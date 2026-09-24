import test from 'node:test';
import assert from 'node:assert/strict';
import { fork } from 'node:child_process';
import { DatabaseSync } from 'node:sqlite';
import { assertion, b64, audience, downgradeStoreFixture, register, request, setup } from './fixtures.js';

const denies = (action, code) => assert.throws(action, (error) => error.code === code);
function candidate(owner, overrides = {}) {
  return {
    schemaVersion: 1, operationId: b64(21), generationId: b64(22),
    backupNamespace: owner.namespace, expectedHeadRevision: '0', expectedHeadSha256: null,
    bundleSha256: 'a'.repeat(64), keyEpoch: '1', driveFileId: 'drive-file-one',
    storageAccountBinding: 'b'.repeat(64), ...overrides,
  };
}
function commit(core, sessionToken, input) {
  const grant = core.issueGenerationGrant(sessionToken, input);
  return core.commitGenerationMetadata(grant.token, input, sessionToken);
}
function worker(message) {
  return new Promise((resolve, reject) => {
    const child = fork(new URL('./process-worker.js', import.meta.url), { stdio: ['ignore', 'ignore', 'pipe', 'ipc'] });
    let result;
    let diagnostic = '';
    child.stderr.on('data', (bytes) => { diagnostic += bytes; });
    child.on('message', (value) => { result = value; });
    child.on('error', reject);
    child.on('exit', (code) => resolve({ code, result, diagnostic }));
    child.send(message);
  });
}

test('authenticated metadata CAS retains the previous accepted descriptor and survives restart', async (t) => {
  const { core, open, bootstrap } = setup(t);
  const { owner } = await bootstrap();
  assert.deepEqual(core.readBackupHead(owner.sessionToken), {
    schemaVersion: 1, ownerSubject: owner.subject, backupNamespace: owner.namespace, head: null, previous: null,
  });
  const first = candidate(owner);
  const accepted = commit(core, owner.sessionToken, first);
  assert.equal(accepted.status, 'committed');
  assert.equal(accepted.descriptor.headRevision, '1');
  assert.equal(accepted.descriptor.parentHeadRevision, '0');
  assert.equal(accepted.descriptor.parentHeadSha256, null);
  assert.equal(core.backupOperationStatus(owner.sessionToken, first.operationId).status, 'committed');
  const second = candidate(owner, {
    operationId: b64(23), generationId: b64(24), expectedHeadRevision: '1',
    expectedHeadSha256: first.bundleSha256, bundleSha256: 'c'.repeat(64), driveFileId: 'drive-file-two',
  });
  commit(core, owner.sessionToken, second);
  denies(() => commit(core, owner.sessionToken, candidate(owner, {
    operationId: b64(29), generationId: b64(30), expectedHeadRevision: '2',
    expectedHeadSha256: second.bundleSha256, bundleSha256: first.bundleSha256,
    driveFileId: 'drive-file-three',
  })), 'generation_conflict');
  const current = core.readBackupHead(owner.sessionToken);
  assert.equal(current.head.generationId, second.generationId);
  assert.equal(current.head.parentHeadRevision, '1');
  assert.equal(current.head.parentHeadSha256, first.bundleSha256);
  assert.deepEqual(current.previous, accepted.descriptor);
  core.close();
  const restarted = open();
  assert.deepEqual(restarted.readBackupHead(owner.sessionToken), current);
  // The original exact operation remains reconcilable after a later head update.
  assert.deepEqual(commit(restarted, owner.sessionToken, { ...first }), accepted);
  assert.equal(restarted.backupOperationStatus(owner.sessionToken, second.operationId).descriptor.parentHeadSha256,
    first.bundleSha256);
  assert.equal(restarted.backupOperationStatus(owner.sessionToken, b64(99)).status, 'absent');
});

