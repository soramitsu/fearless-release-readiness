#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SERVICE_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
EVIDENCE_FILE="$SCRIPT_DIR/production-deployment-evidence.json"
REQUIRE_READY=0

usage() {
  cat <<'USAGE'
Usage: bash scripts/audit-deployment-evidence.sh [--require-ready] [--evidence <file>]

Validates production deployment evidence for backup.fearlesswallet.io.
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --require-ready)
      REQUIRE_READY=1
      shift
      ;;
    --evidence)
      EVIDENCE_FILE="${2:-}"
      if [[ -z "$EVIDENCE_FILE" ]]; then
        echo "[passkey-deployment-evidence][error] --evidence requires a file path" >&2
        exit 2
      fi
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "[passkey-deployment-evidence][error] unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [[ ! -f "$EVIDENCE_FILE" ]]; then
  echo "[passkey-deployment-evidence][error] production deployment evidence missing: $EVIDENCE_FILE" >&2
  exit 1
fi

PASSKEY_DEPLOYMENT_EVIDENCE_FILE="$EVIDENCE_FILE" \
PASSKEY_DEPLOYMENT_ROOT="$SERVICE_ROOT" \
PASSKEY_DEPLOYMENT_REQUIRE_READY="$REQUIRE_READY" \
node <<'NODE'
const childProcess = require('child_process');
const crypto = require('crypto');
const fs = require('fs');
const os = require('os');
const path = require('path');

const evidencePath = process.env.PASSKEY_DEPLOYMENT_EVIDENCE_FILE;
const deploymentRoot = process.env.PASSKEY_DEPLOYMENT_ROOT;
const requireReady = process.env.PASSKEY_DEPLOYMENT_REQUIRE_READY === '1';
const expectedCommitOverride = process.env.PASSKEY_DEPLOYMENT_EXPECTED_COMMIT;
const deploymentGhBin = process.env.PASSKEY_DEPLOYMENT_GH_BIN;
const EXPECTED_BASE_URL = 'https://backup.fearlesswallet.io';
const EXPECTED_HEALTH_URL = `${EXPECTED_BASE_URL}/api/passkey-backup/v1/health`;
const EXPECTED_SERVICE = 'fearless-passkey-backup';
const EXPECTED_RP_ID = 'fearlesswallet.io';
const EXPECTED_IMAGE = 'passkey-backup-challenge-service';
const EXPECTED_IMAGE_REPOSITORY = 'ghcr.io/soramitsu/fearless-passkey-backup';
const EXPECTED_IMAGE_PUBLICATION_WORKFLOW = '.github/workflows/passkey-image-publish.yml';
const EXPECTED_PUBLICATION_REPOSITORY = 'soramitsu/fearless-release-readiness';
const EXPECTED_PUBLICATION_BRANCH = 'main';
const EXPECTED_PUBLICATION_EVENT = 'workflow_dispatch';
const EXPECTED_PUBLICATION_SOURCE_REF = 'refs/heads/main';
const EXPECTED_PROVENANCE_PREDICATE_TYPE = 'https://slsa.dev/provenance/v1';
const GITHUB_API_VERSION = '2026-03-10';
const EXPECTED_PUBLICATION_SIGNER_WORKFLOW =
  `${EXPECTED_PUBLICATION_REPOSITORY}/${EXPECTED_IMAGE_PUBLICATION_WORKFLOW}`;
const EXPECTED_IMAGE_PUBLICATION_COMMAND =
  'gh workflow run passkey-image-publish.yml --repo soramitsu/fearless-release-readiness --ref main -f source_commit=<protected-main-commit>';
const EXPECTED_IMAGE_PUBLICATION_RUN_URL =
  /^https:\/\/github\.com\/soramitsu\/fearless-release-readiness\/actions\/runs\/[1-9][0-9]*$/u;
const EXPECTED_IMAGE_PROVENANCE_ATTESTATION_URL =
  /^https:\/\/github\.com\/soramitsu\/fearless-release-readiness\/attestations\/[1-9][0-9]*$/u;
const EXPECTED_LIVE_HEALTH =
  'PASSKEY_BACKUP_LIVE_HEALTH=1 PASSKEY_BACKUP_HEALTH_TIMEOUT_SECONDS=10 bash ../../scripts/audit-passkey-backup-prerequisites.sh';
const EXPECTED_SMOKE =
  'PASSKEY_BACKUP_BASE_URL=https://backup.fearlesswallet.io PASSKEY_BACKUP_SMOKE_GRANT_HELPER=/run/secrets/passkey-smoke-grant-helper PASSKEY_BACKUP_SMOKE_TIMEOUT_MS=10000 npm run smoke:production';
