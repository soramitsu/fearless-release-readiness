#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
AUDIT_SCRIPT="$SCRIPT_DIR/audit-github-governance.sh"

fail() {
  echo "[github-governance-test][error] $*" >&2
  exit 1
}

tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

fake_gh="$tmp_dir/gh"

cat > "$fake_gh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail

scenario="${FAKE_GH_SCENARIO:-good}"
state_file="${TMPDIR:-/tmp}/fake-gh-delete-staging-count"
ruleset_state_file="${TMPDIR:-/tmp}/fake-gh-ruleset-${scenario}"
classic_state_file="${TMPDIR:-/tmp}/fake-gh-classic-${scenario}"

if [[ "${1:-}" != "api" ]]; then
  echo "expected gh api" >&2
  exit 2
fi
shift

method="GET"
path=""
jq_expr=""
input_body=""
saw_accept_header=false
saw_api_version=false

while (($#)); do
  case "$1" in
    --method)
      method="$2"
      shift 2
      ;;
    --input)
      input_body="$(cat "$2")"
      shift 2
      ;;
    --jq)
      jq_expr="$2"
      shift 2
      ;;
    -H|--header)
      case "$2" in
        "Accept: application/vnd.github+json")
          saw_accept_header=true
          ;;
        "X-GitHub-Api-Version: 2026-03-10")
          saw_api_version=true
          ;;
      esac
      shift 2
      ;;
    repos/*)
      path="$1"
      shift
      ;;
    *)
      shift
      ;;
  esac
done

[[ "$saw_accept_header" == true ]] || {
  echo "missing pinned GitHub JSON Accept header" >&2
  exit 2
}
[[ "$saw_api_version" == true ]] || {
  echo "missing pinned GitHub API version" >&2
  exit 2
}

repo_from_path() {
  local p="$1"
  p="${p#repos/}"
  if [[ "$p" == */rules/branches/* ]]; then
    p="${p%%/rules/branches/*}"
  elif [[ "$p" == */rulesets/* ]]; then
    p="${p%%/rulesets/*}"
  elif [[ "$p" == */branches/* ]]; then
    p="${p%%/branches/*}"
  fi
  if [[ "$p" == */git/refs/* ]]; then
    p="${p%%/git/refs/*}"
  fi
  echo "$p"
}

branch_from_path() {
  local p="$1"
  p="${p#*/branches/}"
  p="${p%%/*}"
  echo "$p"
}

emit_jq() {
  local default_branch="$1"
  local protected="${2:-}"
  local name="${3:-}"
  local private="${4:-false}"
  case "$jq_expr" in
    .default_branch) echo "$default_branch" ;;
    .protected) echo "$protected" ;;
    .name) echo "$name" ;;
    .private) echo "$private" ;;
    *) echo "{}" ;;
  esac
}

default_branch_for_repo() {
  case "$1" in
    soramitsu/fearless-release-readiness)
      echo "main"
      ;;
    tonswap-org/ton-indexer|solswap-io/solswap-indexer|sora-xor/polkaswap-indexer)
      echo "master"
      ;;
    *)
      echo "develop"
      ;;
  esac
}

repo="$(repo_from_path "$path")"

if [[ "$path" == */rulesets/42 && "$method" == "GET" ]]; then
  case "$scenario" in
    ruleset-bypass)
      printf '%s\n' '{"id":42,"enforcement":"active","bypass_actors":[{"actor_id":5,"actor_type":"User","bypass_mode":"always"}],"current_user_can_bypass":"always"}'
      ;;
    ruleset-apply-success)
      if [[ -f "$ruleset_state_file" ]]; then
        printf '%s\n' '{"id":42,"name":"polkaswap-release-policy","target":"branch","enforcement":"active","bypass_actors":[],"current_user_can_bypass":"never","conditions":{"ref_name":{"include":["refs/heads/develop","refs/heads/master"],"exclude":[]}},"rules":[{"type":"required_linear_history"}]}'
      else
        printf '%s\n' '{"id":42,"name":"polkaswap-release-policy","target":"branch","enforcement":"active","bypass_actors":[{"actor_id":5,"actor_type":"User","bypass_mode":"always"}],"current_user_can_bypass":"always","conditions":{"ref_name":{"include":["refs/heads/develop","refs/heads/master"],"exclude":[]}},"rules":[{"type":"deletion"},{"type":"non_fast_forward"},{"type":"required_linear_history"}]}'
      fi
      ;;
    *)
      printf '%s\n' '{"id":42,"enforcement":"active","bypass_actors":[],"current_user_can_bypass":"never"}'
      ;;
  esac
  exit 0
