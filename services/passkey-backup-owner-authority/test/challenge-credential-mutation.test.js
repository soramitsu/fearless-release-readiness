import test from 'node:test';
import assert from 'node:assert/strict';
import { fork } from 'node:child_process';
import { DatabaseSync } from 'node:sqlite';
import { hash } from '../src/validation.js';
import { assertion, audience, b64, downgradeStoreFixture, register, setup } from './fixtures.js';

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
function registration(id, challengeId = 'reg:test') {
  return bound('registration', { registrationId: challengeId, rpId: 'fearlesswallet.io', credential: register(id) });
}
function assertionRequest(id, handle, challengeId = 'assert:test') {
  return bound('assertion', { assertionId: challengeId, rpId: 'fearlesswallet.io', credential: assertion(handle, id) });
}
const legacyHandle = (storageKey) => hash(Buffer.from(`user\0${storageKey}`, 'utf8'));
function revocation(id, storageKey = 'storage:wallet-test', confirm = true) {
  return bound('revoke', { storageKey, credentialId: id,
    rpId: 'fearlesswallet.io', schemaVersion: 1,
    ...(confirm === null ? {} : { confirmFinalRecoveryRemoval: confirm }) });
}
function revokeAll(storageKey = 'storage:wallet-test', confirm = true) {
  return bound('revokeAll', { storageKey,
    rpId: 'fearlesswallet.io', schemaVersion: 1,
    ...(confirm === null ? {} : { confirmFinalRecoveryRemoval: confirm }) });
}
function bindLegacyCredential(path, owner, storageKey, credentialId, seed = 1) {
  const db = new DatabaseSync(path);
  try {
    db.exec('PRAGMA foreign_keys=ON');
    db.prepare('UPDATE credentials SET user_handle=? WHERE id=?').run(legacyHandle(storageKey), credentialId);
    db.prepare('INSERT INTO storage_bindings VALUES(?,?,?,?,?,?)').run(
      storageKey, owner.subject, b64(seed), Buffer.alloc(32, seed).toString('hex'),
      Buffer.alloc(32, seed + 20).toString('hex'), 1);
    db.prepare('INSERT INTO legacy_credential_metadata VALUES(?,?,?,?,?)').run(
      credentialId, storageKey, '00000000-0000-0000-0000-000000000000', null, 'android');
  } finally { db.close(); }
}
function bindStorageKey(path, owner, storageKey = 'storage:wallet-test') {
  const db = new DatabaseSync(path);
  try {
    db.prepare('INSERT INTO storage_bindings VALUES(?,?,?,?,?,?)').run(storageKey,
      owner.subject, b64(1), Buffer.alloc(32, 1).toString('hex'),
      Buffer.alloc(32, 21).toString('hex'), 1);
  } finally { db.close(); }
}
function claimedRegistration(core, owner, id, storageKey = 'storage:wallet-test') {
  const pending = core.beginChallengeCredentialMutation(owner.sessionToken,
    { kind: 'registration', storageKey });
  const body = registration(id, pending.challengeId);
  core.claimChallengeCredentialMutation(owner.sessionToken, body.request, body.bytes);
  return { pending, body, evidence: { challengeNonce: pending.challenge, platform: pending.platform,
    credential: record(id, pending.userHandle), aaguid: '00000000-0000-0000-0000-000000000000', transportsJson: null } };
}
function claimedAssertion(core, owner, id, storageKey = 'storage:wallet-test', directed = false, handle = legacyHandle(storageKey)) {
  const pending = core.beginChallengeCredentialMutation(owner.sessionToken,
    { kind: 'assertion', storageKey, ...(directed ? { directedCredentialId: id } : {}) });
  const body = assertionRequest(id, handle, pending.challengeId);
  core.claimChallengeCredentialMutation(owner.sessionToken, body.request, body.bytes);
  return { pending, body, evidence: { challengeNonce: pending.challenge, platform: pending.platform,
    expectedCounter: 0, newCounter: 1, deviceType: 'multiDevice', backedUp: true } };
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
  const { owner } = await bootstrap();
  const id = b64(41);
  bindStorageKey(path, owner);
  const { body, evidence } = claimedRegistration(core, owner, id);
  const grant = core.issueGrant(owner.sessionToken, body.request);
  const wrongBody = Buffer.from(body.bytes);
  wrongBody[wrongBody.length - 1] ^= 1;
  denied(() => core.commitChallengeCredentialMutation(grant.token, body.request, wrongBody,
    evidence), 'invalid_request');
  assert.equal(row(path, id), undefined);
  const committed = core.commitChallengeCredentialMutation(grant.token, body.request, body.bytes,
    evidence);
  assert.deepEqual(committed, { status: 'registered', credentialId: id, generation: 1 });
  assert.deepEqual(row(path, id), { owner: owner.subject, counter: 0, revoked: 0 });
  const db = new DatabaseSync(path, { readOnly: true });
  try {
    assert.deepEqual({ ...db.prepare('SELECT scope,storage_key FROM credential_scopes WHERE credential_id=?').get(id) },
      { scope: 'storage', storage_key: 'storage:wallet-test' });
    assert.equal(db.prepare('SELECT user_handle FROM credentials WHERE id=?').get(id).user_handle,
      legacyHandle('storage:wallet-test'));
    assert.equal(db.prepare('SELECT registration_platform FROM legacy_credential_metadata WHERE credential_id=?').get(id).registration_platform,
      'android');
  } finally { db.close(); }
  denied(() => core.commitChallengeCredentialMutation(grant.token, body.request, body.bytes,
    evidence), 'authorization_failed');
  denied(() => core.issueGrant(owner.sessionToken, body.request), 'authorization_failed');
  const restarted = open();
  assert.deepEqual(row(path, id), { owner: owner.subject, counter: 0, revoked: 0 });
  denied(() => restarted.consumeGrant(grant.token, body.request), 'authorization_failed');
});