const EXPECTED_VOLUME = '/data/passkey-backup';
const EXPECTED_FILE = '/data/passkey-backup/credentials.json';
const EXPECTED_HTTPS_ORIGINS = ['https://fearlesswallet.io', 'https://backup.fearlesswallet.io'];
const ANDROID_ORIGIN_PREFIX = 'android:apk-key-hash:';
const MAX_CLOCK_SKEW_MS = 5 * 60 * 1000;
const MAX_READY_EVIDENCE_AGE_MS = 24 * 60 * 60 * 1000;
// Read once, at second precision, so every record in one audit is evaluated
// against the same clock and ISO-8601 second boundary.
const auditStartedAtMs = Math.floor(Date.now() / 1000) * 1000;
const REQUIRED_COMMANDS = [
  'npm run lint:syntax',
  'npm test',
  'npm run test:deployment-evidence-template',
  'npm run generate:deployment-evidence-template -- --output build/reports/production-deployment-evidence-template.json',
  'npm run test:deployment-evidence-audit',
  'npm run audit:deployment-evidence',
  EXPECTED_IMAGE_PUBLICATION_COMMAND,
  EXPECTED_LIVE_HEALTH,
  EXPECTED_SMOKE,
  'npm run audit:deployment-evidence -- --require-ready',
];
const REQUIRED_BLOCKERS = [
  'production-deployment-evidence-missing',
  'live-health-failing',
  'platform-provisioning-incomplete',
  'request-access-introspection-unprovisioned',
  'trusted-proxy-evidence-missing',
];
const REQUIRED_FIELDS = [
  'imageRepository',
  'imageDigest',
  'imagePublicationRunUrl',
  'imageProvenanceAttestationUrl',
  'deploymentId',
  'deployedCommit',
  'deployedAt',
  'operator',
  'smokePassedAt',
  'smokeCommand',
  'healthUrl',
  'healthResponse',
  'liveHealthAttestation',
  'credentialStoreVolume',
  'credentialStoreFile',
  'webauthnAllowedOrigins',
  'requestAccessPolicy',
  'trustedProxyPolicy',
  'platformProvisioning',
  'platformProvisioningAttestation',
];
const REQUIRED_PLATFORM = [
  'androidGoogleDriveConsent',
  'androidReleaseFlagDisabled',
  'iosAssociatedDomain',
  'iosCloudKitProductionSchema',
  'iosReleaseFlagDisabled',
];
const ALLOWED_TOP_LEVEL_FIELDS = [
  'schemaVersion',
  'scope',
  'service',
  'rpId',
  'baseUrl',
  'healthUrl',
  'imageName',
  'imageRepository',
  'imagePublicationWorkflow',
  'imagePublicationCommand',
  'port',
  'credentialStoreVolume',
  'credentialStoreFile',
  'status',
  'releaseEnabled',
  'blockers',
  'smokeCommand',
  'requiredCommands',
  'requiredEvidenceFields',
  'deploymentEvidence',
];
const ALLOWED_HEALTH_FIELDS = ['ok', 'service', 'rpId', 'schemaVersion'];
const REQUIRED_ATTESTATION_FIELDS = [
  'deploymentId',
  'deployedCommit',
  'imageDigest',
  'observedAt',
  'payloadSha256',
];
const REQUIRED_ACCESS_POLICY = [
  'introspectionUrl',
  'audience',
  'mode',
  'allPostRoutesProtected',
  'stableCrossPlatformWalletSubject',
  'authorizedSmokePassed',
  'noRawSubjectPersisted',
  'credentialLifecycleSmokePassed',
  'ownerTombstonePersistencePassed',
  'crossSubjectTakeoverDenied',
  'sameOwnerReregistrationPassed',
  'cloudDeleteRevokesServerFirst',
  'listExcludesVerificationMaterial',
];
const REQUIRED_PROXY_POLICY = [
  'hops',
  'forwardedHeader',
  'directPeerAllowlistConfigured',
  'incomingHeaderSanitized',
  'directPublicAccessBlocked',
  'adversarialProxyTestsPassed',
];
const SECRET_KEY_PATTERN =
  /(?:secret|password|token|private[_-]?key|authorization|cookie|credentialStoreSnapshot|credentialsByStorageKey|clientDataJSON)/iu;
const SECRET_VALUE_PATTERN =
  /(?:AKIA[0-9A-Z]{16}|gh[pousr]_[A-Za-z0-9_]{20,}|sk-[A-Za-z0-9_-]{20,}|xox[baprs]-[A-Za-z0-9-]{10,})/u;

function fail(message) {
  console.error(`[passkey-deployment-evidence][error] ${message}`);
  process.exitCode = 1;
}

function isRecord(value) {
  return value && typeof value === 'object' && !Array.isArray(value);
}

function assert(condition, message) {
  if (!condition) fail(message);
}

function parseJson(file) {
  try {
    return JSON.parse(fs.readFileSync(file, 'utf8'));
  } catch (error) {
    fail(`production deployment evidence must be valid JSON: ${error.message}`);
    return null;
  }
}

function hasAllStrings(actual, expected) {
  return Array.isArray(actual) && expected.every((entry) => actual.includes(entry));
}

function validTimestamp(value) {
  return timestampMillis(value) !== null;
}

function isRepeatedHexPlaceholder(value) {
  const hex = String(value ?? '').replace(/^sha256:/u, '');
  return /^[0-9a-f]+$/u.test(hex) && new Set(hex).size === 1;
}

function isTemplatePlaceholder(value) {
  const raw = String(value ?? '').trim();
  const normalized = raw.toUpperCase();
  return (
    normalized.length === 0 ||
    normalized.startsWith('TODO_') ||
    normalized.startsWith('REPLACE_WITH_') ||
    normalized.includes('PLACEHOLDER') ||
    /^(todo|tbd|placeholder|example|sample|dummy|unknown|n\/a)(?:$|[._\-\s:])/u.test(raw.toLowerCase())
  );
}

function timestampMillis(value) {
  if (typeof value !== 'string' || !/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$/u.test(value)) {
    return null;
  }
  const millis = Date.parse(value);
  if (!Number.isFinite(millis)) return null;
  return new Date(millis).toISOString() === value.replace(/Z$/u, '.000Z') ? millis : null;
}

