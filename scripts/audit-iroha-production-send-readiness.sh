#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="${IROHA_SEND_AGGREGATE_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"

failures=()

record_failure() {
  failures+=("$1")
  echo "[iroha-production-send-readiness][warn] $1" >&2
}

run_gate() {
  local platform="$1"
  local path="$2"
  local label="$3"
  if [[ ! -f "$path" || -L "$path" ]]; then
    record_failure "$platform $label is missing or is not a regular file: $path"
    return
  fi
  if [[ ! -x "$path" ]]; then
    record_failure "$platform $label is not executable: $path"
    return
  fi
  if ! bash "$path"; then
    record_failure "$platform $label failed"
  fi
}

run_platform() {
  local platform="$1"
  local repo="$2"
  run_gate "$platform" "$repo/scripts/test-iroha-production-send-readiness-audit.sh" "adversarial self-test"
  run_gate "$platform" "$repo/scripts/audit-iroha-production-send-readiness.sh" "blocked-readiness audit"
}

run_platform "android" "$ROOT_DIR/fearless-Android"
run_platform "ios" "$ROOT_DIR/fearless-iOS"
run_platform "browser-extension" "$ROOT_DIR/fearless-wallet-web"

if ((${#failures[@]} > 0)); then
  echo "[iroha-production-send-readiness][error] aggregate failed with ${#failures[@]} issue(s)" >&2
  exit 1
fi

echo "[iroha-production-send-readiness] all platform blocker contracts and fail-closed seams passed."
