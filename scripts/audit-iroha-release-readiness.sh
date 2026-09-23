#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="${IROHA_READINESS_ROOT:-$(cd "$SCRIPT_DIR/.." && pwd)}"
PARENT_DIR="${IROHA_READINESS_PARENT:-$(cd "$ROOT_DIR/.." && pwd)}"

ANDROID_VALIDATOR="$ROOT_DIR/fearless-Android-production-consolidated-20260731/scripts/check-iroha-mobile-sdk-release-assets.sh"
IOS_VALIDATOR="$ROOT_DIR/fearless-iOS-production-consolidated-20260731/scripts/check-iroha-mobile-sdk-release-assets.sh"
WEB_REPO="$ROOT_DIR/fearless-wallet-web"
WEB_JS_VALIDATOR="$ROOT_DIR/fearless-wallet-web/scripts/check-iroha-js-sdk-artifact.sh"
IROHA_REPO="$PARENT_DIR/iroha"
DEFAULT_NEXUS_TORII_URL="https://minamoto.sora.org"
IROHA_RELEASE_CONFIG_FILE="${IROHA_RELEASE_CONFIG_FILE:-$ROOT_DIR/config/iroha-release-readiness.env}"
NEXUS_PRODUCTION_EVIDENCE_FILE="${NEXUS_PRODUCTION_EVIDENCE_FILE:-$ROOT_DIR/config/nexus-production-evidence.json}"
NEXUS_PRODUCTION_EVIDENCE_AUDIT="${NEXUS_PRODUCTION_EVIDENCE_AUDIT:-$SCRIPT_DIR/audit-nexus-production-evidence.sh}"
NEXUS_PRODUCTION_EVIDENCE_TEST="${NEXUS_PRODUCTION_EVIDENCE_TEST:-$SCRIPT_DIR/test-nexus-production-evidence-audit.sh}"
TAIRA_RELEASE_AUDIT="${TAIRA_RELEASE_AUDIT:-$ROOT_DIR/scripts/audit-taira-release-readiness.sh}"
TAIRA_RELEASE_AUDIT_TEST="${TAIRA_RELEASE_AUDIT_TEST:-$ROOT_DIR/scripts/test-taira-release-readiness-audit.mjs}"

