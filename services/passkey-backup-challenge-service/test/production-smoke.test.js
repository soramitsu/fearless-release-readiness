import assert from 'node:assert/strict';
import { chmodSync, mkdirSync, mkdtempSync, realpathSync, rmSync, symlinkSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import test from 'node:test';
import {
  createExecutableSmokeAuthorizationProvider,
  runProductionSmoke,
} from '../scripts/production-smoke.mjs';
import { createServer } from '../src/server.js';
import { createPasskeyBackupChallengeService } from '../src/service.js';
import { InMemoryPasskeyChallengeStore } from '../src/store.js';

async function withServer(t, handler, { requestAuthorizer } = {}) {
  const store = new InMemoryPasskeyChallengeStore();
  const server = createServer({
    service: createPasskeyBackupChallengeService({ store }),
    requestAuthorizer: requestAuthorizer ?? {
      async authorize() {
        return {
          subjectHash: 'QkJCQkJCQkJCQkJCQkJCQkJCQkJCQkJCQkJCQkJCQkI',
          platform: 'android',
          expiresAt: Math.floor(Date.now() / 1000) + 60,
        };
      },
    },
  });
  await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
  t.after(() => {
    server.close();
  });
  const address = server.address();
  return handler(`http://127.0.0.1:${address.port}`, store);
}

function jsonResponse(status, body, contentType = 'application/json') {
  return new Response(JSON.stringify(body), {
    status,
    headers: { 'content-type': contentType },
  });
}

function textResponse(status, body, contentType = 'text/plain; charset=utf-8') {
  return new Response(body, {
    status,
    headers: { 'content-type': contentType },
  });
}

function routeFetch(routes) {
  return async (input, options = {}) => {
    const url = new URL(input);
    const key = `${options.method ?? 'GET'} ${url.pathname}`;
    const route = routes[key];
    if (!route) {
      throw new Error(`unexpected smoke route: ${key}`);
    }
    return route(input, options);
  };
}

const health = {
  ok: true,
  service: 'fearless-passkey-backup',
  rpId: 'fearlesswallet.io',
  schemaVersion: 1,
};

const registration = {
  registrationId: 'reg:passkey-smoke-ok',
  challenge: 'QUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUE',
  userId: 'QkJCQkJCQkJCQkJCQkJCQkJCQkJCQkJCQkJCQkJCQkI',
  userName: 'passkey-smoke@example.com',
  displayName: 'Fearless Passkey Smoke',
  storageKey: 'storage:passkey-smoke-ok',
  rpId: 'fearlesswallet.io',
  schemaVersion: 1,
};

const serviceError = (error) => ({
  ok: false,
  service: 'fearless-passkey-backup',
  error,
  rpId: 'fearlesswallet.io',
  schemaVersion: 1,
});

const testAuthorizationProvider = async ({ bodySha256 }) => `smoke-grant.${bodySha256}`;

function smokeRoutes(overrides = {}) {
  let registrationConsumed = false;
  return {
    'GET /api/passkey-backup/v1/health': () => jsonResponse(200, health),
    'POST /api/passkey-backup/v1/registration/challenge': (input, options) => {
      const body = JSON.parse(options.body);
      return jsonResponse(200, {
        ...registration,
        userName: body.accountName,
        displayName: body.displayName,
      });
    },
    'POST /api/passkey-backup/v1/assertion/challenge': () => jsonResponse(
      404,
      serviceError('credential_not_registered'),
    ),
    'POST /api/passkey-backup/v1/registration/complete': (input, options) => {
      const body = JSON.parse(options.body);
      assert.equal(body.registrationId, registration.registrationId);
      if (registrationConsumed) {
        return jsonResponse(404, serviceError('unknown_or_expired_registration'));
      }
      registrationConsumed = true;
      return jsonResponse(400, serviceError('credential_type_mismatch'));
    },
    'POST /api/passkey-backup/v1/assertion/complete': () => jsonResponse(
      404,
      serviceError('unknown_or_expired_assertion'),
    ),
    'POST /api/passkey-backup/v1/credentials/list': () => jsonResponse(
      404,
      serviceError('credential_storage_not_registered'),
    ),
    'POST /api/passkey-backup/v1/credentials/revoke': (input, options) => {
      const body = JSON.parse(options.body);
      return jsonResponse(200, {
        storageKey: body.storageKey,
        credentialId: body.credentialId,
        remainingCredentials: 0,
        rpId: 'fearlesswallet.io',
        schemaVersion: 1,
      });
    },
    'POST /api/passkey-backup/v1/credentials/revoke-all': (input, options) => {
      const body = JSON.parse(options.body);
      return jsonResponse(200, {
        storageKey: body.storageKey,
        remainingCredentials: 0,
        rpId: 'fearlesswallet.io',
        schemaVersion: 1,
      });
    },
    ...overrides,
  };
}

test('production smoke validates health and challenge routes without storing credentials or ceremonies', async (t) => {
  await withServer(t, async (baseUrl, store) => {
    let tokenIndex = 0;
    const result = await runProductionSmoke({
      baseUrl,
      timeoutMs: 1_000,
      authorizationProvider: async () => `smoke-one-time-token-${tokenIndex += 1}`,
    });
    assert.equal(result.service, 'fearless-passkey-backup');
    assert.deepEqual(result.checkedRoutes, [
      '/api/passkey-backup/v1/health',
      '/api/passkey-backup/v1/registration/challenge',
      '/api/passkey-backup/v1/registration/complete',
      '/api/passkey-backup/v1/assertion/challenge',
      '/api/passkey-backup/v1/assertion/complete',
      '/api/passkey-backup/v1/credentials/list',
      '/api/passkey-backup/v1/credentials/revoke',
      '/api/passkey-backup/v1/credentials/revoke-all',
    ]);
    assert.equal(store.registrationCeremonies.size, 0);
    assert.equal(store.inFlightRegistrationsByStorageKey.size, 0);
    assert.equal(store.credentialsByStorageKey.size, 0);
  });
});

test('production smoke detects rotating authorization subjects and consumes its pending registration', async (t) => {
  let authorizationCalls = 0;
  const subjects = [
    'QkJCQkJCQkJCQkJCQkJCQkJCQkJCQkJCQkJCQkJCQkI',
    'Q0NDQ0NDQ0NDQ0NDQ0NDQ0NDQ0NDQ0NDQ0NDQ0NDQ0M',
  ];
  const requestAuthorizer = {
    async authorize() {
      const subjectHash = subjects[authorizationCalls % subjects.length];
      authorizationCalls += 1;
      return { subjectHash, platform: 'android', expiresAt: Math.floor(Date.now() / 1000) + 60 };
    },
  };

  await withServer(t, async (baseUrl, store) => {
    await assert.rejects(
      () => runProductionSmoke({
        baseUrl,
        timeoutMs: 1_000,
        authorizationProvider: testAuthorizationProvider,
      }),
      /authorization subject or platform changed between registration challenge and completion/,
    );
    assert.equal(store.registrationCeremonies.size, 0);
    assert.equal(store.inFlightRegistrationsByStorageKey.size, 0);
    assert.equal(store.credentialsByStorageKey.size, 0);
  }, { requestAuthorizer });
});

test('production smoke rejects non-HTTPS non-localhost base URLs', async () => {
  await assert.rejects(
    () => runProductionSmoke({
      baseUrl: 'http://backup.fearlesswallet.io',
      fetchImpl: routeFetch(smokeRoutes()),
    }),
    /must use HTTPS outside localhost/,
  );
});

test('production smoke rejects credentialed base URLs before making requests', async () => {
  let fetchCalled = false;
  await assert.rejects(
    () => runProductionSmoke({
      baseUrl: 'https://operator:secret@backup.fearlesswallet.io',
      fetchImpl: async () => {
        fetchCalled = true;
        throw new Error('fetch should not be called for credentialed base URLs');
      },
    }),
    /PASSKEY_BACKUP_BASE_URL must not contain credentials/,
  );
  assert.equal(fetchCalled, false);
});

test('production smoke rejects query or fragment base URLs before making requests', async () => {
  let fetchCalled = false;
  await assert.rejects(
    () => runProductionSmoke({
      baseUrl: 'https://backup.fearlesswallet.io?token=secret#fragment',
      fetchImpl: async () => {
        fetchCalled = true;
        throw new Error('fetch should not be called for query or fragment base URLs');
      },
    }),
    /PASSKEY_BACKUP_BASE_URL must not contain query strings or fragments/,
  );
  assert.equal(fetchCalled, false);
});

test('production smoke refuses redirects without following or logging the location', async () => {
  let calls = 0;
  let capturedOptions;
  const fetchImpl = async (input, options) => {
    calls += 1;
    capturedOptions = options;
    return new Response('redirecting', {
      status: 302,
      headers: {
        location: 'https://attacker.invalid/?token=redirect-secret',
        'content-type': 'text/plain',
      },
    });
  };

  await assert.rejects(
    () => runProductionSmoke({
      baseUrl: 'https://backup.fearlesswallet.io',
      fetchImpl,
      authorizationProvider: testAuthorizationProvider,
    }),
    (error) => {
      const diagnostic = String(error);
      assert.match(diagnostic, /refused redirect HTTP 302; production smoke redirects are forbidden/);
      assert.doesNotMatch(diagnostic, /redirect-secret/);
      return true;
    },
  );
  assert.equal(calls, 1);
  assert.equal(capturedOptions.redirect, 'manual');
});

test('production smoke bounds slow response bodies and non-cooperative fetches by the total deadline', async () => {
  let slowBodyTimer;
  const slowBody = new ReadableStream({
    start(controller) {
      controller.enqueue(new TextEncoder().encode('{"ok":'));
      slowBodyTimer = setTimeout(() => {
        controller.enqueue(new TextEncoder().encode('true}'));
        controller.close();
      }, 200);
    },
    cancel() {
      clearTimeout(slowBodyTimer);
    },
  });
  const fetches = [
    async () => new Response(slowBody, {
      status: 200,
      headers: { 'content-type': 'application/json' },
    }),
    async () => new Promise(() => undefined),
  ];

  for (const fetchImpl of fetches) {
    const startedAt = Date.now();
    await assert.rejects(
      () => runProductionSmoke({
        baseUrl: 'https://backup.fearlesswallet.io',
        timeoutMs: 25,
        fetchImpl,
        authorizationProvider: testAuthorizationProvider,
      }),
      /timed out after 25ms/,
    );
    assert.ok(Date.now() - startedAt < 500, 'deadline must bound non-cooperative transports');
  }
});

test('production smoke rejects response bodies above the configured decoded-byte limit', async () => {
  await assert.rejects(
    () => runProductionSmoke({
      baseUrl: 'https://backup.fearlesswallet.io',
      maxResponseBytes: 128,
      fetchImpl: routeFetch(smokeRoutes({
        'GET /api/passkey-backup/v1/health': () => jsonResponse(200, {
          ...health,
          padding: 'x'.repeat(512),
        }),
      })),
      authorizationProvider: testAuthorizationProvider,
    }),
    /response exceeded the 128-byte limit/,
  );
});

test('production smoke rejects misleading JSON media types and accepts registered structured suffixes', async () => {
  for (const contentType of [
    'text/application/json',
    'application/jsonp',
    'application/json, text/html',
  ]) {
    await assert.rejects(
      () => runProductionSmoke({
        baseUrl: 'https://backup.fearlesswallet.io',
        fetchImpl: routeFetch(smokeRoutes({
          'GET /api/passkey-backup/v1/health': () => jsonResponse(200, health, contentType),
        })),
        authorizationProvider: testAuthorizationProvider,
      }),
      /did not return JSON\. Content-Type:/,
    );
  }

  const result = await runProductionSmoke({
    baseUrl: 'https://backup.fearlesswallet.io',
    fetchImpl: routeFetch(smokeRoutes({
      'GET /api/passkey-backup/v1/health': () => jsonResponse(
        200,
        health,
        'application/health+json; charset="utf-8"',
      ),
    })),
    authorizationProvider: testAuthorizationProvider,
  });
  assert.equal(result.service, 'fearless-passkey-backup');
});

test('production smoke rejects noncanonical timeout and response-limit settings before fetch', async () => {
  for (const options of [
    { timeoutMs: '10ms' },
    { timeoutMs: 60_001 },
    { maxResponseBytes: '1e6' },
    { maxResponseBytes: 5_242_881 },
  ]) {
    let fetchCalled = false;
    await assert.rejects(
      () => runProductionSmoke({
        baseUrl: 'https://backup.fearlesswallet.io',
        ...options,
        fetchImpl: async () => {
          fetchCalled = true;
          return jsonResponse(200, health);
        },
      }),
      /must be an integer between 1 and/,
    );
    assert.equal(fetchCalled, false);
  }
});

test('production smoke rejects wrong health identity', async () => {
  await assert.rejects(
    () => runProductionSmoke({
      baseUrl: 'https://backup.fearlesswallet.io',
      fetchImpl: routeFetch(smokeRoutes({
        'GET /api/passkey-backup/v1/health': () => jsonResponse(200, {
          ...health,
          service: 'wrong-service',
        }),
      })),
      authorizationProvider: testAuthorizationProvider,
    }),
    /health response\.service must be fearless-passkey-backup/,
  );
});

test('production smoke reports HTTP body previews for deploy failures', async () => {
  await assert.rejects(
    () => runProductionSmoke({
      baseUrl: 'https://backup.fearlesswallet.io',
      fetchImpl: routeFetch(smokeRoutes({
        'GET /api/passkey-backup/v1/health': () => textResponse(503, 'deploy in progress'),
      })),
      authorizationProvider: testAuthorizationProvider,
    }),
    /GET \/api\/passkey-backup\/v1\/health expected HTTP 200, got 503\. Body preview: deploy in progress/,
  );
});

test('production smoke redacts token, password, API-key, and bearer values from response previews', async () => {
  await assert.rejects(
    () => runProductionSmoke({
      baseUrl: 'https://backup.fearlesswallet.io',
      fetchImpl: routeFetch(smokeRoutes({
        'GET /api/passkey-backup/v1/health': () => textResponse(
          503,
          '{"token":"body-token","password":"body-password","api_key":"body-key","authorization":"Bearer body-bearer"}',
          'application/json',
        ),
      })),
      authorizationProvider: testAuthorizationProvider,
    }),
    (error) => {
      const diagnostic = String(error);
      assert.match(diagnostic, /<redacted>/);
      for (const secret of ['body-token', 'body-password', 'body-key', 'body-bearer']) {
        assert.doesNotMatch(diagnostic, new RegExp(secret));
      }
      return true;
    },
  );
});

test('production smoke reports invalid JSON body previews', async () => {
  await assert.rejects(
    () => runProductionSmoke({
      baseUrl: 'https://backup.fearlesswallet.io',
      fetchImpl: routeFetch(smokeRoutes({
        'GET /api/passkey-backup/v1/health': () => textResponse(200, '{"ok":', 'application/json'),
      })),
      authorizationProvider: testAuthorizationProvider,
    }),
    /GET \/api\/passkey-backup\/v1\/health must return valid JSON\. Body preview: \{"ok":/,
  );
});

test('executable smoke grant helper receives exact binding on stdin without arguments', async (t) => {
  const directory = mkdtempSync(join(realpathSync.native(tmpdir()), 'passkey-smoke-helper-'));
  t.after(() => rmSync(directory, { recursive: true, force: true }));
  const helper = join(directory, 'grant-helper');
  writeFileSync(helper, `#!/usr/bin/env node
let input='';
process.stdin.on('data',(chunk)=>{input+=chunk});
process.stdin.on('end',()=>{const value=JSON.parse(input);process.stdout.write('grant.'+value.bodySha256+'\\n')});
`);
  chmodSync(helper, 0o700);
  const provider = createExecutableSmokeAuthorizationProvider(helper, { timeoutMs: 5_000 });
  const token = await provider({
    method: 'POST',
    path: '/api/passkey-backup/v1/registration/challenge',
    bodySha256: 'QkJCQkJCQkJCQkJCQkJCQkJCQkJCQkJCQkJCQkJCQkI',
  });
  assert.equal(token, 'grant.QkJCQkJCQkJCQkJCQkJCQkJCQkJCQkJCQkJCQkJCQkI');
});

test('smoke grant helper rejects symlinks, non-executables, writable files, extra output, and timeout', async (t) => {
  const directory = mkdtempSync(join(realpathSync.native(tmpdir()), 'passkey-smoke-helper-negative-'));
  t.after(() => rmSync(directory, { recursive: true, force: true }));
  const nonExecutable = join(directory, 'non-executable');
  writeFileSync(nonExecutable, '#!/usr/bin/env node\n');
  assert.throws(
    () => createExecutableSmokeAuthorizationProvider(nonExecutable),
    /non-symlink executable file/,
  );
  const link = join(directory, 'helper-link');
  symlinkSync(nonExecutable, link);
  assert.throws(
    () => createExecutableSmokeAuthorizationProvider(link),
    /non-symlink executable file/,
  );

  const realParent = join(directory, 'real-parent');
  mkdirSync(realParent);
  const parentHelper = join(realParent, 'helper');
  writeFileSync(parentHelper, '#!/usr/bin/env node\nprocess.stdout.write("token")\n');
  chmodSync(parentHelper, 0o700);
  const linkedParent = join(directory, 'linked-parent');
  symlinkSync(realParent, linkedParent);
  assert.throws(
    () => createExecutableSmokeAuthorizationProvider(join(linkedParent, 'helper')),
    /non-symlink executable file/,
  );

  const writable = join(directory, 'group-writable');
  writeFileSync(writable, '#!/usr/bin/env node\nprocess.stdout.write("token")\n');
  chmodSync(writable, 0o720);
  assert.throws(
    () => createExecutableSmokeAuthorizationProvider(writable),
    /must not be group- or world-writable/,
  );

  const context = {
    method: 'POST',
    path: '/api/passkey-backup/v1/registration/challenge',
    bodySha256: 'QkJCQkJCQkJCQkJCQkJCQkJCQkJCQkJCQkJCQkJCQkI',
  };
  const extraOutput = join(directory, 'extra-output');
  writeFileSync(extraOutput, '#!/usr/bin/env node\nprocess.stdout.write("token-one\\ntoken-two\\n")\n');
  chmodSync(extraOutput, 0o700);
  await assert.rejects(
    () => createExecutableSmokeAuthorizationProvider(extraOutput, { timeoutMs: 2_000 })(context),
    /smoke grant helper failed/,
  );

  const slow = join(directory, 'slow');
  writeFileSync(slow, '#!/usr/bin/env node\nsetTimeout(()=>process.stdout.write("too-late"),2000)\n');
  chmodSync(slow, 0o700);
  await assert.rejects(
    () => createExecutableSmokeAuthorizationProvider(slow, { timeoutMs: 700 })(context),
    /smoke grant helper failed/,
  );
});

test('production smoke fails closed before requests when the configured grant helper is missing', async () => {
  const previousHelper = process.env.PASSKEY_BACKUP_SMOKE_GRANT_HELPER;
  process.env.PASSKEY_BACKUP_SMOKE_GRANT_HELPER = '/definitely/missing/passkey-smoke-grant-helper';
  let fetchCalled = false;
  try {
    await assert.rejects(
      () => runProductionSmoke({
        baseUrl: 'https://backup.fearlesswallet.io',
        fetchImpl: async () => {
          fetchCalled = true;
          return jsonResponse(200, health);
        },
      }),
      /PASSKEY_BACKUP_SMOKE_GRANT_HELPER must be a readable executable file/,
    );
  } finally {
    if (previousHelper === undefined) delete process.env.PASSKEY_BACKUP_SMOKE_GRANT_HELPER;
    else process.env.PASSKEY_BACKUP_SMOKE_GRANT_HELPER = previousHelper;
  }
  assert.equal(fetchCalled, false);
});

test('production smoke reports network failures with deployment hints', async () => {
  await assert.rejects(
    () => runProductionSmoke({
      baseUrl: 'https://backup.fearlesswallet.io',
      fetchImpl: async () => {
        const error = new TypeError('fetch failed');
        error.cause = Object.assign(new Error('getaddrinfo ENOTFOUND backup.fearlesswallet.io'), {
          code: 'ENOTFOUND',
          syscall: 'getaddrinfo',
          hostname: 'backup.fearlesswallet.io',
        });
        throw error;
      },
    }),
    /GET \/api\/passkey-backup\/v1\/health request to https:\/\/backup\.fearlesswallet\.io failed: fetch failed; cause: getaddrinfo ENOTFOUND backup\.fearlesswallet\.io; code=ENOTFOUND, syscall=getaddrinfo, hostname=backup\.fearlesswallet\.io\. Verify backup\.fearlesswallet\.io DNS\/TLS\/routing and deploy services\/passkey-backup-challenge-service\./,
  );
});

test('production smoke redacts and bounds secrets in transport-error diagnostics', async () => {
  const transportError = new TypeError('fetch failed password=transport-password');
  transportError.cause = new Error(
    `upstream https://operator:transport-pass@backup.fearlesswallet.io/?api_key=transport-key Authorization: Bearer transport-bearer ${'x'.repeat(2_000)}`,
  );

  await assert.rejects(
    () => runProductionSmoke({
      baseUrl: 'https://backup.fearlesswallet.io',
      fetchImpl: async () => { throw transportError; },
    }),
    (error) => {
      const diagnostic = String(error);
      assert.match(diagnostic, /<redacted>/);
      for (const secret of ['transport-password', 'transport-pass', 'transport-key', 'transport-bearer']) {
        assert.doesNotMatch(diagnostic, new RegExp(secret));
      }
      assert.ok(diagnostic.length < 1_000, 'transport diagnostic must stay bounded');
      return true;
    },
  );
});

test('production smoke rejects unsupported registration response fields', async () => {
  await assert.rejects(
    () => runProductionSmoke({
      baseUrl: 'https://backup.fearlesswallet.io',
      fetchImpl: routeFetch(smokeRoutes({
        'POST /api/passkey-backup/v1/registration/challenge': (input, options) => {
          const body = JSON.parse(options.body);
          return jsonResponse(200, {
            ...registration,
            userName: body.accountName,
            displayName: body.displayName,
            secret: 'must-not-appear',
          });
        },
      })),
      authorizationProvider: testAuthorizationProvider,
    }),
    /registration challenge response contains unsupported field secret/,
  );
});

test('production smoke rejects noncanonical 32-byte registration challenge and userId encodings', async () => {
  const canonicalChallenge = registration.challenge;
  const invalidEncodings = [
    ['42 characters', canonicalChallenge.slice(0, -1)],
    ['44 characters', `${canonicalChallenge}A`],
    ['padding', `${canonicalChallenge}=`],
    ['invalid character', `${canonicalChallenge.slice(0, -1)}*`],
    ['noncanonical alias', `${canonicalChallenge.slice(0, -1)}F`],
  ];

  for (const field of ['challenge', 'userId']) {
    for (const [description, encoded] of invalidEncodings) {
      await assert.rejects(
        () => runProductionSmoke({
          baseUrl: 'https://backup.fearlesswallet.io',
          fetchImpl: routeFetch(smokeRoutes({
            'POST /api/passkey-backup/v1/registration/challenge': (input, options) => {
              const body = JSON.parse(options.body);
              return jsonResponse(200, {
                ...registration,
                userName: body.accountName,
                displayName: body.displayName,
                [field]: encoded,
              });
            },
          })),
          authorizationProvider: testAuthorizationProvider,
        }),
        new RegExp(`registration ${field} must be canonical unpadded base64url for 32 bytes`),
        `${field}: ${description}`,
      );
    }
  }
});

test('production smoke rejects missing assertion challenge route contract', async () => {
  await assert.rejects(
    () => runProductionSmoke({
      baseUrl: 'https://backup.fearlesswallet.io',
      fetchImpl: routeFetch(smokeRoutes({
        'POST /api/passkey-backup/v1/assertion/challenge': () => jsonResponse(
          200,
          serviceError('credential_not_registered'),
        ),
      })),
      authorizationProvider: testAuthorizationProvider,
    }),
    /assertion\/challenge expected HTTP 404, got 200/,
  );
});

test('production smoke rejects completion routes with wrong public error codes', async () => {
  await assert.rejects(
    () => runProductionSmoke({
      baseUrl: 'https://backup.fearlesswallet.io',
      fetchImpl: routeFetch(smokeRoutes({
        'POST /api/passkey-backup/v1/registration/complete': () => jsonResponse(
          404,
          serviceError('invalid_request'),
        ),
      })),
      authorizationProvider: testAuthorizationProvider,
    }),
    /registration completion error must be credential_type_mismatch/,
  );
});

test('production smoke rejects lifecycle routes with leaked or non-idempotent response drift', async () => {
  await assert.rejects(
    () => runProductionSmoke({
      baseUrl: 'https://backup.fearlesswallet.io',
      fetchImpl: routeFetch(smokeRoutes({
        'POST /api/passkey-backup/v1/credentials/revoke': (input, options) => {
          const body = JSON.parse(options.body);
          return jsonResponse(200, {
            storageKey: body.storageKey,
            credentialId: body.credentialId,
            remainingCredentials: 0,
            rpId: 'fearlesswallet.io',
            schemaVersion: 1,
            publicKey: 'must-not-leak',
          });
        },
      })),
      authorizationProvider: testAuthorizationProvider,
    }),
    /credential revoke response contains unsupported field publicKey/,
  );

  await assert.rejects(
    () => runProductionSmoke({
      baseUrl: 'https://backup.fearlesswallet.io',
      fetchImpl: routeFetch(smokeRoutes({
        'POST /api/passkey-backup/v1/credentials/revoke-all': (input, options) => {
          const body = JSON.parse(options.body);
          return jsonResponse(200, {
            storageKey: body.storageKey,
            remainingCredentials: 1,
            rpId: 'fearlesswallet.io',
            schemaVersion: 1,
          });
        },
      })),
      authorizationProvider: testAuthorizationProvider,
    }),
    /credential revoke-all must report zero remaining credentials/,
  );
});
