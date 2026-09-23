import { timingSafeEqual } from 'node:crypto';
import { base64UrlDecode, base64UrlDecodeToUtf8 } from './base64url.js';
import { serviceError } from './errors.js';

export const SERVICE_ID = 'fearless-passkey-backup';
export const RP_ID = 'fearlesswallet.io';
export const SCHEMA_VERSION = 1;

export const PATHS = Object.freeze({
  health: '/api/passkey-backup/v1/health',
  registrationChallenge: '/api/passkey-backup/v1/registration/challenge',
  registrationComplete: '/api/passkey-backup/v1/registration/complete',
  assertionChallenge: '/api/passkey-backup/v1/assertion/challenge',
  assertionComplete: '/api/passkey-backup/v1/assertion/complete',
  credentialsList: '/api/passkey-backup/v1/credentials/list',
  credentialsRevoke: '/api/passkey-backup/v1/credentials/revoke',
  credentialsRevokeAll: '/api/passkey-backup/v1/credentials/revoke-all',
});

const IDENTIFIER_RE = /^[A-Za-z0-9._:-]{8,128}$/;
const ACCOUNT_NAME_RE = /^[^\s@]+@[^\s@]+$/;
const AUTHENTICATOR_TRANSPORTS = new Set([
  'ble',
  'cable',
  'hybrid',
  'internal',
  'nfc',
  'smart-card',
  'usb',
]);
const CREDENTIAL_ATTACHMENTS = new Set(['platform', 'cross-platform']);
const SUPPORTED_CREDENTIAL_ALGORITHMS = new Set([-7, -257]);
const ANDROID_APK_ORIGIN_PREFIX = 'android:apk-key-hash:';
const ANDROID_APK_CERTIFICATE_DIGEST_BYTES = 32;
const ANDROID_APK_CERTIFICATE_DIGEST_ENCODED_LENGTH = 43;
const MAX_ALLOWED_ORIGINS = 16;

export function isPlainObject(value) {
  return value !== null && typeof value === 'object' && !Array.isArray(value);
}

export function parseAllowedOrigins(
  value = process.env.PASSKEY_ALLOWED_ORIGINS,
  {
    androidOrigin = process.env.PASSKEY_ANDROID_ALLOWED_ORIGIN,
    requireAndroidOrigin = process.env.NODE_ENV === 'production',
  } = {},
) {
  const defaults = ['https://fearlesswallet.io', 'https://backup.fearlesswallet.io'];
  let origins;
  if (value === undefined) {
    origins = [...defaults];
  } else if (typeof value !== 'string' || value.length === 0) {
    throw serviceError(500, 'invalid_service_config', 'PASSKEY_ALLOWED_ORIGINS must contain at least one origin');
  } else {
    origins = value.split(',');
  }

  if (androidOrigin !== undefined) {
    if (typeof androidOrigin !== 'string' || androidOrigin.length === 0) {
      throw serviceError(500, 'invalid_service_config', 'PASSKEY_ANDROID_ALLOWED_ORIGIN must be an Android APK origin');
    }
    origins.push(androidOrigin);
  }

  if (origins.length === 0 || origins.length > MAX_ALLOWED_ORIGINS) {
    throw serviceError(500, 'invalid_service_config', 'PASSKEY_ALLOWED_ORIGINS must contain at least one origin');
  }

  const normalizedOrigins = new Set();
  for (const origin of origins) {
    if (typeof origin !== 'string' || origin.length === 0 || origin !== origin.trim()) {
      throw serviceError(500, 'invalid_service_config', 'WebAuthn allowed origins must not be empty or contain surrounding whitespace');
    }
    const normalized = normalizeAllowedOrigin(origin);
    if (normalizedOrigins.has(normalized)) {
      throw serviceError(500, 'invalid_service_config', 'WebAuthn allowed origins must not contain duplicates');
    }
    normalizedOrigins.add(normalized);
  }

  if (requireAndroidOrigin &&
      ![...normalizedOrigins].some((origin) => origin.startsWith(ANDROID_APK_ORIGIN_PREFIX))) {
    throw serviceError(
      500,
      'invalid_service_config',
      'Production requires PASSKEY_ANDROID_ALLOWED_ORIGIN for the release signing certificate',
    );
  }

  return normalizedOrigins;
}

