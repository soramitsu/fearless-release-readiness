import { createHash, randomBytes } from 'node:crypto';

export class AuthorityError extends Error {
  constructor(code = 'authorization_failed') {
    super(code);
    this.name = 'AuthorityError';
    this.code = code;
  }
}
export function deny(code) { throw new AuthorityError(code); }
export function exact(value, fields) {
  if (!value || Object.getPrototypeOf(value) !== Object.prototype ||
      Object.keys(value).length !== fields.length ||
      fields.some((key) => !Object.hasOwn(value, key))) deny('invalid_request');
  return value;
}
export function base64(value, minimum = 1, maximum = 8192) {
  if (typeof value !== 'string' || value.length > maximum * 2 || !/^[A-Za-z0-9_-]+$/.test(value)) deny('invalid_request');
  const bytes = Buffer.from(value, 'base64url');
  if (bytes.length < minimum || bytes.length > maximum || bytes.toString('base64url') !== value) deny('invalid_request');
  return value;
}
export function hash(value) { return createHash('sha256').update(value).digest('base64url'); }
export function random(prefix = '') { return prefix + randomBytes(32).toString('base64url'); }
export function platform(value) {
  if (value !== 'android' && value !== 'ios') deny('invalid_request');
  return value;
}
export function counter(value) {
  if (!Number.isSafeInteger(value) || value < 0 || value > 0xffffffff) deny('invalid_request');
  return value;
}
export function opaque(value, prefix) {
  if (typeof value !== 'string' || !value.startsWith(prefix)) deny('authorization_failed');
  base64(value.slice(prefix.length), 32, 32);
  return value;
}
export const RP_ID = 'fearlesswallet.io';
export const SCOPES = Object.freeze({
  '/api/passkey-backup/v1/registration/challenge': 'passkey.registration.challenge',
  '/api/passkey-backup/v1/registration/complete': 'passkey.registration.complete',
  '/api/passkey-backup/v1/assertion/challenge': 'passkey.assertion.challenge',
  '/api/passkey-backup/v1/assertion/complete': 'passkey.assertion.complete',
  '/api/passkey-backup/v1/credentials/list': 'passkey.credentials.list',
  '/api/passkey-backup/v1/credentials/revoke': 'passkey.credentials.revoke',
  '/api/passkey-backup/v1/credentials/revoke-all': 'passkey.credentials.revoke-all',
});
export function requestBinding(value, audience) {
  exact(value, ['schemaVersion', 'audience', 'method', 'path', 'bodySha256', 'scope']);
  if (value.schemaVersion !== 1 || value.audience !== audience || value.method !== 'POST' ||
      !Object.hasOwn(SCOPES, value.path) || SCOPES[value.path] !== value.scope) deny('invalid_request');
  base64(value.bodySha256, 32, 32);
  return { ...value };
}

// This is public WebAuthn transport data only. In particular, never forward PRF
// or largeBlob extension output to an adapter. Native clients must strip it
// BEFORE HTTP serialization; rejection here cannot undo transmission.
export function credentialResponse(value, kind, { allowNullUserHandle = false } = {}) {
  exact(value, Object.hasOwn(value ?? {}, 'authenticatorAttachment')
    ? ['id', 'rawId', 'type', 'response', 'clientExtensionResults', 'authenticatorAttachment']
    : ['id', 'rawId', 'type', 'response', 'clientExtensionResults']);
  base64(value.id, 1, 384);
  if (value.rawId !== value.id || value.type !== 'public-key') deny('invalid_request');
  if (value.authenticatorAttachment !== undefined &&
      !['platform', 'cross-platform'].includes(value.authenticatorAttachment)) deny('invalid_request');
  const extensionKeys = Object.keys(value.clientExtensionResults ?? {});
  if (extensionKeys.length === 0) exact(value.clientExtensionResults, []);
  else {
    exact(value.clientExtensionResults, ['credProps']);
    exact(value.clientExtensionResults.credProps, ['rk']);
    if (typeof value.clientExtensionResults.credProps.rk !== 'boolean') deny('invalid_request');
  }
  if (kind === 'authentication') {
    exact(value.response, ['clientDataJSON', 'authenticatorData', 'signature', 'userHandle']);
    base64(value.response.authenticatorData, 37, 8192);
    base64(value.response.signature, 1, 2048);
    if (value.response.userHandle !== null || !allowNullUserHandle) {
      base64(value.response.userHandle, 1, 64);
    }
  } else {
    const fields = ['clientDataJSON', 'attestationObject'];
    for (const field of ['authenticatorData', 'transports', 'publicKeyAlgorithm', 'publicKey']) {
      if (Object.hasOwn(value.response ?? {}, field)) fields.push(field);
    }
    exact(value.response, fields);
    base64(value.response.attestationObject, 1, 16384);
    if (value.response.authenticatorData !== undefined) base64(value.response.authenticatorData, 37, 8192);
    if (value.response.publicKey !== undefined) base64(value.response.publicKey, 1, 6144);
    if (value.response.publicKeyAlgorithm !== undefined &&
        ![-7, -257].includes(value.response.publicKeyAlgorithm)) deny('invalid_request');
    if (Object.hasOwn(value.response, 'transports')) {
      const transports = value.response.transports;
      if (!Array.isArray(transports) || transports.length > 7 ||
          new Set(transports).size !== transports.length ||
          transports.some((item) => !['ble', 'cable', 'hybrid', 'internal', 'nfc', 'smart-card', 'usb'].includes(item))) {
        deny('invalid_request');
      }
    }
  }
  base64(value.response.clientDataJSON, 1, 8192);
  return structuredClone(value);
}
export function walletProof(value) {
  exact(value, ['scheme', 'publicKey', 'signature']);
  if (!['ed25519', 'sr25519', 'secp256k1'].includes(value.scheme)) deny('invalid_request');
  base64(value.publicKey, 32, 65);
  base64(value.signature, 64, 80);
  return { ...value };
}
export function credentialRecord(value, expectedId, expectedUserHandle) {
  exact(value, ['id', 'publicKey', 'userHandle', 'counter', 'deviceType', 'backedUp']);
  backupFlags(value);
  base64(value.id, 1, 384);
  base64(value.publicKey, 1, 6144);
  base64(value.userHandle, 1, 64);
  counter(value.counter);
  if (value.id !== expectedId || value.userHandle !== expectedUserHandle) deny('verification_failed');
  return { ...value };
}

export function backupFlags(value) {
  if (!['singleDevice', 'multiDevice'].includes(value.deviceType) || typeof value.backedUp !== 'boolean' ||
      (value.deviceType === 'singleDevice' && value.backedUp)) deny('verification_failed');
}