function isFutureTimestamp(value) {
  const millis = timestampMillis(value);
  return Number.isFinite(millis) && millis > auditStartedAtMs + MAX_CLOCK_SKEW_MS;
}

function sha256Json(value) {
  return `sha256:${crypto.createHash('sha256').update(JSON.stringify(value), 'utf8').digest('hex')}`;
}

function isGitCommit(value) {
  return /^[0-9a-f]{40}$/u.test(String(value ?? ''));
}

function expectedDeploymentCommitResult() {
  if (expectedCommitOverride !== undefined && expectedCommitOverride !== '') {
    if (!isGitCommit(expectedCommitOverride)) {
      return {
        error: 'PASSKEY_DEPLOYMENT_EXPECTED_COMMIT must be a 40-character lowercase git commit',
      };
    }
    return { commit: expectedCommitOverride };
  }

  try {
    const commit = childProcess.execFileSync('git', ['-C', deploymentRoot, 'rev-parse', 'HEAD'], {
      encoding: 'utf8',
      stdio: ['ignore', 'pipe', 'pipe'],
    }).trim();
    if (isGitCommit(commit)) {
      return { commit };
    }
    return {
      error: `PASSKEY_DEPLOYMENT_EXPECTED_COMMIT must be set because repository HEAD was not a 40-character lowercase git commit: ${commit}`,
    };
  } catch (error) {
    const detail = String(error.stderr || error.message || error).trim();
    return {
      error: `PASSKEY_DEPLOYMENT_EXPECTED_COMMIT must be set because repository HEAD could not be determined${detail ? `: ${detail}` : ''}`,
    };
  }
}

function assertNoSecretLikeKeys(value, path = 'deployment evidence') {
  if (Array.isArray(value)) {
    value.forEach((entry, index) => assertNoSecretLikeKeys(entry, `${path}[${index}]`));
    return;
  }
  if (!isRecord(value)) return;
  for (const [key, nested] of Object.entries(value)) {
    const nestedPath = `${path}.${key}`;
    assert(!SECRET_KEY_PATTERN.test(key), `${nestedPath} must not be included in public deployment evidence`);
    assertNoSecretLikeKeys(nested, nestedPath);
  }
}

function assertNoSecretLikeValues(value, path = 'deployment evidence') {
  if (Array.isArray(value)) {
    value.forEach((entry, index) => assertNoSecretLikeValues(entry, `${path}[${index}]`));
    return;
  }
  if (isRecord(value)) {
    for (const [key, nested] of Object.entries(value)) {
      assertNoSecretLikeValues(nested, `${path}.${key}`);
    }
    return;
  }
  if (typeof value === 'string') {
    assert(!SECRET_VALUE_PATTERN.test(value), `${path} must not contain secret-like token`);
  }
}

function assertAllowedKeys(value, allowedKeys, path) {
  if (!isRecord(value)) return;
  const allowed = new Set(allowedKeys);
  for (const key of Object.keys(value)) {
    assert(allowed.has(key), `${path}.${key} is not supported in public deployment evidence`);
  }
}

function assertPublicOperator(value, path) {
  assert(typeof value === 'string' && value.trim().length > 0, 'operator must be a non-empty string');
  if (typeof value !== 'string') return;
  assert(!/[\u0000-\u001f\u007f]/u.test(value), 'operator must be a single-line public value');
  assert(!SECRET_VALUE_PATTERN.test(value), 'operator must not contain secret-like token');
  assert(!isTemplatePlaceholder(value), 'operator must not be a placeholder operator');
}

function matchesCanonicalPublicationUrl(value, pattern) {
  return (
    typeof value === 'string' &&
    !/[\u0000-\u001f\u007f]/u.test(value) &&
    pattern.test(value)
  );
}

function deploymentGhBinaryResult() {
  if (typeof deploymentGhBin !== 'string' || deploymentGhBin.length === 0) {
    return { error: 'PASSKEY_DEPLOYMENT_GH_BIN must be set to an absolute executable gh binary for ready evidence' };
  }
  if (!path.isAbsolute(deploymentGhBin)) {
    return { error: 'PASSKEY_DEPLOYMENT_GH_BIN must be an absolute path for ready evidence' };
  }
  if (/[\u0000-\u001f\u007f]/u.test(deploymentGhBin)) {
    return { error: 'PASSKEY_DEPLOYMENT_GH_BIN must not contain control characters' };
  }
  try {
    const stat = fs.lstatSync(deploymentGhBin);
    if (stat.isSymbolicLink()) {
      return { error: 'PASSKEY_DEPLOYMENT_GH_BIN must not be a symbolic link' };
    }
    if (!stat.isFile()) {
      return { error: 'PASSKEY_DEPLOYMENT_GH_BIN must name a regular executable file' };
    }
    fs.accessSync(deploymentGhBin, fs.constants.X_OK);
  } catch {
    return { error: 'PASSKEY_DEPLOYMENT_GH_BIN must name an existing executable file' };
  }
  return { binary: deploymentGhBin };
}

function ghErrorDetail(error) {
  return String(error?.stderr || error?.message || error || '').trim();
}