function normalizeAllowedOrigin(origin) {
  if (origin.startsWith(ANDROID_APK_ORIGIN_PREFIX)) {
    return normalizeAndroidApkOrigin(origin);
  }

  let url;
  try {
    url = new URL(origin);
  } catch (error) {
    throw serviceError(500, 'invalid_service_config', 'PASSKEY_ALLOWED_ORIGINS must contain valid origins');
  }

  if (url.username || url.password) {
    throw serviceError(500, 'invalid_service_config', 'PASSKEY_ALLOWED_ORIGINS must not contain credentials');
  }
  if (url.search || url.hash) {
    throw serviceError(500, 'invalid_service_config', 'PASSKEY_ALLOWED_ORIGINS must not contain query strings or fragments');
  }
  if (url.pathname !== '/') {
    throw serviceError(500, 'invalid_service_config', 'PASSKEY_ALLOWED_ORIGINS must not contain paths');
  }

  const isLocalhost = ['localhost', '127.0.0.1', '[::1]'].includes(url.hostname);
  if (url.protocol !== 'https:' && !(url.protocol === 'http:' && isLocalhost)) {
    throw serviceError(500, 'invalid_service_config', 'PASSKEY_ALLOWED_ORIGINS must use HTTPS outside localhost');
  }
  if (origin !== url.origin) {
    throw serviceError(500, 'invalid_service_config', 'PASSKEY_ALLOWED_ORIGINS must contain canonical origins');
  }

  return url.origin;
}

function normalizeAndroidApkOrigin(origin) {
  const digest = origin.slice(ANDROID_APK_ORIGIN_PREFIX.length);
  if (digest.length !== ANDROID_APK_CERTIFICATE_DIGEST_ENCODED_LENGTH) {
    throw serviceError(
      500,
      'invalid_service_config',
      'Android WebAuthn origin must contain an unpadded base64url SHA-256 signing-certificate digest',
    );
  }

  let decoded;
  try {
    decoded = base64UrlDecode(
      digest,
      'Android APK signing-certificate digest',
      ANDROID_APK_CERTIFICATE_DIGEST_ENCODED_LENGTH,
    );
  } catch (error) {
    throw serviceError(
      500,
      'invalid_service_config',
      'Android WebAuthn origin must contain an unpadded base64url SHA-256 signing-certificate digest',
    );
  }
  if (decoded.length !== ANDROID_APK_CERTIFICATE_DIGEST_BYTES) {
    throw serviceError(
      500,
      'invalid_service_config',
      'Android WebAuthn origin must contain an unpadded base64url SHA-256 signing-certificate digest',
    );
  }

  return origin;
}

export function validateExactObject(value, requiredFields, optionalFields = [], context = 'request') {
  if (!isPlainObject(value)) {
    throw serviceError(400, 'invalid_request', `${context} must be a JSON object`);
  }

  const allowed = new Set([...requiredFields, ...optionalFields]);
  for (const field of requiredFields) {
    if (!Object.prototype.hasOwnProperty.call(value, field)) {
      throw serviceError(400, 'invalid_request', `${context} missing required field ${field}`);
    }
  }

  for (const field of Object.keys(value)) {
    if (!allowed.has(field)) {
      throw serviceError(400, 'invalid_request', `${context} contains unsupported field ${field}`);
    }
  }
}

export function validateIdentifier(value, fieldName) {
  if (typeof value !== 'string' || value !== value.trim() || !IDENTIFIER_RE.test(value)) {
    throw serviceError(400, 'invalid_request', `${fieldName} must be 8-128 URL-safe characters`);
  }

  return value;
}

export function validateCredentialId(value) {
  if (typeof value !== 'string' || value.length === 0 || value.length > 512) {
    throw serviceError(400, 'invalid_request', 'credentialId must be a non-empty canonical base64url identifier');
  }
  try {
    const decoded = base64UrlDecode(value, 'credentialId', 512);
    if (decoded.length === 0) throw new Error('empty credentialId');
  } catch (error) {
    throw serviceError(400, 'invalid_request', 'credentialId must be a non-empty canonical base64url identifier');
  }
  return value;
}

export function validateAccountName(value) {
  if (typeof value !== 'string') {
    throw serviceError(400, 'invalid_request', 'accountName must be a string');
  }

  if (value !== value.trim() || value.length < 3 || value.length > 320 || !ACCOUNT_NAME_RE.test(value)) {
    throw serviceError(400, 'invalid_request', 'accountName must be email-shaped without whitespace');
  }

  return value;
}

export function validateDisplayName(value) {
  if (typeof value !== 'string') {
    throw serviceError(400, 'invalid_request', 'displayName must be a string');
  }

  const normalized = value.trim();
  if (normalized.length < 1 || normalized.length > 128) {
    throw serviceError(400, 'invalid_request', 'displayName must be 1-128 characters');
  }

  return normalized;
}

