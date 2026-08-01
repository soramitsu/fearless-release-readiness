import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import {
  closeSync,
  fsyncSync,
  mkdirSync,
  mkdtempSync,
  openSync,
  readFileSync,
  renameSync,
  rmSync,
  symlinkSync,
  writeFileSync,
} from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import test from 'node:test';
import { base64UrlEncode } from '../src/base64url.js';
import { authorizationSubjectHash } from '../src/authorization.js';
import { createPasskeyBackupChallengeService } from '../src/service.js';
import { createServer, parseIntegerSetting, parseNodeEnvironment } from '../src/server.js';
import {
  createPasskeyChallengeStore,
  FileBackedPasskeyChallengeStore,
  InMemoryPasskeyChallengeStore,
} from '../src/store.js';
import { parseAllowedOrigins, RP_ID, SCHEMA_VERSION } from '../src/validation.js';
import {
  authenticationCredential,
  createAuthenticator,
  registrationCredential,
} from './webauthn-fixture.js';

const ORIGIN = 'https://wallet.example.test';
const ANDROID_ORIGIN = `android:apk-key-hash:${base64UrlEncode(Buffer.alloc(32, 0xa5))}`;

function deterministicRandomBytes() {
  let seed = 1;
  return (size) => {
    const buffer = Buffer.alloc(size);
    for (let i = 0; i < size; i += 1) buffer[i] = (seed + i) % 256;
    seed = (seed + 17) % 256;
    return buffer;
  };
}

