import assert from 'node:assert/strict';
import { fork } from 'node:child_process';
import { createHash } from 'node:crypto';
import { readFileSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { DatabaseSync } from 'node:sqlite';
import test from 'node:test';
import { readOwnerCredentialSnapshot } from '../src/store.js';
import { hash } from '../src/validation.js';
import { assertion, audience, b64, downgradeStoreFixture, setup } from './fixtures.js';

const storageKey = 'storage:cutover-wallet';
const legacyId = b64(77);
const sourceHash = hash('historical-grant-subject');
const digest = (bytes) => createHash('sha256').update(bytes).digest('hex');

function denied(action, code = 'authorization_failed') {
  assert.throws(action, (error) => error.code === code, `expected ${code}`);
}

async function fixture(t, options = {}) {
  const context = setup(t, options);
  const { owner } = await context.bootstrap();
  const ownerCredential = readOwnerCredentialSnapshot(context.path).credentials[0];
  const legacyUserHandle = hash(`user\0${storageKey}`);
  const source = {
    schemaVersion: 4,
    credentialOwnersById: [{ credentialId: legacyId, storageKey, ownerSubjectHash: sourceHash }],
    credentialsByStorageKey: [{ storageKey, ownerSubjectHash: sourceHash, credentials: [{
      id: legacyId, publicKey: b64(88), userId: legacyUserHandle, counter: 7,
      deviceType: 'multiDevice', backedUp: true,
      aaguid: '00000000-0000-0000-0000-000000000000', registrationPlatform: 'ios',
      transports: ['internal', 'hybrid'],
    }] }],
  };
  const bytes = Buffer.from(`${JSON.stringify(source)}\n`);
  const expectedSourceSha256 = digest(bytes);
  const legacySnapshotPath = join(context.dir, `legacy-${expectedSourceSha256}.json`);
  writeFileSync(legacySnapshotPath, bytes, { mode: 0o600 });
  const issueInput = { schemaVersion: 1, legacySnapshotPath, expectedSourceSha256,
    storageKey, credentialId: legacyId };
  const claims = { schemaVersion: 1, legacyAssertion: assertion(legacyUserHandle, legacyId),
    ownerAssertion: assertion(ownerCredential.user_handle, ownerCredential.id) };
  return { ...context, owner, ownerCredential, source, bytes, expectedSourceSha256,
    legacySnapshotPath, issueInput, claims };
}

function row(path, id) {
  const db = new DatabaseSync(path, { readOnly: true });
  try { return db.prepare('SELECT * FROM legacy_cutover_challenges WHERE id=?').get(id); }
  finally { db.close(); }
}

function alternateSource(item, source) {
  const bytes = Buffer.from(`${JSON.stringify(source)}\n`);
  const expectedSourceSha256 = digest(bytes);
  const legacySnapshotPath = join(item.dir, `legacy-${expectedSourceSha256}.json`);
  writeFileSync(legacySnapshotPath, bytes, { mode: 0o600 });
  return { schemaVersion: 1, legacySnapshotPath, expectedSourceSha256,
    storageKey, credentialId: source.credentialsByStorageKey[0].credentials[0].id };
}

function worker(item, input) {
  return new Promise((resolve, reject) => {
    const child = fork(new URL('./process-worker.js', import.meta.url), [], { stdio: ['ignore', 'ignore', 'ignore', 'ipc'] });
    let received;
    child.on('message', (message) => { received = message; });
    child.on('error', reject);
    child.on('exit', (code) => code === 0 && received ? resolve(received) : reject(new Error(`worker exited ${code}`)));
    child.send({ path: item.path, audience, token: item.owner.sessionToken, action: 'claim-cutover',
      wall: item.clock.wall, cutoverClaim: input });
  });
}

test('v1 cutover challenge binds exact sealed public cohort and only burns an unverified claim', async (t) => {
  const item = await fixture(t);
  const beforeSource = readFileSync(item.legacySnapshotPath);
  const beforeCredential = readOwnerCredentialSnapshot(item.path).credentials;
  const challenge = item.core.issueLegacyCutoverChallenge(item.owner.sessionToken, item.issueInput);
  assert.equal(challenge.schemaVersion, 1);
  assert.equal(challenge.migrationPermitted, false);
  assert.equal(challenge.sourceSha256, item.expectedSourceSha256);
  assert.equal(challenge.legacyCredentialId, legacyId);
  assert.notEqual(challenge.legacyChallenge, challenge.ownerChallenge);
  const issued = row(item.path, challenge.challengeId);
  assert.equal(issued.version, 1);
  assert.equal(issued.source_sha256, item.expectedSourceSha256);
  assert.equal(issued.snapshot_name, `legacy-${item.expectedSourceSha256}.json`);
  assert.equal(issued.legacy_owner_hash, sourceHash);
  assert.equal(issued.legacy_credential_id, legacyId);
  assert.equal(issued.legacy_public_key_sha256, digest(Buffer.from(b64(88), 'base64url')));
  assert.equal(issued.legacy_counter, 7);
  assert.equal(issued.legacy_scope, 'storage');
  assert.equal(issued.owner, item.owner.subject);
  assert.equal(issued.owner_credential_counter, item.ownerCredential.counter);
  assert.equal(issued.rp_id, 'fearlesswallet.io');
  assert.equal(issued.platform, 'android');
  assert.equal(issued.state, 0);
  assert.equal(issued.legacy_body_sha256, null);
  assert.equal(issued.owner_body_sha256, null);
  assert.equal(JSON.stringify(issued).includes(item.source.credentialsByStorageKey[0].credentials[0].publicKey), false);
  const claimInput = { ...item.claims, challengeId: challenge.challengeId };
  assert.equal(item.core.claimLegacyCutoverChallenge(item.owner.sessionToken, claimInput).migrationPermitted, false);
  assert.equal(row(item.path, challenge.challengeId).state, 1);
  denied(() => item.core.claimLegacyCutoverChallenge(item.owner.sessionToken, claimInput));
  assert.deepEqual(item.core.consumeLegacyCutoverClaim(item.owner.sessionToken, {
    ...claimInput, legacySnapshotPath: item.legacySnapshotPath,
    expectedSourceSha256: item.expectedSourceSha256,
  }), { schemaVersion: 1, challengeId: challenge.challengeId,
    state: 'consumed-unverified', expiresAt: challenge.expiresAt,
    migrationPermitted: false });
  assert.equal(row(item.path, challenge.challengeId).state, 2);
  denied(() => item.core.consumeLegacyCutoverClaim(item.owner.sessionToken, {
    ...claimInput, legacySnapshotPath: item.legacySnapshotPath,
    expectedSourceSha256: item.expectedSourceSha256,
  }));
  assert.deepEqual(readFileSync(item.legacySnapshotPath), beforeSource);
  assert.deepEqual(readOwnerCredentialSnapshot(item.path).credentials, beforeCredential);
  assert.deepEqual(readOwnerCredentialSnapshot(item.path).storageBindings, []);
});

test('a v7 consumed claim migrates as unverified and cannot acquire a proof by direct SQL', async (t) => {
  const item = await fixture(t);
  const issued = item.core.issueLegacyCutoverChallenge(item.owner.sessionToken, item.issueInput);
  const claimed = { ...item.claims, challengeId: issued.challengeId };
  item.core.claimLegacyCutoverChallenge(item.owner.sessionToken, claimed);
  assert.equal(item.core.consumeLegacyCutoverClaim(item.owner.sessionToken, {
    ...claimed, legacySnapshotPath: item.legacySnapshotPath,
    expectedSourceSha256: item.expectedSourceSha256,
  }).state, 'consumed-unverified');
  item.core.close();
  downgradeStoreFixture(item.path, 7);
  assert.equal(readOwnerCredentialSnapshot(item.path).schemaVersion, 7);
  denied(() => item.open(), 'store_unavailable');
  const migrated = item.open({ migrate: true });
  assert.equal(row(item.path, issued.challengeId).state, 2);
  const db = new DatabaseSync(item.path);
  try {
    assert.equal(db.prepare('PRAGMA user_version').get().user_version, 8);
    assert.equal(db.prepare('SELECT count(*) AS n FROM legacy_cutover_verified_proofs').get().n, 0);
    const old = row(item.path, issued.challengeId);
    assert.throws(() => db.prepare(`INSERT INTO legacy_cutover_verified_proofs (
      challenge_id,proof_sha256,source_sha256,owner,legacy_credential_id,owner_credential_id,
      legacy_body_sha256,owner_body_sha256,legacy_challenge_sha256,owner_challenge_sha256,
      legacy_new_counter,owner_new_counter,legacy_device_type,legacy_backed_up,
      owner_device_type,owner_backed_up,verified_at) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)`).run(
      old.id, digest('forged-proof'), old.source_sha256, old.owner,
      old.legacy_credential_id, old.owner_credential_id, old.legacy_body_sha256,
      old.owner_body_sha256, digest(issued.legacyChallenge), digest(issued.ownerChallenge),
      8, old.owner_credential_counter, 'multiDevice', 1, 'multiDevice', 1,
      old.expires - 1000), /invalid legacy cutover proof/);
    assert.equal(db.prepare('SELECT count(*) AS n FROM legacy_cutover_verified_proofs').get().n, 0);
  } finally { db.close(); }
  assert.equal(readOwnerCredentialSnapshot(item.path).schemaVersion, 8);
  migrated.close();
});

test('cutover claim rejects substitution, source changes and another owner session', async (t) => {
  const item = await fixture(t);
  const challenge = item.core.issueLegacyCutoverChallenge(item.owner.sessionToken, item.issueInput);
  const claimInput = { ...item.claims, challengeId: challenge.challengeId };
  denied(() => item.core.claimLegacyCutoverChallenge(item.owner.sessionToken, {
    ...claimInput, legacyAssertion: assertion(item.claims.legacyAssertion.response.userHandle, b64(99)),
  }));
  denied(() => item.core.claimLegacyCutoverChallenge(item.owner.sessionToken, {
    ...claimInput, ownerAssertion: assertion(item.ownerCredential.user_handle, b64(99)),
  }));
  const second = (await item.bootstrap(item.core, b64(3), b64(5))).owner;
  denied(() => item.core.claimLegacyCutoverChallenge(second.sessionToken, claimInput));
  assert.equal(row(item.path, challenge.challengeId).state, 0);
  item.core.claimLegacyCutoverChallenge(item.owner.sessionToken, claimInput);
  denied(() => item.core.consumeLegacyCutoverClaim(item.owner.sessionToken, {
    ...claimInput, legacySnapshotPath: item.legacySnapshotPath,
    expectedSourceSha256: digest('other source'),
  }));
  denied(() => item.core.consumeLegacyCutoverClaim(item.owner.sessionToken, {
    ...claimInput, legacySnapshotPath: item.legacySnapshotPath,
    expectedSourceSha256: item.expectedSourceSha256,
    legacyAssertion: { ...item.claims.legacyAssertion,
      response: { ...item.claims.legacyAssertion.response, signature: b64(10, 64) } },
  }));
  writeFileSync(item.legacySnapshotPath, Buffer.from('tampered'), { mode: 0o600 });
  denied(() => item.core.consumeLegacyCutoverClaim(item.owner.sessionToken, {
    ...claimInput, legacySnapshotPath: item.legacySnapshotPath,
    expectedSourceSha256: item.expectedSourceSha256,
  }), 'cutover_source_invalid');
  assert.equal(row(item.path, challenge.challengeId).state, 1);
});

test('malformed source, existing credential IDs and conflicting pending owners cannot issue', async (t) => {
  const item = await fixture(t);
  denied(() => item.core.issueLegacyCutoverChallenge(item.owner.sessionToken, {
    ...item.issueInput, credentialId: b64(99),
  }), 'cutover_source_invalid');
  const replaced = { ...item.source,
    credentialOwnersById: [{ credentialId: item.ownerCredential.id, storageKey, ownerSubjectHash: sourceHash }],
    credentialsByStorageKey: [{ ...item.source.credentialsByStorageKey[0], credentials: [{
      ...item.source.credentialsByStorageKey[0].credentials[0], id: item.ownerCredential.id,
    }] }],
  };
  denied(() => item.core.issueLegacyCutoverChallenge(item.owner.sessionToken,
    alternateSource(item, replaced)), 'cutover_identity_collision');
  const shadowed = Buffer.from(item.bytes.toString('utf8').replace('"credentials":[{', '"credentials":[],"credentials":[{'));
  const shadowDigest = digest(shadowed);
  const shadowPath = join(item.dir, `legacy-${shadowDigest}.json`);
  writeFileSync(shadowPath, shadowed, { mode: 0o600 });
  denied(() => item.core.issueLegacyCutoverChallenge(item.owner.sessionToken, {
    ...item.issueInput, legacySnapshotPath: shadowPath, expectedSourceSha256: shadowDigest,
  }), 'cutover_source_invalid');
  item.core.issueLegacyCutoverChallenge(item.owner.sessionToken, item.issueInput);
  const changedSource = { ...item.source,
    credentialOwnersById: [{ credentialId: b64(79), storageKey, ownerSubjectHash: sourceHash }],
    credentialsByStorageKey: [{ ...item.source.credentialsByStorageKey[0], credentials: [{
      ...item.source.credentialsByStorageKey[0].credentials[0], id: b64(79),
    }] }],
  };
  denied(() => item.core.issueLegacyCutoverChallenge(item.owner.sessionToken,
    alternateSource(item, changedSource)), 'cutover_identity_collision');
  const second = (await item.bootstrap(item.core, b64(3), b64(5))).owner;
  const differentCredential = { ...item.source,
    credentialOwnersById: [{ credentialId: b64(78), storageKey, ownerSubjectHash: sourceHash }],
    credentialsByStorageKey: [{ ...item.source.credentialsByStorageKey[0], credentials: [{
      ...item.source.credentialsByStorageKey[0].credentials[0], id: b64(78),
    }] }],
  };
  denied(() => item.core.issueLegacyCutoverChallenge(second.sessionToken,
    alternateSource(item, differentCredential)), 'cutover_identity_collision');
  const differentHistoricalOwner = { ...differentCredential,
    credentialOwnersById: [{ credentialId: b64(78), storageKey,
      ownerSubjectHash: hash('different-historical-owner') }],
    credentialsByStorageKey: [{ ...differentCredential.credentialsByStorageKey[0],
      ownerSubjectHash: hash('different-historical-owner') }],
  };
  denied(() => item.core.issueLegacyCutoverChallenge(second.sessionToken,
    alternateSource(item, differentHistoricalOwner)), 'cutover_identity_collision');
});

test('directed cutover assertions may omit handles but reject a supplied wrong handle', async (t) => {
  const item = await fixture(t);
  const challenge = item.core.issueLegacyCutoverChallenge(item.owner.sessionToken, item.issueInput);
  const claims = { schemaVersion: 1, challengeId: challenge.challengeId,
    legacyAssertion: assertion(null, legacyId),
    ownerAssertion: assertion(null, item.ownerCredential.id) };
  denied(() => item.core.claimLegacyCutoverChallenge(item.owner.sessionToken, {
    ...claims, legacyAssertion: assertion(b64(99), legacyId),
  }));
  assert.equal(item.core.claimLegacyCutoverChallenge(item.owner.sessionToken, claims)
    .migrationPermitted, false);
});

test('pending cutover quota is bounded and issued identity fields cannot be rewritten', async (t) => {
  const item = await fixture(t);
  const credentialIds = Array.from({ length: 9 }, (_, index) => b64(90 + index));
  const source = { ...item.source,
    credentialOwnersById: credentialIds.map((credentialId) =>
      ({ credentialId, storageKey, ownerSubjectHash: sourceHash })),
    credentialsByStorageKey: [{ ...item.source.credentialsByStorageKey[0],
      credentials: credentialIds.map((id) => ({
        ...item.source.credentialsByStorageKey[0].credentials[0], id,
      })) }],
  };
  const sourceInput = alternateSource(item, source);
  for (let index = 0; index < 8; index += 1) {
    const issued = item.core.issueLegacyCutoverChallenge(item.owner.sessionToken,
      { ...sourceInput, credentialId: credentialIds[index] });
    if (index === 0) {
      const db = new DatabaseSync(item.path);
      try {
        assert.throws(() => db.prepare('UPDATE legacy_cutover_challenges SET storage_key=? WHERE id=?')
          .run('storage:substituted', issued.challengeId));
        assert.throws(() => db.prepare('UPDATE legacy_cutover_challenges SET state=1 WHERE id=?')
          .run(issued.challengeId));
      } finally { db.close(); }
    }
  }
  denied(() => item.core.issueLegacyCutoverChallenge(item.owner.sessionToken,
    { ...sourceInput, credentialId: credentialIds[8] }), 'rate_limited');
  assert.equal(readOwnerCredentialSnapshot(item.path).credentials.length, 1);
});

test('counter, generation and expiry changes invalidate an outstanding cutover claim', async (t) => {
  await t.test('owner counter', async (subtest) => {
    const item = await fixture(subtest);
    const challenge = item.core.issueLegacyCutoverChallenge(item.owner.sessionToken, item.issueInput);
    const db = new DatabaseSync(item.path);
    db.prepare('UPDATE credentials SET counter=counter+1 WHERE id=?').run(item.ownerCredential.id);
    db.close();
    denied(() => item.core.claimLegacyCutoverChallenge(item.owner.sessionToken,
      { ...item.claims, challengeId: challenge.challengeId }));
  });
  await t.test('owner counter after claim', async (subtest) => {
    const item = await fixture(subtest);
    const challenge = item.core.issueLegacyCutoverChallenge(item.owner.sessionToken, item.issueInput);
    const claimInput = { ...item.claims, challengeId: challenge.challengeId };
    item.core.claimLegacyCutoverChallenge(item.owner.sessionToken, claimInput);
    const db = new DatabaseSync(item.path);
    db.prepare('UPDATE credentials SET counter=counter+1 WHERE id=?').run(item.ownerCredential.id);
    db.close();
    denied(() => item.core.consumeLegacyCutoverClaim(item.owner.sessionToken, {
      ...claimInput, legacySnapshotPath: item.legacySnapshotPath,
      expectedSourceSha256: item.expectedSourceSha256,
    }));
    assert.equal(row(item.path, challenge.challengeId).state, 1);
  });
  await t.test('owner generation', async (subtest) => {
    const item = await fixture(subtest);
    const challenge = item.core.issueLegacyCutoverChallenge(item.owner.sessionToken, item.issueInput);
    item.core.revokeSessions(item.owner.sessionToken);
    denied(() => item.core.claimLegacyCutoverChallenge(item.owner.sessionToken,
      { ...item.claims, challengeId: challenge.challengeId }));
    assert.equal(row(item.path, challenge.challengeId).state, 0);
  });
  await t.test('expiry', async (subtest) => {
    const item = await fixture(subtest);
    const challenge = item.core.issueLegacyCutoverChallenge(item.owner.sessionToken, item.issueInput);
    item.clock.mono += 121_000;
    denied(() => item.core.claimLegacyCutoverChallenge(item.owner.sessionToken,
      { ...item.claims, challengeId: challenge.challengeId }));
  });
});

test('a commit crossing expiry burns the claim without returning current authority', async (t) => {
  await t.test('claim', async (subtest) => {
    let armed = false;
    let item;
    item = await fixture(subtest, { fault(stage) {
      if (armed && stage === 'beforeCommit') item.clock.mono += 121_000;
    } });
    const challenge = item.core.issueLegacyCutoverChallenge(item.owner.sessionToken, item.issueInput);
    armed = true;
    denied(() => item.core.claimLegacyCutoverChallenge(item.owner.sessionToken,
      { ...item.claims, challengeId: challenge.challengeId }), 'authorization_expired');
    assert.equal(row(item.path, challenge.challengeId).state, 1);
  });
  await t.test('consume', async (subtest) => {
    let armed = false;
    let item;
    item = await fixture(subtest, { fault(stage) {
      if (armed && stage === 'beforeCommit') item.clock.mono += 121_000;
    } });
    const challenge = item.core.issueLegacyCutoverChallenge(item.owner.sessionToken, item.issueInput);
    const claimInput = { ...item.claims, challengeId: challenge.challengeId };
    item.core.claimLegacyCutoverChallenge(item.owner.sessionToken, claimInput);
    armed = true;
    denied(() => item.core.consumeLegacyCutoverClaim(item.owner.sessionToken, {
      ...claimInput, legacySnapshotPath: item.legacySnapshotPath,
      expectedSourceSha256: item.expectedSourceSha256,
    }), 'authorization_expired');
    assert.equal(row(item.path, challenge.challengeId).state, 2);
  });
});

test('revoking the owner session retains a claimed replay tombstone across restart', async (t) => {
  const item = await fixture(t);
  const challenge = item.core.issueLegacyCutoverChallenge(item.owner.sessionToken, item.issueInput);
  const claimInput = { ...item.claims, challengeId: challenge.challengeId };
  item.core.claimLegacyCutoverChallenge(item.owner.sessionToken, claimInput);
  item.core.revokeSessions(item.owner.sessionToken);
  assert.equal(row(item.path, challenge.challengeId).state, 1);
  item.core.close();
  const reopened = item.open();
  assert.equal(readOwnerCredentialSnapshot(item.path).schemaVersion, 8);
  denied(() => reopened.claimLegacyCutoverChallenge(item.owner.sessionToken, claimInput));
  denied(() => reopened.consumeLegacyCutoverClaim(item.owner.sessionToken, {
    ...claimInput, legacySnapshotPath: item.legacySnapshotPath,
    expectedSourceSha256: item.expectedSourceSha256,
  }));
  const auth = reopened.beginAuthentication('android');
  const renewed = await reopened.completeAuthentication({ ceremonyId: auth.ceremonyId,
    credential: assertion(item.ownerCredential.user_handle, item.ownerCredential.id) });
  denied(() => reopened.issueLegacyCutoverChallenge(renewed.sessionToken, item.issueInput), 'rate_limited');
  assert.equal(row(item.path, challenge.challengeId).state, 1);
});

test('one cross-process claim wins and a claimed challenge survives restart', async (t) => {
  const item = await fixture(t);
  const challenge = item.core.issueLegacyCutoverChallenge(item.owner.sessionToken, item.issueInput);
  const claimInput = { ...item.claims, challengeId: challenge.challengeId };
  const outcomes = await Promise.all([worker(item, claimInput), worker(item, claimInput)]);
  assert.deepEqual(outcomes.map((result) => result.accepted).sort(), [false, true]);
  assert.equal(row(item.path, challenge.challengeId).state, 1);
  item.core.close();
  const reopened = item.open();
  denied(() => reopened.claimLegacyCutoverChallenge(item.owner.sessionToken, claimInput));
  assert.equal(reopened.consumeLegacyCutoverClaim(item.owner.sessionToken, {
    ...claimInput, legacySnapshotPath: item.legacySnapshotPath,
    expectedSourceSha256: item.expectedSourceSha256,
  }).migrationPermitted, false);
  assert.equal(row(item.path, challenge.challengeId).state, 2);
});
