#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
EXPORT_SCRIPT="$SCRIPT_DIR/export-release-unblock-bundle.sh"
VERIFY_SCRIPT="$SCRIPT_DIR/verify-release-unblock-bundle.sh"

fail() {
  echo "[release-unblock-bundle-verify-test][error] $*" >&2
  exit 1
}

tmp_dir="$(mktemp -d)"
tmp_dir="$(cd "$tmp_dir" && pwd -P)"
repo_scratch_dir="$SCRIPT_DIR/../build/release-unblock-bundle-verify-test-$$"
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

mark_canonical_review_blocked_fixture() {
  node - "$report_dir/summary.json" "$report_dir/actions.json" "$report_dir/source-publication-readiness.log" <<'NODE'
const fs = require('fs')
const [summaryFile, actionsFile, logFile] = process.argv.slice(2)
const summary = JSON.parse(fs.readFileSync(summaryFile, 'utf8'))
const actions = JSON.parse(fs.readFileSync(actionsFile, 'utf8'))
  const sourceCheck = summary.checks.find((item) => item.slug === 'source-publication-readiness')
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
for (const manifest of [summary, actions]) { manifest.totals.passed -= 1; manifest.totals.failed += 1 }
fs.writeFileSync(summaryFile, `${JSON.stringify(summary, null, 2)}\n`)
fs.writeFileSync(actionsFile, `${JSON.stringify(actions, null, 2)}\n`)
fs.writeFileSync(logFile, `${sourceEvidence}\n  - ../iroha: canonical branch exact-SHA review is blocked: optimizations requires a verifiable reviewed/protected policy\n`)
NODE
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

write_fixture() {
  rm -rf "$report_dir" "$bundle_dir" "$workspace_dir"
  mkdir -p "$report_dir" "$workspace_dir/config" "$workspace_dir/scripts" "$workspace_dir/services/passkey-backup-challenge-service" \
    "$workspace_dir/fearless-Android-production-consolidated-20260731/runtime/src/main/assets" "$workspace_dir/fearless-Android-production-consolidated-20260731/scripts"
  printf '%s\n' \
    '# approved XCM routes' \
    'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb DOT' \
    'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa KSM' \
    > "$workspace_dir/fearless-Android-production-consolidated-20260731/runtime/src/main/assets/approved_xcm_routes.tsv"
  printf '%s\n' \
    '# required XCM routes' \
    'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb DOT' \
    'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa KSM' \
    > "$workspace_dir/fearless-Android-production-consolidated-20260731/scripts/xcm-required-routes.tsv"
  printf '%s\n' '{"chains":[]}' > "$workspace_dir/fearless-Android-production-consolidated-20260731/runtime/src/main/assets/local_chains.json"
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
      "logFile": "$report_dir/release-pr-readiness.log"
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
      "logFile": "$report_dir/release-pr-readiness.log",
      "recommendedAction": "Get every PR in config/release-readiness-prs.tsv approved, green, with all GitHub review conversations resolved including outdated unresolved threads, and merged through the protected branch flow. When the blocker is outdated-only, run bash scripts/resolve-release-pr-review-threads.sh --dry-run to inspect the exact thread IDs before any authorized resolution. After conversations are resolved and approvals are present, run bash scripts/merge-release-prs.sh --dry-run to inspect protected-branch merge candidates before any authorized merge, then rerun bash scripts/audit-release-pr-readiness.sh.",
      "requiresExternalAction": true,
      "unblockCategory": "review-and-merge",
      "externalPrerequisite": "Reviewer approvals, resolved GitHub review conversations, and protected-branch merges.",
      "verificationCommand": "bash scripts/audit-release-pr-readiness.sh",
      "evidencePreview": "wallet PRs still require review"
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
      "recommendedAction": "Keep release ENABLE_PRODUCTION_XCM_TRANSFERS=false until the entire trust and evidence gate is ready. Obtain reviewed per-asset pallet/call, reserve-or-teleport, multilocation, beneficiary, weight, destination-fee, and any bridge execution semantics for every advertised Android XCM route; implement bridge or estimator support before approving those modes. The per-asset schema, loader, validator, registry, and engine representation is now implemented, and all 15 approved single-asset routes are migrated without semantic changes. The current 34 discovery-only destinations cover 59 route assets; 14 of those destinations cover 39 multi-asset routes, and every one remains disabled until its exact reviewed semantics exist. Expand the APK-owned approved_xcm_routes.tsv and scripts/xcm-required-routes.tsv in exact lockstep only after those route semantics are reviewed, and make the production discovery intersection contain every approved route. Then record one funded mainnet E2E transfer per required route in fearless-Android-production-consolidated-20260731/scripts/xcm-production-evidence.json, including 0x-prefixed 32-byte extrinsicHash, sender, recipient, positive amount, UTC timestamp, environment, operator, and androidCommit matching the release commit, plus finalized origin/destination block hashes and numbers, true origin finality/extrinsic success/destination event success, a positive destination balance delta, distinct public HTTPS proof URLs, verificationMethod=canonical-rpc-and-explorer, verifiedAt, and an independentVerifier distinct from operator. Regenerate the canonical live effective report and validate it with the ready evidence, then run the all-routes metadata gate before a separately reviewed release-flag change.",
      "requiresExternalAction": true,
      "unblockCategory": "route-implementation-and-evidence",
      "externalPrerequisite": "Reviewed per-asset execution semantics and effective production discovery for every advertised Android XCM route, implementation of any required bridge or fee-estimator path, a separately reviewed release enablement change, funded mainnet E2E evidence for the exact effective route set, and Android release-commit binding.",
      "verificationCommand": "cd fearless-Android-production-consolidated-20260731 && bash scripts/audit-xcm-effective-registry.sh --discovery-url https://raw.githubusercontent.com/soramitsu/shared-features-utils/master/chains/v13/chains.json --require-all-approved --write-report build/reports/xcm-effective-registry-report.json && bash scripts/audit-xcm-production-evidence.sh --effective-registry-report build/reports/xcm-effective-registry-report.json --require-ready && bash scripts/audit-xcm-registry-metadata.sh --require-executable --require-all-routes-executable --require-route-file scripts/xcm-required-routes.tsv --require-gap-file scripts/xcm-discovery-only-routes.tsv",
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

  cat > "$report_dir/blockers.md" <<MD
# Release Readiness Blockers

- Generated at: 2026-06-28T00:00:00Z
- Run live checks: true
- Totals: 9 passed, 12 failed, 0 skipped, 21 total

## Failed Checks

### Release PR readiness

- Slug: \`release-pr-readiness\`
- Exit code: \`1\`
- Log: \`$report_dir/release-pr-readiness.log\`
- Recommended action: Get every PR in config/release-readiness-prs.tsv approved, green, with all GitHub review conversations resolved including outdated unresolved threads, and merged through the protected branch flow. When the blocker is outdated-only, run bash scripts/resolve-release-pr-review-threads.sh --dry-run to inspect the exact thread IDs before any authorized resolution. After conversations are resolved and approvals are present, run bash scripts/merge-release-prs.sh --dry-run to inspect protected-branch merge candidates before any authorized merge, then rerun bash scripts/audit-release-pr-readiness.sh.
- Requires external action: \`true\`
- Unblock category: \`review-and-merge\`
- External prerequisite: Reviewer approvals, resolved GitHub review conversations, and protected-branch merges.
- Verification command: \`bash scripts/audit-release-pr-readiness.sh\`

Evidence preview:

\`\`\`text
wallet PRs still require review
\`\`\`

### Web Bitcoin broadcast evidence

- Slug: \`web-bitcoin-broadcast-evidence\`
- Exit code: \`1\`
- Log: \`web-bitcoin-broadcast-evidence.log\`
- Recommended action: Run a funded Bitcoin testnet send through the web wallet smoke flow, record txid/outpoint/operator evidence plus canonical https://blockstream.info/testnet/api indexerUrl and confirmed indexer status.block_time proof in fearless-wallet-web/scripts/bitcoin-testnet-broadcast-evidence.json, ensure the evidence timestamp is at or after the confirmed block time, then rerun bash scripts/audit-bitcoin-broadcast-evidence.sh --require-ready in fearless-wallet-web.
- Requires external action: \`true\`
- Unblock category: \`funded-broadcast-evidence\`
- External prerequisite: Funded confirmed Bitcoin testnet broadcast evidence for the current release commit using the canonical Blockstream testnet indexer.
- Verification command: \`cd fearless-wallet-web && bash scripts/audit-bitcoin-broadcast-evidence.sh --require-ready\`

Evidence preview:

\`\`\`text
ready Bitcoin broadcast evidence requires at least one record
\`\`\`

### Passkey deployment evidence

- Slug: \`passkey-deployment-evidence\`
- Exit code: \`1\`
- Log: \`passkey-deployment-evidence.log\`
- Recommended action: Record the passkey backup image digest, deployment ID, operator, healthResponse ok=true/service=fearless-passkey-backup/rpId=fearlesswallet.io/schemaVersion=1, durable credential store paths /data/passkey-backup and /data/passkey-backup/credentials.json, WebAuthn origin allowlist, fail-closed request-access policy, trusted-proxy policy, platform provisioning evidence, and successful smoke timestamp. Independently obtain the distribution signer SHA-256 fingerprint from a distribution-signed APK or the Play app-signing certificate, set PASSKEY_ANDROID_RELEASE_SIGNER_EVIDENCE_SOURCE=distributed-apk|play-app-signing-certificate to identify the source, and prove the derived origin matches assetlinks; AAB upload-key evidence is rejected and absence or mismatch keeps passkey flags disabled. Then rerun npm run audit:deployment-evidence -- --require-ready in services/passkey-backup-challenge-service and bash scripts/audit-passkey-android-origin-parity.sh --require-ready from the workspace root.
- Requires external action: \`true\`
- Unblock category: \`deployment-evidence\`
- External prerequisite: Production passkey backup deployment image, health response, credential-store volume, request-access and trusted-proxy evidence, plus independently obtained distribution signer SHA-256 evidence from a distribution-signed APK or Play app-signing certificate, with PASSKEY_ANDROID_RELEASE_SIGNER_EVIDENCE_SOURCE=distributed-apk|play-app-signing-certificate and a matching assetlinks origin; AAB upload-key evidence is rejected and absence keeps passkey flags disabled.
- Verification command: \`cd services/passkey-backup-challenge-service && npm run audit:deployment-evidence -- --require-ready && cd ../.. && bash scripts/audit-passkey-android-origin-parity.sh --require-ready\`

Evidence preview:

\`\`\`text
passkey production deployment evidence is not release-ready
\`\`\`

### Passkey production smoke

- Slug: \`passkey-production-smoke\`
- Exit code: \`1\`
- Log: \`passkey-production-smoke.log\`
- Recommended action: Deploy and route https://backup.fearlesswallet.io to services/passkey-backup-challenge-service with valid DNS/TLS. Provision PASSKEY_BACKUP_SMOKE_GRANT_HELPER=/run/secrets/passkey-smoke-grant-helper as a readable executable that issues single-use bearer grants for the exact smoke requests, then run the passkey production smoke to verify health, all four ceremony routes, and credential list/revoke/revoke-all contracts without persisting a test credential or creating an owner record.
- Requires external action: \`true\`
- Unblock category: \`live-service-deployment\`
- External prerequisite: DNS, TLS, and routing for backup.fearlesswallet.io to the passkey backup challenge service route surface, plus PASSKEY_BACKUP_SMOKE_GRANT_HELPER=/run/secrets/passkey-smoke-grant-helper provisioned as a readable executable that issues single-use bearer grants for the exact smoke requests.
- Verification command: \`cd services/passkey-backup-challenge-service && PASSKEY_BACKUP_BASE_URL=https://backup.fearlesswallet.io PASSKEY_BACKUP_SMOKE_GRANT_HELPER=/run/secrets/passkey-smoke-grant-helper PASSKEY_BACKUP_SMOKE_TIMEOUT_MS=10000 npm run smoke:production\`

Evidence preview:

\`\`\`text
GET /api/passkey-backup/v1/health request to https://backup.fearlesswallet.io failed
\`\`\`

### Iroha Taira/Nexus release prerequisites

- Slug: \`iroha-release-readiness\`
- Exit code: \`1\`
- Log: \`iroha-release-readiness.log\`
- Recommended action: Do not edit or publish from an unfinished external Iroha Git operation. Have its owner produce a stable reviewed source commit and restore the pinned Iroha JS SDK release artifact so package.json exports ./ivm-artifact and the packaged runtime/declaration surface passes the wallet artifact validator. Pin NEXUS_EXPECTED_BUILD_COMMIT in config/iroha-release-readiness.env to the exact deployed Iroha build. Restore https://minamoto.sora.org/status as a bounded, non-redirecting HTTP 200 application/json Torii/Nexus status response with fresh observed_at_ms and last_block_committed_at_ms, coherent block and queue counters, a matching non-placeholder build.git_commit_sha, the exact ordered SORA routing policy (default 0/0, governance 1/1, smartcontract::deploy 2/2), and an unsealed dataspace_catalog containing ready canonical 0/0, 1/1, and 2/2 targets; record Nexus route publication, canary, and wallet live transfer smoke evidence, keep Nexus release-gated until strict production evidence passes, then rerun bash scripts/audit-iroha-release-readiness.sh.
- Requires external action: \`true\`
- Unblock category: \`live-service-and-evidence\`
- External prerequisite: A stable owner-reviewed Iroha source commit; a pinned Iroha JS SDK release artifact exporting ./ivm-artifact and passing packaged runtime/declaration validation; the exact deployed Iroha build pin; bounded, non-redirecting HTTP 200 application/json Minamoto Torii/Nexus status with fresh observation and block timestamps, coherent block and queue counters, exact canonical routing/dataspace catalog; plus route publication, canary, and wallet live-transfer evidence.
- Verification command: \`IROHA_NEXUS_REQUIRE_PRODUCTION_EVIDENCE=1 IROHA_NEXUS_LIVE_HEALTH=1 bash scripts/audit-iroha-release-readiness.sh\`

Evidence preview:

\`\`\`text
SORA Nexus Torii live health check failed for https://minamoto.sora.org/status
\`\`\`

### Android XCM production evidence

- Slug: \`android-xcm-production-evidence\`
- Exit code: \`1\`
- Log: \`android-xcm-production-evidence.log\`
- Recommended action: Keep release ENABLE_PRODUCTION_XCM_TRANSFERS=false until the entire trust and evidence gate is ready. Obtain reviewed per-asset pallet/call, reserve-or-teleport, multilocation, beneficiary, weight, destination-fee, and any bridge execution semantics for every advertised Android XCM route; implement bridge or estimator support before approving those modes. The per-asset schema, loader, validator, registry, and engine representation is now implemented, and all 15 approved single-asset routes are migrated without semantic changes. The current 34 discovery-only destinations cover 59 route assets; 14 of those destinations cover 39 multi-asset routes, and every one remains disabled until its exact reviewed semantics exist. Expand the APK-owned approved_xcm_routes.tsv and scripts/xcm-required-routes.tsv in exact lockstep only after those route semantics are reviewed, and make the production discovery intersection contain every approved route. Then record one funded mainnet E2E transfer per required route in fearless-Android-production-consolidated-20260731/scripts/xcm-production-evidence.json, including 0x-prefixed 32-byte extrinsicHash, sender, recipient, positive amount, UTC timestamp, environment, operator, and androidCommit matching the release commit, plus finalized origin/destination block hashes and numbers, true origin finality/extrinsic success/destination event success, a positive destination balance delta, distinct public HTTPS proof URLs, verificationMethod=canonical-rpc-and-explorer, verifiedAt, and an independentVerifier distinct from operator. Regenerate the canonical live effective report and validate it with the ready evidence, then run the all-routes metadata gate before a separately reviewed release-flag change.
- Requires external action: \`true\`
- Unblock category: \`route-implementation-and-evidence\`
- External prerequisite: Reviewed per-asset execution semantics and effective production discovery for every advertised Android XCM route, implementation of any required bridge or fee-estimator path, a separately reviewed release enablement change, funded mainnet E2E evidence for the exact effective route set, and Android release-commit binding.
- Verification command: \`cd fearless-Android-production-consolidated-20260731 && bash scripts/audit-xcm-effective-registry.sh --discovery-url https://raw.githubusercontent.com/soramitsu/shared-features-utils/master/chains/v13/chains.json --require-all-approved --write-report build/reports/xcm-effective-registry-report.json && bash scripts/audit-xcm-production-evidence.sh --effective-registry-report build/reports/xcm-effective-registry-report.json --require-ready && bash scripts/audit-xcm-registry-metadata.sh --require-executable --require-all-routes-executable --require-route-file scripts/xcm-required-routes.tsv --require-gap-file scripts/xcm-discovery-only-routes.tsv\`

Evidence preview:

\`\`\`text
ready evidence cannot have discovery-only routes remaining
\`\`\`

### TI deployment evidence

- Slug: \`ti-deployment-evidence\`
- Exit code: \`1\`
- Log: \`ti-deployment-evidence.log\`
- Recommended action: Populate ../ton-indexer/registry/mainnet.json with reviewed non-placeholder mainnet contract addresses. Record the TI Docker image digest, deployment ID, operator, commit, serviceInfo.schemaVersion=1 plus serviceInfo.serviceId=ti.soramitsu.io with TON mainnet identity, healthInfo.serviceId=ti.soramitsu.io with healthInfo.lastMasterSeqno from the successful https://ti.soramitsu.io smoke evidence, then rerun npm run audit:deployment-evidence -- --require-ready in ../ton-indexer.
- Requires external action: \`true\`
- Unblock category: \`deployment-evidence\`
- External prerequisite: Reviewed TON mainnet registry addresses plus deployed TI image, smoke, and health evidence.
- Verification command: \`cd ../ton-indexer && npm run audit:deployment-evidence -- --require-ready\`

Evidence preview:

\`\`\`text
TI deployment evidence log
\`\`\`

### SI deployment evidence

- Slug: \`si-deployment-evidence\`
- Exit code: \`1\`
- Log: \`si-deployment-evidence.log\`
- Recommended action: Deploy the current SI image with Solana mainnet configuration. Record the SI Docker image digest, deployment ID, operator, commit, serviceInfo.schemaVersion=1 plus serviceInfo.serviceId=si.soramitsu.io with Solana mainnet identity, and healthInfo with ok=true, serviceId=si.soramitsu.io, genesisHash=5eykt4UsFv8P8NJdTREpY1vzqKqZKvdpKuc147dw2N9d, latestSlot as a positive safe integer, and syncedAt as an integer no more than 120 seconds before and no more than 30 seconds after smokePassedAt, plus successful https://si.soramitsu.io smoke evidence in ../solswap-indexer/scripts/production-deployment-evidence.json, then rerun npm run audit:deployment-evidence -- --require-ready in ../solswap-indexer.
- Requires external action: \`true\`
- Unblock category: \`deployment-evidence\`
- External prerequisite: Current SI image deployed with exact Solana mainnet genesisHash, positive latestSlot, fresh integer syncedAt, service-info identity, and operator-attested deployment evidence.
- Verification command: \`cd ../solswap-indexer && npm run audit:deployment-evidence -- --require-ready\`

Evidence preview:

\`\`\`text
SI deployment evidence log
\`\`\`

### TI production smoke

- Slug: \`ti-production-smoke\`
- Exit code: \`1\`
- Log: \`ti-production-smoke.log\`
- Recommended action: Deploy the current ton-indexer image to https://ti.soramitsu.io so /api/indexer/v1/health exposes lastMasterSeqno and health.serviceId=ti.soramitsu.io with ecosystem=ton, chainId=ton:mainnet, and network=mainnet. TI production smoke also requires serviceInfo.schemaVersion=1, serviceInfo.serviceId=ti.soramitsu.io, publicBaseUrl=https://ti.soramitsu.io, readOnly=true, endpoints.openapi=/api/indexer/v1/openapi.json, and OpenAPI title TONSWAP Indexer API, then rerun TON_INDEXER_BASE_URL=https://ti.soramitsu.io npm run smoke:production in ../ton-indexer.
- Requires external action: \`true\`
- Unblock category: \`live-service-deployment\`
- External prerequisite: Updated TON indexer deployment serving TI mainnet health, service-info, and OpenAPI contracts.
- Verification command: \`cd ../ton-indexer && TON_INDEXER_BASE_URL=https://ti.soramitsu.io npm run smoke:production\`

Evidence preview:

\`\`\`text
health serviceId must be ti.soramitsu.io
\`\`\`

### SI production smoke

- Slug: \`si-production-smoke\`
- Exit code: \`1\`
- Log: \`si-production-smoke.log\`
- Recommended action: Deploy the current SI image with Solana mainnet configuration so /api/indexer/v1/health returns health.ok=true, health.serviceId=si.soramitsu.io, health.ecosystem=solana, health.chainId=solana:mainnet, health.network=mainnet, health.genesisHash=5eykt4UsFv8P8NJdTREpY1vzqKqZKvdpKuc147dw2N9d, health.latestSlot as a positive safe integer, and health.syncedAt as an integer no more than 120 seconds old and no more than 30 seconds in the future, without advertising api.testnet.solana.com, and /api/indexer/v1/service-info exists. SI production smoke also requires serviceInfo.schemaVersion=1, serviceInfo.serviceId=si.soramitsu.io, ecosystem=solana, chainId=solana:mainnet, network=mainnet, publicBaseUrl=https://si.soramitsu.io, readOnly=true, endpoints.openapi=/api/indexer/v1/openapi.json, and OpenAPI title Solswap Indexer API, then rerun SOLSWAP_INDEXER_BASE_URL=https://si.soramitsu.io npm run smoke:production in ../solswap-indexer.
- Requires external action: \`true\`
- Unblock category: \`live-service-deployment\`
- External prerequisite: Current SI image deployed with exact Solana mainnet genesisHash, positive latestSlot, fresh integer syncedAt, release identity fields, service-info, and OpenAPI contracts.
- Verification command: \`cd ../solswap-indexer && SOLSWAP_INDEXER_BASE_URL=https://si.soramitsu.io npm run smoke:production\`

Evidence preview:

\`\`\`text
health serviceId must be si.soramitsu.io; received <missing>
\`\`\`

### PI deployment evidence

- Slug: \`pi-deployment-evidence\`
- Exit code: \`1\`
- Log: \`pi-deployment-evidence.log\`
- Recommended action: Deploy the current polkaswap-indexer worker and API to https://pi.soramitsu.io/graphql with POLKASWAP_CHAIN_START_BLOCK set, a locally-controlled verifying archival primary RPC and an independently-operated verifying archive RPC on distinct hosts. Require the exact fixed audited SORA mainnet genesis/hash/timestamp anchor identity preflight on both RPCs before database access; exact dual-RPC agreement on finalized height, hash, canonical raw SCALE block, canonical raw SCALE events, and raw decimal timestamp milliseconds; and the compiled PostgreSQL worker health check proving the exact persisted chainState, matching filtered BLOCK snapshot, checkpoint freshness from 300 seconds behind through 30 seconds ahead, and secret-safe diagnostics. API health evidence must prove healthInfo.service=polkaswap-indexer, healthInfo.serviceId=pi.soramitsu.io, exact SORA mainnet genesisHash=0x7e4e32d0feafd4f9c9414b0be86373f9a1efa904809b683453a9af6856d38ad5, latestIndexedBlock as a positive safe integer, latestIndexedBlockHash as a canonical nonzero lowercase 32-byte hash, and latestIndexedAt no more than 300 seconds before or 30 seconds after the smoke timestamp. Record the Docker image digest, deployment ID, operator, commit, those exact healthInfo fields, successful smoke timestamp, soraRpcControls with primaryEndpoint, archiveEndpoint, primaryNodeControl=locally-controlled-verifying-archive, archiveNodeControl=independently-operated-verifying-archive, distinctHosts=true, exactIdentityPreflight=true, and rawPayloadAgreement=height-hash-scale-block-events-timestamp, plus tlsEdgeControls proving TLS termination, forwarded-client-IP header overwrite, 600 HTTP requests and 600 WebSocket upgrades per client per 60000ms, and 16 concurrent WebSockets per client in ../polkaswap-indexer/scripts/production-deployment-evidence.json, then, from ../polkaswap-indexer, rerun bash ../fearless/scripts/run-pinned-yarn.sh audit:deployment-evidence --require-ready.
- Requires external action: \`true\`
- Unblock category: \`deployment-evidence\`
- External prerequisite: Current PI worker/API deployed with required POLKASWAP_CHAIN_START_BLOCK, a locally-controlled verifying archival primary RPC and independently-operated verifying archive RPC on distinct hosts, exact fixed-anchor identity preflight, exact dual raw payload agreement, compiled PostgreSQL worker health proving exact persisted state/snapshot freshness with secret-safe diagnostics, and operator-attested image, deployment, commit, four-field health, SORA RPC-control, smoke, and TLS-edge evidence.
- Verification command: \`cd ../polkaswap-indexer && bash ../fearless/scripts/run-pinned-yarn.sh audit:deployment-evidence --require-ready\`

Evidence preview:

\`\`\`text
Production deployment evidence is not release-ready
\`\`\`

### PI production smoke

- Slug: \`pi-production-smoke\`
- Exit code: \`1\`
- Log: \`pi-production-smoke.log\`
- Recommended action: Deploy the current polkaswap-indexer worker and API to https://pi.soramitsu.io/graphql with POLKASWAP_CHAIN_START_BLOCK set, a locally-controlled verifying archival primary RPC and an independently-operated verifying archive RPC on distinct hosts. Require the exact fixed audited SORA mainnet genesis/hash/timestamp anchor identity preflight on both RPCs before database access; exact dual-RPC agreement on finalized height, hash, canonical raw SCALE block, canonical raw SCALE events, and raw decimal timestamp milliseconds; and the compiled PostgreSQL worker health check proving the exact persisted chainState, matching filtered BLOCK snapshot, checkpoint freshness from 300 seconds behind through 30 seconds ahead, and secret-safe diagnostics. GraphQL _health must return health.ok=true, health.service=polkaswap-indexer, health.serviceId=pi.soramitsu.io, health.schemaVersion=1, health.ecosystem=sora2, health.chainId=sora:mainnet, health.network=mainnet, health.publicBaseUrl=https://pi.soramitsu.io/graphql, health.readOnly=true, exact SORA mainnet genesisHash=0x7e4e32d0feafd4f9c9414b0be86373f9a1efa904809b683453a9af6856d38ad5, a positive latestIndexedBlock, a canonical nonzero lowercase 32-byte latestIndexedBlockHash, and a latestIndexedAt within 300 seconds behind or 30 seconds ahead of the verifier. PI production smoke also requires an immutable exact fixed-anchor chainIdentity, a chainState record at or below finalized height and coherent with the health height/hash/timestamp, live hash and raw timestamp reconciliation, and a matching filtered BLOCK snapshot, and rejects TON and Solana/Solswap indexer contracts. Then, from ../polkaswap-indexer, rerun POLKASWAP_INDEXER_BASE_URL=https://pi.soramitsu.io/graphql bash ../fearless/scripts/run-pinned-yarn.sh smoke:production.
- Requires external action: \`true\`
- Unblock category: \`live-service-deployment\`
- External prerequisite: Updated PI worker/API serving the four SORA identity/checkpoint fields through GraphQL _health and coherent immutable chainIdentity, chainState, and filtered BLOCK worker state, backed by distinct controlled verifying archival RPCs, exact identity preflight and raw payload agreement, required chain start, and the compiled secret-safe worker health check.
- Verification command: \`cd ../polkaswap-indexer && POLKASWAP_INDEXER_BASE_URL=https://pi.soramitsu.io/graphql bash ../fearless/scripts/run-pinned-yarn.sh smoke:production\`

Evidence preview:

\`\`\`text
PI production GraphQL schema is missing _health identity fields
\`\`\`

MD

  printf '%s\n' \
    "wallet PRs still require review" \
    "[release-pr-readiness][warn] wallet PRs still require review" \
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
  # Real Android generator export/verify regression: every bundle fixture
  # consumes the production template schema instead of a synthetic copy.
  bash "$SCRIPT_DIR/../fearless-Android-production-consolidated-20260731/scripts/generate-xcm-production-evidence-template.sh" \
    --required-route-file "$workspace_dir/fearless-Android-production-consolidated-20260731/scripts/xcm-required-routes.tsv" \
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
  const content = fs.readFileSync(path.join(workspace, 'fearless-Android-production-consolidated-20260731', source))
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
fearless-site-web-app-associations-20260726	soramitsu/fearless-site-web	fix/app-association-publication	develop	49
../ton-indexer	tonswap-org/ton-indexer	codex/ti-smoke-body-preview-tests	develop	13
../solswap-indexer	solswap-io/solswap-indexer	codex/si-smoke-body-preview-tests	develop	16
../polkaswap-indexer	sora-xor/polkaswap-indexer	codex/pi-deployment-evidence-gate	develop	1
../iroha	hyperledger-iroha/iroha	optimizations	optimizations	-
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
  ['fearless-site-web-app-associations-20260726', 'soramitsu/fearless-site-web', 'fix/app-association-publication', 'develop', 49],
  ['../ton-indexer', 'tonswap-org/ton-indexer', 'codex/ti-smoke-body-preview-tests', 'develop', 13],
  ['../solswap-indexer', 'solswap-io/solswap-indexer', 'codex/si-smoke-body-preview-tests', 'develop', 16],
  ['../polkaswap-indexer', 'sora-xor/polkaswap-indexer', 'codex/pi-deployment-evidence-gate', 'develop', 1],
  ['../iroha', 'hyperledger-iroha/iroha', 'optimizations', 'optimizations', null],
]
function source(sourcePath, repository, head, base, prNumber) {
  return {
    path: sourcePath, repository, head, base, prNumber,
    prUrl: prNumber === null ? null : `https://github.com/${repository}/pull/${prNumber}`, prState: prNumber === null ? null : 'merged', prHeadSha: prNumber === null ? null : sha,
    repositoryPath: path.resolve(workspace, sourcePath), status: prNumber === null ? 'failed' : 'passed',
    originUrl: `https://github.com/${repository}.git`, originRepository: repository, branch: head,
    headSha: sha, upstream: `origin/${head}`, upstreamSha: sha, remoteHeadSha: sha,
    remoteBranchPresent: true, currentBranchRemoteSha: sha, currentBranchRemotePresent: true,
    stagedCount: 0, unstagedCount: 0, untrackedCount: 0, unmergedCount: 0,
    dirtyPaths: [], requiredTrackedFiles: [], failures: prNumber === null ? ['canonical branch exact-SHA review is blocked: optimizations requires a verifiable reviewed/protected policy'] : [],
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
  'docs/passkey-enabled-acceptance.md',
  'docs/release-shipping-manifest.md',
  'docs/source-freeze-20260801.md',
  'scripts/audit-passkey-enabled-acceptance.mjs',
  'scripts/audit-release-shipping-manifest.mjs',
  'scripts/test-release-shipping-manifest.mjs',
  'scripts/test-passkey-enabled-acceptance.mjs',
  'scripts/audit-plan-readiness.sh',
  'scripts/test-plan-readiness-audit.sh',
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
  'services/passkey-backup-owner-authority/README.md',
  'services/passkey-backup-owner-authority/docs/bootstrap-proof.md',
  'services/passkey-backup-owner-authority/docs/legacy-cutover.md',
  'services/passkey-backup-owner-authority/package.json',
  'services/passkey-backup-owner-authority/package-lock.json',
  'services/passkey-backup-owner-authority/scripts/reconcile-legacy-credentials.mjs',
  'services/passkey-backup-owner-authority/scripts/quarantine-legacy-credentials.mjs',
  'services/passkey-backup-owner-authority/scripts/verify-sealed-legacy-cutover.mjs',
  'services/passkey-backup-owner-authority/src/apple-app-attest-admission.js',
  'services/passkey-backup-owner-authority/src/apple-app-attest-receipt.js',
  'services/passkey-backup-owner-authority/src/apple-app-attestation-root-ca.pem',
  'services/passkey-backup-owner-authority/src/apple-root-ca-g3.cer',
  'services/passkey-backup-owner-authority/src/authority.js',
  'services/passkey-backup-owner-authority/src/bootstrap-proof.js',
  'services/passkey-backup-owner-authority/src/http.js',
  'services/passkey-backup-owner-authority/src/legacy-cutover-verifier.js',
  'services/passkey-backup-owner-authority/src/legacy-quarantine.js',
  'services/passkey-backup-owner-authority/src/legacy-reconciliation.js',
  'services/passkey-backup-owner-authority/src/play-integrity-admission.js',
  'services/passkey-backup-owner-authority/src/store.js',
  'services/passkey-backup-owner-authority/src/validation.js',
  'services/passkey-backup-owner-authority/src/verifier-contract.d.ts',
  'services/passkey-backup-owner-authority/src/webauthn-verifier.js',
  'services/passkey-backup-owner-authority/test/apple-app-attest-admission.test.js',
  'services/passkey-backup-owner-authority/test/apple-app-attest-receipt.test.js',
  'services/passkey-backup-owner-authority/test/apple-app-attest-sample.json',
  'services/passkey-backup-owner-authority/test/authority.test.js',
  'services/passkey-backup-owner-authority/test/challenge-credential-mutation.test.js',
  'services/passkey-backup-owner-authority/test/generation-head.test.js',
  'services/passkey-backup-owner-authority/test/http.test.js',
  'services/passkey-backup-owner-authority/test/legacy-cutover-challenge.test.js',
  'services/passkey-backup-owner-authority/test/legacy-cutover-webauthn.test.js',
  'services/passkey-backup-owner-authority/test/legacy-cutover-verifier.test.js',
  'services/passkey-backup-owner-authority/test/legacy-quarantine.test.js',
  'services/passkey-backup-owner-authority/test/legacy-reconciliation.test.js',
  'services/passkey-backup-owner-authority/test/legacy-schema-migration.test.js',
  'services/passkey-backup-owner-authority/test/fixtures.js',
  'services/passkey-backup-owner-authority/test/play-integrity-admission.test.js',
  'services/passkey-backup-owner-authority/test/process-worker.js',
  'services/passkey-backup-owner-authority/test/webauthn-verifier.test.js',
]
const report = {
  schemaVersion: 3, phase: 'preflight', preflightReportSha256: null,
  generatedAt: '2026-06-28T00:00:00.000Z', status: 'failed', checkRemote: true,
  workspaceRoot: workspace, workspaceParent: path.dirname(workspace),
  configFile: path.join(workspace, 'config/source-publication-readiness.tsv'),
  rootOwnerConfigFile: path.join(workspace, 'config/source-publication-root-owner.json'),
  releasePrConfigFile: path.join(workspace, 'config/release-readiness-prs.tsv'),
  totals: {sources: 9, passed: 8, failed: 1, staged: 0, unstaged: 0, untracked: 0, unmerged: 0},
  workspaceSource,
  repositories: configured.map((row) => source(...row)),
}
const preflightBytes = Buffer.from(`${JSON.stringify(report, null, 2)}\n`)
fs.writeFileSync(preflightOutput, preflightBytes)
report.phase = 'postflight'
report.repositories[7].failures.push('source publication preflight did not pass before release checks')
report.preflightReportSha256 = crypto.createHash('sha256').update(preflightBytes).digest('hex')
fs.writeFileSync(output, `${JSON.stringify(report, null, 2)}\n`)
NODE
  mark_canonical_review_blocked_fixture
  rewrite_blocker_markdown_from_manifests
}