fi

if [[ "$path" == */rules/branches/* ]]; then
  if [[ "$repo" != "sora-xor/polkaswap-indexer" ]]; then
    printf '[]\n'
    exit 0
  fi
  status_contexts='[{"context":"branch-flow"},{"context":"validate"},{"context":"verify"}]'
  if [[ "$scenario" == "ruleset-missing-branch-flow" && "$(branch_from_path "$path")" == "master" ]]; then
    status_contexts='[{"context":"validate"},{"context":"verify"}]'
  fi
  if [[ "$scenario" == "ruleset-apply-success" && ! -f "$ruleset_state_file" ]]; then
    printf '[%s,%s,%s]\n' \
      '{"type":"deletion","ruleset_id":42}' \
      '{"type":"non_fast_forward","ruleset_id":42}' \
      '{"type":"required_linear_history","ruleset_id":42}'
    exit 0
  fi
  if [[ "$scenario" == "ruleset-apply-ambiguous" ]]; then
    printf '[%s,%s]\n' \
      '{"type":"deletion","ruleset_id":42}' \
      '{"type":"non_fast_forward","ruleset_id":43}'
    exit 0
  fi
  printf '[%s,%s,%s,%s]\n' \
    '{"type":"deletion","ruleset_id":42}' \
    '{"type":"non_fast_forward","ruleset_id":42}' \
    '{"type":"pull_request","ruleset_id":42,"parameters":{"required_approving_review_count":1,"dismiss_stale_reviews_on_push":true,"require_code_owner_review":true,"require_last_push_approval":true,"required_review_thread_resolution":true}}' \
    "{\"type\":\"required_status_checks\",\"ruleset_id\":42,\"parameters\":{\"strict_required_status_checks_policy\":true,\"required_status_checks\":$status_contexts}}"
  exit 0
fi

if [[ "$method" == "DELETE" ]]; then
  case "$scenario" in
    delete-staging-success)
      exit 0
      ;;
    delete-staging-protected-success)
      if [[ "$path" == */branches/staging/protection ]]; then
        exit 0
      fi
      count=0
      if [[ -f "$state_file" ]]; then
        count="$(cat "$state_file")"
      fi
      count=$((count + 1))
      printf '%s' "$count" > "$state_file"
      if [[ "$count" -eq 1 ]]; then
        echo 'gh: Cannot delete this branch (HTTP 422)' >&2
        exit 1
      fi
      exit 0
      ;;
    delete-staging-403)
      echo '{"message":"Cannot delete protected branch","status":"403"}' >&2
      exit 1
      ;;
    *)
      echo "unexpected DELETE in $scenario" >&2
      exit 1
      ;;
  esac
fi

