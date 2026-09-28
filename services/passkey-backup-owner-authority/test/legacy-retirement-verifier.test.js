import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { chmodSync, mkdtempSync, readFileSync, rmSync, symlinkSync,
  unlinkSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import test from 'node:test';
import { retireJsonCredentialWriter } from '../../passkey-backup-challenge-service/src/retire-writer.js';
import { createPasskeyChallengeStore } from '../../passkey-backup-challenge-service/src/store.js';
import { verifyRetiredJsonCredentialWriter } from '../src/legacy-retirement-verifier.js';

const sha256 = (bytes) => createHash('sha256').update(bytes).digest('hex');

function fixture(t) {
  const directory = mkdtempSync(join(tmpdir(), 'fearless-retirement-readback-'));
  t.after(() => rmSync(directory, { recursive: true, force: true }));
  const credentialStoreFile = join(directory, 'credentials.json');
  const store = createPasskeyChallengeStore({ credentialStoreFile,
    requireDurable: true, productionMode: true, recoveryEnabled: 'false' });
  store.close();
  const source = readFileSync(credentialStoreFile);
  const expectedSourceSha256 = sha256(source);
  const expectedManifestSha256 = sha256('separately reviewed manifest fixture');
  const legacySnapshotPath = join(directory, `legacy-${expectedSourceSha256}.json`);
  writeFileSync(legacySnapshotPath, source, { mode: 0o600 });
  const marker = join(directory, '.credentials.json.retired');
  const leaseOwner = join(directory, '.credentials.json.writer-lease', 'owner.json');
  const args = { credentialStoreFile, legacySnapshotPath,
    expectedSourceSha256, expectedManifestSha256 };
  const retire = () => retireJsonCredentialWriter({ credentialStoreFile,
    expectedSourceSha256, cutoverManifestSha256: expectedManifestSha256 });
  return { args, source, marker, leaseOwner, retire };
}

test('retirement readback binds the marker, sealed cohort and surviving lease without admission', (t) => {
  const item = fixture(t);
  assert.throws(() => verifyRetiredJsonCredentialWriter(item.args),
    { code: 'legacy_retirement_unavailable' });
  item.retire();
  const before = [item.args.credentialStoreFile, item.args.legacySnapshotPath,
    item.marker, item.leaseOwner].map((path) => readFileSync(path));
  const result = verifyRetiredJsonCredentialWriter(item.args);
  assert.deepEqual(result, {
    schemaVersion: 1, mode: 'read-only',
    sourceSha256: item.args.expectedSourceSha256,
    cutoverManifestSha256: item.args.expectedManifestSha256,
    sealedSourceMatchesRetiredStore: true,
    retirementMarkerMatches: true,
    leaseArtifactPresent: true,
    migrationPermitted: false, productionAdmission: false,
  });
  assert.deepEqual([item.args.credentialStoreFile, item.args.legacySnapshotPath,
    item.marker, item.leaseOwner].map((path) => readFileSync(path)), before);
  assert.equal(JSON.stringify(result).includes('token'), false);
  const script = new URL('../scripts/verify-retired-json-writer.mjs', import.meta.url);
  const command = [script.pathname, item.args.credentialStoreFile,
    item.args.legacySnapshotPath, item.args.expectedSourceSha256,
    item.args.expectedManifestSha256];
  const cli = spawnSync(process.execPath, command, { encoding: 'utf8' });
  assert.equal(cli.status, 3, cli.stderr);
  assert.deepEqual(JSON.parse(cli.stdout), result);
  const wrong = spawnSync(process.execPath, [
    ...command.slice(0, -1), sha256('wrong reviewed manifest'),
  ], { encoding: 'utf8' });
  assert.equal(wrong.status, 1);
  assert.equal(wrong.stdout, '');
});

test('retirement readback rejects altered manifest, source, marker and sealed image', (t) => {
  const item = fixture(t);
  item.retire();
  assert.throws(() => verifyRetiredJsonCredentialWriter({ ...item.args,
    expectedManifestSha256: sha256('different manifest') }),
  { code: 'legacy_retirement_marker_mismatch' });
  writeFileSync(item.marker, 'not a retirement marker\n');
  assert.throws(() => verifyRetiredJsonCredentialWriter(item.args),
    { code: 'legacy_retirement_marker_mismatch' });
  writeFileSync(item.marker, `${JSON.stringify({ schemaVersion: 1,
    credentialStoreSha256: item.args.expectedSourceSha256,
    cutoverManifestSha256: item.args.expectedManifestSha256 })}\n`);
  writeFileSync(item.args.legacySnapshotPath, 'changed sealed source\n');
  assert.throws(() => verifyRetiredJsonCredentialWriter(item.args),
    { code: 'legacy_retirement_source_mismatch' });
  writeFileSync(item.args.legacySnapshotPath, item.source);
  writeFileSync(item.args.credentialStoreFile, 'changed live source\n');
  assert.throws(() => verifyRetiredJsonCredentialWriter(item.args),
    { code: 'legacy_retirement_source_mismatch' });
});

test('retirement readback rejects missing or substituted private fence artifacts', (t) => {
  const item = fixture(t);
  item.retire();
  const markerBytes = readFileSync(item.marker);
  writeFileSync(item.marker, 'X'.repeat(513));
  assert.throws(() => verifyRetiredJsonCredentialWriter(item.args),
    { code: 'legacy_retirement_artifact_oversize' });
  writeFileSync(item.marker, markerBytes);
  writeFileSync(item.leaseOwner, '{}\n');
  assert.throws(() => verifyRetiredJsonCredentialWriter(item.args),
    { code: 'legacy_retirement_lease_invalid' });
  unlinkSync(item.leaseOwner);
  assert.throws(() => verifyRetiredJsonCredentialWriter(item.args),
    { code: 'legacy_retirement_unavailable' });
  unlinkSync(item.marker);
  symlinkSync(item.args.legacySnapshotPath, item.marker);
  assert.throws(() => verifyRetiredJsonCredentialWriter(item.args),
    { code: 'legacy_retirement_unavailable' });
  unlinkSync(item.marker);
  writeFileSync(item.marker, `${JSON.stringify({ schemaVersion: 1,
    credentialStoreSha256: item.args.expectedSourceSha256,
    cutoverManifestSha256: item.args.expectedManifestSha256 })}\n`, { mode: 0o600 });
  chmodSync(item.marker, 0o644);
  assert.throws(() => verifyRetiredJsonCredentialWriter(item.args),
    { code: 'legacy_retirement_unavailable' });
});
