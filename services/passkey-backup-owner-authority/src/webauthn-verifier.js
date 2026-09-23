import {
  verifyAuthenticationResponse,
  verifyRegistrationResponse,
} from '@simplewebauthn/server';
import {
  RP_ID, backupFlags, base64, counter, credentialRecord, credentialResponse, deny,
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

/**
 * Real WebAuthn verification for existing-owner authentication and enrollment.
 * First-owner bootstrap remains unavailable until wallet possession, app
 * attestation, and legacy-owner migration have a reviewed atomic integration.
 */
export function createWebAuthnVerifier({ allowedOrigins } = {}) {
  const origins = configuredOrigins(allowedOrigins);
  return Object.freeze({
    async bootstrap() { deny('verifier_unavailable'); },
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
