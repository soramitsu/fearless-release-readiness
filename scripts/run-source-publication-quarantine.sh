#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
HELPER="$SCRIPT_DIR/quarantine-source-publication-outputs.mjs"

fail() {
  echo "[source-publication-quarantine-runner][error] $*" >&2
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
    printf '%s' "$resolved"
    return 0
  done
  return 1
}

[[ -f "$HELPER" && ! -L "$HELPER" ]] || fail "helper must be a regular non-symlink file: $HELPER"
[[ -z "${NODE_OPTIONS+x}" ]] || fail "NODE_OPTIONS is forbidden"
while IFS= read -r name; do
  [[ "$name" == SOURCE_PUBLICATION_QUARANTINE_* ]] || continue
  fail "$name is forbidden in production mode"
done < <(compgen -A variable)

node_bin="$(resolve_canonical_node)" || fail "canonical Node executable is unavailable"
exec /usr/bin/env -u NODE_OPTIONS "$node_bin" "$HELPER" "$@"
