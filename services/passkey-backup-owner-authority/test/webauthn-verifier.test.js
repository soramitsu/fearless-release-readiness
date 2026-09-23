import assert from 'node:assert/strict';
import { randomBytes } from 'node:crypto';
import test from 'node:test';
import {
  authenticationCredential, createAuthenticator, registrationCredential,
} from '../../passkey-backup-challenge-service/test/webauthn-fixture.js';
import { AuthorityError } from '../src/validation.js';
import { createWebAuthnVerifier } from '../src/webauthn-verifier.js';

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
    clientExtensionResults: source.clientExtensionResults,
    response: {
      clientDataJSON: source.response.clientDataJSON,
      attestationObject: source.response.attestationObject,
    },
  };
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
