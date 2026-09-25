#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR_INPUT="${IROHA_SEND_AGGREGATE_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
if ! ROOT_DIR="$(cd "$ROOT_DIR_INPUT" 2>/dev/null && pwd -P)"; then
  echo "[iroha-production-send-readiness][error] aggregate root is not an accessible directory: $ROOT_DIR_INPUT" >&2
  exit 1
fi

failures=()

record_failure() {
  failures+=("$1")
  echo "[iroha-production-send-readiness][warn] $1" >&2
}

run_gate() {
  local platform="$1"
  local repo="$2"
  local path="$3"
  local label="$4"
  local repo_input="$repo"
  if ! repo="$(cd "$repo" 2>/dev/null && pwd -P)"; then
    record_failure "$platform repository is missing or is not an accessible directory: $repo_input"
    return
  fi
  path="$repo/scripts/$(basename "$path")"
  if [[ ! -f "$path" || -L "$path" ]]; then
    record_failure "$platform $label is missing or is not a regular file: $path"
    return
  fi
  if [[ ! -x "$path" ]]; then
    record_failure "$platform $label is not executable: $path"
    return
  fi
  if ! (
    cd "$repo" || exit 1
    IROHA_SEND_AUDIT_ROOT="$repo" bash "$path"
  ); then
    record_failure "$platform $label failed"
  fi
}

run_platform() {
  local platform="$1"
  local repo="$2"
  run_gate "$platform" "$repo" "test-iroha-production-send-readiness-audit.sh" "adversarial self-test"
  run_gate "$platform" "$repo" "audit-iroha-production-send-readiness.sh" "blocked-readiness audit"
}

run_platform "android" "$ROOT_DIR/fearless-Android-production-consolidated-20260731"
run_platform "ios" "$ROOT_DIR/fearless-iOS-production-consolidated-20260731"
run_platform "browser-extension" "$ROOT_DIR/fearless-wallet-web"

if ((${#failures[@]} > 0)); then
  echo "[iroha-production-send-readiness][error] aggregate failed with ${#failures[@]} issue(s)" >&2
  exit 1
fi

echo "[iroha-production-send-readiness] all platform blocker contracts and fail-closed seams passed."
