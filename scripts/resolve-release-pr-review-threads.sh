#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="${RELEASE_PR_RESOLVER_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
AUDIT_SCRIPT="${RELEASE_PR_RESOLVER_AUDIT_SCRIPT:-$ROOT_DIR/scripts/audit-release-pr-readiness.sh}"
GH_BIN="${GH_BIN:-gh}"
MODE="dry-run"
AUDIT_LOG=""

usage() {
  cat <<'USAGE'
Usage: scripts/resolve-release-pr-review-threads.sh [--dry-run|--apply] [--audit-log FILE]

Safely prepares or applies GitHub review-thread resolution for release PRs whose
only unresolved review conversations are outdated threads already reported by
scripts/audit-release-pr-readiness.sh.

Default mode is --dry-run. --apply performs GitHub GraphQL resolveReviewThread
mutations and also requires:

  RELEASE_PR_THREAD_RESOLUTION_CONFIRM=resolve-outdated-review-threads

The script refuses to apply when any current unresolved review thread remains,
when the audit output is paginated, when thread IDs are missing, or when the
unresolved/outdated counts do not match the listed thread IDs.

Environment:
  RELEASE_PR_RESOLVER_ROOT          Workspace root.
  RELEASE_PR_RESOLVER_AUDIT_SCRIPT Override release PR readiness audit script.
  RELEASE_PR_THREAD_RESOLUTION_CONFIRM
  GH_BIN                            GitHub CLI executable.
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
    --audit-log)
      AUDIT_LOG="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "[release-pr-thread-resolver][error] Unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

log() { echo "[release-pr-thread-resolver] $*"; }
fail() {
  echo "[release-pr-thread-resolver][error] $*" >&2
  exit 1
}

tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

if [[ -n "$AUDIT_LOG" ]]; then
  [[ -f "$AUDIT_LOG" ]] || fail "Audit log not found: $AUDIT_LOG"
  audit_log="$AUDIT_LOG"
else
  [[ -x "$AUDIT_SCRIPT" ]] || fail "Release PR readiness audit is not executable: $AUDIT_SCRIPT"
  audit_log="$tmp_dir/release-pr-readiness.log"
  set +e
  "$AUDIT_SCRIPT" >"$audit_log" 2>&1
  audit_status=$?
  set -e
  if [[ "$audit_status" -eq 0 ]]; then
    log "Release PR readiness already passes; no review threads to resolve."
    exit 0
  fi
fi

threads_tsv="$tmp_dir/review-threads.tsv"
if ! node - "$audit_log" >"$threads_tsv" <<'NODE'
const fs = require('fs')

const auditLogPath = process.argv[2]
const lines = fs.readFileSync(auditLogPath, 'utf8').split(/\r?\n/)
const records = []
const seenThreadIds = new Set()
const errors = []

function field(line, name) {
  const match = line.match(new RegExp(`${name}=([^\\s]+)`))
  return match ? match[1] : null
}

function numberField(line, name) {
  const raw = field(line, name)
  if (!raw) return null
  const match = raw.match(/^(\d+)(\+?)$/)
  if (!match) return { invalid: raw }
  return { value: Number(match[1]), paginated: match[2] === '+' }
}