usage() {
  cat <<'USAGE'
Usage: scripts/audit-iroha-release-readiness.sh

Checks the release prerequisites needed before Taira/Nexus support can be treated
as releasable in the open-source wallets:
  - ../iroha still builds and publishes mobile SDK release assets.
  - Android and iOS can validate the tagged mobile SDK release assets.
  - fearless-wallet-web can validate the browser-safe @iroha/iroha-js artifact.
  - Taira source contracts are canonical across wallets and genesis; optional
    live checks require fresh complete four-validator evidence.
  - SORA Nexus mainnet has a committed HTTPS Torii endpoint in all wallets.

Environment:
  IROHA_READINESS_ROOT             Workspace root containing fearless-* repos.
  IROHA_READINESS_PARENT           Parent directory containing ../iroha.
  IROHA_RELEASE_CONFIG_FILE        Optional env-style defaults file. Defaults to
                                    config/iroha-release-readiness.env.
  IROHA_MOBILE_SDK_RELEASE_TAG     Required GitHub release tag for mobile SDK assets.
  IROHA_MOBILE_SDK_RELEASE_REPO    Optional owner/repo for mobile SDK release assets.
  IROHA_JS_SDK_VERSION             Published @iroha/iroha-js version to validate.
  IROHA_JS_SDK_REGISTRY            Optional npm registry URL for Iroha JS SDK download.
  IROHA_JS_SDK_TARBALL             Local @iroha/iroha-js package tarball to validate.
  IROHA_JS_SDK_PACKAGE_DIR         Local @iroha/iroha-js package directory to pack/validate.
  IROHA_JS_SDK_RELEASE_REPO        GitHub owner/repo for a pinned JS SDK tarball.
  IROHA_JS_SDK_RELEASE_TAG         GitHub release tag for a pinned JS SDK tarball.
  IROHA_JS_SDK_RELEASE_ASSET       GitHub release asset name for the JS SDK tarball.
  IROHA_JS_SDK_RELEASE_SHA256      SHA-256 digest for the pinned JS SDK tarball.
  NEXUS_TORII_URL                  Optional SORA Nexus Torii base URL or /v1/mcp URL.
                                    Defaults to https://minamoto.sora.org.
  IROHA_NEXUS_LIVE_HEALTH          Set to 1/true to require live Nexus endpoint health.
  IROHA_TAIRA_LIVE_HEALTH          Set to 1/true to require canonical Taira
                                    health, fanout, MCP, asset, and validator-DNS checks.
  TAIRA_EXPECTED_BUILD_COMMIT      Exact deployed Taira build commit required
                                    when live Taira checks are enabled.
  IROHA_NEXUS_REQUIRE_PRODUCTION_EVIDENCE
                                    Set to 1/true to require ready route
                                    publication, canary, and wallet-smoke
                                    evidence.
  NEXUS_PRODUCTION_EVIDENCE_FILE   Optional Nexus production evidence manifest.
                                    Defaults to config/nexus-production-evidence.json.
  NEXUS_PRODUCTION_EVIDENCE_AUDIT  Optional Nexus production evidence audit script.
  NEXUS_PRODUCTION_EVIDENCE_TEST   Optional Nexus production evidence audit
                                    self-test script.
  NEXUS_HEALTH_PATH                Optional live health path. Defaults to /status.
  NEXUS_HEALTH_TIMEOUT_SECONDS     Optional curl timeout. Defaults to 10.
  NEXUS_HEALTH_ATTEMPTS            Attempts for live health checks. Defaults to 3.
  NEXUS_HEALTH_RETRY_DELAY_SECONDS Delay between live health attempts. Defaults
                                    to 2.
  NEXUS_EXPECTED_BUILD_COMMIT      Exact deployed Iroha build commit expected
                                    from /status (40 or 64 lowercase hex).
                                    Required when live Nexus health is enabled.
  NEXUS_EXPECTED_CHAIN_ID          Exact deployed Iroha chain identifier expected
                                    from top-level /status.chain_id. The committed
                                    pin is authoritative when live health is enabled.
  NEXUS_EXPECTED_GENESIS_HASH      Exact deployed genesis block hash expected from
                                    top-level /status.genesis_hash (64 lowercase hex).
                                    The committed pin is authoritative when live
                                    health is enabled.
  IROHA_RELEASE_ASSET_VALIDATION_ATTEMPTS
                                    Attempts for network-backed release asset
                                    validation. Defaults to 3.
  IROHA_RELEASE_ASSET_VALIDATION_RETRY_DELAY_SECONDS
                                    Delay between release asset validation
                                    attempts. Defaults to 2.
USAGE
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

if (($# > 0)); then
  echo "[iroha-readiness][error] Unknown argument: $1" >&2
  usage >&2
  exit 2
fi

failures=()
temporary_paths=()
NEXUS_BASE_URL=""
NEXUS_LIVE_HEALTH_ENABLED=false
NEXUS_PRODUCTION_EVIDENCE_REQUIRED=false
NEXUS_HEALTH_PATH_VALUE="/status"
NEXUS_HEALTH_TIMEOUT_VALUE=10
NEXUS_HEALTH_ATTEMPTS_VALUE=3
NEXUS_HEALTH_RETRY_DELAY_VALUE=2
NEXUS_EXPECTED_BUILD_COMMIT_VALUE=""
NEXUS_EXPECTED_CHAIN_ID_VALUE=""
NEXUS_EXPECTED_GENESIS_HASH_VALUE=""
NEXUS_COMMITTED_BUILD_COMMIT=""
NEXUS_COMMITTED_CHAIN_ID=""
NEXUS_COMMITTED_GENESIS_HASH=""
NEXUS_COMMITTED_BUILD_COMMIT_SEEN=false
NEXUS_COMMITTED_CHAIN_ID_SEEN=false
NEXUS_COMMITTED_GENESIS_HASH_SEEN=false
NEXUS_PROCESS_EXPECTED_BUILD_COMMIT="${NEXUS_EXPECTED_BUILD_COMMIT-}"
NEXUS_PROCESS_EXPECTED_CHAIN_ID="${NEXUS_EXPECTED_CHAIN_ID-}"
NEXUS_PROCESS_EXPECTED_GENESIS_HASH="${NEXUS_EXPECTED_GENESIS_HASH-}"
NEXUS_PROCESS_EXPECTED_BUILD_COMMIT_SET=false
NEXUS_PROCESS_EXPECTED_CHAIN_ID_SET=false
NEXUS_PROCESS_EXPECTED_GENESIS_HASH_SET=false
TAIRA_PROCESS_EXPECTED_BUILD_COMMIT="${TAIRA_EXPECTED_BUILD_COMMIT-}"
TAIRA_PROCESS_EXPECTED_BUILD_COMMIT_SET=false
TAIRA_COMMITTED_BUILD_COMMIT=""
TAIRA_COMMITTED_BUILD_COMMIT_SEEN=false
if [[ "${NEXUS_EXPECTED_BUILD_COMMIT+x}" == "x" ]]; then
  NEXUS_PROCESS_EXPECTED_BUILD_COMMIT_SET=true
fi
if [[ "${NEXUS_EXPECTED_CHAIN_ID+x}" == "x" ]]; then
  NEXUS_PROCESS_EXPECTED_CHAIN_ID_SET=true
fi
if [[ "${NEXUS_EXPECTED_GENESIS_HASH+x}" == "x" ]]; then
  NEXUS_PROCESS_EXPECTED_GENESIS_HASH_SET=true
fi
if [[ "${TAIRA_EXPECTED_BUILD_COMMIT+x}" == "x" ]]; then
  TAIRA_PROCESS_EXPECTED_BUILD_COMMIT_SET=true
fi
readonly NEXUS_HEALTH_MAX_RESPONSE_BYTES=131072
readonly NEXUS_HEALTH_MAX_BLOCK_AGE_MS=300000
readonly NEXUS_CHAIN_ID_MAX_BYTES=128
readonly NEXUS_PRODUCTION_EVIDENCE_CHAIN_ID="sora:nexus:global"
readonly NEXUS_DIAGNOSTIC_SCAN_BYTES=4096
readonly NEXUS_DIAGNOSTIC_MAX_BYTES=300

log() { echo "[iroha-readiness] $*"; }
warn() { echo "[iroha-readiness][warn] $*" >&2; }

cleanup_temporaries() {
  local path
  for path in "${temporary_paths[@]:-}"; do
    [[ -n "$path" ]] && rm -rf -- "$path"
  done
  return 0
}
trap cleanup_temporaries EXIT
trap 'cleanup_temporaries; exit 129' HUP
trap 'cleanup_temporaries; exit 130' INT
trap 'cleanup_temporaries; exit 143' TERM

diagnostic_preview() {
  local value="$1"
  printf '%s' "$value" | node -e '
const fs = require("node:fs");
const scanLimit = Number(process.argv[1]);
const outputLimit = Number(process.argv[2]);
const raw = fs.readFileSync(0).subarray(0, scanLimit).toString("utf8");
let text = raw
  .replace(/\u001b(?:\[[0-?]*[ -\/]*[@-~]|\][^\u0007]*(?:\u0007|\u001b\\))/gu, "")
  .replace(/\b((?:proxy-)?authorization|cookie|set-cookie)\s*:\s*[^\r\n]*/giu, "$1: [REDACTED]")
  .replace(/[\u0000-\u001f\u007f-\u009f]/gu, " ")
  .replace(/\b(Bearer|Basic|Digest|Negotiate)\s+[^\s,;]+/giu, "$1 [REDACTED]")
  .replace(/([?&](?:access[_-]?token|api[_-]?key|auth(?:orization)?|client[_-]?secret|password|passwd|secret|token)=)[^&\s]*/giu, "$1[REDACTED]")
  .replace(/(["\x27]?)(access[_-]?token|api[_-]?key|auth(?:orization)?|client[_-]?secret|password|passwd|secret|token)\1\s*[:=]\s*(?:"[^"]*"|\x27[^\x27]*\x27|[^\s,;}]+)/giu, "$2=[REDACTED]")
  .replace(/\s+/gu, " ")
  .trim();
if (!text) text = "<no diagnostic output>";
let bytes = Buffer.from(text, "utf8");
if (bytes.length > outputLimit) {
  text = bytes.subarray(0, outputLimit - 3).toString("utf8").replace(/\uFFFD$/u, "") + "...";
}
process.stdout.write(text);
' "$NEXUS_DIAGNOSTIC_SCAN_BYTES" "$NEXUS_DIAGNOSTIC_MAX_BYTES"
}

record_failure() {
  failures+=("$1")
  warn "$1"
}

require_file() {
  local file="$1"
  local description="$2"
  [[ -f "$file" ]] || record_failure "$description missing: $file"
}

require_executable_file() {
  local file="$1"
  local description="$2"
  if [[ ! -f "$file" ]]; then
    record_failure "$description missing: $file"
  elif [[ ! -x "$file" ]]; then
    record_failure "$description is not executable: $file"
  fi
}

require_pattern() {
  local file="$1"
  local pattern="$2"
  local description="$3"
  if [[ ! -f "$file" ]]; then
    return
  fi
  if ! grep -Eq "$pattern" "$file"; then
    record_failure "$description missing in $file"
  fi
}

require_literal() {
  local file="$1"
  local literal="$2"
  local description="$3"
  if [[ ! -f "$file" ]]; then
    return
  fi
  if ! grep -Fq "$literal" "$file"; then
    record_failure "$description missing in $file"
  fi
}

require_no_pattern() {
  local file="$1"
  local pattern="$2"
  local description="$3"
  if [[ ! -f "$file" ]]; then
    return
  fi
  if grep -Eq "$pattern" "$file"; then
    record_failure "$description found in $file"
  fi
}

require_no_multiline_pattern() {
  local file="$1"
  local pattern="$2"
  local description="$3"
  if [[ ! -f "$file" ]]; then
    return
  fi
  if awk -v pattern="$pattern" 'BEGIN { RS = "\0" } $0 ~ pattern { found = 1 } END { exit found ? 0 : 1 }' "$file"; then
    record_failure "$description found in $file"
  fi
}

run_step() {
  local description="$1"
  shift

  log "$description"
  set +e
  "$@"
  local status=$?
  set -e

  if [[ "$status" -ne 0 ]]; then
    record_failure "$description failed with exit code $status"
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

parse_strict_boolean() {
  local name="$1"
  local raw="$2"
  local output_name="$3"

  case "$raw" in
    1|true)
      printf -v "$output_name" '%s' true
      ;;
    0|false)
      printf -v "$output_name" '%s' false
      ;;
    *)
      record_failure "$name must be exactly one of: 0, 1, false, true"
      printf -v "$output_name" '%s' false
      ;;
  esac
}

parse_bounded_integer() {
  local name="$1"
  local raw="$2"
  local minimum="$3"
  local maximum="$4"
  local fallback="$5"
  local output_name="$6"

  if [[ ! "$raw" =~ ^(0|[1-9][0-9]{0,3})$ ]] || ((10#$raw < minimum || 10#$raw > maximum)); then
    record_failure "$name must be an integer from $minimum through $maximum"
    printf -v "$output_name" '%s' "$fallback"
    return
  fi
  printf -v "$output_name" '%s' "$((10#$raw))"
}

validate_build_commit_pin() {
  local name="$1"
  local value="$2"

  if [[ ! "$value" =~ ^([0-9a-f]{40}|[0-9a-f]{64})$ ]]; then
    record_failure "$name must be exactly 40 or 64 lowercase hexadecimal characters"
    return 1
  fi
  local first_character="${value:0:1}"
  if [[ -z "${value//$first_character/}" ]]; then
    record_failure "$name must not be a repeated-character placeholder"
    return 1
  fi
  return 0
}

validate_chain_id_pin() {
  local name="$1"
  local value="$2"

  if [[ ! "$value" =~ ^[a-z0-9]+([._:-][a-z0-9]+)*$ ]]; then
    record_failure "$name must use canonical lowercase ASCII segments separated only by one of '.', '_', ':', or '-'"
    return 1
  fi
  if ((${#value} > NEXUS_CHAIN_ID_MAX_BYTES)); then
    record_failure "$name must be at most $NEXUS_CHAIN_ID_MAX_BYTES ASCII bytes"
    return 1
  fi
  return 0
}

validate_genesis_hash_pin() {
  local name="$1"
  local value="$2"

  if [[ ! "$value" =~ ^[0-9a-f]{64}$ ]]; then
    record_failure "$name must be exactly 64 lowercase hexadecimal characters"
    return 1
  fi
  local first_character="${value:0:1}"
  if [[ -z "${value//$first_character/}" ]]; then
    record_failure "$name must not be a repeated-character placeholder"
    return 1
  fi
  return 0
}

resolve_nexus_identity_pin() {
  local name="$1"
  local process_is_set="$2"
  local process_value="$3"
  local committed_is_set="$4"
  local committed_value="$5"
  local validator="$6"
  local output_name="$7"
  local committed_valid=true

  if [[ "$process_is_set" == "true" ]] && ! "$validator" "process $name" "$process_value"; then
    :
  fi
  if [[ "$committed_is_set" == "true" ]] && ! "$validator" "committed $name" "$committed_value"; then
    committed_valid=false
  fi

  if [[ "$committed_is_set" == "true" && "$process_is_set" == "true" && "$process_value" != "$committed_value" ]]; then
    if [[ "$name" == "NEXUS_EXPECTED_BUILD_COMMIT" ]]; then
      record_failure "process NEXUS_EXPECTED_BUILD_COMMIT must not override the committed Iroha build pin"
    else
      record_failure "process $name must not override the committed Iroha release pin"
    fi
  fi

  if [[ "$NEXUS_LIVE_HEALTH_ENABLED" == "true" && "$committed_is_set" != "true" ]]; then
    record_failure "$name must be pinned in the committed Iroha release defaults when live health is enabled"
  fi

  if [[ "$committed_is_set" == "true" && "$committed_valid" == "true" ]]; then
    printf -v "$output_name" '%s' "$committed_value"
  else
    printf -v "$output_name" '%s' ""
  fi

  if [[ "$NEXUS_LIVE_HEALTH_ENABLED" == "true" && -z "${!output_name}" ]]; then
    if [[ "$name" == "NEXUS_EXPECTED_BUILD_COMMIT" ]]; then
      record_failure "NEXUS_EXPECTED_BUILD_COMMIT is required when IROHA_NEXUS_LIVE_HEALTH is enabled"
    else
      record_failure "$name is required when IROHA_NEXUS_LIVE_HEALTH is enabled"
    fi
  fi
}

validate_nexus_runtime_settings() {
  parse_strict_boolean \
    IROHA_NEXUS_LIVE_HEALTH \
    "${IROHA_NEXUS_LIVE_HEALTH-0}" \
    NEXUS_LIVE_HEALTH_ENABLED
  parse_strict_boolean \
    IROHA_NEXUS_REQUIRE_PRODUCTION_EVIDENCE \
    "${IROHA_NEXUS_REQUIRE_PRODUCTION_EVIDENCE-0}" \
    NEXUS_PRODUCTION_EVIDENCE_REQUIRED
  parse_bounded_integer \
    NEXUS_HEALTH_TIMEOUT_SECONDS \
    "${NEXUS_HEALTH_TIMEOUT_SECONDS-10}" \
    1 60 10 \
    NEXUS_HEALTH_TIMEOUT_VALUE
  parse_bounded_integer \
    NEXUS_HEALTH_ATTEMPTS \
    "${NEXUS_HEALTH_ATTEMPTS-3}" \
    1 10 3 \
    NEXUS_HEALTH_ATTEMPTS_VALUE
  parse_bounded_integer \
    NEXUS_HEALTH_RETRY_DELAY_SECONDS \
    "${NEXUS_HEALTH_RETRY_DELAY_SECONDS-2}" \
    0 30 2 \
    NEXUS_HEALTH_RETRY_DELAY_VALUE

  local health_path="${NEXUS_HEALTH_PATH-/status}"
  if [[ "$health_path" != "/status" ]]; then
    record_failure "NEXUS_HEALTH_PATH must be exactly /status for SORA Nexus production readiness"
    NEXUS_HEALTH_PATH_VALUE="/status"
  else
    NEXUS_HEALTH_PATH_VALUE="$health_path"
  fi

  resolve_nexus_identity_pin \
    NEXUS_EXPECTED_BUILD_COMMIT \
    "$NEXUS_PROCESS_EXPECTED_BUILD_COMMIT_SET" \
    "$NEXUS_PROCESS_EXPECTED_BUILD_COMMIT" \
    "$NEXUS_COMMITTED_BUILD_COMMIT_SEEN" \
    "$NEXUS_COMMITTED_BUILD_COMMIT" \
    validate_build_commit_pin \
    NEXUS_EXPECTED_BUILD_COMMIT_VALUE
  resolve_nexus_identity_pin \
    NEXUS_EXPECTED_CHAIN_ID \
    "$NEXUS_PROCESS_EXPECTED_CHAIN_ID_SET" \
    "$NEXUS_PROCESS_EXPECTED_CHAIN_ID" \
    "$NEXUS_COMMITTED_CHAIN_ID_SEEN" \
    "$NEXUS_COMMITTED_CHAIN_ID" \
    validate_chain_id_pin \
    NEXUS_EXPECTED_CHAIN_ID_VALUE
  resolve_nexus_identity_pin \
    NEXUS_EXPECTED_GENESIS_HASH \
    "$NEXUS_PROCESS_EXPECTED_GENESIS_HASH_SET" \
    "$NEXUS_PROCESS_EXPECTED_GENESIS_HASH" \
    "$NEXUS_COMMITTED_GENESIS_HASH_SEEN" \
    "$NEXUS_COMMITTED_GENESIS_HASH" \
    validate_genesis_hash_pin \
    NEXUS_EXPECTED_GENESIS_HASH_VALUE
}

run_step_with_retries() {
  local description="$1"
  shift

  local attempts delay
  attempts="$(positive_integer_or_default "${IROHA_RELEASE_ASSET_VALIDATION_ATTEMPTS:-3}" 3)"
  delay="$(positive_integer_or_default "${IROHA_RELEASE_ASSET_VALIDATION_RETRY_DELAY_SECONDS:-2}" 2)"

  log "$description"
  local attempt status=0
  for ((attempt = 1; attempt <= attempts; attempt += 1)); do
    set +e
    "$@"
    status=$?
    set -e

    if [[ "$status" -eq 0 ]]; then
      return
    fi

    if ((attempt < attempts)); then
      warn "$description attempt $attempt/$attempts failed with exit code $status; retrying."
      if ((delay > 0)); then
        sleep "$delay"
      fi
    fi
  done

  record_failure "$description failed after $attempts attempts (last exit code $status)"
}

run_web_js_validator() {
  cd "$WEB_REPO"
  bash "scripts/check-iroha-js-sdk-artifact.sh" "$@"
}

load_release_config_defaults() {
  [[ -f "$IROHA_RELEASE_CONFIG_FILE" ]] || return 0

  log "Loading Iroha release defaults from $IROHA_RELEASE_CONFIG_FILE"
  local line key value
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
    [[ -z "$line" || "$line" == \#* ]] && continue

    key="${line%%=*}"
    value="${line#*=}"
    key="${key%"${key##*[![:space:]]}"}"
    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%\"}"
    value="${value#\"}"
    value="${value%\'}"
    value="${value#\'}"

    case "$key" in
      IROHA_MOBILE_SDK_RELEASE_TAG)
        IROHA_MOBILE_SDK_RELEASE_TAG="${IROHA_MOBILE_SDK_RELEASE_TAG:-$value}"
        ;;
      IROHA_MOBILE_SDK_RELEASE_REPO)
        IROHA_MOBILE_SDK_RELEASE_REPO="${IROHA_MOBILE_SDK_RELEASE_REPO:-$value}"
        ;;
      IROHA_JS_SDK_VERSION)
        IROHA_JS_SDK_VERSION="${IROHA_JS_SDK_VERSION:-$value}"
        ;;
      IROHA_JS_SDK_REGISTRY)
        IROHA_JS_SDK_REGISTRY="${IROHA_JS_SDK_REGISTRY:-$value}"
        ;;
      IROHA_JS_SDK_TARBALL)
        IROHA_JS_SDK_TARBALL="${IROHA_JS_SDK_TARBALL:-$value}"
        ;;
      IROHA_JS_SDK_PACKAGE_DIR)
        IROHA_JS_SDK_PACKAGE_DIR="${IROHA_JS_SDK_PACKAGE_DIR:-$value}"
        ;;
      IROHA_JS_SDK_RELEASE_REPO)
        IROHA_JS_SDK_RELEASE_REPO="${IROHA_JS_SDK_RELEASE_REPO:-$value}"
        ;;
      IROHA_JS_SDK_RELEASE_TAG)
        IROHA_JS_SDK_RELEASE_TAG="${IROHA_JS_SDK_RELEASE_TAG:-$value}"
        ;;
      IROHA_JS_SDK_RELEASE_ASSET)
        IROHA_JS_SDK_RELEASE_ASSET="${IROHA_JS_SDK_RELEASE_ASSET:-$value}"
        ;;
      IROHA_JS_SDK_RELEASE_SHA256)
        IROHA_JS_SDK_RELEASE_SHA256="${IROHA_JS_SDK_RELEASE_SHA256:-$value}"
        ;;
      NEXUS_EXPECTED_BUILD_COMMIT)
        if [[ "$NEXUS_COMMITTED_BUILD_COMMIT_SEEN" == "true" ]]; then
          record_failure "Duplicate NEXUS_EXPECTED_BUILD_COMMIT in Iroha release defaults"
        fi
        NEXUS_COMMITTED_BUILD_COMMIT_SEEN=true
        NEXUS_COMMITTED_BUILD_COMMIT="$value"
        ;;
      NEXUS_EXPECTED_CHAIN_ID)
        if [[ "$NEXUS_COMMITTED_CHAIN_ID_SEEN" == "true" ]]; then
          record_failure "Duplicate NEXUS_EXPECTED_CHAIN_ID in Iroha release defaults"
        fi
        NEXUS_COMMITTED_CHAIN_ID_SEEN=true
        NEXUS_COMMITTED_CHAIN_ID="$value"
        ;;
      NEXUS_EXPECTED_GENESIS_HASH)
        if [[ "$NEXUS_COMMITTED_GENESIS_HASH_SEEN" == "true" ]]; then
          record_failure "Duplicate NEXUS_EXPECTED_GENESIS_HASH in Iroha release defaults"
        fi
        NEXUS_COMMITTED_GENESIS_HASH_SEEN=true
        NEXUS_COMMITTED_GENESIS_HASH="$value"
        ;;
      TAIRA_EXPECTED_BUILD_COMMIT)
        if [[ "$TAIRA_COMMITTED_BUILD_COMMIT_SEEN" == "true" ]]; then
          record_failure "Duplicate TAIRA_EXPECTED_BUILD_COMMIT in Iroha release defaults"
        fi
        TAIRA_COMMITTED_BUILD_COMMIT_SEEN=true
        TAIRA_COMMITTED_BUILD_COMMIT="$value"
        ;;
      *)
        record_failure "Unsupported key in Iroha release defaults: $key"
        ;;
    esac
  done < "$IROHA_RELEASE_CONFIG_FILE"
}

