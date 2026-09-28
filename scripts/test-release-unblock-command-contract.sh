#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

fail() {
  echo "[release-unblock-command-contract-test][error] $*" >&2
  exit 1
}

run_contract_check() {
  local audit_script="$1"
  local export_script="$2"
  local verify_script="$3"

  node - "$audit_script" "$export_script" "$verify_script" <<'NODE'
const fs = require('fs')
const path = require('path')

const [auditFile, exportFile, verifyFile] = process.argv.slice(2)

function fail(message) {
  console.error(`[release-unblock-command-contract-test][error] ${message}`)
  process.exit(1)
}

function read(file) {
  try {
    return fs.readFileSync(file, 'utf8')
  } catch (error) {
    fail(`${file} could not be read: ${error.message}`)
  }
}

function unescapeShellDoubleQuoted(value) {
  return value.replace(/\\([$"`\\])/g, '$1')
}

function unescapeJsSingleQuoted(value) {
  return value.replace(/\\'/g, "'").replace(/\\\\/g, '\\')
}

function extractReleaseChecks(file) {
  const text = read(file)
  const checks = new Map()
  const re = /\b(?:run_check(?:_with_network_retries)?|skip_check)\s+"([^"]+)"\s+"([^"]+)"/g
  for (const match of text.matchAll(re)) {
    const name = match[1]
    const slug = match[2]
    if (checks.has(slug) && checks.get(slug) !== name) {
      fail(`release-readiness check duplicate slug has conflicting name: ${slug}`)
    }
    checks.set(slug, name)
  }
  if (checks.size === 0) fail('release-readiness check extraction found no checks')
  return checks
}

function extractTerminalChecks(file) {
  const text = read(file)
  const checks = new Map()
  const re = /\brecord_check_result\s+\\?\s*\n\s*"([^"]+)"\s+\\?\s*\n\s*"([^"]+)"/g
  for (const match of text.matchAll(re)) {
    const name = match[1]
    const slug = match[2]
    if (checks.has(slug) && checks.get(slug) !== name) {
      fail(`release-readiness terminal check duplicate slug has conflicting name: ${slug}`)
    }
    checks.set(slug, name)
  }
  if (checks.size === 0) fail('release-readiness terminal check extraction found no checks')
  return checks
}

function mergeChecks(primary, additional) {
  const merged = new Map(primary)
  for (const [slug, name] of additional) {
    if (merged.has(slug) && merged.get(slug) !== name) {
      fail(`release-readiness check duplicate slug has conflicting name: ${slug}`)
    }
    merged.set(slug, name)
  }
  return merged
}

function selectMap(source, checks) {
  return new Map([...checks.keys()].map((slug) => [slug, source.get(slug)]))
}

function extractAuditCommands(file) {
  const text = read(file)
  const start = text.indexOf('verification_command_for_slug() {')
  if (start === -1) fail('verification_command_for_slug function missing')
  const endMarker = '\n}\n\nrequires_external_action_for_slug()'
  const end = text.indexOf(endMarker, start)
  if (end === -1) fail('verification_command_for_slug function end marker missing')
  const body = text.slice(start, end)
  const commands = new Map()
  const re = /^\s{4}([a-z0-9][a-z0-9-]*)\)\n\s+printf '%s' "((?:[^"\\]|\\.)*)"\n\s+;;/gm
  for (const match of body.matchAll(re)) {
    const slug = match[1]
    if (commands.has(slug)) fail(`verification_command_for_slug duplicate slug: ${slug}`)
    commands.set(slug, unescapeShellDoubleQuoted(match[2]))
  }
  if (commands.size === 0) fail('verification_command_for_slug command extraction found no commands')
  return commands
}

function extractFunctionBody(file, functionName, nextFunctionName) {
  const text = read(file)
  const start = text.indexOf(`${functionName}() {`)
  if (start === -1) fail(`${functionName} function missing`)
  const endMarker = `\n}\n\n${nextFunctionName}()`
  const end = text.indexOf(endMarker, start)
  if (end === -1) fail(`${functionName} function end marker missing`)
  return text.slice(start, end)
}

function extractAuditRequiresExternalActions(file, releaseChecks) {
  const body = extractFunctionBody(file, 'requires_external_action_for_slug', 'unblock_category_for_slug')
  const values = new Map([...releaseChecks.keys()].map((slug) => [slug, false]))
  const re = /^\s{4}([^)*]+)\)\n\s+printf 'true'\n\s+;;/gm
  for (const match of body.matchAll(re)) {
    for (const slug of match[1].split('|')) {
      if (!releaseChecks.has(slug)) fail(`requires_external_action_for_slug unexpected slug: ${slug}`)
      values.set(slug, true)
    }
  }
  return values
}

