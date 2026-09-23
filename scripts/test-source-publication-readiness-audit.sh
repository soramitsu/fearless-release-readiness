#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
AUDIT="$SCRIPT_DIR/audit-source-publication-readiness.mjs"
RUNNER="$SCRIPT_DIR/run-source-publication-readiness.sh"
REAL_GIT="$(command -v git)"
TMP_DIR="$(mktemp -d)"
TMP_DIR="$(cd "$TMP_DIR" && pwd -P)"
trap 'rm -rf "$TMP_DIR"' EXIT
NEGATIVE_CASES=0

fail() {
  echo "[source-publication-test][error] $*" >&2
  exit 1
}

[[ -f "$SCRIPT_DIR/../services/passkey-backup-challenge-service/src/server.js" ]] ||
  fail "actual passkey service entrypoint src/server.js is missing"
[[ ! -e "$SCRIPT_DIR/../services/passkey-backup-challenge-service/src/server.mjs" ]] ||
  fail "obsolete passkey service entrypoint src/server.mjs must not satisfy source ownership"
[[ -x "$RUNNER" && ! -L "$RUNNER" ]] || fail "source publication runner must be a regular executable"

expect_failure() {
  NEGATIVE_CASES=$((NEGATIVE_CASES + 1))
  local label="$1"
  local pattern="$2"
  shift 2
  local log="$TMP_DIR/${label//[^A-Za-z0-9._-]/_}.log"
  if "$@" >"$log" 2>&1; then
    fail "$label unexpectedly passed"
  fi
  if ! grep -Fq -- "$pattern" "$log"; then
    sed -n '1,80p' "$log" >&2
    fail "$label did not report: $pattern"
  fi
}

# Clean canonical branch publication is still blocked until exact-SHA review exists.
expect_review_blocked() {
  local log="$TMP_DIR/review-blocked-command.log"
  if "$@" > "$log" 2>&1; then fail "unreviewed canonical source unexpectedly passed"; fi
  node - "$log" <<'NODE'
const fs = require('fs')
const lines = fs.readFileSync(process.argv[2], 'utf8').split('\n').filter((line) => line.startsWith('  - '))
const review = '  - ../iroha: canonical branch exact-SHA review is blocked: optimizations requires a verifiable reviewed/protected policy'
const continuity = '  - ../iroha: source publication preflight did not pass before release checks'
if (!lines.includes(review) || lines.some((line) => line !== review && line !== continuity)) process.exit(1)
NODE
  cat "$log"
}

write_source_config() {
  local target="$1"
  printf '%s\n' \
    $'# path\trepository\thead\tbase\tpull_request' \
    $'fearless-Android-production-consolidated-20260731\tsoramitsu/fearless-Android\tcodex/android-production-consolidated-20260731\tdevelop\t1260' \
    $'fearless-iOS-production-consolidated-20260731\tsoramitsu/fearless-iOS\tcodex/testflight-redesign-2026.8.17\tdevelop\t1304' \
    $'fearless-wallet-web\tsoramitsu/fearless-wallet-web\tcodex/web-bitcoin-canonical-indexer-evidence\tdevelop\t1062' \
    $'fearless-site-web\tsoramitsu/fearless-site-web\tcodex/site-todo-debt-baseline-hardening\tdevelop\t45' \
    $'../ton-indexer\ttonswap-org/ton-indexer\tcodex/ti-smoke-body-preview-tests\tdevelop\t13' \
    $'../solswap-indexer\tsolswap-io/solswap-indexer\tcodex/si-smoke-body-preview-tests\tdevelop\t16' \
    $'../polkaswap-indexer\tsora-xor/polkaswap-indexer\tcodex/pi-deployment-evidence-gate\tdevelop\t1' \
    $'../iroha\thyperledger-iroha/iroha\toptimizations\toptimizations\t-' > "$target"
}

write_release_config() {
  local target="$1"
  printf '%s\n' \
    $'# repo\thead\tbase\trequired_state\trequired_checks' \
    $'example/fearless-release-orchestration\tcodex/root-release\tmain\tmerged\tvalidate' \
    $'soramitsu/fearless-Android\tcodex/android-production-consolidated-20260731\tdevelop\tmerged\tvalidate' \
    $'soramitsu/fearless-iOS\tcodex/testflight-redesign-2026.8.17\tdevelop\tmerged\tvalidate' \
    $'soramitsu/fearless-wallet-web\tcodex/web-bitcoin-canonical-indexer-evidence\tdevelop\tmerged\tvalidate' \
    $'soramitsu/fearless-site-web\tcodex/site-todo-debt-baseline-hardening\tdevelop\tmerged\tvalidate' \
    $'tonswap-org/ton-indexer\tcodex/ti-smoke-body-preview-tests\tdevelop\tmerged\tvalidate' \
    $'solswap-io/solswap-indexer\tcodex/si-smoke-body-preview-tests\tdevelop\tmerged\tvalidate' \
    $'sora-xor/polkaswap-indexer\tcodex/pi-deployment-evidence-gate\tdevelop\tmerged\tvalidate' \
    $'hyperledger-iroha/iroha\tcodex/kagemusha-selector-hardening\toptimizations\tmerged\tDCO' > "$target"
}

write_root_owner_config() {
  local target="$1"
  cat > "$target" <<'JSON'
{
  "schemaVersion": 1,
  "status": "ready",
  "repository": "example/fearless-release-orchestration",
  "head": "codex/root-release",
  "base": "main",
  "prNumber": 77,
  "lastReviewed": "2026-07-10",
  "blocker": null
}
JSON
}

init_repo() {
  local repo_path="$1"
  local repository="$2"
  local branch="$3"
  mkdir -p "$repo_path"
  "$REAL_GIT" -C "$repo_path" init -q -b "$branch"
  "$REAL_GIT" -C "$repo_path" config user.name 'Release Test'
  "$REAL_GIT" -C "$repo_path" config user.email release-test@example.com
  printf '%s\n' "$repository" > "$repo_path/source.txt"
  "$REAL_GIT" -C "$repo_path" add source.txt
  "$REAL_GIT" -C "$repo_path" commit -q -m 'initial source'
  printf '%s\n' 'second' >> "$repo_path/source.txt"
  "$REAL_GIT" -C "$repo_path" commit -qam 'current source'
  "$REAL_GIT" -C "$repo_path" remote add origin "https://github.com/$repository.git"
  "$REAL_GIT" -C "$repo_path" update-ref "refs/remotes/origin/$branch" HEAD
  "$REAL_GIT" -C "$repo_path" config "branch.$branch.remote" origin
  "$REAL_GIT" -C "$repo_path" config "branch.$branch.merge" "refs/heads/$branch"
}

ROOT="$TMP_DIR/fixture/workspace"
PARENT="$TMP_DIR/fixture"
mkdir -p "$ROOT/config" "$ROOT/scripts" "$ROOT/services/passkey-backup-challenge-service/src"
write_source_config "$ROOT/config/source-publication-readiness.tsv"
write_release_config "$ROOT/config/release-readiness-prs.tsv"
write_root_owner_config "$ROOT/config/source-publication-root-owner.json"
printf '%s\n' '# fixture plan' > "$ROOT/FEARLESS_PROJECT_PLAN.md"
for file in \
  .github/CODEOWNERS \
  .github/workflows/readiness.yml \
  .gitignore \
  README.md \
  docs/passkey-enabled-acceptance.md \
  docs/source-freeze-20260801.md \
  scripts/audit-passkey-enabled-acceptance.mjs \
  scripts/test-passkey-enabled-acceptance.mjs \
  scripts/audit-plan-readiness.sh \
  scripts/test-plan-readiness-audit.sh \
  scripts/audit-release-readiness.sh \
  scripts/audit-source-publication-readiness.mjs \
  scripts/capture-source-freeze.mjs \
  scripts/export-release-unblock-bundle.sh \
  scripts/quarantine-source-publication-outputs.mjs \
  scripts/run-pinned-yarn.sh \
  scripts/run-source-publication-quarantine.sh \
  scripts/run-source-publication-readiness.sh \
  scripts/test-pinned-yarn-runner.sh \
  scripts/test-source-publication-quarantine.sh \
  scripts/test-source-publication-readiness-audit.sh \
  scripts/verify-release-unblock-bundle.sh \
  services/passkey-backup-challenge-service/Dockerfile \
  services/passkey-backup-challenge-service/package-lock.json \
  services/passkey-backup-challenge-service/package.json \
  services/passkey-backup-challenge-service/src/server.js \
  services/passkey-backup-owner-authority/README.md \
  services/passkey-backup-owner-authority/package.json \
  services/passkey-backup-owner-authority/package-lock.json \
  services/passkey-backup-owner-authority/src/authority.js \
  services/passkey-backup-owner-authority/src/store.js \
  services/passkey-backup-owner-authority/src/validation.js \
  services/passkey-backup-owner-authority/src/verifier-contract.d.ts \
  services/passkey-backup-owner-authority/test/authority.test.js \
  services/passkey-backup-owner-authority/test/fixtures.js \
  services/passkey-backup-owner-authority/test/process-worker.js; do
  mkdir -p "$ROOT/$(dirname "$file")"
  printf '%s\n' 'fixture' > "$ROOT/$file"
done
for index in 1 2 3 4 5 6 7 8; do
  printf '%s\n' 'fixture' > "$ROOT/services/passkey-backup-challenge-service/extra-$index.txt"
done
printf '%s\n' \
  '/fearless-Android-production-consolidated-20260731/' \
  '/fearless-iOS-production-consolidated-20260731/' \
  '/fearless-wallet-web/' \
  '/fearless-site-web/' > "$ROOT/.gitignore"

"$REAL_GIT" -C "$ROOT" init -q -b codex/root-release
"$REAL_GIT" -C "$ROOT" config user.name 'Release Test'
"$REAL_GIT" -C "$ROOT" config user.email release-test@example.com
"$REAL_GIT" -C "$ROOT" add .
"$REAL_GIT" -C "$ROOT" commit -q -m 'owned release orchestration'
"$REAL_GIT" -C "$ROOT" remote add origin https://github.com/example/fearless-release-orchestration.git
"$REAL_GIT" -C "$ROOT" update-ref refs/remotes/origin/codex/root-release HEAD
"$REAL_GIT" -C "$ROOT" config branch.codex/root-release.remote origin
"$REAL_GIT" -C "$ROOT" config branch.codex/root-release.merge refs/heads/codex/root-release