check_iroha_release_tooling() {
  log "Checking ../iroha mobile SDK release tooling"

  if [[ ! -d "$IROHA_REPO" ]]; then
    record_failure "../iroha repo missing: $IROHA_REPO"
    return
  fi

  local workflow="$IROHA_REPO/.github/workflows/mobile_sdk_artifacts.yml"
  require_file "$workflow" "Iroha mobile SDK GitHub Actions workflow"
  require_executable_file "$IROHA_REPO/scripts/check_mobile_sdk_artifacts.sh" "Iroha mobile SDK artifact checker"
  require_executable_file "$IROHA_REPO/scripts/check_mobile_sdk_artifacts_test.sh" "Iroha mobile SDK artifact checker self-test"
  require_executable_file "$IROHA_REPO/scripts/package_mobile_sdk_artifacts.sh" "Iroha mobile SDK artifact packager"

  require_pattern "$workflow" 'push:' "Iroha mobile SDK workflow push trigger"
  require_pattern "$workflow" 'tags:[[:space:]]*$' "Iroha mobile SDK workflow tag trigger"
  require_pattern "$workflow" 'checker-self-test' "Iroha mobile SDK workflow checker self-test job"
  require_pattern "$workflow" 'package_mobile_sdk_artifacts\.sh --apple' "Iroha mobile SDK workflow Apple packaging step"
  require_pattern "$workflow" 'package_mobile_sdk_artifacts\.sh --android' "Iroha mobile SDK workflow Android packaging step"
  require_pattern "$workflow" 'gh release upload' "Iroha mobile SDK workflow release upload step"
}

