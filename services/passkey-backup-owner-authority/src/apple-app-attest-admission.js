import { createHash, timingSafeEqual, X509Certificate } from 'node:crypto';
import { readFileSync } from 'node:fs';
import { decodeCBOR, decodePartialCBOR } from '@levischuck/tiny-cbor';
import { X509Certificate as ParsedCertificate } from '@peculiar/x509';
import { appAttestation, deny } from './validation.js';

const APP_ATTEST_ROOT = new X509Certificate(readFileSync(
  new URL('./apple-app-attestation-root-ca.pem', import.meta.url)));
const NONCE_EXTENSION = '1.2.840.113635.100.8.2';
const PRODUCTION_AAGUID = Buffer.from('appattest\0\0\0\0\0\0\0', 'binary');
const TEAM_ID = /^[A-Z0-9]{10}$/u;
const BUNDLE_ID = /^[a-zA-Z][a-zA-Z0-9-]*(?:\.[a-zA-Z][a-zA-Z0-9-]*)+$/u;
const BUNDLE_VERSION = /^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$/u;

function hash(bytes) { return createHash('sha256').update(bytes).digest(); }
function bytes(value, min, max) {
  if (!(value instanceof Uint8Array) || value.byteLength < min || value.byteLength > max) {
    deny('verification_failed');
  }
  return Buffer.from(value);
}
function mapWithKeys(value, keys) {
  if (!(value instanceof Map) || value.size !== keys.length ||
      keys.some((key) => !value.has(key))) deny('verification_failed');
  return value;
}
function equal(a, b) {
  return a.length === b.length && timingSafeEqual(a, b);
}

function verifyCertificateChain(x5c, nowMillis) {
  if (!Array.isArray(x5c) || x5c.length !== 2 ||
      !Number.isSafeInteger(nowMillis) || nowMillis < 0) deny('verification_failed');
  const [leafBytes, intermediateBytes] = x5c.map((value) => bytes(value, 256, 8192));
  const leaf = new X509Certificate(leafBytes);
  const intermediate = new X509Certificate(intermediateBytes);
  const now = new Date(nowMillis);
  for (const cert of [leaf, intermediate, APP_ATTEST_ROOT]) {
    if (now < cert.validFromDate || now > cert.validToDate) deny('verification_failed');
  }
  if (leaf.ca || !intermediate.ca || !APP_ATTEST_ROOT.ca ||
      !leaf.checkIssued(intermediate) || !leaf.verify(intermediate.publicKey) ||
      !intermediate.checkIssued(APP_ATTEST_ROOT) ||
      !intermediate.verify(APP_ATTEST_ROOT.publicKey)) deny('verification_failed');
  return { leaf, leafBytes };
}

function nonceFromLeaf(leafBytes) {
  const parsed = new ParsedCertificate(leafBytes);
  const extensions = parsed.getExtensions(NONCE_EXTENSION);
  if (extensions.length !== 1) deny('verification_failed');
  const value = Buffer.from(extensions[0].value);
  // Apple encodes a single 32-byte octet string under context tag [1].
  if (value.length !== 38 || !equal(value.subarray(0, 6),
    Buffer.from([0x30, 0x24, 0xa1, 0x22, 0x04, 0x20]))) deny('verification_failed');
  return value.subarray(6);
}

function publicPoint(leaf) {
  const jwk = leaf.publicKey.export({ format: 'jwk' });
  if (jwk.kty !== 'EC' || jwk.crv !== 'P-256' ||
      typeof jwk.x !== 'string' || typeof jwk.y !== 'string') deny('verification_failed');
  const x = Buffer.from(jwk.x, 'base64url');
  const y = Buffer.from(jwk.y, 'base64url');
  if (x.length !== 32 || y.length !== 32 ||
      x.toString('base64url') !== jwk.x || y.toString('base64url') !== jwk.y) {
    deny('verification_failed');
  }
  return Buffer.concat([Buffer.from([0x04]), x, y]);
}

function verifyAuthenticatorData(authData, keyId, point, appId, allowedBundleVersions) {
  if (authData.length < 87 || !equal(authData.subarray(0, 32), hash(Buffer.from(appId, 'utf8'))) ||
      (authData[32] & 0x40) !== 0x40 || authData.readUInt32BE(33) !== 0 ||
      !equal(authData.subarray(37, 53), PRODUCTION_AAGUID) ||
      authData.readUInt16BE(53) !== 32 || !equal(authData.subarray(55, 87), keyId)) {
    deny('verification_failed');
  }
  const [cose, coseLength] = decodePartialCBOR(Uint8Array.from(authData), 87);
  mapWithKeys(cose, [1, 3, -1, -2, -3]);
  if (cose.get(1) !== 2 || cose.get(3) !== -7 || cose.get(-1) !== 1 ||
      !equal(Buffer.concat([Buffer.from([0x04]), bytes(cose.get(-2), 32, 32),
        bytes(cose.get(-3), 32, 32)]), point)) deny('verification_failed');
  const offset = 87 + coseLength;
  if (offset >= authData.length) deny('verification_failed');
  const [extensions, length] = decodePartialCBOR(Uint8Array.from(authData), offset);
  mapWithKeys(extensions, ['apple_bundle_version_01', 'apple_validation_category_01']);
  if (offset + length !== authData.length ||
      !allowedBundleVersions.has(extensions.get('apple_bundle_version_01')) ||
      !equal(bytes(extensions.get('apple_validation_category_01'), 4, 4),
        Buffer.from([1, 0, 0, 0]))) deny('verification_failed');
}