init_repo "$ROOT/fearless-Android-production-consolidated-20260731" soramitsu/fearless-Android codex/android-production-consolidated-20260731
init_repo "$ROOT/fearless-iOS-production-consolidated-20260731" soramitsu/fearless-iOS codex/testflight-redesign-2026.8.17
init_repo "$ROOT/fearless-wallet-web" soramitsu/fearless-wallet-web codex/web-bitcoin-canonical-indexer-evidence
init_repo "$ROOT/fearless-site-web" soramitsu/fearless-site-web codex/site-todo-debt-baseline-hardening
init_repo "$PARENT/ton-indexer" tonswap-org/ton-indexer codex/ti-smoke-body-preview-tests
init_repo "$PARENT/solswap-indexer" solswap-io/solswap-indexer codex/si-smoke-body-preview-tests
init_repo "$PARENT/polkaswap-indexer" sora-xor/polkaswap-indexer codex/pi-deployment-evidence-gate
init_repo "$PARENT/iroha" hyperledger-iroha/iroha optimizations
IROHA_REMOTE_ADVANCED_SHA="$(
  tree="$($REAL_GIT -C "$PARENT/iroha" rev-parse 'HEAD^{tree}')"
  printf '%s\n' 'authoritative remote-only successor' |
    "$REAL_GIT" -C "$PARENT/iroha" commit-tree "$tree" -p HEAD
)"
IROHA_PR_HEAD_SHA="$(
  tree="$($REAL_GIT -C "$PARENT/iroha" rev-parse 'HEAD^{tree}')"
  printf '%s\n' 'merged configured-head successor' |
    "$REAL_GIT" -C "$PARENT/iroha" commit-tree "$tree" -p HEAD
)"

FAKE_GIT="$TMP_DIR/fake-git"
printf '%s\n' \
  '#!/usr/bin/env bash' \
  'set -euo pipefail' \
  '[[ "${1:-}" != "ls-remote" ]] || { echo "remote Git transport must not be used" >&2; exit 70; }' \
  '[[ -z "${GIT_SSH_COMMAND+x}" ]] || exit 71' \
  '[[ "${GIT_CONFIG_COUNT:-}" == "6" ]] || exit 72' \
  '[[ "${GIT_CONFIG_KEY_0:-}" == core.fsmonitor && "${GIT_CONFIG_VALUE_0:-}" == false ]] || exit 73' \
  '[[ "${GIT_CONFIG_KEY_1:-}" == core.hooksPath && "${GIT_CONFIG_VALUE_1:-}" == /dev/null ]] || exit 74' \
  '[[ "${GIT_CONFIG_KEY_2:-}" == core.askPass && "${GIT_CONFIG_VALUE_2:-}" == /usr/bin/false ]] || exit 75' \
  '[[ "${GIT_CONFIG_KEY_3:-}" == credential.helper && "${GIT_CONFIG_VALUE_3+x}" == x && -z "${GIT_CONFIG_VALUE_3}" ]] || exit 76' \
  '[[ "${GIT_CONFIG_KEY_4:-}" == credential.interactive && "${GIT_CONFIG_VALUE_4:-}" == false ]] || exit 77' \
  '[[ "${GIT_CONFIG_KEY_5:-}" == core.sshCommand && "${GIT_CONFIG_VALUE_5:-}" == /usr/bin/false ]] || exit 78' \
  'for index in 0 1 2 3 4 5; do value_name="GIT_CONFIG_VALUE_$index"; [[ "${!value_name}" != *attacker* ]] || exit 79; done' \
  'exec "$REAL_GIT" "$@"' > "$FAKE_GIT"
chmod +x "$FAKE_GIT"

FAKE_GH="$TMP_DIR/fake-gh"
printf '%s\n' \
  '#!/usr/bin/env bash' \
  'set -euo pipefail' \
  '[[ "${1:-}" == api && "${2:-}" == --hostname && "${3:-}" == github.com && -n "${4:-}" ]] || exit 64' \
  'endpoint="$4"' \
  'if [[ "$endpoint" == repos/*/git/ref/heads/* ]]; then' \
  '  repository="${endpoint#repos/}"; repository="${repository%%/git/ref/heads/*}"' \
  '  head="${endpoint#repos/$repository/git/ref/heads/}"' \
  '  query_key="${repository//\//_}--${head//\//_}"' \
  '  query_dir="$FAKE_GH_QUERY_DIR/$PPID"; mkdir -p "$query_dir"' \
  '  query_marker="$query_dir/$query_key"' \
  '  [[ ! -e "$query_marker" ]] || { echo "duplicate authoritative ref query: $repository:$head" >&2; exit 68; }' \
  '  : > "$query_marker"' \
  '  case "$repository" in' \
  '    example/fearless-release-orchestration) repo_path="$FIXTURE_ROOT" ;;' \
  '    soramitsu/fearless-Android) repo_path="$FIXTURE_ROOT/fearless-Android-production-consolidated-20260731" ;;' \
  '    soramitsu/fearless-iOS) repo_path="$FIXTURE_ROOT/fearless-iOS-production-consolidated-20260731" ;;' \
  '    soramitsu/fearless-wallet-web) repo_path="$FIXTURE_ROOT/fearless-wallet-web" ;;' \
  '    soramitsu/fearless-site-web) repo_path="$FIXTURE_ROOT/fearless-site-web" ;;' \
  '    tonswap-org/ton-indexer) repo_path="$FIXTURE_PARENT/ton-indexer" ;;' \
  '    solswap-io/solswap-indexer) repo_path="$FIXTURE_PARENT/solswap-indexer" ;;' \
  '    sora-xor/polkaswap-indexer) repo_path="$FIXTURE_PARENT/polkaswap-indexer" ;;' \
  '    hyperledger-iroha/iroha) repo_path="$FIXTURE_PARENT/iroha" ;;' \
  '    *) exit 65 ;;' \
  '  esac' \
  '  repo="$(basename "$repo_path")"; mode="${FAKE_GIT_MODE:-success}"' \
  '  if [[ "$mode" == "error" || "$mode" == "error-$repo" ]]; then echo "gh: service unavailable (HTTP 503)" >&2; exit 1; fi' \
  '  if [[ "$mode" == "missing" || "$mode" == "missing-$repo" ]]; then echo "gh: Not Found (HTTP 404)" >&2; exit 1; fi' \
  '  if [[ "$mode" == "error-current-iroha" && "$repo" == iroha && "$head" == optimizations ]]; then echo "gh: service unavailable (HTTP 503)" >&2; exit 1; fi' \
  '  if [[ "$mode" == "malformed-current-iroha" && "$repo" == iroha && "$head" == optimizations ]]; then printf "{\"ref\":42}\n"; exit 0; fi' \
  '  sha="$($REAL_GIT -C "$repo_path" rev-parse HEAD)"' \
  '  if [[ "$mode" == "modeled-live-iroha" && "$repo" == iroha ]]; then' \
  '    if [[ "$head" == optimizations ]]; then sha="$IROHA_REMOTE_ADVANCED_SHA"; else echo "gh: Not Found (HTTP 404)" >&2; exit 1; fi' \
  '  fi' \
  '  if [[ "$mode" == "advanced-current-iroha" && "$repo" == iroha && "$head" == optimizations ]]; then sha="$IROHA_REMOTE_ADVANCED_SHA"; fi' \
  '  if [[ "$mode" == "stale" || "$mode" == "stale-$repo" ]]; then sha=0000000000000000000000000000000000000000; fi' \
  '  if [[ "$mode" == "missing-current-iroha" && "$repo" == iroha && "$head" == optimizations ]]; then echo "gh: Not Found (HTTP 404)" >&2; exit 1; fi' \
  '  if [[ "$mode" == "malformed" || "$mode" == "malformed-$repo" ]]; then printf "{\\\"ref\\\":42}\\n"; exit 0; fi' \
  '  printf "{\\\"ref\\\":\\\"refs/heads/%s\\\",\\\"object\\\":{\\\"type\\\":\\\"commit\\\",\\\"sha\\\":\\\"%s\\\"}}\\n" "$head" "$sha"' \
  '  exit 0' \
  'fi' \
  'mode="${FAKE_GH_MODE:-success}"' \
  '[[ "$mode" != error ]] || exit 1' \
  '[[ "$mode" != invalid-json ]] || { printf "{"; exit 0; }' \
  'case "$endpoint" in' \
  '  repos/example/fearless-release-orchestration/pulls/77) repository=example/fearless-release-orchestration; repo_path="$FIXTURE_ROOT"; head=codex/root-release; base=main; number=77 ;;' \
  '  repos/soramitsu/fearless-Android/pulls/1260) repository=soramitsu/fearless-Android; repo_path="$FIXTURE_ROOT/fearless-Android-production-consolidated-20260731"; head=codex/android-production-consolidated-20260731; base=develop; number=1260 ;;' \
  '  repos/soramitsu/fearless-iOS/pulls/1304) repository=soramitsu/fearless-iOS; repo_path="$FIXTURE_ROOT/fearless-iOS-production-consolidated-20260731"; head=codex/testflight-redesign-2026.8.17; base=develop; number=1304 ;;' \
  '  repos/soramitsu/fearless-wallet-web/pulls/1062) repository=soramitsu/fearless-wallet-web; repo_path="$FIXTURE_ROOT/fearless-wallet-web"; head=codex/web-bitcoin-canonical-indexer-evidence; base=develop; number=1062 ;;' \
  '  repos/soramitsu/fearless-site-web/pulls/45) repository=soramitsu/fearless-site-web; repo_path="$FIXTURE_ROOT/fearless-site-web"; head=codex/site-todo-debt-baseline-hardening; base=develop; number=45 ;;' \
  '  repos/tonswap-org/ton-indexer/pulls/13) repository=tonswap-org/ton-indexer; repo_path="$FIXTURE_PARENT/ton-indexer"; head=codex/ti-smoke-body-preview-tests; base=develop; number=13 ;;' \
  '  repos/solswap-io/solswap-indexer/pulls/16) repository=solswap-io/solswap-indexer; repo_path="$FIXTURE_PARENT/solswap-indexer"; head=codex/si-smoke-body-preview-tests; base=develop; number=16 ;;' \
  '  repos/sora-xor/polkaswap-indexer/pulls/1) repository=sora-xor/polkaswap-indexer; repo_path="$FIXTURE_PARENT/polkaswap-indexer"; head=codex/pi-deployment-evidence-gate; base=develop; number=1 ;;' \
  '  *) exit 65 ;;' \
  'esac' \
  'if [[ "$mode" == mutate-after-inspection && "$repository" == sora-xor/polkaswap-indexer ]]; then printf "%s\\n" late-drift >> "$FIXTURE_ROOT/FEARLESS_PROJECT_PLAN.md"; fi' \
  'sha="$($REAL_GIT -C "$repo_path" rev-parse HEAD)"' \
  'if [[ "$mode" == modeled-live-iroha && "$repository" == hyperledger-iroha/iroha ]]; then sha="$IROHA_PR_HEAD_SHA"; fi' \
  'state=closed; merged_at=\"2026-07-10T08:00:00Z\"; head_repo="$repository"; base_repo="$repository"; html_url="https://github.com/$repository/pull/$number"' \
  '[[ "$mode" != stale-sha ]] || sha=0000000000000000000000000000000000000000' \
  '[[ "$mode" != wrong-head ]] || head=wrong/head' \
  '[[ "$mode" != wrong-base ]] || base=wrong-base' \
  '[[ "$mode" != fork-head ]] || head_repo=attacker/fork' \
  'if [[ "$mode" == open ]]; then state=open; merged_at=null; fi' \
  'if [[ "$mode" == closed ]]; then state=closed; merged_at=null; fi' \
  'json="{\"number\":$number,\"html_url\":\"$html_url\",\"state\":\"$state\",\"merged_at\":$merged_at,\"head\":{\"ref\":\"$head\",\"sha\":\"$sha\",\"repo\":{\"full_name\":\"$head_repo\"}},\"base\":{\"ref\":\"$base\",\"repo\":{\"full_name\":\"$base_repo\"}}}"' \
  'printf "%s\\n" "$json"' > "$FAKE_GH"
