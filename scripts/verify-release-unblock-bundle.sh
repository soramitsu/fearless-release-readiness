#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="${RELEASE_UNBLOCK_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
BUNDLE_DIR="${RELEASE_UNBLOCK_BUNDLE_DIR:-$ROOT_DIR/build/reports/release-readiness/unblock-bundle}"
MAX_AGE_HOURS=""
PUBLISHED_BUNDLE_PATH=""

usage() {
  cat <<'USAGE'
Usage: scripts/verify-release-unblock-bundle.sh [--bundle DIR] [--published-path DIR] [--max-age-hours HOURS]

Verifies a release-unblock handoff bundle without requiring access to the
original release-readiness report directory. The verifier checks bundle schema,
checksum coverage, copied artifact integrity, blocker/action consistency, safe
relative paths, executable verification-script integrity, and secret-like
content rejection.

Environment:
  RELEASE_UNBLOCK_ROOT        Workspace root.
  RELEASE_UNBLOCK_BUNDLE_DIR  Bundle directory to verify.
  RELEASE_UNBLOCK_VERIFY_NOW  Override current UTC time for deterministic tests.
USAGE
}

while (($#)); do
  case "$1" in
    --bundle)
      BUNDLE_DIR="$2"
      shift 2
      ;;
    --max-age-hours)
      MAX_AGE_HOURS="$2"
      shift 2
      ;;
    --published-path)
      PUBLISHED_BUNDLE_PATH="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "[release-unblock-bundle-verify][error] Unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

node - "$BUNDLE_DIR" "$MAX_AGE_HOURS" "$ROOT_DIR" "$PUBLISHED_BUNDLE_PATH" <<'NODE'
const crypto = require('crypto')
const fs = require('fs')
const path = require('path')

const [, , bundleDirArg, maxAgeHoursArg, workspaceRootArg, publishedBundlePathArg] = process.argv
const bundleRoot = path.resolve(bundleDirArg)
const configuredWorkspaceRoot = path.resolve(workspaceRootArg)

function fail(message) {
  console.error(`[release-unblock-bundle-verify][error] ${message}`)
  process.exit(1)
}

const publishedBundleRoot = publishedBundlePathArg || bundleRoot
requireSingleLine(bundleRoot, 'bundle directory')
requireSingleLine(configuredWorkspaceRoot, 'workspace root')
requireSingleLine(publishedBundleRoot, 'published bundle path')
if (!path.isAbsolute(publishedBundleRoot) || path.normalize(publishedBundleRoot) !== publishedBundleRoot) {
  fail(`published bundle path must be absolute and normalized: ${publishedBundleRoot}`)
}

function assertRegularBundleDirectory(dir) {
  if (!fs.existsSync(dir)) fail(`bundle directory missing: ${dir}`)
  const stat = fs.lstatSync(dir)
  if (!stat.isDirectory()) fail(`bundle directory must be a regular directory: ${dir}`)
}

function assertRegularWorkspaceDirectory(dir) {
  if (!fs.existsSync(dir)) fail(`workspace root missing: ${dir}`)
  const stat = fs.lstatSync(dir)
  if (!stat.isDirectory()) fail(`workspace root must be a regular directory: ${dir}`)
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
      if (label === 'bundle directory') fail(`bundle directory must not use a symlinked path component: ${current}`)
      fail(`${label} must not use a symlinked path component: ${current}`)
    }
  }
}

function assertNoWorkspaceRootSymlinkPrefix(target) {
  assertNoRootSymlinkPathPrefix(target, 'workspace root')
}

function assertNoBundleRootSymlinkPrefix(target) {
  assertNoRootSymlinkPathPrefix(target, 'bundle directory')
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

function assertRegularBundleFile(relativePath, label) {
  const file = safeBundlePath(relativePath, `${label} path`)
  if (!fs.existsSync(file)) fail(`${label} missing: ${relativePath}`)
  const stat = fs.lstatSync(file)
  if (!stat.isFile()) fail(`${label} must be a regular file: ${relativePath}`)
  return file
}

function readBundleFile(relativePath, label, encoding) {
  const file = assertRegularBundleFile(relativePath, label)
  return encoding === undefined ? fs.readFileSync(file) : fs.readFileSync(file, encoding)
}

function parseJson(content, label) {
  try {
    return JSON.parse(Buffer.isBuffer(content) ? content.toString('utf8') : content)
  } catch (error) {
    fail(`${label} is not valid JSON: ${error.message}`)
  }
}

function readJson(relativePath, label) {
  return parseJson(readBundleFile(relativePath, label), label)
}

function assertObject(value, label) {
  if (!value || typeof value !== 'object' || Array.isArray(value)) {
    fail(`${label} must be an object`)
  }
}

function assertAllowedKeys(value, allowed, label) {
  assertObject(value, label)
  for (const key of Object.keys(value)) {
    if (!allowed.includes(key)) fail(`unsupported ${label} key: ${key}`)
  }
}

function requireString(value, label) {
  if (typeof value !== 'string' || value.trim() === '') {
    fail(`${label} must be a non-empty string`)
  }
}

function requireSingleLine(value, label) {
  requireString(value, label)
  if (/[\r\n\u0000]/.test(value)) fail(`${label} must be a single-line value`)
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
    if (!normalizedLog.includes(line)) fail(`${label} line is not present in source log`)
    if (!logLines.has(line)) fail(`${label} line must match a complete source log line`)
    matchedLines += 1
  }

  if (allowCappedPartialLine) fail(`${label} line cap marker must be followed by a source log line suffix`)

  if (matchedLines === 0) fail(`${label} must include at least one source log line`)
}

