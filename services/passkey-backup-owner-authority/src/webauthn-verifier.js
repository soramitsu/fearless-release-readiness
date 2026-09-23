import {
  verifyAuthenticationResponse,
  verifyRegistrationResponse,
} from '@simplewebauthn/server';
import {
  RP_ID, backupFlags, base64, counter, credentialRecord, credentialResponse, deny, exact, opaque,
} from './validation.js';

const IOS_ORIGINS = new Set([
  'https://fearlesswallet.io',
  'https://backup.fearlesswallet.io',
]);
const ANDROID_ORIGIN = /^android:apk-key-hash:[A-Za-z0-9_-]{43}$/u;

function configuredOrigins(value) {
  if (!value || Object.getPrototypeOf(value) !== Object.prototype ||
      Object.keys(value).sort().join(',') !== 'android,ios') deny('invalid_configuration');
  const result = {};
  for (const platform of ['android', 'ios']) {
    const origins = value[platform];
    if (!Array.isArray(origins) || origins.length === 0 || origins.length > 4 ||
        new Set(origins).size !== origins.length) deny('invalid_configuration');
    for (const origin of origins) {
      if (typeof origin !== 'string' ||
          (platform === 'ios' && !IOS_ORIGINS.has(origin)) ||
          (platform === 'android' && (!ANDROID_ORIGIN.test(origin) ||
            Buffer.from(origin.slice('android:apk-key-hash:'.length), 'base64url').toString('base64url') !==
              origin.slice('android:apk-key-hash:'.length)))) deny('invalid_configuration');
    }
    result[platform] = Object.freeze([...origins]);
  }
  return Object.freeze(result);
}

function ceremonyFor(input, kind) {
  const ceremony = input?.ceremony;
  if (!ceremony || ceremony.kind !== kind || ceremony.rpId !== RP_ID ||
      !['android', 'ios'].includes(ceremony.platform) ||
      typeof ceremony.challenge !== 'string' ||
      typeof ceremony.userHandle !== 'string') deny('verification_failed');
  base64(ceremony.challenge, 32, 32);
  base64(ceremony.userHandle, 32, 32);
  return ceremony;
}

function registrationRecord(info, response, userHandle) {
  if (!info || info.rpID !== RP_ID || !info.userVerified ||
      info.credential?.id !== response.id) deny('verification_failed');
  const record = {
    id: info.credential.id,
    publicKey: Buffer.from(info.credential.publicKey).toString('base64url'),
    userHandle,
    counter: info.credential.counter,
    deviceType: info.credentialDeviceType,
    backedUp: info.credentialBackedUp,
  };
  return credentialRecord(record, response.id, userHandle);
}

function claimedChallenge(input, kind) {
  exact(input, ['ceremony', 'credential']);
  const ceremony = input.ceremony;
  exact(ceremony, ['challengeId', 'kind', 'challenge', 'rpId', 'platform', 'userHandle',
    'directedCredentialId', 'credentialId', 'registeredCredential', 'expiresAt']);
  opaque(ceremony.challengeId, 'pending.');
  if (ceremony.kind !== kind || ceremony.rpId !== RP_ID ||
      !['android', 'ios'].includes(ceremony.platform) ||
      (ceremony.directedCredentialId !== null && typeof ceremony.directedCredentialId !== 'string') ||
      !Number.isSafeInteger(ceremony.expiresAt) || ceremony.expiresAt < 0) deny('verification_failed');
  base64(ceremony.challenge, 32, 32);
  base64(ceremony.userHandle, 32, 32);
  base64(ceremony.credentialId, 1, 384);
  if (ceremony.directedCredentialId !== null) base64(ceremony.directedCredentialId, 1, 384);
  if (kind === 'registration' &&
      (ceremony.directedCredentialId !== null || ceremony.registeredCredential !== null)) deny('verification_failed');
  if (kind === 'assertion' && !ceremony.registeredCredential) deny('verification_failed');
  return ceremony;
}

/**
 * Real WebAuthn verification for existing-owner authentication and enrollment.
 * First-owner bootstrap remains unavailable until wallet possession, app
 * attestation, and legacy-owner migration have a reviewed atomic integration.
 */
