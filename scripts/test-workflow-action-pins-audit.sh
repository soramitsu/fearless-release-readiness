#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
AUDIT_SCRIPT="$ROOT_DIR/scripts/audit-workflow-action-pins.sh"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT
FIXTURE_ROOT="$TMP_DIR/fearless"
FIXTURE_PARENT="$TMP_DIR"

repos=(fearless-Android-production-consolidated-20260731 fearless-iOS-production-consolidated-20260731 fearless-wallet-web fearless-site-web)
siblings=(ton-indexer solswap-indexer polkaswap-indexer)

copy_or_seed_workflows() {
  local source="$1"
  local destination="$2"
  mkdir -p "$destination"
  if [[ -d "$source" && ! -L "$source" ]]; then
    cp -R "$source/." "$destination/"
    return
  fi
  printf '%s\n' \
    'name: fixture' \
    'jobs:' \
    '  validate:' \
    '    runs-on: ubuntu-latest' \
    '    steps:' \
    '      - uses: actions/checkout@34e114876b0b11c390a56381ad16ebd13914f8d5 # v4' \
    '      - uses: actions/setup-node@49933ea5288caeca8642d1e84afbd3f7d6820020 # v4' \
    > "$destination/ci.yml"
}

write_fixture() {
  rm -rf "$FIXTURE_ROOT" "$FIXTURE_PARENT/ton-indexer" "$FIXTURE_PARENT/solswap-indexer" "$FIXTURE_PARENT/polkaswap-indexer"
  mkdir -p "$FIXTURE_ROOT"
  copy_or_seed_workflows "$ROOT_DIR/.github/workflows" "$FIXTURE_ROOT/.github/workflows"
  for repo in "${repos[@]}"; do
    copy_or_seed_workflows "$ROOT_DIR/$repo/.github/workflows" "$FIXTURE_ROOT/$repo/.github/workflows"
  done
  for repo in "${siblings[@]}"; do
    copy_or_seed_workflows "$ROOT_DIR/../$repo/.github/workflows" "$FIXTURE_PARENT/$repo/.github/workflows"
  done
}

run_audit() {
  WORKFLOW_ACTION_PIN_AUDIT_ROOT="$FIXTURE_ROOT" \
    WORKFLOW_ACTION_PIN_AUDIT_PARENT="$FIXTURE_PARENT" \
    bash "$AUDIT_SCRIPT"
}

expect_failure() {
  local label="$1"
  local expected="$2"
  local output="$TMP_DIR/$label.out"
  shift 2
  if "$@" >"$output" 2>&1; then
    echo "[workflow-action-pins-test][error] $label unexpectedly passed" >&2
    exit 1
  fi
  if ! grep -Fq "$expected" "$output"; then
    echo "[workflow-action-pins-test][error] $label did not report: $expected" >&2
    sed -n '1,80p' "$output" >&2
    exit 1
  fi
}

write_fixture
run_audit >/dev/null

write_fixture
cp -R "$FIXTURE_ROOT/fearless-Android-production-consolidated-20260731" "$FIXTURE_ROOT/fearless-Android"
rm -rf "$FIXTURE_ROOT/fearless-Android-production-consolidated-20260731/.github/workflows"
expect_failure "historical-android-substitution" "workflow directory missing or unsafe" run_audit

write_fixture
cp -R "$FIXTURE_ROOT/fearless-iOS-production-consolidated-20260731" "$FIXTURE_ROOT/fearless-iOS"
rm -rf "$FIXTURE_ROOT/fearless-iOS-production-consolidated-20260731/.github/workflows"
expect_failure "historical-ios-substitution" "workflow directory missing or unsafe" run_audit

write_fixture
workflow="$FIXTURE_ROOT/fearless-wallet-web/.github/workflows/ci.yml"
sed -i.bak 's#actions/checkout@34e114876b0b11c390a56381ad16ebd13914f8d5#actions/checkout@v4#' "$workflow"
expect_failure "floating-tag" "action is not pinned by a full lowercase commit SHA" run_audit

write_fixture
workflow="$FIXTURE_ROOT/fearless-site-web/.github/workflows/ci.yml"
sed -i.bak 's#actions/setup-node@49933ea5288caeca8642d1e84afbd3f7d6820020#actions/setup-node@aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa#' "$workflow"
expect_failure "unreviewed-full-sha" "actions/setup-node must use reviewed commit" run_audit

write_fixture
workflow="$FIXTURE_ROOT/.github/workflows/passkey-image-publish.yml"
sed -i.bak 's#docker/build-push-action@10e90e3645eae34f1e60eeb005ba3a3d33f178e8#docker/build-push-action@aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa#' "$workflow"
expect_failure "unreviewed-publication-action" "docker/build-push-action must use reviewed commit" run_audit

write_fixture
workflow="$FIXTURE_PARENT/ton-indexer/.github/workflows/ci.yml"
sed -i.bak 's#actions/checkout@34e114876b0b11c390a56381ad16ebd13914f8d5#actions/checkout@34E114876B0B11C390A56381AD16EBD13914F8D5#' "$workflow"
expect_failure "uppercase-sha" "action is not pinned by a full lowercase commit SHA" run_audit

write_fixture
printf '%s\n' 'name: unsafe' 'jobs:' '  audit:' '    uses: owner/reusable/.github/workflows/ci.yml@main' > "$FIXTURE_ROOT/fearless-iOS-production-consolidated-20260731/.github/workflows/unsafe.yml"
expect_failure "branch-ref" "action is not pinned by a full lowercase commit SHA" run_audit

write_fixture
printf '%s\n' 'name: unsafe' 'jobs:' '  audit:' '    steps:' '      - uses: docker://alpine:3.21' > "$FIXTURE_ROOT/fearless-iOS-production-consolidated-20260731/.github/workflows/unsafe.yml"
expect_failure "docker-tag" "Docker action is not pinned by sha256 digest" run_audit

write_fixture
printf '%s\n' 'name: unsafe' 'jobs:' '  audit:' '    steps:' '      - uses: ./../outside' > "$FIXTURE_ROOT/fearless-iOS-production-consolidated-20260731/.github/workflows/unsafe.yml"
expect_failure "local-traversal" "unsafe local action reference" run_audit

write_fixture
rm -rf "$FIXTURE_PARENT/polkaswap-indexer/.github/workflows"
expect_failure "missing-workflows" "workflow directory missing or unsafe" run_audit

write_fixture
target="$FIXTURE_ROOT/fearless-site-web/.github/workflows/ci.yml"
rm "$target"
ln -s /etc/passwd "$target"
expect_failure "workflow-symlink" "workflow must be a regular non-symlink file" run_audit

echo "[workflow-action-pins-test] all tests passed"
