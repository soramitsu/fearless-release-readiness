import test from 'node:test';
import assert from 'node:assert/strict';
import { fork } from 'node:child_process';
import { DatabaseSync } from 'node:sqlite';
import { hash } from '../src/validation.js';
import { assertion, audience, b64, register, setup } from './fixtures.js';

const route = {
  registration: '/api/passkey-backup/v1/registration/complete',
  assertion: '/api/passkey-backup/v1/assertion/complete',
  revoke: '/api/passkey-backup/v1/credentials/revoke',
  revokeAll: '/api/passkey-backup/v1/credentials/revoke-all',
};
const scope = {
  registration: 'passkey.registration.complete',
  assertion: 'passkey.assertion.complete',
  revoke: 'passkey.credentials.revoke',
  revokeAll: 'passkey.credentials.revoke-all',
};
const denied = (fn, code) => assert.throws(fn, (error) => error?.code === code);

function bound(kind, body) {
  const bytes = Buffer.from(JSON.stringify(body));
  return { bytes, request: { schemaVersion: 1, audience, method: 'POST', path: route[kind],
    bodySha256: hash(bytes), scope: scope[kind] } };
}
function registration(id) {
  return bound('registration', { registrationId: 'reg:test', rpId: 'fearlesswallet.io', credential: register(id) });
}
function assertionRequest(id, handle) {
  return bound('assertion', { assertionId: 'assert:test', rpId: 'fearlesswallet.io', credential: assertion(handle, id) });
}
function revocation(id) {
  return bound('revoke', { storageKey: 'storage:wallet-test', credentialId: id,
    rpId: 'fearlesswallet.io', schemaVersion: 1, confirmFinalRecoveryRemoval: true });
}
function revokeAll() {
  return bound('revokeAll', { storageKey: 'storage:wallet-test',
    rpId: 'fearlesswallet.io', schemaVersion: 1, confirmFinalRecoveryRemoval: true });
}
function record(id, handle) {
  return { id, publicKey: b64(31), userHandle: handle, counter: 0,
    deviceType: 'multiDevice', backedUp: true };
}
function row(path, id) {
  const db = new DatabaseSync(path);
  try {
    const found = db.prepare('SELECT owner,counter,revoked FROM credentials WHERE id=?').get(id);
    return found ? { ...found } : undefined;
  }
  finally { db.close(); }
}
function child(message) {
  return new Promise((resolve, reject) => {
    const worker = fork(new URL('./process-worker.js', import.meta.url), { stdio: ['ignore', 'ignore', 'pipe', 'ipc'] });
    let result;
    let diagnostic = '';
    worker.stderr.on('data', (bytes) => { diagnostic += bytes; });
    worker.on('message', (value) => { result = value; });
    worker.on('error', reject);
    worker.on('exit', (code) => resolve({ code, result, diagnostic }));
    worker.send(message);
  });
}

test('exact grant consumption and registration share one SQLite commit, including after restart', async (t) => {
  const { core, open, path, bootstrap } = setup(t);
  const { owner, challenge } = await bootstrap();
  const id = b64(41);
  const body = registration(id);
  const grant = core.issueGrant(owner.sessionToken, body.request);
  const wrongBody = Buffer.from(body.bytes);
  wrongBody[wrongBody.length - 1] ^= 1;
  denied(() => core.commitChallengeCredentialMutation(grant.token, body.request, wrongBody,
    { credential: record(id, challenge.userHandle) }), 'invalid_request');
  assert.equal(row(path, id), undefined);
  const committed = core.commitChallengeCredentialMutation(grant.token, body.request, body.bytes,
    { credential: record(id, challenge.userHandle) });
  assert.deepEqual(committed, { status: 'registered', credentialId: id, generation: 1 });
  assert.deepEqual(row(path, id), { owner: owner.subject, counter: 0, revoked: 0 });
  denied(() => core.commitChallengeCredentialMutation(grant.token, body.request, body.bytes,
    { credential: record(id, challenge.userHandle) }), 'authorization_failed');
  denied(() => core.issueGrant(owner.sessionToken, body.request), 'authorization_failed');
  const restarted = open();
  assert.deepEqual(row(path, id), { owner: owner.subject, counter: 0, revoked: 0 });
  denied(() => restarted.consumeGrant(grant.token, body.request), 'authorization_failed');
});

