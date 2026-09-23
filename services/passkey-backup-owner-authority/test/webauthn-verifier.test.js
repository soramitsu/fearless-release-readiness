import assert from 'node:assert/strict';
import { randomBytes } from 'node:crypto';
import { DatabaseSync } from 'node:sqlite';
import test from 'node:test';
import {
  authenticationCredential, createAuthenticator, registrationCredential,
} from '../../passkey-backup-challenge-service/test/webauthn-fixture.js';
import { AuthorityError, hash } from '../src/validation.js';
import { createWebAuthnVerifier } from '../src/webauthn-verifier.js';
import { audience, b64, proof, register, setup, verifier as fakeVerifier } from './fixtures.js';

const androidOrigin = `android:apk-key-hash:${Buffer.alloc(32, 0xa5).toString('base64url')}`;
const iosOrigin = 'https://fearlesswallet.io';
const verifier = createWebAuthnVerifier({
  allowedOrigins: { android: [androidOrigin], ios: [iosOrigin] },
});

function ceremony(kind, platform) {
  return {
    ceremonyId: `ceremony.${randomBytes(32).toString('base64url')}`,
    kind,
    challenge: randomBytes(32).toString('base64url'),
    rpId: 'fearlesswallet.io',
    platform,
    subject: `owner:${randomBytes(32).toString('base64url')}`,
    namespace: `backup:${randomBytes(32).toString('base64url')}`,
    userHandle: randomBytes(32).toString('base64url'),
    expiresAt: Date.now() / 1000 + 120,
  };
}

function publicRegistration(source) {
  return {
    id: source.id,
    rawId: source.rawId,
    type: source.type,
    authenticatorAttachment: source.authenticatorAttachment,
    clientExtensionResults: source.clientExtensionResults,
    response: {
      clientDataJSON: source.response.clientDataJSON,
      attestationObject: source.response.attestationObject,
      publicKeyAlgorithm: source.response.publicKeyAlgorithm,
      ...(source.response.transports === undefined ? {} : { transports: source.response.transports }),
    },
  };
}

const storageKey = 'storage:verified-wallet';
const route = {
  registration: ['/api/passkey-backup/v1/registration/complete', 'passkey.registration.complete'],
  assertion: ['/api/passkey-backup/v1/assertion/complete', 'passkey.assertion.complete'],
};
function mutation(kind, challengeId, credential) {
  const bytes = Buffer.from(JSON.stringify({
    [kind === 'registration' ? 'registrationId' : 'assertionId']: challengeId,
    rpId: 'fearlesswallet.io', credential,
  }));
  return { bytes, request: { schemaVersion: 1, audience, method: 'POST',
    path: route[kind][0], scope: route[kind][1], bodySha256: hash(bytes) } };
}
function fixtureOwner(t, platform, overrides = {}) {
  const composite = { ...fakeVerifier(),
    challengeRegistration: verifier.challengeRegistration,
    challengeAssertion: verifier.challengeAssertion, ...overrides };
  const fixture = setup(t, { verifier: composite });
  return { ...fixture, async bootstrapForPlatform() {
    const challenge = fixture.core.beginBootstrap(platform);
    const owner = await fixture.core.completeBootstrap({ ceremonyId: challenge.ceremonyId,
      credential: register(), walletProof: proof });
    const db = new DatabaseSync(fixture.path);
    try {
      db.prepare('INSERT INTO storage_bindings VALUES(?,?,?,?,?,?)').run(
        storageKey, owner.subject, b64(1), 'a'.repeat(64), 'b'.repeat(64), 1);
    } finally { db.close(); }
    return owner;
  } };
}
async function registerForKey(core, owner, authenticator, origin) {
  const pending = core.beginChallengeCredentialMutation(owner.sessionToken,
    { kind: 'registration', storageKey });
  const credential = publicRegistration(registrationCredential(pending.challenge, authenticator, { origin }));
  const body = mutation('registration', pending.challengeId, credential);
  const grant = core.issueGrant(owner.sessionToken, body.request);
  const result = await core.verifyAndCommitChallengeCredentialMutation(owner.sessionToken,
    grant.token, body.request, body.bytes);
  return { pending, credential, result };
}
async function signedAssertionFixture(t, { platform = 'ios', origin = iosOrigin, overrides = {} } = {}) {
  const fixture = fixtureOwner(t, platform, overrides);
  const owner = await fixture.bootstrapForPlatform();
  const authenticator = createAuthenticator(`assertion-${randomBytes(8).toString('hex')}`);
  const registered = await registerForKey(fixture.core, owner, authenticator, origin);
  const auth = fixture.core.beginAuthentication(platform);
  const resumed = await fixture.core.completeAuthentication({ ceremonyId: auth.ceremonyId,
    credential: publicAuthentication(authenticationCredential(auth.challenge,
      authenticator, registered.pending.userHandle, { origin, counter: 1 })) });
  return { ...fixture, owner: resumed, authenticator, credentialId: registered.credential.id,
    userHandle: registered.pending.userHandle };
}

