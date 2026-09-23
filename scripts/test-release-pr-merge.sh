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
# reviewed_pr_pin	repo	head	base	reviewed_pr_number	reviewed_head_sha
# required_check_provenance_pin	repo	head	base	check_name	kind	actor_id	actor_slug	authority_id	authority_value
# repo	head	base	required_state	required_checks
# reviewed_pr_pin	example/repo	codex/release	develop	42	aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
# required_check_provenance_pin	example/repo	codex/release	develop	validate	github-actions	15368	github-actions	9001	.github/workflows/branch-flow.yml
# required_check_provenance_pin	example/repo	codex/release	develop	verify	github-actions	15368	github-actions	9002	.github/workflows/ci.yml
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

expect_failure_without_merge() {
  local name="$1"
  local scenario="$2"
  local expected="$3"
  local merge_log="$tmp_dir/${scenario}-must-not-merge.log"
  local output
  : > "$merge_log"
  set +e
  output="$(
    FAKE_GH_SCENARIO="$scenario" \
      FAKE_GH_MERGE_LOG="$merge_log" \
      RELEASE_PR_MERGE_CONFIRM=merge-release-prs \
      run_merger --apply 2>&1
  )"
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
  if [[ -s "$merge_log" ]]; then
    echo "$output" >&2
    fail "$name reached the irreversible gh pr merge boundary"
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

check_runs_payload() {
  local validate_app_id=15368
  local validate_app_slug="github-actions"
  if [[ "$scenario" == "singleton-wrong-app-authority" ]]; then
    validate_app_id=99153
    validate_app_slug="unreviewed-check-app"
  fi
  cat <<JSON
{"total_count":2,"check_runs":[{"id":2001,"name":"validate","head_sha":"$sha_a","status":"completed","conclusion":"success","app":{"id":$validate_app_id,"slug":"$validate_app_slug"},"check_suite":{"id":1001},"details_url":"https://github.com/example/repo/actions/runs/5001/job/6001"},{"id":2002,"name":"verify","head_sha":"$sha_a","status":"completed","conclusion":"success","app":{"id":15368,"slug":"github-actions"},"check_suite":{"id":1002},"details_url":"https://github.com/example/repo/actions/runs/5002/job/6002"}]}
JSON
}

commit_status_payload() {
  cat <<JSON
{"state":"success","sha":"$sha_a","total_count":0,"statuses":[]}
JSON
}

check_suite_payload() {
  local suite_id="$1"
  cat <<JSON
{"id":$suite_id,"head_sha":"$sha_a","app":{"id":15368,"slug":"github-actions"}}
JSON
}

actions_runs_payload() {
  local suite_id="$1"
  local workflow_id workflow_path run_id
  case "$suite_id" in
    1001)
      workflow_id=9001
      workflow_path=".github/workflows/branch-flow.yml"
      run_id=5001
      ;;
    1002)
      workflow_id=9002
      workflow_path=".github/workflows/ci.yml"
      run_id=5002
      ;;
    *)
      echo "unexpected check suite id: $suite_id" >&2
      exit 1
      ;;
  esac
  if [[ "$scenario" == "singleton-wrong-workflow-authority" && "$suite_id" == "1001" ]]; then
    workflow_id=99001
  fi
  cat <<JSON
{"total_count":1,"workflow_runs":[{"id":$run_id,"check_suite_id":$suite_id,"head_sha":"$sha_a","workflow_id":$workflow_id,"path":"$workflow_path","repository":{"full_name":"example/repo"},"head_repository":{"full_name":"example/repo"},"event":"pull_request","head_branch":"codex/release"}]}
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
      printf '[{"state":"APPROVED","submittedAt":"2026-06-28T00:02:00Z","commit":{"oid":"%s"}}]' "$sha_a"
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
    reviewed-identity-mismatch)
      checks="$(successful_checks)"
      printf '[{"number":43,"url":"https://github.com/example/repo/pull/43","state":"OPEN","mergedAt":null,"headRefOid":"%s","isDraft":false,"reviewDecision":"APPROVED","mergeStateStatus":"CLEAN","statusCheckRollup":%s,"reviews":[]}]\n' "$sha_a" "$checks"
      ;;
    malformed-is-draft)
      checks="$(successful_checks)"
      printf '[{"number":42,"url":"https://github.com/example/repo/pull/42","state":"OPEN","mergedAt":null,"headRefOid":"%s","reviewDecision":"APPROVED","mergeStateStatus":"CLEAN","statusCheckRollup":%s,"reviews":[]}]\n' "$sha_a" "$checks"
      ;;
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

if [[ "${1:-}" == "api" && "${2:-}" == "repos/example/repo/commits/$sha_a/check-runs?filter=latest&per_page=100" ]]; then
  check_runs_payload
  exit 0
fi

if [[ "${1:-}" == "api" && "${2:-}" == "repos/example/repo/commits/$sha_a/status?per_page=100" ]]; then
  commit_status_payload
  exit 0
fi

if [[ "${1:-}" == "api" && "${2:-}" == "repos/example/repo/check-suites/1001" ]]; then
  check_suite_payload 1001
  exit 0
fi

if [[ "${1:-}" == "api" && "${2:-}" == "repos/example/repo/check-suites/1002" ]]; then
  check_suite_payload 1002
  exit 0
fi

if [[ "${1:-}" == "api" && "${2:-}" == "repos/example/repo/actions/runs?check_suite_id=1001&per_page=100" ]]; then
  actions_runs_payload 1001
  exit 0
fi

if [[ "${1:-}" == "api" && "${2:-}" == "repos/example/repo/actions/runs?check_suite_id=1002&per_page=100" ]]; then
  actions_runs_payload 1002
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
expect_failure_without_merge \
  "singleton wrong GitHub app authority fixture" \
  singleton-wrong-app-authority \
  "check-run-app-mismatch"

write_config
expect_failure_without_merge \
  "singleton wrong GitHub Actions workflow authority fixture" \
  singleton-wrong-workflow-authority \
  "actions-workflow-id-mismatch"

write_config
expect_failure_without_merge \
  "reviewed candidate identity mismatch fixture" \
  reviewed-identity-mismatch \
  "reviewedPrNumberPinMismatch expected=42 available=43"

write_config
expect_failure_without_merge \
  "malformed isDraft central preflight fixture" \
  malformed-is-draft \
  "isDraft=UNKNOWN"

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
