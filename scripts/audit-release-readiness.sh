#!/bin/bash
set -euo pipefail

SCRIPT_SOURCE="${BASH_SOURCE[0]}"
case "$SCRIPT_SOURCE" in
  */*) SCRIPT_DIRECTORY_INPUT="${SCRIPT_SOURCE%/*}" ;;
  *) SCRIPT_DIRECTORY_INPUT="." ;;
esac
CANONICAL_ROOT_DIR="$(cd "$SCRIPT_DIRECTORY_INPUT/.." && pwd -P)"
TEST_MODE="${RELEASE_READINESS_TEST_MODE:-0}"

INITIAL_FUNCTION_NAMES=()
while IFS= read -r function_name; do
  [[ -n "$function_name" ]] && INITIAL_FUNCTION_NAMES+=("$function_name")
done < <(compgen -A function)

release_setup_fail() {
  echo "[release-readiness][error] $*" >&2
  exit 2
}

resolve_canonical_tool() {
  local name="$1"
  local candidate resolved
  for candidate in "/usr/bin/$name" "/bin/$name" "/usr/local/bin/$name" "/opt/homebrew/bin/$name"; do
    [[ -e "$candidate" ]] || continue
    resolved="$(/bin/realpath "$candidate" 2>/dev/null || true)"
    [[ -n "$resolved" && -f "$resolved" && -x "$resolved" ]] || continue
    printf '%s' "$candidate"
    return 0
  done
  return 1
}

PRODUCTION_FORBIDDEN_ENV_VARS=(
  RELEASE_READINESS_ROOT
  RELEASE_READINESS_PARENT
  RELEASE_READINESS_REPORT_DIR
  RELEASE_READINESS_SUMMARY_FILE
  RELEASE_READINESS_BLOCKERS_FILE
  RELEASE_READINESS_ACTIONS_FILE
  RELEASE_READINESS_UNBLOCK_BUNDLE_DIR
  RELEASE_UNBLOCK_ROOT
  RELEASE_UNBLOCK_EXPORT_NOW
  RELEASE_UNBLOCK_VERIFY_NOW
  PLAN_AUDIT_ROOT
  PLAN_AUDIT_PARENT
  PLAN_AUDIT_FAIL_FAST
  PLAN_AUDIT_ANDROID_ROOT
  PLAN_AUDIT_IOS_ROOT
  PLAN_AUDIT_IOS_TESTFLIGHT_ROOT
  PLAN_AUDIT_IROHA_ROOT
  RELEASE_PR_READINESS_ROOT
  RELEASE_PR_READINESS_CONFIG
  RELEASE_PR_READINESS_REPORT
  PRIVATE_OVERLAY_AUDIT_ROOT
  PRIVATE_OVERLAY_AUDIT_REPORT_DIR
  PUBLIC_ARTIFACT_PROVENANCE_DOC
  FEARLESS_UTILS_PATH
  FEARLESS_UTILS_COMMIT
  FEARLESS_UTILS_REPOSITORY
  FEARLESS_UTILS_LIBRARY_ONLY
  PASSKEY_CHALLENGE_SERVICE_AUDIT_ROOT
  PASSKEY_CHALLENGE_SERVICE_DIR
  PASSKEY_CHALLENGE_SERVICE_AUDIT_SKIP_COMMANDS
  PASSKEY_DEPLOYMENT_EVIDENCE_ROOT
  PASSKEY_DEPLOYMENT_EXPECTED_COMMIT
  PASSKEY_ANDROID_ASSOCIATION_FILE
  PASSKEY_DEPLOYMENT_EVIDENCE_FILE
  PASSKEY_BACKUP_PRODUCTION_CONFIG_FILE
  PASSKEY_AUDIT_ROOT
  IROHA_READINESS_ROOT
  IROHA_READINESS_PARENT
  IROHA_RELEASE_CONFIG_FILE
  IROHA_MOBILE_SDK_RELEASE_TAG
  IROHA_MOBILE_SDK_RELEASE_REPO
  IROHA_JS_SDK_VERSION
  IROHA_JS_SDK_REGISTRY
  IROHA_JS_SDK_TARBALL
  IROHA_JS_SDK_PACKAGE_DIR
  IROHA_JS_SDK_RELEASE_REPO
  IROHA_JS_SDK_RELEASE_TAG
  IROHA_JS_SDK_RELEASE_ASSET
  IROHA_JS_SDK_RELEASE_SHA256
  NEXUS_PRODUCTION_EVIDENCE_FILE
  NEXUS_PRODUCTION_EVIDENCE_AUDIT
  NEXUS_PRODUCTION_EVIDENCE_TEST
  NEXUS_EVIDENCE_ROOT
  NEXUS_TORII_URL
  NEXUS_EXPECTED_BUILD_COMMIT
  NEXUS_ROUTE_MANIFEST_EXPECTED_COMMIT
  NEXUS_ANDROID_WALLET_EXPECTED_COMMIT
  NEXUS_IOS_WALLET_EXPECTED_COMMIT
  NEXUS_WEB_WALLET_EXPECTED_COMMIT
  IROHA_WALLET_COVERAGE_ROOT
  IROHA_SEND_AGGREGATE_ROOT
  IROHA_SEND_AUDIT_ROOT
  XCM_REGISTRY_ROOT
  XCM_EFFECTIVE_REGISTRY_ROOT
  XCM_PRODUCTION_EVIDENCE_ROOT
  XCM_PRODUCTION_EXPECTED_COMMIT
  BITCOIN_BROADCAST_EVIDENCE_ROOT
  BITCOIN_BROADCAST_EVIDENCE_COMMIT
  BITCOIN_BROADCAST_EVIDENCE_INDEXER_FIXTURE
  DEPLOYMENT_EVIDENCE_ROOT
  DEPLOYMENT_EVIDENCE_EXPECTED_COMMIT
  NODE_BIN
  NPM_BIN
  YARN_BIN
  GH_BIN
  NODE_OPTIONS
  NODE_PATH
  PINNED_YARN_TEST_MODE
  PINNED_YARN_NODE_BIN
  PINNED_YARN_NPM_BIN
  SOURCE_PUBLICATION_WRAPPER_TEST_MODE
  SOURCE_PUBLICATION_WRAPPER_TEST_ROOT
  SOURCE_PUBLICATION_NODE_BIN
  SOURCE_PUBLICATION_TEST_MODE
  SOURCE_PUBLICATION_ROOT
  SOURCE_PUBLICATION_PARENT
  SOURCE_PUBLICATION_CONFIG
  SOURCE_PUBLICATION_ROOT_OWNER_CONFIG
  SOURCE_PUBLICATION_RELEASE_PR_CONFIG
  SOURCE_PUBLICATION_GIT_BIN
  SOURCE_PUBLICATION_GH_BIN
  SOURCE_PUBLICATION_NOW
  NPM_CONFIG_USERCONFIG
  npm_config_userconfig
  NPM_CONFIG_REGISTRY
  npm_config_registry
  COREPACK_HOME
  COREPACK_NPM_REGISTRY
  COREPACK_INTEGRITY_KEYS
  BASH_ENV
  ENV
  CDPATH
  PERL5OPT
  PERL5LIB
  AWKPATH
  AWKLIBPATH
)

reject_production_environment_overrides() {
  local forbidden environment_entry environment_name
  for forbidden in "${PRODUCTION_FORBIDDEN_ENV_VARS[@]}"; do
    [[ -z "${!forbidden+x}" ]] ||
      release_setup_fail "$forbidden is forbidden outside explicit RELEASE_READINESS_TEST_MODE=1"
  done

  while IFS= read -r environment_entry; do
    environment_name="${environment_entry%%=*}"
    case "$environment_name" in
      NPM_CONFIG_*|npm_config_*|COREPACK_*|YARN_*|GIT_*|GH_CONFIG_DIR|GH_HOST|GH_PAGER|GH_REPO|SSH_ASKPASS|BASH_FUNC_*|SHELLOPTS|BASHOPTS)
        release_setup_fail "$environment_name is forbidden outside explicit RELEASE_READINESS_TEST_MODE=1"
        ;;
    esac
  done < <(/usr/bin/env)

  if ((${#INITIAL_FUNCTION_NAMES[@]} > 0)); then
    release_setup_fail "exported shell functions are forbidden outside explicit RELEASE_READINESS_TEST_MODE=1: ${INITIAL_FUNCTION_NAMES[*]}"
  fi
}

require_isolated_test_path() {
  local base="$1"
  local candidate="$2"
  local label="$3"
  [[ "$candidate" == /* ]] || release_setup_fail "$label must be an absolute path in test mode"
  case "/$candidate/" in
    */../*|*/./*) release_setup_fail "$label must be lexically normalized in test mode" ;;
  esac
  case "$candidate" in
    "$base"|"$base"/*) ;;
    *) release_setup_fail "$label must remain inside the isolated test parent: $base" ;;
  esac

  local current=""
  local component
  local old_ifs="$IFS"
  local -a path_components=()
  IFS='/'
  read -r -a path_components <<< "$candidate"
  IFS="$old_ifs"
  for component in "${path_components[@]}"; do
    [[ -n "$component" ]] || continue
    current="$current/$component"
    [[ ! -L "$current" ]] || release_setup_fail "$label must not traverse a symlink in test mode: $current"
  done
}

case "$TEST_MODE" in
  0)
    reject_production_environment_overrides
    PATH="/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin:/opt/homebrew/bin"
    export PATH
    ROOT_DIR="$CANONICAL_ROOT_DIR"
    PARENT_DIR="$(cd "$ROOT_DIR/.." && pwd -P)"
    NODE_BIN="$(resolve_canonical_tool node)" || release_setup_fail "canonical node executable is unavailable"
    NPM_BIN="$(resolve_canonical_tool npm)" || release_setup_fail "canonical npm executable is unavailable"
    YARN_BIN="$ROOT_DIR/scripts/run-pinned-yarn.sh"
    ;;
  1)
    ROOT_DIR="$(cd "${RELEASE_READINESS_ROOT:-$CANONICAL_ROOT_DIR}" 2>/dev/null && pwd -P)" ||
      release_setup_fail "RELEASE_READINESS_TEST_MODE=1 requires an existing workspace root"
    PARENT_DIR="$(cd "${RELEASE_READINESS_PARENT:-$ROOT_DIR/..}" 2>/dev/null && pwd -P)" ||
      release_setup_fail "RELEASE_READINESS_TEST_MODE=1 requires an existing workspace parent"
    EXPECTED_TEST_PARENT="$(cd "$ROOT_DIR/.." && pwd -P)"
    [[ "$PARENT_DIR" == "$EXPECTED_TEST_PARENT" ]] ||
      release_setup_fail "RELEASE_READINESS_PARENT must be the isolated workspace root's canonical parent in test mode"
    if [[ -f "$CANONICAL_ROOT_DIR/FEARLESS_PROJECT_PLAN.md" ]]; then
      case "$ROOT_DIR" in
        "$CANONICAL_ROOT_DIR"|"$CANONICAL_ROOT_DIR"/*)
          release_setup_fail "RELEASE_READINESS_TEST_MODE=1 must use a root isolated from the production workspace"
          ;;
      esac
      case "$CANONICAL_ROOT_DIR" in
        "$ROOT_DIR"/*|"$PARENT_DIR"|"$PARENT_DIR"/*)
          release_setup_fail "RELEASE_READINESS_TEST_MODE=1 must use a root and parent isolated from the production workspace"
          ;;
      esac
    elif [[ "$ROOT_DIR" == "$CANONICAL_ROOT_DIR" ]]; then
      release_setup_fail "RELEASE_READINESS_TEST_MODE=1 must use an isolated non-production workspace root"
    fi
    NODE_BIN="${NODE_BIN:-node}"
    NPM_BIN="${NPM_BIN:-npm}"
    YARN_BIN="${YARN_BIN:-$ROOT_DIR/scripts/run-pinned-yarn.sh}"
    ;;
  *)
    release_setup_fail "RELEASE_READINESS_TEST_MODE must be 0 or 1"
    ;;
esac

REPORT_DIR="${RELEASE_READINESS_REPORT_DIR:-$ROOT_DIR/build/reports/release-readiness}"
SUMMARY_FILE="${RELEASE_READINESS_SUMMARY_FILE:-$REPORT_DIR/summary.json}"
BLOCKERS_FILE="${RELEASE_READINESS_BLOCKERS_FILE:-$REPORT_DIR/blockers.md}"
ACTIONS_FILE="${RELEASE_READINESS_ACTIONS_FILE:-$REPORT_DIR/actions.json}"
UNBLOCK_BUNDLE_DIR="${RELEASE_READINESS_UNBLOCK_BUNDLE_DIR:-$REPORT_DIR/unblock-bundle}"
if [[ "$TEST_MODE" == "1" ]]; then
  for isolated_child_path in \
    "$ROOT_DIR/scripts" \
    "$ROOT_DIR/fearless-Android" \
    "$ROOT_DIR/fearless-iOS" \
    "$ROOT_DIR/fearless-wallet-web" \
    "$ROOT_DIR/fearless-site-web" \
    "$ROOT_DIR/services/passkey-backup-challenge-service" \
    "$PARENT_DIR/ton-indexer" \
    "$PARENT_DIR/solswap-indexer" \
    "$PARENT_DIR/polkaswap-indexer"; do
    require_isolated_test_path "$PARENT_DIR" "$isolated_child_path" "test dependency path"
  done
  require_isolated_test_path "$PARENT_DIR" "$REPORT_DIR" "RELEASE_READINESS_REPORT_DIR"
  require_isolated_test_path "$REPORT_DIR" "$SUMMARY_FILE" "RELEASE_READINESS_SUMMARY_FILE"
  require_isolated_test_path "$REPORT_DIR" "$BLOCKERS_FILE" "RELEASE_READINESS_BLOCKERS_FILE"
  require_isolated_test_path "$REPORT_DIR" "$ACTIONS_FILE" "RELEASE_READINESS_ACTIONS_FILE"
  require_isolated_test_path "$REPORT_DIR" "$UNBLOCK_BUNDLE_DIR" "RELEASE_READINESS_UNBLOCK_BUNDLE_DIR"
fi
SOURCE_PUBLICATION_PREFLIGHT_REPORT="$REPORT_DIR/source-publication-preflight-report.json"
SOURCE_PUBLICATION_PREFLIGHT_LOG="$REPORT_DIR/source-publication-preflight.log"
SOURCE_PUBLICATION_REPORT="$REPORT_DIR/source-publication-readiness-report.json"
SOURCE_PUBLICATION_RUNNER="$ROOT_DIR/scripts/run-source-publication-readiness.sh"
SOURCE_PUBLICATION_PREFLIGHT_STATUS=0
RUN_LIVE=true
MAX_LOG_PREVIEW_LINES="${MAX_LOG_PREVIEW_LINES:-20}"
MAX_BLOCKER_LOG_LINES="${MAX_BLOCKER_LOG_LINES:-12}"
MAX_EVIDENCE_PREVIEW_CHARS="${MAX_EVIDENCE_PREVIEW_CHARS:-6000}"

usage() {
  cat <<'USAGE'
Usage: scripts/audit-release-readiness.sh [--skip-live]

Runs the root release-readiness gate suite and writes one log per check under
build/reports/release-readiness by default. The command reports every failing
gate instead of stopping at the first blocker.

Checks:
  - static cross-repo plan readiness
  - GitHub governance and hosted branch state
  - release implementation PR merge readiness
  - tested-source ownership, cleanliness, PR identity, and publication attestation
  - Android/iOS private overlay readiness
  - Android public dependency provenance and artifact boundary
  - iOS shared-features dependency delta report readiness
  - Passkey backup challenge service implementation and adversarial tests
  - Passkey backup production deployment evidence and Android release-origin parity
  - Android/iOS passkey backup prerequisites
  - live passkey backup production route smoke
  - Iroha mobile/browser SDK and SORA Nexus endpoint release prerequisites
  - Android/iOS/web Iroha/Nexus wallet transfer coverage
  - Android XCM broad-production evidence
  - Web Bitcoin funded-testnet broadcast evidence
  - TI, SI, and PI deployment evidence readiness
  - live TI, SI, and PI production smoke checks

Options:
  --skip-live  Skip GitHub governance, release PR merge readiness, source
               publication attestation, passkey
               challenge-service live health and route smoke, Nexus live
               health, and live TI/SI/PI production smoke checks.

Environment:
  RELEASE_READINESS_ROOT        Workspace root containing fearless-* repos.
  RELEASE_READINESS_PARENT      Parent directory containing sibling indexers.
  RELEASE_READINESS_REPORT_DIR  Directory for per-check logs.
  RELEASE_READINESS_SUMMARY_FILE Machine-readable JSON summary path.
  RELEASE_READINESS_BLOCKERS_FILE Operator-facing Markdown blocker report path.
  RELEASE_READINESS_ACTIONS_FILE Machine-readable blocker action manifest path.
  RELEASE_READINESS_UNBLOCK_BUNDLE_DIR Verified operator unblock bundle path.
  RELEASE_READINESS_TEST_MODE   Explicit fixture-only tool/root injection mode.
                                Production runs reject all child root/config,
                                fixture, expected-commit, and tool overrides.
                                Test roots, sibling dependencies, and outputs
                                must remain in one isolated non-symlink tree.
  MAX_LOG_PREVIEW_LINES         Failure preview lines per check.
  MAX_BLOCKER_LOG_LINES         Failure log preview lines in blockers.md.
  MAX_EVIDENCE_PREVIEW_CHARS    Maximum characters per evidence preview.
  RELEASE_READINESS_NETWORK_ATTEMPTS
                                Attempts for GitHub-backed live checks.
                                Defaults to 3.
  RELEASE_READINESS_NETWORK_RETRY_DELAY_SECONDS
                                Delay between GitHub-backed attempts.
                                Defaults to 2.
USAGE
}

while (($#)); do
  case "$1" in
    --skip-live)
      RUN_LIVE=false
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "[release-readiness][error] Unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
  shift
done

if [[ "$TEST_MODE" == "0" ]]; then
  if [[ "$RUN_LIVE" == true ]]; then
    RELEASE_GH_BIN="$(resolve_canonical_tool gh)" || release_setup_fail "canonical gh executable is unavailable"
  else
    RELEASE_GH_BIN="/usr/bin/false"
  fi
else
  RELEASE_GH_BIN="${GH_BIN:-gh}"
fi

failures=()
skipped=()
check_results=()
REPORT_GENERATED_AT=""

log() { echo "[release-readiness] $*"; }

require_file_pattern() {
  local file="$1"
  local pattern="$2"
  local label="$3"

  if [[ ! -f "$file" ]]; then
    echo "[release-readiness][error] $label missing: $file" >&2
    return 1
  fi
  if ! grep -Eq -- "$pattern" "$file"; then
    echo "[release-readiness][error] $label missing in $file" >&2
    return 1
  fi
}

require_secret_value_evidence_sentinels() {
  local audit_file="$1"
  local audit_pattern="$2"
  local test_file="$3"
  local test_pattern="$4"
  local label="$5"

  require_file_pattern "$audit_file" "$audit_pattern" "$label secret-like value gate"
  require_file_pattern "$test_file" "$test_pattern" "$label secret-like value negative test"
}

report_generated_at() {
  if [[ -z "$REPORT_GENERATED_AT" ]]; then
    REPORT_GENERATED_AT="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  fi
  printf '%s' "$REPORT_GENERATED_AT"
}

json_escape() {
  local value="$1"
  value="${value//\\/\\\\}"
  value="${value//\"/\\\"}"
  value="${value//$'\n'/\\n}"
  value="${value//$'\r'/\\r}"
  value="${value//$'\t'/\\t}"
  printf '%s' "$value"
}

json_string() {
  printf '"%s"' "$(json_escape "$1")"
}

record_check_result() {
  local name="$1"
  local slug="$2"
  local status="$3"
  local exit_code="${4:-}"
  local log_file="${5:-}"
  local result

  case "$status" in
    passed|failed)
      if [[ ! "$exit_code" =~ ^[0-9]+$ || -z "$log_file" ]]; then
        echo "[release-readiness][error] non-skipped release-readiness check must carry numeric exit code and log file: $slug" >&2
        exit 1
      fi
      ;;
    skipped)
      if [[ -n "$exit_code" || -n "$log_file" ]]; then
        echo "[release-readiness][error] skipped release-readiness check must not carry exit code or log file: $slug" >&2
        exit 1
      fi
      ;;
    *)
      echo "[release-readiness][error] invalid release-readiness check status: $slug $status" >&2
      exit 1
      ;;
  esac

  if ((${#check_results[@]} > 0)); then
    for result in "${check_results[@]}"; do
      local existing_name existing_slug existing_status existing_exit_code existing_log_file
      IFS=$'\t' read -r existing_name existing_slug existing_status existing_exit_code existing_log_file <<< "$result"
      if [[ "$existing_slug" == "$slug" ]]; then
        echo "[release-readiness][error] duplicate release-readiness check slug: $slug" >&2
        exit 1
      fi
    done
  fi
  check_results+=("$name"$'\t'"$slug"$'\t'"$status"$'\t'"$exit_code"$'\t'"$log_file")
}

write_summary() {
  local summary_dir
  summary_dir="$(dirname "$SUMMARY_FILE")"
  mkdir -p "$summary_dir"

  local generated_at
  generated_at="$(report_generated_at)"

  local passed=0
  local failed=0
  local skipped_count=0
  local result
  for result in "${check_results[@]}"; do
    local name slug status exit_code log_file
    IFS=$'\t' read -r name slug status exit_code log_file <<< "$result"
    case "$status" in
      passed) ((passed += 1)) ;;
      failed) ((failed += 1)) ;;
      skipped) ((skipped_count += 1)) ;;
    esac
  done

  local overall_status="passed"
  if ((failed > 0)); then
    overall_status="failed"
  elif ((skipped_count > 0)) || [[ "$RUN_LIVE" != true ]]; then
    overall_status="incomplete"
  fi

  local tmp_file="$SUMMARY_FILE.tmp"
  {
    printf '{\n'
    printf '  "schemaVersion": 1,\n'
    printf '  "generatedAt": '
    json_string "$generated_at"
    printf ',\n'
    printf '  "runLive": %s,\n' "$RUN_LIVE"
    printf '  "status": '
    json_string "$overall_status"
    printf ',\n'
    printf '  "totals": {\n'
    printf '    "passed": %d,\n' "$passed"
    printf '    "failed": %d,\n' "$failed"
    printf '    "skipped": %d,\n' "$skipped_count"
    printf '    "total": %d\n' "${#check_results[@]}"
    printf '  },\n'
    printf '  "checks": [\n'
    local first=true
    for result in "${check_results[@]}"; do
      local name slug status exit_code log_file
      IFS=$'\t' read -r name slug status exit_code log_file <<< "$result"
      local recommended_action="" requires_external_action="" unblock_category="" external_prerequisite="" verification_command=""
      if [[ "$status" == "failed" ]]; then
        recommended_action="$(recommended_action_for_check "$slug" "$log_file")"
        requires_external_action="$(requires_external_action_for_check "$slug" "$log_file")"
        unblock_category="$(unblock_category_for_check "$slug" "$log_file")"
        external_prerequisite="$(external_prerequisite_for_check "$slug" "$log_file")"
        verification_command="$(verification_command_for_slug "$slug")"
      fi
      if [[ "$first" == true ]]; then
        first=false
      else
        printf ',\n'
      fi
      printf '    {\n'
      printf '      "name": '
      json_string "$name"
      printf ',\n'
      printf '      "slug": '
      json_string "$slug"
      printf ',\n'
      printf '      "status": '
      json_string "$status"
      printf ',\n'
      if [[ -n "$exit_code" ]]; then
        printf '      "exitCode": %d,\n' "$exit_code"
      else
        printf '      "exitCode": null,\n'
      fi
      printf '      "logFile": '
      if [[ -n "$log_file" ]]; then
        json_string "$log_file"
      else
        printf 'null'
      fi
      printf ',\n'
      printf '      "recommendedAction": '
      if [[ "$status" == "failed" ]]; then
        json_string "$recommended_action"
      else
        printf 'null'
      fi
      printf ',\n'
      printf '      "requiresExternalAction": '
      if [[ "$status" == "failed" ]]; then
        printf '%s' "$requires_external_action"
      else
        printf 'null'
      fi
      printf ',\n'
      printf '      "unblockCategory": '
      if [[ "$status" == "failed" ]]; then
        json_string "$unblock_category"
      else
        printf 'null'
      fi
      printf ',\n'
      printf '      "externalPrerequisite": '
      if [[ "$status" == "failed" ]]; then
        json_string "$external_prerequisite"
      else
        printf 'null'
      fi
      printf ',\n'
      printf '      "verificationCommand": '
      if [[ "$status" == "failed" ]]; then
        json_string "$verification_command"
      else
        printf 'null'
      fi
      printf '\n'
      printf '    }'
    done
    printf '\n'
    printf '  ]\n'
    printf '}\n'
  } > "$tmp_file"

  mv "$tmp_file" "$SUMMARY_FILE"
  log "Wrote machine-readable summary to $SUMMARY_FILE"
}

source_publication_report_has_unsafe_iroha_state() {
  local report_file="${1:-}"
  [[ -n "$report_file" && -f "$report_file" && ! -L "$report_file" ]] || return 1

  "$NODE_BIN" - "$report_file" <<'NODE'
const fs = require('node:fs')

const reportPath = process.argv[2]
let report
try {
  report = JSON.parse(fs.readFileSync(reportPath, 'utf8'))
} catch {
  process.exit(1)
}

if (!report || typeof report !== 'object' || Array.isArray(report) || report.schemaVersion !== 2 || report.status !== 'failed' ||
    report.checkRemote !== true || !Array.isArray(report.repositories)) {
  process.exit(1)
}
const irohaRows = report.repositories.filter((row) => row && row.path === '../iroha')
if (irohaRows.length !== 1 || irohaRows[0].status !== 'failed' || !Array.isArray(irohaRows[0].failures)) {
  process.exit(1)
}
const ownerSuffix = '; only the repository owner may complete or abort it before source publication'
const unsafeFailures = new Set([
  `repository has an in-progress Git merge operation (MERGE_HEAD)${ownerSuffix}`,
  `repository has an in-progress Git rebase operation (rebase-merge)${ownerSuffix}`,
  `repository has an in-progress Git rebase operation (rebase-apply)${ownerSuffix}`,
  `repository has an in-progress Git rebase operation (rebase-apply, rebase-merge)${ownerSuffix}`,
  `repository has an in-progress Git cherry-pick operation (CHERRY_PICK_HEAD)${ownerSuffix}`,
  `repository has an in-progress Git revert operation (REVERT_HEAD)${ownerSuffix}`,
  `repository has an in-progress Git bisect operation (BISECT_START)${ownerSuffix}`,
  `repository has an in-progress Git sequencer operation (sequencer)${ownerSuffix}`,
])
const iroha = irohaRows[0]
const hasOperation = iroha.failures.some((failure) => unsafeFailures.has(failure))
const counts = ['stagedCount', 'unstagedCount', 'untrackedCount', 'unmergedCount']
const hasCanonicalCounts = counts.every((key) => Number.isSafeInteger(iroha[key]) && iroha[key] >= 0)
const unmergedFailure = hasCanonicalCounts
  ? `worktree is not clean (staged=${iroha.stagedCount}, unstaged=${iroha.unstagedCount}, untracked=${iroha.untrackedCount}, unmerged=${iroha.unmergedCount})`
  : null
const hasUnmergedIndex = iroha.unmergedCount > 0 &&
  report.totals && Number.isSafeInteger(report.totals.unmerged) &&
  report.totals.unmerged >= iroha.unmergedCount && iroha.failures.includes(unmergedFailure)
const canonicalSha = (value) => typeof value === 'string' && /^[0-9a-f]{40}$/u.test(value)
const expectedHead = 'codex/kagemusha-selector-hardening'
const expectedBase = 'optimizations'
const expectedPrNumber = 5612
const expectedPrUrl = 'https://github.com/hyperledger-iroha/iroha/pull/5612'
const expectedUpstream = `origin/${expectedHead}`
const expectedCurrentBranchUpstream = `origin/${expectedBase}`
const hasCanonicalReviewedSourceIdentity =
  iroha.repository === 'hyperledger-iroha/iroha' &&
  iroha.originRepository === 'hyperledger-iroha/iroha' &&
  iroha.head === expectedHead &&
  iroha.base === expectedBase &&
  iroha.prNumber === expectedPrNumber &&
  iroha.prUrl === expectedPrUrl &&
  iroha.prState === 'merged' &&
  iroha.branch === expectedBase &&
  iroha.upstream === expectedCurrentBranchUpstream
const branchMismatchFailure = hasCanonicalReviewedSourceIdentity
  ? `current branch mismatch: expected ${iroha.head}, received ${iroha.branch}`
  : null
const upstreamMismatchFailure = hasCanonicalReviewedSourceIdentity
  ? `upstream mismatch: expected ${expectedUpstream}, received ${iroha.upstream}`
  : null
const pullRequestHeadFailure = hasCanonicalReviewedSourceIdentity && canonicalSha(iroha.headSha) &&
    canonicalSha(iroha.prHeadSha)
  ? `local HEAD ${iroha.headSha} does not match pull request head ${iroha.prHeadSha}`
  : null
const authoritativeCurrentBranchFailure = hasCanonicalReviewedSourceIdentity && canonicalSha(iroha.headSha) &&
    canonicalSha(iroha.currentBranchRemoteSha)
  ? `local HEAD ${iroha.headSha} does not match authoritative current branch ${iroha.branch} at ${iroha.currentBranchRemoteSha}`
  : null
const cachedUpstreamCurrentBranchFailure = hasCanonicalReviewedSourceIdentity && canonicalSha(iroha.upstreamSha) &&
    canonicalSha(iroha.currentBranchRemoteSha)
  ? `cached upstream ${iroha.upstream} at ${iroha.upstreamSha} does not match authoritative current branch ${iroha.branch} at ${iroha.currentBranchRemoteSha}`
  : null
const ignoredOutputFailurePattern = /^worktree contains ignored non-published paths \([1-9][0-9]*\): .+; remove or quarantine these ignored outputs outside the source tree before publication; do not force-add generated artifacts$/u
const preflightContinuityFailure = 'source publication preflight did not pass before release checks'
const hasExactOrderedPublicationFailures = (expectedFailures) => {
  const hasContinuityMarker = iroha.failures.length === expectedFailures.length + 1 &&
    iroha.failures[expectedFailures.length] === preflightContinuityFailure
  if (iroha.failures.length !== expectedFailures.length && !hasContinuityMarker) return false
  return typeof iroha.failures[0] === 'string' && ignoredOutputFailurePattern.test(iroha.failures[0]) &&
    expectedFailures.slice(1).every((failure, index) => iroha.failures[index + 1] === failure)
}
const hasCanonicalSynchronizedPublicationFailures = hasCanonicalReviewedSourceIdentity &&
  hasExactOrderedPublicationFailures([
    null,
    branchMismatchFailure,
    pullRequestHeadFailure,
    upstreamMismatchFailure,
  ])
const hasCanonicalDriftPublicationFailures = hasCanonicalReviewedSourceIdentity &&
  hasExactOrderedPublicationFailures([
    null,
    branchMismatchFailure,
    authoritativeCurrentBranchFailure,
    pullRequestHeadFailure,
    upstreamMismatchFailure,
    cachedUpstreamCurrentBranchFailure,
  ])
const hasConfiguredHeadProof =
  iroha.remoteBranchPresent === false && iroha.remoteHeadSha === null
const hasCanonicalPublicationShaProof =
  iroha.currentBranchRemotePresent === true && canonicalSha(iroha.currentBranchRemoteSha) &&
  canonicalSha(iroha.headSha) && canonicalSha(iroha.upstreamSha) &&
  canonicalSha(iroha.prHeadSha) && iroha.prHeadSha !== iroha.headSha &&
  iroha.headSha === iroha.upstreamSha && hasConfiguredHeadProof
const hasSynchronizedAuthoritativeCurrentBranchProof = hasCanonicalPublicationShaProof &&
  iroha.currentBranchRemoteSha === iroha.headSha
const hasDriftedAuthoritativeCurrentBranchProof = hasCanonicalPublicationShaProof &&
  iroha.currentBranchRemoteSha !== iroha.headSha
const hasCanonicalPublicationProof =
  (hasSynchronizedAuthoritativeCurrentBranchProof && hasCanonicalSynchronizedPublicationFailures) ||
  (hasDriftedAuthoritativeCurrentBranchProof && hasCanonicalDriftPublicationFailures)
const hasReviewedSourceMismatch = hasCanonicalReviewedSourceIdentity &&
  iroha.head !== iroha.branch && expectedUpstream !== iroha.upstream &&
  counts.every((key) => iroha[key] === 0) &&
  hasCanonicalPublicationProof
const unsafe = hasOperation || hasUnmergedIndex || hasReviewedSourceMismatch
process.exit(unsafe ? 0 : 1)
NODE
}

plan_readiness_is_external_iroha_only() {
  local log_file="${1:-}"
  local source_report="${2:-$SOURCE_PUBLICATION_REPORT}"
  [[ "$RUN_LIVE" == true ]] || return 1
  [[ -n "$log_file" && -f "$log_file" && ! -L "$log_file" ]] || return 1

  awk '
    $0 == "[plan-readiness][error] Plan readiness audit failed:" {
      marker_count += 1
      in_summary = 1
      next
    }
    in_summary && /^  - / {
      failure_count += 1
      if ($0 !~ /^  - \.\.\/iroha /) invalid = 1
      next
    }
    in_summary && $0 !~ /^[[:space:]]*$/ { invalid = 1 }
    END {
      exit(marker_count == 1 && failure_count > 0 && invalid == 0 ? 0 : 1)
    }
  ' "$log_file" || return 1

  source_publication_report_has_unsafe_iroha_state "$source_report"
}

recommended_action_for_slug() {
  local slug="$1"
  case "$slug" in
    plan-readiness)
      printf '%s' "Fix the static plan-readiness drift in the referenced repos/scripts, then rerun bash scripts/audit-plan-readiness.sh."
      ;;
    github-governance)
      printf '%s' "Apply the documented default-branch, visibility, and branch-protection policy, then rerun bash scripts/audit-github-governance.sh."
      ;;
    release-pr-readiness)
      printf '%s' "Get every PR in config/release-readiness-prs.tsv approved, green, with all GitHub review conversations resolved including outdated unresolved threads, and merged through the protected branch flow. When the blocker is outdated-only, run bash scripts/resolve-release-pr-review-threads.sh --dry-run to inspect the exact thread IDs before any authorized resolution. After conversations are resolved and approvals are present, run bash scripts/merge-release-prs.sh --dry-run to inspect protected-branch merge candidates before any authorized merge, then rerun bash scripts/audit-release-pr-readiness.sh."
      ;;
    source-publication-readiness)
      printf '%s' "Do not commit or publish from a checkout with an in-progress merge, rebase, cherry-pick, revert, bisect, or sequencer operation or unresolved index stages; have that checkout's owner resolve the state first. Remove or quarantine every ignored non-published build output reported by the audit, then commit only reviewed tested changes. Assign the root release tooling and passkey challenge service to a canonical maintained GitHub repository, add its protected release PR to config/release-readiness-prs.tsv, and push exact topic-branch HEADs. Then rerun the full bash scripts/audit-release-readiness.sh flow so the remote-checked source preflight is captured before all release checks and matched by postflight."
      ;;
    private-overlay-readiness)
      printf '%s' "Remove private product-source drift and keep only allowed release overlay files, then rerun bash scripts/audit-private-overlay-readiness.sh."
      ;;
    android-public-dependency-provenance)
      printf '%s' "Restore fearless-utils-Android to the pinned commit plus exact committed library-only overlay with no extra drift, then restore the Android public artifact boundary and handoff bundle. Rerun bash ./scripts/test-fearless-utils-derived-tree.sh, FEARLESS_UTILS_LIBRARY_ONLY=true FEARLESS_UTILS_PATH=../fearless-utils-Android ./scripts/ensure-fearless-utils.sh, bash ./scripts/test-public-dependency-upstream-delta-export.sh, bash ./scripts/export-public-dependency-upstream-delta.sh --output build/reports/public-dependency-upstream-delta, and ./scripts/audit-public-artifacts.sh in fearless-Android."
      ;;
    ios-shared-features-delta)
      printf '%s' "Restore the iOS shared-features delta self-test/report gate, review build/reports/shared-features-delta-report.json, and rerun bash scripts/deps/test-shared-features-delta-report.sh plus bash scripts/deps/audit-shared-features-delta-report.sh \"\$PWD\" --write-report build/reports/shared-features-delta-report.json in fearless-iOS."
      ;;
    passkey-challenge-service)
      printf '%s' "Fix the passkey challenge-service implementation, Docker/deployment evidence, and adversarial tests, then rerun bash scripts/audit-passkey-challenge-service.sh."
      ;;
    passkey-deployment-evidence)
      printf '%s' "Record the passkey backup image digest, deployment ID, operator, healthResponse ok=true/service=fearless-passkey-backup/rpId=fearlesswallet.io/schemaVersion=1, durable credential store paths /data/passkey-backup and /data/passkey-backup/credentials.json, WebAuthn origin allowlist, fail-closed request-access policy, trusted-proxy policy, platform provisioning evidence, and successful smoke timestamp. Independently obtain the distribution signer SHA-256 fingerprint from a distribution-signed APK or the Play app-signing certificate, set PASSKEY_ANDROID_RELEASE_SIGNER_EVIDENCE_SOURCE=distributed-apk|play-app-signing-certificate to identify the source, and prove the derived origin matches assetlinks; AAB upload-key evidence is rejected and absence or mismatch keeps passkey flags disabled. Then rerun npm run audit:deployment-evidence -- --require-ready in services/passkey-backup-challenge-service and bash scripts/audit-passkey-android-origin-parity.sh --require-ready from the workspace root."
      ;;
    passkey-backup-prerequisites)
      printf '%s' "Deploy and route https://backup.fearlesswallet.io to services/passkey-backup-challenge-service with valid DNS/TLS and require live health response ok=true/service=fearless-passkey-backup/rpId=fearlesswallet.io/schemaVersion=1. Deploy https://fearlesswallet.io association files so the strict site verifier observes exact source parity, JSON content types, X-Content-Type-Options: nosniff, and no redirects. Keep Android/iOS passkey backup flags disabled until health, site associations, and platform provisioning pass, then rerun PASSKEY_BACKUP_LIVE_HEALTH=1 bash scripts/audit-passkey-backup-prerequisites.sh && node fearless-site-web/scripts/verify-app-associations.mjs --root fearless-site-web --live-base-url https://fearlesswallet.io."
      ;;
    passkey-production-smoke)
      printf '%s' "Deploy and route https://backup.fearlesswallet.io to services/passkey-backup-challenge-service with valid DNS/TLS. Provision PASSKEY_BACKUP_SMOKE_GRANT_HELPER=/run/secrets/passkey-smoke-grant-helper as a readable executable that issues single-use bearer grants for the exact smoke requests, then run the passkey production smoke to verify health, all four ceremony routes, and credential list/revoke/revoke-all contracts without persisting a test credential or creating an owner record."
      ;;
    iroha-release-readiness)
      printf '%s' "Do not edit or publish from an unfinished external Iroha Git operation. Have its owner produce a stable reviewed source commit and restore the pinned Iroha JS SDK release artifact so package.json exports ./ivm-artifact and the packaged runtime/declaration surface passes the wallet artifact validator. Pin NEXUS_EXPECTED_BUILD_COMMIT in config/iroha-release-readiness.env to the exact deployed Iroha build. Restore https://minamoto.sora.org/status as a bounded, non-redirecting HTTP 200 application/json Torii/Nexus status response with fresh observed_at_ms and last_block_committed_at_ms, coherent block and queue counters, a matching non-placeholder build.git_commit_sha, the exact ordered SORA routing policy (default 0/0, governance 1/1, smartcontract::deploy 2/2), and an unsealed dataspace_catalog containing ready canonical 0/0, 1/1, and 2/2 targets; record Nexus route publication, canary, and wallet live transfer smoke evidence, keep Nexus release-gated until strict production evidence passes, then rerun bash scripts/audit-iroha-release-readiness.sh."
      ;;
    iroha-wallet-coverage)
      printf '%s' "Restore Android/iOS/web Iroha/Nexus wallet coverage, fail-closed transfer tests, and each platform's explicit blocked production-send readiness contract; do not enable production send until reviewed codecs and key providers exist, then rerun bash scripts/audit-iroha-wallet-coverage.sh."
      ;;
    android-xcm-production-evidence)
      printf '%s' "Keep release ENABLE_PRODUCTION_XCM_TRANSFERS=false until the entire trust and evidence gate is ready. Obtain reviewed per-asset pallet/call, reserve-or-teleport, multilocation, beneficiary, weight, destination-fee, and any bridge execution semantics for every advertised Android XCM route; implement bridge or estimator support before approving those modes. The per-asset schema, loader, validator, registry, and engine representation is now implemented, and all 15 approved single-asset routes are migrated without semantic changes. The current 34 discovery-only destinations cover 59 route assets; 14 of those destinations cover 39 multi-asset routes, and every one remains disabled until its exact reviewed semantics exist. Expand the APK-owned approved_xcm_routes.tsv and scripts/xcm-required-routes.tsv in exact lockstep only after those route semantics are reviewed, and make the production discovery intersection contain every approved route. Then record one funded mainnet E2E transfer per required route in fearless-Android/scripts/xcm-production-evidence.json, including 0x-prefixed 32-byte extrinsicHash, sender, recipient, positive amount, UTC timestamp, environment, operator, and androidCommit matching the release commit, plus finalized origin/destination block hashes and numbers, true origin finality/extrinsic success/destination event success, a positive destination balance delta, distinct public HTTPS proof URLs, verificationMethod=canonical-rpc-and-explorer, verifiedAt, and an independentVerifier distinct from operator. Regenerate the canonical live effective report and validate it with the ready evidence, then run the all-routes metadata gate before a separately reviewed release-flag change."
      ;;
    web-bitcoin-broadcast-evidence)
      printf '%s' "Run a funded Bitcoin testnet send through the web wallet smoke flow, record txid/outpoint/operator evidence plus canonical https://blockstream.info/testnet/api indexerUrl and confirmed indexer status.block_time proof in fearless-wallet-web/scripts/bitcoin-testnet-broadcast-evidence.json, ensure the evidence timestamp is at or after the confirmed block time, then rerun bash scripts/audit-bitcoin-broadcast-evidence.sh --require-ready in fearless-wallet-web."
      ;;
    ti-deployment-evidence)
      printf '%s' "Populate ../ton-indexer/registry/mainnet.json with reviewed non-placeholder mainnet contract addresses. Record the TI Docker image digest, deployment ID, operator, commit, serviceInfo.schemaVersion=1 plus serviceInfo.serviceId=ti.soramitsu.io with TON mainnet identity, healthInfo.serviceId=ti.soramitsu.io with healthInfo.lastMasterSeqno from the successful https://ti.soramitsu.io smoke evidence, then rerun npm run audit:deployment-evidence -- --require-ready in ../ton-indexer."
      ;;
    si-deployment-evidence)
      printf '%s' "Deploy the current SI image with Solana mainnet configuration. Record the SI Docker image digest, deployment ID, operator, commit, serviceInfo.schemaVersion=1 plus serviceInfo.serviceId=si.soramitsu.io with Solana mainnet identity, and healthInfo with ok=true, serviceId=si.soramitsu.io, genesisHash=5eykt4UsFv8P8NJdTREpY1vzqKqZKvdpKuc147dw2N9d, latestSlot as a positive safe integer, and syncedAt as an integer no more than 120 seconds before and no more than 30 seconds after smokePassedAt, plus successful https://si.soramitsu.io smoke evidence in ../solswap-indexer/scripts/production-deployment-evidence.json, then rerun npm run audit:deployment-evidence -- --require-ready in ../solswap-indexer."
      ;;
    pi-deployment-evidence)
      printf '%s' "Deploy the current polkaswap-indexer worker and API to https://pi.soramitsu.io/graphql with POLKASWAP_CHAIN_START_BLOCK set, a locally-controlled verifying archival primary RPC and an independently-operated verifying archive RPC on distinct hosts. Require the exact fixed audited SORA mainnet genesis/hash/timestamp anchor identity preflight on both RPCs before database access; exact dual-RPC agreement on finalized height, hash, canonical raw SCALE block, canonical raw SCALE events, and raw decimal timestamp milliseconds; and the compiled PostgreSQL worker health check proving the exact persisted chainState, matching filtered BLOCK snapshot, checkpoint freshness from 300 seconds behind through 30 seconds ahead, and secret-safe diagnostics. API health evidence must prove healthInfo.service=polkaswap-indexer, healthInfo.serviceId=pi.soramitsu.io, exact SORA mainnet genesisHash=0x7e4e32d0feafd4f9c9414b0be86373f9a1efa904809b683453a9af6856d38ad5, latestIndexedBlock as a positive safe integer, latestIndexedBlockHash as a canonical nonzero lowercase 32-byte hash, and latestIndexedAt no more than 300 seconds before or 30 seconds after the smoke timestamp. Record the Docker image digest, deployment ID, operator, commit, those exact healthInfo fields, successful smoke timestamp, soraRpcControls with primaryEndpoint, archiveEndpoint, primaryNodeControl=locally-controlled-verifying-archive, archiveNodeControl=independently-operated-verifying-archive, distinctHosts=true, exactIdentityPreflight=true, and rawPayloadAgreement=height-hash-scale-block-events-timestamp, plus tlsEdgeControls proving TLS termination, forwarded-client-IP header overwrite, 600 HTTP requests and 600 WebSocket upgrades per client per 60000ms, and 16 concurrent WebSockets per client in ../polkaswap-indexer/scripts/production-deployment-evidence.json, then, from ../polkaswap-indexer, rerun bash ../fearless/scripts/run-pinned-yarn.sh audit:deployment-evidence --require-ready."
      ;;
    ti-production-smoke)
      printf '%s' "Deploy the current ton-indexer image to https://ti.soramitsu.io so /api/indexer/v1/health exposes lastMasterSeqno and health.serviceId=ti.soramitsu.io with ecosystem=ton, chainId=ton:mainnet, and network=mainnet. TI production smoke also requires serviceInfo.schemaVersion=1, serviceInfo.serviceId=ti.soramitsu.io, publicBaseUrl=https://ti.soramitsu.io, readOnly=true, endpoints.openapi=/api/indexer/v1/openapi.json, and OpenAPI title TONSWAP Indexer API, then rerun TON_INDEXER_BASE_URL=https://ti.soramitsu.io npm run smoke:production in ../ton-indexer."
      ;;
    si-production-smoke)
      printf '%s' "Deploy the current SI image with Solana mainnet configuration so /api/indexer/v1/health returns health.ok=true, health.serviceId=si.soramitsu.io, health.ecosystem=solana, health.chainId=solana:mainnet, health.network=mainnet, health.genesisHash=5eykt4UsFv8P8NJdTREpY1vzqKqZKvdpKuc147dw2N9d, health.latestSlot as a positive safe integer, and health.syncedAt as an integer no more than 120 seconds old and no more than 30 seconds in the future, without advertising api.testnet.solana.com, and /api/indexer/v1/service-info exists. SI production smoke also requires serviceInfo.schemaVersion=1, serviceInfo.serviceId=si.soramitsu.io, ecosystem=solana, chainId=solana:mainnet, network=mainnet, publicBaseUrl=https://si.soramitsu.io, readOnly=true, endpoints.openapi=/api/indexer/v1/openapi.json, and OpenAPI title Solswap Indexer API, then rerun SOLSWAP_INDEXER_BASE_URL=https://si.soramitsu.io npm run smoke:production in ../solswap-indexer."
      ;;
    pi-production-smoke)
      printf '%s' "Deploy the current polkaswap-indexer worker and API to https://pi.soramitsu.io/graphql with POLKASWAP_CHAIN_START_BLOCK set, a locally-controlled verifying archival primary RPC and an independently-operated verifying archive RPC on distinct hosts. Require the exact fixed audited SORA mainnet genesis/hash/timestamp anchor identity preflight on both RPCs before database access; exact dual-RPC agreement on finalized height, hash, canonical raw SCALE block, canonical raw SCALE events, and raw decimal timestamp milliseconds; and the compiled PostgreSQL worker health check proving the exact persisted chainState, matching filtered BLOCK snapshot, checkpoint freshness from 300 seconds behind through 30 seconds ahead, and secret-safe diagnostics. GraphQL _health must return health.ok=true, health.service=polkaswap-indexer, health.serviceId=pi.soramitsu.io, health.schemaVersion=1, health.ecosystem=sora2, health.chainId=sora:mainnet, health.network=mainnet, health.publicBaseUrl=https://pi.soramitsu.io/graphql, health.readOnly=true, exact SORA mainnet genesisHash=0x7e4e32d0feafd4f9c9414b0be86373f9a1efa904809b683453a9af6856d38ad5, a positive latestIndexedBlock, a canonical nonzero lowercase 32-byte latestIndexedBlockHash, and a latestIndexedAt within 300 seconds behind or 30 seconds ahead of the verifier. PI production smoke also requires an immutable exact fixed-anchor chainIdentity, a chainState record at or below finalized height and coherent with the health height/hash/timestamp, live hash and raw timestamp reconciliation, and a matching filtered BLOCK snapshot, and rejects TON and Solana/Solswap indexer contracts. Then, from ../polkaswap-indexer, rerun POLKASWAP_INDEXER_BASE_URL=https://pi.soramitsu.io/graphql bash ../fearless/scripts/run-pinned-yarn.sh smoke:production."
      ;;
    *)
      printf '%s' "Open the referenced log, fix the failing release gate, and rerun ./scripts/audit-release-readiness.sh."
      ;;
  esac
}

verification_command_for_slug() {
  local slug="$1"
  case "$slug" in
    plan-readiness)
      printf '%s' "bash scripts/audit-plan-readiness.sh"
      ;;
    github-governance)
      printf '%s' "bash scripts/audit-github-governance.sh"
      ;;
    release-pr-readiness)
      printf '%s' "bash scripts/audit-release-pr-readiness.sh"
      ;;
    source-publication-readiness)
      printf '%s' "bash scripts/audit-release-readiness.sh"
      ;;
    private-overlay-readiness)
      printf '%s' "bash scripts/audit-private-overlay-readiness.sh"
      ;;
    android-public-dependency-provenance)
      printf '%s' "cd fearless-Android && bash ./scripts/test-fearless-utils-derived-tree.sh && FEARLESS_UTILS_PATH=../fearless-utils-Android FEARLESS_UTILS_COMMIT=7500809f33243ee47ecb2ec8563fc284ac4de0d6 FEARLESS_UTILS_REPOSITORY=soramitsu/fearless-utils-Android FEARLESS_UTILS_LIBRARY_ONLY=true ./scripts/ensure-fearless-utils.sh && bash ./scripts/test-public-dependency-upstream-delta-export.sh && bash ./scripts/export-public-dependency-upstream-delta.sh --output build/reports/public-dependency-upstream-delta && ./scripts/audit-public-artifacts.sh --strict-provenance"
      ;;
    ios-shared-features-delta)
      printf '%s' "cd fearless-iOS && bash scripts/deps/test-shared-features-delta-report.sh && bash scripts/deps/audit-shared-features-delta-report.sh \"\$PWD\" --write-report build/reports/shared-features-delta-report.json"
      ;;
    passkey-challenge-service)
      printf '%s' "bash scripts/audit-passkey-challenge-service.sh"
      ;;
    passkey-deployment-evidence)
      printf '%s' "cd services/passkey-backup-challenge-service && npm run audit:deployment-evidence -- --require-ready && cd ../.. && bash scripts/audit-passkey-android-origin-parity.sh --require-ready"
      ;;
    passkey-backup-prerequisites)
      printf '%s' "PASSKEY_BACKUP_LIVE_HEALTH=1 bash scripts/audit-passkey-backup-prerequisites.sh && node fearless-site-web/scripts/verify-app-associations.mjs --root fearless-site-web --live-base-url https://fearlesswallet.io"
      ;;
    passkey-production-smoke)
      printf '%s' "cd services/passkey-backup-challenge-service && PASSKEY_BACKUP_BASE_URL=https://backup.fearlesswallet.io PASSKEY_BACKUP_SMOKE_GRANT_HELPER=/run/secrets/passkey-smoke-grant-helper PASSKEY_BACKUP_SMOKE_TIMEOUT_MS=10000 npm run smoke:production"
      ;;
    iroha-release-readiness)
      printf '%s' "IROHA_NEXUS_REQUIRE_PRODUCTION_EVIDENCE=1 IROHA_NEXUS_LIVE_HEALTH=1 bash scripts/audit-iroha-release-readiness.sh"
      ;;
    iroha-wallet-coverage)
      printf '%s' "bash scripts/audit-iroha-wallet-coverage.sh"
      ;;
    android-xcm-production-evidence)
      printf '%s' "cd fearless-Android && bash scripts/audit-xcm-effective-registry.sh --discovery-url https://raw.githubusercontent.com/soramitsu/shared-features-utils/master/chains/v13/chains.json --require-all-approved --write-report build/reports/xcm-effective-registry-report.json && bash scripts/audit-xcm-production-evidence.sh --effective-registry-report build/reports/xcm-effective-registry-report.json --require-ready && bash scripts/audit-xcm-registry-metadata.sh --require-executable --require-all-routes-executable --require-route-file scripts/xcm-required-routes.tsv --require-gap-file scripts/xcm-discovery-only-routes.tsv"
      ;;
    web-bitcoin-broadcast-evidence)
      printf '%s' "cd fearless-wallet-web && bash scripts/audit-bitcoin-broadcast-evidence.sh --require-ready"
      ;;
    ti-deployment-evidence)
      printf '%s' "cd ../ton-indexer && npm run audit:deployment-evidence -- --require-ready"
      ;;
    si-deployment-evidence)
      printf '%s' "cd ../solswap-indexer && npm run audit:deployment-evidence -- --require-ready"
      ;;
    pi-deployment-evidence)
      printf '%s' "cd ../polkaswap-indexer && bash ../fearless/scripts/run-pinned-yarn.sh audit:deployment-evidence --require-ready"
      ;;
    ti-production-smoke)
      printf '%s' "cd ../ton-indexer && TON_INDEXER_BASE_URL=https://ti.soramitsu.io npm run smoke:production"
      ;;
    si-production-smoke)
      printf '%s' "cd ../solswap-indexer && SOLSWAP_INDEXER_BASE_URL=https://si.soramitsu.io npm run smoke:production"
      ;;
    pi-production-smoke)
      printf '%s' "cd ../polkaswap-indexer && POLKASWAP_INDEXER_BASE_URL=https://pi.soramitsu.io/graphql bash ../fearless/scripts/run-pinned-yarn.sh smoke:production"
      ;;
    *)
      printf '%s' "./scripts/audit-release-readiness.sh"
      ;;
  esac
}

requires_external_action_for_slug() {
  local slug="$1"
  case "$slug" in
    github-governance|release-pr-readiness|source-publication-readiness|passkey-deployment-evidence|passkey-backup-prerequisites|passkey-production-smoke|iroha-release-readiness|android-xcm-production-evidence|web-bitcoin-broadcast-evidence|ti-deployment-evidence|si-deployment-evidence|pi-deployment-evidence|ti-production-smoke|si-production-smoke|pi-production-smoke)
      printf 'true'
      ;;
    *)
      printf 'false'
      ;;
  esac
}

unblock_category_for_slug() {
  local slug="$1"
  case "$slug" in
    github-governance)
      printf '%s' "github-admin"
      ;;
    release-pr-readiness)
      printf '%s' "review-and-merge"
      ;;
    source-publication-readiness)
      printf '%s' "source-publication"
      ;;
    passkey-deployment-evidence|ti-deployment-evidence|si-deployment-evidence|pi-deployment-evidence)
      printf '%s' "deployment-evidence"
      ;;
    passkey-backup-prerequisites|passkey-production-smoke|ti-production-smoke|pi-production-smoke)
      printf '%s' "live-service-deployment"
      ;;
    iroha-release-readiness)
      printf '%s' "live-service-and-evidence"
      ;;
    android-xcm-production-evidence)
      printf '%s' "route-implementation-and-evidence"
      ;;
    web-bitcoin-broadcast-evidence)
      printf '%s' "funded-broadcast-evidence"
      ;;
    si-production-smoke)
      printf '%s' "live-service-deployment"
      ;;
    ios-shared-features-delta)
      printf '%s' "upstream-dependency"
      ;;
    private-overlay-readiness)
      printf '%s' "private-overlay-cleanup"
      ;;
    plan-readiness|android-public-dependency-provenance|passkey-challenge-service|iroha-wallet-coverage)
      printf '%s' "local-code"
      ;;
    *)
      printf '%s' "local-code"
      ;;
  esac
}

external_prerequisite_for_slug() {
  local slug="$1"
  case "$slug" in
    github-governance)
      printf '%s' "GitHub admin access to apply default-branch, visibility, and branch-protection policy."
      ;;
    release-pr-readiness)
      printf '%s' "Reviewer approvals, resolved GitHub review conversations, and protected-branch merges."
      ;;
    source-publication-readiness)
      printf '%s' "Owner-resolved completion of every in-progress Git operation or unmerged index state, removal or quarantine of ignored non-published build outputs, canonical Git ownership for the root release/passkey source, plus reviewed commits, pushes, and protected pull requests for the exact tested HEAD of every source tree."
      ;;
    passkey-deployment-evidence)
      printf '%s' "Production passkey backup deployment image, health response, credential-store volume, request-access and trusted-proxy evidence, plus independently obtained distribution signer SHA-256 evidence from a distribution-signed APK or Play app-signing certificate, with PASSKEY_ANDROID_RELEASE_SIGNER_EVIDENCE_SOURCE=distributed-apk|play-app-signing-certificate and a matching assetlinks origin; AAB upload-key evidence is rejected and absence keeps passkey flags disabled."
      ;;
    passkey-backup-prerequisites)
      printf '%s' "DNS, TLS, and routing for backup.fearlesswallet.io plus production deployment of the exact fearlesswallet.io assetlinks/AASA source contracts with JSON content types, nosniff headers, and no redirects."
      ;;
    passkey-production-smoke)
      printf '%s' "DNS, TLS, and routing for backup.fearlesswallet.io to the passkey backup challenge service route surface, plus PASSKEY_BACKUP_SMOKE_GRANT_HELPER=/run/secrets/passkey-smoke-grant-helper provisioned as a readable executable that issues single-use bearer grants for the exact smoke requests."
      ;;
    iroha-release-readiness)
      printf '%s' "A stable owner-reviewed Iroha source commit; a pinned Iroha JS SDK release artifact exporting ./ivm-artifact and passing packaged runtime/declaration validation; the exact deployed Iroha build pin; bounded, non-redirecting HTTP 200 application/json Minamoto Torii/Nexus status with fresh observation and block timestamps, coherent block and queue counters, exact canonical routing/dataspace catalog; plus route publication, canary, and wallet live-transfer evidence."
      ;;
    android-xcm-production-evidence)
      printf '%s' "Reviewed per-asset execution semantics and effective production discovery for every advertised Android XCM route, implementation of any required bridge or fee-estimator path, a separately reviewed release enablement change, funded mainnet E2E evidence for the exact effective route set, and Android release-commit binding."
      ;;
    web-bitcoin-broadcast-evidence)
      printf '%s' "Funded confirmed Bitcoin testnet broadcast evidence for the current release commit using the canonical Blockstream testnet indexer."
      ;;
    ti-deployment-evidence)
      printf '%s' "Reviewed TON mainnet registry addresses plus deployed TI image, smoke, and health evidence."
      ;;
    si-deployment-evidence)
      printf '%s' "Current SI image deployed with exact Solana mainnet genesisHash, positive latestSlot, fresh integer syncedAt, service-info identity, and operator-attested deployment evidence."
      ;;
    pi-deployment-evidence)
      printf '%s' "Current PI worker/API deployed with required POLKASWAP_CHAIN_START_BLOCK, a locally-controlled verifying archival primary RPC and independently-operated verifying archive RPC on distinct hosts, exact fixed-anchor identity preflight, exact dual raw payload agreement, compiled PostgreSQL worker health proving exact persisted state/snapshot freshness with secret-safe diagnostics, and operator-attested image, deployment, commit, four-field health, SORA RPC-control, smoke, and TLS-edge evidence."
      ;;
    ti-production-smoke)
      printf '%s' "Updated TON indexer deployment serving TI mainnet health, service-info, and OpenAPI contracts."
      ;;
    si-production-smoke)
      printf '%s' "Current SI image deployed with exact Solana mainnet genesisHash, positive latestSlot, fresh integer syncedAt, release identity fields, service-info, and OpenAPI contracts."
      ;;
    pi-production-smoke)
      printf '%s' "Updated PI worker/API serving the four SORA identity/checkpoint fields through GraphQL _health and coherent immutable chainIdentity, chainState, and filtered BLOCK worker state, backed by distinct controlled verifying archival RPCs, exact identity preflight and raw payload agreement, required chain start, and the compiled secret-safe worker health check."
      ;;
    ios-shared-features-delta)
      printf '%s' "Upstream shared-features publication of carried compatibility and native-crypto deltas."
      ;;
    private-overlay-readiness)
      printf '%s' "Private repo tracking cleanup so only allowed release overlay files remain tracked."
      ;;
    android-public-dependency-provenance)
      printf '%s' "Pinned public fearless-utils-Android checkout and public dependency handoff bundle."
      ;;
    *)
      printf '%s' "No external prerequisite is expected; fix the local failing release gate."
      ;;
  esac
}

log_evidence_preview() {
  local log_file="$1"
  [[ -s "$log_file" ]] || return 0

  local actionable_lines preview max_chars
  actionable_lines="$(grep -E '(\[(warn|error)\]|Error:|failed|not release-ready|Curl output|Body preview|Route .*indexer)' "$log_file" | tail -n "$MAX_BLOCKER_LOG_LINES" || true)"
  if [[ -n "$actionable_lines" ]]; then
    preview="$actionable_lines"
  else
    preview="$(tail -n "$MAX_BLOCKER_LOG_LINES" "$log_file")"
  fi

  max_chars="$MAX_EVIDENCE_PREVIEW_CHARS"
  if [[ "$max_chars" =~ ^[0-9]+$ ]] && ((max_chars > 0)) && ((${#preview} > max_chars)); then
    local capped_preview
    capped_preview="${preview: -max_chars}"
    if [[ "$capped_preview" == *$'\n'* ]]; then
      capped_preview="${capped_preview#*$'\n'}"
      [[ -n "$capped_preview" ]] || capped_preview="${preview: -max_chars}"
    else
      printf '[line capped to final %d characters; see full log]\n' "$max_chars"
    fi
    printf '%s\n' "$capped_preview"
    printf '[excerpt capped at %d characters; see full log]\n' "$max_chars"
  else
    printf '%s\n' "$preview"
  fi
}

recommended_action_for_check() {
  local slug="$1"
  local log_file="${2:-}"
  if [[ "$slug" == "plan-readiness" ]] && plan_readiness_is_external_iroha_only "$log_file"; then
    printf '%s' "Do not edit or publish from the unsafe external ../iroha checkout. Have its owner resolve any in-progress Git operation or unmerged index state and restore every reported Iroha source and browser-artifact contract on a stable reviewed commit, then rerun bash scripts/audit-plan-readiness.sh."
  else
    recommended_action_for_slug "$slug"
  fi
}

requires_external_action_for_check() {
  local slug="$1"
  local log_file="${2:-}"
  if [[ "$slug" == "plan-readiness" ]] && plan_readiness_is_external_iroha_only "$log_file"; then
    printf 'true'
  else
    requires_external_action_for_slug "$slug"
  fi
}

unblock_category_for_check() {
  local slug="$1"
  local log_file="${2:-}"
  if [[ "$slug" == "plan-readiness" ]] && plan_readiness_is_external_iroha_only "$log_file"; then
    printf '%s' "upstream-dependency"
  else
    unblock_category_for_slug "$slug"
  fi
}

external_prerequisite_for_check() {
  local slug="$1"
  local log_file="${2:-}"
  if [[ "$slug" == "plan-readiness" ]] && plan_readiness_is_external_iroha_only "$log_file"; then
    printf '%s' "Owner-coordinated resolution of the unsafe external ../iroha source state, followed by a stable reviewed checkout containing every audited Iroha source and browser-artifact contract."
  else
    external_prerequisite_for_slug "$slug"
  fi
}

write_action_manifest() {
  local actions_dir
  actions_dir="$(dirname "$ACTIONS_FILE")"
  mkdir -p "$actions_dir"

  local generated_at
  generated_at="$(report_generated_at)"

  local passed=0
  local failed=0
  local skipped_count=0
  local result
  for result in "${check_results[@]}"; do
    local name slug status exit_code log_file
    IFS=$'\t' read -r name slug status exit_code log_file <<< "$result"
    case "$status" in
      passed) ((passed += 1)) ;;
      failed) ((failed += 1)) ;;
      skipped) ((skipped_count += 1)) ;;
    esac
  done

  local overall_status="passed"
  if ((failed > 0)); then
    overall_status="failed"
  elif ((skipped_count > 0)) || [[ "$RUN_LIVE" != true ]]; then
    overall_status="incomplete"
  fi

  local tmp_file="$ACTIONS_FILE.tmp"
  {
    printf '{\n'
    printf '  "schemaVersion": 1,\n'
    printf '  "generatedAt": '
    json_string "$generated_at"
    printf ',\n'
    printf '  "runLive": %s,\n' "$RUN_LIVE"
    printf '  "status": '
    json_string "$overall_status"
    printf ',\n'
    printf '  "totals": {\n'
    printf '    "passed": %d,\n' "$passed"
    printf '    "failed": %d,\n' "$failed"
    printf '    "skipped": %d,\n' "$skipped_count"
    printf '    "total": %d\n' "${#check_results[@]}"
    printf '  },\n'
    printf '  "blockers": [\n'
    local first=true
    for result in "${check_results[@]}"; do
      local name slug status exit_code log_file
      IFS=$'\t' read -r name slug status exit_code log_file <<< "$result"
      [[ "$status" == "failed" ]] || continue

      local recommended_action verification_command requires_external_action evidence_preview unblock_category external_prerequisite
      recommended_action="$(recommended_action_for_check "$slug" "$log_file")"
      verification_command="$(verification_command_for_slug "$slug")"
      requires_external_action="$(requires_external_action_for_check "$slug" "$log_file")"
      unblock_category="$(unblock_category_for_check "$slug" "$log_file")"
      external_prerequisite="$(external_prerequisite_for_check "$slug" "$log_file")"
      evidence_preview="$(log_evidence_preview "$log_file")"

      if [[ "$first" == true ]]; then
        first=false
      else
        printf ',\n'
      fi
      printf '    {\n'
      printf '      "name": '
      json_string "$name"
      printf ',\n'
      printf '      "slug": '
      json_string "$slug"
      printf ',\n'
      printf '      "exitCode": %d,\n' "$exit_code"
      printf '      "logFile": '
      json_string "$log_file"
      printf ',\n'
      printf '      "recommendedAction": '
      json_string "$recommended_action"
      printf ',\n'
      printf '      "requiresExternalAction": %s,\n' "$requires_external_action"
      printf '      "unblockCategory": '
      json_string "$unblock_category"
      printf ',\n'
      printf '      "externalPrerequisite": '
      json_string "$external_prerequisite"
      printf ',\n'
      printf '      "verificationCommand": '
      json_string "$verification_command"
      printf ',\n'
      printf '      "evidencePreview": '
      json_string "$evidence_preview"
      printf '\n'
      printf '    }'
    done
    printf '\n'
    printf '  ]\n'
    printf '}\n'
  } > "$tmp_file"

  mv "$tmp_file" "$ACTIONS_FILE"
  log "Wrote machine-readable blocker actions to $ACTIONS_FILE"
}

write_blocker_report() {
  local blockers_dir
  blockers_dir="$(dirname "$BLOCKERS_FILE")"
  mkdir -p "$blockers_dir"

  local generated_at
  generated_at="$(report_generated_at)"

  local passed=0
  local failed=0
  local skipped_count=0
  local result
  for result in "${check_results[@]}"; do
    local name slug status exit_code log_file
    IFS=$'\t' read -r name slug status exit_code log_file <<< "$result"
    case "$status" in
      passed) ((passed += 1)) ;;
      failed) ((failed += 1)) ;;
      skipped) ((skipped_count += 1)) ;;
    esac
  done

  local tmp_file="$BLOCKERS_FILE.tmp"
  {
    printf '# Release Readiness Blockers\n\n'
    printf -- '- Generated at: %s\n' "$generated_at"
    printf -- '- Run live checks: %s\n' "$RUN_LIVE"
    printf -- '- Totals: %d passed, %d failed, %d skipped, %d total\n\n' "$passed" "$failed" "$skipped_count" "${#check_results[@]}"

    if ((failed == 0)); then
      if ((skipped_count > 0)) || [[ "$RUN_LIVE" != true ]]; then
        printf 'Release readiness is incomplete because required live checks were skipped; this run is not production-ready evidence.\n\n'
      else
        printf 'No blocking release-readiness failures recorded.\n\n'
      fi
    else
      printf '## Failed Checks\n\n'
      for result in "${check_results[@]}"; do
        local name slug status exit_code log_file
        IFS=$'\t' read -r name slug status exit_code log_file <<< "$result"
        [[ "$status" == "failed" ]] || continue

        printf '### %s\n\n' "$name"
        printf -- '- Slug: `%s`\n' "$slug"
        printf -- '- Exit code: `%s`\n' "$exit_code"
        printf -- '- Log: `%s`\n' "$log_file"
        printf -- '- Recommended action: %s\n' "$(recommended_action_for_check "$slug" "$log_file")"
        printf -- '- Requires external action: `%s`\n' "$(requires_external_action_for_check "$slug" "$log_file")"
        printf -- '- Unblock category: `%s`\n' "$(unblock_category_for_check "$slug" "$log_file")"
        printf -- '- External prerequisite: %s\n' "$(external_prerequisite_for_check "$slug" "$log_file")"
        printf -- '- Verification command: `%s`\n\n' "$(verification_command_for_slug "$slug")"

        if [[ -s "$log_file" ]]; then
          printf 'Evidence preview:\n\n'
          printf '```text\n'
          log_evidence_preview "$log_file"
          printf '```\n\n'
        fi
      done
    fi

    if ((skipped_count > 0)); then
      printf '## Skipped Checks\n\n'
      for result in "${check_results[@]}"; do
        local name slug status exit_code log_file
        IFS=$'\t' read -r name slug status exit_code log_file <<< "$result"
        [[ "$status" == "skipped" ]] || continue
        printf -- '- `%s` (%s)\n' "$slug" "$name"
      done
      printf '\n'
    fi
  } > "$tmp_file"

  mv "$tmp_file" "$BLOCKERS_FILE"
  log "Wrote release blocker report to $BLOCKERS_FILE"
}

validate_release_output_contracts() {
  local expected_file
  expected_file="$(mktemp)"

  local result
  for result in "${check_results[@]}"; do
    local name slug status exit_code log_file recommended_action requires_external_action unblock_category external_prerequisite verification_command
    IFS=$'\t' read -r name slug status exit_code log_file <<< "$result"
    recommended_action=""
    requires_external_action=""
    unblock_category=""
    external_prerequisite=""
    verification_command=""
    if [[ "$status" == "failed" ]]; then
      recommended_action="$(recommended_action_for_check "$slug" "$log_file")"
      requires_external_action="$(requires_external_action_for_check "$slug" "$log_file")"
      unblock_category="$(unblock_category_for_check "$slug" "$log_file")"
      external_prerequisite="$(external_prerequisite_for_check "$slug" "$log_file")"
      verification_command="$(verification_command_for_slug "$slug")"
    fi
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$name" \
      "$slug" \
      "$status" \
      "$exit_code" \
      "$log_file" \
      "$recommended_action" \
      "$requires_external_action" \
      "$unblock_category" \
      "$external_prerequisite" \
      "$verification_command"
  done > "$expected_file"

  if ! "$NODE_BIN" - "$SUMMARY_FILE" "$ACTIONS_FILE" "$BLOCKERS_FILE" "$expected_file" <<'NODE'
const fs = require('node:fs')

const [, , summaryFile, actionsFile, blockersFile, expectedFile] = process.argv

function fail(message) {
  console.error(`[release-readiness][error] ${message}`)
  process.exit(1)
}

function assert(condition, message) {
  if (!condition) {
    fail(message)
  }
}

function readJson(file, label) {
  try {
    return JSON.parse(fs.readFileSync(file, 'utf8'))
  } catch (error) {
    fail(`${label} must be readable JSON: ${error.message}`)
  }
}

function occurrences(haystack, needle) {
  return haystack.split(needle).length - 1
}

function assertObjectKeys(value, expectedKeys, label) {
  assert(value && typeof value === 'object' && !Array.isArray(value), `${label} must be an object`)
  const actualKeys = Object.keys(value)
  assert(
    actualKeys.length === expectedKeys.length && expectedKeys.every((key, index) => actualKeys[index] === key),
    `${label} keys mismatch: expected ${expectedKeys.join(',')}; got ${actualKeys.join(',')}`
  )
}

function assertUtcTimestamp(value, label) {
  assert(
    typeof value === 'string' && /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$/.test(value),
    `${label} must be a UTC ISO-8601 timestamp`
  )
  const time = Date.parse(value)
  const canonical = Number.isFinite(time) ? new Date(time).toISOString().replace('.000Z', 'Z') : ''
  assert(canonical === value, `${label} must be a valid UTC ISO-8601 timestamp`)
  return time
}

function assertNotFutureTimestamp(timeMs, label) {
  const futureSkewMs = 5 * 60 * 1000
  assert(timeMs <= Date.now() + futureSkewMs, `${label} must not be in the future`)
}

function assertNonNegativeInteger(value, label) {
  assert(
    Number.isInteger(value) && value >= 0,
    `${label} must be a non-negative integer`
  )
}

function assertSchemaVersion(value, label, mismatchMessage) {
  assert(Number.isInteger(value), `${label} must be integer 1`)
  assert(value === 1, mismatchMessage)
}

function assertSummaryExitCodeForStatus(value, status, label) {
  assertNonNegativeInteger(value, label)
  if (status === 'passed') {
    assert(value === 0, `${label} must be 0 for passed check`)
  }
  if (status === 'failed') {
    assert(value > 0, `${label} must be positive for failed check`)
  }
}

function assertFailedBlockerExitCode(value, label) {
  assertNonNegativeInteger(value, label)
  assert(value > 0, `${label} must be positive for failed blocker`)
}

function assertString(value, label) {
  assert(typeof value === 'string', `${label} must be a string`)
}

function assertOverallStatus(value, label) {
  assertString(value, label)
  assert(value === 'passed' || value === 'failed' || value === 'incomplete', `${label} must be passed, failed, or incomplete`)
}

function assertCheckStatus(value, label) {
  assertString(value, label)
  assert(
    value === 'passed' || value === 'failed' || value === 'skipped',
    `${label} must be passed, failed, or skipped`
  )
}

function assertBoolean(value, label, message = `${label} must be boolean`) {
  assert(typeof value === 'boolean', message)
}

function assertNull(value, label) {
  assert(value === null, `${label} must be null`)
}

function assertLogFile(row) {
  let stat
  try {
    stat = fs.statSync(row.logFile)
  } catch (error) {
    fail(`${row.slug} log file must be a regular file`)
  }
  assert(stat.isFile(), `${row.slug} log file must be a regular file`)
  if (row.status === 'failed') {
    assert(stat.size > 0, `${row.slug} failed log file must be non-empty`)
  }
}

function parseExpected(file) {
  const rawBody = fs.readFileSync(file, 'utf8')
  const body = rawBody.endsWith('\n') ? rawBody.slice(0, -1) : rawBody
  if (!body) {
    return []
  }
  return body.split('\n').map((line) => {
    const fields = line.split('\t')
    assert(fields.length === 10, 'release output validator expected-row field count mismatch')
    const [
      name,
      slug,
      status,
      exitCode,
      logFile,
      recommendedAction,
      requiresExternalAction,
      unblockCategory,
      externalPrerequisite,
      verificationCommand
    ] = fields
    return {
      name,
      slug,
      status,
      exitCode,
      logFile,
      recommendedAction,
      requiresExternalAction,
      unblockCategory,
      externalPrerequisite,
      verificationCommand
    }
  })
}

function expectedExternalAction(row) {
  if (row.requiresExternalAction === 'true') {
    return true
  }
  if (row.requiresExternalAction === 'false') {
    return false
  }
  fail(`${row.slug} expected requiresExternalAction must be true or false`)
}

function blockerSection(markdown, row) {
  const slugLine = `- Slug: \`${row.slug}\``
  const slugIndex = markdown.indexOf(slugLine)
  assert(slugIndex !== -1, `blockers.md missing slug line for ${row.slug}`)
  assert(occurrences(markdown, slugLine) === 1, `blockers.md duplicate slug line for ${row.slug}`)
  const sectionStartMarker = markdown.lastIndexOf('\n### ', slugIndex)
  const sectionStart = sectionStartMarker === -1 ? 0 : sectionStartMarker + 1
  const sectionEndMarkers = ['\n### ', '\n## ']
    .map((marker) => markdown.indexOf(marker, slugIndex + slugLine.length))
    .filter((index) => index !== -1)
  const sectionEnd = sectionEndMarkers.length > 0 ? Math.min(...sectionEndMarkers) : -1
  const section = markdown.slice(sectionStart, sectionEnd === -1 ? markdown.length : sectionEnd)
  return sectionEnd === -1 && section.endsWith('\n\n') ? section.slice(0, -1) : section
}

function expectedBlockerSection(row) {
  let section = ''
  section += `### ${row.name}\n\n`
  section += `- Slug: \`${row.slug}\`\n`
  section += `- Exit code: \`${row.exitCode}\`\n`
  section += `- Log: \`${row.logFile}\`\n`
  section += `- Recommended action: ${row.recommendedAction}\n`
  section += `- Requires external action: \`${row.requiresExternalAction}\`\n`
  section += `- Unblock category: \`${row.unblockCategory}\`\n`
  section += `- External prerequisite: ${row.externalPrerequisite}\n`
  section += `- Verification command: \`${row.verificationCommand}\`\n`

  const expectedPreview = logEvidencePreview(row.logFile)
  if (expectedPreview) {
    section += '\nEvidence preview:\n\n'
    section += '```text\n'
    section += `${expectedPreview}\n`
    section += '```\n'
  }

  return section
}

function assertBlockerSectionContent(section, row) {
  assert(section === expectedBlockerSection(row), `blockers.md section content mismatch for ${row.slug}`)
}

function blockerReportLeadBody(markdown, expectedTotalsLine) {
  const totalsMarker = `${expectedTotalsLine}\n\n`
  const totalsIndex = markdown.indexOf(totalsMarker)
  assert(totalsIndex !== -1, 'blockers.md totals mismatch')
  const bodyStart = totalsIndex + totalsMarker.length
  const bodyEnd = markdown.indexOf('\n## ', bodyStart)
  const body = markdown.slice(bodyStart, bodyEnd === -1 ? markdown.length : bodyEnd)
  return body.endsWith('\n\n') ? body.slice(0, -1) : body
}

function assertBlockerReportNonFailureSection(markdown, expectedTotalsLine, expectedStatus) {
  const expectedBody = expectedStatus === 'incomplete'
    ? 'Release readiness is incomplete because required live checks were skipped; this run is not production-ready evidence.\n'
    : 'No blocking release-readiness failures recorded.\n'
  assert(
    blockerReportLeadBody(markdown, expectedTotalsLine) === expectedBody,
    'blockers.md non-failure section content mismatch'
  )
}

function expectedSkippedSection(rows) {
  return rows.map((row) => `- \`${row.slug}\` (${row.name})`).join('\n') + '\n'
}

function assertSkippedSectionContent(section, rows) {
  const normalizedSection = section.endsWith('\n\n') ? section.slice(0, -1) : section
  assert(normalizedSection === expectedSkippedSection(rows), 'blockers.md skipped section content mismatch')
}

function assertBlockerReportPreamble(markdown, summary, expectedTotalsLine) {
  const expectedPreamble = [
    '# Release Readiness Blockers',
    '',
    `- Generated at: ${summary.generatedAt}`,
    `- Run live checks: ${summary.runLive}`,
    expectedTotalsLine,
    ''
  ].join('\n')
  assert(markdown.startsWith(expectedPreamble), 'blockers.md preamble content mismatch')
}

function markdownSection(markdown, heading) {
  const marker = `## ${heading}\n\n`
  const markerIndex = markdown.indexOf(marker)
  if (markerIndex === -1) {
    return null
  }
  assert(occurrences(markdown, marker) === 1, `blockers.md duplicate ${heading} section`)
  const bodyStart = markerIndex + marker.length
  const bodyEnd = markdown.indexOf('\n## ', bodyStart)
  return markdown.slice(bodyStart, bodyEnd === -1 ? markdown.length : bodyEnd)
}

function assertBlockerReportTopLevelSections(markdown, expectedHeadings) {
  const actualHeadings = [...markdown.matchAll(/^## (.+)$/gm)].map((match) => match[1])
  assert(
    actualHeadings.length === expectedHeadings.length &&
      expectedHeadings.every((heading, index) => actualHeadings[index] === heading),
    `blockers.md top-level section mismatch: expected ${expectedHeadings.join(',')}; got ${actualHeadings.join(',')}`
  )
}

function positiveIntegerOrDefault(raw, fallback) {
  return /^[1-9][0-9]*$/.test(String(raw || '')) ? Number(raw) : fallback
}

function tailLines(lines, count) {
  if (count <= 0) {
    return []
  }
  return lines.slice(Math.max(0, lines.length - count))
}

function logEvidencePreview(logFile) {
  if (!fs.existsSync(logFile) || fs.statSync(logFile).size === 0) {
    return ''
  }

  const maxLines = positiveIntegerOrDefault(process.env.MAX_BLOCKER_LOG_LINES, 12)
  const maxChars = positiveIntegerOrDefault(process.env.MAX_EVIDENCE_PREVIEW_CHARS, 6000)
  const text = fs.readFileSync(logFile, 'utf8')
  const lines = text.endsWith('\n') ? text.slice(0, -1).split('\n') : text.split('\n')
  const actionablePattern = /(\[(warn|error)\]|Error:|failed|not release-ready|Curl output|Body preview|Route .*indexer)/
  const actionableLines = tailLines(lines.filter((line) => actionablePattern.test(line)), maxLines)
  const sourceLines = actionableLines.length > 0 ? actionableLines : tailLines(lines, maxLines)
  let preview = sourceLines.join('\n')

  if (maxChars > 0 && preview.length > maxChars) {
    let cappedPreview = preview.slice(-maxChars)
    if (cappedPreview.includes('\n')) {
      cappedPreview = cappedPreview.slice(cappedPreview.indexOf('\n') + 1)
      if (!cappedPreview) {
        cappedPreview = preview.slice(-maxChars)
      }
      preview = `${cappedPreview}\n[excerpt capped at ${maxChars} characters; see full log]`
    } else {
      preview = `[line capped to final ${maxChars} characters; see full log]\n${cappedPreview}\n[excerpt capped at ${maxChars} characters; see full log]`
    }
  }
  return preview
}

const expected = parseExpected(expectedFile)
const expectedBySlug = new Map(expected.map((row) => [row.slug, row]))
assert(expectedBySlug.size === expected.length, 'release output validator expected slugs must be unique')

const summary = readJson(summaryFile, 'summary.json')
const actions = readJson(actionsFile, 'actions.json')
const blockers = fs.readFileSync(blockersFile, 'utf8')

const totals = expected.reduce(
  (acc, row) => {
    acc[row.status] += 1
    return acc
  },
  {passed: 0, failed: 0, skipped: 0}
)
const expectedStatus = totals.failed > 0
  ? 'failed'
  : totals.skipped > 0 || summary.runLive !== true
    ? 'incomplete'
    : 'passed'

const summaryKeys = ['schemaVersion', 'generatedAt', 'runLive', 'status', 'totals', 'checks']
const actionsKeys = ['schemaVersion', 'generatedAt', 'runLive', 'status', 'totals', 'blockers']
const totalsKeys = ['passed', 'failed', 'skipped', 'total']
const summaryCheckKeys = ['name', 'slug', 'status', 'exitCode', 'logFile', 'recommendedAction', 'requiresExternalAction', 'unblockCategory', 'externalPrerequisite', 'verificationCommand']
const actionBlockerKeys = ['name', 'slug', 'exitCode', 'logFile', 'recommendedAction', 'requiresExternalAction', 'unblockCategory', 'externalPrerequisite', 'verificationCommand', 'evidencePreview']

assertObjectKeys(summary, summaryKeys, 'summary.json')
assertObjectKeys(actions, actionsKeys, 'actions.json')
assertObjectKeys(summary.totals, totalsKeys, 'summary.json totals')
assertObjectKeys(actions.totals, totalsKeys, 'actions.json totals')
for (const key of totalsKeys) {
  assertNonNegativeInteger(summary.totals[key], `summary.json totals.${key}`)
  assertNonNegativeInteger(actions.totals[key], `actions.json totals.${key}`)
}
assertSchemaVersion(summary.schemaVersion, 'summary.json schemaVersion', 'summary.json schemaVersion mismatch')
assertSchemaVersion(actions.schemaVersion, 'actions.json schemaVersion', 'actions.json schemaVersion mismatch')
const summaryGeneratedAtMs = assertUtcTimestamp(summary.generatedAt, 'summary.json generatedAt')
const actionsGeneratedAtMs = assertUtcTimestamp(actions.generatedAt, 'actions.json generatedAt')
assertBoolean(summary.runLive, 'summary.json runLive', 'summary.json runLive must be boolean')
assertBoolean(actions.runLive, 'actions.json runLive', 'actions.json runLive must be boolean')
assert(summary.generatedAt === actions.generatedAt, 'actions.json generatedAt must match summary.json')
assert(blockers.startsWith('# Release Readiness Blockers\n\n'), 'blockers.md heading mismatch')
const generatedAtMatches = [...blockers.matchAll(/^- Generated at: (.+)$/gm)]
assert(generatedAtMatches.length === 1, 'blockers.md generatedAt line count mismatch')
const blockersGeneratedAtMs = assertUtcTimestamp(generatedAtMatches[0][1], 'blockers.md generatedAt')
assert(generatedAtMatches[0][1] === summary.generatedAt, 'blockers.md generatedAt must match summary.json')
assertNotFutureTimestamp(summaryGeneratedAtMs, 'summary.json generatedAt')
assertNotFutureTimestamp(actionsGeneratedAtMs, 'actions.json generatedAt')
assertNotFutureTimestamp(blockersGeneratedAtMs, 'blockers.md generatedAt')
const expectedRunLiveLine = `- Run live checks: ${summary.runLive}`
assert(occurrences(blockers, expectedRunLiveLine) === 1, 'blockers.md runLive mismatch')
assertOverallStatus(summary.status, 'summary.json status')
assertOverallStatus(actions.status, 'actions.json status')
assert(summary.status === expectedStatus, 'summary.json status mismatch')
assert(actions.status === expectedStatus, 'actions.json status mismatch')
assert(actions.runLive === summary.runLive, 'actions.json runLive must match summary.json')

assert(summary.totals.passed === totals.passed, 'summary.json passed total mismatch')
assert(summary.totals.failed === totals.failed, 'summary.json failed total mismatch')
assert(summary.totals.skipped === totals.skipped, 'summary.json skipped total mismatch')
assert(summary.totals.total === expected.length, 'summary.json total mismatch')
assert(actions.totals.passed === totals.passed, 'actions.json passed total mismatch')
assert(actions.totals.failed === totals.failed, 'actions.json failed total mismatch')
assert(actions.totals.skipped === totals.skipped, 'actions.json skipped total mismatch')
assert(actions.totals.total === expected.length, 'actions.json total mismatch')
const expectedTotalsLine = `- Totals: ${totals.passed} passed, ${totals.failed} failed, ${totals.skipped} skipped, ${expected.length} total`
assert(occurrences(blockers, expectedTotalsLine) === 1, 'blockers.md totals mismatch')
assertBlockerReportPreamble(blockers, summary, expectedTotalsLine)

assert(Array.isArray(summary.checks), 'summary.json checks must be an array')
assert(summary.checks.length === expected.length, 'summary.json check count mismatch')
summary.checks.forEach((check, index) => {
  const row = expected[index]
  assert(row, `summary.json unexpected check at index ${index}`)
  assertObjectKeys(check, summaryCheckKeys, `summary.json check keys for ${row.slug}`)
  assertString(check.name, `summary name for ${row.slug}`)
  assertString(check.slug, `summary slug at index ${index}`)
  assertCheckStatus(check.status, `summary status for ${row.slug}`)
  assert(check.name === row.name, `summary name mismatch for ${row.slug}`)
  assert(check.slug === row.slug, `summary slug mismatch at index ${index}`)
  assert(check.status === row.status, `summary status mismatch for ${row.slug}`)
  if (row.status === 'skipped') {
    assert(check.exitCode === null, `summary skipped exitCode mismatch for ${row.slug}`)
    assert(check.logFile === null, `summary skipped logFile mismatch for ${row.slug}`)
  } else {
    assertSummaryExitCodeForStatus(check.exitCode, row.status, `summary exitCode for ${row.slug}`)
    assert(check.exitCode === Number(row.exitCode), `summary exitCode mismatch for ${row.slug}`)
    assertString(check.logFile, `summary logFile for ${row.slug}`)
    assert(check.logFile === row.logFile, `summary logFile mismatch for ${row.slug}`)
    assertLogFile(row)
  }

  if (row.status === 'failed') {
    assertString(check.recommendedAction, `summary recommendedAction for ${row.slug}`)
    assertString(check.unblockCategory, `summary unblockCategory for ${row.slug}`)
    assertString(check.externalPrerequisite, `summary externalPrerequisite for ${row.slug}`)
    assertString(check.verificationCommand, `summary verificationCommand for ${row.slug}`)
    assertBoolean(check.requiresExternalAction, `summary requiresExternalAction for ${row.slug}`)
    assert(check.recommendedAction === row.recommendedAction, `summary recommendedAction mismatch for ${row.slug}`)
    assert(check.requiresExternalAction === expectedExternalAction(row), `summary requiresExternalAction mismatch for ${row.slug}`)
    assert(check.unblockCategory === row.unblockCategory, `summary unblockCategory mismatch for ${row.slug}`)
    assert(check.externalPrerequisite === row.externalPrerequisite, `summary externalPrerequisite mismatch for ${row.slug}`)
    assert(check.verificationCommand === row.verificationCommand, `summary verificationCommand mismatch for ${row.slug}`)
  } else {
    assertNull(check.recommendedAction, `summary non-failed recommendedAction for ${row.slug}`)
    assertNull(check.requiresExternalAction, `summary non-failed requiresExternalAction for ${row.slug}`)
    assertNull(check.unblockCategory, `summary non-failed unblockCategory for ${row.slug}`)
    assertNull(check.externalPrerequisite, `summary non-failed externalPrerequisite for ${row.slug}`)
    assertNull(check.verificationCommand, `summary non-failed verificationCommand for ${row.slug}`)
  }
})

assert(Array.isArray(actions.blockers), 'actions.json blockers must be an array')
const failedRows = expected.filter((row) => row.status === 'failed')
const skippedRows = expected.filter((row) => row.status === 'skipped')
const expectedBlockerReportHeadings = []
if (failedRows.length > 0) expectedBlockerReportHeadings.push('Failed Checks')
if (skippedRows.length > 0) expectedBlockerReportHeadings.push('Skipped Checks')
assert(actions.blockers.length === failedRows.length, 'actions.json blocker count mismatch')
actions.blockers.forEach((blocker, index) => {
  const expectedRow = failedRows[index]
  assert(expectedRow, `actions.json unexpected blocker at index ${index}`)
  assertObjectKeys(blocker, actionBlockerKeys, `actions blocker keys for ${expectedRow.slug}`)
  assertString(blocker.slug, `actions slug at index ${index}`)
  assert(
    blocker.slug === expectedRow.slug,
    `actions blocker order mismatch at index ${index}: expected ${expectedRow.slug}, got ${blocker.slug}`
  )
  const row = expectedBySlug.get(blocker.slug)
  assert(row, `actions.json unexpected blocker ${blocker.slug}`)
  assert(row.status === 'failed', `actions.json non-failed blocker ${blocker.slug}`)
  assertString(blocker.name, `actions name for ${row.slug}`)
  assert(blocker.name === row.name, `actions name mismatch for ${row.slug}`)
  assertFailedBlockerExitCode(blocker.exitCode, `actions exitCode for ${row.slug}`)
  assert(blocker.exitCode === Number(row.exitCode), `actions exitCode mismatch for ${row.slug}`)
  assertString(blocker.logFile, `actions logFile for ${row.slug}`)
  assert(blocker.logFile === row.logFile, `actions logFile mismatch for ${row.slug}`)
  assertString(blocker.recommendedAction, `actions recommendedAction for ${row.slug}`)
  assertString(blocker.unblockCategory, `actions unblockCategory for ${row.slug}`)
  assertString(blocker.externalPrerequisite, `actions externalPrerequisite for ${row.slug}`)
  assertString(blocker.verificationCommand, `actions verificationCommand for ${row.slug}`)
  assertBoolean(blocker.requiresExternalAction, `actions requiresExternalAction for ${row.slug}`)
  assert(blocker.recommendedAction === row.recommendedAction, `actions recommendedAction mismatch for ${row.slug}`)
  assert(blocker.requiresExternalAction === expectedExternalAction(row), `actions requiresExternalAction mismatch for ${row.slug}`)
  assert(blocker.unblockCategory === row.unblockCategory, `actions unblockCategory mismatch for ${row.slug}`)
  assert(blocker.externalPrerequisite === row.externalPrerequisite, `actions externalPrerequisite mismatch for ${row.slug}`)
  assert(blocker.verificationCommand === row.verificationCommand, `actions verificationCommand mismatch for ${row.slug}`)
  assert(typeof blocker.evidencePreview === 'string', `actions evidencePreview must be a string for ${row.slug}`)
  assert(blocker.evidencePreview === logEvidencePreview(row.logFile), `actions evidencePreview mismatch for ${row.slug}`)
})

if (failedRows.length === 0) {
  const expectedNonFailureMessage = expectedStatus === 'incomplete'
    ? 'Release readiness is incomplete because required live checks were skipped; this run is not production-ready evidence.'
    : 'No blocking release-readiness failures recorded.'
  assert(blockers.includes(expectedNonFailureMessage), 'blockers.md missing expected non-failure status message')
  if (expectedStatus === 'incomplete') {
    assert(!blockers.includes('No blocking release-readiness failures recorded.'), 'blockers.md incomplete report must not claim no blockers')
  }
  assert(!blockers.includes('## Failed Checks'), 'blockers.md unexpected failed-checks section')
  assert(
    [...blockers.matchAll(/^### .+\n\n- Slug: `([^`]+)`/gm)].length === 0,
    'blockers.md unexpected failed section when no failures'
  )
  assertBlockerReportNonFailureSection(blockers, expectedTotalsLine, expectedStatus)
} else {
  assert(blockers.includes('## Failed Checks'), 'blockers.md missing failed-checks section')
  const failedSection = markdownSection(blockers, 'Failed Checks')
  assert(failedSection !== null, 'blockers.md missing failed-checks section')
  assert(
    !blockers.includes('No blocking release-readiness failures recorded.'),
    'blockers.md unexpected no-blockers success message'
  )
  for (const row of failedRows) {
    blockerSection(blockers, row)
  }
  const blockerSectionSlugs = [...blockers.matchAll(/^### .+\n\n- Slug: `([^`]+)`/gm)].map((match) => match[1])
  assert(blockerSectionSlugs.length === failedRows.length, 'blockers.md failed section count mismatch')
  failedRows.forEach((row, index) => {
    assert(
      blockerSectionSlugs[index] === row.slug,
      `blockers.md section order mismatch at index ${index}: expected ${row.slug}, got ${blockerSectionSlugs[index]}`
    )
  })
  const failedHeadings = [...failedSection.matchAll(/^### (.+)$/gm)].map((match) => match[1])
  assert(failedHeadings.length === failedRows.length, 'blockers.md failed heading count mismatch')
  failedRows.forEach((row, index) => {
    assert(
      failedHeadings[index] === row.name,
      `blockers.md failed heading order mismatch at index ${index}: expected ${row.name}, got ${failedHeadings[index] || '<missing>'}`
    )
  })
  for (const row of failedRows) {
    const section = blockerSection(blockers, row)
    assert(occurrences(section, `### ${row.name}\n\n`) === 1, `blockers.md heading mismatch for ${row.slug}`)
    assert(
      occurrences(section, `- Exit code: \`${row.exitCode}\``) === 1,
      `blockers.md exit code mismatch for ${row.slug}`
    )
    assert(
      occurrences(section, `- Log: \`${row.logFile}\``) === 1,
      `blockers.md log path mismatch for ${row.slug}`
    )
    assert(
      occurrences(section, `- Recommended action: ${row.recommendedAction}\n`) === 1,
      `blockers.md recommended action mismatch for ${row.slug}`
    )
    assert(
      occurrences(section, `- Requires external action: \`${row.requiresExternalAction}\``) === 1,
      `blockers.md requiresExternalAction mismatch for ${row.slug}`
    )
    assert(
      occurrences(section, `- Unblock category: \`${row.unblockCategory}\``) === 1,
      `blockers.md unblockCategory mismatch for ${row.slug}`
    )
    assert(
      occurrences(section, `- External prerequisite: ${row.externalPrerequisite}\n`) === 1,
      `blockers.md externalPrerequisite mismatch for ${row.slug}`
    )
    assert(
      occurrences(section, `- Verification command: \`${row.verificationCommand}\``) === 1,
      `blockers.md verificationCommand mismatch for ${row.slug}`
    )
    const expectedPreview = logEvidencePreview(row.logFile)
    const previewBlockCount = occurrences(section, 'Evidence preview:\n\n```text\n')
    if (expectedPreview) {
      assert(
        previewBlockCount === 1,
        `blockers.md evidence preview block count mismatch for ${row.slug}`
      )
      assert(
        section.includes(`Evidence preview:\n\n\`\`\`text\n${expectedPreview}\n\`\`\`\n`),
        `blockers.md evidence preview mismatch for ${row.slug}`
      )
    } else {
      assert(
        previewBlockCount === 0,
        `blockers.md evidence preview block count mismatch for ${row.slug}`
      )
    }
    assertBlockerSectionContent(section, row)
  }
}

const skippedSection = markdownSection(blockers, 'Skipped Checks')
if (skippedRows.length === 0) {
  assert(skippedSection === null, 'blockers.md unexpected skipped-checks section')
} else {
  assert(skippedSection !== null, 'blockers.md missing skipped-checks section')
  const skippedLines = skippedSection.trimEnd().split('\n').filter((line) => line !== '')
  assert(skippedLines.length === skippedRows.length, 'blockers.md skipped section count mismatch')
  skippedRows.forEach((row, index) => {
    const expectedLine = `- \`${row.slug}\` (${row.name})`
    assert(
      skippedLines[index] === expectedLine,
      `blockers.md skipped section order mismatch at index ${index}: expected ${expectedLine}, got ${skippedLines[index] || '<missing>'}`
    )
  })
  assertSkippedSectionContent(skippedSection, skippedRows)
}

assertBlockerReportTopLevelSections(blockers, expectedBlockerReportHeadings)
NODE
  then
    rm -f "$expected_file"
    return 1
  fi

  rm -f "$expected_file"
  log "Validated release-readiness output contracts"
}

export_unblock_bundle() {
  local export_script="$ROOT_DIR/scripts/export-release-unblock-bundle.sh"
  local verify_script="$ROOT_DIR/scripts/verify-release-unblock-bundle.sh"

  if [[ ! -x "$export_script" ]]; then
    echo "[release-readiness][error] Release unblock bundle exporter missing or not executable: $export_script" >&2
    return 1
  fi
  if [[ ! -x "$verify_script" ]]; then
    echo "[release-readiness][error] Release unblock bundle verifier missing or not executable: $verify_script" >&2
    return 1
  fi

  if ! RELEASE_UNBLOCK_ROOT="$ROOT_DIR" "$export_script" --report-dir "$REPORT_DIR" --output "$UNBLOCK_BUNDLE_DIR"; then
    echo "[release-readiness][error] Release unblock bundle export failed" >&2
    return 1
  fi
  if ! RELEASE_UNBLOCK_ROOT="$ROOT_DIR" "$verify_script" --bundle "$UNBLOCK_BUNDLE_DIR"; then
    echo "[release-readiness][error] Release unblock bundle verification failed" >&2
    return 1
  fi
  log "Wrote and verified release unblock bundle at $UNBLOCK_BUNDLE_DIR"
}

preview_log() {
  local log_file="$1"
  [[ -s "$log_file" ]] || return 0

  sed -n "1,${MAX_LOG_PREVIEW_LINES}p" "$log_file" >&2
  local line_count
  line_count="$(wc -l < "$log_file" | tr -d '[:space:]')"
  if ((line_count > MAX_LOG_PREVIEW_LINES)); then
    echo "[release-readiness][warn] Output truncated at $MAX_LOG_PREVIEW_LINES lines. Full log: $log_file" >&2
  fi
}

positive_integer_or_default() {
  local raw="$1"
  local fallback="$2"
  if [[ "$raw" =~ ^[1-9][0-9]*$ ]]; then
    printf '%s' "$raw"
  else
    printf '%s' "$fallback"
  fi
}

run_check_attempts() {
  local attempts="$1"
  local retry_delay="$2"
  local name="$3"
  local slug="$4"
  shift 4
  local log_file="$REPORT_DIR/$slug.log"

  mkdir -p "$REPORT_DIR"
  rm -f "$log_file"

  log "Running $name"
  local attempt status=0
  for ((attempt = 1; attempt <= attempts; attempt += 1)); do
    if ((attempts > 1)); then
      printf '[release-readiness] %s attempt %d/%d\n' "$name" "$attempt" "$attempts" >> "$log_file"
    fi

    set +e
    (set -euo pipefail; "$@") >>"$log_file" 2>&1
    status=$?
    set -e

    if [[ "$status" -eq 0 ]]; then
      log "$name passed"
      record_check_result "$name" "$slug" "passed" 0 "$log_file"
      return
    fi

    if ((attempt < attempts)); then
      echo "[release-readiness][warn] $name attempt $attempt/$attempts failed with exit code $status; retrying. Log: $log_file" >&2
      printf '[release-readiness] %s attempt %d/%d failed with exit code %d; retrying.\n' "$name" "$attempt" "$attempts" "$status" >> "$log_file"
      if ((retry_delay > 0)); then
        sleep "$retry_delay"
      fi
    fi
  done

  echo "[release-readiness][warn] $name failed with exit code $status. Log: $log_file" >&2
  preview_log "$log_file"
  failures+=("$name (exit $status, log: $log_file)")
  record_check_result "$name" "$slug" "failed" "$status" "$log_file"
}

run_check() {
  run_check_attempts 1 0 "$@"
}

run_check_with_network_retries() {
  local attempts delay
  attempts="$(positive_integer_or_default "${RELEASE_READINESS_NETWORK_ATTEMPTS:-3}" 3)"
  delay="$(positive_integer_or_default "${RELEASE_READINESS_NETWORK_RETRY_DELAY_SECONDS:-2}" 2)"
  run_check_attempts "$attempts" "$delay" "$@"
}

skip_check() {
  local name="$1"
  local slug="$2"
  skipped+=("$name")
  log "Skipping $name"
  record_check_result "$name" "$slug" "skipped"
}

run_plan_readiness() {
  PLAN_AUDIT_ROOT="$ROOT_DIR" \
    PLAN_AUDIT_PARENT="$PARENT_DIR" \
    PLAN_AUDIT_FAIL_FAST=false \
    "$ROOT_DIR/scripts/audit-plan-readiness.sh"
}

run_github_governance() {
  GH_BIN="$RELEASE_GH_BIN" "$ROOT_DIR/scripts/audit-github-governance.sh"
}

run_release_pr_readiness() {
  RELEASE_PR_READINESS_ROOT="$ROOT_DIR" \
    RELEASE_PR_READINESS_CONFIG="$ROOT_DIR/config/release-readiness-prs.tsv" \
    GH_BIN="$RELEASE_GH_BIN" \
    "$ROOT_DIR/scripts/audit-release-pr-readiness.sh" \
      --write-report "$REPORT_DIR/release-pr-readiness-report.json"
}

run_source_publication_readiness() {
  local status=0
  local audit_status=0
  if [[ -f "$SOURCE_PUBLICATION_PREFLIGHT_LOG" ]]; then
    echo "[source-publication-readiness] Preflight evidence:"
    cat "$SOURCE_PUBLICATION_PREFLIGHT_LOG"
  fi
  "$ROOT_DIR/scripts/test-source-publication-readiness-audit.sh" || status=$?
  "$SOURCE_PUBLICATION_RUNNER" \
    --check-remote \
    --phase postflight \
    --preflight-report "$SOURCE_PUBLICATION_PREFLIGHT_REPORT" \
    --root "$ROOT_DIR" \
    --parent "$PARENT_DIR" \
    --write-report "$REPORT_DIR/source-publication-readiness-report.json" || audit_status=$?
  if ((SOURCE_PUBLICATION_PREFLIGHT_STATUS != 0)); then
    return "$SOURCE_PUBLICATION_PREFLIGHT_STATUS"
  fi
  if ((status != 0)); then
    return "$status"
  fi
  return "$audit_status"
}

run_source_publication_preflight() {
  "$SOURCE_PUBLICATION_RUNNER" \
    --check-remote \
    --phase preflight \
    --root "$ROOT_DIR" \
    --parent "$PARENT_DIR" \
    --write-report "$SOURCE_PUBLICATION_PREFLIGHT_REPORT"
}

clear_release_owned_preflight_outputs() {
  rm -rf "$REPORT_DIR"
  rm -rf "$ROOT_DIR/fearless-Android/build/reports/public-dependency-upstream-delta"
  rm -f \
    "$ROOT_DIR/fearless-Android/build/reports/xcm-production-evidence-template.json" \
    "$ROOT_DIR/fearless-Android/build/reports/xcm-registry-gap-report.json" \
    "$ROOT_DIR/fearless-Android/build/reports/xcm-effective-registry-report.json" \
    "$ROOT_DIR/fearless-iOS/build/reports/shared-features-delta-report.json" \
    "$ROOT_DIR/services/passkey-backup-challenge-service/build/reports/production-deployment-evidence-template.json" \
    "$ROOT_DIR/fearless-wallet-web/build/reports/bitcoin-broadcast-evidence-template.json" \
    "$PARENT_DIR/ton-indexer/build/reports/production-deployment-evidence-template.json" \
    "$PARENT_DIR/solswap-indexer/build/reports/production-deployment-evidence-template.json" \
    "$PARENT_DIR/polkaswap-indexer/build/reports/production-deployment-evidence-template.json"
}

run_private_overlays() {
  PRIVATE_OVERLAY_AUDIT_ROOT="$ROOT_DIR" \
    PRIVATE_OVERLAY_AUDIT_REPORT_DIR="$ROOT_DIR/build/reports/private-overlays" \
    MAX_REPORT_LINES=10 \
    "$ROOT_DIR/scripts/audit-private-overlay-readiness.sh"
}

run_android_public_dependency_provenance() {
  cd "$ROOT_DIR/fearless-Android"
  bash ./scripts/test-fearless-utils-derived-tree.sh
  FEARLESS_UTILS_PATH="$ROOT_DIR/fearless-utils-Android" \
    FEARLESS_UTILS_COMMIT=7500809f33243ee47ecb2ec8563fc284ac4de0d6 \
    FEARLESS_UTILS_REPOSITORY=soramitsu/fearless-utils-Android \
    FEARLESS_UTILS_LIBRARY_ONLY=true \
    ./scripts/ensure-fearless-utils.sh
  bash ./scripts/test-public-dependency-upstream-delta-export.sh
  bash ./scripts/export-public-dependency-upstream-delta.sh --output build/reports/public-dependency-upstream-delta
  PUBLIC_ARTIFACT_PROVENANCE_DOC=docs/binary-provenance.md \
    ./scripts/audit-public-artifacts.sh --strict-provenance
}

run_ios_shared_features_delta() {
  cd "$ROOT_DIR/fearless-iOS"
  bash scripts/deps/test-shared-features-delta-report.sh
  bash scripts/deps/audit-shared-features-delta-report.sh "$PWD" --write-report build/reports/shared-features-delta-report.json
}

run_passkey_challenge_service() {
  PASSKEY_CHALLENGE_SERVICE_AUDIT_ROOT="$ROOT_DIR" \
    PASSKEY_CHALLENGE_SERVICE_DIR="$ROOT_DIR/services/passkey-backup-challenge-service" \
    PASSKEY_CHALLENGE_SERVICE_AUDIT_SKIP_COMMANDS=0 \
    "$ROOT_DIR/scripts/audit-passkey-challenge-service.sh"
}

run_passkey_deployment_evidence() {
  cd "$ROOT_DIR/services/passkey-backup-challenge-service"
  local template_report="build/reports/production-deployment-evidence-template.json"
  local release_template_report="$REPORT_DIR/passkey-deployment-evidence-template.json"
  require_secret_value_evidence_sentinels \
    "scripts/audit-deployment-evidence.sh" \
    'assertNoSecretLikeValues\(data\)' \
    "scripts/test-deployment-evidence-audit.sh" \
    'secret-like deployment evidence value' \
    "passkey deployment evidence"
  "$ROOT_DIR/scripts/test-passkey-android-origin-parity-audit.sh"
  rm -f "$template_report" "$release_template_report"
  PASSKEY_DEPLOYMENT_EVIDENCE_ROOT="$ROOT_DIR/services/passkey-backup-challenge-service" \
    "$NPM_BIN" run generate:deployment-evidence-template -- --output "$template_report" >/dev/null
  if [[ ! -f "$template_report" ]]; then
    echo "[passkey-deployment-evidence][error] expected deployment evidence template was not written: $template_report" >&2
    return 1
  fi
  mkdir -p "$REPORT_DIR"
  cp "$template_report" "$release_template_report"
  if [[ "$RUN_LIVE" == true ]]; then
    PASSKEY_DEPLOYMENT_EVIDENCE_ROOT="$ROOT_DIR/services/passkey-backup-challenge-service" \
      "$NPM_BIN" run audit:deployment-evidence -- --require-ready
    PASSKEY_ANDROID_ASSOCIATION_FILE="$ROOT_DIR/fearless-site-web/src/public/.well-known/assetlinks.json" \
      PASSKEY_DEPLOYMENT_EVIDENCE_FILE="$ROOT_DIR/services/passkey-backup-challenge-service/scripts/production-deployment-evidence.json" \
      PASSKEY_BACKUP_PRODUCTION_CONFIG_FILE="$ROOT_DIR/config/passkey-backup-production.json" \
      "$ROOT_DIR/scripts/audit-passkey-android-origin-parity.sh" --require-ready
  else
    PASSKEY_DEPLOYMENT_EVIDENCE_ROOT="$ROOT_DIR/services/passkey-backup-challenge-service" \
      "$NPM_BIN" run audit:deployment-evidence
    PASSKEY_ANDROID_ASSOCIATION_FILE="$ROOT_DIR/fearless-site-web/src/public/.well-known/assetlinks.json" \
      PASSKEY_DEPLOYMENT_EVIDENCE_FILE="$ROOT_DIR/services/passkey-backup-challenge-service/scripts/production-deployment-evidence.json" \
      PASSKEY_BACKUP_PRODUCTION_CONFIG_FILE="$ROOT_DIR/config/passkey-backup-production.json" \
      "$ROOT_DIR/scripts/audit-passkey-android-origin-parity.sh"
  fi
}

run_passkey_prerequisites() {
  local status=0
  if [[ "$RUN_LIVE" == true ]]; then
    PASSKEY_AUDIT_ROOT="$ROOT_DIR" PASSKEY_BACKUP_LIVE_HEALTH=1 \
      "$ROOT_DIR/scripts/audit-passkey-backup-prerequisites.sh" || status=$?
    "$NODE_BIN" "$ROOT_DIR/fearless-site-web/scripts/verify-app-associations.mjs" \
      --root "$ROOT_DIR/fearless-site-web" \
      --live-base-url https://fearlesswallet.io || {
      local site_status=$?
      if [[ "$status" -eq 0 ]]; then
        status="$site_status"
      fi
    }
  else
    PASSKEY_AUDIT_ROOT="$ROOT_DIR" PASSKEY_BACKUP_LIVE_HEALTH=0 \
      "$ROOT_DIR/scripts/audit-passkey-backup-prerequisites.sh" || status=$?
  fi
  return "$status"
}

run_passkey_production_smoke() {
  cd "$ROOT_DIR/services/passkey-backup-challenge-service"
  PASSKEY_BACKUP_BASE_URL="https://backup.fearlesswallet.io" \
    PASSKEY_BACKUP_SMOKE_GRANT_HELPER="/run/secrets/passkey-smoke-grant-helper" \
    PASSKEY_BACKUP_SMOKE_TIMEOUT_MS=10000 \
    "$NPM_BIN" run smoke:production
}

run_iroha_prerequisites() {
  local template_report="$ROOT_DIR/build/reports/nexus-production-evidence-template.json"
  local release_template_report="$REPORT_DIR/nexus-production-evidence-template.json"
  require_secret_value_evidence_sentinels \
    "$ROOT_DIR/scripts/audit-nexus-production-evidence.sh" \
    'assertNoSecretLikeValues\(manifest\)' \
    "$ROOT_DIR/scripts/test-nexus-production-evidence-audit.sh" \
    'secret-like Nexus evidence value' \
    "Nexus production evidence"
  rm -f "$template_report" "$release_template_report"
  NEXUS_EVIDENCE_ROOT="$ROOT_DIR" \
    "$ROOT_DIR/scripts/generate-nexus-production-evidence-template.sh" --output "$template_report" >/dev/null
  if [[ ! -f "$template_report" ]]; then
    echo "[iroha-release-readiness][error] expected Nexus production evidence template was not written: $template_report" >&2
    return 1
  fi
  mkdir -p "$REPORT_DIR"
  cp "$template_report" "$release_template_report"
  if [[ "$RUN_LIVE" == true ]]; then
    IROHA_READINESS_ROOT="$ROOT_DIR" \
      IROHA_READINESS_PARENT="$PARENT_DIR" \
      IROHA_RELEASE_CONFIG_FILE="$ROOT_DIR/config/iroha-release-readiness.env" \
      NEXUS_PRODUCTION_EVIDENCE_FILE="$ROOT_DIR/config/nexus-production-evidence.json" \
      NEXUS_PRODUCTION_EVIDENCE_AUDIT="$ROOT_DIR/scripts/audit-nexus-production-evidence.sh" \
      NEXUS_PRODUCTION_EVIDENCE_TEST="$ROOT_DIR/scripts/test-nexus-production-evidence-audit.sh" \
      NEXUS_EVIDENCE_ROOT="$ROOT_DIR" \
      IROHA_NEXUS_REQUIRE_PRODUCTION_EVIDENCE=1 \
      IROHA_NEXUS_LIVE_HEALTH=1 \
      "$ROOT_DIR/scripts/audit-iroha-release-readiness.sh"
  else
    IROHA_READINESS_ROOT="$ROOT_DIR" \
      IROHA_READINESS_PARENT="$PARENT_DIR" \
      IROHA_RELEASE_CONFIG_FILE="$ROOT_DIR/config/iroha-release-readiness.env" \
      NEXUS_PRODUCTION_EVIDENCE_FILE="$ROOT_DIR/config/nexus-production-evidence.json" \
      NEXUS_PRODUCTION_EVIDENCE_AUDIT="$ROOT_DIR/scripts/audit-nexus-production-evidence.sh" \
      NEXUS_PRODUCTION_EVIDENCE_TEST="$ROOT_DIR/scripts/test-nexus-production-evidence-audit.sh" \
      NEXUS_EVIDENCE_ROOT="$ROOT_DIR" \
      IROHA_NEXUS_REQUIRE_PRODUCTION_EVIDENCE=0 \
      IROHA_NEXUS_LIVE_HEALTH=0 \
      "$ROOT_DIR/scripts/audit-iroha-release-readiness.sh"
  fi
}

run_iroha_wallet_coverage() {
  IROHA_WALLET_COVERAGE_ROOT="$ROOT_DIR" \
    IROHA_SEND_AGGREGATE_ROOT="$ROOT_DIR" \
    "$ROOT_DIR/scripts/audit-iroha-wallet-coverage.sh"
}

run_android_xcm_production_evidence() {
  cd "$ROOT_DIR/fearless-Android"
  local status=0
  local template_status=0
  local registry_status=0
  local effective_registry_test_status=0
  local effective_registry_status=0
  local evidence_status=0
  local template_report="build/reports/xcm-production-evidence-template.json"
  local release_template_report="$REPORT_DIR/android-xcm-production-evidence-template.json"
  local registry_gap_report="build/reports/xcm-registry-gap-report.json"
  local release_gap_report="$REPORT_DIR/android-xcm-registry-gap-report.json"
  local effective_registry_report="build/reports/xcm-effective-registry-report.json"
  local release_effective_registry_report="$REPORT_DIR/android-xcm-effective-registry-report.json"
  local production_discovery_url="https://raw.githubusercontent.com/soramitsu/shared-features-utils/master/chains/v13/chains.json"
  local registry_args=(
    --require-executable
    --write-gap-report "$registry_gap_report"
    --require-route-file scripts/xcm-required-routes.tsv
    --require-gap-file scripts/xcm-discovery-only-routes.tsv
  )

  require_secret_value_evidence_sentinels \
    "scripts/audit-xcm-production-evidence.sh" \
    'secretLikeValueReason\(manifest\)' \
    "scripts/test-xcm-production-evidence-audit.sh" \
    'secret-like XCM production evidence value' \
    "Android XCM production evidence"

  rm -f \
    "$template_report" \
    "$release_template_report" \
    "$registry_gap_report" \
    "$release_gap_report" \
    "$effective_registry_report" \
    "$release_effective_registry_report"

  if [[ "$RUN_LIVE" == true ]]; then
    registry_args+=(--require-all-routes-executable)
  fi

  XCM_PRODUCTION_EVIDENCE_ROOT="$ROOT_DIR/fearless-Android" \
    bash scripts/generate-xcm-production-evidence-template.sh --output "$template_report" >/dev/null || template_status=$?
  if [[ -f "$template_report" ]]; then
    mkdir -p "$REPORT_DIR"
    cp "$template_report" "$release_template_report"
  else
    echo "[xcm-production-evidence][error] expected XCM production evidence template was not written: $template_report" >&2
    if ((template_status == 0)); then
      template_status=1
    fi
  fi

  XCM_REGISTRY_ROOT="$ROOT_DIR/fearless-Android" \
    bash scripts/audit-xcm-registry-metadata.sh "${registry_args[@]}" || registry_status=$?
  if [[ -f "$registry_gap_report" ]]; then
    mkdir -p "$REPORT_DIR"
    cp "$registry_gap_report" "$release_gap_report"
  else
    echo "[xcm-registry][error] expected XCM registry gap report was not written: $registry_gap_report" >&2
    if ((registry_status == 0)); then
      registry_status=1
    fi
  fi

  bash scripts/test-xcm-effective-registry-audit.sh || effective_registry_test_status=$?
  local effective_registry_args=(--write-report "$effective_registry_report")
  if [[ "$RUN_LIVE" == true ]]; then
    effective_registry_args+=(
      --discovery-url "$production_discovery_url"
      --require-all-approved
    )
  fi
  XCM_EFFECTIVE_REGISTRY_ROOT="$ROOT_DIR/fearless-Android" \
    bash scripts/audit-xcm-effective-registry.sh "${effective_registry_args[@]}" || effective_registry_status=$?
  if [[ -f "$effective_registry_report" ]]; then
    mkdir -p "$REPORT_DIR"
    cp "$effective_registry_report" "$release_effective_registry_report"
  else
    echo "[xcm-effective-registry][error] expected effective XCM registry report was not written: $effective_registry_report" >&2
    if ((effective_registry_status == 0)); then
      effective_registry_status=1
    fi
  fi

  if [[ "$RUN_LIVE" == true ]]; then
    XCM_PRODUCTION_EVIDENCE_ROOT="$ROOT_DIR/fearless-Android" \
      bash scripts/audit-xcm-production-evidence.sh --effective-registry-report "$effective_registry_report" --require-ready || evidence_status=$?
  else
    XCM_PRODUCTION_EVIDENCE_ROOT="$ROOT_DIR/fearless-Android" \
      bash scripts/audit-xcm-production-evidence.sh --effective-registry-report "$effective_registry_report" || evidence_status=$?
  fi

  if ((template_status != 0)); then
    status="$template_status"
  fi
  if ((registry_status != 0)); then
    status="$registry_status"
  fi
  if ((effective_registry_test_status != 0)); then
    status="$effective_registry_test_status"
  fi
  if ((effective_registry_status != 0)); then
    status="$effective_registry_status"
  fi
  if ((evidence_status != 0)); then
    status="$evidence_status"
  fi
  return "$status"
}

run_web_bitcoin_broadcast_evidence() {
  cd "$ROOT_DIR/fearless-wallet-web"
  local status=0
  local template_status=0
  local audit_status=0
  local template_report="build/reports/bitcoin-broadcast-evidence-template.json"
  local release_template_report="$REPORT_DIR/web-bitcoin-broadcast-evidence-template.json"

  require_secret_value_evidence_sentinels \
    "scripts/audit-bitcoin-broadcast-evidence.sh" \
    'secretLikeValueReason\(manifest\)' \
    "scripts/test-bitcoin-broadcast-evidence-audit.sh" \
    'secret-like Bitcoin broadcast evidence value' \
    "web Bitcoin broadcast evidence"

  rm -f "$template_report" "$release_template_report"
  bash scripts/generate-bitcoin-broadcast-evidence-template.sh --output "$template_report" >/dev/null || template_status=$?
  if [[ -f "$template_report" ]]; then
    mkdir -p "$REPORT_DIR"
    cp "$template_report" "$release_template_report"
  else
    echo "[bitcoin-broadcast-evidence][error] expected Bitcoin broadcast evidence template was not written: $template_report" >&2
    if ((template_status == 0)); then
      template_status=1
    fi
  fi

  if [[ "$RUN_LIVE" == true ]]; then
    bash scripts/audit-bitcoin-broadcast-evidence.sh --require-ready || audit_status=$?
  else
    bash scripts/audit-bitcoin-broadcast-evidence.sh || audit_status=$?
  fi

  if ((template_status != 0)); then
    status="$template_status"
  fi
  if ((audit_status != 0)); then
    status="$audit_status"
  fi
  return "$status"
}

run_ton_deployment_evidence() {
  cd "$PARENT_DIR/ton-indexer"
  local template_report="build/reports/production-deployment-evidence-template.json"
  local release_template_report="$REPORT_DIR/ti-deployment-evidence-template.json"
  require_secret_value_evidence_sentinels \
    "scripts/audit-deployment-evidence.sh" \
    'secretLikeValueReason\(manifest\)' \
    "scripts/test-deployment-evidence-audit.sh" \
    'secret-like deployment evidence value' \
    "TI deployment evidence"
  rm -f "$template_report" "$release_template_report"
  DEPLOYMENT_EVIDENCE_ROOT="$PARENT_DIR/ton-indexer" \
    "$NPM_BIN" run generate:deployment-evidence-template -- --output "$template_report" >/dev/null
  if [[ ! -f "$template_report" ]]; then
    echo "[ti-deployment-evidence][error] expected deployment evidence template was not written: $template_report" >&2
    return 1
  fi
  mkdir -p "$REPORT_DIR"
  cp "$template_report" "$release_template_report"
  if [[ "$RUN_LIVE" == true ]]; then
    DEPLOYMENT_EVIDENCE_ROOT="$PARENT_DIR/ton-indexer" \
      "$NPM_BIN" run audit:deployment-evidence -- --require-ready
  else
    DEPLOYMENT_EVIDENCE_ROOT="$PARENT_DIR/ton-indexer" \
      "$NPM_BIN" run audit:deployment-evidence
  fi
}

run_solswap_deployment_evidence() {
  cd "$PARENT_DIR/solswap-indexer"
  local template_report="build/reports/production-deployment-evidence-template.json"
  local release_template_report="$REPORT_DIR/si-deployment-evidence-template.json"
  require_secret_value_evidence_sentinels \
    "scripts/audit-deployment-evidence.sh" \
    'secretLikeValueReason\(manifest\)' \
    "scripts/test-deployment-evidence-audit.sh" \
    'secret-like deployment evidence value' \
    "SI deployment evidence"
  rm -f "$template_report" "$release_template_report"
  DEPLOYMENT_EVIDENCE_ROOT="$PARENT_DIR/solswap-indexer" \
    "$NPM_BIN" run generate:deployment-evidence-template -- --output "$template_report" >/dev/null
  if [[ ! -f "$template_report" ]]; then
    echo "[si-deployment-evidence][error] expected deployment evidence template was not written: $template_report" >&2
    return 1
  fi
  mkdir -p "$REPORT_DIR"
  cp "$template_report" "$release_template_report"
  if [[ "$RUN_LIVE" == true ]]; then
    DEPLOYMENT_EVIDENCE_ROOT="$PARENT_DIR/solswap-indexer" \
      "$NPM_BIN" run audit:deployment-evidence -- --require-ready
  else
    DEPLOYMENT_EVIDENCE_ROOT="$PARENT_DIR/solswap-indexer" \
      "$NPM_BIN" run audit:deployment-evidence
  fi
}

run_polkaswap_deployment_evidence() {
  cd "$PARENT_DIR/polkaswap-indexer"
  local template_report="build/reports/production-deployment-evidence-template.json"
  local release_template_report="$REPORT_DIR/pi-deployment-evidence-template.json"
  require_secret_value_evidence_sentinels \
    "scripts/audit-deployment-evidence.sh" \
    'secretLikeValueReason\(manifest\)' \
    "scripts/test-deployment-evidence-audit.sh" \
    'secret-like deployment evidence value' \
    "PI deployment evidence"
  rm -f "$template_report" "$release_template_report"
  DEPLOYMENT_EVIDENCE_ROOT="$PARENT_DIR/polkaswap-indexer" \
    "$YARN_BIN" generate:deployment-evidence-template --output "$template_report" >/dev/null
  if [[ ! -f "$template_report" ]]; then
    echo "[pi-deployment-evidence][error] expected deployment evidence template was not written: $template_report" >&2
    return 1
  fi
  mkdir -p "$REPORT_DIR"
  cp "$template_report" "$release_template_report"
  if [[ "$RUN_LIVE" == true ]]; then
    DEPLOYMENT_EVIDENCE_ROOT="$PARENT_DIR/polkaswap-indexer" \
      "$YARN_BIN" audit:deployment-evidence --require-ready
  else
    DEPLOYMENT_EVIDENCE_ROOT="$PARENT_DIR/polkaswap-indexer" \
      "$YARN_BIN" audit:deployment-evidence
  fi
}

run_ton_production_smoke() {
  cd "$PARENT_DIR/ton-indexer"
  TON_INDEXER_BASE_URL="https://ti.soramitsu.io" "$NPM_BIN" run smoke:production
}

run_solswap_production_smoke() {
  cd "$PARENT_DIR/solswap-indexer"
  SOLSWAP_INDEXER_BASE_URL="https://si.soramitsu.io" "$NPM_BIN" run smoke:production
}

run_polkaswap_production_smoke() {
  cd "$PARENT_DIR/polkaswap-indexer"
  POLKASWAP_INDEXER_BASE_URL="https://pi.soramitsu.io/graphql" "$YARN_BIN" smoke:production
}

if [[ "$RUN_LIVE" == true ]]; then
  clear_release_owned_preflight_outputs
  mkdir -p "$REPORT_DIR"
  rm -f "$SOURCE_PUBLICATION_PREFLIGHT_REPORT" "$SOURCE_PUBLICATION_PREFLIGHT_LOG" "$REPORT_DIR/source-publication-readiness-report.json"
  log "Capturing source publication preflight before release checks"
  set +e
  (set -euo pipefail; run_source_publication_preflight) >"$SOURCE_PUBLICATION_PREFLIGHT_LOG" 2>&1
  SOURCE_PUBLICATION_PREFLIGHT_STATUS=$?
  set -e
  if ((SOURCE_PUBLICATION_PREFLIGHT_STATUS != 0)); then
    echo "[release-readiness][warn] Source publication preflight failed with exit code $SOURCE_PUBLICATION_PREFLIGHT_STATUS; release checks will continue and postflight will remain blocked. Log: $SOURCE_PUBLICATION_PREFLIGHT_LOG" >&2
  fi
fi

run_check "Static cross-repo plan readiness" "plan-readiness" run_plan_readiness

if [[ "$RUN_LIVE" == true ]]; then
  run_check_with_network_retries "GitHub governance" "github-governance" run_github_governance
  run_check "Release PR readiness" "release-pr-readiness" run_release_pr_readiness
else
  skip_check "GitHub governance" "github-governance"
  skip_check "Release PR readiness" "release-pr-readiness"
fi

run_check "Private overlay readiness" "private-overlay-readiness" run_private_overlays
run_check "Android public dependency provenance" "android-public-dependency-provenance" run_android_public_dependency_provenance
run_check "iOS shared-features dependency delta" "ios-shared-features-delta" run_ios_shared_features_delta
run_check "Passkey challenge service implementation" "passkey-challenge-service" run_passkey_challenge_service
run_check "Passkey deployment evidence" "passkey-deployment-evidence" run_passkey_deployment_evidence
run_check "Passkey backup prerequisites" "passkey-backup-prerequisites" run_passkey_prerequisites
if [[ "$RUN_LIVE" == true ]]; then
  run_check "Passkey production smoke" "passkey-production-smoke" run_passkey_production_smoke
else
  skip_check "Passkey production smoke" "passkey-production-smoke"
fi
run_check "Iroha/Nexus release prerequisites" "iroha-release-readiness" run_iroha_prerequisites
run_check "Iroha/Nexus wallet coverage" "iroha-wallet-coverage" run_iroha_wallet_coverage
run_check "Android XCM production evidence" "android-xcm-production-evidence" run_android_xcm_production_evidence
run_check "Web Bitcoin broadcast evidence" "web-bitcoin-broadcast-evidence" run_web_bitcoin_broadcast_evidence
run_check "TI deployment evidence" "ti-deployment-evidence" run_ton_deployment_evidence
run_check "SI deployment evidence" "si-deployment-evidence" run_solswap_deployment_evidence
run_check "PI deployment evidence" "pi-deployment-evidence" run_polkaswap_deployment_evidence

if [[ "$RUN_LIVE" == true ]]; then
  run_check "TI production smoke" "ti-production-smoke" run_ton_production_smoke
  run_check "SI production smoke" "si-production-smoke" run_solswap_production_smoke
  run_check "PI production smoke" "pi-production-smoke" run_polkaswap_production_smoke
else
  skip_check "TI production smoke" "ti-production-smoke"
  skip_check "SI production smoke" "si-production-smoke"
  skip_check "PI production smoke" "pi-production-smoke"
fi

# This runs last so the attested source trees are the exact trees exercised by
# every preceding release test. A local-only audit must not claim publication.
if [[ "$RUN_LIVE" == true ]]; then
  run_check "Source publication readiness" "source-publication-readiness" run_source_publication_readiness
else
  skip_check "Source publication readiness" "source-publication-readiness"
fi

REPORT_GENERATED_AT="$(report_generated_at)"
write_summary
write_action_manifest
write_blocker_report
if validate_release_output_contracts; then
  if ! export_unblock_bundle; then
    failures+=("Release unblock bundle export/verification failed")
  fi
else
  failures+=("Release readiness output contract validation failed")
fi

if ((${#skipped[@]} > 0)); then
  echo "[release-readiness] Skipped checks:"
  printf '  - %s\n' "${skipped[@]}"
fi

if ((${#failures[@]} > 0)); then
  echo "[release-readiness][error] Release readiness failed:" >&2
  printf '  - %s\n' "${failures[@]}" >&2
  exit 1
fi

if [[ "$RUN_LIVE" == true && ${#skipped[@]} -eq 0 ]]; then
  log "Release readiness audit passed."
else
  log "Local readiness diagnostics completed; release readiness remains incomplete because required live checks were skipped."
fi
