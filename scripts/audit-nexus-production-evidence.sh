#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="${NEXUS_EVIDENCE_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
EVIDENCE_FILE="$ROOT_DIR/config/nexus-production-evidence.json"
REQUIRE_READY=false
SELF_TEST_RECEIPTS_DIR=""

fail_setup() {
  echo "[nexus-production-evidence][error] $*" >&2
  exit 2
}

canonical_path() {
  local candidate="$1"
  local realpath_bin resolved
  for realpath_bin in /usr/bin/realpath /bin/realpath; do
    [[ -x "$realpath_bin" ]] || continue
    resolved="$($realpath_bin "$candidate" 2>/dev/null || true)"
    [[ -n "$resolved" ]] || continue
    printf '%s' "$resolved"
    return 0
  done
  return 1
}

resolve_canonical_node() {
  local candidate resolved
  for candidate in /usr/bin/node /usr/local/bin/node /opt/homebrew/bin/node; do
    [[ -e "$candidate" ]] || continue
    resolved="$(canonical_path "$candidate")" || continue
    [[ -f "$resolved" && -x "$resolved" && ! -L "$resolved" ]] || continue
    printf '%s' "$resolved"
    return 0
  done
  return 1
}

usage() {
  cat <<'USAGE'
Usage: scripts/audit-nexus-production-evidence.sh [--evidence <path>] [--require-ready]
       scripts/audit-nexus-production-evidence.sh --evidence <temporary-path> --self-test-receipts <temporary-dir>

Validates SORA Nexus production route-publication, canary, and wallet smoke
evidence. The default audit allows the current blocked state. --require-ready
requires release-ready public evidence. Ready canary checks and every required
wallet smoke submission and observation must be no more than 24 hours old and
must bind to the unique ledger-latest verified route publication hash. The route
publication itself may be older.
Blocked manifests must keep all three evidence arrays empty so stale evidence
cannot be replayed behind blockers that claim the evidence is missing.

Ready evidence also recomputes each routeManifestHash from the canonical
artifacts/nexus/production-route-governance-action.json file at its pinned Iroha
commit, then verifies every transaction against credential-free, bounded,
non-redirecting Minamoto status, transaction-detail, and instruction queries.
The test-receipt seam is confined to
temporary fixtures, requires NEXUS_EVIDENCE_SELF_TEST=1, and is incompatible
with --require-ready, so it cannot satisfy the release command.

Ready evidence validates release freshness against these optional overrides,
falling back to local repo HEADs when available:
  NEXUS_ROUTE_MANIFEST_EXPECTED_COMMIT
  NEXUS_ANDROID_WALLET_EXPECTED_COMMIT
  NEXUS_IOS_WALLET_EXPECTED_COMMIT
  NEXUS_WEB_WALLET_EXPECTED_COMMIT
USAGE
}

