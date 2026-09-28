#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
RESOLVER="$SCRIPT_DIR/resolve-release-pr-review-threads.sh"

fail() {
  echo "[release-pr-thread-resolver-test][error] $*" >&2
  exit 1
}

tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

write_log() {
  local name="$1"
  shift
  printf '%s\n' "$@" > "$tmp_dir/$name.log"
}

run_resolver() {
  local mode="$1"
  local log_file="$2"
  shift 2
  GH_BIN="${GH_BIN:-$tmp_dir/gh}" "$RESOLVER" "$mode" --audit-log "$log_file" "$@"
}

expect_success() {
  local name="$1"
  local mode="$2"
  local log_file="$3"
  local expected="$4"
  local output
  if ! output="$(run_resolver "$mode" "$log_file" 2>&1)"; then
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
  local mode="$2"
  local log_file="$3"
  local expected="$4"
  shift 4
  local output
  set +e
  output="$("$@" run_resolver "$mode" "$log_file" 2>&1)"
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

write_log eligible \
  "[release-pr-readiness][warn] soramitsu/fearless-Android#1257 is open and is not release-ready: https://github.com/soramitsu/fearless-Android/pull/1257 isDraft=false reviewDecision=REVIEW_REQUIRED mergeStateStatus=BLOCKED unresolvedReviewThreads=2 currentUnresolvedReviewThreads=0 outdatedUnresolvedReviewThreads=2 reviewConversationResolutionRequired=true outdatedReviewThreadsStillBlockMerge=true unresolvedReviewThreadRefs=outdated:Chain.kt:80:https://github.com/soramitsu/fearless-Android/pull/1257#discussion_r1;outdated:SubstrateXcmTransferEngine.kt:169:https://github.com/soramitsu/fearless-Android/pull/1257#discussion_r2 unresolvedReviewThreadIds=PRRT_android_one,PRRT_android_two" \
  "  - soramitsu/fearless-Android#1257 is open and is not release-ready: https://github.com/soramitsu/fearless-Android/pull/1257 isDraft=false reviewDecision=REVIEW_REQUIRED mergeStateStatus=BLOCKED unresolvedReviewThreads=2 currentUnresolvedReviewThreads=0 outdatedUnresolvedReviewThreads=2 reviewConversationResolutionRequired=true outdatedReviewThreadsStillBlockMerge=true unresolvedReviewThreadRefs=outdated:Chain.kt:80:https://github.com/soramitsu/fearless-Android/pull/1257#discussion_r1;outdated:SubstrateXcmTransferEngine.kt:169:https://github.com/soramitsu/fearless-Android/pull/1257#discussion_r2 unresolvedReviewThreadIds=PRRT_android_one,PRRT_android_two" \
  "[release-pr-readiness][warn] soramitsu/fearless-wallet-web#1061 is open and is not release-ready: https://github.com/soramitsu/fearless-wallet-web/pull/1061 isDraft=false reviewDecision=REVIEW_REQUIRED mergeStateStatus=BLOCKED unresolvedReviewThreads=1 currentUnresolvedReviewThreads=0 outdatedUnresolvedReviewThreads=1 reviewConversationResolutionRequired=true outdatedReviewThreadsStillBlockMerge=true unresolvedReviewThreadRefs=outdated:scripts/audit-bitcoin-broadcast-evidence.sh:284:https://github.com/soramitsu/fearless-wallet-web/pull/1061#discussion_r3 unresolvedReviewThreadIds=PRRT_web_one"

write_log current \
  "[release-pr-readiness][warn] soramitsu/fearless-iOS#1300 is open and is not release-ready: https://github.com/soramitsu/fearless-iOS/pull/1300 isDraft=false reviewDecision=REVIEW_REQUIRED mergeStateStatus=BLOCKED unresolvedReviewThreads=1 currentUnresolvedReviewThreads=1 outdatedUnresolvedReviewThreads=0 reviewConversationResolutionRequired=true unresolvedReviewThreadIds=PRRT_ios_current"

write_log mixed \
  "[release-pr-readiness][warn] soramitsu/fearless-iOS#1300 is open and is not release-ready: https://github.com/soramitsu/fearless-iOS/pull/1300 isDraft=false reviewDecision=REVIEW_REQUIRED mergeStateStatus=BLOCKED unresolvedReviewThreads=2 currentUnresolvedReviewThreads=0 outdatedUnresolvedReviewThreads=1 reviewConversationResolutionRequired=true unresolvedReviewThreadIds=PRRT_ios_one,PRRT_ios_two"

write_log missing_id \
  "[release-pr-readiness][warn] soramitsu/fearless-wallet-web#1061 is open and is not release-ready: https://github.com/soramitsu/fearless-wallet-web/pull/1061 isDraft=false reviewDecision=REVIEW_REQUIRED mergeStateStatus=BLOCKED unresolvedReviewThreads=1 currentUnresolvedReviewThreads=0 outdatedUnresolvedReviewThreads=1 reviewConversationResolutionRequired=true"

write_log paginated \
  "[release-pr-readiness][warn] soramitsu/fearless-Android#1257 is open and is not release-ready: https://github.com/soramitsu/fearless-Android/pull/1257 isDraft=false reviewDecision=REVIEW_REQUIRED mergeStateStatus=BLOCKED unresolvedReviewThreads=101+ currentUnresolvedReviewThreads=0 outdatedUnresolvedReviewThreads=101 reviewConversationResolutionRequired=true unresolvedReviewThreadIds=PRRT_android_one,more"

write_log count_mismatch \
  "[release-pr-readiness][warn] soramitsu/fearless-wallet-web#1061 is open and is not release-ready: https://github.com/soramitsu/fearless-wallet-web/pull/1061 isDraft=false reviewDecision=REVIEW_REQUIRED mergeStateStatus=BLOCKED unresolvedReviewThreads=2 currentUnresolvedReviewThreads=0 outdatedUnresolvedReviewThreads=2 reviewConversationResolutionRequired=true unresolvedReviewThreadIds=PRRT_web_one"

write_log malformed_id \
  "[release-pr-readiness][warn] soramitsu/fearless-wallet-web#1061 is open and is not release-ready: https://github.com/soramitsu/fearless-wallet-web/pull/1061 isDraft=false reviewDecision=REVIEW_REQUIRED mergeStateStatus=BLOCKED unresolvedReviewThreads=1 currentUnresolvedReviewThreads=0 outdatedUnresolvedReviewThreads=1 reviewConversationResolutionRequired=true unresolvedReviewThreadIds=bad-thread-id"

write_log query_failed \
  "[release-pr-readiness][warn] soramitsu/fearless-iOS#1300 is open and is not release-ready: https://github.com/soramitsu/fearless-iOS/pull/1300 isDraft=false reviewDecision=REVIEW_REQUIRED mergeStateStatus=BLOCKED reviewThreadsQuery=failed:GitHub unavailable"

write_log none \
  "[release-pr-readiness] Release PR readiness passed for 14 requirement(s)."

cat > "$tmp_dir/gh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail

if [[ "${1:-}" != "api" || "${2:-}" != "graphql" ]]; then
  echo "unexpected gh invocation: $*" >&2
  exit 1
fi
shift 2

thread_id=""
while (($#)); do
  case "$1" in
    -F)
      case "$2" in
        threadId=*) thread_id="${2#threadId=}" ;;
      esac
      shift 2
      ;;
    -f)
      shift 2
      ;;
    *)
      shift
      ;;
  esac