test('verified counter commit rejects stale counter, wrong handle and revoked credential', async (t) => {
  const { core, path, bootstrap } = setup(t);
  const { owner, challenge } = await bootstrap();
  const id = b64(2);
  const body = assertionRequest(id, challenge.userHandle);
  const evidence = { expectedCounter: 0, newCounter: 1, deviceType: 'multiDevice', backedUp: true };
  const grant = core.issueGrant(owner.sessionToken, body.request);
  denied(() => core.commitChallengeCredentialMutation(grant.token, body.request,
    assertionRequest(id, b64(50)).bytes, evidence), 'invalid_request');
  assert.deepEqual(core.commitChallengeCredentialMutation(grant.token, body.request, body.bytes, evidence),
    { status: 'authenticated', credentialId: id, counter: 1 });
  assert.equal(row(path, id).counter, 1);
  const stale = core.issueGrant(owner.sessionToken, body.request);
  denied(() => core.commitChallengeCredentialMutation(stale.token, body.request, body.bytes, evidence), 'credential_counter_replay');
  assert.equal(row(path, id).counter, 1);
  const revoked = core.issueGrant(owner.sessionToken, body.request);
  core.revokeCredential(owner.sessionToken, id, true);
  denied(() => core.commitChallengeCredentialMutation(revoked.token, body.request, body.bytes,
    { ...evidence, expectedCounter: 1, newCounter: 2 }), 'authorization_failed');
  assert.deepEqual(row(path, id), { owner: owner.subject, counter: 1, revoked: 1 });
});

test('counter evidence is copied once before validation and SQLite write', async (t) => {
  const { core, path, bootstrap } = setup(t);
  const { owner, challenge } = await bootstrap();
  const id = b64(2);
  const body = assertionRequest(id, challenge.userHandle);
  const grant = core.issueGrant(owner.sessionToken, body.request);
  let reads = 0;
  const evidence = { expectedCounter: 0, deviceType: 'multiDevice', backedUp: true };
  Object.defineProperty(evidence, 'newCounter', { enumerable: true, get: () => (++reads === 1 ? 1 : 0) });
  assert.equal(core.commitChallengeCredentialMutation(grant.token, body.request, body.bytes, evidence).counter, 1);
  assert.equal(reads, 1);
  assert.equal(row(path, id).counter, 1);
});

test('grant-bound revocation bumps generation in the same commit and retains tombstone', async (t) => {
  const { core, path, bootstrap } = setup(t);
  const { owner } = await bootstrap();
  const id = b64(2);
  const body = revocation(id);
  const grant = core.issueGrant(owner.sessionToken, body.request);
  const result = core.commitChallengeCredentialMutation(grant.token, body.request, body.bytes, {});
  assert.deepEqual(result, { status: 'revoked', credentialId: id, remainingCredentials: 0, generation: 1 });
  assert.equal(row(path, id).revoked, 1);
  denied(() => core.consumeGrant(grant.token, body.request), 'authorization_failed');
  denied(() => core.issueGrant(owner.sessionToken, body.request), 'authorization_failed');
  const db = new DatabaseSync(path);
  try { assert.equal(db.prepare('SELECT generation FROM owners WHERE subject=?').get(owner.subject).generation, 1); }
  finally { db.close(); }
});

