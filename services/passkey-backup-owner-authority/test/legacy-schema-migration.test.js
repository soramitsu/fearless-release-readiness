import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import fs from 'node:fs';
import { syncBuiltinESMExports } from 'node:module';
import { join } from 'node:path';
import { DatabaseSync } from 'node:sqlite';
import test from 'node:test';
import { readOwnerCredentialSnapshot } from '../src/store.js';
import { authorizationSubjectHash } from '../../passkey-backup-challenge-service/src/authorization.js';
import { b64, downgradeStoreFixture, request, setup } from './fixtures.js';

const digest = (value) => createHash('sha256').update(value).digest('hex');
const denied = (action, code = 'store_unavailable') =>
  assert.throws(action, (error) => error?.code === code);

function withSnapshotOpenSwap(path, swap, action) {
  const originalOpen = fs.openSync;
  fs.openSync = function openWithSwap(target, ...args) {
    if (target === path) return swap(originalOpen, target, args);
    return originalOpen(target, ...args);
  };
  syncBuiltinESMExports();
  try { action(); }
  finally {
    fs.openSync = originalOpen;
    syncBuiltinESMExports();
  }
}

test('snapshot rejects a symlink substituted after its private-file check', (t) => {
  const { core, path, dir } = setup(t);
  core.close();
  const publicCopy = join(dir, 'public-copy.sqlite');
  fs.copyFileSync(path, publicCopy);
  fs.chmodSync(publicCopy, 0o644);
  withSnapshotOpenSwap(path, (open, target, args) => {
    fs.renameSync(path, join(dir, 'original.sqlite'));
    fs.symlinkSync(publicCopy, path);
    return open(target, ...args);
  }, () => denied(() => readOwnerCredentialSnapshot(path)));
});

test('snapshot rejects a regular replacement at open and a path swap after open', async (t) => {
  for (const afterOpen of [false, true]) {
    await t.test(afterOpen ? 'after open' : 'at open', (subtest) => {
      const { core, path, dir } = setup(subtest);
      core.close();
      const alternate = join(dir, 'alternate.sqlite');
      fs.copyFileSync(path, alternate);
      withSnapshotOpenSwap(path, (open, target, args) => {
        if (!afterOpen) {
          fs.renameSync(path, join(dir, 'original.sqlite'));
          fs.renameSync(alternate, path);
          return open(target, ...args);
        }
        const fd = open(target, ...args);
        fs.renameSync(path, join(dir, 'original.sqlite'));
        fs.renameSync(alternate, path);
        return fd;
      }, () => denied(() => readOwnerCredentialSnapshot(path)));
    });
  }
});

test('snapshot rejects SQLite sidecars before and during a descriptor-alias read', async (t) => {
  for (const suffix of ['-journal', '-wal', '-shm']) {
    await t.test(suffix, (subtest) => {
      const { core, path } = setup(subtest);
      core.close();
      const sidecar = `${path}${suffix}`;
      fs.writeFileSync(sidecar, 'interrupted writer', { mode: 0o600 });
      denied(() => readOwnerCredentialSnapshot(path));
      fs.unlinkSync(sidecar);
      assert.equal(readOwnerCredentialSnapshot(path).schemaVersion, 5);
    });
  }

  const { core, path } = setup(t);
  core.close();
  const originalLstat = fs.lstatSync;
  let journalChecks = 0;
  fs.lstatSync = function createJournalDuringRead(target, ...args) {
    if (target === `${path}-journal` && ++journalChecks === 2) {
      fs.writeFileSync(target, 'interrupted writer', { mode: 0o600 });
    }
    return originalLstat(target, ...args);
  };
  syncBuiltinESMExports();
  try {
    denied(() => readOwnerCredentialSnapshot(path));
    assert.equal(journalChecks, 2);
  } finally {
    fs.lstatSync = originalLstat;
    syncBuiltinESMExports();
  }
});

