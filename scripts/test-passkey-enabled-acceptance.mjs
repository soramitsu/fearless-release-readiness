#!/usr/bin/env node

import assert from 'node:assert/strict';
import { createHash, generateKeyPairSync, sign } from 'node:crypto';
import { mkdirSync, mkdtempSync, readFileSync, rmSync, symlinkSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { auditPasskeyEnabledAcceptance } from './audit-passkey-enabled-acceptance.mjs';

const NOW = Date.parse('2026-09-23T03:00:00Z');
const RAW_DIR = 'build/reports/passkey-enabled-acceptance/raw';
const KINDS = [
  'ios-to-replacement-android', 'android-to-replacement-ios', 'drive-appdata-interoperability',
  'sanitized-network-traffic', 'play-signed-upgrade', 'apple-delivered-upgrade', 'independent-security-review',
];
const CHECKS = [
  'originalIosUnavailable', 'originalAndroidUnavailable', 'iosToAndroidRestore', 'androidToIosRestore',
  'restoredWalletIdentitySigningAndExport', 'googlePasswordManagerPrf', 'driveUploadDownloadAndDecrypt',
  'currentSignedConfigEnabledAtCeremony',
  'noPrfPlaintextOrKeysInTraffic', 'missingPrfWrongAccountRevokedTamperReplayConcurrentAndInterrupted',
  'lastDecryptableGenerationRetained', 'credentialRevocationAndBackupKeyRotation', 'playSignedInPlaceUpgrade',
  'appleDeliveredInPlaceUpgrade', 'providerRecovery', 'sameDriveAppDataFile', 'optionalIcloudDoesNotSubstitute',
  'featureDisableRetainsLegacyWalletAccess',
];
const DOMAIN = Buffer.from('fearless/passkey-enabled-acceptance/v1\n');
let cases = 0;

function canonical(value) {
  if (Array.isArray(value)) return `[${value.map(canonical).join(',')}]`;
  if (value && typeof value === 'object') {
    return `{${Object.keys(value).sort().map((key) => `${JSON.stringify(key)}:${canonical(value[key])}`).join(',')}}`;
  }
  return JSON.stringify(value);
}

function sha(value) {
  return createHash('sha256').update(value).digest('hex');
}

function write(root, relative, value) {
  const target = path.join(root, relative);
  mkdirSync(path.dirname(target), { recursive: true });
  writeFileSync(target, typeof value === 'string' ? value : JSON.stringify(value));
}

function fixture() {
  const root = mkdtempSync(path.join(tmpdir(), 'fearless-passkey-acceptance-'));
  const keys = {
    mobileQa: generateKeyPairSync('ed25519'),
    security: generateKeyPairSync('ed25519'),
  };
  const manifest = {
    schemaVersion: 1,
    googleApplicationId: 'fearless-prod-google-app',
    android: { sourceCommit: 'a'.repeat(40), artifactSha256: 'a'.repeat(64), compiledPasskeyRecoveryEnabled: true },
    ios: { sourceCommit: 'b'.repeat(40), artifactSha256: 'b'.repeat(64), compiledPasskeyRecoveryEnabled: true },
  };
  const config = {
    releaseEnabled: true,
    android: { releaseEnabled: true, backupStorage: 'google-drive-appdata', googleDriveScope: 'https://www.googleapis.com/auth/drive.appdata' },
    ios: { releaseEnabled: true, backupStorage: 'google-drive-appdata', googleDriveScope: 'https://www.googleapis.com/auth/drive.appdata' },
  };
  write(root, 'config/passkey-backup-production.json', config);
  manifest.passkeyConfigSha256 = sha(readFileSync(path.join(root, 'config/passkey-backup-production.json')));
  write(root, 'config/release-shipping-manifest.json', manifest);
  write(root, 'config/passkey-enabled-acceptance-trust.json', {
    schemaVersion: 1,
    keys: Object.fromEntries(Object.entries(keys).map(([role, pair]) => [role, {
      keyId: `${role}-production-reviewer`,
      publicKeyPem: pair.publicKey.export({ type: 'spki', format: 'pem' }),
    }])),
  });
  const evidence = KINDS.map((kind) => {
    const relative = `${RAW_DIR}/${kind}.json`;
    const raw = JSON.stringify({ kind, fixture: true });
    write(root, relative, raw);
    return { kind, path: relative, sha256: sha(raw) };
  });
  const payload = {
    releaseManifestSha256: sha(readFileSync(path.join(root, 'config/release-shipping-manifest.json'))),
    android: manifest.android,
    ios: manifest.ios,
    startedAt: '2026-09-22T03:00:00Z',
    completedAt: '2026-09-23T02:00:00Z',
    expiresAt: '2026-10-01T02:00:00Z',
    googleDrive: {
      applicationId: manifest.googleApplicationId,
      androidOAuthClientId: 'android-client',
      iosOAuthClientId: 'ios-client',
      sharedAppDataFileId: 'same-drive-appdata-file',
      sharedCiphertextSha256: 'c'.repeat(64),
      scope: 'https://www.googleapis.com/auth/drive.appdata',
    },
    checks: Object.fromEntries(CHECKS.map((name) => [name, true])),
    evidence,
  };
  const save = (signaturesOverride) => {
    const message = Buffer.concat([DOMAIN, Buffer.from(canonical(payload))]);
    const signatures = signaturesOverride ?? Object.entries(keys).map(([role, pair]) => ({
      role,
      keyId: `${role}-production-reviewer`,
      signatureBase64: sign(null, message, pair.privateKey).toString('base64'),
    }));
    write(root, 'build/reports/passkey-enabled-acceptance/attestation.json', {
      schemaVersion: 1,
      payload,
      signatures,
    });
  };
  save();
  const rebindManifest = () => {
    write(root, 'config/release-shipping-manifest.json', manifest);
    payload.releaseManifestSha256 = sha(readFileSync(path.join(root, 'config/release-shipping-manifest.json')));
    save();
  };
  const rebindConfig = () => {
    write(root, 'config/passkey-backup-production.json', config);
    manifest.passkeyConfigSha256 = sha(readFileSync(path.join(root, 'config/passkey-backup-production.json')));
    rebindManifest();
  };
  return { root, manifest, config, payload, keys, save, rebindManifest, rebindConfig };
}

function inFixture(label, change, expected) {
  const input = fixture();
  try {
    change(input);
    assert.throws(() => auditPasskeyEnabledAcceptance(input.root, NOW), expected, label);
    cases += 1;
  } finally {
    rmSync(input.root, { recursive: true, force: true });
  }
}

{
  const input = fixture();
  try {
    assert.equal(auditPasskeyEnabledAcceptance(input.root, NOW).releaseManifestSha256, input.payload.releaseManifestSha256);
    cases += 1;
  } finally {
    rmSync(input.root, { recursive: true, force: true });
  }
}

inFixture('unsigned assertion substitution', (input) => {
  input.payload.checks.originalIosUnavailable = false;
  input.save([]);
}, /originalIosUnavailable/u);
inFixture('signed but incomplete recovery', (input) => {
  input.payload.checks.androidToIosRestore = false;
  input.save();
}, /androidToIosRestore/u);
inFixture('signed but iCloud-only recovery', (input) => {
  input.payload.googleDrive.scope = 'https://www.googleapis.com/auth/drive.file';
  input.save();
}, /Drive app-data scope/u);
inFixture('signed but same OAuth client', (input) => {
  input.payload.googleDrive.iosOAuthClientId = 'android-client';
  input.save();
}, /distinct OAuth clients/u);
inFixture('manifest replacement', (input) => {
  input.manifest.ios.sourceCommit = 'd'.repeat(40);
  write(input.root, 'config/release-shipping-manifest.json', input.manifest);
}, /release manifest digest mismatch/u);
inFixture('artifact substitution with re-bound manifest', (input) => {
  input.payload.android.artifactSha256 = 'd'.repeat(64);
  input.save();
}, /source\/artifact substitution/u);
inFixture('compiled recovery disabled in shipping artifact', (input) => {
  input.manifest.android.compiledPasskeyRecoveryEnabled = false;
  input.rebindManifest();
}, /shipping artifact must compile passkey recovery approval/u);
inFixture('compiled recovery approval absent from shipping manifest', (input) => {
  delete input.manifest.ios.compiledPasskeyRecoveryEnabled;
  input.rebindManifest();
}, /missing or unexpected fields/u);
inFixture('production configuration disabled', (input) => {
  input.config.releaseEnabled = false;
  input.rebindConfig();
}, /enabled in production configuration/u);
inFixture('one platform disabled in production configuration', (input) => {
  input.config.ios.releaseEnabled = false;
  input.rebindConfig();
}, /ios passkey recovery must be enabled/u);
inFixture('production configuration substituted after attestation', (input) => {
  input.config.android.releaseEnabled = false;
  write(input.root, 'config/passkey-backup-production.json', input.config);
}, /production configuration substitution rejected/u);
inFixture('tampered raw traffic', (input) => {
  write(input.root, `${RAW_DIR}/sanitized-network-traffic.json`, 'replaced bytes');
}, /raw evidence digest mismatch/u);
inFixture('missing evidence category', (input) => {
  input.payload.evidence.pop();
  input.save();
}, /complete raw evidence set/u);
inFixture('path traversal', (input) => {
  input.payload.evidence[0].path = `${RAW_DIR}/../../../../outside.json`;
  input.save();
}, /noncanonical evidence path/u);
inFixture('symlinked raw evidence', (input) => {
  const relative = `${RAW_DIR}/ios-to-replacement-android.json`;
  rmSync(path.join(input.root, relative));
  symlinkSync(path.join(input.root, `${RAW_DIR}/android-to-replacement-ios.json`), path.join(input.root, relative));
}, /symlink rejected/u);
inFixture('expired evidence', (input) => {
  input.payload.expiresAt = '2026-09-23T02:30:00Z';
  input.save();
}, /expired/u);
inFixture('excessive validity window', (input) => {
  input.payload.expiresAt = '2026-11-23T02:00:00Z';
  input.save();
}, /lifetime exceeds/u);
inFixture('forged mobile QA signature', (input) => {
  input.payload.googleDrive.sharedAppDataFileId = 'forged-file';
  const previous = JSON.parse(readFileSync(path.join(input.root, 'build/reports/passkey-enabled-acceptance/attestation.json'), 'utf8'));
  input.save(previous.signatures);
}, /mobileQa signature invalid/u);
inFixture('one reviewer signs both roles', (input) => {
  const trust = JSON.parse(readFileSync(path.join(input.root, 'config/passkey-enabled-acceptance-trust.json'), 'utf8'));
  trust.keys.security.publicKeyPem = `${trust.keys.mobileQa.publicKeyPem}\n`;
  write(input.root, 'config/passkey-enabled-acceptance-trust.json', trust);
}, /distinct keys/u);
inFixture('wrong reviewer role', (input) => {
  const previous = JSON.parse(readFileSync(path.join(input.root, 'build/reports/passkey-enabled-acceptance/attestation.json'), 'utf8'));
  previous.signatures[1].role = 'mobileQa';
  input.save(previous.signatures);
}, /security signature/u);

process.stdout.write(`[passkey-enabled-acceptance-test] PASS ${cases} cases\n`);
