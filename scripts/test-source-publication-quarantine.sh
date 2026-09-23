#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
HELPER="$SCRIPT_DIR/quarantine-source-publication-outputs.mjs"
RUNNER="$SCRIPT_DIR/run-source-publication-quarantine.sh"
NODE_BIN="$(command -v node)"
GIT_BIN="/usr/bin/git"
TMP_CREATED="$(mktemp -d)"
TMP_ROOT="$(cd "$TMP_CREATED" && pwd -P)"
trap 'rm -rf "$TMP_ROOT"' EXIT

fail() {
  echo "[source-publication-quarantine-test][error] $*" >&2
  exit 1
}

mode_of() {
  stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1"
}

sha256_of() {
  shasum -a 256 "$1" | awk '{print $1}'
}

write_config() {
  local target="$1"
  {
    printf '# path\trepository\thead\tbase\tpull_request\n'
    printf 'fearless-Android\texample/android\ttopic\tdevelop\t1\n'
    printf 'fearless-iOS\texample/ios\ttopic\tdevelop\t2\n'
    printf 'fearless-wallet-web\texample/wallet\ttopic\tdevelop\t3\n'
    printf 'fearless-site-web-app-associations-20260726\texample/site\ttopic\tdevelop\t4\n'
    printf '../ton-indexer\texample/ton\ttopic\tdevelop\t5\n'
    printf '../solswap-indexer\texample/sol\ttopic\tdevelop\t6\n'
    printf '../polkaswap-indexer\texample/polka\ttopic\tdevelop\t7\n'
    printf '../iroha\texample/iroha\ttopic\toptimizations\t8\n'
  } > "$target"
}

make_fixture() {
  local name="$1"
  local with_outputs="${2:-1}"
  PARENT="$TMP_ROOT/$name/dev"
  ROOT="$PARENT/fearless"
  CONFIG="$ROOT/config/source-publication-readiness.tsv"
  OUTSIDE="$TMP_ROOT/$name/outside"
  mkdir -p "$ROOT/config" "$OUTSIDE/iroha-target"
  write_config "$CONFIG"
  printf 'iroha-owner-data\n' > "$OUTSIDE/iroha-target/sentinel.txt"
  ln -s "$OUTSIDE/iroha-target" "$PARENT/iroha"

  local configured repository
  for configured in \
    fearless-Android \
    fearless-iOS \
    fearless-wallet-web \
    fearless-site-web-app-associations-20260726 \
    ../ton-indexer \
    ../solswap-indexer \
    ../polkaswap-indexer; do
    repository="$ROOT/$configured"
    mkdir -p "$repository"
    repository="$(cd "$repository" && pwd -P)"
    "$GIT_BIN" -C "$repository" init -q
    "$GIT_BIN" -C "$repository" config user.email test@example.invalid
    "$GIT_BIN" -C "$repository" config user.name 'Quarantine Test'
    printf 'ignored\n*.tmp\n' > "$repository/.gitignore"
    printf 'tracked\n' > "$repository/tracked.txt"
    "$GIT_BIN" -C "$repository" add .gitignore tracked.txt
    "$GIT_BIN" -C "$repository" commit -qm fixture
    if [[ "$with_outputs" == 1 ]]; then
      mkdir -p "$repository/ignored"
      printf 'cache\n' > "$repository/ignored/cache.bin"
    fi
  done
}

run_helper() {
  SOURCE_PUBLICATION_QUARANTINE_TEST_MODE=1 \
    "$NODE_BIN" "$HELPER" --test-mode --root "$ROOT" --config "$CONFIG" "$@"
}

expect_failure() {
  local label="$1"
  local expected="$2"
  shift 2
  local output status
  set +e
  output="$("$@" 2>&1)"
  status=$?
  set -e
  [[ $status -ne 0 ]] || fail "$label unexpectedly succeeded"
  [[ "$output" == *"$expected"* ]] || fail "$label did not report '$expected': $output"
}

