#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="${RELEASE_PR_READINESS_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
CONFIG_FILE="${RELEASE_PR_READINESS_CONFIG:-$ROOT_DIR/config/release-readiness-prs.tsv}"
GH_BIN="${GH_BIN:-gh}"
REPORT_FILE="${RELEASE_PR_READINESS_REPORT:-}"

usage() {
  cat <<'USAGE'
Usage: scripts/audit-release-pr-readiness.sh [--config FILE] [--write-report FILE]

Checks the implementation PRs that must be merged before the Fearless release can
be considered ready. The input is a tab-separated file:

  repo<TAB>head<TAB>base<TAB>required_state<TAB>required_checks

Only required_state=merged is currently supported.
required_checks is a comma-separated list of exact GitHub check/status context
names that must be present and successful on the release PR head.
Every requirement must also have one immutable evidence line in the same file:

  # reviewed_pr_pin<TAB>repo<TAB>head<TAB>base<TAB>pr_number<TAB>head_sha

The reviewed pull request number and exact 40-character lowercase head commit are
mandatory even when the remote topic branch has already been deleted.

If GitHub reports a required check name more than once, that requirement must
also pin the GitHub Actions workflow allowed to emit the duplicate rows:

  # duplicate_check_provenance_pin<TAB>repo<TAB>head<TAB>base<TAB>check_name<TAB>app_id<TAB>app_slug<TAB>workflow_id<TAB>workflow_path

Duplicate rows are accepted only when every row is bound to the reviewed head
SHA, emitted by the pinned GitHub Actions app/workflow, and has complete
check-suite and Actions-run provenance. Outcomes are evaluated only for
pull_request runs whose Actions head branch exactly matches the configured PR
head. Same-SHA runs from another branch or from a post-merge push cannot satisfy
or invalidate that PR; at least one exact-head pull_request run must exist.

Environment:
  RELEASE_PR_READINESS_ROOT    Workspace root.
  RELEASE_PR_READINESS_CONFIG  Override config path.
  RELEASE_PR_READINESS_REPORT  Write a machine-readable JSON report.
  GH_BIN                       GitHub CLI executable.
USAGE
}

while (($#)); do
  case "$1" in
    --config)
      CONFIG_FILE="$2"
      shift 2
      ;;
    --write-report)
      REPORT_FILE="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "[release-pr-readiness][error] Unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

log() { echo "[release-pr-readiness] $*"; }
warn() { echo "[release-pr-readiness][warn] $*" >&2; }

failures=()
report_records_file=""

cleanup_report() {
  if [[ -n "$report_records_file" && -f "$report_records_file" ]]; then
    rm -f "$report_records_file"
  fi
}
trap cleanup_report EXIT

