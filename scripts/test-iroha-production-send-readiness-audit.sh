#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
AUDIT="$ROOT_DIR/scripts/audit-iroha-production-send-readiness.sh"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/fearless-iroha-send-aggregate.XXXXXX")"
trap 'rm -rf "$TMP_DIR"' EXIT

fail() {
  echo "[iroha-production-send-readiness-test][error] $*" >&2
  exit 1
}

setup_fixture() {
  rm -rf "$TMP_DIR/fixture"
  for repo in fearless-Android fearless-iOS fearless-wallet-web; do
    mkdir -p "$TMP_DIR/fixture/$repo/scripts"
    for script in test-iroha-production-send-readiness-audit.sh audit-iroha-production-send-readiness.sh; do
      printf '%s\n' \
        '#!/usr/bin/env bash' \
        'set -euo pipefail' \
        'expected_repo="$(cd "$(dirname "$0")/.." && pwd -P)"' \
        '[[ "${IROHA_SEND_AUDIT_ROOT:-}" == "$expected_repo" ]] || { echo "aggregate did not bind exact platform root" >&2; exit 2; }' \
        '[[ "$(pwd -P)" == "$expected_repo" ]] || { echo "aggregate did not enter exact platform working directory" >&2; exit 2; }' \
        'repo="$(basename "$expected_repo")"' \
        'script="$(basename "$0")"' \
        'printf "%s/%s\n" "$repo" "$script" >> "${IROHA_SEND_TEST_SENTINEL:?}"' \
        '[[ "${IROHA_SEND_TEST_FAIL:-}" != "$repo/$script" ]]' \
        > "$TMP_DIR/fixture/$repo/scripts/$script"
      chmod +x "$TMP_DIR/fixture/$repo/scripts/$script"
    done
  done
  : > "$TMP_DIR/sentinel"
}

run_audit() {
  IROHA_SEND_AGGREGATE_ROOT="$TMP_DIR/fixture" \
    IROHA_SEND_TEST_SENTINEL="$TMP_DIR/sentinel" \
    IROHA_SEND_TEST_FAIL="${1:-}" \
    bash "$AUDIT"
}

assert_all_six_ran() {
  local count
  count="$(wc -l < "$TMP_DIR/sentinel" | tr -d '[:space:]')"
  [[ "$count" == "6" ]] || fail "expected all six platform gates to run, got $count"
  [[ "$(sort -u "$TMP_DIR/sentinel" | wc -l | tr -d '[:space:]')" == "6" ]] ||
    fail "aggregate ran duplicate gates"
}

expect_failure() {
  local label="$1"
  local fail_target="$2"
  local expected="$3"
  local output status
  set +e
  output="$(run_audit "$fail_target" 2>&1)"
  status=$?
  set -e
  [[ "$status" -ne 0 ]] || fail "$label unexpectedly passed"
  [[ "$output" == *"$expected"* ]] || fail "$label did not report: $expected"
  assert_all_six_ran
}

setup_fixture
IROHA_SEND_AUDIT_ROOT="$TMP_DIR/forged-ambient-root" run_audit >/dev/null
assert_all_six_ran

setup_fixture
(
  cd "$TMP_DIR"
  IROHA_SEND_AGGREGATE_ROOT=fixture \
    IROHA_SEND_TEST_SENTINEL="$TMP_DIR/sentinel" \
    IROHA_SEND_TEST_FAIL= \
    bash "$AUDIT" >/dev/null
)
assert_all_six_ran

for target in \
  fearless-Android/test-iroha-production-send-readiness-audit.sh \
  fearless-Android/audit-iroha-production-send-readiness.sh \
  fearless-iOS/test-iroha-production-send-readiness-audit.sh \
  fearless-iOS/audit-iroha-production-send-readiness.sh \
  fearless-wallet-web/test-iroha-production-send-readiness-audit.sh \
  fearless-wallet-web/audit-iroha-production-send-readiness.sh
do
  setup_fixture
  platform="${target%%/*}"
  script="${target#*/}"
  case "$platform" in
    fearless-Android) label="android" ;;
    fearless-iOS) label="ios" ;;
    fearless-wallet-web) label="browser-extension" ;;
  esac
  if [[ "$script" == test-* ]]; then
    expected="$label adversarial self-test failed"
  else
    expected="$label blocked-readiness audit failed"
  fi
  expect_failure "$target failure" "$target" "$expected"
done

setup_fixture
rm "$TMP_DIR/fixture/fearless-iOS/scripts/audit-iroha-production-send-readiness.sh"
set +e
output="$(run_audit 2>&1)"
status=$?
set -e
[[ "$status" -ne 0 && "$output" == *"ios blocked-readiness audit is missing"* ]] ||
  fail "missing platform audit was not rejected"

setup_fixture
chmod -x "$TMP_DIR/fixture/fearless-wallet-web/scripts/test-iroha-production-send-readiness-audit.sh"
set +e
output="$(run_audit 2>&1)"
status=$?
set -e
[[ "$status" -ne 0 && "$output" == *"browser-extension adversarial self-test is not executable"* ]] ||
  fail "non-executable platform self-test was not rejected"

echo "[iroha-production-send-readiness-test] all adversarial fixtures passed."
