#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
ASSOCIATION_FILE="${PASSKEY_ANDROID_ASSOCIATION_FILE:-$ROOT_DIR/fearless-site-web-app-associations-20260726/src/public/.well-known/assetlinks.json}"
EVIDENCE_FILE="${PASSKEY_DEPLOYMENT_EVIDENCE_FILE:-$ROOT_DIR/services/passkey-backup-challenge-service/scripts/production-deployment-evidence.json}"
CONFIG_FILE="${PASSKEY_BACKUP_PRODUCTION_CONFIG_FILE:-$ROOT_DIR/config/passkey-backup-production.json}"
APK_EVIDENCE_HELPER="$ROOT_DIR/scripts/extract-android-apk-signer-evidence.mjs"
REQUIRE_READY=0

if [[ "${1:-}" == "--require-ready" ]]; then
  REQUIRE_READY=1
  shift
fi
if [[ $# -ne 0 ]]; then
  echo "[passkey-android-origin-parity][error] usage: $0 [--require-ready]" >&2
  exit 2
fi

PASSKEY_ANDROID_ASSOCIATION_FILE="$ASSOCIATION_FILE" \
PASSKEY_DEPLOYMENT_EVIDENCE_FILE="$EVIDENCE_FILE" \
PASSKEY_BACKUP_PRODUCTION_CONFIG_FILE="$CONFIG_FILE" \
PASSKEY_ANDROID_APK_EVIDENCE_HELPER="$APK_EVIDENCE_HELPER" \
PASSKEY_ANDROID_ORIGIN_REQUIRE_READY="$REQUIRE_READY" \
node <<'NODE'
const childProcess = require('child_process');
const crypto = require('crypto');
const fs = require('fs');
const os = require('os');
const path = require('path');

const associationFile = process.env.PASSKEY_ANDROID_ASSOCIATION_FILE;
const evidenceFile = process.env.PASSKEY_DEPLOYMENT_EVIDENCE_FILE;
const configFile = process.env.PASSKEY_BACKUP_PRODUCTION_CONFIG_FILE;
const apkEvidenceHelper = process.env.PASSKEY_ANDROID_APK_EVIDENCE_HELPER;
const configuredOrigin = process.env.PASSKEY_ANDROID_ALLOWED_ORIGIN;
const releaseSignerFingerprint = process.env.PASSKEY_ANDROID_RELEASE_SIGNER_SHA256_FINGERPRINT;
const releaseSignerEvidenceSource = process.env.PASSKEY_ANDROID_RELEASE_SIGNER_EVIDENCE_SOURCE;
const distributedApkFile = process.env.PASSKEY_ANDROID_DISTRIBUTED_APK_FILE;
const playAttestationFile = process.env.PASSKEY_ANDROID_PLAY_APP_SIGNING_ATTESTATION_FILE;
const playAttestationSha256 = process.env.PASSKEY_ANDROID_PLAY_APP_SIGNING_ATTESTATION_SHA256;
const playCertificateFile = process.env.PASSKEY_ANDROID_PLAY_APP_SIGNING_CERTIFICATE_FILE;
const playCertificateSha256 = process.env.PASSKEY_ANDROID_PLAY_APP_SIGNING_CERTIFICATE_SHA256;
const releaseArtifactFile = process.env.PASSKEY_ANDROID_RELEASE_ARTIFACT_FILE;
const releaseArtifactSha256 = process.env.PASSKEY_ANDROID_RELEASE_ARTIFACT_SHA256;
const requireReady = process.env.PASSKEY_ANDROID_ORIGIN_REQUIRE_READY === '1';
const EXPECTED_PACKAGE = 'jp.co.soramitsu.fearless';
const EXPECTED_FINGERPRINT =
  'CC:17:CB:D4:30:43:22:C5:8E:27:89:03:45:E6:00:9B:28:17:B7:7E:A2:3D:85:FF:DB:E3:33:8C:57:F3:62:C3';
const EXPECTED_ORIGIN =
  'android:apk-key-hash:zBfL1DBDIsWOJ4kDReYAmygXt36iPYX_2-MzjFfzYsM';
const FINGERPRINT_RE = /^(?:[0-9A-F]{2}:){31}[0-9A-F]{2}$/u;
const ANDROID_ORIGIN_RE = /^android:apk-key-hash:[A-Za-z0-9_-]{43}$/u;
const ALLOWED_SIGNER_EVIDENCE_SOURCES = new Set([
  'distributed-apk',
  'play-app-signing-certificate',
]);
const MAX_FILE_BYTES = 64 * 1024;
const MAX_RELEASE_ARTIFACT_BYTES = 1024 * 1024 * 1024;
const MAX_PLAY_ATTESTATION_AGE_MS = 30 * 24 * 60 * 60 * 1000;
const MAX_CLOCK_SKEW_MS = 5 * 60 * 1000;
const PLAY_ATTESTATION_FIELDS = [
  'schemaVersion',
  'source',
  'packageName',
  'artifactType',
  'artifactSha256',
  'versionCode',
  'certificateSha256Fingerprint',
  'certificateFileSha256',
  'issuedAt',
  'playConsoleReleaseId',
];

function fail(message) {
  console.error(`[passkey-android-origin-parity][error] ${message}`);
  process.exit(1);
}

function readJson(file, label) {
  let stat;
  try {
    stat = fs.lstatSync(file);
  } catch (error) {
    fail(`${label} missing: ${file}`);
  }
  if (!stat.isFile() || stat.isSymbolicLink()) fail(`${label} must be a regular non-symlink file`);
  if (stat.size === 0 || stat.size > MAX_FILE_BYTES) fail(`${label} must be 1-${MAX_FILE_BYTES} bytes`);
  try {
    return JSON.parse(fs.readFileSync(file, 'utf8'));
  } catch (error) {
    fail(`${label} must be valid JSON: ${error.message}`);
  }
}

function regularFileStat(file, label, maxBytes, { immutable = false } = {}) {
  if (typeof file !== 'string' || !path.isAbsolute(file) || file !== file.trim()) {
    fail(`${label} path must be absolute and whitespace-free`);
  }
  let stat;
  let realPath;
  try {
    stat = fs.lstatSync(file);
    realPath = fs.realpathSync.native(file);
  } catch {
    fail(`${label} missing: ${file}`);
  }
  if (!stat.isFile() || stat.isSymbolicLink() || realPath !== file) {
    fail(`${label} must be a regular non-symlink file`);
  }
  if (stat.size <= 0 || stat.size > maxBytes) fail(`${label} must be 1-${maxBytes} bytes`);
  if (immutable && (stat.mode & 0o222) !== 0) {
    fail(`${label} must be immutable at audit time (chmod a-w)`);
  }
  return stat;
}

function sha256File(file) {
  const hash = crypto.createHash('sha256');
  const buffer = Buffer.allocUnsafe(1024 * 1024);
  const descriptor = fs.openSync(file, 'r');
  try {
    for (;;) {
      const bytesRead = fs.readSync(descriptor, buffer, 0, buffer.length, null);
      if (bytesRead === 0) break;
      hash.update(buffer.subarray(0, bytesRead));
    }
  } finally {
    fs.closeSync(descriptor);
  }
  return `sha256:${hash.digest('hex')}`;
}

function requireSha256(value, label) {
  if (!/^sha256:[0-9a-f]{64}$/u.test(String(value ?? ''))) {
    fail(`${label} must be canonical sha256:<64-lowercase-hex>`);
  }
}

function timestampMillis(value) {
  if (typeof value !== 'string' || !/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$/u.test(value)) return null;
  const millis = Date.parse(value);
  if (!Number.isFinite(millis)) return null;
  return new Date(millis).toISOString() === value.replace(/Z$/u, '.000Z') ? millis : null;
}

function findAndroidBuildTools() {
  const sdkRoots = [
    process.env.ANDROID_HOME,
    process.env.ANDROID_SDK_ROOT,
    path.join(os.homedir(), 'Library', 'Android', 'sdk'),
    path.join(os.homedir(), 'Android', 'Sdk'),
  ].filter((value, index, values) => value && values.indexOf(value) === index);
  const candidates = [];
  for (const sdkRoot of sdkRoots) {
    const buildTools = path.join(sdkRoot, 'build-tools');
    let versions;
    try {
      versions = fs.readdirSync(buildTools, { withFileTypes: true })
        .filter((entry) => entry.isDirectory() && /^\d+(?:\.\d+){1,3}(?:-[A-Za-z0-9.-]+)?$/u.test(entry.name))
        .map((entry) => entry.name);
    } catch {
      continue;
    }
    for (const version of versions) {
      const directory = path.join(buildTools, version);
      const apksigner = path.join(directory, 'apksigner');
      const aapt = path.join(directory, 'aapt');
      const aapt2 = path.join(directory, 'aapt2');
      if (fs.existsSync(apksigner) && fs.existsSync(aapt) && fs.existsSync(aapt2)) {
        candidates.push({ version, apksigner, aapt, aapt2 });
      }
    }
  }
  candidates.sort((left, right) => right.version.localeCompare(left.version, 'en', { numeric: true }));
  if (candidates.length === 0) {
    fail('distributed APK evidence requires Android SDK build-tools containing apksigner and aapt');
  }
  return candidates[0];
}

function distributedApkEvidence() {
  if (distributedApkFile === undefined) {
    fail('distributed-apk evidence requires PASSKEY_ANDROID_DISTRIBUTED_APK_FILE');
  }
  if (releaseArtifactSha256 === undefined) {
    fail('distributed-apk evidence requires PASSKEY_ANDROID_RELEASE_ARTIFACT_SHA256');
  }
  requireSha256(releaseArtifactSha256, 'PASSKEY_ANDROID_RELEASE_ARTIFACT_SHA256');
  if (playAttestationFile !== undefined || playAttestationSha256 !== undefined ||
      playCertificateFile !== undefined || playCertificateSha256 !== undefined ||
      releaseArtifactFile !== undefined) {
    fail('distributed-apk evidence must not include Play app-signing attestation inputs');
  }
  const tools = findAndroidBuildTools();
  let output;
  try {
    output = childProcess.execFileSync(
      process.execPath,
      [apkEvidenceHelper, '--apk', distributedApkFile, '--apksigner', tools.apksigner, '--aapt', tools.aapt],
      { encoding: 'utf8', maxBuffer: 1024 * 1024, timeout: 60_000, stdio: ['ignore', 'pipe', 'pipe'] },
    );
  } catch (error) {
    const detail = String(error.stderr || '').trim().replace(/\s+/gu, ' ').slice(0, 700);
    fail(`distributed APK signer extraction failed${detail ? `: ${detail}` : ''}`);
  }
  let result;
  try {
    result = JSON.parse(output);
  } catch {
    fail('distributed APK signer extraction returned malformed evidence');
  }
  if (result?.source !== 'distributed-apk' || result.packageName !== EXPECTED_PACKAGE) {
    fail('distributed APK signer extraction returned the wrong artifact identity');
  }
  requireSha256(result.artifactSha256, 'derived distributed APK artifact digest');
  if (result.artifactSha256 !== releaseArtifactSha256) {
    fail('distributed APK artifact digest does not match PASSKEY_ANDROID_RELEASE_ARTIFACT_SHA256');
  }
  return result;
}

function inspectAabIdentity(file) {
  const tools = findAndroidBuildTools();
  const maxEntryBytes = 8 * 1024 * 1024;
  let entries;
  try {
    entries = childProcess.execFileSync('/usr/bin/unzip', ['-Z1', file], {
      encoding: 'utf8', maxBuffer: 8 * 1024 * 1024, timeout: 30_000,
      stdio: ['ignore', 'pipe', 'pipe'],
    }).trim().split('\n').filter(Boolean);
  } catch {
    fail('Play release artifact must expose a bounded canonical AAB entry list');
  }
  if (entries.length === 0 || entries.length > 100_000 || new Set(entries).size !== entries.length) {
    fail('Play release artifact must contain a non-empty unique bounded AAB entry list');
  }
  for (const requiredEntry of ['BundleConfig.pb', 'base/manifest/AndroidManifest.xml', 'base/resources.pb']) {
    if (!entries.includes(requiredEntry)) fail(`Play release artifact missing required AAB entry ${requiredEntry}`);
  }

  const extract = (entry) => {
    try {
      return childProcess.execFileSync('/usr/bin/unzip', ['-p', file, entry], {
        encoding: null, maxBuffer: maxEntryBytes, timeout: 30_000,
        stdio: ['ignore', 'pipe', 'pipe'],
      });
    } catch {
      fail(`Play release artifact ${entry} must be a bounded readable entry`);
    }
  };
  const manifest = extract('base/manifest/AndroidManifest.xml');
  const resources = extract('base/resources.pb');
  const bundleConfig = extract('BundleConfig.pb');
  if (manifest.length === 0 || resources.length === 0 || bundleConfig.length === 0) {
    fail('Play release artifact required AAB metadata entries must be non-empty');
  }

  const tempRoot = fs.mkdtempSync(path.join(fs.realpathSync.native(os.tmpdir()), 'passkey-aab-'));
  try {
    fs.writeFileSync(path.join(tempRoot, 'AndroidManifest.xml'), manifest, { mode: 0o600 });
    fs.writeFileSync(path.join(tempRoot, 'resources.pb'), resources, { mode: 0o600 });
    const inspectionApk = path.join(tempRoot, 'identity.apk');
    try {
      childProcess.execFileSync('/usr/bin/zip', ['-q', inspectionApk, 'AndroidManifest.xml', 'resources.pb'], {
        cwd: tempRoot, stdio: ['ignore', 'ignore', 'pipe'], timeout: 30_000, maxBuffer: 1024 * 1024,
      });
    } catch {
      fail('Play release artifact identity inspection archive construction failed');
    }
    let xmlTree;
    try {
      xmlTree = childProcess.execFileSync(
        tools.aapt2,
        ['dump', 'xmltree', '--file', 'AndroidManifest.xml', inspectionApk],
        { encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'], timeout: 30_000, maxBuffer: 8 * 1024 * 1024 },
      );
    } catch {
      fail('Play release artifact base manifest must be valid compiled protobuf XML');
    }
    const packages = [...xmlTree.matchAll(/^\s*A: package="([^"]+)"/gmu)].map((match) => match[1]);
    const versionCodes = [...xmlTree.matchAll(/^\s*A: .*:versionCode\([^)]*\)=([0-9]+)/gmu)]
      .map((match) => Number(match[1]));
    if (packages.length !== 1 || packages[0] !== EXPECTED_PACKAGE) {
      fail(`Play release artifact base manifest package must be exactly ${EXPECTED_PACKAGE}`);
    }
    if (versionCodes.length !== 1 || !Number.isSafeInteger(versionCodes[0]) || versionCodes[0] <= 0) {
      fail('Play release artifact base manifest must contain one positive versionCode');
    }
    return { packageName: packages[0], versionCode: versionCodes[0] };
  } finally {
    fs.rmSync(tempRoot, { recursive: true, force: true });
  }
}

function playAppSigningEvidence() {
  if (distributedApkFile !== undefined) {
    fail('play-app-signing-certificate evidence must not include PASSKEY_ANDROID_DISTRIBUTED_APK_FILE');
  }
  if (playAttestationFile === undefined || playAttestationSha256 === undefined ||
      playCertificateFile === undefined || playCertificateSha256 === undefined ||
      releaseArtifactFile === undefined || releaseArtifactSha256 === undefined) {
    fail(
      'play-app-signing-certificate evidence requires immutable X.509 certificate, attestation, and release artifact files with digests',
    );
  }
  regularFileStat(playAttestationFile, 'Play app-signing attestation', MAX_FILE_BYTES, { immutable: true });
  regularFileStat(playCertificateFile, 'Play app-signing X.509 certificate', 1024 * 1024, { immutable: true });
  regularFileStat(releaseArtifactFile, 'Play release artifact', MAX_RELEASE_ARTIFACT_BYTES, { immutable: true });
  if (path.extname(releaseArtifactFile) !== '.aab') {
    fail('Play release artifact path must end in lowercase .aab; distributed APKs use distributed-apk evidence');
  }
  requireSha256(playAttestationSha256, 'PASSKEY_ANDROID_PLAY_APP_SIGNING_ATTESTATION_SHA256');
  requireSha256(playCertificateSha256, 'PASSKEY_ANDROID_PLAY_APP_SIGNING_CERTIFICATE_SHA256');
  requireSha256(releaseArtifactSha256, 'PASSKEY_ANDROID_RELEASE_ARTIFACT_SHA256');
  const derivedAttestationSha256 = sha256File(playAttestationFile);
  if (derivedAttestationSha256 !== playAttestationSha256) {
    fail('Play app-signing attestation digest does not match the immutable attestation file');
  }
  const derivedCertificateSha256 = sha256File(playCertificateFile);
  if (derivedCertificateSha256 !== playCertificateSha256) {
    fail('Play app-signing certificate digest does not match the immutable X.509 certificate file');
  }
  let certificate;
  try {
    const certificateBytes = fs.readFileSync(playCertificateFile);
    const certificateText = certificateBytes.toString('utf8');
    if (certificateText.includes('-----BEGIN CERTIFICATE-----')) {
      const pemBlocks = certificateText.match(/-----BEGIN CERTIFICATE-----[\s\S]*?-----END CERTIFICATE-----/gu) || [];
      if (pemBlocks.length !== 1 || certificateText.trim() !== pemBlocks[0]) {
        fail('Play app-signing certificate PEM must contain exactly one X.509 certificate and no extra content');
      }
    }
    certificate = new crypto.X509Certificate(certificateBytes);
  } catch (error) {
    if (String(error.message).startsWith('Play app-signing certificate PEM')) throw error;
    fail('Play app-signing certificate file must contain one valid DER or PEM X.509 certificate');
  }
  const derivedCertificateFingerprint = certificate.fingerprint256;
  if (!FINGERPRINT_RE.test(String(derivedCertificateFingerprint ?? ''))) {
    fail('Play app-signing X.509 certificate must expose a canonical SHA-256 fingerprint');
  }
  const derivedArtifactSha256 = sha256File(releaseArtifactFile);
  if (derivedArtifactSha256 !== releaseArtifactSha256) {
    fail('Play release artifact digest does not match the actual release artifact');
  }
  try {
    childProcess.execFileSync('/usr/bin/unzip', ['-tqq', releaseArtifactFile], {
      stdio: ['ignore', 'ignore', 'pipe'], timeout: 30_000, maxBuffer: 1024 * 1024,
    });
  } catch {
    fail('Play release artifact must be a valid AAB ZIP archive');
  }
  const artifactIdentity = inspectAabIdentity(releaseArtifactFile);
  if (sha256File(releaseArtifactFile) !== derivedArtifactSha256) {
    fail('Play release artifact changed during identity inspection');
  }

  const raw = fs.readFileSync(playAttestationFile, 'utf8');
  let attestation;
  try {
    attestation = JSON.parse(raw);
  } catch (error) {
    fail(`Play app-signing attestation must be valid JSON: ${error.message}`);
  }
  if (!attestation || typeof attestation !== 'object' || Array.isArray(attestation)) {
    fail('Play app-signing attestation must be an object');
  }
  const keys = Object.keys(attestation);
  if (keys.length !== PLAY_ATTESTATION_FIELDS.length ||
      !PLAY_ATTESTATION_FIELDS.every((field) => keys.includes(field))) {
    fail('Play app-signing attestation must contain exactly the reviewed schema fields');
  }
  if (raw !== `${JSON.stringify(attestation, null, 2)}\n`) {
    fail('Play app-signing attestation must use canonical two-space JSON with one trailing newline');
  }
  if (attestation.schemaVersion !== 1 || attestation.source !== 'play-app-signing-certificate' ||
      attestation.packageName !== EXPECTED_PACKAGE || attestation.artifactType !== 'aab') {
    fail('Play app-signing attestation identity must match the Fearless AAB release');
  }
  if (!Number.isSafeInteger(attestation.versionCode) || attestation.versionCode <= 0) {
    fail('Play app-signing attestation versionCode must be a positive integer');
  }
  if (attestation.packageName !== artifactIdentity.packageName ||
      attestation.versionCode !== artifactIdentity.versionCode) {
    fail('Play app-signing attestation packageName/versionCode must bind the compiled AAB base manifest');
  }
  if (!/^[A-Za-z0-9._:-]{8,128}$/u.test(String(attestation.playConsoleReleaseId ?? ''))) {
    fail('Play app-signing attestation playConsoleReleaseId must be a stable public identifier');
  }
  const issuedAt = timestampMillis(attestation.issuedAt);
  if (issuedAt === null) fail('Play app-signing attestation issuedAt must be an ISO-8601 UTC second timestamp');
  const now = Date.now();
  if (issuedAt > now + MAX_CLOCK_SKEW_MS) fail('Play app-signing attestation issuedAt must not be in the future');
  if (now - issuedAt > MAX_PLAY_ATTESTATION_AGE_MS) {
    fail('Play app-signing attestation must be no more than 30 days old');
  }
  if (attestation.artifactSha256 !== derivedArtifactSha256) {
    fail('Play app-signing attestation artifactSha256 must bind the actual release artifact digest');
  }
  if (attestation.certificateFileSha256 !== derivedCertificateSha256) {
    fail('Play app-signing attestation certificateFileSha256 must bind the immutable X.509 certificate bytes');
  }
  if (!FINGERPRINT_RE.test(String(attestation.certificateSha256Fingerprint ?? ''))) {
    fail('Play app-signing attestation certificate fingerprint must be canonical uppercase colon-delimited SHA-256');
  }
  if (attestation.certificateSha256Fingerprint !== derivedCertificateFingerprint) {
    fail('Play app-signing attestation certificate fingerprint must be derived from the X.509 certificate file');
  }
  const certificateValidFrom = Date.parse(certificate.validFrom);
  const certificateValidTo = Date.parse(certificate.validTo);
  if (!Number.isFinite(certificateValidFrom) || !Number.isFinite(certificateValidTo) ||
      issuedAt < certificateValidFrom || issuedAt > certificateValidTo ||
      now < certificateValidFrom || now > certificateValidTo) {
    fail('Play app-signing X.509 certificate must be valid at attestation issue time and audit time');
  }
  return {
    source: 'play-app-signing-certificate',
    packageName: attestation.packageName,
    artifactSha256: derivedArtifactSha256,
    signerSha256Fingerprint: derivedCertificateFingerprint,
    attestationSha256: derivedAttestationSha256,
    certificateSha256: derivedCertificateSha256,
  };
}

function originFromFingerprint(fingerprint) {
  if (typeof fingerprint !== 'string' || !FINGERPRINT_RE.test(fingerprint)) {
    fail('Android release certificate fingerprint must be canonical uppercase colon-delimited SHA-256');
  }
  const digest = Buffer.from(fingerprint.replaceAll(':', ''), 'hex');
  if (digest.length !== 32) fail('Android release certificate fingerprint must contain 32 bytes');
  return `android:apk-key-hash:${digest.toString('base64url')}`;
}

function requireCanonicalOrigin(origin, label) {
  if (typeof origin !== 'string' || !ANDROID_ORIGIN_RE.test(origin)) {
    fail(`${label} must be a canonical android:apk-key-hash origin`);
  }
  const digest = origin.slice('android:apk-key-hash:'.length);
  const decoded = Buffer.from(digest, 'base64url');
  if (decoded.length !== 32 || decoded.toString('base64url') !== digest) {
    fail(`${label} must contain an unpadded canonical base64url SHA-256 digest`);
  }
}

const associations = readJson(associationFile, 'Android association file');
if (!Array.isArray(associations)) fail('Android association file must contain an array');
const matching = associations.filter((entry) =>
  entry?.target?.namespace === 'android_app' && entry.target.package_name === EXPECTED_PACKAGE);
if (matching.length !== 1) fail(`Android association file must contain exactly one ${EXPECTED_PACKAGE} target`);
const association = matching[0];
if (!Array.isArray(association.relation) ||
    !association.relation.includes('delegate_permission/common.get_login_creds')) {
  fail('Android association must grant delegate_permission/common.get_login_creds');
}
const fingerprints = association.target.sha256_cert_fingerprints;
if (!Array.isArray(fingerprints) || fingerprints.length !== 1) {
  fail('Android association must contain exactly one reviewed release certificate fingerprint');
}
const fingerprint = fingerprints[0];
if (fingerprint !== EXPECTED_FINGERPRINT) {
  fail(`Android association fingerprint drifted from the reviewed public release association: ${fingerprint}`);
}
const derivedOrigin = originFromFingerprint(fingerprint);
if (derivedOrigin !== EXPECTED_ORIGIN) fail('Android association fingerprint origin derivation drifted');
requireCanonicalOrigin(derivedOrigin, 'derived Android origin');

const productionConfig = readJson(configFile, 'passkey production config');
const expectedAllowedOrigins = [
  'https://fearlesswallet.io',
  'https://backup.fearlesswallet.io',
  derivedOrigin,
];
if (JSON.stringify(productionConfig.webauthnAllowedOrigins) !== JSON.stringify(expectedAllowedOrigins)) {
  fail('passkey production config webauthnAllowedOrigins must contain the exact reviewed origins');
}
requireCanonicalOrigin(productionConfig?.android?.webauthnOrigin, 'passkey production config Android origin');
if (productionConfig.android.webauthnOrigin !== derivedOrigin) {
  fail('passkey production config Android origin does not match the public Digital Asset Links fingerprint');
}
if (productionConfig.releaseEnabled !== false || productionConfig.android.releaseEnabled !== false ||
    productionConfig?.ios?.releaseEnabled !== false) {
  fail('passkey production config release flags must remain disabled');
}

if (configuredOrigin !== undefined) {
  requireCanonicalOrigin(configuredOrigin, 'PASSKEY_ANDROID_ALLOWED_ORIGIN');
  if (configuredOrigin !== derivedOrigin) {
    fail('PASSKEY_ANDROID_ALLOWED_ORIGIN does not match the public Digital Asset Links fingerprint');
  }
}

if (releaseSignerEvidenceSource !== undefined &&
    !ALLOWED_SIGNER_EVIDENCE_SOURCES.has(releaseSignerEvidenceSource)) {
  fail(
    'PASSKEY_ANDROID_RELEASE_SIGNER_EVIDENCE_SOURCE must be exactly distributed-apk or ' +
    'play-app-signing-certificate; AAB and upload-key evidence are not accepted',
  );
}
if (releaseSignerEvidenceSource !== undefined && releaseSignerFingerprint === undefined) {
  fail(
    'PASSKEY_ANDROID_RELEASE_SIGNER_EVIDENCE_SOURCE requires ' +
    'PASSKEY_ANDROID_RELEASE_SIGNER_SHA256_FINGERPRINT',
  );
}
if (releaseSignerFingerprint !== undefined && releaseSignerEvidenceSource === undefined) {
  fail(
    'PASSKEY_ANDROID_RELEASE_SIGNER_SHA256_FINGERPRINT requires ' +
    'PASSKEY_ANDROID_RELEASE_SIGNER_EVIDENCE_SOURCE',
  );
}

const artifactInputsPresent = [
  distributedApkFile,
  playAttestationFile,
  playAttestationSha256,
  playCertificateFile,
  playCertificateSha256,
  releaseArtifactFile,
  releaseArtifactSha256,
].some((value) => value !== undefined);
if (releaseSignerEvidenceSource === undefined && artifactInputsPresent) {
  fail('signer artifact inputs require PASSKEY_ANDROID_RELEASE_SIGNER_EVIDENCE_SOURCE');
}

let derivedSignerEvidence;
if (releaseSignerEvidenceSource === 'distributed-apk') {
  derivedSignerEvidence = distributedApkEvidence();
} else if (releaseSignerEvidenceSource === 'play-app-signing-certificate') {
  derivedSignerEvidence = playAppSigningEvidence();
}

if (derivedSignerEvidence !== undefined) {
  if (releaseSignerFingerprint !== derivedSignerEvidence.signerSha256Fingerprint) {
    fail('declared distribution signer fingerprint does not match the artifact-derived signer fingerprint');
  }
  if (releaseArtifactSha256 !== undefined &&
      releaseArtifactSha256 !== derivedSignerEvidence.artifactSha256) {
    fail('declared release artifact digest does not match the artifact-derived digest');
  }
  const signerOrigin = originFromFingerprint(derivedSignerEvidence.signerSha256Fingerprint);
  if (signerOrigin !== derivedOrigin) {
    fail(
      'distribution signer evidence does not match the public Digital Asset Links fingerprint',
    );
  }
}

const evidence = readJson(evidenceFile, 'passkey deployment evidence');
const records = evidence.deploymentEvidence;
if (!Array.isArray(records)) fail('passkey deployment evidence deploymentEvidence must be an array');
for (const [index, record] of records.entries()) {
  const origins = record?.webauthnAllowedOrigins;
  if (!Array.isArray(origins)) {
    fail(`deploymentEvidence[${index}].webauthnAllowedOrigins must be an array`);
  }
  const androidOrigins = origins.filter((origin) =>
    typeof origin === 'string' && origin.startsWith('android:apk-key-hash:'));
  if (androidOrigins.length !== 1) {
    fail(`deploymentEvidence[${index}] must contain exactly one Android WebAuthn origin`);
  }
  requireCanonicalOrigin(androidOrigins[0], `deploymentEvidence[${index}] Android origin`);
  if (androidOrigins[0] !== derivedOrigin) {
    fail(`deploymentEvidence[${index}] Android origin does not match the public Digital Asset Links fingerprint`);
  }
}

const ready = evidence.status === 'ready' || evidence.releaseEnabled === true;
if (ready && records.length === 0) fail('ready deployment evidence requires an origin evidence record');
if (requireReady) {
  if (!ready) fail('--require-ready requires ready passkey deployment evidence');
  if (configuredOrigin === undefined) fail('--require-ready requires PASSKEY_ANDROID_ALLOWED_ORIGIN');
  if (releaseSignerFingerprint === undefined) {
    fail(
      '--require-ready requires PASSKEY_ANDROID_RELEASE_SIGNER_SHA256_FINGERPRINT from an ' +
      'independently obtained distribution signer',
    );
  }
  if (releaseSignerEvidenceSource === undefined) {
    fail(
      '--require-ready requires PASSKEY_ANDROID_RELEASE_SIGNER_EVIDENCE_SOURCE=' +
      'distributed-apk or play-app-signing-certificate',
    );
  }
  if (derivedSignerEvidence === undefined) {
    fail('--require-ready requires signer evidence derived from an actual release artifact');
  }
}

console.log(`[passkey-android-origin-parity] verified ${derivedOrigin}`);
if (derivedSignerEvidence === undefined) {
  console.log('[passkey-android-origin-parity] distribution signer evidence remains external; passkey flags must stay disabled.');
} else {
  console.log(
    `[passkey-android-origin-parity] verified artifact-derived signer source ${releaseSignerEvidenceSource} ` +
    `for ${derivedSignerEvidence.artifactSha256}.`,
  );
}
NODE
