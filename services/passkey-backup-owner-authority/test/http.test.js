import test from 'node:test';
import assert from 'node:assert/strict';
import { request as httpRequest } from 'node:http';
import { DatabaseSync } from 'node:sqlite';
import { createOwnerHttpServer } from '../src/http.js';
import { hash, SCOPES } from '../src/validation.js';
import { appAttestation, assertion, audience, b64, proof, register, setup, verifier } from './fixtures.js';

const prefix = '/api/passkey-backup/v1';
const route = (suffix) => `${prefix}/${suffix}`;
const walletId = 'wallet-123456';
const accountName = 'ALICE@Example.COM';
const storageKey = `storage:${hash(`${walletId}\0${accountName.toLowerCase()}`)}`;
const credentialId = b64(40);

function testVerifier() {
  return verifier({
    async challengeRegistration({ ceremony, credential }) {
      return { challengeNonce: ceremony.challenge, platform: ceremony.platform,
        credential: { id: credential.id, publicKey: b64(31),
          userHandle: ceremony.userHandle, counter: 0,
          deviceType: 'multiDevice', backedUp: true },
        aaguid: '00000000-0000-0000-0000-000000000000', transportsJson: null };
    },
    async challengeAssertion({ ceremony }) {
      return { challengeNonce: ceremony.challenge, platform: ceremony.platform,
        expectedCounter: ceremony.registeredCredential.counter,
        newCounter: ceremony.registeredCredential.counter + 1,
        deviceType: ceremony.registeredCredential.deviceType,
        backedUp: ceremony.registeredCredential.backedUp };
    },
  });
}

function bindTestStorage(path, owner) {
  const db = new DatabaseSync(path);
  try {
    db.prepare('INSERT INTO storage_bindings VALUES(?,?,?,?,?,?)').run(
      storageKey, owner.subject, b64(12), Buffer.alloc(32, 1).toString('hex'),
      Buffer.alloc(32, 2).toString('hex'), 1,
    );
  } finally { db.close(); }
}

async function openServer(t, authority) {
  const server = createOwnerHttpServer({ authority, audience, enableCandidate: true });
  await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
  t.after(() => new Promise((resolve) => server.close(resolve)));
  const base = `http://127.0.0.1:${server.address().port}`;
  const post = async (path, body, { bearer, session } = {}) => {
    const response = await fetch(base + path, {
      method: 'POST',
      headers: { 'content-type': 'application/json',
        ...(bearer ? { authorization: `Bearer ${bearer}` } : {}),
        ...(session ? { 'x-passkey-owner-session': session } : {}) },
      body: JSON.stringify(body),
    });
    return { status: response.status, body: await response.json() };
  };
  const grant = async (session, path, body) => {
    const issued = await post(route('owner/grant'), {
      schemaVersion: 1, method: 'POST', path,
      bodySha256: hash(Buffer.from(JSON.stringify(body))), scope: SCOPES[path],
    }, { bearer: session });
    assert.equal(issued.status, 200, JSON.stringify(issued.body));
    return issued.body.token;
  };
  const authenticate = async (credential, userHandle) => {
    const challenge = await post(route('owner/authentication/challenge'),
      { schemaVersion: 1, platform: 'android' });
    assert.equal(challenge.status, 200, JSON.stringify(challenge.body));
    const completed = await post(route('owner/authentication/complete'),
      { schemaVersion: 1, ceremonyId: challenge.body.ceremonyId,
        credential: assertion(userHandle, credential) });
    assert.equal(completed.status, 200, JSON.stringify(completed.body));
    assert.match(completed.body.sessionToken, /^session\./);
    return completed.body.sessionToken;
  };
  return { post, grant, authenticate, base };
}

