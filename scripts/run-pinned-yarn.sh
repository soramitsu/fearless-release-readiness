#!/usr/bin/env bash
set -euo pipefail

EXPECTED_YARN_VERSION="4.10.3"
COREPACK_PACKAGE="corepack@0.34.6"
TEST_MODE="${PINNED_YARN_TEST_MODE:-0}"

fail() {
  echo "[pinned-yarn][error] $*" >&2
  exit 2
}

resolve_canonical_tool() {
  local name="$1"
  local candidate resolved
  for candidate in "/usr/bin/$name" "/usr/local/bin/$name" "/opt/homebrew/bin/$name"; do
    [[ -e "$candidate" ]] || continue
    resolved="$(/bin/realpath "$candidate" 2>/dev/null || true)"
    [[ -n "$resolved" && -f "$resolved" && -x "$resolved" ]] || continue
    printf '%s' "$candidate"
    return 0
  done
  return 1
}

case "$TEST_MODE" in
  0)
    for forbidden in NODE_BIN NPM_BIN NODE_OPTIONS NPM_CONFIG_USERCONFIG npm_config_userconfig NPM_CONFIG_REGISTRY npm_config_registry COREPACK_HOME COREPACK_NPM_REGISTRY COREPACK_INTEGRITY_KEYS PINNED_YARN_NODE_BIN PINNED_YARN_NPM_BIN; do
      [[ -z "${!forbidden+x}" ]] || fail "$forbidden is forbidden outside explicit PINNED_YARN_TEST_MODE=1"
    done
    NODE_BIN="$(resolve_canonical_tool node)" || fail "canonical node executable is unavailable"
    NPM_BIN="$(resolve_canonical_tool npm)" || fail "canonical npm executable is unavailable"
    ;;
  1)
    NODE_BIN="${PINNED_YARN_NODE_BIN:-}"
    NPM_BIN="${PINNED_YARN_NPM_BIN:-}"
    [[ "$NODE_BIN" == /* && -f "$NODE_BIN" && -x "$NODE_BIN" ]] || fail "test node executable must be an absolute executable file"
    [[ "$NPM_BIN" == /* && -f "$NPM_BIN" && -x "$NPM_BIN" ]] || fail "test npm executable must be an absolute executable file"
    ;;
  *)
    fail "PINNED_YARN_TEST_MODE must be 0 or 1"
    ;;
esac

[[ -f package.json ]] || fail "package.json is missing in $PWD"

package_manager="$("$NODE_BIN" -e 'const fs=require("fs"); const value=JSON.parse(fs.readFileSync("package.json","utf8")).packageManager; process.stdout.write(typeof value === "string" ? value : "")')"
if [[ "$package_manager" != "yarn@$EXPECTED_YARN_VERSION" ]]; then
  fail "packageManager must be yarn@$EXPECTED_YARN_VERSION, received ${package_manager:-<missing>}"
fi

# Never trust PATH-provided Yarn/Corepack binaries. The exact Corepack package
# is resolved through the canonical npm executable and then enforces the
# repository-declared Yarn version.
runner=("$NPM_BIN" exec --yes --ignore-scripts --registry=https://registry.npmjs.org --package="$COREPACK_PACKAGE" -- corepack yarn)

actual_version="$("${runner[@]}" --version)"
if [[ "$actual_version" != "$EXPECTED_YARN_VERSION" ]]; then
  fail "resolved Yarn version must be $EXPECTED_YARN_VERSION, received $actual_version"
fi

exec "${runner[@]}" "$@"