if [[ "$method" == "PUT" ]]; then
  if [[ "$path" == */rulesets/42 && "$scenario" == "ruleset-apply-success" ]]; then
    if ! jq -e '
      .name == "polkaswap-release-policy" and
      .target == "branch" and
      .enforcement == "active" and
      .bypass_actors == [] and
      .conditions.ref_name.include == [
        "refs/heads/develop",
        "refs/heads/master"
      ] and
      any(.rules[]; .type == "required_linear_history") and
      any(.rules[];
        .type == "deletion" and
        (has("parameters") | not)
      ) and
      any(.rules[];
        .type == "non_fast_forward" and
        (has("parameters") | not)
      ) and
      any(.rules[];
        .type == "pull_request" and
        .parameters.dismiss_stale_reviews_on_push == true and
        .parameters.require_code_owner_review == true and
        .parameters.require_last_push_approval == true and
        .parameters.required_approving_review_count == 1 and
        .parameters.required_review_thread_resolution == true
      ) and
      any(.rules[];
        .type == "required_status_checks" and
        .parameters.strict_required_status_checks_policy == true and
        (.parameters.required_status_checks | map(.context)) ==
          ["branch-flow", "validate", "verify"]
      )
    ' <<<"$input_body" >/dev/null; then
      echo "ruleset update payload does not preserve and harden policy" >&2
      exit 1
    fi
    : > "$ruleset_state_file"
    exit 0
  fi
  if [[ "$path" == */branches/develop/protection && "$scenario" == "apply-classic-policy-success" ]]; then
    if ! jq -e '
      .required_status_checks.strict == true and
      .required_status_checks.checks == [
        {"context": "validate", "app_id": 15368},
        {"context": "verify", "app_id": 15368}
      ] and
      .enforce_admins == true and
      .required_pull_request_reviews.dismiss_stale_reviews == true and
      .required_pull_request_reviews.require_last_push_approval == true and
      .required_pull_request_reviews.require_code_owner_reviews == true and
      .required_pull_request_reviews.required_approving_review_count == 1 and
      .required_pull_request_reviews.bypass_pull_request_allowances == {
        users: [],
        teams: [],
        apps: []
      } and
      .required_linear_history == true and
      .block_creations == true and
      .allow_force_pushes == false and
      .allow_deletions == false and
      .required_conversation_resolution == true
    ' <<<"$input_body" >/dev/null; then
      echo "classic protection update payload is not strict and no-bypass" >&2
      exit 1
    fi
    : > "$classic_state_file"
    exit 0
  fi
  if [[ "$path" == */branches/master/protection && "$scenario" == "apply-status-404-fallback" ]]; then
    if ! jq -e '
      .required_status_checks.strict == true and
      .required_status_checks.checks == [
        {"context": "validate", "app_id": 15368},
        {"context": "build-and-test"}
      ] and
      .required_linear_history == true and
      .block_creations == true and
      .required_conversation_resolution == true and
      .allow_force_pushes == false and
      .allow_deletions == false
    ' <<<"$input_body" >/dev/null; then
      echo "status-check fallback did not preserve and complete the classic protection policy" >&2
      exit 1
    fi
    exit 0
  fi
  case "$scenario" in
    apply-success)
      exit 0
      ;;
    apply-403)
      echo '{"message":"Upgrade to GitHub Pro or make this repository public to enable this feature.","status":"403"}' >&2
      exit 1
      ;;
    *)
      echo "unexpected PUT in $scenario" >&2
      exit 1
      ;;
  esac
fi

if [[ "$method" == "PATCH" ]]; then
  if [[ "$path" == */protection/required_pull_request_reviews ]]; then
    case "$scenario" in
      apply-review-success)
        exit 0
        ;;
      apply-review-403)
        echo '{"message":"Pull request review protection unavailable","status":"403"}' >&2
        exit 1
        ;;
      *)
        echo "unexpected review PATCH in $scenario" >&2
        exit 1
        ;;
    esac
  fi

  case "$scenario" in
    apply-status-success)
      if ! jq -e '
        .strict == true and
        .checks == [
          {"context": "validate", "app_id": 15368},
          {"context": "build-and-test"}
        ]
      ' <<<"$input_body" >/dev/null; then
        echo "status update did not preserve the existing app binding while adding the missing check" >&2
        exit 1
      fi
      exit 0
      ;;
    apply-status-404-fallback)
      echo 'gh: Required status checks not enabled (HTTP 404)' >&2
      exit 1
      ;;
    apply-status-403)
      echo '{"message":"Required status checks are unavailable","status":"403"}' >&2
      exit 1
      ;;
    *)
      echo "unexpected PATCH in $scenario" >&2
      exit 1
      ;;
  esac
fi

reviews_for_repo() {
  case "$scenario" in
    missing-review-policy|apply-review-success|apply-review-403)
      if [[ "$repo" == "solswap-io/solswap-indexer" && "$branch" == "master" ]]; then
        printf '{"dismiss_stale_reviews":true,"require_code_owner_reviews":true,"require_last_push_approval":false,"required_approving_review_count":1}\n'
      else
        printf '{"dismiss_stale_reviews":true,"require_code_owner_reviews":true,"require_last_push_approval":true,"required_approving_review_count":1}\n'
      fi
      ;;
    weak-review-policy)
      if [[ "$repo" == "soramitsu/fearless-wallet-web" && "$branch" == "develop" ]]; then
        printf '{"dismiss_stale_reviews":false,"require_code_owner_reviews":false,"require_last_push_approval":false,"required_approving_review_count":0}\n'
      else
        printf '{"dismiss_stale_reviews":true,"require_code_owner_reviews":true,"require_last_push_approval":true,"required_approving_review_count":1}\n'
      fi
      ;;
    *)
      printf '{"dismiss_stale_reviews":true,"require_code_owner_reviews":true,"require_last_push_approval":true,"required_approving_review_count":1}\n'
      ;;
  esac
}