export function createWebAuthnVerifier({ allowedOrigins } = {}) {
  const origins = configuredOrigins(allowedOrigins);
  return Object.freeze({
    async bootstrap() { deny('verifier_unavailable'); },
    // These are server-only adapters for a claim returned by the SQLite core.
    // The core's orchestration path owns the claim and commits the evidence;
    // calling this adapter directly does not establish an owner or authority.
    async challengeRegistration(input) {
      const ceremony = claimedChallenge(input, 'registration');
      const response = credentialResponse(input.credential, 'registration');
      if (response.id !== ceremony.credentialId) deny('verification_failed');
      try {
        const result = await verifyRegistrationResponse({
          response,
          expectedChallenge: ceremony.challenge,
          expectedOrigin: origins[ceremony.platform],
          expectedRPID: RP_ID,
          requireUserPresence: true,
          requireUserVerification: true,
          supportedAlgorithmIDs: [-7, -257],
        });
        const info = result?.registrationInfo;
        if (!result?.verified || !info || typeof info.aaguid !== 'string' ||
            !/^[a-f0-9]{8}-(?:[a-f0-9]{4}-){3}[a-f0-9]{12}$/.test(info.aaguid)) deny('verification_failed');
        const record = registrationRecord(info, response, ceremony.userHandle);
        const transports = response.response.transports;
        return Object.freeze({ challengeNonce: ceremony.challenge, platform: ceremony.platform,
          credential: Object.freeze(record), aaguid: info.aaguid,
          transportsJson: transports === undefined ? null : JSON.stringify(transports) });
      } catch { deny('verification_failed'); }
    },
    async challengeAssertion(input) {
      const ceremony = claimedChallenge(input, 'assertion');
      const response = credentialResponse(input.credential, 'authentication', { allowNullUserHandle: true });
      const registered = credentialRecord(ceremony.registeredCredential, response.id, ceremony.userHandle);
      if (response.id !== ceremony.credentialId ||
          (response.response.userHandle === null
            ? ceremony.directedCredentialId !== response.id
            : response.response.userHandle !== registered.userHandle)) deny('verification_failed');
      const authenticatorData = Buffer.from(response.response.authenticatorData, 'base64url');
      if ((authenticatorData[32] & 0x05) !== 0x05) deny('verification_failed');
      try {
        const result = await verifyAuthenticationResponse({
          response,
          expectedChallenge: ceremony.challenge,
          expectedOrigin: origins[ceremony.platform],
          expectedRPID: RP_ID,
          credential: {
            id: registered.id,
            publicKey: Buffer.from(registered.publicKey, 'base64url'),
            counter: registered.counter,
          },
          requireUserVerification: true,
        });
        const info = result?.authenticationInfo;
        if (!result?.verified || !info || info.credentialID !== registered.id ||
            info.rpID !== RP_ID || !info.userVerified ||
            info.credentialDeviceType !== registered.deviceType) deny('verification_failed');
        const evidence = { challengeNonce: ceremony.challenge, platform: ceremony.platform,
          expectedCounter: registered.counter, newCounter: info.newCounter,
          deviceType: info.credentialDeviceType, backedUp: info.credentialBackedUp };
        counter(evidence.newCounter);
        backupFlags(evidence);
        return Object.freeze(evidence);
      } catch { deny('verification_failed'); }
    },
    async enrollment(input) {
      const ceremony = ceremonyFor(input, 'enrollment');
      const response = credentialResponse(input.credential, 'registration');
      try {
        const result = await verifyRegistrationResponse({
          response,
          expectedChallenge: ceremony.challenge,
          expectedOrigin: origins[ceremony.platform],
          expectedRPID: RP_ID,
          requireUserPresence: true,
          requireUserVerification: true,
          supportedAlgorithmIDs: [-7, -257],
        });
        if (!result?.verified) deny('verification_failed');
        return { credential: registrationRecord(result.registrationInfo, response, ceremony.userHandle) };
      } catch {
        deny('verification_failed');
      }
    },
    async authentication(input) {
      const ceremony = ceremonyFor(input, 'authentication');
      const response = credentialResponse(input.credential, 'authentication');
      const registered = credentialRecord(
        input.registeredCredential,
        response.id,
        ceremony.userHandle,
      );
      if (response.response.userHandle !== registered.userHandle) deny('verification_failed');
      const authenticatorData = Buffer.from(response.response.authenticatorData, 'base64url');
      if ((authenticatorData[32] & 0x05) !== 0x05) deny('verification_failed');
      try {
        const result = await verifyAuthenticationResponse({
          response,
          expectedChallenge: ceremony.challenge,
          expectedOrigin: origins[ceremony.platform],
          expectedRPID: RP_ID,
          credential: {
            id: registered.id,
            publicKey: Buffer.from(registered.publicKey, 'base64url'),
            counter: registered.counter,
          },
          requireUserVerification: true,
        });
        const info = result?.authenticationInfo;
        if (!result?.verified || !info || info.credentialID !== registered.id ||
            info.rpID !== RP_ID || !info.userVerified ||
            info.credentialDeviceType !== registered.deviceType) deny('verification_failed');
        const evidence = {
          credentialId: info.credentialID,
          newCounter: info.newCounter,
          deviceType: info.credentialDeviceType,
          backedUp: info.credentialBackedUp,
        };
        counter(evidence.newCounter);
        backupFlags(evidence);
        return evidence;
      } catch {
        deny('verification_failed');
      }
    },
  });
}
