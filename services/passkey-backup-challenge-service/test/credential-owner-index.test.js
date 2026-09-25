import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { fsyncSync, mkdtempSync, readFileSync, rmSync, statSync, symlinkSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import test from 'node:test';
import { authorizationSubjectHash } from '../src/authorization.js';
import { base64UrlEncode } from '../src/base64url.js';
import { createPasskeyBackupChallengeService } from '../src/service.js';
import { FileBackedPasskeyChallengeStore, InMemoryPasskeyChallengeStore, readCredentialStoreSnapshot } from '../src/store.js';
import { RP_ID, SCHEMA_VERSION } from '../src/validation.js';
import { authenticationCredential, createAuthenticator } from './webauthn-fixture.js';

const owner = authorizationSubjectHash('owner:credential-index-tests');
const otherOwner = authorizationSubjectHash('owner:unrelated-index-tests');
const storageKey = 'storage:credential-index-tests';
const otherStorageKey = 'storage:unrelated-index-tests';
const origin = 'https://wallet.example.test';

function credential(authenticator, key = storageKey) {
  return {
    id: base64UrlEncode(authenticator.credentialId),
    publicKey: authenticator.credentialPublicKey,
    userId: createHash('sha256').update(`user\0${key}`).digest('base64url'),
    counter: 13,
    deviceType: 'singleDevice',
    backedUp: false,
    aaguid: '00000000-0000-0000-0000-000000000000',
    registrationPlatform: 'ios',
    transports: ['internal'],
    ownerSubjectHash: key === storageKey ? owner : otherOwner,
  };
}

function legacyFixture(t) {
  const directory = mkdtempSync(join(tmpdir(), 'passkey-owner-index-'));
  t.after(() => rmSync(directory, { recursive: true, force: true }));
  const file = join(directory, 'credentials.json');
  const authenticator = createAuthenticator();
  const stored = credential(authenticator);
  const { ownerSubjectHash, ...record } = stored;
  const document = {
    schemaVersion: 3,
    credentialsByStorageKey: [
      { storageKey, ownerSubjectHash, credentials: [{ ...record, publicKey: base64UrlEncode(record.publicKey) }] },
      { storageKey: otherStorageKey, ownerSubjectHash: otherOwner, credentials: [] },
    ],
  };
  writeFileSync(file, `${JSON.stringify(document, null, 2)}\n`, { mode: 0o600 });
  return { file, document, authenticator, stored };
}

function rejectsLookup(store, id) {
  assert.throws(() => store.findCredentialOwner(id), { code: 'credential_not_registered', status: 403 });
}

test('read-only inventory preserves v3 bytes and tombstones, then rejects malformed and substituted input', (t) => {
  const { file, stored } = legacyFixture(t);
  const before = readFileSync(file);
  const snapshot = readCredentialStoreSnapshot(file);
  assert.equal(snapshot.needsMigration, true);
  assert.equal(snapshot.credentialsByStorageKey.get(storageKey).get(stored.id).userId, stored.userId);
  assert.equal(snapshot.credentialsByStorageKey.get(otherStorageKey).size, 0);
  assert.equal(snapshot.ownersByStorageKey.get(otherStorageKey), otherOwner);
  assert.deepEqual(readFileSync(file), before);
  const alias = `${file}.alias`;
  symlinkSync(file, alias);
  assert.throws(() => readCredentialStoreSnapshot(alias), { code: 'credential_store_invalid' });
  writeFileSync(file, '{invalid json');
  assert.throws(() => readCredentialStoreSnapshot(file), { code: 'credential_store_invalid' });
  assert.equal(readFileSync(file, 'utf8'), '{invalid json');
  assert.throws(() => readCredentialStoreSnapshot(`${file}.missing`), { code: 'credential_store_unavailable' });
});

test('v3 migration preserves every credential field and empty-owner tombstone, then authenticates after restart', async (t) => {
  const { file, document, authenticator, stored } = legacyFixture(t);
  const migrated = new FileBackedPasskeyChallengeStore({ credentialStoreFile: file });
  const persisted = JSON.parse(readFileSync(file, 'utf8'));
  assert.equal(persisted.schemaVersion, 4);
  assert.deepEqual(persisted.credentialsByStorageKey, document.credentialsByStorageKey);
  assert.deepEqual(persisted.credentialOwnersById, [{ credentialId: stored.id, storageKey, ownerSubjectHash: owner }]);
  assert.equal(statSync(file).mode & 0o777, 0o600);
  assert.equal(migrated.hasStorageOwner(otherStorageKey), true);
  assert.equal(migrated.hasAnyCredential(otherStorageKey), false);

  const store = new FileBackedPasskeyChallengeStore({ credentialStoreFile: file });
  const identified = store.findCredentialOwner(stored.id);
  assert.equal(identified.ownerSubjectHash, owner);
  assert.equal(identified.storageKey, storageKey);
  assert.equal(identified.credential.userId, stored.userId);
  assert.equal(identified.credential.counter, 13);
  const service = createPasskeyBackupChallengeService({ store, allowedOrigins: new Set([origin]) });
  const authorization = { subjectHash: owner, platform: 'ios', expiresAt: Math.floor(Date.now() / 1000) + 60 };
  const assertion = service.createAssertionChallenge({ storageKey, rpId: RP_ID, schemaVersion: SCHEMA_VERSION }, authorization);
  await service.completeAssertion({
    assertionId: assertion.assertionId,
    rpId: RP_ID,
    credential: authenticationCredential(assertion.challenge, authenticator, stored.userId, { origin, counter: 14 }),
  }, authorization);
  assert.equal(store.findCredentialOwner(stored.id).credential.counter, 14);
  assert.equal(new FileBackedPasskeyChallengeStore({ credentialStoreFile: file }).findCredentialOwner(stored.id).credential.counter, 14);
});

test('lookup returns copies of public metadata and cannot grant or change ownership', () => {
  const store = new InMemoryPasskeyChallengeStore();
  const input = credential(createAuthenticator());
  store.registerCredential(storageKey, input);
  const found = store.findCredentialOwner(input.id);
  found.ownerSubjectHash = otherOwner;
  found.storageKey = otherStorageKey;
  found.credential.publicKey.fill(0);
  found.credential.transports.push('usb');
  const unchanged = store.findCredentialOwner(input.id);
  assert.equal(unchanged.ownerSubjectHash, owner);
  assert.equal(unchanged.storageKey, storageKey);
  assert.deepEqual(Buffer.from(unchanged.credential.publicKey), input.publicKey);
  assert.deepEqual(unchanged.credential.transports, ['internal']);
  assert.equal(store.isStorageOwner(storageKey, otherOwner), false);
  assert.throws(() => store.listCredentials(storageKey, otherOwner), { code: 'request_authorization_failed' });
  rejectsLookup(store, 'unknown');
});

test('global index rejects re-enrollment under another storage key or owner', () => {
  const store = new InMemoryPasskeyChallengeStore();
  const authenticator = createAuthenticator();
  const input = credential(authenticator);
  store.registerCredential(storageKey, input);
  assert.throws(() => store.registerCredential(otherStorageKey, credential(authenticator, otherStorageKey)), {
    code: 'credential_already_registered', status: 409,
  });
  assert.equal(store.findCredentialOwner(input.id).ownerSubjectHash, owner);
  assert.equal(store.hasStorageOwner(otherStorageKey), false);
});

test('single and all-credential revocation remove lookup authority immediately and after restart', (t) => {
  const { file, stored } = legacyFixture(t);
  const store = new FileBackedPasskeyChallengeStore({ credentialStoreFile: file });
  const second = credential(createAuthenticator('second-credential'));
  store.registerCredential(storageKey, second);
  store.revokeCredential(storageKey, stored.id, owner, true);
  rejectsLookup(store, stored.id);
  assert.equal(store.findCredentialOwner(second.id).storageKey, storageKey);
  assert.throws(() => store.updateCredentialAfterAuthentication(storageKey, stored.id, {
    newCounter: 14, deviceType: 'singleDevice', backedUp: false,
  }), { code: 'credential_not_registered' });
  const restarted = new FileBackedPasskeyChallengeStore({ credentialStoreFile: file });
  rejectsLookup(restarted, stored.id);
  restarted.revokeAllCredentials(storageKey, owner, true);
  rejectsLookup(restarted, second.id);
  const final = new FileBackedPasskeyChallengeStore({ credentialStoreFile: file });
  rejectsLookup(final, second.id);
  assert.equal(final.isStorageOwner(storageKey, owner), true);
  assert.equal(final.isStorageOwner(otherStorageKey, otherOwner), true);
  assert.deepEqual(JSON.parse(readFileSync(file, 'utf8')).credentialOwnersById, []);
});

test('index integrity rejects missing, extra, duplicate, cross-owner and cross-storage entries without rewriting input', (t) => {
  const { file, stored } = legacyFixture(t);
  new FileBackedPasskeyChallengeStore({ credentialStoreFile: file });
  const valid = JSON.parse(readFileSync(file, 'utf8'));
  const mutations = [
    (value) => { delete value.credentialOwnersById; },
    (value) => { value.credentialOwnersById = []; },
    (value) => { value.credentialOwnersById.push(value.credentialOwnersById[0]); },
    (value) => { value.credentialOwnersById[0].credentialId = `${stored.id}x`; },
    (value) => { value.credentialOwnersById[0].ownerSubjectHash = otherOwner; },
    (value) => { value.credentialOwnersById[0].storageKey = otherStorageKey; },
    (value) => { value.credentialOwnersById[0].secret = 'unsupported'; },
    (value) => { value.schemaVersion = 5; },
  ];
  for (const mutate of mutations) {
    const value = structuredClone(valid);
    mutate(value);
    const raw = JSON.stringify(value);
    writeFileSync(file, raw);
    assert.throws(() => new FileBackedPasskeyChallengeStore({ credentialStoreFile: file }), { code: 'credential_store_invalid' });
    assert.equal(readFileSync(file, 'utf8'), raw);
  }
});

test('failed migration before atomic replacement preserves v3 bytes and can be retried', (t) => {
  const { file, stored } = legacyFixture(t);
  const original = readFileSync(file);
  assert.throws(() => new FileBackedPasskeyChallengeStore({
    credentialStoreFile: file,
    fileOperations: { renameSync() { throw new Error('synthetic interrupted migration'); } },
  }), { code: 'credential_store_unavailable' });
  assert.deepEqual(readFileSync(file), original);
  assert.equal(new FileBackedPasskeyChallengeStore({ credentialStoreFile: file }).findCredentialOwner(stored.id).credential.counter, 13);
});

test('migration fsync failure after atomic replacement is reported and restart reads complete v4 records', (t) => {
  const { file, stored } = legacyFixture(t);
  let syncs = 0;
  assert.throws(() => new FileBackedPasskeyChallengeStore({
    credentialStoreFile: file,
    fileOperations: { fsyncSync(fd) { if (++syncs === 2) throw new Error('synthetic directory sync failure'); fsyncSync(fd); } },
  }), { code: 'credential_store_unavailable' });
  assert.equal(JSON.parse(readFileSync(file, 'utf8')).schemaVersion, 4);
  const restarted = new FileBackedPasskeyChallengeStore({ credentialStoreFile: file });
  assert.equal(restarted.findCredentialOwner(stored.id).credential.counter, 13);
  assert.equal(restarted.isStorageOwner(otherStorageKey, otherOwner), true);
});

test('revocation index follows the committed file even when directory fsync reports failure', (t) => {
  const { file, stored } = legacyFixture(t);
  const store = new FileBackedPasskeyChallengeStore({ credentialStoreFile: file });
  let syncs = 0;
  store.fileOperations.fsyncSync = (fd) => {
    if (++syncs === 2) throw new Error('synthetic revocation directory sync failure');
    fsyncSync(fd);
  };
  assert.throws(() => store.revokeCredential(storageKey, stored.id, owner, true), { code: 'credential_store_unavailable' });
  rejectsLookup(store, stored.id);
  rejectsLookup(new FileBackedPasskeyChallengeStore({ credentialStoreFile: file }), stored.id);
});

test('opening v4 is read-only and does not silently repair a substituted index', (t) => {
  const { file, stored } = legacyFixture(t);
  new FileBackedPasskeyChallengeStore({ credentialStoreFile: file });
  const before = readFileSync(file);
  const store = new FileBackedPasskeyChallengeStore({
    credentialStoreFile: file,
    fileOperations: { renameSync() { assert.fail('v4 must not be rewritten at startup'); } },
  });
  assert.equal(store.findCredentialOwner(stored.id).storageKey, storageKey);
  assert.deepEqual(readFileSync(file), before);
});