function publicAuthentication(source) {
  return {
    id: source.id,
    rawId: source.rawId,
    type: source.type,
    clientExtensionResults: source.clientExtensionResults,
    response: {
      clientDataJSON: source.response.clientDataJSON,
      authenticatorData: source.response.authenticatorData,
      signature: source.response.signature,
      userHandle: source.response.userHandle,
    },
  };
}

async function enrolled(platform, origin, authenticator = createAuthenticator(), flags = 0x45) {
  const registration = ceremony('enrollment', platform);
  const credential = publicRegistration(registrationCredential(registration.challenge, authenticator, { origin, flags }));
  const result = await verifier.enrollment({ ceremony: registration, credential });
  return { authenticator, record: result.credential, registration, credential };
}

test('backup-eligible synced credential flags remain bound across authentication', async () => {
  const { authenticator, record } = await enrolled('ios', iosOrigin, createAuthenticator(), 0x5d);
  assert.equal(record.deviceType, 'multiDevice');
  assert.equal(record.backedUp, true);
  const authentication = { ...ceremony('authentication', 'ios'), userHandle: record.userHandle };
  const credential = publicAuthentication(authenticationCredential(
    authentication.challenge, authenticator, record.userHandle,
    { origin: iosOrigin, flags: 0x1d, counter: 1 },
  ));
  assert.deepEqual(await verifier.authentication({
    ceremony: authentication, credential, registeredCredential: record,
  }), {
    credentialId: record.id,
    newCounter: 1,
    deviceType: 'multiDevice',
    backedUp: true,
  });
});

for (const [platform, origin] of [['ios', iosOrigin], ['android', androidOrigin]]) {
  test(`${platform} verified enrollment and exact-owner authentication`, async () => {
    const { authenticator, record, registration } = await enrolled(platform, origin);
    assert.equal(record.userHandle, registration.userHandle);
    assert.equal(record.counter, 0);
    assert.equal(record.deviceType, 'singleDevice');
    assert.equal(record.backedUp, false);

    const authentication = { ...ceremony('authentication', platform), userHandle: registration.userHandle };
    const credential = publicAuthentication(authenticationCredential(
      authentication.challenge, authenticator, record.userHandle, { origin, counter: 1 },
    ));
    const result = await verifier.authentication({
      ceremony: authentication, credential, registeredCredential: record,
    });
    assert.deepEqual(result, {
      credentialId: record.id,
      newCounter: 1,
      deviceType: 'singleDevice',
      backedUp: false,
    });
  });
}

test('first-owner bootstrap remains unavailable without wallet proof and attestation', async () => {
  await assert.rejects(verifier.bootstrap({}), (error) =>
    error instanceof AuthorityError && error.code === 'verifier_unavailable');
});

test('platform origin, challenge, RP and user-handle substitutions are rejected', async () => {
  const authenticator = createAuthenticator();
  const registration = ceremony('enrollment', 'ios');
  for (const options of [
    { origin: androidOrigin },
    { origin: 'https://evil.example' },
    { origin: iosOrigin, rpId: 'evil.example' },
  ]) {
    const credential = publicRegistration(registrationCredential(registration.challenge, authenticator, options));
    await assert.rejects(verifier.enrollment({ ceremony: registration, credential }),
      (error) => error instanceof AuthorityError && error.code === 'verification_failed');
  }
  const { record } = await enrolled('ios', iosOrigin, authenticator);
  const authentication = { ...ceremony('authentication', 'ios'), userHandle: record.userHandle };
  const wrongOrigin = publicAuthentication(authenticationCredential(
    authentication.challenge, authenticator, record.userHandle, { origin: androidOrigin },
  ));
  await assert.rejects(verifier.authentication({ ceremony: authentication, credential: wrongOrigin, registeredCredential: record }),
    (error) => error instanceof AuthorityError && error.code === 'verification_failed');
  for (const userHandle of [randomBytes(32).toString('base64url'), record.userHandle]) {
    const credential = publicAuthentication(authenticationCredential(
      randomBytes(32).toString('base64url'), authenticator, userHandle, { origin: iosOrigin },
    ));
    await assert.rejects(verifier.authentication({ ceremony: authentication, credential, registeredCredential: record }),
      (error) => error instanceof AuthorityError && error.code === 'verification_failed');
  }
});

