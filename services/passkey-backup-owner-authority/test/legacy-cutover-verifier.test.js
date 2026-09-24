import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { chmodSync, readFileSync, symlinkSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { DatabaseSync } from 'node:sqlite';
import test from 'node:test';
import { verifySealedLegacyCutover } from '../src/legacy-cutover-verifier.js';
import { readOwnerCredentialSnapshot } from '../src/store.js';
import { b64, downgradeStoreFixture, setup } from './fixtures.js';

const key = 'storage:historical-wallet';
const emptyKey = 'storage:historical-tombstone';
const hash = (value) => createHash('sha256').update(value).digest('base64url');
const sha256 = (value) => createHash('sha256').update(value).digest('hex');

async function fixture(t, options = {}) {
  const context = setup(t);
  const first = (await context.bootstrap()).owner;
  const second = options.secondOwner ? (await context.bootstrap(context.core, b64(3), b64(5))).owner : null;
  context.core.close();
  const historicalHash = hash('an old authorization subject, not the random owner');
  const source = {
    schemaVersion: options.sourceSchemaVersion ?? 4,
    ...(options.sourceSchemaVersion === 3 ? {} : {
      credentialOwnersById: [{ credentialId: b64(2), storageKey: key, ownerSubjectHash: historicalHash }],
    }),
    credentialsByStorageKey: [
      { storageKey: key, ownerSubjectHash: historicalHash, credentials: [{
        id: b64(2), publicKey: b64(8), userId: hash(`user\0${key}`), counter: 42,
        deviceType: 'multiDevice', backedUp: true,
        aaguid: '00000000-0000-0000-0000-000000000000', registrationPlatform: 'ios',
        transports: ['internal', 'hybrid'],
      }] },
      { storageKey: emptyKey, ownerSubjectHash: options.differentHistoricalHash
        ? hash('another old authorization subject') : historicalHash, credentials: [] },
    ],
  };
  const bytes = Buffer.from(`${options.sourceTextTransform?.(JSON.stringify(source), source) ?? JSON.stringify(source)}\n`);
  const expectedSourceSha256 = sha256(bytes);
  const legacySnapshotPath = join(context.dir, `legacy-${expectedSourceSha256}.json`);
  writeFileSync(legacySnapshotPath, bytes, { mode: 0o600 });
  const db = new DatabaseSync(context.path);
  db.exec('PRAGMA foreign_keys=ON; BEGIN IMMEDIATE');
  try {
    db.prepare(`UPDATE credentials SET public_key=?,user_handle=?,counter=?,backed_up=?
      WHERE id=?`).run(options.wrongPublicKey ? b64(9) : b64(8),
      options.wrongUserHandle ? b64(10) : source.credentialsByStorageKey[0].credentials[0].userId,
      options.wrongCounter ? 41 : 42, options.wrongBackupFlag ? 0 : 1, b64(2));
    const bind = db.prepare('INSERT INTO storage_bindings VALUES(?,?,?,?,?,?)');
    bind.run(key, first.subject, historicalHash,
      options.wrongSourceDigest ? sha256('other source') : expectedSourceSha256, sha256('proof one'), 123);
    if (!options.omitTombstone) bind.run(emptyKey,
      options.splitHistoricalOwner ? second.subject : first.subject,
      source.credentialsByStorageKey[1].ownerSubjectHash, expectedSourceSha256, sha256('proof empty'), 123);
    db.prepare('INSERT INTO legacy_credential_metadata VALUES(?,?,?,?,?)').run(
      b64(2), key, source.credentialsByStorageKey[0].credentials[0].aaguid,
      options.wrongTransports ? '["usb"]' : '["internal","hybrid"]', 'ios');
    if (options.revoked) db.prepare('UPDATE credentials SET revoked=1 WHERE id=?').run(b64(2));
    if (options.extraHistoricalRow) {
      bind.run('storage:unexpected-wallet', second.subject, hash('extra'),
        expectedSourceSha256, sha256('proof extra'), 123);
      db.prepare('INSERT INTO legacy_credential_metadata VALUES(?,?,?,?,?)').run(
        b64(3), 'storage:unexpected-wallet', '00000000-0000-0000-0000-000000000000', null, 'android');
    }
    db.exec('COMMIT');
  } catch (error) { db.exec('ROLLBACK'); throw error; }
  finally { db.close(); }
  return { ...context, first, second, historicalHash, source, bytes, legacySnapshotPath,
    expectedSourceSha256, args: { legacySnapshotPath, ownerPath: context.path, expectedSourceSha256 } };
}

test('sealed v4 public rows, exact legacy handle/counter and empty tombstone compare without writing', async (t) => {
  const item = await fixture(t);
  assert.notEqual(item.historicalHash, hash(item.first.subject));
  const beforeSqlite = readFileSync(item.path);
  const beforeSource = readFileSync(item.legacySnapshotPath);
  const report = verifySealedLegacyCutover(item.args);
  assert.equal(report.mode, 'read-only');
  assert.equal(report.migrationPermitted, false);
  assert.equal(report.publicRepresentationExact, true);
  assert.match(report.comparedTargetRowsSha256, /^[0-9a-f]{64}$/);
  assert.deepEqual(report.counts, {
    sourceStorageKeys: 2, sourceCredentials: 1, sourceTombstones: 1,
    targetBindings: 2, targetHistoricalMetadata: 1,
    matchedBindings: 2, matchedCredentials: 1, matchedTombstones: 1,
    targetOwnerOnlyCredentials: 0, discrepancies: 0,
  });
  assert.deepEqual(report.diagnostics, []);
  assert.ok(report.blockers.includes('fresh_legacy_credential_assertion_and_random_owner_proof_unverified'));
  assert.equal(JSON.stringify(report).includes(key), false);
  assert.equal(JSON.stringify(report).includes(item.first.subject), false);
  assert.equal(JSON.stringify(report).includes(b64(2)), false);
  assert.deepEqual(readFileSync(item.path), beforeSqlite);
  assert.deepEqual(readFileSync(item.legacySnapshotPath), beforeSource);
  assert.equal(readOwnerCredentialSnapshot(item.path).credentials[0].user_handle,
    item.source.credentialsByStorageKey[0].credentials[0].userId);
  item.open();
  const reopened = verifySealedLegacyCutover(item.args);
  assert.equal(reopened.publicRepresentationExact, true);
  assert.equal(reopened.comparedTargetRowsSha256, report.comparedTargetRowsSha256);
});

test('sealed v3 source is compared without migrating its JSON file', async (t) => {
  const item = await fixture(t, { sourceSchemaVersion: 3 });
  const before = readFileSync(item.legacySnapshotPath);
  const report = verifySealedLegacyCutover(item.args);
  assert.equal(report.sourceSchemaVersion, 3);
  assert.equal(report.publicRepresentationExact, true);
  assert.equal(report.migrationPermitted, false);
  assert.deepEqual(readFileSync(item.legacySnapshotPath), before);
});

test('sealed images with shadowed top-level or nested JSON members cannot claim exactness', async (t) => {
  for (const member of ['top-level', 'nested']) {
    await t.test(member, async (subtest) => {
      const item = await fixture(subtest, {
        sourceSchemaVersion: 3,
        sourceTextTransform: (sourceText, source) => {
          const hiddenTombstone = JSON.stringify({
            storageKey: 'storage:old-wallet',
            ownerSubjectHash: source.credentialsByStorageKey[0].ownerSubjectHash,
            credentials: [],
          });
          return member === 'top-level'
            ? sourceText.replace('"credentialsByStorageKey":',
              `"credentialsByStorageKey":[${hiddenTombstone}],"credentialsByStorageKey":`)
            : sourceText.replace('"credentials":[{', '"credentials":[],"credentials":[{');
        },
      });
      assert.throws(() => verifySealedLegacyCutover(item.args), { code: 'credential_store_invalid' });
    });
  }
});

test('source digest, owner hash, metadata, tombstone, aliases and extra rows fail closed', async (t) => {
  const cases = [
    [{ omitTombstone: true }, 'storage_binding_missing'],
    [{ wrongSourceDigest: true }, 'binding_source_digest_mismatch'],
    [{ wrongTransports: true }, 'credential_metadata_mismatch'],
    [{ wrongPublicKey: true }, 'credential_public_state_mismatch'],
    [{ wrongUserHandle: true }, 'credential_public_state_mismatch'],
    [{ wrongCounter: true }, 'credential_public_state_mismatch'],
    [{ wrongBackupFlag: true }, 'credential_public_state_mismatch'],
    [{ revoked: true }, 'credential_public_state_mismatch'],
    [{ secondOwner: true, splitHistoricalOwner: true }, 'historical_owner_split'],
    [{ differentHistoricalHash: true }, 'random_owner_alias_ambiguous'],
    [{ secondOwner: true, extraHistoricalRow: true }, 'target_binding_not_in_source'],
  ];
  for (const [options, expectedKind] of cases) {
    await t.test(expectedKind, async (subtest) => {
      const item = await fixture(subtest, options);
      const report = verifySealedLegacyCutover(item.args);
      assert.equal(report.publicRepresentationExact, false);
      assert.equal(report.migrationPermitted, false);
      assert.ok(report.diagnostics.some((entry) => entry.kind === expectedKind), JSON.stringify(report));
    });
  }
});

test('source historical hash mismatch and a pre-v5 target cannot pass comparison', async (t) => {
  await t.test('historical hash', async (subtest) => {
    const item = await fixture(subtest);
    const altered = JSON.parse(item.bytes.toString('utf8'));
    const different = hash('different old subject');
    altered.credentialsByStorageKey[1].ownerSubjectHash = different;
    const bytes = Buffer.from(`${JSON.stringify(altered)}\n`);
    const digest = sha256(bytes);
    // A changed image under a different digest is still blocked by the exact
    // binding's historical hash and source-digest comparison.
    const alternate = join(item.dir, `legacy-${digest}.json`);
    writeFileSync(alternate, bytes, { mode: 0o600 });
    const report = verifySealedLegacyCutover({
      ...item.args, legacySnapshotPath: alternate, expectedSourceSha256: digest,
    });
    assert.equal(report.publicRepresentationExact, false);
    assert.ok(report.diagnostics.some((entry) => entry.kind === 'binding_legacy_owner_hash_mismatch'));
  });
  await t.test('schema rollback', async (subtest) => {
    const item = await fixture(subtest);
    downgradeStoreFixture(item.path, 4);
    assert.throws(() => verifySealedLegacyCutover(item.args),
      { code: 'cutover_owner_schema_mismatch' });
  });
});

test('counter, public key, handle and revocation mismatches are detected after durable restart', async (t) => {
  const cases = [
    ['counter', 'UPDATE credentials SET counter=43 WHERE id=?', [b64(2)]],
    ['revoked', 'UPDATE credentials SET revoked=1 WHERE id=?', [b64(2)]],
  ];
  for (const [name, sql, params] of cases) {
    await t.test(name, async (subtest) => {
      const item = await fixture(subtest);
      const before = verifySealedLegacyCutover(item.args);
      const db = new DatabaseSync(item.path);
      db.prepare(sql).run(...params);
      db.close();
      item.open();
      const report = verifySealedLegacyCutover(item.args);
      assert.equal(report.publicRepresentationExact, false);
      assert.notEqual(report.comparedTargetRowsSha256, before.comparedTargetRowsSha256);
      assert.ok(report.diagnostics.some((entry) => entry.kind === 'credential_public_state_mismatch'));
    });
  }
  await t.test('public key and handle before binding metadata', async (subtest) => {
    const item = await fixture(subtest);
    const db = new DatabaseSync(item.path);
    // SQLite correctly forbids changing a bound historical key or handle.
    assert.throws(() => db.prepare('UPDATE credentials SET public_key=? WHERE id=?').run(b64(9), b64(2)),
      /immutable legacy credential identity/);
    assert.throws(() => db.prepare('UPDATE credentials SET user_handle=? WHERE id=?').run(b64(9), b64(2)),
      /immutable legacy credential identity/);
    db.close();
    assert.equal(verifySealedLegacyCutover(item.args).publicRepresentationExact, true);
  });
});

test('modified, symlinked and non-private sealed sources never yield a report', async (t) => {
  const item = await fixture(t);
  writeFileSync(item.legacySnapshotPath, Buffer.from('tampered'));
  assert.throws(() => verifySealedLegacyCutover(item.args), { code: 'cutover_snapshot_mismatch' });
  writeFileSync(item.legacySnapshotPath, item.bytes);
  const alias = join(item.dir, 'alias.json');
  symlinkSync(item.legacySnapshotPath, alias);
  assert.throws(() => verifySealedLegacyCutover({ ...item.args, legacySnapshotPath: alias }),
    { code: 'cutover_invalid_request' });
  chmodSync(item.legacySnapshotPath, 0o644);
  assert.throws(() => verifySealedLegacyCutover(item.args), { code: 'quarantine_path_unsafe' });
});

test('operator CLI retains blocked exit even when public representation is exact', async (t) => {
  const item = await fixture(t);
  const script = new URL('../scripts/verify-sealed-legacy-cutover.mjs', import.meta.url);
  const run = spawnSync(process.execPath, [script.pathname,
    item.legacySnapshotPath, item.path, item.expectedSourceSha256], { encoding: 'utf8' });
  assert.equal(run.status, 3, run.stderr);
  const report = JSON.parse(run.stdout);
  assert.equal(report.publicRepresentationExact, true);
  assert.equal(report.migrationPermitted, false);
  assert.equal(run.stdout.includes(key), false);
  assert.equal(run.stdout.includes(item.first.subject), false);
  const bad = spawnSync(process.execPath, [script.pathname,
    item.legacySnapshotPath, item.path, sha256('wrong')], { encoding: 'utf8' });
  assert.equal(bad.status, 1);
  assert.equal(bad.stdout, '');
});