done

if [[ -z "$thread_id" ]]; then
  echo "missing threadId" >&2
  exit 1
fi

printf '%s\n' "$thread_id" >> "${FAKE_GH_LOG:?}"

case "${FAKE_GH_SCENARIO:-ok}" in
  fail)
    echo "GitHub mutation failed" >&2
    exit 1
    ;;
  bad-json)
    echo "{not-json"
    ;;
  unresolved)
    printf '{"data":{"resolveReviewThread":{"thread":{"id":"%s","isResolved":false}}}}\n' "$thread_id"
    ;;
  wrong-id)
    printf '{"data":{"resolveReviewThread":{"thread":{"id":"PRRT_wrong","isResolved":true}}}}\n'
    ;;
  *)
    printf '{"data":{"resolveReviewThread":{"thread":{"id":"%s","isResolved":true}}}}\n' "$thread_id"
    ;;
esac
SH
chmod +x "$tmp_dir/gh"

eligible_log="$tmp_dir/eligible.log"

expect_success "dry-run duplicate line dedupe" --dry-run "$eligible_log" "Dry run: 3 outdated review thread(s)"

dry_run_output="$(run_resolver --dry-run "$eligible_log" 2>&1)"
if [[ "$(grep -o 'PRRT_android_one' <<< "$dry_run_output" | wc -l | tr -d '[:space:]')" != "1" ]]; then
  echo "$dry_run_output" >&2
  fail "dry-run duplicate line dedupe printed duplicate thread ID"
