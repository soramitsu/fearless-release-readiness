import assert from 'node:assert/strict';
import { mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { request as httpRequest } from 'node:http';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import test from 'node:test';
import { base64UrlEncode } from '../src/base64url.js';
import { authorizationSubjectHash, createIntrospectionRequestAuthorizer, sha256Base64Url } from '../src/authorization.js';
import { createServer, parseTrustedProxyCidrs } from '../src/server.js';
import { createPasskeyBackupChallengeService } from '../src/service.js';
import { serviceError } from '../src/errors.js';
import { FileBackedPasskeyChallengeStore, InMemoryPasskeyChallengeStore } from '../src/store.js';
import { RP_ID, SCHEMA_VERSION } from '../src/validation.js';
import {
  authenticationCredential,
  createAuthenticator,
  registrationCredential,
} from './webauthn-fixture.js';

const ORIGIN = 'https://wallet.example.test';
const ANDROID_ORIGIN = `android:apk-key-hash:${base64UrlEncode(Buffer.alloc(32, 0xa5))}`;

function makeService() {
  return createPasskeyBackupChallengeService({
    store: new InMemoryPasskeyChallengeStore(),
    allowedOrigins: new Set([ORIGIN, ANDROID_ORIGIN]),
    allowInsecureTestAuthorization: true,
  });
}

const TEST_REQUEST_AUTHORIZER = Object.freeze({
  async authorize() {
    return {
      subjectHash: base64UrlEncode(Buffer.alloc(32, 0x42)),
      platform: 'android',
    };
  },
});

function registrationRequest() {
  return {
    walletId: 'wallet-redteam-123',
    accountName: 'redteam@example.test',
    displayName: 'Red Team',
    rpId: RP_ID,
    schemaVersion: SCHEMA_VERSION,
  };
}

async function register(service, authenticator) {
  const registration = service.createRegistrationChallenge(registrationRequest());
  const result = await service.completeRegistration({
    registrationId: registration.registrationId,
    rpId: RP_ID,
    credential: registrationCredential(registration.challenge, authenticator, {
      origin: ANDROID_ORIGIN,
    }),
  });
  return { registration, result };
}

async function withServer(t, run, options = {}) {
  const server = createServer({
    requestAuthorizer: TEST_REQUEST_AUTHORIZER,
    ...options,
  });
  await new Promise((resolve, reject) => {
    server.once('error', reject);
    server.listen(0, '127.0.0.1', resolve);
  });
  t.after(() => new Promise((resolve) => server.close(resolve)));
  const address = server.address();
  return run(`http://127.0.0.1:${address.port}`);
}

async function rawPost(baseUrl, path, { body = '{}', headers = {} } = {}) {
  const url = new URL(baseUrl);
  const requestHeaders = {
    'content-type': 'application/json',
    'content-length': String(Buffer.byteLength(body)),
    authorization: 'Bearer test-authorization-token',
    ...headers,
  };
  for (const [name, value] of Object.entries(requestHeaders)) {
    if (value === undefined) delete requestHeaders[name];
  }
  return new Promise((resolve, reject) => {
    const request = httpRequest({
      hostname: url.hostname,
      port: url.port,
      path,
      method: 'POST',
      headers: requestHeaders,
    }, (response) => {
      const chunks = [];
      response.on('data', (chunk) => chunks.push(chunk));
      response.on('end', () => resolve({
        status: response.statusCode,
        body: JSON.parse(Buffer.concat(chunks).toString('utf8')),
      }));
    });
    request.once('error', reject);
    request.end(body);
  });
}

test('HTTP server rejects encoded and dot-segment aliases for API routes', async (t) => {
  await withServer(t, async (baseUrl) => {
    for (const path of [
      '/api/passkey-backup/v1/registration/ignored/../challenge',
      '/api/passkey-backup/v1/registration/%2e%2e/registration/challenge',
      '/api/passkey-backup/v1/%72egistration/challenge',
    ]) {
      const response = await rawPost(baseUrl, path);
      assert.equal(response.status, 400, path);
      assert.equal(response.body.error, 'invalid_request_target', path);
    }
  });
});

test('file-backed store rejects oversized credential data before parsing', (t) => {
  const directory = mkdtempSync(join(tmpdir(), 'fearless-passkey-oversized-store-'));
  t.after(() => rmSync(directory, { recursive: true, force: true }));
  const credentialStoreFile = join(directory, 'credentials.json');
  writeFileSync(credentialStoreFile, Buffer.alloc((16 * 1024 * 1024) + 1, 0x20));

  assert.throws(
    () => new FileBackedPasskeyChallengeStore({ credentialStoreFile }),
    (error) => error?.code === 'credential_store_invalid' && error?.status === 500,
  );
});

test('registration rejects clientDataJSON containing malformed UTF-8', async () => {
  const service = makeService();
  const registration = service.createRegistrationChallenge(registrationRequest());
  const credential = registrationCredential(registration.challenge, createAuthenticator());
  const prefix = Buffer.from(JSON.stringify({
    type: 'webauthn.create',
    challenge: registration.challenge,
    origin: ORIGIN,
    crossOrigin: false,
    extra: '',
  }).replace('"extra":""', '"extra":"'));
  credential.response.clientDataJSON = base64UrlEncode(Buffer.concat([
    prefix,
    Buffer.from([0xc0, 0xaf]),
    Buffer.from('"}'),
  ]));

  await assert.rejects(
    () => service.completeRegistration({
      registrationId: registration.registrationId,
      rpId: RP_ID,
      credential,
    }),
    (error) => error?.code === 'invalid_client_data_json' && error?.status === 400,
  );
});

test('registration rejects local PRF, blob and arbitrary extension output without retaining a credential', async () => {
  const store = new InMemoryPasskeyChallengeStore();
  const service = createPasskeyBackupChallengeService({
    store, allowedOrigins: new Set([ANDROID_ORIGIN]), allowInsecureTestAuthorization: true,
  });
  const authenticator = createAuthenticator();
  const localOnly = 'SYNTHETIC-LOCAL-PRF-OUTPUT-MUST-NOT-BE-SERIALIZED';
  for (const extensions of [
    { prf: { results: { first: localOnly } } },
    { prf: { enabled: true } },
    { largeBlob: { blob: localOnly } },
    { credProps: { rk: true, prf: localOnly } },
    { credProps: { rk: localOnly } },
    { [localOnly]: 'unreviewed-extension' },
    [],
    null,
  ]) {
    const pending = service.createRegistrationChallenge(registrationRequest());
    const credential = registrationCredential(pending.challenge, authenticator, { origin: ANDROID_ORIGIN });
    credential.clientExtensionResults = extensions;
    await assert.rejects(() => service.completeRegistration({
      registrationId: pending.registrationId, rpId: RP_ID, credential,
    }), (error) => {
      assert.equal(error.code, 'invalid_credential');
      assert.equal(error.status, 400);
      assert.equal(error.message.includes(localOnly), false);
      return true;
    });
    assert.equal(store.hasAnyCredential(pending.storageKey), false);
    assert.equal(store.credentialOwnersById.size, 0);
  }
});

test('sanitized public registration properties are accepted, while assertions reject local extension output', async () => {
  const service = makeService();
  const authenticator = createAuthenticator();
  const pending = service.createRegistrationChallenge(registrationRequest());
  const credential = registrationCredential(pending.challenge, authenticator, { origin: ANDROID_ORIGIN });
  credential.clientExtensionResults = { credProps: { rk: true } };
  const result = await service.completeRegistration({ registrationId: pending.registrationId, rpId: RP_ID, credential });
  for (const extensions of [{ prf: { results: { first: 'synthetic-local-only' } } }, { unexpected: true }]) {
    const assertion = service.createAssertionChallenge({ storageKey: result.storageKey, rpId: RP_ID, schemaVersion: SCHEMA_VERSION });
    const response = authenticationCredential(assertion.challenge, authenticator, pending.userId, { origin: ANDROID_ORIGIN });
    response.clientExtensionResults = extensions;
    await assert.rejects(() => service.completeAssertion({ assertionId: assertion.assertionId, rpId: RP_ID, credential: response }), {
      code: 'invalid_credential', status: 400,
    });
  }
  const assertion = service.createAssertionChallenge({ storageKey: result.storageKey, rpId: RP_ID, schemaVersion: SCHEMA_VERSION });
  const response = authenticationCredential(assertion.challenge, authenticator, pending.userId, { origin: ANDROID_ORIGIN });
  assert.deepEqual(await service.completeAssertion({ assertionId: assertion.assertionId, rpId: RP_ID, credential: response }), result);
});

test('concurrent assertion replay permits one claimant only', async () => {
  const service = makeService();
  const authenticator = createAuthenticator('concurrent-assertion');
  const { registration, result } = await register(service, authenticator);
  const assertion = service.createAssertionChallenge({
    storageKey: result.storageKey,
    rpId: RP_ID,
    schemaVersion: SCHEMA_VERSION,
  });
  const completion = {
    assertionId: assertion.assertionId,
    rpId: RP_ID,
    credential: authenticationCredential(
      assertion.challenge,
      authenticator,
      registration.userId,
      { counter: 1, origin: ANDROID_ORIGIN },
    ),
  };

  const outcomes = await Promise.allSettled([
    service.completeAssertion(structuredClone(completion)),
    service.completeAssertion(structuredClone(completion)),
  ]);
  assert.equal(outcomes.filter((outcome) => outcome.status === 'fulfilled').length, 1);
  const rejected = outcomes.find((outcome) => outcome.status === 'rejected');
  assert.equal(rejected.reason.code, 'unknown_or_expired_assertion');
});

test('concurrent distinct assertions cannot commit the same counter twice', async () => {
  const service = makeService();
  const authenticator = createAuthenticator('concurrent-counter');
  const { registration, result } = await register(service, authenticator);
  const assertions = [0, 1].map(() => service.createAssertionChallenge({
    storageKey: result.storageKey,
    rpId: RP_ID,
    schemaVersion: SCHEMA_VERSION,
  }));

  const outcomes = await Promise.allSettled(assertions.map((assertion) => service.completeAssertion({
    assertionId: assertion.assertionId,
    rpId: RP_ID,
    credential: authenticationCredential(
      assertion.challenge,
      authenticator,
      registration.userId,
      { counter: 7, origin: ANDROID_ORIGIN },
    ),
  })));
  assert.equal(outcomes.filter((outcome) => outcome.status === 'fulfilled').length, 1);
  const rejected = outcomes.find((outcome) => outcome.status === 'rejected');
  assert.equal(rejected.reason.code, 'credential_counter_replay');
  assert.equal(rejected.reason.status, 409);
});

test('HTTP authorization binds the exact transmitted body and rejects header ambiguity', async (t) => {
  const calls = [];
  const requestAuthorizer = {
    async authorize(context) {
      calls.push(context);
      return {
        subjectHash: authorizationSubjectHash('fearless-wallet-owner:server-test'),
        platform: 'android',
      };
    },
  };
  const service = {
    health: () => ({ ok: true }),
    createRegistrationChallenge: () => ({ accepted: true }),
  };
  await withServer(t, async (baseUrl) => {
    const rawBody = '{ "body" : "spacing-is-signed" }';
    const accepted = await rawPost(
      baseUrl,
      '/api/passkey-backup/v1/registration/challenge',
      { body: rawBody },
    );
    assert.equal(accepted.status, 200);
    assert.equal(calls.length, 1);
    assert.equal(calls[0].bodySha256, sha256Base64Url(Buffer.from(rawBody)));
    assert.equal(calls[0].token, 'test-authorization-token');

    for (const authorization of [
      undefined,
      'Basic dXNlcjpwYXNz',
      'Bearer contains whitespace',
      'Bearer token,spoof',
      ['Bearer duplicate-one', 'Bearer duplicate-two'],
    ]) {
      const headers = authorization === undefined
        ? { authorization: undefined }
        : { authorization };
      const response = await rawPost(
        baseUrl,
        '/api/passkey-backup/v1/registration/challenge',
        { headers },
      );
      assert.equal(response.status, 401, String(authorization));
      assert.equal(response.body.error, 'request_authorization_failed');
    }
    assert.equal(calls.length, 1, 'malformed Authorization headers must not reach introspection');
  }, { service, requestAuthorizer });
});

test('legacy HTTP refuses SQLite-owner introspection before a credential mutation', async (t) => {
  let calls = 0;
  const requestAuthorizer = createIntrospectionRequestAuthorizer({
    introspectionUrl: 'https://authority.example.test/introspect',
    audience: 'fearless.passkey-backup',
    now: () => 1_800_000_000_000,
    fetchImpl: async (_url, init) => {
      const binding = JSON.parse(init.body);
      return new Response(JSON.stringify({ ...binding, active: true,
        subject: `owner:${base64UrlEncode(Buffer.alloc(32, 7))}`,
        platform: 'android', expiresAt: 1_800_000_030,
        credentialAuthority: 'owner-sqlite-v2',
      }), { headers: { 'content-type': 'application/json' } });
    },
  });
  await withServer(t, async (baseUrl) => {
    for (const path of ['/api/passkey-backup/v1/registration/complete',
      '/api/passkey-backup/v1/assertion/complete', '/api/passkey-backup/v1/credentials/revoke',
      '/api/passkey-backup/v1/credentials/revoke-all']) {
      const response = await rawPost(baseUrl, path);
      assert.equal(response.status, 401, path);
      assert.equal(response.body.error, 'request_authorization_failed');
    }
    assert.equal(calls, 0);
  }, { service: { health: () => ({ ok: true }),
    completeRegistration: () => { calls += 1; return {}; },
    completeAssertion: () => { calls += 1; return {}; },
    revokeCredential: () => { calls += 1; return {}; },
    revokeAllCredentials: () => { calls += 1; return {}; } },
    requestAuthorizer });
});

test('HTTP server rejects duplicate routing and body headers before authorization', async (t) => {
  let authorizations = 0;
  await withServer(t, async (baseUrl) => {
    for (const headers of [
      { 'content-type': ['application/json', 'text/plain'] },
      { 'x-forwarded-for': ['198.51.100.1', '198.51.100.2'] },
      { forwarded: ['for=198.51.100.1', 'for=198.51.100.2'] },
    ]) {
      const response = await rawPost(
        baseUrl,
        '/api/passkey-backup/v1/registration/challenge',
        { headers },
      );
      assert.equal(response.status, 400);
      assert.equal(response.body.error, 'ambiguous_headers');
    }
    assert.equal(authorizations, 0);
  }, {
    service: { health: () => ({ ok: true }), createRegistrationChallenge: () => ({ accepted: true }) },
    requestAuthorizer: { async authorize() { authorizations += 1; return TEST_REQUEST_AUTHORIZER.authorize(); } },
  });
});

test('HTTP authorization rejects a body-hash mismatch without leaking details', async (t) => {
  const expectedHash = sha256Base64Url(Buffer.from('{"authorized":true}'));
  const service = {
    health: () => ({ ok: true }),
    createRegistrationChallenge: () => ({ accepted: true }),
  };
  await withServer(t, async (baseUrl) => {
    const response = await rawPost(
      baseUrl,
      '/api/passkey-backup/v1/registration/challenge',
      { body: '{"authorized":false}' },
    );
    assert.equal(response.status, 401);
    assert.equal(response.body.error, 'request_authorization_failed');
    assert.equal(JSON.stringify(response.body).includes(expectedHash), false);
  }, {
    service,
    requestAuthorizer: {
      async authorize(context) {
        if (context.bodySha256 !== expectedHash) {
          throw serviceError(401, 'request_authorization_failed', 'internal body-hash mismatch details');
        }
        return TEST_REQUEST_AUTHORIZER.authorize();
      },
    },
  });
});

test('credential lifecycle HTTP routes bind distinct exact paths and raw body digests', async (t) => {
  const calls = [];
  const service = {
    health: () => ({ ok: true }),
    listCredentials: (body) => ({ accepted: 'list', storageKey: body.storageKey }),
    revokeCredential: (body) => ({ accepted: 'revoke', storageKey: body.storageKey }),
    revokeAllCredentials: (body) => ({ accepted: 'revoke-all', storageKey: body.storageKey }),
  };
  const routes = [
    ['/api/passkey-backup/v1/credentials/list', '{"storageKey":"storage:exact-list","rpId":"fearlesswallet.io","schemaVersion":1}', 'list'],
    ['/api/passkey-backup/v1/credentials/revoke', '{ "storageKey": "storage:exact-revoke", "credentialId": "QkJCQkJCQkJCQkJCQkJCQkJCQkJCQkJCQkJCQkJCQkI", "rpId": "fearlesswallet.io", "schemaVersion": 1 }', 'revoke'],
    ['/api/passkey-backup/v1/credentials/revoke-all', '{\n"storageKey":"storage:exact-all","rpId":"fearlesswallet.io","schemaVersion":1\n}', 'revoke-all'],
  ];
  await withServer(t, async (baseUrl) => {
    for (const [path, body, expected] of routes) {
      const response = await rawPost(baseUrl, path, { body });
      assert.equal(response.status, 200, path);
      assert.equal(response.body.accepted, expected, path);
    }
  }, {
    service,
    requestAuthorizer: {
      async authorize(context) {
        calls.push(context);
        return TEST_REQUEST_AUTHORIZER.authorize();
      },
    },
  });
  assert.deepEqual(calls.map(({ token, method, path, bodySha256 }) => ({
    token,
    method,
    path,
    bodySha256,
  })), routes.map(([path, body]) => ({
    token: 'test-authorization-token',
    method: 'POST',
    path,
    bodySha256: sha256Base64Url(Buffer.from(body)),
  })));
});

test('trusted-proxy rate limiting is opt-in, single-hop, and fail-closed', async (t) => {
  const service = {
    health: () => ({ ok: true }),
    createRegistrationChallenge: () => ({ accepted: true }),
  };
  await withServer(t, async (baseUrl) => {
    const first = await rawPost(baseUrl, '/api/passkey-backup/v1/registration/challenge', {
      headers: { 'x-forwarded-for': '198.51.100.1' },
    });
    const spoofed = await rawPost(baseUrl, '/api/passkey-backup/v1/registration/challenge', {
      headers: { 'x-forwarded-for': '198.51.100.2' },
    });
    assert.equal(first.status, 200);
    assert.equal(spoofed.status, 429, 'untrusted forwarded headers must not rotate the rate-limit key');
  }, { service, rateLimitMaxRequests: 1, trustedProxyHops: 0 });

  await withServer(t, async (baseUrl) => {
    for (const forwarded of [
      undefined,
      'unknown',
      '198.51.100.1, 198.51.100.2',
      ['198.51.100.1', '198.51.100.2'],
      '2001:0db8::1',
      '2001:DB8::1',
      '::ffff:198.51.100.1',
    ]) {
      const headers = forwarded === undefined
        ? { 'x-forwarded-for': undefined }
        : { 'x-forwarded-for': forwarded };
      const response = await rawPost(baseUrl, '/api/passkey-backup/v1/registration/challenge', { headers });
      assert.equal(response.status, 400, String(forwarded));
      assert.equal(
        response.body.error,
        Array.isArray(forwarded) ? 'ambiguous_headers' : 'invalid_forwarded_client',
      );
    }
    const clientOne = await rawPost(baseUrl, '/api/passkey-backup/v1/registration/challenge', {
      headers: { 'x-forwarded-for': '198.51.100.10' },
    });
    const clientTwo = await rawPost(baseUrl, '/api/passkey-backup/v1/registration/challenge', {
      headers: { 'x-forwarded-for': '198.51.100.11' },
    });
    assert.equal(clientOne.status, 200);
    assert.equal(clientTwo.status, 200);
  }, {
    service,
    rateLimitMaxRequests: 1,
    trustedProxyHops: 1,
    trustedProxyCidrs: parseTrustedProxyCidrs('127.0.0.1/32'),
  });

  await withServer(t, async (baseUrl) => {
    const response = await rawPost(baseUrl, '/api/passkey-backup/v1/registration/challenge', {
      headers: { 'x-forwarded-for': '198.51.100.10' },
    });
    assert.equal(response.status, 400);
    assert.equal(response.body.error, 'untrusted_proxy');
  }, {
    service,
    trustedProxyHops: 1,
    trustedProxyCidrs: parseTrustedProxyCidrs('192.0.2.0/24'),
  });

  assert.doesNotThrow(() => parseTrustedProxyCidrs('2001:db8::/32'));
  for (const value of [
    '',
    '127.0.0.1,127.0.0.1',
    ' 127.0.0.1',
    '127.0.0.1/33',
    'not-an-ip',
    '2001:0db8::/32',
    '2001:DB8::/32',
    '::ffff:198.51.100.1/128',
    '0.0.0.0/0',
    '10.0.0.1/8',
    '192.168.1.2/24',
    '2001:db8::1/64',
    '10.0.0.0/8,10.1.0.0/16',
    '2001:db8::/32,2001:db8:1::/48',
  ]) {
    assert.throws(() => parseTrustedProxyCidrs(value), /PASSKEY_TRUSTED_PROXY_CIDRS/);
  }
});

test('global request bucket bounds distributed client and introspection load', async (t) => {
  let introspectionCalls = 0;
  const service = {
    health: () => ({ ok: true }),
    createRegistrationChallenge: () => ({ accepted: true }),
  };
  await withServer(t, async (baseUrl) => {
    for (const [index, expectedStatus] of [200, 200, 429].entries()) {
      const response = await rawPost(baseUrl, '/api/passkey-backup/v1/registration/challenge', {
        headers: { 'x-forwarded-for': `198.51.100.${index + 1}` },
      });
      assert.equal(response.status, expectedStatus);
    }
    assert.equal(introspectionCalls, 2, 'globally rejected traffic must not reach introspection');
  }, {
    service,
    trustedProxyHops: 1,
    trustedProxyCidrs: parseTrustedProxyCidrs('127.0.0.1'),
    rateLimitMaxRequests: 10,
    globalRateLimitMaxRequests: 2,
    requestAuthorizer: {
      async authorize() {
        introspectionCalls += 1;
        return TEST_REQUEST_AUTHORIZER.authorize();
      },
    },
  });
});

test('stable authorization owner permits cross-platform ceremonies and rejects cross-subject access', async () => {
  const store = new InMemoryPasskeyChallengeStore();
  const service = createPasskeyBackupChallengeService({
    store,
    allowedOrigins: new Set([ORIGIN, ANDROID_ORIGIN]),
  });
  const ownerHash = authorizationSubjectHash('fearless-wallet-owner:cross-platform');
  const expiresAt = Math.floor(Date.now() / 1000) + 60;
  const android = { subjectHash: ownerHash, platform: 'android', expiresAt };
  const ios = { subjectHash: ownerHash, platform: 'ios', expiresAt };
  const attacker = {
    subjectHash: authorizationSubjectHash('fearless-wallet-owner:attacker'),
    platform: 'ios',
    expiresAt,
  };
  const authenticator = createAuthenticator('cross-platform-owner');
  const registration = service.createRegistrationChallenge(registrationRequest(), android);
  const result = await service.completeRegistration({
    registrationId: registration.registrationId,
    rpId: RP_ID,
    credential: registrationCredential(registration.challenge, authenticator, {
      origin: ANDROID_ORIGIN,
    }),
  }, android);

  assert.throws(
    () => service.createRegistrationChallenge(registrationRequest(), attacker),
    (error) => error?.code === 'request_authorization_failed' && error?.status === 403,
  );
  assert.throws(
    () => service.createAssertionChallenge({
      storageKey: result.storageKey,
      rpId: RP_ID,
      schemaVersion: SCHEMA_VERSION,
    }, attacker),
    (error) => error?.code === 'request_authorization_failed' && error?.status === 403,
  );

  const assertion = service.createAssertionChallenge({
    storageKey: result.storageKey,
    rpId: RP_ID,
    schemaVersion: SCHEMA_VERSION,
  }, ios);
  await assert.rejects(
    () => service.completeAssertion({
      assertionId: assertion.assertionId,
      rpId: RP_ID,
      credential: authenticationCredential(
        assertion.challenge,
        authenticator,
        registration.userId,
        { counter: 1, origin: ORIGIN },
      ),
    }, attacker),
    (error) => error?.code === 'request_authorization_failed' && error?.status === 403,
  );
  const asserted = await service.completeAssertion({
    assertionId: assertion.assertionId,
    rpId: RP_ID,
    credential: authenticationCredential(
      assertion.challenge,
      authenticator,
      registration.userId,
      { counter: 1, origin: ORIGIN },
    ),
  }, ios);
  assert.deepEqual(asserted, result);
});

test('authorization platform is cryptographically bound to its WebAuthn origin family', async () => {
  const ownerHash = authorizationSubjectHash('fearless-wallet-owner:origin-platform-binding');
  const cases = [
    {
      platform: 'android',
      wrongOrigin: ORIGIN,
    },
    {
      platform: 'ios',
      wrongOrigin: ANDROID_ORIGIN,
    },
  ];

  for (const { platform, wrongOrigin } of cases) {
    const service = createPasskeyBackupChallengeService({
      store: new InMemoryPasskeyChallengeStore(),
      allowedOrigins: new Set([ORIGIN, ANDROID_ORIGIN]),
    });
    const authorization = { subjectHash: ownerHash, platform, expiresAt: Math.floor(Date.now() / 1000) + 60 };
    const registration = service.createRegistrationChallenge(registrationRequest(), authorization);

    await assert.rejects(
      () => service.completeRegistration({
        registrationId: registration.registrationId,
        rpId: RP_ID,
        credential: registrationCredential(
          registration.challenge,
          createAuthenticator(`wrong-origin-${platform}`),
          { origin: wrongOrigin },
        ),
      }, authorization),
      (error) => error?.code === 'origin_not_allowed' && error?.status === 403,
      platform,
    );
  }
});

test('completion authorization is bound to the subject and platform that opened the ceremony', async () => {
  const service = createPasskeyBackupChallengeService({
    store: new InMemoryPasskeyChallengeStore(),
    allowedOrigins: new Set([ORIGIN, ANDROID_ORIGIN]),
  });
  const subjectHash = authorizationSubjectHash('fearless-wallet-owner:ceremony-binding');
  const expiresAt = Math.floor(Date.now() / 1000) + 60;
  const android = { subjectHash, platform: 'android', expiresAt };
  const ios = { subjectHash, platform: 'ios', expiresAt };
  const registration = service.createRegistrationChallenge(registrationRequest(), android);
  const authenticator = createAuthenticator('authorization-claim-retry');
  await assert.rejects(
    () => service.completeRegistration({
      registrationId: registration.registrationId,
      rpId: RP_ID,
      credential: registrationCredential(registration.challenge, authenticator, {
        origin: ANDROID_ORIGIN,
      }),
    }, ios),
    (error) => error?.code === 'request_authorization_failed' && error?.status === 403,
  );
  const completed = await service.completeRegistration({
    registrationId: registration.registrationId,
    rpId: RP_ID,
    credential: registrationCredential(registration.challenge, authenticator, {
      origin: ANDROID_ORIGIN,
    }),
  }, android);
  assert.equal(completed.storageKey, registration.storageKey);
});