test('one SQLite writer serves discoverable authentication and all seven protected route contracts', async (t) => {
  const { core, path, bootstrap } = setup(t, { verifier: testVerifier() });
  const { owner, challenge: ownerChallenge } = await bootstrap();
  bindTestStorage(path, owner);
  const http = await openServer(t, core);
  let session = await http.authenticate(b64(2), ownerChallenge.userHandle);

  const listPath = route('credentials/list');
  const listBody = { storageKey, rpId: 'fearlesswallet.io', schemaVersion: 1 };
  const listGrant = await http.grant(session, listPath, listBody);
  assert.equal((await http.post(listPath, { ...listBody, storageKey: 'storage:wrong' },
    { bearer: listGrant, session })).status, 403);
  const empty = await http.post(listPath, listBody, { bearer: listGrant, session });
  assert.equal(empty.status, 200);
  assert.deepEqual(empty.body.credentials, []);
  assert.equal((await http.post(listPath, listBody, { bearer: listGrant, session })).status, 403);

  const registrationChallengePath = route('registration/challenge');
  const registrationChallengeBody = { walletId, accountName, displayName: ' Alice ',
    rpId: 'fearlesswallet.io', schemaVersion: 1 };
  const registrationChallengeGrant = await http.grant(session, registrationChallengePath, registrationChallengeBody);
  const registrationChallenge = await http.post(registrationChallengePath, registrationChallengeBody,
    { bearer: registrationChallengeGrant, session });
  assert.equal(registrationChallenge.status, 200);
  assert.equal(registrationChallenge.body.storageKey, storageKey);
  assert.equal(registrationChallenge.body.userId, hash(`user\0${storageKey}`));
  const registrationPath = route('registration/complete');
  const registrationBody = { registrationId: registrationChallenge.body.registrationId,
    rpId: 'fearlesswallet.io', credential: register(credentialId) };
  const registrationGrant = await http.grant(session, registrationPath, registrationBody);
  const registered = await http.post(registrationPath, registrationBody,
    { bearer: registrationGrant, session });
  assert.deepEqual(registered, { status: 200,
    body: { storageKey, rpId: 'fearlesswallet.io', schemaVersion: 1 } });
  assert.equal((await http.post(registrationPath, registrationBody,
    { bearer: registrationGrant, session })).status, 403);

  // Registration bumps the owner generation. An old session cannot mint
  // grants; a fresh discoverable assertion against the enrolled credential can.
  const staleGrant = await http.post(route('owner/grant'), {
    schemaVersion: 1, method: 'POST', path: listPath,
    bodySha256: hash(JSON.stringify(listBody)), scope: SCOPES[listPath],
  }, { bearer: session });
  assert.equal(staleGrant.status, 403);
  session = await http.authenticate(credentialId, registrationChallenge.body.userId);

  const assertionChallengePath = route('assertion/challenge');
  const assertionChallengeBody = { storageKey, rpId: 'fearlesswallet.io', schemaVersion: 1,
    credentialId };
  const assertionChallengeGrant = await http.grant(session, assertionChallengePath, assertionChallengeBody);
  const assertionChallenge = await http.post(assertionChallengePath, assertionChallengeBody,
    { bearer: assertionChallengeGrant, session });
  assert.equal(assertionChallenge.status, 200);
  assert.equal(assertionChallenge.body.credentialId, credentialId);
  const assertionPath = route('assertion/complete');
  const assertionBody = { assertionId: assertionChallenge.body.assertionId,
    rpId: 'fearlesswallet.io', credential: assertion(null, credentialId) };
  const assertionGrant = await http.grant(session, assertionPath, assertionBody);
  const asserted = await http.post(assertionPath, assertionBody, { bearer: assertionGrant, session });
  assert.deepEqual(asserted, { status: 200,
    body: { storageKey, rpId: 'fearlesswallet.io', schemaVersion: 1 } });

  const liveListGrant = await http.grant(session, listPath, listBody);
  const liveList = await http.post(listPath, listBody, { bearer: liveListGrant, session });
  assert.equal(liveList.status, 200);
  assert.equal(liveList.body.credentials.length, 1);
  assert.equal(liveList.body.credentials[0].id, credentialId);

  const revokePath = route('credentials/revoke');
  const revokeBody = { storageKey, credentialId, rpId: 'fearlesswallet.io',
    schemaVersion: 1, confirmFinalRecoveryRemoval: true };
  const revokeGrant = await http.grant(session, revokePath, revokeBody);
  const revoked = await http.post(revokePath, revokeBody, { bearer: revokeGrant, session });
  assert.deepEqual(revoked, { status: 200,
    body: { storageKey, credentialId, remainingCredentials: 0,
      rpId: 'fearlesswallet.io', schemaVersion: 1 } });
  assert.equal((await http.post(revokePath, revokeBody, { bearer: revokeGrant, session })).status, 403);

  session = await http.authenticate(b64(2), ownerChallenge.userHandle);
  const revokeAllPath = route('credentials/revoke-all');
  const revokeAllBody = { storageKey, rpId: 'fearlesswallet.io',
    schemaVersion: 1, confirmFinalRecoveryRemoval: true };
  const revokeAllGrant = await http.grant(session, revokeAllPath, revokeAllBody);
  assert.deepEqual(await http.post(revokeAllPath, revokeAllBody, { bearer: revokeAllGrant, session }),
    { status: 200, body: { storageKey, remainingCredentials: 0,
      rpId: 'fearlesswallet.io', schemaVersion: 1 } });
});