function requireBoolean(value, label) {
  if (typeof value !== 'boolean') fail(`${label} must be boolean`)
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

function assertNotFutureTimestamp(timeMs, value, label, nowMs, futureSkewMs) {
  if (timeMs > nowMs + futureSkewMs) {
    fail(`${label} is in the future: ${value}`)
  }
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

function assertNotFutureDate(timeMs, value, label, nowMs, futureSkewMs) {
  if (timeMs > nowMs + futureSkewMs) {
    fail(`${label} must not be in the future`)
  }
}

function parsePositiveInteger(value, label) {
  if (!/^[1-9][0-9]*$/.test(value)) fail(`${label} must be a positive integer`)
  return Number(value)
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

function normalizeRelativePath(relativePath, label) {
  requireString(relativePath, label)
  if (relativePath.includes('\\')) fail(`${label} must use forward slashes: ${relativePath}`)
  if (path.isAbsolute(relativePath)) fail(`${label} must be relative: ${relativePath}`)
  const normalized = path.posix.normalize(relativePath)
  if (normalized === '.' || normalized.startsWith('../') || normalized.includes('/../')) {
    fail(`${label} points outside bundle: ${relativePath}`)
  }
  if (normalized !== relativePath) fail(`${label} must be normalized: ${relativePath}`)
  return normalized
}

function safeBundlePath(relativePath, label) {
  const normalized = normalizeRelativePath(relativePath, label)
  const resolved = path.resolve(bundleRoot, normalized)
  if (resolved !== bundleRoot && !resolved.startsWith(bundleRoot + path.sep)) {
    fail(`${label} points outside bundle: ${relativePath}`)
  }
  const segments = normalized.split('/').filter(Boolean)
  let current = bundleRoot
  for (const segment of segments.slice(0, -1)) {
    current = path.join(current, segment)
    if (fs.existsSync(current) && fs.lstatSync(current).isSymbolicLink()) {
      fail(`${label} must not use a symlinked parent component: ${relativePath}`)
    }
  }
  return resolved
}

function normalizeAbsolutePath(value, label) {
  requireString(value, label)
  assertNoSecretLike(label, value)
  if (!path.isAbsolute(value)) fail(`${label} must be an absolute normalized path`)
  const normalized = path.resolve(value)
  if (normalized !== value) fail(`${label} must be an absolute normalized path`)
  return normalized
}

function assertInsideWorkspaceRoot(value, label, workspaceRoot) {
  const resolved = normalizeAbsolutePath(value, label)
  if (resolved !== workspaceRoot && !resolved.startsWith(workspaceRoot + path.sep)) {
    fail(`${label} points outside workspace root: ${value}`)
  }
  return resolved
}

function assertInsideSourceReportDir(value, label, sourceReportDir) {
  const resolved = normalizeAbsolutePath(value, label)
  if (resolved !== sourceReportDir && !resolved.startsWith(sourceReportDir + path.sep)) {
    fail(`${label} points outside sourceReportDir: ${value}`)
  }
  return resolved
}

function resolveSourceReportPath(value, label, sourceReportDir) {
  requireString(value, label)
  assertNoSecretLike(label, value)
  if (value.includes('\\')) fail(`${label} must use forward slashes: ${value}`)

  let resolved
  if (path.isAbsolute(value)) {
    resolved = path.resolve(value)
    if (resolved !== value) fail(`${label} must be absolute normalized or relative normalized path`)
  } else {
    const normalized = path.posix.normalize(value)
    if (normalized === '.' || normalized.startsWith('../') || normalized.includes('/../') || normalized !== value) {
      fail(`${label} must be absolute normalized or relative normalized path`)
    }
    resolved = path.resolve(sourceReportDir, normalized)
  }

  if (resolved !== sourceReportDir && !resolved.startsWith(sourceReportDir + path.sep)) {
    fail(`${label} points outside sourceReportDir: ${value}`)
  }
  return resolved
}

function expectedSourcePathForArtifact(relativePath, sourceReportDir) {
  if (['summary.json', 'actions.json', 'blockers.md'].includes(relativePath)) {
    return path.join(sourceReportDir, relativePath)
  }
  if (relativePath === 'handoffs/release-pr-readiness-report.json') {
    return path.join(sourceReportDir, 'release-pr-readiness-report.json')
  }
  if (relativePath === 'handoffs/source-publication-readiness-report.json') {
    return path.join(sourceReportDir, 'source-publication-readiness-report.json')
  }
  if (relativePath === 'handoffs/source-publication-preflight-report.json') {
    return path.join(sourceReportDir, 'source-publication-preflight-report.json')
  }
  if (relativePath === 'handoffs/android-xcm-registry-gap-report.json') {
    return path.join(sourceReportDir, 'android-xcm-registry-gap-report.json')
  }
  if (relativePath === 'handoffs/android-xcm-effective-registry-report.json') {
    return path.join(sourceReportDir, 'android-xcm-effective-registry-report.json')
  }
  if (relativePath === 'handoffs/android-xcm-production-evidence-template.json') {
    return path.join(sourceReportDir, 'android-xcm-production-evidence-template.json')
  }
  if (relativePath === 'handoffs/web-bitcoin-broadcast-evidence-template.json') {
    return path.join(sourceReportDir, 'web-bitcoin-broadcast-evidence-template.json')
  }
  if (relativePath === 'handoffs/passkey-deployment-evidence-template.json') {
    return path.join(sourceReportDir, 'passkey-deployment-evidence-template.json')
  }
  if (relativePath === 'handoffs/nexus-production-evidence-template.json') {
    return path.join(sourceReportDir, 'nexus-production-evidence-template.json')
  }
  if (relativePath === 'handoffs/ti-deployment-evidence-template.json') {
    return path.join(sourceReportDir, 'ti-deployment-evidence-template.json')
  }
  if (relativePath === 'handoffs/si-deployment-evidence-template.json') {
    return path.join(sourceReportDir, 'si-deployment-evidence-template.json')
  }
  if (relativePath === 'handoffs/pi-deployment-evidence-template.json') {
    return path.join(sourceReportDir, 'pi-deployment-evidence-template.json')
  }
  if (/^logs\/[a-z0-9][a-z0-9-]*\.log$/.test(relativePath)) return null
  fail(`unsupported manifest artifact path: ${relativePath}`)
}

function expectedWorkspaceSourcePathForArtifact(relativePath, workspaceRoot) {
  if (relativePath === 'handoffs/passkey-backup-production.json') {
    return path.join(workspaceRoot, 'config/passkey-backup-production.json')
  }
  if (relativePath === 'handoffs/source-publication-readiness.tsv') {
    return path.join(workspaceRoot, 'config/source-publication-readiness.tsv')
  }
  if (relativePath === 'handoffs/source-publication-root-owner.json') {
    return path.join(workspaceRoot, 'config/source-publication-root-owner.json')
  }
  if (relativePath === 'handoffs/passkey-backup-challenge-service.openapi.json') {
    return path.join(workspaceRoot, 'config/passkey-backup-challenge-service.openapi.json')
  }
  if (relativePath === 'handoffs/passkey-backup-docker-compose.production.yml') {
    return path.join(workspaceRoot, 'services/passkey-backup-challenge-service/docker-compose.production.yml')
  }
  return null
}

const releasePrStatusReportArtifactPath = 'handoffs/release-pr-readiness-report.json'
const releasePrConfigPath = 'config/release-readiness-prs.tsv'
const sourcePublicationReportArtifactPath = 'handoffs/source-publication-readiness-report.json'
const sourcePublicationPreflightReportArtifactPath = 'handoffs/source-publication-preflight-report.json'
const sourcePublicationConfigArtifactPath = 'handoffs/source-publication-readiness.tsv'
const sourcePublicationConfigPath = 'config/source-publication-readiness.tsv'
const sourcePublicationRootOwnerConfigArtifactPath = 'handoffs/source-publication-root-owner.json'
const sourcePublicationRootOwnerConfigPath = 'config/source-publication-root-owner.json'
const sourcePublicationRepositories = [
  ['fearless-Android-production-consolidated-20260731', 'soramitsu/fearless-Android', 'codex/android-production-consolidated-20260731', 'develop', 1260],
  ['fearless-iOS-production-consolidated-20260731', 'soramitsu/fearless-iOS', 'codex/testflight-redesign-2026.8.17', 'develop', 1304],
  ['fearless-wallet-web', 'soramitsu/fearless-wallet-web', 'codex/web-bitcoin-canonical-indexer-evidence', 'develop', 1062],
  ['fearless-site-web-app-associations-20260726', 'soramitsu/fearless-site-web', 'fix/app-association-publication', 'develop', 49],
  ['../ton-indexer', 'tonswap-org/ton-indexer', 'codex/ti-smoke-body-preview-tests', 'develop', 13],
  ['../solswap-indexer', 'solswap-io/solswap-indexer', 'codex/si-smoke-body-preview-tests', 'develop', 16],
  ['../polkaswap-indexer', 'sora-xor/polkaswap-indexer', 'codex/pi-deployment-evidence-gate', 'develop', 1],
  ['../iroha', 'hyperledger-iroha/iroha', 'optimizations', 'optimizations', null],
]
const sourcePublicationWorkspaceRequiredFiles = [
  '.github/CODEOWNERS',
  '.github/workflows/readiness.yml',
  '.gitignore',
  'FEARLESS_PROJECT_PLAN.md',
  'README.md',
  'config/release-readiness-prs.tsv',
  'config/source-publication-root-owner.json',
  'config/source-publication-readiness.tsv',
  'docs/passkey-enabled-acceptance.md',
  'docs/release-shipping-manifest.md',
  'docs/source-freeze-20260801.md',
  'scripts/audit-passkey-enabled-acceptance.mjs',
  'scripts/audit-release-shipping-manifest.mjs',
  'scripts/test-release-shipping-manifest.mjs',
  'scripts/test-passkey-enabled-acceptance.mjs',
  'scripts/audit-plan-readiness.sh',
  'scripts/test-plan-readiness-audit.sh',
  'scripts/audit-release-readiness.sh',
  'scripts/audit-source-publication-readiness.mjs',
  'scripts/capture-source-freeze.mjs',
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
  'services/passkey-backup-owner-authority/README.md',
  'services/passkey-backup-owner-authority/docs/bootstrap-proof.md',
  'services/passkey-backup-owner-authority/docs/legacy-cutover.md',
  'services/passkey-backup-owner-authority/package.json',
  'services/passkey-backup-owner-authority/package-lock.json',
  'services/passkey-backup-owner-authority/scripts/reconcile-legacy-credentials.mjs',
  'services/passkey-backup-owner-authority/scripts/quarantine-legacy-credentials.mjs',
  'services/passkey-backup-owner-authority/scripts/verify-sealed-legacy-cutover.mjs',
  'services/passkey-backup-owner-authority/src/authority.js',
  'services/passkey-backup-owner-authority/src/bootstrap-proof.js',
  'services/passkey-backup-owner-authority/src/http.js',
  'services/passkey-backup-owner-authority/src/legacy-cutover-verifier.js',
  'services/passkey-backup-owner-authority/src/legacy-quarantine.js',
  'services/passkey-backup-owner-authority/src/legacy-reconciliation.js',
  'services/passkey-backup-owner-authority/src/store.js',
  'services/passkey-backup-owner-authority/src/validation.js',
  'services/passkey-backup-owner-authority/src/verifier-contract.d.ts',
  'services/passkey-backup-owner-authority/src/webauthn-verifier.js',
  'services/passkey-backup-owner-authority/test/authority.test.js',
  'services/passkey-backup-owner-authority/test/challenge-credential-mutation.test.js',
  'services/passkey-backup-owner-authority/test/generation-head.test.js',
  'services/passkey-backup-owner-authority/test/http.test.js',
  'services/passkey-backup-owner-authority/test/legacy-cutover-challenge.test.js',
  'services/passkey-backup-owner-authority/test/legacy-cutover-webauthn.test.js',
  'services/passkey-backup-owner-authority/test/legacy-cutover-verifier.test.js',
  'services/passkey-backup-owner-authority/test/legacy-quarantine.test.js',
  'services/passkey-backup-owner-authority/test/legacy-reconciliation.test.js',
  'services/passkey-backup-owner-authority/test/legacy-schema-migration.test.js',
  'services/passkey-backup-owner-authority/test/fixtures.js',
  'services/passkey-backup-owner-authority/test/process-worker.js',
  'services/passkey-backup-owner-authority/test/webauthn-verifier.test.js',
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
  if (source.path === '../iroha') fail(`${label}.canonical branch exact-SHA review is blocked`)
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

function assertSourcePublicationReport(report, label, expectedPhase, workspaceRoot, summaryGeneratedAt = null, verificationNow = null) {
  assertAllowedKeys(report, ['schemaVersion', 'phase', 'preflightReportSha256', 'generatedAt', 'status', 'checkRemote', 'workspaceRoot', 'workspaceParent', 'configFile', 'rootOwnerConfigFile', 'releasePrConfigFile', 'totals', 'workspaceSource', 'repositories'], label)
  if (report.schemaVersion !== 3) fail(`${label}.schemaVersion must be 3`)
  if (report.phase !== expectedPhase) fail(`${label}.phase must be ${expectedPhase}`)
  if (expectedPhase === 'postflight') {
    if (typeof report.preflightReportSha256 !== 'string' || !/^[0-9a-f]{64}$/.test(report.preflightReportSha256)) {
      fail(`${label}.preflightReportSha256 must be lowercase SHA-256 for postflight`)
    }
  } else if (report.preflightReportSha256 !== null) {
    fail(`${label}.preflightReportSha256 must be null for ${expectedPhase}`)
  }
  const sourceGeneratedAtMs = parseUtcTimestamp(report.generatedAt, `${label}.generatedAt`)
  if (verificationNow !== null) assertNotFutureTimestamp(sourceGeneratedAtMs, report.generatedAt, `${label}.generatedAt`, verificationNow, 5 * 60 * 1000)
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

function assertSourcePublicationPair(preflightReport, postflightReport, preflightBytes, label) {
  const expectedSha256 = sha256(preflightBytes)
  if (postflightReport.preflightReportSha256 !== expectedSha256) {
    fail(`${label}.postflight preflightReportSha256 must match the exact preflight report bytes`)
  }
  const preflightGeneratedAtMs = parseUtcTimestamp(preflightReport.generatedAt, `${label}.preflight.generatedAt`)
  const postflightGeneratedAtMs = parseUtcTimestamp(postflightReport.generatedAt, `${label}.postflight.generatedAt`)
  const ageMs = postflightGeneratedAtMs - preflightGeneratedAtMs
  if (ageMs < 0) fail(`${label}.preflight report must not postdate the postflight report`)
  if (ageMs > 6 * 60 * 60 * 1000) fail(`${label}.preflight report is stale for the postflight report`)
  for (const field of ['workspaceRoot', 'workspaceParent', 'configFile', 'rootOwnerConfigFile', 'releasePrConfigFile']) {
    if (preflightReport[field] !== postflightReport[field]) fail(`${label}.${field} must match across preflight and postflight`)
  }
  const preflightSources = [preflightReport.workspaceSource, ...preflightReport.repositories]
  const postflightSources = [postflightReport.workspaceSource, ...postflightReport.repositories]
  if (preflightSources.length !== 9 || postflightSources.length !== 9) {
    fail(`${label}.sources must contain exactly nine ordered preflight/postflight rows`)
  }
  const identityFields = [
    'path',
    'repository',
    'head',
    'base',
    'prNumber',
    'prUrl',
    'prState',
    'prHeadSha',
    'repositoryPath',
    'originUrl',
    'originRepository',
    'branch',
    'headSha',
    'upstream',
    'upstreamSha',
    'currentBranchRemoteSha',
    'currentBranchRemotePresent',
    'remoteHeadSha',
    'remoteBranchPresent',
  ]
  const volatilePublicationProofFields = new Set([
    'upstream',
    'upstreamSha',
    'currentBranchRemoteSha',
    'currentBranchRemotePresent',
    'remoteHeadSha',
    'remoteBranchPresent',
  ])
  const failedPreflightContinuityDiagnostic = 'source publication preflight did not pass before release checks'
  for (let index = 0; index < preflightSources.length; index += 1) {
    const preflightSource = preflightSources[index]
    const postflightSource = postflightSources[index]
    if (preflightSource.path !== postflightSource.path) {
      fail(`${label}.sources[${index}].path must match across preflight and postflight`)
    }
    if (preflightSource.status === 'passed') {
      const mergedBranchWasDeleted =
        preflightSource.prState === 'merged' &&
        postflightSource.prState === 'merged' &&
        preflightSource.branch === preflightSource.head &&
        postflightSource.branch === postflightSource.head &&
        preflightSource.upstream === `origin/${preflightSource.head}` &&
        preflightSource.upstreamSha === preflightSource.headSha &&
        preflightSource.remoteBranchPresent === true &&
        preflightSource.remoteHeadSha === preflightSource.headSha &&
        preflightSource.currentBranchRemotePresent === true &&
        preflightSource.currentBranchRemoteSha === preflightSource.headSha &&
        postflightSource.upstream === null &&
        postflightSource.upstreamSha === null &&
        postflightSource.remoteBranchPresent === false &&
        postflightSource.remoteHeadSha === null &&
        postflightSource.currentBranchRemotePresent === false &&
        postflightSource.currentBranchRemoteSha === null
      for (const field of identityFields) {
        if (mergedBranchWasDeleted && volatilePublicationProofFields.has(field)) continue
        if (preflightSource[field] !== postflightSource[field]) {
          fail(`${label}.sources[${index}].${field} must match across preflight and postflight`)
        }
      }
    } else if (!postflightSource.failures.includes(failedPreflightContinuityDiagnostic)) {
      fail(`${label}.sources[${index}].failures must contain the exact failed-preflight continuity diagnostic`)
    }
  }
}

function assertSourcePublicationConfig(content, label) {
  if (content.includes('\r') || content.includes('\0')) fail(`${label} must use LF text without NUL bytes`)
  const rows = content.split('\n').filter((line) => line && !line.startsWith('#')).map((line) => line.split('\t'))
  if (rows.length !== sourcePublicationRepositories.length) fail(`${label} must contain eight rows`)
  rows.forEach((row, index) => {
    if (row.length !== 5) fail(`${label} row ${index + 1} must contain five columns`)
    const [expectedPath, expectedRepository, expectedHead, expectedBase, expectedPr] = sourcePublicationRepositories[index]
    if (expectedPr === null) {
      if (row[4] !== '-') fail(`${label} row ${index + 1} canonical branch must not claim a pull request`)
    } else if (!/^[1-9][0-9]*$/.test(row[4]) || !Number.isSafeInteger(Number(row[4]))) fail(`${label} row ${index + 1} pull request must be canonical positive digits`)
    if (row[0] !== expectedPath || row[1] !== expectedRepository || row[2] !== expectedHead || row[3] !== expectedBase || row[4] !== (expectedPr === null ? '-' : String(expectedPr))) fail(`${label} row ${index + 1} identity mismatch`)
  })
}

function assertSourcePublicationRootOwnerConfig(config, label, verificationNow) {
  assertAllowedKeys(config, ['schemaVersion', 'status', 'repository', 'head', 'base', 'prNumber', 'lastReviewed', 'blocker'], label)
  if (config.schemaVersion !== 1) fail(`${label}.schemaVersion mismatch`)
  if (!['blocked', 'ready'].includes(config.status)) fail(`${label}.status must be blocked or ready`)
  const reviewedAt = parseUtcDate(config.lastReviewed, `${label}.lastReviewed`)
  assertNotFutureDate(reviewedAt, config.lastReviewed, `${label}.lastReviewed`, verificationNow, 5 * 60 * 1000)
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

function assertSourcePublicationHandoff(value, report, rootOwnerConfig, summary, artifactByPath, label) {
  const keys = ['sourceReportPath', 'reportArtifact', 'reportSha256', 'preflightReportPath', 'preflightReportArtifact', 'preflightReportSha256', 'configPath', 'configArtifact', 'configSha256', 'rootOwnerConfigPath', 'rootOwnerConfigArtifact', 'rootOwnerConfigSha256', 'rootOwnerStatus', 'status', 'checkRemote', 'sourceCount', 'passedCount', 'failedCount', 'workspaceOwned', 'repositories']
  assertAllowedKeys(value, keys, label)
  if (value.sourceReportPath !== 'source-publication-readiness-report.json') fail(`${label}.sourceReportPath mismatch`)
  if (value.reportArtifact !== sourcePublicationReportArtifactPath) fail(`${label}.reportArtifact mismatch`)
  if (value.preflightReportPath !== 'source-publication-preflight-report.json') fail(`${label}.preflightReportPath mismatch`)
  if (value.preflightReportArtifact !== sourcePublicationPreflightReportArtifactPath) fail(`${label}.preflightReportArtifact mismatch`)
  if (value.configPath !== sourcePublicationConfigPath || value.configArtifact !== sourcePublicationConfigArtifactPath) fail(`${label}.config identity mismatch`)
  if (value.rootOwnerConfigPath !== sourcePublicationRootOwnerConfigPath || value.rootOwnerConfigArtifact !== sourcePublicationRootOwnerConfigArtifactPath) fail(`${label}.root owner config identity mismatch`)
  const reportArtifact = artifactByPath.get(value.reportArtifact)
  const preflightReportArtifact = artifactByPath.get(value.preflightReportArtifact)
  const configArtifact = artifactByPath.get(value.configArtifact)
  const rootOwnerConfigArtifact = artifactByPath.get(value.rootOwnerConfigArtifact)
  if (!reportArtifact || !preflightReportArtifact || !configArtifact || !rootOwnerConfigArtifact) fail(`${label} artifacts missing`)
  if (value.reportSha256 !== reportArtifact.sha256 || value.configSha256 !== configArtifact.sha256) fail(`${label} checksum mismatch`)
  if (value.preflightReportSha256 !== preflightReportArtifact.sha256) fail(`${label} preflight report checksum mismatch`)
  if (value.preflightReportSha256 !== report.preflightReportSha256) fail(`${label} preflight report binding mismatch`)
  if (value.rootOwnerConfigSha256 !== rootOwnerConfigArtifact.sha256) fail(`${label} root owner config checksum mismatch`)
  if (value.rootOwnerStatus !== rootOwnerConfig.status) fail(`${label}.rootOwnerStatus mismatch`)
  if (value.status !== report.status || value.checkRemote !== report.checkRemote) fail(`${label} report status mismatch`)
  if (value.sourceCount !== report.totals.sources || value.passedCount !== report.totals.passed || value.failedCount !== report.totals.failed) fail(`${label} source totals mismatch`)
  requireBoolean(value.workspaceOwned, `${label}.workspaceOwned`)
  if (value.workspaceOwned !== (report.workspaceSource.status === 'passed')) fail(`${label}.workspaceOwned mismatch`)
  const summaryCheck = summary.checks.find((check) => check.slug === 'source-publication-readiness')
  if (!summaryCheck || summaryCheck.status !== value.status) fail(`${label}.status must match source publication summary check`)
  if (!Array.isArray(value.repositories) || value.repositories.length !== report.repositories.length) fail(`${label}.repositories length mismatch`)
  const repositoryKeys = ['path', 'repository', 'head', 'base', 'prNumber', 'status', 'branch', 'prHeadSha', 'headSha', 'remoteHeadSha', 'remoteBranchPresent', 'currentBranchRemoteSha', 'currentBranchRemotePresent', 'prUrl', 'prState', 'stagedCount', 'unstagedCount', 'untrackedCount', 'unmergedCount']
  value.repositories.forEach((row, index) => {
    assertAllowedKeys(row, repositoryKeys, `${label}.repositories[${index}]`)
    for (const key of repositoryKeys) {
      if (row[key] !== report.repositories[index][key]) fail(`${label}.repositories[${index}].${key} mismatch`)
    }
  })
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
  if (match) fail(`${label} contains secret-like token: ${match[0]}`)
}

function parseReleasePrConfigRows(configPath, label) {
  if (!fs.existsSync(configPath)) fail(`${label} missing: ${configPath}`)
  const stat = fs.lstatSync(configPath)
  if (!stat.isFile()) fail(`${label} must be a regular file: ${configPath}`)
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

function renderVerifyScript(blockers, workspaceRoot) {
  const lines = [
    '#!/usr/bin/env bash',
    'set -euo pipefail',
    '',
    `WORKSPACE_ROOT=\${RELEASE_UNBLOCK_WORKSPACE_ROOT:-${shellQuote(workspaceRoot)}}`,
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
    for (const blocker of blockers) lines.push(`  - ${blocker.slug}`)
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

function renderUnblockMarkdown(manifest, bundleDir) {
  const lines = [
    '# Release Unblock Bundle',
    '',
    `- Generated at: ${manifest.generatedAt}`,
    `- Source report dir: \`${manifest.sourceReportDir}\``,
    `- Status: \`${manifest.status}\``,
    `- Totals: ${manifest.totals.passed} passed, ${manifest.totals.failed} failed, ${manifest.totals.skipped} skipped, ${manifest.totals.total} total`,
    '',
    '## Quick Verification',
    '',
    'Verify bundle integrity and freshness from the workspace root:',
    '',
    '```bash',
    `bash scripts/verify-release-unblock-bundle.sh --bundle ${shellQuote(bundleDir)} --max-age-hours 24`,
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

  if (manifest.sourcePublicationHandoff) {
    lines.push(
      '## Source Publication Attestation',
      '',
      `- Status: \`${manifest.sourcePublicationHandoff.status}\``,
      `- Root owner policy: \`${manifest.sourcePublicationHandoff.rootOwnerStatus}\``,
      `- Workspace source owned and published: \`${manifest.sourcePublicationHandoff.workspaceOwned}\``,
      `- Sources: ${manifest.sourcePublicationHandoff.passedCount} passed, ${manifest.sourcePublicationHandoff.failedCount} failed, ${manifest.sourcePublicationHandoff.sourceCount} total`,
      `- Preflight report artifact: \`${manifest.sourcePublicationHandoff.preflightReportArtifact}\``,
      `- Report artifact: \`${manifest.sourcePublicationHandoff.reportArtifact}\``,
      `- Config artifact: \`${manifest.sourcePublicationHandoff.configArtifact}\``,
      `- Root owner config artifact: \`${manifest.sourcePublicationHandoff.rootOwnerConfigArtifact}\``,
      '',
    )
  }

  if (manifest.blockers.length === 0) {
    lines.push(
      manifest.status === 'incomplete'
        ? 'No failed checks were present, but required live checks were skipped; this bundle is incomplete and is not production-ready evidence.'
        : 'No release blockers were present in `actions.json`.',
      '',
    )
  } else {
    for (const blocker of manifest.blockers) {
      lines.push(`## ${blocker.name}`)
      lines.push('')
      lines.push(`- Slug: \`${blocker.slug}\``)
      lines.push(`- Requires external action: \`${blocker.requiresExternalAction}\``)
      lines.push(`- Unblock category: \`${blocker.unblockCategory}\``)
      lines.push(`- External prerequisite: ${blocker.externalPrerequisite}`)
      lines.push(`- Log: \`${blocker.logArtifact}\``)
      lines.push(`- Log SHA-256: \`${blocker.logSha256}\``)
      lines.push('')
      lines.push('Recommended action:')
      lines.push('')
      lines.push(blocker.recommendedAction)
      lines.push('')
      lines.push('Verification command:')
      lines.push('')
      lines.push('```bash')
      lines.push(blocker.verificationCommand)
      lines.push('```')
      lines.push('')
      if (blocker.evidenceTemplateCommands) {
        lines.push('Evidence template commands:')
        lines.push('')
        lines.push('```bash')
        for (const command of blocker.evidenceTemplateCommands) lines.push(command)
        lines.push('```')
        lines.push('')
      }
      if (blocker.evidenceTemplateHandoff) {
        lines.push('Required evidence contracts:')
        lines.push('')
        for (const contract of blocker.evidenceTemplateHandoff.requiredEvidenceContracts) {
          lines.push(`- \`${contract}\``)
        }
        lines.push('')
      }
      if (blocker.evidenceTemplateHandoff) {
        lines.push('Evidence template handoff:')
        lines.push('')
        lines.push(`- Output path: \`${blocker.evidenceTemplateHandoff.outputPath}\``)
        lines.push(`- Destination manifest: \`${blocker.evidenceTemplateHandoff.destinationManifest}\``)
        lines.push('- Ready audit command:')
        lines.push('')
        lines.push('```bash')
        lines.push(blocker.evidenceTemplateHandoff.readyAuditCommand)
        lines.push('```')
        lines.push('')
      }
      if (blocker.bitcoinBroadcastTemplateHandoff) {
        lines.push('Bitcoin broadcast template handoff:')
        lines.push('')
        lines.push(`- Template artifact: \`${blocker.bitcoinBroadcastTemplateHandoff.templateArtifact}\``)
        lines.push(`- Template SHA-256: \`${blocker.bitcoinBroadcastTemplateHandoff.templateSha256}\``)
        lines.push(`- Source report path: \`${blocker.bitcoinBroadcastTemplateHandoff.sourceReportPath}\``)
        lines.push(`- Generated template path: \`${blocker.bitcoinBroadcastTemplateHandoff.generatedTemplatePath}\``)
        lines.push(`- Destination manifest: \`${blocker.bitcoinBroadcastTemplateHandoff.destinationManifest}\``)
        lines.push(`- Default indexer URL: \`${blocker.bitcoinBroadcastTemplateHandoff.defaultIndexerUrl}\``)
        lines.push('')
        lines.push('Template required fields:')
        lines.push('')
        for (const field of blocker.bitcoinBroadcastTemplateHandoff.requiredEvidenceFields) {
          lines.push(`- \`${field}\``)
        }
        lines.push('')
        lines.push('Template placeholders:')
        lines.push('')
        for (const [field, placeholder] of Object.entries(blocker.bitcoinBroadcastTemplateHandoff.placeholderRecord)) {
          lines.push(`- \`${field}=${placeholder}\``)
        }
        lines.push('')
        lines.push('Template contracts:')
        lines.push('')
        for (const contract of blocker.bitcoinBroadcastTemplateHandoff.requiredContracts) {
          lines.push(`- \`${contract}\``)
        }
        lines.push('')
        lines.push('Bitcoin evidence ready-audit command:')
        lines.push('')
        lines.push('```bash')
        lines.push(blocker.bitcoinBroadcastTemplateHandoff.readyAuditCommand)
        lines.push('```')
        lines.push('')
      }
      if (blocker.passkeyDeploymentTemplateHandoff) {
        lines.push('Passkey deployment template handoff:')
        lines.push('')
        lines.push(`- Template artifact: \`${blocker.passkeyDeploymentTemplateHandoff.templateArtifact}\``)
        lines.push(`- Template SHA-256: \`${blocker.passkeyDeploymentTemplateHandoff.templateSha256}\``)
        lines.push(`- Source report path: \`${blocker.passkeyDeploymentTemplateHandoff.sourceReportPath}\``)
        lines.push(`- Generated template path: \`${blocker.passkeyDeploymentTemplateHandoff.generatedTemplatePath}\``)
        lines.push(`- Destination manifest: \`${blocker.passkeyDeploymentTemplateHandoff.destinationManifest}\``)
        lines.push(`- Service: \`${blocker.passkeyDeploymentTemplateHandoff.service}\``)
        lines.push(`- Base URL: \`${blocker.passkeyDeploymentTemplateHandoff.baseUrl}\``)
        lines.push(`- Health URL: \`${blocker.passkeyDeploymentTemplateHandoff.healthUrl}\``)
        lines.push(`- Credential store file: \`${blocker.passkeyDeploymentTemplateHandoff.credentialStoreFile}\``)
        lines.push('')
        lines.push('Required evidence fields:')
        lines.push('')
        for (const field of blocker.passkeyDeploymentTemplateHandoff.requiredEvidenceFields) {
          lines.push(`- \`${field}\``)
        }
        lines.push('')
        lines.push('Template placeholders:')
        lines.push('')
        for (const [field, placeholder] of Object.entries(blocker.passkeyDeploymentTemplateHandoff.placeholderRecord)) {
          lines.push(`- \`${field}=${placeholder}\``)
        }
        lines.push('')
        lines.push('Health response target:')
        lines.push('')
        for (const [field, value] of Object.entries(blocker.passkeyDeploymentTemplateHandoff.healthResponseTarget)) {
          lines.push(`- \`${field}=${value}\``)
        }
        lines.push('')
        lines.push('Live health attestation target:')
        lines.push('')
        for (const [field, value] of Object.entries(blocker.passkeyDeploymentTemplateHandoff.liveHealthAttestationTarget)) {
          lines.push(`- \`${field}=${value}\``)
        }
        lines.push('')
        lines.push('WebAuthn origin targets:')
        lines.push('')
        for (const origin of blocker.passkeyDeploymentTemplateHandoff.webauthnAllowedOriginsTarget) {
          lines.push(`- \`${origin}\``)
        }
        lines.push('')
        lines.push('Request access policy target:')
        lines.push('')
        for (const [field, value] of Object.entries(blocker.passkeyDeploymentTemplateHandoff.requestAccessPolicyTarget)) {
          lines.push(`- \`${field}=${value}\``)
        }
        lines.push('')
        lines.push('Trusted proxy policy target:')
        lines.push('')
        for (const [field, value] of Object.entries(blocker.passkeyDeploymentTemplateHandoff.trustedProxyPolicyTarget)) {
          lines.push(`- \`${field}=${value}\``)
        }
        lines.push('')
        lines.push('Platform provisioning target:')
        lines.push('')
        for (const [field, value] of Object.entries(blocker.passkeyDeploymentTemplateHandoff.platformProvisioningTarget)) {
          lines.push(`- \`${field}=${value}\``)
        }
        lines.push('')
        lines.push('Platform provisioning attestation target:')
        lines.push('')
        for (const [field, value] of Object.entries(blocker.passkeyDeploymentTemplateHandoff.platformProvisioningAttestationTarget)) {
          lines.push(`- \`${field}=${value}\``)
        }
        lines.push('')
        lines.push('Template contracts:')
        lines.push('')
        for (const contract of blocker.passkeyDeploymentTemplateHandoff.requiredContracts) {
          lines.push(`- \`${contract}\``)
        }
        lines.push('')
        lines.push('Passkey evidence ready-audit command:')
        lines.push('')
        lines.push('```bash')
        lines.push(blocker.passkeyDeploymentTemplateHandoff.readyAuditCommand)
        lines.push('```')
        lines.push('')
      }
      if (blocker.passkeyProductionContractHandoff) {
        lines.push('Passkey production contract handoff:')
        lines.push('')
        lines.push(`- Production config artifact: \`${blocker.passkeyProductionContractHandoff.productionConfigArtifact}\``)
        lines.push(`- Production config SHA-256: \`${blocker.passkeyProductionContractHandoff.productionConfigSha256}\``)
        lines.push(`- Production config source: \`${blocker.passkeyProductionContractHandoff.productionConfigSourcePath}\``)
        lines.push(`- OpenAPI artifact: \`${blocker.passkeyProductionContractHandoff.openApiArtifact}\``)
        lines.push(`- OpenAPI SHA-256: \`${blocker.passkeyProductionContractHandoff.openApiSha256}\``)
        lines.push(`- OpenAPI source: \`${blocker.passkeyProductionContractHandoff.openApiSourcePath}\``)
        lines.push(`- Production Compose artifact: \`${blocker.passkeyProductionContractHandoff.composeArtifact}\``)
        lines.push(`- Production Compose SHA-256: \`${blocker.passkeyProductionContractHandoff.composeSha256}\``)
        lines.push(`- Production Compose source: \`${blocker.passkeyProductionContractHandoff.composeSourcePath}\``)
        lines.push(`- Service: \`${blocker.passkeyProductionContractHandoff.service}\``)
        lines.push(`- Base URL: \`${blocker.passkeyProductionContractHandoff.baseUrl}\``)
        lines.push(`- RP ID: \`${blocker.passkeyProductionContractHandoff.rpId}\``)
        lines.push(`- Schema version: \`${blocker.passkeyProductionContractHandoff.schemaVersion}\``)
        lines.push(`- Health path: \`${blocker.passkeyProductionContractHandoff.healthPath}\``)
        lines.push('- Android distribution signer evidence:')
        lines.push(`  - Fingerprint environment variable: \`${blocker.passkeyProductionContractHandoff.androidSignerEvidence.fingerprintEnvironmentVariable}\``)
        lines.push(`  - Source environment variable: \`${blocker.passkeyProductionContractHandoff.androidSignerEvidence.sourceEnvironmentVariable}\``)
        lines.push(`  - Allowed sources: \`${blocker.passkeyProductionContractHandoff.androidSignerEvidence.allowedSources.join(', ')}\``)
        lines.push(`  - Rejected evidence types: \`${blocker.passkeyProductionContractHandoff.androidSignerEvidence.rejectedEvidenceTypes.join(', ')}\``)
        lines.push(`  - Independently obtained: \`${blocker.passkeyProductionContractHandoff.androidSignerEvidence.independentlyObtained}\``)
        lines.push(`  - Requires assetlinks parity: \`${blocker.passkeyProductionContractHandoff.androidSignerEvidence.requiresAssetlinksParity}\``)
        lines.push(`  - Exact package name: \`${blocker.passkeyProductionContractHandoff.androidSignerEvidence.exactPackageName}\``)
        lines.push('  - Distributed APK evidence:')
        for (const [field, value] of Object.entries(blocker.passkeyProductionContractHandoff.androidSignerEvidence.distributedApk)) {
          lines.push(`    - \`${field}=${value}\``)
        }
        lines.push('  - Play app-signing certificate evidence:')
        for (const [field, value] of Object.entries(blocker.passkeyProductionContractHandoff.androidSignerEvidence.playAppSigningCertificate)) {
          lines.push(`    - \`${field}=${value}\``)
        }
        lines.push('- Required route paths:')
        for (const routePath of blocker.passkeyProductionContractHandoff.requiredRoutePaths) {
          lines.push(`  - \`${routePath}\``)
        }
        lines.push('')
        lines.push('Production contract requirements:')
        lines.push('')
        for (const contract of blocker.passkeyProductionContractHandoff.requiredContracts) {
          lines.push(`- \`${contract}\``)
        }
        lines.push('')
        lines.push('Production contract verification commands:')
        lines.push('')
        lines.push('```bash')
        for (const command of blocker.passkeyProductionContractHandoff.verificationCommands) {
          lines.push(command)
        }
        lines.push('```')
        lines.push('')
      }
      if (blocker.indexerDeploymentTemplateHandoff) {
        lines.push('Indexer deployment template handoff:')
        lines.push('')
        lines.push(`- Template artifact: \`${blocker.indexerDeploymentTemplateHandoff.templateArtifact}\``)
        lines.push(`- Template SHA-256: \`${blocker.indexerDeploymentTemplateHandoff.templateSha256}\``)
        lines.push(`- Source report path: \`${blocker.indexerDeploymentTemplateHandoff.sourceReportPath}\``)
        lines.push(`- Generated template path: \`${blocker.indexerDeploymentTemplateHandoff.generatedTemplatePath}\``)
        lines.push(`- Destination manifest: \`${blocker.indexerDeploymentTemplateHandoff.destinationManifest}\``)
        lines.push(`- Service ID: \`${blocker.indexerDeploymentTemplateHandoff.serviceId}\``)
        lines.push(`- Base URL: \`${blocker.indexerDeploymentTemplateHandoff.baseUrl}\``)
        lines.push(`- Template status: \`${blocker.indexerDeploymentTemplateHandoff.status}\``)
        lines.push(`- Template release enabled: \`${blocker.indexerDeploymentTemplateHandoff.releaseEnabled}\``)
        lines.push('')
        lines.push('Required evidence fields:')
        lines.push('')
        for (const field of blocker.indexerDeploymentTemplateHandoff.requiredEvidenceFields) {
          lines.push(`- \`${field}\``)
        }
        lines.push('')
        lines.push('Template placeholders:')
        lines.push('')
        for (const [field, placeholder] of Object.entries(blocker.indexerDeploymentTemplateHandoff.placeholderRecord)) {
          lines.push(`- \`${field}=${placeholder}\``)
        }
        if (blocker.indexerDeploymentTemplateHandoff.serviceInfoTarget) {
          lines.push('')
          lines.push('Service-info target:')
          lines.push('')
          for (const [field, value] of Object.entries(blocker.indexerDeploymentTemplateHandoff.serviceInfoTarget)) {
            lines.push(`- \`${field}=${typeof value === 'object' ? JSON.stringify(value) : value}\``)
          }
        }
        lines.push('')
        lines.push('Health-info target:')
        lines.push('')
        for (const [field, value] of Object.entries(blocker.indexerDeploymentTemplateHandoff.healthInfoTarget)) {
          lines.push(`- \`${field}=${typeof value === 'object' ? JSON.stringify(value) : value}\``)
        }
        if (blocker.indexerDeploymentTemplateHandoff.soraRpcControlsTarget) {
          lines.push('')
          lines.push('SORA RPC controls target:')
          lines.push('')
          for (const [field, value] of Object.entries(blocker.indexerDeploymentTemplateHandoff.soraRpcControlsTarget)) {
            lines.push(`- \`${field}=${typeof value === 'object' ? JSON.stringify(value) : value}\``)
          }
        }
        if (blocker.indexerDeploymentTemplateHandoff.tlsEdgeControlsTarget) {
          lines.push('')
          lines.push('TLS-edge controls target:')
          lines.push('')
          for (const [field, value] of Object.entries(blocker.indexerDeploymentTemplateHandoff.tlsEdgeControlsTarget)) {
            lines.push(`- \`${field}=${typeof value === 'object' ? JSON.stringify(value) : value}\``)
          }
        }
        lines.push('')
        lines.push('Template contracts:')
        lines.push('')
        for (const contract of blocker.indexerDeploymentTemplateHandoff.requiredContracts) {
          lines.push(`- \`${contract}\``)
        }
        lines.push('')
        lines.push('Indexer evidence ready-audit command:')
        lines.push('')
        lines.push('```bash')
        lines.push(blocker.indexerDeploymentTemplateHandoff.readyAuditCommand)
        lines.push('```')
        lines.push('')
      }
      if (blocker.nexusProductionEvidenceTemplateHandoff) {
        lines.push('Nexus production evidence template handoff:')
        lines.push('')
        lines.push(`- Template artifact: \`${blocker.nexusProductionEvidenceTemplateHandoff.templateArtifact}\``)
        lines.push(`- Template SHA-256: \`${blocker.nexusProductionEvidenceTemplateHandoff.templateSha256}\``)
        lines.push(`- Source report path: \`${blocker.nexusProductionEvidenceTemplateHandoff.sourceReportPath}\``)
        lines.push(`- Generated template path: \`${blocker.nexusProductionEvidenceTemplateHandoff.generatedTemplatePath}\``)
        lines.push(`- Destination manifest: \`${blocker.nexusProductionEvidenceTemplateHandoff.destinationManifest}\``)
        lines.push(`- Network: \`${blocker.nexusProductionEvidenceTemplateHandoff.network}\``)
        lines.push(`- Chain ID: \`${blocker.nexusProductionEvidenceTemplateHandoff.chainId}\``)
        lines.push(`- Torii base URL: \`${blocker.nexusProductionEvidenceTemplateHandoff.toriiBaseUrl}\``)
        lines.push(`- MCP URL: \`${blocker.nexusProductionEvidenceTemplateHandoff.mcpUrl}\``)
        lines.push(`- Health URL: \`${blocker.nexusProductionEvidenceTemplateHandoff.healthUrl}\``)
        lines.push(`- Template status: \`${blocker.nexusProductionEvidenceTemplateHandoff.status}\``)
        lines.push(`- Template release enabled: \`${blocker.nexusProductionEvidenceTemplateHandoff.releaseEnabled}\``)
        lines.push('')
        lines.push('Required evidence fields:')
        lines.push('')
        for (const field of blocker.nexusProductionEvidenceTemplateHandoff.requiredEvidenceFields) {
          lines.push(`- \`${field}\``)
        }
        lines.push('')
        lines.push('Route publication placeholders:')
        lines.push('')
        for (const [field, placeholder] of Object.entries(blocker.nexusProductionEvidenceTemplateHandoff.routePublicationPlaceholder)) {
          lines.push(`- \`${field}=${placeholder}\``)
        }
        lines.push('')
        lines.push('Route canary placeholders:')
        lines.push('')
        for (const [field, placeholder] of Object.entries(blocker.nexusProductionEvidenceTemplateHandoff.routeCanaryPlaceholder)) {
          lines.push(`- \`${field}=${placeholder}\``)
        }
        lines.push('')
        lines.push('Wallet smoke placeholders:')
        lines.push('')
        for (const [platform, placeholder] of Object.entries(blocker.nexusProductionEvidenceTemplateHandoff.walletSmokePlaceholders)) {
          lines.push(`- \`${platform}: walletCommit=${placeholder.walletCommit}; walletSmokeTransactionHash=${placeholder.walletSmokeTransactionHash}; sourceAccount=${placeholder.sourceAccount}; destinationAccount=${placeholder.destinationAccount}\``)
        }
        lines.push('')
        lines.push('Template contracts:')
        lines.push('')
        for (const contract of blocker.nexusProductionEvidenceTemplateHandoff.requiredContracts) {
          lines.push(`- \`${contract}\``)
        }
        lines.push('')
        lines.push('Nexus evidence ready-audit command:')
        lines.push('')
        lines.push('```bash')
        lines.push(blocker.nexusProductionEvidenceTemplateHandoff.readyAuditCommand)
        lines.push('```')
        lines.push('')
        lines.push('Strict release-readiness command:')
        lines.push('')
        lines.push('```bash')
        lines.push(blocker.nexusProductionEvidenceTemplateHandoff.strictReleaseReadinessCommand)
        lines.push('```')
        lines.push('')
      }
      if (blocker.liveServiceHandoff) {
        lines.push('Live service handoff:')
        lines.push('')
        lines.push(`- Service: \`${blocker.liveServiceHandoff.service}\``)
        lines.push(`- Base URL: \`${blocker.liveServiceHandoff.baseUrl}\``)
        lines.push(`- URL policy: protocols \`${blocker.liveServiceHandoff.urlPolicy.allowedProtocols.join(',')}\`, credentials \`${blocker.liveServiceHandoff.urlPolicy.credentials}\`, query \`${blocker.liveServiceHandoff.urlPolicy.query}\`, fragment \`${blocker.liveServiceHandoff.urlPolicy.fragment}\``)
        lines.push(`- Canonical input: ${blocker.liveServiceHandoff.urlPolicy.canonicalInput}`)
        lines.push(`- Health path: \`${blocker.liveServiceHandoff.healthPath}\``)
        if (blocker.liveServiceHandoff.routePaths) {
          lines.push('- Smoke route paths:')
          for (const routePath of blocker.liveServiceHandoff.routePaths) {
            lines.push(`  - \`${routePath}\``)
          }
        }
        if (blocker.liveServiceHandoff.serviceInfoPath) {
          lines.push(`- Service-info path: \`${blocker.liveServiceHandoff.serviceInfoPath}\``)
        }
        if (blocker.liveServiceHandoff.openApiPath) {
          lines.push(`- OpenAPI path: \`${blocker.liveServiceHandoff.openApiPath}\``)
        }
        lines.push('')
        lines.push('Expected live contracts:')
        lines.push('')
        for (const contract of blocker.liveServiceHandoff.expectedContracts) {
          lines.push(`- \`${contract}\``)
        }
        lines.push('')
        lines.push('Live verification command:')
        lines.push('')
        lines.push('```bash')
        lines.push(blocker.liveServiceHandoff.verificationCommand)
        lines.push('```')
        lines.push('')
      }
      if (blocker.xcmProductionEvidenceTemplateHandoff) {
        lines.push('Android XCM production evidence template handoff:')
        lines.push('')
        lines.push(`- Template artifact: \`${blocker.xcmProductionEvidenceTemplateHandoff.templateArtifact}\``)
        lines.push(`- Template SHA-256: \`${blocker.xcmProductionEvidenceTemplateHandoff.templateSha256}\``)
        lines.push(`- Source report path: \`${blocker.xcmProductionEvidenceTemplateHandoff.sourceReportPath}\``)
        lines.push(`- Generated template path: \`${blocker.xcmProductionEvidenceTemplateHandoff.generatedTemplatePath}\``)
        lines.push(`- Destination manifest: \`${blocker.xcmProductionEvidenceTemplateHandoff.destinationManifest}\``)
        lines.push(`- Required route file: \`${blocker.xcmProductionEvidenceTemplateHandoff.requiredRouteFile}\``)
        lines.push(`- Discovery-gap file: \`${blocker.xcmProductionEvidenceTemplateHandoff.discoveryGapFile}\``)
        lines.push(`- Required route count: \`${blocker.xcmProductionEvidenceTemplateHandoff.requiredRouteCount}\``)
        lines.push('')
        lines.push('Required evidence fields:')
        lines.push('')
        for (const field of blocker.xcmProductionEvidenceTemplateHandoff.requiredEvidenceFields) {
          lines.push(`- \`${field}\``)
        }
        lines.push('')
        lines.push('Placeholder values:')
        lines.push('')
        for (const [field, placeholder] of Object.entries(blocker.xcmProductionEvidenceTemplateHandoff.placeholderRecord)) {
          lines.push(`- \`${field}\`: \`${placeholder}\``)
        }
        lines.push('')
        lines.push('Template contracts:')
        lines.push('')
        for (const contract of blocker.xcmProductionEvidenceTemplateHandoff.requiredContracts) {
          lines.push(`- \`${contract}\``)
        }
        lines.push('')
        lines.push('Ready evidence audit command:')
        lines.push('')
        lines.push('```bash')
        lines.push(blocker.xcmProductionEvidenceTemplateHandoff.readyAuditCommand)
        lines.push('```')
        lines.push('')
      }
      if (blocker.xcmRegistryHandoff) {
        lines.push('Android XCM registry handoff:')
        lines.push('')
        lines.push(`- Gap report artifact: \`${blocker.xcmRegistryHandoff.gapReportArtifact}\``)
        lines.push(`- Gap report SHA-256: \`${blocker.xcmRegistryHandoff.gapReportSha256}\``)
        lines.push(`- Source report path: \`${blocker.xcmRegistryHandoff.sourceReportPath}\``)
        lines.push(`- Android report path: \`${blocker.xcmRegistryHandoff.generatedGapReportPath}\``)
        lines.push(`- Registry file: \`${blocker.xcmRegistryHandoff.registryFile}\``)
        lines.push(`- Required route file: \`${blocker.xcmRegistryHandoff.requiredRouteFile}\``)
        lines.push(`- Discovery-gap file: \`${blocker.xcmRegistryHandoff.discoveryGapFile}\``)
        lines.push(`- Remaining discovery-only destinations: \`${blocker.xcmRegistryHandoff.remainingDiscoveryOnlyDestinations}\``)
        lines.push(`- Remaining discovery-only route assets: \`${blocker.xcmRegistryHandoff.remainingDiscoveryOnlyRouteAssets}\``)
        lines.push(`- Missing executable destination records: \`${blocker.xcmRegistryHandoff.missingExecutableDestinationCount}\``)
        lines.push(`- Effective-registry artifact: \`${blocker.xcmRegistryHandoff.effectiveRegistry.reportArtifact}\``)
        lines.push(`- Effective-registry SHA-256: \`${blocker.xcmRegistryHandoff.effectiveRegistry.reportSha256}\``)
        lines.push(`- Effective-registry mode/status: \`${blocker.xcmRegistryHandoff.effectiveRegistry.mode}/${blocker.xcmRegistryHandoff.effectiveRegistry.status}\``)
        lines.push(`- Approved routes: \`${blocker.xcmRegistryHandoff.effectiveRegistry.counts.approved}\``)
        lines.push(`- Compatible approved candidates: \`${blocker.xcmRegistryHandoff.effectiveRegistry.counts.effective}\``)
        lines.push(`- Production executable routes: \`${blocker.xcmRegistryHandoff.effectiveRegistry.counts.productionExecutable}\``)
        lines.push(`- Missing approved candidates: \`${blocker.xcmRegistryHandoff.effectiveRegistry.counts.missing}\``)
        lines.push(`- Extra discovery-only routes: \`${blocker.xcmRegistryHandoff.effectiveRegistry.counts.extra}\``)
        if (blocker.xcmRegistryHandoff.effectiveRegistry.discoveryRegistry) {
          lines.push(`- Production discovery: \`${blocker.xcmRegistryHandoff.effectiveRegistry.discoveryRegistry.source}\` (\`${blocker.xcmRegistryHandoff.effectiveRegistry.discoveryRegistry.byteLength}\` bytes, SHA-256 \`${blocker.xcmRegistryHandoff.effectiveRegistry.discoveryRegistry.sha256}\`)`)
        }
        lines.push(`- Trust policy: authority \`${blocker.xcmRegistryHandoff.effectiveRegistry.policy.transactionAuthority}\`; meaning \`${blocker.xcmRegistryHandoff.effectiveRegistry.policy.effectiveRouteMeaning}\`; remote execution trusted \`${blocker.xcmRegistryHandoff.effectiveRegistry.policy.remoteExecutionTrusted}\`; production transfers enabled \`${blocker.xcmRegistryHandoff.effectiveRegistry.policy.productionTransfersEnabled}\`; unapproved discovery executable \`${blocker.xcmRegistryHandoff.effectiveRegistry.policy.unapprovedDiscoveryRoutesExecutable}\`; runtime role \`${blocker.xcmRegistryHandoff.effectiveRegistry.policy.runtimeDiscoveryRole}\`; runtime storage \`${blocker.xcmRegistryHandoff.effectiveRegistry.policy.runtimeDiscoveryStorage}\`; successful process sync required \`${blocker.xcmRegistryHandoff.effectiveRegistry.policy.runtimeDiscoveryRequiresSuccessfulProcessSync}\`; snapshot bound \`${blocker.xcmRegistryHandoff.effectiveRegistry.policy.runtimeDiscoverySnapshotBoundToReport}\`; freshness enforced \`${blocker.xcmRegistryHandoff.effectiveRegistry.policy.runtimeDiscoveryFreshnessEnforced}\``)
        lines.push('')
        lines.push('Effective-registry input identities:')
        lines.push('')
        for (const [name, identity] of Object.entries(blocker.xcmRegistryHandoff.effectiveRegistry.inputContentIdentities)) {
          lines.push(`- \`${name}\`: \`${identity.source}\` (\`${identity.byteLength}\` bytes, SHA-256 \`${identity.sha256}\`)`)
        }
        lines.push('')
        lines.push('Effective-registry audit command:')
        lines.push('')
        lines.push('```bash')
        lines.push(blocker.xcmRegistryHandoff.effectiveRegistry.auditCommand)
        lines.push('```')
        lines.push('')
        lines.push('Registry contracts:')
        lines.push('')
        for (const contract of blocker.xcmRegistryHandoff.requiredContracts) {
          lines.push(`- \`${contract}\``)
        }
        lines.push('')
        lines.push('Registry verification command:')
        lines.push('')
        lines.push('```bash')
        lines.push(blocker.xcmRegistryHandoff.registryAuditCommand)
        lines.push('```')
        lines.push('')
      }
      lines.push('Evidence preview:')
      lines.push('')
      pushFencedBlock(lines, 'text', blocker.evidencePreview)
      lines.push('')
      if (blocker.outdatedReviewThreadResolution) {
        lines.push('Outdated review-thread resolution dry run:')
        lines.push('')
        lines.push('```bash')
        lines.push(blocker.outdatedReviewThreadResolution.dryRunCommand)
        lines.push('```')
        lines.push('')
        lines.push('Eligible outdated review threads:')
        lines.push('')
        for (const thread of blocker.outdatedReviewThreadResolution.threads) {
          lines.push(`- ${thread.repo}#${thread.pr}: \`${thread.id}\`${thread.refs ? ` (${thread.refs})` : ''}`)
        }
        lines.push('')
        lines.push('Apply command after explicit authorization:')
        lines.push('')
        lines.push('```bash')
        lines.push(blocker.outdatedReviewThreadResolution.applyCommand)
        lines.push('```')
        lines.push('')
      }
      if (blocker.releasePrApprovalHandoff) {
        lines.push('Release PR approval handoff:')
        lines.push('')
        lines.push(`- Approval-only PR count: \`${blocker.releasePrApprovalHandoff.approvalCount}\``)
        lines.push('- PRs needing eligible reviewer approval:')
        lines.push('')
        for (const pr of blocker.releasePrApprovalHandoff.prs) {
          const details = [
            pr.requiredAction,
            `reviewDecision=${pr.reviewDecision}`,
            `mergeStateStatus=${pr.mergeStateStatus}`,
            ...releasePrApprovalDiagnosticParts(pr),
          ]
          lines.push(`- ${pr.repo}#${pr.pr}: ${pr.url} (${details.join('; ')})`)
        }
        lines.push('')
        lines.push('After approval, inspect merge candidates:')
        lines.push('')
        lines.push('```bash')
        lines.push(blocker.releasePrApprovalHandoff.dryRunCommand)
        lines.push('```')
        lines.push('')
      }
      if (blocker.releasePrStatusReportHandoff) {
        lines.push('Release PR status report handoff:')
        lines.push('')
        lines.push(`- Report artifact: \`${blocker.releasePrStatusReportHandoff.reportArtifact}\``)
        lines.push(`- Report SHA-256: \`${blocker.releasePrStatusReportHandoff.reportSha256}\``)
        lines.push(`- Source report path: \`${blocker.releasePrStatusReportHandoff.sourceReportPath}\``)
        lines.push(`- Config: \`${blocker.releasePrStatusReportHandoff.configPath}\``)
        lines.push(`- Status: \`${blocker.releasePrStatusReportHandoff.status}\``)
        lines.push(`- Required PR rows: \`${blocker.releasePrStatusReportHandoff.requiredPrCount}\``)
        lines.push(`- Failed PR rows: \`${blocker.releasePrStatusReportHandoff.failedCount}\``)
        if (blocker.releasePrStatusReportHandoff.blockedPrs.length > 0) {
          lines.push('Blocked PRs:')
          for (const pr of blocker.releasePrStatusReportHandoff.blockedPrs) {
            lines.push(`- \`${pr.repo}#${pr.pr}\` ${pr.head} -> ${pr.base} row ${pr.configLine}, requiredState=${pr.requiredState}, checks=${pr.requiredChecks.join(',')} (${pr.reviewDecision}, ${pr.mergeStateStatus}): ${pr.url}`)
          }
        }
        lines.push('Dry run:')
        lines.push('')
        lines.push('```bash')
        lines.push(blocker.releasePrStatusReportHandoff.dryRunCommand)
        lines.push('```')
        lines.push('')
      }
      if (blocker.releasePrMergeHandoff) {
      lines.push('Protected release PR merge handoff:')
      lines.push('')
      lines.push(`- Config: \`${blocker.releasePrMergeHandoff.configPath}\``)
      lines.push(`- Required PR rows: \`${blocker.releasePrMergeHandoff.requiredPrCount}\``)
      lines.push(`- Blocked PR rows: \`${blocker.releasePrMergeHandoff.blockedPrCount}\``)
      lines.push(`- Merge method: \`${blocker.releasePrMergeHandoff.mergeMethod}\``)
        lines.push('Dry run:')
        lines.push('')
        lines.push('```bash')
        lines.push(blocker.releasePrMergeHandoff.dryRunCommand)
        lines.push('```')
        lines.push('')
        lines.push('Apply command after approvals and resolved conversations:')
        lines.push('')
        lines.push('```bash')
        lines.push(blocker.releasePrMergeHandoff.applyCommand)
        lines.push('```')
        lines.push('')
        lines.push('Post-merge verification:')
        lines.push('')
        lines.push('```bash')
        lines.push(blocker.releasePrMergeHandoff.postMergeVerificationCommand)
        lines.push('```')
        lines.push('')
      }
    }
  }

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

function assertBlockerMetadataLineCounts(markdown, label, expectedCount, entries) {
  const lines = markdown.split('\n')
  for (const [name, prefix] of entries) {
    const count = lines.filter((line) => line.startsWith(prefix)).length
    if (count !== expectedCount) {
      fail(`${label} must contain exactly one ${name} line per blocker: ${count} != ${expectedCount}`)
    }
  }
}

function listFiles(dir) {
  if (!fs.existsSync(dir)) fail(`bundle directory missing: ${dir}`)
  return fs.readdirSync(dir, { withFileTypes: true }).flatMap((entry) => {
    const absolute = path.join(dir, entry.name)
    if (entry.isDirectory()) return listFiles(absolute)
    if (!entry.isFile()) fail(`unsupported bundle entry type: ${absolute}`)
    return [absolute]
  })
}

function listDirectories(dir) {
  if (!fs.existsSync(dir)) fail(`bundle directory missing: ${dir}`)
  return fs.readdirSync(dir, { withFileTypes: true }).flatMap((entry) => {
    const absolute = path.join(dir, entry.name)
    if (entry.isDirectory()) return [absolute, ...listDirectories(absolute)]
    if (!entry.isFile()) fail(`unsupported bundle entry type: ${absolute}`)
    return []
  })
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
  ['iroha-release-readiness', 'Iroha Taira/Nexus release prerequisites'],
  ['iroha-wallet-coverage', 'Iroha Taira/Nexus wallet coverage'],
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
  ['android-public-dependency-provenance', 'Restore fearless-utils-Android-production-20260922 to the pinned pristine commit with no source drift, then restore the Android public artifact boundary and handoff bundle. Rerun bash ./scripts/test-fearless-utils-derived-tree.sh, FEARLESS_UTILS_LIBRARY_ONLY=true FEARLESS_UTILS_PATH=../fearless-utils-Android-production-20260922 ./scripts/ensure-fearless-utils.sh, bash ./scripts/test-public-dependency-upstream-delta-export.sh, bash ./scripts/export-public-dependency-upstream-delta.sh --output build/reports/public-dependency-upstream-delta, and ./scripts/audit-public-artifacts.sh in fearless-Android-production-consolidated-20260731.'],
  ['ios-shared-features-delta', 'Upstream or vendor every carried iOS shared-features/native-crypto delta, remove post-resolution checkout mutation, review build/reports/shared-features-delta-report.json, and rerun bash scripts/deps/test-shared-features-delta-report.sh plus bash scripts/deps/audit-shared-features-delta-report.sh "$PWD" --write-report build/reports/shared-features-delta-report.json --require-ready in fearless-iOS-production-consolidated-20260731.'],
  ['passkey-challenge-service', 'Fix the passkey challenge-service implementation, Docker/deployment evidence, and adversarial tests, then rerun bash scripts/audit-passkey-challenge-service.sh.'],
  ['passkey-deployment-evidence', 'Record the passkey backup image digest, deployment ID, operator, healthResponse ok=true/service=fearless-passkey-backup/rpId=fearlesswallet.io/schemaVersion=1, durable credential store paths /data/passkey-backup and /data/passkey-backup/credentials.json, WebAuthn origin allowlist, fail-closed request-access policy, trusted-proxy policy, platform provisioning evidence, and successful smoke timestamp. Independently obtain the distribution signer SHA-256 fingerprint from a distribution-signed APK or the Play app-signing certificate, set PASSKEY_ANDROID_RELEASE_SIGNER_EVIDENCE_SOURCE=distributed-apk|play-app-signing-certificate to identify the source, and prove the derived origin matches assetlinks; AAB upload-key evidence is rejected and absence or mismatch keeps passkey flags disabled. Then rerun npm run audit:deployment-evidence -- --require-ready in services/passkey-backup-challenge-service and bash scripts/audit-passkey-android-origin-parity.sh --require-ready from the workspace root.'],
  ['passkey-backup-prerequisites', 'Deploy and route https://backup.fearlesswallet.io to services/passkey-backup-challenge-service with valid DNS/TLS and require live health response ok=true/service=fearless-passkey-backup/rpId=fearlesswallet.io/schemaVersion=1. Deploy https://fearlesswallet.io association files so the strict site verifier observes exact source parity, JSON content types, X-Content-Type-Options: nosniff, and no redirects. Keep Android/iOS passkey backup flags disabled until health, site associations, and platform provisioning pass, then rerun PASSKEY_BACKUP_LIVE_HEALTH=1 bash scripts/audit-passkey-backup-prerequisites.sh && node fearless-site-web-app-associations-20260726/scripts/verify-app-associations.mjs --root fearless-site-web-app-associations-20260726 --live-base-url https://fearlesswallet.io.'],
  ['passkey-production-smoke', 'Deploy and route https://backup.fearlesswallet.io to services/passkey-backup-challenge-service with valid DNS/TLS. Provision PASSKEY_BACKUP_SMOKE_GRANT_HELPER=/run/secrets/passkey-smoke-grant-helper as a readable executable that issues single-use bearer grants for the exact smoke requests, then run the passkey production smoke to verify health, all four ceremony routes, and credential list/revoke/revoke-all contracts without persisting a test credential or creating an owner record.'],
  ['iroha-release-readiness', 'Do not edit or publish from an unfinished external Iroha Git operation. Have its owner produce a stable reviewed source commit and restore the pinned Iroha JS SDK release artifact so package.json exports ./ivm-artifact and the packaged runtime/declaration surface passes the wallet artifact validator. Pin NEXUS_EXPECTED_BUILD_COMMIT in config/iroha-release-readiness.env to the exact deployed Iroha build. Restore https://minamoto.sora.org/status as a bounded, non-redirecting HTTP 200 application/json Torii/Nexus status response with fresh observed_at_ms and last_block_committed_at_ms, coherent block and queue counters, a matching non-placeholder build.git_commit_sha, the exact ordered SORA routing policy (default 0/0, governance 1/1, smartcontract::deploy 2/2), and an unsealed dataspace_catalog containing ready canonical 0/0, 1/1, and 2/2 targets; record Nexus route publication, canary, and wallet live transfer smoke evidence, keep Nexus release-gated until strict production evidence passes, then rerun bash scripts/audit-iroha-release-readiness.sh.'],
  ['iroha-wallet-coverage', 'Restore Android/iOS/web Iroha Taira/Nexus wallet coverage, fail-closed transfer tests, and each platform\'s explicit blocked production-send readiness contract; do not enable production send until reviewed codecs and key providers exist, then rerun bash scripts/audit-iroha-wallet-coverage.sh.'],
  ['android-xcm-production-evidence', 'Keep release ENABLE_PRODUCTION_XCM_TRANSFERS=false until the entire trust and evidence gate is ready. Obtain reviewed per-asset pallet/call, reserve-or-teleport, multilocation, beneficiary, weight, destination-fee, and any bridge execution semantics for every advertised Android XCM route; implement bridge or estimator support before approving those modes. The per-asset schema, loader, validator, registry, and engine representation is now implemented, and all 15 approved single-asset routes are migrated without semantic changes. The current 34 discovery-only destinations cover 59 route assets; 14 of those destinations cover 39 multi-asset routes, and every one remains disabled until its exact reviewed semantics exist. Expand the APK-owned approved_xcm_routes.tsv and scripts/xcm-required-routes.tsv in exact lockstep only after those route semantics are reviewed, and make the production discovery intersection contain every approved route. Then record one funded mainnet E2E transfer per required route in fearless-Android-production-consolidated-20260731/scripts/xcm-production-evidence.json, including 0x-prefixed 32-byte extrinsicHash, sender, recipient, positive amount, UTC timestamp, environment, operator, and androidCommit matching the release commit, plus finalized origin/destination block hashes and numbers, true origin finality/extrinsic success/destination event success, a positive destination balance delta, distinct public HTTPS proof URLs, verificationMethod=canonical-rpc-and-explorer, verifiedAt, and an independentVerifier distinct from operator. Regenerate the canonical live effective report and validate it with the ready evidence, then run the all-routes metadata gate before a separately reviewed release-flag change.'],
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
  ['ios-shared-features-delta', true],
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
  const hasCanonicalBranchSourceIdentity =
    report.schemaVersion === 3 &&
    report.phase === 'postflight' &&
    typeof report.preflightReportSha256 === 'string' &&
    /^[0-9a-f]{64}$/u.test(report.preflightReportSha256) &&
    iroha.repository === 'hyperledger-iroha/iroha' &&
    iroha.originRepository === 'hyperledger-iroha/iroha' &&
    iroha.head === 'optimizations' && iroha.base === 'optimizations' &&
    iroha.prNumber === null && iroha.prUrl === null &&
    iroha.prState === null && iroha.prHeadSha === null &&
    iroha.branch === 'optimizations' && iroha.upstream === 'origin/optimizations' &&
    canonicalSha(iroha.headSha) && iroha.upstreamSha === iroha.headSha &&
    iroha.remoteBranchPresent === true && iroha.currentBranchRemotePresent === true &&
    canonicalSha(iroha.remoteHeadSha) && iroha.currentBranchRemoteSha === iroha.remoteHeadSha
  const expectedBranchFailures = []
  const ignoredOutputsFailure = iroha.failures[0]
  if (typeof ignoredOutputsFailure === 'string' &&
      /^worktree contains ignored non-published paths \([1-9][0-9]*\): .+; remove or quarantine these ignored outputs outside the source tree before publication; do not force-add generated artifacts$/u.test(ignoredOutputsFailure)) {
    expectedBranchFailures.push(ignoredOutputsFailure)
  }
  if (iroha.headSha !== iroha.remoteHeadSha) {
    expectedBranchFailures.push(`local HEAD ${iroha.headSha} does not match authoritative remote head ${iroha.remoteHeadSha}`)
    expectedBranchFailures.push(`cached upstream ${iroha.upstream} at ${iroha.upstreamSha} does not match authoritative current branch ${iroha.branch} at ${iroha.currentBranchRemoteSha}`)
  }
  expectedBranchFailures.push('canonical branch exact-SHA review is blocked: optimizations requires a verifiable reviewed/protected policy')
  const preflightContinuityFailure = 'source publication preflight did not pass before release checks'
  if (iroha.failures.at(-1) === preflightContinuityFailure) expectedBranchFailures.push(preflightContinuityFailure)
  const hasCanonicalBranchReviewBlocker =
    hasCanonicalBranchSourceIdentity && counts.every((key) => iroha[key] === 0) &&
    JSON.stringify(iroha.failures) === JSON.stringify(expectedBranchFailures)
  return hasOperation || hasUnmergedIndex || hasCanonicalBranchReviewBlocker
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
  ['android-public-dependency-provenance', 'cd fearless-Android-production-consolidated-20260731 && bash ./scripts/test-fearless-utils-derived-tree.sh && FEARLESS_UTILS_PATH=../fearless-utils-Android-production-20260922 FEARLESS_UTILS_COMMIT=1c80a2bf3fa1f996cf1328873e09f282ee29b69e FEARLESS_UTILS_REPOSITORY=soramitsu/fearless-utils-Android FEARLESS_UTILS_LIBRARY_ONLY=true ./scripts/ensure-fearless-utils.sh && bash ./scripts/test-public-dependency-upstream-delta-export.sh && bash ./scripts/export-public-dependency-upstream-delta.sh --output build/reports/public-dependency-upstream-delta && ./scripts/audit-public-artifacts.sh --strict-provenance'],
  ['ios-shared-features-delta', 'cd fearless-iOS-production-consolidated-20260731 && bash scripts/deps/test-shared-features-delta-report.sh && bash scripts/deps/audit-shared-features-delta-report.sh "$PWD" --write-report build/reports/shared-features-delta-report.json --require-ready'],
  ['passkey-challenge-service', 'bash scripts/audit-passkey-challenge-service.sh'],
  ['passkey-deployment-evidence', 'cd services/passkey-backup-challenge-service && npm run audit:deployment-evidence -- --require-ready && cd ../.. && bash scripts/audit-passkey-android-origin-parity.sh --require-ready'],
  ['passkey-backup-prerequisites', 'PASSKEY_BACKUP_LIVE_HEALTH=1 bash scripts/audit-passkey-backup-prerequisites.sh && node fearless-site-web-app-associations-20260726/scripts/verify-app-associations.mjs --root fearless-site-web-app-associations-20260726 --live-base-url https://fearlesswallet.io'],
  ['passkey-production-smoke', 'cd services/passkey-backup-challenge-service && PASSKEY_BACKUP_BASE_URL=https://backup.fearlesswallet.io PASSKEY_BACKUP_SMOKE_GRANT_HELPER=/run/secrets/passkey-smoke-grant-helper PASSKEY_BACKUP_SMOKE_TIMEOUT_MS=10000 npm run smoke:production'],
  ['iroha-release-readiness', 'IROHA_NEXUS_REQUIRE_PRODUCTION_EVIDENCE=1 IROHA_NEXUS_LIVE_HEALTH=1 bash scripts/audit-iroha-release-readiness.sh'],
  ['iroha-wallet-coverage', 'bash scripts/audit-iroha-wallet-coverage.sh'],
  ['android-xcm-production-evidence', 'cd fearless-Android-production-consolidated-20260731 && bash scripts/audit-xcm-effective-registry.sh --discovery-url https://raw.githubusercontent.com/soramitsu/shared-features-utils/master/chains/v13/chains.json --require-all-approved --write-report build/reports/xcm-effective-registry-report.json && bash scripts/audit-xcm-production-evidence.sh --effective-registry-report build/reports/xcm-effective-registry-report.json --require-ready && bash scripts/audit-xcm-registry-metadata.sh --require-executable --require-all-routes-executable --require-route-file scripts/xcm-required-routes.tsv --require-gap-file scripts/xcm-discovery-only-routes.tsv'],
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

function assertSummaryChecks(summary, actionsBySlug, sourceReportDir) {
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
    requireString(check.logFile, `${check.slug}.summary.logFile`)
    const summaryLogFile = resolveSourceReportPath(check.logFile, `${check.slug}.summary.logFile`, sourceReportDir)
    if (check.status === 'failed') {
      requireSingleLine(check.recommendedAction, `${check.slug}.summary.recommendedAction`)
      requireSingleLine(check.verificationCommand, `${check.slug}.summary.verificationCommand`)
      const action = actionsBySlug.get(check.slug)
      if (!action) fail(`${check.slug} failed summary check missing from actions.json blockers`)
      const actionLogFile = resolveSourceReportPath(action.logFile, `${check.slug}.action.logFile`, sourceReportDir)
      if (summaryLogFile !== actionLogFile) fail(`${check.slug}.summary logFile must match actions.json logFile`)
      if (check.name !== action.name) fail(`${check.slug}.summary name must match actions.json blocker`)
      assertExpectedCheckName(check.slug, check.name, `${check.slug}.summary.name`)
      if (check.exitCode !== action.exitCode) fail(`${check.slug}.summary exitCode must match actions.json blocker`)
      for (const key of summaryUnblockKeys) {
        if (check[key] !== action[key]) fail(`${check.slug}.summary ${key} must match actions.json blocker`)
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
  if (failedCheckSlugs.size !== actionSlugs.length) fail('summary failed checks must match actions.json blockers')
  if (failedCheckOrder.join('\n') !== actionSlugs.join('\n')) fail('actions.json blockers must match failed summary check order')
  for (const slug of actionsBySlug.keys()) {
    if (!failedCheckSlugs.has(slug)) fail(`${slug} actions.json blocker missing from failed summary checks`)
  }
}

function parseChecksums() {
  const checksumsFile = assertRegularBundleFile('SHA256SUMS', 'SHA256SUMS')
  const content = fs.readFileSync(checksumsFile, 'utf8')
  assertNoSecretLike('SHA256SUMS', content)

  const entries = []
  const seen = new Set()
  for (const [index, rawLine] of content.split('\n').entries()) {
    if (rawLine === '') continue
    const match = rawLine.match(/^([a-f0-9]{64})  (.+)$/)
    if (!match) fail(`SHA256SUMS line ${index + 1} has invalid format`)
    const relativePath = normalizeRelativePath(match[2], `SHA256SUMS line ${index + 1} path`)
    if (relativePath === 'SHA256SUMS') fail('SHA256SUMS must not include itself')
    if (seen.has(relativePath)) fail(`duplicate checksum path: ${relativePath}`)
    seen.add(relativePath)
    entries.push({ sha256: match[1], path: relativePath })
  }
  if (entries.length === 0) fail('SHA256SUMS must contain at least one entry')
  return entries
}

function assertOutdatedReviewThreadResolution(value, label, blockerSlug) {
  assertAllowedKeys(value, ['threadCount', 'dryRunCommand', 'applyCommand', 'threads'], label)
  requireNumber(value.threadCount, `${label}.threadCount`)
  if (value.threadCount <= 0) fail(`${label}.threadCount must be positive`)
  requireString(value.dryRunCommand, `${label}.dryRunCommand`)
  requireString(value.applyCommand, `${label}.applyCommand`)
  const expectedDryRun = 'bash scripts/resolve-release-pr-review-threads.sh --dry-run --audit-log build/reports/release-readiness/release-pr-readiness.log'
  const expectedApply = 'RELEASE_PR_THREAD_RESOLUTION_CONFIRM=resolve-outdated-review-threads bash scripts/resolve-release-pr-review-threads.sh --apply --audit-log build/reports/release-readiness/release-pr-readiness.log'
  if (value.dryRunCommand !== expectedDryRun) fail(`${label}.dryRunCommand mismatch`)
  if (value.applyCommand !== expectedApply) fail(`${label}.applyCommand mismatch`)
  if (blockerSlug !== 'release-pr-readiness') fail(`${label} is only supported on release-pr-readiness`)
  if (!Array.isArray(value.threads)) fail(`${label}.threads must be an array`)
  if (value.threads.length !== value.threadCount) fail(`${label}.threads length must match threadCount`)
  const seenIds = new Set()
  for (const [index, thread] of value.threads.entries()) {
    const threadLabel = `${label}.threads[${index}]`
    assertAllowedKeys(thread, ['repo', 'pr', 'id', 'refs'], threadLabel)
    requireString(thread.repo, `${threadLabel}.repo`)
    if (!/^[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+$/.test(thread.repo)) fail(`${threadLabel}.repo has unsupported format`)
    requireString(thread.pr, `${threadLabel}.pr`)
    if (!/^[1-9][0-9]*$/.test(thread.pr)) fail(`${threadLabel}.pr has unsupported format`)
    requireString(thread.id, `${threadLabel}.id`)
    if (!/^PRRT_[A-Za-z0-9_-]+$/.test(thread.id)) fail(`${threadLabel}.id has unsupported format`)
    if (seenIds.has(thread.id)) fail(`${label}.threads contains duplicate id: ${thread.id}`)
    seenIds.add(thread.id)
    if (typeof thread.refs !== 'string') fail(`${threadLabel}.refs must be a string`)
    for (const key of ['repo', 'pr', 'id', 'refs']) assertNoSecretLike(`${threadLabel}.${key}`, String(thread[key]))
  }
}

function assertReleasePrMergeHandoff(value, label, blockerSlug) {
  if (blockerSlug !== 'release-pr-readiness') fail(`${label} is only supported on release-pr-readiness`)
  assertAllowedKeys(value, ['configPath', 'requiredPrCount', 'blockedPrCount', 'mergeMethod', 'dryRunCommand', 'applyCommand', 'postMergeVerificationCommand'], label)
  const expected = {
    configPath: 'config/release-readiness-prs.tsv',
    mergeMethod: 'merge',
    dryRunCommand: 'bash scripts/merge-release-prs.sh --dry-run --config config/release-readiness-prs.tsv',
    applyCommand: 'RELEASE_PR_MERGE_CONFIRM=merge-release-prs bash scripts/merge-release-prs.sh --apply --config config/release-readiness-prs.tsv',
    postMergeVerificationCommand: 'bash scripts/audit-release-pr-readiness.sh',
  }
  for (const [key, expectedValue] of Object.entries(expected)) {
    requireSingleLine(value[key], `${label}.${key}`)
    assertNoSecretLike(`${label}.${key}`, value[key])
    if (value[key] !== expectedValue) fail(`${label}.${key} mismatch`)
  }
  requireNumber(value.requiredPrCount, `${label}.requiredPrCount`)
  requireNumber(value.blockedPrCount, `${label}.blockedPrCount`)
  const report = readJson(releasePrStatusReportArtifactPath, `${label}.statusReportArtifact`)
  assertReleasePrStatusReport(report, releasePrStatusReportArtifactPath)
  if (value.requiredPrCount !== report.totals.total) fail(`${label}.requiredPrCount must match status report`)
  if (value.blockedPrCount !== releasePrBlockedRequirementCount(report)) fail(`${label}.blockedPrCount must match status report blocked PR count`)
}

function releasePrBlockedRequirementCount(report) {
  return report.requirements.filter((requirement) => requirement.status === 'failed' && requirement.pr).length
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

function assertReleasePrApprovalHandoff(value, label, blockerSlug) {
  if (blockerSlug !== 'release-pr-readiness') fail(`${label} is only supported on release-pr-readiness`)
  assertAllowedKeys(value, ['approvalCount', 'dryRunCommand', 'prs'], label)
  requireNumber(value.approvalCount, `${label}.approvalCount`)
  if (value.approvalCount <= 0) fail(`${label}.approvalCount must be positive`)
  const expectedDryRun = 'bash scripts/merge-release-prs.sh --dry-run --config config/release-readiness-prs.tsv'
  requireSingleLine(value.dryRunCommand, `${label}.dryRunCommand`)
  assertNoSecretLike(`${label}.dryRunCommand`, value.dryRunCommand)
  if (value.dryRunCommand !== expectedDryRun) fail(`${label}.dryRunCommand mismatch`)
  if (!Array.isArray(value.prs)) fail(`${label}.prs must be an array`)
  if (value.prs.length !== value.approvalCount) fail(`${label}.prs length must match approvalCount`)

  const seen = new Set()
  for (const [index, pr] of value.prs.entries()) {
    const prLabel = `${label}.prs[${index}]`
    assertAllowedKeys(pr, [
      'repo',
      'pr',
      'url',
      'reviewDecision',
      'mergeStateStatus',
      'requiredAction',
      'eligibleReviewerApprovalRequired',
      'reviewDetails',
      'approvalCount',
      'currentHeadApprovalCount',
      'staleApprovalCount',
      'latestApprovalCommit',
      'currentApprovalNotEligible',
      'freshApprovalRequired',
    ], prLabel)
    requireSingleLine(pr.repo, `${prLabel}.repo`)
    if (!/^[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+$/.test(pr.repo)) fail(`${prLabel}.repo has unsupported format`)
    requireSingleLine(pr.pr, `${prLabel}.pr`)
    if (!/^[1-9][0-9]*$/.test(pr.pr)) fail(`${prLabel}.pr has unsupported format`)
    requireSingleLine(pr.url, `${prLabel}.url`)
    if (pr.url !== `https://github.com/${pr.repo}/pull/${pr.pr}`) fail(`${prLabel}.url mismatch`)
    requireSingleLine(pr.reviewDecision, `${prLabel}.reviewDecision`)
    if (!['REVIEW_REQUIRED', 'UNKNOWN'].includes(pr.reviewDecision)) {
      fail(`${prLabel}.reviewDecision must be REVIEW_REQUIRED or UNKNOWN`)
    }
    requireSingleLine(pr.mergeStateStatus, `${prLabel}.mergeStateStatus`)
    requireSingleLine(pr.requiredAction, `${prLabel}.requiredAction`)
    requireBoolean(pr.eligibleReviewerApprovalRequired, `${prLabel}.eligibleReviewerApprovalRequired`)
    if (pr.eligibleReviewerApprovalRequired !== true) fail(`${prLabel}.eligibleReviewerApprovalRequired must be true`)
    if (pr.reviewDetails !== undefined) {
      requireSingleLine(pr.reviewDetails, `${prLabel}.reviewDetails`)
      if (!['unavailable', 'malformed'].includes(pr.reviewDetails)) fail(`${prLabel}.reviewDetails must be unavailable or malformed`)
      if (pr.requiredAction !== 'restore review details for eligible reviewer approval') {
        fail(`${prLabel}.requiredAction must be restore review details for eligible reviewer approval`)
      }
      for (const countField of ['approvalCount', 'currentHeadApprovalCount', 'staleApprovalCount']) {
        if (pr[countField] !== undefined) fail(`${prLabel}.${countField} must be omitted when reviewDetails is ${pr.reviewDetails}`)
      }
      for (const stateField of ['latestApprovalCommit', 'currentApprovalNotEligible', 'freshApprovalRequired']) {
        if (pr[stateField] !== undefined) fail(`${prLabel}.${stateField} must be omitted when reviewDetails is ${pr.reviewDetails}`)
      }
      const key = `${pr.repo}#${pr.pr}`
      if (seen.has(key)) fail(`${label}.prs contains duplicate PR: ${key}`)
      seen.add(key)
      for (const field of ['repo', 'pr', 'url', 'reviewDecision', 'mergeStateStatus', 'requiredAction', 'reviewDetails']) {
        assertNoSecretLike(`${prLabel}.${field}`, pr[field])
      }
      continue
    }
    if (pr.requiredAction !== 'eligible reviewer approval') fail(`${prLabel}.requiredAction must be eligible reviewer approval`)
    requireNumber(pr.approvalCount, `${prLabel}.approvalCount`)
    requireNumber(pr.currentHeadApprovalCount, `${prLabel}.currentHeadApprovalCount`)
    requireNumber(pr.staleApprovalCount, `${prLabel}.staleApprovalCount`)
    if (pr.currentHeadApprovalCount > pr.approvalCount) fail(`${prLabel}.currentHeadApprovalCount must not exceed approvalCount`)
    if (pr.staleApprovalCount > pr.approvalCount) fail(`${prLabel}.staleApprovalCount must not exceed approvalCount`)
    requireBoolean(pr.currentApprovalNotEligible, `${prLabel}.currentApprovalNotEligible`)
    requireBoolean(pr.freshApprovalRequired, `${prLabel}.freshApprovalRequired`)
    if (pr.currentApprovalNotEligible && pr.freshApprovalRequired) fail(`${prLabel}.currentApprovalNotEligible and freshApprovalRequired cannot both be true`)
    if (pr.currentApprovalNotEligible && pr.currentHeadApprovalCount === 0) fail(`${prLabel}.currentApprovalNotEligible requires currentHeadApprovalCount`)
    if (pr.freshApprovalRequired && pr.approvalCount === 0) fail(`${prLabel}.freshApprovalRequired requires approvalCount`)
    if (pr.freshApprovalRequired && pr.currentHeadApprovalCount !== 0) fail(`${prLabel}.freshApprovalRequired requires currentHeadApprovalCount=0`)
    if (pr.approvalCount > 0 && pr.currentHeadApprovalCount > 0 && !pr.currentApprovalNotEligible) {
      fail(`${prLabel}.currentApprovalNotEligible must be true when current-head approvals are present`)
    }
    if (pr.approvalCount > 0 && pr.currentHeadApprovalCount === 0 && !pr.freshApprovalRequired) {
      fail(`${prLabel}.freshApprovalRequired must be true when only stale approvals are present`)
    }
    if (pr.latestApprovalCommit !== undefined) {
      requireSingleLine(pr.latestApprovalCommit, `${prLabel}.latestApprovalCommit`)
      if (!/^[0-9a-f]{40}$/i.test(pr.latestApprovalCommit)) fail(`${prLabel}.latestApprovalCommit must be a 40-character hex commit`)
    }
    const key = `${pr.repo}#${pr.pr}`
    if (seen.has(key)) fail(`${label}.prs contains duplicate PR: ${key}`)
    seen.add(key)
    for (const field of ['repo', 'pr', 'url', 'reviewDecision', 'mergeStateStatus', 'requiredAction', 'latestApprovalCommit']) {
      if (pr[field] === undefined) continue
      assertNoSecretLike(`${prLabel}.${field}`, pr[field])
    }
  }
  const report = readJson(releasePrStatusReportArtifactPath, `${label}.statusReportArtifact`)
  assertReleasePrStatusReport(report, releasePrStatusReportArtifactPath)
  assertReleasePrApprovalHandoffMatchesStatusReport(value, report, label)
}

function assertReleasePrStatusReport(report, label) {
  assertAllowedKeys(report, ['schemaVersion', 'generatedAt', 'configFile', 'status', 'checkedCount', 'totals', 'failures', 'requirements'], label)
  if (report.schemaVersion !== 1) fail(`${label}.schemaVersion must be 1`)
  const reportGeneratedAtMs = parseUtcTimestamp(report.generatedAt, `${label}.generatedAt`)
  assertNotFutureTimestamp(reportGeneratedAtMs, report.generatedAt, `${label}.generatedAt`, nowMs, futureSkewMs)
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
    ], requirementLabel)
    if (requirement.status !== 'passed' && requirement.status !== 'failed') fail(`${requirementLabel}.status unsupported`)
    if (requirement.configLine !== null) requireNumber(requirement.configLine, `${requirementLabel}.configLine`)
    if (requirement.configLine !== null && requirement.configLine <= previousConfigLine) {
      fail(`${requirementLabel}.configLine must match ${releasePrConfigPath} order`)
    }
    if (requirement.configLine !== null) previousConfigLine = requirement.configLine
    for (const key of ['repo', 'head', 'base', 'requiredState', 'message']) {
      requireSingleLine(requirement[key], `${requirementLabel}.${key}`)
      assertNoSecretLike(`${requirementLabel}.${key}`, requirement[key])
    }
    const failureMessagePattern = /(is open and is not release-ready|closed without merge|no merged pull request found|has new commits after merge|required checks are not release-ready|no release PR requirements were found)/
    const successMessagePattern = /is merged with required checks/
    if (requirement.status === 'passed' && failureMessagePattern.test(requirement.message)) {
      fail(`${requirementLabel}.message contradicts passed status`)
    }
    if (requirement.status === 'failed' && successMessagePattern.test(requirement.message)) {
      fail(`${requirementLabel}.message contradicts failed status`)
    }
    const reviewDecisionDiagnostic = requirement.message.match(/reviewDecision=([^\s]+)/)
    if (reviewDecisionDiagnostic && requirement.reviewDecision !== reviewDecisionDiagnostic[1]) {
      fail(`${requirementLabel}.reviewDecision must match message diagnostic`)
    }
    const mergeStateStatusDiagnostic = requirement.message.match(/mergeStateStatus=([^\s]+)/)
    if (mergeStateStatusDiagnostic && requirement.mergeStateStatus !== mergeStateStatusDiagnostic[1]) {
      fail(`${requirementLabel}.mergeStateStatus must match message diagnostic`)
    }
    for (const booleanDiagnosticField of ['isDraft', 'eligibleReviewerApprovalRequired', 'currentApprovalNotEligible', 'freshApprovalRequired']) {
      const booleanDiagnostic = requirement.message.match(new RegExp(`${booleanDiagnosticField}=([^\\s]+)`))
      if (booleanDiagnostic && requirement[booleanDiagnosticField] !== (booleanDiagnostic[1] === 'true')) {
        fail(`${requirementLabel}.${booleanDiagnosticField} must match message diagnostic`)
      }
    }
    for (const countDiagnosticField of ['approvalCount', 'currentHeadApprovalCount', 'staleApprovalCount', 'unresolvedReviewThreads', 'currentUnresolvedReviewThreads', 'outdatedUnresolvedReviewThreads']) {
      const countDiagnostic = requirement.message.match(new RegExp(`${countDiagnosticField}=([^\\s]+)`))
      if (countDiagnostic && requirement[countDiagnosticField] !== Number(countDiagnostic[1])) {
        fail(`${requirementLabel}.${countDiagnosticField} must match message diagnostic`)
      }
    }
    if (!/^[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+$/.test(requirement.repo)) fail(`${requirementLabel}.repo has unsupported format`)
    if (!Array.isArray(requirement.requiredChecks) || requirement.requiredChecks.length === 0) fail(`${requirementLabel}.requiredChecks must be a non-empty array`)
    for (const [checkIndex, check] of requirement.requiredChecks.entries()) {
      requireSingleLine(check, `${requirementLabel}.requiredChecks[${checkIndex}]`)
    }
    assertReleasePrRequirementMatchesConfig(requirement, requirementLabel, releasePrConfigRows)
    const successRequiredChecksDiagnostic = requirement.message.match(/ is merged with required checks ([^:]+): /)
    if (successRequiredChecksDiagnostic) {
      const messageRequiredChecks = successRequiredChecksDiagnostic[1].split(',')
      if (
        messageRequiredChecks.length !== requirement.requiredChecks.length ||
        messageRequiredChecks.some((check, checkIndex) => check !== requirement.requiredChecks[checkIndex])
      ) {
        fail(`${requirementLabel}.requiredChecks must match success message`)
      }
    }
    const messageContainsPrReference = (
      /^[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+#[1-9][0-9]*\b/.test(requirement.message) ||
      /\bhttps:\/\/github\.com\/[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+\/pull\/[1-9][0-9]*(?:\s|$)/.test(requirement.message)
    )
    if (messageContainsPrReference && requirement.pr === undefined) {
      fail(`${requirementLabel}.pr required when message contains PR reference`)
    }
    if (requirement.pr !== undefined) {
      assertAllowedKeys(requirement.pr, ['repo', 'number', 'url'], `${requirementLabel}.pr`)
      if (requirement.pr.repo !== requirement.repo) fail(`${requirementLabel}.pr.repo must match requirement repo`)
      requireNumber(requirement.pr.number, `${requirementLabel}.pr.number`)
      if (requirement.pr.number <= 0) fail(`${requirementLabel}.pr.number must be positive`)
      requireSingleLine(requirement.pr.url, `${requirementLabel}.pr.url`)
      if (requirement.pr.url !== `https://github.com/${requirement.repo}/pull/${requirement.pr.number}`) fail(`${requirementLabel}.pr.url mismatch`)
      const expectedPrReference = `${requirement.repo}#${requirement.pr.number}`
      if (!requirement.message.startsWith(`${expectedPrReference} `)) fail(`${requirementLabel}.message must start with PR reference`)
      const prUrlTokenPattern = new RegExp(`(?:^|\\s)${escapeRegExp(requirement.pr.url)}(?:\\s|$)`)
      if (!prUrlTokenPattern.test(requirement.message)) fail(`${requirementLabel}.message must include PR URL`)
    }
    for (const key of ['isDraft', 'eligibleReviewerApprovalRequired', 'currentApprovalNotEligible', 'freshApprovalRequired']) {
      if (requirement[key] !== undefined) requireBoolean(requirement[key], `${requirementLabel}.${key}`)
    }
    if (requirement.reviewDetails !== undefined && !['unavailable', 'malformed'].includes(requirement.reviewDetails)) {
      fail(`${requirementLabel}.reviewDetails must be unavailable or malformed`)
    }
    if (requirement.reviewDetails !== undefined) {
      for (const staleField of ['approvalCount', 'currentHeadApprovalCount', 'staleApprovalCount', 'latestApprovalCommit', 'currentApprovalNotEligible', 'freshApprovalRequired']) {
        if (requirement[staleField] !== undefined) fail(`${requirementLabel}.${staleField} must be omitted when reviewDetails is ${requirement.reviewDetails}`)
      }
    }
    for (const key of ['approvalCount', 'currentHeadApprovalCount', 'staleApprovalCount', 'unresolvedReviewThreads', 'currentUnresolvedReviewThreads', 'outdatedUnresolvedReviewThreads']) {
      if (requirement[key] !== undefined) requireNumber(requirement[key], `${requirementLabel}.${key}`)
    }
    if (requirement.latestApprovalCommit !== undefined && !/^[0-9a-f]{40}$/i.test(requirement.latestApprovalCommit)) {
      fail(`${requirementLabel}.latestApprovalCommit must be a 40-character hex commit`)
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

function assertReleasePrStatusReportHandoff(value, label, blockerSlug, artifactByPath, logContent) {
  if (blockerSlug !== 'release-pr-readiness') fail(`${label} is only supported on release-pr-readiness`)
  assertAllowedKeys(value, ['sourceReportPath', 'reportArtifact', 'reportSha256', 'configPath', 'status', 'checkedCount', 'failedCount', 'requiredPrCount', 'blockedPrs', 'dryRunCommand'], label)
  requireSingleLine(value.sourceReportPath, `${label}.sourceReportPath`)
  requireSingleLine(value.reportArtifact, `${label}.reportArtifact`)
  if (value.reportArtifact !== releasePrStatusReportArtifactPath) fail(`${label}.reportArtifact mismatch`)
  requireSingleLine(value.reportSha256, `${label}.reportSha256`)
  if (!/^[a-f0-9]{64}$/.test(value.reportSha256)) fail(`${label}.reportSha256 must be lowercase SHA-256`)
  requireSingleLine(value.configPath, `${label}.configPath`)
  if (value.configPath !== releasePrConfigPath) fail(`${label}.configPath mismatch`)
  if (value.status !== 'failed' && value.status !== 'passed') fail(`${label}.status unsupported`)
  requireNumber(value.checkedCount, `${label}.checkedCount`)
  requireNumber(value.failedCount, `${label}.failedCount`)
  requireNumber(value.requiredPrCount, `${label}.requiredPrCount`)
  requireSingleLine(value.dryRunCommand, `${label}.dryRunCommand`)
  if (value.dryRunCommand !== 'bash scripts/merge-release-prs.sh --dry-run --config config/release-readiness-prs.tsv') {
    fail(`${label}.dryRunCommand mismatch`)
  }
  const artifact = artifactByPath.get(value.reportArtifact)
  if (!artifact) fail(`${label}.reportArtifact missing from manifest artifacts`)
  const sourceReportPath = assertInsideSourceReportDir(value.sourceReportPath, `${label}.sourceReportPath`, sourceReportDir)
  if (artifact.sourcePath !== sourceReportPath) fail(`${label}.sourceReportPath must match report artifact sourcePath`)
  if (artifact.sha256 !== value.reportSha256) fail(`${label}.reportSha256 does not match artifact checksum`)
  const report = readJson(value.reportArtifact, `${label}.reportArtifact`)
  assertReleasePrStatusReport(report, value.reportArtifact)
  assertReleasePrStatusReportFailuresMatchLog(report, logContent, value.reportArtifact)
  assertReleasePrStatusReportRequirementsMatchLog(report, logContent, value.reportArtifact)
  assertReleasePrStatusReportLogResultsMatchRequirements(report, logContent, value.reportArtifact)
  if (report.status !== value.status) fail(`${label}.status must match report status`)
  if (report.checkedCount !== value.checkedCount) fail(`${label}.checkedCount must match report`)
  if (report.totals.failed !== value.failedCount) fail(`${label}.failedCount must match report`)
  if (report.totals.total !== value.requiredPrCount) fail(`${label}.requiredPrCount must match report`)
  if (!Array.isArray(value.blockedPrs)) fail(`${label}.blockedPrs must be an array`)
  const reportBlocked = report.requirements
    .filter((requirement) => requirement.status === 'failed' && requirement.pr)
    .map((requirement) => ({
      key: `${requirement.pr.repo}#${requirement.pr.number}`,
      configLine: requirement.configLine,
      head: requirement.head,
      base: requirement.base,
      requiredState: requirement.requiredState,
      requiredChecks: requirement.requiredChecks,
      reviewDecision: requirement.reviewDecision || 'UNKNOWN',
      mergeStateStatus: requirement.mergeStateStatus || 'UNKNOWN',
    }))
  if (value.blockedPrs.length !== reportBlocked.length) fail(`${label}.blockedPrs length must match report failures`)
  const seen = new Set()
  for (const [index, pr] of value.blockedPrs.entries()) {
    const prLabel = `${label}.blockedPrs[${index}]`
    assertAllowedKeys(pr, ['repo', 'pr', 'url', 'configLine', 'head', 'base', 'requiredState', 'requiredChecks', 'reviewDecision', 'mergeStateStatus'], prLabel)
    requireSingleLine(pr.repo, `${prLabel}.repo`)
    requireSingleLine(pr.pr, `${prLabel}.pr`)
    if (!/^[1-9][0-9]*$/.test(pr.pr)) fail(`${prLabel}.pr has unsupported format`)
    requireSingleLine(pr.url, `${prLabel}.url`)
    if (pr.url !== `https://github.com/${pr.repo}/pull/${pr.pr}`) fail(`${prLabel}.url mismatch`)
    requireNumber(pr.configLine, `${prLabel}.configLine`)
    for (const field of ['head', 'base', 'requiredState']) {
      requireSingleLine(pr[field], `${prLabel}.${field}`)
    }
    if (!Array.isArray(pr.requiredChecks) || pr.requiredChecks.length === 0) {
      fail(`${prLabel}.requiredChecks must be a non-empty array`)
    }
    for (const [checkIndex, check] of pr.requiredChecks.entries()) {
      requireSingleLine(check, `${prLabel}.requiredChecks[${checkIndex}]`)
      assertNoSecretLike(`${prLabel}.requiredChecks[${checkIndex}]`, check)
    }
    requireSingleLine(pr.reviewDecision, `${prLabel}.reviewDecision`)
    requireSingleLine(pr.mergeStateStatus, `${prLabel}.mergeStateStatus`)
    const key = `${pr.repo}#${pr.pr}`
    if (reportBlocked[index]?.key !== key) fail(`${prLabel} must match report failure order`)
    const expected = reportBlocked.find((blocked) => blocked.key === key)
    if (!expected) fail(`${prLabel} missing from report failures`)
    if (pr.configLine !== expected.configLine) fail(`${prLabel}.configLine must match report`)
    if (pr.head !== expected.head) fail(`${prLabel}.head must match report`)
    if (pr.base !== expected.base) fail(`${prLabel}.base must match report`)
    if (pr.requiredState !== expected.requiredState) fail(`${prLabel}.requiredState must match report`)
    if (pr.requiredChecks.length !== expected.requiredChecks.length) fail(`${prLabel}.requiredChecks length must match report`)
    for (const [checkIndex, check] of pr.requiredChecks.entries()) {
      if (check !== expected.requiredChecks[checkIndex]) fail(`${prLabel}.requiredChecks[${checkIndex}] must match report`)
    }
    if (pr.reviewDecision !== expected.reviewDecision) fail(`${prLabel}.reviewDecision must match report`)
    if (pr.mergeStateStatus !== expected.mergeStateStatus) fail(`${prLabel}.mergeStateStatus must match report`)
    if (seen.has(key)) fail(`${label}.blockedPrs contains duplicate PR: ${key}`)
    seen.add(key)
    for (const field of ['repo', 'pr', 'url', 'head', 'base', 'requiredState', 'reviewDecision', 'mergeStateStatus']) {
      assertNoSecretLike(`${prLabel}.${field}`, pr[field])
    }
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
    verificationCommand: 'PASSKEY_BACKUP_LIVE_HEALTH=1 bash scripts/audit-passkey-backup-prerequisites.sh && node fearless-site-web-app-associations-20260726/scripts/verify-app-associations.mjs --root fearless-site-web-app-associations-20260726 --live-base-url https://fearlesswallet.io',
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

function expectedLiveServiceHandoff(slug) {
  const handoff = liveServiceHandoffBySlug[slug]
  if (!handoff) return null
  return {
    ...handoff,
    urlPolicy: cloneLiveServiceUrlPolicy(),
  }
}

function assertExactStringArray(value, expected, label) {
  if (!Array.isArray(value)) fail(`${label} must be an array`)
  if (value.length !== expected.length) fail(`${label} length mismatch`)
  for (const [index, actual] of value.entries()) {
    requireSingleLine(actual, `${label}[${index}]`)
    assertNoSecretLike(`${label}[${index}]`, actual)
    if (actual !== expected[index]) fail(`${label}[${index}] mismatch`)
  }
}

function assertLiveServiceHandoff(value, label, blockerSlug) {
  const expected = expectedLiveServiceHandoff(blockerSlug)
  if (!expected) fail(`${label} is not supported on ${blockerSlug}`)
  assertAllowedKeys(value, ['service', 'baseUrl', 'urlPolicy', 'healthPath', 'routePaths', 'serviceInfoPath', 'openApiPath', 'expectedContracts', 'verificationCommand'], label)
  const actualKeys = Object.keys(value).sort().join(',')
  const expectedKeys = Object.keys(expected).sort().join(',')
  if (actualKeys !== expectedKeys) fail(`${label} keys mismatch`)
  for (const [key, expectedValue] of Object.entries(expected)) {
    if (key === 'urlPolicy') {
      assertAllowedKeys(value[key], ['allowedProtocols', 'credentials', 'query', 'fragment', 'canonicalInput'], `${label}.urlPolicy`)
      assertExactStringArray(value[key].allowedProtocols, expectedValue.allowedProtocols, `${label}.urlPolicy.allowedProtocols`)
      for (const policyKey of ['credentials', 'query', 'fragment', 'canonicalInput']) {
        requireSingleLine(value[key][policyKey], `${label}.urlPolicy.${policyKey}`)
        assertNoSecretLike(`${label}.urlPolicy.${policyKey}`, value[key][policyKey])
        if (value[key][policyKey] !== expectedValue[policyKey]) fail(`${label}.urlPolicy.${policyKey} mismatch`)
      }
      continue
    }
    if (key === 'expectedContracts' || key === 'routePaths') {
      assertExactStringArray(value[key], expectedValue, `${label}.${key}`)
      continue
    }
    requireSingleLine(value[key], `${label}.${key}`)
    assertNoSecretLike(`${label}.${key}`, value[key])
    if (value[key] !== expectedValue) fail(`${label}.${key} mismatch`)
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
    'cd fearless-Android-production-consolidated-20260731 && bash scripts/test-xcm-production-evidence-template.sh',
    'cd fearless-Android-production-consolidated-20260731 && bash scripts/generate-xcm-production-evidence-template.sh --output build/reports/xcm-production-evidence-template.json',
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

function expectedEvidenceTemplateCommands(slug) {
  return evidenceTemplateCommandsBySlug[slug] || null
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
    selfTestCommand: 'cd fearless-Android-production-consolidated-20260731 && bash scripts/test-xcm-production-evidence-template.sh',
    generateCommand: 'cd fearless-Android-production-consolidated-20260731 && bash scripts/generate-xcm-production-evidence-template.sh --output build/reports/xcm-production-evidence-template.json',
    outputPath: 'fearless-Android-production-consolidated-20260731/build/reports/xcm-production-evidence-template.json',
    destinationManifest: 'fearless-Android-production-consolidated-20260731/scripts/xcm-production-evidence.json',
    readyAuditCommand: 'cd fearless-Android-production-consolidated-20260731 && bash scripts/audit-xcm-effective-registry.sh --discovery-url https://raw.githubusercontent.com/soramitsu/shared-features-utils/master/chains/v13/chains.json --require-all-approved --write-report build/reports/xcm-effective-registry-report.json && bash scripts/audit-xcm-production-evidence.sh --effective-registry-report build/reports/xcm-effective-registry-report.json --require-ready',
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

function expectedEvidenceTemplateHandoff(slug) {
  return evidenceTemplateHandoffBySlug[slug] || null
}

function assertEvidenceTemplateCommands(value, label, blockerSlug) {
  const expected = expectedEvidenceTemplateCommands(blockerSlug)
  if (!expected) fail(`${label} is not supported on ${blockerSlug}`)
  if (!Array.isArray(value)) fail(`${label} must be an array`)
  if (value.length !== expected.length) fail(`${label} length mismatch`)
  for (const [index, command] of value.entries()) {
    requireSingleLine(command, `${label}[${index}]`)
    assertNoSecretLike(`${label}[${index}]`, command)
    if (command !== expected[index]) fail(`${label}[${index}] mismatch`)
  }
}

function assertEvidenceTemplateHandoff(value, label, blockerSlug) {
  const expected = expectedEvidenceTemplateHandoff(blockerSlug)
  if (!expected) fail(`${label} is not supported on ${blockerSlug}`)
  assertAllowedKeys(value, ['selfTestCommand', 'generateCommand', 'outputPath', 'destinationManifest', 'readyAuditCommand', 'requiredEvidenceContracts'], label)
  for (const [key, expectedValue] of Object.entries(expected)) {
    if (key === 'requiredEvidenceContracts') {
      assertExactStringArray(value[key], expectedValue, `${label}.${key}`)
      continue
    }
    requireSingleLine(value[key], `${label}.${key}`)
    assertNoSecretLike(`${label}.${key}`, value[key])
    if (value[key] !== expectedValue) fail(`${label}.${key} mismatch`)
  }
  const expectedCommands = expectedEvidenceTemplateCommands(blockerSlug)
  if (!expectedCommands) fail(`${label} has no matching evidenceTemplateCommands for ${blockerSlug}`)
  if (value.selfTestCommand !== expectedCommands[0]) fail(`${label}.selfTestCommand must match evidenceTemplateCommands[0]`)
  if (value.generateCommand !== expectedCommands[1]) fail(`${label}.generateCommand must match evidenceTemplateCommands[1]`)
}

function deepClone(value) {
  return value === null || value === undefined ? value : JSON.parse(JSON.stringify(value))
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

const indexerDeploymentTemplateArtifacts = new Map(
  Object.entries(indexerDeploymentTemplateConfigs).map(([slug, config]) => [config.templateArtifact, { slug, config }])
)

function expectedIndexerDeploymentTemplateHandoff(slug) {
  const config = indexerDeploymentTemplateConfigs[slug]
  if (!config) return null
  return {
    sourceReportPath: config.sourceReportPath,
    templateArtifact: config.templateArtifact,
    generatedTemplatePath: config.generatedTemplatePath,
    destinationManifest: config.destinationManifest,
    serviceId: config.serviceId,
    baseUrl: config.baseUrl,
    status: config.status,
    releaseEnabled: config.releaseEnabled,
    requiredEvidenceFields: [...config.requiredEvidenceFields],
    placeholderRecord: deepClone(config.placeholderRecord),
    serviceInfoTarget: config.serviceInfoTarget ? deepClone(config.serviceInfoTarget) : null,
    healthInfoTarget: deepClone(config.healthInfoTarget),
    ...(config.soraRpcControlsTarget
      ? { soraRpcControlsTarget: deepClone(config.soraRpcControlsTarget) }
      : {}),
    ...(config.tlsEdgeControlsTarget
      ? { tlsEdgeControlsTarget: deepClone(config.tlsEdgeControlsTarget) }
      : {}),
    readyAuditCommand: config.readyAuditCommand,
    requiredContracts: [...config.requiredContracts],
  }
}

function assertNestedObjectMap(value, expected, label) {
  assertAllowedKeys(value, Object.keys(expected), label)
  for (const [key, expectedValue] of Object.entries(expected)) {
    if (expectedValue && typeof expectedValue === 'object' && !Array.isArray(expectedValue)) {
      assertNestedObjectMap(value[key], expectedValue, `${label}.${key}`)
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
    assertNotFutureDate(lastReviewed, template.lastReviewed, `${label}.lastReviewed`, nowMs, futureSkewMs)
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
    if (evidence[field] !== placeholder) {
      fail(field === 'commit'
        ? `${label}.deploymentEvidence[0].commit placeholder mismatch`
        : `${label}.deploymentEvidence[0].${field} placeholder mismatch`)
    }
  }
  if (evidence.baseUrl !== config.baseUrl) fail(`${label}.deploymentEvidence[0].baseUrl mismatch`)
  if (evidence.smokeCommand !== config.smokeCommand) fail(`${label}.deploymentEvidence[0].smokeCommand mismatch`)
  if (config.serviceInfoTarget) {
    assertNestedObjectMap(evidence.serviceInfo, config.serviceInfoTarget, `${label}.deploymentEvidence[0].serviceInfo`)
  }
  assertNestedObjectMap(evidence.healthInfo, config.healthInfoTarget, `${label}.deploymentEvidence[0].healthInfo`)
  if (config.soraRpcControlsTarget) {
    assertNestedObjectMap(evidence.soraRpcControls, config.soraRpcControlsTarget, `${label}.deploymentEvidence[0].soraRpcControls`)
  }
  if (config.tlsEdgeControlsTarget) {
    assertNestedObjectMap(evidence.tlsEdgeControls, config.tlsEdgeControlsTarget, `${label}.deploymentEvidence[0].tlsEdgeControls`)
  }
}

function assertIndexerDeploymentTemplateHandoff(value, label, blockerSlug, artifactByPath) {
  const expected = expectedIndexerDeploymentTemplateHandoff(blockerSlug)
  if (!expected) fail(`${label} is not supported on ${blockerSlug}`)
  assertAllowedKeys(value, ['sourceReportPath', 'templateArtifact', 'templateSha256', 'generatedTemplatePath', 'destinationManifest', 'serviceId', 'baseUrl', 'status', 'releaseEnabled', 'requiredEvidenceFields', 'placeholderRecord', 'serviceInfoTarget', 'healthInfoTarget', 'soraRpcControlsTarget', 'tlsEdgeControlsTarget', 'readyAuditCommand', 'requiredContracts'], label)
  for (const [key, expectedValue] of Object.entries(expected)) {
    if (key === 'requiredEvidenceFields' || key === 'requiredContracts') {
      assertExactStringArray(value[key], expectedValue, `${label}.${key}`)
      continue
    }
    if (key === 'placeholderRecord' || key === 'healthInfoTarget' || key === 'soraRpcControlsTarget' || key === 'tlsEdgeControlsTarget') {
      if (expectedValue === null) {
        if (value[key] !== null) fail(`${label}.${key} must be null`)
        continue
      }
      assertNestedObjectMap(value[key], expectedValue, `${label}.${key}`)
      continue
    }
    if (key === 'serviceInfoTarget') {
      if (expectedValue === null) {
        if (value[key] !== null) fail(`${label}.${key} must be null`)
      } else {
        assertNestedObjectMap(value[key], expectedValue, `${label}.${key}`)
      }
      continue
    }
    if (typeof expectedValue === 'boolean') {
      requireBoolean(value[key], `${label}.${key}`)
      if (value[key] !== expectedValue) fail(`${label}.${key} mismatch`)
      continue
    }
    requireSingleLine(value[key], `${label}.${key}`)
    assertNoSecretLike(`${label}.${key}`, value[key])
    if (value[key] !== expectedValue) fail(`${label}.${key} mismatch`)
  }
  requireString(value.templateSha256, `${label}.templateSha256`)
  if (!/^[a-f0-9]{64}$/.test(value.templateSha256)) fail(`${label}.templateSha256 must be lowercase SHA-256`)
  const artifact = artifactByPath.get(value.templateArtifact)
  if (!artifact) fail(`${label}.templateArtifact missing from manifest artifacts`)
  if (artifact.sha256 !== value.templateSha256) fail(`${label}.templateSha256 does not match artifact checksum`)
  const template = readJson(value.templateArtifact, `${label}.templateArtifact`)
  assertIndexerDeploymentEvidenceTemplate(template, `${label}.template`, indexerDeploymentTemplateConfigs[blockerSlug])
  const content = readBundleFile(value.templateArtifact, `${label}.templateArtifact`)
  if (sha256(content) !== value.templateSha256) fail(`${label}.templateSha256 does not match bundle file`)
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

function expectedNexusProductionEvidenceTemplateHandoff(slug) {
  if (slug !== 'iroha-release-readiness') return null
  return {
    sourceReportPath: nexusProductionEvidenceTemplateSourcePath,
    templateArtifact: nexusProductionEvidenceTemplateArtifactPath,
    generatedTemplatePath: 'build/reports/nexus-production-evidence-template.json',
    destinationManifest: 'config/nexus-production-evidence.json',
    network: 'sora-nexus-mainnet',
    chainId: 'sora:nexus:global',
    toriiBaseUrl: 'https://minamoto.sora.org',
    mcpUrl: 'https://minamoto.sora.org/v1/mcp',
    healthUrl: 'https://minamoto.sora.org/status',
    status: 'ready',
    releaseEnabled: true,
    requiredEvidenceFields: [...nexusProductionEvidenceRequiredFields],
    routePublicationPlaceholder: { ...nexusRoutePublicationPlaceholder },
    routeCanaryPlaceholder: { ...nexusRouteCanaryPlaceholder },
    walletSmokePlaceholders: nexusWalletSmokePlaceholders(),
    readyAuditCommand: 'bash scripts/audit-nexus-production-evidence.sh --require-ready',
    strictReleaseReadinessCommand: 'IROHA_NEXUS_REQUIRE_PRODUCTION_EVIDENCE=1 IROHA_NEXUS_LIVE_HEALTH=1 bash scripts/audit-iroha-release-readiness.sh',
    requiredContracts: [...nexusProductionEvidenceTemplateContracts],
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
  assertNestedObjectMap(template.routePublicationEvidence[0], nexusRoutePublicationPlaceholder, `${label}.routePublicationEvidence[0]`)
  if (!Array.isArray(template.routeCanaryEvidence) || template.routeCanaryEvidence.length !== 1) {
    fail(`${label}.routeCanaryEvidence must contain exactly one fill-in record`)
  }
  assertNestedObjectMap(template.routeCanaryEvidence[0], nexusRouteCanaryPlaceholder, `${label}.routeCanaryEvidence[0]`)
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
    assertNestedObjectMap(evidence, expected, `${label}.walletSmokeEvidence[${index}]`)
  }
  for (const platform of ['android', 'ios', 'web']) {
    if (!seenPlatforms.has(platform)) fail(`${label}.walletSmokeEvidence missing ${platform}`)
  }
}

function assertNexusProductionEvidenceTemplateHandoff(value, label, blockerSlug, artifactByPath) {
  const expected = expectedNexusProductionEvidenceTemplateHandoff(blockerSlug)
  if (!expected) fail(`${label} is not supported on ${blockerSlug}`)
  assertAllowedKeys(value, ['sourceReportPath', 'templateArtifact', 'templateSha256', 'generatedTemplatePath', 'destinationManifest', 'network', 'chainId', 'toriiBaseUrl', 'mcpUrl', 'healthUrl', 'status', 'releaseEnabled', 'requiredEvidenceFields', 'routePublicationPlaceholder', 'routeCanaryPlaceholder', 'walletSmokePlaceholders', 'readyAuditCommand', 'strictReleaseReadinessCommand', 'requiredContracts'], label)
  for (const [key, expectedValue] of Object.entries(expected)) {
    if (key === 'requiredEvidenceFields' || key === 'requiredContracts') {
      assertExactStringArray(value[key], expectedValue, `${label}.${key}`)
      continue
    }
    if (key === 'routePublicationPlaceholder' || key === 'routeCanaryPlaceholder' || key === 'walletSmokePlaceholders') {
      assertNestedObjectMap(value[key], expectedValue, `${label}.${key}`)
      continue
    }
    if (typeof expectedValue === 'boolean') {
      requireBoolean(value[key], `${label}.${key}`)
      if (value[key] !== expectedValue) fail(`${label}.${key} mismatch`)
      continue
    }
    requireSingleLine(value[key], `${label}.${key}`)
    assertNoSecretLike(`${label}.${key}`, value[key])
    if (value[key] !== expectedValue) fail(`${label}.${key} mismatch`)
  }
  requireString(value.templateSha256, `${label}.templateSha256`)
  if (!/^[a-f0-9]{64}$/.test(value.templateSha256)) fail(`${label}.templateSha256 must be lowercase SHA-256`)
  const artifact = artifactByPath.get(value.templateArtifact)
  if (!artifact) fail(`${label}.templateArtifact missing from manifest artifacts`)
  if (artifact.sha256 !== value.templateSha256) fail(`${label}.templateSha256 does not match artifact checksum`)
  const template = readJson(value.templateArtifact, `${label}.templateArtifact`)
  assertNexusProductionEvidenceTemplate(template, `${label}.template`)
  const content = readBundleFile(value.templateArtifact, `${label}.templateArtifact`)
  if (sha256(content) !== value.templateSha256) fail(`${label}.templateSha256 does not match bundle file`)
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

function expectedPasskeyDeploymentTemplateHandoff(slug) {
  if (slug !== 'passkey-deployment-evidence') return null
  return {
    sourceReportPath: passkeyDeploymentTemplateSourcePath,
    templateArtifact: passkeyDeploymentTemplateArtifactPath,
    generatedTemplatePath: 'services/passkey-backup-challenge-service/build/reports/production-deployment-evidence-template.json',
    destinationManifest: 'services/passkey-backup-challenge-service/scripts/production-deployment-evidence.json',
    service: 'fearless-passkey-backup',
    baseUrl: 'https://backup.fearlesswallet.io',
    healthUrl: 'https://backup.fearlesswallet.io/api/passkey-backup/v1/health',
    credentialStoreFile: '/data/passkey-backup/credentials.json',
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

function assertObjectMap(value, expected, label) {
  assertAllowedKeys(value, Object.keys(expected), label)
  for (const [key, expectedValue] of Object.entries(expected)) {
    const actual = value[key]
    if (typeof expectedValue === 'boolean' || typeof expectedValue === 'number') {
      if (actual !== expectedValue) fail(`${label}.${key} mismatch`)
      continue
    }
    requireSingleLine(actual, `${label}.${key}`)
    assertNoSecretLike(`${label}.${key}`, actual)
    if (actual !== expectedValue) fail(`${label}.${key} mismatch`)
  }
}

function assertPasskeyDeploymentTemplateHandoff(value, label, blockerSlug, artifactByPath) {
  const expected = expectedPasskeyDeploymentTemplateHandoff(blockerSlug)
  if (!expected) fail(`${label} is not supported on ${blockerSlug}`)
  assertAllowedKeys(value, ['sourceReportPath', 'templateArtifact', 'templateSha256', 'generatedTemplatePath', 'destinationManifest', 'service', 'baseUrl', 'healthUrl', 'credentialStoreFile', 'requiredEvidenceFields', 'placeholderRecord', 'healthResponseTarget', 'liveHealthAttestationTarget', 'webauthnAllowedOriginsTarget', 'requestAccessPolicyTarget', 'trustedProxyPolicyTarget', 'platformProvisioningTarget', 'platformProvisioningAttestationTarget', 'readyAuditCommand', 'requiredContracts'], label)
  for (const [key, expectedValue] of Object.entries(expected)) {
    if (key === 'requiredEvidenceFields' || key === 'requiredContracts' || key === 'webauthnAllowedOriginsTarget') {
      assertExactStringArray(value[key], expectedValue, `${label}.${key}`)
      continue
    }
    if (key === 'placeholderRecord' || key === 'healthResponseTarget' || key === 'liveHealthAttestationTarget' || key === 'requestAccessPolicyTarget' || key === 'trustedProxyPolicyTarget' || key === 'platformProvisioningTarget' || key === 'platformProvisioningAttestationTarget') {
      assertObjectMap(value[key], expectedValue, `${label}.${key}`)
      continue
    }
    requireSingleLine(value[key], `${label}.${key}`)
    assertNoSecretLike(`${label}.${key}`, value[key])
    if (value[key] !== expectedValue) fail(`${label}.${key} mismatch`)
  }
  requireString(value.templateSha256, `${label}.templateSha256`)
  if (!/^[a-f0-9]{64}$/.test(value.templateSha256)) fail(`${label}.templateSha256 must be lowercase SHA-256`)
  const artifact = artifactByPath.get(value.templateArtifact)
  if (!artifact) fail(`${label}.templateArtifact missing from manifest artifacts`)
  if (artifact.sha256 !== value.templateSha256) fail(`${label}.templateSha256 does not match artifact checksum`)
  const template = readJson(value.templateArtifact, `${label}.templateArtifact`)
  assertPasskeyDeploymentEvidenceTemplate(template, `${label}.template`)
  const content = readBundleFile(value.templateArtifact, `${label}.templateArtifact`)
  if (sha256(content) !== value.templateSha256) fail(`${label}.templateSha256 does not match bundle file`)
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
  'google-account-selection',
  'google-drive-consent',
  'cross-platform-restore',
  'optional-icloud-copy',
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
  'PASSKEY_BACKUP_LIVE_HEALTH=1 bash scripts/audit-passkey-backup-prerequisites.sh && node fearless-site-web-app-associations-20260726/scripts/verify-app-associations.mjs --root fearless-site-web-app-associations-20260726 --live-base-url https://fearlesswallet.io',
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
  'OpenAPI Base64UrlUserId remains canonical 43-character unpadded base64url SHA-256; assertion userHandle is required and permits null only for an exact credential-directed challenge',
  'OpenAPI health response must require ok=true, service=fearless-passkey-backup, rpId=fearlesswallet.io, and schemaVersion=1',
  'production Docker Compose must bind 127.0.0.1:8789:8789 and mount passkey-backup-data:/data/passkey-backup',
  'production Docker Compose must keep PASSKEY_ALLOWED_ORIGINS pinned to fearlesswallet.io and backup.fearlesswallet.io',
  'production Docker Compose must require the Android origin, authorization introspection URL, and trusted proxy CIDRs without permissive fallbacks',
  'production Docker Compose must pin authorization audience/timeouts, one trusted proxy hop, per-client/global rate limits, and the durable credential store',
  'Android origin parity must pass in blocked mode; --require-ready requires actual release-artifact evidence and assetlinks parity: distributed-apk must bind PASSKEY_ANDROID_DISTRIBUTED_APK_FILE and PASSKEY_ANDROID_RELEASE_ARTIFACT_SHA256 to one v2/v3 signer and exact package jp.co.soramitsu.fearless, while play-app-signing-certificate must bind an immutable AAB plus independently exported immutable X.509 certificate and canonical attestation through their SHA-256 digests, derive the fingerprint from that certificate, and bind packageName/versionCode to the compiled AAB; AAB upload-key evidence is rejected and absence keeps passkey flags disabled',
]

function expectedPasskeyProductionContractHandoff(slug) {
  if (!passkeyProductionContractSlugs.has(slug)) return null
  return {
    productionConfigSourcePath: passkeyProductionConfigSourcePath,
    productionConfigArtifact: passkeyProductionConfigArtifactPath,
    openApiSourcePath: passkeyOpenApiSourcePath,
    openApiArtifact: passkeyOpenApiArtifactPath,
    composeSourcePath: passkeyProductionComposeSourcePath,
    composeArtifact: passkeyProductionComposeArtifactPath,
    service: passkeyProductionService,
    baseUrl: passkeyProductionBaseUrl,
    rpId: passkeyProductionRpId,
    schemaVersion: passkeyProductionSchemaVersion,
    healthPath: passkeyProductionHealthPath,
    androidSignerEvidence: JSON.parse(JSON.stringify(passkeyAndroidSignerEvidence)),
    requiredRoutePaths: [...passkeyProductionRoutePaths],
    requiredContracts: [...passkeyProductionRequiredContracts],
    verificationCommands: [...passkeyProductionVerificationCommands],
  }
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

  assertAllowedKeys(config.ios, ['releaseEnabled', 'backupStorage', 'googleDriveScope', 'additionalBackupStorage', 'associatedDomain', 'cloudKitRecordType', 'cloudKitContainers', 'releaseUxChecklist'], `${label}.ios`)
  if (config.ios.releaseEnabled !== false) fail(`${label}.ios.releaseEnabled must be false`)
  if (config.ios.backupStorage !== 'google-drive-appdata') fail(`${label}.ios.backupStorage mismatch`)
  if (config.ios.googleDriveScope !== 'https://www.googleapis.com/auth/drive.appdata') fail(`${label}.ios.googleDriveScope mismatch`)
  if (config.ios.additionalBackupStorage !== 'cloudkit-private-database') fail(`${label}.ios.additionalBackupStorage mismatch`)
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
    [passkeyChallengeServicePaths.credentialsRevoke, 'revokePasskeyCredential', '#/components/schemas/CredentialRevokeResponse', ['200', '400', '401', '403', '409', '413', '415', '429', '500', '503']],
    [passkeyChallengeServicePaths.credentialsRevokeAll, 'revokeAllPasskeyCredentials', '#/components/schemas/CredentialRevokeAllResponse', ['200', '400', '401', '403', '409', '413', '415', '429', '500', '503']],
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
  const assertionUserHandle = schemas.AssertionAuthenticatorResponse?.properties?.userHandle
  if (!schemas.AssertionAuthenticatorResponse?.required?.includes('userHandle') ||
      !assertionUserHandle || Object.keys(assertionUserHandle).sort().join(',') !== 'description,oneOf' ||
      assertionUserHandle.description !== 'Null is accepted only for an assertion whose challenge was bound to an exact credentialId.' ||
      !Array.isArray(assertionUserHandle.oneOf) || assertionUserHandle.oneOf.length !== 2 ||
      Object.keys(assertionUserHandle.oneOf[0] ?? {}).join(',') !== '$ref' ||
      assertionUserHandle.oneOf[0].$ref !== '#/components/schemas/Base64UrlUserId' ||
      Object.keys(assertionUserHandle.oneOf[1] ?? {}).join(',') !== 'type' ||
      assertionUserHandle.oneOf[1].type !== 'null') {
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
    'image: "${PASSKEY_BACKUP_IMAGE_REPOSITORY:?Set the reviewed passkey image repository}@sha256:${PASSKEY_BACKUP_IMAGE_DIGEST:?Set the reviewed 64-character lowercase image digest}"',
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
  if (/^\s*build\s*:/m.test(content)) fail(`${label} must not build a mutable local image`)
  if (/\.env/.test(content)) fail(`${label} must not depend on .env files`)
  if (/-\s*["']?(?:0\.0\.0\.0:)?8789:8789["']?/.test(content)) fail(`${label} must not expose the service port publicly`)
  for (const variable of ['PASSKEY_ANDROID_ALLOWED_ORIGIN', 'PASSKEY_AUTHORIZATION_INTROSPECTION_URL', 'PASSKEY_TRUSTED_PROXY_CIDRS']) {
    if (new RegExp(`\\$\\{${variable}:-`).test(content)) fail(`${label} must not provide a permissive fallback for ${variable}`)
  }
  assertNoSecretLike(label, content)
}

function assertPasskeyProductionContractHandoff(value, label, blockerSlug, artifactByPath) {
  const expected = expectedPasskeyProductionContractHandoff(blockerSlug)
  if (!expected) fail(`${label} is not supported on ${blockerSlug}`)
  assertAllowedKeys(value, [
    'productionConfigSourcePath',
    'productionConfigArtifact',
    'productionConfigSha256',
    'openApiSourcePath',
    'openApiArtifact',
    'openApiSha256',
    'composeSourcePath',
    'composeArtifact',
    'composeSha256',
    'service',
    'baseUrl',
    'rpId',
    'schemaVersion',
    'healthPath',
    'androidSignerEvidence',
    'requiredRoutePaths',
    'requiredContracts',
    'verificationCommands',
  ], label)
  for (const [key, expectedValue] of Object.entries(expected)) {
    if (key === 'androidSignerEvidence') {
      assertAllowedKeys(value[key], Object.keys(expectedValue), `${label}.${key}`)
      for (const field of ['fingerprintEnvironmentVariable', 'sourceEnvironmentVariable', 'exactPackageName']) {
        requireSingleLine(value[key][field], `${label}.${key}.${field}`)
        if (value[key][field] !== expectedValue[field]) fail(`${label}.${key}.${field} mismatch`)
      }
      for (const field of ['allowedSources', 'rejectedEvidenceTypes']) {
        assertExactStringArray(value[key][field], expectedValue[field], `${label}.${key}.${field}`)
      }
      for (const field of ['independentlyObtained', 'requiresAssetlinksParity']) {
        if (value[key][field] !== expectedValue[field]) fail(`${label}.${key}.${field} mismatch`)
      }
      for (const nestedField of ['distributedApk', 'playAppSigningCertificate']) {
        const actualNested = value[key][nestedField]
        const expectedNested = expectedValue[nestedField]
        assertAllowedKeys(actualNested, Object.keys(expectedNested), `${label}.${key}.${nestedField}`)
        for (const [field, expectedNestedValue] of Object.entries(expectedNested)) {
          if (typeof expectedNestedValue === 'boolean') {
            if (actualNested[field] !== expectedNestedValue) fail(`${label}.${key}.${nestedField}.${field} mismatch`)
            continue
          }
          requireSingleLine(actualNested[field], `${label}.${key}.${nestedField}.${field}`)
          assertNoSecretLike(`${label}.${key}.${nestedField}.${field}`, actualNested[field])
          if (actualNested[field] !== expectedNestedValue) fail(`${label}.${key}.${nestedField}.${field} mismatch`)
        }
      }
      continue
    }
    if (key === 'requiredRoutePaths' || key === 'requiredContracts' || key === 'verificationCommands') {
      assertExactStringArray(value[key], expectedValue, `${label}.${key}`)
      continue
    }
    if (key === 'schemaVersion') {
      if (value[key] !== expectedValue) fail(`${label}.${key} mismatch`)
      continue
    }
    requireSingleLine(value[key], `${label}.${key}`)
    assertNoSecretLike(`${label}.${key}`, value[key])
    if (value[key] !== expectedValue) fail(`${label}.${key} mismatch`)
  }
  for (const [field, artifactField] of [
    ['productionConfigSha256', 'productionConfigArtifact'],
    ['openApiSha256', 'openApiArtifact'],
    ['composeSha256', 'composeArtifact'],
  ]) {
    requireString(value[field], `${label}.${field}`)
    if (!/^[a-f0-9]{64}$/.test(value[field])) fail(`${label}.${field} must be lowercase SHA-256`)
    const artifact = artifactByPath.get(value[artifactField])
    if (!artifact) fail(`${label}.${artifactField} missing from manifest artifacts`)
    if (artifact.sha256 !== value[field]) fail(`${label}.${field} does not match artifact checksum`)
    const content = readBundleFile(value[artifactField], `${label}.${artifactField}`)
    if (sha256(content) !== value[field]) fail(`${label}.${field} does not match bundle file`)
  }
  assertPasskeyProductionConfig(readJson(value.productionConfigArtifact, `${label}.productionConfigArtifact`), `${label}.productionConfig`)
  assertPasskeyOpenApi(readJson(value.openApiArtifact, `${label}.openApiArtifact`), `${label}.openApi`)
  assertPasskeyProductionCompose(readBundleFile(value.composeArtifact, `${label}.composeArtifact`, 'utf8'), `${label}.compose`)
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

function expectedBitcoinBroadcastTemplateHandoff(slug) {
  if (slug !== 'web-bitcoin-broadcast-evidence') return null
  return {
    sourceReportPath: bitcoinBroadcastTemplateSourcePath,
    templateArtifact: bitcoinBroadcastTemplateArtifactPath,
    generatedTemplatePath: 'fearless-wallet-web/build/reports/bitcoin-broadcast-evidence-template.json',
    destinationManifest: 'fearless-wallet-web/scripts/bitcoin-testnet-broadcast-evidence.json',
    defaultIndexerUrl: 'https://blockstream.info/testnet/api',
    requiredEvidenceFields: [...bitcoinRequiredEvidenceFields],
    placeholderRecord: { ...bitcoinTemplatePlaceholders },
    readyAuditCommand: 'cd fearless-wallet-web && bash scripts/audit-bitcoin-broadcast-evidence.sh --require-ready',
    requiredContracts: [...bitcoinBroadcastTemplateContracts],
  }
}

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
      const mismatchLabel = field === 'commit'
        ? `${label}.evidence[0].commit placeholder mismatch`
        : `${label}.evidence[0].${field} placeholder mismatch`
      fail(mismatchLabel)
    }
  }
}

function assertBitcoinBroadcastTemplateHandoff(value, label, blockerSlug, artifactByPath) {
  const expected = expectedBitcoinBroadcastTemplateHandoff(blockerSlug)
  if (!expected) fail(`${label} is not supported on ${blockerSlug}`)
  assertAllowedKeys(value, ['sourceReportPath', 'templateArtifact', 'templateSha256', 'generatedTemplatePath', 'destinationManifest', 'defaultIndexerUrl', 'requiredEvidenceFields', 'placeholderRecord', 'readyAuditCommand', 'requiredContracts'], label)
  for (const [key, expectedValue] of Object.entries(expected)) {
    if (key === 'requiredEvidenceFields' || key === 'requiredContracts') {
      assertExactStringArray(value[key], expectedValue, `${label}.${key}`)
      continue
    }
    if (key === 'placeholderRecord') {
      assertAllowedKeys(value[key], bitcoinRequiredEvidenceFields, `${label}.${key}`)
      for (const [field, placeholder] of Object.entries(expectedValue)) {
        requireSingleLine(value[key][field], `${label}.${key}.${field}`)
        assertNoSecretLike(`${label}.${key}.${field}`, value[key][field])
        if (value[key][field] !== placeholder) fail(`${label}.${key}.${field} mismatch`)
      }
      continue
    }
    requireSingleLine(value[key], `${label}.${key}`)
    assertNoSecretLike(`${label}.${key}`, value[key])
    if (value[key] !== expectedValue) fail(`${label}.${key} mismatch`)
  }
  requireString(value.templateSha256, `${label}.templateSha256`)
  if (!/^[a-f0-9]{64}$/.test(value.templateSha256)) fail(`${label}.templateSha256 must be lowercase SHA-256`)
  const artifact = artifactByPath.get(value.templateArtifact)
  if (!artifact) fail(`${label}.templateArtifact missing from manifest artifacts`)
  if (artifact.sha256 !== value.templateSha256) fail(`${label}.templateSha256 does not match artifact checksum`)
  const template = readJson(value.templateArtifact, `${label}.templateArtifact`)
  assertBitcoinBroadcastEvidenceTemplate(template, `${label}.template`)
  const content = readBundleFile(value.templateArtifact, `${label}.templateArtifact`)
  if (sha256(content) !== value.templateSha256) fail(`${label}.templateSha256 does not match bundle file`)
}

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
const xcmProductionEvidenceTemplateHandoffBySlug = {
  'android-xcm-production-evidence': {
    sourceReportPath: 'android-xcm-production-evidence-template.json',
    templateArtifact: xcmProductionEvidenceTemplateArtifactPath,
    generatedTemplatePath: 'fearless-Android-production-consolidated-20260731/build/reports/xcm-production-evidence-template.json',
    destinationManifest: 'fearless-Android-production-consolidated-20260731/scripts/xcm-production-evidence.json',
    requiredRouteFile: 'fearless-Android-production-consolidated-20260731/scripts/xcm-required-routes.tsv',
    discoveryGapFile: 'fearless-Android-production-consolidated-20260731/scripts/xcm-discovery-only-routes.tsv',
    requiredEvidenceFields: [...xcmProductionEvidenceRequiredFields],
    placeholderRecord: deepClone(xcmProductionEvidencePlaceholderRecord),
    readyAuditCommand: 'cd fearless-Android-production-consolidated-20260731 && bash scripts/audit-xcm-effective-registry.sh --discovery-url https://raw.githubusercontent.com/soramitsu/shared-features-utils/master/chains/v13/chains.json --require-all-approved --write-report build/reports/xcm-effective-registry-report.json && bash scripts/audit-xcm-production-evidence.sh --effective-registry-report build/reports/xcm-effective-registry-report.json --require-ready',
    requiredContracts: [...xcmProductionEvidenceTemplateContracts],
  },
}

function expectedXcmProductionEvidenceTemplateHandoff(slug) {
  return xcmProductionEvidenceTemplateHandoffBySlug[slug] || null
}

function assertXcmRequiredRouteSourcePath(value, label) {
  requireSingleLine(value, label)
  assertNoSecretLike(label, value)
  if (value !== 'fearless-Android-production-consolidated-20260731/scripts/xcm-required-routes.tsv' && !value.endsWith('/fearless-Android-production-consolidated-20260731/scripts/xcm-required-routes.tsv')) {
    fail(`${label} must point at fearless-Android-production-consolidated-20260731/scripts/xcm-required-routes.tsv`)
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
  const requiredSource = readCandidateXcmRoutes(xcmEffectiveRegistryLocalInputs.requiredRoutes, `${label}.requiredRouteManifest`)
  xcmTemplateRequiredSourceIdentity = requiredSource
  assertXcmTemplateAndEffectiveSourceAgree()
  const requiredRoutes = requiredSource.routes
  if (template.requiredRouteCount !== requiredRoutes.length) {
    fail(`${label}.requiredRouteCount must match candidate required-route manifest`)
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
    if (routeKey !== requiredRoutes[index]) fail(`${label}.evidence[${index}] does not match candidate required-route manifest order`)
    for (const [field, placeholder] of Object.entries(xcmProductionEvidencePlaceholderRecord)) {
      if (typeof placeholder === 'boolean') {
        requireBoolean(evidence[field], `${label}.evidence[${index}].${field}`)
      } else {
        requireSingleLine(evidence[field], `${label}.evidence[${index}].${field}`)
        assertNoSecretLike(`${label}.evidence[${index}].${field}`, evidence[field])
      }
      if (evidence[field] !== placeholder) fail(`${label}.evidence[${index}].${field} placeholder mismatch`)
    }
  }
}

function assertXcmProductionEvidenceTemplateHandoff(value, label, blockerSlug, artifactByPath) {
  const expected = expectedXcmProductionEvidenceTemplateHandoff(blockerSlug)
  if (!expected) fail(`${label} is not supported on ${blockerSlug}`)
  assertAllowedKeys(value, ['sourceReportPath', 'templateArtifact', 'templateSha256', 'generatedTemplatePath', 'destinationManifest', 'requiredRouteFile', 'discoveryGapFile', 'requiredRouteCount', 'requiredEvidenceFields', 'placeholderRecord', 'readyAuditCommand', 'requiredContracts'], label)
  for (const [key, expectedValue] of Object.entries(expected)) {
    if (key === 'requiredEvidenceFields' || key === 'requiredContracts') {
      assertExactStringArray(value[key], expectedValue, `${label}.${key}`)
      continue
    }
    if (key === 'placeholderRecord') {
      assertObjectMap(value[key], expectedValue, `${label}.${key}`)
      continue
    }
    requireSingleLine(value[key], `${label}.${key}`)
    assertNoSecretLike(`${label}.${key}`, value[key])
    if (value[key] !== expectedValue) fail(`${label}.${key} mismatch`)
  }
  requireNumber(value.requiredRouteCount, `${label}.requiredRouteCount`)
  if (value.requiredRouteCount === 0) fail(`${label}.requiredRouteCount must be positive`)
  requireString(value.templateSha256, `${label}.templateSha256`)
  if (!/^[a-f0-9]{64}$/.test(value.templateSha256)) fail(`${label}.templateSha256 must be lowercase SHA-256`)
  const artifact = artifactByPath.get(value.templateArtifact)
  if (!artifact) fail(`${label}.templateArtifact missing from manifest artifacts`)
  if (artifact.sha256 !== value.templateSha256) fail(`${label}.templateSha256 does not match artifact checksum`)
  const template = readJson(value.templateArtifact, `${label}.templateArtifact`)
  assertXcmProductionEvidenceTemplate(template, `${label}.template`)
  if (template.requiredRouteCount !== value.requiredRouteCount) {
    fail(`${label}.requiredRouteCount must match template`)
  }
  const content = readBundleFile(value.templateArtifact, `${label}.templateArtifact`)
  if (sha256(content) !== value.templateSha256) fail(`${label}.templateSha256 does not match bundle file`)
}

const xcmRegistryHandoffBySlug = {
  'android-xcm-production-evidence': {
    sourceReportPath: 'android-xcm-registry-gap-report.json',
    gapReportArtifact: 'handoffs/android-xcm-registry-gap-report.json',
    registryFile: 'runtime/src/main/assets/local_chains.json',
    requiredRouteFile: 'fearless-Android-production-consolidated-20260731/scripts/xcm-required-routes.tsv',
    discoveryGapFile: 'fearless-Android-production-consolidated-20260731/scripts/xcm-discovery-only-routes.tsv',
    generatedGapReportPath: 'fearless-Android-production-consolidated-20260731/build/reports/xcm-registry-gap-report.json',
    registryAuditCommand: 'cd fearless-Android-production-consolidated-20260731 && bash scripts/audit-xcm-registry-metadata.sh --require-executable --write-gap-report build/reports/xcm-registry-gap-report.json --require-route-file scripts/xcm-required-routes.tsv --require-gap-file scripts/xcm-discovery-only-routes.tsv --require-all-routes-executable',
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
  },
}

function expectedXcmRegistryHandoff(slug) {
  return xcmRegistryHandoffBySlug[slug] || null
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
const xcmEffectiveRegistryGeneratedPath = 'fearless-Android-production-consolidated-20260731/build/reports/xcm-effective-registry-report.json'
const xcmProductionDiscoveryUrl = 'https://raw.githubusercontent.com/soramitsu/shared-features-utils/master/chains/v13/chains.json'
const xcmEffectiveRegistryLocalInputs = {
  approvedRoutes: 'runtime/src/main/assets/approved_xcm_routes.tsv',
  requiredRoutes: 'scripts/xcm-required-routes.tsv',
  bundledRegistry: 'runtime/src/main/assets/local_chains.json',
}
const xcmCandidateDirectory = 'fearless-Android-production-consolidated-20260731'
let xcmTemplateRequiredSourceIdentity = null
let xcmEffectiveRequiredSourceIdentity = null

function assertXcmSourceIdentity(actual, expected, label) {
  if (actual.byteLength !== expected.byteLength) fail(`${label}.byteLength does not match candidate route source`)
  if (actual.sha256 !== expected.sha256) fail(`${label}.sha256 does not match candidate route source`)
}

function assertXcmTemplateAndEffectiveSourceAgree() {
  if (!xcmTemplateRequiredSourceIdentity || !xcmEffectiveRequiredSourceIdentity) return
  assertXcmSourceIdentity(xcmTemplateRequiredSourceIdentity, xcmEffectiveRequiredSourceIdentity, 'Android XCM template required-route source')
}

function readCandidateXcmRoutes(relativeSource, label) {
  const source = path.join(workspaceRoot, xcmCandidateDirectory, relativeSource)
  if (!fs.existsSync(source)) fail(`${label} workspace source missing: ${source}`)
  assertNoRootSymlinkPathPrefix(source, label)
  const stat = fs.lstatSync(source)
  if (stat.isSymbolicLink() || !stat.isFile()) fail(`${label} workspace source must be a regular non-symlink file`)
  if (stat.size > 1024 * 1024) fail(`${label} exceeds 1 MiB`)
  const bytes = fs.readFileSync(source)
  const routes = []
  const seen = new Set()
  for (const [index, line] of bytes.toString('utf8').split(/\r?\n/u).entries()) {
    const trimmed = line.replace(/\s+#.*$/u, '').trim()
    if (!trimmed || trimmed.startsWith('#')) continue
    const parts = trimmed.split(/\s+/u)
    if (parts.length !== 3) fail(`${label} line ${index + 1} must contain exactly origin destination asset columns`)
    const [origin, destination, symbol] = parts
    if (!/^[0-9a-f]{64}$/u.test(origin) || !/^[0-9a-f]{64}$/u.test(destination) || origin === destination) {
      fail(`${label} line ${index + 1} has invalid chain identities`)
    }
    if (!/^[A-Z0-9][A-Z0-9._-]{0,31}$/u.test(symbol) || symbol.replace(/^xc/iu, '').toUpperCase() !== symbol) {
      fail(`${label} line ${index + 1} has a noncanonical asset symbol`)
    }
    const key = `${origin}|${destination}|${symbol}`
    if (seen.has(key)) fail(`${label} contains duplicate route: ${key}`)
    seen.add(key)
    routes.push(key)
  }
  if (routes.length === 0) fail(`${label} must contain at least one route`)
  return { routes, byteLength: bytes.length, sha256: sha256(bytes) }
}

function assertXcmCandidateRouteParity(report, label) {
  const approvedSource = readCandidateXcmRoutes(xcmEffectiveRegistryLocalInputs.approvedRoutes, `${label}.approvedRouteManifest`)
  const requiredSource = readCandidateXcmRoutes(xcmEffectiveRegistryLocalInputs.requiredRoutes, `${label}.requiredRouteManifest`)
  assertXcmSourceIdentity(approvedSource, report.inputs.approvedRoutes, `${label}.inputs.approvedRoutes`)
  assertXcmSourceIdentity(requiredSource, report.inputs.requiredRoutes, `${label}.inputs.requiredRoutes`)
  xcmEffectiveRequiredSourceIdentity = requiredSource
  assertXcmTemplateAndEffectiveSourceAgree()
  const approved = approvedSource.routes.sort((a, b) => a.localeCompare(b))
  const required = requiredSource.routes.sort((a, b) => a.localeCompare(b))
  if (approved.length !== required.length || approved.some((route, index) => route !== required[index])) {
    fail(`${label}.approved and required route manifests must contain the same routes`)
  }
  if (report.routes.length !== approved.length) fail(`${label}.routes length must match candidate approved-route manifest`)
  for (const [index, route] of report.routes.entries()) {
    if (xcmEffectiveRouteKey(route) !== approved[index]) {
      fail(`${label}.routes[${index}] does not match candidate approved-route manifest`)
    }
  }
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
  bundled: 'cd fearless-Android-production-consolidated-20260731 && bash scripts/audit-xcm-effective-registry.sh --write-report build/reports/xcm-effective-registry-report.json',
  discovery: `cd fearless-Android-production-consolidated-20260731 && bash scripts/audit-xcm-effective-registry.sh --discovery-url ${xcmProductionDiscoveryUrl} --require-all-approved --write-report build/reports/xcm-effective-registry-report.json`,
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

function assertXcmEffectiveWorkspaceInputParity(report, label, workspaceRoot) {
  for (const [inputName, relativeSource] of Object.entries(xcmEffectiveRegistryLocalInputs)) {
    const source = path.join(workspaceRoot, 'fearless-Android-production-consolidated-20260731', relativeSource)
    if (!fs.existsSync(source)) fail(`${label}.inputs.${inputName} workspace source missing: ${source}`)
    assertNoRootSymlinkPathPrefix(source, `${label}.inputs.${inputName}.workspaceSource`)
    const stat = fs.lstatSync(source)
    if (stat.isSymbolicLink() || !stat.isFile()) fail(`${label}.inputs.${inputName} workspace source must be a regular non-symlink file`)
    const content = fs.readFileSync(source)
    if (content.length !== report.inputs[inputName].byteLength) fail(`${label}.inputs.${inputName}.byteLength does not match workspace source`)
    if (sha256(content) !== report.inputs[inputName].sha256) fail(`${label}.inputs.${inputName}.sha256 does not match workspace source`)
  }
}

function assertXcmEffectiveRegistryReport(report, label, runLive, workspaceRoot) {
  assertAllowedKeys(report, ['schemaVersion', 'mode', 'status', 'policy', 'inputs', 'summary', 'routes', 'missing', 'extra'], label)
  if (report.schemaVersion !== 1) fail(`${label}.schemaVersion must be 1`)
  if (!['bundled', 'discovery'].includes(report.mode)) fail(`${label}.mode must be bundled or discovery`)
  if (!['complete', 'incomplete'].includes(report.status)) fail(`${label}.status must be complete or incomplete`)
  const expectedMode = runLive ? 'discovery' : 'bundled'
  if (report.mode !== expectedMode) fail(`${label}.mode must be ${expectedMode} when runLive=${runLive}`)

  assertAllowedKeys(report.policy, Object.keys(xcmEffectiveRegistryPolicy), `${label}.policy`)
  for (const [key, expected] of Object.entries(xcmEffectiveRegistryPolicy)) {
    if (typeof expected === 'boolean') requireBoolean(report.policy[key], `${label}.policy.${key}`)
    else requireSingleLine(report.policy[key], `${label}.policy.${key}`)
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
    },
  )
  const missingKeys = assertXcmEffectiveSortedUniqueRoutes(
    report.missing,
    `${label}.missing`,
    ['originChainId', 'destinationChainId', 'assetSymbol', 'reasons'],
    (route, routeLabel) => {
      assertXcmEffectiveReasons(route.reasons, `${routeLabel}.reasons`)
      if (route.reasons.length === 0) fail(`${routeLabel}.reasons must be non-empty`)
    },
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
  assertXcmEffectiveWorkspaceInputParity(report, label, workspaceRoot)
  assertXcmCandidateRouteParity(report, label)
}

function assertXcmEffectiveRegistryHandoff(value, label, report, runLive, artifactByPath, workspaceRoot) {
  assertAllowedKeys(value, [
    'sourceReportPath',
    'reportArtifact',
    'reportSha256',
    'generatedReportPath',
    'mode',
    'status',
    'auditCommand',
    'policy',
    'inputContentIdentities',
    'discoveryRegistry',
    'counts',
  ], label)
  const expectedStrings = {
    sourceReportPath: xcmEffectiveRegistrySourcePath,
    reportArtifact: xcmEffectiveRegistryArtifactPath,
    generatedReportPath: xcmEffectiveRegistryGeneratedPath,
    mode: report.mode,
    status: report.status,
    auditCommand: xcmEffectiveRegistryAuditCommands[report.mode],
  }
  for (const [key, expected] of Object.entries(expectedStrings)) {
    requireSingleLine(value[key], `${label}.${key}`)
    assertNoSecretLike(`${label}.${key}`, value[key])
    if (value[key] !== expected) fail(`${label}.${key} mismatch`)
  }
  requireString(value.reportSha256, `${label}.reportSha256`)
  if (!/^[a-f0-9]{64}$/.test(value.reportSha256)) fail(`${label}.reportSha256 must be lowercase SHA-256`)
  const artifact = artifactByPath.get(value.reportArtifact)
  if (!artifact) fail(`${label}.reportArtifact missing from manifest artifacts`)
  if (artifact.sha256 !== value.reportSha256) fail(`${label}.reportSha256 does not match artifact checksum`)
  const content = readBundleFile(value.reportArtifact, `${label}.reportArtifact`)
  if (sha256(content) !== value.reportSha256) fail(`${label}.reportSha256 does not match bundle file`)

  assertObjectMap(value.policy, report.policy, `${label}.policy`)
  assertAllowedKeys(value.inputContentIdentities, Object.keys(xcmEffectiveRegistryLocalInputs), `${label}.inputContentIdentities`)
  for (const inputName of Object.keys(xcmEffectiveRegistryLocalInputs)) {
    assertObjectMap(value.inputContentIdentities[inputName], report.inputs[inputName], `${label}.inputContentIdentities.${inputName}`)
  }
  if (report.inputs.discoveryRegistry === null) {
    if (value.discoveryRegistry !== null) fail(`${label}.discoveryRegistry must be null`)
  } else {
    assertObjectMap(value.discoveryRegistry, report.inputs.discoveryRegistry, `${label}.discoveryRegistry`)
  }
  const countFields = ['approved', 'effective', 'productionExecutable', 'missing', 'extra']
  assertAllowedKeys(value.counts, countFields, `${label}.counts`)
  for (const field of countFields) {
    requireNumber(value.counts[field], `${label}.counts.${field}`)
    if (value.counts[field] !== report.summary[field]) fail(`${label}.counts.${field} must match effective registry report`)
  }
  assertXcmEffectiveRegistryReport(report, `${label}.report`, runLive, workspaceRoot)
}

function assertXcmRegistryHandoff(value, label, blockerSlug, artifactByPath, runLive, workspaceRoot) {
  const expected = expectedXcmRegistryHandoff(blockerSlug)
  if (!expected) fail(`${label} is not supported on ${blockerSlug}`)
  assertAllowedKeys(value, [
    'sourceReportPath',
    'gapReportArtifact',
    'gapReportSha256',
    'registryFile',
    'requiredRouteFile',
    'discoveryGapFile',
    'generatedGapReportPath',
    'remainingDiscoveryOnlyDestinations',
    'remainingDiscoveryOnlyRouteAssets',
    'missingExecutableDestinationCount',
    'registryAuditCommand',
    'effectiveRegistry',
    'requiredContracts',
  ], label)
  for (const [key, expectedValue] of Object.entries(expected)) {
    if (key === 'requiredContracts') {
      assertExactStringArray(value[key], expectedValue, `${label}.${key}`)
      continue
    }
    requireSingleLine(value[key], `${label}.${key}`)
    assertNoSecretLike(`${label}.${key}`, value[key])
    if (value[key] !== expectedValue) fail(`${label}.${key} mismatch`)
  }
  requireString(value.gapReportSha256, `${label}.gapReportSha256`)
  if (!/^[a-f0-9]{64}$/.test(value.gapReportSha256)) fail(`${label}.gapReportSha256 must be lowercase SHA-256`)
  requireNumber(value.remainingDiscoveryOnlyDestinations, `${label}.remainingDiscoveryOnlyDestinations`)
  requireNumber(value.remainingDiscoveryOnlyRouteAssets, `${label}.remainingDiscoveryOnlyRouteAssets`)
  requireNumber(value.missingExecutableDestinationCount, `${label}.missingExecutableDestinationCount`)
  if (value.remainingDiscoveryOnlyDestinations !== value.missingExecutableDestinationCount) {
    fail(`${label}.remainingDiscoveryOnlyDestinations must match missingExecutableDestinationCount`)
  }
  const artifact = artifactByPath.get(value.gapReportArtifact)
  if (!artifact) fail(`${label}.gapReportArtifact missing from manifest artifacts`)
  if (artifact.sha256 !== value.gapReportSha256) fail(`${label}.gapReportSha256 does not match artifact checksum`)
  const report = readJson(value.gapReportArtifact, `${label}.gapReportArtifact`)
  assertXcmRegistryGapReport(report, `${label}.gapReport`)
  if (report.registryFile !== value.registryFile) fail(`${label}.registryFile must match gap report`)
  if (report.summary.remainingDiscoveryOnlyDestinations !== value.remainingDiscoveryOnlyDestinations) {
    fail(`${label}.remainingDiscoveryOnlyDestinations must match gap report`)
  }
  if (report.summary.remainingDiscoveryOnlyRouteAssets !== value.remainingDiscoveryOnlyRouteAssets) {
    fail(`${label}.remainingDiscoveryOnlyRouteAssets must match gap report`)
  }
  if (report.missingExecutableDestinations.length !== value.missingExecutableDestinationCount) {
    fail(`${label}.missingExecutableDestinationCount must match gap report`)
  }
  if (!value.effectiveRegistry || typeof value.effectiveRegistry !== 'object' || Array.isArray(value.effectiveRegistry)) {
    fail(`${label}.effectiveRegistry must be an object`)
  }
  const effectiveReport = readJson(value.effectiveRegistry.reportArtifact, `${label}.effectiveRegistry.reportArtifact`)
  assertXcmEffectiveRegistryHandoff(value.effectiveRegistry, `${label}.effectiveRegistry`, effectiveReport, runLive, artifactByPath, workspaceRoot)
}

assertRegularBundleDirectory(bundleRoot)
assertNoBundleRootSymlinkPrefix(bundleRoot)
assertRegularWorkspaceDirectory(configuredWorkspaceRoot)
assertNoWorkspaceRootSymlinkPrefix(configuredWorkspaceRoot)
assertFearlessWorkspaceRoot(configuredWorkspaceRoot)

const manifest = readJson('manifest.json', 'manifest.json')
const summary = readJson('summary.json', 'summary.json')
const actions = readJson('actions.json', 'actions.json')
for (const file of ['blockers.md', 'unblock.md', 'verify-blockers.sh']) {
  const absolute = assertRegularBundleFile(file, file)
  assertNoSecretLike(file, fs.readFileSync(absolute, 'utf8'))
}

assertAllowedKeys(manifest, ['schemaVersion', 'generatedAt', 'sourceReportDir', 'status', 'runLive', 'totals', 'blockerCount', 'blockers', 'sourcePublicationHandoff', 'artifacts'], 'manifest')
assertAllowedKeys(summary, ['schemaVersion', 'generatedAt', 'runLive', 'status', 'totals', 'checks'], 'summary')
assertAllowedKeys(actions, ['schemaVersion', 'generatedAt', 'runLive', 'status', 'totals', 'blockers'], 'actions manifest')

if (manifest.schemaVersion !== 3 || summary.schemaVersion !== 1 || actions.schemaVersion !== 1) {
  fail('manifest must use schemaVersion 3; summary and actions must use schemaVersion 1')
}
const nowMs = process.env.RELEASE_UNBLOCK_VERIFY_NOW
  ? parseUtcSecondsTimestamp(process.env.RELEASE_UNBLOCK_VERIFY_NOW, 'RELEASE_UNBLOCK_VERIFY_NOW')
  : Date.now()
const futureSkewMs = 5 * 60 * 1000
const manifestGeneratedAtMs = parseUtcSecondsTimestamp(manifest.generatedAt, 'manifest.generatedAt')
const summaryGeneratedAtMs = parseUtcSecondsTimestamp(summary.generatedAt, 'summary.generatedAt')
const actionsGeneratedAtMs = parseUtcSecondsTimestamp(actions.generatedAt, 'actions.generatedAt')
if (summary.generatedAt !== actions.generatedAt) {
  fail(`summary/actions generatedAt mismatch: ${summary.generatedAt} != ${actions.generatedAt}`)
}
assertNotFutureTimestamp(summaryGeneratedAtMs, summary.generatedAt, 'summary.generatedAt', nowMs, futureSkewMs)
assertNotFutureTimestamp(actionsGeneratedAtMs, actions.generatedAt, 'actions.generatedAt', nowMs, futureSkewMs)
if (manifestGeneratedAtMs < summaryGeneratedAtMs) {
  fail(`manifest.generatedAt must not be earlier than summary/actions generatedAt: ${manifest.generatedAt} < ${summary.generatedAt}`)
}
assertNotFutureTimestamp(manifestGeneratedAtMs, manifest.generatedAt, 'manifest.generatedAt', nowMs, futureSkewMs)
if (maxAgeHoursArg) {
  const maxAgeHours = parsePositiveInteger(maxAgeHoursArg, '--max-age-hours')
  const maxAgeMs = maxAgeHours * 60 * 60 * 1000
  const bundleAgeMs = nowMs - manifestGeneratedAtMs
  if (bundleAgeMs > maxAgeMs) {
    fail(`bundle generated at ${manifest.generatedAt} is older than --max-age-hours ${maxAgeHours}`)
  }
  const reportAgeMs = nowMs - summaryGeneratedAtMs
  if (reportAgeMs > maxAgeMs) {
    fail(`report generated at ${summary.generatedAt} is older than --max-age-hours ${maxAgeHours}`)
  }
}
const workspaceRoot = normalizeAbsolutePath(configuredWorkspaceRoot, 'workspace root')
const sourceReportDir = assertInsideWorkspaceRoot(manifest.sourceReportDir, 'manifest.sourceReportDir', workspaceRoot)
requireBoolean(manifest.runLive, 'manifest.runLive')
if (manifest.status !== summary.status || manifest.status !== actions.status) {
  fail(`status mismatch across manifest/summary/actions: ${manifest.status}/${summary.status}/${actions.status}`)
}
if (manifest.runLive !== summary.runLive || manifest.runLive !== actions.runLive) {
  fail('runLive mismatch across manifest/summary/actions')
}
assertTotals(manifest.totals, 'manifest.totals')
assertTotals(summary.totals, 'summary.totals')
assertTotals(actions.totals, 'actions.totals')
for (const key of ['passed', 'failed', 'skipped', 'total']) {
  if (manifest.totals[key] !== summary.totals[key] || manifest.totals[key] !== actions.totals[key]) {
    fail(`totals mismatch for ${key}`)
  }
}
assertOverallStatus(manifest.status, manifest.totals, manifest.runLive, 'release status')

if (!Array.isArray(manifest.blockers)) fail('manifest.blockers must be an array')
if (!Array.isArray(actions.blockers)) fail('actions.blockers must be an array')
if (!Array.isArray(manifest.artifacts)) fail('manifest.artifacts must be an array')
if (!Array.isArray(summary.checks)) fail('summary.checks must be an array')
requireNumber(manifest.blockerCount, 'manifest.blockerCount')
if (manifest.blockerCount !== manifest.blockers.length) {
  fail(`manifest blockerCount mismatch: ${manifest.blockerCount} != ${manifest.blockers.length}`)
}
if (manifest.totals.failed !== manifest.blockerCount || actions.totals.failed !== actions.blockers.length) {
  fail('failed total must match blocker count')
}

const artifactKeys = ['path', 'sourcePath', 'sha256', 'bytes']
const artifactByPath = new Map()
const sourcePublicationArtifactPaths = new Set([
  sourcePublicationReportArtifactPath,
  sourcePublicationPreflightReportArtifactPath,
  sourcePublicationConfigArtifactPath,
  sourcePublicationRootOwnerConfigArtifactPath,
])
const sourcePublicationArtifactSnapshots = new Map()
for (const artifact of manifest.artifacts) {
  assertAllowedKeys(artifact, artifactKeys, 'manifest artifact')
  const relativePath = normalizeRelativePath(artifact.path, 'artifact.path')
  const expectedWorkspaceSourcePath = expectedWorkspaceSourcePathForArtifact(relativePath, workspaceRoot)
  let sourcePath
  if (expectedWorkspaceSourcePath) {
    sourcePath = normalizeAbsolutePath(artifact.sourcePath, `${relativePath}.sourcePath`)
    if (sourcePath !== expectedWorkspaceSourcePath) {
      fail(`${relativePath}.sourcePath must match workspace source artifact path`)
    }
  } else {
    sourcePath = assertInsideSourceReportDir(artifact.sourcePath, `${relativePath}.sourcePath`, sourceReportDir)
    const expectedSourcePath = expectedSourcePathForArtifact(relativePath, sourceReportDir)
    if (expectedSourcePath && sourcePath !== expectedSourcePath) {
      fail(`${relativePath}.sourcePath must match report artifact path`)
    }
  }
  requireString(artifact.sha256, `${relativePath}.sha256`)
  if (!/^[a-f0-9]{64}$/.test(artifact.sha256)) fail(`${relativePath}.sha256 must be lowercase SHA-256`)
  requireNumber(artifact.bytes, `${relativePath}.bytes`)
  if (artifactByPath.has(relativePath)) fail(`duplicate manifest artifact path: ${relativePath}`)
  const absolute = safeBundlePath(relativePath, `${relativePath} artifact path`)
  if (!fs.existsSync(absolute)) fail(`manifest artifact missing: ${relativePath}`)
  if (!fs.lstatSync(absolute).isFile()) fail(`manifest artifact must be a regular file: ${relativePath}`)
  const content = fs.readFileSync(absolute)
  if (sourcePublicationArtifactPaths.has(relativePath)) {
    assertNoSecretLike(relativePath, content.toString('utf8'))
  }
  if (relativePath === sourcePublicationReportArtifactPath) {
    let report
    try {
      report = JSON.parse(content.toString('utf8'))
    } catch (error) {
      fail(`${relativePath} is not valid JSON: ${error.message}`)
    }
    assertSourcePublicationReport(report, relativePath, 'postflight', workspaceRoot, summaryGeneratedAtMs, nowMs)
  } else if (relativePath === sourcePublicationPreflightReportArtifactPath) {
    let report
    try {
      report = JSON.parse(content.toString('utf8'))
    } catch (error) {
      fail(`${relativePath} is not valid JSON: ${error.message}`)
    }
    assertSourcePublicationReport(report, relativePath, 'preflight', workspaceRoot, null, nowMs)
  } else if (relativePath === sourcePublicationConfigArtifactPath) {
    assertSourcePublicationConfig(content.toString('utf8'), relativePath)
  } else if (relativePath === sourcePublicationRootOwnerConfigArtifactPath) {
    let config
    try {
      config = JSON.parse(content.toString('utf8'))
    } catch (error) {
      fail(`${relativePath} is not valid JSON: ${error.message}`)
    }
    assertSourcePublicationRootOwnerConfig(config, relativePath, nowMs)
  } else if (relativePath === releasePrStatusReportArtifactPath) {
    let report
    try {
      report = JSON.parse(content.toString('utf8'))
    } catch (error) {
      fail(`${relativePath} is not valid JSON: ${error.message}`)
    }
    assertReleasePrStatusReport(report, relativePath)
  } else if (relativePath === bitcoinBroadcastTemplateArtifactPath) {
    let template
    try {
      template = JSON.parse(content.toString('utf8'))
    } catch (error) {
      fail(`${relativePath} is not valid JSON: ${error.message}`)
    }
    assertBitcoinBroadcastEvidenceTemplate(template, relativePath)
  } else if (relativePath === xcmProductionEvidenceTemplateArtifactPath) {
    let template
    try {
      template = JSON.parse(content.toString('utf8'))
    } catch (error) {
      fail(`${relativePath} is not valid JSON: ${error.message}`)
    }
    assertXcmProductionEvidenceTemplate(template, relativePath)
  } else if (relativePath === xcmEffectiveRegistryArtifactPath) {
    let report
    try {
      report = JSON.parse(content.toString('utf8'))
    } catch (error) {
      fail(`${relativePath} is not valid JSON: ${error.message}`)
    }
    assertXcmEffectiveRegistryReport(report, relativePath, manifest.runLive, workspaceRoot)
  } else if (relativePath === nexusProductionEvidenceTemplateArtifactPath) {
    let template
    try {
      template = JSON.parse(content.toString('utf8'))
    } catch (error) {
      fail(`${relativePath} is not valid JSON: ${error.message}`)
    }
    assertNexusProductionEvidenceTemplate(template, relativePath)
  } else if (relativePath === passkeyDeploymentTemplateArtifactPath) {
    let template
    try {
      template = JSON.parse(content.toString('utf8'))
    } catch (error) {
      fail(`${relativePath} is not valid JSON: ${error.message}`)
    }
    assertPasskeyDeploymentEvidenceTemplate(template, relativePath)
  } else if (relativePath === passkeyProductionConfigArtifactPath) {
    let config
    try {
      config = JSON.parse(content.toString('utf8'))
    } catch (error) {
      fail(`${relativePath} is not valid JSON: ${error.message}`)
    }
    assertPasskeyProductionConfig(config, relativePath)
  } else if (relativePath === passkeyOpenApiArtifactPath) {
    let openApi
    try {
      openApi = JSON.parse(content.toString('utf8'))
    } catch (error) {
      fail(`${relativePath} is not valid JSON: ${error.message}`)
    }
    assertPasskeyOpenApi(openApi, relativePath)
  } else if (relativePath === passkeyProductionComposeArtifactPath) {
    assertPasskeyProductionCompose(content.toString('utf8'), relativePath)
  } else if (indexerDeploymentTemplateArtifacts.has(relativePath)) {
    const { config } = indexerDeploymentTemplateArtifacts.get(relativePath)
    let template
    try {
      template = JSON.parse(content.toString('utf8'))
    } catch (error) {
      fail(`${relativePath} is not valid JSON: ${error.message}`)
    }
    assertIndexerDeploymentEvidenceTemplate(template, relativePath, config)
  } else {
    assertNoSecretLike(relativePath, content.toString('utf8'))
  }
  if (expectedWorkspaceSourcePath) {
    assertNoRootSymlinkPathPrefix(expectedWorkspaceSourcePath, `${relativePath}.workspaceSourcePath`)
    if (!fs.existsSync(expectedWorkspaceSourcePath) || !fs.lstatSync(expectedWorkspaceSourcePath).isFile()) {
      fail(`${relativePath} workspace source artifact must be a regular file`)
    }
    const workspaceSourceContent = fs.readFileSync(expectedWorkspaceSourcePath)
    if (sha256(workspaceSourceContent) !== sha256(content)) {
      fail(`${relativePath} does not match workspace source artifact`)
    }
  }
  if (content.length !== artifact.bytes) fail(`${relativePath} bytes mismatch`)
  if (sha256(content) !== artifact.sha256) fail(`${relativePath} SHA-256 mismatch`)
  if (sourcePublicationArtifactPaths.has(relativePath)) sourcePublicationArtifactSnapshots.set(relativePath, content)
  artifactByPath.set(relativePath, { ...artifact, sourcePath })
}

for (const requiredArtifact of ['summary.json', 'actions.json', 'blockers.md']) {
  if (!artifactByPath.has(requiredArtifact)) fail(`manifest missing required artifact: ${requiredArtifact}`)
}

const coreArtifactPaths = new Set(['summary.json', 'actions.json', 'blockers.md'])
const referencedArtifactPaths = new Set(coreArtifactPaths)
function markReferencedArtifact(relativePath, label) {
  referencedArtifactPaths.add(normalizeRelativePath(relativePath, label))
}

let sourcePublicationReportForClassification = null
if (manifest.runLive) {
  if (!manifest.sourcePublicationHandoff || typeof manifest.sourcePublicationHandoff !== 'object' || Array.isArray(manifest.sourcePublicationHandoff)) {
    fail('manifest.sourcePublicationHandoff required for full-live bundle')
  }
  const sourceReportBytes = sourcePublicationArtifactSnapshots.get(sourcePublicationReportArtifactPath)
  const preflightReportBytes = sourcePublicationArtifactSnapshots.get(sourcePublicationPreflightReportArtifactPath)
  const rootOwnerConfigBytes = sourcePublicationArtifactSnapshots.get(sourcePublicationRootOwnerConfigArtifactPath)
  if (!sourceReportBytes || !preflightReportBytes || !rootOwnerConfigBytes) fail('source publication artifact snapshots missing')
  const sourceReport = parseJson(sourceReportBytes, sourcePublicationReportArtifactPath)
  const preflightReport = parseJson(preflightReportBytes, sourcePublicationPreflightReportArtifactPath)
  sourcePublicationReportForClassification = sourceReport
  const rootOwnerConfig = parseJson(rootOwnerConfigBytes, sourcePublicationRootOwnerConfigArtifactPath)
  const releasePrConfigSource = path.join(workspaceRoot, releasePrConfigPath)
  assertNoRootSymlinkPathPrefix(releasePrConfigSource, 'source publication release PR config')
  if (!fs.existsSync(releasePrConfigSource) || !fs.lstatSync(releasePrConfigSource).isFile()) fail('source publication release PR config must be a regular file')
  const releasePrConfigContent = fs.readFileSync(releasePrConfigSource, 'utf8')
  assertNoSecretLike('source publication release PR config', releasePrConfigContent)
  const releasePrRows = parseSourcePublicationReleasePrConfig(releasePrConfigContent, 'source publication release PR config')
  assertSourcePublicationReport(sourceReport, sourcePublicationReportArtifactPath, 'postflight', workspaceRoot, summaryGeneratedAtMs, nowMs)
  assertSourcePublicationReport(preflightReport, sourcePublicationPreflightReportArtifactPath, 'preflight', workspaceRoot, null, nowMs)
  assertSourcePublicationPair(preflightReport, sourceReport, preflightReportBytes, 'manifest.sourcePublicationHandoff')
  assertSourcePublicationRootOwnerConfig(rootOwnerConfig, sourcePublicationRootOwnerConfigArtifactPath, nowMs)
  assertSourcePublicationRootOwnerBinding(sourceReport, rootOwnerConfig, releasePrRows, 'manifest.sourcePublicationHandoff')
  assertSourcePublicationHandoff(manifest.sourcePublicationHandoff, sourceReport, rootOwnerConfig, summary, artifactByPath, 'manifest.sourcePublicationHandoff')
  markReferencedArtifact(manifest.sourcePublicationHandoff.reportArtifact, 'manifest.sourcePublicationHandoff.reportArtifact')
  markReferencedArtifact(manifest.sourcePublicationHandoff.preflightReportArtifact, 'manifest.sourcePublicationHandoff.preflightReportArtifact')
  markReferencedArtifact(manifest.sourcePublicationHandoff.configArtifact, 'manifest.sourcePublicationHandoff.configArtifact')
  markReferencedArtifact(manifest.sourcePublicationHandoff.rootOwnerConfigArtifact, 'manifest.sourcePublicationHandoff.rootOwnerConfigArtifact')
} else if (manifest.sourcePublicationHandoff !== null) {
  fail('manifest.sourcePublicationHandoff must be null when live checks were skipped')
}

const blockerKeys = ['name', 'slug', 'requiresExternalAction', 'unblockCategory', 'externalPrerequisite', 'recommendedAction', 'verificationCommand', 'evidencePreview', 'sourceLog', 'logArtifact', 'logSha256', 'outdatedReviewThreadResolution', 'releasePrApprovalHandoff', 'releasePrStatusReportHandoff', 'releasePrMergeHandoff', 'evidenceTemplateCommands', 'evidenceTemplateHandoff', 'bitcoinBroadcastTemplateHandoff', 'passkeyDeploymentTemplateHandoff', 'passkeyProductionContractHandoff', 'indexerDeploymentTemplateHandoff', 'nexusProductionEvidenceTemplateHandoff', 'xcmProductionEvidenceTemplateHandoff', 'liveServiceHandoff', 'xcmRegistryHandoff']
const actionKeys = ['name', 'slug', 'exitCode', 'logFile', 'recommendedAction', 'requiresExternalAction', 'unblockCategory', 'externalPrerequisite', 'verificationCommand', 'evidencePreview']
const actionsBySlug = new Map()
const actionUnblockVariantsBySlug = new Map()
for (const action of actions.blockers) {
  assertAllowedKeys(action, actionKeys, 'action blocker')
  requireSingleLine(action.name, 'action.name')
  assertNoSecretLike('action.name', action.name)
  requireString(action.slug, 'action.slug')
  if (!/^[a-z0-9][a-z0-9-]*$/.test(action.slug)) fail(`action.slug has unsupported format: ${action.slug}`)
  if (actionsBySlug.has(action.slug)) fail(`duplicate action blocker slug: ${action.slug}`)
  assertExpectedCheckName(action.slug, action.name, `${action.slug}.name`)
  assertFailedBlockerExitCode(action.exitCode, `${action.slug}.exitCode`)
  requireString(action.logFile, `${action.slug}.logFile`)
  requireSingleLine(action.recommendedAction, `${action.slug}.recommendedAction`)
  requireBoolean(action.requiresExternalAction, `${action.slug}.requiresExternalAction`)
  assertUnblockCategory(action.unblockCategory, `${action.slug}.unblockCategory`)
  requireSingleLine(action.externalPrerequisite, `${action.slug}.externalPrerequisite`)
  const unblockContractVariant = assertExpectedBlockerUnblockContract(
    action.slug,
    action.recommendedAction,
    action.requiresExternalAction,
    action.unblockCategory,
    action.externalPrerequisite,
    action.slug,
  )
  requireSingleLine(action.verificationCommand, `${action.slug}.verificationCommand`)
  assertExpectedVerificationCommand(action.slug, action.verificationCommand, `${action.slug}.verificationCommand`)
  requireString(action.evidencePreview, `${action.slug}.evidencePreview`)
  assertNoSecretLike(`${action.slug}.recommendedAction`, action.recommendedAction)
  assertNoSecretLike(`${action.slug}.unblockCategory`, action.unblockCategory)
  assertNoSecretLike(`${action.slug}.externalPrerequisite`, action.externalPrerequisite)
  assertNoSecretLike(`${action.slug}.verificationCommand`, action.verificationCommand)
  assertNoSecretLike(`${action.slug}.evidencePreview`, action.evidencePreview)
  actionsBySlug.set(action.slug, action)
  actionUnblockVariantsBySlug.set(action.slug, unblockContractVariant)
}
assertSummaryChecks(summary, actionsBySlug, sourceReportDir)

const seenBlockers = new Set()
const manifestBlockerSlugs = []
for (const blocker of manifest.blockers) {
  assertAllowedKeys(blocker, blockerKeys, 'manifest blocker')
  requireSingleLine(blocker.name, 'blocker.name')
  assertNoSecretLike('blocker.name', blocker.name)
  requireString(blocker.slug, 'blocker.slug')
  if (!/^[a-z0-9][a-z0-9-]*$/.test(blocker.slug)) fail(`blocker.slug has unsupported format: ${blocker.slug}`)
  if (seenBlockers.has(blocker.slug)) fail(`duplicate blocker slug: ${blocker.slug}`)
  seenBlockers.add(blocker.slug)
  manifestBlockerSlugs.push(blocker.slug)
  requireBoolean(blocker.requiresExternalAction, `${blocker.slug}.requiresExternalAction`)
  assertUnblockCategory(blocker.unblockCategory, `${blocker.slug}.unblockCategory`)
  requireSingleLine(blocker.externalPrerequisite, `${blocker.slug}.externalPrerequisite`)
  requireSingleLine(blocker.recommendedAction, `${blocker.slug}.recommendedAction`)
  requireSingleLine(blocker.verificationCommand, `${blocker.slug}.verificationCommand`)
  requireString(blocker.evidencePreview, `${blocker.slug}.evidencePreview`)
  const sourceLog = assertInsideSourceReportDir(blocker.sourceLog, `${blocker.slug}.sourceLog`, sourceReportDir)
  const logArtifact = normalizeRelativePath(blocker.logArtifact, `${blocker.slug}.logArtifact`)
  if (logArtifact !== `logs/${blocker.slug}.log`) fail(`${blocker.slug}.logArtifact must be logs/${blocker.slug}.log`)
  markReferencedArtifact(logArtifact, `${blocker.slug}.logArtifact`)
  requireString(blocker.logSha256, `${blocker.slug}.logSha256`)
  if (!/^[a-f0-9]{64}$/.test(blocker.logSha256)) fail(`${blocker.slug}.logSha256 must be lowercase SHA-256`)
  const logRecord = artifactByPath.get(logArtifact)
  if (!logRecord) fail(`${blocker.slug}.logArtifact missing from manifest artifacts`)
  if (logRecord.sha256 !== blocker.logSha256) fail(`${blocker.slug}.logSha256 does not match artifact checksum`)
  if (logRecord.sourcePath !== sourceLog) fail(`${blocker.slug}.sourceLog must match log artifact sourcePath`)
  const logContent = readBundleFile(logArtifact, `${blocker.slug}.logArtifact content`, 'utf8')
  assertEvidencePreviewMatchesLog(
    blocker.evidencePreview,
    logContent,
    `${blocker.slug}.evidencePreview`,
  )
  if (blocker.slug === 'plan-readiness') {
    const expectedVariant = isExternalIrohaOnlyPlanReadinessLog(logContent, sourcePublicationReportForClassification)
      ? 'external-iroha-only'
      : 'local'
    if (actionUnblockVariantsBySlug.get(blocker.slug) !== expectedVariant) {
      fail(`${blocker.slug} unblock contract variant must match plan-readiness log classification`)
    }
  }
  const action = actionsBySlug.get(blocker.slug)
  if (!action) fail(`${blocker.slug} missing from actions.json blockers`)
  const actionLogFile = resolveSourceReportPath(action.logFile, `${blocker.slug}.action.logFile`, sourceReportDir)
  if (sourceLog !== actionLogFile) fail(`${blocker.slug}.sourceLog must match actions.json logFile`)
  for (const key of ['name', 'recommendedAction', 'requiresExternalAction', 'unblockCategory', 'externalPrerequisite', 'verificationCommand', 'evidencePreview']) {
    if (action[key] !== blocker[key]) fail(`${blocker.slug}.${key} mismatch between manifest and actions.json`)
  }
  assertNoSecretLike(`${blocker.slug}.unblockCategory`, blocker.unblockCategory)
  assertNoSecretLike(`${blocker.slug}.externalPrerequisite`, blocker.externalPrerequisite)
  assertNoSecretLike(`${blocker.slug}.recommendedAction`, blocker.recommendedAction)
  assertNoSecretLike(`${blocker.slug}.verificationCommand`, blocker.verificationCommand)
  assertNoSecretLike(`${blocker.slug}.evidencePreview`, blocker.evidencePreview)
  if (blocker.outdatedReviewThreadResolution !== undefined) {
    assertOutdatedReviewThreadResolution(blocker.outdatedReviewThreadResolution, `${blocker.slug}.outdatedReviewThreadResolution`, blocker.slug)
  }
  if (blocker.releasePrApprovalHandoff !== undefined) {
    assertReleasePrApprovalHandoff(blocker.releasePrApprovalHandoff, `${blocker.slug}.releasePrApprovalHandoff`, blocker.slug)
  } else if (blocker.slug === 'release-pr-readiness') {
    const report = readJson(releasePrStatusReportArtifactPath, `${blocker.slug}.releasePrApprovalHandoff.statusReportArtifact`)
    assertReleasePrStatusReport(report, releasePrStatusReportArtifactPath)
    if (releasePrApprovalRecordsFromStatusReport(report).length > 0) fail(`${blocker.slug}.releasePrApprovalHandoff missing`)
  }
  if (blocker.releasePrStatusReportHandoff !== undefined) {
    assertReleasePrStatusReportHandoff(blocker.releasePrStatusReportHandoff, `${blocker.slug}.releasePrStatusReportHandoff`, blocker.slug, artifactByPath, logContent)
    markReferencedArtifact(blocker.releasePrStatusReportHandoff.reportArtifact, `${blocker.slug}.releasePrStatusReportHandoff.reportArtifact`)
  } else if (blocker.slug === 'release-pr-readiness') {
    fail(`${blocker.slug}.releasePrStatusReportHandoff missing`)
  }
  if (blocker.releasePrMergeHandoff !== undefined) {
    assertReleasePrMergeHandoff(blocker.releasePrMergeHandoff, `${blocker.slug}.releasePrMergeHandoff`, blocker.slug)
  } else if (blocker.slug === 'release-pr-readiness') {
    fail(`${blocker.slug}.releasePrMergeHandoff missing`)
  }
  if (blocker.evidenceTemplateCommands !== undefined) {
    assertEvidenceTemplateCommands(blocker.evidenceTemplateCommands, `${blocker.slug}.evidenceTemplateCommands`, blocker.slug)
  } else if (expectedEvidenceTemplateCommands(blocker.slug)) {
    fail(`${blocker.slug}.evidenceTemplateCommands missing`)
  }
  if (blocker.evidenceTemplateHandoff !== undefined) {
    assertEvidenceTemplateHandoff(blocker.evidenceTemplateHandoff, `${blocker.slug}.evidenceTemplateHandoff`, blocker.slug)
  } else if (expectedEvidenceTemplateHandoff(blocker.slug)) {
    fail(`${blocker.slug}.evidenceTemplateHandoff missing`)
  }
  if (blocker.bitcoinBroadcastTemplateHandoff !== undefined) {
    assertBitcoinBroadcastTemplateHandoff(blocker.bitcoinBroadcastTemplateHandoff, `${blocker.slug}.bitcoinBroadcastTemplateHandoff`, blocker.slug, artifactByPath)
    markReferencedArtifact(blocker.bitcoinBroadcastTemplateHandoff.templateArtifact, `${blocker.slug}.bitcoinBroadcastTemplateHandoff.templateArtifact`)
  } else if (expectedBitcoinBroadcastTemplateHandoff(blocker.slug)) {
    fail(`${blocker.slug}.bitcoinBroadcastTemplateHandoff missing`)
  }
  if (blocker.passkeyDeploymentTemplateHandoff !== undefined) {
    assertPasskeyDeploymentTemplateHandoff(blocker.passkeyDeploymentTemplateHandoff, `${blocker.slug}.passkeyDeploymentTemplateHandoff`, blocker.slug, artifactByPath)
    markReferencedArtifact(blocker.passkeyDeploymentTemplateHandoff.templateArtifact, `${blocker.slug}.passkeyDeploymentTemplateHandoff.templateArtifact`)
  } else if (expectedPasskeyDeploymentTemplateHandoff(blocker.slug)) {
    fail(`${blocker.slug}.passkeyDeploymentTemplateHandoff missing`)
  }
  if (blocker.passkeyProductionContractHandoff !== undefined) {
    assertPasskeyProductionContractHandoff(blocker.passkeyProductionContractHandoff, `${blocker.slug}.passkeyProductionContractHandoff`, blocker.slug, artifactByPath)
    markReferencedArtifact(blocker.passkeyProductionContractHandoff.productionConfigArtifact, `${blocker.slug}.passkeyProductionContractHandoff.productionConfigArtifact`)
    markReferencedArtifact(blocker.passkeyProductionContractHandoff.openApiArtifact, `${blocker.slug}.passkeyProductionContractHandoff.openApiArtifact`)
    markReferencedArtifact(blocker.passkeyProductionContractHandoff.composeArtifact, `${blocker.slug}.passkeyProductionContractHandoff.composeArtifact`)
  } else if (expectedPasskeyProductionContractHandoff(blocker.slug)) {
    fail(`${blocker.slug}.passkeyProductionContractHandoff missing`)
  }
  if (blocker.indexerDeploymentTemplateHandoff !== undefined) {
    assertIndexerDeploymentTemplateHandoff(blocker.indexerDeploymentTemplateHandoff, `${blocker.slug}.indexerDeploymentTemplateHandoff`, blocker.slug, artifactByPath)
    markReferencedArtifact(blocker.indexerDeploymentTemplateHandoff.templateArtifact, `${blocker.slug}.indexerDeploymentTemplateHandoff.templateArtifact`)
  } else if (expectedIndexerDeploymentTemplateHandoff(blocker.slug)) {
    fail(`${blocker.slug}.indexerDeploymentTemplateHandoff missing`)
  }
  if (blocker.nexusProductionEvidenceTemplateHandoff !== undefined) {
    assertNexusProductionEvidenceTemplateHandoff(blocker.nexusProductionEvidenceTemplateHandoff, `${blocker.slug}.nexusProductionEvidenceTemplateHandoff`, blocker.slug, artifactByPath)
    markReferencedArtifact(blocker.nexusProductionEvidenceTemplateHandoff.templateArtifact, `${blocker.slug}.nexusProductionEvidenceTemplateHandoff.templateArtifact`)
  } else if (expectedNexusProductionEvidenceTemplateHandoff(blocker.slug)) {
    fail(`${blocker.slug}.nexusProductionEvidenceTemplateHandoff missing`)
  }
  if (blocker.xcmProductionEvidenceTemplateHandoff !== undefined) {
    assertXcmProductionEvidenceTemplateHandoff(blocker.xcmProductionEvidenceTemplateHandoff, `${blocker.slug}.xcmProductionEvidenceTemplateHandoff`, blocker.slug, artifactByPath)
    markReferencedArtifact(blocker.xcmProductionEvidenceTemplateHandoff.templateArtifact, `${blocker.slug}.xcmProductionEvidenceTemplateHandoff.templateArtifact`)
  } else if (expectedXcmProductionEvidenceTemplateHandoff(blocker.slug)) {
    fail(`${blocker.slug}.xcmProductionEvidenceTemplateHandoff missing`)
  }
  if (blocker.liveServiceHandoff !== undefined) {
    assertLiveServiceHandoff(blocker.liveServiceHandoff, `${blocker.slug}.liveServiceHandoff`, blocker.slug)
  } else if (expectedLiveServiceHandoff(blocker.slug)) {
    fail(`${blocker.slug}.liveServiceHandoff missing`)
  }
  if (blocker.xcmRegistryHandoff !== undefined) {
    assertXcmRegistryHandoff(blocker.xcmRegistryHandoff, `${blocker.slug}.xcmRegistryHandoff`, blocker.slug, artifactByPath, manifest.runLive, workspaceRoot)
    markReferencedArtifact(blocker.xcmRegistryHandoff.gapReportArtifact, `${blocker.slug}.xcmRegistryHandoff.gapReportArtifact`)
    markReferencedArtifact(blocker.xcmRegistryHandoff.effectiveRegistry.reportArtifact, `${blocker.slug}.xcmRegistryHandoff.effectiveRegistry.reportArtifact`)
  } else if (expectedXcmRegistryHandoff(blocker.slug)) {
    fail(`${blocker.slug}.xcmRegistryHandoff missing`)
  }
}

for (const artifactPath of artifactByPath.keys()) {
  if (!referencedArtifactPaths.has(artifactPath)) fail(`${artifactPath} has no matching blocker handoff`)
}

const actionBlockerSlugs = [...actionsBySlug.keys()]
if (seenBlockers.size !== actionBlockerSlugs.length) fail('manifest/actions blocker sets differ')
if (manifestBlockerSlugs.join('\n') !== actionBlockerSlugs.join('\n')) fail('manifest blockers must match actions.json blocker order')

const verifyScriptPath = assertRegularBundleFile('verify-blockers.sh', 'verify-blockers.sh')
const verifyScriptStat = fs.statSync(verifyScriptPath)
if ((verifyScriptStat.mode & 0o111) === 0) fail('verify-blockers.sh must be executable')
const expectedVerifyScript = renderVerifyScript(manifest.blockers, workspaceRoot)
const actualVerifyScript = fs.readFileSync(verifyScriptPath, 'utf8')
if (actualVerifyScript !== expectedVerifyScript) {
  fail('verify-blockers.sh does not match manifest blockers')
}

const expectedUnblockMarkdown = renderUnblockMarkdown(manifest, publishedBundleRoot)
const actualUnblockMarkdown = fs.readFileSync(assertRegularBundleFile('unblock.md', 'unblock.md'), 'utf8')
const commonBlockerMetadata = [
  ['slug', '- Slug: '],
  ['external-action', '- Requires external action: '],
  ['unblock-category', '- Unblock category: '],
  ['external-prerequisite', '- External prerequisite: '],
]
assertBlockerMetadataLineCounts(actualUnblockMarkdown, 'unblock.md', manifest.blockerCount, [
  ...commonBlockerMetadata,
  ['log', '- Log: '],
  ['log-sha256', '- Log SHA-256: '],
  ['recommended-action', 'Recommended action:'],
  ['verification-command', 'Verification command:'],
])
if (actualUnblockMarkdown !== expectedUnblockMarkdown) {
  fail('unblock.md does not match manifest blockers')
}

const expectedBlockerReportMarkdown = renderBlockerReportMarkdown(summary, actions)
const actualBlockerReportMarkdown = fs.readFileSync(assertRegularBundleFile('blockers.md', 'blockers.md'), 'utf8')
assertBlockerMetadataLineCounts(actualBlockerReportMarkdown, 'blockers.md', actions.blockers.length, [
  ...commonBlockerMetadata,
  ['exit-code', '- Exit code: '],
  ['log', '- Log: '],
  ['recommended-action', '- Recommended action: '],
  ['verification-command', '- Verification command: '],
])
if (actualBlockerReportMarkdown !== expectedBlockerReportMarkdown) {
  fail('blockers.md does not match summary/actions blockers')
}

const checksumEntries = parseChecksums()
const checksumByPath = new Map()
for (const entry of checksumEntries) checksumByPath.set(entry.path, entry.sha256)
const expectedChecksumPaths = new Set(['manifest.json', 'unblock.md', 'verify-blockers.sh', ...artifactByPath.keys()])
for (const expected of expectedChecksumPaths) {
  if (!checksumByPath.has(expected)) fail(`SHA256SUMS missing expected path: ${expected}`)
}
for (const entry of checksumEntries) {
  if (!expectedChecksumPaths.has(entry.path)) fail(`SHA256SUMS contains unexpected path: ${entry.path}`)
  const manifestArtifact = artifactByPath.get(entry.path)
  if (manifestArtifact && entry.sha256 !== manifestArtifact.sha256) {
    fail(`${entry.path} SHA256SUMS digest does not match manifest artifact`)
  }
  const absolute = assertRegularBundleFile(entry.path, `${entry.path} checksum path`)
  const admittedSnapshot = sourcePublicationArtifactSnapshots.get(entry.path)
  const digest = admittedSnapshot ? sha256(admittedSnapshot) : sha256(fs.readFileSync(absolute))
  if (digest !== entry.sha256) fail(`${entry.path} checksum mismatch`)
}

const actualFiles = new Set(listFiles(bundleRoot).map((file) => path.relative(bundleRoot, file).split(path.sep).join('/')))
const expectedFiles = new Set([...expectedChecksumPaths, 'SHA256SUMS'])
for (const file of actualFiles) {
  if (!expectedFiles.has(file)) fail(`bundle contains unchecked file: ${file}`)
}
for (const file of expectedFiles) {
  if (!actualFiles.has(file)) fail(`bundle missing expected file: ${file}`)
}
const actualDirectories = new Set(listDirectories(bundleRoot).map((directory) => path.relative(bundleRoot, directory).split(path.sep).join('/')))
const expectedDirectories = new Set()
for (const file of expectedFiles) {
  let directory = path.posix.dirname(file)
  while (directory && directory !== '.') {
    expectedDirectories.add(directory)
    directory = path.posix.dirname(directory)
  }
}
for (const directory of actualDirectories) {
  if (!expectedDirectories.has(directory)) fail(`bundle contains unchecked directory: ${directory}`)
}

const normalizedChecksumLines = [...expectedChecksumPaths]
  .map((relativePath) => `${checksumByPath.get(relativePath)}  ${relativePath}`)
  .sort()
  .join('\n') + '\n'
const checksumContent = fs.readFileSync(assertRegularBundleFile('SHA256SUMS', 'SHA256SUMS'), 'utf8')
if (checksumContent !== normalizedChecksumLines) fail('SHA256SUMS is not sorted or does not match bundle contents')

console.log(`[release-unblock-bundle-verify] Bundle verified: ${bundleRoot}`)
NODE