contexts_for_repo() {
  case "$1" in
    soramitsu/fearless-Android)
      printf '["validate","build-and-test"]\n'
      ;;
    soramitsu/fearless-iOS)
      printf '["validate","build","continuous-integration/jenkins/pr-merge"]\n'
      ;;
    soramitsu/fearless-wallet-web)
      printf '["validate","verify"]\n'
      ;;
    soramitsu/fearless-site-web)
      printf '["validate","build"]\n'
      ;;
    soramitsu/fearless-release-readiness)
      printf '["validate","verify","verify-owner"]\n'
      ;;
    tonswap-org/ton-indexer|solswap-io/solswap-indexer)
      printf '["validate","verify"]\n'
      ;;
    sora-xor/polkaswap-indexer)
      printf '["branch-flow","validate","verify"]\n'
      ;;
    *)
      printf '[]\n'
      ;;
  esac
}

if [[ "$path" != */branches/* ]]; then
  case "$scenario" in
    wrong-default)
      emit_jq "master"
      ;;
    wrong-indexer-default)
      if [[ "$repo" == "solswap-io/solswap-indexer" ]]; then
        emit_jq "develop"
      else
        emit_jq "$(default_branch_for_repo "$repo")"
      fi
      ;;
    private-wallet)
      if [[ "$repo" == "soramitsu/fearless-wallet-web" ]]; then
        emit_jq "$(default_branch_for_repo "$repo")" "" "" "true"
      else
        emit_jq "$(default_branch_for_repo "$repo")"
      fi
      ;;
    private-indexer)
      if [[ "$repo" == "solswap-io/solswap-indexer" ]]; then
        emit_jq "$(default_branch_for_repo "$repo")" "" "" "true"
      else
        emit_jq "$(default_branch_for_repo "$repo")"
      fi
      ;;
    private-root)
      if [[ "$repo" == "soramitsu/fearless-release-readiness" ]]; then
        emit_jq "$(default_branch_for_repo "$repo")" "" "" "true"
      else
        emit_jq "$(default_branch_for_repo "$repo")"
      fi
      ;;
    wrong-root-default)
      if [[ "$repo" == "soramitsu/fearless-release-readiness" ]]; then
        emit_jq "develop"
      else
        emit_jq "$(default_branch_for_repo "$repo")"
      fi
      ;;
    *)
      emit_jq "$(default_branch_for_repo "$repo")"
      ;;
  esac
  exit 0
fi

branch="$(branch_from_path "$path")"

if [[ "$path" == */protection/required_pull_request_reviews ]]; then
  reviews_for_repo
  exit 0
fi

