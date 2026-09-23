import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { DatabaseSync } from 'node:sqlite';
import test from 'node:test';
import { readOwnerCredentialSnapshot } from '../src/store.js';
import { authorizationSubjectHash } from '../../passkey-backup-challenge-service/src/authorization.js';
import { b64, downgradeStoreFixture, request, setup } from './fixtures.js';

const digest = (value) => createHash('sha256').update(value).digest('hex');
const denied = (action, code = 'store_unavailable') =>
  assert.throws(action, (error) => error?.code === code);

test('explicit v2-to-v3 migration preserves credentials, grants, counters and backup head', async (t) => {
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
  const v3 = readOwnerCredentialSnapshot(path);
  assert.equal(v3.schemaVersion, 3);
  assert.deepEqual(v3.owners, v2.owners);
  assert.deepEqual(v3.credentials, v2.credentials);
  assert.deepEqual(v3.storageBindings, []);
  assert.deepEqual(v3.legacyCredentialMetadata, []);
  const db = new DatabaseSync(path, { readOnly: true });
  assert.equal(db.prepare('PRAGMA user_version').get().user_version, 3);
  db.close();
});

test('v3 stores exact historical public metadata, per-credential handles and empty owner tombstones', async (t) => {
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
  assert.equal(snapshot.schemaVersion, 3);
  assert.equal(snapshot.credentials.find((row) => row.id === b64(2)).user_handle, historicalHandle);
  assert.equal(snapshot.credentials.find((row) => row.id === b64(2)).counter, 7);
  assert.deepEqual(snapshot.storageBindings.map((row) => row.storage_key), [tombstone, storage]);
  assert.equal(snapshot.legacyCredentialMetadata[0].transports_json, '["internal","hybrid"]');
  assert.equal(snapshot.legacyCredentialMetadata[0].registration_platform, 'ios');
  assert.equal(snapshot.legacyCredentialMetadata.some((row) => row.storage_key === tombstone), false);

  assert.throws(() => db.prepare('INSERT INTO legacy_credential_metadata VALUES(?,?,?,?,?)').run(
    b64(3), storage, '00000000-0000-0000-0000-000000000000', null, 'android'), /owner mismatch/);
  assert.throws(() => db.prepare('UPDATE storage_bindings SET owner=? WHERE storage_key=?').run(second.subject, storage), /immutable storage binding/);
  assert.throws(() => db.prepare('DELETE FROM storage_bindings WHERE storage_key=?').run(tombstone), /immutable storage binding/);
  assert.throws(() => db.prepare('UPDATE legacy_credential_metadata SET registration_platform=? WHERE credential_id=?').run('android', b64(2)), /immutable legacy credential metadata/);
  assert.throws(() => db.prepare('UPDATE credentials SET owner=? WHERE id=?').run(second.subject, b64(2)), /immutable legacy credential identity/);
  assert.throws(() => db.prepare('UPDATE credentials SET user_handle=? WHERE id=?').run(b64(9), b64(2)), /immutable legacy credential identity/);
  assert.throws(() => db.prepare('DELETE FROM credentials WHERE id=?').run(b64(2)), /FOREIGN KEY constraint failed/);
  db.prepare('UPDATE credentials SET counter=8, revoked=1 WHERE id=?').run(b64(2));
  assert.equal(db.prepare('SELECT counter,revoked FROM credentials WHERE id=?').get(b64(2)).counter, 8);
  db.close();
  open(); // The persisted tombstone and metadata are valid for the v3 reader.
});

test('failed v2-to-v3 migration rolls back all schema changes and remains explicitly retryable', async (t) => {
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
  assert.equal(readOwnerCredentialSnapshot(path).schemaVersion, 3);
});

test('missing v3 immutability trigger rejects opening rather than silently running weaker schema', (t) => {
  const { core, open, path } = setup(t);
  core.close();
  const db = new DatabaseSync(path);
  db.exec('DROP TRIGGER legacy_credential_identity_no_update');
  db.close();
  denied(() => open());
  denied(() => readOwnerCredentialSnapshot(path));
});
