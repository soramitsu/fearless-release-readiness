#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="${RELEASE_PR_MERGE_ROOT:-$(cd "$SCRIPT_DIR/.." && pwd)}"
CONFIG_FILE="${RELEASE_PR_MERGE_CONFIG:-$ROOT_DIR/config/release-readiness-prs.tsv}"
READINESS_AUDIT="$SCRIPT_DIR/audit-release-pr-readiness.sh"
GH_BIN="${GH_BIN:-gh}"
MODE="dry-run"
MERGE_METHOD="${RELEASE_PR_MERGE_METHOD:-merge}"

usage() {
  cat <<'USAGE'
Usage: scripts/merge-release-prs.sh [--dry-run|--apply] [--config FILE] [--merge-method merge|squash|rebase]

Safely prepares or applies protected-branch merges for release PRs listed in
config/release-readiness-prs.tsv. Default mode is --dry-run.

The script refuses to merge draft PRs, unapproved PRs, non-clean merge states,
missing/incomplete/ambiguous required checks, unresolved review conversations,
branch-ref drift, closed-unmerged PRs, malformed GitHub responses, and duplicate
config rows. Every locally discovered candidate must also pass the central typed
check-authority audit for its exact reviewed PR number and head SHA. Apply mode
repeats that authoritative preflight immediately before gh pr merge, uses
--match-head-commit, and never uses administrator bypass.

Apply mode requires:

  RELEASE_PR_MERGE_CONFIRM=merge-release-prs

Environment:
  RELEASE_PR_MERGE_ROOT     Workspace root.
  RELEASE_PR_MERGE_CONFIG   Override config path.
  RELEASE_PR_MERGE_METHOD   merge, squash, or rebase. Defaults to merge.
  RELEASE_PR_MERGE_CONFIRM  Required confirmation token for --apply.
  GH_BIN                    GitHub CLI executable.
USAGE
}

while (($#)); do
  case "$1" in
    --dry-run)
      MODE="dry-run"
      shift
      ;;
    --apply)
      MODE="apply"
      shift
      ;;
    --config)
      CONFIG_FILE="$2"
      shift 2
      ;;
    --merge-method)
      MERGE_METHOD="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "[release-pr-merge][error] Unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

log() { echo "[release-pr-merge] $*"; }
warn() { echo "[release-pr-merge][warn] $*" >&2; }
fail() {
  echo "[release-pr-merge][error] $*" >&2
  exit 1
}

case "$MERGE_METHOD" in
  merge) merge_flag="--merge" ;;
  squash) merge_flag="--squash" ;;
  rebase) merge_flag="--rebase" ;;
  *) fail "Unsupported merge method: $MERGE_METHOD" ;;
esac

[[ -f "$CONFIG_FILE" ]] || fail "Required PR config missing: $CONFIG_FILE"
[[ -f "$READINESS_AUDIT" && ! -L "$READINESS_AUDIT" ]] || fail "Authoritative release PR readiness auditor missing or aliased: $READINESS_AUDIT"
command -v "$GH_BIN" >/dev/null 2>&1 || fail "gh CLI not found. Install GitHub CLI or set GH_BIN."

tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

candidates_tsv="$tmp_dir/candidates.tsv"
: > "$candidates_tsv"

failures=()
requirement_keys=()
checked_count=0
candidate_count=0
already_merged_count=0

record_failure() {
  failures+=("$1")
  warn "$1"
}

verify_authoritative_open_candidate() {
  local repo="$1"
  local head="$2"
  local base="$3"
  local number="$4"
  local sha="$5"
  local output

  if ! output="$(
    RELEASE_PR_READINESS_ROOT="$ROOT_DIR" \
    RELEASE_PR_READINESS_CONFIG="$CONFIG_FILE" \
    RELEASE_PR_READINESS_REPORT= \
    GH_BIN="$GH_BIN" \
      bash "$READINESS_AUDIT" \
        --config "$CONFIG_FILE" \
        --verify-open-candidate "$repo" "$head" "$base" "$number" "$sha" 2>&1
  )"; then
    if [[ -n "$output" ]]; then
      printf '%s\n' "$output" >&2
    fi
    return 1
  fi
}