test('registration and assertion require a claimed SQLite challenge, not an adapter-selected ID', async (t) => {
  const { core, path, bootstrap } = setup(t);
  const { owner } = await bootstrap();
  bindLegacyCredential(path, owner, 'storage:wallet-test', b64(2));
  const fake = assertionRequest(b64(2), legacyHandle('storage:wallet-test'));
  const fakeGrant = core.issueGrant(owner.sessionToken, fake.request);
  denied(() => core.commitChallengeCredentialMutation(fakeGrant.token, fake.request, fake.bytes,
    { challengeNonce: b64(20), platform: 'android', expectedCounter: 0,
      newCounter: 1, deviceType: 'multiDevice', backedUp: true,
      directedCredentialId: b64(2) }), 'authorization_failed');
  assert.equal(core.consumeGrant(fakeGrant.token, fake.request).active, true);
  const pending = core.beginChallengeCredentialMutation(owner.sessionToken,
    { kind: 'assertion', storageKey: 'storage:wallet-test', directedCredentialId: b64(2) });
  const body = assertionRequest(b64(2), null, pending.challengeId);
  const grant = core.issueGrant(owner.sessionToken, body.request);
  denied(() => core.commitChallengeCredentialMutation(grant.token, body.request, body.bytes,
    { challengeNonce: pending.challenge, platform: pending.platform, expectedCounter: 0,
      newCounter: 1, deviceType: 'multiDevice', backedUp: true }), 'authorization_failed');
  assert.equal(core.consumeGrant(grant.token, body.request).active, true);
  assert.equal(row(path, b64(2)).counter, 0);
});

test('pending challenge cannot cross owner, wallet key, credential, nonce or platform', async (t) => {
  const { core, path, bootstrap } = setup(t);
  const first = (await bootstrap()).owner;
  const second = (await bootstrap(core, b64(3), b64(5))).owner;
  bindLegacyCredential(path, first, 'storage:wallet-test', b64(2));
  bindLegacyCredential(path, second, 'storage:other-wallet', b64(3), 2);
  denied(() => core.beginChallengeCredentialMutation(second.sessionToken,
    { kind: 'assertion', storageKey: 'storage:wallet-test' }), 'authorization_failed');
  const pending = core.beginChallengeCredentialMutation(first.sessionToken,
    { kind: 'assertion', storageKey: 'storage:wallet-test', directedCredentialId: b64(2) });
  const wrongOwner = assertionRequest(b64(2), null, pending.challengeId);
  denied(() => core.claimChallengeCredentialMutation(second.sessionToken,
    wrongOwner.request, wrongOwner.bytes), 'authorization_failed');
  const wrongCredential = assertionRequest(b64(3), null, pending.challengeId);
  denied(() => core.claimChallengeCredentialMutation(first.sessionToken,
    wrongCredential.request, wrongCredential.bytes), 'authorization_failed');
  const body = wrongOwner;
  core.claimChallengeCredentialMutation(first.sessionToken, body.request, body.bytes);
  const grant = core.issueGrant(first.sessionToken, body.request);
  const base = { challengeNonce: pending.challenge, platform: pending.platform, expectedCounter: 0,
    newCounter: 1, deviceType: 'multiDevice', backedUp: true };
  denied(() => core.commitChallengeCredentialMutation(grant.token, body.request, body.bytes,
    { ...base, challengeNonce: b64(89) }), 'verification_failed');
  denied(() => core.commitChallengeCredentialMutation(grant.token, body.request, body.bytes,
    { ...base, platform: 'ios' }), 'verification_failed');
  assert.equal(core.commitChallengeCredentialMutation(grant.token, body.request, body.bytes, base).counter, 1);
});

