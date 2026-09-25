#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
WORKSPACE_ROOT="$(cd "$SCRIPT_DIR/.." && pwd -P)"
AUDIT="$SCRIPT_DIR/audit-source-publication-readiness.mjs"

fail() {
  echo "[source-publication-runner][error] $*" >&2
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
    printf '%s' "$candidate"
    return 0
  done
  return 1
}

[[ -f "$AUDIT" && ! -L "$AUDIT" ]] || fail "audit module must be a regular non-symlink file: $AUDIT"
[[ -z "${NODE_OPTIONS+x}" ]] || fail "NODE_OPTIONS is forbidden before the source-publication Node process starts"

node_bin=""
if [[ -z "${SOURCE_PUBLICATION_WRAPPER_TEST_MODE+x}" ]]; then
  for forbidden in NODE_BIN SOURCE_PUBLICATION_NODE_BIN SOURCE_PUBLICATION_WRAPPER_TEST_ROOT; do
    [[ -z "${!forbidden+x}" ]] || fail "$forbidden is forbidden outside explicit SOURCE_PUBLICATION_WRAPPER_TEST_MODE=1"
  done
  node_bin="$(resolve_canonical_node)" || fail "canonical Node executable is unavailable"
elif [[ "$SOURCE_PUBLICATION_WRAPPER_TEST_MODE" == "1" ]]; then
  [[ -z "${NODE_BIN+x}" ]] || fail "NODE_BIN is unsupported; use SOURCE_PUBLICATION_NODE_BIN in isolated wrapper test mode"
  [[ -n "${SOURCE_PUBLICATION_WRAPPER_TEST_ROOT:-}" ]] || fail "SOURCE_PUBLICATION_WRAPPER_TEST_ROOT is required in test mode"
  [[ -n "${SOURCE_PUBLICATION_NODE_BIN:-}" ]] || fail "SOURCE_PUBLICATION_NODE_BIN is required in test mode"
  [[ "$SOURCE_PUBLICATION_WRAPPER_TEST_ROOT" == /* && "$SOURCE_PUBLICATION_NODE_BIN" == /* ]] ||
    fail "test root and Node executable must be absolute paths"
  test_root="$(canonical_path "$SOURCE_PUBLICATION_WRAPPER_TEST_ROOT")" || fail "test root is unavailable"
  node_bin="$(canonical_path "$SOURCE_PUBLICATION_NODE_BIN")" || fail "test Node executable is unavailable"
  [[ "$test_root" == "$SOURCE_PUBLICATION_WRAPPER_TEST_ROOT" && -d "$test_root" && ! -L "$test_root" ]] ||
    fail "test root must be an existing normalized non-symlink directory"
  [[ "$node_bin" == "$SOURCE_PUBLICATION_NODE_BIN" && -f "$node_bin" && -x "$node_bin" && ! -L "$node_bin" ]] ||
    fail "test Node executable must be an existing normalized regular executable"
  [[ "$node_bin" == "$test_root"/* ]] || fail "test Node executable must be contained by the isolated test root"
  [[ "$test_root" != "$WORKSPACE_ROOT" && "$test_root" != "$WORKSPACE_ROOT"/* && "$WORKSPACE_ROOT" != "$test_root"/* ]] ||
    fail "wrapper test root must be isolated from the production workspace"
else
  fail "SOURCE_PUBLICATION_WRAPPER_TEST_MODE must be unset or 1"
fi

exec /usr/bin/env \
  -u NODE_OPTIONS \
  -u NODE_BIN \
  -u SOURCE_PUBLICATION_NODE_BIN \
  -u SOURCE_PUBLICATION_WRAPPER_TEST_MODE \
  -u SOURCE_PUBLICATION_WRAPPER_TEST_ROOT \
  "$node_bin" "$AUDIT" "$@"