function runGh(ghBinary, args, label, options = {}) {
  let output;
  try {
    output = childProcess.execFileSync(ghBinary, args, {
      encoding: 'utf8',
      env: { ...process.env, GH_HOST: 'github.com' },
      maxBuffer: 4 * 1024 * 1024,
      stdio: ['ignore', 'pipe', 'pipe'],
      ...options,
    });
  } catch (error) {
    const detail = ghErrorDetail(error);
    throw new Error(`${label} failed${detail ? `: ${detail}` : ''}`);
  }
  return output;
}

function runGhJson(ghBinary, args, label, options) {
  const output = runGh(ghBinary, args, label, options);
  try {
    return JSON.parse(output);
  } catch (error) {
    throw new Error(`${label} response must be valid JSON: ${error.message}`);
  }
}

function githubApiArgs(endpoint) {
  return [
    'api',
    '--hostname',
    'github.com',
    '--method',
    'GET',
    '-H',
    'Accept: application/vnd.github+json',
    '-H',
    `X-GitHub-Api-Version: ${GITHUB_API_VERSION}`,
    endpoint,
  ];
}

function positiveNumericUrlId(value) {
  const id = String(value ?? '').slice(String(value ?? '').lastIndexOf('/') + 1);
  return /^[1-9][0-9]*$/u.test(id) ? id : null;
}

function assertAuthenticated(condition, prefix, message) {
  if (!condition) throw new Error(`${prefix}.${message}`);
}

function attestationIdFromBundleUrl(value) {
  if (typeof value !== 'string') return null;
  let url;
  try {
    url = new URL(value);
  } catch {
    return null;
  }
  if (url.protocol !== 'https:' || url.username || url.password || url.hash) return null;
  const match = url.pathname.match(/\/([1-9][0-9]*)\.json\.sn$/u);
  return match?.[1] ?? null;
}

