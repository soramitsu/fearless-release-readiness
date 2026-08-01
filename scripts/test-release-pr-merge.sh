#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
MERGER="$SCRIPT_DIR/merge-release-prs.sh"

fail() {
  echo "[release-pr-merge-test][error] $*" >&2
  exit 1
}

tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

config="$tmp_dir/release-prs.tsv"
sha_a="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
sha_b="bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"

write_config() {
  cat > "$config" <<'TSV'
# repo	head	base	required_state	required_checks
example/repo	codex/release	develop	merged	validate,verify
TSV
}

run_merger() {
  GH_BIN="$tmp_dir/gh" \
    FAKE_GH_SCENARIO="${FAKE_GH_SCENARIO:-ready}" \
    FAKE_GH_MERGE_SCENARIO="${FAKE_GH_MERGE_SCENARIO:-ok}" \
    FAKE_GH_MERGE_LOG="${FAKE_GH_MERGE_LOG:-$tmp_dir/merge-default.log}" \
    "$MERGER" --config "$config" "$@"
}

expect_success() {
  local name="$1"
  local expected="$2"
  shift 2
  local output
  if ! output="$("$@" 2>&1)"; then
    echo "$output" >&2
    fail "$name unexpectedly failed"
  fi
  if [[ "$output" != *"$expected"* ]]; then
    echo "$output" >&2
    fail "$name did not report expected text: $expected"
  fi
}

expect_failure() {
  local name="$1"
  local expected="$2"
  shift 2
  local output
  set +e
  output="$("$@" 2>&1)"
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

cat > "$tmp_dir/gh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail

scenario="${FAKE_GH_SCENARIO:-ready}"
sha_a="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
sha_b="bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"

successful_checks() {
  cat <<JSON
[
  {"name":"validate","status":"COMPLETED","conclusion":"SUCCESS","completedAt":"2026-06-28T00:00:00Z"},
  {"name":"verify","status":"COMPLETED","conclusion":"SUCCESS","completedAt":"2026-06-28T00:01:00Z"}
]
JSON
}

pending_checks() {
  cat <<JSON
[
  {"name":"validate","status":"COMPLETED","conclusion":"SUCCESS","completedAt":"2026-06-28T00:00:00Z"},
  {"name":"verify","status":"IN_PROGRESS","conclusion":null,"startedAt":"2026-06-28T00:01:00Z"}
]
JSON
}

missing_checks() {
  cat <<JSON
[
  {"name":"validate","status":"COMPLETED","conclusion":"SUCCESS","completedAt":"2026-06-28T00:00:00Z"}
]
JSON
}

duplicate_checks() {
  cat <<JSON
[
  {"name":"validate","status":"COMPLETED","conclusion":"SUCCESS","completedAt":"2026-06-28T00:00:00Z"},
  {"name":"verify","status":"COMPLETED","conclusion":"SUCCESS","completedAt":"2026-06-28T00:01:00Z"},
  {"name":"verify","status":"COMPLETED","conclusion":"SUCCESS","completedAt":"2026-06-28T00:01:00Z"}
]
JSON
}

review_payload() {
  case "$scenario" in
    review-required-current-approval)
      printf '[{"state":"APPROVED","submittedAt":"2026-06-28T00:02:00Z","commit":{"oid":"%s"}}]' "$sha_a"
      ;;
    review-required-stale-approval)
      printf '[{"state":"APPROVED","submittedAt":"2026-06-28T00:02:00Z","commit":{"oid":"%s"}}]' "$sha_b"
      ;;
    review-details-malformed)
      printf '{}'
      ;;
    *)
      printf '[]'
      ;;
  esac
}