test('explicit v2-to-v5 migration preserves credentials, grants, counters and backup head', async (t) => {
  const { core, open, path, bootstrap } = setup(t);
  const { owner } = await bootstrap();
  const grant = core.issueGrant(owner.sessionToken, request());
  const generation = {
    schemaVersion: 1, operationId: b64(21), generationId: b64(22),
    backupNamespace: owner.namespace, expectedHeadRevision: '0', expectedHeadSha256: null,
    bundleSha256: 'a'.repeat(64), keyEpoch: '1', driveFileId: 'drive-v2-head',
    storageAccountBinding: 'b'.repeat(64),
  };
  const generationGrant = core.issueGenerationGrant(owner.sessionToken, generation);
  core.commitGenerationMetadata(generationGrant.token, generation);
  const originalHead = core.readBackupHead(owner.sessionToken);
  core.close();
  downgradeStoreFixture(path, 2);
  denied(() => open());
  const v2 = readOwnerCredentialSnapshot(path);
  assert.equal(v2.schemaVersion, 2);
  assert.equal(v2.credentials.length, 1);
  assert.equal(v2.credentials[0].counter, 0);
  assert.deepEqual(v2.storageBindings, []);
  assert.deepEqual(v2.legacyCredentialMetadata, []);

  const migrated = open({ migrate: true });
  assert.deepEqual(migrated.readBackupHead(owner.sessionToken), originalHead);
  assert.equal(migrated.consumeGrant(grant.token, request()).subject, owner.subject);
  denied(() => migrated.consumeGrant(grant.token, request()), 'authorization_failed');
  const v5 = readOwnerCredentialSnapshot(path);
  assert.equal(v5.schemaVersion, 5);
  assert.deepEqual(v5.owners, v2.owners);
  assert.deepEqual(v5.credentials, v2.credentials);
  assert.deepEqual(v5.storageBindings, []);
  assert.deepEqual(v5.legacyCredentialMetadata, []);
  assert.deepEqual(v5.credentialScopes, [{ credential_id: b64(2), owner: owner.subject, scope: 'owner', storage_key: null }]);
  const db = new DatabaseSync(path, { readOnly: true });
  assert.equal(db.prepare('PRAGMA user_version').get().user_version, 5);
  db.close();
});