function extractAuditStringCaseMap(file, functionName, nextFunctionName, releaseChecks, contractName) {
  const body = extractFunctionBody(file, functionName, nextFunctionName)
  const values = new Map()
  let defaultValue = null
  const re = /^\s{4}([^)*]+|\*)\)\n\s+printf '%s' "((?:[^"\\]|\\.)*)"\n\s+;;/gm
  for (const match of body.matchAll(re)) {
    const value = unescapeShellDoubleQuoted(match[2])
    if (match[1] === '*') {
      defaultValue = value
      continue
    }
    for (const slug of match[1].split('|')) {
      if (!releaseChecks.has(slug)) fail(`${functionName} unexpected slug: ${slug}`)
      if (values.has(slug)) fail(`${functionName} duplicate slug: ${slug}`)
      values.set(slug, value)
    }
  }
  if (defaultValue === null) fail(`${functionName} default ${contractName} value missing`)
  for (const slug of releaseChecks.keys()) {
    if (!values.has(slug)) values.set(slug, defaultValue)
  }
  return values
}

function extractJsStringMap(file, constName, mapLabel) {
  const text = read(file)
  const start = text.indexOf(`const ${constName} = new Map([`)
  if (start === -1) fail(`${path.basename(file)} ${constName} missing`)
  const end = text.indexOf('\n])', start)
  if (end === -1) fail(`${path.basename(file)} ${constName} end marker missing`)
  const body = text.slice(start, end)
  const entries = new Map()
  const re = /^\s*\['([^']+)', '((?:[^'\\]|\\.)*)'\],$/gm
  for (const match of body.matchAll(re)) {
    const slug = match[1]
    if (entries.has(slug)) fail(`${path.basename(file)} ${mapLabel} contract duplicate slug: ${slug}`)
    entries.set(slug, unescapeJsSingleQuoted(match[2]))
  }
  if (entries.size === 0) fail(`${path.basename(file)} ${mapLabel} contract extraction found no entries`)
  return entries
}

function extractJsBooleanMap(file, constName, mapLabel) {
  const text = read(file)
  const start = text.indexOf(`const ${constName} = new Map([`)
  if (start === -1) fail(`${path.basename(file)} ${constName} missing`)
  const end = text.indexOf('\n])', start)
  if (end === -1) fail(`${path.basename(file)} ${constName} end marker missing`)
  const body = text.slice(start, end)
  const entries = new Map()
  const re = /^\s*\['([^']+)', (true|false)\],$/gm
  for (const match of body.matchAll(re)) {
    const slug = match[1]
    if (entries.has(slug)) fail(`${path.basename(file)} ${mapLabel} contract duplicate slug: ${slug}`)
    entries.set(slug, match[2] === 'true')
  }
  if (entries.size === 0) fail(`${path.basename(file)} ${mapLabel} contract extraction found no entries`)
  return entries
}

function extractJsCommandMap(file) {
  return extractJsStringMap(
    file,
    'expectedVerificationCommandsBySlug',
    'command',
  )
}

function extractJsNameMap(file) {
  return extractJsStringMap(
    file,
    'expectedCheckNamesBySlug',
    'check-name',
  )
}

function extractJsRecommendedActionMap(file) {
  return extractJsStringMap(file, 'expectedRecommendedActionsBySlug', 'recommended-action')
}

function extractJsRequiresExternalActionMap(file) {
  return extractJsBooleanMap(file, 'expectedRequiresExternalActionBySlug', 'requires-external-action')
}

function extractJsUnblockCategoryMap(file) {
  return extractJsStringMap(file, 'expectedUnblockCategoriesBySlug', 'unblock-category')
}

function extractJsExternalPrerequisiteMap(file) {
  return extractJsStringMap(file, 'expectedExternalPrerequisitesBySlug', 'external-prerequisite')
}

function compareKeys(label, actual, expected, contractName) {
  for (const slug of expected.keys()) {
    if (!actual.has(slug)) fail(`${label} ${contractName} contract missing slug: ${slug}`)
  }
  for (const slug of actual.keys()) {
    if (!expected.has(slug)) fail(`${label} ${contractName} contract unexpected slug: ${slug}`)
  }
}

