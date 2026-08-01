import assert from 'node:assert/strict';
import test from 'node:test';
import {
  AUTHORIZATION_SCOPES,
  authorizationSubjectHash,
  createIntrospectionRequestAuthorizer,
  createRequestAuthorizerFromEnvironment,
  normalizeAuthorizationAudience,
  normalizeIntrospectionUrl,
  sha256Base64Url,
} from '../src/authorization.js';

const URL = 'https://authorization.fearlesswallet.io/v1/passkey/consume';
const AUDIENCE = 'fearless-passkey-backup';
const PATH = '/api/passkey-backup/v1/registration/challenge';
const BODY_HASH = sha256Base64Url(Buffer.from('{"request":true}'));
const NOW = 1_750_000_000_000;

function activeAuthorization(overrides = {}) {
  return {
    schemaVersion: 1,
    active: true,
    subject: 'fearless-wallet-owner:123456',
    audience: AUDIENCE,
    method: 'POST',
    path: PATH,
    bodySha256: BODY_HASH,
    scope: AUTHORIZATION_SCOPES[PATH],
    platform: 'android',
    expiresAt: Math.floor(NOW / 1000) + 60,
    ...overrides,
  };
}

function jsonResponse(status, body, headers = {}) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { 'content-type': 'application/json', ...headers },
  });
}

function authorizer(fetchImpl) {
  return createIntrospectionRequestAuthorizer({
    introspectionUrl: URL,
    audience: AUDIENCE,
    fetchImpl,
    now: () => NOW,
    timeoutMs: 500,
  });
}

const context = {
  token: 'opaque-one-time-authorization-token',
  method: 'POST',
  path: PATH,
  bodySha256: BODY_HASH,
};

test('introspection sends the opaque token only in Authorization and validates exact binding', async () => {
  let captured;
  const result = await authorizer(async (url, options) => {
    captured = { url, options };
    return jsonResponse(200, activeAuthorization());
  }).authorize(context);

  assert.equal(captured.url, URL);
  assert.equal(captured.options.headers.authorization, `Bearer ${context.token}`);
  assert.equal(captured.options.redirect, 'error');
  assert.deepEqual(JSON.parse(captured.options.body), {
    schemaVersion: 1,
    audience: AUDIENCE,
    method: 'POST',
    path: PATH,
    bodySha256: BODY_HASH,
    scope: AUTHORIZATION_SCOPES[PATH],
  });
  assert.equal(captured.options.body.includes(context.token), false);
  assert.deepEqual(result, {
    subjectHash: authorizationSubjectHash('fearless-wallet-owner:123456'),
    platform: 'android',
    expiresAt: Math.floor(NOW / 1000) + 60,
  });
});

test('authorization scopes cover every ceremony and credential-lifecycle route exactly', async () => {
  assert.deepEqual(AUTHORIZATION_SCOPES, {
    '/api/passkey-backup/v1/registration/challenge': 'passkey.registration.challenge',
    '/api/passkey-backup/v1/registration/complete': 'passkey.registration.complete',
    '/api/passkey-backup/v1/assertion/challenge': 'passkey.assertion.challenge',
    '/api/passkey-backup/v1/assertion/complete': 'passkey.assertion.complete',
    '/api/passkey-backup/v1/credentials/list': 'passkey.credentials.list',
    '/api/passkey-backup/v1/credentials/revoke': 'passkey.credentials.revoke',
    '/api/passkey-backup/v1/credentials/revoke-all': 'passkey.credentials.revoke-all',
  });

  for (const [path, scope] of Object.entries(AUTHORIZATION_SCOPES)) {
    const routeContext = { ...context, path };
    const result = await authorizer(async () => jsonResponse(200, activeAuthorization({
      path,
      scope,
      platform: 'ios',
    }))).authorize(routeContext);
    assert.equal(result.platform, 'ios');
  }
});

test('introspection fails closed on claim, binding, platform, expiry, and schema drift', async () => {
  const mutations = [
    { schemaVersion: 2 },
    { active: false },
    { subject: 'short' },
    { audience: 'different-audience' },
    { method: 'GET' },
    { path: '/api/passkey-backup/v1/assertion/challenge' },
    { bodySha256: sha256Base64Url('mutated-body') },
    { scope: 'passkey.admin' },
    { platform: 'web' },
    { expiresAt: Math.floor(NOW / 1000) },
    { expiresAt: Math.floor(NOW / 1000) + 301 },
    { expiresAt: `${Math.floor(NOW / 1000) + 60}` },
    { unexpected: true },
  ];
  for (const mutation of mutations) {
    await assert.rejects(
      () => authorizer(async () => jsonResponse(200, activeAuthorization(mutation))).authorize(context),
      (error) => error?.code === 'request_authorization_failed' && error?.status === 401,
      JSON.stringify(mutation),
    );
  }
});