test('v5 stores exact historical public metadata, scoped credentials and empty owner tombstones', async (t) => {
  const { core, path, bootstrap, open } = setup(t);
  const first = (await bootstrap()).owner;
  const second = (await bootstrap(core, b64(3), b64(5))).owner;
  core.close();
  const db = new DatabaseSync(path);
  db.exec('PRAGMA foreign_keys=ON');
  const storage = 'storage:historical-wallet';
  const tombstone = 'storage:historical-empty';
  const historicalHandle = createHash('sha256').update(`user\0${storage}`).digest('base64url');
  const source = digest('sealed-legacy-file');
  db.exec('BEGIN IMMEDIATE');
  try {
    db.prepare('UPDATE credentials SET user_handle=?, counter=7 WHERE id=?').run(historicalHandle, b64(2));
    const bind = db.prepare('INSERT INTO storage_bindings VALUES(?,?,?,?,?,?)');
    bind.run(storage, first.subject, authorizationSubjectHash(first.subject), source, digest('proof-one'), 123);
    bind.run(tombstone, first.subject, authorizationSubjectHash(first.subject), source, digest('proof-empty'), 123);
    db.prepare('INSERT INTO legacy_credential_metadata VALUES(?,?,?,?,?)').run(
      b64(2), storage, '00000000-0000-0000-0000-000000000000', '["internal","hybrid"]', 'ios');
    db.exec('COMMIT');
  } catch (error) { db.exec('ROLLBACK'); throw error; }
  const snapshot = readOwnerCredentialSnapshot(path);
  assert.equal(snapshot.schemaVersion, 5);
  assert.equal(snapshot.credentials.find((row) => row.id === b64(2)).user_handle, historicalHandle);
  assert.equal(snapshot.credentials.find((row) => row.id === b64(2)).counter, 7);
  assert.deepEqual(snapshot.storageBindings.map((row) => row.storage_key), [tombstone, storage]);
  assert.equal(snapshot.legacyCredentialMetadata[0].transports_json, '["internal","hybrid"]');
  assert.equal(snapshot.legacyCredentialMetadata[0].registration_platform, 'ios');
  assert.equal(snapshot.legacyCredentialMetadata.some((row) => row.storage_key === tombstone), false);
  assert.deepEqual(snapshot.credentialScopes.find((row) => row.credential_id === b64(2)),
    { credential_id: b64(2), owner: first.subject, scope: 'storage', storage_key: storage });
  assert.deepEqual(snapshot.credentialScopes.find((row) => row.credential_id === b64(3)),
    { credential_id: b64(3), owner: second.subject, scope: 'owner', storage_key: null });

  assert.throws(() => db.prepare('INSERT INTO legacy_credential_metadata VALUES(?,?,?,?,?)').run(
    b64(3), storage, '00000000-0000-0000-0000-000000000000', null, 'android'), /owner mismatch/);
  assert.throws(() => db.prepare('UPDATE storage_bindings SET owner=? WHERE storage_key=?').run(second.subject, storage), /immutable storage binding/);
  assert.throws(() => db.prepare('DELETE FROM storage_bindings WHERE storage_key=?').run(tombstone), /immutable storage binding/);
  assert.throws(() => db.prepare('UPDATE legacy_credential_metadata SET registration_platform=? WHERE credential_id=?').run('android', b64(2)), /immutable legacy credential metadata/);
  assert.throws(() => db.prepare('UPDATE credentials SET owner=? WHERE id=?').run(second.subject, b64(2)), /immutable credential identity/);
  assert.throws(() => db.prepare('UPDATE credentials SET user_handle=? WHERE id=?').run(b64(9), b64(2)), /immutable legacy credential identity/);
  assert.throws(() => db.prepare('DELETE FROM credentials WHERE id=?').run(b64(2)), /FOREIGN KEY constraint failed/);
  db.prepare('UPDATE credentials SET counter=8, revoked=1 WHERE id=?').run(b64(2));
  assert.equal(db.prepare('SELECT counter,revoked FROM credentials WHERE id=?').get(b64(2)).counter, 8);
  db.close();
  open(); // The persisted tombstone and scope are valid for the v5 reader.
});

test('explicit v3-to-v5 migration retains legacy wallet scope and owner-wide recovery scope', async (t) => {
  const { core, path, open, bootstrap } = setup(t);
  const historical = (await bootstrap()).owner;
  const ownerWide = (await bootstrap(core, b64(3), b64(5))).owner;
  const storage = 'storage:historical-wallet';
  core.close();
  const db = new DatabaseSync(path);
  try {
    db.exec('PRAGMA foreign_keys=ON; BEGIN IMMEDIATE');
    db.prepare('INSERT INTO storage_bindings VALUES(?,?,?,?,?,?)').run(
      storage, historical.subject, authorizationSubjectHash(historical.subject),
      digest('source'), digest('proof'), 123);
    db.prepare('INSERT INTO legacy_credential_metadata VALUES(?,?,?,?,?)').run(
      b64(2), storage, '00000000-0000-0000-0000-000000000000', null, 'android');
    db.exec('COMMIT');
  } finally { db.close(); }
  downgradeStoreFixture(path, 3);
  const previous = readOwnerCredentialSnapshot(path);
  assert.equal(previous.schemaVersion, 3);
  assert.deepEqual(previous.credentialScopes, []);
  denied(() => open());
  const migrated = open({ migrate: true });
  const snapshot = readOwnerCredentialSnapshot(path);
  assert.equal(snapshot.schemaVersion, 5);
  assert.deepEqual(snapshot.credentials, previous.credentials);
  assert.deepEqual(snapshot.storageBindings, previous.storageBindings);
  assert.deepEqual(snapshot.legacyCredentialMetadata, previous.legacyCredentialMetadata);
  assert.deepEqual(snapshot.credentialScopes, [
    { credential_id: b64(2), owner: historical.subject, scope: 'storage', storage_key: storage },
    { credential_id: b64(3), owner: ownerWide.subject, scope: 'owner', storage_key: null },
  ]);
  assert.equal(migrated.readBackupHead(historical.sessionToken).ownerSubject, historical.subject);
});