function authenticatePublicationRecord(record, index, ghBinary) {
  const prefix = `deploymentEvidence[${index}]`;
  const runId = positiveNumericUrlId(record.imagePublicationRunUrl);
  const runEndpoint = `repos/${EXPECTED_PUBLICATION_REPOSITORY}/actions/runs/${runId}`;
  const run = runGhJson(ghBinary, githubApiArgs(runEndpoint), `${prefix}.imagePublicationRunUrl`);

  assertAuthenticated(isRecord(run), prefix, 'imagePublicationRunUrl GitHub API response must be an object');
  assertAuthenticated(
    Number.isSafeInteger(run.id) && run.id > 0 && String(run.id) === runId,
    prefix,
    'imagePublicationRunUrl run id must exactly match the evidence URL id',
  );
  assertAuthenticated(
    run.html_url === record.imagePublicationRunUrl,
    prefix,
    'imagePublicationRunUrl html_url must exactly match the evidence URL',
  );
  assertAuthenticated(
    isRecord(run.repository) && run.repository.full_name === EXPECTED_PUBLICATION_REPOSITORY,
    prefix,
    `imagePublicationRunUrl repository.full_name must be ${EXPECTED_PUBLICATION_REPOSITORY}`,
  );
  assertAuthenticated(
    Number.isSafeInteger(run.repository?.id) && run.repository.id > 0,
    prefix,
    'imagePublicationRunUrl repository.id must be a positive integer',
  );
  assertAuthenticated(
    isRecord(run.head_repository) && run.head_repository.full_name === EXPECTED_PUBLICATION_REPOSITORY,
    prefix,
    `imagePublicationRunUrl head_repository.full_name must be ${EXPECTED_PUBLICATION_REPOSITORY}`,
  );
  assertAuthenticated(
    run.path === EXPECTED_IMAGE_PUBLICATION_WORKFLOW,
    prefix,
    `imagePublicationRunUrl path must be ${EXPECTED_IMAGE_PUBLICATION_WORKFLOW}`,
  );
  assertAuthenticated(
    run.event === EXPECTED_PUBLICATION_EVENT,
    prefix,
    `imagePublicationRunUrl event must be ${EXPECTED_PUBLICATION_EVENT}`,
  );
  assertAuthenticated(
    run.head_branch === EXPECTED_PUBLICATION_BRANCH,
    prefix,
    `imagePublicationRunUrl head_branch must be ${EXPECTED_PUBLICATION_BRANCH}`,
  );
  assertAuthenticated(run.status === 'completed', prefix, 'imagePublicationRunUrl status must be completed');
  assertAuthenticated(run.conclusion === 'success', prefix, 'imagePublicationRunUrl conclusion must be success');
  assertAuthenticated(
    run.head_sha === record.deployedCommit,
    prefix,
    'imagePublicationRunUrl head_sha must exactly match deployedCommit',
  );

  const attestationId = positiveNumericUrlId(record.imageProvenanceAttestationUrl);
  const attestationEndpoint =
    `repos/${EXPECTED_PUBLICATION_REPOSITORY}/attestations/${record.imageDigest}` +
    '?per_page=2&predicate_type=provenance';
  const collection = runGhJson(
    ghBinary,
    githubApiArgs(attestationEndpoint),
    `${prefix}.imageDigest attestation-list GitHub API request`,
  );
  assertAuthenticated(
    isRecord(collection) && Array.isArray(collection.attestations),
    prefix,
    'imageDigest attestation-list response must contain an attestations array',
  );
  assertAuthenticated(
    collection.attestations.length === 1,
    prefix,
    'imageDigest must resolve to exactly one provenance attestation',
  );
  const listedAttestation = collection.attestations[0];
  assertAuthenticated(
    isRecord(listedAttestation),
    prefix,
    'imageDigest provenance attestation entry must be an object',
  );
  assertAuthenticated(
    Number.isSafeInteger(listedAttestation.repository_id) &&
      listedAttestation.repository_id === run.repository.id,
    prefix,
    'imageDigest provenance attestation repository_id must match the authenticated Actions repository',
  );
  assertAuthenticated(
    attestationIdFromBundleUrl(listedAttestation.bundle_url) === attestationId,
    prefix,
    'imageProvenanceAttestationUrl id must exactly match the digest-listed bundle_url id',
  );

  const privateDirectory = fs.mkdtempSync(path.join(os.tmpdir(), 'passkey-deployment-attestation-'));
  fs.chmodSync(privateDirectory, 0o700);
  try {
    const subject = `oci://${record.imageRepository}@${record.imageDigest}`;
    runGh(ghBinary, [
      'attestation',
      'download',
      subject,
      '--repo',
      EXPECTED_PUBLICATION_REPOSITORY,
      '--predicate-type',
      EXPECTED_PROVENANCE_PREDICATE_TYPE,
      '--limit',
      '2',
      '--hostname',
      'github.com',
    ], `${prefix}.imageProvenanceAttestationUrl gh attestation download`, {
      cwd: privateDirectory,
    });
    const expectedBundleNames = new Set([
      `${record.imageDigest}.jsonl`,
      `${record.imageDigest.replace(':', '-')}.jsonl`,
    ]);
    const downloadedFiles = fs.readdirSync(privateDirectory);
    assertAuthenticated(
      downloadedFiles.length === 1 && expectedBundleNames.has(downloadedFiles[0]),
      prefix,
      'imageProvenanceAttestationUrl download must create exactly the digest-named bundle file',
    );
    const bundlePath = path.join(privateDirectory, downloadedFiles[0]);
    const bundleStat = fs.lstatSync(bundlePath);
    assertAuthenticated(
      bundleStat.isFile() && !bundleStat.isSymbolicLink(),
      prefix,
      'imageProvenanceAttestationUrl download must create a regular non-symlink bundle file',
    );
    assertAuthenticated(
      bundleStat.size > 0 && bundleStat.size <= 4 * 1024 * 1024,
      prefix,
      'imageProvenanceAttestationUrl downloaded bundle must be non-empty and bounded',
    );
    const bundleLines = fs.readFileSync(bundlePath, 'utf8')
      .split(/\r?\n/u)
      .filter((line) => line.length > 0);
    assertAuthenticated(
      bundleLines.length === 1,
      prefix,
      'imageProvenanceAttestationUrl download must contain exactly one Sigstore bundle',
    );
    let downloadedBundle;
    try {
      downloadedBundle = JSON.parse(bundleLines[0]);
    } catch {
      downloadedBundle = null;
    }
    assertAuthenticated(
      isRecord(downloadedBundle) &&
        typeof downloadedBundle.mediaType === 'string' && downloadedBundle.mediaType.length > 0 &&
        isRecord(downloadedBundle.verificationMaterial) &&
        isRecord(downloadedBundle.dsseEnvelope),
      prefix,
      'imageProvenanceAttestationUrl download must contain a structurally valid Sigstore bundle',
    );
    const verification = runGhJson(ghBinary, [
      'attestation',
      'verify',
      subject,
      '--bundle',
      bundlePath,
      '--repo',
      EXPECTED_PUBLICATION_REPOSITORY,
      '--signer-workflow',
      EXPECTED_PUBLICATION_SIGNER_WORKFLOW,
      '--source-digest',
      record.deployedCommit,
      '--source-ref',
      EXPECTED_PUBLICATION_SOURCE_REF,
      '--predicate-type',
      EXPECTED_PROVENANCE_PREDICATE_TYPE,
      '--deny-self-hosted-runners',
      '--hostname',
      'github.com',
      '--format',
      'json',
    ], `${prefix}.imageProvenanceAttestationUrl gh attestation verify`);
    assertAuthenticated(
      Array.isArray(verification) && verification.length === 1 && isRecord(verification[0]),
      prefix,
      'imageProvenanceAttestationUrl verification must return exactly one verified provenance result',
    );
  } finally {
    fs.rmSync(privateDirectory, { recursive: true, force: true });
  }
}

function isCanonicalAndroidOrigin(value) {
  if (typeof value !== 'string' || !value.startsWith(ANDROID_ORIGIN_PREFIX)) return false;
  const digest = value.slice(ANDROID_ORIGIN_PREFIX.length);
  if (!/^[A-Za-z0-9_-]{43}$/u.test(digest)) return false;
  try {
    const decoded = Buffer.from(digest, 'base64url');
    return decoded.length === 32 && decoded.toString('base64url') === digest;
  } catch {
    return false;
  }
}

function validateAllowedOrigins(value, prefix) {
  assert(Array.isArray(value), `${prefix}.webauthnAllowedOrigins must be an array`);
  if (!Array.isArray(value)) return;
  assert(value.length === 3, `${prefix}.webauthnAllowedOrigins must contain two HTTPS origins and one Android release origin`);
  const unique = new Set(value);
  assert(unique.size === value.length, `${prefix}.webauthnAllowedOrigins must not contain duplicates`);
  for (const origin of EXPECTED_HTTPS_ORIGINS) {
    assert(unique.has(origin), `${prefix}.webauthnAllowedOrigins must include ${origin}`);
  }
  const androidOrigins = value.filter((origin) =>
    typeof origin === 'string' && origin.startsWith(ANDROID_ORIGIN_PREFIX));
  assert(androidOrigins.length === 1, `${prefix}.webauthnAllowedOrigins must contain exactly one Android release origin`);
  if (androidOrigins.length === 1) {
    assert(
      isCanonicalAndroidOrigin(androidOrigins[0]),
      `${prefix}.webauthnAllowedOrigins Android origin must contain an unpadded base64url SHA-256 release certificate digest`,
    );
  }
}

