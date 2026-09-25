import assert from 'node:assert/strict';
import { ECDH, generateKeyPairSync, randomBytes, sign } from 'node:crypto';
import { readFileSync } from 'node:fs';
import { DatabaseSync } from 'node:sqlite';
import test from 'node:test';
import {
  authenticationCredential, createAuthenticator, registrationCredential,
} from '../../passkey-backup-challenge-service/test/webauthn-fixture.js';
import { AuthorityError, hash } from '../src/validation.js';
import { bootstrapWalletMessage, verifyBootstrapWalletProof } from '../src/bootstrap-proof.js';
import { createPlayIntegrityBootstrapVerifier } from '../src/play-integrity-admission.js';
import { createWebAuthnVerifier } from '../src/webauthn-verifier.js';
import { appAttestation, audience, b64, proof, register, setup, verifier as fakeVerifier } from './fixtures.js';

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
      credential: register(), walletProof: proof, appAttestation: appAttestation(platform) });
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

function signedWalletProof(ceremony, credential, scheme = 'ed25519') {
  const pair = scheme === 'ed25519' ? generateKeyPairSync('ed25519')
    : generateKeyPairSync('ec', { namedCurve: 'secp256k1' });
  const spki = pair.publicKey.export({ type: 'spki', format: 'der' });
  const key = spki.subarray(scheme === 'ed25519' ? -32 : -65);
  const message = bootstrapWalletMessage(ceremony, credential);
  const signature = scheme === 'ed25519' ? sign(null, message, pair.privateKey)
    : sign('sha256', message, { key: pair.privateKey, dsaEncoding: 'ieee-p1363' });
  return { scheme, publicKey: key.toString('base64url'), signature: signature.toString('base64url') };
}
const bootstrapAdmission = (verifyAppAttestation) => ({
  android: { packageName: 'io.soramitsu.fearless', signingCertificateSha256: 'a5'.repeat(32) },
  ios: { teamId: 'ABCDE12345', bundleId: 'io.soramitsu.fearless' },
  verifyAppAttestation,
});

test('first owner commits only after signed local wallet, bound app attestation and real WebAuthn registration', async (t) => {
  let appChecks = 0;
  const admitted = createWebAuthnVerifier({
    allowedOrigins: { android: [androidOrigin], ios: [iosOrigin] },
    // Test double only: a real server adapter must verify Apple's App Attest
    // certificate/receipt and nonce against the configured Team/bundle ID.
    bootstrapAdmission: bootstrapAdmission(async ({ platform, expectedNonce, expectedApplication, attestation }) => {
      appChecks++;
      assert.equal(platform, 'ios');
      assert.equal(attestation.kind, 'app-attest');
      return { platform, nonce: expectedNonce, application: expectedApplication };
    }),
  });
  const { core, path } = setup(t, { verifier: admitted });
  const pending = core.beginBootstrap('ios');
  const authenticator = createAuthenticator('bootstrap-owner');
  const credential = publicRegistration(registrationCredential(pending.challenge, authenticator, { origin: iosOrigin }));
  const walletProof = signedWalletProof(pending, credential);
  const result = await core.completeBootstrap({ ceremonyId: pending.ceremonyId, credential,
    walletProof, appAttestation: appAttestation('ios') });
  assert.equal(result.subject, pending.subject);
  assert.equal(appChecks, 1);
  const stored = new DatabaseSync(path, { readOnly: true });
  try {
    assert.equal(stored.prepare('SELECT wallet_binding FROM owners WHERE subject=?').get(result.subject).wallet_binding,
      verifyBootstrapWalletProof(pending, credential, walletProof).walletBindingHash);
    assert.equal(stored.prepare('SELECT count(*) AS n FROM credentials WHERE owner=?').get(result.subject).n, 1);
  } finally { stored.close(); }
  const duplicate = core.beginBootstrap('ios');
  const newCredential = publicRegistration(registrationCredential(duplicate.challenge,
    createAuthenticator('bootstrap-owner'), { origin: iosOrigin }));
  await assert.rejects(core.completeBootstrap({ ceremonyId: duplicate.ceremonyId, credential: newCredential,
    walletProof: signedWalletProof(duplicate, newCredential), appAttestation: appAttestation('ios') }),
  (error) => error.code === 'credential_already_linked');
});

