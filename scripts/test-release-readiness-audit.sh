#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
AUDIT_SCRIPT="$SCRIPT_DIR/audit-release-readiness.sh"

fail() {
  echo "[release-readiness-test][error] $*" >&2
  exit 1
}

tmp_dir="$(mktemp -d)"
tmp_dir="$(cd "$tmp_dir" && pwd -P)"
trap 'rm -rf "$tmp_dir"' EXIT

workspace="$tmp_dir/fearless"
parent="$tmp_dir"
report_dir="$workspace/build/reports/release-readiness"
bin_dir="$tmp_dir/bin"
SCENARIO_COUNT=0

write_file() {
  local file="$1"
  shift
  mkdir -p "$(dirname "$file")"
  printf '%s\n' "$@" > "$file"
}

write_fake_audit_script() {
  local file="$1"
  local fail_scenarios="$2"
  write_file "$file" \
    '#!/usr/bin/env bash' \
    'set -euo pipefail' \
    'scenario="${FAKE_RELEASE_SCENARIO:-good}"' \
    'state_dir="${FAKE_RELEASE_STATE_DIR:-${TMPDIR:-/tmp}}"' \
    'script_name="$(basename "$0")"' \
    'mkdir -p "$state_dir"' \
    'if [[ "$scenario:$script_name" == "github-transient:audit-github-governance.sh" ]]; then' \
    '  marker="$state_dir/$scenario-$script_name.count"' \
    '  count=0' \
    '  [[ -f "$marker" ]] && count="$(cat "$marker")"' \
    '  count=$((count + 1))' \
    '  printf "%s\n" "$count" > "$marker"' \
    '  if [[ "$count" -eq 1 ]]; then' \
    '    echo "transient GitHub API connection refused" >&2' \
    '    exit 1' \
    '  fi' \
    'fi' \
    'if [[ "$script_name" == "audit-plan-readiness.sh" && ( "$scenario" == "plan-unsafe-iroha-only" || "$scenario" == "plan-unmerged-iroha-only" || "$scenario" == "plan-unpublished-iroha-only" || "$scenario" == "plan-unpublished-iroha-postflight-continuity" || "$scenario" == "plan-unpublished-iroha-wrong-continuity-marker" || "$scenario" == "plan-unpublished-iroha-duplicate-continuity-marker" || "$scenario" == "plan-unpublished-iroha-reordered-continuity-marker" || "$scenario" == "plan-unpublished-iroha-continuity-marker-plus-extra" || "$scenario" == "plan-unpublished-iroha-legacy-v2" || "$scenario" == "plan-unpublished-iroha-wrong-report-phase" || "$scenario" == "plan-unpublished-iroha-wrong-preflight-digest" || "$scenario" == "plan-unpublished-iroha-missing-actual-proof" || "$scenario" == "plan-unpublished-iroha-forged-actual-proof" || "$scenario" == "plan-unpublished-iroha-mismatched-proof-failure" || "$scenario" == "plan-unpublished-iroha-missing-pr-head" || "$scenario" == "plan-unpublished-iroha-forged-pr-head" || "$scenario" == "plan-unpublished-iroha-missing-pr-diagnostic" || "$scenario" == "plan-unpublished-iroha-invalid-configured-ref-proof" || "$scenario" == "plan-unpublished-iroha-missing-ignored-diagnostic" || "$scenario" == "plan-unpublished-iroha-stale-current-diagnostic" || "$scenario" == "plan-unpublished-iroha-preflight-row-mismatch" || "$scenario" == plan-unpublished-iroha-drift* || "$scenario" == "plan-clean-iroha-only" || "$scenario" == "plan-forged-iroha-operation" || "$scenario" == "plan-forged-iroha-publication" ) ]]; then' \
    '  echo "[plan-readiness][warn] ../iroha unsafe external source contract missing" >&2' \
    '  echo "[plan-readiness][error] Plan readiness audit failed:" >&2' \
    '  echo "  - ../iroha unsafe external source contract missing" >&2' \
    '  echo "  - ../iroha browser artifact contract missing" >&2' \
    '  exit 1' \
    'fi' \
    'if [[ "$script_name" == "audit-plan-readiness.sh" && "$scenario" == "plan-mixed-failure" ]]; then' \
    '  echo "[plan-readiness][error] Plan readiness audit failed:" >&2' \
    '  echo "  - ../iroha unsafe external source contract missing" >&2' \
    '  echo "  - fearless-iOS maintained source contract missing" >&2' \
    '  exit 1' \
    'fi' \
    "case \",$fail_scenarios,\" in" \
    '  *,"$scenario",*)' \
    '    echo "$script_name failed for $scenario" >&2' \
    '    exit 1' \
    '    ;;' \
    'esac' \
    'echo "$script_name passed"'
  chmod +x "$file"
}