test('one owner cannot assert a credential scoped to another of its proven wallet keys', async (t) => {
  const { core, path, bootstrap } = setup(t);
  const { owner, challenge } = await bootstrap();
  const secondId = b64(55);
  const db = new DatabaseSync(path);
  try {
    db.prepare('INSERT INTO credentials VALUES(?,?,?,?,?,?,?,0)').run(
      secondId, owner.subject, b64(31), challenge.userHandle, 0, 'multiDevice', 1);
  } finally { db.close(); }
  bindLegacyCredential(path, owner, 'storage:first-wallet', b64(2), 1);
  bindLegacyCredential(path, owner, 'storage:second-wallet', secondId, 2);
  const pending = core.beginChallengeCredentialMutation(owner.sessionToken,
    { kind: 'assertion', storageKey: 'storage:first-wallet' });
  const wrong = assertionRequest(secondId, legacyHandle('storage:second-wallet'), pending.challengeId);
  denied(() => core.claimChallengeCredentialMutation(owner.sessionToken, wrong.request, wrong.bytes), 'verification_failed');
  denied(() => core.beginChallengeCredentialMutation(owner.sessionToken,
    { kind: 'assertion', storageKey: 'storage:first-wallet', directedCredentialId: secondId }),
  'authorization_failed');
});

test('wallet-key registration rejects an owner-wide handle and unknown storage key', async (t) => {
  const { core, path, bootstrap } = setup(t);
  const { owner, challenge } = await bootstrap();
  denied(() => core.beginChallengeCredentialMutation(owner.sessionToken,
    { kind: 'registration', storageKey: 'storage:unproven-wallet' }), 'authorization_failed');
  bindStorageKey(path, owner);
  const id = b64(60);
  const { body, evidence } = claimedRegistration(core, owner, id);
  const grant = core.issueGrant(owner.sessionToken, body.request);
  assert.notEqual(challenge.userHandle, evidence.credential.userHandle);
  denied(() => core.commitChallengeCredentialMutation(grant.token, body.request, body.bytes,
    { ...evidence, credential: { ...evidence.credential, userHandle: challenge.userHandle } }),
  'verification_failed');
  assert.equal(row(path, id), undefined);
  assert.equal(core.commitChallengeCredentialMutation(grant.token, body.request, body.bytes, evidence).status,
    'registered');
});

test('claimed challenge survives restart but cannot be claimed or committed twice', async (t) => {
  const { core, open, path, bootstrap } = setup(t);
  const { owner } = await bootstrap();
  bindLegacyCredential(path, owner, 'storage:wallet-test', b64(2));
  const { body, evidence } = claimedAssertion(core, owner, b64(2));
  denied(() => core.claimChallengeCredentialMutation(owner.sessionToken, body.request, body.bytes), 'authorization_failed');
  const grant = core.issueGrant(owner.sessionToken, body.request);
  core.close();
  const restarted = open();
  assert.equal(restarted.commitChallengeCredentialMutation(grant.token, body.request, body.bytes, evidence).counter, 1);
  denied(() => restarted.commitChallengeCredentialMutation(grant.token, body.request, body.bytes, evidence), 'authorization_failed');
  denied(() => restarted.claimChallengeCredentialMutation(owner.sessionToken, body.request, body.bytes), 'authorization_failed');
});

