import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { chmodSync, readFileSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { DatabaseSync } from 'node:sqlite';
import test from 'node:test';
import { protectedRouteInventorySha256,
  verifyLegacyCutoverManifest } from '../src/legacy-cutover-manifest.js';
import { verifySealedLegacyCutover } from '../src/legacy-cutover-verifier.js';
import { hash } from '../src/validation.js';
import { b64, setup } from './fixtures.js';

const sha256 = (value) => createHash('sha256').update(value).digest('hex');
const key = 'storage:manifest-wallet';
const imageSha256 = sha256('candidate owner image fixture');

function publishManifest(directory, manifest) {
  const bytes = Buffer.from(`${JSON.stringify(manifest, null, 2)}\n`);
  const digest = sha256(bytes);
  const path = join(directory, `cutover-${digest}.json`);
  writeFileSync(path, bytes, { mode: 0o600 });
  return { path, digest };
}

async function fixture(t) {
  const item = setup(t);
  const { owner } = await item.bootstrap();
  item.core.close();
  const legacyOwnerHash = hash('independent historical owner');
  const historical = {
    id: b64(55), publicKey: b64(8), userId: hash(`user\0${key}`), counter: 42,
    deviceType: 'multiDevice', backedUp: true,
    aaguid: '00000000-0000-0000-0000-000000000000',
    registrationPlatform: 'android', transports: ['internal'],
  };
  const source = { schemaVersion: 4,
    credentialOwnersById: [{ credentialId: historical.id, storageKey: key,
      ownerSubjectHash: legacyOwnerHash }],
    credentialsByStorageKey: [{ storageKey: key, ownerSubjectHash: legacyOwnerHash,
      credentials: [historical] }],
  };
  const sourceBytes = Buffer.from(`${JSON.stringify(source)}\n`);
  const sourceSha256 = sha256(sourceBytes);
  const legacySnapshotPath = join(item.dir, `legacy-${sourceSha256}.json`);
  writeFileSync(legacySnapshotPath, sourceBytes, { mode: 0o600 });
  const db = new DatabaseSync(item.path);
  try {
    db.exec('PRAGMA foreign_keys=ON; BEGIN IMMEDIATE');
    db.prepare('INSERT INTO storage_bindings VALUES(?,?,?,?,?,?)').run(
      key, owner.subject, legacyOwnerHash, sourceSha256, sha256('fixture proof'), 123);
    db.prepare('INSERT INTO credentials VALUES(?,?,?,?,?,?,?,0)').run(
      historical.id, owner.subject, historical.publicKey, historical.userId,
      historical.counter, historical.deviceType, 1);
    db.prepare('INSERT INTO legacy_credential_metadata VALUES(?,?,?,?,?)').run(
      historical.id, key, historical.aaguid, JSON.stringify(historical.transports),
      historical.registrationPlatform);
    db.exec('COMMIT');
  } catch (error) { db.exec('ROLLBACK'); throw error; }
  finally { db.close(); }
  const compared = verifySealedLegacyCutover({ legacySnapshotPath,
    ownerPath: item.path, expectedSourceSha256: sourceSha256 });
  assert.equal(compared.publicRepresentationExact, true);
  assert.equal(compared.proofMetadata.sourceAndBindingMetadataComplete, false);
  const manifest = {
    candidate: { ownerImageSha256: imageSha256,
      protectedRoutesSha256: protectedRouteInventorySha256() },
    owner: { bindings: compared.counts.targetBindings,
      historicalMetadata: compared.counts.targetHistoricalMetadata,
      publicRowsSha256: compared.comparedTargetRowsSha256,
      schemaVersion: 8, verifiedProofs: compared.proofMetadata.counts.retainedProofs },
    schemaVersion: 1,
    source: { credentials: compared.counts.sourceCredentials,
      schemaVersion: compared.sourceSchemaVersion, sha256: sourceSha256,
      storageKeys: compared.counts.sourceStorageKeys,
      tombstones: compared.counts.sourceTombstones },
  };
  const { path: manifestPath, digest: manifestSha256 } = publishManifest(item.dir, manifest);
  const args = { manifestPath, expectedManifestSha256: manifestSha256,
    legacySnapshotPath, ownerPath: item.path, expectedOwnerImageSha256: imageSha256 };
  return { ...item, args, manifest, sourceBytes, historical };
}

test('candidate manifest binds exact source, public rows, routes and image without admitting migration', async (t) => {
  const item = await fixture(t);
  assert.equal(protectedRouteInventorySha256(),
    '11a8e0d89bfd6fbeba2d1e4b26b0d5e419df97b84d2daaa0d5f70fe5c213805e');
  const sourceBefore = readFileSync(item.args.legacySnapshotPath);
  const ownerBefore = readFileSync(item.path);
  const report = verifyLegacyCutoverManifest(item.args);
  assert.equal(report.mode, 'read-only');
  assert.equal(report.sourceAndTargetMatched, true);
  assert.equal(report.retainedProofMetadataComplete, false);
  assert.equal(report.migrationPermitted, false);
  assert.equal(report.sourceSha256, item.manifest.source.sha256);
  assert.equal(JSON.stringify(report).includes(key), false);
  assert.equal(JSON.stringify(report).includes(item.historical.id), false);
  assert.deepEqual(readFileSync(item.args.legacySnapshotPath), sourceBefore);
  assert.deepEqual(readFileSync(item.path), ownerBefore);
});

test('candidate manifest rejects substituted source, owner rows, route inventory and image', async (t) => {
  const item = await fixture(t);
  assert.throws(() => verifyLegacyCutoverManifest({ ...item.args,
    expectedOwnerImageSha256: sha256('another image') }),
  { code: 'cutover_manifest_candidate_mismatch' });
  const wrongRoutes = publishManifest(item.dir, { ...item.manifest,
    candidate: { ...item.manifest.candidate,
      protectedRoutesSha256: sha256('wrong routes') } });
  assert.throws(() => verifyLegacyCutoverManifest({ ...item.args,
    manifestPath: wrongRoutes.path, expectedManifestSha256: wrongRoutes.digest }),
  { code: 'cutover_manifest_candidate_mismatch' });
  writeFileSync(item.args.legacySnapshotPath, Buffer.from('tampered'));
  assert.throws(() => verifyLegacyCutoverManifest(item.args),
    { code: 'cutover_snapshot_mismatch' });
  writeFileSync(item.args.legacySnapshotPath, item.sourceBytes);
  const db = new DatabaseSync(item.path);
  try { db.prepare('UPDATE credentials SET counter=43 WHERE id=?').run(item.historical.id); }
  finally { db.close(); }
  assert.throws(() => verifyLegacyCutoverManifest(item.args),
    { code: 'cutover_manifest_state_mismatch' });
  const compared = verifySealedLegacyCutover({ legacySnapshotPath: item.args.legacySnapshotPath,
    ownerPath: item.path, expectedSourceSha256: item.manifest.source.sha256 });
  assert.equal(compared.publicRepresentationExact, false);
  const pinnedWrongRows = publishManifest(item.dir, { ...item.manifest,
    owner: { ...item.manifest.owner,
      publicRowsSha256: compared.comparedTargetRowsSha256 } });
  assert.throws(() => verifyLegacyCutoverManifest({ ...item.args,
    manifestPath: pinnedWrongRows.path, expectedManifestSha256: pinnedWrongRows.digest }),
  { code: 'cutover_manifest_public_cohort_mismatch' });
});

test('candidate manifest enforces canonical private bytes and closed fields', async (t) => {
  const item = await fixture(t);
  const noncanonical = Buffer.from(JSON.stringify(item.manifest));
  const noncanonicalSha256 = sha256(noncanonical);
  const noncanonicalPath = join(item.dir, `cutover-${noncanonicalSha256}.json`);
  writeFileSync(noncanonicalPath, noncanonical, { mode: 0o600 });
  assert.throws(() => verifyLegacyCutoverManifest({ ...item.args,
    manifestPath: noncanonicalPath, expectedManifestSha256: noncanonicalSha256 }),
  { code: 'cutover_manifest_invalid' });
  const extra = Buffer.from(`${JSON.stringify({ ...item.manifest, accepted: true }, null, 2)}\n`);
  const extraSha256 = sha256(extra);
  const extraPath = join(item.dir, `cutover-${extraSha256}.json`);
  writeFileSync(extraPath, extra, { mode: 0o600 });
  assert.throws(() => verifyLegacyCutoverManifest({ ...item.args,
    manifestPath: extraPath, expectedManifestSha256: extraSha256 }),
  { code: 'cutover_manifest_invalid' });
  writeFileSync(item.args.manifestPath, Buffer.from('tampered'));
  assert.throws(() => verifyLegacyCutoverManifest(item.args),
    { code: 'cutover_manifest_mismatch' });
  publishManifest(item.dir, item.manifest);
  chmodSync(item.args.manifestPath, 0o644);
  assert.throws(() => verifyLegacyCutoverManifest(item.args),
    { code: 'quarantine_path_unsafe' });
});

test('operator CLI exits blocked after a valid read-only candidate comparison', async (t) => {
  const item = await fixture(t);
  const script = new URL('../scripts/verify-legacy-cutover-manifest.mjs', import.meta.url);
  const run = spawnSync(process.execPath, [script.pathname, item.args.manifestPath,
    item.args.expectedManifestSha256, item.args.legacySnapshotPath,
    item.args.ownerPath, item.args.expectedOwnerImageSha256], { encoding: 'utf8' });
  assert.equal(run.status, 3, run.stderr);
  assert.equal(JSON.parse(run.stdout).migrationPermitted, false);
  assert.equal(run.stdout.includes(key), false);
  const wrong = spawnSync(process.execPath, [script.pathname, item.args.manifestPath,
    sha256('wrong manifest'), item.args.legacySnapshotPath,
    item.args.ownerPath, item.args.expectedOwnerImageSha256], { encoding: 'utf8' });
  assert.equal(wrong.status, 1);
  assert.equal(wrong.stdout, '');
});