test('candidate HTTP cannot be constructed for production or without an explicit test admission', (t) => {
  const { core } = setup(t);
  assert.throws(() => createOwnerHttpServer({ authority: core, audience }),
    /not admitted for production/);
  const prior = process.env.NODE_ENV;
  try {
    process.env.NODE_ENV = 'production';
    assert.throws(() => createOwnerHttpServer({ authority: core, audience, enableCandidate: true }),
      /not admitted for production/);
  } finally {
    if (prior === undefined) delete process.env.NODE_ENV;
    else process.env.NODE_ENV = prior;
  }
});

test('candidate HTTP bootstrap requires the server verifier, rejects local PRF output, and burns replay', async (t) => {
  const { core, path } = setup(t, { verifier: testVerifier() });
  const http = await openServer(t, core);
  const challenge = await http.post(route('owner/bootstrap/challenge'),
    { schemaVersion: 1, platform: 'android' });
  assert.equal(challenge.status, 200);
  assert.equal(challenge.body.kind, 'bootstrap');
  assert.match(challenge.body.subject, /^owner:/u);
  const body = { schemaVersion: 1, ceremonyId: challenge.body.ceremonyId,
    credential: register(b64(50)), walletProof: proof, appAttestation: appAttestation() };
  const leaked = await http.post(route('owner/bootstrap/complete'), {
    ...body, credential: { ...body.credential, clientExtensionResults: { prf: { results: {} } } },
  });
  assert.equal(leaked.status, 400);
  const completed = await http.post(route('owner/bootstrap/complete'), body);
  assert.equal(completed.status, 200, JSON.stringify(completed.body));
  assert.match(completed.body.sessionToken, /^session\./u);
  assert.equal(completed.body.subject, challenge.body.subject);
  assert.equal(completed.body.namespace, challenge.body.namespace);
  assert.equal((await http.post(route('owner/bootstrap/complete'), body)).status, 403);
  assert.equal((await http.post(route('owner/bootstrap/challenge'),
    { schemaVersion: 1, platform: 'android' }, { session: completed.body.sessionToken })).status, 400);

  const duplicateChallenge = await http.post(route('owner/bootstrap/challenge'),
    { schemaVersion: 1, platform: 'android' });
  const duplicate = await http.post(route('owner/bootstrap/complete'), {
    ...body, ceremonyId: duplicateChallenge.body.ceremonyId, credential: register(b64(51)),
  });
  assert.equal(duplicate.status, 409);
  const db = new DatabaseSync(path, { readOnly: true });
  try { assert.equal(db.prepare('SELECT count(*) AS n FROM owners').get().n, 1); }
  finally { db.close(); }
});