chmod +x "$FAKE_GH"

COMMON_ENV=(env SOURCE_PUBLICATION_TEST_MODE=1 SOURCE_PUBLICATION_NOW=2026-07-10T09:00:00.000Z REAL_GIT="$REAL_GIT" FIXTURE_ROOT="$ROOT" FIXTURE_PARENT="$PARENT" IROHA_REMOTE_ADVANCED_SHA="$IROHA_REMOTE_ADVANCED_SHA" IROHA_PR_HEAD_SHA="$IROHA_PR_HEAD_SHA" FAKE_GH_QUERY_DIR="$TMP_DIR/fake-gh-query-counts")
COMMON_ARGS=(node "$AUDIT" --test-tool-injection --root "$ROOT" --parent "$PARENT" --config "$ROOT/config/source-publication-readiness.tsv" --root-owner-config "$ROOT/config/source-publication-root-owner.json" --release-pr-config "$ROOT/config/release-readiness-prs.tsv")

expect_review_blocked "${COMMON_ENV[@]}" "${COMMON_ARGS[@]}" > "$TMP_DIR/local-success.log"
REPORT="$TMP_DIR/source-report.json"
expect_review_blocked "${COMMON_ENV[@]}" "${COMMON_ARGS[@]}" --check-remote --git-bin "$FAKE_GIT" --gh-bin "$FAKE_GH" --write-report "$REPORT" > "$TMP_DIR/remote-success.log"
node - "$REPORT" <<'NODE'
const fs = require('fs')
const report = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'))
if (report.schemaVersion !== 3 || report.phase !== 'standalone' || report.preflightReportSha256 !== null || report.status !== 'failed' || report.checkRemote !== true) process.exit(1)
if (report.totals.sources !== 9 || report.totals.passed !== 8 || report.totals.failed !== 1) process.exit(1)
if (report.rootOwnerConfigFile !== `${report.workspaceRoot}/config/source-publication-root-owner.json`) process.exit(1)
if (!report.workspaceSource || report.workspaceSource.repository !== 'example/fearless-release-orchestration' || report.workspaceSource.prState !== 'merged') process.exit(1)
if (report.repositories.length !== 8 || report.repositories.slice(0, -1).some((repo) => repo.status !== 'passed' || repo.prState !== 'merged')) process.exit(1)
for (const source of [report.workspaceSource, ...report.repositories]) {
  if (source.currentBranchRemotePresent !== true || !/^[0-9a-f]{40}$/.test(source.currentBranchRemoteSha ?? '')) process.exit(1)
  if (source.currentBranchRemoteSha !== source.headSha || source.currentBranchRemoteSha !== source.upstreamSha) process.exit(1)
  if (source.path !== '../iroha' && source.prHeadSha !== source.headSha) process.exit(1)
}
const iroha = report.repositories.at(-1)
if (iroha.path !== '../iroha' || iroha.repository !== 'hyperledger-iroha/iroha' || iroha.head !== 'optimizations' || iroha.base !== 'optimizations' || iroha.prNumber !== null || iroha.prUrl !== null || iroha.prState !== null || iroha.prHeadSha !== null || iroha.status !== 'failed') process.exit(1)
NODE

WALLET_EXCLUDE="$ROOT/fearless-wallet-web/.git/info/exclude"
cp "$WALLET_EXCLUDE" "$TMP_DIR/wallet-exclude-before-phase-tests"
printf '%s\n' 'node_modules/' 'build/' '.yarn/' >> "$WALLET_EXCLUDE"
mkdir -p "$ROOT/fearless-wallet-web/node_modules/example"
printf '%s\n' 'locked dependency cache' > "$ROOT/fearless-wallet-web/node_modules/example/index.js"
PREFLIGHT_REPORT="$TMP_DIR/source-publication-preflight-report.json"
expect_review_blocked "${COMMON_ENV[@]}" "${COMMON_ARGS[@]}" --check-remote --phase preflight --git-bin "$FAKE_GIT" --gh-bin "$FAKE_GH" --write-report "$PREFLIGHT_REPORT" > "$TMP_DIR/preflight-success.log"

node - "$PREFLIGHT_REPORT" <<'NODE'
const fs = require('fs')
const report = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'))
if (report.schemaVersion !== 3 || report.phase !== 'preflight' || report.preflightReportSha256 !== null) process.exit(1)
NODE

LEGACY_PREFLIGHT_REPORT="$TMP_DIR/source-publication-preflight-report-v2.json"
node - "$PREFLIGHT_REPORT" "$LEGACY_PREFLIGHT_REPORT" <<'NODE'
const fs = require('fs')
const [source, target] = process.argv.slice(2)
const report = JSON.parse(fs.readFileSync(source, 'utf8'))
report.schemaVersion = 2
fs.writeFileSync(target, `${JSON.stringify(report, null, 2)}\n`)
NODE
expect_failure legacy-v2-preflight-report 'source publication preflight report schemaVersion must be 3' \
  "${COMMON_ENV[@]}" "${COMMON_ARGS[@]}" --check-remote --phase postflight \
    --preflight-report "$LEGACY_PREFLIGHT_REPORT" --git-bin "$FAKE_GIT" --gh-bin "$FAKE_GH"

WRONG_PHASE_PREFLIGHT_REPORT="$TMP_DIR/source-publication-preflight-report-wrong-phase.json"
node - "$PREFLIGHT_REPORT" "$WRONG_PHASE_PREFLIGHT_REPORT" <<'NODE'
const fs = require('fs')
const [source, target] = process.argv.slice(2)
const report = JSON.parse(fs.readFileSync(source, 'utf8'))
report.phase = 'standalone'
fs.writeFileSync(target, `${JSON.stringify(report, null, 2)}\n`)
NODE
expect_failure wrong-phase-preflight-report 'source publication preflight report phase must be preflight' \
  "${COMMON_ENV[@]}" "${COMMON_ARGS[@]}" --check-remote --phase postflight \
    --preflight-report "$WRONG_PHASE_PREFLIGHT_REPORT" --git-bin "$FAKE_GIT" --gh-bin "$FAKE_GH"

SELF_BOUND_PREFLIGHT_REPORT="$TMP_DIR/source-publication-preflight-report-self-bound.json"
node - "$PREFLIGHT_REPORT" "$SELF_BOUND_PREFLIGHT_REPORT" <<'NODE'
const fs = require('fs')
const [source, target] = process.argv.slice(2)
const report = JSON.parse(fs.readFileSync(source, 'utf8'))
report.preflightReportSha256 = 'a'.repeat(64)
fs.writeFileSync(target, `${JSON.stringify(report, null, 2)}\n`)
NODE
expect_failure self-bound-preflight-report 'source publication preflight report must not bind another preflight report' \
  "${COMMON_ENV[@]}" "${COMMON_ARGS[@]}" --check-remote --phase postflight \
    --preflight-report "$SELF_BOUND_PREFLIGHT_REPORT" --git-bin "$FAKE_GIT" --gh-bin "$FAKE_GH"

mkdir -p "$ROOT/fearless-wallet-web/build/reports"
printf '%s\n' '{"currentRun":true}' > "$ROOT/fearless-wallet-web/build/reports/generated.json"
POSTFLIGHT_REPORT="$TMP_DIR/source-publication-postflight-report.json"
expect_review_blocked "${COMMON_ENV[@]}" "${COMMON_ARGS[@]}" --check-remote --phase postflight --preflight-report "$PREFLIGHT_REPORT" --git-bin "$FAKE_GIT" --gh-bin "$FAKE_GH" --write-report "$POSTFLIGHT_REPORT" > "$TMP_DIR/postflight-generated-output-success.log"
node - "$PREFLIGHT_REPORT" "$POSTFLIGHT_REPORT" <<'NODE'
const crypto = require('crypto')
const fs = require('fs')
const [preflightFile, postflightFile] = process.argv.slice(2)
const preflightBytes = fs.readFileSync(preflightFile)
const report = JSON.parse(fs.readFileSync(postflightFile, 'utf8'))
const expectedSha256 = crypto.createHash('sha256').update(preflightBytes).digest('hex')
if (report.schemaVersion !== 3 || report.phase !== 'postflight' || report.preflightReportSha256 !== expectedSha256) process.exit(1)
NODE
rm -rf "$ROOT/fearless-wallet-web/build"