write_external_plan_fixture() {
  local source_variant="${1:-operation}"
  write_fixture
  local action="Do not edit or publish from the unsafe external ../iroha checkout. Have its owner resolve any in-progress Git operation or unmerged index state and restore every reported Iroha source and browser-artifact contract on a stable reviewed commit, then rerun bash scripts/audit-plan-readiness.sh."
  local prerequisite="Owner-coordinated resolution of the unsafe external ../iroha source state, followed by a stable reviewed checkout containing every audited Iroha source and browser-artifact contract."
  local evidence="  - ../iroha browser-artifact contract missing"
  local log_file="$report_dir/plan-readiness.log"

  printf '%s\n' \
    "[plan-readiness][error] Plan readiness audit failed:" \
    "  - ../iroha source contract missing" \
    "$evidence" \
    > "$log_file"
  node - "$report_dir/summary.json" "$report_dir/actions.json" "$log_file" "$report_dir/source-publication-preflight-report.json" "$report_dir/source-publication-readiness-report.json" "$report_dir/source-publication-readiness.log" "$action" "$prerequisite" "$evidence" "$source_variant" <<'NODE'
const crypto = require('crypto')
const fs = require('fs')
const [summaryFile, actionsFile, logFile, preflightReportFile, sourceReportFile, sourceLogFile, action, prerequisite, evidence, sourceVariant] = process.argv.slice(2)
const summary = JSON.parse(fs.readFileSync(summaryFile, 'utf8'))
const actions = JSON.parse(fs.readFileSync(actionsFile, 'utf8'))
const check = summary.checks.find((item) => item.slug === 'plan-readiness')
Object.assign(check, {
  status: 'failed',
  exitCode: 1,
  logFile,
  recommendedAction: action,
  requiresExternalAction: true,
  unblockCategory: 'upstream-dependency',
  externalPrerequisite: prerequisite,
  verificationCommand: 'bash scripts/audit-plan-readiness.sh',
})
summary.totals.passed -= 1
summary.totals.failed += 1
actions.totals.passed -= 1
actions.totals.failed += 1
actions.blockers.unshift({
  name: 'Static cross-repo plan readiness',
  slug: 'plan-readiness',
  exitCode: 1,
  logFile,
  recommendedAction: action,
  requiresExternalAction: true,
  unblockCategory: 'upstream-dependency',
  externalPrerequisite: prerequisite,
  verificationCommand: 'bash scripts/audit-plan-readiness.sh',
  evidencePreview: evidence,
})
const operationFailure = 'repository has an in-progress Git merge operation (MERGE_HEAD); only the repository owner may complete or abort it before source publication'
const sourceReport = JSON.parse(fs.readFileSync(sourceReportFile, 'utf8'))
const iroha = sourceReport.repositories.find((row) => row.path === '../iroha')
if (!iroha) throw new Error('Iroha source-publication fixture missing')
iroha.status = 'failed'
if (sourceVariant === 'reviewed-source') {
  const liveHeadSha = 'e56af586b6d047c361e531d330424fb3067f57b2'
  // Canonical branch has no pull-request identity.
  iroha.branch = 'optimizations'
  iroha.upstream = 'origin/optimizations'
  iroha.headSha = liveHeadSha
  iroha.upstreamSha = liveHeadSha
  iroha.prHeadSha = null
  iroha.remoteBranchPresent = true
  iroha.remoteHeadSha = liveHeadSha
  iroha.currentBranchRemotePresent = true
  iroha.currentBranchRemoteSha = liveHeadSha
  iroha.dirtyPaths = ['.cache/', '.codex-target/', '.playwright-cli/', '.pytest_cache/', 'Cargo.lock', 'IrohaSwift/.build/', 'artifacts/js-sdk-bundle-size/', 'artifacts/python_fixture_regen_state.json']
  iroha.failures = [
    'worktree contains ignored non-published paths (154): .cache/, .codex-target/, .playwright-cli/, .pytest_cache/, Cargo.lock, IrohaSwift/.build/, artifacts/js-sdk-bundle-size/, artifacts/python_fixture_regen_state.json; remove or quarantine these ignored outputs outside the source tree before publication; do not force-add generated artifacts',
    'canonical branch exact-SHA review is blocked: optimizations requires a verifiable reviewed/protected policy',
  ]
} else if (sourceVariant === 'operation') {
  iroha.stagedCount = 1
  iroha.dirtyPaths = ['crates/iroha_torii/src/offline_v2_issuer.rs']
  iroha.failures = [operationFailure, 'source publication preflight did not pass before release checks']
} else {
  throw new Error(`unsupported external plan source variant: ${sourceVariant}`)
}
sourceReport.status = 'failed'
if (sourceVariant === 'operation') sourceReport.totals.staged += 1
if (sourceVariant === 'reviewed-source') {
  const preflightReport = JSON.parse(fs.readFileSync(preflightReportFile, 'utf8'))
  const preflightIndex = preflightReport.repositories.findIndex((row) => row.path === '../iroha')
  if (preflightIndex < 0) throw new Error('Iroha preflight source-publication fixture missing')
  preflightReport.repositories[preflightIndex] = JSON.parse(JSON.stringify(iroha))
  preflightReport.status = 'failed'
      fs.writeFileSync(preflightReportFile, `${JSON.stringify(preflightReport, null, 2)}\n`)
  const preflightBytes = fs.readFileSync(preflightReportFile)
  sourceReport.preflightReportSha256 = crypto.createHash('sha256').update(preflightBytes).digest('hex')
  iroha.failures.push('source publication preflight did not pass before release checks')
}
const sourceEvidence = '[source-publication-readiness][error] Source publication readiness failed:'
fs.writeFileSync(sourceReportFile, `${JSON.stringify(sourceReport, null, 2)}\n`)
fs.writeFileSync(
  sourceLogFile,
  `${sourceEvidence}\n${iroha.failures.map((failure) => `  - ../iroha: ${failure}`).join('\n')}\n`,
)
fs.writeFileSync(summaryFile, `${JSON.stringify(summary, null, 2)}\n`)
fs.writeFileSync(actionsFile, `${JSON.stringify(actions, null, 2)}\n`)
NODE

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
  lines.push(`### ${blocker.name}`, '')
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

export_bundle() {
  RELEASE_UNBLOCK_ROOT="$workspace_dir" bash "$EXPORT_SCRIPT" --report-dir "$report_dir" --output "$bundle_dir" >/dev/null
}

reset_bundle() {
  write_fixture
  export_bundle
}

reset_external_plan_bundle() {
  write_external_plan_fixture "${1:-operation}"
  export_bundle
}

reset_non_live_bundle() {
  write_fixture
  node - "$report_dir/summary.json" "$report_dir/actions.json" "$report_dir/android-xcm-effective-registry-report.json" <<'NODE'
const fs = require('fs')
for (const file of process.argv.slice(2, 4)) {
  const data = JSON.parse(fs.readFileSync(file, 'utf8'))
  data.runLive = false
  fs.writeFileSync(file, JSON.stringify(data, null, 2) + '\n')
}
const reportFile = process.argv[4]
const report = JSON.parse(fs.readFileSync(reportFile, 'utf8'))
report.mode = 'bundled'
report.status = 'complete'
report.inputs.discoveryRegistry = null
report.routes[1].effective = true
report.routes[1].reasons = []
report.missing = []
report.extra = []
Object.assign(report.summary, { discovered: 2, effective: 2, productionExecutable: 0, missing: 0, extra: 0 })
fs.writeFileSync(reportFile, JSON.stringify(report, null, 2) + '\n')
NODE
  perl -0pi -e 's/Run live checks: true/Run live checks: false/' "$report_dir/blockers.md"
  export_bundle
}

run_verify() {
  RELEASE_UNBLOCK_ROOT="$workspace_dir" bash "$VERIFY_SCRIPT" --bundle "$bundle_dir" "$@"
}

run_verify_to() {
  local target_bundle="$1"
  shift
  RELEASE_UNBLOCK_ROOT="$workspace_dir" bash "$VERIFY_SCRIPT" --bundle "$target_bundle" "$@"
}

run_verify_with_workspace_root() {
  local target_workspace="$1"
  shift
  RELEASE_UNBLOCK_ROOT="$target_workspace" bash "$VERIFY_SCRIPT" --bundle "$bundle_dir" "$@"
}

expect_success() {
  local name="$1"
  local output
  if ! output="$(run_verify 2>&1)"; then
    echo "$output" >&2
    fail "$name unexpectedly failed"
  fi
}

expect_failure() {
  local name="$1"
  local expected="$2"
  local output
  set +e
  output="$(run_verify 2>&1)"
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

expect_failure_with_workspace_root() {
  local name="$1"
  local target_workspace="$2"
  local expected="$3"
  local output
  set +e
  output="$(run_verify_with_workspace_root "$target_workspace" 2>&1)"
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

expect_failure_to() {
  local name="$1"
  local target_bundle="$2"
  local expected="$3"
  local output
  set +e
  output="$(run_verify_to "$target_bundle" 2>&1)"
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

expect_failure_at_time() {
  local name="$1"
  local now="$2"
  local expected="$3"
  shift 3
  local output
  set +e
  output="$(RELEASE_UNBLOCK_ROOT="$workspace_dir" RELEASE_UNBLOCK_VERIFY_NOW="$now" bash "$VERIFY_SCRIPT" --bundle "$bundle_dir" "$@" 2>&1)"
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

rewrite_checksums() {
  node - "$bundle_dir" <<'NODE'
const crypto = require('crypto')
const fs = require('fs')
const path = require('path')
const root = process.argv[2]
function listFiles(dir) {
  return fs.readdirSync(dir, { withFileTypes: true }).flatMap((entry) => {
    const absolute = path.join(dir, entry.name)
    if (entry.isDirectory()) return listFiles(absolute)
    return [absolute]
  })
}
function sha(file) {
  return crypto.createHash('sha256').update(fs.readFileSync(file)).digest('hex')
}
const lines = listFiles(root)
  .filter((file) => path.basename(file) !== 'SHA256SUMS')
  .map((file) => `${sha(file)}  ${path.relative(root, file).split(path.sep).join('/')}`)
  .sort()
fs.writeFileSync(path.join(root, 'SHA256SUMS'), lines.join('\n') + '\n')
NODE
}

edit_json() {
  local relative="$1"
  local script="$2"
  node - "$bundle_dir/$relative" "$script" <<'NODE'
const fs = require('fs')
const file = process.argv[2]
const script = process.argv[3]
const data = JSON.parse(fs.readFileSync(file, 'utf8'))
Function('data', script)(data)
fs.writeFileSync(file, JSON.stringify(data, null, 2) + '\n')
NODE
}

refresh_manifest_artifact() {
  local relative="$1"
  node - "$bundle_dir" "$relative" <<'NODE'
const crypto = require('crypto')
const fs = require('fs')
const path = require('path')
const root = process.argv[2]
const relative = process.argv[3]
const manifestFile = path.join(root, 'manifest.json')
const artifactFile = path.join(root, relative)
const manifest = JSON.parse(fs.readFileSync(manifestFile, 'utf8'))
const artifact = manifest.artifacts.find((item) => item.path === relative)
if (!artifact) throw new Error(`manifest artifact not found: ${relative}`)
const content = fs.readFileSync(artifactFile)
artifact.sha256 = crypto.createHash('sha256').update(content).digest('hex')
artifact.bytes = content.length
fs.writeFileSync(manifestFile, JSON.stringify(manifest, null, 2) + '\n')
NODE
}

refresh_source_publication_report_handoff() {
  refresh_manifest_artifact "handoffs/source-publication-readiness-report.json"
  edit_json "manifest.json" "data.sourcePublicationHandoff.reportSha256 = data.artifacts.find((artifact) => artifact.path === 'handoffs/source-publication-readiness-report.json').sha256"
  rewrite_checksums
}

refresh_source_publication_preflight_report_handoff() {
  refresh_manifest_artifact "handoffs/source-publication-preflight-report.json"
  edit_json "manifest.json" "data.sourcePublicationHandoff.preflightReportSha256 = data.artifacts.find((artifact) => artifact.path === 'handoffs/source-publication-preflight-report.json').sha256"
  rewrite_checksums
}

rebind_bundled_source_publication_postflight() {
  node - "$bundle_dir/handoffs/source-publication-preflight-report.json" "$bundle_dir/handoffs/source-publication-readiness-report.json" <<'NODE'
const crypto = require('crypto')
const fs = require('fs')
const [preflightFile, postflightFile] = process.argv.slice(2)
const preflightBytes = fs.readFileSync(preflightFile)
const postflight = JSON.parse(fs.readFileSync(postflightFile, 'utf8'))
postflight.preflightReportSha256 = crypto.createHash('sha256').update(preflightBytes).digest('hex')
fs.writeFileSync(postflightFile, `${JSON.stringify(postflight, null, 2)}\n`)
NODE
  refresh_manifest_artifact "handoffs/source-publication-preflight-report.json"
  refresh_manifest_artifact "handoffs/source-publication-readiness-report.json"
  edit_json "manifest.json" "data.sourcePublicationHandoff.preflightReportSha256 = data.artifacts.find((artifact) => artifact.path === 'handoffs/source-publication-preflight-report.json').sha256; data.sourcePublicationHandoff.reportSha256 = data.artifacts.find((artifact) => artifact.path === 'handoffs/source-publication-readiness-report.json').sha256"
  rewrite_checksums
}

set_reviewed_source_authoritative_current_drift_bundle() {
  edit_json "handoffs/source-publication-readiness-report.json" "const iroha = data.repositories.find((row) => row.path === '../iroha'); const hasContinuity = iroha.failures.includes('source publication preflight did not pass before release checks'); iroha.currentBranchRemotePresent = true; iroha.currentBranchRemoteSha = '095afec25e64fdcf1d619c23a7e3b0a3906e7e8c'
iroha.remoteHeadSha = iroha.currentBranchRemoteSha; for (const key of ['stagedCount', 'unstagedCount', 'untrackedCount', 'unmergedCount']) iroha[key] = 0; iroha.failures = [iroha.failures[0], 'local HEAD ' + iroha.headSha + ' does not match authoritative remote head ' + iroha.remoteHeadSha, 'cached upstream ' + iroha.upstream + ' at ' + iroha.upstreamSha + ' does not match authoritative current branch ' + iroha.branch + ' at ' + iroha.currentBranchRemoteSha, 'canonical branch exact-SHA review is blocked: optimizations requires a verifiable reviewed/protected policy', ...(hasContinuity ? ['source publication preflight did not pass before release checks'] : [])]"
  edit_json "manifest.json" "const iroha = data.sourcePublicationHandoff.repositories.find((row) => row.path === '../iroha'); iroha.currentBranchRemotePresent = true; iroha.currentBranchRemoteSha = '095afec25e64fdcf1d619c23a7e3b0a3906e7e8c'
iroha.remoteHeadSha = iroha.currentBranchRemoteSha; for (const key of ['stagedCount', 'unstagedCount', 'untrackedCount', 'unmergedCount']) iroha[key] = 0"
  refresh_source_publication_report_handoff
}

refresh_plan_log_artifact() {
  refresh_manifest_artifact "logs/plan-readiness.log"
  edit_json "manifest.json" "const blocker = data.blockers.find((candidate) => candidate.slug === 'plan-readiness'); blocker.logSha256 = data.artifacts.find((artifact) => artifact.path === blocker.logArtifact).sha256"
  rewrite_checksums
}

refresh_xcm_effective_artifact_handoff() {
  refresh_manifest_artifact "handoffs/android-xcm-effective-registry-report.json"
  edit_json "manifest.json" "const blocker = data.blockers.find((candidate) => candidate.slug === 'android-xcm-production-evidence'); blocker.xcmRegistryHandoff.effectiveRegistry.reportSha256 = data.artifacts.find((artifact) => artifact.path === blocker.xcmRegistryHandoff.effectiveRegistry.reportArtifact).sha256"
}

refresh_xcm_registry_gap_artifact_handoff() {
  refresh_manifest_artifact "handoffs/android-xcm-registry-gap-report.json"
  edit_json "manifest.json" "const blocker = data.blockers.find((candidate) => candidate.slug === 'android-xcm-production-evidence'); blocker.xcmRegistryHandoff.gapReportSha256 = data.artifacts.find((artifact) => artifact.path === blocker.xcmRegistryHandoff.gapReportArtifact).sha256"
}

refresh_xcm_production_template_artifact_handoff() {
  refresh_manifest_artifact "handoffs/android-xcm-production-evidence-template.json"
  edit_json "manifest.json" "const blocker = data.blockers.find((candidate) => candidate.slug === 'android-xcm-production-evidence'); blocker.xcmProductionEvidenceTemplateHandoff.templateSha256 = data.artifacts.find((artifact) => artifact.path === blocker.xcmProductionEvidenceTemplateHandoff.templateArtifact).sha256"
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

const oldBlock = 'Evidence preview:\n\n```text\nwallet PRs still require review\n```\n'
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

const oldBlock = 'Evidence preview:\n\n```text\nwallet PRs still require review\n```\n'
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

rewrite_bundle_evidence_to_unsafe_fixed_fence() {
  local relative="$1"
  node - "$bundle_dir/$relative" <<'NODE'
const fs = require('fs')
const file = process.argv[2]
const safeBlock = 'Evidence preview:\n\n````text\n```\n````\n'
const unsafeBlock = 'Evidence preview:\n\n```text\n```\n```\n'
const markdown = fs.readFileSync(file, 'utf8')
if (!markdown.includes(safeBlock)) throw new Error('safe release PR evidence fence not found')
fs.writeFileSync(file, markdown.replace(safeBlock, unsafeBlock))
NODE
}

reset_bundle
SOURCE_PUBLICATION_SNAPSHOT_PATHS="$bundle_dir/handoffs/source-publication-readiness-report.json|$bundle_dir/handoffs/source-publication-preflight-report.json|$bundle_dir/handoffs/source-publication-readiness.tsv|$bundle_dir/handoffs/source-publication-root-owner.json" \
  SOURCE_PUBLICATION_SNAPSHOT_PROCESS_ARG="$bundle_dir" \
  NODE_OPTIONS="--require=$single_snapshot_preload" \
expect_success "valid bundle fixture - real Android generator export/verify regression"

spaced_bundle_dir="$tmp_dir/release unblock bundle"
if ! RELEASE_UNBLOCK_ROOT="$workspace_dir" \
  bash "$EXPORT_SCRIPT" --report-dir "$report_dir" --output "$spaced_bundle_dir" >/dev/null; then
  fail "bundle path with spaces export fixture unexpectedly failed"
fi
if ! RELEASE_UNBLOCK_ROOT="$workspace_dir" \
  bash "$VERIFY_SCRIPT" --bundle "$spaced_bundle_dir" >/dev/null; then
  fail "bundle path with spaces verification fixture unexpectedly failed"
fi
expected_quick_command="bash scripts/verify-release-unblock-bundle.sh --bundle '$spaced_bundle_dir' --max-age-hours 24"
grep -Fqx "$expected_quick_command" "$spaced_bundle_dir/unblock.md" ||
  fail "bundle path with spaces was not shell-quoted in Quick Verification"
cat > "$workspace_dir/scripts/verify-release-unblock-bundle.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
[[ "$#" -eq 4 ]]
[[ "$1" == "--bundle" ]]
[[ "$2" == "$EXPECTED_BUNDLE_PATH" ]]
[[ "$3" == "--max-age-hours" ]]
[[ "$4" == "24" ]]
SH
quick_command="$(grep -F 'bash scripts/verify-release-unblock-bundle.sh --bundle ' "$spaced_bundle_dir/unblock.md")"
if ! quick_output="$(
  cd "$workspace_dir" &&
    EXPECTED_BUNDLE_PATH="$spaced_bundle_dir" bash -c "$quick_command" 2>&1
)"; then
  echo "$quick_output" >&2
  fail "documented Quick Verification command failed for a bundle path with spaces"
fi
rm -f "$workspace_dir/scripts/verify-release-unblock-bundle.sh"
rm -rf "$spaced_bundle_dir"

staged_bundle_dir="$tmp_dir/.bundle.staging-fixture"
mv "$bundle_dir" "$staged_bundle_dir"
if ! staged_verify_output="$(run_verify_to "$staged_bundle_dir" --published-path "$bundle_dir" 2>&1)"; then
  echo "$staged_verify_output" >&2
  fail "private staging path with canonical publication rendering fixture unexpectedly failed"
fi
mv "$staged_bundle_dir" "$bundle_dir"

reset_external_plan_bundle
expect_success "external Iroha-only plan classification bundle fixture"

reset_external_plan_bundle reviewed-source
expect_success "external reviewed-source-mismatch plan classification bundle fixture"

reset_external_plan_bundle reviewed-source
expect_success "external reviewed-source postflight preflight-continuity marker fixture"

reset_external_plan_bundle reviewed-source
set_reviewed_source_authoritative_current_drift_bundle
expect_success "external reviewed-source authoritative-current drift live-shape fixture"

reset_external_plan_bundle reviewed-source
set_reviewed_source_authoritative_current_drift_bundle
edit_json "handoffs/source-publication-readiness-report.json" "const row = data.repositories[7]; row.currentBranchRemoteSha = row.prHeadSha; row.failures[2] = 'local HEAD ' + row.headSha + ' does not match authoritative current branch ' + row.branch + ' at ' + row.currentBranchRemoteSha; row.failures[5] = 'cached upstream ' + row.upstream + ' at ' + row.upstreamSha + ' does not match authoritative current branch ' + row.branch + ' at ' + row.currentBranchRemoteSha"
edit_json "manifest.json" "const row = data.sourcePublicationHandoff.repositories[7]; row.currentBranchRemoteSha = row.prHeadSha"
refresh_source_publication_report_handoff
expect_failure "external reviewed-source canonical remote cannot use absent PR head fixture" "handoffs/source-publication-readiness-report.json.repositories[7].currentBranchRemoteSha must match remoteHeadSha when branch matches head"

reset_external_plan_bundle reviewed-source
set_reviewed_source_authoritative_current_drift_bundle
edit_json "handoffs/source-publication-readiness-report.json" "const row = data.repositories[7]; row.prHeadSha = row.headSha; row.failures[3] = 'local HEAD ' + row.headSha + ' does not match pull request head ' + row.prHeadSha"
edit_json "manifest.json" "const row = data.sourcePublicationHandoff.repositories[7]; row.prHeadSha = row.headSha"
refresh_source_publication_report_handoff
expect_failure "external reviewed-source authoritative-current drift pull-request head equals local fixture" "plan-readiness unblock contract variant must match plan-readiness log classification"

reset_external_plan_bundle reviewed-source
set_reviewed_source_authoritative_current_drift_bundle
expect_success "external reviewed-source authoritative-current drift postflight fixture"

reset_external_plan_bundle reviewed-source
set_reviewed_source_authoritative_current_drift_bundle
edit_json "handoffs/source-publication-readiness-report.json" "data.repositories[7].failures.splice(1, 1)"
refresh_source_publication_report_handoff
expect_failure "external reviewed-source authoritative-current drift missing diagnostic fixture" "plan-readiness unblock contract variant must match plan-readiness log classification"

reset_external_plan_bundle reviewed-source
set_reviewed_source_authoritative_current_drift_bundle
edit_json "handoffs/source-publication-readiness-report.json" "data.repositories[7].failures.splice(2, 1)"
refresh_source_publication_report_handoff
expect_failure "external reviewed-source authoritative-current drift missing cached-upstream diagnostic fixture" "plan-readiness unblock contract variant must match plan-readiness log classification"

reset_external_plan_bundle reviewed-source
set_reviewed_source_authoritative_current_drift_bundle
edit_json "handoffs/source-publication-readiness-report.json" "const row = data.repositories[7]; const value = row.failures[2]; row.failures[2] = row.failures[3]; row.failures[3] = value"
refresh_source_publication_report_handoff
expect_failure "external reviewed-source authoritative-current drift reordered diagnostics fixture" "plan-readiness unblock contract variant must match plan-readiness log classification"

reset_external_plan_bundle reviewed-source
set_reviewed_source_authoritative_current_drift_bundle
edit_json "handoffs/source-publication-readiness-report.json" "const row = data.repositories[7]; row.failures[2] = 'local HEAD ' + row.headSha + ' does not match authoritative current branch ' + row.branch + ' at ' + 'f'.repeat(40)"
refresh_source_publication_report_handoff
expect_failure "external reviewed-source authoritative-current drift forged diagnostic fixture" "plan-readiness unblock contract variant must match plan-readiness log classification"

reset_external_plan_bundle reviewed-source
set_reviewed_source_authoritative_current_drift_bundle
edit_json "handoffs/source-publication-readiness-report.json" "const row = data.repositories[7]; row.failures[5] = 'cached upstream ' + row.upstream + ' at ' + 'f'.repeat(40) + ' does not match authoritative current branch ' + row.branch + ' at ' + row.currentBranchRemoteSha"
refresh_source_publication_report_handoff
expect_failure "external reviewed-source authoritative-current drift forged cached-upstream diagnostic fixture" "plan-readiness unblock contract variant must match plan-readiness log classification"

reset_external_plan_bundle reviewed-source
set_reviewed_source_authoritative_current_drift_bundle
edit_json "handoffs/source-publication-readiness-report.json" "const row = data.repositories[7]; row.currentBranchRemoteSha = row.headSha; row.remoteHeadSha = row.headSha; row.failures[2] = 'local HEAD ' + row.headSha + ' does not match authoritative current branch ' + row.branch + ' at ' + row.currentBranchRemoteSha; row.failures[5] = 'cached upstream ' + row.upstream + ' at ' + row.upstreamSha + ' does not match authoritative current branch ' + row.branch + ' at ' + row.currentBranchRemoteSha"
edit_json "manifest.json" "const row = data.sourcePublicationHandoff.repositories[7]; row.currentBranchRemoteSha = row.headSha; row.remoteHeadSha = row.headSha"
refresh_source_publication_report_handoff
expect_failure "external reviewed-source synchronized current with full drift diagnostics fixture" "plan-readiness unblock contract variant must match plan-readiness log classification"

reset_bundle
edit_json "handoffs/source-publication-preflight-report.json" "const row = data.repositories[0]; const sha = 'b'.repeat(40); for (const key of ['prHeadSha', 'headSha', 'upstreamSha', 'remoteHeadSha', 'currentBranchRemoteSha']) row[key] = sha"
rebind_bundled_source_publication_postflight
expect_failure "source publication preflight passed-source identity mismatch fixture" "manifest.sourcePublicationHandoff.sources[1].prHeadSha must match across preflight and postflight"

reset_external_plan_bundle reviewed-source
set_reviewed_source_authoritative_current_drift_bundle
edit_json "handoffs/source-publication-readiness-report.json" "data.repositories[7].failures.push('unrelated postflight diagnostic')"
refresh_source_publication_report_handoff
expect_failure "external reviewed-source authoritative-current drift six plus marker plus extra fixture" "plan-readiness unblock contract variant must match plan-readiness log classification"

reset_external_plan_bundle reviewed-source
set_reviewed_source_authoritative_current_drift_bundle
edit_json "handoffs/source-publication-readiness-report.json" "data.repositories[7].stagedCount = 1; data.totals.staged = 1"
edit_json "manifest.json" "data.sourcePublicationHandoff.repositories[7].stagedCount = 1"
refresh_source_publication_report_handoff
expect_failure "external reviewed-source authoritative-current drift nonzero worktree count fixture" "plan-readiness unblock contract variant must match plan-readiness log classification"

reset_external_plan_bundle reviewed-source
edit_json "handoffs/source-publication-readiness-report.json" "data.repositories[7].stagedCount = 1; data.totals.staged = 1"
edit_json "manifest.json" "data.sourcePublicationHandoff.repositories[7].stagedCount = 1"
refresh_source_publication_report_handoff
expect_failure "external reviewed-source synchronized nonzero worktree count fixture" "plan-readiness unblock contract variant must match plan-readiness log classification"

reset_external_plan_bundle reviewed-source
edit_json "handoffs/source-publication-readiness-report.json" "const marker = 'source publication preflight did not pass before release checks'; const failures = data.repositories[7].failures; failures.splice(failures.indexOf(marker), 1)"
refresh_manifest_artifact "handoffs/source-publication-readiness-report.json"
edit_json "manifest.json" "data.sourcePublicationHandoff.reportSha256 = data.artifacts.find((artifact) => artifact.path === 'handoffs/source-publication-readiness-report.json').sha256"
rewrite_checksums
expect_failure "external reviewed-source missing exact failed-preflight continuity marker fixture" "manifest.sourcePublicationHandoff.sources[8].failures must contain the exact failed-preflight continuity diagnostic"

reset_external_plan_bundle reviewed-source
edit_json "handoffs/source-publication-readiness-report.json" "const marker = 'source publication preflight did not pass before release checks'; data.repositories[7].failures.splice(data.repositories[7].failures.indexOf(marker), 1); data.repositories[7].failures.splice(1, 0, marker)"
refresh_manifest_artifact "handoffs/source-publication-readiness-report.json"
edit_json "manifest.json" "data.sourcePublicationHandoff.reportSha256 = data.artifacts.find((artifact) => artifact.path === 'handoffs/source-publication-readiness-report.json').sha256"
rewrite_checksums
expect_failure "external reviewed-source reordered preflight-continuity marker fixture" "plan-readiness unblock contract variant must match plan-readiness log classification"

reset_external_plan_bundle reviewed-source
edit_json "handoffs/source-publication-readiness-report.json" "data.repositories[7].failures.push('source publication preflight did not pass before release checks')"
refresh_manifest_artifact "handoffs/source-publication-readiness-report.json"
edit_json "manifest.json" "data.sourcePublicationHandoff.reportSha256 = data.artifacts.find((artifact) => artifact.path === 'handoffs/source-publication-readiness-report.json').sha256"
rewrite_checksums
expect_failure "external reviewed-source duplicate preflight-continuity marker fixture" "handoffs/source-publication-readiness-report.json.repositories[7].failures must not contain duplicates"

reset_external_plan_bundle reviewed-source
edit_json "handoffs/source-publication-readiness-report.json" "data.repositories[7].failures.push('unrelated postflight diagnostic')"
refresh_manifest_artifact "handoffs/source-publication-readiness-report.json"
edit_json "manifest.json" "data.sourcePublicationHandoff.reportSha256 = data.artifacts.find((artifact) => artifact.path === 'handoffs/source-publication-readiness-report.json').sha256"
rewrite_checksums
expect_failure "external reviewed-source preflight-continuity marker plus unrelated failure fixture" "plan-readiness unblock contract variant must match plan-readiness log classification"

reset_external_plan_bundle reviewed-source
edit_json "handoffs/source-publication-readiness-report.json" "data.repositories[7].failures[0] = 'worktree contains ignored non-published paths (0): forged; remove or quarantine these ignored outputs outside the source tree before publication; do not force-add generated artifacts'"
refresh_manifest_artifact "handoffs/source-publication-readiness-report.json"
edit_json "manifest.json" "data.sourcePublicationHandoff.reportSha256 = data.artifacts.find((artifact) => artifact.path === 'handoffs/source-publication-readiness-report.json').sha256"
rewrite_checksums
expect_failure "external reviewed-source malformed ignored-output diagnostic fixture" "plan-readiness unblock contract variant must match plan-readiness log classification"

reset_external_plan_bundle reviewed-source
edit_json "handoffs/source-publication-readiness-report.json" "const row = data.repositories[7]; row.failures.push('local HEAD ' + row.headSha + ' does not match authoritative current branch ' + row.branch + ' at ' + row.currentBranchRemoteSha)"
refresh_manifest_artifact "handoffs/source-publication-readiness-report.json"
edit_json "manifest.json" "data.sourcePublicationHandoff.reportSha256 = data.artifacts.find((artifact) => artifact.path === 'handoffs/source-publication-readiness-report.json').sha256"
rewrite_checksums
expect_failure "external reviewed-source obsolete extra current-branch diagnostic fixture" "plan-readiness unblock contract variant must match plan-readiness log classification"

reset_external_plan_bundle reviewed-source
edit_json "handoffs/source-publication-readiness-report.json" "data.repositories[7].prState = 'merged'"
edit_json "manifest.json" "data.sourcePublicationHandoff.repositories[7].prState = 'merged'"
refresh_manifest_artifact "handoffs/source-publication-readiness-report.json"
edit_json "manifest.json" "data.sourcePublicationHandoff.reportSha256 = data.artifacts.find((artifact) => artifact.path === 'handoffs/source-publication-readiness-report.json').sha256"
rewrite_checksums
expect_failure "external reviewed-source claimed pull-request review fixture" "plan-readiness unblock contract variant must match plan-readiness log classification"

reset_external_plan_bundle reviewed-source
edit_json "handoffs/source-publication-readiness-report.json" "data.repositories[7].prHeadSha = 'd'.repeat(40)"
edit_json "manifest.json" "data.sourcePublicationHandoff.repositories[7].prHeadSha = 'd'.repeat(40)"
refresh_manifest_artifact "handoffs/source-publication-readiness-report.json"
edit_json "manifest.json" "data.sourcePublicationHandoff.reportSha256 = data.artifacts.find((artifact) => artifact.path === 'handoffs/source-publication-readiness-report.json').sha256"
rewrite_checksums
expect_failure "external reviewed-source forged pull-request head SHA fixture" "plan-readiness unblock contract variant must match plan-readiness log classification"

reset_external_plan_bundle reviewed-source
edit_json "handoffs/source-publication-readiness-report.json" "data.repositories[7].failures.splice(1, 1)"
refresh_manifest_artifact "handoffs/source-publication-readiness-report.json"
edit_json "manifest.json" "data.sourcePublicationHandoff.reportSha256 = data.artifacts.find((artifact) => artifact.path === 'handoffs/source-publication-readiness-report.json').sha256"
rewrite_checksums
expect_failure "external reviewed-source missing pull-request head diagnostic fixture" "plan-readiness unblock contract variant must match plan-readiness log classification"

reset_external_plan_bundle reviewed-source
edit_json "handoffs/source-publication-readiness-report.json" "const row = data.repositories[7]; row.remoteBranchPresent = false; row.remoteHeadSha = null"
edit_json "manifest.json" "const row = data.sourcePublicationHandoff.repositories[7]; row.remoteBranchPresent = false; row.remoteHeadSha = null"
refresh_manifest_artifact "handoffs/source-publication-readiness-report.json"
edit_json "manifest.json" "data.sourcePublicationHandoff.reportSha256 = data.artifacts.find((artifact) => artifact.path === 'handoffs/source-publication-readiness-report.json').sha256"
rewrite_checksums
expect_failure "external reviewed-source invalid configured-ref relation fixture" "handoffs/source-publication-readiness-report.json.repositories[7].currentBranchRemotePresent must match remoteBranchPresent when branch matches head"

reset_external_plan_bundle reviewed-source
edit_json "handoffs/source-publication-readiness-report.json" "data.repositories[7].headSha = 'd'.repeat(40)"
edit_json "manifest.json" "data.sourcePublicationHandoff.repositories[7].headSha = 'd'.repeat(40)"
refresh_manifest_artifact "handoffs/source-publication-readiness-report.json"
edit_json "manifest.json" "data.sourcePublicationHandoff.reportSha256 = data.artifacts.find((artifact) => artifact.path === 'handoffs/source-publication-readiness-report.json').sha256"
rewrite_checksums
expect_failure "external reviewed-source forged local HEAD fixture" "plan-readiness unblock contract variant must match plan-readiness log classification"

reset_external_plan_bundle reviewed-source
edit_json "handoffs/source-publication-readiness-report.json" "data.repositories[7].upstreamSha = 'd'.repeat(40)"
refresh_manifest_artifact "handoffs/source-publication-readiness-report.json"
edit_json "manifest.json" "data.sourcePublicationHandoff.reportSha256 = data.artifacts.find((artifact) => artifact.path === 'handoffs/source-publication-readiness-report.json').sha256"
rewrite_checksums
expect_failure "external reviewed-source forged cached upstream SHA fixture" "plan-readiness unblock contract variant must match plan-readiness log classification"

reset_external_plan_bundle reviewed-source
edit_json "handoffs/source-publication-readiness-report.json" "data.repositories[7].currentBranchRemoteSha = 'd'.repeat(40); data.repositories[7].remoteHeadSha = 'd'.repeat(40)"
edit_json "manifest.json" "data.sourcePublicationHandoff.repositories[7].currentBranchRemoteSha = 'd'.repeat(40); data.sourcePublicationHandoff.repositories[7].remoteHeadSha = 'd'.repeat(40)"
refresh_manifest_artifact "handoffs/source-publication-readiness-report.json"
edit_json "manifest.json" "data.sourcePublicationHandoff.reportSha256 = data.artifacts.find((artifact) => artifact.path === 'handoffs/source-publication-readiness-report.json').sha256"
rewrite_checksums
expect_failure "external reviewed-source forged authoritative current-branch proof fixture" "plan-readiness unblock contract variant must match plan-readiness log classification"

reset_external_plan_bundle reviewed-source
edit_json "handoffs/source-publication-readiness-report.json" "const row = data.repositories[7]; row.currentBranchRemotePresent = false; row.currentBranchRemoteSha = null; row.remoteBranchPresent = false; row.remoteHeadSha = null"
edit_json "manifest.json" "const row = data.sourcePublicationHandoff.repositories[7]; row.currentBranchRemotePresent = false; row.currentBranchRemoteSha = null; row.remoteBranchPresent = false; row.remoteHeadSha = null"
refresh_manifest_artifact "handoffs/source-publication-readiness-report.json"
edit_json "manifest.json" "data.sourcePublicationHandoff.reportSha256 = data.artifacts.find((artifact) => artifact.path === 'handoffs/source-publication-readiness-report.json').sha256"
rewrite_checksums
expect_failure "external reviewed-source missing authoritative current-branch proof fixture" "plan-readiness unblock contract variant must match plan-readiness log classification"

reset_external_plan_bundle reviewed-source
edit_json "handoffs/source-publication-readiness-report.json" "const row = data.repositories[7]; const marker = 'source publication preflight did not pass before release checks'; const markerIndex = row.failures.indexOf(marker); row.currentBranchRemoteSha = row.headSha; row.remoteHeadSha = row.headSha; row.failures.splice(markerIndex, 0, 'local HEAD ' + row.headSha + ' does not match authoritative current branch ' + row.branch + ' at ' + row.currentBranchRemoteSha, 'cached upstream ' + row.upstream + ' at ' + row.upstreamSha + ' does not match authoritative current branch ' + row.branch + ' at ' + row.currentBranchRemoteSha)"
edit_json "manifest.json" "data.sourcePublicationHandoff.repositories[7].currentBranchRemoteSha = data.sourcePublicationHandoff.repositories[7].headSha"
refresh_manifest_artifact "handoffs/source-publication-readiness-report.json"
edit_json "manifest.json" "data.sourcePublicationHandoff.reportSha256 = data.artifacts.find((artifact) => artifact.path === 'handoffs/source-publication-readiness-report.json').sha256"
rewrite_checksums
expect_failure "external reviewed-source obsolete authoritative current-branch drift diagnostics fixture" "plan-readiness unblock contract variant must match plan-readiness log classification"

reset_external_plan_bundle
edit_json "handoffs/source-publication-readiness-report.json" "const row = data.repositories[7]; row.branch = 'optimizations'; row.upstream = 'origin/optimizations'; row.remoteBranchPresent = false; row.remoteHeadSha = 'd'.repeat(40)"
edit_json "manifest.json" "const row = data.sourcePublicationHandoff.repositories[7]; row.remoteBranchPresent = false; row.remoteHeadSha = 'd'.repeat(40)"
refresh_manifest_artifact "handoffs/source-publication-readiness-report.json"
edit_json "manifest.json" "data.sourcePublicationHandoff.reportSha256 = data.artifacts.find((artifact) => artifact.path === 'handoffs/source-publication-readiness-report.json').sha256"
rewrite_checksums
expect_failure "failed differing-branch false configured-ref presence with SHA fixture" "handoffs/source-publication-readiness-report.json.repositories[7].remoteHeadSha must be null when remoteBranchPresent is false or null"

reset_external_plan_bundle
edit_json "handoffs/source-publication-readiness-report.json" "const row = data.repositories[7]; row.branch = 'optimizations'; row.upstream = 'origin/optimizations'; row.remoteBranchPresent = null; row.remoteHeadSha = 'd'.repeat(40)"
edit_json "manifest.json" "const row = data.sourcePublicationHandoff.repositories[7]; row.remoteBranchPresent = null; row.remoteHeadSha = 'd'.repeat(40)"
refresh_manifest_artifact "handoffs/source-publication-readiness-report.json"
edit_json "manifest.json" "data.sourcePublicationHandoff.reportSha256 = data.artifacts.find((artifact) => artifact.path === 'handoffs/source-publication-readiness-report.json').sha256"
rewrite_checksums
expect_failure "failed differing-branch null configured-ref presence with SHA fixture" "handoffs/source-publication-readiness-report.json.repositories[7].remoteHeadSha must be null when remoteBranchPresent is false or null"

reset_external_plan_bundle
edit_json "handoffs/source-publication-readiness-report.json" "const row = data.repositories[7]; row.currentBranchRemotePresent = false; row.currentBranchRemoteSha = 'b'.repeat(40)"
edit_json "manifest.json" "const row = data.sourcePublicationHandoff.repositories[7]; row.currentBranchRemotePresent = false; row.currentBranchRemoteSha = 'b'.repeat(40)"
refresh_manifest_artifact "handoffs/source-publication-readiness-report.json"
edit_json "manifest.json" "data.sourcePublicationHandoff.reportSha256 = data.artifacts.find((artifact) => artifact.path === 'handoffs/source-publication-readiness-report.json').sha256"
rewrite_checksums
expect_failure "failed Iroha false current-branch presence with SHA fixture" "handoffs/source-publication-readiness-report.json.repositories[7].currentBranchRemoteSha must be null when currentBranchRemotePresent is false or null"

reset_external_plan_bundle
edit_json "handoffs/source-publication-readiness-report.json" "const row = data.repositories[7]; row.currentBranchRemotePresent = false; row.currentBranchRemoteSha = null"
edit_json "manifest.json" "const row = data.sourcePublicationHandoff.repositories[7]; row.currentBranchRemotePresent = false; row.currentBranchRemoteSha = null"
refresh_manifest_artifact "handoffs/source-publication-readiness-report.json"
edit_json "manifest.json" "data.sourcePublicationHandoff.reportSha256 = data.artifacts.find((artifact) => artifact.path === 'handoffs/source-publication-readiness-report.json').sha256"
rewrite_checksums
expect_failure "failed Iroha matching-branch remote proof mismatch fixture" "handoffs/source-publication-readiness-report.json.repositories[7].currentBranchRemotePresent must match remoteBranchPresent when branch matches head"

reset_external_plan_bundle reviewed-source
edit_json "handoffs/source-publication-readiness-report.json" "const row = data.repositories[7]; row.remoteHeadSha = null; row.currentBranchRemoteSha = null"
edit_json "manifest.json" "const row = data.sourcePublicationHandoff.repositories[7]; row.remoteHeadSha = null; row.currentBranchRemoteSha = null"
refresh_manifest_artifact "handoffs/source-publication-readiness-report.json"
edit_json "manifest.json" "data.sourcePublicationHandoff.reportSha256 = data.artifacts.find((artifact) => artifact.path === 'handoffs/source-publication-readiness-report.json').sha256"
rewrite_checksums
expect_failure "failed Iroha malformed matching-branch remote response fixture" "plan-readiness unblock contract variant must match plan-readiness log classification"

reset_external_plan_bundle reviewed-source
edit_json "handoffs/source-publication-readiness-report.json" "data.repositories[7].failures[1] = 'upstream mismatch: expected origin/codex/kagemusha-selector-hardening, received origin/forged'"
refresh_manifest_artifact "handoffs/source-publication-readiness-report.json"
edit_json "manifest.json" "data.sourcePublicationHandoff.reportSha256 = data.artifacts.find((artifact) => artifact.path === 'handoffs/source-publication-readiness-report.json').sha256"
rewrite_checksums
expect_failure "external plan metadata with forged reviewed-source mismatch fixture" "plan-readiness unblock contract variant must match plan-readiness log classification"

reset_external_plan_bundle
edit_json "handoffs/source-publication-readiness-report.json" "data.repositories[7].failures = ['worktree is not clean (staged=1, unstaged=0, untracked=0, unmerged=0)', 'source publication preflight did not pass before release checks']"
refresh_manifest_artifact "handoffs/source-publication-readiness-report.json"
edit_json "manifest.json" "data.sourcePublicationHandoff.reportSha256 = data.artifacts.find((artifact) => artifact.path === 'handoffs/source-publication-readiness-report.json').sha256"
rewrite_checksums
expect_failure "external plan metadata without unsafe Iroha operation fixture" "plan-readiness unblock contract variant must match plan-readiness log classification"

reset_external_plan_bundle
edit_json "handoffs/source-publication-readiness-report.json" "data.repositories[7].failures = ['repository has an in-progress Git merge operation (FORGED_HEAD); only the repository owner may complete or abort it before source publication', 'source publication preflight did not pass before release checks']"
refresh_manifest_artifact "handoffs/source-publication-readiness-report.json"
edit_json "manifest.json" "data.sourcePublicationHandoff.reportSha256 = data.artifacts.find((artifact) => artifact.path === 'handoffs/source-publication-readiness-report.json').sha256"
rewrite_checksums
expect_failure "external plan metadata with forged Iroha operation marker fixture" "plan-readiness unblock contract variant must match plan-readiness log classification"

reset_external_plan_bundle
printf '%s\n' "  - fearless-iOS maintained source contract missing" >> "$bundle_dir/logs/plan-readiness.log"
refresh_plan_log_artifact
expect_failure "external plan metadata with mixed bundled log fixture" "plan-readiness unblock contract variant must match plan-readiness log classification"

reset_external_plan_bundle
printf '%s\n' \
  "[plan-readiness][error] Plan readiness audit failed:" \
  "  - ../iroha duplicate failure summary row" \
  >> "$bundle_dir/logs/plan-readiness.log"
refresh_plan_log_artifact
expect_failure "external plan metadata with duplicate failure marker fixture" "plan-readiness unblock contract variant must match plan-readiness log classification"

reset_external_plan_bundle
printf '%s\n' "unexpected post-summary text" >> "$bundle_dir/logs/plan-readiness.log"
refresh_plan_log_artifact
expect_failure "external plan metadata with post-summary text fixture" "plan-readiness unblock contract variant must match plan-readiness log classification"

reset_bundle
edit_json "manifest.json" "delete data.sourcePublicationHandoff"
rewrite_checksums
expect_failure "missing source publication handoff fixture" "manifest.sourcePublicationHandoff required for full-live bundle"

reset_bundle
edit_json "manifest.json" "data.schemaVersion = 2"
rewrite_checksums
expect_failure "legacy manifest schema fixture" "manifest must use schemaVersion 3; summary and actions must use schemaVersion 1"

reset_bundle
rm "$bundle_dir/handoffs/source-publication-preflight-report.json"
expect_failure "missing source publication preflight artifact fixture" "manifest artifact missing: handoffs/source-publication-preflight-report.json"

reset_bundle
edit_json "manifest.json" "data.artifacts.find((artifact) => artifact.path === 'handoffs/source-publication-preflight-report.json').sourcePath = data.artifacts.find((artifact) => artifact.path === 'handoffs/source-publication-readiness-report.json').sourcePath"
rewrite_checksums
expect_failure "source publication preflight artifact source path drift fixture" "handoffs/source-publication-preflight-report.json.sourcePath must match report artifact path"

reset_bundle
edit_json "handoffs/source-publication-readiness-report.json" "data.phase = 'preflight'"
refresh_source_publication_report_handoff
expect_failure "source publication wrong postflight phase fixture" "handoffs/source-publication-readiness-report.json.phase must be postflight"

reset_bundle
edit_json "handoffs/source-publication-preflight-report.json" "data.phase = 'postflight'; data.preflightReportSha256 = 'a'.repeat(64)"
refresh_source_publication_preflight_report_handoff
expect_failure "source publication wrong preflight phase fixture" "handoffs/source-publication-preflight-report.json.phase must be preflight"

reset_bundle
edit_json "handoffs/source-publication-readiness-report.json" "data.preflightReportSha256 = 'f'.repeat(64)"
refresh_source_publication_report_handoff
expect_failure "source publication preflight digest mismatch fixture" "manifest.sourcePublicationHandoff.postflight preflightReportSha256 must match the exact preflight report bytes"

reset_bundle
edit_json "manifest.json" "data.sourcePublicationHandoff.preflightReportSha256 = 'f'.repeat(64)"
rewrite_checksums
expect_failure "source publication preflight handoff checksum drift fixture" "manifest.sourcePublicationHandoff preflight report checksum mismatch"

reset_bundle
edit_json "handoffs/source-publication-preflight-report.json" "data.generatedAt = '2026-06-28T00:01:00.000Z'"
rebind_bundled_source_publication_postflight
expect_failure "source publication preflight chronology fixture" "manifest.sourcePublicationHandoff.preflight report must not postdate the postflight report"

reset_bundle
edit_json "manifest.json" "data.sourcePublicationHandoff.workspaceOwned = false"
rewrite_checksums
expect_failure "source publication workspace ownership drift fixture" "manifest.sourcePublicationHandoff.workspaceOwned mismatch"

reset_bundle
edit_json "manifest.json" "data.sourcePublicationHandoff.repositories[0].headSha = '0'.repeat(40)"
rewrite_checksums
expect_failure "source publication repository SHA handoff drift fixture" "manifest.sourcePublicationHandoff.repositories[0].headSha mismatch"

reset_bundle
edit_json "manifest.json" "data.sourcePublicationHandoff.repositories[7].headSha = '0'.repeat(40)"
rewrite_checksums
expect_failure "source publication Iroha SHA handoff drift fixture" "manifest.sourcePublicationHandoff.repositories[7].headSha mismatch"

reset_bundle
edit_json "manifest.json" "data.sourcePublicationHandoff.repositories[0].prHeadSha = '0'.repeat(40)"
rewrite_checksums
expect_failure "source publication pull-request head SHA handoff drift fixture" "manifest.sourcePublicationHandoff.repositories[0].prHeadSha mismatch"

reset_bundle
edit_json "manifest.json" "delete data.sourcePublicationHandoff.repositories[0].prHeadSha"
rewrite_checksums
expect_failure "source publication missing pull-request head SHA handoff fixture" "manifest.sourcePublicationHandoff.repositories[0].prHeadSha mismatch"

reset_bundle
edit_json "manifest.json" "data.sourcePublicationHandoff.repositories[0].currentBranchRemoteSha = '0'.repeat(40)"
rewrite_checksums
expect_failure "source publication current-branch SHA handoff drift fixture" "manifest.sourcePublicationHandoff.repositories[0].currentBranchRemoteSha mismatch"

reset_bundle
edit_json "manifest.json" "data.sourcePublicationHandoff.repositories[0].remoteBranchPresent = false"
rewrite_checksums
expect_failure "source publication configured-ref presence handoff drift fixture" "manifest.sourcePublicationHandoff.repositories[0].remoteBranchPresent mismatch"

reset_bundle
edit_json "manifest.json" "delete data.sourcePublicationHandoff.repositories[0].remoteBranchPresent"
rewrite_checksums
expect_failure "source publication missing configured-ref presence handoff fixture" "manifest.sourcePublicationHandoff.repositories[0].remoteBranchPresent mismatch"

reset_bundle
edit_json "manifest.json" "delete data.sourcePublicationHandoff.repositories[0].currentBranchRemotePresent"
rewrite_checksums
expect_failure "source publication missing current-branch presence handoff fixture" "manifest.sourcePublicationHandoff.repositories[0].currentBranchRemotePresent mismatch"

reset_bundle
edit_json "manifest.json" "data.sourcePublicationHandoff.repositories[0].unexpectedCurrentBranchProof = true"
rewrite_checksums
expect_failure "source publication extra current-branch handoff field fixture" "unsupported manifest.sourcePublicationHandoff.repositories[0] key: unexpectedCurrentBranchProof"

reset_bundle
edit_json "manifest.json" "data.sourcePublicationHandoff.repositories[0].branch = 'attacker/forged-current-branch'"
rewrite_checksums
expect_failure "source publication current-branch handoff drift fixture" "manifest.sourcePublicationHandoff.repositories[0].branch mismatch"

reset_bundle
edit_json "handoffs/source-publication-readiness-report.json" "data.checkRemote = false"
refresh_manifest_artifact "handoffs/source-publication-readiness-report.json"
rewrite_checksums
expect_failure "source publication non-live report fixture" "handoffs/source-publication-readiness-report.json.checkRemote must be true for a full-live bundle"

reset_bundle
edit_json "handoffs/source-publication-readiness-report.json" "data.schemaVersion = 2"
refresh_manifest_artifact "handoffs/source-publication-readiness-report.json"
rewrite_checksums
expect_failure "source publication legacy schema fixture" "handoffs/source-publication-readiness-report.json.schemaVersion must be 3"

reset_bundle
edit_json "handoffs/source-publication-readiness-report.json" "data.repositories[0].head = 'codex/forged-head'"
refresh_manifest_artifact "handoffs/source-publication-readiness-report.json"
rewrite_checksums
expect_failure "source publication report identity drift fixture" "handoffs/source-publication-readiness-report.json.repositories[0] identity mismatch"

reset_bundle
edit_json "handoffs/source-publication-readiness-report.json" "data.repositories.pop()"
refresh_manifest_artifact "handoffs/source-publication-readiness-report.json"
rewrite_checksums
expect_failure "source publication missing Iroha source fixture" "handoffs/source-publication-readiness-report.json.repositories must contain eight rows"

reset_bundle
edit_json "handoffs/source-publication-readiness-report.json" "const iroha = data.repositories.pop(); data.repositories.splice(6, 0, iroha)"
refresh_manifest_artifact "handoffs/source-publication-readiness-report.json"
rewrite_checksums
expect_failure "source publication Iroha source order fixture" "handoffs/source-publication-readiness-report.json.repositories[6] identity mismatch"

reset_bundle
edit_json "handoffs/source-publication-readiness-report.json" "data.repositories[7].head = 'attacker/unpublished-iroha'"
refresh_manifest_artifact "handoffs/source-publication-readiness-report.json"
rewrite_checksums
expect_failure "source publication Iroha identity fixture" "handoffs/source-publication-readiness-report.json.repositories[7] identity mismatch"

reset_bundle
edit_json "handoffs/source-publication-readiness-report.json" "data.repositories[7].status = 'passed'; data.repositories[7].failures = []; data.repositories[7].unstagedCount = 1; data.totals.unstaged = 1"
refresh_manifest_artifact "handoffs/source-publication-readiness-report.json"
rewrite_checksums
expect_failure "source publication passed dirty Iroha fixture" "handoffs/source-publication-readiness-report.json.repositories[7].canonical branch exact-SHA review is blocked"

reset_bundle
edit_json "handoffs/source-publication-readiness-report.json" "data.repositories[0].repositoryPath = '/tmp/attacker-controlled-source'"
refresh_manifest_artifact "handoffs/source-publication-readiness-report.json"
rewrite_checksums
expect_failure "source publication repository path forgery fixture" "handoffs/source-publication-readiness-report.json.repositories[0].repositoryPath mismatch"

reset_bundle
edit_json "handoffs/source-publication-readiness-report.json" "data.repositories[0].originUrl = 'https://user:password@github.com/soramitsu/fearless-Android.git'"
refresh_manifest_artifact "handoffs/source-publication-readiness-report.json"
rewrite_checksums
expect_failure "source publication credential origin fixture" "handoffs/source-publication-readiness-report.json contains secret-like token: password"

reset_bundle
edit_json "handoffs/source-publication-readiness-report.json" "data.repositories[0].originUrl = 'https://github.com/attacker/wrong.git'; data.repositories[0].originRepository = 'attacker/wrong'"
refresh_manifest_artifact "handoffs/source-publication-readiness-report.json"
rewrite_checksums
expect_failure "source publication origin identity forgery fixture" "handoffs/source-publication-readiness-report.json.repositories[0].originRepository must match repository for a passed source"

reset_bundle
edit_json "handoffs/source-publication-readiness-report.json" "data.repositories[0].branch = 'attacker/wrong-branch'"
refresh_manifest_artifact "handoffs/source-publication-readiness-report.json"
rewrite_checksums
expect_failure "source publication branch forgery fixture" "handoffs/source-publication-readiness-report.json.repositories[0].branch must match head for a passed source"

reset_bundle
edit_json "handoffs/source-publication-readiness-report.json" "data.repositories[0].prHeadSha = null"
refresh_manifest_artifact "handoffs/source-publication-readiness-report.json"
rewrite_checksums
expect_failure "source publication missing pull-request head SHA fixture" "handoffs/source-publication-readiness-report.json.repositories[0].prHeadSha is required for a passed source"

reset_bundle
edit_json "handoffs/source-publication-readiness-report.json" "data.repositories[0].prHeadSha = 'b'.repeat(40)"
refresh_manifest_artifact "handoffs/source-publication-readiness-report.json"
rewrite_checksums
expect_failure "source publication forged pull-request head SHA fixture" "handoffs/source-publication-readiness-report.json.repositories[0].prHeadSha must match headSha for a passed source"

reset_bundle
edit_json "handoffs/source-publication-readiness-report.json" "data.repositories[0].upstreamSha = 'b'.repeat(40)"
refresh_manifest_artifact "handoffs/source-publication-readiness-report.json"
rewrite_checksums
expect_failure "source publication upstream SHA forgery fixture" "handoffs/source-publication-readiness-report.json.repositories[0].upstream must match the published head when the remote branch exists"

reset_bundle
edit_json "handoffs/source-publication-readiness-report.json" "data.repositories[0].unstagedCount = 1; data.totals.unstaged = 1"
refresh_manifest_artifact "handoffs/source-publication-readiness-report.json"
rewrite_checksums
expect_failure "source publication passed dirty source fixture" "handoffs/source-publication-readiness-report.json.repositories[0].passed source must have zero dirty counts"

reset_bundle
edit_json "handoffs/source-publication-readiness-report.json" "data.repositories[0].remoteBranchPresent = null; data.repositories[0].remoteHeadSha = null; data.repositories[0].currentBranchRemotePresent = null; data.repositories[0].currentBranchRemoteSha = null"
refresh_manifest_artifact "handoffs/source-publication-readiness-report.json"
rewrite_checksums
expect_failure "source publication missing remote proof fixture" "handoffs/source-publication-readiness-report.json.repositories[0].remoteBranchPresent is required for a passed source"

reset_bundle
edit_json "handoffs/source-publication-readiness-report.json" "data.repositories[0].currentBranchRemotePresent = null; data.repositories[0].currentBranchRemoteSha = null"
refresh_manifest_artifact "handoffs/source-publication-readiness-report.json"
rewrite_checksums
expect_failure "source publication missing current-branch remote proof fixture" "handoffs/source-publication-readiness-report.json.repositories[0].currentBranchRemotePresent must match remoteBranchPresent when branch matches head"

reset_bundle
edit_json "handoffs/source-publication-readiness-report.json" "data.repositories[0].currentBranchRemoteSha = 'b'.repeat(40)"
refresh_manifest_artifact "handoffs/source-publication-readiness-report.json"
rewrite_checksums
expect_failure "source publication forged current-branch remote SHA fixture" "handoffs/source-publication-readiness-report.json.repositories[0].currentBranchRemoteSha must match remoteHeadSha when branch matches head"

reset_bundle
edit_json "handoffs/source-publication-readiness-report.json" "data.repositories[0].currentBranchRemotePresent = false; data.repositories[0].currentBranchRemoteSha = null"
refresh_manifest_artifact "handoffs/source-publication-readiness-report.json"
rewrite_checksums
expect_failure "source publication current/configured branch presence mismatch fixture" "handoffs/source-publication-readiness-report.json.repositories[0].currentBranchRemotePresent must match remoteBranchPresent when branch matches head"

reset_bundle
edit_json "handoffs/source-publication-readiness-report.json" "data.repositories[0].remoteBranchPresent = false; data.repositories[0].remoteHeadSha = null; data.repositories[0].currentBranchRemotePresent = false; data.repositories[0].currentBranchRemoteSha = null; data.repositories[0].upstream = null; data.repositories[0].upstreamSha = null"
edit_json "manifest.json" "const row = data.sourcePublicationHandoff.repositories[0]; row.remoteBranchPresent = false; row.remoteHeadSha = null; row.currentBranchRemotePresent = false; row.currentBranchRemoteSha = null"
refresh_manifest_artifact "handoffs/source-publication-readiness-report.json"
edit_json "manifest.json" "data.sourcePublicationHandoff.reportSha256 = data.artifacts.find((artifact) => artifact.path === 'handoffs/source-publication-readiness-report.json').sha256"
rewrite_checksums
expect_success "source publication deleted merged current/configured branch proof fixture"

reset_bundle
edit_json "handoffs/source-publication-readiness-report.json" "data.repositories[0].prState = 'open'"
refresh_manifest_artifact "handoffs/source-publication-readiness-report.json"
rewrite_checksums
expect_failure "source publication unmerged passed source fixture" "handoffs/source-publication-readiness-report.json.repositories[0].prState must be merged for a passed source"

reset_bundle
edit_json "handoffs/source-publication-readiness-report.json" "data.workspaceSource.requiredTrackedFiles.pop()"
refresh_manifest_artifact "handoffs/source-publication-readiness-report.json"
rewrite_checksums
expect_failure "source publication workspace tracked-file proof fixture" "handoffs/source-publication-readiness-report.json.workspaceSource.requiredTrackedFiles length mismatch"

reset_bundle
edit_json "handoffs/source-publication-root-owner.json" "Object.assign(data, {status: 'blocked', repository: null, head: null, base: null, prNumber: null, blocker: 'canonical-root-source-owner-unassigned'})"
cp "$bundle_dir/handoffs/source-publication-root-owner.json" "$workspace_dir/config/source-publication-root-owner.json"
refresh_manifest_artifact "handoffs/source-publication-root-owner.json"
rewrite_checksums
expect_failure "source publication blocked root owner with passed source fixture" "manifest.sourcePublicationHandoff.workspaceSource must fail while root owner config is blocked"

reset_bundle
edit_json "handoffs/source-publication-root-owner.json" "data.repository = 'attacker/wrong'"
cp "$bundle_dir/handoffs/source-publication-root-owner.json" "$workspace_dir/config/source-publication-root-owner.json"
refresh_manifest_artifact "handoffs/source-publication-root-owner.json"
rewrite_checksums
expect_failure "source publication root owner identity mismatch fixture" "manifest.sourcePublicationHandoff.workspaceSource.repository must match root owner config"

reset_bundle
edit_json "handoffs/source-publication-root-owner.json" "Object.assign(data, {repository: 'attacker/unlisted-root', head: 'attacker/release', base: 'main', prNumber: 999})"
cp "$bundle_dir/handoffs/source-publication-root-owner.json" "$workspace_dir/config/source-publication-root-owner.json"
edit_json "handoffs/source-publication-readiness-report.json" "const source = data.workspaceSource; Object.assign(source, {repository: 'attacker/unlisted-root', head: 'attacker/release', base: 'main', prNumber: 999, prUrl: 'https://github.com/attacker/unlisted-root/pull/999', originUrl: 'https://github.com/attacker/unlisted-root.git', originRepository: 'attacker/unlisted-root', branch: 'attacker/release', upstream: 'origin/attacker/release'})"
refresh_manifest_artifact "handoffs/source-publication-root-owner.json"
refresh_manifest_artifact "handoffs/source-publication-readiness-report.json"
rewrite_checksums
expect_failure "source publication unlisted root owner release row fixture" "manifest.sourcePublicationHandoff.sources[0].repository must match across preflight and postflight"

reset_bundle
edit_json "handoffs/source-publication-readiness-report.json" "data.rootOwnerConfigFile = '/tmp/attacker-root-owner.json'"
refresh_manifest_artifact "handoffs/source-publication-readiness-report.json"
rewrite_checksums
expect_failure "source publication root owner config path drift fixture" "handoffs/source-publication-readiness-report.json.rootOwnerConfigFile mismatch"

reset_bundle
edit_json "handoffs/source-publication-root-owner.json" "data.lastReviewed = '2999-01-01'"
cp "$bundle_dir/handoffs/source-publication-root-owner.json" "$workspace_dir/config/source-publication-root-owner.json"
refresh_manifest_artifact "handoffs/source-publication-root-owner.json"
rewrite_checksums
expect_failure "source publication future root owner review fixture" "handoffs/source-publication-root-owner.json.lastReviewed must not be in the future"

reset_bundle
edit_json "handoffs/source-publication-root-owner.json" "data.lastReviewed = '2026-06-27'"
refresh_manifest_artifact "handoffs/source-publication-root-owner.json"
rewrite_checksums
expect_failure "source publication root owner workspace parity fixture" "handoffs/source-publication-root-owner.json does not match workspace source artifact"

reset_bundle
printf '%s\n' '# forged but semantically ignored comment' >> "$bundle_dir/handoffs/source-publication-readiness.tsv"
refresh_manifest_artifact "handoffs/source-publication-readiness.tsv"
rewrite_checksums
expect_failure "source publication config workspace parity fixture" "handoffs/source-publication-readiness.tsv does not match workspace source artifact"

reset_bundle
printf '%s\n' '# api_key=ghp_fixture_secret' >> "$bundle_dir/handoffs/source-publication-readiness.tsv"
printf '%s\n' '# api_key=ghp_fixture_secret' >> "$workspace_dir/config/source-publication-readiness.tsv"
refresh_manifest_artifact "handoffs/source-publication-readiness.tsv"
rewrite_checksums
expect_failure "source publication matched secret config fixture" "handoffs/source-publication-readiness.tsv contains secret-like token: api_key"

reset_bundle
edit_json "manifest.json" "data.sourcePublicationHandoff.rootOwnerStatus = 'blocked'"
rewrite_checksums
expect_failure "source publication root owner handoff status drift fixture" "manifest.sourcePublicationHandoff.rootOwnerStatus mismatch"

reset_bundle
edit_json "handoffs/source-publication-readiness-report.json" "data.generatedAt = '2026-06-27T23:50:00.000Z'"
refresh_manifest_artifact "handoffs/source-publication-readiness-report.json"
rewrite_checksums
expect_failure "source publication stale report fixture" "handoffs/source-publication-readiness-report.json.generatedAt must be within five minutes of summary.generatedAt"

reset_bundle
edit_json "handoffs/source-publication-readiness-report.json" "data.generatedAt = '2026-06-28T00:04:00.000Z'"
refresh_manifest_artifact "handoffs/source-publication-readiness-report.json"
rewrite_checksums
expect_failure "source publication post-summary report fixture" "handoffs/source-publication-readiness-report.json.generatedAt must not be later than summary.generatedAt"

reset_bundle
edit_json "handoffs/source-publication-readiness-report.json" "data.totals.passed = 7; data.totals.failed = 2; data.status = 'failed'"
refresh_manifest_artifact "handoffs/source-publication-readiness-report.json"
rewrite_checksums
expect_failure "source publication report totals drift fixture" "handoffs/source-publication-readiness-report.json.totals.passed mismatch"

reset_bundle
perl -0pi -e 's/codex\/android-production-consolidated-20260731/codex\/forged-head/' "$bundle_dir/handoffs/source-publication-readiness.tsv"
refresh_manifest_artifact "handoffs/source-publication-readiness.tsv"
rewrite_checksums
expect_failure "source publication config identity drift fixture" "handoffs/source-publication-readiness.tsv row 1 identity mismatch"

reset_bundle
perl -0pi -e 's/\t1260$/\t01260/m' "$bundle_dir/handoffs/source-publication-readiness.tsv"
refresh_manifest_artifact "handoffs/source-publication-readiness.tsv"
rewrite_checksums
expect_failure "source publication config noncanonical PR fixture" "handoffs/source-publication-readiness.tsv row 1 pull request must be canonical positive digits"

reset_bundle
sed -i.bak '/^\.\.\/iroha/d' "$bundle_dir/handoffs/source-publication-readiness.tsv"
rm "$bundle_dir/handoffs/source-publication-readiness.tsv.bak"
refresh_manifest_artifact "handoffs/source-publication-readiness.tsv"
rewrite_checksums
expect_failure "source publication missing Iroha config fixture" "handoffs/source-publication-readiness.tsv must contain eight rows"

reset_bundle
perl -0pi -e 's#hyperledger-iroha/iroha#attacker/iroha#' "$bundle_dir/handoffs/source-publication-readiness.tsv"
refresh_manifest_artifact "handoffs/source-publication-readiness.tsv"
rewrite_checksums
expect_failure "source publication Iroha config identity fixture" "handoffs/source-publication-readiness.tsv row 8 identity mismatch"

reset_bundle
node - "$bundle_dir/handoffs/source-publication-readiness.tsv" <<'NODE'
const fs = require('fs')
const file = process.argv[2]
const lines = fs.readFileSync(file, 'utf8').trimEnd().split('\n')
const iroha = lines.pop()
lines.splice(lines.length - 1, 0, iroha)
fs.writeFileSync(file, `${lines.join('\n')}\n`)
NODE
refresh_manifest_artifact "handoffs/source-publication-readiness.tsv"
rewrite_checksums
expect_failure "source publication Iroha config order fixture" "handoffs/source-publication-readiness.tsv row 7 pull request must be canonical positive digits"

reset_bundle
rm "$bundle_dir/handoffs/source-publication-readiness-report.json"
expect_failure "missing source publication report artifact fixture" "manifest artifact missing: handoffs/source-publication-readiness-report.json"

reset_bundle
rm "$bundle_dir/handoffs/source-publication-root-owner.json"
expect_failure "missing source publication root owner artifact fixture" "manifest artifact missing: handoffs/source-publication-root-owner.json"

reset_bundle
expect_failure_with_workspace_root "missing verifier workspace root fixture" "$tmp_dir/missing-verifier-workspace" "workspace root missing"

reset_bundle
ln -s "$workspace_dir" "$tmp_dir/verifier-workspace-link"
expect_failure_with_workspace_root "verifier workspace root symlink fixture" "$tmp_dir/verifier-workspace-link" "workspace root must be a regular directory"

reset_bundle
real_workspace_parent="$tmp_dir/verifier-real-workspace-parent"
symlink_workspace_parent="$tmp_dir/verifier-workspace-parent-link"
rm -rf "$real_workspace_parent" "$symlink_workspace_parent"
mkdir -p "$real_workspace_parent"
mv "$workspace_dir" "$real_workspace_parent/fearless"
ln -s "$real_workspace_parent" "$symlink_workspace_parent"
expect_failure_with_workspace_root "verifier workspace root symlink-parent fixture" "$symlink_workspace_parent/fearless" "workspace root must not use a symlinked path component"

reset_bundle
printf '%s\n' "not a workspace" > "$tmp_dir/verifier-workspace-file"
expect_failure_with_workspace_root "verifier workspace root file fixture" "$tmp_dir/verifier-workspace-file" "workspace root must be a regular directory"

reset_bundle
mkdir -p "$tmp_dir/verifier-empty-workspace"
expect_failure_with_workspace_root "verifier workspace missing markers fixture" "$tmp_dir/verifier-empty-workspace" "workspace root is not a Fearless workspace"

reset_bundle
mkdir -p "$tmp_dir/verifier-symlink-marker-workspace/scripts"
printf '%s\n' '# Fearless symlink marker target' > "$tmp_dir/verifier-plan-marker-target.md"
printf '%s\n' '#!/usr/bin/env bash' 'exit 0' > "$tmp_dir/verifier-audit-marker-target.sh"
ln -s "$tmp_dir/verifier-plan-marker-target.md" "$tmp_dir/verifier-symlink-marker-workspace/FEARLESS_PROJECT_PLAN.md"
ln -s "$tmp_dir/verifier-audit-marker-target.sh" "$tmp_dir/verifier-symlink-marker-workspace/scripts/audit-release-readiness.sh"
expect_failure_with_workspace_root "verifier workspace symlink marker fixture" "$tmp_dir/verifier-symlink-marker-workspace" "workspace root is not a Fearless workspace"

reset_bundle
mkdir -p "$tmp_dir/verifier-placeholder-plan-workspace/scripts"
printf '%s\n' '# Fearless test workspace' > "$tmp_dir/verifier-placeholder-plan-workspace/FEARLESS_PROJECT_PLAN.md"
printf '%s\n' '#!/usr/bin/env bash' '# Usage: scripts/audit-release-readiness.sh' 'exit 0' > "$tmp_dir/verifier-placeholder-plan-workspace/scripts/audit-release-readiness.sh"
expect_failure_with_workspace_root "verifier workspace placeholder plan marker fixture" "$tmp_dir/verifier-placeholder-plan-workspace" "workspace root marker content mismatch"

reset_bundle
mkdir -p "$tmp_dir/verifier-placeholder-audit-workspace/scripts"
printf '%s\n' '# Fearless Universal Wallet Project Plan' > "$tmp_dir/verifier-placeholder-audit-workspace/FEARLESS_PROJECT_PLAN.md"
printf '%s\n' '#!/usr/bin/env bash' 'exit 0' > "$tmp_dir/verifier-placeholder-audit-workspace/scripts/audit-release-readiness.sh"
expect_failure_with_workspace_root "verifier workspace placeholder audit marker fixture" "$tmp_dir/verifier-placeholder-audit-workspace" "workspace root marker content mismatch"

reset_bundle
mkdir -p "$tmp_dir/verifier-nonexec-audit-workspace/scripts"
printf '%s\n' '# Fearless Universal Wallet Project Plan' > "$tmp_dir/verifier-nonexec-audit-workspace/FEARLESS_PROJECT_PLAN.md"
printf '%s\n' '#!/usr/bin/env bash' '# Usage: scripts/audit-release-readiness.sh' 'exit 0' > "$tmp_dir/verifier-nonexec-audit-workspace/scripts/audit-release-readiness.sh"
chmod 0644 "$tmp_dir/verifier-nonexec-audit-workspace/scripts/audit-release-readiness.sh"
expect_failure_with_workspace_root "verifier workspace non-executable audit marker fixture" "$tmp_dir/verifier-nonexec-audit-workspace" "workspace root marker must be executable"

reset_bundle
ln -s "$bundle_dir" "$tmp_dir/bundle-root-link"
expect_failure_to "bundle root symlink fixture" "$tmp_dir/bundle-root-link" "bundle directory must be a regular directory"

reset_bundle
rm -rf "$repo_scratch_dir"
mkdir -p "$repo_scratch_dir/real-bundle-parent"
mv "$bundle_dir" "$repo_scratch_dir/real-bundle-parent/bundle"
ln -s "$repo_scratch_dir/real-bundle-parent" "$repo_scratch_dir/bundle-parent-link"
expect_failure_to "bundle root symlink-parent fixture" "$repo_scratch_dir/bundle-parent-link/bundle" "bundle directory must not use a symlinked path component"

reset_bundle
printf '%s\n' "not a bundle" > "$tmp_dir/bundle-root-file"
expect_failure_to "bundle root file fixture" "$tmp_dir/bundle-root-file" "bundle directory must be a regular directory"

reset_bundle
printf '%s\n' '#!/usr/bin/env bash' 'exit 0' > "$outside_log"
rm "$bundle_dir/verify-blockers.sh"
ln -s "$outside_log" "$bundle_dir/verify-blockers.sh"
expect_failure "verify script symlink fixture" "verify-blockers.sh must be a regular file"

reset_bundle
printf '%s\n' "solswap production smoke failed for https://si.soramitsu.io/" > "$outside_log"
rm "$bundle_dir/logs/si-production-smoke.log"
ln -s "$outside_log" "$bundle_dir/logs/si-production-smoke.log"
expect_failure "manifest artifact symlink fixture" "manifest artifact must be a regular file: logs/si-production-smoke.log"

reset_bundle
outside_handoffs="$tmp_dir/outside-handoffs"
rm -rf "$outside_handoffs"
cp -R "$bundle_dir/handoffs" "$outside_handoffs"
rm -rf "$bundle_dir/handoffs"
ln -s "$outside_handoffs" "$bundle_dir/handoffs"
expect_failure "manifest artifact symlinked parent fixture" "must not use a symlinked parent component"

write_fixture
set_release_pr_backtick_evidence_fixture
export_bundle
expect_success "safe evidence-preview markdown fence bundle fixture"
assert_safe_evidence_markdown_fence

write_fixture
set_release_pr_backtick_evidence_fixture
export_bundle
rewrite_bundle_evidence_to_unsafe_fixed_fence "unblock.md"
rewrite_checksums
expect_failure "unsafe unblock evidence-preview markdown fence fixture" "unblock.md does not match manifest blockers"

write_fixture
set_release_pr_backtick_evidence_fixture
export_bundle
rewrite_bundle_evidence_to_unsafe_fixed_fence "blockers.md"
refresh_manifest_artifact "blockers.md"
rewrite_checksums
expect_failure "unsafe blocker-report evidence-preview markdown fence fixture" "blockers.md does not match summary/actions blockers"

write_fixture
set_release_pr_capped_evidence_fixture
export_bundle
expect_success "capped evidence-preview suffix bundle fixture"
assert_capped_evidence_preview_preserved

reset_bundle
edit_json "actions.json" "data.blockers[0].evidencePreview = 'wallet PRs still require review\\n[line capped to final 59 characters; see full log]'"
edit_json "manifest.json" "data.blockers[0].evidencePreview = 'wallet PRs still require review\\n[line capped to final 59 characters; see full log]'"
refresh_manifest_artifact "actions.json"
rewrite_checksums
expect_failure "action blocker dangling capped evidence-preview fixture" "release-pr-readiness.evidencePreview line cap marker must be followed by a source log line suffix"

reset_bundle
edit_json "actions.json" "data.blockers[0].evidencePreview = '[line capped to final 58 characters; see full log]\\nunresolvedReviewThreadIds=PRRT_release_one,PRRT_release_two'"
edit_json "manifest.json" "data.blockers[0].evidencePreview = '[line capped to final 58 characters; see full log]\\nunresolvedReviewThreadIds=PRRT_release_one,PRRT_release_two'"
refresh_manifest_artifact "actions.json"
rewrite_checksums
expect_failure "action blocker wrong-length capped evidence-preview fixture" "release-pr-readiness.evidencePreview capped line length must match line cap marker"

reset_bundle
perl -0pi -e 's/(- Requires external action: `true`\n)/$1$1/' "$bundle_dir/unblock.md"
rewrite_checksums
expect_failure "duplicate unblock external-action line fixture" "unblock.md must contain exactly one external-action line per blocker"

reset_bundle
perl -0pi -e 's/(- Unblock category: `review-and-merge`\n)/$1$1/' "$bundle_dir/unblock.md"
rewrite_checksums
expect_failure "duplicate unblock category line fixture" "unblock.md must contain exactly one unblock-category line per blocker"

reset_bundle
perl -0pi -e 's/(Recommended action:\n)/$1$1/' "$bundle_dir/unblock.md"
rewrite_checksums
expect_failure "duplicate unblock recommended-action line fixture" "unblock.md must contain exactly one recommended-action line per blocker"

reset_bundle
perl -0pi -e 's/(Verification command:\n)/$1$1/' "$bundle_dir/unblock.md"
rewrite_checksums
expect_failure "duplicate unblock verification-command line fixture" "unblock.md must contain exactly one verification-command line per blocker"

reset_bundle
perl -0pi -e 's/(- Requires external action: `true`\n)/$1$1/' "$bundle_dir/blockers.md"
refresh_manifest_artifact "blockers.md"
rewrite_checksums
expect_failure "duplicate blocker report external-action line fixture" "blockers.md must contain exactly one external-action line per blocker"

reset_bundle
perl -0pi -e 's/(- External prerequisite:[^\n]*\n)/$1$1/' "$bundle_dir/blockers.md"
refresh_manifest_artifact "blockers.md"
rewrite_checksums
expect_failure "duplicate blocker report external-prerequisite line fixture" "blockers.md must contain exactly one external-prerequisite line per blocker"

reset_bundle
perl -0pi -e 's/(- Recommended action:[^\n]*\n)/$1$1/' "$bundle_dir/blockers.md"
refresh_manifest_artifact "blockers.md"
rewrite_checksums
expect_failure "duplicate blocker report recommended-action line fixture" "blockers.md must contain exactly one recommended-action line per blocker"

reset_bundle
perl -0pi -e 's/(- Verification command:[^\n]*\n)/$1$1/' "$bundle_dir/blockers.md"
refresh_manifest_artifact "blockers.md"
rewrite_checksums
expect_failure "duplicate blocker report verification-command line fixture" "blockers.md must contain exactly one verification-command line per blocker"

reset_bundle
edit_json "manifest.json" "delete data.blockers.find((blocker) => blocker.slug === 'web-bitcoin-broadcast-evidence').evidenceTemplateCommands"
rewrite_checksums
expect_failure "evidence template command handoff missing fixture" "web-bitcoin-broadcast-evidence.evidenceTemplateCommands missing"

reset_bundle
edit_json "manifest.json" "data.blockers.find((blocker) => blocker.slug === 'web-bitcoin-broadcast-evidence').evidenceTemplateCommands[1] = 'cd fearless-wallet-web && echo unsafe-template'"
rewrite_checksums
expect_failure "evidence template command handoff mismatch fixture" "web-bitcoin-broadcast-evidence.evidenceTemplateCommands[1] mismatch"

reset_bundle
edit_json "manifest.json" "delete data.blockers.find((blocker) => blocker.slug === 'web-bitcoin-broadcast-evidence').evidenceTemplateHandoff"
rewrite_checksums
expect_failure "evidence template handoff missing fixture" "web-bitcoin-broadcast-evidence.evidenceTemplateHandoff missing"

reset_bundle
edit_json "manifest.json" "data.blockers.find((blocker) => blocker.slug === 'web-bitcoin-broadcast-evidence').evidenceTemplateHandoff.outputPath = 'fearless-wallet-web/build/reports/wrong-template.json'"
rewrite_checksums
expect_failure "evidence template handoff output mismatch fixture" "web-bitcoin-broadcast-evidence.evidenceTemplateHandoff.outputPath mismatch"

reset_bundle
edit_json "manifest.json" "data.blockers.find((blocker) => blocker.slug === 'web-bitcoin-broadcast-evidence').evidenceTemplateHandoff.selfTestCommand = 'cd fearless-wallet-web && yarn test:wrong-template'"
rewrite_checksums
expect_failure "evidence template handoff command mismatch fixture" "web-bitcoin-broadcast-evidence.evidenceTemplateHandoff.selfTestCommand mismatch"

reset_bundle
edit_json "manifest.json" "delete data.blockers.find((blocker) => blocker.slug === 'web-bitcoin-broadcast-evidence').evidenceTemplateHandoff.requiredEvidenceContracts"
rewrite_checksums
expect_failure "evidence template contract handoff missing fixture" "web-bitcoin-broadcast-evidence.evidenceTemplateHandoff.requiredEvidenceContracts must be an array"

reset_bundle
edit_json "manifest.json" "data.blockers.find((blocker) => blocker.slug === 'web-bitcoin-broadcast-evidence').evidenceTemplateHandoff.requiredEvidenceContracts[0] = 'indexerUrl may use any HTTPS endpoint'"
rewrite_checksums
expect_failure "evidence template contract handoff mismatch fixture" "web-bitcoin-broadcast-evidence.evidenceTemplateHandoff.requiredEvidenceContracts[0] mismatch"

reset_bundle
edit_json "manifest.json" "delete data.blockers.find((blocker) => blocker.slug === 'web-bitcoin-broadcast-evidence').bitcoinBroadcastTemplateHandoff"
rewrite_checksums
expect_failure "web Bitcoin template artifact handoff missing fixture" "web-bitcoin-broadcast-evidence.bitcoinBroadcastTemplateHandoff missing"

reset_bundle
edit_json "manifest.json" "data.blockers.find((blocker) => blocker.slug === 'web-bitcoin-broadcast-evidence').bitcoinBroadcastTemplateHandoff.templateSha256 = '0000000000000000000000000000000000000000000000000000000000000000'"
rewrite_checksums
expect_failure "web Bitcoin template artifact checksum mismatch fixture" "web-bitcoin-broadcast-evidence.bitcoinBroadcastTemplateHandoff.templateSha256 does not match artifact checksum"

reset_bundle
edit_json "manifest.json" "data.artifacts = data.artifacts.filter((artifact) => artifact.path !== 'handoffs/web-bitcoin-broadcast-evidence-template.json')"
rewrite_checksums
expect_failure "web Bitcoin template artifact manifest missing fixture" "web-bitcoin-broadcast-evidence.bitcoinBroadcastTemplateHandoff.templateArtifact missing from manifest artifacts"

reset_bundle
edit_json "manifest.json" "data.artifacts.find((artifact) => artifact.path === 'handoffs/web-bitcoin-broadcast-evidence-template.json').sourcePath = data.sourceReportDir + '/web-bitcoin-broadcast-evidence-template-drift.json'"
rewrite_checksums
expect_failure "web Bitcoin template artifact source path drift fixture" "handoffs/web-bitcoin-broadcast-evidence-template.json.sourcePath must match report artifact path"

reset_bundle
node - "$bundle_dir/handoffs/web-bitcoin-broadcast-evidence-template.json" <<'NODE'
const fs = require('fs')
const file = process.argv[2]
const data = JSON.parse(fs.readFileSync(file, 'utf8'))
data.evidence[0].commit = '0123456789abcdef0123456789abcdef01234567'
fs.writeFileSync(file, JSON.stringify(data, null, 2) + '\n')
NODE
rewrite_checksums
expect_failure "web Bitcoin template artifact placeholder drift fixture" "handoffs/web-bitcoin-broadcast-evidence-template.json.evidence[0].commit placeholder mismatch"

reset_bundle
edit_json "manifest.json" "delete data.blockers.find((blocker) => blocker.slug === 'passkey-deployment-evidence').passkeyDeploymentTemplateHandoff"
rewrite_checksums
expect_failure "passkey deployment template artifact handoff missing fixture" "passkey-deployment-evidence.passkeyDeploymentTemplateHandoff missing"

reset_bundle
edit_json "manifest.json" "data.blockers.find((blocker) => blocker.slug === 'passkey-deployment-evidence').passkeyDeploymentTemplateHandoff.templateSha256 = '0000000000000000000000000000000000000000000000000000000000000000'"
rewrite_checksums
expect_failure "passkey deployment template artifact checksum mismatch fixture" "passkey-deployment-evidence.passkeyDeploymentTemplateHandoff.templateSha256 does not match artifact checksum"

reset_bundle
edit_json "manifest.json" "data.artifacts = data.artifacts.filter((artifact) => artifact.path !== 'handoffs/passkey-deployment-evidence-template.json')"
rewrite_checksums
expect_failure "passkey deployment template artifact manifest missing fixture" "passkey-deployment-evidence.passkeyDeploymentTemplateHandoff.templateArtifact missing from manifest artifacts"

reset_bundle
edit_json "manifest.json" "data.artifacts.find((artifact) => artifact.path === 'handoffs/passkey-deployment-evidence-template.json').sourcePath = data.sourceReportDir + '/passkey-deployment-evidence-template-drift.json'"
rewrite_checksums
expect_failure "passkey deployment template artifact source path drift fixture" "handoffs/passkey-deployment-evidence-template.json.sourcePath must match report artifact path"

reset_bundle
node - "$bundle_dir/handoffs/passkey-deployment-evidence-template.json" <<'NODE'
const fs = require('fs')
const file = process.argv[2]
const data = JSON.parse(fs.readFileSync(file, 'utf8'))
data.deploymentEvidence[0].deployedCommit = '0123456789abcdef0123456789abcdef01234567'
fs.writeFileSync(file, JSON.stringify(data, null, 2) + '\n')
NODE
rewrite_checksums
expect_failure "passkey deployment template artifact placeholder drift fixture" "handoffs/passkey-deployment-evidence-template.json.deploymentEvidence[0].deployedCommit placeholder mismatch"

reset_bundle
node - "$bundle_dir/handoffs/passkey-deployment-evidence-template.json" <<'NODE'
const fs = require('fs')
const file = process.argv[2]
const data = JSON.parse(fs.readFileSync(file, 'utf8'))
data.deploymentEvidence[0].requestAccessPolicy.authorizedSmokePassed = false
fs.writeFileSync(file, JSON.stringify(data, null, 2) + '\n')
NODE
rewrite_checksums
expect_failure "passkey deployment request-access policy artifact drift fixture" "handoffs/passkey-deployment-evidence-template.json.deploymentEvidence[0].requestAccessPolicy.authorizedSmokePassed mismatch"

reset_bundle
node - "$bundle_dir/handoffs/passkey-deployment-evidence-template.json" <<'NODE'
const fs = require('fs')
const file = process.argv[2]
const data = JSON.parse(fs.readFileSync(file, 'utf8'))
data.deploymentEvidence[0].trustedProxyPolicy.directPublicAccessBlocked = false
fs.writeFileSync(file, JSON.stringify(data, null, 2) + '\n')
NODE
rewrite_checksums
expect_failure "passkey deployment trusted-proxy policy artifact drift fixture" "handoffs/passkey-deployment-evidence-template.json.deploymentEvidence[0].trustedProxyPolicy.directPublicAccessBlocked mismatch"

reset_bundle
node - "$bundle_dir/handoffs/passkey-deployment-evidence-template.json" <<'NODE'
const fs = require('fs')
const file = process.argv[2]
const data = JSON.parse(fs.readFileSync(file, 'utf8'))
data.deploymentEvidence[0].requestAccessPolicy.credentialLifecycleSmokePassed = false
fs.writeFileSync(file, JSON.stringify(data, null, 2) + '\n')
NODE
refresh_manifest_artifact "handoffs/passkey-deployment-evidence-template.json"
rewrite_checksums
expect_failure "passkey lifecycle evidence boolean artifact drift fixture" "handoffs/passkey-deployment-evidence-template.json.deploymentEvidence[0].requestAccessPolicy.credentialLifecycleSmokePassed mismatch"

reset_bundle
node - "$bundle_dir/handoffs/passkey-deployment-evidence-template.json" <<'NODE'
const fs = require('fs')
const file = process.argv[2]
const data = JSON.parse(fs.readFileSync(file, 'utf8'))
delete data.deploymentEvidence[0].liveHealthAttestation
fs.writeFileSync(file, JSON.stringify(data, null, 2) + '\n')
NODE
refresh_manifest_artifact "handoffs/passkey-deployment-evidence-template.json"
rewrite_checksums
expect_failure "passkey live-health attestation missing artifact fixture" "handoffs/passkey-deployment-evidence-template.json.deploymentEvidence[0].liveHealthAttestation must be an object"

reset_bundle
node - "$bundle_dir/handoffs/passkey-deployment-evidence-template.json" <<'NODE'
const fs = require('fs')
const file = process.argv[2]
const data = JSON.parse(fs.readFileSync(file, 'utf8'))
data.deploymentEvidence[0].liveHealthAttestation.payloadSha256 = 'sha256:TODO_UNBOUND_HEALTH_PAYLOAD'
fs.writeFileSync(file, JSON.stringify(data, null, 2) + '\n')
NODE
refresh_manifest_artifact "handoffs/passkey-deployment-evidence-template.json"
rewrite_checksums
expect_failure "passkey live-health payload digest artifact drift fixture" "handoffs/passkey-deployment-evidence-template.json.deploymentEvidence[0].liveHealthAttestation.payloadSha256 mismatch"

reset_bundle
node - "$bundle_dir/handoffs/passkey-deployment-evidence-template.json" <<'NODE'
const fs = require('fs')
const file = process.argv[2]
const data = JSON.parse(fs.readFileSync(file, 'utf8'))
data.deploymentEvidence[0].liveHealthAttestation.deploymentId = 'TODO_CROSS_DEPLOYMENT_ID'
fs.writeFileSync(file, JSON.stringify(data, null, 2) + '\n')
NODE
refresh_manifest_artifact "handoffs/passkey-deployment-evidence-template.json"
rewrite_checksums
expect_failure "passkey live-health deployment binding artifact drift fixture" "handoffs/passkey-deployment-evidence-template.json.deploymentEvidence[0].liveHealthAttestation.deploymentId mismatch"

reset_bundle
node - "$bundle_dir/handoffs/passkey-deployment-evidence-template.json" <<'NODE'
const fs = require('fs')
const file = process.argv[2]
const data = JSON.parse(fs.readFileSync(file, 'utf8'))
data.deploymentEvidence[0].platformProvisioningAttestation.observedAt = 'TODO_UNBOUND_PLATFORM_OBSERVED_AT'
fs.writeFileSync(file, JSON.stringify(data, null, 2) + '\n')
NODE
refresh_manifest_artifact "handoffs/passkey-deployment-evidence-template.json"
rewrite_checksums
expect_failure "passkey platform chronology artifact drift fixture" "handoffs/passkey-deployment-evidence-template.json.deploymentEvidence[0].platformProvisioningAttestation.observedAt mismatch"

reset_bundle
node - "$bundle_dir/handoffs/passkey-deployment-evidence-template.json" <<'NODE'
const fs = require('fs')
const file = process.argv[2]
const data = JSON.parse(fs.readFileSync(file, 'utf8'))
data.deploymentEvidence[0].platformProvisioningAttestation.payloadSha256 = 'sha256:TODO_UNBOUND_PLATFORM_PAYLOAD'
fs.writeFileSync(file, JSON.stringify(data, null, 2) + '\n')
NODE
refresh_manifest_artifact "handoffs/passkey-deployment-evidence-template.json"
rewrite_checksums
expect_failure "passkey platform payload digest artifact drift fixture" "handoffs/passkey-deployment-evidence-template.json.deploymentEvidence[0].platformProvisioningAttestation.payloadSha256 mismatch"

reset_bundle
edit_json "manifest.json" "data.blockers.find((blocker) => blocker.slug === 'passkey-deployment-evidence').passkeyDeploymentTemplateHandoff.webauthnAllowedOriginsTarget[2] = 'android:apk-key-hash:UNREVIEWED'"
rewrite_checksums
expect_failure "passkey deployment Android origin handoff drift fixture" "passkey-deployment-evidence.passkeyDeploymentTemplateHandoff.webauthnAllowedOriginsTarget[2] mismatch"

reset_bundle
edit_json "manifest.json" "data.blockers.find((blocker) => blocker.slug === 'passkey-deployment-evidence').passkeyDeploymentTemplateHandoff.requestAccessPolicyTarget.mode = 'reusable-token'"
rewrite_checksums
expect_failure "passkey deployment request-access handoff drift fixture" "passkey-deployment-evidence.passkeyDeploymentTemplateHandoff.requestAccessPolicyTarget.mode mismatch"

reset_bundle
edit_json "manifest.json" "data.blockers.find((blocker) => blocker.slug === 'passkey-deployment-evidence').passkeyDeploymentTemplateHandoff.liveHealthAttestationTarget.payloadSha256 = 'sha256:TODO_UNBOUND_HEALTH_PAYLOAD'"
rewrite_checksums
expect_failure "passkey live-health attestation handoff drift fixture" "passkey-deployment-evidence.passkeyDeploymentTemplateHandoff.liveHealthAttestationTarget.payloadSha256 mismatch"

reset_bundle
edit_json "manifest.json" "data.blockers.find((blocker) => blocker.slug === 'passkey-deployment-evidence').passkeyDeploymentTemplateHandoff.platformProvisioningAttestationTarget.imageDigest = 'sha256:TODO_DIFFERENT_IMAGE_DIGEST'"
rewrite_checksums
expect_failure "passkey platform attestation handoff drift fixture" "passkey-deployment-evidence.passkeyDeploymentTemplateHandoff.platformProvisioningAttestationTarget.imageDigest mismatch"

reset_bundle
edit_json "manifest.json" "data.blockers.find((blocker) => blocker.slug === 'passkey-deployment-evidence').passkeyDeploymentTemplateHandoff.requiredContracts[9] = 'ready evidence may be reused indefinitely'"
rewrite_checksums
expect_failure "passkey freshness contract handoff drift fixture" "passkey-deployment-evidence.passkeyDeploymentTemplateHandoff.requiredContracts[9] mismatch"

reset_bundle
edit_json "manifest.json" "data.blockers.find((blocker) => blocker.slug === 'passkey-deployment-evidence').passkeyDeploymentTemplateHandoff.requiredContracts[11] = 'blocked evidence may retain partial records'"
rewrite_checksums
expect_failure "passkey blocked-evidence contract handoff drift fixture" "passkey-deployment-evidence.passkeyDeploymentTemplateHandoff.requiredContracts[11] mismatch"

reset_bundle
edit_json "manifest.json" "delete data.blockers.find((blocker) => blocker.slug === 'passkey-production-smoke').passkeyProductionContractHandoff"
rewrite_checksums
expect_failure "passkey production contract handoff missing fixture" "passkey-production-smoke.passkeyProductionContractHandoff missing"

reset_bundle
edit_json "manifest.json" "data.blockers.find((blocker) => blocker.slug === 'passkey-production-smoke').passkeyProductionContractHandoff.productionConfigSha256 = '0000000000000000000000000000000000000000000000000000000000000000'"
rewrite_checksums
expect_failure "passkey production config checksum mismatch fixture" "passkey-production-smoke.passkeyProductionContractHandoff.productionConfigSha256 does not match artifact checksum"

reset_bundle
edit_json "manifest.json" "data.artifacts = data.artifacts.filter((artifact) => artifact.path !== 'handoffs/passkey-backup-production.json')"
rewrite_checksums
expect_failure "passkey production config artifact manifest missing fixture" "passkey-production-smoke.passkeyProductionContractHandoff.productionConfigArtifact missing from manifest artifacts"

reset_bundle
edit_json "manifest.json" "data.artifacts.find((artifact) => artifact.path === 'handoffs/passkey-backup-production.json').sourcePath = data.sourceReportDir + '/passkey-backup-production.json'"
rewrite_checksums
expect_failure "passkey production config source path drift fixture" "handoffs/passkey-backup-production.json.sourcePath must match workspace source artifact path"

reset_bundle
node - "$bundle_dir/handoffs/passkey-backup-production.json" <<'NODE'
const fs = require('fs')
const file = process.argv[2]
const data = JSON.parse(fs.readFileSync(file, 'utf8'))
data.challengeServiceBaseUrl = 'https://backup.example.invalid'
fs.writeFileSync(file, JSON.stringify(data, null, 2) + '\n')
NODE
refresh_manifest_artifact "handoffs/passkey-backup-production.json"
rewrite_checksums
expect_failure "passkey production config artifact drift fixture" "handoffs/passkey-backup-production.json.challengeServiceBaseUrl mismatch"

for spec in 'backupStorage|cloudkit-private-database' 'googleDriveScope|https://www.googleapis.com/auth/drive' 'additionalBackupStorage|none'; do
  reset_bundle
  field="${spec%%|*}"
  value="${spec#*|}"
  edit_json "handoffs/passkey-backup-production.json" "data.ios['$field'] = '$value'"
  refresh_manifest_artifact "handoffs/passkey-backup-production.json"
  rewrite_checksums
  expect_failure "iOS portable Drive contract $field fixture" "handoffs/passkey-backup-production.json.ios.$field mismatch"
done

reset_bundle
node - "$bundle_dir/handoffs/passkey-backup-production.json" <<'NODE'
const fs = require('fs')
const file = process.argv[2]
const data = JSON.parse(fs.readFileSync(file, 'utf8'))
data.releaseEnabled = true
fs.writeFileSync(file, JSON.stringify(data, null, 2) + '\n')
NODE
refresh_manifest_artifact "handoffs/passkey-backup-production.json"
rewrite_checksums
expect_failure "passkey production release gate artifact drift fixture" "handoffs/passkey-backup-production.json.releaseEnabled must be false"

reset_bundle
node - "$bundle_dir/handoffs/passkey-backup-production.json" <<'NODE'
const fs = require('fs')
const file = process.argv[2]
const data = JSON.parse(fs.readFileSync(file, 'utf8'))
data.requestAuthorization.bodyDigest = 'sha256-of-reencoded-json'
fs.writeFileSync(file, JSON.stringify(data, null, 2) + '\n')
NODE
refresh_manifest_artifact "handoffs/passkey-backup-production.json"
rewrite_checksums
expect_failure "passkey authorization body binding artifact drift fixture" "handoffs/passkey-backup-production.json.requestAuthorization.bodyDigest mismatch"

reset_bundle
node - "$bundle_dir/handoffs/passkey-backup-production.json" <<'NODE'
const fs = require('fs')
const file = process.argv[2]
const data = JSON.parse(fs.readFileSync(file, 'utf8'))
data.credentialLifecycle.finalRevocationRetainsOwnerTombstone = false
fs.writeFileSync(file, JSON.stringify(data, null, 2) + '\n')
NODE
refresh_manifest_artifact "handoffs/passkey-backup-production.json"
rewrite_checksums
expect_failure "passkey credentialLifecycle artifact drift fixture" "handoffs/passkey-backup-production.json.credentialLifecycle.finalRevocationRetainsOwnerTombstone mismatch"

reset_bundle
node - "$bundle_dir/handoffs/passkey-backup-challenge-service.openapi.json" <<'NODE'
const fs = require('fs')
const file = process.argv[2]
const data = JSON.parse(fs.readFileSync(file, 'utf8'))
data.servers[0].url = 'https://backup.example.invalid'
fs.writeFileSync(file, JSON.stringify(data, null, 2) + '\n')
NODE
refresh_manifest_artifact "handoffs/passkey-backup-challenge-service.openapi.json"
rewrite_checksums
expect_failure "passkey OpenAPI artifact drift fixture" "handoffs/passkey-backup-challenge-service.openapi.json.servers[0].url mismatch"

reset_bundle
node - "$bundle_dir/handoffs/passkey-backup-challenge-service.openapi.json" <<'NODE'
const fs = require('fs')
const file = process.argv[2]
const data = JSON.parse(fs.readFileSync(file, 'utf8'))
data.info.description = 'Generic WebAuthn challenge API.'
fs.writeFileSync(file, JSON.stringify(data, null, 2) + '\n')
NODE
refresh_manifest_artifact "handoffs/passkey-backup-challenge-service.openapi.json"
rewrite_checksums
expect_failure "passkey OpenAPI description artifact drift fixture" "handoffs/passkey-backup-challenge-service.openapi.json.info.description mismatch"

reset_bundle
node - "$bundle_dir/handoffs/passkey-backup-challenge-service.openapi.json" <<'NODE'
const fs = require('fs')
const file = process.argv[2]
const data = JSON.parse(fs.readFileSync(file, 'utf8'))
delete data.paths['/api/passkey-backup/v1/credentials/revoke-all']
fs.writeFileSync(file, JSON.stringify(data, null, 2) + '\n')
NODE
refresh_manifest_artifact "handoffs/passkey-backup-challenge-service.openapi.json"
rewrite_checksums
expect_failure "passkey lifecycle path removal artifact fixture" "handoffs/passkey-backup-challenge-service.openapi.json.paths./api/passkey-backup/v1/credentials/revoke-all.post missing"

reset_bundle
node - "$bundle_dir/handoffs/passkey-backup-challenge-service.openapi.json" <<'NODE'
const fs = require('fs')
const file = process.argv[2]
const data = JSON.parse(fs.readFileSync(file, 'utf8'))
data.paths['/api/passkey-backup/v1/registration/complete'].post.security = []
fs.writeFileSync(file, JSON.stringify(data, null, 2) + '\n')
NODE
refresh_manifest_artifact "handoffs/passkey-backup-challenge-service.openapi.json"
rewrite_checksums
expect_failure "passkey OpenAPI bearer security artifact drift fixture" "handoffs/passkey-backup-challenge-service.openapi.json.paths./api/passkey-backup/v1/registration/complete.post.security must require bearerAuth"

reset_bundle
node - "$bundle_dir/handoffs/passkey-backup-challenge-service.openapi.json" <<'NODE'
const fs = require('fs')
const file = process.argv[2]
const data = JSON.parse(fs.readFileSync(file, 'utf8'))
data.paths['/api/passkey-backup/v1/assertion/challenge'].post.responses['503'].$ref = '#/components/responses/InternalFailure'
fs.writeFileSync(file, JSON.stringify(data, null, 2) + '\n')
NODE
refresh_manifest_artifact "handoffs/passkey-backup-challenge-service.openapi.json"
rewrite_checksums
expect_failure "passkey OpenAPI authorization unavailable artifact drift fixture" "handoffs/passkey-backup-challenge-service.openapi.json.paths./api/passkey-backup/v1/assertion/challenge.post.responses.503 reference mismatch"

reset_bundle
node - "$bundle_dir/handoffs/passkey-backup-challenge-service.openapi.json" <<'NODE'
const fs = require('fs')
const file = process.argv[2]
const data = JSON.parse(fs.readFileSync(file, 'utf8'))
data.components.schemas.Base64UrlUserId.pattern = '^[A-Za-z0-9_-]+$'
fs.writeFileSync(file, JSON.stringify(data, null, 2) + '\n')
NODE
refresh_manifest_artifact "handoffs/passkey-backup-challenge-service.openapi.json"
rewrite_checksums
expect_failure "passkey OpenAPI canonical user ID artifact drift fixture" "handoffs/passkey-backup-challenge-service.openapi.json.components.schemas.Base64UrlUserId must be canonical 43-character unpadded base64url"

reset_bundle
node - "$bundle_dir/handoffs/passkey-backup-challenge-service.openapi.json" <<'NODE'
const fs = require('fs')
const file = process.argv[2]
const data = JSON.parse(fs.readFileSync(file, 'utf8'))
data.components.schemas.CredentialDescriptor.properties.userHandle = { $ref: '#/components/schemas/Base64UrlUserId' }
fs.writeFileSync(file, JSON.stringify(data, null, 2) + '\n')
NODE
refresh_manifest_artifact "handoffs/passkey-backup-challenge-service.openapi.json"
rewrite_checksums
expect_failure "passkey leaked credential descriptor field artifact fixture" "unsupported handoffs/passkey-backup-challenge-service.openapi.json.components.schemas.CredentialDescriptor.properties key: userHandle"

reset_bundle
edit_json "manifest.json" "data.blockers.find((blocker) => blocker.slug === 'passkey-production-smoke').passkeyProductionContractHandoff.composeSha256 = '0000000000000000000000000000000000000000000000000000000000000000'"
rewrite_checksums
expect_failure "passkey production compose checksum mismatch fixture" "passkey-production-smoke.passkeyProductionContractHandoff.composeSha256 does not match artifact checksum"

reset_bundle
edit_json "manifest.json" "data.artifacts = data.artifacts.filter((artifact) => artifact.path !== 'handoffs/passkey-backup-docker-compose.production.yml')"
rewrite_checksums
expect_failure "passkey production compose artifact manifest missing fixture" "passkey-production-smoke.passkeyProductionContractHandoff.composeArtifact missing from manifest artifacts"

reset_bundle
edit_json "manifest.json" "data.artifacts.find((artifact) => artifact.path === 'handoffs/passkey-backup-docker-compose.production.yml').sourcePath = data.sourceReportDir + '/passkey-backup-docker-compose.production.yml'"
rewrite_checksums
expect_failure "passkey production compose source path drift fixture" "handoffs/passkey-backup-docker-compose.production.yml.sourcePath must match workspace source artifact path"

reset_bundle
perl -0pi -e 's/"127\.0\.0\.1:8789:8789"/"0.0.0.0:8789:8789"/' "$bundle_dir/handoffs/passkey-backup-docker-compose.production.yml"
refresh_manifest_artifact "handoffs/passkey-backup-docker-compose.production.yml"
rewrite_checksums
expect_failure "passkey production public compose artifact drift fixture" "handoffs/passkey-backup-docker-compose.production.yml must include - \"127.0.0.1:8789:8789\""

reset_bundle
perl -0pi -e 's#    image: "\$\{PASSKEY_BACKUP_IMAGE_REPOSITORY:\?[^\n]+#    image: passkey-backup-challenge-service:release#' "$bundle_dir/handoffs/passkey-backup-docker-compose.production.yml"
refresh_manifest_artifact "handoffs/passkey-backup-docker-compose.production.yml"
rewrite_checksums
expect_failure "passkey production mutable compose image artifact fixture" "handoffs/passkey-backup-docker-compose.production.yml must include image: \"\${PASSKEY_BACKUP_IMAGE_REPOSITORY:?Set the reviewed passkey image repository}@sha256:\${PASSKEY_BACKUP_IMAGE_DIGEST:?Set the reviewed 64-character lowercase image digest}\""

reset_bundle
node - "$bundle_dir/handoffs/passkey-backup-docker-compose.production.yml" <<'NODE'
const fs = require('fs')
const file = process.argv[2]
const content = fs.readFileSync(file, 'utf8').replace(
  'PASSKEY_AUTHORIZATION_INTROSPECTION_URL: "${PASSKEY_AUTHORIZATION_INTROSPECTION_URL:?',
  'PASSKEY_AUTHORIZATION_INTROSPECTION_URL: "${PASSKEY_AUTHORIZATION_INTROSPECTION_URL:-',
)
fs.writeFileSync(file, content)
NODE
refresh_manifest_artifact "handoffs/passkey-backup-docker-compose.production.yml"
rewrite_checksums
expect_failure "passkey production introspection fallback artifact drift fixture" "handoffs/passkey-backup-docker-compose.production.yml must include PASSKEY_AUTHORIZATION_INTROSPECTION_URL: \"\${PASSKEY_AUTHORIZATION_INTROSPECTION_URL:?"

reset_bundle
perl -0pi -e 's/PASSKEY_GLOBAL_RATE_LIMIT_MAX_REQUESTS: "5000"/PASSKEY_GLOBAL_RATE_LIMIT_MAX_REQUESTS: "999999"/' "$bundle_dir/handoffs/passkey-backup-docker-compose.production.yml"
refresh_manifest_artifact "handoffs/passkey-backup-docker-compose.production.yml"
rewrite_checksums
expect_failure "passkey production global rate limit artifact drift fixture" "handoffs/passkey-backup-docker-compose.production.yml must include PASSKEY_GLOBAL_RATE_LIMIT_MAX_REQUESTS: \"5000\""

reset_bundle
edit_json "manifest.json" "data.blockers.find((blocker) => blocker.slug === 'passkey-production-smoke').passkeyProductionContractHandoff.requiredContracts[9] = 'POST operations may omit authorization during rollout'"
rewrite_checksums
expect_failure "passkey production authorization contract handoff drift fixture" "passkey-production-smoke.passkeyProductionContractHandoff.requiredContracts[9] mismatch"

reset_bundle
edit_json "manifest.json" "data.blockers.find((blocker) => blocker.slug === 'passkey-production-smoke').passkeyProductionContractHandoff.androidSignerEvidence.allowedSources[1] = 'aab-upload-key'"
rewrite_checksums
expect_failure "passkey Android signer evidence-source handoff drift fixture" "passkey-production-smoke.passkeyProductionContractHandoff.androidSignerEvidence.allowedSources[1] mismatch"

reset_bundle
edit_json "manifest.json" "data.blockers.find((blocker) => blocker.slug === 'passkey-production-smoke').passkeyProductionContractHandoff.androidSignerEvidence.exactPackageName = 'com.attacker.wallet'"
rewrite_checksums
expect_failure "passkey Android exact package handoff drift fixture" "passkey-production-smoke.passkeyProductionContractHandoff.androidSignerEvidence.exactPackageName mismatch"

reset_bundle
edit_json "manifest.json" "data.blockers.find((blocker) => blocker.slug === 'passkey-production-smoke').passkeyProductionContractHandoff.androidSignerEvidence.distributedApk.artifactFileEnvironmentVariable = 'PASSKEY_ANDROID_UNVERIFIED_APK_FILE'"
rewrite_checksums
expect_failure "passkey distributed APK file environment handoff drift fixture" "passkey-production-smoke.passkeyProductionContractHandoff.androidSignerEvidence.distributedApk.artifactFileEnvironmentVariable mismatch"

reset_bundle
edit_json "manifest.json" "data.blockers.find((blocker) => blocker.slug === 'passkey-production-smoke').passkeyProductionContractHandoff.androidSignerEvidence.distributedApk.exactlyOneSigningCertificateRequired = false"
rewrite_checksums
expect_failure "passkey distributed APK multi-signer handoff drift fixture" "passkey-production-smoke.passkeyProductionContractHandoff.androidSignerEvidence.distributedApk.exactlyOneSigningCertificateRequired mismatch"

reset_bundle
edit_json "manifest.json" "data.blockers.find((blocker) => blocker.slug === 'passkey-production-smoke').passkeyProductionContractHandoff.androidSignerEvidence.distributedApk.signatureSchemeV2OrV3Required = false"
rewrite_checksums
expect_failure "passkey distributed APK v1-only handoff drift fixture" "passkey-production-smoke.passkeyProductionContractHandoff.androidSignerEvidence.distributedApk.signatureSchemeV2OrV3Required mismatch"

reset_bundle
edit_json "manifest.json" "data.blockers.find((blocker) => blocker.slug === 'passkey-production-smoke').passkeyProductionContractHandoff.androidSignerEvidence.playAppSigningCertificate.certificateSha256EnvironmentVariable = 'PASSKEY_ANDROID_UNBOUND_CERTIFICATE_SHA256'"
rewrite_checksums
expect_failure "passkey Play certificate digest environment handoff drift fixture" "passkey-production-smoke.passkeyProductionContractHandoff.androidSignerEvidence.playAppSigningCertificate.certificateSha256EnvironmentVariable mismatch"

reset_bundle
edit_json "manifest.json" "data.blockers.find((blocker) => blocker.slug === 'passkey-production-smoke').passkeyProductionContractHandoff.androidSignerEvidence.playAppSigningCertificate.immutableFilesRequired = false"
rewrite_checksums
expect_failure "passkey mutable Play evidence handoff drift fixture" "passkey-production-smoke.passkeyProductionContractHandoff.androidSignerEvidence.playAppSigningCertificate.immutableFilesRequired mismatch"

reset_bundle
edit_json "manifest.json" "data.blockers.find((blocker) => blocker.slug === 'passkey-production-smoke').passkeyProductionContractHandoff.androidSignerEvidence.playAppSigningCertificate.certificateFingerprintDerivedFromX509Required = false"
rewrite_checksums
expect_failure "passkey self-declared Play fingerprint handoff drift fixture" "passkey-production-smoke.passkeyProductionContractHandoff.androidSignerEvidence.playAppSigningCertificate.certificateFingerprintDerivedFromX509Required mismatch"

reset_bundle
edit_json "manifest.json" "data.blockers.find((blocker) => blocker.slug === 'passkey-production-smoke').passkeyProductionContractHandoff.androidSignerEvidence.playAppSigningCertificate.attestationBindsCompiledPackageAndVersionCodeRequired = false"
rewrite_checksums
expect_failure "passkey unbound compiled AAB identity handoff drift fixture" "passkey-production-smoke.passkeyProductionContractHandoff.androidSignerEvidence.playAppSigningCertificate.attestationBindsCompiledPackageAndVersionCodeRequired mismatch"

reset_bundle
edit_json "manifest.json" "data.blockers.find((blocker) => blocker.slug === 'passkey-production-smoke').passkeyProductionContractHandoff.androidSignerEvidence.playAppSigningCertificate.unreviewed = true"
rewrite_checksums
expect_failure "passkey Play signer evidence extra-field handoff fixture" "unsupported passkey-production-smoke.passkeyProductionContractHandoff.androidSignerEvidence.playAppSigningCertificate key: unreviewed"

reset_bundle
edit_json "manifest.json" "data.blockers.find((blocker) => blocker.slug === 'passkey-production-smoke').passkeyProductionContractHandoff.requiredRoutePaths[7] = '/api/passkey-backup/v1/credentials/delete-all'"
rewrite_checksums
expect_failure "passkey lifecycle route contract handoff drift fixture" "passkey-production-smoke.passkeyProductionContractHandoff.requiredRoutePaths[7] mismatch"

reset_bundle
edit_json "manifest.json" "data.blockers.find((blocker) => blocker.slug === 'passkey-production-smoke').passkeyProductionContractHandoff.verificationCommands[4] = 'bash scripts/audit-passkey-android-origin-parity.sh'"
rewrite_checksums
expect_failure "passkey Android origin ready verification handoff drift fixture" "passkey-production-smoke.passkeyProductionContractHandoff.verificationCommands[4] mismatch"

reset_bundle
edit_json "manifest.json" "delete data.blockers.find((blocker) => blocker.slug === 'iroha-release-readiness').nexusProductionEvidenceTemplateHandoff"
rewrite_checksums
expect_failure "Nexus production evidence template artifact handoff missing fixture" "iroha-release-readiness.nexusProductionEvidenceTemplateHandoff missing"

reset_bundle
edit_json "manifest.json" "data.blockers.find((blocker) => blocker.slug === 'iroha-release-readiness').nexusProductionEvidenceTemplateHandoff.templateSha256 = '0000000000000000000000000000000000000000000000000000000000000000'"
rewrite_checksums
expect_failure "Nexus production evidence template artifact checksum mismatch fixture" "iroha-release-readiness.nexusProductionEvidenceTemplateHandoff.templateSha256 does not match artifact checksum"

reset_bundle
edit_json "manifest.json" "data.artifacts = data.artifacts.filter((artifact) => artifact.path !== 'handoffs/nexus-production-evidence-template.json')"
rewrite_checksums
expect_failure "Nexus production evidence template artifact manifest missing fixture" "iroha-release-readiness.nexusProductionEvidenceTemplateHandoff.templateArtifact missing from manifest artifacts"

reset_bundle
edit_json "manifest.json" "data.artifacts.find((artifact) => artifact.path === 'handoffs/nexus-production-evidence-template.json').sourcePath = data.sourceReportDir + '/nexus-production-evidence-template-drift.json'"
rewrite_checksums
expect_failure "Nexus production evidence template artifact source path drift fixture" "handoffs/nexus-production-evidence-template.json.sourcePath must match report artifact path"

reset_bundle
node - "$bundle_dir/handoffs/nexus-production-evidence-template.json" <<'NODE'
const fs = require('fs')
const file = process.argv[2]
const data = JSON.parse(fs.readFileSync(file, 'utf8'))
data.routePublicationEvidence[0].routeManifestCommit = '0123456789abcdef0123456789abcdef01234567'
fs.writeFileSync(file, JSON.stringify(data, null, 2) + '\n')
NODE
rewrite_checksums
expect_failure "Nexus production evidence template artifact placeholder drift fixture" "handoffs/nexus-production-evidence-template.json.routePublicationEvidence[0].routeManifestCommit mismatch"

reset_bundle
edit_json "handoffs/nexus-production-evidence-template.json" "data.routePublicationEvidence[0].routeManifestSourcePath = 'tmp/operator-selected-route.json'"
refresh_manifest_artifact "handoffs/nexus-production-evidence-template.json"
rewrite_checksums
expect_failure "Nexus canonical route source placeholder drift fixture" "handoffs/nexus-production-evidence-template.json.routePublicationEvidence[0].routeManifestSourcePath mismatch"

reset_bundle
edit_json "handoffs/nexus-production-evidence-template.json" "data.routePublicationEvidence[0].publishedAt = 'TODO_UTC_ROUTE_PUBLISHED_AT_SECONDS'"
refresh_manifest_artifact "handoffs/nexus-production-evidence-template.json"
rewrite_checksums
expect_failure "Nexus legacy seconds timestamp placeholder drift fixture" "handoffs/nexus-production-evidence-template.json.routePublicationEvidence[0].publishedAt mismatch"

reset_bundle
edit_json "handoffs/nexus-production-evidence-template.json" "data.routeCanaryEvidence[0].amount = 'TODO_UNBOUND_AMOUNT'"
refresh_manifest_artifact "handoffs/nexus-production-evidence-template.json"
rewrite_checksums
expect_failure "Nexus bound canary amount placeholder drift fixture" "handoffs/nexus-production-evidence-template.json.routeCanaryEvidence[0].amount mismatch"

reset_bundle
edit_json "manifest.json" "data.blockers.find((blocker) => blocker.slug === 'iroha-release-readiness').nexusProductionEvidenceTemplateHandoff.requiredContracts.pop()"
rewrite_checksums
expect_failure "Nexus self-test release-incompatibility contract removal fixture" "iroha-release-readiness.nexusProductionEvidenceTemplateHandoff.requiredContracts length mismatch"

reset_bundle
edit_json "manifest.json" "delete data.blockers.find((blocker) => blocker.slug === 'ti-deployment-evidence').indexerDeploymentTemplateHandoff"
rewrite_checksums
expect_failure "TI deployment template artifact handoff missing fixture" "ti-deployment-evidence.indexerDeploymentTemplateHandoff missing"

reset_bundle
edit_json "manifest.json" "data.blockers.find((blocker) => blocker.slug === 'ti-deployment-evidence').indexerDeploymentTemplateHandoff.templateSha256 = '0000000000000000000000000000000000000000000000000000000000000000'"
rewrite_checksums
expect_failure "TI deployment template artifact checksum mismatch fixture" "ti-deployment-evidence.indexerDeploymentTemplateHandoff.templateSha256 does not match artifact checksum"

reset_bundle
edit_json "manifest.json" "data.artifacts = data.artifacts.filter((artifact) => artifact.path !== 'handoffs/ti-deployment-evidence-template.json')"
rewrite_checksums
expect_failure "TI deployment template artifact manifest missing fixture" "ti-deployment-evidence.indexerDeploymentTemplateHandoff.templateArtifact missing from manifest artifacts"

reset_bundle
edit_json "manifest.json" "data.artifacts.find((artifact) => artifact.path === 'handoffs/ti-deployment-evidence-template.json').sourcePath = data.sourceReportDir + '/ti-deployment-evidence-template-drift.json'"
rewrite_checksums
expect_failure "TI deployment template artifact source path drift fixture" "handoffs/ti-deployment-evidence-template.json.sourcePath must match report artifact path"

reset_bundle
node - "$bundle_dir/handoffs/ti-deployment-evidence-template.json" <<'NODE'
const fs = require('fs')
const file = process.argv[2]
const data = JSON.parse(fs.readFileSync(file, 'utf8'))
data.deploymentEvidence[0].commit = '0123456789abcdef0123456789abcdef01234567'
fs.writeFileSync(file, JSON.stringify(data, null, 2) + '\n')
NODE
rewrite_checksums
expect_failure "TI deployment template artifact placeholder drift fixture" "handoffs/ti-deployment-evidence-template.json.deploymentEvidence[0].commit placeholder mismatch"

reset_bundle
edit_json "manifest.json" "delete data.blockers.find((blocker) => blocker.slug === 'ti-deployment-evidence').evidenceTemplateHandoff"
rewrite_checksums
expect_failure "TI deployment evidence template handoff missing fixture" "ti-deployment-evidence.evidenceTemplateHandoff missing"

reset_bundle
edit_json "manifest.json" "data.blockers.find((blocker) => blocker.slug === 'ti-deployment-evidence').evidenceTemplateCommands[1] = 'cd ../ton-indexer && npm run generate:deployment-evidence-template -- --output build/reports/wrong-template.json'"
rewrite_checksums
expect_failure "TI deployment evidence template command mismatch fixture" "ti-deployment-evidence.evidenceTemplateCommands[1] mismatch"

reset_bundle
edit_json "manifest.json" "data.blockers.find((blocker) => blocker.slug === 'ti-deployment-evidence').evidenceTemplateHandoff.readyAuditCommand = 'cd ../ton-indexer && npm run audit:deployment-evidence'"
rewrite_checksums
expect_failure "TI deployment evidence ready audit mismatch fixture" "ti-deployment-evidence.evidenceTemplateHandoff.readyAuditCommand mismatch"

reset_bundle
edit_json "manifest.json" "data.blockers.find((blocker) => blocker.slug === 'ti-deployment-evidence').evidenceTemplateHandoff.requiredEvidenceContracts[1] = 'serviceInfo.serviceId may be any TON service'"
rewrite_checksums
expect_failure "TI deployment evidence contract mismatch fixture" "ti-deployment-evidence.evidenceTemplateHandoff.requiredEvidenceContracts[1] mismatch"

reset_bundle
edit_json "manifest.json" "delete data.blockers.find((blocker) => blocker.slug === 'si-deployment-evidence').indexerDeploymentTemplateHandoff"
rewrite_checksums
expect_failure "SI deployment template artifact handoff missing fixture" "si-deployment-evidence.indexerDeploymentTemplateHandoff missing"

reset_bundle
edit_json "manifest.json" "data.blockers.find((blocker) => blocker.slug === 'si-deployment-evidence').indexerDeploymentTemplateHandoff.templateSha256 = '0000000000000000000000000000000000000000000000000000000000000000'"
rewrite_checksums
expect_failure "SI deployment template artifact checksum mismatch fixture" "si-deployment-evidence.indexerDeploymentTemplateHandoff.templateSha256 does not match artifact checksum"

reset_bundle
edit_json "manifest.json" "data.artifacts = data.artifacts.filter((artifact) => artifact.path !== 'handoffs/si-deployment-evidence-template.json')"
rewrite_checksums
expect_failure "SI deployment template artifact manifest missing fixture" "si-deployment-evidence.indexerDeploymentTemplateHandoff.templateArtifact missing from manifest artifacts"

reset_bundle
edit_json "manifest.json" "data.artifacts.find((artifact) => artifact.path === 'handoffs/si-deployment-evidence-template.json').sourcePath = data.sourceReportDir + '/si-deployment-evidence-template-drift.json'"
rewrite_checksums
expect_failure "SI deployment template artifact source path drift fixture" "handoffs/si-deployment-evidence-template.json.sourcePath must match report artifact path"

reset_bundle
node - "$bundle_dir/handoffs/si-deployment-evidence-template.json" <<'NODE'
const fs = require('fs')
const file = process.argv[2]
const data = JSON.parse(fs.readFileSync(file, 'utf8'))
data.deploymentEvidence[0].commit = '0123456789abcdef0123456789abcdef01234567'
fs.writeFileSync(file, JSON.stringify(data, null, 2) + '\n')
NODE
rewrite_checksums
expect_failure "SI deployment template artifact placeholder drift fixture" "handoffs/si-deployment-evidence-template.json.deploymentEvidence[0].commit placeholder mismatch"

reset_bundle
edit_json "manifest.json" "delete data.blockers.find((blocker) => blocker.slug === 'si-deployment-evidence').evidenceTemplateHandoff"
rewrite_checksums
expect_failure "SI deployment evidence template handoff missing fixture" "si-deployment-evidence.evidenceTemplateHandoff missing"

reset_bundle
edit_json "manifest.json" "data.blockers.find((blocker) => blocker.slug === 'si-deployment-evidence').evidenceTemplateCommands[1] = 'cd ../solswap-indexer && npm run generate:deployment-evidence-template -- --output build/reports/wrong-template.json'"
rewrite_checksums
expect_failure "SI deployment evidence template command mismatch fixture" "si-deployment-evidence.evidenceTemplateCommands[1] mismatch"

reset_bundle
edit_json "manifest.json" "data.blockers.find((blocker) => blocker.slug === 'si-deployment-evidence').evidenceTemplateHandoff.readyAuditCommand = 'cd ../solswap-indexer && npm run audit:deployment-evidence'"
rewrite_checksums
expect_failure "SI deployment evidence ready audit mismatch fixture" "si-deployment-evidence.evidenceTemplateHandoff.readyAuditCommand mismatch"

reset_bundle
edit_json "manifest.json" "data.blockers.find((blocker) => blocker.slug === 'si-deployment-evidence').evidenceTemplateHandoff.requiredEvidenceContracts[1] = 'serviceInfo.serviceId may be any Solana service'"
rewrite_checksums
expect_failure "SI deployment evidence contract mismatch fixture" "si-deployment-evidence.evidenceTemplateHandoff.requiredEvidenceContracts[1] mismatch"

reset_bundle
edit_json "manifest.json" "data.blockers.find((blocker) => blocker.slug === 'si-deployment-evidence').evidenceTemplateHandoff.requiredEvidenceContracts[5] = 'healthInfo.genesisHash may be any Solana cluster'"
rewrite_checksums
expect_failure "SI deployment evidence genesis contract drift fixture" "si-deployment-evidence.evidenceTemplateHandoff.requiredEvidenceContracts[5] mismatch"

reset_bundle
edit_json "manifest.json" "data.blockers.find((blocker) => blocker.slug === 'si-deployment-evidence').evidenceTemplateHandoff.requiredEvidenceContracts[6] = 'healthInfo.latestSlot may be zero'"
rewrite_checksums
expect_failure "SI deployment evidence slot contract drift fixture" "si-deployment-evidence.evidenceTemplateHandoff.requiredEvidenceContracts[6] mismatch"

reset_bundle
edit_json "manifest.json" "data.blockers.find((blocker) => blocker.slug === 'si-deployment-evidence').evidenceTemplateHandoff.requiredEvidenceContracts[7] = 'healthInfo.syncedAt may be stale'"
rewrite_checksums
expect_failure "SI deployment evidence freshness contract drift fixture" "si-deployment-evidence.evidenceTemplateHandoff.requiredEvidenceContracts[7] mismatch"

reset_bundle
edit_json "manifest.json" "data.blockers.find((blocker) => blocker.slug === 'si-deployment-evidence').indexerDeploymentTemplateHandoff.healthInfoTarget.genesisHash = 'GH7ome3EiwEr7tu9JuTh2dpYWBJK3z69Xm1ZE3MEE6JC'"
rewrite_checksums
expect_failure "SI deployment template mainnet genesis target drift fixture" "si-deployment-evidence.indexerDeploymentTemplateHandoff.healthInfoTarget.genesisHash mismatch"

reset_bundle
edit_json "manifest.json" "data.blockers.find((blocker) => blocker.slug === 'si-deployment-evidence').indexerDeploymentTemplateHandoff.healthInfoTarget.latestSlot = 'TODO_ANY_SLOT'"
rewrite_checksums
expect_failure "SI deployment template slot target drift fixture" "si-deployment-evidence.indexerDeploymentTemplateHandoff.healthInfoTarget.latestSlot mismatch"

reset_bundle
edit_json "manifest.json" "data.blockers.find((blocker) => blocker.slug === 'si-deployment-evidence').indexerDeploymentTemplateHandoff.healthInfoTarget.syncedAt = 'TODO_ANY_TIMESTAMP'"
rewrite_checksums
expect_failure "SI deployment template freshness target drift fixture" "si-deployment-evidence.indexerDeploymentTemplateHandoff.healthInfoTarget.syncedAt mismatch"

reset_bundle
edit_json "manifest.json" "data.blockers.find((blocker) => blocker.slug === 'si-deployment-evidence').indexerDeploymentTemplateHandoff.requiredContracts[4] = 'healthInfo.genesisHash may vary by cluster'"
rewrite_checksums
expect_failure "SI deployment template genesis contract drift fixture" "si-deployment-evidence.indexerDeploymentTemplateHandoff.requiredContracts[4] mismatch"

reset_bundle
edit_json "manifest.json" "data.blockers.find((blocker) => blocker.slug === 'si-deployment-evidence').indexerDeploymentTemplateHandoff.requiredContracts[5] = 'healthInfo.latestSlot may be any value'"
rewrite_checksums
expect_failure "SI deployment template slot contract drift fixture" "si-deployment-evidence.indexerDeploymentTemplateHandoff.requiredContracts[5] mismatch"

reset_bundle
edit_json "manifest.json" "data.blockers.find((blocker) => blocker.slug === 'si-deployment-evidence').indexerDeploymentTemplateHandoff.requiredContracts[6] = 'healthInfo.syncedAt may be stale'"
rewrite_checksums
expect_failure "SI deployment template freshness contract drift fixture" "si-deployment-evidence.indexerDeploymentTemplateHandoff.requiredContracts[6] mismatch"

reset_bundle
edit_json "manifest.json" "delete data.blockers.find((blocker) => blocker.slug === 'pi-deployment-evidence').indexerDeploymentTemplateHandoff"
rewrite_checksums
expect_failure "PI deployment template artifact handoff missing fixture" "pi-deployment-evidence.indexerDeploymentTemplateHandoff missing"

reset_bundle
edit_json "manifest.json" "data.blockers.find((blocker) => blocker.slug === 'pi-deployment-evidence').indexerDeploymentTemplateHandoff.templateSha256 = '0000000000000000000000000000000000000000000000000000000000000000'"
rewrite_checksums
expect_failure "PI deployment template artifact checksum mismatch fixture" "pi-deployment-evidence.indexerDeploymentTemplateHandoff.templateSha256 does not match artifact checksum"

reset_bundle
edit_json "manifest.json" "data.artifacts = data.artifacts.filter((artifact) => artifact.path !== 'handoffs/pi-deployment-evidence-template.json')"
rewrite_checksums
expect_failure "PI deployment template artifact manifest missing fixture" "pi-deployment-evidence.indexerDeploymentTemplateHandoff.templateArtifact missing from manifest artifacts"

reset_bundle
edit_json "manifest.json" "data.artifacts.find((artifact) => artifact.path === 'handoffs/pi-deployment-evidence-template.json').sourcePath = data.sourceReportDir + '/pi-deployment-evidence-template-drift.json'"
rewrite_checksums
expect_failure "PI deployment template artifact source path drift fixture" "handoffs/pi-deployment-evidence-template.json.sourcePath must match report artifact path"

reset_bundle
node - "$bundle_dir/handoffs/pi-deployment-evidence-template.json" <<'NODE'
const fs = require('fs')
const file = process.argv[2]
const data = JSON.parse(fs.readFileSync(file, 'utf8'))
data.blockers = data.blockers.filter((blocker) => blocker !== 'live-production-smoke-failing')
fs.writeFileSync(file, JSON.stringify(data, null, 2) + '\n')
NODE
rewrite_checksums
expect_failure "missing PI live-smoke blocker fixture" "handoffs/pi-deployment-evidence-template.json.blockers length mismatch"

reset_bundle
node - "$bundle_dir/handoffs/pi-deployment-evidence-template.json" <<'NODE'
const fs = require('fs')
const file = process.argv[2]
const data = JSON.parse(fs.readFileSync(file, 'utf8'))
data.lastReviewed = '2026-02-31'
fs.writeFileSync(file, JSON.stringify(data, null, 2) + '\n')
NODE
rewrite_checksums
expect_failure "PI deployment template artifact invalid lastReviewed fixture" "handoffs/pi-deployment-evidence-template.json.lastReviewed must be a valid YYYY-MM-DD date"

reset_bundle
node - "$bundle_dir/handoffs/pi-deployment-evidence-template.json" <<'NODE'
const fs = require('fs')
const file = process.argv[2]
const data = JSON.parse(fs.readFileSync(file, 'utf8'))
data.lastReviewed = '2999-01-01'
fs.writeFileSync(file, JSON.stringify(data, null, 2) + '\n')
NODE
rewrite_checksums
expect_failure "PI deployment template artifact future lastReviewed fixture" "handoffs/pi-deployment-evidence-template.json.lastReviewed must not be in the future"

reset_bundle
node - "$bundle_dir/handoffs/pi-deployment-evidence-template.json" <<'NODE'
const fs = require('fs')
const file = process.argv[2]
const data = JSON.parse(fs.readFileSync(file, 'utf8'))
data.deploymentEvidence[0].commit = '0123456789abcdef0123456789abcdef01234567'
fs.writeFileSync(file, JSON.stringify(data, null, 2) + '\n')
NODE
rewrite_checksums
expect_failure "PI deployment template artifact placeholder drift fixture" "handoffs/pi-deployment-evidence-template.json.deploymentEvidence[0].commit placeholder mismatch"

reset_bundle
edit_json "manifest.json" "data.blockers.find((blocker) => blocker.slug === 'pi-deployment-evidence').indexerDeploymentTemplateHandoff.requiredEvidenceFields = data.blockers.find((blocker) => blocker.slug === 'pi-deployment-evidence').indexerDeploymentTemplateHandoff.requiredEvidenceFields.filter((field) => field !== 'soraRpcControls')"
rewrite_checksums
expect_failure "PI deployment SORA RPC required field missing fixture" "pi-deployment-evidence.indexerDeploymentTemplateHandoff.requiredEvidenceFields length mismatch"

reset_bundle
edit_json "manifest.json" "delete data.blockers.find((blocker) => blocker.slug === 'pi-deployment-evidence').indexerDeploymentTemplateHandoff.soraRpcControlsTarget"
rewrite_checksums
expect_failure "PI deployment SORA RPC target missing fixture" "pi-deployment-evidence.indexerDeploymentTemplateHandoff.soraRpcControlsTarget must be an object"

reset_bundle
edit_json "manifest.json" "data.blockers.find((blocker) => blocker.slug === 'pi-deployment-evidence').indexerDeploymentTemplateHandoff.soraRpcControlsTarget.unreviewedTrustOverride = true"
rewrite_checksums
expect_failure "PI deployment SORA RPC target extra key fixture" "unsupported pi-deployment-evidence.indexerDeploymentTemplateHandoff.soraRpcControlsTarget key: unreviewedTrustOverride"

reset_bundle
edit_json "manifest.json" "data.blockers.find((blocker) => blocker.slug === 'pi-deployment-evidence').indexerDeploymentTemplateHandoff.soraRpcControlsTarget.primaryEndpoint = 'wss://ws.mof.sora.org'"
rewrite_checksums
expect_failure "PI deployment public-convenience primary RPC target fixture" "pi-deployment-evidence.indexerDeploymentTemplateHandoff.soraRpcControlsTarget.primaryEndpoint mismatch"

reset_bundle
edit_json "manifest.json" "data.blockers.find((blocker) => blocker.slug === 'pi-deployment-evidence').indexerDeploymentTemplateHandoff.soraRpcControlsTarget.archiveNodeControl = 'same-operator-primary-mirror'"
rewrite_checksums
expect_failure "PI deployment non-independent archive RPC target fixture" "pi-deployment-evidence.indexerDeploymentTemplateHandoff.soraRpcControlsTarget.archiveNodeControl mismatch"

reset_bundle
edit_json "manifest.json" "data.blockers.find((blocker) => blocker.slug === 'pi-deployment-evidence').indexerDeploymentTemplateHandoff.soraRpcControlsTarget.distinctHosts = false"
rewrite_checksums
expect_failure "PI deployment same-host RPC target fixture" "pi-deployment-evidence.indexerDeploymentTemplateHandoff.soraRpcControlsTarget.distinctHosts mismatch"

reset_bundle
edit_json "manifest.json" "data.blockers.find((blocker) => blocker.slug === 'pi-deployment-evidence').indexerDeploymentTemplateHandoff.soraRpcControlsTarget.exactIdentityPreflight = false"
rewrite_checksums
expect_failure "PI deployment disabled identity-preflight target fixture" "pi-deployment-evidence.indexerDeploymentTemplateHandoff.soraRpcControlsTarget.exactIdentityPreflight mismatch"

reset_bundle
edit_json "manifest.json" "data.blockers.find((blocker) => blocker.slug === 'pi-deployment-evidence').indexerDeploymentTemplateHandoff.soraRpcControlsTarget.rawPayloadAgreement = 'height-hash-decoded-events-timestamp-seconds'"
rewrite_checksums
expect_failure "PI deployment weakened raw-payload agreement target fixture" "pi-deployment-evidence.indexerDeploymentTemplateHandoff.soraRpcControlsTarget.rawPayloadAgreement mismatch"

reset_bundle
edit_json "handoffs/pi-deployment-evidence-template.json" "data.deploymentEvidence[0].soraRpcControls.primaryEndpoint = 'wss://ws.mof.sora.org'"
refresh_manifest_artifact "handoffs/pi-deployment-evidence-template.json"
edit_json "manifest.json" "const blocker = data.blockers.find((candidate) => candidate.slug === 'pi-deployment-evidence'); blocker.indexerDeploymentTemplateHandoff.templateSha256 = data.artifacts.find((artifact) => artifact.path === blocker.indexerDeploymentTemplateHandoff.templateArtifact).sha256"
rewrite_checksums
expect_failure "PI deployment template artifact primary RPC tampered fixture" "handoffs/pi-deployment-evidence-template.json.deploymentEvidence[0].soraRpcControls.primaryEndpoint mismatch"

reset_bundle
edit_json "handoffs/pi-deployment-evidence-template.json" "data.deploymentEvidence[0].soraRpcControls.archiveEndpoint = 'wss://mof2.sora.org'"
refresh_manifest_artifact "handoffs/pi-deployment-evidence-template.json"
edit_json "manifest.json" "const blocker = data.blockers.find((candidate) => candidate.slug === 'pi-deployment-evidence'); blocker.indexerDeploymentTemplateHandoff.templateSha256 = data.artifacts.find((artifact) => artifact.path === blocker.indexerDeploymentTemplateHandoff.templateArtifact).sha256"
rewrite_checksums
expect_failure "PI deployment template artifact archive RPC tampered fixture" "handoffs/pi-deployment-evidence-template.json.deploymentEvidence[0].soraRpcControls.archiveEndpoint mismatch"

reset_bundle
edit_json "handoffs/pi-deployment-evidence-template.json" "data.deploymentEvidence[0].soraRpcControls.unreviewedTrustOverride = true"
refresh_manifest_artifact "handoffs/pi-deployment-evidence-template.json"
edit_json "manifest.json" "const blocker = data.blockers.find((candidate) => candidate.slug === 'pi-deployment-evidence'); blocker.indexerDeploymentTemplateHandoff.templateSha256 = data.artifacts.find((artifact) => artifact.path === blocker.indexerDeploymentTemplateHandoff.templateArtifact).sha256"
rewrite_checksums
expect_failure "PI deployment template artifact SORA RPC extra key fixture" "unsupported handoffs/pi-deployment-evidence-template.json.deploymentEvidence[0].soraRpcControls key: unreviewedTrustOverride"

reset_bundle
edit_json "manifest.json" "delete data.blockers.find((blocker) => blocker.slug === 'pi-deployment-evidence').indexerDeploymentTemplateHandoff.tlsEdgeControlsTarget"
rewrite_checksums
expect_failure "PI deployment TLS-edge target missing fixture" "pi-deployment-evidence.indexerDeploymentTemplateHandoff.tlsEdgeControlsTarget must be an object"

reset_bundle
edit_json "manifest.json" "data.blockers.find((blocker) => blocker.slug === 'pi-deployment-evidence').indexerDeploymentTemplateHandoff.tlsEdgeControlsTarget.forwardedClientIpHeaders = 'preserve'"
rewrite_checksums
expect_failure "PI deployment TLS-edge overwrite target weakened fixture" "pi-deployment-evidence.indexerDeploymentTemplateHandoff.tlsEdgeControlsTarget.forwardedClientIpHeaders mismatch"

reset_bundle
edit_json "manifest.json" "data.blockers.find((blocker) => blocker.slug === 'pi-deployment-evidence').indexerDeploymentTemplateHandoff.tlsEdgeControlsTarget.webSocketClientIpLimits.maxConcurrentConnections = 17"
rewrite_checksums
expect_failure "PI deployment TLS-edge connection target tampered fixture" "pi-deployment-evidence.indexerDeploymentTemplateHandoff.tlsEdgeControlsTarget.webSocketClientIpLimits.maxConcurrentConnections mismatch"

reset_bundle
edit_json "handoffs/pi-deployment-evidence-template.json" "data.deploymentEvidence[0].tlsEdgeControls.httpClientIpRateLimit.maxRequests = 601"
refresh_manifest_artifact "handoffs/pi-deployment-evidence-template.json"
edit_json "manifest.json" "const blocker = data.blockers.find((candidate) => candidate.slug === 'pi-deployment-evidence'); blocker.indexerDeploymentTemplateHandoff.templateSha256 = data.artifacts.find((artifact) => artifact.path === blocker.indexerDeploymentTemplateHandoff.templateArtifact).sha256"
rewrite_checksums
expect_failure "PI deployment TLS-edge template artifact tampered fixture" "handoffs/pi-deployment-evidence-template.json.deploymentEvidence[0].tlsEdgeControls.httpClientIpRateLimit.maxRequests mismatch"

reset_bundle
edit_json "manifest.json" "data.blockers.find((blocker) => blocker.slug === 'pi-deployment-evidence').indexerDeploymentTemplateHandoff.healthInfoTarget.genesisHash = '0x0000000000000000000000000000000000000000000000000000000000000001'"
rewrite_checksums
expect_failure "PI deployment health genesis target mismatch fixture" "pi-deployment-evidence.indexerDeploymentTemplateHandoff.healthInfoTarget.genesisHash mismatch"

reset_bundle
edit_json "manifest.json" "data.blockers.find((blocker) => blocker.slug === 'pi-deployment-evidence').indexerDeploymentTemplateHandoff.healthInfoTarget.latestIndexedBlock = 'TODO_NONNEGATIVE_INDEXED_BLOCK'"
rewrite_checksums
expect_failure "PI deployment indexed-block target mismatch fixture" "pi-deployment-evidence.indexerDeploymentTemplateHandoff.healthInfoTarget.latestIndexedBlock mismatch"

reset_bundle
edit_json "manifest.json" "data.blockers.find((blocker) => blocker.slug === 'pi-deployment-evidence').indexerDeploymentTemplateHandoff.healthInfoTarget.latestIndexedBlockHash = 'TODO_ANY_BLOCK_HASH'"
rewrite_checksums
expect_failure "PI deployment indexed-block-hash target mismatch fixture" "pi-deployment-evidence.indexerDeploymentTemplateHandoff.healthInfoTarget.latestIndexedBlockHash mismatch"

reset_bundle
edit_json "manifest.json" "data.blockers.find((blocker) => blocker.slug === 'pi-deployment-evidence').indexerDeploymentTemplateHandoff.healthInfoTarget.latestIndexedAt = 'TODO_UNIX_SECONDS'"
rewrite_checksums
expect_failure "PI deployment indexed-at target mismatch fixture" "pi-deployment-evidence.indexerDeploymentTemplateHandoff.healthInfoTarget.latestIndexedAt mismatch"

reset_bundle
edit_json "handoffs/pi-deployment-evidence-template.json" "data.deploymentEvidence[0].healthInfo.genesisHash = '0x0000000000000000000000000000000000000000000000000000000000000001'"
refresh_manifest_artifact "handoffs/pi-deployment-evidence-template.json"
edit_json "manifest.json" "const blocker = data.blockers.find((candidate) => candidate.slug === 'pi-deployment-evidence'); blocker.indexerDeploymentTemplateHandoff.templateSha256 = data.artifacts.find((artifact) => artifact.path === blocker.indexerDeploymentTemplateHandoff.templateArtifact).sha256"
rewrite_checksums
expect_failure "PI deployment template artifact genesis tampered fixture" "handoffs/pi-deployment-evidence-template.json.deploymentEvidence[0].healthInfo.genesisHash mismatch"

reset_bundle
edit_json "handoffs/pi-deployment-evidence-template.json" "data.deploymentEvidence[0].healthInfo.latestIndexedBlock = 1"
refresh_manifest_artifact "handoffs/pi-deployment-evidence-template.json"
edit_json "manifest.json" "const blocker = data.blockers.find((candidate) => candidate.slug === 'pi-deployment-evidence'); blocker.indexerDeploymentTemplateHandoff.templateSha256 = data.artifacts.find((artifact) => artifact.path === blocker.indexerDeploymentTemplateHandoff.templateArtifact).sha256"
rewrite_checksums
expect_failure "PI deployment template artifact indexed-block placeholder tampered fixture" "handoffs/pi-deployment-evidence-template.json.deploymentEvidence[0].healthInfo.latestIndexedBlock must be a non-empty string"

reset_bundle
edit_json "handoffs/pi-deployment-evidence-template.json" "data.deploymentEvidence[0].healthInfo.latestIndexedBlockHash = '0x1111111111111111111111111111111111111111111111111111111111111111'"
refresh_manifest_artifact "handoffs/pi-deployment-evidence-template.json"
edit_json "manifest.json" "const blocker = data.blockers.find((candidate) => candidate.slug === 'pi-deployment-evidence'); blocker.indexerDeploymentTemplateHandoff.templateSha256 = data.artifacts.find((artifact) => artifact.path === blocker.indexerDeploymentTemplateHandoff.templateArtifact).sha256"
rewrite_checksums
expect_failure "PI deployment template artifact indexed-block-hash placeholder tampered fixture" "handoffs/pi-deployment-evidence-template.json.deploymentEvidence[0].healthInfo.latestIndexedBlockHash mismatch"

reset_bundle
edit_json "handoffs/pi-deployment-evidence-template.json" "data.deploymentEvidence[0].healthInfo.latestIndexedAt = 'TODO_UNBOUNDED_UNIX_SECONDS'"
refresh_manifest_artifact "handoffs/pi-deployment-evidence-template.json"
edit_json "manifest.json" "const blocker = data.blockers.find((candidate) => candidate.slug === 'pi-deployment-evidence'); blocker.indexerDeploymentTemplateHandoff.templateSha256 = data.artifacts.find((artifact) => artifact.path === blocker.indexerDeploymentTemplateHandoff.templateArtifact).sha256"
rewrite_checksums
expect_failure "PI deployment template artifact indexed-at placeholder tampered fixture" "handoffs/pi-deployment-evidence-template.json.deploymentEvidence[0].healthInfo.latestIndexedAt mismatch"

reset_bundle
edit_json "manifest.json" "delete data.blockers.find((blocker) => blocker.slug === 'pi-deployment-evidence').evidenceTemplateHandoff"
rewrite_checksums
expect_failure "PI deployment evidence template handoff missing fixture" "pi-deployment-evidence.evidenceTemplateHandoff missing"

reset_bundle
edit_json "manifest.json" "data.blockers.find((blocker) => blocker.slug === 'pi-deployment-evidence').evidenceTemplateCommands[1] = 'cd ../polkaswap-indexer && bash ../fearless/scripts/run-pinned-yarn.sh generate:deployment-evidence-template --output build/reports/wrong-template.json'"
rewrite_checksums
expect_failure "PI deployment evidence template command mismatch fixture" "pi-deployment-evidence.evidenceTemplateCommands[1] mismatch"

reset_bundle
edit_json "manifest.json" "data.blockers.find((blocker) => blocker.slug === 'pi-deployment-evidence').evidenceTemplateHandoff.readyAuditCommand = 'cd ../polkaswap-indexer && yarn audit:deployment-evidence'"
rewrite_checksums
expect_failure "PI deployment evidence ready audit mismatch fixture" "pi-deployment-evidence.evidenceTemplateHandoff.readyAuditCommand mismatch"

reset_bundle
edit_json "manifest.json" "data.blockers.find((blocker) => blocker.slug === 'pi-deployment-evidence').evidenceTemplateHandoff.requiredEvidenceContracts[1] = 'healthInfo.service may be any GraphQL service'"
rewrite_checksums
expect_failure "PI deployment evidence contract mismatch fixture" "pi-deployment-evidence.evidenceTemplateHandoff.requiredEvidenceContracts[1] mismatch"

reset_bundle
edit_json "manifest.json" "data.blockers.find((blocker) => blocker.slug === 'pi-deployment-evidence').evidenceTemplateHandoff.requiredEvidenceContracts[5] = 'healthInfo.genesisHash may match any SORA network'"
rewrite_checksums
expect_failure "PI deployment evidence genesis contract mismatch fixture" "pi-deployment-evidence.evidenceTemplateHandoff.requiredEvidenceContracts[5] mismatch"

reset_bundle
edit_json "manifest.json" "data.blockers.find((blocker) => blocker.slug === 'pi-deployment-evidence').evidenceTemplateHandoff.requiredEvidenceContracts[6] = 'healthInfo.latestIndexedBlock may be zero'"
rewrite_checksums
expect_failure "PI deployment evidence indexed-block contract mismatch fixture" "pi-deployment-evidence.evidenceTemplateHandoff.requiredEvidenceContracts[6] mismatch"

reset_bundle
edit_json "manifest.json" "data.blockers.find((blocker) => blocker.slug === 'pi-deployment-evidence').evidenceTemplateHandoff.requiredEvidenceContracts[7] = 'healthInfo.latestIndexedBlockHash may be mixed case'"
rewrite_checksums
expect_failure "PI deployment evidence indexed-block-hash contract mismatch fixture" "pi-deployment-evidence.evidenceTemplateHandoff.requiredEvidenceContracts[7] mismatch"

reset_bundle
edit_json "manifest.json" "data.blockers.find((blocker) => blocker.slug === 'pi-deployment-evidence').evidenceTemplateHandoff.requiredEvidenceContracts[8] = 'healthInfo.latestIndexedAt may be stale'"
rewrite_checksums
expect_failure "PI deployment evidence indexed-at contract mismatch fixture" "pi-deployment-evidence.evidenceTemplateHandoff.requiredEvidenceContracts[8] mismatch"

reset_bundle
edit_json "manifest.json" "data.blockers.find((blocker) => blocker.slug === 'pi-deployment-evidence').evidenceTemplateHandoff.requiredEvidenceContracts[9] = 'soraRpcControls may omit reviewed trust fields'"
rewrite_checksums
expect_failure "PI deployment evidence SORA RPC seven-key contract drift fixture" "pi-deployment-evidence.evidenceTemplateHandoff.requiredEvidenceContracts[9] mismatch"

reset_bundle
edit_json "manifest.json" "data.blockers.find((blocker) => blocker.slug === 'pi-deployment-evidence').evidenceTemplateHandoff.requiredEvidenceContracts[10] = 'soraRpcControls.primaryEndpoint may use a public convenience host'"
rewrite_checksums
expect_failure "PI deployment evidence primary RPC contract drift fixture" "pi-deployment-evidence.evidenceTemplateHandoff.requiredEvidenceContracts[10] mismatch"

reset_bundle
edit_json "manifest.json" "data.blockers.find((blocker) => blocker.slug === 'pi-deployment-evidence').evidenceTemplateHandoff.requiredEvidenceContracts[11] = 'soraRpcControls.archiveEndpoint may share the primary host'"
rewrite_checksums
expect_failure "PI deployment evidence archive RPC contract drift fixture" "pi-deployment-evidence.evidenceTemplateHandoff.requiredEvidenceContracts[11] mismatch"

reset_bundle
edit_json "manifest.json" "data.blockers.find((blocker) => blocker.slug === 'pi-deployment-evidence').evidenceTemplateHandoff.requiredEvidenceContracts[12] = 'decoded payload equality is sufficient'"
rewrite_checksums
expect_failure "PI deployment evidence raw-payload contract drift fixture" "pi-deployment-evidence.evidenceTemplateHandoff.requiredEvidenceContracts[12] mismatch"

reset_bundle
edit_json "manifest.json" "data.blockers.find((blocker) => blocker.slug === 'pi-deployment-evidence').indexerDeploymentTemplateHandoff.requiredContracts[9] = 'soraRpcControls may omit reviewed trust fields'"
rewrite_checksums
expect_failure "PI deployment template SORA RPC seven-key contract drift fixture" "pi-deployment-evidence.indexerDeploymentTemplateHandoff.requiredContracts[9] mismatch"

reset_bundle
edit_json "manifest.json" "data.blockers.find((blocker) => blocker.slug === 'pi-deployment-evidence').indexerDeploymentTemplateHandoff.requiredContracts[10] = 'soraRpcControls.primaryEndpoint may use a public convenience host'"
rewrite_checksums
expect_failure "PI deployment template primary RPC contract drift fixture" "pi-deployment-evidence.indexerDeploymentTemplateHandoff.requiredContracts[10] mismatch"

reset_bundle
edit_json "manifest.json" "data.blockers.find((blocker) => blocker.slug === 'pi-deployment-evidence').indexerDeploymentTemplateHandoff.requiredContracts[11] = 'soraRpcControls.archiveEndpoint may share the primary host'"
rewrite_checksums
expect_failure "PI deployment template archive RPC contract drift fixture" "pi-deployment-evidence.indexerDeploymentTemplateHandoff.requiredContracts[11] mismatch"

reset_bundle
edit_json "manifest.json" "data.blockers.find((blocker) => blocker.slug === 'pi-deployment-evidence').indexerDeploymentTemplateHandoff.requiredContracts[12] = 'decoded payload equality is sufficient'"
rewrite_checksums
expect_failure "PI deployment template raw-payload contract drift fixture" "pi-deployment-evidence.indexerDeploymentTemplateHandoff.requiredContracts[12] mismatch"

reset_bundle
edit_json "manifest.json" "delete data.blockers.find((blocker) => blocker.slug === 'android-xcm-production-evidence').xcmProductionEvidenceTemplateHandoff"
rewrite_checksums
expect_failure "Android XCM production evidence template handoff missing fixture" "android-xcm-production-evidence.xcmProductionEvidenceTemplateHandoff missing"

reset_bundle
edit_json "manifest.json" "data.blockers.find((blocker) => blocker.slug === 'android-xcm-production-evidence').xcmProductionEvidenceTemplateHandoff.templateSha256 = '0000000000000000000000000000000000000000000000000000000000000000'"
rewrite_checksums
expect_failure "Android XCM production evidence template checksum mismatch fixture" "android-xcm-production-evidence.xcmProductionEvidenceTemplateHandoff.templateSha256 does not match artifact checksum"

reset_bundle
edit_json "manifest.json" "data.blockers.find((blocker) => blocker.slug === 'android-xcm-production-evidence').xcmProductionEvidenceTemplateHandoff.readyAuditCommand = 'cd fearless-Android-production-consolidated-20260731 && bash scripts/audit-xcm-production-evidence.sh --require-ready'"
rewrite_checksums
expect_failure "Android XCM production evidence stale ready-audit command fixture" "android-xcm-production-evidence.xcmProductionEvidenceTemplateHandoff.readyAuditCommand mismatch"

reset_bundle
edit_json "manifest.json" "data.blockers.find((blocker) => blocker.slug === 'android-xcm-production-evidence').xcmProductionEvidenceTemplateHandoff.requiredContracts.pop()"
rewrite_checksums
expect_failure "Android XCM production evidence live report contract missing fixture" "android-xcm-production-evidence.xcmProductionEvidenceTemplateHandoff.requiredContracts length mismatch"

reset_bundle
edit_json "manifest.json" "data.artifacts = data.artifacts.filter((artifact) => artifact.path !== 'handoffs/android-xcm-production-evidence-template.json')"
rewrite_checksums
expect_failure "Android XCM production evidence template artifact manifest missing fixture" "android-xcm-production-evidence.xcmProductionEvidenceTemplateHandoff.templateArtifact missing from manifest artifacts"

reset_bundle
edit_json "manifest.json" "data.artifacts.find((artifact) => artifact.path === 'handoffs/android-xcm-production-evidence-template.json').sourcePath = data.sourceReportDir + '/android-xcm-production-evidence-template-drift.json'"
rewrite_checksums
expect_failure "Android XCM production evidence template artifact source path drift fixture" "handoffs/android-xcm-production-evidence-template.json.sourcePath must match report artifact path"

reset_bundle
node - "$bundle_dir/handoffs/android-xcm-production-evidence-template.json" <<'NODE'
const fs = require('fs')
const file = process.argv[2]
const data = JSON.parse(fs.readFileSync(file, 'utf8'))
data.evidence[0].androidCommit = '0123456789abcdef0123456789abcdef01234567'
fs.writeFileSync(file, JSON.stringify(data, null, 2) + '\n')
NODE
refresh_manifest_artifact "handoffs/android-xcm-production-evidence-template.json"
rewrite_checksums
expect_failure "Android XCM production evidence template artifact placeholder drift fixture" "handoffs/android-xcm-production-evidence-template.json.evidence[0].androidCommit placeholder mismatch"

reset_bundle
edit_json "handoffs/android-xcm-production-evidence-template.json" "data.instructions[4] = 'Set lastReviewed whenever convenient.'"
refresh_xcm_production_template_artifact_handoff
rewrite_checksums
expect_failure "weakened Android XCM chronology instruction verification fixture" "handoffs/android-xcm-production-evidence-template.json.instructions[4] mismatch"

reset_bundle
edit_json "handoffs/android-xcm-production-evidence-template.json" "data.requiredEvidenceFields = data.requiredEvidenceFields.filter((field) => field !== 'originBlockHash')"
refresh_xcm_production_template_artifact_handoff
rewrite_checksums
expect_failure "Android XCM required evidence field removal verification fixture" "handoffs/android-xcm-production-evidence-template.json.requiredEvidenceFields length mismatch"

reset_bundle
edit_json "handoffs/android-xcm-production-evidence-template.json" "const value = data.requiredEvidenceFields[4]; data.requiredEvidenceFields[4] = data.requiredEvidenceFields[5]; data.requiredEvidenceFields[5] = value"
refresh_xcm_production_template_artifact_handoff
rewrite_checksums
expect_failure "Android XCM required evidence field order verification fixture" "handoffs/android-xcm-production-evidence-template.json.requiredEvidenceFields[4] mismatch"

reset_bundle
edit_json "handoffs/android-xcm-production-evidence-template.json" "data.evidence[0].originFinalized = 'false'"
refresh_xcm_production_template_artifact_handoff
rewrite_checksums
expect_failure "Android XCM boolean placeholder type verification fixture" "handoffs/android-xcm-production-evidence-template.json.evidence[0].originFinalized must be boolean"

reset_bundle
edit_json "handoffs/android-xcm-production-evidence-template.json" "data.evidence[0].destinationChainId = 'c'.repeat(64)"
refresh_xcm_production_template_artifact_handoff
rewrite_checksums
expect_failure "Android XCM same-count template route substitution verification fixture" "handoffs/android-xcm-production-evidence-template.json.evidence[0] does not match candidate required-route manifest order"

reset_bundle
edit_json "handoffs/android-xcm-production-evidence-template.json" "data.evidence.reverse()"
refresh_xcm_production_template_artifact_handoff
rewrite_checksums
expect_failure "Android XCM template generator-order substitution verification fixture" "handoffs/android-xcm-production-evidence-template.json.evidence[0] does not match candidate required-route manifest order"

reset_bundle
edit_json "handoffs/android-xcm-production-evidence-template.json" "delete data.evidence[0].destinationBalanceDelta"
refresh_xcm_production_template_artifact_handoff
rewrite_checksums
expect_failure "Android XCM newly required evidence value removal verification fixture" "handoffs/android-xcm-production-evidence-template.json.evidence[0].destinationBalanceDelta must be a non-empty string"

reset_bundle
edit_json "manifest.json" "delete data.blockers.find((blocker) => blocker.slug === 'android-xcm-production-evidence').xcmRegistryHandoff"
rewrite_checksums
expect_failure "Android XCM registry handoff missing fixture" "android-xcm-production-evidence.xcmRegistryHandoff missing"

reset_bundle
edit_json "manifest.json" "data.blockers.find((blocker) => blocker.slug === 'android-xcm-production-evidence').xcmRegistryHandoff.registryAuditCommand = 'cd fearless-Android-production-consolidated-20260731 && bash scripts/audit-xcm-registry-metadata.sh --require-executable'"
rewrite_checksums
expect_failure "Android XCM registry command mismatch fixture" "android-xcm-production-evidence.xcmRegistryHandoff.registryAuditCommand mismatch"

reset_bundle
edit_json "manifest.json" "data.blockers.find((blocker) => blocker.slug === 'android-xcm-production-evidence').xcmRegistryHandoff.gapReportSha256 = '0000000000000000000000000000000000000000000000000000000000000000'"
rewrite_checksums
expect_failure "Android XCM registry checksum mismatch fixture" "android-xcm-production-evidence.xcmRegistryHandoff.gapReportSha256 does not match artifact checksum"

reset_bundle
edit_json "manifest.json" "data.artifacts = data.artifacts.filter((artifact) => artifact.path !== 'handoffs/android-xcm-registry-gap-report.json')"
rewrite_checksums
expect_failure "Android XCM registry artifact manifest missing fixture" "android-xcm-production-evidence.xcmRegistryHandoff.gapReportArtifact missing from manifest artifacts"

reset_bundle
edit_json "manifest.json" "const handoff = data.blockers.find((blocker) => blocker.slug === 'android-xcm-production-evidence').xcmRegistryHandoff; handoff.remainingDiscoveryOnlyDestinations = 0; handoff.missingExecutableDestinationCount = 0"
rewrite_checksums
expect_failure "Android XCM registry report count mismatch fixture" "android-xcm-production-evidence.xcmRegistryHandoff.remainingDiscoveryOnlyDestinations must match gap report"

reset_bundle
edit_json "manifest.json" "data.blockers.find((blocker) => blocker.slug === 'android-xcm-production-evidence').xcmRegistryHandoff.remainingDiscoveryOnlyRouteAssets = 1"
rewrite_checksums
expect_failure "Android XCM registry route-asset handoff tamper fixture" "android-xcm-production-evidence.xcmRegistryHandoff.remainingDiscoveryOnlyRouteAssets must match gap report"

reset_bundle
edit_json "handoffs/android-xcm-registry-gap-report.json" "data.summary.remainingDiscoveryOnlyRouteAssets = 1"
refresh_xcm_registry_gap_artifact_handoff
rewrite_checksums
expect_failure "Android XCM registry route-asset report count mismatch fixture" "android-xcm-production-evidence.xcmRegistryHandoff.gapReport.summary.remainingDiscoveryOnlyRouteAssets must match the sum of missingExecutableDestinations[].assetSymbols lengths"

reset_bundle
edit_json "manifest.json" "delete data.blockers.find((blocker) => blocker.slug === 'android-xcm-production-evidence').xcmRegistryHandoff.effectiveRegistry"
rewrite_checksums
expect_failure "Android XCM effective-registry handoff missing fixture" "android-xcm-production-evidence.xcmRegistryHandoff.effectiveRegistry must be an object"

reset_bundle
edit_json "manifest.json" "data.artifacts = data.artifacts.filter((artifact) => artifact.path !== 'handoffs/android-xcm-effective-registry-report.json')"
rewrite_checksums
expect_failure "Android XCM effective-registry artifact manifest missing fixture" "android-xcm-production-evidence.xcmRegistryHandoff.effectiveRegistry.reportArtifact missing from manifest artifacts"

reset_bundle
rm "$bundle_dir/handoffs/android-xcm-effective-registry-report.json"
rewrite_checksums
expect_failure "Android XCM effective-registry artifact file missing fixture" "manifest artifact missing: handoffs/android-xcm-effective-registry-report.json"

reset_bundle
edit_json "manifest.json" "data.blockers.find((blocker) => blocker.slug === 'android-xcm-production-evidence').xcmRegistryHandoff.effectiveRegistry.reportSha256 = '0'.repeat(64)"
rewrite_checksums
expect_failure "Android XCM effective-registry handoff checksum mismatch fixture" "android-xcm-production-evidence.xcmRegistryHandoff.effectiveRegistry.reportSha256 does not match artifact checksum"

reset_bundle
edit_json "manifest.json" "data.blockers.find((blocker) => blocker.slug === 'android-xcm-production-evidence').xcmRegistryHandoff.effectiveRegistry.sourceReportPath = 'android-xcm-effective-registry-report-drift.json'"
rewrite_checksums
expect_failure "Android XCM effective-registry source path drift fixture" "android-xcm-production-evidence.xcmRegistryHandoff.effectiveRegistry.sourceReportPath mismatch"

reset_bundle
edit_json "manifest.json" "data.artifacts.find((artifact) => artifact.path === 'handoffs/android-xcm-effective-registry-report.json').sourcePath = data.sourceReportDir + '/android-xcm-effective-registry-report-drift.json'"
rewrite_checksums
expect_failure "Android XCM effective-registry artifact provenance drift fixture" "handoffs/android-xcm-effective-registry-report.json.sourcePath must match report artifact path"

reset_bundle
edit_json "manifest.json" "data.blockers.find((blocker) => blocker.slug === 'android-xcm-production-evidence').xcmRegistryHandoff.effectiveRegistry.auditCommand = 'cd fearless-Android-production-consolidated-20260731 && true'"
rewrite_checksums
expect_failure "Android XCM effective-registry audit command drift fixture" "android-xcm-production-evidence.xcmRegistryHandoff.effectiveRegistry.auditCommand mismatch"

reset_bundle
edit_json "manifest.json" "data.blockers.find((blocker) => blocker.slug === 'android-xcm-production-evidence').xcmRegistryHandoff.effectiveRegistry.counts.effective = 2"
rewrite_checksums
expect_failure "Android XCM effective-registry handoff count drift fixture" "android-xcm-production-evidence.xcmRegistryHandoff.effectiveRegistry.counts.effective must match effective registry report"

reset_bundle
edit_json "manifest.json" "data.blockers.find((blocker) => blocker.slug === 'android-xcm-production-evidence').xcmRegistryHandoff.effectiveRegistry.policy.remoteExecutionTrusted = true"
rewrite_checksums
expect_failure "Android XCM handoff trusts remote execution fixture" "android-xcm-production-evidence.xcmRegistryHandoff.effectiveRegistry.policy.remoteExecutionTrusted mismatch"

reset_bundle
edit_json "manifest.json" "data.blockers.find((blocker) => blocker.slug === 'android-xcm-production-evidence').xcmRegistryHandoff.effectiveRegistry.discoveryRegistry.sha256 = '0'.repeat(64)"
rewrite_checksums
expect_failure "Android XCM handoff discovery digest drift fixture" "android-xcm-production-evidence.xcmRegistryHandoff.effectiveRegistry.discoveryRegistry.sha256 mismatch"

reset_bundle
edit_json "handoffs/android-xcm-effective-registry-report.json" "data.policy.remoteExecutionTrusted = true"
refresh_xcm_effective_artifact_handoff
rewrite_checksums
expect_failure "checksummed Android XCM remote-execution policy tamper fixture" "handoffs/android-xcm-effective-registry-report.json.policy.remoteExecutionTrusted mismatch"

reset_bundle
edit_json "handoffs/android-xcm-effective-registry-report.json" "data.policy.productionTransfersEnabled = true"
refresh_xcm_effective_artifact_handoff
rewrite_checksums
expect_failure "checksummed Android XCM production flag tamper fixture" "handoffs/android-xcm-effective-registry-report.json.policy.productionTransfersEnabled mismatch"

reset_bundle
edit_json "handoffs/android-xcm-effective-registry-report.json" "data.policy.runtimeDiscoveryRequiresSuccessfulProcessSync = false"
refresh_xcm_effective_artifact_handoff
rewrite_checksums
expect_failure "checksummed Android XCM process-sync bypass fixture" "handoffs/android-xcm-effective-registry-report.json.policy.runtimeDiscoveryRequiresSuccessfulProcessSync mismatch"

reset_bundle
edit_json "handoffs/android-xcm-effective-registry-report.json" "data.mode = 'bundled'"
refresh_xcm_effective_artifact_handoff
rewrite_checksums
expect_failure "checksummed Android XCM live mode tamper fixture" "handoffs/android-xcm-effective-registry-report.json.mode must be discovery when runLive=true"

reset_bundle
edit_json "handoffs/android-xcm-effective-registry-report.json" "data.inputs.discoveryRegistry.sha256 = 'invalid'"
refresh_xcm_effective_artifact_handoff
rewrite_checksums
expect_failure "checksummed Android XCM discovery hash tamper fixture" "handoffs/android-xcm-effective-registry-report.json.inputs.discoveryRegistry.sha256 must be lowercase SHA-256"

reset_bundle
edit_json "handoffs/android-xcm-effective-registry-report.json" "data.routes.push(JSON.parse(JSON.stringify(data.routes[0])))"
refresh_xcm_effective_artifact_handoff
rewrite_checksums
expect_failure "checksummed Android XCM duplicate route fixture" "handoffs/android-xcm-effective-registry-report.json.routes contains duplicate route"

reset_bundle
edit_json "handoffs/android-xcm-effective-registry-report.json" "data.routes.reverse()"
refresh_xcm_effective_artifact_handoff
rewrite_checksums
expect_failure "checksummed Android XCM route order fixture" "handoffs/android-xcm-effective-registry-report.json.routes must use deterministic route order"

reset_bundle
edit_json "handoffs/android-xcm-effective-registry-report.json" "data.routes[0].assetSymbol = 'ADA'"
refresh_xcm_effective_artifact_handoff
rewrite_checksums
expect_failure "checksummed Android XCM same-count effective route substitution fixture" "handoffs/android-xcm-effective-registry-report.json.routes[0] does not match candidate approved-route manifest"

reset_bundle
edit_json "handoffs/android-xcm-effective-registry-report.json" "data.routes[1].reasons = ['attacker-reason']; data.missing[0].reasons = ['attacker-reason']"
refresh_xcm_effective_artifact_handoff
rewrite_checksums
expect_failure "checksummed Android XCM reason drift fixture" "handoffs/android-xcm-effective-registry-report.json.routes[1].reasons[0] unsupported"

reset_bundle
edit_json "handoffs/android-xcm-effective-registry-report.json" "data.missing = []"
refresh_xcm_effective_artifact_handoff
rewrite_checksums
expect_failure "checksummed Android XCM missing-set drift fixture" "handoffs/android-xcm-effective-registry-report.json.missing must match ineffective routes"

reset_bundle
edit_json "handoffs/android-xcm-effective-registry-report.json" "data.extra = []"
refresh_xcm_effective_artifact_handoff
rewrite_checksums
expect_failure "checksummed Android XCM extra-set drift fixture" "handoffs/android-xcm-effective-registry-report.json.summary.extra must match extra length"

reset_bundle
edit_json "handoffs/android-xcm-effective-registry-report.json" "data.routes[0].productionExecutable = true; data.summary.productionExecutable = 1"
refresh_xcm_effective_artifact_handoff
rewrite_checksums
expect_failure "checksummed Android XCM production-executable tamper fixture" "handoffs/android-xcm-effective-registry-report.json.routes[0].productionExecutable must be false while production transfers are disabled"

reset_bundle
printf '%s\n' '# stale after bundle export' >> "$workspace_dir/fearless-Android-production-consolidated-20260731/runtime/src/main/assets/local_chains.json"
rewrite_checksums
expect_failure "Android XCM stale workspace source fixture" "handoffs/android-xcm-effective-registry-report.json.inputs.bundledRegistry.byteLength does not match workspace source"

reset_bundle
rm "$workspace_dir/fearless-Android-production-consolidated-20260731/runtime/src/main/assets/local_chains.json"
expect_failure "Android XCM missing candidate source fixture" "handoffs/android-xcm-effective-registry-report.json.inputs.bundledRegistry workspace source missing"

reset_bundle
edit_json "handoffs/android-xcm-effective-registry-report.json" "data.inputs.requiredRoutes.sha256 = '0'.repeat(64)"
refresh_xcm_effective_artifact_handoff
rewrite_checksums
expect_failure "checksummed Android XCM stale source digest fixture" "handoffs/android-xcm-effective-registry-report.json.inputs.requiredRoutes.sha256 does not match workspace source"

reset_non_live_bundle
expect_success "skip-live Android XCM bundled report verification"
node - "$bundle_dir/manifest.json" <<'NODE'
const fs = require('fs')
const manifest = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'))
const effective = manifest.blockers.find((blocker) => blocker.slug === 'android-xcm-production-evidence')?.xcmRegistryHandoff?.effectiveRegistry
if (manifest.runLive !== false || manifest.sourcePublicationHandoff !== null) throw new Error('skip-live manifest contract mismatch')
if (effective?.mode !== 'bundled' || effective?.discoveryRegistry !== null || effective?.counts?.productionExecutable !== 0) throw new Error('skip-live effective-registry contract mismatch')
NODE

reset_non_live_bundle
edit_json "handoffs/android-xcm-effective-registry-report.json" "data.mode = 'discovery'"
refresh_xcm_effective_artifact_handoff
rewrite_checksums
expect_failure "skip-live Android XCM discovery mode tamper fixture" "handoffs/android-xcm-effective-registry-report.json.mode must be bundled when runLive=false"

reset_bundle
edit_json "manifest.json" "delete data.blockers.find((blocker) => blocker.slug === 'passkey-production-smoke').liveServiceHandoff.routePaths"
rewrite_checksums
expect_failure "passkey smoke route handoff missing fixture" "passkey-production-smoke.liveServiceHandoff keys mismatch"

reset_bundle
edit_json "manifest.json" "data.blockers.find((blocker) => blocker.slug === 'passkey-production-smoke').liveServiceHandoff.routePaths[1] = '/api/passkey-backup/v1/registration/start'"
rewrite_checksums
expect_failure "passkey smoke route handoff drift fixture" "passkey-production-smoke.liveServiceHandoff.routePaths[1] mismatch"

reset_bundle
edit_json "manifest.json" "data.blockers.find((blocker) => blocker.slug === 'passkey-production-smoke').liveServiceHandoff.verificationCommand = 'cd services/passkey-backup-challenge-service && npm run smoke:production'"
rewrite_checksums
expect_failure "passkey smoke command handoff mismatch fixture" "passkey-production-smoke.liveServiceHandoff.verificationCommand mismatch"

reset_bundle
edit_json "manifest.json" "data.blockers.find((blocker) => blocker.slug === 'passkey-production-smoke').recommendedAction = 'Deploy DNS and run the smoke without provisioning its grant helper.'"
rewrite_checksums
expect_failure "passkey smoke recommended action missing executable grant helper fixture" "passkey-production-smoke.recommendedAction mismatch"

reset_bundle
edit_json "manifest.json" "data.blockers.find((blocker) => blocker.slug === 'passkey-production-smoke').externalPrerequisite = 'DNS, TLS, and routing only.'"
rewrite_checksums
expect_failure "passkey smoke external prerequisite missing executable grant helper fixture" "passkey-production-smoke.externalPrerequisite mismatch"

reset_bundle
edit_json "manifest.json" "data.blockers.find((blocker) => blocker.slug === 'passkey-production-smoke').liveServiceHandoff.urlPolicy.query = 'allowed'"
rewrite_checksums
expect_failure "passkey smoke URL query policy mismatch fixture" "passkey-production-smoke.liveServiceHandoff.urlPolicy.query mismatch"

reset_bundle
edit_json "manifest.json" "delete data.blockers.find((blocker) => blocker.slug === 'iroha-release-readiness').liveServiceHandoff"
rewrite_checksums
expect_failure "Nexus live service handoff missing fixture" "iroha-release-readiness.liveServiceHandoff missing"

reset_bundle
edit_json "manifest.json" "data.blockers.find((blocker) => blocker.slug === 'iroha-release-readiness').liveServiceHandoff.verificationCommand = 'IROHA_NEXUS_LIVE_HEALTH=1 bash scripts/audit-iroha-release-readiness.sh'"
rewrite_checksums
expect_failure "Nexus live service handoff command mismatch fixture" "iroha-release-readiness.liveServiceHandoff.verificationCommand mismatch"

reset_bundle
edit_json "manifest.json" "data.blockers.find((blocker) => blocker.slug === 'iroha-release-readiness').liveServiceHandoff.urlPolicy.allowedProtocols[0] = 'http'"
rewrite_checksums
expect_failure "Nexus live service URL protocol policy mismatch fixture" "iroha-release-readiness.liveServiceHandoff.urlPolicy.allowedProtocols[0] mismatch"

reset_bundle
edit_json "manifest.json" "data.blockers.find((blocker) => blocker.slug === 'iroha-release-readiness').liveServiceHandoff.expectedContracts[5] = 'nexus.routing_policy may use arbitrary routes'"
rewrite_checksums
expect_failure "Nexus live service routing contract mismatch fixture" "iroha-release-readiness.liveServiceHandoff.expectedContracts[5] mismatch"

reset_bundle
edit_json "manifest.json" "data.blockers.find((blocker) => blocker.slug === 'iroha-release-readiness').liveServiceHandoff.expectedContracts[6] = 'dataspace_catalog is optional'"
rewrite_checksums
expect_failure "Nexus live service dataspace contract mismatch fixture" "iroha-release-readiness.liveServiceHandoff.expectedContracts[6] mismatch"

reset_bundle
edit_json "manifest.json" "delete data.blockers.find((blocker) => blocker.slug === 'si-production-smoke').liveServiceHandoff"
rewrite_checksums
expect_failure "live service handoff missing fixture" "si-production-smoke.liveServiceHandoff missing"

reset_bundle
edit_json "manifest.json" "data.blockers.find((blocker) => blocker.slug === 'si-production-smoke').liveServiceHandoff.expectedContracts[1] = 'health.lastMasterSeqno present'"
rewrite_checksums
expect_failure "live service handoff contract mismatch fixture" "si-production-smoke.liveServiceHandoff.expectedContracts[1] mismatch"

reset_bundle
edit_json "manifest.json" "data.blockers.find((blocker) => blocker.slug === 'si-production-smoke').liveServiceHandoff.verificationCommand = 'cd ../solswap-indexer && npm run smoke:production'"
rewrite_checksums
expect_failure "live service handoff command mismatch fixture" "si-production-smoke.liveServiceHandoff.verificationCommand mismatch"

reset_bundle
edit_json "manifest.json" "data.blockers.find((blocker) => blocker.slug === 'si-production-smoke').liveServiceHandoff.urlPolicy.fragment = 'allowed'"
rewrite_checksums
expect_failure "SI live service fragment URL policy mismatch fixture" "si-production-smoke.liveServiceHandoff.urlPolicy.fragment mismatch"

reset_bundle
edit_json "manifest.json" "delete data.blockers.find((blocker) => blocker.slug === 'ti-production-smoke').liveServiceHandoff"
rewrite_checksums
expect_failure "TI live service handoff missing fixture" "ti-production-smoke.liveServiceHandoff missing"

reset_bundle
edit_json "manifest.json" "data.blockers.find((blocker) => blocker.slug === 'ti-production-smoke').liveServiceHandoff.baseUrl = 'https://ti.soramitsu.io/graphql'"
rewrite_checksums
expect_failure "TI live service handoff URL mismatch fixture" "ti-production-smoke.liveServiceHandoff.baseUrl mismatch"

reset_bundle
edit_json "manifest.json" "data.blockers.find((blocker) => blocker.slug === 'ti-production-smoke').liveServiceHandoff.urlPolicy.credentials = 'allowed'"
rewrite_checksums
expect_failure "TI live service credential URL policy mismatch fixture" "ti-production-smoke.liveServiceHandoff.urlPolicy.credentials mismatch"

reset_bundle
edit_json "manifest.json" "data.blockers.find((blocker) => blocker.slug === 'ti-production-smoke').liveServiceHandoff.expectedContracts[4] = 'health.lastMasterSeqno absent'"
rewrite_checksums
expect_failure "TI live service handoff contract mismatch fixture" "ti-production-smoke.liveServiceHandoff.expectedContracts[4] mismatch"

reset_bundle
edit_json "manifest.json" "data.blockers.find((blocker) => blocker.slug === 'ti-production-smoke').liveServiceHandoff.verificationCommand = 'cd ../ton-indexer && npm run smoke:production'"
rewrite_checksums
expect_failure "TI live service handoff command mismatch fixture" "ti-production-smoke.liveServiceHandoff.verificationCommand mismatch"

reset_bundle
edit_json "manifest.json" "delete data.blockers.find((blocker) => blocker.slug === 'pi-production-smoke').liveServiceHandoff"
rewrite_checksums
expect_failure "PI live service handoff missing fixture" "pi-production-smoke.liveServiceHandoff missing"

reset_bundle
edit_json "manifest.json" "data.blockers.find((blocker) => blocker.slug === 'pi-production-smoke').liveServiceHandoff.baseUrl = 'https://pi.soramitsu.io'"
rewrite_checksums
expect_failure "PI live service handoff URL mismatch fixture" "pi-production-smoke.liveServiceHandoff.baseUrl mismatch"

reset_bundle
edit_json "manifest.json" "data.blockers.find((blocker) => blocker.slug === 'pi-production-smoke').liveServiceHandoff.urlPolicy.canonicalInput = 'operator may append query strings'"
rewrite_checksums
expect_failure "PI live service canonical URL policy mismatch fixture" "pi-production-smoke.liveServiceHandoff.urlPolicy.canonicalInput mismatch"

reset_bundle
edit_json "manifest.json" "data.blockers.find((blocker) => blocker.slug === 'pi-production-smoke').liveServiceHandoff.expectedContracts[2] = 'health.serviceId=wrong'"
rewrite_checksums
expect_failure "PI live service handoff contract mismatch fixture" "pi-production-smoke.liveServiceHandoff.expectedContracts[2] mismatch"

reset_bundle
edit_json "manifest.json" "data.blockers.find((blocker) => blocker.slug === 'pi-production-smoke').liveServiceHandoff.expectedContracts[9] = 'health.genesisHash may match any SORA network'"
rewrite_checksums
expect_failure "PI live service exact genesis contract mismatch fixture" "pi-production-smoke.liveServiceHandoff.expectedContracts[9] mismatch"

reset_bundle
edit_json "manifest.json" "data.blockers.find((blocker) => blocker.slug === 'pi-production-smoke').liveServiceHandoff.expectedContracts[10] = 'health.latestIndexedBlock is nonnegative'"
rewrite_checksums
expect_failure "PI live service indexed-block contract mismatch fixture" "pi-production-smoke.liveServiceHandoff.expectedContracts[10] mismatch"

reset_bundle
edit_json "manifest.json" "data.blockers.find((blocker) => blocker.slug === 'pi-production-smoke').liveServiceHandoff.expectedContracts[11] = 'health.latestIndexedBlockHash is arbitrary text'"
rewrite_checksums
expect_failure "PI live service indexed-block-hash contract mismatch fixture" "pi-production-smoke.liveServiceHandoff.expectedContracts[11] mismatch"

reset_bundle
edit_json "manifest.json" "data.blockers.find((blocker) => blocker.slug === 'pi-production-smoke').liveServiceHandoff.expectedContracts[12] = 'health.latestIndexedAt may be stale'"
rewrite_checksums
expect_failure "PI live service indexed-at contract mismatch fixture" "pi-production-smoke.liveServiceHandoff.expectedContracts[12] mismatch"

reset_bundle
edit_json "manifest.json" "data.blockers.find((blocker) => blocker.slug === 'pi-production-smoke').liveServiceHandoff.expectedContracts[13] = 'worker chainIdentity update is optional'"
rewrite_checksums
expect_failure "PI live service chain-identity contract mismatch fixture" "pi-production-smoke.liveServiceHandoff.expectedContracts[13] mismatch"

reset_bundle
edit_json "manifest.json" "data.blockers.find((blocker) => blocker.slug === 'pi-production-smoke').liveServiceHandoff.expectedContracts[14] = 'worker chainState need not match health'"
rewrite_checksums
expect_failure "PI live service chain-state contract mismatch fixture" "pi-production-smoke.liveServiceHandoff.expectedContracts[14] mismatch"

reset_bundle
edit_json "manifest.json" "data.blockers.find((blocker) => blocker.slug === 'pi-production-smoke').liveServiceHandoff.expectedContracts[15] = 'worker BLOCK snapshot need not match health'"
rewrite_checksums
expect_failure "PI live service BLOCK snapshot contract mismatch fixture" "pi-production-smoke.liveServiceHandoff.expectedContracts[15] mismatch"

reset_bundle
edit_json "manifest.json" "data.blockers.find((blocker) => blocker.slug === 'pi-production-smoke').liveServiceHandoff.verificationCommand = 'cd ../polkaswap-indexer && npm run smoke:production'"
rewrite_checksums
expect_failure "PI live service handoff command mismatch fixture" "pi-production-smoke.liveServiceHandoff.verificationCommand mismatch"

reset_bundle
edit_json "manifest.json" "data.blockers.find((blocker) => blocker.slug === 'pi-deployment-evidence').verificationCommand = 'cd ../polkaswap-indexer && yarn audit:deployment-evidence --require-ready'"
rewrite_checksums
expect_failure "bare PI deployment verification command fixture" "pi-deployment-evidence.verificationCommand mismatch"

reset_bundle
edit_json "manifest.json" "data.blockers.find((blocker) => blocker.slug === 'pi-production-smoke').verificationCommand = 'cd ../polkaswap-indexer && POLKASWAP_INDEXER_BASE_URL=https://pi.soramitsu.io/graphql yarn smoke:production'"
rewrite_checksums
expect_failure "bare PI smoke verification command fixture" "pi-production-smoke.verificationCommand mismatch"

reset_bundle
edit_json "manifest.json" "data.blockers.find((blocker) => blocker.slug === 'release-pr-readiness').outdatedReviewThreadResolution.threadCount = 3"
rewrite_checksums
expect_failure "review-thread handoff count mismatch fixture" "release-pr-readiness.outdatedReviewThreadResolution.threads length must match threadCount"

reset_bundle
edit_json "manifest.json" "data.blockers.find((blocker) => blocker.slug === 'release-pr-readiness').outdatedReviewThreadResolution.threads[0].id = 'bad-thread-id'"
rewrite_checksums
expect_failure "review-thread handoff malformed id fixture" "release-pr-readiness.outdatedReviewThreadResolution.threads[0].id has unsupported format"

reset_bundle
edit_json "manifest.json" "delete data.blockers.find((blocker) => blocker.slug === 'release-pr-readiness').releasePrStatusReportHandoff"
rewrite_checksums
expect_failure "release PR status report handoff missing fixture" "release-pr-readiness.releasePrStatusReportHandoff missing"

reset_bundle
edit_json "manifest.json" "data.blockers.find((blocker) => blocker.slug === 'release-pr-readiness').releasePrStatusReportHandoff.reportSha256 = '0000000000000000000000000000000000000000000000000000000000000000'"
rewrite_checksums
expect_failure "release PR status report checksum mismatch fixture" "release-pr-readiness.releasePrStatusReportHandoff.reportSha256 does not match artifact checksum"

reset_bundle
edit_json "manifest.json" "data.artifacts = data.artifacts.filter((artifact) => artifact.path !== 'handoffs/release-pr-readiness-report.json')"
rewrite_checksums
expect_failure "release PR status report artifact manifest missing fixture" "release-pr-readiness.releasePrStatusReportHandoff.reportArtifact missing from manifest artifacts"

reset_bundle
edit_json "manifest.json" "const handoff = data.blockers.find((blocker) => blocker.slug === 'release-pr-readiness').releasePrStatusReportHandoff; handoff.sourceReportPath = handoff.sourceReportPath.replace('release-pr-readiness-report.json', 'summary.json')"
rewrite_checksums
expect_failure "release PR status report source path mismatch fixture" "release-pr-readiness.releasePrStatusReportHandoff.sourceReportPath must match report artifact sourcePath"

reset_bundle
edit_json "manifest.json" "data.blockers.find((blocker) => blocker.slug === 'release-pr-readiness').releasePrStatusReportHandoff.blockedPrs[0].pr = '9999'"
rewrite_checksums
expect_failure "release PR status report blocked PR mismatch fixture" "release-pr-readiness.releasePrStatusReportHandoff.blockedPrs[0].url mismatch"

reset_bundle
edit_json "manifest.json" "data.blockers.find((blocker) => blocker.slug === 'release-pr-readiness').releasePrStatusReportHandoff.blockedPrs.reverse()"
rewrite_checksums
expect_failure "release PR status report blocked PR order fixture" "release-pr-readiness.releasePrStatusReportHandoff.blockedPrs[0] must match report failure order"

reset_bundle
edit_json "manifest.json" "data.blockers.find((blocker) => blocker.slug === 'release-pr-readiness').releasePrStatusReportHandoff.blockedPrs[0].reviewDecision = 'APPROVED'"
rewrite_checksums
expect_failure "release PR status report blocked PR review-decision fixture" "release-pr-readiness.releasePrStatusReportHandoff.blockedPrs[0].reviewDecision must match report"

reset_bundle
edit_json "manifest.json" "data.blockers.find((blocker) => blocker.slug === 'release-pr-readiness').releasePrStatusReportHandoff.blockedPrs[0].mergeStateStatus = 'CLEAN'"
rewrite_checksums
expect_failure "release PR status report blocked PR merge-state fixture" "release-pr-readiness.releasePrStatusReportHandoff.blockedPrs[0].mergeStateStatus must match report"

reset_bundle
edit_json "manifest.json" "data.blockers.find((blocker) => blocker.slug === 'release-pr-readiness').releasePrStatusReportHandoff.blockedPrs[0].configLine = 999"
rewrite_checksums
expect_failure "release PR status report blocked PR config-line fixture" "release-pr-readiness.releasePrStatusReportHandoff.blockedPrs[0].configLine must match report"

reset_bundle
edit_json "manifest.json" "data.blockers.find((blocker) => blocker.slug === 'release-pr-readiness').releasePrStatusReportHandoff.blockedPrs[0].head = 'codex/wrong-release-head'"
rewrite_checksums
expect_failure "release PR status report blocked PR head fixture" "release-pr-readiness.releasePrStatusReportHandoff.blockedPrs[0].head must match report"

reset_bundle
edit_json "manifest.json" "data.blockers.find((blocker) => blocker.slug === 'release-pr-readiness').releasePrStatusReportHandoff.blockedPrs[0].base = 'main'"
rewrite_checksums
expect_failure "release PR status report blocked PR base fixture" "release-pr-readiness.releasePrStatusReportHandoff.blockedPrs[0].base must match report"

reset_bundle
edit_json "manifest.json" "data.blockers.find((blocker) => blocker.slug === 'release-pr-readiness').releasePrStatusReportHandoff.blockedPrs[0].requiredState = 'open'"
rewrite_checksums
expect_failure "release PR status report blocked PR required-state fixture" "release-pr-readiness.releasePrStatusReportHandoff.blockedPrs[0].requiredState must match report"

reset_bundle
edit_json "manifest.json" "data.blockers.find((blocker) => blocker.slug === 'release-pr-readiness').releasePrStatusReportHandoff.blockedPrs[0].requiredChecks = ['validate']"
rewrite_checksums
expect_failure "release PR status report blocked PR required-checks fixture" "release-pr-readiness.releasePrStatusReportHandoff.blockedPrs[0].requiredChecks length must match report"

reset_bundle
edit_json "handoffs/release-pr-readiness-report.json" "data.checkedCount = data.totals.total - 1"
refresh_manifest_artifact "handoffs/release-pr-readiness-report.json"
rewrite_checksums
expect_failure "release PR status report checked-count fixture" "handoffs/release-pr-readiness-report.json.checkedCount must match totals.total"

reset_bundle
edit_json "handoffs/release-pr-readiness-report.json" "data.configFile = 'config/release-readiness-prs.tsv'"
refresh_manifest_artifact "handoffs/release-pr-readiness-report.json"
rewrite_checksums
expect_failure "release PR status report relative config-file fixture" "handoffs/release-pr-readiness-report.json.configFile must be an absolute normalized path"

reset_bundle
edit_json "handoffs/release-pr-readiness-report.json" "data.configFile = '$workspace_dir/config/release-readiness-prs-drift.tsv'"
refresh_manifest_artifact "handoffs/release-pr-readiness-report.json"
rewrite_checksums
expect_failure "release PR status report wrong config-file fixture" "handoffs/release-pr-readiness-report.json.configFile must match config/release-readiness-prs.tsv"

reset_bundle
edit_json "handoffs/release-pr-readiness-report.json" "data.requirements[0].head = 'codex/wrong-release-head'"
refresh_manifest_artifact "handoffs/release-pr-readiness-report.json"
rewrite_checksums
expect_failure "release PR status report config-row head fixture" "handoffs/release-pr-readiness-report.json.requirements[0].head must match config/release-readiness-prs.tsv line 6"

reset_bundle
edit_json "handoffs/release-pr-readiness-report.json" "data.requirements[0].requiredChecks = ['validate']"
refresh_manifest_artifact "handoffs/release-pr-readiness-report.json"
rewrite_checksums
expect_failure "release PR status report config-row required-checks fixture" "handoffs/release-pr-readiness-report.json.requirements[0].requiredChecks length must match config/release-readiness-prs.tsv line 6"

reset_bundle
edit_json "handoffs/release-pr-readiness-report.json" "const swapped = data.requirements[1]; data.requirements[1] = data.requirements[2]; data.requirements[2] = swapped; data.failures = data.requirements.filter((requirement) => requirement.status === 'failed').map((requirement) => requirement.message)"
refresh_manifest_artifact "handoffs/release-pr-readiness-report.json"
rewrite_checksums
expect_failure "release PR status report config-row order fixture" "handoffs/release-pr-readiness-report.json.requirements[2].configLine must match config/release-readiness-prs.tsv order"

reset_bundle
edit_json "handoffs/release-pr-readiness-report.json" "data.requirements.splice(1, 1); data.checkedCount -= 1; data.totals.failed -= 1; data.totals.total -= 1; data.failures = data.requirements.filter((requirement) => requirement.status === 'failed').map((requirement) => requirement.message)"
refresh_manifest_artifact "handoffs/release-pr-readiness-report.json"
rewrite_checksums
expect_failure "release PR status report config coverage fixture" "handoffs/release-pr-readiness-report.json.requirements length must match config/release-readiness-prs.tsv"

reset_bundle
edit_json "handoffs/release-pr-readiness-report.json" "data.generatedAt = '2026-06-28 00:00:00'"
refresh_manifest_artifact "handoffs/release-pr-readiness-report.json"
rewrite_checksums
expect_failure "release PR status report non-UTC timestamp fixture" "handoffs/release-pr-readiness-report.json.generatedAt must be an ISO-8601 UTC timestamp"

reset_bundle
edit_json "handoffs/release-pr-readiness-report.json" "data.generatedAt = '2099-01-01T00:06:00.000Z'"
refresh_manifest_artifact "handoffs/release-pr-readiness-report.json"
rewrite_checksums
expect_failure_at_time "release PR status report future timestamp fixture" "2099-01-01T00:00:00Z" "handoffs/release-pr-readiness-report.json.generatedAt is in the future"

reset_bundle
edit_json "handoffs/release-pr-readiness-report.json" "data.requirements[0].reviewDecision = 'APPROVED'"
refresh_manifest_artifact "handoffs/release-pr-readiness-report.json"
rewrite_checksums
expect_failure "release PR status report review-decision diagnostic fixture" "handoffs/release-pr-readiness-report.json.requirements[0].reviewDecision must match message diagnostic"

reset_bundle
edit_json "handoffs/release-pr-readiness-report.json" "data.requirements[0].mergeStateStatus = 'CLEAN'"
refresh_manifest_artifact "handoffs/release-pr-readiness-report.json"
rewrite_checksums
expect_failure "release PR status report merge-state diagnostic fixture" "handoffs/release-pr-readiness-report.json.requirements[0].mergeStateStatus must match message diagnostic"

reset_bundle
edit_json "handoffs/release-pr-readiness-report.json" "data.requirements[0].isDraft = true"
refresh_manifest_artifact "handoffs/release-pr-readiness-report.json"
rewrite_checksums
expect_failure "release PR status report draft diagnostic fixture" "handoffs/release-pr-readiness-report.json.requirements[0].isDraft must match message diagnostic"

reset_bundle
edit_json "handoffs/release-pr-readiness-report.json" "data.requirements[0].message = data.requirements[0].message.replace('soramitsu/fearless-wallet-web#1061', 'soramitsu/fearless-wallet-web#9999'); data.failures[0] = data.requirements[0].message"
refresh_manifest_artifact "handoffs/release-pr-readiness-report.json"
rewrite_checksums
expect_failure "release PR status report message PR reference fixture" "handoffs/release-pr-readiness-report.json.requirements[0].message must start with PR reference"

reset_bundle
edit_json "handoffs/release-pr-readiness-report.json" "data.requirements[0].message = data.requirements[0].message.replace('https://github.com/soramitsu/fearless-wallet-web/pull/1061', 'https://github.com/soramitsu/fearless-wallet-web/pull/9999'); data.failures[0] = data.requirements[0].message"
refresh_manifest_artifact "handoffs/release-pr-readiness-report.json"
rewrite_checksums
expect_failure "release PR status report message URL fixture" "handoffs/release-pr-readiness-report.json.requirements[0].message must include PR URL"

reset_bundle
edit_json "handoffs/release-pr-readiness-report.json" "delete data.requirements[0].pr"
refresh_manifest_artifact "handoffs/release-pr-readiness-report.json"
rewrite_checksums
expect_failure "release PR status report missing structured PR fixture" "handoffs/release-pr-readiness-report.json.requirements[0].pr required when message contains PR reference"

reset_bundle
edit_json "handoffs/release-pr-readiness-report.json" "data.requirements[1].approvalCount = 99"
refresh_manifest_artifact "handoffs/release-pr-readiness-report.json"
rewrite_checksums
expect_failure "release PR status report approval-count diagnostic fixture" "handoffs/release-pr-readiness-report.json.requirements[1].approvalCount must match message diagnostic"

reset_bundle
edit_json "handoffs/release-pr-readiness-report.json" "const requirement = data.requirements[1]; requirement.currentHeadApprovalCount = 2; requirement.message = requirement.message.replace('currentHeadApprovalCount=1', 'currentHeadApprovalCount=2'); data.failures[1] = requirement.message"
refresh_manifest_artifact "handoffs/release-pr-readiness-report.json"
rewrite_checksums
expect_failure "release PR status report current-head semantic fixture" "handoffs/release-pr-readiness-report.json.requirements[1].currentHeadApprovalCount must not exceed approvalCount"

reset_bundle
edit_json "handoffs/release-pr-readiness-report.json" "const requirement = data.requirements[1]; delete requirement.approvalCount; delete requirement.currentHeadApprovalCount; delete requirement.latestApprovalCommit; delete requirement.currentApprovalNotEligible; requirement.message = requirement.message.replace(/ approvalCount=1 currentHeadApprovalCount=1 latestApprovalCommit=[0-9a-f]{40} currentApprovalNotEligible=true/, ''); data.failures[1] = requirement.message"
refresh_manifest_artifact "handoffs/release-pr-readiness-report.json"
rewrite_checksums
expect_failure "release PR status report missing approval diagnostics fixture" "handoffs/release-pr-readiness-report.json.requirements[1].approvalCount required when eligibleReviewerApprovalRequired is true"

reset_bundle
edit_json "handoffs/release-pr-readiness-report.json" "data.requirements[0].unresolvedReviewThreads = 99"
refresh_manifest_artifact "handoffs/release-pr-readiness-report.json"
rewrite_checksums
expect_failure "release PR status report review-thread count diagnostic fixture" "handoffs/release-pr-readiness-report.json.requirements[0].unresolvedReviewThreads must match message diagnostic"

reset_bundle
edit_json "handoffs/release-pr-readiness-report.json" "const requirement = data.requirements[0]; requirement.currentUnresolvedReviewThreads = 1; requirement.message = requirement.message.replace('currentUnresolvedReviewThreads=0', 'currentUnresolvedReviewThreads=1'); data.failures[0] = requirement.message"
refresh_manifest_artifact "handoffs/release-pr-readiness-report.json"
rewrite_checksums
expect_failure "release PR status report review-thread semantic fixture" "handoffs/release-pr-readiness-report.json.requirements[0].currentUnresolvedReviewThreads plus outdatedUnresolvedReviewThreads must equal unresolvedReviewThreads"

reset_bundle
edit_json "handoffs/release-pr-readiness-report.json" "const requirement = data.requirements[0]; requirement.message = requirement.message.replace(' reviewConversationResolutionRequired=true', ''); data.failures[0] = requirement.message"
refresh_manifest_artifact "handoffs/release-pr-readiness-report.json"
rewrite_checksums
expect_failure "release PR status report review-thread resolution flag fixture" "handoffs/release-pr-readiness-report.json.requirements[0].message must include reviewConversationResolutionRequired=true when unresolvedReviewThreads is positive"

reset_bundle
edit_json "handoffs/release-pr-readiness-report.json" "const requirement = data.requirements[0]; requirement.message = requirement.message.replace(' outdatedReviewThreadsStillBlockMerge=true', ''); data.failures[0] = requirement.message"
refresh_manifest_artifact "handoffs/release-pr-readiness-report.json"
rewrite_checksums
expect_failure "release PR status report outdated-thread flag fixture" "handoffs/release-pr-readiness-report.json.requirements[0].message must include outdatedReviewThreadsStillBlockMerge=true when only outdated review threads remain"

reset_bundle
edit_json "handoffs/release-pr-readiness-report.json" "const requirement = data.requirements[0]; delete requirement.currentUnresolvedReviewThreads; requirement.message = requirement.message.replace(' currentUnresolvedReviewThreads=0', ''); data.failures[0] = requirement.message"
refresh_manifest_artifact "handoffs/release-pr-readiness-report.json"
rewrite_checksums
expect_failure "release PR status report missing review-thread diagnostics fixture" "handoffs/release-pr-readiness-report.json.requirements[0].currentUnresolvedReviewThreads required when review-thread diagnostics are present"

reset_bundle
edit_json "handoffs/release-pr-readiness-report.json" "data.requirements[0].status = 'passed'; data.totals.passed = 1; data.totals.failed = 3; data.failures = data.requirements.filter((requirement) => requirement.status === 'failed').map((requirement) => requirement.message)"
refresh_manifest_artifact "handoffs/release-pr-readiness-report.json"
rewrite_checksums
expect_failure "release PR status report passed failure-message fixture" "handoffs/release-pr-readiness-report.json.requirements[0].message contradicts passed status"

reset_bundle
edit_json "handoffs/release-pr-readiness-report.json" "const requirement = data.requirements[0]; requirement.status = 'passed'; requirement.message = 'soramitsu/fearless-wallet-web#1061 is merged with required checks validate: https://github.com/soramitsu/fearless-wallet-web/pull/1061'; data.totals.passed = 1; data.totals.failed = 3; data.failures = data.requirements.filter((item) => item.status === 'failed').map((item) => item.message)"
refresh_manifest_artifact "handoffs/release-pr-readiness-report.json"
rewrite_checksums
expect_failure "release PR status report success required-checks fixture" "handoffs/release-pr-readiness-report.json.requirements[0].requiredChecks must match success message"

reset_bundle
edit_json "handoffs/release-pr-readiness-report.json" "const message = 'soramitsu/fearless-wallet-web#1061 is merged with required checks validate,verify: https://github.com/soramitsu/fearless-wallet-web/pull/1061'; data.requirements[0].message = message; data.failures[0] = message"
refresh_manifest_artifact "handoffs/release-pr-readiness-report.json"
rewrite_checksums
expect_failure "release PR status report failed success-message fixture" "handoffs/release-pr-readiness-report.json.requirements[0].message contradicts failed status"

reset_bundle
edit_json "handoffs/release-pr-readiness-report.json" "data.failures[0] = 'soramitsu/fearless-wallet-web#1061 failure text hidden by tampered bundle'"
refresh_manifest_artifact "handoffs/release-pr-readiness-report.json"
rewrite_checksums
expect_failure "release PR status report failure-message fixture" "handoffs/release-pr-readiness-report.json.failures[0] must match failed requirement message"

reset_bundle
edit_json "handoffs/release-pr-readiness-report.json" "const requirement = data.requirements[0]; requirement.message = 'soramitsu/fearless-wallet-web:codex/web-bitcoin-broadcast-evidence -> develop: no merged pull request found'; delete requirement.pr; delete requirement.isDraft; delete requirement.reviewDecision; delete requirement.mergeStateStatus; delete requirement.unresolvedReviewThreads; delete requirement.currentUnresolvedReviewThreads; delete requirement.outdatedUnresolvedReviewThreads; data.failures[0] = requirement.message"
refresh_manifest_artifact "handoffs/release-pr-readiness-report.json"
edit_json "manifest.json" "data.blockers.find((blocker) => blocker.slug === 'release-pr-readiness').releasePrStatusReportHandoff.reportSha256 = data.artifacts.find((artifact) => artifact.path === 'handoffs/release-pr-readiness-report.json').sha256"
rewrite_checksums
expect_failure "release PR status report failure log parity fixture" "handoffs/release-pr-readiness-report.json.failures[0] must be present in release PR log"

reset_bundle
edit_json "handoffs/release-pr-readiness-report.json" "const requirement = data.requirements[1]; requirement.message = requirement.message.replace(/ isDraft=false.*$/, ''); data.failures[1] = requirement.message"
refresh_manifest_artifact "handoffs/release-pr-readiness-report.json"
edit_json "manifest.json" "data.blockers.find((blocker) => blocker.slug === 'release-pr-readiness').releasePrStatusReportHandoff.reportSha256 = data.artifacts.find((artifact) => artifact.path === 'handoffs/release-pr-readiness-report.json').sha256"
rewrite_checksums
expect_failure "release PR status report failure log substring fixture" "handoffs/release-pr-readiness-report.json.failures[1] must be present in release PR log as a full failure line"

reset_bundle
edit_json "handoffs/release-pr-readiness-report.json" "const requirement = data.requirements[0]; requirement.status = 'passed'; requirement.message = 'soramitsu/fearless-wallet-web#1061 is merged with required checks validate,verify: https://github.com/soramitsu/fearless-wallet-web/pull/1061'; delete requirement.isDraft; delete requirement.reviewDecision; delete requirement.mergeStateStatus; delete requirement.unresolvedReviewThreads; delete requirement.currentUnresolvedReviewThreads; delete requirement.outdatedUnresolvedReviewThreads; data.totals.passed = 1; data.totals.failed = 3; data.failures = data.requirements.filter((item) => item.status === 'failed').map((item) => item.message)"
refresh_manifest_artifact "handoffs/release-pr-readiness-report.json"
edit_json "manifest.json" "const releasePr = data.blockers.find((blocker) => blocker.slug === 'release-pr-readiness'); releasePr.releasePrStatusReportHandoff.reportSha256 = data.artifacts.find((artifact) => artifact.path === 'handoffs/release-pr-readiness-report.json').sha256; releasePr.releasePrStatusReportHandoff.status = 'failed'; releasePr.releasePrStatusReportHandoff.failedCount = 3; releasePr.releasePrStatusReportHandoff.blockedPrs = releasePr.releasePrStatusReportHandoff.blockedPrs.filter((pr) => !(pr.repo === 'soramitsu/fearless-wallet-web' && pr.pr === '1061')); releasePr.releasePrMergeHandoff.blockedPrCount = 3"
rewrite_checksums
expect_failure "release PR status report passed requirement log parity fixture" "handoffs/release-pr-readiness-report.json.requirements[0].message must be present in release PR log as a full result line"

reset_bundle
printf '%s\n' "[release-pr-readiness][warn] soramitsu/fearless-wallet-web#9999 is merged with required checks validate,verify: https://github.com/soramitsu/fearless-wallet-web/pull/9999" >> "$bundle_dir/logs/release-pr-readiness.log"
refresh_manifest_artifact "logs/release-pr-readiness.log"
edit_json "manifest.json" "const releasePr = data.blockers.find((blocker) => blocker.slug === 'release-pr-readiness'); releasePr.logSha256 = data.artifacts.find((artifact) => artifact.path === 'logs/release-pr-readiness.log').sha256"
rewrite_checksums
expect_failure "release PR status report extra log result fixture" "handoffs/release-pr-readiness-report.json.logResults"

reset_bundle
edit_json "handoffs/release-pr-readiness-report.json" "data.requirements.find((requirement) => requirement.reviewDetails === 'unavailable').approvalCount = 0"
refresh_manifest_artifact "handoffs/release-pr-readiness-report.json"
rewrite_checksums
expect_failure "release PR status report review-details count fixture" "handoffs/release-pr-readiness-report.json.requirements[2].approvalCount must be omitted when reviewDetails is unavailable"

reset_bundle
edit_json "manifest.json" "delete data.blockers.find((blocker) => blocker.slug === 'release-pr-readiness').releasePrApprovalHandoff"
rewrite_checksums
expect_failure "release PR approval handoff missing fixture" "release-pr-readiness.releasePrApprovalHandoff missing"

reset_bundle
edit_json "manifest.json" "data.blockers.find((blocker) => blocker.slug === 'release-pr-readiness').releasePrApprovalHandoff.approvalCount = 4"
rewrite_checksums
expect_failure "release PR approval handoff count mismatch fixture" "release-pr-readiness.releasePrApprovalHandoff.prs length must match approvalCount"

reset_bundle
edit_json "manifest.json" "data.blockers.find((blocker) => blocker.slug === 'release-pr-readiness').releasePrApprovalHandoff.prs[0].url = 'https://github.com/tonswap-org/ton-indexer/pull/99'"
rewrite_checksums
expect_failure "release PR approval handoff URL mismatch fixture" "release-pr-readiness.releasePrApprovalHandoff.prs[0].url mismatch"

reset_bundle
edit_json "manifest.json" "data.blockers.find((blocker) => blocker.slug === 'release-pr-readiness').releasePrApprovalHandoff.prs[0].reviewDecision = 'APPROVED'"
rewrite_checksums
expect_failure "release PR approval handoff review-decision mismatch fixture" "release-pr-readiness.releasePrApprovalHandoff.prs[0].reviewDecision must be REVIEW_REQUIRED or UNKNOWN"

reset_bundle
edit_json "manifest.json" "data.blockers.find((blocker) => blocker.slug === 'release-pr-readiness').releasePrApprovalHandoff.prs[0].currentHeadApprovalCount = 2"
rewrite_checksums
expect_failure "release PR approval handoff current-head count mismatch fixture" "release-pr-readiness.releasePrApprovalHandoff.prs[0].currentHeadApprovalCount must not exceed approvalCount"

reset_bundle
edit_json "manifest.json" "data.blockers.find((blocker) => blocker.slug === 'release-pr-readiness').releasePrApprovalHandoff.prs[0].latestApprovalCommit = 'not-a-commit'"
rewrite_checksums
expect_failure "release PR approval handoff latest approval commit malformed fixture" "release-pr-readiness.releasePrApprovalHandoff.prs[0].latestApprovalCommit must be a 40-character hex commit"

reset_bundle
edit_json "manifest.json" "data.blockers.find((blocker) => blocker.slug === 'release-pr-readiness').releasePrApprovalHandoff.prs[0].currentApprovalNotEligible = false"
rewrite_checksums
expect_failure "release PR approval handoff current approval eligibility mismatch fixture" "release-pr-readiness.releasePrApprovalHandoff.prs[0].currentApprovalNotEligible must be true when current-head approvals are present"

reset_bundle
edit_json "manifest.json" "data.blockers.find((blocker) => blocker.slug === 'release-pr-readiness').releasePrApprovalHandoff.prs[1].reviewDetails = 'unknown'"
rewrite_checksums
expect_failure "release PR approval handoff review-details invalid fixture" "release-pr-readiness.releasePrApprovalHandoff.prs[1].reviewDetails must be unavailable or malformed"

reset_bundle
edit_json "manifest.json" "data.blockers.find((blocker) => blocker.slug === 'release-pr-readiness').releasePrApprovalHandoff.prs[1].approvalCount = 0"
rewrite_checksums
expect_failure "release PR approval handoff review-details count fixture" "release-pr-readiness.releasePrApprovalHandoff.prs[1].approvalCount must be omitted when reviewDetails is unavailable"

reset_bundle
edit_json "manifest.json" "data.blockers.find((blocker) => blocker.slug === 'release-pr-readiness').releasePrApprovalHandoff.prs.reverse()"
rewrite_checksums
expect_failure "release PR approval handoff status-report order fixture" "release-pr-readiness.releasePrApprovalHandoff.prs[0] must match status report approval order"

reset_bundle
edit_json "manifest.json" "data.blockers.find((blocker) => blocker.slug === 'release-pr-readiness').releasePrApprovalHandoff.prs[0].approvalCount = 2"
rewrite_checksums
expect_failure "release PR approval handoff status-report approval-count fixture" "release-pr-readiness.releasePrApprovalHandoff.prs[0].approvalCount must match status report"

reset_bundle
edit_json "manifest.json" "data.blockers.find((blocker) => blocker.slug === 'release-pr-readiness').releasePrApprovalHandoff.prs[0].mergeStateStatus = 'CLEAN'"
rewrite_checksums
expect_failure "release PR approval handoff status-report merge-state fixture" "release-pr-readiness.releasePrApprovalHandoff.prs[0].mergeStateStatus must match status report"

reset_bundle
edit_json "manifest.json" "data.blockers.find((blocker) => blocker.slug === 'release-pr-readiness').releasePrApprovalHandoff.prs[0].latestApprovalCommit = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'"
rewrite_checksums
expect_failure "release PR approval handoff status-report latest-approval fixture" "release-pr-readiness.releasePrApprovalHandoff.prs[0].latestApprovalCommit must match status report"

reset_bundle
edit_json "manifest.json" "data.blockers.find((blocker) => blocker.slug === 'release-pr-readiness').releasePrApprovalHandoff.prs[1].reviewDetails = 'malformed'"
rewrite_checksums
expect_failure "release PR approval handoff status-report review-details fixture" "release-pr-readiness.releasePrApprovalHandoff.prs[1].reviewDetails must match status report"

reset_bundle
edit_json "manifest.json" "delete data.blockers.find((blocker) => blocker.slug === 'release-pr-readiness').releasePrMergeHandoff"
rewrite_checksums
expect_failure "release PR merge handoff missing fixture" "release-pr-readiness.releasePrMergeHandoff missing"

reset_bundle
edit_json "manifest.json" "data.blockers.find((blocker) => blocker.slug === 'release-pr-readiness').releasePrMergeHandoff.dryRunCommand = 'bash scripts/merge-release-prs.sh --dry-run'"
rewrite_checksums
expect_failure "release PR merge handoff dry-run mismatch fixture" "release-pr-readiness.releasePrMergeHandoff.dryRunCommand mismatch"

reset_bundle
edit_json "manifest.json" "data.blockers.find((blocker) => blocker.slug === 'release-pr-readiness').releasePrMergeHandoff.requiredPrCount = 99"
rewrite_checksums
expect_failure "release PR merge handoff required-count fixture" "release-pr-readiness.releasePrMergeHandoff.requiredPrCount must match status report"

reset_bundle
edit_json "manifest.json" "data.blockers.find((blocker) => blocker.slug === 'release-pr-readiness').releasePrMergeHandoff.blockedPrCount = 99"
rewrite_checksums
expect_failure "release PR merge handoff blocked-count fixture" "release-pr-readiness.releasePrMergeHandoff.blockedPrCount must match status report"

reset_bundle
node - "$bundle_dir/handoffs/release-pr-readiness-report.json" "$bundle_dir/logs/release-pr-readiness.log" <<'NODE'
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
fs.writeFileSync(reportFile, JSON.stringify(report, null, 2) + '\n')
const log = fs.readFileSync(logFile, 'utf8')
fs.writeFileSync(logFile, log.replace(`[release-pr-readiness][warn] ${originalMessage}`, `[release-pr-readiness][warn] ${requirement.message}`))
NODE
refresh_manifest_artifact "handoffs/release-pr-readiness-report.json"
refresh_manifest_artifact "logs/release-pr-readiness.log"
edit_json "manifest.json" "const releasePr = data.blockers.find((blocker) => blocker.slug === 'release-pr-readiness'); releasePr.releasePrStatusReportHandoff.reportSha256 = data.artifacts.find((artifact) => artifact.path === 'handoffs/release-pr-readiness-report.json').sha256; releasePr.releasePrStatusReportHandoff.blockedPrs = releasePr.releasePrStatusReportHandoff.blockedPrs.filter((pr) => !(pr.repo === 'soramitsu/fearless-wallet-web' && pr.pr === '1061')); releasePr.logSha256 = data.artifacts.find((artifact) => artifact.path === 'logs/release-pr-readiness.log').sha256"
rewrite_checksums
expect_failure "release PR merge handoff no-PR failure blocked-count fixture" "release-pr-readiness.releasePrMergeHandoff.blockedPrCount must match status report blocked PR count"

reset_bundle
edit_json "manifest.json" "data.blockers.find((blocker) => blocker.slug === 'release-pr-readiness').releasePrMergeHandoff.applyCommand = 'bash scripts/merge-release-prs.sh --apply --config config/release-readiness-prs.tsv'"
rewrite_checksums
expect_failure "release PR merge handoff apply mismatch fixture" "release-pr-readiness.releasePrMergeHandoff.applyCommand mismatch"

reset_bundle
edit_json "manifest.json" "data.generatedAt = 'not-a-timestamp'"
rewrite_checksums
expect_failure "invalid manifest timestamp fixture" "manifest.generatedAt must be an ISO-8601 UTC seconds timestamp"

reset_bundle
edit_json "manifest.json" "data.generatedAt = '2026-06-28T13:10:00Z'"
rewrite_checksums
expect_failure_at_time "future manifest timestamp fixture" "2026-06-28T12:00:00Z" "manifest.generatedAt is in the future"

reset_bundle
edit_json "manifest.json" "data.generatedAt = '2026-06-28T10:00:00Z'"
rewrite_checksums
expect_failure_at_time "stale bundle max-age fixture" "2026-06-28T12:30:00Z" "bundle generated at 2026-06-28T10:00:00Z is older than --max-age-hours 1" --max-age-hours 1

reset_bundle
edit_json "manifest.json" "data.generatedAt = '2026-06-28T12:00:00Z'"
edit_json "summary.json" "data.generatedAt = '2026-06-28T10:00:00Z'"
refresh_manifest_artifact "summary.json"
edit_json "actions.json" "data.generatedAt = '2026-06-28T10:00:00Z'"
refresh_manifest_artifact "actions.json"
rewrite_checksums
expect_failure_at_time "stale report max-age fixture" "2026-06-28T12:30:00Z" "report generated at 2026-06-28T10:00:00Z is older than --max-age-hours 1" --max-age-hours 1

reset_bundle
edit_json "manifest.json" "data.generatedAt = '2026-06-28T11:59:00Z'"
rewrite_checksums
expect_failure_at_time "invalid max-age fixture" "2026-06-28T12:00:00Z" "--max-age-hours must be a positive integer" --max-age-hours nope

reset_bundle
edit_json "actions.json" "data.generatedAt = '2026-06-28T00:00:01Z'"
refresh_manifest_artifact "actions.json"
rewrite_checksums
expect_failure "summary actions generatedAt mismatch fixture" "summary/actions generatedAt mismatch"

reset_bundle
edit_json "manifest.json" "data.generatedAt = '2026-06-28T12:06:00Z'"
edit_json "summary.json" "data.generatedAt = '2026-06-28T12:06:00Z'"
refresh_manifest_artifact "summary.json"
edit_json "actions.json" "data.generatedAt = '2026-06-28T12:06:00Z'"
refresh_manifest_artifact "actions.json"
rewrite_checksums
expect_failure_at_time "future report timestamp fixture" "2026-06-28T12:00:00Z" "summary.generatedAt is in the future"

reset_bundle
edit_json "manifest.json" "data.generatedAt = '2026-06-27T23:59:59Z'"
rewrite_checksums
expect_failure "manifest earlier than report timestamp fixture" "manifest.generatedAt must not be earlier than summary/actions generatedAt"

reset_bundle
edit_json "manifest.json" "data.sourceReportDir = '../reports'"
rewrite_checksums
expect_failure "relative source report dir fixture" "manifest.sourceReportDir must be an absolute normalized path"

reset_bundle
edit_json "manifest.json" "data.sourceReportDir = '/tmp/forged-release-readiness'"
rewrite_checksums
expect_failure "source report dir outside workspace fixture" "manifest.sourceReportDir points outside workspace root"

reset_bundle
edit_json "manifest.json" "data.artifacts.find((artifact) => artifact.path === 'actions.json').sourcePath = '/tmp/actions.json'"
rewrite_checksums
expect_failure "outside artifact source path fixture" "actions.json.sourcePath points outside sourceReportDir"

reset_bundle
edit_json "manifest.json" "data.artifacts.find((artifact) => artifact.path === 'actions.json').sourcePath = '/tmp/private_key/actions.json'"
rewrite_checksums
expect_failure "secret-like source path fixture" "actions.json.sourcePath contains secret-like token"

reset_bundle
edit_json "manifest.json" "data.artifacts.find((artifact) => artifact.path === 'summary.json').sourcePath = data.sourceReportDir + '/summary-copy.json'"
rewrite_checksums
expect_failure "report artifact source path drift fixture" "summary.json.sourcePath must match report artifact path"

reset_bundle
printf '%s\n' "operator notes" > "$bundle_dir/notes.txt"
edit_json "manifest.json" "data.artifacts.push({ path: 'notes.txt', sourcePath: data.sourceReportDir + '/notes.txt', sha256: '0'.repeat(64), bytes: 15 })"
refresh_manifest_artifact "notes.txt"
rewrite_checksums
expect_failure "unsupported manifest artifact path fixture" "unsupported manifest artifact path: notes.txt"

reset_bundle
edit_json "manifest.json" "const artifact = data.artifacts.find((item) => item.path === 'actions.json'); data.artifacts.push({ ...artifact })"
rewrite_checksums
expect_failure "duplicate manifest artifact path fixture" "duplicate manifest artifact path: actions.json"

reset_bundle
edit_json "manifest.json" "data.artifacts = data.artifacts.filter((artifact) => artifact.path !== 'blockers.md')"
rewrite_checksums
expect_failure "missing required manifest artifact fixture" "manifest missing required artifact: blockers.md"

reset_bundle
printf '%s\n' "ghost log" > "$bundle_dir/logs/ghost.log"
edit_json "manifest.json" "data.artifacts.push({ path: 'logs/ghost.log', sourcePath: data.sourceReportDir + '/ghost.log', sha256: '0'.repeat(64), bytes: 10 })"
refresh_manifest_artifact "logs/ghost.log"
rewrite_checksums
expect_failure "unmatched log artifact fixture" "logs/ghost.log has no matching blocker"

reset_bundle
printf '%s\n' '{"orphan":true}' > "$bundle_dir/handoffs/orphan-deployment-evidence-template.json"
edit_json "manifest.json" "data.artifacts.push({ path: 'handoffs/orphan-deployment-evidence-template.json', sourcePath: data.sourceReportDir + '/orphan-deployment-evidence-template.json', sha256: '0'.repeat(64), bytes: 0 })"
refresh_manifest_artifact "handoffs/orphan-deployment-evidence-template.json"
rewrite_checksums
expect_failure "orphan handoff artifact fixture" "unsupported manifest artifact path: handoffs/orphan-deployment-evidence-template.json"

reset_bundle
edit_json "manifest.json" "data.blockers[0].sourceLog = data.sourceReportDir + '/different.log'"
rewrite_checksums
expect_failure "blocker source log artifact mismatch fixture" "release-pr-readiness.sourceLog must match log artifact sourcePath"

reset_bundle
edit_json "actions.json" "data.blockers[0].logFile = './release-pr-readiness.log'"
refresh_manifest_artifact "actions.json"
rewrite_checksums
expect_failure "non-normalized action log path fixture" "release-pr-readiness.action.logFile must be absolute normalized or relative normalized path"

reset_bundle
perl -0pi -e 's/Get every PR in config\/release-readiness-prs\.tsv approved/Skip release approvals/' "$bundle_dir/unblock.md"
rewrite_checksums
expect_failure "unblock markdown mismatch fixture" "unblock.md does not match manifest blockers"

reset_bundle
rm "$bundle_dir/unblock.md"
expect_failure "missing unblock markdown fixture" "unblock.md missing"

reset_bundle
perl -0pi -e 's/Get every PR in config\/release-readiness-prs\.tsv approved/Skip release approvals/' "$bundle_dir/blockers.md"
refresh_manifest_artifact "blockers.md"
rewrite_checksums
expect_failure "blockers markdown mismatch fixture" "blockers.md does not match summary/actions blockers"

reset_bundle
rm "$bundle_dir/blockers.md"
expect_failure "missing blocker report file fixture" "blockers.md missing"

reset_bundle
printf '%s\n' '#!/usr/bin/env bash' 'echo tampered' > "$bundle_dir/verify-blockers.sh"
chmod +x "$bundle_dir/verify-blockers.sh"
rewrite_checksums
expect_failure "verify script mismatch fixture" "verify-blockers.sh does not match manifest blockers"

reset_bundle
rm "$bundle_dir/verify-blockers.sh"
expect_failure "missing verify script fixture" "verify-blockers.sh missing"

reset_bundle
chmod -x "$bundle_dir/verify-blockers.sh"
expect_failure "verify script executable bit fixture" "verify-blockers.sh must be executable"

reset_bundle
rm "$bundle_dir/manifest.json"
expect_failure "missing manifest fixture" "manifest.json missing"

reset_bundle
printf '{bad-json\n' > "$bundle_dir/manifest.json"
expect_failure "malformed manifest fixture" "manifest.json is not valid JSON"

reset_bundle
node - "$bundle_dir/logs/si-production-smoke.log" <<'NODE'
const fs = require('fs')
const file = process.argv[2]
const original = fs.readFileSync(file, 'utf8')
fs.writeFileSync(file, 'x'.repeat(Buffer.byteLength(original) - 1) + '\n')
NODE
expect_failure "checksum mismatch fixture" "logs/si-production-smoke.log SHA-256 mismatch"

reset_bundle
rm "$bundle_dir/SHA256SUMS"
expect_failure "missing checksum file fixture" "SHA256SUMS missing"

reset_bundle
printf '%s\n' "not-a-valid-checksum-line" > "$bundle_dir/SHA256SUMS"
expect_failure "malformed checksum line fixture" "SHA256SUMS line 1 has invalid format"

reset_bundle
printf '%s\n' "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa  SHA256SUMS" >> "$bundle_dir/SHA256SUMS"
expect_failure "checksum self-reference fixture" "SHA256SUMS must not include itself"

reset_bundle
: > "$bundle_dir/SHA256SUMS"
expect_failure "empty checksum file fixture" "SHA256SUMS must contain at least one entry"

reset_bundle
printf '%s\n' "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa  private_key.txt" >> "$bundle_dir/SHA256SUMS"
expect_failure "secret-like checksum file fixture" "SHA256SUMS contains secret-like token"

reset_bundle
grep -v 'logs/release-pr-readiness.log' "$bundle_dir/SHA256SUMS" > "$bundle_dir/SHA256SUMS.tmp"
mv "$bundle_dir/SHA256SUMS.tmp" "$bundle_dir/SHA256SUMS"
expect_failure "missing checksum entry fixture" "SHA256SUMS missing expected path: logs/release-pr-readiness.log"

reset_bundle
head -n 1 "$bundle_dir/SHA256SUMS" >> "$bundle_dir/SHA256SUMS"
expect_failure "duplicate checksum path fixture" "duplicate checksum path"

reset_bundle
printf '%s\n' "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa  ghost.txt" >> "$bundle_dir/SHA256SUMS"
expect_failure "unexpected checksum path fixture" "SHA256SUMS contains unexpected path: ghost.txt"

reset_bundle
LC_ALL=C sort -r "$bundle_dir/SHA256SUMS" > "$bundle_dir/SHA256SUMS.tmp"
mv "$bundle_dir/SHA256SUMS.tmp" "$bundle_dir/SHA256SUMS"
expect_failure "unsorted checksum file fixture" "SHA256SUMS is not sorted or does not match bundle contents"

reset_bundle
printf '%s\n' "unchecked" > "$bundle_dir/unchecked.txt"
expect_failure "unchecked extra file fixture" "bundle contains unchecked file: unchecked.txt"

reset_bundle
mkdir -p "$bundle_dir/unchecked-dir"
expect_failure "unchecked extra directory fixture" "bundle contains unchecked directory: unchecked-dir"

reset_bundle
printf '%s\n' "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa  ../evil.txt" >> "$bundle_dir/SHA256SUMS"
expect_failure "unsafe checksum path fixture" "points outside bundle"

reset_bundle
printf '%s\n' "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa  logs\\release-pr-readiness.log" >> "$bundle_dir/SHA256SUMS"
expect_failure "backslash checksum path fixture" "must use forward slashes"

reset_bundle
printf '%s\n' "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa  /tmp/release-pr-readiness.log" >> "$bundle_dir/SHA256SUMS"
expect_failure "absolute checksum path fixture" "must be relative"

reset_bundle
printf '%s\n' "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa  ./manifest.json" >> "$bundle_dir/SHA256SUMS"
expect_failure "non-normalized checksum path fixture" "must be normalized"

reset_bundle
edit_json "manifest.json" "data.unexpected = true"
rewrite_checksums
expect_failure "unsupported manifest key fixture" "unsupported manifest key"

reset_bundle
edit_json "manifest.json" "data.artifacts[0].unexpected = true"
rewrite_checksums
expect_failure "unsupported manifest artifact key fixture" "unsupported manifest artifact key: unexpected"

reset_bundle
edit_json "manifest.json" "data.blockers[1].slug = data.blockers[0].slug"
rewrite_checksums
expect_failure "duplicate blocker fixture" "duplicate blocker slug"

reset_bundle
edit_json "manifest.json" "data.blockers[0].unexpected = true"
rewrite_checksums
expect_failure "unsupported manifest blocker key fixture" "unsupported manifest blocker key: unexpected"

reset_bundle
edit_json "manifest.json" "data.blockers[0].name = 'Release\\nPR readiness'"
rewrite_checksums
expect_failure "manifest blocker multiline name fixture" "blocker.name must be a single-line value"

reset_bundle
edit_json "manifest.json" "data.blockers[0].name = 'Release PR readiness api_key'"
rewrite_checksums
expect_failure "manifest blocker secret-like name fixture" "blocker.name contains secret-like token"

reset_bundle
edit_json "manifest.json" "data.blockers[0].recommendedAction = 'Approve and merge\\nthe release PRs.'"
rewrite_checksums
expect_failure "manifest blocker multiline recommended action fixture" "release-pr-readiness.recommendedAction must be a single-line value"

reset_bundle
edit_json "manifest.json" "data.blockers[0].verificationCommand = 'bash scripts/audit-release-pr-readiness.sh\\necho unsafe'"
rewrite_checksums
expect_failure "manifest blocker multiline verification command fixture" "release-pr-readiness.verificationCommand must be a single-line value"

reset_bundle
edit_json "actions.json" "data.blockers[1].slug = data.blockers[0].slug"
refresh_manifest_artifact "actions.json"
rewrite_checksums
expect_failure "duplicate action blocker fixture" "duplicate action blocker slug"

reset_bundle
edit_json "actions.json" "data.blockers[0].unexpected = true"
refresh_manifest_artifact "actions.json"
rewrite_checksums
expect_failure "unsupported action blocker key fixture" "unsupported action blocker key: unexpected"

reset_bundle
edit_json "actions.json" "data.blockers[0].name = 'Release\\nPR readiness'"
refresh_manifest_artifact "actions.json"
rewrite_checksums
expect_failure "action blocker multiline name fixture" "action.name must be a single-line value"

reset_bundle
edit_json "actions.json" "data.blockers[0].name = 'Release PR readiness api_key'"
refresh_manifest_artifact "actions.json"
rewrite_checksums
expect_failure "action blocker secret-like name fixture" "actions.json contains secret-like token"

reset_bundle
edit_json "actions.json" "data.blockers[0].name = 'Release PR approval readiness'"
refresh_manifest_artifact "actions.json"
rewrite_checksums
expect_failure "action blocker wrong name contract fixture" "release-pr-readiness.name must match expected check name"

reset_bundle
edit_json "actions.json" "data.blockers[0].requiresExternalAction = false"
refresh_manifest_artifact "actions.json"
rewrite_checksums
expect_failure "action blocker wrong external-action contract fixture" "release-pr-readiness.requiresExternalAction must match expected unblock metadata"

reset_bundle
edit_json "actions.json" "data.blockers[0].unblockCategory = 'local-code'"
refresh_manifest_artifact "actions.json"
rewrite_checksums
expect_failure "action blocker wrong category contract fixture" "release-pr-readiness.unblockCategory must match expected unblock metadata"

reset_bundle
edit_json "actions.json" "data.blockers[0].externalPrerequisite = 'Local release checklist cleanup.'"
refresh_manifest_artifact "actions.json"
rewrite_checksums
expect_failure "action blocker wrong external-prerequisite contract fixture" "release-pr-readiness.externalPrerequisite must match expected unblock metadata"

reset_bundle
edit_json "actions.json" "data.blockers[0].recommendedAction = 'Approve and merge the release PRs.'"
refresh_manifest_artifact "actions.json"
rewrite_checksums
expect_failure "action blocker wrong recommended-action contract fixture" "release-pr-readiness.recommendedAction must match expected recommended action"

reset_bundle
edit_json "actions.json" "data.blockers[0].recommendedAction = 'Approve and merge\\nthe release PRs.'"
refresh_manifest_artifact "actions.json"
rewrite_checksums
expect_failure "action blocker multiline recommended action fixture" "release-pr-readiness.recommendedAction must be a single-line value"

reset_bundle
edit_json "actions.json" "data.blockers[0].exitCode = 0"
refresh_manifest_artifact "actions.json"
rewrite_checksums
expect_failure "action blocker zero exit-code fixture" "release-pr-readiness.exitCode must be positive for failed blocker"

reset_bundle
edit_json "actions.json" "data.blockers[0].evidencePreview = 'All release PRs are approved and merged.'"
edit_json "manifest.json" "data.blockers[0].evidencePreview = 'All release PRs are approved and merged.'"
refresh_manifest_artifact "actions.json"
rewrite_checksums
expect_failure "action blocker unbacked evidence-preview fixture" "release-pr-readiness.evidencePreview line is not present in source log"

reset_bundle
edit_json "actions.json" "data.blockers[0].evidencePreview = 'api_key'"
refresh_manifest_artifact "actions.json"
rewrite_checksums
expect_failure "action blocker secret-like evidence-preview fixture" "actions.json contains secret-like token"

reset_bundle
edit_json "actions.json" "data.blockers[0].evidencePreview = 'not release-ready'"
edit_json "manifest.json" "data.blockers[0].evidencePreview = 'not release-ready'"
refresh_manifest_artifact "actions.json"
rewrite_checksums
expect_failure "action blocker substring evidence-preview fixture" "release-pr-readiness.evidencePreview line must match a complete source log line"

reset_bundle
edit_json "actions.json" "data.blockers[0].verificationCommand = 'bash scripts/audit-release-pr-readiness.sh\\necho unsafe'"
refresh_manifest_artifact "actions.json"
rewrite_checksums
expect_failure "action blocker multiline verification command fixture" "release-pr-readiness.verificationCommand must be a single-line value"

reset_bundle
edit_json "actions.json" "data.blockers[0].verificationCommand = 'bash scripts/audit-release-pr-readiness.sh; echo unsafe'"
refresh_manifest_artifact "actions.json"
rewrite_checksums
expect_failure "action blocker unsafe verification command fixture" "release-pr-readiness.verificationCommand must match expected command"

reset_bundle
edit_json "actions.json" "data.blockers[0].slug = 'Release Pr Readiness'"
refresh_manifest_artifact "actions.json"
rewrite_checksums
expect_failure "action blocker slug format fixture" "action.slug has unsupported format: Release Pr Readiness"

reset_bundle
edit_json "summary.json" "data.checks[1].slug = data.checks[0].slug"
refresh_manifest_artifact "summary.json"
rewrite_checksums
expect_failure "duplicate summary check fixture" "duplicate summary check slug"

reset_bundle
edit_json "summary.json" "data.checks[0].unexpected = true"
refresh_manifest_artifact "summary.json"
rewrite_checksums
expect_failure "unsupported summary check key fixture" "unsupported summary check key: unexpected"

reset_bundle
edit_json "summary.json" "data.checks[0].name = 'Release\\nPR readiness'"
refresh_manifest_artifact "summary.json"
rewrite_checksums
expect_failure "summary check multiline name fixture" "summary.check.name must be a single-line value"

reset_bundle
edit_json "summary.json" "data.checks[0].name = 'Release PR readiness api_key'"
refresh_manifest_artifact "summary.json"
rewrite_checksums
expect_failure "summary check secret-like name fixture" "summary.json contains secret-like token"

reset_bundle
edit_json "summary.json" "data.checks.find((check) => check.slug === 'plan-readiness').name = 'Static plan readiness drift'"
refresh_manifest_artifact "summary.json"
rewrite_checksums
expect_failure "summary passed wrong name contract fixture" "plan-readiness.summary.name must match expected check name"

reset_bundle
edit_json "summary.json" "data.checks.find((check) => check.slug === 'release-pr-readiness').recommendedAction = 'Approve and merge\\nthe release PRs.'"
refresh_manifest_artifact "summary.json"
rewrite_checksums
expect_failure "summary check multiline recommended action fixture" "release-pr-readiness.summary.recommendedAction must be a single-line value"

reset_bundle
edit_json "summary.json" "data.checks.find((check) => check.slug === 'release-pr-readiness').exitCode = 0"
refresh_manifest_artifact "summary.json"
rewrite_checksums
expect_failure "summary failed zero exit-code fixture" "release-pr-readiness.summary.exitCode must be positive for failed check"

reset_bundle
edit_json "summary.json" "data.checks.find((check) => check.slug === 'plan-readiness').exitCode = 1"
refresh_manifest_artifact "summary.json"
rewrite_checksums
expect_failure "summary passed nonzero exit-code fixture" "plan-readiness.summary.exitCode must be 0 for passed check"

reset_bundle
edit_json "summary.json" "data.checks.find((check) => check.slug === 'release-pr-readiness').verificationCommand = 'bash scripts/audit-release-pr-readiness.sh\\necho unsafe'"
refresh_manifest_artifact "summary.json"
rewrite_checksums
expect_failure "summary check multiline verification command fixture" "release-pr-readiness.summary.verificationCommand must be a single-line value"

reset_bundle
edit_json "manifest.json" "data.blockers[0].recommendedAction = 'different action'"
rewrite_checksums
expect_failure "manifest action mismatch fixture" "recommendedAction mismatch between manifest and actions.json"

reset_bundle
edit_json "manifest.json" "data.blockers[0].name = 'Different release blocker name'"
rewrite_checksums
expect_failure "manifest name mismatch fixture" "name mismatch between manifest and actions.json"

reset_bundle
edit_json "manifest.json" "data.blockers[0].requiresExternalAction = false"
rewrite_checksums
expect_failure "manifest external-action mismatch fixture" "requiresExternalAction mismatch between manifest and actions.json"

reset_bundle
edit_json "manifest.json" "data.blockers[0].verificationCommand = 'bash scripts/audit-plan-readiness.sh'"
rewrite_checksums
expect_failure "manifest verification command mismatch fixture" "verificationCommand mismatch between manifest and actions.json"

reset_bundle
edit_json "manifest.json" "data.blockers[0].evidencePreview = '[release-pr-readiness][warn] wallet PRs still require review'"
rewrite_checksums
expect_failure "manifest evidence preview mismatch fixture" "evidencePreview mismatch between manifest and actions.json"

reset_bundle
edit_json "manifest.json" "data.blockers[0].unblockCategory = 'unknown-category'"
rewrite_checksums
expect_failure "unsupported manifest unblock category fixture" "unblockCategory unsupported"

reset_bundle
edit_json "manifest.json" "data.blockers[0].unblockCategory = 'live-service-routing'"
rewrite_checksums
expect_failure "manifest unblock category mismatch fixture" "unblockCategory mismatch between manifest and actions.json"

reset_bundle
edit_json "manifest.json" "data.blockers[0].externalPrerequisite = 'Different external prerequisite'"
rewrite_checksums
expect_failure "actions external prerequisite mismatch fixture" "externalPrerequisite mismatch between manifest and actions.json"

reset_bundle
edit_json "manifest.json" "data.blockers[0].logSha256 = '0'.repeat(64)"
rewrite_checksums
expect_failure "manifest log checksum mismatch fixture" "logSha256 does not match artifact checksum"

reset_bundle
edit_json "manifest.json" "data.artifacts.find((artifact) => artifact.path === 'actions.json').bytes = 1"
rewrite_checksums
expect_failure "manifest bytes mismatch fixture" "actions.json bytes mismatch"

reset_bundle
rm "$bundle_dir/logs/si-production-smoke.log"
expect_failure "missing artifact file fixture" "manifest artifact missing: logs/si-production-smoke.log"

reset_bundle
printf '%s\n' \
  "health serviceId must be si.soramitsu.io; received <missing>" \
  "private_key=do-not-ship" \
  > "$bundle_dir/logs/si-production-smoke.log"
node - "$bundle_dir/manifest.json" <<'NODE'
const crypto = require('crypto')
const fs = require('fs')
const path = require('path')
const manifestFile = process.argv[2]
const root = path.dirname(manifestFile)
const manifest = JSON.parse(fs.readFileSync(manifestFile, 'utf8'))
const logPath = path.join(root, 'logs/si-production-smoke.log')
const content = fs.readFileSync(logPath)
const digest = crypto.createHash('sha256').update(content).digest('hex')
const artifact = manifest.artifacts.find((item) => item.path === 'logs/si-production-smoke.log')
artifact.sha256 = digest
artifact.bytes = content.length
const blocker = manifest.blockers.find((item) => item.slug === 'si-production-smoke')
blocker.logSha256 = digest
fs.writeFileSync(manifestFile, JSON.stringify(manifest, null, 2) + '\n')
NODE
rewrite_checksums
expect_failure "secret-like copied log fixture" "contains secret-like token"

reset_bundle
edit_json "summary.json" "data.totals.failed = 1; data.totals.total = data.totals.passed + data.totals.failed + data.totals.skipped"
rewrite_checksums
expect_failure "summary mismatch fixture" "totals mismatch for failed"

reset_bundle
edit_json "manifest.json" "data.status = 'degraded'"
edit_json "summary.json" "data.status = 'degraded'"
refresh_manifest_artifact "summary.json"
edit_json "actions.json" "data.status = 'degraded'"
refresh_manifest_artifact "actions.json"
perl -0pi -e 's/- Status: `failed`/- Status: `degraded`/' "$bundle_dir/unblock.md"
rewrite_checksums
expect_failure "unsupported overall status fixture" "release status unsupported: degraded"

reset_bundle
edit_json "manifest.json" "data.status = 'passed'"
edit_json "summary.json" "data.status = 'passed'"
refresh_manifest_artifact "summary.json"
edit_json "actions.json" "data.status = 'passed'"
refresh_manifest_artifact "actions.json"
perl -0pi -e 's/- Status: `failed`/- Status: `passed`/' "$bundle_dir/unblock.md"
rewrite_checksums
expect_failure "status failed-total mismatch fixture" "release status must be failed when failed total is greater than zero"

reset_bundle
edit_json "summary.json" "const check = data.checks.find((item) => item.slug === 'release-pr-readiness'); check.status = 'passed'; check.exitCode = 0; check.recommendedAction = null; check.requiresExternalAction = null; check.unblockCategory = null; check.externalPrerequisite = null; check.verificationCommand = null"
refresh_manifest_artifact "summary.json"
rewrite_checksums
expect_failure "summary checks status mismatch fixture" "summary checks passed count must match summary.totals.passed"

reset_bundle
edit_json "summary.json" "data.checks.find((check) => check.slug === 'release-pr-readiness').slug = 'release-pr-readiness-copy'"
refresh_manifest_artifact "summary.json"
rewrite_checksums
expect_failure "summary failed action mismatch fixture" "release-pr-readiness-copy failed summary check missing from actions.json blockers"

reset_bundle
edit_json "summary.json" "data.checks = data.checks.filter((check) => check.slug !== 'passkey-backup-prerequisites'); data.totals.passed -= 1; data.totals.total -= 1"
refresh_manifest_artifact "summary.json"
edit_json "actions.json" "data.totals.passed -= 1; data.totals.total -= 1"
refresh_manifest_artifact "actions.json"
edit_json "manifest.json" "data.totals.passed -= 1; data.totals.total -= 1"
rewrite_checksums
expect_failure "summary missing release check fixture" "summary missing release check: passkey-backup-prerequisites"

reset_bundle
edit_json "summary.json" "const first = data.checks[0]; data.checks[0] = data.checks[1]; data.checks[1] = first"
refresh_manifest_artifact "summary.json"
rewrite_checksums
expect_failure "summary non-failed check order fixture" "summary non-failed checks must match release check order"

reset_bundle
edit_json "actions.json" "const first = data.blockers[0]; data.blockers[0] = data.blockers[1]; data.blockers[1] = first"
refresh_manifest_artifact "actions.json"
rewrite_checksums
expect_failure "actions blocker order fixture" "actions.json blockers must match failed summary check order"

reset_bundle
edit_json "manifest.json" "const first = data.blockers[0]; data.blockers[0] = data.blockers[1]; data.blockers[1] = first"
rewrite_checksums
expect_failure "manifest blocker order fixture" "manifest blockers must match actions.json blocker order"

reset_bundle
edit_json "summary.json" "data.checks.find((check) => check.slug === 'release-pr-readiness').recommendedAction = 'different summary action'"
refresh_manifest_artifact "summary.json"
rewrite_checksums
expect_failure "summary recommended action mismatch fixture" "release-pr-readiness.summary recommendedAction must match actions.json blocker"

reset_bundle
edit_json "summary.json" "data.checks.find((check) => check.slug === 'release-pr-readiness').name = 'Different summary check name'"
refresh_manifest_artifact "summary.json"
rewrite_checksums
expect_failure "summary name mismatch fixture" "release-pr-readiness.summary name must match actions.json blocker"

reset_bundle
edit_json "summary.json" "data.checks.find((check) => check.slug === 'release-pr-readiness').exitCode = 99"
refresh_manifest_artifact "summary.json"
rewrite_checksums
expect_failure "summary exit-code mismatch fixture" "release-pr-readiness.summary exitCode must match actions.json blocker"

reset_bundle
edit_json "summary.json" "data.checks.find((check) => check.slug === 'release-pr-readiness').logFile = 'different-release-pr-readiness.log'"
refresh_manifest_artifact "summary.json"
rewrite_checksums
expect_failure "summary log-file mismatch fixture" "release-pr-readiness.summary logFile must match actions.json logFile"

reset_bundle
edit_json "summary.json" "data.checks.find((check) => check.slug === 'release-pr-readiness').requiresExternalAction = false"
refresh_manifest_artifact "summary.json"
rewrite_checksums
expect_failure "summary external-action mismatch fixture" "release-pr-readiness.summary requiresExternalAction must match actions.json blocker"

reset_bundle
edit_json "summary.json" "data.checks.find((check) => check.slug === 'release-pr-readiness').verificationCommand = 'bash scripts/audit-plan-readiness.sh'"
refresh_manifest_artifact "summary.json"
rewrite_checksums
expect_failure "summary verification command mismatch fixture" "release-pr-readiness.summary verificationCommand must match actions.json blocker"

reset_bundle
edit_json "summary.json" "data.checks.find((check) => check.slug === 'plan-readiness').recommendedAction = 'unexpected action'"
refresh_manifest_artifact "summary.json"
rewrite_checksums
expect_failure "summary non-failed unblock metadata fixture" "plan-readiness.summary non-failed check must not carry unblock metadata"

echo "[release-unblock-bundle-verify-test] all tests passed"
