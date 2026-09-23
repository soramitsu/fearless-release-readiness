#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
AUDIT_SCRIPT="$SCRIPT_DIR/audit-nexus-production-evidence.sh"
RECEIPT_VERIFIER="$SCRIPT_DIR/verify-nexus-production-receipts.mjs"
ROUTE_MANIFEST_COMMIT="0123456789abcdef0123456789abcdef01234567"
ANDROID_WALLET_COMMIT="89abcdef89abcdef89abcdef89abcdef89abcdef"
IOS_WALLET_COMMIT="abcdef0123456789abcdef0123456789abcdef01"
WEB_WALLET_COMMIT="456789abcdef0123456789abcdef0123456789ab"
negative_cases=0
positive_cases=0

fail() {
  echo "[nexus-production-evidence-test][error] $*" >&2
  exit 1
}

write_blocked_manifest() {
  local file="$1"
  cat >"$file" <<'JSON'
{
  "schemaVersion": 1,
  "scope": "sora-nexus-production-readiness",
  "network": "sora-nexus-mainnet",
  "chainId": "sora:nexus:global",
  "toriiBaseUrl": "https://minamoto.sora.org",
  "mcpUrl": "https://minamoto.sora.org/v1/mcp",
  "healthUrl": "https://minamoto.sora.org/status",
  "status": "blocked",
  "releaseEnabled": false,
  "blockers": [
    "nexus-live-health-failing",
    "route-publication-evidence-missing",
    "route-canary-evidence-missing",
    "wallet-live-transfer-smoke-missing"
  ],
  "readyVerificationCommands": [
    "bash scripts/test-nexus-production-evidence-template.sh",
    "bash scripts/generate-nexus-production-evidence-template.sh --output build/reports/nexus-production-evidence-template.json",
    "bash scripts/test-nexus-production-evidence-audit.sh",
    "bash scripts/audit-nexus-production-evidence.sh --require-ready",
    "IROHA_NEXUS_REQUIRE_PRODUCTION_EVIDENCE=1 IROHA_NEXUS_LIVE_HEALTH=1 bash scripts/audit-iroha-release-readiness.sh",
    "bash scripts/audit-iroha-wallet-coverage.sh"
  ],
  "requiredEvidenceFields": [
    "routeManifestCommit",
    "routeManifestSourcePath",
    "routeManifestHash",
    "publicationTransactionHash",
    "publicationAuthority",
    "publishedAt",
    "routeCanaryTransactionHash",
    "routeCanaryCheckedAt",
    "routeCanarySourceAccount",
    "routeCanaryDestinationAccount",
    "routeCanaryAssetId",
    "routeCanaryAmount",
    "walletPlatform",
    "walletCommit",
    "walletSmokeTransactionHash",
    "walletSmokeSubmittedAt",
    "walletSmokeObservedAt",
    "operator"
  ],
  "routePublicationEvidence": [],
  "routeCanaryEvidence": [],
  "walletSmokeEvidence": []
}
JSON
}

write_ready_manifest() {
  local file="$1"
  cat >"$file" <<'JSON'
{
  "schemaVersion": 1,
  "scope": "sora-nexus-production-readiness",
  "network": "sora-nexus-mainnet",
  "chainId": "sora:nexus:global",
  "toriiBaseUrl": "https://minamoto.sora.org",
  "mcpUrl": "https://minamoto.sora.org/v1/mcp",
  "healthUrl": "https://minamoto.sora.org/status",
  "status": "ready",
  "releaseEnabled": true,
  "blockers": [],
  "readyVerificationCommands": [
    "bash scripts/test-nexus-production-evidence-template.sh",
    "bash scripts/generate-nexus-production-evidence-template.sh --output build/reports/nexus-production-evidence-template.json",
    "bash scripts/test-nexus-production-evidence-audit.sh",
    "bash scripts/audit-nexus-production-evidence.sh --require-ready",
    "IROHA_NEXUS_REQUIRE_PRODUCTION_EVIDENCE=1 IROHA_NEXUS_LIVE_HEALTH=1 bash scripts/audit-iroha-release-readiness.sh",
    "bash scripts/audit-iroha-wallet-coverage.sh"
  ],
  "requiredEvidenceFields": [
    "routeManifestCommit",
    "routeManifestSourcePath",
    "routeManifestHash",
    "publicationTransactionHash",
    "publicationAuthority",
    "publishedAt",
    "routeCanaryTransactionHash",
    "routeCanaryCheckedAt",
    "routeCanarySourceAccount",
    "routeCanaryDestinationAccount",
    "routeCanaryAssetId",
    "routeCanaryAmount",
    "walletPlatform",
    "walletCommit",
    "walletSmokeTransactionHash",
    "walletSmokeSubmittedAt",
    "walletSmokeObservedAt",
    "operator"
  ],
  "routePublicationEvidence": [
    {
      "routeManifestCommit": "0123456789abcdef0123456789abcdef01234567",
      "routeManifestSourcePath": "artifacts/nexus/production-route-governance-action.json",
      "routeManifestHash": "sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
      "publicationTransactionHash": "0x0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
      "publicationAuthority": "release-authority@sora",
      "publishedAt": "2026-06-26T00:00:00Z",
      "toriiBaseUrl": "https://minamoto.sora.org",
      "mcpUrl": "https://minamoto.sora.org/v1/mcp",
      "operator": "release"
    }
  ],
  "routeCanaryEvidence": [
    {
      "publishedRouteManifestHash": "sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
      "routeCanaryTransactionHash": "0xfedcba9876543210fedcba9876543210fedcba9876543210fedcba9876543210",
      "authority": "release-authority@sora",
      "sourceAccount": "nexus-canary-source",
      "destinationAccount": "nexus-canary-destination",
      "assetId": "xor#sora",
      "amount": "1.0",
      "routeCanaryCheckedAt": "2026-06-26T00:10:00Z",
      "toriiBaseUrl": "https://minamoto.sora.org",
      "operator": "release"
    }
  ],
  "walletSmokeEvidence": [
    {
      "platform": "android",
      "walletCommit": "89abcdef89abcdef89abcdef89abcdef89abcdef",
      "routeManifestHash": "sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
      "walletSmokeTransactionHash": "0xabcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789",
      "sourceAccount": "nexus-android-source",
      "destinationAccount": "nexus-android-destination",
      "assetId": "xor#sora",
      "amount": "1.0",
      "walletSmokeSubmittedAt": "2026-06-26T00:20:00Z",
      "walletSmokeObservedAt": "2026-06-26T00:25:00Z",
      "toriiBaseUrl": "https://minamoto.sora.org",
      "operator": "release"
    },
    {
      "platform": "ios",
      "walletCommit": "abcdef0123456789abcdef0123456789abcdef01",
      "routeManifestHash": "sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
      "walletSmokeTransactionHash": "0x1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef",
      "sourceAccount": "nexus-ios-source",
      "destinationAccount": "nexus-ios-destination",
      "assetId": "xor#sora",
      "amount": "1.0",
      "walletSmokeSubmittedAt": "2026-06-26T00:21:00Z",
      "walletSmokeObservedAt": "2026-06-26T00:26:00Z",
      "toriiBaseUrl": "https://minamoto.sora.org",
      "operator": "release"
    },
    {
      "platform": "web",
      "walletCommit": "456789abcdef0123456789abcdef0123456789ab",
      "routeManifestHash": "sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
      "walletSmokeTransactionHash": "0xba9876543210fedcba9876543210fedcba9876543210fedcba9876543210fedc",
      "sourceAccount": "nexus-web-source",
      "destinationAccount": "nexus-web-destination",
      "assetId": "xor#sora",
      "amount": "1.0",
      "walletSmokeSubmittedAt": "2026-06-26T00:22:00Z",
      "walletSmokeObservedAt": "2026-06-26T00:27:00Z",
      "toriiBaseUrl": "https://minamoto.sora.org",
      "operator": "release"
    }
  ]
}
JSON

  NEXUS_READY_FIXTURE="$file" node <<'NODE'
const fs = require('fs');
const crypto = require('crypto');
const file = process.env.NEXUS_READY_FIXTURE;
const data = JSON.parse(fs.readFileSync(file, 'utf8'));
const encodedForCommit = (commit) => Buffer.from(`nexus-test-apply-sccp-route-governance-v1:${commit}`, 'utf8');
const routeHash = `sha256:${crypto.createHash('sha256').update(encodedForCommit(data.routePublicationEvidence[0].routeManifestCommit)).digest('hex')}`;
data.routePublicationEvidence[0].routeManifestHash = routeHash;
data.routeCanaryEvidence[0].publishedRouteManifestHash = routeHash;
data.walletSmokeEvidence.forEach((entry) => { entry.routeManifestHash = routeHash; });
const now = Math.floor(Date.now() / 1000) * 1000;
const isoSecondsAgo = (seconds) => new Date(now - seconds * 1000).toISOString().replace('.000Z', 'Z');
data.routeCanaryEvidence[0].routeCanaryCheckedAt = isoSecondsAgo(5 * 60);
data.walletSmokeEvidence.forEach((entry, index) => {
  entry.walletSmokeSubmittedAt = isoSecondsAgo(4 * 60 - index * 10);
  entry.walletSmokeObservedAt = isoSecondsAgo(3 * 60 - index * 10);
});
fs.writeFileSync(file, `${JSON.stringify(data, null, 2)}\n`);
NODE
}

mutate_manifest() {
  local source="$1"
  local dest="$2"
  local script="$3"
  node - "$source" "$dest" "$script" <<'NODE'
const fs = require('fs');
const crypto = require('crypto');
const [source, dest, script] = process.argv.slice(2);
const data = JSON.parse(fs.readFileSync(source, 'utf8'));
const routeHashForCommit = (commit) => {
  const bytes = Buffer.from(`nexus-test-apply-sccp-route-governance-v1:${commit}`, 'utf8');
  return `sha256:${crypto.createHash('sha256').update(bytes).digest('hex')}`;
};
new Function('data', 'routeHashForCommit', script)(data, routeHashForCommit);
fs.writeFileSync(dest, `${JSON.stringify(data, null, 2)}\n`);
NODE
}

prepare_receipt_fixtures() {
  local manifest="$1"
  local receipts_dir="$2"
  mkdir -p "$receipts_dir"
  NEXUS_RECEIPT_MANIFEST="$manifest" NEXUS_RECEIPT_FIXTURES="$receipts_dir" node <<'NODE'
const crypto = require('crypto');
const fs = require('fs');
const path = require('path');

const manifest = JSON.parse(fs.readFileSync(process.env.NEXUS_RECEIPT_MANIFEST, 'utf8'));
const out = process.env.NEXUS_RECEIPT_FIXTURES;
const writeJson = (file, value) => fs.writeFileSync(path.join(out, file), `${JSON.stringify(value, null, 2)}\n`);
const APPLY_WIRE_ID = 'iroha_data_model::isi::bridge::ApplySccpRouteGovernance';
const encodedForCommit = (commit) =>
  `0x${Buffer.from(`nexus-test-apply-sccp-route-governance-v1:${commit}`, 'utf8').toString('hex')}`;
const routeArtifact = (commit) => ({
  schemaVersion: 1,
  network: 'sora-nexus-mainnet',
  chainId: 'sora:nexus:global',
  publicationInstruction: {
    kind: 'ApplySccpRouteGovernance',
    wireId: APPLY_WIRE_ID,
    encoded: encodedForCommit(commit),
  },
});
const transferPayload = (record) => ({
  variant: 'Asset',
  value: {
    source: `${record.assetId}#${record.sourceAccount}`,
    destination: record.destinationAccount,
    object: record.amount,
  },
});
const statusRequest = (hash) => ({
  url: `https://minamoto.sora.org/v1/pipeline/transactions/status?hash=${hash.slice(2)}&scope=global`,
  method: 'GET',
  headers: { accept: 'application/json' },
  body: null,
});
const mcpRequest = (hash, suffix, name, args) => ({
  url: 'https://minamoto.sora.org/v1/mcp',
  method: 'POST',
  headers: { accept: 'application/json', 'content-type': 'application/json' },
  body: {
    jsonrpc: '2.0',
    id: `nexus-${suffix}-${hash.slice(2, 26)}`,
    method: 'tools/call',
    params: {
      name,
      arguments: args,
    },
  },
});
const transactionRequest = (hash) => mcpRequest(hash, 'tx', 'iroha.transactions.get', {
  hash: hash.slice(2),
  accept: 'application/json',
});
const instructionRequest = (hash) => mcpRequest(hash, 'isi', 'iroha.instructions.list', {
  transaction_hash: hash.slice(2),
  transaction_status: 'committed',
  page: 0,
  per_page: 2,
  accept: 'application/json',
});
const fixture = (request, responseBody) => ({
  mode: 'nexus-receipt-self-test-v1',
  request,
  response: {
    url: request.url,
    redirected: false,
    status: 200,
    headers: { 'content-type': 'application/json' },
    rawBody: JSON.stringify(responseBody),
  },
});
const rpcResponse = (request, body) => ({
  jsonrpc: '2.0',
  id: request.body.id,
  result: {
    content: [{ type: 'text', text: 'http 200' }],
    isError: false,
    structuredContent: {
      status: 200,
      headers: { 'content-type': 'application/json' },
      content_type: 'application/json',
      body,
    },
  },
});
const writeTransaction = (hash, { authority, createdAt, metadata, box, kind }, block) => {
  if (!/^0x[0-9a-f]{64}$/.test(hash)) return;
  writeJson(`${hash.slice(2)}.status.json`, fixture(statusRequest(hash), {
    hash: hash.slice(2),
    status: { kind: 'Applied', block_height: block },
    summary: 'Applied',
    scope: 'global',
    resolved_from: 'state',
  }));
  const txRequest = transactionRequest(hash);
  writeJson(`${hash.slice(2)}.transaction.json`, fixture(txRequest, rpcResponse(txRequest, {
    authority,
    hash: hash.slice(2),
    block,
    created_at: createdAt,
    executable: 'Instructions',
    status: 'Committed',
    rejection_reason: null,
    executable_payload: { instruction_count: 1 },
    metadata,
    nonce: null,
    signature: 'ab'.repeat(64),
    time_to_live: null,
  })));
  const isiRequest = instructionRequest(hash);
  writeJson(`${hash.slice(2)}.instructions.json`, fixture(isiRequest, rpcResponse(isiRequest, {
    pagination: { page: 0, per_page: 2, total_pages: 1, total_items: 1 },
    items: [{
      authority,
      created_at: createdAt,
      kind,
      box,
      transaction_hash: hash.slice(2),
      transaction_status: 'Committed',
      block,
      index: 0,
    }],
  })));
};

fs.writeFileSync(path.join(out, '.nexus-receipt-self-test-v1'), 'nexus-receipt-self-test-v1\n');
for (const [index, record] of (manifest.routePublicationEvidence || []).entries()) {
  const artifact = routeArtifact(record.routeManifestCommit);
  const encoded = artifact.publicationInstruction.encoded;
  writeJson(`route-governance-action-${record.routeManifestCommit}.json`, artifact);
  writeTransaction(record.publicationTransactionHash, {
    createdAt: record.publishedAt,
    authority: record.publicationAuthority,
    kind: artifact.publicationInstruction.kind,
    metadata: {
      evidence_role: 'route-publication',
      route_governance_action_hash: record.routeManifestHash,
    },
    box: {
      encoded,
      json: {
        kind: 'Custom',
        payload: {
          variant: 'ApplySccpRouteGovernance',
          value: { wire_id: APPLY_WIRE_ID, encoded: encoded.slice(2) },
        },
        wire_id: APPLY_WIRE_ID,
        encoded: encoded.slice(2),
      },
    },
  }, 40 + index);
}
for (const [index, record] of (manifest.routeCanaryEvidence || []).entries()) {
  const encoded = `0x${Buffer.from(`nexus-test-transfer-canary:${record.routeCanaryTransactionHash}`, 'utf8').toString('hex')}`;
  writeTransaction(record.routeCanaryTransactionHash, {
    createdAt: record.routeCanaryCheckedAt,
    authority: record.authority,
    kind: 'Transfer',
    metadata: {
      evidence_role: 'route-canary',
      route_governance_action_hash: record.publishedRouteManifestHash,
    },
    box: {
      encoded,
      json: {
        kind: 'Transfer',
        payload: transferPayload(record),
        wire_id: 'iroha.transfer',
        encoded: encoded.slice(2),
      },
    },
  }, 100 + index);
}
for (const [index, record] of (manifest.walletSmokeEvidence || []).entries()) {
  const encoded = `0x${Buffer.from(`nexus-test-transfer-wallet:${record.walletSmokeTransactionHash}`, 'utf8').toString('hex')}`;
  writeTransaction(record.walletSmokeTransactionHash, {
    createdAt: record.walletSmokeSubmittedAt,
    authority: record.sourceAccount,
    kind: 'Transfer',
    metadata: {
      evidence_role: 'wallet-smoke',
      route_governance_action_hash: record.routeManifestHash,
      wallet_platform: record.platform,
      wallet_commit: record.walletCommit,
    },
    box: {
      encoded,
      json: {
        kind: 'Transfer',
        payload: transferPayload(record),
        wire_id: 'iroha.transfer',
        encoded: encoded.slice(2),
      },
    },
  }, 200 + index);
}
NODE
}