mkdir -p "$ROOT/fearless-wallet-web/build"
printf '%s\n' 'stale output' > "$ROOT/fearless-wallet-web/build/stale.json"
expect_failure preflight-existing-generated-output 'worktree contains ignored non-published paths' \
  "${COMMON_ENV[@]}" "${COMMON_ARGS[@]}" --check-remote --phase preflight --git-bin "$FAKE_GIT" --gh-bin "$FAKE_GH"
rm -rf "$ROOT/fearless-wallet-web/build"

mkdir -p "$ROOT/fearless-wallet-web/.yarn"
printf '%s\n' 'ignored source override' > "$ROOT/fearless-wallet-web/.yarn/evil-source.js"
expect_failure postflight-yarn-source-injection 'worktree contains ignored non-published paths' \
  "${COMMON_ENV[@]}" "${COMMON_ARGS[@]}" --check-remote --phase postflight --preflight-report "$PREFLIGHT_REPORT" --git-bin "$FAKE_GIT" --gh-bin "$FAKE_GH"
rm -rf "$ROOT/fearless-wallet-web/.yarn"

mkdir -p "$TMP_DIR/external-node-modules"
rm -rf "$ROOT/fearless-wallet-web/node_modules"
ln -s "$TMP_DIR/external-node-modules" "$ROOT/fearless-wallet-web/node_modules"
expect_failure preflight-symlinked-cache 'worktree is not clean' \
  "${COMMON_ENV[@]}" "${COMMON_ARGS[@]}" --check-remote --phase preflight --git-bin "$FAKE_GIT" --gh-bin "$FAKE_GH"
rm "$ROOT/fearless-wallet-web/node_modules"

baseline_head="$($REAL_GIT -C "$ROOT/fearless-wallet-web" rev-parse HEAD)"
printf '%s\n' 'clean committed drift after preflight' >> "$ROOT/fearless-wallet-web/source.txt"
"$REAL_GIT" -C "$ROOT/fearless-wallet-web" commit -qam 'post-preflight drift'
"$REAL_GIT" -C "$ROOT/fearless-wallet-web" update-ref refs/remotes/origin/codex/web-bitcoin-canonical-indexer-evidence HEAD
expect_failure postflight-clean-head-drift 'source identity changed between release preflight and postflight' \
  "${COMMON_ENV[@]}" "${COMMON_ARGS[@]}" --check-remote --phase postflight --preflight-report "$PREFLIGHT_REPORT" --git-bin "$FAKE_GIT" --gh-bin "$FAKE_GH"
"$REAL_GIT" -C "$ROOT/fearless-wallet-web" reset -q --hard "$baseline_head"
"$REAL_GIT" -C "$ROOT/fearless-wallet-web" update-ref refs/remotes/origin/codex/web-bitcoin-canonical-indexer-evidence HEAD

iroha_baseline_head="$($REAL_GIT -C "$PARENT/iroha" rev-parse HEAD)"
printf '%s\n' 'unpublished Iroha drift after preflight' >> "$PARENT/iroha/source.txt"
"$REAL_GIT" -C "$PARENT/iroha" commit -qam 'post-preflight Iroha drift'
"$REAL_GIT" -C "$PARENT/iroha" update-ref refs/remotes/origin/optimizations HEAD
expect_failure postflight-iroha-head-drift 'source publication preflight did not pass before release checks' \
  "${COMMON_ENV[@]}" "${COMMON_ARGS[@]}" --check-remote --phase postflight --preflight-report "$PREFLIGHT_REPORT" --git-bin "$FAKE_GIT" --gh-bin "$FAKE_GH" --write-report "$TMP_DIR/iroha-drift-postflight.json"
node - "$PREFLIGHT_REPORT" "$TMP_DIR/iroha-drift-postflight.json" <<'NODE'
const fs = require('fs')
const [before, after] = process.argv.slice(2).map((file) => JSON.parse(fs.readFileSync(file, 'utf8')).repositories.at(-1))
if (before.headSha === after.headSha || after.headSha !== after.currentBranchRemoteSha || after.branch !== 'optimizations' || after.prNumber !== null || after.status !== 'failed') process.exit(1)
NODE
"$REAL_GIT" -C "$PARENT/iroha" reset -q --hard "$iroha_baseline_head"
"$REAL_GIT" -C "$PARENT/iroha" update-ref refs/remotes/origin/optimizations HEAD

cp "$PREFLIGHT_REPORT" "$TMP_DIR/forged-reviewed-optimizations.json"
node - "$TMP_DIR/forged-reviewed-optimizations.json" <<'NODE'
const fs = require('fs')
const file = process.argv[2]
const report = JSON.parse(fs.readFileSync(file, 'utf8'))
report.status = 'passed'
report.totals.passed = 9
report.totals.failed = 0
report.repositories.at(-1).status = 'passed'
report.repositories.at(-1).failures = []
fs.writeFileSync(file, JSON.stringify(report))
NODE
expect_failure forged-canonical-reviewed-preflight 'canonical branch exact-SHA review is blocked' \
  "${COMMON_ENV[@]}" "${COMMON_ARGS[@]}" --check-remote --phase postflight --preflight-report "$TMP_DIR/forged-reviewed-optimizations.json" --git-bin "$FAKE_GIT" --gh-bin "$FAKE_GH"

cp "$PREFLIGHT_REPORT" "$TMP_DIR/stale-preflight-report.json"
node - "$TMP_DIR/stale-preflight-report.json" <<'NODE'
const fs = require('fs')
const file = process.argv[2]
const report = JSON.parse(fs.readFileSync(file, 'utf8'))
report.generatedAt = '2026-07-09T00:00:00.000Z'
fs.writeFileSync(file, `${JSON.stringify(report, null, 2)}\n`)
NODE
expect_failure stale-preflight-report 'source publication preflight report is stale' \
  "${COMMON_ENV[@]}" "${COMMON_ARGS[@]}" --check-remote --phase postflight --preflight-report "$TMP_DIR/stale-preflight-report.json" --git-bin "$FAKE_GIT" --gh-bin "$FAKE_GH"

rm -rf "$ROOT/fearless-wallet-web/node_modules"
cp "$TMP_DIR/wallet-exclude-before-phase-tests" "$WALLET_EXCLUDE"

expect_review_blocked "${COMMON_ENV[@]}" GIT_DIR="$TMP_DIR/attacker-git-dir" GIT_WORK_TREE="$TMP_DIR/attacker-worktree" GH_HOST=attacker.invalid \
  GIT_SSH_COMMAND="$TMP_DIR/attacker-ssh" GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=core.sshCommand GIT_CONFIG_VALUE_0="$TMP_DIR/attacker-ssh" \
  "${COMMON_ARGS[@]}" --check-remote --git-bin "$FAKE_GIT" --gh-bin "$FAKE_GH" > "$TMP_DIR/scrubbed-tool-environment-success.log"

PROMPT_MARKER="$TMP_DIR/network-helper-executed"
ATTACKER_HELPER="$TMP_DIR/attacker-network-helper"
printf '%s\n' '#!/usr/bin/env bash' 'printf executed > "$PROMPT_MARKER"' 'exit 1' > "$ATTACKER_HELPER"
chmod +x "$ATTACKER_HELPER"
"$REAL_GIT" -C "$ROOT/fearless-wallet-web" config core.askPass "$ATTACKER_HELPER"
"$REAL_GIT" -C "$ROOT/fearless-wallet-web" config credential.helper "!$ATTACKER_HELPER"
"$REAL_GIT" -C "$ROOT/fearless-wallet-web" config core.sshCommand "$ATTACKER_HELPER"
"$REAL_GIT" -C "$ROOT/fearless-wallet-web" config core.fsmonitor "$ATTACKER_HELPER"
"$REAL_GIT" -C "$ROOT/fearless-wallet-web" config diff.external "$ATTACKER_HELPER"
expect_review_blocked "${COMMON_ENV[@]}" PROMPT_MARKER="$PROMPT_MARKER" \
  "${COMMON_ARGS[@]}" --check-remote --git-bin "$FAKE_GIT" --gh-bin "$FAKE_GH" > "$TMP_DIR/repository-network-config-isolation-success.log"
[[ ! -e "$PROMPT_MARKER" ]] || fail "network credential or SSH helper executed unexpectedly"
"$REAL_GIT" -C "$ROOT/fearless-wallet-web" config --unset-all core.askPass
"$REAL_GIT" -C "$ROOT/fearless-wallet-web" config --unset-all credential.helper
"$REAL_GIT" -C "$ROOT/fearless-wallet-web" config --unset-all core.sshCommand
"$REAL_GIT" -C "$ROOT/fearless-wallet-web" config --unset-all core.fsmonitor
"$REAL_GIT" -C "$ROOT/fearless-wallet-web" config --unset-all diff.external

printf '%s\n' 'dirty' >> "$ROOT/fearless-Android-production-consolidated-20260731/source.txt"
expect_failure unstaged 'worktree is not clean (staged=0, unstaged=1' "${COMMON_ENV[@]}" "${COMMON_ARGS[@]}"
"$REAL_GIT" -C "$ROOT/fearless-Android-production-consolidated-20260731" restore source.txt

printf '%s\n' 'staged' >> "$ROOT/fearless-iOS-production-consolidated-20260731/source.txt"
"$REAL_GIT" -C "$ROOT/fearless-iOS-production-consolidated-20260731" add source.txt
expect_failure staged 'worktree is not clean (staged=1' "${COMMON_ENV[@]}" "${COMMON_ARGS[@]}"
"$REAL_GIT" -C "$ROOT/fearless-iOS-production-consolidated-20260731" restore --staged source.txt
"$REAL_GIT" -C "$ROOT/fearless-iOS-production-consolidated-20260731" restore source.txt