test('tampered signatures, UV/UP removal and replayed counters are rejected', async () => {
  const { authenticator, record } = await enrolled('android', androidOrigin);
  const authentication = { ...ceremony('authentication', 'android'), userHandle: record.userHandle };
  const valid = publicAuthentication(authenticationCredential(
    authentication.challenge, authenticator, record.userHandle, { origin: androidOrigin, counter: 2 },
  ));
  const badSignature = structuredClone(valid);
  badSignature.response.signature = Buffer.alloc(64, 0).toString('base64url');
  await assert.rejects(verifier.authentication({ ceremony: authentication, credential: badSignature, registeredCredential: record }),
    (error) => error instanceof AuthorityError && error.code === 'verification_failed');

  for (const flags of [0x00, 0x01]) {
    const credential = publicAuthentication(authenticationCredential(
      authentication.challenge, authenticator, record.userHandle, { origin: androidOrigin, flags, counter: 2 },
    ));
    await assert.rejects(verifier.authentication({ ceremony: authentication, credential, registeredCredential: record }),
      (error) => error instanceof AuthorityError && error.code === 'verification_failed');
  }
  await assert.rejects(verifier.authentication({
    ceremony: authentication,
    credential: valid,
    registeredCredential: { ...record, counter: 2 },
  }), (error) => error instanceof AuthorityError && error.code === 'verification_failed');
});

test('local PRF output cannot enter the server verifier', async () => {
  const { authenticator, record } = await enrolled('ios', iosOrigin);
  const authentication = { ...ceremony('authentication', 'ios'), userHandle: record.userHandle };
  const credential = publicAuthentication(authenticationCredential(
    authentication.challenge, authenticator, record.userHandle, { origin: iosOrigin },
  ));
  credential.clientExtensionResults = { prf: { results: { first: 'secret' } } };
  await assert.rejects(verifier.authentication({ ceremony: authentication, credential, registeredCredential: record }),
    (error) => error instanceof AuthorityError && error.code === 'invalid_request');
});

test('origin policy rejects ambiguous and unsupported configuration', () => {
  for (const allowedOrigins of [
    { android: [androidOrigin], ios: [iosOrigin, iosOrigin] },
    { android: [iosOrigin], ios: [iosOrigin] },
    { android: [androidOrigin], ios: ['http://fearlesswallet.io'] },
    { android: [androidOrigin], ios: [iosOrigin], unknown: ['https://evil.example'] },
  ]) {
    assert.throws(() => createWebAuthnVerifier({ allowedOrigins }),
      (error) => error instanceof AuthorityError && error.code === 'invalid_configuration');
  }
});

for (const [platform, origin] of [['ios', iosOrigin], ['android', androidOrigin]]) {
  test(`${platform} v5 claimed registration and directed assertion verify real signatures before SQLite commit`, async (t) => {
    const { core, path, bootstrapForPlatform } = fixtureOwner(t, platform);
    const owner = await bootstrapForPlatform();
    const authenticator = createAuthenticator(`v5-${platform}`);
    const registered = await registerForKey(core, owner, authenticator, origin);
    assert.deepEqual(registered.result, {
      status: 'registered', storageKey, credentialId: registered.credential.id, generation: 1,
    });
    const db = new DatabaseSync(path, { readOnly: true });
    try {
      const metadata = db.prepare(`SELECT m.aaguid,m.transports_json,m.registration_platform,
        s.scope,s.storage_key,c.user_handle,c.public_key FROM legacy_credential_metadata m
        JOIN credential_scopes s ON s.credential_id=m.credential_id
        JOIN credentials c ON c.id=m.credential_id WHERE m.credential_id=?`).get(registered.credential.id);
      assert.equal(metadata.aaguid, '00000000-0000-0000-0000-000000000000');
      assert.equal(metadata.transports_json, '["internal"]');
      assert.equal(metadata.registration_platform, platform);
      assert.equal(metadata.scope, 'storage');
      assert.equal(metadata.storage_key, storageKey);
      assert.equal(metadata.user_handle, registered.pending.userHandle);
      assert.equal(metadata.public_key, authenticator.credentialPublicKey.toString('base64url'));
    } finally { db.close(); }

    // Test-only owner authentication gets a fresh session after registration's
    // generation bump; the v5 assertion itself uses a real signed response.
    const auth = core.beginAuthentication(platform);
    const resumed = await core.completeAuthentication({ ceremonyId: auth.ceremonyId,
      credential: publicAuthentication(authenticationCredential(auth.challenge,
        authenticator, registered.pending.userHandle, { origin, counter: 1 })) });
    const pending = core.beginChallengeCredentialMutation(resumed.sessionToken,
      { kind: 'assertion', storageKey, directedCredentialId: registered.credential.id });
    const credential = publicAuthentication(authenticationCredential(pending.challenge,
      authenticator, null, { origin, counter: 2 }));
    const body = mutation('assertion', pending.challengeId, credential);
    const grant = core.issueGrant(resumed.sessionToken, body.request);
    assert.deepEqual(await core.verifyAndCommitChallengeCredentialMutation(resumed.sessionToken,
      grant.token, body.request, body.bytes),
    { status: 'authenticated', storageKey, credentialId: registered.credential.id, counter: 2 });
    assert.equal(dbOpenCounter(path, registered.credential.id), 2);
  });
}