check_mobile_wallet_validators() {
  require_executable_file "$ANDROID_VALIDATOR" "Android Iroha mobile SDK release asset validator"
  require_executable_file "$IOS_VALIDATOR" "iOS Iroha mobile SDK release asset validator"

  if [[ -f "$ANDROID_VALIDATOR" ]]; then
    run_step "Android Iroha mobile SDK release asset validator self-test" bash "$ANDROID_VALIDATOR" --self-test
  fi
  if [[ -f "$IOS_VALIDATOR" ]]; then
    run_step "iOS Iroha mobile SDK release asset validator self-test" bash "$IOS_VALIDATOR" --self-test
  fi

  local release_tag="${IROHA_MOBILE_SDK_RELEASE_TAG:-}"
  local release_repo="${IROHA_MOBILE_SDK_RELEASE_REPO:-hyperledger-iroha/iroha}"
  if [[ -z "$release_tag" ]]; then
    record_failure "IROHA_MOBILE_SDK_RELEASE_TAG is required so Android and iOS can validate published Iroha mobile SDK release assets"
    return
  fi

  if [[ -f "$ANDROID_VALIDATOR" ]]; then
    run_step_with_retries "Android Iroha mobile SDK release asset validation" bash "$ANDROID_VALIDATOR" --download --tag "$release_tag" --repo "$release_repo"
  fi
  if [[ -f "$IOS_VALIDATOR" ]]; then
    run_step_with_retries "iOS Iroha mobile SDK release asset validation" bash "$IOS_VALIDATOR" --download --tag "$release_tag" --repo "$release_repo"
  fi
}

