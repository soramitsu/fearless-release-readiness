#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="${NEXUS_EVIDENCE_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
EVIDENCE_FILE="$ROOT_DIR/config/nexus-production-evidence.json"
OUTPUT_FILE=""

usage() {
  cat <<'USAGE'
Usage: scripts/generate-nexus-production-evidence-template.sh [--evidence <path>] [--output <path>]

Generates a fill-in-ready SORA Nexus production evidence manifest from the
committed blocked manifest. The generated template intentionally contains TODO
placeholders and must fail the release-ready audit until real Minamoto route
publication, canary, and wallet smoke evidence are recorded. Canary checks and
all three wallet submissions and observations must bind to the unique
ledger-latest verified route publication hash and be recorded within the fixed 24-hour
readiness window; the publication itself may be older. The committed blocked
source manifest must keep publication,
canary, and wallet-smoke evidence arrays empty so stale evidence cannot be
replayed behind evidence-missing blockers.
Before release, commit the exact canonical ApplySccpRouteGovernance instruction
artifact at artifacts/nexus/production-route-governance-action.json in the
pinned Iroha commit. The ready audit hashes its exact canonical Norito bytes and
verifies the publication, canary, and wallet transactions through Minamoto;
transaction hashes and action hashes are not accepted as operator assertions.
USAGE
}