test('separate-process counter commit and owner revoke serialize: no update after revocation', async (t) => {
  const { core, path, clock, bootstrap } = setup(t);
  const { owner, challenge } = await bootstrap();
  const id = b64(2);
  const body = assertionRequest(id, challenge.userHandle);
  const grant = core.issueGrant(owner.sessionToken, body.request);
  const jobs = await Promise.all([
    child({ action: 'commit-credential-mutation', path, audience, wall: clock.wall, token: grant.token,
      request: body.request, mutationBody: body.bytes.toString('base64'),
      mutationEvidence: { expectedCounter: 0, newCounter: 1, deviceType: 'multiDevice', backedUp: true } }),
    child({ action: 'revoke-credential', path, audience, wall: clock.wall,
      token: owner.sessionToken, credentialId: id }),
  ]);
  assert.equal(jobs.every((job) => job.code === 0), true, JSON.stringify(jobs));
  assert.equal(jobs[1].result.accepted, true, JSON.stringify(jobs));
  assert.equal(row(path, id).revoked, 1);
  assert.equal(row(path, id).counter, jobs[0].result.accepted ? 1 : 0);
  const replay = child({ action: 'commit-credential-mutation', path, audience, wall: clock.wall, token: grant.token,
    request: body.request, mutationBody: body.bytes.toString('base64'),
    mutationEvidence: { expectedCounter: 0, newCounter: 1, deviceType: 'multiDevice', backedUp: true } });
  assert.equal((await replay).result.accepted, false);
});

test('two processes cannot commit the same nonzero counter or replay either grant', async (t) => {
  const { core, path, clock, bootstrap } = setup(t);
  const { owner, challenge } = await bootstrap();
  const id = b64(2);
  const body = assertionRequest(id, challenge.userHandle);
  const evidence = { expectedCounter: 0, newCounter: 1, deviceType: 'multiDevice', backedUp: true };
  const grants = [core.issueGrant(owner.sessionToken, body.request), core.issueGrant(owner.sessionToken, body.request)];
  const jobs = await Promise.all(grants.map(({ token }) => child({
    action: 'commit-credential-mutation', path, audience, wall: clock.wall, token,
    request: body.request, mutationBody: body.bytes.toString('base64'), mutationEvidence: evidence,
  })));
  assert.equal(jobs.every((job) => job.code === 0), true, JSON.stringify(jobs));
  assert.equal(jobs.filter((job) => job.result.accepted).length, 1, JSON.stringify(jobs));
  assert.equal(row(path, id).counter, 1);
  const winningIndex = jobs.findIndex((job) => job.result.accepted);
  denied(() => core.consumeGrant(grants[winningIndex].token, body.request), 'authorization_failed');
  denied(() => core.commitChallengeCredentialMutation(grants[1 - winningIndex].token, body.request, body.bytes, evidence),
    'credential_counter_replay');
});

test('PRF output in a raw request is rejected without consuming the grant or storing secret bytes', async (t) => {
  const { core, path, bootstrap } = setup(t);
  const { owner, challenge } = await bootstrap();
  const id = b64(42);
  const contaminated = register(id);
  contaminated.clientExtensionResults = { prf: { results: { first: b64(99) } } };
  const secretBody = bound('registration', {
    registrationId: 'reg:test', rpId: 'fearlesswallet.io', credential: contaminated,
  });
  const grant = core.issueGrant(owner.sessionToken, secretBody.request);
  denied(() => core.commitChallengeCredentialMutation(grant.token, secretBody.request, secretBody.bytes,
    { credential: record(id, challenge.userHandle) }), 'invalid_request');
  assert.equal(row(path, id), undefined);
  assert.equal(core.consumeGrant(grant.token, secretBody.request).active, true);
  const db = new DatabaseSync(path);
  try { assert.equal(db.prepare('SELECT count(*) AS n FROM credentials WHERE id=?').get(id).n, 0); }
  finally { db.close(); }
});

test('grant-bound revoke-all is atomic and invalidates every owner grant', async (t) => {
  const { core, path, bootstrap } = setup(t);
  const { owner } = await bootstrap();
  const id = b64(2);
  const body = revokeAll();
  const grant = core.issueGrant(owner.sessionToken, body.request);
  const pending = core.issueGrant(owner.sessionToken, assertionRequest(id, b64(1)).request);
  assert.deepEqual(core.commitChallengeCredentialMutation(grant.token, body.request, body.bytes, {}),
    { status: 'revoked-all', remainingCredentials: 0, generation: 1 });
  assert.equal(row(path, id).revoked, 1);
  denied(() => core.consumeGrant(pending.token, assertionRequest(id, b64(1)).request), 'authorization_failed');
});