/**
 * Verify Apple's signed attestation structure against the pinned Apple App
 * Attestation root. The caller must separately validate its fraud receipt.
 * Exposed for Apple's published sample vector; the production adapter below
 * additionally requires the exact wallet-proof nonce and app identity.
 */
export function verifyAppleAppAttestObject({ attestationObject, keyId, clientDataHash,
  teamId, bundleId, allowedBundleVersions, nowMillis }) {
  try {
    const object = mapWithKeys(decodeCBOR(Uint8Array.from(bytes(attestationObject, 32, 32768))),
      ['fmt', 'attStmt', 'authData']);
    if (object.get('fmt') !== 'apple-appattest') deny('verification_failed');
    const statement = mapWithKeys(object.get('attStmt'), ['x5c', 'receipt']);
    const receipt = bytes(statement.get('receipt'), 1, 16384);
    const authData = bytes(object.get('authData'), 87, 4096);
    const id = bytes(keyId, 32, 32);
    const clientHash = bytes(clientDataHash, 1, 4096);
    if (typeof teamId !== 'string' || !TEAM_ID.test(teamId) ||
        typeof bundleId !== 'string' || !BUNDLE_ID.test(bundleId) ||
        !(allowedBundleVersions instanceof Set) || allowedBundleVersions.size === 0) {
      deny('verification_failed');
    }
    const { leaf, leafBytes } = verifyCertificateChain(statement.get('x5c'), nowMillis);
    const expectedNonce = hash(Buffer.concat([authData, clientHash]));
    if (!equal(nonceFromLeaf(leafBytes), expectedNonce)) deny('verification_failed');
    const point = publicPoint(leaf);
    if (!equal(hash(point), id)) deny('verification_failed');
    verifyAuthenticatorData(authData, id, point, `${teamId}.${bundleId}`,
      allowedBundleVersions);
    return Object.freeze({ receipt, keyId: id.toString('base64url') });
  } catch { deny('verification_failed'); }
}

/**
 * Server-owned, production-environment App Attest admission. It has no default
 * receipt verifier and is not composed with a deployable HTTP listener.
 */
export function createAppleAppAttestBootstrapVerifier({ teamId, bundleId,
  allowedBundleVersions, verifyReceipt, now = Date.now } = {}) {
  if (typeof teamId !== 'string' || !TEAM_ID.test(teamId) ||
      typeof bundleId !== 'string' || !BUNDLE_ID.test(bundleId) ||
      !Array.isArray(allowedBundleVersions) || allowedBundleVersions.length === 0 ||
      allowedBundleVersions.length > 32 ||
      allowedBundleVersions.some((version) => typeof version !== 'string' ||
        !BUNDLE_VERSION.test(version)) ||
      new Set(allowedBundleVersions).size !== allowedBundleVersions.length ||
      typeof verifyReceipt !== 'function' || typeof now !== 'function') {
    deny('invalid_configuration');
  }
  const application = `ios:${teamId}:${bundleId}`;
  const versions = new Set(allowedBundleVersions);
  return async function verifyAppAttestation(input) {
    try {
      if (!input || input.platform !== 'ios' ||
          input.expectedApplication !== application ||
          typeof input.expectedNonce !== 'string' ||
          !/^[A-Za-z0-9_-]{43}$/u.test(input.expectedNonce)) deny('verification_failed');
      const challengeBytes = Buffer.from(input.expectedNonce, 'base64url');
      if (challengeBytes.length !== 32 ||
          challengeBytes.toString('base64url') !== input.expectedNonce) deny('verification_failed');
      const attestation = appAttestation(input.attestation, 'ios');
      const verified = verifyAppleAppAttestObject({
        attestationObject: Buffer.from(attestation.attestationObject, 'base64url'),
        keyId: Buffer.from(attestation.keyId, 'base64url'), clientDataHash: hash(challengeBytes),
        teamId, bundleId, allowedBundleVersions: versions, nowMillis: now(),
      });
      if (await verifyReceipt(Object.freeze({ receipt: verified.receipt,
        keyId: verified.keyId, application })) !== true) deny('verification_failed');
      return Object.freeze({ platform: 'ios', nonce: input.expectedNonce, application });
    } catch { deny('verification_failed'); }
  };
}