printf '%s\n' 'untracked' > "$ROOT/fearless-wallet-web/untracked.txt"
expect_failure untracked 'untracked=1' "${COMMON_ENV[@]}" "${COMMON_ARGS[@]}"
rm "$ROOT/fearless-wallet-web/untracked.txt"

printf '%s\n' 'root drift' > "$ROOT/untracked-root.txt"
expect_failure root-untracked '.: worktree is not clean' "${COMMON_ENV[@]}" "${COMMON_ARGS[@]}"
rm "$ROOT/untracked-root.txt"

printf '%s\n' 'unpublished Iroha source' >> "$PARENT/iroha/source.txt"
expect_failure iroha-unstaged '../iroha: worktree is not clean (staged=0, unstaged=1' "${COMMON_ENV[@]}" "${COMMON_ARGS[@]}"
"$REAL_GIT" -C "$PARENT/iroha" restore source.txt

printf '%s\n' 'unpublished Iroha file' > "$PARENT/iroha/untracked-source.txt"
expect_failure iroha-untracked '../iroha: worktree is not clean (staged=0, unstaged=0, untracked=1' "${COMMON_ENV[@]}" "${COMMON_ARGS[@]}"
rm "$PARENT/iroha/untracked-source.txt"

IROHA_GIT_DIR="$("$REAL_GIT" -C "$PARENT/iroha" rev-parse --absolute-git-dir)"
IROHA_HEAD="$("$REAL_GIT" -C "$PARENT/iroha" rev-parse HEAD)"
MERGE_REPORT="$TMP_DIR/in-progress-merge-report.json"
printf '%s\n' "$IROHA_HEAD" > "$IROHA_GIT_DIR/MERGE_HEAD"
expect_failure in-progress-merge 'repository has an in-progress Git merge operation (MERGE_HEAD); only the repository owner may complete or abort it before source publication' \
  "${COMMON_ENV[@]}" "${COMMON_ARGS[@]}" --write-report "$MERGE_REPORT"
node - "$MERGE_REPORT" <<'NODE'
const fs = require('fs')
const report = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'))
const iroha = report.repositories.find((source) => source.path === '../iroha')
if (!iroha || iroha.status !== 'failed') process.exit(1)
if (!iroha.failures.includes('repository has an in-progress Git merge operation (MERGE_HEAD); only the repository owner may complete or abort it before source publication')) process.exit(1)
NODE
rm "$IROHA_GIT_DIR/MERGE_HEAD"

mkdir "$IROHA_GIT_DIR/rebase-merge"
expect_failure in-progress-rebase-merge 'repository has an in-progress Git rebase operation (rebase-merge)' "${COMMON_ENV[@]}" "${COMMON_ARGS[@]}"
rmdir "$IROHA_GIT_DIR/rebase-merge"

mkdir "$IROHA_GIT_DIR/rebase-apply"
expect_failure in-progress-rebase-apply 'repository has an in-progress Git rebase operation (rebase-apply)' "${COMMON_ENV[@]}" "${COMMON_ARGS[@]}"
rmdir "$IROHA_GIT_DIR/rebase-apply"

printf '%s\n' "$IROHA_HEAD" > "$IROHA_GIT_DIR/CHERRY_PICK_HEAD"
expect_failure in-progress-cherry-pick 'repository has an in-progress Git cherry-pick operation (CHERRY_PICK_HEAD)' "${COMMON_ENV[@]}" "${COMMON_ARGS[@]}"
rm "$IROHA_GIT_DIR/CHERRY_PICK_HEAD"

printf '%s\n' "$IROHA_HEAD" > "$IROHA_GIT_DIR/REVERT_HEAD"
expect_failure in-progress-revert 'repository has an in-progress Git revert operation (REVERT_HEAD)' "${COMMON_ENV[@]}" "${COMMON_ARGS[@]}"
rm "$IROHA_GIT_DIR/REVERT_HEAD"

printf '%s\n' "$IROHA_HEAD" > "$IROHA_GIT_DIR/BISECT_START"
expect_failure in-progress-bisect 'repository has an in-progress Git bisect operation (BISECT_START)' "${COMMON_ENV[@]}" "${COMMON_ARGS[@]}"
rm "$IROHA_GIT_DIR/BISECT_START"

mkdir "$IROHA_GIT_DIR/sequencer"
expect_failure in-progress-sequencer 'repository has an in-progress Git sequencer operation (sequencer)' "${COMMON_ENV[@]}" "${COMMON_ARGS[@]}"
rmdir "$IROHA_GIT_DIR/sequencer"

printf '%s\n' "$IROHA_HEAD" > "$TMP_DIR/spoofed-merge-head"
ln -s "$TMP_DIR/spoofed-merge-head" "$IROHA_GIT_DIR/MERGE_HEAD"
expect_failure symlinked-operation-marker 'Git operation marker MERGE_HEAD must not be a symlink' "${COMMON_ENV[@]}" "${COMMON_ARGS[@]}"
rm "$IROHA_GIT_DIR/MERGE_HEAD"

mv "$PARENT/iroha/.git" "$PARENT/iroha/.git-real"
ln -s .git-real "$PARENT/iroha/.git"
expect_failure symlinked-git-directory 'repository .git metadata entry must not be a symlink' "${COMMON_ENV[@]}" "${COMMON_ARGS[@]}"
rm "$PARENT/iroha/.git"
mv "$PARENT/iroha/.git-real" "$PARENT/iroha/.git"

expect_review_blocked "${COMMON_ENV[@]}" "${COMMON_ARGS[@]}" > "$TMP_DIR/post-operation-clean-success.log"

"$REAL_GIT" -C "$PARENT/iroha" checkout -q -b codex/unapproved-iroha
expect_failure iroha-wrong-branch '../iroha: current branch mismatch: expected optimizations, received codex/unapproved-iroha' "${COMMON_ENV[@]}" "${COMMON_ARGS[@]}"
"$REAL_GIT" -C "$PARENT/iroha" checkout -q optimizations
"$REAL_GIT" -C "$PARENT/iroha" branch -q -D codex/unapproved-iroha
"$REAL_GIT" -C "$PARENT/iroha" update-ref refs/remotes/origin/optimizations HEAD
"$REAL_GIT" -C "$PARENT/iroha" branch --set-upstream-to=origin/optimizations optimizations >/dev/null
IROHA_REMOTE_REPORT="$TMP_DIR/iroha-actual-branch-remote-advanced.json"
expect_failure iroha-actual-branch-remote-advanced 'does not match authoritative remote head' \
  env FAKE_GIT_MODE=advanced-current-iroha "${COMMON_ENV[@]}" "${COMMON_ARGS[@]}" \
    --check-remote --git-bin "$FAKE_GIT" --gh-bin "$FAKE_GH" --write-report "$IROHA_REMOTE_REPORT"
node - "$IROHA_REMOTE_REPORT" "$IROHA_REMOTE_ADVANCED_SHA" <<'NODE'
const fs = require('fs')
const [reportFile, expectedRemoteSha] = process.argv.slice(2)
const report = JSON.parse(fs.readFileSync(reportFile, 'utf8'))
const iroha = report.repositories.find((source) => source.path === '../iroha')
if (!iroha || iroha.branch !== 'optimizations' || iroha.currentBranchRemotePresent !== true) process.exit(1)
if (iroha.currentBranchRemoteSha !== expectedRemoteSha || iroha.upstreamSha !== iroha.headSha) process.exit(1)
if (!iroha.failures.some((failure) => failure.includes('cached upstream origin/optimizations') && failure.includes(expectedRemoteSha))) process.exit(1)
NODE
IROHA_MODELED_LIVE_REPORT="$TMP_DIR/iroha-modeled-live-state.json"
expect_failure iroha-modeled-live-state "local HEAD $IROHA_HEAD does not match authoritative remote head $IROHA_REMOTE_ADVANCED_SHA" \
  env FAKE_GIT_MODE=modeled-live-iroha FAKE_GH_MODE=modeled-live-iroha \
    "${COMMON_ENV[@]}" "${COMMON_ARGS[@]}" --check-remote --git-bin "$FAKE_GIT" --gh-bin "$FAKE_GH" \
      --write-report "$IROHA_MODELED_LIVE_REPORT"
node - "$IROHA_MODELED_LIVE_REPORT" "$IROHA_HEAD" "$IROHA_REMOTE_ADVANCED_SHA" "$IROHA_PR_HEAD_SHA" <<'NODE'
const fs = require('fs')
const [reportFile, localHead, actualRemoteHead, prHead] = process.argv.slice(2)
const report = JSON.parse(fs.readFileSync(reportFile, 'utf8'))
const iroha = report.repositories.find((source) => source.path === '../iroha')
if (!iroha || new Set([localHead, actualRemoteHead, prHead]).size !== 3) process.exit(1)
if (iroha.headSha !== localHead || iroha.prHeadSha !== null || iroha.upstreamSha !== localHead) process.exit(1)
if (iroha.currentBranchRemotePresent !== true || iroha.currentBranchRemoteSha !== actualRemoteHead) process.exit(1)
if (iroha.remoteBranchPresent !== true || iroha.remoteHeadSha !== actualRemoteHead || iroha.prState !== null || iroha.prNumber !== null) process.exit(1)
const expectedFailures = [
  `local HEAD ${localHead} does not match authoritative remote head ${actualRemoteHead}`,
  `cached upstream origin/optimizations at ${localHead} does not match authoritative current branch optimizations at ${actualRemoteHead}`,
  'canonical branch exact-SHA review is blocked: optimizations requires a verifiable reviewed/protected policy',
]
if (JSON.stringify(iroha.failures) !== JSON.stringify(expectedFailures)) process.exit(1)
NODE
expect_failure iroha-actual-branch-remote-missing 'authoritative canonical branch is missing or deleted: optimizations' \
  env FAKE_GIT_MODE=missing-current-iroha "${COMMON_ENV[@]}" "${COMMON_ARGS[@]}" \
    --check-remote --git-bin "$FAKE_GIT" --gh-bin "$FAKE_GH"