check_web_js_sdk_artifact() {
  require_executable_file "$WEB_JS_VALIDATOR" "fearless-wallet-web Iroha JS SDK artifact validator"
  if [[ -f "$WEB_JS_VALIDATOR" ]]; then
    run_step "Iroha JS SDK artifact validator self-test" run_web_js_validator --self-test
  fi

  local github_release_configured=false
  if [[ -n "${IROHA_JS_SDK_RELEASE_REPO:-}" || -n "${IROHA_JS_SDK_RELEASE_TAG:-}" || -n "${IROHA_JS_SDK_RELEASE_ASSET:-}" || -n "${IROHA_JS_SDK_RELEASE_SHA256:-}" ]]; then
    if [[ -z "${IROHA_JS_SDK_RELEASE_REPO:-}" || -z "${IROHA_JS_SDK_RELEASE_TAG:-}" || -z "${IROHA_JS_SDK_RELEASE_ASSET:-}" || -z "${IROHA_JS_SDK_RELEASE_SHA256:-}" ]]; then
      record_failure "IROHA_JS_SDK_RELEASE_REPO, IROHA_JS_SDK_RELEASE_TAG, IROHA_JS_SDK_RELEASE_ASSET, and IROHA_JS_SDK_RELEASE_SHA256 are required together"
      return
    fi
    github_release_configured=true
  fi

  if [[ -n "${IROHA_JS_SDK_TARBALL:-}" ]]; then
    run_step "Iroha JS SDK artifact validation" run_web_js_validator --tarball "$IROHA_JS_SDK_TARBALL"
  elif [[ -n "${IROHA_JS_SDK_PACKAGE_DIR:-}" ]]; then
    run_step "Iroha JS SDK artifact validation" run_web_js_validator --package-dir "$IROHA_JS_SDK_PACKAGE_DIR"
  elif [[ "$github_release_configured" == "true" ]]; then
    run_step_with_retries \
      "Iroha JS SDK artifact validation" \
      run_web_js_validator \
        --github-release \
        --repo "$IROHA_JS_SDK_RELEASE_REPO" \
        --tag "$IROHA_JS_SDK_RELEASE_TAG" \
        --asset "$IROHA_JS_SDK_RELEASE_ASSET" \
        --sha256 "$IROHA_JS_SDK_RELEASE_SHA256"
  elif [[ -n "${IROHA_JS_SDK_VERSION:-}" ]]; then
    run_step_with_retries \
      "Iroha JS SDK artifact validation" \
      run_web_js_validator --download --version "$IROHA_JS_SDK_VERSION" --registry "${IROHA_JS_SDK_REGISTRY:-https://registry.npmjs.org/}"
  else
    record_failure "One of IROHA_JS_SDK_VERSION, IROHA_JS_SDK_TARBALL, IROHA_JS_SDK_PACKAGE_DIR, or IROHA_JS_SDK_RELEASE_* is required so fearless-wallet-web can validate the browser Iroha SDK artifact"
  fi
}

normalize_nexus_torii_url() {
  local raw="${NEXUS_TORII_URL:-$DEFAULT_NEXUS_TORII_URL}"

  if ! command -v node >/dev/null 2>&1; then
    record_failure "node is required to validate NEXUS_TORII_URL"
    return 1
  fi
  if [[ "$raw" =~ [[:space:]] ]]; then
    record_failure "NEXUS_TORII_URL must not contain whitespace"
    return 1
  fi
  if [[ "$raw" == *\?* || "$raw" == *\#* ]]; then
    record_failure "NEXUS_TORII_URL must not contain query strings or fragments"
    return 1
  fi

  local result status
  set +e
  result="$(
    NEXUS_URL_INPUT="$raw" node <<'NODE'
const raw = process.env.NEXUS_URL_INPUT || '';
const reject = (code) => {
  process.stdout.write(code);
  process.exit(1);
};

let parsed;
try {
  parsed = new URL(raw);
} catch {
  reject('INVALID_URL');
}
if (parsed.protocol !== 'https:') reject('HTTPS_REQUIRED');
if (parsed.username || parsed.password) reject('CREDENTIALS');
if (parsed.search || parsed.hash) reject('QUERY_OR_FRAGMENT');
if (raw.includes('\\')) reject('NON_CANONICAL_PATH');

const rawPathMatch = raw.match(/^[a-z][a-z0-9+.-]*:\/\/[^/]*(\/.*)?$/iu);
if (!rawPathMatch) reject('INVALID_URL');
const rawPath = rawPathMatch[1] || '';
for (const segment of rawPath.split('/')) {
  let decoded;
  try {
    decoded = decodeURIComponent(segment);
  } catch {
    reject('INVALID_PATH_ENCODING');
  }
  if (decoded === '.' || decoded === '..') reject('DOT_SEGMENT');
}

if (parsed.origin !== 'https://minamoto.sora.org') reject('NON_PRODUCTION_ORIGIN');
if (parsed.pathname !== '/' && parsed.pathname !== '/v1/mcp' && parsed.pathname !== '/v1/mcp/') {
  reject('NON_CANONICAL_PATH');
}
process.stdout.write('https://minamoto.sora.org');
NODE
  )"
  status=$?
  set -e

  if [[ "$status" -ne 0 ]]; then
    case "$result" in
      HTTPS_REQUIRED)
        record_failure "NEXUS_TORII_URL must be an https URL"
        ;;
      CREDENTIALS)
        record_failure "NEXUS_TORII_URL must not contain credentials"
        ;;
      QUERY_OR_FRAGMENT)
        record_failure "NEXUS_TORII_URL must not contain query strings or fragments"
        ;;
      DOT_SEGMENT)
        record_failure "NEXUS_TORII_URL must not contain dot segments"
        ;;
      NON_PRODUCTION_ORIGIN)
        record_failure "NEXUS_TORII_URL must use the canonical SORA Nexus production origin https://minamoto.sora.org"
        ;;
      NON_CANONICAL_PATH)
        record_failure "NEXUS_TORII_URL path must be empty, /, or exactly /v1/mcp"
        ;;
      *)
        record_failure "NEXUS_TORII_URL must be a valid canonical SORA Nexus production URL"
        ;;
    esac
    return 1
  fi

  NEXUS_BASE_URL="$result"
}

check_nexus_sources() {
  local nexus_base_url="$1"
  local web_registry="$ROOT_DIR/fearless-wallet-web/src/consts/universalWallet.ts"
  local android_registry="$ROOT_DIR/fearless-Android-production-consolidated-20260731/common/src/main/java/jp/co/soramitsu/common/model/UniversalWalletRegistry.kt"
  local ios_registry="$ROOT_DIR/fearless-iOS-production-consolidated-20260731/fearless/Common/Model/UniversalWalletRegistry.swift"

  log "Checking committed SORA Nexus Torii endpoint bindings"

  require_file "$web_registry" "fearless-wallet-web universal wallet registry"
  require_file "$android_registry" "Android universal wallet registry"
  require_file "$ios_registry" "iOS universal wallet registry"

  require_no_pattern "$web_registry" 'toriiBaseUrl:[[:space:]]*null' "Web SORA Nexus null Torii base URL"
  require_no_multiline_pattern "$web_registry" "UNIVERSAL_WALLET_NEXUS_REGISTRY_ENTRY[[:space:][:print:]]*endpoints:[[:space:]]*\\[[[:space:]]*\\]" "Web SORA Nexus empty endpoints"
  require_no_pattern "$android_registry" 'toriiBaseUrl[[:space:]]*=[[:space:]]*null' "Android SORA Nexus null Torii base URL"
  require_no_pattern "$ios_registry" 'toriiBaseURL:[[:space:]]*nil' "iOS SORA Nexus nil Torii base URL"

  if [[ -n "$nexus_base_url" ]]; then
    require_literal "$web_registry" "$nexus_base_url" "SORA Nexus Torii URL"
    require_literal "$android_registry" "$nexus_base_url" "SORA Nexus Torii URL"
    require_literal "$ios_registry" "$nexus_base_url" "SORA Nexus Torii URL"
  fi
}

run_isolated_nexus_curl() {
  /usr/bin/env \
    -u CURL_CA_BUNDLE \
    -u SSL_CERT_FILE \
    -u SSL_CERT_DIR \
    -u OPENSSL_CONF \
    -u HTTP_PROXY \
    -u HTTPS_PROXY \
    -u ALL_PROXY \
    -u NO_PROXY \
    -u http_proxy \
    -u https_proxy \
    -u all_proxy \
    -u no_proxy \
    curl "$@"
}