setup_fixture() {
  rm -rf "$workspace" "$parent/ton-indexer" "$parent/solswap-indexer" "$parent/polkaswap-indexer" "$report_dir" "$bin_dir"
  mkdir -p "$workspace/scripts" "$workspace/fearless-Android/scripts" "$workspace/fearless-iOS/scripts/deps" "$workspace/fearless-wallet-web/scripts" "$workspace/fearless-site-web-app-associations-20260726/scripts" "$workspace/services/passkey-backup-challenge-service" "$parent/ton-indexer" "$parent/solswap-indexer" "$parent/polkaswap-indexer" "$bin_dir"

  write_file "$bin_dir/date" \
    '#!/usr/bin/env bash' \
    'set -euo pipefail' \
    'script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"' \
    'state_file="$script_dir/.date-count"' \
    'count=0' \
    '[[ -f "$state_file" ]] && count="$(cat "$state_file")"' \
    'count=$((count + 1))' \
    'printf "%s\n" "$count" > "$state_file"' \
    'if [[ "$*" == *"+%Y-%m-%dT%H:%M:%SZ"* ]]; then' \
    '  printf "2026-06-28T00:00:%02dZ\n" "$count"' \
    'else' \
    '  exec /bin/date "$@"' \
    'fi'
  chmod +x "$bin_dir/date"

  write_file "$bin_dir/gh" \
    '#!/usr/bin/env bash' \
    'set -euo pipefail' \
    'echo "aggregate fixture gh must not be invoked directly" >&2' \
    'exit 97'
  chmod +x "$bin_dir/gh"

  write_file "$workspace/scripts/audit-passkey-enabled-acceptance.mjs" \
    'if (process.env.FAKE_RELEASE_SCENARIO === "passkey-enabled-acceptance-fail") { console.error("passkey enabled acceptance evidence missing"); process.exit(1) }' \
    'console.log("passkey enabled acceptance fixture passed")'
  write_fake_audit_script "$workspace/scripts/audit-plan-readiness.sh" "plan-fail,multi-fail"
  write_fake_audit_script "$workspace/scripts/audit-github-governance.sh" "github-fail,live-fail"
  write_fake_audit_script "$workspace/scripts/audit-release-pr-readiness.sh" "release-pr-fail,live-fail,multi-fail"
  write_fake_audit_script "$workspace/scripts/test-source-publication-readiness-audit.sh" "source-self-test-fail"
  write_file "$workspace/scripts/audit-source-publication-readiness.mjs" \
    '#!/usr/bin/env node' \
    'import crypto from "node:crypto"' \
    'import fs from "node:fs"' \
    'import path from "node:path"' \
    'const args = process.argv.slice(2)' \
    'const reportIndex = args.indexOf("--write-report")' \
    'const phaseIndex = args.indexOf("--phase")' \
    'const preflightIndex = args.indexOf("--preflight-report")' \
    'const phase = phaseIndex >= 0 ? args[phaseIndex + 1] : "standalone"' \
    'if (!args.includes("--check-remote") || reportIndex < 0 || !args[reportIndex + 1] || !["preflight", "postflight"].includes(phase) || (phase === "postflight" && (preflightIndex < 0 || !args[preflightIndex + 1]))) {' \
    '  console.error("source publication audit missing fail-closed live/report arguments")' \
    '  process.exit(2)' \
    '}' \
    'const scenario = process.env.FAKE_RELEASE_SCENARIO' \
    'const unsafeIroha = scenario === "plan-unsafe-iroha-only"' \
    'const unmergedIroha = scenario === "plan-unmerged-iroha-only"' \
    'const unpublishedIroha = scenario === "plan-unpublished-iroha-only"' \
    'const postflightContinuityIroha = scenario === "plan-unpublished-iroha-postflight-continuity"' \
    'const wrongContinuityMarker = scenario === "plan-unpublished-iroha-wrong-continuity-marker"' \
    'const duplicateContinuityMarker = scenario === "plan-unpublished-iroha-duplicate-continuity-marker"' \
    'const reorderedContinuityMarker = scenario === "plan-unpublished-iroha-reordered-continuity-marker"' \
    'const continuityMarkerPlusExtra = scenario === "plan-unpublished-iroha-continuity-marker-plus-extra"' \
    'const legacyPublication = scenario === "plan-unpublished-iroha-legacy-v2"' \
    'const wrongReportPhase = scenario === "plan-unpublished-iroha-wrong-report-phase"' \
    'const wrongPreflightDigest = scenario === "plan-unpublished-iroha-wrong-preflight-digest"' \
    'const missingActualProof = scenario === "plan-unpublished-iroha-missing-actual-proof"' \
    'const forgedActualProof = scenario === "plan-unpublished-iroha-forged-actual-proof"' \
    'const mismatchedProofFailure = scenario === "plan-unpublished-iroha-mismatched-proof-failure"' \
    'const missingPrHead = scenario === "plan-unpublished-iroha-missing-pr-head"' \
    'const forgedPrHead = scenario === "plan-unpublished-iroha-forged-pr-head"' \
    'const missingPrDiagnostic = scenario === "plan-unpublished-iroha-missing-pr-diagnostic"' \
    'const invalidConfiguredRefProof = scenario === "plan-unpublished-iroha-invalid-configured-ref-proof"' \
    'const missingIgnoredDiagnostic = scenario === "plan-unpublished-iroha-missing-ignored-diagnostic"' \
    'const staleCurrentDiagnostic = scenario === "plan-unpublished-iroha-stale-current-diagnostic"' \
    'const preflightRowMismatch = scenario === "plan-unpublished-iroha-preflight-row-mismatch"' \
    'const driftPublication = scenario.startsWith("plan-unpublished-iroha-drift")' \
    'const driftContinuityMarker = scenario === "plan-unpublished-iroha-drift-postflight-continuity"' \
    'const driftCurrentEqualsPr = scenario === "plan-unpublished-iroha-drift-current-equals-pr"' \
    'const driftMissingCurrentDiagnostic = scenario === "plan-unpublished-iroha-drift-missing-current-diagnostic"' \
    'const driftMissingCachedDiagnostic = scenario === "plan-unpublished-iroha-drift-missing-cached-diagnostic"' \
    'const driftReorderedDiagnostics = scenario === "plan-unpublished-iroha-drift-reordered-diagnostics"' \
    'const driftForgedCurrentDiagnostic = scenario === "plan-unpublished-iroha-drift-forged-current-diagnostic"' \
    'const driftForgedCachedDiagnostic = scenario === "plan-unpublished-iroha-drift-forged-cached-diagnostic"' \
    'const driftUnrelatedExtra = scenario === "plan-unpublished-iroha-drift-unrelated-extra"' \
    'const driftWrongContinuityMarker = scenario === "plan-unpublished-iroha-drift-wrong-continuity-marker"' \
    'const driftDuplicateContinuityMarker = scenario === "plan-unpublished-iroha-drift-duplicate-continuity-marker"' \
    'const driftContinuityMarkerPlusExtra = scenario === "plan-unpublished-iroha-drift-continuity-marker-plus-extra"' \
    'const driftCurrentEqualsLocal = scenario === "plan-unpublished-iroha-drift-current-equals-local"' \
    'const driftUpstreamDiffersFromLocal = scenario === "plan-unpublished-iroha-drift-upstream-differs-from-local"' \
    'const driftPrEqualsLocal = scenario === "plan-unpublished-iroha-drift-pr-equals-local"' \
    'const driftConfiguredRefPresent = scenario === "plan-unpublished-iroha-drift-configured-ref-present"' \
    'const driftConfiguredRefSha = scenario === "plan-unpublished-iroha-drift-configured-ref-sha"' \
    'const driftCurrentRefNotPresent = scenario === "plan-unpublished-iroha-drift-current-ref-not-present"' \
    'const driftNonzeroCount = scenario === "plan-unpublished-iroha-drift-nonzero-count"' \
    'const forgedIroha = scenario === "plan-forged-iroha-operation"' \
    'const forgedPublication = scenario === "plan-forged-iroha-publication"' \
    'const publicationIroha = unpublishedIroha || postflightContinuityIroha || wrongContinuityMarker || duplicateContinuityMarker || reorderedContinuityMarker || continuityMarkerPlusExtra || legacyPublication || wrongReportPhase || wrongPreflightDigest || missingActualProof || forgedActualProof || mismatchedProofFailure || missingPrHead || forgedPrHead || missingPrDiagnostic || invalidConfiguredRefProof || missingIgnoredDiagnostic || staleCurrentDiagnostic || preflightRowMismatch || driftPublication' \
    'const failed = scenario === "source-publication-fail" || unsafeIroha || unmergedIroha || publicationIroha || forgedIroha || forgedPublication' \
    'const operationFailure = unsafeIroha ? "repository has an in-progress Git merge operation (MERGE_HEAD); only the repository owner may complete or abort it before source publication" : "repository has an in-progress Git merge operation (FORGED_HEAD); only the repository owner may complete or abort it before source publication"' \
    'const unmergedFailure = "worktree is not clean (staged=0, unstaged=0, untracked=0, unmerged=2)"' \
    'const localSha = "e56af586b6d047c361e531d330424fb3067f57b2"' \
    'const prHeadSha = "e7a9e27691d6f34e2737d946af9b7f0768a31136"' \
    'const advancedCurrentBranchRemoteSha = "095afec25e64fdcf1d619c23a7e3b0a3906e7e8c"' \
    'const currentBranchRemoteSha = driftCurrentEqualsPr ? prHeadSha : driftPublication ? advancedCurrentBranchRemoteSha : localSha' \
    'const ignoredOutputFailure = "worktree contains ignored non-published paths (154): .cache/, .codex-target/, .playwright-cli/, .pytest_cache/, Cargo.lock, IrohaSwift/.build/, artifacts/js-sdk-bundle-size/, artifacts/python_fixture_regen_state.json; remove or quarantine these ignored outputs outside the source tree before publication; do not force-add generated artifacts"' \
    'const preflightContinuityFailure = "source publication preflight did not pass before release checks"' \
    'const canonicalPublicationFailures = [ignoredOutputFailure, "canonical branch exact-SHA review is blocked: optimizations requires a verifiable reviewed/protected policy"]' \
    'const canonicalDriftPublicationFailures = [ignoredOutputFailure, `local HEAD ${localSha} does not match authoritative remote head ${currentBranchRemoteSha}`, `cached upstream origin/optimizations at ${localSha} does not match authoritative current branch optimizations at ${currentBranchRemoteSha}`, "canonical branch exact-SHA review is blocked: optimizations requires a verifiable reviewed/protected policy"]' \
    'const publicationFailures = publicationIroha ? [...(driftPublication ? canonicalDriftPublicationFailures : canonicalPublicationFailures)] : ["current branch mismatch: expected codex/kagemusha-selector-hardening, received optimizations", "upstream mismatch: expected origin/codex/kagemusha-selector-hardening, received origin/forged"]' \
    'if (postflightContinuityIroha) publicationFailures.push(preflightContinuityFailure)' \
    'if (wrongContinuityMarker) publicationFailures.push("source publication preflight did not pass after release checks")' \
    'if (duplicateContinuityMarker) publicationFailures.push(preflightContinuityFailure, preflightContinuityFailure)' \
    'if (reorderedContinuityMarker) publicationFailures.unshift(preflightContinuityFailure)' \
    'if (continuityMarkerPlusExtra) publicationFailures.push(preflightContinuityFailure, "authoritative publication proof accepted by an unrelated forged diagnostic")' \
    'if (mismatchedProofFailure) publicationFailures[2] = `local HEAD ${localSha} does not match pull request head ${"d".repeat(40)}`' \
    'if (missingPrDiagnostic) publicationFailures.splice(1, 1)' \
    'if (missingIgnoredDiagnostic) publicationFailures[0] = "worktree contains ignored non-published paths (0): forged"' \
    'if (staleCurrentDiagnostic) publicationFailures.push(`local HEAD ${localSha} does not match authoritative current branch optimizations at ${currentBranchRemoteSha}`)' \
    'if (driftContinuityMarker) publicationFailures.push(preflightContinuityFailure)' \
    'if (driftMissingCurrentDiagnostic) publicationFailures.splice(1, 1)' \
    'if (driftMissingCachedDiagnostic) publicationFailures.splice(2, 1)' \
    'if (driftReorderedDiagnostics) [publicationFailures[1], publicationFailures[2]] = [publicationFailures[2], publicationFailures[1]]' \
    'if (driftForgedCurrentDiagnostic) publicationFailures[1] = `local HEAD ${localSha} does not match authoritative current branch optimizations at ${"d".repeat(40)}`' \
    'if (driftForgedCachedDiagnostic) publicationFailures[2] = `cached upstream origin/optimizations at ${localSha} does not match authoritative current branch optimizations at ${"d".repeat(40)}`' \
    'if (driftUnrelatedExtra) publicationFailures.push("authoritative publication proof accepted by an unrelated forged diagnostic")' \
    'if (driftWrongContinuityMarker) publicationFailures.push("source publication preflight did not pass after release checks")' \
    'if (driftDuplicateContinuityMarker) publicationFailures.push(preflightContinuityFailure, preflightContinuityFailure)' \
    'if (driftContinuityMarkerPlusExtra) publicationFailures.push(preflightContinuityFailure, "authoritative publication proof accepted by an unrelated forged diagnostic")' \
    'const publicationRow = {path:"../iroha",repository:"hyperledger-iroha/iroha",originUrl:"https://github.com/hyperledger-iroha/iroha.git",originRepository:"hyperledger-iroha/iroha",head:"optimizations",base:"optimizations",prNumber:null,prUrl:null,prState:null,repositoryPath:"/fixture/iroha",branch:"optimizations",upstream:"origin/optimizations",headSha:localSha,upstreamSha:localSha,prHeadSha:null,remoteHeadSha:currentBranchRemoteSha,remoteBranchPresent:true,currentBranchRemoteSha,currentBranchRemotePresent:true,status:"failed",stagedCount:0,unstagedCount:0,untrackedCount:0,unmergedCount:0,failures:publicationFailures}' \
    'if (missingActualProof) { publicationRow.currentBranchRemoteSha = null; publicationRow.currentBranchRemotePresent = null }' \
    'if (forgedActualProof) publicationRow.currentBranchRemoteSha = "d".repeat(40)' \
    'if (missingPrHead) publicationRow.prState = "merged"' \
    'if (forgedPrHead) publicationRow.prHeadSha = localSha' \
    'if (invalidConfiguredRefProof) { publicationRow.remoteBranchPresent = true; publicationRow.remoteHeadSha = "d".repeat(40) }' \
    'if (driftCurrentEqualsLocal) { publicationRow.currentBranchRemoteSha = localSha; publicationFailures[2] = `local HEAD ${localSha} does not match authoritative current branch optimizations at ${localSha}`; publicationFailures[5] = `cached upstream origin/optimizations at ${localSha} does not match authoritative current branch optimizations at ${localSha}` }' \
    'if (driftUpstreamDiffersFromLocal) { publicationRow.upstreamSha = "d".repeat(40); publicationFailures[5] = `cached upstream origin/optimizations at ${publicationRow.upstreamSha} does not match authoritative current branch optimizations at ${currentBranchRemoteSha}` }' \
    'if (driftCurrentEqualsPr) publicationRow.prHeadSha = prHeadSha' \
    'if (driftPrEqualsLocal) { publicationRow.prHeadSha = localSha; publicationFailures[3] = `local HEAD ${localSha} does not match pull request head ${localSha}` }' \
    'if (driftConfiguredRefPresent) publicationRow.remoteBranchPresent = false' \
    'if (driftConfiguredRefSha) publicationRow.remoteHeadSha = "d".repeat(40)' \
    'if (driftCurrentRefNotPresent) publicationRow.currentBranchRemotePresent = false' \
    'if (driftNonzeroCount) publicationRow.stagedCount = 1' \
    'if (forgedPublication) publicationRow.upstream = "origin/forged"' \
    'const operationRow = {...publicationRow,status:"failed",stagedCount:0,unstagedCount:0,untrackedCount:0,unmergedCount:unmergedIroha?2:0,failures:[unmergedIroha?unmergedFailure:operationFailure]}' \
    'const stablePaths = [".","fearless-Android","fearless-iOS","fearless-wallet-web","fearless-site-web-app-associations-20260726","../ton-indexer","../solswap-indexer","../polkaswap-indexer"]' \
    'const stableSource = (sourcePath, index) => ({path:sourcePath,repository:`example/source-${index}`,head:"main",base:"main",prNumber:index+1,prUrl:`https://github.com/example/source-${index}/pull/${index+1}`,prState:"merged",prHeadSha:localSha,repositoryPath:`/fixture/source-${index}`,originUrl:`https://github.com/example/source-${index}.git`,originRepository:`example/source-${index}`,branch:"main",headSha:localSha,upstream:"origin/main",upstreamSha:localSha,currentBranchRemoteSha:localSha,currentBranchRemotePresent:true,remoteHeadSha:localSha,remoteBranchPresent:true,status:"passed",stagedCount:0,unstagedCount:0,untrackedCount:0,unmergedCount:0,failures:[]})' \
    'const stableSources = stablePaths.map(stableSource)' \
    'if (preflightRowMismatch && phase === "postflight") stableSources[1].headSha = "c".repeat(40)' \
    'const ordinaryIrohaRow = stableSource("../iroha", 8)' \
    'const postflightIrohaRow = (publicationIroha || forgedPublication) ? publicationRow : (unsafeIroha || unmergedIroha || forgedIroha) ? operationRow : ordinaryIrohaRow' \
    'const failedPreflightIroha = postflightContinuityIroha || wrongContinuityMarker || duplicateContinuityMarker || reorderedContinuityMarker || continuityMarkerPlusExtra || driftContinuityMarker || driftWrongContinuityMarker || driftDuplicateContinuityMarker || driftContinuityMarkerPlusExtra' \
    'const preflightIrohaRow = {...postflightIrohaRow,status:failedPreflightIroha?"failed":"passed",stagedCount:0,unstagedCount:0,untrackedCount:0,unmergedCount:0,failures:failedPreflightIroha?[ignoredOutputFailure]:[]}' \
    'const currentIrohaRow = phase === "preflight" ? preflightIrohaRow : postflightIrohaRow' \
    'const workspaceSource = {...stableSources[0]}' \
    'if (scenario === "source-publication-fail" && phase === "postflight") { workspaceSource.status = "failed"; workspaceSource.failures = ["source publication fixture failure"] }' \
    'const repositories = [...stableSources.slice(1), currentIrohaRow]' \
    'const sources = [workspaceSource, ...repositories]' \
    'const sourceTotals = sources.reduce((totals, source) => { totals[source.status] += 1; totals.staged += source.stagedCount; totals.unstaged += source.unstagedCount; totals.untracked += source.untrackedCount; totals.unmerged += source.unmergedCount; return totals }, {passed:0,failed:0,staged:0,unstaged:0,untracked:0,unmerged:0})' \
    'const reportFailed = sourceTotals.failed > 0' \
    'const preflightBytes = phase === "postflight" ? fs.readFileSync(args[preflightIndex + 1]) : null' \
    'const preflightSha256 = preflightBytes ? crypto.createHash("sha256").update(preflightBytes).digest("hex") : null' \
    'const report = {schemaVersion:legacyPublication&&phase==="postflight"?2:3,phase:wrongReportPhase&&phase==="postflight"?"preflight":phase,preflightReportSha256:phase==="postflight"?(wrongPreflightDigest?"f".repeat(64):preflightSha256):null,generatedAt:phase==="preflight"?"2026-06-28T00:00:01Z":"2026-06-28T00:00:02Z",status:reportFailed?"failed":"passed",checkRemote:true,workspaceRoot:"/fixture/fearless",workspaceParent:"/fixture",configFile:"/fixture/source-publication-readiness.tsv",rootOwnerConfigFile:"/fixture/source-publication-root-owner.json",releasePrConfigFile:"/fixture/release-readiness-prs.tsv",totals:{sources:9,...sourceTotals},workspaceSource,repositories}' \
    'fs.mkdirSync(path.dirname(args[reportIndex + 1]), {recursive:true})' \
    'fs.writeFileSync(args[reportIndex + 1], JSON.stringify(report) + "\n")' \
    'if (reportFailed) {' \
    '  console.error("tested source is dirty or unpublished and root production source has no Git owner")' \
    '  process.exit(1)' \
    '}' \
    'console.log("source publication audit passed")'
  chmod +x "$workspace/scripts/audit-source-publication-readiness.mjs"
  write_file "$workspace/scripts/run-source-publication-readiness.sh" \
    '#!/usr/bin/env bash' \
    'set -euo pipefail' \
    'script_dir="$(cd "$(dirname "$0")" && pwd)"' \
    'exec node "$script_dir/audit-source-publication-readiness.mjs" "$@"'
  chmod +x "$workspace/scripts/run-source-publication-readiness.sh"
  write_fake_audit_script "$workspace/scripts/audit-private-overlay-readiness.sh" "overlay-fail"
  write_fake_audit_script "$workspace/scripts/audit-passkey-challenge-service.sh" "passkey-service-fail,multi-fail"
  write_fake_audit_script "$workspace/scripts/audit-passkey-backup-prerequisites.sh" "passkey-fail,multi-fail"
  write_fake_audit_script "$workspace/scripts/audit-iroha-release-readiness.sh" "iroha-fail,multi-fail"
  write_fake_audit_script "$workspace/scripts/audit-iroha-wallet-coverage.sh" "iroha-wallet-fail,multi-fail"

  write_file "$workspace/fearless-site-web-app-associations-20260726/scripts/verify-app-associations.mjs" \
    'import fs from "node:fs"' \
    'import path from "node:path"' \
    'import { fileURLToPath } from "node:url"' \
    'const siteRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..")' \
    'const args = process.argv.slice(2)' \
    'const rootMatches = args[1] && fs.realpathSync(args[1]) === fs.realpathSync(siteRoot)' \
    'if (args.length !== 4 || args[0] !== "--root" || !rootMatches || args[2] !== "--live-base-url" || args[3] !== "https://fearlesswallet.io") {' \
    '  console.error(`unexpected site verifier arguments: ${process.argv.slice(2).join(" ")}`)' \
    '  process.exit(2)' \
    '}' \
    'const buildDir = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../build")' \
    'fs.mkdirSync(buildDir, { recursive: true })' \
    'fs.writeFileSync(path.join(buildDir, "live-association-verifier-called"), "true\n")' \
    'if (process.env.FAKE_RELEASE_SCENARIO === "site-association-fail") {' \
    '  console.error("strict live app association verification failed: stale assetlinks/AASA or insecure response headers")' \
    '  process.exit(1)' \
    '}' \
    'console.log("strict live app association verification passed")'

  write_file "$workspace/scripts/test-passkey-android-origin-parity-audit.sh" \
    '#!/usr/bin/env bash' \
    'set -euo pipefail' \
    'scenario="${FAKE_RELEASE_SCENARIO:-good}"' \
    'if [[ "$scenario" == "passkey-origin-self-test-fail" ]]; then' \
    '  echo "passkey Android origin parity self-test failed" >&2' \
    '  exit 1' \
    'fi' \
    'echo "passkey Android origin parity self-test passed"'
  chmod +x "$workspace/scripts/test-passkey-android-origin-parity-audit.sh"

  write_file "$workspace/scripts/audit-passkey-android-origin-parity.sh" \
    '#!/usr/bin/env bash' \
    'set -euo pipefail' \
    'scenario="${FAKE_RELEASE_SCENARIO:-good}"' \
    'require_ready=false' \
    '[[ "$*" == *"--require-ready"* ]] && require_ready=true' \
    'if [[ "$scenario" == "passkey-origin-fail" ]]; then' \
    '  echo "passkey Android origin parity failed requireReady=$require_ready" >&2' \
    '  exit 1' \
    'fi' \
    'echo "passkey Android origin parity passed requireReady=$require_ready"'
  chmod +x "$workspace/scripts/audit-passkey-android-origin-parity.sh"

  write_file "$workspace/services/passkey-backup-challenge-service/scripts/audit-deployment-evidence.sh" \
    '#!/usr/bin/env bash' \
    'set -euo pipefail' \
    'echo "assertNoSecretLikeValues(data)"'
  chmod +x "$workspace/services/passkey-backup-challenge-service/scripts/audit-deployment-evidence.sh"

  write_file "$workspace/services/passkey-backup-challenge-service/scripts/test-deployment-evidence-audit.sh" \
    '#!/usr/bin/env bash' \
    'set -euo pipefail' \
    'echo "secret-like deployment evidence value"'
  chmod +x "$workspace/services/passkey-backup-challenge-service/scripts/test-deployment-evidence-audit.sh"

  write_file "$workspace/scripts/audit-nexus-production-evidence.sh" \
    '#!/usr/bin/env bash' \
    'set -euo pipefail' \
    'echo "assertNoSecretLikeValues(manifest)"'
  chmod +x "$workspace/scripts/audit-nexus-production-evidence.sh"

  write_file "$workspace/scripts/test-nexus-production-evidence-audit.sh" \
    '#!/usr/bin/env bash' \
    'set -euo pipefail' \
    'echo "secret-like Nexus evidence value"'
  chmod +x "$workspace/scripts/test-nexus-production-evidence-audit.sh"

  write_file "$workspace/fearless-Android/scripts/test-xcm-production-evidence-audit.sh" \
    '#!/usr/bin/env bash' \
    'set -euo pipefail' \
    'echo "secret-like XCM production evidence value"'
  chmod +x "$workspace/fearless-Android/scripts/test-xcm-production-evidence-audit.sh"

  write_file "$workspace/fearless-wallet-web/scripts/test-bitcoin-broadcast-evidence-audit.sh" \
    '#!/usr/bin/env bash' \
    'set -euo pipefail' \
    'echo "secret-like Bitcoin broadcast evidence value"'
  chmod +x "$workspace/fearless-wallet-web/scripts/test-bitcoin-broadcast-evidence-audit.sh"

  for repo in "$parent/ton-indexer" "$parent/solswap-indexer" "$parent/polkaswap-indexer"; do
    write_file "$repo/scripts/audit-deployment-evidence.sh" \
      '#!/usr/bin/env bash' \
      'set -euo pipefail' \
      'echo "secretLikeValueReason(manifest)"'
    chmod +x "$repo/scripts/audit-deployment-evidence.sh"

    write_file "$repo/scripts/test-deployment-evidence-audit.sh" \
      '#!/usr/bin/env bash' \
      'set -euo pipefail' \
      'echo "secret-like deployment evidence value"'
    chmod +x "$repo/scripts/test-deployment-evidence-audit.sh"
  done

  write_file "$workspace/scripts/generate-nexus-production-evidence-template.sh" \
    '#!/usr/bin/env bash' \
    'set -euo pipefail' \
    'output=""' \
    'while (($#)); do' \
    '  case "$1" in' \
    '    --output)' \
    '      output="$2"' \
    '      shift 2' \
    '      ;;' \
    '    *)' \
    '      shift' \
    '      ;;' \
    '  esac' \
    'done' \
    'template="$(mktemp)"' \
    'printf "%s\n" "{\"schemaVersion\":1,\"scope\":\"sora-nexus-production-readiness\",\"status\":\"ready\",\"releaseEnabled\":true}" > "$template"' \
    'if [[ -n "$output" ]]; then' \
    '  mkdir -p "$(dirname "$output")"' \
    '  cp "$template" "$output"' \
    'fi' \
    'cat "$template"'
  chmod +x "$workspace/scripts/generate-nexus-production-evidence-template.sh"

  write_file "$workspace/scripts/export-release-unblock-bundle.sh" \
    '#!/usr/bin/env bash' \
    'set -euo pipefail' \
    'output=""' \
    'report_dir=""' \
    'verifier=""' \
    'while (($#)); do' \
    '  case "$1" in' \
    '    --output)' \
    '      output="$2"' \
    '      shift 2' \
    '      ;;' \
    '    --report-dir)' \
    '      report_dir="$2"' \
    '      shift 2' \
    '      ;;' \
    '    --verify-with)' \
    '      verifier="$2"' \
    '      shift 2' \
    '      ;;' \
    '    *)' \
    '      shift' \
    '      ;;' \
    '  esac' \
    'done' \
    '[[ -n "$output" ]] || output="build/reports/release-readiness/unblock-bundle"' \
    '[[ -n "$report_dir" ]] || { echo "fake exporter missing report dir" >&2; exit 1; }' \
    '[[ -n "$verifier" && -x "$verifier" ]] || { echo "fake exporter missing canonical verifier" >&2; exit 1; }' \
    'final_output="$output"' \
    'staged_output="${output}.staging"' \
    'rm -rf "$staged_output"' \
    'output="$staged_output"' \
    'trap '\''rm -rf "$staged_output"'\'' EXIT' \
    'node - "$report_dir/actions.json" "$report_dir/android-xcm-effective-registry-report.json" <<'"'"'NODE'"'"'' \
    'const fs = require("fs")' \
    'const [actionsFile, reportFile] = process.argv.slice(2)' \
    'const actions = JSON.parse(fs.readFileSync(actionsFile, "utf8"))' \
    'const report = JSON.parse(fs.readFileSync(reportFile, "utf8"))' \
    'const expectedMode = actions.runLive ? "discovery" : "bundled"' \
    'const expectedUrl = "https://raw.githubusercontent.com/soramitsu/shared-features-utils/master/chains/v13/chains.json"' \
    'if (report.schemaVersion !== 1 || report.mode !== expectedMode || !["complete","incomplete"].includes(report.status)) throw new Error("fake exporter effective-registry mode/schema mismatch")' \
    'if (report.policy?.effectiveRouteMeaning !== "compatible-approved-candidate" || report.policy?.remoteExecutionTrusted !== false || report.policy?.productionTransfersEnabled !== false || report.policy?.runtimeDiscoveryRequiresSuccessfulProcessSync !== true || report.policy?.releaseDiscoveryUrl !== expectedUrl) throw new Error("fake exporter effective-registry policy mismatch")' \
    'if (actions.runLive && (report.inputs?.discoveryRegistry?.kind !== "https" || report.inputs?.discoveryRegistry?.source !== expectedUrl)) throw new Error("fake exporter live discovery mismatch")' \
    'if (!actions.runLive && report.inputs?.discoveryRegistry !== null) throw new Error("fake exporter bundled discovery must be null")' \
    'if (report.summary?.productionExecutable !== 0 || !Array.isArray(report.routes) || !Array.isArray(report.missing) || !Array.isArray(report.extra)) throw new Error("fake exporter effective-registry structure mismatch")' \
    'if (report.status === "complete" && (report.summary.approved !== report.summary.effective || report.summary.missing !== 0)) throw new Error("fake exporter complete effective-registry parity mismatch")' \
    'NODE' \
    'mkdir -p "$output/logs" "$output/handoffs"' \
    'cp "$report_dir/actions.json" "$output/actions.json"' \
    'cp "$report_dir/android-xcm-effective-registry-report.json" "$output/handoffs/android-xcm-effective-registry-report.json"' \
    'printf "%s\n" "{\"schemaVersion\":1,\"blockerCount\":0,\"artifacts\":[]}" > "$output/manifest.json"' \
    'printf "%s\n" "# Release Unblock Bundle" > "$output/unblock.md"' \
    'printf "%s\n" "#!/usr/bin/env bash" "echo fake verification" > "$output/verify-blockers.sh"' \
    'chmod +x "$output/verify-blockers.sh"' \
    'printf "%s\n" "bundle-checksum  manifest.json" > "$output/SHA256SUMS"' \
    '"$verifier" --bundle "$output" --published-path "$final_output"' \
    'rm -rf "$final_output"' \
    'mv "$output" "$final_output"' \
    'trap - EXIT' \
    'echo "fake release unblock bundle exported and verified to $final_output"'
  chmod +x "$workspace/scripts/export-release-unblock-bundle.sh"

  write_file "$workspace/scripts/verify-release-unblock-bundle.sh" \
    '#!/usr/bin/env bash' \
    'set -euo pipefail' \
    'scenario="${FAKE_RELEASE_SCENARIO:-good}"' \
    'bundle=""' \
    'published_path=""' \
    'while (($#)); do' \
    '  case "$1" in' \
    '    --bundle)' \
    '      bundle="$2"' \
    '      shift 2' \
    '      ;;' \
    '    --published-path)' \
    '      published_path="$2"' \
    '      shift 2' \
    '      ;;' \
    '    *)' \
    '      shift' \
    '      ;;' \
    '  esac' \
    'done' \
    'if [[ "$scenario" == "unblock-fail" ]]; then' \
    '  echo "fake release unblock bundle verification failed for $scenario" >&2' \
    '  exit 1' \
    'fi' \
    '[[ "$published_path" == "${bundle%.staging}" ]] || { echo "published bundle path does not match staged destination" >&2; exit 1; }' \
    '[[ -f "$bundle/manifest.json" ]] || { echo "manifest missing from $bundle" >&2; exit 1; }' \
    'node - "$bundle/actions.json" "$bundle/handoffs/android-xcm-effective-registry-report.json" <<'"'"'NODE'"'"'' \
    'const fs = require("fs")' \
    'const [actionsFile, reportFile] = process.argv.slice(2)' \
    'const actions = JSON.parse(fs.readFileSync(actionsFile, "utf8"))' \
    'const report = JSON.parse(fs.readFileSync(reportFile, "utf8"))' \
    'const expectedMode = actions.runLive ? "discovery" : "bundled"' \
    'const expectedUrl = "https://raw.githubusercontent.com/soramitsu/shared-features-utils/master/chains/v13/chains.json"' \
    'if (report.schemaVersion !== 1 || report.mode !== expectedMode || !["complete","incomplete"].includes(report.status)) throw new Error("fake verifier effective-registry mode/schema mismatch")' \
    'if (report.policy?.transactionAuthority !== "apk-approved-intersection" || report.policy?.effectiveRouteMeaning !== "compatible-approved-candidate" || report.policy?.remoteExecutionTrusted !== false || report.policy?.productionTransfersEnabled !== false || report.policy?.runtimeDiscoveryRequiresSuccessfulProcessSync !== true || report.policy?.runtimeDiscoverySnapshotBoundToReport !== false || report.policy?.runtimeDiscoveryFreshnessEnforced !== false || report.policy?.releaseDiscoveryUrl !== expectedUrl) throw new Error("fake verifier effective-registry policy mismatch")' \
    'if (actions.runLive && (report.inputs?.discoveryRegistry?.kind !== "https" || report.inputs?.discoveryRegistry?.source !== expectedUrl)) throw new Error("fake verifier live discovery mismatch")' \
    'if (!actions.runLive && report.inputs?.discoveryRegistry !== null) throw new Error("fake verifier bundled discovery must be null")' \
    'if (report.summary?.productionExecutable !== 0) throw new Error("fake verifier production executable mismatch")' \
    'NODE' \
    'echo "fake release unblock bundle verified: $bundle"'
  chmod +x "$workspace/scripts/verify-release-unblock-bundle.sh"

  write_file "$workspace/fearless-Android/scripts/ensure-fearless-utils.sh" \
    '#!/usr/bin/env bash' \
    'set -euo pipefail' \
    'scenario="${FAKE_RELEASE_SCENARIO:-good}"' \
    'expected_path="${PWD%/fearless-Android}/fearless-utils-Android"' \
    'if [[ "${FEARLESS_UTILS_PATH:-}" != "$expected_path" || "${FEARLESS_UTILS_COMMIT:-}" != "7500809f33243ee47ecb2ec8563fc284ac4de0d6" || "${FEARLESS_UTILS_REPOSITORY:-}" != "soramitsu/fearless-utils-Android" ]]; then' \
    '  echo "fearless-utils canonical identity was not pinned: path=${FEARLESS_UTILS_PATH:-<unset>} commit=${FEARLESS_UTILS_COMMIT:-<unset>} repository=${FEARLESS_UTILS_REPOSITORY:-<unset>}" >&2' \
    '  exit 1' \
    'fi' \
    'if [[ -f .force-provenance-fail ]]; then' \
    '  echo "fearless-utils provenance failed for forced fixture" >&2' \
    '  exit 1' \
    'fi' \
    'if [[ "${FEARLESS_UTILS_PATH:-}" == *"missing-fearless-utils"* ]]; then' \
    '  echo "fearless-utils provenance failed for missing checkout: ${FEARLESS_UTILS_PATH}" >&2' \
    '  exit 1' \
    'fi' \
    'case "$scenario" in' \
    '  android-provenance-fail|multi-fail)' \
    '    echo "fearless-utils provenance failed for $scenario" >&2' \
    '    exit 1' \
    '    ;;' \
    'esac' \
    'echo "fearless-utils canonical identity and provenance passed"'
  chmod +x "$workspace/fearless-Android/scripts/ensure-fearless-utils.sh"

  write_file "$workspace/fearless-Android/scripts/test-fearless-utils-derived-tree.sh" \
    '#!/usr/bin/env bash' \
    'set -euo pipefail' \
    'if [[ "${FAKE_RELEASE_SCENARIO:-good}" == "android-derived-tree-test-fail" ]]; then' \
    '  echo "fearless-utils derived-tree self-test failed" >&2' \
    '  exit 1' \
    'fi' \
    'echo "fearless-utils derived-tree self-test passed"'
  chmod +x "$workspace/fearless-Android/scripts/test-fearless-utils-derived-tree.sh"

  write_file "$workspace/fearless-Android/scripts/test-public-dependency-upstream-delta-export.sh" \
    '#!/usr/bin/env bash' \
    'set -euo pipefail' \
    'scenario="${FAKE_RELEASE_SCENARIO:-good}"' \
    'case "$scenario" in' \
    '  android-handoff-test-fail)' \
    '    echo "android public dependency handoff self-test failed for $scenario" >&2' \
    '    exit 1' \
    '    ;;' \
    'esac' \
    'echo "android public dependency handoff self-test passed"'
  chmod +x "$workspace/fearless-Android/scripts/test-public-dependency-upstream-delta-export.sh"

  write_file "$workspace/fearless-Android/scripts/export-public-dependency-upstream-delta.sh" \
    '#!/usr/bin/env bash' \
    'set -euo pipefail' \
    'scenario="${FAKE_RELEASE_SCENARIO:-good}"' \
    'case "$scenario" in' \
    '  android-handoff-fail)' \
    '    echo "android public dependency handoff export failed for $scenario" >&2' \
    '    exit 1' \
    '    ;;' \
    'esac' \
    'mkdir -p build/reports/public-dependency-upstream-delta' \
    'printf "%s\n" "{\"schemaVersion\":1}" > build/reports/public-dependency-upstream-delta/handoff-manifest.json' \
    'echo "android public dependency handoff export passed"'
  chmod +x "$workspace/fearless-Android/scripts/export-public-dependency-upstream-delta.sh"

  write_file "$workspace/fearless-Android/scripts/audit-public-artifacts.sh" \
    '#!/usr/bin/env bash' \
    'set -euo pipefail' \
    'scenario="${FAKE_RELEASE_SCENARIO:-good}"' \
    'strict_provenance=false' \
    'while (($#)); do' \
    '  case "$1" in' \
    '    --strict-provenance) strict_provenance=true ;;' \
    '    *) echo "unexpected Android public artifact audit argument: $1" >&2; exit 2 ;;' \
    '  esac' \
    '  shift' \
    'done' \
    'if [[ "$strict_provenance" != true ]]; then' \
    '  echo "Android public artifact strict provenance flag is required" >&2' \
    '  exit 1' \
    'fi' \
    'case "$scenario" in' \
    '  android-artifact-fail)' \
    '    echo "android public artifact audit failed for $scenario" >&2' \
    '    exit 1' \
    '    ;;' \
    'esac' \
    'echo "android public artifact strict provenance audit passed"'
  chmod +x "$workspace/fearless-Android/scripts/audit-public-artifacts.sh"

  write_file "$workspace/fearless-Android/scripts/audit-xcm-registry-metadata.sh" \
    '#!/usr/bin/env bash' \
    'set -euo pipefail' \
    'scenario="${FAKE_RELEASE_SCENARIO:-good}"' \
    'require_all_routes=false' \
    'write_gap_report=""' \
    'while (($#)); do' \
    '  case "$1" in' \
    '    --require-all-routes-executable)' \
    '      require_all_routes=true' \
    '      shift' \
    '      ;;' \
    '    --write-gap-report)' \
    '      write_gap_report="$2"' \
    '      shift 2' \
    '      ;;' \
    '    *)' \
    '      shift' \
    '      ;;' \
    '  esac' \
    'done' \
    'if [[ -n "$write_gap_report" ]]; then' \
    '  mkdir -p "$(dirname "$write_gap_report")"' \
    '  printf "%s\n" "{\"schemaVersion\":1}" > "$write_gap_report"' \
    'fi' \
    'if [[ "$scenario" == "xcm-registry-fail" || "$scenario" == "multi-fail" || ( "$scenario" == "live-fail" && "$require_all_routes" == true ) ]]; then' \
    '  echo "xcm registry metadata failed for $scenario requireAllRoutes=$require_all_routes" >&2' \
    '  exit 1' \
    'fi' \
    'echo "xcm registry metadata passed requireAllRoutes=$require_all_routes writeGapReport=${write_gap_report:-<none>}"'
  chmod +x "$workspace/fearless-Android/scripts/audit-xcm-registry-metadata.sh"

  write_file "$workspace/fearless-Android/scripts/test-xcm-effective-registry-audit.sh" \
    '#!/usr/bin/env bash' \
    'set -euo pipefail' \
    'scenario="${FAKE_RELEASE_SCENARIO:-good}"' \
    'if [[ "$scenario" == "xcm-effective-test-fail" ]]; then' \
    '  echo "xcm effective registry self-test failed for $scenario" >&2' \
    '  exit 1' \
    'fi' \
    'echo "xcm effective registry self-test passed"'
  chmod +x "$workspace/fearless-Android/scripts/test-xcm-effective-registry-audit.sh"

  write_file "$workspace/fearless-Android/scripts/audit-xcm-effective-registry.sh" \
    '#!/usr/bin/env bash' \
    'set -euo pipefail' \
    'scenario="${FAKE_RELEASE_SCENARIO:-good}"' \
    'require_all=false' \
    'write_report=""' \
    'discovery_url=""' \
    'while (($#)); do' \
    '  case "$1" in' \
    '    --require-all-approved)' \
    '      require_all=true' \
    '      shift' \
    '      ;;' \
    '    --write-report)' \
    '      write_report="$2"' \
    '      shift 2' \
    '      ;;' \
    '    --discovery-url)' \
    '      discovery_url="$2"' \
    '      shift 2' \
    '      ;;' \
    '    *)' \
    '      shift' \
    '      ;;' \
    '  esac' \
    'done' \
    'if [[ "$scenario" != "xcm-effective-report-missing" && -n "$write_report" ]]; then' \
    '  mkdir -p "$(dirname "$write_report")"' \
    '  mode="bundled"' \
    '  status="complete"' \
    '  effective=true' \
    '  [[ -n "$discovery_url" ]] && mode="discovery"' \
    '  if [[ "$scenario" == "xcm-effective-fail" || "$scenario" == "multi-fail" || ( "$scenario" == "live-fail" && "$require_all" == true ) ]]; then status="incomplete"; effective=false; fi' \
    '  node - "$write_report" "$mode" "$status" "$effective" "$discovery_url" "$scenario" <<'"'"'NODE'"'"'' \
    'const fs = require("fs")' \
    'const [file, mode, status, effectiveRaw, discoveryUrl, scenario] = process.argv.slice(2)' \
    'const effective = effectiveRaw === "true"' \
    'const route = {originChainId:"a".repeat(64),destinationChainId:"b".repeat(64),assetSymbol:"DOT",effective,productionExecutable:false,reasons:effective?[]:["not-discovered"]}' \
    'const identity = (source) => ({source,byteLength:1,sha256:"0".repeat(64)})' \
    'const report = {schemaVersion:1,mode,status,policy:{transactionAuthority:"apk-approved-intersection",effectiveRouteMeaning:"compatible-approved-candidate",remoteExecutionTrusted:false,productionTransfersEnabled:false,unapprovedDiscoveryRoutesExecutable:false,runtimeDiscoveryRole:"narrowing-advisory-only",runtimeDiscoveryStorage:"current-process-successful-sync-snapshot",runtimeDiscoveryRequiresSuccessfulProcessSync:true,runtimeDiscoverySnapshotBoundToReport:false,runtimeDiscoveryFreshnessEnforced:false,releaseDiscoveryUrl:"https://raw.githubusercontent.com/soramitsu/shared-features-utils/master/chains/v13/chains.json"},inputs:{approvedRoutes:identity("runtime/src/main/assets/approved_xcm_routes.tsv"),requiredRoutes:identity("scripts/xcm-required-routes.tsv"),bundledRegistry:identity("runtime/src/main/assets/local_chains.json"),discoveryRegistry:mode==="discovery"?{kind:"https",source:discoveryUrl,byteLength:1,sha256:"1".repeat(64)}:null},summary:{approved:1,required:1,bundledExecutable:1,discovered:effective?1:0,effective:effective?1:0,productionExecutable:0,missing:effective?0:1,extra:0},routes:[route],missing:effective?[]:[{originChainId:route.originChainId,destinationChainId:route.destinationChainId,assetSymbol:route.assetSymbol,reasons:route.reasons}],extra:[]}' \
    'if (scenario === "xcm-effective-report-policy-drift") report.policy.remoteExecutionTrusted = true' \
    'if (scenario === "xcm-effective-report-mode-drift") report.mode = "bundled"' \
    'fs.writeFileSync(file, JSON.stringify(report)+"\n")' \
    'NODE' \
    'fi' \
    'if [[ "$scenario" == "xcm-effective-fail" || "$scenario" == "multi-fail" || ( "$scenario" == "live-fail" && "$require_all" == true ) ]]; then' \
    '  echo "xcm effective registry failed for $scenario requireAll=$require_all discoveryUrl=${discovery_url:-<none>}" >&2' \
    '  exit 1' \
    'fi' \
    'echo "xcm effective registry passed requireAll=$require_all discoveryUrl=${discovery_url:-<none>}"'
  chmod +x "$workspace/fearless-Android/scripts/audit-xcm-effective-registry.sh"

  write_file "$workspace/fearless-Android/scripts/generate-xcm-production-evidence-template.sh" \
    '#!/usr/bin/env bash' \
    'set -euo pipefail' \
    'output=""' \
    'while (($#)); do' \
    '  case "$1" in' \
    '    --output)' \
    '      output="$2"' \
    '      shift 2' \
    '      ;;' \
    '    *)' \
    '      shift' \
    '      ;;' \
    '  esac' \
    'done' \
    '[[ -n "$output" ]] || { echo "missing output" >&2; exit 2; }' \
    'mkdir -p "$(dirname "$output")"' \
    'cat > "$output" <<JSON' \
    '{"schemaVersion":1,"scope":"android-xcm-production-evidence-template","requiredRouteCount":1,"evidence":[{"androidCommit":"TODO_android_release_commit"}]}' \
    'JSON' \
    'echo "xcm production evidence template generated at $output"'
  chmod +x "$workspace/fearless-Android/scripts/generate-xcm-production-evidence-template.sh"

  write_file "$workspace/fearless-iOS/scripts/deps/test-shared-features-delta-report.sh" \
    '#!/usr/bin/env bash' \
    'set -euo pipefail' \
    'scenario="${FAKE_RELEASE_SCENARIO:-good}"' \
    'if [[ "$scenario" == "ios-delta-test-fail" ]]; then' \
    '  echo "shared-features delta self-test failed for $scenario" >&2' \
    '  exit 1' \
    'fi' \
    'echo "shared-features delta self-test passed"'
  chmod +x "$workspace/fearless-iOS/scripts/deps/test-shared-features-delta-report.sh"

  write_file "$workspace/fearless-iOS/scripts/deps/audit-shared-features-delta-report.sh" \
    '#!/usr/bin/env bash' \
    'set -euo pipefail' \
    'scenario="${FAKE_RELEASE_SCENARIO:-good}"' \
    'report=""' \
    'require_ready=false' \
    'while (($#)); do' \
    '  case "$1" in' \
    '    --write-report)' \
    '      report="$2"' \
    '      shift 2' \
    '      ;;' \
    '    --require-ready)' \
    '      require_ready=true' \
    '      shift' \
    '      ;;' \
    '    *)' \
    '      shift' \
    '      ;;' \
    '  esac' \
    'done' \
    'if [[ "$scenario" == "ios-delta-fail" || "$scenario" == "multi-fail" ]]; then' \
    '  echo "shared-features delta audit failed for $scenario" >&2' \
    '  exit 1' \
    'fi' \
    'status="ready"' \
    'mutates=false' \
    'blockers="[]"' \
    'if [[ "$scenario" == "ios-delta-blocked" || "$require_ready" == false ]]; then' \
    '  status="blocked"' \
    '  mutates=true' \
    '  blockers="[\"checkout mutation remains\"]"' \
    'fi' \
    'if [[ -n "$report" ]]; then' \
    '  mkdir -p "$(dirname "$report")"' \
    '  printf "%s\n" "{\"schemaVersion\":1,\"mutatesResolvedCheckout\":${mutates},\"removalReadiness\":{\"status\":\"${status}\",\"blockers\":${blockers}}}" > "$report"' \
    'fi' \
    'if [[ "$require_ready" == true && "$status" != "ready" ]]; then' \
    '  echo "--require-ready rejected unresolved shared-features checkout mutation: removalReadiness.status must be ready, got $status" >&2' \
    '  exit 1' \
    'fi' \
    'echo "shared-features delta audit passed"'
  chmod +x "$workspace/fearless-iOS/scripts/deps/audit-shared-features-delta-report.sh"

  write_file "$workspace/fearless-Android/scripts/audit-xcm-production-evidence.sh" \
    '#!/usr/bin/env bash' \
    'set -euo pipefail' \
    'scenario="${FAKE_RELEASE_SCENARIO:-good}"' \
    'require_ready=false' \
    'effective_report=""' \
    'while (($#)); do' \
    '  case "$1" in' \
    '    --require-ready) require_ready=true; shift ;;' \
    '    --effective-registry-report) effective_report="$2"; shift 2 ;;' \
    '    *) shift ;;' \
    '  esac' \
    'done' \
    'if [[ "$scenario" == "xcm-fail" || "$scenario" == "multi-fail" || ( "$scenario" == "live-fail" && "$require_ready" == true ) ]]; then' \
    '  echo "xcm production evidence failed for $scenario requireReady=$require_ready" >&2' \
    '  exit 1' \
    'fi' \
    'if [[ "$require_ready" == true ]]; then' \
    '  [[ -n "$effective_report" && -f "$effective_report" ]] || { echo "ready XCM evidence requires the generated effective-registry report" >&2; exit 1; }' \
    '  node - "$effective_report" <<'"'"'NODE'"'"'' \
    'const fs = require("fs")' \
    'const report = JSON.parse(fs.readFileSync(process.argv[2], "utf8"))' \
    'const expectedUrl = "https://raw.githubusercontent.com/soramitsu/shared-features-utils/master/chains/v13/chains.json"' \
    'if (report.schemaVersion !== 1 || report.mode !== "discovery" || report.status !== "complete") throw new Error("ready XCM evidence effective-registry report must be live and complete")' \
    'if (report.policy?.effectiveRouteMeaning !== "compatible-approved-candidate" || report.policy?.remoteExecutionTrusted !== false || report.policy?.productionTransfersEnabled !== false || report.policy?.runtimeDiscoveryRequiresSuccessfulProcessSync !== true || report.policy?.releaseDiscoveryUrl !== expectedUrl) throw new Error("ready XCM evidence effective-registry policy mismatch")' \
    'if (report.inputs?.discoveryRegistry?.kind !== "https" || report.inputs?.discoveryRegistry?.source !== expectedUrl) throw new Error("ready XCM evidence discovery binding mismatch")' \
    'if (report.summary?.approved !== report.summary?.effective || report.summary?.missing !== 0 || report.summary?.productionExecutable !== 0) throw new Error("ready XCM evidence effective-route parity mismatch")' \
    'NODE' \
    'fi' \
    'echo "secretLikeValueReason(manifest)"' \
    'echo "xcm production evidence passed requireReady=$require_ready"'
  chmod +x "$workspace/fearless-Android/scripts/audit-xcm-production-evidence.sh"

  write_file "$workspace/fearless-wallet-web/scripts/audit-bitcoin-broadcast-evidence.sh" \
    '#!/usr/bin/env bash' \
    'set -euo pipefail' \
    'if [[ ${BITCOIN_BROADCAST_EVIDENCE_ROOT+x} == x ]]; then' \
    '  echo "aggregate leaked forbidden BITCOIN_BROADCAST_EVIDENCE_ROOT into Bitcoin evidence audit" >&2' \
    '  exit 2' \
    'fi' \
    'scenario="${FAKE_RELEASE_SCENARIO:-good}"' \
    'require_ready=false' \
    'for arg in "$@"; do' \
    '  [[ "$arg" == "--require-ready" ]] && require_ready=true' \
    'done' \
    'if [[ "$scenario" == "bitcoin-fail" || "$scenario" == "multi-fail" || ( "$scenario" == "live-fail" && "$require_ready" == true ) ]]; then' \
    '  echo "bitcoin broadcast evidence failed for $scenario requireReady=$require_ready" >&2' \
    '  exit 1' \
    'fi' \
    'echo "secretLikeValueReason(manifest)"' \
    'echo "bitcoin broadcast evidence passed requireReady=$require_ready"'
  chmod +x "$workspace/fearless-wallet-web/scripts/audit-bitcoin-broadcast-evidence.sh"

  write_file "$workspace/fearless-wallet-web/scripts/generate-bitcoin-broadcast-evidence-template.sh" \
    '#!/usr/bin/env bash' \
    'set -euo pipefail' \
    'if [[ ${BITCOIN_BROADCAST_EVIDENCE_ROOT+x} == x ]]; then' \
    '  echo "aggregate leaked forbidden BITCOIN_BROADCAST_EVIDENCE_ROOT into Bitcoin template generator" >&2' \
    '  exit 2' \
    'fi' \
    'output=""' \
    'while (($#)); do' \
    '  case "$1" in' \
    '    --)' \
    '      shift' \
    '      ;;' \
    '    --output)' \
    '      output="$2"' \
    '      shift 2' \
    '      ;;' \
    '    *)' \
    '      shift' \
    '      ;;' \
    '  esac' \
    'done' \
    'template="$(mktemp)"' \
    'cat > "$template" <<'"'"'JSON'"'"'' \
    '{"schemaVersion":1,"scope":"web-bitcoin-testnet-broadcast-readiness","status":"ready","releaseEnabled":true,"lastReviewed":"TODO_YYYY_MM_DD","blockers":[],"smokeCommand":"yarn test:smoke:bitcoin","readyVerificationCommands":["yarn test:bitcoin-broadcast-evidence-template","yarn generate:bitcoin-broadcast-evidence-template -- --output build/reports/bitcoin-broadcast-evidence-template.json","yarn test:bitcoin-broadcast-evidence-audit","yarn audit:bitcoin-broadcast-evidence --require-ready","FEARLESS_BITCOIN_TESTNET_LIVE=1 yarn test:smoke:bitcoin"],"liveSmokeEnvironment":["FEARLESS_BITCOIN_TESTNET_LIVE","FEARLESS_BITCOIN_TESTNET_MNEMONIC","FEARLESS_BITCOIN_TESTNET_SOURCE_ADDRESS","FEARLESS_BITCOIN_TESTNET_RECIPIENT_ADDRESS","FEARLESS_BITCOIN_TESTNET_AMOUNT_SAT","FEARLESS_BITCOIN_TESTNET_OUTPOINT"],"defaultIndexerUrl":"https://blockstream.info/testnet/api","requiredEvidenceFields":["txid","sourceAddress","recipientAddress","amountSat","outpoint","indexerUrl","timestamp","operator","commit"],"evidence":[{"txid":"TODO_64_HEX_TESTNET_TXID","sourceAddress":"TODO_TESTNET_SOURCE_TB1Q_ADDRESS","recipientAddress":"TODO_TESTNET_RECIPIENT_TB1Q_ADDRESS","amountSat":"TODO_POSITIVE_INTEGER_SATS","outpoint":"TODO_64_HEX_FUNDING_TXID:TODO_VOUT","indexerUrl":"https://blockstream.info/testnet/api","timestamp":"TODO_UTC_TIMESTAMP_SECONDS","operator":"TODO_RELEASE_OPERATOR","commit":"TODO_40_HEX_GIT_COMMIT"}]}' \
    'JSON' \
    'if [[ -n "$output" ]]; then' \
    '  mkdir -p "$(dirname "$output")"' \
    '  cp "$template" "$output"' \
    'fi' \
    'cat "$template"'
  chmod +x "$workspace/fearless-wallet-web/scripts/generate-bitcoin-broadcast-evidence-template.sh"

  write_file "$bin_dir/npm" \
    '#!/usr/bin/env bash' \
    'set -euo pipefail' \
    'scenario="${FAKE_RELEASE_SCENARIO:-good}"' \
    'repo="$(basename "$PWD")"' \
    'args="$*"' \
    'runner="$(basename "$0")"' \
    'if [[ "$repo" == "polkaswap-indexer" && "$runner" != "yarn" ]]; then' \
    '  echo "polkaswap-indexer checks must use Yarn, received $runner" >&2' \
    '  exit 2' \
    'fi' \
    'if [[ "$repo" != "polkaswap-indexer" && "$runner" == "yarn" ]]; then' \
    '  echo "$repo checks must not use the PI Yarn runner" >&2' \
    '  exit 2' \
    'fi' \
    'require_ready=false' \
    '[[ "$args" == *"--require-ready"* ]] && require_ready=true' \
    'if [[ "$args" == run\ generate:deployment-evidence-template* || "$args" == generate:deployment-evidence-template* ]]; then' \
    '  output=""' \
    '  while (($#)); do' \
    '    case "$1" in' \
    '      --output)' \
    '        output="$2"' \
    '        shift 2' \
    '        ;;' \
    '      *)' \
    '        shift' \
    '        ;;' \
    '    esac' \
    '  done' \
    '  template="$(mktemp)"' \
    '  case "$repo" in' \
    '    passkey-backup-challenge-service)' \
    '      cat > "$template" <<'"'"'JSON'"'"'' \
    '{"schemaVersion":1,"scope":"passkey-backup-challenge-service-production-deployment-readiness","service":"fearless-passkey-backup","rpId":"fearlesswallet.io","baseUrl":"https://backup.fearlesswallet.io","healthUrl":"https://backup.fearlesswallet.io/api/passkey-backup/v1/health","imageName":"passkey-backup-challenge-service","port":8789,"credentialStoreVolume":"/data/passkey-backup","credentialStoreFile":"/data/passkey-backup/credentials.json","status":"ready","releaseEnabled":true,"blockers":[],"dockerBuildCommand":"docker build -t passkey-backup-challenge-service:release .","smokeCommand":"PASSKEY_BACKUP_BASE_URL=https://backup.fearlesswallet.io PASSKEY_BACKUP_SMOKE_GRANT_HELPER=/run/secrets/passkey-smoke-grant-helper PASSKEY_BACKUP_SMOKE_TIMEOUT_MS=10000 npm run smoke:production","requiredCommands":["npm run lint:syntax","npm test","npm run test:deployment-evidence-template","npm run generate:deployment-evidence-template -- --output build/reports/production-deployment-evidence-template.json","npm run test:deployment-evidence-audit","npm run audit:deployment-evidence","docker build -t passkey-backup-challenge-service:release .","PASSKEY_BACKUP_LIVE_HEALTH=1 PASSKEY_BACKUP_HEALTH_TIMEOUT_SECONDS=10 bash ../../scripts/audit-passkey-backup-prerequisites.sh","PASSKEY_BACKUP_BASE_URL=https://backup.fearlesswallet.io PASSKEY_BACKUP_SMOKE_GRANT_HELPER=/run/secrets/passkey-smoke-grant-helper PASSKEY_BACKUP_SMOKE_TIMEOUT_MS=10000 npm run smoke:production","npm run audit:deployment-evidence -- --require-ready"],"requiredEvidenceFields":["imageDigest","deploymentId","deployedCommit","deployedAt","operator","smokePassedAt","smokeCommand","healthUrl","healthResponse","credentialStoreVolume","credentialStoreFile","webauthnAllowedOrigins","requestAccessPolicy","trustedProxyPolicy","platformProvisioning"],"deploymentEvidence":[{"imageDigest":"sha256:TODO_64_HEX_IMAGE_DIGEST","deploymentId":"TODO_PRODUCTION_DEPLOYMENT_ID","deployedCommit":"TODO_40_HEX_GIT_COMMIT","deployedAt":"TODO_UTC_DEPLOYED_AT_SECONDS","operator":"TODO_RELEASE_OPERATOR","smokePassedAt":"TODO_UTC_SMOKE_TIMESTAMP_SECONDS","smokeCommand":"PASSKEY_BACKUP_BASE_URL=https://backup.fearlesswallet.io PASSKEY_BACKUP_SMOKE_GRANT_HELPER=/run/secrets/passkey-smoke-grant-helper PASSKEY_BACKUP_SMOKE_TIMEOUT_MS=10000 npm run smoke:production","healthUrl":"https://backup.fearlesswallet.io/api/passkey-backup/v1/health","healthResponse":{"ok":true,"service":"fearless-passkey-backup","rpId":"fearlesswallet.io","schemaVersion":1},"credentialStoreVolume":"/data/passkey-backup","credentialStoreFile":"/data/passkey-backup/credentials.json","webauthnAllowedOrigins":["https://fearlesswallet.io","https://backup.fearlesswallet.io","android:apk-key-hash:TODO_RELEASE_CERT_SHA256_BASE64URL"],"requestAccessPolicy":{"introspectionUrl":"https://TODO_WALLET_OWNER_AUTHORITY/v1/passkey/consume","audience":"fearless-passkey-backup","mode":"atomic-one-time-consume","allPostRoutesProtected":true,"stableCrossPlatformWalletSubject":true,"authorizedSmokePassed":true,"noRawSubjectPersisted":true},"trustedProxyPolicy":{"hops":1,"forwardedHeader":"X-Forwarded-For","directPeerAllowlistConfigured":true,"incomingHeaderSanitized":true,"directPublicAccessBlocked":true,"adversarialProxyTestsPassed":true},"platformProvisioning":{"androidGoogleDriveConsent":true,"androidReleaseFlagDisabled":true,"iosAssociatedDomain":true,"iosCloudKitProductionSchema":true,"iosReleaseFlagDisabled":true}}]}' \
    'JSON' \
    '      ;;' \
    '    ton-indexer)' \
    '      cat > "$template" <<'"'"'JSON'"'"'' \
    '{"schemaVersion":1,"scope":"ton-indexer-production-deployment-readiness","serviceId":"ti.soramitsu.io","baseUrl":"https://ti.soramitsu.io","status":"ready","releaseEnabled":true,"lastReviewed":"TODO_YYYY_MM_DD","blockers":[],"smokeCommand":"TON_INDEXER_BASE_URL=https://ti.soramitsu.io npm run smoke:production","dockerBuildCommand":"docker build -t ton-indexer:release .","readyVerificationCommands":["npm run test:deployment-evidence-template","npm run generate:deployment-evidence-template -- --output build/reports/production-deployment-evidence-template.json","npm run test:deployment-evidence-audit","npm run audit:deployment-evidence -- --require-ready","docker build -t ton-indexer:release .","TON_INDEXER_BASE_URL=https://ti.soramitsu.io npm run smoke:production"],"requiredEvidenceFields":["commit","imageDigest","deploymentId","baseUrl","smokeCommand","deployedAt","smokePassedAt","serviceInfo","healthInfo","operator"],"deploymentEvidence":[{"commit":"TODO_40_HEX_GIT_COMMIT","imageDigest":"sha256:TODO_64_HEX_IMAGE_DIGEST","deploymentId":"TODO_PRODUCTION_DEPLOYMENT_ID","baseUrl":"https://ti.soramitsu.io","smokeCommand":"TON_INDEXER_BASE_URL=https://ti.soramitsu.io npm run smoke:production","deployedAt":"TODO_UTC_DEPLOYED_AT_SECONDS","smokePassedAt":"TODO_UTC_SMOKE_TIMESTAMP_SECONDS","serviceInfo":{"schemaVersion":1,"serviceId":"ti.soramitsu.io","ecosystem":"ton","chainId":"ton:mainnet","network":"mainnet","publicBaseUrl":"https://ti.soramitsu.io","readOnly":true,"endpoints":{"openapi":"/api/indexer/v1/openapi.json"}},"healthInfo":{"serviceId":"ti.soramitsu.io","ecosystem":"ton","chainId":"ton:mainnet","network":"mainnet","lastMasterSeqno":"TODO_LAST_MASTER_SEQNO"},"operator":"TODO_RELEASE_OPERATOR"}]}' \
    'JSON' \
    '      ;;' \
    '    solswap-indexer)' \
    '      cat > "$template" <<'"'"'JSON'"'"'' \
    '{"schemaVersion":1,"scope":"solswap-indexer-production-deployment-readiness","serviceId":"si.soramitsu.io","baseUrl":"https://si.soramitsu.io","status":"ready","releaseEnabled":true,"lastReviewed":"TODO_YYYY_MM_DD","blockers":[],"smokeCommand":"SOLSWAP_INDEXER_BASE_URL=https://si.soramitsu.io npm run smoke:production","dockerBuildCommand":"docker build -t solswap-indexer:release .","readyVerificationCommands":["npm run test:deployment-evidence-template","npm run generate:deployment-evidence-template -- --output build/reports/production-deployment-evidence-template.json","npm run test:deployment-evidence-audit","npm run audit:deployment-evidence -- --require-ready","docker build -t solswap-indexer:release .","SOLSWAP_INDEXER_BASE_URL=https://si.soramitsu.io npm run smoke:production"],"requiredEvidenceFields":["commit","imageDigest","deploymentId","baseUrl","smokeCommand","deployedAt","smokePassedAt","serviceInfo","healthInfo","operator"],"deploymentEvidence":[{"commit":"TODO_40_HEX_GIT_COMMIT","imageDigest":"sha256:TODO_64_HEX_IMAGE_DIGEST","deploymentId":"TODO_PRODUCTION_DEPLOYMENT_ID","baseUrl":"https://si.soramitsu.io","smokeCommand":"SOLSWAP_INDEXER_BASE_URL=https://si.soramitsu.io npm run smoke:production","deployedAt":"TODO_UTC_DEPLOYED_AT_SECONDS","smokePassedAt":"TODO_UTC_SMOKE_TIMESTAMP_SECONDS","serviceInfo":{"schemaVersion":1,"serviceId":"si.soramitsu.io","ecosystem":"solana","chainId":"solana:mainnet","network":"mainnet","publicBaseUrl":"https://si.soramitsu.io","readOnly":true,"endpoints":{"openapi":"/api/indexer/v1/openapi.json"}},"healthInfo":{"ok":true,"serviceId":"si.soramitsu.io","ecosystem":"solana","chainId":"solana:mainnet","network":"mainnet"},"operator":"TODO_RELEASE_OPERATOR"}]}' \
    'JSON' \
    '      ;;' \
    '    polkaswap-indexer)' \
    '      cat > "$template" <<'"'"'JSON'"'"'' \
    '{"schemaVersion":1,"scope":"polkaswap-indexer-production-deployment-readiness","serviceId":"pi.soramitsu.io","baseUrl":"https://pi.soramitsu.io/graphql","status":"blocked","releaseEnabled":false,"lastReviewed":"2026-07-13","blockers":["production-deployment-evidence-missing","live-production-smoke-failing"],"smokeCommand":"POLKASWAP_INDEXER_BASE_URL=https://pi.soramitsu.io/graphql yarn smoke:production","dockerBuildCommand":"docker build -t polkaswap-indexer:release .","readyVerificationCommands":["yarn test:deployment-evidence-template","yarn generate:deployment-evidence-template --output build/reports/production-deployment-evidence-template.json","yarn test:deployment-evidence-audit","yarn audit:deployment-evidence --require-ready","docker build -t polkaswap-indexer:release .","POLKASWAP_INDEXER_BASE_URL=https://pi.soramitsu.io/graphql yarn smoke:production"],"requiredEvidenceFields":["commit","imageDigest","deploymentId","baseUrl","smokeCommand","deployedAt","smokePassedAt","healthInfo","soraRpcControls","tlsEdgeControls","operator"],"deploymentEvidence":[{"commit":"TODO_40_HEX_GIT_COMMIT","imageDigest":"sha256:TODO_64_HEX_IMAGE_DIGEST","deploymentId":"TODO_PRODUCTION_DEPLOYMENT_ID","baseUrl":"https://pi.soramitsu.io/graphql","smokeCommand":"POLKASWAP_INDEXER_BASE_URL=https://pi.soramitsu.io/graphql yarn smoke:production","deployedAt":"TODO_UTC_DEPLOYED_AT_SECONDS","smokePassedAt":"TODO_UTC_SMOKE_TIMESTAMP_SECONDS","healthInfo":{"ok":true,"service":"polkaswap-indexer","serviceId":"pi.soramitsu.io","schemaVersion":1,"ecosystem":"sora2","chainId":"sora:mainnet","network":"mainnet","publicBaseUrl":"https://pi.soramitsu.io/graphql","readOnly":true,"genesisHash":"0x7e4e32d0feafd4f9c9414b0be86373f9a1efa904809b683453a9af6856d38ad5","latestIndexedBlock":"TODO_POSITIVE_SAFE_INTEGER_INDEXED_BLOCK","latestIndexedBlockHash":"TODO_0X_64_LOWERCASE_HEX_INDEXED_BLOCK_HASH","latestIndexedAt":"TODO_UNIX_SECONDS_WITHIN_300_BEFORE_OR_30_AFTER_SMOKE"},"soraRpcControls":{"primaryEndpoint":"TODO_CANONICAL_WSS_LOCALLY_CONTROLLED_PRIMARY_RPC_ENDPOINT","archiveEndpoint":"TODO_CANONICAL_WSS_INDEPENDENT_ARCHIVE_RPC_ENDPOINT","primaryNodeControl":"locally-controlled-verifying-archive","archiveNodeControl":"independently-operated-verifying-archive","distinctHosts":true,"exactIdentityPreflight":true,"rawPayloadAgreement":"height-hash-scale-block-events-timestamp"},"tlsEdgeControls":{"tlsTermination":true,"forwardedClientIpHeaders":"overwrite","httpClientIpRateLimit":{"windowMs":60000,"maxRequests":600},"webSocketClientIpLimits":{"windowMs":60000,"maxUpgrades":600,"maxConcurrentConnections":16}},"operator":"TODO_RELEASE_OPERATOR"}]}' \
    'JSON' \
    '      ;;' \
    '    *)' \
    '      echo "unsupported deployment evidence template repo: $repo" >&2' \
    '      exit 1' \
    '      ;;' \
    '  esac' \
    '  if [[ -n "$output" ]]; then' \
    '    mkdir -p "$(dirname "$output")"' \
    '    cp "$template" "$output"' \
    '  fi' \
    '  cat "$template"' \
    '  exit 0' \
    'fi' \
    'if [[ "$args" == run\ audit:deployment-evidence* || "$args" == audit:deployment-evidence* ]]; then' \
    '  if [[ "$repo" == passkey-backup-challenge-service && "$require_ready" == true ]]; then' \
    '    expected_gh="$(cd "$(dirname "$0")" && pwd -P)/gh"' \
    '    [[ "${PASSKEY_DEPLOYMENT_GH_BIN:-}" == "$expected_gh" ]] || {' \
    '      echo "passkey ready evidence must receive the root authenticated gh authority" >&2' \
    '      exit 2' \
    '    }' \
    '  fi' \
    '  case "$scenario:$repo" in' \
    '    passkey-deployment-fail:passkey-backup-challenge-service|multi-fail:passkey-backup-challenge-service)' \
    '      echo "passkey deployment evidence failed for $scenario requireReady=$require_ready" >&2' \
    '      exit 1' \
    '      ;;' \
    '    ton-deployment-fail:ton-indexer|multi-fail:ton-indexer)' \
    '      echo "ton-indexer deployment evidence failed for $scenario requireReady=$require_ready" >&2' \
    '      exit 1' \
    '      ;;' \
    '    solswap-deployment-fail:solswap-indexer|multi-fail:solswap-indexer)' \
    '      echo "solswap-indexer deployment evidence failed for $scenario requireReady=$require_ready" >&2' \
    '      exit 1' \
    '      ;;' \
    '    polkaswap-deployment-fail:polkaswap-indexer|multi-fail:polkaswap-indexer)' \
    '      echo "polkaswap-indexer deployment evidence failed for $scenario requireReady=$require_ready" >&2' \
    '      exit 1' \
    '      ;;' \
    '    live-fail:passkey-backup-challenge-service|live-fail:ton-indexer|live-fail:solswap-indexer|live-fail:polkaswap-indexer)' \
    '      if [[ "$require_ready" == true ]]; then' \
    '        echo "$repo deployment evidence failed for live-fail requireReady=$require_ready" >&2' \
    '        exit 1' \
    '      fi' \
    '      ;;' \
    '  esac' \
    '  echo "$repo deployment evidence passed requireReady=$require_ready runner=$runner"' \
    '  exit 0' \
    'fi' \
    'if [[ "$repo" == passkey-backup-challenge-service && "$args" == *"smoke:production"* ]]; then' \
    '  for transport_variable in NODE_TLS_REJECT_UNAUTHORIZED NODE_EXTRA_CA_CERTS NODE_USE_ENV_PROXY NODE_USE_SYSTEM_CA OPENSSL_CONF SSL_CERT_FILE SSL_CERT_DIR HTTP_PROXY HTTPS_PROXY ALL_PROXY NO_PROXY http_proxy https_proxy all_proxy no_proxy NODE_PATH; do' \
    '    [[ -z "${!transport_variable+x}" ]] || {' \
    '      echo "passkey production smoke inherited forbidden Node TLS/proxy/CA environment: $transport_variable" >&2' \
    '      exit 2' \
    '    }' \
    '  done' \
    '  [[ "${HOME:-}" == /var/empty && "${XDG_CONFIG_HOME:-}" == /var/empty && "${NPM_CONFIG_USERCONFIG:-}" == /dev/null && "${npm_config_userconfig:-}" == /dev/null && "${NPM_CONFIG_GLOBALCONFIG:-}" == /dev/null && "${npm_config_globalconfig:-}" == /dev/null && "${NODE_OPTIONS+x}" == x && -z "$NODE_OPTIONS" ]] || {' \
    '    echo "passkey production smoke must isolate Node and npm configuration" >&2' \
    '    exit 2' \
    '  }' \
    '  [[ "${PASSKEY_BACKUP_SMOKE_GRANT_HELPER:-}" == /run/secrets/passkey-smoke-grant-helper && "${PASSKEY_BACKUP_SMOKE_TIMEOUT_MS:-}" == 10000 && "${PASSKEY_BACKUP_SMOKE_MAX_RESPONSE_BYTES:-}" == 1048576 && "${PASSKEY_BACKUP_SMOKE_GRANT_HELPER_TIMEOUT_MS:-}" == 2000 ]] || {' \
    '    echo "passkey production smoke must use the canonical helper, timeout, response-size, and isolated Node TLS/proxy/CA environment" >&2' \
    '    exit 2' \
    '  }' \
    'fi' \
    'if [[ "$repo" == ton-indexer && "$args" == *"smoke:production"* ]]; then' \
    '  [[ "${TON_INDEXER_SMOKE_TIMEOUT_MS:-}" == 10000 && "${TON_INDEXER_SMOKE_MAX_RESPONSE_BYTES:-}" == 1048576 && "${TON_INDEXER_SMOKE_MAX_HEALTH_LAG_SEC:-}" == 300 ]] || {' \
    '    echo "TI production smoke must use the canonical timeout, response-size, and health-lag limits" >&2' \
    '    exit 2' \
    '  }' \
    'fi' \
    'if [[ "$repo" == solswap-indexer && "$args" == *"smoke:production"* ]]; then' \
    '  [[ "${SOLSWAP_INDEXER_SMOKE_TIMEOUT_MS:-}" == 10000 && "${SOLSWAP_INDEXER_SMOKE_MAX_RESPONSE_BYTES:-}" == 1048576 && "${SOLSWAP_INDEXER_SMOKE_MAX_HEALTH_AGE_SEC:-}" == 120 ]] || {' \
    '    echo "SI production smoke must use the canonical timeout, response-size, and health-age limits" >&2' \
    '    exit 2' \
    '  }' \
    'fi' \
    'if [[ "$repo" == polkaswap-indexer && "$args" == *"smoke:production"* ]]; then' \
    '  [[ "${POLKASWAP_INDEXER_SMOKE_TIMEOUT_MS:-}" == 10000 && "${POLKASWAP_INDEXER_SMOKE_MAX_RESPONSE_BYTES:-}" == 1048576 && "${POLKASWAP_INDEXER_SMOKE_MAX_INDEXER_AGE_SEC:-}" == 300 ]] || {' \
    '    echo "PI production smoke must use the canonical timeout, response-size, and indexer-age limits" >&2' \
    '    exit 2' \
    '  }' \
    'fi' \
    'case "$scenario:$repo" in' \
    '  passkey-smoke-fail:passkey-backup-challenge-service|live-fail:passkey-backup-challenge-service|multi-fail:passkey-backup-challenge-service)' \
    '    echo "passkey production smoke failed for $scenario" >&2' \
    '    exit 1' \
    '    ;;' \
    '  ton-fail:ton-indexer|live-fail:ton-indexer|multi-fail:ton-indexer)' \
    '    echo "ton smoke failed for $scenario" >&2' \
    '    exit 1' \
    '    ;;' \
    '  solswap-fail:solswap-indexer|live-fail:solswap-indexer)' \
    '    echo "solswap smoke failed for $scenario" >&2' \
    '    exit 1' \
    '    ;;' \
    '  polkaswap-fail:polkaswap-indexer|live-fail:polkaswap-indexer)' \
    '    echo "polkaswap smoke failed for $scenario" >&2' \
    '    exit 1' \
    '    ;;' \
    'esac' \
    'echo "$repo smoke passed runner=$runner"'
  chmod +x "$bin_dir/npm"
  ln -s npm "$bin_dir/yarn"
}