expect_failure iroha-actual-branch-remote-unavailable 'authoritative remote head is unavailable for optimizations' \
  env FAKE_GIT_MODE=error-current-iroha "${COMMON_ENV[@]}" "${COMMON_ARGS[@]}" \
    --check-remote --git-bin "$FAKE_GIT" --gh-bin "$FAKE_GH"
expect_failure iroha-actual-branch-remote-malformed 'authoritative remote head response is malformed for optimizations' \
  env FAKE_GIT_MODE=malformed-current-iroha "${COMMON_ENV[@]}" "${COMMON_ARGS[@]}" \
    --check-remote --git-bin "$FAKE_GIT" --gh-bin "$FAKE_GH"

"$REAL_GIT" -C "$PARENT/iroha" remote set-url origin https://github.com/attacker/iroha.git
expect_failure iroha-wrong-origin '../iroha: origin repository mismatch: expected hyperledger-iroha/iroha, received attacker/iroha' "${COMMON_ENV[@]}" "${COMMON_ARGS[@]}"
"$REAL_GIT" -C "$PARENT/iroha" remote set-url origin https://github.com/hyperledger-iroha/iroha.git

"$REAL_GIT" -C "$ROOT/fearless-Android-production-consolidated-20260731" update-index --assume-unchanged source.txt
printf '%s\n' 'hidden assume-unchanged drift' >> "$ROOT/fearless-Android-production-consolidated-20260731/source.txt"
expect_failure assume-unchanged 'Git index contains assume-unchanged or skip-worktree paths' "${COMMON_ENV[@]}" "${COMMON_ARGS[@]}"
"$REAL_GIT" -C "$ROOT/fearless-Android-production-consolidated-20260731" update-index --no-assume-unchanged source.txt
"$REAL_GIT" -C "$ROOT/fearless-Android-production-consolidated-20260731" restore source.txt

"$REAL_GIT" -C "$ROOT/fearless-iOS-production-consolidated-20260731" update-index --skip-worktree source.txt
printf '%s\n' 'hidden skip-worktree drift' >> "$ROOT/fearless-iOS-production-consolidated-20260731/source.txt"
expect_failure skip-worktree 'Git index contains assume-unchanged or skip-worktree paths' "${COMMON_ENV[@]}" "${COMMON_ARGS[@]}"
"$REAL_GIT" -C "$ROOT/fearless-iOS-production-consolidated-20260731" update-index --no-skip-worktree source.txt
"$REAL_GIT" -C "$ROOT/fearless-iOS-production-consolidated-20260731" restore source.txt

cp "$ROOT/fearless-wallet-web/.git/info/exclude" "$TMP_DIR/wallet-info-exclude"
printf '%s\n' 'ignored-generated.ts' >> "$ROOT/fearless-wallet-web/.git/info/exclude"
printf '%s\n' 'ignored but build-visible drift' > "$ROOT/fearless-wallet-web/ignored-generated.ts"
expect_failure ignored-build-input 'remove or quarantine these ignored outputs outside the source tree before publication; do not force-add generated artifacts' "${COMMON_ENV[@]}" "${COMMON_ARGS[@]}"
rm "$ROOT/fearless-wallet-web/ignored-generated.ts"
cp "$TMP_DIR/wallet-info-exclude" "$ROOT/fearless-wallet-web/.git/info/exclude"

printf '%s\n' 'external source' > "$TMP_DIR/external-source.txt"
ln -s "$TMP_DIR/external-source.txt" "$ROOT/fearless-site-web/escaping-source-link"
"$REAL_GIT" -C "$ROOT/fearless-site-web" add escaping-source-link
expect_failure escaping-tracked-symlink 'tracked symlinks escape the repository root' "${COMMON_ENV[@]}" "${COMMON_ARGS[@]}"
"$REAL_GIT" -C "$ROOT/fearless-site-web" restore --staged escaping-source-link
rm "$ROOT/fearless-site-web/escaping-source-link"

"$REAL_GIT" -C "$ROOT/fearless-site-web" checkout -q --detach
expect_failure detached 'HEAD is detached' "${COMMON_ENV[@]}" "${COMMON_ARGS[@]}"
"$REAL_GIT" -C "$ROOT/fearless-site-web" checkout -q codex/site-todo-debt-baseline-hardening

"$REAL_GIT" -C "$PARENT/ton-indexer" checkout -q -b wrong-branch
expect_failure wrong-branch 'current branch mismatch' "${COMMON_ENV[@]}" "${COMMON_ARGS[@]}"
"$REAL_GIT" -C "$PARENT/ton-indexer" checkout -q codex/ti-smoke-body-preview-tests
"$REAL_GIT" -C "$PARENT/ton-indexer" branch -q -D wrong-branch

"$REAL_GIT" -C "$PARENT/solswap-indexer" remote set-url origin https://github.com/attacker/wrong.git
expect_failure wrong-origin 'origin repository mismatch' "${COMMON_ENV[@]}" "${COMMON_ARGS[@]}"
"$REAL_GIT" -C "$PARENT/solswap-indexer" remote set-url origin https://github.com/solswap-io/solswap-indexer.git

CREDENTIAL_ORIGIN_REPORT="$TMP_DIR/credential-origin-report.json"
"$REAL_GIT" -C "$PARENT/solswap-indexer" remote set-url origin https://operator:secret@github.com/solswap-io/solswap-indexer.git
expect_failure credential-origin 'origin must be a credential-free github.com HTTPS or SSH URL' "${COMMON_ENV[@]}" "${COMMON_ARGS[@]}" --write-report "$CREDENTIAL_ORIGIN_REPORT"
node - "$CREDENTIAL_ORIGIN_REPORT" <<'NODE'
const fs = require('fs')
const content = fs.readFileSync(process.argv[2], 'utf8')
if (content.includes('operator:secret') || content.includes('operator') || content.includes('secret@')) process.exit(1)
const report = JSON.parse(content)
const source = report.repositories.find((repository) => repository.path === '../solswap-indexer')
if (!source || source.originUrl !== null || source.originRepository !== null) process.exit(1)
NODE
"$REAL_GIT" -C "$PARENT/solswap-indexer" remote set-url origin https://github.com/solswap-io/solswap-indexer.git

branch=codex/pi-deployment-evidence-gate
"$REAL_GIT" -C "$PARENT/polkaswap-indexer" update-ref "refs/remotes/origin/$branch" HEAD^
expect_failure stale-upstream 'does not match upstream' "${COMMON_ENV[@]}" "${COMMON_ARGS[@]}"
expect_failure cached-upstream-vs-live-remote 'cached upstream origin/codex/pi-deployment-evidence-gate' \
  "${COMMON_ENV[@]}" "${COMMON_ARGS[@]}" --check-remote --git-bin "$FAKE_GIT" --gh-bin "$FAKE_GH"
"$REAL_GIT" -C "$PARENT/polkaswap-indexer" update-ref "refs/remotes/origin/$branch" HEAD

mv "$ROOT/fearless-iOS-production-consolidated-20260731" "$ROOT/fearless-iOS-production-consolidated-20260731-real"
ln -s fearless-iOS-production-consolidated-20260731-real "$ROOT/fearless-iOS-production-consolidated-20260731"
expect_failure symlink-repo 'repository path must be a real directory' "${COMMON_ENV[@]}" "${COMMON_ARGS[@]}"
rm "$ROOT/fearless-iOS-production-consolidated-20260731"
mv "$ROOT/fearless-iOS-production-consolidated-20260731-real" "$ROOT/fearless-iOS-production-consolidated-20260731"

mv "$ROOT/.git" "$ROOT/.git.saved"
expect_failure root-unowned 'source has no Git repository owner' "${COMMON_ENV[@]}" "${COMMON_ARGS[@]}"
mv "$ROOT/.git.saved" "$ROOT/.git"

"$REAL_GIT" -C "$ROOT" rm -q --cached FEARLESS_PROJECT_PLAN.md
expect_failure untracked-required 'required production source is not Git-tracked: FEARLESS_PROJECT_PLAN.md' "${COMMON_ENV[@]}" "${COMMON_ARGS[@]}"
"$REAL_GIT" -C "$ROOT" reset -q FEARLESS_PROJECT_PLAN.md

for required_file in services/passkey-backup-owner-authority/src/authority.js scripts/audit-plan-readiness.sh; do
  "$REAL_GIT" -C "$ROOT" rm -q --cached "$required_file"
  expect_failure "untracked-required-source-$required_file" "required production source is not Git-tracked: $required_file" "${COMMON_ENV[@]}" "${COMMON_ARGS[@]}"
  "$REAL_GIT" -C "$ROOT" reset -q "$required_file"
done