test('head mutation needs its own exact single-use grant, never a session or seven-route grant', async (t) => {
  const { core, bootstrap } = setup(t);
  const { owner } = await bootstrap();
  const first = candidate(owner);
  const generationGrant = core.issueGenerationGrant(owner.sessionToken, first);
  const routeGrant = core.issueGrant(owner.sessionToken, request());
  denies(() => core.commitGenerationMetadata(owner.sessionToken, first, owner.sessionToken), 'authorization_failed');
  denies(() => core.commitGenerationMetadata(routeGrant.token, first, owner.sessionToken), 'authorization_failed');
  denies(() => core.consumeGrant(generationGrant.token, request()), 'authorization_failed');
  denies(() => core.commitGenerationMetadata(generationGrant.token,
    { ...first, bundleSha256: 'c'.repeat(64) }, owner.sessionToken), 'authorization_failed');
  denies(() => core.commitGenerationMetadata(generationGrant.token, first), 'authorization_failed');
  const { owner: stranger } = await bootstrap(core, b64(7), b64(10));
  denies(() => core.commitGenerationMetadata(generationGrant.token, first, stranger.sessionToken),
    'authorization_failed');
  assert.equal(core.readBackupHead(owner.sessionToken).head, null);
  assert.equal(core.commitGenerationMetadata(generationGrant.token, first, owner.sessionToken).descriptor.headRevision, '1');
  denies(() => core.commitGenerationMetadata(generationGrant.token, first, owner.sessionToken), 'authorization_failed');
  assert.equal(core.consumeGrant(routeGrant.token, request()).active, true);
  assert.equal(commit(core, owner.sessionToken, first).descriptor.headRevision, '1');
});

test('expired or revoked generation grants cannot change a head', async (t) => {
  const { core, open, clock, bootstrap } = setup(t);
  const { owner } = await bootstrap();
  const first = candidate(owner);
  const expired = core.issueGenerationGrant(owner.sessionToken, first);
  clock.mono += 61_000;
  denies(() => core.commitGenerationMetadata(expired.token, first, owner.sessionToken), 'authorization_failed');
  denies(() => open().commitGenerationMetadata(expired.token, first, owner.sessionToken), 'authorization_failed');
  const revoked = core.issueGenerationGrant(owner.sessionToken, first);
  core.revokeSessions(owner.sessionToken);
  denies(() => core.commitGenerationMetadata(revoked.token, first, owner.sessionToken), 'authorization_failed');
  denies(() => core.readBackupHead(owner.sessionToken), 'authorization_failed');
});

test('stale parent, changed operation, skipped epoch and Drive-account switch cannot change the head', async (t) => {
  const { core, bootstrap } = setup(t);
  const { owner } = await bootstrap();
  const first = candidate(owner);
  commit(core, owner.sessionToken, first);
  denies(() => commit(core, owner.sessionToken,
    candidate(owner, { operationId: b64(25), generationId: b64(26), driveFileId: 'different-file' })), 'head_conflict');
  denies(() => commit(core, owner.sessionToken,
    { ...first, bundleSha256: 'd'.repeat(64) }), 'operation_conflict');
  const next = candidate(owner, {
    operationId: b64(25), generationId: b64(26), expectedHeadRevision: '1',
    expectedHeadSha256: first.bundleSha256, bundleSha256: 'd'.repeat(64), driveFileId: 'different-file',
  });
  denies(() => commit(core, owner.sessionToken, { ...next, keyEpoch: '3' }), 'key_epoch_transition_required');
  denies(() => commit(core, owner.sessionToken,
    { ...next, bundleSha256: first.bundleSha256 }), 'generation_conflict');
  denies(() => commit(core, owner.sessionToken,
    { ...next, storageAccountBinding: 'e'.repeat(64) }), 'storage_account_changed');
  denies(() => commit(core, owner.sessionToken,
    { ...next, generationId: first.generationId }), 'generation_conflict');
  denies(() => commit(core, owner.sessionToken,
    { ...next, driveFileId: first.driveFileId }), 'generation_conflict');
  assert.equal(core.readBackupHead(owner.sessionToken).head.generationId, first.generationId);
});

