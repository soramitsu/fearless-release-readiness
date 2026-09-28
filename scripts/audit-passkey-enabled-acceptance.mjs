#!/usr/bin/env node

// This is an enabled-feature gate. A successful blocked-state audit or an
// original-phone passkey login cannot establish portable recovery.
import assert from 'node:assert/strict';
import { constants, fstatSync, lstatSync, openSync, readSync, closeSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { createHash, createPublicKey, verify } from 'node:crypto';

const PRODUCTION_ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const HEX_256 = /^[a-f0-9]{64}$/u;
const GIT_COMMIT = /^[a-f0-9]{40}$/u;
const EVIDENCE_DIR = 'build/reports/passkey-enabled-acceptance/raw/';
const EVIDENCE_KINDS = [
  'ios-to-replacement-android',
  'android-to-replacement-ios',
  'drive-appdata-interoperability',
  'sanitized-network-traffic',
  'play-signed-upgrade',
  'apple-delivered-upgrade',
  'independent-security-review',
];
const CHECKS = [
  'originalIosUnavailable',
  'originalAndroidUnavailable',
  'iosToAndroidRestore',
  'androidToIosRestore',
  'restoredWalletIdentitySigningAndExport',
  'googlePasswordManagerPrf',
  'currentSignedConfigEnabledAtCeremony',
  'driveUploadDownloadAndDecrypt',
  'noPrfPlaintextOrKeysInTraffic',
  'missingPrfWrongAccountRevokedTamperReplayConcurrentAndInterrupted',
  'lastDecryptableGenerationRetained',
  'credentialRevocationAndBackupKeyRotation',
  'playSignedInPlaceUpgrade',
  'appleDeliveredInPlaceUpgrade',
  'providerRecovery',
  'sameDriveAppDataFile',
  'optionalIcloudDoesNotSubstitute',
  'featureDisableRetainsLegacyWalletAccess',
];
const SIGNING_DOMAIN = Buffer.from('fearless/passkey-enabled-acceptance/v1\n', 'utf8');

function requireKeys(value, keys, label) {
  assert.ok(value && typeof value === 'object' && !Array.isArray(value), `${label} must be an object`);
  assert.deepEqual(Object.keys(value).sort(), [...keys].sort(), `${label} has missing or unexpected fields`);
}

function requireDigest(value, label) {
  assert.match(value, HEX_256, `${label} must be lowercase SHA-256`);
}

function requireString(value, label) {
  assert.ok(typeof value === 'string' && value.length > 0 && value.length <= 512, `${label} must be a nonempty string`);
}

function canonicalJson(value) {
  if (Array.isArray(value)) return `[${value.map(canonicalJson).join(',')}]`;
  if (value && typeof value === 'object') {
    return `{${Object.keys(value).sort().map((key) => `${JSON.stringify(key)}:${canonicalJson(value[key])}`).join(',')}}`;
  }
  return JSON.stringify(value);
}

// Reject symlinks at every existing path component, including the raw evidence
// directory. A signed digest must bind the bytes actually opened by this gate.
function regularFile(root, relativePath) {
  assert.ok(!path.isAbsolute(relativePath), 'absolute evidence path rejected');
  const normalized = path.posix.normalize(relativePath);
  assert.equal(normalized, relativePath, 'noncanonical evidence path rejected');
  assert.ok(!normalized.startsWith('../') && normalized !== '..', 'evidence path escapes root');
  const components = normalized.split('/');
  assert.ok(components.every((part) => part && part !== '.' && part !== '..'), 'invalid evidence path component');
  let current = root;
  for (let index = 0; index < components.length; index += 1) {
    current = path.join(current, components[index]);
    const info = lstatSync(current);
    assert.ok(!info.isSymbolicLink(), `symlink rejected: ${relativePath}`);
    assert.ok(index === components.length - 1 ? info.isFile() : info.isDirectory(), `not a regular file: ${relativePath}`);
  }
  return current;
}

function openRegularFile(file) {
  const descriptor = openSync(file, constants.O_RDONLY | constants.O_NOFOLLOW);
  try {
    assert.ok(fstatSync(descriptor).isFile(), 'evidence must remain a regular file');
  } catch (error) {
    closeSync(descriptor);
    throw error;
  }
  return descriptor;
}

function readRegularFile(file) {
  const descriptor = openRegularFile(file);
  const buffer = Buffer.alloc(64 * 1024);
  const chunks = [];
  let total = 0;
  try {
    for (;;) {
      const count = readSync(descriptor, buffer, 0, buffer.length, null);
      if (count === 0) break;
      total += count;
      assert.ok(total <= 1024 * 1024, 'JSON input exceeds 1 MiB');
      chunks.push(Buffer.from(buffer.subarray(0, count)));
    }
  } finally {
    closeSync(descriptor);
  }
  return Buffer.concat(chunks);
}

function sha256File(file) {
  const descriptor = openRegularFile(file);
  const digest = createHash('sha256');
  const buffer = Buffer.alloc(64 * 1024);
  try {
    for (;;) {
      const count = readSync(descriptor, buffer, 0, buffer.length, null);
      if (count === 0) break;
      digest.update(buffer.subarray(0, count));
    }
  } finally {
    closeSync(descriptor);
  }
  return digest.digest('hex');
}

function readJson(root, relativePath) {
  return JSON.parse(readRegularFile(regularFile(root, relativePath)).toString('utf8'));
}

function validateSourceBinding(payload, manifest) {
  for (const platform of ['android', 'ios']) {
    requireKeys(payload[platform], ['sourceCommit', 'artifactSha256', 'compiledPasskeyRecoveryEnabled'], `payload.${platform}`);
    requireKeys(manifest[platform], ['sourceCommit', 'artifactSha256', 'compiledPasskeyRecoveryEnabled'], `manifest.${platform}`);
    assert.match(payload[platform].sourceCommit, GIT_COMMIT, `${platform} source commit required`);
    requireDigest(payload[platform].artifactSha256, `${platform} artifact digest`);
    assert.deepEqual(payload[platform], manifest[platform], `${platform} source/artifact substitution rejected`);
    assert.equal(manifest[platform].compiledPasskeyRecoveryEnabled, true, `${platform} shipping artifact must compile passkey recovery approval`);
  }
}

function validateReleaseConfiguration(root, manifest) {
  requireDigest(manifest.passkeyConfigSha256, 'passkey production configuration digest');
  const configBytes = readRegularFile(regularFile(root, 'config/passkey-backup-production.json'));
  assert.equal(createHash('sha256').update(configBytes).digest('hex'), manifest.passkeyConfigSha256, 'passkey production configuration substitution rejected');
  const config = JSON.parse(configBytes.toString('utf8'));
  assert.equal(config.releaseEnabled, true, 'passkey recovery must be enabled in production configuration');
  for (const platform of ['android', 'ios']) {
    assert.equal(config[platform]?.releaseEnabled, true, `${platform} passkey recovery must be enabled in production configuration`);
    assert.equal(config[platform]?.backupStorage, 'google-drive-appdata', `${platform} Google Drive backup must be primary`);
    assert.equal(config[platform]?.googleDriveScope, 'https://www.googleapis.com/auth/drive.appdata', `${platform} Drive app-data scope required`);
  }
}

function validateDates(payload, now) {
  const started = Date.parse(payload.startedAt);
  const completed = Date.parse(payload.completedAt);
  const expires = Date.parse(payload.expiresAt);
  assert.ok([started, completed, expires].every(Number.isFinite), 'invalid acceptance timestamps');
  assert.ok(started <= completed && completed <= now + 5 * 60_000, 'acceptance evidence is future-dated or reversed');
  assert.ok(now >= completed && now < expires, 'acceptance evidence expired or incomplete');
  assert.ok(expires - completed <= 14 * 24 * 60 * 60_000, 'acceptance lifetime exceeds 14 days');
}

function validateEvidence(root, evidence, manifest) {
  assert.ok(Array.isArray(evidence) && evidence.length === EVIDENCE_KINDS.length, 'complete raw evidence set required');
  assert.ok(Array.isArray(manifest.evidence), 'shipping manifest evidence is required');
  const shippingRows = new Map();
  for (const row of manifest.evidence) {
    assert.ok(row && typeof row === 'object' && typeof row.kind === 'string' &&
      !shippingRows.has(row.kind), 'shipping manifest evidence is ambiguous');
    shippingRows.set(row.kind, row);
  }
  const kinds = new Set();
  const paths = new Set();
  for (const row of evidence) {
    requireKeys(row, ['kind', 'path', 'sha256'], 'evidence row');
    assert.ok(EVIDENCE_KINDS.includes(row.kind) && !kinds.has(row.kind), 'missing or duplicate evidence kind');
    assert.ok(typeof row.path === 'string' && row.path.startsWith(EVIDENCE_DIR), 'raw evidence must stay under acceptance evidence directory');
    assert.ok(!paths.has(row.path), 'one raw file cannot substitute for multiple evidence kinds');
    requireDigest(row.sha256, 'raw evidence digest');
    const actualDigest = sha256File(regularFile(root, row.path));
    assert.deepEqual(shippingRows.get(row.kind), row,
      `acceptance evidence differs from shipping manifest: ${row.kind}`);
    assert.equal(actualDigest, row.sha256, `raw evidence digest mismatch: ${row.kind}`);
    kinds.add(row.kind);
    paths.add(row.path);
  }
  assert.deepEqual([...kinds].sort(), [...EVIDENCE_KINDS].sort(), 'raw evidence kind mismatch');
}

function validateTrustAndSignatures(trust, payload, signatures) {
  requireKeys(trust, ['schemaVersion', 'keys'], 'review trust');
  assert.equal(trust.schemaVersion, 1, 'review trust schema mismatch');
  requireKeys(trust.keys, ['mobileQa', 'security'], 'review trust keys');
  assert.ok(Array.isArray(signatures) && signatures.length === 2, 'two independent reviewer signatures required');
  const message = Buffer.concat([SIGNING_DOMAIN, Buffer.from(canonicalJson(payload), 'utf8')]);
  const seenRoles = new Set();
  const seenKeyIds = new Set();
  const seenPublicKeyDer = new Set();
  for (const role of ['mobileQa', 'security']) {
    const key = trust.keys[role];
    requireKeys(key, ['keyId', 'publicKeyPem'], `${role} trust key`);
    requireString(key.keyId, `${role} key ID`);
    requireString(key.publicKeyPem, `${role} public key`);
    assert.ok(!seenKeyIds.has(key.keyId), 'reviewers must have distinct key IDs');
    seenKeyIds.add(key.keyId);
    const signature = signatures.find((row) => row?.role === role);
    requireKeys(signature, ['role', 'keyId', 'signatureBase64'], `${role} signature`);
    assert.equal(signature.keyId, key.keyId, `${role} signing key mismatch`);
    assert.match(signature.signatureBase64, /^[A-Za-z0-9+/]{86}==$/u, `${role} Ed25519 signature encoding required`);
    const publicKey = createPublicKey(key.publicKeyPem);
    assert.equal(publicKey.asymmetricKeyType, 'ed25519', `${role} Ed25519 key required`);
    const publicKeyDer = publicKey.export({ type: 'spki', format: 'der' }).toString('hex');
    assert.ok(!seenPublicKeyDer.has(publicKeyDer), 'reviewers must have distinct keys');
    seenPublicKeyDer.add(publicKeyDer);
    assert.ok(verify(null, message, publicKey, Buffer.from(signature.signatureBase64, 'base64')), `${role} signature invalid`);
    seenRoles.add(role);
  }
  assert.deepEqual(signatures.map((row) => row.role).sort(), [...seenRoles].sort(), 'duplicate or substituted reviewer role');
}

export function auditPasskeyEnabledAcceptance(root = PRODUCTION_ROOT, now = Date.now()) {
  const manifestPath = 'config/release-shipping-manifest.json';
  const manifestBytes = readRegularFile(regularFile(root, manifestPath));
  const manifest = JSON.parse(manifestBytes.toString('utf8'));
  const trust = readJson(root, 'config/passkey-enabled-acceptance-trust.json');
  const attestation = readJson(root, 'build/reports/passkey-enabled-acceptance/attestation.json');
  requireKeys(attestation, ['schemaVersion', 'payload', 'signatures'], 'acceptance attestation');
  assert.equal(attestation.schemaVersion, 1, 'acceptance attestation schema mismatch');
  const payload = attestation.payload;
  requireKeys(payload, [
    'releaseManifestSha256', 'android', 'ios', 'startedAt', 'completedAt', 'expiresAt',
    'googleDrive', 'checks', 'evidence',
  ], 'acceptance payload');
  requireDigest(payload.releaseManifestSha256, 'release manifest digest');
  assert.equal(createHash('sha256').update(manifestBytes).digest('hex'), payload.releaseManifestSha256, 'release manifest digest mismatch');
  assert.equal(manifest.schemaVersion, 1, 'shipping manifest schema mismatch');
  validateSourceBinding(payload, manifest);
  validateReleaseConfiguration(root, manifest);
  requireKeys(payload.googleDrive, [
    'applicationId', 'androidOAuthClientId', 'iosOAuthClientId', 'sharedAppDataFileId', 'sharedCiphertextSha256', 'scope',
  ], 'Google Drive interoperability');
  for (const key of ['applicationId', 'androidOAuthClientId', 'iosOAuthClientId', 'sharedAppDataFileId']) {
    requireString(payload.googleDrive[key], `Google Drive ${key}`);
  }
  assert.notEqual(payload.googleDrive.androidOAuthClientId, payload.googleDrive.iosOAuthClientId, 'distinct OAuth clients required');
  assert.equal(payload.googleDrive.applicationId, manifest.googleApplicationId, 'Google application identity mismatch');
  assert.equal(payload.googleDrive.scope, 'https://www.googleapis.com/auth/drive.appdata', 'Drive app-data scope required');
  requireDigest(payload.googleDrive.sharedCiphertextSha256, 'shared Drive ciphertext digest');
  requireKeys(payload.checks, CHECKS, 'enabled-feature checks');
  for (const check of CHECKS) assert.equal(payload.checks[check], true, `${check} requires affirmative device/review evidence`);
  validateDates(payload, now);
  validateEvidence(root, payload.evidence, manifest);
  validateTrustAndSignatures(trust, payload, attestation.signatures);
  return { releaseManifestSha256: payload.releaseManifestSha256, acceptedAt: new Date(now).toISOString() };
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try {
    assert.equal(process.argv.length, 2, 'production acceptance gate takes no arguments');
    const result = auditPasskeyEnabledAcceptance();
    process.stdout.write(`[passkey-enabled-acceptance] PASS ${result.releaseManifestSha256}\n`);
  } catch (error) {
    process.stderr.write(`[passkey-enabled-acceptance][error] ${error.message}\n`);
    process.exitCode = 1;
  }
}
