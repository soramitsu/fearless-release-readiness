#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
EXPORT_SCRIPT="$SCRIPT_DIR/export-release-unblock-bundle.sh"
COMMAND_CONTRACT_TEST="$SCRIPT_DIR/test-release-unblock-command-contract.sh"

fail() {
  echo "[release-unblock-bundle-test][error] $*" >&2
  exit 1
}

"$COMMAND_CONTRACT_TEST"

tmp_dir="$(mktemp -d)"
tmp_dir="$(cd "$tmp_dir" && pwd -P)"
repo_scratch_dir="$SCRIPT_DIR/../build/release-unblock-bundle-test-$$"
trap 'rm -rf "$tmp_dir" "$repo_scratch_dir"' EXIT

bundle_dir="$tmp_dir/bundle"
workspace_dir="$tmp_dir/workspace"
report_dir="$workspace_dir/build/reports/release-readiness"
outside_log="$tmp_dir/outside.log"
single_snapshot_preload="$tmp_dir/source-publication-single-snapshot.cjs"

cat > "$single_snapshot_preload" <<'NODE'
const fs = require('node:fs')
const path = require('node:path')
const processArg = process.env.SOURCE_PUBLICATION_SNAPSHOT_PROCESS_ARG || ''
if (processArg && process.argv.includes(processArg)) {
  const targets = new Set((process.env.SOURCE_PUBLICATION_SNAPSHOT_PATHS || '').split('|').filter(Boolean).map((entry) => path.resolve(entry)))
  const counts = new Map([...targets].map((entry) => [entry, 0]))
  const originalReadFileSync = fs.readFileSync
  fs.readFileSync = function readSourcePublicationSnapshotOnce(file, ...args) {
    if (typeof file === 'string') {
      const resolved = path.resolve(file)
      if (targets.has(resolved)) {
        const count = (counts.get(resolved) || 0) + 1
        counts.set(resolved, count)
        if (count > 1) throw new Error(`source publication artifact read more than once: ${resolved}`)
      }
    }
    return originalReadFileSync.call(this, file, ...args)
  }
  process.on('exit', () => {
    for (const [target, count] of counts) {
      if (count !== 1) {
        process.stderr.write(`source publication artifact read count ${count}, expected 1: ${target}\n`)
        process.exitCode = 1
      }
    }
  })
}
NODE

write_fixture() {
  rm -rf "$report_dir" "$bundle_dir" "$workspace_dir"
  mkdir -p "$report_dir" "$workspace_dir/config" "$workspace_dir/scripts" "$workspace_dir/services/passkey-backup-challenge-service" \
    "$workspace_dir/fearless-Android/runtime/src/main/assets" "$workspace_dir/fearless-Android/scripts"
  printf '%s\n' \
    '# approved XCM routes' \
    'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb DOT' \
    'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa KSM' \
    > "$workspace_dir/fearless-Android/runtime/src/main/assets/approved_xcm_routes.tsv"
  printf '%s\n' \
    '# required XCM routes' \
    'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb DOT' \
    'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa KSM' \
    > "$workspace_dir/fearless-Android/scripts/xcm-required-routes.tsv"
  printf '%s\n' '{"chains":[]}' > "$workspace_dir/fearless-Android/runtime/src/main/assets/local_chains.json"
  printf '%s\n' '# Fearless Universal Wallet Project Plan' > "$workspace_dir/FEARLESS_PROJECT_PLAN.md"
  printf '%s\n' '#!/usr/bin/env bash' '# Usage: scripts/audit-release-readiness.sh' 'exit 0' > "$workspace_dir/scripts/audit-release-readiness.sh"
  chmod +x "$workspace_dir/scripts/audit-release-readiness.sh"
  cat > "$workspace_dir/config/release-readiness-prs.tsv" <<'TSV'
# repo	head	base	required_state	required_checks
# synthetic fixture keeps real config line numbers used by the status report
# line 3 intentionally blank/comment for line-number parity
# line 4 intentionally blank/comment for line-number parity
# line 5 intentionally blank/comment for line-number parity
soramitsu/fearless-wallet-web	codex/web-bitcoin-broadcast-evidence	develop	merged	validate,verify
# line 7 intentionally blank/comment for line-number parity
# line 8 intentionally blank/comment for line-number parity
# line 9 intentionally blank/comment for line-number parity
# line 10 intentionally blank/comment for line-number parity
# line 11 intentionally blank/comment for line-number parity
# line 12 intentionally blank/comment for line-number parity
# line 13 intentionally blank/comment for line-number parity
# line 14 intentionally blank/comment for line-number parity
# line 15 intentionally blank/comment for line-number parity
# line 16 intentionally blank/comment for line-number parity
# line 17 intentionally blank/comment for line-number parity
# line 18 intentionally blank/comment for line-number parity
# line 19 intentionally blank/comment for line-number parity
tonswap-org/ton-indexer	hotfix/indexer-service-info-schema-smoke	master	merged	validate,verify
# line 21 intentionally blank/comment for line-number parity
tonswap-org/ton-indexer	hotfix/deployment-evidence-placeholder-quality	master	merged	validate,verify
sora-xor/polkaswap-indexer	codex/pi-deployment-evidence-gate	develop	merged	validate,verify
TSV
  cp "$SCRIPT_DIR/../config/passkey-backup-production.json" "$workspace_dir/config/passkey-backup-production.json"
  cp "$SCRIPT_DIR/../config/passkey-backup-challenge-service.openapi.json" "$workspace_dir/config/passkey-backup-challenge-service.openapi.json"
  cp "$SCRIPT_DIR/../services/passkey-backup-challenge-service/docker-compose.production.yml" "$workspace_dir/services/passkey-backup-challenge-service/docker-compose.production.yml"

  cat > "$report_dir/summary.json" <<JSON
{
  "schemaVersion": 1,
  "generatedAt": "2026-06-28T00:00:00Z",
  "runLive": true,
  "status": "failed",
  "totals": {
    "passed": 8,
    "failed": 12,
    "skipped": 0,
    "total": 20
  },
  "checks": [
    {
      "name": "Static cross-repo plan readiness",
      "slug": "plan-readiness",
      "status": "passed",
      "exitCode": 0,
      "logFile": "plan-readiness.log"
    },
    {
      "name": "GitHub governance",
      "slug": "github-governance",
      "status": "passed",
      "exitCode": 0,
      "logFile": "github-governance.log"
    },
    {
      "name": "Private overlay readiness",
      "slug": "private-overlay-readiness",
      "status": "passed",
      "exitCode": 0,
      "logFile": "private-overlay-readiness.log"
    },
    {
      "name": "Android public dependency provenance",
      "slug": "android-public-dependency-provenance",
      "status": "passed",
      "exitCode": 0,
      "logFile": "android-public-dependency-provenance.log"
    },
    {
      "name": "iOS shared-features dependency delta",
      "slug": "ios-shared-features-delta",
      "status": "passed",
      "exitCode": 0,
      "logFile": "ios-shared-features-delta.log"
    },
    {
      "name": "Passkey challenge service implementation",
      "slug": "passkey-challenge-service",
      "status": "passed",
      "exitCode": 0,
      "logFile": "passkey-challenge-service.log"
    },
    {
      "name": "Passkey backup prerequisites",
      "slug": "passkey-backup-prerequisites",
      "status": "passed",
      "exitCode": 0,
      "logFile": "passkey-backup-prerequisites.log"
    },
    {
      "name": "Iroha Taira/Nexus wallet coverage",
      "slug": "iroha-wallet-coverage",
      "status": "passed",
      "exitCode": 0,
      "logFile": "iroha-wallet-coverage.log"
    },
    {
      "name": "Release PR readiness",
      "slug": "release-pr-readiness",
      "status": "failed",
      "exitCode": 1,
      "logFile": "release-pr-readiness.log"
    },
    {
      "name": "Web Bitcoin broadcast evidence",
      "slug": "web-bitcoin-broadcast-evidence",
      "status": "failed",
      "exitCode": 1,
      "logFile": "web-bitcoin-broadcast-evidence.log"
    },
    {
      "name": "Passkey deployment evidence",
      "slug": "passkey-deployment-evidence",
      "status": "failed",
      "exitCode": 1,
      "logFile": "passkey-deployment-evidence.log"
    },
    {
      "name": "Passkey production smoke",
      "slug": "passkey-production-smoke",
      "status": "failed",
      "exitCode": 1,
      "logFile": "passkey-production-smoke.log"
    },
    {
      "name": "Iroha Taira/Nexus release prerequisites",
      "slug": "iroha-release-readiness",
      "status": "failed",
      "exitCode": 1,
      "logFile": "iroha-release-readiness.log"
    },
    {
      "name": "Android XCM production evidence",
      "slug": "android-xcm-production-evidence",
      "status": "failed",
      "exitCode": 1,
      "logFile": "android-xcm-production-evidence.log"
    },
    {
      "name": "TI deployment evidence",
      "slug": "ti-deployment-evidence",
      "status": "failed",
      "exitCode": 1,
      "logFile": "ti-deployment-evidence.log"
    },
    {
      "name": "SI deployment evidence",
      "slug": "si-deployment-evidence",
      "status": "failed",
      "exitCode": 1,
      "logFile": "si-deployment-evidence.log"
    },
    {
      "name": "TI production smoke",
      "slug": "ti-production-smoke",
      "status": "failed",
      "exitCode": 1,
      "logFile": "ti-production-smoke.log"
    },
    {
      "name": "SI production smoke",
      "slug": "si-production-smoke",
      "status": "failed",
      "exitCode": 1,
      "logFile": "si-production-smoke.log"
    },
    {
      "name": "PI deployment evidence",
      "slug": "pi-deployment-evidence",
      "status": "failed",
      "exitCode": 1,
      "logFile": "pi-deployment-evidence.log"
    },
    {
      "name": "PI production smoke",
      "slug": "pi-production-smoke",
      "status": "failed",
      "exitCode": 1,
      "logFile": "pi-production-smoke.log"
    }
  ]
}
JSON

  cat > "$report_dir/actions.json" <<JSON
{
  "schemaVersion": 1,
  "generatedAt": "2026-06-28T00:00:00Z",
  "runLive": true,
  "status": "failed",
  "totals": {
    "passed": 8,
    "failed": 12,
    "skipped": 0,
    "total": 20
  },
  "blockers": [
    {
      "name": "Release PR readiness",
      "slug": "release-pr-readiness",
      "exitCode": 1,
      "logFile": "release-pr-readiness.log",
      "recommendedAction": "Get every PR in config/release-readiness-prs.tsv approved, green, with all GitHub review conversations resolved including outdated unresolved threads, and merged through the protected branch flow. When the blocker is outdated-only, run bash scripts/resolve-release-pr-review-threads.sh --dry-run to inspect the exact thread IDs before any authorized resolution. After conversations are resolved and approvals are present, run bash scripts/merge-release-prs.sh --dry-run to inspect protected-branch merge candidates before any authorized merge, then rerun bash scripts/audit-release-pr-readiness.sh.",
      "requiresExternalAction": true,
      "unblockCategory": "review-and-merge",
      "externalPrerequisite": "Reviewer approvals, resolved GitHub review conversations, and protected-branch merges.",
      "verificationCommand": "bash scripts/audit-release-pr-readiness.sh",
      "evidencePreview": "solswap-io/solswap-indexer#8 is open"
    },
    {
      "name": "Web Bitcoin broadcast evidence",
      "slug": "web-bitcoin-broadcast-evidence",
      "exitCode": 1,
      "logFile": "web-bitcoin-broadcast-evidence.log",
      "recommendedAction": "Run a funded Bitcoin testnet send through the web wallet smoke flow, record txid/outpoint/operator evidence plus canonical https://blockstream.info/testnet/api indexerUrl and confirmed indexer status.block_time proof in fearless-wallet-web/scripts/bitcoin-testnet-broadcast-evidence.json, ensure the evidence timestamp is at or after the confirmed block time, then rerun bash scripts/audit-bitcoin-broadcast-evidence.sh --require-ready in fearless-wallet-web.",
      "requiresExternalAction": true,
      "unblockCategory": "funded-broadcast-evidence",
      "externalPrerequisite": "Funded confirmed Bitcoin testnet broadcast evidence for the current release commit using the canonical Blockstream testnet indexer.",
      "verificationCommand": "cd fearless-wallet-web && bash scripts/audit-bitcoin-broadcast-evidence.sh --require-ready",
      "evidencePreview": "ready Bitcoin broadcast evidence requires at least one record"
    },
    {
      "name": "Passkey deployment evidence",
      "slug": "passkey-deployment-evidence",
      "exitCode": 1,
      "logFile": "passkey-deployment-evidence.log",
      "recommendedAction": "Record the passkey backup image digest, deployment ID, operator, healthResponse ok=true/service=fearless-passkey-backup/rpId=fearlesswallet.io/schemaVersion=1, durable credential store paths /data/passkey-backup and /data/passkey-backup/credentials.json, WebAuthn origin allowlist, fail-closed request-access policy, trusted-proxy policy, platform provisioning evidence, and successful smoke timestamp. Independently obtain the distribution signer SHA-256 fingerprint from a distribution-signed APK or the Play app-signing certificate, set PASSKEY_ANDROID_RELEASE_SIGNER_EVIDENCE_SOURCE=distributed-apk|play-app-signing-certificate to identify the source, and prove the derived origin matches assetlinks; AAB upload-key evidence is rejected and absence or mismatch keeps passkey flags disabled. Then rerun npm run audit:deployment-evidence -- --require-ready in services/passkey-backup-challenge-service and bash scripts/audit-passkey-android-origin-parity.sh --require-ready from the workspace root.",
      "requiresExternalAction": true,
      "unblockCategory": "deployment-evidence",
      "externalPrerequisite": "Production passkey backup deployment image, health response, credential-store volume, request-access and trusted-proxy evidence, plus independently obtained distribution signer SHA-256 evidence from a distribution-signed APK or Play app-signing certificate, with PASSKEY_ANDROID_RELEASE_SIGNER_EVIDENCE_SOURCE=distributed-apk|play-app-signing-certificate and a matching assetlinks origin; AAB upload-key evidence is rejected and absence keeps passkey flags disabled.",
      "verificationCommand": "cd services/passkey-backup-challenge-service && npm run audit:deployment-evidence -- --require-ready && cd ../.. && bash scripts/audit-passkey-android-origin-parity.sh --require-ready",
      "evidencePreview": "passkey production deployment evidence is not release-ready"
    },
    {
      "name": "Passkey production smoke",
      "slug": "passkey-production-smoke",
      "exitCode": 1,
      "logFile": "passkey-production-smoke.log",
      "recommendedAction": "Deploy and route https://backup.fearlesswallet.io to services/passkey-backup-challenge-service with valid DNS/TLS. Provision PASSKEY_BACKUP_SMOKE_GRANT_HELPER=/run/secrets/passkey-smoke-grant-helper as a readable executable that issues single-use bearer grants for the exact smoke requests, then run the passkey production smoke to verify health, all four ceremony routes, and credential list/revoke/revoke-all contracts without persisting a test credential or creating an owner record.",
      "requiresExternalAction": true,
      "unblockCategory": "live-service-deployment",
      "externalPrerequisite": "DNS, TLS, and routing for backup.fearlesswallet.io to the passkey backup challenge service route surface, plus PASSKEY_BACKUP_SMOKE_GRANT_HELPER=/run/secrets/passkey-smoke-grant-helper provisioned as a readable executable that issues single-use bearer grants for the exact smoke requests.",
      "verificationCommand": "cd services/passkey-backup-challenge-service && PASSKEY_BACKUP_BASE_URL=https://backup.fearlesswallet.io PASSKEY_BACKUP_SMOKE_GRANT_HELPER=/run/secrets/passkey-smoke-grant-helper PASSKEY_BACKUP_SMOKE_TIMEOUT_MS=10000 npm run smoke:production",
      "evidencePreview": "GET /api/passkey-backup/v1/health request to https://backup.fearlesswallet.io failed"
    },
    {
      "name": "Iroha Taira/Nexus release prerequisites",
      "slug": "iroha-release-readiness",
      "exitCode": 1,
      "logFile": "iroha-release-readiness.log",
      "recommendedAction": "Do not edit or publish from an unfinished external Iroha Git operation. Have its owner produce a stable reviewed source commit and restore the pinned Iroha JS SDK release artifact so package.json exports ./ivm-artifact and the packaged runtime/declaration surface passes the wallet artifact validator. Pin NEXUS_EXPECTED_BUILD_COMMIT in config/iroha-release-readiness.env to the exact deployed Iroha build. Restore https://minamoto.sora.org/status as a bounded, non-redirecting HTTP 200 application/json Torii/Nexus status response with fresh observed_at_ms and last_block_committed_at_ms, coherent block and queue counters, a matching non-placeholder build.git_commit_sha, the exact ordered SORA routing policy (default 0/0, governance 1/1, smartcontract::deploy 2/2), and an unsealed dataspace_catalog containing ready canonical 0/0, 1/1, and 2/2 targets; record Nexus route publication, canary, and wallet live transfer smoke evidence, keep Nexus release-gated until strict production evidence passes, then rerun bash scripts/audit-iroha-release-readiness.sh.",
      "requiresExternalAction": true,
      "unblockCategory": "live-service-and-evidence",
      "externalPrerequisite": "A stable owner-reviewed Iroha source commit; a pinned Iroha JS SDK release artifact exporting ./ivm-artifact and passing packaged runtime/declaration validation; the exact deployed Iroha build pin; bounded, non-redirecting HTTP 200 application/json Minamoto Torii/Nexus status with fresh observation and block timestamps, coherent block and queue counters, exact canonical routing/dataspace catalog; plus route publication, canary, and wallet live-transfer evidence.",
      "verificationCommand": "IROHA_NEXUS_REQUIRE_PRODUCTION_EVIDENCE=1 IROHA_NEXUS_LIVE_HEALTH=1 bash scripts/audit-iroha-release-readiness.sh",
      "evidencePreview": "SORA Nexus Torii live health check failed for https://minamoto.sora.org/status"
    },
    {
      "name": "Android XCM production evidence",
      "slug": "android-xcm-production-evidence",
      "exitCode": 1,
      "logFile": "android-xcm-production-evidence.log",
      "recommendedAction": "Keep release ENABLE_PRODUCTION_XCM_TRANSFERS=false until the entire trust and evidence gate is ready. Obtain reviewed per-asset pallet/call, reserve-or-teleport, multilocation, beneficiary, weight, destination-fee, and any bridge execution semantics for every advertised Android XCM route; implement bridge or estimator support before approving those modes. The per-asset schema, loader, validator, registry, and engine representation is now implemented, and all 15 approved single-asset routes are migrated without semantic changes. The current 34 discovery-only destinations cover 59 route assets; 14 of those destinations cover 39 multi-asset routes, and every one remains disabled until its exact reviewed semantics exist. Expand the APK-owned approved_xcm_routes.tsv and scripts/xcm-required-routes.tsv in exact lockstep only after those route semantics are reviewed, and make the production discovery intersection contain every approved route. Then record one funded mainnet E2E transfer per required route in fearless-Android/scripts/xcm-production-evidence.json, including 0x-prefixed 32-byte extrinsicHash, sender, recipient, positive amount, UTC timestamp, environment, operator, and androidCommit matching the release commit, plus finalized origin/destination block hashes and numbers, true origin finality/extrinsic success/destination event success, a positive destination balance delta, distinct public HTTPS proof URLs, verificationMethod=canonical-rpc-and-explorer, verifiedAt, and an independentVerifier distinct from operator. Regenerate the canonical live effective report and validate it with the ready evidence, then run the all-routes metadata gate before a separately reviewed release-flag change.",
      "requiresExternalAction": true,
      "unblockCategory": "route-implementation-and-evidence",
      "externalPrerequisite": "Reviewed per-asset execution semantics and effective production discovery for every advertised Android XCM route, implementation of any required bridge or fee-estimator path, a separately reviewed release enablement change, funded mainnet E2E evidence for the exact effective route set, and Android release-commit binding.",
      "verificationCommand": "cd fearless-Android && bash scripts/audit-xcm-effective-registry.sh --discovery-url https://raw.githubusercontent.com/soramitsu/shared-features-utils/master/chains/v13/chains.json --require-all-approved --write-report build/reports/xcm-effective-registry-report.json && bash scripts/audit-xcm-production-evidence.sh --effective-registry-report build/reports/xcm-effective-registry-report.json --require-ready && bash scripts/audit-xcm-registry-metadata.sh --require-executable --require-all-routes-executable --require-route-file scripts/xcm-required-routes.tsv --require-gap-file scripts/xcm-discovery-only-routes.tsv",
      "evidencePreview": "ready evidence cannot have discovery-only routes remaining"
    },
    {
      "name": "TI deployment evidence",
      "slug": "ti-deployment-evidence",
      "exitCode": 1,
      "logFile": "ti-deployment-evidence.log",
      "recommendedAction": "Populate ../ton-indexer/registry/mainnet.json with reviewed non-placeholder mainnet contract addresses. Record the TI Docker image digest, deployment ID, operator, commit, serviceInfo.schemaVersion=1 plus serviceInfo.serviceId=ti.soramitsu.io with TON mainnet identity, healthInfo.serviceId=ti.soramitsu.io with healthInfo.lastMasterSeqno from the successful https://ti.soramitsu.io smoke evidence, then rerun npm run audit:deployment-evidence -- --require-ready in ../ton-indexer.",
      "requiresExternalAction": true,
      "unblockCategory": "deployment-evidence",
      "externalPrerequisite": "Reviewed TON mainnet registry addresses plus deployed TI image, smoke, and health evidence.",
      "verificationCommand": "cd ../ton-indexer && npm run audit:deployment-evidence -- --require-ready",
      "evidencePreview": "TI deployment evidence log"
    },
    {
      "name": "SI deployment evidence",
      "slug": "si-deployment-evidence",
      "exitCode": 1,
      "logFile": "si-deployment-evidence.log",
      "recommendedAction": "Deploy the current SI image with Solana mainnet configuration. Record the SI Docker image digest, deployment ID, operator, commit, serviceInfo.schemaVersion=1 plus serviceInfo.serviceId=si.soramitsu.io with Solana mainnet identity, and healthInfo with ok=true, serviceId=si.soramitsu.io, genesisHash=5eykt4UsFv8P8NJdTREpY1vzqKqZKvdpKuc147dw2N9d, latestSlot as a positive safe integer, and syncedAt as an integer no more than 120 seconds before and no more than 30 seconds after smokePassedAt, plus successful https://si.soramitsu.io smoke evidence in ../solswap-indexer/scripts/production-deployment-evidence.json, then rerun npm run audit:deployment-evidence -- --require-ready in ../solswap-indexer.",
      "requiresExternalAction": true,
      "unblockCategory": "deployment-evidence",
      "externalPrerequisite": "Current SI image deployed with exact Solana mainnet genesisHash, positive latestSlot, fresh integer syncedAt, service-info identity, and operator-attested deployment evidence.",
      "verificationCommand": "cd ../solswap-indexer && npm run audit:deployment-evidence -- --require-ready",
      "evidencePreview": "SI deployment evidence log"
    },
    {
      "name": "TI production smoke",
      "slug": "ti-production-smoke",
      "exitCode": 1,
      "logFile": "ti-production-smoke.log",
      "recommendedAction": "Deploy the current ton-indexer image to https://ti.soramitsu.io so /api/indexer/v1/health exposes lastMasterSeqno and health.serviceId=ti.soramitsu.io with ecosystem=ton, chainId=ton:mainnet, and network=mainnet. TI production smoke also requires serviceInfo.schemaVersion=1, serviceInfo.serviceId=ti.soramitsu.io, publicBaseUrl=https://ti.soramitsu.io, readOnly=true, endpoints.openapi=/api/indexer/v1/openapi.json, and OpenAPI title TONSWAP Indexer API, then rerun TON_INDEXER_BASE_URL=https://ti.soramitsu.io npm run smoke:production in ../ton-indexer.",
      "requiresExternalAction": true,
      "unblockCategory": "live-service-deployment",
      "externalPrerequisite": "Updated TON indexer deployment serving TI mainnet health, service-info, and OpenAPI contracts.",
      "verificationCommand": "cd ../ton-indexer && TON_INDEXER_BASE_URL=https://ti.soramitsu.io npm run smoke:production",
      "evidencePreview": "health serviceId must be ti.soramitsu.io"
    },
    {
      "name": "SI production smoke",
      "slug": "si-production-smoke",
      "exitCode": 1,
      "logFile": "si-production-smoke.log",
      "recommendedAction": "Deploy the current SI image with Solana mainnet configuration so /api/indexer/v1/health returns health.ok=true, health.serviceId=si.soramitsu.io, health.ecosystem=solana, health.chainId=solana:mainnet, health.network=mainnet, health.genesisHash=5eykt4UsFv8P8NJdTREpY1vzqKqZKvdpKuc147dw2N9d, health.latestSlot as a positive safe integer, and health.syncedAt as an integer no more than 120 seconds old and no more than 30 seconds in the future, without advertising api.testnet.solana.com, and /api/indexer/v1/service-info exists. SI production smoke also requires serviceInfo.schemaVersion=1, serviceInfo.serviceId=si.soramitsu.io, ecosystem=solana, chainId=solana:mainnet, network=mainnet, publicBaseUrl=https://si.soramitsu.io, readOnly=true, endpoints.openapi=/api/indexer/v1/openapi.json, and OpenAPI title Solswap Indexer API, then rerun SOLSWAP_INDEXER_BASE_URL=https://si.soramitsu.io npm run smoke:production in ../solswap-indexer.",
      "requiresExternalAction": true,
      "unblockCategory": "live-service-deployment",
      "externalPrerequisite": "Current SI image deployed with exact Solana mainnet genesisHash, positive latestSlot, fresh integer syncedAt, release identity fields, service-info, and OpenAPI contracts.",
      "verificationCommand": "cd ../solswap-indexer && SOLSWAP_INDEXER_BASE_URL=https://si.soramitsu.io npm run smoke:production",
      "evidencePreview": "health serviceId must be si.soramitsu.io; received <missing>"
    },
    {
      "name": "PI deployment evidence",
      "slug": "pi-deployment-evidence",
      "exitCode": 1,
      "logFile": "pi-deployment-evidence.log",
      "recommendedAction": "Deploy the current polkaswap-indexer worker and API to https://pi.soramitsu.io/graphql with POLKASWAP_CHAIN_START_BLOCK set, a locally-controlled verifying archival primary RPC and an independently-operated verifying archive RPC on distinct hosts. Require the exact fixed audited SORA mainnet genesis/hash/timestamp anchor identity preflight on both RPCs before database access; exact dual-RPC agreement on finalized height, hash, canonical raw SCALE block, canonical raw SCALE events, and raw decimal timestamp milliseconds; and the compiled PostgreSQL worker health check proving the exact persisted chainState, matching filtered BLOCK snapshot, checkpoint freshness from 300 seconds behind through 30 seconds ahead, and secret-safe diagnostics. API health evidence must prove healthInfo.service=polkaswap-indexer, healthInfo.serviceId=pi.soramitsu.io, exact SORA mainnet genesisHash=0x7e4e32d0feafd4f9c9414b0be86373f9a1efa904809b683453a9af6856d38ad5, latestIndexedBlock as a positive safe integer, latestIndexedBlockHash as a canonical nonzero lowercase 32-byte hash, and latestIndexedAt no more than 300 seconds before or 30 seconds after the smoke timestamp. Record the Docker image digest, deployment ID, operator, commit, those exact healthInfo fields, successful smoke timestamp, soraRpcControls with primaryEndpoint, archiveEndpoint, primaryNodeControl=locally-controlled-verifying-archive, archiveNodeControl=independently-operated-verifying-archive, distinctHosts=true, exactIdentityPreflight=true, and rawPayloadAgreement=height-hash-scale-block-events-timestamp, plus tlsEdgeControls proving TLS termination, forwarded-client-IP header overwrite, 600 HTTP requests and 600 WebSocket upgrades per client per 60000ms, and 16 concurrent WebSockets per client in ../polkaswap-indexer/scripts/production-deployment-evidence.json, then, from ../polkaswap-indexer, rerun bash ../fearless/scripts/run-pinned-yarn.sh audit:deployment-evidence --require-ready.",
      "requiresExternalAction": true,
      "unblockCategory": "deployment-evidence",
      "externalPrerequisite": "Current PI worker/API deployed with required POLKASWAP_CHAIN_START_BLOCK, a locally-controlled verifying archival primary RPC and independently-operated verifying archive RPC on distinct hosts, exact fixed-anchor identity preflight, exact dual raw payload agreement, compiled PostgreSQL worker health proving exact persisted state/snapshot freshness with secret-safe diagnostics, and operator-attested image, deployment, commit, four-field health, SORA RPC-control, smoke, and TLS-edge evidence.",
      "verificationCommand": "cd ../polkaswap-indexer && bash ../fearless/scripts/run-pinned-yarn.sh audit:deployment-evidence --require-ready",
      "evidencePreview": "Production deployment evidence is not release-ready"
    },
    {
      "name": "PI production smoke",
      "slug": "pi-production-smoke",
      "exitCode": 1,
      "logFile": "pi-production-smoke.log",
      "recommendedAction": "Deploy the current polkaswap-indexer worker and API to https://pi.soramitsu.io/graphql with POLKASWAP_CHAIN_START_BLOCK set, a locally-controlled verifying archival primary RPC and an independently-operated verifying archive RPC on distinct hosts. Require the exact fixed audited SORA mainnet genesis/hash/timestamp anchor identity preflight on both RPCs before database access; exact dual-RPC agreement on finalized height, hash, canonical raw SCALE block, canonical raw SCALE events, and raw decimal timestamp milliseconds; and the compiled PostgreSQL worker health check proving the exact persisted chainState, matching filtered BLOCK snapshot, checkpoint freshness from 300 seconds behind through 30 seconds ahead, and secret-safe diagnostics. GraphQL _health must return health.ok=true, health.service=polkaswap-indexer, health.serviceId=pi.soramitsu.io, health.schemaVersion=1, health.ecosystem=sora2, health.chainId=sora:mainnet, health.network=mainnet, health.publicBaseUrl=https://pi.soramitsu.io/graphql, health.readOnly=true, exact SORA mainnet genesisHash=0x7e4e32d0feafd4f9c9414b0be86373f9a1efa904809b683453a9af6856d38ad5, a positive latestIndexedBlock, a canonical nonzero lowercase 32-byte latestIndexedBlockHash, and a latestIndexedAt within 300 seconds behind or 30 seconds ahead of the verifier. PI production smoke also requires an immutable exact fixed-anchor chainIdentity, a chainState record at or below finalized height and coherent with the health height/hash/timestamp, live hash and raw timestamp reconciliation, and a matching filtered BLOCK snapshot, and rejects TON and Solana/Solswap indexer contracts. Then, from ../polkaswap-indexer, rerun POLKASWAP_INDEXER_BASE_URL=https://pi.soramitsu.io/graphql bash ../fearless/scripts/run-pinned-yarn.sh smoke:production.",
      "requiresExternalAction": true,
      "unblockCategory": "live-service-deployment",
      "externalPrerequisite": "Updated PI worker/API serving the four SORA identity/checkpoint fields through GraphQL _health and coherent immutable chainIdentity, chainState, and filtered BLOCK worker state, backed by distinct controlled verifying archival RPCs, exact identity preflight and raw payload agreement, required chain start, and the compiled secret-safe worker health check.",
      "verificationCommand": "cd ../polkaswap-indexer && POLKASWAP_INDEXER_BASE_URL=https://pi.soramitsu.io/graphql bash ../fearless/scripts/run-pinned-yarn.sh smoke:production",
      "evidencePreview": "PI production GraphQL schema is missing _health identity fields"
    }
  ]
}
JSON

  node - "$report_dir/summary.json" "$report_dir/actions.json" <<'NODE'
const fs = require('fs')
const [summaryFile, actionsFile] = process.argv.slice(2)
const summary = JSON.parse(fs.readFileSync(summaryFile, 'utf8'))
const actions = JSON.parse(fs.readFileSync(actionsFile, 'utf8'))
const actionsBySlug = new Map(actions.blockers.map((blocker) => [blocker.slug, blocker]))
summary.checks.push({
  name: 'Source publication readiness',
  slug: 'source-publication-readiness',
  status: 'passed',
  exitCode: 0,
  logFile: 'source-publication-readiness.log',
  recommendedAction: null,
  requiresExternalAction: null,
  unblockCategory: null,
  externalPrerequisite: null,
  verificationCommand: null,
})
summary.totals.passed += 1
summary.totals.total += 1
actions.totals.passed += 1
actions.totals.total += 1
for (const check of summary.checks) {
  const action = actionsBySlug.get(check.slug)
  if (check.status === 'failed') {
    for (const key of ['recommendedAction', 'requiresExternalAction', 'unblockCategory', 'externalPrerequisite', 'verificationCommand']) {
      check[key] = action[key]
    }
  } else {
    check.recommendedAction = null
    check.requiresExternalAction = null
    check.unblockCategory = null
    check.externalPrerequisite = null
    check.verificationCommand = null
  }
}
fs.writeFileSync(summaryFile, `${JSON.stringify(summary, null, 2)}\n`)
fs.writeFileSync(actionsFile, `${JSON.stringify(actions, null, 2)}\n`)
NODE

  cat > "$report_dir/blockers.md" <<'MD'
# Release Readiness Blockers

- Generated at: 2026-06-28T00:00:00Z
- Run live checks: true
- Totals: 9 passed, 12 failed, 0 skipped, 21 total

## Failed Checks

### Release PR readiness

- Slug: `release-pr-readiness`
- Exit code: `1`
- Log: `release-pr-readiness.log`
- Recommended action: Get every PR in config/release-readiness-prs.tsv approved, green, with all GitHub review conversations resolved including outdated unresolved threads, and merged through the protected branch flow. When the blocker is outdated-only, run bash scripts/resolve-release-pr-review-threads.sh --dry-run to inspect the exact thread IDs before any authorized resolution. After conversations are resolved and approvals are present, run bash scripts/merge-release-prs.sh --dry-run to inspect protected-branch merge candidates before any authorized merge, then rerun bash scripts/audit-release-pr-readiness.sh.
- Requires external action: `true`
- Unblock category: `review-and-merge`
- External prerequisite: Reviewer approvals, resolved GitHub review conversations, and protected-branch merges.
- Verification command: `bash scripts/audit-release-pr-readiness.sh`

Evidence preview:

```text
solswap-io/solswap-indexer#8 is open
```

### Web Bitcoin broadcast evidence

- Slug: `web-bitcoin-broadcast-evidence`
- Exit code: `1`
- Log: `web-bitcoin-broadcast-evidence.log`
- Recommended action: Run a funded Bitcoin testnet send through the web wallet smoke flow, record txid/outpoint/operator evidence plus canonical https://blockstream.info/testnet/api indexerUrl and confirmed indexer status.block_time proof in fearless-wallet-web/scripts/bitcoin-testnet-broadcast-evidence.json, ensure the evidence timestamp is at or after the confirmed block time, then rerun bash scripts/audit-bitcoin-broadcast-evidence.sh --require-ready in fearless-wallet-web.
- Requires external action: `true`
- Unblock category: `funded-broadcast-evidence`
- External prerequisite: Funded confirmed Bitcoin testnet broadcast evidence for the current release commit using the canonical Blockstream testnet indexer.
- Verification command: `cd fearless-wallet-web && bash scripts/audit-bitcoin-broadcast-evidence.sh --require-ready`

Evidence preview:

```text
ready Bitcoin broadcast evidence requires at least one record
```

### Passkey deployment evidence

- Slug: `passkey-deployment-evidence`
- Exit code: `1`
- Log: `passkey-deployment-evidence.log`
- Recommended action: Record the passkey backup image digest, deployment ID, operator, healthResponse ok=true/service=fearless-passkey-backup/rpId=fearlesswallet.io/schemaVersion=1, durable credential store paths /data/passkey-backup and /data/passkey-backup/credentials.json, WebAuthn origin allowlist, fail-closed request-access policy, trusted-proxy policy, platform provisioning evidence, and successful smoke timestamp. Independently obtain the distribution signer SHA-256 fingerprint from a distribution-signed APK or the Play app-signing certificate, set PASSKEY_ANDROID_RELEASE_SIGNER_EVIDENCE_SOURCE=distributed-apk|play-app-signing-certificate to identify the source, and prove the derived origin matches assetlinks; AAB upload-key evidence is rejected and absence or mismatch keeps passkey flags disabled. Then rerun npm run audit:deployment-evidence -- --require-ready in services/passkey-backup-challenge-service and bash scripts/audit-passkey-android-origin-parity.sh --require-ready from the workspace root.
- Requires external action: `true`
- Unblock category: `deployment-evidence`
- External prerequisite: Production passkey backup deployment image, health response, credential-store volume, request-access and trusted-proxy evidence, plus independently obtained distribution signer SHA-256 evidence from a distribution-signed APK or Play app-signing certificate, with PASSKEY_ANDROID_RELEASE_SIGNER_EVIDENCE_SOURCE=distributed-apk|play-app-signing-certificate and a matching assetlinks origin; AAB upload-key evidence is rejected and absence keeps passkey flags disabled.
- Verification command: `cd services/passkey-backup-challenge-service && npm run audit:deployment-evidence -- --require-ready && cd ../.. && bash scripts/audit-passkey-android-origin-parity.sh --require-ready`

Evidence preview:

```text
passkey production deployment evidence is not release-ready
```

### Passkey production smoke

- Slug: `passkey-production-smoke`
- Exit code: `1`
- Log: `passkey-production-smoke.log`
- Recommended action: Deploy and route https://backup.fearlesswallet.io to services/passkey-backup-challenge-service with valid DNS/TLS. Provision PASSKEY_BACKUP_SMOKE_GRANT_HELPER=/run/secrets/passkey-smoke-grant-helper as a readable executable that issues single-use bearer grants for the exact smoke requests, then run the passkey production smoke to verify health, all four ceremony routes, and credential list/revoke/revoke-all contracts without persisting a test credential or creating an owner record.
- Requires external action: `true`
- Unblock category: `live-service-deployment`
- External prerequisite: DNS, TLS, and routing for backup.fearlesswallet.io to the passkey backup challenge service route surface, plus PASSKEY_BACKUP_SMOKE_GRANT_HELPER=/run/secrets/passkey-smoke-grant-helper provisioned as a readable executable that issues single-use bearer grants for the exact smoke requests.
- Verification command: `cd services/passkey-backup-challenge-service && PASSKEY_BACKUP_BASE_URL=https://backup.fearlesswallet.io PASSKEY_BACKUP_SMOKE_GRANT_HELPER=/run/secrets/passkey-smoke-grant-helper PASSKEY_BACKUP_SMOKE_TIMEOUT_MS=10000 npm run smoke:production`

Evidence preview:

```text
GET /api/passkey-backup/v1/health request to https://backup.fearlesswallet.io failed
```

### Iroha Taira/Nexus release prerequisites

- Slug: `iroha-release-readiness`
- Exit code: `1`
- Log: `iroha-release-readiness.log`
- Recommended action: Do not edit or publish from an unfinished external Iroha Git operation. Have its owner produce a stable reviewed source commit and restore the pinned Iroha JS SDK release artifact so package.json exports ./ivm-artifact and the packaged runtime/declaration surface passes the wallet artifact validator. Pin NEXUS_EXPECTED_BUILD_COMMIT in config/iroha-release-readiness.env to the exact deployed Iroha build. Restore https://minamoto.sora.org/status as a bounded, non-redirecting HTTP 200 application/json Torii/Nexus status response with fresh observed_at_ms and last_block_committed_at_ms, coherent block and queue counters, a matching non-placeholder build.git_commit_sha, the exact ordered SORA routing policy (default 0/0, governance 1/1, smartcontract::deploy 2/2), and an unsealed dataspace_catalog containing ready canonical 0/0, 1/1, and 2/2 targets; record Nexus route publication, canary, and wallet live transfer smoke evidence, keep Nexus release-gated until strict production evidence passes, then rerun bash scripts/audit-iroha-release-readiness.sh.
- Requires external action: `true`
- Unblock category: `live-service-and-evidence`
- External prerequisite: A stable owner-reviewed Iroha source commit; a pinned Iroha JS SDK release artifact exporting ./ivm-artifact and passing packaged runtime/declaration validation; the exact deployed Iroha build pin; bounded, non-redirecting HTTP 200 application/json Minamoto Torii/Nexus status with fresh observation and block timestamps, coherent block and queue counters, exact canonical routing/dataspace catalog; plus route publication, canary, and wallet live-transfer evidence.
- Verification command: `IROHA_NEXUS_REQUIRE_PRODUCTION_EVIDENCE=1 IROHA_NEXUS_LIVE_HEALTH=1 bash scripts/audit-iroha-release-readiness.sh`

Evidence preview:

```text
SORA Nexus Torii live health check failed for https://minamoto.sora.org/status
```

### Android XCM production evidence

- Slug: `android-xcm-production-evidence`
- Exit code: `1`
- Log: `android-xcm-production-evidence.log`
- Recommended action: Keep release ENABLE_PRODUCTION_XCM_TRANSFERS=false until the entire trust and evidence gate is ready. Obtain reviewed per-asset pallet/call, reserve-or-teleport, multilocation, beneficiary, weight, destination-fee, and any bridge execution semantics for every advertised Android XCM route; implement bridge or estimator support before approving those modes. The per-asset schema, loader, validator, registry, and engine representation is now implemented, and all 15 approved single-asset routes are migrated without semantic changes. The current 34 discovery-only destinations cover 59 route assets; 14 of those destinations cover 39 multi-asset routes, and every one remains disabled until its exact reviewed semantics exist. Expand the APK-owned approved_xcm_routes.tsv and scripts/xcm-required-routes.tsv in exact lockstep only after those route semantics are reviewed, and make the production discovery intersection contain every approved route. Then record one funded mainnet E2E transfer per required route in fearless-Android/scripts/xcm-production-evidence.json, including 0x-prefixed 32-byte extrinsicHash, sender, recipient, positive amount, UTC timestamp, environment, operator, and androidCommit matching the release commit, plus finalized origin/destination block hashes and numbers, true origin finality/extrinsic success/destination event success, a positive destination balance delta, distinct public HTTPS proof URLs, verificationMethod=canonical-rpc-and-explorer, verifiedAt, and an independentVerifier distinct from operator. Regenerate the canonical live effective report and validate it with the ready evidence, then run the all-routes metadata gate before a separately reviewed release-flag change.
- Requires external action: `true`
- Unblock category: `route-implementation-and-evidence`
- External prerequisite: Reviewed per-asset execution semantics and effective production discovery for every advertised Android XCM route, implementation of any required bridge or fee-estimator path, a separately reviewed release enablement change, funded mainnet E2E evidence for the exact effective route set, and Android release-commit binding.
- Verification command: `cd fearless-Android && bash scripts/audit-xcm-effective-registry.sh --discovery-url https://raw.githubusercontent.com/soramitsu/shared-features-utils/master/chains/v13/chains.json --require-all-approved --write-report build/reports/xcm-effective-registry-report.json && bash scripts/audit-xcm-production-evidence.sh --effective-registry-report build/reports/xcm-effective-registry-report.json --require-ready && bash scripts/audit-xcm-registry-metadata.sh --require-executable --require-all-routes-executable --require-route-file scripts/xcm-required-routes.tsv --require-gap-file scripts/xcm-discovery-only-routes.tsv`

Evidence preview:

```text
ready evidence cannot have discovery-only routes remaining
```

### TI deployment evidence

- Slug: `ti-deployment-evidence`
- Exit code: `1`
- Log: `ti-deployment-evidence.log`
- Recommended action: Populate ../ton-indexer/registry/mainnet.json with reviewed non-placeholder mainnet contract addresses. Record the TI Docker image digest, deployment ID, operator, commit, serviceInfo.schemaVersion=1 plus serviceInfo.serviceId=ti.soramitsu.io with TON mainnet identity, healthInfo.serviceId=ti.soramitsu.io with healthInfo.lastMasterSeqno from the successful https://ti.soramitsu.io smoke evidence, then rerun npm run audit:deployment-evidence -- --require-ready in ../ton-indexer.
- Requires external action: `true`
- Unblock category: `deployment-evidence`
- External prerequisite: Reviewed TON mainnet registry addresses plus deployed TI image, smoke, and health evidence.
- Verification command: `cd ../ton-indexer && npm run audit:deployment-evidence -- --require-ready`

Evidence preview:

```text
TI deployment evidence log
```

### SI deployment evidence

- Slug: `si-deployment-evidence`
- Exit code: `1`
- Log: `si-deployment-evidence.log`
- Recommended action: Deploy the current SI image with Solana mainnet configuration. Record the SI Docker image digest, deployment ID, operator, commit, serviceInfo.schemaVersion=1 plus serviceInfo.serviceId=si.soramitsu.io with Solana mainnet identity, and healthInfo with ok=true, serviceId=si.soramitsu.io, genesisHash=5eykt4UsFv8P8NJdTREpY1vzqKqZKvdpKuc147dw2N9d, latestSlot as a positive safe integer, and syncedAt as an integer no more than 120 seconds before and no more than 30 seconds after smokePassedAt, plus successful https://si.soramitsu.io smoke evidence in ../solswap-indexer/scripts/production-deployment-evidence.json, then rerun npm run audit:deployment-evidence -- --require-ready in ../solswap-indexer.
- Requires external action: `true`
- Unblock category: `deployment-evidence`
- External prerequisite: Current SI image deployed with exact Solana mainnet genesisHash, positive latestSlot, fresh integer syncedAt, service-info identity, and operator-attested deployment evidence.
- Verification command: `cd ../solswap-indexer && npm run audit:deployment-evidence -- --require-ready`

Evidence preview:

```text
SI deployment evidence log
```

### TI production smoke

- Slug: `ti-production-smoke`
- Exit code: `1`
- Log: `ti-production-smoke.log`
- Recommended action: Deploy the current ton-indexer image to https://ti.soramitsu.io so /api/indexer/v1/health exposes lastMasterSeqno and health.serviceId=ti.soramitsu.io with ecosystem=ton, chainId=ton:mainnet, and network=mainnet. TI production smoke also requires serviceInfo.schemaVersion=1, serviceInfo.serviceId=ti.soramitsu.io, publicBaseUrl=https://ti.soramitsu.io, readOnly=true, endpoints.openapi=/api/indexer/v1/openapi.json, and OpenAPI title TONSWAP Indexer API, then rerun TON_INDEXER_BASE_URL=https://ti.soramitsu.io npm run smoke:production in ../ton-indexer.
- Requires external action: `true`
- Unblock category: `live-service-deployment`
- External prerequisite: Updated TON indexer deployment serving TI mainnet health, service-info, and OpenAPI contracts.
- Verification command: `cd ../ton-indexer && TON_INDEXER_BASE_URL=https://ti.soramitsu.io npm run smoke:production`

Evidence preview:

```text
health serviceId must be ti.soramitsu.io
```

### SI production smoke

- Slug: `si-production-smoke`
- Exit code: `1`
- Log: `si-production-smoke.log`
- Recommended action: Deploy the current SI image with Solana mainnet configuration so /api/indexer/v1/health returns health.ok=true, health.serviceId=si.soramitsu.io, health.ecosystem=solana, health.chainId=solana:mainnet, health.network=mainnet, health.genesisHash=5eykt4UsFv8P8NJdTREpY1vzqKqZKvdpKuc147dw2N9d, health.latestSlot as a positive safe integer, and health.syncedAt as an integer no more than 120 seconds old and no more than 30 seconds in the future, without advertising api.testnet.solana.com, and /api/indexer/v1/service-info exists. SI production smoke also requires serviceInfo.schemaVersion=1, serviceInfo.serviceId=si.soramitsu.io, ecosystem=solana, chainId=solana:mainnet, network=mainnet, publicBaseUrl=https://si.soramitsu.io, readOnly=true, endpoints.openapi=/api/indexer/v1/openapi.json, and OpenAPI title Solswap Indexer API, then rerun SOLSWAP_INDEXER_BASE_URL=https://si.soramitsu.io npm run smoke:production in ../solswap-indexer.
- Requires external action: `true`
- Unblock category: `live-service-deployment`
- External prerequisite: Current SI image deployed with exact Solana mainnet genesisHash, positive latestSlot, fresh integer syncedAt, release identity fields, service-info, and OpenAPI contracts.
- Verification command: `cd ../solswap-indexer && SOLSWAP_INDEXER_BASE_URL=https://si.soramitsu.io npm run smoke:production`

Evidence preview:

```text
health serviceId must be si.soramitsu.io; received <missing>
```

### PI deployment evidence

- Slug: `pi-deployment-evidence`
- Exit code: `1`
- Log: `pi-deployment-evidence.log`
- Recommended action: Deploy the current polkaswap-indexer worker and API to https://pi.soramitsu.io/graphql with POLKASWAP_CHAIN_START_BLOCK set, a locally-controlled verifying archival primary RPC and an independently-operated verifying archive RPC on distinct hosts. Require the exact fixed audited SORA mainnet genesis/hash/timestamp anchor identity preflight on both RPCs before database access; exact dual-RPC agreement on finalized height, hash, canonical raw SCALE block, canonical raw SCALE events, and raw decimal timestamp milliseconds; and the compiled PostgreSQL worker health check proving the exact persisted chainState, matching filtered BLOCK snapshot, checkpoint freshness from 300 seconds behind through 30 seconds ahead, and secret-safe diagnostics. API health evidence must prove healthInfo.service=polkaswap-indexer, healthInfo.serviceId=pi.soramitsu.io, exact SORA mainnet genesisHash=0x7e4e32d0feafd4f9c9414b0be86373f9a1efa904809b683453a9af6856d38ad5, latestIndexedBlock as a positive safe integer, latestIndexedBlockHash as a canonical nonzero lowercase 32-byte hash, and latestIndexedAt no more than 300 seconds before or 30 seconds after the smoke timestamp. Record the Docker image digest, deployment ID, operator, commit, those exact healthInfo fields, successful smoke timestamp, soraRpcControls with primaryEndpoint, archiveEndpoint, primaryNodeControl=locally-controlled-verifying-archive, archiveNodeControl=independently-operated-verifying-archive, distinctHosts=true, exactIdentityPreflight=true, and rawPayloadAgreement=height-hash-scale-block-events-timestamp, plus tlsEdgeControls proving TLS termination, forwarded-client-IP header overwrite, 600 HTTP requests and 600 WebSocket upgrades per client per 60000ms, and 16 concurrent WebSockets per client in ../polkaswap-indexer/scripts/production-deployment-evidence.json, then, from ../polkaswap-indexer, rerun bash ../fearless/scripts/run-pinned-yarn.sh audit:deployment-evidence --require-ready.
- Requires external action: `true`
- Unblock category: `deployment-evidence`
- External prerequisite: Current PI worker/API deployed with required POLKASWAP_CHAIN_START_BLOCK, a locally-controlled verifying archival primary RPC and independently-operated verifying archive RPC on distinct hosts, exact fixed-anchor identity preflight, exact dual raw payload agreement, compiled PostgreSQL worker health proving exact persisted state/snapshot freshness with secret-safe diagnostics, and operator-attested image, deployment, commit, four-field health, SORA RPC-control, smoke, and TLS-edge evidence.
- Verification command: `cd ../polkaswap-indexer && bash ../fearless/scripts/run-pinned-yarn.sh audit:deployment-evidence --require-ready`

Evidence preview:

```text
Production deployment evidence is not release-ready
```

### PI production smoke

- Slug: `pi-production-smoke`
- Exit code: `1`
- Log: `pi-production-smoke.log`
- Recommended action: Deploy the current polkaswap-indexer worker and API to https://pi.soramitsu.io/graphql with POLKASWAP_CHAIN_START_BLOCK set, a locally-controlled verifying archival primary RPC and an independently-operated verifying archive RPC on distinct hosts. Require the exact fixed audited SORA mainnet genesis/hash/timestamp anchor identity preflight on both RPCs before database access; exact dual-RPC agreement on finalized height, hash, canonical raw SCALE block, canonical raw SCALE events, and raw decimal timestamp milliseconds; and the compiled PostgreSQL worker health check proving the exact persisted chainState, matching filtered BLOCK snapshot, checkpoint freshness from 300 seconds behind through 30 seconds ahead, and secret-safe diagnostics. GraphQL _health must return health.ok=true, health.service=polkaswap-indexer, health.serviceId=pi.soramitsu.io, health.schemaVersion=1, health.ecosystem=sora2, health.chainId=sora:mainnet, health.network=mainnet, health.publicBaseUrl=https://pi.soramitsu.io/graphql, health.readOnly=true, exact SORA mainnet genesisHash=0x7e4e32d0feafd4f9c9414b0be86373f9a1efa904809b683453a9af6856d38ad5, a positive latestIndexedBlock, a canonical nonzero lowercase 32-byte latestIndexedBlockHash, and a latestIndexedAt within 300 seconds behind or 30 seconds ahead of the verifier. PI production smoke also requires an immutable exact fixed-anchor chainIdentity, a chainState record at or below finalized height and coherent with the health height/hash/timestamp, live hash and raw timestamp reconciliation, and a matching filtered BLOCK snapshot, and rejects TON and Solana/Solswap indexer contracts. Then, from ../polkaswap-indexer, rerun POLKASWAP_INDEXER_BASE_URL=https://pi.soramitsu.io/graphql bash ../fearless/scripts/run-pinned-yarn.sh smoke:production.
- Requires external action: `true`
- Unblock category: `live-service-deployment`
- External prerequisite: Updated PI worker/API serving the four SORA identity/checkpoint fields through GraphQL _health and coherent immutable chainIdentity, chainState, and filtered BLOCK worker state, backed by distinct controlled verifying archival RPCs, exact identity preflight and raw payload agreement, required chain start, and the compiled secret-safe worker health check.
- Verification command: `cd ../polkaswap-indexer && POLKASWAP_INDEXER_BASE_URL=https://pi.soramitsu.io/graphql bash ../fearless/scripts/run-pinned-yarn.sh smoke:production`

Evidence preview:

```text
PI production GraphQL schema is missing _health identity fields
```

MD

  printf '%s\n' \
    "solswap-io/solswap-indexer#8 is open" \
    "[release-pr-readiness][warn] solswap-io/solswap-indexer#8 is open" \
    "[release-pr-readiness][warn] soramitsu/fearless-wallet-web#1061 is open and is not release-ready: https://github.com/soramitsu/fearless-wallet-web/pull/1061 isDraft=false reviewDecision=REVIEW_REQUIRED mergeStateStatus=BLOCKED unresolvedReviewThreads=2 currentUnresolvedReviewThreads=0 outdatedUnresolvedReviewThreads=2 reviewConversationResolutionRequired=true outdatedReviewThreadsStillBlockMerge=true unresolvedReviewThreadRefs=outdated:scripts/audit-bitcoin-broadcast-evidence.sh:284:https://github.com/soramitsu/fearless-wallet-web/pull/1061#discussion_r1;outdated:scripts/audit-bitcoin-broadcast-evidence.sh:285:https://github.com/soramitsu/fearless-wallet-web/pull/1061#discussion_r2 unresolvedReviewThreadIds=PRRT_release_one,PRRT_release_two" \
    "[release-pr-readiness][warn] tonswap-org/ton-indexer#9 is open and is not release-ready: https://github.com/tonswap-org/ton-indexer/pull/9 isDraft=false reviewDecision=REVIEW_REQUIRED mergeStateStatus=BLOCKED eligibleReviewerApprovalRequired=true approvalCount=1 currentHeadApprovalCount=1 latestApprovalCommit=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa currentApprovalNotEligible=true unresolvedReviewThreads=0 currentUnresolvedReviewThreads=0 outdatedUnresolvedReviewThreads=0" \
    "[release-pr-readiness][warn] tonswap-org/ton-indexer#10 is open and is not release-ready: https://github.com/tonswap-org/ton-indexer/pull/10 isDraft=false reviewDecision=REVIEW_REQUIRED mergeStateStatus=BLOCKED eligibleReviewerApprovalRequired=true reviewDetails=unavailable unresolvedReviewThreads=0 currentUnresolvedReviewThreads=0 outdatedUnresolvedReviewThreads=0" \
    "[release-pr-readiness][warn] sora-xor/polkaswap-indexer#1 is open and is not release-ready: https://github.com/sora-xor/polkaswap-indexer/pull/1 isDraft=false reviewDecision=UNKNOWN mergeStateStatus=CLEAN eligibleReviewerApprovalRequired=true approvalCount=0 currentHeadApprovalCount=0 unresolvedReviewThreads=0 currentUnresolvedReviewThreads=0 outdatedUnresolvedReviewThreads=0" \
    > "$report_dir/release-pr-readiness.log"
  cat > "$report_dir/release-pr-readiness-report.json" <<'JSON'
{
  "schemaVersion": 1,
  "generatedAt": "2026-06-28T00:00:00Z",
  "configFile": "/workspace/config/release-readiness-prs.tsv",
  "status": "failed",
  "checkedCount": 4,
  "totals": {
    "passed": 0,
    "failed": 4,
    "total": 4
  },
  "failures": [
    "soramitsu/fearless-wallet-web#1061 is open and is not release-ready: https://github.com/soramitsu/fearless-wallet-web/pull/1061 isDraft=false reviewDecision=REVIEW_REQUIRED mergeStateStatus=BLOCKED unresolvedReviewThreads=2 currentUnresolvedReviewThreads=0 outdatedUnresolvedReviewThreads=2 reviewConversationResolutionRequired=true outdatedReviewThreadsStillBlockMerge=true unresolvedReviewThreadRefs=outdated:scripts/audit-bitcoin-broadcast-evidence.sh:284:https://github.com/soramitsu/fearless-wallet-web/pull/1061#discussion_r1;outdated:scripts/audit-bitcoin-broadcast-evidence.sh:285:https://github.com/soramitsu/fearless-wallet-web/pull/1061#discussion_r2 unresolvedReviewThreadIds=PRRT_release_one,PRRT_release_two",
    "tonswap-org/ton-indexer#9 is open and is not release-ready: https://github.com/tonswap-org/ton-indexer/pull/9 isDraft=false reviewDecision=REVIEW_REQUIRED mergeStateStatus=BLOCKED eligibleReviewerApprovalRequired=true approvalCount=1 currentHeadApprovalCount=1 latestApprovalCommit=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa currentApprovalNotEligible=true unresolvedReviewThreads=0 currentUnresolvedReviewThreads=0 outdatedUnresolvedReviewThreads=0",
    "tonswap-org/ton-indexer#10 is open and is not release-ready: https://github.com/tonswap-org/ton-indexer/pull/10 isDraft=false reviewDecision=REVIEW_REQUIRED mergeStateStatus=BLOCKED eligibleReviewerApprovalRequired=true reviewDetails=unavailable unresolvedReviewThreads=0 currentUnresolvedReviewThreads=0 outdatedUnresolvedReviewThreads=0",
    "sora-xor/polkaswap-indexer#1 is open and is not release-ready: https://github.com/sora-xor/polkaswap-indexer/pull/1 isDraft=false reviewDecision=UNKNOWN mergeStateStatus=CLEAN eligibleReviewerApprovalRequired=true approvalCount=0 currentHeadApprovalCount=0 unresolvedReviewThreads=0 currentUnresolvedReviewThreads=0 outdatedUnresolvedReviewThreads=0"
  ],
  "requirements": [
    {
      "status": "failed",
      "configLine": 6,
      "repo": "soramitsu/fearless-wallet-web",
      "head": "codex/web-bitcoin-broadcast-evidence",
      "base": "develop",
      "requiredState": "merged",
      "requiredChecks": ["validate", "verify"],
      "message": "soramitsu/fearless-wallet-web#1061 is open and is not release-ready: https://github.com/soramitsu/fearless-wallet-web/pull/1061 isDraft=false reviewDecision=REVIEW_REQUIRED mergeStateStatus=BLOCKED unresolvedReviewThreads=2 currentUnresolvedReviewThreads=0 outdatedUnresolvedReviewThreads=2 reviewConversationResolutionRequired=true outdatedReviewThreadsStillBlockMerge=true unresolvedReviewThreadRefs=outdated:scripts/audit-bitcoin-broadcast-evidence.sh:284:https://github.com/soramitsu/fearless-wallet-web/pull/1061#discussion_r1;outdated:scripts/audit-bitcoin-broadcast-evidence.sh:285:https://github.com/soramitsu/fearless-wallet-web/pull/1061#discussion_r2 unresolvedReviewThreadIds=PRRT_release_one,PRRT_release_two",
      "pr": {
        "repo": "soramitsu/fearless-wallet-web",
        "number": 1061,
        "url": "https://github.com/soramitsu/fearless-wallet-web/pull/1061"
      },
      "isDraft": false,
      "reviewDecision": "REVIEW_REQUIRED",
      "mergeStateStatus": "BLOCKED",
      "unresolvedReviewThreads": 2,
      "currentUnresolvedReviewThreads": 0,
      "outdatedUnresolvedReviewThreads": 2
    },
    {
      "status": "failed",
      "configLine": 20,
      "repo": "tonswap-org/ton-indexer",
      "head": "hotfix/indexer-service-info-schema-smoke",
      "base": "master",
      "requiredState": "merged",
      "requiredChecks": ["validate", "verify"],
      "message": "tonswap-org/ton-indexer#9 is open and is not release-ready: https://github.com/tonswap-org/ton-indexer/pull/9 isDraft=false reviewDecision=REVIEW_REQUIRED mergeStateStatus=BLOCKED eligibleReviewerApprovalRequired=true approvalCount=1 currentHeadApprovalCount=1 latestApprovalCommit=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa currentApprovalNotEligible=true unresolvedReviewThreads=0 currentUnresolvedReviewThreads=0 outdatedUnresolvedReviewThreads=0",
      "pr": {
        "repo": "tonswap-org/ton-indexer",
        "number": 9,
        "url": "https://github.com/tonswap-org/ton-indexer/pull/9"
      },
      "isDraft": false,
      "reviewDecision": "REVIEW_REQUIRED",
      "mergeStateStatus": "BLOCKED",
      "eligibleReviewerApprovalRequired": true,
      "approvalCount": 1,
      "currentHeadApprovalCount": 1,
      "latestApprovalCommit": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
      "currentApprovalNotEligible": true,
      "unresolvedReviewThreads": 0,
      "currentUnresolvedReviewThreads": 0,
      "outdatedUnresolvedReviewThreads": 0
    },
    {
      "status": "failed",
      "configLine": 22,
      "repo": "tonswap-org/ton-indexer",
      "head": "hotfix/deployment-evidence-placeholder-quality",
      "base": "master",
      "requiredState": "merged",
      "requiredChecks": ["validate", "verify"],
      "message": "tonswap-org/ton-indexer#10 is open and is not release-ready: https://github.com/tonswap-org/ton-indexer/pull/10 isDraft=false reviewDecision=REVIEW_REQUIRED mergeStateStatus=BLOCKED eligibleReviewerApprovalRequired=true reviewDetails=unavailable unresolvedReviewThreads=0 currentUnresolvedReviewThreads=0 outdatedUnresolvedReviewThreads=0",
      "pr": {
        "repo": "tonswap-org/ton-indexer",
        "number": 10,
        "url": "https://github.com/tonswap-org/ton-indexer/pull/10"
      },
      "isDraft": false,
      "reviewDecision": "REVIEW_REQUIRED",
      "mergeStateStatus": "BLOCKED",
      "eligibleReviewerApprovalRequired": true,
      "reviewDetails": "unavailable",
      "unresolvedReviewThreads": 0,
      "currentUnresolvedReviewThreads": 0,
      "outdatedUnresolvedReviewThreads": 0
    },
    {
      "status": "failed",
      "configLine": 23,
      "repo": "sora-xor/polkaswap-indexer",
      "head": "codex/pi-deployment-evidence-gate",
      "base": "develop",
      "requiredState": "merged",
      "requiredChecks": ["validate", "verify"],
      "message": "sora-xor/polkaswap-indexer#1 is open and is not release-ready: https://github.com/sora-xor/polkaswap-indexer/pull/1 isDraft=false reviewDecision=UNKNOWN mergeStateStatus=CLEAN eligibleReviewerApprovalRequired=true approvalCount=0 currentHeadApprovalCount=0 unresolvedReviewThreads=0 currentUnresolvedReviewThreads=0 outdatedUnresolvedReviewThreads=0",
      "pr": {
        "repo": "sora-xor/polkaswap-indexer",
        "number": 1,
        "url": "https://github.com/sora-xor/polkaswap-indexer/pull/1"
      },
      "isDraft": false,
      "reviewDecision": "UNKNOWN",
      "mergeStateStatus": "CLEAN",
      "eligibleReviewerApprovalRequired": true,
      "approvalCount": 0,
      "currentHeadApprovalCount": 0,
      "unresolvedReviewThreads": 0,
      "currentUnresolvedReviewThreads": 0,
      "outdatedUnresolvedReviewThreads": 0
    }
  ]
}
JSON
  node - "$report_dir/release-pr-readiness-report.json" "$workspace_dir/config/release-readiness-prs.tsv" <<'NODE'
const fs = require('fs')
const [file, configFile] = process.argv.slice(2)
const data = JSON.parse(fs.readFileSync(file, 'utf8'))
data.configFile = configFile
fs.writeFileSync(file, JSON.stringify(data, null, 2))
NODE
  printf '%s\n' "ready Bitcoin broadcast evidence requires at least one record" > "$report_dir/web-bitcoin-broadcast-evidence.log"
  cat > "$report_dir/web-bitcoin-broadcast-evidence-template.json" <<JSON
{
  "schemaVersion": 1,
  "scope": "web-bitcoin-testnet-broadcast-readiness",
  "status": "ready",
  "releaseEnabled": true,
  "lastReviewed": "TODO_YYYY_MM_DD",
  "blockers": [],
  "smokeCommand": "yarn test:smoke:bitcoin",
  "readyVerificationCommands": [
    "yarn test:bitcoin-broadcast-evidence-template",
    "yarn generate:bitcoin-broadcast-evidence-template -- --output build/reports/bitcoin-broadcast-evidence-template.json",
    "yarn test:bitcoin-broadcast-evidence-audit",
    "yarn audit:bitcoin-broadcast-evidence --require-ready",
    "FEARLESS_BITCOIN_TESTNET_LIVE=1 yarn test:smoke:bitcoin"
  ],
  "liveSmokeEnvironment": [
    "FEARLESS_BITCOIN_TESTNET_LIVE",
    "FEARLESS_BITCOIN_TESTNET_MNEMONIC",
    "FEARLESS_BITCOIN_TESTNET_SOURCE_ADDRESS",
    "FEARLESS_BITCOIN_TESTNET_RECIPIENT_ADDRESS",
    "FEARLESS_BITCOIN_TESTNET_AMOUNT_SAT",
    "FEARLESS_BITCOIN_TESTNET_OUTPOINT"
  ],
  "defaultIndexerUrl": "https://blockstream.info/testnet/api",
  "requiredEvidenceFields": [
    "txid",
    "sourceAddress",
    "recipientAddress",
    "amountSat",
    "outpoint",
    "indexerUrl",
    "timestamp",
    "operator",
    "commit"
  ],
  "evidence": [
    {
      "txid": "TODO_64_HEX_TESTNET_TXID",
      "sourceAddress": "TODO_TESTNET_SOURCE_TB1Q_ADDRESS",
      "recipientAddress": "TODO_TESTNET_RECIPIENT_TB1Q_ADDRESS",
      "amountSat": "TODO_POSITIVE_INTEGER_SATS",
      "outpoint": "TODO_64_HEX_FUNDING_TXID:TODO_VOUT",
      "indexerUrl": "https://blockstream.info/testnet/api",
      "timestamp": "TODO_UTC_TIMESTAMP_SECONDS",
      "operator": "TODO_RELEASE_OPERATOR",
      "commit": "TODO_40_HEX_GIT_COMMIT"
    }
  ]
}
JSON
  printf '%s\n' "passkey production deployment evidence is not release-ready" > "$report_dir/passkey-deployment-evidence.log"
  cat > "$report_dir/passkey-deployment-evidence-template.json" <<JSON
{
  "schemaVersion": 1,
  "scope": "passkey-backup-challenge-service-production-deployment-readiness",
  "service": "fearless-passkey-backup",
  "rpId": "fearlesswallet.io",
  "baseUrl": "https://backup.fearlesswallet.io",
  "healthUrl": "https://backup.fearlesswallet.io/api/passkey-backup/v1/health",
  "imageName": "passkey-backup-challenge-service",
  "port": 8789,
  "credentialStoreVolume": "/data/passkey-backup",
  "credentialStoreFile": "/data/passkey-backup/credentials.json",
  "status": "ready",
  "releaseEnabled": true,
  "blockers": [],
  "dockerBuildCommand": "docker build -t passkey-backup-challenge-service:release .",
  "smokeCommand": "PASSKEY_BACKUP_BASE_URL=https://backup.fearlesswallet.io PASSKEY_BACKUP_SMOKE_GRANT_HELPER=/run/secrets/passkey-smoke-grant-helper PASSKEY_BACKUP_SMOKE_TIMEOUT_MS=10000 npm run smoke:production",
  "requiredCommands": [
    "npm run lint:syntax",
    "npm test",
    "npm run test:deployment-evidence-template",
    "npm run generate:deployment-evidence-template -- --output build/reports/production-deployment-evidence-template.json",
    "npm run test:deployment-evidence-audit",
    "npm run audit:deployment-evidence",
    "docker build -t passkey-backup-challenge-service:release .",
    "PASSKEY_BACKUP_LIVE_HEALTH=1 PASSKEY_BACKUP_HEALTH_TIMEOUT_SECONDS=10 bash ../../scripts/audit-passkey-backup-prerequisites.sh",
    "PASSKEY_BACKUP_BASE_URL=https://backup.fearlesswallet.io PASSKEY_BACKUP_SMOKE_GRANT_HELPER=/run/secrets/passkey-smoke-grant-helper PASSKEY_BACKUP_SMOKE_TIMEOUT_MS=10000 npm run smoke:production",
    "npm run audit:deployment-evidence -- --require-ready"
  ],
  "requiredEvidenceFields": [
    "imageDigest",
    "deploymentId",
    "deployedCommit",
    "deployedAt",
    "operator",
    "smokePassedAt",
    "smokeCommand",
    "healthUrl",
    "healthResponse",
    "liveHealthAttestation",
    "credentialStoreVolume",
    "credentialStoreFile",
    "webauthnAllowedOrigins",
    "requestAccessPolicy",
    "trustedProxyPolicy",
    "platformProvisioning",
    "platformProvisioningAttestation"
  ],
  "deploymentEvidence": [
    {
      "imageDigest": "sha256:TODO_64_HEX_IMAGE_DIGEST",
      "deploymentId": "TODO_PRODUCTION_DEPLOYMENT_ID",
      "deployedCommit": "TODO_40_HEX_GIT_COMMIT",
      "deployedAt": "TODO_UTC_DEPLOYED_AT_SECONDS",
      "operator": "TODO_RELEASE_OPERATOR",
      "smokePassedAt": "TODO_UTC_SMOKE_TIMESTAMP_SECONDS",
      "smokeCommand": "PASSKEY_BACKUP_BASE_URL=https://backup.fearlesswallet.io PASSKEY_BACKUP_SMOKE_GRANT_HELPER=/run/secrets/passkey-smoke-grant-helper PASSKEY_BACKUP_SMOKE_TIMEOUT_MS=10000 npm run smoke:production",
      "healthUrl": "https://backup.fearlesswallet.io/api/passkey-backup/v1/health",
      "healthResponse": {
        "ok": true,
        "service": "fearless-passkey-backup",
        "rpId": "fearlesswallet.io",
        "schemaVersion": 1
      },
      "liveHealthAttestation": {
        "deploymentId": "TODO_PRODUCTION_DEPLOYMENT_ID",
        "deployedCommit": "TODO_40_HEX_GIT_COMMIT",
        "imageDigest": "sha256:TODO_64_HEX_IMAGE_DIGEST",
        "observedAt": "TODO_UTC_SMOKE_TIMESTAMP_SECONDS",
        "payloadSha256": "sha256:TODO_CANONICAL_HEALTH_RESPONSE_SHA256"
      },
      "credentialStoreVolume": "/data/passkey-backup",
      "credentialStoreFile": "/data/passkey-backup/credentials.json",
      "webauthnAllowedOrigins": [
        "https://fearlesswallet.io",
        "https://backup.fearlesswallet.io",
        "android:apk-key-hash:TODO_RELEASE_CERT_SHA256_BASE64URL"
      ],
      "requestAccessPolicy": {
        "introspectionUrl": "https://TODO_WALLET_OWNER_AUTHORITY/v1/passkey/consume",
        "audience": "fearless-passkey-backup",
        "mode": "atomic-one-time-consume",
        "allPostRoutesProtected": true,
        "stableCrossPlatformWalletSubject": true,
        "authorizedSmokePassed": true,
        "noRawSubjectPersisted": true,
        "credentialLifecycleSmokePassed": true,
        "ownerTombstonePersistencePassed": true,
        "crossSubjectTakeoverDenied": true,
        "sameOwnerReregistrationPassed": true,
        "cloudDeleteRevokesServerFirst": true,
        "listExcludesVerificationMaterial": true
      },
      "trustedProxyPolicy": {
        "hops": 1,
        "forwardedHeader": "X-Forwarded-For",
        "directPeerAllowlistConfigured": true,
        "incomingHeaderSanitized": true,
        "directPublicAccessBlocked": true,
        "adversarialProxyTestsPassed": true
      },
      "platformProvisioning": {
        "androidGoogleDriveConsent": true,
        "androidReleaseFlagDisabled": true,
        "iosAssociatedDomain": true,
        "iosCloudKitProductionSchema": true,
        "iosReleaseFlagDisabled": true
      },
      "platformProvisioningAttestation": {
        "deploymentId": "TODO_PRODUCTION_DEPLOYMENT_ID",
        "deployedCommit": "TODO_40_HEX_GIT_COMMIT",
        "imageDigest": "sha256:TODO_64_HEX_IMAGE_DIGEST",
        "observedAt": "TODO_UTC_SMOKE_TIMESTAMP_SECONDS",
        "payloadSha256": "sha256:TODO_CANONICAL_PLATFORM_PROVISIONING_SHA256"
      }
    }
  ]
}
JSON
  printf '%s\n' "GET /api/passkey-backup/v1/health request to https://backup.fearlesswallet.io failed" > "$report_dir/passkey-production-smoke.log"
  printf '%s\n' "SORA Nexus Torii live health check failed for https://minamoto.sora.org/status" > "$report_dir/iroha-release-readiness.log"
  cat > "$report_dir/nexus-production-evidence-template.json" <<JSON
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
      "routeManifestCommit": "TODO_40_HEX_ROUTE_MANIFEST_COMMIT",
      "routeManifestSourcePath": "artifacts/nexus/production-route-governance-action.json",
      "routeManifestHash": "sha256:TODO_64_HEX_ROUTE_MANIFEST_HASH",
      "publicationTransactionHash": "0xTODO_64_HEX_PUBLICATION_TX_HASH",
      "publicationAuthority": "TODO_PUBLICATION_AUTHORITY",
      "publishedAt": "TODO_UTC_ROUTE_PUBLISHED_AT_RFC3339",
      "toriiBaseUrl": "https://minamoto.sora.org",
      "mcpUrl": "https://minamoto.sora.org/v1/mcp",
      "operator": "TODO_RELEASE_OPERATOR"
    }
  ],
  "routeCanaryEvidence": [
    {
      "publishedRouteManifestHash": "sha256:TODO_64_HEX_ROUTE_MANIFEST_HASH",
      "routeCanaryTransactionHash": "0xTODO_64_HEX_CANARY_TX_HASH",
      "authority": "TODO_CANARY_AUTHORITY",
      "sourceAccount": "TODO_NEXUS_CANARY_SOURCE_ACCOUNT",
      "destinationAccount": "TODO_NEXUS_CANARY_DESTINATION_ACCOUNT",
      "assetId": "xor#sora",
      "amount": "TODO_POSITIVE_DECIMAL_AMOUNT",
      "routeCanaryCheckedAt": "TODO_UTC_CANARY_CHECKED_WITHIN_24_HOURS_AT_RFC3339",
      "toriiBaseUrl": "https://minamoto.sora.org",
      "operator": "TODO_RELEASE_OPERATOR"
    }
  ],
  "walletSmokeEvidence": [
    {
      "platform": "android",
      "walletCommit": "TODO_40_HEX_ANDROID_WALLET_COMMIT",
      "routeManifestHash": "sha256:TODO_64_HEX_ROUTE_MANIFEST_HASH",
      "walletSmokeTransactionHash": "0xTODO_64_HEX_ANDROID_WALLET_SMOKE_TX_HASH",
      "sourceAccount": "TODO_NEXUS_ANDROID_SOURCE_ACCOUNT",
      "destinationAccount": "TODO_NEXUS_ANDROID_DESTINATION_ACCOUNT",
      "assetId": "xor#sora",
      "amount": "TODO_POSITIVE_DECIMAL_AMOUNT",
      "walletSmokeSubmittedAt": "TODO_UTC_ANDROID_WALLET_SMOKE_SUBMITTED_AT_RFC3339",
      "walletSmokeObservedAt": "TODO_UTC_ANDROID_WALLET_SMOKE_OBSERVED_WITHIN_24_HOURS_AT_RFC3339",
      "toriiBaseUrl": "https://minamoto.sora.org",
      "operator": "TODO_RELEASE_OPERATOR"
    },
    {
      "platform": "ios",
      "walletCommit": "TODO_40_HEX_IOS_WALLET_COMMIT",
      "routeManifestHash": "sha256:TODO_64_HEX_ROUTE_MANIFEST_HASH",
      "walletSmokeTransactionHash": "0xTODO_64_HEX_IOS_WALLET_SMOKE_TX_HASH",
      "sourceAccount": "TODO_NEXUS_IOS_SOURCE_ACCOUNT",
      "destinationAccount": "TODO_NEXUS_IOS_DESTINATION_ACCOUNT",
      "assetId": "xor#sora",
      "amount": "TODO_POSITIVE_DECIMAL_AMOUNT",
      "walletSmokeSubmittedAt": "TODO_UTC_IOS_WALLET_SMOKE_SUBMITTED_AT_RFC3339",
      "walletSmokeObservedAt": "TODO_UTC_IOS_WALLET_SMOKE_OBSERVED_WITHIN_24_HOURS_AT_RFC3339",
      "toriiBaseUrl": "https://minamoto.sora.org",
      "operator": "TODO_RELEASE_OPERATOR"
    },
    {
      "platform": "web",
      "walletCommit": "TODO_40_HEX_WEB_WALLET_COMMIT",
      "routeManifestHash": "sha256:TODO_64_HEX_ROUTE_MANIFEST_HASH",
      "walletSmokeTransactionHash": "0xTODO_64_HEX_WEB_WALLET_SMOKE_TX_HASH",
      "sourceAccount": "TODO_NEXUS_WEB_SOURCE_ACCOUNT",
      "destinationAccount": "TODO_NEXUS_WEB_DESTINATION_ACCOUNT",
      "assetId": "xor#sora",
      "amount": "TODO_POSITIVE_DECIMAL_AMOUNT",
      "walletSmokeSubmittedAt": "TODO_UTC_WEB_WALLET_SMOKE_SUBMITTED_AT_RFC3339",
      "walletSmokeObservedAt": "TODO_UTC_WEB_WALLET_SMOKE_OBSERVED_WITHIN_24_HOURS_AT_RFC3339",
      "toriiBaseUrl": "https://minamoto.sora.org",
      "operator": "TODO_RELEASE_OPERATOR"
    }
  ]
}
JSON
  printf '%s\n' "ready evidence cannot have discovery-only routes remaining" > "$report_dir/android-xcm-production-evidence.log"
  # Real Android generator export regression: every bundle fixture consumes the
  # production template schema instead of a hand-maintained synthetic copy.
  bash "$SCRIPT_DIR/../fearless-Android/scripts/generate-xcm-production-evidence-template.sh" \
    --required-route-file "$workspace_dir/fearless-Android/scripts/xcm-required-routes.tsv" \
    --output "$report_dir/android-xcm-production-evidence-template.json" >/dev/null
  cat > "$report_dir/android-xcm-registry-gap-report.json" <<JSON
{
  "schemaVersion": 1,
  "registryFile": "runtime/src/main/assets/local_chains.json",
  "summary": {
    "chains": 3,
    "xcmChains": 2,
    "destinations": 2,
    "routeAssets": 3,
    "executableDestinations": 1,
    "executableRouteAssets": 1,
    "remainingDiscoveryOnlyDestinations": 1,
    "remainingDiscoveryOnlyRouteAssets": 2
  },
  "missingExecutableDestinations": [
    {
      "originChainId": "origin-chain",
      "originName": "Origin",
      "destinationChainId": "destination-chain",
      "destinationName": "Destination",
      "assetSymbols": ["DOT", "USDT"],
      "bridgeParachainId": null,
      "reason": "missingExecutionSpec"
    }
  ]
}
JSON
  node - "$workspace_dir" "$report_dir/android-xcm-effective-registry-report.json" <<'NODE'
const crypto = require('crypto')
const fs = require('fs')
const path = require('path')
const [workspace, output] = process.argv.slice(2)
const identity = (source) => {
  const content = fs.readFileSync(path.join(workspace, 'fearless-Android', source))
  return { source, byteLength: content.length, sha256: crypto.createHash('sha256').update(content).digest('hex') }
}
const first = {
  originChainId: 'a'.repeat(64),
  destinationChainId: 'b'.repeat(64),
  assetSymbol: 'DOT',
}
const second = {
  originChainId: 'b'.repeat(64),
  destinationChainId: 'a'.repeat(64),
  assetSymbol: 'KSM',
}
const report = {
  schemaVersion: 1,
  mode: 'discovery',
  status: 'incomplete',
  policy: {
    transactionAuthority: 'apk-approved-intersection',
    effectiveRouteMeaning: 'compatible-approved-candidate',
    remoteExecutionTrusted: false,
    productionTransfersEnabled: false,
    unapprovedDiscoveryRoutesExecutable: false,
    runtimeDiscoveryRole: 'narrowing-advisory-only',
    runtimeDiscoveryStorage: 'current-process-successful-sync-snapshot',
    runtimeDiscoveryRequiresSuccessfulProcessSync: true,
    runtimeDiscoverySnapshotBoundToReport: false,
    runtimeDiscoveryFreshnessEnforced: false,
    releaseDiscoveryUrl: 'https://raw.githubusercontent.com/soramitsu/shared-features-utils/master/chains/v13/chains.json',
  },
  inputs: {
    approvedRoutes: identity('runtime/src/main/assets/approved_xcm_routes.tsv'),
    requiredRoutes: identity('scripts/xcm-required-routes.tsv'),
    bundledRegistry: identity('runtime/src/main/assets/local_chains.json'),
    discoveryRegistry: {
      kind: 'https',
      source: 'https://raw.githubusercontent.com/soramitsu/shared-features-utils/master/chains/v13/chains.json',
      byteLength: 303182,
      sha256: 'fa6f0e23cd87dfb3e5536980591dd22ae30e49bf59d04dc2a0b31fc53237ea66',
    },
  },
  summary: { approved: 2, required: 2, bundledExecutable: 2, discovered: 2, effective: 1, productionExecutable: 0, missing: 1, extra: 1 },
  routes: [
    { ...first, effective: true, productionExecutable: false, reasons: [] },
    { ...second, effective: false, productionExecutable: false, reasons: ['not-discovered'] },
  ],
  missing: [{ ...second, reasons: ['not-discovered'] }],
  extra: [{ originChainId: 'c'.repeat(64), destinationChainId: 'd'.repeat(64), assetSymbol: 'ROC' }],
}
fs.writeFileSync(output, `${JSON.stringify(report, null, 2)}\n`)
NODE
  printf '%s\n' "health serviceId must be ti.soramitsu.io" > "$report_dir/ti-production-smoke.log"
  printf '%s\n' "health serviceId must be si.soramitsu.io; received <missing>" > "$report_dir/si-production-smoke.log"
  cat > "$report_dir/ti-deployment-evidence-template.json" <<JSON
{
  "schemaVersion": 1,
  "scope": "ton-indexer-production-deployment-readiness",
  "serviceId": "ti.soramitsu.io",
  "baseUrl": "https://ti.soramitsu.io",
  "status": "ready",
  "releaseEnabled": true,
  "lastReviewed": "TODO_YYYY_MM_DD",
  "blockers": [],
  "smokeCommand": "TON_INDEXER_BASE_URL=https://ti.soramitsu.io npm run smoke:production",
  "dockerBuildCommand": "docker build -t ton-indexer:release .",
  "readyVerificationCommands": [
    "npm run test:deployment-evidence-template",
    "npm run generate:deployment-evidence-template -- --output build/reports/production-deployment-evidence-template.json",
    "npm run test:deployment-evidence-audit",
    "npm run audit:deployment-evidence -- --require-ready",
    "docker build -t ton-indexer:release .",
    "TON_INDEXER_BASE_URL=https://ti.soramitsu.io npm run smoke:production"
  ],
  "requiredEvidenceFields": [
    "commit",
    "imageDigest",
    "deploymentId",
    "baseUrl",
    "smokeCommand",
    "deployedAt",
    "smokePassedAt",
    "serviceInfo",
    "healthInfo",
    "operator"
  ],
  "deploymentEvidence": [
    {
      "commit": "TODO_40_HEX_GIT_COMMIT",
      "imageDigest": "sha256:TODO_64_HEX_IMAGE_DIGEST",
      "deploymentId": "TODO_PRODUCTION_DEPLOYMENT_ID",
      "baseUrl": "https://ti.soramitsu.io",
      "smokeCommand": "TON_INDEXER_BASE_URL=https://ti.soramitsu.io npm run smoke:production",
      "deployedAt": "TODO_UTC_DEPLOYED_AT_SECONDS",
      "smokePassedAt": "TODO_UTC_SMOKE_TIMESTAMP_SECONDS",
      "serviceInfo": {
        "schemaVersion": 1,
        "serviceId": "ti.soramitsu.io",
        "ecosystem": "ton",
        "chainId": "ton:mainnet",
        "network": "mainnet",
        "publicBaseUrl": "https://ti.soramitsu.io",
        "readOnly": true,
        "endpoints": {
          "openapi": "/api/indexer/v1/openapi.json"
        }
      },
      "healthInfo": {
        "serviceId": "ti.soramitsu.io",
        "ecosystem": "ton",
        "chainId": "ton:mainnet",
        "network": "mainnet",
        "lastMasterSeqno": "TODO_LAST_MASTER_SEQNO"
      },
      "operator": "TODO_RELEASE_OPERATOR"
    }
  ]
}
JSON
  cat > "$report_dir/si-deployment-evidence-template.json" <<JSON
{
  "schemaVersion": 1,
  "scope": "solswap-indexer-production-deployment-readiness",
  "serviceId": "si.soramitsu.io",
  "baseUrl": "https://si.soramitsu.io",
  "status": "ready",
  "releaseEnabled": true,
  "lastReviewed": "TODO_YYYY_MM_DD",
  "blockers": [],
  "smokeCommand": "SOLSWAP_INDEXER_BASE_URL=https://si.soramitsu.io npm run smoke:production",
  "dockerBuildCommand": "docker build -t solswap-indexer:release .",
  "readyVerificationCommands": [
    "npm run test:deployment-evidence-template",
    "npm run generate:deployment-evidence-template -- --output build/reports/production-deployment-evidence-template.json",
    "npm run test:deployment-evidence-audit",
    "npm run audit:deployment-evidence -- --require-ready",
    "docker build -t solswap-indexer:release .",
    "SOLSWAP_INDEXER_BASE_URL=https://si.soramitsu.io npm run smoke:production"
  ],
  "requiredEvidenceFields": [
    "commit",
    "imageDigest",
    "deploymentId",
    "baseUrl",
    "smokeCommand",
    "deployedAt",
    "smokePassedAt",
    "serviceInfo",
    "healthInfo",
    "operator"
  ],
  "deploymentEvidence": [
    {
      "commit": "TODO_40_HEX_GIT_COMMIT",
      "imageDigest": "sha256:TODO_64_HEX_IMAGE_DIGEST",
      "deploymentId": "TODO_PRODUCTION_DEPLOYMENT_ID",
      "baseUrl": "https://si.soramitsu.io",
      "smokeCommand": "SOLSWAP_INDEXER_BASE_URL=https://si.soramitsu.io npm run smoke:production",
      "deployedAt": "TODO_UTC_DEPLOYED_AT_SECONDS",
      "smokePassedAt": "TODO_UTC_SMOKE_TIMESTAMP_SECONDS",
      "serviceInfo": {
        "schemaVersion": 1,
        "serviceId": "si.soramitsu.io",
        "ecosystem": "solana",
        "chainId": "solana:mainnet",
        "network": "mainnet",
        "publicBaseUrl": "https://si.soramitsu.io",
        "readOnly": true,
        "endpoints": {
          "openapi": "/api/indexer/v1/openapi.json"
        }
      },
      "healthInfo": {
        "ok": true,
        "serviceId": "si.soramitsu.io",
        "ecosystem": "solana",
        "chainId": "solana:mainnet",
        "network": "mainnet",
        "genesisHash": "5eykt4UsFv8P8NJdTREpY1vzqKqZKvdpKuc147dw2N9d",
        "latestSlot": "TODO_POSITIVE_LATEST_SLOT",
        "syncedAt": "TODO_UNIX_TIMESTAMP_SECONDS"
      },
      "operator": "TODO_RELEASE_OPERATOR"
    }
  ]
}
JSON
  printf '%s\n' "Production deployment evidence is not release-ready" > "$report_dir/pi-deployment-evidence.log"
  cat > "$report_dir/pi-deployment-evidence-template.json" <<JSON
{
  "schemaVersion": 1,
  "scope": "polkaswap-indexer-production-deployment-readiness",
  "serviceId": "pi.soramitsu.io",
  "baseUrl": "https://pi.soramitsu.io/graphql",
  "status": "blocked",
  "releaseEnabled": false,
  "lastReviewed": "2026-06-28",
  "blockers": [
    "production-deployment-evidence-missing",
    "live-production-smoke-failing"
  ],
  "smokeCommand": "POLKASWAP_INDEXER_BASE_URL=https://pi.soramitsu.io/graphql yarn smoke:production",
  "dockerBuildCommand": "docker build -t polkaswap-indexer:release .",
  "readyVerificationCommands": [
    "yarn test:deployment-evidence-template",
    "yarn generate:deployment-evidence-template --output build/reports/production-deployment-evidence-template.json",
    "yarn test:deployment-evidence-audit",
    "yarn audit:deployment-evidence --require-ready",
    "docker build -t polkaswap-indexer:release .",
    "POLKASWAP_INDEXER_BASE_URL=https://pi.soramitsu.io/graphql yarn smoke:production"
  ],
  "requiredEvidenceFields": [
    "commit",
    "imageDigest",
    "deploymentId",
    "baseUrl",
    "smokeCommand",
    "deployedAt",
    "smokePassedAt",
    "healthInfo",
    "soraRpcControls",
    "tlsEdgeControls",
    "operator"
  ],
  "deploymentEvidence": [
    {
      "commit": "TODO_40_HEX_GIT_COMMIT",
      "imageDigest": "sha256:TODO_64_HEX_IMAGE_DIGEST",
      "deploymentId": "TODO_PRODUCTION_DEPLOYMENT_ID",
      "baseUrl": "https://pi.soramitsu.io/graphql",
      "smokeCommand": "POLKASWAP_INDEXER_BASE_URL=https://pi.soramitsu.io/graphql yarn smoke:production",
      "deployedAt": "TODO_UTC_DEPLOYED_AT_SECONDS",
      "smokePassedAt": "TODO_UTC_SMOKE_TIMESTAMP_SECONDS",
      "healthInfo": {
        "ok": true,
        "service": "polkaswap-indexer",
        "serviceId": "pi.soramitsu.io",
        "schemaVersion": 1,
        "ecosystem": "sora2",
        "chainId": "sora:mainnet",
        "network": "mainnet",
        "publicBaseUrl": "https://pi.soramitsu.io/graphql",
        "readOnly": true,
        "genesisHash": "0x7e4e32d0feafd4f9c9414b0be86373f9a1efa904809b683453a9af6856d38ad5",
        "latestIndexedBlock": "TODO_POSITIVE_SAFE_INTEGER_INDEXED_BLOCK",
        "latestIndexedBlockHash": "TODO_0X_64_LOWERCASE_HEX_INDEXED_BLOCK_HASH",
        "latestIndexedAt": "TODO_UNIX_SECONDS_WITHIN_300_BEFORE_OR_30_AFTER_SMOKE"
      },
      "soraRpcControls": {
        "primaryEndpoint": "TODO_CANONICAL_WSS_LOCALLY_CONTROLLED_PRIMARY_RPC_ENDPOINT",
        "archiveEndpoint": "TODO_CANONICAL_WSS_INDEPENDENT_ARCHIVE_RPC_ENDPOINT",
        "primaryNodeControl": "locally-controlled-verifying-archive",
        "archiveNodeControl": "independently-operated-verifying-archive",
        "distinctHosts": true,
        "exactIdentityPreflight": true,
        "rawPayloadAgreement": "height-hash-scale-block-events-timestamp"
      },
      "tlsEdgeControls": {
        "tlsTermination": true,
        "forwardedClientIpHeaders": "overwrite",
        "httpClientIpRateLimit": {
          "windowMs": 60000,
          "maxRequests": 600
        },
        "webSocketClientIpLimits": {
          "windowMs": 60000,
          "maxUpgrades": 600,
          "maxConcurrentConnections": 16
        }
      },
      "operator": "TODO_RELEASE_OPERATOR"
    }
  ]
}
JSON
  printf '%s\n' "PI production GraphQL schema is missing _health identity fields" > "$report_dir/pi-production-smoke.log"
  printf '%s\n' "plan readiness log" > "$report_dir/plan-readiness.log"
  printf '%s\n' "GitHub governance log" > "$report_dir/github-governance.log"
  printf '%s\n' "private overlay log" > "$report_dir/private-overlay-readiness.log"
  printf '%s\n' "Android public dependency log" > "$report_dir/android-public-dependency-provenance.log"
  printf '%s\n' "iOS shared features log" > "$report_dir/ios-shared-features-delta.log"
  printf '%s\n' "passkey service log" > "$report_dir/passkey-challenge-service.log"
  printf '%s\n' "passkey backup prerequisite log" > "$report_dir/passkey-backup-prerequisites.log"
  printf '%s\n' "Iroha wallet coverage log" > "$report_dir/iroha-wallet-coverage.log"
  printf '%s\n' "TI deployment evidence log" > "$report_dir/ti-deployment-evidence.log"
  printf '%s\n' "SI deployment evidence log" > "$report_dir/si-deployment-evidence.log"
  printf '%s\n' "source publication readiness passed" > "$report_dir/source-publication-readiness.log"
  cat > "$workspace_dir/config/source-publication-readiness.tsv" <<'TSV'
# path	repository	head	base	pull_request
fearless-Android-production-consolidated-20260731	soramitsu/fearless-Android	codex/android-production-consolidated-20260731	develop	1260
fearless-iOS-production-consolidated-20260731	soramitsu/fearless-iOS	codex/testflight-redesign-2026.8.17	develop	1304
fearless-wallet-web	soramitsu/fearless-wallet-web	codex/web-bitcoin-canonical-indexer-evidence	develop	1062
fearless-site-web	soramitsu/fearless-site-web	codex/site-todo-debt-baseline-hardening	develop	45
../ton-indexer	tonswap-org/ton-indexer	codex/ti-smoke-body-preview-tests	develop	13
../solswap-indexer	solswap-io/solswap-indexer	codex/si-smoke-body-preview-tests	develop	16
../polkaswap-indexer	sora-xor/polkaswap-indexer	codex/pi-deployment-evidence-gate	develop	1
../iroha	hyperledger-iroha/iroha	codex/kagemusha-selector-hardening	optimizations	5612
TSV
  cat > "$workspace_dir/config/source-publication-root-owner.json" <<'JSON'
{
  "schemaVersion": 1,
  "status": "ready",
  "repository": "soramitsu/fearless-wallet-web",
  "head": "codex/web-bitcoin-broadcast-evidence",
  "base": "develop",
  "prNumber": 1061,
  "lastReviewed": "2026-06-28",
  "blocker": null
}
JSON
  node - "$workspace_dir" "$report_dir/source-publication-preflight-report.json" "$report_dir/source-publication-readiness-report.json" <<'NODE'
const crypto = require('crypto')
const fs = require('fs')
const path = require('path')
const [workspace, preflightOutput, output] = process.argv.slice(2)
const sha = 'a'.repeat(40)
const configured = [
  ['fearless-Android-production-consolidated-20260731', 'soramitsu/fearless-Android', 'codex/android-production-consolidated-20260731', 'develop', 1260],
  ['fearless-iOS-production-consolidated-20260731', 'soramitsu/fearless-iOS', 'codex/testflight-redesign-2026.8.17', 'develop', 1304],
  ['fearless-wallet-web', 'soramitsu/fearless-wallet-web', 'codex/web-bitcoin-canonical-indexer-evidence', 'develop', 1062],
  ['fearless-site-web', 'soramitsu/fearless-site-web', 'codex/site-todo-debt-baseline-hardening', 'develop', 45],
  ['../ton-indexer', 'tonswap-org/ton-indexer', 'codex/ti-smoke-body-preview-tests', 'develop', 13],
  ['../solswap-indexer', 'solswap-io/solswap-indexer', 'codex/si-smoke-body-preview-tests', 'develop', 16],
  ['../polkaswap-indexer', 'sora-xor/polkaswap-indexer', 'codex/pi-deployment-evidence-gate', 'develop', 1],
  ['../iroha', 'hyperledger-iroha/iroha', 'codex/kagemusha-selector-hardening', 'optimizations', 5612],
]
function source(sourcePath, repository, head, base, prNumber) {
  return {
    path: sourcePath, repository, head, base, prNumber,
    prUrl: `https://github.com/${repository}/pull/${prNumber}`, prState: 'merged', prHeadSha: sha,
    repositoryPath: path.resolve(workspace, sourcePath), status: 'passed',
    originUrl: `https://github.com/${repository}.git`, originRepository: repository, branch: head,
    headSha: sha, upstream: `origin/${head}`, upstreamSha: sha, remoteHeadSha: sha,
    remoteBranchPresent: true, currentBranchRemoteSha: sha, currentBranchRemotePresent: true,
    stagedCount: 0, unstagedCount: 0, untrackedCount: 0, unmergedCount: 0,
    dirtyPaths: [], requiredTrackedFiles: [], failures: [],
  }
}
const workspaceSource = source('.', 'soramitsu/fearless-wallet-web', 'codex/web-bitcoin-broadcast-evidence', 'develop', 1061)
workspaceSource.repositoryPath = workspace
workspaceSource.requiredTrackedFiles = [
  '.github/CODEOWNERS',
  '.github/workflows/readiness.yml',
  '.gitignore',
  'FEARLESS_PROJECT_PLAN.md',
  'README.md',
  'config/release-readiness-prs.tsv',
  'config/source-publication-root-owner.json',
  'config/source-publication-readiness.tsv',
  'docs/source-freeze-20260801.md',
  'scripts/audit-release-readiness.sh',
  'scripts/audit-source-publication-readiness.mjs',
  'scripts/capture-source-freeze.mjs',
  'scripts/export-release-unblock-bundle.sh',
  'scripts/quarantine-source-publication-outputs.mjs',
  'scripts/run-pinned-yarn.sh',
  'scripts/run-source-publication-quarantine.sh',
  'scripts/run-source-publication-readiness.sh',
  'scripts/test-pinned-yarn-runner.sh',
  'scripts/test-source-publication-quarantine.sh',
  'scripts/test-source-publication-readiness-audit.sh',
  'scripts/verify-release-unblock-bundle.sh',
  'services/passkey-backup-challenge-service/Dockerfile',
  'services/passkey-backup-challenge-service/package-lock.json',
  'services/passkey-backup-challenge-service/package.json',
  'services/passkey-backup-challenge-service/src/server.js',
]
const report = {
  schemaVersion: 3, phase: 'preflight', preflightReportSha256: null,
  generatedAt: '2026-06-28T00:00:00.000Z', status: 'passed', checkRemote: true,
  workspaceRoot: workspace, workspaceParent: path.dirname(workspace),
  configFile: path.join(workspace, 'config/source-publication-readiness.tsv'),
  rootOwnerConfigFile: path.join(workspace, 'config/source-publication-root-owner.json'),
  releasePrConfigFile: path.join(workspace, 'config/release-readiness-prs.tsv'),
  totals: {sources: 9, passed: 9, failed: 0, staged: 0, unstaged: 0, untracked: 0, unmerged: 0},
  workspaceSource,
  repositories: configured.map((row) => source(...row)),
}
const preflightBytes = Buffer.from(`${JSON.stringify(report, null, 2)}\n`)
fs.writeFileSync(preflightOutput, preflightBytes)
report.phase = 'postflight'
report.preflightReportSha256 = crypto.createHash('sha256').update(preflightBytes).digest('hex')
fs.writeFileSync(output, `${JSON.stringify(report, null, 2)}\n`)
NODE
}

run_export() {
  RELEASE_UNBLOCK_ROOT="$workspace_dir" bash "$EXPORT_SCRIPT" --report-dir "$report_dir" --output "$bundle_dir"
}

run_export_to() {
  local output_dir="$1"
  RELEASE_UNBLOCK_ROOT="$workspace_dir" bash "$EXPORT_SCRIPT" --report-dir "$report_dir" --output "$output_dir"
}

run_export_from() {
  local source_report_dir="$1"
  RELEASE_UNBLOCK_ROOT="$workspace_dir" bash "$EXPORT_SCRIPT" --report-dir "$source_report_dir" --output "$bundle_dir"
}

run_export_at_time() {
  RELEASE_UNBLOCK_EXPORT_NOW="$1" run_export
}

expect_success() {
  local name="$1"
  local output
  if ! output="$(run_export 2>&1)"; then
    echo "$output" >&2
    fail "$name unexpectedly failed"
  fi
}

expect_failure() {
  local name="$1"
  local expected="$2"
  local output
  set +e
  output="$(run_export 2>&1)"
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
}

edit_source_publication_report() {
  local script="$1"
  node - "$report_dir/source-publication-readiness-report.json" "$script" <<'NODE'
const fs = require('fs')
const file = process.argv[2]
const script = process.argv[3]
const data = JSON.parse(fs.readFileSync(file, 'utf8'))
Function('data', script)(data)
fs.writeFileSync(file, JSON.stringify(data, null, 2) + '\n')
NODE
}

edit_source_publication_preflight_report() {
  local script="$1"
  node - "$report_dir/source-publication-preflight-report.json" "$script" <<'NODE'
const fs = require('fs')
const file = process.argv[2]
const script = process.argv[3]
const data = JSON.parse(fs.readFileSync(file, 'utf8'))
Function('data', script)(data)
fs.writeFileSync(file, JSON.stringify(data, null, 2) + '\n')
NODE
}

rebind_source_publication_postflight() {
  node - "$report_dir/source-publication-preflight-report.json" "$report_dir/source-publication-readiness-report.json" <<'NODE'
const crypto = require('crypto')
const fs = require('fs')
const [preflightFile, postflightFile] = process.argv.slice(2)
const preflightBytes = fs.readFileSync(preflightFile)
const postflight = JSON.parse(fs.readFileSync(postflightFile, 'utf8'))
postflight.preflightReportSha256 = crypto.createHash('sha256').update(preflightBytes).digest('hex')
fs.writeFileSync(postflightFile, JSON.stringify(postflight, null, 2) + '\n')
NODE
}

set_reviewed_source_authoritative_current_drift_fixture() {
  node - "$report_dir/source-publication-readiness-report.json" <<'NODE'
const fs = require('fs')
const file = process.argv[2]
const data = JSON.parse(fs.readFileSync(file, 'utf8'))
const iroha = data.repositories.find((row) => row.path === '../iroha')
if (!iroha) throw new Error('Iroha source-publication fixture missing')
const hasContinuity = iroha.failures.includes('source publication preflight did not pass before release checks')
iroha.currentBranchRemotePresent = true
iroha.currentBranchRemoteSha = '095afec25e64fdcf1d619c23a7e3b0a3906e7e8c'
for (const key of ['stagedCount', 'unstagedCount', 'untrackedCount', 'unmergedCount']) iroha[key] = 0
iroha.failures = [
  iroha.failures[0],
  `current branch mismatch: expected ${iroha.head}, received ${iroha.branch}`,
  `local HEAD ${iroha.headSha} does not match authoritative current branch ${iroha.branch} at ${iroha.currentBranchRemoteSha}`,
  `local HEAD ${iroha.headSha} does not match pull request head ${iroha.prHeadSha}`,
  `upstream mismatch: expected origin/${iroha.head}, received ${iroha.upstream}`,
  `cached upstream ${iroha.upstream} at ${iroha.upstreamSha} does not match authoritative current branch ${iroha.branch} at ${iroha.currentBranchRemoteSha}`,
  ...(hasContinuity ? ['source publication preflight did not pass before release checks'] : []),
]
fs.writeFileSync(file, JSON.stringify(data, null, 2) + '\n')
NODE
}

edit_actions_report() {
  local script="$1"
  node - "$report_dir/actions.json" "$script" <<'NODE'
const fs = require('fs')
const file = process.argv[2]
const script = process.argv[3]
const data = JSON.parse(fs.readFileSync(file, 'utf8'))
Function('data', script)(data)
fs.writeFileSync(file, JSON.stringify(data, null, 2) + '\n')
NODE
}

edit_xcm_effective_report() {
  local script="$1"
  node - "$report_dir/android-xcm-effective-registry-report.json" "$script" <<'NODE'
const fs = require('fs')
const file = process.argv[2]
const script = process.argv[3]
const data = JSON.parse(fs.readFileSync(file, 'utf8'))
Function('data', script)(data)
fs.writeFileSync(file, JSON.stringify(data, null, 2) + '\n')
NODE
}

edit_xcm_production_evidence_template() {
  local script="$1"
  node - "$report_dir/android-xcm-production-evidence-template.json" "$script" <<'NODE'
const fs = require('fs')
const file = process.argv[2]
const script = process.argv[3]
const data = JSON.parse(fs.readFileSync(file, 'utf8'))
Function('data', script)(data)
fs.writeFileSync(file, JSON.stringify(data, null, 2) + '\n')
NODE
}

set_fixture_run_live_false() {
  node - "$report_dir/summary.json" "$report_dir/actions.json" <<'NODE'
const fs = require('fs')
for (const file of process.argv.slice(2)) {
  const data = JSON.parse(fs.readFileSync(file, 'utf8'))
  data.runLive = false
  fs.writeFileSync(file, JSON.stringify(data, null, 2) + '\n')
}
NODE
  perl -0pi -e 's/Run live checks: true/Run live checks: false/' "$report_dir/blockers.md"
}

expect_failure_at_time() {
  local name="$1"
  local now="$2"
  local expected="$3"
  local output
  set +e
  output="$(run_export_at_time "$now" 2>&1)"
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
}

expect_failure_with_export_script() {
  local name="$1"
  local export_script="$2"
  local expected="$3"
  local output
  set +e
  output="$(RELEASE_UNBLOCK_ROOT="$workspace_dir" bash "$export_script" --report-dir "$report_dir" --output "$bundle_dir" 2>&1)"
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
}

expect_success_with_export_script() {
  local name="$1"
  local export_script="$2"
  local output
  if ! output="$(RELEASE_UNBLOCK_ROOT="$workspace_dir" bash "$export_script" --report-dir "$report_dir" --output "$bundle_dir" 2>&1)"; then
    echo "$output" >&2
    fail "$name unexpectedly failed"
  fi
}

expect_failure_to() {
  local name="$1"
  local output_dir="$2"
  local expected="$3"
  local output
  set +e
  output="$(run_export_to "$output_dir" 2>&1)"
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
}

expect_failure_from() {
  local name="$1"
  local source_report_dir="$2"
  local expected="$3"
  local output
  set +e
  output="$(run_export_from "$source_report_dir" 2>&1)"
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
}

assert_no_bundle_temp_dirs() {
  local leaked
  leaked="$(find "$tmp_dir" -maxdepth 1 \( -name '.bundle.staging-*' -o -name '.bundle.previous-*' \) -print)"
  if [[ -n "$leaked" ]]; then
    echo "$leaked" >&2
    fail "exporter leaked a staging or backup directory"
  fi
}

rewrite_blocker_markdown_from_manifests() {
  node - "$report_dir/summary.json" "$report_dir/actions.json" "$report_dir/blockers.md" <<'NODE'
const fs = require('fs')
const [summaryFile, actionsFile, blockersFile] = process.argv.slice(2)
const summary = JSON.parse(fs.readFileSync(summaryFile, 'utf8'))
const actions = JSON.parse(fs.readFileSync(actionsFile, 'utf8'))

function fenceFor(content) {
  const runs = String(content).match(/`+/g) || []
  const maxRun = runs.reduce((max, run) => Math.max(max, run.length), 0)
  return '`'.repeat(Math.max(3, maxRun + 1))
}

const lines = [
  '# Release Readiness Blockers',
  '',
  `- Generated at: ${summary.generatedAt}`,
  `- Run live checks: ${summary.runLive}`,
  `- Totals: ${summary.totals.passed} passed, ${summary.totals.failed} failed, ${summary.totals.skipped} skipped, ${summary.totals.total} total`,
  '',
  '## Failed Checks',
  '',
]
for (const blocker of actions.blockers) {
  lines.push(`### ${blocker.name}`)
  lines.push('')
  lines.push(`- Slug: \`${blocker.slug}\``)
  lines.push(`- Exit code: \`${blocker.exitCode}\``)
  lines.push(`- Log: \`${blocker.logFile}\``)
  lines.push(`- Recommended action: ${blocker.recommendedAction}`)
  lines.push(`- Requires external action: \`${blocker.requiresExternalAction}\``)
  lines.push(`- Unblock category: \`${blocker.unblockCategory}\``)
  lines.push(`- External prerequisite: ${blocker.externalPrerequisite}`)
  lines.push(`- Verification command: \`${blocker.verificationCommand}\``)
  lines.push('', 'Evidence preview:', '')
  const fence = fenceFor(blocker.evidencePreview)
  lines.push(`${fence}text`, blocker.evidencePreview, fence, '')
}
fs.writeFileSync(blockersFile, `${lines.join('\n')}\n`)
NODE
}

set_plan_readiness_blocker_fixture() {
  local variant="$1"
  node - "$report_dir/summary.json" "$report_dir/actions.json" "$report_dir/plan-readiness.log" "$report_dir/source-publication-preflight-report.json" "$report_dir/source-publication-readiness-report.json" "$report_dir/source-publication-readiness.log" "$variant" <<'NODE'
const crypto = require('crypto')
const fs = require('fs')
const [summaryFile, actionsFile, logFile, preflightReportFile, sourceReportFile, sourceLogFile, variant] = process.argv.slice(2)
const summary = JSON.parse(fs.readFileSync(summaryFile, 'utf8'))
const actions = JSON.parse(fs.readFileSync(actionsFile, 'utf8'))
const contracts = {
  local: {
    recommendedAction: 'Fix the static plan-readiness drift in the referenced repos/scripts, then rerun bash scripts/audit-plan-readiness.sh.',
    requiresExternalAction: false,
    unblockCategory: 'local-code',
    externalPrerequisite: 'No external prerequisite is expected; fix the local failing release gate.',
    failure: '  - fearless-iOS maintained source contract missing',
  },
  external: {
    recommendedAction: 'Do not edit or publish from the unsafe external ../iroha checkout. Have its owner resolve any in-progress Git operation or unmerged index state and restore every reported Iroha source and browser-artifact contract on a stable reviewed commit, then rerun bash scripts/audit-plan-readiness.sh.',
    requiresExternalAction: true,
    unblockCategory: 'upstream-dependency',
    externalPrerequisite: 'Owner-coordinated resolution of the unsafe external ../iroha source state, followed by a stable reviewed checkout containing every audited Iroha source and browser-artifact contract.',
    failure: '  - ../iroha unsafe external source contract missing',
  },
}
const contract = contracts[variant === 'external-reviewed-source' ? 'external' : variant]
if (!contract) throw new Error(`unsupported plan fixture variant: ${variant}`)
const marker = '[plan-readiness][error] Plan readiness audit failed:'
const check = summary.checks.find((item) => item.slug === 'plan-readiness')
if (!check || check.status !== 'passed') throw new Error('plan-readiness fixture must start passed')
Object.assign(check, {
  status: 'failed',
  exitCode: 1,
  logFile: 'plan-readiness.log',
  recommendedAction: contract.recommendedAction,
  requiresExternalAction: contract.requiresExternalAction,
  unblockCategory: contract.unblockCategory,
  externalPrerequisite: contract.externalPrerequisite,
  verificationCommand: 'bash scripts/audit-plan-readiness.sh',
})
const blocker = {
  name: check.name,
  slug: check.slug,
  exitCode: check.exitCode,
  logFile: check.logFile,
  recommendedAction: check.recommendedAction,
  requiresExternalAction: check.requiresExternalAction,
  unblockCategory: check.unblockCategory,
  externalPrerequisite: check.externalPrerequisite,
  verificationCommand: check.verificationCommand,
  evidencePreview: marker,
}
actions.blockers.unshift(blocker)
for (const manifest of [summary, actions]) {
  manifest.totals.passed -= 1
  manifest.totals.failed += 1
}
if (variant === 'external' || variant === 'external-reviewed-source') {
  const operationFailure = 'repository has an in-progress Git merge operation (MERGE_HEAD); only the repository owner may complete or abort it before source publication'
  const sourceReport = JSON.parse(fs.readFileSync(sourceReportFile, 'utf8'))
  const iroha = sourceReport.repositories.find((row) => row.path === '../iroha')
  if (!iroha) throw new Error('Iroha source-publication fixture missing')
  iroha.status = 'failed'
  if (variant === 'external-reviewed-source') {
    const liveHeadSha = 'e56af586b6d047c361e531d330424fb3067f57b2'
    const mergedPrHeadSha = 'e7a9e27691d6f34e2737d946af9b7f0768a31136'
    iroha.branch = 'optimizations'
    iroha.upstream = 'origin/optimizations'
    iroha.headSha = liveHeadSha
    iroha.upstreamSha = liveHeadSha
    iroha.prHeadSha = mergedPrHeadSha
    iroha.remoteBranchPresent = false
    iroha.remoteHeadSha = null
    iroha.currentBranchRemotePresent = true
    iroha.currentBranchRemoteSha = liveHeadSha
    iroha.dirtyPaths = ['.cache/', '.codex-target/', '.playwright-cli/', '.pytest_cache/', 'Cargo.lock', 'IrohaSwift/.build/', 'artifacts/js-sdk-bundle-size/', 'artifacts/python_fixture_regen_state.json']
    iroha.failures = [
      'worktree contains ignored non-published paths (154): .cache/, .codex-target/, .playwright-cli/, .pytest_cache/, Cargo.lock, IrohaSwift/.build/, artifacts/js-sdk-bundle-size/, artifacts/python_fixture_regen_state.json; remove or quarantine these ignored outputs outside the source tree before publication; do not force-add generated artifacts',
      `current branch mismatch: expected ${iroha.head}, received ${iroha.branch}`,
      `local HEAD ${iroha.headSha} does not match pull request head ${iroha.prHeadSha}`,
      `upstream mismatch: expected origin/${iroha.head}, received ${iroha.upstream}`,
    ]
  } else {
    iroha.stagedCount = 1
    iroha.dirtyPaths = ['crates/iroha_torii/src/offline_v2_issuer.rs']
    iroha.failures = [operationFailure]
  }
  sourceReport.status = 'failed'
  sourceReport.totals.passed -= 1
  sourceReport.totals.failed += 1
  if (variant === 'external') sourceReport.totals.staged += 1
  if (variant === 'external-reviewed-source') {
    const preflightReport = JSON.parse(fs.readFileSync(preflightReportFile, 'utf8'))
    const preflightIndex = preflightReport.repositories.findIndex((row) => row.path === '../iroha')
    if (preflightIndex < 0) throw new Error('Iroha preflight source-publication fixture missing')
    preflightReport.repositories[preflightIndex] = JSON.parse(JSON.stringify(iroha))
    preflightReport.status = 'failed'
    preflightReport.totals.passed -= 1
    preflightReport.totals.failed += 1
    fs.writeFileSync(preflightReportFile, `${JSON.stringify(preflightReport, null, 2)}\n`)
    const preflightBytes = fs.readFileSync(preflightReportFile)
    sourceReport.preflightReportSha256 = crypto.createHash('sha256').update(preflightBytes).digest('hex')
    iroha.failures.push('source publication preflight did not pass before release checks')
  }
  const sourceCheck = summary.checks.find((item) => item.slug === 'source-publication-readiness')
  if (!sourceCheck || sourceCheck.status !== 'passed') throw new Error('source-publication fixture must start passed')
  const sourceEvidence = '[source-publication-readiness][error] Source publication readiness failed:'
  Object.assign(sourceCheck, {
    status: 'failed',
    exitCode: 1,
    logFile: 'source-publication-readiness.log',
    recommendedAction: "Do not commit or publish from a checkout with an in-progress merge, rebase, cherry-pick, revert, bisect, or sequencer operation or unresolved index stages; have that checkout's owner resolve the state first. Remove or quarantine every ignored non-published build output reported by the audit, then commit only reviewed tested changes. Assign the root release tooling and passkey challenge service to a canonical maintained GitHub repository, add its protected release PR to config/release-readiness-prs.tsv, and push exact topic-branch HEADs. Then rerun the full bash scripts/audit-release-readiness.sh flow so the remote-checked source preflight is captured before all release checks and matched by postflight.",
    requiresExternalAction: true,
    unblockCategory: 'source-publication',
    externalPrerequisite: 'Owner-resolved completion of every in-progress Git operation or unmerged index state, removal or quarantine of ignored non-published build outputs, canonical Git ownership for the root release/passkey source, plus reviewed commits, pushes, and protected pull requests for the exact tested HEAD of every source tree.',
    verificationCommand: 'bash scripts/audit-release-readiness.sh',
  })
  actions.blockers.push({
    name: sourceCheck.name,
    slug: sourceCheck.slug,
    exitCode: sourceCheck.exitCode,
    logFile: sourceCheck.logFile,
    recommendedAction: sourceCheck.recommendedAction,
    requiresExternalAction: sourceCheck.requiresExternalAction,
    unblockCategory: sourceCheck.unblockCategory,
    externalPrerequisite: sourceCheck.externalPrerequisite,
    verificationCommand: sourceCheck.verificationCommand,
    evidencePreview: sourceEvidence,
  })
  for (const manifest of [summary, actions]) {
    manifest.totals.passed -= 1
    manifest.totals.failed += 1
  }
  fs.writeFileSync(sourceReportFile, `${JSON.stringify(sourceReport, null, 2)}\n`)
  fs.writeFileSync(
    sourceLogFile,
    `${sourceEvidence}\n${iroha.failures.map((failure) => `  - ../iroha: ${failure}`).join('\n')}\n`,
  )
}
fs.writeFileSync(logFile, `${marker}\n${contract.failure}\n`)
fs.writeFileSync(summaryFile, `${JSON.stringify(summary, null, 2)}\n`)
fs.writeFileSync(actionsFile, `${JSON.stringify(actions, null, 2)}\n`)
NODE
  rewrite_blocker_markdown_from_manifests
}

edit_plan_blocker_contract() {
  local edit_script="$1"
  node - "$report_dir/summary.json" "$report_dir/actions.json" "$edit_script" <<'NODE'
const fs = require('fs')
const [summaryFile, actionsFile, editScript] = process.argv.slice(2)
const summary = JSON.parse(fs.readFileSync(summaryFile, 'utf8'))
const actions = JSON.parse(fs.readFileSync(actionsFile, 'utf8'))
const check = summary.checks.find((item) => item.slug === 'plan-readiness')
const blocker = actions.blockers.find((item) => item.slug === 'plan-readiness')
if (!check || !blocker) throw new Error('plan-readiness blocker fixture missing')
for (const contract of [check, blocker]) Function('contract', editScript)(contract)
fs.writeFileSync(summaryFile, `${JSON.stringify(summary, null, 2)}\n`)
fs.writeFileSync(actionsFile, `${JSON.stringify(actions, null, 2)}\n`)
NODE
  rewrite_blocker_markdown_from_manifests
}

set_plan_readiness_log_classification() {
  local variant="$1"
  local failure
  case "$variant" in
    external)
      failure='  - ../iroha unsafe external source contract missing'
      ;;
    local)
      failure='  - fearless-iOS maintained source contract missing'
      ;;
    *)
      fail "unsupported plan log fixture variant: $variant"
      ;;
  esac
  printf '%s\n' '[plan-readiness][error] Plan readiness audit failed:' "$failure" > "$report_dir/plan-readiness.log"
}

assert_success_bundle() {
  [[ -f "$bundle_dir/manifest.json" ]] || fail "manifest.json missing"
  [[ -f "$bundle_dir/unblock.md" ]] || fail "unblock.md missing"
  [[ -x "$bundle_dir/verify-blockers.sh" ]] || fail "verify-blockers.sh missing or not executable"
  [[ -f "$bundle_dir/SHA256SUMS" ]] || fail "SHA256SUMS missing"
  [[ -f "$bundle_dir/logs/release-pr-readiness.log" ]] || fail "release PR log copy missing"
  [[ -f "$bundle_dir/handoffs/release-pr-readiness-report.json" ]] || fail "release PR status report handoff missing"
  [[ -f "$bundle_dir/logs/web-bitcoin-broadcast-evidence.log" ]] || fail "web Bitcoin evidence log copy missing"
  [[ -f "$bundle_dir/handoffs/web-bitcoin-broadcast-evidence-template.json" ]] || fail "web Bitcoin evidence template handoff missing"
  [[ -f "$bundle_dir/handoffs/passkey-deployment-evidence-template.json" ]] || fail "passkey deployment evidence template handoff missing"
  [[ -f "$bundle_dir/handoffs/passkey-backup-production.json" ]] || fail "passkey production config handoff missing"
  [[ -f "$bundle_dir/handoffs/passkey-backup-challenge-service.openapi.json" ]] || fail "passkey OpenAPI contract handoff missing"
  [[ -f "$bundle_dir/handoffs/passkey-backup-docker-compose.production.yml" ]] || fail "passkey production compose handoff missing"
  [[ -f "$bundle_dir/handoffs/nexus-production-evidence-template.json" ]] || fail "Nexus production evidence template handoff missing"
  [[ -f "$bundle_dir/handoffs/ti-deployment-evidence-template.json" ]] || fail "TI deployment evidence template artifact handoff missing"
  [[ -f "$bundle_dir/handoffs/si-deployment-evidence-template.json" ]] || fail "SI deployment evidence template artifact handoff missing"
  [[ -f "$bundle_dir/handoffs/pi-deployment-evidence-template.json" ]] || fail "PI deployment evidence template artifact handoff missing"
  [[ -f "$bundle_dir/handoffs/android-xcm-production-evidence-template.json" ]] || fail "Android XCM production evidence template handoff missing"
  [[ -f "$bundle_dir/handoffs/android-xcm-registry-gap-report.json" ]] || fail "Android XCM registry gap report handoff missing"
  [[ -f "$bundle_dir/handoffs/android-xcm-effective-registry-report.json" ]] || fail "Android XCM effective registry report handoff missing"
  [[ -f "$bundle_dir/logs/si-production-smoke.log" ]] || fail "SI smoke log copy missing"
  [[ ! -e "$bundle_dir/stale.txt" ]] || fail "stale output file was not removed"

  node - "$bundle_dir/manifest.json" <<'NODE'
const fs = require('fs')
const manifest = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'))
if (manifest.schemaVersion !== 3) throw new Error('bad schemaVersion')
if (manifest.blockerCount !== 12) throw new Error('bad blockerCount')
if (manifest.sourcePublicationHandoff?.sourceCount !== 9 || manifest.sourcePublicationHandoff?.passedCount !== 9 || manifest.sourcePublicationHandoff?.repositories?.length !== 8) {
  throw new Error('bad nine-source publication handoff totals')
}
if (manifest.sourcePublicationHandoff?.preflightReportPath !== 'source-publication-preflight-report.json' ||
    manifest.sourcePublicationHandoff?.preflightReportArtifact !== 'handoffs/source-publication-preflight-report.json' ||
    manifest.sourcePublicationHandoff?.preflightReportSha256 !== manifest.artifacts.find((artifact) => artifact.path === 'handoffs/source-publication-preflight-report.json')?.sha256) {
  throw new Error('missing exact preflight source publication handoff')
}
const irohaSource = manifest.sourcePublicationHandoff.repositories[7]
if (irohaSource?.path !== '../iroha' || irohaSource?.repository !== 'hyperledger-iroha/iroha' || irohaSource?.head !== 'codex/kagemusha-selector-hardening' || irohaSource?.base !== 'optimizations' || irohaSource?.prNumber !== 5612) {
  throw new Error('missing exact Iroha source publication identity')
}
if (irohaSource?.branch !== irohaSource.head || irohaSource?.prHeadSha !== irohaSource.headSha || irohaSource?.remoteBranchPresent !== true || irohaSource?.currentBranchRemotePresent !== true || irohaSource?.currentBranchRemoteSha !== irohaSource.headSha) {
  throw new Error('missing exact Iroha current-branch remote proof')
}
const releasePrBlocker = manifest.blockers.find((blocker) => blocker.slug === 'release-pr-readiness')
if (!releasePrBlocker || !releasePrBlocker.logSha256) {
  throw new Error('missing release PR blocker checksum')
}
if (releasePrBlocker.releasePrStatusReportHandoff?.failedCount !== 4) {
  throw new Error('missing release PR status report handoff count')
}
if (releasePrBlocker.releasePrStatusReportHandoff?.reportArtifact !== 'handoffs/release-pr-readiness-report.json') {
  throw new Error('missing release PR status report artifact')
}
if (!releasePrBlocker.releasePrStatusReportHandoff?.reportSha256) {
  throw new Error('missing release PR status report checksum')
}
if (!releasePrBlocker.releasePrStatusReportHandoff.blockedPrs.some((pr) => pr.repo === 'soramitsu/fearless-wallet-web' && pr.pr === '1061' && pr.head === 'codex/web-bitcoin-broadcast-evidence' && pr.base === 'develop' && pr.requiredState === 'merged' && pr.requiredChecks.join(',') === 'validate,verify' && pr.reviewDecision === 'REVIEW_REQUIRED' && pr.mergeStateStatus === 'BLOCKED')) {
  throw new Error('missing release PR status report blocked PR')
}
if (!releasePrBlocker.outdatedReviewThreadResolution) {
  throw new Error('missing release PR outdated review-thread resolution handoff')
}
if (releasePrBlocker.outdatedReviewThreadResolution.threadCount !== 2) {
  throw new Error('bad release PR outdated review-thread count')
}
if (!releasePrBlocker.outdatedReviewThreadResolution.threads.some((thread) => thread.id === 'PRRT_release_one')) {
  throw new Error('missing release PR outdated review-thread ID')
}
if (releasePrBlocker.releasePrApprovalHandoff?.approvalCount !== 3) {
  throw new Error('missing release PR approval handoff count')
}
if (!releasePrBlocker.releasePrApprovalHandoff.prs.some((pr) => pr.repo === 'tonswap-org/ton-indexer' && pr.pr === '9' && pr.requiredAction === 'eligible reviewer approval')) {
  throw new Error('missing release PR approval-only PR handoff')
}
if (!releasePrBlocker.releasePrApprovalHandoff.prs.some((pr) => pr.repo === 'tonswap-org/ton-indexer' && pr.pr === '10' && pr.requiredAction === 'restore review details for eligible reviewer approval' && pr.reviewDetails === 'unavailable')) {
  throw new Error('missing release PR unavailable review-detail handoff')
}
if (!releasePrBlocker.releasePrApprovalHandoff.prs.some((pr) => pr.repo === 'sora-xor/polkaswap-indexer' && pr.pr === '1' && pr.reviewDecision === 'UNKNOWN' && pr.approvalCount === 0 && pr.currentHeadApprovalCount === 0)) {
  throw new Error('missing release PR zero-approval unknown-review handoff')
}
const approvalPr = releasePrBlocker.releasePrApprovalHandoff.prs.find((pr) => pr.repo === 'tonswap-org/ton-indexer' && pr.pr === '9')
if (!approvalPr) {
  throw new Error('missing release PR approval diagnostic PR')
}
if (
  approvalPr.eligibleReviewerApprovalRequired !== true ||
  approvalPr.approvalCount !== 1 ||
  approvalPr.currentHeadApprovalCount !== 1 ||
  approvalPr.staleApprovalCount !== 0 ||
  approvalPr.latestApprovalCommit !== 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' ||
  approvalPr.currentApprovalNotEligible !== true ||
  approvalPr.freshApprovalRequired !== false
) {
  throw new Error('missing release PR approval diagnostics')
}
if (releasePrBlocker.releasePrMergeHandoff?.dryRunCommand !== 'bash scripts/merge-release-prs.sh --dry-run --config config/release-readiness-prs.tsv') {
  throw new Error('missing release PR merge dry-run handoff')
}
if (releasePrBlocker.releasePrMergeHandoff?.requiredPrCount !== 4 || releasePrBlocker.releasePrMergeHandoff?.blockedPrCount !== 4) {
  throw new Error('missing release PR merge count handoff')
}
if (releasePrBlocker.releasePrMergeHandoff?.applyCommand !== 'RELEASE_PR_MERGE_CONFIRM=merge-release-prs bash scripts/merge-release-prs.sh --apply --config config/release-readiness-prs.tsv') {
  throw new Error('missing release PR merge apply handoff')
}
if (releasePrBlocker.releasePrMergeHandoff?.postMergeVerificationCommand !== 'bash scripts/audit-release-pr-readiness.sh') {
  throw new Error('missing release PR post-merge verification handoff')
}
if (releasePrBlocker.unblockCategory !== 'review-and-merge') {
  throw new Error('missing release PR unblock category')
}
if (!releasePrBlocker.externalPrerequisite?.includes('Reviewer approvals')) {
  throw new Error('missing release PR external prerequisite')
}
const bitcoinBlocker = manifest.blockers.find((blocker) => blocker.slug === 'web-bitcoin-broadcast-evidence')
if (!bitcoinBlocker?.evidenceTemplateCommands?.includes('cd fearless-wallet-web && yarn generate:bitcoin-broadcast-evidence-template -- --output build/reports/bitcoin-broadcast-evidence-template.json')) {
  throw new Error('missing web Bitcoin evidence template command handoff')
}
if (bitcoinBlocker?.evidenceTemplateHandoff?.outputPath !== 'fearless-wallet-web/build/reports/bitcoin-broadcast-evidence-template.json') {
  throw new Error('missing web Bitcoin evidence template output handoff')
}
if (bitcoinBlocker?.evidenceTemplateHandoff?.destinationManifest !== 'fearless-wallet-web/scripts/bitcoin-testnet-broadcast-evidence.json') {
  throw new Error('missing web Bitcoin evidence destination manifest handoff')
}
if (bitcoinBlocker?.evidenceTemplateHandoff?.readyAuditCommand !== 'cd fearless-wallet-web && bash scripts/audit-bitcoin-broadcast-evidence.sh --require-ready') {
  throw new Error('missing web Bitcoin evidence ready audit handoff')
}
if (!bitcoinBlocker?.evidenceTemplateHandoff?.requiredEvidenceContracts?.includes('indexerUrl must be https://blockstream.info/testnet/api')) {
  throw new Error('missing web Bitcoin evidence canonical indexer contract handoff')
}
if (!bitcoinBlocker?.evidenceTemplateHandoff?.requiredEvidenceContracts?.includes('status.block_time must be present from the indexer')) {
  throw new Error('missing web Bitcoin evidence block-time contract handoff')
}
if (bitcoinBlocker?.bitcoinBroadcastTemplateHandoff?.templateArtifact !== 'handoffs/web-bitcoin-broadcast-evidence-template.json') {
  throw new Error('missing web Bitcoin evidence template artifact handoff')
}
if (bitcoinBlocker?.bitcoinBroadcastTemplateHandoff?.sourceReportPath !== 'web-bitcoin-broadcast-evidence-template.json') {
  throw new Error('missing web Bitcoin evidence template source report handoff')
}
if (bitcoinBlocker?.bitcoinBroadcastTemplateHandoff?.generatedTemplatePath !== 'fearless-wallet-web/build/reports/bitcoin-broadcast-evidence-template.json') {
  throw new Error('missing web Bitcoin evidence generated template path handoff')
}
if (bitcoinBlocker?.bitcoinBroadcastTemplateHandoff?.defaultIndexerUrl !== 'https://blockstream.info/testnet/api') {
  throw new Error('missing web Bitcoin evidence template canonical indexer handoff')
}
if (!bitcoinBlocker?.bitcoinBroadcastTemplateHandoff?.requiredEvidenceFields?.includes('outpoint')) {
  throw new Error('missing web Bitcoin evidence template outpoint field handoff')
}
if (bitcoinBlocker?.bitcoinBroadcastTemplateHandoff?.placeholderRecord?.commit !== 'TODO_40_HEX_GIT_COMMIT') {
  throw new Error('missing web Bitcoin evidence template commit placeholder handoff')
}
if (!bitcoinBlocker?.bitcoinBroadcastTemplateHandoff?.requiredContracts?.includes('template placeholders must fail --require-ready until funded evidence is recorded')) {
  throw new Error('missing web Bitcoin evidence template placeholder-failure contract handoff')
}
if (!manifest.artifacts.some((artifact) => artifact.path === 'handoffs/web-bitcoin-broadcast-evidence-template.json' && artifact.sha256 === bitcoinBlocker.bitcoinBroadcastTemplateHandoff.templateSha256)) {
  throw new Error('missing web Bitcoin evidence template artifact checksum')
}
const passkeyDeploymentBlocker = manifest.blockers.find((blocker) => blocker.slug === 'passkey-deployment-evidence')
if (passkeyDeploymentBlocker?.evidenceTemplateHandoff?.outputPath !== 'services/passkey-backup-challenge-service/build/reports/production-deployment-evidence-template.json') {
  throw new Error('missing passkey deployment evidence template output handoff')
}
if (passkeyDeploymentBlocker?.passkeyDeploymentTemplateHandoff?.templateArtifact !== 'handoffs/passkey-deployment-evidence-template.json') {
  throw new Error('missing passkey deployment evidence template artifact handoff')
}
if (passkeyDeploymentBlocker?.passkeyDeploymentTemplateHandoff?.sourceReportPath !== 'passkey-deployment-evidence-template.json') {
  throw new Error('missing passkey deployment evidence template source report handoff')
}
if (passkeyDeploymentBlocker?.passkeyDeploymentTemplateHandoff?.service !== 'fearless-passkey-backup') {
  throw new Error('missing passkey deployment evidence service handoff')
}
if (passkeyDeploymentBlocker?.passkeyDeploymentTemplateHandoff?.healthUrl !== 'https://backup.fearlesswallet.io/api/passkey-backup/v1/health') {
  throw new Error('missing passkey deployment evidence health URL handoff')
}
if (passkeyDeploymentBlocker?.passkeyDeploymentTemplateHandoff?.credentialStoreFile !== '/data/passkey-backup/credentials.json') {
  throw new Error('missing passkey deployment evidence credential-store file handoff')
}
if (!passkeyDeploymentBlocker?.passkeyDeploymentTemplateHandoff?.requiredEvidenceFields?.includes('platformProvisioning')) {
  throw new Error('missing passkey deployment evidence platform provisioning field handoff')
}
if (!passkeyDeploymentBlocker?.passkeyDeploymentTemplateHandoff?.requiredEvidenceFields?.includes('liveHealthAttestation') ||
    !passkeyDeploymentBlocker?.passkeyDeploymentTemplateHandoff?.requiredEvidenceFields?.includes('platformProvisioningAttestation')) {
  throw new Error('missing passkey bound attestation fields handoff')
}
if (!passkeyDeploymentBlocker?.passkeyDeploymentTemplateHandoff?.requiredEvidenceFields?.includes('webauthnAllowedOrigins')) {
  throw new Error('missing passkey deployment evidence WebAuthn origin field handoff')
}
if (passkeyDeploymentBlocker?.passkeyDeploymentTemplateHandoff?.webauthnAllowedOriginsTarget?.[2] !== 'android:apk-key-hash:TODO_RELEASE_CERT_SHA256_BASE64URL') {
  throw new Error('missing passkey deployment evidence Android release origin target')
}
if (passkeyDeploymentBlocker?.passkeyDeploymentTemplateHandoff?.requestAccessPolicyTarget?.introspectionUrl !== 'https://TODO_WALLET_OWNER_AUTHORITY/v1/passkey/consume' ||
    passkeyDeploymentBlocker?.passkeyDeploymentTemplateHandoff?.requestAccessPolicyTarget?.allPostRoutesProtected !== true ||
    passkeyDeploymentBlocker?.passkeyDeploymentTemplateHandoff?.requestAccessPolicyTarget?.noRawSubjectPersisted !== true ||
    passkeyDeploymentBlocker?.passkeyDeploymentTemplateHandoff?.requestAccessPolicyTarget?.credentialLifecycleSmokePassed !== true ||
    passkeyDeploymentBlocker?.passkeyDeploymentTemplateHandoff?.requestAccessPolicyTarget?.ownerTombstonePersistencePassed !== true ||
    passkeyDeploymentBlocker?.passkeyDeploymentTemplateHandoff?.requestAccessPolicyTarget?.crossSubjectTakeoverDenied !== true ||
    passkeyDeploymentBlocker?.passkeyDeploymentTemplateHandoff?.requestAccessPolicyTarget?.sameOwnerReregistrationPassed !== true ||
    passkeyDeploymentBlocker?.passkeyDeploymentTemplateHandoff?.requestAccessPolicyTarget?.cloudDeleteRevokesServerFirst !== true ||
    passkeyDeploymentBlocker?.passkeyDeploymentTemplateHandoff?.requestAccessPolicyTarget?.listExcludesVerificationMaterial !== true) {
  throw new Error('missing passkey deployment evidence request-access policy target')
}
if (passkeyDeploymentBlocker?.passkeyDeploymentTemplateHandoff?.trustedProxyPolicyTarget?.hops !== 1 ||
    passkeyDeploymentBlocker?.passkeyDeploymentTemplateHandoff?.trustedProxyPolicyTarget?.directPeerAllowlistConfigured !== true ||
    passkeyDeploymentBlocker?.passkeyDeploymentTemplateHandoff?.trustedProxyPolicyTarget?.adversarialProxyTestsPassed !== true) {
  throw new Error('missing passkey deployment evidence trusted-proxy policy target')
}
if (passkeyDeploymentBlocker?.passkeyDeploymentTemplateHandoff?.placeholderRecord?.deployedCommit !== 'TODO_40_HEX_GIT_COMMIT') {
  throw new Error('missing passkey deployment evidence deployed commit placeholder handoff')
}
if (passkeyDeploymentBlocker?.passkeyDeploymentTemplateHandoff?.healthResponseTarget?.service !== 'fearless-passkey-backup') {
  throw new Error('missing passkey deployment evidence health service target')
}
if (passkeyDeploymentBlocker?.passkeyDeploymentTemplateHandoff?.liveHealthAttestationTarget?.deploymentId !== 'TODO_PRODUCTION_DEPLOYMENT_ID' ||
    passkeyDeploymentBlocker?.passkeyDeploymentTemplateHandoff?.liveHealthAttestationTarget?.observedAt !== 'TODO_UTC_SMOKE_TIMESTAMP_SECONDS' ||
    passkeyDeploymentBlocker?.passkeyDeploymentTemplateHandoff?.liveHealthAttestationTarget?.payloadSha256 !== 'sha256:TODO_CANONICAL_HEALTH_RESPONSE_SHA256') {
  throw new Error('missing passkey live-health attestation target')
}
if (passkeyDeploymentBlocker?.passkeyDeploymentTemplateHandoff?.platformProvisioningTarget?.iosReleaseFlagDisabled !== true) {
  throw new Error('missing passkey deployment evidence iOS release flag target')
}
if (passkeyDeploymentBlocker?.passkeyDeploymentTemplateHandoff?.platformProvisioningAttestationTarget?.deployedCommit !== 'TODO_40_HEX_GIT_COMMIT' ||
    passkeyDeploymentBlocker?.passkeyDeploymentTemplateHandoff?.platformProvisioningAttestationTarget?.payloadSha256 !== 'sha256:TODO_CANONICAL_PLATFORM_PROVISIONING_SHA256') {
  throw new Error('missing passkey platform-provisioning attestation target')
}
if (!passkeyDeploymentBlocker?.passkeyDeploymentTemplateHandoff?.requiredContracts?.includes('template placeholders must fail --require-ready until deployment evidence is recorded')) {
  throw new Error('missing passkey deployment evidence placeholder-failure contract handoff')
}
if (!passkeyDeploymentBlocker?.passkeyDeploymentTemplateHandoff?.requiredContracts?.includes('smokePassedAt must be no more than 24 hours old for ready evidence; the exact 24-hour boundary is accepted and every record is checked independently') ||
    !passkeyDeploymentBlocker?.passkeyDeploymentTemplateHandoff?.requiredContracts?.includes('liveHealthAttestation and platformProvisioningAttestation must bind deploymentId, deployedCommit, imageDigest, and observedAt=smokePassedAt; payloadSha256 must match the canonical attested payload') ||
    !passkeyDeploymentBlocker?.passkeyDeploymentTemplateHandoff?.requiredContracts?.includes('blocked deployment evidence must keep deploymentEvidence empty; partial or stale records cannot coexist with blockers')) {
  throw new Error('missing passkey freshness, attestation-binding, or blocked-evidence contract handoff')
}
if (!manifest.artifacts.some((artifact) => artifact.path === 'handoffs/passkey-deployment-evidence-template.json' && artifact.sha256 === passkeyDeploymentBlocker.passkeyDeploymentTemplateHandoff.templateSha256)) {
  throw new Error('missing passkey deployment evidence template artifact checksum')
}
function assertReadyIndexerDeploymentBlocker(slug, expected) {
  const blocker = manifest.blockers.find((candidate) => candidate.slug === slug)
  if (!blocker) throw new Error(`missing ${slug} blocker`)
  if (!blocker.evidenceTemplateCommands?.includes(expected.generateCommand)) {
    throw new Error(`missing ${expected.label} deployment evidence template command handoff`)
  }
  if (blocker.evidenceTemplateHandoff?.outputPath !== expected.outputPath) {
    throw new Error(`missing ${expected.label} deployment evidence template output handoff`)
  }
  if (blocker.evidenceTemplateHandoff?.destinationManifest !== expected.destinationManifest) {
    throw new Error(`missing ${expected.label} deployment evidence destination manifest handoff`)
  }
  if (blocker.evidenceTemplateHandoff?.readyAuditCommand !== expected.readyAuditCommand) {
    throw new Error(`missing ${expected.label} deployment evidence ready audit handoff`)
  }
  for (const contract of expected.evidenceContracts) {
    if (!blocker.evidenceTemplateHandoff?.requiredEvidenceContracts?.includes(contract)) {
      throw new Error(`missing ${expected.label} deployment evidence contract handoff`)
    }
  }
  const handoff = blocker.indexerDeploymentTemplateHandoff
  if (handoff?.templateArtifact !== expected.templateArtifact) {
    throw new Error(`missing ${expected.label} deployment evidence template artifact handoff`)
  }
  if (handoff?.sourceReportPath !== expected.sourceReportPath) {
    throw new Error(`missing ${expected.label} deployment evidence template source report handoff`)
  }
  if (handoff?.serviceId !== expected.serviceId) {
    throw new Error(`missing ${expected.label} deployment evidence template service-id handoff`)
  }
  if (handoff?.baseUrl !== expected.baseUrl) {
    throw new Error(`missing ${expected.label} deployment evidence template base URL handoff`)
  }
  if (handoff?.status !== 'ready') {
    throw new Error(`missing ${expected.label} deployment evidence template ready status handoff`)
  }
  if (handoff?.releaseEnabled !== true) {
    throw new Error(`missing ${expected.label} deployment evidence template release gate handoff`)
  }
  if (handoff?.placeholderRecord?.commit !== 'TODO_40_HEX_GIT_COMMIT') {
    throw new Error(`missing ${expected.label} deployment evidence template commit placeholder handoff`)
  }
  if (handoff?.serviceInfoTarget?.serviceId !== expected.serviceId) {
    throw new Error(`missing ${expected.label} deployment evidence template service-info service-id target`)
  }
  if (handoff?.serviceInfoTarget?.publicBaseUrl !== expected.baseUrl) {
    throw new Error(`missing ${expected.label} deployment evidence template service-info public URL target`)
  }
  if (handoff?.healthInfoTarget?.serviceId !== expected.serviceId) {
    throw new Error(`missing ${expected.label} deployment evidence template health service-id target`)
  }
  for (const [field, value] of Object.entries(expected.healthInfoTargets || {})) {
    if (handoff?.healthInfoTarget?.[field] !== value) {
      throw new Error(`missing ${expected.label} deployment evidence template health ${field} target`)
    }
  }
  for (const contract of expected.templateContracts) {
    if (!handoff?.requiredContracts?.includes(contract)) {
      throw new Error(`missing ${expected.label} deployment evidence template contract handoff`)
    }
  }
  if (!manifest.artifacts.some((artifact) => artifact.path === expected.templateArtifact && artifact.sha256 === handoff.templateSha256)) {
    throw new Error(`missing ${expected.label} deployment evidence template artifact checksum`)
  }
}
assertReadyIndexerDeploymentBlocker('ti-deployment-evidence', {
  label: 'TI',
  generateCommand: 'cd ../ton-indexer && npm run generate:deployment-evidence-template -- --output build/reports/production-deployment-evidence-template.json',
  outputPath: '../ton-indexer/build/reports/production-deployment-evidence-template.json',
  destinationManifest: '../ton-indexer/scripts/production-deployment-evidence.json',
  readyAuditCommand: 'cd ../ton-indexer && npm run audit:deployment-evidence -- --require-ready',
  evidenceContracts: ['serviceInfo.serviceId=ti.soramitsu.io', 'healthInfo.lastMasterSeqno must come from successful production smoke'],
  templateArtifact: 'handoffs/ti-deployment-evidence-template.json',
  sourceReportPath: 'ti-deployment-evidence-template.json',
  serviceId: 'ti.soramitsu.io',
  baseUrl: 'https://ti.soramitsu.io',
  templateContracts: [
    'template status must be ready with releaseEnabled=true for operator fill-in',
    'healthInfo.lastMasterSeqno must be replaced with successful production smoke evidence',
  ],
})
assertReadyIndexerDeploymentBlocker('si-deployment-evidence', {
  label: 'SI',
  generateCommand: 'cd ../solswap-indexer && npm run generate:deployment-evidence-template -- --output build/reports/production-deployment-evidence-template.json',
  outputPath: '../solswap-indexer/build/reports/production-deployment-evidence-template.json',
  destinationManifest: '../solswap-indexer/scripts/production-deployment-evidence.json',
  readyAuditCommand: 'cd ../solswap-indexer && npm run audit:deployment-evidence -- --require-ready',
  evidenceContracts: [
    'serviceInfo.serviceId=si.soramitsu.io',
    'healthInfo.ok=true and healthInfo.lastMasterSeqno must be absent',
    'healthInfo.genesisHash=5eykt4UsFv8P8NJdTREpY1vzqKqZKvdpKuc147dw2N9d',
    'healthInfo.latestSlot must be a positive safe integer',
    'healthInfo.syncedAt must be an integer no more than 120 seconds before and no more than 30 seconds after smokePassedAt',
  ],
  templateArtifact: 'handoffs/si-deployment-evidence-template.json',
  sourceReportPath: 'si-deployment-evidence-template.json',
  serviceId: 'si.soramitsu.io',
  baseUrl: 'https://si.soramitsu.io',
  healthInfoTargets: {
    genesisHash: '5eykt4UsFv8P8NJdTREpY1vzqKqZKvdpKuc147dw2N9d',
    latestSlot: 'TODO_POSITIVE_LATEST_SLOT',
    syncedAt: 'TODO_UNIX_TIMESTAMP_SECONDS',
  },
  templateContracts: [
    'template status must be ready with releaseEnabled=true for operator fill-in',
    'healthInfo.genesisHash must remain the exact Solana mainnet genesis hash',
    'healthInfo.latestSlot must be TODO_POSITIVE_LATEST_SLOT in the template and a positive safe integer in ready evidence',
    'healthInfo.syncedAt must be TODO_UNIX_TIMESTAMP_SECONDS in the template and an integer no more than 120 seconds before and no more than 30 seconds after smokePassedAt in ready evidence',
    'healthInfo.lastMasterSeqno must remain absent for the Solswap service',
  ],
})
const piDeploymentBlocker = manifest.blockers.find((blocker) => blocker.slug === 'pi-deployment-evidence')
if (!piDeploymentBlocker?.evidenceTemplateCommands?.includes('cd ../polkaswap-indexer && bash ../fearless/scripts/run-pinned-yarn.sh generate:deployment-evidence-template --output build/reports/production-deployment-evidence-template.json')) {
  throw new Error('missing PI deployment evidence template command handoff')
}
if (piDeploymentBlocker?.evidenceTemplateHandoff?.outputPath !== '../polkaswap-indexer/build/reports/production-deployment-evidence-template.json') {
  throw new Error('missing PI deployment evidence template output handoff')
}
if (piDeploymentBlocker?.evidenceTemplateHandoff?.destinationManifest !== '../polkaswap-indexer/scripts/production-deployment-evidence.json') {
  throw new Error('missing PI deployment evidence destination manifest handoff')
}
if (piDeploymentBlocker?.evidenceTemplateHandoff?.readyAuditCommand !== 'cd ../polkaswap-indexer && bash ../fearless/scripts/run-pinned-yarn.sh audit:deployment-evidence --require-ready') {
  throw new Error('missing PI deployment evidence ready audit handoff')
}
if (!piDeploymentBlocker?.evidenceTemplateHandoff?.requiredEvidenceContracts?.includes('healthInfo.service=polkaswap-indexer')) {
  throw new Error('missing PI deployment evidence health service contract handoff')
}
if (!piDeploymentBlocker?.evidenceTemplateHandoff?.requiredEvidenceContracts?.includes('healthInfo.publicBaseUrl=https://pi.soramitsu.io/graphql')) {
  throw new Error('missing PI deployment evidence public URL contract handoff')
}
if (!piDeploymentBlocker?.evidenceTemplateHandoff?.requiredEvidenceContracts?.includes('healthInfo.genesisHash=0x7e4e32d0feafd4f9c9414b0be86373f9a1efa904809b683453a9af6856d38ad5')) {
  throw new Error('missing PI deployment evidence genesis contract handoff')
}
for (const contract of [
  'soraRpcControls must contain exactly the seven reviewed primary/archive trust-boundary fields',
  'soraRpcControls.primaryEndpoint must be a canonical credential-free WSS URL for a locally-controlled verifying archival node and not a public SORA convenience host',
  'soraRpcControls.archiveEndpoint must be a canonical credential-free WSS URL for an independently-operated verifying archival node on a distinct host and not a public SORA convenience host',
  'soraRpcControls.exactIdentityPreflight must be true and rawPayloadAgreement must be height-hash-scale-block-events-timestamp',
]) {
  if (!piDeploymentBlocker?.evidenceTemplateHandoff?.requiredEvidenceContracts?.includes(contract)) {
    throw new Error(`missing PI deployment evidence SORA RPC contract handoff: ${contract}`)
  }
}
if (!piDeploymentBlocker?.evidenceTemplateHandoff?.requiredEvidenceContracts?.includes('tlsEdgeControls.forwardedClientIpHeaders=overwrite')) {
  throw new Error('missing PI deployment evidence TLS-edge overwrite contract handoff')
}
if (piDeploymentBlocker?.indexerDeploymentTemplateHandoff?.templateArtifact !== 'handoffs/pi-deployment-evidence-template.json') {
  throw new Error('missing PI deployment evidence template artifact handoff')
}
if (piDeploymentBlocker?.indexerDeploymentTemplateHandoff?.sourceReportPath !== 'pi-deployment-evidence-template.json') {
  throw new Error('missing PI deployment evidence template source report handoff')
}
if (piDeploymentBlocker?.indexerDeploymentTemplateHandoff?.serviceId !== 'pi.soramitsu.io') {
  throw new Error('missing PI deployment evidence template service-id handoff')
}
if (piDeploymentBlocker?.indexerDeploymentTemplateHandoff?.baseUrl !== 'https://pi.soramitsu.io/graphql') {
  throw new Error('missing PI deployment evidence template base URL handoff')
}
if (piDeploymentBlocker?.indexerDeploymentTemplateHandoff?.status !== 'blocked') {
  throw new Error('missing PI deployment evidence template blocked status handoff')
}
if (piDeploymentBlocker?.indexerDeploymentTemplateHandoff?.releaseEnabled !== false) {
  throw new Error('missing PI deployment evidence template release gate handoff')
}
if (piDeploymentBlocker?.indexerDeploymentTemplateHandoff?.placeholderRecord?.commit !== 'TODO_40_HEX_GIT_COMMIT') {
  throw new Error('missing PI deployment evidence template commit placeholder handoff')
}
if (piDeploymentBlocker?.indexerDeploymentTemplateHandoff?.healthInfoTarget?.service !== 'polkaswap-indexer') {
  throw new Error('missing PI deployment evidence template health service target')
}
if (piDeploymentBlocker?.indexerDeploymentTemplateHandoff?.healthInfoTarget?.publicBaseUrl !== 'https://pi.soramitsu.io/graphql') {
  throw new Error('missing PI deployment evidence template health public URL target')
}
const piHealthTarget = piDeploymentBlocker?.indexerDeploymentTemplateHandoff?.healthInfoTarget
if (
  piHealthTarget?.genesisHash !== '0x7e4e32d0feafd4f9c9414b0be86373f9a1efa904809b683453a9af6856d38ad5' ||
  piHealthTarget?.latestIndexedBlock !== 'TODO_POSITIVE_SAFE_INTEGER_INDEXED_BLOCK' ||
  piHealthTarget?.latestIndexedBlockHash !== 'TODO_0X_64_LOWERCASE_HEX_INDEXED_BLOCK_HASH' ||
  piHealthTarget?.latestIndexedAt !== 'TODO_UNIX_SECONDS_WITHIN_300_BEFORE_OR_30_AFTER_SMOKE'
) {
  throw new Error('missing exact PI deployment evidence indexed-health target handoff')
}
if (!piDeploymentBlocker?.indexerDeploymentTemplateHandoff?.requiredEvidenceFields?.includes('tlsEdgeControls')) {
  throw new Error('missing PI deployment evidence TLS-edge required field handoff')
}
if (!piDeploymentBlocker?.indexerDeploymentTemplateHandoff?.requiredEvidenceFields?.includes('soraRpcControls')) {
  throw new Error('missing PI deployment evidence SORA RPC required field handoff')
}
const piSoraRpcTarget = piDeploymentBlocker?.indexerDeploymentTemplateHandoff?.soraRpcControlsTarget
const expectedPiSoraRpcTarget = {
  primaryEndpoint: 'TODO_CANONICAL_WSS_LOCALLY_CONTROLLED_PRIMARY_RPC_ENDPOINT',
  archiveEndpoint: 'TODO_CANONICAL_WSS_INDEPENDENT_ARCHIVE_RPC_ENDPOINT',
  primaryNodeControl: 'locally-controlled-verifying-archive',
  archiveNodeControl: 'independently-operated-verifying-archive',
  distinctHosts: true,
  exactIdentityPreflight: true,
  rawPayloadAgreement: 'height-hash-scale-block-events-timestamp',
}
if (JSON.stringify(piSoraRpcTarget) !== JSON.stringify(expectedPiSoraRpcTarget)) {
  throw new Error('missing exact seven-key PI deployment evidence SORA RPC target handoff')
}
const piTlsEdgeTarget = piDeploymentBlocker?.indexerDeploymentTemplateHandoff?.tlsEdgeControlsTarget
if (
  piTlsEdgeTarget?.tlsTermination !== true ||
  piTlsEdgeTarget?.forwardedClientIpHeaders !== 'overwrite' ||
  piTlsEdgeTarget?.httpClientIpRateLimit?.windowMs !== 60000 ||
  piTlsEdgeTarget?.httpClientIpRateLimit?.maxRequests !== 600 ||
  piTlsEdgeTarget?.webSocketClientIpLimits?.windowMs !== 60000 ||
  piTlsEdgeTarget?.webSocketClientIpLimits?.maxUpgrades !== 600 ||
  piTlsEdgeTarget?.webSocketClientIpLimits?.maxConcurrentConnections !== 16
) {
  throw new Error('missing exact PI deployment evidence TLS-edge target handoff')
}
if (!piDeploymentBlocker?.indexerDeploymentTemplateHandoff?.requiredContracts?.includes('template remains blocked until PI production deployment evidence is recorded')) {
  throw new Error('missing PI deployment evidence template blocked contract handoff')
}
for (const contract of [
  'soraRpcControls must contain exactly the seven reviewed primary/archive trust-boundary fields',
  'soraRpcControls.primaryEndpoint must be a canonical credential-free WSS URL for a locally-controlled verifying archival node and not a public SORA convenience host',
  'soraRpcControls.archiveEndpoint must be a canonical credential-free WSS URL for an independently-operated verifying archival node on a distinct host and not a public SORA convenience host',
  'soraRpcControls.exactIdentityPreflight must be true and rawPayloadAgreement must be height-hash-scale-block-events-timestamp',
]) {
  if (!piDeploymentBlocker?.indexerDeploymentTemplateHandoff?.requiredContracts?.includes(contract)) {
    throw new Error(`missing PI deployment template SORA RPC contract handoff: ${contract}`)
  }
}
if (!manifest.artifacts.some((artifact) => artifact.path === 'handoffs/pi-deployment-evidence-template.json' && artifact.sha256 === piDeploymentBlocker.indexerDeploymentTemplateHandoff.templateSha256)) {
  throw new Error('missing PI deployment evidence template artifact checksum')
}
const passkeySmokeBlocker = manifest.blockers.find((blocker) => blocker.slug === 'passkey-production-smoke')
if (passkeySmokeBlocker?.liveServiceHandoff?.baseUrl !== 'https://backup.fearlesswallet.io') {
  throw new Error('missing passkey production smoke base URL handoff')
}
if (passkeySmokeBlocker?.liveServiceHandoff?.urlPolicy?.allowedProtocols?.[0] !== 'https') {
  throw new Error('missing passkey production smoke URL protocol policy handoff')
}
if (passkeySmokeBlocker?.liveServiceHandoff?.urlPolicy?.credentials !== 'forbidden') {
  throw new Error('missing passkey production smoke credential URL policy handoff')
}
if (passkeySmokeBlocker?.liveServiceHandoff?.urlPolicy?.query !== 'forbidden') {
  throw new Error('missing passkey production smoke query URL policy handoff')
}
if (passkeySmokeBlocker?.liveServiceHandoff?.urlPolicy?.fragment !== 'forbidden') {
  throw new Error('missing passkey production smoke fragment URL policy handoff')
}
if (passkeySmokeBlocker?.liveServiceHandoff?.urlPolicy?.canonicalInput !== 'use the exact baseUrl; do not append credentials, query strings, or fragments') {
  throw new Error('missing passkey production smoke canonical URL policy handoff')
}
if (!passkeySmokeBlocker?.liveServiceHandoff?.routePaths?.includes('/api/passkey-backup/v1/registration/challenge')) {
  throw new Error('missing passkey production smoke registration challenge route handoff')
}
if (!passkeySmokeBlocker?.liveServiceHandoff?.routePaths?.includes('/api/passkey-backup/v1/assertion/complete')) {
  throw new Error('missing passkey production smoke assertion completion route handoff')
}
if (!passkeySmokeBlocker?.liveServiceHandoff?.expectedContracts?.includes('assertion challenge for unregistered credential returns HTTP 404 error=credential_not_registered')) {
  throw new Error('missing passkey production smoke unregistered assertion contract handoff')
}
if (!passkeySmokeBlocker?.liveServiceHandoff?.expectedContracts?.includes('registration completion for unknown registration returns HTTP 404 error=unknown_or_expired_registration')) {
  throw new Error('missing passkey production smoke unknown registration contract handoff')
}
if (passkeySmokeBlocker?.liveServiceHandoff?.verificationCommand !== 'cd services/passkey-backup-challenge-service && PASSKEY_BACKUP_BASE_URL=https://backup.fearlesswallet.io PASSKEY_BACKUP_SMOKE_GRANT_HELPER=/run/secrets/passkey-smoke-grant-helper PASSKEY_BACKUP_SMOKE_TIMEOUT_MS=10000 npm run smoke:production') {
  throw new Error('missing passkey production smoke verification command handoff')
}
if (passkeySmokeBlocker?.passkeyProductionContractHandoff?.productionConfigArtifact !== 'handoffs/passkey-backup-production.json') {
  throw new Error('missing passkey production config artifact handoff')
}
if (passkeySmokeBlocker?.passkeyProductionContractHandoff?.openApiArtifact !== 'handoffs/passkey-backup-challenge-service.openapi.json') {
  throw new Error('missing passkey OpenAPI artifact handoff')
}
if (passkeySmokeBlocker?.passkeyProductionContractHandoff?.composeArtifact !== 'handoffs/passkey-backup-docker-compose.production.yml') {
  throw new Error('missing passkey production compose artifact handoff')
}
if (passkeySmokeBlocker?.passkeyProductionContractHandoff?.composeSourcePath !== 'services/passkey-backup-challenge-service/docker-compose.production.yml') {
  throw new Error('missing passkey production compose source handoff')
}
if (passkeySmokeBlocker?.passkeyProductionContractHandoff?.baseUrl !== 'https://backup.fearlesswallet.io') {
  throw new Error('missing passkey production contract base URL handoff')
}
if (passkeySmokeBlocker?.passkeyProductionContractHandoff?.rpId !== 'fearlesswallet.io') {
  throw new Error('missing passkey production contract RP ID handoff')
}
if (!passkeySmokeBlocker?.passkeyProductionContractHandoff?.requiredRoutePaths?.includes('/api/passkey-backup/v1/registration/complete')) {
  throw new Error('missing passkey production contract route handoff')
}
if (!passkeySmokeBlocker?.passkeyProductionContractHandoff?.requiredContracts?.includes('OpenAPI server URL must remain https://backup.fearlesswallet.io')) {
  throw new Error('missing passkey production contract OpenAPI server requirement')
}
if (!passkeySmokeBlocker?.passkeyProductionContractHandoff?.requiredContracts?.includes('production Docker Compose must bind 127.0.0.1:8789:8789 and mount passkey-backup-data:/data/passkey-backup')) {
  throw new Error('missing passkey production compose port and volume requirement')
}
if (!passkeySmokeBlocker?.passkeyProductionContractHandoff?.requiredContracts?.includes('production Docker Compose must keep PASSKEY_ALLOWED_ORIGINS pinned to fearlesswallet.io and backup.fearlesswallet.io')) {
  throw new Error('missing passkey production compose origins requirement')
}
if (!passkeySmokeBlocker?.passkeyProductionContractHandoff?.verificationCommands?.includes('PASSKEY_BACKUP_LIVE_HEALTH=1 bash scripts/audit-passkey-backup-prerequisites.sh && node fearless-site-web/scripts/verify-app-associations.mjs --root fearless-site-web --live-base-url https://fearlesswallet.io')) {
  throw new Error('missing passkey production contract prerequisite verification command')
}
if (!passkeySmokeBlocker?.passkeyProductionContractHandoff?.requiredContracts?.includes('production config request authorization must atomically consume one-time bearer grants, bind the exact body digest, fail closed, and prohibit raw platform account identifiers')) {
  throw new Error('missing passkey request-authorization contract handoff')
}
if (!passkeySmokeBlocker?.passkeyProductionContractHandoff?.requiredContracts?.includes('all seven OpenAPI POST operations must require bearerAuth and expose exact 401, 403, and 503 ErrorResponse references')) {
  throw new Error('missing passkey OpenAPI authorization response contract handoff')
}
if (!passkeySmokeBlocker?.passkeyProductionContractHandoff?.requiredContracts?.includes('production Docker Compose must require the Android origin, authorization introspection URL, and trusted proxy CIDRs without permissive fallbacks')) {
  throw new Error('missing passkey fail-closed Compose environment contract handoff')
}
if (!passkeySmokeBlocker?.passkeyProductionContractHandoff?.requiredContracts?.includes('Android origin parity must pass in blocked mode; --require-ready requires actual release-artifact evidence and assetlinks parity: distributed-apk must bind PASSKEY_ANDROID_DISTRIBUTED_APK_FILE and PASSKEY_ANDROID_RELEASE_ARTIFACT_SHA256 to one v2/v3 signer and exact package jp.co.soramitsu.fearless, while play-app-signing-certificate must bind an immutable AAB plus independently exported immutable X.509 certificate and canonical attestation through their SHA-256 digests, derive the fingerprint from that certificate, and bind packageName/versionCode to the compiled AAB; AAB upload-key evidence is rejected and absence keeps passkey flags disabled')) {
  throw new Error('missing passkey signed release origin parity contract handoff')
}
const passkeySignerEvidence = passkeySmokeBlocker?.passkeyProductionContractHandoff?.androidSignerEvidence
if (passkeySignerEvidence?.fingerprintEnvironmentVariable !== 'PASSKEY_ANDROID_RELEASE_SIGNER_SHA256_FINGERPRINT' ||
    passkeySignerEvidence?.sourceEnvironmentVariable !== 'PASSKEY_ANDROID_RELEASE_SIGNER_EVIDENCE_SOURCE' ||
    JSON.stringify(passkeySignerEvidence?.allowedSources) !== JSON.stringify(['distributed-apk', 'play-app-signing-certificate']) ||
    JSON.stringify(passkeySignerEvidence?.rejectedEvidenceTypes) !== JSON.stringify(['aab-upload-key']) ||
    passkeySignerEvidence?.independentlyObtained !== true ||
    passkeySignerEvidence?.requiresAssetlinksParity !== true ||
    passkeySignerEvidence?.exactPackageName !== 'jp.co.soramitsu.fearless' ||
    passkeySignerEvidence?.distributedApk?.artifactFileEnvironmentVariable !== 'PASSKEY_ANDROID_DISTRIBUTED_APK_FILE' ||
    passkeySignerEvidence?.distributedApk?.artifactSha256EnvironmentVariable !== 'PASSKEY_ANDROID_RELEASE_ARTIFACT_SHA256' ||
    passkeySignerEvidence?.distributedApk?.actualReleaseArtifactRequired !== true ||
    passkeySignerEvidence?.distributedApk?.exactlyOneSigningCertificateRequired !== true ||
    passkeySignerEvidence?.distributedApk?.signatureSchemeV2OrV3Required !== true ||
    passkeySignerEvidence?.distributedApk?.packageMustMatchExactPackageName !== true ||
    passkeySignerEvidence?.distributedApk?.artifactChangeDetectionRequired !== true ||
    passkeySignerEvidence?.playAppSigningCertificate?.certificateFileEnvironmentVariable !== 'PASSKEY_ANDROID_PLAY_APP_SIGNING_CERTIFICATE_FILE' ||
    passkeySignerEvidence?.playAppSigningCertificate?.certificateSha256EnvironmentVariable !== 'PASSKEY_ANDROID_PLAY_APP_SIGNING_CERTIFICATE_SHA256' ||
    passkeySignerEvidence?.playAppSigningCertificate?.attestationFileEnvironmentVariable !== 'PASSKEY_ANDROID_PLAY_APP_SIGNING_ATTESTATION_FILE' ||
    passkeySignerEvidence?.playAppSigningCertificate?.attestationSha256EnvironmentVariable !== 'PASSKEY_ANDROID_PLAY_APP_SIGNING_ATTESTATION_SHA256' ||
    passkeySignerEvidence?.playAppSigningCertificate?.releaseArtifactFileEnvironmentVariable !== 'PASSKEY_ANDROID_RELEASE_ARTIFACT_FILE' ||
    passkeySignerEvidence?.playAppSigningCertificate?.releaseArtifactSha256EnvironmentVariable !== 'PASSKEY_ANDROID_RELEASE_ARTIFACT_SHA256' ||
    passkeySignerEvidence?.playAppSigningCertificate?.releaseArtifactType !== 'aab' ||
    passkeySignerEvidence?.playAppSigningCertificate?.immutableFilesRequired !== true ||
    passkeySignerEvidence?.playAppSigningCertificate?.independentlyExportedX509CertificateRequired !== true ||
    passkeySignerEvidence?.playAppSigningCertificate?.certificateFingerprintDerivedFromX509Required !== true ||
    passkeySignerEvidence?.playAppSigningCertificate?.attestationBindsArtifactDigestRequired !== true ||
    passkeySignerEvidence?.playAppSigningCertificate?.attestationBindsCertificateFileDigestRequired !== true ||
    passkeySignerEvidence?.playAppSigningCertificate?.attestationBindsCompiledPackageAndVersionCodeRequired !== true ||
    passkeySignerEvidence?.playAppSigningCertificate?.artifactChangeDetectionRequired !== true) {
  throw new Error('missing exact passkey Android distribution signer evidence handoff')
}
if (!passkeySmokeBlocker?.passkeyProductionContractHandoff?.verificationCommands?.includes('bash scripts/test-passkey-android-origin-parity-audit.sh') ||
    !passkeySmokeBlocker?.passkeyProductionContractHandoff?.verificationCommands?.includes('bash scripts/audit-passkey-android-origin-parity.sh --require-ready')) {
  throw new Error('missing passkey Android origin parity verification handoff')
}
if (!manifest.artifacts.some((artifact) => artifact.path === 'handoffs/passkey-backup-production.json' && artifact.sha256 === passkeySmokeBlocker.passkeyProductionContractHandoff.productionConfigSha256)) {
  throw new Error('missing passkey production config artifact checksum')
}
if (!manifest.artifacts.some((artifact) => artifact.path === 'handoffs/passkey-backup-challenge-service.openapi.json' && artifact.sha256 === passkeySmokeBlocker.passkeyProductionContractHandoff.openApiSha256)) {
  throw new Error('missing passkey OpenAPI artifact checksum')
}
if (!manifest.artifacts.some((artifact) => artifact.path === 'handoffs/passkey-backup-docker-compose.production.yml' && artifact.sha256 === passkeySmokeBlocker.passkeyProductionContractHandoff.composeSha256)) {
  throw new Error('missing passkey production compose artifact checksum')
}
const irohaBlocker = manifest.blockers.find((blocker) => blocker.slug === 'iroha-release-readiness')
if (!irohaBlocker?.evidenceTemplateCommands?.includes('bash scripts/generate-nexus-production-evidence-template.sh --output build/reports/nexus-production-evidence-template.json')) {
  throw new Error('missing Nexus production evidence template command handoff')
}
if (irohaBlocker?.evidenceTemplateHandoff?.destinationManifest !== 'config/nexus-production-evidence.json') {
  throw new Error('missing Nexus production evidence destination manifest handoff')
}
if (irohaBlocker?.nexusProductionEvidenceTemplateHandoff?.templateArtifact !== 'handoffs/nexus-production-evidence-template.json') {
  throw new Error('missing Nexus production evidence template artifact handoff')
}
if (irohaBlocker?.nexusProductionEvidenceTemplateHandoff?.sourceReportPath !== 'nexus-production-evidence-template.json') {
  throw new Error('missing Nexus production evidence template source report handoff')
}
if (irohaBlocker?.nexusProductionEvidenceTemplateHandoff?.generatedTemplatePath !== 'build/reports/nexus-production-evidence-template.json') {
  throw new Error('missing Nexus production evidence generated template path handoff')
}
if (irohaBlocker?.nexusProductionEvidenceTemplateHandoff?.toriiBaseUrl !== 'https://minamoto.sora.org') {
  throw new Error('missing Nexus production evidence Torii URL handoff')
}
if (!irohaBlocker?.nexusProductionEvidenceTemplateHandoff?.requiredEvidenceFields?.includes('routeManifestCommit') ||
    !irohaBlocker.nexusProductionEvidenceTemplateHandoff.requiredEvidenceFields.includes('routeManifestSourcePath') ||
    !irohaBlocker.nexusProductionEvidenceTemplateHandoff.requiredEvidenceFields.includes('routeCanaryAmount')) {
  throw new Error('missing Nexus production evidence canonical artifact/canary fields handoff')
}
if (irohaBlocker?.nexusProductionEvidenceTemplateHandoff?.routePublicationPlaceholder?.routeManifestCommit !== 'TODO_40_HEX_ROUTE_MANIFEST_COMMIT') {
  throw new Error('missing Nexus production evidence route manifest commit placeholder handoff')
}
if (irohaBlocker?.nexusProductionEvidenceTemplateHandoff?.routePublicationPlaceholder?.routeManifestSourcePath !== 'artifacts/nexus/production-route-governance-action.json') {
  throw new Error('missing Nexus canonical route governance action source placeholder handoff')
}
if (irohaBlocker?.nexusProductionEvidenceTemplateHandoff?.routeCanaryPlaceholder?.routeCanaryTransactionHash !== '0xTODO_64_HEX_CANARY_TX_HASH') {
  throw new Error('missing Nexus production evidence canary tx placeholder handoff')
}
if (irohaBlocker?.nexusProductionEvidenceTemplateHandoff?.routeCanaryPlaceholder?.sourceAccount !== 'TODO_NEXUS_CANARY_SOURCE_ACCOUNT' ||
    irohaBlocker.nexusProductionEvidenceTemplateHandoff.routeCanaryPlaceholder.amount !== 'TODO_POSITIVE_DECIMAL_AMOUNT') {
  throw new Error('missing Nexus production evidence bound canary payload placeholder handoff')
}
if (irohaBlocker?.nexusProductionEvidenceTemplateHandoff?.walletSmokePlaceholders?.android?.walletSmokeTransactionHash !== '0xTODO_64_HEX_ANDROID_WALLET_SMOKE_TX_HASH') {
  throw new Error('missing Nexus production evidence Android wallet smoke placeholder handoff')
}
if (!irohaBlocker?.nexusProductionEvidenceTemplateHandoff?.requiredContracts?.includes('walletSmokeEvidence must include android, ios, and web')) {
  throw new Error('missing Nexus production evidence wallet-platform contract handoff')
}
if (!irohaBlocker?.nexusProductionEvidenceTemplateHandoff?.requiredContracts?.includes('routeManifestSourcePath must pin artifacts/nexus/production-route-governance-action.json at routeManifestCommit and routeManifestHash must be recomputed from its canonical ApplySccpRouteGovernance Norito bytes') ||
    !irohaBlocker.nexusProductionEvidenceTemplateHandoff.requiredContracts.includes('ready evidence must verify committed transaction status and exactly one matching instruction through credential-free canonical Minamoto Torii and MCP requests') ||
    !irohaBlocker.nexusProductionEvidenceTemplateHandoff.requiredContracts.includes('self-test receipt fixtures must be temporary and cannot satisfy --require-ready')) {
  throw new Error('missing Nexus canonical receipt-verification contracts handoff')
}
if (irohaBlocker?.nexusProductionEvidenceTemplateHandoff?.readyAuditCommand !== 'bash scripts/audit-nexus-production-evidence.sh --require-ready') {
  throw new Error('missing Nexus production evidence ready audit handoff')
}
if (irohaBlocker?.nexusProductionEvidenceTemplateHandoff?.strictReleaseReadinessCommand !== 'IROHA_NEXUS_REQUIRE_PRODUCTION_EVIDENCE=1 IROHA_NEXUS_LIVE_HEALTH=1 bash scripts/audit-iroha-release-readiness.sh') {
  throw new Error('missing Nexus production evidence strict release-readiness handoff')
}
if (!manifest.artifacts.some((artifact) => artifact.path === 'handoffs/nexus-production-evidence-template.json' && artifact.sha256 === irohaBlocker.nexusProductionEvidenceTemplateHandoff.templateSha256)) {
  throw new Error('missing Nexus production evidence template artifact checksum')
}
if (irohaBlocker?.liveServiceHandoff?.baseUrl !== 'https://minamoto.sora.org') {
  throw new Error('missing Nexus live service base URL handoff')
}
if (irohaBlocker?.liveServiceHandoff?.urlPolicy?.allowedProtocols?.[0] !== 'https') {
  throw new Error('missing Nexus live service HTTPS URL policy handoff')
}
if (irohaBlocker?.liveServiceHandoff?.urlPolicy?.credentials !== 'forbidden') {
  throw new Error('missing Nexus live service credential URL policy handoff')
}
if (irohaBlocker?.liveServiceHandoff?.urlPolicy?.query !== 'forbidden') {
  throw new Error('missing Nexus live service query URL policy handoff')
}
if (irohaBlocker?.liveServiceHandoff?.urlPolicy?.fragment !== 'forbidden') {
  throw new Error('missing Nexus live service fragment URL policy handoff')
}
if (irohaBlocker?.liveServiceHandoff?.urlPolicy?.canonicalInput !== 'use the exact baseUrl; do not append credentials, query strings, or fragments') {
  throw new Error('missing Nexus live service canonical URL policy handoff')
}
if (irohaBlocker?.liveServiceHandoff?.healthPath !== '/status') {
  throw new Error('missing Nexus live service health path handoff')
}
const expectedNexusContracts = [
  'transport uses HTTPS without redirects and returns bounded HTTP 200 application/json',
  'observed_at_ms is no more than 30 seconds ahead or five minutes behind the verifier clock',
  'last_block_committed_at_ms is no more than 30 seconds ahead and within five minutes of the verifier clock',
  'peers is positive and block and transaction-queue counters are coherent',
  'build.git_commit_sha exactly matches the committed NEXUS_EXPECTED_BUILD_COMMIT',
  'nexus.routing_policy exactly matches ordered default 0/0, governance 1/1, and smartcontract::deploy 2/2 routing',
  'dataspace_catalog contains unique unsealed canonical 0/0, 1/1, and 2/2 targets with required manifests ready',
]
if (JSON.stringify(irohaBlocker?.liveServiceHandoff?.expectedContracts) !== JSON.stringify(expectedNexusContracts)) {
  throw new Error('missing Nexus live service health contract handoff')
}
if (irohaBlocker?.liveServiceHandoff?.verificationCommand !== 'IROHA_NEXUS_REQUIRE_PRODUCTION_EVIDENCE=1 IROHA_NEXUS_LIVE_HEALTH=1 bash scripts/audit-iroha-release-readiness.sh') {
  throw new Error('missing Nexus strict verification command handoff')
}
const xcmBlocker = manifest.blockers.find((blocker) => blocker.slug === 'android-xcm-production-evidence')
if (xcmBlocker?.xcmProductionEvidenceTemplateHandoff?.templateArtifact !== 'handoffs/android-xcm-production-evidence-template.json') {
  throw new Error('missing Android XCM production evidence template artifact handoff')
}
if (xcmBlocker?.xcmProductionEvidenceTemplateHandoff?.sourceReportPath !== 'android-xcm-production-evidence-template.json') {
  throw new Error('missing Android XCM production evidence template source report handoff')
}
if (xcmBlocker?.xcmProductionEvidenceTemplateHandoff?.requiredRouteCount !== 2) {
  throw new Error('missing Android XCM production evidence template route count handoff')
}
if (xcmBlocker?.xcmProductionEvidenceTemplateHandoff?.placeholderRecord?.androidCommit !== 'TODO_android_release_commit') {
  throw new Error('missing Android XCM production evidence template androidCommit placeholder handoff')
}
// Real Android generator 24-field export regression.
if (xcmBlocker?.xcmProductionEvidenceTemplateHandoff?.requiredEvidenceFields?.length !== 24 ||
    xcmBlocker.xcmProductionEvidenceTemplateHandoff.requiredEvidenceFields[4] !== 'originBlockHash' ||
    xcmBlocker.xcmProductionEvidenceTemplateHandoff.requiredEvidenceFields[20] !== 'independentVerifier' ||
    xcmBlocker.xcmProductionEvidenceTemplateHandoff.requiredEvidenceFields[23] !== 'androidCommit') {
  throw new Error('real Android generator 24-field export regression failed')
}
if (xcmBlocker.xcmProductionEvidenceTemplateHandoff.placeholderRecord.originFinalized !== false ||
    xcmBlocker.xcmProductionEvidenceTemplateHandoff.placeholderRecord.originExtrinsicSucceeded !== false ||
    xcmBlocker.xcmProductionEvidenceTemplateHandoff.placeholderRecord.destinationEventSucceeded !== false) {
  throw new Error('real Android generator boolean placeholder export regression failed')
}
if (xcmBlocker?.xcmProductionEvidenceTemplateHandoff?.readyAuditCommand !== 'cd fearless-Android && bash scripts/audit-xcm-effective-registry.sh --discovery-url https://raw.githubusercontent.com/soramitsu/shared-features-utils/master/chains/v13/chains.json --require-all-approved --write-report build/reports/xcm-effective-registry-report.json && bash scripts/audit-xcm-production-evidence.sh --effective-registry-report build/reports/xcm-effective-registry-report.json --require-ready') {
  throw new Error('missing Android XCM canonical live ready-audit command handoff')
}
if (!xcmBlocker?.xcmProductionEvidenceTemplateHandoff?.requiredContracts?.includes('template must contain one evidence record per scripts/xcm-required-routes.tsv route')) {
  throw new Error('missing Android XCM production evidence template route-count contract handoff')
}
if (!xcmBlocker?.xcmProductionEvidenceTemplateHandoff?.requiredContracts?.includes('the canonical live effective-registry report must be regenerated and validate complete approved/effective parity before ready evidence can pass')) {
  throw new Error('missing Android XCM canonical live effective-report contract handoff')
}
if (!manifest.artifacts.some((artifact) => artifact.path === 'handoffs/android-xcm-production-evidence-template.json' && artifact.sha256 === xcmBlocker.xcmProductionEvidenceTemplateHandoff.templateSha256)) {
  throw new Error('missing Android XCM production evidence template artifact checksum')
}
if (xcmBlocker?.xcmRegistryHandoff?.gapReportArtifact !== 'handoffs/android-xcm-registry-gap-report.json') {
  throw new Error('missing Android XCM registry gap artifact handoff')
}
if (xcmBlocker?.xcmRegistryHandoff?.sourceReportPath !== 'android-xcm-registry-gap-report.json') {
  throw new Error('missing Android XCM registry source report handoff')
}
if (xcmBlocker?.xcmRegistryHandoff?.remainingDiscoveryOnlyDestinations !== 1) {
  throw new Error('missing Android XCM registry gap count handoff')
}
if (xcmBlocker?.xcmRegistryHandoff?.remainingDiscoveryOnlyRouteAssets !== 2) {
  throw new Error('missing Android XCM registry route-asset gap count handoff')
}
if (xcmBlocker?.xcmRegistryHandoff?.registryAuditCommand !== 'cd fearless-Android && bash scripts/audit-xcm-registry-metadata.sh --require-executable --write-gap-report build/reports/xcm-registry-gap-report.json --require-route-file scripts/xcm-required-routes.tsv --require-gap-file scripts/xcm-discovery-only-routes.tsv --require-all-routes-executable') {
  throw new Error('missing Android XCM registry audit command handoff')
}
if (!xcmBlocker?.xcmRegistryHandoff?.requiredContracts?.includes('missingExecutableDestinations must match scripts/xcm-discovery-only-routes.tsv')) {
  throw new Error('missing Android XCM registry gap contract handoff')
}
if (!xcmBlocker?.xcmRegistryHandoff?.requiredContracts?.includes('summary.remainingDiscoveryOnlyRouteAssets must be zero before broad release')) {
  throw new Error('missing Android XCM registry route-asset zero-gate contract handoff')
}
if (!manifest.artifacts.some((artifact) => artifact.path === 'handoffs/android-xcm-registry-gap-report.json' && artifact.sha256)) {
  throw new Error('missing Android XCM registry gap artifact checksum')
}
const effectiveRegistry = xcmBlocker?.xcmRegistryHandoff?.effectiveRegistry
if (effectiveRegistry?.reportArtifact !== 'handoffs/android-xcm-effective-registry-report.json') {
  throw new Error('missing Android XCM effective-registry artifact handoff')
}
if (effectiveRegistry?.sourceReportPath !== 'android-xcm-effective-registry-report.json') {
  throw new Error('missing Android XCM effective-registry source report handoff')
}
if (effectiveRegistry?.mode !== 'discovery' || effectiveRegistry?.status !== 'incomplete') {
  throw new Error('missing Android XCM live effective-registry mode/status handoff')
}
if (
  effectiveRegistry?.counts?.approved !== 2 ||
  effectiveRegistry?.counts?.effective !== 1 ||
  effectiveRegistry?.counts?.productionExecutable !== 0 ||
  effectiveRegistry?.counts?.missing !== 1 ||
  effectiveRegistry?.counts?.extra !== 1
) {
  throw new Error('missing Android XCM effective-registry count handoff')
}
if (
  effectiveRegistry?.policy?.effectiveRouteMeaning !== 'compatible-approved-candidate' ||
  effectiveRegistry?.policy?.remoteExecutionTrusted !== false ||
  effectiveRegistry?.policy?.productionTransfersEnabled !== false ||
  effectiveRegistry?.policy?.runtimeDiscoveryRole !== 'narrowing-advisory-only' ||
  effectiveRegistry?.policy?.runtimeDiscoveryStorage !== 'current-process-successful-sync-snapshot' ||
  effectiveRegistry?.policy?.runtimeDiscoveryRequiresSuccessfulProcessSync !== true ||
  effectiveRegistry?.policy?.runtimeDiscoverySnapshotBoundToReport !== false ||
  effectiveRegistry?.policy?.runtimeDiscoveryFreshnessEnforced !== false
) {
  throw new Error('missing Android XCM fail-closed effective-registry policy handoff')
}
if (
  effectiveRegistry?.discoveryRegistry?.source !== 'https://raw.githubusercontent.com/soramitsu/shared-features-utils/master/chains/v13/chains.json' ||
  effectiveRegistry?.discoveryRegistry?.byteLength !== 303182 ||
  effectiveRegistry?.discoveryRegistry?.sha256 !== 'fa6f0e23cd87dfb3e5536980591dd22ae30e49bf59d04dc2a0b31fc53237ea66'
) {
  throw new Error('missing Android XCM production discovery identity handoff')
}
if (!effectiveRegistry?.inputContentIdentities?.approvedRoutes?.sha256 || !effectiveRegistry?.inputContentIdentities?.requiredRoutes?.sha256 || !effectiveRegistry?.inputContentIdentities?.bundledRegistry?.sha256) {
  throw new Error('missing Android XCM local input content identities')
}
if (!manifest.artifacts.some((artifact) => artifact.path === effectiveRegistry.reportArtifact && artifact.sha256 === effectiveRegistry.reportSha256)) {
  throw new Error('missing Android XCM effective-registry artifact checksum')
}
const tiSmokeBlocker = manifest.blockers.find((blocker) => blocker.slug === 'ti-production-smoke')
if (tiSmokeBlocker?.liveServiceHandoff?.baseUrl !== 'https://ti.soramitsu.io') {
  throw new Error('missing TI production smoke live base URL handoff')
}
if (tiSmokeBlocker?.liveServiceHandoff?.urlPolicy?.allowedProtocols?.[0] !== 'https') {
  throw new Error('missing TI production smoke HTTPS URL policy handoff')
}
if (tiSmokeBlocker?.liveServiceHandoff?.urlPolicy?.credentials !== 'forbidden') {
  throw new Error('missing TI production smoke credential URL policy handoff')
}
if (tiSmokeBlocker?.liveServiceHandoff?.urlPolicy?.query !== 'forbidden') {
  throw new Error('missing TI production smoke query URL policy handoff')
}
if (tiSmokeBlocker?.liveServiceHandoff?.urlPolicy?.fragment !== 'forbidden') {
  throw new Error('missing TI production smoke fragment URL policy handoff')
}
if (tiSmokeBlocker?.liveServiceHandoff?.urlPolicy?.canonicalInput !== 'use the exact baseUrl; do not append credentials, query strings, or fragments') {
  throw new Error('missing TI production smoke canonical URL policy handoff')
}
if (tiSmokeBlocker?.liveServiceHandoff?.healthPath !== '/api/indexer/v1/health') {
  throw new Error('missing TI production smoke health path handoff')
}
if (tiSmokeBlocker?.liveServiceHandoff?.serviceInfoPath !== '/api/indexer/v1/service-info') {
  throw new Error('missing TI production smoke service-info path handoff')
}
if (tiSmokeBlocker?.liveServiceHandoff?.openApiPath !== '/api/indexer/v1/openapi.json') {
  throw new Error('missing TI production smoke OpenAPI path handoff')
}
if (!tiSmokeBlocker?.liveServiceHandoff?.expectedContracts?.includes('health.lastMasterSeqno present')) {
  throw new Error('missing TI production smoke seqno handoff')
}
if (!tiSmokeBlocker?.liveServiceHandoff?.expectedContracts?.includes('serviceInfo.serviceId=ti.soramitsu.io')) {
  throw new Error('missing TI production smoke service-info service-id handoff')
}
if (!tiSmokeBlocker?.liveServiceHandoff?.expectedContracts?.includes('openapi.info.title=TONSWAP Indexer API')) {
  throw new Error('missing TI production smoke OpenAPI title handoff')
}
if (tiSmokeBlocker?.liveServiceHandoff?.verificationCommand !== 'cd ../ton-indexer && TON_INDEXER_BASE_URL=https://ti.soramitsu.io npm run smoke:production') {
  throw new Error('missing TI production smoke verification command handoff')
}
const siSmokeBlocker = manifest.blockers.find((blocker) => blocker.slug === 'si-production-smoke')
if (siSmokeBlocker?.liveServiceHandoff?.baseUrl !== 'https://si.soramitsu.io') {
  throw new Error('missing SI production smoke live base URL handoff')
}
if (siSmokeBlocker?.liveServiceHandoff?.urlPolicy?.allowedProtocols?.[0] !== 'https') {
  throw new Error('missing SI production smoke HTTPS URL policy handoff')
}
if (siSmokeBlocker?.liveServiceHandoff?.urlPolicy?.credentials !== 'forbidden') {
  throw new Error('missing SI production smoke credential URL policy handoff')
}
if (siSmokeBlocker?.liveServiceHandoff?.urlPolicy?.query !== 'forbidden') {
  throw new Error('missing SI production smoke query URL policy handoff')
}
if (siSmokeBlocker?.liveServiceHandoff?.urlPolicy?.fragment !== 'forbidden') {
  throw new Error('missing SI production smoke fragment URL policy handoff')
}
if (siSmokeBlocker?.liveServiceHandoff?.urlPolicy?.canonicalInput !== 'use the exact baseUrl; do not append credentials, query strings, or fragments') {
  throw new Error('missing SI production smoke canonical URL policy handoff')
}
if (!siSmokeBlocker?.liveServiceHandoff?.expectedContracts?.includes('health.lastMasterSeqno absent')) {
  throw new Error('missing SI production smoke TON-health rejection handoff')
}
if (!siSmokeBlocker?.liveServiceHandoff?.expectedContracts?.includes('openapi.info.title=Solswap Indexer API')) {
  throw new Error('missing SI production smoke OpenAPI title handoff')
}
const piSmokeBlocker = manifest.blockers.find((blocker) => blocker.slug === 'pi-production-smoke')
if (piSmokeBlocker?.liveServiceHandoff?.baseUrl !== 'https://pi.soramitsu.io/graphql') {
  throw new Error('missing PI production smoke live GraphQL URL handoff')
}
if (piSmokeBlocker?.liveServiceHandoff?.urlPolicy?.allowedProtocols?.[0] !== 'https') {
  throw new Error('missing PI production smoke HTTPS URL policy handoff')
}
if (piSmokeBlocker?.liveServiceHandoff?.urlPolicy?.credentials !== 'forbidden') {
  throw new Error('missing PI production smoke credential URL policy handoff')
}
if (piSmokeBlocker?.liveServiceHandoff?.urlPolicy?.query !== 'forbidden') {
  throw new Error('missing PI production smoke query URL policy handoff')
}
if (piSmokeBlocker?.liveServiceHandoff?.urlPolicy?.fragment !== 'forbidden') {
  throw new Error('missing PI production smoke fragment URL policy handoff')
}
if (piSmokeBlocker?.liveServiceHandoff?.urlPolicy?.canonicalInput !== 'use the exact baseUrl; do not append credentials, query strings, or fragments') {
  throw new Error('missing PI production smoke canonical URL policy handoff')
}
if (piSmokeBlocker?.liveServiceHandoff?.healthPath !== 'GraphQL _health') {
  throw new Error('missing PI production smoke GraphQL health handoff')
}
if (!piSmokeBlocker?.liveServiceHandoff?.expectedContracts?.includes('health.serviceId=pi.soramitsu.io')) {
  throw new Error('missing PI production smoke service-id handoff')
}
if (!piSmokeBlocker?.liveServiceHandoff?.expectedContracts?.includes('health.publicBaseUrl=https://pi.soramitsu.io/graphql')) {
  throw new Error('missing PI production smoke public URL handoff')
}
if (!piSmokeBlocker?.liveServiceHandoff?.expectedContracts?.includes('health.genesisHash=0x7e4e32d0feafd4f9c9414b0be86373f9a1efa904809b683453a9af6856d38ad5')) {
  throw new Error('missing PI production smoke exact genesis handoff')
}
if (!piSmokeBlocker?.liveServiceHandoff?.expectedContracts?.includes('health.latestIndexedBlock is a positive safe integer')) {
  throw new Error('missing PI production smoke positive indexed-block handoff')
}
if (!piSmokeBlocker?.liveServiceHandoff?.expectedContracts?.includes('health.latestIndexedBlockHash is a canonical nonzero lowercase 32-byte hash')) {
  throw new Error('missing PI production smoke indexed-block-hash handoff')
}
if (!piSmokeBlocker?.liveServiceHandoff?.expectedContracts?.includes('health.latestIndexedAt is no more than 30 seconds ahead or 300 seconds behind the verifier clock')) {
  throw new Error('missing PI production smoke indexed-at freshness handoff')
}
if (!piSmokeBlocker?.liveServiceHandoff?.expectedContracts?.includes('worker chainIdentity update proves the immutable SORA mainnet genesis')) {
  throw new Error('missing PI production smoke worker chain-identity handoff')
}
if (!piSmokeBlocker?.liveServiceHandoff?.expectedContracts?.includes('worker chainState matches the health checkpoint height, block hash, and block timestamp')) {
  throw new Error('missing PI production smoke worker chain-state handoff')
}
if (!piSmokeBlocker?.liveServiceHandoff?.expectedContracts?.includes('worker BLOCK snapshot id and timestamp match the health checkpoint')) {
  throw new Error('missing PI production smoke worker BLOCK snapshot handoff')
}
if (!piSmokeBlocker?.liveServiceHandoff?.expectedContracts?.includes('TON contract rejected')) {
  throw new Error('missing PI production smoke TON contract rejection handoff')
}
if (piSmokeBlocker?.liveServiceHandoff?.verificationCommand !== 'cd ../polkaswap-indexer && POLKASWAP_INDEXER_BASE_URL=https://pi.soramitsu.io/graphql bash ../fearless/scripts/run-pinned-yarn.sh smoke:production') {
  throw new Error('missing PI production smoke verification command handoff')
}
if (!manifest.artifacts.some((artifact) => artifact.path === 'actions.json' && artifact.sha256)) {
  throw new Error('missing actions artifact checksum')
}
NODE

  node - "$bundle_dir/manifest.json" "$bundle_dir/blockers.md" "$bundle_dir/unblock.md" <<'NODE'
const fs = require('fs')
const [manifestFile, blockersFile, unblockFile] = process.argv.slice(2)
const manifest = JSON.parse(fs.readFileSync(manifestFile, 'utf8'))

function assertBlockerMetadataLineCounts(file, label, entries) {
  const lines = fs.readFileSync(file, 'utf8').split('\n')
  for (const [name, prefix] of entries) {
    const count = lines.filter((line) => line.startsWith(prefix)).length
    if (count !== manifest.blockerCount) {
      throw new Error(`${label} must contain exactly one ${name} line per blocker: ${count} != ${manifest.blockerCount}`)
    }
  }
}

const commonMetadata = [
  ['slug', '- Slug: '],
  ['external-action', '- Requires external action: '],
  ['unblock-category', '- Unblock category: '],
  ['external-prerequisite', '- External prerequisite: '],
]
assertBlockerMetadataLineCounts(blockersFile, 'blockers.md', [
  ...commonMetadata,
  ['exit-code', '- Exit code: '],
  ['log', '- Log: '],
  ['recommended-action', '- Recommended action: '],
  ['verification-command', '- Verification command: '],
])
assertBlockerMetadataLineCounts(unblockFile, 'unblock.md', [
  ...commonMetadata,
  ['log', '- Log: '],
  ['log-sha256', '- Log SHA-256: '],
  ['recommended-action', 'Recommended action:'],
  ['verification-command', 'Verification command:'],
])
NODE

  grep -q 'Get every PR in config/release-readiness-prs.tsv approved' "$bundle_dir/unblock.md" ||
    fail "unblock.md missing recommended action"
  grep -q 'Unblock category: `review-and-merge`' "$bundle_dir/unblock.md" ||
    fail "unblock.md missing release PR unblock category"
  grep -q 'External prerequisite: Reviewer approvals, resolved GitHub review conversations, and protected-branch merges.' "$bundle_dir/unblock.md" ||
    fail "unblock.md missing release PR external prerequisite"
  grep -q './verify-blockers.sh' "$bundle_dir/unblock.md" ||
    fail "unblock.md missing verification script handoff"
  grep -q 'URL policy: protocols `https`, credentials `forbidden`, query `forbidden`, fragment `forbidden`' "$bundle_dir/unblock.md" ||
    fail "unblock.md missing live service URL policy handoff"
  grep -q 'Canonical input: use the exact baseUrl; do not append credentials, query strings, or fragments' "$bundle_dir/unblock.md" ||
    fail "unblock.md missing live service canonical URL handoff"
  grep -q 'Run every blocker verification command from the bundle directory:' "$bundle_dir/unblock.md" ||
    fail "unblock.md missing bundle-directory verification script handoff"
  if grep -q 'Run every blocker verification command from the workspace root:' "$bundle_dir/unblock.md"; then
    fail "unblock.md incorrectly says verify-blockers.sh runs from workspace root"
  fi
  grep -q 'Run one blocker by slug from the bundle directory:' "$bundle_dir/unblock.md" ||
    fail "unblock.md missing bundle-directory single-blocker verification handoff"
  grep -q -- '--max-age-hours 24' "$bundle_dir/unblock.md" ||
    fail "unblock.md missing freshness verification handoff"
  grep -q 'resolve-release-pr-review-threads.sh --dry-run' "$bundle_dir/unblock.md" ||
    fail "unblock.md missing release PR review-thread resolver dry-run handoff"
  grep -q 'PRRT_release_one' "$bundle_dir/unblock.md" ||
    fail "unblock.md missing release PR outdated review-thread ID"
  grep -q 'Release PR approval handoff:' "$bundle_dir/unblock.md" ||
    fail "unblock.md missing release PR approval handoff"
  grep -q 'Release PR status report handoff:' "$bundle_dir/unblock.md" ||
    fail "unblock.md missing release PR status report handoff"
  grep -q 'handoffs/release-pr-readiness-report.json' "$bundle_dir/unblock.md" ||
    fail "unblock.md missing release PR status report artifact"
  grep -q 'soramitsu/fearless-wallet-web#1061' "$bundle_dir/unblock.md" ||
    fail "unblock.md missing release PR status report blocked PR"
  grep -q 'tonswap-org/ton-indexer#9' "$bundle_dir/unblock.md" ||
    fail "unblock.md missing release PR approval-only PR"
  grep -q 'tonswap-org/ton-indexer#10' "$bundle_dir/unblock.md" ||
    fail "unblock.md missing release PR unavailable review-detail PR"
  grep -q 'sora-xor/polkaswap-indexer#1' "$bundle_dir/unblock.md" ||
    fail "unblock.md missing release PR zero-approval unknown-review PR"
  grep -q 'eligible reviewer approval' "$bundle_dir/unblock.md" ||
    fail "unblock.md missing release PR eligible-reviewer approval action"
  grep -q 'restore review details for eligible reviewer approval' "$bundle_dir/unblock.md" ||
    fail "unblock.md missing release PR review-detail fallback action"
  grep -q 'reviewDetails=unavailable' "$bundle_dir/unblock.md" ||
    fail "unblock.md missing release PR unavailable review-detail diagnostic"
  grep -q 'reviewDecision=UNKNOWN; mergeStateStatus=CLEAN; approvalCount=0; currentHeadApprovalCount=0' "$bundle_dir/unblock.md" ||
    fail "unblock.md missing release PR zero-approval unknown-review diagnostics"
  grep -q 'approvalCount=1; currentHeadApprovalCount=1; staleApprovalCount=0; latestApprovalCommit=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa; currentApprovalNotEligible=true' "$bundle_dir/unblock.md" ||
    fail "unblock.md missing release PR approval diagnostics"
  grep -q 'merge-release-prs.sh --dry-run --config config/release-readiness-prs.tsv' "$bundle_dir/unblock.md" ||
    fail "unblock.md missing release PR merge dry-run handoff"
  grep -q 'RELEASE_PR_MERGE_CONFIRM=merge-release-prs bash scripts/merge-release-prs.sh --apply --config config/release-readiness-prs.tsv' "$bundle_dir/unblock.md" ||
    fail "unblock.md missing release PR merge apply handoff"
  grep -q 'yarn generate:bitcoin-broadcast-evidence-template -- --output build/reports/bitcoin-broadcast-evidence-template.json' "$bundle_dir/unblock.md" ||
    fail "unblock.md missing web Bitcoin evidence template command handoff"
  grep -q 'fearless-wallet-web/build/reports/bitcoin-broadcast-evidence-template.json' "$bundle_dir/unblock.md" ||
    fail "unblock.md missing web Bitcoin evidence template output handoff"
  grep -q 'fearless-wallet-web/scripts/bitcoin-testnet-broadcast-evidence.json' "$bundle_dir/unblock.md" ||
    fail "unblock.md missing web Bitcoin evidence destination manifest handoff"
  grep -q 'bash scripts/audit-bitcoin-broadcast-evidence.sh --require-ready' "$bundle_dir/unblock.md" ||
    fail "unblock.md missing web Bitcoin evidence ready audit handoff"
  grep -q 'Required evidence contracts:' "$bundle_dir/unblock.md" ||
    fail "unblock.md missing evidence contract handoff"
  grep -q 'indexerUrl must be https://blockstream.info/testnet/api' "$bundle_dir/unblock.md" ||
    fail "unblock.md missing web Bitcoin canonical indexer contract handoff"
  grep -q 'status.block_time must be present from the indexer' "$bundle_dir/unblock.md" ||
    fail "unblock.md missing web Bitcoin block-time contract handoff"
  grep -q 'Bitcoin broadcast template handoff:' "$bundle_dir/unblock.md" ||
    fail "unblock.md missing web Bitcoin template artifact handoff"
  grep -q 'handoffs/web-bitcoin-broadcast-evidence-template.json' "$bundle_dir/unblock.md" ||
    fail "unblock.md missing web Bitcoin template artifact path"
  grep -q 'Default indexer URL: `https://blockstream.info/testnet/api`' "$bundle_dir/unblock.md" ||
    fail "unblock.md missing web Bitcoin template canonical indexer"
  grep -q 'commit=TODO_40_HEX_GIT_COMMIT' "$bundle_dir/unblock.md" ||
    fail "unblock.md missing web Bitcoin commit placeholder"
  grep -q 'template placeholders must fail --require-ready until funded evidence is recorded' "$bundle_dir/unblock.md" ||
    fail "unblock.md missing web Bitcoin placeholder-failure contract"
  grep -q 'Passkey deployment template handoff:' "$bundle_dir/unblock.md" ||
    fail "unblock.md missing passkey deployment template artifact handoff"
  grep -q 'handoffs/passkey-deployment-evidence-template.json' "$bundle_dir/unblock.md" ||
    fail "unblock.md missing passkey deployment template artifact path"
  grep -q 'deployedCommit=TODO_40_HEX_GIT_COMMIT' "$bundle_dir/unblock.md" ||
    fail "unblock.md missing passkey deployment commit placeholder"
  grep -q 'healthResponse.service must remain fearless-passkey-backup' "$bundle_dir/unblock.md" ||
    fail "unblock.md missing passkey deployment health-service contract"
  grep -q 'Live health attestation target:' "$bundle_dir/unblock.md" ||
    fail "unblock.md missing passkey live-health attestation target"
  grep -q 'payloadSha256=sha256:TODO_CANONICAL_HEALTH_RESPONSE_SHA256' "$bundle_dir/unblock.md" ||
    fail "unblock.md missing passkey canonical health payload target"
  grep -q 'Platform provisioning attestation target:' "$bundle_dir/unblock.md" ||
    fail "unblock.md missing passkey platform-provisioning attestation target"
  grep -q 'payloadSha256=sha256:TODO_CANONICAL_PLATFORM_PROVISIONING_SHA256' "$bundle_dir/unblock.md" ||
    fail "unblock.md missing passkey canonical platform payload target"
  grep -q 'exact 24-hour boundary is accepted and every record is checked independently' "$bundle_dir/unblock.md" ||
    fail "unblock.md missing passkey ready-evidence freshness contract"
  grep -q 'partial or stale records cannot coexist with blockers' "$bundle_dir/unblock.md" ||
    fail "unblock.md missing passkey blocked-evidence contract"
  grep -q 'iosReleaseFlagDisabled=true' "$bundle_dir/unblock.md" ||
    fail "unblock.md missing passkey deployment iOS release flag target"
  grep -q 'cd ../ton-indexer && npm run generate:deployment-evidence-template -- --output build/reports/production-deployment-evidence-template.json' "$bundle_dir/unblock.md" ||
    fail "unblock.md missing TI deployment evidence template command handoff"
  grep -q '../ton-indexer/scripts/production-deployment-evidence.json' "$bundle_dir/unblock.md" ||
    fail "unblock.md missing TI deployment evidence destination manifest handoff"
  grep -q 'handoffs/ti-deployment-evidence-template.json' "$bundle_dir/unblock.md" ||
    fail "unblock.md missing TI deployment template artifact path"
  grep -q 'Service ID: `ti.soramitsu.io`' "$bundle_dir/unblock.md" ||
    fail "unblock.md missing TI deployment template service-id handoff"
  grep -q 'healthInfo.lastMasterSeqno must be replaced with successful production smoke evidence' "$bundle_dir/unblock.md" ||
    fail "unblock.md missing TI deployment template last-master-seqno contract"
  grep -q 'cd ../solswap-indexer && npm run generate:deployment-evidence-template -- --output build/reports/production-deployment-evidence-template.json' "$bundle_dir/unblock.md" ||
    fail "unblock.md missing SI deployment evidence template command handoff"
  grep -q '../solswap-indexer/scripts/production-deployment-evidence.json' "$bundle_dir/unblock.md" ||
    fail "unblock.md missing SI deployment evidence destination manifest handoff"
  grep -q 'handoffs/si-deployment-evidence-template.json' "$bundle_dir/unblock.md" ||
    fail "unblock.md missing SI deployment template artifact path"
  grep -q 'Service ID: `si.soramitsu.io`' "$bundle_dir/unblock.md" ||
    fail "unblock.md missing SI deployment template service-id handoff"
  grep -q 'healthInfo.lastMasterSeqno must remain absent for the Solswap service' "$bundle_dir/unblock.md" ||
    fail "unblock.md missing SI deployment template no-master-seqno contract"
  grep -q 'healthInfo.genesisHash must remain the exact Solana mainnet genesis hash' "$bundle_dir/unblock.md" ||
    fail "unblock.md missing SI deployment template genesis contract"
  grep -q 'healthInfo.latestSlot must be TODO_POSITIVE_LATEST_SLOT in the template and a positive safe integer in ready evidence' "$bundle_dir/unblock.md" ||
    fail "unblock.md missing SI deployment template slot contract"
  grep -q 'healthInfo.syncedAt must be TODO_UNIX_TIMESTAMP_SECONDS in the template and an integer no more than 120 seconds before and no more than 30 seconds after smokePassedAt in ready evidence' "$bundle_dir/unblock.md" ||
    fail "unblock.md missing SI deployment template freshness contract"
  grep -q 'cd ../polkaswap-indexer && bash ../fearless/scripts/run-pinned-yarn.sh generate:deployment-evidence-template --output build/reports/production-deployment-evidence-template.json' "$bundle_dir/unblock.md" ||
    fail "unblock.md missing PI deployment evidence template command handoff"
  grep -q '../polkaswap-indexer/scripts/production-deployment-evidence.json' "$bundle_dir/unblock.md" ||
    fail "unblock.md missing PI deployment evidence destination manifest handoff"
  grep -q 'healthInfo.service=polkaswap-indexer' "$bundle_dir/unblock.md" ||
    fail "unblock.md missing PI deployment evidence health service contract handoff"
  grep -q 'Indexer deployment template handoff:' "$bundle_dir/unblock.md" ||
    fail "unblock.md missing PI deployment template artifact handoff"
  grep -q 'handoffs/pi-deployment-evidence-template.json' "$bundle_dir/unblock.md" ||
    fail "unblock.md missing PI deployment template artifact path"
  grep -q 'Service ID: `pi.soramitsu.io`' "$bundle_dir/unblock.md" ||
    fail "unblock.md missing PI deployment template service-id handoff"
  grep -q 'publicBaseUrl=https://pi.soramitsu.io/graphql' "$bundle_dir/unblock.md" ||
    fail "unblock.md missing PI deployment template public URL target"
  grep -q 'genesisHash=0x7e4e32d0feafd4f9c9414b0be86373f9a1efa904809b683453a9af6856d38ad5' "$bundle_dir/unblock.md" ||
    fail "unblock.md missing PI deployment exact genesis target"
  grep -q 'latestIndexedBlock=TODO_POSITIVE_SAFE_INTEGER_INDEXED_BLOCK' "$bundle_dir/unblock.md" ||
    fail "unblock.md missing PI deployment indexed-block target"
  grep -q 'latestIndexedBlockHash=TODO_0X_64_LOWERCASE_HEX_INDEXED_BLOCK_HASH' "$bundle_dir/unblock.md" ||
    fail "unblock.md missing PI deployment indexed-block-hash target"
  grep -q 'latestIndexedAt=TODO_UNIX_SECONDS_WITHIN_300_BEFORE_OR_30_AFTER_SMOKE' "$bundle_dir/unblock.md" ||
    fail "unblock.md missing PI deployment indexed-at target"
  grep -q 'SORA RPC controls target:' "$bundle_dir/unblock.md" ||
    fail "unblock.md missing PI deployment SORA RPC controls target heading"
  grep -q 'primaryEndpoint=TODO_CANONICAL_WSS_LOCALLY_CONTROLLED_PRIMARY_RPC_ENDPOINT' "$bundle_dir/unblock.md" ||
    fail "unblock.md missing PI deployment primary RPC endpoint target"
  grep -q 'archiveEndpoint=TODO_CANONICAL_WSS_INDEPENDENT_ARCHIVE_RPC_ENDPOINT' "$bundle_dir/unblock.md" ||
    fail "unblock.md missing PI deployment archive RPC endpoint target"
  grep -q 'primaryNodeControl=locally-controlled-verifying-archive' "$bundle_dir/unblock.md" ||
    fail "unblock.md missing PI deployment primary-node control target"
  grep -q 'archiveNodeControl=independently-operated-verifying-archive' "$bundle_dir/unblock.md" ||
    fail "unblock.md missing PI deployment archive-node control target"
  grep -q 'distinctHosts=true' "$bundle_dir/unblock.md" ||
    fail "unblock.md missing PI deployment distinct RPC hosts target"
  grep -q 'exactIdentityPreflight=true' "$bundle_dir/unblock.md" ||
    fail "unblock.md missing PI deployment exact identity preflight target"
  grep -q 'rawPayloadAgreement=height-hash-scale-block-events-timestamp' "$bundle_dir/unblock.md" ||
    fail "unblock.md missing PI deployment raw payload agreement target"
  grep -q 'soraRpcControls must contain exactly the seven reviewed primary/archive trust-boundary fields' "$bundle_dir/unblock.md" ||
    fail "unblock.md missing PI deployment SORA RPC contract"
  grep -q 'template remains blocked until PI production deployment evidence is recorded' "$bundle_dir/unblock.md" ||
    fail "unblock.md missing PI deployment template blocked contract"
  grep -q 'TLS-edge controls target:' "$bundle_dir/unblock.md" ||
    fail "unblock.md missing PI deployment TLS-edge target heading"
  grep -q 'forwardedClientIpHeaders=overwrite' "$bundle_dir/unblock.md" ||
    fail "unblock.md missing PI deployment forwarded-header overwrite target"
  grep -q 'httpClientIpRateLimit={"windowMs":60000,"maxRequests":600}' "$bundle_dir/unblock.md" ||
    fail "unblock.md missing PI deployment HTTP client-IP limit target"
  grep -q 'webSocketClientIpLimits={"windowMs":60000,"maxUpgrades":600,"maxConcurrentConnections":16}' "$bundle_dir/unblock.md" ||
    fail "unblock.md missing PI deployment WebSocket client-IP limit target"
  grep -q 'Nexus production evidence template handoff:' "$bundle_dir/unblock.md" ||
    fail "unblock.md missing Nexus production evidence template artifact handoff"
  grep -q 'handoffs/nexus-production-evidence-template.json' "$bundle_dir/unblock.md" ||
    fail "unblock.md missing Nexus production evidence template artifact path"
  grep -q 'routeManifestCommit=TODO_40_HEX_ROUTE_MANIFEST_COMMIT' "$bundle_dir/unblock.md" ||
    fail "unblock.md missing Nexus route manifest commit placeholder"
  grep -q 'routeManifestSourcePath=artifacts/nexus/production-route-governance-action.json' "$bundle_dir/unblock.md" ||
    fail "unblock.md missing Nexus canonical route governance action source placeholder"
  grep -q 'android: walletCommit=TODO_40_HEX_ANDROID_WALLET_COMMIT; walletSmokeTransactionHash=0xTODO_64_HEX_ANDROID_WALLET_SMOKE_TX_HASH' "$bundle_dir/unblock.md" ||
    fail "unblock.md missing Nexus Android wallet smoke placeholder"
  grep -q 'walletSmokeEvidence must include android, ios, and web' "$bundle_dir/unblock.md" ||
    fail "unblock.md missing Nexus wallet-platform contract"
  grep -q 'ready evidence must verify committed transaction status and exactly one matching instruction' "$bundle_dir/unblock.md" ||
    fail "unblock.md missing Nexus canonical receipt verification contract"
  grep -q 'bash scripts/audit-nexus-production-evidence.sh --require-ready' "$bundle_dir/unblock.md" ||
    fail "unblock.md missing Nexus production evidence ready audit handoff"
  grep -q 'Live service handoff:' "$bundle_dir/unblock.md" ||
    fail "unblock.md missing live service handoff"
  grep -q 'https://backup.fearlesswallet.io' "$bundle_dir/unblock.md" ||
    fail "unblock.md missing passkey production smoke base URL handoff"
  grep -q '/api/passkey-backup/v1/registration/challenge' "$bundle_dir/unblock.md" ||
    fail "unblock.md missing passkey registration challenge route handoff"
  grep -q '/api/passkey-backup/v1/assertion/complete' "$bundle_dir/unblock.md" ||
    fail "unblock.md missing passkey assertion completion route handoff"
  grep -q 'credential_not_registered' "$bundle_dir/unblock.md" ||
    fail "unblock.md missing passkey unregistered credential contract handoff"
  grep -q 'PASSKEY_BACKUP_BASE_URL=https://backup.fearlesswallet.io PASSKEY_BACKUP_SMOKE_GRANT_HELPER=/run/secrets/passkey-smoke-grant-helper PASSKEY_BACKUP_SMOKE_TIMEOUT_MS=10000 npm run smoke:production' "$bundle_dir/unblock.md" ||
    fail "unblock.md missing passkey production smoke verification command handoff"
  grep -q 'Passkey production contract handoff:' "$bundle_dir/unblock.md" ||
    fail "unblock.md missing passkey production contract handoff"
  grep -q 'handoffs/passkey-backup-production.json' "$bundle_dir/unblock.md" ||
    fail "unblock.md missing passkey production config artifact path"
  grep -q 'handoffs/passkey-backup-challenge-service.openapi.json' "$bundle_dir/unblock.md" ||
    fail "unblock.md missing passkey OpenAPI artifact path"
  grep -q 'handoffs/passkey-backup-docker-compose.production.yml' "$bundle_dir/unblock.md" ||
    fail "unblock.md missing passkey production compose artifact path"
  grep -q 'services/passkey-backup-challenge-service/docker-compose.production.yml' "$bundle_dir/unblock.md" ||
    fail "unblock.md missing passkey production compose source path"
  grep -q 'RP ID: `fearlesswallet.io`' "$bundle_dir/unblock.md" ||
    fail "unblock.md missing passkey production contract RP ID"
  grep -q 'production config route paths must match the passkey challenge service OpenAPI paths' "$bundle_dir/unblock.md" ||
    fail "unblock.md missing passkey route contract requirement"
  grep -q 'production Docker Compose must bind 127.0.0.1:8789:8789 and mount passkey-backup-data:/data/passkey-backup' "$bundle_dir/unblock.md" ||
    fail "unblock.md missing passkey production compose contract requirement"
  grep -q 'Request access policy target:' "$bundle_dir/unblock.md" ||
    fail "unblock.md missing passkey request-access policy target"
  grep -q 'Trusted proxy policy target:' "$bundle_dir/unblock.md" ||
    fail "unblock.md missing passkey trusted-proxy policy target"
  grep -q 'android:apk-key-hash:TODO_RELEASE_CERT_SHA256_BASE64URL' "$bundle_dir/unblock.md" ||
    fail "unblock.md missing passkey Android release origin target"
  grep -q 'all seven OpenAPI POST operations must require bearerAuth and expose exact 401, 403, and 503 ErrorResponse references' "$bundle_dir/unblock.md" ||
    fail "unblock.md missing passkey OpenAPI authorization contract"
  grep -q 'bash scripts/audit-passkey-android-origin-parity.sh --require-ready' "$bundle_dir/unblock.md" ||
    fail "unblock.md missing passkey Android origin ready audit command"
  grep -Fq 'distributed-apk must bind PASSKEY_ANDROID_DISTRIBUTED_APK_FILE and PASSKEY_ANDROID_RELEASE_ARTIFACT_SHA256 to one v2/v3 signer and exact package jp.co.soramitsu.fearless' "$bundle_dir/unblock.md" ||
    fail "unblock.md missing passkey signed release origin parity contract"
  grep -q 'Source environment variable: `PASSKEY_ANDROID_RELEASE_SIGNER_EVIDENCE_SOURCE`' "$bundle_dir/unblock.md" ||
    fail "unblock.md missing passkey signer evidence-source environment handoff"
  grep -q 'Allowed sources: `distributed-apk, play-app-signing-certificate`' "$bundle_dir/unblock.md" ||
    fail "unblock.md missing passkey allowed distribution signer sources"
  grep -q 'Rejected evidence types: `aab-upload-key`' "$bundle_dir/unblock.md" ||
    fail "unblock.md missing passkey AAB upload-key rejection handoff"
  grep -q 'Exact package name: `jp.co.soramitsu.fearless`' "$bundle_dir/unblock.md" ||
    fail "unblock.md missing passkey exact Android package handoff"
  grep -q 'artifactFileEnvironmentVariable=PASSKEY_ANDROID_DISTRIBUTED_APK_FILE' "$bundle_dir/unblock.md" ||
    fail "unblock.md missing passkey actual distributed APK handoff"
  grep -q 'exactlyOneSigningCertificateRequired=true' "$bundle_dir/unblock.md" ||
    fail "unblock.md missing passkey single APK signer contract"
  grep -q 'signatureSchemeV2OrV3Required=true' "$bundle_dir/unblock.md" ||
    fail "unblock.md missing passkey APK v2/v3 signer contract"
  grep -q 'certificateFileEnvironmentVariable=PASSKEY_ANDROID_PLAY_APP_SIGNING_CERTIFICATE_FILE' "$bundle_dir/unblock.md" ||
    fail "unblock.md missing passkey immutable Play X.509 certificate handoff"
  grep -q 'attestationSha256EnvironmentVariable=PASSKEY_ANDROID_PLAY_APP_SIGNING_ATTESTATION_SHA256' "$bundle_dir/unblock.md" ||
    fail "unblock.md missing passkey Play attestation digest handoff"
  grep -q 'attestationBindsCompiledPackageAndVersionCodeRequired=true' "$bundle_dir/unblock.md" ||
    fail "unblock.md missing passkey compiled AAB identity binding handoff"
  grep -q 'PASSKEY_BACKUP_LIVE_HEALTH=1 bash scripts/audit-passkey-backup-prerequisites.sh' "$bundle_dir/unblock.md" ||
    fail "unblock.md missing passkey prerequisite verification command"
  grep -q 'https://minamoto.sora.org' "$bundle_dir/unblock.md" ||
    fail "unblock.md missing Nexus live service base URL handoff"
  grep -q 'nexus.routing_policy exactly matches ordered default 0/0, governance 1/1, and smartcontract::deploy 2/2 routing' "$bundle_dir/unblock.md" ||
    fail "unblock.md missing Nexus live service health contract handoff"
  grep -q 'dataspace_catalog contains unique unsealed canonical 0/0, 1/1, and 2/2 targets with required manifests ready' "$bundle_dir/unblock.md" ||
    fail "unblock.md missing Nexus live service dataspace contract handoff"
  grep -q 'IROHA_NEXUS_REQUIRE_PRODUCTION_EVIDENCE=1 IROHA_NEXUS_LIVE_HEALTH=1 bash scripts/audit-iroha-release-readiness.sh' "$bundle_dir/unblock.md" ||
    fail "unblock.md missing Nexus strict verification command handoff"
  grep -q 'Android XCM production evidence template handoff:' "$bundle_dir/unblock.md" ||
    fail "unblock.md missing Android XCM production evidence template handoff"
  grep -q 'handoffs/android-xcm-production-evidence-template.json' "$bundle_dir/unblock.md" ||
    fail "unblock.md missing Android XCM production evidence template artifact handoff"
  grep -q 'Required route count: `2`' "$bundle_dir/unblock.md" ||
    fail "unblock.md missing Android XCM production evidence route count handoff"
  grep -q 'androidCommit.*TODO_android_release_commit' "$bundle_dir/unblock.md" ||
    fail "unblock.md missing Android XCM production evidence androidCommit placeholder handoff"
  grep -q 'template must contain one evidence record per scripts/xcm-required-routes.tsv route' "$bundle_dir/unblock.md" ||
    fail "unblock.md missing Android XCM production evidence route-count contract handoff"
  grep -q 'Android XCM registry handoff:' "$bundle_dir/unblock.md" ||
    fail "unblock.md missing Android XCM registry handoff"
  grep -q 'handoffs/android-xcm-registry-gap-report.json' "$bundle_dir/unblock.md" ||
    fail "unblock.md missing Android XCM registry gap report artifact handoff"
  grep -q 'Remaining discovery-only destinations: `1`' "$bundle_dir/unblock.md" ||
    fail "unblock.md missing Android XCM registry gap count handoff"
  grep -q 'Remaining discovery-only route assets: `2`' "$bundle_dir/unblock.md" ||
    fail "unblock.md missing Android XCM registry route-asset gap count handoff"
  grep -q 'missingExecutableDestinations must match scripts/xcm-discovery-only-routes.tsv' "$bundle_dir/unblock.md" ||
    fail "unblock.md missing Android XCM registry gap contract handoff"
  grep -q 'summary.remainingDiscoveryOnlyRouteAssets must be zero before broad release' "$bundle_dir/unblock.md" ||
    fail "unblock.md missing Android XCM registry route-asset zero-gate contract handoff"
  grep -q 'audit-xcm-registry-metadata.sh --require-executable --write-gap-report build/reports/xcm-registry-gap-report.json' "$bundle_dir/unblock.md" ||
    fail "unblock.md missing Android XCM registry audit command handoff"
  grep -q 'handoffs/android-xcm-effective-registry-report.json' "$bundle_dir/unblock.md" ||
    fail "unblock.md missing Android XCM effective-registry artifact"
  grep -q 'Compatible approved candidates: `1`' "$bundle_dir/unblock.md" ||
    fail "unblock.md missing Android XCM compatible-candidate count"
  grep -q 'Production executable routes: `0`' "$bundle_dir/unblock.md" ||
    fail "unblock.md missing Android XCM production-executable count"
  grep -q 'runtime role `narrowing-advisory-only`; runtime storage `current-process-successful-sync-snapshot`; successful process sync required `true`; snapshot bound `false`; freshness enforced `false`' "$bundle_dir/unblock.md" ||
    fail "unblock.md missing Android XCM runtime snapshot/freshness truth"
  grep -q 'fa6f0e23cd87dfb3e5536980591dd22ae30e49bf59d04dc2a0b31fc53237ea66' "$bundle_dir/unblock.md" ||
    fail "unblock.md missing Android XCM production discovery digest"
  grep -q 'https://ti.soramitsu.io' "$bundle_dir/unblock.md" ||
    fail "unblock.md missing TI production smoke live base URL handoff"
  grep -q '/api/indexer/v1/health' "$bundle_dir/unblock.md" ||
    fail "unblock.md missing TI production smoke health path handoff"
  grep -q 'health.lastMasterSeqno present' "$bundle_dir/unblock.md" ||
    fail "unblock.md missing TI production smoke seqno handoff"
  grep -q 'openapi.info.title=TONSWAP Indexer API' "$bundle_dir/unblock.md" ||
    fail "unblock.md missing TI production smoke OpenAPI title handoff"
  grep -q 'TON_INDEXER_BASE_URL=https://ti.soramitsu.io npm run smoke:production' "$bundle_dir/unblock.md" ||
    fail "unblock.md missing TI production smoke verification command handoff"
  grep -q 'https://si.soramitsu.io' "$bundle_dir/unblock.md" ||
    fail "unblock.md missing SI production smoke live base URL handoff"
  grep -q 'health.lastMasterSeqno absent' "$bundle_dir/unblock.md" ||
    fail "unblock.md missing SI production smoke TON-health rejection handoff"
  grep -q 'openapi.info.title=Solswap Indexer API' "$bundle_dir/unblock.md" ||
    fail "unblock.md missing SI production smoke OpenAPI title handoff"
  grep -q 'https://pi.soramitsu.io/graphql' "$bundle_dir/unblock.md" ||
    fail "unblock.md missing PI production smoke live GraphQL URL handoff"
  grep -q 'GraphQL _health' "$bundle_dir/unblock.md" ||
    fail "unblock.md missing PI production smoke GraphQL health handoff"
  grep -q 'health.serviceId=pi.soramitsu.io' "$bundle_dir/unblock.md" ||
    fail "unblock.md missing PI production smoke service-id handoff"
  grep -q 'health.genesisHash=0x7e4e32d0feafd4f9c9414b0be86373f9a1efa904809b683453a9af6856d38ad5' "$bundle_dir/unblock.md" ||
    fail "unblock.md missing PI production smoke exact genesis handoff"
  grep -q 'health.latestIndexedBlock is a positive safe integer' "$bundle_dir/unblock.md" ||
    fail "unblock.md missing PI production smoke positive indexed-block handoff"
  grep -q 'health.latestIndexedBlockHash is a canonical nonzero lowercase 32-byte hash' "$bundle_dir/unblock.md" ||
    fail "unblock.md missing PI production smoke indexed-block-hash handoff"
  grep -q 'health.latestIndexedAt is no more than 30 seconds ahead or 300 seconds behind the verifier clock' "$bundle_dir/unblock.md" ||
    fail "unblock.md missing PI production smoke indexed-at freshness handoff"
  grep -q 'worker chainIdentity update proves the immutable SORA mainnet genesis' "$bundle_dir/unblock.md" ||
    fail "unblock.md missing PI production smoke worker chain-identity handoff"
  grep -q 'worker chainState matches the health checkpoint height, block hash, and block timestamp' "$bundle_dir/unblock.md" ||
    fail "unblock.md missing PI production smoke worker chain-state handoff"
  grep -q 'worker BLOCK snapshot id and timestamp match the health checkpoint' "$bundle_dir/unblock.md" ||
    fail "unblock.md missing PI production smoke worker BLOCK snapshot handoff"
  grep -q 'TON contract rejected' "$bundle_dir/unblock.md" ||
    fail "unblock.md missing PI production smoke TON contract rejection handoff"
  grep -q 'POLKASWAP_INDEXER_BASE_URL=https://pi.soramitsu.io/graphql bash ../fearless/scripts/run-pinned-yarn.sh smoke:production' "$bundle_dir/unblock.md" ||
    fail "unblock.md missing PI production smoke verification command handoff"
  grep -q 'bash scripts/audit-release-pr-readiness.sh' "$bundle_dir/verify-blockers.sh" ||
    fail "verify-blockers.sh missing release PR verification command"
  grep -q 'release-pr-readiness' "$bundle_dir/verify-blockers.sh" ||
    fail "verify-blockers.sh missing release PR slug"
  grep -q 'logs/release-pr-readiness.log' "$bundle_dir/SHA256SUMS" ||
    fail "SHA256SUMS missing release PR log"
  grep -q 'handoffs/release-pr-readiness-report.json' "$bundle_dir/SHA256SUMS" ||
    fail "SHA256SUMS missing release PR status report"
  grep -q 'handoffs/passkey-backup-production.json' "$bundle_dir/SHA256SUMS" ||
    fail "SHA256SUMS missing passkey production config"
  grep -q 'handoffs/passkey-backup-challenge-service.openapi.json' "$bundle_dir/SHA256SUMS" ||
    fail "SHA256SUMS missing passkey OpenAPI contract"
  grep -q 'handoffs/passkey-backup-docker-compose.production.yml' "$bundle_dir/SHA256SUMS" ||
    fail "SHA256SUMS missing passkey production compose contract"
  grep -q 'verify-blockers.sh' "$bundle_dir/SHA256SUMS" ||
    fail "SHA256SUMS missing verify-blockers.sh"

  local help_output
  if ! help_output="$(RELEASE_UNBLOCK_WORKSPACE_ROOT="$tmp_dir" "$bundle_dir/verify-blockers.sh" --help 2>&1)"; then
    echo "$help_output" >&2
    fail "verify-blockers.sh help mode failed"
  fi
  [[ "$help_output" == *"release-pr-readiness"* ]] ||
    fail "verify-blockers.sh help output missing release PR slug"

  if ! help_output="$(RELEASE_UNBLOCK_WORKSPACE_ROOT="$tmp_dir/missing-workspace" "$bundle_dir/verify-blockers.sh" --help 2>&1)"; then
    echo "$help_output" >&2
    fail "verify-blockers.sh help mode should not require workspace root"
  fi

  local missing_workspace_output
  if missing_workspace_output="$(RELEASE_UNBLOCK_WORKSPACE_ROOT="$tmp_dir/missing-workspace" "$bundle_dir/verify-blockers.sh" release-pr-readiness 2>&1)"; then
    echo "$missing_workspace_output" >&2
    fail "verify-blockers.sh missing workspace root guard should fail"
  fi
  [[ "$missing_workspace_output" == *"Workspace root does not exist: $tmp_dir/missing-workspace"* ]] ||
    fail "verify-blockers.sh missing workspace root guard diagnostic missing"

  local file_workspace="$tmp_dir/workspace-file"
  printf '%s\n' "not a workspace" > "$file_workspace"
  local file_workspace_output
  if file_workspace_output="$(RELEASE_UNBLOCK_WORKSPACE_ROOT="$file_workspace" "$bundle_dir/verify-blockers.sh" release-pr-readiness 2>&1)"; then
    echo "$file_workspace_output" >&2
    fail "verify-blockers.sh file workspace root guard should fail"
  fi
  [[ "$file_workspace_output" == *"Workspace root must be a regular directory: $file_workspace"* ]] ||
    fail "verify-blockers.sh file workspace root guard diagnostic missing"

  local real_workspace_target="$tmp_dir/real-workspace-target"
  local symlink_workspace_root="$tmp_dir/workspace-root-link"
  mkdir -p "$real_workspace_target/scripts"
  printf '%s\n' '# Fearless Universal Wallet Project Plan' > "$real_workspace_target/FEARLESS_PROJECT_PLAN.md"
  printf '%s\n' '#!/usr/bin/env bash' '# Usage: scripts/audit-release-readiness.sh' 'exit 0' > "$real_workspace_target/scripts/audit-release-readiness.sh"
  ln -s "$real_workspace_target" "$symlink_workspace_root"
  local symlink_workspace_root_output
  if symlink_workspace_root_output="$(RELEASE_UNBLOCK_WORKSPACE_ROOT="$symlink_workspace_root" "$bundle_dir/verify-blockers.sh" release-pr-readiness 2>&1)"; then
    echo "$symlink_workspace_root_output" >&2
    fail "verify-blockers.sh symlink workspace root guard should fail"
  fi
  [[ "$symlink_workspace_root_output" == *"Workspace root must be a regular directory: $symlink_workspace_root"* ]] ||
    fail "verify-blockers.sh symlink workspace root guard diagnostic missing"

  local real_workspace_parent="$tmp_dir/verify-script-real-workspace-parent"
  local symlink_workspace_parent="$tmp_dir/verify-script-workspace-parent-link"
  mkdir -p "$real_workspace_parent/fearless/scripts"
  printf '%s\n' '# Fearless Universal Wallet Project Plan' > "$real_workspace_parent/fearless/FEARLESS_PROJECT_PLAN.md"
  printf '%s\n' '#!/usr/bin/env bash' '# Usage: scripts/audit-release-readiness.sh' 'exit 0' > "$real_workspace_parent/fearless/scripts/audit-release-readiness.sh"
  chmod +x "$real_workspace_parent/fearless/scripts/audit-release-readiness.sh"
  ln -s "$real_workspace_parent" "$symlink_workspace_parent"
  local symlink_parent_workspace_root_output
  if symlink_parent_workspace_root_output="$(RELEASE_UNBLOCK_WORKSPACE_ROOT="$symlink_workspace_parent/fearless" "$bundle_dir/verify-blockers.sh" release-pr-readiness 2>&1)"; then
    echo "$symlink_parent_workspace_root_output" >&2
    fail "verify-blockers.sh symlink-parent workspace root guard should fail"
  fi
  [[ "$symlink_parent_workspace_root_output" == *"Workspace root must not use a symlinked path component"* ]] ||
    fail "verify-blockers.sh symlink-parent workspace root guard diagnostic missing"

  local wrong_workspace="$tmp_dir/not-fearless"
  mkdir -p "$wrong_workspace/scripts"
  local wrong_workspace_output
  if wrong_workspace_output="$(RELEASE_UNBLOCK_WORKSPACE_ROOT="$wrong_workspace" "$bundle_dir/verify-blockers.sh" release-pr-readiness 2>&1)"; then
    echo "$wrong_workspace_output" >&2
    fail "verify-blockers.sh wrong workspace root guard should fail"
  fi
  [[ "$wrong_workspace_output" == *"Workspace root is not a Fearless workspace: $wrong_workspace"* ]] ||
    fail "verify-blockers.sh wrong workspace root guard diagnostic missing"

  local symlink_marker_workspace="$tmp_dir/symlink-marker-workspace"
  mkdir -p "$symlink_marker_workspace/scripts"
  printf '%s\n' '# Fearless symlink marker target' > "$tmp_dir/plan-marker-target.md"
  printf '%s\n' '#!/usr/bin/env bash' 'exit 0' > "$tmp_dir/audit-marker-target.sh"
  ln -s "$tmp_dir/plan-marker-target.md" "$symlink_marker_workspace/FEARLESS_PROJECT_PLAN.md"
  ln -s "$tmp_dir/audit-marker-target.sh" "$symlink_marker_workspace/scripts/audit-release-readiness.sh"
  local symlink_marker_workspace_output
  if symlink_marker_workspace_output="$(RELEASE_UNBLOCK_WORKSPACE_ROOT="$symlink_marker_workspace" "$bundle_dir/verify-blockers.sh" release-pr-readiness 2>&1)"; then
    echo "$symlink_marker_workspace_output" >&2
    fail "verify-blockers.sh symlink marker workspace guard should fail"
  fi
  [[ "$symlink_marker_workspace_output" == *"Workspace root is not a Fearless workspace: $symlink_marker_workspace"* ]] ||
    fail "verify-blockers.sh symlink marker workspace guard diagnostic missing"

  local placeholder_plan_workspace="$tmp_dir/placeholder-plan-workspace"
  mkdir -p "$placeholder_plan_workspace/scripts"
  printf '%s\n' '# Fearless test workspace' > "$placeholder_plan_workspace/FEARLESS_PROJECT_PLAN.md"
  printf '%s\n' '#!/usr/bin/env bash' '# Usage: scripts/audit-release-readiness.sh' 'exit 0' > "$placeholder_plan_workspace/scripts/audit-release-readiness.sh"
  local placeholder_plan_workspace_output
  if placeholder_plan_workspace_output="$(RELEASE_UNBLOCK_WORKSPACE_ROOT="$placeholder_plan_workspace" "$bundle_dir/verify-blockers.sh" release-pr-readiness 2>&1)"; then
    echo "$placeholder_plan_workspace_output" >&2
    fail "verify-blockers.sh placeholder plan marker workspace guard should fail"
  fi
  [[ "$placeholder_plan_workspace_output" == *"Workspace root marker content mismatch: $placeholder_plan_workspace"* ]] ||
    fail "verify-blockers.sh placeholder plan marker workspace guard diagnostic missing"

  local placeholder_audit_workspace="$tmp_dir/placeholder-audit-workspace"
  mkdir -p "$placeholder_audit_workspace/scripts"
  printf '%s\n' '# Fearless Universal Wallet Project Plan' > "$placeholder_audit_workspace/FEARLESS_PROJECT_PLAN.md"
  printf '%s\n' '#!/usr/bin/env bash' 'exit 0' > "$placeholder_audit_workspace/scripts/audit-release-readiness.sh"
  local placeholder_audit_workspace_output
  if placeholder_audit_workspace_output="$(RELEASE_UNBLOCK_WORKSPACE_ROOT="$placeholder_audit_workspace" "$bundle_dir/verify-blockers.sh" release-pr-readiness 2>&1)"; then
    echo "$placeholder_audit_workspace_output" >&2
    fail "verify-blockers.sh placeholder audit marker workspace guard should fail"
  fi
  [[ "$placeholder_audit_workspace_output" == *"Workspace root marker content mismatch: $placeholder_audit_workspace"* ]] ||
    fail "verify-blockers.sh placeholder audit marker workspace guard diagnostic missing"

  local nonexec_audit_workspace="$tmp_dir/nonexec-audit-workspace"
  mkdir -p "$nonexec_audit_workspace/scripts"
  printf '%s\n' '# Fearless Universal Wallet Project Plan' > "$nonexec_audit_workspace/FEARLESS_PROJECT_PLAN.md"
  printf '%s\n' '#!/usr/bin/env bash' '# Usage: scripts/audit-release-readiness.sh' 'exit 0' > "$nonexec_audit_workspace/scripts/audit-release-readiness.sh"
  chmod 0644 "$nonexec_audit_workspace/scripts/audit-release-readiness.sh"
  local nonexec_audit_workspace_output
  if nonexec_audit_workspace_output="$(RELEASE_UNBLOCK_WORKSPACE_ROOT="$nonexec_audit_workspace" "$bundle_dir/verify-blockers.sh" release-pr-readiness 2>&1)"; then
    echo "$nonexec_audit_workspace_output" >&2
    fail "verify-blockers.sh non-executable audit marker workspace guard should fail"
  fi
  [[ "$nonexec_audit_workspace_output" == *"Workspace root audit marker must be executable: $nonexec_audit_workspace/scripts/audit-release-readiness.sh"* ]] ||
    fail "verify-blockers.sh non-executable audit marker workspace guard diagnostic missing"

  local unknown_slug_output
  if unknown_slug_output="$(RELEASE_UNBLOCK_WORKSPACE_ROOT="$tmp_dir/missing-workspace" "$bundle_dir/verify-blockers.sh" not-a-blocker 2>&1)"; then
    echo "$unknown_slug_output" >&2
    fail "verify-blockers.sh unknown slug should fail"
  fi
  [[ "$unknown_slug_output" == *"Unknown blocker slug: not-a-blocker"* ]] ||
    fail "verify-blockers.sh unknown slug diagnostic missing"
  if [[ "$unknown_slug_output" == *"Workspace root does not exist"* ]]; then
    echo "$unknown_slug_output" >&2
    fail "verify-blockers.sh unknown slug should not require workspace root"
  fi

  local fake_workspace="$tmp_dir/workspace"
  local fake_solswap="$tmp_dir/solswap-indexer"
  local fake_bin="$tmp_dir/fake-bin"
  mkdir -p "$fake_workspace/scripts" "$fake_solswap" "$fake_bin"
  printf '%s\n' '# Fearless Universal Wallet Project Plan' > "$fake_workspace/FEARLESS_PROJECT_PLAN.md"
  printf '%s\n' '#!/usr/bin/env bash' '# Usage: scripts/audit-release-readiness.sh' 'exit 0' > "$fake_workspace/scripts/audit-release-readiness.sh"
  chmod +x "$fake_workspace/scripts/audit-release-readiness.sh"
cat > "$fake_workspace/scripts/audit-release-pr-readiness.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
if [[ -n "${RELEASE_UNBLOCK_PARTIAL_MARKER:-}" ]]; then
  printf '%s\n' "release-pr-readiness-ran" > "$RELEASE_UNBLOCK_PARTIAL_MARKER"
fi
if [[ "$PWD" != "$RELEASE_UNBLOCK_WORKSPACE_ROOT" ]]; then
  echo "release PR audit did not start from workspace root: $PWD" >&2
  exit 1
fi
if [[ "${RELEASE_UNBLOCK_FORCE_RELEASE_PR_FAIL:-}" == "1" ]]; then
  echo "forced release PR failure" >&2
  exit 42
fi
SH
  chmod +x "$fake_workspace/scripts/audit-release-pr-readiness.sh"
  cat > "$fake_bin/npm" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
expected="$(cd "$RELEASE_UNBLOCK_WORKSPACE_ROOT/../solswap-indexer" && pwd)"
if [[ "$PWD" != "$expected" ]]; then
  echo "fake npm did not run from solswap-indexer: $PWD" >&2
  exit 1
fi
if [[ "$*" != "run smoke:production" ]]; then
  echo "unexpected fake npm args: $*" >&2
  exit 1
fi
if [[ "${SOLSWAP_INDEXER_BASE_URL:-}" != "https://si.soramitsu.io" ]]; then
  echo "missing SOLSWAP_INDEXER_BASE_URL" >&2
  exit 1
fi
if [[ -n "${RELEASE_UNBLOCK_NPM_MARKER:-}" ]]; then
  printf '%s\n' "npm-ran" > "$RELEASE_UNBLOCK_NPM_MARKER"
fi
SH
  chmod +x "$fake_bin/npm"

  local partial_marker="$tmp_dir/partial-run-marker"
  local partial_output
  if partial_output="$(PATH="$fake_bin:$PATH" RELEASE_UNBLOCK_WORKSPACE_ROOT="$fake_workspace" RELEASE_UNBLOCK_PARTIAL_MARKER="$partial_marker" "$bundle_dir/verify-blockers.sh" release-pr-readiness not-a-blocker 2>&1)"; then
    echo "$partial_output" >&2
    fail "verify-blockers.sh mixed known and unknown slug should fail"
  fi
  [[ "$partial_output" == *"Unknown blocker slug: not-a-blocker"* ]] ||
    fail "verify-blockers.sh mixed slug prevalidation diagnostic missing"
  [[ ! -e "$partial_marker" ]] ||
    fail "verify-blockers.sh mixed slug prevalidation allowed partial execution"

  local aggregate_marker="$tmp_dir/aggregate-npm-marker"
  local aggregate_output
  if aggregate_output="$(PATH="$fake_bin:$PATH" RELEASE_UNBLOCK_WORKSPACE_ROOT="$fake_workspace" RELEASE_UNBLOCK_FORCE_RELEASE_PR_FAIL=1 RELEASE_UNBLOCK_NPM_MARKER="$aggregate_marker" "$bundle_dir/verify-blockers.sh" release-pr-readiness si-production-smoke 2>&1)"; then
    echo "$aggregate_output" >&2
    fail "verify-blockers.sh failure aggregation should fail after running requested blockers"
  fi
  [[ "$aggregate_output" == *"Blocker verification failed: release-pr-readiness"* ]] ||
    fail "verify-blockers.sh failure aggregation missing failed blocker diagnostic"
  [[ "$aggregate_output" == *"1 blocker verification command(s) failed: release-pr-readiness"* ]] ||
    fail "verify-blockers.sh failure aggregation summary missing"
  [[ -e "$aggregate_marker" ]] ||
    fail "verify-blockers.sh failure aggregation skipped later blocker"

  local run_output
  if ! run_output="$(PATH="$fake_bin:$PATH" RELEASE_UNBLOCK_WORKSPACE_ROOT="$fake_workspace" "$bundle_dir/verify-blockers.sh" si-production-smoke release-pr-readiness 2>&1)"; then
    echo "$run_output" >&2
    fail "verify-blockers.sh must reset cwd between blocker commands"
  fi
}

set_release_pr_backtick_evidence_fixture() {
  node - "$report_dir/actions.json" "$report_dir/release-pr-readiness.log" "$report_dir/blockers.md" <<'NODE'
const fs = require('fs')
const [actionsFile, logFile, blockersFile] = process.argv.slice(2)
const evidencePreview = '```'
const actions = JSON.parse(fs.readFileSync(actionsFile, 'utf8'))
actions.blockers[0].evidencePreview = evidencePreview
fs.writeFileSync(actionsFile, JSON.stringify(actions, null, 2))
fs.appendFileSync(logFile, `\n${evidencePreview}\n`)

const oldBlock = 'Evidence preview:\n\n```text\nsolswap-io/solswap-indexer#8 is open\n```\n'
const newBlock = 'Evidence preview:\n\n````text\n```\n````\n'
const markdown = fs.readFileSync(blockersFile, 'utf8')
if (!markdown.includes(oldBlock)) throw new Error('release PR evidence preview block not found')
fs.writeFileSync(blockersFile, markdown.replace(oldBlock, newBlock))
NODE
}

set_release_pr_capped_evidence_fixture() {
  node - "$report_dir/actions.json" "$report_dir/blockers.md" <<'NODE'
const fs = require('fs')
const [actionsFile, blockersFile] = process.argv.slice(2)
const evidencePreview = '[line capped to final 59 characters; see full log]\nunresolvedReviewThreadIds=PRRT_release_one,PRRT_release_two'
const actions = JSON.parse(fs.readFileSync(actionsFile, 'utf8'))
actions.blockers[0].evidencePreview = evidencePreview
fs.writeFileSync(actionsFile, JSON.stringify(actions, null, 2))

const oldBlock = 'Evidence preview:\n\n```text\nsolswap-io/solswap-indexer#8 is open\n```\n'
const newBlock = `Evidence preview:\n\n\`\`\`text\n${evidencePreview}\n\`\`\`\n`
const markdown = fs.readFileSync(blockersFile, 'utf8')
if (!markdown.includes(oldBlock)) throw new Error('release PR evidence preview block not found')
fs.writeFileSync(blockersFile, markdown.replace(oldBlock, newBlock))
NODE
}

assert_capped_evidence_preview_preserved() {
  node - "$bundle_dir/blockers.md" "$bundle_dir/unblock.md" <<'NODE'
const fs = require('fs')
const expected = '[line capped to final 59 characters; see full log]\nunresolvedReviewThreadIds=PRRT_release_one,PRRT_release_two'
for (const file of process.argv.slice(2)) {
  const content = fs.readFileSync(file, 'utf8')
  if (!content.includes(expected)) {
    throw new Error(`${file} missing capped evidence preview`)
  }
}
NODE
}

assert_safe_evidence_markdown_fence() {
  node - "$bundle_dir/blockers.md" "$bundle_dir/unblock.md" <<'NODE'
const fs = require('fs')
for (const file of process.argv.slice(2)) {
  const content = fs.readFileSync(file, 'utf8')
  if (!content.includes('````text\n```\n````')) {
    throw new Error(`${file} missing safe four-backtick evidence fence`)
  }
  const lines = content.split('\n')
  if (lines.some((line, index) => line === '```text' && lines[index + 1] === '```' && lines[index + 2] === '```')) {
    throw new Error(`${file} used unsafe fixed three-backtick evidence fence`)
  }
}
NODE
}

set_release_pr_dangling_capped_evidence_fixture() {
  node - "$report_dir/actions.json" <<'NODE'
const fs = require('fs')
const file = process.argv[2]
const data = JSON.parse(fs.readFileSync(file, 'utf8'))
data.blockers[0].evidencePreview = 'solswap-io/solswap-indexer#8 is open\n[line capped to final 59 characters; see full log]'
fs.writeFileSync(file, JSON.stringify(data, null, 2))
NODE
}

set_release_pr_wrong_length_capped_evidence_fixture() {
  node - "$report_dir/actions.json" <<'NODE'
const fs = require('fs')
const file = process.argv[2]
const data = JSON.parse(fs.readFileSync(file, 'utf8'))
data.blockers[0].evidencePreview = '[line capped to final 58 characters; see full log]\nunresolvedReviewThreadIds=PRRT_release_one,PRRT_release_two'
fs.writeFileSync(file, JSON.stringify(data, null, 2))
NODE
}

rewrite_release_pr_evidence_to_unsafe_fixed_fence() {
  node - "$report_dir/blockers.md" <<'NODE'
const fs = require('fs')
const file = process.argv[2]
const safeBlock = 'Evidence preview:\n\n````text\n```\n````\n'
const unsafeBlock = 'Evidence preview:\n\n```text\n```\n```\n'
const markdown = fs.readFileSync(file, 'utf8')
if (!markdown.includes(safeBlock)) throw new Error('safe release PR evidence fence not found')
fs.writeFileSync(file, markdown.replace(safeBlock, unsafeBlock))
NODE
}

write_fixture
mkdir -p "$bundle_dir"
printf '%s\n' stale > "$bundle_dir/stale.txt"
SOURCE_PUBLICATION_SNAPSHOT_PATHS="$report_dir/source-publication-readiness-report.json|$report_dir/source-publication-preflight-report.json|$workspace_dir/config/source-publication-readiness.tsv|$workspace_dir/config/source-publication-root-owner.json" \
  SOURCE_PUBLICATION_SNAPSHOT_PROCESS_ARG="$report_dir" \
  NODE_OPTIONS="--require=$single_snapshot_preload" \
expect_success "valid fixture"
assert_success_bundle
assert_no_bundle_temp_dirs

# A failure discovered after most handoffs have been copied must leave an
# already-valid published bundle byte-for-byte unchanged.
preserved_bundle_snapshot="$tmp_dir/preserved-valid-bundle"
rm -rf "$preserved_bundle_snapshot"
cp -R "$bundle_dir" "$preserved_bundle_snapshot"
rm "$report_dir/pi-production-smoke.log"
expect_failure "late validation preserves existing valid bundle fixture" "pi-production-smoke.logFile missing"
if ! diff -r "$preserved_bundle_snapshot" "$bundle_dir" >/dev/null; then
  diff -r "$preserved_bundle_snapshot" "$bundle_dir" >&2 || true
  fail "late validation failure changed the existing valid bundle"
fi
assert_no_bundle_temp_dirs

# The same late failure with no prior output must not expose even a partial
# final directory and must clean the private staging directory.
write_fixture
rm "$report_dir/pi-production-smoke.log"
expect_failure "late validation publishes no partial bundle fixture" "pi-production-smoke.logFile missing"
[[ ! -e "$bundle_dir" ]] || fail "late validation failure published a partial bundle"
assert_no_bundle_temp_dirs

# A same-user tamper of a staged artifact after SHA256SUMS construction is
# detected by a full checksum recomputation before the publication rename.
write_fixture
staging_tamper_exporter="$tmp_dir/export-release-unblock-bundle-staging-tamper.sh"
cp "$EXPORT_SCRIPT" "$staging_tamper_exporter"
node - "$staging_tamper_exporter" <<'NODE'
const fs = require('fs')
const file = process.argv[2]
const source = fs.readFileSync(file, 'utf8')
const needle = '\nvalidateStagedBundleForPublication()\npublishStagedBundle()\n'
const replacement = "\nfs.appendFileSync(path.join(outputRoot, 'summary.json'), 'tampered\\n')\nvalidateStagedBundleForPublication()\npublishStagedBundle()\n"
if (!source.includes(needle)) throw new Error('publication call site not found')
fs.writeFileSync(file, source.replace(needle, replacement))
NODE
expect_failure_with_export_script "staged artifact checksum tamper fixture" "$staging_tamper_exporter" "staged bundle content changed before publication"
[[ ! -e "$bundle_dir" ]] || fail "staged artifact tamper published a partial bundle"
assert_no_bundle_temp_dirs

# Exercise the signal cleanup path deterministically after the complete staged
# bundle has validated but before publication.
write_fixture
signal_exporter="$tmp_dir/export-release-unblock-bundle-signal.sh"
cp "$EXPORT_SCRIPT" "$signal_exporter"
node - "$signal_exporter" <<'NODE'
const fs = require('fs')
const file = process.argv[2]
const source = fs.readFileSync(file, 'utf8')
const needle = '\nvalidateStagedBundleForPublication()\npublishStagedBundle()\n'
if (!source.includes(needle)) throw new Error('publication call site not found')
fs.writeFileSync(file, source.replace(needle, '\nvalidateStagedBundleForPublication()\nprocess.emit(\'SIGTERM\')\npublishStagedBundle()\n'))
NODE
expect_failure_with_export_script "signal before publication fixture" "$signal_exporter" "interrupted by SIGTERM"
[[ ! -e "$bundle_dir" ]] || fail "signal before publication exposed a partial bundle"
assert_no_bundle_temp_dirs

# If the publication rename itself fails after the old directory was moved to
# the private backup, the transaction must roll the prior output back.
write_fixture
expect_success "publication rollback baseline fixture"
rollback_bundle_snapshot="$tmp_dir/publication-rollback-bundle"
rm -rf "$rollback_bundle_snapshot"
cp -R "$bundle_dir" "$rollback_bundle_snapshot"
publication_failure_exporter="$tmp_dir/export-release-unblock-bundle-publication-failure.sh"
cp "$EXPORT_SCRIPT" "$publication_failure_exporter"
node - "$publication_failure_exporter" <<'NODE'
const fs = require('fs')
const file = process.argv[2]
const source = fs.readFileSync(file, 'utf8')
const needle = '    fs.renameSync(staged.path, finalOutputRoot)\n'
if (!source.includes(needle)) throw new Error('publication rename not found')
fs.writeFileSync(file, source.replace(needle, "    throw new Error('injected publication rename failure')\n"))
NODE
expect_failure_with_export_script "publication rename rollback fixture" "$publication_failure_exporter" "injected publication rename failure"
if ! diff -r "$rollback_bundle_snapshot" "$bundle_dir" >/dev/null; then
  diff -r "$rollback_bundle_snapshot" "$bundle_dir" >&2 || true
  fail "publication rename failure did not restore the prior bundle"
fi
assert_no_bundle_temp_dirs

# A concurrent regular-directory replacement between validation and publish is
# detected by inode identity and is never overwritten by the exporter.
write_fixture
mkdir -p "$bundle_dir"
printf '%s\n' original > "$bundle_dir/original.txt"
output_race_exporter="$tmp_dir/export-release-unblock-bundle-output-race.sh"
cp "$EXPORT_SCRIPT" "$output_race_exporter"
node - "$output_race_exporter" <<'NODE'
const fs = require('fs')
const file = process.argv[2]
const source = fs.readFileSync(file, 'utf8')
const needle = 'validateStagedBundleForPublication()\npublishStagedBundle()'
const replacement = `validateStagedBundleForPublication()
fs.renameSync(finalOutputRoot, finalOutputRoot + '.raced-original')
fs.mkdirSync(finalOutputRoot)
fs.writeFileSync(path.join(finalOutputRoot, 'concurrent.txt'), 'concurrent output\\n')
publishStagedBundle()`
if (!source.includes(needle)) throw new Error('publication call site not found')
fs.writeFileSync(file, source.replace(needle, replacement))
NODE
expect_failure_with_export_script "concurrent output replacement fixture" "$output_race_exporter" "output dir changed during bundle construction"
[[ "$(cat "$bundle_dir/concurrent.txt")" == "concurrent output" ]] || fail "exporter overwrote a concurrent output replacement"
[[ "$(cat "$bundle_dir.raced-original/original.txt")" == "original" ]] || fail "concurrent output race fixture lost the original directory"
assert_no_bundle_temp_dirs
rm -rf "$bundle_dir.raced-original"

# A symlink introduced at the final name after staging is likewise rejected;
# its target report remains untouched.
write_fixture
output_symlink_race_exporter="$tmp_dir/export-release-unblock-bundle-output-symlink-race.sh"
cp "$EXPORT_SCRIPT" "$output_symlink_race_exporter"
node - "$output_symlink_race_exporter" <<'NODE'
const fs = require('fs')
const file = process.argv[2]
const source = fs.readFileSync(file, 'utf8')
const needle = 'validateStagedBundleForPublication()\npublishStagedBundle()'
const replacement = `validateStagedBundleForPublication()
fs.symlinkSync(reportRoot, finalOutputRoot)
publishStagedBundle()`
if (!source.includes(needle)) throw new Error('publication call site not found')
fs.writeFileSync(file, source.replace(needle, replacement))
NODE
expect_failure_with_export_script "concurrent output symlink fixture" "$output_symlink_race_exporter" "output dir must not use a symlinked path component"
[[ -L "$bundle_dir" ]] || fail "concurrent output symlink fixture did not preserve the raced path"
[[ -f "$report_dir/summary.json" ]] || fail "concurrent output symlink race damaged the source report"
assert_no_bundle_temp_dirs
rm "$bundle_dir"

# Both exact plan-readiness contracts are accepted, but the external variant is
# only valid when the source log proves every failure belongs to ../iroha.
write_fixture
set_plan_readiness_blocker_fixture external
expect_success "exact external-Iroha-only plan blocker fixture"
node - "$bundle_dir/manifest.json" <<'NODE'
const fs = require('fs')
const manifest = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'))
const blocker = manifest.blockers.find((item) => item.slug === 'plan-readiness')
if (!blocker) throw new Error('external plan blocker missing from manifest')
if (blocker.recommendedAction !== 'Do not edit or publish from the unsafe external ../iroha checkout. Have its owner resolve any in-progress Git operation or unmerged index state and restore every reported Iroha source and browser-artifact contract on a stable reviewed commit, then rerun bash scripts/audit-plan-readiness.sh.') {
  throw new Error('external plan recommended action drift')
}
if (blocker.requiresExternalAction !== true || blocker.unblockCategory !== 'upstream-dependency') {
  throw new Error('external plan unblock classification drift')
}
if (blocker.externalPrerequisite !== 'Owner-coordinated resolution of the unsafe external ../iroha source state, followed by a stable reviewed checkout containing every audited Iroha source and browser-artifact contract.') {
  throw new Error('external plan prerequisite drift')
}
NODE
assert_no_bundle_temp_dirs

write_fixture
set_plan_readiness_blocker_fixture external
edit_source_publication_report "const iroha = data.repositories.find((row) => row.path === '../iroha'); iroha.stagedCount = 0; iroha.unmergedCount = 2; iroha.failures = ['worktree is not clean (staged=0, unstaged=0, untracked=0, unmerged=2)']; data.totals.staged = 0; data.totals.unmerged = 2"
expect_success "unmerged-Iroha-only plan blocker fixture"
assert_no_bundle_temp_dirs

write_fixture
set_plan_readiness_blocker_fixture external-reviewed-source
expect_success "reviewed-source-mismatch Iroha-only plan blocker fixture"
assert_no_bundle_temp_dirs

write_fixture
set_plan_readiness_blocker_fixture external-reviewed-source
expect_success "reviewed-source postflight preflight-continuity marker fixture"
assert_no_bundle_temp_dirs

write_fixture
set_plan_readiness_blocker_fixture external-reviewed-source
set_reviewed_source_authoritative_current_drift_fixture
expect_success "reviewed-source authoritative-current drift live-shape fixture"
assert_no_bundle_temp_dirs

write_fixture
set_plan_readiness_blocker_fixture external-reviewed-source
set_reviewed_source_authoritative_current_drift_fixture
edit_source_publication_report "const iroha = data.repositories.find((row) => row.path === '../iroha'); iroha.currentBranchRemoteSha = iroha.prHeadSha; iroha.failures[2] = 'local HEAD ' + iroha.headSha + ' does not match authoritative current branch ' + iroha.branch + ' at ' + iroha.currentBranchRemoteSha; iroha.failures[5] = 'cached upstream ' + iroha.upstream + ' at ' + iroha.upstreamSha + ' does not match authoritative current branch ' + iroha.branch + ' at ' + iroha.currentBranchRemoteSha"
expect_success "reviewed-source authoritative-current equals pull-request head drift fixture"
assert_no_bundle_temp_dirs

write_fixture
set_plan_readiness_blocker_fixture external-reviewed-source
set_reviewed_source_authoritative_current_drift_fixture
edit_source_publication_report "const iroha = data.repositories.find((row) => row.path === '../iroha'); iroha.prHeadSha = iroha.headSha; iroha.failures[3] = 'local HEAD ' + iroha.headSha + ' does not match pull request head ' + iroha.prHeadSha"
expect_failure "reviewed-source authoritative-current drift pull-request head equals local fixture" "plan-readiness unblock contract variant must match plan-readiness log classification"

write_fixture
set_plan_readiness_blocker_fixture external-reviewed-source
set_reviewed_source_authoritative_current_drift_fixture
expect_success "reviewed-source authoritative-current drift postflight fixture"
assert_no_bundle_temp_dirs

write_fixture
set_plan_readiness_blocker_fixture external-reviewed-source
set_reviewed_source_authoritative_current_drift_fixture
edit_source_publication_report "const iroha = data.repositories.find((row) => row.path === '../iroha'); iroha.failures.splice(2, 1)"
expect_failure "reviewed-source authoritative-current drift missing diagnostic fixture" "plan-readiness unblock contract variant must match plan-readiness log classification"

write_fixture
set_plan_readiness_blocker_fixture external-reviewed-source
set_reviewed_source_authoritative_current_drift_fixture
edit_source_publication_report "const iroha = data.repositories.find((row) => row.path === '../iroha'); iroha.failures.splice(5, 1)"
expect_failure "reviewed-source authoritative-current drift missing cached-upstream diagnostic fixture" "plan-readiness unblock contract variant must match plan-readiness log classification"

write_fixture
set_plan_readiness_blocker_fixture external-reviewed-source
set_reviewed_source_authoritative_current_drift_fixture
edit_source_publication_report "const iroha = data.repositories.find((row) => row.path === '../iroha'); const value = iroha.failures[2]; iroha.failures[2] = iroha.failures[3]; iroha.failures[3] = value"
expect_failure "reviewed-source authoritative-current drift reordered diagnostics fixture" "plan-readiness unblock contract variant must match plan-readiness log classification"

write_fixture
set_plan_readiness_blocker_fixture external-reviewed-source
set_reviewed_source_authoritative_current_drift_fixture
edit_source_publication_report "const iroha = data.repositories.find((row) => row.path === '../iroha'); iroha.failures[2] = 'local HEAD ' + iroha.headSha + ' does not match authoritative current branch ' + iroha.branch + ' at ' + 'f'.repeat(40)"
expect_failure "reviewed-source authoritative-current drift forged diagnostic fixture" "plan-readiness unblock contract variant must match plan-readiness log classification"

write_fixture
set_plan_readiness_blocker_fixture external-reviewed-source
set_reviewed_source_authoritative_current_drift_fixture
edit_source_publication_report "const iroha = data.repositories.find((row) => row.path === '../iroha'); iroha.failures[5] = 'cached upstream ' + iroha.upstream + ' at ' + 'f'.repeat(40) + ' does not match authoritative current branch ' + iroha.branch + ' at ' + iroha.currentBranchRemoteSha"
expect_failure "reviewed-source authoritative-current drift forged cached-upstream diagnostic fixture" "plan-readiness unblock contract variant must match plan-readiness log classification"

write_fixture
set_plan_readiness_blocker_fixture external-reviewed-source
set_reviewed_source_authoritative_current_drift_fixture
edit_source_publication_report "const iroha = data.repositories.find((row) => row.path === '../iroha'); iroha.currentBranchRemoteSha = iroha.headSha; iroha.failures[2] = 'local HEAD ' + iroha.headSha + ' does not match authoritative current branch ' + iroha.branch + ' at ' + iroha.currentBranchRemoteSha; iroha.failures[5] = 'cached upstream ' + iroha.upstream + ' at ' + iroha.upstreamSha + ' does not match authoritative current branch ' + iroha.branch + ' at ' + iroha.currentBranchRemoteSha"
expect_failure "reviewed-source synchronized current with full drift diagnostics fixture" "plan-readiness unblock contract variant must match plan-readiness log classification"

write_fixture
edit_source_publication_preflight_report "const row = data.repositories[0]; const sha = 'b'.repeat(40); for (const key of ['prHeadSha', 'headSha', 'upstreamSha', 'remoteHeadSha', 'currentBranchRemoteSha']) row[key] = sha"
rebind_source_publication_postflight
expect_failure "source publication preflight passed-source identity mismatch fixture" "sourcePublicationHandoff.sources[1].prHeadSha must match across preflight and postflight"

write_fixture
set_plan_readiness_blocker_fixture external-reviewed-source
set_reviewed_source_authoritative_current_drift_fixture
edit_source_publication_report "const iroha = data.repositories.find((row) => row.path === '../iroha'); iroha.failures.push('unrelated postflight diagnostic')"
expect_failure "reviewed-source authoritative-current drift six plus marker plus extra fixture" "plan-readiness unblock contract variant must match plan-readiness log classification"

write_fixture
set_plan_readiness_blocker_fixture external-reviewed-source
set_reviewed_source_authoritative_current_drift_fixture
edit_source_publication_report "const iroha = data.repositories.find((row) => row.path === '../iroha'); iroha.stagedCount = 1; data.totals.staged = 1"
expect_failure "reviewed-source authoritative-current drift nonzero worktree count fixture" "plan-readiness unblock contract variant must match plan-readiness log classification"

write_fixture
set_plan_readiness_blocker_fixture external-reviewed-source
edit_source_publication_report "const iroha = data.repositories.find((row) => row.path === '../iroha'); iroha.stagedCount = 1; data.totals.staged = 1"
expect_failure "reviewed-source synchronized nonzero worktree count fixture" "plan-readiness unblock contract variant must match plan-readiness log classification"

write_fixture
set_plan_readiness_blocker_fixture external-reviewed-source
edit_source_publication_report "const iroha = data.repositories.find((row) => row.path === '../iroha'); const marker = 'source publication preflight did not pass before release checks'; iroha.failures.splice(iroha.failures.indexOf(marker), 1)"
expect_failure "reviewed-source missing exact failed-preflight continuity marker fixture" "sourcePublicationHandoff.sources[8].failures must contain the exact failed-preflight continuity diagnostic"

write_fixture
set_plan_readiness_blocker_fixture external-reviewed-source
edit_source_publication_report "const iroha = data.repositories.find((row) => row.path === '../iroha'); const marker = 'source publication preflight did not pass before release checks'; iroha.failures.splice(iroha.failures.indexOf(marker), 1); iroha.failures.splice(3, 0, marker)"
expect_failure "reviewed-source reordered preflight-continuity marker fixture" "plan-readiness unblock contract variant must match plan-readiness log classification"

write_fixture
set_plan_readiness_blocker_fixture external-reviewed-source
edit_source_publication_report "const iroha = data.repositories.find((row) => row.path === '../iroha'); iroha.failures.push('source publication preflight did not pass before release checks')"
expect_failure "reviewed-source duplicate preflight-continuity marker fixture" "plan-readiness unblock contract variant must match plan-readiness log classification"

write_fixture
set_plan_readiness_blocker_fixture external-reviewed-source
edit_source_publication_report "const iroha = data.repositories.find((row) => row.path === '../iroha'); iroha.failures.push('unrelated postflight diagnostic')"
expect_failure "reviewed-source preflight-continuity marker plus unrelated failure fixture" "plan-readiness unblock contract variant must match plan-readiness log classification"

write_fixture
set_plan_readiness_blocker_fixture external-reviewed-source
edit_source_publication_report "const iroha = data.repositories.find((row) => row.path === '../iroha'); iroha.failures[0] = 'worktree contains ignored non-published paths (0): forged; remove or quarantine these ignored outputs outside the source tree before publication; do not force-add generated artifacts'"
expect_failure "reviewed-source malformed ignored-output diagnostic fixture" "plan-readiness unblock contract variant must match plan-readiness log classification"

write_fixture
set_plan_readiness_blocker_fixture external-reviewed-source
edit_source_publication_report "const iroha = data.repositories.find((row) => row.path === '../iroha'); iroha.failures.push('local HEAD ' + iroha.headSha + ' does not match authoritative current branch ' + iroha.branch + ' at ' + iroha.currentBranchRemoteSha)"
expect_failure "reviewed-source obsolete extra current-branch diagnostic fixture" "plan-readiness unblock contract variant must match plan-readiness log classification"

write_fixture
set_plan_readiness_blocker_fixture external-reviewed-source
edit_source_publication_report "const iroha = data.repositories.find((row) => row.path === '../iroha'); iroha.prHeadSha = null"
expect_failure "reviewed-source missing pull-request head SHA fixture" "plan-readiness unblock contract variant must match plan-readiness log classification"

write_fixture
set_plan_readiness_blocker_fixture external-reviewed-source
edit_source_publication_report "const iroha = data.repositories.find((row) => row.path === '../iroha'); iroha.prHeadSha = 'd'.repeat(40)"
expect_failure "reviewed-source forged pull-request head SHA fixture" "plan-readiness unblock contract variant must match plan-readiness log classification"

write_fixture
set_plan_readiness_blocker_fixture external-reviewed-source
edit_source_publication_report "const iroha = data.repositories.find((row) => row.path === '../iroha'); iroha.failures.splice(2, 1)"
expect_failure "reviewed-source missing pull-request head diagnostic fixture" "plan-readiness unblock contract variant must match plan-readiness log classification"

write_fixture
set_plan_readiness_blocker_fixture external-reviewed-source
edit_source_publication_report "const iroha = data.repositories.find((row) => row.path === '../iroha'); iroha.remoteBranchPresent = true; iroha.remoteHeadSha = iroha.headSha"
expect_failure "reviewed-source invalid configured-ref relation fixture" "plan-readiness unblock contract variant must match plan-readiness log classification"

write_fixture
set_plan_readiness_blocker_fixture external-reviewed-source
edit_source_publication_report "const iroha = data.repositories.find((row) => row.path === '../iroha'); iroha.headSha = 'd'.repeat(40)"
expect_failure "reviewed-source forged local HEAD fixture" "plan-readiness unblock contract variant must match plan-readiness log classification"

write_fixture
set_plan_readiness_blocker_fixture external-reviewed-source
edit_source_publication_report "const iroha = data.repositories.find((row) => row.path === '../iroha'); iroha.upstreamSha = 'd'.repeat(40)"
expect_failure "reviewed-source forged cached upstream SHA fixture" "plan-readiness unblock contract variant must match plan-readiness log classification"

write_fixture
set_plan_readiness_blocker_fixture external-reviewed-source
edit_source_publication_report "const iroha = data.repositories.find((row) => row.path === '../iroha'); iroha.failures[3] = 'local HEAD forged current-branch proof'"
expect_failure "reviewed-source stale authoritative current-branch diagnostic fixture" "plan-readiness unblock contract variant must match plan-readiness log classification"

write_fixture
set_plan_readiness_blocker_fixture external-reviewed-source
edit_source_publication_report "const iroha = data.repositories.find((row) => row.path === '../iroha'); iroha.currentBranchRemotePresent = false; iroha.currentBranchRemoteSha = null"
expect_failure "reviewed-source missing authoritative current-branch proof fixture" "plan-readiness unblock contract variant must match plan-readiness log classification"

write_fixture
set_plan_readiness_blocker_fixture external-reviewed-source
edit_source_publication_report "const iroha = data.repositories.find((row) => row.path === '../iroha'); const marker = 'source publication preflight did not pass before release checks'; const markerIndex = iroha.failures.indexOf(marker); iroha.currentBranchRemoteSha = iroha.headSha; iroha.failures.splice(markerIndex, 0, 'local HEAD ' + iroha.headSha + ' does not match authoritative current branch ' + iroha.branch + ' at ' + iroha.currentBranchRemoteSha, 'cached upstream ' + iroha.upstream + ' at ' + iroha.upstreamSha + ' does not match authoritative current branch ' + iroha.branch + ' at ' + iroha.currentBranchRemoteSha)"
expect_failure "reviewed-source obsolete authoritative current-branch drift diagnostics fixture" "plan-readiness unblock contract variant must match plan-readiness log classification"

write_fixture
set_plan_readiness_blocker_fixture external
edit_source_publication_report "const iroha = data.repositories.find((row) => row.path === '../iroha'); iroha.branch = 'optimizations'; iroha.upstream = 'origin/optimizations'; iroha.remoteBranchPresent = false; iroha.remoteHeadSha = 'd'.repeat(40)"
expect_failure "failed differing-branch false configured-ref presence with SHA fixture" "source-publication-readiness-report.json.repositories[7].remoteHeadSha must be null when remoteBranchPresent is false or null"

write_fixture
set_plan_readiness_blocker_fixture external
edit_source_publication_report "const iroha = data.repositories.find((row) => row.path === '../iroha'); iroha.branch = 'optimizations'; iroha.upstream = 'origin/optimizations'; iroha.remoteBranchPresent = null; iroha.remoteHeadSha = 'd'.repeat(40)"
expect_failure "failed differing-branch null configured-ref presence with SHA fixture" "source-publication-readiness-report.json.repositories[7].remoteHeadSha must be null when remoteBranchPresent is false or null"

write_fixture
set_plan_readiness_blocker_fixture external
edit_source_publication_report "const iroha = data.repositories.find((row) => row.path === '../iroha'); iroha.currentBranchRemotePresent = false; iroha.currentBranchRemoteSha = 'b'.repeat(40)"
expect_failure "failed Iroha false current-branch presence with SHA fixture" "source-publication-readiness-report.json.repositories[7].currentBranchRemoteSha must be null when currentBranchRemotePresent is false or null"

write_fixture
set_plan_readiness_blocker_fixture external
edit_source_publication_report "const iroha = data.repositories.find((row) => row.path === '../iroha'); iroha.currentBranchRemotePresent = false; iroha.currentBranchRemoteSha = null"
expect_failure "failed Iroha matching-branch remote proof mismatch fixture" "source-publication-readiness-report.json.repositories[7].currentBranchRemotePresent must match remoteBranchPresent when branch matches head"

write_fixture
set_plan_readiness_blocker_fixture external
edit_source_publication_report "const iroha = data.repositories.find((row) => row.path === '../iroha'); iroha.remoteHeadSha = null; iroha.currentBranchRemoteSha = null"
expect_failure "failed Iroha malformed matching-branch remote response fixture" "sourcePublicationHandoff.sources[8].currentBranchRemoteSha must match across preflight and postflight"

write_fixture
set_plan_readiness_blocker_fixture external-reviewed-source
edit_source_publication_report "const iroha = data.repositories.find((row) => row.path === '../iroha'); iroha.failures[1] = 'upstream mismatch: expected origin/codex/kagemusha-selector-hardening, received origin/forged'"
expect_failure "forged reviewed-source mismatch plan blocker fixture" "plan-readiness unblock contract variant must match plan-readiness log classification"

write_fixture
set_plan_readiness_blocker_fixture local
expect_success "exact local plan blocker fixture"
assert_no_bundle_temp_dirs

write_fixture
set_plan_readiness_blocker_fixture external
edit_plan_blocker_contract "contract.recommendedAction = 'Fix the static plan-readiness drift in the referenced repos/scripts, then rerun bash scripts/audit-plan-readiness.sh.'"
expect_failure "external plan action mixed with external metadata fixture" "plan-readiness unblock contract must match either the exact local or exact external-Iroha-only variant"

write_fixture
set_plan_readiness_blocker_fixture external
edit_plan_blocker_contract "contract.requiresExternalAction = false"
expect_failure "external plan false external-action fixture" "plan-readiness unblock contract must match either the exact local or exact external-Iroha-only variant"

write_fixture
set_plan_readiness_blocker_fixture external
edit_plan_blocker_contract "contract.unblockCategory = 'local-code'"
expect_failure "external plan local category fixture" "plan-readiness unblock contract must match either the exact local or exact external-Iroha-only variant"

write_fixture
set_plan_readiness_blocker_fixture external
edit_plan_blocker_contract "contract.externalPrerequisite = 'No external prerequisite is expected; fix the local failing release gate.'"
expect_failure "external plan local prerequisite fixture" "plan-readiness unblock contract must match either the exact local or exact external-Iroha-only variant"

write_fixture
set_plan_readiness_blocker_fixture external
edit_plan_blocker_contract "contract.externalPrerequisite += ' Tampered.'"
expect_failure "external plan tampered prerequisite fixture" "plan-readiness unblock contract must match either the exact local or exact external-Iroha-only variant"

write_fixture
set_plan_readiness_blocker_fixture external
set_plan_readiness_log_classification local
expect_failure "external plan metadata with local failure log fixture" "plan-readiness unblock contract variant must match plan-readiness log classification"

write_fixture
set_plan_readiness_blocker_fixture local
set_plan_readiness_log_classification external
expect_success "clean Iroha-only log stays local without unsafe source operation fixture"
assert_no_bundle_temp_dirs

write_fixture
edit_actions_report "data.blockers.find((blocker) => blocker.slug === 'passkey-production-smoke').recommendedAction = 'Deploy DNS and run the smoke without provisioning its grant helper.'"
expect_failure "passkey smoke recommended action missing executable grant helper fixture" "passkey-production-smoke.recommendedAction must match expected recommended action"

write_fixture
edit_actions_report "data.blockers.find((blocker) => blocker.slug === 'passkey-production-smoke').externalPrerequisite = 'DNS, TLS, and routing only.'"
expect_failure "passkey smoke external prerequisite missing executable grant helper fixture" "passkey-production-smoke.externalPrerequisite must match expected unblock metadata"

write_fixture
edit_actions_report "data.blockers.find((blocker) => blocker.slug === 'pi-deployment-evidence').verificationCommand = 'cd ../polkaswap-indexer && yarn audit:deployment-evidence --require-ready'"
expect_failure "bare PI deployment verification command fixture" "pi-deployment-evidence.verificationCommand must match expected command"

write_fixture
edit_actions_report "data.blockers.find((blocker) => blocker.slug === 'pi-production-smoke').verificationCommand = 'cd ../polkaswap-indexer && POLKASWAP_INDEXER_BASE_URL=https://pi.soramitsu.io/graphql yarn smoke:production'"
expect_failure "bare PI smoke verification command fixture" "pi-production-smoke.verificationCommand must match expected command"

write_fixture
outside_workspace_config="$tmp_dir/outside-workspace-config"
rm -rf "$outside_workspace_config"
cp -R "$workspace_dir/config" "$outside_workspace_config"
rm -rf "$workspace_dir/config"
ln -s "$outside_workspace_config" "$workspace_dir/config"
expect_failure "workspace handoff symlinked parent fixture" "must not use a symlinked path component"

write_fixture
rm "$report_dir/source-publication-preflight-report.json"
expect_failure "missing source publication preflight report fixture" "sourcePublicationHandoff.preflightReportPath missing"

write_fixture
edit_source_publication_report "data.phase = 'preflight'"
expect_failure "source publication wrong postflight phase fixture" "source-publication-readiness-report.json.phase must be postflight"

write_fixture
edit_source_publication_preflight_report "data.phase = 'postflight'; data.preflightReportSha256 = 'a'.repeat(64)"
rebind_source_publication_postflight
expect_failure "source publication wrong preflight phase fixture" "source-publication-preflight-report.json.phase must be preflight"

write_fixture
edit_source_publication_report "data.preflightReportSha256 = 'f'.repeat(64)"
expect_failure "source publication preflight digest mismatch fixture" "sourcePublicationHandoff.postflight preflightReportSha256 must match the exact preflight report bytes"

write_fixture
edit_source_publication_preflight_report "data.generatedAt = '2026-06-28T00:01:00.000Z'"
rebind_source_publication_postflight
expect_failure "source publication preflight chronology fixture" "sourcePublicationHandoff.preflight report must not postdate the postflight report"

write_fixture
edit_source_publication_report "data.repositories[0].repositoryPath = '/tmp/attacker-controlled-source'"
expect_failure "source publication repository path forgery fixture" "source-publication-readiness-report.json.repositories[0].repositoryPath mismatch"

write_fixture
edit_source_publication_report "data.schemaVersion = 2"
expect_failure "source publication legacy schema fixture" "source-publication-readiness-report.json.schemaVersion must be 3"

write_fixture
edit_source_publication_report "data.repositories.pop()"
expect_failure "source publication missing Iroha source fixture" "source-publication-readiness-report.json.repositories must contain eight rows"

write_fixture
edit_source_publication_report "const iroha = data.repositories.pop(); data.repositories.splice(6, 0, iroha)"
expect_failure "source publication Iroha source order fixture" "source-publication-readiness-report.json.repositories[6] identity mismatch"

write_fixture
edit_source_publication_report "data.repositories[7].head = 'attacker/unpublished-iroha'"
expect_failure "source publication Iroha identity fixture" "source-publication-readiness-report.json.repositories[7] identity mismatch"

write_fixture
edit_source_publication_report "data.repositories[7].unstagedCount = 1; data.totals.unstaged = 1"
expect_failure "source publication passed dirty Iroha fixture" "source-publication-readiness-report.json.repositories[7].passed source must have zero dirty counts"

write_fixture
edit_source_publication_report "data.repositories[0].originUrl = 'https://user:password@github.com/soramitsu/fearless-Android.git'"
expect_failure "source publication credential origin fixture" "source-publication-readiness-report.json.repositories[0].originUrl contains secret-like token: password"

write_fixture
edit_source_publication_report "data.repositories[0].originUrl = 'https://github.com/attacker/wrong.git'; data.repositories[0].originRepository = 'attacker/wrong'"
expect_failure "source publication origin identity forgery fixture" "source-publication-readiness-report.json.repositories[0].originRepository must match repository for a passed source"

write_fixture
edit_source_publication_report "data.repositories[0].branch = 'attacker/wrong-branch'"
expect_failure "source publication branch forgery fixture" "source-publication-readiness-report.json.repositories[0].branch must match head for a passed source"

write_fixture
edit_source_publication_report "data.repositories[0].prHeadSha = null"
expect_failure "source publication missing pull-request head SHA fixture" "source-publication-readiness-report.json.repositories[0].prHeadSha is required for a passed source"

write_fixture
edit_source_publication_report "data.repositories[0].prHeadSha = 'b'.repeat(40)"
expect_failure "source publication forged pull-request head SHA fixture" "source-publication-readiness-report.json.repositories[0].prHeadSha must match headSha for a passed source"

write_fixture
edit_source_publication_report "data.repositories[0].upstreamSha = 'b'.repeat(40)"
expect_failure "source publication upstream SHA forgery fixture" "source-publication-readiness-report.json.repositories[0].upstream must match the published head when the remote branch exists"

write_fixture
edit_source_publication_report "data.repositories[0].unstagedCount = 1; data.totals.unstaged = 1"
expect_failure "source publication passed dirty source fixture" "source-publication-readiness-report.json.repositories[0].passed source must have zero dirty counts"

write_fixture
edit_source_publication_report "data.repositories[0].remoteBranchPresent = null; data.repositories[0].remoteHeadSha = null; data.repositories[0].currentBranchRemotePresent = null; data.repositories[0].currentBranchRemoteSha = null"
expect_failure "source publication missing remote proof fixture" "source-publication-readiness-report.json.repositories[0].remoteBranchPresent is required for a passed source"

write_fixture
edit_source_publication_report "data.repositories[0].currentBranchRemotePresent = null; data.repositories[0].currentBranchRemoteSha = null"
expect_failure "source publication missing current-branch remote proof fixture" "source-publication-readiness-report.json.repositories[0].currentBranchRemotePresent must match remoteBranchPresent when branch matches head"

write_fixture
edit_source_publication_report "data.repositories[0].currentBranchRemoteSha = 'b'.repeat(40)"
expect_failure "source publication forged current-branch remote SHA fixture" "source-publication-readiness-report.json.repositories[0].currentBranchRemoteSha must match remoteHeadSha when branch matches head"

write_fixture
edit_source_publication_report "data.repositories[0].currentBranchRemotePresent = false; data.repositories[0].currentBranchRemoteSha = null"
expect_failure "source publication current/configured branch presence mismatch fixture" "source-publication-readiness-report.json.repositories[0].currentBranchRemotePresent must match remoteBranchPresent when branch matches head"

write_fixture
edit_source_publication_report "data.repositories[0].remoteBranchPresent = false; data.repositories[0].remoteHeadSha = null; data.repositories[0].currentBranchRemotePresent = false; data.repositories[0].currentBranchRemoteSha = null; data.repositories[0].upstream = null; data.repositories[0].upstreamSha = null"
expect_success "source publication deleted merged current/configured branch proof fixture"
assert_no_bundle_temp_dirs

write_fixture
edit_source_publication_report "data.repositories[0].prState = 'open'"
expect_failure "source publication unmerged passed source fixture" "source-publication-readiness-report.json.repositories[0].prState must be merged for a passed source"

write_fixture
edit_source_publication_report "data.workspaceSource.requiredTrackedFiles.pop()"
expect_failure "source publication workspace tracked-file proof fixture" "source-publication-readiness-report.json.workspaceSource.requiredTrackedFiles length mismatch"

write_fixture
node - "$workspace_dir/config/source-publication-root-owner.json" <<'NODE'
const fs = require('fs')
const file = process.argv[2]
const data = JSON.parse(fs.readFileSync(file, 'utf8'))
Object.assign(data, {status: 'blocked', repository: null, head: null, base: null, prNumber: null, blocker: 'canonical-root-source-owner-unassigned'})
fs.writeFileSync(file, JSON.stringify(data, null, 2) + '\n')
NODE
expect_failure "source publication blocked root owner with passed source fixture" "sourcePublicationHandoff.workspaceSource must fail while root owner config is blocked"

write_fixture
node - "$workspace_dir/config/source-publication-root-owner.json" <<'NODE'
const fs = require('fs')
const file = process.argv[2]
const data = JSON.parse(fs.readFileSync(file, 'utf8'))
data.repository = 'attacker/wrong'
fs.writeFileSync(file, JSON.stringify(data, null, 2) + '\n')
NODE
expect_failure "source publication root owner identity mismatch fixture" "sourcePublicationHandoff.workspaceSource.repository must match root owner config"

write_fixture
node - "$workspace_dir/config/source-publication-root-owner.json" "$report_dir/source-publication-readiness-report.json" <<'NODE'
const fs = require('fs')
const [configFile, reportFile] = process.argv.slice(2)
const config = JSON.parse(fs.readFileSync(configFile, 'utf8'))
Object.assign(config, {repository: 'attacker/unlisted-root', head: 'attacker/release', base: 'main', prNumber: 999})
fs.writeFileSync(configFile, JSON.stringify(config, null, 2) + '\n')
const report = JSON.parse(fs.readFileSync(reportFile, 'utf8'))
const source = report.workspaceSource
Object.assign(source, {
  repository: config.repository,
  head: config.head,
  base: config.base,
  prNumber: config.prNumber,
  prUrl: `https://github.com/${config.repository}/pull/${config.prNumber}`,
  originUrl: `https://github.com/${config.repository}.git`,
  originRepository: config.repository,
  branch: config.head,
  upstream: `origin/${config.head}`,
})
fs.writeFileSync(reportFile, JSON.stringify(report, null, 2) + '\n')
NODE
expect_failure "source publication unlisted root owner release row fixture" "sourcePublicationHandoff.sources[0].repository must match across preflight and postflight"

write_fixture
edit_source_publication_report "data.rootOwnerConfigFile = '/tmp/attacker-root-owner.json'"
expect_failure "source publication root owner config path drift fixture" "source-publication-readiness-report.json.rootOwnerConfigFile mismatch"

write_fixture
node - "$workspace_dir/config/source-publication-root-owner.json" <<'NODE'
const fs = require('fs')
const file = process.argv[2]
const data = JSON.parse(fs.readFileSync(file, 'utf8'))
data.lastReviewed = '2999-01-01'
fs.writeFileSync(file, JSON.stringify(data, null, 2) + '\n')
NODE
expect_failure "source publication future root owner review fixture" "sourcePublicationHandoff.rootOwnerConfig.lastReviewed must not be in the future"

write_fixture
edit_source_publication_report "data.generatedAt = '2026-06-27T23:50:00.000Z'"
expect_failure "source publication stale report fixture" "source-publication-readiness-report.json.generatedAt must be within five minutes of summary.generatedAt"

write_fixture
edit_source_publication_report "data.generatedAt = '2026-06-28T00:04:00.000Z'"
expect_failure "source publication post-summary report fixture" "source-publication-readiness-report.json.generatedAt must not be later than summary.generatedAt"

write_fixture
perl -0pi -e 's/\t1260$/\t01260/m' "$workspace_dir/config/source-publication-readiness.tsv"
expect_failure "source publication noncanonical PR number fixture" "sourcePublicationHandoff.config row 1 pull request must be canonical positive digits"

write_fixture
sed -i.bak '/^\.\.\/iroha/d' "$workspace_dir/config/source-publication-readiness.tsv"
rm "$workspace_dir/config/source-publication-readiness.tsv.bak"
expect_failure "source publication missing Iroha config fixture" "sourcePublicationHandoff.config must contain eight rows"

write_fixture
perl -0pi -e 's#hyperledger-iroha/iroha#attacker/iroha#' "$workspace_dir/config/source-publication-readiness.tsv"
expect_failure "source publication Iroha config identity fixture" "sourcePublicationHandoff.config row 8 identity mismatch"

write_fixture
node - "$workspace_dir/config/source-publication-readiness.tsv" <<'NODE'
const fs = require('fs')
const file = process.argv[2]
const lines = fs.readFileSync(file, 'utf8').trimEnd().split('\n')
const iroha = lines.pop()
lines.splice(lines.length - 1, 0, iroha)
fs.writeFileSync(file, `${lines.join('\n')}\n`)
NODE
expect_failure "source publication Iroha config order fixture" "sourcePublicationHandoff.config row 7 identity mismatch"

write_fixture
printf '%s\n' '# api_key=ghp_fixture_secret' >> "$workspace_dir/config/source-publication-readiness.tsv"
expect_failure "source publication secret config comment fixture" "handoffs/source-publication-readiness.tsv contains secret-like token: api_key"

write_fixture
node - "$report_dir/release-pr-readiness-report.json" "$report_dir/release-pr-readiness.log" <<'NODE'
const fs = require('fs')
const [reportFile, logFile] = process.argv.slice(2)
const report = JSON.parse(fs.readFileSync(reportFile, 'utf8'))
const requirement = report.requirements[0]
const originalMessage = requirement.message
requirement.message = 'soramitsu/fearless-wallet-web:codex/web-bitcoin-broadcast-evidence -> develop: no merged pull request found'
delete requirement.pr
delete requirement.isDraft
delete requirement.reviewDecision
delete requirement.mergeStateStatus
delete requirement.unresolvedReviewThreads
delete requirement.currentUnresolvedReviewThreads
delete requirement.outdatedUnresolvedReviewThreads
report.failures[0] = requirement.message
fs.writeFileSync(reportFile, JSON.stringify(report, null, 2))
const log = fs.readFileSync(logFile, 'utf8')
fs.writeFileSync(logFile, log.replace(`[release-pr-readiness][warn] ${originalMessage}`, `[release-pr-readiness][warn] ${requirement.message}`))
NODE
expect_success "release PR merge handoff blocked PR count from structured PR fixture"
node - "$bundle_dir/manifest.json" <<'NODE'
const fs = require('fs')
const manifest = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'))
const releasePrBlocker = manifest.blockers.find((blocker) => blocker.slug === 'release-pr-readiness')
if (releasePrBlocker.releasePrStatusReportHandoff.failedCount !== 4) {
  throw new Error('expected four failed release PR requirements')
}
if (releasePrBlocker.releasePrStatusReportHandoff.blockedPrs.length !== 3) {
  throw new Error('expected three structured blocked PR rows')
}
if (releasePrBlocker.releasePrMergeHandoff.blockedPrCount !== 3) {
  throw new Error('release PR merge handoff blockedPrCount must count structured PR rows')
}
NODE

write_fixture
outside_report_dir="$tmp_dir/outside-reports"
rm -rf "$outside_report_dir"
cp -R "$report_dir" "$outside_report_dir"
expect_failure_from "source report dir outside workspace fixture" "$outside_report_dir" "release-readiness report dir must be inside workspace root"

write_fixture
real_report_parent="$tmp_dir/real-report-parent"
rm -rf "$real_report_parent"
mkdir -p "$real_report_parent"
mv "$report_dir" "$real_report_parent/release-readiness"
rm -rf "$workspace_dir/build/reports"
ln -s "$real_report_parent" "$workspace_dir/build/reports"
expect_failure "source report dir symlink-parent fixture" "release-readiness report dir must not alias outside workspace root through symlinks"

write_fixture
workspace_report_parent="$workspace_dir/alternate-report-parent"
rm -rf "$workspace_report_parent"
mkdir -p "$workspace_report_parent"
mv "$report_dir" "$workspace_report_parent/release-readiness"
rm -rf "$workspace_dir/build/reports"
ln -s "$workspace_report_parent" "$workspace_dir/build/reports"
expect_failure "source report dir workspace symlink-parent fixture" "release-readiness report dir must not use a symlinked path component"

write_fixture
expect_failure_to "output report dir fixture" "$report_dir" "output dir must not be the release-readiness report dir or an ancestor"
[[ -f "$report_dir/summary.json" ]] || fail "unsafe report output removed source summary"

write_fixture
expect_failure_to "output workspace root fixture" "$workspace_dir" "output dir must not be the workspace root or an ancestor"
[[ -f "$workspace_dir/config/passkey-backup-production.json" ]] || fail "unsafe workspace output removed source config"

write_fixture
ln -s "$report_dir" "$tmp_dir/report-output-link"
expect_failure_to "output report file symlink alias fixture" "$tmp_dir/report-output-link/summary.json" "output dir must be absent or a regular directory"
[[ -f "$report_dir/summary.json" ]] || fail "unsafe report file alias output removed source summary"

write_fixture
ln -s "$report_dir" "$tmp_dir/report-output-link"
expect_failure_to "output report child symlink alias fixture" "$tmp_dir/report-output-link/unblock-bundle" "output dir must not use a symlinked path component"
[[ -f "$report_dir/summary.json" ]] || fail "unsafe report child alias output removed source summary"

write_fixture
ln -s "$workspace_dir" "$tmp_dir/workspace-output-link"
expect_failure_to "output workspace dir symlink alias fixture" "$tmp_dir/workspace-output-link/config" "output dir must not use a symlinked path component"
[[ -f "$workspace_dir/config/passkey-backup-production.json" ]] || fail "unsafe workspace alias output removed source config"

write_fixture
mkdir -p "$tmp_dir/real-output-parent/unblock-bundle"
printf '%s\n' "keep me" > "$tmp_dir/real-output-parent/unblock-bundle/sentinel.txt"
ln -s "$tmp_dir/real-output-parent" "$workspace_dir/output-parent-link"
expect_failure_to "output symlinked parent fixture" "$workspace_dir/output-parent-link/unblock-bundle" "output dir must not use a symlinked path component"
[[ -f "$tmp_dir/real-output-parent/unblock-bundle/sentinel.txt" ]] || fail "unsafe symlink-parent output removed target sentinel"

write_fixture
rm -rf "$repo_scratch_dir"
mkdir -p "$repo_scratch_dir/real-output-parent/unblock-bundle"
printf '%s\n' "keep me" > "$repo_scratch_dir/real-output-parent/unblock-bundle/sentinel.txt"
ln -s "$repo_scratch_dir/real-output-parent" "$repo_scratch_dir/output-parent-link"
expect_failure_to "output unanchored symlinked parent fixture" "$repo_scratch_dir/output-parent-link/unblock-bundle" "output dir must not use a symlinked path component"
[[ -f "$repo_scratch_dir/real-output-parent/unblock-bundle/sentinel.txt" ]] || fail "unsafe unanchored symlink-parent output removed target sentinel"

write_fixture
mv "$report_dir" "$tmp_dir/real-reports"
ln -s "$tmp_dir/real-reports" "$report_dir"
expect_failure "source report dir symlink fixture" "release-readiness report dir must be a regular directory"

write_fixture
mv "$workspace_dir" "$tmp_dir/real-workspace"
ln -s "$tmp_dir/real-workspace" "$workspace_dir"
expect_failure "workspace root symlink fixture" "workspace root must be a regular directory"

write_fixture
(
  real_workspace_parent="$tmp_dir/real-workspace-parent"
  symlink_workspace_parent="$tmp_dir/workspace-parent-link"
  rm -rf "$real_workspace_parent" "$symlink_workspace_parent"
  mkdir -p "$real_workspace_parent"
  mv "$workspace_dir" "$real_workspace_parent/fearless"
  ln -s "$real_workspace_parent" "$symlink_workspace_parent"
  workspace_dir="$symlink_workspace_parent/fearless"
  report_dir="$workspace_dir/build/reports/release-readiness"
  expect_failure "workspace root symlink-parent fixture" "workspace root must not use a symlinked path component"
)

write_fixture
rm "$workspace_dir/FEARLESS_PROJECT_PLAN.md"
expect_failure "workspace missing plan marker fixture" "workspace root is not a Fearless workspace"

write_fixture
rm "$workspace_dir/FEARLESS_PROJECT_PLAN.md"
printf '%s\n' '# Fearless symlink marker target' > "$tmp_dir/export-plan-marker-target.md"
ln -s "$tmp_dir/export-plan-marker-target.md" "$workspace_dir/FEARLESS_PROJECT_PLAN.md"
expect_failure "workspace symlink plan marker fixture" "workspace root is not a Fearless workspace"

write_fixture
printf '%s\n' '# Fearless test workspace' > "$workspace_dir/FEARLESS_PROJECT_PLAN.md"
expect_failure "workspace placeholder plan marker fixture" "workspace root marker content mismatch"

write_fixture
printf '%s\n' '#!/usr/bin/env bash' 'exit 0' > "$workspace_dir/scripts/audit-release-readiness.sh"
expect_failure "workspace placeholder audit marker fixture" "workspace root marker content mismatch"

write_fixture
chmod 0644 "$workspace_dir/scripts/audit-release-readiness.sh"
expect_failure "workspace non-executable audit marker fixture" "workspace root marker must be executable"

write_fixture
printf '%s\n' '{}' > "$outside_log"
rm "$report_dir/summary.json"
ln -s "$outside_log" "$report_dir/summary.json"
expect_failure "source summary symlink fixture" "summary.json must be a regular file"

write_fixture
printf '%s\n' "solswap-io/solswap-indexer#8 is open" > "$outside_log"
rm "$report_dir/release-pr-readiness.log"
ln -s "$outside_log" "$report_dir/release-pr-readiness.log"
expect_failure "source log symlink fixture" "release-pr-readiness.logFile must not use a symlinked path component"

write_fixture
set_release_pr_backtick_evidence_fixture
expect_success "safe evidence-preview markdown fence fixture"
assert_safe_evidence_markdown_fence

write_fixture
set_release_pr_backtick_evidence_fixture
rewrite_release_pr_evidence_to_unsafe_fixed_fence
expect_failure "unsafe evidence-preview markdown fence fixture" "blockers.md does not match summary/actions blockers"

write_fixture
set_release_pr_capped_evidence_fixture
expect_success "capped evidence-preview suffix fixture"
assert_capped_evidence_preview_preserved

write_fixture
set_release_pr_dangling_capped_evidence_fixture
expect_failure "dangling capped evidence-preview fixture" "release-pr-readiness.evidencePreview line cap marker must be followed by a source log line suffix"

write_fixture
set_release_pr_wrong_length_capped_evidence_fixture
expect_failure "wrong-length capped evidence-preview fixture" "release-pr-readiness.evidencePreview capped line length must match line cap marker"

write_fixture
rm "$report_dir/web-bitcoin-broadcast-evidence-template.json"
expect_failure "missing web Bitcoin template report fixture" "web-bitcoin-broadcast-evidence.bitcoinBroadcastTemplateHandoff.sourceReportPath missing"

write_fixture
node - "$report_dir/web-bitcoin-broadcast-evidence-template.json" <<'NODE'
const fs = require('fs')
const file = process.argv[2]
const data = JSON.parse(fs.readFileSync(file, 'utf8'))
data.scope = 'web-bitcoin-mainnet-broadcast-readiness'
fs.writeFileSync(file, JSON.stringify(data, null, 2))
NODE
expect_failure "bad web Bitcoin template scope fixture" "web-bitcoin-broadcast-evidence.bitcoinBroadcastEvidenceTemplate.scope mismatch"

write_fixture
node - "$report_dir/web-bitcoin-broadcast-evidence-template.json" <<'NODE'
const fs = require('fs')
const file = process.argv[2]
const data = JSON.parse(fs.readFileSync(file, 'utf8'))
data.evidence[0].commit = '0123456789abcdef0123456789abcdef01234567'
fs.writeFileSync(file, JSON.stringify(data, null, 2))
NODE
expect_failure "bad web Bitcoin template placeholder fixture" "web-bitcoin-broadcast-evidence.bitcoinBroadcastEvidenceTemplate.evidence[0].commit placeholder mismatch"

write_fixture
rm "$report_dir/passkey-deployment-evidence-template.json"
expect_failure "missing passkey deployment template report fixture" "passkey-deployment-evidence.passkeyDeploymentTemplateHandoff.sourceReportPath missing"

write_fixture
node - "$report_dir/passkey-deployment-evidence-template.json" <<'NODE'
const fs = require('fs')
const file = process.argv[2]
const data = JSON.parse(fs.readFileSync(file, 'utf8'))
data.scope = 'passkey-backup-challenge-service-staging-deployment-readiness'
fs.writeFileSync(file, JSON.stringify(data, null, 2))
NODE
expect_failure "bad passkey deployment template scope fixture" "passkey-deployment-evidence.passkeyDeploymentEvidenceTemplate.scope mismatch"

write_fixture
node - "$report_dir/passkey-deployment-evidence-template.json" <<'NODE'
const fs = require('fs')
const file = process.argv[2]
const data = JSON.parse(fs.readFileSync(file, 'utf8'))
data.deploymentEvidence[0].deployedCommit = '0123456789abcdef0123456789abcdef01234567'
fs.writeFileSync(file, JSON.stringify(data, null, 2))
NODE
expect_failure "bad passkey deployment template placeholder fixture" "passkey-deployment-evidence.passkeyDeploymentEvidenceTemplate.deploymentEvidence[0].deployedCommit placeholder mismatch"

write_fixture
node - "$report_dir/passkey-deployment-evidence-template.json" <<'NODE'
const fs = require('fs')
const file = process.argv[2]
const data = JSON.parse(fs.readFileSync(file, 'utf8'))
data.deploymentEvidence[0].webauthnAllowedOrigins[2] = 'android:apk-key-hash:UNREVIEWED'
fs.writeFileSync(file, JSON.stringify(data, null, 2))
NODE
expect_failure "bad passkey deployment template Android origin fixture" "passkey-deployment-evidence.passkeyDeploymentEvidenceTemplate.deploymentEvidence[0].webauthnAllowedOrigins[2] mismatch"

write_fixture
node - "$report_dir/passkey-deployment-evidence-template.json" <<'NODE'
const fs = require('fs')
const file = process.argv[2]
const data = JSON.parse(fs.readFileSync(file, 'utf8'))
data.deploymentEvidence[0].requestAccessPolicy.allPostRoutesProtected = false
fs.writeFileSync(file, JSON.stringify(data, null, 2))
NODE
expect_failure "bad passkey deployment template request-access fixture" "passkey-deployment-evidence.passkeyDeploymentEvidenceTemplate.deploymentEvidence[0].requestAccessPolicy.allPostRoutesProtected mismatch"

write_fixture
node - "$report_dir/passkey-deployment-evidence-template.json" <<'NODE'
const fs = require('fs')
const file = process.argv[2]
const data = JSON.parse(fs.readFileSync(file, 'utf8'))
data.deploymentEvidence[0].trustedProxyPolicy.hops = 2
fs.writeFileSync(file, JSON.stringify(data, null, 2))
NODE
expect_failure "bad passkey deployment template trusted-proxy fixture" "passkey-deployment-evidence.passkeyDeploymentEvidenceTemplate.deploymentEvidence[0].trustedProxyPolicy.hops mismatch"

write_fixture
node - "$report_dir/passkey-deployment-evidence-template.json" <<'NODE'
const fs = require('fs')
const file = process.argv[2]
const data = JSON.parse(fs.readFileSync(file, 'utf8'))
data.deploymentEvidence[0].requestAccessPolicy.credentialLifecycleSmokePassed = false
fs.writeFileSync(file, JSON.stringify(data, null, 2))
NODE
expect_failure "passkey lifecycle evidence boolean drift fixture" "passkey-deployment-evidence.passkeyDeploymentEvidenceTemplate.deploymentEvidence[0].requestAccessPolicy.credentialLifecycleSmokePassed mismatch"

write_fixture
node - "$report_dir/passkey-deployment-evidence-template.json" <<'NODE'
const fs = require('fs')
const file = process.argv[2]
const data = JSON.parse(fs.readFileSync(file, 'utf8'))
delete data.deploymentEvidence[0].liveHealthAttestation
fs.writeFileSync(file, JSON.stringify(data, null, 2))
NODE
expect_failure "passkey missing live-health attestation fixture" "passkey-deployment-evidence.passkeyDeploymentEvidenceTemplate.deploymentEvidence[0].liveHealthAttestation must be an object"

write_fixture
node - "$report_dir/passkey-deployment-evidence-template.json" <<'NODE'
const fs = require('fs')
const file = process.argv[2]
const data = JSON.parse(fs.readFileSync(file, 'utf8'))
data.deploymentEvidence[0].liveHealthAttestation.payloadSha256 = 'sha256:TODO_UNBOUND_HEALTH_PAYLOAD'
fs.writeFileSync(file, JSON.stringify(data, null, 2))
NODE
expect_failure "passkey live-health payload target drift fixture" "passkey-deployment-evidence.passkeyDeploymentEvidenceTemplate.deploymentEvidence[0].liveHealthAttestation.payloadSha256 mismatch"

write_fixture
node - "$report_dir/passkey-deployment-evidence-template.json" <<'NODE'
const fs = require('fs')
const file = process.argv[2]
const data = JSON.parse(fs.readFileSync(file, 'utf8'))
data.deploymentEvidence[0].liveHealthAttestation.deployedCommit = 'TODO_DIFFERENT_COMMIT'
fs.writeFileSync(file, JSON.stringify(data, null, 2))
NODE
expect_failure "passkey live-health commit binding drift fixture" "passkey-deployment-evidence.passkeyDeploymentEvidenceTemplate.deploymentEvidence[0].liveHealthAttestation.deployedCommit mismatch"

write_fixture
node - "$report_dir/passkey-deployment-evidence-template.json" <<'NODE'
const fs = require('fs')
const file = process.argv[2]
const data = JSON.parse(fs.readFileSync(file, 'utf8'))
data.deploymentEvidence[0].platformProvisioningAttestation.observedAt = 'TODO_DIFFERENT_OBSERVED_AT'
fs.writeFileSync(file, JSON.stringify(data, null, 2))
NODE
expect_failure "passkey platform attestation chronology drift fixture" "passkey-deployment-evidence.passkeyDeploymentEvidenceTemplate.deploymentEvidence[0].platformProvisioningAttestation.observedAt mismatch"

write_fixture
node - "$report_dir/passkey-deployment-evidence-template.json" <<'NODE'
const fs = require('fs')
const file = process.argv[2]
const data = JSON.parse(fs.readFileSync(file, 'utf8'))
data.deploymentEvidence[0].platformProvisioningAttestation.payloadSha256 = 'sha256:TODO_UNBOUND_PLATFORM_PAYLOAD'
fs.writeFileSync(file, JSON.stringify(data, null, 2))
NODE
expect_failure "passkey platform payload target drift fixture" "passkey-deployment-evidence.passkeyDeploymentEvidenceTemplate.deploymentEvidence[0].platformProvisioningAttestation.payloadSha256 mismatch"

write_fixture
node - "$report_dir/passkey-deployment-evidence-template.json" <<'NODE'
const fs = require('fs')
const file = process.argv[2]
const data = JSON.parse(fs.readFileSync(file, 'utf8'))
data.deploymentEvidence[0].liveHealthAttestation.unreviewed = true
fs.writeFileSync(file, JSON.stringify(data, null, 2))
NODE
expect_failure "passkey attestation extra-field fixture" "unsupported passkey-deployment-evidence.passkeyDeploymentEvidenceTemplate.deploymentEvidence[0].liveHealthAttestation key: unreviewed"

write_fixture
rm "$workspace_dir/config/passkey-backup-production.json"
expect_failure "missing passkey production config fixture" "passkey-production-smoke.passkeyProductionContractHandoff.productionConfigSourcePath missing"

write_fixture
node - "$workspace_dir/config/passkey-backup-production.json" <<'NODE'
const fs = require('fs')
const file = process.argv[2]
const data = JSON.parse(fs.readFileSync(file, 'utf8'))
data.challengeServiceBaseUrl = 'https://backup.example.invalid'
fs.writeFileSync(file, JSON.stringify(data, null, 2))
NODE
expect_failure "bad passkey production config base URL fixture" "passkey-production-smoke.passkeyProductionContract.productionConfig.challengeServiceBaseUrl mismatch"

write_fixture
node - "$workspace_dir/config/passkey-backup-production.json" <<'NODE'
const fs = require('fs')
const file = process.argv[2]
const data = JSON.parse(fs.readFileSync(file, 'utf8'))
data.releaseEnabled = true
fs.writeFileSync(file, JSON.stringify(data, null, 2))
NODE
expect_failure "enabled passkey production release fixture" "passkey-production-smoke.passkeyProductionContract.productionConfig.releaseEnabled must be false"

write_fixture
node - "$workspace_dir/config/passkey-backup-production.json" <<'NODE'
const fs = require('fs')
const file = process.argv[2]
const data = JSON.parse(fs.readFileSync(file, 'utf8'))
data.android.webauthnOrigin = 'android:apk-key-hash:WRONG_RELEASE_SIGNER'
fs.writeFileSync(file, JSON.stringify(data, null, 2))
NODE
expect_failure "bad passkey production Android origin fixture" "passkey-production-smoke.passkeyProductionContract.productionConfig.android.webauthnOrigin mismatch"

write_fixture
node - "$workspace_dir/config/passkey-backup-production.json" <<'NODE'
const fs = require('fs')
const file = process.argv[2]
const data = JSON.parse(fs.readFileSync(file, 'utf8'))
data.requestAuthorization.failClosed = false
fs.writeFileSync(file, JSON.stringify(data, null, 2))
NODE
expect_failure "permissive passkey request authorization fixture" "passkey-production-smoke.passkeyProductionContract.productionConfig.requestAuthorization.failClosed mismatch"

write_fixture
node - "$workspace_dir/config/passkey-backup-production.json" <<'NODE'
const fs = require('fs')
const file = process.argv[2]
const data = JSON.parse(fs.readFileSync(file, 'utf8'))
data.requestAuthorization.protectedPaths.pop()
fs.writeFileSync(file, JSON.stringify(data, null, 2))
NODE
expect_failure "incomplete passkey protected paths fixture" "passkey-production-smoke.passkeyProductionContract.productionConfig.requestAuthorization.protectedPaths length mismatch"

write_fixture
node - "$workspace_dir/config/passkey-backup-production.json" <<'NODE'
const fs = require('fs')
const file = process.argv[2]
const data = JSON.parse(fs.readFileSync(file, 'utf8'))
delete data.challengeServicePaths.credentialsRevokeAll
fs.writeFileSync(file, JSON.stringify(data, null, 2))
NODE
expect_failure "passkey lifecycle path removal fixture" "passkey-production-smoke.passkeyProductionContract.productionConfig.challengeServicePaths.credentialsRevokeAll must be a non-empty string"

write_fixture
node - "$workspace_dir/config/passkey-backup-production.json" <<'NODE'
const fs = require('fs')
const file = process.argv[2]
const data = JSON.parse(fs.readFileSync(file, 'utf8'))
data.credentialLifecycle.finalRevocationRetainsOwnerTombstone = false
fs.writeFileSync(file, JSON.stringify(data, null, 2))
NODE
expect_failure "passkey credentialLifecycle drift fixture" "passkey-production-smoke.passkeyProductionContract.productionConfig.credentialLifecycle.finalRevocationRetainsOwnerTombstone mismatch"

write_fixture
node - "$workspace_dir/config/passkey-backup-production.json" <<'NODE'
const fs = require('fs')
const file = process.argv[2]
const data = JSON.parse(fs.readFileSync(file, 'utf8'))
data.challengeServicePaths.credentialsList = '/api/passkey-backup/v1/credentials/enumerate'
fs.writeFileSync(file, JSON.stringify(data, null, 2))
NODE
expect_failure "passkey lifecycle route handoff drift fixture" "passkey-production-smoke.passkeyProductionContract.productionConfig.challengeServicePaths.credentialsList mismatch"

write_fixture
node - "$workspace_dir/config/passkey-backup-challenge-service.openapi.json" <<'NODE'
const fs = require('fs')
const file = process.argv[2]
const data = JSON.parse(fs.readFileSync(file, 'utf8'))
delete data.paths['/api/passkey-backup/v1/registration/challenge']
fs.writeFileSync(file, JSON.stringify(data, null, 2))
NODE
expect_failure "bad passkey OpenAPI route fixture" "passkey-production-smoke.passkeyProductionContract.openApi.paths./api/passkey-backup/v1/registration/challenge.post missing"

write_fixture
node - "$workspace_dir/config/passkey-backup-challenge-service.openapi.json" <<'NODE'
const fs = require('fs')
const file = process.argv[2]
const data = JSON.parse(fs.readFileSync(file, 'utf8'))
data.info.description = 'WebAuthn challenge service.'
fs.writeFileSync(file, JSON.stringify(data, null, 2))
NODE
expect_failure "weakened passkey OpenAPI description fixture" "passkey-production-smoke.passkeyProductionContract.openApi.info.description mismatch"

write_fixture
node - "$workspace_dir/config/passkey-backup-challenge-service.openapi.json" <<'NODE'
const fs = require('fs')
const file = process.argv[2]
const data = JSON.parse(fs.readFileSync(file, 'utf8'))
delete data.paths['/api/passkey-backup/v1/assertion/complete'].post.security
fs.writeFileSync(file, JSON.stringify(data, null, 2))
NODE
expect_failure "unprotected passkey OpenAPI POST fixture" "passkey-production-smoke.passkeyProductionContract.openApi.paths./api/passkey-backup/v1/assertion/complete.post.security must require bearerAuth"

for status in 401 403 503; do
  write_fixture
  node - "$workspace_dir/config/passkey-backup-challenge-service.openapi.json" "$status" <<'NODE'
const fs = require('fs')
const [file, status] = process.argv.slice(2)
const data = JSON.parse(fs.readFileSync(file, 'utf8'))
data.paths['/api/passkey-backup/v1/registration/challenge'].post.responses[status].$ref = '#/components/responses/BadRequest'
fs.writeFileSync(file, JSON.stringify(data, null, 2))
NODE
  expect_failure "bad passkey OpenAPI ${status} response fixture" "passkey-production-smoke.passkeyProductionContract.openApi.paths./api/passkey-backup/v1/registration/challenge.post.responses.${status} reference mismatch"
done

write_fixture
node - "$workspace_dir/config/passkey-backup-challenge-service.openapi.json" <<'NODE'
const fs = require('fs')
const file = process.argv[2]
const data = JSON.parse(fs.readFileSync(file, 'utf8'))
data.components.responses.AuthorizationFailed.content['application/json'].schema.$ref = '#/components/schemas/HealthResponse'
fs.writeFileSync(file, JSON.stringify(data, null, 2))
NODE
expect_failure "bad passkey OpenAPI ErrorResponse component fixture" "passkey-production-smoke.passkeyProductionContract.openApi.components.responses.AuthorizationFailed must reference #/components/schemas/ErrorResponse"

write_fixture
node - "$workspace_dir/config/passkey-backup-challenge-service.openapi.json" <<'NODE'
const fs = require('fs')
const file = process.argv[2]
const data = JSON.parse(fs.readFileSync(file, 'utf8'))
data.components.schemas.Base64UrlUserId.minLength = 1
fs.writeFileSync(file, JSON.stringify(data, null, 2))
NODE
expect_failure "weak passkey OpenAPI user ID fixture" "passkey-production-smoke.passkeyProductionContract.openApi.components.schemas.Base64UrlUserId must be canonical 43-character unpadded base64url"

write_fixture
node - "$workspace_dir/config/passkey-backup-challenge-service.openapi.json" <<'NODE'
const fs = require('fs')
const file = process.argv[2]
const data = JSON.parse(fs.readFileSync(file, 'utf8'))
data.components.schemas.AssertionAuthenticatorResponse.required = data.components.schemas.AssertionAuthenticatorResponse.required.filter((field) => field !== 'userHandle')
fs.writeFileSync(file, JSON.stringify(data, null, 2))
NODE
expect_failure "optional passkey assertion userHandle fixture" "passkey-production-smoke.passkeyProductionContract.openApi.components.schemas.AssertionAuthenticatorResponse.userHandle mismatch"

write_fixture
node - "$workspace_dir/config/passkey-backup-challenge-service.openapi.json" <<'NODE'
const fs = require('fs')
const file = process.argv[2]
const data = JSON.parse(fs.readFileSync(file, 'utf8'))
data.components.schemas.CredentialDescriptor.properties.publicKey = { $ref: '#/components/schemas/Base64UrlBlob' }
fs.writeFileSync(file, JSON.stringify(data, null, 2))
NODE
expect_failure "passkey leaked credential descriptor field fixture" "unsupported passkey-production-smoke.passkeyProductionContract.openApi.components.schemas.CredentialDescriptor.properties key: publicKey"

write_fixture
rm "$workspace_dir/services/passkey-backup-challenge-service/docker-compose.production.yml"
expect_failure "missing passkey production compose fixture" "passkey-production-smoke.passkeyProductionContractHandoff.composeSourcePath missing"

write_fixture
printf '%s\n' "services:" > "$outside_log"
rm "$workspace_dir/services/passkey-backup-challenge-service/docker-compose.production.yml"
ln -s "$outside_log" "$workspace_dir/services/passkey-backup-challenge-service/docker-compose.production.yml"
expect_failure "passkey production compose symlink fixture" "passkey-production-smoke.passkeyProductionContractHandoff.composeSourcePath must not use a symlinked path component"

write_fixture
perl -0pi -e 's/"127\.0\.0\.1:8789:8789"/"0.0.0.0:8789:8789"/' "$workspace_dir/services/passkey-backup-challenge-service/docker-compose.production.yml"
expect_failure "public passkey production compose port fixture" "passkey-production-smoke.passkeyProductionContract.compose must include - \"127.0.0.1:8789:8789\""

write_fixture
perl -0pi -e 's#    image: "\$\{PASSKEY_BACKUP_IMAGE_REPOSITORY:\?[^\n]+#    image: passkey-backup-challenge-service:release#' "$workspace_dir/services/passkey-backup-challenge-service/docker-compose.production.yml"
expect_failure "mutable passkey production compose image fixture" "passkey-production-smoke.passkeyProductionContract.compose must include image: \"\${PASSKEY_BACKUP_IMAGE_REPOSITORY:?Set the reviewed passkey image repository}@sha256:\${PASSKEY_BACKUP_IMAGE_DIGEST:?Set the reviewed 64-character lowercase image digest}\""

write_fixture
perl -0pi -e 's#https://fearlesswallet.io,https://backup.fearlesswallet.io#https://example.invalid#g' "$workspace_dir/services/passkey-backup-challenge-service/docker-compose.production.yml"
expect_failure "bad passkey production compose origins fixture" "passkey-production-smoke.passkeyProductionContract.compose must include PASSKEY_ALLOWED_ORIGINS: https://fearlesswallet.io,https://backup.fearlesswallet.io"

write_fixture
node - "$workspace_dir/services/passkey-backup-challenge-service/docker-compose.production.yml" <<'NODE'
const fs = require('fs')
const file = process.argv[2]
const content = fs.readFileSync(file, 'utf8').replace(
  'PASSKEY_ANDROID_ALLOWED_ORIGIN: "${PASSKEY_ANDROID_ALLOWED_ORIGIN:?',
  'PASSKEY_ANDROID_ALLOWED_ORIGIN: "${PASSKEY_ANDROID_ALLOWED_ORIGIN:-',
)
fs.writeFileSync(file, content)
NODE
expect_failure "permissive passkey Android origin fallback fixture" "passkey-production-smoke.passkeyProductionContract.compose must include PASSKEY_ANDROID_ALLOWED_ORIGIN: \"\${PASSKEY_ANDROID_ALLOWED_ORIGIN:?"

write_fixture
perl -0pi -e 's/PASSKEY_AUTHORIZATION_AUDIENCE: fearless-passkey-backup/PASSKEY_AUTHORIZATION_AUDIENCE: public/' "$workspace_dir/services/passkey-backup-challenge-service/docker-compose.production.yml"
expect_failure "bad passkey authorization audience fixture" "passkey-production-smoke.passkeyProductionContract.compose must include PASSKEY_AUTHORIZATION_AUDIENCE: fearless-passkey-backup"

write_fixture
perl -0pi -e 's/PASSKEY_TRUST_PROXY_HOPS: "1"/PASSKEY_TRUST_PROXY_HOPS: "0"/' "$workspace_dir/services/passkey-backup-challenge-service/docker-compose.production.yml"
expect_failure "disabled passkey trusted proxy hop fixture" "passkey-production-smoke.passkeyProductionContract.compose must include PASSKEY_TRUST_PROXY_HOPS: \"1\""

write_fixture
perl -0pi -e 's/PASSKEY_RATE_LIMIT_MAX_REQUESTS: "120"/PASSKEY_RATE_LIMIT_MAX_REQUESTS: "999999"/' "$workspace_dir/services/passkey-backup-challenge-service/docker-compose.production.yml"
expect_failure "permissive passkey client rate limit fixture" "passkey-production-smoke.passkeyProductionContract.compose must include PASSKEY_RATE_LIMIT_MAX_REQUESTS: \"120\""

write_fixture
perl -0pi -e 's#PASSKEY_CREDENTIAL_STORE_FILE: /data/passkey-backup/credentials.json#PASSKEY_CREDENTIAL_STORE_FILE: /tmp/credentials.json#' "$workspace_dir/services/passkey-backup-challenge-service/docker-compose.production.yml"
expect_failure "ephemeral passkey credential store fixture" "passkey-production-smoke.passkeyProductionContract.compose must include PASSKEY_CREDENTIAL_STORE_FILE: /data/passkey-backup/credentials.json"

write_fixture
rm "$report_dir/nexus-production-evidence-template.json"
expect_failure "missing Nexus production evidence template report fixture" "iroha-release-readiness.nexusProductionEvidenceTemplateHandoff.sourceReportPath missing"

write_fixture
node - "$report_dir/nexus-production-evidence-template.json" <<'NODE'
const fs = require('fs')
const file = process.argv[2]
const data = JSON.parse(fs.readFileSync(file, 'utf8'))
data.scope = 'sora-nexus-staging-readiness'
fs.writeFileSync(file, JSON.stringify(data, null, 2))
NODE
expect_failure "bad Nexus production evidence template scope fixture" "iroha-release-readiness.nexusProductionEvidenceTemplate.scope mismatch"

write_fixture
node - "$report_dir/nexus-production-evidence-template.json" <<'NODE'
const fs = require('fs')
const file = process.argv[2]
const data = JSON.parse(fs.readFileSync(file, 'utf8'))
data.routePublicationEvidence[0].routeManifestSourcePath = 'tmp/operator-selected-route.json'
fs.writeFileSync(file, JSON.stringify(data, null, 2))
NODE
expect_failure "operator-selected Nexus route manifest source fixture" "iroha-release-readiness.nexusProductionEvidenceTemplate.routePublicationEvidence[0].routeManifestSourcePath mismatch"

write_fixture
node - "$report_dir/nexus-production-evidence-template.json" <<'NODE'
const fs = require('fs')
const file = process.argv[2]
const data = JSON.parse(fs.readFileSync(file, 'utf8'))
data.routePublicationEvidence[0].publishedAt = 'TODO_UTC_ROUTE_PUBLISHED_AT_SECONDS'
fs.writeFileSync(file, JSON.stringify(data, null, 2))
NODE
expect_failure "legacy Nexus seconds timestamp placeholder fixture" "iroha-release-readiness.nexusProductionEvidenceTemplate.routePublicationEvidence[0].publishedAt mismatch"

write_fixture
node - "$report_dir/nexus-production-evidence-template.json" <<'NODE'
const fs = require('fs')
const file = process.argv[2]
const data = JSON.parse(fs.readFileSync(file, 'utf8'))
data.routeCanaryEvidence[0].amount = 'TODO_UNBOUND_AMOUNT'
fs.writeFileSync(file, JSON.stringify(data, null, 2))
NODE
expect_failure "unbound Nexus route canary amount fixture" "iroha-release-readiness.nexusProductionEvidenceTemplate.routeCanaryEvidence[0].amount mismatch"

write_fixture
node - "$report_dir/nexus-production-evidence-template.json" <<'NODE'
const fs = require('fs')
const file = process.argv[2]
const data = JSON.parse(fs.readFileSync(file, 'utf8'))
data.walletSmokeEvidence[0].walletSmokeTransactionHash = '0x0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef'
fs.writeFileSync(file, JSON.stringify(data, null, 2))
NODE
expect_failure "bad Nexus production evidence template placeholder fixture" "iroha-release-readiness.nexusProductionEvidenceTemplate.walletSmokeEvidence[0].walletSmokeTransactionHash mismatch"

write_fixture
rm "$report_dir/ti-deployment-evidence-template.json"
expect_failure "missing TI deployment template report fixture" "ti-deployment-evidence.indexerDeploymentTemplateHandoff.sourceReportPath missing"

write_fixture
node - "$report_dir/ti-deployment-evidence-template.json" <<'NODE'
const fs = require('fs')
const file = process.argv[2]
const data = JSON.parse(fs.readFileSync(file, 'utf8'))
data.scope = 'ton-indexer-staging-deployment-readiness'
fs.writeFileSync(file, JSON.stringify(data, null, 2))
NODE
expect_failure "bad TI deployment template scope fixture" "ti-deployment-evidence.indexerDeploymentEvidenceTemplate.scope mismatch"

write_fixture
node - "$report_dir/ti-deployment-evidence-template.json" <<'NODE'
const fs = require('fs')
const file = process.argv[2]
const data = JSON.parse(fs.readFileSync(file, 'utf8'))
data.deploymentEvidence[0].commit = '0123456789abcdef0123456789abcdef01234567'
fs.writeFileSync(file, JSON.stringify(data, null, 2))
NODE
expect_failure "bad TI deployment template placeholder fixture" "ti-deployment-evidence.indexerDeploymentEvidenceTemplate.deploymentEvidence[0].commit placeholder mismatch"

write_fixture
rm "$report_dir/si-deployment-evidence-template.json"
expect_failure "missing SI deployment template report fixture" "si-deployment-evidence.indexerDeploymentTemplateHandoff.sourceReportPath missing"

write_fixture
node - "$report_dir/si-deployment-evidence-template.json" <<'NODE'
const fs = require('fs')
const file = process.argv[2]
const data = JSON.parse(fs.readFileSync(file, 'utf8'))
data.scope = 'solswap-indexer-staging-deployment-readiness'
fs.writeFileSync(file, JSON.stringify(data, null, 2))
NODE
expect_failure "bad SI deployment template scope fixture" "si-deployment-evidence.indexerDeploymentEvidenceTemplate.scope mismatch"

write_fixture
node - "$report_dir/si-deployment-evidence-template.json" <<'NODE'
const fs = require('fs')
const file = process.argv[2]
const data = JSON.parse(fs.readFileSync(file, 'utf8'))
data.deploymentEvidence[0].commit = '0123456789abcdef0123456789abcdef01234567'
fs.writeFileSync(file, JSON.stringify(data, null, 2))
NODE
expect_failure "bad SI deployment template placeholder fixture" "si-deployment-evidence.indexerDeploymentEvidenceTemplate.deploymentEvidence[0].commit placeholder mismatch"

write_fixture
node - "$report_dir/si-deployment-evidence-template.json" <<'NODE'
const fs = require('fs')
const file = process.argv[2]
const data = JSON.parse(fs.readFileSync(file, 'utf8'))
data.deploymentEvidence[0].healthInfo.genesisHash = 'GH7ome3EiwEr7tu9JuTh2dpYWBJK3z69Xm1ZE3MEE6JC'
fs.writeFileSync(file, JSON.stringify(data, null, 2))
NODE
expect_failure "bad SI deployment template genesis target fixture" "si-deployment-evidence.indexerDeploymentEvidenceTemplate.deploymentEvidence[0].healthInfo.genesisHash mismatch"

write_fixture
node - "$report_dir/si-deployment-evidence-template.json" <<'NODE'
const fs = require('fs')
const file = process.argv[2]
const data = JSON.parse(fs.readFileSync(file, 'utf8'))
data.deploymentEvidence[0].healthInfo.latestSlot = 'TODO_ANY_SLOT'
fs.writeFileSync(file, JSON.stringify(data, null, 2))
NODE
expect_failure "bad SI deployment template slot target fixture" "si-deployment-evidence.indexerDeploymentEvidenceTemplate.deploymentEvidence[0].healthInfo.latestSlot mismatch"

write_fixture
node - "$report_dir/si-deployment-evidence-template.json" <<'NODE'
const fs = require('fs')
const file = process.argv[2]
const data = JSON.parse(fs.readFileSync(file, 'utf8'))
data.deploymentEvidence[0].healthInfo.syncedAt = 'TODO_ANY_TIMESTAMP'
fs.writeFileSync(file, JSON.stringify(data, null, 2))
NODE
expect_failure "bad SI deployment template freshness target fixture" "si-deployment-evidence.indexerDeploymentEvidenceTemplate.deploymentEvidence[0].healthInfo.syncedAt mismatch"

write_fixture
rm "$report_dir/pi-deployment-evidence-template.json"
expect_failure "missing PI deployment template report fixture" "pi-deployment-evidence.indexerDeploymentTemplateHandoff.sourceReportPath missing"

write_fixture
node - "$report_dir/pi-deployment-evidence-template.json" <<'NODE'
const fs = require('fs')
const file = process.argv[2]
const data = JSON.parse(fs.readFileSync(file, 'utf8'))
data.scope = 'polkaswap-indexer-staging-deployment-readiness'
fs.writeFileSync(file, JSON.stringify(data, null, 2))
NODE
expect_failure "bad PI deployment template scope fixture" "pi-deployment-evidence.indexerDeploymentEvidenceTemplate.scope mismatch"

write_fixture
node - "$report_dir/pi-deployment-evidence-template.json" <<'NODE'
const fs = require('fs')
const file = process.argv[2]
const data = JSON.parse(fs.readFileSync(file, 'utf8'))
data.blockers = data.blockers.filter((blocker) => blocker !== 'live-production-smoke-failing')
fs.writeFileSync(file, JSON.stringify(data, null, 2))
NODE
expect_failure "missing PI live-smoke blocker fixture" "pi-deployment-evidence.indexerDeploymentEvidenceTemplate.blockers length mismatch"

write_fixture
node - "$report_dir/pi-deployment-evidence-template.json" <<'NODE'
const fs = require('fs')
const file = process.argv[2]
const data = JSON.parse(fs.readFileSync(file, 'utf8'))
data.lastReviewed = '2026-02-31'
fs.writeFileSync(file, JSON.stringify(data, null, 2))
NODE
expect_failure "bad PI deployment template invalid lastReviewed fixture" "pi-deployment-evidence.indexerDeploymentEvidenceTemplate.lastReviewed must be a valid YYYY-MM-DD date"

write_fixture
node - "$report_dir/pi-deployment-evidence-template.json" <<'NODE'
const fs = require('fs')
const file = process.argv[2]
const data = JSON.parse(fs.readFileSync(file, 'utf8'))
data.lastReviewed = '2999-01-01'
fs.writeFileSync(file, JSON.stringify(data, null, 2))
NODE
expect_failure "bad PI deployment template future lastReviewed fixture" "pi-deployment-evidence.indexerDeploymentEvidenceTemplate.lastReviewed must not be in the future"

write_fixture
node - "$report_dir/pi-deployment-evidence-template.json" <<'NODE'
const fs = require('fs')
const file = process.argv[2]
const data = JSON.parse(fs.readFileSync(file, 'utf8'))
data.deploymentEvidence[0].commit = '0123456789abcdef0123456789abcdef01234567'
fs.writeFileSync(file, JSON.stringify(data, null, 2))
NODE
expect_failure "bad PI deployment template placeholder fixture" "pi-deployment-evidence.indexerDeploymentEvidenceTemplate.deploymentEvidence[0].commit placeholder mismatch"

write_fixture
node - "$report_dir/pi-deployment-evidence-template.json" <<'NODE'
const fs = require('fs')
const file = process.argv[2]
const data = JSON.parse(fs.readFileSync(file, 'utf8'))
data.requiredEvidenceFields = data.requiredEvidenceFields.filter((field) => field !== 'soraRpcControls')
fs.writeFileSync(file, JSON.stringify(data, null, 2))
NODE
expect_failure "missing PI SORA RPC required field fixture" "pi-deployment-evidence.indexerDeploymentEvidenceTemplate.requiredEvidenceFields length mismatch"

write_fixture
node - "$report_dir/pi-deployment-evidence-template.json" <<'NODE'
const fs = require('fs')
const file = process.argv[2]
const data = JSON.parse(fs.readFileSync(file, 'utf8'))
delete data.deploymentEvidence[0].soraRpcControls
fs.writeFileSync(file, JSON.stringify(data, null, 2))
NODE
expect_failure "missing PI SORA RPC controls fixture" "pi-deployment-evidence.indexerDeploymentEvidenceTemplate.deploymentEvidence[0].soraRpcControls must be an object"

write_fixture
node - "$report_dir/pi-deployment-evidence-template.json" <<'NODE'
const fs = require('fs')
const file = process.argv[2]
const data = JSON.parse(fs.readFileSync(file, 'utf8'))
data.deploymentEvidence[0].soraRpcControls.unreviewedTrustOverride = true
fs.writeFileSync(file, JSON.stringify(data, null, 2))
NODE
expect_failure "extra PI SORA RPC trust key fixture" "unsupported pi-deployment-evidence.indexerDeploymentEvidenceTemplate.deploymentEvidence[0].soraRpcControls key: unreviewedTrustOverride"

write_fixture
node - "$report_dir/pi-deployment-evidence-template.json" <<'NODE'
const fs = require('fs')
const file = process.argv[2]
const data = JSON.parse(fs.readFileSync(file, 'utf8'))
data.deploymentEvidence[0].soraRpcControls.primaryEndpoint = 'wss://ws.mof.sora.org'
fs.writeFileSync(file, JSON.stringify(data, null, 2))
NODE
expect_failure "public-convenience PI primary RPC fixture" "pi-deployment-evidence.indexerDeploymentEvidenceTemplate.deploymentEvidence[0].soraRpcControls.primaryEndpoint mismatch"

write_fixture
node - "$report_dir/pi-deployment-evidence-template.json" <<'NODE'
const fs = require('fs')
const file = process.argv[2]
const data = JSON.parse(fs.readFileSync(file, 'utf8'))
data.deploymentEvidence[0].soraRpcControls.archiveNodeControl = 'same-operator-primary-mirror'
fs.writeFileSync(file, JSON.stringify(data, null, 2))
NODE
expect_failure "non-independent PI archive RPC fixture" "pi-deployment-evidence.indexerDeploymentEvidenceTemplate.deploymentEvidence[0].soraRpcControls.archiveNodeControl mismatch"

write_fixture
node - "$report_dir/pi-deployment-evidence-template.json" <<'NODE'
const fs = require('fs')
const file = process.argv[2]
const data = JSON.parse(fs.readFileSync(file, 'utf8'))
data.deploymentEvidence[0].soraRpcControls.distinctHosts = false
fs.writeFileSync(file, JSON.stringify(data, null, 2))
NODE
expect_failure "same-host PI SORA RPC fixture" "pi-deployment-evidence.indexerDeploymentEvidenceTemplate.deploymentEvidence[0].soraRpcControls.distinctHosts mismatch"

write_fixture
node - "$report_dir/pi-deployment-evidence-template.json" <<'NODE'
const fs = require('fs')
const file = process.argv[2]
const data = JSON.parse(fs.readFileSync(file, 'utf8'))
data.deploymentEvidence[0].soraRpcControls.exactIdentityPreflight = false
fs.writeFileSync(file, JSON.stringify(data, null, 2))
NODE
expect_failure "disabled PI exact identity preflight fixture" "pi-deployment-evidence.indexerDeploymentEvidenceTemplate.deploymentEvidence[0].soraRpcControls.exactIdentityPreflight mismatch"

write_fixture
node - "$report_dir/pi-deployment-evidence-template.json" <<'NODE'
const fs = require('fs')
const file = process.argv[2]
const data = JSON.parse(fs.readFileSync(file, 'utf8'))
data.deploymentEvidence[0].soraRpcControls.rawPayloadAgreement = 'height-hash-decoded-events-timestamp-seconds'
fs.writeFileSync(file, JSON.stringify(data, null, 2))
NODE
expect_failure "weakened PI raw RPC payload agreement fixture" "pi-deployment-evidence.indexerDeploymentEvidenceTemplate.deploymentEvidence[0].soraRpcControls.rawPayloadAgreement mismatch"

write_fixture
node - "$report_dir/pi-deployment-evidence-template.json" <<'NODE'
const fs = require('fs')
const file = process.argv[2]
const data = JSON.parse(fs.readFileSync(file, 'utf8'))
data.requiredEvidenceFields = data.requiredEvidenceFields.filter((field) => field !== 'tlsEdgeControls')
fs.writeFileSync(file, JSON.stringify(data, null, 2))
NODE
expect_failure "missing PI TLS-edge required field fixture" "pi-deployment-evidence.indexerDeploymentEvidenceTemplate.requiredEvidenceFields length mismatch"

write_fixture
node - "$report_dir/pi-deployment-evidence-template.json" <<'NODE'
const fs = require('fs')
const file = process.argv[2]
const data = JSON.parse(fs.readFileSync(file, 'utf8'))
delete data.deploymentEvidence[0].tlsEdgeControls
fs.writeFileSync(file, JSON.stringify(data, null, 2))
NODE
expect_failure "missing PI TLS-edge controls fixture" "pi-deployment-evidence.indexerDeploymentEvidenceTemplate.deploymentEvidence[0].tlsEdgeControls must be an object"

write_fixture
node - "$report_dir/pi-deployment-evidence-template.json" <<'NODE'
const fs = require('fs')
const file = process.argv[2]
const data = JSON.parse(fs.readFileSync(file, 'utf8'))
data.deploymentEvidence[0].tlsEdgeControls.tlsTermination = false
fs.writeFileSync(file, JSON.stringify(data, null, 2))
NODE
expect_failure "weakened PI TLS termination fixture" "pi-deployment-evidence.indexerDeploymentEvidenceTemplate.deploymentEvidence[0].tlsEdgeControls.tlsTermination mismatch"

write_fixture
node - "$report_dir/pi-deployment-evidence-template.json" <<'NODE'
const fs = require('fs')
const file = process.argv[2]
const data = JSON.parse(fs.readFileSync(file, 'utf8'))
data.deploymentEvidence[0].tlsEdgeControls.webSocketClientIpLimits.maxConcurrentConnections = 17
fs.writeFileSync(file, JSON.stringify(data, null, 2))
NODE
expect_failure "tampered PI WebSocket connection target fixture" "pi-deployment-evidence.indexerDeploymentEvidenceTemplate.deploymentEvidence[0].tlsEdgeControls.webSocketClientIpLimits.maxConcurrentConnections mismatch"

write_fixture
rm "$report_dir/android-xcm-production-evidence-template.json"
expect_failure "missing Android XCM production evidence template fixture" "android-xcm-production-evidence.xcmProductionEvidenceTemplateHandoff.sourceReportPath missing"

write_fixture
node - "$report_dir/android-xcm-production-evidence-template.json" <<'NODE'
const fs = require('fs')
const file = process.argv[2]
const data = JSON.parse(fs.readFileSync(file, 'utf8'))
data.scope = 'android-xcm-production-evidence-template-v0'
fs.writeFileSync(file, JSON.stringify(data, null, 2))
NODE
expect_failure "bad Android XCM production evidence template scope fixture" "android-xcm-production-evidence.xcmProductionEvidenceTemplate.scope mismatch"

write_fixture
edit_xcm_production_evidence_template "data.instructions[4] = 'Set lastReviewed whenever convenient.'"
expect_failure "weakened Android XCM chronology instruction fixture" "android-xcm-production-evidence.xcmProductionEvidenceTemplate.instructions[4] mismatch"

write_fixture
node - "$report_dir/android-xcm-production-evidence-template.json" <<'NODE'
const fs = require('fs')
const file = process.argv[2]
const data = JSON.parse(fs.readFileSync(file, 'utf8'))
data.evidence[0].androidCommit = '0123456789abcdef0123456789abcdef01234567'
fs.writeFileSync(file, JSON.stringify(data, null, 2))
NODE
expect_failure "bad Android XCM production evidence template placeholder fixture" "android-xcm-production-evidence.xcmProductionEvidenceTemplate.evidence[0].androidCommit placeholder mismatch"

write_fixture
edit_xcm_production_evidence_template "data.requiredEvidenceFields = data.requiredEvidenceFields.filter((field) => field !== 'originBlockHash')"
expect_failure "Android XCM required evidence field removal fixture" "android-xcm-production-evidence.xcmProductionEvidenceTemplate.requiredEvidenceFields length mismatch"

write_fixture
edit_xcm_production_evidence_template "const value = data.requiredEvidenceFields[4]; data.requiredEvidenceFields[4] = data.requiredEvidenceFields[5]; data.requiredEvidenceFields[5] = value"
expect_failure "Android XCM required evidence field order fixture" "android-xcm-production-evidence.xcmProductionEvidenceTemplate.requiredEvidenceFields[4] mismatch"

write_fixture
edit_xcm_production_evidence_template "data.evidence[0].originFinalized = 'false'"
expect_failure "Android XCM boolean placeholder type fixture" "android-xcm-production-evidence.xcmProductionEvidenceTemplate.evidence[0].originFinalized must be boolean"

write_fixture
edit_xcm_production_evidence_template "delete data.evidence[0].destinationBalanceDelta"
expect_failure "Android XCM newly required evidence value removal fixture" "android-xcm-production-evidence.xcmProductionEvidenceTemplate.evidence[0].destinationBalanceDelta must be a non-empty string"

write_fixture
rm "$report_dir/android-xcm-registry-gap-report.json"
expect_failure "missing Android XCM registry gap report fixture" "android-xcm-production-evidence.xcmRegistryHandoff.sourceReportPath missing"

write_fixture
node - "$report_dir/android-xcm-registry-gap-report.json" <<'NODE'
const fs = require('fs')
const file = process.argv[2]
const data = JSON.parse(fs.readFileSync(file, 'utf8'))
data.schemaVersion = 2
fs.writeFileSync(file, JSON.stringify(data, null, 2))
NODE
expect_failure "bad Android XCM registry gap report schema fixture" "android-xcm-production-evidence.xcmRegistryGapReport.schemaVersion must be 1"

write_fixture
node - "$report_dir/android-xcm-registry-gap-report.json" <<'NODE'
const fs = require('fs')
const file = process.argv[2]
const data = JSON.parse(fs.readFileSync(file, 'utf8'))
data.summary.remainingDiscoveryOnlyDestinations = 2
fs.writeFileSync(file, JSON.stringify(data, null, 2))
NODE
expect_failure "bad Android XCM registry gap count fixture" "android-xcm-production-evidence.xcmRegistryGapReport.missingExecutableDestinations length must match summary.remainingDiscoveryOnlyDestinations"

write_fixture
node - "$report_dir/android-xcm-registry-gap-report.json" <<'NODE'
const fs = require('fs')
const file = process.argv[2]
const data = JSON.parse(fs.readFileSync(file, 'utf8'))
data.summary.remainingDiscoveryOnlyRouteAssets = 1
fs.writeFileSync(file, JSON.stringify(data, null, 2))
NODE
expect_failure "bad Android XCM registry route-asset gap count fixture" "android-xcm-production-evidence.xcmRegistryGapReport.summary.remainingDiscoveryOnlyRouteAssets must match the sum of missingExecutableDestinations[].assetSymbols lengths"

write_fixture
rm "$report_dir/android-xcm-effective-registry-report.json"
expect_failure "missing Android XCM effective-registry report fixture" "android-xcm-production-evidence.xcmRegistryHandoff.effectiveRegistry.sourceReportPath missing"

write_fixture
edit_xcm_effective_report "data.inputs.discoveryRegistry.sha256 = 'not-a-sha256'"
expect_failure "bad Android XCM discovery hash fixture" "android-xcm-production-evidence.xcmEffectiveRegistryReport.inputs.discoveryRegistry.sha256 must be lowercase SHA-256"

write_fixture
edit_xcm_effective_report "data.inputs.approvedRoutes.source = '../attacker-routes.tsv'"
expect_failure "bad Android XCM approved source path fixture" "android-xcm-production-evidence.xcmEffectiveRegistryReport.inputs.approvedRoutes.source mismatch"

write_fixture
edit_xcm_effective_report "data.mode = 'bundled'"
expect_failure "live Android XCM bundled mode fixture" "android-xcm-production-evidence.xcmEffectiveRegistryReport.mode must be discovery when runLive=true"

write_fixture
edit_xcm_effective_report "data.policy.remoteExecutionTrusted = true"
expect_failure "trusted Android XCM remote execution fixture" "android-xcm-production-evidence.xcmEffectiveRegistryReport.policy.remoteExecutionTrusted mismatch"

write_fixture
edit_xcm_effective_report "data.policy.productionTransfersEnabled = true"
expect_failure "enabled Android XCM production transfer fixture" "android-xcm-production-evidence.xcmEffectiveRegistryReport.policy.productionTransfersEnabled mismatch"

write_fixture
edit_xcm_effective_report "data.policy.runtimeDiscoverySnapshotBoundToReport = true"
expect_failure "forged Android XCM runtime snapshot binding fixture" "android-xcm-production-evidence.xcmEffectiveRegistryReport.policy.runtimeDiscoverySnapshotBoundToReport mismatch"

write_fixture
edit_xcm_effective_report "data.policy.runtimeDiscoveryFreshnessEnforced = true"
expect_failure "forged Android XCM runtime freshness fixture" "android-xcm-production-evidence.xcmEffectiveRegistryReport.policy.runtimeDiscoveryFreshnessEnforced mismatch"

write_fixture
edit_xcm_effective_report "data.policy.runtimeDiscoveryRequiresSuccessfulProcessSync = false"
expect_failure "Android XCM runtime process-sync bypass fixture" "android-xcm-production-evidence.xcmEffectiveRegistryReport.policy.runtimeDiscoveryRequiresSuccessfulProcessSync mismatch"

write_fixture
edit_xcm_effective_report "data.inputs.discoveryRegistry.source = 'https://attacker.invalid/chains.json'"
expect_failure "bad Android XCM discovery URL fixture" "android-xcm-production-evidence.xcmEffectiveRegistryReport.inputs.discoveryRegistry.source must match the production discovery URL"

write_fixture
edit_xcm_effective_report "data.summary.effective = 2"
expect_failure "bad Android XCM compatible count fixture" "android-xcm-production-evidence.xcmEffectiveRegistryReport.summary.effective must match compatible routes"

write_fixture
edit_xcm_effective_report "data.routes[0].productionExecutable = true; data.summary.productionExecutable = 1"
expect_failure "enabled Android XCM route execution fixture" "android-xcm-production-evidence.xcmEffectiveRegistryReport.routes[0].productionExecutable must be false while production transfers are disabled"

write_fixture
edit_xcm_effective_report "data.routes.push(JSON.parse(JSON.stringify(data.routes[0])))"
expect_failure "duplicate Android XCM effective route fixture" "android-xcm-production-evidence.xcmEffectiveRegistryReport.routes contains duplicate route"

write_fixture
edit_xcm_effective_report "data.routes.reverse()"
expect_failure "unordered Android XCM effective routes fixture" "android-xcm-production-evidence.xcmEffectiveRegistryReport.routes must use deterministic route order"

write_fixture
edit_xcm_effective_report "data.routes[1].reasons = ['attacker-reason']; data.missing[0].reasons = ['attacker-reason']"
expect_failure "unsupported Android XCM compatibility reason fixture" "android-xcm-production-evidence.xcmEffectiveRegistryReport.routes[1].reasons[0] unsupported"

write_fixture
edit_xcm_effective_report "data.missing = []"
expect_failure "Android XCM missing-route set drift fixture" "android-xcm-production-evidence.xcmEffectiveRegistryReport.missing must match ineffective routes"

write_fixture
edit_xcm_effective_report "data.missing[0].reasons = ['origin-xcm-version-mismatch']"
expect_failure "Android XCM missing reason drift fixture" "android-xcm-production-evidence.xcmEffectiveRegistryReport.missing[0].reasons must match ineffective route"

write_fixture
edit_xcm_effective_report "data.extra = []"
expect_failure "Android XCM extra-route set drift fixture" "android-xcm-production-evidence.xcmEffectiveRegistryReport.summary.extra must match extra length"

write_fixture
edit_xcm_effective_report "data.extra[0] = {originChainId: data.routes[0].originChainId, destinationChainId: data.routes[0].destinationChainId, assetSymbol: data.routes[0].assetSymbol}"
expect_failure "approved Android XCM route repeated as extra fixture" "android-xcm-production-evidence.xcmEffectiveRegistryReport.extra route must not be approved"

write_fixture
edit_xcm_effective_report "data.status = 'complete'"
expect_failure "Android XCM status/count mismatch fixture" "android-xcm-production-evidence.xcmEffectiveRegistryReport.status must match missing count"

write_fixture
printf '%s\n' '# stale source mutation' >> "$workspace_dir/fearless-Android/runtime/src/main/assets/approved_xcm_routes.tsv"
expect_failure "stale Android XCM approved source fixture" "android-xcm-production-evidence.xcmEffectiveRegistryReport.inputs.approvedRoutes.byteLength does not match workspace source"

write_fixture
edit_xcm_effective_report "data.inputs.requiredRoutes.sha256 = '0'.repeat(64)"
expect_failure "stale Android XCM required source digest fixture" "android-xcm-production-evidence.xcmEffectiveRegistryReport.inputs.requiredRoutes.sha256 does not match workspace source"

write_fixture
set_fixture_run_live_false
expect_failure "skip-live Android XCM discovery report fixture" "android-xcm-production-evidence.xcmEffectiveRegistryReport.mode must be bundled when runLive=false"

write_fixture
set_fixture_run_live_false
edit_xcm_effective_report "data.mode = 'bundled'; data.status = 'complete'; data.inputs.discoveryRegistry = null; data.routes[1].effective = true; data.routes[1].reasons = []; data.missing = []; data.extra = []; Object.assign(data.summary, {discovered: 2, effective: 2, productionExecutable: 0, missing: 0, extra: 0})"
if ! output="$(run_export 2>&1)"; then
  echo "$output" >&2
  fail "skip-live Android XCM bundled report fixture unexpectedly failed"
fi
node - "$bundle_dir/manifest.json" <<'NODE'
const fs = require('fs')
const manifest = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'))
const effective = manifest.blockers.find((blocker) => blocker.slug === 'android-xcm-production-evidence')?.xcmRegistryHandoff?.effectiveRegistry
if (manifest.runLive !== false || manifest.sourcePublicationHandoff !== null) throw new Error('skip-live bundle source-publication contract mismatch')
if (effective?.mode !== 'bundled' || effective?.status !== 'complete' || effective?.discoveryRegistry !== null) throw new Error('skip-live effective-registry handoff mismatch')
if (effective?.counts?.effective !== 2 || effective?.counts?.productionExecutable !== 0) throw new Error('skip-live compatible/production count mismatch')
if (effective?.auditCommand !== 'cd fearless-Android && bash scripts/audit-xcm-effective-registry.sh --write-report build/reports/xcm-effective-registry-report.json') throw new Error('skip-live effective-registry audit command mismatch')
NODE

write_fixture
node - "$report_dir/summary.json" "$report_dir/actions.json" <<'NODE'
const fs = require('fs')
for (const file of process.argv.slice(2)) {
  const data = JSON.parse(fs.readFileSync(file, 'utf8'))
  data.generatedAt = '2026-06-28T00:04:00Z'
  fs.writeFileSync(file, JSON.stringify(data, null, 2))
}
NODE
perl -0pi -e 's/Generated at: 2026-06-28T00:00:00Z/Generated at: 2026-06-28T00:04:00Z/' "$report_dir/blockers.md"
if ! output="$(run_export_at_time "2026-06-28T00:00:00Z" 2>&1)"; then
  echo "$output" >&2
  fail "manifest generatedAt chronology fixture unexpectedly failed"
fi
node - "$bundle_dir/manifest.json" <<'NODE'
const fs = require('fs')
const manifest = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'))
if (manifest.generatedAt !== '2026-06-28T00:04:00Z') {
  throw new Error(`manifest generatedAt chronology was not clamped to source report time: ${manifest.generatedAt}`)
}
NODE

write_fixture
rm "$report_dir/actions.json"
expect_failure "missing actions fixture" "actions.json missing"

write_fixture
printf '{not-json\n' > "$report_dir/actions.json"
expect_failure "malformed actions fixture" "actions.json is not valid JSON"

write_fixture
rm "$report_dir/release-pr-readiness-report.json"
expect_failure "missing release PR status report fixture" "release-pr-readiness.releasePrStatusReportHandoff.sourceReportPath missing"

write_fixture
node - "$report_dir/release-pr-readiness-report.json" <<'NODE'
const fs = require('fs')
const file = process.argv[2]
const data = JSON.parse(fs.readFileSync(file, 'utf8'))
data.configFile = 'config/release-readiness-prs.tsv'
fs.writeFileSync(file, JSON.stringify(data, null, 2))
NODE
expect_failure "bad release PR status report relative config-file fixture" "release-pr-readiness-report.json.configFile must be an absolute normalized path"

write_fixture
node - "$report_dir/release-pr-readiness-report.json" "$workspace_dir/config/release-readiness-prs-drift.tsv" <<'NODE'
const fs = require('fs')
const [file, configFile] = process.argv.slice(2)
const data = JSON.parse(fs.readFileSync(file, 'utf8'))
data.configFile = configFile
fs.writeFileSync(file, JSON.stringify(data, null, 2))
NODE
expect_failure "bad release PR status report wrong config-file fixture" "release-pr-readiness-report.json.configFile must match config/release-readiness-prs.tsv"

write_fixture
node - "$report_dir/release-pr-readiness-report.json" <<'NODE'
const fs = require('fs')
const file = process.argv[2]
const data = JSON.parse(fs.readFileSync(file, 'utf8'))
data.requirements[0].head = 'codex/wrong-release-head'
fs.writeFileSync(file, JSON.stringify(data, null, 2))
NODE
expect_failure "bad release PR status report config-row head fixture" "release-pr-readiness-report.json.requirements[0].head must match config/release-readiness-prs.tsv line 6"

write_fixture
node - "$report_dir/release-pr-readiness-report.json" <<'NODE'
const fs = require('fs')
const file = process.argv[2]
const data = JSON.parse(fs.readFileSync(file, 'utf8'))
data.requirements[0].requiredChecks = ['validate']
fs.writeFileSync(file, JSON.stringify(data, null, 2))
NODE
expect_failure "bad release PR status report config-row required-checks fixture" "release-pr-readiness-report.json.requirements[0].requiredChecks length must match config/release-readiness-prs.tsv line 6"

write_fixture
node - "$report_dir/release-pr-readiness-report.json" <<'NODE'
const fs = require('fs')
const file = process.argv[2]
const data = JSON.parse(fs.readFileSync(file, 'utf8'))
const swapped = data.requirements[1]
data.requirements[1] = data.requirements[2]
data.requirements[2] = swapped
data.failures = data.requirements.filter((requirement) => requirement.status === 'failed').map((requirement) => requirement.message)
fs.writeFileSync(file, JSON.stringify(data, null, 2))
NODE
expect_failure "bad release PR status report config-row order fixture" "release-pr-readiness-report.json.requirements[2].configLine must match config/release-readiness-prs.tsv order"

write_fixture
node - "$report_dir/release-pr-readiness-report.json" <<'NODE'
const fs = require('fs')
const file = process.argv[2]
const data = JSON.parse(fs.readFileSync(file, 'utf8'))
data.requirements.splice(1, 1)
data.checkedCount -= 1
data.totals.failed -= 1
data.totals.total -= 1
data.failures = data.requirements.filter((requirement) => requirement.status === 'failed').map((requirement) => requirement.message)
fs.writeFileSync(file, JSON.stringify(data, null, 2))
NODE
expect_failure "bad release PR status report config coverage fixture" "release-pr-readiness-report.json.requirements length must match config/release-readiness-prs.tsv"

write_fixture
node - "$report_dir/release-pr-readiness-report.json" <<'NODE'
const fs = require('fs')
const file = process.argv[2]
const data = JSON.parse(fs.readFileSync(file, 'utf8'))
data.generatedAt = '2026-06-28 00:00:00'
fs.writeFileSync(file, JSON.stringify(data, null, 2))
NODE
expect_failure "bad release PR status report non-UTC timestamp fixture" "release-pr-readiness-report.json.generatedAt must be an ISO-8601 UTC timestamp"

write_fixture
node - "$report_dir/release-pr-readiness-report.json" <<'NODE'
const fs = require('fs')
const file = process.argv[2]
const data = JSON.parse(fs.readFileSync(file, 'utf8'))
data.generatedAt = '2026-06-28T12:06:00.000Z'
fs.writeFileSync(file, JSON.stringify(data, null, 2))
NODE
expect_failure_at_time "bad release PR status report future timestamp fixture" "2026-06-28T12:00:00Z" "release-pr-readiness-report.json.generatedAt is in the future"

write_fixture
node - "$report_dir/release-pr-readiness-report.json" <<'NODE'
const fs = require('fs')
const file = process.argv[2]
const data = JSON.parse(fs.readFileSync(file, 'utf8'))
data.totals.passed = 1
data.totals.failed = 3
fs.writeFileSync(file, JSON.stringify(data, null, 2))
NODE
expect_failure "bad release PR status report totals fixture" "release-pr-readiness-report.json.failures length must match totals.failed"

write_fixture
node - "$report_dir/release-pr-readiness-report.json" <<'NODE'
const fs = require('fs')
const file = process.argv[2]
const data = JSON.parse(fs.readFileSync(file, 'utf8'))
data.checkedCount = data.totals.total - 1
fs.writeFileSync(file, JSON.stringify(data, null, 2))
NODE
expect_failure "bad release PR status report checked-count fixture" "release-pr-readiness-report.json.checkedCount must match totals.total"

write_fixture
node - "$report_dir/release-pr-readiness-report.json" <<'NODE'
const fs = require('fs')
const file = process.argv[2]
const data = JSON.parse(fs.readFileSync(file, 'utf8'))
data.requirements[0].status = 'passed'
data.totals.passed = 1
data.totals.failed = 3
data.failures = data.requirements.filter((requirement) => requirement.status === 'failed').map((requirement) => requirement.message)
fs.writeFileSync(file, JSON.stringify(data, null, 2))
NODE
expect_failure "bad release PR status report passed failure-message fixture" "release-pr-readiness-report.json.requirements[0].message contradicts passed status"

write_fixture
node - "$report_dir/release-pr-readiness-report.json" <<'NODE'
const fs = require('fs')
const file = process.argv[2]
const data = JSON.parse(fs.readFileSync(file, 'utf8'))
const requirement = data.requirements[0]
requirement.status = 'passed'
requirement.message = 'soramitsu/fearless-wallet-web#1061 is merged with required checks validate: https://github.com/soramitsu/fearless-wallet-web/pull/1061'
data.totals.passed = 1
data.totals.failed = 3
data.failures = data.requirements.filter((item) => item.status === 'failed').map((item) => item.message)
fs.writeFileSync(file, JSON.stringify(data, null, 2))
NODE
expect_failure "bad release PR status report success required-checks fixture" "release-pr-readiness-report.json.requirements[0].requiredChecks must match success message"

write_fixture
node - "$report_dir/release-pr-readiness-report.json" <<'NODE'
const fs = require('fs')
const file = process.argv[2]
const data = JSON.parse(fs.readFileSync(file, 'utf8'))
const message = 'soramitsu/fearless-wallet-web#1061 is merged with required checks validate,verify: https://github.com/soramitsu/fearless-wallet-web/pull/1061'
data.requirements[0].message = message
data.failures[0] = message
fs.writeFileSync(file, JSON.stringify(data, null, 2))
NODE
expect_failure "bad release PR status report failed success-message fixture" "release-pr-readiness-report.json.requirements[0].message contradicts failed status"

write_fixture
node - "$report_dir/release-pr-readiness-report.json" <<'NODE'
const fs = require('fs')
const file = process.argv[2]
const data = JSON.parse(fs.readFileSync(file, 'utf8'))
data.failures[0] = 'soramitsu/fearless-wallet-web#1061 failure text hidden by tampered report'
fs.writeFileSync(file, JSON.stringify(data, null, 2))
NODE
expect_failure "bad release PR status report failure-message fixture" "release-pr-readiness-report.json.failures[0] must match failed requirement message"

write_fixture
node - "$report_dir/release-pr-readiness-report.json" <<'NODE'
const fs = require('fs')
const file = process.argv[2]
const data = JSON.parse(fs.readFileSync(file, 'utf8'))
const requirement = data.requirements[0]
requirement.message = 'soramitsu/fearless-wallet-web:codex/web-bitcoin-broadcast-evidence -> develop: no merged pull request found'
delete requirement.pr
delete requirement.isDraft
delete requirement.reviewDecision
delete requirement.mergeStateStatus
delete requirement.unresolvedReviewThreads
delete requirement.currentUnresolvedReviewThreads
delete requirement.outdatedUnresolvedReviewThreads
data.failures[0] = requirement.message
fs.writeFileSync(file, JSON.stringify(data, null, 2))
NODE
expect_failure "bad release PR status report failure log parity fixture" "release-pr-readiness-report.json.failures[0] must be present in release PR log"

write_fixture
node - "$report_dir/release-pr-readiness-report.json" <<'NODE'
const fs = require('fs')
const file = process.argv[2]
const data = JSON.parse(fs.readFileSync(file, 'utf8'))
const requirement = data.requirements[1]
requirement.message = requirement.message.replace(/ isDraft=false.*$/, '')
data.failures[1] = requirement.message
fs.writeFileSync(file, JSON.stringify(data, null, 2))
NODE
expect_failure "bad release PR status report failure log substring fixture" "release-pr-readiness-report.json.failures[1] must be present in release PR log as a full failure line"

write_fixture
node - "$report_dir/release-pr-readiness-report.json" <<'NODE'
const fs = require('fs')
const file = process.argv[2]
const data = JSON.parse(fs.readFileSync(file, 'utf8'))
const requirement = data.requirements[0]
requirement.status = 'passed'
requirement.message = 'soramitsu/fearless-wallet-web#1061 is merged with required checks validate,verify: https://github.com/soramitsu/fearless-wallet-web/pull/1061'
delete requirement.isDraft
delete requirement.reviewDecision
delete requirement.mergeStateStatus
delete requirement.unresolvedReviewThreads
delete requirement.currentUnresolvedReviewThreads
delete requirement.outdatedUnresolvedReviewThreads
data.totals.passed = 1
data.totals.failed = 3
data.failures = data.requirements.filter((item) => item.status === 'failed').map((item) => item.message)
fs.writeFileSync(file, JSON.stringify(data, null, 2))
NODE
expect_failure "bad release PR status report passed requirement log parity fixture" "release-pr-readiness-report.json.requirements[0].message must be present in release PR log as a full result line"

write_fixture
printf '%s\n' "[release-pr-readiness][warn] soramitsu/fearless-wallet-web#9999 is merged with required checks validate,verify: https://github.com/soramitsu/fearless-wallet-web/pull/9999" >> "$report_dir/release-pr-readiness.log"
expect_failure "bad release PR status report extra log result fixture" "release-pr-readiness-report.json.logResults"

write_fixture
node - "$report_dir/release-pr-readiness-report.json" <<'NODE'
const fs = require('fs')
const file = process.argv[2]
const data = JSON.parse(fs.readFileSync(file, 'utf8'))
data.requirements[0].pr.url = 'https://github.com/soramitsu/fearless-wallet-web/pull/9999'
fs.writeFileSync(file, JSON.stringify(data, null, 2))
NODE
expect_failure "bad release PR status report URL fixture" "release-pr-readiness-report.json.requirements[0].pr.url mismatch"

write_fixture
node - "$report_dir/release-pr-readiness-report.json" <<'NODE'
const fs = require('fs')
const file = process.argv[2]
const data = JSON.parse(fs.readFileSync(file, 'utf8'))
data.requirements[0].message = data.requirements[0].message.replace('soramitsu/fearless-wallet-web#1061', 'soramitsu/fearless-wallet-web#9999')
data.failures[0] = data.requirements[0].message
fs.writeFileSync(file, JSON.stringify(data, null, 2))
NODE
expect_failure "bad release PR status report message PR reference fixture" "release-pr-readiness-report.json.requirements[0].message must start with PR reference"

write_fixture
node - "$report_dir/release-pr-readiness-report.json" <<'NODE'
const fs = require('fs')
const file = process.argv[2]
const data = JSON.parse(fs.readFileSync(file, 'utf8'))
data.requirements[0].message = data.requirements[0].message.replace('https://github.com/soramitsu/fearless-wallet-web/pull/1061', 'https://github.com/soramitsu/fearless-wallet-web/pull/9999')
data.failures[0] = data.requirements[0].message
fs.writeFileSync(file, JSON.stringify(data, null, 2))
NODE
expect_failure "bad release PR status report message URL fixture" "release-pr-readiness-report.json.requirements[0].message must include PR URL"

write_fixture
node - "$report_dir/release-pr-readiness-report.json" <<'NODE'
const fs = require('fs')
const file = process.argv[2]
const data = JSON.parse(fs.readFileSync(file, 'utf8'))
delete data.requirements[0].pr
fs.writeFileSync(file, JSON.stringify(data, null, 2))
NODE
expect_failure "bad release PR status report missing structured PR fixture" "release-pr-readiness-report.json.requirements[0].pr required when message contains PR reference"

write_fixture
node - "$report_dir/release-pr-readiness-report.json" <<'NODE'
const fs = require('fs')
const file = process.argv[2]
const data = JSON.parse(fs.readFileSync(file, 'utf8'))
data.requirements[0].reviewDecision = 'APPROVED'
fs.writeFileSync(file, JSON.stringify(data, null, 2))
NODE
expect_failure "bad release PR status report review-decision diagnostic fixture" "release-pr-readiness-report.json.requirements[0].reviewDecision must match message diagnostic"

write_fixture
node - "$report_dir/release-pr-readiness-report.json" <<'NODE'
const fs = require('fs')
const file = process.argv[2]
const data = JSON.parse(fs.readFileSync(file, 'utf8'))
data.requirements[0].mergeStateStatus = 'CLEAN'
fs.writeFileSync(file, JSON.stringify(data, null, 2))
NODE
expect_failure "bad release PR status report merge-state diagnostic fixture" "release-pr-readiness-report.json.requirements[0].mergeStateStatus must match message diagnostic"

write_fixture
node - "$report_dir/release-pr-readiness-report.json" <<'NODE'
const fs = require('fs')
const file = process.argv[2]
const data = JSON.parse(fs.readFileSync(file, 'utf8'))
data.requirements[0].isDraft = true
fs.writeFileSync(file, JSON.stringify(data, null, 2))
NODE
expect_failure "bad release PR status report draft diagnostic fixture" "release-pr-readiness-report.json.requirements[0].isDraft must match message diagnostic"

write_fixture
node - "$report_dir/release-pr-readiness-report.json" <<'NODE'
const fs = require('fs')
const file = process.argv[2]
const data = JSON.parse(fs.readFileSync(file, 'utf8'))
data.requirements[1].approvalCount = 99
fs.writeFileSync(file, JSON.stringify(data, null, 2))
NODE
expect_failure "bad release PR status report approval-count diagnostic fixture" "release-pr-readiness-report.json.requirements[1].approvalCount must match message diagnostic"

write_fixture
node - "$report_dir/release-pr-readiness-report.json" <<'NODE'
const fs = require('fs')
const file = process.argv[2]
const data = JSON.parse(fs.readFileSync(file, 'utf8'))
const requirement = data.requirements[1]
requirement.currentHeadApprovalCount = 2
requirement.message = requirement.message.replace('currentHeadApprovalCount=1', 'currentHeadApprovalCount=2')
data.failures[1] = requirement.message
fs.writeFileSync(file, JSON.stringify(data, null, 2))
NODE
expect_failure "bad release PR status report current-head semantic fixture" "release-pr-readiness-report.json.requirements[1].currentHeadApprovalCount must not exceed approvalCount"

write_fixture
node - "$report_dir/release-pr-readiness-report.json" <<'NODE'
const fs = require('fs')
const file = process.argv[2]
const data = JSON.parse(fs.readFileSync(file, 'utf8'))
const requirement = data.requirements[1]
delete requirement.approvalCount
delete requirement.currentHeadApprovalCount
delete requirement.latestApprovalCommit
delete requirement.currentApprovalNotEligible
requirement.message = requirement.message.replace(/ approvalCount=1 currentHeadApprovalCount=1 latestApprovalCommit=[0-9a-f]{40} currentApprovalNotEligible=true/, '')
data.failures[1] = requirement.message
fs.writeFileSync(file, JSON.stringify(data, null, 2))
NODE
expect_failure "bad release PR status report missing approval diagnostics fixture" "release-pr-readiness-report.json.requirements[1].approvalCount required when eligibleReviewerApprovalRequired is true"

write_fixture
node - "$report_dir/release-pr-readiness-report.json" <<'NODE'
const fs = require('fs')
const file = process.argv[2]
const data = JSON.parse(fs.readFileSync(file, 'utf8'))
data.requirements[0].unresolvedReviewThreads = 99
fs.writeFileSync(file, JSON.stringify(data, null, 2))
NODE
expect_failure "bad release PR status report review-thread count diagnostic fixture" "release-pr-readiness-report.json.requirements[0].unresolvedReviewThreads must match message diagnostic"

write_fixture
node - "$report_dir/release-pr-readiness-report.json" <<'NODE'
const fs = require('fs')
const file = process.argv[2]
const data = JSON.parse(fs.readFileSync(file, 'utf8'))
const requirement = data.requirements[0]
requirement.currentUnresolvedReviewThreads = 1
requirement.message = requirement.message.replace('currentUnresolvedReviewThreads=0', 'currentUnresolvedReviewThreads=1')
data.failures[0] = requirement.message
fs.writeFileSync(file, JSON.stringify(data, null, 2))
NODE
expect_failure "bad release PR status report review-thread semantic fixture" "release-pr-readiness-report.json.requirements[0].currentUnresolvedReviewThreads plus outdatedUnresolvedReviewThreads must equal unresolvedReviewThreads"

write_fixture
node - "$report_dir/release-pr-readiness-report.json" <<'NODE'
const fs = require('fs')
const file = process.argv[2]
const data = JSON.parse(fs.readFileSync(file, 'utf8'))
const requirement = data.requirements[0]
requirement.message = requirement.message.replace(' reviewConversationResolutionRequired=true', '')
data.failures[0] = requirement.message
fs.writeFileSync(file, JSON.stringify(data, null, 2))
NODE
expect_failure "bad release PR status report review-thread resolution flag fixture" "release-pr-readiness-report.json.requirements[0].message must include reviewConversationResolutionRequired=true when unresolvedReviewThreads is positive"

write_fixture
node - "$report_dir/release-pr-readiness-report.json" <<'NODE'
const fs = require('fs')
const file = process.argv[2]
const data = JSON.parse(fs.readFileSync(file, 'utf8'))
const requirement = data.requirements[0]
requirement.message = requirement.message.replace(' outdatedReviewThreadsStillBlockMerge=true', '')
data.failures[0] = requirement.message
fs.writeFileSync(file, JSON.stringify(data, null, 2))
NODE
expect_failure "bad release PR status report outdated-thread flag fixture" "release-pr-readiness-report.json.requirements[0].message must include outdatedReviewThreadsStillBlockMerge=true when only outdated review threads remain"

write_fixture
node - "$report_dir/release-pr-readiness-report.json" <<'NODE'
const fs = require('fs')
const file = process.argv[2]
const data = JSON.parse(fs.readFileSync(file, 'utf8'))
const requirement = data.requirements[0]
delete requirement.currentUnresolvedReviewThreads
requirement.message = requirement.message.replace(' currentUnresolvedReviewThreads=0', '')
data.failures[0] = requirement.message
fs.writeFileSync(file, JSON.stringify(data, null, 2))
NODE
expect_failure "bad release PR status report missing review-thread diagnostics fixture" "release-pr-readiness-report.json.requirements[0].currentUnresolvedReviewThreads required when review-thread diagnostics are present"

write_fixture
node - "$report_dir/release-pr-readiness-report.json" <<'NODE'
const fs = require('fs')
const file = process.argv[2]
const data = JSON.parse(fs.readFileSync(file, 'utf8'))
const fallback = data.requirements.find((requirement) => requirement.reviewDetails === 'unavailable')
fallback.approvalCount = 0
fs.writeFileSync(file, JSON.stringify(data, null, 2))
NODE
expect_failure "release PR status report review-details stale approval count fixture" "release-pr-readiness-report.json.requirements[2].approvalCount must be omitted when reviewDetails is unavailable"

write_fixture
node - "$report_dir/release-pr-readiness.log" <<'NODE'
const fs = require('fs')
const file = process.argv[2]
const lines = fs.readFileSync(file, 'utf8').split('\n')
const index = lines.findIndex((line) => line.includes('approvalCount=1 currentHeadApprovalCount=1'))
if (index === -1) throw new Error('approval-count fixture line missing')
const tampered = lines[index].replace('approvalCount=1 currentHeadApprovalCount=1', 'approvalCount=2 currentHeadApprovalCount=1')
lines.splice(index, 0, tampered)
fs.writeFileSync(file, lines.join('\n'))
NODE
expect_failure "bad release PR approval handoff log approval-count fixture" "release-pr-readiness-report.json.logResults[1] must match a status report requirement message"

write_fixture
node - "$report_dir/release-pr-readiness.log" <<'NODE'
const fs = require('fs')
const file = process.argv[2]
const originalLines = fs.readFileSync(file, 'utf8').split('\n')
const target = 'unresolvedReviewThreads=0 currentUnresolvedReviewThreads=0 outdatedUnresolvedReviewThreads=0'
const replacement = 'unresolvedReviewThreads=1 currentUnresolvedReviewThreads=1 outdatedUnresolvedReviewThreads=0'
const approvalLines = originalLines.filter((line) => line.includes('reviewDecision=REVIEW_REQUIRED') && line.includes('eligibleReviewerApprovalRequired=true') && line.includes(target))
if (approvalLines.length === 0) throw new Error('approval handoff fixture line missing')
const mutatedLines = originalLines.map((line) => (
  line.includes('reviewDecision=REVIEW_REQUIRED') && line.includes('eligibleReviewerApprovalRequired=true') && line.includes(target)
    ? line.replace(target, replacement)
    : line
))
const snapshots = approvalLines.map((line) => `  - ${line.replace('[release-pr-readiness][warn] ', '')}`)
fs.writeFileSync(file, `${mutatedLines.join('\n')}\n${snapshots.join('\n')}\n`)
NODE
expect_failure "bad release PR approval handoff missing fixture" "release-pr-readiness-report.json.logResults[1] must match a status report requirement message"

write_fixture
rm "$report_dir/blockers.md"
expect_failure "missing blockers fixture" "blockers.md missing"

write_fixture
perl -0pi -e 's/Get every PR in config\/release-readiness-prs\.tsv approved/Skip release approvals/' "$report_dir/blockers.md"
expect_failure "blockers markdown mismatch fixture" "blockers.md does not match summary/actions blockers"

write_fixture
perl -0pi -e 's/(- Requires external action: `true`\n)/$1$1/' "$report_dir/blockers.md"
expect_failure "duplicate blockers external-action line fixture" "blockers.md does not match summary/actions blockers"

write_fixture
perl -0pi -e 's/(- Unblock category: `review-and-merge`\n)/$1$1/' "$report_dir/blockers.md"
expect_failure "duplicate blockers unblock-category line fixture" "blockers.md does not match summary/actions blockers"

write_fixture
perl -0pi -e 's/(- External prerequisite:[^\n]*\n)/$1$1/' "$report_dir/blockers.md"
expect_failure "duplicate blockers external-prerequisite line fixture" "blockers.md does not match summary/actions blockers"

write_fixture
perl -0pi -e 's/(- Recommended action:[^\n]*\n)/$1$1/' "$report_dir/blockers.md"
expect_failure "duplicate blockers recommended-action line fixture" "blockers.md does not match summary/actions blockers"

write_fixture
perl -0pi -e 's/(- Verification command:[^\n]*\n)/$1$1/' "$report_dir/blockers.md"
expect_failure "duplicate blockers verification-command line fixture" "blockers.md does not match summary/actions blockers"

write_fixture
node - "$report_dir/actions.json" <<'NODE'
const fs = require('fs')
const file = process.argv[2]
const data = JSON.parse(fs.readFileSync(file, 'utf8'))
data.unexpected = true
fs.writeFileSync(file, JSON.stringify(data, null, 2))
NODE
expect_failure "unsupported actions key fixture" "unsupported actions manifest key"

write_fixture
node - "$report_dir/actions.json" <<'NODE'
const fs = require('fs')
const file = process.argv[2]
const data = JSON.parse(fs.readFileSync(file, 'utf8'))
data.blockers[0].unexpected = true
fs.writeFileSync(file, JSON.stringify(data, null, 2))
NODE
expect_failure "unsupported blocker key fixture" "unsupported blocker action key"

write_fixture
node - "$report_dir/actions.json" <<'NODE'
const fs = require('fs')
const file = process.argv[2]
const data = JSON.parse(fs.readFileSync(file, 'utf8'))
data.blockers[0].name = 'Release\nPR readiness'
fs.writeFileSync(file, JSON.stringify(data, null, 2))
NODE
expect_failure "multi-line blocker name fixture" "blocker.name must be a single-line value"

write_fixture
node - "$report_dir/actions.json" <<'NODE'
const fs = require('fs')
const file = process.argv[2]
const data = JSON.parse(fs.readFileSync(file, 'utf8'))
data.blockers[0].name = 'Release PR readiness api_key'
fs.writeFileSync(file, JSON.stringify(data, null, 2))
NODE
expect_failure "secret-like blocker name fixture" "blocker.name contains secret-like token"

write_fixture
node - "$report_dir/actions.json" <<'NODE'
const fs = require('fs')
const file = process.argv[2]
const data = JSON.parse(fs.readFileSync(file, 'utf8'))
data.blockers[0].name = 'Release PR approval readiness'
fs.writeFileSync(file, JSON.stringify(data, null, 2))
NODE
expect_failure "wrong blocker name contract fixture" "release-pr-readiness.name must match expected check name"

write_fixture
node - "$report_dir/actions.json" <<'NODE'
const fs = require('fs')
const file = process.argv[2]
const data = JSON.parse(fs.readFileSync(file, 'utf8'))
data.blockers[0].requiresExternalAction = false
fs.writeFileSync(file, JSON.stringify(data, null, 2))
NODE
expect_failure "wrong blocker external-action contract fixture" "release-pr-readiness.requiresExternalAction must match expected unblock metadata"

write_fixture
node - "$report_dir/actions.json" <<'NODE'
const fs = require('fs')
const file = process.argv[2]
const data = JSON.parse(fs.readFileSync(file, 'utf8'))
data.blockers[0].unblockCategory = 'local-code'
fs.writeFileSync(file, JSON.stringify(data, null, 2))
NODE
expect_failure "wrong blocker category contract fixture" "release-pr-readiness.unblockCategory must match expected unblock metadata"

write_fixture
node - "$report_dir/actions.json" <<'NODE'
const fs = require('fs')
const file = process.argv[2]
const data = JSON.parse(fs.readFileSync(file, 'utf8'))
data.blockers[0].externalPrerequisite = 'Local release checklist cleanup.'
fs.writeFileSync(file, JSON.stringify(data, null, 2))
NODE
expect_failure "wrong blocker external-prerequisite contract fixture" "release-pr-readiness.externalPrerequisite must match expected unblock metadata"

write_fixture
node - "$report_dir/actions.json" <<'NODE'
const fs = require('fs')
const file = process.argv[2]
const data = JSON.parse(fs.readFileSync(file, 'utf8'))
data.blockers[0].recommendedAction = 'Approve and merge the release PRs.'
fs.writeFileSync(file, JSON.stringify(data, null, 2))
NODE
expect_failure "wrong blocker recommended-action contract fixture" "release-pr-readiness.recommendedAction must match expected recommended action"

write_fixture
node - "$report_dir/actions.json" <<'NODE'
const fs = require('fs')
const file = process.argv[2]
const data = JSON.parse(fs.readFileSync(file, 'utf8'))
data.blockers[0].exitCode = 0
fs.writeFileSync(file, JSON.stringify(data, null, 2))
NODE
expect_failure "zero failed blocker exit-code fixture" "release-pr-readiness.exitCode must be positive for failed blocker"

write_fixture
node - "$report_dir/actions.json" <<'NODE'
const fs = require('fs')
const file = process.argv[2]
const data = JSON.parse(fs.readFileSync(file, 'utf8'))
data.blockers[0].evidencePreview = 'All release PRs are approved and merged.'
fs.writeFileSync(file, JSON.stringify(data, null, 2))
NODE
expect_failure "unbacked blocker evidence-preview fixture" "release-pr-readiness.evidencePreview line is not present in source log"

write_fixture
node - "$report_dir/actions.json" <<'NODE'
const fs = require('fs')
const file = process.argv[2]
const data = JSON.parse(fs.readFileSync(file, 'utf8'))
data.blockers[0].evidencePreview = 'api_key'
fs.writeFileSync(file, JSON.stringify(data, null, 2))
NODE
expect_failure "secret-like blocker evidence-preview fixture" "release-pr-readiness.evidencePreview contains secret-like token"

write_fixture
node - "$report_dir/actions.json" <<'NODE'
const fs = require('fs')
const file = process.argv[2]
const data = JSON.parse(fs.readFileSync(file, 'utf8'))
data.blockers[0].evidencePreview = 'not release-ready'
fs.writeFileSync(file, JSON.stringify(data, null, 2))
NODE
expect_failure "substring blocker evidence-preview fixture" "release-pr-readiness.evidencePreview line must match a complete source log line"

write_fixture
node - "$report_dir/actions.json" <<'NODE'
const fs = require('fs')
const file = process.argv[2]
const data = JSON.parse(fs.readFileSync(file, 'utf8'))
data.blockers[1].slug = data.blockers[0].slug
fs.writeFileSync(file, JSON.stringify(data, null, 2))
NODE
expect_failure "duplicate blocker slug fixture" "duplicate blocker slug"

write_fixture
duplicate_artifact_exporter="$tmp_dir/export-release-unblock-bundle-duplicate-artifact.sh"
cp "$EXPORT_SCRIPT" "$duplicate_artifact_exporter"
perl -0pi -e 's/if \(passkeyProductionContractHandoffCache\) return deepClone\(passkeyProductionContractHandoffCache\)/if (false \&\& passkeyProductionContractHandoffCache) return deepClone(passkeyProductionContractHandoffCache)/' "$duplicate_artifact_exporter"
perl -0pi -e "s/new Set\\(\\['passkey-backup-prerequisites', 'passkey-production-smoke'\\]\\)/new Set(['passkey-deployment-evidence', 'passkey-production-smoke'])/" "$duplicate_artifact_exporter"
expect_failure_with_export_script "duplicate bundle artifact path fixture" "$duplicate_artifact_exporter" "duplicate bundle artifact path: handoffs/passkey-backup-production.json"

write_fixture
unsafe_artifact_exporter="$tmp_dir/export-release-unblock-bundle-unsafe-artifact.sh"
cp "$EXPORT_SCRIPT" "$unsafe_artifact_exporter"
perl -0pi -e "s/copyArtifact\\(summaryPath, 'summary\\.json', artifacts\\)/copyArtifact(summaryPath, '..\\/summary.json', artifacts)/" "$unsafe_artifact_exporter"
expect_failure_with_export_script "unsafe bundle artifact path fixture" "$unsafe_artifact_exporter" "bundle artifact path points outside output bundle: ../summary.json"

write_fixture
nested_checksum_exporter="$tmp_dir/export-release-unblock-bundle-nested-checksum.sh"
cp "$EXPORT_SCRIPT" "$nested_checksum_exporter"
perl -0pi -e "s/const checksumLines = listFiles\\(outputRoot\\)/fs.writeFileSync(path.join(outputRoot, 'logs\\/SHA256SUMS'), 'nested checksum fixture\\\\n')\\nconst checksumLines = listFiles(outputRoot)/" "$nested_checksum_exporter"
expect_success_with_export_script "nested checksum basename fixture" "$nested_checksum_exporter"
grep -q 'logs/SHA256SUMS' "$bundle_dir/SHA256SUMS" ||
  fail "nested checksum basename fixture was omitted from SHA256SUMS"

write_fixture
node - "$report_dir/actions.json" <<'NODE'
const fs = require('fs')
const file = process.argv[2]
const data = JSON.parse(fs.readFileSync(file, 'utf8'))
data.blockers[0].recommendedAction = 'Approve and merge\nthe release PRs.'
fs.writeFileSync(file, JSON.stringify(data, null, 2))
NODE
expect_failure "multi-line recommended action fixture" "release-pr-readiness.recommendedAction must be a single-line value"

write_fixture
node - "$report_dir/actions.json" <<'NODE'
const fs = require('fs')
const file = process.argv[2]
const data = JSON.parse(fs.readFileSync(file, 'utf8'))
delete data.blockers[0].verificationCommand
fs.writeFileSync(file, JSON.stringify(data, null, 2))
NODE
expect_failure "missing verification command fixture" "verificationCommand must be a non-empty string"

write_fixture
node - "$report_dir/actions.json" <<'NODE'
const fs = require('fs')
const file = process.argv[2]
const data = JSON.parse(fs.readFileSync(file, 'utf8'))
data.blockers[0].verificationCommand = 'bash scripts/audit-release-pr-readiness.sh\necho unsafe'
fs.writeFileSync(file, JSON.stringify(data, null, 2))
NODE
expect_failure "multi-line verification command fixture" "verificationCommand must be a single-line value"

write_fixture
node - "$report_dir/actions.json" <<'NODE'
const fs = require('fs')
const file = process.argv[2]
const data = JSON.parse(fs.readFileSync(file, 'utf8'))
data.blockers[0].verificationCommand = 'bash scripts/audit-release-pr-readiness.sh; echo unsafe'
fs.writeFileSync(file, JSON.stringify(data, null, 2))
NODE
expect_failure "unsafe verification command fixture" "verificationCommand must match expected command"

write_fixture
node - "$report_dir/actions.json" <<'NODE'
const fs = require('fs')
const file = process.argv[2]
const data = JSON.parse(fs.readFileSync(file, 'utf8'))
data.blockers[0].requiresExternalAction = 'true'
fs.writeFileSync(file, JSON.stringify(data, null, 2))
NODE
expect_failure "non-boolean external action fixture" "requiresExternalAction must be boolean"

write_fixture
node - "$report_dir/actions.json" <<'NODE'
const fs = require('fs')
const file = process.argv[2]
const data = JSON.parse(fs.readFileSync(file, 'utf8'))
delete data.blockers[0].unblockCategory
fs.writeFileSync(file, JSON.stringify(data, null, 2))
NODE
expect_failure "missing unblock category fixture" "unblockCategory must be a non-empty string"

write_fixture
node - "$report_dir/actions.json" <<'NODE'
const fs = require('fs')
const file = process.argv[2]
const data = JSON.parse(fs.readFileSync(file, 'utf8'))
data.blockers[0].unblockCategory = 'unknown-category'
fs.writeFileSync(file, JSON.stringify(data, null, 2))
NODE
expect_failure "unsupported unblock category fixture" "unblockCategory unsupported"

write_fixture
node - "$report_dir/actions.json" <<'NODE'
const fs = require('fs')
const file = process.argv[2]
const data = JSON.parse(fs.readFileSync(file, 'utf8'))
data.blockers[0].externalPrerequisite = 'Reviewer approval\nand hidden drift'
fs.writeFileSync(file, JSON.stringify(data, null, 2))
NODE
expect_failure "multi-line external prerequisite fixture" "externalPrerequisite must be a single-line value"

write_fixture
rm "$report_dir/si-production-smoke.log"
expect_failure "missing source log fixture" "si-production-smoke.logFile missing"

write_fixture
node - "$report_dir/actions.json" <<'NODE'
const fs = require('fs')
const file = process.argv[2]
const data = JSON.parse(fs.readFileSync(file, 'utf8'))
data.blockers[0].logFile = './release-pr-readiness.log'
fs.writeFileSync(file, JSON.stringify(data, null, 2))
NODE
expect_failure "non-normalized action log path fixture" "release-pr-readiness.logFile must be absolute normalized or relative normalized path"

write_fixture
node - "$report_dir/summary.json" <<'NODE'
const fs = require('fs')
const file = process.argv[2]
const data = JSON.parse(fs.readFileSync(file, 'utf8'))
data.checks.find((check) => check.slug === 'release-pr-readiness').logFile = './release-pr-readiness.log'
fs.writeFileSync(file, JSON.stringify(data, null, 2))
NODE
expect_failure "non-normalized summary log path fixture" "release-pr-readiness.summary.logFile must be absolute normalized or relative normalized path"

write_fixture
printf '%s\n' "outside log" > "$outside_log"
node - "$report_dir/actions.json" "$outside_log" <<'NODE'
const fs = require('fs')
const file = process.argv[2]
const outside = process.argv[3]
const data = JSON.parse(fs.readFileSync(file, 'utf8'))
data.blockers[0].logFile = outside
fs.writeFileSync(file, JSON.stringify(data, null, 2))
NODE
expect_failure "outside source log fixture" "points outside release-readiness report dir"

write_fixture
node - "$report_dir/actions.json" <<'NODE'
const fs = require('fs')
const file = process.argv[2]
const data = JSON.parse(fs.readFileSync(file, 'utf8'))
data.totals.failed = 1
data.totals.total = 10
fs.writeFileSync(file, JSON.stringify(data, null, 2))
NODE
expect_failure "blocker count mismatch fixture" "summary/actions totals mismatch for failed"

write_fixture
node - "$report_dir/summary.json" <<'NODE'
const fs = require('fs')
const file = process.argv[2]
const data = JSON.parse(fs.readFileSync(file, 'utf8'))
data.generatedAt = '2026-06-28T00:00:00.000Z'
fs.writeFileSync(file, JSON.stringify(data, null, 2))
NODE
expect_failure "invalid source generatedAt fixture" "summary.generatedAt must be an ISO-8601 UTC seconds timestamp"

write_fixture
node - "$report_dir/actions.json" <<'NODE'
const fs = require('fs')
const file = process.argv[2]
const data = JSON.parse(fs.readFileSync(file, 'utf8'))
data.generatedAt = '2026-06-28T00:00:01Z'
fs.writeFileSync(file, JSON.stringify(data, null, 2))
NODE
expect_failure "summary actions generatedAt mismatch fixture" "summary/actions generatedAt mismatch"

write_fixture
node - "$report_dir/summary.json" "$report_dir/actions.json" <<'NODE'
const fs = require('fs')
for (const file of process.argv.slice(2)) {
  const data = JSON.parse(fs.readFileSync(file, 'utf8'))
  data.generatedAt = '2999-01-01T00:00:00Z'
  fs.writeFileSync(file, JSON.stringify(data, null, 2))
}
NODE
expect_failure "future source generatedAt fixture" "summary.generatedAt is in the future"

write_fixture
node - "$report_dir/summary.json" "$report_dir/actions.json" <<'NODE'
const fs = require('fs')
for (const file of process.argv.slice(2)) {
  const data = JSON.parse(fs.readFileSync(file, 'utf8'))
  data.status = 'degraded'
  fs.writeFileSync(file, JSON.stringify(data, null, 2))
}
NODE
expect_failure "unsupported source status fixture" "release status unsupported: degraded"

write_fixture
node - "$report_dir/summary.json" "$report_dir/actions.json" <<'NODE'
const fs = require('fs')
for (const file of process.argv.slice(2)) {
  const data = JSON.parse(fs.readFileSync(file, 'utf8'))
  data.status = 'passed'
  fs.writeFileSync(file, JSON.stringify(data, null, 2))
}
NODE
expect_failure "source status failed-total mismatch fixture" "release status must be failed when failed total is greater than zero"

write_fixture
node - "$report_dir/actions.json" <<'NODE'
const fs = require('fs')
const file = process.argv[2]
const data = JSON.parse(fs.readFileSync(file, 'utf8'))
data.runLive = false
fs.writeFileSync(file, JSON.stringify(data, null, 2))
NODE
expect_failure "runLive mismatch fixture" "summary/actions runLive mismatch"

write_fixture
node - "$report_dir/summary.json" <<'NODE'
const fs = require('fs')
const file = process.argv[2]
const data = JSON.parse(fs.readFileSync(file, 'utf8'))
const check = data.checks.find((item) => item.slug === 'release-pr-readiness')
check.status = 'passed'
check.exitCode = 0
check.recommendedAction = null
check.requiresExternalAction = null
check.unblockCategory = null
check.externalPrerequisite = null
check.verificationCommand = null
fs.writeFileSync(file, JSON.stringify(data, null, 2))
NODE
expect_failure "summary checks status mismatch fixture" "summary checks passed count must match summary.totals.passed"

write_fixture
node - "$report_dir/summary.json" <<'NODE'
const fs = require('fs')
const file = process.argv[2]
const data = JSON.parse(fs.readFileSync(file, 'utf8'))
data.checks.find((check) => check.slug === 'release-pr-readiness').name = 'Release\nPR readiness'
fs.writeFileSync(file, JSON.stringify(data, null, 2))
NODE
expect_failure "summary multi-line name fixture" "summary.check.name must be a single-line value"

write_fixture
node - "$report_dir/summary.json" <<'NODE'
const fs = require('fs')
const file = process.argv[2]
const data = JSON.parse(fs.readFileSync(file, 'utf8'))
data.checks.find((check) => check.slug === 'release-pr-readiness').name = 'Release PR readiness api_key'
fs.writeFileSync(file, JSON.stringify(data, null, 2))
NODE
expect_failure "summary secret-like name fixture" "summary.check.name contains secret-like token"

write_fixture
node - "$report_dir/summary.json" <<'NODE'
const fs = require('fs')
const file = process.argv[2]
const data = JSON.parse(fs.readFileSync(file, 'utf8'))
data.checks.find((check) => check.slug === 'plan-readiness').name = 'Static plan readiness drift'
fs.writeFileSync(file, JSON.stringify(data, null, 2))
NODE
expect_failure "wrong summary check name contract fixture" "plan-readiness.summary.name must match expected check name"

write_fixture
node - "$report_dir/summary.json" <<'NODE'
const fs = require('fs')
const file = process.argv[2]
const data = JSON.parse(fs.readFileSync(file, 'utf8'))
data.checks.find((check) => check.slug === 'release-pr-readiness').slug = 'release-pr-readiness-copy'
fs.writeFileSync(file, JSON.stringify(data, null, 2))
NODE
expect_failure "summary failed action mismatch fixture" "release-pr-readiness-copy failed summary check missing from actions manifest blockers"

write_fixture
node - "$report_dir/summary.json" "$report_dir/actions.json" <<'NODE'
const fs = require('fs')
const [summaryFile, actionsFile] = process.argv.slice(2)
const summary = JSON.parse(fs.readFileSync(summaryFile, 'utf8'))
const actions = JSON.parse(fs.readFileSync(actionsFile, 'utf8'))
summary.checks = summary.checks.filter((check) => check.slug !== 'passkey-backup-prerequisites')
summary.totals.passed -= 1
summary.totals.total -= 1
actions.totals.passed -= 1
actions.totals.total -= 1
fs.writeFileSync(summaryFile, JSON.stringify(summary, null, 2))
fs.writeFileSync(actionsFile, JSON.stringify(actions, null, 2))
NODE
expect_failure "summary missing release check fixture" "summary missing release check: passkey-backup-prerequisites"

write_fixture
node - "$report_dir/summary.json" <<'NODE'
const fs = require('fs')
const file = process.argv[2]
const data = JSON.parse(fs.readFileSync(file, 'utf8'))
const first = data.checks[0]
data.checks[0] = data.checks[1]
data.checks[1] = first
fs.writeFileSync(file, JSON.stringify(data, null, 2))
NODE
expect_failure "summary non-failed check order fixture" "summary non-failed checks must match release check order"

write_fixture
node - "$report_dir/actions.json" <<'NODE'
const fs = require('fs')
const file = process.argv[2]
const data = JSON.parse(fs.readFileSync(file, 'utf8'))
const first = data.blockers[0]
data.blockers[0] = data.blockers[1]
data.blockers[1] = first
fs.writeFileSync(file, JSON.stringify(data, null, 2))
NODE
expect_failure "actions blocker order fixture" "actions manifest blockers must match failed summary check order"

write_fixture
node - "$report_dir/summary.json" <<'NODE'
const fs = require('fs')
const file = process.argv[2]
const data = JSON.parse(fs.readFileSync(file, 'utf8'))
data.checks.find((check) => check.slug === 'release-pr-readiness').recommendedAction = 'Approve and merge\nthe release PRs.'
fs.writeFileSync(file, JSON.stringify(data, null, 2))
NODE
expect_failure "summary multi-line recommended action fixture" "release-pr-readiness.summary.recommendedAction must be a single-line value"

write_fixture
node - "$report_dir/summary.json" <<'NODE'
const fs = require('fs')
const file = process.argv[2]
const data = JSON.parse(fs.readFileSync(file, 'utf8'))
data.checks.find((check) => check.slug === 'release-pr-readiness').exitCode = 0
fs.writeFileSync(file, JSON.stringify(data, null, 2))
NODE
expect_failure "summary failed zero exit-code fixture" "release-pr-readiness.summary.exitCode must be positive for failed check"

write_fixture
node - "$report_dir/summary.json" <<'NODE'
const fs = require('fs')
const file = process.argv[2]
const data = JSON.parse(fs.readFileSync(file, 'utf8'))
data.checks.find((check) => check.slug === 'plan-readiness').exitCode = 1
fs.writeFileSync(file, JSON.stringify(data, null, 2))
NODE
expect_failure "summary passed nonzero exit-code fixture" "plan-readiness.summary.exitCode must be 0 for passed check"

write_fixture
node - "$report_dir/summary.json" <<'NODE'
const fs = require('fs')
const file = process.argv[2]
const data = JSON.parse(fs.readFileSync(file, 'utf8'))
data.checks.find((check) => check.slug === 'release-pr-readiness').recommendedAction = 'different summary action'
fs.writeFileSync(file, JSON.stringify(data, null, 2))
NODE
expect_failure "summary recommended action mismatch fixture" "release-pr-readiness.summary recommendedAction must match actions manifest blocker"

write_fixture
node - "$report_dir/summary.json" <<'NODE'
const fs = require('fs')
const file = process.argv[2]
const data = JSON.parse(fs.readFileSync(file, 'utf8'))
data.checks.find((check) => check.slug === 'plan-readiness').recommendedAction = 'unexpected action'
fs.writeFileSync(file, JSON.stringify(data, null, 2))
NODE
expect_failure "summary non-failed unblock metadata fixture" "plan-readiness.summary non-failed check must not carry unblock metadata"

write_fixture
printf '%s\n' \
  "health serviceId must be si.soramitsu.io; received <missing>" \
  "private_key=do-not-export" \
  > "$report_dir/si-production-smoke.log"
expect_failure "secret-like log fixture" "contains secret-like token"

echo "[release-unblock-bundle-test] all tests passed"