test('revocation generation and expiry invalidate claimed challenges without spending new grants', async (t) => {
  const { core, path, bootstrap, clock } = setup(t);
  const { owner } = await bootstrap();
  bindLegacyCredential(path, owner, 'storage:wallet-test', b64(2));
  const first = claimedAssertion(core, owner, b64(2));
  const firstGrant = core.issueGrant(owner.sessionToken, first.body.request);
  core.revokeSessions(owner.sessionToken);
  denied(() => core.commitChallengeCredentialMutation(firstGrant.token,
    first.body.request, first.body.bytes, first.evidence), 'authorization_failed');
  const authentication = core.beginAuthentication('android');
  const resumed = await core.completeAuthentication({ ceremonyId: authentication.ceremonyId,
    credential: assertion(legacyHandle('storage:wallet-test')) });
  const second = claimedAssertion(core, resumed, b64(2));
  const secondGrant = core.issueGrant(resumed.sessionToken, second.body.request);
  clock.mono += 121_000;
  denied(() => core.commitChallengeCredentialMutation(secondGrant.token,
    second.body.request, second.body.bytes, second.evidence), 'authorization_failed');
  assert.equal(row(path, b64(2)).counter, 1);
});

test('separate SQLite writers permit only one claim of the same challenge', async (t) => {
  const { core, path, clock, bootstrap } = setup(t);
  const { owner } = await bootstrap();
  bindLegacyCredential(path, owner, 'storage:wallet-test', b64(2));
  const pending = core.beginChallengeCredentialMutation(owner.sessionToken,
    { kind: 'assertion', storageKey: 'storage:wallet-test' });
  const body = assertionRequest(b64(2), legacyHandle('storage:wallet-test'), pending.challengeId);
  const jobs = await Promise.all([0, 1].map(() => child({ action: 'claim-credential-mutation',
    path, audience, wall: clock.wall, token: owner.sessionToken,
    request: body.request, mutationBody: body.bytes.toString('base64') })));
  assert.equal(jobs.every((job) => job.code === 0), true, JSON.stringify(jobs));
  assert.equal(jobs.filter((job) => job.result.accepted).length, 1, JSON.stringify(jobs));
});

test('verified counter commit rejects stale counter, wrong handle and revoked credential', async (t) => {
  const { core, path, bootstrap } = setup(t);
  const { owner } = await bootstrap();
  const id = b64(2);
  bindLegacyCredential(path, owner, 'storage:wallet-test', id);
  const { body, evidence } = claimedAssertion(core, owner, id);
  const grant = core.issueGrant(owner.sessionToken, body.request);
  denied(() => core.commitChallengeCredentialMutation(grant.token, body.request,
    assertionRequest(id, b64(50), JSON.parse(body.bytes).assertionId).bytes, evidence), 'invalid_request');
  assert.deepEqual(core.commitChallengeCredentialMutation(grant.token, body.request, body.bytes, evidence),
    { status: 'authenticated', credentialId: id, counter: 1 });
  assert.equal(row(path, id).counter, 1);
  const staleChallenge = claimedAssertion(core, owner, id);
  const stale = core.issueGrant(owner.sessionToken, staleChallenge.body.request);
  denied(() => core.commitChallengeCredentialMutation(stale.token, staleChallenge.body.request, staleChallenge.body.bytes,
    { ...staleChallenge.evidence, expectedCounter: 0 }), 'credential_counter_replay');
  assert.equal(row(path, id).counter, 1);
  const revokedChallenge = claimedAssertion(core, owner, id);
  const revoked = core.issueGrant(owner.sessionToken, revokedChallenge.body.request);
  core.revokeCredential(owner.sessionToken, id, true);
  denied(() => core.commitChallengeCredentialMutation(revoked.token, revokedChallenge.body.request, revokedChallenge.body.bytes,
    { ...revokedChallenge.evidence, expectedCounter: 1, newCounter: 2 }), 'authorization_failed');
  assert.deepEqual(row(path, id), { owner: owner.subject, counter: 1, revoked: 1 });
});