for (const line of lines) {
  if (!line.includes('open and is not release-ready')) continue

  const prMatch = line.match(/([A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+)#([0-9]+) is open/)
  if (!prMatch) continue

  const repo = prMatch[1]
  const pr = prMatch[2]
  const label = `${repo}#${pr}`

  if (line.includes('reviewThreadsQuery=')) {
    errors.push(`${label}: review-thread query did not return complete thread data`)
    continue
  }

  if (line.includes('malformedReviewThreads=')) {
    errors.push(`${label}: review-thread payload contained malformed unresolved thread data`)
    continue
  }

  const unresolved = numberField(line, 'unresolvedReviewThreads')
  const current = numberField(line, 'currentUnresolvedReviewThreads')
  const outdated = numberField(line, 'outdatedUnresolvedReviewThreads')

  if (!unresolved || unresolved.invalid || !current || current.invalid || !outdated || outdated.invalid) {
    continue
  }
  if (unresolved.value === 0) {
    continue
  }
  if (unresolved.paginated) {
    errors.push(`${label}: unresolved review-thread output is paginated; rerun the audit with complete thread coverage before resolving`)
    continue
  }
  if (current.value !== 0) {
    errors.push(`${label}: currentUnresolvedReviewThreads=${current.value}; refusing to resolve active review feedback`)
    continue
  }
  if (outdated.value !== unresolved.value) {
    errors.push(`${label}: unresolvedReviewThreads=${unresolved.value} but outdatedUnresolvedReviewThreads=${outdated.value}; refusing mixed thread state`)
    continue
  }

  const rawIds = field(line, 'unresolvedReviewThreadIds')
  if (!rawIds) {
    errors.push(`${label}: unresolved review-thread IDs are missing`)
    continue
  }

  const ids = rawIds.split(',').filter(Boolean)
  if (ids.includes('more')) {
    errors.push(`${label}: unresolved review-thread IDs are truncated; rerun the audit with complete thread coverage before resolving`)
    continue
  }
  if (ids.length !== unresolved.value) {
    errors.push(`${label}: unresolvedReviewThreads=${unresolved.value} but unresolvedReviewThreadIds has ${ids.length} ID(s)`)
    continue
  }

  const refs = field(line, 'unresolvedReviewThreadRefs') || ''
  for (const id of ids) {
    if (!/^PRRT_[A-Za-z0-9_-]+$/.test(id)) {
      errors.push(`${label}: malformed review-thread ID '${id}'`)
      continue
    }
    if (seenThreadIds.has(id)) {
      continue
    }
    seenThreadIds.add(id)
    records.push({ repo, pr, id, refs })
  }
}

if (errors.length > 0) {
  for (const error of errors) {
    console.error(`[release-pr-thread-resolver][error] ${error}`)
  }
  process.exit(1)
}

for (const record of records) {
  console.log([record.repo, record.pr, record.id, record.refs].join('\t'))
}
NODE
then
  exit 1
fi

if [[ ! -s "$threads_tsv" ]]; then
  log "No eligible outdated review-thread IDs found in $audit_log."
  exit 0
fi

thread_count="$(wc -l < "$threads_tsv" | tr -d '[:space:]')"

if [[ "$MODE" == "dry-run" ]]; then
  log "Dry run: $thread_count outdated review thread(s) are eligible for resolution."
  while IFS=$'\t' read -r repo pr thread_id refs; do
    log "Would resolve $repo#$pr review thread $thread_id${refs:+ ($refs)}"
  done < "$threads_tsv"
  log "Rerun with --apply and RELEASE_PR_THREAD_RESOLUTION_CONFIRM=resolve-outdated-review-threads to mutate GitHub."
  exit 0
fi

if [[ "${RELEASE_PR_THREAD_RESOLUTION_CONFIRM:-}" != "resolve-outdated-review-threads" ]]; then
  fail "--apply requires RELEASE_PR_THREAD_RESOLUTION_CONFIRM=resolve-outdated-review-threads"
fi

if ! command -v "$GH_BIN" >/dev/null 2>&1; then
  fail "gh CLI not found. Install GitHub CLI or set GH_BIN."
fi

log "Applying resolution for $thread_count outdated review thread(s)."
while IFS=$'\t' read -r repo pr thread_id refs; do
  response_file="$tmp_dir/resolve-$thread_id.json"
  if ! "$GH_BIN" api graphql \
    -F "threadId=$thread_id" \
    -f query='mutation($threadId: ID!) {
      resolveReviewThread(input: { threadId: $threadId }) {
        thread {
          id
          isResolved
        }
      }
    }' >"$response_file"; then
    fail "GitHub failed to resolve $repo#$pr review thread $thread_id"
  fi

  node - "$thread_id" "$response_file" <<'NODE'
const fs = require('fs')
const expected = process.argv[2]
const file = process.argv[3]
let payload
try {
  payload = JSON.parse(fs.readFileSync(file, 'utf8'))
} catch (error) {
  console.error(`[release-pr-thread-resolver][error] GitHub returned invalid JSON for ${expected}: ${error.message}`)
  process.exit(1)
}
const thread = payload && payload.data && payload.data.resolveReviewThread && payload.data.resolveReviewThread.thread
if (!thread || thread.id !== expected || thread.isResolved !== true) {
  console.error(`[release-pr-thread-resolver][error] GitHub did not confirm ${expected} was resolved`)
  process.exit(1)
}
NODE
  log "Resolved $repo#$pr review thread $thread_id${refs:+ ($refs)}"
done < "$threads_tsv"

log "Finished resolving outdated review threads. Rerun bash scripts/audit-release-pr-readiness.sh."