function compareValues(label, actual, expected, contractName) {
  compareKeys(label, actual, expected, contractName)
  for (const [slug, expectedValue] of expected.entries()) {
    const actualValue = actual.get(slug)
    if (actualValue !== expectedValue) {
      fail(`${label} ${contractName} contract drift for ${slug}: expected ${JSON.stringify(expectedValue)}, got ${JSON.stringify(actualValue)}`)
    }
  }
}

function compareCommands(label, actual, expected) {
  compareValues(label, actual, expected, 'command')
}

function compareCheckNames(label, actual, expected) {
  compareValues(label, actual, expected, 'check-name')
}

const releaseChecks = extractReleaseChecks(auditFile)
const terminalChecks = extractTerminalChecks(auditFile)
const allChecks = mergeChecks(releaseChecks, terminalChecks)
const auditCommands = extractAuditCommands(auditFile)
const auditRecommendedActions = extractAuditStringCaseMap(
  auditFile,
  'recommended_action_for_slug',
  'verification_command_for_slug',
  allChecks,
  'recommended-action',
)
const auditRequiresExternalActions = extractAuditRequiresExternalActions(auditFile, allChecks)
const auditUnblockCategories = extractAuditStringCaseMap(
  auditFile,
  'unblock_category_for_slug',
  'external_prerequisite_for_slug',
  allChecks,
  'unblock-category',
)
const auditExternalPrerequisites = extractAuditStringCaseMap(
  auditFile,
  'external_prerequisite_for_slug',
  'log_evidence_preview',
  allChecks,
  'external-prerequisite',
)
compareKeys('verification_command_for_slug', auditCommands, allChecks, 'command')
compareCommands(path.basename(exportFile), extractJsCommandMap(exportFile), selectMap(auditCommands, releaseChecks))
compareCommands(path.basename(verifyFile), extractJsCommandMap(verifyFile), selectMap(auditCommands, releaseChecks))
compareCheckNames(path.basename(exportFile), extractJsNameMap(exportFile), releaseChecks)
compareCheckNames(path.basename(verifyFile), extractJsNameMap(verifyFile), releaseChecks)
compareValues(path.basename(exportFile), extractJsRecommendedActionMap(exportFile), selectMap(auditRecommendedActions, releaseChecks), 'recommended-action')
compareValues(path.basename(verifyFile), extractJsRecommendedActionMap(verifyFile), selectMap(auditRecommendedActions, releaseChecks), 'recommended-action')
compareValues(path.basename(exportFile), extractJsRequiresExternalActionMap(exportFile), selectMap(auditRequiresExternalActions, releaseChecks), 'requires-external-action')
compareValues(path.basename(verifyFile), extractJsRequiresExternalActionMap(verifyFile), selectMap(auditRequiresExternalActions, releaseChecks), 'requires-external-action')
compareValues(path.basename(exportFile), extractJsUnblockCategoryMap(exportFile), selectMap(auditUnblockCategories, releaseChecks), 'unblock-category')
compareValues(path.basename(verifyFile), extractJsUnblockCategoryMap(verifyFile), selectMap(auditUnblockCategories, releaseChecks), 'unblock-category')
compareValues(path.basename(exportFile), extractJsExternalPrerequisiteMap(exportFile), selectMap(auditExternalPrerequisites, releaseChecks), 'external-prerequisite')
compareValues(path.basename(verifyFile), extractJsExternalPrerequisiteMap(verifyFile), selectMap(auditExternalPrerequisites, releaseChecks), 'external-prerequisite')
NODE
}

