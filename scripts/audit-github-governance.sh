#!/usr/bin/env bash
set -euo pipefail

GH_BIN="${GH_BIN:-gh}"
APPLY_PROTECTION=false
DELETE_STAGING=false

repos=(
  "soramitsu/fearless-Android"
  "soramitsu/fearless-iOS"
  "soramitsu/fearless-wallet-web"
  "soramitsu/fearless-site-web"
  "soramitsu/fearless-release-readiness"
  "tonswap-org/ton-indexer"
  "solswap-io/solswap-indexer"
  "sora-xor/polkaswap-indexer"
)

usage() {
  cat <<'USAGE'
Usage: scripts/audit-github-governance.sh [--apply-protection] [--delete-staging]

Checks maintained Fearless GitHub repositories for:
  - wallet/public-site/indexer/release-readiness repositories are public
  - wallet/public-site default branch is develop
  - release-readiness default branch is main
  - indexer default branch is master
  - each repository's maintained branches exist and are protected
  - protected branches (classic rules or active no-bypass rulesets) require the
    repo's Branch Flow and CI status checks
  - status checks are strict/current, administrators cannot bypass classic
    protection, conversations must be resolved, and force-push/deletion stay off
  - protected branches require CODEOWNERS review, stale-review dismissal,
    last-push approval, and at least one approving review
  - hosted staging branch is absent

--apply-protection attempts the standard branch-protection API policy for
develop/master when a branch exists but is unprotected or missing expected
status-check contexts or review-policy settings. When exactly one active
repository ruleset protects the branch, it preserves unrelated rules and
conditions while enforcing the same no-bypass status/review policy.
--delete-staging deletes hosted staging branches after local release workflows
have been audited not to depend on staging. It is never enabled by default.
USAGE
}

while (($#)); do
  case "$1" in
    --apply-protection)
      APPLY_PROTECTION=true
      ;;
    --delete-staging)
      DELETE_STAGING=true
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "[github-governance][error] Unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
  shift
done

log() { echo "[github-governance] $*"; }
warn() { echo "[github-governance][warn] $*" >&2; }

if ! command -v "$GH_BIN" >/dev/null 2>&1; then
  echo "[github-governance][error] gh CLI not found. Install GitHub CLI or set GH_BIN." >&2
  exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "[github-governance][error] jq not found. Install jq for status-check context validation." >&2
  exit 1
fi

api_get() {
  "$GH_BIN" api \
    -H 'Accept: application/vnd.github+json' \
    -H 'X-GitHub-Api-Version: 2026-03-10' \
    "$@"
}

apply_branch_protection() {
  local repo="$1"
  local branch="$2"
  shift 2
  local contexts_json

  contexts_json="$(printf '%s\n' "$@" | jq -R . | jq -s .)"

  api_get \
    --method PUT \
    "repos/$repo/branches/$branch/protection" \
    --input - >/dev/null <<JSON
{
  "required_status_checks": {
    "strict": true,
    "contexts": $contexts_json
  },
  "enforce_admins": true,
  "required_pull_request_reviews": {
    "dismiss_stale_reviews": true,
    "require_last_push_approval": true,
    "require_code_owner_reviews": true,
    "required_approving_review_count": 1
  },
  "restrictions": null,
  "required_linear_history": false,
  "allow_force_pushes": false,
  "allow_deletions": false,
  "required_conversation_resolution": true
}
JSON
}