function validateRequestAccessPolicy(value, prefix) {
  assert(isRecord(value), `${prefix}.requestAccessPolicy must be an object`);
  if (!isRecord(value)) return;
  assertAllowedKeys(value, REQUIRED_ACCESS_POLICY, `${prefix}.requestAccessPolicy`);
  let url;
  try { url = new URL(value.introspectionUrl); } catch { url = null; }
  assert(
    url && url.protocol === 'https:' && !url.username && !url.password && !url.search &&
      !url.hash && url.pathname !== '/' && url.href === value.introspectionUrl,
    `${prefix}.requestAccessPolicy.introspectionUrl must be a canonical HTTPS endpoint`,
  );
  assert(value.audience === 'fearless-passkey-backup', `${prefix}.requestAccessPolicy.audience must be fearless-passkey-backup`);
  assert(value.mode === 'atomic-one-time-consume', `${prefix}.requestAccessPolicy.mode must be atomic-one-time-consume`);
  for (const field of REQUIRED_ACCESS_POLICY.slice(3)) {
    assert(value[field] === true, `${prefix}.requestAccessPolicy.${field} must be true`);
  }
}

function validateTrustedProxyPolicy(value, prefix) {
  assert(isRecord(value), `${prefix}.trustedProxyPolicy must be an object`);
  if (!isRecord(value)) return;
  assertAllowedKeys(value, REQUIRED_PROXY_POLICY, `${prefix}.trustedProxyPolicy`);
  assert(value.hops === 1, `${prefix}.trustedProxyPolicy.hops must be 1`);
  assert(value.forwardedHeader === 'X-Forwarded-For', `${prefix}.trustedProxyPolicy.forwardedHeader must be X-Forwarded-For`);
  for (const field of REQUIRED_PROXY_POLICY.slice(2)) {
    assert(value[field] === true, `${prefix}.trustedProxyPolicy.${field} must be true`);
  }
}

function validateBoundAttestation(attestation, record, payload, field, prefix) {
  const path = `${prefix}.${field}`;
  assert(isRecord(attestation), `${path} must be an object`);
  if (!isRecord(attestation)) return;
  assertAllowedKeys(attestation, REQUIRED_ATTESTATION_FIELDS, path);
  assert(attestation.deploymentId === record.deploymentId, `${path}.deploymentId must match ${prefix}.deploymentId`);
  assert(attestation.deployedCommit === record.deployedCommit, `${path}.deployedCommit must match ${prefix}.deployedCommit`);
  assert(attestation.imageDigest === record.imageDigest, `${path}.imageDigest must match ${prefix}.imageDigest`);
  assert(validTimestamp(attestation.observedAt), `${path}.observedAt must be an ISO-8601 UTC second timestamp`);
  if (validTimestamp(attestation.observedAt)) {
    assert(!isFutureTimestamp(attestation.observedAt), `${path}.observedAt must not be in the future`);
    assert(attestation.observedAt === record.smokePassedAt, `${path}.observedAt must equal ${prefix}.smokePassedAt`);
  }
  assert(
    attestation.payloadSha256 === sha256Json(payload),
    `${path}.payloadSha256 must match the canonical attested payload`,
  );
}