function makeService(options = {}) {
  return createPasskeyBackupChallengeService({
    store: options.store ?? new InMemoryPasskeyChallengeStore(options.storeOptions),
    allowedOrigins: options.allowedOrigins ?? new Set([ORIGIN, ANDROID_ORIGIN]),
    randomBytes: options.randomBytes ?? deterministicRandomBytes(),
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

function registrationRequest(overrides = {}) {
  return {
    walletId: 'wallet-123456',
    accountName: 'alice@example.com',
    displayName: 'Alice',
    rpId: RP_ID,
    schemaVersion: SCHEMA_VERSION,
    ...overrides,
  };
}

function registrationCompletion(registration, authenticator, credentialOptions = {}) {
  return {
    registrationId: registration.registrationId,
    rpId: RP_ID,
    credential: registrationCredential(registration.challenge, authenticator, {
      origin: ANDROID_ORIGIN,
      ...credentialOptions,
    }),
  };
}

async function registerCredential(service, authenticator = createAuthenticator(), credentialOptions = {}) {
  const registration = service.createRegistrationChallenge(registrationRequest());
  const result = await service.completeRegistration(
    registrationCompletion(registration, authenticator, credentialOptions),
  );
  return { registration, result, authenticator };
}

function authorization(subject, platform = 'android') {
  return {
    subjectHash: authorizationSubjectHash(subject),
    platform,
  };
}

async function registerCredentialAs(
  service,
  authorizationContext,
  authenticator = createAuthenticator(),
  requestOverrides = {},
) {
  const registration = service.createRegistrationChallenge(
    registrationRequest(requestOverrides),
    authorizationContext,
  );
  const result = await service.completeRegistration(
    registrationCompletion(registration, authenticator, {
      origin: authorizationContext.platform === 'android' ? ANDROID_ORIGIN : ORIGIN,
    }),
    authorizationContext,
  );
  return { registration, result, authenticator };
}

function assertionCompletion(assertion, authenticator, userHandle, options = {}) {
  return {
    assertionId: assertion.assertionId,
    rpId: RP_ID,
    credential: authenticationCredential(
      assertion.challenge,
      authenticator,
      userHandle,
      { origin: ANDROID_ORIGIN, ...options },
    ),
  };
}

async function assertServiceRejects(promise, code, status) {
  await assert.rejects(promise, (error) => {
    assert.equal(error.code, code);
    if (status !== undefined) assert.equal(error.status, status);
    return true;
  });
}

function assertServiceError(fn, code, status) {
  assert.throws(fn, (error) => {
    assert.equal(error.code, code);
    if (status !== undefined) assert.equal(error.status, status);
    return true;
  });
}

function tempDirectory(t) {
  const directory = mkdtempSync(join(tmpdir(), 'fearless-passkey-store-'));
  t.after(() => rmSync(directory, { recursive: true, force: true }));
  return directory;
}

function tempCredentialStoreFile(t) {
  return join(tempDirectory(t), 'credentials.json');
}

async function withServer(t, options, run) {
  const server = createServer({
    ...options,
    requestAuthorizer: options.requestAuthorizer ?? TEST_REQUEST_AUTHORIZER,
  });
  await new Promise((resolve, reject) => {
    server.once('error', reject);
    server.listen(0, '127.0.0.1', resolve);
  });
  t.after(() => new Promise((resolve) => server.close(resolve)));
  const address = server.address();
  return run(`http://127.0.0.1:${address.port}`);
}

async function postJson(baseUrl, path, body, headers = {}) {
  const response = await fetch(`${baseUrl}${path}`, {
    method: 'POST',
    headers: {
      'content-type': 'application/json',
      authorization: 'Bearer test-authorization-token',
      ...headers,
    },
    body: JSON.stringify(body),
  });
  return { response, body: await response.json() };
}

test('health returns strict service identity', () => {
  assert.deepEqual(makeService().health(), {
    ok: true,
    service: 'fearless-passkey-backup',
    rpId: RP_ID,
    schemaVersion: SCHEMA_VERSION,
  });
});

test('registration and assertion verify real ES256 WebAuthn cryptography', async () => {
  const service = makeService();
  const { registration, result, authenticator } = await registerCredential(service);
  const assertion = service.createAssertionChallenge({
    storageKey: result.storageKey,
    rpId: RP_ID,
    schemaVersion: SCHEMA_VERSION,
  });
  const assertionResult = await service.completeAssertion(
    assertionCompletion(assertion, authenticator, registration.userId),
  );
  assert.deepEqual(assertionResult, result);
});

test('registration and assertion verify real RS256 WebAuthn cryptography', async () => {
  const service = makeService();
  const authenticator = createAuthenticator('fearless-test-rs256-passkey', { algorithm: -257 });
  const { registration, result } = await registerCredential(service, authenticator);
  const assertion = service.createAssertionChallenge({
    storageKey: result.storageKey,
    rpId: RP_ID,
    schemaVersion: SCHEMA_VERSION,
  });
  const assertionResult = await service.completeAssertion(
    assertionCompletion(assertion, authenticator, registration.userId),
  );
  assert.deepEqual(assertionResult, result);
});

test('file-backed store persists public key, user handle, counter, and metadata across restart', async (t) => {
  const credentialStoreFile = tempCredentialStoreFile(t);
  const service = makeService({ store: new FileBackedPasskeyChallengeStore({ credentialStoreFile }) });
  const { registration, result, authenticator } = await registerCredential(service);

  const persistedAfterRegistration = JSON.parse(readFileSync(credentialStoreFile, 'utf8'));
  assert.equal(readFileSync(credentialStoreFile, 'utf8').includes('local-test-wallet-owner'), false);
  assert.equal(persistedAfterRegistration.schemaVersion, 3);
  const persistedCredential = persistedAfterRegistration.credentialsByStorageKey[0].credentials[0];
  assert.equal(persistedCredential.id, base64UrlEncode(authenticator.credentialId));
  assert.equal(persistedCredential.userId, registration.userId);
  assert.equal(persistedCredential.counter, 0);
  assert.equal(persistedCredential.deviceType, 'singleDevice');
  assert.equal(persistedCredential.backedUp, false);
  assert.equal(persistedCredential.aaguid, '00000000-0000-0000-0000-000000000000');
  assert.equal(persistedCredential.registrationPlatform, 'android');
  assert.equal(
    persistedAfterRegistration.credentialsByStorageKey[0].ownerSubjectHash,
    authorizationSubjectHash('local-test-wallet-owner'),
  );
  assert.deepEqual(persistedCredential.transports, ['internal']);
  assert.ok(persistedCredential.publicKey.length > 32);

  const restartedService = makeService({
    store: new FileBackedPasskeyChallengeStore({ credentialStoreFile }),
  });
  const assertion = restartedService.createAssertionChallenge({
    storageKey: result.storageKey,
    rpId: RP_ID,
    schemaVersion: SCHEMA_VERSION,
  });
  await restartedService.completeAssertion(
    assertionCompletion(assertion, authenticator, registration.userId, { counter: 7 }),
  );
  const persistedAfterAssertion = JSON.parse(readFileSync(credentialStoreFile, 'utf8'));
  assert.equal(persistedAfterAssertion.credentialsByStorageKey[0].credentials[0].counter, 7);
});

test('credential lifecycle lists only bounded public descriptors and supports a stable cross-platform owner', async () => {
  const service = makeService();
  const ownerAndroid = authorization('fearless-wallet-owner:lifecycle-descriptors', 'android');
  const ownerIos = authorization('fearless-wallet-owner:lifecycle-descriptors', 'ios');
  const { result, authenticator } = await registerCredentialAs(service, ownerAndroid);

  const listed = service.listCredentials({
    storageKey: result.storageKey,
    rpId: RP_ID,
    schemaVersion: SCHEMA_VERSION,
  }, ownerIos);
  assert.equal(listed.storageKey, result.storageKey);
  assert.equal(listed.rpId, RP_ID);
  assert.equal(listed.schemaVersion, SCHEMA_VERSION);
  assert.deepEqual(listed.credentials, [{
    id: base64UrlEncode(authenticator.credentialId),
    aaguid: '00000000-0000-0000-0000-000000000000',
    registrationPlatform: 'android',
    deviceType: 'singleDevice',
    backedUp: false,
    transports: ['internal'],
  }]);
  assert.equal(JSON.stringify(listed).includes('publicKey'), false);
  assert.equal(JSON.stringify(listed).includes('userId'), false);
  assert.equal(JSON.stringify(listed).includes('counter'), false);
  assert.equal(service.revokeCredential({
    storageKey: result.storageKey,
    credentialId: base64UrlEncode(authenticator.credentialId),
    rpId: RP_ID,
    schemaVersion: SCHEMA_VERSION,
  }, ownerIos).remainingCredentials, 0);
});

test('credential lifecycle rejects cross-subject and invalid-platform access without mutating credentials', async () => {
  const service = makeService();
  const owner = authorization('fearless-wallet-owner:lifecycle-owner');
  const attacker = authorization('fearless-wallet-owner:lifecycle-attacker', 'ios');
  const { result, authenticator } = await registerCredentialAs(service, owner);
  const listRequest = { storageKey: result.storageKey, rpId: RP_ID, schemaVersion: SCHEMA_VERSION };
  const revokeRequest = {
    ...listRequest,
    credentialId: base64UrlEncode(authenticator.credentialId),
  };

  for (const operation of [
    () => service.listCredentials(listRequest, attacker),
    () => service.revokeCredential(revokeRequest, attacker),
    () => service.revokeAllCredentials(listRequest, attacker),
  ]) {
    assertServiceError(operation, 'request_authorization_failed', 403);
  }
  for (const operation of [
    () => service.listCredentials(listRequest, { ...owner, platform: 'web' }),
    () => service.revokeCredential(revokeRequest, { ...owner, platform: '' }),
    () => service.revokeAllCredentials(listRequest, { ...owner, platform: 'ANDROID' }),
  ]) {
    assertServiceError(operation, 'request_authorization_failed', 401);
  }
  assert.equal(service.listCredentials(listRequest, owner).credentials.length, 1);
});

test('credential revocation is idempotent for unknown IDs and retains a final-owner tombstone', async () => {
  const service = makeService();
  const owner = authorization('fearless-wallet-owner:lifecycle-idempotent');
  const attacker = authorization('fearless-wallet-owner:lifecycle-idempotent-attacker');
  const { result, authenticator } = await registerCredentialAs(service, owner);
  const unknownCredentialId = base64UrlEncode(Buffer.alloc(32, 0x91));

  assert.equal(service.revokeCredential({
    storageKey: result.storageKey,
    credentialId: unknownCredentialId,
    rpId: RP_ID,
    schemaVersion: SCHEMA_VERSION,
  }, owner).remainingCredentials, 1);
  assert.equal(service.revokeCredential({
    storageKey: 'storage:unknown-lifecycle',
    credentialId: unknownCredentialId,
    rpId: RP_ID,
    schemaVersion: SCHEMA_VERSION,
  }, attacker).remainingCredentials, 0);

  const request = {
    storageKey: result.storageKey,
    credentialId: base64UrlEncode(authenticator.credentialId),
    rpId: RP_ID,
    schemaVersion: SCHEMA_VERSION,
  };
  assert.equal(service.revokeCredential(request, owner).remainingCredentials, 0);
  assert.equal(service.revokeCredential(request, owner).remainingCredentials, 0);
  assert.deepEqual(service.listCredentials({
    storageKey: result.storageKey,
    rpId: RP_ID,
    schemaVersion: SCHEMA_VERSION,
  }, owner).credentials, []);
  assertServiceError(
    () => service.revokeAllCredentials({
      storageKey: result.storageKey,
      rpId: RP_ID,
      schemaVersion: SCHEMA_VERSION,
    }, attacker),
    'request_authorization_failed',
    403,
  );
});

test('revoke-all tombstone survives restart, denies takeover, and permits same-owner registration', async (t) => {
  const credentialStoreFile = tempCredentialStoreFile(t);
  const owner = authorization('fearless-wallet-owner:lifecycle-restart');
  const attacker = authorization('fearless-wallet-owner:lifecycle-restart-attacker');
  const service = makeService({ store: new FileBackedPasskeyChallengeStore({ credentialStoreFile }) });
  const { result } = await registerCredentialAs(service, owner);
  const lifecycleRequest = {
    storageKey: result.storageKey,
    rpId: RP_ID,
    schemaVersion: SCHEMA_VERSION,
  };
  assert.equal(service.revokeAllCredentials(lifecycleRequest, owner).remainingCredentials, 0);

  const persisted = JSON.parse(readFileSync(credentialStoreFile, 'utf8'));
  assert.equal(persisted.schemaVersion, 3);
  assert.equal(persisted.credentialsByStorageKey.length, 1);
  assert.deepEqual(persisted.credentialsByStorageKey[0].credentials, []);
  assert.equal(persisted.credentialsByStorageKey[0].ownerSubjectHash, owner.subjectHash);

  const restarted = makeService({ store: new FileBackedPasskeyChallengeStore({ credentialStoreFile }) });
  assert.deepEqual(restarted.listCredentials(lifecycleRequest, owner).credentials, []);
  assertServiceError(
    () => restarted.createRegistrationChallenge(registrationRequest(), attacker),
    'request_authorization_failed',
    403,
  );
  const replacement = await registerCredentialAs(
    restarted,
    owner,
    createAuthenticator('same-owner-replacement'),
  );
  assert.equal(replacement.result.storageKey, result.storageKey);
  assert.equal(restarted.listCredentials(lifecycleRequest, owner).credentials.length, 1);
});

test('unknown revocation does not persist a phantom owner or block later first registration', async (t) => {
  const credentialStoreFile = tempCredentialStoreFile(t);
  const owner = authorization('fearless-wallet-owner:lifecycle-unknown-revoke');
  const store = new FileBackedPasskeyChallengeStore({ credentialStoreFile });
  const service = makeService({ store });
  const pending = service.createRegistrationChallenge(registrationRequest(), owner);
  const request = {
    storageKey: pending.storageKey,
    rpId: RP_ID,
    schemaVersion: SCHEMA_VERSION,
  };
  assert.equal(service.revokeAllCredentials(request, owner).remainingCredentials, 0);
  assert.equal(service.revokeCredential({
    ...request,
    credentialId: base64UrlEncode(Buffer.alloc(32, 0x81)),
  }, owner).remainingCredentials, 0);
  assert.deepEqual(
    JSON.parse(readFileSync(credentialStoreFile, 'utf8')).credentialsByStorageKey,
    [],
  );

  const restarted = makeService({
    store: new FileBackedPasskeyChallengeStore({ credentialStoreFile }),
  });
  assert.doesNotThrow(() => restarted.createRegistrationChallenge(
    registrationRequest(),
    authorization('fearless-wallet-owner:lifecycle-new-owner'),
  ));
});

test('single revoke handles the last of multiple credentials and leaves the remaining credential usable', async () => {
  const service = makeService();
  const owner = authorization('fearless-wallet-owner:lifecycle-multiple');
  const first = await registerCredentialAs(service, owner, createAuthenticator('lifecycle-first'));
  const second = await registerCredentialAs(service, owner, createAuthenticator('lifecycle-second'));
  assert.equal(first.result.storageKey, second.result.storageKey);
  const baseRequest = {
    storageKey: first.result.storageKey,
    rpId: RP_ID,
    schemaVersion: SCHEMA_VERSION,
  };
  assert.equal(service.listCredentials(baseRequest, owner).credentials.length, 2);
  assert.equal(service.revokeCredential({
    ...baseRequest,
    credentialId: base64UrlEncode(first.authenticator.credentialId),
  }, owner).remainingCredentials, 1);

  const assertion = service.createAssertionChallenge(baseRequest, owner);
  await service.completeAssertion(
    assertionCompletion(assertion, second.authenticator, second.registration.userId),
    owner,
  );
  assert.equal(service.revokeCredential({
    ...baseRequest,
    credentialId: base64UrlEncode(second.authenticator.credentialId),
  }, owner).remainingCredentials, 0);
  assertServiceError(
    () => service.createAssertionChallenge(baseRequest, owner),
    'credential_not_registered',
    404,
  );
});

test('revocation wins safely against pending assertion and in-flight registration', async () => {
  const service = makeService();
  const owner = authorization('fearless-wallet-owner:lifecycle-races');
  const first = await registerCredentialAs(service, owner, createAuthenticator('lifecycle-race-first'));
  const lifecycleRequest = {
    storageKey: first.result.storageKey,
    rpId: RP_ID,
    schemaVersion: SCHEMA_VERSION,
  };

  const assertion = service.createAssertionChallenge(lifecycleRequest, owner);
  const completingAssertion = service.completeAssertion(
    assertionCompletion(assertion, first.authenticator, first.registration.userId, { counter: 1 }),
    owner,
  );
  assert.equal(service.revokeAllCredentials(lifecycleRequest, owner).remainingCredentials, 0);
  await assertServiceRejects(completingAssertion, 'credential_not_registered', 403);

  const restored = await registerCredentialAs(
    service,
    owner,
    createAuthenticator('lifecycle-race-restored'),
  );
  const stalePending = service.createRegistrationChallenge(registrationRequest(), owner);
  assert.equal(service.revokeAllCredentials(lifecycleRequest, owner).remainingCredentials, 0);
  await assertServiceRejects(
    service.completeRegistration(
      registrationCompletion(stalePending, createAuthenticator('lifecycle-race-stale')),
      owner,
    ),
    'unknown_or_expired_registration',
    404,
  );

  const active = await registerCredentialAs(
    service,
    owner,
    createAuthenticator('lifecycle-race-active'),
  );
  const inFlight = service.createRegistrationChallenge(registrationRequest(), owner);
  const completingRegistration = service.completeRegistration(
    registrationCompletion(inFlight, createAuthenticator('lifecycle-race-inflight')),
    owner,
  );
  assert.equal(service.revokeAllCredentials(lifecycleRequest, owner).remainingCredentials, 0);
  await assertServiceRejects(
    completingRegistration,
    'credential_lifecycle_conflict',
    409,
  );
  assert.equal(restored.result.storageKey, lifecycleRequest.storageKey);
  assert.equal(active.result.storageKey, lifecycleRequest.storageKey);
  assert.deepEqual(service.listCredentials(lifecycleRequest, owner).credentials, []);
});

test('unknown-owner revoke-all cannot interfere with another subject claimed registration', async () => {
  const service = makeService();
  const owner = authorization('fearless-wallet-owner:lifecycle-first-inflight');
  const attacker = authorization('fearless-wallet-owner:lifecycle-first-inflight-attacker', 'ios');
  const registration = service.createRegistrationChallenge(registrationRequest(), owner);
  const completing = service.completeRegistration(
    registrationCompletion(
      registration,
      createAuthenticator('lifecycle-first-inflight'),
      { origin: ANDROID_ORIGIN },
    ),
    owner,
  );
  const lifecycleRequest = {
    storageKey: registration.storageKey,
    rpId: RP_ID,
    schemaVersion: SCHEMA_VERSION,
  };

  assert.equal(service.revokeAllCredentials(lifecycleRequest, attacker).remainingCredentials, 0);
  const completed = await completing;
  assert.equal(completed.storageKey, registration.storageKey);
  assert.equal(service.listCredentials(lifecycleRequest, owner).credentials.length, 1);
});

test('revoke-all cancels the authorized subject pending first-registration challenge without claiming storage', async () => {
  const service = makeService();
  const owner = authorization('fearless-wallet-owner:lifecycle-pending-first');
  const attacker = authorization('fearless-wallet-owner:lifecycle-pending-first-attacker');
  const pending = service.createRegistrationChallenge(registrationRequest(), owner);
  const lifecycleRequest = {
    storageKey: pending.storageKey,
    rpId: RP_ID,
    schemaVersion: SCHEMA_VERSION,
  };

  // A different subject must not cancel the owner's unclaimed registration.
  assert.equal(service.revokeAllCredentials(lifecycleRequest, attacker).remainingCredentials, 0);
  const secondPending = service.createRegistrationChallenge(registrationRequest(), owner);
  assert.equal(service.revokeAllCredentials(lifecycleRequest, owner).remainingCredentials, 0);
  for (const registration of [pending, secondPending]) {
    await assertServiceRejects(
      service.completeRegistration(
        registrationCompletion(registration, createAuthenticator(`cancelled-${registration.registrationId}`)),
        owner,
      ),
      'unknown_or_expired_registration',
      404,
    );
  }
  assertServiceError(
    () => service.listCredentials(lifecycleRequest, owner),
    'credential_storage_not_registered',
    404,
  );
});

test('cancelled first-registration churn does not retain unbounded mutation-version keys', () => {
  const store = new InMemoryPasskeyChallengeStore({ maxCeremonies: 4 });
  const service = makeService({ store });
  const owner = authorization('fearless-wallet-owner:lifecycle-churn');

  for (let index = 0; index < 200; index += 1) {
    const pending = service.createRegistrationChallenge({
      ...registrationRequest(),
      walletId: `wallet:lifecycle-churn-${index}`,
      accountName: `lifecycle-churn-${index}@fearlesswallet.io`,
    }, owner);
    assert.equal(service.revokeAllCredentials({
      storageKey: pending.storageKey,
      rpId: RP_ID,
      schemaVersion: SCHEMA_VERSION,
    }, owner).remainingCredentials, 0);
  }

  assert.equal(store.registrationCeremonies.size, 0);
  assert.equal(store.inFlightRegistrationsByStorageKey.size, 0);
  assert.equal(store.credentialMutationVersions.size, 0);
});

test('claimed registrations count toward capacity and release capacity after completion', async () => {
  const store = new InMemoryPasskeyChallengeStore({ maxCeremonies: 1 });
  const service = makeService({ store });
  const owner = authorization('fearless-wallet-owner:lifecycle-inflight-capacity');
  const registration = service.createRegistrationChallenge(registrationRequest(), owner);
  const completing = service.completeRegistration(
    registrationCompletion(registration, createAuthenticator('lifecycle-inflight-capacity')),
    owner,
  );

  assertServiceError(
    () => service.createRegistrationChallenge(registrationRequest(), owner),
    'ceremony_store_full',
    503,
  );
  await completing;
  assert.equal(store.inFlightRegistrationsByStorageKey.size, 0);
  assert.doesNotThrow(() => service.createRegistrationChallenge(registrationRequest(), owner));
});

test('failed durable revocation does not mutate the in-memory credential state', async (t) => {
  const directory = tempDirectory(t);
  const credentialStoreFile = join(directory, 'credentials.json');
  const owner = authorization('fearless-wallet-owner:lifecycle-write-failure');
  const store = new FileBackedPasskeyChallengeStore({ credentialStoreFile });
  const service = makeService({ store });
  const { result } = await registerCredentialAs(service, owner);
  rmSync(credentialStoreFile);
  mkdirSync(credentialStoreFile);

  assertServiceError(
    () => service.revokeAllCredentials({
      storageKey: result.storageKey,
      rpId: RP_ID,
      schemaVersion: SCHEMA_VERSION,
    }, owner),
    'credential_store_unavailable',
    500,
  );
  assert.equal(store.hasAnyCredential(result.storageKey), true);
});

test('post-rename fsync and close failures keep durable and in-memory state aligned', async (t) => {
  const root = tempDirectory(t);

  for (const failurePoint of ['directory-fsync', 'directory-close']) {
    const directory = join(root, failurePoint);
    const credentialStoreFile = join(directory, 'credentials.json');
    let armed = false;
    let replacementRenamed = false;
    let directoryDescriptor;
    const fileOperations = {
      openSync(path, flags, mode) {
        const descriptor = openSync(path, flags, mode);
        if (armed && replacementRenamed && path === directory && flags === 'r') {
          directoryDescriptor = descriptor;
        }
        return descriptor;
      },
      renameSync(source, destination) {
        renameSync(source, destination);
        if (armed) replacementRenamed = true;
      },
      fsyncSync(descriptor) {
        if (armed && failurePoint === 'directory-fsync' && descriptor === directoryDescriptor) {
          throw new Error('injected post-rename directory fsync failure');
        }
        fsyncSync(descriptor);
      },
      closeSync(descriptor) {
        if (armed && failurePoint === 'directory-close' && descriptor === directoryDescriptor) {
          closeSync(descriptor);
          throw new Error('injected post-rename directory close failure');
        }
        closeSync(descriptor);
      },
    };
    const store = new FileBackedPasskeyChallengeStore({
      credentialStoreFile,
      fileOperations,
    });
    const service = makeService({ store });
    const owner = authorization(`fearless-wallet-owner:${failurePoint}`);
    const registration = service.createRegistrationChallenge(registrationRequest(), owner);
    armed = true;

    await assertServiceRejects(
      service.completeRegistration(
        registrationCompletion(
          registration,
          createAuthenticator(`post-rename-${failurePoint}`),
          { origin: ANDROID_ORIGIN },
        ),
        owner,
      ),
      'credential_store_unavailable',
      500,
    );

    assert.equal(store.hasAnyCredential(registration.storageKey), true, failurePoint);
    const restarted = new FileBackedPasskeyChallengeStore({ credentialStoreFile });
    assert.equal(restarted.hasAnyCredential(registration.storageKey), true, failurePoint);
    const persisted = JSON.parse(readFileSync(credentialStoreFile, 'utf8'));
    assert.equal(persisted.credentialsByStorageKey[0].storageKey, registration.storageKey);
  }
});

test('file-backed store keeps pending ceremonies transient across restart', async (t) => {
  const credentialStoreFile = tempCredentialStoreFile(t);
  const service = makeService({ store: new FileBackedPasskeyChallengeStore({ credentialStoreFile }) });
  const registration = service.createRegistrationChallenge(registrationRequest());
  const restartedService = makeService({
    store: new FileBackedPasskeyChallengeStore({ credentialStoreFile }),
  });
  await assertServiceRejects(
    restartedService.completeRegistration(
      registrationCompletion(registration, createAuthenticator()),
    ),
    'unknown_or_expired_registration',
    404,
  );
});

test('file-backed store rejects corrupted, legacy, unsupported, duplicate, and symlink stores', (t) => {
  const directory = tempDirectory(t);
  const storedUserId = (storageKey) => createHash('sha256')
    .update(`user\0${storageKey}`)
    .digest('base64url');
  const validCredential = {
    id: base64UrlEncode(Buffer.alloc(32, 1)),
    publicKey: base64UrlEncode(Buffer.alloc(77, 2)),
    userId: storedUserId('storage:valid-key'),
    counter: 0,
    deviceType: 'singleDevice',
    backedUp: false,
    aaguid: '00000000-0000-0000-0000-000000000000',
    registrationPlatform: 'android',
    transports: ['internal'],
  };
  const ownerSubjectHash = base64UrlEncode(Buffer.alloc(32, 4));
  const fixtures = [
    ['invalid-json', '{not-json'],
    ['legacy-schema', JSON.stringify({ schemaVersion: 2, credentialsByStorageKey: [] })],
    ['unknown-field', JSON.stringify({ schemaVersion: 3, credentialsByStorageKey: [], secret: true })],
    ['bad-public-key', JSON.stringify({
      schemaVersion: 3,
      credentialsByStorageKey: [{
        storageKey: 'storage:valid-key', ownerSubjectHash,
        credentials: [{ ...validCredential, publicKey: '***' }],
      }],
    })],
    ['duplicate-id', JSON.stringify({
      schemaVersion: 3,
      credentialsByStorageKey: [
        {
          storageKey: 'storage:first-key',
          ownerSubjectHash,
          credentials: [{ ...validCredential, userId: storedUserId('storage:first-key') }],
        },
        {
          storageKey: 'storage:second-key',
          ownerSubjectHash,
          credentials: [{ ...validCredential, userId: storedUserId('storage:second-key') }],
        },
      ],
    })],
    ['counter-overflow', JSON.stringify({
      schemaVersion: 3,
      credentialsByStorageKey: [{
        storageKey: 'storage:valid-key', ownerSubjectHash,
        credentials: [{ ...validCredential, counter: Number.MAX_SAFE_INTEGER + 1 }],
      }],
    })],
    ['bad-aaguid', JSON.stringify({
      schemaVersion: 3,
      credentialsByStorageKey: [{
        storageKey: 'storage:valid-key', ownerSubjectHash,
        credentials: [{ ...validCredential, aaguid: 'NOT-A-UUID' }],
      }],
    })],
    ['impossible-backup-flags', JSON.stringify({
      schemaVersion: 3,
      credentialsByStorageKey: [{
        storageKey: 'storage:valid-key', ownerSubjectHash,
        credentials: [{ ...validCredential, backedUp: true }],
      }],
    })],
    ['tombstone-missing-owner', JSON.stringify({
      schemaVersion: 3,
      credentialsByStorageKey: [{ storageKey: 'storage:valid-key', credentials: [] }],
    })],
    ['tombstone-invalid-owner', JSON.stringify({
      schemaVersion: 3,
      credentialsByStorageKey: [{
        storageKey: 'storage:valid-key', ownerSubjectHash: 'not-a-sha256-digest', credentials: [],
      }],
    })],
    ['duplicate-tombstone-storage', JSON.stringify({
      schemaVersion: 3,
      credentialsByStorageKey: [
        { storageKey: 'storage:valid-key', ownerSubjectHash, credentials: [] },
        { storageKey: 'storage:valid-key', ownerSubjectHash, credentials: [] },
      ],
    })],
    ['tombstone-non-array-credentials', JSON.stringify({
      schemaVersion: 3,
      credentialsByStorageKey: [{
        storageKey: 'storage:valid-key', ownerSubjectHash, credentials: null,
      }],
    })],
  ];

  for (const [name, contents] of fixtures) {
    const file = join(directory, `${name}.json`);
    writeFileSync(file, contents);
    assertServiceError(
      () => new FileBackedPasskeyChallengeStore({ credentialStoreFile: file }),
      'credential_store_invalid',
      500,
    );
  }

  const target = join(directory, 'target.json');
  writeFileSync(target, JSON.stringify({ schemaVersion: 3, credentialsByStorageKey: [] }));
  const link = join(directory, 'credentials-link.json');
  symlinkSync(target, link);
  assertServiceError(
    () => new FileBackedPasskeyChallengeStore({ credentialStoreFile: link }),
    'credential_store_invalid',
    500,
  );
});

test('file-backed store rejects unwritable path and does not retain failed writes', async (t) => {
  const directory = tempDirectory(t);
  const blockedParent = join(directory, 'blocked-parent');
  writeFileSync(blockedParent, 'not-a-directory');
  assertServiceError(
    () => new FileBackedPasskeyChallengeStore({ credentialStoreFile: join(blockedParent, 'credentials.json') }),
    'credential_store_unavailable',
    500,
  );

  const credentialStoreDirectory = join(directory, 'credential-store');
  const credentialStoreFile = join(credentialStoreDirectory, 'credentials.json');
  mkdirSync(credentialStoreDirectory);
  const store = new FileBackedPasskeyChallengeStore({ credentialStoreFile });
  const service = makeService({ store });
  const registration = service.createRegistrationChallenge(registrationRequest());
  rmSync(credentialStoreDirectory, { recursive: true, force: true });
  writeFileSync(credentialStoreDirectory, 'not-a-directory');
  await assertServiceRejects(
    service.completeRegistration(registrationCompletion(registration, createAuthenticator())),
    'credential_store_unavailable',
    500,
  );
  assert.equal(store.hasAnyCredential(registration.storageKey), false);
});

test('createPasskeyChallengeStore selects durable store only when configured', (t) => {
  assert.ok(createPasskeyChallengeStore({
    credentialStoreFile: '',
    requireDurable: false,
  }) instanceof InMemoryPasskeyChallengeStore);
  assertServiceError(
    () => createPasskeyChallengeStore({ credentialStoreFile: '', requireDurable: true }),
    'credential_store_unavailable',
    500,
  );
  assert.ok(createPasskeyChallengeStore({
    credentialStoreFile: tempCredentialStoreFile(t),
    requireDurable: true,
  }) instanceof FileBackedPasskeyChallengeStore);
});

test('rejects request smuggling fields and invalid identifiers including noncanonical aliases', async () => {
  const service = makeService();
  assertServiceError(
    () => service.createRegistrationChallenge(registrationRequest({ admin: true })),
    'invalid_request',
    400,
  );
  for (const overrides of [
    { walletId: 'short' },
    { walletId: ' wallet-123456' },
    { walletId: 'wallet-123456 ' },
    { accountName: 'bad account' },
    { accountName: ' alice@example.com' },
    { accountName: 'alice@example.com ' },
    { displayName: '   ' },
    { rpId: 'evil.example' },
    { schemaVersion: 999 },
  ]) {
    assert.throws(() => service.createRegistrationChallenge(registrationRequest(overrides)));
  }
  assertServiceError(
    () => service.createAssertionChallenge({ storageKey: '../escape', rpId: RP_ID, schemaVersion: SCHEMA_VERSION }),
    'invalid_request',
    400,
  );
  assertServiceError(
    () => service.createAssertionChallenge({
      storageKey: ' storage:unregistered',
      rpId: RP_ID,
      schemaVersion: SCHEMA_VERSION,
    }),
    'invalid_request',
    400,
  );

  const registration = service.createRegistrationChallenge(registrationRequest());
  const canonicalIdAuthenticator = createAuthenticator('canonical-id-test');
  await assertServiceRejects(
    service.completeRegistration({
      ...registrationCompletion(registration, canonicalIdAuthenticator),
      registrationId: `${registration.registrationId} `,
    }),
    'invalid_request',
    400,
  );
  const completed = await service.completeRegistration(
    registrationCompletion(registration, canonicalIdAuthenticator),
  );
  assert.equal(completed.storageKey, registration.storageKey);
});

test('malformed registration credential consumes its one-time ceremony', async () => {
  const service = makeService();
  const registration = service.createRegistrationChallenge(registrationRequest());
  const completion = registrationCompletion(registration, createAuthenticator());
  completion.credential.response.clientDataJSON = base64UrlEncode(Buffer.from(JSON.stringify({
    type: 'webauthn.create',
    challenge: 'wrong-challenge',
    origin: ORIGIN,
  })));
  await assertServiceRejects(service.completeRegistration(completion), 'challenge_mismatch', 400);
  await assertServiceRejects(
    service.completeRegistration(registrationCompletion(registration, createAuthenticator('retry'))),
    'unknown_or_expired_registration',
    404,
  );
});

test('concurrent registration replay has exactly one successful claimant', async () => {
  const service = makeService();
  const authenticator = createAuthenticator();
  const registration = service.createRegistrationChallenge(registrationRequest());
  const completion = registrationCompletion(registration, authenticator);
  const outcomes = await Promise.allSettled([
    service.completeRegistration(structuredClone(completion)),
    service.completeRegistration(structuredClone(completion)),
  ]);
  assert.equal(outcomes.filter((outcome) => outcome.status === 'fulfilled').length, 1);
  const rejection = outcomes.find((outcome) => outcome.status === 'rejected');
  assert.equal(rejection.reason.code, 'unknown_or_expired_registration');
});

test('rejects wrong origin, client-data type, and cross-origin registration', async () => {
  for (const [options, code] of [
    [{ origin: 'https://evil.example' }, 'origin_not_allowed'],
    [{ clientDataExtra: { type: 'webauthn.get' } }, 'credential_type_mismatch'],
    [{ clientDataExtra: { crossOrigin: true } }, 'cross_origin_not_allowed'],
    [{ clientDataExtra: { topOrigin: 'https://embedded.example' } }, 'cross_origin_not_allowed'],
    [{ clientDataExtra: { crossOrigin: 'false' } }, 'invalid_client_data_json'],
    [{ clientDataExtra: { crossOrigin: 0 } }, 'invalid_client_data_json'],
    [{ clientDataExtra: { crossOrigin: null } }, 'invalid_client_data_json'],
  ]) {
    const service = makeService();
    const registration = service.createRegistrationChallenge(registrationRequest());
    await assertServiceRejects(
      service.completeRegistration(registrationCompletion(registration, createAuthenticator(), options)),
      code,
    );
  }
});

test('rejects registration without user verification or with wrong RP hash', async () => {
  for (const options of [
    { flags: 0x41 },
    { rpId: 'evil.example' },
  ]) {
    const service = makeService();
    const registration = service.createRegistrationChallenge(registrationRequest());
    await assertServiceRejects(
      service.completeRegistration(registrationCompletion(registration, createAuthenticator(), options)),
      'webauthn_verification_failed',
      400,
    );
  }
});

test('rejects malformed attestation, mismatched rawId, extra fields, and unsupported algorithm', async () => {
  const mutators = [
    (credential) => { credential.response.attestationObject = base64UrlEncode(Buffer.from('not-cbor')); },
    (credential) => { credential.rawId = base64UrlEncode(Buffer.alloc(32, 9)); },
    (credential) => { credential.admin = true; },
    (credential) => { credential.response.publicKeyAlgorithm = -8; },
    (credential) => { credential.response.transports = ['internal', 'internal']; },
  ];
  for (const mutate of mutators) {
    const service = makeService();
    const registration = service.createRegistrationChallenge(registrationRequest());
    const completion = registrationCompletion(registration, createAuthenticator());
    mutate(completion.credential);
    await assert.rejects(service.completeRegistration(completion));
  }
});

test('rejects duplicate credential registration across storage keys', async () => {
  const service = makeService();
  const authenticator = createAuthenticator();
  await registerCredential(service, authenticator);
  const second = service.createRegistrationChallenge(registrationRequest({
    walletId: 'wallet-654321',
    accountName: 'bob@example.com',
    displayName: 'Bob',
  }));
  await assertServiceRejects(
    service.completeRegistration(registrationCompletion(second, authenticator)),
    'credential_already_registered',
    409,
  );
});

test('rejects assertion before registration and credentials registered to another storage key', async () => {
  const service = makeService();
  assertServiceError(
    () => service.createAssertionChallenge({
      storageKey: 'storage:unregistered',
      rpId: RP_ID,
      schemaVersion: SCHEMA_VERSION,
    }),
    'credential_not_registered',
    404,
  );

  const { registration, result } = await registerCredential(service);
  const assertion = service.createAssertionChallenge({
    storageKey: result.storageKey,
    rpId: RP_ID,
    schemaVersion: SCHEMA_VERSION,
  });
  await assertServiceRejects(
    service.completeAssertion(assertionCompletion(
      assertion,
      createAuthenticator('unregistered'),
      registration.userId,
    )),
    'credential_not_registered',
    403,
  );
});

test('rejects wrong user handle, missing user handle, tampered signature, wrong RP hash, and missing UV', async () => {
  const scenarios = [
    { mutate: (completion) => { completion.credential.response.userHandle = base64UrlEncode(Buffer.alloc(32, 8)); }, code: 'credential_user_mismatch' },
    { mutate: (completion) => { delete completion.credential.response.userHandle; }, code: 'invalid_credential' },
    { mutate: (completion) => { completion.credential.response.userHandle = null; }, code: 'invalid_credential' },
    { mutate: (completion) => { completion.credential.response.userHandle = base64UrlEncode(Buffer.alloc(65, 1)); }, code: 'invalid_credential' },
    { mutate: (completion) => { completion.credential.response.signature = base64UrlEncode(Buffer.alloc(64, 1)); }, code: 'webauthn_verification_failed' },
    { options: { rpId: 'evil.example' }, code: 'webauthn_verification_failed' },
    { options: { flags: 0x01 }, code: 'webauthn_verification_failed' },
  ];
  for (const scenario of scenarios) {
    const service = makeService();
    const { registration, result, authenticator } = await registerCredential(service);
    const assertion = service.createAssertionChallenge({
      storageKey: result.storageKey,
      rpId: RP_ID,
      schemaVersion: SCHEMA_VERSION,
    });
    const completion = assertionCompletion(
      assertion,
      authenticator,
      registration.userId,
      scenario.options,
    );
    scenario.mutate?.(completion);
    await assertServiceRejects(service.completeAssertion(completion), scenario.code);
  }
});

test('rejects non-advancing authenticator counters', async () => {
  const service = makeService();
  const { registration, result, authenticator } = await registerCredential(service);
  const first = service.createAssertionChallenge({ storageKey: result.storageKey, rpId: RP_ID, schemaVersion: 1 });
  await service.completeAssertion(assertionCompletion(first, authenticator, registration.userId, { counter: 4 }));
  const replay = service.createAssertionChallenge({ storageKey: result.storageKey, rpId: RP_ID, schemaVersion: 1 });
  await assertServiceRejects(
    service.completeAssertion(assertionCompletion(replay, authenticator, registration.userId, { counter: 4 })),
    'webauthn_verification_failed',
    400,
  );
});

test('allows zero counters for multi-device-compatible authenticators', async () => {
  const service = makeService();
  const { registration, result, authenticator } = await registerCredential(service);
  for (let index = 0; index < 2; index += 1) {
    const assertion = service.createAssertionChallenge({ storageKey: result.storageKey, rpId: RP_ID, schemaVersion: 1 });
    await service.completeAssertion(assertionCompletion(
      assertion,
      authenticator,
      registration.userId,
      { counter: 0 },
    ));
  }
});

test('expired and capacity-exhausted ceremonies fail closed', async () => {
  let now = 1_000;
  const expiring = makeService({ storeOptions: { ttlMillis: 10, now: () => now } });
  const registration = expiring.createRegistrationChallenge(registrationRequest());
  now += 11;
  await assertServiceRejects(
    expiring.completeRegistration(registrationCompletion(registration, createAuthenticator())),
    'unknown_or_expired_registration',
    404,
  );
  assert.doesNotThrow(() => expiring.createRegistrationChallenge(
    registrationRequest({ walletId: 'wallet-222222' }),
  ));

  const full = makeService({ storeOptions: { maxCeremonies: 1 } });
  full.createRegistrationChallenge(registrationRequest());
  assertServiceError(
    () => full.createRegistrationChallenge(registrationRequest({ walletId: 'wallet-222222' })),
    'ceremony_store_full',
    503,
  );
});

test('parses only canonical secure allowed origins', () => {
  assert.deepEqual(
    [...parseAllowedOrigins(
      'https://wallet.example.test,http://localhost:8080',
      { androidOrigin: ANDROID_ORIGIN, requireAndroidOrigin: true },
    )],
    ['https://wallet.example.test', 'http://localhost:8080', ANDROID_ORIGIN],
  );
  for (const origins of [
    '',
    'http://wallet.example.test',
    'https://operator:secret@wallet.example.test',
    'https://wallet.example.test/path',
    'https://wallet.example.test?token=secret',
    'https://wallet.example.test/',
    'https://WALLET.example.test',
    ' https://wallet.example.test',
    'https://wallet.example.test ',
    'https://wallet.example.test,',
    'https://wallet.example.test,,https://backup.example.test',
    'https://wallet.example.test,https://wallet.example.test',
    'not-a-url',
  ]) {
    assertServiceError(
      () => parseAllowedOrigins(origins, { requireAndroidOrigin: false }),
      'invalid_service_config',
      500,
    );
  }

  const digest = base64UrlEncode(Buffer.alloc(32, 0xff));
  const malformedAndroidOrigins = [
    'android:apk-key-hash:',
    `android:apk-key-hash:${digest.slice(0, -1)}`,
    `android:apk-key-hash:${digest}A`,
    `android:apk-key-hash:${digest}=`,
    `android:apk-key-hash:${Buffer.alloc(32, 0xff).toString('base64')}`,
    `Android:apk-key-hash:${digest}`,
    `ANDROID:APK-KEY-HASH:${digest}`,
    ` android:apk-key-hash:${digest}`,
    `android:apk-key-hash:${digest} `,
  ];
  for (const origin of malformedAndroidOrigins) {
    assertServiceError(
      () => parseAllowedOrigins(origin, { requireAndroidOrigin: true }),
      'invalid_service_config',
      500,
    );
  }

  assertServiceError(
    () => parseAllowedOrigins(
      `https://wallet.example.test,${ANDROID_ORIGIN}`,
      { androidOrigin: ANDROID_ORIGIN, requireAndroidOrigin: true },
    ),
    'invalid_service_config',
    500,
  );
  assertServiceError(
    () => parseAllowedOrigins('https://wallet.example.test', { requireAndroidOrigin: true }),
    'invalid_service_config',
    500,
  );
  assertServiceError(
    () => parseAllowedOrigins('https://wallet.example.test', {
      androidOrigin: '',
      requireAndroidOrigin: true,
    }),
    'invalid_service_config',
    500,
  );
});

test('Android APK signing-certificate origin completes registration and assertion', async () => {
  const service = makeService({
    allowedOrigins: parseAllowedOrigins(
      `https://wallet.example.test,${ANDROID_ORIGIN}`,
      { requireAndroidOrigin: true },
    ),
  });
  const { registration, result, authenticator } = await registerCredential(
    service,
    createAuthenticator(),
    { origin: ANDROID_ORIGIN },
  );
  const assertion = service.createAssertionChallenge({
    storageKey: result.storageKey,
    rpId: RP_ID,
    schemaVersion: SCHEMA_VERSION,
  });
  const assertionResult = await service.completeAssertion(
    assertionCompletion(
      assertion,
      authenticator,
      registration.userId,
      { origin: ANDROID_ORIGIN },
    ),
  );

  assert.deepEqual(assertionResult, result);
});

test('strict integer settings reject partial, signed, unsafe, and out-of-range values', () => {
  assert.equal(parseIntegerSetting('8789', 'PORT', { minimum: 1, maximum: 65535 }), 8789);
  for (const value of ['1junk', '-1', '+1', '01', '', '65536', '9007199254740992']) {
    assert.throws(
      () => parseIntegerSetting(value, 'PORT', { minimum: 1, maximum: 65535 }),
      /PORT must be an integer/,
    );
  }
  for (const environment of ['development', 'test', 'production']) {
    assert.equal(parseNodeEnvironment(environment), environment);
  }
  for (const environment of ['', 'prod', 'Production', ' production', 'production\n']) {
    assert.throws(() => parseNodeEnvironment(environment), /NODE_ENV must be/);
  }
});

test('HTTP server completes cryptographic ceremony and emits hardened response headers', async (t) => {
  const service = makeService();
  const authenticator = createAuthenticator();
  await withServer(t, { service }, async (baseUrl) => {
    const healthResponse = await fetch(`${baseUrl}/api/passkey-backup/v1/health`);
    assert.equal(healthResponse.status, 200);
    assert.equal(healthResponse.headers.get('cache-control'), 'no-store');
    assert.equal(healthResponse.headers.get('x-content-type-options'), 'nosniff');
    assert.match(healthResponse.headers.get('content-security-policy'), /default-src 'none'/);

    const challenge = await postJson(baseUrl, '/api/passkey-backup/v1/registration/challenge', registrationRequest());
    assert.equal(challenge.response.status, 200);
    const completed = await postJson(
      baseUrl,
      '/api/passkey-backup/v1/registration/complete',
      registrationCompletion(challenge.body, authenticator),
    );
    assert.equal(completed.response.status, 200);
    assert.equal(completed.body.storageKey, challenge.body.storageKey);

    const assertion = await postJson(baseUrl, '/api/passkey-backup/v1/assertion/challenge', {
      storageKey: completed.body.storageKey,
      rpId: RP_ID,
      schemaVersion: 1,
    });
    const asserted = await postJson(baseUrl, '/api/passkey-backup/v1/assertion/complete', {
      assertionId: assertion.body.assertionId,
      rpId: RP_ID,
      credential: authenticationCredential(
        assertion.body.challenge,
        authenticator,
        challenge.body.userId,
        { origin: ANDROID_ORIGIN },
      ),
    });
    assert.equal(asserted.response.status, 200);
    assert.equal(asserted.body.storageKey, completed.body.storageKey);

    const credentials = await postJson(baseUrl, '/api/passkey-backup/v1/credentials/list', {
      storageKey: completed.body.storageKey,
      rpId: RP_ID,
      schemaVersion: SCHEMA_VERSION,
    });
    assert.equal(credentials.response.status, 200);
    assert.equal(credentials.body.credentials.length, 1);
    const revoked = await postJson(baseUrl, '/api/passkey-backup/v1/credentials/revoke', {
      storageKey: completed.body.storageKey,
      credentialId: credentials.body.credentials[0].id,
      rpId: RP_ID,
      schemaVersion: SCHEMA_VERSION,
    });
    assert.equal(revoked.response.status, 200);
    assert.equal(revoked.body.remainingCredentials, 0);
    const revokedAgain = await postJson(baseUrl, '/api/passkey-backup/v1/credentials/revoke-all', {
      storageKey: completed.body.storageKey,
      rpId: RP_ID,
      schemaVersion: SCHEMA_VERSION,
    });
    assert.equal(revokedAgain.response.status, 200);
    assert.equal(revokedAgain.body.remainingCredentials, 0);
  });
});

test('HTTP server rejects MIME confusion, query smuggling, oversized bodies, and wrong methods', async (t) => {
  await withServer(t, { service: makeService() }, async (baseUrl) => {
    const mime = await fetch(`${baseUrl}/api/passkey-backup/v1/registration/challenge`, {
      method: 'POST',
      headers: {
        'content-type': 'text/application/json',
        authorization: 'Bearer test-authorization-token',
      },
      body: '{}',
    });
    assert.equal(mime.status, 415);

    const query = await fetch(`${baseUrl}/api/passkey-backup/v1/health?admin=true`);
    assert.equal(query.status, 400);
    assert.equal((await query.json()).error, 'invalid_request_target');

    const oversized = await fetch(`${baseUrl}/api/passkey-backup/v1/registration/challenge`, {
      method: 'POST',
      headers: {
        'content-type': 'application/json',
        authorization: 'Bearer test-authorization-token',
      },
      body: JSON.stringify({ padding: 'x'.repeat(65 * 1024) }),
    });
    assert.equal(oversized.status, 413);

    const wrongMethod = await fetch(`${baseUrl}/api/passkey-backup/v1/health`, { method: 'POST' });
    assert.equal(wrongMethod.status, 405);
    assert.equal(wrongMethod.headers.get('allow'), 'GET');

    for (const target of [
      '/api/passkey-backup/v1/credentials/revoke-all?admin=true',
      '/api/passkey-backup/v1/credentials/%72evoke-all',
      '/api/passkey-backup/v1/credentials/revoke-all/',
      '/api/passkey-backup/v1/credentials/revoke-all%2F..%2Flist',
    ]) {
      const smuggled = await fetch(`${baseUrl}${target}`, {
        method: 'POST',
        headers: {
          'content-type': 'application/json',
          authorization: 'Bearer test-authorization-token',
        },
        body: '{}',
      });
      assert.ok([400, 404].includes(smuggled.status), `${target}: ${smuggled.status}`);
    }
  });
});

test('credential lifecycle rejects extra fields, malformed IDs, and schema or RP drift', async () => {
  const service = makeService();
  const owner = authorization('fearless-wallet-owner:lifecycle-validation');
  const { result } = await registerCredentialAs(service, owner);
  const base = { storageKey: result.storageKey, rpId: RP_ID, schemaVersion: SCHEMA_VERSION };
  for (const request of [
    { ...base, admin: true },
    { ...base, storageKey: `${result.storageKey} ` },
    { ...base, rpId: 'evil.example' },
    { ...base, schemaVersion: 2 },
  ]) {
    assert.throws(() => service.listCredentials(request, owner));
  }
  for (const credentialId of ['', '***', 'QQ==', 'Q', ' credential-id', 'credential-id ']) {
    assertServiceError(
      () => service.revokeCredential({ ...base, credentialId }, owner),
      'invalid_request',
      400,
    );
  }
  assertServiceError(
    () => service.revokeAllCredentials({ ...base, credentialId: 'unexpected' }, owner),
    'invalid_request',
    400,
  );
});

test('HTTP server rate limits ceremony endpoints per client and returns Retry-After', async (t) => {
  let now = 1_000;
  await withServer(t, {
    service: makeService(),
    rateLimitWindowMillis: 60_000,
    rateLimitMaxRequests: 1,
    now: () => now,
  }, async (baseUrl) => {
    const first = await postJson(baseUrl, '/api/passkey-backup/v1/registration/challenge', registrationRequest());
    assert.equal(first.response.status, 200);
    const blocked = await postJson(baseUrl, '/api/passkey-backup/v1/registration/challenge', registrationRequest({
      walletId: 'wallet-222222',
    }));
    assert.equal(blocked.response.status, 429);
    assert.equal(blocked.body.error, 'rate_limit_exceeded');
    assert.equal(blocked.response.headers.get('retry-after'), '60');
    const health = await fetch(`${baseUrl}/api/passkey-backup/v1/health`);
    assert.equal(health.status, 200);

    now += 60_001;
    const reset = await postJson(baseUrl, '/api/passkey-backup/v1/registration/challenge', registrationRequest({
      walletId: 'wallet-333333',
    }));
    assert.equal(reset.response.status, 200);
  });
});
