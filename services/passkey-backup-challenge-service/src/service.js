import { createHash, randomBytes as cryptoRandomBytes } from 'node:crypto';
import {
  verifyAuthenticationResponse,
  verifyRegistrationResponse,
} from '@simplewebauthn/server';
import { base64UrlEncode } from './base64url.js';
import { serviceError } from './errors.js';
import { createPasskeyChallengeStore } from './store.js';
import {
  RP_ID,
  SCHEMA_VERSION,
  SERVICE_ID,
  parseAllowedOrigins,
  validateAccountName,
  validateClientDataJSON,
  validateCredentialId,
  validateCredentialResponse,
  validateDisplayName,
  validateExactObject,
  validateIdentifier,
  validateRpId,
  validateSchemaVersion,
} from './validation.js';

function sha256Base64Url(value) {
  return createHash('sha256').update(value).digest('base64url');
}

function defaultRandomBytes(size) {
  return cryptoRandomBytes(size);
}

function randomToken(prefix, randomBytes) {
  return `${prefix}:${base64UrlEncode(randomBytes(32))}`;
}

function storageKeyFor(walletId, accountName) {
  return `storage:${sha256Base64Url(`${walletId}\0${accountName.toLowerCase()}`)}`;
}

function userIdFor(storageKey) {
  return sha256Base64Url(`user\0${storageKey}`);
}

function challenge(randomBytes) {
  return base64UrlEncode(randomBytes(32));
}

const AUTHORIZATION_SUBJECT_HASH_RE = /^[A-Za-z0-9_-]{43}$/;
const AUTHORIZATION_PLATFORMS = new Set(['android', 'ios']);
const INSECURE_TEST_AUTHORIZATION = Object.freeze({
  subjectHash: sha256Base64Url('authorization-subject\0local-test-wallet-owner'),
  platform: 'android',
});

function allowedOriginsForPlatform(allowedOrigins, platform) {
  const isAndroidOrigin = (origin) => origin.startsWith('android:apk-key-hash:');
  return new Set(
    [...allowedOrigins].filter((origin) => (
      platform === 'android' ? isAndroidOrigin(origin) : !isAndroidOrigin(origin)
    )),
  );
}

function requireCurrentAuthorization(authorization, allowInsecureTestAuthorization, now) {
  if (authorization.expiresAt === undefined && allowInsecureTestAuthorization) return;
  if (!Number.isSafeInteger(authorization.expiresAt) ||
      authorization.expiresAt <= Math.floor(now() / 1000)) {
    throw serviceError(401, 'request_authorization_failed', 'Request authorization failed');
  }
}

function validateAuthorizationContext(authorization, allowInsecureTestAuthorization, now) {
  if (authorization === undefined && allowInsecureTestAuthorization) {
    return INSECURE_TEST_AUTHORIZATION;
  }
  if (authorization === null || typeof authorization !== 'object' || Array.isArray(authorization) ||
      !AUTHORIZATION_SUBJECT_HASH_RE.test(authorization.subjectHash) ||
      !AUTHORIZATION_PLATFORMS.has(authorization.platform)) {
    throw serviceError(401, 'request_authorization_failed', 'Request authorization failed');
  }
  requireCurrentAuthorization(authorization, allowInsecureTestAuthorization, now);
  return authorization;
}

function webAuthnVerificationError() {
  return serviceError(400, 'webauthn_verification_failed', 'WebAuthn response verification failed');
}

async function verifyWebAuthn(verify) {
  try {
    const result = await verify();
    if (!result?.verified) {
      throw new Error('WebAuthn verification returned false');
    }
    return result;
  } catch (error) {
    if (error?.code && error?.status) {
      throw error;
    }
    throw webAuthnVerificationError();
  }
}