run_isolated_nexus_evidence_audit() {
  /usr/bin/env \
    -u NEXUS_RECEIPT_BASE_URL \
    -u NEXUS_TORII_BASE_URL \
    -u NEXUS_MCP_URL \
    -u NEXUS_RECEIPT_FIXTURE_DIR \
    -u NODE_BIN \
    -u NODE_OPTIONS \
    -u NODE_EXTRA_CA_CERTS \
    -u NODE_TLS_REJECT_UNAUTHORIZED \
    -u NODE_PATH \
    -u NPM_CONFIG_NODE_OPTIONS \
    -u npm_config_node_options \
    -u NODE_USE_SYSTEM_CA \
    -u NODE_USE_ENV_PROXY \
    -u SSL_CERT_FILE \
    -u SSL_CERT_DIR \
    -u SSLKEYLOGFILE \
    -u OPENSSL_CONF \
    -u HTTP_PROXY \
    -u HTTPS_PROXY \
    -u ALL_PROXY \
    -u NO_PROXY \
    -u http_proxy \
    -u https_proxy \
    -u all_proxy \
    -u no_proxy \
    -u GLOBAL_AGENT_HTTP_PROXY \
    -u GLOBAL_AGENT_HTTPS_PROXY \
    -u GLOBAL_AGENT_NO_PROXY \
    -u GLOBAL_AGENT_ENVIRONMENT_VARIABLE_NAMESPACE \
    bash "$@"
}

check_nexus_live_health() {
  local nexus_base_url="$1"
  if [[ "$NEXUS_LIVE_HEALTH_ENABLED" != "true" ]]; then
    return
  fi
  if [[ -z "$nexus_base_url" ]]; then
    record_failure "SORA Nexus live health check requires a valid NEXUS_TORII_URL"
    return
  fi
  if [[ -z "$NEXUS_EXPECTED_BUILD_COMMIT_VALUE" ||
        -z "$NEXUS_EXPECTED_CHAIN_ID_VALUE" ||
        -z "$NEXUS_EXPECTED_GENESIS_HASH_VALUE" ]]; then
    return
  fi
  if ! command -v curl >/dev/null 2>&1; then
    record_failure "curl is required for SORA Nexus live health check"
    return
  fi
  if ! command -v node >/dev/null 2>&1; then
    record_failure "node is required for SORA Nexus live health response validation"
    return
  fi

  local health_path="$NEXUS_HEALTH_PATH_VALUE"
  local health_url="${nexus_base_url}${health_path}"
  local timeout="$NEXUS_HEALTH_TIMEOUT_VALUE"
  local attempts="$NEXUS_HEALTH_ATTEMPTS_VALUE"
  local delay="$NEXUS_HEALTH_RETRY_DELAY_VALUE"
  local metadata http_status content_type status attempt response_bytes curl_error diagnostic
  local curl_version_output curl_version major_version minor_version
  local health_tmp_dir response_file error_file
  set +e
  curl_version_output="$(run_isolated_nexus_curl --disable --version 2>/dev/null)"
  status=$?
  set -e
  curl_version="$(printf '%s\n' "$curl_version_output" | sed -nE '1s/^curl ([0-9]+)\.([0-9]+)\..*$/\1.\2/p')"
  if [[ "$status" -ne 0 || ! "$curl_version" =~ ^([0-9]+)\.([0-9]+)$ ]]; then
    record_failure "curl version could not be verified for the SORA Nexus live health response-size contract"
    return
  fi
  major_version="${BASH_REMATCH[1]}"
  minor_version="${BASH_REMATCH[2]}"
  if ((major_version < 8 || (major_version == 8 && minor_version < 4))); then
    record_failure "curl 8.4 or newer is required so --max-filesize bounds unknown-length SORA Nexus health responses"
    return
  fi
  health_tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/fearless-nexus-health.XXXXXX")" || {
    record_failure "Unable to create a temporary directory for SORA Nexus live health validation"
    return
  }
  temporary_paths+=("$health_tmp_dir")
  response_file="$health_tmp_dir/response.bin"
  error_file="$health_tmp_dir/curl-error.txt"

  log "Checking live SORA Nexus Torii health at $health_url"

  status=0
  diagnostic="health request failed without diagnostic output"
  for ((attempt = 1; attempt <= attempts; attempt += 1)); do
    : > "$response_file"
    : > "$error_file"
    set +e
    metadata="$(
      run_isolated_nexus_curl --disable -sS \
        --proto '=https' \
        --proto-redir '=https' \
        --tlsv1.2 \
        --max-redirs 0 \
        --connect-timeout "$timeout" \
        --max-time "$timeout" \
        --max-filesize 131072 \
        --header 'Accept: application/json' \
        --output "$response_file" \
        --write-out '__NEXUS_HTTP_META__%{http_code}|%{content_type}' \
        "$health_url" 2>"$error_file"
    )"
    status=$?
    set -e

    response_bytes="$(LC_ALL=C wc -c < "$response_file" | tr -d '[:space:]')"
    curl_error="$(LC_ALL=C head -c "$NEXUS_DIAGNOSTIC_SCAN_BYTES" "$error_file")"

    if [[ "$response_bytes" =~ ^[0-9]+$ ]] && ((response_bytes > NEXUS_HEALTH_MAX_RESPONSE_BYTES)); then
      status=63
      diagnostic="response exceeded $NEXUS_HEALTH_MAX_RESPONSE_BYTES bytes for $health_url"
    elif [[ "$status" -eq 63 ]]; then
      diagnostic="response exceeded the enforced $NEXUS_HEALTH_MAX_RESPONSE_BYTES-byte limit for $health_url"
    elif [[ "$status" -eq 0 && "$metadata" == __NEXUS_HTTP_META__* ]]; then
      metadata="${metadata#__NEXUS_HTTP_META__}"
      http_status="${metadata%%|*}"
      content_type="${metadata#*|}"
      if [[ "$http_status" != "200" ]]; then
        status=22
        diagnostic="HTTP $http_status returned for $health_url; response body withheld"
      elif [[ "${content_type%%;*}" != "application/json" ]]; then
        status=22
        diagnostic="unexpected Content-Type ${content_type:-<missing>} for $health_url; response body withheld"
      else
        diagnostic=""
      fi
    elif [[ "$status" -eq 0 ]]; then
      status=22
      diagnostic="curl response metadata was missing or malformed for $health_url"
    else
      diagnostic="curl transport failed for $health_url: $(diagnostic_preview "$curl_error")"
    fi

    if [[ "$status" -eq 0 ]]; then
      break
    fi

    if ((attempt < attempts)); then
      warn "SORA Nexus Torii live health attempt $attempt/$attempts failed for $health_url. $(diagnostic_preview "$diagnostic"). Retrying."
      if ((delay > 0)); then
        sleep "$delay"
      fi
    fi
  done

  if [[ "$status" -ne 0 ]]; then
    record_failure "SORA Nexus Torii live health check failed for $health_url. $(diagnostic_preview "$diagnostic"). Verify Minamoto DNS/TLS/routing and that Torii serves exactly /status."
    rm -rf "$health_tmp_dir"
    return
  fi

  local output
  set +e
  output="$(
    env NEXUS_HEALTH_RESPONSE_FILE="$response_file" \
      NEXUS_HEALTH_MAX_BLOCK_AGE_MS="$NEXUS_HEALTH_MAX_BLOCK_AGE_MS" \
      NEXUS_EXPECTED_BUILD_COMMIT="$NEXUS_EXPECTED_BUILD_COMMIT_VALUE" \
      NEXUS_EXPECTED_CHAIN_ID="$NEXUS_EXPECTED_CHAIN_ID_VALUE" \
      NEXUS_EXPECTED_GENESIS_HASH="$NEXUS_EXPECTED_GENESIS_HASH_VALUE" \
      node <<'NODE' 2>&1