test('candidate HTTP bootstrap accepts the bounded iOS proof size and denies an unavailable verifier', async (t) => {
  const { core, open, path } = setup(t, { verifier: testVerifier() });
  const http = await openServer(t, core);
  const challenge = await http.post(route('owner/bootstrap/challenge'),
    { schemaVersion: 1, platform: 'ios' });
  const baseCredential = register(b64(60));
  const body = { schemaVersion: 1, ceremonyId: challenge.body.ceremonyId,
    credential: { ...baseCredential, response: {
      ...baseCredential.response, attestationObject: b64(61, 16_384),
    } },
    walletProof: proof,
    appAttestation: { ...appAttestation('ios'), attestationObject: b64(62, 32_768) },
  };
  assert.ok(Buffer.byteLength(JSON.stringify(body)) > 64 * 1024);
  assert.equal((await http.post(route('owner/bootstrap/complete'), body)).status, 200);

  const unavailable = open({ verifier: undefined });
  const denied = await openServer(t, unavailable);
  const deniedChallenge = await denied.post(route('owner/bootstrap/challenge'),
    { schemaVersion: 1, platform: 'android' });
  const deniedCompletion = await denied.post(route('owner/bootstrap/complete'), {
    schemaVersion: 1, ceremonyId: deniedChallenge.body.ceremonyId,
    credential: register(b64(63)),
    walletProof: { ...proof, publicKey: b64(64) },
    appAttestation: appAttestation(),
  });
  assert.equal(deniedCompletion.status, 503);
  const db = new DatabaseSync(path, { readOnly: true });
  try { assert.equal(db.prepare('SELECT count(*) AS n FROM owners').get().n, 1); }
  finally { db.close(); }
});

test('candidate HTTP backup head and commit require the exact owner session and one-use generation grant', async (t) => {
  const { core, bootstrap } = setup(t);
  const { owner } = await bootstrap();
  const { owner: stranger } = await bootstrap(core, b64(71), b64(72));
  const http = await openServer(t, core);
  const headPath = route('owner/backup/head');
  const operationPath = route('owner/backup/operation');
  const grantPath = route('owner/backup/grant');
  const commitPath = route('owner/backup/commit');
  const first = { schemaVersion: 1, operationId: b64(73), generationId: b64(74),
    backupNamespace: owner.namespace, expectedHeadRevision: '0', expectedHeadSha256: null,
    bundleSha256: 'a'.repeat(64), keyEpoch: '1', driveFileId: 'drive-http-one',
    storageAccountBinding: 'b'.repeat(64) };
  assert.equal((await http.post(headPath, { schemaVersion: 1 })).status, 403);
  const empty = await http.post(headPath, { schemaVersion: 1 }, { bearer: owner.sessionToken });
  assert.equal(empty.status, 200);
  assert.equal(empty.body.head, null);
  assert.equal((await http.post(grantPath, { ...first, prfOutput: 'secret' },
    { bearer: owner.sessionToken })).status, 400);
  const issued = await http.post(grantPath, first, { bearer: owner.sessionToken });
  assert.equal(issued.status, 200, JSON.stringify(issued.body));
  const grant = issued.body.token;
  assert.match(grant, /^grant\./u);
  assert.equal((await http.post(commitPath, first, { bearer: grant })).status, 403);
  assert.equal((await http.post(commitPath, first,
    { bearer: grant, session: stranger.sessionToken })).status, 403);
  assert.equal((await http.post(commitPath, { ...first, bundleSha256: 'c'.repeat(64) },
    { bearer: grant, session: owner.sessionToken })).status, 403);
  const committed = await http.post(commitPath, first,
    { bearer: grant, session: owner.sessionToken });
  assert.equal(committed.status, 200, JSON.stringify(committed.body));
  assert.equal(committed.body.descriptor.keyEpoch, '1');
  assert.equal((await http.post(commitPath, first,
    { bearer: grant, session: owner.sessionToken })).status, 403);
  const head = await http.post(headPath, { schemaVersion: 1 }, { bearer: owner.sessionToken });
  assert.deepEqual(head.body.head, committed.body.descriptor);
  assert.equal(head.body.previous, null);
  const status = await http.post(operationPath, { schemaVersion: 1, operationId: first.operationId },
    { bearer: owner.sessionToken });
  assert.deepEqual(status.body, committed.body);
  const next = { ...first, operationId: b64(75), generationId: b64(76),
    bundleSha256: 'c'.repeat(64), driveFileId: 'drive-http-two' };
  const nextGrant = await http.post(grantPath, next, { bearer: owner.sessionToken });
  assert.equal(nextGrant.status, 200);
  assert.equal((await http.post(commitPath, next,
    { bearer: nextGrant.body.token, session: owner.sessionToken })).status, 409);
  core.revokeSessions(owner.sessionToken);
  assert.equal((await http.post(commitPath, next,
    { bearer: nextGrant.body.token, session: owner.sessionToken })).status, 403);
  assert.equal((await http.post(headPath, { schemaVersion: 1 },
    { bearer: owner.sessionToken })).status, 403);
});