test('atomic challenge counter commit accepts a proven legacy credential handle', async (t) => {
  const { core, path, bootstrap } = setup(t);
  const { owner } = await bootstrap();
  const id = b64(2);
  const unrelatedHandle = b64(72);
  assert.notEqual(unrelatedHandle, legacyHandle('storage:wallet-test'));
  // A future verified import retains the historical handle per credential.
  // This fixture does not admit a live legacy cohort or migrate either store.
  bindLegacyCredential(path, owner, 'storage:wallet-test', id);
  // The fixture's historical per-key handle is deterministic for this route.

  const { body, evidence } = claimedAssertion(core, owner, id);
  const grant = core.issueGrant(owner.sessionToken, body.request);
  assert.deepEqual(core.commitChallengeCredentialMutation(grant.token, body.request,
    body.bytes, evidence),
  { status: 'authenticated', credentialId: id, counter: 1 });
  assert.equal(row(path, id).counter, 1);

  const wrongPending = core.beginChallengeCredentialMutation(owner.sessionToken,
    { kind: 'assertion', storageKey: 'storage:wallet-test' });
  const wrong = assertionRequest(id, unrelatedHandle, wrongPending.challengeId);
  const wrongGrant = core.issueGrant(owner.sessionToken, wrong.request);
  denied(() => core.claimChallengeCredentialMutation(owner.sessionToken, wrong.request, wrong.bytes), 'verification_failed');
  denied(() => core.commitChallengeCredentialMutation(wrongGrant.token, wrong.request,
    wrong.bytes, { ...evidence, expectedCounter: 1, newCounter: 2 }), 'authorization_failed');
  assert.equal(row(path, id).counter, 1);
});

test('null assertion handle requires a claimed server-owned credential-directed challenge', async (t) => {
  const { core, path, bootstrap } = setup(t);
  const { owner } = await bootstrap();
  const id = b64(2);
  bindLegacyCredential(path, owner, 'storage:wallet-test', id);
  const undirected = core.beginChallengeCredentialMutation(owner.sessionToken,
    { kind: 'assertion', storageKey: 'storage:wallet-test' });
  const wrong = assertionRequest(id, null, undirected.challengeId);
  denied(() => core.claimChallengeCredentialMutation(owner.sessionToken, wrong.request, wrong.bytes), 'verification_failed');
  const { body, evidence } = claimedAssertion(core, owner, id, 'storage:wallet-test', true, null);
  const grant = core.issueGrant(owner.sessionToken, body.request);
  denied(() => core.commitChallengeCredentialMutation(grant.token, body.request,
    body.bytes, { ...evidence, directedCredentialId: id }), 'invalid_request');
  assert.equal(row(path, id).counter, 0);
  assert.deepEqual(core.commitChallengeCredentialMutation(grant.token, body.request,
    body.bytes, evidence),
  { status: 'authenticated', credentialId: id, counter: 1 });
  assert.equal(row(path, id).counter, 1);
  denied(() => core.consumeGrant(grant.token, body.request), 'authorization_failed');
});

test('counter evidence is copied once before validation and SQLite write', async (t) => {
  const { core, path, bootstrap } = setup(t);
  const { owner } = await bootstrap();
  const id = b64(2);
  bindLegacyCredential(path, owner, 'storage:wallet-test', id);
  const { body, evidence: baseEvidence } = claimedAssertion(core, owner, id);
  const grant = core.issueGrant(owner.sessionToken, body.request);
  let reads = 0;
  const evidence = { ...baseEvidence }; delete evidence.newCounter;
  Object.defineProperty(evidence, 'newCounter', { enumerable: true, get: () => (++reads === 1 ? 1 : 0) });
  assert.equal(core.commitChallengeCredentialMutation(grant.token, body.request, body.bytes, evidence).counter, 1);
  assert.equal(reads, 1);
  assert.equal(row(path, id).counter, 1);
});