test('Android first-owner ceremony composes wallet proof, Google verdict and WebAuthn', async () => {
  const pending = ceremony('bootstrap', 'android');
  const credential = publicRegistration(registrationCredential(pending.challenge,
    createAuthenticator('play-bootstrap'), { origin: androidOrigin }));
  const walletProof = signedWalletProof(pending, credential);
  const boundNonce = verifyBootstrapWalletProof(pending, credential, walletProof).attestationNonce;
  const now = 1_797_000_000_000;
  const play = createPlayIntegrityBootstrapVerifier({
    packageName: 'io.soramitsu.fearless', signingCertificateSha256: 'a5'.repeat(32),
    allowedVersionCodes: ['420'], getAccessToken: async () => 'ya29.test_access_token',
    now: () => now,
    fetchImpl: async () => Response.json({ tokenPayloadExternal: {
      requestDetails: { requestPackageName: 'io.soramitsu.fearless', requestHash: boundNonce,
        timestampMillis: String(now) },
      appIntegrity: { appRecognitionVerdict: 'PLAY_RECOGNIZED',
        packageName: 'io.soramitsu.fearless',
        certificateSha256Digest: [Buffer.alloc(32, 0xa5).toString('base64url')], versionCode: '420' },
      accountDetails: { appLicensingVerdict: 'LICENSED' },
      deviceIntegrity: { deviceRecognitionVerdict: ['MEETS_DEVICE_INTEGRITY'] },
    } }),
  });
  const admitted = createWebAuthnVerifier({
    allowedOrigins: { android: [androidOrigin], ios: [iosOrigin] },
    bootstrapAdmission: bootstrapAdmission(play),
  });
  const result = await admitted.bootstrap({ ceremony: pending, credential, walletProof,
    appAttestation: appAttestation('android') });
  assert.equal(result.walletBindingHash,
    verifyBootstrapWalletProof(pending, credential, walletProof).walletBindingHash);
  assert.equal(result.credential.userHandle, pending.userHandle);
});

test('wallet bootstrap message binds owner, namespace, nonce and every public registration field', () => {
  const pending = ceremony('bootstrap', 'ios');
  const credential = publicRegistration(registrationCredential(pending.challenge,
    createAuthenticator('message-binding'), { origin: iosOrigin }));
  const wallet = signedWalletProof(pending, credential);
  const baseline = verifyBootstrapWalletProof(pending, credential, wallet);
  assert.match(baseline.walletBindingHash, /^[A-Za-z0-9_-]{43}$/);
  for (const changed of [
    { ceremony: { ...pending, subject: ceremony('bootstrap', 'ios').subject }, credential },
    { ceremony: { ...pending, namespace: ceremony('bootstrap', 'ios').namespace }, credential },
    { ceremony: { ...pending, challenge: randomBytes(32).toString('base64url') }, credential },
    { ceremony: pending, credential: { ...credential, response: {
      ...credential.response, attestationObject: b64(99, 64),
    } } },
  ]) {
    assert.throws(() => verifyBootstrapWalletProof(changed.ceremony, changed.credential, wallet),
      (error) => error.code === 'verification_failed');
  }
  assert.throws(() => verifyBootstrapWalletProof(pending, credential,
    { ...wallet, scheme: 'sr25519' }), (error) => error.code === 'verifier_unavailable');
});

test('secp256k1 wallet proof accepts both public-key encodings under one owner binding', () => {
  const pending = ceremony('bootstrap', 'android');
  const credential = publicRegistration(registrationCredential(pending.challenge,
    createAuthenticator('secp-binding'), { origin: androidOrigin }));
  const wallet = signedWalletProof(pending, credential, 'secp256k1');
  const compressed = ECDH.convertKey(Buffer.from(wallet.publicKey, 'base64url'),
    'secp256k1', undefined, undefined, 'compressed').toString('base64url');
  const full = verifyBootstrapWalletProof(pending, credential, wallet);
  const compact = verifyBootstrapWalletProof(pending, credential, { ...wallet, publicKey: compressed });
  assert.equal(full.walletBindingHash, compact.walletBindingHash);
  assert.equal(full.attestationNonce, compact.attestationNonce);
});