test('surviving credential can publish one-step key rotation after revocation without losing prior head', async (t) => {
  const { core, bootstrap } = setup(t);
  const { owner, challenge } = await bootstrap();
  const first = candidate(owner);
  denies(() => commit(core, owner.sessionToken, { ...first, keyEpoch: '2' }), 'key_epoch_transition_required');
  const firstDescriptor = commit(core, owner.sessionToken, first).descriptor;
  const enrollment = core.beginEnrollment(owner.sessionToken);
  const enrolled = await core.completeEnrollment({ ceremonyId: enrollment.ceremonyId,
    sessionToken: owner.sessionToken, credential: register(b64(6)) });
  const rotated = candidate(owner, { operationId: b64(33), generationId: b64(34),
    expectedHeadRevision: '1', expectedHeadSha256: first.bundleSha256,
    bundleSha256: 'd'.repeat(64), keyEpoch: '2', driveFileId: 'drive-rotated' });
  const preRevokeGrant = core.issueGenerationGrant(enrolled.sessionToken, rotated);
  core.revokeCredential(enrolled.sessionToken, b64(2), true);
  denies(() => core.commitGenerationMetadata(preRevokeGrant.token, rotated, enrolled.sessionToken), 'authorization_failed');
  denies(() => core.readBackupHead(enrolled.sessionToken), 'authorization_failed');
  const restored = await core.completeAuthentication({ ceremonyId: core.beginAuthentication('ios').ceremonyId,
    credential: assertion(challenge.userHandle, b64(6)) });
  assert.equal(restored.subject, owner.subject);
  const result = commit(core, restored.sessionToken, rotated);
  assert.equal(result.descriptor.keyEpoch, '2');
  const head = core.readBackupHead(restored.sessionToken);
  assert.deepEqual(head.head, result.descriptor);
  assert.deepEqual(head.previous, firstDescriptor);
  assert.equal(core.backupOperationStatus(restored.sessionToken, first.operationId).descriptor.keyEpoch, '1');
  const next = candidate(owner, { operationId: b64(35), generationId: b64(36),
    expectedHeadRevision: '2', expectedHeadSha256: rotated.bundleSha256,
    bundleSha256: 'e'.repeat(64), driveFileId: 'drive-after-rotation' });
  denies(() => commit(core, restored.sessionToken, { ...next, keyEpoch: '1' }), 'key_epoch_transition_required');
  denies(() => commit(core, restored.sessionToken, { ...next, keyEpoch: '4' }), 'key_epoch_transition_required');
  assert.equal(commit(core, restored.sessionToken, { ...next, keyEpoch: '2' }).descriptor.keyEpoch, '2');
});

test('two separate writers cannot both commit the same expected head', async (t) => {
  const { core, path, clock, bootstrap } = setup(t);
  const { owner } = await bootstrap();
  const attempts = [candidate(owner), candidate(owner, {
    operationId: b64(27), generationId: b64(28), bundleSha256: 'c'.repeat(64), driveFileId: 'drive-file-two',
  })];
  const results = await Promise.all(attempts.map((generationRequest) => worker({
    path, audience, token: core.issueGenerationGrant(owner.sessionToken, generationRequest).token,
    sessionToken: owner.sessionToken,
    generationRequest, wall: clock.wall,
  })));
  assert.equal(results.every((result) => result.code === 0), true, JSON.stringify(results));
  assert.equal(results.filter((result) => result.result?.accepted).length, 1);
  assert.equal(core.readBackupHead(owner.sessionToken).head.headRevision, '1');
});

test('two separate processes racing the same generation grant commit only once', async (t) => {
  const { core, path, clock, bootstrap } = setup(t);
  const { owner } = await bootstrap();
  const generationRequest = candidate(owner);
  const grant = core.issueGenerationGrant(owner.sessionToken, generationRequest);
  const results = await Promise.all(Array.from({ length: 8 }, () => worker({
    path, audience, token: grant.token, sessionToken: owner.sessionToken,
    generationRequest, wall: clock.wall,
  })));
  assert.equal(results.every((result) => result.code === 0), true, JSON.stringify(results));
  assert.equal(results.filter((result) => result.result?.accepted).length, 1);
  assert.equal(core.readBackupHead(owner.sessionToken).head.headRevision, '1');
  assert.equal(core.backupOperationStatus(owner.sessionToken, generationRequest.operationId).status, 'committed');
});

