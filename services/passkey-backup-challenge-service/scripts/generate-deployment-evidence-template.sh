#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="${PASSKEY_DEPLOYMENT_EVIDENCE_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
EVIDENCE_FILE="$ROOT_DIR/scripts/production-deployment-evidence.json"
OUTPUT_FILE=""

usage() {
  cat <<'USAGE'
Usage: scripts/generate-deployment-evidence-template.sh [--evidence <path>] [--output <path>]

Generates a fill-in-ready production deployment evidence manifest from the
committed passkey challenge-service evidence schema. The generated template
intentionally contains TODO placeholders and must fail the release-ready audit
until a real deployment, live health result, and platform provisioning evidence
are recorded.
USAGE
}

while (($#)); do
  case "$1" in
    --evidence)
      [[ $# -ge 2 ]] || { echo "[passkey-deployment-evidence-template][error] --evidence requires a path" >&2; exit 2; }
      EVIDENCE_FILE="$2"
      shift 2
      ;;
    --output)
      [[ $# -ge 2 ]] || { echo "[passkey-deployment-evidence-template][error] --output requires a path" >&2; exit 2; }
      OUTPUT_FILE="$2"
      shift 2
      ;;
    --)
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "[passkey-deployment-evidence-template][error] Unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if ! command -v node >/dev/null 2>&1; then
  echo "[passkey-deployment-evidence-template][error] node is required for structured JSON generation" >&2
  exit 1
fi

node - "$EVIDENCE_FILE" "$OUTPUT_FILE" <<'NODE'
const fs = require('fs');
const path = require('path');

const [evidenceFile, outputFile] = process.argv.slice(2);
const errors = [];

const expected = {
  schemaVersion: 1,
  scope: 'passkey-backup-challenge-service-production-deployment-readiness',
  service: 'fearless-passkey-backup',
  rpId: 'fearlesswallet.io',
  baseUrl: 'https://backup.fearlesswallet.io',
  healthUrl: 'https://backup.fearlesswallet.io/api/passkey-backup/v1/health',
  imageName: 'passkey-backup-challenge-service',
  port: 8789,
  credentialStoreVolume: '/data/passkey-backup',
  credentialStoreFile: '/data/passkey-backup/credentials.json',
  dockerBuildCommand: 'docker build -t passkey-backup-challenge-service:release .',
  smokeCommand:
    'PASSKEY_BACKUP_BASE_URL=https://backup.fearlesswallet.io PASSKEY_BACKUP_SMOKE_GRANT_HELPER=/run/secrets/passkey-smoke-grant-helper PASSKEY_BACKUP_SMOKE_TIMEOUT_MS=10000 npm run smoke:production',
};
const requiredEvidenceFields = [
  'imageDigest',
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
const requiredCommands = [
  'npm run lint:syntax',
  'npm test',
  'npm run test:deployment-evidence-template',
  'npm run generate:deployment-evidence-template -- --output build/reports/production-deployment-evidence-template.json',
  'npm run test:deployment-evidence-audit',
  'npm run audit:deployment-evidence',
  expected.dockerBuildCommand,
  expected.smokeCommand,
  'npm run audit:deployment-evidence -- --require-ready',
];
const requiredBlockers = [
  'production-deployment-evidence-missing',
  'live-health-failing',
  'platform-provisioning-incomplete',
  'request-access-introspection-unprovisioned',
  'trusted-proxy-evidence-missing',
];
const requiredPlatform = [
  'androidGoogleDriveConsent',
  'androidReleaseFlagDisabled',
  'iosAssociatedDomain',
  'iosCloudKitProductionSchema',
  'iosReleaseFlagDisabled',
];
const allowedTopLevelFields = [
  'schemaVersion',
  'scope',
  'service',
  'rpId',
  'baseUrl',
  'healthUrl',
  'imageName',
  'port',
  'credentialStoreVolume',
  'credentialStoreFile',
  'status',
  'releaseEnabled',
  'blockers',
  'dockerBuildCommand',
  'smokeCommand',
  'requiredCommands',
  'requiredEvidenceFields',
  'deploymentEvidence',
];
const allowedHealthFields = ['ok', 'service', 'rpId', 'schemaVersion'];
const requiredAttestationFields = [
  'deploymentId', 'deployedCommit', 'imageDigest', 'observedAt', 'payloadSha256',
];
const requiredAccessPolicy = [
  'introspectionUrl', 'audience', 'mode', 'allPostRoutesProtected',
  'stableCrossPlatformWalletSubject', 'authorizedSmokePassed', 'noRawSubjectPersisted',
  'credentialLifecycleSmokePassed', 'ownerTombstonePersistencePassed',
  'crossSubjectTakeoverDenied', 'sameOwnerReregistrationPassed',
  'cloudDeleteRevokesServerFirst', 'listExcludesVerificationMaterial',
];
const requiredProxyPolicy = [
  'hops', 'forwardedHeader', 'directPeerAllowlistConfigured',
  'incomingHeaderSanitized', 'directPublicAccessBlocked', 'adversarialProxyTestsPassed',
];
const secretKeyPattern =
  /(?:secret|password|token|private[_-]?key|authorization|cookie|credentialStoreSnapshot|credentialsByStorageKey|clientDataJSON|mnemonic|seed)/iu;

function fail(message) {
  errors.push(message);
}

function readJson(file) {
  if (!fs.existsSync(file)) {
    fail(`production deployment evidence manifest missing: ${file}`);
    return null;
  }

  try {
    return JSON.parse(fs.readFileSync(file, 'utf8'));
  } catch (error) {
    fail(`production deployment evidence manifest must be valid JSON: ${error.message}`);
    return null;
  }
}

function isRecord(value) {
  return value && typeof value === 'object' && !Array.isArray(value);
}

function requireArray(value, name) {
  if (!Array.isArray(value)) {
    fail(`${name} must be an array`);
    return [];
  }
  return value;
}

function secretLikeKeyReason(value, currentPath = '$') {
  if (Array.isArray(value)) {
    for (let index = 0; index < value.length; index += 1) {
      const reason = secretLikeKeyReason(value[index], `${currentPath}[${index}]`);
      if (reason) return reason;
    }
    return null;
  }
  if (!isRecord(value)) return null;

  for (const [key, child] of Object.entries(value)) {
    if (secretKeyPattern.test(key)) {
      return `${currentPath}.${key}`;
    }

    const reason = secretLikeKeyReason(child, `${currentPath}.${key}`);
    if (reason) return reason;
  }

  return null;
}

function assertAllowedKeys(record, allowedKeys, path) {
  if (!isRecord(record)) return;
  const allowed = new Set(allowedKeys);
  for (const key of Object.keys(record)) {
    if (!allowed.has(key)) {
      fail(`${path}.${key} is not supported in public deployment evidence manifest`);
    }
  }
}

function validateCommittedDeploymentEvidence(records) {
  const deploymentEvidence = requireArray(records, 'deploymentEvidence');
  deploymentEvidence.forEach((record, index) => {
    const prefix = `deploymentEvidence[${index}]`;
    if (!isRecord(record)) {
      fail(`${prefix} must be an object`);
      return;
    }
    assertAllowedKeys(record, requiredEvidenceFields, prefix);

    if (isRecord(record.healthResponse)) {
      assertAllowedKeys(record.healthResponse, allowedHealthFields, `${prefix}.healthResponse`);
    }
    if (isRecord(record.liveHealthAttestation)) {
      assertAllowedKeys(record.liveHealthAttestation, requiredAttestationFields, `${prefix}.liveHealthAttestation`);
    }
    if (isRecord(record.platformProvisioning)) {
      assertAllowedKeys(record.platformProvisioning, requiredPlatform, `${prefix}.platformProvisioning`);
    }
    if (isRecord(record.platformProvisioningAttestation)) {
      assertAllowedKeys(
        record.platformProvisioningAttestation,
        requiredAttestationFields,
        `${prefix}.platformProvisioningAttestation`,
      );
    }
    if (isRecord(record.requestAccessPolicy)) {
      assertAllowedKeys(record.requestAccessPolicy, requiredAccessPolicy, `${prefix}.requestAccessPolicy`);
    }
    if (isRecord(record.trustedProxyPolicy)) {
      assertAllowedKeys(record.trustedProxyPolicy, requiredProxyPolicy, `${prefix}.trustedProxyPolicy`);
    }
  });

  if (deploymentEvidence.length > 0) {
    fail('committed deployment evidence manifest must not prefill deploymentEvidence');
  }
}

const manifest = readJson(evidenceFile);
if (manifest) {
  const secretPath = secretLikeKeyReason(manifest);
  if (secretPath) {
    fail(`${secretPath} must not be read from public deployment evidence manifest`);
  }
  assertAllowedKeys(manifest, allowedTopLevelFields, 'deployment evidence');

  for (const [field, value] of Object.entries(expected)) {
    if (manifest[field] !== value) {
      fail(`${field} must be ${value}`);
    }
  }

  const blockers = requireArray(manifest.blockers, 'blockers');
  const blockerSet = new Set(blockers);
  for (const blocker of requiredBlockers) {
    if (!blockers.includes(blocker)) {
      fail(`blocked deployment evidence missing ${blocker}`);
    }
  }
  if (blockerSet.size !== blockers.length) {
    fail('duplicate deployment evidence blocker in manifest');
  }
  for (const blocker of blockers) {
    if (!requiredBlockers.includes(blocker)) {
      fail(`unsupported deployment evidence blocker in manifest: ${blocker}`);
    }
  }

  if (manifest.status !== 'blocked') fail('status must stay blocked in the committed manifest');
  if (manifest.releaseEnabled !== false) fail('releaseEnabled must stay false in the committed manifest');

  const declaredCommandList = requireArray(manifest.requiredCommands, 'requiredCommands');
  const declaredCommands = declaredCommandList.join('\n');
  if (new Set(declaredCommandList).size !== declaredCommandList.length) {
    fail('duplicate deployment evidence required command in manifest');
  }
  for (const command of requiredCommands) {
    if (!declaredCommands.includes(command)) {
      fail(`requiredCommands missing ${command}`);
    }
  }

  const declaredFields = requireArray(manifest.requiredEvidenceFields, 'requiredEvidenceFields');
  const declaredFieldSet = new Set(declaredFields);
  if (declaredFieldSet.size !== declaredFields.length) {
    fail('duplicate deployment evidence required field in manifest');
  }
  for (const field of requiredEvidenceFields) {
    if (!declaredFieldSet.has(field)) {
      fail(`requiredEvidenceFields missing ${field}`);
    }
  }
  for (const field of declaredFields) {
    if (!requiredEvidenceFields.includes(field)) {
      fail(`unsupported deployment evidence field in manifest: ${field}`);
    }
  }

  validateCommittedDeploymentEvidence(manifest.deploymentEvidence);
}

if (errors.length > 0) {
  for (const error of errors) {
    console.error(`[passkey-deployment-evidence-template][error] ${error}`);
  }
  process.exit(1);
}

const evidence = {
  imageDigest: 'sha256:TODO_64_HEX_IMAGE_DIGEST',
  deploymentId: 'TODO_PRODUCTION_DEPLOYMENT_ID',
  deployedCommit: 'TODO_40_HEX_GIT_COMMIT',
  deployedAt: 'TODO_UTC_DEPLOYED_AT_SECONDS',
  operator: 'TODO_RELEASE_OPERATOR',
  smokePassedAt: 'TODO_UTC_SMOKE_TIMESTAMP_SECONDS',
  smokeCommand: manifest.smokeCommand,
  healthUrl: manifest.healthUrl,
  healthResponse: {
    ok: true,
    service: manifest.service,
    rpId: manifest.rpId,
    schemaVersion: manifest.schemaVersion,
  },
  liveHealthAttestation: {
    deploymentId: 'TODO_PRODUCTION_DEPLOYMENT_ID',
    deployedCommit: 'TODO_40_HEX_GIT_COMMIT',
    imageDigest: 'sha256:TODO_64_HEX_IMAGE_DIGEST',
    observedAt: 'TODO_UTC_SMOKE_TIMESTAMP_SECONDS',
    payloadSha256: 'sha256:TODO_CANONICAL_HEALTH_RESPONSE_SHA256',
  },
  credentialStoreVolume: manifest.credentialStoreVolume,
  credentialStoreFile: manifest.credentialStoreFile,
  webauthnAllowedOrigins: [
    'https://fearlesswallet.io',
    'https://backup.fearlesswallet.io',
    'android:apk-key-hash:TODO_RELEASE_CERT_SHA256_BASE64URL',
  ],
  requestAccessPolicy: {
    introspectionUrl: 'https://TODO_WALLET_OWNER_AUTHORITY/v1/passkey/consume',
    audience: 'fearless-passkey-backup',
    mode: 'atomic-one-time-consume',
    allPostRoutesProtected: true,
    stableCrossPlatformWalletSubject: true,
    authorizedSmokePassed: true,
    noRawSubjectPersisted: true,
    credentialLifecycleSmokePassed: true,
    ownerTombstonePersistencePassed: true,
    crossSubjectTakeoverDenied: true,
    sameOwnerReregistrationPassed: true,
    cloudDeleteRevokesServerFirst: true,
    listExcludesVerificationMaterial: true,
  },
  trustedProxyPolicy: {
    hops: 1,
    forwardedHeader: 'X-Forwarded-For',
    directPeerAllowlistConfigured: true,
    incomingHeaderSanitized: true,
    directPublicAccessBlocked: true,
    adversarialProxyTestsPassed: true,
  },
  platformProvisioning: Object.fromEntries(requiredPlatform.map((field) => [field, true])),
  platformProvisioningAttestation: {
    deploymentId: 'TODO_PRODUCTION_DEPLOYMENT_ID',
    deployedCommit: 'TODO_40_HEX_GIT_COMMIT',
    imageDigest: 'sha256:TODO_64_HEX_IMAGE_DIGEST',
    observedAt: 'TODO_UTC_SMOKE_TIMESTAMP_SECONDS',
    payloadSha256: 'sha256:TODO_CANONICAL_PLATFORM_PROVISIONING_SHA256',
  },
};

const template = {
  schemaVersion: manifest.schemaVersion,
  scope: manifest.scope,
  service: manifest.service,
  rpId: manifest.rpId,
  baseUrl: manifest.baseUrl,
  healthUrl: manifest.healthUrl,
  imageName: manifest.imageName,
  port: manifest.port,
  credentialStoreVolume: manifest.credentialStoreVolume,
  credentialStoreFile: manifest.credentialStoreFile,
  status: 'ready',
  releaseEnabled: true,
  blockers: [],
  dockerBuildCommand: manifest.dockerBuildCommand,
  smokeCommand: manifest.smokeCommand,
  requiredCommands: manifest.requiredCommands,
  requiredEvidenceFields: manifest.requiredEvidenceFields,
  deploymentEvidence: [evidence],
};

const output = `${JSON.stringify(template, null, 2)}\n`;
if (outputFile) {
  fs.mkdirSync(path.dirname(outputFile), { recursive: true });
  fs.writeFileSync(outputFile, output);
}
process.stdout.write(output);
NODE