test('introspection maps denial and infrastructure failures to generic non-leaking errors', async () => {
  for (const [response, code, status] of [
    [jsonResponse(401, { error: 'token details must not escape' }), 'request_authorization_failed', 401],
    [jsonResponse(500, { error: 'database DSN must not escape' }), 'authorization_service_unavailable', 503],
    [new Response(JSON.stringify(activeAuthorization()), { status: 201, headers: { 'content-type': 'application/json' } }), 'authorization_service_unavailable', 503],
    [new Response('not-json', { status: 200, headers: { 'content-type': 'application/json' } }), 'authorization_service_unavailable', 503],
    [new Response('{}', { status: 200, headers: { 'content-type': 'text/plain' } }), 'authorization_service_unavailable', 503],
  ]) {
    await assert.rejects(
      () => authorizer(async () => response).authorize(context),
      (error) => {
        assert.equal(error.code, code);
        assert.equal(error.status, status);
        assert.doesNotMatch(error.message, /token details|database DSN/);
        return true;
      },
    );
  }
  await assert.rejects(
    () => authorizer(async () => { throw new Error(`leaked ${context.token}`); }).authorize(context),
    (error) => error?.code === 'authorization_service_unavailable' &&
      !error.message.includes(context.token),
  );
});

test('introspection timeout and oversized responses fail closed', async () => {
  const slow = createIntrospectionRequestAuthorizer({
    introspectionUrl: URL,
    audience: AUDIENCE,
    timeoutMs: 100,
    now: () => NOW,
    fetchImpl: async (url, { signal }) => new Promise((resolve, reject) => {
      signal.addEventListener('abort', () => reject(new Error('aborted')), { once: true });
    }),
  });
  await assert.rejects(
    () => slow.authorize(context),
    (error) => error?.code === 'authorization_service_unavailable' && error?.status === 503,
  );

  const oversized = 'x'.repeat((16 * 1024) + 1);
  await assert.rejects(
    () => authorizer(async () => new Response(oversized, {
      status: 200,
      headers: { 'content-type': 'application/json' },
    })).authorize(context),
    (error) => error?.code === 'authorization_service_unavailable' && error?.status === 503,
  );
});

test('replayed one-time authorization is rejected by the consuming introspector', async () => {
  const consumed = new Set();
  const consumingAuthorizer = authorizer(async (url, options) => {
    const token = options.headers.authorization.slice('Bearer '.length);
    if (consumed.has(token)) return jsonResponse(401, { active: false });
    consumed.add(token);
    return jsonResponse(200, activeAuthorization());
  });
  await consumingAuthorizer.authorize(context);
  await assert.rejects(
    () => consumingAuthorizer.authorize(context),
    (error) => error?.code === 'request_authorization_failed' && error?.status === 401,
  );
});

test('authorization configuration accepts only canonical production values', () => {
  assert.equal(normalizeIntrospectionUrl(URL), URL);
  assert.equal(normalizeAuthorizationAudience(AUDIENCE), AUDIENCE);
  for (const value of [
    '',
    'http://authorization.fearlesswallet.io/v1/passkey/consume',
    'https://user:secret@authorization.fearlesswallet.io/v1/passkey/consume',
    'https://authorization.fearlesswallet.io',
    'https://authorization.fearlesswallet.io/v1/passkey/../consume',
    'https://authorization.fearlesswallet.io/v1/passkey/%63onsume',
    'https://authorization.fearlesswallet.io/v1/passkey/%2Fconsume',
    'https://authorization.fearlesswallet.io/v1/passkey/consume?secret=x',
    ' https://authorization.fearlesswallet.io/v1/passkey/consume',
  ]) {
    assert.throws(() => normalizeIntrospectionUrl(value), /canonical HTTPS URL/, value);
  }
  for (const audience of ['', 'short', 'contains whitespace', 'x'.repeat(129)]) {
    assert.throws(() => normalizeAuthorizationAudience(audience), /8-128 URL-safe/, audience);
  }
  assert.throws(() => createRequestAuthorizerFromEnvironment({}), /are required/);
  assert.throws(() => createRequestAuthorizerFromEnvironment({
    PASSKEY_AUTHORIZATION_INTROSPECTION_URL: URL,
    PASSKEY_AUTHORIZATION_AUDIENCE: AUDIENCE,
    PASSKEY_AUTHORIZATION_TIMEOUT_MS: '02000',
  }), /must be an integer/);
});