const fs = require('node:fs');
class HealthValidationError extends Error {}
const fail = (message) => { throw new HealthValidationError(message); };
const object = (value, label) => {
  if (!value || typeof value !== 'object' || Array.isArray(value)) fail(`${label} must be an object`);
  return value;
};
const uint = (value, label, { positive = false } = {}) => {
  if (!Number.isSafeInteger(value) || value < (positive ? 1 : 0)) {
    fail(`${label} must be a ${positive ? 'positive ' : ''}safe integer`);
  }
  return value;
};
const text = (value, label) => {
  if (typeof value !== 'string' || value.trim().length === 0 || value.length > 512 || /[\u0000-\u001f\u007f]/u.test(value)) {
    fail(`${label} must be a non-empty single-line string`);
  }
  return value.trim();
};

try {
  let data;
  try {
    data = JSON.parse(fs.readFileSync(process.env.NEXUS_HEALTH_RESPONSE_FILE, 'utf8'));
  } catch {
    fail('health response must be valid JSON');
  }

  object(data, 'health response');
  if (!Object.hasOwn(data, 'chain_id')) {
    fail('chain_id must be an exact top-level /status field');
  }
  if (typeof data.chain_id !== 'string' ||
      data.chain_id.length < 1 ||
      data.chain_id.length > 128 ||
      !/^[a-z0-9]+(?:[._:-][a-z0-9]+)*$/u.test(data.chain_id)) {
    fail("chain_id must be a canonical lowercase ASCII identifier of at most 128 bytes");
  }
  const expectedChainId = process.env.NEXUS_EXPECTED_CHAIN_ID || '';
  if (expectedChainId.length < 1 ||
      expectedChainId.length > 128 ||
      !/^[a-z0-9]+(?:[._:-][a-z0-9]+)*$/u.test(expectedChainId)) {
    fail('expected chain ID configuration must be a canonical lowercase ASCII identifier of at most 128 bytes');
  }
  if (data.chain_id !== expectedChainId) {
    fail('chain_id must exactly match NEXUS_EXPECTED_CHAIN_ID');
  }

  if (!Object.hasOwn(data, 'genesis_hash')) {
    fail('genesis_hash must be an exact top-level /status field');
  }
  if (typeof data.genesis_hash !== 'string' ||
      !/^[0-9a-f]{64}$/u.test(data.genesis_hash) ||
      /^([0-9a-f])\1+$/u.test(data.genesis_hash)) {
    fail('genesis_hash must be an exact non-placeholder 64-character lowercase hexadecimal hash');
  }
  const expectedGenesisHash = process.env.NEXUS_EXPECTED_GENESIS_HASH || '';
  if (!/^[0-9a-f]{64}$/u.test(expectedGenesisHash) ||
      /^([0-9a-f])\1+$/u.test(expectedGenesisHash)) {
    fail('expected genesis hash configuration must be an exact non-placeholder 64-character lowercase hexadecimal hash');
  }
  if (data.genesis_hash !== expectedGenesisHash) {
    fail('genesis_hash must exactly match NEXUS_EXPECTED_GENESIS_HASH');
  }

  const observedAt = uint(data.observed_at_ms, 'observed_at_ms', { positive: true });
  const now = Date.now();
  const observationAge = now - observedAt;
  if (observationAge < -30_000 || observationAge > 5 * 60 * 1000) {
    fail('observed_at_ms must be no more than 30 seconds ahead or five minutes behind the verifier clock');
  }
  const blocks = uint(data.blocks, 'blocks', { positive: true });
  const blocksNonEmpty = uint(data.blocks_non_empty, 'blocks_non_empty');
  if (blocksNonEmpty > blocks) fail('blocks_non_empty must not exceed blocks');
  const queueSize = uint(data.queue_size, 'queue_size');
  const queueQueued = uint(data.queue_queued, 'queue_queued');
  const queueInflight = uint(data.queue_inflight, 'queue_inflight');
  if (queueQueued + queueInflight !== queueSize) fail('queue_size must equal queue_queued plus queue_inflight');
  uint(data.peers, 'peers', { positive: true });
  uint(data.txs_approved, 'txs_approved');
  uint(data.txs_rejected, 'txs_rejected');
  const lastBlockAt = uint(data.last_block_committed_at_ms, 'last_block_committed_at_ms', { positive: true });
  const sinceLastBlock = uint(data.time_since_last_block_ms, 'time_since_last_block_ms');
  if (lastBlockAt > observedAt) fail('last_block_committed_at_ms must not exceed observed_at_ms');
  if (Math.abs((observedAt - lastBlockAt) - sinceLastBlock) > 5000) {
    fail('time_since_last_block_ms must match the observed and committed block timestamps');
  }
  const maxBlockAge = Number(process.env.NEXUS_HEALTH_MAX_BLOCK_AGE_MS);
  if (!Number.isSafeInteger(maxBlockAge) || maxBlockAge < 1 || sinceLastBlock > maxBlockAge) {
    fail('time_since_last_block_ms must show a block committed within the last five minutes');
  }
  const verifierBlockAge = now - lastBlockAt;
  if (verifierBlockAge < -30_000 || verifierBlockAge > maxBlockAge) {
    fail('last_block_committed_at_ms must be no more than 30 seconds ahead and must be within five minutes of the verifier clock');
  }

  const build = object(data.build, 'build');
  text(build.version, 'build.version');
  const commit = text(build.git_commit_sha, 'build.git_commit_sha');
  if (!/^[0-9a-f]{7,64}$/u.test(commit) || /^([0-9a-f])\1+$/u.test(commit)) {
    fail('build.git_commit_sha must be a non-placeholder hexadecimal commit');
  }
  if (!/^(?:[0-9a-f]{40}|[0-9a-f]{64})$/u.test(process.env.NEXUS_EXPECTED_BUILD_COMMIT || '')) {
    fail('expected build commit configuration must be an exact 40- or 64-character hexadecimal commit');
  }
  if (commit !== process.env.NEXUS_EXPECTED_BUILD_COMMIT) {
    fail('build.git_commit_sha must exactly match NEXUS_EXPECTED_BUILD_COMMIT');
  }
  text(build.target_triple, 'build.target_triple');
  const nexus = object(data.nexus, 'nexus');
  const routing = object(nexus.routing_policy, 'nexus.routing_policy');
  uint(routing.default_lane, 'nexus.routing_policy.default_lane');
  uint(routing.default_dataspace, 'nexus.routing_policy.default_dataspace');
  if (!Array.isArray(routing.rules) || routing.rules.length === 0) {
    fail('nexus.routing_policy.rules must be a non-empty array');
  }
  routing.rules.forEach((candidate, index) => {
    const rule = object(candidate, `nexus.routing_policy.rules[${index}]`);
    uint(rule.lane, `nexus.routing_policy.rules[${index}].lane`);
    if (Object.hasOwn(rule, 'dataspace_id')) {
      uint(rule.dataspace_id, `nexus.routing_policy.rules[${index}].dataspace_id`);
    }
    const matcher = object(rule.matcher, `nexus.routing_policy.rules[${index}].matcher`);
    let hasSelector = false;
    for (const selector of ['account', 'instruction']) {
      if (Object.hasOwn(matcher, selector)) {
        text(matcher[selector], `nexus.routing_policy.rules[${index}].matcher.${selector}`);
        hasSelector = true;
      }
    }
    if (Object.hasOwn(matcher, 'description')) {
      text(matcher.description, `nexus.routing_policy.rules[${index}].matcher.description`);
    }
    if (!hasSelector) {
      fail(`nexus.routing_policy.rules[${index}].matcher must contain account or instruction`);
    }
  });
  const expectedRouting = {
    default_lane: 0,
    default_dataspace: 0,
    rules: [
      {
        lane: 1,
        dataspace_id: 1,
        matcher: {
          instruction: 'governance',
          description: 'Route governance instructions to the governance lane',
        },
      },
      {
        lane: 2,
        dataspace_id: 2,
        matcher: {
          instruction: 'smartcontract::deploy',
          description: 'Route contract deployments to the zk lane for proof tracking',
        },
      },
    ],
  };
  if (JSON.stringify(routing) !== JSON.stringify(expectedRouting)) {
    fail('nexus.routing_policy must exactly match the canonical ordered SORA 0/0, governance 1/1, and smartcontract::deploy 2/2 policy');
  }

  if (!Array.isArray(data.dataspace_catalog) || data.dataspace_catalog.length === 0) {
    fail('dataspace_catalog must be a non-empty array');
  }
  const catalog = new Map();
  data.dataspace_catalog.forEach((candidate, index) => {
    const entry = object(candidate, `dataspace_catalog[${index}]`);
    const lane = uint(entry.lane_id, `dataspace_catalog[${index}].lane_id`);
    const dataspace = uint(entry.dataspace_id, `dataspace_catalog[${index}].dataspace_id`);
    text(entry.lane_alias, `dataspace_catalog[${index}].lane_alias`);
    text(entry.alias, `dataspace_catalog[${index}].alias`);
    text(entry.visibility, `dataspace_catalog[${index}].visibility`);
    text(entry.storage_profile, `dataspace_catalog[${index}].storage_profile`);
    for (const field of ['manifest_required', 'manifest_ready', 'sealed']) {
      if (typeof entry[field] !== 'boolean') fail(`dataspace_catalog[${index}].${field} must be a boolean`);
    }
    const key = `${lane}/${dataspace}`;
    if (catalog.has(key)) fail(`dataspace_catalog contains duplicate lane/dataspace target ${key}`);
    catalog.set(key, entry);
  });
  for (const key of ['0/0', '1/1', '2/2']) {
    const entry = catalog.get(key);
    if (!entry) fail(`dataspace_catalog must contain canonical routing target ${key}`);
    if (entry.sealed) fail(`dataspace_catalog routing target ${key} must not be sealed`);
    if (entry.manifest_required && !entry.manifest_ready) {
      fail(`dataspace_catalog routing target ${key} requires a ready governance manifest`);
    }
  }
} catch (error) {
  const message = error instanceof HealthValidationError
    ? error.message
    : 'health response validation failed';
  process.stderr.write(`${message}\n`);
  process.exitCode = 1;
}
NODE
)"
  local status=$?
  set -e
  rm -rf "$health_tmp_dir"

  if [[ "$status" -ne 0 ]]; then
    record_failure "SORA Nexus Torii live health response invalid for $health_url: $(diagnostic_preview "$output")"
  fi
}