export function validateRpId(value) {
  if (value !== RP_ID) {
    throw serviceError(400, 'unsupported_rp_id', `Unsupported relying party id: ${value}`);
  }

  return value;
}

export function validateSchemaVersion(value) {
  if (value !== SCHEMA_VERSION) {
    throw serviceError(400, 'unsupported_schema_version', `Unsupported schemaVersion: ${value}`);
  }

  return value;
}

function invalidCredential(message) {
  throw serviceError(400, 'invalid_credential', message);
}

function validateBase64UrlBlob(value, fieldName, maxEncodedLength = 32768) {
  try {
    return base64UrlDecode(value, fieldName, maxEncodedLength);
  } catch (error) {
    invalidCredential(`${fieldName} must be canonical base64url`);
  }
}

function validateTransports(value) {
  if (value === undefined) {
    return undefined;
  }
  if (!Array.isArray(value) || value.length > AUTHENTICATOR_TRANSPORTS.size) {
    invalidCredential('credential.response.transports must be an array of supported transports');
  }
  const transports = [];
  for (const transport of value) {
    if (typeof transport !== 'string' || !AUTHENTICATOR_TRANSPORTS.has(transport)) {
      invalidCredential('credential.response.transports contains an unsupported transport');
    }
    if (transports.includes(transport)) {
      invalidCredential('credential.response.transports must not contain duplicates');
    }
    transports.push(transport);
  }
  return transports;
}

function validateServerExtensionResults(value) {
  // Native clients must extract PRF output into a local-only typed result before
  // serializing the credential. Do not accept arbitrary WebAuthn toJSON output:
  // PRF and large-blob extension results can contain wallet recovery material.
  // This is a second boundary, not a substitute for client-side sanitization.
  if (!isPlainObject(value) || Object.keys(value).some((key) => key !== 'credProps')) {
    invalidCredential('credential.clientExtensionResults contains unsupported extension data');
  }
  if (!Object.prototype.hasOwnProperty.call(value, 'credProps')) return {};
  const properties = value.credProps;
  if (!isPlainObject(properties) || Object.keys(properties).length !== 1 ||
      !Object.prototype.hasOwnProperty.call(properties, 'rk') || typeof properties.rk !== 'boolean') {
    invalidCredential('credential.clientExtensionResults contains invalid public credential properties');
  }
  return { credProps: { rk: properties.rk } };
}

function validateCredentialEnvelope(value) {
  try {
    validateExactObject(
      value,
      ['id', 'rawId', 'response', 'type', 'clientExtensionResults'],
      ['authenticatorAttachment'],
      'credential',
    );
  } catch (error) {
    invalidCredential(error.message);
  }

  if (typeof value.id !== 'string' || value.id.length === 0 || value.id.length > 512) {
    invalidCredential('credential.id must be a non-empty base64url identifier');
  }
  if (typeof value.rawId !== 'string' || value.rawId.length === 0 || value.rawId.length > 512) {
    invalidCredential('credential.rawId must be a non-empty base64url identifier');
  }
  const idBytes = validateBase64UrlBlob(value.id, 'credential.id', 512);
  const rawIdBytes = validateBase64UrlBlob(value.rawId, 'credential.rawId', 512);
  if (idBytes.length === 0 || rawIdBytes.length === 0 ||
      idBytes.length !== rawIdBytes.length || !timingSafeEqual(idBytes, rawIdBytes)) {
    invalidCredential('credential.id and credential.rawId must identify the same credential');
  }
  if (value.type !== 'public-key') {
    invalidCredential('credential.type must be public-key');
  }
  const clientExtensionResults = validateServerExtensionResults(value.clientExtensionResults);
  if (value.authenticatorAttachment !== undefined &&
      !CREDENTIAL_ATTACHMENTS.has(value.authenticatorAttachment)) {
    invalidCredential('credential.authenticatorAttachment is unsupported');
  }
  if (!isPlainObject(value.response)) {
    invalidCredential('credential.response must be an object');
  }

  return {
    id: value.id,
    rawId: value.rawId,
    type: value.type,
    clientExtensionResults,
    ...(value.authenticatorAttachment === undefined
      ? {}
      : { authenticatorAttachment: value.authenticatorAttachment }),
  };
}

