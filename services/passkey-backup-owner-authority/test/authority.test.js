import test from 'node:test';
import assert from 'node:assert/strict';
import { fork } from 'node:child_process';
import { chmodSync, readFileSync, writeFileSync } from 'node:fs';
import { DatabaseSync } from 'node:sqlite';
import { createOwnerAuthority } from '../src/authority.js';
import { hash, SCOPES } from '../src/validation.js';
import { appAttestation, audience, b64, proof, register, assertion, request, verifier, setup } from './fixtures.js';

const denies = (fn, code) => assert.throws(fn, (e) => code ? e.code === code : !!e.code);
const rejects = (promise, code) => assert.rejects(promise, (e) => code ? e.code === code : !!e.code);
function child(message) {
  return new Promise((resolve, reject) => {
    const process = fork(new URL('./process-worker.js', import.meta.url), { stdio: ['ignore', 'ignore', 'pipe', 'ipc'] });
    let result;
    let diagnostic = '';
    process.stderr.on('data', (bytes) => { diagnostic += bytes; });
    process.on('message', (value) => { result = value; });
    process.on('error', reject);
    process.on('exit', (code) => resolve({ code, result, diagnostic }));
    process.send(message);
  });
}

test('default production adapters deny bootstrap and never accept truthy client verification claims', async (t) => {
  const { core } = setup(t, { verifier: undefined });
  const challenge = core.beginBootstrap('android');
  await rejects(core.completeBootstrap({ ceremonyId: challenge.ceremonyId, credential: register(), walletProof: proof,
    appAttestation: appAttestation() }), 'verifier_unavailable');
  await rejects(core.completeBootstrap({ ceremonyId: challenge.ceremonyId, credential: register(), walletProof: proof,
    appAttestation: appAttestation(), verified: true }), 'invalid_request');
});
test('bootstrap requires platform-specific attestation evidence and never persists its transport token', async (t) => {
  const { core, path } = setup(t);
  const missing = core.beginBootstrap('android');
  await rejects(core.completeBootstrap({ ceremonyId: missing.ceremonyId,
    credential: register(), walletProof: proof }), 'invalid_request');
  const wrongPlatform = core.beginBootstrap('android');
  await rejects(core.completeBootstrap({ ceremonyId: wrongPlatform.ceremonyId,
    credential: register(), walletProof: proof,
    appAttestation: appAttestation('ios') }), 'invalid_request');
  const token = 'Z'.repeat(256);
  const valid = core.beginBootstrap('android');
  await core.completeBootstrap({ ceremonyId: valid.ceremonyId, credential: register(),
    walletProof: proof, appAttestation: { kind: 'play-integrity', token } });
  assert.equal(readFileSync(path).includes(Buffer.from(token)), false);
});
test('discoverable owner authentication still requires a concrete credential user handle', async (t) => {
  const { core, bootstrap } = setup(t);
  await bootstrap();
  const challenge = core.beginAuthentication('android');
  await rejects(core.completeAuthentication({ ceremonyId: challenge.ceremonyId,
    credential: assertion(null) }), 'invalid_request');
});
test('bootstrap produces random stable owner namespace; raw sessions and grants never persist', async (t) => {
  const { core, path, bootstrap } = setup(t);
  const { owner, challenge } = await bootstrap();
  assert.equal(owner.subject, challenge.subject);
  assert.match(owner.subject, /^owner:[A-Za-z0-9_-]{43}$/);
  assert.match(owner.namespace, /^backup:[A-Za-z0-9_-]{43}$/);
  assert.notEqual(owner.subject.split(':')[1], owner.namespace.split(':')[1]);
  const grant = core.issueGrant(owner.sessionToken, request());
  const contents = readFileSync(path);
  for (const token of [owner.sessionToken, grant.token]) assert.equal(contents.includes(Buffer.from(token)), false);
  assert.equal(core.consumeGrant(grant.token, request()).subject, owner.subject);
});
test('seven protected routes match existing challenge contract and issue distinct one-use exact-body grants', async (t) => {
  const { AUTHORIZATION_SCOPES } = await import('../../passkey-backup-challenge-service/src/authorization.js');
  assert.deepEqual(SCOPES, AUTHORIZATION_SCOPES);
  const { core, bootstrap } = setup(t);
  const { owner } = await bootstrap();
  const tokens = new Set();
  for (const path of Object.keys(SCOPES)) {
    const binding = request(path, '{"a":1}');
    const grant = core.issueGrant(owner.sessionToken, binding);
    assert.equal(tokens.has(grant.token), false); tokens.add(grant.token);
    denies(() => core.consumeGrant(grant.token, request(path, '{ "a": 1 }')));
    const result = core.consumeGrant(grant.token, binding);
    assert.deepEqual(result, { ...binding, credentialAuthority: 'owner-sqlite-v2', active: true,
      subject: owner.subject, platform: 'android', expiresAt: grant.expiresAt });
    denies(() => core.consumeGrant(grant.token, binding));
  }
});
test('legacy JSON introspector rejects SQLite-owner grants after one-use consumption', async (t) => {
  const { createIntrospectionRequestAuthorizer } = await import('../../passkey-backup-challenge-service/src/authorization.js');
  const { core, bootstrap, clock } = setup(t);
  const { owner } = await bootstrap(); const binding = request(); const grant = core.issueGrant(owner.sessionToken, binding);
  const adapter = createIntrospectionRequestAuthorizer({ introspectionUrl: 'https://authority.example/introspect', audience, now: () => clock.wall,
    fetchImpl: async (_url, init) => {
      try { return new Response(JSON.stringify(core.consumeGrant(init.headers.authorization.slice(7), JSON.parse(init.body))), { headers: { 'content-type': 'application/json' } }); }
      catch { return new Response('{}', { status: 401 }); }
    },
  });
  await rejects(adapter.authorize({ token: grant.token, method: binding.method, path: binding.path,
    bodySha256: binding.bodySha256 }), 'request_authorization_failed');
  await rejects(adapter.authorize({ token: grant.token, method: binding.method, path: binding.path, bodySha256: binding.bodySha256 }), 'request_authorization_failed');
});
test('wrong audience, method, scope, path, noncanonical digest and extra fields cannot mint or consume authority', async (t) => {
  const { core, bootstrap } = setup(t); const { owner } = await bootstrap();
  const grant = core.issueGrant(owner.sessionToken, request());
  for (const change of [{ audience: 'attacker.app' }, { method: 'GET' }, { scope: 'admin' }, { path: '/api/passkey-backup/v1/credentials/list?x=1' },
    { bodySha256: hash('{}') + '=' }, { platform: 'ios' }, { schemaVersion: 2 }]) {
    const invalid = { ...request(), ...change };
    denies(() => core.issueGrant(owner.sessionToken, invalid), 'invalid_request');
    denies(() => core.consumeGrant(grant.token, invalid), 'invalid_request');
  }
  assert.equal(core.consumeGrant(grant.token, request()).active, true);
});
test('parallel separate processes can consume one grant only once', async (t) => {
  const { core, path, clock, bootstrap } = setup(t); const { owner } = await bootstrap();
  const { token } = core.issueGrant(owner.sessionToken, request());
  const runs = await Promise.all(Array.from({ length: 12 }, () => child({ path, audience, token, request: request(), wall: clock.wall })));
  assert.equal(runs.filter((r) => r.result?.accepted).length, 1);
  assert.equal(runs.every((r) => r.code === 0), true, JSON.stringify(runs.filter((r) => r.code !== 0)));
});
test('consumption and owner identity survive restart, without reopening spent grants', async (t) => {
  const { core, open, bootstrap } = setup(t); const { owner } = await bootstrap();
  const first = core.issueGrant(owner.sessionToken, request()); const second = core.issueGrant(owner.sessionToken, request());
  core.consumeGrant(first.token, request()); core.close(); const restarted = open();
  denies(() => restarted.consumeGrant(first.token, request()));
  assert.equal(restarted.consumeGrant(second.token, request()).subject, owner.subject);
});
test('process crash before commit rolls back; crash after commit permanently consumes grant', async (t) => {
  const { core, open, path, clock, bootstrap } = setup(t); const { owner } = await bootstrap();
  const before = core.issueGrant(owner.sessionToken, request());
  assert.equal((await child({ path, audience, token: before.token, request: request(), wall: clock.wall, action: 'crash-before' })).code, 81);
  assert.equal(open().consumeGrant(before.token, request()).active, true);
  const after = core.issueGrant(owner.sessionToken, request());
  assert.equal((await child({ path, audience, token: after.token, request: request(), wall: clock.wall, action: 'crash-after' })).code, 82);
  denies(() => open().consumeGrant(after.token, request()));
});
test('ambiguous commit error poisons process and restart cannot consume spent token', async (t) => {
  let armed = false;
  const { core, open, bootstrap } = setup(t, { fault: (stage) => { if (armed && stage === 'afterCommit') throw Error('synthetic I/O'); } });
  const { owner } = await bootstrap(); const grant = core.issueGrant(owner.sessionToken, request()); armed = true;
  denies(() => core.consumeGrant(grant.token, request()), 'store_unavailable');
  denies(() => core.issueGrant(owner.sessionToken, request()), 'store_unavailable');
  armed = false; denies(() => open().consumeGrant(grant.token, request()));
});
test('failed precommit never leaks success or partially creates owner/session', async (t) => {
  let armed = false; let commits = 0;
  const { core, open } = setup(t, { fault: (stage) => {
    if (armed && stage === 'beforeCommit' && ++commits === 2) throw Error('synthetic I/O after owner insert');
  } });
  const pending = core.beginBootstrap('android'); armed = true;
  await rejects(core.completeBootstrap({ ceremonyId: pending.ceremonyId, credential: register(), walletProof: proof,
    appAttestation: appAttestation() }), 'store_unavailable');
  armed = false; const restart = open();
  const pending2 = restart.beginBootstrap('android');
  const owner = await restart.completeBootstrap({ ceremonyId: pending2.ceremonyId, credential: register(), walletProof: proof,
    appAttestation: appAttestation() });
  assert.notEqual(owner.subject, pending.subject);
});
test('expired grant and observed wall rollback remain denied after restart', async (t) => {
  const { core, open, clock, bootstrap } = setup(t); const { owner } = await bootstrap();
  const grant = core.issueGrant(owner.sessionToken, request());
  clock.wall += 61_000; clock.mono += 61_000;
  denies(() => core.consumeGrant(grant.token, request()));
  clock.wall -= 61_000; core.close(); const restart = open();
  denies(() => restart.consumeGrant(grant.token, request()), 'clock_rollback');
});
test('continuous time expires a grant even while wall time is frozen', async (t) => {
  const { core, open, clock, bootstrap } = setup(t); const { owner } = await bootstrap();
  const grant = core.issueGrant(owner.sessionToken, request()); clock.mono += 61_000;
  denies(() => core.consumeGrant(grant.token, request()));
  core.close(); clock.mono = 0;
  denies(() => open().consumeGrant(grant.token, request()));
});
test('slow durable commit cannot return expired authority and never restores grant', async (t) => {
  let clock; let armed = false;
  const fixture = setup(t, { fault: (stage) => { if (armed && stage === 'beforeCommit') clock.mono += 61_000; } });
  clock = fixture.clock;
  const { owner } = await fixture.bootstrap(); const grant = fixture.core.issueGrant(owner.sessionToken, request()); armed = true;
  denies(() => fixture.core.consumeGrant(grant.token, request()), 'authorization_expired'); armed = false;
  denies(() => fixture.core.consumeGrant(grant.token, request()));
});
test('revocation atomically invalidates outstanding grants, sessions, and active authentication', async (t) => {
  let release;
  const fixture = setup(t, { verifier: verifier({ authentication: ({ registeredCredential }) => new Promise((resolve) => {
    release = () => resolve({ credentialId: registeredCredential.id, newCounter: 1, deviceType: 'multiDevice', backedUp: true });
  }) }) });
  const { core } = fixture; const { owner, challenge } = await fixture.bootstrap();
  const grant = core.issueGrant(owner.sessionToken, request()); const pending = core.beginAuthentication('ios');
  const auth = core.completeAuthentication({ ceremonyId: pending.ceremonyId, credential: assertion(challenge.userHandle) });
  denies(() => core.revokeCredential(owner.sessionToken, b64(2)), 'final_recovery_route_confirmation_required');
  assert.equal(core.revokeCredential(owner.sessionToken, b64(2), true).generation, 1); release();
  await rejects(auth);
  denies(() => core.consumeGrant(grant.token, request()));
  denies(() => core.issueGrant(owner.sessionToken, request()));
  const retry = core.beginAuthentication('ios'); await rejects(core.completeAuthentication({ ceremonyId: retry.ceremonyId, credential: assertion(challenge.userHandle) }));
});
test('revoke-all tombstone prevents Google or new-wallet bootstrap from replacing existing owner', async (t) => {
  const { core, bootstrap } = setup(t); const { owner } = await bootstrap();
  denies(() => core.revokeAll(owner.sessionToken), 'final_recovery_route_confirmation_required');
  core.revokeAll(owner.sessionToken, true);
  const pending = core.beginBootstrap('ios');
  await rejects(core.completeBootstrap({ ceremonyId: pending.ceremonyId, credential: register(b64(6)), walletProof: proof,
    appAttestation: appAttestation('ios') }), 'owner_already_exists');
  const google = core.beginBootstrap('ios');
  await rejects(core.completeBootstrap({ ceremonyId: google.ceremonyId, credential: register(b64(6)),
    walletProof: { googleIdToken: 'not-evidence' }, appAttestation: appAttestation('ios') }), 'invalid_request');
  const fresh = await bootstrap(core, b64(7), b64(10)); assert.notEqual(fresh.owner.subject, owner.subject);
});
test('verified discoverable authentication preserves owner across platforms with exact user handle', async (t) => {
  const { core, bootstrap } = setup(t); const { owner, challenge } = await bootstrap();
  const pending = core.beginAuthentication('ios');
  const renewed = await core.completeAuthentication({ ceremonyId: pending.ceremonyId, credential: assertion(challenge.userHandle) });
  assert.equal(renewed.subject, owner.subject); assert.equal(renewed.namespace, owner.namespace); assert.equal(renewed.platform, 'ios');
  const grant = core.issueGrant(renewed.sessionToken, request()); assert.equal(core.consumeGrant(grant.token, request()).platform, 'ios');
  const mismatch = core.beginAuthentication('ios');
  await rejects(core.completeAuthentication({ ceremonyId: mismatch.ceremonyId, credential: assertion(b64(99)) }), 'verification_failed');
});
test('discoverable authentication uses an imported credential handle rather than the new owner handle', async (t) => {
  const legacyHandle = b64(71);
  const { core, path, bootstrap } = setup(t, { verifier: verifier({
    authentication: async ({ ceremony, registeredCredential }) => {
      assert.equal(ceremony.userHandle, legacyHandle);
      assert.equal(registeredCredential.userHandle, legacyHandle);
      return { credentialId: registeredCredential.id, newCounter: 1,
        deviceType: registeredCredential.deviceType, backedUp: registeredCredential.backedUp };
    },
  }) });
  const { owner, challenge } = await bootstrap();
  assert.notEqual(legacyHandle, challenge.userHandle);
  // Simulate the per-credential historical handle retained by a future
  // proof-bound import. This fixture is not a migration or ownership proof.
  const db = new DatabaseSync(path);
  try { db.prepare('UPDATE credentials SET user_handle=? WHERE id=?').run(legacyHandle, b64(2)); }
  finally { db.close(); }

  const pending = core.beginAuthentication('ios');
  assert.equal(pending.userHandle, null);
  const renewed = await core.completeAuthentication({ ceremonyId: pending.ceremonyId,
    credential: assertion(legacyHandle) });
  assert.equal(renewed.subject, owner.subject);
  assert.equal(renewed.namespace, owner.namespace);
  const wrong = core.beginAuthentication('ios');
  await rejects(core.completeAuthentication({ ceremonyId: wrong.ceremonyId,
    credential: assertion(challenge.userHandle) }), 'verification_failed');
});
test('same valid response is claimed before asynchronous verification, so concurrent replay creates only one session', async (t) => {
  let release; let calls = 0;
  const fixture = setup(t, { verifier: verifier({ authentication: ({ registeredCredential }) => { calls++; return new Promise((resolve) => {
    release = () => resolve({ credentialId: registeredCredential.id, newCounter: 1, deviceType: 'multiDevice', backedUp: true });
  }); } }) });
  const { core } = fixture; const { challenge } = await fixture.bootstrap(); const pending = core.beginAuthentication('ios');
  const input = { ceremonyId: pending.ceremonyId, credential: assertion(challenge.userHandle) };
  const first = core.completeAuthentication(input);
  await rejects(core.completeAuthentication(input)); assert.equal(calls, 1); release(); await first;
  await rejects(core.completeAuthentication(input));
});
test('counter CAS rejects a second concurrently verified assertion with a stale counter', async (t) => {
  let releases = [];
  const fixture = setup(t, { verifier: verifier({ authentication: ({ registeredCredential }) => new Promise((resolve) => {
    releases.push(() => resolve({ credentialId: registeredCredential.id, newCounter: 1, deviceType: 'multiDevice', backedUp: true }));
  }) }) });
  const { core } = fixture; const { challenge } = await fixture.bootstrap();
  const first = core.completeAuthentication({ ceremonyId: core.beginAuthentication('ios').ceremonyId, credential: assertion(challenge.userHandle) });
  const second = core.completeAuthentication({ ceremonyId: core.beginAuthentication('ios').ceremonyId, credential: assertion(challenge.userHandle) });
  releases[0](); await first; releases[1](); await rejects(second, 'credential_counter_replay');
});
test('malformed credential does not burn challenge; well-formed invalid signature burns it with generic diagnostics', async (t) => {
  const fixture = setup(t, { verifier: verifier({ authentication: async () => { throw Error('do not expose proof bytes'); } }) });
  const { core } = fixture; const { challenge } = await fixture.bootstrap(); const pending = core.beginAuthentication('ios');
  await rejects(core.completeAuthentication({ ceremonyId: pending.ceremonyId, credential: { ...assertion(challenge.userHandle), verified: true } }), 'invalid_request');
  const valid = { ceremonyId: pending.ceremonyId, credential: assertion(challenge.userHandle) };
  await assert.rejects(core.completeAuthentication(valid), (error) => error.message === 'verification_failed');
  await rejects(core.completeAuthentication(valid), 'authorization_failed');
});
test('enrollment requires same live session and commits credential/link/generation atomically', async (t) => {
  const { core, bootstrap } = setup(t); const { owner, challenge } = await bootstrap(); const grant = core.issueGrant(owner.sessionToken, request());
  const enrollment = core.beginEnrollment(owner.sessionToken);
  const renewed = await core.completeEnrollment({ ceremonyId: enrollment.ceremonyId, sessionToken: owner.sessionToken, credential: register(b64(6)) });
  assert.equal(renewed.subject, owner.subject); assert.equal(renewed.generation, 1);
  denies(() => core.consumeGrant(grant.token, request())); denies(() => core.issueGrant(owner.sessionToken, request()));
  const restored = await core.completeAuthentication({ ceremonyId: core.beginAuthentication('ios').ceremonyId, credential: assertion(challenge.userHandle, b64(6)) });
  assert.equal(restored.namespace, owner.namespace);
});
test('revocation during enrollment prevents credential resurrection', async (t) => {
  let release;
  const fixture = setup(t, { verifier: verifier({ enrollment: ({ ceremony, credential }) => new Promise((resolve) => {
    release = () => resolve({ credential: { id: credential.id, publicKey: b64(9), userHandle: ceremony.userHandle, counter: 0, deviceType: 'multiDevice', backedUp: true } });
  }) }) });
  const { core } = fixture; const { owner } = await fixture.bootstrap(); const enrollment = core.beginEnrollment(owner.sessionToken);
  const completion = core.completeEnrollment({ ceremonyId: enrollment.ceremonyId, sessionToken: owner.sessionToken, credential: register(b64(6)) });
  core.revokeAll(owner.sessionToken, true); release(); await rejects(completion);
});
test('cross-owner session cannot claim another enrollment or revoke another credential', async (t) => {
  const { core, bootstrap } = setup(t); const { owner: first } = await bootstrap(); const { owner: second } = await bootstrap(core, b64(6), b64(10));
  const pending = core.beginEnrollment(first.sessionToken);
  await rejects(core.completeEnrollment({ ceremonyId: pending.ceremonyId, sessionToken: second.sessionToken, credential: register(b64(7)) }));
  denies(() => core.revokeCredential(second.sessionToken, b64(2)));
  const enrolled = await core.completeEnrollment({ ceremonyId: pending.ceremonyId, sessionToken: first.sessionToken, credential: register(b64(7)) });
  assert.equal(enrolled.subject, first.subject);
});
test('credential IDs cannot move between owners, including after revocation', async (t) => {
  const { core, bootstrap } = setup(t); const { owner } = await bootstrap(); core.revokeAll(owner.sessionToken, true);
  await rejects(bootstrap(core, b64(2), b64(10)), 'credential_already_linked');
});
test('session revocation changes generation, retaining credential for a fresh authentication', async (t) => {
  const { core, bootstrap } = setup(t); const { owner, challenge } = await bootstrap(); core.revokeSessions(owner.sessionToken);
  denies(() => core.issueGrant(owner.sessionToken, request()));
  const renewed = await core.completeAuthentication({ ceremonyId: core.beginAuthentication('ios').ceremonyId, credential: assertion(challenge.userHandle) });
  assert.equal(renewed.generation, 1); assert.equal(renewed.subject, owner.subject);
});
test('PRF, phrases, ciphertext, attestation extras and Google identity are rejected before verifier/persistence', async (t) => {
  const { core, bootstrap } = setup(t); const { owner } = await bootstrap();
  for (const ext of [{ prf: { results: { first: 'secret' } } }, { largeBlob: { blob: 'secret' } }, { unknown: true }]) {
    const pending = core.beginEnrollment(owner.sessionToken);
    await rejects(core.completeEnrollment({ ceremonyId: pending.ceremonyId, sessionToken: owner.sessionToken, credential: { ...register(b64(6)), clientExtensionResults: ext } }), 'invalid_request');
  }
  for (const extra of ['phrase', 'ciphertext', 'googleIdToken', 'privateKey']) {
    const pending = core.beginBootstrap('ios');
    await rejects(core.completeBootstrap({ ceremonyId: pending.ceremonyId, credential: register(b64(7)), walletProof: proof,
      appAttestation: appAttestation('ios'), [extra]: 'secret' }), 'invalid_request');
  }
});
test('bounded anonymous ceremony and session grant issuance denies excess without fallback', async (t) => {
  const { core, bootstrap } = setup(t); const { owner } = await bootstrap();
  for (let i = 0; i < 64; i++) core.issueGrant(owner.sessionToken, request());
  denies(() => core.issueGrant(owner.sessionToken, request()), 'capacity_exceeded');
  for (let i = 0; i < 59; i++) core.beginAuthentication('ios');
  denies(() => core.beginAuthentication('ios'), 'rate_limited');
});
test('database requires explicit private durable creation; missing/corrupt/schema-mismatched stores deny', (t) => {
  const { core, path, open } = setup(t); core.close();
  denies(() => createOwnerAuthority({ path: ':memory:', audience }), 'store_unavailable');
  denies(() => createOwnerAuthority({ path: path + '.missing', audience }), 'store_unavailable');
  denies(() => open({ create: true }), 'store_unavailable');
  chmodSync(path, 0o644); denies(() => open(), 'store_unavailable'); chmodSync(path, 0o600);
  const db = new DatabaseSync(path); db.exec('PRAGMA user_version=8'); db.close(); denies(() => open(), 'store_unavailable');
  writeFileSync(path, 'not a database'); denies(() => open(), 'store_unavailable');
});
test('revoked credential is checked even if an unexpired session/grant row remains', async (t) => {
  const { core, path, bootstrap } = setup(t); const { owner } = await bootstrap(); const grant = core.issueGrant(owner.sessionToken, request());
  // Represents another trusted lifecycle writer recording a revocation. The
  // exact consume query must check credential state, not only session TTL.
  const db = new DatabaseSync(path); db.prepare('UPDATE credentials SET revoked=1 WHERE id=?').run(b64(2)); db.close();
  denies(() => core.consumeGrant(grant.token, request())); denies(() => core.issueGrant(owner.sessionToken, request()));
});
test('zero-counter synced passkeys still require independently consumed challenges', async (t) => {
  const fixture = setup(t, { verifier: verifier({ authentication: async ({ registeredCredential }) => ({
    credentialId: registeredCredential.id, newCounter: 0, deviceType: 'multiDevice', backedUp: true,
  }) }) });
  const { core } = fixture; const { challenge } = await fixture.bootstrap();
  for (let i = 0; i < 2; i++) {
    const input = { ceremonyId: core.beginAuthentication('ios').ceremonyId, credential: assertion(challenge.userHandle) };
    assert.equal((await core.completeAuthentication(input)).platform, 'ios');
    await rejects(core.completeAuthentication(input));
  }
});
test('backup eligibility is immutable and impossible flags cannot update authority', async (t) => {
  for (const flags of [{ deviceType: 'singleDevice', backedUp: false }, { deviceType: 'singleDevice', backedUp: true }, { deviceType: 'unknown', backedUp: true }]) {
    const fixture = setup(t, { verifier: verifier({ authentication: async ({ registeredCredential }) => ({
      credentialId: registeredCredential.id, newCounter: 1, ...flags,
    }) }) });
    const { challenge } = await fixture.bootstrap();
    await rejects(fixture.core.completeAuthentication({ ceremonyId: fixture.core.beginAuthentication('ios').ceremonyId, credential: assertion(challenge.userHandle) }), 'verification_failed');
  }
});
test('client verified booleans and incomplete server adapter results never count as evidence', async (t) => {
  const fixture = setup(t, { verifier: verifier({ bootstrap: async () => ({ verified: true }) }) });
  await rejects(fixture.bootstrap(), 'invalid_request');
});
test('forward wall jump followed by frozen wall does not extend grant lifetime', async (t) => {
  const { core, clock, bootstrap } = setup(t); const { owner } = await bootstrap();
  clock.wall += 30_000;
  const grant = core.issueGrant(owner.sessionToken, request()); clock.mono += 61_000;
  denies(() => core.consumeGrant(grant.token, request()));
});
test('expired sessions cannot mint grants and expired verification cannot establish an owner', async (t) => {
  let release;
  const fixture = setup(t, { verifier: verifier({ bootstrap: (input) => new Promise((resolve) => { release = () => resolve(verifier().bootstrap(input)); }) }) });
  const pending = fixture.bootstrap(); fixture.clock.mono += 121_000; release(); await rejects(pending);
  const other = setup(t); const { owner } = await other.bootstrap(); other.clock.mono += 601_000;
  denies(() => other.core.issueGrant(owner.sessionToken, request()));
});
test('database lock wait is followed by a fresh expiry sample', async (t) => {
  const { core, path, clock, bootstrap } = setup(t); const { owner } = await bootstrap(); const grant = core.issueGrant(owner.sessionToken, request());
  let started;
  const blocked = createOwnerAuthority({ path, audience,
    now: () => clock.wall + (started !== undefined && Date.now() - started >= 100 ? 61_000 : 0), monotonic: () => 0 });
  t.after(() => blocked.close());
  const holder = fork(new URL('./process-worker.js', import.meta.url), { stdio: ['ignore', 'ignore', 'ignore', 'ipc'] });
  t.after(() => holder.kill());
  await new Promise((resolve, reject) => {
    holder.once('message', (message) => { assert.equal(message.locked, true); resolve(); });
    holder.once('error', reject);
    holder.send({ path, action: 'hold-lock' });
  });
  started = Date.now();
  denies(() => blocked.consumeGrant(grant.token, request()));
  assert.ok(Date.now() - started >= 100);
});
test('unknown credential cannot consume a valid unclaimed authentication ceremony', async (t) => {
  const { core, bootstrap } = setup(t); const { challenge } = await bootstrap(); const ceremony = core.beginAuthentication('ios');
  await rejects(core.completeAuthentication({ ceremonyId: ceremony.ceremonyId, credential: assertion(challenge.userHandle, b64(50)) }));
  assert.equal((await core.completeAuthentication({ ceremonyId: ceremony.ceremonyId, credential: assertion(challenge.userHandle) })).platform, 'ios');
});
test('revocation committed by another process invalidates local sessions/grants after a crash', async (t) => {
  const { core, path, clock, bootstrap, open } = setup(t); const { owner, challenge } = await bootstrap();
  const grant = core.issueGrant(owner.sessionToken, request());
  const result = await child({ path, audience, token: owner.sessionToken, wall: clock.wall, action: 'crash-after', revoke: true });
  assert.equal(result.code, 82);
  denies(() => core.consumeGrant(grant.token, request()));
  const restarted = open();
  const auth = restarted.beginAuthentication('ios');
  await rejects(restarted.completeAuthentication({ ceremonyId: auth.ceremonyId, credential: assertion(challenge.userHandle) }));
});
test('authentication and enrollment adapters also fail closed by default for an existing owner', async (t) => {
  const { core, open, bootstrap } = setup(t); const { owner, challenge } = await bootstrap(); core.close();
  const productionDefault = open({ verifier: undefined });
  const auth = productionDefault.beginAuthentication('ios');
  await rejects(productionDefault.completeAuthentication({ ceremonyId: auth.ceremonyId, credential: assertion(challenge.userHandle) }), 'verifier_unavailable');
  const enrollment = productionDefault.beginEnrollment(owner.sessionToken);
  await rejects(productionDefault.completeEnrollment({ ceremonyId: enrollment.ceremonyId, sessionToken: owner.sessionToken, credential: register(b64(6)) }), 'verifier_unavailable');
});