check_nexus_production_evidence() {
  require_file "$NEXUS_PRODUCTION_EVIDENCE_FILE" "SORA Nexus production evidence manifest"
  require_executable_file "$NEXUS_PRODUCTION_EVIDENCE_AUDIT" "SORA Nexus production evidence audit"
  require_executable_file "$NEXUS_PRODUCTION_EVIDENCE_TEST" "SORA Nexus production evidence audit self-test"
  require_pattern "$NEXUS_PRODUCTION_EVIDENCE_AUDIT" 'assertNoSecretLikeValues\(manifest\)' "SORA Nexus production evidence secret-like value gate"
  require_pattern "$NEXUS_PRODUCTION_EVIDENCE_TEST" 'secret-like Nexus evidence value' "SORA Nexus production evidence secret-like value negative test"
  require_pattern "$NEXUS_PRODUCTION_EVIDENCE_AUDIT" "const EXPECTED_CHAIN_ID = '${NEXUS_PRODUCTION_EVIDENCE_CHAIN_ID}';" "SORA Nexus production evidence chain identity authority"

  if [[ "$NEXUS_PRODUCTION_EVIDENCE_REQUIRED" == "true" &&
        "$NEXUS_EXPECTED_CHAIN_ID_VALUE" != "$NEXUS_PRODUCTION_EVIDENCE_CHAIN_ID" ]]; then
    record_failure "Strict SORA Nexus production evidence requires committed NEXUS_EXPECTED_CHAIN_ID to equal ${NEXUS_PRODUCTION_EVIDENCE_CHAIN_ID}; resolved ${NEXUS_EXPECTED_CHAIN_ID_VALUE:-<unset>}"
  fi

  if [[ ! -f "$NEXUS_PRODUCTION_EVIDENCE_FILE" || ! -x "$NEXUS_PRODUCTION_EVIDENCE_AUDIT" ]]; then
    return
  fi

  local args=(--evidence "$NEXUS_PRODUCTION_EVIDENCE_FILE")
  if [[ "$NEXUS_PRODUCTION_EVIDENCE_REQUIRED" == "true" ]]; then
    args+=(--require-ready)
  fi

  run_step \
    "SORA Nexus production evidence audit" \
    run_isolated_nexus_evidence_audit \
    "$NEXUS_PRODUCTION_EVIDENCE_AUDIT" \
    "${args[@]}"
}

check_taira_release_readiness() {
  require_executable_file "$TAIRA_RELEASE_AUDIT" "SORA Taira release readiness audit"
  require_executable_file "$TAIRA_RELEASE_AUDIT_TEST" "SORA Taira release readiness self-test"

  local live="${IROHA_TAIRA_LIVE_HEALTH-0}"
  local expected_commit="$TAIRA_PROCESS_EXPECTED_BUILD_COMMIT"
  if [[ "$TAIRA_COMMITTED_BUILD_COMMIT_SEEN" == "true" ]]; then
    if ! validate_build_commit_pin "committed TAIRA_EXPECTED_BUILD_COMMIT" "$TAIRA_COMMITTED_BUILD_COMMIT"; then
      expected_commit=""
    else
      expected_commit="$TAIRA_COMMITTED_BUILD_COMMIT"
    fi
    if [[ "$TAIRA_PROCESS_EXPECTED_BUILD_COMMIT_SET" == "true" &&
          "$TAIRA_PROCESS_EXPECTED_BUILD_COMMIT" != "$TAIRA_COMMITTED_BUILD_COMMIT" ]]; then
      record_failure "process TAIRA_EXPECTED_BUILD_COMMIT must not override the committed Taira build pin"
    fi
  elif [[ "$live" == "1" || "$live" == "true" ]]; then
    record_failure "TAIRA_EXPECTED_BUILD_COMMIT must be pinned in the committed Iroha release defaults when live Taira health is enabled"
    expected_commit=""
  fi

  if [[ -x "$TAIRA_RELEASE_AUDIT_TEST" ]]; then
    run_step "SORA Taira release readiness self-test" node "$TAIRA_RELEASE_AUDIT_TEST"
  fi
  if [[ -x "$TAIRA_RELEASE_AUDIT" ]]; then
    run_step \
      "SORA Taira release readiness audit" \
      env \
      IROHA_READINESS_ROOT="$ROOT_DIR" \
      IROHA_READINESS_PARENT="$PARENT_DIR" \
      IROHA_TAIRA_LIVE_HEALTH="$live" \
      TAIRA_EXPECTED_BUILD_COMMIT="$expected_commit" \
      "$TAIRA_RELEASE_AUDIT"
  fi
}

load_release_config_defaults
validate_nexus_runtime_settings
check_iroha_release_tooling
check_mobile_wallet_validators
check_web_js_sdk_artifact

if normalize_nexus_torii_url; then
  :
else
  NEXUS_BASE_URL=""
fi
check_nexus_sources "$NEXUS_BASE_URL"
check_nexus_live_health "$NEXUS_BASE_URL"
check_nexus_production_evidence
check_taira_release_readiness

if ((${#failures[@]} > 0)); then
  echo "[iroha-readiness][error] Iroha Taira/Nexus release readiness failed:" >&2
  printf '  - %s\n' "${failures[@]}" >&2
  exit 1
fi

log "Iroha Taira/Nexus release readiness passed."