export function validateCredentialResponse(value, ceremonyType) {
  const credential = validateCredentialEnvelope(value);

  if (ceremonyType === 'registration') {
    try {
      validateExactObject(
        value.response,
        ['clientDataJSON', 'attestationObject'],
        ['authenticatorData', 'transports', 'publicKeyAlgorithm', 'publicKey'],
        'credential.response',
      );
    } catch (error) {
      invalidCredential(error.message);
    }
    validateBase64UrlBlob(value.response.clientDataJSON, 'credential.response.clientDataJSON', 8192);
    validateBase64UrlBlob(value.response.attestationObject, 'credential.response.attestationObject');
    if (value.response.authenticatorData !== undefined) {
      validateBase64UrlBlob(value.response.authenticatorData, 'credential.response.authenticatorData');
    }
    if (value.response.publicKey !== undefined) {
      validateBase64UrlBlob(value.response.publicKey, 'credential.response.publicKey');
    }
    if (value.response.publicKeyAlgorithm !== undefined &&
        !SUPPORTED_CREDENTIAL_ALGORITHMS.has(value.response.publicKeyAlgorithm)) {
      invalidCredential('credential.response.publicKeyAlgorithm is unsupported');
    }
    const transports = validateTransports(value.response.transports);

    return {
      ...credential,
      response: {
        clientDataJSON: value.response.clientDataJSON,
        attestationObject: value.response.attestationObject,
        ...(value.response.authenticatorData === undefined
          ? {}
          : { authenticatorData: value.response.authenticatorData }),
        ...(transports === undefined ? {} : { transports }),
        ...(value.response.publicKeyAlgorithm === undefined
          ? {}
          : { publicKeyAlgorithm: value.response.publicKeyAlgorithm }),
        ...(value.response.publicKey === undefined ? {} : { publicKey: value.response.publicKey }),
      },
    };
  }

  if (ceremonyType === 'authentication') {
    try {
      validateExactObject(
        value.response,
        ['clientDataJSON', 'authenticatorData', 'signature', 'userHandle'],
        [],
        'credential.response',
      );
    } catch (error) {
      invalidCredential(error.message);
    }
    validateBase64UrlBlob(value.response.clientDataJSON, 'credential.response.clientDataJSON', 8192);
    validateBase64UrlBlob(value.response.authenticatorData, 'credential.response.authenticatorData');
    validateBase64UrlBlob(value.response.signature, 'credential.response.signature');
    const userHandle = validateBase64UrlBlob(
      value.response.userHandle,
      'credential.response.userHandle',
      43,
    );
    if (userHandle.length !== 32 || value.response.userHandle.length !== 43) {
      invalidCredential('credential.response.userHandle must be a 32-byte user identifier');
    }

    return {
      ...credential,
      response: {
        clientDataJSON: value.response.clientDataJSON,
        authenticatorData: value.response.authenticatorData,
        signature: value.response.signature,
        userHandle: value.response.userHandle,
      },
    };
  }

  throw new Error(`Unsupported credential ceremony type: ${ceremonyType}`);
}

export function validateClientDataJSON(clientDataJSON, expectedType, expectedChallenge, allowedOrigins) {
  let parsed;
  try {
    parsed = JSON.parse(base64UrlDecodeToUtf8(clientDataJSON, 'clientDataJSON'));
  } catch (error) {
    throw serviceError(400, 'invalid_client_data_json', 'clientDataJSON must be canonical base64url JSON');
  }

  if (!isPlainObject(parsed)) {
    throw serviceError(400, 'invalid_client_data_json', 'clientDataJSON must decode to a JSON object');
  }
  if (parsed.type !== expectedType) {
    throw serviceError(400, 'credential_type_mismatch', `Expected ${expectedType} clientDataJSON`);
  }
  if (parsed.challenge !== expectedChallenge) {
    throw serviceError(400, 'challenge_mismatch', 'Credential challenge does not match the issued ceremony challenge');
  }
  if (typeof parsed.origin !== 'string' || !allowedOrigins.has(parsed.origin)) {
    throw serviceError(403, 'origin_not_allowed', 'Credential origin is not allowed');
  }
  if (parsed.crossOrigin !== undefined && typeof parsed.crossOrigin !== 'boolean') {
    throw serviceError(400, 'invalid_client_data_json', 'clientDataJSON crossOrigin must be a boolean when present');
  }
  if (parsed.crossOrigin === true || parsed.topOrigin !== undefined) {
    throw serviceError(403, 'cross_origin_not_allowed', 'Cross-origin WebAuthn ceremonies are not allowed');
  }

  return parsed;
}