apply_classic_protection_policy() {
  local repo="$1"
  local branch="$2"
  local protection_json="$3"
  shift 3
  local contexts_json payload

  contexts_json="$(printf '%s\n' "$@" | jq -R . | jq -s .)"
  payload="$(
    jq --argjson expected_contexts "$contexts_json" '
      def actor_names($field):
        ($field // []) |
        map(.login // .slug) |
        map(select(type == "string" and length > 0));
      def app_names($field):
        ($field // []) |
        map(.slug) |
        map(select(type == "string" and length > 0));
      {
        required_status_checks: (
          if .required_status_checks == null then
            {
              strict: true,
              contexts: $expected_contexts
            }
          elif ((.required_status_checks.checks // []) | length) > 0 then
            {
              strict: true,
              checks: (
                reduce (
                  (
                    .required_status_checks.checks |
                    map(
                      if .app_id == null then
                        {context: .context}
                      else
                        {context: .context, app_id: .app_id}
                      end
                    )
                  ) +
                  ($expected_contexts | map({context: .}))
                )[] as $check (
                  [];
                  if any(.[]; .context == $check.context) then
                    .
                  else
                    . + [$check]
                  end
                )
              )
            }
          else
            {
              strict: true,
              contexts: (
                (.required_status_checks.contexts // []) +
                $expected_contexts |
                unique
              )
            }
          end
        ),
        enforce_admins: true,
        required_pull_request_reviews: (
          if .required_pull_request_reviews == null then
            {
              dismissal_restrictions: {
                users: [],
                teams: [],
                apps: []
              },
              dismiss_stale_reviews: true,
              require_code_owner_reviews: true,
              required_approving_review_count: 1,
              require_last_push_approval: true,
              bypass_pull_request_allowances: {
                users: [],
                teams: [],
                apps: []
              }
            }
          else
            {
              dismissal_restrictions: {
                users: actor_names(.required_pull_request_reviews.dismissal_restrictions.users),
                teams: actor_names(.required_pull_request_reviews.dismissal_restrictions.teams),
                apps: app_names(.required_pull_request_reviews.dismissal_restrictions.apps)
              },
              dismiss_stale_reviews: true,
              require_code_owner_reviews: true,
              required_approving_review_count: (
                if (.required_pull_request_reviews.required_approving_review_count // 0) < 1 then
                  1
                else
                  .required_pull_request_reviews.required_approving_review_count
                end
              ),
              require_last_push_approval: true,
              bypass_pull_request_allowances: {
                users: [],
                teams: [],
                apps: []
              }
            }
          end
        ),
        restrictions: (
          if .restrictions == null then
            null
          else
            {
              users: actor_names(.restrictions.users),
              teams: actor_names(.restrictions.teams),
              apps: app_names(.restrictions.apps)
            }
          end
        ),
        required_linear_history: (.required_linear_history.enabled // false),
        allow_force_pushes: false,
        allow_deletions: false,
        block_creations: (.block_creations.enabled // false),
        required_conversation_resolution: true,
        lock_branch: (.lock_branch.enabled // false),
        allow_fork_syncing: (.allow_fork_syncing.enabled // false)
      }
    ' <<<"$protection_json"
  )"

  api_get \
    --method PUT \
    "repos/$repo/branches/$branch/protection" \
    --input - >/dev/null <<<"$payload"
}

apply_required_status_checks() {
  local repo="$1"
  local branch="$2"
  local protection_json="$3"
  shift 3
  local contexts_json payload

  contexts_json="$(printf '%s\n' "$@" | jq -R . | jq -s .)"
  payload="$(
    jq --argjson expected_contexts "$contexts_json" '
      if ((.required_status_checks.checks // []) | length) > 0 then
        {
          strict: true,
          checks: (
            reduce (
              (
                .required_status_checks.checks |
                map(
                  if (.app_id | type) == "number" then
                    {context: .context, app_id: .app_id}
                  else
                    {context: .context}
                  end
                )
              ) +
              ($expected_contexts | map({context: .}))
            )[] as $check (
              [];
              if any(.[]; .context == $check.context) then
                .
              else
                . + [$check]
              end
            )
          )
        }
      else
        {
          strict: true,
          contexts: (
            (.required_status_checks.contexts // []) +
            $expected_contexts |
            unique
          )
        }
      end
    ' <<<"$protection_json"
  )"

  api_get \
    --method PATCH \
    "repos/$repo/branches/$branch/protection/required_status_checks" \
    --input - >/dev/null <<<"$payload"
}

apply_pull_request_reviews() {
  local repo="$1"
  local branch="$2"

  api_get \
    --method PATCH \
    "repos/$repo/branches/$branch/protection/required_pull_request_reviews" \
    --input - >/dev/null <<'JSON'
{
  "dismiss_stale_reviews": true,
  "require_code_owner_reviews": true,
  "require_last_push_approval": true,
  "required_approving_review_count": 1
}
JSON
}

apply_repository_ruleset_policy() {
  local repo="$1"
  local branch="$2"
  local effective_rules_json="$3"
  shift 3
  local expected_contexts=("$@")
  local -a ruleset_ids=()
  local ruleset_id ruleset_detail payload contexts_json

  while IFS= read -r ruleset_id; do
    [[ -n "$ruleset_id" && "$ruleset_id" != "null" ]] &&
      ruleset_ids+=("$ruleset_id")
  done < <(
    jq -r '.[].ruleset_id // empty' <<<"$effective_rules_json" |
      sort -u
  )

  if ((${#ruleset_ids[@]} != 1)); then
    echo "cannot safely update '$branch': expected exactly one effective repository ruleset, found ${#ruleset_ids[@]}" >&2
    return 1
  fi
  ruleset_id="${ruleset_ids[0]}"

  if ! ruleset_detail="$(api_get "repos/$repo/rulesets/$ruleset_id" 2>&1)"; then
    echo "unable to inspect ruleset $ruleset_id before update: $ruleset_detail" >&2
    return 1
  fi
  if ! jq -e '
    type == "object" and
    (.name | type == "string" and length > 0) and
    (.target == "branch") and
    (.enforcement == "active") and
    (.conditions | type == "object") and
    (.rules | type == "array")
  ' <<<"$ruleset_detail" >/dev/null; then
    echo "ruleset $ruleset_id is not an active branch ruleset with a complete editable policy" >&2
    return 1
  fi

  contexts_json="$(
    printf '%s\n' "${expected_contexts[@]}" |
      jq -R '{context: .}' |
      jq -s .
  )"
  payload="$(
    jq \
      --argjson required_status_checks "$contexts_json" '
      def clean_rule:
        if .parameters? != null then
          {type: .type, parameters: .parameters}
        else
          {type: .type}
        end;
      {
        name: .name,
        target: .target,
        enforcement: "active",
        bypass_actors: [],
        conditions: .conditions,
        rules: (
          [
            .rules[] |
            select(
              .type != "deletion" and
              .type != "non_fast_forward" and
              .type != "pull_request" and
              .type != "required_status_checks"
            ) |
            clean_rule
          ] + [
            {type: "deletion"},
            {type: "non_fast_forward"},
            {
              type: "pull_request",
              parameters: {
                dismiss_stale_reviews_on_push: true,
                require_code_owner_review: true,
                require_last_push_approval: true,
                required_approving_review_count: 1,
                required_review_thread_resolution: true
              }
            },
            {
              type: "required_status_checks",
              parameters: {
                strict_required_status_checks_policy: true,
                required_status_checks: $required_status_checks
              }
            }
          ]
        )
      }
    ' <<<"$ruleset_detail"
  )"

  api_get \
    --method PUT \
    "repos/$repo/rulesets/$ruleset_id" \
    --input - >/dev/null <<<"$payload"
}

delete_staging_branch() {
  local repo="$1"

  api_get \
    --method DELETE \
    "repos/$repo/git/refs/heads/staging" >/dev/null
}

remove_staging_branch_protection() {
  local repo="$1"

  api_get \
    --method DELETE \
    "repos/$repo/branches/staging/protection" >/dev/null
}

expected_public_repo() {
  case "$1" in
    soramitsu/fearless-Android|\
    soramitsu/fearless-iOS|\
    soramitsu/fearless-wallet-web|\
    soramitsu/fearless-site-web|\
    soramitsu/fearless-release-readiness|\
    tonswap-org/ton-indexer|\
    solswap-io/solswap-indexer|\
    sora-xor/polkaswap-indexer)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

expected_default_branch() {
  case "$1" in
    soramitsu/fearless-release-readiness)
      echo "main"
      ;;
    tonswap-org/ton-indexer|\
    solswap-io/solswap-indexer|\
    sora-xor/polkaswap-indexer)
      echo "master"
      ;;
    *)
      echo "develop"
      ;;
  esac
}

expected_protected_branches() {
  case "$1" in
    soramitsu/fearless-release-readiness)
      printf '%s\n' main
      ;;
    *)
      printf '%s\n' develop master
      ;;
  esac
}

expected_status_contexts() {
  case "$1" in
    soramitsu/fearless-Android)
      printf '%s\n' validate build-and-test
      ;;
    soramitsu/fearless-iOS)
      printf '%s\n' validate build continuous-integration/jenkins/pr-merge
      ;;
    soramitsu/fearless-wallet-web)
      printf '%s\n' validate verify
      ;;
    soramitsu/fearless-site-web)
      printf '%s\n' validate build
      ;;
    soramitsu/fearless-release-readiness)
      printf '%s\n' validate verify verify-owner
      ;;
    tonswap-org/ton-indexer|\
    solswap-io/solswap-indexer)
      printf '%s\n' validate verify
      ;;
    sora-xor/polkaswap-indexer)
      printf '%s\n' branch-flow validate verify
      ;;
  esac
}

failures=()

record_failure() {
  failures+=("$1")
  warn "$1"
}

audit_ruleset_policy() {
  local repo="$1"
  local branch="$2"
  local rules_json="$3"
  shift 3
  local expected_contexts=("$@")
  local initial_failure_count="${#failures[@]}"

  if ! jq -e 'type == "array" and length > 0' <<<"$rules_json" >/dev/null; then
    record_failure "$repo: branch '$branch' has no effective active repository rules"
    return
  fi

  local missing_contexts=()
  for context in "${expected_contexts[@]}"; do
    if ! CONTEXT="$context" jq -e '
      any(.[];
        .type == "required_status_checks" and
        any(.parameters.required_status_checks[]?; .context == env.CONTEXT)
      )
    ' <<<"$rules_json" >/dev/null; then
      missing_contexts+=("$context")
    fi
  done
  if ((${#missing_contexts[@]} > 0)); then
    record_failure "$repo: branch '$branch' ruleset missing required status checks: ${missing_contexts[*]}"
  fi
  if ! jq -e 'any(.[]; .type == "required_status_checks" and .parameters.strict_required_status_checks_policy == true)' <<<"$rules_json" >/dev/null; then
    record_failure "$repo: branch '$branch' ruleset does not require branches to be current before status checks pass"
  fi

  local missing_review_settings=()
  if ! jq -e 'any(.[]; .type == "pull_request" and .parameters.dismiss_stale_reviews_on_push == true)' <<<"$rules_json" >/dev/null; then
    missing_review_settings+=("dismiss_stale_reviews_on_push")
  fi
  if ! jq -e 'any(.[]; .type == "pull_request" and .parameters.require_code_owner_review == true)' <<<"$rules_json" >/dev/null; then
    missing_review_settings+=("require_code_owner_review")
  fi
  if ! jq -e 'any(.[]; .type == "pull_request" and .parameters.require_last_push_approval == true)' <<<"$rules_json" >/dev/null; then
    missing_review_settings+=("require_last_push_approval")
  fi
  if ! jq -e 'any(.[]; .type == "pull_request" and (.parameters.required_approving_review_count // 0) >= 1)' <<<"$rules_json" >/dev/null; then
    missing_review_settings+=("required_approving_review_count")
  fi
  if ! jq -e 'any(.[]; .type == "pull_request" and .parameters.required_review_thread_resolution == true)' <<<"$rules_json" >/dev/null; then
    missing_review_settings+=("required_review_thread_resolution")
  fi
  if ((${#missing_review_settings[@]} > 0)); then
    record_failure "$repo: branch '$branch' ruleset missing pull-request review protection: ${missing_review_settings[*]}"
  fi
  if ! jq -e 'any(.[]; .type == "deletion")' <<<"$rules_json" >/dev/null; then
    record_failure "$repo: branch '$branch' ruleset does not block deletion"
  fi
  if ! jq -e 'any(.[]; .type == "non_fast_forward")' <<<"$rules_json" >/dev/null; then
    record_failure "$repo: branch '$branch' ruleset does not block force pushes"
  fi

  local ruleset_id ruleset_detail
  while IFS= read -r ruleset_id; do
    [[ -n "$ruleset_id" && "$ruleset_id" != "null" ]] || continue
    if ! ruleset_detail="$(api_get "repos/$repo/rulesets/$ruleset_id" 2>&1)"; then
      record_failure "$repo: unable to inspect ruleset $ruleset_id for '$branch': $ruleset_detail"
      continue
    fi
    if [[ "$(jq -r '.enforcement // "disabled"' <<<"$ruleset_detail")" != "active" ]]; then
      record_failure "$repo: ruleset $ruleset_id affecting '$branch' is not active"
    fi
    if [[ "$(jq -r '(.bypass_actors // []) | length' <<<"$ruleset_detail")" != "0" ||
      "$(jq -r '.current_user_can_bypass // "unknown"' <<<"$ruleset_detail")" != "never" ]]; then
      record_failure "$repo: ruleset $ruleset_id affecting '$branch' permits a bypass actor"
    fi
  done < <(jq -r '.[].ruleset_id // empty' <<<"$rules_json" | sort -u)

  if ((${#failures[@]} == initial_failure_count)); then
    log "$repo: '$branch' is protected by an active no-bypass repository ruleset"
  fi
}

classic_protection_policy_gaps() {
  local protection_json="$1"

  if ! jq -e 'type == "object"' <<<"$protection_json" >/dev/null; then
    printf '%s\n' malformed_policy
    return
  fi
  jq -e '.required_status_checks.strict == true' <<<"$protection_json" >/dev/null ||
    printf '%s\n' strict_required_status_checks
  jq -e '.enforce_admins.enabled == true' <<<"$protection_json" >/dev/null ||
    printf '%s\n' enforce_admins
  jq -e '.required_conversation_resolution.enabled == true' <<<"$protection_json" >/dev/null ||
    printf '%s\n' required_conversation_resolution
  jq -e '.allow_force_pushes.enabled == false' <<<"$protection_json" >/dev/null ||
    printf '%s\n' disallow_force_pushes
  jq -e '.allow_deletions.enabled == false' <<<"$protection_json" >/dev/null ||
    printf '%s\n' disallow_deletions
  jq -e '
    ((.required_pull_request_reviews.bypass_pull_request_allowances.users // []) | length) == 0 and
    ((.required_pull_request_reviews.bypass_pull_request_allowances.teams // []) | length) == 0 and
    ((.required_pull_request_reviews.bypass_pull_request_allowances.apps // []) | length) == 0
  ' <<<"$protection_json" >/dev/null ||
    printf '%s\n' disallow_pull_request_bypass
}

for repo in "${repos[@]}"; do
  log "Checking $repo"

  if ! default_branch="$(api_get "repos/$repo" --jq '.default_branch' 2>&1)"; then
    record_failure "$repo: unable to read repository metadata: $default_branch"
    continue
  fi

  expected_branch="$(expected_default_branch "$repo")"
  if [[ "$default_branch" != "$expected_branch" ]]; then
    record_failure "$repo: default branch is '$default_branch', expected '$expected_branch'"
  fi

  if expected_public_repo "$repo"; then
    if ! is_private="$(api_get "repos/$repo" --jq '.private' 2>&1)"; then
      record_failure "$repo: unable to read repository visibility: $is_private"
    elif [[ "$is_private" != "false" ]]; then
      record_failure "$repo: repository is private, expected public/open-source"
    fi
  fi

  while IFS= read -r branch; do
    [[ -n "$branch" ]] || continue
    if ! protected="$(api_get "repos/$repo/branches/$branch" --jq '.protected' 2>&1)"; then
      record_failure "$repo: branch '$branch' is missing or unreadable: $protected"
      continue
    fi

    expected_contexts=()
    while IFS= read -r context; do
      [[ -n "$context" ]] && expected_contexts+=("$context")
    done < <(expected_status_contexts "$repo")

    if [[ "$protected" != "true" ]]; then
      if [[ "$APPLY_PROTECTION" == true ]]; then
        if apply_output="$(apply_branch_protection "$repo" "$branch" "${expected_contexts[@]}" 2>&1)"; then
          log "$repo: applied standard protection policy to '$branch'"
        else
          record_failure "$repo: failed to apply protection to '$branch': $apply_output"
        fi
      else
        record_failure "$repo: branch '$branch' is not protected"
      fi
      continue
    fi

    if ! protection_json="$(
      api_get "repos/$repo/branches/$branch/protection" 2>&1
    )"; then
      if rules_json="$(api_get "repos/$repo/rules/branches/$branch" 2>&1)" &&
        jq -e 'type == "array" and length > 0' <<<"$rules_json" >/dev/null 2>&1; then
        if [[ "$APPLY_PROTECTION" == true ]]; then
          if ruleset_apply_output="$(
            apply_repository_ruleset_policy \
              "$repo" \
              "$branch" \
              "$rules_json" \
              "${expected_contexts[@]}" 2>&1
          )"; then
            log "$repo: updated the effective repository ruleset for '$branch'"
            if ! rules_json="$(
              api_get "repos/$repo/rules/branches/$branch" 2>&1
            )"; then
              record_failure "$repo: unable to verify '$branch' ruleset policy after update: $rules_json"
              continue
            fi
          else
            record_failure "$repo: failed to update '$branch' repository ruleset policy: $ruleset_apply_output"
            continue
          fi
        fi
        audit_ruleset_policy "$repo" "$branch" "$rules_json" "${expected_contexts[@]}"
      else
        record_failure "$repo: unable to read '$branch' classic protection or effective ruleset policy: $protection_json ${rules_json:-}"
      fi
      continue
    fi

    classic_policy_gaps=()
    while IFS= read -r setting; do
      [[ -n "$setting" ]] && classic_policy_gaps+=("$setting")
    done < <(classic_protection_policy_gaps "$protection_json")

    if ((${#classic_policy_gaps[@]} > 0)); then
      if [[ "$APPLY_PROTECTION" == true ]]; then
        if apply_output="$(
          apply_classic_protection_policy \
            "$repo" \
            "$branch" \
            "$protection_json" \
            "${expected_contexts[@]}" 2>&1
        )"; then
          log "$repo: repaired '$branch' strict no-bypass classic protection policy"
          if ! protection_json="$(
            api_get "repos/$repo/branches/$branch/protection" 2>&1
          )"; then
            record_failure "$repo: unable to verify '$branch' classic protection after update: $protection_json"
            continue
          fi
          classic_policy_gaps=()
          while IFS= read -r setting; do
            [[ -n "$setting" ]] && classic_policy_gaps+=("$setting")
          done < <(classic_protection_policy_gaps "$protection_json")
          if ((${#classic_policy_gaps[@]} > 0)); then
            record_failure "$repo: '$branch' classic protection remains incomplete after update: ${classic_policy_gaps[*]}"
          fi
        else
          record_failure "$repo: failed to repair '$branch' classic protection (${classic_policy_gaps[*]}): $apply_output"
        fi
      else
        record_failure "$repo: branch '$branch' missing strict no-bypass classic protection: ${classic_policy_gaps[*]}"
      fi
    fi

    if ! contexts_json="$(
      jq -c '.required_status_checks.contexts // []' <<<"$protection_json"
    )"; then
      record_failure "$repo: unable to decode '$branch' required status checks"
      continue
    fi

    missing_contexts=()
    for context in "${expected_contexts[@]}"; do
      if ! CONTEXT="$context" jq -e 'index(env.CONTEXT) != null' <<<"$contexts_json" >/dev/null; then
        missing_contexts+=("$context")
      fi
    done

    if ((${#missing_contexts[@]} > 0)); then
      if [[ "$APPLY_PROTECTION" == true ]]; then
        if status_output="$(
          apply_required_status_checks \
            "$repo" \
            "$branch" \
            "$protection_json" \
            "${expected_contexts[@]}" 2>&1
        )"; then
          log "$repo: updated '$branch' required status checks: ${expected_contexts[*]}"
        elif [[ "$status_output" == *"Required status checks not enabled"* || "$status_output" == *"HTTP 404"* ]]; then
          if apply_output="$(
            apply_classic_protection_policy \
              "$repo" \
              "$branch" \
              "$protection_json" \
              "${expected_contexts[@]}" 2>&1
          )"; then
            log "$repo: initialized '$branch' protection with required status checks: ${expected_contexts[*]}"
          else
            record_failure "$repo: failed to initialize '$branch' protection with required status checks (${expected_contexts[*]}): $apply_output"
          fi
        else
          record_failure "$repo: failed to update '$branch' required status checks (${expected_contexts[*]}): $status_output"
        fi
      else
        record_failure "$repo: branch '$branch' missing required status checks: ${missing_contexts[*]}"
      fi
    fi

    if ! review_json="$(api_get "repos/$repo/branches/$branch/protection/required_pull_request_reviews" 2>&1)"; then
      record_failure "$repo: unable to read '$branch' pull-request review protection: $review_json"
      continue
    fi

    missing_review_settings=()
    if [[ "$(jq -r '.dismiss_stale_reviews // false' <<<"$review_json")" != "true" ]]; then
      missing_review_settings+=("dismiss_stale_reviews")
    fi
    if [[ "$(jq -r '.require_code_owner_reviews // false' <<<"$review_json")" != "true" ]]; then
      missing_review_settings+=("require_code_owner_reviews")
    fi
    if [[ "$(jq -r '.require_last_push_approval // false' <<<"$review_json")" != "true" ]]; then
      missing_review_settings+=("require_last_push_approval")
    fi
    if (( $(jq -r '.required_approving_review_count // 0' <<<"$review_json") < 1 )); then
      missing_review_settings+=("required_approving_review_count")
    fi

    if ((${#missing_review_settings[@]} > 0)); then
      if [[ "$APPLY_PROTECTION" == true ]]; then
        if review_output="$(apply_pull_request_reviews "$repo" "$branch" 2>&1)"; then
          log "$repo: updated '$branch' pull-request review protection"
        else
          record_failure "$repo: failed to update '$branch' pull-request review protection (${missing_review_settings[*]}): $review_output"
        fi
      else
        record_failure "$repo: branch '$branch' missing pull-request review protection: ${missing_review_settings[*]}"
      fi
    fi
  done < <(expected_protected_branches "$repo")

  if staging_name="$(api_get "repos/$repo/branches/staging" --jq '.name' 2>/dev/null)"; then
    if [[ "$staging_name" == "staging" ]]; then
      if [[ "$DELETE_STAGING" == true ]]; then
        if delete_output="$(delete_staging_branch "$repo" 2>&1)"; then
          log "$repo: deleted hosted staging branch"
        elif [[ "$delete_output" == *"Cannot delete this branch"* || "$delete_output" == *"protected"* || "$delete_output" == *"HTTP 422"* ]]; then
          if protection_output="$(remove_staging_branch_protection "$repo" 2>&1)" &&
            delete_after_unprotect_output="$(delete_staging_branch "$repo" 2>&1)"; then
            log "$repo: removed staging protection and deleted hosted staging branch"
          else
            record_failure "$repo: failed to delete protected hosted staging branch: ${protection_output:-$delete_after_unprotect_output}"
          fi
        else
          record_failure "$repo: failed to delete hosted staging branch: $delete_output"
        fi
      else
        record_failure "$repo: hosted staging branch still exists"
      fi
    fi
  fi
done

if ((${#failures[@]} > 0)); then
  echo "[github-governance][error] GitHub governance audit failed:" >&2
  printf '  - %s\n' "${failures[@]}" >&2
  exit 1
fi

log "GitHub governance audit passed."