while (($#)); do
  case "$1" in
    --evidence)
      [[ $# -ge 2 ]] || { echo "[nexus-production-evidence-template][error] --evidence requires a path" >&2; exit 2; }
      EVIDENCE_FILE="$2"
      shift 2
      ;;
    --output)
      [[ $# -ge 2 ]] || { echo "[nexus-production-evidence-template][error] --output requires a path" >&2; exit 2; }
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
      echo "[nexus-production-evidence-template][error] Unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if ! command -v node >/dev/null 2>&1; then
  echo "[nexus-production-evidence-template][error] node is required for structured JSON generation" >&2
  exit 1
fi

node - "$EVIDENCE_FILE" "$OUTPUT_FILE" <<'NODE'
const fs = require('fs');
const path = require('path');

const [evidenceFile, outputFile] = process.argv.slice(2);
const errors = [];

const expected = {
  schemaVersion: 1,
  scope: 'sora-nexus-production-readiness',
  network: 'sora-nexus-mainnet',
  chainId: 'sora:nexus:global',
  toriiBaseUrl: 'https://minamoto.sora.org',
  mcpUrl: 'https://minamoto.sora.org/v1/mcp',
  healthUrl: 'https://minamoto.sora.org/status',
};
const requiredBlockers = [
  'nexus-live-health-failing',
  'route-publication-evidence-missing',
  'route-canary-evidence-missing',
  'wallet-live-transfer-smoke-missing',
];
const requiredCommands = [
  'bash scripts/test-nexus-production-evidence-template.sh',
  'bash scripts/generate-nexus-production-evidence-template.sh --output build/reports/nexus-production-evidence-template.json',
  'bash scripts/test-nexus-production-evidence-audit.sh',
  'bash scripts/audit-nexus-production-evidence.sh --require-ready',
  'IROHA_NEXUS_REQUIRE_PRODUCTION_EVIDENCE=1 IROHA_NEXUS_LIVE_HEALTH=1 bash scripts/audit-iroha-release-readiness.sh',
  'bash scripts/audit-iroha-wallet-coverage.sh',
];
const requiredFields = [
  'routeManifestCommit',
  'routeManifestSourcePath',
  'routeManifestHash',
  'publicationTransactionHash',
  'publicationAuthority',
  'publishedAt',
  'routeCanaryTransactionHash',
  'routeCanaryCheckedAt',
  'routeCanarySourceAccount',
  'routeCanaryDestinationAccount',
  'routeCanaryAssetId',
  'routeCanaryAmount',
  'walletPlatform',
  'walletCommit',
  'walletSmokeTransactionHash',
  'walletSmokeSubmittedAt',
  'walletSmokeObservedAt',
  'operator',
];
const allowedManifestFields = new Set([
  'schemaVersion',
  'scope',
  'network',
  'chainId',
  'toriiBaseUrl',
  'mcpUrl',
  'healthUrl',
  'status',
  'releaseEnabled',
  'blockers',
  'readyVerificationCommands',
  'requiredEvidenceFields',
  'routePublicationEvidence',
  'routeCanaryEvidence',
  'walletSmokeEvidence',
]);
const allowedPublicationFields = new Set([
  'routeManifestCommit',
  'routeManifestSourcePath',
  'routeManifestHash',
  'publicationTransactionHash',
  'publicationAuthority',
  'publishedAt',
  'toriiBaseUrl',
  'mcpUrl',
  'operator',
]);
const allowedCanaryFields = new Set([
  'publishedRouteManifestHash',
  'routeCanaryTransactionHash',
  'authority',
  'sourceAccount',
  'destinationAccount',
  'assetId',
  'amount',
  'routeCanaryCheckedAt',
  'toriiBaseUrl',
  'operator',
]);
const allowedWalletSmokeFields = new Set([
  'platform',
  'walletCommit',
  'routeManifestHash',
  'walletSmokeTransactionHash',
  'sourceAccount',
  'destinationAccount',
  'assetId',
  'amount',
  'walletSmokeSubmittedAt',
  'walletSmokeObservedAt',
  'toriiBaseUrl',
  'operator',
]);
const secretKeyPattern =
  /(?:secret|password|token|private[_-]?key|authorization|cookie|seed|mnemonic|credentialStoreSnapshot|credentialsByStorageKey|clientDataJSON)/iu;

function fail(message) {
  errors.push(message);
}

function isRecord(value) {
  return value && typeof value === 'object' && !Array.isArray(value);
}

function readJson(file) {
  if (!fs.existsSync(file)) {
    fail(`Nexus production evidence manifest missing: ${file}`);
    return null;
  }

  try {
    return JSON.parse(fs.readFileSync(file, 'utf8'));
  } catch (error) {
    fail(`Nexus production evidence manifest must be valid JSON: ${error.message}`);
    return null;
  }
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
    if (secretKeyPattern.test(key)) return `${currentPath}.${key}`;
    const reason = secretLikeKeyReason(child, `${currentPath}.${key}`);
    if (reason) return reason;
  }
  return null;
}

function rejectUnsupportedKeys(record, allowedFields, prefix, messagePrefix) {
  if (!isRecord(record)) return;
  for (const field of Object.keys(record)) {
    if (!allowedFields.has(field)) {
      fail(`${messagePrefix} ${prefix}.${field}`);
    }
  }
}

function validateCommittedEvidenceArray(value, name, allowedFields, messagePrefix, prefilledMessage) {
  const records = requireArray(value, name);
  records.forEach((entry, index) => {
    const prefix = `${name}[${index}]`;
    if (!isRecord(entry)) {
      fail(`${prefix} must be an object`);
      return;
    }
    rejectUnsupportedKeys(entry, allowedFields, prefix, messagePrefix);
  });
  if (records.length > 0) {
    fail(prefilledMessage);
  }
}

const manifest = readJson(evidenceFile);
if (manifest) {
  const secretPath = secretLikeKeyReason(manifest);
  if (secretPath) {
    fail(`${secretPath} must not be read from public Nexus production evidence manifest`);
  }
  rejectUnsupportedKeys(manifest, allowedManifestFields, 'manifest', 'unsupported Nexus production evidence manifest field');

  for (const [field, value] of Object.entries(expected)) {
    if (manifest[field] !== value) {
      fail(`${field} must be ${value}`);
    }
  }

  if (manifest.status !== 'blocked') fail('status must stay blocked in the committed Nexus manifest');
  if (manifest.releaseEnabled !== false) fail('releaseEnabled must stay false in the committed Nexus manifest');

  const blockers = requireArray(manifest.blockers, 'blockers');
  const blockerSet = new Set(blockers);
  for (const blocker of requiredBlockers) {
    if (!blockers.includes(blocker)) fail(`blocked Nexus production evidence missing ${blocker}`);
  }
  for (const blocker of blockers) {
    if (!requiredBlockers.includes(blocker)) {
      fail(`unsupported Nexus production evidence blocker in manifest: ${blocker}`);
    }
  }
  if (blockerSet.size !== blockers.length) {
    fail('duplicate Nexus production evidence blocker in manifest');
  }

  const commandList = requireArray(manifest.readyVerificationCommands, 'readyVerificationCommands');
  const commands = commandList.join('\n');
  if (new Set(commandList).size !== commandList.length) {
    fail('duplicate Nexus production evidence verification command in manifest');
  }
  for (const command of requiredCommands) {
    if (!commands.includes(command)) fail(`readyVerificationCommands missing ${command}`);
  }

  const fields = requireArray(manifest.requiredEvidenceFields, 'requiredEvidenceFields');
  const fieldSet = new Set(fields);
  if (fieldSet.size !== fields.length) {
    fail('duplicate Nexus production evidence required field in manifest');
  }
  for (const field of requiredFields) {
    if (!fieldSet.has(field)) fail(`requiredEvidenceFields missing ${field}`);
  }
  for (const field of fields) {
    if (!requiredFields.includes(field)) {
      fail(`unsupported Nexus production evidence field in manifest: ${field}`);
    }
  }

  validateCommittedEvidenceArray(
    manifest.routePublicationEvidence,
    'routePublicationEvidence',
    allowedPublicationFields,
    'unsupported Nexus route publication evidence field',
    'committed Nexus production evidence manifest must not prefill routePublicationEvidence',
  );
  validateCommittedEvidenceArray(
    manifest.routeCanaryEvidence,
    'routeCanaryEvidence',
    allowedCanaryFields,
    'unsupported Nexus route canary evidence field',
    'committed Nexus production evidence manifest must not prefill routeCanaryEvidence',
  );
  validateCommittedEvidenceArray(
    manifest.walletSmokeEvidence,
    'walletSmokeEvidence',
    allowedWalletSmokeFields,
    'unsupported Nexus wallet smoke evidence field',
    'committed Nexus production evidence manifest must not prefill walletSmokeEvidence',
  );
}

if (errors.length > 0) {
  for (const error of errors) {
    console.error(`[nexus-production-evidence-template][error] ${error}`);
  }
  process.exit(1);
}

const routeManifestHash = 'sha256:TODO_64_HEX_ROUTE_MANIFEST_HASH';
const operator = 'TODO_RELEASE_OPERATOR';
const walletSmokePlaceholders = {
  android: {
    walletCommit: 'TODO_40_HEX_ANDROID_WALLET_COMMIT',
    walletSmokeTransactionHash: '0xTODO_64_HEX_ANDROID_WALLET_SMOKE_TX_HASH',
    sourceAccount: 'TODO_NEXUS_ANDROID_SOURCE_ACCOUNT',
    destinationAccount: 'TODO_NEXUS_ANDROID_DESTINATION_ACCOUNT',
    walletSmokeSubmittedAt: 'TODO_UTC_ANDROID_WALLET_SMOKE_SUBMITTED_AT_RFC3339',
    walletSmokeObservedAt: 'TODO_UTC_ANDROID_WALLET_SMOKE_OBSERVED_WITHIN_24_HOURS_AT_RFC3339',
  },
  ios: {
    walletCommit: 'TODO_40_HEX_IOS_WALLET_COMMIT',
    walletSmokeTransactionHash: '0xTODO_64_HEX_IOS_WALLET_SMOKE_TX_HASH',
    sourceAccount: 'TODO_NEXUS_IOS_SOURCE_ACCOUNT',
    destinationAccount: 'TODO_NEXUS_IOS_DESTINATION_ACCOUNT',
    walletSmokeSubmittedAt: 'TODO_UTC_IOS_WALLET_SMOKE_SUBMITTED_AT_RFC3339',
    walletSmokeObservedAt: 'TODO_UTC_IOS_WALLET_SMOKE_OBSERVED_WITHIN_24_HOURS_AT_RFC3339',
  },
  web: {
    walletCommit: 'TODO_40_HEX_WEB_WALLET_COMMIT',
    walletSmokeTransactionHash: '0xTODO_64_HEX_WEB_WALLET_SMOKE_TX_HASH',
    sourceAccount: 'TODO_NEXUS_WEB_SOURCE_ACCOUNT',
    destinationAccount: 'TODO_NEXUS_WEB_DESTINATION_ACCOUNT',
    walletSmokeSubmittedAt: 'TODO_UTC_WEB_WALLET_SMOKE_SUBMITTED_AT_RFC3339',
    walletSmokeObservedAt: 'TODO_UTC_WEB_WALLET_SMOKE_OBSERVED_WITHIN_24_HOURS_AT_RFC3339',
  },
};
const walletSmokeTemplate = (platform) => ({
  platform,
  walletCommit: walletSmokePlaceholders[platform].walletCommit,
  routeManifestHash,
  walletSmokeTransactionHash: walletSmokePlaceholders[platform].walletSmokeTransactionHash,
  sourceAccount: walletSmokePlaceholders[platform].sourceAccount,
  destinationAccount: walletSmokePlaceholders[platform].destinationAccount,
  assetId: 'xor#sora',
  amount: 'TODO_POSITIVE_DECIMAL_AMOUNT',
  walletSmokeSubmittedAt: walletSmokePlaceholders[platform].walletSmokeSubmittedAt,
  walletSmokeObservedAt: walletSmokePlaceholders[platform].walletSmokeObservedAt,
  toriiBaseUrl: manifest.toriiBaseUrl,
  operator,
});
const template = {
  schemaVersion: manifest.schemaVersion,
  scope: manifest.scope,
  network: manifest.network,
  chainId: manifest.chainId,
  toriiBaseUrl: manifest.toriiBaseUrl,
  mcpUrl: manifest.mcpUrl,
  healthUrl: manifest.healthUrl,
  status: 'ready',
  releaseEnabled: true,
  blockers: [],
  readyVerificationCommands: manifest.readyVerificationCommands,
  requiredEvidenceFields: manifest.requiredEvidenceFields,
  routePublicationEvidence: [
    {
      routeManifestCommit: 'TODO_40_HEX_ROUTE_MANIFEST_COMMIT',
      routeManifestSourcePath: 'artifacts/nexus/production-route-governance-action.json',
      routeManifestHash,
      publicationTransactionHash: '0xTODO_64_HEX_PUBLICATION_TX_HASH',
      publicationAuthority: 'TODO_PUBLICATION_AUTHORITY',
      publishedAt: 'TODO_UTC_ROUTE_PUBLISHED_AT_RFC3339',
      toriiBaseUrl: manifest.toriiBaseUrl,
      mcpUrl: manifest.mcpUrl,
      operator,
    },
  ],
  routeCanaryEvidence: [
    {
      publishedRouteManifestHash: routeManifestHash,
      routeCanaryTransactionHash: '0xTODO_64_HEX_CANARY_TX_HASH',
      authority: 'TODO_CANARY_AUTHORITY',
      sourceAccount: 'TODO_NEXUS_CANARY_SOURCE_ACCOUNT',
      destinationAccount: 'TODO_NEXUS_CANARY_DESTINATION_ACCOUNT',
      assetId: 'xor#sora',
      amount: 'TODO_POSITIVE_DECIMAL_AMOUNT',
      routeCanaryCheckedAt: 'TODO_UTC_CANARY_CHECKED_WITHIN_24_HOURS_AT_RFC3339',
      toriiBaseUrl: manifest.toriiBaseUrl,
      operator,
    },
  ],
  walletSmokeEvidence: [
    walletSmokeTemplate('android'),
    walletSmokeTemplate('ios'),
    walletSmokeTemplate('web'),
  ],
};

const output = `${JSON.stringify(template, null, 2)}\n`;
if (outputFile) {
  fs.mkdirSync(path.dirname(outputFile), { recursive: true });
  fs.writeFileSync(outputFile, output);
}
process.stdout.write(output);
NODE