pr_payload() {
  local state="${1:-OPEN}"
  local draft="${2:-false}"
  local review="${3:-APPROVED}"
  local merge_state="${4:-CLEAN}"
  local head_sha="${5:-$sha_a}"
  local checks="${6:-success}"
  local check_json reviews_json
  case "$checks" in
    pending) check_json="$(pending_checks)" ;;
    missing) check_json="$(missing_checks)" ;;
    duplicate) check_json="$(duplicate_checks)" ;;
    malformed) check_json='{}' ;;
    *) check_json="$(successful_checks)" ;;
  esac
  reviews_json="$(review_payload)"

  if [[ "$state" == "MERGED" ]]; then
    printf '[{"number":42,"url":"https://github.com/example/repo/pull/42","state":"MERGED","mergedAt":"2026-06-28T00:10:00Z","headRefOid":"%s","isDraft":false,"reviewDecision":"APPROVED","mergeStateStatus":"CLEAN","statusCheckRollup":%s,"reviews":%s}]\n' "$head_sha" "$check_json" "$reviews_json"
  elif [[ "$state" == "CLOSED" ]]; then
    printf '[{"number":42,"url":"https://github.com/example/repo/pull/42","state":"CLOSED","mergedAt":null,"headRefOid":"%s","isDraft":false,"reviewDecision":"APPROVED","mergeStateStatus":"CLEAN","statusCheckRollup":%s,"reviews":%s}]\n' "$head_sha" "$check_json" "$reviews_json"
  else
    printf '[{"number":42,"url":"https://github.com/example/repo/pull/42","state":"OPEN","mergedAt":null,"headRefOid":"%s","isDraft":%s,"reviewDecision":"%s","mergeStateStatus":"%s","statusCheckRollup":%s,"reviews":%s}]\n' "$head_sha" "$draft" "$review" "$merge_state" "$check_json" "$reviews_json"
  fi
}

review_threads_payload() {
  case "$scenario" in
    current-thread)
      cat <<JSON
{"data":{"repository":{"pullRequest":{"reviewThreads":{"nodes":[{"id":"PRRT_current","isResolved":false,"isOutdated":false,"path":"src/App.ts","line":10,"originalLine":10,"comments":{"nodes":[{"url":"https://github.com/example/repo/pull/42#discussion_r1"}]}}],"pageInfo":{"hasNextPage":false}}}}}}
JSON
      ;;
    outdated-thread)
      cat <<JSON
{"data":{"repository":{"pullRequest":{"reviewThreads":{"nodes":[{"id":"PRRT_old","isResolved":false,"isOutdated":true,"path":"src/App.ts","line":null,"originalLine":12,"comments":{"nodes":[{"url":"https://github.com/example/repo/pull/42#discussion_r2"}]}}],"pageInfo":{"hasNextPage":false}}}}}}
JSON
      ;;
    paginated-threads)
      cat <<JSON
{"data":{"repository":{"pullRequest":{"reviewThreads":{"nodes":[],"pageInfo":{"hasNextPage":true}}}}}}
JSON
      ;;
    malformed-threads)
      cat <<JSON
{"data":{"repository":{"pullRequest":{"reviewThreads":{"nodes":[{"id":"PRRT_bad"}],"pageInfo":{"hasNextPage":false}}}}}}
JSON
      ;;
    missing-thread-nodes)
      printf '{"data":{"repository":{"pullRequest":{}}}}\n'
      ;;
    graphql-bad-json)
      printf '{bad-json\n'
      ;;
    *)
      cat <<JSON
{"data":{"repository":{"pullRequest":{"reviewThreads":{"nodes":[{"id":"PRRT_done","isResolved":true,"isOutdated":false,"path":"src/App.ts","line":1,"originalLine":1,"comments":{"nodes":[{"url":"https://github.com/example/repo/pull/42#discussion_r0"}]}}],"pageInfo":{"hasNextPage":false}}}}}}
JSON
      ;;
  esac
}