run_audit() {
  local scenario="$1"
  shift
  FAKE_RELEASE_SCENARIO="$scenario" \
    FAKE_RELEASE_STATE_DIR="$tmp_dir/state" \
    RELEASE_READINESS_TEST_MODE=1 \
    RELEASE_READINESS_ROOT="$workspace" \
    RELEASE_READINESS_PARENT="$parent" \
    RELEASE_READINESS_REPORT_DIR="$report_dir" \
    RELEASE_READINESS_NETWORK_RETRY_DELAY_SECONDS=0 \
    FEARLESS_UTILS_PATH="${TEST_AMBIENT_FEARLESS_UTILS_PATH:-$parent/fearless-utils-Android}" \
    FEARLESS_UTILS_COMMIT="${TEST_AMBIENT_FEARLESS_UTILS_COMMIT:-7500809f33243ee47ecb2ec8563fc284ac4de0d6}" \
    FEARLESS_UTILS_REPOSITORY="${TEST_AMBIENT_FEARLESS_UTILS_REPOSITORY:-soramitsu/fearless-utils-Android}" \
    PASSKEY_BACKUP_SMOKE_MAX_RESPONSE_BYTES=5242880 \
    PASSKEY_BACKUP_SMOKE_GRANT_HELPER_TIMEOUT_MS=10000 \
    TON_INDEXER_SMOKE_TIMEOUT_MS=60000 \
    TON_INDEXER_SMOKE_MAX_RESPONSE_BYTES=5242880 \
    TON_INDEXER_SMOKE_MAX_HEALTH_LAG_SEC=3600 \
    SOLSWAP_INDEXER_SMOKE_TIMEOUT_MS=60000 \
    SOLSWAP_INDEXER_SMOKE_MAX_RESPONSE_BYTES=5242880 \
    SOLSWAP_INDEXER_SMOKE_MAX_HEALTH_AGE_SEC=900 \
    POLKASWAP_INDEXER_SMOKE_TIMEOUT_MS=60000 \
    POLKASWAP_INDEXER_SMOKE_MAX_RESPONSE_BYTES=5242880 \
    POLKASWAP_INDEXER_SMOKE_MAX_INDEXER_AGE_SEC=900 \
    PATH="$bin_dir:$PATH" \
    NPM_BIN="$bin_dir/npm" \
    YARN_BIN="$bin_dir/yarn" \
    GH_BIN="$bin_dir/gh" \
    MAX_LOG_PREVIEW_LINES=3 \
    MAX_EVIDENCE_PREVIEW_CHARS="${MAX_EVIDENCE_PREVIEW_CHARS:-6000}" \
    bash "$AUDIT_SCRIPT" "$@"
}

force_android_public_dependency_provenance_failure() {
  write_file "$workspace/fearless-Android/scripts/ensure-fearless-utils.sh" \
    '#!/usr/bin/env bash' \
    'set -euo pipefail' \
    'echo "fearless-utils provenance failed for forced fixture" >&2' \
    'exit 1'
  chmod +x "$workspace/fearless-Android/scripts/ensure-fearless-utils.sh"
}

expect_success() {
  SCENARIO_COUNT=$((SCENARIO_COUNT + 1))
  local name="$1"
  local scenario="$2"
  shift 2
  local output
  if ! output="$(run_audit "$scenario" "$@" 2>&1)"; then
    echo "$output" >&2
    fail "$name unexpectedly failed"
  fi
}