is_safe_branch_ref() {
  local ref="$1"
  [[ "$ref" =~ ^[A-Za-z0-9][A-Za-z0-9._/-]*$ ]] || return 1
  [[ "$ref" != *..* ]] || return 1
  [[ "$ref" != *@* ]] || return 1
  [[ "$ref" != *//* ]] || return 1
  [[ "$ref" != */ ]] || return 1
  [[ "$ref" != *. ]] || return 1
  [[ ! "$ref" =~ (^|/)\. ]] || return 1
  [[ ! "$ref" =~ (^|/)[^/]*\.lock($|/) ]] || return 1
  return 0
}

extract_open_pr_number() {
  local raw="$1"
  node - "$raw" <<'NODE'
const raw = process.argv[2] || ''
try {
  const prs = JSON.parse(raw)
  if (!Array.isArray(prs)) process.exit(0)
  const open = prs.find((pr) => pr && pr.state === 'OPEN')
  const number = open && Number(open.number)
  if (Number.isInteger(number) && number > 0) {
    console.log(String(number))
  }
} catch (_) {
  process.exit(0)
}
NODE
}

json_query_error() {
  local raw="$1"
  node - "$raw" <<'NODE'
const raw = process.argv[2] || ''
console.log(JSON.stringify({ queryError: raw.slice(0, 500) }))
NODE
}

line_number=0
while IFS= read -r line || [[ -n "$line" ]]; do
  line_number=$((line_number + 1))
  [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue

  IFS=$'\t' read -r repo head base required_state required_checks extra <<< "$line"

  if [[ -n "${extra:-}" || -z "${repo:-}" || -z "${head:-}" || -z "${base:-}" || -z "${required_state:-}" || -z "${required_checks:-}" ]]; then
    record_failure "$CONFIG_FILE:$line_number: invalid release PR config line"
    continue
  fi
  if [[ ! "$repo" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]]; then
    record_failure "$CONFIG_FILE:$line_number: invalid repo '$repo'"
    continue
  fi
  if ! is_safe_branch_ref "$head"; then
    record_failure "$CONFIG_FILE:$line_number: invalid head branch ref"
    continue
  fi
  if ! is_safe_branch_ref "$base"; then
    record_failure "$CONFIG_FILE:$line_number: invalid base branch ref"
    continue
  fi
  if [[ "$required_state" != "merged" ]]; then
    record_failure "$CONFIG_FILE:$line_number: unsupported required_state '$required_state'"
    continue
  fi

  requirement_key="$repo"$'\t'"$head"$'\t'"$base"$'\t'"$required_state"
  if ((${#requirement_keys[@]} > 0)); then
    for existing_requirement_key in "${requirement_keys[@]}"; do
      if [[ "$existing_requirement_key" == "$requirement_key" ]]; then
        record_failure "$CONFIG_FILE:$line_number: duplicate release PR requirement row for $repo:$head -> $base"
        continue 2
      fi
    done
  fi
  requirement_keys+=("$requirement_key")

  checked_count=$((checked_count + 1))
  log "Inspecting $repo PR head '$head' into '$base' with required checks '$required_checks'"

  if ! pr_json="$("$GH_BIN" pr list \
    --repo "$repo" \
    --head "$head" \
    --base "$base" \
    --state all \
    --limit 20 \
    --json number,url,state,mergedAt,headRefOid,isDraft,reviewDecision,mergeStateStatus,statusCheckRollup,reviews 2>&1)"; then
    record_failure "$repo:$head -> $base: unable to query PR state: $pr_json"
    continue
  fi

  if ! ref_json="$("$GH_BIN" api "repos/$repo/git/matching-refs/heads/$head" 2>&1)"; then
    record_failure "$repo:$head -> $base: unable to query current PR head branch ref: $ref_json"
    continue
  fi

  review_threads_json="{}"
  open_pr_number="$(extract_open_pr_number "$pr_json")"
  if [[ -n "$open_pr_number" ]]; then
    owner="${repo%%/*}"
    name="${repo#*/}"
    if ! review_threads_json="$("$GH_BIN" api graphql \
      -F owner="$owner" \
      -F name="$name" \
      -F number="$open_pr_number" \
      -f query='query($owner: String!, $name: String!, $number: Int!) {
        repository(owner: $owner, name: $name) {
          pullRequest(number: $number) {
            reviewThreads(first: 100) {
              nodes {
                id
                isResolved
                isOutdated
                path
                line
                originalLine
                comments(first: 1) {
                  nodes {
                    url
                  }
                }
              }
              pageInfo {
                hasNextPage
              }
            }
          }
        }
      }' 2>&1)"; then
      review_threads_json="$(json_query_error "$review_threads_json")"
    fi
  fi

  set +e
  node_output="$(node - "$repo" "$head" "$base" "$required_checks" "$pr_json" "$ref_json" "$review_threads_json" 2>&1 <<'NODE'
const [repo, head, base, requiredChecksRaw, rawPrs, rawRefs, rawReviewThreads] = process.argv.slice(2)

function fail(message) {
  console.error(message)
  process.exit(1)
}

function parseRequiredChecks(rawChecks) {
  const parts = rawChecks.split(',')
  if (parts.some((part) => part.trim() === '')) {
    fail(`${repo}:${head} -> ${base}: invalid required_checks '${rawChecks}'`)
  }
  const requiredChecks = parts.map((part) => part.trim())
  const duplicates = [...new Set(requiredChecks.filter((name, index) => requiredChecks.indexOf(name) !== index))]
  if (duplicates.length > 0) {
    fail(`${repo}:${head} -> ${base}: duplicate required_checks entries: ${duplicates.join(',')}`)
  }
  const invalid = requiredChecks.filter((name) => /[\u0000-\u001f\u007f]/.test(name))
  if (invalid.length > 0) {
    fail(`${repo}:${head} -> ${base}: required_checks contains control characters`)
  }
  return requiredChecks
}

const requiredChecks = parseRequiredChecks(requiredChecksRaw)

let prs
try {
  prs = JSON.parse(rawPrs)
} catch (error) {
  fail(`${repo}:${head} -> ${base}: gh returned invalid JSON: ${error.message}`)
}
if (!Array.isArray(prs)) {
  fail(`${repo}:${head} -> ${base}: gh returned a non-array PR payload`)
}
if (prs.length === 0) {
  fail(`${repo}:${head} -> ${base}: no pull request found`)
}

let refs
try {
  refs = JSON.parse(rawRefs)
} catch (error) {
  fail(`${repo}:${head} -> ${base}: gh returned invalid branch-ref JSON: ${error.message}`)
}
if (!Array.isArray(refs)) {
  fail(`${repo}:${head} -> ${base}: gh returned a non-array branch-ref payload`)
}

function currentHeadBranchOid() {
  const exactRef = `refs/heads/${head}`
  const matches = refs.filter((ref) => ref && ref.ref === exactRef)
  if (matches.length === 0) return null
  if (matches.length > 1) {
    fail(`${repo}:${head} -> ${base}: duplicate current branch refs returned for ${exactRef}`)
  }
  const oid = matches[0].object && matches[0].object.sha
  if (typeof oid !== 'string' || !/^[0-9a-f]{40}$/i.test(oid)) {
    fail(`${repo}:${head} -> ${base}: current branch ref ${exactRef} is missing a valid object sha`)
  }
  return oid
}

const currentHeadOid = currentHeadBranchOid()
const SUCCESSFUL_STATUS_STATES = new Set(['SUCCESS'])
const REQUIRED_CHECK_RUN_SUCCESS_CONCLUSION = 'SUCCESS'

function checkTimestampMs(check) {
  for (const field of ['completedAt', 'startedAt']) {
    if (typeof check[field] !== 'string' || check[field].trim() === '') continue
    if (check[field] === '0001-01-01T00:00:00Z') continue
    const parsed = Date.parse(check[field])
    if (Number.isFinite(parsed)) return parsed
  }
  return null
}

function checkName(check) {
  if (typeof check.name === 'string' && check.name.trim() !== '') return check.name
  if (typeof check.context === 'string' && check.context.trim() !== '') return check.context
  return 'unnamed'
}

function checkSummary(check) {
  const name = checkName(check)
  const timestampMs = checkTimestampMs(check)
  if (Object.prototype.hasOwnProperty.call(check, 'state')) {
    const state = String(check.state || '').toUpperCase()
    return {
      name,
      ok: SUCCESSFUL_STATUS_STATES.has(state),
      summary: `${name}:STATUS/${state || 'PENDING'}`,
      timestampMs
    }
  }
  const status = String(check.status || '').toUpperCase()
  const conclusion = String(check.conclusion || '').toUpperCase()
  return {
    name,
    ok: status === 'COMPLETED' && conclusion === REQUIRED_CHECK_RUN_SUCCESS_CONCLUSION,
    summary: `${name}:${status || 'UNKNOWN'}/${conclusion || 'PENDING'}`,
    timestampMs
  }
}

function selectLatestRequiredCheck(name, matches) {
  if (matches.length === 0) return { missing: name }
  if (matches.length === 1) return { selected: matches[0] }
  const timedMatches = matches.filter((entry) => Number.isFinite(entry.timestampMs))
  if (timedMatches.length !== matches.length) return { duplicate: name }
  const latestTimestamp = Math.max(...timedMatches.map((entry) => entry.timestampMs))
  const latestMatches = timedMatches.filter((entry) => entry.timestampMs === latestTimestamp)
  if (latestMatches.length !== 1) return { duplicate: name }
  return { selected: latestMatches[0] }
}

function requiredCheckFailureParts(pr) {
  if (!Array.isArray(pr.statusCheckRollup)) {
    return [`malformedChecks=statusCheckRollup is not an array`, `missingRequiredChecks=${requiredChecks.join(',')}`]
  }
  const entries = pr.statusCheckRollup.map(checkSummary)
  const byName = new Map()
  for (const entry of entries) {
    const bucket = byName.get(entry.name) || []
    bucket.push(entry)
    byName.set(entry.name, bucket)
  }
  const parts = []
  const incomplete = []
  const missing = []
  const duplicate = []
  for (const name of requiredChecks) {
    const selectedCheck = selectLatestRequiredCheck(name, byName.get(name) || [])
    if (selectedCheck.missing) {
      missing.push(selectedCheck.missing)
    } else if (selectedCheck.duplicate) {
      duplicate.push(selectedCheck.duplicate)
    } else if (selectedCheck.selected && !selectedCheck.selected.ok) {
      incomplete.push(selectedCheck.selected.summary)
    }
  }
  if (missing.length > 0) parts.push(`missingRequiredChecks=${missing.join(',')}`)
  if (duplicate.length > 0) parts.push(`duplicateRequiredChecks=${duplicate.join(',')}`)
  if (incomplete.length > 0) parts.push(`incompleteRequiredChecks=${incomplete.join(',')}`)
  return parts
}

function reviewThreadFailureParts(rawThreads) {
  let payload
  try {
    payload = JSON.parse(rawThreads)
  } catch (error) {
    return [`reviewThreadsQuery=malformed:${error.message}`]
  }
  if (payload && typeof payload.queryError === 'string') {
    return [`reviewThreadsQuery=failed:${payload.queryError.replace(/\s+/g, ' ').trim() || 'unknown'}`]
  }
  const reviewThreads = payload && payload.data && payload.data.repository && payload.data.repository.pullRequest && payload.data.repository.pullRequest.reviewThreads
  if (!reviewThreads || !Array.isArray(reviewThreads.nodes)) {
    return ['reviewThreadsQuery=malformed:missing reviewThreads.nodes']
  }

  let unresolved = 0
  let current = 0
  let outdated = 0
  let malformed = 0
  const refs = []
  for (const thread of reviewThreads.nodes) {
    if (!thread || typeof thread.isResolved !== 'boolean' || typeof thread.isOutdated !== 'boolean') {
      malformed += 1
      continue
    }
    if (thread.isResolved) continue
    unresolved += 1
    if (thread.isOutdated) outdated += 1
    else current += 1
    if (refs.length < 5) {
      const status = thread.isOutdated ? 'outdated' : 'current'
      const path = typeof thread.path === 'string' && thread.path.trim() !== '' ? thread.path.trim() : 'unknown-path'
      const line = Number.isInteger(thread.line) ? thread.line : (Number.isInteger(thread.originalLine) ? thread.originalLine : 'unknown-line')
      refs.push(`${status}:${path}:${line}`)
    }
  }

  const hasNextPage = Boolean(reviewThreads.pageInfo && reviewThreads.pageInfo.hasNextPage)
  const parts = []
  if (hasNextPage) parts.push('unresolvedReviewThreads=paginated')
  if (malformed > 0) parts.push(`malformedReviewThreads=${malformed}`)
  if (unresolved > 0) {
    parts.push(`unresolvedReviewThreads=${unresolved}`)
    parts.push(`currentUnresolvedReviewThreads=${current}`)
    parts.push(`outdatedUnresolvedReviewThreads=${outdated}`)
    parts.push('reviewConversationResolutionRequired=true')
    if (refs.length > 0) parts.push(`unresolvedReviewThreadRefs=${refs.join(';')}`)
  }
  return parts
}

function reviewApprovalFailureParts(pr) {
  if (pr.reviewDecision === 'APPROVED') return []

  const parts = ['eligibleReviewerApprovalRequired=true']
  if (!Object.prototype.hasOwnProperty.call(pr, 'reviews')) {
    parts.push('reviewDetails=unavailable')
    return parts
  }
  if (!Array.isArray(pr.reviews)) {
    parts.push('reviewDetails=malformed')
    return parts
  }

  const approvals = pr.reviews.filter((review) => review && review.state === 'APPROVED')
  const headOid = typeof pr.headRefOid === 'string' && /^[0-9a-f]{40}$/i.test(pr.headRefOid.trim())
    ? pr.headRefOid.trim().toLowerCase()
    : ''
  const currentHeadApprovals = approvals.filter((review) => {
    const oid = review && review.commit && typeof review.commit.oid === 'string' ? review.commit.oid.trim().toLowerCase() : ''
    return headOid !== '' && oid === headOid
  })
  const staleApprovals = approvals.filter((review) => {
    const oid = review && review.commit && typeof review.commit.oid === 'string' ? review.commit.oid.trim().toLowerCase() : ''
    return oid !== '' && headOid !== '' && oid !== headOid
  })

  parts.push(`approvalCount=${approvals.length}`)
  parts.push(`currentHeadApprovalCount=${currentHeadApprovals.length}`)
  if (staleApprovals.length > 0) parts.push(`staleApprovalCount=${staleApprovals.length}`)

  const latestApproval = approvals
    .slice()
    .sort((a, b) => Date.parse(a.submittedAt || '') - Date.parse(b.submittedAt || ''))
    .pop()
  const latestApprovalCommit = latestApproval && latestApproval.commit && typeof latestApproval.commit.oid === 'string'
    ? latestApproval.commit.oid.trim()
    : ''
  if (latestApprovalCommit !== '') parts.push(`latestApprovalCommit=${latestApprovalCommit}`)

  if (approvals.length > 0 && currentHeadApprovals.length > 0) {
    parts.push('currentApprovalNotEligible=true')
  } else if (approvals.length > 0 && currentHeadApprovals.length === 0) {
    parts.push('freshApprovalRequired=true')
  }

  return parts
}

function validPrHeadOid(pr) {
  const oid = typeof pr.headRefOid === 'string' ? pr.headRefOid.trim() : ''
  if (!/^[0-9a-f]{40}$/i.test(oid)) {
    fail(`${repo}#${pr.number}: headRefOid is missing or invalid`)
  }
  return oid
}

const openPrs = prs.filter((pr) => pr && pr.state === 'OPEN')
if (openPrs.length > 1) {
  fail(`${repo}:${head} -> ${base}: multiple open pull requests found`)
}

if (openPrs.length === 1) {
  const pr = openPrs[0]
  const number = Number(pr.number)
  if (!Number.isInteger(number) || number <= 0) {
    fail(`${repo}:${head} -> ${base}: open pull request is missing a valid number`)
  }
  const url = typeof pr.url === 'string' && pr.url.trim() !== '' ? pr.url.trim() : `${repo}#${number}`
  const prHeadOid = validPrHeadOid(pr)
  const parts = []
  if (pr.isDraft === true) parts.push('isDraft=true')
  if (pr.reviewDecision !== 'APPROVED') parts.push(`reviewDecision=${pr.reviewDecision || 'UNKNOWN'}`)
  if (pr.mergeStateStatus !== 'CLEAN') parts.push(`mergeStateStatus=${pr.mergeStateStatus || 'UNKNOWN'}`)
  parts.push(...reviewApprovalFailureParts(pr))
  if (!currentHeadOid) {
    parts.push(`current branch ref refs/heads/${head} is missing`)
  } else if (currentHeadOid.toLowerCase() !== prHeadOid.toLowerCase()) {
    parts.push(`head branch moved after PR query currentHeadOid=${currentHeadOid} headRefOid=${prHeadOid}`)
  }
  parts.push(...requiredCheckFailureParts(pr))
  parts.push(...reviewThreadFailureParts(rawReviewThreads))

  if (parts.length > 0) {
    fail(`${repo}#${number} is not safe to merge: ${url} ${parts.join(' ')}`)
  }

  console.log(['candidate', repo, String(number), url, head, base, prHeadOid, requiredChecks.join(',')].join('\t'))
  process.exit(0)
}

const merged = prs.find((pr) => pr && (pr.state === 'MERGED' || pr.mergedAt))
if (merged) {
  const number = Number(merged.number)
  const url = typeof merged.url === 'string' && merged.url.trim() !== '' ? merged.url.trim() : `${repo}#${number || 'merged'}`
  const mergedHeadOid = validPrHeadOid(merged)
  if (currentHeadOid && currentHeadOid.toLowerCase() !== mergedHeadOid.toLowerCase()) {
    fail(`${repo}#${number}: already merged but branch '${head}' has new commits after merge: ${url} currentHeadOid=${currentHeadOid} mergedHeadRefOid=${mergedHeadOid}`)
  }
  const checkFailures = requiredCheckFailureParts(merged)
  if (checkFailures.length > 0) {
    fail(`${repo}#${number}: already merged but required checks are not release-ready: ${url} ${checkFailures.join(' ')}`)
  }
  console.log(['merged', repo, String(number), url, head, base, mergedHeadOid, requiredChecks.join(',')].join('\t'))
  process.exit(0)
}

const closed = prs.find((pr) => pr && pr.state === 'CLOSED')
if (closed) {
  fail(`${repo}#${closed.number}: closed without merge: ${closed.url || ''}`)
}

fail(`${repo}:${head} -> ${base}: no open or merged pull request found`)
NODE
)"
  node_status=$?
  set -e

  if [[ "$node_status" -ne 0 ]]; then
    if [[ -n "$node_output" ]]; then
      record_failure "$node_output"
    else
      record_failure "$repo:$head -> $base: unable to evaluate release PR merge readiness"
    fi
    continue
  fi

  if [[ -z "$node_output" ]]; then
    record_failure "$repo:$head -> $base: merge-readiness evaluator returned empty output"
    continue
  fi

  IFS=$'\t' read -r row_type row_repo row_number row_url row_head row_base row_sha row_checks <<< "$node_output"
  case "$row_type" in
    candidate)
      if ! verify_authoritative_open_candidate "$row_repo" "$row_head" "$row_base" "$row_number" "$row_sha"; then
        record_failure "$row_repo#$row_number at $row_sha failed authoritative protected-merge preflight"
        continue
      fi
      candidate_count=$((candidate_count + 1))
      printf '%s\n' "$node_output" >> "$candidates_tsv"
      log "Ready to merge authoritative reviewed candidate $row_repo#$row_number head=$row_sha base=$row_base checks=$row_checks"
      ;;
    merged)
      already_merged_count=$((already_merged_count + 1))
      log "Already merged $row_repo#$row_number head=$row_sha base=$row_base"
      ;;
    *)
      record_failure "$repo:$head -> $base: merge-readiness evaluator returned unknown row type '$row_type'"
      ;;
  esac
done < "$CONFIG_FILE"

if [[ "$checked_count" -eq 0 ]]; then
  record_failure "$CONFIG_FILE: no release PR requirements were found"
fi

if ((${#failures[@]} > 0)); then
  echo "[release-pr-merge][error] Release PR merge handoff failed:" >&2
  printf '  - %s\n' "${failures[@]}" >&2
  exit 1
fi

if [[ "$candidate_count" -eq 0 ]]; then
  log "No open release PRs are ready to merge. Already merged: $already_merged_count. Checked: $checked_count."
  exit 0
fi

if [[ "$MODE" == "dry-run" ]]; then
  log "Dry run: $candidate_count release PR(s) are ready to merge with method '$MERGE_METHOD'."
  while IFS=$'\t' read -r row_type repo number url head base sha checks; do
    log "Would merge $repo#$number ($head -> $base) at $sha with checks $checks: $url"
  done < "$candidates_tsv"
  log "Rerun with --apply and RELEASE_PR_MERGE_CONFIRM=merge-release-prs to merge without admin bypass."
  exit 0
fi

if [[ "${RELEASE_PR_MERGE_CONFIRM:-}" != "merge-release-prs" ]]; then
  fail "--apply requires RELEASE_PR_MERGE_CONFIRM=merge-release-prs"
fi

log "Applying protected-branch merge for $candidate_count release PR(s) with method '$MERGE_METHOD'."
while IFS=$'\t' read -r row_type repo number url head base sha checks; do
  if ! verify_authoritative_open_candidate "$repo" "$head" "$base" "$number" "$sha"; then
    fail "authoritative protected-merge preflight changed before apply for $repo#$number at $sha"
  fi
  if ! "$GH_BIN" pr merge "$number" \
    --repo "$repo" \
    "$merge_flag" \
    --match-head-commit "$sha"; then
    fail "GitHub failed to merge $repo#$number at $sha"
  fi
  log "Merged $repo#$number ($head -> $base) at $sha: $url"
done < "$candidates_tsv"

log "Finished merging release PRs. Rerun bash scripts/audit-release-pr-readiness.sh."