test('candidate transport rejects malformed paths, secret extensions and missing owner session', async (t) => {
  const { core, path, bootstrap } = setup(t, { verifier: testVerifier() });
  const { owner } = await bootstrap();
  bindTestStorage(path, owner);
  const http = await openServer(t, core);
  const body = { storageKey, rpId: 'fearlesswallet.io', schemaVersion: 1 };
  const token = await http.grant(owner.sessionToken, route('credentials/list'), body);
  assert.equal((await http.post(route('credentials/list'), body, { bearer: token })).status, 403);
  assert.equal((await http.post(`${route('credentials/list')}?foo=1`, body,
    { bearer: token, session: owner.sessionToken })).status, 400);
  assert.equal((await http.post(route('credentials/list'), body,
    { bearer: token, session: owner.sessionToken })).status, 200);
  const bad = await http.post(route('owner/authentication/complete'), {
    schemaVersion: 1, ceremonyId: 'ceremony.invalid',
    credential: { ...assertion(b64(2)), clientExtensionResults: { prf: {} } },
  });
  assert.equal(bad.status, 400);
});

test('candidate transport rejects duplicate sensitive headers and oversized bodies before authority work', async (t) => {
  const { core, path } = setup(t);
  const { base } = await openServer(t, core);
  const sendRaw = (headers, body) => new Promise((resolve, reject) => {
    const request = httpRequest(base + route('owner/authentication/challenge'),
      { method: 'POST', headers }, (response) => {
        const chunks = [];
        response.on('data', (chunk) => chunks.push(chunk));
        response.on('end', () => resolve({ status: response.statusCode,
          body: Buffer.concat(chunks).toString('utf8') }));
      });
    request.on('error', reject);
    request.end(body);
  });
  const body = JSON.stringify({ schemaVersion: 1, platform: 'android' });
  assert.equal((await sendRaw([
    'Host', new URL(base).host,
    'Content-Type', 'application/json', 'Content-Type', 'application/json',
    'Content-Length', String(Buffer.byteLength(body)),
  ], body)).status, 400);
  for (const duplicated of [
    '{"schemaVersion":1,"schemaVersion":1,"platform":"android"}',
    '{"schemaVersion":1,"platform":"android","\\u0070latform":"ios"}',
    '{"schemaVersion":1,"platform":{"name":"android","\\u006eame":"ios"}}',
  ]) {
    assert.equal((await sendRaw([
      'Host', new URL(base).host,
      'Content-Type', 'application/json',
      'Content-Length', String(Buffer.byteLength(duplicated)),
    ], duplicated)).status, 400);
  }
  const oversized = 'x'.repeat(64 * 1024 + 1);
  const rejected = await sendRaw([
    'Host', new URL(base).host,
    'Content-Type', 'application/json',
    'Content-Length', String(Buffer.byteLength(oversized)),
  ], oversized);
  assert.equal(rejected.status, 413, JSON.stringify(rejected));
  const db = new DatabaseSync(path, { readOnly: true });
  try { assert.equal(db.prepare('SELECT count(*) AS n FROM ceremonies').get().n, 0); }
  finally { db.close(); }
});