# Pure overlap handling is deterministic and does not depend on Git's collapsing behavior.
HELPER_PATH="$HELPER" "$NODE_BIN" --input-type=module <<'NODE'
import { pathToFileURL } from 'node:url';
const helper = await import(pathToFileURL(process.env.HELPER_PATH));
const result = helper.collapseCandidatePaths(['vendor/', 'vendor/bundle/', 'build/tmp/', 'build/']);
if (JSON.stringify(result) !== JSON.stringify([
  { relativePath: 'build', coveredPaths: ['build/tmp'] },
  { relativePath: 'vendor', coveredPaths: ['vendor/bundle'] },
])) process.exit(1);
NODE

# Dry-run is the default and performs no filesystem mutation.
make_fixture dry_run
iroha_before="$(sha256_of "$OUTSIDE/iroha-target/sentinel.txt")"
run_helper > "$TMP_ROOT/dry-run.json"
[[ "$(jq -r '.mode + ":" + .status' "$TMP_ROOT/dry-run.json")" == 'dry-run:planned' ]] || fail 'dry-run report mismatch'
[[ "$(jq '.entries | length' "$TMP_ROOT/dry-run.json")" == 7 ]] || fail 'dry-run candidate count mismatch'
[[ ! -e "$ROOT/build/quarantine" ]] || fail 'dry-run created a quarantine directory'
[[ -d "$ROOT/fearless-Android/ignored" ]] || fail 'dry-run moved an ignored output'
[[ "$(sha256_of "$OUTSIDE/iroha-target/sentinel.txt")" == "$iroha_before" ]] || fail 'dry-run touched Iroha sentinel'
[[ "$(readlink "$PARENT/iroha")" == "$OUTSIDE/iroha-target" ]] || fail 'dry-run touched Iroha path'

# A clean tree is an apply no-op and also creates no quarantine directory.
make_fixture no_op 0
run_helper --apply > "$TMP_ROOT/no-op.json"
[[ "$(jq -r '.mode + ":" + .status' "$TMP_ROOT/no-op.json")" == 'apply:no-op' ]] || fail 'no-op report mismatch'
[[ ! -e "$ROOT/build/quarantine" ]] || fail 'no-op apply created a quarantine directory'

# Successful apply is private, same-filesystem, preserves internal links, and is reversible.
make_fixture success
printf 'outside-data\n' > "$OUTSIDE/shared.txt"
chmod 0644 "$OUTSIDE/shared.txt"
outside_sha="$(sha256_of "$OUTSIDE/shared.txt")"
outside_mode="$(mode_of "$OUTSIDE/shared.txt")"
ln "$OUTSIDE/shared.txt" "$ROOT/fearless-Android/ignored/hard-peer"
ln -s "$OUTSIDE/shared.txt" "$ROOT/fearless-Android/ignored/external-link"
run_helper --apply > "$TMP_ROOT/applied.json"
quarantine_root="$(jq -r '.quarantineRoot' "$TMP_ROOT/applied.json")"
manifest="$quarantine_root/manifest.json"
[[ "$(jq -r '.status' "$TMP_ROOT/applied.json")" == applied ]] || fail 'apply did not complete'
[[ "$(mode_of "$quarantine_root")" == 700 ]] || fail 'quarantine root is not private'
[[ "$(mode_of "$manifest")" == 600 ]] || fail 'manifest is not private'
[[ -L "$quarantine_root/fearless-Android/ignored/external-link" ]] || fail 'internal symlink was followed or lost'
[[ "$(sha256_of "$OUTSIDE/shared.txt")" == "$outside_sha" ]] || fail 'external symlink target content changed'
[[ "$(mode_of "$OUTSIDE/shared.txt")" == "$outside_mode" ]] || fail 'external/hardlink peer permissions changed'
for repository in fearless-Android fearless-iOS fearless-wallet-web fearless-site-web-app-associations-20260726 ../ton-indexer ../solswap-indexer ../polkaswap-indexer; do
  [[ "$("$GIT_BIN" -C "$ROOT/$repository" ls-files --others --ignored --exclude-standard --directory -z | tr -cd '\0' | wc -c | tr -d ' ')" == 0 ]] || fail "$repository retained ignored outputs"