expect_failure() {
  SCENARIO_COUNT=$((SCENARIO_COUNT + 1))
  local name="$1"
  local scenario="$2"
  local expected="$3"
  shift 3
  local output
  set +e
  output="$(run_audit "$scenario" "$@" 2>&1)"
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

assert_summary() {
  local name="$1"
  local expected_status="$2"
  local expected_run_live="$3"
  local expected_failed="$4"
  local expected_skipped="$5"
  shift 5

  node - "$report_dir/summary.json" "$name" "$expected_status" "$expected_run_live" "$expected_failed" "$expected_skipped" "$@" <<'NODE'
const assert = require('node:assert/strict')
const fs = require('node:fs')

const [
  ,
  ,
  file,
  name,
  expectedStatus,
  expectedRunLive,
  expectedFailed,
  expectedSkipped,
  ...expectedSlugStatuses
] = process.argv

assert.ok(fs.existsSync(file), `${name}: summary.json must exist`)
const summary = JSON.parse(fs.readFileSync(file, 'utf8'))

assert.equal(summary.schemaVersion, 1, `${name}: schemaVersion`)
assert.match(summary.generatedAt, /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$/, `${name}: generatedAt`)
assert.equal(summary.status, expectedStatus, `${name}: status`)
assert.equal(summary.runLive, expectedRunLive === 'true', `${name}: runLive`)
assert.equal(summary.totals.failed, Number(expectedFailed), `${name}: failed total`)
assert.equal(summary.totals.skipped, Number(expectedSkipped), `${name}: skipped total`)
assert.equal(summary.totals.total, summary.checks.length, `${name}: total matches checks`)
assert.equal(summary.totals.passed + summary.totals.failed + summary.totals.skipped, summary.totals.total, `${name}: totals sum`)
const expectsTerminalFailure = expectedSlugStatuses.some((pair) =>
  pair === 'release-unblock-bundle=failed' || pair === 'release-output-contract=failed'
)
assert.equal(summary.checks.length, expectsTerminalFailure ? 22 : 21, `${name}: expected all release gates to be represented`)
const slugs = summary.checks.map((check) => check.slug)
assert.equal(new Set(slugs).size, slugs.length, `${name}: check slugs must be unique`)

for (const check of summary.checks) {
  assert.ok(check.name, `${name}: check name`)
  assert.ok(check.slug, `${name}: check slug`)
  assert.match(check.status, /^(passed|failed|skipped)$/, `${name}: check status`)
  if (check.status === 'skipped') {
    assert.equal(check.exitCode, null, `${name}: skipped exitCode`)
    assert.equal(check.logFile, null, `${name}: skipped logFile`)
  } else {
    assert.equal(typeof check.exitCode, 'number', `${name}: non-skipped exitCode`)
    assert.equal(typeof check.logFile, 'string', `${name}: non-skipped logFile`)
  }
  if (check.status === 'failed') {
    assert.equal(typeof check.recommendedAction, 'string', `${name}: check summary recommendedAction`)
    assert.ok(check.recommendedAction, `${name}: check summary recommendedAction non-empty`)
    assert.equal(typeof check.requiresExternalAction, 'boolean', `${name}: check summary requiresExternalAction`)
    assert.equal(typeof check.unblockCategory, 'string', `${name}: check summary unblockCategory`)
    assert.ok(check.unblockCategory, `${name}: check summary unblockCategory non-empty`)
    assert.equal(typeof check.externalPrerequisite, 'string', `${name}: check summary externalPrerequisite`)
    assert.ok(check.externalPrerequisite, `${name}: check summary externalPrerequisite non-empty`)
    assert.equal(typeof check.verificationCommand, 'string', `${name}: check summary verificationCommand`)
    assert.ok(check.verificationCommand, `${name}: check summary verificationCommand non-empty`)
  } else {
    assert.equal(check.recommendedAction, null, `${name}: non-blocking check summary recommendedAction`)
    assert.equal(check.requiresExternalAction, null, `${name}: non-blocking check summary requiresExternalAction`)
    assert.equal(check.unblockCategory, null, `${name}: non-blocking check summary unblockCategory`)
    assert.equal(check.externalPrerequisite, null, `${name}: non-blocking check summary externalPrerequisite`)
    assert.equal(check.verificationCommand, null, `${name}: non-blocking check summary verificationCommand`)
  }
}

for (const pair of expectedSlugStatuses) {
  const [slug, status] = pair.split('=')
  const check = summary.checks.find((item) => item.slug === slug)
  assert.ok(check, `${name}: expected slug ${slug}`)
  assert.equal(check.status, status, `${name}: expected ${slug}=${status}`)
}
NODE
}

assert_blocker_report() {
  local name="$1"
  shift
  local file="$report_dir/blockers.md"

  [[ -f "$file" ]] || fail "$name: blockers.md must exist"
  grep -q "# Release Readiness Blockers" "$file" ||
    fail "$name: blockers report title missing"

  local expected
  for expected in "$@"; do
    grep -q "$expected" "$file" ||
      fail "$name: blockers report missing expected text: $expected"
  done
}

assert_action_manifest() {
  local name="$1"
  local expected_status="$2"
  local expected_run_live="$3"
  local expected_failed="$4"
  shift 4

  node - "$report_dir/actions.json" "$name" "$expected_status" "$expected_run_live" "$expected_failed" "$@" <<'NODE'
const assert = require('node:assert/strict')
const fs = require('node:fs')

const [
  ,
  ,
  file,
  name,
  expectedStatus,
  expectedRunLive,
  expectedFailed,
  ...expectedText
] = process.argv

assert.ok(fs.existsSync(file), `${name}: actions.json must exist`)
const actions = JSON.parse(fs.readFileSync(file, 'utf8'))

assert.equal(actions.schemaVersion, 1, `${name}: schemaVersion`)
assert.match(actions.generatedAt, /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$/, `${name}: generatedAt`)
assert.equal(actions.status, expectedStatus, `${name}: status`)
assert.equal(actions.runLive, expectedRunLive === 'true', `${name}: runLive`)
assert.equal(actions.totals.failed, Number(expectedFailed), `${name}: failed total`)
assert.equal(actions.blockers.length, Number(expectedFailed), `${name}: blocker count`)

for (const blocker of actions.blockers) {
  assert.ok(blocker.name, `${name}: blocker name`)
  assert.ok(blocker.slug, `${name}: blocker slug`)
  assert.equal(typeof blocker.exitCode, 'number', `${name}: blocker exitCode`)
  assert.ok(blocker.logFile, `${name}: blocker logFile`)
  assert.ok(blocker.recommendedAction, `${name}: blocker recommendedAction`)
  assert.equal(typeof blocker.requiresExternalAction, 'boolean', `${name}: blocker requiresExternalAction`)
  assert.ok(blocker.unblockCategory, `${name}: blocker unblockCategory`)
  assert.ok(blocker.externalPrerequisite, `${name}: blocker externalPrerequisite`)
  assert.ok(blocker.verificationCommand, `${name}: blocker verificationCommand`)
  assert.equal(typeof blocker.evidencePreview, 'string', `${name}: blocker evidencePreview`)
}

const stringValues = []
const collectStrings = (value) => {
  if (typeof value === 'string') {
    stringValues.push(value)
    return
  }
  if (Array.isArray(value)) {
    value.forEach(collectStrings)
    return
  }
  if (value && typeof value === 'object') {
    Object.values(value).forEach(collectStrings)
  }
}
collectStrings(actions)
const searchableText = stringValues.join('\n')
const serialized = JSON.stringify(actions)
for (const text of expectedText) {
  assert.ok(
    serialized.includes(text) || searchableText.includes(text),
    `${name}: actions manifest missing expected text: ${text}`
  )
}
NODE
}

assert_failed_check_metadata() {
  local name="$1"
  local slug="$2"
  local expected_external="$3"
  local expected_category="$4"
  local expected_action_fragment="$5"
  local expected_prerequisite_fragment="$6"

  node - \
    "$report_dir/summary.json" \
    "$report_dir/actions.json" \
    "$report_dir/blockers.md" \
    "$name" \
    "$slug" \
    "$expected_external" \
    "$expected_category" \
    "$expected_action_fragment" \
    "$expected_prerequisite_fragment" <<'NODE'
const assert = require('node:assert/strict')
const fs = require('node:fs')

const [
  ,
  ,
  summaryFile,
  actionsFile,
  blockersFile,
  name,
  slug,
  expectedExternal,
  expectedCategory,
  expectedActionFragment,
  expectedPrerequisiteFragment,
] = process.argv

const summary = JSON.parse(fs.readFileSync(summaryFile, 'utf8'))
const actions = JSON.parse(fs.readFileSync(actionsFile, 'utf8'))
const blockers = fs.readFileSync(blockersFile, 'utf8')
const check = summary.checks.find((item) => item.slug === slug)
const action = actions.blockers.find((item) => item.slug === slug)

assert.ok(check, `${name}: missing summary check ${slug}`)
assert.ok(action, `${name}: missing action blocker ${slug}`)
assert.equal(check.status, 'failed', `${name}: summary status`)
assert.equal(check.requiresExternalAction, expectedExternal === 'true', `${name}: summary external classification`)
assert.equal(action.requiresExternalAction, expectedExternal === 'true', `${name}: action external classification`)
assert.equal(check.unblockCategory, expectedCategory, `${name}: summary category`)
assert.equal(action.unblockCategory, expectedCategory, `${name}: action category`)
assert.ok(check.recommendedAction.includes(expectedActionFragment), `${name}: summary action fragment`)
assert.ok(action.recommendedAction.includes(expectedActionFragment), `${name}: action fragment`)
assert.ok(check.externalPrerequisite.includes(expectedPrerequisiteFragment), `${name}: summary prerequisite fragment`)
assert.ok(action.externalPrerequisite.includes(expectedPrerequisiteFragment), `${name}: action prerequisite fragment`)
assert.ok(blockers.includes(`- Requires external action: \`${expectedExternal}\``), `${name}: blocker external classification`)
assert.ok(blockers.includes(`- Unblock category: \`${expectedCategory}\``), `${name}: blocker category`)
assert.ok(blockers.includes(expectedActionFragment), `${name}: blocker action fragment`)
assert.ok(blockers.includes(expectedPrerequisiteFragment), `${name}: blocker prerequisite fragment`)
NODE
}

assert_report_timestamps_match() {
  local name="$1"

  node - "$report_dir/summary.json" "$report_dir/actions.json" "$report_dir/blockers.md" "$name" <<'NODE'
const assert = require('node:assert/strict')
const fs = require('node:fs')

const [, , summaryFile, actionsFile, blockersFile, name] = process.argv
const summary = JSON.parse(fs.readFileSync(summaryFile, 'utf8'))
const actions = JSON.parse(fs.readFileSync(actionsFile, 'utf8'))
const blockers = fs.readFileSync(blockersFile, 'utf8')
const match = blockers.match(/^- Generated at: (.+)$/m)

assert.ok(match, `${name}: blockers generated timestamp`)
assert.equal(actions.generatedAt, summary.generatedAt, `${name}: actions generatedAt must match summary`)
assert.equal(match[1], summary.generatedAt, `${name}: blockers generatedAt must match summary`)
NODE
}

production_root="$(cd "$SCRIPT_DIR/.." && pwd -P)"
clean_production_env=(
  /usr/bin/env -i
  "PATH=/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin:/opt/homebrew/bin"
  "HOME=${HOME:-/tmp}"
  "TMPDIR=$tmp_dir"
)
production_override_cases=(
  'RELEASE_READINESS_ROOT|/tmp/forged-release-root'
  'RELEASE_READINESS_PARENT|/tmp/forged-release-parent'
  'RELEASE_READINESS_REPORT_DIR|/tmp/forged-release-report'
  'RELEASE_READINESS_SUMMARY_FILE|/tmp/forged-summary.json'
  'RELEASE_READINESS_BLOCKERS_FILE|/tmp/forged-blockers.md'
  'RELEASE_READINESS_ACTIONS_FILE|/tmp/forged-actions.json'
  'RELEASE_READINESS_UNBLOCK_BUNDLE_DIR|/tmp/forged-unblock-bundle'
  'RELEASE_UNBLOCK_ROOT|/tmp/forged-unblock-root'
  'RELEASE_UNBLOCK_EXPORT_NOW|2030-01-01T00:00:00Z'
  'RELEASE_UNBLOCK_VERIFY_NOW|2030-01-01T00:00:00Z'
  'PLAN_AUDIT_ROOT|/tmp/forged-plan-root'
  'PLAN_AUDIT_PARENT|/tmp/forged-plan-parent'
  'PLAN_AUDIT_FAIL_FAST|true'
  'PLAN_AUDIT_ANDROID_ROOT|/tmp/forged-android-candidate'
  'PLAN_AUDIT_IOS_ROOT|/tmp/forged-ios-candidate'
  'PLAN_AUDIT_IOS_TESTFLIGHT_ROOT|/tmp/forged-ios-testflight-candidate'
  'PLAN_AUDIT_IROHA_ROOT|/tmp/forged-iroha-candidate'
  'RELEASE_PR_READINESS_ROOT|/tmp/forged-pr-root'
  'RELEASE_PR_READINESS_CONFIG|/tmp/forged-pr-config.tsv'
  'RELEASE_PR_READINESS_REPORT|/tmp/forged-pr-report.json'
  'PRIVATE_OVERLAY_AUDIT_ROOT|/tmp/forged-overlay-root'
  'PRIVATE_OVERLAY_AUDIT_REPORT_DIR|/tmp/forged-overlay-report'
  'PUBLIC_ARTIFACT_PROVENANCE_DOC|/tmp/forged-provenance.md'
  'FEARLESS_UTILS_PATH|/tmp/forged-utils'
  'FEARLESS_UTILS_COMMIT|aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
  'FEARLESS_UTILS_REPOSITORY|attacker/forged-utils'
  'FEARLESS_UTILS_LIBRARY_ONLY|false'
  'PASSKEY_CHALLENGE_SERVICE_AUDIT_ROOT|/tmp/forged-passkey-root'
  'PASSKEY_CHALLENGE_SERVICE_DIR|/tmp/forged-passkey-service'
  'PASSKEY_CHALLENGE_SERVICE_AUDIT_SKIP_COMMANDS|1'
  'PASSKEY_DEPLOYMENT_EVIDENCE_ROOT|/tmp/forged-passkey-evidence-root'
  'PASSKEY_DEPLOYMENT_EXPECTED_COMMIT|aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
  'PASSKEY_DEPLOYMENT_GH_BIN|/tmp/forged-passkey-gh'
  'PASSKEY_ANDROID_ASSOCIATION_FILE|/tmp/forged-assetlinks.json'
  'PASSKEY_DEPLOYMENT_EVIDENCE_FILE|/tmp/forged-passkey-evidence.json'
  'PASSKEY_BACKUP_PRODUCTION_CONFIG_FILE|/tmp/forged-passkey-config.json'
  'PASSKEY_AUDIT_ROOT|/tmp/forged-passkey-prerequisite-root'
  'IROHA_READINESS_ROOT|/tmp/forged-iroha-root'
  'IROHA_READINESS_PARENT|/tmp/forged-iroha-parent'
  'IROHA_RELEASE_CONFIG_FILE|/tmp/forged-iroha.env'
  'IROHA_MOBILE_SDK_RELEASE_TAG|forged-tag'
  'IROHA_MOBILE_SDK_RELEASE_REPO|attacker/forged-iroha'
  'IROHA_JS_SDK_VERSION|99.99.99'
  'IROHA_JS_SDK_REGISTRY|https://attacker.invalid'
  'IROHA_JS_SDK_TARBALL|/tmp/forged-iroha-js.tgz'
  'IROHA_JS_SDK_PACKAGE_DIR|/tmp/forged-iroha-js-package'
  'IROHA_JS_SDK_RELEASE_REPO|attacker/forged-iroha-js'
  'IROHA_JS_SDK_RELEASE_TAG|forged-js-tag'
  'IROHA_JS_SDK_RELEASE_ASSET|forged-js.tgz'
  'IROHA_JS_SDK_RELEASE_SHA256|aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
  'NEXUS_PRODUCTION_EVIDENCE_FILE|/tmp/forged-nexus-evidence.json'
  'NEXUS_PRODUCTION_EVIDENCE_AUDIT|/tmp/forged-nexus-audit.sh'
  'NEXUS_PRODUCTION_EVIDENCE_TEST|/tmp/forged-nexus-test.sh'
  'NEXUS_EVIDENCE_ROOT|/tmp/forged-nexus-root'
  'NEXUS_TORII_URL|https://attacker.invalid'
  'NEXUS_EXPECTED_BUILD_COMMIT|aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
  'NEXUS_ROUTE_MANIFEST_EXPECTED_COMMIT|aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
  'NEXUS_ANDROID_WALLET_EXPECTED_COMMIT|aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
  'NEXUS_IOS_WALLET_EXPECTED_COMMIT|aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
  'NEXUS_WEB_WALLET_EXPECTED_COMMIT|aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
  'IROHA_WALLET_COVERAGE_ROOT|/tmp/forged-wallet-root'
  'IROHA_SEND_AGGREGATE_ROOT|/tmp/forged-send-root'
  'IROHA_SEND_AUDIT_ROOT|/tmp/forged-platform-send-root'
  'XCM_REGISTRY_ROOT|/tmp/forged-xcm-registry'
  'XCM_EFFECTIVE_REGISTRY_ROOT|/tmp/forged-effective-xcm'
  'XCM_PRODUCTION_EVIDENCE_ROOT|/tmp/forged-xcm-evidence-root'
  'XCM_PRODUCTION_EXPECTED_COMMIT|aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
  'BITCOIN_BROADCAST_EVIDENCE_ROOT|/tmp/forged-bitcoin-root'
  'BITCOIN_BROADCAST_EVIDENCE_COMMIT|aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
  'BITCOIN_BROADCAST_EVIDENCE_INDEXER_FIXTURE|/tmp/forged-bitcoin-indexer.json'
  'DEPLOYMENT_EVIDENCE_ROOT|/tmp/forged-deployment-root'
  'DEPLOYMENT_EVIDENCE_EXPECTED_COMMIT|aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
  'PASSKEY_BACKUP_SMOKE_MAX_RESPONSE_BYTES|5242880'
  'PASSKEY_BACKUP_SMOKE_GRANT_HELPER_TIMEOUT_MS|10000'
  'TON_INDEXER_SMOKE_TIMEOUT_MS|60000'
  'TON_INDEXER_SMOKE_MAX_RESPONSE_BYTES|5242880'
  'TON_INDEXER_SMOKE_MAX_HEALTH_LAG_SEC|3600'
  'SOLSWAP_INDEXER_SMOKE_TIMEOUT_MS|60000'
  'SOLSWAP_INDEXER_SMOKE_MAX_RESPONSE_BYTES|5242880'
  'SOLSWAP_INDEXER_SMOKE_MAX_HEALTH_AGE_SEC|900'
  'POLKASWAP_INDEXER_SMOKE_TIMEOUT_MS|60000'
  'POLKASWAP_INDEXER_SMOKE_MAX_RESPONSE_BYTES|5242880'
  'POLKASWAP_INDEXER_SMOKE_MAX_INDEXER_AGE_SEC|900'
  'NODE_BIN|/usr/bin/true'
  'NPM_BIN|/usr/bin/true'
  'YARN_BIN|/usr/bin/true'
  'GH_BIN|/usr/bin/true'
  'NODE_OPTIONS|--require=/tmp/forged-preload.cjs'
  'NODE_PATH|/tmp/forged-node-modules'
  'NODE_TLS_REJECT_UNAUTHORIZED|0'
  'NODE_EXTRA_CA_CERTS|/tmp/forged-ca.pem'
  'NODE_USE_ENV_PROXY|1'
  'NODE_USE_SYSTEM_CA|1'
  'OPENSSL_CONF|/tmp/forged-openssl.cnf'
  'CURL_CA_BUNDLE|/tmp/forged-ca.pem'
  'SSL_CERT_FILE|/tmp/forged-ca.pem'
  'SSL_CERT_DIR|/tmp/forged-ca-dir'
  'HTTP_PROXY|http://127.0.0.1:1'
  'HTTPS_PROXY|http://127.0.0.1:1'
  'ALL_PROXY|socks5://127.0.0.1:1'
  'NO_PROXY|*'
  'http_proxy|http://127.0.0.1:1'
  'https_proxy|http://127.0.0.1:1'
  'all_proxy|socks5://127.0.0.1:1'
  'no_proxy|*'
  'PINNED_YARN_TEST_MODE|1'
  'PINNED_YARN_NODE_BIN|/usr/bin/true'
  'PINNED_YARN_NPM_BIN|/usr/bin/true'
  'SOURCE_PUBLICATION_WRAPPER_TEST_MODE|1'
  'SOURCE_PUBLICATION_WRAPPER_TEST_ROOT|/tmp/forged-wrapper-root'
  'SOURCE_PUBLICATION_NODE_BIN|/usr/bin/true'
  'SOURCE_PUBLICATION_TEST_MODE|1'
  'SOURCE_PUBLICATION_ROOT|/tmp/forged-source-root'
  'SOURCE_PUBLICATION_PARENT|/tmp/forged-source-parent'
  'SOURCE_PUBLICATION_CONFIG|/tmp/forged-source.tsv'
  'SOURCE_PUBLICATION_ROOT_OWNER_CONFIG|/tmp/forged-owner.json'
  'SOURCE_PUBLICATION_RELEASE_PR_CONFIG|/tmp/forged-source-pr.tsv'
  'SOURCE_PUBLICATION_GIT_BIN|/usr/bin/true'
  'SOURCE_PUBLICATION_GH_BIN|/usr/bin/true'
  'SOURCE_PUBLICATION_NOW|2030-01-01T00:00:00.000Z'
  'NPM_CONFIG_USERCONFIG|/tmp/forged-npmrc'
  'npm_config_userconfig|/tmp/forged-npmrc-lower'
  'NPM_CONFIG_REGISTRY|https://attacker.invalid'
  'npm_config_registry|https://attacker.invalid'
  'NPM_CONFIG_SCRIPT_SHELL|/usr/bin/true'
  'npm_config_ignore_scripts|true'
  'COREPACK_HOME|/tmp/forged-corepack'
  'COREPACK_NPM_REGISTRY|https://attacker.invalid'
  'COREPACK_INTEGRITY_KEYS|0'
  'COREPACK_ENABLE_PROJECT_SPEC|0'
  'YARN_ENABLE_IMMUTABLE_INSTALLS|false'
  'GIT_DIR|/tmp/forged.git'
  'GIT_WORK_TREE|/tmp/forged-work-tree'
  'GIT_CONFIG_COUNT|1'
  'GIT_SSH_COMMAND|/usr/bin/true'
  'GH_CONFIG_DIR|/tmp/forged-gh-config'
  'GH_HOST|attacker.invalid'
  'GH_REPO|attacker/forged'
  'SSH_ASKPASS|/usr/bin/true'
  'BASH_ENV|/dev/null'
  'ENV|/dev/null'
  'CDPATH|/tmp'
  'PERL5OPT|-Mlib=/tmp/forged-perl'
  'PERL5LIB|/tmp/forged-perl'
  'AWKPATH|/tmp/forged-awk'
  'AWKLIBPATH|/tmp/forged-awk'
)

PRODUCTION_OVERRIDE_PROBE_COUNT=0
for override_case in "${production_override_cases[@]}"; do
  override_name="${override_case%%|*}"
  override_value="${override_case#*|}"
  probe_log="$tmp_dir/production-override-$PRODUCTION_OVERRIDE_PROBE_COUNT.log"
  if "${clean_production_env[@]}" "$override_name=$override_value" \
    /bin/bash "$AUDIT_SCRIPT" --skip-live >"$probe_log" 2>&1; then
    fail "production $override_name override unexpectedly passed"
  fi
  grep -Fq "$override_name is forbidden outside explicit RELEASE_READINESS_TEST_MODE=1" "$probe_log" || {
    sed -n '1,10p' "$probe_log" >&2
    fail "production $override_name override diagnostic missing"
  }
  PRODUCTION_OVERRIDE_PROBE_COUNT=$((PRODUCTION_OVERRIDE_PROBE_COUNT + 1))
done

PRODUCTION_PATH_PROBE_COUNT=0
path_probe_bin="$tmp_dir/path-probe-bin"
path_probe_marker="$tmp_dir/path-probe-invoked"
mkdir -p "$path_probe_bin"
for tool in dirname realpath node npm gh git curl env bash; do
  write_file "$path_probe_bin/$tool" \
    '#!/bin/bash' \
    "printf '%s\\n' '$tool' >> '$path_probe_marker'" \
    'exit 91'
  chmod +x "$path_probe_bin/$tool"
done
path_probe_log="$tmp_dir/production-path-probe.log"
if ! /usr/bin/env -i \
  "PATH=$path_probe_bin:/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin:/opt/homebrew/bin" \
  "HOME=${HOME:-/tmp}" \
  "$AUDIT_SCRIPT" --help >"$path_probe_log" 2>&1; then
  sed -n '1,20p' "$path_probe_log" >&2
  fail "production PATH sanitization probe unexpectedly failed"
fi
[[ ! -e "$path_probe_marker" ]] || {
  cat "$path_probe_marker" >&2
  fail "production PATH sanitization invoked an injected executable"
}
grep -Fq 'Usage: scripts/audit-release-readiness.sh' "$path_probe_log" ||
  fail "production PATH sanitization probe did not reach canonical help output"
grep -Fq 'TI, SI, and PI deployment evidence readiness' "$path_probe_log" ||
  fail "release-readiness help must enumerate PI deployment evidence coverage"
PRODUCTION_PATH_PROBE_COUNT=$((PRODUCTION_PATH_PROBE_COUNT + 1))

cleanup_probe_root="$tmp_dir/production-cleanup-symlink-root"
cleanup_probe_outside="$tmp_dir/production-cleanup-symlink-outside"
cleanup_probe_log="$tmp_dir/production-cleanup-symlink.log"
mkdir -p "$cleanup_probe_root/scripts" "$cleanup_probe_outside/reports/release-readiness"
cp "$AUDIT_SCRIPT" "$cleanup_probe_root/scripts/audit-release-readiness.sh"
ln -s "$cleanup_probe_outside" "$cleanup_probe_root/build"
write_file "$cleanup_probe_outside/reports/release-readiness/sentinel" "must survive"
set +e
"${clean_production_env[@]}" \
  /bin/bash "$cleanup_probe_root/scripts/audit-release-readiness.sh" \
  >"$cleanup_probe_log" 2>&1
cleanup_probe_status=$?
set -e
if [[ "$cleanup_probe_status" -ne 2 ]]; then
  sed -n '1,20p' "$cleanup_probe_log" >&2
  fail "production cleanup symlink probe must fail setup with exit code 2"
fi
[[ -f "$cleanup_probe_outside/reports/release-readiness/sentinel" ]] ||
  fail "production cleanup followed an intermediate build symlink"
grep -Fq 'release-readiness report directory cleanup path must not traverse a symlink' "$cleanup_probe_log" ||
  fail "production cleanup symlink diagnostic missing"
PRODUCTION_PATH_PROBE_COUNT=$((PRODUCTION_PATH_PROBE_COUNT + 1))

function_probe_log="$tmp_dir/production-exported-function-probe.log"
if "${clean_production_env[@]}" AUDIT_SCRIPT="$AUDIT_SCRIPT" /bin/bash -c \
  'git() { return 0; }; export -f git; exec /bin/bash "$AUDIT_SCRIPT" --help' \
  >"$function_probe_log" 2>&1; then
  fail "production exported-function injection unexpectedly passed"
fi
grep -Eq '(exported shell functions are forbidden outside explicit RELEASE_READINESS_TEST_MODE=1: git|BASH_FUNC_git%% is forbidden outside explicit RELEASE_READINESS_TEST_MODE=1)' "$function_probe_log" || {
  sed -n '1,10p' "$function_probe_log" >&2
  fail "production exported-function injection diagnostic missing"
}
PRODUCTION_PATH_PROBE_COUNT=$((PRODUCTION_PATH_PROBE_COUNT + 1))

TEST_ISOLATION_PROBE_COUNT=0
test_mode_log="$tmp_dir/test-mode-production-root.log"
if "${clean_production_env[@]}" \
  RELEASE_READINESS_TEST_MODE=1 \
  RELEASE_READINESS_ROOT="$production_root" \
  RELEASE_READINESS_PARENT="$(cd "$production_root/.." && pwd -P)" \
  /bin/bash "$AUDIT_SCRIPT" --help >"$test_mode_log" 2>&1; then
  fail "test mode unexpectedly targeted the production workspace root"
fi
grep -Fq 'must use a root isolated from the production workspace' "$test_mode_log" ||
  fail "test-mode production-root isolation diagnostic missing"
TEST_ISOLATION_PROBE_COUNT=$((TEST_ISOLATION_PROBE_COUNT + 1))

isolated_parent="$tmp_dir/isolated-test-parent"
isolated_root="$isolated_parent/fearless"
mkdir -p "$isolated_root" "$tmp_dir/wrong-test-parent"
test_mode_log="$tmp_dir/test-mode-parent-escape.log"
if "${clean_production_env[@]}" \
  RELEASE_READINESS_TEST_MODE=1 \
  RELEASE_READINESS_ROOT="$isolated_root" \
  RELEASE_READINESS_PARENT="$tmp_dir/wrong-test-parent" \
  /bin/bash "$AUDIT_SCRIPT" --help >"$test_mode_log" 2>&1; then
  fail "test mode unexpectedly accepted a detached parent"
fi
grep -Fq "must be the isolated workspace root's canonical parent" "$test_mode_log" ||
  fail "test-mode detached-parent diagnostic missing"
TEST_ISOLATION_PROBE_COUNT=$((TEST_ISOLATION_PROBE_COUNT + 1))

destructive_parent="$tmp_dir/test-mode-report-parent-equality"
destructive_root="$destructive_parent/fearless"
destructive_probe_log="$tmp_dir/test-mode-report-parent-equality.log"
mkdir -p "$destructive_root"
write_file "$destructive_root/sentinel" "workspace must survive"
set +e
"${clean_production_env[@]}" \
  RELEASE_READINESS_TEST_MODE=1 \
  RELEASE_READINESS_ROOT="$destructive_root" \
  RELEASE_READINESS_PARENT="$destructive_parent" \
  RELEASE_READINESS_REPORT_DIR="$destructive_parent" \
  /bin/bash "$AUDIT_SCRIPT" >"$destructive_probe_log" 2>&1
destructive_probe_status=$?
set -e
if [[ "$destructive_probe_status" -ne 2 ]]; then
  sed -n '1,20p' "$destructive_probe_log" >&2
  fail "test mode report-parent equality must fail setup with exit code 2"
fi
[[ -f "$destructive_root/sentinel" ]] ||
  fail "test mode report-parent equality deleted the isolated workspace"
grep -Fq 'RELEASE_READINESS_REPORT_DIR must be a strict descendant' "$destructive_probe_log" ||
  fail "test-mode strict report-descendant diagnostic missing"
TEST_ISOLATION_PROBE_COUNT=$((TEST_ISOLATION_PROBE_COUNT + 1))

test_mode_log="$tmp_dir/test-mode-report-escape.log"
if "${clean_production_env[@]}" \
  RELEASE_READINESS_TEST_MODE=1 \
  RELEASE_READINESS_ROOT="$isolated_root" \
  RELEASE_READINESS_PARENT="$isolated_parent" \
  RELEASE_READINESS_REPORT_DIR="$production_root/build/reports/forged-test-report" \
  /bin/bash "$AUDIT_SCRIPT" --help >"$test_mode_log" 2>&1; then
  fail "test mode unexpectedly accepted a production report destination"
fi
grep -Fq 'RELEASE_READINESS_REPORT_DIR must remain inside the isolated test parent' "$test_mode_log" ||
  fail "test-mode report-containment diagnostic missing"
TEST_ISOLATION_PROBE_COUNT=$((TEST_ISOLATION_PROBE_COUNT + 1))

ln -s "$production_root" "$isolated_parent/report-link"
test_mode_log="$tmp_dir/test-mode-report-symlink.log"
if "${clean_production_env[@]}" \
  RELEASE_READINESS_TEST_MODE=1 \
  RELEASE_READINESS_ROOT="$isolated_root" \
  RELEASE_READINESS_PARENT="$isolated_parent" \
  RELEASE_READINESS_REPORT_DIR="$isolated_parent/report-link/build/reports/forged-test-report" \
  /bin/bash "$AUDIT_SCRIPT" --help >"$test_mode_log" 2>&1; then
  fail "test mode unexpectedly accepted a symlinked report destination"
fi
grep -Fq 'RELEASE_READINESS_REPORT_DIR must not traverse a symlink in test mode' "$test_mode_log" ||
  fail "test-mode report-symlink diagnostic missing"
TEST_ISOLATION_PROBE_COUNT=$((TEST_ISOLATION_PROBE_COUNT + 1))

ln -s "$production_root/fearless-Android" "$isolated_root/fearless-Android"
test_mode_log="$tmp_dir/test-mode-dependency-symlink.log"
if "${clean_production_env[@]}" \
  RELEASE_READINESS_TEST_MODE=1 \
  RELEASE_READINESS_ROOT="$isolated_root" \
  RELEASE_READINESS_PARENT="$isolated_parent" \
  /bin/bash "$AUDIT_SCRIPT" --help >"$test_mode_log" 2>&1; then
  fail "test mode unexpectedly accepted a symlinked child repository"
fi
grep -Fq 'test dependency path must not traverse a symlink in test mode' "$test_mode_log" ||
  fail "test-mode dependency-symlink diagnostic missing"
TEST_ISOLATION_PROBE_COUNT=$((TEST_ISOLATION_PROBE_COUNT + 1))

setup_fixture
NODE_TLS_REJECT_UNAUTHORIZED=0 \
NODE_EXTRA_CA_CERTS=/dev/null \
NODE_USE_ENV_PROXY=1 \
NODE_USE_SYSTEM_CA=1 \
OPENSSL_CONF=/dev/null \
SSL_CERT_FILE=/dev/null \
SSL_CERT_DIR=/tmp/forged-ca-dir \
HTTP_PROXY=http://127.0.0.1:1 \
HTTPS_PROXY=http://127.0.0.1:1 \
ALL_PROXY=socks5://127.0.0.1:1 \
NO_PROXY='*' \
http_proxy=http://127.0.0.1:1 \
https_proxy=http://127.0.0.1:1 \
all_proxy=socks5://127.0.0.1:1 \
no_proxy='*' \
expect_success "all-good fixture" good
[[ -f "$report_dir/plan-readiness.log" ]] || fail "expected plan-readiness log"
[[ -f "$report_dir/si-production-smoke.log" ]] || fail "expected SI production log"
[[ -f "$report_dir/pi-production-smoke.log" ]] || fail "expected PI production log"
[[ -f "$report_dir/source-publication-readiness.log" ]] || fail "expected source publication log"
[[ -f "$report_dir/source-publication-readiness-report.json" ]] || fail "expected source publication report"
[[ -f "$report_dir/unblock-bundle/manifest.json" ]] || fail "expected release unblock bundle manifest"
[[ -x "$report_dir/unblock-bundle/verify-blockers.sh" ]] || fail "expected release unblock bundle verification script"
[[ -f "$report_dir/unblock-bundle/SHA256SUMS" ]] || fail "expected release unblock bundle checksums"
grep -q "polkaswap-indexer deployment evidence passed requireReady=true runner=yarn" "$report_dir/pi-deployment-evidence.log" ||
  fail "expected exact Yarn PI deployment-evidence command"
grep -q "polkaswap-indexer smoke passed runner=yarn" "$report_dir/pi-production-smoke.log" ||
  fail "expected exact Yarn PI production-smoke command"
node - "$parent/polkaswap-indexer/build/reports/production-deployment-evidence-template.json" <<'NODE'
const assert = require('node:assert/strict')
const fs = require('node:fs')

const manifest = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'))
assert.deepEqual(manifest.requiredEvidenceFields, [
  'commit',
  'imageDigest',
  'deploymentId',
  'baseUrl',
  'smokeCommand',
  'deployedAt',
  'smokePassedAt',
  'healthInfo',
  'soraRpcControls',
  'tlsEdgeControls',
  'operator',
])
const evidence = manifest.deploymentEvidence[0]
assert.equal(evidence.healthInfo.genesisHash, '0x7e4e32d0feafd4f9c9414b0be86373f9a1efa904809b683453a9af6856d38ad5')
assert.equal(evidence.healthInfo.latestIndexedBlock, 'TODO_POSITIVE_SAFE_INTEGER_INDEXED_BLOCK')
assert.equal(evidence.healthInfo.latestIndexedBlockHash, 'TODO_0X_64_LOWERCASE_HEX_INDEXED_BLOCK_HASH')
assert.equal(evidence.healthInfo.latestIndexedAt, 'TODO_UNIX_SECONDS_WITHIN_300_BEFORE_OR_30_AFTER_SMOKE')
assert.deepEqual(evidence.soraRpcControls, {
  primaryEndpoint: 'TODO_CANONICAL_WSS_LOCALLY_CONTROLLED_PRIMARY_RPC_ENDPOINT',
  archiveEndpoint: 'TODO_CANONICAL_WSS_INDEPENDENT_ARCHIVE_RPC_ENDPOINT',
  primaryNodeControl: 'locally-controlled-verifying-archive',
  archiveNodeControl: 'independently-operated-verifying-archive',
  distinctHosts: true,
  exactIdentityPreflight: true,
  rawPayloadAgreement: 'height-hash-scale-block-events-timestamp',
})
assert.deepEqual(evidence.tlsEdgeControls, {
  tlsTermination: true,
  forwardedClientIpHeaders: 'overwrite',
  httpClientIpRateLimit: { windowMs: 60000, maxRequests: 600 },
  webSocketClientIpLimits: { windowMs: 60000, maxUpgrades: 600, maxConcurrentConnections: 16 },
})
NODE
grep -q "passkey Android origin parity self-test passed" "$report_dir/passkey-deployment-evidence.log" ||
  fail "expected passkey Android origin parity self-test in full-live deployment log"
grep -q "passkey Android origin parity passed requireReady=true" "$report_dir/passkey-deployment-evidence.log" ||
  fail "expected passkey Android origin parity --require-ready in full-live deployment log"
grep -q "strict live app association verification passed" "$report_dir/passkey-backup-prerequisites.log" ||
  fail "expected strict fearless-site-web-app-associations-20260726 live app association verifier in full-live prerequisites log"
[[ -f "$workspace/fearless-site-web-app-associations-20260726/build/live-association-verifier-called" ]] ||
  fail "expected strict fearless-site-web-app-associations-20260726 live app association verifier to execute in full-live mode"
assert_summary "all-good fixture" passed true 0 0 \
  plan-readiness=passed \
  github-governance=passed \
  release-pr-readiness=passed \
  android-public-dependency-provenance=passed \
  ios-shared-features-delta=passed \
  passkey-deployment-evidence=passed \
  passkey-production-smoke=passed \
  android-xcm-production-evidence=passed \
  web-bitcoin-broadcast-evidence=passed \
  ti-deployment-evidence=passed \
  si-deployment-evidence=passed \
  pi-deployment-evidence=passed \
  ti-production-smoke=passed \
  si-production-smoke=passed \
  pi-production-smoke=passed \
  source-publication-readiness=passed
assert_blocker_report "all-good fixture" \
  "No blocking release-readiness failures recorded"
assert_action_manifest "all-good fixture" passed true 0
assert_report_timestamps_match "all-good fixture"

setup_fixture
mkdir -p \
  "$workspace/services/passkey-backup-challenge-service/build/reports" \
  "$parent/ton-indexer/build/reports" \
  "$parent/solswap-indexer/build/reports" \
  "$parent/polkaswap-indexer/build/reports"
for stale_template in \
  "$workspace/services/passkey-backup-challenge-service/build/reports/production-deployment-evidence-template.json" \
  "$parent/ton-indexer/build/reports/production-deployment-evidence-template.json" \
  "$parent/solswap-indexer/build/reports/production-deployment-evidence-template.json" \
  "$parent/polkaswap-indexer/build/reports/production-deployment-evidence-template.json"; do
  printf '%s\n' '{"stale":true}' > "$stale_template"
done
write_file "$bin_dir/npm" '#!/usr/bin/env bash' 'exit 0'
chmod +x "$bin_dir/npm"
expect_failure "stale deployment templates cannot survive successful no-op generators" good "Passkey deployment evidence"
for slug in passkey-deployment-evidence ti-deployment-evidence si-deployment-evidence pi-deployment-evidence; do
  grep -q 'expected deployment evidence template was not written' "$report_dir/$slug.log" ||
    fail "expected stale-template rejection in $slug log"
done

setup_fixture
TEST_AMBIENT_FEARLESS_UTILS_PATH="$parent/attacker-controlled-utils" \
  TEST_AMBIENT_FEARLESS_UTILS_COMMIT=1111111111111111111111111111111111111111 \
  TEST_AMBIENT_FEARLESS_UTILS_REPOSITORY=attacker/fearless-utils-Android \
  expect_success "ambient fearless-utils identity overrides are scrubbed" good
grep -q "fearless-utils canonical identity and provenance passed" "$report_dir/android-public-dependency-provenance.log" ||
  fail "expected aggregate to replace ambient fearless-utils identity overrides with canonical pins"

setup_fixture
expect_success "transient GitHub governance retry" github-transient
grep -q "transient GitHub API connection refused" "$report_dir/github-governance.log" ||
  fail "expected transient GitHub governance failure in retry log"
grep -q "GitHub governance attempt 2/3" "$report_dir/github-governance.log" ||
  fail "expected second GitHub governance retry attempt in log"
assert_summary "transient GitHub governance retry" passed true 0 0 \
  github-governance=passed \
  release-pr-readiness=passed
assert_action_manifest "transient GitHub governance retry" passed true 0

setup_fixture
expect_failure "unsafe-Iroha-only plan failure" plan-unsafe-iroha-only "Static cross-repo plan readiness"
assert_summary "unsafe-Iroha-only plan failure" failed true 2 0 \
  plan-readiness=failed \
  github-governance=passed \
  source-publication-readiness=failed
assert_failed_check_metadata \
  "unsafe-Iroha-only plan failure" \
  "plan-readiness" \
  true \
  "upstream-dependency" \
  "Do not edit or publish from the unsafe external ../iroha checkout" \
  "Owner-coordinated resolution of the unsafe external ../iroha source state"

[[ -f "$report_dir/source-publication-readiness-report.json" ]] ||
  fail "expected unsafe-Iroha live fixture to leave a source-publication report"
expect_failure \
  "skip-live Iroha-only plan failure ignores stale live source report" \
  plan-unsafe-iroha-only \
  "Static cross-repo plan readiness" \
  --skip-live
assert_summary "skip-live Iroha-only plan failure ignores stale live source report" failed false 1 7 \
  plan-readiness=failed \
  github-governance=skipped \
  release-pr-readiness=skipped \
  source-publication-readiness=skipped
assert_failed_check_metadata \
  "skip-live Iroha-only plan failure ignores stale live source report" \
  "plan-readiness" \
  false \
  "local-code" \
  "Fix the static plan-readiness drift" \
  "No external prerequisite is expected"
[[ -f "$report_dir/unblock-bundle/manifest.json" ]] ||
  fail "expected skip-live stale-report regression to export and verify an unblock bundle"

setup_fixture
expect_failure "unmerged-Iroha-only plan failure" plan-unmerged-iroha-only "Static cross-repo plan readiness"
assert_summary "unmerged-Iroha-only plan failure" failed true 2 0 \
  plan-readiness=failed \
  github-governance=passed \
  source-publication-readiness=failed
assert_failed_check_metadata \
  "unmerged-Iroha-only plan failure" \
  "plan-readiness" \
  true \
  "upstream-dependency" \
  "Do not edit or publish from the unsafe external ../iroha checkout" \
  "Owner-coordinated resolution of the unsafe external ../iroha source state"

setup_fixture
expect_failure "unpublished-Iroha-only plan failure" plan-unpublished-iroha-only "Static cross-repo plan readiness"
assert_summary "unpublished-Iroha-only plan failure" failed true 2 0 \
  plan-readiness=failed \
  github-governance=passed \
  source-publication-readiness=failed
assert_failed_check_metadata \
  "unpublished-Iroha-only plan failure" \
  "plan-readiness" \
  true \
  "upstream-dependency" \
  "Do not edit or publish from the unsafe external ../iroha checkout" \
  "Owner-coordinated resolution of the unsafe external ../iroha source state"

setup_fixture
expect_failure \
  "postflight-continuity Iroha-only plan failure" \
  plan-unpublished-iroha-postflight-continuity \
  "Static cross-repo plan readiness"
assert_summary "postflight-continuity Iroha-only plan failure" failed true 2 0 \
  plan-readiness=failed \
  github-governance=passed \
  source-publication-readiness=failed
assert_failed_check_metadata \
  "postflight-continuity Iroha-only plan failure" \
  "plan-readiness" \
  true \
  "upstream-dependency" \
  "Do not edit or publish from the unsafe external ../iroha checkout" \
  "Owner-coordinated resolution of the unsafe external ../iroha source state"

setup_fixture
expect_failure \
  "authoritative-current drift Iroha-only plan failure" \
  plan-unpublished-iroha-drift \
  "Static cross-repo plan readiness"
assert_summary "authoritative-current drift Iroha-only plan failure" failed true 2 0 \
  plan-readiness=failed \
  github-governance=passed \
  source-publication-readiness=failed
assert_failed_check_metadata \
  "authoritative-current drift Iroha-only plan failure" \
  "plan-readiness" \
  true \
  "upstream-dependency" \
  "Do not edit or publish from the unsafe external ../iroha checkout" \
  "Owner-coordinated resolution of the unsafe external ../iroha source state"

setup_fixture
expect_failure \
  "postflight-continuity authoritative-current drift Iroha-only plan failure" \
  plan-unpublished-iroha-drift-postflight-continuity \
  "Static cross-repo plan readiness"
assert_summary "postflight-continuity authoritative-current drift Iroha-only plan failure" failed true 2 0 \
  plan-readiness=failed \
  github-governance=passed \
  source-publication-readiness=failed
assert_failed_check_metadata \
  "postflight-continuity authoritative-current drift Iroha-only plan failure" \
  "plan-readiness" \
  true \
  "upstream-dependency" \
  "Do not edit or publish from the unsafe external ../iroha checkout" \
  "Owner-coordinated resolution of the unsafe external ../iroha source state"


iroha_publication_proof_negative_cases=(
  "canonical branch cannot claim merged PR proof|plan-unpublished-iroha-drift-current-equals-pr"
  "legacy v2 Iroha publication proof stays local|plan-unpublished-iroha-legacy-v2"
  "wrong-phase Iroha publication proof stays local|plan-unpublished-iroha-wrong-report-phase"
  "wrong-preflight-digest Iroha publication proof stays local|plan-unpublished-iroha-wrong-preflight-digest"
  "missing actual-branch Iroha publication proof stays local|plan-unpublished-iroha-missing-actual-proof"
  "forged actual-branch Iroha publication proof stays local|plan-unpublished-iroha-forged-actual-proof"
  "mismatched Iroha PR-head diagnostic stays local|plan-unpublished-iroha-mismatched-proof-failure"
  "missing Iroha PR-head SHA proof stays local|plan-unpublished-iroha-missing-pr-head"
  "forged Iroha PR-head SHA proof stays local|plan-unpublished-iroha-forged-pr-head"
  "missing Iroha PR-head mismatch diagnostic stays local|plan-unpublished-iroha-missing-pr-diagnostic"
  "invalid Iroha configured-ref proof stays local|plan-unpublished-iroha-invalid-configured-ref-proof"
  "missing Iroha ignored-output diagnostic stays local|plan-unpublished-iroha-missing-ignored-diagnostic"
  "stale Iroha local/current diagnostic stays local|plan-unpublished-iroha-stale-current-diagnostic"
  "preflight/postflight source-row mismatch stays local|plan-unpublished-iroha-preflight-row-mismatch"
  "wrong Iroha postflight-continuity marker stays local|plan-unpublished-iroha-wrong-continuity-marker"
  "duplicate Iroha postflight-continuity marker stays local|plan-unpublished-iroha-duplicate-continuity-marker"
  "reordered Iroha postflight-continuity marker stays local|plan-unpublished-iroha-reordered-continuity-marker"
  "Iroha postflight-continuity marker plus unrelated failure stays local|plan-unpublished-iroha-continuity-marker-plus-extra"
  "missing Iroha authoritative-current drift diagnostic stays local|plan-unpublished-iroha-drift-missing-current-diagnostic"
  "missing Iroha cached-upstream drift diagnostic stays local|plan-unpublished-iroha-drift-missing-cached-diagnostic"
  "reordered Iroha authoritative-current drift diagnostics stay local|plan-unpublished-iroha-drift-reordered-diagnostics"
  "forged Iroha authoritative-current drift diagnostic stays local|plan-unpublished-iroha-drift-forged-current-diagnostic"
  "forged Iroha cached-upstream drift diagnostic stays local|plan-unpublished-iroha-drift-forged-cached-diagnostic"
  "unrelated extra Iroha authoritative-current drift failure stays local|plan-unpublished-iroha-drift-unrelated-extra"
  "wrong Iroha authoritative-current drift continuity marker stays local|plan-unpublished-iroha-drift-wrong-continuity-marker"
  "duplicate Iroha authoritative-current drift continuity marker stays local|plan-unpublished-iroha-drift-duplicate-continuity-marker"
  "Iroha authoritative-current drift marker plus unrelated failure stays local|plan-unpublished-iroha-drift-continuity-marker-plus-extra"
  "Iroha authoritative-current drift proof with synchronized current SHA stays local|plan-unpublished-iroha-drift-current-equals-local"
  "Iroha authoritative-current drift proof with divergent cached upstream stays local|plan-unpublished-iroha-drift-upstream-differs-from-local"
  "Iroha authoritative-current drift proof with local PR head stays local|plan-unpublished-iroha-drift-pr-equals-local"
  "Iroha authoritative-current drift proof with present configured ref stays local|plan-unpublished-iroha-drift-configured-ref-present"
  "Iroha authoritative-current drift proof with configured-ref SHA stays local|plan-unpublished-iroha-drift-configured-ref-sha"
  "Iroha authoritative-current drift proof with not-present current ref stays local|plan-unpublished-iroha-drift-current-ref-not-present"
  "Iroha authoritative-current drift proof with nonzero worktree count stays local|plan-unpublished-iroha-drift-nonzero-count"
)
for iroha_publication_proof_case in "${iroha_publication_proof_negative_cases[@]}"; do
  IFS='|' read -r fixture_name fixture_scenario <<< "$iroha_publication_proof_case"
  setup_fixture
  expect_failure "$fixture_name" "$fixture_scenario" "Static cross-repo plan readiness"
  assert_summary "$fixture_name" failed true 2 0 \
    plan-readiness=failed \
    github-governance=passed \
    source-publication-readiness=failed
  assert_failed_check_metadata \
    "$fixture_name" \
    "plan-readiness" \
    false \
    "local-code" \
    "Fix the static plan-readiness drift" \
    "No external prerequisite is expected"
done

setup_fixture
expect_failure "clean-Iroha-only plan failure stays local" plan-clean-iroha-only "Static cross-repo plan readiness"
assert_summary "clean-Iroha-only plan failure stays local" failed true 1 0 \
  plan-readiness=failed \
  github-governance=passed
assert_failed_check_metadata \
  "clean-Iroha-only plan failure stays local" \
  "plan-readiness" \
  false \
  "local-code" \
  "Fix the static plan-readiness drift" \
  "No external prerequisite is expected"

setup_fixture
expect_failure "forged Iroha operation marker stays local" plan-forged-iroha-operation "Static cross-repo plan readiness"
assert_summary "forged Iroha operation marker stays local" failed true 2 0 \
  plan-readiness=failed \
  github-governance=passed \
  source-publication-readiness=failed
assert_failed_check_metadata \
  "forged Iroha operation marker stays local" \
  "plan-readiness" \
  false \
  "local-code" \
  "Fix the static plan-readiness drift" \
  "No external prerequisite is expected"

setup_fixture
expect_failure "forged Iroha publication mismatch stays local" plan-forged-iroha-publication "Static cross-repo plan readiness"
assert_summary "forged Iroha publication mismatch stays local" failed true 2 0 \
  plan-readiness=failed \
  github-governance=passed \
  source-publication-readiness=failed
assert_failed_check_metadata \
  "forged Iroha publication mismatch stays local" \
  "plan-readiness" \
  false \
  "local-code" \
  "Fix the static plan-readiness drift" \
  "No external prerequisite is expected"

setup_fixture
expect_failure "mixed local and unsafe-Iroha plan failure" plan-mixed-failure "Static cross-repo plan readiness"
assert_summary "mixed local and unsafe-Iroha plan failure" failed true 1 0 \
  plan-readiness=failed \
  github-governance=passed
assert_failed_check_metadata \
  "mixed local and unsafe-Iroha plan failure" \
  "plan-readiness" \
  false \
  "local-code" \
  "Fix the static plan-readiness drift" \
  "No external prerequisite is expected"

setup_fixture
expect_failure "release unblock bundle verification failure" unblock-fail "Release unblock bundle export/verification failed"
assert_summary "release unblock bundle verification failure" failed true 1 0 \
  plan-readiness=passed \
  release-pr-readiness=passed \
  release-unblock-bundle=failed
assert_failed_check_metadata \
  "release unblock bundle verification failure" \
  "release-unblock-bundle" \
  false \
  "local-code" \
  "Fix the release-unblock bundle exporter or verifier failure" \
  "No external prerequisite is expected"
[[ ! -e "$report_dir/unblock-bundle" ]] ||
  fail "unverified release unblock bundle reached the canonical output path"
grep -q "fake release unblock bundle verification failed" "$report_dir/release-unblock-bundle.log" ||
  fail "expected terminal release unblock bundle failure log"

setup_fixture
expect_failure "single release PR failure" release-pr-fail "Release PR readiness"
grep -q "release-pr-fail" "$report_dir/release-pr-readiness.log" ||
  fail "expected release PR readiness failure log"
assert_summary "single release PR failure" failed true 1 0 \
  release-pr-readiness=failed \
  github-governance=passed
assert_blocker_report "single release PR failure" \
  "release-pr-readiness" \
  "Get every PR in config/release-readiness-prs.tsv approved" \
  "all GitHub review conversations resolved including outdated unresolved threads" \
  "resolve-release-pr-review-threads.sh --dry-run" \
  "merge-release-prs.sh --dry-run" \
  "Requires external action: \`true\`" \
  "Unblock category: \`review-and-merge\`" \
  "External prerequisite: Reviewer approvals, resolved GitHub review conversations, and protected-branch merges." \
  "Verification command: \`bash scripts/audit-release-pr-readiness.sh\`" \
  "audit-release-pr-readiness.sh failed for release-pr-fail"
assert_action_manifest "single release PR failure" failed true 1 \
  "release-pr-readiness" \
  "all GitHub review conversations resolved including outdated unresolved threads" \
  "resolve-release-pr-review-threads.sh --dry-run" \
  "merge-release-prs.sh --dry-run" \
  "\"requiresExternalAction\":true" \
  "\"unblockCategory\":\"review-and-merge\"" \
  "Reviewer approvals, resolved GitHub review conversations, and protected-branch merges." \
  "bash scripts/audit-release-pr-readiness.sh" \
  "audit-release-pr-readiness.sh failed for release-pr-fail"

setup_fixture
expect_failure "source publication failure" source-publication-fail "Source publication readiness"
grep -q "tested source is dirty or unpublished" "$report_dir/source-publication-readiness.log" ||
  fail "expected source publication failure log"
[[ -f "$report_dir/source-publication-readiness-report.json" ]] ||
  fail "expected structured source publication failure report"
assert_summary "source publication failure" failed true 1 0 \
  source-publication-readiness=failed \
  release-pr-readiness=passed \
  pi-production-smoke=passed
assert_blocker_report "source publication failure" \
  "source-publication-readiness" \
  "Do not commit or publish from a checkout with an in-progress merge" \
  "Remove or quarantine every ignored non-published build output" \
  "Assign the root release tooling and passkey challenge service to a canonical maintained GitHub repository" \
  "Unblock category: \`source-publication\`" \
  "remote-checked source preflight" \
  "bash scripts/audit-release-readiness.sh"
assert_action_manifest "source publication failure" failed true 1 \
  "source-publication-readiness" \
  "Owner-resolved completion of every in-progress Git operation" \
  "removal or quarantine of ignored non-published build outputs" \
  "source-publication"
[[ -f "$report_dir/unblock-bundle/manifest.json" ]] ||
  fail "expected release unblock bundle manifest for single release PR failure"

setup_fixture
expect_failure "source publication self-test failure" source-self-test-fail "Source publication readiness"
grep -q "test-source-publication-readiness-audit.sh failed for source-self-test-fail" "$report_dir/source-publication-readiness.log" ||
  fail "expected source publication self-test failure log"
grep -q "source publication audit passed" "$report_dir/source-publication-readiness.log" ||
  fail "expected source publication live audit to run after its self-test failed"
[[ -f "$report_dir/source-publication-readiness-report.json" ]] ||
  fail "expected source publication live audit report after its self-test failed"
assert_summary "source publication self-test failure" failed true 1 0 \
  source-publication-readiness=failed \
  release-pr-readiness=passed
assert_blocker_report "source publication self-test failure" \
  "source-publication-readiness" \
  "bash scripts/audit-release-readiness.sh"
assert_action_manifest "source publication self-test failure" failed true 1 \
  "source-publication-readiness" \
  "bash scripts/audit-release-readiness.sh"

setup_fixture
MAX_EVIDENCE_PREVIEW_CHARS=20 expect_failure "capped release PR evidence preview" release-pr-fail "Release PR readiness"
assert_blocker_report "capped release PR evidence preview" \
  "release-pr-readiness" \
  "[line capped to final 20 characters; see full log]" \
  "release-pr-fail" \
  "[excerpt capped at 20 characters; see full log]"
assert_action_manifest "capped release PR evidence preview" failed true 1 \
  "release-pr-readiness" \
  "[line capped to final 20 characters; see full log]" \
  "release-pr-fail" \
  "[excerpt capped at 20 characters; see full log]"

setup_fixture
expect_failure "single overlay failure" overlay-fail "Private overlay readiness"
grep -q "overlay-fail" "$report_dir/private-overlay-readiness.log" ||
  fail "expected overlay failure log"
assert_summary "single overlay failure" failed true 1 0 \
  private-overlay-readiness=failed \
  android-public-dependency-provenance=passed \
  ios-shared-features-delta=passed \
  passkey-challenge-service=passed

setup_fixture
force_android_public_dependency_provenance_failure
expect_failure "single Android public dependency provenance failure" android-provenance-fail "Android public dependency provenance"
grep -q "fearless-utils provenance failed for forced fixture" "$report_dir/android-public-dependency-provenance.log" ||
  fail "expected Android public dependency provenance failure log"
assert_summary "single Android public dependency provenance failure" failed true 1 0 \
  android-public-dependency-provenance=failed \
  ios-shared-features-delta=passed
assert_blocker_report "single Android public dependency provenance failure" \
  "android-public-dependency-provenance" \
  "Restore fearless-utils-Android to the pinned commit plus exact committed library-only overlay with no extra drift" \
  "fearless-utils provenance failed for forced fixture"

setup_fixture
expect_failure "single fearless-utils derived-tree self-test failure" android-derived-tree-test-fail "Android public dependency provenance"
grep -q "fearless-utils derived-tree self-test failed" "$report_dir/android-public-dependency-provenance.log" ||
  fail "expected fearless-utils derived-tree self-test failure log"
assert_summary "single fearless-utils derived-tree self-test failure" failed true 1 0 \
  android-public-dependency-provenance=failed

setup_fixture
android_non_strict_script="$tmp_dir/audit-release-readiness-android-non-strict.sh"
cp "$AUDIT_SCRIPT" "$android_non_strict_script"
chmod +x "$android_non_strict_script"
perl -0pi -e 's#\./scripts/audit-public-artifacts\.sh --strict-provenance#./scripts/audit-public-artifacts.sh#g' "$android_non_strict_script"
original_audit_script="$AUDIT_SCRIPT"
AUDIT_SCRIPT="$android_non_strict_script"
expect_failure "Android strict provenance removal" good "Android public dependency provenance"
grep -q "Android public artifact strict provenance flag is required" "$report_dir/android-public-dependency-provenance.log" ||
  fail "expected Android aggregate to reject a non-strict public artifact audit"
AUDIT_SCRIPT="$original_audit_script"

setup_fixture
expect_failure "single Android public dependency handoff self-test failure" android-handoff-test-fail "Android public dependency provenance"
grep -q "android public dependency handoff self-test failed for android-handoff-test-fail" "$report_dir/android-public-dependency-provenance.log" ||
  fail "expected Android public dependency handoff self-test failure log"
assert_summary "single Android public dependency handoff self-test failure" failed true 1 0 \
  android-public-dependency-provenance=failed \
  ios-shared-features-delta=passed
assert_blocker_report "single Android public dependency handoff self-test failure" \
  "android-public-dependency-provenance" \
  "Android public artifact boundary and handoff bundle" \
  "android public dependency handoff self-test failed for android-handoff-test-fail"

setup_fixture
expect_failure "single Android public dependency handoff export failure" android-handoff-fail "Android public dependency provenance"
grep -q "android public dependency handoff export failed for android-handoff-fail" "$report_dir/android-public-dependency-provenance.log" ||
  fail "expected Android public dependency handoff export failure log"
assert_summary "single Android public dependency handoff export failure" failed true 1 0 \
  android-public-dependency-provenance=failed \
  ios-shared-features-delta=passed
assert_blocker_report "single Android public dependency handoff export failure" \
  "android-public-dependency-provenance" \
  "export-public-dependency-upstream-delta.sh" \
  "android public dependency handoff export failed for android-handoff-fail"

setup_fixture
expect_failure "blocked iOS shared-features removal readiness" ios-delta-blocked "iOS shared-features dependency delta"
grep -q -- "--require-ready rejected unresolved shared-features checkout mutation" "$report_dir/ios-shared-features-delta.log" ||
  fail "expected full-live iOS shared-features gate to reject blocked removal readiness"
grep -q '"status":"blocked"' "$workspace/fearless-iOS/build/reports/shared-features-delta-report.json" ||
  fail "expected blocked iOS shared-features diagnostic report to be retained"
assert_summary "blocked iOS shared-features removal readiness" failed true 1 0 \
  ios-shared-features-delta=failed \
  passkey-challenge-service=passed
assert_blocker_report "blocked iOS shared-features removal readiness" \
  "ios-shared-features-delta" \
  "Upstream or vendor every carried iOS shared-features/native-crypto delta" \
  "removalReadiness.status must be ready, got blocked"
assert_action_manifest "blocked iOS shared-features removal readiness" failed true 1 \
  "ios-shared-features-delta" \
  "Upstream or vendor every carried iOS shared-features/native-crypto delta" \
  "Upstream shared-features publication of carried compatibility and native-crypto deltas." \
  "cd fearless-iOS && bash scripts/deps/test-shared-features-delta-report.sh && bash scripts/deps/audit-shared-features-delta-report.sh \"\$PWD\" --write-report build/reports/shared-features-delta-report.json --require-ready"
assert_failed_check_metadata \
  "blocked iOS shared-features removal readiness" \
  "ios-shared-features-delta" \
  true \
  "upstream-dependency" \
  "Upstream or vendor every carried iOS shared-features/native-crypto delta" \
  "Upstream shared-features publication"

setup_fixture
expect_failure "single iOS shared-features delta self-test failure" ios-delta-test-fail "iOS shared-features dependency delta"
grep -q "shared-features delta self-test failed for ios-delta-test-fail" "$report_dir/ios-shared-features-delta.log" ||
  fail "expected iOS shared-features delta self-test failure log"
assert_summary "single iOS shared-features delta self-test failure" failed true 1 0 \
  ios-shared-features-delta=failed \
  passkey-challenge-service=passed
assert_blocker_report "single iOS shared-features delta self-test failure" \
  "ios-shared-features-delta" \
  "Upstream or vendor every carried iOS shared-features/native-crypto delta" \
  "shared-features delta self-test failed for ios-delta-test-fail"

setup_fixture
expect_failure "single passkey service failure" passkey-service-fail "Passkey challenge service implementation"
grep -q "passkey-service-fail" "$report_dir/passkey-challenge-service.log" ||
  fail "expected passkey challenge service failure log"

setup_fixture
expect_failure "single passkey deployment evidence failure" passkey-deployment-fail "Passkey deployment evidence"
grep -q "passkey deployment evidence failed for passkey-deployment-fail requireReady=true" "$report_dir/passkey-deployment-evidence.log" ||
  fail "expected passkey deployment evidence failure log"
assert_summary "single passkey deployment evidence failure" failed true 1 0 \
  passkey-deployment-evidence=failed \
  passkey-backup-prerequisites=passed
assert_blocker_report "single passkey deployment evidence failure" \
  "passkey-deployment-evidence" \
  "healthResponse ok=true/service=fearless-passkey-backup/rpId=fearlesswallet.io/schemaVersion=1" \
  "passkey deployment evidence failed for passkey-deployment-fail"

setup_fixture
expect_failure "single passkey Android origin parity failure" passkey-origin-fail "Passkey deployment evidence"
grep -q "passkey Android origin parity failed requireReady=true" "$report_dir/passkey-deployment-evidence.log" ||
  fail "expected passkey Android origin parity failure log"
assert_summary "single passkey Android origin parity failure" failed true 1 0 \
  passkey-deployment-evidence=failed \
  passkey-backup-prerequisites=passed
assert_blocker_report "single passkey Android origin parity failure" \
  "passkey-deployment-evidence" \
  "independently obtained distribution signer SHA-256 evidence" \
  "PASSKEY_ANDROID_RELEASE_SIGNER_EVIDENCE_SOURCE=distributed-apk|play-app-signing-certificate" \
  "AAB upload-key evidence is rejected" \
  "passkey Android origin parity failed requireReady=true"

setup_fixture
expect_failure "passkey Android origin parity self-test failure" passkey-origin-self-test-fail "Passkey deployment evidence"
grep -q "passkey Android origin parity self-test failed" "$report_dir/passkey-deployment-evidence.log" ||
  fail "expected passkey Android origin parity self-test failure log"

setup_fixture
perl -0pi -e 's/assertNoSecretLikeValues\(data\)/assertSecretLikeValuesAllowed(data)/' "$workspace/services/passkey-backup-challenge-service/scripts/audit-deployment-evidence.sh"
expect_failure "missing passkey deployment aggregate secret-like value gate" good "passkey deployment evidence secret-like value gate"

setup_fixture
perl -0pi -e 's/secret-like deployment evidence value/deployment evidence secret value accepted/' "$workspace/services/passkey-backup-challenge-service/scripts/test-deployment-evidence-audit.sh"
expect_failure "missing passkey deployment aggregate secret-like value negative test" good "passkey deployment evidence secret-like value negative test"

setup_fixture
expect_failure "single passkey backup prerequisites failure" passkey-fail "Passkey backup prerequisites"
grep -q "audit-passkey-backup-prerequisites.sh failed for passkey-fail" "$report_dir/passkey-backup-prerequisites.log" ||
  fail "expected passkey backup prerequisites failure log"
assert_summary "single passkey backup prerequisites failure" failed true 1 0 \
  passkey-backup-prerequisites=failed \
  passkey-production-smoke=passed \
  iroha-release-readiness=passed
assert_blocker_report "single passkey backup prerequisites failure" \
  "passkey-backup-prerequisites" \
  "live health response ok=true/service=fearless-passkey-backup/rpId=fearlesswallet.io/schemaVersion=1" \
  "audit-passkey-backup-prerequisites.sh failed for passkey-fail"

setup_fixture
expect_failure "single live site association failure" site-association-fail "Passkey backup prerequisites"
grep -q "strict live app association verification failed" "$report_dir/passkey-backup-prerequisites.log" ||
  fail "expected strict live site association failure log"
assert_summary "single live site association failure" failed true 1 0 \
  passkey-backup-prerequisites=failed \
  passkey-production-smoke=passed \
  iroha-release-readiness=passed
assert_blocker_report "single live site association failure" \
  "passkey-backup-prerequisites" \
  "exact source parity, JSON content types, X-Content-Type-Options: nosniff, and no redirects" \
  "strict live app association verification failed"

setup_fixture
expect_failure "single passkey production smoke failure" passkey-smoke-fail "Passkey production smoke"
grep -q "passkey production smoke failed for passkey-smoke-fail" "$report_dir/passkey-production-smoke.log" ||
  fail "expected passkey production smoke failure log"
grep -q "Provision PASSKEY_BACKUP_SMOKE_GRANT_HELPER=/run/secrets/passkey-smoke-grant-helper as a readable executable" "$report_dir/blockers.md" ||
  fail "passkey smoke recommended action missing executable grant helper"
grep -q "PASSKEY_BACKUP_SMOKE_GRANT_HELPER=/run/secrets/passkey-smoke-grant-helper provisioned as a readable executable" "$report_dir/blockers.md" ||
  fail "passkey smoke external prerequisite missing executable grant helper"
assert_summary "single passkey production smoke failure" failed true 1 0 \
  passkey-production-smoke=failed \
  iroha-release-readiness=passed
assert_blocker_report "single passkey production smoke failure" \
  "passkey-production-smoke" \
  "PASSKEY_BACKUP_SMOKE_GRANT_HELPER=/run/secrets/passkey-smoke-grant-helper as a readable executable" \
  "PASSKEY_BACKUP_SMOKE_GRANT_HELPER=/run/secrets/passkey-smoke-grant-helper provisioned as a readable executable" \
  "health, all four ceremony routes, and credential list/revoke/revoke-all contracts without persisting a test credential or creating an owner record" \
  "passkey production smoke failed for passkey-smoke-fail"
assert_action_manifest "single passkey production smoke failure" failed true 1 \
  "passkey-production-smoke" \
  "PASSKEY_BACKUP_SMOKE_GRANT_HELPER=/run/secrets/passkey-smoke-grant-helper as a readable executable" \
  "PASSKEY_BACKUP_SMOKE_GRANT_HELPER=/run/secrets/passkey-smoke-grant-helper provisioned as a readable executable" \
  "PASSKEY_BACKUP_SMOKE_GRANT_HELPER=/run/secrets/passkey-smoke-grant-helper PASSKEY_BACKUP_SMOKE_TIMEOUT_MS=10000 npm run smoke:production"

setup_fixture
expect_failure "enabled passkey acceptance is mandatory after successful smoke" passkey-enabled-acceptance-fail "Passkey production smoke"
grep -q "passkey enabled acceptance evidence missing" "$report_dir/passkey-production-smoke.log" ||
  fail "enabled acceptance failure must remain visible in the production smoke log"
assert_summary "enabled passkey acceptance is mandatory after successful smoke" failed true 1 0 \
  passkey-backup-prerequisites=passed \
  passkey-production-smoke=failed \
  iroha-release-readiness=passed

setup_fixture
expect_failure "single Iroha Taira/Nexus release readiness failure" iroha-fail "Iroha Taira/Nexus release prerequisites"
grep -q "audit-iroha-release-readiness.sh failed for iroha-fail" "$report_dir/iroha-release-readiness.log" ||
  fail "expected Iroha Taira/Nexus release readiness failure log"
assert_summary "single Iroha Taira/Nexus release readiness failure" failed true 1 0 \
  iroha-release-readiness=failed \
  iroha-wallet-coverage=passed
assert_blocker_report "single Iroha Taira/Nexus release readiness failure" \
  "iroha-release-readiness" \
  "Do not edit or publish from an unfinished external Iroha Git operation" \
  "package.json exports ./ivm-artifact" \
  "pinned Iroha JS SDK release artifact exporting ./ivm-artifact" \
  "Nexus route publication, canary, and wallet live transfer smoke evidence" \
  "audit-iroha-release-readiness.sh failed for iroha-fail"

setup_fixture
perl -0pi -e 's/assertNoSecretLikeValues\(manifest\)/assertSecretLikeValuesAllowed(manifest)/' "$workspace/scripts/audit-nexus-production-evidence.sh"
expect_failure "missing Nexus aggregate secret-like value gate" good "Nexus production evidence secret-like value gate"

setup_fixture
perl -0pi -e 's/secret-like Nexus evidence value/Nexus evidence secret value accepted/' "$workspace/scripts/test-nexus-production-evidence-audit.sh"
expect_failure "missing Nexus aggregate secret-like value negative test" good "Nexus production evidence secret-like value negative test"

setup_fixture
expect_failure "single Bitcoin broadcast evidence failure" bitcoin-fail "Web Bitcoin broadcast evidence"
grep -q "bitcoin broadcast evidence failed for bitcoin-fail" "$report_dir/web-bitcoin-broadcast-evidence.log" ||
  fail "expected Bitcoin broadcast evidence failure log"
assert_summary "single Bitcoin broadcast evidence failure" failed true 1 0 \
  web-bitcoin-broadcast-evidence=failed \
  si-production-smoke=passed
assert_blocker_report "single Bitcoin broadcast evidence failure" \
  "web-bitcoin-broadcast-evidence" \
  "canonical https://blockstream.info/testnet/api indexerUrl" \
  "confirmed indexer status.block_time proof" \
  "canonical Blockstream testnet indexer" \
  "bitcoin broadcast evidence failed for bitcoin-fail"
assert_action_manifest "single Bitcoin broadcast evidence failure" failed true 1 \
  "web-bitcoin-broadcast-evidence" \
  "canonical https://blockstream.info/testnet/api indexerUrl" \
  "canonical Blockstream testnet indexer" \
  "bitcoin broadcast evidence failed for bitcoin-fail"

setup_fixture
perl -0pi -e 's/secretLikeValueReason\(manifest\)/secretValueReasonRemoved(manifest)/' "$workspace/fearless-wallet-web/scripts/audit-bitcoin-broadcast-evidence.sh"
expect_failure "missing web Bitcoin aggregate secret-like value gate" good "web Bitcoin broadcast evidence secret-like value gate"

setup_fixture
perl -0pi -e 's/secret-like Bitcoin broadcast evidence value/Bitcoin broadcast secret value accepted/' "$workspace/fearless-wallet-web/scripts/test-bitcoin-broadcast-evidence-audit.sh"
expect_failure "missing web Bitcoin aggregate secret-like value negative test" good "web Bitcoin broadcast evidence secret-like value negative test"

setup_fixture
expect_failure "single Android XCM production evidence failure" xcm-fail "Android XCM production evidence"
grep -q "xcm registry metadata passed requireAllRoutes=true" "$report_dir/android-xcm-production-evidence.log" ||
  fail "expected Android XCM registry audit to run before production evidence"
grep -q "xcm effective registry self-test passed" "$report_dir/android-xcm-production-evidence.log" ||
  fail "expected Android XCM effective-registry self-test to run before production evidence"
grep -q "xcm effective registry passed requireAll=true discoveryUrl=https://raw.githubusercontent.com/soramitsu/shared-features-utils/master/chains/v13/chains.json" "$report_dir/android-xcm-production-evidence.log" ||
  fail "expected live Android XCM audit to bind the production discovery URL and require every approved route"
grep -q "xcm production evidence failed for xcm-fail" "$report_dir/android-xcm-production-evidence.log" ||
  fail "expected Android XCM production evidence failure log"
assert_summary "single Android XCM production evidence failure" failed true 1 0 \
  android-xcm-production-evidence=failed \
  web-bitcoin-broadcast-evidence=passed
assert_blocker_report "single Android XCM production evidence failure" \
  "android-xcm-production-evidence" \
  "0x-prefixed 32-byte extrinsicHash" \
  "14 of those destinations cover 39 multi-asset routes" \
  "Reviewed per-asset execution semantics" \
  "route-implementation-and-evidence" \
  "xcm production evidence failed for xcm-fail"
assert_action_manifest "single Android XCM production evidence failure" failed true 1 \
  "android-xcm-production-evidence" \
  "14 of those destinations cover 39 multi-asset routes" \
  "--effective-registry-report build/reports/xcm-effective-registry-report.json --require-ready" \
  "Reviewed per-asset execution semantics" \
  "route-implementation-and-evidence" \
  "xcm production evidence failed for xcm-fail"

setup_fixture
perl -0pi -e 's/secretLikeValueReason\(manifest\)/secretValueReasonRemoved(manifest)/' "$workspace/fearless-Android/scripts/audit-xcm-production-evidence.sh"
expect_failure "missing Android XCM aggregate secret-like value gate" good "Android XCM production evidence secret-like value gate"

setup_fixture
perl -0pi -e 's/secret-like XCM production evidence value/XCM production secret value accepted/' "$workspace/fearless-Android/scripts/test-xcm-production-evidence-audit.sh"
expect_failure "missing Android XCM aggregate secret-like value negative test" good "Android XCM production evidence secret-like value negative test"

setup_fixture
expect_failure "single Android XCM registry metadata failure" xcm-registry-fail "Android XCM production evidence"
grep -q "xcm registry metadata failed for xcm-registry-fail requireAllRoutes=true" "$report_dir/android-xcm-production-evidence.log" ||
  fail "expected Android XCM registry metadata failure log"
grep -q "xcm production evidence passed requireReady=true" "$report_dir/android-xcm-production-evidence.log" ||
  fail "xcm production evidence audit to still run after registry failure"
assert_summary "single Android XCM registry metadata failure" failed true 1 0 \
  android-xcm-production-evidence=failed \
  web-bitcoin-broadcast-evidence=passed
assert_blocker_report "single Android XCM registry metadata failure" \
  "android-xcm-production-evidence" \
  "approved_xcm_routes.tsv" \
  "production discovery intersection" \
  "Reviewed per-asset execution semantics" \
  "xcm registry metadata failed for xcm-registry-fail"
assert_action_manifest "single Android XCM registry metadata failure" failed true 1 \
  "android-xcm-production-evidence" \
  "approved_xcm_routes.tsv" \
  "route-implementation-and-evidence" \
  "xcm registry metadata failed for xcm-registry-fail"

setup_fixture
expect_failure "single Android XCM effective-registry self-test failure" xcm-effective-test-fail "Android XCM production evidence"
grep -q "xcm effective registry self-test failed for xcm-effective-test-fail" "$report_dir/android-xcm-production-evidence.log" ||
  fail "expected Android XCM effective-registry self-test failure log"
grep -q "xcm effective registry passed requireAll=true" "$report_dir/android-xcm-production-evidence.log" ||
  fail "expected Android XCM effective-registry audit to continue after its self-test failed"
assert_summary "single Android XCM effective-registry self-test failure" failed true 1 0 \
  android-xcm-production-evidence=failed \
  web-bitcoin-broadcast-evidence=passed

setup_fixture
expect_failure "single Android XCM effective-registry failure" xcm-effective-fail "Android XCM production evidence"
grep -q "xcm effective registry failed for xcm-effective-fail requireAll=true" "$report_dir/android-xcm-production-evidence.log" ||
  fail "expected Android XCM effective-registry failure log"
[[ -f "$workspace/fearless-Android/build/reports/xcm-effective-registry-report.json" ]] ||
  fail "expected failing Android XCM effective-registry audit to preserve its structured report"
[[ -f "$report_dir/android-xcm-effective-registry-report.json" ]] ||
  fail "expected failing Android XCM effective-registry report to be copied into release-readiness reports"
assert_summary "single Android XCM effective-registry failure" failed true 1 0 \
  android-xcm-production-evidence=failed \
  web-bitcoin-broadcast-evidence=passed

setup_fixture
expect_failure "Android XCM effective-registry policy drift" xcm-effective-report-policy-drift "Android XCM production evidence"
grep -q "ready XCM evidence effective-registry policy mismatch" "$report_dir/android-xcm-production-evidence.log" ||
  fail "expected Android XCM effective-registry policy drift diagnostic"
assert_summary "Android XCM effective-registry policy drift" failed true 2 0 \
  android-xcm-production-evidence=failed \
  release-unblock-bundle=failed \
  web-bitcoin-broadcast-evidence=passed

setup_fixture
expect_failure "Android XCM effective-registry live mode drift" xcm-effective-report-mode-drift "Android XCM production evidence"
grep -q "ready XCM evidence effective-registry report must be live and complete" "$report_dir/android-xcm-production-evidence.log" ||
  fail "expected Android XCM effective-registry live mode drift diagnostic"
assert_summary "Android XCM effective-registry live mode drift" failed true 2 0 \
  android-xcm-production-evidence=failed \
  release-unblock-bundle=failed \
  web-bitcoin-broadcast-evidence=passed

setup_fixture
expect_failure "missing Android XCM effective-registry report" xcm-effective-report-missing "Android XCM production evidence"
grep -q "expected effective XCM registry report was not written" "$report_dir/android-xcm-production-evidence.log" ||
  fail "expected missing Android XCM effective-registry report diagnostic"
assert_summary "missing Android XCM effective-registry report" failed true 2 0 \
  android-xcm-production-evidence=failed \
  release-unblock-bundle=failed \
  web-bitcoin-broadcast-evidence=passed

setup_fixture
expect_failure "single TI deployment evidence failure" ton-deployment-fail "TI deployment evidence"
grep -q "ton-indexer deployment evidence failed for ton-deployment-fail requireReady=true" "$report_dir/ti-deployment-evidence.log" ||
  fail "expected TI deployment evidence failure log"
assert_summary "single TI deployment evidence failure" failed true 1 0 \
  ti-deployment-evidence=failed \
  ti-production-smoke=passed
assert_blocker_report "single TI deployment evidence failure" \
  "ti-deployment-evidence" \
  "reviewed non-placeholder mainnet contract addresses" \
  "serviceInfo.schemaVersion=1 plus serviceInfo.serviceId=ti.soramitsu.io" \
  "healthInfo.serviceId=ti.soramitsu.io" \
  "ton-indexer deployment evidence failed for ton-deployment-fail"

setup_fixture
perl -0pi -e 's/secretLikeValueReason\(manifest\)/secretValueReasonRemoved(manifest)/' "$parent/ton-indexer/scripts/audit-deployment-evidence.sh"
expect_failure "missing TI deployment aggregate secret-like value gate" good "TI deployment evidence secret-like value gate"

setup_fixture
perl -0pi -e 's/secret-like deployment evidence value/TI deployment secret value accepted/' "$parent/ton-indexer/scripts/test-deployment-evidence-audit.sh"
expect_failure "missing TI deployment aggregate secret-like value negative test" good "TI deployment evidence secret-like value negative test"

setup_fixture
expect_failure "single SI deployment evidence failure" solswap-deployment-fail "SI deployment evidence"
grep -q "solswap-indexer deployment evidence failed for solswap-deployment-fail requireReady=true" "$report_dir/si-deployment-evidence.log" ||
  fail "expected SI deployment evidence failure log"
assert_summary "single SI deployment evidence failure" failed true 1 0 \
  si-deployment-evidence=failed \
  si-production-smoke=passed
assert_blocker_report "single SI deployment evidence failure" \
  "si-deployment-evidence" \
  "serviceInfo.schemaVersion=1 plus serviceInfo.serviceId=si.soramitsu.io with Solana mainnet identity" \
  "healthInfo with ok=true, serviceId=si.soramitsu.io" \
  "genesisHash=5eykt4UsFv8P8NJdTREpY1vzqKqZKvdpKuc147dw2N9d" \
  "latestSlot as a positive safe integer" \
  "syncedAt as an integer no more than 120 seconds before and no more than 30 seconds after smokePassedAt" \
  "solswap-indexer deployment evidence failed for solswap-deployment-fail"

setup_fixture
perl -0pi -e 's/secretLikeValueReason\(manifest\)/secretValueReasonRemoved(manifest)/' "$parent/solswap-indexer/scripts/audit-deployment-evidence.sh"
expect_failure "missing SI deployment aggregate secret-like value gate" good "SI deployment evidence secret-like value gate"

setup_fixture
perl -0pi -e 's/secret-like deployment evidence value/SI deployment secret value accepted/' "$parent/solswap-indexer/scripts/test-deployment-evidence-audit.sh"
expect_failure "missing SI deployment aggregate secret-like value negative test" good "SI deployment evidence secret-like value negative test"

setup_fixture
expect_failure "single PI deployment evidence failure" polkaswap-deployment-fail "PI deployment evidence"
grep -q "polkaswap-indexer deployment evidence failed for polkaswap-deployment-fail requireReady=true" "$report_dir/pi-deployment-evidence.log" ||
  fail "expected PI deployment evidence failure log"
assert_summary "single PI deployment evidence failure" failed true 1 0 \
  pi-deployment-evidence=failed \
  pi-production-smoke=passed
assert_blocker_report "single PI deployment evidence failure" \
  "pi-deployment-evidence" \
  "Deploy the current polkaswap-indexer worker and API to https://pi.soramitsu.io/graphql" \
  "POLKASWAP_CHAIN_START_BLOCK set" \
  "locally-controlled verifying archival primary RPC" \
  "independently-operated verifying archive RPC on distinct hosts" \
  "exact fixed audited SORA mainnet genesis/hash/timestamp anchor identity preflight on both RPCs before database access" \
  "exact dual-RPC agreement on finalized height, hash, canonical raw SCALE block, canonical raw SCALE events, and raw decimal timestamp milliseconds" \
  "compiled PostgreSQL worker health check proving the exact persisted chainState, matching filtered BLOCK snapshot" \
  "checkpoint freshness from 300 seconds behind through 30 seconds ahead, and secret-safe diagnostics" \
  "exact SORA mainnet genesisHash=0x7e4e32d0feafd4f9c9414b0be86373f9a1efa904809b683453a9af6856d38ad5" \
  "latestIndexedBlock as a positive safe integer" \
  "latestIndexedBlockHash as a canonical nonzero lowercase 32-byte hash" \
  "latestIndexedAt no more than 300 seconds before or 30 seconds after the smoke timestamp" \
  "soraRpcControls with primaryEndpoint, archiveEndpoint" \
  "primaryNodeControl=locally-controlled-verifying-archive" \
  "archiveNodeControl=independently-operated-verifying-archive" \
  "distinctHosts=true, exactIdentityPreflight=true" \
  "rawPayloadAgreement=height-hash-scale-block-events-timestamp" \
  "tlsEdgeControls proving TLS termination, forwarded-client-IP header overwrite" \
  "600 HTTP requests and 600 WebSocket upgrades per client per 60000ms" \
  "16 concurrent WebSockets per client" \
  "bash ../fearless/scripts/run-pinned-yarn.sh audit:deployment-evidence --require-ready" \
  "polkaswap-indexer deployment evidence failed for polkaswap-deployment-fail"
assert_action_manifest "single PI deployment evidence failure" failed true 1 \
  "pi-deployment-evidence" \
  "required POLKASWAP_CHAIN_START_BLOCK" \
  "exact fixed-anchor identity preflight" \
  "exact dual raw payload agreement" \
  "four-field health, SORA RPC-control, smoke, and TLS-edge evidence" \
  "rawPayloadAgreement=height-hash-scale-block-events-timestamp" \
  "cd ../polkaswap-indexer && bash ../fearless/scripts/run-pinned-yarn.sh audit:deployment-evidence --require-ready" \
  "polkaswap-indexer deployment evidence failed for polkaswap-deployment-fail"

setup_fixture
perl -0pi -e 's/secretLikeValueReason\(manifest\)/secretValueReasonRemoved(manifest)/' "$parent/polkaswap-indexer/scripts/audit-deployment-evidence.sh"
expect_failure "missing PI deployment aggregate secret-like value gate" good "PI deployment evidence secret-like value gate"

setup_fixture
perl -0pi -e 's/secret-like deployment evidence value/PI deployment secret value accepted/' "$parent/polkaswap-indexer/scripts/test-deployment-evidence-audit.sh"
expect_failure "missing PI deployment aggregate secret-like value negative test" good "PI deployment evidence secret-like value negative test"

setup_fixture
expect_failure "single TI production smoke failure" ton-fail "TI production smoke"
grep -q "ton smoke failed for ton-fail" "$report_dir/ti-production-smoke.log" ||
  fail "expected TI production smoke failure log"
assert_summary "single TI production smoke failure" failed true 1 0 \
  ti-production-smoke=failed \
  si-production-smoke=passed
assert_blocker_report "single TI production smoke failure" \
  "ti-production-smoke" \
  "health.serviceId=ti.soramitsu.io" \
  "TI production smoke also requires serviceInfo.schemaVersion=1, serviceInfo.serviceId=ti.soramitsu.io" \
  "chainId=ton:mainnet" \
  "OpenAPI title TONSWAP Indexer API" \
  "ton smoke failed for ton-fail"

setup_fixture
expect_failure "single SI production smoke failure" solswap-fail "SI production smoke"
grep -q "solswap smoke failed for solswap-fail" "$report_dir/si-production-smoke.log" ||
  fail "expected SI production smoke failure log"
assert_summary "single SI production smoke failure" failed true 1 0 \
  ti-production-smoke=passed \
  si-production-smoke=failed
assert_blocker_report "single SI production smoke failure" \
  "si-production-smoke" \
  "health.ok=true, health.serviceId=si.soramitsu.io" \
  "health.chainId=solana:mainnet" \
  "SI production smoke also requires serviceInfo.schemaVersion=1, serviceInfo.serviceId=si.soramitsu.io" \
  "OpenAPI title Solswap Indexer API" \
  "solswap smoke failed for solswap-fail"

setup_fixture
expect_failure "single PI production smoke failure" polkaswap-fail "PI production smoke"
grep -q "polkaswap smoke failed for polkaswap-fail" "$report_dir/pi-production-smoke.log" ||
  fail "expected PI production smoke failure log"
assert_summary "single PI production smoke failure" failed true 1 0 \
  ti-production-smoke=passed \
  si-production-smoke=passed \
  pi-production-smoke=failed
assert_blocker_report "single PI production smoke failure" \
  "pi-production-smoke" \
  "POLKASWAP_CHAIN_START_BLOCK set" \
  "locally-controlled verifying archival primary RPC" \
  "independently-operated verifying archive RPC on distinct hosts" \
  "exact fixed audited SORA mainnet genesis/hash/timestamp anchor identity preflight on both RPCs before database access" \
  "exact dual-RPC agreement on finalized height, hash, canonical raw SCALE block, canonical raw SCALE events, and raw decimal timestamp milliseconds" \
  "compiled PostgreSQL worker health check proving the exact persisted chainState, matching filtered BLOCK snapshot" \
  "checkpoint freshness from 300 seconds behind through 30 seconds ahead, and secret-safe diagnostics" \
  "health.serviceId=pi.soramitsu.io" \
  "health.schemaVersion=1" \
  "health.chainId=sora:mainnet" \
  "exact SORA mainnet genesisHash=0x7e4e32d0feafd4f9c9414b0be86373f9a1efa904809b683453a9af6856d38ad5" \
  "a positive latestIndexedBlock" \
  "a canonical nonzero lowercase 32-byte latestIndexedBlockHash" \
  "latestIndexedAt within 300 seconds behind or 30 seconds ahead" \
  "immutable exact fixed-anchor chainIdentity" \
  "chainState record at or below finalized height and coherent with the health height/hash/timestamp" \
  "live hash and raw timestamp reconciliation" \
  "matching filtered BLOCK snapshot" \
  "Solana/Solswap indexer contracts" \
  "polkaswap smoke failed for polkaswap-fail"
assert_action_manifest "single PI production smoke failure" failed true 1 \
  "pi-production-smoke" \
  "POLKASWAP_INDEXER_BASE_URL=https://pi.soramitsu.io/graphql" \
  "four SORA identity/checkpoint fields through GraphQL _health" \
  "coherent immutable chainIdentity, chainState, and filtered BLOCK worker state" \
  "distinct controlled verifying archival RPCs" \
  "exact identity preflight and raw payload agreement" \
  "required chain start" \
  "compiled secret-safe worker health check" \
  "cd ../polkaswap-indexer && POLKASWAP_INDEXER_BASE_URL=https://pi.soramitsu.io/graphql bash ../fearless/scripts/run-pinned-yarn.sh smoke:production" \
  "polkaswap smoke failed for polkaswap-fail"

setup_fixture
force_android_public_dependency_provenance_failure
expect_failure "multi failure aggregation" multi-fail "Passkey backup prerequisites"
grep -q "audit-plan-readiness.sh failed" "$report_dir/plan-readiness.log" ||
  fail "expected plan failure log"
grep -q "audit-release-pr-readiness.sh failed" "$report_dir/release-pr-readiness.log" ||
  fail "expected release PR readiness failure log"
grep -q "audit-passkey-challenge-service.sh failed" "$report_dir/passkey-challenge-service.log" ||
  fail "expected passkey challenge service failure log"
grep -q "passkey deployment evidence failed" "$report_dir/passkey-deployment-evidence.log" ||
  fail "expected passkey deployment evidence failure log"
grep -q "audit-passkey-backup-prerequisites.sh failed" "$report_dir/passkey-backup-prerequisites.log" ||
  fail "expected passkey failure log"
grep -q "passkey production smoke failed" "$report_dir/passkey-production-smoke.log" ||
  fail "expected passkey production smoke failure log"
grep -q "audit-iroha-release-readiness.sh failed" "$report_dir/iroha-release-readiness.log" ||
  fail "expected Iroha Taira/Nexus failure log"
grep -q "audit-iroha-wallet-coverage.sh failed" "$report_dir/iroha-wallet-coverage.log" ||
  fail "expected Iroha Taira/Nexus wallet coverage failure log"
grep -q "fearless-utils provenance failed" "$report_dir/android-public-dependency-provenance.log" ||
  fail "expected Android public dependency provenance failure log"
grep -q "shared-features delta audit failed" "$report_dir/ios-shared-features-delta.log" ||
  fail "expected iOS shared-features delta failure log"
grep -q "xcm production evidence failed" "$report_dir/android-xcm-production-evidence.log" ||
  fail "expected Android XCM production evidence failure log"
grep -q "xcm registry metadata failed" "$report_dir/android-xcm-production-evidence.log" ||
  fail "expected Android XCM registry metadata failure log"
grep -q "bitcoin broadcast evidence failed" "$report_dir/web-bitcoin-broadcast-evidence.log" ||
  fail "expected Bitcoin broadcast evidence failure log"
grep -q "ton-indexer deployment evidence failed" "$report_dir/ti-deployment-evidence.log" ||
  fail "expected TI deployment evidence failure log"
grep -q "solswap-indexer deployment evidence failed" "$report_dir/si-deployment-evidence.log" ||
  fail "expected SI deployment evidence failure log"
grep -q "polkaswap-indexer deployment evidence failed" "$report_dir/pi-deployment-evidence.log" ||
  fail "expected PI deployment evidence failure log"
grep -q "ton smoke failed" "$report_dir/ti-production-smoke.log" ||
  fail "expected TON smoke failure log"
assert_summary "multi failure aggregation" failed true 16 0 \
  plan-readiness=failed \
  release-pr-readiness=failed \
  android-public-dependency-provenance=failed \
  ios-shared-features-delta=failed \
  passkey-challenge-service=failed \
  passkey-deployment-evidence=failed \
  passkey-backup-prerequisites=failed \
  passkey-production-smoke=failed \
  iroha-release-readiness=failed \
  iroha-wallet-coverage=failed \
  android-xcm-production-evidence=failed \
  web-bitcoin-broadcast-evidence=failed \
  ti-deployment-evidence=failed \
  si-deployment-evidence=failed \
  pi-deployment-evidence=failed \
  ti-production-smoke=failed \
  si-production-smoke=passed
assert_blocker_report "multi failure aggregation" \
  "plan-readiness" \
  "passkey-deployment-evidence" \
  "passkey-backup-prerequisites" \
  "passkey-production-smoke" \
  "ti-deployment-evidence" \
  "pi-deployment-evidence" \
  "ti-production-smoke" \
  "ton smoke failed for multi-fail"
assert_action_manifest "multi failure aggregation" failed true 16 \
  "release-pr-readiness" \
  "passkey-challenge-service" \
  "passkey-production-smoke" \
  "pi-deployment-evidence" \
  "ti-production-smoke" \
  "ton smoke failed for multi-fail"

setup_fixture
mkdir -p "$workspace/fearless-Android/build/reports"
printf '%s\n' 'stale-effective-registry-report' > "$workspace/fearless-Android/build/reports/xcm-effective-registry-report.json"
expect_success "skip-live fixture" live-fail --skip-live
grep -q '"status":"blocked"' "$workspace/fearless-iOS/build/reports/shared-features-delta-report.json" ||
  fail "expected --skip-live to retain blocked iOS shared-features diagnostics without treating them as live readiness"
grep -q '"mutatesResolvedCheckout":true' "$workspace/fearless-iOS/build/reports/shared-features-delta-report.json" ||
  fail "expected --skip-live iOS report to preserve checkout mutation state"
[[ ! -f "$report_dir/github-governance.log" ]] ||
  fail "expected GitHub log to be absent when --skip-live is used"
[[ ! -f "$report_dir/release-pr-readiness.log" ]] ||
  fail "expected release PR readiness log to be absent when --skip-live is used"
[[ ! -f "$report_dir/source-publication-readiness.log" ]] ||
  fail "expected source publication log to be absent when --skip-live is used"
[[ ! -f "$report_dir/ti-production-smoke.log" ]] ||
  fail "expected TI smoke log to be absent when --skip-live is used"
[[ ! -f "$report_dir/si-production-smoke.log" ]] ||
  fail "expected SI smoke log to be absent when --skip-live is used"
[[ ! -f "$report_dir/pi-production-smoke.log" ]] ||
  fail "expected PI smoke log to be absent when --skip-live is used"
[[ ! -f "$report_dir/passkey-production-smoke.log" ]] ||
  fail "expected passkey production smoke log to be absent when --skip-live is used"
[[ ! -f "$workspace/fearless-site-web-app-associations-20260726/build/live-association-verifier-called" ]] ||
  fail "expected strict fearless-site-web-app-associations-20260726 live app association verifier not to run during --skip-live"
grep -q "requireReady=false" "$report_dir/android-xcm-production-evidence.log" ||
  fail "expected Android XCM production evidence audit to run without --require-ready when --skip-live is used"
grep -q "xcm registry metadata passed requireAllRoutes=false" "$report_dir/android-xcm-production-evidence.log" ||
  fail "expected Android XCM registry audit to run without --require-all-routes-executable when --skip-live is used"
grep -q "xcm effective registry self-test passed" "$report_dir/android-xcm-production-evidence.log" ||
  fail "expected Android XCM effective-registry self-test during --skip-live"
grep -q "xcm effective registry passed requireAll=false discoveryUrl=<none>" "$report_dir/android-xcm-production-evidence.log" ||
  fail "expected Android XCM effective-registry audit to stay offline during --skip-live"
[[ -f "$workspace/fearless-Android/build/reports/xcm-registry-gap-report.json" ]] ||
  fail "expected Android XCM registry gap report to be written during --skip-live"
[[ -f "$report_dir/android-xcm-registry-gap-report.json" ]] ||
  fail "expected Android XCM registry gap report to be copied into release-readiness reports during --skip-live"
[[ -f "$workspace/fearless-Android/build/reports/xcm-effective-registry-report.json" ]] ||
  fail "expected Android XCM effective-registry report to be written during --skip-live"
! grep -q 'stale-effective-registry-report' "$workspace/fearless-Android/build/reports/xcm-effective-registry-report.json" ||
  fail "expected stale Android XCM effective-registry output to be cleared before the audit"
[[ -f "$report_dir/android-xcm-effective-registry-report.json" ]] ||
  fail "expected Android XCM effective-registry report to be copied into release-readiness reports during --skip-live"
[[ -f "$workspace/fearless-Android/build/reports/xcm-production-evidence-template.json" ]] ||
  fail "expected Android XCM production evidence template to be written during --skip-live"
[[ -f "$report_dir/android-xcm-production-evidence-template.json" ]] ||
  fail "expected Android XCM production evidence template to be copied into release-readiness reports during --skip-live"
grep -q "requireReady=false" "$report_dir/web-bitcoin-broadcast-evidence.log" ||
  fail "expected Bitcoin broadcast evidence audit to run without --require-ready when --skip-live is used"
[[ -f "$workspace/fearless-wallet-web/build/reports/bitcoin-broadcast-evidence-template.json" ]] ||
  fail "expected Bitcoin broadcast evidence template to be written during --skip-live"
[[ -f "$report_dir/web-bitcoin-broadcast-evidence-template.json" ]] ||
  fail "expected Bitcoin broadcast evidence template to be copied into release-readiness reports during --skip-live"
[[ -f "$workspace/build/reports/nexus-production-evidence-template.json" ]] ||
  fail "expected Nexus production evidence template to be written during --skip-live"
[[ -f "$report_dir/nexus-production-evidence-template.json" ]] ||
  fail "expected Nexus production evidence template to be copied into release-readiness reports during --skip-live"
[[ -f "$workspace/services/passkey-backup-challenge-service/build/reports/production-deployment-evidence-template.json" ]] ||
  fail "expected passkey deployment evidence template to be written during --skip-live"
[[ -f "$report_dir/passkey-deployment-evidence-template.json" ]] ||
  fail "expected passkey deployment evidence template to be copied into release-readiness reports during --skip-live"
[[ -f "$workspace/../ton-indexer/build/reports/production-deployment-evidence-template.json" ]] ||
  fail "expected TI deployment evidence template to be written during --skip-live"
[[ -f "$report_dir/ti-deployment-evidence-template.json" ]] ||
  fail "expected TI deployment evidence template to be copied into release-readiness reports during --skip-live"
[[ -f "$workspace/../solswap-indexer/build/reports/production-deployment-evidence-template.json" ]] ||
  fail "expected SI deployment evidence template to be written during --skip-live"
[[ -f "$report_dir/si-deployment-evidence-template.json" ]] ||
  fail "expected SI deployment evidence template to be copied into release-readiness reports during --skip-live"
[[ -f "$workspace/../polkaswap-indexer/build/reports/production-deployment-evidence-template.json" ]] ||
  fail "expected PI deployment evidence template to be written during --skip-live"
[[ -f "$report_dir/pi-deployment-evidence-template.json" ]] ||
  fail "expected PI deployment evidence template to be copied into release-readiness reports during --skip-live"
grep -q "requireReady=false" "$report_dir/passkey-deployment-evidence.log" ||
  fail "expected passkey deployment evidence audit to run without --require-ready when --skip-live is used"
grep -q "passkey Android origin parity self-test passed" "$report_dir/passkey-deployment-evidence.log" ||
  fail "expected passkey Android origin parity self-test during --skip-live"
grep -q "passkey Android origin parity passed requireReady=false" "$report_dir/passkey-deployment-evidence.log" ||
  fail "expected blocked-mode passkey Android origin parity audit during --skip-live"
grep -q "requireReady=false" "$report_dir/ti-deployment-evidence.log" ||
  fail "expected TI deployment evidence audit to run without --require-ready when --skip-live is used"
grep -q "requireReady=false" "$report_dir/si-deployment-evidence.log" ||
  fail "expected SI deployment evidence audit to run without --require-ready when --skip-live is used"
grep -q "requireReady=false" "$report_dir/pi-deployment-evidence.log" ||
  fail "expected PI deployment evidence audit to run without --require-ready when --skip-live is used"
assert_summary "skip-live fixture" incomplete false 0 7 \
  github-governance=skipped \
  release-pr-readiness=skipped \
  passkey-production-smoke=skipped \
  ti-production-smoke=skipped \
  si-production-smoke=skipped \
  pi-production-smoke=skipped \
  source-publication-readiness=skipped \
  android-public-dependency-provenance=passed \
  ios-shared-features-delta=passed \
  android-xcm-production-evidence=passed \
  web-bitcoin-broadcast-evidence=passed \
  passkey-deployment-evidence=passed \
  ti-deployment-evidence=passed \
  si-deployment-evidence=passed \
  pi-deployment-evidence=passed \
  passkey-backup-prerequisites=passed
assert_blocker_report "skip-live fixture" \
  "Release readiness is incomplete because required live checks were skipped" \
  "not production-ready evidence" \
  "Skipped Checks" \
  "github-governance" \
  "release-pr-readiness" \
  "source-publication-readiness"
assert_action_manifest "skip-live fixture" incomplete false 0

setup_fixture
stale_success_blocker_report_script="$tmp_dir/audit-release-readiness-stale-success-blocker-report.sh"
stale_success_blocker_report_mutator="$tmp_dir/append-stale-success-blocker-report.js"
write_file "$stale_success_blocker_report_mutator" \
  "const fs = require('node:fs')" \
  "const file = process.argv[2]" \
  "fs.appendFileSync(file, '## Failed Checks\\n\\n### Release PR readiness\\n\\n- Slug: \`release-pr-readiness\`\\n- Exit code: \`1\`\\n- Log: \`/tmp/stale-release-pr-readiness.log\`\\n\\n')"
cp "$AUDIT_SCRIPT" "$stale_success_blocker_report_script"
chmod +x "$stale_success_blocker_report_script"
perl -0pi -e "s#\nwrite_blocker_report\nif validate_release_output_contracts#\nwrite_blocker_report\nnode \"$stale_success_blocker_report_mutator\" \"\\\$BLOCKERS_FILE\"\nif validate_release_output_contracts#" "$stale_success_blocker_report_script"
original_audit_script="$AUDIT_SCRIPT"
AUDIT_SCRIPT="$stale_success_blocker_report_script"
expect_failure \
  "stale success blocker report fixture" \
  live-fail \
  "blockers.md unexpected failed-checks section" \
  --skip-live
assert_summary "stale success blocker report fixture" failed false 1 7 \
  plan-readiness=passed \
  source-publication-readiness=skipped \
  release-output-contract=failed
assert_failed_check_metadata \
  "stale success blocker report fixture" \
  "release-output-contract" \
  false \
  "local-code" \
  "Fix the release-readiness summary, action manifest, or blocker-report contract failure" \
  "No external prerequisite is expected"
[[ ! -e "$report_dir/unblock-bundle" ]] ||
  fail "invalid release-readiness outputs reached canonical bundle publication"
grep -q "blockers.md unexpected failed-checks section" "$report_dir/release-output-contract.log" ||
  fail "expected terminal release output-contract failure log"
AUDIT_SCRIPT="$original_audit_script"

setup_fixture
stale_success_orphan_failed_section_script="$tmp_dir/audit-release-readiness-stale-success-orphan-failed-section.sh"
stale_success_orphan_failed_section_mutator="$tmp_dir/append-stale-success-orphan-failed-section.js"
write_file "$stale_success_orphan_failed_section_mutator" \
  "const fs = require('node:fs')" \
  "const file = process.argv[2]" \
  "fs.appendFileSync(file, '### Release PR readiness\\n\\n- Slug: \`release-pr-readiness\`\\n- Exit code: \`1\`\\n- Log: \`/tmp/stale-release-pr-readiness.log\`\\n\\n')"
cp "$AUDIT_SCRIPT" "$stale_success_orphan_failed_section_script"
chmod +x "$stale_success_orphan_failed_section_script"
perl -0pi -e "s#\nwrite_blocker_report\nif validate_release_output_contracts#\nwrite_blocker_report\nnode \"$stale_success_orphan_failed_section_mutator\" \"\\\$BLOCKERS_FILE\"\nif validate_release_output_contracts#" "$stale_success_orphan_failed_section_script"
original_audit_script="$AUDIT_SCRIPT"
AUDIT_SCRIPT="$stale_success_orphan_failed_section_script"
expect_failure \
  "stale success orphan failed-section fixture" \
  good \
  "blockers.md unexpected failed section when no failures"
AUDIT_SCRIPT="$original_audit_script"

setup_fixture
stale_success_skipped_report_script="$tmp_dir/audit-release-readiness-stale-success-skipped-report.sh"
stale_success_skipped_report_mutator="$tmp_dir/append-stale-success-skipped-report.js"
write_file "$stale_success_skipped_report_mutator" \
  "const fs = require('node:fs')" \
  "const file = process.argv[2]" \
  "fs.appendFileSync(file, '## Skipped Checks\\n\\n- \`github-governance\` (GitHub governance)\\n')"
cp "$AUDIT_SCRIPT" "$stale_success_skipped_report_script"
chmod +x "$stale_success_skipped_report_script"
perl -0pi -e "s#\nwrite_blocker_report\nif validate_release_output_contracts#\nwrite_blocker_report\nnode \"$stale_success_skipped_report_mutator\" \"\\\$BLOCKERS_FILE\"\nif validate_release_output_contracts#" "$stale_success_skipped_report_script"
original_audit_script="$AUDIT_SCRIPT"
AUDIT_SCRIPT="$stale_success_skipped_report_script"
expect_failure \
  "stale success skipped blocker report fixture" \
  good \
  "blockers.md unexpected skipped-checks section"
AUDIT_SCRIPT="$original_audit_script"

setup_fixture
blockers_extra_passed_non_failure_line_mutator="$tmp_dir/append-blocker-report-extra-passed-non-failure-line.js"
write_file "$blockers_extra_passed_non_failure_line_mutator" \
  "const fs = require('node:fs')" \
  "const file = process.argv[2]" \
  "const text = fs.readFileSync(file, 'utf8')" \
  "const marker = 'No blocking release-readiness failures recorded.\\n'" \
  "if (!text.includes(marker)) throw new Error('expected no-blockers success message')" \
  "fs.writeFileSync(file, text.replace(marker, marker + '- Unsupported note: stale no-blocker operator context\\n'))"

setup_fixture
blockers_extra_passed_non_failure_line_script="$tmp_dir/audit-release-readiness-blockers-extra-passed-non-failure-line.sh"
cp "$AUDIT_SCRIPT" "$blockers_extra_passed_non_failure_line_script"
chmod +x "$blockers_extra_passed_non_failure_line_script"
perl -0pi -e "s#\nwrite_blocker_report\nif validate_release_output_contracts#\nwrite_blocker_report\nnode \"$blockers_extra_passed_non_failure_line_mutator\" \"\\\$BLOCKERS_FILE\"\nif validate_release_output_contracts#" "$blockers_extra_passed_non_failure_line_script"
original_audit_script="$AUDIT_SCRIPT"
AUDIT_SCRIPT="$blockers_extra_passed_non_failure_line_script"
expect_failure \
  "blocker report extra passed non-failure-line fixture" \
  good \
  "blockers.md non-failure section content mismatch"
AUDIT_SCRIPT="$original_audit_script"

setup_fixture
blockers_extra_incomplete_non_failure_line_mutator="$tmp_dir/append-blocker-report-extra-incomplete-non-failure-line.js"
write_file "$blockers_extra_incomplete_non_failure_line_mutator" \
  "const fs = require('node:fs')" \
  "const file = process.argv[2]" \
  "const text = fs.readFileSync(file, 'utf8')" \
  "const marker = 'Release readiness is incomplete because required live checks were skipped; this run is not production-ready evidence.\\n'" \
  "if (!text.includes(marker)) throw new Error('expected incomplete non-failure message')" \
  "fs.writeFileSync(file, text.replace(marker, marker + '- Unsupported note: stale incomplete operator context\\n'))"

blockers_extra_incomplete_non_failure_line_script="$tmp_dir/audit-release-readiness-blockers-extra-incomplete-non-failure-line.sh"
cp "$AUDIT_SCRIPT" "$blockers_extra_incomplete_non_failure_line_script"
chmod +x "$blockers_extra_incomplete_non_failure_line_script"
perl -0pi -e "s#\nwrite_blocker_report\nif validate_release_output_contracts#\nwrite_blocker_report\nnode \"$blockers_extra_incomplete_non_failure_line_mutator\" \"\\\$BLOCKERS_FILE\"\nif validate_release_output_contracts#" "$blockers_extra_incomplete_non_failure_line_script"
original_audit_script="$AUDIT_SCRIPT"
AUDIT_SCRIPT="$blockers_extra_incomplete_non_failure_line_script"
expect_failure \
  "blocker report extra incomplete non-failure-line fixture" \
  live-fail \
  "blockers.md non-failure section content mismatch" \
  --skip-live
AUDIT_SCRIPT="$original_audit_script"

setup_fixture
stale_failure_success_message_script="$tmp_dir/audit-release-readiness-stale-failure-success-message.sh"
stale_failure_success_message_mutator="$tmp_dir/append-stale-failure-success-message.js"
write_file "$stale_failure_success_message_mutator" \
  "const fs = require('node:fs')" \
  "const file = process.argv[2]" \
  "fs.appendFileSync(file, 'No blocking release-readiness failures recorded.\\n')"
cp "$AUDIT_SCRIPT" "$stale_failure_success_message_script"
chmod +x "$stale_failure_success_message_script"
perl -0pi -e "s#\nwrite_blocker_report\nif validate_release_output_contracts#\nwrite_blocker_report\nnode \"$stale_failure_success_message_mutator\" \"\\\$BLOCKERS_FILE\"\nif validate_release_output_contracts#" "$stale_failure_success_message_script"
original_audit_script="$AUDIT_SCRIPT"
AUDIT_SCRIPT="$stale_failure_success_message_script"
expect_failure \
  "stale failure success message fixture" \
  release-pr-fail \
  "blockers.md unexpected no-blockers success message"
AUDIT_SCRIPT="$original_audit_script"

setup_fixture
missing_failed_blocker_report_script="$tmp_dir/audit-release-readiness-missing-failed-blocker-report.sh"
missing_failed_blocker_report_mutator="$tmp_dir/remove-failed-blocker-report-section-heading.js"
write_file "$missing_failed_blocker_report_mutator" \
  "const fs = require('node:fs')" \
  "const file = process.argv[2]" \
  "const text = fs.readFileSync(file, 'utf8')" \
  "const marker = '## Failed Checks\\n\\n'" \
  "const markerIndex = text.indexOf(marker)" \
  "if (markerIndex === -1) throw new Error('expected failed section')" \
  "fs.writeFileSync(file, text.slice(0, markerIndex) + text.slice(markerIndex + marker.length))"
cp "$AUDIT_SCRIPT" "$missing_failed_blocker_report_script"
chmod +x "$missing_failed_blocker_report_script"
perl -0pi -e "s#\nwrite_blocker_report\nif validate_release_output_contracts#\nwrite_blocker_report\nnode \"$missing_failed_blocker_report_mutator\" \"\\\$BLOCKERS_FILE\"\nif validate_release_output_contracts#" "$missing_failed_blocker_report_script"
original_audit_script="$AUDIT_SCRIPT"
AUDIT_SCRIPT="$missing_failed_blocker_report_script"
expect_failure \
  "missing failed blocker report fixture" \
  release-pr-fail \
  "blockers.md missing failed-checks section"
AUDIT_SCRIPT="$original_audit_script"

setup_fixture
blockers_run_live_script="$tmp_dir/audit-release-readiness-blockers-run-live-drift.sh"
blockers_run_live_mutator="$tmp_dir/corrupt-blocker-report-run-live.js"
write_file "$blockers_run_live_mutator" \
  "const fs = require('node:fs')" \
  "const file = process.argv[2]" \
  "const text = fs.readFileSync(file, 'utf8').replace(/^- Run live checks: false$/m, '- Run live checks: true')" \
  "fs.writeFileSync(file, text)"
cp "$AUDIT_SCRIPT" "$blockers_run_live_script"
chmod +x "$blockers_run_live_script"
perl -0pi -e "s#\nwrite_blocker_report\nif validate_release_output_contracts#\nwrite_blocker_report\nnode \"$blockers_run_live_mutator\" \"\\\$BLOCKERS_FILE\"\nif validate_release_output_contracts#" "$blockers_run_live_script"
original_audit_script="$AUDIT_SCRIPT"
AUDIT_SCRIPT="$blockers_run_live_script"
expect_failure \
  "blocker report runLive drift fixture" \
  live-fail \
  "blockers.md runLive mismatch" \
  --skip-live
AUDIT_SCRIPT="$original_audit_script"

setup_fixture
blockers_extra_preamble_line_script="$tmp_dir/audit-release-readiness-blockers-extra-preamble-line.sh"
blockers_extra_preamble_line_mutator="$tmp_dir/append-blocker-report-extra-preamble-line.js"
write_file "$blockers_extra_preamble_line_mutator" \
  "const fs = require('node:fs')" \
  "const file = process.argv[2]" \
  "const text = fs.readFileSync(file, 'utf8')" \
  "const line = text.match(/^- Run live checks: .+$/m)?.[0]" \
  "if (!line) throw new Error('expected runLive line')" \
  "fs.writeFileSync(file, text.replace(line + '\\n', line + '\\n- Unsupported metadata: stale operator-only release context\\n'))"
cp "$AUDIT_SCRIPT" "$blockers_extra_preamble_line_script"
chmod +x "$blockers_extra_preamble_line_script"
perl -0pi -e "s#\nwrite_blocker_report\nif validate_release_output_contracts#\nwrite_blocker_report\nnode \"$blockers_extra_preamble_line_mutator\" \"\\\$BLOCKERS_FILE\"\nif validate_release_output_contracts#" "$blockers_extra_preamble_line_script"
original_audit_script="$AUDIT_SCRIPT"
AUDIT_SCRIPT="$blockers_extra_preamble_line_script"
expect_failure \
  "blocker report extra preamble-line fixture" \
  live-fail \
  "blockers.md preamble content mismatch" \
  --skip-live
AUDIT_SCRIPT="$original_audit_script"

setup_fixture
blockers_heading_script="$tmp_dir/audit-release-readiness-blockers-heading-drift.sh"
blockers_heading_mutator="$tmp_dir/corrupt-blocker-report-heading.js"
write_file "$blockers_heading_mutator" \
  "const fs = require('node:fs')" \
  "const file = process.argv[2]" \
  "const text = fs.readFileSync(file, 'utf8').replace(/^# Release Readiness Blockers$/m, '# Release Readiness Report')" \
  "fs.writeFileSync(file, text)"
cp "$AUDIT_SCRIPT" "$blockers_heading_script"
chmod +x "$blockers_heading_script"
perl -0pi -e "s#\nwrite_blocker_report\nif validate_release_output_contracts#\nwrite_blocker_report\nnode \"$blockers_heading_mutator\" \"\\\$BLOCKERS_FILE\"\nif validate_release_output_contracts#" "$blockers_heading_script"
original_audit_script="$AUDIT_SCRIPT"
AUDIT_SCRIPT="$blockers_heading_script"
expect_failure \
  "blocker report heading drift fixture" \
  live-fail \
  "blockers.md heading mismatch" \
  --skip-live
AUDIT_SCRIPT="$original_audit_script"

setup_fixture
blockers_extra_section_script="$tmp_dir/audit-release-readiness-blockers-extra-section.sh"
blockers_extra_section_mutator="$tmp_dir/append-blocker-report-extra-section.js"
write_file "$blockers_extra_section_mutator" \
  "const fs = require('node:fs')" \
  "const file = process.argv[2]" \
  "fs.appendFileSync(file, '## Operator Notes\\n\\nThis unsupported section must not be accepted.\\n')"
cp "$AUDIT_SCRIPT" "$blockers_extra_section_script"
chmod +x "$blockers_extra_section_script"
perl -0pi -e "s#\nwrite_blocker_report\nif validate_release_output_contracts#\nwrite_blocker_report\nnode \"$blockers_extra_section_mutator\" \"\\\$BLOCKERS_FILE\"\nif validate_release_output_contracts#" "$blockers_extra_section_script"
original_audit_script="$AUDIT_SCRIPT"
AUDIT_SCRIPT="$blockers_extra_section_script"
expect_failure \
  "blocker report extra top-level section fixture" \
  release-pr-fail \
  "blockers.md top-level section mismatch"
AUDIT_SCRIPT="$original_audit_script"

setup_fixture
blockers_duplicate_generated_at_script="$tmp_dir/audit-release-readiness-blockers-duplicate-generated-at.sh"
blockers_duplicate_generated_at_mutator="$tmp_dir/duplicate-blocker-report-generated-at.js"
write_file "$blockers_duplicate_generated_at_mutator" \
  "const fs = require('node:fs')" \
  "const file = process.argv[2]" \
  "const text = fs.readFileSync(file, 'utf8')" \
  "const line = text.match(/^- Generated at: .+$/m)?.[0]" \
  "if (!line) throw new Error('expected generatedAt line')" \
  "fs.writeFileSync(file, text + line + '\\n')"
cp "$AUDIT_SCRIPT" "$blockers_duplicate_generated_at_script"
chmod +x "$blockers_duplicate_generated_at_script"
perl -0pi -e "s#\nwrite_blocker_report\nif validate_release_output_contracts#\nwrite_blocker_report\nnode \"$blockers_duplicate_generated_at_mutator\" \"\\\$BLOCKERS_FILE\"\nif validate_release_output_contracts#" "$blockers_duplicate_generated_at_script"
original_audit_script="$AUDIT_SCRIPT"
AUDIT_SCRIPT="$blockers_duplicate_generated_at_script"
expect_failure \
  "blocker report duplicate generatedAt fixture" \
  live-fail \
  "blockers.md generatedAt line count mismatch" \
  --skip-live
AUDIT_SCRIPT="$original_audit_script"

setup_fixture
blockers_duplicate_totals_script="$tmp_dir/audit-release-readiness-blockers-duplicate-totals.sh"
blockers_duplicate_totals_mutator="$tmp_dir/duplicate-blocker-report-totals.js"
write_file "$blockers_duplicate_totals_mutator" \
  "const fs = require('node:fs')" \
  "const file = process.argv[2]" \
  "const text = fs.readFileSync(file, 'utf8')" \
  "const line = text.match(/^- Totals: .+$/m)?.[0]" \
  "if (!line) throw new Error('expected totals line')" \
  "fs.writeFileSync(file, text + line + '\\n')"
cp "$AUDIT_SCRIPT" "$blockers_duplicate_totals_script"
chmod +x "$blockers_duplicate_totals_script"
perl -0pi -e "s#\nwrite_blocker_report\nif validate_release_output_contracts#\nwrite_blocker_report\nnode \"$blockers_duplicate_totals_mutator\" \"\\\$BLOCKERS_FILE\"\nif validate_release_output_contracts#" "$blockers_duplicate_totals_script"
original_audit_script="$AUDIT_SCRIPT"
AUDIT_SCRIPT="$blockers_duplicate_totals_script"
expect_failure \
  "blocker report duplicate totals fixture" \
  live-fail \
  "blockers.md totals mismatch" \
  --skip-live
AUDIT_SCRIPT="$original_audit_script"

setup_fixture
missing_skipped_blocker_report_script="$tmp_dir/audit-release-readiness-missing-skipped-blocker-report.sh"
missing_skipped_blocker_report_mutator="$tmp_dir/remove-skipped-blocker-report-section.js"
write_file "$missing_skipped_blocker_report_mutator" \
  "const fs = require('node:fs')" \
  "const file = process.argv[2]" \
  "const text = fs.readFileSync(file, 'utf8')" \
  "const marker = '## Skipped Checks\\n\\n'" \
  "const markerIndex = text.indexOf(marker)" \
  "if (markerIndex === -1) throw new Error('expected skipped section')" \
  "const nextIndex = text.indexOf('\\n## ', markerIndex + marker.length)" \
  "fs.writeFileSync(file, nextIndex === -1 ? text.slice(0, markerIndex) : text.slice(0, markerIndex) + text.slice(nextIndex + 1))"
cp "$AUDIT_SCRIPT" "$missing_skipped_blocker_report_script"
chmod +x "$missing_skipped_blocker_report_script"
perl -0pi -e "s#\nwrite_blocker_report\nif validate_release_output_contracts#\nwrite_blocker_report\nnode \"$missing_skipped_blocker_report_mutator\" \"\\\$BLOCKERS_FILE\"\nif validate_release_output_contracts#" "$missing_skipped_blocker_report_script"
original_audit_script="$AUDIT_SCRIPT"
AUDIT_SCRIPT="$missing_skipped_blocker_report_script"
expect_failure \
  "missing skipped blocker report fixture" \
  live-fail \
  "blockers.md missing skipped-checks section" \
  --skip-live
AUDIT_SCRIPT="$original_audit_script"

setup_fixture
skipped_count_blocker_report_script="$tmp_dir/audit-release-readiness-skipped-count-blocker-report.sh"
skipped_count_blocker_report_mutator="$tmp_dir/duplicate-skipped-blocker-report-line.js"
write_file "$skipped_count_blocker_report_mutator" \
  "const fs = require('node:fs')" \
  "const file = process.argv[2]" \
  "const text = fs.readFileSync(file, 'utf8')" \
  "const marker = '## Skipped Checks\\n\\n'" \
  "const markerIndex = text.indexOf(marker)" \
  "if (markerIndex === -1) throw new Error('expected skipped section')" \
  "const bodyStart = markerIndex + marker.length" \
  "const nextIndex = text.indexOf('\\n## ', bodyStart)" \
  "const body = nextIndex === -1 ? text.slice(bodyStart) : text.slice(bodyStart, nextIndex)" \
  "const suffix = nextIndex === -1 ? '' : text.slice(nextIndex)" \
  "const lines = body.trimEnd().split('\\n').filter(Boolean)" \
  "if (lines.length < 1) throw new Error('expected skipped line')" \
  "lines.push(lines[0])" \
  "fs.writeFileSync(file, text.slice(0, bodyStart) + lines.join('\\n') + '\\n' + suffix)"
cp "$AUDIT_SCRIPT" "$skipped_count_blocker_report_script"
chmod +x "$skipped_count_blocker_report_script"
perl -0pi -e "s#\nwrite_blocker_report\nif validate_release_output_contracts#\nwrite_blocker_report\nnode \"$skipped_count_blocker_report_mutator\" \"\\\$BLOCKERS_FILE\"\nif validate_release_output_contracts#" "$skipped_count_blocker_report_script"
original_audit_script="$AUDIT_SCRIPT"
AUDIT_SCRIPT="$skipped_count_blocker_report_script"
expect_failure \
  "skipped blocker report count drift fixture" \
  live-fail \
  "blockers.md skipped section count mismatch" \
  --skip-live
AUDIT_SCRIPT="$original_audit_script"

setup_fixture
skipped_order_blocker_report_script="$tmp_dir/audit-release-readiness-skipped-order-blocker-report.sh"
skipped_order_blocker_report_mutator="$tmp_dir/reverse-skipped-blocker-report-section.js"
write_file "$skipped_order_blocker_report_mutator" \
  "const fs = require('node:fs')" \
  "const file = process.argv[2]" \
  "const text = fs.readFileSync(file, 'utf8')" \
  "const marker = '## Skipped Checks\\n\\n'" \
  "const markerIndex = text.indexOf(marker)" \
  "if (markerIndex === -1) throw new Error('expected skipped section')" \
  "const bodyStart = markerIndex + marker.length" \
  "const nextIndex = text.indexOf('\\n## ', bodyStart)" \
  "const body = nextIndex === -1 ? text.slice(bodyStart) : text.slice(bodyStart, nextIndex)" \
  "const suffix = nextIndex === -1 ? '' : text.slice(nextIndex)" \
  "const trailing = body.endsWith('\\n') ? '\\n' : ''" \
  "const lines = body.trimEnd().split('\\n').filter(Boolean)" \
  "if (lines.length < 2) throw new Error('expected multiple skipped lines')" \
  "fs.writeFileSync(file, text.slice(0, bodyStart) + lines.reverse().join('\\n') + trailing + suffix)"
cp "$AUDIT_SCRIPT" "$skipped_order_blocker_report_script"
chmod +x "$skipped_order_blocker_report_script"
perl -0pi -e "s#\nwrite_blocker_report\nif validate_release_output_contracts#\nwrite_blocker_report\nnode \"$skipped_order_blocker_report_mutator\" \"\\\$BLOCKERS_FILE\"\nif validate_release_output_contracts#" "$skipped_order_blocker_report_script"
original_audit_script="$AUDIT_SCRIPT"
AUDIT_SCRIPT="$skipped_order_blocker_report_script"
expect_failure \
  "skipped blocker report order drift fixture" \
  live-fail \
  "blockers.md skipped section order mismatch at index 0" \
  --skip-live
AUDIT_SCRIPT="$original_audit_script"

setup_fixture
skipped_extra_blank_line_blocker_report_script="$tmp_dir/audit-release-readiness-skipped-extra-blank-line-blocker-report.sh"
skipped_extra_blank_line_blocker_report_mutator="$tmp_dir/insert-skipped-blocker-report-extra-blank-line.js"
write_file "$skipped_extra_blank_line_blocker_report_mutator" \
  "const fs = require('node:fs')" \
  "const file = process.argv[2]" \
  "const text = fs.readFileSync(file, 'utf8')" \
  "const marker = '## Skipped Checks\\n\\n'" \
  "const markerIndex = text.indexOf(marker)" \
  "if (markerIndex === -1) throw new Error('expected skipped section')" \
  "const bodyStart = markerIndex + marker.length" \
  "const lineEnd = text.indexOf('\\n', bodyStart)" \
  "if (lineEnd === -1) throw new Error('expected skipped line')" \
  "fs.writeFileSync(file, text.slice(0, lineEnd + 1) + '\\n' + text.slice(lineEnd + 1))"
cp "$AUDIT_SCRIPT" "$skipped_extra_blank_line_blocker_report_script"
chmod +x "$skipped_extra_blank_line_blocker_report_script"
perl -0pi -e "s#\nwrite_blocker_report\nif validate_release_output_contracts#\nwrite_blocker_report\nnode \"$skipped_extra_blank_line_blocker_report_mutator\" \"\\\$BLOCKERS_FILE\"\nif validate_release_output_contracts#" "$skipped_extra_blank_line_blocker_report_script"
original_audit_script="$AUDIT_SCRIPT"
AUDIT_SCRIPT="$skipped_extra_blank_line_blocker_report_script"
expect_failure \
  "skipped blocker report extra blank-line fixture" \
  live-fail \
  "blockers.md skipped section content mismatch" \
  --skip-live
AUDIT_SCRIPT="$original_audit_script"

setup_fixture
missing_log_script="$tmp_dir/audit-release-readiness-missing-log.sh"
cp "$AUDIT_SCRIPT" "$missing_log_script"
chmod +x "$missing_log_script"
perl -0pi -e 's#\nwrite_blocker_report\nif validate_release_output_contracts#\nwrite_blocker_report\nrm -f "\$REPORT_DIR/release-pr-readiness.log"\nif validate_release_output_contracts#' "$missing_log_script"
original_audit_script="$AUDIT_SCRIPT"
AUDIT_SCRIPT="$missing_log_script"
expect_failure \
  "missing failed log fixture" \
  release-pr-fail \
  "release-pr-readiness log file must be a regular file"
AUDIT_SCRIPT="$original_audit_script"

setup_fixture
empty_failed_log_script="$tmp_dir/audit-release-readiness-empty-failed-log.sh"
cp "$AUDIT_SCRIPT" "$empty_failed_log_script"
chmod +x "$empty_failed_log_script"
perl -0pi -e 's#\nwrite_blocker_report\nif validate_release_output_contracts#\nwrite_blocker_report\n: > "\$REPORT_DIR/release-pr-readiness.log"\nif validate_release_output_contracts#' "$empty_failed_log_script"
original_audit_script="$AUDIT_SCRIPT"
AUDIT_SCRIPT="$empty_failed_log_script"
expect_failure \
  "empty failed log fixture" \
  release-pr-fail \
  "release-pr-readiness failed log file must be non-empty"
AUDIT_SCRIPT="$original_audit_script"

setup_fixture
timestamp_contract_script="$tmp_dir/audit-release-readiness-timestamp-contract-drift.sh"
timestamp_contract_mutator="$tmp_dir/corrupt-report-timestamps.js"
write_file "$timestamp_contract_mutator" \
  "const fs = require('node:fs')" \
  "const [summaryFile, actionsFile, blockersFile] = process.argv.slice(2)" \
  "for (const file of [summaryFile, actionsFile]) {" \
  "  const data = JSON.parse(fs.readFileSync(file, 'utf8'))" \
  "  data.generatedAt = '2026-07-07 11:47:06 UTC'" \
  "  fs.writeFileSync(file, JSON.stringify(data, null, 2) + '\\n')" \
  "}" \
  "const blockers = fs.readFileSync(blockersFile, 'utf8').replace(/^- Generated at: .*$/m, '- Generated at: 2026-07-07 11:47:06 UTC')" \
  "fs.writeFileSync(blockersFile, blockers)"
cp "$AUDIT_SCRIPT" "$timestamp_contract_script"
chmod +x "$timestamp_contract_script"
perl -0pi -e "s#(write_blocker_report\\n)#\\1node \"$timestamp_contract_mutator\" \"\\\$SUMMARY_FILE\" \"\\\$ACTIONS_FILE\" \"\\\$BLOCKERS_FILE\"\\n#" "$timestamp_contract_script"
original_audit_script="$AUDIT_SCRIPT"
AUDIT_SCRIPT="$timestamp_contract_script"
expect_failure \
  "generatedAt format drift fixture" \
  good \
  "summary.json generatedAt must be a UTC ISO-8601 timestamp"
AUDIT_SCRIPT="$original_audit_script"

setup_fixture
timestamp_value_contract_mutator="$tmp_dir/corrupt-report-timestamp-values.js"
write_file "$timestamp_value_contract_mutator" \
  "const fs = require('node:fs')" \
  "const [summaryFile, actionsFile, blockersFile, value] = process.argv.slice(2)" \
  "for (const file of [summaryFile, actionsFile]) {" \
  "  const data = JSON.parse(fs.readFileSync(file, 'utf8'))" \
  "  data.generatedAt = value" \
  "  fs.writeFileSync(file, JSON.stringify(data, null, 2) + '\\n')" \
  "}" \
  "const blockers = fs.readFileSync(blockersFile, 'utf8').replace(/^- Generated at: .*$/m, '- Generated at: ' + value)" \
  "fs.writeFileSync(blockersFile, blockers)"

timestamp_value_contract_cases=(
  "2026-02-31T00:00:00Z|generatedAt invalid calendar fixture|summary.json generatedAt must be a valid UTC ISO-8601 timestamp"
  "2999-01-01T00:00:00Z|generatedAt future fixture|summary.json generatedAt must not be in the future"
)
for timestamp_value_case in "${timestamp_value_contract_cases[@]}"; do
  IFS='|' read -r timestamp_value timestamp_value_fixture_name timestamp_value_expected_failure <<< "$timestamp_value_case"
  setup_fixture
  timestamp_value_contract_script="$tmp_dir/audit-release-readiness-timestamp-value-drift.sh"
  cp "$AUDIT_SCRIPT" "$timestamp_value_contract_script"
  chmod +x "$timestamp_value_contract_script"
  perl -0pi -e "s#(write_blocker_report\\n)#\\1node \"$timestamp_value_contract_mutator\" \"\\\$SUMMARY_FILE\" \"\\\$ACTIONS_FILE\" \"\\\$BLOCKERS_FILE\" \"$timestamp_value\"\\n#" "$timestamp_value_contract_script"
  original_audit_script="$AUDIT_SCRIPT"
  AUDIT_SCRIPT="$timestamp_value_contract_script"
  expect_failure \
    "$timestamp_value_fixture_name" \
    good \
    "$timestamp_value_expected_failure"
  AUDIT_SCRIPT="$original_audit_script"
done

setup_fixture
run_live_contract_script="$tmp_dir/audit-release-readiness-run-live-contract-drift.sh"
run_live_contract_mutator="$tmp_dir/corrupt-run-live-types.js"
write_file "$run_live_contract_mutator" \
  "const fs = require('node:fs')" \
  "for (const file of process.argv.slice(2)) {" \
  "  const data = JSON.parse(fs.readFileSync(file, 'utf8'))" \
  "  data.runLive = 'true'" \
  "  fs.writeFileSync(file, JSON.stringify(data, null, 2) + '\\n')" \
  "}"
cp "$AUDIT_SCRIPT" "$run_live_contract_script"
chmod +x "$run_live_contract_script"
perl -0pi -e "s#(write_action_manifest\\n)#\\1node \"$run_live_contract_mutator\" \"\\\$SUMMARY_FILE\" \"\\\$ACTIONS_FILE\"\\n#" "$run_live_contract_script"
original_audit_script="$AUDIT_SCRIPT"
AUDIT_SCRIPT="$run_live_contract_script"
expect_failure \
  "summary runLive type drift fixture" \
  good \
  "summary.json runLive must be boolean"
AUDIT_SCRIPT="$original_audit_script"

setup_fixture
actions_run_live_contract_script="$tmp_dir/audit-release-readiness-actions-run-live-contract-drift.sh"
cp "$AUDIT_SCRIPT" "$actions_run_live_contract_script"
chmod +x "$actions_run_live_contract_script"
perl -0pi -e "s#(write_action_manifest\\n)#\\1node \"$run_live_contract_mutator\" \"\\\$ACTIONS_FILE\"\\n#" "$actions_run_live_contract_script"
original_audit_script="$AUDIT_SCRIPT"
AUDIT_SCRIPT="$actions_run_live_contract_script"
expect_failure \
  "actions runLive type drift fixture" \
  good \
  "actions.json runLive must be boolean"
AUDIT_SCRIPT="$original_audit_script"

setup_fixture
top_level_contract_script="$tmp_dir/audit-release-readiness-top-level-contract-drift.sh"
top_level_contract_mutator="$tmp_dir/corrupt-top-level-release-output.js"
write_file "$top_level_contract_mutator" \
  "const fs = require('node:fs')" \
  "const [summaryFile, actionsFile, blockersFile, mutation] = process.argv.slice(2)" \
  "const summary = JSON.parse(fs.readFileSync(summaryFile, 'utf8'))" \
  "const actions = JSON.parse(fs.readFileSync(actionsFile, 'utf8'))" \
  "let blockers = fs.readFileSync(blockersFile, 'utf8')" \
	  "switch (mutation) {" \
	  "  case 'summary-schema-version': summary.schemaVersion = 2; break" \
	  "  case 'summary-schema-version-string': summary.schemaVersion = String(summary.schemaVersion); break" \
	  "  case 'summary-schema-version-null': summary.schemaVersion = null; break" \
	  "  case 'actions-schema-version': actions.schemaVersion = 2; break" \
	  "  case 'actions-schema-version-string': actions.schemaVersion = String(actions.schemaVersion); break" \
	  "  case 'actions-schema-version-fraction': actions.schemaVersion = actions.schemaVersion + 0.5; break" \
	  "  case 'actions-generated-at': actions.generatedAt = '2026-07-07T00:00:01Z'; break" \
  "  case 'blockers-generated-at': blockers = blockers.replace(/^- Generated at: .+$/m, '- Generated at: 2026-07-07T00:00:02Z'); break" \
  "  case 'summary-status-invalid': summary.status = 'deferred'; break" \
  "  case 'summary-status': summary.status = 'passed'; break" \
  "  case 'actions-status-invalid': actions.status = 'deferred'; break" \
  "  case 'actions-status': actions.status = 'passed'; break" \
  "  case 'actions-run-live': actions.runLive = !summary.runLive; break" \
  "  default: throw new Error('unknown top-level release output mutation ' + mutation)" \
  "}" \
  "fs.writeFileSync(summaryFile, JSON.stringify(summary, null, 2) + '\\n')" \
  "fs.writeFileSync(actionsFile, JSON.stringify(actions, null, 2) + '\\n')" \
  "fs.writeFileSync(blockersFile, blockers)"

top_level_contract_cases=(
  "summary-schema-version|summary schemaVersion drift fixture|summary.json schemaVersion mismatch"
  "summary-schema-version-string|summary schemaVersion string fixture|summary.json schemaVersion must be integer 1"
  "summary-schema-version-null|summary schemaVersion null fixture|summary.json schemaVersion must be integer 1"
  "actions-schema-version|actions schemaVersion drift fixture|actions.json schemaVersion mismatch"
  "actions-schema-version-string|actions schemaVersion string fixture|actions.json schemaVersion must be integer 1"
  "actions-schema-version-fraction|actions schemaVersion fractional fixture|actions.json schemaVersion must be integer 1"
  "actions-generated-at|actions generatedAt mismatch fixture|actions.json generatedAt must match summary.json"
  "blockers-generated-at|blocker report generatedAt mismatch fixture|blockers.md generatedAt must match summary.json"
  "summary-status-invalid|summary invalid status fixture|summary.json status must be passed, failed, or incomplete"
  "summary-status|summary status drift fixture|summary.json status mismatch"
  "actions-status-invalid|actions invalid status fixture|actions.json status must be passed, failed, or incomplete"
  "actions-status|actions status drift fixture|actions.json status mismatch"
  "actions-run-live|actions runLive mismatch fixture|actions.json runLive must match summary.json"
)
for top_level_case in "${top_level_contract_cases[@]}"; do
  IFS='|' read -r top_level_mutation top_level_fixture_name top_level_expected_failure <<< "$top_level_case"
  setup_fixture
  top_level_contract_case_script="$tmp_dir/audit-release-readiness-${top_level_mutation}-drift.sh"
  cp "$AUDIT_SCRIPT" "$top_level_contract_case_script"
  chmod +x "$top_level_contract_case_script"
  perl -0pi -e "s#(write_blocker_report\\n)#\\1node \"$top_level_contract_mutator\" \"\\\$SUMMARY_FILE\" \"\\\$ACTIONS_FILE\" \"\\\$BLOCKERS_FILE\" \"$top_level_mutation\"\\n#" "$top_level_contract_case_script"
  original_audit_script="$AUDIT_SCRIPT"
  AUDIT_SCRIPT="$top_level_contract_case_script"
  expect_failure \
    "$top_level_fixture_name" \
    release-pr-fail \
    "$top_level_expected_failure"
  AUDIT_SCRIPT="$original_audit_script"
done

setup_fixture
top_level_key_contract_mutator="$tmp_dir/corrupt-top-level-release-output-keys.js"
write_file "$top_level_key_contract_mutator" \
  "const fs = require('node:fs')" \
  "const [summaryFile, actionsFile, mutation] = process.argv.slice(2)" \
  "const summary = JSON.parse(fs.readFileSync(summaryFile, 'utf8'))" \
  "const actions = JSON.parse(fs.readFileSync(actionsFile, 'utf8'))" \
  "switch (mutation) {" \
  "  case 'summary-extra-key': summary.unexpectedField = 'unexpected release-readiness summary field'; break" \
  "  case 'actions-extra-key': actions.unexpectedField = 'unexpected release-readiness actions field'; break" \
  "  case 'summary-totals-extra-key': summary.totals.unexpectedField = 1; break" \
  "  case 'actions-totals-extra-key': actions.totals.unexpectedField = 1; break" \
  "  default: throw new Error('unknown top-level key mutation ' + mutation)" \
  "}" \
  "fs.writeFileSync(summaryFile, JSON.stringify(summary, null, 2) + '\\n')" \
  "fs.writeFileSync(actionsFile, JSON.stringify(actions, null, 2) + '\\n')"

top_level_key_contract_cases=(
  "summary-extra-key|summary top-level unexpected field fixture|summary.json keys mismatch"
  "actions-extra-key|actions top-level unexpected field fixture|actions.json keys mismatch"
  "summary-totals-extra-key|summary totals unexpected field fixture|summary.json totals keys mismatch"
  "actions-totals-extra-key|actions totals unexpected field fixture|actions.json totals keys mismatch"
)
for top_level_case in "${top_level_key_contract_cases[@]}"; do
  IFS='|' read -r top_level_mutation top_level_fixture_name top_level_expected_failure <<< "$top_level_case"
  setup_fixture
  top_level_key_contract_case_script="$tmp_dir/audit-release-readiness-${top_level_mutation}-drift.sh"
  cp "$AUDIT_SCRIPT" "$top_level_key_contract_case_script"
  chmod +x "$top_level_key_contract_case_script"
  perl -0pi -e "s#(write_action_manifest\\n)#\\1node \"$top_level_key_contract_mutator\" \"\\\$SUMMARY_FILE\" \"\\\$ACTIONS_FILE\" \"$top_level_mutation\"\\n#" "$top_level_key_contract_case_script"
  original_audit_script="$AUDIT_SCRIPT"
  AUDIT_SCRIPT="$top_level_key_contract_case_script"
  expect_failure \
    "$top_level_fixture_name" \
    release-pr-fail \
    "$top_level_expected_failure"
  AUDIT_SCRIPT="$original_audit_script"
done

setup_fixture
top_level_object_type_contract_mutator="$tmp_dir/corrupt-top-level-release-output-object-types.js"
write_file "$top_level_object_type_contract_mutator" \
  "const fs = require('node:fs')" \
  "const [summaryFile, actionsFile, mutation] = process.argv.slice(2)" \
  "const summary = JSON.parse(fs.readFileSync(summaryFile, 'utf8'))" \
  "const actions = JSON.parse(fs.readFileSync(actionsFile, 'utf8'))" \
  "switch (mutation) {" \
  "  case 'summary-array': fs.writeFileSync(summaryFile, JSON.stringify([summary], null, 2) + '\\n'); break" \
  "  case 'summary-null': fs.writeFileSync(summaryFile, 'null\\n'); break" \
  "  case 'actions-array': fs.writeFileSync(actionsFile, JSON.stringify([actions], null, 2) + '\\n'); break" \
  "  case 'actions-string': fs.writeFileSync(actionsFile, JSON.stringify('stale release-readiness actions') + '\\n'); break" \
  "  default: throw new Error('unknown top-level object type mutation ' + mutation)" \
  "}"

top_level_object_type_contract_cases=(
  "summary-array|summary top-level non-object array fixture|summary.json must be an object"
  "summary-null|summary top-level non-object null fixture|summary.json must be an object"
  "actions-array|actions top-level non-object array fixture|actions.json must be an object"
  "actions-string|actions top-level non-object string fixture|actions.json must be an object"
)
for top_level_case in "${top_level_object_type_contract_cases[@]}"; do
  IFS='|' read -r top_level_mutation top_level_fixture_name top_level_expected_failure <<< "$top_level_case"
  setup_fixture
  top_level_object_type_contract_case_script="$tmp_dir/audit-release-readiness-${top_level_mutation}-drift.sh"
  cp "$AUDIT_SCRIPT" "$top_level_object_type_contract_case_script"
  chmod +x "$top_level_object_type_contract_case_script"
  perl -0pi -e "s#(write_action_manifest\\n)#\\1node \"$top_level_object_type_contract_mutator\" \"\\\$SUMMARY_FILE\" \"\\\$ACTIONS_FILE\" \"$top_level_mutation\"\\n#" "$top_level_object_type_contract_case_script"
  original_audit_script="$AUDIT_SCRIPT"
  AUDIT_SCRIPT="$top_level_object_type_contract_case_script"
  expect_failure \
    "$top_level_fixture_name" \
    release-pr-fail \
    "$top_level_expected_failure"
  AUDIT_SCRIPT="$original_audit_script"
done

setup_fixture
collection_type_contract_mutator="$tmp_dir/corrupt-release-output-collection-types.js"
write_file "$collection_type_contract_mutator" \
  "const fs = require('node:fs')" \
  "const [summaryFile, actionsFile, mutation] = process.argv.slice(2)" \
  "const summary = JSON.parse(fs.readFileSync(summaryFile, 'utf8'))" \
  "const actions = JSON.parse(fs.readFileSync(actionsFile, 'utf8'))" \
  "switch (mutation) {" \
  "  case 'summary-checks-object': summary.checks = { stale: summary.checks[0] || null }; break" \
  "  case 'summary-checks-null': summary.checks = null; break" \
  "  case 'actions-blockers-object': actions.blockers = { stale: actions.blockers[0] || null }; break" \
  "  case 'actions-blockers-string': actions.blockers = 'stale release-readiness blockers'; break" \
  "  default: throw new Error('unknown release output collection type mutation ' + mutation)" \
  "}" \
  "fs.writeFileSync(summaryFile, JSON.stringify(summary, null, 2) + '\\n')" \
  "fs.writeFileSync(actionsFile, JSON.stringify(actions, null, 2) + '\\n')"

collection_type_contract_cases=(
  "summary-checks-object|summary checks non-array object fixture|summary.json checks must be an array"
  "summary-checks-null|summary checks non-array null fixture|summary.json checks must be an array"
  "actions-blockers-object|actions blockers non-array object fixture|actions.json blockers must be an array"
  "actions-blockers-string|actions blockers non-array string fixture|actions.json blockers must be an array"
)
for collection_type_case in "${collection_type_contract_cases[@]}"; do
  IFS='|' read -r collection_type_mutation collection_type_fixture_name collection_type_expected_failure <<< "$collection_type_case"
  setup_fixture
  collection_type_contract_case_script="$tmp_dir/audit-release-readiness-${collection_type_mutation}-drift.sh"
  cp "$AUDIT_SCRIPT" "$collection_type_contract_case_script"
  chmod +x "$collection_type_contract_case_script"
  perl -0pi -e "s#(write_action_manifest\\n)#\\1node \"$collection_type_contract_mutator\" \"\\\$SUMMARY_FILE\" \"\\\$ACTIONS_FILE\" \"$collection_type_mutation\"\\n#" "$collection_type_contract_case_script"
  original_audit_script="$AUDIT_SCRIPT"
  AUDIT_SCRIPT="$collection_type_contract_case_script"
  expect_failure \
    "$collection_type_fixture_name" \
    release-pr-fail \
    "$collection_type_expected_failure"
  AUDIT_SCRIPT="$original_audit_script"
done

setup_fixture
totals_object_type_contract_mutator="$tmp_dir/corrupt-release-output-totals-object-types.js"
write_file "$totals_object_type_contract_mutator" \
  "const fs = require('node:fs')" \
  "const [summaryFile, actionsFile, mutation] = process.argv.slice(2)" \
  "const summary = JSON.parse(fs.readFileSync(summaryFile, 'utf8'))" \
  "const actions = JSON.parse(fs.readFileSync(actionsFile, 'utf8'))" \
  "switch (mutation) {" \
  "  case 'summary-totals-array': summary.totals = [summary.totals]; break" \
  "  case 'summary-totals-null': summary.totals = null; break" \
  "  case 'actions-totals-array': actions.totals = [actions.totals]; break" \
  "  case 'actions-totals-string': actions.totals = 'stale release-readiness totals'; break" \
  "  default: throw new Error('unknown release output totals object type mutation ' + mutation)" \
  "}" \
  "fs.writeFileSync(summaryFile, JSON.stringify(summary, null, 2) + '\\n')" \
  "fs.writeFileSync(actionsFile, JSON.stringify(actions, null, 2) + '\\n')"

totals_object_type_contract_cases=(
  "summary-totals-array|summary totals non-object array fixture|summary.json totals must be an object"
  "summary-totals-null|summary totals non-object null fixture|summary.json totals must be an object"
  "actions-totals-array|actions totals non-object array fixture|actions.json totals must be an object"
  "actions-totals-string|actions totals non-object string fixture|actions.json totals must be an object"
)
for totals_object_type_case in "${totals_object_type_contract_cases[@]}"; do
  IFS='|' read -r totals_object_type_mutation totals_object_type_fixture_name totals_object_type_expected_failure <<< "$totals_object_type_case"
  setup_fixture
  totals_object_type_contract_case_script="$tmp_dir/audit-release-readiness-${totals_object_type_mutation}-drift.sh"
  cp "$AUDIT_SCRIPT" "$totals_object_type_contract_case_script"
  chmod +x "$totals_object_type_contract_case_script"
  perl -0pi -e "s#(write_action_manifest\\n)#\\1node \"$totals_object_type_contract_mutator\" \"\\\$SUMMARY_FILE\" \"\\\$ACTIONS_FILE\" \"$totals_object_type_mutation\"\\n#" "$totals_object_type_contract_case_script"
  original_audit_script="$AUDIT_SCRIPT"
  AUDIT_SCRIPT="$totals_object_type_contract_case_script"
  expect_failure \
    "$totals_object_type_fixture_name" \
    release-pr-fail \
    "$totals_object_type_expected_failure"
  AUDIT_SCRIPT="$original_audit_script"
done

setup_fixture
totals_value_type_contract_mutator="$tmp_dir/corrupt-release-output-totals-value-types.js"
write_file "$totals_value_type_contract_mutator" \
  "const fs = require('node:fs')" \
  "const [summaryFile, actionsFile, mutation] = process.argv.slice(2)" \
  "const summary = JSON.parse(fs.readFileSync(summaryFile, 'utf8'))" \
  "const actions = JSON.parse(fs.readFileSync(actionsFile, 'utf8'))" \
  "switch (mutation) {" \
  "  case 'summary-passed-string': summary.totals.passed = String(summary.totals.passed); break" \
  "  case 'summary-total-null': summary.totals.total = null; break" \
  "  case 'actions-failed-fraction': actions.totals.failed = actions.totals.failed + 0.5; break" \
  "  case 'actions-skipped-negative': actions.totals.skipped = -1; break" \
  "  default: throw new Error('unknown release output totals value type mutation ' + mutation)" \
  "}" \
  "fs.writeFileSync(summaryFile, JSON.stringify(summary, null, 2) + '\\n')" \
  "fs.writeFileSync(actionsFile, JSON.stringify(actions, null, 2) + '\\n')"

totals_value_type_contract_cases=(
  "summary-passed-string|summary totals string count fixture|summary.json totals.passed must be a non-negative integer"
  "summary-total-null|summary totals null count fixture|summary.json totals.total must be a non-negative integer"
  "actions-failed-fraction|actions totals fractional count fixture|actions.json totals.failed must be a non-negative integer"
  "actions-skipped-negative|actions totals negative count fixture|actions.json totals.skipped must be a non-negative integer"
)
for totals_value_type_case in "${totals_value_type_contract_cases[@]}"; do
  IFS='|' read -r totals_value_type_mutation totals_value_type_fixture_name totals_value_type_expected_failure <<< "$totals_value_type_case"
  setup_fixture
  totals_value_type_contract_case_script="$tmp_dir/audit-release-readiness-${totals_value_type_mutation}-drift.sh"
  cp "$AUDIT_SCRIPT" "$totals_value_type_contract_case_script"
  chmod +x "$totals_value_type_contract_case_script"
  perl -0pi -e "s#(write_action_manifest\\n)#\\1node \"$totals_value_type_contract_mutator\" \"\\\$SUMMARY_FILE\" \"\\\$ACTIONS_FILE\" \"$totals_value_type_mutation\"\\n#" "$totals_value_type_contract_case_script"
  original_audit_script="$AUDIT_SCRIPT"
  AUDIT_SCRIPT="$totals_value_type_contract_case_script"
  expect_failure \
    "$totals_value_type_fixture_name" \
    release-pr-fail \
    "$totals_value_type_expected_failure"
  AUDIT_SCRIPT="$original_audit_script"
done

setup_fixture
exit_code_value_type_contract_mutator="$tmp_dir/corrupt-release-output-exit-code-value-types.js"
write_file "$exit_code_value_type_contract_mutator" \
  "const fs = require('node:fs')" \
  "const [summaryFile, actionsFile, mutation] = process.argv.slice(2)" \
  "const summary = JSON.parse(fs.readFileSync(summaryFile, 'utf8'))" \
  "const actions = JSON.parse(fs.readFileSync(actionsFile, 'utf8'))" \
  "const check = summary.checks.find((candidate) => candidate.slug === 'release-pr-readiness')" \
  "const passedCheck = summary.checks.find((candidate) => candidate.slug === 'plan-readiness')" \
  "const blocker = actions.blockers.find((candidate) => candidate.slug === 'release-pr-readiness')" \
  "if (!check) throw new Error('expected release-pr-readiness summary check')" \
  "if (!passedCheck) throw new Error('expected plan-readiness summary check')" \
  "if (!blocker) throw new Error('expected release-pr-readiness action blocker')" \
  "switch (mutation) {" \
  "  case 'summary-exitCode-string': check.exitCode = String(check.exitCode); break" \
  "  case 'summary-exitCode-null': check.exitCode = null; break" \
  "  case 'summary-failed-exitCode-zero': check.exitCode = 0; break" \
  "  case 'summary-passed-exitCode-positive': passedCheck.exitCode = 1; break" \
  "  case 'actions-exitCode-fraction': blocker.exitCode = blocker.exitCode + 0.5; break" \
  "  case 'actions-exitCode-negative': blocker.exitCode = -1; break" \
  "  case 'actions-exitCode-zero': blocker.exitCode = 0; break" \
  "  default: throw new Error('unknown release output exitCode value type mutation ' + mutation)" \
  "}" \
  "fs.writeFileSync(summaryFile, JSON.stringify(summary, null, 2) + '\\n')" \
  "fs.writeFileSync(actionsFile, JSON.stringify(actions, null, 2) + '\\n')"

exit_code_value_type_contract_cases=(
  "summary-exitCode-string|summary exitCode string fixture|summary exitCode for release-pr-readiness must be a non-negative integer"
  "summary-exitCode-null|summary exitCode null fixture|summary exitCode for release-pr-readiness must be a non-negative integer"
  "summary-failed-exitCode-zero|summary failed zero exitCode fixture|summary exitCode for release-pr-readiness must be positive for failed check"
  "summary-passed-exitCode-positive|summary passed nonzero exitCode fixture|summary exitCode for plan-readiness must be 0 for passed check"
  "actions-exitCode-fraction|actions exitCode fractional fixture|actions exitCode for release-pr-readiness must be a non-negative integer"
  "actions-exitCode-negative|actions exitCode negative fixture|actions exitCode for release-pr-readiness must be a non-negative integer"
  "actions-exitCode-zero|actions zero exitCode fixture|actions exitCode for release-pr-readiness must be positive for failed blocker"
)
for exit_code_value_type_case in "${exit_code_value_type_contract_cases[@]}"; do
  IFS='|' read -r exit_code_value_type_mutation exit_code_value_type_fixture_name exit_code_value_type_expected_failure <<< "$exit_code_value_type_case"
  setup_fixture
  exit_code_value_type_contract_case_script="$tmp_dir/audit-release-readiness-${exit_code_value_type_mutation}-drift.sh"
  cp "$AUDIT_SCRIPT" "$exit_code_value_type_contract_case_script"
  chmod +x "$exit_code_value_type_contract_case_script"
  perl -0pi -e "s#(write_action_manifest\\n)#\\1node \"$exit_code_value_type_contract_mutator\" \"\\\$SUMMARY_FILE\" \"\\\$ACTIONS_FILE\" \"$exit_code_value_type_mutation\"\\n#" "$exit_code_value_type_contract_case_script"
  original_audit_script="$AUDIT_SCRIPT"
  AUDIT_SCRIPT="$exit_code_value_type_contract_case_script"
  expect_failure \
    "$exit_code_value_type_fixture_name" \
    release-pr-fail \
    "$exit_code_value_type_expected_failure"
  AUDIT_SCRIPT="$original_audit_script"
done

setup_fixture
string_value_type_contract_mutator="$tmp_dir/corrupt-release-output-string-value-types.js"
write_file "$string_value_type_contract_mutator" \
  "const fs = require('node:fs')" \
  "const [summaryFile, actionsFile, mutation] = process.argv.slice(2)" \
  "const summary = JSON.parse(fs.readFileSync(summaryFile, 'utf8'))" \
  "const actions = JSON.parse(fs.readFileSync(actionsFile, 'utf8'))" \
  "const check = summary.checks.find((candidate) => candidate.slug === 'release-pr-readiness')" \
  "const blocker = actions.blockers.find((candidate) => candidate.slug === 'release-pr-readiness')" \
  "if (!check) throw new Error('expected release-pr-readiness summary check')" \
  "if (!blocker) throw new Error('expected release-pr-readiness action blocker')" \
  "switch (mutation) {" \
  "  case 'summary-name-object': check.name = { stale: 'release-readiness summary name' }; break" \
  "  case 'summary-logFile-null': check.logFile = null; break" \
  "  case 'summary-verificationCommand-array': check.verificationCommand = [check.verificationCommand]; break" \
  "  case 'actions-slug-object': blocker.slug = { stale: 'release-pr-readiness' }; break" \
  "  case 'actions-logFile-null': blocker.logFile = null; break" \
  "  case 'actions-verificationCommand-array': blocker.verificationCommand = [blocker.verificationCommand]; break" \
  "  default: throw new Error('unknown release output string value type mutation ' + mutation)" \
  "}" \
  "fs.writeFileSync(summaryFile, JSON.stringify(summary, null, 2) + '\\n')" \
  "fs.writeFileSync(actionsFile, JSON.stringify(actions, null, 2) + '\\n')"

string_value_type_contract_cases=(
  "summary-name-object|summary name object fixture|summary name for release-pr-readiness must be a string"
  "summary-logFile-null|summary logFile null fixture|summary logFile for release-pr-readiness must be a string"
  "summary-verificationCommand-array|summary verificationCommand array fixture|summary verificationCommand for release-pr-readiness must be a string"
  "actions-slug-object|actions slug object fixture|actions slug at index 0 must be a string"
  "actions-logFile-null|actions logFile null fixture|actions logFile for release-pr-readiness must be a string"
  "actions-verificationCommand-array|actions verificationCommand array fixture|actions verificationCommand for release-pr-readiness must be a string"
)
for string_value_type_case in "${string_value_type_contract_cases[@]}"; do
  IFS='|' read -r string_value_type_mutation string_value_type_fixture_name string_value_type_expected_failure <<< "$string_value_type_case"
  setup_fixture
  string_value_type_contract_case_script="$tmp_dir/audit-release-readiness-${string_value_type_mutation}-drift.sh"
  cp "$AUDIT_SCRIPT" "$string_value_type_contract_case_script"
  chmod +x "$string_value_type_contract_case_script"
  perl -0pi -e "s#(write_action_manifest\\n)#\\1node \"$string_value_type_contract_mutator\" \"\\\$SUMMARY_FILE\" \"\\\$ACTIONS_FILE\" \"$string_value_type_mutation\"\\n#" "$string_value_type_contract_case_script"
  original_audit_script="$AUDIT_SCRIPT"
  AUDIT_SCRIPT="$string_value_type_contract_case_script"
  expect_failure \
    "$string_value_type_fixture_name" \
    release-pr-fail \
    "$string_value_type_expected_failure"
  AUDIT_SCRIPT="$original_audit_script"
done

setup_fixture
boolean_value_type_contract_mutator="$tmp_dir/corrupt-release-output-boolean-value-types.js"
write_file "$boolean_value_type_contract_mutator" \
  "const fs = require('node:fs')" \
  "const [summaryFile, actionsFile, mutation] = process.argv.slice(2)" \
  "const summary = JSON.parse(fs.readFileSync(summaryFile, 'utf8'))" \
  "const actions = JSON.parse(fs.readFileSync(actionsFile, 'utf8'))" \
  "const check = summary.checks.find((candidate) => candidate.slug === 'release-pr-readiness')" \
  "const blocker = actions.blockers.find((candidate) => candidate.slug === 'release-pr-readiness')" \
  "if (!check) throw new Error('expected release-pr-readiness summary check')" \
  "if (!blocker) throw new Error('expected release-pr-readiness action blocker')" \
  "switch (mutation) {" \
  "  case 'summary-requiresExternalAction-string': check.requiresExternalAction = String(check.requiresExternalAction); break" \
  "  case 'summary-requiresExternalAction-null': check.requiresExternalAction = null; break" \
  "  case 'actions-requiresExternalAction-string': blocker.requiresExternalAction = String(blocker.requiresExternalAction); break" \
  "  case 'actions-requiresExternalAction-object': blocker.requiresExternalAction = { stale: true }; break" \
  "  default: throw new Error('unknown release output boolean value type mutation ' + mutation)" \
  "}" \
  "fs.writeFileSync(summaryFile, JSON.stringify(summary, null, 2) + '\\n')" \
  "fs.writeFileSync(actionsFile, JSON.stringify(actions, null, 2) + '\\n')"

boolean_value_type_contract_cases=(
  "summary-requiresExternalAction-string|summary requiresExternalAction string fixture|summary requiresExternalAction for release-pr-readiness must be boolean"
  "summary-requiresExternalAction-null|summary requiresExternalAction null fixture|summary requiresExternalAction for release-pr-readiness must be boolean"
  "actions-requiresExternalAction-string|actions requiresExternalAction string fixture|actions requiresExternalAction for release-pr-readiness must be boolean"
  "actions-requiresExternalAction-object|actions requiresExternalAction object fixture|actions requiresExternalAction for release-pr-readiness must be boolean"
)
for boolean_value_type_case in "${boolean_value_type_contract_cases[@]}"; do
  IFS='|' read -r boolean_value_type_mutation boolean_value_type_fixture_name boolean_value_type_expected_failure <<< "$boolean_value_type_case"
  setup_fixture
  boolean_value_type_contract_case_script="$tmp_dir/audit-release-readiness-${boolean_value_type_mutation}-drift.sh"
  cp "$AUDIT_SCRIPT" "$boolean_value_type_contract_case_script"
  chmod +x "$boolean_value_type_contract_case_script"
  perl -0pi -e "s#(write_action_manifest\\n)#\\1node \"$boolean_value_type_contract_mutator\" \"\\\$SUMMARY_FILE\" \"\\\$ACTIONS_FILE\" \"$boolean_value_type_mutation\"\\n#" "$boolean_value_type_contract_case_script"
  original_audit_script="$AUDIT_SCRIPT"
  AUDIT_SCRIPT="$boolean_value_type_contract_case_script"
  expect_failure \
    "$boolean_value_type_fixture_name" \
    release-pr-fail \
    "$boolean_value_type_expected_failure"
  AUDIT_SCRIPT="$original_audit_script"
done

setup_fixture
summary_non_failed_null_contract_mutator="$tmp_dir/corrupt-summary-non-failed-null-fields.js"
write_file "$summary_non_failed_null_contract_mutator" \
  "const fs = require('node:fs')" \
  "const [file, slug, field, mutation] = process.argv.slice(2)" \
  "const summary = JSON.parse(fs.readFileSync(file, 'utf8'))" \
  "const check = summary.checks.find((candidate) => candidate.slug === slug)" \
  "if (!check) throw new Error('expected summary check ' + slug)" \
  "switch (mutation) {" \
  "  case 'string': check[field] = 'stale non-failed summary metadata'; break" \
  "  case 'boolean': check[field] = false; break" \
  "  case 'object': check[field] = { stale: true }; break" \
  "  default: throw new Error('unknown non-failed summary null-field mutation ' + mutation)" \
  "}" \
  "fs.writeFileSync(file, JSON.stringify(summary, null, 2) + '\\n')"

summary_non_failed_null_contract_cases=(
  "release-pr-fail|plan-readiness|recommendedAction|string|summary passed recommendedAction stale fixture|summary non-failed recommendedAction for plan-readiness must be null|"
  "release-pr-fail|plan-readiness|requiresExternalAction|boolean|summary passed requiresExternalAction stale fixture|summary non-failed requiresExternalAction for plan-readiness must be null|"
  "good|github-governance|externalPrerequisite|object|summary skipped externalPrerequisite stale fixture|summary non-failed externalPrerequisite for github-governance must be null|--skip-live"
  "good|github-governance|verificationCommand|string|summary skipped verificationCommand stale fixture|summary non-failed verificationCommand for github-governance must be null|--skip-live"
)
for summary_non_failed_null_case in "${summary_non_failed_null_contract_cases[@]}"; do
  IFS='|' read -r summary_non_failed_scenario summary_non_failed_slug summary_non_failed_field summary_non_failed_mutation summary_non_failed_fixture_name summary_non_failed_expected_failure summary_non_failed_extra_arg <<< "$summary_non_failed_null_case"
  setup_fixture
  summary_non_failed_null_script="$tmp_dir/audit-release-readiness-summary-non-failed-${summary_non_failed_slug}-${summary_non_failed_field}-drift.sh"
  cp "$AUDIT_SCRIPT" "$summary_non_failed_null_script"
  chmod +x "$summary_non_failed_null_script"
  perl -0pi -e "s#(log \"Wrote machine-readable summary to \\\$SUMMARY_FILE\"\\n)#node \"$summary_non_failed_null_contract_mutator\" \"\\\$SUMMARY_FILE\" \"$summary_non_failed_slug\" \"$summary_non_failed_field\" \"$summary_non_failed_mutation\"\n\\1#" "$summary_non_failed_null_script"
  original_audit_script="$AUDIT_SCRIPT"
  AUDIT_SCRIPT="$summary_non_failed_null_script"
  if [[ -n "$summary_non_failed_extra_arg" ]]; then
    expect_failure \
      "$summary_non_failed_fixture_name" \
      "$summary_non_failed_scenario" \
      "$summary_non_failed_expected_failure" \
      "$summary_non_failed_extra_arg"
  else
    expect_failure \
      "$summary_non_failed_fixture_name" \
      "$summary_non_failed_scenario" \
      "$summary_non_failed_expected_failure"
  fi
  AUDIT_SCRIPT="$original_audit_script"
done

setup_fixture
item_object_type_contract_mutator="$tmp_dir/corrupt-release-output-item-object-types.js"
write_file "$item_object_type_contract_mutator" \
  "const fs = require('node:fs')" \
  "const [summaryFile, actionsFile, mutation] = process.argv.slice(2)" \
  "const summary = JSON.parse(fs.readFileSync(summaryFile, 'utf8'))" \
  "const actions = JSON.parse(fs.readFileSync(actionsFile, 'utf8'))" \
  "switch (mutation) {" \
  "  case 'summary-check-array': summary.checks[0] = [summary.checks[0]]; break" \
  "  case 'summary-check-null': summary.checks[0] = null; break" \
  "  case 'actions-blocker-array': actions.blockers[0] = [actions.blockers[0]]; break" \
  "  case 'actions-blocker-string': actions.blockers[0] = 'stale release-readiness blocker'; break" \
  "  default: throw new Error('unknown release output item object type mutation ' + mutation)" \
  "}" \
  "fs.writeFileSync(summaryFile, JSON.stringify(summary, null, 2) + '\\n')" \
  "fs.writeFileSync(actionsFile, JSON.stringify(actions, null, 2) + '\\n')"

item_object_type_contract_cases=(
  "summary-check-array|summary check non-object array fixture|summary.json check keys for plan-readiness must be an object"
  "summary-check-null|summary check non-object null fixture|summary.json check keys for plan-readiness must be an object"
  "actions-blocker-array|actions blocker non-object array fixture|actions blocker keys for release-pr-readiness must be an object"
  "actions-blocker-string|actions blocker non-object string fixture|actions blocker keys for release-pr-readiness must be an object"
)
for item_object_type_case in "${item_object_type_contract_cases[@]}"; do
  IFS='|' read -r item_object_type_mutation item_object_type_fixture_name item_object_type_expected_failure <<< "$item_object_type_case"
  setup_fixture
  item_object_type_contract_case_script="$tmp_dir/audit-release-readiness-${item_object_type_mutation}-drift.sh"
  cp "$AUDIT_SCRIPT" "$item_object_type_contract_case_script"
  chmod +x "$item_object_type_contract_case_script"
  perl -0pi -e "s#(write_action_manifest\\n)#\\1node \"$item_object_type_contract_mutator\" \"\\\$SUMMARY_FILE\" \"\\\$ACTIONS_FILE\" \"$item_object_type_mutation\"\\n#" "$item_object_type_contract_case_script"
  original_audit_script="$AUDIT_SCRIPT"
  AUDIT_SCRIPT="$item_object_type_contract_case_script"
  expect_failure \
    "$item_object_type_fixture_name" \
    release-pr-fail \
    "$item_object_type_expected_failure"
  AUDIT_SCRIPT="$original_audit_script"
done

setup_fixture
totals_count_contract_mutator="$tmp_dir/corrupt-totals-count-release-output.js"
write_file "$totals_count_contract_mutator" \
  "const fs = require('node:fs')" \
  "const [summaryFile, actionsFile, mutation] = process.argv.slice(2)" \
  "const summary = JSON.parse(fs.readFileSync(summaryFile, 'utf8'))" \
  "const actions = JSON.parse(fs.readFileSync(actionsFile, 'utf8'))" \
  "switch (mutation) {" \
  "  case 'summary-passed-total': summary.totals.passed += 1; break" \
  "  case 'summary-failed-total': summary.totals.failed += 1; break" \
  "  case 'summary-skipped-total': summary.totals.skipped += 1; break" \
  "  case 'summary-total': summary.totals.total += 1; break" \
  "  case 'actions-passed-total': actions.totals.passed += 1; break" \
  "  case 'actions-failed-total': actions.totals.failed += 1; break" \
  "  case 'actions-skipped-total': actions.totals.skipped += 1; break" \
  "  case 'actions-total': actions.totals.total += 1; break" \
  "  case 'summary-check-count': summary.checks.pop(); break" \
  "  case 'actions-blocker-count': actions.blockers.pop(); break" \
  "  default: throw new Error('unknown totals/count release output mutation ' + mutation)" \
  "}" \
  "fs.writeFileSync(summaryFile, JSON.stringify(summary, null, 2) + '\\n')" \
  "fs.writeFileSync(actionsFile, JSON.stringify(actions, null, 2) + '\\n')"

totals_count_contract_cases=(
  "summary-passed-total|summary passed total drift fixture|summary.json passed total mismatch"
  "summary-failed-total|summary failed total drift fixture|summary.json failed total mismatch"
  "summary-skipped-total|summary skipped total drift fixture|summary.json skipped total mismatch"
  "summary-total|summary total drift fixture|summary.json total mismatch"
  "actions-passed-total|actions passed total drift fixture|actions.json passed total mismatch"
  "actions-failed-total|actions failed total drift fixture|actions.json failed total mismatch"
  "actions-skipped-total|actions skipped total drift fixture|actions.json skipped total mismatch"
  "actions-total|actions total drift fixture|actions.json total mismatch"
  "summary-check-count|summary check count drift fixture|summary.json check count mismatch"
  "actions-blocker-count|actions blocker count drift fixture|actions.json blocker count mismatch"
)
for totals_count_case in "${totals_count_contract_cases[@]}"; do
  IFS='|' read -r totals_count_mutation totals_count_fixture_name totals_count_expected_failure <<< "$totals_count_case"
  setup_fixture
  totals_count_contract_case_script="$tmp_dir/audit-release-readiness-${totals_count_mutation}-drift.sh"
  cp "$AUDIT_SCRIPT" "$totals_count_contract_case_script"
  chmod +x "$totals_count_contract_case_script"
  perl -0pi -e "s#(write_action_manifest\\n)#\\1node \"$totals_count_contract_mutator\" \"\\\$SUMMARY_FILE\" \"\\\$ACTIONS_FILE\" \"$totals_count_mutation\"\\n#" "$totals_count_contract_case_script"
  original_audit_script="$AUDIT_SCRIPT"
  AUDIT_SCRIPT="$totals_count_contract_case_script"
  expect_failure \
    "$totals_count_fixture_name" \
    release-pr-fail \
    "$totals_count_expected_failure"
  AUDIT_SCRIPT="$original_audit_script"
done

setup_fixture
summary_contract_script="$tmp_dir/audit-release-readiness-summary-contract-drift.sh"
cp "$AUDIT_SCRIPT" "$summary_contract_script"
chmod +x "$summary_contract_script"
perl -0pi -e "s/printf '%s' \"\\\$requires_external_action\"/printf 'false'/" "$summary_contract_script"
original_audit_script="$AUDIT_SCRIPT"
AUDIT_SCRIPT="$summary_contract_script"
expect_failure \
  "summary output contract drift fixture" \
  release-pr-fail \
  "summary requiresExternalAction mismatch for release-pr-readiness"
AUDIT_SCRIPT="$original_audit_script"

setup_fixture
summary_identity_mutator="$tmp_dir/corrupt-summary-check-identity.js"
write_file "$summary_identity_mutator" \
  "const fs = require('node:fs')" \
  "const [file, mutation] = process.argv.slice(2)" \
  "const data = JSON.parse(fs.readFileSync(file, 'utf8'))" \
  "const check = data.checks.find((candidate) => candidate.slug === 'release-pr-readiness')" \
  "if (!check) throw new Error('expected release-pr-readiness summary check')" \
  "switch (mutation) {" \
  "  case 'name': check.name = 'Release PR readiness stale label'; break" \
  "  case 'slug': check.slug = 'release-pr-readiness-stale'; break" \
  "  case 'status-invalid': check.status = 'deferred'; break" \
  "  case 'status': check.status = 'passed'; break" \
  "  default: throw new Error('unknown summary identity mutation ' + mutation)" \
  "}" \
  "fs.writeFileSync(file, JSON.stringify(data, null, 2) + '\\n')"

summary_identity_cases=(
  "name|summary name drift fixture|summary name mismatch for release-pr-readiness"
  "slug|summary slug drift fixture|summary slug mismatch at index"
  "status-invalid|summary check invalid status fixture|summary status for release-pr-readiness must be passed, failed, or skipped"
  "status|summary check status drift fixture|summary status mismatch for release-pr-readiness"
)
for summary_case in "${summary_identity_cases[@]}"; do
  IFS='|' read -r summary_mutation summary_fixture_name summary_expected_failure <<< "$summary_case"
  setup_fixture
  summary_identity_script="$tmp_dir/audit-release-readiness-summary-${summary_mutation}-drift.sh"
  cp "$AUDIT_SCRIPT" "$summary_identity_script"
  chmod +x "$summary_identity_script"
  perl -0pi -e "s#(log \"Wrote machine-readable summary to \\\$SUMMARY_FILE\"\\n)#node \"$summary_identity_mutator\" \"\\\$SUMMARY_FILE\" \"$summary_mutation\"\n\\1#" "$summary_identity_script"
  original_audit_script="$AUDIT_SCRIPT"
  AUDIT_SCRIPT="$summary_identity_script"
  expect_failure \
    "$summary_fixture_name" \
    release-pr-fail \
    "$summary_expected_failure"
  AUDIT_SCRIPT="$original_audit_script"
done

setup_fixture
summary_result_mutator="$tmp_dir/corrupt-summary-check-result.js"
write_file "$summary_result_mutator" \
  "const fs = require('node:fs')" \
  "const [file, mutation] = process.argv.slice(2)" \
  "const data = JSON.parse(fs.readFileSync(file, 'utf8'))" \
  "const check = data.checks.find((candidate) => candidate.slug === 'release-pr-readiness')" \
  "if (!check) throw new Error('expected release-pr-readiness summary check')" \
  "switch (mutation) {" \
  "  case 'exitCode': check.exitCode = check.exitCode + 1; break" \
  "  case 'logFile': check.logFile = 'stale-release-pr-readiness.log'; break" \
  "  default: throw new Error('unknown summary result mutation ' + mutation)" \
  "}" \
  "fs.writeFileSync(file, JSON.stringify(data, null, 2) + '\\n')"

summary_result_cases=(
  "exitCode|summary exitCode drift fixture|summary exitCode mismatch for release-pr-readiness"
  "logFile|summary logFile drift fixture|summary logFile mismatch for release-pr-readiness"
)
for summary_case in "${summary_result_cases[@]}"; do
  IFS='|' read -r summary_mutation summary_fixture_name summary_expected_failure <<< "$summary_case"
  setup_fixture
  summary_result_script="$tmp_dir/audit-release-readiness-summary-${summary_mutation}-drift.sh"
  cp "$AUDIT_SCRIPT" "$summary_result_script"
  chmod +x "$summary_result_script"
  perl -0pi -e "s#(log \"Wrote machine-readable summary to \\\$SUMMARY_FILE\"\\n)#node \"$summary_result_mutator\" \"\\\$SUMMARY_FILE\" \"$summary_mutation\"\n\\1#" "$summary_result_script"
  original_audit_script="$AUDIT_SCRIPT"
  AUDIT_SCRIPT="$summary_result_script"
  expect_failure \
    "$summary_fixture_name" \
    release-pr-fail \
    "$summary_expected_failure"
  AUDIT_SCRIPT="$original_audit_script"
done

setup_fixture
summary_metadata_mutator="$tmp_dir/corrupt-summary-metadata-field.js"
write_file "$summary_metadata_mutator" \
  "const fs = require('node:fs')" \
  "const [file, field] = process.argv.slice(2)" \
  "const data = JSON.parse(fs.readFileSync(file, 'utf8'))" \
  "const check = data.checks.find((candidate) => candidate.slug === 'release-pr-readiness')" \
  "if (!check) throw new Error('expected release-pr-readiness summary check')" \
  "check[field] = 'stale summary metadata for ' + field" \
  "fs.writeFileSync(file, JSON.stringify(data, null, 2) + '\\n')"

summary_metadata_cases=(
  "recommendedAction|summary recommendedAction drift fixture|summary recommendedAction mismatch for release-pr-readiness"
  "unblockCategory|summary unblockCategory drift fixture|summary unblockCategory mismatch for release-pr-readiness"
  "externalPrerequisite|summary externalPrerequisite drift fixture|summary externalPrerequisite mismatch for release-pr-readiness"
  "verificationCommand|summary verificationCommand drift fixture|summary verificationCommand mismatch for release-pr-readiness"
)
for summary_case in "${summary_metadata_cases[@]}"; do
  IFS='|' read -r summary_field summary_fixture_name summary_expected_failure <<< "$summary_case"
  setup_fixture
  summary_metadata_script="$tmp_dir/audit-release-readiness-summary-${summary_field}-drift.sh"
  cp "$AUDIT_SCRIPT" "$summary_metadata_script"
  chmod +x "$summary_metadata_script"
  perl -0pi -e "s#(log \"Wrote machine-readable summary to \\\$SUMMARY_FILE\"\\n)#node \"$summary_metadata_mutator\" \"\\\$SUMMARY_FILE\" \"$summary_field\"\n\\1#" "$summary_metadata_script"
  original_audit_script="$AUDIT_SCRIPT"
  AUDIT_SCRIPT="$summary_metadata_script"
  expect_failure \
    "$summary_fixture_name" \
    release-pr-fail \
    "$summary_expected_failure"
  AUDIT_SCRIPT="$original_audit_script"
done

setup_fixture
summary_extra_key_script="$tmp_dir/audit-release-readiness-summary-extra-key.sh"
summary_extra_key_mutator="$tmp_dir/add-summary-check-extra-key.js"
write_file "$summary_extra_key_mutator" \
  "const fs = require('node:fs')" \
  "const file = process.argv[2]" \
  "const data = JSON.parse(fs.readFileSync(file, 'utf8'))" \
  "data.checks[0].unexpectedField = 'unexpected release-readiness summary field'" \
  "fs.writeFileSync(file, JSON.stringify(data, null, 2) + '\\n')"
cp "$AUDIT_SCRIPT" "$summary_extra_key_script"
chmod +x "$summary_extra_key_script"
perl -0pi -e "s#(log \"Wrote machine-readable summary to \\\$SUMMARY_FILE\"\\n)#node \"$summary_extra_key_mutator\" \"\\\$SUMMARY_FILE\"\\n\\1#" "$summary_extra_key_script"
original_audit_script="$AUDIT_SCRIPT"
AUDIT_SCRIPT="$summary_extra_key_script"
expect_failure \
  "summary unexpected field fixture" \
  good \
  "summary.json check keys for plan-readiness keys mismatch"
AUDIT_SCRIPT="$original_audit_script"

setup_fixture
actions_contract_script="$tmp_dir/audit-release-readiness-actions-contract-drift.sh"
cp "$AUDIT_SCRIPT" "$actions_contract_script"
chmod +x "$actions_contract_script"
perl -0pi -e "s/printf '      \"requiresExternalAction\": %s,\\\\n' \"\\\$requires_external_action\"/printf '      \"requiresExternalAction\": false,\\\\n'/" "$actions_contract_script"
original_audit_script="$AUDIT_SCRIPT"
AUDIT_SCRIPT="$actions_contract_script"
expect_failure \
  "actions output contract drift fixture" \
  release-pr-fail \
  "actions requiresExternalAction mismatch for release-pr-readiness"
AUDIT_SCRIPT="$original_audit_script"

setup_fixture
actions_result_mutator="$tmp_dir/corrupt-actions-blocker-result.js"
write_file "$actions_result_mutator" \
  "const fs = require('node:fs')" \
  "const [file, mutation] = process.argv.slice(2)" \
  "const data = JSON.parse(fs.readFileSync(file, 'utf8'))" \
  "const blocker = data.blockers.find((candidate) => candidate.slug === 'release-pr-readiness')" \
  "if (!blocker) throw new Error('expected release-pr-readiness action blocker')" \
  "switch (mutation) {" \
  "  case 'name': blocker.name = 'Release PR readiness stale action label'; break" \
  "  case 'exitCode': blocker.exitCode = blocker.exitCode + 1; break" \
  "  case 'logFile': blocker.logFile = 'stale-release-pr-readiness.log'; break" \
  "  default: throw new Error('unknown actions result mutation ' + mutation)" \
  "}" \
  "fs.writeFileSync(file, JSON.stringify(data, null, 2) + '\\n')"

actions_result_cases=(
  "name|actions name drift fixture|actions name mismatch for release-pr-readiness"
  "exitCode|actions exitCode drift fixture|actions exitCode mismatch for release-pr-readiness"
  "logFile|actions logFile drift fixture|actions logFile mismatch for release-pr-readiness"
)
for actions_case in "${actions_result_cases[@]}"; do
  IFS='|' read -r actions_mutation actions_fixture_name actions_expected_failure <<< "$actions_case"
  setup_fixture
  actions_result_script="$tmp_dir/audit-release-readiness-actions-${actions_mutation}-drift.sh"
  cp "$AUDIT_SCRIPT" "$actions_result_script"
  chmod +x "$actions_result_script"
  perl -0pi -e "s#(log \"Wrote machine-readable blocker actions to \\\$ACTIONS_FILE\"\\n)#node \"$actions_result_mutator\" \"\\\$ACTIONS_FILE\" \"$actions_mutation\"\n\\1#" "$actions_result_script"
  original_audit_script="$AUDIT_SCRIPT"
  AUDIT_SCRIPT="$actions_result_script"
  expect_failure \
    "$actions_fixture_name" \
    release-pr-fail \
    "$actions_expected_failure"
  AUDIT_SCRIPT="$original_audit_script"
done

setup_fixture
actions_metadata_mutator="$tmp_dir/corrupt-actions-metadata-field.js"
write_file "$actions_metadata_mutator" \
  "const fs = require('node:fs')" \
  "const [file, field] = process.argv.slice(2)" \
  "const data = JSON.parse(fs.readFileSync(file, 'utf8'))" \
  "const blocker = data.blockers.find((candidate) => candidate.slug === 'release-pr-readiness')" \
  "if (!blocker) throw new Error('expected release-pr-readiness action blocker')" \
  "blocker[field] = 'stale action metadata for ' + field" \
  "fs.writeFileSync(file, JSON.stringify(data, null, 2) + '\\n')"

actions_metadata_cases=(
  "recommendedAction|actions recommendedAction drift fixture|actions recommendedAction mismatch for release-pr-readiness"
  "unblockCategory|actions unblockCategory drift fixture|actions unblockCategory mismatch for release-pr-readiness"
  "externalPrerequisite|actions externalPrerequisite drift fixture|actions externalPrerequisite mismatch for release-pr-readiness"
  "verificationCommand|actions verificationCommand drift fixture|actions verificationCommand mismatch for release-pr-readiness"
)
for actions_case in "${actions_metadata_cases[@]}"; do
  IFS='|' read -r actions_field actions_fixture_name actions_expected_failure <<< "$actions_case"
  setup_fixture
  actions_metadata_script="$tmp_dir/audit-release-readiness-actions-${actions_field}-drift.sh"
  cp "$AUDIT_SCRIPT" "$actions_metadata_script"
  chmod +x "$actions_metadata_script"
  perl -0pi -e "s#(log \"Wrote machine-readable blocker actions to \\\$ACTIONS_FILE\"\\n)#node \"$actions_metadata_mutator\" \"\\\$ACTIONS_FILE\" \"$actions_field\"\n\\1#" "$actions_metadata_script"
  original_audit_script="$AUDIT_SCRIPT"
  AUDIT_SCRIPT="$actions_metadata_script"
  expect_failure \
    "$actions_fixture_name" \
    release-pr-fail \
    "$actions_expected_failure"
  AUDIT_SCRIPT="$original_audit_script"
done

setup_fixture
actions_extra_key_script="$tmp_dir/audit-release-readiness-actions-extra-key.sh"
actions_extra_key_mutator="$tmp_dir/add-actions-blocker-extra-key.js"
write_file "$actions_extra_key_mutator" \
  "const fs = require('node:fs')" \
  "const file = process.argv[2]" \
  "const data = JSON.parse(fs.readFileSync(file, 'utf8'))" \
  "data.blockers[0].unexpectedField = 'unexpected release-readiness action field'" \
  "fs.writeFileSync(file, JSON.stringify(data, null, 2) + '\\n')"
cp "$AUDIT_SCRIPT" "$actions_extra_key_script"
chmod +x "$actions_extra_key_script"
perl -0pi -e "s#(log \"Wrote machine-readable blocker actions to \\\$ACTIONS_FILE\"\\n)#node \"$actions_extra_key_mutator\" \"\\\$ACTIONS_FILE\"\\n\\1#" "$actions_extra_key_script"
original_audit_script="$AUDIT_SCRIPT"
AUDIT_SCRIPT="$actions_extra_key_script"
expect_failure \
  "actions unexpected field fixture" \
  release-pr-fail \
  "actions blocker keys for release-pr-readiness keys mismatch"
AUDIT_SCRIPT="$original_audit_script"

setup_fixture
blockers_contract_script="$tmp_dir/audit-release-readiness-blockers-contract-drift.sh"
cp "$AUDIT_SCRIPT" "$blockers_contract_script"
chmod +x "$blockers_contract_script"
perl -0pi -e 's/Requires external action:/External action removed:/' "$blockers_contract_script"
original_audit_script="$AUDIT_SCRIPT"
AUDIT_SCRIPT="$blockers_contract_script"
expect_failure \
  "blocker report output contract drift fixture" \
  release-pr-fail \
  "blockers.md requiresExternalAction mismatch for release-pr-readiness"
AUDIT_SCRIPT="$original_audit_script"

duplicate_blocker_report_line_mutator="$tmp_dir/duplicate-blocker-report-line.js"
write_file "$duplicate_blocker_report_line_mutator" \
  "const fs = require('node:fs')" \
  "const [file, prefix] = process.argv.slice(2)" \
  "const text = fs.readFileSync(file, 'utf8')" \
  "const line = text.split('\\n').find((candidate) => candidate.startsWith(prefix))" \
  "if (!line) throw new Error('expected blocker report line with prefix ' + prefix)" \
  "fs.writeFileSync(file, text.replace(line + '\\n', line + '\\n' + line + '\\n'))"

setup_fixture
blockers_missing_slug_script="$tmp_dir/audit-release-readiness-blockers-missing-slug.sh"
blockers_missing_slug_mutator="$tmp_dir/remove-blocker-report-slug-line.js"
write_file "$blockers_missing_slug_mutator" \
  "const fs = require('node:fs')" \
  "const file = process.argv[2]" \
  "const text = fs.readFileSync(file, 'utf8')" \
  "const line = '- Slug: \`release-pr-readiness\`\\n'" \
  "if (!text.includes(line)) throw new Error('expected release-pr-readiness slug line')" \
  "fs.writeFileSync(file, text.replace(line, ''))"
cp "$AUDIT_SCRIPT" "$blockers_missing_slug_script"
chmod +x "$blockers_missing_slug_script"
perl -0pi -e "s#(log \"Wrote release blocker report to \\\$BLOCKERS_FILE\"\\n)#node \"$blockers_missing_slug_mutator\" \"\\\$BLOCKERS_FILE\"\n\\1#" "$blockers_missing_slug_script"
original_audit_script="$AUDIT_SCRIPT"
AUDIT_SCRIPT="$blockers_missing_slug_script"
expect_failure \
  "blocker report missing slug-line fixture" \
  release-pr-fail \
  "blockers.md missing slug line for release-pr-readiness"
AUDIT_SCRIPT="$original_audit_script"

setup_fixture
blockers_duplicate_slug_script="$tmp_dir/audit-release-readiness-blockers-duplicate-slug.sh"
cp "$AUDIT_SCRIPT" "$blockers_duplicate_slug_script"
chmod +x "$blockers_duplicate_slug_script"
perl -0pi -e "s#(log \"Wrote release blocker report to \\\$BLOCKERS_FILE\"\\n)#node \"$duplicate_blocker_report_line_mutator\" \"\\\$BLOCKERS_FILE\" \"- Slug:\"\n\\1#" "$blockers_duplicate_slug_script"
original_audit_script="$AUDIT_SCRIPT"
AUDIT_SCRIPT="$blockers_duplicate_slug_script"
expect_failure \
  "blocker report duplicate slug-line fixture" \
  release-pr-fail \
  "blockers.md duplicate slug line for release-pr-readiness"
AUDIT_SCRIPT="$original_audit_script"

setup_fixture
blockers_failed_heading_drift_script="$tmp_dir/audit-release-readiness-blockers-failed-heading-drift.sh"
blockers_failed_heading_drift_mutator="$tmp_dir/corrupt-blocker-report-failed-heading.js"
write_file "$blockers_failed_heading_drift_mutator" \
  "const fs = require('node:fs')" \
  "const file = process.argv[2]" \
  "const text = fs.readFileSync(file, 'utf8')" \
  "const line = text.split('\\n').find((candidate) => candidate.startsWith('### '))" \
  "if (!line) throw new Error('expected failed-check heading line')" \
  "fs.writeFileSync(file, text.replace(line + '\\n', '### Stale Release Readiness\\n'))"
cp "$AUDIT_SCRIPT" "$blockers_failed_heading_drift_script"
chmod +x "$blockers_failed_heading_drift_script"
perl -0pi -e "s#(log \"Wrote release blocker report to \\\$BLOCKERS_FILE\"\\n)#node \"$blockers_failed_heading_drift_mutator\" \"\\\$BLOCKERS_FILE\"\n\\1#" "$blockers_failed_heading_drift_script"
original_audit_script="$AUDIT_SCRIPT"
AUDIT_SCRIPT="$blockers_failed_heading_drift_script"
expect_failure \
  "blocker report failed-heading drift fixture" \
  release-pr-fail \
  "blockers.md failed heading order mismatch at index 0"
AUDIT_SCRIPT="$original_audit_script"

setup_fixture
blockers_duplicate_failed_heading_script="$tmp_dir/audit-release-readiness-blockers-duplicate-failed-heading.sh"
cp "$AUDIT_SCRIPT" "$blockers_duplicate_failed_heading_script"
chmod +x "$blockers_duplicate_failed_heading_script"
perl -0pi -e "s@(log \"Wrote release blocker report to \\\$BLOCKERS_FILE\"\\n)@node \"$duplicate_blocker_report_line_mutator\" \"\\\$BLOCKERS_FILE\" \"### \"\n\\1@" "$blockers_duplicate_failed_heading_script"
original_audit_script="$AUDIT_SCRIPT"
AUDIT_SCRIPT="$blockers_duplicate_failed_heading_script"
expect_failure \
  "blocker report duplicate failed-heading fixture" \
  release-pr-fail \
  "blockers.md failed heading count mismatch"
AUDIT_SCRIPT="$original_audit_script"

setup_fixture
blockers_duplicate_exit_code_script="$tmp_dir/audit-release-readiness-blockers-duplicate-exit-code.sh"
cp "$AUDIT_SCRIPT" "$blockers_duplicate_exit_code_script"
chmod +x "$blockers_duplicate_exit_code_script"
perl -0pi -e "s#(log \"Wrote release blocker report to \\\$BLOCKERS_FILE\"\\n)#node \"$duplicate_blocker_report_line_mutator\" \"\\\$BLOCKERS_FILE\" \"- Exit code:\"\n\\1#" "$blockers_duplicate_exit_code_script"
original_audit_script="$AUDIT_SCRIPT"
AUDIT_SCRIPT="$blockers_duplicate_exit_code_script"
expect_failure \
  "blocker report duplicate exit-code fixture" \
  release-pr-fail \
  "blockers.md exit code mismatch for release-pr-readiness"
AUDIT_SCRIPT="$original_audit_script"

setup_fixture
blockers_duplicate_log_script="$tmp_dir/audit-release-readiness-blockers-duplicate-log.sh"
cp "$AUDIT_SCRIPT" "$blockers_duplicate_log_script"
chmod +x "$blockers_duplicate_log_script"
perl -0pi -e "s#(log \"Wrote release blocker report to \\\$BLOCKERS_FILE\"\\n)#node \"$duplicate_blocker_report_line_mutator\" \"\\\$BLOCKERS_FILE\" \"- Log:\"\n\\1#" "$blockers_duplicate_log_script"
original_audit_script="$AUDIT_SCRIPT"
AUDIT_SCRIPT="$blockers_duplicate_log_script"
expect_failure \
  "blocker report duplicate log fixture" \
  release-pr-fail \
  "blockers.md log path mismatch for release-pr-readiness"
AUDIT_SCRIPT="$original_audit_script"

setup_fixture
blockers_duplicate_recommended_action_script="$tmp_dir/audit-release-readiness-blockers-duplicate-recommended-action.sh"
cp "$AUDIT_SCRIPT" "$blockers_duplicate_recommended_action_script"
chmod +x "$blockers_duplicate_recommended_action_script"
perl -0pi -e "s#(log \"Wrote release blocker report to \\\$BLOCKERS_FILE\"\\n)#node \"$duplicate_blocker_report_line_mutator\" \"\\\$BLOCKERS_FILE\" \"- Recommended action:\"\n\\1#" "$blockers_duplicate_recommended_action_script"
original_audit_script="$AUDIT_SCRIPT"
AUDIT_SCRIPT="$blockers_duplicate_recommended_action_script"
expect_failure \
  "blocker report duplicate recommended-action fixture" \
  release-pr-fail \
  "blockers.md recommended action mismatch for release-pr-readiness"
AUDIT_SCRIPT="$original_audit_script"

setup_fixture
blockers_duplicate_external_prerequisite_script="$tmp_dir/audit-release-readiness-blockers-duplicate-external-prerequisite.sh"
cp "$AUDIT_SCRIPT" "$blockers_duplicate_external_prerequisite_script"
chmod +x "$blockers_duplicate_external_prerequisite_script"
perl -0pi -e "s#(log \"Wrote release blocker report to \\\$BLOCKERS_FILE\"\\n)#node \"$duplicate_blocker_report_line_mutator\" \"\\\$BLOCKERS_FILE\" \"- External prerequisite:\"\n\\1#" "$blockers_duplicate_external_prerequisite_script"
original_audit_script="$AUDIT_SCRIPT"
AUDIT_SCRIPT="$blockers_duplicate_external_prerequisite_script"
expect_failure \
  "blocker report duplicate external-prerequisite fixture" \
  release-pr-fail \
  "blockers.md externalPrerequisite mismatch for release-pr-readiness"
AUDIT_SCRIPT="$original_audit_script"

setup_fixture
blockers_duplicate_requires_external_action_script="$tmp_dir/audit-release-readiness-blockers-duplicate-requires-external-action.sh"
cp "$AUDIT_SCRIPT" "$blockers_duplicate_requires_external_action_script"
chmod +x "$blockers_duplicate_requires_external_action_script"
perl -0pi -e "s#(log \"Wrote release blocker report to \\\$BLOCKERS_FILE\"\\n)#node \"$duplicate_blocker_report_line_mutator\" \"\\\$BLOCKERS_FILE\" \"- Requires external action:\"\n\\1#" "$blockers_duplicate_requires_external_action_script"
original_audit_script="$AUDIT_SCRIPT"
AUDIT_SCRIPT="$blockers_duplicate_requires_external_action_script"
expect_failure \
  "blocker report duplicate requires-external-action fixture" \
  release-pr-fail \
  "blockers.md requiresExternalAction mismatch for release-pr-readiness"
AUDIT_SCRIPT="$original_audit_script"

setup_fixture
blockers_duplicate_unblock_category_script="$tmp_dir/audit-release-readiness-blockers-duplicate-unblock-category.sh"
cp "$AUDIT_SCRIPT" "$blockers_duplicate_unblock_category_script"
chmod +x "$blockers_duplicate_unblock_category_script"
perl -0pi -e "s#(log \"Wrote release blocker report to \\\$BLOCKERS_FILE\"\\n)#node \"$duplicate_blocker_report_line_mutator\" \"\\\$BLOCKERS_FILE\" \"- Unblock category:\"\n\\1#" "$blockers_duplicate_unblock_category_script"
original_audit_script="$AUDIT_SCRIPT"
AUDIT_SCRIPT="$blockers_duplicate_unblock_category_script"
expect_failure \
  "blocker report duplicate unblock-category fixture" \
  release-pr-fail \
  "blockers.md unblockCategory mismatch for release-pr-readiness"
AUDIT_SCRIPT="$original_audit_script"

setup_fixture
blockers_duplicate_verification_command_script="$tmp_dir/audit-release-readiness-blockers-duplicate-verification-command.sh"
cp "$AUDIT_SCRIPT" "$blockers_duplicate_verification_command_script"
chmod +x "$blockers_duplicate_verification_command_script"
perl -0pi -e "s#(log \"Wrote release blocker report to \\\$BLOCKERS_FILE\"\\n)#node \"$duplicate_blocker_report_line_mutator\" \"\\\$BLOCKERS_FILE\" \"- Verification command:\"\n\\1#" "$blockers_duplicate_verification_command_script"
original_audit_script="$AUDIT_SCRIPT"
AUDIT_SCRIPT="$blockers_duplicate_verification_command_script"
expect_failure \
  "blocker report duplicate verification-command fixture" \
  release-pr-fail \
  "blockers.md verificationCommand mismatch for release-pr-readiness"
AUDIT_SCRIPT="$original_audit_script"

setup_fixture
blockers_extra_failed_line_script="$tmp_dir/audit-release-readiness-blockers-extra-failed-line.sh"
blockers_extra_failed_line_mutator="$tmp_dir/append-blocker-report-extra-failed-line.js"
write_file "$blockers_extra_failed_line_mutator" \
  "const fs = require('node:fs')" \
  "const file = process.argv[2]" \
  "const text = fs.readFileSync(file, 'utf8')" \
  "const slugLine = '- Slug: \`release-pr-readiness\`\\n'" \
  "const slugIndex = text.indexOf(slugLine)" \
  "if (slugIndex === -1) throw new Error('expected release-pr-readiness slug line')" \
  "const sectionEndCandidates = ['\\n### ', '\\n## ']" \
  "  .map((marker) => text.indexOf(marker, slugIndex + slugLine.length))" \
  "  .filter((index) => index !== -1)" \
  "const sectionEnd = sectionEndCandidates.length > 0 ? Math.min(...sectionEndCandidates) : text.length" \
  "const section = text.slice(slugIndex, sectionEnd)" \
  "const verificationLine = section.split('\\n').find((line) => line.startsWith('- Verification command: '))" \
  "if (!verificationLine) throw new Error('expected release-pr-readiness verification command')" \
  "const marker = verificationLine + '\\n'" \
  "const insertIndex = text.indexOf(marker, slugIndex)" \
  "if (insertIndex === -1 || insertIndex >= sectionEnd) throw new Error('expected verification command inside release-pr-readiness section')" \
  "const insertAfter = insertIndex + marker.length" \
  "fs.writeFileSync(file, text.slice(0, insertAfter) + '- Unsupported note: stale operator-only blocker context\\n' + text.slice(insertAfter))"
cp "$AUDIT_SCRIPT" "$blockers_extra_failed_line_script"
chmod +x "$blockers_extra_failed_line_script"
perl -0pi -e "s#(log \"Wrote release blocker report to \\\$BLOCKERS_FILE\"\\n)#node \"$blockers_extra_failed_line_mutator\" \"\\\$BLOCKERS_FILE\"\\n\\1#" "$blockers_extra_failed_line_script"
original_audit_script="$AUDIT_SCRIPT"
AUDIT_SCRIPT="$blockers_extra_failed_line_script"
expect_failure \
  "blocker report extra failed-section line fixture" \
  release-pr-fail \
  "blockers.md section content mismatch for release-pr-readiness"
AUDIT_SCRIPT="$original_audit_script"

setup_fixture
actions_preview_script="$tmp_dir/audit-release-readiness-actions-preview-drift.sh"
actions_preview_mutator="$tmp_dir/corrupt-actions-evidence-preview.js"
write_file "$actions_preview_mutator" \
  "const fs = require('node:fs')" \
  "const file = process.argv[2]" \
  "const data = JSON.parse(fs.readFileSync(file, 'utf8'))" \
  "data.blockers[0].evidencePreview = 'stale release-readiness evidence preview not backed by the current log'" \
  "fs.writeFileSync(file, JSON.stringify(data, null, 2) + '\\n')"
cp "$AUDIT_SCRIPT" "$actions_preview_script"
chmod +x "$actions_preview_script"
perl -0pi -e "s#(log \"Wrote machine-readable blocker actions to \\\$ACTIONS_FILE\"\\n)#node \"$actions_preview_mutator\" \"\\\$ACTIONS_FILE\"\\n\\1#" "$actions_preview_script"
original_audit_script="$AUDIT_SCRIPT"
AUDIT_SCRIPT="$actions_preview_script"
expect_failure \
  "actions evidence-preview drift fixture" \
  release-pr-fail \
  "actions evidencePreview mismatch for release-pr-readiness"
AUDIT_SCRIPT="$original_audit_script"

setup_fixture
actions_preview_type_mutator="$tmp_dir/corrupt-actions-evidence-preview-type.js"
write_file "$actions_preview_type_mutator" \
  "const fs = require('node:fs')" \
  "const [file, mutation] = process.argv.slice(2)" \
  "const data = JSON.parse(fs.readFileSync(file, 'utf8'))" \
  "switch (mutation) {" \
  "  case 'object': data.blockers[0].evidencePreview = { stale: 'release-readiness evidence preview' }; break" \
  "  case 'null': data.blockers[0].evidencePreview = null; break" \
  "  default: throw new Error('unknown evidence preview type mutation ' + mutation)" \
  "}" \
  "fs.writeFileSync(file, JSON.stringify(data, null, 2) + '\\n')"

actions_preview_type_cases=(
  "object|actions evidence-preview non-string object fixture"
  "null|actions evidence-preview non-string null fixture"
)
for actions_preview_type_case in "${actions_preview_type_cases[@]}"; do
  IFS='|' read -r actions_preview_type_mutation actions_preview_type_fixture_name <<< "$actions_preview_type_case"
  setup_fixture
  actions_preview_type_script="$tmp_dir/audit-release-readiness-actions-preview-${actions_preview_type_mutation}-drift.sh"
  cp "$AUDIT_SCRIPT" "$actions_preview_type_script"
  chmod +x "$actions_preview_type_script"
  perl -0pi -e "s#(log \"Wrote machine-readable blocker actions to \\\$ACTIONS_FILE\"\\n)#node \"$actions_preview_type_mutator\" \"\\\$ACTIONS_FILE\" \"$actions_preview_type_mutation\"\n\\1#" "$actions_preview_type_script"
  original_audit_script="$AUDIT_SCRIPT"
  AUDIT_SCRIPT="$actions_preview_type_script"
  expect_failure \
    "$actions_preview_type_fixture_name" \
    release-pr-fail \
    "actions evidencePreview must be a string for release-pr-readiness"
  AUDIT_SCRIPT="$original_audit_script"
done

setup_fixture
blockers_preview_script="$tmp_dir/audit-release-readiness-blockers-preview-drift.sh"
blockers_preview_mutator="$tmp_dir/corrupt-blocker-report-evidence-preview.js"
write_file "$blockers_preview_mutator" \
  "const fs = require('node:fs')" \
  "const file = process.argv[2]" \
  "const text = fs.readFileSync(file, 'utf8')" \
  "fs.writeFileSync(file, text.replace('audit-release-pr-readiness.sh failed for release-pr-fail', 'stale release-readiness evidence preview not backed by the current log'))"
cp "$AUDIT_SCRIPT" "$blockers_preview_script"
chmod +x "$blockers_preview_script"
perl -0pi -e "s#(log \"Wrote release blocker report to \\\$BLOCKERS_FILE\"\\n)#node \"$blockers_preview_mutator\" \"\\\$BLOCKERS_FILE\"\\n\\1#" "$blockers_preview_script"
original_audit_script="$AUDIT_SCRIPT"
AUDIT_SCRIPT="$blockers_preview_script"
expect_failure \
  "blocker report evidence-preview drift fixture" \
  release-pr-fail \
  "blockers.md evidence preview mismatch for release-pr-readiness"
AUDIT_SCRIPT="$original_audit_script"

setup_fixture
blockers_duplicate_preview_script="$tmp_dir/audit-release-readiness-blockers-duplicate-preview.sh"
blockers_duplicate_preview_mutator="$tmp_dir/duplicate-blocker-report-evidence-preview.js"
write_file "$blockers_duplicate_preview_mutator" \
  "const fs = require('node:fs')" \
  "const file = process.argv[2]" \
  "const text = fs.readFileSync(file, 'utf8')" \
  "const fence = String.fromCharCode(96, 96, 96)" \
  "const start = 'Evidence preview:\\n\\n' + fence + 'text\\n'" \
  "const startIndex = text.indexOf(start)" \
  "if (startIndex === -1) throw new Error('expected evidence preview block start')" \
  "const endMarker = '\\n' + fence + '\\n\\n'" \
  "const endIndex = text.indexOf(endMarker, startIndex + start.length)" \
  "if (endIndex === -1) throw new Error('expected evidence preview block end')" \
  "const block = text.slice(startIndex, endIndex + endMarker.length)" \
  "fs.writeFileSync(file, text.slice(0, startIndex) + block + block + text.slice(endIndex + endMarker.length))"
cp "$AUDIT_SCRIPT" "$blockers_duplicate_preview_script"
chmod +x "$blockers_duplicate_preview_script"
perl -0pi -e "s#(log \"Wrote release blocker report to \\\$BLOCKERS_FILE\"\\n)#node \"$blockers_duplicate_preview_mutator\" \"\\\$BLOCKERS_FILE\"\\n\\1#" "$blockers_duplicate_preview_script"
original_audit_script="$AUDIT_SCRIPT"
AUDIT_SCRIPT="$blockers_duplicate_preview_script"
expect_failure \
  "blocker report duplicate evidence-preview fixture" \
  release-pr-fail \
  "blockers.md evidence preview block count mismatch for release-pr-readiness"
AUDIT_SCRIPT="$original_audit_script"

setup_fixture
actions_order_script="$tmp_dir/audit-release-readiness-actions-order-drift.sh"
actions_order_mutator="$tmp_dir/reverse-actions-blockers.js"
write_file "$actions_order_mutator" \
  "const fs = require('node:fs')" \
  "const file = process.argv[2]" \
  "const data = JSON.parse(fs.readFileSync(file, 'utf8'))" \
  "data.blockers.reverse()" \
  "fs.writeFileSync(file, JSON.stringify(data, null, 2) + '\\n')"
cp "$AUDIT_SCRIPT" "$actions_order_script"
chmod +x "$actions_order_script"
perl -0pi -e "s#(log \"Wrote machine-readable blocker actions to \\\$ACTIONS_FILE\"\\n)#node \"$actions_order_mutator\" \"\\\$ACTIONS_FILE\"\\n\\1#" "$actions_order_script"
original_audit_script="$AUDIT_SCRIPT"
AUDIT_SCRIPT="$actions_order_script"
expect_failure \
  "actions output blocker order drift fixture" \
  multi-fail \
  "actions blocker order mismatch at index 0"
AUDIT_SCRIPT="$original_audit_script"

setup_fixture
blockers_order_script="$tmp_dir/audit-release-readiness-blockers-order-drift.sh"
blockers_order_mutator="$tmp_dir/reverse-blocker-report-sections.js"
write_file "$blockers_order_mutator" \
  "const fs = require('node:fs')" \
  "const file = process.argv[2]" \
  "const text = fs.readFileSync(file, 'utf8')" \
  "const marker = '## Failed Checks\\n\\n'" \
  "const markerIndex = text.indexOf(marker)" \
  "if (markerIndex === -1) process.exit(0)" \
  "const prefix = text.slice(0, markerIndex + marker.length)" \
  "const rest = text.slice(markerIndex + marker.length)" \
  "const skippedIndex = rest.indexOf('\\n## Skipped Checks')" \
  "const failedBody = skippedIndex === -1 ? rest : rest.slice(0, skippedIndex)" \
  "const suffix = skippedIndex === -1 ? '' : rest.slice(skippedIndex)" \
  "const trailing = failedBody.endsWith('\\n') ? '\\n' : ''" \
  "const sections = failedBody.trimEnd().split(/\\n(?=### )/).filter(Boolean)" \
  "if (sections.length > 1) fs.writeFileSync(file, prefix + sections.reverse().join('\\n') + trailing + suffix)"
cp "$AUDIT_SCRIPT" "$blockers_order_script"
chmod +x "$blockers_order_script"
perl -0pi -e "s#(log \"Wrote release blocker report to \\\$BLOCKERS_FILE\"\\n)#node \"$blockers_order_mutator\" \"\\\$BLOCKERS_FILE\"\\n\\1#" "$blockers_order_script"
original_audit_script="$AUDIT_SCRIPT"
AUDIT_SCRIPT="$blockers_order_script"
expect_failure \
  "blocker report section order drift fixture" \
  multi-fail \
  "blockers.md section order mismatch at index 0"
AUDIT_SCRIPT="$original_audit_script"

setup_fixture
expect_failure "unknown arg" good "Unknown argument" --bogus

setup_fixture
duplicate_slug_script="$tmp_dir/audit-release-readiness-duplicate-slug.sh"
cp "$AUDIT_SCRIPT" "$duplicate_slug_script"
chmod +x "$duplicate_slug_script"
perl -0pi -e 's/run_check "SI deployment evidence" "si-deployment-evidence"/run_check "SI deployment evidence" "ti-deployment-evidence"/' "$duplicate_slug_script"
original_audit_script="$AUDIT_SCRIPT"
AUDIT_SCRIPT="$duplicate_slug_script"
expect_failure \
  "duplicate check slug fixture" \
  good \
  "duplicate release-readiness check slug: ti-deployment-evidence" \
  --skip-live
AUDIT_SCRIPT="$original_audit_script"

setup_fixture
invalid_status_script="$tmp_dir/audit-release-readiness-invalid-status.sh"
cp "$AUDIT_SCRIPT" "$invalid_status_script"
chmod +x "$invalid_status_script"
perl -0pi -e 's/record_check_result "\$name" "\$slug" "skipped"/record_check_result "\$name" "\$slug" "deferred"/' "$invalid_status_script"
original_audit_script="$AUDIT_SCRIPT"
AUDIT_SCRIPT="$invalid_status_script"
expect_failure \
  "invalid check status fixture" \
  good \
  "invalid release-readiness check status: github-governance deferred" \
  --skip-live
AUDIT_SCRIPT="$original_audit_script"

setup_fixture
skipped_metadata_script="$tmp_dir/audit-release-readiness-skipped-metadata.sh"
cp "$AUDIT_SCRIPT" "$skipped_metadata_script"
chmod +x "$skipped_metadata_script"
perl -0pi -e 's/record_check_result "\$name" "\$slug" "skipped"/record_check_result "\$name" "\$slug" "skipped" 0 "\$REPORT_DIR\/\$slug.log"/' "$skipped_metadata_script"
original_audit_script="$AUDIT_SCRIPT"
AUDIT_SCRIPT="$skipped_metadata_script"
expect_failure \
  "skipped check metadata fixture" \
  good \
  "skipped release-readiness check must not carry exit code or log file: github-governance" \
  --skip-live
AUDIT_SCRIPT="$original_audit_script"

echo "[release-readiness-test] all tests passed ($SCENARIO_COUNT aggregate scenarios, $PRODUCTION_OVERRIDE_PROBE_COUNT production override probes, $PRODUCTION_PATH_PROBE_COUNT production tool-path/function probes, and $TEST_ISOLATION_PROBE_COUNT test-mode isolation probes)"