while (($#)); do
  case "$1" in
    --evidence)
      [[ $# -ge 2 ]] || { echo "[nexus-production-evidence][error] --evidence requires a path" >&2; exit 2; }
      EVIDENCE_FILE="$2"
      shift 2
      ;;
    --require-ready)
      REQUIRE_READY=true
      shift
      ;;
    --self-test-receipts)
      [[ $# -ge 2 ]] || { echo "[nexus-production-evidence][error] --self-test-receipts requires a path" >&2; exit 2; }
      SELF_TEST_RECEIPTS_DIR="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "[nexus-production-evidence][error] Unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [[ -n "$SELF_TEST_RECEIPTS_DIR" ]]; then
  [[ "${NEXUS_EVIDENCE_SELF_TEST:-}" == "1" ]] || {
    echo "[nexus-production-evidence][error] --self-test-receipts requires NEXUS_EVIDENCE_SELF_TEST=1" >&2
    exit 2
  }
  [[ "$REQUIRE_READY" == false ]] || {
    echo "[nexus-production-evidence][error] --self-test-receipts cannot be combined with --require-ready" >&2
    exit 2
  }
fi

for unsafe_name in \
  NEXUS_RECEIPT_BASE_URL NEXUS_TORII_BASE_URL NEXUS_MCP_URL \
  NEXUS_RECEIPT_FIXTURE_DIR NODE_BIN NODE_EXTRA_CA_CERTS NODE_TLS_REJECT_UNAUTHORIZED \
  NODE_PATH NPM_CONFIG_NODE_OPTIONS npm_config_node_options NODE_USE_SYSTEM_CA \
  SSL_CERT_FILE SSL_CERT_DIR SSLKEYLOGFILE OPENSSL_CONF \
  HTTP_PROXY HTTPS_PROXY ALL_PROXY NO_PROXY http_proxy https_proxy all_proxy no_proxy \
  GLOBAL_AGENT_HTTP_PROXY GLOBAL_AGENT_HTTPS_PROXY GLOBAL_AGENT_NO_PROXY \
  GLOBAL_AGENT_ENVIRONMENT_VARIABLE_NAMESPACE; do
  if [[ -n "${!unsafe_name:-}" ]]; then
    echo "[nexus-production-evidence][error] ambient transport override $unsafe_name is forbidden" >&2
    exit 2
  fi
done
if [[ -n "${NODE_OPTIONS:-}" ]]; then
  echo "[nexus-production-evidence][error] ambient transport override NODE_OPTIONS is forbidden" >&2
  exit 2
fi
if [[ -n "${NODE_USE_ENV_PROXY:-}" && "${NODE_USE_ENV_PROXY}" != "0" ]]; then
  echo "[nexus-production-evidence][error] ambient transport override NODE_USE_ENV_PROXY is forbidden" >&2
  exit 2
fi

NODE_BIN="$(resolve_canonical_node)" || fail_setup "canonical Node executable is required for structured JSON validation"
[[ -f "$SCRIPT_DIR/verify-nexus-production-receipts.mjs" && ! -L "$SCRIPT_DIR/verify-nexus-production-receipts.mjs" ]] ||
  fail_setup "Nexus production receipt verifier must be a regular non-symlink file"

CLEAN_NODE_ENV=(
  /usr/bin/env
  -u NODE_OPTIONS -u NODE_BIN -u NODE_PATH -u NPM_CONFIG_NODE_OPTIONS -u npm_config_node_options
  -u NODE_EXTRA_CA_CERTS -u NODE_TLS_REJECT_UNAUTHORIZED -u NODE_USE_ENV_PROXY -u NODE_USE_SYSTEM_CA
  -u SSL_CERT_FILE -u SSL_CERT_DIR -u SSLKEYLOGFILE -u OPENSSL_CONF
  -u HTTP_PROXY -u HTTPS_PROXY -u ALL_PROXY -u NO_PROXY
  -u http_proxy -u https_proxy -u all_proxy -u no_proxy
  -u GLOBAL_AGENT_HTTP_PROXY -u GLOBAL_AGENT_HTTPS_PROXY -u GLOBAL_AGENT_NO_PROXY
  -u GLOBAL_AGENT_ENVIRONMENT_VARIABLE_NAMESPACE
)

"${CLEAN_NODE_ENV[@]}" "$NODE_BIN" - "$EVIDENCE_FILE" "$REQUIRE_READY" "$ROOT_DIR" <<'NODE'
const childProcess = require('child_process');
const fs = require('fs');
const path = require('path');

const [evidenceFile, requireReadyRaw, rootDir] = process.argv.slice(2);
const requireReady = requireReadyRaw === 'true';
const errors = [];
const MAX_CLOCK_SKEW_MS = 5 * 60 * 1000;
const EVIDENCE_FRESHNESS_WINDOW_MS = 24 * 60 * 60 * 1000;
// Use one immutable second boundary so a whole-second timestamp exactly 24 hours
// old remains valid throughout its boundary second.
const AUDIT_NOW_MS = Math.floor(Date.now() / 1000) * 1000;
const ROUTE_MANIFEST_EXPECTED_COMMIT_ENV = 'NEXUS_ROUTE_MANIFEST_EXPECTED_COMMIT';
const WALLET_EXPECTED_COMMIT_ENV = {
  android: 'NEXUS_ANDROID_WALLET_EXPECTED_COMMIT',
  ios: 'NEXUS_IOS_WALLET_EXPECTED_COMMIT',
  web: 'NEXUS_WEB_WALLET_EXPECTED_COMMIT',
};
const EXPECTED_COMMIT_REPOS = {
  routeManifest: { label: '../iroha', repoPath: path.resolve(rootDir, '..', 'iroha') },
  android: { label: 'fearless-Android-production-consolidated-20260731', repoPath: path.resolve(rootDir, 'fearless-Android-production-consolidated-20260731') },
  ios: { label: 'fearless-iOS-production-consolidated-20260731', repoPath: path.resolve(rootDir, 'fearless-iOS-production-consolidated-20260731') },
  web: { label: 'fearless-wallet-web', repoPath: path.resolve(rootDir, 'fearless-wallet-web') },
};

const EXPECTED_SCOPE = 'sora-nexus-production-readiness';
const EXPECTED_NETWORK = 'sora-nexus-mainnet';
const EXPECTED_CHAIN_ID = 'sora:nexus:global';
const EXPECTED_TORII = 'https://minamoto.sora.org';
const EXPECTED_MCP = 'https://minamoto.sora.org/v1/mcp';
const EXPECTED_HEALTH = 'https://minamoto.sora.org/status';
const REQUIRED_BLOCKERS = [
  'nexus-live-health-failing',
  'route-publication-evidence-missing',
  'route-canary-evidence-missing',
  'wallet-live-transfer-smoke-missing',
];
const REQUIRED_COMMANDS = [
  'bash scripts/test-nexus-production-evidence-template.sh',
  'bash scripts/generate-nexus-production-evidence-template.sh --output build/reports/nexus-production-evidence-template.json',
  'bash scripts/test-nexus-production-evidence-audit.sh',
  'bash scripts/audit-nexus-production-evidence.sh --require-ready',
  'IROHA_NEXUS_REQUIRE_PRODUCTION_EVIDENCE=1 IROHA_NEXUS_LIVE_HEALTH=1 bash scripts/audit-iroha-release-readiness.sh',
  'bash scripts/audit-iroha-wallet-coverage.sh',
];
const REQUIRED_FIELDS = [
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
const REQUIRED_WALLET_PLATFORMS = ['android', 'ios', 'web'];
const ALLOWED_MANIFEST_FIELDS = new Set([
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
const ALLOWED_PUBLICATION_FIELDS = new Set([
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
const ALLOWED_CANARY_FIELDS = new Set([
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
const ALLOWED_WALLET_SMOKE_FIELDS = new Set([
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
const SECRET_KEY_PATTERN =
  /(?:secret|password|token|private[_-]?key|authorization|cookie|seed|mnemonic|credentialStoreSnapshot|credentialsByStorageKey|clientDataJSON)/iu;
const SECRET_VALUE_PATTERN =
  /(?:AKIA[0-9A-Z]{16}|gh[pousr]_[A-Za-z0-9_]{20,}|sk-[A-Za-z0-9_-]{20,}|xox[baprs]-[A-Za-z0-9-]{10,})/u;

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
    const stat = fs.lstatSync(file);
    if (!stat.isFile() || stat.isSymbolicLink()) {
      fail(`Nexus production evidence manifest must be a regular non-symlink file: ${file}`);
      return null;
    }
    if (stat.size > 256 * 1024) {
      fail('Nexus production evidence manifest must not exceed 262144 bytes');
      return null;
    }
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

function nonEmptyString(value) {
  return typeof value === 'string' && value.trim().length > 0;
}

function isCommit(value) {
  return /^[0-9a-f]{40}$/iu.test(String(value || ''));
}

function isLowercaseCommit(value) {
  return /^[0-9a-f]{40}$/u.test(String(value || ''));
}

function isSha256(value) {
  return /^sha256:[0-9a-f]{64}$/iu.test(String(value || ''));
}

function isTxHash(value) {
  return /^0x[0-9a-f]{64}$/iu.test(String(value || ''));
}

function isRepeatedHexPlaceholder(value) {
  const hex = String(value || '')
    .replace(/^sha256:/iu, '')
    .replace(/^0x/iu, '')
    .toLowerCase();
  return /^[0-9a-f]+$/u.test(hex) && new Set(hex).size === 1;
}

function isPlaceholderText(value) {
  const normalized = String(value || '').trim().toLowerCase();
  return /^(todo|tbd|placeholder|example|sample|dummy|unknown|n\/a)(?:$|[_\-\s:])/u.test(normalized);
}

function validatePublicOperator(value, path) {
  if (typeof value !== 'string') return;
  if (/[\u0000-\u001f\u007f]/u.test(value)) {
    fail(`${path}: operator must be a single-line public value`);
  }
  if (SECRET_VALUE_PATTERN.test(value)) {
    fail(`${path}: operator must not contain secret-like token`);
  }
  if (isPlaceholderText(value)) {
    fail(`${path}: operator must not be a placeholder operator`);
  }
}

function isIsoUtcTimestamp(value) {
  return timestampMillis(value) !== null;
}

function timestampMillis(value) {
  if (
    typeof value !== 'string' ||
    !/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,9})?Z$/u.test(value)
  ) {
    return null;
  }
  const millis = Date.parse(value);
  if (!Number.isFinite(millis)) return null;
  const seconds = value.slice(0, 19);
  return new Date(millis).toISOString().slice(0, 19) === seconds ? millis : null;
}

function isFutureTimestamp(value) {
  const millis = timestampMillis(value);
  return millis !== null && millis > AUDIT_NOW_MS + MAX_CLOCK_SKEW_MS;
}

function isOutsideEvidenceFreshnessWindow(value) {
  const millis = timestampMillis(value);
  return millis !== null && AUDIT_NOW_MS - millis > EVIDENCE_FRESHNESS_WINDOW_MS;
}

function assertNoSecretLikeKeys(value, path = 'Nexus production evidence') {
  if (Array.isArray(value)) {
    value.forEach((entry, index) => assertNoSecretLikeKeys(entry, `${path}[${index}]`));
    return;
  }
  if (!isRecord(value)) return;

  for (const [key, nested] of Object.entries(value)) {
    const nestedPath = `${path}.${key}`;
    if (SECRET_KEY_PATTERN.test(key)) {
      fail(`${nestedPath} must not be included in public Nexus production evidence`);
    }
    assertNoSecretLikeKeys(nested, nestedPath);
  }
}

function assertNoSecretLikeValues(value, path = 'Nexus production evidence') {
  if (typeof value === 'string') {
    if (SECRET_VALUE_PATTERN.test(value)) {
      fail(`${path} must not contain secret-like token`);
    }
    return;
  }

  if (Array.isArray(value)) {
    value.forEach((entry, index) => assertNoSecretLikeValues(entry, `${path}[${index}]`));
    return;
  }

  if (!isRecord(value)) return;

  for (const [key, nested] of Object.entries(value)) {
    assertNoSecretLikeValues(nested, `${path}.${key}`);
  }
}

function resolveExpectedCommit(envName, repoInfo) {
  const override = process.env[envName];
  if (override !== undefined && override !== '') {
    if (!isLowercaseCommit(override)) {
      fail(`${envName} must be a 40-character lowercase git commit`);
      return null;
    }
    return override;
  }

  try {
    const commit = childProcess.execFileSync('/usr/bin/git', ['-C', repoInfo.repoPath, 'rev-parse', 'HEAD'], {
      encoding: 'utf8',
      stdio: ['ignore', 'pipe', 'pipe'],
      timeout: 10_000,
      env: {
        PATH: '/usr/bin:/bin',
        HOME: '/',
        GIT_CONFIG_NOSYSTEM: '1',
        GIT_CONFIG_GLOBAL: '/dev/null',
        GIT_NO_REPLACE_OBJECTS: '1',
        GIT_TERMINAL_PROMPT: '0',
      },
    }).trim();
    if (isLowercaseCommit(commit)) {
      return commit;
    }
    fail(`${envName} must be set because ${repoInfo.label} HEAD was not a 40-character lowercase git commit: ${commit}`);
    return null;
  } catch (error) {
    const detail = String(error.stderr || error.message || error).trim();
    fail(`${envName} must be set because ${repoInfo.label} HEAD could not be determined${detail ? `: ${detail}` : ''}`);
    return null;
  }
}

function resolveExpectedCommits() {
  return {
    routeManifest: resolveExpectedCommit(ROUTE_MANIFEST_EXPECTED_COMMIT_ENV, EXPECTED_COMMIT_REPOS.routeManifest),
    wallets: {
      android: resolveExpectedCommit(WALLET_EXPECTED_COMMIT_ENV.android, EXPECTED_COMMIT_REPOS.android),
      ios: resolveExpectedCommit(WALLET_EXPECTED_COMMIT_ENV.ios, EXPECTED_COMMIT_REPOS.ios),
      web: resolveExpectedCommit(WALLET_EXPECTED_COMMIT_ENV.web, EXPECTED_COMMIT_REPOS.web),
    },
  };
}

function rejectUnsupportedKeys(record, allowedFields, prefix, messagePrefix) {
  if (!isRecord(record)) return;
  for (const field of Object.keys(record)) {
    if (!allowedFields.has(field)) {
      fail(`${messagePrefix} ${prefix}.${field}`);
    }
  }
}

function requireStringField(record, field, prefix) {
  if (!nonEmptyString(record[field])) {
    fail(`${prefix}.${field} must be a non-empty string`);
    return '';
  }
  return String(record[field]).trim();
}

function isPositiveDecimalString(value) {
  const text = String(value || '');
  return (
    text.length <= 80 &&
    /^(?:0\.[0-9]+|[1-9][0-9]*(?:\.[0-9]+)?)$/u.test(text) &&
    !/^0(?:\.0+)?$/u.test(text)
  );
}

function validatePublication(record, index, seenTxHashes) {
  const prefix = `routePublicationEvidence[${index}]`;
  if (!isRecord(record)) {
    fail(`${prefix} must be an object`);
    return null;
  }
  rejectUnsupportedKeys(record, ALLOWED_PUBLICATION_FIELDS, prefix, 'unsupported Nexus route publication evidence field');

  const routeManifestCommit = requireStringField(record, 'routeManifestCommit', prefix);
  const routeManifestSourcePath = requireStringField(record, 'routeManifestSourcePath', prefix);
  const routeManifestHash = requireStringField(record, 'routeManifestHash', prefix);
  const txHash = requireStringField(record, 'publicationTransactionHash', prefix);
  requireStringField(record, 'publicationAuthority', prefix);
  const operator = requireStringField(record, 'operator', prefix);
  validatePublicOperator(operator, `${prefix}.operator`);

  if (!isCommit(routeManifestCommit)) {
    fail(`${prefix}.routeManifestCommit must be a 40-character git commit`);
  } else if (isRepeatedHexPlaceholder(routeManifestCommit)) {
    fail(`${prefix}.routeManifestCommit must not be a placeholder git commit`);
  }
  if (routeManifestSourcePath !== 'artifacts/nexus/production-route-governance-action.json') {
    fail(`${prefix}.routeManifestSourcePath must be artifacts/nexus/production-route-governance-action.json`);
  }
  if (!isSha256(routeManifestHash)) {
    fail(`${prefix}.routeManifestHash must be a sha256 route manifest hash`);
  } else if (isRepeatedHexPlaceholder(routeManifestHash)) {
    fail(`${prefix}.routeManifestHash must not be a placeholder route manifest hash`);
  }
  if (!isTxHash(txHash)) {
    fail(`${prefix}.publicationTransactionHash must be a 0x-prefixed 32-byte hash`);
  } else if (isRepeatedHexPlaceholder(txHash)) {
    fail(`${prefix}.publicationTransactionHash must not be a placeholder transaction hash`);
  }
  if (seenTxHashes.has(txHash)) {
    fail(`duplicate Nexus transaction evidence hash: ${txHash}`);
  }
  seenTxHashes.add(txHash);
  if (!isIsoUtcTimestamp(record.publishedAt)) {
    fail(`${prefix}.publishedAt must be a canonical UTC RFC3339 timestamp`);
  } else if (isFutureTimestamp(record.publishedAt)) {
    fail(`${prefix}.publishedAt must not be in the future`);
  }
  if (record.toriiBaseUrl !== EXPECTED_TORII) {
    fail(`${prefix}.toriiBaseUrl must be ${EXPECTED_TORII}`);
  }
  if (record.mcpUrl !== EXPECTED_MCP) {
    fail(`${prefix}.mcpUrl must be ${EXPECTED_MCP}`);
  }

  return {
    index,
    commit: routeManifestCommit,
    hash: routeManifestHash,
    publishedAt: isIsoUtcTimestamp(record.publishedAt) ? timestampMillis(record.publishedAt) : null,
  };
}

function validateCanary(
  record,
  index,
  publishedHashes,
  readyClaimed,
  seenTxHashes,
) {
  const prefix = `routeCanaryEvidence[${index}]`;
  if (!isRecord(record)) {
    fail(`${prefix} must be an object`);
    return;
  }
  rejectUnsupportedKeys(record, ALLOWED_CANARY_FIELDS, prefix, 'unsupported Nexus route canary evidence field');

  const routeManifestHash = requireStringField(record, 'publishedRouteManifestHash', prefix);
  const txHash = requireStringField(record, 'routeCanaryTransactionHash', prefix);
  requireStringField(record, 'authority', prefix);
  const sourceAccount = requireStringField(record, 'sourceAccount', prefix);
  const destinationAccount = requireStringField(record, 'destinationAccount', prefix);
  requireStringField(record, 'assetId', prefix);
  requireStringField(record, 'amount', prefix);
  const operator = requireStringField(record, 'operator', prefix);
  validatePublicOperator(operator, `${prefix}.operator`);

  if (!isSha256(routeManifestHash)) {
    fail(`${prefix}.publishedRouteManifestHash must be a sha256 route manifest hash`);
  } else if (isRepeatedHexPlaceholder(routeManifestHash)) {
    fail(`${prefix}.publishedRouteManifestHash must not be a placeholder route manifest hash`);
  } else if (!publishedHashes.has(routeManifestHash)) {
    fail(`${prefix} must reference a published routeManifestHash`);
  }
  if (!isTxHash(txHash)) {
    fail(`${prefix}.routeCanaryTransactionHash must be a 0x-prefixed 32-byte hash`);
  } else if (isRepeatedHexPlaceholder(txHash)) {
    fail(`${prefix}.routeCanaryTransactionHash must not be a placeholder transaction hash`);
  }
  if (seenTxHashes.has(txHash)) {
    fail(`duplicate Nexus transaction evidence hash: ${txHash}`);
  }
  seenTxHashes.add(txHash);
  if (sourceAccount && destinationAccount && sourceAccount === destinationAccount) {
    fail(`${prefix}.sourceAccount and destinationAccount must be distinct`);
  }
  if (!isPositiveDecimalString(record.amount)) {
    fail(`${prefix}.amount must be a positive decimal string`);
  }
  if (!isIsoUtcTimestamp(record.routeCanaryCheckedAt)) {
    fail(`${prefix}.routeCanaryCheckedAt must be a canonical UTC RFC3339 timestamp`);
  } else if (isFutureTimestamp(record.routeCanaryCheckedAt)) {
    fail(`${prefix}.routeCanaryCheckedAt must not be in the future`);
  } else if (readyClaimed && isOutsideEvidenceFreshnessWindow(record.routeCanaryCheckedAt)) {
    fail(`${prefix}.routeCanaryCheckedAt must be within the last 24 hours for ready Nexus production evidence`);
  }
  if (record.toriiBaseUrl !== EXPECTED_TORII) {
    fail(`${prefix}.toriiBaseUrl must be ${EXPECTED_TORII}`);
  }
}

function validateWalletSmoke(
  record,
  index,
  publishedHashes,
  readyClaimed,
  seenTxHashes,
  expectedWalletCommits,
) {
  const prefix = `walletSmokeEvidence[${index}]`;
  if (!isRecord(record)) {
    fail(`${prefix} must be an object`);
    return;
  }
  rejectUnsupportedKeys(record, ALLOWED_WALLET_SMOKE_FIELDS, prefix, 'unsupported Nexus wallet smoke evidence field');

  const platform = requireStringField(record, 'platform', prefix);
  const walletCommit = requireStringField(record, 'walletCommit', prefix);
  const routeManifestHash = requireStringField(record, 'routeManifestHash', prefix);
  const txHash = requireStringField(record, 'walletSmokeTransactionHash', prefix);
  const sourceAccount = requireStringField(record, 'sourceAccount', prefix);
  const destinationAccount = requireStringField(record, 'destinationAccount', prefix);
  requireStringField(record, 'assetId', prefix);
  requireStringField(record, 'amount', prefix);
  const operator = requireStringField(record, 'operator', prefix);
  validatePublicOperator(operator, `${prefix}.operator`);

  if (!['android', 'ios', 'web'].includes(platform)) {
    fail(`${prefix}.platform must be android, ios, or web`);
  }
  if (!isCommit(walletCommit)) {
    fail(`${prefix}.walletCommit must be a 40-character git commit`);
  } else if (isRepeatedHexPlaceholder(walletCommit)) {
    fail(`${prefix}.walletCommit must not be a placeholder git commit`);
  } else if (expectedWalletCommits?.[platform] && walletCommit !== expectedWalletCommits[platform]) {
    fail(`${prefix}.walletCommit must match expected ${platform} wallet commit ${expectedWalletCommits[platform]}`);
  }
  if (!isSha256(routeManifestHash)) {
    fail(`${prefix}.routeManifestHash must be a sha256 route manifest hash`);
  } else if (isRepeatedHexPlaceholder(routeManifestHash)) {
    fail(`${prefix}.routeManifestHash must not be a placeholder route manifest hash`);
  } else if (!publishedHashes.has(routeManifestHash)) {
    fail(`${prefix} must reference a published routeManifestHash`);
  }
  if (!isTxHash(txHash)) {
    fail(`${prefix}.walletSmokeTransactionHash must be a 0x-prefixed 32-byte hash`);
  } else if (isRepeatedHexPlaceholder(txHash)) {
    fail(`${prefix}.walletSmokeTransactionHash must not be a placeholder transaction hash`);
  }
  if (seenTxHashes.has(txHash)) {
    fail(`duplicate Nexus transaction evidence hash: ${txHash}`);
  }
  seenTxHashes.add(txHash);
  if (sourceAccount && destinationAccount && sourceAccount === destinationAccount) {
    fail(`${prefix}.sourceAccount and destinationAccount must be distinct`);
  }
  if (!isPositiveDecimalString(record.amount)) {
    fail(`${prefix}.amount must be a positive decimal string`);
  }
  if (!isIsoUtcTimestamp(record.walletSmokeSubmittedAt)) {
    fail(`${prefix}.walletSmokeSubmittedAt must be a canonical UTC RFC3339 timestamp`);
  } else if (isFutureTimestamp(record.walletSmokeSubmittedAt)) {
    fail(`${prefix}.walletSmokeSubmittedAt must not be in the future`);
  } else if (readyClaimed && isOutsideEvidenceFreshnessWindow(record.walletSmokeSubmittedAt)) {
    fail(`${prefix}.walletSmokeSubmittedAt must be within the last 24 hours for ready Nexus production evidence`);
  }
  if (!isIsoUtcTimestamp(record.walletSmokeObservedAt)) {
    fail(`${prefix}.walletSmokeObservedAt must be a canonical UTC RFC3339 timestamp`);
  } else if (isFutureTimestamp(record.walletSmokeObservedAt)) {
    fail(`${prefix}.walletSmokeObservedAt must not be in the future`);
  } else if (
    isIsoUtcTimestamp(record.walletSmokeSubmittedAt) &&
    timestampMillis(record.walletSmokeObservedAt) < timestampMillis(record.walletSmokeSubmittedAt)
  ) {
    fail(`${prefix}.walletSmokeObservedAt must be at or after walletSmokeSubmittedAt`);
  } else if (readyClaimed && isOutsideEvidenceFreshnessWindow(record.walletSmokeObservedAt)) {
    fail(`${prefix}.walletSmokeObservedAt must be within the last 24 hours for ready Nexus production evidence`);
  }
  if (record.toriiBaseUrl !== EXPECTED_TORII) {
    fail(`${prefix}.toriiBaseUrl must be ${EXPECTED_TORII}`);
  }
  return ['android', 'ios', 'web'].includes(platform) ? { platform } : null;
}

const manifest = readJson(evidenceFile);
if (manifest) {
  assertNoSecretLikeKeys(manifest);
  assertNoSecretLikeValues(manifest);
  rejectUnsupportedKeys(manifest, ALLOWED_MANIFEST_FIELDS, 'manifest', 'unsupported Nexus production evidence manifest field');

  if (manifest.schemaVersion !== 1) {
    fail('schemaVersion must be 1');
  }
  if (manifest.scope !== EXPECTED_SCOPE) {
    fail(`scope must be ${EXPECTED_SCOPE}`);
  }
  if (manifest.network !== EXPECTED_NETWORK) {
    fail(`network must be ${EXPECTED_NETWORK}`);
  }
  if (manifest.chainId !== EXPECTED_CHAIN_ID) {
    fail(`chainId must be ${EXPECTED_CHAIN_ID}`);
  }
  if (manifest.toriiBaseUrl !== EXPECTED_TORII) {
    fail(`toriiBaseUrl must be ${EXPECTED_TORII}`);
  }
  if (manifest.mcpUrl !== EXPECTED_MCP) {
    fail(`mcpUrl must be ${EXPECTED_MCP}`);
  }
  if (manifest.healthUrl !== EXPECTED_HEALTH) {
    fail(`healthUrl must be ${EXPECTED_HEALTH}`);
  }

  if (!['blocked', 'ready'].includes(manifest.status)) {
    fail('status must be blocked or ready');
  }
  if (typeof manifest.releaseEnabled !== 'boolean') {
    fail('releaseEnabled must be a boolean');
  }
  if (manifest.status === 'blocked' && manifest.releaseEnabled) {
    fail('releaseEnabled must remain false while Nexus production evidence is blocked');
  }
  if (requireReady && manifest.status !== 'ready') {
    fail('status must be ready when --require-ready is used');
  }

  const commandList = requireArray(manifest.readyVerificationCommands, 'readyVerificationCommands');
  const commands = new Set(commandList);
  if (commands.size !== commandList.length) {
    fail('duplicate Nexus production evidence verification command');
  }
  for (const command of REQUIRED_COMMANDS) {
    if (!commands.has(command)) {
      fail(`readyVerificationCommands missing ${command}`);
    }
  }

  const declaredFieldList = requireArray(manifest.requiredEvidenceFields, 'requiredEvidenceFields');
  const declaredFields = new Set(declaredFieldList);
  if (declaredFields.size !== declaredFieldList.length) {
    fail('duplicate Nexus production evidence required field');
  }
  for (const field of REQUIRED_FIELDS) {
    if (!declaredFields.has(field)) {
      fail(`requiredEvidenceFields missing ${field}`);
    }
  }
  for (const field of declaredFieldList) {
    if (!REQUIRED_FIELDS.includes(field)) {
      fail(`unsupported required Nexus production evidence field: ${field}`);
    }
  }

  const publications = requireArray(manifest.routePublicationEvidence, 'routePublicationEvidence');
  const canaries = requireArray(manifest.routeCanaryEvidence, 'routeCanaryEvidence');
  const walletSmokes = requireArray(manifest.walletSmokeEvidence, 'walletSmokeEvidence');
  const readyClaimed = manifest.status === 'ready' || manifest.releaseEnabled || requireReady;
  const readyEvidenceClaimed = manifest.status === 'ready' || manifest.releaseEnabled === true;
  const expectedCommits = readyEvidenceClaimed ? resolveExpectedCommits() : null;

  if (manifest.status === 'blocked') {
    const manifestBlockers = requireArray(manifest.blockers, 'blockers');
    const blockers = new Set(manifestBlockers);
    for (const blocker of REQUIRED_BLOCKERS) {
      if (!blockers.has(blocker)) {
        fail(`blocked Nexus production evidence missing blocker ${blocker}`);
      }
    }
    for (const blocker of manifestBlockers) {
      if (!REQUIRED_BLOCKERS.includes(blocker)) {
        fail(`unsupported Nexus production evidence blocker: ${blocker}`);
      }
    }
    if (blockers.size !== manifestBlockers.length) {
      fail('duplicate Nexus production evidence blocker');
    }
    if (publications.length !== 0) {
      fail('blocked Nexus production evidence must keep routePublicationEvidence empty');
    }
    if (canaries.length !== 0) {
      fail('blocked Nexus production evidence must keep routeCanaryEvidence empty');
    }
    if (walletSmokes.length !== 0) {
      fail('blocked Nexus production evidence must keep walletSmokeEvidence empty');
    }
  }

  if (readyClaimed) {
    if (!manifest.releaseEnabled) {
      fail('releaseEnabled must be true when Nexus production evidence is ready');
    }
    if (!Array.isArray(manifest.blockers) || manifest.blockers.length !== 0) {
      fail('ready Nexus production evidence must not list blockers');
    }
    if (publications.length === 0 || canaries.length === 0 || walletSmokes.length === 0) {
      fail('ready Nexus production evidence requires route publication, canary, and wallet smoke evidence');
    }
  }

  const seenTxHashes = new Set();
  const publicationRecords = publications
    .map((entry, index) => validatePublication(entry, index, seenTxHashes))
    .filter(Boolean);
  const publishedHashes = new Set(publicationRecords.map((entry) => entry.hash));

  canaries.forEach((entry, index) =>
    validateCanary(
      entry,
      index,
      publishedHashes,
      readyClaimed,
      seenTxHashes,
    ),
  );
  const walletSmokeRecords = walletSmokes
    .map((entry, index) =>
      validateWalletSmoke(
        entry,
        index,
        publishedHashes,
        readyClaimed,
        seenTxHashes,
        expectedCommits?.wallets,
      ),
    )
    .filter(Boolean);

  if (readyClaimed) {
    const walletSmokePlatforms = new Set();
    for (const record of walletSmokeRecords) {
      if (walletSmokePlatforms.has(record.platform)) {
        fail(`duplicate Nexus wallet smoke platform: ${record.platform}`);
      }
      walletSmokePlatforms.add(record.platform);
    }
    for (const platform of REQUIRED_WALLET_PLATFORMS) {
      if (!walletSmokePlatforms.has(platform)) {
        fail(`ready Nexus production evidence requires wallet smoke evidence for ${platform}`);
      }
    }
  }
}

if (errors.length > 0) {
  for (const error of errors) {
    console.error(`[nexus-production-evidence][error] ${error}`);
  }
  process.exit(1);
}

console.log(
  `[nexus-production-evidence] status=${manifest.status} releaseEnabled=${manifest.releaseEnabled} publications=${manifest.routePublicationEvidence.length} canaries=${manifest.routeCanaryEvidence.length} walletSmokes=${manifest.walletSmokeEvidence.length}`,
);
NODE

receipt_args=(
  --evidence "$EVIDENCE_FILE"
  --root "$ROOT_DIR"
)
if [[ -n "$SELF_TEST_RECEIPTS_DIR" ]]; then
  receipt_args+=(--self-test-receipts "$SELF_TEST_RECEIPTS_DIR")
fi
"${CLEAN_NODE_ENV[@]}" "$NODE_BIN" "$SCRIPT_DIR/verify-nexus-production-receipts.mjs" "${receipt_args[@]}"