if [[ "${1:-}" == "pr" && "${2:-}" == "list" ]]; then
  case "$scenario" in
    pr-query-fail) echo "GitHub unavailable" >&2; exit 1 ;;
    pr-bad-json) echo "{bad-json"; exit 0 ;;
    no-pr) echo "[]"; exit 0 ;;
    multiple-open)
      checks="$(successful_checks)"
      printf '[{"number":42,"url":"https://github.com/example/repo/pull/42","state":"OPEN","mergedAt":null,"headRefOid":"%s","isDraft":false,"reviewDecision":"APPROVED","mergeStateStatus":"CLEAN","statusCheckRollup":%s},{"number":43,"url":"https://github.com/example/repo/pull/43","state":"OPEN","mergedAt":null,"headRefOid":"%s","isDraft":false,"reviewDecision":"APPROVED","mergeStateStatus":"CLEAN","statusCheckRollup":%s}]\n' "$sha_a" "$checks" "$sha_a" "$checks"
      ;;
    draft) pr_payload OPEN true APPROVED CLEAN "$sha_a" success ;;
    review-required) pr_payload OPEN false REVIEW_REQUIRED CLEAN "$sha_a" success ;;
    review-required-current-approval) pr_payload OPEN false REVIEW_REQUIRED CLEAN "$sha_a" success ;;
    review-required-stale-approval) pr_payload OPEN false REVIEW_REQUIRED CLEAN "$sha_a" success ;;
    review-details-unavailable)
      checks="$(successful_checks)"
      printf '[{"number":42,"url":"https://github.com/example/repo/pull/42","state":"OPEN","mergedAt":null,"headRefOid":"%s","isDraft":false,"reviewDecision":"REVIEW_REQUIRED","mergeStateStatus":"CLEAN","statusCheckRollup":%s}]\n' "$sha_a" "$checks"
      ;;
    review-details-malformed) pr_payload OPEN false REVIEW_REQUIRED CLEAN "$sha_a" success ;;
    changes-requested) pr_payload OPEN false CHANGES_REQUESTED CLEAN "$sha_a" success ;;
    blocked) pr_payload OPEN false APPROVED BLOCKED "$sha_a" success ;;
    pending-check) pr_payload OPEN false APPROVED CLEAN "$sha_a" pending ;;
    missing-check) pr_payload OPEN false APPROVED CLEAN "$sha_a" missing ;;
    duplicate-check) pr_payload OPEN false APPROVED CLEAN "$sha_a" duplicate ;;
    malformed-checks) pr_payload OPEN false APPROVED CLEAN "$sha_a" malformed ;;
    closed) pr_payload CLOSED false APPROVED CLEAN "$sha_a" success ;;
    merged) pr_payload MERGED false APPROVED CLEAN "$sha_a" success ;;
    merged-check-fail) pr_payload MERGED false APPROVED CLEAN "$sha_a" pending ;;
    branch-drift) pr_payload OPEN false APPROVED CLEAN "$sha_a" success ;;
    merged-branch-drift) pr_payload MERGED false APPROVED CLEAN "$sha_a" success ;;
    *) pr_payload OPEN false APPROVED CLEAN "$sha_a" success ;;
  esac
  exit 0
fi

if [[ "${1:-}" == "api" && "${2:-}" == "repos/example/repo/git/matching-refs/heads/codex/release" ]]; then
  case "$scenario" in
    branch-ref-fail) echo "branch API unavailable" >&2; exit 1 ;;
    branch-ref-bad-json) echo "{bad-json"; exit 0 ;;
    branch-ref-missing) echo "[]"; exit 0 ;;
    branch-ref-duplicate) printf '[{"ref":"refs/heads/codex/release","object":{"sha":"%s"}},{"ref":"refs/heads/codex/release","object":{"sha":"%s"}}]\n' "$sha_a" "$sha_a" ;;
    branch-ref-bad-sha) echo '[{"ref":"refs/heads/codex/release","object":{"sha":"notasha"}}]' ;;
    branch-drift|merged-branch-drift) printf '[{"ref":"refs/heads/codex/release","object":{"sha":"%s"}}]\n' "$sha_b" ;;
    *) printf '[{"ref":"refs/heads/codex/release","object":{"sha":"%s"}}]\n' "$sha_a" ;;
  esac
  exit 0
fi

if [[ "${1:-}" == "api" && "${2:-}" == "graphql" ]]; then
  case "$scenario" in
    graphql-fail) echo "graphql unavailable" >&2; exit 1 ;;
    *) review_threads_payload ;;
  esac
  exit 0
fi

if [[ "${1:-}" == "pr" && "${2:-}" == "merge" ]]; then
  shift 2
  printf '%s\n' "$*" >> "${FAKE_GH_MERGE_LOG:?}"
  if [[ "$*" == *"--admin"* ]]; then
    echo "admin bypass must not be used" >&2
    exit 1
  fi
  if [[ "$*" != *"--match-head-commit $sha_a"* ]]; then
    echo "missing head pin" >&2
    exit 1
  fi
  if [[ "${FAKE_GH_MERGE_SCENARIO:-ok}" == "fail" ]]; then
    echo "merge failed" >&2
    exit 1
  fi
  echo "merged"
  exit 0
fi

echo "unexpected gh invocation: $*" >&2
exit 1
SH
chmod +x "$tmp_dir/gh"

write_config
expect_success "ready dry-run" "Dry run: 1 release PR(s) are ready to merge" run_merger --dry-run
ready_output="$(run_merger --dry-run 2>&1)"
[[ "$ready_output" == *"Would merge example/repo#42"* ]] || fail "ready dry-run did not print merge candidate"

