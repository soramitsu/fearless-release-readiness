#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="${RELEASE_UNBLOCK_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
REPORT_DIR="${RELEASE_READINESS_REPORT_DIR:-$ROOT_DIR/build/reports/release-readiness}"
OUTPUT_DIR="${RELEASE_UNBLOCK_BUNDLE_DIR:-$REPORT_DIR/unblock-bundle}"

usage() {
  cat <<'USAGE'
Usage: scripts/export-release-unblock-bundle.sh [--report-dir DIR] [--output DIR]

Exports a validated release-unblock handoff bundle from the latest
release-readiness artifacts. The bundle contains:
  - summary.json, actions.json, and blockers.md snapshots;
  - one copied log per blocker;
  - checked handoff artifacts such as Android XCM registry gap reports;
  - manifest.json with blocker actions, verification commands, log checksums;
  - unblock.md for release operators;
  - verify-blockers.sh for rerunning blocker verification commands;
  - SHA256SUMS for every generated bundle file.

Environment:
  RELEASE_UNBLOCK_ROOT        Workspace root.
  RELEASE_READINESS_REPORT_DIR Source release-readiness report directory.
  RELEASE_UNBLOCK_BUNDLE_DIR  Output bundle directory.
  RELEASE_UNBLOCK_EXPORT_NOW  Override current UTC time for deterministic tests.
USAGE
}

while (($#)); do
  case "$1" in
    --report-dir)
      REPORT_DIR="$2"
      shift 2
      ;;
    --output)
      OUTPUT_DIR="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "[release-unblock-bundle][error] Unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

node - "$REPORT_DIR" "$OUTPUT_DIR" "$ROOT_DIR" <<'NODE'
const crypto = require('crypto')
const fs = require('fs')
const path = require('path')

const [, , reportDirArg, outputDirArg, workspaceRootArg] = process.argv
const reportRoot = path.resolve(reportDirArg)
const finalOutputRoot = path.resolve(outputDirArg)
let outputRoot = finalOutputRoot
const workspaceRoot = path.resolve(workspaceRootArg)

let outputParentState = null
let initialOutputState = null
let stagingState = null
let backupState = null
let publicationCommitted = false

function fail(message) {
  console.error(`[release-unblock-bundle][error] ${message}`)
  process.exit(1)
}

function assertRegularFile(file, label) {
  if (!fs.existsSync(file)) {
    fail(`${label} missing: ${file}`)
  }
  const stat = fs.lstatSync(file)
  if (!stat.isFile()) {
    fail(`${label} must be a regular file: ${file}`)
  }
}

function assertRegularDirectory(dir, label) {
  if (!fs.existsSync(dir)) {
    fail(`${label} missing: ${dir}`)
  }
  const stat = fs.lstatSync(dir)
  if (!stat.isDirectory()) {
    fail(`${label} must be a regular directory: ${dir}`)
  }
}

function assertFearlessWorkspaceRoot(dir) {
  const requiredMarkers = [
    {
      path: path.join(dir, 'FEARLESS_PROJECT_PLAN.md'),
      sentinel: '# Fearless Universal Wallet Project Plan',
    },
    {
      path: path.join(dir, 'scripts/audit-release-readiness.sh'),
      sentinel: 'Usage: scripts/audit-release-readiness.sh',
      executable: true,
    },
  ]
  for (const marker of requiredMarkers) {
    if (!fs.existsSync(marker.path) || !fs.lstatSync(marker.path).isFile()) {
      fail(`workspace root is not a Fearless workspace: ${dir}`)
    }
    const content = fs.readFileSync(marker.path, 'utf8')
    if (!content.includes(marker.sentinel)) {
      fail(`workspace root marker content mismatch: ${marker.path}`)
    }
    if (marker.executable && (fs.statSync(marker.path).mode & 0o111) === 0) {
      fail(`workspace root marker must be executable: ${marker.path}`)
    }
  }
}

function assertNoRootSymlinkPathPrefix(target, label) {
  const resolvedTarget = path.resolve(target)
  const root = path.parse(resolvedTarget).root
  let current = root
  const relative = path.relative(root, resolvedTarget)
  for (const segment of relative.split(path.sep).filter(Boolean)) {
    current = path.join(current, segment)
    if (!fs.existsSync(current)) return
    if (fs.lstatSync(current).isSymbolicLink()) {
      if (label === 'workspace root') fail(`workspace root must not use a symlinked path component: ${current}`)
      if (label === 'output dir') fail(`output dir must not use a symlinked path component: ${current}`)
      fail(`${label} must not use a symlinked path component: ${current}`)
    }
  }
}

function assertNoWorkspaceRootSymlinkPrefix(target) {
  assertNoRootSymlinkPathPrefix(target, 'workspace root')
}

function assertNoOutputRootSymlinkPrefix(target) {
  assertNoRootSymlinkPathPrefix(target, 'output dir')
}

function assertReportRootInsideWorkspace(reportDir, rootDir) {
  if (!isSameOrDescendant(rootDir, reportDir)) {
    fail(`release-readiness report dir must be inside workspace root: ${reportDir}`)
  }
  const realReportDir = fs.realpathSync.native(reportDir)
  const realRootDir = fs.realpathSync.native(rootDir)
  if (!isSameOrDescendant(realRootDir, realReportDir)) {
    fail(`release-readiness report dir must not alias outside workspace root through symlinks: ${reportDir}`)
  }
}

function isSameOrAncestor(candidate, target) {
  const relative = path.relative(candidate, target)
  return relative === '' || (relative !== '' && !relative.startsWith('..') && !path.isAbsolute(relative))
}

function isSameOrDescendant(parent, candidate) {
  const relative = path.relative(parent, candidate)
  return relative === '' || (relative !== '' && !relative.startsWith('..') && !path.isAbsolute(relative))
}

function resolveWithRealPrefix(target) {
  let existing = target
  while (!fs.existsSync(existing)) {
    const parent = path.dirname(existing)
    if (parent === existing) break
    existing = parent
  }
  const realExisting = fs.realpathSync.native(existing)
  return path.resolve(realExisting, path.relative(existing, target))
}

function commonAncestor(a, b) {
  const resolvedA = path.resolve(a)
  const resolvedB = path.resolve(b)
  const root = path.parse(resolvedA).root
  if (root !== path.parse(resolvedB).root) return ''
  const partsA = resolvedA.slice(root.length).split(path.sep).filter(Boolean)
  const partsB = resolvedB.slice(root.length).split(path.sep).filter(Boolean)
  const common = []
  for (let index = 0; index < Math.min(partsA.length, partsB.length); index += 1) {
    if (partsA[index] !== partsB[index]) break
    common.push(partsA[index])
  }
  return common.length === 0 ? root : path.join(root, ...common)
}

function assertNoSymlinkPathPrefix(target, label, anchors) {
  const resolvedTarget = path.resolve(target)
  const root = path.parse(resolvedTarget).root
  const anchor = anchors
    .map((candidate) => commonAncestor(candidate, resolvedTarget))
    .filter((candidate) => candidate && candidate !== root)
    .sort((a, b) => b.length - a.length)[0]
  if (!anchor) return

  let current = anchor
  const relative = path.relative(anchor, resolvedTarget)
  for (const segment of relative.split(path.sep).filter(Boolean)) {
    current = path.join(current, segment)
    if (!fs.existsSync(current)) return
    if (fs.lstatSync(current).isSymbolicLink()) {
      const diagnostic = label === 'output dir'
        ? `output dir must not use a symlinked path component: ${current}`
        : `${label} must not use a symlinked path component: ${current}`
      fail(diagnostic)
    }
  }
}

function assertSafeOutputRoot(outputDir, reportDir, rootDir) {
  if (fs.existsSync(outputDir) && !fs.lstatSync(outputDir).isDirectory()) {
    fail(`output dir must be absent or a regular directory: ${outputDir}`)
  }
  assertNoOutputRootSymlinkPrefix(outputDir)

  const realOutputDir = resolveWithRealPrefix(outputDir)
  const realReportDir = fs.realpathSync.native(reportDir)
  const realRootDir = fs.realpathSync.native(rootDir)

  if (isSameOrAncestor(outputDir, rootDir) || isSameOrAncestor(realOutputDir, realRootDir)) {
    fail(`output dir must not be the workspace root or an ancestor: ${outputDir}`)
  }
  if (isSameOrAncestor(outputDir, reportDir) || isSameOrAncestor(realOutputDir, realReportDir)) {
    fail(`output dir must not be the release-readiness report dir or an ancestor: ${outputDir}`)
  }
  if (isSameOrDescendant(realReportDir, realOutputDir) && !isSameOrDescendant(reportDir, outputDir)) {
    fail(`output dir must not alias the release-readiness report dir through symlinks: ${outputDir}`)
  }
  if (isSameOrDescendant(realRootDir, realOutputDir) && !isSameOrDescendant(rootDir, outputDir)) {
    fail(`output dir must not alias the workspace root through symlinks: ${outputDir}`)
  }
  assertNoSymlinkPathPrefix(outputDir, 'output dir', [reportDir, rootDir])
}

function lstatIdentity(target) {
  const stat = fs.lstatSync(target, { bigint: true })
  return {
    dev: stat.dev,
    ino: stat.ino,
    isDirectory: stat.isDirectory(),
    isSymbolicLink: stat.isSymbolicLink(),
  }
}

function hasSameIdentity(actual, expected) {
  return actual.dev === expected.dev && actual.ino === expected.ino
}

function assertStableOutputParent() {
  if (!outputParentState || !fs.existsSync(outputParentState.path)) {
    fail(`output parent changed during bundle construction: ${path.dirname(finalOutputRoot)}`)
  }
  const current = lstatIdentity(outputParentState.path)
  if (!current.isDirectory || current.isSymbolicLink || !hasSameIdentity(current, outputParentState.identity)) {
    fail(`output parent changed during bundle construction: ${outputParentState.path}`)
  }
  if (fs.realpathSync.native(outputParentState.path) !== outputParentState.realPath) {
    fail(`output parent changed during bundle construction: ${outputParentState.path}`)
  }
}

function assertStableFinalOutput() {
  assertStableOutputParent()
  assertNoOutputRootSymlinkPrefix(finalOutputRoot)

  if (!initialOutputState.exists) {
    if (fs.existsSync(finalOutputRoot)) {
      fail(`output dir changed during bundle construction: expected absent: ${finalOutputRoot}`)
    }
    return
  }

  if (!fs.existsSync(finalOutputRoot)) {
    fail(`output dir changed during bundle construction: expected existing directory: ${finalOutputRoot}`)
  }
  const current = lstatIdentity(finalOutputRoot)
  if (!current.isDirectory || current.isSymbolicLink || !hasSameIdentity(current, initialOutputState.identity)) {
    fail(`output dir changed during bundle construction: ${finalOutputRoot}`)
  }
}

function assertOwnedTemporaryDirectory(state, label) {
  if (!state || !fs.existsSync(state.path)) fail(`${label} disappeared during bundle construction: ${state ? state.path : '<missing>'}`)
  const current = lstatIdentity(state.path)
  if (!current.isDirectory || current.isSymbolicLink || !hasSameIdentity(current, state.identity)) {
    fail(`${label} changed during bundle construction: ${state.path}`)
  }
}

function removeOwnedTemporaryDirectory(state, label) {
  if (!state || !fs.existsSync(state.path)) return true
  try {
    const current = lstatIdentity(state.path)
    if (!current.isDirectory || current.isSymbolicLink || !hasSameIdentity(current, state.identity)) {
      console.error(`[release-unblock-bundle][warn] refusing to remove changed ${label}: ${state.path}`)
      return false
    }
    fs.rmSync(state.path, { recursive: true, force: true })
    return true
  } catch (error) {
    console.error(`[release-unblock-bundle][warn] could not remove ${label} ${state.path}: ${error.message}`)
    return false
  }
}

function cleanupTemporaryDirectories() {
  if (stagingState) removeOwnedTemporaryDirectory(stagingState, 'staging directory')
  if (backupState) {
    if (!publicationCommitted && backupState.previousPath && fs.existsSync(backupState.previousPath)) {
      console.error(`[release-unblock-bundle][warn] preserving previous output after incomplete publication: ${backupState.previousPath}`)
    } else {
      removeOwnedTemporaryDirectory(backupState, 'backup directory')
    }
  }
}

process.once('exit', cleanupTemporaryDirectories)
for (const [signal, exitCode] of [['SIGHUP', 129], ['SIGINT', 130], ['SIGQUIT', 131], ['SIGTERM', 143]]) {
  process.once(signal, () => {
    console.error(`[release-unblock-bundle][error] interrupted by ${signal}`)
    process.exit(exitCode)
  })
}

function createSecureStagingDirectory() {
  const outputParent = path.dirname(finalOutputRoot)
  fs.mkdirSync(outputParent, { recursive: true, mode: 0o700 })
  assertNoOutputRootSymlinkPrefix(finalOutputRoot)
  assertRegularDirectory(outputParent, 'output parent')

  const parentIdentity = lstatIdentity(outputParent)
  outputParentState = {
    path: outputParent,
    realPath: fs.realpathSync.native(outputParent),
    identity: parentIdentity,
  }
  initialOutputState = fs.existsSync(finalOutputRoot)
    ? { exists: true, identity: lstatIdentity(finalOutputRoot) }
    : { exists: false, identity: null }

  const prefix = path.join(outputParent, `.${path.basename(finalOutputRoot)}.staging-`)
  const stagingPath = fs.mkdtempSync(prefix)
  fs.chmodSync(stagingPath, 0o700)
  const stagingIdentity = lstatIdentity(stagingPath)
  if (!stagingIdentity.isDirectory || stagingIdentity.isSymbolicLink || stagingIdentity.dev !== parentIdentity.dev) {
    fs.rmSync(stagingPath, { recursive: true, force: true })
    fail(`could not create a secure same-filesystem staging directory for output: ${finalOutputRoot}`)
  }
  stagingState = { path: stagingPath, identity: stagingIdentity }
  outputRoot = stagingPath
}

function readJson(file, label) {
  assertRegularFile(file, label)

  try {
    return JSON.parse(fs.readFileSync(file, 'utf8'))
  } catch (error) {
    fail(`${label} is not valid JSON: ${error.message}`)
  }
}

function assertObject(value, label) {
  if (!value || typeof value !== 'object' || Array.isArray(value)) {
    fail(`${label} must be an object`)
  }
}

function assertAllowedKeys(value, allowed, label) {
  assertObject(value, label)
  for (const key of Object.keys(value)) {
    if (!allowed.includes(key)) {
      fail(`unsupported ${label} key: ${key}`)
    }
  }
}

function requireString(value, label) {
  if (typeof value !== 'string' || value.trim() === '') {
    fail(`${label} must be a non-empty string`)
  }
}

function requireSingleLine(value, label) {
  requireString(value, label)
  if (/[\r\n\u0000]/.test(value)) {
    fail(`${label} must be a single-line value`)
  }
}

function assertEvidencePreviewMatchesLog(preview, logContent, label) {
  requireString(preview, label)
  const normalizedPreview = preview.replace(/\r\n/g, '\n')
  const normalizedLog = String(logContent).replace(/\r\n/g, '\n')
  const logLines = new Set(normalizedLog.split('\n'))
  const lineCapMarkerPattern = /^\[line capped to final (\d+) characters; see full log\]$/
  const excerptCapMarkerPattern = /^\[excerpt capped at \d+ characters; see full log\]$/
  let allowCappedPartialLine = false
  let expectedCappedLineLength = null
  let matchedLines = 0

  for (const line of normalizedPreview.split('\n')) {
    if (line === '') continue
    const lineCapMarkerMatch = line.match(lineCapMarkerPattern)
    if (lineCapMarkerMatch) {
      allowCappedPartialLine = true
      expectedCappedLineLength = Number(lineCapMarkerMatch[1])
      continue
    }
    if (excerptCapMarkerPattern.test(line)) continue
    if (allowCappedPartialLine) {
      if (line.length !== expectedCappedLineLength) {
        fail(`${label} capped line length must match line cap marker`)
      }
      if (!normalizedLog.split('\n').some((logLine) => logLine.endsWith(line))) {
        fail(`${label} capped line is not present as a source log line suffix`)
      }
      allowCappedPartialLine = false
      expectedCappedLineLength = null
      matchedLines += 1
      continue
    }
    if (!normalizedLog.includes(line)) {
      fail(`${label} line is not present in source log`)
    }
    if (!logLines.has(line)) {
      fail(`${label} line must match a complete source log line`)
    }
    matchedLines += 1
  }

  if (allowCappedPartialLine) {
    fail(`${label} line cap marker must be followed by a source log line suffix`)
  }

  if (matchedLines === 0) {
    fail(`${label} must include at least one source log line`)
  }
}

function requireBoolean(value, label) {
  if (typeof value !== 'boolean') {
    fail(`${label} must be boolean`)
  }
}

function requireNumber(value, label) {
  if (!Number.isInteger(value) || value < 0) {
    fail(`${label} must be a non-negative integer`)
  }
}

function assertFailedBlockerExitCode(value, label) {
  requireNumber(value, label)
  if (value <= 0) fail(`${label} must be positive for failed blocker`)
}

function assertSummaryExitCodeForStatus(status, value, label) {
  requireNumber(value, label)
  if (status === 'passed' && value !== 0) fail(`${label} must be 0 for passed check`)
  if (status === 'failed' && value <= 0) fail(`${label} must be positive for failed check`)
}

function parseUtcSecondsTimestamp(value, label) {
  requireString(value, label)
  if (!/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$/.test(value)) {
    fail(`${label} must be an ISO-8601 UTC seconds timestamp`)
  }
  const time = Date.parse(value)
  if (!Number.isFinite(time)) fail(`${label} must be a valid timestamp`)
  return time
}

function parseUtcTimestamp(value, label) {
  requireString(value, label)
  if (!/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{3})?Z$/.test(value)) {
    fail(`${label} must be an ISO-8601 UTC timestamp`)
  }
  const time = Date.parse(value)
  if (!Number.isFinite(time)) fail(`${label} must be a valid timestamp`)
  const canonical = new Date(time).toISOString()
  const normalizedValue = value.includes('.') ? value : value.replace(/Z$/, '.000Z')
  if (canonical !== normalizedValue) fail(`${label} must be a valid timestamp`)
  return time
}

function parseUtcDate(value, label) {
  requireString(value, label)
  if (!/^\d{4}-\d{2}-\d{2}$/.test(value)) {
    fail(`${label} must be YYYY-MM-DD`)
  }
  const time = Date.parse(`${value}T00:00:00Z`)
  if (!Number.isFinite(time)) fail(`${label} must be a valid YYYY-MM-DD date`)
  const canonical = new Date(time).toISOString().slice(0, 10)
  if (canonical !== value) fail(`${label} must be a valid YYYY-MM-DD date`)
  return time
}

function assertNotFutureTimestamp(timeMs, value, label, nowMs) {
  const futureSkewMs = 5 * 60 * 1000
  if (timeMs > nowMs + futureSkewMs) {
    fail(`${label} is in the future: ${value}`)
  }
}

function assertNotFutureDate(timeMs, value, label, nowMs) {
  const futureSkewMs = 5 * 60 * 1000
  if (timeMs > nowMs + futureSkewMs) {
    fail(`${label} must not be in the future`)
  }
}

function formatUtcSeconds(timeMs) {
  return new Date(timeMs).toISOString().replace(/\.\d{3}Z$/, 'Z')
}

const secretPattern = /(?:private[_-]?key|mnemonic|seed phrase|access[_-]?token|api[_-]?key|password|secret)/i
function assertNoSecretLike(label, content) {
  const scanContent = String(content)
    .replace(/\bsecret-safe\b/gi, 'redaction-safe')
    .replace(
      /(^|[=\s"'`])\/run\/secrets\/passkey-smoke-grant-helper(?=$|[\s"'`])/g,
      '$1/run/runtime/passkey-smoke-grant-helper',
    )
  const match = scanContent.match(secretPattern)
  if (match) {
    fail(`${label} contains secret-like token: ${match[0]}`)
  }
}

function escapeRegExp(value) {
  return String(value).replace(/[.*+?^${}()|[\]\\]/g, '\\$&')
}

function sha256(content) {
  return crypto.createHash('sha256').update(content).digest('hex')
}

function shellQuote(value) {
  return `'${String(value).replace(/'/g, `'\\''`)}'`
}

function markdownFenceFor(content) {
  const runs = String(content).match(/`+/g) || []
  const maxRun = runs.reduce((max, run) => Math.max(max, run.length), 0)
  return '`'.repeat(Math.max(3, maxRun + 1))
}

function pushFencedBlock(lines, language, content) {
  const fence = markdownFenceFor(content)
  lines.push(`${fence}${language}`)
  lines.push(content)
  lines.push(fence)
}

function defaultWorkspaceRoot() {
  return workspaceRoot
}

function renderVerifyScript(blockers) {
  const lines = [
    '#!/usr/bin/env bash',
    'set -euo pipefail',
    '',
    `WORKSPACE_ROOT=\${RELEASE_UNBLOCK_WORKSPACE_ROOT:-${shellQuote(defaultWorkspaceRoot())}}`,
    '',
    'usage() {',
    "  cat <<'USAGE'",
    'Usage: verify-blockers.sh [slug...]',
    '',
    'Runs verification commands for blockers captured in this release-unblock bundle.',
    'Set RELEASE_UNBLOCK_WORKSPACE_ROOT=/path/to/fearless when running from a moved bundle.',
    '',
    'Available blocker slugs:',
  ]

  if (blockers.length === 0) {
    lines.push('  (none)')
  } else {
    for (const blocker of blockers) {
      lines.push(`  - ${blocker.slug}`)
    }
  }

  lines.push(
    'USAGE',
    '}',
    '',
    'if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then',
    '  usage',
    '  exit 0',
    'fi',
    '',
    'require_workspace_root() {',
    '  if [[ ! -e "$WORKSPACE_ROOT" ]]; then',
    '    echo "[release-unblock-verify][error] Workspace root does not exist: $WORKSPACE_ROOT" >&2',
    '    return 2',
    '  fi',
    '  if [[ ! -d "$WORKSPACE_ROOT" || -L "$WORKSPACE_ROOT" ]]; then',
    '    echo "[release-unblock-verify][error] Workspace root must be a regular directory: $WORKSPACE_ROOT" >&2',
    '    return 2',
    '  fi',
    '  assert_no_workspace_root_symlink_prefix || return $?',
    '  if [[ ! -f "$WORKSPACE_ROOT/FEARLESS_PROJECT_PLAN.md" || -L "$WORKSPACE_ROOT/FEARLESS_PROJECT_PLAN.md" || ! -f "$WORKSPACE_ROOT/scripts/audit-release-readiness.sh" || -L "$WORKSPACE_ROOT/scripts/audit-release-readiness.sh" ]]; then',
    '    echo "[release-unblock-verify][error] Workspace root is not a Fearless workspace: $WORKSPACE_ROOT" >&2',
    '    return 2',
    '  fi',
    '  if ! grep -qF "# Fearless Universal Wallet Project Plan" "$WORKSPACE_ROOT/FEARLESS_PROJECT_PLAN.md" || ! grep -qF "Usage: scripts/audit-release-readiness.sh" "$WORKSPACE_ROOT/scripts/audit-release-readiness.sh"; then',
    '    echo "[release-unblock-verify][error] Workspace root marker content mismatch: $WORKSPACE_ROOT" >&2',
    '    return 2',
    '  fi',
    '  if [[ ! -x "$WORKSPACE_ROOT/scripts/audit-release-readiness.sh" ]]; then',
    '    echo "[release-unblock-verify][error] Workspace root audit marker must be executable: $WORKSPACE_ROOT/scripts/audit-release-readiness.sh" >&2',
    '    return 2',
    '  fi',
    '}',
    '',
    'assert_no_workspace_root_symlink_prefix() {',
    '  local check_path="$WORKSPACE_ROOT"',
    '  if [[ "$check_path" != /* ]]; then',
    '    check_path="$PWD/$check_path"',
    '  fi',
    '  local current="/"',
    '  local remainder="${check_path#/}"',
    '  local segment',
    '  while [[ -n "$remainder" ]]; do',
    '    segment="${remainder%%/*}"',
    '    if [[ "$remainder" == "$segment" ]]; then',
    '      remainder=""',
    '    else',
    '      remainder="${remainder#*/}"',
    '    fi',
    '    if [[ -z "$segment" || "$segment" == "." ]]; then',
    '      continue',
    '    fi',
    '    if [[ "$segment" == ".." ]]; then',
    '      current="$(dirname "$current")"',
    '      continue',
    '    fi',
    '    if [[ "$current" == "/" ]]; then',
    '      current="/$segment"',
    '    else',
    '      current="$current/$segment"',
    '    fi',
    '    if [[ -L "$current" ]]; then',
    '      echo "[release-unblock-verify][error] Workspace root must not use a symlinked path component: $current" >&2',
    '      return 2',
    '    fi',
    '  done',
    '}',
    '',
    'validate_slug() {',
    '  case "$1" in'
  )

  for (const blocker of blockers) {
    lines.push(`    ${blocker.slug}) return 0 ;;`)
  }

  lines.push(
    '    *)',
    '      echo "[release-unblock-verify][error] Unknown blocker slug: $1" >&2',
    '      usage >&2',
    '      return 2',
    '      ;;',
    '  esac',
    '}',
    '',
    'run_blocker() {',
    '  case "$1" in'
  )

  for (const blocker of blockers) {
    lines.push(`    ${blocker.slug})`)
    lines.push(`      echo ${shellQuote(`[release-unblock-verify] Running ${blocker.slug}: ${blocker.name}`)}`)
    lines.push('      require_workspace_root')
    lines.push('      (')
    lines.push('        cd "$WORKSPACE_ROOT"')
    lines.push(`        ${blocker.verificationCommand}`)
    lines.push('      )')
    lines.push('      ;;')
  }

  lines.push(
    '    *)',
    '      echo "[release-unblock-verify][error] Unknown blocker slug: $1" >&2',
    '      usage >&2',
    '      return 2',
    '      ;;',
    '  esac',
    '}',
    '',
    'if (($# == 0)); then'
  )

  if (blockers.length === 0) {
    lines.push('  echo "[release-unblock-verify] No blockers were captured in this bundle."')
    lines.push('  exit 0')
  } else {
    lines.push(`  set -- ${blockers.map((blocker) => shellQuote(blocker.slug)).join(' ')}`)
  }

  lines.push(
    'fi',
    '',
    'for slug in "$@"; do',
    '  validate_slug "$slug"',
    'done',
    '',
    'require_workspace_root',
    '',
    'failures=()',
    'for slug in "$@"; do',
    '  if ! run_blocker "$slug"; then',
    '    failures+=("$slug")',
    '    echo "[release-unblock-verify][error] Blocker verification failed: $slug" >&2',
    '  fi',
    'done',
    '',
    'if ((${#failures[@]} > 0)); then',
    '  echo "[release-unblock-verify][error] ${#failures[@]} blocker verification command(s) failed: ${failures[*]}" >&2',
    '  exit 1',
    'fi',
    ''
  )

  return lines.join('\n')
}

function renderBlockerReportMarkdown(summary, actions) {
  const lines = [
    '# Release Readiness Blockers',
    '',
    `- Generated at: ${summary.generatedAt}`,
    `- Run live checks: ${summary.runLive}`,
    `- Totals: ${summary.totals.passed} passed, ${summary.totals.failed} failed, ${summary.totals.skipped} skipped, ${summary.totals.total} total`,
    '',
  ]

  if (actions.blockers.length === 0) {
    lines.push(
      summary.status === 'incomplete'
        ? 'Release readiness is incomplete because required live checks were skipped; this run is not production-ready evidence.'
        : 'No blocking release-readiness failures recorded.',
      '',
    )
  } else {
    lines.push('## Failed Checks', '')
    for (const blocker of actions.blockers) {
      lines.push(`### ${blocker.name}`)
      lines.push('')
      lines.push(`- Slug: \`${blocker.slug}\``)
      lines.push(`- Exit code: \`${blocker.exitCode}\``)
      lines.push(`- Log: \`${blocker.logFile}\``)
      lines.push(`- Recommended action: ${blocker.recommendedAction}`)
      lines.push(`- Requires external action: \`${blocker.requiresExternalAction}\``)
      lines.push(`- Unblock category: \`${blocker.unblockCategory}\``)
      lines.push(`- External prerequisite: ${blocker.externalPrerequisite}`)
      lines.push(`- Verification command: \`${blocker.verificationCommand}\``)
      lines.push('')
      lines.push('Evidence preview:')
      lines.push('')
      pushFencedBlock(lines, 'text', blocker.evidencePreview)
      lines.push('')
    }
  }

  if (summary.totals.skipped > 0) {
    lines.push('## Skipped Checks', '')
    for (const check of summary.checks) {
      if (check.status !== 'skipped') continue
      lines.push(`- \`${check.slug}\` (${check.name})`)
    }
    lines.push('')
  }

  return lines.join('\n') + '\n'
}

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

function requireLineNumberField(line, name, label) {
  const parsed = numberField(line, name)
  if (!parsed || parsed.invalid || parsed.paginated) {
    fail(`${label}.${name} must be a non-paginated non-negative integer`)
  }
  return parsed.value
}

function optionalLineNumberField(line, name, label) {
  const parsed = numberField(line, name)
  if (!parsed) return 0
  if (parsed.invalid || parsed.paginated) {
    fail(`${label}.${name} must be a non-paginated non-negative integer`)
  }
  return parsed.value
}

function booleanField(line, name) {
  const raw = field(line, name)
  if (raw === null) return null
  if (raw === 'true') return true
  if (raw === 'false') return false
  return { invalid: raw }
}

function releasePrApprovalDiagnosticParts(pr) {
  if (pr.reviewDetails) {
    return [`reviewDetails=${pr.reviewDetails}`]
  }
  const parts = [
    `approvalCount=${pr.approvalCount}`,
    `currentHeadApprovalCount=${pr.currentHeadApprovalCount}`,
    `staleApprovalCount=${pr.staleApprovalCount}`,
  ]
  if (pr.latestApprovalCommit) parts.push(`latestApprovalCommit=${pr.latestApprovalCommit}`)
  if (pr.currentApprovalNotEligible) parts.push('currentApprovalNotEligible=true')
  if (pr.freshApprovalRequired) parts.push('freshApprovalRequired=true')
  return parts
}

function buildOutdatedReviewThreadResolution(logContent) {
  const records = []
  const seenThreadIds = new Set()

  for (const line of logContent.split(/\r?\n/)) {
    if (!line.includes('open and is not release-ready')) continue
    if (line.includes('reviewThreadsQuery=') || line.includes('malformedReviewThreads=')) continue

    const prMatch = line.match(/([A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+)#([0-9]+) is open/)
    if (!prMatch) continue

    const unresolved = numberField(line, 'unresolvedReviewThreads')
    const current = numberField(line, 'currentUnresolvedReviewThreads')
    const outdated = numberField(line, 'outdatedUnresolvedReviewThreads')
    if (!unresolved || unresolved.invalid || !current || current.invalid || !outdated || outdated.invalid) continue
    if (unresolved.value === 0 || unresolved.paginated || current.value !== 0 || outdated.value !== unresolved.value) continue

    const rawIds = field(line, 'unresolvedReviewThreadIds')
    if (!rawIds) continue
    const ids = rawIds.split(',').filter(Boolean)
    if (ids.includes('more') || ids.length !== unresolved.value) continue

    const refs = field(line, 'unresolvedReviewThreadRefs') || ''
    for (const id of ids) {
      if (!/^PRRT_[A-Za-z0-9_-]+$/.test(id)) continue
      if (seenThreadIds.has(id)) continue
      seenThreadIds.add(id)
      records.push({
        repo: prMatch[1],
        pr: prMatch[2],
        id,
        refs,
      })
    }
  }

  if (records.length === 0) return null

  const auditLog = 'build/reports/release-readiness/release-pr-readiness.log'
  return {
    threadCount: records.length,
    dryRunCommand: `bash scripts/resolve-release-pr-review-threads.sh --dry-run --audit-log ${auditLog}`,
    applyCommand: `RELEASE_PR_THREAD_RESOLUTION_CONFIRM=resolve-outdated-review-threads bash scripts/resolve-release-pr-review-threads.sh --apply --audit-log ${auditLog}`,
    threads: records,
  }
}

function buildReleasePrApprovalHandoff(logContent, statusReport = null) {
  if (statusReport) {
    const records = releasePrApprovalRecordsFromStatusReport(statusReport)
    if (records.length === 0) return null
    return {
      approvalCount: records.length,
      dryRunCommand: 'bash scripts/merge-release-prs.sh --dry-run --config config/release-readiness-prs.tsv',
      prs: records,
    }
  }

  const records = []
  const seen = new Set()

  for (const line of logContent.split(/\r?\n/)) {
    if (line.startsWith('  - ')) continue
    if (!line.includes('open and is not release-ready')) continue
    if (!line.includes('reviewDecision=REVIEW_REQUIRED')) continue
    if (line.includes('missingRequiredChecks=') || line.includes('incompleteRequiredChecks=') || line.includes('checks=')) continue

    const prMatch = line.match(/([A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+)#([0-9]+) is open and is not release-ready: (https:\/\/github\.com\/[^\s]+)/)
    if (!prMatch) continue

    const unresolved = numberField(line, 'unresolvedReviewThreads')
    const current = numberField(line, 'currentUnresolvedReviewThreads')
    const outdated = numberField(line, 'outdatedUnresolvedReviewThreads')
    if (!unresolved || unresolved.invalid || !current || current.invalid || !outdated || outdated.invalid) continue
    if (unresolved.value !== 0 || current.value !== 0 || outdated.value !== 0 || unresolved.paginated) continue

    const key = `${prMatch[1]}#${prMatch[2]}`
    if (seen.has(key)) continue
    seen.add(key)
    const eligibleReviewerApprovalRequired = booleanField(line, 'eligibleReviewerApprovalRequired')
    if (eligibleReviewerApprovalRequired !== true) {
      fail(`${key}.eligibleReviewerApprovalRequired must be true`)
    }
    const reviewDetails = field(line, 'reviewDetails')
    if (reviewDetails) {
      if (!['unavailable', 'malformed'].includes(reviewDetails)) {
        fail(`${key}.reviewDetails must be unavailable or malformed`)
      }
      records.push({
        repo: prMatch[1],
        pr: prMatch[2],
        url: prMatch[3],
        reviewDecision: 'REVIEW_REQUIRED',
        mergeStateStatus: field(line, 'mergeStateStatus') || 'UNKNOWN',
        requiredAction: 'restore review details for eligible reviewer approval',
        eligibleReviewerApprovalRequired,
        reviewDetails,
      })
      continue
    }
    const approvalCount = requireLineNumberField(line, 'approvalCount', key)
    const currentHeadApprovalCount = requireLineNumberField(line, 'currentHeadApprovalCount', key)
    const staleApprovalCount = optionalLineNumberField(line, 'staleApprovalCount', key)
    const currentApprovalNotEligible = booleanField(line, 'currentApprovalNotEligible')
    if (currentApprovalNotEligible && currentApprovalNotEligible.invalid) {
      fail(`${key}.currentApprovalNotEligible must be boolean`)
    }
    const freshApprovalRequired = booleanField(line, 'freshApprovalRequired')
    if (freshApprovalRequired && freshApprovalRequired.invalid) {
      fail(`${key}.freshApprovalRequired must be boolean`)
    }
    const latestApprovalCommit = field(line, 'latestApprovalCommit')
    if (latestApprovalCommit && !/^[0-9a-f]{40}$/i.test(latestApprovalCommit)) {
      fail(`${key}.latestApprovalCommit must be a 40-character hex commit`)
    }
    records.push({
      repo: prMatch[1],
      pr: prMatch[2],
      url: prMatch[3],
      reviewDecision: 'REVIEW_REQUIRED',
      mergeStateStatus: field(line, 'mergeStateStatus') || 'UNKNOWN',
      requiredAction: 'eligible reviewer approval',
      eligibleReviewerApprovalRequired,
      approvalCount,
      currentHeadApprovalCount,
      staleApprovalCount,
      ...(latestApprovalCommit ? { latestApprovalCommit } : {}),
      currentApprovalNotEligible: currentApprovalNotEligible === true,
      freshApprovalRequired: freshApprovalRequired === true,
    })
  }

  if (records.length === 0) return null

  return {
    approvalCount: records.length,
    dryRunCommand: 'bash scripts/merge-release-prs.sh --dry-run --config config/release-readiness-prs.tsv',
    prs: records,
  }
}

function releasePrBlockedRequirementCount(report) {
  return report.requirements.filter((requirement) => requirement.status === 'failed' && requirement.pr).length
}

function releasePrMergeHandoffForSlug(slug, report) {
  if (slug !== 'release-pr-readiness') return null
  return {
    configPath: 'config/release-readiness-prs.tsv',
    requiredPrCount: report.totals.total,
    blockedPrCount: releasePrBlockedRequirementCount(report),
    mergeMethod: 'merge',
    dryRunCommand: 'bash scripts/merge-release-prs.sh --dry-run --config config/release-readiness-prs.tsv',
    applyCommand: 'RELEASE_PR_MERGE_CONFIRM=merge-release-prs bash scripts/merge-release-prs.sh --apply --config config/release-readiness-prs.tsv',
    postMergeVerificationCommand: 'bash scripts/audit-release-pr-readiness.sh',
  }
}

const liveServiceUrlPolicy = {
  allowedProtocols: ['https'],
  credentials: 'forbidden',
  query: 'forbidden',
  fragment: 'forbidden',
  canonicalInput: 'use the exact baseUrl; do not append credentials, query strings, or fragments',
}

function cloneLiveServiceUrlPolicy() {
  return {
    ...liveServiceUrlPolicy,
    allowedProtocols: [...liveServiceUrlPolicy.allowedProtocols],
  }
}

function validateLiveServiceUrlPolicy(value, label) {
  assertAllowedKeys(value, ['allowedProtocols', 'credentials', 'query', 'fragment', 'canonicalInput'], label)
  if (!Array.isArray(value.allowedProtocols) || value.allowedProtocols.length === 0) {
    fail(`${label}.allowedProtocols must be a non-empty array`)
  }
  for (const [index, protocol] of value.allowedProtocols.entries()) {
    requireSingleLine(protocol, `${label}.allowedProtocols[${index}]`)
    assertNoSecretLike(`${label}.allowedProtocols[${index}]`, protocol)
  }
  for (const key of ['credentials', 'query', 'fragment', 'canonicalInput']) {
    requireSingleLine(value[key], `${label}.${key}`)
    assertNoSecretLike(`${label}.${key}`, value[key])
  }
}

const liveServiceHandoffBySlug = {
  'passkey-backup-prerequisites': {
    service: 'passkey-backup-challenge-service',
    baseUrl: 'https://backup.fearlesswallet.io',
    healthPath: '/api/passkey-backup/v1/health',
    expectedContracts: [
      'health.ok=true',
      'health.service=fearless-passkey-backup',
      'health.rpId=fearlesswallet.io',
      'health.schemaVersion=1',
    ],
    verificationCommand: 'PASSKEY_BACKUP_LIVE_HEALTH=1 bash scripts/audit-passkey-backup-prerequisites.sh && node fearless-site-web/scripts/verify-app-associations.mjs --root fearless-site-web --live-base-url https://fearlesswallet.io',
  },
  'passkey-production-smoke': {
    service: 'passkey-backup-challenge-service',
    baseUrl: 'https://backup.fearlesswallet.io',
    healthPath: '/api/passkey-backup/v1/health',
    routePaths: [
      '/api/passkey-backup/v1/health',
      '/api/passkey-backup/v1/registration/challenge',
      '/api/passkey-backup/v1/assertion/challenge',
      '/api/passkey-backup/v1/registration/complete',
      '/api/passkey-backup/v1/assertion/complete',
      '/api/passkey-backup/v1/credentials/list',
      '/api/passkey-backup/v1/credentials/revoke',
      '/api/passkey-backup/v1/credentials/revoke-all',
    ],
    expectedContracts: [
      'health.ok=true',
      'health.service=fearless-passkey-backup',
      'health.rpId=fearlesswallet.io',
      'health.schemaVersion=1',
      'registration challenge returns HTTP 200 with registrationId, challenge, userId, storageKey, rpId, and schemaVersion',
      'assertion challenge for unregistered credential returns HTTP 404 error=credential_not_registered',
      'registration completion for unknown registration returns HTTP 404 error=unknown_or_expired_registration',
      'assertion completion for unknown assertion returns HTTP 404 error=unknown_or_expired_assertion',
      'credential list for unregistered storage returns HTTP 404 error=credential_storage_not_registered without leaked verification material',
      'unknown credential revoke is idempotent, returns remainingCredentials=0, and does not create an owner record',
      'unknown credential revoke-all is idempotent, returns remainingCredentials=0, and does not create an owner record',
      'smoke does not persist a test credential',
    ],
    verificationCommand: 'cd services/passkey-backup-challenge-service && PASSKEY_BACKUP_BASE_URL=https://backup.fearlesswallet.io PASSKEY_BACKUP_SMOKE_GRANT_HELPER=/run/secrets/passkey-smoke-grant-helper PASSKEY_BACKUP_SMOKE_TIMEOUT_MS=10000 npm run smoke:production',
  },
  'iroha-release-readiness': {
    service: 'sora-nexus-torii',
    baseUrl: 'https://minamoto.sora.org',
    healthPath: '/status',
    expectedContracts: [
      'transport uses HTTPS without redirects and returns bounded HTTP 200 application/json',
      'observed_at_ms is no more than 30 seconds ahead or five minutes behind the verifier clock',
      'last_block_committed_at_ms is no more than 30 seconds ahead and within five minutes of the verifier clock',
      'peers is positive and block and transaction-queue counters are coherent',
      'build.git_commit_sha exactly matches the committed NEXUS_EXPECTED_BUILD_COMMIT',
      'nexus.routing_policy exactly matches ordered default 0/0, governance 1/1, and smartcontract::deploy 2/2 routing',
      'dataspace_catalog contains unique unsealed canonical 0/0, 1/1, and 2/2 targets with required manifests ready',
    ],
    verificationCommand: 'IROHA_NEXUS_REQUIRE_PRODUCTION_EVIDENCE=1 IROHA_NEXUS_LIVE_HEALTH=1 bash scripts/audit-iroha-release-readiness.sh',
  },
  'ti-production-smoke': {
    service: 'ton-indexer',
    baseUrl: 'https://ti.soramitsu.io',
    healthPath: '/api/indexer/v1/health',
    serviceInfoPath: '/api/indexer/v1/service-info',
    openApiPath: '/api/indexer/v1/openapi.json',
    expectedContracts: [
      'health.serviceId=ti.soramitsu.io',
      'health.ecosystem=ton',
      'health.chainId=ton:mainnet',
      'health.network=mainnet',
      'health.lastMasterSeqno present',
      'health.ok absent',
      'serviceInfo.serviceId=ti.soramitsu.io',
      'serviceInfo.ecosystem=ton',
      'serviceInfo.chainId=ton:mainnet',
      'serviceInfo.network=mainnet',
      'serviceInfo.publicBaseUrl=https://ti.soramitsu.io',
      'serviceInfo.readOnly=true',
      'serviceInfo.endpoints.openapi=/api/indexer/v1/openapi.json',
      'openapi.info.title=TONSWAP Indexer API',
    ],
    verificationCommand: 'cd ../ton-indexer && TON_INDEXER_BASE_URL=https://ti.soramitsu.io npm run smoke:production',
  },
  'si-production-smoke': {
    service: 'solswap-indexer',
    baseUrl: 'https://si.soramitsu.io',
    healthPath: '/api/indexer/v1/health',
    serviceInfoPath: '/api/indexer/v1/service-info',
    openApiPath: '/api/indexer/v1/openapi.json',
    expectedContracts: [
      'health.ok=true',
      'health.lastMasterSeqno absent',
      'health.serviceId=si.soramitsu.io',
      'health.ecosystem=solana',
      'health.chainId=solana:mainnet',
      'health.network=mainnet',
      'serviceInfo.serviceId=si.soramitsu.io',
      'serviceInfo.ecosystem=solana',
      'serviceInfo.chainId=solana:mainnet',
      'serviceInfo.network=mainnet',
      'serviceInfo.publicBaseUrl=https://si.soramitsu.io',
      'serviceInfo.readOnly=true',
      'serviceInfo.endpoints.openapi=/api/indexer/v1/openapi.json',
      'openapi.info.title=Solswap Indexer API',
    ],
    verificationCommand: 'cd ../solswap-indexer && SOLSWAP_INDEXER_BASE_URL=https://si.soramitsu.io npm run smoke:production',
  },
  'pi-production-smoke': {
    service: 'polkaswap-indexer',
    baseUrl: 'https://pi.soramitsu.io/graphql',
    healthPath: 'GraphQL _health',
    expectedContracts: [
      'health.ok=true',
      'health.service=polkaswap-indexer',
      'health.serviceId=pi.soramitsu.io',
      'health.schemaVersion=1',
      'health.ecosystem=sora2',
      'health.chainId=sora:mainnet',
      'health.network=mainnet',
      'health.publicBaseUrl=https://pi.soramitsu.io/graphql',
      'health.readOnly=true',
      'health.genesisHash=0x7e4e32d0feafd4f9c9414b0be86373f9a1efa904809b683453a9af6856d38ad5',
      'health.latestIndexedBlock is a positive safe integer',
      'health.latestIndexedBlockHash is a canonical nonzero lowercase 32-byte hash',
      'health.latestIndexedAt is no more than 30 seconds ahead or 300 seconds behind the verifier clock',
      'worker chainIdentity update proves the immutable SORA mainnet genesis',
      'worker chainState matches the health checkpoint height, block hash, and block timestamp',
      'worker BLOCK snapshot id and timestamp match the health checkpoint',
      'TON contract rejected',
      'Solana/Solswap contract rejected',
    ],
    verificationCommand: 'cd ../polkaswap-indexer && POLKASWAP_INDEXER_BASE_URL=https://pi.soramitsu.io/graphql bash ../fearless/scripts/run-pinned-yarn.sh smoke:production',
  },
}

function liveServiceHandoffForSlug(slug) {
  const handoff = liveServiceHandoffBySlug[slug]
  if (!handoff) return null
  return {
    ...handoff,
    urlPolicy: cloneLiveServiceUrlPolicy(),
    expectedContracts: [...handoff.expectedContracts],
    ...(handoff.routePaths ? { routePaths: [...handoff.routePaths] } : {}),
  }
}

const evidenceTemplateCommandsBySlug = {
  'passkey-deployment-evidence': [
    'cd services/passkey-backup-challenge-service && npm run test:deployment-evidence-template',
    'cd services/passkey-backup-challenge-service && npm run generate:deployment-evidence-template -- --output build/reports/production-deployment-evidence-template.json',
  ],
  'iroha-release-readiness': [
    'bash scripts/test-nexus-production-evidence-template.sh',
    'bash scripts/generate-nexus-production-evidence-template.sh --output build/reports/nexus-production-evidence-template.json',
  ],
  'android-xcm-production-evidence': [
    'cd fearless-Android && bash scripts/test-xcm-production-evidence-template.sh',
    'cd fearless-Android && bash scripts/generate-xcm-production-evidence-template.sh --output build/reports/xcm-production-evidence-template.json',
  ],
  'web-bitcoin-broadcast-evidence': [
    'cd fearless-wallet-web && yarn test:bitcoin-broadcast-evidence-template',
    'cd fearless-wallet-web && yarn generate:bitcoin-broadcast-evidence-template -- --output build/reports/bitcoin-broadcast-evidence-template.json',
  ],
  'ti-deployment-evidence': [
    'cd ../ton-indexer && npm run test:deployment-evidence-template',
    'cd ../ton-indexer && npm run generate:deployment-evidence-template -- --output build/reports/production-deployment-evidence-template.json',
  ],
  'si-deployment-evidence': [
    'cd ../solswap-indexer && npm run test:deployment-evidence-template',
    'cd ../solswap-indexer && npm run generate:deployment-evidence-template -- --output build/reports/production-deployment-evidence-template.json',
  ],
  'pi-deployment-evidence': [
    'cd ../polkaswap-indexer && bash ../fearless/scripts/run-pinned-yarn.sh test:deployment-evidence-template',
    'cd ../polkaswap-indexer && bash ../fearless/scripts/run-pinned-yarn.sh generate:deployment-evidence-template --output build/reports/production-deployment-evidence-template.json',
  ],
}

function evidenceTemplateCommandsForSlug(slug) {
  return evidenceTemplateCommandsBySlug[slug] ? [...evidenceTemplateCommandsBySlug[slug]] : null
}

const evidenceTemplateHandoffBySlug = {
  'passkey-deployment-evidence': {
    selfTestCommand: 'cd services/passkey-backup-challenge-service && npm run test:deployment-evidence-template',
    generateCommand: 'cd services/passkey-backup-challenge-service && npm run generate:deployment-evidence-template -- --output build/reports/production-deployment-evidence-template.json',
    outputPath: 'services/passkey-backup-challenge-service/build/reports/production-deployment-evidence-template.json',
    destinationManifest: 'services/passkey-backup-challenge-service/scripts/production-deployment-evidence.json',
    readyAuditCommand: 'cd services/passkey-backup-challenge-service && npm run audit:deployment-evidence -- --require-ready',
    requiredEvidenceContracts: [
      'imageDigest must be immutable',
      'commit must match the deployed service release commit',
      'healthResponse.service=fearless-passkey-backup',
      'healthResponse.rpId=fearlesswallet.io',
      'credentialStore.path=/data/passkey-backup/credentials.json',
    ],
  },
  'iroha-release-readiness': {
    selfTestCommand: 'bash scripts/test-nexus-production-evidence-template.sh',
    generateCommand: 'bash scripts/generate-nexus-production-evidence-template.sh --output build/reports/nexus-production-evidence-template.json',
    outputPath: 'build/reports/nexus-production-evidence-template.json',
    destinationManifest: 'config/nexus-production-evidence.json',
    readyAuditCommand: 'bash scripts/audit-nexus-production-evidence.sh --require-ready',
    requiredEvidenceContracts: [
      'routePublicationEvidence.routeManifestCommit must match the Iroha release commit',
      'routePublicationEvidence.routeManifestSourcePath must pin the canonical committed artifact and routeManifestHash must be recomputed',
      'routePublicationEvidence must be present',
      'routeCanaryEvidence must be present after route publication',
      'walletSmokeEvidence must include android, ios, and web',
      'walletSmokeEvidence.walletCommit must match each wallet release commit',
      'ready evidence must verify exact committed Minamoto receipts and instructions; self-test receipts cannot satisfy release',
    ],
  },
  'android-xcm-production-evidence': {
    selfTestCommand: 'cd fearless-Android && bash scripts/test-xcm-production-evidence-template.sh',
    generateCommand: 'cd fearless-Android && bash scripts/generate-xcm-production-evidence-template.sh --output build/reports/xcm-production-evidence-template.json',
    outputPath: 'fearless-Android/build/reports/xcm-production-evidence-template.json',
    destinationManifest: 'fearless-Android/scripts/xcm-production-evidence.json',
    readyAuditCommand: 'cd fearless-Android && bash scripts/audit-xcm-effective-registry.sh --discovery-url https://raw.githubusercontent.com/soramitsu/shared-features-utils/master/chains/v13/chains.json --require-all-approved --write-report build/reports/xcm-effective-registry-report.json && bash scripts/audit-xcm-production-evidence.sh --effective-registry-report build/reports/xcm-effective-registry-report.json --require-ready',
    requiredEvidenceContracts: [
      'one evidence record per scripts/xcm-required-routes.tsv route',
      'extrinsicHash must be a 0x-prefixed 32-byte hash',
      'environment must be mainnet',
      'androidCommit must match the Android release commit under validation',
      'scripts/xcm-discovery-only-routes.tsv must be empty for ready evidence',
      'the canonical live effective-registry report must be regenerated and validate complete approved/effective parity before ready evidence can pass',
    ],
  },
  'web-bitcoin-broadcast-evidence': {
    selfTestCommand: 'cd fearless-wallet-web && yarn test:bitcoin-broadcast-evidence-template',
    generateCommand: 'cd fearless-wallet-web && yarn generate:bitcoin-broadcast-evidence-template -- --output build/reports/bitcoin-broadcast-evidence-template.json',
    outputPath: 'fearless-wallet-web/build/reports/bitcoin-broadcast-evidence-template.json',
    destinationManifest: 'fearless-wallet-web/scripts/bitcoin-testnet-broadcast-evidence.json',
    readyAuditCommand: 'cd fearless-wallet-web && bash scripts/audit-bitcoin-broadcast-evidence.sh --require-ready',
    requiredEvidenceContracts: [
      'indexerUrl must be https://blockstream.info/testnet/api',
      'status.block_time must be present from the indexer',
      'evidence timestamp must be at or after the confirmed block time',
      'commit must match the web wallet release commit under validation',
      'sourceAddress and recipientAddress must be Bitcoin testnet addresses',
    ],
  },
  'ti-deployment-evidence': {
    selfTestCommand: 'cd ../ton-indexer && npm run test:deployment-evidence-template',
    generateCommand: 'cd ../ton-indexer && npm run generate:deployment-evidence-template -- --output build/reports/production-deployment-evidence-template.json',
    outputPath: '../ton-indexer/build/reports/production-deployment-evidence-template.json',
    destinationManifest: '../ton-indexer/scripts/production-deployment-evidence.json',
    readyAuditCommand: 'cd ../ton-indexer && npm run audit:deployment-evidence -- --require-ready',
    requiredEvidenceContracts: [
      'commit must match the deployed ton-indexer release commit',
      'serviceInfo.serviceId=ti.soramitsu.io',
      'serviceInfo.chainId=ton:mainnet',
      'healthInfo.serviceId=ti.soramitsu.io',
      'healthInfo.lastMasterSeqno must come from successful production smoke',
    ],
  },
  'si-deployment-evidence': {
    selfTestCommand: 'cd ../solswap-indexer && npm run test:deployment-evidence-template',
    generateCommand: 'cd ../solswap-indexer && npm run generate:deployment-evidence-template -- --output build/reports/production-deployment-evidence-template.json',
    outputPath: '../solswap-indexer/build/reports/production-deployment-evidence-template.json',
    destinationManifest: '../solswap-indexer/scripts/production-deployment-evidence.json',
    readyAuditCommand: 'cd ../solswap-indexer && npm run audit:deployment-evidence -- --require-ready',
    requiredEvidenceContracts: [
      'commit must match the deployed solswap-indexer release commit',
      'serviceInfo.serviceId=si.soramitsu.io',
      'serviceInfo.chainId=solana:mainnet',
      'healthInfo.serviceId=si.soramitsu.io',
      'healthInfo.ok=true and healthInfo.lastMasterSeqno must be absent',
      'healthInfo.genesisHash=5eykt4UsFv8P8NJdTREpY1vzqKqZKvdpKuc147dw2N9d',
      'healthInfo.latestSlot must be a positive safe integer',
      'healthInfo.syncedAt must be an integer no more than 120 seconds before and no more than 30 seconds after smokePassedAt',
    ],
  },
  'pi-deployment-evidence': {
    selfTestCommand: 'cd ../polkaswap-indexer && bash ../fearless/scripts/run-pinned-yarn.sh test:deployment-evidence-template',
    generateCommand: 'cd ../polkaswap-indexer && bash ../fearless/scripts/run-pinned-yarn.sh generate:deployment-evidence-template --output build/reports/production-deployment-evidence-template.json',
    outputPath: '../polkaswap-indexer/build/reports/production-deployment-evidence-template.json',
    destinationManifest: '../polkaswap-indexer/scripts/production-deployment-evidence.json',
    readyAuditCommand: 'cd ../polkaswap-indexer && bash ../fearless/scripts/run-pinned-yarn.sh audit:deployment-evidence --require-ready',
    requiredEvidenceContracts: [
      'commit must match the deployed polkaswap-indexer release commit',
      'healthInfo.service=polkaswap-indexer',
      'healthInfo.serviceId=pi.soramitsu.io',
      'healthInfo.chainId=sora:mainnet',
      'healthInfo.publicBaseUrl=https://pi.soramitsu.io/graphql',
      'healthInfo.genesisHash=0x7e4e32d0feafd4f9c9414b0be86373f9a1efa904809b683453a9af6856d38ad5',
      'healthInfo.latestIndexedBlock must be a positive safe integer',
      'healthInfo.latestIndexedBlockHash must be a canonical nonzero 32-byte lowercase hash',
      'healthInfo.latestIndexedAt must be an integer no more than 300 seconds before and no more than 30 seconds after smokePassedAt',
      'soraRpcControls must contain exactly the seven reviewed primary/archive trust-boundary fields',
      'soraRpcControls.primaryEndpoint must be a canonical credential-free WSS URL for a locally-controlled verifying archival node and not a public SORA convenience host',
      'soraRpcControls.archiveEndpoint must be a canonical credential-free WSS URL for an independently-operated verifying archival node on a distinct host and not a public SORA convenience host',
      'soraRpcControls.exactIdentityPreflight must be true and rawPayloadAgreement must be height-hash-scale-block-events-timestamp',
      'tlsEdgeControls.tlsTermination=true',
      'tlsEdgeControls.forwardedClientIpHeaders=overwrite',
      'tlsEdgeControls.httpClientIpRateLimit=600 requests per 60000 ms',
      'tlsEdgeControls.webSocketClientIpLimits=600 upgrades per 60000 ms and 16 concurrent connections',
    ],
  },
}

function evidenceTemplateHandoffForSlug(slug) {
  const handoff = evidenceTemplateHandoffBySlug[slug]
  return handoff ? { ...handoff } : null
}

function normalizeBundleRelativePath(relativeDestination) {
  requireString(relativeDestination, 'bundle artifact path')
  assertNoSecretLike('bundle artifact path', relativeDestination)
  if (relativeDestination.includes('\\')) fail(`bundle artifact path must use forward slashes: ${relativeDestination}`)
  if (path.isAbsolute(relativeDestination)) fail(`bundle artifact path must be relative: ${relativeDestination}`)
  const normalized = path.posix.normalize(relativeDestination)
  if (normalized === '.' || normalized.startsWith('../') || normalized.includes('/../')) {
    fail(`bundle artifact path points outside output bundle: ${relativeDestination}`)
  }
  if (normalized !== relativeDestination) fail(`bundle artifact path must be normalized: ${relativeDestination}`)
  return normalized
}

function assertUniqueArtifactDestination(relativeDestination, artifacts) {
  const normalizedDestination = normalizeBundleRelativePath(relativeDestination)
  if (artifacts.some((artifact) => artifact.path === normalizedDestination)) {
    fail(`duplicate bundle artifact path: ${normalizedDestination}`)
  }
  return normalizedDestination
}

function copyArtifact(src, relativeDestination, artifacts) {
  const normalizedDestination = assertUniqueArtifactDestination(relativeDestination, artifacts)
  assertRegularFile(src, `${normalizedDestination} source`)
  const content = fs.readFileSync(src)
  assertNoSecretLike(normalizedDestination, content.toString('utf8'))

  const destination = path.join(outputRoot, normalizedDestination)
  fs.mkdirSync(path.dirname(destination), { recursive: true })
  fs.writeFileSync(destination, content)

  artifacts.push({
    path: normalizedDestination,
    sourcePath: src,
    sha256: sha256(content),
    bytes: content.length,
  })
}

function copyCheckedArtifact(src, relativeDestination, artifacts) {
  const normalizedDestination = assertUniqueArtifactDestination(relativeDestination, artifacts)
  assertRegularFile(src, `${normalizedDestination} source`)
  const content = fs.readFileSync(src)
  const destination = path.join(outputRoot, normalizedDestination)
  fs.mkdirSync(path.dirname(destination), { recursive: true })
  fs.writeFileSync(destination, content)

  artifacts.push({
    path: normalizedDestination,
    sourcePath: src,
    sha256: sha256(content),
    bytes: content.length,
  })
}

const releasePrStatusReportSourcePath = 'release-pr-readiness-report.json'
const releasePrStatusReportArtifactPath = 'handoffs/release-pr-readiness-report.json'
const releasePrConfigPath = 'config/release-readiness-prs.tsv'
const sourcePublicationReportSourcePath = 'source-publication-readiness-report.json'
const sourcePublicationReportArtifactPath = 'handoffs/source-publication-readiness-report.json'
const sourcePublicationConfigPath = 'config/source-publication-readiness.tsv'
const sourcePublicationConfigArtifactPath = 'handoffs/source-publication-readiness.tsv'
const sourcePublicationRootOwnerConfigPath = 'config/source-publication-root-owner.json'
const sourcePublicationRootOwnerConfigArtifactPath = 'handoffs/source-publication-root-owner.json'
const sourcePublicationRepositories = [
  ['fearless-Android', 'soramitsu/fearless-Android', 'codex/android-xcm-evidence-release-commit', 'develop', 1258],
  ['fearless-iOS', 'soramitsu/fearless-iOS', 'codex/ios-transaction-builder-ci-gate', 'develop', 1301],
  ['fearless-wallet-web', 'soramitsu/fearless-wallet-web', 'codex/web-bitcoin-canonical-indexer-evidence', 'develop', 1062],
  ['fearless-site-web', 'soramitsu/fearless-site-web', 'codex/site-todo-debt-baseline-hardening', 'develop', 45],
  ['../ton-indexer', 'tonswap-org/ton-indexer', 'codex/ti-smoke-body-preview-tests', 'develop', 13],
  ['../solswap-indexer', 'solswap-io/solswap-indexer', 'codex/si-smoke-body-preview-tests', 'develop', 16],
  ['../polkaswap-indexer', 'sora-xor/polkaswap-indexer', 'codex/pi-deployment-evidence-gate', 'develop', 1],
  ['../iroha', 'hyperledger-iroha/iroha', 'codex/kagemusha-selector-hardening', 'optimizations', 5612],
]
const sourcePublicationWorkspaceRequiredFiles = [
  'FEARLESS_PROJECT_PLAN.md',
  'config/release-readiness-prs.tsv',
  'config/source-publication-root-owner.json',
  'config/source-publication-readiness.tsv',
  'scripts/audit-release-readiness.sh',
  'scripts/audit-source-publication-readiness.mjs',
  'scripts/export-release-unblock-bundle.sh',
  'scripts/quarantine-source-publication-outputs.mjs',
  'scripts/run-pinned-yarn.sh',
  'scripts/run-source-publication-quarantine.sh',
  'scripts/run-source-publication-readiness.sh',
  'scripts/test-pinned-yarn-runner.sh',
  'scripts/test-source-publication-quarantine.sh',
  'scripts/test-source-publication-readiness-audit.sh',
  'scripts/verify-release-unblock-bundle.sh',
  'services/passkey-backup-challenge-service/Dockerfile',
  'services/passkey-backup-challenge-service/package-lock.json',
  'services/passkey-backup-challenge-service/package.json',
  'services/passkey-backup-challenge-service/src/server.js',
]

function repositoryFromCredentialFreeGitHubOrigin(value) {
  if (typeof value !== 'string') return null
  if (/^git@github\.com:[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+(?:\.git)?$/.test(value)) {
    return value.replace(/^git@github\.com:/, '').replace(/\.git$/, '')
  }
  if (/^ssh:\/\/git@github\.com\/[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+(?:\.git)?$/.test(value)) {
    return value.replace(/^ssh:\/\/git@github\.com\//, '').replace(/\.git$/, '')
  }
  try {
    const url = new URL(value)
    if (url.protocol !== 'https:' || url.hostname !== 'github.com' || url.username || url.password || url.search || url.hash) return null
    const match = url.pathname.match(/^\/([A-Za-z0-9_.-]+)\/([A-Za-z0-9_.-]+?)(?:\.git)?$/)
    return match ? `${match[1]}/${match[2]}` : null
  } catch {
    return null
  }
}

function assertNullableSingleLine(value, label) {
  if (value !== null) requireSingleLine(value, label)
}

function assertSourcePublicationSource(source, label) {
  const keys = [
    'path', 'repository', 'head', 'base', 'prNumber', 'prUrl', 'prState', 'prHeadSha', 'repositoryPath', 'status',
    'originUrl', 'originRepository', 'branch', 'headSha', 'upstream', 'upstreamSha', 'remoteHeadSha',
    'remoteBranchPresent', 'currentBranchRemoteSha', 'currentBranchRemotePresent', 'stagedCount',
    'unstagedCount', 'untrackedCount', 'unmergedCount', 'dirtyPaths',
    'requiredTrackedFiles', 'failures',
  ]
  assertAllowedKeys(source, keys, label)
  requireSingleLine(source.path, `${label}.path`)
  requireSingleLine(source.repositoryPath, `${label}.repositoryPath`)
  if (!path.isAbsolute(source.repositoryPath)) fail(`${label}.repositoryPath must be absolute`)
  if (!['passed', 'failed'].includes(source.status)) fail(`${label}.status must be passed or failed`)
  for (const field of ['repository', 'head', 'base', 'prUrl', 'prState', 'prHeadSha', 'originUrl', 'originRepository', 'branch', 'headSha', 'upstream', 'upstreamSha', 'remoteHeadSha', 'currentBranchRemoteSha']) {
    assertNullableSingleLine(source[field], `${label}.${field}`)
  }
  if (source.prNumber !== null && (!Number.isInteger(source.prNumber) || source.prNumber <= 0)) fail(`${label}.prNumber must be null or positive integer`)
  if (source.remoteBranchPresent !== null) requireBoolean(source.remoteBranchPresent, `${label}.remoteBranchPresent`)
  if (source.currentBranchRemotePresent !== null) requireBoolean(source.currentBranchRemotePresent, `${label}.currentBranchRemotePresent`)
  for (const field of ['stagedCount', 'unstagedCount', 'untrackedCount', 'unmergedCount']) requireNumber(source[field], `${label}.${field}`)
  for (const field of ['dirtyPaths', 'requiredTrackedFiles', 'failures']) {
    if (!Array.isArray(source[field])) fail(`${label}.${field} must be an array`)
    for (const [index, value] of source[field].entries()) requireSingleLine(value, `${label}.${field}[${index}]`)
    if (new Set(source[field]).size !== source[field].length) fail(`${label}.${field} must not contain duplicates`)
  }
  if (source.status === 'passed' && source.failures.length !== 0) fail(`${label}.passed source must have no failures`)
  if (source.status === 'failed' && source.failures.length === 0) fail(`${label}.failed source must carry failures`)
  for (const field of ['prHeadSha', 'headSha', 'upstreamSha', 'remoteHeadSha', 'currentBranchRemoteSha']) {
    if (source[field] !== null && !/^[0-9a-f]{40}$/.test(source[field])) fail(`${label}.${field} must be lowercase 40-character SHA-1`)
  }
  if (source.remoteBranchPresent !== true && source.remoteHeadSha !== null) {
    fail(`${label}.remoteHeadSha must be null when remoteBranchPresent is false or null`)
  }
  if (source.currentBranchRemotePresent !== true && source.currentBranchRemoteSha !== null) {
    fail(`${label}.currentBranchRemoteSha must be null when currentBranchRemotePresent is false or null`)
  }
  if (source.branch === source.head) {
    if (source.currentBranchRemotePresent !== source.remoteBranchPresent) {
      fail(`${label}.currentBranchRemotePresent must match remoteBranchPresent when branch matches head`)
    }
    if (source.currentBranchRemoteSha !== source.remoteHeadSha) {
      fail(`${label}.currentBranchRemoteSha must match remoteHeadSha when branch matches head`)
    }
  }
  if ((source.originUrl === null) !== (source.originRepository === null)) fail(`${label}.originUrl and originRepository must both be null or populated`)
  if (source.originUrl !== null) {
    assertNoSecretLike(`${label}.originUrl`, source.originUrl)
    const originRepository = repositoryFromCredentialFreeGitHubOrigin(source.originUrl)
    if (!originRepository) fail(`${label}.originUrl must be a credential-free github.com HTTPS or SSH URL`)
    if (originRepository !== source.originRepository) fail(`${label}.originRepository must match originUrl`)
  }
}

function assertPassedSourcePublicationSemantics(source, label, expectedRepositoryPath, expectedRequiredTrackedFiles) {
  if (source.status !== 'passed') return
  if (source.repositoryPath !== expectedRepositoryPath) fail(`${label}.repositoryPath mismatch`)
  for (const field of ['repository', 'head', 'base', 'prUrl', 'prState', 'prHeadSha', 'originUrl', 'originRepository', 'branch', 'headSha']) {
    if (source[field] === null) fail(`${label}.${field} is required for a passed source`)
  }
  if (source.prNumber === null) fail(`${label}.prNumber is required for a passed source`)
  if (source.prHeadSha !== source.headSha) fail(`${label}.prHeadSha must match headSha for a passed source`)
  if (source.originRepository !== source.repository) fail(`${label}.originRepository must match repository for a passed source`)
  if (source.branch !== source.head) fail(`${label}.branch must match head for a passed source`)
  if (source.prUrl !== `https://github.com/${source.repository}/pull/${source.prNumber}`) fail(`${label}.prUrl mismatch for a passed source`)
  if (source.prState !== 'merged') fail(`${label}.prState must be merged for a passed source`)
  if (source.stagedCount !== 0 || source.unstagedCount !== 0 || source.untrackedCount !== 0 || source.unmergedCount !== 0) {
    fail(`${label}.passed source must have zero dirty counts`)
  }
  if (source.dirtyPaths.length !== 0) fail(`${label}.passed source must have no dirtyPaths`)
  assertExactStringArray(source.requiredTrackedFiles, expectedRequiredTrackedFiles, `${label}.requiredTrackedFiles`)
  if (source.remoteBranchPresent === null) fail(`${label}.remoteBranchPresent is required for a passed source`)
  if (source.currentBranchRemotePresent === null) fail(`${label}.currentBranchRemotePresent is required for a passed source`)
  if (source.remoteBranchPresent === true) {
    if (source.currentBranchRemotePresent !== true) fail(`${label}.currentBranchRemotePresent must match remoteBranchPresent for a passed source`)
    if (source.currentBranchRemoteSha !== source.remoteHeadSha) fail(`${label}.currentBranchRemoteSha must match remoteHeadSha for a passed source`)
    if (source.remoteHeadSha !== source.headSha) fail(`${label}.remoteHeadSha must match headSha when the remote branch exists`)
    if (source.upstream !== `origin/${source.head}` || source.upstreamSha !== source.headSha) {
      fail(`${label}.upstream must match the published head when the remote branch exists`)
    }
  } else if (source.remoteBranchPresent === false) {
    if (source.currentBranchRemotePresent !== false) fail(`${label}.currentBranchRemotePresent must match remoteBranchPresent for a passed source`)
    if (source.currentBranchRemoteSha !== source.remoteHeadSha) fail(`${label}.currentBranchRemoteSha must match remoteHeadSha for a passed source`)
    if (source.remoteHeadSha !== null) fail(`${label}.remoteHeadSha must be null when the merged remote branch is absent`)
    if (source.currentBranchRemoteSha !== null) fail(`${label}.currentBranchRemoteSha must be null when the merged current branch is absent`)
    if (source.upstream !== null && source.upstream !== `origin/${source.head}`) fail(`${label}.upstream mismatch for deleted merged branch`)
    if (source.upstream === null && source.upstreamSha !== null) fail(`${label}.upstreamSha must be null when upstream is absent`)
    if (source.upstreamSha !== null && source.upstreamSha !== source.headSha) fail(`${label}.upstreamSha must match headSha`)
  }
}

function assertSourcePublicationReport(report, label, summaryGeneratedAt = null) {
  assertAllowedKeys(report, ['schemaVersion', 'generatedAt', 'status', 'checkRemote', 'workspaceRoot', 'workspaceParent', 'configFile', 'rootOwnerConfigFile', 'releasePrConfigFile', 'totals', 'workspaceSource', 'repositories'], label)
  if (report.schemaVersion !== 2) fail(`${label}.schemaVersion must be 2`)
  const sourceGeneratedAtMs = parseUtcTimestamp(report.generatedAt, `${label}.generatedAt`)
  assertNotFutureTimestamp(sourceGeneratedAtMs, report.generatedAt, `${label}.generatedAt`, nowMs)
  if (summaryGeneratedAt !== null) {
    const deltaMs = summaryGeneratedAt - sourceGeneratedAtMs
    if (deltaMs < 0) fail(`${label}.generatedAt must not be later than summary.generatedAt`)
    if (deltaMs > 5 * 60 * 1000) fail(`${label}.generatedAt must be within five minutes of summary.generatedAt`)
  }
  if (!['passed', 'failed'].includes(report.status)) fail(`${label}.status must be passed or failed`)
  requireBoolean(report.checkRemote, `${label}.checkRemote`)
  if (report.checkRemote !== true) fail(`${label}.checkRemote must be true for a full-live bundle`)
  if (report.workspaceRoot !== workspaceRoot) fail(`${label}.workspaceRoot mismatch`)
  if (report.workspaceParent !== path.dirname(workspaceRoot)) fail(`${label}.workspaceParent mismatch`)
  if (report.configFile !== path.join(workspaceRoot, sourcePublicationConfigPath)) fail(`${label}.configFile mismatch`)
  if (report.rootOwnerConfigFile !== path.join(workspaceRoot, sourcePublicationRootOwnerConfigPath)) fail(`${label}.rootOwnerConfigFile mismatch`)
  if (report.releasePrConfigFile !== path.join(workspaceRoot, releasePrConfigPath)) fail(`${label}.releasePrConfigFile mismatch`)
  assertAllowedKeys(report.totals, ['sources', 'passed', 'failed', 'staged', 'unstaged', 'untracked', 'unmerged'], `${label}.totals`)
  for (const field of ['sources', 'passed', 'failed', 'staged', 'unstaged', 'untracked', 'unmerged']) requireNumber(report.totals[field], `${label}.totals.${field}`)
  if (report.totals.sources !== 9 || report.totals.passed + report.totals.failed !== 9) fail(`${label}.totals must cover exactly nine source trees`)
  assertSourcePublicationSource(report.workspaceSource, `${label}.workspaceSource`)
  if (report.workspaceSource.path !== '.' || report.workspaceSource.repositoryPath !== workspaceRoot) fail(`${label}.workspaceSource identity mismatch`)
  assertPassedSourcePublicationSemantics(report.workspaceSource, `${label}.workspaceSource`, workspaceRoot, sourcePublicationWorkspaceRequiredFiles)
  if (!Array.isArray(report.repositories) || report.repositories.length !== sourcePublicationRepositories.length) fail(`${label}.repositories must contain eight rows`)
  for (const [index, source] of report.repositories.entries()) {
    assertSourcePublicationSource(source, `${label}.repositories[${index}]`)
    const [expectedPath, expectedRepository, expectedHead, expectedBase, expectedPr] = sourcePublicationRepositories[index]
    if (source.path !== expectedPath || source.repository !== expectedRepository || source.head !== expectedHead || source.base !== expectedBase || source.prNumber !== expectedPr) fail(`${label}.repositories[${index}] identity mismatch`)
    const expectedRepositoryPath = path.resolve(workspaceRoot, expectedPath)
    if (source.repositoryPath !== expectedRepositoryPath) fail(`${label}.repositories[${index}].repositoryPath mismatch`)
    assertPassedSourcePublicationSemantics(source, `${label}.repositories[${index}]`, expectedRepositoryPath, [])
  }
  const sources = [report.workspaceSource, ...report.repositories]
  const computed = sources.reduce((totals, source) => {
    totals[source.status] += 1
    totals.staged += source.stagedCount
    totals.unstaged += source.unstagedCount
    totals.untracked += source.untrackedCount
    totals.unmerged += source.unmergedCount
    return totals
  }, {passed: 0, failed: 0, staged: 0, unstaged: 0, untracked: 0, unmerged: 0})
  for (const field of Object.keys(computed)) if (computed[field] !== report.totals[field]) fail(`${label}.totals.${field} mismatch`)
  if ((report.totals.failed === 0 ? 'passed' : 'failed') !== report.status) fail(`${label}.status does not match source totals`)
}

function assertSourcePublicationConfig(content, label) {
  if (content.includes('\r') || content.includes('\0')) fail(`${label} must use LF text without NUL bytes`)
  const rows = content.split('\n').filter((line) => line && !line.startsWith('#')).map((line) => line.split('\t'))
  if (rows.length !== sourcePublicationRepositories.length) fail(`${label} must contain eight rows`)
  rows.forEach((row, index) => {
    if (row.length !== 5) fail(`${label} row ${index + 1} must contain five columns`)
    const [expectedPath, expectedRepository, expectedHead, expectedBase, expectedPr] = sourcePublicationRepositories[index]
    if (!/^[1-9][0-9]*$/.test(row[4]) || !Number.isSafeInteger(Number(row[4]))) fail(`${label} row ${index + 1} pull request must be canonical positive digits`)
    if (row[0] !== expectedPath || row[1] !== expectedRepository || row[2] !== expectedHead || row[3] !== expectedBase || row[4] !== String(expectedPr)) fail(`${label} row ${index + 1} identity mismatch`)
  })
}

function assertSourcePublicationRootOwnerConfig(config, label) {
  assertAllowedKeys(config, ['schemaVersion', 'status', 'repository', 'head', 'base', 'prNumber', 'lastReviewed', 'blocker'], label)
  if (config.schemaVersion !== 1) fail(`${label}.schemaVersion mismatch`)
  if (!['blocked', 'ready'].includes(config.status)) fail(`${label}.status must be blocked or ready`)
  const reviewedAt = parseUtcDate(config.lastReviewed, `${label}.lastReviewed`)
  assertNotFutureDate(reviewedAt, config.lastReviewed, `${label}.lastReviewed`, nowMs)
  if (config.status === 'blocked') {
    for (const field of ['repository', 'head', 'base', 'prNumber']) if (config[field] !== null) fail(`${label}.${field} must be null while blocked`)
    if (config.blocker !== 'canonical-root-source-owner-unassigned') fail(`${label}.blocker mismatch while blocked`)
    return
  }
  if (typeof config.repository !== 'string' || !/^[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+$/.test(config.repository)) fail(`${label}.repository must be an owner/repository slug while ready`)
  for (const field of ['head', 'base']) {
    if (typeof config[field] !== 'string' || !/^(?![./])(?!.*(?:\.\.|\/\/|@\{|\\))[A-Za-z0-9._/-]+(?<![./])$/.test(config[field])) fail(`${label}.${field} must be a safe Git ref while ready`)
  }
  if (!Number.isSafeInteger(config.prNumber) || config.prNumber <= 0) fail(`${label}.prNumber must be a positive safe integer while ready`)
  if (config.blocker !== null) fail(`${label}.blocker must be null while ready`)
}

function parseSourcePublicationReleasePrConfig(content, label) {
  if (content.includes('\r') || content.includes('\0')) fail(`${label} must use LF text without NUL bytes`)
  const rows = []
  const seen = new Set()
  for (const [index, line] of content.split('\n').entries()) {
    if (!line || line.startsWith('#')) continue
    const fields = line.split('\t')
    if (fields.length !== 5 || fields.some((field) => !field || field.trim() !== field)) fail(`${label} line ${index + 1} must contain five non-empty tab-separated fields`)
    const [repository, head, base, requiredState, requiredChecks] = fields
    if (!/^[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+$/.test(repository)) fail(`${label} line ${index + 1} repository must be owner/repository`)
    for (const [field, value] of [['head', head], ['base', base]]) {
      if (!/^(?![./])(?!.*(?:\.\.|\/\/|@\{|\\))[A-Za-z0-9._/-]+(?<![./])$/.test(value)) fail(`${label} line ${index + 1} ${field} must be a safe Git ref`)
    }
    if (!['open', 'merged'].includes(requiredState)) fail(`${label} line ${index + 1} required state must be open or merged`)
    if (requiredChecks.split(',').some((check) => !check || check.trim() !== check || /[\r\n\0]/.test(check))) fail(`${label} line ${index + 1} required checks must be canonical comma-separated names`)
    const identity = `${repository}\0${head}\0${base}`
    if (seen.has(identity)) fail(`${label} contains duplicate repository/head/base rows`)
    seen.add(identity)
    rows.push({repository, head, base, requiredState})
  }
  return rows
}

function assertSourcePublicationRootOwnerBinding(report, config, releasePrRows, label) {
  const source = report.workspaceSource
  if (config.status === 'blocked') {
    if (source.status !== 'failed') fail(`${label}.workspaceSource must fail while root owner config is blocked`)
    for (const field of ['repository', 'head', 'base', 'prNumber']) if (source[field] !== null) fail(`${label}.workspaceSource.${field} must be null while root owner config is blocked`)
    if (!source.failures.some((failure) => failure.includes('canonical-root-source-owner-unassigned'))) fail(`${label}.workspaceSource must record the blocked root-owner prerequisite`)
    return
  }
  for (const field of ['repository', 'head', 'base', 'prNumber']) {
    if (source[field] !== config[field]) fail(`${label}.workspaceSource.${field} must match root owner config`)
  }
  const releaseRows = releasePrRows.filter((row) => row.repository === config.repository && row.head === config.head && row.base === config.base)
  if (releaseRows.length !== 1 || releaseRows[0].requiredState !== 'merged') {
    fail(`${label}.root owner must have exactly one matching merged release PR config row`)
  }
}

function buildSourcePublicationHandoff(actionsManifest, summaryManifest, artifacts) {
  if (!actionsManifest.runLive) return null
  const source = resolveReportFile(sourcePublicationReportSourcePath, 'sourcePublicationHandoff.sourceReportPath')
  const report = readJson(source, 'sourcePublicationHandoff.sourceReport')
  assertSourcePublicationReport(report, sourcePublicationReportSourcePath, summaryGeneratedAtMs)
  const summaryCheck = summaryManifest.checks.find((check) => check.slug === 'source-publication-readiness')
  if (!summaryCheck || summaryCheck.status !== report.status) fail('source publication report status must match summary check')
  const configSource = resolveWorkspaceFile(sourcePublicationConfigPath, 'sourcePublicationHandoff.configPath')
  assertSourcePublicationConfig(fs.readFileSync(configSource, 'utf8'), 'sourcePublicationHandoff.config')
  const rootOwnerConfigSource = resolveWorkspaceFile(sourcePublicationRootOwnerConfigPath, 'sourcePublicationHandoff.rootOwnerConfigPath')
  const rootOwnerConfig = readJson(rootOwnerConfigSource, 'sourcePublicationHandoff.rootOwnerConfig')
  assertSourcePublicationRootOwnerConfig(rootOwnerConfig, 'sourcePublicationHandoff.rootOwnerConfig')
  const releasePrConfigSource = resolveWorkspaceFile(releasePrConfigPath, 'sourcePublicationHandoff.releasePrConfigPath')
  const releasePrConfigContent = fs.readFileSync(releasePrConfigSource, 'utf8')
  assertNoSecretLike('sourcePublicationHandoff.releasePrConfig', releasePrConfigContent)
  const releasePrRows = parseSourcePublicationReleasePrConfig(releasePrConfigContent, 'sourcePublicationHandoff.releasePrConfig')
  assertSourcePublicationRootOwnerBinding(report, rootOwnerConfig, releasePrRows, 'sourcePublicationHandoff')
  copyArtifact(source, sourcePublicationReportArtifactPath, artifacts)
  copyArtifact(configSource, sourcePublicationConfigArtifactPath, artifacts)
  copyArtifact(rootOwnerConfigSource, sourcePublicationRootOwnerConfigArtifactPath, artifacts)
  const reportArtifact = artifacts.find((artifact) => artifact.path === sourcePublicationReportArtifactPath)
  const configArtifact = artifacts.find((artifact) => artifact.path === sourcePublicationConfigArtifactPath)
  const rootOwnerConfigArtifact = artifacts.find((artifact) => artifact.path === sourcePublicationRootOwnerConfigArtifactPath)
  return {
    sourceReportPath: sourcePublicationReportSourcePath,
    reportArtifact: sourcePublicationReportArtifactPath,
    reportSha256: reportArtifact.sha256,
    configPath: sourcePublicationConfigPath,
    configArtifact: sourcePublicationConfigArtifactPath,
    configSha256: configArtifact.sha256,
    rootOwnerConfigPath: sourcePublicationRootOwnerConfigPath,
    rootOwnerConfigArtifact: sourcePublicationRootOwnerConfigArtifactPath,
    rootOwnerConfigSha256: rootOwnerConfigArtifact.sha256,
    rootOwnerStatus: rootOwnerConfig.status,
    status: report.status,
    checkRemote: report.checkRemote,
    sourceCount: report.totals.sources,
    passedCount: report.totals.passed,
    failedCount: report.totals.failed,
    workspaceOwned: report.workspaceSource.status === 'passed',
    repositories: report.repositories.map((sourceRow) => ({
      path: sourceRow.path,
      repository: sourceRow.repository,
      head: sourceRow.head,
      base: sourceRow.base,
      prNumber: sourceRow.prNumber,
      status: sourceRow.status,
      branch: sourceRow.branch,
      prHeadSha: sourceRow.prHeadSha,
      headSha: sourceRow.headSha,
      remoteHeadSha: sourceRow.remoteHeadSha,
      remoteBranchPresent: sourceRow.remoteBranchPresent,
      currentBranchRemoteSha: sourceRow.currentBranchRemoteSha,
      currentBranchRemotePresent: sourceRow.currentBranchRemotePresent,
      prUrl: sourceRow.prUrl,
      prState: sourceRow.prState,
      stagedCount: sourceRow.stagedCount,
      unstagedCount: sourceRow.unstagedCount,
      untrackedCount: sourceRow.untrackedCount,
      unmergedCount: sourceRow.unmergedCount,
    })),
  }
}

function parseReleasePrConfigRows(configPath, label) {
  assertRegularFile(configPath, label)
  const rowsByLine = new Map()
  const seen = new Set()
  const lines = fs.readFileSync(configPath, 'utf8').split(/\r?\n/)
  for (const [lineIndex, line] of lines.entries()) {
    const lineNumber = lineIndex + 1
    if (line.trim() === '' || /^\s*#/.test(line)) continue
    const columns = line.split('\t')
    if (columns.length !== 5 || columns.some((column) => column.trim() === '')) {
      fail(`${label}:${lineNumber} invalid release PR config line`)
    }
    const [repo, head, base, requiredState, requiredChecksRaw] = columns
    const rowLabel = `${label}:${lineNumber}`
    for (const [field, value] of Object.entries({ repo, head, base, requiredState })) {
      requireSingleLine(value, `${rowLabel}.${field}`)
      assertNoSecretLike(`${rowLabel}.${field}`, value)
    }
    const requiredChecks = requiredChecksRaw.split(',').map((part) => part.trim()).filter(Boolean)
    if (requiredChecks.length === 0) fail(`${rowLabel}.requiredChecks must be a non-empty list`)
    for (const [checkIndex, check] of requiredChecks.entries()) {
      requireSingleLine(check, `${rowLabel}.requiredChecks[${checkIndex}]`)
      assertNoSecretLike(`${rowLabel}.requiredChecks[${checkIndex}]`, check)
    }
    const key = `${repo}\t${head}\t${base}\t${requiredState}`
    if (seen.has(key)) fail(`${rowLabel} duplicate release PR requirement row`)
    seen.add(key)
    rowsByLine.set(lineNumber, { repo, head, base, requiredState, requiredChecks })
  }
  return rowsByLine
}

function assertReleasePrRequirementMatchesConfig(requirement, requirementLabel, configRows) {
  if (requirement.configLine === null) fail(`${requirementLabel}.configLine must reference ${releasePrConfigPath}`)
  const configRow = configRows.get(requirement.configLine)
  if (!configRow) fail(`${requirementLabel}.configLine must exist in ${releasePrConfigPath}`)
  for (const field of ['repo', 'head', 'base', 'requiredState']) {
    if (requirement[field] !== configRow[field]) {
      fail(`${requirementLabel}.${field} must match ${releasePrConfigPath} line ${requirement.configLine}`)
    }
  }
  if (requirement.requiredChecks.length !== configRow.requiredChecks.length) {
    fail(`${requirementLabel}.requiredChecks length must match ${releasePrConfigPath} line ${requirement.configLine}`)
  }
  for (const [checkIndex, check] of requirement.requiredChecks.entries()) {
    if (check !== configRow.requiredChecks[checkIndex]) {
      fail(`${requirementLabel}.requiredChecks[${checkIndex}] must match ${releasePrConfigPath} line ${requirement.configLine}`)
    }
  }
}

function assertReleasePrStatusReport(report, label) {
  assertAllowedKeys(report, ['schemaVersion', 'generatedAt', 'configFile', 'status', 'checkedCount', 'totals', 'failures', 'requirements'], label)
  if (report.schemaVersion !== 1) fail(`${label}.schemaVersion must be 1`)
  const reportGeneratedAtMs = parseUtcTimestamp(report.generatedAt, `${label}.generatedAt`)
  assertNotFutureTimestamp(reportGeneratedAtMs, report.generatedAt, `${label}.generatedAt`, nowMs)
  requireSingleLine(report.configFile, `${label}.configFile`)
  if (report.configFile.includes('\\') || !path.isAbsolute(report.configFile) || path.resolve(report.configFile) !== report.configFile) {
    fail(`${label}.configFile must be an absolute normalized path`)
  }
  if (report.configFile !== path.join(workspaceRoot, releasePrConfigPath)) {
    fail(`${label}.configFile must match ${releasePrConfigPath}`)
  }
  const releasePrConfigRows = parseReleasePrConfigRows(report.configFile, `${label}.configFile`)
  if (report.status !== 'failed' && report.status !== 'passed') fail(`${label}.status unsupported: ${report.status}`)
  requireNumber(report.checkedCount, `${label}.checkedCount`)
  assertAllowedKeys(report.totals, ['passed', 'failed', 'total'], `${label}.totals`)
  for (const key of ['passed', 'failed', 'total']) requireNumber(report.totals[key], `${label}.totals.${key}`)
  if (report.totals.passed + report.totals.failed !== report.totals.total) fail(`${label}.totals counts must sum to total`)
  if (report.checkedCount !== report.totals.total) fail(`${label}.checkedCount must match totals.total`)
  if (!Array.isArray(report.failures)) fail(`${label}.failures must be an array`)
  if (!Array.isArray(report.requirements)) fail(`${label}.requirements must be an array`)
  if (report.requirements.length !== report.totals.total) fail(`${label}.requirements length must match totals.total`)
  if (report.requirements.length !== releasePrConfigRows.size) fail(`${label}.requirements length must match ${releasePrConfigPath}`)
  if (report.failures.length !== report.totals.failed) fail(`${label}.failures length must match totals.failed`)
  if (report.status === 'failed' && report.totals.failed === 0) fail(`${label}.status failed requires failed total`)
  if (report.status === 'passed' && report.totals.failed !== 0) fail(`${label}.status passed requires zero failures`)
  for (const [index, failure] of report.failures.entries()) {
    requireSingleLine(failure, `${label}.failures[${index}]`)
    assertNoSecretLike(`${label}.failures[${index}]`, failure)
  }
  const failedRequirementMessages = []
  let previousConfigLine = 0
  for (const [index, requirement] of report.requirements.entries()) {
    const requirementLabel = `${label}.requirements[${index}]`
    assertAllowedKeys(requirement, [
      'status',
      'configLine',
      'repo',
      'head',
      'base',
      'requiredState',
      'requiredChecks',
      'message',
      'pr',
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
    ], `${label}.requirements[${index}]`)
    if (requirement.status !== 'passed' && requirement.status !== 'failed') fail(`${label}.requirements[${index}].status unsupported`)
    if (requirement.configLine !== null) requireNumber(requirement.configLine, `${label}.requirements[${index}].configLine`)
    if (requirement.configLine !== null && requirement.configLine <= previousConfigLine) {
      fail(`${requirementLabel}.configLine must match ${releasePrConfigPath} order`)
    }
    if (requirement.configLine !== null) previousConfigLine = requirement.configLine
    for (const key of ['repo', 'head', 'base', 'requiredState', 'message']) {
      requireSingleLine(requirement[key], `${label}.requirements[${index}].${key}`)
      assertNoSecretLike(`${label}.requirements[${index}].${key}`, requirement[key])
    }
    const failureMessagePattern = /(is open and is not release-ready|closed without merge|no merged pull request found|has new commits after merge|required checks are not release-ready|no release PR requirements were found)/
    const successMessagePattern = /is merged with required checks/
    if (requirement.status === 'passed' && failureMessagePattern.test(requirement.message)) {
      fail(`${label}.requirements[${index}].message contradicts passed status`)
    }
    if (requirement.status === 'failed' && successMessagePattern.test(requirement.message)) {
      fail(`${label}.requirements[${index}].message contradicts failed status`)
    }
    const reviewDecisionDiagnostic = requirement.message.match(/reviewDecision=([^\s]+)/)
    if (reviewDecisionDiagnostic && requirement.reviewDecision !== reviewDecisionDiagnostic[1]) {
      fail(`${label}.requirements[${index}].reviewDecision must match message diagnostic`)
    }
    const mergeStateStatusDiagnostic = requirement.message.match(/mergeStateStatus=([^\s]+)/)
    if (mergeStateStatusDiagnostic && requirement.mergeStateStatus !== mergeStateStatusDiagnostic[1]) {
      fail(`${label}.requirements[${index}].mergeStateStatus must match message diagnostic`)
    }
    for (const booleanDiagnosticField of ['isDraft', 'eligibleReviewerApprovalRequired', 'currentApprovalNotEligible', 'freshApprovalRequired']) {
      const booleanDiagnostic = requirement.message.match(new RegExp(`${booleanDiagnosticField}=([^\\s]+)`))
      if (booleanDiagnostic && requirement[booleanDiagnosticField] !== (booleanDiagnostic[1] === 'true')) {
        fail(`${label}.requirements[${index}].${booleanDiagnosticField} must match message diagnostic`)
      }
    }
    for (const countDiagnosticField of ['approvalCount', 'currentHeadApprovalCount', 'staleApprovalCount', 'unresolvedReviewThreads', 'currentUnresolvedReviewThreads', 'outdatedUnresolvedReviewThreads']) {
      const countDiagnostic = requirement.message.match(new RegExp(`${countDiagnosticField}=([^\\s]+)`))
      if (countDiagnostic && requirement[countDiagnosticField] !== Number(countDiagnostic[1])) {
        fail(`${label}.requirements[${index}].${countDiagnosticField} must match message diagnostic`)
      }
    }
    if (!/^[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+$/.test(requirement.repo)) fail(`${label}.requirements[${index}].repo has unsupported format`)
    if (!Array.isArray(requirement.requiredChecks) || requirement.requiredChecks.length === 0) fail(`${label}.requirements[${index}].requiredChecks must be a non-empty array`)
    for (const [checkIndex, check] of requirement.requiredChecks.entries()) {
      requireSingleLine(check, `${label}.requirements[${index}].requiredChecks[${checkIndex}]`)
    }
    assertReleasePrRequirementMatchesConfig(requirement, requirementLabel, releasePrConfigRows)
    const successRequiredChecksDiagnostic = requirement.message.match(/ is merged with required checks ([^:]+): /)
    if (successRequiredChecksDiagnostic) {
      const messageRequiredChecks = successRequiredChecksDiagnostic[1].split(',')
      if (
        messageRequiredChecks.length !== requirement.requiredChecks.length ||
        messageRequiredChecks.some((check, checkIndex) => check !== requirement.requiredChecks[checkIndex])
      ) {
        fail(`${label}.requirements[${index}].requiredChecks must match success message`)
      }
    }
    const messageContainsPrReference = (
      /^[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+#[1-9][0-9]*\b/.test(requirement.message) ||
      /\bhttps:\/\/github\.com\/[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+\/pull\/[1-9][0-9]*(?:\s|$)/.test(requirement.message)
    )
    if (messageContainsPrReference && requirement.pr === undefined) {
      fail(`${label}.requirements[${index}].pr required when message contains PR reference`)
    }
    if (requirement.pr !== undefined) {
      assertAllowedKeys(requirement.pr, ['repo', 'number', 'url'], `${label}.requirements[${index}].pr`)
      if (requirement.pr.repo !== requirement.repo) fail(`${label}.requirements[${index}].pr.repo must match requirement repo`)
      requireNumber(requirement.pr.number, `${label}.requirements[${index}].pr.number`)
      if (requirement.pr.number <= 0) fail(`${label}.requirements[${index}].pr.number must be positive`)
      requireSingleLine(requirement.pr.url, `${label}.requirements[${index}].pr.url`)
      if (requirement.pr.url !== `https://github.com/${requirement.repo}/pull/${requirement.pr.number}`) {
        fail(`${label}.requirements[${index}].pr.url mismatch`)
      }
      const expectedPrReference = `${requirement.repo}#${requirement.pr.number}`
      if (!requirement.message.startsWith(`${expectedPrReference} `)) {
        fail(`${label}.requirements[${index}].message must start with PR reference`)
      }
      const prUrlTokenPattern = new RegExp(`(?:^|\\s)${escapeRegExp(requirement.pr.url)}(?:\\s|$)`)
      if (!prUrlTokenPattern.test(requirement.message)) {
        fail(`${label}.requirements[${index}].message must include PR URL`)
      }
    }
    for (const key of ['isDraft', 'eligibleReviewerApprovalRequired', 'currentApprovalNotEligible', 'freshApprovalRequired']) {
      if (requirement[key] !== undefined) requireBoolean(requirement[key], `${label}.requirements[${index}].${key}`)
    }
    if (requirement.reviewDetails !== undefined && !['unavailable', 'malformed'].includes(requirement.reviewDetails)) {
      fail(`${label}.requirements[${index}].reviewDetails must be unavailable or malformed`)
    }
    if (requirement.reviewDetails !== undefined) {
      for (const staleField of ['approvalCount', 'currentHeadApprovalCount', 'staleApprovalCount', 'latestApprovalCommit', 'currentApprovalNotEligible', 'freshApprovalRequired']) {
        if (requirement[staleField] !== undefined) fail(`${label}.requirements[${index}].${staleField} must be omitted when reviewDetails is ${requirement.reviewDetails}`)
      }
    }
    for (const key of ['approvalCount', 'currentHeadApprovalCount', 'staleApprovalCount', 'unresolvedReviewThreads', 'currentUnresolvedReviewThreads', 'outdatedUnresolvedReviewThreads']) {
      if (requirement[key] !== undefined) requireNumber(requirement[key], `${label}.requirements[${index}].${key}`)
    }
    if (requirement.latestApprovalCommit !== undefined && !/^[0-9a-f]{40}$/i.test(requirement.latestApprovalCommit)) {
      fail(`${label}.requirements[${index}].latestApprovalCommit must be a 40-character hex commit`)
    }
    const requiresApprovalDiagnostics = (
      requirement.eligibleReviewerApprovalRequired === true &&
      requirement.reviewDetails === undefined
    )
    const hasApprovalDiagnostics = [
      'approvalCount',
      'currentHeadApprovalCount',
      'staleApprovalCount',
      'latestApprovalCommit',
      'currentApprovalNotEligible',
      'freshApprovalRequired',
    ].some((key) => requirement[key] !== undefined)
    if (requiresApprovalDiagnostics) {
      if (requirement.approvalCount === undefined) fail(`${requirementLabel}.approvalCount required when eligibleReviewerApprovalRequired is true`)
      if (requirement.currentHeadApprovalCount === undefined) fail(`${requirementLabel}.currentHeadApprovalCount required when eligibleReviewerApprovalRequired is true`)
    }
    if (hasApprovalDiagnostics) {
      if (requirement.approvalCount === undefined) fail(`${requirementLabel}.approvalCount required when approval diagnostics are present`)
      if (requirement.currentHeadApprovalCount === undefined) fail(`${requirementLabel}.currentHeadApprovalCount required when approval diagnostics are present`)
      const staleApprovalCount = requirement.staleApprovalCount || 0
      if (requirement.currentHeadApprovalCount > requirement.approvalCount) fail(`${requirementLabel}.currentHeadApprovalCount must not exceed approvalCount`)
      if (staleApprovalCount > requirement.approvalCount) fail(`${requirementLabel}.staleApprovalCount must not exceed approvalCount`)
      if (requirement.latestApprovalCommit !== undefined && requirement.approvalCount === 0) fail(`${requirementLabel}.latestApprovalCommit requires approvalCount`)
      if (requirement.currentApprovalNotEligible && requirement.freshApprovalRequired) fail(`${requirementLabel}.currentApprovalNotEligible and freshApprovalRequired cannot both be true`)
      if (requirement.currentApprovalNotEligible && requirement.currentHeadApprovalCount === 0) fail(`${requirementLabel}.currentApprovalNotEligible requires currentHeadApprovalCount`)
      if (requirement.freshApprovalRequired && requirement.approvalCount === 0) fail(`${requirementLabel}.freshApprovalRequired requires approvalCount`)
      if (requirement.freshApprovalRequired && requirement.currentHeadApprovalCount !== 0) fail(`${requirementLabel}.freshApprovalRequired requires currentHeadApprovalCount=0`)
      if (requirement.approvalCount > 0 && requirement.currentHeadApprovalCount > 0 && !requirement.currentApprovalNotEligible) {
        fail(`${requirementLabel}.currentApprovalNotEligible must be true when current-head approvals are present`)
      }
      if (requirement.approvalCount > 0 && requirement.currentHeadApprovalCount === 0 && !requirement.freshApprovalRequired) {
        fail(`${requirementLabel}.freshApprovalRequired must be true when only stale approvals are present`)
      }
    }
    const reviewThreadCountFields = [
      'unresolvedReviewThreads',
      'currentUnresolvedReviewThreads',
      'outdatedUnresolvedReviewThreads',
    ]
    const hasReviewThreadDiagnostics = reviewThreadCountFields.some((key) => requirement[key] !== undefined)
    if (hasReviewThreadDiagnostics) {
      for (const key of reviewThreadCountFields) {
        if (requirement[key] === undefined) fail(`${requirementLabel}.${key} required when review-thread diagnostics are present`)
      }
      if (requirement.currentUnresolvedReviewThreads + requirement.outdatedUnresolvedReviewThreads !== requirement.unresolvedReviewThreads) {
        fail(`${requirementLabel}.currentUnresolvedReviewThreads plus outdatedUnresolvedReviewThreads must equal unresolvedReviewThreads`)
      }
      const hasResolutionRequiredFlag = /\breviewConversationResolutionRequired=true\b/.test(requirement.message)
      const hasOutdatedOnlyFlag = /\boutdatedReviewThreadsStillBlockMerge=true\b/.test(requirement.message)
      if (requirement.unresolvedReviewThreads > 0 && !hasResolutionRequiredFlag) {
        fail(`${requirementLabel}.message must include reviewConversationResolutionRequired=true when unresolvedReviewThreads is positive`)
      }
      if (requirement.unresolvedReviewThreads === 0 && hasResolutionRequiredFlag) {
        fail(`${requirementLabel}.message must not include reviewConversationResolutionRequired=true when unresolvedReviewThreads is zero`)
      }
      if (requirement.currentUnresolvedReviewThreads === 0 && requirement.outdatedUnresolvedReviewThreads > 0 && !hasOutdatedOnlyFlag) {
        fail(`${requirementLabel}.message must include outdatedReviewThreadsStillBlockMerge=true when only outdated review threads remain`)
      }
      if ((requirement.currentUnresolvedReviewThreads !== 0 || requirement.outdatedUnresolvedReviewThreads === 0) && hasOutdatedOnlyFlag) {
        fail(`${requirementLabel}.message must not include outdatedReviewThreadsStillBlockMerge=true unless only outdated review threads remain`)
      }
    }
    if (requirement.status === 'failed') failedRequirementMessages.push(requirement.message)
  }
  if (report.failures.length !== failedRequirementMessages.length) fail(`${label}.failures must match failed requirement messages`)
  for (const [index, message] of failedRequirementMessages.entries()) {
    if (report.failures[index] !== message) fail(`${label}.failures[${index}] must match failed requirement message`)
  }
}

function isReleasePrLogResultMessage(message) {
  return (
    /^[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+#[1-9][0-9]* is merged with required checks [^:]+: https:\/\/github\.com\/[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+\/pull\/[1-9][0-9]*$/.test(message) ||
    /^[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+#[1-9][0-9]* is open and is not release-ready: https:\/\/github\.com\/[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+\/pull\/[1-9][0-9]*(?:\s|$)/.test(message) ||
    /^[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+#[1-9][0-9]* is merged but head branch '[^']+' has new commits after merge: https:\/\/github\.com\/[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+\/pull\/[1-9][0-9]*(?:\s|$)/.test(message) ||
    /^[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+#[1-9][0-9]* is merged but required checks are not release-ready: https:\/\/github\.com\/[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+\/pull\/[1-9][0-9]*(?:\s|$)/.test(message) ||
    /^[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+#[1-9][0-9]* is closed without merge: https:\/\/github\.com\/[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+\/pull\/[1-9][0-9]*$/.test(message) ||
    /^[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+:[^\s]+ -> [^\s]+: no merged pull request found$/.test(message) ||
    /: no release PR requirements were found$/.test(message)
  )
}

function releasePrLogResultMessages(logContent) {
  const messages = []
  const releasePrWarningPrefix = '[release-pr-readiness][warn] '
  const releasePrSummaryPrefix = '  - '
  const seen = new Set()
  for (const line of String(logContent).replace(/\r\n/g, '\n').split('\n')) {
    if (!line) continue
    let message = null
    if (line.startsWith(releasePrWarningPrefix)) {
      message = line.slice(releasePrWarningPrefix.length)
    } else if (line.startsWith(releasePrSummaryPrefix)) {
      message = line.slice(releasePrSummaryPrefix.length)
    } else if (!line.startsWith('[release-pr-readiness]')) {
      message = line
    }
    if (message && isReleasePrLogResultMessage(message) && !seen.has(message)) {
      seen.add(message)
      messages.push(message)
    }
  }
  return messages
}

function assertReleasePrStatusReportFailuresMatchLog(report, logContent, label) {
  const logFailures = new Set(releasePrLogResultMessages(logContent))
  for (const [index, failure] of report.failures.entries()) {
    if (!logFailures.has(failure)) fail(`${label}.failures[${index}] must be present in release PR log as a full failure line`)
  }
}

function assertReleasePrStatusReportRequirementsMatchLog(report, logContent, label) {
  const logMessages = new Set(releasePrLogResultMessages(logContent))
  for (const [index, requirement] of report.requirements.entries()) {
    if (!logMessages.has(requirement.message)) fail(`${label}.requirements[${index}].message must be present in release PR log as a full result line`)
  }
}

function assertReleasePrStatusReportLogResultsMatchRequirements(report, logContent, label) {
  const requirementMessages = new Set(report.requirements.map((requirement) => requirement.message))
  for (const [index, message] of releasePrLogResultMessages(logContent).entries()) {
    if (!requirementMessages.has(message)) fail(`${label}.logResults[${index}] must match a status report requirement message`)
  }
}

function buildReleasePrStatusReportHandoff(blockerSlug, artifacts) {
  if (blockerSlug !== 'release-pr-readiness') return null
  const source = resolveReportFile(releasePrStatusReportSourcePath, `${blockerSlug}.releasePrStatusReportHandoff.sourceReportPath`)
  const report = readJson(source, `${blockerSlug}.releasePrStatusReportHandoff.sourceReport`)
  assertReleasePrStatusReport(report, releasePrStatusReportSourcePath)
  copyCheckedArtifact(source, releasePrStatusReportArtifactPath, artifacts)
  const record = artifacts.find((artifact) => artifact.path === releasePrStatusReportArtifactPath)
  return {
    sourceReportPath: source,
    reportArtifact: releasePrStatusReportArtifactPath,
    reportSha256: record.sha256,
    configPath: releasePrConfigPath,
    status: report.status,
    checkedCount: report.checkedCount,
    failedCount: report.totals.failed,
    requiredPrCount: report.totals.total,
    blockedPrs: report.requirements
      .filter((requirement) => requirement.status === 'failed' && requirement.pr)
      .map((requirement) => ({
        repo: requirement.pr.repo,
        pr: String(requirement.pr.number),
        url: requirement.pr.url,
        configLine: requirement.configLine,
        head: requirement.head,
        base: requirement.base,
        requiredState: requirement.requiredState,
        requiredChecks: [...requirement.requiredChecks],
        reviewDecision: requirement.reviewDecision || 'UNKNOWN',
        mergeStateStatus: requirement.mergeStateStatus || 'UNKNOWN',
      })),
    dryRunCommand: 'bash scripts/merge-release-prs.sh --dry-run --config config/release-readiness-prs.tsv',
  }
}

function releasePrApprovalRecordsFromStatusReport(report) {
  return report.requirements
    .filter((requirement) => (
      requirement.status === 'failed' &&
      requirement.pr &&
      requirement.eligibleReviewerApprovalRequired === true &&
      requirement.unresolvedReviewThreads === 0 &&
      requirement.currentUnresolvedReviewThreads === 0 &&
      requirement.outdatedUnresolvedReviewThreads === 0
    ))
    .map((requirement) => {
      const record = {
        repo: requirement.pr.repo,
        pr: String(requirement.pr.number),
        url: requirement.pr.url,
        reviewDecision: requirement.reviewDecision || 'UNKNOWN',
        mergeStateStatus: requirement.mergeStateStatus || 'UNKNOWN',
        requiredAction: requirement.reviewDetails
          ? 'restore review details for eligible reviewer approval'
          : 'eligible reviewer approval',
        eligibleReviewerApprovalRequired: true,
      }
      if (requirement.reviewDetails) {
        record.reviewDetails = requirement.reviewDetails
        return record
      }
      record.approvalCount = requirement.approvalCount
      record.currentHeadApprovalCount = requirement.currentHeadApprovalCount
      record.staleApprovalCount = requirement.staleApprovalCount || 0
      if (requirement.latestApprovalCommit !== undefined) record.latestApprovalCommit = requirement.latestApprovalCommit
      record.currentApprovalNotEligible = requirement.currentApprovalNotEligible === true
      record.freshApprovalRequired = requirement.freshApprovalRequired === true
      return record
    })
}

function assertReleasePrApprovalHandoffMatchesStatusReport(value, report, label) {
  const expected = releasePrApprovalRecordsFromStatusReport(report)
  if (value.prs.length !== expected.length) fail(`${label}.prs length must match status report approval blockers`)
  for (const [index, pr] of value.prs.entries()) {
    const prLabel = `${label}.prs[${index}]`
    const expectedPr = expected[index]
    if (!expectedPr || `${pr.repo}#${pr.pr}` !== `${expectedPr.repo}#${expectedPr.pr}`) {
      fail(`${prLabel} must match status report approval order`)
    }
    for (const field of ['repo', 'pr', 'url', 'reviewDecision', 'mergeStateStatus', 'requiredAction', 'eligibleReviewerApprovalRequired', 'reviewDetails', 'approvalCount', 'currentHeadApprovalCount', 'staleApprovalCount', 'latestApprovalCommit', 'currentApprovalNotEligible', 'freshApprovalRequired']) {
      if (pr[field] !== expectedPr[field]) fail(`${prLabel}.${field} must match status report`)
    }
  }
}

function resolveReportFile(logFile, label) {
  requireString(logFile, label)
  assertNoSecretLike(label, logFile)
  if (logFile.includes('\\')) fail(`${label} must use forward slashes: ${logFile}`)

  let resolved
  if (path.isAbsolute(logFile)) {
    resolved = path.resolve(logFile)
    if (resolved !== logFile) fail(`${label} must be absolute normalized or relative normalized path`)
  } else {
    const normalized = path.posix.normalize(logFile)
    if (normalized === '.' || normalized.startsWith('../') || normalized.includes('/../') || normalized !== logFile) {
      fail(`${label} must be absolute normalized or relative normalized path`)
    }
    resolved = path.resolve(reportRoot, normalized)
  }
  if (resolved !== reportRoot && !resolved.startsWith(reportRoot + path.sep)) {
    fail(`${label} points outside release-readiness report dir: ${logFile}`)
  }
  if (!fs.existsSync(resolved)) {
    fail(`${label} missing: ${resolved}`)
  }
  assertNoSymlinkPathPrefix(resolved, label, [reportRoot, workspaceRoot])
  return resolved
}

function resolveWorkspaceFile(relativePath, label) {
  requireString(relativePath, label)
  if (path.isAbsolute(relativePath) || relativePath.includes('\\')) {
    fail(`${label} must be a workspace-relative normalized path`)
  }
  const normalized = path.posix.normalize(relativePath)
  if (normalized === '.' || normalized.startsWith('../') || normalized.includes('/../') || normalized !== relativePath) {
    fail(`${label} must be a workspace-relative normalized path`)
  }
  const resolved = path.resolve(workspaceRoot, normalized)
  if (resolved !== workspaceRoot && !resolved.startsWith(workspaceRoot + path.sep)) {
    fail(`${label} points outside workspace root: ${relativePath}`)
  }
  if (!fs.existsSync(resolved)) {
    fail(`${label} missing: ${resolved}`)
  }
  assertNoSymlinkPathPrefix(resolved, label, [workspaceRoot])
  const realResolved = fs.realpathSync.native(resolved)
  const realWorkspaceRoot = fs.realpathSync.native(workspaceRoot)
  if (realResolved !== realWorkspaceRoot && !realResolved.startsWith(realWorkspaceRoot + path.sep)) {
    fail(`${label} must not alias outside workspace root through symlinks: ${relativePath}`)
  }
  return resolved
}

function assertXcmRegistryGapReport(report, label) {
  assertAllowedKeys(report, ['schemaVersion', 'registryFile', 'summary', 'missingExecutableDestinations'], label)
  if (report.schemaVersion !== 1) fail(`${label}.schemaVersion must be 1`)
  requireSingleLine(report.registryFile, `${label}.registryFile`)
  const summaryFields = [
    'chains',
    'xcmChains',
    'destinations',
    'routeAssets',
    'executableDestinations',
    'executableRouteAssets',
    'remainingDiscoveryOnlyDestinations',
    'remainingDiscoveryOnlyRouteAssets',
  ]
  assertAllowedKeys(report.summary, summaryFields, `${label}.summary`)
  for (const key of summaryFields) {
    requireNumber(report.summary[key], `${label}.summary.${key}`)
  }
  if (!Array.isArray(report.missingExecutableDestinations)) {
    fail(`${label}.missingExecutableDestinations must be an array`)
  }
  if (report.missingExecutableDestinations.length !== report.summary.remainingDiscoveryOnlyDestinations) {
    fail(`${label}.missingExecutableDestinations length must match summary.remainingDiscoveryOnlyDestinations`)
  }
  let remainingDiscoveryOnlyRouteAssets = 0
  for (const [index, route] of report.missingExecutableDestinations.entries()) {
    assertAllowedKeys(route, [
      'originChainId',
      'originName',
      'destinationChainId',
      'destinationName',
      'assetSymbols',
      'bridgeParachainId',
      'reason',
    ], `${label}.missingExecutableDestinations[${index}]`)
    for (const key of ['originChainId', 'originName', 'destinationChainId', 'destinationName', 'reason']) {
      requireSingleLine(route[key], `${label}.missingExecutableDestinations[${index}].${key}`)
    }
    if (route.reason !== 'missingExecutionSpec') {
      fail(`${label}.missingExecutableDestinations[${index}].reason must be missingExecutionSpec`)
    }
    if (!Array.isArray(route.assetSymbols) || route.assetSymbols.length === 0) {
      fail(`${label}.missingExecutableDestinations[${index}].assetSymbols must be a non-empty array`)
    }
    remainingDiscoveryOnlyRouteAssets += route.assetSymbols.length
    for (const [assetIndex, symbol] of route.assetSymbols.entries()) {
      requireSingleLine(symbol, `${label}.missingExecutableDestinations[${index}].assetSymbols[${assetIndex}]`)
    }
    if (route.bridgeParachainId !== null) {
      requireSingleLine(route.bridgeParachainId, `${label}.missingExecutableDestinations[${index}].bridgeParachainId`)
    }
  }
  if (remainingDiscoveryOnlyRouteAssets !== report.summary.remainingDiscoveryOnlyRouteAssets) {
    fail(`${label}.summary.remainingDiscoveryOnlyRouteAssets must match the sum of missingExecutableDestinations[].assetSymbols lengths`)
  }
}

const xcmEffectiveRegistrySourcePath = 'android-xcm-effective-registry-report.json'
const xcmEffectiveRegistryArtifactPath = 'handoffs/android-xcm-effective-registry-report.json'
const xcmEffectiveRegistryGeneratedPath = 'fearless-Android/build/reports/xcm-effective-registry-report.json'
const xcmProductionDiscoveryUrl = 'https://raw.githubusercontent.com/soramitsu/shared-features-utils/master/chains/v13/chains.json'
const xcmEffectiveRegistryLocalInputs = {
  approvedRoutes: 'runtime/src/main/assets/approved_xcm_routes.tsv',
  requiredRoutes: 'scripts/xcm-required-routes.tsv',
  bundledRegistry: 'runtime/src/main/assets/local_chains.json',
}
const xcmEffectiveRegistryPolicy = {
  transactionAuthority: 'apk-approved-intersection',
  effectiveRouteMeaning: 'compatible-approved-candidate',
  remoteExecutionTrusted: false,
  productionTransfersEnabled: false,
  unapprovedDiscoveryRoutesExecutable: false,
  runtimeDiscoveryRole: 'narrowing-advisory-only',
  runtimeDiscoveryStorage: 'current-process-successful-sync-snapshot',
  runtimeDiscoveryRequiresSuccessfulProcessSync: true,
  runtimeDiscoverySnapshotBoundToReport: false,
  runtimeDiscoveryFreshnessEnforced: false,
  releaseDiscoveryUrl: xcmProductionDiscoveryUrl,
}
const xcmEffectiveRegistryReasons = [
  'not-discovered',
  'remote-destination-not-single-asset',
  'destination-chain-not-discovered',
  'origin-core-asset-not-single',
  'origin-xcm-version-mismatch',
  'origin-xcm-chain-mismatch',
  'origin-parent-chain-mismatch',
  'origin-parachain-mismatch',
  'destination-parent-chain-mismatch',
  'destination-parachain-mismatch',
  'bridge-parachain-mismatch',
  'asset-id-mismatch',
  'asset-symbol-mismatch',
  'min-amount-mismatch',
  'origin-asset-id-mismatch',
  'origin-asset-precision-mismatch',
]
const xcmEffectiveRegistryAuditCommands = {
  bundled: 'cd fearless-Android && bash scripts/audit-xcm-effective-registry.sh --write-report build/reports/xcm-effective-registry-report.json',
  discovery: `cd fearless-Android && bash scripts/audit-xcm-effective-registry.sh --discovery-url ${xcmProductionDiscoveryUrl} --require-all-approved --write-report build/reports/xcm-effective-registry-report.json`,
}

function assertXcmEffectiveContentIdentity(value, label, expectedSource) {
  assertAllowedKeys(value, ['source', 'byteLength', 'sha256'], label)
  requireSingleLine(value.source, `${label}.source`)
  assertNoSecretLike(`${label}.source`, value.source)
  if (value.source !== expectedSource) fail(`${label}.source mismatch`)
  requireNumber(value.byteLength, `${label}.byteLength`)
  if (value.byteLength === 0) fail(`${label}.byteLength must be positive`)
  requireString(value.sha256, `${label}.sha256`)
  if (!/^[a-f0-9]{64}$/.test(value.sha256)) fail(`${label}.sha256 must be lowercase SHA-256`)
}

function xcmEffectiveRouteKey(route) {
  return `${route.originChainId}|${route.destinationChainId}|${route.assetSymbol}`
}

function assertXcmEffectiveRouteIdentity(route, label, allowedKeys) {
  assertAllowedKeys(route, allowedKeys, label)
  for (const field of ['originChainId', 'destinationChainId', 'assetSymbol']) {
    requireSingleLine(route[field], `${label}.${field}`)
    assertNoSecretLike(`${label}.${field}`, route[field])
  }
  if (!/^[a-f0-9]{64}$/.test(route.originChainId)) fail(`${label}.originChainId must be a lowercase 32-byte hex identity`)
  if (!/^[a-f0-9]{64}$/.test(route.destinationChainId)) fail(`${label}.destinationChainId must be a lowercase 32-byte hex identity`)
  if (!/^[A-Z0-9][A-Z0-9._-]{0,31}$/.test(route.assetSymbol)) fail(`${label}.assetSymbol must be canonical uppercase`)
}

function assertXcmEffectiveReasons(reasons, label) {
  if (!Array.isArray(reasons)) fail(`${label} must be an array`)
  let previousIndex = -1
  const seen = new Set()
  for (const [index, reason] of reasons.entries()) {
    requireSingleLine(reason, `${label}[${index}]`)
    const reasonIndex = xcmEffectiveRegistryReasons.indexOf(reason)
    if (reasonIndex < 0) fail(`${label}[${index}] unsupported: ${reason}`)
    if (seen.has(reason)) fail(`${label} must not contain duplicate reasons`)
    if (reasonIndex <= previousIndex) fail(`${label} must use deterministic reason order`)
    seen.add(reason)
    previousIndex = reasonIndex
  }
}

function assertXcmEffectiveSortedUniqueRoutes(routes, label, allowedKeys, validateRoute) {
  if (!Array.isArray(routes)) fail(`${label} must be an array`)
  let previousKey = null
  const keys = new Set()
  for (const [index, route] of routes.entries()) {
    const routeLabel = `${label}[${index}]`
    assertXcmEffectiveRouteIdentity(route, routeLabel, allowedKeys)
    validateRoute(route, routeLabel)
    const key = xcmEffectiveRouteKey(route)
    if (keys.has(key)) fail(`${label} contains duplicate route: ${key}`)
    if (previousKey !== null && previousKey.localeCompare(key) >= 0) fail(`${label} must use deterministic route order`)
    keys.add(key)
    previousKey = key
  }
  return keys
}

function assertXcmEffectiveWorkspaceInputParity(report, label, requireSources) {
  for (const [inputName, relativeSource] of Object.entries(xcmEffectiveRegistryLocalInputs)) {
    const workspaceRelative = `fearless-Android/${relativeSource}`
    const absolute = path.resolve(workspaceRoot, workspaceRelative)
    if (!fs.existsSync(absolute)) {
      if (requireSources) fail(`${label}.inputs.${inputName} workspace source missing: ${workspaceRelative}`)
      continue
    }
    const source = resolveWorkspaceFile(workspaceRelative, `${label}.inputs.${inputName}.workspaceSource`)
    assertRegularFile(source, `${label}.inputs.${inputName}.workspaceSource`)
    const content = fs.readFileSync(source)
    if (content.length !== report.inputs[inputName].byteLength) fail(`${label}.inputs.${inputName}.byteLength does not match workspace source`)
    if (sha256(content) !== report.inputs[inputName].sha256) fail(`${label}.inputs.${inputName}.sha256 does not match workspace source`)
  }
}

function assertXcmEffectiveRegistryReport(report, label, runLive, requireWorkspaceSources = false) {
  assertAllowedKeys(report, ['schemaVersion', 'mode', 'status', 'policy', 'inputs', 'summary', 'routes', 'missing', 'extra'], label)
  if (report.schemaVersion !== 1) fail(`${label}.schemaVersion must be 1`)
  if (!['bundled', 'discovery'].includes(report.mode)) fail(`${label}.mode must be bundled or discovery`)
  if (!['complete', 'incomplete'].includes(report.status)) fail(`${label}.status must be complete or incomplete`)
  const expectedMode = runLive ? 'discovery' : 'bundled'
  if (report.mode !== expectedMode) fail(`${label}.mode must be ${expectedMode} when runLive=${runLive}`)

  assertAllowedKeys(report.policy, Object.keys(xcmEffectiveRegistryPolicy), `${label}.policy`)
  for (const [key, expected] of Object.entries(xcmEffectiveRegistryPolicy)) {
    if (typeof expected === 'boolean') {
      requireBoolean(report.policy[key], `${label}.policy.${key}`)
    } else {
      requireSingleLine(report.policy[key], `${label}.policy.${key}`)
    }
    if (report.policy[key] !== expected) fail(`${label}.policy.${key} mismatch`)
  }

  assertAllowedKeys(report.inputs, ['approvedRoutes', 'requiredRoutes', 'bundledRegistry', 'discoveryRegistry'], `${label}.inputs`)
  for (const [inputName, source] of Object.entries(xcmEffectiveRegistryLocalInputs)) {
    assertXcmEffectiveContentIdentity(report.inputs[inputName], `${label}.inputs.${inputName}`, source)
  }
  if (report.mode === 'bundled') {
    if (report.inputs.discoveryRegistry !== null) fail(`${label}.inputs.discoveryRegistry must be null in bundled mode`)
  } else {
    const discovery = report.inputs.discoveryRegistry
    assertAllowedKeys(discovery, ['kind', 'source', 'byteLength', 'sha256'], `${label}.inputs.discoveryRegistry`)
    if (!['file', 'https'].includes(discovery.kind)) fail(`${label}.inputs.discoveryRegistry.kind must be file or https`)
    requireSingleLine(discovery.source, `${label}.inputs.discoveryRegistry.source`)
    assertNoSecretLike(`${label}.inputs.discoveryRegistry.source`, discovery.source)
    requireNumber(discovery.byteLength, `${label}.inputs.discoveryRegistry.byteLength`)
    if (discovery.byteLength === 0) fail(`${label}.inputs.discoveryRegistry.byteLength must be positive`)
    requireString(discovery.sha256, `${label}.inputs.discoveryRegistry.sha256`)
    if (!/^[a-f0-9]{64}$/.test(discovery.sha256)) fail(`${label}.inputs.discoveryRegistry.sha256 must be lowercase SHA-256`)
    if (runLive && discovery.kind !== 'https') fail(`${label}.inputs.discoveryRegistry.kind must be https for a live report`)
    if (runLive && discovery.source !== xcmProductionDiscoveryUrl) fail(`${label}.inputs.discoveryRegistry.source must match the production discovery URL`)
  }

  const summaryKeys = ['approved', 'required', 'bundledExecutable', 'discovered', 'effective', 'productionExecutable', 'missing', 'extra']
  assertAllowedKeys(report.summary, summaryKeys, `${label}.summary`)
  for (const key of summaryKeys) requireNumber(report.summary[key], `${label}.summary.${key}`)

  const routeKeys = assertXcmEffectiveSortedUniqueRoutes(
    report.routes,
    `${label}.routes`,
    ['originChainId', 'destinationChainId', 'assetSymbol', 'effective', 'productionExecutable', 'reasons'],
    (route, routeLabel) => {
      requireBoolean(route.effective, `${routeLabel}.effective`)
      requireBoolean(route.productionExecutable, `${routeLabel}.productionExecutable`)
      assertXcmEffectiveReasons(route.reasons, `${routeLabel}.reasons`)
      if (route.effective !== (route.reasons.length === 0)) fail(`${routeLabel}.effective must match empty reasons`)
      if (route.productionExecutable) fail(`${routeLabel}.productionExecutable must be false while production transfers are disabled`)
    }
  )
  const missingKeys = assertXcmEffectiveSortedUniqueRoutes(
    report.missing,
    `${label}.missing`,
    ['originChainId', 'destinationChainId', 'assetSymbol', 'reasons'],
    (route, routeLabel) => {
      assertXcmEffectiveReasons(route.reasons, `${routeLabel}.reasons`)
      if (route.reasons.length === 0) fail(`${routeLabel}.reasons must be non-empty`)
    }
  )
  const extraKeys = assertXcmEffectiveSortedUniqueRoutes(
    report.extra,
    `${label}.extra`,
    ['originChainId', 'destinationChainId', 'assetSymbol'],
    () => {},
  )

  const derivedMissing = report.routes.filter((route) => !route.effective)
  if (derivedMissing.length !== report.missing.length) fail(`${label}.missing must match ineffective routes`)
  for (const [index, route] of derivedMissing.entries()) {
    const missing = report.missing[index]
    if (xcmEffectiveRouteKey(route) !== xcmEffectiveRouteKey(missing)) fail(`${label}.missing[${index}] must match ineffective route order`)
    if (route.reasons.join('\n') !== missing.reasons.join('\n')) fail(`${label}.missing[${index}].reasons must match ineffective route`)
  }
  for (const key of missingKeys) if (!routeKeys.has(key)) fail(`${label}.missing route must exist in routes: ${key}`)
  for (const key of extraKeys) if (routeKeys.has(key)) fail(`${label}.extra route must not be approved: ${key}`)

  const effectiveCount = report.routes.filter((route) => route.effective).length
  const productionExecutableCount = report.routes.filter((route) => route.productionExecutable).length
  if (report.summary.approved !== report.routes.length) fail(`${label}.summary.approved must match routes length`)
  if (report.summary.required !== report.summary.approved) fail(`${label}.summary.required must match approved`)
  if (report.summary.bundledExecutable !== report.summary.approved) fail(`${label}.summary.bundledExecutable must match approved`)
  if (report.summary.effective !== effectiveCount) fail(`${label}.summary.effective must match compatible routes`)
  if (report.summary.productionExecutable !== productionExecutableCount) fail(`${label}.summary.productionExecutable must match production-executable routes`)
  if (report.summary.productionExecutable !== 0) fail(`${label}.summary.productionExecutable must be zero while production transfers are disabled`)
  if (report.summary.missing !== report.missing.length) fail(`${label}.summary.missing must match missing length`)
  if (report.summary.extra !== report.extra.length) fail(`${label}.summary.extra must match extra length`)
  if (report.summary.effective + report.summary.missing !== report.summary.approved) fail(`${label}.summary effective plus missing must equal approved`)
  if (report.status !== (report.summary.missing === 0 ? 'complete' : 'incomplete')) fail(`${label}.status must match missing count`)
  if (report.mode === 'bundled') {
    if (report.summary.discovered !== report.summary.bundledExecutable) fail(`${label}.summary.discovered must match bundledExecutable in bundled mode`)
    if (report.summary.extra !== 0) fail(`${label}.summary.extra must be zero in bundled mode`)
    if (report.summary.missing !== 0 || report.summary.effective !== report.summary.approved) fail(`${label} bundled report must contain every approved compatible route`)
  } else {
    if (report.summary.discovered < report.summary.effective + report.summary.extra) fail(`${label}.summary.discovered cannot be smaller than compatible plus extra routes`)
    if (report.summary.discovered > report.summary.approved + report.summary.extra) fail(`${label}.summary.discovered cannot exceed approved plus extra routes`)
  }

  assertXcmEffectiveWorkspaceInputParity(report, label, requireWorkspaceSources)
}

function assertExactStringArray(value, expected, label) {
  if (!Array.isArray(value)) fail(`${label} must be an array`)
  if (value.length !== expected.length) fail(`${label} length mismatch`)
  for (const [index, expectedValue] of expected.entries()) {
    requireSingleLine(value[index], `${label}[${index}]`)
    assertNoSecretLike(`${label}[${index}]`, value[index])
    if (value[index] !== expectedValue) fail(`${label}[${index}] mismatch`)
  }
}

const indexerDeploymentTemplateConfigs = {
  'ti-deployment-evidence': {
    sourceReportPath: 'ti-deployment-evidence-template.json',
    templateArtifact: 'handoffs/ti-deployment-evidence-template.json',
    generatedTemplatePath: '../ton-indexer/build/reports/production-deployment-evidence-template.json',
    destinationManifest: '../ton-indexer/scripts/production-deployment-evidence.json',
    serviceId: 'ti.soramitsu.io',
    scope: 'ton-indexer-production-deployment-readiness',
    baseUrl: 'https://ti.soramitsu.io',
    status: 'ready',
    releaseEnabled: true,
    lastReviewed: 'TODO_YYYY_MM_DD',
    blockers: [],
    smokeCommand: 'TON_INDEXER_BASE_URL=https://ti.soramitsu.io npm run smoke:production',
    dockerBuildCommand: 'docker build -t ton-indexer:release .',
    readyVerificationCommands: [
      'npm run test:deployment-evidence-template',
      'npm run generate:deployment-evidence-template -- --output build/reports/production-deployment-evidence-template.json',
      'npm run test:deployment-evidence-audit',
      'npm run audit:deployment-evidence -- --require-ready',
      'docker build -t ton-indexer:release .',
      'TON_INDEXER_BASE_URL=https://ti.soramitsu.io npm run smoke:production',
    ],
    requiredEvidenceFields: ['commit', 'imageDigest', 'deploymentId', 'baseUrl', 'smokeCommand', 'deployedAt', 'smokePassedAt', 'serviceInfo', 'healthInfo', 'operator'],
    placeholderRecord: {
      commit: 'TODO_40_HEX_GIT_COMMIT',
      imageDigest: 'sha256:TODO_64_HEX_IMAGE_DIGEST',
      deploymentId: 'TODO_PRODUCTION_DEPLOYMENT_ID',
      deployedAt: 'TODO_UTC_DEPLOYED_AT_SECONDS',
      smokePassedAt: 'TODO_UTC_SMOKE_TIMESTAMP_SECONDS',
      operator: 'TODO_RELEASE_OPERATOR',
    },
    serviceInfoTarget: {
      schemaVersion: 1,
      serviceId: 'ti.soramitsu.io',
      ecosystem: 'ton',
      chainId: 'ton:mainnet',
      network: 'mainnet',
      publicBaseUrl: 'https://ti.soramitsu.io',
      readOnly: true,
      endpoints: { openapi: '/api/indexer/v1/openapi.json' },
    },
    healthInfoTarget: {
      serviceId: 'ti.soramitsu.io',
      ecosystem: 'ton',
      chainId: 'ton:mainnet',
      network: 'mainnet',
      lastMasterSeqno: 'TODO_LAST_MASTER_SEQNO',
    },
    readyAuditCommand: 'cd ../ton-indexer && npm run audit:deployment-evidence -- --require-ready',
    requiredContracts: [
      'template status must be ready with releaseEnabled=true for operator fill-in',
      'template placeholders must fail --require-ready until deployment evidence is recorded',
      'serviceInfo.serviceId must remain ti.soramitsu.io',
      'healthInfo.serviceId must remain ti.soramitsu.io',
      'healthInfo.lastMasterSeqno must be replaced with successful production smoke evidence',
    ],
  },
  'si-deployment-evidence': {
    sourceReportPath: 'si-deployment-evidence-template.json',
    templateArtifact: 'handoffs/si-deployment-evidence-template.json',
    generatedTemplatePath: '../solswap-indexer/build/reports/production-deployment-evidence-template.json',
    destinationManifest: '../solswap-indexer/scripts/production-deployment-evidence.json',
    serviceId: 'si.soramitsu.io',
    scope: 'solswap-indexer-production-deployment-readiness',
    baseUrl: 'https://si.soramitsu.io',
    status: 'ready',
    releaseEnabled: true,
    lastReviewed: 'TODO_YYYY_MM_DD',
    blockers: [],
    smokeCommand: 'SOLSWAP_INDEXER_BASE_URL=https://si.soramitsu.io npm run smoke:production',
    dockerBuildCommand: 'docker build -t solswap-indexer:release .',
    readyVerificationCommands: [
      'npm run test:deployment-evidence-template',
      'npm run generate:deployment-evidence-template -- --output build/reports/production-deployment-evidence-template.json',
      'npm run test:deployment-evidence-audit',
      'npm run audit:deployment-evidence -- --require-ready',
      'docker build -t solswap-indexer:release .',
      'SOLSWAP_INDEXER_BASE_URL=https://si.soramitsu.io npm run smoke:production',
    ],
    requiredEvidenceFields: ['commit', 'imageDigest', 'deploymentId', 'baseUrl', 'smokeCommand', 'deployedAt', 'smokePassedAt', 'serviceInfo', 'healthInfo', 'operator'],
    placeholderRecord: {
      commit: 'TODO_40_HEX_GIT_COMMIT',
      imageDigest: 'sha256:TODO_64_HEX_IMAGE_DIGEST',
      deploymentId: 'TODO_PRODUCTION_DEPLOYMENT_ID',
      deployedAt: 'TODO_UTC_DEPLOYED_AT_SECONDS',
      smokePassedAt: 'TODO_UTC_SMOKE_TIMESTAMP_SECONDS',
      operator: 'TODO_RELEASE_OPERATOR',
    },
    serviceInfoTarget: {
      schemaVersion: 1,
      serviceId: 'si.soramitsu.io',
      ecosystem: 'solana',
      chainId: 'solana:mainnet',
      network: 'mainnet',
      publicBaseUrl: 'https://si.soramitsu.io',
      readOnly: true,
      endpoints: { openapi: '/api/indexer/v1/openapi.json' },
    },
    healthInfoTarget: {
      ok: true,
      serviceId: 'si.soramitsu.io',
      ecosystem: 'solana',
      chainId: 'solana:mainnet',
      network: 'mainnet',
      genesisHash: '5eykt4UsFv8P8NJdTREpY1vzqKqZKvdpKuc147dw2N9d',
      latestSlot: 'TODO_POSITIVE_LATEST_SLOT',
      syncedAt: 'TODO_UNIX_TIMESTAMP_SECONDS',
    },
    readyAuditCommand: 'cd ../solswap-indexer && npm run audit:deployment-evidence -- --require-ready',
    requiredContracts: [
      'template status must be ready with releaseEnabled=true for operator fill-in',
      'template placeholders must fail --require-ready until deployment evidence is recorded',
      'serviceInfo.serviceId must remain si.soramitsu.io',
      'healthInfo.serviceId must remain si.soramitsu.io',
      'healthInfo.genesisHash must remain the exact Solana mainnet genesis hash',
      'healthInfo.latestSlot must be TODO_POSITIVE_LATEST_SLOT in the template and a positive safe integer in ready evidence',
      'healthInfo.syncedAt must be TODO_UNIX_TIMESTAMP_SECONDS in the template and an integer no more than 120 seconds before and no more than 30 seconds after smokePassedAt in ready evidence',
      'healthInfo.lastMasterSeqno must remain absent for the Solswap service',
    ],
  },
  'pi-deployment-evidence': {
    sourceReportPath: 'pi-deployment-evidence-template.json',
    templateArtifact: 'handoffs/pi-deployment-evidence-template.json',
    generatedTemplatePath: '../polkaswap-indexer/build/reports/production-deployment-evidence-template.json',
    destinationManifest: '../polkaswap-indexer/scripts/production-deployment-evidence.json',
    serviceId: 'pi.soramitsu.io',
    scope: 'polkaswap-indexer-production-deployment-readiness',
    baseUrl: 'https://pi.soramitsu.io/graphql',
    status: 'blocked',
    releaseEnabled: false,
    blockers: ['production-deployment-evidence-missing', 'live-production-smoke-failing'],
    smokeCommand: 'POLKASWAP_INDEXER_BASE_URL=https://pi.soramitsu.io/graphql yarn smoke:production',
    dockerBuildCommand: 'docker build -t polkaswap-indexer:release .',
    readyVerificationCommands: [
      'yarn test:deployment-evidence-template',
      'yarn generate:deployment-evidence-template --output build/reports/production-deployment-evidence-template.json',
      'yarn test:deployment-evidence-audit',
      'yarn audit:deployment-evidence --require-ready',
      'docker build -t polkaswap-indexer:release .',
      'POLKASWAP_INDEXER_BASE_URL=https://pi.soramitsu.io/graphql yarn smoke:production',
    ],
    requiredEvidenceFields: ['commit', 'imageDigest', 'deploymentId', 'baseUrl', 'smokeCommand', 'deployedAt', 'smokePassedAt', 'healthInfo', 'soraRpcControls', 'tlsEdgeControls', 'operator'],
    placeholderRecord: {
      commit: 'TODO_40_HEX_GIT_COMMIT',
      imageDigest: 'sha256:TODO_64_HEX_IMAGE_DIGEST',
      deploymentId: 'TODO_PRODUCTION_DEPLOYMENT_ID',
      deployedAt: 'TODO_UTC_DEPLOYED_AT_SECONDS',
      smokePassedAt: 'TODO_UTC_SMOKE_TIMESTAMP_SECONDS',
      operator: 'TODO_RELEASE_OPERATOR',
    },
    healthInfoTarget: {
      ok: true,
      service: 'polkaswap-indexer',
      serviceId: 'pi.soramitsu.io',
      schemaVersion: 1,
      ecosystem: 'sora2',
      chainId: 'sora:mainnet',
      network: 'mainnet',
      publicBaseUrl: 'https://pi.soramitsu.io/graphql',
      readOnly: true,
      genesisHash: '0x7e4e32d0feafd4f9c9414b0be86373f9a1efa904809b683453a9af6856d38ad5',
      latestIndexedBlock: 'TODO_POSITIVE_SAFE_INTEGER_INDEXED_BLOCK',
      latestIndexedBlockHash: 'TODO_0X_64_LOWERCASE_HEX_INDEXED_BLOCK_HASH',
      latestIndexedAt: 'TODO_UNIX_SECONDS_WITHIN_300_BEFORE_OR_30_AFTER_SMOKE',
    },
    soraRpcControlsTarget: {
      primaryEndpoint: 'TODO_CANONICAL_WSS_LOCALLY_CONTROLLED_PRIMARY_RPC_ENDPOINT',
      archiveEndpoint: 'TODO_CANONICAL_WSS_INDEPENDENT_ARCHIVE_RPC_ENDPOINT',
      primaryNodeControl: 'locally-controlled-verifying-archive',
      archiveNodeControl: 'independently-operated-verifying-archive',
      distinctHosts: true,
      exactIdentityPreflight: true,
      rawPayloadAgreement: 'height-hash-scale-block-events-timestamp',
    },
    tlsEdgeControlsTarget: {
      tlsTermination: true,
      forwardedClientIpHeaders: 'overwrite',
      httpClientIpRateLimit: {
        windowMs: 60000,
        maxRequests: 600,
      },
      webSocketClientIpLimits: {
        windowMs: 60000,
        maxUpgrades: 600,
        maxConcurrentConnections: 16,
      },
    },
    readyAuditCommand: 'cd ../polkaswap-indexer && bash ../fearless/scripts/run-pinned-yarn.sh audit:deployment-evidence --require-ready',
    requiredContracts: [
      'template remains blocked until PI production deployment evidence is recorded',
      'template placeholders must fail --require-ready until deployment evidence is recorded',
      'healthInfo.service must remain polkaswap-indexer',
      'healthInfo.serviceId must remain pi.soramitsu.io',
      'healthInfo.publicBaseUrl must remain https://pi.soramitsu.io/graphql',
      'healthInfo.genesisHash must remain the exact SORA mainnet genesis hash',
      'healthInfo.latestIndexedBlock must be TODO_POSITIVE_SAFE_INTEGER_INDEXED_BLOCK in the template and a positive safe integer in ready evidence',
      'healthInfo.latestIndexedBlockHash must be TODO_0X_64_LOWERCASE_HEX_INDEXED_BLOCK_HASH in the template and a canonical nonzero lowercase 32-byte hash in ready evidence',
      'healthInfo.latestIndexedAt must be TODO_UNIX_SECONDS_WITHIN_300_BEFORE_OR_30_AFTER_SMOKE in the template and an integer no more than 300 seconds before and no more than 30 seconds after smokePassedAt in ready evidence',
      'soraRpcControls must contain exactly the seven reviewed primary/archive trust-boundary fields',
      'soraRpcControls.primaryEndpoint must be a canonical credential-free WSS URL for a locally-controlled verifying archival node and not a public SORA convenience host',
      'soraRpcControls.archiveEndpoint must be a canonical credential-free WSS URL for an independently-operated verifying archival node on a distinct host and not a public SORA convenience host',
      'soraRpcControls.exactIdentityPreflight must be true and rawPayloadAgreement must be height-hash-scale-block-events-timestamp',
      'tlsEdgeControls.tlsTermination must remain true',
      'tlsEdgeControls.forwardedClientIpHeaders must remain overwrite',
      'tlsEdgeControls.httpClientIpRateLimit must remain 600 requests per 60000 ms',
      'tlsEdgeControls.webSocketClientIpLimits must remain 600 upgrades per 60000 ms and 16 concurrent connections',
    ],
  },
}

function assertObjectMap(value, expected, label) {
  assertAllowedKeys(value, Object.keys(expected), label)
  for (const [key, expectedValue] of Object.entries(expected)) {
    if (expectedValue && typeof expectedValue === 'object' && !Array.isArray(expectedValue)) {
      assertObjectMap(value[key], expectedValue, `${label}.${key}`)
      continue
    }
    if (typeof expectedValue === 'boolean' || typeof expectedValue === 'number') {
      if (value[key] !== expectedValue) fail(`${label}.${key} mismatch`)
      continue
    }
    requireSingleLine(value[key], `${label}.${key}`)
    assertNoSecretLike(`${label}.${key}`, value[key])
    if (value[key] !== expectedValue) fail(`${label}.${key} mismatch`)
  }
}

function assertIndexerDeploymentEvidenceTemplate(template, label, config) {
  assertAllowedKeys(template, ['schemaVersion', 'scope', 'serviceId', 'baseUrl', 'status', 'releaseEnabled', 'lastReviewed', 'blockers', 'smokeCommand', 'dockerBuildCommand', 'readyVerificationCommands', 'requiredEvidenceFields', 'deploymentEvidence'], label)
  if (template.schemaVersion !== 1) fail(`${label}.schemaVersion must be 1`)
  if (template.scope !== config.scope) fail(`${label}.scope mismatch`)
  if (template.serviceId !== config.serviceId) fail(`${label}.serviceId mismatch`)
  if (template.baseUrl !== config.baseUrl) fail(`${label}.baseUrl mismatch`)
  if (template.status !== config.status) fail(`${label}.status mismatch`)
  if (template.releaseEnabled !== config.releaseEnabled) fail(`${label}.releaseEnabled mismatch`)
  if (config.lastReviewed) {
    if (template.lastReviewed !== config.lastReviewed) fail(`${label}.lastReviewed mismatch`)
  } else {
    const lastReviewed = parseUtcDate(template.lastReviewed, `${label}.lastReviewed`)
    assertNotFutureDate(lastReviewed, template.lastReviewed, `${label}.lastReviewed`, nowMs)
  }
  assertExactStringArray(template.blockers, config.blockers, `${label}.blockers`)
  if (template.smokeCommand !== config.smokeCommand) fail(`${label}.smokeCommand mismatch`)
  if (template.dockerBuildCommand !== config.dockerBuildCommand) fail(`${label}.dockerBuildCommand mismatch`)
  assertExactStringArray(template.readyVerificationCommands, config.readyVerificationCommands, `${label}.readyVerificationCommands`)
  assertExactStringArray(template.requiredEvidenceFields, config.requiredEvidenceFields, `${label}.requiredEvidenceFields`)
  if (!Array.isArray(template.deploymentEvidence) || template.deploymentEvidence.length !== 1) {
    fail(`${label}.deploymentEvidence must contain exactly one fill-in record`)
  }
  const evidence = template.deploymentEvidence[0]
  assertAllowedKeys(evidence, config.requiredEvidenceFields, `${label}.deploymentEvidence[0]`)
  for (const [field, placeholder] of Object.entries(config.placeholderRecord)) {
    requireSingleLine(evidence[field], `${label}.deploymentEvidence[0].${field}`)
    assertNoSecretLike(`${label}.deploymentEvidence[0].${field}`, evidence[field])
    if (evidence[field] !== placeholder) fail(`${label}.deploymentEvidence[0].${field} placeholder mismatch`)
  }
  if (evidence.baseUrl !== config.baseUrl) fail(`${label}.deploymentEvidence[0].baseUrl mismatch`)
  if (evidence.smokeCommand !== config.smokeCommand) fail(`${label}.deploymentEvidence[0].smokeCommand mismatch`)
  if (config.serviceInfoTarget) {
    assertObjectMap(evidence.serviceInfo, config.serviceInfoTarget, `${label}.deploymentEvidence[0].serviceInfo`)
  }
  assertObjectMap(evidence.healthInfo, config.healthInfoTarget, `${label}.deploymentEvidence[0].healthInfo`)
  if (config.soraRpcControlsTarget) {
    assertObjectMap(evidence.soraRpcControls, config.soraRpcControlsTarget, `${label}.deploymentEvidence[0].soraRpcControls`)
  }
  if (config.tlsEdgeControlsTarget) {
    assertObjectMap(evidence.tlsEdgeControls, config.tlsEdgeControlsTarget, `${label}.deploymentEvidence[0].tlsEdgeControls`)
  }
}

const passkeyDeploymentTemplateSourcePath = 'passkey-deployment-evidence-template.json'
const passkeyDeploymentTemplateArtifactPath = 'handoffs/passkey-deployment-evidence-template.json'
const passkeyRequiredCommands = [
  'npm run lint:syntax',
  'npm test',
  'npm run test:deployment-evidence-template',
  'npm run generate:deployment-evidence-template -- --output build/reports/production-deployment-evidence-template.json',
  'npm run test:deployment-evidence-audit',
  'npm run audit:deployment-evidence',
  'docker build -t passkey-backup-challenge-service:release .',
  'PASSKEY_BACKUP_LIVE_HEALTH=1 PASSKEY_BACKUP_HEALTH_TIMEOUT_SECONDS=10 bash ../../scripts/audit-passkey-backup-prerequisites.sh',
  'PASSKEY_BACKUP_BASE_URL=https://backup.fearlesswallet.io PASSKEY_BACKUP_SMOKE_GRANT_HELPER=/run/secrets/passkey-smoke-grant-helper PASSKEY_BACKUP_SMOKE_TIMEOUT_MS=10000 npm run smoke:production',
  'npm run audit:deployment-evidence -- --require-ready',
]
const passkeyRequiredEvidenceFields = [
  'imageDigest',
  'deploymentId',
  'deployedCommit',
  'deployedAt',
  'operator',
  'smokePassedAt',
  'smokeCommand',
  'healthUrl',
  'healthResponse',
  'liveHealthAttestation',
  'credentialStoreVolume',
  'credentialStoreFile',
  'webauthnAllowedOrigins',
  'requestAccessPolicy',
  'trustedProxyPolicy',
  'platformProvisioning',
  'platformProvisioningAttestation',
]
const passkeyPlatformProvisioningFields = [
  'androidGoogleDriveConsent',
  'androidReleaseFlagDisabled',
  'iosAssociatedDomain',
  'iosCloudKitProductionSchema',
  'iosReleaseFlagDisabled',
]
const passkeyDeploymentTemplatePlaceholders = {
  imageDigest: 'sha256:TODO_64_HEX_IMAGE_DIGEST',
  deploymentId: 'TODO_PRODUCTION_DEPLOYMENT_ID',
  deployedCommit: 'TODO_40_HEX_GIT_COMMIT',
  deployedAt: 'TODO_UTC_DEPLOYED_AT_SECONDS',
  operator: 'TODO_RELEASE_OPERATOR',
  smokePassedAt: 'TODO_UTC_SMOKE_TIMESTAMP_SECONDS',
}
const passkeyAttestationFields = [
  'deploymentId',
  'deployedCommit',
  'imageDigest',
  'observedAt',
  'payloadSha256',
]
const passkeyTemplateLiveHealthAttestation = {
  deploymentId: passkeyDeploymentTemplatePlaceholders.deploymentId,
  deployedCommit: passkeyDeploymentTemplatePlaceholders.deployedCommit,
  imageDigest: passkeyDeploymentTemplatePlaceholders.imageDigest,
  observedAt: passkeyDeploymentTemplatePlaceholders.smokePassedAt,
  payloadSha256: 'sha256:TODO_CANONICAL_HEALTH_RESPONSE_SHA256',
}
const passkeyTemplatePlatformProvisioningAttestation = {
  deploymentId: passkeyDeploymentTemplatePlaceholders.deploymentId,
  deployedCommit: passkeyDeploymentTemplatePlaceholders.deployedCommit,
  imageDigest: passkeyDeploymentTemplatePlaceholders.imageDigest,
  observedAt: passkeyDeploymentTemplatePlaceholders.smokePassedAt,
  payloadSha256: 'sha256:TODO_CANONICAL_PLATFORM_PROVISIONING_SHA256',
}
const passkeyTemplateWebauthnAllowedOrigins = [
  'https://fearlesswallet.io',
  'https://backup.fearlesswallet.io',
  'android:apk-key-hash:TODO_RELEASE_CERT_SHA256_BASE64URL',
]
const passkeyTemplateRequestAccessPolicy = {
  introspectionUrl: 'https://TODO_WALLET_OWNER_AUTHORITY/v1/passkey/consume',
  audience: 'fearless-passkey-backup',
  mode: 'atomic-one-time-consume',
  allPostRoutesProtected: true,
  stableCrossPlatformWalletSubject: true,
  authorizedSmokePassed: true,
  noRawSubjectPersisted: true,
  credentialLifecycleSmokePassed: true,
  ownerTombstonePersistencePassed: true,
  crossSubjectTakeoverDenied: true,
  sameOwnerReregistrationPassed: true,
  cloudDeleteRevokesServerFirst: true,
  listExcludesVerificationMaterial: true,
}
const passkeyTemplateTrustedProxyPolicy = {
  hops: 1,
  forwardedHeader: 'X-Forwarded-For',
  directPeerAllowlistConfigured: true,
  incomingHeaderSanitized: true,
  directPublicAccessBlocked: true,
  adversarialProxyTestsPassed: true,
}
const passkeyDeploymentTemplateContracts = [
  'template status must be ready with releaseEnabled=true for operator fill-in',
  'template placeholders must fail --require-ready until deployment evidence is recorded',
  'healthResponse.service must remain fearless-passkey-backup',
  'healthResponse.rpId must remain fearlesswallet.io',
  'credentialStoreFile must remain /data/passkey-backup/credentials.json',
  'webauthnAllowedOrigins must contain the two production HTTPS origins and one reviewed Android release origin',
  'requestAccessPolicy must use atomic one-time consume authorization for every POST route with a stable cross-platform wallet subject and prove lifecycle smoke, durable tombstones, takeover denial, same-owner re-registration, server-first cloud deletion, and verification-material-free list output',
  'trustedProxyPolicy must require one trusted hop, a direct-peer allowlist, sanitized forwarding headers, blocked direct public access, and adversarial proxy evidence',
  'platformProvisioning must keep Android and iOS release flags disabled until live evidence is ready',
  'smokePassedAt must be no more than 24 hours old for ready evidence; the exact 24-hour boundary is accepted and every record is checked independently',
  'liveHealthAttestation and platformProvisioningAttestation must bind deploymentId, deployedCommit, imageDigest, and observedAt=smokePassedAt; payloadSha256 must match the canonical attested payload',
  'blocked deployment evidence must keep deploymentEvidence empty; partial or stale records cannot coexist with blockers',
]

function assertPasskeyDeploymentEvidenceTemplate(template, label) {
  assertAllowedKeys(template, [
    'schemaVersion',
    'scope',
    'service',
    'rpId',
    'baseUrl',
    'healthUrl',
    'imageName',
    'port',
    'credentialStoreVolume',
    'credentialStoreFile',
    'status',
    'releaseEnabled',
    'blockers',
    'dockerBuildCommand',
    'smokeCommand',
    'requiredCommands',
    'requiredEvidenceFields',
    'deploymentEvidence',
  ], label)
  if (template.schemaVersion !== 1) fail(`${label}.schemaVersion must be 1`)
  if (template.scope !== 'passkey-backup-challenge-service-production-deployment-readiness') fail(`${label}.scope mismatch`)
  if (template.service !== 'fearless-passkey-backup') fail(`${label}.service mismatch`)
  if (template.rpId !== 'fearlesswallet.io') fail(`${label}.rpId mismatch`)
  if (template.baseUrl !== 'https://backup.fearlesswallet.io') fail(`${label}.baseUrl mismatch`)
  if (template.healthUrl !== 'https://backup.fearlesswallet.io/api/passkey-backup/v1/health') fail(`${label}.healthUrl mismatch`)
  if (template.imageName !== 'passkey-backup-challenge-service') fail(`${label}.imageName mismatch`)
  if (template.port !== 8789) fail(`${label}.port mismatch`)
  if (template.credentialStoreVolume !== '/data/passkey-backup') fail(`${label}.credentialStoreVolume mismatch`)
  if (template.credentialStoreFile !== '/data/passkey-backup/credentials.json') fail(`${label}.credentialStoreFile mismatch`)
  if (template.status !== 'ready') fail(`${label}.status must be ready`)
  if (template.releaseEnabled !== true) fail(`${label}.releaseEnabled must be true`)
  if (!Array.isArray(template.blockers) || template.blockers.length !== 0) fail(`${label}.blockers must be empty`)
  if (template.dockerBuildCommand !== 'docker build -t passkey-backup-challenge-service:release .') fail(`${label}.dockerBuildCommand mismatch`)
  if (template.smokeCommand !== 'PASSKEY_BACKUP_BASE_URL=https://backup.fearlesswallet.io PASSKEY_BACKUP_SMOKE_GRANT_HELPER=/run/secrets/passkey-smoke-grant-helper PASSKEY_BACKUP_SMOKE_TIMEOUT_MS=10000 npm run smoke:production') fail(`${label}.smokeCommand mismatch`)
  assertExactStringArray(template.requiredCommands, passkeyRequiredCommands, `${label}.requiredCommands`)
  assertExactStringArray(template.requiredEvidenceFields, passkeyRequiredEvidenceFields, `${label}.requiredEvidenceFields`)
  if (!Array.isArray(template.deploymentEvidence) || template.deploymentEvidence.length !== 1) {
    fail(`${label}.deploymentEvidence must contain exactly one fill-in record`)
  }
  const evidence = template.deploymentEvidence[0]
  assertAllowedKeys(evidence, passkeyRequiredEvidenceFields, `${label}.deploymentEvidence[0]`)
  for (const [field, placeholder] of Object.entries(passkeyDeploymentTemplatePlaceholders)) {
    requireSingleLine(evidence[field], `${label}.deploymentEvidence[0].${field}`)
    assertNoSecretLike(`${label}.deploymentEvidence[0].${field}`, evidence[field])
    if (evidence[field] !== placeholder) {
      fail(field === 'deployedCommit'
        ? `${label}.deploymentEvidence[0].deployedCommit placeholder mismatch`
        : `${label}.deploymentEvidence[0].${field} placeholder mismatch`)
    }
  }
  if (evidence.smokeCommand !== template.smokeCommand) fail(`${label}.deploymentEvidence[0].smokeCommand mismatch`)
  if (evidence.healthUrl !== template.healthUrl) fail(`${label}.deploymentEvidence[0].healthUrl mismatch`)
  if (evidence.credentialStoreVolume !== template.credentialStoreVolume) fail(`${label}.deploymentEvidence[0].credentialStoreVolume mismatch`)
  if (evidence.credentialStoreFile !== template.credentialStoreFile) fail(`${label}.deploymentEvidence[0].credentialStoreFile mismatch`)
  assertExactStringArray(evidence.webauthnAllowedOrigins, passkeyTemplateWebauthnAllowedOrigins, `${label}.deploymentEvidence[0].webauthnAllowedOrigins`)
  assertObjectMap(evidence.requestAccessPolicy, passkeyTemplateRequestAccessPolicy, `${label}.deploymentEvidence[0].requestAccessPolicy`)
  assertObjectMap(evidence.trustedProxyPolicy, passkeyTemplateTrustedProxyPolicy, `${label}.deploymentEvidence[0].trustedProxyPolicy`)
  assertAllowedKeys(evidence.healthResponse, ['ok', 'service', 'rpId', 'schemaVersion'], `${label}.deploymentEvidence[0].healthResponse`)
  if (evidence.healthResponse.ok !== true) fail(`${label}.deploymentEvidence[0].healthResponse.ok must be true`)
  if (evidence.healthResponse.service !== 'fearless-passkey-backup') fail(`${label}.deploymentEvidence[0].healthResponse.service mismatch`)
  if (evidence.healthResponse.rpId !== 'fearlesswallet.io') fail(`${label}.deploymentEvidence[0].healthResponse.rpId mismatch`)
  if (evidence.healthResponse.schemaVersion !== 1) fail(`${label}.deploymentEvidence[0].healthResponse.schemaVersion mismatch`)
  assertAllowedKeys(evidence.liveHealthAttestation, passkeyAttestationFields, `${label}.deploymentEvidence[0].liveHealthAttestation`)
  assertObjectMap(evidence.liveHealthAttestation, passkeyTemplateLiveHealthAttestation, `${label}.deploymentEvidence[0].liveHealthAttestation`)
  assertAllowedKeys(evidence.platformProvisioning, passkeyPlatformProvisioningFields, `${label}.deploymentEvidence[0].platformProvisioning`)
  for (const field of passkeyPlatformProvisioningFields) {
    if (evidence.platformProvisioning[field] !== true) {
      fail(`${label}.deploymentEvidence[0].platformProvisioning.${field} must be true`)
    }
  }
  assertAllowedKeys(evidence.platformProvisioningAttestation, passkeyAttestationFields, `${label}.deploymentEvidence[0].platformProvisioningAttestation`)
  assertObjectMap(evidence.platformProvisioningAttestation, passkeyTemplatePlatformProvisioningAttestation, `${label}.deploymentEvidence[0].platformProvisioningAttestation`)
}

const bitcoinBroadcastTemplateSourcePath = 'web-bitcoin-broadcast-evidence-template.json'
const bitcoinBroadcastTemplateArtifactPath = 'handoffs/web-bitcoin-broadcast-evidence-template.json'
const bitcoinRequiredEvidenceFields = [
  'txid',
  'sourceAddress',
  'recipientAddress',
  'amountSat',
  'outpoint',
  'indexerUrl',
  'timestamp',
  'operator',
  'commit',
]
const bitcoinReadyVerificationCommands = [
  'yarn test:bitcoin-broadcast-evidence-template',
  'yarn generate:bitcoin-broadcast-evidence-template -- --output build/reports/bitcoin-broadcast-evidence-template.json',
  'yarn test:bitcoin-broadcast-evidence-audit',
  'yarn audit:bitcoin-broadcast-evidence --require-ready',
  'FEARLESS_BITCOIN_TESTNET_LIVE=1 yarn test:smoke:bitcoin',
]
const bitcoinLiveSmokeEnvironment = [
  'FEARLESS_BITCOIN_TESTNET_LIVE',
  'FEARLESS_BITCOIN_TESTNET_MNEMONIC',
  'FEARLESS_BITCOIN_TESTNET_SOURCE_ADDRESS',
  'FEARLESS_BITCOIN_TESTNET_RECIPIENT_ADDRESS',
  'FEARLESS_BITCOIN_TESTNET_AMOUNT_SAT',
  'FEARLESS_BITCOIN_TESTNET_OUTPOINT',
]
const bitcoinTemplatePlaceholders = {
  txid: 'TODO_64_HEX_TESTNET_TXID',
  sourceAddress: 'TODO_TESTNET_SOURCE_TB1Q_ADDRESS',
  recipientAddress: 'TODO_TESTNET_RECIPIENT_TB1Q_ADDRESS',
  amountSat: 'TODO_POSITIVE_INTEGER_SATS',
  outpoint: 'TODO_64_HEX_FUNDING_TXID:TODO_VOUT',
  indexerUrl: 'https://blockstream.info/testnet/api',
  timestamp: 'TODO_UTC_TIMESTAMP_SECONDS',
  operator: 'TODO_RELEASE_OPERATOR',
  commit: 'TODO_40_HEX_GIT_COMMIT',
}
const bitcoinBroadcastTemplateContracts = [
  'template status must be ready with releaseEnabled=true for operator fill-in',
  'template placeholders must fail --require-ready until funded evidence is recorded',
  'indexerUrl placeholder must remain https://blockstream.info/testnet/api',
  'commit placeholder must be replaced with the web wallet release commit',
  'sourceAddress and recipientAddress placeholders must be replaced with Bitcoin testnet addresses',
]

function assertBitcoinBroadcastEvidenceTemplate(template, label) {
  assertAllowedKeys(template, [
    'schemaVersion',
    'scope',
    'status',
    'releaseEnabled',
    'lastReviewed',
    'blockers',
    'smokeCommand',
    'readyVerificationCommands',
    'liveSmokeEnvironment',
    'defaultIndexerUrl',
    'requiredEvidenceFields',
    'evidence',
  ], label)
  if (template.schemaVersion !== 1) fail(`${label}.schemaVersion must be 1`)
  if (template.scope !== 'web-bitcoin-testnet-broadcast-readiness') fail(`${label}.scope mismatch`)
  if (template.status !== 'ready') fail(`${label}.status must be ready`)
  if (template.releaseEnabled !== true) fail(`${label}.releaseEnabled must be true`)
  if (template.lastReviewed !== 'TODO_YYYY_MM_DD') fail(`${label}.lastReviewed must be TODO_YYYY_MM_DD`)
  if (!Array.isArray(template.blockers) || template.blockers.length !== 0) fail(`${label}.blockers must be empty`)
  if (template.smokeCommand !== 'yarn test:smoke:bitcoin') fail(`${label}.smokeCommand mismatch`)
  if (template.defaultIndexerUrl !== 'https://blockstream.info/testnet/api') fail(`${label}.defaultIndexerUrl mismatch`)
  assertExactStringArray(template.readyVerificationCommands, bitcoinReadyVerificationCommands, `${label}.readyVerificationCommands`)
  if (!Array.isArray(template.liveSmokeEnvironment)) fail(`${label}.liveSmokeEnvironment must be an array`)
  if (template.liveSmokeEnvironment.length !== bitcoinLiveSmokeEnvironment.length) fail(`${label}.liveSmokeEnvironment length mismatch`)
  for (const [index, expectedValue] of bitcoinLiveSmokeEnvironment.entries()) {
    requireSingleLine(template.liveSmokeEnvironment[index], `${label}.liveSmokeEnvironment[${index}]`)
    if (template.liveSmokeEnvironment[index] !== expectedValue) fail(`${label}.liveSmokeEnvironment[${index}] mismatch`)
  }
  assertExactStringArray(template.requiredEvidenceFields, bitcoinRequiredEvidenceFields, `${label}.requiredEvidenceFields`)
  if (!Array.isArray(template.evidence) || template.evidence.length !== 1) {
    fail(`${label}.evidence must contain exactly one fill-in record`)
  }
  const evidence = template.evidence[0]
  assertAllowedKeys(evidence, bitcoinRequiredEvidenceFields, `${label}.evidence[0]`)
  for (const field of bitcoinRequiredEvidenceFields) {
    requireSingleLine(evidence[field], `${label}.evidence[0].${field}`)
    assertNoSecretLike(`${label}.evidence[0].${field}`, evidence[field])
    if (evidence[field] !== bitcoinTemplatePlaceholders[field]) {
      fail(`${label}.evidence[0].${field} placeholder mismatch`)
    }
  }
}

function buildBitcoinBroadcastTemplateHandoff(blockerSlug, artifacts) {
  if (blockerSlug !== 'web-bitcoin-broadcast-evidence') return null

  const source = resolveReportFile(bitcoinBroadcastTemplateSourcePath, `${blockerSlug}.bitcoinBroadcastTemplateHandoff.sourceReportPath`)
  const template = readJson(source, `${blockerSlug} Bitcoin broadcast evidence template`)
  assertBitcoinBroadcastEvidenceTemplate(template, `${blockerSlug}.bitcoinBroadcastEvidenceTemplate`)
  copyCheckedArtifact(source, bitcoinBroadcastTemplateArtifactPath, artifacts)
  const artifact = artifacts.find((item) => item.path === bitcoinBroadcastTemplateArtifactPath)

  return {
    sourceReportPath: bitcoinBroadcastTemplateSourcePath,
    templateArtifact: bitcoinBroadcastTemplateArtifactPath,
    templateSha256: artifact.sha256,
    generatedTemplatePath: 'fearless-wallet-web/build/reports/bitcoin-broadcast-evidence-template.json',
    destinationManifest: 'fearless-wallet-web/scripts/bitcoin-testnet-broadcast-evidence.json',
    defaultIndexerUrl: template.defaultIndexerUrl,
    requiredEvidenceFields: [...bitcoinRequiredEvidenceFields],
    placeholderRecord: { ...bitcoinTemplatePlaceholders },
    readyAuditCommand: 'cd fearless-wallet-web && bash scripts/audit-bitcoin-broadcast-evidence.sh --require-ready',
    requiredContracts: [...bitcoinBroadcastTemplateContracts],
  }
}

function buildPasskeyDeploymentTemplateHandoff(blockerSlug, artifacts) {
  if (blockerSlug !== 'passkey-deployment-evidence') return null

  const source = resolveReportFile(passkeyDeploymentTemplateSourcePath, `${blockerSlug}.passkeyDeploymentTemplateHandoff.sourceReportPath`)
  const template = readJson(source, `${blockerSlug} deployment evidence template`)
  assertPasskeyDeploymentEvidenceTemplate(template, `${blockerSlug}.passkeyDeploymentEvidenceTemplate`)
  copyCheckedArtifact(source, passkeyDeploymentTemplateArtifactPath, artifacts)
  const artifact = artifacts.find((item) => item.path === passkeyDeploymentTemplateArtifactPath)

  return {
    sourceReportPath: passkeyDeploymentTemplateSourcePath,
    templateArtifact: passkeyDeploymentTemplateArtifactPath,
    templateSha256: artifact.sha256,
    generatedTemplatePath: 'services/passkey-backup-challenge-service/build/reports/production-deployment-evidence-template.json',
    destinationManifest: 'services/passkey-backup-challenge-service/scripts/production-deployment-evidence.json',
    service: template.service,
    baseUrl: template.baseUrl,
    healthUrl: template.healthUrl,
    credentialStoreFile: template.credentialStoreFile,
    requiredEvidenceFields: [...passkeyRequiredEvidenceFields],
    placeholderRecord: { ...passkeyDeploymentTemplatePlaceholders },
    healthResponseTarget: { ok: true, service: 'fearless-passkey-backup', rpId: 'fearlesswallet.io', schemaVersion: 1 },
    liveHealthAttestationTarget: { ...passkeyTemplateLiveHealthAttestation },
    webauthnAllowedOriginsTarget: [...passkeyTemplateWebauthnAllowedOrigins],
    requestAccessPolicyTarget: { ...passkeyTemplateRequestAccessPolicy },
    trustedProxyPolicyTarget: { ...passkeyTemplateTrustedProxyPolicy },
    platformProvisioningTarget: Object.fromEntries(passkeyPlatformProvisioningFields.map((field) => [field, true])),
    platformProvisioningAttestationTarget: { ...passkeyTemplatePlatformProvisioningAttestation },
    readyAuditCommand: 'cd services/passkey-backup-challenge-service && npm run audit:deployment-evidence -- --require-ready',
    requiredContracts: [...passkeyDeploymentTemplateContracts],
  }
}

const passkeyProductionContractSlugs = new Set(['passkey-backup-prerequisites', 'passkey-production-smoke'])
const passkeyProductionConfigSourcePath = 'config/passkey-backup-production.json'
const passkeyProductionConfigArtifactPath = 'handoffs/passkey-backup-production.json'
const passkeyOpenApiSourcePath = 'config/passkey-backup-challenge-service.openapi.json'
const passkeyOpenApiArtifactPath = 'handoffs/passkey-backup-challenge-service.openapi.json'
const passkeyProductionComposeSourcePath = 'services/passkey-backup-challenge-service/docker-compose.production.yml'
const passkeyProductionComposeArtifactPath = 'handoffs/passkey-backup-docker-compose.production.yml'
const passkeyProductionService = 'fearless-passkey-backup'
const passkeyProductionBaseUrl = 'https://backup.fearlesswallet.io'
const passkeyProductionRpId = 'fearlesswallet.io'
const passkeyProductionSchemaVersion = 1
const passkeyProductionHealthPath = '/api/passkey-backup/v1/health'
const passkeyAndroidWebauthnOrigin = 'android:apk-key-hash:zBfL1DBDIsWOJ4kDReYAmygXt36iPYX_2-MzjFfzYsM'
const passkeyProductionWebauthnAllowedOrigins = [
  'https://fearlesswallet.io',
  'https://backup.fearlesswallet.io',
  passkeyAndroidWebauthnOrigin,
]
const passkeyProductionRoutePaths = [
  '/api/passkey-backup/v1/health',
  '/api/passkey-backup/v1/registration/challenge',
  '/api/passkey-backup/v1/assertion/challenge',
  '/api/passkey-backup/v1/registration/complete',
  '/api/passkey-backup/v1/assertion/complete',
  '/api/passkey-backup/v1/credentials/list',
  '/api/passkey-backup/v1/credentials/revoke',
  '/api/passkey-backup/v1/credentials/revoke-all',
]
const passkeyChallengeServicePaths = {
  registrationChallenge: '/api/passkey-backup/v1/registration/challenge',
  registrationComplete: '/api/passkey-backup/v1/registration/complete',
  assertionChallenge: '/api/passkey-backup/v1/assertion/challenge',
  assertionComplete: '/api/passkey-backup/v1/assertion/complete',
  credentialsList: '/api/passkey-backup/v1/credentials/list',
  credentialsRevoke: '/api/passkey-backup/v1/credentials/revoke',
  credentialsRevokeAll: '/api/passkey-backup/v1/credentials/revoke-all',
}
const passkeyCredentialLifecycle = {
  maxCredentialsPerStorageKey: 32,
  listExposesPublicKeyOrUserHandle: false,
  singleRevokeIdempotent: true,
  revokeAllIdempotent: true,
  finalRevocationRetainsOwnerTombstone: true,
  crossSubjectTakeoverDenied: true,
  sameOwnerReregistrationAllowed: true,
  ownerErasureEndpointEnabled: false,
  cloudDeletionOrdering: 'revoke-server-credentials-before-cloud-record',
}
const passkeyEncryptedBackupMetadata = ['storageKey', 'walletId', 'accountName', 'createdAtMillis', 'schemaVersion']
const passkeyAndroidReleaseUxChecklist = [
  'google-account-selection',
  'google-drive-consent',
  'restore-before-create',
  'disabled-until-live-health',
]
const passkeyIosCloudKitContainers = [
  'iCloud.jp.co.soramitsu.fearlesswallet',
  'iCloud.jp.co.soramitsu.fearlesswallet.dev',
]
const passkeyIosReleaseUxChecklist = [
  'icloud-account-availability',
  'associated-domain-provisioning',
  'cloudkit-production-schema',
  'restore-before-create',
  'disabled-until-live-health',
]
const passkeyRequestAuthorization = {
  mode: 'atomic-one-time-consume',
  audience: 'fearless-passkey-backup',
  credentialType: 'opaque-one-time-bearer-grant',
  bodyDigest: 'sha256-base64url-unpadded-of-exact-request-body-bytes',
  introspectionUrlEnvironmentVariable: 'PASSKEY_AUTHORIZATION_INTROSPECTION_URL',
  failClosed: true,
  stableCrossPlatformSubject: 'fearless-wallet-owner',
}
const passkeyRequestAuthorizationProhibitedSubjectSources = [
  'raw-google-account',
  'raw-apple-account',
  'device-identifier',
]
const passkeyRequestAuthorizationPlatformClaimValues = ['android', 'ios']
const passkeyOpenApiDescription = 'WebAuthn verification is bound to fearlesswallet.io and an explicit origin allowlist. Every ceremony and credential-lifecycle POST requires a distinct one-time Bearer grant atomically consumed by an HTTPS wallet-ownership introspector and bound to the exact method, path, raw-body SHA-256, scope, audience, stable cross-platform subject, and verified platform. Authenticated lifecycle routes list public metadata-only credential descriptors and revoke one or all credentials; final revocation retains a bounded owner tombstone to prevent cross-subject takeover while allowing same-owner re-registration. Production Android ceremonies require the exact android:apk-key-hash:<unpadded-base64url SHA-256 release signing-certificate digest> origin; release flags remain disabled until that origin and platform provisioning are evidenced.'
const passkeyProductionVerificationCommands = [
  'PASSKEY_BACKUP_LIVE_HEALTH=1 bash scripts/audit-passkey-backup-prerequisites.sh && node fearless-site-web/scripts/verify-app-associations.mjs --root fearless-site-web --live-base-url https://fearlesswallet.io',
  'cd services/passkey-backup-challenge-service && PASSKEY_BACKUP_BASE_URL=https://backup.fearlesswallet.io PASSKEY_BACKUP_SMOKE_GRANT_HELPER=/run/secrets/passkey-smoke-grant-helper PASSKEY_BACKUP_SMOKE_TIMEOUT_MS=10000 npm run smoke:production',
  'bash scripts/test-passkey-android-origin-parity-audit.sh',
  'bash scripts/audit-passkey-android-origin-parity.sh',
  'bash scripts/audit-passkey-android-origin-parity.sh --require-ready',
]
const passkeyAndroidSignerEvidence = {
  fingerprintEnvironmentVariable: 'PASSKEY_ANDROID_RELEASE_SIGNER_SHA256_FINGERPRINT',
  sourceEnvironmentVariable: 'PASSKEY_ANDROID_RELEASE_SIGNER_EVIDENCE_SOURCE',
  allowedSources: ['distributed-apk', 'play-app-signing-certificate'],
  rejectedEvidenceTypes: ['aab-upload-key'],
  independentlyObtained: true,
  requiresAssetlinksParity: true,
  exactPackageName: 'jp.co.soramitsu.fearless',
  distributedApk: {
    artifactFileEnvironmentVariable: 'PASSKEY_ANDROID_DISTRIBUTED_APK_FILE',
    artifactSha256EnvironmentVariable: 'PASSKEY_ANDROID_RELEASE_ARTIFACT_SHA256',
    actualReleaseArtifactRequired: true,
    exactlyOneSigningCertificateRequired: true,
    signatureSchemeV2OrV3Required: true,
    packageMustMatchExactPackageName: true,
    artifactChangeDetectionRequired: true,
  },
  playAppSigningCertificate: {
    certificateFileEnvironmentVariable: 'PASSKEY_ANDROID_PLAY_APP_SIGNING_CERTIFICATE_FILE',
    certificateSha256EnvironmentVariable: 'PASSKEY_ANDROID_PLAY_APP_SIGNING_CERTIFICATE_SHA256',
    attestationFileEnvironmentVariable: 'PASSKEY_ANDROID_PLAY_APP_SIGNING_ATTESTATION_FILE',
    attestationSha256EnvironmentVariable: 'PASSKEY_ANDROID_PLAY_APP_SIGNING_ATTESTATION_SHA256',
    releaseArtifactFileEnvironmentVariable: 'PASSKEY_ANDROID_RELEASE_ARTIFACT_FILE',
    releaseArtifactSha256EnvironmentVariable: 'PASSKEY_ANDROID_RELEASE_ARTIFACT_SHA256',
    releaseArtifactType: 'aab',
    immutableFilesRequired: true,
    independentlyExportedX509CertificateRequired: true,
    certificateFingerprintDerivedFromX509Required: true,
    attestationBindsArtifactDigestRequired: true,
    attestationBindsCertificateFileDigestRequired: true,
    attestationBindsCompiledPackageAndVersionCodeRequired: true,
    artifactChangeDetectionRequired: true,
  },
}
const passkeyProductionRequiredContracts = [
  'production config challengeServiceBaseUrl must remain https://backup.fearlesswallet.io',
  'production config relyingPartyId must remain fearlesswallet.io',
  'production config healthPath must remain /api/passkey-backup/v1/health',
  'production config route paths must match the passkey challenge service OpenAPI paths',
  'production config release flags must remain false until live evidence is ready',
  'production config WebAuthn origins must be the two production HTTPS origins plus the assetlinks-derived Android release origin',
  'production config request authorization must atomically consume one-time bearer grants, bind the exact body digest, fail closed, and prohibit raw platform account identifiers',
  'production config credential lifecycle must cap credentials at 32, expose no public key or user handle, keep revoke operations idempotent, retain a final-owner tombstone, deny cross-subject takeover, allow same-owner re-registration, disable owner erasure, and revoke server credentials before cloud deletion',
  'OpenAPI server URL must remain https://backup.fearlesswallet.io',
  'OpenAPI info.description must document the exact Android release signing-certificate origin requirement',
  'all seven OpenAPI POST operations must require bearerAuth and expose exact 401, 403, and 503 ErrorResponse references',
  'OpenAPI credential lifecycle responses must expose only bounded public metadata descriptors and exact idempotent revocation result schemas',
  'OpenAPI Base64UrlUserId and assertion userHandle must remain required canonical 43-character unpadded base64url SHA-256 values',
  'OpenAPI health response must require ok=true, service=fearless-passkey-backup, rpId=fearlesswallet.io, and schemaVersion=1',
  'production Docker Compose must bind 127.0.0.1:8789:8789 and mount passkey-backup-data:/data/passkey-backup',
  'production Docker Compose must keep PASSKEY_ALLOWED_ORIGINS pinned to fearlesswallet.io and backup.fearlesswallet.io',
  'production Docker Compose must require the Android origin, authorization introspection URL, and trusted proxy CIDRs without permissive fallbacks',
  'production Docker Compose must pin authorization audience/timeouts, one trusted proxy hop, per-client/global rate limits, and the durable credential store',
  'Android origin parity must pass in blocked mode; --require-ready requires actual release-artifact evidence and assetlinks parity: distributed-apk must bind PASSKEY_ANDROID_DISTRIBUTED_APK_FILE and PASSKEY_ANDROID_RELEASE_ARTIFACT_SHA256 to one v2/v3 signer and exact package jp.co.soramitsu.fearless, while play-app-signing-certificate must bind an immutable AAB plus independently exported immutable X.509 certificate and canonical attestation through their SHA-256 digests, derive the fingerprint from that certificate, and bind packageName/versionCode to the compiled AAB; AAB upload-key evidence is rejected and absence keeps passkey flags disabled',
]

function deepClone(value) {
  return value === null || value === undefined ? value : JSON.parse(JSON.stringify(value))
}

function assertPasskeyProductionConfig(config, label) {
  assertAllowedKeys(config, [
    'schemaVersion',
    'relyingPartyId',
    'challengeServiceBaseUrl',
    'healthPath',
    'releaseEnabled',
    'challengeServicePaths',
    'webauthnAllowedOrigins',
    'requestAuthorization',
    'credentialLifecycle',
    'encryptedBackupMetadata',
    'android',
    'ios',
  ], label)
  if (config.schemaVersion !== passkeyProductionSchemaVersion) fail(`${label}.schemaVersion must be ${passkeyProductionSchemaVersion}`)
  if (config.relyingPartyId !== passkeyProductionRpId) fail(`${label}.relyingPartyId mismatch`)
  if (config.challengeServiceBaseUrl !== passkeyProductionBaseUrl) fail(`${label}.challengeServiceBaseUrl mismatch`)
  if (config.healthPath !== passkeyProductionHealthPath) fail(`${label}.healthPath mismatch`)
  if (config.releaseEnabled !== false) fail(`${label}.releaseEnabled must be false`)
  assertObjectMap(config.challengeServicePaths, passkeyChallengeServicePaths, `${label}.challengeServicePaths`)
  assertExactStringArray(config.webauthnAllowedOrigins, passkeyProductionWebauthnAllowedOrigins, `${label}.webauthnAllowedOrigins`)
  assertAllowedKeys(config.requestAuthorization, [
    'mode',
    'audience',
    'credentialType',
    'bodyDigest',
    'introspectionUrlEnvironmentVariable',
    'failClosed',
    'stableCrossPlatformSubject',
    'prohibitedSubjectSources',
    'platformClaimValues',
    'protectedPaths',
  ], `${label}.requestAuthorization`)
  for (const [field, expected] of Object.entries(passkeyRequestAuthorization)) {
    if (config.requestAuthorization[field] !== expected) fail(`${label}.requestAuthorization.${field} mismatch`)
  }
  assertExactStringArray(config.requestAuthorization.prohibitedSubjectSources, passkeyRequestAuthorizationProhibitedSubjectSources, `${label}.requestAuthorization.prohibitedSubjectSources`)
  assertExactStringArray(config.requestAuthorization.platformClaimValues, passkeyRequestAuthorizationPlatformClaimValues, `${label}.requestAuthorization.platformClaimValues`)
  assertExactStringArray(config.requestAuthorization.protectedPaths, Object.values(passkeyChallengeServicePaths), `${label}.requestAuthorization.protectedPaths`)
  assertObjectMap(config.credentialLifecycle, passkeyCredentialLifecycle, `${label}.credentialLifecycle`)
  assertExactStringArray(config.encryptedBackupMetadata, passkeyEncryptedBackupMetadata, `${label}.encryptedBackupMetadata`)

  assertAllowedKeys(config.android, ['releaseEnabled', 'webauthnOrigin', 'backupStorage', 'googleDriveScope', 'oauthScope', 'releaseUxChecklist'], `${label}.android`)
  if (config.android.releaseEnabled !== false) fail(`${label}.android.releaseEnabled must be false`)
  if (config.android.webauthnOrigin !== passkeyAndroidWebauthnOrigin) fail(`${label}.android.webauthnOrigin mismatch`)
  if (config.android.backupStorage !== 'google-drive-appdata') fail(`${label}.android.backupStorage mismatch`)
  if (config.android.googleDriveScope !== 'https://www.googleapis.com/auth/drive.appdata') fail(`${label}.android.googleDriveScope mismatch`)
  if (config.android.oauthScope !== 'oauth2:https://www.googleapis.com/auth/drive.appdata') fail(`${label}.android.oauthScope mismatch`)
  assertExactStringArray(config.android.releaseUxChecklist, passkeyAndroidReleaseUxChecklist, `${label}.android.releaseUxChecklist`)

  assertAllowedKeys(config.ios, ['releaseEnabled', 'backupStorage', 'associatedDomain', 'cloudKitRecordType', 'cloudKitContainers', 'releaseUxChecklist'], `${label}.ios`)
  if (config.ios.releaseEnabled !== false) fail(`${label}.ios.releaseEnabled must be false`)
  if (config.ios.backupStorage !== 'cloudkit-private-database') fail(`${label}.ios.backupStorage mismatch`)
  if (config.ios.associatedDomain !== 'webcredentials:fearlesswallet.io') fail(`${label}.ios.associatedDomain mismatch`)
  if (config.ios.cloudKitRecordType !== 'FearlessPasskeyBackup') fail(`${label}.ios.cloudKitRecordType mismatch`)
  assertExactStringArray(config.ios.cloudKitContainers, passkeyIosCloudKitContainers, `${label}.ios.cloudKitContainers`)
  assertExactStringArray(config.ios.releaseUxChecklist, passkeyIosReleaseUxChecklist, `${label}.ios.releaseUxChecklist`)
}

function assertOpenApiResponseRef(operation, expectedRef, label) {
  const response = operation?.responses?.['200']?.content?.['application/json']?.schema
  if (!response || response.$ref !== expectedRef) fail(`${label}.responses.200 schema mismatch`)
}

function assertOpenApiErrorResponseRef(operation, status, expectedRef, label) {
  if (operation?.responses?.[status]?.$ref !== expectedRef) fail(`${label}.responses.${status} reference mismatch`)
}

function assertOpenApiErrorComponent(response, label) {
  if (response?.content?.['application/json']?.schema?.$ref !== '#/components/schemas/ErrorResponse') {
    fail(`${label} must reference #/components/schemas/ErrorResponse`)
  }
}

const passkeyOpenApiErrorResponseRefs = {
  400: '#/components/responses/BadRequest',
  401: '#/components/responses/AuthorizationFailed',
  403: '#/components/responses/AuthorizationForbidden',
  404: '#/components/responses/NotFound',
  409: '#/components/responses/Conflict',
  413: '#/components/responses/PayloadTooLarge',
  415: '#/components/responses/UnsupportedMediaType',
  429: '#/components/responses/RateLimited',
  500: '#/components/responses/InternalFailure',
  503: '#/components/responses/AuthorizationUnavailable',
}

function assertPasskeyOpenApi(openApi, label) {
  assertAllowedKeys(openApi, ['openapi', 'info', 'servers', 'paths', 'components'], label)
  if (openApi.openapi !== '3.1.0') fail(`${label}.openapi mismatch`)
  assertAllowedKeys(openApi.info, ['title', 'version', 'description'], `${label}.info`)
  if (openApi.info.title !== 'Fearless Passkey Backup Challenge Service') fail(`${label}.info.title mismatch`)
  if (openApi.info.version !== '1.0.0') fail(`${label}.info.version mismatch`)
  if (openApi.info.description !== passkeyOpenApiDescription) fail(`${label}.info.description mismatch`)
  if (!Array.isArray(openApi.servers) || openApi.servers.length !== 1) fail(`${label}.servers must contain exactly one server`)
  assertAllowedKeys(openApi.servers[0], ['url'], `${label}.servers[0]`)
  if (openApi.servers[0].url !== passkeyProductionBaseUrl) fail(`${label}.servers[0].url mismatch`)

  assertAllowedKeys(openApi.paths, passkeyProductionRoutePaths, `${label}.paths`)
  const health = openApi.paths[passkeyProductionHealthPath]?.get
  if (!health) fail(`${label}.paths.${passkeyProductionHealthPath}.get missing`)
  if (health.operationId !== 'getPasskeyBackupHealth') fail(`${label}.paths.${passkeyProductionHealthPath}.get.operationId mismatch`)
  assertOpenApiResponseRef(health, '#/components/schemas/HealthResponse', `${label}.paths.${passkeyProductionHealthPath}.get`)

  const routeExpectations = [
    [passkeyChallengeServicePaths.registrationChallenge, 'createPasskeyRegistrationChallenge', '#/components/schemas/RegistrationChallengeResponse', ['200', '400', '401', '403', '413', '415', '429', '500', '503']],
    [passkeyChallengeServicePaths.assertionChallenge, 'createPasskeyAssertionChallenge', '#/components/schemas/AssertionChallengeResponse', ['200', '400', '401', '403', '404', '413', '415', '429', '500', '503']],
    [passkeyChallengeServicePaths.registrationComplete, 'completePasskeyRegistration', '#/components/schemas/ChallengeResult', ['200', '400', '401', '403', '404', '409', '413', '415', '429', '500', '503']],
    [passkeyChallengeServicePaths.assertionComplete, 'completePasskeyAssertion', '#/components/schemas/ChallengeResult', ['200', '400', '401', '403', '404', '409', '413', '415', '429', '500', '503']],
    [passkeyChallengeServicePaths.credentialsList, 'listPasskeyCredentials', '#/components/schemas/CredentialListResponse', ['200', '400', '401', '403', '404', '413', '415', '429', '500', '503']],
    [passkeyChallengeServicePaths.credentialsRevoke, 'revokePasskeyCredential', '#/components/schemas/CredentialRevokeResponse', ['200', '400', '401', '403', '413', '415', '429', '500', '503']],
    [passkeyChallengeServicePaths.credentialsRevokeAll, 'revokeAllPasskeyCredentials', '#/components/schemas/CredentialRevokeAllResponse', ['200', '400', '401', '403', '413', '415', '429', '500', '503']],
  ]
  for (const [routePath, operationId, responseRef, responseStatuses] of routeExpectations) {
    const operation = openApi.paths[routePath]?.post
    if (!operation) fail(`${label}.paths.${routePath}.post missing`)
    if (operation.operationId !== operationId) fail(`${label}.paths.${routePath}.post.operationId mismatch`)
    if (operation.requestBody?.required !== true) fail(`${label}.paths.${routePath}.post.requestBody.required must be true`)
    if (!Array.isArray(operation.security) || operation.security.length !== 1 ||
        Object.keys(operation.security[0] ?? {}).length !== 1 ||
        !Array.isArray(operation.security[0]?.bearerAuth) || operation.security[0].bearerAuth.length !== 0) {
      fail(`${label}.paths.${routePath}.post.security must require bearerAuth`)
    }
    assertOpenApiResponseRef(operation, responseRef, `${label}.paths.${routePath}.post`)
    assertExactStringArray(Object.keys(operation.responses), responseStatuses, `${label}.paths.${routePath}.post.responses`)
    for (const status of responseStatuses.slice(1)) {
      assertOpenApiErrorResponseRef(operation, status, passkeyOpenApiErrorResponseRefs[status], `${label}.paths.${routePath}.post`)
    }
  }

  assertAllowedKeys(openApi.components, ['securitySchemes', 'responses', 'schemas'], `${label}.components`)
  const bearerAuth = openApi.components.securitySchemes?.bearerAuth
  if (bearerAuth?.type !== 'http' || bearerAuth?.scheme !== 'bearer') fail(`${label}.components.securitySchemes.bearerAuth mismatch`)
  for (const name of Object.values(passkeyOpenApiErrorResponseRefs).map((ref) => ref.split('/').at(-1))) {
    assertOpenApiErrorComponent(openApi.components.responses?.[name], `${label}.components.responses.${name}`)
  }
  const schemas = openApi.components?.schemas
  assertObject(schemas, `${label}.components.schemas`)
  const healthSchema = schemas.HealthResponse
  assertAllowedKeys(healthSchema, ['type', 'additionalProperties', 'required', 'properties'], `${label}.components.schemas.HealthResponse`)
  if (healthSchema.type !== 'object') fail(`${label}.components.schemas.HealthResponse.type mismatch`)
  if (healthSchema.additionalProperties !== false) fail(`${label}.components.schemas.HealthResponse.additionalProperties must be false`)
  assertExactStringArray(healthSchema.required, ['ok', 'service', 'rpId', 'schemaVersion'], `${label}.components.schemas.HealthResponse.required`)
  if (healthSchema.properties?.ok?.const !== true) fail(`${label}.components.schemas.HealthResponse.properties.ok.const mismatch`)
  if (healthSchema.properties?.service?.const !== passkeyProductionService) fail(`${label}.components.schemas.HealthResponse.properties.service.const mismatch`)
  if (healthSchema.properties?.rpId?.const !== passkeyProductionRpId) fail(`${label}.components.schemas.HealthResponse.properties.rpId.const mismatch`)
  if (healthSchema.properties?.schemaVersion?.const !== passkeyProductionSchemaVersion) fail(`${label}.components.schemas.HealthResponse.properties.schemaVersion.const mismatch`)
  if (schemas.RelyingPartyId?.const !== passkeyProductionRpId) fail(`${label}.components.schemas.RelyingPartyId.const mismatch`)
  if (schemas.SchemaVersion?.const !== passkeyProductionSchemaVersion) fail(`${label}.components.schemas.SchemaVersion.const mismatch`)
  if (schemas.Base64UrlUserId?.pattern !== '^[A-Za-z0-9_-]{43}$' ||
      schemas.Base64UrlUserId?.minLength !== 43 || schemas.Base64UrlUserId?.maxLength !== 43) {
    fail(`${label}.components.schemas.Base64UrlUserId must be canonical 43-character unpadded base64url`)
  }
  if (!schemas.AssertionAuthenticatorResponse?.required?.includes('userHandle') ||
      schemas.AssertionAuthenticatorResponse?.properties?.userHandle?.$ref !== '#/components/schemas/Base64UrlUserId') {
    fail(`${label}.components.schemas.AssertionAuthenticatorResponse.userHandle mismatch`)
  }
  assertExactStringArray(schemas.RegistrationChallengeResponse?.required, [
    'registrationId',
    'challenge',
    'userId',
    'userName',
    'displayName',
    'storageKey',
    'rpId',
    'schemaVersion',
  ], `${label}.components.schemas.RegistrationChallengeResponse.required`)
  assertExactStringArray(schemas.AssertionChallengeResponse?.required, [
    'assertionId',
    'challenge',
    'storageKey',
    'rpId',
    'schemaVersion',
  ], `${label}.components.schemas.AssertionChallengeResponse.required`)
  assertExactStringArray(schemas.ChallengeResult?.required, ['storageKey', 'rpId', 'schemaVersion'], `${label}.components.schemas.ChallengeResult.required`)
  assertExactStringArray(schemas.CredentialDescriptor?.required, ['id', 'aaguid', 'registrationPlatform', 'deviceType', 'backedUp'], `${label}.components.schemas.CredentialDescriptor.required`)
  assertAllowedKeys(schemas.CredentialDescriptor?.properties, ['id', 'aaguid', 'registrationPlatform', 'deviceType', 'backedUp', 'transports'], `${label}.components.schemas.CredentialDescriptor.properties`)
  if (schemas.CredentialListResponse?.properties?.credentials?.maxItems !== 32 ||
      schemas.CredentialListResponse?.properties?.credentials?.items?.$ref !== '#/components/schemas/CredentialDescriptor') {
    fail(`${label}.components.schemas.CredentialListResponse.credentials mismatch`)
  }
  assertExactStringArray(schemas.CredentialListResponse?.required, ['storageKey', 'credentials', 'rpId', 'schemaVersion'], `${label}.components.schemas.CredentialListResponse.required`)
  assertExactStringArray(schemas.CredentialRevokeResponse?.required, ['storageKey', 'credentialId', 'remainingCredentials', 'rpId', 'schemaVersion'], `${label}.components.schemas.CredentialRevokeResponse.required`)
  assertExactStringArray(schemas.CredentialRevokeAllResponse?.required, ['storageKey', 'remainingCredentials', 'rpId', 'schemaVersion'], `${label}.components.schemas.CredentialRevokeAllResponse.required`)
  if (schemas.CredentialRevokeResponse?.properties?.remainingCredentials?.minimum !== 0 ||
      schemas.CredentialRevokeResponse?.properties?.remainingCredentials?.maximum !== 32 ||
      schemas.CredentialRevokeAllResponse?.properties?.remainingCredentials?.const !== 0) {
    fail(`${label}.components.schemas credential revocation remainingCredentials mismatch`)
  }
}

function assertPasskeyProductionCompose(content, label) {
  requireString(content, label)
  const requiredFragments = [
    'passkey-backup-challenge-service:',
    'dockerfile: Dockerfile',
    'image: passkey-backup-challenge-service:release',
    'restart: unless-stopped',
    'NODE_ENV: production',
    'HOST: 0.0.0.0',
    'PORT: "8789"',
    'PASSKEY_ALLOWED_ORIGINS: https://fearlesswallet.io,https://backup.fearlesswallet.io',
    'PASSKEY_ANDROID_ALLOWED_ORIGIN: "${PASSKEY_ANDROID_ALLOWED_ORIGIN:?',
    'PASSKEY_AUTHORIZATION_INTROSPECTION_URL: "${PASSKEY_AUTHORIZATION_INTROSPECTION_URL:?',
    'PASSKEY_AUTHORIZATION_AUDIENCE: fearless-passkey-backup',
    'PASSKEY_AUTHORIZATION_TIMEOUT_MS: "2000"',
    'PASSKEY_AUTHORIZATION_MAX_TTL_SECONDS: "300"',
    'PASSKEY_TRUST_PROXY_HOPS: "1"',
    'PASSKEY_TRUSTED_PROXY_CIDRS: "${PASSKEY_TRUSTED_PROXY_CIDRS:?',
    'PASSKEY_CHALLENGE_TTL_MS: "300000"',
    'PASSKEY_MAX_CEREMONIES: "10000"',
    'PASSKEY_RATE_LIMIT_WINDOW_MS: "60000"',
    'PASSKEY_RATE_LIMIT_MAX_REQUESTS: "120"',
    'PASSKEY_GLOBAL_RATE_LIMIT_MAX_REQUESTS: "5000"',
    'PASSKEY_CREDENTIAL_STORE_FILE: /data/passkey-backup/credentials.json',
    '- "127.0.0.1:8789:8789"',
    '- passkey-backup-data:/data/passkey-backup',
    'http://127.0.0.1:8789/api/passkey-backup/v1/health',
    'passkey-backup-data:',
  ]
  for (const fragment of requiredFragments) {
    if (!content.includes(fragment)) fail(`${label} must include ${fragment}`)
  }
  if (/privileged:\s*true/.test(content)) fail(`${label} must not enable privileged mode`)
  if (/\.env/.test(content)) fail(`${label} must not depend on .env files`)
  if (/-\s*["']?(?:0\.0\.0\.0:)?8789:8789["']?/.test(content)) fail(`${label} must not expose the service port publicly`)
  for (const variable of ['PASSKEY_ANDROID_ALLOWED_ORIGIN', 'PASSKEY_AUTHORIZATION_INTROSPECTION_URL', 'PASSKEY_TRUSTED_PROXY_CIDRS']) {
    if (new RegExp(`\\$\\{${variable}:-`).test(content)) fail(`${label} must not provide a permissive fallback for ${variable}`)
  }
  assertNoSecretLike(label, content)
}

let passkeyProductionContractHandoffCache = null

function buildPasskeyProductionContractHandoff(blockerSlug, artifacts) {
  if (!passkeyProductionContractSlugs.has(blockerSlug)) return null
  if (passkeyProductionContractHandoffCache) return deepClone(passkeyProductionContractHandoffCache)

  const productionConfigSource = resolveWorkspaceFile(passkeyProductionConfigSourcePath, `${blockerSlug}.passkeyProductionContractHandoff.productionConfigSourcePath`)
  const productionConfig = readJson(productionConfigSource, `${blockerSlug} passkey production config`)
  assertPasskeyProductionConfig(productionConfig, `${blockerSlug}.passkeyProductionContract.productionConfig`)
  copyCheckedArtifact(productionConfigSource, passkeyProductionConfigArtifactPath, artifacts)
  const productionConfigArtifact = artifacts.find((item) => item.path === passkeyProductionConfigArtifactPath)

  const openApiSource = resolveWorkspaceFile(passkeyOpenApiSourcePath, `${blockerSlug}.passkeyProductionContractHandoff.openApiSourcePath`)
  const openApi = readJson(openApiSource, `${blockerSlug} passkey OpenAPI contract`)
  assertPasskeyOpenApi(openApi, `${blockerSlug}.passkeyProductionContract.openApi`)
  copyCheckedArtifact(openApiSource, passkeyOpenApiArtifactPath, artifacts)
  const openApiArtifact = artifacts.find((item) => item.path === passkeyOpenApiArtifactPath)

  const composeSource = resolveWorkspaceFile(passkeyProductionComposeSourcePath, `${blockerSlug}.passkeyProductionContractHandoff.composeSourcePath`)
  assertRegularFile(composeSource, `${blockerSlug}.passkeyProductionContractHandoff.composeSourcePath`)
  const composeContent = fs.readFileSync(composeSource, 'utf8')
  assertPasskeyProductionCompose(composeContent, `${blockerSlug}.passkeyProductionContract.compose`)
  copyCheckedArtifact(composeSource, passkeyProductionComposeArtifactPath, artifacts)
  const composeArtifact = artifacts.find((item) => item.path === passkeyProductionComposeArtifactPath)

  passkeyProductionContractHandoffCache = {
    productionConfigSourcePath: passkeyProductionConfigSourcePath,
    productionConfigArtifact: passkeyProductionConfigArtifactPath,
    productionConfigSha256: productionConfigArtifact.sha256,
    openApiSourcePath: passkeyOpenApiSourcePath,
    openApiArtifact: passkeyOpenApiArtifactPath,
    openApiSha256: openApiArtifact.sha256,
    composeSourcePath: passkeyProductionComposeSourcePath,
    composeArtifact: passkeyProductionComposeArtifactPath,
    composeSha256: composeArtifact.sha256,
    service: passkeyProductionService,
    baseUrl: productionConfig.challengeServiceBaseUrl,
    rpId: productionConfig.relyingPartyId,
    schemaVersion: productionConfig.schemaVersion,
    healthPath: productionConfig.healthPath,
    androidSignerEvidence: deepClone(passkeyAndroidSignerEvidence),
    requiredRoutePaths: [...passkeyProductionRoutePaths],
    requiredContracts: [...passkeyProductionRequiredContracts],
    verificationCommands: [...passkeyProductionVerificationCommands],
  }
  return deepClone(passkeyProductionContractHandoffCache)
}

function buildIndexerDeploymentTemplateHandoff(blockerSlug, artifacts) {
  const config = indexerDeploymentTemplateConfigs[blockerSlug]
  if (!config) return null

  const source = resolveReportFile(config.sourceReportPath, `${blockerSlug}.indexerDeploymentTemplateHandoff.sourceReportPath`)
  const template = readJson(source, `${blockerSlug} deployment evidence template`)
  assertIndexerDeploymentEvidenceTemplate(template, `${blockerSlug}.indexerDeploymentEvidenceTemplate`, config)
  copyCheckedArtifact(source, config.templateArtifact, artifacts)
  const artifact = artifacts.find((item) => item.path === config.templateArtifact)

  return {
    sourceReportPath: config.sourceReportPath,
    templateArtifact: config.templateArtifact,
    templateSha256: artifact.sha256,
    generatedTemplatePath: config.generatedTemplatePath,
    destinationManifest: config.destinationManifest,
    serviceId: config.serviceId,
    baseUrl: config.baseUrl,
    status: config.status,
    releaseEnabled: config.releaseEnabled,
    requiredEvidenceFields: [...config.requiredEvidenceFields],
    placeholderRecord: { ...config.placeholderRecord },
    serviceInfoTarget: config.serviceInfoTarget ? structuredClone(config.serviceInfoTarget) : null,
    healthInfoTarget: structuredClone(config.healthInfoTarget),
    ...(config.soraRpcControlsTarget
      ? { soraRpcControlsTarget: structuredClone(config.soraRpcControlsTarget) }
      : {}),
    ...(config.tlsEdgeControlsTarget
      ? { tlsEdgeControlsTarget: structuredClone(config.tlsEdgeControlsTarget) }
      : {}),
    readyAuditCommand: config.readyAuditCommand,
    requiredContracts: [...config.requiredContracts],
  }
}

const nexusProductionEvidenceTemplateSourcePath = 'nexus-production-evidence-template.json'
const nexusProductionEvidenceTemplateArtifactPath = 'handoffs/nexus-production-evidence-template.json'
const nexusProductionEvidenceReadyVerificationCommands = [
  'bash scripts/test-nexus-production-evidence-template.sh',
  'bash scripts/generate-nexus-production-evidence-template.sh --output build/reports/nexus-production-evidence-template.json',
  'bash scripts/test-nexus-production-evidence-audit.sh',
  'bash scripts/audit-nexus-production-evidence.sh --require-ready',
  'IROHA_NEXUS_REQUIRE_PRODUCTION_EVIDENCE=1 IROHA_NEXUS_LIVE_HEALTH=1 bash scripts/audit-iroha-release-readiness.sh',
  'bash scripts/audit-iroha-wallet-coverage.sh',
]
const nexusProductionEvidenceRequiredFields = [
  'routeManifestCommit',
  'routeManifestSourcePath',
  'routeManifestHash',
  'publicationTransactionHash',
  'publicationAuthority',
  'publishedAt',
  'routeCanaryTransactionHash',
  'routeCanaryCheckedAt',
  'routeCanarySourceAccount',
  'routeCanaryDestinationAccount',
  'routeCanaryAssetId',
  'routeCanaryAmount',
  'walletPlatform',
  'walletCommit',
  'walletSmokeTransactionHash',
  'walletSmokeSubmittedAt',
  'walletSmokeObservedAt',
  'operator',
]
const nexusRoutePublicationPlaceholder = {
  routeManifestCommit: 'TODO_40_HEX_ROUTE_MANIFEST_COMMIT',
  routeManifestSourcePath: 'artifacts/nexus/production-route-governance-action.json',
  routeManifestHash: 'sha256:TODO_64_HEX_ROUTE_MANIFEST_HASH',
  publicationTransactionHash: '0xTODO_64_HEX_PUBLICATION_TX_HASH',
  publicationAuthority: 'TODO_PUBLICATION_AUTHORITY',
  publishedAt: 'TODO_UTC_ROUTE_PUBLISHED_AT_RFC3339',
  toriiBaseUrl: 'https://minamoto.sora.org',
  mcpUrl: 'https://minamoto.sora.org/v1/mcp',
  operator: 'TODO_RELEASE_OPERATOR',
}
const nexusRouteCanaryPlaceholder = {
  publishedRouteManifestHash: 'sha256:TODO_64_HEX_ROUTE_MANIFEST_HASH',
  routeCanaryTransactionHash: '0xTODO_64_HEX_CANARY_TX_HASH',
  authority: 'TODO_CANARY_AUTHORITY',
  sourceAccount: 'TODO_NEXUS_CANARY_SOURCE_ACCOUNT',
  destinationAccount: 'TODO_NEXUS_CANARY_DESTINATION_ACCOUNT',
  assetId: 'xor#sora',
  amount: 'TODO_POSITIVE_DECIMAL_AMOUNT',
  routeCanaryCheckedAt: 'TODO_UTC_CANARY_CHECKED_WITHIN_24_HOURS_AT_RFC3339',
  toriiBaseUrl: 'https://minamoto.sora.org',
  operator: 'TODO_RELEASE_OPERATOR',
}
const nexusProductionEvidenceTemplateContracts = [
  'template status must be ready with releaseEnabled=true for operator fill-in',
  'template placeholders must fail --require-ready until Nexus production evidence is recorded',
  'routePublicationEvidence.routeManifestCommit must match the Iroha release commit',
  'routeManifestSourcePath must pin artifacts/nexus/production-route-governance-action.json at routeManifestCommit and routeManifestHash must be recomputed from its canonical ApplySccpRouteGovernance Norito bytes',
  'routeCanaryEvidence.publishedRouteManifestHash must match routePublicationEvidence.routeManifestHash',
  'walletSmokeEvidence must include android, ios, and web',
  'walletSmokeEvidence.walletCommit must match each wallet release commit',
  'toriiBaseUrl must remain https://minamoto.sora.org',
  'ready evidence must verify committed transaction status and exactly one matching instruction through credential-free canonical Minamoto Torii and MCP requests',
  'self-test receipt fixtures must be temporary and cannot satisfy --require-ready',
]

function nexusWalletSmokePlaceholders() {
  const routeManifestHash = 'sha256:TODO_64_HEX_ROUTE_MANIFEST_HASH'
  return {
    android: {
      platform: 'android',
      walletCommit: 'TODO_40_HEX_ANDROID_WALLET_COMMIT',
      routeManifestHash,
      walletSmokeTransactionHash: '0xTODO_64_HEX_ANDROID_WALLET_SMOKE_TX_HASH',
      sourceAccount: 'TODO_NEXUS_ANDROID_SOURCE_ACCOUNT',
      destinationAccount: 'TODO_NEXUS_ANDROID_DESTINATION_ACCOUNT',
      assetId: 'xor#sora',
      amount: 'TODO_POSITIVE_DECIMAL_AMOUNT',
      walletSmokeSubmittedAt: 'TODO_UTC_ANDROID_WALLET_SMOKE_SUBMITTED_AT_RFC3339',
      walletSmokeObservedAt: 'TODO_UTC_ANDROID_WALLET_SMOKE_OBSERVED_WITHIN_24_HOURS_AT_RFC3339',
      toriiBaseUrl: 'https://minamoto.sora.org',
      operator: 'TODO_RELEASE_OPERATOR',
    },
    ios: {
      platform: 'ios',
      walletCommit: 'TODO_40_HEX_IOS_WALLET_COMMIT',
      routeManifestHash,
      walletSmokeTransactionHash: '0xTODO_64_HEX_IOS_WALLET_SMOKE_TX_HASH',
      sourceAccount: 'TODO_NEXUS_IOS_SOURCE_ACCOUNT',
      destinationAccount: 'TODO_NEXUS_IOS_DESTINATION_ACCOUNT',
      assetId: 'xor#sora',
      amount: 'TODO_POSITIVE_DECIMAL_AMOUNT',
      walletSmokeSubmittedAt: 'TODO_UTC_IOS_WALLET_SMOKE_SUBMITTED_AT_RFC3339',
      walletSmokeObservedAt: 'TODO_UTC_IOS_WALLET_SMOKE_OBSERVED_WITHIN_24_HOURS_AT_RFC3339',
      toriiBaseUrl: 'https://minamoto.sora.org',
      operator: 'TODO_RELEASE_OPERATOR',
    },
    web: {
      platform: 'web',
      walletCommit: 'TODO_40_HEX_WEB_WALLET_COMMIT',
      routeManifestHash,
      walletSmokeTransactionHash: '0xTODO_64_HEX_WEB_WALLET_SMOKE_TX_HASH',
      sourceAccount: 'TODO_NEXUS_WEB_SOURCE_ACCOUNT',
      destinationAccount: 'TODO_NEXUS_WEB_DESTINATION_ACCOUNT',
      assetId: 'xor#sora',
      amount: 'TODO_POSITIVE_DECIMAL_AMOUNT',
      walletSmokeSubmittedAt: 'TODO_UTC_WEB_WALLET_SMOKE_SUBMITTED_AT_RFC3339',
      walletSmokeObservedAt: 'TODO_UTC_WEB_WALLET_SMOKE_OBSERVED_WITHIN_24_HOURS_AT_RFC3339',
      toriiBaseUrl: 'https://minamoto.sora.org',
      operator: 'TODO_RELEASE_OPERATOR',
    },
  }
}

function assertNexusProductionEvidenceTemplate(template, label) {
  assertAllowedKeys(template, [
    'schemaVersion',
    'scope',
    'network',
    'chainId',
    'toriiBaseUrl',
    'mcpUrl',
    'healthUrl',
    'status',
    'releaseEnabled',
    'blockers',
    'readyVerificationCommands',
    'requiredEvidenceFields',
    'routePublicationEvidence',
    'routeCanaryEvidence',
    'walletSmokeEvidence',
  ], label)
  if (template.schemaVersion !== 1) fail(`${label}.schemaVersion must be 1`)
  if (template.scope !== 'sora-nexus-production-readiness') fail(`${label}.scope mismatch`)
  if (template.network !== 'sora-nexus-mainnet') fail(`${label}.network mismatch`)
  if (template.chainId !== 'sora:nexus:global') fail(`${label}.chainId mismatch`)
  if (template.toriiBaseUrl !== 'https://minamoto.sora.org') fail(`${label}.toriiBaseUrl mismatch`)
  if (template.mcpUrl !== 'https://minamoto.sora.org/v1/mcp') fail(`${label}.mcpUrl mismatch`)
  if (template.healthUrl !== 'https://minamoto.sora.org/status') fail(`${label}.healthUrl mismatch`)
  if (template.status !== 'ready') fail(`${label}.status must be ready`)
  if (template.releaseEnabled !== true) fail(`${label}.releaseEnabled must be true`)
  assertExactStringArray(template.blockers, [], `${label}.blockers`)
  assertExactStringArray(template.readyVerificationCommands, nexusProductionEvidenceReadyVerificationCommands, `${label}.readyVerificationCommands`)
  assertExactStringArray(template.requiredEvidenceFields, nexusProductionEvidenceRequiredFields, `${label}.requiredEvidenceFields`)

  if (!Array.isArray(template.routePublicationEvidence) || template.routePublicationEvidence.length !== 1) {
    fail(`${label}.routePublicationEvidence must contain exactly one fill-in record`)
  }
  assertObjectMap(template.routePublicationEvidence[0], nexusRoutePublicationPlaceholder, `${label}.routePublicationEvidence[0]`)

  if (!Array.isArray(template.routeCanaryEvidence) || template.routeCanaryEvidence.length !== 1) {
    fail(`${label}.routeCanaryEvidence must contain exactly one fill-in record`)
  }
  assertObjectMap(template.routeCanaryEvidence[0], nexusRouteCanaryPlaceholder, `${label}.routeCanaryEvidence[0]`)

  if (!Array.isArray(template.walletSmokeEvidence) || template.walletSmokeEvidence.length !== 3) {
    fail(`${label}.walletSmokeEvidence must contain android, ios, and web fill-in records`)
  }
  const expectedWalletSmoke = nexusWalletSmokePlaceholders()
  const seenPlatforms = new Set()
  for (const [index, evidence] of template.walletSmokeEvidence.entries()) {
    requireSingleLine(evidence.platform, `${label}.walletSmokeEvidence[${index}].platform`)
    const expected = expectedWalletSmoke[evidence.platform]
    if (!expected) fail(`${label}.walletSmokeEvidence[${index}].platform unsupported: ${evidence.platform}`)
    if (seenPlatforms.has(evidence.platform)) fail(`${label}.walletSmokeEvidence duplicate platform: ${evidence.platform}`)
    seenPlatforms.add(evidence.platform)
    assertObjectMap(evidence, expected, `${label}.walletSmokeEvidence[${index}]`)
  }
  for (const platform of ['android', 'ios', 'web']) {
    if (!seenPlatforms.has(platform)) fail(`${label}.walletSmokeEvidence missing ${platform}`)
  }
}

function buildNexusProductionEvidenceTemplateHandoff(blockerSlug, artifacts) {
  if (blockerSlug !== 'iroha-release-readiness') return null

  const source = resolveReportFile(nexusProductionEvidenceTemplateSourcePath, `${blockerSlug}.nexusProductionEvidenceTemplateHandoff.sourceReportPath`)
  const template = readJson(source, `${blockerSlug} Nexus production evidence template`)
  assertNexusProductionEvidenceTemplate(template, `${blockerSlug}.nexusProductionEvidenceTemplate`)
  copyCheckedArtifact(source, nexusProductionEvidenceTemplateArtifactPath, artifacts)
  const artifact = artifacts.find((item) => item.path === nexusProductionEvidenceTemplateArtifactPath)

  return {
    sourceReportPath: nexusProductionEvidenceTemplateSourcePath,
    templateArtifact: nexusProductionEvidenceTemplateArtifactPath,
    templateSha256: artifact.sha256,
    generatedTemplatePath: 'build/reports/nexus-production-evidence-template.json',
    destinationManifest: 'config/nexus-production-evidence.json',
    network: template.network,
    chainId: template.chainId,
    toriiBaseUrl: template.toriiBaseUrl,
    mcpUrl: template.mcpUrl,
    healthUrl: template.healthUrl,
    status: template.status,
    releaseEnabled: template.releaseEnabled,
    requiredEvidenceFields: [...nexusProductionEvidenceRequiredFields],
    routePublicationPlaceholder: { ...nexusRoutePublicationPlaceholder },
    routeCanaryPlaceholder: { ...nexusRouteCanaryPlaceholder },
    walletSmokePlaceholders: structuredClone(nexusWalletSmokePlaceholders()),
    readyAuditCommand: 'bash scripts/audit-nexus-production-evidence.sh --require-ready',
    strictReleaseReadinessCommand: 'IROHA_NEXUS_REQUIRE_PRODUCTION_EVIDENCE=1 IROHA_NEXUS_LIVE_HEALTH=1 bash scripts/audit-iroha-release-readiness.sh',
    requiredContracts: [...nexusProductionEvidenceTemplateContracts],
  }
}

const xcmProductionEvidenceTemplateSourcePath = 'android-xcm-production-evidence-template.json'
const xcmProductionEvidenceTemplateArtifactPath = 'handoffs/android-xcm-production-evidence-template.json'
const xcmProductionEvidenceRequiredFields = [
  'originChainId',
  'destinationChainId',
  'assetSymbol',
  'extrinsicHash',
  'originBlockHash',
  'originBlockNumber',
  'originFinalized',
  'originExtrinsicSucceeded',
  'sender',
  'recipient',
  'amount',
  'timestamp',
  'destinationBlockHash',
  'destinationBlockNumber',
  'destinationEventSucceeded',
  'destinationBalanceDelta',
  'originVerificationUrl',
  'destinationVerificationUrl',
  'verificationMethod',
  'verifiedAt',
  'independentVerifier',
  'environment',
  'operator',
  'androidCommit',
]
const xcmProductionEvidenceRequiredFieldCount = 24
const xcmProductionEvidencePlaceholderRecord = {
  extrinsicHash: 'TODO_0x_prefixed_32_byte_hash',
  originBlockHash: 'TODO_origin_0x_prefixed_32_byte_block_hash',
  originBlockNumber: 'TODO_origin_positive_block_number',
  originFinalized: false,
  originExtrinsicSucceeded: false,
  sender: 'TODO_sender_public_address',
  recipient: 'TODO_recipient_public_address',
  amount: 'TODO_positive_decimal_amount',
  timestamp: 'TODO_YYYY-MM-DDTHH:MM:SSZ',
  destinationBlockHash: 'TODO_destination_0x_prefixed_32_byte_block_hash',
  destinationBlockNumber: 'TODO_destination_positive_block_number',
  destinationEventSucceeded: false,
  destinationBalanceDelta: 'TODO_positive_destination_balance_delta',
  originVerificationUrl: 'TODO_public_https_origin_proof_url',
  destinationVerificationUrl: 'TODO_public_https_destination_proof_url',
  verificationMethod: 'canonical-rpc-and-explorer',
  verifiedAt: 'TODO_YYYY-MM-DDTHH:MM:SSZ',
  independentVerifier: 'TODO_independent_verifier_or_runbook_id',
  environment: 'mainnet',
  operator: 'TODO_operator_or_runbook_id',
  androidCommit: 'TODO_android_release_commit',
}
const xcmProductionEvidenceTemplateInstructions = [
  'Copy the evidence array into scripts/xcm-production-evidence.json only after replacing every TODO value.',
  'Do not include private keys, mnemonics, seeds, passwords, credentials, or authorization headers in public evidence.',
  'Independently verify finalized origin inclusion/success and destination execution/balance delta against canonical RPCs plus public proof links; the offline audit checks the attestation shape, not chain truth.',
  'Set every success/finality boolean to true only after verification, and use an independentVerifier that differs from operator.',
  'Set lastReviewed in scripts/xcm-production-evidence.json to a valid UTC YYYY-MM-DD date on or after the UTC calendar date of every timestamp and verifiedAt value; same-day values through 23:59:59Z are valid.',
  'Set androidCommit to the Android release commit under validation; for tagged release validation you may set XCM_PRODUCTION_EXPECTED_COMMIT when running the audit.',
  'After every route has evidence and no discovery-only gaps remain, set status to ready, releaseEnabled to true, clear blockers, then regenerate the canonical live report and validate it with the evidence in one command: bash ./scripts/audit-xcm-effective-registry.sh --discovery-url https://raw.githubusercontent.com/soramitsu/shared-features-utils/master/chains/v13/chains.json --require-all-approved --write-report build/reports/xcm-effective-registry-report.json && bash ./scripts/audit-xcm-production-evidence.sh --effective-registry-report build/reports/xcm-effective-registry-report.json --require-ready.',
]
const xcmProductionEvidenceTemplateContracts = [
  'template must contain one evidence record per scripts/xcm-required-routes.tsv route',
  'template placeholders must fail --require-ready until funded route evidence is recorded',
  'extrinsicHash placeholder must be replaced with a 0x-prefixed 32-byte hash',
  'environment must remain mainnet',
  'androidCommit must be replaced with the Android release commit under validation',
  'scripts/xcm-discovery-only-routes.tsv must be empty before ready evidence can pass',
  'the canonical live effective-registry report must be regenerated and validate complete approved/effective parity before ready evidence can pass',
]

function assertXcmRequiredRouteSourcePath(value, label) {
  requireSingleLine(value, label)
  assertNoSecretLike(label, value)
  if (value !== 'fearless-Android/scripts/xcm-required-routes.tsv' && !value.endsWith('/fearless-Android/scripts/xcm-required-routes.tsv')) {
    fail(`${label} must point at fearless-Android/scripts/xcm-required-routes.tsv`)
  }
}

function assertXcmProductionEvidenceTemplate(template, label) {
  assertAllowedKeys(template, ['schemaVersion', 'scope', 'sourceRequiredRouteFile', 'requiredRouteCount', 'instructions', 'requiredEvidenceFields', 'evidence'], label)
  if (template.schemaVersion !== 1) fail(`${label}.schemaVersion must be 1`)
  if (template.scope !== 'android-xcm-production-evidence-template') fail(`${label}.scope mismatch`)
  assertXcmRequiredRouteSourcePath(template.sourceRequiredRouteFile, `${label}.sourceRequiredRouteFile`)
  requireNumber(template.requiredRouteCount, `${label}.requiredRouteCount`)
  if (template.requiredRouteCount === 0) fail(`${label}.requiredRouteCount must be positive`)
  if (!Array.isArray(template.instructions)) fail(`${label}.instructions must be an array`)
  if (template.instructions.length !== xcmProductionEvidenceTemplateInstructions.length) fail(`${label}.instructions length mismatch`)
  for (const [index, expectedInstruction] of xcmProductionEvidenceTemplateInstructions.entries()) {
    requireSingleLine(template.instructions[index], `${label}.instructions[${index}]`)
    if (template.instructions[index] !== expectedInstruction) fail(`${label}.instructions[${index}] mismatch`)
  }
  if (xcmProductionEvidenceRequiredFields.length !== xcmProductionEvidenceRequiredFieldCount) fail(`${label} internal required-evidence field contract mismatch`)
  assertExactStringArray(template.requiredEvidenceFields, xcmProductionEvidenceRequiredFields, `${label}.requiredEvidenceFields`)
  if (!Array.isArray(template.evidence)) fail(`${label}.evidence must be an array`)
  if (template.evidence.length !== template.requiredRouteCount) {
    fail(`${label}.evidence length must match requiredRouteCount`)
  }
  const seenRoutes = new Set()
  for (const [index, evidence] of template.evidence.entries()) {
    assertAllowedKeys(evidence, xcmProductionEvidenceRequiredFields, `${label}.evidence[${index}]`)
    for (const field of ['originChainId', 'destinationChainId', 'assetSymbol']) {
      requireSingleLine(evidence[field], `${label}.evidence[${index}].${field}`)
      assertNoSecretLike(`${label}.evidence[${index}].${field}`, evidence[field])
    }
    const routeKey = `${evidence.originChainId}|${evidence.destinationChainId}|${evidence.assetSymbol}`
    if (seenRoutes.has(routeKey)) fail(`${label}.evidence duplicate route: ${routeKey}`)
    seenRoutes.add(routeKey)
    for (const [field, placeholder] of Object.entries(xcmProductionEvidencePlaceholderRecord)) {
      if (typeof placeholder === 'boolean') {
        requireBoolean(evidence[field], `${label}.evidence[${index}].${field}`)
      } else {
        requireSingleLine(evidence[field], `${label}.evidence[${index}].${field}`)
        assertNoSecretLike(`${label}.evidence[${index}].${field}`, evidence[field])
      }
      if (evidence[field] !== placeholder) {
        fail(`${label}.evidence[${index}].${field} placeholder mismatch`)
      }
    }
  }
}

function buildXcmProductionEvidenceTemplateHandoff(blockerSlug, artifacts) {
  if (blockerSlug !== 'android-xcm-production-evidence') return null

  const source = resolveReportFile(xcmProductionEvidenceTemplateSourcePath, `${blockerSlug}.xcmProductionEvidenceTemplateHandoff.sourceReportPath`)
  const template = readJson(source, `${blockerSlug} XCM production evidence template`)
  assertXcmProductionEvidenceTemplate(template, `${blockerSlug}.xcmProductionEvidenceTemplate`)
  copyCheckedArtifact(source, xcmProductionEvidenceTemplateArtifactPath, artifacts)
  const artifact = artifacts.find((item) => item.path === xcmProductionEvidenceTemplateArtifactPath)

  return {
    sourceReportPath: xcmProductionEvidenceTemplateSourcePath,
    templateArtifact: xcmProductionEvidenceTemplateArtifactPath,
    templateSha256: artifact.sha256,
    generatedTemplatePath: 'fearless-Android/build/reports/xcm-production-evidence-template.json',
    destinationManifest: 'fearless-Android/scripts/xcm-production-evidence.json',
    requiredRouteFile: 'fearless-Android/scripts/xcm-required-routes.tsv',
    discoveryGapFile: 'fearless-Android/scripts/xcm-discovery-only-routes.tsv',
    requiredRouteCount: template.requiredRouteCount,
    requiredEvidenceFields: [...xcmProductionEvidenceRequiredFields],
    placeholderRecord: { ...xcmProductionEvidencePlaceholderRecord },
    readyAuditCommand: 'cd fearless-Android && bash scripts/audit-xcm-effective-registry.sh --discovery-url https://raw.githubusercontent.com/soramitsu/shared-features-utils/master/chains/v13/chains.json --require-all-approved --write-report build/reports/xcm-effective-registry-report.json && bash scripts/audit-xcm-production-evidence.sh --effective-registry-report build/reports/xcm-effective-registry-report.json --require-ready',
    requiredContracts: [...xcmProductionEvidenceTemplateContracts],
  }
}

function buildXcmRegistryHandoff(blockerSlug, artifacts, runLive) {
  if (blockerSlug !== 'android-xcm-production-evidence') return null

  const reportSourcePath = 'android-xcm-registry-gap-report.json'
  const artifactPath = 'handoffs/android-xcm-registry-gap-report.json'
  const source = resolveReportFile(reportSourcePath, `${blockerSlug}.xcmRegistryHandoff.sourceReportPath`)
  const report = readJson(source, `${blockerSlug} XCM registry gap report`)
  assertXcmRegistryGapReport(report, `${blockerSlug}.xcmRegistryGapReport`)
  copyArtifact(source, artifactPath, artifacts)
  const artifact = artifacts.find((item) => item.path === artifactPath)

  const effectiveSource = resolveReportFile(xcmEffectiveRegistrySourcePath, `${blockerSlug}.xcmRegistryHandoff.effectiveRegistry.sourceReportPath`)
  const effectiveReport = readJson(effectiveSource, `${blockerSlug} XCM effective registry report`)
  assertXcmEffectiveRegistryReport(effectiveReport, `${blockerSlug}.xcmEffectiveRegistryReport`, runLive, true)
  copyCheckedArtifact(effectiveSource, xcmEffectiveRegistryArtifactPath, artifacts)
  const effectiveArtifact = artifacts.find((item) => item.path === xcmEffectiveRegistryArtifactPath)

  return {
    sourceReportPath: reportSourcePath,
    gapReportArtifact: artifactPath,
    gapReportSha256: artifact.sha256,
    registryFile: report.registryFile,
    requiredRouteFile: 'fearless-Android/scripts/xcm-required-routes.tsv',
    discoveryGapFile: 'fearless-Android/scripts/xcm-discovery-only-routes.tsv',
    generatedGapReportPath: 'fearless-Android/build/reports/xcm-registry-gap-report.json',
    remainingDiscoveryOnlyDestinations: report.summary.remainingDiscoveryOnlyDestinations,
    remainingDiscoveryOnlyRouteAssets: report.summary.remainingDiscoveryOnlyRouteAssets,
    missingExecutableDestinationCount: report.missingExecutableDestinations.length,
    registryAuditCommand: 'cd fearless-Android && bash scripts/audit-xcm-registry-metadata.sh --require-executable --write-gap-report build/reports/xcm-registry-gap-report.json --require-route-file scripts/xcm-required-routes.tsv --require-gap-file scripts/xcm-discovery-only-routes.tsv --require-all-routes-executable',
    effectiveRegistry: {
      sourceReportPath: xcmEffectiveRegistrySourcePath,
      reportArtifact: xcmEffectiveRegistryArtifactPath,
      reportSha256: effectiveArtifact.sha256,
      generatedReportPath: xcmEffectiveRegistryGeneratedPath,
      mode: effectiveReport.mode,
      status: effectiveReport.status,
      auditCommand: xcmEffectiveRegistryAuditCommands[effectiveReport.mode],
      policy: structuredClone(effectiveReport.policy),
      inputContentIdentities: {
        approvedRoutes: structuredClone(effectiveReport.inputs.approvedRoutes),
        requiredRoutes: structuredClone(effectiveReport.inputs.requiredRoutes),
        bundledRegistry: structuredClone(effectiveReport.inputs.bundledRegistry),
      },
      discoveryRegistry: effectiveReport.inputs.discoveryRegistry === null
        ? null
        : structuredClone(effectiveReport.inputs.discoveryRegistry),
      counts: {
        approved: effectiveReport.summary.approved,
        effective: effectiveReport.summary.effective,
        productionExecutable: effectiveReport.summary.productionExecutable,
        missing: effectiveReport.summary.missing,
        extra: effectiveReport.summary.extra,
      },
    },
    requiredContracts: [
      'missingExecutableDestinations must match scripts/xcm-discovery-only-routes.tsv',
      'summary.remainingDiscoveryOnlyDestinations must be zero before broad release',
      'summary.remainingDiscoveryOnlyRouteAssets must be zero before broad release',
      'every scripts/xcm-required-routes.tsv route must remain executable',
      'effective routes are compatible approved candidates, not enabled production execution',
      'productionExecutable must remain zero while ENABLE_PRODUCTION_XCM_TRANSFERS is false',
      'remote discovery execution is never trusted or executable',
      'live discovery compatibility evidence does not attest the persisted runtime snapshot or freshness',
      'runtime discovery is narrowing-only and requires a successful current-process canonical sync snapshot',
    ],
  }
}

function assertTotals(value, label) {
  assertAllowedKeys(value, ['passed', 'failed', 'skipped', 'total'], label)
  for (const key of ['passed', 'failed', 'skipped', 'total']) {
    requireNumber(value[key], `${label}.${key}`)
  }
  if (value.passed + value.failed + value.skipped !== value.total) {
    fail(`${label} counts must sum to total`)
  }
}

function assertOverallStatus(status, totals, runLive, label) {
  requireString(status, label)
  if (!['passed', 'failed', 'incomplete'].includes(status)) fail(`${label} unsupported: ${status}`)
  if (totals.failed > 0 && status !== 'failed') fail(`${label} must be failed when failed total is greater than zero`)
  if (totals.failed === 0 && (totals.skipped > 0 || runLive !== true) && status !== 'incomplete') {
    fail(`${label} must be incomplete when required live checks are skipped or runLive is false`)
  }
  if (totals.failed === 0 && totals.skipped === 0 && runLive === true && status !== 'passed') {
    fail(`${label} must be passed only when every live check passed`)
  }
}

const blockerKeys = [
  'name',
  'slug',
  'exitCode',
  'logFile',
  'recommendedAction',
  'requiresExternalAction',
  'unblockCategory',
  'externalPrerequisite',
  'verificationCommand',
  'evidencePreview',
]

const supportedUnblockCategories = new Set([
  'deployment-evidence',
  'funded-broadcast-evidence',
  'funded-route-evidence',
  'route-implementation-and-evidence',
  'github-admin',
  'live-service-and-evidence',
  'live-service-deployment',
  'live-service-routing',
  'local-code',
  'private-overlay-cleanup',
  'review-and-merge',
  'source-publication',
  'upstream-dependency',
])

const expectedCheckNamesBySlug = new Map([
  ['plan-readiness', 'Static cross-repo plan readiness'],
  ['github-governance', 'GitHub governance'],
  ['release-pr-readiness', 'Release PR readiness'],
  ['private-overlay-readiness', 'Private overlay readiness'],
  ['android-public-dependency-provenance', 'Android public dependency provenance'],
  ['ios-shared-features-delta', 'iOS shared-features dependency delta'],
  ['passkey-challenge-service', 'Passkey challenge service implementation'],
  ['passkey-deployment-evidence', 'Passkey deployment evidence'],
  ['passkey-backup-prerequisites', 'Passkey backup prerequisites'],
  ['passkey-production-smoke', 'Passkey production smoke'],
  ['iroha-release-readiness', 'Iroha/Nexus release prerequisites'],
  ['iroha-wallet-coverage', 'Iroha/Nexus wallet coverage'],
  ['android-xcm-production-evidence', 'Android XCM production evidence'],
  ['web-bitcoin-broadcast-evidence', 'Web Bitcoin broadcast evidence'],
  ['ti-deployment-evidence', 'TI deployment evidence'],
  ['si-deployment-evidence', 'SI deployment evidence'],
  ['pi-deployment-evidence', 'PI deployment evidence'],
  ['ti-production-smoke', 'TI production smoke'],
  ['si-production-smoke', 'SI production smoke'],
  ['pi-production-smoke', 'PI production smoke'],
  ['source-publication-readiness', 'Source publication readiness'],
])

const expectedCheckOrderSlugs = [...expectedCheckNamesBySlug.keys()]

const expectedRecommendedActionsBySlug = new Map([
  ['plan-readiness', 'Fix the static plan-readiness drift in the referenced repos/scripts, then rerun bash scripts/audit-plan-readiness.sh.'],
  ['github-governance', 'Apply the documented default-branch, visibility, and branch-protection policy, then rerun bash scripts/audit-github-governance.sh.'],
  ['release-pr-readiness', 'Get every PR in config/release-readiness-prs.tsv approved, green, with all GitHub review conversations resolved including outdated unresolved threads, and merged through the protected branch flow. When the blocker is outdated-only, run bash scripts/resolve-release-pr-review-threads.sh --dry-run to inspect the exact thread IDs before any authorized resolution. After conversations are resolved and approvals are present, run bash scripts/merge-release-prs.sh --dry-run to inspect protected-branch merge candidates before any authorized merge, then rerun bash scripts/audit-release-pr-readiness.sh.'],
  ['source-publication-readiness', 'Do not commit or publish from a checkout with an in-progress merge, rebase, cherry-pick, revert, bisect, or sequencer operation or unresolved index stages; have that checkout\'s owner resolve the state first. Remove or quarantine every ignored non-published build output reported by the audit, then commit only reviewed tested changes. Assign the root release tooling and passkey challenge service to a canonical maintained GitHub repository, add its protected release PR to config/release-readiness-prs.tsv, and push exact topic-branch HEADs. Then rerun the full bash scripts/audit-release-readiness.sh flow so the remote-checked source preflight is captured before all release checks and matched by postflight.'],
  ['private-overlay-readiness', 'Remove private product-source drift and keep only allowed release overlay files, then rerun bash scripts/audit-private-overlay-readiness.sh.'],
  ['android-public-dependency-provenance', 'Restore fearless-utils-Android to the pinned commit plus exact committed library-only overlay with no extra drift, then restore the Android public artifact boundary and handoff bundle. Rerun bash ./scripts/test-fearless-utils-derived-tree.sh, FEARLESS_UTILS_LIBRARY_ONLY=true FEARLESS_UTILS_PATH=../fearless-utils-Android ./scripts/ensure-fearless-utils.sh, bash ./scripts/test-public-dependency-upstream-delta-export.sh, bash ./scripts/export-public-dependency-upstream-delta.sh --output build/reports/public-dependency-upstream-delta, and ./scripts/audit-public-artifacts.sh in fearless-Android.'],
  ['ios-shared-features-delta', 'Restore the iOS shared-features delta self-test/report gate, review build/reports/shared-features-delta-report.json, and rerun bash scripts/deps/test-shared-features-delta-report.sh plus bash scripts/deps/audit-shared-features-delta-report.sh "$PWD" --write-report build/reports/shared-features-delta-report.json in fearless-iOS.'],
  ['passkey-challenge-service', 'Fix the passkey challenge-service implementation, Docker/deployment evidence, and adversarial tests, then rerun bash scripts/audit-passkey-challenge-service.sh.'],
  ['passkey-deployment-evidence', 'Record the passkey backup image digest, deployment ID, operator, healthResponse ok=true/service=fearless-passkey-backup/rpId=fearlesswallet.io/schemaVersion=1, durable credential store paths /data/passkey-backup and /data/passkey-backup/credentials.json, WebAuthn origin allowlist, fail-closed request-access policy, trusted-proxy policy, platform provisioning evidence, and successful smoke timestamp. Independently obtain the distribution signer SHA-256 fingerprint from a distribution-signed APK or the Play app-signing certificate, set PASSKEY_ANDROID_RELEASE_SIGNER_EVIDENCE_SOURCE=distributed-apk|play-app-signing-certificate to identify the source, and prove the derived origin matches assetlinks; AAB upload-key evidence is rejected and absence or mismatch keeps passkey flags disabled. Then rerun npm run audit:deployment-evidence -- --require-ready in services/passkey-backup-challenge-service and bash scripts/audit-passkey-android-origin-parity.sh --require-ready from the workspace root.'],
  ['passkey-backup-prerequisites', 'Deploy and route https://backup.fearlesswallet.io to services/passkey-backup-challenge-service with valid DNS/TLS and require live health response ok=true/service=fearless-passkey-backup/rpId=fearlesswallet.io/schemaVersion=1. Deploy https://fearlesswallet.io association files so the strict site verifier observes exact source parity, JSON content types, X-Content-Type-Options: nosniff, and no redirects. Keep Android/iOS passkey backup flags disabled until health, site associations, and platform provisioning pass, then rerun PASSKEY_BACKUP_LIVE_HEALTH=1 bash scripts/audit-passkey-backup-prerequisites.sh && node fearless-site-web/scripts/verify-app-associations.mjs --root fearless-site-web --live-base-url https://fearlesswallet.io.'],
  ['passkey-production-smoke', 'Deploy and route https://backup.fearlesswallet.io to services/passkey-backup-challenge-service with valid DNS/TLS. Provision PASSKEY_BACKUP_SMOKE_GRANT_HELPER=/run/secrets/passkey-smoke-grant-helper as a readable executable that issues single-use bearer grants for the exact smoke requests, then run the passkey production smoke to verify health, all four ceremony routes, and credential list/revoke/revoke-all contracts without persisting a test credential or creating an owner record.'],
  ['iroha-release-readiness', 'Do not edit or publish from an unfinished external Iroha Git operation. Have its owner produce a stable reviewed source commit and restore the pinned Iroha JS SDK release artifact so package.json exports ./ivm-artifact and the packaged runtime/declaration surface passes the wallet artifact validator. Pin NEXUS_EXPECTED_BUILD_COMMIT in config/iroha-release-readiness.env to the exact deployed Iroha build. Restore https://minamoto.sora.org/status as a bounded, non-redirecting HTTP 200 application/json Torii/Nexus status response with fresh observed_at_ms and last_block_committed_at_ms, coherent block and queue counters, a matching non-placeholder build.git_commit_sha, the exact ordered SORA routing policy (default 0/0, governance 1/1, smartcontract::deploy 2/2), and an unsealed dataspace_catalog containing ready canonical 0/0, 1/1, and 2/2 targets; record Nexus route publication, canary, and wallet live transfer smoke evidence, keep Nexus release-gated until strict production evidence passes, then rerun bash scripts/audit-iroha-release-readiness.sh.'],
  ['iroha-wallet-coverage', 'Restore Android/iOS/web Iroha/Nexus wallet coverage, fail-closed transfer tests, and each platform\'s explicit blocked production-send readiness contract; do not enable production send until reviewed codecs and key providers exist, then rerun bash scripts/audit-iroha-wallet-coverage.sh.'],
  ['android-xcm-production-evidence', 'Keep release ENABLE_PRODUCTION_XCM_TRANSFERS=false until the entire trust and evidence gate is ready. Obtain reviewed per-asset pallet/call, reserve-or-teleport, multilocation, beneficiary, weight, destination-fee, and any bridge execution semantics for every advertised Android XCM route; implement bridge or estimator support before approving those modes. The per-asset schema, loader, validator, registry, and engine representation is now implemented, and all 15 approved single-asset routes are migrated without semantic changes. The current 34 discovery-only destinations cover 59 route assets; 14 of those destinations cover 39 multi-asset routes, and every one remains disabled until its exact reviewed semantics exist. Expand the APK-owned approved_xcm_routes.tsv and scripts/xcm-required-routes.tsv in exact lockstep only after those route semantics are reviewed, and make the production discovery intersection contain every approved route. Then record one funded mainnet E2E transfer per required route in fearless-Android/scripts/xcm-production-evidence.json, including 0x-prefixed 32-byte extrinsicHash, sender, recipient, positive amount, UTC timestamp, environment, operator, and androidCommit matching the release commit, plus finalized origin/destination block hashes and numbers, true origin finality/extrinsic success/destination event success, a positive destination balance delta, distinct public HTTPS proof URLs, verificationMethod=canonical-rpc-and-explorer, verifiedAt, and an independentVerifier distinct from operator. Regenerate the canonical live effective report and validate it with the ready evidence, then run the all-routes metadata gate before a separately reviewed release-flag change.'],
  ['web-bitcoin-broadcast-evidence', 'Run a funded Bitcoin testnet send through the web wallet smoke flow, record txid/outpoint/operator evidence plus canonical https://blockstream.info/testnet/api indexerUrl and confirmed indexer status.block_time proof in fearless-wallet-web/scripts/bitcoin-testnet-broadcast-evidence.json, ensure the evidence timestamp is at or after the confirmed block time, then rerun bash scripts/audit-bitcoin-broadcast-evidence.sh --require-ready in fearless-wallet-web.'],
  ['ti-deployment-evidence', 'Populate ../ton-indexer/registry/mainnet.json with reviewed non-placeholder mainnet contract addresses. Record the TI Docker image digest, deployment ID, operator, commit, serviceInfo.schemaVersion=1 plus serviceInfo.serviceId=ti.soramitsu.io with TON mainnet identity, healthInfo.serviceId=ti.soramitsu.io with healthInfo.lastMasterSeqno from the successful https://ti.soramitsu.io smoke evidence, then rerun npm run audit:deployment-evidence -- --require-ready in ../ton-indexer.'],
  ['si-deployment-evidence', 'Deploy the current SI image with Solana mainnet configuration. Record the SI Docker image digest, deployment ID, operator, commit, serviceInfo.schemaVersion=1 plus serviceInfo.serviceId=si.soramitsu.io with Solana mainnet identity, and healthInfo with ok=true, serviceId=si.soramitsu.io, genesisHash=5eykt4UsFv8P8NJdTREpY1vzqKqZKvdpKuc147dw2N9d, latestSlot as a positive safe integer, and syncedAt as an integer no more than 120 seconds before and no more than 30 seconds after smokePassedAt, plus successful https://si.soramitsu.io smoke evidence in ../solswap-indexer/scripts/production-deployment-evidence.json, then rerun npm run audit:deployment-evidence -- --require-ready in ../solswap-indexer.'],
  ['pi-deployment-evidence', 'Deploy the current polkaswap-indexer worker and API to https://pi.soramitsu.io/graphql with POLKASWAP_CHAIN_START_BLOCK set, a locally-controlled verifying archival primary RPC and an independently-operated verifying archive RPC on distinct hosts. Require the exact fixed audited SORA mainnet genesis/hash/timestamp anchor identity preflight on both RPCs before database access; exact dual-RPC agreement on finalized height, hash, canonical raw SCALE block, canonical raw SCALE events, and raw decimal timestamp milliseconds; and the compiled PostgreSQL worker health check proving the exact persisted chainState, matching filtered BLOCK snapshot, checkpoint freshness from 300 seconds behind through 30 seconds ahead, and secret-safe diagnostics. API health evidence must prove healthInfo.service=polkaswap-indexer, healthInfo.serviceId=pi.soramitsu.io, exact SORA mainnet genesisHash=0x7e4e32d0feafd4f9c9414b0be86373f9a1efa904809b683453a9af6856d38ad5, latestIndexedBlock as a positive safe integer, latestIndexedBlockHash as a canonical nonzero lowercase 32-byte hash, and latestIndexedAt no more than 300 seconds before or 30 seconds after the smoke timestamp. Record the Docker image digest, deployment ID, operator, commit, those exact healthInfo fields, successful smoke timestamp, soraRpcControls with primaryEndpoint, archiveEndpoint, primaryNodeControl=locally-controlled-verifying-archive, archiveNodeControl=independently-operated-verifying-archive, distinctHosts=true, exactIdentityPreflight=true, and rawPayloadAgreement=height-hash-scale-block-events-timestamp, plus tlsEdgeControls proving TLS termination, forwarded-client-IP header overwrite, 600 HTTP requests and 600 WebSocket upgrades per client per 60000ms, and 16 concurrent WebSockets per client in ../polkaswap-indexer/scripts/production-deployment-evidence.json, then, from ../polkaswap-indexer, rerun bash ../fearless/scripts/run-pinned-yarn.sh audit:deployment-evidence --require-ready.'],
  ['ti-production-smoke', 'Deploy the current ton-indexer image to https://ti.soramitsu.io so /api/indexer/v1/health exposes lastMasterSeqno and health.serviceId=ti.soramitsu.io with ecosystem=ton, chainId=ton:mainnet, and network=mainnet. TI production smoke also requires serviceInfo.schemaVersion=1, serviceInfo.serviceId=ti.soramitsu.io, publicBaseUrl=https://ti.soramitsu.io, readOnly=true, endpoints.openapi=/api/indexer/v1/openapi.json, and OpenAPI title TONSWAP Indexer API, then rerun TON_INDEXER_BASE_URL=https://ti.soramitsu.io npm run smoke:production in ../ton-indexer.'],
  ['si-production-smoke', 'Deploy the current SI image with Solana mainnet configuration so /api/indexer/v1/health returns health.ok=true, health.serviceId=si.soramitsu.io, health.ecosystem=solana, health.chainId=solana:mainnet, health.network=mainnet, health.genesisHash=5eykt4UsFv8P8NJdTREpY1vzqKqZKvdpKuc147dw2N9d, health.latestSlot as a positive safe integer, and health.syncedAt as an integer no more than 120 seconds old and no more than 30 seconds in the future, without advertising api.testnet.solana.com, and /api/indexer/v1/service-info exists. SI production smoke also requires serviceInfo.schemaVersion=1, serviceInfo.serviceId=si.soramitsu.io, ecosystem=solana, chainId=solana:mainnet, network=mainnet, publicBaseUrl=https://si.soramitsu.io, readOnly=true, endpoints.openapi=/api/indexer/v1/openapi.json, and OpenAPI title Solswap Indexer API, then rerun SOLSWAP_INDEXER_BASE_URL=https://si.soramitsu.io npm run smoke:production in ../solswap-indexer.'],
  ['pi-production-smoke', 'Deploy the current polkaswap-indexer worker and API to https://pi.soramitsu.io/graphql with POLKASWAP_CHAIN_START_BLOCK set, a locally-controlled verifying archival primary RPC and an independently-operated verifying archive RPC on distinct hosts. Require the exact fixed audited SORA mainnet genesis/hash/timestamp anchor identity preflight on both RPCs before database access; exact dual-RPC agreement on finalized height, hash, canonical raw SCALE block, canonical raw SCALE events, and raw decimal timestamp milliseconds; and the compiled PostgreSQL worker health check proving the exact persisted chainState, matching filtered BLOCK snapshot, checkpoint freshness from 300 seconds behind through 30 seconds ahead, and secret-safe diagnostics. GraphQL _health must return health.ok=true, health.service=polkaswap-indexer, health.serviceId=pi.soramitsu.io, health.schemaVersion=1, health.ecosystem=sora2, health.chainId=sora:mainnet, health.network=mainnet, health.publicBaseUrl=https://pi.soramitsu.io/graphql, health.readOnly=true, exact SORA mainnet genesisHash=0x7e4e32d0feafd4f9c9414b0be86373f9a1efa904809b683453a9af6856d38ad5, a positive latestIndexedBlock, a canonical nonzero lowercase 32-byte latestIndexedBlockHash, and a latestIndexedAt within 300 seconds behind or 30 seconds ahead of the verifier. PI production smoke also requires an immutable exact fixed-anchor chainIdentity, a chainState record at or below finalized height and coherent with the health height/hash/timestamp, live hash and raw timestamp reconciliation, and a matching filtered BLOCK snapshot, and rejects TON and Solana/Solswap indexer contracts. Then, from ../polkaswap-indexer, rerun POLKASWAP_INDEXER_BASE_URL=https://pi.soramitsu.io/graphql bash ../fearless/scripts/run-pinned-yarn.sh smoke:production.'],
])

const expectedRequiresExternalActionBySlug = new Map([
  ['plan-readiness', false],
  ['github-governance', true],
  ['release-pr-readiness', true],
  ['source-publication-readiness', true],
  ['private-overlay-readiness', false],
  ['android-public-dependency-provenance', false],
  ['ios-shared-features-delta', false],
  ['passkey-challenge-service', false],
  ['passkey-deployment-evidence', true],
  ['passkey-backup-prerequisites', true],
  ['passkey-production-smoke', true],
  ['iroha-release-readiness', true],
  ['iroha-wallet-coverage', false],
  ['android-xcm-production-evidence', true],
  ['web-bitcoin-broadcast-evidence', true],
  ['ti-deployment-evidence', true],
  ['si-deployment-evidence', true],
  ['pi-deployment-evidence', true],
  ['ti-production-smoke', true],
  ['si-production-smoke', true],
  ['pi-production-smoke', true],
])

const expectedUnblockCategoriesBySlug = new Map([
  ['github-governance', 'github-admin'],
  ['release-pr-readiness', 'review-and-merge'],
  ['source-publication-readiness', 'source-publication'],
  ['passkey-deployment-evidence', 'deployment-evidence'],
  ['ti-deployment-evidence', 'deployment-evidence'],
  ['si-deployment-evidence', 'deployment-evidence'],
  ['pi-deployment-evidence', 'deployment-evidence'],
  ['passkey-backup-prerequisites', 'live-service-deployment'],
  ['passkey-production-smoke', 'live-service-deployment'],
  ['ti-production-smoke', 'live-service-deployment'],
  ['pi-production-smoke', 'live-service-deployment'],
  ['iroha-release-readiness', 'live-service-and-evidence'],
  ['android-xcm-production-evidence', 'route-implementation-and-evidence'],
  ['web-bitcoin-broadcast-evidence', 'funded-broadcast-evidence'],
  ['si-production-smoke', 'live-service-deployment'],
  ['ios-shared-features-delta', 'upstream-dependency'],
  ['private-overlay-readiness', 'private-overlay-cleanup'],
  ['plan-readiness', 'local-code'],
  ['android-public-dependency-provenance', 'local-code'],
  ['passkey-challenge-service', 'local-code'],
  ['iroha-wallet-coverage', 'local-code'],
])

const expectedExternalPrerequisitesBySlug = new Map([
  ['github-governance', 'GitHub admin access to apply default-branch, visibility, and branch-protection policy.'],
  ['release-pr-readiness', 'Reviewer approvals, resolved GitHub review conversations, and protected-branch merges.'],
  ['source-publication-readiness', 'Owner-resolved completion of every in-progress Git operation or unmerged index state, removal or quarantine of ignored non-published build outputs, canonical Git ownership for the root release/passkey source, plus reviewed commits, pushes, and protected pull requests for the exact tested HEAD of every source tree.'],
  ['passkey-deployment-evidence', 'Production passkey backup deployment image, health response, credential-store volume, request-access and trusted-proxy evidence, plus independently obtained distribution signer SHA-256 evidence from a distribution-signed APK or Play app-signing certificate, with PASSKEY_ANDROID_RELEASE_SIGNER_EVIDENCE_SOURCE=distributed-apk|play-app-signing-certificate and a matching assetlinks origin; AAB upload-key evidence is rejected and absence keeps passkey flags disabled.'],
  ['passkey-backup-prerequisites', 'DNS, TLS, and routing for backup.fearlesswallet.io plus production deployment of the exact fearlesswallet.io assetlinks/AASA source contracts with JSON content types, nosniff headers, and no redirects.'],
  ['passkey-production-smoke', 'DNS, TLS, and routing for backup.fearlesswallet.io to the passkey backup challenge service route surface, plus PASSKEY_BACKUP_SMOKE_GRANT_HELPER=/run/secrets/passkey-smoke-grant-helper provisioned as a readable executable that issues single-use bearer grants for the exact smoke requests.'],
  ['iroha-release-readiness', 'A stable owner-reviewed Iroha source commit; a pinned Iroha JS SDK release artifact exporting ./ivm-artifact and passing packaged runtime/declaration validation; the exact deployed Iroha build pin; bounded, non-redirecting HTTP 200 application/json Minamoto Torii/Nexus status with fresh observation and block timestamps, coherent block and queue counters, exact canonical routing/dataspace catalog; plus route publication, canary, and wallet live-transfer evidence.'],
  ['android-xcm-production-evidence', 'Reviewed per-asset execution semantics and effective production discovery for every advertised Android XCM route, implementation of any required bridge or fee-estimator path, a separately reviewed release enablement change, funded mainnet E2E evidence for the exact effective route set, and Android release-commit binding.'],
  ['web-bitcoin-broadcast-evidence', 'Funded confirmed Bitcoin testnet broadcast evidence for the current release commit using the canonical Blockstream testnet indexer.'],
  ['ti-deployment-evidence', 'Reviewed TON mainnet registry addresses plus deployed TI image, smoke, and health evidence.'],
  ['si-deployment-evidence', 'Current SI image deployed with exact Solana mainnet genesisHash, positive latestSlot, fresh integer syncedAt, service-info identity, and operator-attested deployment evidence.'],
  ['pi-deployment-evidence', 'Current PI worker/API deployed with required POLKASWAP_CHAIN_START_BLOCK, a locally-controlled verifying archival primary RPC and independently-operated verifying archive RPC on distinct hosts, exact fixed-anchor identity preflight, exact dual raw payload agreement, compiled PostgreSQL worker health proving exact persisted state/snapshot freshness with secret-safe diagnostics, and operator-attested image, deployment, commit, four-field health, SORA RPC-control, smoke, and TLS-edge evidence.'],
  ['ti-production-smoke', 'Updated TON indexer deployment serving TI mainnet health, service-info, and OpenAPI contracts.'],
  ['si-production-smoke', 'Current SI image deployed with exact Solana mainnet genesisHash, positive latestSlot, fresh integer syncedAt, release identity fields, service-info, and OpenAPI contracts.'],
  ['pi-production-smoke', 'Updated PI worker/API serving the four SORA identity/checkpoint fields through GraphQL _health and coherent immutable chainIdentity, chainState, and filtered BLOCK worker state, backed by distinct controlled verifying archival RPCs, exact identity preflight and raw payload agreement, required chain start, and the compiled secret-safe worker health check.'],
  ['ios-shared-features-delta', 'Upstream shared-features publication of carried compatibility and native-crypto deltas.'],
  ['private-overlay-readiness', 'Private repo tracking cleanup so only allowed release overlay files remain tracked.'],
  ['android-public-dependency-provenance', 'Pinned public fearless-utils-Android checkout and public dependency handoff bundle.'],
  ['plan-readiness', 'No external prerequisite is expected; fix the local failing release gate.'],
  ['passkey-challenge-service', 'No external prerequisite is expected; fix the local failing release gate.'],
  ['iroha-wallet-coverage', 'No external prerequisite is expected; fix the local failing release gate.'],
])

const externalIrohaOnlyPlanContract = Object.freeze({
  recommendedAction: 'Do not edit or publish from the unsafe external ../iroha checkout. Have its owner resolve any in-progress Git operation or unmerged index state and restore every reported Iroha source and browser-artifact contract on a stable reviewed commit, then rerun bash scripts/audit-plan-readiness.sh.',
  requiresExternalAction: true,
  unblockCategory: 'upstream-dependency',
  externalPrerequisite: 'Owner-coordinated resolution of the unsafe external ../iroha source state, followed by a stable reviewed checkout containing every audited Iroha source and browser-artifact contract.',
})

function assertExpectedCheckName(slug, value, label) {
  requireSingleLine(value, label)
  const expected = expectedCheckNamesBySlug.get(slug)
  if (!expected) fail(`${label} has unsupported blocker slug for check name: ${slug}`)
  if (value !== expected) fail(`${label} must match expected check name for ${slug}`)
}

function assertExpectedRecommendedAction(slug, value, label) {
  requireSingleLine(value, label)
  const expected = expectedRecommendedActionsBySlug.get(slug)
  if (!expected) fail(`${label} has unsupported blocker slug for recommended action: ${slug}`)
  if (value !== expected) fail(`${label} must match expected recommended action for ${slug}`)
}

function assertExpectedUnblockMetadata(slug, requiresExternalAction, unblockCategory, externalPrerequisite, label) {
  const expectedRequiresExternalAction = expectedRequiresExternalActionBySlug.get(slug)
  const expectedUnblockCategory = expectedUnblockCategoriesBySlug.get(slug)
  const expectedExternalPrerequisite = expectedExternalPrerequisitesBySlug.get(slug)
  if (typeof expectedRequiresExternalAction !== 'boolean' || !expectedUnblockCategory || !expectedExternalPrerequisite) {
    fail(`${label} has unsupported blocker slug for unblock metadata: ${slug}`)
  }
  if (requiresExternalAction !== expectedRequiresExternalAction) {
    fail(`${label}.requiresExternalAction must match expected unblock metadata for ${slug}`)
  }
  if (unblockCategory !== expectedUnblockCategory) {
    fail(`${label}.unblockCategory must match expected unblock metadata for ${slug}`)
  }
  if (externalPrerequisite !== expectedExternalPrerequisite) {
    fail(`${label}.externalPrerequisite must match expected unblock metadata for ${slug}`)
  }
}

function matchesUnblockContract(recommendedAction, requiresExternalAction, unblockCategory, externalPrerequisite, contract) {
  return recommendedAction === contract.recommendedAction &&
    requiresExternalAction === contract.requiresExternalAction &&
    unblockCategory === contract.unblockCategory &&
    externalPrerequisite === contract.externalPrerequisite
}

function assertExpectedBlockerUnblockContract(
  slug,
  recommendedAction,
  requiresExternalAction,
  unblockCategory,
  externalPrerequisite,
  label,
) {
  if (slug === 'plan-readiness') {
    const localContract = {
      recommendedAction: expectedRecommendedActionsBySlug.get(slug),
      requiresExternalAction: expectedRequiresExternalActionBySlug.get(slug),
      unblockCategory: expectedUnblockCategoriesBySlug.get(slug),
      externalPrerequisite: expectedExternalPrerequisitesBySlug.get(slug),
    }
    if (matchesUnblockContract(recommendedAction, requiresExternalAction, unblockCategory, externalPrerequisite, localContract)) {
      return 'local'
    }
    if (matchesUnblockContract(recommendedAction, requiresExternalAction, unblockCategory, externalPrerequisite, externalIrohaOnlyPlanContract)) {
      return 'external-iroha-only'
    }
    fail(`${label} unblock contract must match either the exact local or exact external-Iroha-only variant`)
  }

  assertExpectedRecommendedAction(slug, recommendedAction, `${label}.recommendedAction`)
  assertExpectedUnblockMetadata(slug, requiresExternalAction, unblockCategory, externalPrerequisite, label)
  return 'default'
}

function sourceReportHasUnsafeIrohaState(report) {
  if (!report || typeof report !== 'object' || Array.isArray(report) || report.status !== 'failed' ||
      report.checkRemote !== true || !Array.isArray(report.repositories)) {
    return false
  }
  const irohaRows = report.repositories.filter((row) => row && row.path === '../iroha')
  if (irohaRows.length !== 1 || irohaRows[0].status !== 'failed' || !Array.isArray(irohaRows[0].failures)) return false
  const ownerSuffix = '; only the repository owner may complete or abort it before source publication'
  const unsafeFailures = new Set([
    `repository has an in-progress Git merge operation (MERGE_HEAD)${ownerSuffix}`,
    `repository has an in-progress Git rebase operation (rebase-merge)${ownerSuffix}`,
    `repository has an in-progress Git rebase operation (rebase-apply)${ownerSuffix}`,
    `repository has an in-progress Git rebase operation (rebase-apply, rebase-merge)${ownerSuffix}`,
    `repository has an in-progress Git cherry-pick operation (CHERRY_PICK_HEAD)${ownerSuffix}`,
    `repository has an in-progress Git revert operation (REVERT_HEAD)${ownerSuffix}`,
    `repository has an in-progress Git bisect operation (BISECT_START)${ownerSuffix}`,
    `repository has an in-progress Git sequencer operation (sequencer)${ownerSuffix}`,
  ])
  const iroha = irohaRows[0]
  const hasOperation = iroha.failures.some((failure) => unsafeFailures.has(failure))
  const counts = ['stagedCount', 'unstagedCount', 'untrackedCount', 'unmergedCount']
  const hasCanonicalCounts = counts.every((key) => Number.isSafeInteger(iroha[key]) && iroha[key] >= 0)
  const unmergedFailure = hasCanonicalCounts
    ? `worktree is not clean (staged=${iroha.stagedCount}, unstaged=${iroha.unstagedCount}, untracked=${iroha.untrackedCount}, unmerged=${iroha.unmergedCount})`
    : null
  const hasUnmergedIndex = iroha.unmergedCount > 0 &&
    report.totals && Number.isSafeInteger(report.totals.unmerged) &&
    report.totals.unmerged >= iroha.unmergedCount && iroha.failures.includes(unmergedFailure)
  const canonicalSha = (value) => typeof value === 'string' && /^[0-9a-f]{40}$/u.test(value)
  const hasCanonicalReviewedSourceIdentity =
    report.schemaVersion === 2 &&
    iroha.repository === 'hyperledger-iroha/iroha' &&
    iroha.originRepository === 'hyperledger-iroha/iroha' &&
    iroha.head === 'codex/kagemusha-selector-hardening' &&
    iroha.base === 'optimizations' &&
    iroha.prNumber === 5612 &&
    iroha.prUrl === 'https://github.com/hyperledger-iroha/iroha/pull/5612' &&
    iroha.prState === 'merged' &&
    iroha.branch === 'optimizations' &&
    iroha.upstream === 'origin/optimizations' &&
    canonicalSha(iroha.headSha) &&
    iroha.upstreamSha === iroha.headSha &&
    canonicalSha(iroha.prHeadSha) &&
    iroha.prHeadSha !== iroha.headSha &&
    iroha.remoteBranchPresent === false &&
    iroha.remoteHeadSha === null &&
    iroha.currentBranchRemotePresent === true &&
    canonicalSha(iroha.currentBranchRemoteSha)
  const branchMismatchFailure = hasCanonicalReviewedSourceIdentity
    ? `current branch mismatch: expected ${iroha.head}, received ${iroha.branch}`
    : null
  const upstreamMismatchFailure = hasCanonicalReviewedSourceIdentity
    ? `upstream mismatch: expected origin/${iroha.head}, received ${iroha.upstream}`
    : null
  const pullRequestHeadFailure = hasCanonicalReviewedSourceIdentity
    ? `local HEAD ${iroha.headSha} does not match pull request head ${iroha.prHeadSha}`
    : null
  const authoritativeCurrentBranchFailure = hasCanonicalReviewedSourceIdentity
    ? `local HEAD ${iroha.headSha} does not match authoritative current branch ${iroha.branch} at ${iroha.currentBranchRemoteSha}`
    : null
  const cachedUpstreamAuthoritativeCurrentBranchFailure = hasCanonicalReviewedSourceIdentity
    ? `cached upstream ${iroha.upstream} at ${iroha.upstreamSha} does not match authoritative current branch ${iroha.branch} at ${iroha.currentBranchRemoteSha}`
    : null
  const ignoredOutputsFailure = iroha.failures[0]
  const hasCanonicalIgnoredOutputsFailure =
    typeof ignoredOutputsFailure === 'string' &&
    /^worktree contains ignored non-published paths \([1-9][0-9]*\): .+; remove or quarantine these ignored outputs outside the source tree before publication; do not force-add generated artifacts$/u.test(ignoredOutputsFailure)
  const preflightContinuityFailure = 'source publication preflight did not pass before release checks'
  const hasCanonicalSynchronizedFailureCountAndContinuity =
    iroha.failures.length === 4 ||
    (iroha.failures.length === 5 && iroha.failures[4] === preflightContinuityFailure)
  const hasCanonicalSynchronizedReviewedSourceMismatch =
    hasCanonicalReviewedSourceIdentity &&
    iroha.currentBranchRemoteSha === iroha.headSha &&
    hasCanonicalSynchronizedFailureCountAndContinuity &&
    hasCanonicalIgnoredOutputsFailure &&
    iroha.failures[1] === branchMismatchFailure &&
    iroha.failures[2] === pullRequestHeadFailure &&
    iroha.failures[3] === upstreamMismatchFailure
  const hasCanonicalDriftFailureCountAndContinuity =
    iroha.failures.length === 6 ||
    (iroha.failures.length === 7 && iroha.failures[6] === preflightContinuityFailure)
  const hasCanonicalDriftReviewedSourceMismatch =
    hasCanonicalReviewedSourceIdentity &&
    iroha.currentBranchRemoteSha !== iroha.headSha &&
    hasCanonicalDriftFailureCountAndContinuity &&
    hasCanonicalIgnoredOutputsFailure &&
    iroha.failures[1] === branchMismatchFailure &&
    iroha.failures[2] === authoritativeCurrentBranchFailure &&
    iroha.failures[3] === pullRequestHeadFailure &&
    iroha.failures[4] === upstreamMismatchFailure &&
    iroha.failures[5] === cachedUpstreamAuthoritativeCurrentBranchFailure
  const hasReviewedSourceMismatch =
    counts.every((key) => iroha[key] === 0) &&
    (hasCanonicalSynchronizedReviewedSourceMismatch ||
      hasCanonicalDriftReviewedSourceMismatch)
  return hasOperation || hasUnmergedIndex || hasReviewedSourceMismatch
}

function isExternalIrohaOnlyPlanReadinessLog(content, sourcePublicationReport) {
  const marker = '[plan-readiness][error] Plan readiness audit failed:'
  const lines = String(content).replace(/\r\n/g, '\n').split('\n')
  let markerCount = 0
  let failureCount = 0
  let invalid = false
  let inSummary = false

  for (const line of lines) {
    if (line === marker) {
      markerCount += 1
      inSummary = true
      continue
    }
    if (!inSummary) continue
    if (line.startsWith('  - ')) {
      failureCount += 1
      if (!line.startsWith('  - ../iroha ')) invalid = true
      continue
    }
    if (line.trim() !== '') invalid = true
  }

  return markerCount === 1 && failureCount > 0 && !invalid &&
    sourceReportHasUnsafeIrohaState(sourcePublicationReport)
}

function assertUnblockCategory(value, label) {
  requireSingleLine(value, label)
  if (!supportedUnblockCategories.has(value)) fail(`${label} unblockCategory unsupported: ${value}`)
}

const expectedVerificationCommandsBySlug = new Map([
  ['plan-readiness', 'bash scripts/audit-plan-readiness.sh'],
  ['github-governance', 'bash scripts/audit-github-governance.sh'],
  ['release-pr-readiness', 'bash scripts/audit-release-pr-readiness.sh'],
  ['source-publication-readiness', 'bash scripts/audit-release-readiness.sh'],
  ['private-overlay-readiness', 'bash scripts/audit-private-overlay-readiness.sh'],
  ['android-public-dependency-provenance', 'cd fearless-Android && bash ./scripts/test-fearless-utils-derived-tree.sh && FEARLESS_UTILS_PATH=../fearless-utils-Android FEARLESS_UTILS_COMMIT=7500809f33243ee47ecb2ec8563fc284ac4de0d6 FEARLESS_UTILS_REPOSITORY=soramitsu/fearless-utils-Android FEARLESS_UTILS_LIBRARY_ONLY=true ./scripts/ensure-fearless-utils.sh && bash ./scripts/test-public-dependency-upstream-delta-export.sh && bash ./scripts/export-public-dependency-upstream-delta.sh --output build/reports/public-dependency-upstream-delta && ./scripts/audit-public-artifacts.sh --strict-provenance'],
  ['ios-shared-features-delta', 'cd fearless-iOS && bash scripts/deps/test-shared-features-delta-report.sh && bash scripts/deps/audit-shared-features-delta-report.sh "$PWD" --write-report build/reports/shared-features-delta-report.json'],
  ['passkey-challenge-service', 'bash scripts/audit-passkey-challenge-service.sh'],
  ['passkey-deployment-evidence', 'cd services/passkey-backup-challenge-service && npm run audit:deployment-evidence -- --require-ready && cd ../.. && bash scripts/audit-passkey-android-origin-parity.sh --require-ready'],
  ['passkey-backup-prerequisites', 'PASSKEY_BACKUP_LIVE_HEALTH=1 bash scripts/audit-passkey-backup-prerequisites.sh && node fearless-site-web/scripts/verify-app-associations.mjs --root fearless-site-web --live-base-url https://fearlesswallet.io'],
  ['passkey-production-smoke', 'cd services/passkey-backup-challenge-service && PASSKEY_BACKUP_BASE_URL=https://backup.fearlesswallet.io PASSKEY_BACKUP_SMOKE_GRANT_HELPER=/run/secrets/passkey-smoke-grant-helper PASSKEY_BACKUP_SMOKE_TIMEOUT_MS=10000 npm run smoke:production'],
  ['iroha-release-readiness', 'IROHA_NEXUS_REQUIRE_PRODUCTION_EVIDENCE=1 IROHA_NEXUS_LIVE_HEALTH=1 bash scripts/audit-iroha-release-readiness.sh'],
  ['iroha-wallet-coverage', 'bash scripts/audit-iroha-wallet-coverage.sh'],
  ['android-xcm-production-evidence', 'cd fearless-Android && bash scripts/audit-xcm-effective-registry.sh --discovery-url https://raw.githubusercontent.com/soramitsu/shared-features-utils/master/chains/v13/chains.json --require-all-approved --write-report build/reports/xcm-effective-registry-report.json && bash scripts/audit-xcm-production-evidence.sh --effective-registry-report build/reports/xcm-effective-registry-report.json --require-ready && bash scripts/audit-xcm-registry-metadata.sh --require-executable --require-all-routes-executable --require-route-file scripts/xcm-required-routes.tsv --require-gap-file scripts/xcm-discovery-only-routes.tsv'],
  ['web-bitcoin-broadcast-evidence', 'cd fearless-wallet-web && bash scripts/audit-bitcoin-broadcast-evidence.sh --require-ready'],
  ['ti-deployment-evidence', 'cd ../ton-indexer && npm run audit:deployment-evidence -- --require-ready'],
  ['si-deployment-evidence', 'cd ../solswap-indexer && npm run audit:deployment-evidence -- --require-ready'],
  ['pi-deployment-evidence', 'cd ../polkaswap-indexer && bash ../fearless/scripts/run-pinned-yarn.sh audit:deployment-evidence --require-ready'],
  ['ti-production-smoke', 'cd ../ton-indexer && TON_INDEXER_BASE_URL=https://ti.soramitsu.io npm run smoke:production'],
  ['si-production-smoke', 'cd ../solswap-indexer && SOLSWAP_INDEXER_BASE_URL=https://si.soramitsu.io npm run smoke:production'],
  ['pi-production-smoke', 'cd ../polkaswap-indexer && POLKASWAP_INDEXER_BASE_URL=https://pi.soramitsu.io/graphql bash ../fearless/scripts/run-pinned-yarn.sh smoke:production'],
])

function assertExpectedVerificationCommand(slug, value, label) {
  requireSingleLine(value, label)
  const expected = expectedVerificationCommandsBySlug.get(slug)
  if (!expected) fail(`${label} has unsupported blocker slug for verification command: ${slug}`)
  if (value !== expected) fail(`${label} must match expected command for ${slug}`)
}

function validateActionBlockers(actionsManifest, sourcePublicationReport) {
  if (!Array.isArray(actionsManifest.blockers)) {
    fail('actions.blockers must be an array')
  }
  if (actionsManifest.totals.failed !== actionsManifest.blockers.length) {
    fail(`actions blocker count must match failed total: ${actionsManifest.blockers.length} != ${actionsManifest.totals.failed}`)
  }

  const actionsBySlug = new Map()
  for (const blocker of actionsManifest.blockers) {
    assertAllowedKeys(blocker, blockerKeys, 'blocker action')
    requireSingleLine(blocker.name, 'blocker.name')
    assertNoSecretLike('blocker.name', blocker.name)
    requireString(blocker.slug, 'blocker.slug')
    if (!/^[a-z0-9][a-z0-9-]*$/.test(blocker.slug)) {
      fail(`blocker.slug has unsupported format: ${blocker.slug}`)
    }
    if (actionsBySlug.has(blocker.slug)) {
      fail(`duplicate blocker slug: ${blocker.slug}`)
    }
    assertExpectedCheckName(blocker.slug, blocker.name, `${blocker.slug}.name`)

    assertFailedBlockerExitCode(blocker.exitCode, `${blocker.slug}.exitCode`)
    requireSingleLine(blocker.recommendedAction, `${blocker.slug}.recommendedAction`)
    requireBoolean(blocker.requiresExternalAction, `${blocker.slug}.requiresExternalAction`)
    assertUnblockCategory(blocker.unblockCategory, `${blocker.slug}.unblockCategory`)
    requireSingleLine(blocker.externalPrerequisite, `${blocker.slug}.externalPrerequisite`)
    const unblockContractVariant = assertExpectedBlockerUnblockContract(
      blocker.slug,
      blocker.recommendedAction,
      blocker.requiresExternalAction,
      blocker.unblockCategory,
      blocker.externalPrerequisite,
      blocker.slug,
    )
    assertExpectedVerificationCommand(blocker.slug, blocker.verificationCommand, `${blocker.slug}.verificationCommand`)
    requireString(blocker.evidencePreview, `${blocker.slug}.evidencePreview`)
    assertNoSecretLike(`${blocker.slug}.recommendedAction`, blocker.recommendedAction)
    assertNoSecretLike(`${blocker.slug}.unblockCategory`, blocker.unblockCategory)
    assertNoSecretLike(`${blocker.slug}.externalPrerequisite`, blocker.externalPrerequisite)
    assertNoSecretLike(`${blocker.slug}.verificationCommand`, blocker.verificationCommand)
    assertNoSecretLike(`${blocker.slug}.evidencePreview`, blocker.evidencePreview)
    const blockerLogFile = resolveReportFile(blocker.logFile, `${blocker.slug}.logFile`)
    assertRegularFile(blockerLogFile, `${blocker.slug}.logFile`)
    const blockerLogContent = fs.readFileSync(blockerLogFile, 'utf8')
    assertEvidencePreviewMatchesLog(
      blocker.evidencePreview,
      blockerLogContent,
      `${blocker.slug}.evidencePreview`,
    )
    if (blocker.slug === 'plan-readiness') {
      const expectedVariant = isExternalIrohaOnlyPlanReadinessLog(blockerLogContent, sourcePublicationReport)
        ? 'external-iroha-only'
        : 'local'
      if (unblockContractVariant !== expectedVariant) {
        fail(`${blocker.slug} unblock contract variant must match plan-readiness log classification`)
      }
    }

    actionsBySlug.set(blocker.slug, blocker)
  }
  return actionsBySlug
}

function assertSummaryChecks(summary, actionsBySlug) {
  if (!Array.isArray(summary.checks)) fail('summary.checks must be an array')

  const checkKeys = [
    'name',
    'slug',
    'status',
    'exitCode',
    'logFile',
    'recommendedAction',
    'requiresExternalAction',
    'unblockCategory',
    'externalPrerequisite',
    'verificationCommand',
  ]
  const counts = { passed: 0, failed: 0, skipped: 0 }
  const seenChecks = new Set()
  const failedCheckSlugs = new Set()
  const failedCheckOrder = []
  const nonFailedCheckOrder = []
  const summaryUnblockKeys = ['recommendedAction', 'requiresExternalAction', 'unblockCategory', 'externalPrerequisite', 'verificationCommand']

  for (const check of summary.checks) {
    assertAllowedKeys(check, checkKeys, 'summary check')
    requireSingleLine(check.name, 'summary.check.name')
    assertNoSecretLike('summary.check.name', check.name)
    requireString(check.slug, 'summary.check.slug')
    if (!/^[a-z0-9][a-z0-9-]*$/.test(check.slug)) fail(`summary.check slug has unsupported format: ${check.slug}`)
    if (seenChecks.has(check.slug)) fail(`duplicate summary check slug: ${check.slug}`)
    seenChecks.add(check.slug)
    if (!['passed', 'failed', 'skipped'].includes(check.status)) fail(`summary.check status unsupported: ${check.slug} ${check.status}`)
    counts[check.status] += 1

    if (check.status === 'skipped') {
      if (check.exitCode !== null || check.logFile !== null) fail(`${check.slug}.summary skipped check must not carry exitCode or logFile`)
      for (const key of summaryUnblockKeys) {
        if (check[key] !== null) fail(`${check.slug}.summary non-failed check must not carry unblock metadata`)
      }
      assertExpectedCheckName(check.slug, check.name, `${check.slug}.summary.name`)
      nonFailedCheckOrder.push(check.slug)
      continue
    }

    assertSummaryExitCodeForStatus(check.status, check.exitCode, `${check.slug}.summary.exitCode`)
    const summaryLogFile = resolveReportFile(check.logFile, `${check.slug}.summary.logFile`)
    if (check.status === 'failed') {
      requireSingleLine(check.recommendedAction, `${check.slug}.summary.recommendedAction`)
      requireSingleLine(check.verificationCommand, `${check.slug}.summary.verificationCommand`)
      const action = actionsBySlug.get(check.slug)
      if (!action) fail(`${check.slug} failed summary check missing from actions manifest blockers`)
      const actionLogFile = resolveReportFile(action.logFile, `${check.slug}.action.logFile`)
      if (summaryLogFile !== actionLogFile) fail(`${check.slug}.summary logFile must match actions manifest logFile`)
      if (check.name !== action.name) fail(`${check.slug}.summary name must match actions manifest blocker`)
      assertExpectedCheckName(check.slug, check.name, `${check.slug}.summary.name`)
      if (check.exitCode !== action.exitCode) fail(`${check.slug}.summary exitCode must match actions manifest blocker`)
      for (const key of summaryUnblockKeys) {
        if (check[key] !== action[key]) fail(`${check.slug}.summary ${key} must match actions manifest blocker`)
      }
      failedCheckSlugs.add(check.slug)
      failedCheckOrder.push(check.slug)
    } else {
      for (const key of summaryUnblockKeys) {
        if (check[key] !== null) fail(`${check.slug}.summary non-failed check must not carry unblock metadata`)
      }
      assertExpectedCheckName(check.slug, check.name, `${check.slug}.summary.name`)
      nonFailedCheckOrder.push(check.slug)
    }
  }

  if (summary.checks.length !== summary.totals.total) {
    fail(`summary checks length must match summary.totals.total: ${summary.checks.length} != ${summary.totals.total}`)
  }
  for (const status of ['passed', 'failed', 'skipped']) {
    if (counts[status] !== summary.totals[status]) {
      fail(`summary checks ${status} count must match summary.totals.${status}: ${counts[status]} != ${summary.totals[status]}`)
    }
  }
  for (const slug of expectedCheckOrderSlugs) {
    if (!seenChecks.has(slug)) fail(`summary missing release check: ${slug}`)
  }
  if (summary.checks.length !== expectedCheckOrderSlugs.length) {
    fail(`summary checks must include every release check: ${summary.checks.length} != ${expectedCheckOrderSlugs.length}`)
  }
  const nonFailedCheckSet = new Set(nonFailedCheckOrder)
  const expectedNonFailedOrder = expectedCheckOrderSlugs.filter((slug) => nonFailedCheckSet.has(slug))
  if (nonFailedCheckOrder.join('\n') !== expectedNonFailedOrder.join('\n')) fail('summary non-failed checks must match release check order')
  const actionSlugs = [...actionsBySlug.keys()]
  if (failedCheckSlugs.size !== actionSlugs.length) fail('summary failed checks must match actions manifest blockers')
  if (failedCheckOrder.join('\n') !== actionSlugs.join('\n')) fail('actions manifest blockers must match failed summary check order')
  for (const slug of actionsBySlug.keys()) {
    if (!failedCheckSlugs.has(slug)) fail(`${slug} actions manifest blocker missing from failed summary checks`)
  }
}

const summaryPath = path.join(reportRoot, 'summary.json')
const actionsPath = path.join(reportRoot, 'actions.json')
const blockersPath = path.join(reportRoot, 'blockers.md')

assertRegularDirectory(reportRoot, 'release-readiness report dir')
assertRegularDirectory(workspaceRoot, 'workspace root')
assertNoWorkspaceRootSymlinkPrefix(workspaceRoot)
assertFearlessWorkspaceRoot(workspaceRoot)
assertReportRootInsideWorkspace(reportRoot, workspaceRoot)
assertNoSymlinkPathPrefix(reportRoot, 'release-readiness report dir', [workspaceRoot])

const summary = readJson(summaryPath, 'summary.json')
const actions = readJson(actionsPath, 'actions.json')
assertRegularFile(blockersPath, 'blockers.md')

assertAllowedKeys(summary, ['schemaVersion', 'generatedAt', 'runLive', 'status', 'totals', 'checks'], 'summary')
assertAllowedKeys(actions, ['schemaVersion', 'generatedAt', 'runLive', 'status', 'totals', 'blockers'], 'actions manifest')
if (summary.schemaVersion !== 1 || actions.schemaVersion !== 1) {
  fail('summary.json and actions.json must use schemaVersion 1')
}
const nowMs = process.env.RELEASE_UNBLOCK_EXPORT_NOW
  ? parseUtcSecondsTimestamp(process.env.RELEASE_UNBLOCK_EXPORT_NOW, 'RELEASE_UNBLOCK_EXPORT_NOW')
  : Date.now()
const summaryGeneratedAtMs = parseUtcSecondsTimestamp(summary.generatedAt, 'summary.generatedAt')
const actionsGeneratedAtMs = parseUtcSecondsTimestamp(actions.generatedAt, 'actions.generatedAt')
if (summary.generatedAt !== actions.generatedAt) {
  fail(`summary/actions generatedAt mismatch: ${summary.generatedAt} != ${actions.generatedAt}`)
}
assertNotFutureTimestamp(summaryGeneratedAtMs, summary.generatedAt, 'summary.generatedAt', nowMs)
assertNotFutureTimestamp(actionsGeneratedAtMs, actions.generatedAt, 'actions.generatedAt', nowMs)
if (summary.status !== actions.status) {
  fail(`summary/actions status mismatch: ${summary.status} != ${actions.status}`)
}
requireBoolean(summary.runLive, 'summary.runLive')
requireBoolean(actions.runLive, 'actions.runLive')
if (summary.runLive !== actions.runLive) {
  fail(`summary/actions runLive mismatch: ${summary.runLive} != ${actions.runLive}`)
}

assertTotals(summary.totals, 'summary.totals')
assertTotals(actions.totals, 'actions.totals')
for (const key of ['passed', 'failed', 'skipped', 'total']) {
  if (summary.totals[key] !== actions.totals[key]) {
    fail(`summary/actions totals mismatch for ${key}: ${summary.totals[key]} != ${actions.totals[key]}`)
  }
}

assertOverallStatus(actions.status, actions.totals, actions.runLive, 'release status')
const sourcePublicationReportForClassification = actions.runLive
  ? readJson(resolveReportFile(sourcePublicationReportSourcePath, 'source publication report classification'), 'source publication report classification')
  : null
const actionsBySlug = validateActionBlockers(actions, sourcePublicationReportForClassification)
assertSummaryChecks(summary, actionsBySlug)
const actualBlockerReportMarkdown = fs.readFileSync(blockersPath, 'utf8')
assertNoSecretLike('blockers.md', actualBlockerReportMarkdown)
const expectedBlockerReportMarkdown = renderBlockerReportMarkdown(summary, actions)
if (actualBlockerReportMarkdown !== expectedBlockerReportMarkdown) {
  fail('blockers.md does not match summary/actions blockers')
}

assertSafeOutputRoot(outputRoot, reportRoot, workspaceRoot)
createSecureStagingDirectory()

const artifacts = []
copyArtifact(summaryPath, 'summary.json', artifacts)
copyArtifact(actionsPath, 'actions.json', artifacts)
copyArtifact(blockersPath, 'blockers.md', artifacts)

const seenSlugs = new Set()
const blockers = []

for (const blocker of actions.blockers) {
  assertAllowedKeys(blocker, blockerKeys, 'blocker action')
  requireSingleLine(blocker.name, 'blocker.name')
  assertNoSecretLike('blocker.name', blocker.name)
  requireString(blocker.slug, 'blocker.slug')
  if (!/^[a-z0-9][a-z0-9-]*$/.test(blocker.slug)) {
    fail(`blocker.slug has unsupported format: ${blocker.slug}`)
  }
  if (seenSlugs.has(blocker.slug)) {
    fail(`duplicate blocker slug: ${blocker.slug}`)
  }
  seenSlugs.add(blocker.slug)
  assertExpectedCheckName(blocker.slug, blocker.name, `${blocker.slug}.name`)

  assertFailedBlockerExitCode(blocker.exitCode, `${blocker.slug}.exitCode`)
  requireSingleLine(blocker.recommendedAction, `${blocker.slug}.recommendedAction`)
  requireBoolean(blocker.requiresExternalAction, `${blocker.slug}.requiresExternalAction`)
  assertUnblockCategory(blocker.unblockCategory, `${blocker.slug}.unblockCategory`)
  requireSingleLine(blocker.externalPrerequisite, `${blocker.slug}.externalPrerequisite`)
  assertExpectedVerificationCommand(blocker.slug, blocker.verificationCommand, `${blocker.slug}.verificationCommand`)
  requireString(blocker.evidencePreview, `${blocker.slug}.evidencePreview`)

  assertNoSecretLike(`${blocker.slug}.recommendedAction`, blocker.recommendedAction)
  assertNoSecretLike(`${blocker.slug}.unblockCategory`, blocker.unblockCategory)
  assertNoSecretLike(`${blocker.slug}.externalPrerequisite`, blocker.externalPrerequisite)
  assertNoSecretLike(`${blocker.slug}.verificationCommand`, blocker.verificationCommand)
  assertNoSecretLike(`${blocker.slug}.evidencePreview`, blocker.evidencePreview)

  const sourceLog = resolveReportFile(blocker.logFile, `${blocker.slug}.logFile`)
  assertRegularFile(sourceLog, `${blocker.slug}.logFile`)
  const sourceLogContent = fs.readFileSync(sourceLog, 'utf8')
  assertEvidencePreviewMatchesLog(blocker.evidencePreview, sourceLogContent, `${blocker.slug}.evidencePreview`)
  const logArtifact = `logs/${blocker.slug}.log`
  copyArtifact(sourceLog, logArtifact, artifacts)
  const logRecord = artifacts.find((artifact) => artifact.path === logArtifact)

  const manifestBlocker = {
    name: blocker.name,
    slug: blocker.slug,
    requiresExternalAction: blocker.requiresExternalAction,
    unblockCategory: blocker.unblockCategory,
    externalPrerequisite: blocker.externalPrerequisite,
    recommendedAction: blocker.recommendedAction,
    verificationCommand: blocker.verificationCommand,
    evidencePreview: blocker.evidencePreview,
    sourceLog,
    logArtifact,
    logSha256: logRecord.sha256,
  }

  const evidenceTemplateCommands = evidenceTemplateCommandsForSlug(blocker.slug)
  if (evidenceTemplateCommands) {
    for (const [index, command] of evidenceTemplateCommands.entries()) {
      requireSingleLine(command, `${blocker.slug}.evidenceTemplateCommands[${index}]`)
      assertNoSecretLike(`${blocker.slug}.evidenceTemplateCommands[${index}]`, command)
    }
    manifestBlocker.evidenceTemplateCommands = evidenceTemplateCommands
    const evidenceTemplateHandoff = evidenceTemplateHandoffForSlug(blocker.slug)
    if (!evidenceTemplateHandoff) fail(`${blocker.slug}.evidenceTemplateHandoff missing`)
    for (const [key, value] of Object.entries(evidenceTemplateHandoff)) {
      if (key === 'requiredEvidenceContracts') {
        if (!Array.isArray(value) || value.length === 0) fail(`${blocker.slug}.evidenceTemplateHandoff.requiredEvidenceContracts must be a non-empty array`)
        for (const [index, contract] of value.entries()) {
          requireSingleLine(contract, `${blocker.slug}.evidenceTemplateHandoff.requiredEvidenceContracts[${index}]`)
          assertNoSecretLike(`${blocker.slug}.evidenceTemplateHandoff.requiredEvidenceContracts[${index}]`, contract)
        }
        continue
      }
      requireSingleLine(value, `${blocker.slug}.evidenceTemplateHandoff.${key}`)
      assertNoSecretLike(`${blocker.slug}.evidenceTemplateHandoff.${key}`, value)
    }
    manifestBlocker.evidenceTemplateHandoff = evidenceTemplateHandoff
  }

  const bitcoinBroadcastTemplateHandoff = buildBitcoinBroadcastTemplateHandoff(blocker.slug, artifacts)
  if (bitcoinBroadcastTemplateHandoff) {
    for (const [key, value] of Object.entries(bitcoinBroadcastTemplateHandoff)) {
      if (key === 'requiredEvidenceFields' || key === 'requiredContracts') {
        if (!Array.isArray(value) || value.length === 0) fail(`${blocker.slug}.bitcoinBroadcastTemplateHandoff.${key} must be a non-empty array`)
        for (const [index, item] of value.entries()) {
          requireSingleLine(item, `${blocker.slug}.bitcoinBroadcastTemplateHandoff.${key}[${index}]`)
          assertNoSecretLike(`${blocker.slug}.bitcoinBroadcastTemplateHandoff.${key}[${index}]`, item)
        }
        continue
      }
      if (key === 'placeholderRecord') {
        assertAllowedKeys(value, bitcoinRequiredEvidenceFields, `${blocker.slug}.bitcoinBroadcastTemplateHandoff.placeholderRecord`)
        for (const [field, placeholder] of Object.entries(value)) {
          requireSingleLine(placeholder, `${blocker.slug}.bitcoinBroadcastTemplateHandoff.placeholderRecord.${field}`)
          assertNoSecretLike(`${blocker.slug}.bitcoinBroadcastTemplateHandoff.placeholderRecord.${field}`, placeholder)
        }
        continue
      }
      requireSingleLine(value, `${blocker.slug}.bitcoinBroadcastTemplateHandoff.${key}`)
      assertNoSecretLike(`${blocker.slug}.bitcoinBroadcastTemplateHandoff.${key}`, value)
    }
    manifestBlocker.bitcoinBroadcastTemplateHandoff = bitcoinBroadcastTemplateHandoff
  }

  const passkeyDeploymentTemplateHandoff = buildPasskeyDeploymentTemplateHandoff(blocker.slug, artifacts)
  if (passkeyDeploymentTemplateHandoff) {
    manifestBlocker.passkeyDeploymentTemplateHandoff = passkeyDeploymentTemplateHandoff
  }

  const passkeyProductionContractHandoff = buildPasskeyProductionContractHandoff(blocker.slug, artifacts)
  if (passkeyProductionContractHandoff) {
    manifestBlocker.passkeyProductionContractHandoff = passkeyProductionContractHandoff
  }

  const indexerDeploymentTemplateHandoff = buildIndexerDeploymentTemplateHandoff(blocker.slug, artifacts)
  if (indexerDeploymentTemplateHandoff) {
    manifestBlocker.indexerDeploymentTemplateHandoff = indexerDeploymentTemplateHandoff
  }

  const nexusProductionEvidenceTemplateHandoff = buildNexusProductionEvidenceTemplateHandoff(blocker.slug, artifacts)
  if (nexusProductionEvidenceTemplateHandoff) {
    manifestBlocker.nexusProductionEvidenceTemplateHandoff = nexusProductionEvidenceTemplateHandoff
  }

  const xcmProductionEvidenceTemplateHandoff = buildXcmProductionEvidenceTemplateHandoff(blocker.slug, artifacts)
  if (xcmProductionEvidenceTemplateHandoff) {
    manifestBlocker.xcmProductionEvidenceTemplateHandoff = xcmProductionEvidenceTemplateHandoff
  }

  const liveServiceHandoff = liveServiceHandoffForSlug(blocker.slug)
  if (liveServiceHandoff) {
    for (const [key, value] of Object.entries(liveServiceHandoff)) {
      if (key === 'urlPolicy') {
        validateLiveServiceUrlPolicy(value, `${blocker.slug}.liveServiceHandoff.urlPolicy`)
        continue
      }
      if (key === 'expectedContracts' || key === 'routePaths') {
        if (!Array.isArray(value) || value.length === 0) fail(`${blocker.slug}.liveServiceHandoff.${key} must be a non-empty array`)
        for (const [index, item] of value.entries()) {
          requireSingleLine(item, `${blocker.slug}.liveServiceHandoff.${key}[${index}]`)
          assertNoSecretLike(`${blocker.slug}.liveServiceHandoff.${key}[${index}]`, item)
        }
        continue
      }
      requireSingleLine(value, `${blocker.slug}.liveServiceHandoff.${key}`)
      assertNoSecretLike(`${blocker.slug}.liveServiceHandoff.${key}`, value)
    }
    manifestBlocker.liveServiceHandoff = liveServiceHandoff
  }

  if (blocker.slug === 'release-pr-readiness') {
    const releasePrStatusReportSource = resolveReportFile(releasePrStatusReportSourcePath, `${blocker.slug}.releasePrStatusReportHandoff.sourceReportPath`)
    const releasePrStatusReport = readJson(releasePrStatusReportSource, `${blocker.slug}.releasePrStatusReportHandoff.sourceReport`)
    assertReleasePrStatusReport(releasePrStatusReport, releasePrStatusReportSourcePath)
    assertReleasePrStatusReportFailuresMatchLog(releasePrStatusReport, sourceLogContent, releasePrStatusReportSourcePath)
    assertReleasePrStatusReportRequirementsMatchLog(releasePrStatusReport, sourceLogContent, releasePrStatusReportSourcePath)
    const releasePrStatusReportHandoff = buildReleasePrStatusReportHandoff(blocker.slug, artifacts)
    if (releasePrStatusReportHandoff) {
      for (const [key, value] of Object.entries(releasePrStatusReportHandoff)) {
        if (key === 'blockedPrs') {
          if (!Array.isArray(value)) fail(`${blocker.slug}.releasePrStatusReportHandoff.blockedPrs must be an array`)
          for (const [index, pr] of value.entries()) {
            for (const [prKey, prValue] of Object.entries(pr)) {
              if (prKey === 'configLine') {
                requireNumber(prValue, `${blocker.slug}.releasePrStatusReportHandoff.blockedPrs[${index}].${prKey}`)
                continue
              }
              if (prKey === 'requiredChecks') {
                if (!Array.isArray(prValue) || prValue.length === 0) fail(`${blocker.slug}.releasePrStatusReportHandoff.blockedPrs[${index}].requiredChecks must be a non-empty array`)
                for (const [checkIndex, check] of prValue.entries()) {
                  requireSingleLine(check, `${blocker.slug}.releasePrStatusReportHandoff.blockedPrs[${index}].requiredChecks[${checkIndex}]`)
                  assertNoSecretLike(`${blocker.slug}.releasePrStatusReportHandoff.blockedPrs[${index}].requiredChecks[${checkIndex}]`, check)
                }
                continue
              }
              requireSingleLine(prValue, `${blocker.slug}.releasePrStatusReportHandoff.blockedPrs[${index}].${prKey}`)
              assertNoSecretLike(`${blocker.slug}.releasePrStatusReportHandoff.blockedPrs[${index}].${prKey}`, prValue)
            }
          }
        } else if (['checkedCount', 'failedCount', 'requiredPrCount'].includes(key)) {
          requireNumber(value, `${blocker.slug}.releasePrStatusReportHandoff.${key}`)
        } else {
          requireSingleLine(value, `${blocker.slug}.releasePrStatusReportHandoff.${key}`)
          assertNoSecretLike(`${blocker.slug}.releasePrStatusReportHandoff.${key}`, value)
        }
      }
      manifestBlocker.releasePrStatusReportHandoff = releasePrStatusReportHandoff
    }
    const resolution = buildOutdatedReviewThreadResolution(sourceLogContent)
    if (resolution) manifestBlocker.outdatedReviewThreadResolution = resolution
    const approvalHandoff = buildReleasePrApprovalHandoff(sourceLogContent, releasePrStatusReport)
    if (approvalHandoff) {
      assertReleasePrApprovalHandoffMatchesStatusReport(approvalHandoff, releasePrStatusReport, `${blocker.slug}.releasePrApprovalHandoff`)
      requireNumber(approvalHandoff.approvalCount, `${blocker.slug}.releasePrApprovalHandoff.approvalCount`)
      requireSingleLine(approvalHandoff.dryRunCommand, `${blocker.slug}.releasePrApprovalHandoff.dryRunCommand`)
      assertNoSecretLike(`${blocker.slug}.releasePrApprovalHandoff.dryRunCommand`, approvalHandoff.dryRunCommand)
      for (const [index, pr] of approvalHandoff.prs.entries()) {
        for (const [key, value] of Object.entries(pr)) {
          const label = `${blocker.slug}.releasePrApprovalHandoff.prs[${index}].${key}`
          if (['approvalCount', 'currentHeadApprovalCount', 'staleApprovalCount'].includes(key)) {
            requireNumber(value, label)
          } else if (['eligibleReviewerApprovalRequired', 'currentApprovalNotEligible', 'freshApprovalRequired'].includes(key)) {
            requireBoolean(value, label)
          } else {
            requireSingleLine(value, label)
            assertNoSecretLike(label, value)
          }
        }
      }
      manifestBlocker.releasePrApprovalHandoff = approvalHandoff
    } else if (releasePrApprovalRecordsFromStatusReport(releasePrStatusReport).length > 0) {
      fail(`${blocker.slug}.releasePrApprovalHandoff missing`)
    }
    const releasePrMergeHandoff = releasePrMergeHandoffForSlug(blocker.slug, releasePrStatusReport)
    for (const [key, value] of Object.entries(releasePrMergeHandoff)) {
      if (['requiredPrCount', 'blockedPrCount'].includes(key)) {
        requireNumber(value, `${blocker.slug}.releasePrMergeHandoff.${key}`)
        continue
      }
      requireSingleLine(value, `${blocker.slug}.releasePrMergeHandoff.${key}`)
      assertNoSecretLike(`${blocker.slug}.releasePrMergeHandoff.${key}`, value)
    }
    manifestBlocker.releasePrMergeHandoff = releasePrMergeHandoff
    assertReleasePrStatusReportLogResultsMatchRequirements(releasePrStatusReport, sourceLogContent, releasePrStatusReportSourcePath)
  }

  const xcmRegistryHandoff = buildXcmRegistryHandoff(blocker.slug, artifacts, actions.runLive)
  if (xcmRegistryHandoff) {
    for (const [key, value] of Object.entries(xcmRegistryHandoff)) {
      if (key === 'requiredContracts') {
        if (!Array.isArray(value) || value.length === 0) fail(`${blocker.slug}.xcmRegistryHandoff.requiredContracts must be a non-empty array`)
        for (const [index, contract] of value.entries()) {
          requireSingleLine(contract, `${blocker.slug}.xcmRegistryHandoff.requiredContracts[${index}]`)
          assertNoSecretLike(`${blocker.slug}.xcmRegistryHandoff.requiredContracts[${index}]`, contract)
        }
        continue
      }
      if (key === 'effectiveRegistry') {
        assertObject(value, `${blocker.slug}.xcmRegistryHandoff.effectiveRegistry`)
        continue
      }
      if (['remainingDiscoveryOnlyDestinations', 'remainingDiscoveryOnlyRouteAssets', 'missingExecutableDestinationCount'].includes(key)) {
        requireNumber(value, `${blocker.slug}.xcmRegistryHandoff.${key}`)
        continue
      }
      requireSingleLine(value, `${blocker.slug}.xcmRegistryHandoff.${key}`)
      assertNoSecretLike(`${blocker.slug}.xcmRegistryHandoff.${key}`, value)
    }
    manifestBlocker.xcmRegistryHandoff = xcmRegistryHandoff
  }

  blockers.push(manifestBlocker)
}

const generatedAtMs = Math.max(nowMs, summaryGeneratedAtMs)
const generatedAt = formatUtcSeconds(generatedAtMs)
const sourcePublicationHandoff = buildSourcePublicationHandoff(actions, summary, artifacts)
const manifest = {
  schemaVersion: 2,
  generatedAt,
  sourceReportDir: reportRoot,
  status: actions.status,
  runLive: actions.runLive,
  totals: actions.totals,
  blockerCount: blockers.length,
  blockers,
  sourcePublicationHandoff,
  artifacts,
}

const unblockLines = [
  '# Release Unblock Bundle',
  '',
  `- Generated at: ${generatedAt}`,
  `- Source report dir: \`${reportRoot}\``,
  `- Status: \`${actions.status}\``,
  `- Totals: ${actions.totals.passed} passed, ${actions.totals.failed} failed, ${actions.totals.skipped} skipped, ${actions.totals.total} total`,
  '',
  '## Quick Verification',
  '',
  'Verify bundle integrity and freshness from the workspace root:',
  '',
  '```bash',
  `bash scripts/verify-release-unblock-bundle.sh --bundle ${finalOutputRoot} --max-age-hours 24`,
  '```',
  '',
  'Run every blocker verification command from the bundle directory:',
  '',
  '```bash',
  './verify-blockers.sh',
  '```',
  '',
  'Run one blocker by slug from the bundle directory:',
  '',
  '```bash',
  './verify-blockers.sh release-pr-readiness',
  '```',
  '',
]

if (sourcePublicationHandoff) {
  unblockLines.push(
    '## Source Publication Attestation',
    '',
    `- Status: \`${sourcePublicationHandoff.status}\``,
    `- Root owner policy: \`${sourcePublicationHandoff.rootOwnerStatus}\``,
    `- Workspace source owned and published: \`${sourcePublicationHandoff.workspaceOwned}\``,
    `- Sources: ${sourcePublicationHandoff.passedCount} passed, ${sourcePublicationHandoff.failedCount} failed, ${sourcePublicationHandoff.sourceCount} total`,
    `- Report artifact: \`${sourcePublicationHandoff.reportArtifact}\``,
    `- Config artifact: \`${sourcePublicationHandoff.configArtifact}\``,
    `- Root owner config artifact: \`${sourcePublicationHandoff.rootOwnerConfigArtifact}\``,
    '',
  )
}

if (blockers.length === 0) {
  unblockLines.push(
    actions.status === 'incomplete'
      ? 'No failed checks were present, but required live checks were skipped; this bundle is incomplete and is not production-ready evidence.'
      : 'No release blockers were present in `actions.json`.',
    '',
  )
} else {
  for (const blocker of blockers) {
    unblockLines.push(`## ${blocker.name}`)
    unblockLines.push('')
    unblockLines.push(`- Slug: \`${blocker.slug}\``)
    unblockLines.push(`- Requires external action: \`${blocker.requiresExternalAction}\``)
    unblockLines.push(`- Unblock category: \`${blocker.unblockCategory}\``)
    unblockLines.push(`- External prerequisite: ${blocker.externalPrerequisite}`)
    unblockLines.push(`- Log: \`${blocker.logArtifact}\``)
    unblockLines.push(`- Log SHA-256: \`${blocker.logSha256}\``)
    unblockLines.push('')
    unblockLines.push('Recommended action:')
    unblockLines.push('')
    unblockLines.push(blocker.recommendedAction)
    unblockLines.push('')
    unblockLines.push('Verification command:')
    unblockLines.push('')
    unblockLines.push('```bash')
    unblockLines.push(blocker.verificationCommand)
    unblockLines.push('```')
    unblockLines.push('')
    if (blocker.evidenceTemplateCommands) {
      unblockLines.push('Evidence template commands:')
      unblockLines.push('')
      unblockLines.push('```bash')
      for (const command of blocker.evidenceTemplateCommands) {
        unblockLines.push(command)
      }
      unblockLines.push('```')
      unblockLines.push('')
      unblockLines.push('Required evidence contracts:')
      unblockLines.push('')
      for (const contract of blocker.evidenceTemplateHandoff.requiredEvidenceContracts) {
        unblockLines.push(`- \`${contract}\``)
      }
      unblockLines.push('')
    }
    if (blocker.evidenceTemplateHandoff) {
      unblockLines.push('Evidence template handoff:')
      unblockLines.push('')
      unblockLines.push(`- Output path: \`${blocker.evidenceTemplateHandoff.outputPath}\``)
      unblockLines.push(`- Destination manifest: \`${blocker.evidenceTemplateHandoff.destinationManifest}\``)
      unblockLines.push('- Ready audit command:')
      unblockLines.push('')
      unblockLines.push('```bash')
      unblockLines.push(blocker.evidenceTemplateHandoff.readyAuditCommand)
      unblockLines.push('```')
      unblockLines.push('')
    }
    if (blocker.bitcoinBroadcastTemplateHandoff) {
      unblockLines.push('Bitcoin broadcast template handoff:')
      unblockLines.push('')
      unblockLines.push(`- Template artifact: \`${blocker.bitcoinBroadcastTemplateHandoff.templateArtifact}\``)
      unblockLines.push(`- Template SHA-256: \`${blocker.bitcoinBroadcastTemplateHandoff.templateSha256}\``)
      unblockLines.push(`- Source report path: \`${blocker.bitcoinBroadcastTemplateHandoff.sourceReportPath}\``)
      unblockLines.push(`- Generated template path: \`${blocker.bitcoinBroadcastTemplateHandoff.generatedTemplatePath}\``)
      unblockLines.push(`- Destination manifest: \`${blocker.bitcoinBroadcastTemplateHandoff.destinationManifest}\``)
      unblockLines.push(`- Default indexer URL: \`${blocker.bitcoinBroadcastTemplateHandoff.defaultIndexerUrl}\``)
      unblockLines.push('')
      unblockLines.push('Template required fields:')
      unblockLines.push('')
      for (const field of blocker.bitcoinBroadcastTemplateHandoff.requiredEvidenceFields) {
        unblockLines.push(`- \`${field}\``)
      }
      unblockLines.push('')
      unblockLines.push('Template placeholders:')
      unblockLines.push('')
      for (const [field, placeholder] of Object.entries(blocker.bitcoinBroadcastTemplateHandoff.placeholderRecord)) {
        unblockLines.push(`- \`${field}=${placeholder}\``)
      }
      unblockLines.push('')
      unblockLines.push('Template contracts:')
      unblockLines.push('')
      for (const contract of blocker.bitcoinBroadcastTemplateHandoff.requiredContracts) {
        unblockLines.push(`- \`${contract}\``)
      }
      unblockLines.push('')
      unblockLines.push('Bitcoin evidence ready-audit command:')
      unblockLines.push('')
      unblockLines.push('```bash')
      unblockLines.push(blocker.bitcoinBroadcastTemplateHandoff.readyAuditCommand)
      unblockLines.push('```')
      unblockLines.push('')
    }
    if (blocker.passkeyDeploymentTemplateHandoff) {
      unblockLines.push('Passkey deployment template handoff:')
      unblockLines.push('')
      unblockLines.push(`- Template artifact: \`${blocker.passkeyDeploymentTemplateHandoff.templateArtifact}\``)
      unblockLines.push(`- Template SHA-256: \`${blocker.passkeyDeploymentTemplateHandoff.templateSha256}\``)
      unblockLines.push(`- Source report path: \`${blocker.passkeyDeploymentTemplateHandoff.sourceReportPath}\``)
      unblockLines.push(`- Generated template path: \`${blocker.passkeyDeploymentTemplateHandoff.generatedTemplatePath}\``)
      unblockLines.push(`- Destination manifest: \`${blocker.passkeyDeploymentTemplateHandoff.destinationManifest}\``)
      unblockLines.push(`- Service: \`${blocker.passkeyDeploymentTemplateHandoff.service}\``)
      unblockLines.push(`- Base URL: \`${blocker.passkeyDeploymentTemplateHandoff.baseUrl}\``)
      unblockLines.push(`- Health URL: \`${blocker.passkeyDeploymentTemplateHandoff.healthUrl}\``)
      unblockLines.push(`- Credential store file: \`${blocker.passkeyDeploymentTemplateHandoff.credentialStoreFile}\``)
      unblockLines.push('')
      unblockLines.push('Required evidence fields:')
      unblockLines.push('')
      for (const field of blocker.passkeyDeploymentTemplateHandoff.requiredEvidenceFields) {
        unblockLines.push(`- \`${field}\``)
      }
      unblockLines.push('')
      unblockLines.push('Template placeholders:')
      unblockLines.push('')
      for (const [field, placeholder] of Object.entries(blocker.passkeyDeploymentTemplateHandoff.placeholderRecord)) {
        unblockLines.push(`- \`${field}=${placeholder}\``)
      }
      unblockLines.push('')
      unblockLines.push('Health response target:')
      unblockLines.push('')
      for (const [field, value] of Object.entries(blocker.passkeyDeploymentTemplateHandoff.healthResponseTarget)) {
        unblockLines.push(`- \`${field}=${value}\``)
      }
      unblockLines.push('')
      unblockLines.push('Live health attestation target:')
      unblockLines.push('')
      for (const [field, value] of Object.entries(blocker.passkeyDeploymentTemplateHandoff.liveHealthAttestationTarget)) {
        unblockLines.push(`- \`${field}=${value}\``)
      }
      unblockLines.push('')
      unblockLines.push('WebAuthn origin targets:')
      unblockLines.push('')
      for (const origin of blocker.passkeyDeploymentTemplateHandoff.webauthnAllowedOriginsTarget) {
        unblockLines.push(`- \`${origin}\``)
      }
      unblockLines.push('')
      unblockLines.push('Request access policy target:')
      unblockLines.push('')
      for (const [field, value] of Object.entries(blocker.passkeyDeploymentTemplateHandoff.requestAccessPolicyTarget)) {
        unblockLines.push(`- \`${field}=${value}\``)
      }
      unblockLines.push('')
      unblockLines.push('Trusted proxy policy target:')
      unblockLines.push('')
      for (const [field, value] of Object.entries(blocker.passkeyDeploymentTemplateHandoff.trustedProxyPolicyTarget)) {
        unblockLines.push(`- \`${field}=${value}\``)
      }
      unblockLines.push('')
      unblockLines.push('Platform provisioning target:')
      unblockLines.push('')
      for (const [field, value] of Object.entries(blocker.passkeyDeploymentTemplateHandoff.platformProvisioningTarget)) {
        unblockLines.push(`- \`${field}=${value}\``)
      }
      unblockLines.push('')
      unblockLines.push('Platform provisioning attestation target:')
      unblockLines.push('')
      for (const [field, value] of Object.entries(blocker.passkeyDeploymentTemplateHandoff.platformProvisioningAttestationTarget)) {
        unblockLines.push(`- \`${field}=${value}\``)
      }
      unblockLines.push('')
      unblockLines.push('Template contracts:')
      unblockLines.push('')
      for (const contract of blocker.passkeyDeploymentTemplateHandoff.requiredContracts) {
        unblockLines.push(`- \`${contract}\``)
      }
      unblockLines.push('')
      unblockLines.push('Passkey evidence ready-audit command:')
      unblockLines.push('')
      unblockLines.push('```bash')
      unblockLines.push(blocker.passkeyDeploymentTemplateHandoff.readyAuditCommand)
      unblockLines.push('```')
      unblockLines.push('')
    }
    if (blocker.passkeyProductionContractHandoff) {
      unblockLines.push('Passkey production contract handoff:')
      unblockLines.push('')
      unblockLines.push(`- Production config artifact: \`${blocker.passkeyProductionContractHandoff.productionConfigArtifact}\``)
      unblockLines.push(`- Production config SHA-256: \`${blocker.passkeyProductionContractHandoff.productionConfigSha256}\``)
      unblockLines.push(`- Production config source: \`${blocker.passkeyProductionContractHandoff.productionConfigSourcePath}\``)
      unblockLines.push(`- OpenAPI artifact: \`${blocker.passkeyProductionContractHandoff.openApiArtifact}\``)
      unblockLines.push(`- OpenAPI SHA-256: \`${blocker.passkeyProductionContractHandoff.openApiSha256}\``)
      unblockLines.push(`- OpenAPI source: \`${blocker.passkeyProductionContractHandoff.openApiSourcePath}\``)
      unblockLines.push(`- Production Compose artifact: \`${blocker.passkeyProductionContractHandoff.composeArtifact}\``)
      unblockLines.push(`- Production Compose SHA-256: \`${blocker.passkeyProductionContractHandoff.composeSha256}\``)
      unblockLines.push(`- Production Compose source: \`${blocker.passkeyProductionContractHandoff.composeSourcePath}\``)
      unblockLines.push(`- Service: \`${blocker.passkeyProductionContractHandoff.service}\``)
      unblockLines.push(`- Base URL: \`${blocker.passkeyProductionContractHandoff.baseUrl}\``)
      unblockLines.push(`- RP ID: \`${blocker.passkeyProductionContractHandoff.rpId}\``)
      unblockLines.push(`- Schema version: \`${blocker.passkeyProductionContractHandoff.schemaVersion}\``)
      unblockLines.push(`- Health path: \`${blocker.passkeyProductionContractHandoff.healthPath}\``)
      unblockLines.push('- Android distribution signer evidence:')
      unblockLines.push(`  - Fingerprint environment variable: \`${blocker.passkeyProductionContractHandoff.androidSignerEvidence.fingerprintEnvironmentVariable}\``)
      unblockLines.push(`  - Source environment variable: \`${blocker.passkeyProductionContractHandoff.androidSignerEvidence.sourceEnvironmentVariable}\``)
      unblockLines.push(`  - Allowed sources: \`${blocker.passkeyProductionContractHandoff.androidSignerEvidence.allowedSources.join(', ')}\``)
      unblockLines.push(`  - Rejected evidence types: \`${blocker.passkeyProductionContractHandoff.androidSignerEvidence.rejectedEvidenceTypes.join(', ')}\``)
      unblockLines.push(`  - Independently obtained: \`${blocker.passkeyProductionContractHandoff.androidSignerEvidence.independentlyObtained}\``)
      unblockLines.push(`  - Requires assetlinks parity: \`${blocker.passkeyProductionContractHandoff.androidSignerEvidence.requiresAssetlinksParity}\``)
      unblockLines.push(`  - Exact package name: \`${blocker.passkeyProductionContractHandoff.androidSignerEvidence.exactPackageName}\``)
      unblockLines.push('  - Distributed APK evidence:')
      for (const [field, value] of Object.entries(blocker.passkeyProductionContractHandoff.androidSignerEvidence.distributedApk)) {
        unblockLines.push(`    - \`${field}=${value}\``)
      }
      unblockLines.push('  - Play app-signing certificate evidence:')
      for (const [field, value] of Object.entries(blocker.passkeyProductionContractHandoff.androidSignerEvidence.playAppSigningCertificate)) {
        unblockLines.push(`    - \`${field}=${value}\``)
      }
      unblockLines.push('- Required route paths:')
      for (const routePath of blocker.passkeyProductionContractHandoff.requiredRoutePaths) {
        unblockLines.push(`  - \`${routePath}\``)
      }
      unblockLines.push('')
      unblockLines.push('Production contract requirements:')
      unblockLines.push('')
      for (const contract of blocker.passkeyProductionContractHandoff.requiredContracts) {
        unblockLines.push(`- \`${contract}\``)
      }
      unblockLines.push('')
      unblockLines.push('Production contract verification commands:')
      unblockLines.push('')
      unblockLines.push('```bash')
      for (const command of blocker.passkeyProductionContractHandoff.verificationCommands) {
        unblockLines.push(command)
      }
      unblockLines.push('```')
      unblockLines.push('')
    }
    if (blocker.indexerDeploymentTemplateHandoff) {
      unblockLines.push('Indexer deployment template handoff:')
      unblockLines.push('')
      unblockLines.push(`- Template artifact: \`${blocker.indexerDeploymentTemplateHandoff.templateArtifact}\``)
      unblockLines.push(`- Template SHA-256: \`${blocker.indexerDeploymentTemplateHandoff.templateSha256}\``)
      unblockLines.push(`- Source report path: \`${blocker.indexerDeploymentTemplateHandoff.sourceReportPath}\``)
      unblockLines.push(`- Generated template path: \`${blocker.indexerDeploymentTemplateHandoff.generatedTemplatePath}\``)
      unblockLines.push(`- Destination manifest: \`${blocker.indexerDeploymentTemplateHandoff.destinationManifest}\``)
      unblockLines.push(`- Service ID: \`${blocker.indexerDeploymentTemplateHandoff.serviceId}\``)
      unblockLines.push(`- Base URL: \`${blocker.indexerDeploymentTemplateHandoff.baseUrl}\``)
      unblockLines.push(`- Template status: \`${blocker.indexerDeploymentTemplateHandoff.status}\``)
      unblockLines.push(`- Template release enabled: \`${blocker.indexerDeploymentTemplateHandoff.releaseEnabled}\``)
      unblockLines.push('')
      unblockLines.push('Required evidence fields:')
      unblockLines.push('')
      for (const field of blocker.indexerDeploymentTemplateHandoff.requiredEvidenceFields) {
        unblockLines.push(`- \`${field}\``)
      }
      unblockLines.push('')
      unblockLines.push('Template placeholders:')
      unblockLines.push('')
      for (const [field, placeholder] of Object.entries(blocker.indexerDeploymentTemplateHandoff.placeholderRecord)) {
        unblockLines.push(`- \`${field}=${placeholder}\``)
      }
      if (blocker.indexerDeploymentTemplateHandoff.serviceInfoTarget) {
        unblockLines.push('')
        unblockLines.push('Service-info target:')
        unblockLines.push('')
        for (const [field, value] of Object.entries(blocker.indexerDeploymentTemplateHandoff.serviceInfoTarget)) {
          unblockLines.push(`- \`${field}=${typeof value === 'object' ? JSON.stringify(value) : value}\``)
        }
      }
      unblockLines.push('')
      unblockLines.push('Health-info target:')
      unblockLines.push('')
      for (const [field, value] of Object.entries(blocker.indexerDeploymentTemplateHandoff.healthInfoTarget)) {
        unblockLines.push(`- \`${field}=${typeof value === 'object' ? JSON.stringify(value) : value}\``)
      }
      if (blocker.indexerDeploymentTemplateHandoff.soraRpcControlsTarget) {
        unblockLines.push('')
        unblockLines.push('SORA RPC controls target:')
        unblockLines.push('')
        for (const [field, value] of Object.entries(blocker.indexerDeploymentTemplateHandoff.soraRpcControlsTarget)) {
          unblockLines.push(`- \`${field}=${typeof value === 'object' ? JSON.stringify(value) : value}\``)
        }
      }
      if (blocker.indexerDeploymentTemplateHandoff.tlsEdgeControlsTarget) {
        unblockLines.push('')
        unblockLines.push('TLS-edge controls target:')
        unblockLines.push('')
        for (const [field, value] of Object.entries(blocker.indexerDeploymentTemplateHandoff.tlsEdgeControlsTarget)) {
          unblockLines.push(`- \`${field}=${typeof value === 'object' ? JSON.stringify(value) : value}\``)
        }
      }
      unblockLines.push('')
      unblockLines.push('Template contracts:')
      unblockLines.push('')
      for (const contract of blocker.indexerDeploymentTemplateHandoff.requiredContracts) {
        unblockLines.push(`- \`${contract}\``)
      }
      unblockLines.push('')
      unblockLines.push('Indexer evidence ready-audit command:')
      unblockLines.push('')
      unblockLines.push('```bash')
      unblockLines.push(blocker.indexerDeploymentTemplateHandoff.readyAuditCommand)
      unblockLines.push('```')
      unblockLines.push('')
    }
    if (blocker.nexusProductionEvidenceTemplateHandoff) {
      unblockLines.push('Nexus production evidence template handoff:')
      unblockLines.push('')
      unblockLines.push(`- Template artifact: \`${blocker.nexusProductionEvidenceTemplateHandoff.templateArtifact}\``)
      unblockLines.push(`- Template SHA-256: \`${blocker.nexusProductionEvidenceTemplateHandoff.templateSha256}\``)
      unblockLines.push(`- Source report path: \`${blocker.nexusProductionEvidenceTemplateHandoff.sourceReportPath}\``)
      unblockLines.push(`- Generated template path: \`${blocker.nexusProductionEvidenceTemplateHandoff.generatedTemplatePath}\``)
      unblockLines.push(`- Destination manifest: \`${blocker.nexusProductionEvidenceTemplateHandoff.destinationManifest}\``)
      unblockLines.push(`- Network: \`${blocker.nexusProductionEvidenceTemplateHandoff.network}\``)
      unblockLines.push(`- Chain ID: \`${blocker.nexusProductionEvidenceTemplateHandoff.chainId}\``)
      unblockLines.push(`- Torii base URL: \`${blocker.nexusProductionEvidenceTemplateHandoff.toriiBaseUrl}\``)
      unblockLines.push(`- MCP URL: \`${blocker.nexusProductionEvidenceTemplateHandoff.mcpUrl}\``)
      unblockLines.push(`- Health URL: \`${blocker.nexusProductionEvidenceTemplateHandoff.healthUrl}\``)
      unblockLines.push(`- Template status: \`${blocker.nexusProductionEvidenceTemplateHandoff.status}\``)
      unblockLines.push(`- Template release enabled: \`${blocker.nexusProductionEvidenceTemplateHandoff.releaseEnabled}\``)
      unblockLines.push('')
      unblockLines.push('Required evidence fields:')
      unblockLines.push('')
      for (const field of blocker.nexusProductionEvidenceTemplateHandoff.requiredEvidenceFields) {
        unblockLines.push(`- \`${field}\``)
      }
      unblockLines.push('')
      unblockLines.push('Route publication placeholders:')
      unblockLines.push('')
      for (const [field, placeholder] of Object.entries(blocker.nexusProductionEvidenceTemplateHandoff.routePublicationPlaceholder)) {
        unblockLines.push(`- \`${field}=${placeholder}\``)
      }
      unblockLines.push('')
      unblockLines.push('Route canary placeholders:')
      unblockLines.push('')
      for (const [field, placeholder] of Object.entries(blocker.nexusProductionEvidenceTemplateHandoff.routeCanaryPlaceholder)) {
        unblockLines.push(`- \`${field}=${placeholder}\``)
      }
      unblockLines.push('')
      unblockLines.push('Wallet smoke placeholders:')
      unblockLines.push('')
      for (const [platform, placeholder] of Object.entries(blocker.nexusProductionEvidenceTemplateHandoff.walletSmokePlaceholders)) {
        unblockLines.push(`- \`${platform}: walletCommit=${placeholder.walletCommit}; walletSmokeTransactionHash=${placeholder.walletSmokeTransactionHash}; sourceAccount=${placeholder.sourceAccount}; destinationAccount=${placeholder.destinationAccount}\``)
      }
      unblockLines.push('')
      unblockLines.push('Template contracts:')
      unblockLines.push('')
      for (const contract of blocker.nexusProductionEvidenceTemplateHandoff.requiredContracts) {
        unblockLines.push(`- \`${contract}\``)
      }
      unblockLines.push('')
      unblockLines.push('Nexus evidence ready-audit command:')
      unblockLines.push('')
      unblockLines.push('```bash')
      unblockLines.push(blocker.nexusProductionEvidenceTemplateHandoff.readyAuditCommand)
      unblockLines.push('```')
      unblockLines.push('')
      unblockLines.push('Strict release-readiness command:')
      unblockLines.push('')
      unblockLines.push('```bash')
      unblockLines.push(blocker.nexusProductionEvidenceTemplateHandoff.strictReleaseReadinessCommand)
      unblockLines.push('```')
      unblockLines.push('')
    }
    if (blocker.liveServiceHandoff) {
      unblockLines.push('Live service handoff:')
      unblockLines.push('')
      unblockLines.push(`- Service: \`${blocker.liveServiceHandoff.service}\``)
      unblockLines.push(`- Base URL: \`${blocker.liveServiceHandoff.baseUrl}\``)
      unblockLines.push(`- URL policy: protocols \`${blocker.liveServiceHandoff.urlPolicy.allowedProtocols.join(',')}\`, credentials \`${blocker.liveServiceHandoff.urlPolicy.credentials}\`, query \`${blocker.liveServiceHandoff.urlPolicy.query}\`, fragment \`${blocker.liveServiceHandoff.urlPolicy.fragment}\``)
      unblockLines.push(`- Canonical input: ${blocker.liveServiceHandoff.urlPolicy.canonicalInput}`)
      unblockLines.push(`- Health path: \`${blocker.liveServiceHandoff.healthPath}\``)
      if (blocker.liveServiceHandoff.routePaths) {
        unblockLines.push('- Smoke route paths:')
        for (const routePath of blocker.liveServiceHandoff.routePaths) {
          unblockLines.push(`  - \`${routePath}\``)
        }
      }
      if (blocker.liveServiceHandoff.serviceInfoPath) {
        unblockLines.push(`- Service-info path: \`${blocker.liveServiceHandoff.serviceInfoPath}\``)
      }
      if (blocker.liveServiceHandoff.openApiPath) {
        unblockLines.push(`- OpenAPI path: \`${blocker.liveServiceHandoff.openApiPath}\``)
      }
      unblockLines.push('')
      unblockLines.push('Expected live contracts:')
      unblockLines.push('')
      for (const contract of blocker.liveServiceHandoff.expectedContracts) {
        unblockLines.push(`- \`${contract}\``)
      }
      unblockLines.push('')
      unblockLines.push('Live verification command:')
      unblockLines.push('')
      unblockLines.push('```bash')
      unblockLines.push(blocker.liveServiceHandoff.verificationCommand)
      unblockLines.push('```')
      unblockLines.push('')
    }
    if (blocker.xcmProductionEvidenceTemplateHandoff) {
      unblockLines.push('Android XCM production evidence template handoff:')
      unblockLines.push('')
      unblockLines.push(`- Template artifact: \`${blocker.xcmProductionEvidenceTemplateHandoff.templateArtifact}\``)
      unblockLines.push(`- Template SHA-256: \`${blocker.xcmProductionEvidenceTemplateHandoff.templateSha256}\``)
      unblockLines.push(`- Source report path: \`${blocker.xcmProductionEvidenceTemplateHandoff.sourceReportPath}\``)
      unblockLines.push(`- Generated template path: \`${blocker.xcmProductionEvidenceTemplateHandoff.generatedTemplatePath}\``)
      unblockLines.push(`- Destination manifest: \`${blocker.xcmProductionEvidenceTemplateHandoff.destinationManifest}\``)
      unblockLines.push(`- Required route file: \`${blocker.xcmProductionEvidenceTemplateHandoff.requiredRouteFile}\``)
      unblockLines.push(`- Discovery-gap file: \`${blocker.xcmProductionEvidenceTemplateHandoff.discoveryGapFile}\``)
      unblockLines.push(`- Required route count: \`${blocker.xcmProductionEvidenceTemplateHandoff.requiredRouteCount}\``)
      unblockLines.push('')
      unblockLines.push('Required evidence fields:')
      unblockLines.push('')
      for (const field of blocker.xcmProductionEvidenceTemplateHandoff.requiredEvidenceFields) {
        unblockLines.push(`- \`${field}\``)
      }
      unblockLines.push('')
      unblockLines.push('Placeholder values:')
      unblockLines.push('')
      for (const [field, placeholder] of Object.entries(blocker.xcmProductionEvidenceTemplateHandoff.placeholderRecord)) {
        unblockLines.push(`- \`${field}\`: \`${placeholder}\``)
      }
      unblockLines.push('')
      unblockLines.push('Template contracts:')
      unblockLines.push('')
      for (const contract of blocker.xcmProductionEvidenceTemplateHandoff.requiredContracts) {
        unblockLines.push(`- \`${contract}\``)
      }
      unblockLines.push('')
      unblockLines.push('Ready evidence audit command:')
      unblockLines.push('')
      unblockLines.push('```bash')
      unblockLines.push(blocker.xcmProductionEvidenceTemplateHandoff.readyAuditCommand)
      unblockLines.push('```')
      unblockLines.push('')
    }
    if (blocker.xcmRegistryHandoff) {
      unblockLines.push('Android XCM registry handoff:')
      unblockLines.push('')
      unblockLines.push(`- Gap report artifact: \`${blocker.xcmRegistryHandoff.gapReportArtifact}\``)
      unblockLines.push(`- Gap report SHA-256: \`${blocker.xcmRegistryHandoff.gapReportSha256}\``)
      unblockLines.push(`- Source report path: \`${blocker.xcmRegistryHandoff.sourceReportPath}\``)
      unblockLines.push(`- Android report path: \`${blocker.xcmRegistryHandoff.generatedGapReportPath}\``)
      unblockLines.push(`- Registry file: \`${blocker.xcmRegistryHandoff.registryFile}\``)
      unblockLines.push(`- Required route file: \`${blocker.xcmRegistryHandoff.requiredRouteFile}\``)
      unblockLines.push(`- Discovery-gap file: \`${blocker.xcmRegistryHandoff.discoveryGapFile}\``)
      unblockLines.push(`- Remaining discovery-only destinations: \`${blocker.xcmRegistryHandoff.remainingDiscoveryOnlyDestinations}\``)
      unblockLines.push(`- Remaining discovery-only route assets: \`${blocker.xcmRegistryHandoff.remainingDiscoveryOnlyRouteAssets}\``)
      unblockLines.push(`- Missing executable destination records: \`${blocker.xcmRegistryHandoff.missingExecutableDestinationCount}\``)
      unblockLines.push(`- Effective-registry artifact: \`${blocker.xcmRegistryHandoff.effectiveRegistry.reportArtifact}\``)
      unblockLines.push(`- Effective-registry SHA-256: \`${blocker.xcmRegistryHandoff.effectiveRegistry.reportSha256}\``)
      unblockLines.push(`- Effective-registry mode/status: \`${blocker.xcmRegistryHandoff.effectiveRegistry.mode}/${blocker.xcmRegistryHandoff.effectiveRegistry.status}\``)
      unblockLines.push(`- Approved routes: \`${blocker.xcmRegistryHandoff.effectiveRegistry.counts.approved}\``)
      unblockLines.push(`- Compatible approved candidates: \`${blocker.xcmRegistryHandoff.effectiveRegistry.counts.effective}\``)
      unblockLines.push(`- Production executable routes: \`${blocker.xcmRegistryHandoff.effectiveRegistry.counts.productionExecutable}\``)
      unblockLines.push(`- Missing approved candidates: \`${blocker.xcmRegistryHandoff.effectiveRegistry.counts.missing}\``)
      unblockLines.push(`- Extra discovery-only routes: \`${blocker.xcmRegistryHandoff.effectiveRegistry.counts.extra}\``)
      if (blocker.xcmRegistryHandoff.effectiveRegistry.discoveryRegistry) {
        unblockLines.push(`- Production discovery: \`${blocker.xcmRegistryHandoff.effectiveRegistry.discoveryRegistry.source}\` (\`${blocker.xcmRegistryHandoff.effectiveRegistry.discoveryRegistry.byteLength}\` bytes, SHA-256 \`${blocker.xcmRegistryHandoff.effectiveRegistry.discoveryRegistry.sha256}\`)`)
      }
      unblockLines.push(`- Trust policy: authority \`${blocker.xcmRegistryHandoff.effectiveRegistry.policy.transactionAuthority}\`; meaning \`${blocker.xcmRegistryHandoff.effectiveRegistry.policy.effectiveRouteMeaning}\`; remote execution trusted \`${blocker.xcmRegistryHandoff.effectiveRegistry.policy.remoteExecutionTrusted}\`; production transfers enabled \`${blocker.xcmRegistryHandoff.effectiveRegistry.policy.productionTransfersEnabled}\`; unapproved discovery executable \`${blocker.xcmRegistryHandoff.effectiveRegistry.policy.unapprovedDiscoveryRoutesExecutable}\`; runtime role \`${blocker.xcmRegistryHandoff.effectiveRegistry.policy.runtimeDiscoveryRole}\`; runtime storage \`${blocker.xcmRegistryHandoff.effectiveRegistry.policy.runtimeDiscoveryStorage}\`; successful process sync required \`${blocker.xcmRegistryHandoff.effectiveRegistry.policy.runtimeDiscoveryRequiresSuccessfulProcessSync}\`; snapshot bound \`${blocker.xcmRegistryHandoff.effectiveRegistry.policy.runtimeDiscoverySnapshotBoundToReport}\`; freshness enforced \`${blocker.xcmRegistryHandoff.effectiveRegistry.policy.runtimeDiscoveryFreshnessEnforced}\``)
      unblockLines.push('')
      unblockLines.push('Effective-registry input identities:')
      unblockLines.push('')
      for (const [name, identity] of Object.entries(blocker.xcmRegistryHandoff.effectiveRegistry.inputContentIdentities)) {
        unblockLines.push(`- \`${name}\`: \`${identity.source}\` (\`${identity.byteLength}\` bytes, SHA-256 \`${identity.sha256}\`)`)
      }
      unblockLines.push('')
      unblockLines.push('Effective-registry audit command:')
      unblockLines.push('')
      unblockLines.push('```bash')
      unblockLines.push(blocker.xcmRegistryHandoff.effectiveRegistry.auditCommand)
      unblockLines.push('```')
      unblockLines.push('')
      unblockLines.push('Registry contracts:')
      unblockLines.push('')
      for (const contract of blocker.xcmRegistryHandoff.requiredContracts) {
        unblockLines.push(`- \`${contract}\``)
      }
      unblockLines.push('')
      unblockLines.push('Registry verification command:')
      unblockLines.push('')
      unblockLines.push('```bash')
      unblockLines.push(blocker.xcmRegistryHandoff.registryAuditCommand)
      unblockLines.push('```')
      unblockLines.push('')
    }
    unblockLines.push('Evidence preview:')
    unblockLines.push('')
    pushFencedBlock(unblockLines, 'text', blocker.evidencePreview)
    unblockLines.push('')
    if (blocker.outdatedReviewThreadResolution) {
      unblockLines.push('Outdated review-thread resolution dry run:')
      unblockLines.push('')
      unblockLines.push('```bash')
      unblockLines.push(blocker.outdatedReviewThreadResolution.dryRunCommand)
      unblockLines.push('```')
      unblockLines.push('')
      unblockLines.push('Eligible outdated review threads:')
      unblockLines.push('')
      for (const thread of blocker.outdatedReviewThreadResolution.threads) {
        unblockLines.push(`- ${thread.repo}#${thread.pr}: \`${thread.id}\`${thread.refs ? ` (${thread.refs})` : ''}`)
      }
      unblockLines.push('')
      unblockLines.push('Apply command after explicit authorization:')
      unblockLines.push('')
      unblockLines.push('```bash')
      unblockLines.push(blocker.outdatedReviewThreadResolution.applyCommand)
      unblockLines.push('```')
      unblockLines.push('')
    }
    if (blocker.releasePrApprovalHandoff) {
      unblockLines.push('Release PR approval handoff:')
      unblockLines.push('')
      unblockLines.push(`- Approval-only PR count: \`${blocker.releasePrApprovalHandoff.approvalCount}\``)
      unblockLines.push('- PRs needing eligible reviewer approval:')
      unblockLines.push('')
      for (const pr of blocker.releasePrApprovalHandoff.prs) {
        const details = [
          pr.requiredAction,
          `reviewDecision=${pr.reviewDecision}`,
          `mergeStateStatus=${pr.mergeStateStatus}`,
          ...releasePrApprovalDiagnosticParts(pr),
        ]
        unblockLines.push(`- ${pr.repo}#${pr.pr}: ${pr.url} (${details.join('; ')})`)
      }
      unblockLines.push('')
      unblockLines.push('After approval, inspect merge candidates:')
      unblockLines.push('')
      unblockLines.push('```bash')
      unblockLines.push(blocker.releasePrApprovalHandoff.dryRunCommand)
      unblockLines.push('```')
      unblockLines.push('')
    }
    if (blocker.releasePrStatusReportHandoff) {
      unblockLines.push('Release PR status report handoff:')
      unblockLines.push('')
      unblockLines.push(`- Report artifact: \`${blocker.releasePrStatusReportHandoff.reportArtifact}\``)
      unblockLines.push(`- Report SHA-256: \`${blocker.releasePrStatusReportHandoff.reportSha256}\``)
      unblockLines.push(`- Source report path: \`${blocker.releasePrStatusReportHandoff.sourceReportPath}\``)
      unblockLines.push(`- Config: \`${blocker.releasePrStatusReportHandoff.configPath}\``)
      unblockLines.push(`- Status: \`${blocker.releasePrStatusReportHandoff.status}\``)
      unblockLines.push(`- Required PR rows: \`${blocker.releasePrStatusReportHandoff.requiredPrCount}\``)
      unblockLines.push(`- Failed PR rows: \`${blocker.releasePrStatusReportHandoff.failedCount}\``)
      if (blocker.releasePrStatusReportHandoff.blockedPrs.length > 0) {
        unblockLines.push('Blocked PRs:')
        for (const pr of blocker.releasePrStatusReportHandoff.blockedPrs) {
          unblockLines.push(`- \`${pr.repo}#${pr.pr}\` ${pr.head} -> ${pr.base} row ${pr.configLine}, requiredState=${pr.requiredState}, checks=${pr.requiredChecks.join(',')} (${pr.reviewDecision}, ${pr.mergeStateStatus}): ${pr.url}`)
        }
      }
      unblockLines.push('Dry run:')
      unblockLines.push('')
      unblockLines.push('```bash')
      unblockLines.push(blocker.releasePrStatusReportHandoff.dryRunCommand)
      unblockLines.push('```')
      unblockLines.push('')
    }
    if (blocker.releasePrMergeHandoff) {
      unblockLines.push('Protected release PR merge handoff:')
      unblockLines.push('')
      unblockLines.push(`- Config: \`${blocker.releasePrMergeHandoff.configPath}\``)
      unblockLines.push(`- Required PR rows: \`${blocker.releasePrMergeHandoff.requiredPrCount}\``)
      unblockLines.push(`- Blocked PR rows: \`${blocker.releasePrMergeHandoff.blockedPrCount}\``)
      unblockLines.push(`- Merge method: \`${blocker.releasePrMergeHandoff.mergeMethod}\``)
      unblockLines.push('Dry run:')
      unblockLines.push('')
      unblockLines.push('```bash')
      unblockLines.push(blocker.releasePrMergeHandoff.dryRunCommand)
      unblockLines.push('```')
      unblockLines.push('')
      unblockLines.push('Apply command after approvals and resolved conversations:')
      unblockLines.push('')
      unblockLines.push('```bash')
      unblockLines.push(blocker.releasePrMergeHandoff.applyCommand)
      unblockLines.push('```')
      unblockLines.push('')
      unblockLines.push('Post-merge verification:')
      unblockLines.push('')
      unblockLines.push('```bash')
      unblockLines.push(blocker.releasePrMergeHandoff.postMergeVerificationCommand)
      unblockLines.push('```')
      unblockLines.push('')
    }
  }
}

const manifestPath = path.join(outputRoot, 'manifest.json')
const unblockPath = path.join(outputRoot, 'unblock.md')
const verifyScriptPath = path.join(outputRoot, 'verify-blockers.sh')
fs.writeFileSync(manifestPath, JSON.stringify(manifest, null, 2) + '\n')
fs.writeFileSync(unblockPath, unblockLines.join('\n'))
fs.writeFileSync(verifyScriptPath, renderVerifyScript(blockers))
fs.chmodSync(verifyScriptPath, 0o755)

function listFiles(dir) {
  const entries = fs.readdirSync(dir, { withFileTypes: true })
  return entries.flatMap((entry) => {
    const absolute = path.join(dir, entry.name)
    if (entry.isDirectory()) return listFiles(absolute)
    if (!entry.isFile()) fail(`unsupported output bundle entry type: ${absolute}`)
    return [absolute]
  })
}

function checksumLineForFile(file) {
  const relative = normalizeBundleRelativePath(path.relative(outputRoot, file).split(path.sep).join('/'))
  if (relative === 'SHA256SUMS') return null
  const content = fs.readFileSync(file)
  return `${sha256(content)}  ${relative}`
}

const checksumLines = listFiles(outputRoot)
  .map((file) => checksumLineForFile(file))
  .filter((line) => line !== null)
  .sort()

fs.writeFileSync(path.join(outputRoot, 'SHA256SUMS'), checksumLines.join('\n') + '\n')

function validateStagedBundleForPublication() {
  assertOwnedTemporaryDirectory(stagingState, 'staging directory')
  for (const requiredFile of ['summary.json', 'actions.json', 'blockers.md', 'manifest.json', 'unblock.md', 'verify-blockers.sh', 'SHA256SUMS']) {
    assertRegularFile(path.join(outputRoot, requiredFile), `staged ${requiredFile}`)
  }
  const expectedChecksums = checksumLines.join('\n') + '\n'
  const actualChecksums = fs.readFileSync(path.join(outputRoot, 'SHA256SUMS'), 'utf8')
  if (actualChecksums !== expectedChecksums) fail('staged SHA256SUMS changed before publication')
  const stagedFiles = listFiles(outputRoot)
  if (stagedFiles.length !== checksumLines.length + 1) {
    fail('staged bundle file set changed before publication')
  }
  const recomputedChecksums = stagedFiles
    .map((file) => checksumLineForFile(file))
    .filter((line) => line !== null)
    .sort()
  if (recomputedChecksums.join('\n') + '\n' !== expectedChecksums) {
    fail('staged bundle content changed before publication')
  }
}

function rollbackPublication(staged, previousPath, oldOutputMoved, stagedOutputMoved) {
  try {
    if (stagedOutputMoved && fs.existsSync(finalOutputRoot)) {
      const currentOutput = lstatIdentity(finalOutputRoot)
      if (currentOutput.isDirectory && !currentOutput.isSymbolicLink && hasSameIdentity(currentOutput, staged.identity) && !fs.existsSync(staged.path)) {
        fs.renameSync(finalOutputRoot, staged.path)
        stagingState = staged
        outputRoot = staged.path
      }
    }
    if (oldOutputMoved && previousPath && fs.existsSync(previousPath) && !fs.existsSync(finalOutputRoot)) {
      fs.renameSync(previousPath, finalOutputRoot)
    }
  } catch (error) {
    console.error(`[release-unblock-bundle][warn] could not fully roll back bundle publication: ${error.message}`)
  }
}

function publishStagedBundle() {
  assertStableFinalOutput()
  assertOwnedTemporaryDirectory(stagingState, 'staging directory')

  const staged = stagingState
  let previousPath = null
  let oldOutputMoved = false
  let stagedOutputMoved = false

  if (initialOutputState.exists) {
    const backupPrefix = path.join(outputParentState.path, `.${path.basename(finalOutputRoot)}.previous-`)
    const backupPath = fs.mkdtempSync(backupPrefix)
    fs.chmodSync(backupPath, 0o700)
    const backupIdentity = lstatIdentity(backupPath)
    if (!backupIdentity.isDirectory || backupIdentity.isSymbolicLink || backupIdentity.dev !== outputParentState.identity.dev) {
      fs.rmSync(backupPath, { recursive: true, force: true })
      fail(`could not create a secure same-filesystem backup directory for output: ${finalOutputRoot}`)
    }
    previousPath = path.join(backupPath, 'previous')
    backupState = { path: backupPath, identity: backupIdentity, previousPath }

    // Recheck every publication path after creating the private backup directory,
    // immediately before the first rename closes the validation/publication race.
    assertStableFinalOutput()
    assertOwnedTemporaryDirectory(stagingState, 'staging directory')
    assertOwnedTemporaryDirectory(backupState, 'backup directory')
  }

  try {
    if (initialOutputState.exists) {
      fs.renameSync(finalOutputRoot, previousPath)
      oldOutputMoved = true
    }

    // The staging directory is a sibling on the same filesystem, so this is the
    // sole publication rename and no partially constructed bundle is observable.
    fs.renameSync(staged.path, finalOutputRoot)
    stagedOutputMoved = true
    stagingState = null
    outputRoot = finalOutputRoot

    const publishedIdentity = lstatIdentity(finalOutputRoot)
    if (!publishedIdentity.isDirectory || publishedIdentity.isSymbolicLink || !hasSameIdentity(publishedIdentity, staged.identity)) {
      throw new Error(`published output identity mismatch: ${finalOutputRoot}`)
    }
    publicationCommitted = true
  } catch (error) {
    rollbackPublication(staged, previousPath, oldOutputMoved, stagedOutputMoved)
    throw error
  }

  if (backupState && removeOwnedTemporaryDirectory(backupState, 'backup directory')) {
    backupState = null
  }
}

validateStagedBundleForPublication()
publishStagedBundle()
console.log(`[release-unblock-bundle] Wrote release unblock bundle to ${finalOutputRoot}`)
NODE