expect_failure() {
  local name="$1"
  local expected="$2"
  shift 2
  local output
  set +e
  output="$(run_contract_check "$@" 2>&1)"
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

audit_script="$ROOT_DIR/scripts/audit-release-readiness.sh"
export_script="$ROOT_DIR/scripts/export-release-unblock-bundle.sh"
verify_script="$ROOT_DIR/scripts/verify-release-unblock-bundle.sh"

run_contract_check "$audit_script" "$export_script" "$verify_script"

tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

copy_fixture() {
  rm -rf "$tmp_dir/fixture"
  mkdir -p "$tmp_dir/fixture"
  cp "$audit_script" "$tmp_dir/fixture/audit-release-readiness.sh"
  cp "$export_script" "$tmp_dir/fixture/export-release-unblock-bundle.sh"
  cp "$verify_script" "$tmp_dir/fixture/verify-release-unblock-bundle.sh"
}

remove_js_map_entry() {
  local file="$1"
  local map_name="$2"
  local slug="$3"
  node - "$file" "$map_name" "$slug" <<'NODE'
const fs = require('fs')
const [file, mapName, slug] = process.argv.slice(2)
let text = fs.readFileSync(file, 'utf8')
const start = text.indexOf(`const ${mapName} = new Map([`)
if (start === -1) throw new Error(`${mapName} missing from fixture`)
const end = text.indexOf('\n])', start)
if (end === -1) throw new Error(`${mapName} end missing from fixture`)
const body = text.slice(start, end)
const escaped = slug.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')
const updated = body.replace(new RegExp(`^  \\['${escaped}', [^\\n]+\\],\\n`, 'm'), '')
if (updated === body) throw new Error(`${mapName} entry ${slug} missing from fixture`)
text = text.slice(0, start) + updated + text.slice(end)
fs.writeFileSync(file, text)
NODE
}

copy_fixture
perl -0pi -e 's/bash scripts\/audit-release-pr-readiness\.sh/bash scripts\/audit-plan-readiness.sh/g' "$tmp_dir/fixture/audit-release-readiness.sh"
expect_failure "audit command drift fixture" "export-release-unblock-bundle.sh command contract drift for release-pr-readiness" \
  "$tmp_dir/fixture/audit-release-readiness.sh" \
  "$tmp_dir/fixture/export-release-unblock-bundle.sh" \
  "$tmp_dir/fixture/verify-release-unblock-bundle.sh"

copy_fixture
perl -0pi -e 's/bash scripts\/audit-release-pr-readiness\.sh/bash scripts\/audit-plan-readiness.sh/g' "$tmp_dir/fixture/export-release-unblock-bundle.sh"
expect_failure "exporter command drift fixture" "export-release-unblock-bundle.sh command contract drift for release-pr-readiness" \
  "$tmp_dir/fixture/audit-release-readiness.sh" \
  "$tmp_dir/fixture/export-release-unblock-bundle.sh" \
  "$tmp_dir/fixture/verify-release-unblock-bundle.sh"

copy_fixture
perl -0pi -e 's/bash scripts\/audit-release-pr-readiness\.sh/bash scripts\/audit-plan-readiness.sh/g' "$tmp_dir/fixture/verify-release-unblock-bundle.sh"
expect_failure "verifier command drift fixture" "verify-release-unblock-bundle.sh command contract drift for release-pr-readiness" \
  "$tmp_dir/fixture/audit-release-readiness.sh" \
  "$tmp_dir/fixture/export-release-unblock-bundle.sh" \
  "$tmp_dir/fixture/verify-release-unblock-bundle.sh"

copy_fixture
remove_js_map_entry "$tmp_dir/fixture/export-release-unblock-bundle.sh" expectedVerificationCommandsBySlug passkey-backup-prerequisites
expect_failure "exporter missing command slug fixture" "export-release-unblock-bundle.sh command contract missing slug: passkey-backup-prerequisites" \
  "$tmp_dir/fixture/audit-release-readiness.sh" \
  "$tmp_dir/fixture/export-release-unblock-bundle.sh" \
  "$tmp_dir/fixture/verify-release-unblock-bundle.sh"

copy_fixture
remove_js_map_entry "$tmp_dir/fixture/verify-release-unblock-bundle.sh" expectedVerificationCommandsBySlug passkey-backup-prerequisites
expect_failure "verifier missing command slug fixture" "verify-release-unblock-bundle.sh command contract missing slug: passkey-backup-prerequisites" \
  "$tmp_dir/fixture/audit-release-readiness.sh" \
  "$tmp_dir/fixture/export-release-unblock-bundle.sh" \
  "$tmp_dir/fixture/verify-release-unblock-bundle.sh"

copy_fixture
node - "$tmp_dir/fixture/audit-release-readiness.sh" <<'NODE'
const fs = require('fs')
const file = process.argv[2]
const target = `
    passkey-backup-prerequisites)
      printf '%s' "PASSKEY_BACKUP_LIVE_HEALTH=1 bash scripts/audit-passkey-backup-prerequisites.sh && node fearless-site-web-app-associations-20260726/scripts/verify-app-associations.mjs --root fearless-site-web-app-associations-20260726 --live-base-url https://fearlesswallet.io"
      ;;`
let text = fs.readFileSync(file, 'utf8')
if (!text.includes(target)) throw new Error('passkey-backup-prerequisites command arm missing from fixture')
text = text.replace(target, '')
fs.writeFileSync(file, text)
NODE
expect_failure "audit missing command slug fixture" "verification_command_for_slug command contract missing slug: passkey-backup-prerequisites" \
  "$tmp_dir/fixture/audit-release-readiness.sh" \
  "$tmp_dir/fixture/export-release-unblock-bundle.sh" \
  "$tmp_dir/fixture/verify-release-unblock-bundle.sh"

copy_fixture
perl -0pi -e "s/(^  \\['release-pr-readiness', 'bash scripts\\/audit-release-pr-readiness\\.sh'\\],\\n)/\$1  ['unexpected-release-check', 'bash scripts\\/audit-plan-readiness.sh'],\\n/m" "$tmp_dir/fixture/export-release-unblock-bundle.sh"
expect_failure "exporter unexpected command slug fixture" "export-release-unblock-bundle.sh command contract unexpected slug: unexpected-release-check" \
  "$tmp_dir/fixture/audit-release-readiness.sh" \
  "$tmp_dir/fixture/export-release-unblock-bundle.sh" \
  "$tmp_dir/fixture/verify-release-unblock-bundle.sh"

copy_fixture
perl -0pi -e "s/(^  \\['release-pr-readiness', 'bash scripts\\/audit-release-pr-readiness\\.sh'\\],\\n)/\$1  ['unexpected-release-check', 'bash scripts\\/audit-plan-readiness.sh'],\\n/m" "$tmp_dir/fixture/verify-release-unblock-bundle.sh"
expect_failure "verifier unexpected command slug fixture" "verify-release-unblock-bundle.sh command contract unexpected slug: unexpected-release-check" \
  "$tmp_dir/fixture/audit-release-readiness.sh" \
  "$tmp_dir/fixture/export-release-unblock-bundle.sh" \
  "$tmp_dir/fixture/verify-release-unblock-bundle.sh"

copy_fixture
perl -0pi -e "s/(^  \\['release-pr-readiness', 'bash scripts\\/audit-release-pr-readiness\\.sh'\\],\\n)/\$1\$1/m" "$tmp_dir/fixture/export-release-unblock-bundle.sh"
expect_failure "exporter duplicate command slug fixture" "export-release-unblock-bundle.sh command contract duplicate slug: release-pr-readiness" \
  "$tmp_dir/fixture/audit-release-readiness.sh" \
  "$tmp_dir/fixture/export-release-unblock-bundle.sh" \
  "$tmp_dir/fixture/verify-release-unblock-bundle.sh"

copy_fixture
perl -0pi -e 's/Release PR readiness/Release PR approval readiness/g' "$tmp_dir/fixture/audit-release-readiness.sh"
expect_failure "audit name drift fixture" "export-release-unblock-bundle.sh check-name contract drift for release-pr-readiness" \
  "$tmp_dir/fixture/audit-release-readiness.sh" \
  "$tmp_dir/fixture/export-release-unblock-bundle.sh" \
  "$tmp_dir/fixture/verify-release-unblock-bundle.sh"

copy_fixture
perl -0pi -e "s/\\['release-pr-readiness', 'Release PR readiness'\\]/['release-pr-readiness', 'Release PR approval readiness']/" "$tmp_dir/fixture/export-release-unblock-bundle.sh"
expect_failure "exporter name drift fixture" "export-release-unblock-bundle.sh check-name contract drift for release-pr-readiness" \
  "$tmp_dir/fixture/audit-release-readiness.sh" \
  "$tmp_dir/fixture/export-release-unblock-bundle.sh" \
  "$tmp_dir/fixture/verify-release-unblock-bundle.sh"

copy_fixture
perl -0pi -e "s/\\['release-pr-readiness', 'Release PR readiness'\\]/['release-pr-readiness', 'Release PR approval readiness']/" "$tmp_dir/fixture/verify-release-unblock-bundle.sh"
expect_failure "verifier name drift fixture" "verify-release-unblock-bundle.sh check-name contract drift for release-pr-readiness" \
  "$tmp_dir/fixture/audit-release-readiness.sh" \
  "$tmp_dir/fixture/export-release-unblock-bundle.sh" \
  "$tmp_dir/fixture/verify-release-unblock-bundle.sh"

copy_fixture
perl -0pi -e "s/^  \\['passkey-backup-prerequisites', 'Passkey backup prerequisites'\\],\\n//m" "$tmp_dir/fixture/export-release-unblock-bundle.sh"
expect_failure "exporter missing name slug fixture" "export-release-unblock-bundle.sh check-name contract missing slug: passkey-backup-prerequisites" \
  "$tmp_dir/fixture/audit-release-readiness.sh" \
  "$tmp_dir/fixture/export-release-unblock-bundle.sh" \
  "$tmp_dir/fixture/verify-release-unblock-bundle.sh"

copy_fixture
perl -0pi -e "s/\\['release-pr-readiness', true\\]/['release-pr-readiness', false]/" "$tmp_dir/fixture/export-release-unblock-bundle.sh"
expect_failure "exporter external-action drift fixture" "export-release-unblock-bundle.sh requires-external-action contract drift for release-pr-readiness" \
  "$tmp_dir/fixture/audit-release-readiness.sh" \
  "$tmp_dir/fixture/export-release-unblock-bundle.sh" \
  "$tmp_dir/fixture/verify-release-unblock-bundle.sh"

copy_fixture
perl -0pi -e "s/\\['release-pr-readiness', 'review-and-merge'\\]/['release-pr-readiness', 'local-code']/" "$tmp_dir/fixture/export-release-unblock-bundle.sh"
expect_failure "exporter unblock-category drift fixture" "export-release-unblock-bundle.sh unblock-category contract drift for release-pr-readiness" \
  "$tmp_dir/fixture/audit-release-readiness.sh" \
  "$tmp_dir/fixture/export-release-unblock-bundle.sh" \
  "$tmp_dir/fixture/verify-release-unblock-bundle.sh"

copy_fixture
perl -0pi -e "s/\\['release-pr-readiness', 'Reviewer approvals, resolved GitHub review conversations, and protected-branch merges\\.'\\]/['release-pr-readiness', 'Local release checklist cleanup.']/" "$tmp_dir/fixture/verify-release-unblock-bundle.sh"
expect_failure "verifier external-prerequisite drift fixture" "verify-release-unblock-bundle.sh external-prerequisite contract drift for release-pr-readiness" \
  "$tmp_dir/fixture/audit-release-readiness.sh" \
  "$tmp_dir/fixture/export-release-unblock-bundle.sh" \
  "$tmp_dir/fixture/verify-release-unblock-bundle.sh"

copy_fixture
perl -0pi -e "s/^  \\['passkey-backup-prerequisites', 'live-service-deployment'\\],\\n//m" "$tmp_dir/fixture/export-release-unblock-bundle.sh"
expect_failure "exporter missing unblock-category slug fixture" "export-release-unblock-bundle.sh unblock-category contract missing slug: passkey-backup-prerequisites" \
  "$tmp_dir/fixture/audit-release-readiness.sh" \
  "$tmp_dir/fixture/export-release-unblock-bundle.sh" \
  "$tmp_dir/fixture/verify-release-unblock-bundle.sh"

copy_fixture
perl -0pi -e "s/\\['release-pr-readiness', 'Get every PR in config\\/release-readiness-prs\\.tsv approved, green, with all GitHub review conversations resolved including outdated unresolved threads, and merged through the protected branch flow\\. When the blocker is outdated-only, run bash scripts\\/resolve-release-pr-review-threads\\.sh --dry-run to inspect the exact thread IDs before any authorized resolution\\. After conversations are resolved and approvals are present, run bash scripts\\/merge-release-prs\\.sh --dry-run to inspect protected-branch merge candidates before any authorized merge, then rerun bash scripts\\/audit-release-pr-readiness\\.sh\\.'\\]/['release-pr-readiness', 'Approve and merge the release PRs.']/" "$tmp_dir/fixture/export-release-unblock-bundle.sh"
expect_failure "exporter recommended-action drift fixture" "export-release-unblock-bundle.sh recommended-action contract drift for release-pr-readiness" \
  "$tmp_dir/fixture/audit-release-readiness.sh" \
  "$tmp_dir/fixture/export-release-unblock-bundle.sh" \
  "$tmp_dir/fixture/verify-release-unblock-bundle.sh"

copy_fixture
remove_js_map_entry "$tmp_dir/fixture/verify-release-unblock-bundle.sh" expectedRecommendedActionsBySlug passkey-backup-prerequisites
expect_failure "verifier missing recommended-action slug fixture" "verify-release-unblock-bundle.sh recommended-action contract missing slug: passkey-backup-prerequisites" \
  "$tmp_dir/fixture/audit-release-readiness.sh" \
  "$tmp_dir/fixture/export-release-unblock-bundle.sh" \
  "$tmp_dir/fixture/verify-release-unblock-bundle.sh"

echo "[release-unblock-command-contract-test] all tests passed"