record_failure() {
  failures+=("$1")
  warn "$1"
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

init_report() {
  [[ -n "$REPORT_FILE" ]] || return 0
  report_records_file="$(mktemp)"
  : > "$report_records_file"
}

append_report_record() {
  [[ -n "$REPORT_FILE" ]] || return 0
  local status="$1"
  local config_line="$2"
  local repo="$3"
  local head="$4"
  local base="$5"
  local required_state="$6"
  local required_checks="$7"
  local message="$8"

  node - "$status" "$config_line" "$repo" "$head" "$base" "$required_state" "$required_checks" "$message" >> "$report_records_file" <<'NODE'
const [status, configLineRaw, repo, head, base, requiredState, requiredChecksRaw, message] = process.argv.slice(2)
const configLine = Number(configLineRaw)
const requiredChecks = requiredChecksRaw
  .split(',')
  .map((part) => part.trim())
  .filter(Boolean)
const record = {
  status,
  configLine: Number.isInteger(configLine) ? configLine : null,
  repo,
  head,
  base,
  requiredState,
  requiredChecks,
  message,
}

const prMatch = message.match(/([A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+)#([0-9]+).*?(https:\/\/github\.com\/[^\s]+)/)
if (prMatch) {
  record.pr = {
    repo: prMatch[1],
    number: Number(prMatch[2]),
    url: prMatch[3],
  }
}

for (const field of [
  'isDraft',
  'reviewDecision',
  'mergeStateStatus',
  'eligibleReviewerApprovalRequired',
  'reviewDetails',
  'approvalCount',
  'currentHeadApprovalCount',
  'staleApprovalCount',
  'latestApprovalCommit',
  'currentApprovalNotEligible',
  'freshApprovalRequired',
  'unresolvedReviewThreads',
  'currentUnresolvedReviewThreads',
  'outdatedUnresolvedReviewThreads',
]) {
  const match = message.match(new RegExp(`${field}=([^\\s]+)`))
  if (!match) continue
  const raw = match[1]
  if (/^(true|false)$/.test(raw)) {
    record[field] = raw === 'true'
  } else if (/^[0-9]+$/.test(raw)) {
    record[field] = Number(raw)
  } else {
    record[field] = raw
  }
}

console.log(JSON.stringify(record))
NODE
}

write_report() {
  [[ -n "$REPORT_FILE" ]] || return 0
  local status="$1"

  mkdir -p "$(dirname "$REPORT_FILE")"
  node - "$REPORT_FILE" "$CONFIG_FILE" "$status" "$checked_count" "$report_records_file" <<'NODE'
const fs = require('fs')
const path = require('path')

const [reportFile, configFile, status, checkedCountRaw, recordsFile] = process.argv.slice(2)
const checkedCount = Number(checkedCountRaw)
const records = fs.existsSync(recordsFile)
  ? fs.readFileSync(recordsFile, 'utf8')
    .split(/\r?\n/)
    .filter(Boolean)
    .map((line) => JSON.parse(line))
  : []
const totals = {
  passed: records.filter((record) => record.status === 'passed').length,
  failed: records.filter((record) => record.status === 'failed').length,
  total: records.length,
}
const report = {
  schemaVersion: 1,
  generatedAt: new Date().toISOString(),
  configFile: path.resolve(configFile),
  status,
  checkedCount: Number.isFinite(checkedCount) ? checkedCount : 0,
  totals,
  failures: records.filter((record) => record.status === 'failed').map((record) => record.message),
  requirements: records,
}

fs.writeFileSync(reportFile, JSON.stringify(report, null, 2) + '\n')
NODE
}

extract_open_pr_number() {
  local raw="$1"
  local reviewed_pr_number="$2"
  node - "$raw" "$reviewed_pr_number" <<'NODE'
const raw = process.argv[2] || ''
const reviewedPrNumber = Number(process.argv[3])
try {
  const prs = JSON.parse(raw)
  if (!Array.isArray(prs)) process.exit(0)
  const open = prs.find((pr) => pr && pr.state === 'OPEN' && Number(pr.number) === reviewedPrNumber)
  if (!open) process.exit(0)
  const number = Number(open.number)
  if (Number.isInteger(number) && number > 0) {
    console.log(String(number))
  }
} catch (_) {
  process.exit(0)
}
NODE
}

load_review_pins() {
  node - "$CONFIG_FILE" <<'NODE'
const fs = require('fs')
const file = process.argv[2]
const lines = fs.readFileSync(file, 'utf8').split(/\r?\n/)
const requirements = []
const pins = new Map()

function fail(message) {
  console.error(message)
  process.exit(1)
}

function key(repo, head, base) {
  return `${repo}\0${head}\0${base}`
}

for (const [index, line] of lines.entries()) {
  const lineNumber = index + 1
  if (!line || /^\s*$/.test(line)) continue
  if (line.startsWith('# reviewed_pr_pin\t')) {
    const fields = line.split('\t')
    if (
      fields.length === 6 &&
      fields[1] === 'repo' &&
      fields[2] === 'head' &&
      fields[3] === 'base' &&
      fields[4] === 'reviewed_pr_number' &&
      fields[5] === 'reviewed_head_sha'
    ) {
      continue
    }
    if (fields.length !== 6 || fields.some((field) => field.trim() !== field || field === '')) {
      fail(`${file}:${lineNumber}: invalid reviewed PR pin evidence line`)
    }
    const [, repo, head, base, prNumberRaw, headSha] = fields
    if (!/^[1-9][0-9]*$/.test(prNumberRaw) || !Number.isSafeInteger(Number(prNumberRaw))) {
      fail(`${file}:${lineNumber}: reviewed PR pin number must be canonical positive digits`)
    }
    if (!/^[0-9a-f]{40}$/.test(headSha)) {
      fail(`${file}:${lineNumber}: reviewed PR head pin must be an exact lowercase 40-character commit SHA`)
    }
    const identity = key(repo, head, base)
    if (pins.has(identity)) {
      fail(`${file}:${lineNumber}: duplicate reviewed PR pin for ${repo}:${head} -> ${base}`)
    }
    pins.set(identity, {
      repo,
      head,
      base,
      reviewedPrNumber: Number(prNumberRaw),
      reviewedHeadSha: headSha,
      configLine: lineNumber,
    })
    continue
  }
  if (/^\s*#/.test(line)) continue
  const fields = line.split('\t')
  if (fields.length === 5) {
    requirements.push({ repo: fields[0], head: fields[1], base: fields[2], configLine: lineNumber })
  }
}

for (const requirement of requirements) {
  const identity = key(requirement.repo, requirement.head, requirement.base)
  if (!pins.has(identity)) {
    fail(`${file}:${requirement.configLine}: missing immutable reviewed PR number/head commit pin for ${requirement.repo}:${requirement.head} -> ${requirement.base}`)
  }
}

const requirementKeys = new Set(requirements.map((requirement) => key(requirement.repo, requirement.head, requirement.base)))
for (const [identity, pin] of pins) {
  if (!requirementKeys.has(identity)) {
    fail(`${file}:${pin.configLine}: reviewed PR pin has no matching release PR requirement for ${pin.repo}:${pin.head} -> ${pin.base}`)
  }
}

console.log(JSON.stringify([...pins.values()]))
NODE
}

review_pin_for_requirement() {
  local raw_pins="$1"
  local repo="$2"
  local head="$3"
  local base="$4"
  node - "$raw_pins" "$repo" "$head" "$base" <<'NODE'
const [raw, repo, head, base] = process.argv.slice(2)
const pins = JSON.parse(raw)
const matches = pins.filter((pin) => pin.repo === repo && pin.head === head && pin.base === base)
if (matches.length !== 1) process.exit(1)
console.log(`${matches[0].reviewedPrNumber}\t${matches[0].reviewedHeadSha}`)
NODE
}

load_duplicate_check_provenance_pins() {
  node - "$CONFIG_FILE" <<'NODE'
const fs = require('fs')
const file = process.argv[2]
const lines = fs.readFileSync(file, 'utf8').split(/\r?\n/)
const requirements = []
const pins = new Map()

function fail(message) {
  console.error(message)
  process.exit(1)
}

function requirementKey(repo, head, base) {
  return `${repo}\0${head}\0${base}`
}

function pinKey(repo, head, base, checkName) {
  return `${requirementKey(repo, head, base)}\0${checkName}`
}

function validWorkflowPath(value) {
  if (!/^\.github\/workflows\/[A-Za-z0-9][A-Za-z0-9._-]*\.ya?ml$/.test(value)) return false
  if (value.includes('//') || value.includes('\\')) return false
  const segments = value.split('/')
  return !segments.some((segment) => segment === '.' || segment === '..')
}

for (const [index, line] of lines.entries()) {
  const lineNumber = index + 1
  if (!line || /^\s*$/.test(line)) continue
  if (line.startsWith('# duplicate_check_provenance_pin\t')) {
    const fields = line.split('\t')
    if (
      fields.length === 9 &&
      fields[1] === 'repo' &&
      fields[2] === 'head' &&
      fields[3] === 'base' &&
      fields[4] === 'check_name' &&
      fields[5] === 'app_id' &&
      fields[6] === 'app_slug' &&
      fields[7] === 'workflow_id' &&
      fields[8] === 'workflow_path'
    ) {
      continue
    }
    if (fields.length !== 9 || fields.some((field) => field.trim() !== field || field === '')) {
      fail(`${file}:${lineNumber}: invalid duplicate required-check provenance pin`)
    }
    const [, repo, head, base, checkName, appIdRaw, appSlug, workflowIdRaw, workflowPath] = fields
    if (!/^[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+$/.test(repo)) {
      fail(`${file}:${lineNumber}: duplicate required-check provenance pin has invalid repo`)
    }
    if (!/^[A-Za-z0-9][A-Za-z0-9._/-]*$/.test(head) || !/^[A-Za-z0-9][A-Za-z0-9._/-]*$/.test(base)) {
      fail(`${file}:${lineNumber}: duplicate required-check provenance pin has invalid branch ref`)
    }
    if (/[\u0000-\u001f\u007f]/.test(checkName)) {
      fail(`${file}:${lineNumber}: duplicate required-check provenance pin has invalid check name`)
    }
    if (!/^[1-9][0-9]*$/.test(appIdRaw) || !Number.isSafeInteger(Number(appIdRaw))) {
      fail(`${file}:${lineNumber}: duplicate required-check provenance pin has invalid app id`)
    }
    if (Number(appIdRaw) !== 15368 || appSlug !== 'github-actions') {
      fail(`${file}:${lineNumber}: duplicate required-check provenance pin must use the canonical GitHub Actions app`)
    }
    if (!/^[1-9][0-9]*$/.test(workflowIdRaw) || !Number.isSafeInteger(Number(workflowIdRaw))) {
      fail(`${file}:${lineNumber}: duplicate required-check provenance pin has invalid workflow id`)
    }
    if (!validWorkflowPath(workflowPath)) {
      fail(`${file}:${lineNumber}: duplicate required-check provenance pin has invalid workflow path`)
    }
    const identity = pinKey(repo, head, base, checkName)
    if (pins.has(identity)) {
      fail(`${file}:${lineNumber}: duplicate required-check provenance pin for ${repo}:${head} -> ${base}:${checkName}`)
    }
    pins.set(identity, {
      repo,
      head,
      base,
      checkName,
      appId: Number(appIdRaw),
      appSlug,
      workflowId: Number(workflowIdRaw),
      workflowPath,
      configLine: lineNumber,
    })
    continue
  }
  if (/^\s*#/.test(line)) continue
  const fields = line.split('\t')
  if (fields.length === 5) {
    requirements.push({
      repo: fields[0],
      head: fields[1],
      base: fields[2],
      requiredChecks: fields[4].split(',').map((value) => value.trim()),
      configLine: lineNumber,
    })
  }
}

const requirementsByKey = new Map(requirements.map((requirement) => [
  requirementKey(requirement.repo, requirement.head, requirement.base),
  requirement,
]))
for (const pin of pins.values()) {
  const requirement = requirementsByKey.get(requirementKey(pin.repo, pin.head, pin.base))
  if (!requirement) {
    fail(`${file}:${pin.configLine}: duplicate required-check provenance pin has no matching release PR requirement for ${pin.repo}:${pin.head} -> ${pin.base}`)
  }
  if (!requirement.requiredChecks.includes(pin.checkName)) {
    fail(`${file}:${pin.configLine}: duplicate required-check provenance pin names an unrequired check for ${pin.repo}:${pin.head} -> ${pin.base}:${pin.checkName}`)
  }
}

console.log(JSON.stringify([...pins.values()]))
NODE
}

duplicate_check_provenance_for_requirement() {
  local raw_pins="$1"
  local repo="$2"
  local head="$3"
  local base="$4"
  node - "$raw_pins" "$repo" "$head" "$base" <<'NODE'
const [raw, repo, head, base] = process.argv.slice(2)
const pins = JSON.parse(raw)
console.log(JSON.stringify(pins.filter((pin) => pin.repo === repo && pin.head === head && pin.base === base)))
NODE
}

json_query_error() {
  printf '%s\n' '{"queryError":"GitHub review-thread query failed; response details suppressed"}'
}

pr_list_rest_endpoint() {
  local repo="$1"
  local head="$2"
  local base="$3"
  node - "$repo" "$head" "$base" <<'NODE'
const [repo, head, base] = process.argv.slice(2)
const owner = repo.split('/')[0]
const params = new URLSearchParams({
  head: `${owner}:${head}`,
  base,
  state: 'all',
  per_page: '20'
})
console.log(`repos/${repo}/pulls?${params.toString()}`)
NODE
}

query_pr_list_rest_fallback() {
  local repo="$1"
  local head="$2"
  local base="$3"
  local endpoint pulls_json transformed_json

  endpoint="$(pr_list_rest_endpoint "$repo" "$head" "$base")"
  if ! pulls_json="$("$GH_BIN" api "$endpoint" 2>&1)"; then
    echo "REST pulls query failed (GitHub response details suppressed)" >&2
    return 1
  fi

  if ! transformed_json="$(node - "$pulls_json" 2>&1 <<'NODE'
const raw = process.argv[2]

function fail(message) {
  console.error(message)
  process.exit(1)
}

let pulls
try {
  pulls = JSON.parse(raw)
} catch (error) {
  fail(`REST pulls query returned invalid JSON: ${error.message}`)
}
if (!Array.isArray(pulls)) {
  fail('REST pulls query returned a non-array payload')
}

const result = pulls.map((pr) => {
  const headSha = pr && pr.head && typeof pr.head.sha === 'string' ? pr.head.sha.trim() : ''
  const mergedAt = pr && typeof pr.merged_at === 'string' && pr.merged_at.trim() !== '' ? pr.merged_at : null
  const rawState = pr && typeof pr.state === 'string' ? pr.state.toUpperCase() : 'UNKNOWN'
  const state = mergedAt ? 'MERGED' : rawState
  const mergeState = state === 'MERGED'
    ? 'CLEAN'
    : (typeof pr.mergeable_state === 'string' && pr.mergeable_state.trim() !== '' ? pr.mergeable_state.toUpperCase() : 'UNKNOWN')

  return {
    number: Number(pr && pr.number),
    url: typeof (pr && pr.html_url) === 'string' ? pr.html_url : '',
    state,
    mergedAt,
    headRefOid: headSha,
    isDraft: Boolean(pr && pr.draft === true),
    reviewDecision: state === 'MERGED' ? 'APPROVED' : 'UNKNOWN',
    mergeStateStatus: mergeState
  }
})

console.log(JSON.stringify(result))
NODE
)"; then
    echo "$transformed_json" >&2
    return 1
  fi

  printf '%s\n' "$transformed_json"
}

PINNED_CHECK_RUNS_JSON=""
PINNED_COMMIT_STATUS_JSON=""
PINNED_CHECK_SUITES_JSON="[]"
PINNED_CHECK_WORKFLOWS_JSON="[]"
CHECK_EVIDENCE_ERROR=""

load_pinned_check_evidence() {
  local repo="$1"
  local reviewed_head_sha="$2"
  local required_checks="$3"
  local suite_ids suite_id suite_json duplicate_suite_ids workflow_json

  PINNED_CHECK_RUNS_JSON=""
  PINNED_COMMIT_STATUS_JSON=""
  PINNED_CHECK_SUITES_JSON="[]"
  PINNED_CHECK_WORKFLOWS_JSON="[]"
  CHECK_EVIDENCE_ERROR=""

  if ! PINNED_CHECK_RUNS_JSON="$("$GH_BIN" api "repos/$repo/commits/$reviewed_head_sha/check-runs?filter=latest&per_page=100" 2>&1)"; then
    CHECK_EVIDENCE_ERROR="check-runs request failed; GitHub response details suppressed"
    return 1
  fi
  if ! PINNED_COMMIT_STATUS_JSON="$("$GH_BIN" api "repos/$repo/commits/$reviewed_head_sha/status?per_page=100" 2>&1)"; then
    CHECK_EVIDENCE_ERROR="commit-status request failed; GitHub response details suppressed"
    return 1
  fi

  if ! suite_ids="$(node - "$PINNED_CHECK_RUNS_JSON" "$required_checks" 2>/dev/null <<'NODE'
const raw = process.argv[2]
const required = new Set(process.argv[3].split(',').map((value) => value.trim()).filter(Boolean))
const payload = JSON.parse(raw)
if (!payload || !Array.isArray(payload.check_runs)) process.exit(1)
const ids = new Set()
for (const run of payload.check_runs) {
  if (!run || !required.has(run.name)) continue
  const id = run.check_suite && run.check_suite.id
  if (Number.isSafeInteger(id) && id > 0) ids.add(id)
}
for (const id of [...ids].sort((a, b) => a - b)) console.log(String(id))
NODE
)"; then
    CHECK_EVIDENCE_ERROR="check-runs response was malformed; response details suppressed"
    return 1
  fi

  while IFS= read -r suite_id; do
    [[ -n "$suite_id" ]] || continue
    if ! suite_json="$("$GH_BIN" api "repos/$repo/check-suites/$suite_id" 2>&1)"; then
      CHECK_EVIDENCE_ERROR="check-suite provenance request failed for suite $suite_id; GitHub response details suppressed"
      return 1
    fi
    if ! PINNED_CHECK_SUITES_JSON="$(node - "$PINNED_CHECK_SUITES_JSON" "$suite_id" "$suite_json" 2>/dev/null <<'NODE'
const [rawEntries, suiteIdRaw, rawPayload] = process.argv.slice(2)
const entries = JSON.parse(rawEntries)
entries.push({ requestedId: Number(suiteIdRaw), rawPayload })
console.log(JSON.stringify(entries))
NODE
)"; then
      CHECK_EVIDENCE_ERROR="check-suite provenance response could not be retained safely"
      return 1
    fi
  done <<< "$suite_ids"

  if ! duplicate_suite_ids="$(node - "$PINNED_CHECK_RUNS_JSON" "$PINNED_COMMIT_STATUS_JSON" "$required_checks" 2>/dev/null <<'NODE'
const [rawRuns, rawStatuses, rawRequired] = process.argv.slice(2)
const runs = JSON.parse(rawRuns)
const statuses = JSON.parse(rawStatuses)
const required = new Set(rawRequired.split(',').map((value) => value.trim()).filter(Boolean))
if (!runs || !Array.isArray(runs.check_runs)) process.exit(1)
const statusEntries = statuses && Array.isArray(statuses.statuses) ? statuses.statuses : []
const counts = new Map()
for (const run of runs.check_runs) {
  if (!run || !required.has(run.name)) continue
  counts.set(run.name, (counts.get(run.name) || 0) + 1)
}
for (const status of statusEntries) {
  if (!status || !required.has(status.context)) continue
  counts.set(status.context, (counts.get(status.context) || 0) + 1)
}
const ids = new Set()
for (const run of runs.check_runs) {
  if (!run || !required.has(run.name) || (counts.get(run.name) || 0) < 2) continue
  const id = run.check_suite && run.check_suite.id
  if (Number.isSafeInteger(id) && id > 0) ids.add(id)
}
for (const id of [...ids].sort((a, b) => a - b)) console.log(String(id))
NODE
)"; then
    CHECK_EVIDENCE_ERROR="duplicate check provenance inventory was malformed; response details suppressed"
    return 1
  fi

  while IFS= read -r suite_id; do
    [[ -n "$suite_id" ]] || continue
    if ! workflow_json="$("$GH_BIN" api "repos/$repo/actions/runs?check_suite_id=$suite_id&per_page=100" 2>&1)"; then
      CHECK_EVIDENCE_ERROR="Actions workflow provenance request failed for suite $suite_id; GitHub response details suppressed"
      return 1
    fi
    if ! PINNED_CHECK_WORKFLOWS_JSON="$(node - "$PINNED_CHECK_WORKFLOWS_JSON" "$suite_id" "$workflow_json" 2>/dev/null <<'NODE'
const [rawEntries, suiteIdRaw, rawPayload] = process.argv.slice(2)
const entries = JSON.parse(rawEntries)
entries.push({ requestedSuiteId: Number(suiteIdRaw), rawPayload })
console.log(JSON.stringify(entries))
NODE
)"; then
      CHECK_EVIDENCE_ERROR="Actions workflow provenance response could not be retained safely"
      return 1
    fi
  done <<< "$duplicate_suite_ids"
}

line_number=0
checked_count=0
requirement_keys=()

init_report

if [[ ! -f "$CONFIG_FILE" ]]; then
  echo "[release-pr-readiness][error] Required PR config missing: $CONFIG_FILE" >&2
  write_report "failed"
  exit 1
fi

if ! command -v "$GH_BIN" >/dev/null 2>&1; then
  echo "[release-pr-readiness][error] gh CLI not found. Install GitHub CLI or set GH_BIN." >&2
  write_report "failed"
  exit 1
fi

if ! review_pins_json="$(load_review_pins 2>&1)"; then
  echo "[release-pr-readiness][error] $review_pins_json" >&2
  write_report "failed"
  exit 1
fi

if ! duplicate_check_provenance_pins_json="$(load_duplicate_check_provenance_pins 2>&1)"; then
  echo "[release-pr-readiness][error] $duplicate_check_provenance_pins_json" >&2
  write_report "failed"
  exit 1
fi

while IFS= read -r line || [[ -n "$line" ]]; do
  line_number=$((line_number + 1))
  [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue

  IFS=$'\t' read -r repo head base required_state required_checks extra <<< "$line"

  if [[ -n "${extra:-}" || -z "${repo:-}" || -z "${head:-}" || -z "${base:-}" || -z "${required_state:-}" || -z "${required_checks:-}" ]]; then
    failure="$CONFIG_FILE:$line_number: invalid release PR config line"
    record_failure "$failure"
    append_report_record "failed" "$line_number" "${repo:-}" "${head:-}" "${base:-}" "${required_state:-}" "${required_checks:-}" "$failure"
    continue
  fi

  if [[ ! "$repo" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]]; then
    failure="$CONFIG_FILE:$line_number: invalid repo '$repo'"
    record_failure "$failure"
    append_report_record "failed" "$line_number" "$repo" "$head" "$base" "$required_state" "$required_checks" "$failure"
    continue
  fi

  if ! is_safe_branch_ref "$head"; then
    failure="$CONFIG_FILE:$line_number: invalid head branch ref"
    record_failure "$failure"
    append_report_record "failed" "$line_number" "$repo" "$head" "$base" "$required_state" "$required_checks" "$failure"
    continue
  fi

  if ! is_safe_branch_ref "$base"; then
    failure="$CONFIG_FILE:$line_number: invalid base branch ref"
    record_failure "$failure"
    append_report_record "failed" "$line_number" "$repo" "$head" "$base" "$required_state" "$required_checks" "$failure"
    continue
  fi

  if [[ "$required_state" != "merged" ]]; then
    failure="$CONFIG_FILE:$line_number: unsupported required_state '$required_state'"
    record_failure "$failure"
    append_report_record "failed" "$line_number" "$repo" "$head" "$base" "$required_state" "$required_checks" "$failure"
    continue
  fi

  requirement_key="$repo"$'\t'"$head"$'\t'"$base"$'\t'"$required_state"
  if ((${#requirement_keys[@]} > 0)); then
    for existing_requirement_key in "${requirement_keys[@]}"; do
      if [[ "$existing_requirement_key" == "$requirement_key" ]]; then
        failure="$CONFIG_FILE:$line_number: duplicate release PR requirement row for $repo:$head -> $base"
        record_failure "$failure"
        append_report_record "failed" "$line_number" "$repo" "$head" "$base" "$required_state" "$required_checks" "$failure"
        continue 2
      fi
    done
  fi
  requirement_keys+=("$requirement_key")

  if ! review_pin="$(review_pin_for_requirement "$review_pins_json" "$repo" "$head" "$base" 2>/dev/null)"; then
    failure="$CONFIG_FILE:$line_number: unable to resolve immutable reviewed PR pin"
    record_failure "$failure"
    append_report_record "failed" "$line_number" "$repo" "$head" "$base" "$required_state" "$required_checks" "$failure"
    continue
  fi
  IFS=$'\t' read -r reviewed_pr_number reviewed_head_sha <<< "$review_pin"
  duplicate_check_provenance_json="$(duplicate_check_provenance_for_requirement "$duplicate_check_provenance_pins_json" "$repo" "$head" "$base")"

  checked_count=$((checked_count + 1))
  log "Checking pinned $repo#$reviewed_pr_number at $reviewed_head_sha from head '$head' into '$base' with required checks '$required_checks'"

  if ! pr_json="$("$GH_BIN" pr list \
    --repo "$repo" \
    --head "$head" \
    --base "$base" \
    --state all \
    --limit 20 \
    --json number,url,state,mergedAt,headRefOid,isDraft,reviewDecision,mergeStateStatus,reviews 2>&1)"; then
    if pr_json="$(query_pr_list_rest_fallback "$repo" "$head" "$base" 2>&1)"; then
      warn "$repo:$head -> $base: gh pr list failed; using REST fallback for PR state (GitHub response details suppressed)"
    else
      failure="$repo:$head -> $base: unable to query PR state; primary and REST response details suppressed"
      record_failure "$failure"
      append_report_record "failed" "$line_number" "$repo" "$head" "$base" "$required_state" "$required_checks" "$failure"
      continue
    fi
  fi

  if ! ref_json="$("$GH_BIN" api "repos/$repo/git/matching-refs/heads/$head" 2>&1)"; then
    failure="$repo:$head -> $base: unable to query current PR head branch ref; GitHub response details suppressed"
    record_failure "$failure"
    append_report_record "failed" "$line_number" "$repo" "$head" "$base" "$required_state" "$required_checks" "$failure"
    continue
  fi

  if ! load_pinned_check_evidence "$repo" "$reviewed_head_sha" "$required_checks"; then
    failure="$repo:$head -> $base: unable to query SHA-bound required check evidence for reviewedHeadSha=$reviewed_head_sha: $CHECK_EVIDENCE_ERROR"
    record_failure "$failure"
    append_report_record "failed" "$line_number" "$repo" "$head" "$base" "$required_state" "$required_checks" "$failure"
    continue
  fi

  review_threads_json="{}"
  open_pr_number="$(extract_open_pr_number "$pr_json" "$reviewed_pr_number")"
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
  node_output="$(node - "$repo" "$head" "$base" "$required_checks" "$reviewed_pr_number" "$reviewed_head_sha" "$pr_json" "$ref_json" "$review_threads_json" "$PINNED_CHECK_RUNS_JSON" "$PINNED_COMMIT_STATUS_JSON" "$PINNED_CHECK_SUITES_JSON" "$PINNED_CHECK_WORKFLOWS_JSON" "$duplicate_check_provenance_json" 2>&1 <<'NODE'
const [
  repo,
  head,
  base,
  requiredChecksRaw,
  reviewedPrNumberRaw,
  reviewedHeadSha,
  raw,
  rawRefs,
  rawReviewThreads,
  rawCheckRuns,
  rawCommitStatus,
  rawCheckSuites,
  rawCheckWorkflows,
  rawDuplicateCheckProvenancePins,
] = process.argv.slice(2)

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
const reviewedPrNumber = Number(reviewedPrNumberRaw)
if (!Number.isSafeInteger(reviewedPrNumber) || reviewedPrNumber <= 0) {
  fail(`${repo}:${head} -> ${base}: reviewed PR number pin is invalid`)
}
if (!/^[0-9a-f]{40}$/.test(reviewedHeadSha)) {
  fail(`${repo}:${head} -> ${base}: reviewed PR head commit pin is invalid`)
}

let prs
try {
  prs = JSON.parse(raw)
} catch (error) {
  fail(`${repo}:${head} -> ${base}: gh returned invalid JSON: ${error.message}`)
}

if (!Array.isArray(prs)) {
  fail(`${repo}:${head} -> ${base}: gh returned a non-array PR payload`)
}

if (prs.length === 0) fail(`${repo}:${head} -> ${base}: no pull request found for reviewedPrNumber=${reviewedPrNumber}`)

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
  if (matches.length === 0) {
    return null
  }
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

function parseJsonEvidence(rawEvidence, label) {
  try {
    return JSON.parse(rawEvidence)
  } catch (_) {
    fail(`${repo}:${head} -> ${base}: malformedChecks=${label}-response-invalid-json`)
  }
}

function analyzeChecks() {
  const malformed = []
  const provenance = []
  const entries = []
  const checkRuns = parseJsonEvidence(rawCheckRuns, 'check-runs')
  const commitStatus = parseJsonEvidence(rawCommitStatus, 'commit-status')
  const suiteEntries = parseJsonEvidence(rawCheckSuites, 'check-suites')
  const workflowEntries = parseJsonEvidence(rawCheckWorkflows, 'actions-workflows')
  const duplicateProvenancePins = parseJsonEvidence(rawDuplicateCheckProvenancePins, 'duplicate-check-provenance-pins')

  if (!checkRuns || !Array.isArray(checkRuns.check_runs)) {
    malformed.push('check-runs-response-shape')
  } else if (!Number.isSafeInteger(checkRuns.total_count) || checkRuns.total_count < 0 || checkRuns.total_count !== checkRuns.check_runs.length) {
    malformed.push('check-runs-pagination-incomplete')
  }
  if (!commitStatus || !Array.isArray(commitStatus.statuses)) {
    malformed.push('commit-status-response-shape')
  } else if (!Number.isSafeInteger(commitStatus.total_count) || commitStatus.total_count < 0 || commitStatus.total_count !== commitStatus.statuses.length) {
    malformed.push('commit-status-pagination-incomplete')
  }
  if (!Array.isArray(suiteEntries)) malformed.push('check-suites-response-shape')
  if (!Array.isArray(workflowEntries)) malformed.push('actions-workflows-response-shape')
  if (!Array.isArray(duplicateProvenancePins)) malformed.push('duplicate-check-provenance-pins-response-shape')

  const suites = new Map()
  if (Array.isArray(suiteEntries)) {
    for (const entry of suiteEntries) {
      const requestedId = entry && entry.requestedId
      if (!Number.isSafeInteger(requestedId) || requestedId <= 0 || typeof entry.rawPayload !== 'string') {
        malformed.push('check-suite-envelope')
        continue
      }
      if (suites.has(requestedId)) {
        malformed.push('duplicate-check-suite-provenance')
        continue
      }
      let suite
      try {
        suite = JSON.parse(entry.rawPayload)
      } catch (_) {
        malformed.push('check-suite-response-invalid-json')
        continue
      }
      suites.set(requestedId, suite)
    }
  }

  const workflows = new Map()
  if (Array.isArray(workflowEntries)) {
    for (const entry of workflowEntries) {
      const requestedSuiteId = entry && entry.requestedSuiteId
      if (!Number.isSafeInteger(requestedSuiteId) || requestedSuiteId <= 0 || typeof entry.rawPayload !== 'string') {
        malformed.push('actions-workflow-envelope')
        continue
      }
      if (workflows.has(requestedSuiteId)) {
        malformed.push('duplicate-actions-workflow-provenance')
        continue
      }
      let payload
      try {
        payload = JSON.parse(entry.rawPayload)
      } catch (_) {
        malformed.push('actions-workflow-response-invalid-json')
        continue
      }
      workflows.set(requestedSuiteId, payload)
    }
  }

  const duplicatePinsByName = new Map()
  if (Array.isArray(duplicateProvenancePins)) {
    for (const pin of duplicateProvenancePins) {
      if (
        !pin ||
        pin.repo !== repo ||
        pin.head !== head ||
        pin.base !== base ||
        typeof pin.checkName !== 'string' ||
        !Number.isSafeInteger(pin.appId) ||
        typeof pin.appSlug !== 'string' ||
        !Number.isSafeInteger(pin.workflowId) ||
        typeof pin.workflowPath !== 'string'
      ) {
        malformed.push('duplicate-check-provenance-pin-envelope')
        continue
      }
      if (duplicatePinsByName.has(pin.checkName)) {
        malformed.push('duplicate-check-provenance-pin-identity')
        continue
      }
      duplicatePinsByName.set(pin.checkName, pin)
    }
  }

  function addProvenanceError(entry, error) {
    if (!entry.errors.includes(error)) entry.errors.push(error)
    provenance.push(`${entry.name}:${error}`)
  }

  const requiredNames = new Set(requiredChecks)
  if (checkRuns && Array.isArray(checkRuns.check_runs)) {
    for (const run of checkRuns.check_runs) {
      const name = run && typeof run.name === 'string' ? run.name : ''
      if (!requiredNames.has(name)) continue
      const errors = []
      if (!Number.isSafeInteger(run.id) || run.id <= 0) errors.push('check-run-id-missing')
      if (typeof run.head_sha !== 'string' || run.head_sha.toLowerCase() !== reviewedHeadSha) {
        errors.push('check-run-head-sha-mismatch')
      }
      const suiteId = run.check_suite && run.check_suite.id
      if (!Number.isSafeInteger(suiteId) || suiteId <= 0) {
        errors.push('check-suite-id-missing')
      } else {
        const suite = suites.get(suiteId)
        if (!suite) {
          errors.push('check-suite-provenance-missing')
        } else {
          if (suite.id !== suiteId) errors.push('check-suite-id-mismatch')
          if (typeof suite.head_sha !== 'string' || suite.head_sha.toLowerCase() !== reviewedHeadSha) {
            errors.push('check-suite-head-sha-mismatch')
          }
        }
      }
      const status = String(run.status || '').toUpperCase()
      const conclusion = String(run.conclusion || '').toUpperCase()
      const summary = `${name}:${status || 'UNKNOWN'}/${conclusion || 'PENDING'}`
      const check = {
        kind: 'check-run',
        name,
        run,
        suiteId,
        ok: status === 'COMPLETED' && conclusion === 'SUCCESS',
        outcome: `${status || 'UNKNOWN'}/${conclusion || 'PENDING'}`,
        summary,
        errors,
      }
      entries.push(check)
      for (const error of errors) provenance.push(`${name}:${error}`)
    }
  }

  if (commitStatus && Array.isArray(commitStatus.statuses)) {
    const aggregateShaMatches = typeof commitStatus.sha === 'string' && commitStatus.sha.toLowerCase() === reviewedHeadSha
    for (const statusEntry of commitStatus.statuses) {
      const name = statusEntry && typeof statusEntry.context === 'string' ? statusEntry.context : ''
      if (!requiredNames.has(name)) continue
      const errors = []
      if (!aggregateShaMatches) errors.push('commit-status-head-sha-mismatch')
      if (!Number.isSafeInteger(statusEntry.id) || statusEntry.id <= 0) errors.push('commit-status-id-missing')
      const state = String(statusEntry.state || '').toUpperCase()
      const check = {
        kind: 'commit-status',
        name,
        ok: state === 'SUCCESS',
        outcome: `STATUS/${state || 'PENDING'}`,
        summary: `${name}:STATUS/${state || 'PENDING'}`,
        errors,
      }
      entries.push(check)
      for (const error of errors) provenance.push(`${name}:${error}`)
    }
  }

  const byName = new Map()
  for (const entry of entries) {
    const bucket = byName.get(entry.name) || []
    bucket.push(entry)
    byName.set(entry.name, bucket)
  }

  const checkRunIds = new Map()
  for (const entry of entries.filter((candidate) => candidate.kind === 'check-run')) {
    const id = entry.run && entry.run.id
    if (!Number.isSafeInteger(id) || id <= 0) continue
    const bucket = checkRunIds.get(id) || []
    bucket.push(entry)
    checkRunIds.set(id, bucket)
  }
  for (const bucket of checkRunIds.values()) {
    if (bucket.length < 2) continue
    for (const entry of bucket) addProvenanceError(entry, 'duplicate-check-run-id')
  }

  function validateDuplicateProvenance(name, matches) {
    const pin = duplicatePinsByName.get(name)
    if (!pin) {
      for (const entry of matches) addProvenanceError(entry, 'duplicate-check-provenance-pin-missing')
      return { valid: false, authoritativeMatches: [] }
    }

    let valid = true
    const authoritativeMatches = []
    for (const entry of matches) {
      if (entry.kind !== 'check-run') {
        addProvenanceError(entry, 'duplicate-check-source-not-github-actions')
        valid = false
        continue
      }

      const run = entry.run
      const suite = suites.get(entry.suiteId)
      if (!run.app || run.app.id !== pin.appId || run.app.slug !== pin.appSlug) {
        addProvenanceError(entry, 'check-run-app-mismatch')
        valid = false
      }
      if (!suite || !suite.app || suite.app.id !== pin.appId || suite.app.slug !== pin.appSlug) {
        addProvenanceError(entry, 'check-suite-app-mismatch')
        valid = false
      }

      const workflowPayload = workflows.get(entry.suiteId)
      if (!workflowPayload) {
        addProvenanceError(entry, 'actions-workflow-provenance-missing')
        valid = false
        continue
      }
      if (!Array.isArray(workflowPayload.workflow_runs) || !Number.isSafeInteger(workflowPayload.total_count)) {
        addProvenanceError(entry, 'actions-workflow-response-shape')
        valid = false
        continue
      }
      if (workflowPayload.total_count !== workflowPayload.workflow_runs.length) {
        addProvenanceError(entry, 'actions-workflow-pagination-incomplete')
        valid = false
        continue
      }
      if (workflowPayload.workflow_runs.length === 0) {
        addProvenanceError(entry, 'actions-workflow-provenance-missing')
        valid = false
        continue
      }
      if (workflowPayload.workflow_runs.length !== 1) {
        addProvenanceError(entry, 'actions-workflow-provenance-ambiguous')
        valid = false
        continue
      }

      const workflowRun = workflowPayload.workflow_runs[0]
      if (!workflowRun || workflowRun.check_suite_id !== entry.suiteId) {
        addProvenanceError(entry, 'actions-workflow-check-suite-id-mismatch')
        valid = false
      }
      if (typeof workflowRun.head_sha !== 'string' || workflowRun.head_sha.toLowerCase() !== reviewedHeadSha) {
        addProvenanceError(entry, 'actions-workflow-head-sha-mismatch')
        valid = false
      }
      if (workflowRun.workflow_id !== pin.workflowId) {
        addProvenanceError(entry, 'actions-workflow-id-mismatch')
        valid = false
      }
      if (workflowRun.path !== pin.workflowPath) {
        addProvenanceError(entry, 'actions-workflow-path-mismatch')
        valid = false
      }
      if (!workflowRun.repository || workflowRun.repository.full_name !== repo) {
        addProvenanceError(entry, 'actions-workflow-repository-mismatch')
        valid = false
      }
      if (!workflowRun.head_repository || workflowRun.head_repository.full_name !== repo) {
        addProvenanceError(entry, 'actions-workflow-head-repository-mismatch')
        valid = false
      }
      if (typeof workflowRun.event !== 'string' || workflowRun.event === '') {
        addProvenanceError(entry, 'actions-workflow-event-missing')
        valid = false
      }
      if (
        typeof workflowRun.head_branch !== 'string' ||
        workflowRun.head_branch === '' ||
        /[\u0000-\u001f\u007f]/.test(workflowRun.head_branch)
      ) {
        addProvenanceError(entry, 'actions-workflow-head-branch-missing')
        valid = false
      } else if (workflowRun.event === 'pull_request' && workflowRun.head_branch === head) {
        authoritativeMatches.push(entry)
      }
      if (!Number.isSafeInteger(workflowRun.id) || workflowRun.id <= 0) {
        addProvenanceError(entry, 'actions-workflow-run-id-missing')
        valid = false
      } else {
        const escapedRepo = repo.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')
        const detailsPattern = new RegExp(`^https://github\\.com/${escapedRepo}/actions/runs/${workflowRun.id}/job/[1-9][0-9]*$`)
        if (typeof run.details_url !== 'string' || !detailsPattern.test(run.details_url)) {
          addProvenanceError(entry, 'actions-workflow-details-url-mismatch')
          valid = false
        }
      }
    }
    if (authoritativeMatches.length === 0) {
      for (const entry of matches) {
        addProvenanceError(entry, 'actions-workflow-required-head-pull-request-missing')
      }
      valid = false
    }
    return {
      valid: valid && matches.every((entry) => entry.errors.length === 0),
      authoritativeMatches,
    }
  }

  const missing = []
  const duplicate = []
  const conflicting = []
  const incomplete = []
  const selected = []
  for (const name of requiredChecks) {
    const matches = byName.get(name) || []
    if (matches.length === 0) {
      missing.push(name)
      continue
    }
    if (matches.length > 1) {
      const duplicateResolution = validateDuplicateProvenance(name, matches)
      if (!duplicateResolution.valid) {
        duplicate.push(name)
        continue
      }
      const authoritativeMatches = duplicateResolution.authoritativeMatches
      const outcomes = new Set(authoritativeMatches.map((entry) => entry.outcome))
      if (outcomes.size !== 1) {
        conflicting.push(name)
        continue
      }
      selected.push(authoritativeMatches[0])
      if (!authoritativeMatches[0].ok) incomplete.push(authoritativeMatches[0].summary)
      continue
    }
    selected.push(matches[0])
    if (!matches[0].ok) incomplete.push(matches[0].summary)
  }

  return {
    malformed: [...new Set(malformed)],
    provenance: [...new Set(provenance)],
    missing,
    duplicate,
    conflicting,
    incomplete,
    selected,
    allIncomplete: selected.filter((entry) => !entry.ok).map((entry) => entry.summary),
  }
}

function requiredCheckFailureParts() {
  const analysis = analyzeChecks()
  const parts = []
  if (analysis.malformed.length > 0) {
    parts.push(`malformedChecks=${analysis.malformed.join(',')}`)
  }
  if (analysis.provenance.length > 0) {
    parts.push(`invalidRequiredCheckProvenance=${analysis.provenance.join(',')}`)
  }
  if (analysis.missing.length > 0) {
    parts.push(`missingRequiredChecks=${analysis.missing.join(',')}`)
  }
  if (analysis.duplicate.length > 0) {
    parts.push(`duplicateRequiredChecks=${analysis.duplicate.join(',')}`)
  }
  if (analysis.conflicting.length > 0) {
    parts.push(`conflictingRequiredCheckConclusions=${analysis.conflicting.join(',')}`)
  }
  if (analysis.incomplete.length > 0) {
    parts.push(`incompleteRequiredChecks=${analysis.incomplete.join(',')}`)
  }
  return { analysis, parts }
}

function reviewThreadParts(rawThreads) {
  if (!rawThreads || rawThreads === '{}') {
    return []
  }

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
  const ids = []
  for (const thread of reviewThreads.nodes) {
    if (!thread || typeof thread.isResolved !== 'boolean' || typeof thread.isOutdated !== 'boolean') {
      malformed += 1
    } else if (!thread.isResolved) {
      unresolved += 1
      if (thread.isOutdated) {
        outdated += 1
      } else {
        current += 1
      }

      if (typeof thread.id === 'string' && thread.id.trim() !== '') {
        ids.push(thread.id.trim())
      } else {
        malformed += 1
      }

      if (refs.length < 5) {
        const status = thread.isOutdated ? 'outdated' : 'current'
        const path = typeof thread.path === 'string' && thread.path.trim() !== '' ? thread.path.trim() : 'unknown-path'
        const line = Number.isInteger(thread.line) ? thread.line : (Number.isInteger(thread.originalLine) ? thread.originalLine : 'unknown-line')
        const comments = thread.comments && Array.isArray(thread.comments.nodes) ? thread.comments.nodes : []
        const url = comments.length > 0 && typeof comments[0].url === 'string' && comments[0].url.trim() !== ''
          ? comments[0].url.trim()
          : 'unknown-url'
        refs.push(`${status}:${path}:${line}:${url}`)
      }
    }
  }

  const hasNextPage = Boolean(reviewThreads.pageInfo && reviewThreads.pageInfo.hasNextPage)
  const suffix = hasNextPage ? '+' : ''
  const parts = [
    `unresolvedReviewThreads=${unresolved}${suffix}`,
    `currentUnresolvedReviewThreads=${current}`,
    `outdatedUnresolvedReviewThreads=${outdated}`
  ]
  if (unresolved > 0) {
    parts.push('reviewConversationResolutionRequired=true')
  }
  if (current === 0 && outdated > 0) {
    parts.push('outdatedReviewThreadsStillBlockMerge=true')
  }
  if (refs.length > 0) {
    parts.push(`unresolvedReviewThreadRefs=${refs.join(';')}${hasNextPage ? ';more' : ''}`)
  }
  if (ids.length > 0) {
    parts.push(`unresolvedReviewThreadIds=${ids.slice(0, 20).join(',')}${hasNextPage ? ',more' : ''}`)
  }
  if (malformed > 0) {
    parts.push(`malformedReviewThreads=${malformed}`)
  }
  return parts
}

function reviewApprovalParts(pr) {
  const parts = []
  if (pr.reviewDecision !== 'APPROVED') {
    parts.push('eligibleReviewerApprovalRequired=true')
  }

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
  if (staleApprovals.length > 0) {
    parts.push(`staleApprovalCount=${staleApprovals.length}`)
  }

  const latestApproval = approvals
    .slice()
    .sort((a, b) => Date.parse(a.submittedAt || '') - Date.parse(b.submittedAt || ''))
    .pop()
  const latestApprovalCommit = latestApproval && latestApproval.commit && typeof latestApproval.commit.oid === 'string'
    ? latestApproval.commit.oid.trim()
    : ''
  if (latestApprovalCommit !== '') {
    parts.push(`latestApprovalCommit=${latestApprovalCommit}`)
  }

  if (pr.reviewDecision !== 'APPROVED' && approvals.length > 0 && currentHeadApprovals.length > 0) {
    parts.push('currentApprovalNotEligible=true')
  } else if (pr.reviewDecision !== 'APPROVED' && approvals.length > 0 && currentHeadApprovals.length === 0) {
    parts.push('freshApprovalRequired=true')
  }

  return parts
}

const reviewedMatches = prs.filter((pr) => pr && Number(pr.number) === reviewedPrNumber)
if (reviewedMatches.length === 0) {
  const availableNumbers = prs
    .map((pr) => Number(pr && pr.number))
    .filter((number) => Number.isSafeInteger(number) && number > 0)
    .slice(0, 20)
  fail(`${repo}:${head} -> ${base}: reviewedPrNumberPinMismatch expected=${reviewedPrNumber} available=${availableNumbers.join(',') || 'none'}`)
}
if (reviewedMatches.length !== 1) {
  fail(`${repo}:${head} -> ${base}: ambiguous reviewed PR pin; GitHub returned ${reviewedMatches.length} records for reviewedPrNumber=${reviewedPrNumber}`)
}

const reviewed = reviewedMatches[0]
const reviewedUrl = `https://github.com/${repo}/pull/${reviewedPrNumber}`
if (reviewed.url !== reviewedUrl) {
  fail(`${repo}#${reviewedPrNumber} has invalid canonical PR URL; expected ${reviewedUrl}`)
}
const reviewedState = reviewed.mergedAt ? 'MERGED' : String(reviewed.state || '').toUpperCase()
const returnedHeadSha = typeof reviewed.headRefOid === 'string' ? reviewed.headRefOid.trim().toLowerCase() : ''
if (returnedHeadSha !== reviewedHeadSha) {
  const actual = /^[0-9a-f]{40}$/.test(returnedHeadSha) ? returnedHeadSha : 'missing-or-invalid'
  if (reviewedState === 'MERGED') {
    fail(`${repo}#${reviewedPrNumber} is merged but required checks are not release-ready: ${reviewedUrl} reviewedHeadShaPinMismatch expected=${reviewedHeadSha} actual=${actual}`)
  }
  fail(`${repo}#${reviewedPrNumber} is open and is not release-ready: ${reviewedUrl} reviewedHeadShaPinMismatch expected=${reviewedHeadSha} actual=${actual}`)
}

const unpinnedOpen = prs.find((pr) => pr && String(pr.state || '').toUpperCase() === 'OPEN' && Number(pr.number) !== reviewedPrNumber)
if (unpinnedOpen) {
  const number = Number(unpinnedOpen.number)
  const url = Number.isSafeInteger(number) && number > 0 ? `https://github.com/${repo}/pull/${number}` : reviewedUrl
  fail(`${repo}#${Number.isSafeInteger(number) && number > 0 ? number : reviewedPrNumber} is open and is not release-ready: ${url} unpinnedOpenPr=true reviewedPrNumber=${reviewedPrNumber}`)
}

if (reviewedState === 'OPEN') {
  const open = reviewed
  const { analysis, parts: requiredCheckParts } = requiredCheckFailureParts()

  const parts = [
    `${repo}#${reviewedPrNumber} is open and is not release-ready: ${reviewedUrl}`,
    `isDraft=${open.isDraft === true ? 'true' : 'false'}`,
    `reviewDecision=${open.reviewDecision || 'UNKNOWN'}`,
    `mergeStateStatus=${open.mergeStateStatus || 'UNKNOWN'}`
  ]

  parts.push(...requiredCheckParts)
  parts.push(...reviewApprovalParts(open))
  parts.push(...reviewThreadParts(rawReviewThreads))

  if (analysis.allIncomplete.length > 0) {
    parts.push(`checks=${analysis.allIncomplete.join(',')}`)
  }

  fail(parts.join(' '))
}

if (reviewedState === 'MERGED') {
  const merged = reviewed
  if (currentHeadOid) {
    if (currentHeadOid.toLowerCase() !== reviewedHeadSha) {
      fail(`${repo}#${reviewedPrNumber} is merged but head branch '${head}' has new commits after merge: ${reviewedUrl} currentHeadOid=${currentHeadOid} mergedHeadRefOid=${reviewedHeadSha}`)
    }
  }

  const { parts } = requiredCheckFailureParts()
  if (parts.length > 0) {
    fail(`${repo}#${reviewedPrNumber} is merged but required checks are not release-ready: ${reviewedUrl} ${parts.join(' ')}`)
  }

  console.log(`${repo}#${reviewedPrNumber} is merged with required checks ${requiredChecks.join(',')}: ${reviewedUrl}`)
  process.exit(0)
}

if (reviewedState === 'CLOSED') {
  fail(`${repo}#${reviewedPrNumber} is closed without merge: ${reviewedUrl}`)
}

fail(`${repo}:${head} -> ${base}: no merged pull request found for reviewedPrNumber=${reviewedPrNumber}`)
NODE
)"
  node_status=$?
  set -e

  if [[ "$node_status" -eq 0 && -n "$node_output" ]]; then
    printf '%s\n' "$node_output"
    append_report_record "passed" "$line_number" "$repo" "$head" "$base" "$required_state" "$required_checks" "$node_output"
  fi

  if [[ "$node_status" -ne 0 ]]; then
    if [[ -n "$node_output" ]]; then
      failure="$node_output"
    else
      failure="$repo:$head -> $base: required release PR is not merged"
    fi
    record_failure "$failure"
    append_report_record "failed" "$line_number" "$repo" "$head" "$base" "$required_state" "$required_checks" "$failure"
  fi
done < "$CONFIG_FILE"

if [[ "$checked_count" -eq 0 ]]; then
  failure="$CONFIG_FILE: no release PR requirements were found"
  record_failure "$failure"
  append_report_record "failed" "0" "" "" "" "" "" "$failure"
fi

if ((${#failures[@]} > 0)); then
  write_report "failed"
  echo "[release-pr-readiness][error] Release PR readiness audit failed:" >&2
  printf '  - %s\n' "${failures[@]}" >&2
  exit 1
fi

write_report "passed"
log "Release PR readiness audit passed for $checked_count requirement(s)."