done
[[ "$(sha256_of "$OUTSIDE/iroha-target/sentinel.txt")" == "$iroha_before" ]] || fail 'apply touched Iroha sentinel'
run_helper --rollback "$manifest" > "$TMP_ROOT/rolled-back.json"
[[ "$(jq -r '.status' "$TMP_ROOT/rolled-back.json")" == rolled-back ]] || fail 'explicit rollback did not complete'
[[ -d "$ROOT/fearless-Android/ignored" ]] || fail 'rollback did not restore ignored output'
[[ -L "$ROOT/fearless-Android/ignored/external-link" ]] || fail 'rollback did not restore symlink as a link'

# A later failure rolls back every completed atomic rename without overwriting sources.
make_fixture rollback
expect_failure automatic_rollback 'completed moves were rolled back' \
  env SOURCE_PUBLICATION_QUARANTINE_TEST_MODE=1 SOURCE_PUBLICATION_QUARANTINE_TEST_FAIL_AFTER_MOVES=2 \
  "$NODE_BIN" "$HELPER" --test-mode --root "$ROOT" --config "$CONFIG" --apply
rollback_manifest="$(find "$ROOT/build/quarantine" -name manifest.json -print | sort | tail -n 1)"
[[ "$(jq -r '.status' "$rollback_manifest")" == rolled-back ]] || fail 'automatic rollback manifest is not complete'
[[ "$(jq '[.entries[] | select(.status == "rolled-back")] | length' "$rollback_manifest")" == 2 ]] || fail 'automatic rollback count mismatch'
for repository in fearless-Android fearless-iOS fearless-wallet-web fearless-site-web-app-associations-20260726 ../ton-indexer ../solswap-indexer ../polkaswap-indexer; do
  [[ -d "$ROOT/$repository/ignored" ]] || fail "automatic rollback lost $repository output"
done

# Tracked and non-ignored content introduced after planning are fail-closed.
make_fixture tracked_race
expect_failure tracked_after_plan 'ignored candidate contains tracked content' \
  env SOURCE_PUBLICATION_QUARANTINE_TEST_MODE=1 SOURCE_PUBLICATION_QUARANTINE_TEST_ADD_TRACKED=1 \
  "$NODE_BIN" "$HELPER" --test-mode --root "$ROOT" --config "$CONFIG" --apply
[[ -f "$ROOT/fearless-Android/ignored/tracked-after-plan.txt" ]] || fail 'tracked race evidence was unexpectedly moved'

make_fixture nonignored_race
expect_failure nonignored_after_plan 'ignored candidate contains non-ignored untracked content' \
  env SOURCE_PUBLICATION_QUARANTINE_TEST_MODE=1 SOURCE_PUBLICATION_QUARANTINE_TEST_ADD_NONIGNORED=1 \
  "$NODE_BIN" "$HELPER" --test-mode --root "$ROOT" --config "$CONFIG" --apply
[[ -f "$ROOT/fearless-Android/ignored/keep.txt" ]] || fail 'non-ignored race evidence was unexpectedly moved'

# Candidate and destination symlink attacks are rejected without following targets.
make_fixture source_symlink
rm -rf "$ROOT/fearless-Android/ignored"
mkdir -p "$OUTSIDE/source-target"
printf 'outside-source\n' > "$OUTSIDE/source-target/sentinel.txt"
ln -s "$OUTSIDE/source-target" "$ROOT/fearless-Android/ignored"
source_target_sha="$(sha256_of "$OUTSIDE/source-target/sentinel.txt")"
expect_failure ignored_source_symlink 'must not use a symlinked path component' run_helper
[[ "$(sha256_of "$OUTSIDE/source-target/sentinel.txt")" == "$source_target_sha" ]] || fail 'source symlink target changed'

make_fixture destination_symlink
mkdir -p "$ROOT/build" "$OUTSIDE/quarantine-target"
ln -s "$OUTSIDE/quarantine-target" "$ROOT/build/quarantine"
expect_failure quarantine_parent_symlink 'must not use a symlinked path component' run_helper --apply
[[ -z "$(find "$OUTSIDE/quarantine-target" -mindepth 1 -print -quit)" ]] || fail 'destination symlink target received data'
[[ -d "$ROOT/fearless-Android/ignored" ]] || fail 'destination symlink case moved source data'