fi

expect_success "empty log fixture" --dry-run "$tmp_dir/none.log" "No eligible outdated review-thread IDs found"

expect_failure "current thread refusal" --dry-run "$tmp_dir/current.log" "refusing to resolve active review feedback"
expect_failure "mixed thread refusal" --dry-run "$tmp_dir/mixed.log" "refusing mixed thread state"
expect_failure "missing thread id refusal" --dry-run "$tmp_dir/missing_id.log" "unresolved review-thread IDs are missing"
expect_failure "pagination refusal" --dry-run "$tmp_dir/paginated.log" "unresolved review-thread output is paginated"
expect_failure "thread id count mismatch refusal" --dry-run "$tmp_dir/count_mismatch.log" "unresolvedReviewThreadIds has 1 ID"
expect_failure "malformed thread id refusal" --dry-run "$tmp_dir/malformed_id.log" "malformed review-thread ID"
expect_failure "review-thread query failure refusal" --dry-run "$tmp_dir/query_failed.log" "review-thread query did not return complete thread data"

expect_failure "apply confirmation gate" --apply "$eligible_log" "--apply requires RELEASE_PR_THREAD_RESOLUTION_CONFIRM"

FAKE_GH_LOG="$tmp_dir/gh.log" RELEASE_PR_THREAD_RESOLUTION_CONFIRM=resolve-outdated-review-threads expect_success "apply success" --apply "$eligible_log" "Finished resolving outdated review threads"
if [[ "$(wc -l < "$tmp_dir/gh.log" | tr -d '[:space:]')" != "3" ]]; then
  cat "$tmp_dir/gh.log" >&2
  fail "apply success did not resolve exactly three deduped threads"
fi

FAKE_GH_LOG="$tmp_dir/gh-fail.log" FAKE_GH_SCENARIO=fail RELEASE_PR_THREAD_RESOLUTION_CONFIRM=resolve-outdated-review-threads expect_failure "mutation failure" --apply "$eligible_log" "GitHub failed to resolve"
FAKE_GH_LOG="$tmp_dir/gh-bad-json.log" FAKE_GH_SCENARIO=bad-json RELEASE_PR_THREAD_RESOLUTION_CONFIRM=resolve-outdated-review-threads expect_failure "mutation bad JSON" --apply "$eligible_log" "GitHub returned invalid JSON"
FAKE_GH_LOG="$tmp_dir/gh-unresolved.log" FAKE_GH_SCENARIO=unresolved RELEASE_PR_THREAD_RESOLUTION_CONFIRM=resolve-outdated-review-threads expect_failure "mutation unresolved response" --apply "$eligible_log" "GitHub did not confirm"
FAKE_GH_LOG="$tmp_dir/gh-wrong-id.log" FAKE_GH_SCENARIO=wrong-id RELEASE_PR_THREAD_RESOLUTION_CONFIRM=resolve-outdated-review-threads expect_failure "mutation wrong id response" --apply "$eligible_log" "GitHub did not confirm"

echo "[release-pr-thread-resolver-test] all tests passed"
