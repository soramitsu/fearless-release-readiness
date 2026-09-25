import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { createHash } from 'node:crypto';
import { readFileSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { DatabaseSync } from 'node:sqlite';
import test from 'node:test';
import { authenticationCredential, createAuthenticator } from
  '../../passkey-backup-challenge-service/test/webauthn-fixture.js';
import { inspectSealedLegacyImport, importSealedLegacyCredentialCohort } from '../src/legacy-import.js';
import { protectedRouteInventorySha256,
  verifyLegacyCutoverManifest } from '../src/legacy-cutover-manifest.js';
import { verifySealedLegacyCutover } from '../src/legacy-cutover-verifier.js';
import { legacyCutoverProofCommitment, readOwnerCredentialSnapshot } from '../src/store.js';
import { hash } from '../src/validation.js';
import { createWebAuthnVerifier } from '../src/webauthn-verifier.js';
import { audience, b64, setup, verifier as fakeVerifier } from './fixtures.js';

const sha256 = (value) => createHash('sha256').update(value).digest('hex');
const origin = `android:apk-key-hash:${Buffer.alloc(32, 0xa5).toString('base64url')}`;
const realVerifier = createWebAuthnVerifier({ allowedOrigins: {
  android: [origin], ios: ['https://fearlesswallet.io'],
} });

function db(path, action) {
  const handle = new DatabaseSync(path);
  try { return action(handle); }
  finally { handle.close(); }
}

function signed(challenge, authenticator, userHandle, credentialId, counter) {
  const { authenticatorAttachment, ...response } = authenticationCredential(
    challenge, authenticator, userHandle,
    { origin, flags: 0x1d, counter,
      credentialId: Buffer.from(credentialId, 'base64url') });
  void authenticatorAttachment;
  return response;
}

async function fixture(t, { schemaVersion = 4, credentials = 1, tombstone = false,
  verified = credentials } = {}) {
  const item = setup(t, { verifier: { ...fakeVerifier(),
    async legacyCutoverAssertion(input) { return realVerifier.legacyCutoverAssertion(input); },
  } });
  const { owner } = await item.bootstrap();
  const ownerCredential = readOwnerCredentialSnapshot(item.path).credentials[0];
  const ownerAuthenticator = createAuthenticator(`import-owner-${item.dir}`);
  db(item.path, (handle) => handle.prepare('UPDATE credentials SET public_key=?,counter=1 WHERE id=?')
    .run(Buffer.from(ownerAuthenticator.credentialPublicKey).toString('base64url'),
      ownerCredential.id));
  const storageKey = 'storage:verified-import';
  const historicalHash = hash('historical public authorization subject');
  const historical = Array.from({ length: credentials }, (_, index) => {
    const authenticator = createAuthenticator(`import-legacy-${index}-${item.dir}`);
    return { authenticator, record: {
      id: Buffer.from(authenticator.credentialId).toString('base64url'),
      publicKey: Buffer.from(authenticator.credentialPublicKey).toString('base64url'),
      userId: hash(`user\0${storageKey}`), counter: 7 + index,
      deviceType: 'multiDevice', backedUp: true,
      aaguid: '00000000-0000-0000-0000-000000000000',
      registrationPlatform: index % 2 ? 'android' : 'ios',
      ...(index % 2 ? {} : { transports: ['internal', 'hybrid'] }),
    } };
  });
  const source = {
    schemaVersion,
    ...(schemaVersion === 4 ? { credentialOwnersById: historical.map(({ record }) => ({
      credentialId: record.id, storageKey, ownerSubjectHash: historicalHash,
    })) } : {}),
    credentialsByStorageKey: [{ storageKey, ownerSubjectHash: historicalHash,
      credentials: historical.map(({ record }) => record) },
    ...(tombstone ? [{ storageKey: 'storage:unproven-empty', ownerSubjectHash: historicalHash,
      credentials: [] }] : [])],
  };
  const sourceBytes = Buffer.from(`${JSON.stringify(source)}\n`);
  const expectedSourceSha256 = sha256(sourceBytes);
  const legacySnapshotPath = join(item.dir, `legacy-${expectedSourceSha256}.json`);
  writeFileSync(legacySnapshotPath, sourceBytes, { mode: 0o600 });
  for (const [index, { authenticator, record }] of historical.entries()) {
    if (index >= verified) break;
    const challenge = item.core.issueLegacyCutoverChallenge(owner.sessionToken, {
      schemaVersion: 1, legacySnapshotPath, expectedSourceSha256,
      storageKey, credentialId: record.id,
    });
    await item.core.verifyAndConsumeLegacyCutoverClaim(owner.sessionToken, {
      schemaVersion: 1, challengeId: challenge.challengeId,
      legacySnapshotPath, expectedSourceSha256,
      legacyAssertion: signed(challenge.legacyChallenge, authenticator,
        record.userId, record.id, record.counter + 1),
      ownerAssertion: signed(challenge.ownerChallenge, ownerAuthenticator,
        ownerCredential.user_handle, ownerCredential.id, index + 2),
    });
  }
  item.core.close();
  const args = { legacySnapshotPath, ownerPath: item.path, expectedSourceSha256 };
  const clock = { now: () => item.clock.wall, monotonic: () => item.clock.mono };
  return { ...item, owner, ownerCredential, historical, source, sourceBytes,
    args, clock, storageKey };
}

function importCandidate(item, extra = {}) {
  const preflight = inspectSealedLegacyImport(item.args);
  return importSealedLegacyCredentialCohort({ ...item.args,
    expectedCandidateSha256: preflight.candidateSha256, ...item.clock, ...extra });
}

function worker(args) {
  return new Promise((resolve) => {
    const child = spawn(process.execPath, [new URL('./legacy-import-worker.js', import.meta.url).pathname,
      args.legacySnapshotPath, args.ownerPath, args.expectedSourceSha256,
      args.expectedCandidateSha256], { stdio: ['ignore', 'pipe', 'pipe'] });
    let stdout = '';
    let stderr = '';
    child.stdout.on('data', (chunk) => { stdout += chunk; });
    child.stderr.on('data', (chunk) => { stderr += chunk; });
    child.on('close', (status) => resolve({ status, stdout, stderr }));
  });
}

test('v4 sealed cohort imports only after verified v2 proofs and survives restart', async (t) => {
  const item = await fixture(t, { credentials: 2 });
  const beforeSource = readFileSync(item.args.legacySnapshotPath);
  const preflight = inspectSealedLegacyImport(item.args);
  assert.equal(preflight.offlineImportEligible, true);
  assert.equal(preflight.credentials, 2);
  assert.equal(preflight.productionAdmission, false);
  for (const value of [item.storageKey, item.owner.subject,
    ...item.historical.map(({ record }) => record.id)]) {
    assert.equal(JSON.stringify(preflight).includes(value), false);
  }
  const result = importCandidate(item);
  assert.equal(result.durableReceiptCommitted, true);
  assert.equal(result.productionAdmission, false);
  const after = readOwnerCredentialSnapshot(item.path);
  assert.equal(after.schemaVersion, 9);
  assert.equal(after.legacyImportReceipts.length, 1);
  assert.equal(after.legacyImportReceipts[0].receipt_sha256, result.receiptSha256);
  assert.equal(after.storageBindings.length, 1);
  assert.equal(after.legacyCredentialMetadata.length, 2);
  for (const { record } of item.historical) {
    const imported = after.credentials.find((row) => row.id === record.id);
    assert.equal(imported.owner, item.owner.subject);
    assert.equal(imported.public_key, record.publicKey);
    assert.equal(imported.user_handle, record.userId);
    assert.equal(imported.counter, record.counter + 1);
    assert.equal(imported.revoked, 0);
    assert.equal(after.credentialScopes.find((row) => row.credential_id === record.id).scope, 'storage');
  }
  assert.deepEqual(readFileSync(item.args.legacySnapshotPath), beforeSource);
  const compared = verifySealedLegacyCutover(item.args);
  assert.equal(compared.publicRepresentationExact, true);
  assert.equal(compared.proofMetadata.sourceAndBindingMetadataComplete, true);
  assert.equal(compared.migrationPermitted, false);
  const reopened = item.open();
  const body = Buffer.from(JSON.stringify({ storageKey: item.storageKey,
    rpId: 'fearlesswallet.io', schemaVersion: 1 }));
  const request = { schemaVersion: 1, audience, method: 'POST',
    path: '/api/passkey-backup/v1/credentials/list',
    bodySha256: hash(body), scope: 'passkey.credentials.list' };
  const grant = reopened.issueGrant(item.owner.sessionToken, request);
  const listed = reopened.commitChallengeReadRoute(item.owner.sessionToken,
    grant.token, request, body);
  assert.deepEqual(listed.credentials.map((row) => row.id).sort(),
    item.historical.map(({ record }) => record.id).sort());
  assert.equal(listed.credentials.find((row) => row.registrationPlatform === 'ios')
    .transports.join(','), 'internal,hybrid');
  assert.throws(() => importCandidate(item), { code: 'legacy_import_target_conflict' });
  db(item.path, (handle) => {
    assert.throws(() => handle.prepare('DELETE FROM legacy_import_receipts').run(),
      /immutable legacy import receipt/);
    assert.throws(() => handle.prepare('UPDATE legacy_import_receipts SET credentials=1').run(),
      /immutable legacy import receipt/);
    assert.throws(() => handle.prepare('UPDATE credentials SET public_key=? WHERE id=?')
      .run(b64(88), item.ownerCredential.id), /immutable proven owner key/);
  });
});

test('v3 public JSON shape imports without modifying the sealed image', async (t) => {
  const item = await fixture(t, { schemaVersion: 3 });
  const result = importCandidate(item);
  assert.equal(result.credentials, 1);
  assert.equal(readOwnerCredentialSnapshot(item.path).legacyImportReceipts[0].source_schema_version, 3);
  assert.equal(verifySealedLegacyCutover(item.args).publicRepresentationExact, true);
});

test('manifest v2 binds the durable import receipt while v1 cannot omit it', async (t) => {
  const item = await fixture(t);
  const imported = importCandidate(item);
  const compared = verifySealedLegacyCutover(item.args);
  const imageSha256 = sha256('reviewed-owner-image');
  const publish = (manifest) => {
    const bytes = Buffer.from(`${JSON.stringify(manifest, null, 2)}\n`);
    const digest = sha256(bytes);
    const path = join(item.dir, `cutover-${digest}.json`);
    writeFileSync(path, bytes, { mode: 0o600 });
    return { manifestPath: path, expectedManifestSha256: digest,
      legacySnapshotPath: item.args.legacySnapshotPath,
      ownerPath: item.path, expectedOwnerImageSha256: imageSha256 };
  };
  const manifest = {
    candidate: { ownerImageSha256: imageSha256,
      protectedRoutesSha256: protectedRouteInventorySha256() },
    owner: { bindings: compared.counts.targetBindings,
      historicalMetadata: compared.counts.targetHistoricalMetadata,
      importReceiptSha256: imported.receiptSha256,
      publicRowsSha256: compared.comparedTargetRowsSha256,
      schemaVersion: 9, verifiedProofs: compared.proofMetadata.counts.retainedProofs },
    schemaVersion: 2,
    source: { credentials: compared.counts.sourceCredentials,
      schemaVersion: compared.sourceSchemaVersion, sha256: item.args.expectedSourceSha256,
      storageKeys: compared.counts.sourceStorageKeys,
      tombstones: compared.counts.sourceTombstones },
  };
  const report = verifyLegacyCutoverManifest(publish(manifest));
  assert.equal(report.durableImportReceiptBound, true);
  assert.equal(report.retainedProofMetadataComplete, true);
  assert.equal(report.migrationPermitted, false);
  assert.throws(() => verifyLegacyCutoverManifest(publish({ ...manifest,
    schemaVersion: 1, owner: { ...manifest.owner, importReceiptSha256: undefined } })),
  { code: 'cutover_manifest_receipt_mismatch' });
  assert.throws(() => verifyLegacyCutoverManifest(publish({ ...manifest,
    owner: { ...manifest.owner, importReceiptSha256: sha256('another receipt') } })),
  { code: 'cutover_manifest_receipt_mismatch' });
});

test('unproven tombstones, missing proofs and substituted images never write rows', async (t) => {
  for (const options of [{ tombstone: true }, { credentials: 2, verified: 1 }]) {
    await t.test(JSON.stringify(options), async (subtest) => {
      const item = await fixture(subtest, options);
      const before = readOwnerCredentialSnapshot(item.path);
      const preflight = inspectSealedLegacyImport(item.args);
      assert.equal(preflight.offlineImportEligible, false);
      assert.equal(preflight.blocker, options.tombstone
        ? 'legacy_import_tombstone_unproven' : 'legacy_import_proof_unverified');
      assert.throws(() => importSealedLegacyCredentialCohort({ ...item.args,
        expectedCandidateSha256: preflight.candidateSha256, ...item.clock }),
      { code: preflight.blocker });
      assert.deepEqual(readOwnerCredentialSnapshot(item.path), before);
    });
  }
  const item = await fixture(t);
  const preflight = inspectSealedLegacyImport(item.args);
  writeFileSync(item.args.legacySnapshotPath, Buffer.from('tampered'), { mode: 0o600 });
  assert.throws(() => importSealedLegacyCredentialCohort({ ...item.args,
    expectedCandidateSha256: preflight.candidateSha256, ...item.clock }),
  { code: 'cutover_snapshot_mismatch' });
  assert.equal(readOwnerCredentialSnapshot(item.path).legacyImportReceipts.length, 0);
});

test('changed owner state, colliding credential and owner-key mutation reject preflight', async (t) => {
  const item = await fixture(t);
  const preflight = inspectSealedLegacyImport(item.args);
  db(item.path, (handle) => handle.prepare('UPDATE credentials SET counter=counter+1 WHERE id=?')
    .run(item.ownerCredential.id));
  assert.throws(() => importSealedLegacyCredentialCohort({ ...item.args,
    expectedCandidateSha256: preflight.candidateSha256, ...item.clock }),
  { code: 'legacy_import_state_changed' });
  assert.equal(readOwnerCredentialSnapshot(item.path).legacyImportReceipts.length, 0);
  db(item.path, (handle) => {
    assert.throws(() => handle.prepare('UPDATE credentials SET public_key=? WHERE id=?')
      .run(b64(33), item.ownerCredential.id), /immutable proven owner key/);
  });
  const second = await fixture(t);
  db(second.path, (handle) => handle.prepare('INSERT INTO storage_bindings VALUES(?,?,?,?,?,?)')
    .run(second.storageKey, second.owner.subject, second.source.credentialsByStorageKey[0].ownerSubjectHash,
      second.args.expectedSourceSha256, sha256('unreviewed'), 1));
  assert.equal(inspectSealedLegacyImport(second.args).blocker, 'legacy_import_target_conflict');

  const collision = await fixture(t);
  const historical = collision.historical[0].record;
  db(collision.path, (handle) => handle.prepare('INSERT INTO credentials VALUES(?,?,?,?,?,?,?,0)')
    .run(historical.id, collision.owner.subject, historical.publicKey,
      historical.userId, historical.counter, historical.deviceType, 1));
  assert.equal(inspectSealedLegacyImport(collision.args).blocker,
    'legacy_import_credential_collision');
});

test('migrated v8-style proof metadata cannot import without a new key-bound proof', async (t) => {
  const item = await fixture(t);
  db(item.path, (handle) => {
    const proof = handle.prepare('SELECT * FROM legacy_cutover_verified_proofs').get();
    const oldCommitment = legacyCutoverProofCommitment({ ...proof, proof_version: 1,
      owner_public_key_sha256: null, owner_public_key: null });
    handle.exec('DROP TRIGGER legacy_cutover_verified_proof_no_update');
    handle.prepare(`UPDATE legacy_cutover_verified_proofs SET proof_version=1,
      owner_public_key_sha256=NULL,owner_public_key=NULL,proof_sha256=?`).run(oldCommitment);
    handle.exec(`CREATE TRIGGER legacy_cutover_verified_proof_no_update
      BEFORE UPDATE ON legacy_cutover_verified_proofs
      BEGIN SELECT RAISE(ABORT,'immutable legacy cutover proof'); END`);
  });
  assert.equal(readOwnerCredentialSnapshot(item.path).legacyCutoverVerifiedProofs[0].proof_version, 1);
  const preflight = inspectSealedLegacyImport(item.args);
  assert.equal(preflight.offlineImportEligible, false);
  assert.equal(preflight.blocker, 'legacy_import_proof_unverified');
  assert.equal(readOwnerCredentialSnapshot(item.path).legacyImportReceipts.length, 0);
});

test('owner generation change after proof rejects import without rewriting historical rows', async (t) => {
  const item = await fixture(t);
  db(item.path, (handle) => handle.prepare('UPDATE owners SET generation=generation+1 WHERE subject=?')
    .run(item.owner.subject));
  const preflight = inspectSealedLegacyImport(item.args);
  assert.equal(preflight.blocker, 'legacy_import_proof_unverified');
  assert.equal(readOwnerCredentialSnapshot(item.path).storageBindings.length, 0);
});

test('receipt commitment tampering is rejected on restart', async (t) => {
  const item = await fixture(t);
  importCandidate(item);
  db(item.path, (handle) => {
    handle.exec('DROP TRIGGER legacy_import_receipt_no_update');
    handle.prepare('UPDATE legacy_import_receipts SET public_rows_sha256=?')
      .run(sha256('substituted rows'));
    handle.exec(`CREATE TRIGGER legacy_import_receipt_no_update
      BEFORE UPDATE ON legacy_import_receipts
      BEGIN SELECT RAISE(ABORT,'immutable legacy import receipt'); END`);
  });
  assert.throws(() => readOwnerCredentialSnapshot(item.path), { code: 'store_unavailable' });
  assert.throws(() => item.open(), { code: 'store_unavailable' });
});

test('before-commit fault rolls back all rows; uncertain after-commit returns no authority', async (t) => {
  const first = await fixture(t);
  const candidate = inspectSealedLegacyImport(first.args);
  assert.throws(() => importSealedLegacyCredentialCohort({ ...first.args,
    expectedCandidateSha256: candidate.candidateSha256, ...first.clock,
    fault: (phase) => { if (phase === 'beforeCommit') throw new Error('fault'); } }),
  { code: 'store_unavailable' });
  assert.equal(readOwnerCredentialSnapshot(first.path).storageBindings.length, 0);
  assert.equal(readOwnerCredentialSnapshot(first.path).legacyImportReceipts.length, 0);
  assert.equal(importCandidate(first).durableReceiptCommitted, true);

  const second = await fixture(t);
  const secondCandidate = inspectSealedLegacyImport(second.args);
  assert.throws(() => importSealedLegacyCredentialCohort({ ...second.args,
    expectedCandidateSha256: secondCandidate.candidateSha256, ...second.clock,
    fault: (phase) => { if (phase === 'afterCommit') throw new Error('fault'); } }),
  { code: 'store_unavailable' });
  assert.equal(readOwnerCredentialSnapshot(second.path).legacyImportReceipts.length, 1);
  assert.equal(verifySealedLegacyCutover(second.args).publicRepresentationExact, true);
  assert.throws(() => importCandidate(second), { code: 'legacy_import_target_conflict' });
});

test('two processes cannot commit the same cohort twice', async (t) => {
  const item = await fixture(t);
  const expectedCandidateSha256 = inspectSealedLegacyImport(item.args).candidateSha256;
  const [one, two] = await Promise.all([worker({ ...item.args, expectedCandidateSha256 }),
    worker({ ...item.args, expectedCandidateSha256 })]);
  assert.deepEqual([one, two].map((run) => run.status).sort(), [0, 1]);
  assert.match([one, two].find((run) => run.status === 1).stderr,
    /legacy_import_(target_conflict|state_changed)/);
  assert.equal(readOwnerCredentialSnapshot(item.path).legacyImportReceipts.length, 1);
  assert.equal(verifySealedLegacyCutover(item.args).publicRepresentationExact, true);
});