# A type swap at the last rename checkpoint is detected; the external target is untouched.
make_fixture type_race
printf 'race-target\n' > "$OUTSIDE/race-target.txt"
race_sha="$(sha256_of "$OUTSIDE/race-target.txt")"
expect_failure pre_rename_type_swap 'automatic rollback was incomplete' \
  env SOURCE_PUBLICATION_QUARANTINE_TEST_MODE=1 SOURCE_PUBLICATION_QUARANTINE_TEST_SWAP_BEFORE_RENAME="$OUTSIDE/race-target.txt" \
  "$NODE_BIN" "$HELPER" --test-mode --root "$ROOT" --config "$CONFIG" --apply
[[ -L "$ROOT/fearless-Android/ignored" ]] || fail 'type-race symlink was not detected in place'
[[ -d "$ROOT/fearless-Android/ignored.race-original" ]] || fail 'type-race original evidence was lost'
[[ "$(sha256_of "$OUTSIDE/race-target.txt")" == "$race_sha" ]] || fail 'type-race target was changed'

# Canonical repository roots, safe filenames, exact config, and production env isolation are enforced.
make_fixture repository_symlink
mv "$ROOT/fearless-Android" "$OUTSIDE/android-real"
ln -s "$OUTSIDE/android-real" "$ROOT/fearless-Android"
expect_failure repository_root_symlink 'must not use a symlinked path component' run_helper

make_fixture unsafe_filename 0
printf 'unsafe\n' > "$ROOT/fearless-Android/evil
name.tmp"
expect_failure control_character_filename 'unsafe ignored path' run_helper

make_fixture config_drift
printf '../unexpected\texample/unexpected\ttopic\tdevelop\t9\n' >> "$CONFIG"
expect_failure config_path_drift 'source publication config paths must be exactly' run_helper

make_fixture git_config_include
printf '\n[include]\n\tpath = %s\n' "$PARENT/iroha/config" >> "$ROOT/fearless-Android/.git/config"
expect_failure external_git_config 'repository config includes external configuration' run_helper

make_fixture rollback_forgery
run_helper --apply > "$TMP_ROOT/forgery-applied.json"
forgery_manifest="$(jq -r '.quarantineRoot' "$TMP_ROOT/forgery-applied.json")/manifest.json"
MANIFEST_PATH="$forgery_manifest" "$NODE_BIN" <<'NODE'
const fs = require('node:fs');
const manifest = JSON.parse(fs.readFileSync(process.env.MANIFEST_PATH, 'utf8'));
manifest.entries[0].repository = '../iroha';
fs.writeFileSync(process.env.MANIFEST_PATH, `${JSON.stringify(manifest, null, 2)}\n`);
NODE
forgery_iroha_sha="$(sha256_of "$OUTSIDE/iroha-target/sentinel.txt")"
expect_failure forged_iroha_rollback 'rollback manifest contains a forbidden repository' run_helper --rollback "$forgery_manifest"
[[ "$(sha256_of "$OUTSIDE/iroha-target/sentinel.txt")" == "$forgery_iroha_sha" ]] || fail 'forged rollback touched Iroha sentinel'

expect_failure production_root_override 'root/config overrides and test environment are forbidden in production mode' \
  "$NODE_BIN" "$HELPER" --root "$ROOT" --config "$CONFIG"
expect_failure production_env_injection 'test-mode and SOURCE_PUBLICATION_QUARANTINE_TEST_MODE=1 must be used together' \
  env SOURCE_PUBLICATION_QUARANTINE_TEST_MODE=1 "$NODE_BIN" "$HELPER"
expect_failure runner_env_injection 'is forbidden in production mode' \
  env SOURCE_PUBLICATION_QUARANTINE_FORGED=1 "$RUNNER"

echo '[source-publication-quarantine-test] isolated dry-run, apply, rollback, and adversarial cases passed'