write_config
expect_failure "apply confirmation gate" "--apply requires RELEASE_PR_MERGE_CONFIRM" run_merger --apply

write_config
FAKE_GH_MERGE_LOG="$tmp_dir/merge.log" RELEASE_PR_MERGE_CONFIRM=merge-release-prs expect_success "apply success" "Finished merging release PRs" run_merger --apply
grep -q -- "--match-head-commit $sha_a" "$tmp_dir/merge.log" || fail "apply success did not pin expected head commit"
if grep -q -- "--admin" "$tmp_dir/merge.log"; then
  cat "$tmp_dir/merge.log" >&2
  fail "apply success used admin bypass"
fi

write_config
FAKE_GH_MERGE_LOG="$tmp_dir/merge-fail.log" FAKE_GH_MERGE_SCENARIO=fail RELEASE_PR_MERGE_CONFIRM=merge-release-prs expect_failure "merge failure" "GitHub failed to merge" run_merger --apply

write_config
FAKE_GH_SCENARIO=merged expect_success "already merged fixture" "No open release PRs are ready to merge. Already merged: 1" run_merger --dry-run

for fixture in \
  "pr-query-fail:unable to query PR state" \
  "pr-bad-json:gh returned invalid JSON" \
  "no-pr:no pull request found" \
  "multiple-open:multiple open pull requests found" \
  "draft:isDraft=true" \
  "review-required:reviewDecision=REVIEW_REQUIRED" \
  "review-required-current-approval:currentApprovalNotEligible=true" \
  "review-required-stale-approval:freshApprovalRequired=true" \
  "review-details-unavailable:reviewDetails=unavailable" \
  "review-details-malformed:reviewDetails=malformed" \
  "changes-requested:reviewDecision=CHANGES_REQUESTED" \
  "blocked:mergeStateStatus=BLOCKED" \
  "pending-check:incompleteRequiredChecks=verify:IN_PROGRESS/PENDING" \
  "missing-check:missingRequiredChecks=verify" \
  "duplicate-check:duplicateRequiredChecks=verify" \
  "malformed-checks:malformedChecks=statusCheckRollup is not an array" \
  "current-thread:currentUnresolvedReviewThreads=1" \
  "outdated-thread:outdatedUnresolvedReviewThreads=1" \
  "paginated-threads:unresolvedReviewThreads=paginated" \
  "malformed-threads:malformedReviewThreads=1" \
  "missing-thread-nodes:reviewThreadsQuery=malformed" \
  "graphql-fail:reviewThreadsQuery=failed" \
  "graphql-bad-json:reviewThreadsQuery=malformed" \
  "branch-ref-fail:unable to query current PR head branch ref" \
  "branch-ref-bad-json:gh returned invalid branch-ref JSON" \
  "branch-ref-missing:current branch ref refs/heads/codex/release is missing" \
  "branch-ref-duplicate:duplicate current branch refs" \
  "branch-ref-bad-sha:current branch ref refs/heads/codex/release is missing a valid object sha" \
  "branch-drift:head branch moved after PR query" \
  "closed:closed without merge" \
  "merged-check-fail:already merged but required checks are not release-ready" \
  "merged-branch-drift:already merged but branch 'codex/release' has new commits after merge"; do
  write_config
  scenario="${fixture%%:*}"
  expected="${fixture#*:}"
  FAKE_GH_SCENARIO="$scenario" expect_failure "$scenario fixture" "$expected" run_merger --dry-run
done

write_config
printf '%s\n' "example/repo	codex/release	develop	merged	validate,verify" >> "$config"
expect_failure "duplicate config row" "duplicate release PR requirement row" run_merger --dry-run

printf '%s\n' "example/repo	codex/../release	develop	merged	validate,verify" > "$config"
expect_failure "invalid head branch ref config" "invalid head branch ref" run_merger --dry-run

printf '%s\n' "example/repo	codex/release	develop.lock	merged	validate,verify" > "$config"
expect_failure "invalid base branch ref config" "invalid base branch ref" run_merger --dry-run

write_config
perl -0pi -e 's/merged/closed/' "$config"
expect_failure "unsupported config state" "unsupported required_state" run_merger --dry-run

write_config
expect_failure "unsupported merge method" "Unsupported merge method" run_merger --dry-run --merge-method octopus

echo "[release-pr-merge-test] all tests passed"