export function createPasskeyBackupChallengeService({
  store = createPasskeyChallengeStore(),
  allowedOrigins = parseAllowedOrigins(),
  randomBytes = defaultRandomBytes,
  allowInsecureTestAuthorization = false,
  now = () => Date.now(),
} = {}) {
  if (allowInsecureTestAuthorization && process.env.NODE_ENV === 'production') {
    throw new Error('Insecure test authorization cannot be enabled in production');
  }
  if (typeof now !== 'function') throw new Error('now must be a function');
  return {
    health() {
      return {
        ok: true,
        service: SERVICE_ID,
        rpId: RP_ID,
        schemaVersion: SCHEMA_VERSION,
      };
    },

    createRegistrationChallenge(request, authorizationContext) {
      const authorization = validateAuthorizationContext(
        authorizationContext,
        allowInsecureTestAuthorization,
        now,
      );
      validateExactObject(
        request,
        ['walletId', 'accountName', 'displayName', 'rpId', 'schemaVersion'],
        [],
        'registration challenge request',
      );

      const walletId = validateIdentifier(request.walletId, 'walletId');
      const accountName = validateAccountName(request.accountName);
      const displayName = validateDisplayName(request.displayName);
      validateRpId(request.rpId);
      validateSchemaVersion(request.schemaVersion);

      const storageKey = storageKeyFor(walletId, accountName);
      if (store.hasStorageOwner(storageKey) &&
          !store.isStorageOwner(storageKey, authorization.subjectHash)) {
        throw serviceError(403, 'request_authorization_failed', 'Request authorization failed');
      }
      const registration = {
        registrationId: randomToken('reg', randomBytes),
        challenge: challenge(randomBytes),
        userId: userIdFor(storageKey),
        userName: accountName,
        displayName,
        storageKey,
        rpId: RP_ID,
        schemaVersion: SCHEMA_VERSION,
      };

      store.createRegistration({
        ...registration,
        walletId,
        accountName,
        authorizationSubjectHash: authorization.subjectHash,
        authorizationPlatform: authorization.platform,
        credentialMutationVersion: store.storageMutationVersion(
          storageKey,
          authorization.subjectHash,
        ),
      });

      return registration;
    },

    async completeRegistration(request, authorizationContext) {
      const authorization = validateAuthorizationContext(
        authorizationContext,
        allowInsecureTestAuthorization,
        now,
      );
      validateExactObject(request, ['registrationId', 'rpId', 'credential'], [], 'registration complete request');
      const registrationId = validateIdentifier(request.registrationId, 'registrationId');
      validateRpId(request.rpId);

      // Claim before any asynchronous cryptographic work so concurrent replays
      // cannot verify the same one-time ceremony twice.
      const pending = store.consumeRegistration(registrationId, authorization);
      try {
        const platformAllowedOrigins = allowedOriginsForPlatform(
          allowedOrigins,
          pending.authorizationPlatform,
        );
        const credential = validateCredentialResponse(request.credential, 'registration');
        validateClientDataJSON(
          credential.response.clientDataJSON,
          'webauthn.create',
          pending.challenge,
          platformAllowedOrigins,
        );

        const verification = await verifyWebAuthn(() => verifyRegistrationResponse({
          response: credential,
          expectedChallenge: pending.challenge,
          expectedOrigin: [...platformAllowedOrigins],
          expectedRPID: RP_ID,
          requireUserPresence: true,
          requireUserVerification: true,
          supportedAlgorithmIDs: [-7, -257],
        }));
        const { registrationInfo } = verification;
        if (!registrationInfo || registrationInfo.credential.id !== credential.id ||
            registrationInfo.rpID !== RP_ID || !registrationInfo.userVerified) {
          throw webAuthnVerificationError();
        }

        // A one-use grant can expire while the WebAuthn verifier is awaiting
        // cryptographic work. Never commit a credential under expired authority.
        requireCurrentAuthorization(authorization, allowInsecureTestAuthorization, now);
        store.registerCredential(pending.storageKey, {
          id: registrationInfo.credential.id,
          publicKey: registrationInfo.credential.publicKey,
          userId: pending.userId,
          counter: registrationInfo.credential.counter,
          transports: registrationInfo.credential.transports,
          deviceType: registrationInfo.credentialDeviceType,
          backedUp: registrationInfo.credentialBackedUp,
          aaguid: registrationInfo.aaguid,
          registrationPlatform: authorization.platform,
          ownerSubjectHash: authorization.subjectHash,
        }, pending.credentialMutationVersion);

        return {
          storageKey: pending.storageKey,
          rpId: RP_ID,
          schemaVersion: SCHEMA_VERSION,
        };
      } finally {
        store.releaseRegistration(pending.storageKey, pending.authorizationSubjectHash);
      }
    },

    createAssertionChallenge(request, authorizationContext) {
      const authorization = validateAuthorizationContext(
        authorizationContext,
        allowInsecureTestAuthorization,
        now,
      );
      validateExactObject(request, ['storageKey', 'rpId', 'schemaVersion'], ['credentialId'], 'assertion challenge request');
      const storageKey = validateIdentifier(request.storageKey, 'storageKey');
      validateRpId(request.rpId);
      validateSchemaVersion(request.schemaVersion);

      if (!store.hasAnyCredential(storageKey)) {
        throw serviceError(404, 'credential_not_registered', 'No passkey credential is registered for this storageKey');
      }
      if (!store.isStorageOwner(storageKey, authorization.subjectHash)) {
        throw serviceError(403, 'request_authorization_failed', 'Request authorization failed');
      }
      // A credential-directed ceremony may omit userHandle under WebAuthn. Bind
      // the exact allowCredentials ID before issuing its one-use challenge.
      const credentialId = request.credentialId === undefined
        ? undefined : validateCredentialId(request.credentialId);
      if (credentialId !== undefined) store.getCredential(storageKey, credentialId);

      const assertion = {
        assertionId: randomToken('assert', randomBytes),
        challenge: challenge(randomBytes),
        storageKey,
        ...(credentialId === undefined ? {} : { credentialId }),
        rpId: RP_ID,
        schemaVersion: SCHEMA_VERSION,
      };

      store.createAssertion({
        ...assertion,
        authorizationSubjectHash: authorization.subjectHash,
        authorizationPlatform: authorization.platform,
      });
      return assertion;
    },

    async completeAssertion(request, authorizationContext) {
      const authorization = validateAuthorizationContext(
        authorizationContext,
        allowInsecureTestAuthorization,
        now,
      );
      validateExactObject(request, ['assertionId', 'rpId', 'credential'], [], 'assertion complete request');
      const assertionId = validateIdentifier(request.assertionId, 'assertionId');
      validateRpId(request.rpId);

      const pending = store.consumeAssertion(assertionId, authorization);
      const platformAllowedOrigins = allowedOriginsForPlatform(
        allowedOrigins,
        pending.authorizationPlatform,
      );
      const credential = validateCredentialResponse(request.credential, 'authentication', {
        allowNullUserHandle: pending.credentialId !== undefined,
      });
      if (pending.credentialId !== undefined && credential.id !== pending.credentialId) {
        throw serviceError(403, 'credential_not_registered', 'Credential is not registered for this challenge');
      }
      const registeredCredential = store.getCredential(pending.storageKey, credential.id);
      if (credential.response.userHandle !== null &&
          credential.response.userHandle !== registeredCredential.userId) {
        throw serviceError(403, 'credential_user_mismatch', 'Credential userHandle does not match this storageKey');
      }

      validateClientDataJSON(
        credential.response.clientDataJSON,
        'webauthn.get',
        pending.challenge,
        platformAllowedOrigins,
      );
      const verification = await verifyWebAuthn(() => verifyAuthenticationResponse({
        response: credential,
        expectedChallenge: pending.challenge,
        expectedOrigin: [...platformAllowedOrigins],
        expectedRPID: RP_ID,
        credential: {
          id: registeredCredential.id,
          publicKey: registeredCredential.publicKey,
          counter: registeredCredential.counter,
          transports: registeredCredential.transports,
        },
        requireUserVerification: true,
      }));
      const { authenticationInfo } = verification;
      if (authenticationInfo.credentialID !== credential.id ||
          authenticationInfo.rpID !== RP_ID || !authenticationInfo.userVerified) {
        throw webAuthnVerificationError();
      }
      requireCurrentAuthorization(authorization, allowInsecureTestAuthorization, now);
      store.updateCredentialAfterAuthentication(pending.storageKey, credential.id, {
        newCounter: authenticationInfo.newCounter,
        deviceType: authenticationInfo.credentialDeviceType,
        backedUp: authenticationInfo.credentialBackedUp,
      });

      return {
        storageKey: pending.storageKey,
        rpId: RP_ID,
        schemaVersion: SCHEMA_VERSION,
      };
    },

    listCredentials(request, authorizationContext) {
      const authorization = validateAuthorizationContext(
        authorizationContext,
        allowInsecureTestAuthorization,
        now,
      );
      validateExactObject(request, ['storageKey', 'rpId', 'schemaVersion'], [], 'credential list request');
      const storageKey = validateIdentifier(request.storageKey, 'storageKey');
      validateRpId(request.rpId);
      validateSchemaVersion(request.schemaVersion);

      return {
        storageKey,
        credentials: store.listCredentials(storageKey, authorization.subjectHash),
        rpId: RP_ID,
        schemaVersion: SCHEMA_VERSION,
      };
    },

    revokeCredential(request, authorizationContext) {
      const authorization = validateAuthorizationContext(
        authorizationContext,
        allowInsecureTestAuthorization,
        now,
      );
      validateExactObject(
        request,
        ['storageKey', 'credentialId', 'rpId', 'schemaVersion'],
        ['confirmFinalRecoveryRemoval'],
        'credential revoke request',
      );
      if (request.confirmFinalRecoveryRemoval !== undefined && request.confirmFinalRecoveryRemoval !== true) {
        throw serviceError(400, 'invalid_request', 'Final recovery route confirmation must be true');
      }
      const storageKey = validateIdentifier(request.storageKey, 'storageKey');
      const credentialId = validateCredentialId(request.credentialId);
      validateRpId(request.rpId);
      validateSchemaVersion(request.schemaVersion);
      const result = store.revokeCredential(storageKey, credentialId, authorization.subjectHash,
        request.confirmFinalRecoveryRemoval === true);

      return {
        storageKey,
        credentialId,
        remainingCredentials: result.remainingCredentials,
        rpId: RP_ID,
        schemaVersion: SCHEMA_VERSION,
      };
    },

    revokeAllCredentials(request, authorizationContext) {
      const authorization = validateAuthorizationContext(
        authorizationContext,
        allowInsecureTestAuthorization,
        now,
      );
      validateExactObject(request, ['storageKey', 'rpId', 'schemaVersion'], ['confirmFinalRecoveryRemoval'], 'credential revoke-all request');
      if (request.confirmFinalRecoveryRemoval !== undefined && request.confirmFinalRecoveryRemoval !== true) {
        throw serviceError(400, 'invalid_request', 'Final recovery route confirmation must be true');
      }
      const storageKey = validateIdentifier(request.storageKey, 'storageKey');
      validateRpId(request.rpId);
      validateSchemaVersion(request.schemaVersion);
      const result = store.revokeAllCredentials(storageKey, authorization.subjectHash,
        request.confirmFinalRecoveryRemoval === true);

      return {
        storageKey,
        remainingCredentials: result.remainingCredentials,
        rpId: RP_ID,
        schemaVersion: SCHEMA_VERSION,
      };
    },
  };
}