test('explicit v4-to-v5 migration preserves authority and starts with no pending challenge', async (t) => {
  const { core, path, open, bootstrap } = setup(t);
  const { owner } = await bootstrap();
  const grant = core.issueGrant(owner.sessionToken, request());
  const original = readOwnerCredentialSnapshot(path);
  core.close();
  downgradeStoreFixture(path, 4);
  assert.equal(readOwnerCredentialSnapshot(path).schemaVersion, 4);
  denied(() => open());
  const migrated = open({ migrate: true });
  assert.equal(migrated.consumeGrant(grant.token, request()).subject, owner.subject);
  const snapshot = readOwnerCredentialSnapshot(path);
  assert.equal(snapshot.schemaVersion, 5);
  assert.deepEqual(snapshot.owners, original.owners);
  assert.deepEqual(snapshot.credentials, original.credentials);
  const db = new DatabaseSync(path, { readOnly: true });
  try { assert.equal(db.prepare('SELECT count(*) AS n FROM pending_challenges').get().n, 0); }
  finally { db.close(); }
});

test('v5 rejects missing challenge claim trigger and forged per-key handle', async (t) => {
  const { core, path, open, bootstrap } = setup(t);
  const { owner } = await bootstrap();
  const db = new DatabaseSync(path);
  db.prepare('INSERT INTO storage_bindings VALUES(?,?,?,?,?,?)').run(
    'storage:wallet-test', owner.subject, b64(9), digest('source'), digest('proof'), 1);
  const issued = core.beginChallengeCredentialMutation(owner.sessionToken,
    { kind: 'registration', storageKey: 'storage:wallet-test' });
  assert.throws(() => db.prepare('UPDATE pending_challenges SET nonce=? WHERE id=?').run(b64(20), issued.challengeId),
    /immutable pending challenge/);
  core.close();
  db.exec('DROP TRIGGER pending_challenge_claim_once');
  db.close();
  denied(() => open());
  denied(() => readOwnerCredentialSnapshot(path));
});

test('failed v2-to-v5 migration rolls back all schema changes and remains explicitly retryable', async (t) => {
  const { core, open, path, bootstrap } = setup(t);
  const { owner } = await bootstrap();
  const grant = core.issueGrant(owner.sessionToken, request());
  core.close();
  downgradeStoreFixture(path, 2);
  const db = new DatabaseSync(path);
  db.exec('CREATE TABLE storage_bindings (sentinel TEXT) STRICT');
  denied(() => open({ migrate: true }));
  assert.equal(db.prepare('PRAGMA user_version').get().user_version, 2);
  assert.equal(db.prepare('SELECT version FROM meta WHERE id=1').get().version, 2);
  assert.deepEqual(db.prepare('PRAGMA table_info(storage_bindings)').all().map((row) => row.name), ['sentinel']);
  assert.equal(db.prepare("SELECT count(*) AS n FROM sqlite_master WHERE name='legacy_credential_metadata'").get().n, 0);
  db.exec('DROP TABLE storage_bindings');
  db.close();
  const migrated = open({ migrate: true });
  assert.equal(migrated.consumeGrant(grant.token, request()).subject, owner.subject);
  assert.equal(readOwnerCredentialSnapshot(path).schemaVersion, 5);
});

test('missing v4 immutability trigger rejects opening rather than silently running weaker schema', (t) => {
  const { core, open, path } = setup(t);
  core.close();
  const db = new DatabaseSync(path);
  db.exec('DROP TRIGGER legacy_credential_identity_no_update');
  db.close();
  denied(() => open());
  denied(() => readOwnerCredentialSnapshot(path));
});

test('missing scope row or scope trigger rejects opening a v4 store', async (t) => {
  const { core, open, path, bootstrap } = setup(t);
  await bootstrap();
  core.close();
  const db = new DatabaseSync(path);
  db.exec('DROP TRIGGER credential_scope_no_delete');
  db.prepare('DELETE FROM credential_scopes WHERE credential_id=?').run(b64(2));
  db.close();
  denied(() => open());
  denied(() => readOwnerCredentialSnapshot(path));
});