function validateRecord(record, index, expectedDeploymentCommit, enforceReadyFreshness) {
  const prefix = `deploymentEvidence[${index}]`;
  assert(isRecord(record), `${prefix} must be an object`);
  if (!isRecord(record)) return;
  assertAllowedKeys(record, REQUIRED_FIELDS, prefix);

  assert(
    record.imageRepository === EXPECTED_IMAGE_REPOSITORY,
    `${prefix}.imageRepository must be ${EXPECTED_IMAGE_REPOSITORY}`,
  );
  assert(/^sha256:[0-9a-f]{64}$/u.test(String(record.imageDigest ?? '')), `${prefix}.imageDigest must be a sha256 image digest`);
  assert(!isRepeatedHexPlaceholder(record.imageDigest), `${prefix}.imageDigest must not be a placeholder image digest`);
  assert(
    matchesCanonicalPublicationUrl(record.imagePublicationRunUrl, EXPECTED_IMAGE_PUBLICATION_RUN_URL),
    `${prefix}.imagePublicationRunUrl must be a canonical protected-repository GitHub Actions run URL with a positive integer id`,
  );
  assert(
    matchesCanonicalPublicationUrl(
      record.imageProvenanceAttestationUrl,
      EXPECTED_IMAGE_PROVENANCE_ATTESTATION_URL,
    ),
    `${prefix}.imageProvenanceAttestationUrl must be a canonical protected-repository GitHub attestation URL with a positive integer id`,
  );
  assert(/^[A-Za-z0-9._:-]{3,128}$/u.test(String(record.deploymentId ?? '')), `${prefix}.deploymentId must be a stable deployment id`);
  assert(!isTemplatePlaceholder(record.deploymentId), `${prefix}.deploymentId must not be a placeholder deployment id`);
  assert(isGitCommit(record.deployedCommit), `${prefix}.deployedCommit must be a 40-character lowercase git commit`);
  assert(!isRepeatedHexPlaceholder(record.deployedCommit), `${prefix}.deployedCommit must not be a placeholder git commit`);
  if (expectedDeploymentCommit) {
    assert(
      record.deployedCommit === expectedDeploymentCommit,
      `${prefix}.deployedCommit must match expected deployment commit ${expectedDeploymentCommit}`,
    );
  }
  assert(validTimestamp(record.deployedAt), `${prefix}.deployedAt must be an ISO-8601 UTC second timestamp`);
  assert(validTimestamp(record.smokePassedAt), `${prefix}.smokePassedAt must be an ISO-8601 UTC second timestamp`);
  if (validTimestamp(record.deployedAt)) {
    assert(!isFutureTimestamp(record.deployedAt), `${prefix}.deployedAt must not be in the future`);
  }
  if (validTimestamp(record.smokePassedAt)) {
    assert(!isFutureTimestamp(record.smokePassedAt), `${prefix}.smokePassedAt must not be in the future`);
    if (enforceReadyFreshness) {
      assert(
        auditStartedAtMs - timestampMillis(record.smokePassedAt) <= MAX_READY_EVIDENCE_AGE_MS,
        `${prefix}.smokePassedAt must be no more than 24 hours old for ready evidence`,
      );
    }
  }
  if (validTimestamp(record.deployedAt) && validTimestamp(record.smokePassedAt)) {
    assert(
      timestampMillis(record.smokePassedAt) >= timestampMillis(record.deployedAt),
      `${prefix}.smokePassedAt must be at or after deployedAt`,
    );
  }
  assertPublicOperator(record.operator, `${prefix}.operator`);
  assert(record.smokeCommand === EXPECTED_SMOKE, `${prefix}.smokeCommand must be the production route smoke command`);
  assert(record.healthUrl === EXPECTED_HEALTH_URL, `${prefix}.healthUrl must be ${EXPECTED_HEALTH_URL}`);
  assert(record.credentialStoreVolume === EXPECTED_VOLUME, `${prefix}.credentialStoreVolume must be ${EXPECTED_VOLUME}`);
  assert(record.credentialStoreFile === EXPECTED_FILE, `${prefix}.credentialStoreFile must be ${EXPECTED_FILE}`);
  validateAllowedOrigins(record.webauthnAllowedOrigins, prefix);
  validateRequestAccessPolicy(record.requestAccessPolicy, prefix);
  validateTrustedProxyPolicy(record.trustedProxyPolicy, prefix);

  const health = record.healthResponse;
  assert(isRecord(health), `${prefix}.healthResponse must be an object`);
  if (isRecord(health)) {
    assertAllowedKeys(health, ALLOWED_HEALTH_FIELDS, `${prefix}.healthResponse`);
    assert(health.ok === true, `${prefix}.healthResponse.ok must be true`);
    assert(health.service === EXPECTED_SERVICE, `${prefix}.healthResponse.service must be ${EXPECTED_SERVICE}`);
    assert(health.rpId === EXPECTED_RP_ID, `${prefix}.healthResponse.rpId must be ${EXPECTED_RP_ID}`);
    assert(health.schemaVersion === 1, `${prefix}.healthResponse.schemaVersion must be 1`);
  }
  const canonicalHealthPayload = {
    ok: health?.ok,
    service: health?.service,
    rpId: health?.rpId,
    schemaVersion: health?.schemaVersion,
  };
  validateBoundAttestation(
    record.liveHealthAttestation,
    record,
    canonicalHealthPayload,
    'liveHealthAttestation',
    prefix,
  );

  const platform = record.platformProvisioning;
  assert(isRecord(platform), `${prefix}.platformProvisioning must be an object`);
  if (isRecord(platform)) {
    assertAllowedKeys(platform, REQUIRED_PLATFORM, `${prefix}.platformProvisioning`);
    for (const field of REQUIRED_PLATFORM) {
      assert(platform[field] === true, `${prefix}.platformProvisioning.${field} must be true`);
    }
  }
  const canonicalPlatformPayload = Object.fromEntries(
    REQUIRED_PLATFORM.map((field) => [field, platform?.[field]]),
  );
  validateBoundAttestation(
    record.platformProvisioningAttestation,
    record,
    canonicalPlatformPayload,
    'platformProvisioningAttestation',
    prefix,
  );
}

const data = parseJson(evidencePath);
if (!data) process.exit(1);
assertNoSecretLikeKeys(data);
assertNoSecretLikeValues(data);
assertAllowedKeys(data, ALLOWED_TOP_LEVEL_FIELDS, 'deployment evidence');
const readyEvidenceRequired = data.status === 'ready' || data.releaseEnabled === true;
let expectedDeploymentCommit = null;
if (readyEvidenceRequired) {
  const result = expectedDeploymentCommitResult();
  if (result.error) {
    fail(result.error);
  } else {
    expectedDeploymentCommit = result.commit;
  }
}

