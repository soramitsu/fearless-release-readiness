import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { readFileSync, readdirSync, symlinkSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { DatabaseSync } from 'node:sqlite';
import test from 'node:test';
import { authorizationSubjectHash } from '../../passkey-backup-challenge-service/src/authorization.js';
import { reconcileLegacyCredentialStores } from '../src/legacy-reconciliation.js';
import { readOwnerCredentialSnapshot } from '../src/store.js';
import { b64, setup } from './fixtures.js';

const storageKey = 'storage:wallet-test';
const otherStorageKey = 'storage:tombstone-test';
const digest = (value) => createHash('sha256').update(value).digest('base64url');

function writeLegacy(path, ownerSubject, { schemaVersion = 3, ownerHash = authorizationSubjectHash(ownerSubject) } = {}) {
  const id = b64(2);
  const document = {
    schemaVersion,
    credentialsByStorageKey: [
      { storageKey, ownerSubjectHash: ownerHash, credentials: [{
        id, publicKey: b64(8), userId: digest(`user\0${storageKey}`), counter: 0,
        deviceType: 'multiDevice', backedUp: true,
        aaguid: '00000000-0000-0000-0000-000000000000', registrationPlatform: 'android',
        transports: ['internal'],
      }] },
      { storageKey: otherStorageKey, ownerSubjectHash: digest('unrelated owner'), credentials: [] },
    ],
  };
  if (schemaVersion === 4) document.credentialOwnersById = [
    { credentialId: id, storageKey, ownerSubjectHash: ownerHash },
  ];
  writeFileSync(path, `${JSON.stringify(document)}\n`, { mode: 0o600 });
  return document;
}

test('read-only reconciliation reports real handle mismatch and retained tombstone without changing either store', async (t) => {
  const { path, dir, bootstrap } = setup(t);
  const { owner } = await bootstrap();
  const legacyPath = join(dir, 'credentials.json');
  writeLegacy(legacyPath, owner.subject);
  const sqliteBefore = readFileSync(path);
  const jsonBefore = readFileSync(legacyPath);
  const entriesBefore = readdirSync(dir);
  const report = reconcileLegacyCredentialStores({ legacyPath, ownerPath: path });
  assert.equal(report.mode, 'read-only');
  assert.equal(report.migrationPermitted, false);
  assert.equal(report.legacySchemaVersion, 3);
  assert.equal(report.ownerSchemaVersion, 7);
  assert.deepEqual(report.counts, {
    legacyStorageKeys: 2, legacyCredentials: 1, ownerSubjects: 1, ownerCredentials: 1,
    matchingPublicCredentialRows: 0, unmappedStorageKeys: 1, unmappedCredentials: 0,
    conflictingCredentials: 1, ownerOnlyCredentials: 0,
  });
  assert.ok(report.diagnostics.some((item) => item.kind === 'credential_state_conflict' &&
    item.storageEntryIndex === 0 && item.credentialEntryIndex === 0));
  assert.ok(report.diagnostics.some((item) => item.kind === 'storage_binding_unrepresented'));
  assert.equal(JSON.stringify(report).includes(storageKey), false);
  assert.equal(JSON.stringify(report).includes(owner.subject), false);
  assert.equal(JSON.stringify(report).includes(b64(2)), false);
  assert.deepEqual(readFileSync(path), sqliteBefore);
  assert.deepEqual(readFileSync(legacyPath), jsonBefore);
  assert.deepEqual(readdirSync(dir), entriesBefore);
});

test('v4 and unmapped owners remain blocked; the operator CLI cannot authorize migration', async (t) => {
  const { path, dir, bootstrap } = setup(t);
  const { owner } = await bootstrap();
  const legacyPath = join(dir, 'credentials.json');
  writeLegacy(legacyPath, owner.subject, { schemaVersion: 4, ownerHash: digest('unknown owner') });
  const before = readFileSync(legacyPath);
  const report = reconcileLegacyCredentialStores({ legacyPath, ownerPath: path });
  assert.equal(report.legacySchemaVersion, 4);
  assert.equal(report.counts.unmappedStorageKeys, 2);
  assert.equal(report.migrationPermitted, false);
  const script = new URL('../scripts/reconcile-legacy-credentials.mjs', import.meta.url);
  const run = spawnSync(process.execPath, [script.pathname, legacyPath, path], { encoding: 'utf8' });
  assert.equal(run.status, 3, run.stderr);
  assert.equal(JSON.parse(run.stdout).migrationPermitted, false);
  assert.deepEqual(readFileSync(legacyPath), before);
});

test('matching v3 public rows and metadata remain unverified and cannot admit migration', async (t) => {
  const { core, path, dir, bootstrap } = setup(t);
  const { owner } = await bootstrap();
  const legacyPath = join(dir, 'credentials.json');
  const document = writeLegacy(legacyPath, owner.subject);
  const historical = document.credentialsByStorageKey[0].credentials[0];
  core.close();
  const db = new DatabaseSync(path);
  db.exec('PRAGMA foreign_keys=ON');
  db.prepare('UPDATE credentials SET user_handle=? WHERE id=?').run(historical.userId, historical.id);
  db.prepare('INSERT INTO storage_bindings VALUES(?,?,?,?,?,?)').run(
    storageKey, owner.subject, authorizationSubjectHash(owner.subject),
    createHash('sha256').update('sealed source').digest('hex'),
    createHash('sha256').update('unverified proof').digest('hex'), 1);
  db.prepare('INSERT INTO legacy_credential_metadata VALUES(?,?,?,?,?)').run(
    historical.id, storageKey, historical.aaguid, JSON.stringify(historical.transports), historical.registrationPlatform);
  db.close();
  const report = reconcileLegacyCredentialStores({ legacyPath, ownerPath: path });
  assert.equal(report.counts.matchingPublicCredentialRows, 1);
  assert.equal(report.counts.conflictingCredentials, 0);
  assert.ok(report.diagnostics.some((item) => item.kind === 'storage_binding_unverified'));
  assert.ok(report.diagnostics.some((item) => item.kind === 'credential_metadata_unverified'));
  assert.equal(report.migrationPermitted, false);
  assert.ok(report.blockers.includes('challenge_http_still_writes_json'));
  assert.equal(JSON.stringify(report).includes(storageKey), false);
  assert.equal(JSON.stringify(report).includes(historical.id), false);
});

test('invalid, symlinked and missing sources fail closed without creating a replacement', async (t) => {
  const { path, dir, bootstrap } = setup(t);
  const { owner } = await bootstrap();
  const legacyPath = join(dir, 'credentials.json');
  writeLegacy(legacyPath, owner.subject);
  const ownerAlias = join(dir, 'owner-alias.sqlite');
  symlinkSync(path, ownerAlias);
  assert.throws(() => readOwnerCredentialSnapshot(ownerAlias), { code: 'store_unavailable' });
  assert.throws(() => reconcileLegacyCredentialStores({ legacyPath, ownerPath: ownerAlias }),
    { code: 'store_unavailable' });
  const missingOwner = join(dir, 'missing.sqlite');
  assert.throws(() => reconcileLegacyCredentialStores({ legacyPath: 'credentials.json', ownerPath: path }),
    { message: 'absolute_store_paths_required' });
  assert.throws(() => reconcileLegacyCredentialStores({ legacyPath, ownerPath: missingOwner }),
    { code: 'store_unavailable' });
  assert.equal(readdirSync(dir).includes('missing.sqlite'), false);
  const damaged = JSON.parse(readFileSync(legacyPath, 'utf8'));
  damaged.credentialOwnersById = [];
  damaged.schemaVersion = 4;
  writeFileSync(legacyPath, JSON.stringify(damaged));
  assert.throws(() => reconcileLegacyCredentialStores({ legacyPath, ownerPath: path }),
    { code: 'credential_store_invalid' });
});

test('many unlinked tombstones bound diagnostics while keeping a complete count', (t) => {
  const { path, dir } = setup(t);
  const legacyPath = join(dir, 'credentials.json');
  const entries = Array.from({ length: 514 }, (_, index) => ({
    storageKey: `storage:tombstone-${index}`,
    ownerSubjectHash: digest(`owner:${index}`),
    credentials: [],
  }));
  writeFileSync(legacyPath, JSON.stringify({ schemaVersion: 3, credentialsByStorageKey: entries }), { mode: 0o600 });
  const report = reconcileLegacyCredentialStores({ legacyPath, ownerPath: path });
  assert.equal(report.migrationPermitted, false);
  assert.equal(report.counts.legacyStorageKeys, 514);
  assert.equal(report.counts.unmappedStorageKeys, 514);
  assert.equal(report.diagnostics.length, 512);
  assert.equal(report.omittedDiagnostics, 516);
});