expect_failure remote-stale 'does not match authoritative remote head' env FAKE_GIT_MODE=stale-fearless-wallet-web "${COMMON_ENV[@]}" "${COMMON_ARGS[@]}" --check-remote --git-bin "$FAKE_GIT" --gh-bin "$FAKE_GH"
expect_failure remote-missing 'authoritative remote branch is missing for unmerged pull request' env FAKE_GIT_MODE=missing-ton-indexer FAKE_GH_MODE=open "${COMMON_ENV[@]}" "${COMMON_ARGS[@]}" --check-remote --git-bin "$FAKE_GIT" --gh-bin "$FAKE_GH"
expect_failure remote-error 'authoritative remote head is unavailable' env FAKE_GIT_MODE=error-solswap-indexer "${COMMON_ENV[@]}" "${COMMON_ARGS[@]}" --check-remote --git-bin "$FAKE_GIT" --gh-bin "$FAKE_GH"
expect_failure remote-malformed 'authoritative remote head response is malformed' env FAKE_GIT_MODE=malformed-polkaswap-indexer "${COMMON_ENV[@]}" "${COMMON_ARGS[@]}" --check-remote --git-bin "$FAKE_GIT" --gh-bin "$FAKE_GH"
expect_failure api-error 'authoritative pull request query failed' env FAKE_GH_MODE=error "${COMMON_ENV[@]}" "${COMMON_ARGS[@]}" --check-remote --git-bin "$FAKE_GIT" --gh-bin "$FAKE_GH"
expect_failure api-invalid 'returned invalid JSON' env FAKE_GH_MODE=invalid-json "${COMMON_ENV[@]}" "${COMMON_ARGS[@]}" --check-remote --git-bin "$FAKE_GIT" --gh-bin "$FAKE_GH"
expect_failure pr-stale-sha 'does not match pull request head' env FAKE_GH_MODE=stale-sha "${COMMON_ENV[@]}" "${COMMON_ARGS[@]}" --check-remote --git-bin "$FAKE_GIT" --gh-bin "$FAKE_GH"
expect_failure pr-wrong-head 'pull request head identity mismatch' env FAKE_GH_MODE=wrong-head "${COMMON_ENV[@]}" "${COMMON_ARGS[@]}" --check-remote --git-bin "$FAKE_GIT" --gh-bin "$FAKE_GH"
expect_failure pr-wrong-base 'pull request base identity mismatch' env FAKE_GH_MODE=wrong-base "${COMMON_ENV[@]}" "${COMMON_ARGS[@]}" --check-remote --git-bin "$FAKE_GIT" --gh-bin "$FAKE_GH"
expect_failure pr-fork 'pull request head identity mismatch' env FAKE_GH_MODE=fork-head "${COMMON_ENV[@]}" "${COMMON_ARGS[@]}" --check-remote --git-bin "$FAKE_GIT" --gh-bin "$FAKE_GH"
expect_failure pr-open 'pull request state mismatch: required merged, received open' env FAKE_GH_MODE=open "${COMMON_ENV[@]}" "${COMMON_ARGS[@]}" --check-remote --git-bin "$FAKE_GIT" --gh-bin "$FAKE_GH"
expect_failure pr-closed 'pull request state mismatch: required merged, received closed' env FAKE_GH_MODE=closed "${COMMON_ENV[@]}" "${COMMON_ARGS[@]}" --check-remote --git-bin "$FAKE_GIT" --gh-bin "$FAKE_GH"
expect_failure final-state-race 'local source state changed after publication inspection' env FAKE_GH_MODE=mutate-after-inspection "${COMMON_ENV[@]}" "${COMMON_ARGS[@]}" --check-remote --git-bin "$FAKE_GIT" --gh-bin "$FAKE_GH"
"$REAL_GIT" -C "$ROOT" restore FEARLESS_PROJECT_PLAN.md

# matching-current-branch-reuses-configured-head: one authoritative ref query mirrors
# the configured-head deletion proof into the actual-current-branch report fields.
MERGED_DELETED_REPORT="$TMP_DIR/merged-deleted-current-branch.json"
expect_failure canonical-branch-deletion 'authoritative canonical branch is missing or deleted: optimizations' "${COMMON_ENV[@]}" FAKE_GH_MODE=merged FAKE_GIT_MODE=missing "${COMMON_ARGS[@]}" \
  --check-remote --git-bin "$FAKE_GIT" --gh-bin "$FAKE_GH" --write-report "$MERGED_DELETED_REPORT" \
  > "$TMP_DIR/merged-deleted-success.log"
node - "$MERGED_DELETED_REPORT" <<'NODE'
const fs = require('fs')
const report = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'))
if (report.status !== 'failed' || report.totals.passed !== 8 || report.repositories.at(-1).prState !== null) process.exit(1)
for (const source of [report.workspaceSource, ...report.repositories]) {
  if (source.remoteBranchPresent !== false || source.remoteHeadSha !== null) process.exit(1)
  if (source.currentBranchRemotePresent !== false || source.currentBranchRemoteSha !== null) process.exit(1)
}
NODE

BAD_CONFIG="$TMP_DIR/duplicate.tsv"
cp "$ROOT/config/source-publication-readiness.tsv" "$BAD_CONFIG"
tail -n 1 "$BAD_CONFIG" >> "$BAD_CONFIG"
expect_failure duplicate-config 'duplicate source publication repo path' "${COMMON_ENV[@]}" node "$AUDIT" --test-tool-injection --root "$ROOT" --parent "$PARENT" --config "$BAD_CONFIG" --root-owner-config "$ROOT/config/source-publication-root-owner.json" --release-pr-config "$ROOT/config/release-readiness-prs.tsv"

BAD_CONFIG="$TMP_DIR/missing.tsv"
sed '$d' "$ROOT/config/source-publication-readiness.tsv" > "$BAD_CONFIG"
expect_failure missing-config 'must contain exactly 8 repository rows' "${COMMON_ENV[@]}" node "$AUDIT" --test-tool-injection --root "$ROOT" --parent "$PARENT" --config "$BAD_CONFIG" --root-owner-config "$ROOT/config/source-publication-root-owner.json" --release-pr-config "$ROOT/config/release-readiness-prs.tsv"

BAD_CONFIG="$TMP_DIR/missing-iroha.tsv"
grep -v '^\.\./iroha' "$ROOT/config/source-publication-readiness.tsv" > "$BAD_CONFIG"
expect_failure missing-iroha-config 'source publication config must contain exactly 8 repository rows' "${COMMON_ENV[@]}" node "$AUDIT" --test-tool-injection --root "$ROOT" --parent "$PARENT" --config "$BAD_CONFIG" --root-owner-config "$ROOT/config/source-publication-root-owner.json" --release-pr-config "$ROOT/config/release-readiness-prs.tsv"

BAD_CONFIG="$TMP_DIR/wrong-iroha-identity.tsv"
sed 's#hyperledger-iroha/iroha#attacker/iroha#' "$ROOT/config/source-publication-readiness.tsv" > "$BAD_CONFIG"
expect_failure wrong-iroha-config-identity 'repository mismatch for ../iroha: expected hyperledger-iroha/iroha' "${COMMON_ENV[@]}" node "$AUDIT" --test-tool-injection --root "$ROOT" --parent "$PARENT" --config "$BAD_CONFIG" --root-owner-config "$ROOT/config/source-publication-root-owner.json" --release-pr-config "$ROOT/config/release-readiness-prs.tsv"

BAD_CONFIG="$TMP_DIR/wrong-iroha-order.tsv"
node - "$ROOT/config/source-publication-readiness.tsv" "$BAD_CONFIG" <<'NODE'
const fs = require('fs')
const [source, output] = process.argv.slice(2)
const lines = fs.readFileSync(source, 'utf8').trimEnd().split('\n')
const last = lines.pop()
lines.splice(lines.length - 1, 0, last)
fs.writeFileSync(output, `${lines.join('\n')}\n`)
NODE
expect_failure wrong-iroha-config-order 'source publication config repository order must be' "${COMMON_ENV[@]}" node "$AUDIT" --test-tool-injection --root "$ROOT" --parent "$PARENT" --config "$BAD_CONFIG" --root-owner-config "$ROOT/config/source-publication-root-owner.json" --release-pr-config "$ROOT/config/release-readiness-prs.tsv"

BAD_CONFIG="$TMP_DIR/traversal.tsv"
sed 's#^fearless-Android-production-consolidated-20260731#../../escape#' "$ROOT/config/source-publication-readiness.tsv" > "$BAD_CONFIG"
expect_failure traversal-config 'unsupported source publication repo path' "${COMMON_ENV[@]}" node "$AUDIT" --test-tool-injection --root "$ROOT" --parent "$PARENT" --config "$BAD_CONFIG" --root-owner-config "$ROOT/config/source-publication-root-owner.json" --release-pr-config "$ROOT/config/release-readiness-prs.tsv"

BAD_RELEASE="$TMP_DIR/missing-release.tsv"
grep -v 'codex/si-smoke-body-preview-tests' "$ROOT/config/release-readiness-prs.tsv" > "$BAD_RELEASE"
expect_failure missing-release-row 'must contain exactly one matching row' "${COMMON_ENV[@]}" node "$AUDIT" --test-tool-injection --root "$ROOT" --parent "$PARENT" --config "$ROOT/config/source-publication-readiness.tsv" --root-owner-config "$ROOT/config/source-publication-root-owner.json" --release-pr-config "$BAD_RELEASE"

ln -s "$ROOT/config/source-publication-readiness.tsv" "$TMP_DIR/config-link.tsv"
expect_failure symlink-config 'source publication config must not use a symlinked path component' "${COMMON_ENV[@]}" node "$AUDIT" --test-tool-injection --root "$ROOT" --parent "$PARENT" --config "$TMP_DIR/config-link.tsv" --root-owner-config "$ROOT/config/source-publication-root-owner.json" --release-pr-config "$ROOT/config/release-readiness-prs.tsv"

BLOCKED_ROOT_OWNER="$TMP_DIR/blocked-root-owner.json"
cat > "$BLOCKED_ROOT_OWNER" <<'JSON'
{
  "schemaVersion": 1,
  "status": "blocked",
  "repository": null,
  "head": null,
  "base": null,
  "prNumber": null,
  "lastReviewed": "2026-07-10",
  "blocker": "canonical-root-source-owner-unassigned"
}
JSON
BLOCKED_REPORT="$TMP_DIR/blocked-root-owner-report.json"
expect_failure blocked-root-owner 'workspace source owner is blocked: canonical-root-source-owner-unassigned' "${COMMON_ENV[@]}" "${COMMON_ARGS[@]}" --root-owner-config "$BLOCKED_ROOT_OWNER" --write-report "$BLOCKED_REPORT"
node - "$BLOCKED_REPORT" <<'NODE'
const fs = require('fs')
const report = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'))
const source = report.workspaceSource
if (report.status !== 'failed' || source.repository !== null || source.head !== null || source.base !== null || source.prNumber !== null || source.prState !== null) process.exit(1)
NODE

FORGED_ROOT_OWNER="$TMP_DIR/forged-root-owner.json"
FORGED_RELEASE_CONFIG="$TMP_DIR/forged-release-config.tsv"
node - "$ROOT/config/source-publication-root-owner.json" "$FORGED_ROOT_OWNER" "$ROOT/config/release-readiness-prs.tsv" "$FORGED_RELEASE_CONFIG" <<'NODE'
const fs = require('fs')
const [ownerSource, ownerOutput, releaseSource, releaseOutput] = process.argv.slice(2)
const owner = JSON.parse(fs.readFileSync(ownerSource, 'utf8'))
owner.repository = 'attacker/wrong'
fs.writeFileSync(ownerOutput, `${JSON.stringify(owner, null, 2)}\n`)
const release = fs.readFileSync(releaseSource, 'utf8').replace(
  'example/fearless-release-orchestration\tcodex/root-release\tmain\tmerged\tvalidate',
  'attacker/wrong\tcodex/root-release\tmain\tmerged\tvalidate',
)
fs.writeFileSync(releaseOutput, release)
NODE
expect_failure forged-root-owner 'workspace origin repository mismatch: expected attacker/wrong' "${COMMON_ENV[@]}" "${COMMON_ARGS[@]}" --root-owner-config "$FORGED_ROOT_OWNER" --release-pr-config "$FORGED_RELEASE_CONFIG"

