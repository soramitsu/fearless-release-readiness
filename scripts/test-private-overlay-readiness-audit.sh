#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
AUDIT_SCRIPT="$SCRIPT_DIR/audit-private-overlay-readiness.sh"
REAL_ANDROID_AUDIT="$SCRIPT_DIR/../fearless-Android-production-consolidated-20260731/scripts/audit-private-overlay-boundary.sh"
REAL_ANDROID_TEST="$SCRIPT_DIR/../fearless-Android-production-consolidated-20260731/scripts/test-private-overlay-boundary.sh"
REAL_IOS_AUDIT="$SCRIPT_DIR/../fearless-iOS-production-consolidated-20260731/scripts/audit-private-overlay-boundary.sh"
REAL_IOS_TEST="$SCRIPT_DIR/../fearless-iOS-production-consolidated-20260731/scripts/test-private-overlay-boundary.sh"

fail() {
  echo "[private-overlay-readiness-test][error] $*" >&2
  exit 1
}

tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

workspace="$tmp_dir/fearless"
report_dir="$tmp_dir/reports"

write_file() {
  local file="$1"
  local content="$2"
  mkdir -p "$(dirname "$file")"
  printf '%s\n' "$content" > "$file"
}

init_repo() {
  local repo="$1"
  git init -q "$repo"
  git -C "$repo" config user.email "overlay-readiness@example.invalid"
  git -C "$repo" config user.name "Overlay Readiness Test"
}

track_all() {
  local repo="$1"
  git -C "$repo" add .
}

install_platform_scripts() {
  local repo="$1"
  local audit_source="$2"
  local test_source="$3"
  mkdir -p "$repo/scripts"
  cp "$audit_source" "$repo/scripts/audit-private-overlay-boundary.sh"
  cp "$test_source" "$repo/scripts/test-private-overlay-boundary.sh"
  chmod +x "$repo/scripts/audit-private-overlay-boundary.sh" "$repo/scripts/test-private-overlay-boundary.sh"
}

make_android_pair() {
  local public_repo="$workspace/fearless-Android-production-consolidated-20260731"
  local private_repo="$workspace/fearless-Android-priv"
  mkdir -p "$public_repo" "$private_repo"
  init_repo "$public_repo"
  init_repo "$private_repo"
  install_platform_scripts "$public_repo" "$REAL_ANDROID_AUDIT" "$REAL_ANDROID_TEST"
  write_file "$public_repo/app/src/main/java/jp/co/soramitsu/PublicFeature.kt" "public feature"
  write_file "$private_repo/app/src/release/google-services.json" '{"release":true}'
  track_all "$public_repo"
  track_all "$private_repo"
}

make_ios_pair() {
  local public_repo="$workspace/fearless-iOS-production-consolidated-20260731"
  local private_repo="$workspace/fearless-iOS-priv"
  mkdir -p "$public_repo" "$private_repo"
  init_repo "$public_repo"
  init_repo "$private_repo"
  install_platform_scripts "$public_repo" "$REAL_IOS_AUDIT" "$REAL_IOS_TEST"
  write_file "$public_repo/fearless/Common/Model/PublicFeature.swift" "public feature"
  write_file "$private_repo/fearless/Configs/fearless.release.xcconfig" "RELEASE=1"
  track_all "$public_repo"
  track_all "$private_repo"
}

reset_fixture() {
  rm -rf "$workspace" "$report_dir"
  mkdir -p "$workspace"
  make_android_pair
  make_ios_pair
}

run_audit() {
  PRIVATE_OVERLAY_AUDIT_ROOT="$workspace" \
    PRIVATE_OVERLAY_AUDIT_REPORT_DIR="$report_dir" \
    MAX_REPORT_LINES=2 \
    bash "$AUDIT_SCRIPT" --skip-self-tests "$@"
}

expect_success() {
  local name="$1"
  shift || true
  local output
  if ! output="$(run_audit "$@" 2>&1)"; then
    echo "$output" >&2
    fail "$name unexpectedly failed"
  fi
}

expect_failure() {
  local name="$1"
  local expected="$2"
  shift 2
  local output
  set +e
  output="$(run_audit "$@" 2>&1)"
  local status=$?
  set -e

  if [[ "$status" -eq 0 ]]; then
    echo "$output" >&2
    fail "$name unexpectedly passed"
  fi

  if [[ "$output" != *"$expected"* ]]; then
    echo "$output" >&2
    fail "$name did not report expected text: $expected"
  fi
}

reset_fixture
expect_success "overlay-only fixture"

reset_fixture
write_file "$workspace/fearless-Android-priv/app/src/main/java/jp/co/soramitsu/PublicFeature.kt" "public feature"
track_all "$workspace/fearless-Android-priv"
expect_failure "android duplicate public product path" "android private overlay is not release-ready"
grep -q $'T\tapp/src/main/java/jp/co/soramitsu/PublicFeature.kt' "$report_dir/android-private-overlay-boundary.tsv" ||
  fail "expected Android report to include identical duplicated public product path"

reset_fixture
rm -rf "$workspace/fearless-iOS-priv"
expect_failure "missing private repo" "ios private repo missing"
expect_success "allow missing private repo" --allow-missing

reset_fixture
write_file "$workspace/fearless-Android-priv/feature-wallet-impl/src/main/java/jp/co/soramitsu/PrivateTransfer.kt" "private product code"
track_all "$workspace/fearless-Android-priv"
expect_failure "android private product path" "android private overlay is not release-ready"
grep -q $'A\tfeature-wallet-impl/src/main/java/jp/co/soramitsu/PrivateTransfer.kt' "$report_dir/android-private-overlay-boundary.tsv" ||
  fail "expected Android report to include private-only product path"

reset_fixture
write_file "$workspace/fearless-iOS-priv/fearless/Common/Model/PublicFeature.swift" "modified private feature"
track_all "$workspace/fearless-iOS-priv"
expect_failure "ios modified product path" "ios private overlay is not release-ready"
grep -q $'M\tfearless/Common/Model/PublicFeature.swift' "$report_dir/ios-private-overlay-boundary.tsv" ||
  fail "expected iOS report to include modified product path"

reset_fixture
cp -R "$workspace/fearless-Android-production-consolidated-20260731" "$workspace/fearless-Android"
rm -rf "$workspace/fearless-Android-production-consolidated-20260731"
expect_failure "historical Android checkout cannot substitute for candidate" "android public repo missing or not a Git checkout"

reset_fixture
git -C "$workspace/fearless-Android-production-consolidated-20260731" -c commit.gpgsign=false commit -qm fixture
mv "$workspace/fearless-Android-production-consolidated-20260731" "$workspace/fearless-Android"
git -C "$workspace/fearless-Android" worktree add --detach "$workspace/fearless-Android-production-consolidated-20260731" HEAD >/dev/null
expect_success "consolidated Git worktree checkout"

echo "[private-overlay-readiness-test] all tests passed"
