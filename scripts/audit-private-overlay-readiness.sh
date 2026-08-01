#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="${PRIVATE_OVERLAY_AUDIT_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
REPORT_DIR="${PRIVATE_OVERLAY_AUDIT_REPORT_DIR:-$ROOT_DIR/build/reports/private-overlays}"
MAX_REPORT_LINES="${MAX_REPORT_LINES:-40}"
ALLOW_MISSING=false
RUN_SELF_TESTS=true

usage() {
  cat <<'USAGE'
Usage: scripts/audit-private-overlay-readiness.sh [--allow-missing] [--skip-self-tests]

Runs the Android and iOS private-overlay boundary audits together and writes
stable TSV remediation reports under build/reports/private-overlays by default.

Options:
  --allow-missing    Do not fail when a private checkout is absent.
  --skip-self-tests  Skip platform overlay audit self-tests before real audits.

Environment:
  PRIVATE_OVERLAY_AUDIT_ROOT        Workspace root containing fearless-* repos.
  PRIVATE_OVERLAY_AUDIT_REPORT_DIR  Directory for android/ios TSV reports.
  MAX_REPORT_LINES                  Console preview lines per platform audit.
USAGE
}

while (($#)); do
  case "$1" in
    --allow-missing)
      ALLOW_MISSING=true
      ;;
    --skip-self-tests)
      RUN_SELF_TESTS=false
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "[private-overlay-readiness][error] Unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
  shift
done

failures=()

log() { echo "[private-overlay-readiness] $*"; }
warn() { echo "[private-overlay-readiness][warn] $*" >&2; }

record_failure() {
  failures+=("$1")
  warn "$1"
}

run_platform_audit() {
  local platform="$1"
  local public_repo="$2"
  local private_repo="$3"
  local report="$REPORT_DIR/${platform}-private-overlay-boundary.tsv"

  log "Checking $platform private overlay"

  if [[ ! -d "$public_repo/.git" ]]; then
    record_failure "$platform public repo missing or not a Git checkout: $public_repo"
    return
  fi

  if [[ ! -d "$private_repo/.git" ]]; then
    if [[ "$ALLOW_MISSING" == true ]]; then
      warn "$platform private repo missing; skipped because --allow-missing was set: $private_repo"
      return
    fi
    record_failure "$platform private repo missing or not a Git checkout: $private_repo"
    return
  fi

  if [[ "$RUN_SELF_TESTS" == true ]]; then
    if [[ ! -x "$public_repo/scripts/test-private-overlay-boundary.sh" ]]; then
      record_failure "$platform private-overlay self-test is missing or not executable"
      return
    fi
    if ! (cd "$public_repo" && bash ./scripts/test-private-overlay-boundary.sh); then
      record_failure "$platform private-overlay self-test failed"
      return
    fi
  fi

  if [[ ! -x "$public_repo/scripts/audit-private-overlay-boundary.sh" ]]; then
    record_failure "$platform private-overlay audit is missing or not executable"
    return
  fi

  mkdir -p "$REPORT_DIR"
  rm -f "$report"

  if (
    cd "$public_repo"
    PUBLIC_REPO_DIR="$public_repo" \
      PRIVATE_REPO_DIR="$private_repo" \
      PRIVATE_OVERLAY_REPORT="$report" \
      MAX_REPORT_LINES="$MAX_REPORT_LINES" \
      bash ./scripts/audit-private-overlay-boundary.sh
  ); then
    log "$platform private overlay passed"
  else
    local count="unknown"
    if [[ -f "$report" ]]; then
      count="$(wc -l < "$report" | tr -d '[:space:]')"
    fi
    record_failure "$platform private overlay is not release-ready: $count unexpected paths; report=$report"
  fi
}

run_platform_audit \
  "android" \
  "$ROOT_DIR/fearless-Android" \
  "$ROOT_DIR/fearless-Android-priv"

run_platform_audit \
  "ios" \
  "$ROOT_DIR/fearless-iOS" \
  "$ROOT_DIR/fearless-iOS-priv"

if ((${#failures[@]} > 0)); then
  echo "[private-overlay-readiness][error] Private overlay readiness audit failed:" >&2
  printf '  - %s\n' "${failures[@]}" >&2
  exit 1
fi

log "Private overlay readiness audit passed."