function dbOpenCounter(path, id) {
  const db = new DatabaseSync(path, { readOnly: true });
  try { return db.prepare('SELECT counter FROM credentials WHERE id=?').get(id)?.counter; }
  finally { db.close(); }
}

test('v5 registration rejects wrong nonce, origin, RP, missing UV/UP and caller success claims', async (t) => {
  const { core, path, bootstrapForPlatform } = fixtureOwner(t, 'ios');
  const owner = await bootstrapForPlatform();
  const authenticator = createAuthenticator('v5-negative-registration');
  const cases = [
    (challenge) => registrationCredential(b64(50), authenticator, { origin: iosOrigin }),
    (challenge) => registrationCredential(challenge, authenticator, { origin: androidOrigin }),
    (challenge) => registrationCredential(challenge, authenticator, { origin: iosOrigin, rpId: 'evil.example' }),
    (challenge) => registrationCredential(challenge, authenticator, { origin: iosOrigin, flags: 0x41 }),
    (challenge) => registrationCredential(challenge, authenticator, { origin: iosOrigin, flags: 0x44 }),
  ];
  for (const make of cases) {
    const pending = core.beginChallengeCredentialMutation(owner.sessionToken,
      { kind: 'registration', storageKey });
    const body = mutation('registration', pending.challengeId,
      publicRegistration(make(pending.challenge)));
    const grant = core.issueGrant(owner.sessionToken, body.request);
    await assert.rejects(core.verifyAndCommitChallengeCredentialMutation(owner.sessionToken,
      grant.token, body.request, body.bytes),
    (error) => error instanceof AuthorityError && error.code === 'verification_failed');
    assert.equal(dbOpenCounter(path, authenticator.credentialId.toString('base64url')), undefined);
    assert.equal(core.consumeGrant(grant.token, body.request).active, true);
    await assert.rejects(core.verifyAndCommitChallengeCredentialMutation(owner.sessionToken,
      grant.token, body.request, body.bytes),
    (error) => error instanceof AuthorityError && error.code === 'authorization_failed');
  }
  const pending = core.beginChallengeCredentialMutation(owner.sessionToken,
    { kind: 'registration', storageKey });
  const valid = publicRegistration(registrationCredential(pending.challenge, authenticator,
    { origin: iosOrigin }));
  const leaked = structuredClone(valid);
  leaked.clientExtensionResults = { prf: { results: { first: b64(99) } } };
  for (const contaminated of [leaked, { ...valid, verified: true }]) {
    const body = mutation('registration', pending.challengeId, contaminated);
    const grant = core.issueGrant(owner.sessionToken, body.request);
    await assert.rejects(core.verifyAndCommitChallengeCredentialMutation(owner.sessionToken,
      grant.token, body.request, body.bytes),
    (error) => error instanceof AuthorityError && error.code === 'invalid_request');
    assert.equal(core.consumeGrant(grant.token, body.request).active, true);
  }
  const body = mutation('registration', pending.challengeId, valid);
  const grant = core.issueGrant(owner.sessionToken, body.request);
  assert.equal((await core.verifyAndCommitChallengeCredentialMutation(owner.sessionToken,
    grant.token, body.request, body.bytes)).status, 'registered');
});