if [[ "$path" == */protection ]]; then
  case "$scenario" in
    ruleset-fallback|ruleset-missing-branch-flow|ruleset-bypass|ruleset-apply-success|ruleset-apply-ambiguous)
      if [[ "$repo" == "sora-xor/polkaswap-indexer" ]]; then
        echo 'gh: Branch protection has been disabled on this repository. (HTTP 404)' >&2
        exit 1
      fi
      ;;
  esac

  contexts_json="$(contexts_for_repo "$repo")"
  case "$scenario" in
    polkaswap-missing-branch-flow)
      if [[ "$repo" == "sora-xor/polkaswap-indexer" && "$branch" == "master" ]]; then
        contexts_json='["validate","verify"]'
      fi
      ;;
    missing-status-check|apply-status-success|apply-status-404-fallback|apply-status-403)
      if [[ "$repo" == "soramitsu/fearless-Android" && "$branch" == "master" ]]; then
        contexts_json='["validate"]'
      fi
      ;;
    root-missing-status-check)
      if [[ "$repo" == "soramitsu/fearless-release-readiness" && "$branch" == "main" ]]; then
        contexts_json='["validate","verify"]'
      fi
      ;;
  esac

  strict=true
  admins=true
  conversations=true
  force_pushes=false
  deletions=false
  bypass_users='[]'
  case "$scenario" in
    weak-classic-policy)
      if [[ "$repo" == "soramitsu/fearless-wallet-web" && "$branch" == "develop" ]]; then
        strict=false
        admins=false
        conversations=false
        force_pushes=true
        deletions=true
      fi
      ;;
    apply-classic-policy-success)
      if [[ "$repo" == "soramitsu/fearless-wallet-web" &&
        "$branch" == "develop" &&
        ! -f "$classic_state_file" ]]; then
        strict=false
        admins=false
        conversations=false
        force_pushes=true
        deletions=true
        bypass_users='[{"login":"unsafe-bypass"}]'
      fi
      ;;
    classic-bypass-policy)
      if [[ "$repo" == "soramitsu/fearless-wallet-web" && "$branch" == "develop" ]]; then
        bypass_users='[{"login":"unsafe-bypass"}]'
      fi
      ;;
  esac

  if [[ "$jq_expr" == ".required_status_checks.contexts // []" ]]; then
    printf '%s\n' "$contexts_json"
  else
    jq -n \
      --argjson contexts "$contexts_json" \
      --argjson strict "$strict" \
      --argjson admins "$admins" \
      --argjson conversations "$conversations" \
      --argjson force_pushes "$force_pushes" \
      --argjson deletions "$deletions" \
      --argjson bypass_users "$bypass_users" '
      {
        required_status_checks: {
          strict: $strict,
          contexts: $contexts,
          checks: ($contexts | map({context: ., app_id: 15368}))
        },
        enforce_admins: {enabled: $admins},
        required_pull_request_reviews: {
          dismiss_stale_reviews: true,
          require_code_owner_reviews: true,
          required_approving_review_count: 1,
          require_last_push_approval: true,
          dismissal_restrictions: {
            users: [],
            teams: [],
            apps: []
          },
          bypass_pull_request_allowances: {
            users: $bypass_users,
            teams: [],
            apps: []
          }
        },
        restrictions: null,
        required_linear_history: {enabled: true},
        required_conversation_resolution: {enabled: $conversations},
        allow_force_pushes: {enabled: $force_pushes},
        allow_deletions: {enabled: $deletions},
        block_creations: {enabled: true},
        lock_branch: {enabled: false},
        allow_fork_syncing: {enabled: false}
      }
    '
  fi
  exit 0
fi

if [[ "$branch" == "staging" ]]; then
  case "$scenario" in
    staging-present|delete-staging-success|delete-staging-protected-success|delete-staging-403)
      emit_jq "" "" "staging"
      exit 0
      ;;
    *)
      echo "Not Found" >&2
      exit 1
      ;;
  esac
fi

case "$scenario" in
  missing-develop)
    if [[ "$branch" == "develop" ]]; then
      echo "Not Found" >&2
      exit 1
    fi
    emit_jq "" "true"
    ;;
  root-missing-main)
    if [[ "$repo" == "soramitsu/fearless-release-readiness" && "$branch" == "main" ]]; then
      echo "Not Found" >&2
      exit 1
    fi
    emit_jq "" "true"
    ;;
  unprotected|apply-success|apply-403)
    if [[ "$repo" == "soramitsu/fearless-wallet-web" && "$branch" == "master" ]]; then
      emit_jq "" "false"
    else
      emit_jq "" "true"
    fi
    ;;
  polkaswap-unprotected)
    if [[ "$repo" == "sora-xor/polkaswap-indexer" && "$branch" == "develop" ]]; then
      emit_jq "" "false"
    else
      emit_jq "" "true"
    fi
    ;;
  *)
    emit_jq "" "true"
    ;;
esac
SH

chmod +x "$fake_gh"

run_audit() {
  local scenario="$1"
  shift
  rm -f "${TMPDIR:-/tmp}/fake-gh-ruleset-${scenario}"
  rm -f "${TMPDIR:-/tmp}/fake-gh-classic-${scenario}"
  FAKE_GH_SCENARIO="$scenario" GH_BIN="$fake_gh" bash "$AUDIT_SCRIPT" "$@"
}