test('commit ambiguity is reconciled by operation ID after process crash', async (t) => {
  const { core, open, path, clock, bootstrap } = setup(t);
  const { owner } = await bootstrap();
  const before = candidate(owner);
  const beforeGrant = core.issueGenerationGrant(owner.sessionToken, before);
  assert.equal((await worker({ path, audience, token: beforeGrant.token, sessionToken: owner.sessionToken,
    generationRequest: before,
    wall: clock.wall, action: 'crash-before' })).code, 81);
  assert.equal(core.backupOperationStatus(owner.sessionToken, before.operationId).status, 'absent');
  assert.equal(core.commitGenerationMetadata(beforeGrant.token, before, owner.sessionToken).descriptor.headRevision, '1');
  const after = candidate(owner, { operationId: b64(30), generationId: b64(31),
    bundleSha256: 'c'.repeat(64), driveFileId: 'drive-file-after' });
  const afterRequest = { ...after, expectedHeadRevision: '1', expectedHeadSha256: before.bundleSha256 };
  const afterGrant = core.issueGenerationGrant(owner.sessionToken, afterRequest);
  assert.equal((await worker({ path, audience, token: afterGrant.token, sessionToken: owner.sessionToken,
    generationRequest: afterRequest,
    wall: clock.wall, action: 'crash-after' })).code, 82);
  assert.equal(open().backupOperationStatus(owner.sessionToken, after.operationId).descriptor.headRevision, '2');
  denies(() => core.commitGenerationMetadata(afterGrant.token, afterRequest, owner.sessionToken), 'authorization_failed');
  assert.equal(core.readBackupHead(owner.sessionToken).head.driveFileId, 'drive-file-after');
});

test('revoked session credential and wrong owner cannot read or commit another backup head', async (t) => {
  const { core, path, bootstrap } = setup(t);
  const { owner: first } = await bootstrap();
  const { owner: second } = await bootstrap(core, b64(6), b64(10));
  const firstRequest = candidate(first);
  commit(core, first.sessionToken, firstRequest);
  denies(() => commit(core, second.sessionToken, firstRequest), 'authorization_failed');
  assert.equal(core.readBackupHead(second.sessionToken).head, null);
  const db = new DatabaseSync(path);
  db.prepare('UPDATE credentials SET revoked=1 WHERE owner=?').run(first.subject);
  db.close();
  denies(() => core.readBackupHead(first.sessionToken), 'authorization_failed');
  denies(() => core.backupOperationStatus(first.sessionToken, firstRequest.operationId), 'authorization_failed');
  denies(() => commit(core, first.sessionToken, firstRequest), 'authorization_failed');
});

test('version-one store migration is explicit and preserves existing owner credentials', async (t) => {
  const { core, path, open, bootstrap } = setup(t);
  const { owner } = await bootstrap();
  core.close();
  downgradeStoreFixture(path, 1);
  denies(() => open(), 'store_unavailable');
  const migrated = open({ migrate: true });
  assert.equal(migrated.readBackupHead(owner.sessionToken).ownerSubject, owner.subject);
  assert.equal(commit(migrated, owner.sessionToken, candidate(owner)).descriptor.headRevision, '1');
});

test('closed request rejects secret fields, noncanonical integers and digest substitution', async (t) => {
  const { core, bootstrap } = setup(t);
  const { owner } = await bootstrap();
  const base = candidate(owner);
  for (const invalid of [
    { ...base, prfOutput: 'secret' }, { ...base, plaintext: 'secret' },
    { ...base, expectedHeadRevision: '00' }, { ...base, keyEpoch: '01' },
    { ...base, expectedHeadSha256: 'a'.repeat(64) }, { ...base, bundleSha256: 'A'.repeat(64) },
    { ...base, operationId: `${base.operationId}=` }, { ...base, driveFileId: '../other' },
    { ...base, generationId: base.operationId },
  ]) denies(() => commit(core, owner.sessionToken, invalid), 'invalid_request');
  assert.equal(core.readBackupHead(owner.sessionToken).head, null);
});