test('published Android Play Integrity request hashes match valid server wallet proofs', () => {
  const vectors = JSON.parse(readFileSync(
    new URL('./bootstrap-play-integrity-vectors.json', import.meta.url), 'utf8'));
  const { ceremony: pending, credential } = vectors;
  assert.equal(bootstrapWalletMessage(pending, credential).toString('base64url'),
    vectors.walletMessage);
  for (const { requestHash, ...wallet } of vectors.proofs) {
    assert.equal(verifyBootstrapWalletProof(pending, credential, wallet).attestationNonce,
      requestHash);
  }
  const secp = vectors.proofs.find((proof) => proof.scheme === 'secp256k1');
  const compressed = ECDH.convertKey(Buffer.from(secp.publicKey, 'base64url'),
    'secp256k1', undefined, undefined, 'compressed').toString('base64url');
  assert.equal(verifyBootstrapWalletProof(pending, credential,
    { scheme: secp.scheme, publicKey: compressed, signature: secp.signature }).attestationNonce,
  secp.requestHash);
});

test('first-owner attestation result must match nonce, platform and configured app identity', async () => {
  const pending = ceremony('bootstrap', 'android');
  const credential = publicRegistration(registrationCredential(pending.challenge,
    createAuthenticator('app-bound'), { origin: androidOrigin }));
  const walletProof = signedWalletProof(pending, credential);
  const input = { ceremony: pending, credential, walletProof, appAttestation: appAttestation() };
  for (const result of [true, { platform: 'android', nonce: b64(2), application: 'android:wrong' },
    { platform: 'ios', nonce: verifyBootstrapWalletProof(pending, credential, walletProof).attestationNonce,
      application: 'ios:wrong' }]) {
    const admitted = createWebAuthnVerifier({
      allowedOrigins: { android: [androidOrigin], ios: [iosOrigin] },
      bootstrapAdmission: bootstrapAdmission(async () => result),
    });
    await assert.rejects(admitted.bootstrap(input), (error) => error.code === 'verification_failed');
  }
  assert.throws(() => createWebAuthnVerifier({
    allowedOrigins: { android: [androidOrigin], ios: [iosOrigin] },
    bootstrapAdmission: { ...bootstrapAdmission(() => {}), verifyAppAttestation: true },
  }), (error) => error.code === 'invalid_configuration');
  assert.throws(() => createWebAuthnVerifier({
    allowedOrigins: { android: [androidOrigin], ios: [iosOrigin] },
    bootstrapAdmission: { ...bootstrapAdmission(async () => {}),
      android: { ...bootstrapAdmission(async () => {}).android,
        signingCertificateSha256: '00'.repeat(32) } },
  }), (error) => error.code === 'invalid_configuration');
  let attestations = 0;
  const admitted = createWebAuthnVerifier({
    allowedOrigins: { android: [androidOrigin], ios: [iosOrigin] },
    bootstrapAdmission: bootstrapAdmission(async ({ platform, expectedNonce, expectedApplication }) => {
      attestations++;
      return { platform, nonce: expectedNonce, application: expectedApplication };
    }),
  });
  await assert.rejects(admitted.bootstrap({ ...input, walletProof: {
    ...walletProof, signature: b64(99, 64),
  } }), (error) => error.code === 'verification_failed');
  assert.equal(attestations, 0);
  const wrongOrigin = publicRegistration(registrationCredential(pending.challenge,
    createAuthenticator('wrong-bootstrap-origin'), { origin: 'https://evil.example' }));
  await assert.rejects(admitted.bootstrap({ ...input, credential: wrongOrigin,
    walletProof: signedWalletProof(pending, wrongOrigin) }),
  (error) => error.code === 'verification_failed');
  assert.equal(attestations, 1);
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