expect_success() {
  local name="$1"
  shift
  local output
  if ! output="$("$@" 2>&1)"; then
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

expect_success "all-good fixture" run_audit good
expect_failure "wrong-default fixture" "default branch is 'master'" run_audit wrong-default
expect_failure "wrong-indexer-default fixture" "default branch is 'develop', expected 'master'" run_audit wrong-indexer-default
expect_failure "private-wallet fixture" "repository is private, expected public/open-source" run_audit private-wallet
expect_failure "private-indexer fixture" "repository is private, expected public/open-source" run_audit private-indexer
expect_failure "private-root fixture" "soramitsu/fearless-release-readiness: repository is private, expected public/open-source" run_audit private-root
expect_failure "wrong-root-default fixture" "soramitsu/fearless-release-readiness: default branch is 'develop', expected 'main'" run_audit wrong-root-default
expect_failure "missing-develop fixture" "branch 'develop' is missing" run_audit missing-develop
expect_failure "root-missing-main fixture" "soramitsu/fearless-release-readiness: branch 'main' is missing" run_audit root-missing-main
expect_failure "unprotected fixture" "branch 'master' is not protected" run_audit unprotected
expect_failure "polkaswap-unprotected fixture" "sora-xor/polkaswap-indexer: branch 'develop' is not protected" run_audit polkaswap-unprotected
expect_failure "missing-status-check fixture" "branch 'master' missing required status checks: build-and-test" run_audit missing-status-check
expect_failure "root-missing-status-check fixture" "soramitsu/fearless-release-readiness: branch 'main' missing required status checks: verify-owner" run_audit root-missing-status-check
expect_failure "polkaswap-missing-branch-flow fixture" "sora-xor/polkaswap-indexer: branch 'master' missing required status checks: branch-flow" run_audit polkaswap-missing-branch-flow
expect_failure "weak classic policy fixture" "missing strict no-bypass classic protection: strict_required_status_checks enforce_admins required_conversation_resolution disallow_force_pushes disallow_deletions" run_audit weak-classic-policy
expect_failure "classic bypass fixture" "missing strict no-bypass classic protection: disallow_pull_request_bypass" run_audit classic-bypass-policy
expect_success "classic policy apply fixture" run_audit apply-classic-policy-success --apply-protection
expect_success "active ruleset fallback fixture" run_audit ruleset-fallback
expect_failure "ruleset missing status fixture" "branch 'master' ruleset missing required status checks: branch-flow" run_audit ruleset-missing-branch-flow
expect_failure "ruleset bypass fixture" "ruleset 42 affecting 'develop' permits a bypass actor" run_audit ruleset-bypass
expect_success "ruleset apply fixture" run_audit ruleset-apply-success --apply-protection
expect_failure "ambiguous ruleset apply fixture" "expected exactly one effective repository ruleset, found 2" run_audit ruleset-apply-ambiguous --apply-protection
expect_failure "missing-review-policy fixture" "branch 'master' missing pull-request review protection: require_last_push_approval" run_audit missing-review-policy
expect_failure "weak-review-policy fixture" "branch 'develop' missing pull-request review protection: dismiss_stale_reviews require_code_owner_reviews require_last_push_approval required_approving_review_count" run_audit weak-review-policy
expect_failure "staging fixture" "hosted staging branch still exists" run_audit staging-present
expect_success "delete-staging fixture" run_audit delete-staging-success --delete-staging
rm -f "${TMPDIR:-/tmp}/fake-gh-delete-staging-count"
expect_success "delete-protected-staging fixture" run_audit delete-staging-protected-success --delete-staging
expect_failure "delete-staging-403 fixture" "Cannot delete protected branch" run_audit delete-staging-403 --delete-staging
expect_success "apply-success fixture" run_audit apply-success --apply-protection
expect_success "apply-status-success fixture" run_audit apply-status-success --apply-protection
expect_success "apply-status-404-fallback fixture" run_audit apply-status-404-fallback --apply-protection
expect_success "apply-review-success fixture" run_audit apply-review-success --apply-protection
expect_failure "apply-403 fixture" "Upgrade to GitHub Pro" run_audit apply-403 --apply-protection
expect_failure "apply-status-403 fixture" "Required status checks are unavailable" run_audit apply-status-403 --apply-protection
expect_failure "apply-review-403 fixture" "Pull request review protection unavailable" run_audit apply-review-403 --apply-protection

echo "[github-governance-test] all tests passed"