run_audit() {
  local manifest="$1"
  shift
  local route_manifest_commit="${NEXUS_ROUTE_MANIFEST_EXPECTED_COMMIT:-$ROUTE_MANIFEST_COMMIT}"
  local android_wallet_commit="${NEXUS_ANDROID_WALLET_EXPECTED_COMMIT:-$ANDROID_WALLET_COMMIT}"
  local ios_wallet_commit="${NEXUS_IOS_WALLET_EXPECTED_COMMIT:-$IOS_WALLET_COMMIT}"
  local web_wallet_commit="${NEXUS_WEB_WALLET_EXPECTED_COMMIT:-$WEB_WALLET_COMMIT}"
  local manifest_status=""
  manifest_status="$(node -e 'const fs=require("fs"); try { const d=JSON.parse(fs.readFileSync(process.argv[1],"utf8")); process.stdout.write(String(d.status || "")); } catch {}' "$manifest")"
  if [[ "$manifest_status" == "ready" ]]; then
    local receipts_dir
    receipts_dir="$(mktemp -d "$tmp_dir/receipts.XXXXXX")"
    prepare_receipt_fixtures "$manifest" "$receipts_dir"
    local -a self_test_args=()
    local arg
    for arg in "$@"; do
      [[ "$arg" == "--require-ready" ]] || self_test_args+=("$arg")
    done
    local -a audit_command=(bash "$AUDIT_SCRIPT" --evidence "$manifest" --self-test-receipts "$receipts_dir")
    if ((${#self_test_args[@]} > 0)); then
      audit_command+=("${self_test_args[@]}")
    fi
    NEXUS_ROUTE_MANIFEST_EXPECTED_COMMIT="$route_manifest_commit" \
    NEXUS_ANDROID_WALLET_EXPECTED_COMMIT="$android_wallet_commit" \
    NEXUS_IOS_WALLET_EXPECTED_COMMIT="$ios_wallet_commit" \
    NEXUS_WEB_WALLET_EXPECTED_COMMIT="$web_wallet_commit" \
    NEXUS_EVIDENCE_SELF_TEST=1 \
      "${audit_command[@]}"
  else
    NEXUS_ROUTE_MANIFEST_EXPECTED_COMMIT="$route_manifest_commit" \
    NEXUS_ANDROID_WALLET_EXPECTED_COMMIT="$android_wallet_commit" \
    NEXUS_IOS_WALLET_EXPECTED_COMMIT="$ios_wallet_commit" \
    NEXUS_WEB_WALLET_EXPECTED_COMMIT="$web_wallet_commit" \
      bash "$AUDIT_SCRIPT" --evidence "$manifest" "$@"
  fi
}

expect_failure() {
  local name="$1"
  local expected="$2"
  shift 2
  local output

  set +e
  output="$("$@" 2>&1)"
  local status=$?
  set -e

  if [[ "$status" -eq 0 ]]; then
    echo "$output" >&2
    fail "$name unexpectedly passed"
  fi

  if [[ "$output" != *"$expected"* ]]; then
    echo "$output" >&2
    fail "$name did not report expected text: $expected"
  fi

  ((negative_cases += 1))
}

expect_exact_freshness_boundary_pass() {
  local source="$1"
  local dest="$2"
  local output=""

  for _attempt in $(seq 1 20); do
    mutate_manifest "$source" "$dest" '
const auditSecond = Math.floor(Date.now() / 1000) * 1000;
const exactBoundary = new Date(auditSecond - 24 * 60 * 60 * 1000).toISOString().replace(".000Z", "Z");
data.routeCanaryEvidence.forEach((entry) => { entry.routeCanaryCheckedAt = exactBoundary; });
data.walletSmokeEvidence.forEach((entry) => {
  entry.walletSmokeSubmittedAt = exactBoundary;
  entry.walletSmokeObservedAt = exactBoundary;
});'
    local expected_audit_second
    expected_audit_second="$(node -e 'const fs=require("fs"); const d=JSON.parse(fs.readFileSync(process.argv[1],"utf8")); process.stdout.write(String(Date.parse(d.routeCanaryEvidence[0].routeCanaryCheckedAt)/1000 + 24*60*60));' "$dest")"

    set +e
    output="$(run_audit "$dest" --require-ready 2>&1)"
    local status=$?
    set -e
    local completed_second
    completed_second="$(date -u +%s)"
    if [[ "$status" -eq 0 && "$completed_second" == "$expected_audit_second" ]]; then
      ((positive_cases += 1))
      return
    fi
  done

  echo "$output" >&2
  fail "exact 24-hour freshness boundary did not pass within one audit second"
}

tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

blocked="$tmp_dir/blocked.json"
ready="$tmp_dir/ready.json"
write_blocked_manifest "$blocked"
write_ready_manifest "$ready"

run_audit "$blocked" >/dev/null
((positive_cases += 1))
run_audit "$ready" --require-ready >/dev/null
((positive_cases += 1))

audit_help="$(bash "$AUDIT_SCRIPT" --help)"
[[ "$audit_help" == *"Blocked manifests must keep all three evidence arrays empty"* ]] \
  || fail "audit help must document blocked-evidence replay protection"
((positive_cases += 1))

rg -Fq 'const EVIDENCE_FRESHNESS_WINDOW_MS = 24 * 60 * 60 * 1000;' "$AUDIT_SCRIPT" \
  || fail "audit must keep the fixed 24-hour evidence freshness window"
rg -Fq 'AUDIT_NOW_MS - millis > EVIDENCE_FRESHNESS_WINDOW_MS' "$AUDIT_SCRIPT" \
  || fail "audit must accept the exact 24-hour boundary and reject evidence older than it"
((positive_cases += 1))

exact_freshness_boundary="$tmp_dir/exact-freshness-boundary.json"
expect_exact_freshness_boundary_pass "$ready" "$exact_freshness_boundary"

old_route_publication="$tmp_dir/old-route-publication.json"
mutate_manifest "$ready" "$old_route_publication" 'data.routePublicationEvidence[0].publishedAt = "2020-01-01T00:00:00Z";'
run_audit "$old_route_publication" --require-ready >/dev/null
((positive_cases += 1))

blocked_with_publication_replay="$tmp_dir/blocked-with-publication-replay.json"
mutate_manifest "$ready" "$blocked_with_publication_replay" '
data.status = "blocked";
data.releaseEnabled = false;
data.blockers = [
  "nexus-live-health-failing",
  "route-publication-evidence-missing",
  "route-canary-evidence-missing",
  "wallet-live-transfer-smoke-missing",
];
data.routeCanaryEvidence = [];
data.walletSmokeEvidence = [];'
expect_failure "blocked manifest rejects partial route publication replay" "blocked Nexus production evidence must keep routePublicationEvidence empty" run_audit "$blocked_with_publication_replay"

blocked_with_canary_replay="$tmp_dir/blocked-with-canary-replay.json"
mutate_manifest "$ready" "$blocked_with_canary_replay" '
data.status = "blocked";
data.releaseEnabled = false;
data.blockers = [
  "nexus-live-health-failing",
  "route-publication-evidence-missing",
  "route-canary-evidence-missing",
  "wallet-live-transfer-smoke-missing",
];
data.routePublicationEvidence = [];
data.walletSmokeEvidence = [];'
expect_failure "blocked manifest rejects partial route canary replay" "blocked Nexus production evidence must keep routeCanaryEvidence empty" run_audit "$blocked_with_canary_replay"

blocked_with_wallet_replay="$tmp_dir/blocked-with-wallet-replay.json"
mutate_manifest "$ready" "$blocked_with_wallet_replay" '
data.status = "blocked";
data.releaseEnabled = false;
data.blockers = [
  "nexus-live-health-failing",
  "route-publication-evidence-missing",
  "route-canary-evidence-missing",
  "wallet-live-transfer-smoke-missing",
];
data.routePublicationEvidence = [];
data.routeCanaryEvidence = [];'
expect_failure "blocked manifest rejects partial wallet smoke replay" "blocked Nexus production evidence must keep walletSmokeEvidence empty" run_audit "$blocked_with_wallet_replay"

blocked_with_fully_populated_replay="$tmp_dir/blocked-with-fully-populated-replay.json"
mutate_manifest "$ready" "$blocked_with_fully_populated_replay" '
data.status = "blocked";
data.releaseEnabled = false;
data.blockers = [
  "nexus-live-health-failing",
  "route-publication-evidence-missing",
  "route-canary-evidence-missing",
  "wallet-live-transfer-smoke-missing",
];'
expect_failure "blocked manifest rejects fully populated evidence replay" "blocked Nexus production evidence must keep routePublicationEvidence empty" run_audit "$blocked_with_fully_populated_replay"

stale_canary_by_one_second="$tmp_dir/stale-canary-by-one-second.json"
mutate_manifest "$ready" "$stale_canary_by_one_second" '
const old = new Date(Math.floor(Date.now() / 1000) * 1000 - (24 * 60 * 60 + 1) * 1000).toISOString().replace(".000Z", "Z");
data.routeCanaryEvidence[0].routeCanaryCheckedAt = old;'
expect_failure "route canary one second outside fixed freshness boundary" "routeCanaryEvidence[0].routeCanaryCheckedAt must be within the last 24 hours for ready Nexus production evidence" run_audit "$stale_canary_by_one_second" --require-ready

for wallet_index in 0 1 2; do
  stale_wallet="$tmp_dir/stale-wallet-${wallet_index}-by-one-second.json"
  mutate_manifest "$ready" "$stale_wallet" "
const old = new Date(Math.floor(Date.now() / 1000) * 1000 - (24 * 60 * 60 + 1) * 1000).toISOString().replace('.000Z', 'Z');
data.walletSmokeEvidence[$wallet_index].walletSmokeSubmittedAt = old;
data.walletSmokeEvidence[$wallet_index].walletSmokeObservedAt = old;"
  expect_failure "wallet platform index ${wallet_index} one second outside fixed freshness boundary" "walletSmokeEvidence[${wallet_index}].walletSmokeSubmittedAt must be within the last 24 hours for ready Nexus production evidence" run_audit "$stale_wallet" --require-ready
done

stale_wallet_submit_fresh_observation="$tmp_dir/stale-wallet-submit-fresh-observation.json"
mutate_manifest "$ready" "$stale_wallet_submit_fresh_observation" '
data.walletSmokeEvidence[0].walletSmokeSubmittedAt = "2020-01-01T00:00:00Z";'
expect_failure "fresh observation cannot replay an old wallet transaction" "walletSmokeEvidence[0].walletSmokeSubmittedAt must be within the last 24 hours for ready Nexus production evidence" run_audit "$stale_wallet_submit_fresh_observation" --require-ready

stale_second_canary="$tmp_dir/stale-second-canary.json"
mutate_manifest "$ready" "$stale_second_canary" '
const old = new Date(Math.floor(Date.now() / 1000) * 1000 - (24 * 60 * 60 + 1) * 1000).toISOString().replace(".000Z", "Z");
const second = { ...data.routeCanaryEvidence[0] };
second.routeCanaryTransactionHash = "0x0a1b2c3d4e5f67890a1b2c3d4e5f67890a1b2c3d4e5f67890a1b2c3d4e5f6789";
second.routeCanaryCheckedAt = old;
data.routeCanaryEvidence.push(second);'
expect_failure "every ready canary record must be fresh" "routeCanaryEvidence[1].routeCanaryCheckedAt must be within the last 24 hours for ready Nexus production evidence" run_audit "$stale_second_canary" --require-ready

expect_failure "stale route manifest commit evidence" "routeManifestCommit must match expected route manifest commit fedcba9876543210fedcba9876543210fedcba98" \
  env \
    NEXUS_ROUTE_MANIFEST_EXPECTED_COMMIT=fedcba9876543210fedcba9876543210fedcba98 \
    NEXUS_ANDROID_WALLET_EXPECTED_COMMIT="$ANDROID_WALLET_COMMIT" \
    NEXUS_IOS_WALLET_EXPECTED_COMMIT="$IOS_WALLET_COMMIT" \
    NEXUS_WEB_WALLET_EXPECTED_COMMIT="$WEB_WALLET_COMMIT" \
    bash "$AUDIT_SCRIPT" --evidence "$ready" --require-ready

expect_failure "stale android wallet commit evidence" "walletSmokeEvidence[0].walletCommit must match expected android wallet commit fedcba9876543210fedcba9876543210fedcba98" \
  env \
    NEXUS_ROUTE_MANIFEST_EXPECTED_COMMIT="$ROUTE_MANIFEST_COMMIT" \
    NEXUS_ANDROID_WALLET_EXPECTED_COMMIT=fedcba9876543210fedcba9876543210fedcba98 \
    NEXUS_IOS_WALLET_EXPECTED_COMMIT="$IOS_WALLET_COMMIT" \
    NEXUS_WEB_WALLET_EXPECTED_COMMIT="$WEB_WALLET_COMMIT" \
    bash "$AUDIT_SCRIPT" --evidence "$ready" --require-ready

expect_failure "stale ios wallet commit evidence" "walletSmokeEvidence[1].walletCommit must match expected ios wallet commit fedcba9876543210fedcba9876543210fedcba98" \
  env \
    NEXUS_ROUTE_MANIFEST_EXPECTED_COMMIT="$ROUTE_MANIFEST_COMMIT" \
    NEXUS_ANDROID_WALLET_EXPECTED_COMMIT="$ANDROID_WALLET_COMMIT" \
    NEXUS_IOS_WALLET_EXPECTED_COMMIT=fedcba9876543210fedcba9876543210fedcba98 \
    NEXUS_WEB_WALLET_EXPECTED_COMMIT="$WEB_WALLET_COMMIT" \
    bash "$AUDIT_SCRIPT" --evidence "$ready" --require-ready

expect_failure "stale web wallet commit evidence" "walletSmokeEvidence[2].walletCommit must match expected web wallet commit fedcba9876543210fedcba9876543210fedcba98" \
  env \
    NEXUS_ROUTE_MANIFEST_EXPECTED_COMMIT="$ROUTE_MANIFEST_COMMIT" \
    NEXUS_ANDROID_WALLET_EXPECTED_COMMIT="$ANDROID_WALLET_COMMIT" \
    NEXUS_IOS_WALLET_EXPECTED_COMMIT="$IOS_WALLET_COMMIT" \
    NEXUS_WEB_WALLET_EXPECTED_COMMIT=fedcba9876543210fedcba9876543210fedcba98 \
    bash "$AUDIT_SCRIPT" --evidence "$ready" --require-ready

expect_failure "malformed expected route manifest commit" "NEXUS_ROUTE_MANIFEST_EXPECTED_COMMIT must be a 40-character lowercase git commit" \
  env NEXUS_ROUTE_MANIFEST_EXPECTED_COMMIT=not-a-commit bash "$AUDIT_SCRIPT" --evidence "$ready" --require-ready

expect_failure "malformed expected wallet commit" "NEXUS_WEB_WALLET_EXPECTED_COMMIT must be a 40-character lowercase git commit" \
  env \
    NEXUS_ROUTE_MANIFEST_EXPECTED_COMMIT="$ROUTE_MANIFEST_COMMIT" \
    NEXUS_ANDROID_WALLET_EXPECTED_COMMIT="$ANDROID_WALLET_COMMIT" \
    NEXUS_IOS_WALLET_EXPECTED_COMMIT="$IOS_WALLET_COMMIT" \
    NEXUS_WEB_WALLET_EXPECTED_COMMIT=not-a-commit \
    bash "$AUDIT_SCRIPT" --evidence "$ready" --require-ready

mkdir -p "$tmp_dir/no-repos"
expect_failure "missing expected route manifest commit source" "NEXUS_ROUTE_MANIFEST_EXPECTED_COMMIT must be set because ../iroha HEAD could not be determined" \
  env \
    -u NEXUS_ROUTE_MANIFEST_EXPECTED_COMMIT \
    -u NEXUS_ANDROID_WALLET_EXPECTED_COMMIT \
    -u NEXUS_IOS_WALLET_EXPECTED_COMMIT \
    -u NEXUS_WEB_WALLET_EXPECTED_COMMIT \
    NEXUS_EVIDENCE_ROOT="$tmp_dir/no-repos" \
    bash "$AUDIT_SCRIPT" --evidence "$ready" --require-ready

mkdir -p "$tmp_dir/no-repos/fearless-Android" "$tmp_dir/no-repos/fearless-iOS"
git -C "$tmp_dir/no-repos/fearless-Android" init -q
git -C "$tmp_dir/no-repos/fearless-Android" -c user.name=Fixture -c user.email=fixture@example.invalid commit --allow-empty -qm historical
git -C "$tmp_dir/no-repos/fearless-iOS" init -q
git -C "$tmp_dir/no-repos/fearless-iOS" -c user.name=Fixture -c user.email=fixture@example.invalid commit --allow-empty -qm historical
expect_failure "historical Android checkout cannot supply expected wallet commit" "NEXUS_ANDROID_WALLET_EXPECTED_COMMIT must be set because fearless-Android-production-consolidated-20260731 HEAD could not be determined" \
  env \
    -u NEXUS_ANDROID_WALLET_EXPECTED_COMMIT \
    NEXUS_EVIDENCE_ROOT="$tmp_dir/no-repos" \
    NEXUS_ROUTE_MANIFEST_EXPECTED_COMMIT="$ROUTE_MANIFEST_COMMIT" \
    NEXUS_IOS_WALLET_EXPECTED_COMMIT="$IOS_WALLET_COMMIT" \
    NEXUS_WEB_WALLET_EXPECTED_COMMIT="$WEB_WALLET_COMMIT" \
    bash "$AUDIT_SCRIPT" --evidence "$ready" --require-ready

expect_failure "historical iOS checkout cannot supply expected wallet commit" "NEXUS_IOS_WALLET_EXPECTED_COMMIT must be set because fearless-iOS-production-consolidated-20260731 HEAD could not be determined" \
  env \
    -u NEXUS_IOS_WALLET_EXPECTED_COMMIT \
    NEXUS_EVIDENCE_ROOT="$tmp_dir/no-repos" \
    NEXUS_ROUTE_MANIFEST_EXPECTED_COMMIT="$ROUTE_MANIFEST_COMMIT" \
    NEXUS_ANDROID_WALLET_EXPECTED_COMMIT="$ANDROID_WALLET_COMMIT" \
    NEXUS_WEB_WALLET_EXPECTED_COMMIT="$WEB_WALLET_COMMIT" \
    bash "$AUDIT_SCRIPT" --evidence "$ready" --require-ready

expect_failure "missing Nexus production evidence manifest" "Nexus production evidence manifest missing" run_audit "$tmp_dir/missing.json"

bad_json="$tmp_dir/bad-json.json"
printf '{' >"$bad_json"
expect_failure "invalid Nexus production evidence JSON" "must be valid JSON" run_audit "$bad_json"

bad_schema="$tmp_dir/bad-schema.json"
mutate_manifest "$blocked" "$bad_schema" 'data.schemaVersion = 2;'
expect_failure "bad schema" "schemaVersion must be 1" run_audit "$bad_schema"

wrong_torii="$tmp_dir/wrong-torii.json"
mutate_manifest "$blocked" "$wrong_torii" 'data.toriiBaseUrl = "https://example.com";'
expect_failure "wrong Minamoto URL evidence" "toriiBaseUrl must be https://minamoto.sora.org" run_audit "$wrong_torii"

release_enabled_blocked="$tmp_dir/release-enabled-blocked.json"
mutate_manifest "$blocked" "$release_enabled_blocked" 'data.releaseEnabled = true;'
expect_failure "release enabled while blocked" "releaseEnabled must remain false while Nexus production evidence is blocked" run_audit "$release_enabled_blocked"

blocked_missing_blocker="$tmp_dir/blocked-missing-blocker.json"
mutate_manifest "$blocked" "$blocked_missing_blocker" 'data.blockers = data.blockers.filter((blocker) => blocker !== "route-publication-evidence-missing");'
expect_failure "blocked evidence missing route publication blocker" "blocked Nexus production evidence missing blocker route-publication-evidence-missing" run_audit "$blocked_missing_blocker"

unsupported_blocker="$tmp_dir/unsupported-blocker.json"
mutate_manifest "$blocked" "$unsupported_blocker" 'data.blockers.push("manual-approval-pending");'
expect_failure "unsupported Nexus production evidence blocker" "unsupported Nexus production evidence blocker: manual-approval-pending" run_audit "$unsupported_blocker"

duplicate_blocker="$tmp_dir/duplicate-blocker.json"
mutate_manifest "$blocked" "$duplicate_blocker" 'data.blockers.push("route-publication-evidence-missing");'
expect_failure "duplicate Nexus production evidence blocker" "duplicate Nexus production evidence blocker" run_audit "$duplicate_blocker"

require_ready_blocked="$tmp_dir/require-ready-blocked.json"
cp "$blocked" "$require_ready_blocked"
expect_failure "require ready on blocked evidence" "status must be ready when --require-ready is used" run_audit "$require_ready_blocked" --require-ready

missing_ready_command="$tmp_dir/missing-ready-command.json"
mutate_manifest "$blocked" "$missing_ready_command" 'data.readyVerificationCommands = data.readyVerificationCommands.filter((command) => command !== "bash scripts/audit-nexus-production-evidence.sh --require-ready");'
expect_failure "missing require-ready command" "readyVerificationCommands missing bash scripts/audit-nexus-production-evidence.sh --require-ready" run_audit "$missing_ready_command"

missing_template_command="$tmp_dir/missing-template-command.json"
mutate_manifest "$blocked" "$missing_template_command" 'data.readyVerificationCommands = data.readyVerificationCommands.filter((command) => !command.includes("generate-nexus-production-evidence-template"));'
expect_failure "missing Nexus evidence template command" "readyVerificationCommands missing bash scripts/generate-nexus-production-evidence-template.sh --output build/reports/nexus-production-evidence-template.json" run_audit "$missing_template_command"

duplicate_ready_command="$tmp_dir/duplicate-ready-command.json"
mutate_manifest "$blocked" "$duplicate_ready_command" 'data.readyVerificationCommands.push("bash scripts/test-nexus-production-evidence-audit.sh");'
expect_failure "duplicate Nexus production evidence verification command" "duplicate Nexus production evidence verification command" run_audit "$duplicate_ready_command"

missing_required_field="$tmp_dir/missing-required-field.json"
mutate_manifest "$blocked" "$missing_required_field" 'data.requiredEvidenceFields = data.requiredEvidenceFields.filter((field) => field !== "publicationTransactionHash");'
expect_failure "missing required evidence field" "requiredEvidenceFields missing publicationTransactionHash" run_audit "$missing_required_field"

duplicate_required_field="$tmp_dir/duplicate-required-field.json"
mutate_manifest "$blocked" "$duplicate_required_field" 'data.requiredEvidenceFields.push("publicationTransactionHash");'
expect_failure "duplicate Nexus production evidence required field" "duplicate Nexus production evidence required field" run_audit "$duplicate_required_field"

unsupported_required_field="$tmp_dir/unsupported-required-field.json"
mutate_manifest "$blocked" "$unsupported_required_field" 'data.requiredEvidenceFields.push("region");'
expect_failure "unsupported required evidence field" "unsupported required Nexus production evidence field: region" run_audit "$unsupported_required_field"

unsupported_top_level="$tmp_dir/unsupported-top-level.json"
mutate_manifest "$blocked" "$unsupported_top_level" 'data.region = "jp";'
expect_failure "unsupported top-level Nexus evidence field" "unsupported Nexus production evidence manifest field manifest.region" run_audit "$unsupported_top_level"

ready_without_publication="$tmp_dir/ready-without-publication.json"
mutate_manifest "$ready" "$ready_without_publication" 'data.routePublicationEvidence = [];'
expect_failure "ready evidence without route publication" "ready Nexus production evidence requires route publication, canary, and wallet smoke evidence" run_audit "$ready_without_publication" --require-ready

ready_without_canary="$tmp_dir/ready-without-canary.json"
mutate_manifest "$ready" "$ready_without_canary" 'data.routeCanaryEvidence = [];'
expect_failure "ready evidence without route canary" "ready Nexus production evidence requires route publication, canary, and wallet smoke evidence" run_audit "$ready_without_canary" --require-ready

ready_without_wallet="$tmp_dir/ready-without-wallet.json"
mutate_manifest "$ready" "$ready_without_wallet" 'data.walletSmokeEvidence = [];'
expect_failure "ready evidence without wallet smoke" "ready Nexus production evidence requires route publication, canary, and wallet smoke evidence" run_audit "$ready_without_wallet" --require-ready

ready_missing_ios_wallet="$tmp_dir/ready-missing-ios-wallet.json"
mutate_manifest "$ready" "$ready_missing_ios_wallet" 'data.walletSmokeEvidence = data.walletSmokeEvidence.filter((entry) => entry.platform !== "ios");'
expect_failure "ready evidence missing iOS wallet smoke" "ready Nexus production evidence requires wallet smoke evidence for ios" run_audit "$ready_missing_ios_wallet" --require-ready

ready_duplicate_wallet_platform="$tmp_dir/ready-duplicate-wallet-platform.json"
mutate_manifest "$ready" "$ready_duplicate_wallet_platform" 'data.walletSmokeEvidence[1].platform = "android";'
expect_failure "ready evidence duplicate wallet platform" "duplicate Nexus wallet smoke platform: android" run_audit "$ready_duplicate_wallet_platform" --require-ready

bad_publication_hash="$tmp_dir/bad-publication-hash.json"
mutate_manifest "$ready" "$bad_publication_hash" 'data.routePublicationEvidence[0].publicationTransactionHash = "3333";'
expect_failure "ready evidence malformed publication hash" "publicationTransactionHash must be a 0x-prefixed 32-byte hash" run_audit "$bad_publication_hash" --require-ready

bad_manifest_hash="$tmp_dir/bad-manifest-hash.json"
mutate_manifest "$ready" "$bad_manifest_hash" 'data.routePublicationEvidence[0].routeManifestHash = "0x2222";'
expect_failure "ready evidence malformed route manifest hash" "routeManifestHash must be a sha256 route manifest hash" run_audit "$bad_manifest_hash" --require-ready

placeholder_manifest_commit="$tmp_dir/placeholder-manifest-commit.json"
mutate_manifest "$ready" "$placeholder_manifest_commit" 'data.routePublicationEvidence[0].routeManifestCommit = "1111111111111111111111111111111111111111";'
expect_failure "placeholder route manifest commit evidence" "routeManifestCommit must not be a placeholder git commit" run_audit "$placeholder_manifest_commit" --require-ready

placeholder_manifest_hash="$tmp_dir/placeholder-manifest-hash.json"
mutate_manifest "$ready" "$placeholder_manifest_hash" 'data.routePublicationEvidence[0].routeManifestHash = "sha256:2222222222222222222222222222222222222222222222222222222222222222"; data.routeCanaryEvidence[0].publishedRouteManifestHash = data.routePublicationEvidence[0].routeManifestHash; data.walletSmokeEvidence[0].routeManifestHash = data.routePublicationEvidence[0].routeManifestHash;'
expect_failure "placeholder route manifest hash evidence" "routeManifestHash must not be a placeholder route manifest hash" run_audit "$placeholder_manifest_hash" --require-ready

placeholder_publication_tx="$tmp_dir/placeholder-publication-tx.json"
mutate_manifest "$ready" "$placeholder_publication_tx" 'data.routePublicationEvidence[0].publicationTransactionHash = "0x3333333333333333333333333333333333333333333333333333333333333333";'
expect_failure "placeholder publication transaction evidence" "publicationTransactionHash must not be a placeholder transaction hash" run_audit "$placeholder_publication_tx" --require-ready

placeholder_canary_tx="$tmp_dir/placeholder-canary-tx.json"
mutate_manifest "$ready" "$placeholder_canary_tx" 'data.routeCanaryEvidence[0].routeCanaryTransactionHash = "0x4444444444444444444444444444444444444444444444444444444444444444";'
expect_failure "placeholder canary transaction evidence" "routeCanaryTransactionHash must not be a placeholder transaction hash" run_audit "$placeholder_canary_tx" --require-ready

placeholder_wallet_commit="$tmp_dir/placeholder-wallet-commit.json"
mutate_manifest "$ready" "$placeholder_wallet_commit" 'data.walletSmokeEvidence[0].walletCommit = "5555555555555555555555555555555555555555";'
expect_failure "placeholder wallet commit evidence" "walletCommit must not be a placeholder git commit" run_audit "$placeholder_wallet_commit" --require-ready

placeholder_wallet_tx="$tmp_dir/placeholder-wallet-tx.json"
mutate_manifest "$ready" "$placeholder_wallet_tx" 'data.walletSmokeEvidence[0].walletSmokeTransactionHash = "0x6666666666666666666666666666666666666666666666666666666666666666";'
expect_failure "placeholder wallet smoke transaction evidence" "walletSmokeTransactionHash must not be a placeholder transaction hash" run_audit "$placeholder_wallet_tx" --require-ready

placeholder_publication_operator="$tmp_dir/placeholder-publication-operator.json"
mutate_manifest "$ready" "$placeholder_publication_operator" 'data.routePublicationEvidence[0].operator = "TODO_operator_or_runbook_id";'
expect_failure "placeholder publication operator evidence" "operator must not be a placeholder operator" run_audit "$placeholder_publication_operator" --require-ready

multiline_canary_operator="$tmp_dir/multiline-canary-operator.json"
mutate_manifest "$ready" "$multiline_canary_operator" 'data.routeCanaryEvidence[0].operator = "release\noncall";'
expect_failure "multiline canary operator evidence" "operator must be a single-line public value" run_audit "$multiline_canary_operator" --require-ready

secret_like_wallet_operator="$tmp_dir/secret-like-wallet-operator.json"
mutate_manifest "$ready" "$secret_like_wallet_operator" 'data.walletSmokeEvidence[0].operator = "release-ghp_12345678901234567890";'
expect_failure "secret-like wallet operator evidence" "operator must not contain secret-like token" run_audit "$secret_like_wallet_operator" --require-ready

canary_unknown_manifest="$tmp_dir/canary-unknown-manifest.json"
mutate_manifest "$ready" "$canary_unknown_manifest" 'data.routeCanaryEvidence[0].publishedRouteManifestHash = "sha256:abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789";'
expect_failure "route canary unknown manifest" "routeCanaryEvidence[0] must reference a published routeManifestHash" run_audit "$canary_unknown_manifest" --require-ready

historical_and_latest_publications="$tmp_dir/historical-and-latest-publications.json"
mutate_manifest "$ready" "$historical_and_latest_publications" '
const historical = { ...data.routePublicationEvidence[0] };
historical.routeManifestCommit = "fedcba9876543210fedcba9876543210fedcba98";
historical.routeManifestHash = routeHashForCommit(historical.routeManifestCommit);
historical.publicationTransactionHash = "0x0f1e2d3c4b5a69780f1e2d3c4b5a69780f1e2d3c4b5a69780f1e2d3c4b5a6978";
historical.publishedAt = "2020-01-01T00:00:00Z";
data.routePublicationEvidence.unshift(historical);'
run_audit "$historical_and_latest_publications" --require-ready >/dev/null
((positive_cases += 1))

same_time_ledger_ordered_publication="$tmp_dir/same-time-ledger-ordered-publication.json"
mutate_manifest "$ready" "$same_time_ledger_ordered_publication" '
const ambiguous = { ...data.routePublicationEvidence[0] };
ambiguous.publicationTransactionHash = "0x0f1e2d3c4b5a69780f1e2d3c4b5a69780f1e2d3c4b5a69780f1e2d3c4b5a6978";
data.routePublicationEvidence.push(ambiguous);'
run_audit "$same_time_ledger_ordered_publication" --require-ready >/dev/null
((positive_cases += 1))

canary_cross_publication_substitution="$tmp_dir/canary-cross-publication-substitution.json"
mutate_manifest "$ready" "$canary_cross_publication_substitution" '
const historicalCommit = "fedcba9876543210fedcba9876543210fedcba98";
data.routePublicationEvidence[0].routeManifestCommit = historicalCommit;
data.routePublicationEvidence[0].routeManifestHash = routeHashForCommit(historicalCommit);
const historicalHash = data.routePublicationEvidence[0].routeManifestHash;
const latest = { ...data.routePublicationEvidence[0] };
latest.routeManifestCommit = "0123456789abcdef0123456789abcdef01234567";
const latestHash = routeHashForCommit(latest.routeManifestCommit);
latest.routeManifestHash = latestHash;
latest.publicationTransactionHash = "0x0f1e2d3c4b5a69780f1e2d3c4b5a69780f1e2d3c4b5a69780f1e2d3c4b5a6978";
latest.publishedAt = new Date(Math.floor(Date.now() / 1000) * 1000 - 60 * 60 * 1000).toISOString().replace(".000Z", "Z");
data.routePublicationEvidence.push(latest);
data.routeCanaryEvidence[0].publishedRouteManifestHash = historicalHash;
data.walletSmokeEvidence.forEach((entry) => { entry.routeManifestHash = latestHash; });'
expect_failure "canary cannot reuse a historical publication hash" "routeCanaryEvidence[0].publishedRouteManifestHash must match ledger-latest route publication hash" run_audit "$canary_cross_publication_substitution" --require-ready

wallet_cross_publication_substitution="$tmp_dir/wallet-cross-publication-substitution.json"
mutate_manifest "$ready" "$wallet_cross_publication_substitution" '
const historicalCommit = "fedcba9876543210fedcba9876543210fedcba98";
data.routePublicationEvidence[0].routeManifestCommit = historicalCommit;
data.routePublicationEvidence[0].routeManifestHash = routeHashForCommit(historicalCommit);
const historicalHash = data.routePublicationEvidence[0].routeManifestHash;
const latest = { ...data.routePublicationEvidence[0] };
latest.routeManifestCommit = "0123456789abcdef0123456789abcdef01234567";
const latestHash = routeHashForCommit(latest.routeManifestCommit);
latest.routeManifestHash = latestHash;
latest.publicationTransactionHash = "0x0f1e2d3c4b5a69780f1e2d3c4b5a69780f1e2d3c4b5a69780f1e2d3c4b5a6978";
latest.publishedAt = new Date(Math.floor(Date.now() / 1000) * 1000 - 60 * 60 * 1000).toISOString().replace(".000Z", "Z");
data.routePublicationEvidence.push(latest);
data.routeCanaryEvidence[0].publishedRouteManifestHash = latestHash;
data.walletSmokeEvidence.forEach((entry) => { entry.routeManifestHash = latestHash; });
data.walletSmokeEvidence[1].routeManifestHash = historicalHash;'
expect_failure "wallet smoke cannot reuse a historical publication hash" "walletSmokeEvidence[1].routeManifestHash must match ledger-latest route publication hash" run_audit "$wallet_cross_publication_substitution" --require-ready

second_canary_cross_publication_substitution="$tmp_dir/second-canary-cross-publication-substitution.json"
mutate_manifest "$ready" "$second_canary_cross_publication_substitution" '
const historicalCommit = "fedcba9876543210fedcba9876543210fedcba98";
data.routePublicationEvidence[0].routeManifestCommit = historicalCommit;
data.routePublicationEvidence[0].routeManifestHash = routeHashForCommit(historicalCommit);
const historicalHash = data.routePublicationEvidence[0].routeManifestHash;
const latest = { ...data.routePublicationEvidence[0] };
latest.routeManifestCommit = "0123456789abcdef0123456789abcdef01234567";
const latestHash = routeHashForCommit(latest.routeManifestCommit);
latest.routeManifestHash = latestHash;
latest.publicationTransactionHash = "0x0f1e2d3c4b5a69780f1e2d3c4b5a69780f1e2d3c4b5a69780f1e2d3c4b5a6978";
latest.publishedAt = new Date(Math.floor(Date.now() / 1000) * 1000 - 60 * 60 * 1000).toISOString().replace(".000Z", "Z");
data.routePublicationEvidence.push(latest);
data.routeCanaryEvidence[0].publishedRouteManifestHash = latestHash;
const historicalCanary = { ...data.routeCanaryEvidence[0] };
historicalCanary.publishedRouteManifestHash = historicalHash;
historicalCanary.routeCanaryTransactionHash = "0x13579bdf2468ace013579bdf2468ace013579bdf2468ace013579bdf2468ace0";
data.routeCanaryEvidence.push(historicalCanary);
data.walletSmokeEvidence.forEach((entry) => { entry.routeManifestHash = latestHash; });'
expect_failure "every canary must bind the latest publication hash" "routeCanaryEvidence[1].publishedRouteManifestHash must match ledger-latest route publication hash" run_audit "$second_canary_cross_publication_substitution" --require-ready

canary_signed_before_publication="$tmp_dir/canary-signed-before-publication.json"
mutate_manifest "$ready" "$canary_signed_before_publication" '
const now = Math.floor(Date.now() / 1000) * 1000;
data.routePublicationEvidence[0].publishedAt = new Date(now - 5 * 60 * 1000).toISOString().replace(".000Z", "Z");
data.routeCanaryEvidence[0].routeCanaryCheckedAt = new Date(now - 10 * 60 * 1000).toISOString().replace(".000Z", "Z");'
run_audit "$canary_signed_before_publication" --require-ready >/dev/null
((positive_cases += 1))

fractional_rfc3339="$tmp_dir/fractional-rfc3339.json"
mutate_manifest "$ready" "$fractional_rfc3339" '
const base = new Date(Math.floor(Date.now() / 1000) * 1000 - 10 * 60 * 1000).toISOString().replace(".000Z", "");
data.routePublicationEvidence[0].publishedAt = `${base}.123456789Z`;
data.routeCanaryEvidence[0].routeCanaryCheckedAt = `${base}.234567891Z`;
data.walletSmokeEvidence.forEach((entry, index) => {
  entry.walletSmokeSubmittedAt = `${base}.${300000000 + index}Z`;
  entry.walletSmokeObservedAt = `${base}.${400000000 + index}Z`;
});'
run_audit "$fractional_rfc3339" --require-ready >/dev/null
((positive_cases += 1))

overprecision_rfc3339="$tmp_dir/overprecision-rfc3339.json"
mutate_manifest "$ready" "$overprecision_rfc3339" 'data.walletSmokeEvidence[0].walletSmokeSubmittedAt = "2026-07-13T00:00:00.1234567890Z";'
expect_failure "RFC3339 timestamp over nine fractional digits" "walletSmokeEvidence[0].walletSmokeSubmittedAt must be a canonical UTC RFC3339 timestamp" run_audit "$overprecision_rfc3339" --require-ready

impossible_publication_date="$tmp_dir/impossible-publication-date.json"
mutate_manifest "$ready" "$impossible_publication_date" 'data.routePublicationEvidence[0].publishedAt = "2026-02-30T00:00:00Z";'
expect_failure "impossible route publication calendar date" "routePublicationEvidence[0].publishedAt must be a canonical UTC RFC3339 timestamp" run_audit "$impossible_publication_date" --require-ready

hour_24_canary="$tmp_dir/hour-24-canary.json"
mutate_manifest "$ready" "$hour_24_canary" 'data.routeCanaryEvidence[0].routeCanaryCheckedAt = "2026-06-26T24:00:00Z";'
expect_failure "hour-24 route canary timestamp" "routeCanaryEvidence[0].routeCanaryCheckedAt must be a canonical UTC RFC3339 timestamp" run_audit "$hour_24_canary" --require-ready

non_leap_wallet_submit="$tmp_dir/non-leap-wallet-submit.json"
mutate_manifest "$ready" "$non_leap_wallet_submit" 'data.walletSmokeEvidence[0].walletSmokeSubmittedAt = "2025-02-29T00:20:00Z";'
expect_failure "non-leap-day wallet submit timestamp" "walletSmokeEvidence[0].walletSmokeSubmittedAt must be a canonical UTC RFC3339 timestamp" run_audit "$non_leap_wallet_submit" --require-ready

impossible_wallet_observed="$tmp_dir/impossible-wallet-observed.json"
mutate_manifest "$ready" "$impossible_wallet_observed" 'data.walletSmokeEvidence[0].walletSmokeObservedAt = "2026-04-31T00:25:00Z";'
expect_failure "impossible wallet observed calendar date" "walletSmokeEvidence[0].walletSmokeObservedAt must be a canonical UTC RFC3339 timestamp" run_audit "$impossible_wallet_observed" --require-ready

valid_leap_day="$tmp_dir/valid-leap-day.json"
mutate_manifest "$ready" "$valid_leap_day" '
data.routePublicationEvidence[0].publishedAt = "2024-02-29T00:00:00Z";'
run_audit "$valid_leap_day" --require-ready >/dev/null
((positive_cases += 1))

future_publication="$tmp_dir/future-publication.json"
mutate_manifest "$ready" "$future_publication" 'data.routePublicationEvidence[0].publishedAt = "2999-01-01T00:00:00Z"; data.routeCanaryEvidence[0].routeCanaryCheckedAt = "2999-01-01T00:10:00Z"; data.walletSmokeEvidence[0].walletSmokeSubmittedAt = "2999-01-01T00:20:00Z"; data.walletSmokeEvidence[0].walletSmokeObservedAt = "2999-01-01T00:25:00Z";'
expect_failure "future route publication timestamp" "routePublicationEvidence[0].publishedAt must not be in the future" run_audit "$future_publication" --require-ready

future_canary="$tmp_dir/future-canary.json"
mutate_manifest "$ready" "$future_canary" 'data.routeCanaryEvidence[0].routeCanaryCheckedAt = "2999-01-01T00:10:00Z";'
expect_failure "future route canary timestamp" "routeCanaryEvidence[0].routeCanaryCheckedAt must not be in the future" run_audit "$future_canary" --require-ready

wallet_signed_before_publication="$tmp_dir/wallet-signed-before-publication.json"
mutate_manifest "$ready" "$wallet_signed_before_publication" '
const now = Math.floor(Date.now() / 1000) * 1000;
data.routePublicationEvidence[0].publishedAt = new Date(now - 5 * 60 * 1000).toISOString().replace(".000Z", "Z");
data.walletSmokeEvidence[0].walletSmokeSubmittedAt = new Date(now - 10 * 60 * 1000).toISOString().replace(".000Z", "Z");
data.walletSmokeEvidence[0].walletSmokeObservedAt = new Date(now - 4 * 60 * 1000).toISOString().replace(".000Z", "Z");'
run_audit "$wallet_signed_before_publication" --require-ready >/dev/null
((positive_cases += 1))

wallet_observed_before_submitted="$tmp_dir/wallet-observed-before-submitted.json"
mutate_manifest "$ready" "$wallet_observed_before_submitted" 'data.walletSmokeEvidence[0].walletSmokeObservedAt = "2026-06-26T00:19:59Z";'
expect_failure "wallet observed before submitted" "walletSmokeEvidence[0].walletSmokeObservedAt must be at or after walletSmokeSubmittedAt" run_audit "$wallet_observed_before_submitted" --require-ready

future_wallet_submitted="$tmp_dir/future-wallet-submitted.json"
mutate_manifest "$ready" "$future_wallet_submitted" 'data.walletSmokeEvidence[0].walletSmokeSubmittedAt = "2999-01-01T00:20:00Z"; data.walletSmokeEvidence[0].walletSmokeObservedAt = "2999-01-01T00:25:00Z";'
expect_failure "future wallet submitted timestamp" "walletSmokeEvidence[0].walletSmokeSubmittedAt must not be in the future" run_audit "$future_wallet_submitted" --require-ready

future_wallet_observed="$tmp_dir/future-wallet-observed.json"
mutate_manifest "$ready" "$future_wallet_observed" 'data.walletSmokeEvidence[0].walletSmokeObservedAt = "2999-01-01T00:25:00Z";'
expect_failure "future wallet observed timestamp" "walletSmokeEvidence[0].walletSmokeObservedAt must not be in the future" run_audit "$future_wallet_observed" --require-ready

bad_platform="$tmp_dir/bad-platform.json"
mutate_manifest "$ready" "$bad_platform" 'data.walletSmokeEvidence[0].platform = "desktop";'
expect_failure "bad wallet platform" "walletSmokeEvidence[0].platform must be android, ios, or web" run_audit "$bad_platform" --require-ready

duplicate_tx="$tmp_dir/duplicate-tx.json"
mutate_manifest "$ready" "$duplicate_tx" 'data.walletSmokeEvidence[0].walletSmokeTransactionHash = data.routeCanaryEvidence[0].routeCanaryTransactionHash;'
expect_failure "duplicate transaction evidence" "duplicate Nexus transaction evidence hash" run_audit "$duplicate_tx" --require-ready

secret_top_level="$tmp_dir/secret-top-level.json"
mutate_manifest "$ready" "$secret_top_level" 'data.privateKey = "do-not-commit";'
expect_failure "secret-like Nexus evidence key" "must not be included in public Nexus production evidence" run_audit "$secret_top_level" --require-ready

secret_nested="$tmp_dir/secret-nested.json"
mutate_manifest "$ready" "$secret_nested" 'data.walletSmokeEvidence[0].clientDataJSON = "do-not-commit";'
expect_failure "nested secret-like Nexus evidence key" "must not be included in public Nexus production evidence" run_audit "$secret_nested" --require-ready

secret_value="$tmp_dir/secret-value.json"
mutate_manifest "$ready" "$secret_value" 'data.routePublicationEvidence[0].publicationAuthority = "release-ghp_12345678901234567890";'
expect_failure "secret-like Nexus evidence value" "publicationAuthority must not contain secret-like token" run_audit "$secret_value" --require-ready

unsupported_publication_record="$tmp_dir/unsupported-publication-record.json"
mutate_manifest "$ready" "$unsupported_publication_record" 'data.routePublicationEvidence[0].region = "jp";'
expect_failure "unsupported route publication evidence field" "unsupported Nexus route publication evidence field routePublicationEvidence[0].region" run_audit "$unsupported_publication_record" --require-ready

unsupported_canary_record="$tmp_dir/unsupported-canary-record.json"
mutate_manifest "$ready" "$unsupported_canary_record" 'data.routeCanaryEvidence[0].latencyMs = 10;'
expect_failure "unsupported route canary evidence field" "unsupported Nexus route canary evidence field routeCanaryEvidence[0].latencyMs" run_audit "$unsupported_canary_record" --require-ready

unsupported_wallet_record="$tmp_dir/unsupported-wallet-record.json"
mutate_manifest "$ready" "$unsupported_wallet_record" 'data.walletSmokeEvidence[0].memo = "release";'
expect_failure "unsupported wallet smoke evidence field" "unsupported Nexus wallet smoke evidence field walletSmokeEvidence[0].memo" run_audit "$unsupported_wallet_record" --require-ready

wrong_route_manifest_source="$tmp_dir/wrong-route-manifest-source.json"
mutate_manifest "$ready" "$wrong_route_manifest_source" 'data.routePublicationEvidence[0].routeManifestSourcePath = "tmp/operator-route.json";'
expect_failure "operator-selected route manifest source path" "routeManifestSourcePath must be artifacts/nexus/production-route-governance-action.json" run_audit "$wrong_route_manifest_source" --require-ready

missing_canary_source="$tmp_dir/missing-canary-source.json"
mutate_manifest "$ready" "$missing_canary_source" 'delete data.routeCanaryEvidence[0].sourceAccount;'
expect_failure "missing route canary source account" "routeCanaryEvidence[0].sourceAccount must be a non-empty string" run_audit "$missing_canary_source" --require-ready

self_transfer_canary="$tmp_dir/self-transfer-canary.json"
mutate_manifest "$ready" "$self_transfer_canary" 'data.routeCanaryEvidence[0].destinationAccount = data.routeCanaryEvidence[0].sourceAccount;'
expect_failure "route canary self-transfer" "sourceAccount and destinationAccount must be distinct" run_audit "$self_transfer_canary" --require-ready

self_transfer_wallet="$tmp_dir/self-transfer-wallet.json"
mutate_manifest "$ready" "$self_transfer_wallet" 'data.walletSmokeEvidence[0].destinationAccount = data.walletSmokeEvidence[0].sourceAccount;'
expect_failure "wallet smoke self-transfer" "walletSmokeEvidence[0].sourceAccount and destinationAccount must be distinct" run_audit "$self_transfer_wallet" --require-ready

invalid_canary_amount="$tmp_dir/invalid-canary-amount.json"
mutate_manifest "$ready" "$invalid_canary_amount" 'data.routeCanaryEvidence[0].amount = "0";'
expect_failure "zero route canary amount" "routeCanaryEvidence[0].amount must be a positive decimal string" run_audit "$invalid_canary_amount" --require-ready

# Receipt-integrity tests use one confined, known-good fixture set, then mutate
# one transport or chain fact at a time. Unlike run_audit, these calls never
# regenerate fixtures after the hostile mutation.
base_receipts="$tmp_dir/base-receipts"
prepare_receipt_fixtures "$ready" "$base_receipts"
publication_tx="$(node -e 'const d=require(process.argv[1]); process.stdout.write(d.routePublicationEvidence[0].publicationTransactionHash.slice(2));' "$ready")"
canary_tx="$(node -e 'const d=require(process.argv[1]); process.stdout.write(d.routeCanaryEvidence[0].routeCanaryTransactionHash.slice(2));' "$ready")"
wallet_tx="$(node -e 'const d=require(process.argv[1]); process.stdout.write(d.walletSmokeEvidence[0].walletSmokeTransactionHash.slice(2));' "$ready")"
route_commit="$(node -e 'const d=require(process.argv[1]); process.stdout.write(d.routePublicationEvidence[0].routeManifestCommit);' "$ready")"

# Exercise the production git-object boundary without contacting Minamoto and
# without reading or mutating the real ../iroha checkout. Both cases terminate
# at canonical-artifact verification before any network request is possible.
production_fixture_workspace="$tmp_dir/production-source-fixture"
production_fixture_root="$production_fixture_workspace/fearless"
production_fixture_iroha="$production_fixture_workspace/iroha"
mkdir -p "$production_fixture_root/config" "$production_fixture_iroha/artifacts/nexus"
git -C "$production_fixture_iroha" init -q
touch "$production_fixture_iroha/.keep"
git -C "$production_fixture_iroha" add .keep
env \
  GIT_AUTHOR_NAME="Nexus Evidence Test" GIT_AUTHOR_EMAIL="nexus-test@example.invalid" \
  GIT_COMMITTER_NAME="Nexus Evidence Test" GIT_COMMITTER_EMAIL="nexus-test@example.invalid" \
  git -C "$production_fixture_iroha" commit -q -m "empty source fixture"
missing_artifact_commit="$(git -C "$production_fixture_iroha" rev-parse HEAD)"
cp "$base_receipts/route-governance-action-$route_commit.json" "$production_fixture_iroha/artifacts/nexus/production-route-governance-action.json"
git -C "$production_fixture_iroha" add artifacts/nexus/production-route-governance-action.json
env \
  GIT_AUTHOR_NAME="Nexus Evidence Test" GIT_AUTHOR_EMAIL="nexus-test@example.invalid" \
  GIT_COMMITTER_NAME="Nexus Evidence Test" GIT_COMMITTER_EMAIL="nexus-test@example.invalid" \
  git -C "$production_fixture_iroha" commit -q -m "canonical source fixture"
canonical_artifact_commit="$(git -C "$production_fixture_iroha" rev-parse HEAD)"

# A local replace ref must not change the object read for a pinned production
# commit. The verifier sets GIT_NO_REPLACE_OBJECTS=1 and therefore reports the
# digest of the original canonical object, not the replacement commit's bytes.
canonical_route_hash="$(node -e 'const d=require(process.argv[1]); process.stdout.write(d.routePublicationEvidence[0].routeManifestHash);' "$ready")"
node - "$production_fixture_iroha/artifacts/nexus/production-route-governance-action.json" <<'NODE'
const fs = require('fs');
const file = process.argv[2];
const data = JSON.parse(fs.readFileSync(file, 'utf8'));
data.publicationInstruction.encoded += '00';
fs.writeFileSync(file, `${JSON.stringify(data, null, 2)}\n`);
NODE
git -C "$production_fixture_iroha" add artifacts/nexus/production-route-governance-action.json
env \
  GIT_AUTHOR_NAME="Nexus Evidence Test" GIT_AUTHOR_EMAIL="nexus-test@example.invalid" \
  GIT_COMMITTER_NAME="Nexus Evidence Test" GIT_COMMITTER_EMAIL="nexus-test@example.invalid" \
  git -C "$production_fixture_iroha" commit -q -m "replacement source fixture"
replacement_artifact_commit="$(git -C "$production_fixture_iroha" rev-parse HEAD)"
git -C "$production_fixture_iroha" replace "$canonical_artifact_commit" "$replacement_artifact_commit"
replace_ref_probe="$production_fixture_root/config/replace-ref-probe.json"
NEXUS_FIXTURE_SOURCE="$ready" NEXUS_FIXTURE_DEST="$replace_ref_probe" NEXUS_FIXTURE_COMMIT="$canonical_artifact_commit" node <<'NODE'
const fs = require('fs');
const data = JSON.parse(fs.readFileSync(process.env.NEXUS_FIXTURE_SOURCE, 'utf8'));
data.routePublicationEvidence[0].routeManifestCommit = process.env.NEXUS_FIXTURE_COMMIT;
const forged = 'sha256:abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789';
data.routePublicationEvidence[0].routeManifestHash = forged;
data.routeCanaryEvidence[0].publishedRouteManifestHash = forged;
data.walletSmokeEvidence.forEach((entry) => { entry.routeManifestHash = forged; });
fs.writeFileSync(process.env.NEXUS_FIXTURE_DEST, `${JSON.stringify(data, null, 2)}\n`);
NODE
expect_failure \
  "git replacement objects cannot rewrite pinned route action" \
  "must equal recomputed canonical route governance action hash $canonical_route_hash" \
  env \
    NEXUS_EVIDENCE_ROOT="$production_fixture_root" \
    NEXUS_ROUTE_MANIFEST_EXPECTED_COMMIT="$canonical_artifact_commit" \
    NEXUS_ANDROID_WALLET_EXPECTED_COMMIT="$ANDROID_WALLET_COMMIT" \
    NEXUS_IOS_WALLET_EXPECTED_COMMIT="$IOS_WALLET_COMMIT" \
    NEXUS_WEB_WALLET_EXPECTED_COMMIT="$WEB_WALLET_COMMIT" \
    bash "$AUDIT_SCRIPT" --evidence "$replace_ref_probe" --require-ready
git -C "$production_fixture_iroha" replace -d "$canonical_artifact_commit" >/dev/null

production_hash_forgery="$production_fixture_root/config/forged.json"
NEXUS_FIXTURE_SOURCE="$ready" NEXUS_FIXTURE_DEST="$production_hash_forgery" NEXUS_FIXTURE_COMMIT="$canonical_artifact_commit" node <<'NODE'
const fs = require('fs');
const data = JSON.parse(fs.readFileSync(process.env.NEXUS_FIXTURE_SOURCE, 'utf8'));
data.routePublicationEvidence[0].routeManifestCommit = process.env.NEXUS_FIXTURE_COMMIT;
const forged = 'sha256:abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789';
data.routePublicationEvidence[0].routeManifestHash = forged;
data.routeCanaryEvidence[0].publishedRouteManifestHash = forged;
data.walletSmokeEvidence.forEach((entry) => { entry.routeManifestHash = forged; });
fs.writeFileSync(process.env.NEXUS_FIXTURE_DEST, `${JSON.stringify(data, null, 2)}\n`);
NODE
expect_failure \
  "production source recomputes route manifest hash from pinned commit" \
  "must equal recomputed canonical route governance action hash" \
  env \
    NEXUS_EVIDENCE_ROOT="$production_fixture_root" \
    NEXUS_ROUTE_MANIFEST_EXPECTED_COMMIT="$canonical_artifact_commit" \
    NEXUS_ANDROID_WALLET_EXPECTED_COMMIT="$ANDROID_WALLET_COMMIT" \
    NEXUS_IOS_WALLET_EXPECTED_COMMIT="$IOS_WALLET_COMMIT" \
    NEXUS_WEB_WALLET_EXPECTED_COMMIT="$WEB_WALLET_COMMIT" \
    bash "$AUDIT_SCRIPT" --evidence "$production_hash_forgery" --require-ready

production_missing_artifact="$production_fixture_root/config/missing-artifact.json"
NEXUS_FIXTURE_SOURCE="$ready" NEXUS_FIXTURE_DEST="$production_missing_artifact" NEXUS_FIXTURE_COMMIT="$missing_artifact_commit" node <<'NODE'
const fs = require('fs');
const data = JSON.parse(fs.readFileSync(process.env.NEXUS_FIXTURE_SOURCE, 'utf8'));
data.routePublicationEvidence[0].routeManifestCommit = process.env.NEXUS_FIXTURE_COMMIT;
fs.writeFileSync(process.env.NEXUS_FIXTURE_DEST, `${JSON.stringify(data, null, 2)}\n`);
NODE
expect_failure \
  "production source requires canonical artifact at pinned commit" \
  "canonical route governance action artifact artifacts/nexus/production-route-governance-action.json is unavailable at pinned commit" \
  env \
    NEXUS_EVIDENCE_ROOT="$production_fixture_root" \
    NEXUS_ROUTE_MANIFEST_EXPECTED_COMMIT="$missing_artifact_commit" \
    NEXUS_ANDROID_WALLET_EXPECTED_COMMIT="$ANDROID_WALLET_COMMIT" \
    NEXUS_IOS_WALLET_EXPECTED_COMMIT="$IOS_WALLET_COMMIT" \
    NEXUS_WEB_WALLET_EXPECTED_COMMIT="$WEB_WALLET_COMMIT" \
    bash "$AUDIT_SCRIPT" --evidence "$production_missing_artifact" --require-ready

copy_receipts() {
  local name="$1"
  local dest="$tmp_dir/receipt-$name"
  cp -R "$base_receipts" "$dest"
  printf '%s' "$dest"
}

mutate_receipt_envelope() {
  local file="$1"
  local script="$2"
  node - "$file" "$script" <<'NODE'
const fs = require('fs');
const [file, script] = process.argv.slice(2);
const data = JSON.parse(fs.readFileSync(file, 'utf8'));
new Function('data', script)(data);
fs.writeFileSync(file, `${JSON.stringify(data, null, 2)}\n`);
NODE
}

mutate_receipt_body() {
  local file="$1"
  local script="$2"
  node - "$file" "$script" <<'NODE'
const fs = require('fs');
const [file, script] = process.argv.slice(2);
const data = JSON.parse(fs.readFileSync(file, 'utf8'));
const body = JSON.parse(data.response.rawBody);
new Function('body', script)(body);
data.response.rawBody = JSON.stringify(body);
fs.writeFileSync(file, `${JSON.stringify(data, null, 2)}\n`);
NODE
}

run_receipt_audit() {
  local manifest="$1"
  local receipts="$2"
  NEXUS_ROUTE_MANIFEST_EXPECTED_COMMIT="$ROUTE_MANIFEST_COMMIT" \
  NEXUS_ANDROID_WALLET_EXPECTED_COMMIT="$ANDROID_WALLET_COMMIT" \
  NEXUS_IOS_WALLET_EXPECTED_COMMIT="$IOS_WALLET_COMMIT" \
  NEXUS_WEB_WALLET_EXPECTED_COMMIT="$WEB_WALLET_COMMIT" \
  NEXUS_EVIDENCE_SELF_TEST=1 \
    bash "$AUDIT_SCRIPT" --evidence "$manifest" --self-test-receipts "$receipts"
}

run_receipt_audit "$ready" "$base_receipts" >/dev/null
((positive_cases += 1))

run_verifier_direct() {
  local manifest="$1"
  local receipts="$2"
  NEXUS_ROUTE_MANIFEST_EXPECTED_COMMIT="$ROUTE_MANIFEST_COMMIT" \
  NEXUS_EVIDENCE_SELF_TEST=1 \
    node "$RECEIPT_VERIFIER" \
      --evidence "$manifest" \
      --root "$(cd "$SCRIPT_DIR/.." && pwd)" \
      --self-test-receipts "$receipts"
}

zero_route_action_hash_manifest="$tmp_dir/zero-route-action-hash-direct.json"
mutate_manifest "$ready" "$zero_route_action_hash_manifest" '
const zero = `sha256:${"0".repeat(64)}`;
data.routePublicationEvidence[0].routeManifestHash = zero;
data.routeCanaryEvidence[0].publishedRouteManifestHash = zero;
data.walletSmokeEvidence.forEach((entry) => { entry.routeManifestHash = zero; });'
expect_failure "receipt verifier rejects all-zero route action hash" "routeManifestHash must not be an all-zero placeholder hash" run_verifier_direct "$zero_route_action_hash_manifest" "$base_receipts"

zero_wallet_commit_manifest="$tmp_dir/zero-wallet-commit-direct.json"
mutate_manifest "$ready" "$zero_wallet_commit_manifest" 'data.walletSmokeEvidence[0].walletCommit = "0".repeat(40);'
expect_failure "receipt verifier rejects all-zero wallet commit" "walletCommit must not be an all-zero placeholder commit" run_verifier_direct "$zero_wallet_commit_manifest" "$base_receipts"

ledger_tie_manifest="$tmp_dir/ledger-tie-publications.json"
mutate_manifest "$ready" "$ledger_tie_manifest" '
const second = { ...data.routePublicationEvidence[0] };
second.publicationTransactionHash = "0x0f1e2d3c4b5a69780f1e2d3c4b5a69780f1e2d3c4b5a69780f1e2d3c4b5a6978";
second.publishedAt = data.routePublicationEvidence[0].publishedAt;
data.routePublicationEvidence.push(second);'
ledger_tie_receipts="$tmp_dir/ledger-tie-receipts"
prepare_receipt_fixtures "$ledger_tie_manifest" "$ledger_tie_receipts"
ledger_tie_tx="0f1e2d3c4b5a69780f1e2d3c4b5a69780f1e2d3c4b5a69780f1e2d3c4b5a6978"
mutate_receipt_body "$ledger_tie_receipts/$ledger_tie_tx.status.json" 'body.status.block_height = 40;'
mutate_receipt_body "$ledger_tie_receipts/$ledger_tie_tx.transaction.json" 'body.result.structuredContent.body.block = 40;'
mutate_receipt_body "$ledger_tie_receipts/$ledger_tie_tx.instructions.json" 'body.result.structuredContent.body.items[0].block = 40;'
expect_failure "same-block latest route publications are ambiguous" "one unique latest route publication by ledger block height" run_receipt_audit "$ledger_tie_manifest" "$ledger_tie_receipts"

missing_status_receipts="$(copy_receipts missing-status)"
rm "$missing_status_receipts/$wallet_tx.status.json"
expect_failure "missing wallet transaction status receipt" "walletSmokeEvidence[0] status fixture missing" run_receipt_audit "$ready" "$missing_status_receipts"

missing_instruction_receipts="$(copy_receipts missing-instruction)"
rm "$missing_instruction_receipts/$wallet_tx.instructions.json"
expect_failure "missing wallet instruction receipt" "walletSmokeEvidence[0] instructions fixture missing" run_receipt_audit "$ready" "$missing_instruction_receipts"

missing_transaction_receipts="$(copy_receipts missing-transaction)"
rm "$missing_transaction_receipts/$wallet_tx.transaction.json"
expect_failure "missing wallet transaction detail receipt" "walletSmokeEvidence[0] transaction fixture missing" run_receipt_audit "$ready" "$missing_transaction_receipts"

wrong_status_hash_receipts="$(copy_receipts wrong-status-hash)"
mutate_receipt_body "$wrong_status_hash_receipts/$wallet_tx.status.json" 'body.hash = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";'
expect_failure "wrong transaction status hash" "status response hash mismatch" run_receipt_audit "$ready" "$wrong_status_hash_receipts"

failed_transaction_receipts="$(copy_receipts failed-transaction)"
mutate_receipt_body "$failed_transaction_receipts/$wallet_tx.status.json" 'body.status.kind = "Rejected"; body.summary = "Rejected";'
expect_failure "failed transaction cannot satisfy receipt evidence" "pipeline transaction status must be Applied" run_receipt_audit "$ready" "$failed_transaction_receipts"

unfinalized_transaction_receipts="$(copy_receipts unfinalized-transaction)"
mutate_receipt_body "$unfinalized_transaction_receipts/$wallet_tx.status.json" 'body.status.block_height = 0;'
expect_failure "unfinalized transaction cannot satisfy receipt evidence" "positive block_height" run_receipt_audit "$ready" "$unfinalized_transaction_receipts"

invented_chain_receipts="$(copy_receipts invented-chain)"
mutate_receipt_body "$invented_chain_receipts/$wallet_tx.status.json" 'body.chain_id = "sora:nexus:global";'
expect_failure "invented pipeline chain identity field" "status response has unsupported field chain_id" run_receipt_audit "$ready" "$invented_chain_receipts"

invented_network_receipts="$(copy_receipts invented-network)"
mutate_receipt_body "$invented_network_receipts/$wallet_tx.status.json" 'body.network = "sora-nexus-mainnet";'
expect_failure "invented pipeline network identity field" "status response has unsupported field network" run_receipt_audit "$ready" "$invented_network_receipts"

wrong_scope_receipts="$(copy_receipts wrong-scope)"
mutate_receipt_body "$wrong_scope_receipts/$wallet_tx.status.json" 'body.scope = "local";'
expect_failure "local-scope receipt cannot satisfy global evidence" "status response scope must be global" run_receipt_audit "$ready" "$wrong_scope_receipts"

queued_resolution_receipts="$(copy_receipts queued-resolution)"
mutate_receipt_body "$queued_resolution_receipts/$wallet_tx.status.json" 'body.resolved_from = "queue";'
expect_failure "queue is not an authoritative terminal resolution" "applied status resolved_from must be cache or state" run_receipt_audit "$ready" "$queued_resolution_receipts"

missing_status_summary_receipts="$(copy_receipts missing-status-summary)"
mutate_receipt_body "$missing_status_summary_receipts/$wallet_tx.status.json" 'delete body.summary;'
expect_failure "pipeline DTO missing required summary" "status response is missing field summary" run_receipt_audit "$ready" "$missing_status_summary_receipts"

extra_status_field_receipts="$(copy_receipts extra-status-field)"
mutate_receipt_body "$extra_status_field_receipts/$wallet_tx.status.json" 'body.observed_at = "2026-07-13T00:00:00Z";'
expect_failure "pipeline DTO rejects unknown field" "status response has unsupported field observed_at" run_receipt_audit "$ready" "$extra_status_field_receipts"

status_rejection_field_receipts="$(copy_receipts status-rejection-field)"
mutate_receipt_body "$status_rejection_field_receipts/$wallet_tx.status.json" 'body.status.rejection_reason = null;'
expect_failure "applied status rejects rejection field schema drift" "status response status has unsupported or missing fields" run_receipt_audit "$ready" "$status_rejection_field_receipts"

wrong_detail_hash_receipts="$(copy_receipts wrong-detail-hash)"
mutate_receipt_body "$wrong_detail_hash_receipts/$wallet_tx.transaction.json" 'body.result.structuredContent.body.hash = "aa".repeat(32);'
expect_failure "wrong transaction detail hash" "transaction detail hash mismatch" run_receipt_audit "$ready" "$wrong_detail_hash_receipts"

extra_detail_field_receipts="$(copy_receipts extra-detail-field)"
mutate_receipt_body "$extra_detail_field_receipts/$wallet_tx.transaction.json" 'body.result.structuredContent.body.chain_id = "sora:nexus:global";'
expect_failure "transaction detail DTO rejects invented chain field" "transaction detail has unsupported or missing fields" run_receipt_audit "$ready" "$extra_detail_field_receipts"

missing_detail_metadata_receipts="$(copy_receipts missing-detail-metadata)"
mutate_receipt_body "$missing_detail_metadata_receipts/$wallet_tx.transaction.json" 'delete body.result.structuredContent.body.metadata;'
expect_failure "transaction detail requires signed metadata" "transaction detail has unsupported or missing fields" run_receipt_audit "$ready" "$missing_detail_metadata_receipts"

extra_signed_metadata_receipts="$(copy_receipts extra-signed-metadata)"
mutate_receipt_body "$extra_signed_metadata_receipts/$wallet_tx.transaction.json" 'body.result.structuredContent.body.metadata.memo = "operator injected";'
expect_failure "signed metadata fails closed on extra key" "signed transaction metadata mismatch" run_receipt_audit "$ready" "$extra_signed_metadata_receipts"

numeric_signed_metadata_receipts="$(copy_receipts numeric-signed-metadata)"
mutate_receipt_body "$numeric_signed_metadata_receipts/$wallet_tx.transaction.json" 'body.result.structuredContent.body.metadata.wallet_commit = 7;'
expect_failure "signed metadata values must retain string type" "signed transaction metadata mismatch" run_receipt_audit "$ready" "$numeric_signed_metadata_receipts"

all_zero_route_metadata_receipts="$(copy_receipts all-zero-route-metadata)"
mutate_receipt_body "$all_zero_route_metadata_receipts/$wallet_tx.transaction.json" 'body.result.structuredContent.body.metadata.route_governance_action_hash = `sha256:${"0".repeat(64)}`;'
expect_failure "receipt metadata cannot substitute all-zero route hash" "signed transaction metadata mismatch" run_receipt_audit "$ready" "$all_zero_route_metadata_receipts"

all_zero_wallet_metadata_receipts="$(copy_receipts all-zero-wallet-metadata)"
mutate_receipt_body "$all_zero_wallet_metadata_receipts/$wallet_tx.transaction.json" 'body.result.structuredContent.body.metadata.wallet_commit = "0".repeat(40);'
expect_failure "receipt metadata cannot substitute all-zero wallet commit" "signed transaction metadata mismatch" run_receipt_audit "$ready" "$all_zero_wallet_metadata_receipts"

multiple_executable_instructions_receipts="$(copy_receipts multiple-executable-instructions)"
mutate_receipt_body "$multiple_executable_instructions_receipts/$wallet_tx.transaction.json" 'body.result.structuredContent.body.executable_payload.instruction_count = 2;'
expect_failure "transaction detail rejects hidden second instruction" "transaction must contain exactly one instruction" run_receipt_audit "$ready" "$multiple_executable_instructions_receipts"

rejected_detail_receipts="$(copy_receipts rejected-detail)"
mutate_receipt_body "$rejected_detail_receipts/$wallet_tx.transaction.json" 'const tx=body.result.structuredContent.body; tx.status="Rejected"; tx.rejection_reason={encoded:"0xaa",json:{},message:"rejected"};'
expect_failure "rejected explorer transaction detail" "explorer transaction must be committed without rejection" run_receipt_audit "$ready" "$rejected_detail_receipts"

invalid_signature_receipts="$(copy_receipts invalid-signature)"
mutate_receipt_body "$invalid_signature_receipts/$wallet_tx.transaction.json" 'body.result.structuredContent.body.signature = "0xAB";'
expect_failure "invalid transaction detail signature" "signature must be non-empty lowercase hexadecimal bytes" run_receipt_audit "$ready" "$invalid_signature_receipts"

zero_nonce_receipts="$(copy_receipts zero-nonce)"
mutate_receipt_body "$zero_nonce_receipts/$wallet_tx.transaction.json" 'body.result.structuredContent.body.nonce = 0;'
expect_failure "zero transaction nonce" "nonce must be null or a positive safe integer" run_receipt_audit "$ready" "$zero_nonce_receipts"

wrong_instruction_hash_receipts="$(copy_receipts wrong-instruction-hash)"
mutate_receipt_body "$wrong_instruction_hash_receipts/$wallet_tx.instructions.json" 'body.result.structuredContent.body.items[0].transaction_hash = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";'
expect_failure "wrong instruction transaction hash" "instruction transaction hash mismatch" run_receipt_audit "$ready" "$wrong_instruction_hash_receipts"

wrong_pagination_total_receipts="$(copy_receipts wrong-pagination-total)"
mutate_receipt_body "$wrong_pagination_total_receipts/$wallet_tx.instructions.json" 'body.result.structuredContent.body.pagination.total_items = 2;'
expect_failure "instruction pagination reveals hidden record" "transaction must resolve to one complete instruction page" run_receipt_audit "$ready" "$wrong_pagination_total_receipts"

extra_pagination_field_receipts="$(copy_receipts extra-pagination-field)"
mutate_receipt_body "$extra_pagination_field_receipts/$wallet_tx.instructions.json" 'body.result.structuredContent.body.pagination.has_more = false;'
expect_failure "instruction pagination DTO rejects legacy field" "pagination has unsupported or missing fields" run_receipt_audit "$ready" "$extra_pagination_field_receipts"

extra_instruction_field_receipts="$(copy_receipts extra-instruction-field)"
mutate_receipt_body "$extra_instruction_field_receipts/$wallet_tx.instructions.json" 'body.result.structuredContent.body.items[0].evidence_role = "wallet-smoke";'
expect_failure "instruction DTO rejects synthetic evidence field" "instruction record has unsupported or missing fields" run_receipt_audit "$ready" "$extra_instruction_field_receipts"

nonzero_instruction_index_receipts="$(copy_receipts nonzero-instruction-index)"
mutate_receipt_body "$nonzero_instruction_index_receipts/$wallet_tx.instructions.json" 'body.result.structuredContent.body.items[0].index = 1;'
expect_failure "single instruction must have index zero" "instruction index must be zero" run_receipt_audit "$ready" "$nonzero_instruction_index_receipts"

instruction_encoded_mirror_receipts="$(copy_receipts instruction-encoded-mirror)"
mutate_receipt_body "$instruction_encoded_mirror_receipts/$wallet_tx.instructions.json" 'body.result.structuredContent.body.items[0].box.json.encoded = "aa".repeat(80);'
expect_failure "instruction encoded mirrors must agree" "instruction encoded byte mirrors mismatch" run_receipt_audit "$ready" "$instruction_encoded_mirror_receipts"

wrong_transfer_wire_receipts="$(copy_receipts wrong-transfer-wire)"
mutate_receipt_body "$wrong_transfer_wire_receipts/$wallet_tx.instructions.json" 'body.result.structuredContent.body.items[0].box.json.wire_id = "iroha.transfer_batch";'
expect_failure "wrong transfer wire identity" "transfer instruction wire identity mismatch" run_receipt_audit "$ready" "$wrong_transfer_wire_receipts"

extra_instruction_box_field_receipts="$(copy_receipts extra-instruction-box-field)"
mutate_receipt_body "$extra_instruction_box_field_receipts/$wallet_tx.instructions.json" 'body.result.structuredContent.body.items[0].box.metadata = {};'
expect_failure "instruction box DTO rejects extra field" "instruction box has unsupported or missing fields" run_receipt_audit "$ready" "$extra_instruction_box_field_receipts"

status_detail_block_mismatch_receipts="$(copy_receipts status-detail-block-mismatch)"
mutate_receipt_body "$status_detail_block_mismatch_receipts/$wallet_tx.transaction.json" 'body.result.structuredContent.body.block += 1;'
expect_failure "status and transaction detail block mismatch" "block heights must match across status, transaction detail, and instruction" run_receipt_audit "$ready" "$status_detail_block_mismatch_receipts"

status_instruction_block_mismatch_receipts="$(copy_receipts status-instruction-block-mismatch)"
mutate_receipt_body "$status_instruction_block_mismatch_receipts/$wallet_tx.instructions.json" 'body.result.structuredContent.body.items[0].block += 1;'
expect_failure "status and instruction block mismatch" "block heights must match across status, transaction detail, and instruction" run_receipt_audit "$ready" "$status_instruction_block_mismatch_receipts"

wrong_authority_receipts="$(copy_receipts wrong-authority)"
mutate_receipt_body "$wrong_authority_receipts/$wallet_tx.instructions.json" 'body.result.structuredContent.body.items[0].authority = "attacker@sora";'
expect_failure "wrong wallet instruction authority" "instruction authority mismatch" run_receipt_audit "$ready" "$wrong_authority_receipts"

wrong_instruction_kind_receipts="$(copy_receipts wrong-kind)"
mutate_receipt_body "$wrong_instruction_kind_receipts/$wallet_tx.instructions.json" 'body.result.structuredContent.body.items[0].kind = "Burn";'
expect_failure "wrong wallet instruction kind" "instruction kind mismatch" run_receipt_audit "$ready" "$wrong_instruction_kind_receipts"

wrong_asset_receipts="$(copy_receipts wrong-asset)"
mutate_receipt_body "$wrong_asset_receipts/$wallet_tx.instructions.json" 'body.result.structuredContent.body.items[0].box.json.payload.value.source = "val#sora#nexus-android-source";'
expect_failure "wrong wallet instruction asset" "instruction payload mismatch" run_receipt_audit "$ready" "$wrong_asset_receipts"

wrong_destination_receipts="$(copy_receipts wrong-destination)"
mutate_receipt_body "$wrong_destination_receipts/$wallet_tx.instructions.json" 'body.result.structuredContent.body.items[0].box.json.payload.value.destination = "attacker@sora";'
expect_failure "wrong wallet instruction destination" "instruction payload mismatch" run_receipt_audit "$ready" "$wrong_destination_receipts"

wrong_amount_receipts="$(copy_receipts wrong-amount)"
mutate_receipt_body "$wrong_amount_receipts/$wallet_tx.instructions.json" 'body.result.structuredContent.body.items[0].box.json.payload.value.object = "999";'
expect_failure "wrong wallet instruction amount" "instruction payload mismatch" run_receipt_audit "$ready" "$wrong_amount_receipts"

wrong_route_binding_receipts="$(copy_receipts wrong-route-binding)"
mutate_receipt_body "$wrong_route_binding_receipts/$wallet_tx.transaction.json" 'body.result.structuredContent.body.metadata.route_governance_action_hash = "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";'
expect_failure "wrong wallet route governance binding" "signed transaction metadata mismatch" run_receipt_audit "$ready" "$wrong_route_binding_receipts"

wrong_role_receipts="$(copy_receipts wrong-role)"
mutate_receipt_body "$wrong_role_receipts/$wallet_tx.transaction.json" 'body.result.structuredContent.body.metadata.evidence_role = "route-canary";'
expect_failure "cross-role receipt substitution" "signed transaction metadata mismatch" run_receipt_audit "$ready" "$wrong_role_receipts"

wrong_platform_receipts="$(copy_receipts wrong-platform)"
mutate_receipt_body "$wrong_platform_receipts/$wallet_tx.transaction.json" 'body.result.structuredContent.body.metadata.wallet_platform = "ios";'
expect_failure "wrong wallet platform receipt binding" "signed transaction metadata mismatch" run_receipt_audit "$ready" "$wrong_platform_receipts"

wrong_commit_receipts="$(copy_receipts wrong-wallet-commit)"
mutate_receipt_body "$wrong_commit_receipts/$wallet_tx.transaction.json" 'body.result.structuredContent.body.metadata.wallet_commit = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";'
expect_failure "wrong wallet commit receipt binding" "signed transaction metadata mismatch" run_receipt_audit "$ready" "$wrong_commit_receipts"

wrong_publication_authority_receipts="$(copy_receipts wrong-publication-authority)"
mutate_receipt_body "$wrong_publication_authority_receipts/$publication_tx.instructions.json" 'body.result.structuredContent.body.items[0].authority = "attacker@sora";'
expect_failure "wrong publication instruction authority" "routePublicationEvidence[0] instruction authority mismatch" run_receipt_audit "$ready" "$wrong_publication_authority_receipts"

wrong_publication_payload_receipts="$(copy_receipts wrong-publication-payload)"
mutate_receipt_body "$wrong_publication_payload_receipts/$publication_tx.instructions.json" 'body.result.structuredContent.body.items[0].box.json.payload.value.encoded = "aa".repeat(80);'
expect_failure "wrong publication instruction payload" "route governance instruction JSON mismatch" run_receipt_audit "$ready" "$wrong_publication_payload_receipts"

wrong_canary_source_receipts="$(copy_receipts wrong-canary-source)"
mutate_receipt_body "$wrong_canary_source_receipts/$canary_tx.instructions.json" 'body.result.structuredContent.body.items[0].box.json.payload.value.source = "xor#sora#attacker@sora";'
expect_failure "wrong canary source account" "routeCanaryEvidence[0] instruction payload mismatch" run_receipt_audit "$ready" "$wrong_canary_source_receipts"

wrong_canary_created_at_receipts="$(copy_receipts wrong-canary-created-at)"
mutate_receipt_body "$wrong_canary_created_at_receipts/$canary_tx.instructions.json" 'body.result.structuredContent.body.items[0].created_at = "2020-01-01T00:00:00Z";'
expect_failure "replayed old canary receipt timestamp" "routeCanaryEvidence[0] instruction created_at mismatch" run_receipt_audit "$ready" "$wrong_canary_created_at_receipts"

wrong_wallet_created_at_receipts="$(copy_receipts wrong-wallet-created-at)"
mutate_receipt_body "$wrong_wallet_created_at_receipts/$wallet_tx.instructions.json" 'body.result.structuredContent.body.items[0].created_at = "2020-01-01T00:00:00Z";'
expect_failure "replayed old wallet receipt timestamp" "walletSmokeEvidence[0] instruction created_at mismatch" run_receipt_audit "$ready" "$wrong_wallet_created_at_receipts"

wrong_detail_created_at_receipts="$(copy_receipts wrong-detail-created-at)"
mutate_receipt_body "$wrong_detail_created_at_receipts/$wallet_tx.transaction.json" 'body.result.structuredContent.body.created_at = "2020-01-01T00:00:00Z";'
expect_failure "replayed transaction detail timestamp" "walletSmokeEvidence[0] transaction created_at mismatch" run_receipt_audit "$ready" "$wrong_detail_created_at_receipts"

canary_not_after_publication_receipts="$(copy_receipts canary-not-after-publication)"
mutate_receipt_body "$canary_not_after_publication_receipts/$canary_tx.status.json" 'body.status.block_height = 40;'
mutate_receipt_body "$canary_not_after_publication_receipts/$canary_tx.transaction.json" 'body.result.structuredContent.body.block = 40;'
mutate_receipt_body "$canary_not_after_publication_receipts/$canary_tx.instructions.json" 'body.result.structuredContent.body.items[0].block = 40;'
expect_failure "canary ledger block must follow publication" "ledger block must be after the ledger-latest route publication block 40" run_receipt_audit "$ready" "$canary_not_after_publication_receipts"

wallet_not_after_publication_receipts="$(copy_receipts wallet-not-after-publication)"
mutate_receipt_body "$wallet_not_after_publication_receipts/$wallet_tx.status.json" 'body.status.block_height = 40;'
mutate_receipt_body "$wallet_not_after_publication_receipts/$wallet_tx.transaction.json" 'body.result.structuredContent.body.block = 40;'
mutate_receipt_body "$wallet_not_after_publication_receipts/$wallet_tx.instructions.json" 'body.result.structuredContent.body.items[0].block = 40;'
expect_failure "wallet ledger block must follow publication" "ledger block must be after the ledger-latest route publication block 40" run_receipt_audit "$ready" "$wallet_not_after_publication_receipts"

rejected_instruction_receipts="$(copy_receipts rejected-instruction)"
mutate_receipt_body "$rejected_instruction_receipts/$wallet_tx.instructions.json" 'body.result.structuredContent.body.items[0].transaction_status = "Rejected";'
expect_failure "rejected instruction record" "instruction transaction_status must be Committed" run_receipt_audit "$ready" "$rejected_instruction_receipts"

multiple_instruction_receipts="$(copy_receipts multiple-instructions)"
mutate_receipt_body "$multiple_instruction_receipts/$wallet_tx.instructions.json" 'body.result.structuredContent.body.items.push({...body.result.structuredContent.body.items[0]});'
expect_failure "multiple-instruction transaction substitution" "exactly one instruction record" run_receipt_audit "$ready" "$multiple_instruction_receipts"

truncated_instruction_receipts="$(copy_receipts truncated-instructions)"
mutate_receipt_body "$truncated_instruction_receipts/$wallet_tx.instructions.json" 'body.result.structuredContent.body.has_more = true;'
expect_failure "legacy truncated instruction page marker" "instruction page has unsupported or missing fields" run_receipt_audit "$ready" "$truncated_instruction_receipts"

jsonrpc_error_receipts="$(copy_receipts jsonrpc-error)"
mutate_receipt_body "$jsonrpc_error_receipts/$wallet_tx.instructions.json" 'delete body.result; body.error = {code:-32603,message:"failed"};'
expect_failure "JSON-RPC receipt error" "JSON-RPC response has unsupported or missing fields" run_receipt_audit "$ready" "$jsonrpc_error_receipts"

wrong_jsonrpc_id_receipts="$(copy_receipts wrong-jsonrpc-id)"
mutate_receipt_body "$wrong_jsonrpc_id_receipts/$wallet_tx.instructions.json" 'body.id = "replayed-request";'
expect_failure "replayed JSON-RPC response id" "response must match the canonical JSON-RPC request" run_receipt_audit "$ready" "$wrong_jsonrpc_id_receipts"

malformed_response_receipts="$(copy_receipts malformed-response)"
mutate_receipt_envelope "$malformed_response_receipts/$wallet_tx.status.json" 'data.response.rawBody = "{";'
expect_failure "malformed receipt response" "response must be valid JSON" run_receipt_audit "$ready" "$malformed_response_receipts"

duplicate_key_receipts="$(copy_receipts duplicate-json-key)"
mutate_receipt_envelope "$duplicate_key_receipts/$wallet_tx.status.json" 'data.response.rawBody = data.response.rawBody.replace("\"scope\":\"global\"", "\"scope\":\"global\",\"scope\":\"local\"");'
expect_failure "duplicate JSON receipt key" "contains duplicate JSON key scope" run_receipt_audit "$ready" "$duplicate_key_receipts"

oversize_response_receipts="$(copy_receipts oversize-response)"
mutate_receipt_envelope "$oversize_response_receipts/$wallet_tx.status.json" 'data.response.rawBody = "x".repeat(65537);'
expect_failure "oversize receipt response" "response exceeds 65536 bytes" run_receipt_audit "$ready" "$oversize_response_receipts"

redirect_receipts="$(copy_receipts redirect)"
mutate_receipt_envelope "$redirect_receipts/$wallet_tx.status.json" 'data.response.redirected = true;'
expect_failure "redirected receipt response" "redirects are forbidden" run_receipt_audit "$ready" "$redirect_receipts"

host_confusion_receipts="$(copy_receipts host-confusion)"
mutate_receipt_envelope "$host_confusion_receipts/$wallet_tx.status.json" 'data.response.url = "https://minamoto.sora.org.attacker.invalid/v1/pipeline/transactions/status";'
expect_failure "receipt response host confusion" "response URL must remain https://minamoto.sora.org/" run_receipt_audit "$ready" "$host_confusion_receipts"

wrong_content_type_receipts="$(copy_receipts wrong-content-type)"
mutate_receipt_envelope "$wrong_content_type_receipts/$wallet_tx.status.json" 'data.response.headers["content-type"] = "text/html";'
expect_failure "non-JSON receipt response" "response content-type must be application/json" run_receipt_audit "$ready" "$wrong_content_type_receipts"

wrong_http_status_receipts="$(copy_receipts wrong-http-status)"
mutate_receipt_envelope "$wrong_http_status_receipts/$wallet_tx.status.json" 'data.response.status = 500;'
expect_failure "failed receipt HTTP response" "response must be HTTP 200" run_receipt_audit "$ready" "$wrong_http_status_receipts"

request_host_confusion_receipts="$(copy_receipts request-host-confusion)"
mutate_receipt_envelope "$request_host_confusion_receipts/$wallet_tx.status.json" 'data.request.url = "https://minamoto.sora.org.attacker.invalid/status";'
expect_failure "receipt request host confusion" "fixture request does not match the canonical Minamoto request" run_receipt_audit "$ready" "$request_host_confusion_receipts"

missing_artifact_receipts="$(copy_receipts missing-artifact)"
rm "$missing_artifact_receipts/route-governance-action-$route_commit.json"
expect_failure "missing canonical route governance action artifact" "self-test route governance action artifact for $route_commit missing" run_receipt_audit "$ready" "$missing_artifact_receipts"

wrong_artifact_chain_receipts="$(copy_receipts wrong-artifact-chain)"
mutate_receipt_envelope "$wrong_artifact_chain_receipts/route-governance-action-$route_commit.json" 'data.chainId = "sora:taira:testnet";'
expect_failure "wrong canonical artifact chain" "self-test route governance action artifact.chainId must be sora:nexus:global" run_receipt_audit "$ready" "$wrong_artifact_chain_receipts"

wrong_artifact_kind_receipts="$(copy_receipts wrong-artifact-kind)"
mutate_receipt_envelope "$wrong_artifact_kind_receipts/route-governance-action-$route_commit.json" 'data.publicationInstruction.kind = "UpsertSccpRouteManifest";'
expect_failure "retired canonical publication instruction" "publicationInstruction.kind must be ApplySccpRouteGovernance" run_receipt_audit "$ready" "$wrong_artifact_kind_receipts"

forged_route_hash_manifest="$tmp_dir/forged-route-hash.json"
mutate_manifest "$ready" "$forged_route_hash_manifest" '
const forged = "sha256:abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789";
data.routePublicationEvidence[0].routeManifestHash = forged;
data.routeCanaryEvidence[0].publishedRouteManifestHash = forged;
data.walletSmokeEvidence.forEach((entry) => { entry.routeManifestHash = forged; });'
expect_failure "self-asserted route governance action hash" "must equal recomputed canonical route governance action hash" run_receipt_audit "$forged_route_hash_manifest" "$base_receipts"

uppercase_transaction_manifest="$tmp_dir/uppercase-transaction-hash.json"
mutate_manifest "$ready" "$uppercase_transaction_manifest" 'data.walletSmokeEvidence[0].walletSmokeTransactionHash = data.walletSmokeEvidence[0].walletSmokeTransactionHash.toUpperCase().replace("0X", "0x");'
expect_failure "noncanonical uppercase transaction hash" "must be a lowercase 0x-prefixed 32-byte hash" run_receipt_audit "$uppercase_transaction_manifest" "$base_receipts"

replayed_receipts="$(copy_receipts replayed-transaction)"
cp "$replayed_receipts/$canary_tx.status.json" "$replayed_receipts/$wallet_tx.status.json"
cp "$replayed_receipts/$canary_tx.instructions.json" "$replayed_receipts/$wallet_tx.instructions.json"
expect_failure "cross-transaction receipt replay" "fixture request does not match the canonical Minamoto request" run_receipt_audit "$ready" "$replayed_receipts"

expect_failure \
  "self-test seam without explicit opt-in" \
  "--self-test-receipts requires NEXUS_EVIDENCE_SELF_TEST=1" \
  env \
    NEXUS_ROUTE_MANIFEST_EXPECTED_COMMIT="$ROUTE_MANIFEST_COMMIT" \
    NEXUS_ANDROID_WALLET_EXPECTED_COMMIT="$ANDROID_WALLET_COMMIT" \
    NEXUS_IOS_WALLET_EXPECTED_COMMIT="$IOS_WALLET_COMMIT" \
    NEXUS_WEB_WALLET_EXPECTED_COMMIT="$WEB_WALLET_COMMIT" \
    bash "$AUDIT_SCRIPT" --evidence "$ready" --self-test-receipts "$base_receipts"

expect_failure \
  "self-test seam cannot satisfy release command" \
  "--self-test-receipts cannot be combined with --require-ready" \
  env \
    NEXUS_EVIDENCE_SELF_TEST=1 \
    bash "$AUDIT_SCRIPT" --evidence "$ready" --self-test-receipts "$base_receipts" --require-ready

expect_failure \
  "ambient receipt endpoint override" \
  "ambient transport override NEXUS_RECEIPT_BASE_URL is forbidden" \
  env \
    NEXUS_RECEIPT_BASE_URL="https://attacker.invalid" \
    bash "$AUDIT_SCRIPT" --evidence "$blocked"

expect_failure \
  "ambient TLS verification override" \
  "ambient transport override NODE_TLS_REJECT_UNAUTHORIZED is forbidden" \
  env \
    NODE_TLS_REJECT_UNAUTHORIZED=0 \
    bash "$AUDIT_SCRIPT" --evidence "$blocked"

expect_failure \
  "ambient HTTPS proxy override" \
  "ambient transport override HTTPS_PROXY is forbidden" \
  env \
    HTTPS_PROXY="http://127.0.0.1:18080" \
    bash "$AUDIT_SCRIPT" --evidence "$blocked"

expect_failure \
  "ambient CA file override" \
  "ambient transport override SSL_CERT_FILE is forbidden" \
  env \
    SSL_CERT_FILE="$tmp_dir/attacker-ca.pem" \
    bash "$AUDIT_SCRIPT" --evidence "$blocked"

node_preload="$tmp_dir/nexus-preload.cjs"
node_preload_marker="$tmp_dir/nexus-preload-executed"
printf '%s\n' \
  'require("node:fs").writeFileSync(process.env.NEXUS_PRELOAD_MARKER, "executed"); globalThis.fetch = async () => { throw new Error("forged fetch"); };' \
  >"$node_preload"
expect_failure \
  "NODE_OPTIONS preload and global fetch injection" \
  "ambient transport override NODE_OPTIONS is forbidden" \
  env \
    NODE_OPTIONS="--require=$node_preload" \
    NEXUS_PRELOAD_MARKER="$node_preload_marker" \
    bash "$AUDIT_SCRIPT" --evidence "$blocked"
[[ ! -e "$node_preload_marker" ]] || fail "NODE_OPTIONS preload executed before the Nexus audit rejected it"

fake_node_dir="$tmp_dir/fake-node-bin"
fake_node_marker="$tmp_dir/fake-node-executed"
mkdir -p "$fake_node_dir"
printf '%s\n' '#!/usr/bin/env bash' 'touch "$NEXUS_FAKE_NODE_MARKER"' 'exit 0' >"$fake_node_dir/node"
chmod +x "$fake_node_dir/node"
PATH="$fake_node_dir:/usr/bin:/bin:/usr/sbin:/sbin" \
NEXUS_FAKE_NODE_MARKER="$fake_node_marker" \
  bash "$AUDIT_SCRIPT" --evidence "$blocked" >/dev/null
[[ ! -e "$fake_node_marker" ]] || fail "PATH-injected Node executed instead of the canonical Node binary"
((positive_cases += 1))

echo "[nexus-production-evidence-test] all assertions passed (${positive_cases} positive, ${negative_cases} negative)"