test('an exact grant from one owner cannot mutate another owner credential', async (t) => {
  const { core, path, bootstrap } = setup(t);
  const first = (await bootstrap()).owner;
  const second = (await bootstrap(core, b64(3), b64(5))).owner;
  const body = revocation(b64(3));
  const grant = core.issueGrant(first.sessionToken, body.request);
  denied(() => core.commitChallengeCredentialMutation(grant.token, body.request, body.bytes, {}), 'authorization_failed');
  assert.deepEqual(row(path, b64(3)), { owner: second.subject, counter: 0, revoked: 0 });
  assert.equal(core.consumeGrant(grant.token, body.request).subject, first.subject);
});

test('precommit failure rolls back counter and grant; ambiguous postcommit failure poisons caller', async (t) => {
  let faultStage;
  const { core, open, path, bootstrap } = setup(t, {
    fault(stage) { if (stage === faultStage) throw Error('synthetic durability failure'); },
  });
  const { owner, challenge } = await bootstrap();
  const id = b64(2);
  const body = assertionRequest(id, challenge.userHandle);
  const evidence = { expectedCounter: 0, newCounter: 1, deviceType: 'multiDevice', backedUp: true };
  const first = core.issueGrant(owner.sessionToken, body.request);
  faultStage = 'beforeCommit';
  denied(() => core.commitChallengeCredentialMutation(first.token, body.request, body.bytes, evidence), 'store_unavailable');
  faultStage = undefined;
  assert.equal(row(path, id).counter, 0);
  const recovered = open();
  assert.deepEqual(recovered.commitChallengeCredentialMutation(first.token, body.request, body.bytes, evidence),
    { status: 'authenticated', credentialId: id, counter: 1 });
  const second = recovered.issueGrant(owner.sessionToken, body.request);
  faultStage = 'afterCommit';
  denied(() => recovered.commitChallengeCredentialMutation(second.token, body.request, body.bytes,
    { ...evidence, expectedCounter: 1, newCounter: 2 }), 'store_unavailable');
  faultStage = undefined;
  assert.equal(row(path, id).counter, 2);
  const restarted = open();
  denied(() => restarted.consumeGrant(second.token, body.request), 'authorization_failed');
});

test('explicit v1-to-v2 owner migration retains existing credential and permits atomic counter commit', async (t) => {
  const { core, open, path, bootstrap } = setup(t);
  const { owner, challenge } = await bootstrap();
  const id = b64(2);
  const body = assertionRequest(id, challenge.userHandle);
  const grant = core.issueGrant(owner.sessionToken, body.request);
  core.close();
  const db = new DatabaseSync(path);
  db.exec(`
    DROP TABLE backup_heads;
    DROP TABLE backup_operations;
    CREATE TABLE meta_v1 (id INTEGER PRIMARY KEY CHECK(id=1), wall INTEGER NOT NULL CHECK(wall>=0), observed INTEGER NOT NULL CHECK(observed>=0), version INTEGER NOT NULL CHECK(version=1)) STRICT;
    INSERT INTO meta_v1 SELECT id,wall,observed,1 FROM meta;
    DROP TABLE meta;
    ALTER TABLE meta_v1 RENAME TO meta;
    PRAGMA user_version=1;
  `);
  db.close();
  denied(() => open(), 'store_unavailable');
  const migrated = open({ migrate: true });
  assert.deepEqual(row(path, id), { owner: owner.subject, counter: 0, revoked: 0 });
  assert.deepEqual(migrated.commitChallengeCredentialMutation(grant.token, body.request, body.bytes,
    { expectedCounter: 0, newCounter: 1, deviceType: 'multiDevice', backedUp: true }),
  { status: 'authenticated', credentialId: id, counter: 1 });
  assert.deepEqual(row(path, id), { owner: owner.subject, counter: 1, revoked: 0 });
});