test('v5 claimed assertion rejects nonce, origin, RP, signature, public-key, UV/UP and counter substitution', async (t) => {
  const { core, path, clock, owner, authenticator, credentialId, userHandle } =
    await signedAssertionFixture(t);
  const wrongSigner = createAuthenticator('v5-wrong-signer');
  const cases = [
    (challenge) => authenticationCredential(b64(70), authenticator, userHandle,
      { origin: iosOrigin, counter: 2 }),
    (challenge) => authenticationCredential(challenge, authenticator, userHandle,
      { origin: androidOrigin, counter: 2 }),
    (challenge) => authenticationCredential(challenge, authenticator, userHandle,
      { origin: iosOrigin, rpId: 'evil.example', counter: 2 }),
    (challenge) => {
      const response = authenticationCredential(challenge, authenticator, userHandle,
        { origin: iosOrigin, counter: 2 });
      response.response.signature = b64(90, 64);
      return response;
    },
    (challenge) => authenticationCredential(challenge, wrongSigner, userHandle,
      { origin: iosOrigin, counter: 2, credentialId: authenticator.credentialId }),
    (challenge) => authenticationCredential(challenge, authenticator, userHandle,
      { origin: iosOrigin, flags: 0x01, counter: 2 }),
    (challenge) => authenticationCredential(challenge, authenticator, userHandle,
      { origin: iosOrigin, flags: 0x04, counter: 2 }),
    (challenge) => authenticationCredential(challenge, authenticator, userHandle,
      { origin: iosOrigin, counter: 1 }),
  ];
  for (const make of cases) {
    const pending = core.beginChallengeCredentialMutation(owner.sessionToken,
      { kind: 'assertion', storageKey, directedCredentialId: credentialId });
    const body = mutation('assertion', pending.challengeId,
      publicAuthentication(make(pending.challenge)));
    const grant = core.issueGrant(owner.sessionToken, body.request);
    await assert.rejects(core.verifyAndCommitChallengeCredentialMutation(owner.sessionToken,
      grant.token, body.request, body.bytes, { verified: true }),
    (error) => error instanceof AuthorityError && error.code === 'verification_failed');
    assert.equal(dbOpenCounter(path, credentialId), 1);
    assert.equal(core.consumeGrant(grant.token, body.request).active, true);
  }
  clock.mono += 121_000; // Expire claimed negative ceremonies before the next case.
  const undirected = core.beginChallengeCredentialMutation(owner.sessionToken,
    { kind: 'assertion', storageKey });
  const nullHandle = mutation('assertion', undirected.challengeId,
    publicAuthentication(authenticationCredential(undirected.challenge,
      authenticator, null, { origin: iosOrigin, counter: 2 })));
  const grant = core.issueGrant(owner.sessionToken, nullHandle.request);
  await assert.rejects(core.verifyAndCommitChallengeCredentialMutation(owner.sessionToken,
    grant.token, nullHandle.request, nullHandle.bytes),
  (error) => error instanceof AuthorityError && error.code === 'verification_failed');
  assert.equal(core.consumeGrant(grant.token, nullHandle.request).active, true);
});

test('v5 verifier claim is burned before asynchronous work and owner revocation blocks its commit', async (t) => {
  let resolveEntered;
  let release;
  const entered = new Promise((resolve) => { resolveEntered = resolve; });
  const gate = new Promise((resolve) => { release = resolve; });
  const { core, path, owner, authenticator, credentialId, userHandle } =
    await signedAssertionFixture(t, { overrides: {
      async challengeAssertion(input) {
        resolveEntered();
        await gate;
        return verifier.challengeAssertion(input);
      },
    } });
  const pending = core.beginChallengeCredentialMutation(owner.sessionToken,
    { kind: 'assertion', storageKey, directedCredentialId: credentialId });
  const body = mutation('assertion', pending.challengeId,
    publicAuthentication(authenticationCredential(pending.challenge,
      authenticator, userHandle, { origin: iosOrigin, counter: 2 })));
  const grant = core.issueGrant(owner.sessionToken, body.request);
  const inFlight = core.verifyAndCommitChallengeCredentialMutation(owner.sessionToken,
    grant.token, body.request, body.bytes);
  await entered;
  await assert.rejects(core.verifyAndCommitChallengeCredentialMutation(owner.sessionToken,
    grant.token, body.request, body.bytes),
  (error) => error instanceof AuthorityError && error.code === 'authorization_failed');
  core.revokeCredential(owner.sessionToken, credentialId, true);
  release();
  await assert.rejects(inFlight,
    (error) => error instanceof AuthorityError && error.code === 'authorization_failed');
  assert.equal(dbOpenCounter(path, credentialId), 1);
});