test('grant-bound revocation bumps generation in the same commit and retains tombstone', async (t) => {
  const { core, path, bootstrap } = setup(t);
  const { owner } = await bootstrap();
  const id = b64(2);
  bindLegacyCredential(path, owner, 'storage:wallet-test', id);
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

test('legacy revoke retries are idempotent but live removal needs explicit confirmation', async (t) => {
  const { core, path, bootstrap } = setup(t);
  const { owner } = await bootstrap();
  const id = b64(2);
  bindLegacyCredential(path, owner, 'storage:wallet-test', id);

  const unconfirmed = revocation(id, 'storage:wallet-test', null);
  const unconfirmedGrant = core.issueGrant(owner.sessionToken, unconfirmed.request);
  denied(() => core.commitChallengeCredentialMutation(unconfirmedGrant.token,
    unconfirmed.request, unconfirmed.bytes, {}), 'final_recovery_route_confirmation_required');
  assert.equal(row(path, id).revoked, 0);
  assert.equal(core.consumeGrant(unconfirmedGrant.token, unconfirmed.request).active, true);

  const explicitFalse = revocation(id, 'storage:wallet-test', false);
  const falseGrant = core.issueGrant(owner.sessionToken, explicitFalse.request);
  denied(() => core.commitChallengeCredentialMutation(falseGrant.token,
    explicitFalse.request, explicitFalse.bytes, {}), 'invalid_request');
  assert.equal(core.consumeGrant(falseGrant.token, explicitFalse.request).active, true);

  const unknown = revocation(b64(59), 'storage:wallet-test', null);
  const unknownGrant = core.issueGrant(owner.sessionToken, unknown.request);
  assert.deepEqual(core.commitChallengeCredentialMutation(unknownGrant.token,
    unknown.request, unknown.bytes, {}),
  { status: 'revoked', credentialId: b64(59), remainingCredentials: 1, generation: 0 });
  assert.equal(row(path, id).revoked, 0);

  const confirmed = revocation(id);
  const confirmedGrant = core.issueGrant(owner.sessionToken, confirmed.request);
  assert.equal(core.commitChallengeCredentialMutation(confirmedGrant.token,
    confirmed.request, confirmed.bytes, {}).generation, 1);
  assert.equal(row(path, id).revoked, 1);
});

test('an already revoked key credential can be retried without a second confirmation', async (t) => {
  const { core, path, bootstrap } = setup(t);
  const { owner, challenge } = await bootstrap();
  const id = b64(2);
  bindLegacyCredential(path, owner, 'storage:wallet-test', id);
  const enrollment = core.beginEnrollment(owner.sessionToken);
  const survivor = await core.completeEnrollment({ ceremonyId: enrollment.ceremonyId,
    sessionToken: owner.sessionToken, credential: register(b64(60)) });

  const first = revocation(id);
  const firstGrant = core.issueGrant(survivor.sessionToken, first.request);
  assert.equal(core.commitChallengeCredentialMutation(firstGrant.token,
    first.request, first.bytes, {}).generation, 2);
  const auth = core.beginAuthentication('android');
  const renewed = await core.completeAuthentication({ ceremonyId: auth.ceremonyId,
    credential: assertion(challenge.userHandle, b64(60)) });
  const retry = revocation(id, 'storage:wallet-test', null);
  const retryGrant = core.issueGrant(renewed.sessionToken, retry.request);
  assert.deepEqual(core.commitChallengeCredentialMutation(retryGrant.token,
    retry.request, retry.bytes, {}),
  { status: 'revoked', credentialId: id, remainingCredentials: 0, generation: 2 });
  assert.equal(row(path, b64(60)).revoked, 0);
});

test('separate-process counter commit and owner revoke serialize: no update after revocation', async (t) => {
  const { core, path, clock, bootstrap } = setup(t);
  const { owner } = await bootstrap();
  const id = b64(2);
  bindLegacyCredential(path, owner, 'storage:wallet-test', id);
  const { body, evidence } = claimedAssertion(core, owner, id);
  const grant = core.issueGrant(owner.sessionToken, body.request);
  const jobs = await Promise.all([
    child({ action: 'commit-credential-mutation', path, audience, wall: clock.wall, token: grant.token,
      request: body.request, mutationBody: body.bytes.toString('base64'),
      mutationEvidence: evidence }),
    child({ action: 'revoke-credential', path, audience, wall: clock.wall,
      token: owner.sessionToken, credentialId: id }),
  ]);
  assert.equal(jobs.every((job) => job.code === 0), true, JSON.stringify(jobs));
  assert.equal(jobs[1].result.accepted, true, JSON.stringify(jobs));
  assert.equal(row(path, id).revoked, 1);
  assert.equal(row(path, id).counter, jobs[0].result.accepted ? 1 : 0);
  const replay = child({ action: 'commit-credential-mutation', path, audience, wall: clock.wall, token: grant.token,
    request: body.request, mutationBody: body.bytes.toString('base64'),
    mutationEvidence: evidence });
  assert.equal((await replay).result.accepted, false);
});

test('two processes cannot commit the same nonzero counter or replay either grant', async (t) => {
  const { core, path, clock, bootstrap } = setup(t);
  const { owner } = await bootstrap();
  const id = b64(2);
  bindLegacyCredential(path, owner, 'storage:wallet-test', id);
  const attempts = [claimedAssertion(core, owner, id), claimedAssertion(core, owner, id)];
  const grants = attempts.map(({ body }) => core.issueGrant(owner.sessionToken, body.request));
  const jobs = await Promise.all(grants.map(({ token }, index) => child({
    action: 'commit-credential-mutation', path, audience, wall: clock.wall, token,
    request: attempts[index].body.request,
    mutationBody: attempts[index].body.bytes.toString('base64'), mutationEvidence: attempts[index].evidence,
  })));
  assert.equal(jobs.every((job) => job.code === 0), true, JSON.stringify(jobs));
  assert.equal(jobs.filter((job) => job.result.accepted).length, 1, JSON.stringify(jobs));
  assert.equal(row(path, id).counter, 1);
  const winningIndex = jobs.findIndex((job) => job.result.accepted);
  denied(() => core.consumeGrant(grants[winningIndex].token, attempts[winningIndex].body.request), 'authorization_failed');
  const losing = attempts[1 - winningIndex];
  denied(() => core.commitChallengeCredentialMutation(grants[1 - winningIndex].token,
    losing.body.request, losing.body.bytes, losing.evidence),
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
  bindLegacyCredential(path, owner, 'storage:wallet-test', id);
  const body = revokeAll();
  const grant = core.issueGrant(owner.sessionToken, body.request);
  const pending = core.issueGrant(owner.sessionToken, assertionRequest(id, b64(1)).request);
  assert.deepEqual(core.commitChallengeCredentialMutation(grant.token, body.request, body.bytes, {}),
    { status: 'revoked-all', remainingCredentials: 0, generation: 1 });
  assert.equal(row(path, id).revoked, 1);
  denied(() => core.consumeGrant(pending.token, assertionRequest(id, b64(1)).request), 'authorization_failed');
});

test('legacy revoke-all needs confirmation only when its bound key has live credentials', async (t) => {
  const { core, path, bootstrap } = setup(t);
  const { owner } = await bootstrap();
  const id = b64(2);
  bindLegacyCredential(path, owner, 'storage:wallet-test', id);
  const body = revokeAll('storage:wallet-test', null);
  const grant = core.issueGrant(owner.sessionToken, body.request);
  denied(() => core.commitChallengeCredentialMutation(grant.token,
    body.request, body.bytes, {}), 'final_recovery_route_confirmation_required');
  assert.equal(row(path, id).revoked, 0);
  assert.equal(core.consumeGrant(grant.token, body.request).active, true);

  const emptyKey = 'storage:empty-wallet';
  const db = new DatabaseSync(path);
  try {
    db.prepare('INSERT INTO storage_bindings VALUES(?,?,?,?,?,?)').run(
      emptyKey, owner.subject, b64(8), Buffer.alloc(32, 8).toString('hex'),
      Buffer.alloc(32, 28).toString('hex'), 1);
  } finally { db.close(); }
  const empty = revokeAll(emptyKey, null);
  const emptyGrant = core.issueGrant(owner.sessionToken, empty.request);
  assert.deepEqual(core.commitChallengeCredentialMutation(emptyGrant.token,
    empty.request, empty.bytes, {}),
  { status: 'revoked-all', remainingCredentials: 0, generation: 1 });
  assert.equal(row(path, id).revoked, 0);
});

test('legacy revocation is bound to the exact storage key and revoke-all cannot cross wallets', async (t) => {
  const { core, path, bootstrap } = setup(t);
  const { owner, challenge } = await bootstrap();
  const firstId = b64(2);
  const secondId = b64(53);
  const secondKey = 'storage:second-wallet';
  const db = new DatabaseSync(path);
  try {
    db.prepare('INSERT INTO credentials VALUES(?,?,?,?,?,?,?,0)').run(
      secondId, owner.subject, b64(31), challenge.userHandle, 0, 'multiDevice', 1);
  } finally { db.close(); }
  bindLegacyCredential(path, owner, 'storage:wallet-test', firstId, 1);
  bindLegacyCredential(path, owner, secondKey, secondId, 2);

  const wrong = revocation(secondId);
  const wrongGrant = core.issueGrant(owner.sessionToken, wrong.request);
  denied(() => core.commitChallengeCredentialMutation(wrongGrant.token, wrong.request,
    wrong.bytes, {}), 'authorization_failed');
  assert.equal(row(path, secondId).revoked, 0);
  assert.equal(core.consumeGrant(wrongGrant.token, wrong.request).active, true);

  const body = revokeAll();
  const grant = core.issueGrant(owner.sessionToken, body.request);
  assert.deepEqual(core.commitChallengeCredentialMutation(grant.token, body.request, body.bytes, {}),
    { status: 'revoked-all', remainingCredentials: 0, generation: 1 });
  assert.equal(row(path, firstId).revoked, 1);
  assert.equal(row(path, secondId).revoked, 0);
});

test('legacy revoke-all rejects an unbound storage key without spending its grant', async (t) => {
  const { core, path, bootstrap } = setup(t);
  const { owner } = await bootstrap();
  const body = revokeAll('storage:unbound-wallet');
  const grant = core.issueGrant(owner.sessionToken, body.request);
  denied(() => core.commitChallengeCredentialMutation(grant.token, body.request,
    body.bytes, {}), 'authorization_failed');
  assert.equal(row(path, b64(2)).revoked, 0);
  assert.equal(core.consumeGrant(grant.token, body.request).active, true);
});

test('wallet-key revoke-all preserves an explicitly owner-wide recovery credential', async (t) => {
  const { core, path, bootstrap } = setup(t);
  const { owner, challenge } = await bootstrap();
  bindLegacyCredential(path, owner, 'storage:wallet-test', b64(2));
  const ownerWideId = b64(54);
  const db = new DatabaseSync(path);
  try {
    db.prepare('INSERT INTO credentials VALUES(?,?,?,?,?,?,?,0)').run(
      ownerWideId, owner.subject, b64(31), challenge.userHandle, 0, 'multiDevice', 1);
    assert.deepEqual({ ...db.prepare('SELECT scope,storage_key FROM credential_scopes WHERE credential_id=?').get(ownerWideId) },
      { scope: 'owner', storage_key: null });
  } finally { db.close(); }
  const body = revokeAll();
  const grant = core.issueGrant(owner.sessionToken, body.request);
  assert.deepEqual(core.commitChallengeCredentialMutation(grant.token, body.request,
    body.bytes, {}), { status: 'revoked-all', remainingCredentials: 0, generation: 1 });
  assert.equal(row(path, b64(2)).revoked, 1);
  assert.equal(row(path, ownerWideId).revoked, 0);
  denied(() => core.consumeGrant(grant.token, body.request), 'authorization_failed');
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
  const { owner } = await bootstrap();
  const id = b64(2);
  bindLegacyCredential(path, owner, 'storage:wallet-test', id);
  const { body, evidence } = claimedAssertion(core, owner, id);
  const first = core.issueGrant(owner.sessionToken, body.request);
  faultStage = 'beforeCommit';
  denied(() => core.commitChallengeCredentialMutation(first.token, body.request, body.bytes, evidence), 'store_unavailable');
  faultStage = undefined;
  assert.equal(row(path, id).counter, 0);
  const recovered = open();
  assert.deepEqual(recovered.commitChallengeCredentialMutation(first.token, body.request, body.bytes, evidence),
    { status: 'authenticated', credentialId: id, counter: 1 });
  const secondAttempt = claimedAssertion(recovered, owner, id);
  const second = recovered.issueGrant(owner.sessionToken, secondAttempt.body.request);
  faultStage = 'afterCommit';
  denied(() => recovered.commitChallengeCredentialMutation(second.token,
    secondAttempt.body.request, secondAttempt.body.bytes,
    { ...secondAttempt.evidence, expectedCounter: 1, newCounter: 2 }), 'store_unavailable');
  faultStage = undefined;
  assert.equal(row(path, id).counter, 2);
  const restarted = open();
  denied(() => restarted.consumeGrant(second.token, secondAttempt.body.request), 'authorization_failed');
});

test('explicit v1-to-v5 owner migration retains existing credential and permits atomic counter commit', async (t) => {
  const { core, open, path, bootstrap } = setup(t);
  const { owner } = await bootstrap();
  const id = b64(2);
  core.close();
  downgradeStoreFixture(path, 1);
  denied(() => open(), 'store_unavailable');
  const migrated = open({ migrate: true });
  assert.deepEqual(row(path, id), { owner: owner.subject, counter: 0, revoked: 0 });
  bindLegacyCredential(path, owner, 'storage:wallet-test', id);
  const { body, evidence } = claimedAssertion(migrated, owner, id);
  const grant = migrated.issueGrant(owner.sessionToken, body.request);
  assert.deepEqual(migrated.commitChallengeCredentialMutation(grant.token, body.request, body.bytes, evidence),
  { status: 'authenticated', credentialId: id, counter: 1 });
  assert.deepEqual(row(path, id), { owner: owner.subject, counter: 1, revoked: 0 });
});