assert(data.schemaVersion === 1, 'schemaVersion must be 1');
assert(data.scope === 'passkey-backup-challenge-service-production-deployment-readiness', 'scope must be passkey backup deployment readiness');
assert(data.service === EXPECTED_SERVICE, `service must be ${EXPECTED_SERVICE}`);
assert(data.rpId === EXPECTED_RP_ID, `rpId must be ${EXPECTED_RP_ID}`);
assert(data.baseUrl === EXPECTED_BASE_URL, `baseUrl must be ${EXPECTED_BASE_URL}`);
assert(data.healthUrl === EXPECTED_HEALTH_URL, `healthUrl must be ${EXPECTED_HEALTH_URL}`);
assert(data.imageName === EXPECTED_IMAGE, `imageName must be ${EXPECTED_IMAGE}`);
assert(data.imageRepository === EXPECTED_IMAGE_REPOSITORY, `imageRepository must be ${EXPECTED_IMAGE_REPOSITORY}`);
assert(
  data.imagePublicationWorkflow === EXPECTED_IMAGE_PUBLICATION_WORKFLOW,
  `imagePublicationWorkflow must be ${EXPECTED_IMAGE_PUBLICATION_WORKFLOW}`,
);
assert(
  data.imagePublicationCommand === EXPECTED_IMAGE_PUBLICATION_COMMAND,
  'imagePublicationCommand must dispatch the protected-main image publication workflow',
);
assert(data.port === 8789, 'port must be 8789');
assert(data.credentialStoreVolume === EXPECTED_VOLUME, `credentialStoreVolume must be ${EXPECTED_VOLUME}`);
assert(data.credentialStoreFile === EXPECTED_FILE, `credentialStoreFile must be ${EXPECTED_FILE}`);
assert(data.smokeCommand === EXPECTED_SMOKE, 'smokeCommand must be the production route smoke command');
assert(
  hasAllStrings(data.requiredCommands, REQUIRED_COMMANDS),
  'requiredCommands must include lint, tests, protected-main image publication, deployment evidence audits, template generation, ready audit, live health command, and route smoke command',
);
if (Array.isArray(data.requiredCommands)) {
  const commandSet = new Set(data.requiredCommands);
  assert(commandSet.size === data.requiredCommands.length, 'duplicate deployment evidence required command');
  for (const command of data.requiredCommands) {
    assert(REQUIRED_COMMANDS.includes(command), `unsupported deployment evidence required command: ${command}`);
  }
}
assert(hasAllStrings(data.requiredEvidenceFields, REQUIRED_FIELDS), 'requiredEvidenceFields must include all release proof fields');
if (Array.isArray(data.requiredEvidenceFields)) {
  const fieldSet = new Set(data.requiredEvidenceFields);
  assert(fieldSet.size === data.requiredEvidenceFields.length, 'duplicate deployment evidence required field');
  for (const field of data.requiredEvidenceFields) {
    assert(REQUIRED_FIELDS.includes(field), `unsupported deployment evidence field in manifest: ${field}`);
  }
}

if (data.status === 'blocked') {
  assert(data.releaseEnabled === false, 'releaseEnabled must remain false while deployment evidence is blocked');
  assert(hasAllStrings(data.blockers, REQUIRED_BLOCKERS), 'blocked deployment evidence must list missing deployment, live health, and platform provisioning blockers');
  if (Array.isArray(data.blockers)) {
    const blockerSet = new Set(data.blockers);
    assert(blockerSet.size === data.blockers.length, 'duplicate deployment evidence blocker');
    for (const blocker of data.blockers) {
      assert(REQUIRED_BLOCKERS.includes(blocker), `unsupported deployment evidence blocker: ${blocker}`);
    }
  }
  assert(
    Array.isArray(data.deploymentEvidence) && data.deploymentEvidence.length === 0,
    'blocked deployment evidence must keep deploymentEvidence empty; partial or stale records cannot coexist with blockers',
  );
  if (requireReady) {
    fail('--require-ready requires status ready and releaseEnabled true');
  }
} else if (data.status === 'ready') {
  assert(data.releaseEnabled === true, 'ready deployment evidence must set releaseEnabled true');
  assert(Array.isArray(data.blockers) && data.blockers.length === 0, 'ready deployment evidence must not list blockers');
  assert(Array.isArray(data.deploymentEvidence) && data.deploymentEvidence.length > 0, 'ready deployment evidence requires at least one successful live production smoke record');
} else {
  fail('status must be blocked or ready');
}

if (Array.isArray(data.deploymentEvidence)) {
  const deploymentIds = new Set();
  data.deploymentEvidence.forEach((record, index) => {
    validateRecord(record, index, expectedDeploymentCommit, readyEvidenceRequired);
    if (!isRecord(record)) return;

    const deploymentId = String(record.deploymentId ?? '').trim();
    if (!deploymentId) return;
    assert(!deploymentIds.has(deploymentId), `duplicate deployment evidence id: ${deploymentId}`);
    deploymentIds.add(deploymentId);
  });
} else {
  fail('deploymentEvidence must be an array');
}

if (readyEvidenceRequired && !process.exitCode) {
  const ghBinaryResult = deploymentGhBinaryResult();
  if (ghBinaryResult.error) {
    fail(ghBinaryResult.error);
  } else {
    for (let index = 0; index < data.deploymentEvidence.length; index += 1) {
      try {
        authenticatePublicationRecord(data.deploymentEvidence[index], index, ghBinaryResult.binary);
      } catch (error) {
        fail(error.message || String(error));
        break;
      }
    }
  }
}

if (process.exitCode) process.exit(process.exitCode);
console.log('[passkey-deployment-evidence] deployment evidence audit passed.');
NODE
