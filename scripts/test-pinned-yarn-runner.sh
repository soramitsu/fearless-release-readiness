#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
RUNNER="$SCRIPT_DIR/run-pinned-yarn.sh"
REAL_NODE="$(command -v node)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

fail() {
  echo "[pinned-yarn-test][error] $*" >&2
  exit 1
}

write_package() {
  local value="$1"
  printf '{"packageManager":"%s"}\n' "$value" > "$TMP_DIR/package.json"
}

mkdir -p "$TMP_DIR/bin"
cat > "$TMP_DIR/bin/yarn" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "PATH yarn must never execute" >&2
exit 97
SH
chmod +x "$TMP_DIR/bin/yarn"

cat > "$TMP_DIR/bin/corepack" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "PATH corepack must never execute" >&2
exit 98
SH
chmod +x "$TMP_DIR/bin/corepack"

cat > "$TMP_DIR/bin/npm" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
[[ "$#" -ge 8 && "$1" == exec && "$2" == --yes && "$3" == --ignore-scripts && "$4" == --registry=https://registry.npmjs.org && "$5" == --package=corepack@0.34.6 && "$6" == -- && "$7" == corepack && "$8" == yarn ]] || {
  printf 'unexpected npm arguments: %s\n' "$*" >&2
  exit 96
}
shift 8
if [[ "${1:-}" == "--version" ]]; then
  printf '%s\n' "${FAKE_YARN_VERSION:-4.10.3}"
  exit 0
fi
printf '%s\n' "$*" >> "$FAKE_YARN_LOG"
SH
chmod +x "$TMP_DIR/bin/npm"

write_package yarn@4.10.3
FAKE_YARN_LOG="$TMP_DIR/yarn.log" PATH="$TMP_DIR/bin:/usr/bin:/bin" PINNED_YARN_TEST_MODE=1 \
  PINNED_YARN_NODE_BIN="$REAL_NODE" PINNED_YARN_NPM_BIN="$TMP_DIR/bin/npm" \
  bash -c 'cd "$1" && exec "$2" smoke:production --strict' _ "$TMP_DIR" "$RUNNER"
[[ "$(cat "$TMP_DIR/yarn.log")" == "smoke:production --strict" ]] || fail "runner did not preserve Yarn arguments"

write_package yarn@4.9.1
if FAKE_YARN_LOG="$TMP_DIR/yarn.log" PATH="$TMP_DIR/bin:/usr/bin:/bin" PINNED_YARN_TEST_MODE=1 \
  PINNED_YARN_NODE_BIN="$REAL_NODE" PINNED_YARN_NPM_BIN="$TMP_DIR/bin/npm" \
  bash -c 'cd "$1" && exec "$2" --version' _ "$TMP_DIR" "$RUNNER" >"$TMP_DIR/out" 2>"$TMP_DIR/err"; then
  fail "mismatched packageManager unexpectedly passed"
fi
grep -q 'packageManager must be yarn@4.10.3' "$TMP_DIR/err" || fail "mismatched packageManager diagnostic missing"

write_package yarn@4.10.3
if FAKE_YARN_VERSION=4.9.1 FAKE_YARN_LOG="$TMP_DIR/yarn.log" PATH="$TMP_DIR/bin:/usr/bin:/bin" PINNED_YARN_TEST_MODE=1 \
  PINNED_YARN_NODE_BIN="$REAL_NODE" PINNED_YARN_NPM_BIN="$TMP_DIR/bin/npm" \
  bash -c 'cd "$1" && exec "$2" --version' _ "$TMP_DIR" "$RUNNER" >"$TMP_DIR/out" 2>"$TMP_DIR/err"; then
  fail "mismatched resolved Yarn version unexpectedly passed"
fi
grep -q 'resolved Yarn version must be 4.10.3' "$TMP_DIR/err" || fail "resolved-version diagnostic missing"

if NODE_BIN="$REAL_NODE" NPM_BIN="$TMP_DIR/bin/npm" bash -c 'cd "$1" && exec "$2" --version' _ "$TMP_DIR" "$RUNNER" >"$TMP_DIR/out" 2>"$TMP_DIR/err"; then
  fail "production tool overrides unexpectedly passed"
fi
grep -q 'NODE_BIN is forbidden outside explicit PINNED_YARN_TEST_MODE=1' "$TMP_DIR/err" || fail "production override diagnostic missing"

echo "[pinned-yarn-test] all tests passed"