INVALID_BLOCKED_ROOT_OWNER="$TMP_DIR/invalid-blocked-root-owner.json"
cp "$BLOCKED_ROOT_OWNER" "$INVALID_BLOCKED_ROOT_OWNER"
node - "$INVALID_BLOCKED_ROOT_OWNER" <<'NODE'
const fs = require('fs')
const file = process.argv[2]
const owner = JSON.parse(fs.readFileSync(file, 'utf8'))
owner.repository = 'attacker/wrong'
fs.writeFileSync(file, `${JSON.stringify(owner, null, 2)}\n`)
NODE
expect_failure invalid-blocked-root-owner 'blocked source publication root owner config repository must be null' "${COMMON_ENV[@]}" "${COMMON_ARGS[@]}" --root-owner-config "$INVALID_BLOCKED_ROOT_OWNER"

ln -s "$TMP_DIR" "$TMP_DIR/symlink-prefix"
ALIAS_ROOT="$TMP_DIR/symlink-prefix/fixture/workspace"
ALIAS_PARENT="$TMP_DIR/symlink-prefix/fixture"
expect_failure symlink-root-prefix 'workspace root must not use a symlinked path component' "${COMMON_ENV[@]}" node "$AUDIT" --test-tool-injection --root "$ALIAS_ROOT" --parent "$ALIAS_PARENT" --config "$ALIAS_ROOT/config/source-publication-readiness.tsv" --root-owner-config "$ALIAS_ROOT/config/source-publication-root-owner.json" --release-pr-config "$ALIAS_ROOT/config/release-readiness-prs.tsv"

ln -s "$ROOT/config" "$TMP_DIR/config-parent-link"
expect_failure symlink-config-parent 'source publication config must not use a symlinked path component' "${COMMON_ENV[@]}" "${COMMON_ARGS[@]}" --config "$TMP_DIR/config-parent-link/source-publication-readiness.tsv"
expect_failure symlink-root-owner-parent 'source publication root owner config must not use a symlinked path component' "${COMMON_ENV[@]}" "${COMMON_ARGS[@]}" --root-owner-config "$TMP_DIR/config-parent-link/source-publication-root-owner.json"
expect_failure symlink-release-config-parent 'release PR config must not use a symlinked path component' "${COMMON_ENV[@]}" "${COMMON_ARGS[@]}" --release-pr-config "$TMP_DIR/config-parent-link/release-readiness-prs.tsv"

mkdir -p "$TMP_DIR/outside-report-parent"
ln -s "$TMP_DIR/outside-report-parent" "$TMP_DIR/report-parent-link"
expect_failure symlink-report-parent 'report output parent must not use a symlinked path component' "${COMMON_ENV[@]}" "${COMMON_ARGS[@]}" --write-report "$TMP_DIR/report-parent-link/report.json"
[[ ! -e "$TMP_DIR/outside-report-parent/report.json" ]] || fail 'symlinked report parent wrote outside the intended report path'

PRODUCTION_ARGS=(node "$AUDIT" --root "$ROOT" --parent "$PARENT")
expect_failure production-cli-tool-injection '--git-bin and --gh-bin are forbidden outside explicit test-tool-injection mode' env -u SOURCE_PUBLICATION_TEST_MODE -u SOURCE_PUBLICATION_NOW "${PRODUCTION_ARGS[@]}" --git-bin "$FAKE_GIT"
expect_failure production-env-tool-injection 'SOURCE_PUBLICATION_GIT_BIN is forbidden outside explicit test-tool-injection mode' env -u SOURCE_PUBLICATION_TEST_MODE -u SOURCE_PUBLICATION_NOW SOURCE_PUBLICATION_GIT_BIN="$FAKE_GIT" "${PRODUCTION_ARGS[@]}"
expect_failure production-node-options-injection 'NODE_OPTIONS is forbidden outside explicit test-tool-injection mode' env -u SOURCE_PUBLICATION_TEST_MODE -u SOURCE_PUBLICATION_NOW NODE_OPTIONS=--no-warnings "${PRODUCTION_ARGS[@]}"
expect_failure relative-test-tool-injection 'test git executable must be an absolute normalized path' "${COMMON_ENV[@]}" "${COMMON_ARGS[@]}" --git-bin relative-git

WRAPPER_TEST_ROOT="$TMP_DIR/wrapper-test-root"
mkdir -p "$WRAPPER_TEST_ROOT"
WRAPPER_FAKE_NODE="$WRAPPER_TEST_ROOT/fake-node"
WRAPPER_CAPTURE="$TMP_DIR/wrapper-node-capture.txt"
printf '%s\n' \
  '#!/usr/bin/env bash' \
  'set -euo pipefail' \
  '[[ -z "${NODE_OPTIONS+x}" && -z "${NODE_BIN+x}" && -z "${SOURCE_PUBLICATION_NODE_BIN+x}" && -z "${SOURCE_PUBLICATION_WRAPPER_TEST_MODE+x}" && -z "${SOURCE_PUBLICATION_WRAPPER_TEST_ROOT+x}" ]] || exit 80' \
  'printf "%s\n" "$@" > "$WRAPPER_CAPTURE"' > "$WRAPPER_FAKE_NODE"
chmod +x "$WRAPPER_FAKE_NODE"
SOURCE_PUBLICATION_WRAPPER_TEST_MODE=1 \
SOURCE_PUBLICATION_WRAPPER_TEST_ROOT="$WRAPPER_TEST_ROOT" \
SOURCE_PUBLICATION_NODE_BIN="$WRAPPER_FAKE_NODE" \
WRAPPER_CAPTURE="$WRAPPER_CAPTURE" \
  "$RUNNER" --help
[[ "$(sed -n '1p' "$WRAPPER_CAPTURE")" == "$AUDIT" && "$(sed -n '2p' "$WRAPPER_CAPTURE")" == '--help' ]] ||
  fail "source publication runner did not preserve the canonical audit path and arguments"

PRELOAD_MARKER="$TMP_DIR/node-options-preload-executed"
PRELOAD_MODULE="$TMP_DIR/node-options-preload.mjs"
printf '%s\n' 'import fs from "node:fs";' 'fs.writeFileSync(process.env.PRELOAD_MARKER, "executed");' > "$PRELOAD_MODULE"
expect_failure wrapper-node-options-preload 'NODE_OPTIONS is forbidden before the source-publication Node process starts' \
  env NODE_OPTIONS="--import=$PRELOAD_MODULE" PRELOAD_MARKER="$PRELOAD_MARKER" "$RUNNER" --help
[[ ! -e "$PRELOAD_MARKER" ]] || fail "NODE_OPTIONS preload executed before the source publication runner rejected it"
expect_failure wrapper-production-node-override 'NODE_BIN is forbidden outside explicit SOURCE_PUBLICATION_WRAPPER_TEST_MODE=1' \
  env NODE_BIN="$WRAPPER_FAKE_NODE" "$RUNNER" --help
expect_failure wrapper-missing-test-root 'SOURCE_PUBLICATION_WRAPPER_TEST_ROOT is required in test mode' \
  env SOURCE_PUBLICATION_WRAPPER_TEST_MODE=1 SOURCE_PUBLICATION_NODE_BIN="$WRAPPER_FAKE_NODE" "$RUNNER" --help
expect_failure wrapper-node-outside-test-root 'test Node executable must be contained by the isolated test root' \
  env SOURCE_PUBLICATION_WRAPPER_TEST_MODE=1 SOURCE_PUBLICATION_WRAPPER_TEST_ROOT="$TMP_DIR/outside-report-parent" SOURCE_PUBLICATION_NODE_BIN="$WRAPPER_FAKE_NODE" "$RUNNER" --help
"$RUNNER" --help > "$TMP_DIR/wrapper-production-help.log"
grep -Fq 'Usage: audit-source-publication-readiness.mjs' "$TMP_DIR/wrapper-production-help.log" ||
  fail "production source publication runner did not execute the canonical audit module"

STALE_REPORT="$TMP_DIR/stale-source-report.json"
printf '%s\n' '{"stale":true}' > "$STALE_REPORT"
EARLY_BAD_CONFIG="$TMP_DIR/early-bad-config.tsv"
cp "$ROOT/config/source-publication-readiness.tsv" "$EARLY_BAD_CONFIG"
tail -n 1 "$EARLY_BAD_CONFIG" >> "$EARLY_BAD_CONFIG"
expect_failure stale-report-replaced 'duplicate source publication repo path' "${COMMON_ENV[@]}" "${COMMON_ARGS[@]}" --config "$EARLY_BAD_CONFIG" --write-report "$STALE_REPORT"
node - "$STALE_REPORT" <<'NODE'
const fs = require('fs')
const report = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'))
if (report.stale === true || report.schemaVersion !== 3 || report.phase !== 'standalone' || report.preflightReportSha256 !== null || report.status !== 'failed' || report.totals.failed !== 9) process.exit(1)
if (!report.workspaceSource.failures.some((failure) => failure.includes('duplicate source publication repo path'))) process.exit(1)
NODE

printf '%s\n' '{}' > "$TMP_DIR/report-target.json"
ln -s "$TMP_DIR/report-target.json" "$TMP_DIR/report-link.json"
expect_failure symlink-report 'report output must be a regular non-symlink file' "${COMMON_ENV[@]}" "${COMMON_ARGS[@]}" --write-report "$TMP_DIR/report-link.json"

echo "[source-publication-test] source publication readiness adversarial cases passed ($NEGATIVE_CASES negative cases)"
