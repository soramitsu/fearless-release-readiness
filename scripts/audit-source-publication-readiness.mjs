#!/usr/bin/env node

import { spawnSync } from 'node:child_process';
import crypto from 'node:crypto';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const SCRIPT_DIR = path.dirname(fileURLToPath(import.meta.url));
const DEFAULT_ROOT = path.resolve(SCRIPT_DIR, '..');
const EXPECTED_REPOSITORIES = new Map([
  ['fearless-Android', { repository: 'soramitsu/fearless-Android', head: 'codex/android-xcm-evidence-release-commit', base: 'develop', prNumber: 1258 }],
  ['fearless-iOS', { repository: 'soramitsu/fearless-iOS', head: 'codex/ios-transaction-builder-ci-gate', base: 'develop', prNumber: 1301 }],
  ['fearless-wallet-web', { repository: 'soramitsu/fearless-wallet-web', head: 'codex/web-bitcoin-canonical-indexer-evidence', base: 'develop', prNumber: 1062 }],
  ['fearless-site-web', { repository: 'soramitsu/fearless-site-web', head: 'codex/site-todo-debt-baseline-hardening', base: 'develop', prNumber: 45 }],
  ['../ton-indexer', { repository: 'tonswap-org/ton-indexer', head: 'codex/ti-smoke-body-preview-tests', base: 'develop', prNumber: 13 }],
  ['../solswap-indexer', { repository: 'solswap-io/solswap-indexer', head: 'codex/si-smoke-body-preview-tests', base: 'develop', prNumber: 16 }],
  ['../polkaswap-indexer', { repository: 'sora-xor/polkaswap-indexer', head: 'codex/pi-deployment-evidence-gate', base: 'develop', prNumber: 1 }],
  ['../iroha', { repository: 'hyperledger-iroha/iroha', head: 'codex/kagemusha-selector-hardening', base: 'optimizations', prNumber: 5612 }],
]);
const REQUIRED_WORKSPACE_FILES = [
  '.github/CODEOWNERS',
  '.github/workflows/readiness.yml',
  '.gitignore',
  'FEARLESS_PROJECT_PLAN.md',
  'README.md',
  'config/release-readiness-prs.tsv',
  'config/source-publication-root-owner.json',
  'config/source-publication-readiness.tsv',
  'docs/source-freeze-20260801.md',
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
];
const ROOT_OWNER_BLOCKER = 'canonical-root-source-owner-unassigned';
const SOURCE_PUBLICATION_REPORT_SCHEMA_VERSION = 2;
const SAFE_REPOSITORY = /^[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+$/u;
const SAFE_REF = /^(?![./])(?!.*(?:\.\.|\/\/|@\{|\\))[A-Za-z0-9._/-]+(?<![./])$/u;
const SHA1 = /^[0-9a-f]{40}$/u;
const WORKSPACE_NESTED_REPOSITORIES = ['fearless-Android', 'fearless-iOS', 'fearless-wallet-web', 'fearless-site-web'];
const SOURCE_PHASES = new Set(['standalone', 'preflight', 'postflight']);
const MAX_PREFLIGHT_AGE_MS = 6 * 60 * 60 * 1000;
const TOOL_TIMEOUT_MS = 30_000;
const GIT_OPERATION_MARKERS = Object.freeze([
  { operation: 'merge', relativePath: 'MERGE_HEAD', kind: 'file' },
  { operation: 'rebase', relativePath: 'rebase-merge', kind: 'directory' },
  { operation: 'rebase', relativePath: 'rebase-apply', kind: 'directory' },
  { operation: 'cherry-pick', relativePath: 'CHERRY_PICK_HEAD', kind: 'file' },
  { operation: 'revert', relativePath: 'REVERT_HEAD', kind: 'file' },
  { operation: 'bisect', relativePath: 'BISECT_START', kind: 'file' },
  { operation: 'sequencer', relativePath: 'sequencer', kind: 'directory' },
]);
const SAFE_GIT_CONFIG = [
  ['core.fsmonitor', 'false'],
  ['core.hooksPath', os.devNull],
  ['core.askPass', '/usr/bin/false'],
  ['credential.helper', ''],
  ['credential.interactive', 'false'],
  ['core.sshCommand', '/usr/bin/false'],
];
const DANGEROUS_TOOL_ENVIRONMENT = new Set([
  'GIT_ALTERNATE_OBJECT_DIRECTORIES',
  'GIT_ASKPASS',
  'GIT_ATTR_NOSYSTEM',
  'GIT_CEILING_DIRECTORIES',
  'GIT_COMMON_DIR',
  'GIT_CONFIG',
  'GIT_CONFIG_COUNT',
  'GIT_CONFIG_GLOBAL',
  'GIT_CONFIG_NOSYSTEM',
  'GIT_CONFIG_PARAMETERS',
  'GIT_CONFIG_SYSTEM',
  'GIT_DIR',
  'GIT_DISCOVERY_ACROSS_FILESYSTEM',
  'GIT_EXEC_PATH',
  'GIT_EXTERNAL_DIFF',
  'GIT_INDEX_FILE',
  'GIT_NAMESPACE',
  'GIT_OBJECT_DIRECTORY',
  'GIT_PAGER',
  'GIT_PROXY_COMMAND',
  'GIT_SSH',
  'GIT_SSH_COMMAND',
  'GIT_SSL_CAINFO',
  'GIT_SSL_CAPATH',
  'GIT_SSL_NO_VERIFY',
  'GIT_TEMPLATE_DIR',
  'GIT_WORK_TREE',
  'GH_CONFIG_DIR',
  'GH_HOST',
  'GH_PAGER',
  'GH_REPO',
  'SSH_ASKPASS',
]);
const localStateSnapshots = new Map();
let earlyReportContext = null;
let writingEarlyReport = false;

const options = parseArgs(process.argv.slice(2));
const testToolInjection = options.testToolInjection === true;
if (testToolInjection && process.env.SOURCE_PUBLICATION_TEST_MODE !== '1') {
  usage('--test-tool-injection requires SOURCE_PUBLICATION_TEST_MODE=1');
}
if (!testToolInjection && process.env.SOURCE_PUBLICATION_TEST_MODE) {
  usage('SOURCE_PUBLICATION_TEST_MODE is only valid with --test-tool-injection');
}
if (!testToolInjection) rejectProductionInjectionEnvironment();

const root = path.resolve(options.root ?? (testToolInjection ? process.env.SOURCE_PUBLICATION_ROOT : undefined) ?? DEFAULT_ROOT);
const parent = path.resolve(options.parent ?? (testToolInjection ? process.env.SOURCE_PUBLICATION_PARENT : undefined) ?? path.dirname(root));
const configFile = path.resolve(
  options.config ??
    (testToolInjection ? process.env.SOURCE_PUBLICATION_CONFIG : undefined) ??
    path.join(root, 'config/source-publication-readiness.tsv'),
);
const rootOwnerConfigFile = path.resolve(
  options.rootOwnerConfig ??
    (testToolInjection ? process.env.SOURCE_PUBLICATION_ROOT_OWNER_CONFIG : undefined) ??
    path.join(root, 'config/source-publication-root-owner.json'),
);
const releasePrConfigFile = path.resolve(
  options.releasePrConfig ??
    (testToolInjection ? process.env.SOURCE_PUBLICATION_RELEASE_PR_CONFIG : undefined) ??
    path.join(root, 'config/release-readiness-prs.tsv'),
);
if (!testToolInjection) {
  const expectedConfigFile = path.join(root, 'config/source-publication-readiness.tsv');
  const expectedRootOwnerConfigFile = path.join(root, 'config/source-publication-root-owner.json');
  const expectedReleasePrConfigFile = path.join(root, 'config/release-readiness-prs.tsv');
  if (configFile !== expectedConfigFile) usage(`production source publication config must be ${expectedConfigFile}`);
  if (rootOwnerConfigFile !== expectedRootOwnerConfigFile) {
    usage(`production source publication root owner config must be ${expectedRootOwnerConfigFile}`);
  }
  if (releasePrConfigFile !== expectedReleasePrConfigFile) {
    usage(`production release PR config must be ${expectedReleasePrConfigFile}`);
  }
}
const checkRemote = options.checkRemote;
const phase = options.phase;
const maxPaths = options.maxPaths;
const generatedAt = normalizeTimestamp(
  (testToolInjection ? process.env.SOURCE_PUBLICATION_NOW : undefined) ?? new Date().toISOString(),
);
const failures = [];
const reportTarget = options.writeReport ? path.resolve(options.writeReport) : null;
const preflightReportFile = options.preflightReport ? path.resolve(options.preflightReport) : null;

if ((phase === 'preflight' || phase === 'postflight') && !checkRemote) {
  usage(`${phase} source publication attestation requires --check-remote`);
}
if (phase === 'postflight' && !preflightReportFile) usage('postflight source publication attestation requires --preflight-report');
if (phase !== 'postflight' && preflightReportFile) usage('--preflight-report is only valid with --phase postflight');
if (reportTarget && preflightReportFile && reportTarget === preflightReportFile) {
  usage('postflight report and preflight report must be different files');
}

earlyReportContext = {
  generatedAt,
  checkRemote,
  root,
  parent,
  configFile,
  rootOwnerConfigFile,
  releasePrConfigFile,
  reportTarget,
  reportSafe: false,
};
if (reportTarget) prepareReportOutput(reportTarget, root, testToolInjection);

const gitBin = testToolInjection && options.gitBin
  ? resolveInjectedTool(options.gitBin, 'git')
  : resolveCanonicalTool('git');
const ghBin = checkRemote
  ? testToolInjection && options.ghBin
    ? resolveInjectedTool(options.ghBin, 'gh')
    : resolveCanonicalTool('gh')
  : null;

assertDirectory(root, 'workspace root');
assertDirectory(parent, 'workspace parent');
if (parent !== path.dirname(root)) usage(`workspace parent must be the direct parent of workspace root: ${path.dirname(root)}`);
assertRegularFile(configFile, 'source publication config');
assertRegularFile(rootOwnerConfigFile, 'source publication root owner config');
assertRegularFile(releasePrConfigFile, 'release PR config');

const configRows = parseSourceConfig(configFile);
const rootOwner = parseRootOwnerConfig(rootOwnerConfigFile);
const releasePrRows = parseReleasePrConfig(releasePrConfigFile);
validateConfigCoverage(configRows, rootOwner, releasePrRows);
const preflightReport = preflightReportFile ? parsePreflightReport(preflightReportFile) : null;

const workspaceSource = inspectWorkspaceSource(rootOwner, releasePrRows);
const repositories = [];
for (const row of configRows) repositories.push(inspectRepository(row));
for (const source of [workspaceSource, ...repositories]) finalLocalStateRecheck(source);
if (preflightReport) comparePreflightSources(preflightReport, [workspaceSource, ...repositories]);
for (const source of [workspaceSource, ...repositories]) {
  source.status = source.failures.length === 0 ? 'passed' : 'failed';
}

const totals = [workspaceSource, ...repositories].reduce(
  (result, repository) => {
    result.sources += 1;
    result.staged += repository.stagedCount;
    result.unstaged += repository.unstagedCount;
    result.untracked += repository.untrackedCount;
    result.unmerged += repository.unmergedCount;
    if (repository.status === 'passed') result.passed += 1;
    else result.failed += 1;
    return result;
  },
  { sources: 0, passed: 0, failed: 0, staged: 0, unstaged: 0, untracked: 0, unmerged: 0 },
);

const report = {
  schemaVersion: SOURCE_PUBLICATION_REPORT_SCHEMA_VERSION,
  generatedAt,
  status: failures.length === 0 ? 'passed' : 'failed',
  checkRemote,
  workspaceRoot: root,
  workspaceParent: parent,
  configFile,
  rootOwnerConfigFile,
  releasePrConfigFile,
  totals,
  workspaceSource,
  repositories,
};

if (reportTarget) writeReport(reportTarget, report);

if (failures.length > 0) {
  console.error('[source-publication-readiness][error] Source publication readiness failed:');
  for (const failure of failures) console.error(`  - ${failure}`);
  process.exit(1);
}

console.log(
  `[source-publication-readiness] verified ${totals.sources} clean, versioned source trees` +
    `${checkRemote ? ' against authoritative pull requests and remote heads' : ' against local upstream refs'}`,
);

function parseArgs(args) {
  const parsed = { checkRemote: false, maxPaths: 8, testToolInjection: false, phase: 'standalone' };
  for (let index = 0; index < args.length; index += 1) {
    const arg = args[index];
    if (arg === '--check-remote') {
      parsed.checkRemote = true;
      continue;
    }
    if (arg === '--test-tool-injection') {
      parsed.testToolInjection = true;
      continue;
    }
    if (arg === '--root' || arg === '--parent' || arg === '--config' || arg === '--root-owner-config' || arg === '--release-pr-config' || arg === '--git-bin' || arg === '--gh-bin' || arg === '--write-report' || arg === '--preflight-report' || arg === '--phase' || arg === '--max-paths') {
      const value = args[index + 1];
      if (!value) usage(`${arg} requires a value`);
      const key = {
        '--root': 'root',
        '--parent': 'parent',
        '--config': 'config',
        '--root-owner-config': 'rootOwnerConfig',
        '--release-pr-config': 'releasePrConfig',
        '--git-bin': 'gitBin',
        '--gh-bin': 'ghBin',
        '--write-report': 'writeReport',
        '--preflight-report': 'preflightReport',
        '--phase': 'phase',
        '--max-paths': 'maxPaths',
      }[arg];
      if (arg === '--phase' && !SOURCE_PHASES.has(value)) usage(`--phase must be one of: ${[...SOURCE_PHASES].join(', ')}`);
      parsed[key] = arg === '--max-paths' ? parsePositiveInteger(value, arg) : value;
      index += 1;
      continue;
    }
    if (arg === '--help' || arg === '-h') {
      console.log('Usage: audit-source-publication-readiness.mjs [--check-remote] [--phase standalone|preflight|postflight] [--preflight-report PATH] [--write-report PATH] [--root PATH] [--parent PATH] [--config PATH] [--root-owner-config PATH] [--release-pr-config PATH] [--max-paths N]');
      process.exit(0);
    }
    usage(`unknown argument: ${arg}`);
  }
  return parsed;
}

function usage(message) {
  tryWriteEarlyFailureReport(message);
  console.error(`[source-publication-readiness][error] ${message}`);
  process.exit(2);
}

function rejectProductionInjectionEnvironment() {
  const forbidden = [
    'NODE_OPTIONS',
    'SOURCE_PUBLICATION_CONFIG',
    'SOURCE_PUBLICATION_GH_BIN',
    'SOURCE_PUBLICATION_GIT_BIN',
    'SOURCE_PUBLICATION_NOW',
    'SOURCE_PUBLICATION_PARENT',
    'SOURCE_PUBLICATION_RELEASE_PR_CONFIG',
    'SOURCE_PUBLICATION_ROOT',
    'SOURCE_PUBLICATION_ROOT_OWNER_CONFIG',
  ];
  for (const name of forbidden) {
    if (process.env[name] !== undefined) usage(`${name} is forbidden outside explicit test-tool-injection mode`);
  }
  if (options.gitBin || options.ghBin) usage('--git-bin and --gh-bin are forbidden outside explicit test-tool-injection mode');
}

function resolveCanonicalTool(name) {
  const candidates = {
    git: ['/usr/bin/git', '/opt/homebrew/bin/git', '/usr/local/bin/git'],
    gh: ['/usr/bin/gh', '/opt/homebrew/bin/gh', '/usr/local/bin/gh'],
  }[name];
  if (!candidates) usage(`unsupported canonical tool: ${name}`);
  for (const candidate of candidates) {
    if (!fs.existsSync(candidate)) continue;
    let resolved;
    try {
      resolved = fs.realpathSync.native(candidate);
      const stat = fs.lstatSync(resolved);
      fs.accessSync(resolved, fs.constants.X_OK);
      if (!stat.isFile() || stat.isSymbolicLink()) continue;
      assertNoSymlinkPathComponents(resolved, `${name} executable`);
      return resolved;
    } catch {
      continue;
    }
  }
  usage(`canonical ${name} executable is unavailable`);
}

function resolveInjectedTool(value, name) {
  if (!path.isAbsolute(value) || path.resolve(value) !== value) {
    usage(`test ${name} executable must be an absolute normalized path`);
  }
  assertNoSymlinkPathComponents(value, `test ${name} executable`);
  let stat;
  try {
    stat = fs.lstatSync(value);
    fs.accessSync(value, fs.constants.X_OK);
  } catch {
    usage(`test ${name} executable is unavailable: ${value}`);
  }
  if (!stat.isFile() || stat.isSymbolicLink()) usage(`test ${name} executable must be a regular executable file: ${value}`);
  return value;
}

function cleanToolEnvironment(extra = {}) {
  const env = { ...process.env };
  for (const key of Object.keys(env)) {
    if (
      DANGEROUS_TOOL_ENVIRONMENT.has(key) ||
      /^GIT_CONFIG_(?:KEY|VALUE)_\d+$/u.test(key) ||
      /^GIT_TRACE/u.test(key)
    ) {
      delete env[key];
    }
  }
  return {
    ...env,
    GIT_CONFIG_GLOBAL: os.devNull,
    GIT_CONFIG_NOSYSTEM: '1',
    GIT_PAGER: 'cat',
    GH_PAGER: 'cat',
    ...extra,
  };
}

function cleanGitEnvironment() {
  const overrides = {
    GIT_TERMINAL_PROMPT: '0',
    GIT_CONFIG_COUNT: String(SAFE_GIT_CONFIG.length),
  };
  for (const [index, [key, value]] of SAFE_GIT_CONFIG.entries()) {
    overrides[`GIT_CONFIG_KEY_${index}`] = key;
    overrides[`GIT_CONFIG_VALUE_${index}`] = value;
  }
  return cleanToolEnvironment(overrides);
}

function parsePositiveInteger(value, label) {
  if (!/^[1-9][0-9]*$/u.test(value)) usage(`${label} must be a positive integer`);
  const parsed = Number(value);
  if (!Number.isSafeInteger(parsed)) usage(`${label} must be a safe integer`);
  return parsed;
}

function normalizeTimestamp(value) {
  if (!/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z$/u.test(value)) {
    usage('SOURCE_PUBLICATION_NOW must be an ISO-8601 UTC timestamp with milliseconds');
  }
  const parsed = new Date(value);
  if (Number.isNaN(parsed.getTime()) || parsed.toISOString() !== value) {
    usage('SOURCE_PUBLICATION_NOW must be a real canonical UTC timestamp');
  }
  return value;
}

function assertNoSymlinkPathComponents(target, label, allowMissingSuffix = false) {
  const absolute = path.resolve(target);
  const filesystemRoot = path.parse(absolute).root;
  let current = filesystemRoot;
  for (const segment of path.relative(filesystemRoot, absolute).split(path.sep).filter(Boolean)) {
    current = path.join(current, segment);
    if (!fs.existsSync(current)) {
      if (allowMissingSuffix) return;
      usage(`${label} path component does not exist: ${current}`);
    }
    let stat;
    try {
      stat = fs.lstatSync(current);
    } catch {
      if (allowMissingSuffix) return;
      usage(`${label} path component is unavailable: ${current}`);
    }
    if (stat.isSymbolicLink()) usage(`${label} must not use a symlinked path component: ${current}`);
  }
}

function assertDirectory(target, label) {
  assertNoSymlinkPathComponents(target, label);
  let stat;
  try {
    stat = fs.lstatSync(target);
  } catch {
    usage(`${label} does not exist: ${target}`);
  }
  if (!stat.isDirectory() || stat.isSymbolicLink()) usage(`${label} must be a real directory: ${target}`);
}

function assertRegularFile(target, label) {
  assertNoSymlinkPathComponents(target, label);
  let stat;
  try {
    stat = fs.lstatSync(target);
  } catch {
    usage(`${label} does not exist: ${target}`);
  }
  if (!stat.isFile() || stat.isSymbolicLink()) usage(`${label} must be a regular non-symlink file: ${target}`);
}

function prepareReportOutput(target, workspaceRoot, testMode) {
  const parentDirectory = path.dirname(target);
  if (!testMode) {
    const allowedRoot = path.join(workspaceRoot, 'build', 'reports');
    if (target !== allowedRoot && !target.startsWith(`${allowedRoot}${path.sep}`)) {
      usage(`report output must be inside ${allowedRoot}`);
    }
  }
  assertNoSymlinkPathComponents(parentDirectory, 'report output parent', true);
  fs.mkdirSync(parentDirectory, { recursive: true, mode: 0o700 });
  assertNoSymlinkPathComponents(parentDirectory, 'report output parent');
  if (!fs.existsSync(target)) {
    earlyReportContext.reportSafe = true;
    return;
  }
  const stat = fs.lstatSync(target);
  if (!stat.isFile() || stat.isSymbolicLink()) usage(`report output must be a regular non-symlink file: ${target}`);
  fs.unlinkSync(target);
  earlyReportContext.reportSafe = true;
}

function tryWriteEarlyFailureReport(message) {
  if (!earlyReportContext?.reportTarget || !earlyReportContext.reportSafe || writingEarlyReport) return;
  writingEarlyReport = true;
  try {
    const rows = [...EXPECTED_REPOSITORIES.entries()].map(([repoPath, expected]) => ({
      path: repoPath,
      repository: expected.repository,
      head: expected.head,
      base: expected.base,
      prNumber: expected.prNumber,
    }));
    const workspaceSource = createSource('.', earlyReportContext.root);
    workspaceSource.failures = [message];
    const repositories = rows.map((row) => {
      const source = createSource(row.path, path.resolve(earlyReportContext.root, row.path), row);
      source.failures = ['audit initialization failed before source inspection'];
      return source;
    });
    const value = {
      schemaVersion: SOURCE_PUBLICATION_REPORT_SCHEMA_VERSION,
      generatedAt: earlyReportContext.generatedAt,
      status: 'failed',
      checkRemote: earlyReportContext.checkRemote,
      workspaceRoot: earlyReportContext.root,
      workspaceParent: earlyReportContext.parent,
      configFile: earlyReportContext.configFile,
      rootOwnerConfigFile: earlyReportContext.rootOwnerConfigFile,
      releasePrConfigFile: earlyReportContext.releasePrConfigFile,
      totals: { sources: 9, passed: 0, failed: 9, staged: 0, unstaged: 0, untracked: 0, unmerged: 0 },
      workspaceSource,
      repositories,
    };
    const temporary = `${earlyReportContext.reportTarget}.tmp-${process.pid}-failure`;
    fs.writeFileSync(temporary, `${JSON.stringify(value, null, 2)}\n`, { mode: 0o600, flag: 'wx' });
    fs.renameSync(temporary, earlyReportContext.reportTarget);
  } catch {
    // The primary validation diagnostic remains authoritative if failure reporting is impossible.
  } finally {
    writingEarlyReport = false;
  }
}

function readTextFile(target, label) {
  const value = fs.readFileSync(target, 'utf8');
  if (value.includes('\0')) usage(`${label} must not contain NUL bytes`);
  if (value.includes('\r')) usage(`${label} must use LF line endings`);
  return value;
}

function parseSourceConfig(target) {
  const rows = [];
  const seen = new Set();
  const lines = readTextFile(target, 'source publication config').split('\n');
  for (let index = 0; index < lines.length; index += 1) {
    const line = lines[index];
    if (!line || line.startsWith('#')) continue;
    const fields = line.split('\t');
    if (fields.length !== 5 || fields.some((field) => !field || field.trim() !== field)) {
      usage(`source publication config line ${index + 1} must contain exactly five non-empty tab-separated fields`);
    }
    const [repoPath, repository, head, base, prNumberRaw] = fields;
    if (seen.has(repoPath)) usage(`duplicate source publication repo path: ${repoPath}`);
    seen.add(repoPath);
    if (!EXPECTED_REPOSITORIES.has(repoPath)) usage(`unsupported source publication repo path: ${repoPath}`);
    const expected = EXPECTED_REPOSITORIES.get(repoPath);
    if (expected.repository !== repository) usage(`repository mismatch for ${repoPath}: expected ${expected.repository}`);
    if (!SAFE_REF.test(head)) usage(`invalid source publication head branch for ${repoPath}: ${head}`);
    if (!SAFE_REF.test(base)) usage(`invalid source publication base branch for ${repoPath}: ${base}`);
    if (head !== expected.head) usage(`head branch mismatch for ${repoPath}: expected ${expected.head}`);
    if (base !== expected.base) usage(`base branch mismatch for ${repoPath}: expected ${expected.base}`);
    if (!/^[1-9][0-9]*$/u.test(prNumberRaw) || !Number.isSafeInteger(Number(prNumberRaw))) {
      usage(`invalid pull request number for ${repoPath}: ${prNumberRaw}`);
    }
    if (Number(prNumberRaw) !== expected.prNumber) {
      usage(`pull request mismatch for ${repoPath}: expected ${expected.prNumber}`);
    }
    rows.push({ path: repoPath, repository, head, base, prNumber: Number(prNumberRaw) });
  }
  return rows;
}

function parseRootOwnerConfig(target) {
  let value;
  try {
    value = JSON.parse(readTextFile(target, 'source publication root owner config'));
  } catch (error) {
    usage(`source publication root owner config must be valid JSON: ${error.message}`);
  }
  if (!value || typeof value !== 'object' || Array.isArray(value)) {
    usage('source publication root owner config must be an object');
  }
  const expectedFields = ['schemaVersion', 'status', 'repository', 'head', 'base', 'prNumber', 'lastReviewed', 'blocker'];
  const keys = Object.keys(value);
  if (keys.length !== expectedFields.length || expectedFields.some((field) => !keys.includes(field))) {
    usage(`source publication root owner config must contain exactly: ${expectedFields.join(', ')}`);
  }
  if (value.schemaVersion !== 1) usage('source publication root owner config schemaVersion must be 1');
  if (!['blocked', 'ready'].includes(value.status)) usage('source publication root owner config status must be blocked or ready');
  validateReviewedDate(value.lastReviewed, 'source publication root owner config lastReviewed');
  if (value.status === 'blocked') {
    for (const field of ['repository', 'head', 'base', 'prNumber']) {
      if (value[field] !== null) usage(`blocked source publication root owner config ${field} must be null`);
    }
    if (value.blocker !== ROOT_OWNER_BLOCKER) {
      usage(`blocked source publication root owner config blocker must be ${ROOT_OWNER_BLOCKER}`);
    }
  } else {
    if (typeof value.repository !== 'string' || !SAFE_REPOSITORY.test(value.repository)) {
      usage('ready source publication root owner config repository must be owner/repository');
    }
    if (typeof value.head !== 'string' || !SAFE_REF.test(value.head)) {
      usage('ready source publication root owner config head must be a safe branch ref');
    }
    if (typeof value.base !== 'string' || !SAFE_REF.test(value.base)) {
      usage('ready source publication root owner config base must be a safe branch ref');
    }
    if (!Number.isSafeInteger(value.prNumber) || value.prNumber <= 0) {
      usage('ready source publication root owner config prNumber must be a positive integer');
    }
    if (value.blocker !== null) usage('ready source publication root owner config blocker must be null');
  }
  return value;
}

function validateReviewedDate(value, label) {
  if (typeof value !== 'string' || !/^\d{4}-\d{2}-\d{2}$/u.test(value)) usage(`${label} must be YYYY-MM-DD`);
  const milliseconds = Date.parse(`${value}T00:00:00Z`);
  if (!Number.isFinite(milliseconds) || new Date(milliseconds).toISOString().slice(0, 10) !== value) {
    usage(`${label} must be a real calendar date`);
  }
  if (milliseconds > Date.parse(generatedAt) + 5 * 60 * 1000) usage(`${label} must not be in the future`);
}

function parseReleasePrConfig(target) {
  const rows = [];
  const lines = readTextFile(target, 'release PR config').split('\n');
  for (let index = 0; index < lines.length; index += 1) {
    const line = lines[index];
    if (!line || line.startsWith('#')) continue;
    const fields = line.split('\t');
    if (fields.length !== 5 || fields.some((field) => !field || field.trim() !== field)) {
      usage(`release PR config line ${index + 1} must contain exactly five non-empty tab-separated fields`);
    }
    const [repository, head, base, requiredState, requiredChecks] = fields;
    rows.push({ repository, head, base, requiredState, requiredChecks, line: index + 1 });
  }
  return rows;
}

function validateConfigCoverage(configRows, rootOwner, releasePrRows) {
  if (configRows.length !== EXPECTED_REPOSITORIES.size) {
    usage(`source publication config must contain exactly ${EXPECTED_REPOSITORIES.size} repository rows`);
  }
  for (const [repoPath] of EXPECTED_REPOSITORIES) {
    if (!configRows.some((row) => row.path === repoPath)) usage(`source publication config missing repo path: ${repoPath}`);
  }
  const expectedOrder = [...EXPECTED_REPOSITORIES.keys()];
  if (configRows.some((row, index) => row.path !== expectedOrder[index])) {
    usage(`source publication config repository order must be: ${expectedOrder.join(', ')}`);
  }
  for (const row of configRows) {
    const matches = releasePrRows.filter(
      (candidate) => candidate.repository === row.repository && candidate.head === row.head && candidate.base === row.base,
    );
    if (matches.length !== 1) {
      usage(`release PR config must contain exactly one matching row for ${row.repository}:${row.head}->${row.base}`);
    }
    if (matches[0].requiredState !== 'merged') {
      usage(`release PR config row for ${row.repository}:${row.head} must require merged state`);
    }
    row.requiredState = matches[0].requiredState;
  }
  if (rootOwner.status === 'ready') {
    const matches = releasePrRows.filter(
      (candidate) =>
        candidate.repository === rootOwner.repository &&
        candidate.head === rootOwner.head &&
        candidate.base === rootOwner.base,
    );
    if (matches.length !== 1) {
      usage(`release PR config must contain exactly one matching row for pinned workspace owner ${rootOwner.repository}:${rootOwner.head}->${rootOwner.base}`);
    }
    if (matches[0].requiredState !== 'merged') {
      usage(`release PR config row for pinned workspace owner ${rootOwner.repository}:${rootOwner.head} must require merged state`);
    }
    rootOwner.requiredState = matches[0].requiredState;
  }
}

function parsePreflightReport(target) {
  assertRegularFile(target, 'source publication preflight report');
  if (!testToolInjection) {
    const allowedRoot = path.join(root, 'build', 'reports');
    if (!isPathInside(target, allowedRoot) || path.basename(target) !== 'source-publication-preflight-report.json') {
      usage(`production preflight report must be named source-publication-preflight-report.json inside ${allowedRoot}`);
    }
  }
  let report;
  try {
    report = JSON.parse(readTextFile(target, 'source publication preflight report'));
  } catch (error) {
    usage(`source publication preflight report must be valid JSON: ${error.message}`);
  }
  if (
    !report ||
    typeof report !== 'object' ||
    Array.isArray(report) ||
    report.schemaVersion !== SOURCE_PUBLICATION_REPORT_SCHEMA_VERSION
  ) {
    usage(`source publication preflight report schemaVersion must be ${SOURCE_PUBLICATION_REPORT_SCHEMA_VERSION}`);
  }
  if (report.checkRemote !== true) usage('source publication preflight report must include authoritative remote checks');
  if (report.workspaceRoot !== root || report.workspaceParent !== parent) usage('source publication preflight workspace identity mismatch');
  if (
    report.configFile !== configFile ||
    report.rootOwnerConfigFile !== rootOwnerConfigFile ||
    report.releasePrConfigFile !== releasePrConfigFile
  ) {
    usage('source publication preflight configuration identity mismatch');
  }
  const preflightTime = parseCanonicalUtcTimestamp(report.generatedAt, 'source publication preflight generatedAt');
  const postflightTime = Date.parse(generatedAt);
  const age = postflightTime - preflightTime;
  if (age < 0) usage('source publication preflight report must not postdate the postflight audit');
  if (age > MAX_PREFLIGHT_AGE_MS) usage('source publication preflight report is stale');

  const sources = [report.workspaceSource, ...(Array.isArray(report.repositories) ? report.repositories : [])];
  if (sources.length !== 9) usage('source publication preflight report must contain exactly nine source trees');
  const expectedPaths = ['.', ...EXPECTED_REPOSITORIES.keys()];
  let passed = 0;
  let failed = 0;
  for (const [index, source] of sources.entries()) {
    if (!source || typeof source !== 'object' || Array.isArray(source) || source.path !== expectedPaths[index]) {
      usage(`source publication preflight source identity mismatch at index ${index}`);
    }
    const expectedRepositoryPath = path.resolve(root, expectedPaths[index]);
    if (source.repositoryPath !== expectedRepositoryPath) usage(`source publication preflight repository path mismatch for ${source.path}`);
    if (!['passed', 'failed'].includes(source.status)) usage(`source publication preflight status is invalid for ${source.path}`);
    if (source.status === 'passed') {
      passed += 1;
      const remoteProofIsPresent =
        source.currentBranchRemotePresent === true &&
        source.remoteBranchPresent === true &&
        SHA1.test(source.currentBranchRemoteSha ?? '') &&
        source.currentBranchRemoteSha === source.remoteHeadSha;
      const remoteProofIsDeleted =
        source.currentBranchRemotePresent === false &&
        source.remoteBranchPresent === false &&
        source.currentBranchRemoteSha === null &&
        source.remoteHeadSha === null;
      if (
        source.stagedCount !== 0 ||
        source.unstagedCount !== 0 ||
        source.untrackedCount !== 0 ||
        source.unmergedCount !== 0 ||
        !Array.isArray(source.dirtyPaths) ||
        source.dirtyPaths.length !== 0 ||
        !Array.isArray(source.failures) ||
        source.failures.length !== 0 ||
        !SHA1.test(source.headSha ?? '') ||
        !SHA1.test(source.prHeadSha ?? '') ||
        source.prHeadSha !== source.headSha ||
        (!remoteProofIsPresent && !remoteProofIsDeleted) ||
        source.prState !== 'merged'
      ) {
        usage(`source publication preflight passed-source semantics are invalid for ${source.path}`);
      }
    } else {
      failed += 1;
      if (!Array.isArray(source.failures) || source.failures.length === 0) {
        usage(`source publication preflight failed source lacks diagnostics for ${source.path}`);
      }
    }
  }
  if (
    !report.totals ||
    report.totals.sources !== 9 ||
    report.totals.passed !== passed ||
    report.totals.failed !== failed ||
    report.status !== (failed === 0 ? 'passed' : 'failed')
  ) {
    usage('source publication preflight totals/status mismatch');
  }
  return report;
}

function parseCanonicalUtcTimestamp(value, label) {
  if (typeof value !== 'string' || !/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z$/u.test(value)) {
    usage(`${label} must be a canonical ISO-8601 UTC timestamp`);
  }
  const milliseconds = Date.parse(value);
  if (!Number.isFinite(milliseconds) || new Date(milliseconds).toISOString() !== value) {
    usage(`${label} must be a real canonical ISO-8601 UTC timestamp`);
  }
  return milliseconds;
}

function comparePreflightSources(report, currentSources) {
  const baselineSources = [report.workspaceSource, ...report.repositories];
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
  ];
  currentSources.forEach((source, index) => {
    const baseline = baselineSources[index];
    const addFailure = failureRecorder(source);
    if (baseline.status !== 'passed') {
      addFailure('source publication preflight did not pass before release checks');
      return;
    }
    const changed = identityFields.some((field) => baseline[field] !== source[field]);
    if (changed) addFailure('source identity changed between release preflight and postflight');
  });
}

function createSource(sourcePath, repositoryPath, row = {}) {
  return {
    path: sourcePath,
    repository: row.repository ?? null,
    head: row.head ?? null,
    base: row.base ?? null,
    prNumber: row.prNumber ?? null,
    prUrl: null,
    prState: null,
    prHeadSha: null,
    repositoryPath,
    status: 'failed',
    originUrl: null,
    originRepository: null,
    branch: null,
    headSha: null,
    upstream: null,
    upstreamSha: null,
    currentBranchRemoteSha: null,
    currentBranchRemotePresent: null,
    remoteHeadSha: null,
    remoteBranchPresent: null,
    stagedCount: 0,
    unstagedCount: 0,
    untrackedCount: 0,
    unmergedCount: 0,
    dirtyPaths: [],
    requiredTrackedFiles: [],
    failures: [],
  };
}

function failureRecorder(source) {
  return (message) => {
    source.failures.push(message);
    failures.push(`${source.path}: ${message}`);
  };
}

function inspectWorkspaceSource(rootOwner, releasePrRows) {
  const pinned = rootOwner.status === 'ready'
    ? {
        repository: rootOwner.repository,
        head: rootOwner.head,
        base: rootOwner.base,
        prNumber: rootOwner.prNumber,
      }
    : {};
  const source = createSource('.', root, pinned);
  const addFailure = failureRecorder(source);
  source.requiredTrackedFiles = [...REQUIRED_WORKSPACE_FILES];
  if (rootOwner.status !== 'ready') {
    addFailure(`workspace source owner is blocked: ${ROOT_OWNER_BLOCKER}`);
  }
  if (!inspectGitSource(source, addFailure)) return source;

  if (rootOwner.status === 'ready') {
    if (source.originRepository !== source.repository) {
      addFailure(`workspace origin repository mismatch: expected ${source.repository}, received ${source.originRepository ?? '<invalid>'}`);
    }
    if (source.branch !== source.head) {
      addFailure(`workspace current branch mismatch: expected ${source.head}, received ${source.branch ?? '<unavailable>'}`);
    }
    const matches = releasePrRows.filter(
      (row) => row.repository === source.repository && row.head === source.head && row.base === source.base,
    );
    if (matches.length !== 1 || matches[0].requiredState !== rootOwner.requiredState) {
      addFailure(`release PR config does not match pinned workspace owner ${source.repository}:${source.head}->${source.base}`);
    }
  }

  for (const requiredPath of REQUIRED_WORKSPACE_FILES) {
    const tracked = spawnSync(gitBin, ['ls-files', '--error-unmatch', '--', requiredPath], {
      cwd: root,
      encoding: 'utf8',
      env: cleanGitEnvironment(),
      maxBuffer: 1024 * 1024,
      timeout: TOOL_TIMEOUT_MS,
      killSignal: 'SIGKILL',
    });
    if (tracked.status !== 0 || tracked.stdout.trim() !== requiredPath) {
      addFailure(`required production source is not Git-tracked: ${requiredPath}`);
    }
  }
  const serviceFiles = gitPaths(root, ['ls-files', '-z', '--', 'services/passkey-backup-challenge-service'], addFailure);
  if (serviceFiles.length < 12) addFailure(`passkey challenge service ownership is incomplete: only ${serviceFiles.length} tracked files`);

  if (rootOwner.status === 'ready' && checkRemote) {
    validateCurrentBranchRemote(source, addFailure);
    const pullRequest = fetchPullRequest(source, addFailure);
    if (pullRequest) validatePullRequest(source, pullRequest, rootOwner.requiredState, addFailure);
    validateRemotePublication(source, addFailure);
    const deletedMergedHead = source.remoteBranchPresent === false && source.prState === 'merged';
    validateLocalUpstream(source, addFailure, deletedMergedHead, true);
  } else if (rootOwner.status === 'ready') {
    validateLocalUpstream(source, addFailure, false, false);
  }
  source.status = source.failures.length === 0 ? 'passed' : 'failed';
  return source;
}

function inspectRepository(row) {
  const repoPath = path.resolve(root, row.path);
  const source = createSource(row.path, repoPath, row);
  const addFailure = failureRecorder(source);
  if (!inspectGitSource(source, addFailure)) return source;
  if (source.originRepository !== row.repository) {
    addFailure(`origin repository mismatch: expected ${row.repository}, received ${source.originRepository ?? '<invalid>'}`);
  }
  if (source.branch && source.branch !== row.head) {
    addFailure(`current branch mismatch: expected ${row.head}, received ${source.branch}`);
  }
  if (checkRemote) {
    validateCurrentBranchRemote(source, addFailure);
    const pullRequest = fetchPullRequest(source, addFailure);
    if (pullRequest) validatePullRequest(source, pullRequest, row.requiredState, addFailure);
    validateRemotePublication(source, addFailure);
    const deletedMergedHead = source.remoteBranchPresent === false && source.prState === 'merged';
    validateLocalUpstream(source, addFailure, deletedMergedHead, true);
  } else {
    validateLocalUpstream(source, addFailure, false, false);
  }
  source.status = source.failures.length === 0 ? 'passed' : 'failed';
  return source;
}

function inspectGitSource(source, addFailure) {
  let stat;
  try {
    stat = fs.lstatSync(source.repositoryPath);
  } catch {
    addFailure(`repository path does not exist: ${source.repositoryPath}`);
    return false;
  }
  if (!stat.isDirectory() || stat.isSymbolicLink()) {
    addFailure(`repository path must be a real directory: ${source.repositoryPath}`);
    return false;
  }

  const topLevel = git(source.repositoryPath, ['rev-parse', '--show-toplevel'], addFailure, 'source has no Git repository owner; assign it to a canonical maintained repository and protected release PR');
  if (!topLevel) return false;
  try {
    if (fs.realpathSync(topLevel) !== fs.realpathSync(source.repositoryPath)) addFailure(`Git top-level mismatch: ${topLevel}`);
  } catch {
    addFailure('unable to resolve Git top-level path');
  }
  inspectRepositoryGitMetadataEntry(source.repositoryPath, addFailure);
  const initialLocalState = localStateFingerprint(source);

  const rawOriginUrl = git(source.repositoryPath, ['remote', 'get-url', 'origin'], addFailure, 'origin remote is missing');
  if (rawOriginUrl) {
    source.originRepository = normalizeGitHubRemote(rawOriginUrl);
    if (!source.originRepository) {
      source.originUrl = null;
      addFailure('origin must be a credential-free github.com HTTPS or SSH URL');
    } else {
      source.originUrl = rawOriginUrl;
    }
  }
  source.branch = git(source.repositoryPath, ['symbolic-ref', '--quiet', '--short', 'HEAD'], addFailure, 'HEAD is detached');
  if (source.branch && !SAFE_REF.test(source.branch)) addFailure(`current branch is invalid: ${source.branch}`);
  source.headSha = git(source.repositoryPath, ['rev-parse', '--verify', 'HEAD^{commit}'], addFailure, 'local HEAD commit is unavailable');
  if (source.headSha && !SHA1.test(source.headSha)) addFailure(`local HEAD must be a 40-character lowercase SHA-1: ${source.headSha}`);

  inspectInProgressGitOperations(source.repositoryPath, addFailure);

  const staged = gitPaths(source.repositoryPath, ['diff', '--no-ext-diff', '--no-textconv', '--cached', '--name-only', '-z'], addFailure);
  const unstaged = gitPaths(source.repositoryPath, ['diff', '--no-ext-diff', '--no-textconv', '--ignore-submodules=none', '--name-only', '-z'], addFailure);
  const untracked = gitPaths(source.repositoryPath, ['ls-files', '--others', '--exclude-standard', '-z'], addFailure).filter(
    (untrackedPath) =>
      !isAllowedPostflightGeneratedPath(source, normalizeRepositoryRelativePath(untrackedPath)) ||
      ignoredPathHasSymlinkComponent(source.repositoryPath, untrackedPath),
  );
  const unmerged = gitPaths(source.repositoryPath, ['diff', '--no-ext-diff', '--no-textconv', '--name-only', '--diff-filter=U', '-z'], addFailure);
  const ignored = inspectDisallowedIgnoredPaths(source, addFailure);
  const unsafeIndexFlags = inspectUnsafeIndexFlags(source.repositoryPath, addFailure);
  const escapingSymlinks = inspectTrackedSymlinks(source.repositoryPath, addFailure);
  source.stagedCount = staged.length;
  source.unstagedCount = unstaged.length;
  source.untrackedCount = untracked.length;
  source.unmergedCount = unmerged.length;
  source.dirtyPaths = [
    ...new Set([
      ...staged,
      ...unstaged,
      ...untracked,
      ...unmerged,
      ...ignored,
      ...unsafeIndexFlags,
      ...escapingSymlinks,
    ]),
  ].sort().slice(0, maxPaths);
  if (staged.length || unstaged.length || untracked.length || unmerged.length) {
    addFailure(`worktree is not clean (staged=${staged.length}, unstaged=${unstaged.length}, untracked=${untracked.length}, unmerged=${unmerged.length})`);
  }
  if (ignored.length) {
    addFailure(
      `worktree contains ignored non-published paths (${ignored.length}): ${ignored.slice(0, maxPaths).join(', ')}; ` +
        'remove or quarantine these ignored outputs outside the source tree before publication; do not force-add generated artifacts',
    );
  }
  if (unsafeIndexFlags.length) {
    addFailure(`Git index contains assume-unchanged or skip-worktree paths (${unsafeIndexFlags.length}): ${unsafeIndexFlags.slice(0, maxPaths).join(', ')}`);
  }
  if (escapingSymlinks.length) {
    addFailure(`tracked symlinks escape the repository root (${escapingSymlinks.length}): ${escapingSymlinks.slice(0, maxPaths).join(', ')}`);
  }

  const submodules = spawnSync(gitBin, ['submodule', 'status', '--recursive'], {
    cwd: source.repositoryPath,
    encoding: 'utf8',
    env: cleanGitEnvironment(),
    maxBuffer: 4 * 1024 * 1024,
    timeout: TOOL_TIMEOUT_MS,
    killSignal: 'SIGKILL',
  });
  if (submodules.status !== 0) addFailure('unable to inspect recursive submodule state');
  else if (submodules.stdout.split('\n').filter(Boolean).some((line) => !line.startsWith(' '))) {
    addFailure('submodule state is not pinned and initialized');
  }
  const inspectedLocalState = localStateFingerprint(source);
  if (initialLocalState !== inspectedLocalState) addFailure('local source state changed during initial inspection');
  localStateSnapshots.set(source, inspectedLocalState);
  return true;
}

function inspectRepositoryGitMetadataEntry(repositoryPath, addFailure) {
  const metadataEntry = path.join(repositoryPath, '.git');
  let stat;
  try {
    stat = fs.lstatSync(metadataEntry);
  } catch {
    addFailure('repository .git metadata entry is unavailable');
    return;
  }
  if (stat.isSymbolicLink()) {
    addFailure('repository .git metadata entry must not be a symlink');
    return;
  }
  if (!stat.isDirectory() && !stat.isFile()) {
    addFailure('repository .git metadata entry must be a real directory or a regular linked-worktree file');
  }
}

function inspectInProgressGitOperations(repositoryPath, addFailure) {
  const gitDirectory = resolveCanonicalGitStateDirectory(
    repositoryPath,
    ['rev-parse', '--absolute-git-dir'],
    'Git directory',
    addFailure,
  );
  const commonDirectory = resolveCanonicalGitStateDirectory(
    repositoryPath,
    ['rev-parse', '--path-format=absolute', '--git-common-dir'],
    'Git common directory',
    addFailure,
  );
  const stateDirectories = new Map();
  if (gitDirectory) stateDirectories.set(gitDirectory, 'Git directory');
  if (commonDirectory && !stateDirectories.has(commonDirectory)) {
    stateDirectories.set(commonDirectory, 'Git common directory');
  }

  const operations = new Map();
  for (const [stateDirectory, directoryLabel] of stateDirectories) {
    for (const marker of GIT_OPERATION_MARKERS) {
      const markerPath = path.join(stateDirectory, marker.relativePath);
      let stat;
      try {
        stat = fs.lstatSync(markerPath);
      } catch (error) {
        if (error?.code === 'ENOENT') continue;
        addFailure(`unable to inspect Git operation marker ${marker.relativePath} in the canonical ${directoryLabel.toLowerCase()}`);
        continue;
      }

      if (stat.isSymbolicLink()) {
        addFailure(`Git operation marker ${marker.relativePath} must not be a symlink`);
      } else if (marker.kind === 'file' && !stat.isFile()) {
        addFailure(`Git operation marker ${marker.relativePath} must be a regular file`);
      } else if (marker.kind === 'directory' && !stat.isDirectory()) {
        addFailure(`Git operation marker ${marker.relativePath} must be a real directory`);
      }

      const operationMarkers = operations.get(marker.operation) ?? new Set();
      operationMarkers.add(marker.relativePath);
      operations.set(marker.operation, operationMarkers);
    }
  }

  for (const [operation, markers] of operations) {
    addFailure(
      `repository has an in-progress Git ${operation} operation (${[...markers].sort().join(', ')}); ` +
        'only the repository owner may complete or abort it before source publication',
    );
  }
}

function resolveCanonicalGitStateDirectory(repositoryPath, args, label, addFailure) {
  const raw = git(repositoryPath, args, addFailure, `canonical ${label.toLowerCase()} is unavailable`);
  if (!raw) return null;
  if (!path.isAbsolute(raw) || path.normalize(raw) !== raw) {
    addFailure(`canonical ${label.toLowerCase()} must be an absolute normalized path`);
    return null;
  }

  let stat;
  try {
    stat = fs.lstatSync(raw);
  } catch {
    addFailure(`canonical ${label.toLowerCase()} is unavailable`);
    return null;
  }
  if (!stat.isDirectory() || stat.isSymbolicLink()) {
    addFailure(`canonical ${label.toLowerCase()} must be a real non-symlink directory`);
    return null;
  }

  try {
    return fs.realpathSync.native(raw);
  } catch {
    addFailure(`canonical ${label.toLowerCase()} cannot be resolved`);
    return null;
  }
}

function inspectDisallowedIgnoredPaths(source, addFailure) {
  const ignored = gitPaths(
    source.repositoryPath,
    ['ls-files', '--others', '--ignored', '--exclude-standard', '--directory', '-z'],
    addFailure,
  );
  const disallowed = [];
  for (const rawPath of ignored) {
    const normalized = normalizeRepositoryRelativePath(rawPath);
    if (normalized === '.yarn/' && ['fearless-wallet-web', '../polkaswap-indexer'].includes(source.path) && phase !== 'standalone') {
      const yarnEntries = gitPaths(
        source.repositoryPath,
        ['ls-files', '--others', '--ignored', '--exclude-standard', '-z', '--', '.yarn'],
        addFailure,
      );
      const unsafeYarnEntries = yarnEntries.filter((entry) => !isAllowedYarnCacheEntry(entry));
      const symlinkedYarnEntries = yarnEntries.filter((entry) => ignoredPathHasSymlinkComponent(source.repositoryPath, entry));
      if (unsafeYarnEntries.length || symlinkedYarnEntries.length || ignoredPathHasSymlinkComponent(source.repositoryPath, '.yarn/')) {
        disallowed.push(...unsafeYarnEntries, ...symlinkedYarnEntries, '.yarn/');
      }
      continue;
    }
    if (!isAllowedIgnoredPath(source, normalized) || ignoredPathHasSymlinkComponent(source.repositoryPath, normalized)) {
      disallowed.push(normalized);
    }
  }
  return [...new Set(disallowed)].sort();
}

function normalizeRepositoryRelativePath(value) {
  return value.replaceAll('\\', '/').replace(/^\.\//u, '');
}

function matchesPathPrefix(value, prefix) {
  const normalizedPrefix = prefix.endsWith('/') ? prefix : `${prefix}/`;
  return value === prefix || value === normalizedPrefix || value.startsWith(normalizedPrefix);
}

function isAllowedIgnoredPath(source, ignoredPath) {
  if (source.path === '.' && WORKSPACE_NESTED_REPOSITORIES.some((repositoryPath) => matchesPathPrefix(ignoredPath, repositoryPath))) {
    return true;
  }
  if (phase === 'standalone') return false;

  const cachePrefixes = {
    '.': ['services/passkey-backup-challenge-service/node_modules'],
    'fearless-Android': ['.gradle', '.kotlin', 'buildSrc/.gradle', 'buildSrc/.kotlin'],
    'fearless-iOS': [
      '.build',
      '.bundle',
      'Packages/FearlessDependencies/.build',
      'Packages/FearlessDependencies/.swiftpm',
      'Packages/FearlessUtilsCompat/.swiftpm',
      'Pods',
      'SourcePackages',
      'vendor/bundle',
    ],
    'fearless-wallet-web': ['node_modules'],
    'fearless-site-web': ['node_modules'],
    '../ton-indexer': ['node_modules'],
    '../solswap-indexer': ['node_modules'],
    '../polkaswap-indexer': ['node_modules'],
  }[source.path] ?? [];
  if (cachePrefixes.some((prefix) => matchesPathPrefix(ignoredPath, prefix))) return true;
  return isAllowedPostflightGeneratedPath(source, ignoredPath);
}

function isAllowedPostflightGeneratedPath(source, ignoredPath) {
  if (phase !== 'postflight') return false;

  if (source.path === 'fearless-Android') {
    if (matchesPathPrefix(ignoredPath, 'build')) return true;
    return /^(?:app|buildSrc|common|core-api|core-db|feature-[A-Za-z0-9-]+|public-[A-Za-z0-9-]+|runtime(?:-permission)?|test-shared)\/(?:build|coverage)(?:\/|$)/u.test(ignoredPath);
  }
  const outputPrefixes = {
    '.': ['build', 'services/passkey-backup-challenge-service/build'],
    'fearless-iOS': ['build'],
    'fearless-wallet-web': ['build', 'coverage', 'dist'],
    'fearless-site-web': ['.nuxt', '.output'],
    '../ton-indexer': ['build', 'dist'],
    '../solswap-indexer': ['build', 'dist'],
    '../polkaswap-indexer': ['build', 'dist'],
  }[source.path] ?? [];
  if (outputPrefixes.some((prefix) => matchesPathPrefix(ignoredPath, prefix))) return true;
  return source.path === 'fearless-iOS' && (ignoredPath === 'CIKeys.generated.swift' || ignoredPath === 'R.generated.swift');
}

function isAllowedYarnCacheEntry(value) {
  const normalized = normalizeRepositoryRelativePath(value);
  if (normalized === '.yarn/install-state.gz') return true;
  if (/^\.yarn\/cache\/[A-Za-z0-9_.+~-]+\.zip$/u.test(normalized)) return true;
  return /^\.yarn\/(?:unplugged|sdks)\//u.test(normalized);
}

function ignoredPathHasSymlinkComponent(repositoryPath, ignoredPath) {
  const normalized = normalizeRepositoryRelativePath(ignoredPath).replace(/\/$/u, '');
  if (!normalized || path.isAbsolute(normalized) || normalized.split('/').some((segment) => !segment || segment === '.' || segment === '..')) return true;
  let current = repositoryPath;
  for (const segment of normalized.split('/')) {
    current = path.join(current, segment);
    if (!fs.existsSync(current)) break;
    try {
      if (fs.lstatSync(current).isSymbolicLink()) return true;
    } catch {
      return true;
    }
  }
  return false;
}

function inspectUnsafeIndexFlags(repositoryPath, addFailure) {
  const records = gitRawRecords(repositoryPath, ['ls-files', '-v', '-z'], addFailure, 'index flags');
  const unsafe = [];
  for (const record of records) {
    if (record.length < 3 || record[1] !== ' ') {
      addFailure('git ls-files returned a malformed index flag record');
      continue;
    }
    const tag = record[0];
    if (tag === 'S' || tag === 's' || /[a-z]/u.test(tag)) unsafe.push(record.slice(2).replaceAll('\\', '/'));
  }
  return unsafe;
}

function inspectTrackedSymlinks(repositoryPath, addFailure) {
  const records = gitRawRecords(repositoryPath, ['ls-files', '-s', '-z'], addFailure, 'tracked symlinks');
  const unsafe = [];
  const realRoot = fs.realpathSync.native(repositoryPath);
  const gitMetadata = path.join(realRoot, '.git');
  for (const record of records) {
    const match = record.match(/^([0-7]{6}) ([0-9a-f]{40}) ([0-3])\t([\s\S]+)$/u);
    if (!match) {
      addFailure('git ls-files returned a malformed tracked-file record');
      continue;
    }
    if (match[1] !== '120000' || match[3] !== '0') continue;
    const trackedPath = match[4];
    const linkPath = path.resolve(repositoryPath, trackedPath);
    if (!isPathInside(linkPath, repositoryPath)) {
      unsafe.push(trackedPath.replaceAll('\\', '/'));
      continue;
    }
    let target;
    try {
      const stat = fs.lstatSync(linkPath);
      if (!stat.isSymbolicLink()) throw new Error('not a symbolic link');
      target = fs.readlinkSync(linkPath);
    } catch {
      unsafe.push(trackedPath.replaceAll('\\', '/'));
      continue;
    }
    const lexicalTarget = path.resolve(path.dirname(linkPath), target);
    const resolvedTarget = resolveWithRealPrefix(lexicalTarget);
    if (
      !isPathInside(lexicalTarget, repositoryPath) ||
      !isPathInside(resolvedTarget, realRoot) ||
      resolvedTarget === gitMetadata ||
      resolvedTarget.startsWith(`${gitMetadata}${path.sep}`)
    ) {
      unsafe.push(trackedPath.replaceAll('\\', '/'));
    }
  }
  return unsafe;
}

function isPathInside(candidate, directory) {
  const resolvedCandidate = path.resolve(candidate);
  const resolvedDirectory = path.resolve(directory);
  return resolvedCandidate === resolvedDirectory || resolvedCandidate.startsWith(`${resolvedDirectory}${path.sep}`);
}

function resolveWithRealPrefix(target) {
  const missing = [];
  let existing = path.resolve(target);
  while (!fs.existsSync(existing)) {
    const parentDirectory = path.dirname(existing);
    if (parentDirectory === existing) return existing;
    missing.unshift(path.basename(existing));
    existing = parentDirectory;
  }
  return path.resolve(fs.realpathSync.native(existing), ...missing);
}

function gitRawRecords(cwd, args, addFailure, label) {
  const result = spawnSync(gitBin, args, {
    cwd,
    encoding: 'buffer',
    env: cleanGitEnvironment(),
    maxBuffer: 32 * 1024 * 1024,
    timeout: TOOL_TIMEOUT_MS,
    killSignal: 'SIGKILL',
  });
  if (result.status !== 0) {
    addFailure(`git ${args[0]} failed while inspecting ${label}`);
    return [];
  }
  return result.stdout.toString('utf8').split('\0').filter(Boolean);
}

function localStateFingerprint(source) {
  const repositoryPath = source.repositoryPath;
  const commands = [
    ['rev-parse', '--verify', 'HEAD^{commit}'],
    ['symbolic-ref', '--quiet', '--short', 'HEAD'],
    ['remote', 'get-url', 'origin'],
    ['diff', '--no-ext-diff', '--no-textconv', '--cached', '--name-only', '-z'],
    ['diff', '--no-ext-diff', '--no-textconv', '--ignore-submodules=none', '--name-only', '-z'],
    ['ls-files', '--others', '--exclude-standard', '-z'],
    ['ls-files', '--others', '--ignored', '--exclude-standard', '--directory', '-z'],
    ['diff', '--no-ext-diff', '--no-textconv', '--name-only', '--diff-filter=U', '-z'],
    ['ls-files', '-v', '-z'],
    ['ls-files', '-s', '-z'],
    ['submodule', 'status', '--recursive'],
  ];
  const records = commands.map((args) => {
    const result = spawnSync(gitBin, args, {
      cwd: repositoryPath,
      encoding: 'buffer',
      env: cleanGitEnvironment(),
      maxBuffer: 32 * 1024 * 1024,
      timeout: TOOL_TIMEOUT_MS,
      killSignal: 'SIGKILL',
    });
    let stdout = result.stdout ?? Buffer.alloc(0);
    if (args[0] === 'ls-files' && args.includes('--ignored')) {
      const retained = stdout
        .toString('utf8')
        .split('\0')
        .filter(Boolean)
        .map(normalizeRepositoryRelativePath)
        .filter((ignoredPath) => !isAllowedIgnoredPath(source, ignoredPath));
      stdout = Buffer.from(retained.length ? `${retained.join('\0')}\0` : '');
    } else if (args[0] === 'ls-files' && args.includes('--others') && phase === 'postflight') {
      const retained = stdout
        .toString('utf8')
        .split('\0')
        .filter(Boolean)
        .map(normalizeRepositoryRelativePath)
        .filter((untrackedPath) => !isAllowedPostflightGeneratedPath(source, untrackedPath));
      stdout = Buffer.from(retained.length ? `${retained.join('\0')}\0` : '');
    }
    return {
      args,
      status: result.status,
      signal: result.signal,
      stdout: stdout.toString('base64'),
      stderr: result.stderr?.toString('base64') ?? '',
      error: result.error?.code ?? null,
    };
  });
  const gitOperationState = snapshotGitOperationState(repositoryPath);
  return crypto.createHash('sha256').update(JSON.stringify({ records, gitOperationState })).digest('hex');
}

function snapshotGitOperationState(repositoryPath) {
  const directoryQueries = [
    ['rev-parse', '--absolute-git-dir'],
    ['rev-parse', '--path-format=absolute', '--git-common-dir'],
  ];
  const directories = [];
  const queryResults = [];
  for (const args of directoryQueries) {
    const result = spawnSync(gitBin, args, {
      cwd: repositoryPath,
      encoding: 'utf8',
      env: cleanGitEnvironment(),
      maxBuffer: 1024 * 1024,
      timeout: TOOL_TIMEOUT_MS,
      killSignal: 'SIGKILL',
    });
    const raw = result.status === 0 ? result.stdout.trim() : '';
    queryResults.push({ args, status: result.status, signal: result.signal, raw, error: result.error?.code ?? null });
    if (!raw || !path.isAbsolute(raw) || path.normalize(raw) !== raw) continue;
    try {
      const stat = fs.lstatSync(raw);
      if (!stat.isDirectory() || stat.isSymbolicLink()) continue;
      const resolved = fs.realpathSync.native(raw);
      if (!directories.includes(resolved)) directories.push(resolved);
    } catch {
      // The query result is retained above, so an unavailable directory still changes the fingerprint.
    }
  }

  const markers = [];
  for (const directory of directories.sort()) {
    for (const marker of GIT_OPERATION_MARKERS) {
      const markerPath = path.join(directory, marker.relativePath);
      try {
        const stat = fs.lstatSync(markerPath);
        markers.push({
          directory,
          marker: marker.relativePath,
          type: stat.isSymbolicLink()
            ? 'symlink'
            : stat.isFile()
              ? 'file'
              : stat.isDirectory()
                ? 'directory'
                : 'other',
        });
      } catch (error) {
        if (error?.code !== 'ENOENT') markers.push({ directory, marker: marker.relativePath, type: 'unavailable' });
      }
    }
  }
  return { queryResults, markers };
}

function finalLocalStateRecheck(source) {
  const expected = localStateSnapshots.get(source);
  if (!expected) return;
  const addFailure = failureRecorder(source);
  const current = localStateFingerprint(source);
  if (current !== expected) addFailure('local source state changed after publication inspection');
  const unsafeSymlinks = inspectTrackedSymlinks(source.repositoryPath, addFailure);
  if (unsafeSymlinks.length && !source.failures.some((failure) => failure.startsWith('tracked symlinks escape'))) {
    addFailure(`tracked symlinks escape the repository root (${unsafeSymlinks.length}): ${unsafeSymlinks.slice(0, maxPaths).join(', ')}`);
  }
}

function fetchPullRequest(source, addFailure) {
  const result = runGh(['api', `repos/${source.repository}/pulls/${source.prNumber}`]);
  if (result.status !== 0) {
    addFailure(`authoritative pull request query failed for ${source.repository}#${source.prNumber}`);
    return null;
  }
  return parsePullRequestJson(result.stdout, `${source.repository}#${source.prNumber}`, addFailure);
}

function parsePullRequestJson(value, label, addFailure) {
  try {
    const parsed = JSON.parse(value);
    if (!parsed || typeof parsed !== 'object' || Array.isArray(parsed)) throw new Error('not an object');
    return parsed;
  } catch {
    addFailure(`authoritative pull request ${label} returned invalid JSON`);
    return null;
  }
}

function validatePullRequest(source, pullRequest, requiredState, addFailure) {
  const number = pullRequest.number;
  const expectedUrl = `https://github.com/${source.repository}/pull/${number}`;
  const state = pullRequest.merged_at ? 'merged' : pullRequest.state;
  if (!Number.isSafeInteger(number) || number <= 0) addFailure('pull request number is invalid');
  if (source.prNumber !== null && number !== source.prNumber) {
    addFailure(`pull request number mismatch: expected ${source.prNumber}, received ${number}`);
  }
  source.prNumber = number;
  source.prUrl = pullRequest.html_url ?? null;
  source.prState = state ?? null;
  if (pullRequest.html_url !== expectedUrl) addFailure(`pull request URL mismatch: expected ${expectedUrl}`);
  if (!pullRequest.base || pullRequest.base.ref !== source.base || pullRequest.base.repo?.full_name !== source.repository) {
    addFailure(`pull request base identity mismatch: expected ${source.repository}:${source.base}`);
  }
  if (!pullRequest.head || pullRequest.head.ref !== source.head || pullRequest.head.repo?.full_name !== source.repository) {
    addFailure(`pull request head identity mismatch: expected ${source.repository}:${source.head}`);
  }
  const prHeadSha = typeof pullRequest.head?.sha === 'string' ? pullRequest.head.sha.toLowerCase() : '';
  if (!SHA1.test(prHeadSha)) addFailure('pull request head SHA is missing or malformed');
  else {
    source.prHeadSha = prHeadSha;
    if (source.headSha && prHeadSha !== source.headSha) {
      addFailure(`local HEAD ${source.headSha} does not match pull request head ${prHeadSha}`);
    }
  }
  if (state !== requiredState) {
    addFailure(`pull request state mismatch: required ${requiredState}, received ${state ?? 'unknown'}`);
  }
  if (pullRequest.merged_at) {
    const parsed = new Date(pullRequest.merged_at);
    if (!/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$/u.test(pullRequest.merged_at) || Number.isNaN(parsed.getTime())) {
      addFailure('pull request merged_at timestamp is malformed');
    } else if (parsed.getTime() > Date.parse(generatedAt) + 5 * 60 * 1000) {
      addFailure('pull request merged_at timestamp must not be in the future');
    }
  }
}

function validateCurrentBranchRemote(source, addFailure) {
  if (!source.branch || !SAFE_REF.test(source.branch)) {
    addFailure('authoritative current branch cannot be queried because the local branch identity is unavailable or invalid');
    return;
  }
  // When the checkout is already on the configured PR head, the configured-head query below
  // is also the authoritative current-branch query. Reuse that single observation so two API
  // calls cannot create a false proof or a branch-deletion TOCTOU window.
  if (source.branch === source.head) return;
  const endpoint = `repos/${source.repository}/git/ref/heads/${source.branch}`;
  const remote = runGh(['api', endpoint]);
  const branchMissing = remote.status !== 0 && /\bHTTP 404\b/u.test(remote.stderr ?? '');
  source.currentBranchRemotePresent = branchMissing ? false : remote.status === 0 ? true : null;
  if (branchMissing) {
    addFailure(`authoritative current branch is missing or deleted: ${source.branch}`);
    return;
  }
  if (remote.status !== 0) {
    addFailure(`authoritative current branch is unavailable: ${source.branch}`);
    return;
  }
  let parsed = null;
  try {
    parsed = JSON.parse(remote.stdout);
  } catch {
    // Report the same bounded diagnostic for malformed transport and schema.
  }
  const sha = parsed?.object?.sha;
  if (
    !parsed ||
    typeof parsed !== 'object' ||
    Array.isArray(parsed) ||
    parsed.ref !== `refs/heads/${source.branch}` ||
    parsed.object?.type !== 'commit' ||
    typeof sha !== 'string' ||
    !SHA1.test(sha)
  ) {
    addFailure(`authoritative current branch response is malformed: ${source.branch}`);
    return;
  }
  source.currentBranchRemoteSha = sha;
  if (source.headSha && sha !== source.headSha) {
    addFailure(`local HEAD ${source.headSha} does not match authoritative current branch ${source.branch} at ${sha}`);
  }
}

function validateRemotePublication(source, addFailure) {
  const endpoint = `repos/${source.repository}/git/ref/heads/${source.head}`;
  const remote = runGh(['api', endpoint]);
  const branchMissing = remote.status !== 0 && /\bHTTP 404\b/u.test(remote.stderr ?? '');
  source.remoteBranchPresent = branchMissing ? false : remote.status === 0 ? true : null;
  if (branchMissing) {
    if (source.prState !== 'merged') addFailure(`authoritative remote branch is missing for unmerged pull request ${source.prNumber}`);
  } else if (remote.status !== 0) {
    addFailure(`authoritative remote head is unavailable for ${source.head}`);
  } else {
    let parsed = null;
    try {
      parsed = JSON.parse(remote.stdout);
    } catch {
      // Report the same bounded diagnostic for malformed transport and schema.
    }
    const sha = parsed?.object?.sha;
    if (
      !parsed ||
      typeof parsed !== 'object' ||
      Array.isArray(parsed) ||
      parsed.ref !== `refs/heads/${source.head}` ||
      parsed.object?.type !== 'commit' ||
      typeof sha !== 'string' ||
      !SHA1.test(sha)
    ) {
      addFailure(`authoritative remote head response is malformed for ${source.head}`);
    } else {
      source.remoteHeadSha = sha;
      if (source.headSha && sha !== source.headSha) {
        addFailure(`local HEAD ${source.headSha} does not match authoritative remote head ${sha}`);
      }
    }
  }
  if (source.branch === source.head) {
    source.currentBranchRemotePresent = source.remoteBranchPresent;
    source.currentBranchRemoteSha = source.remoteHeadSha;
  }
}

function validateLocalUpstream(source, addFailure, missingAllowed, bindAuthoritativeCurrentBranch) {
  const upstream = spawnSync(gitBin, ['rev-parse', '--verify', '--abbrev-ref', '@{upstream}'], {
    cwd: source.repositoryPath,
    encoding: 'utf8',
    env: cleanGitEnvironment(),
    maxBuffer: 1024 * 1024,
    timeout: TOOL_TIMEOUT_MS,
    killSignal: 'SIGKILL',
  });
  if (upstream.status !== 0) {
    if (!missingAllowed) addFailure(`upstream branch is missing or deleted; expected origin/${source.head}`);
    return;
  }
  source.upstream = upstream.stdout.trim();
  if (source.upstream !== `origin/${source.head}`) {
    addFailure(`upstream mismatch: expected origin/${source.head}, received ${source.upstream}`);
  }
  const upstreamSha = git(source.repositoryPath, ['rev-parse', '--verify', '@{upstream}^{commit}'], addFailure, 'upstream commit is unavailable');
  source.upstreamSha = upstreamSha;
  if (upstreamSha && !SHA1.test(upstreamSha)) addFailure(`upstream commit must be a 40-character lowercase SHA-1: ${upstreamSha}`);
  if (source.headSha && upstreamSha && source.headSha !== upstreamSha) {
    addFailure(`local HEAD ${source.headSha} does not match upstream ${upstreamSha}`);
  }
  if (
    bindAuthoritativeCurrentBranch &&
    source.branch &&
    source.upstream === `origin/${source.branch}` &&
    upstreamSha &&
    source.currentBranchRemoteSha &&
    upstreamSha !== source.currentBranchRemoteSha
  ) {
    addFailure(
      `cached upstream ${source.upstream} at ${upstreamSha} does not match authoritative current branch ` +
        `${source.branch} at ${source.currentBranchRemoteSha}`,
    );
  }
}

function runGh(args) {
  if (args[0] !== 'api') throw new Error('unsupported gh operation');
  return spawnSync(ghBin, ['api', '--hostname', 'github.com', ...args.slice(1)], {
    cwd: root,
    encoding: 'utf8',
    env: cleanToolEnvironment({ GH_PROMPT_DISABLED: '1', GIT_TERMINAL_PROMPT: '0' }),
    maxBuffer: 8 * 1024 * 1024,
    timeout: TOOL_TIMEOUT_MS,
    killSignal: 'SIGKILL',
  });
}

function git(cwd, args, addFailure, customFailure) {
  const result = spawnSync(gitBin, args, {
    cwd,
    encoding: 'utf8',
    env: cleanGitEnvironment(),
    maxBuffer: 4 * 1024 * 1024,
    timeout: TOOL_TIMEOUT_MS,
    killSignal: 'SIGKILL',
  });
  if (result.status !== 0) {
    addFailure(customFailure ?? `git ${args[0]} failed`);
    return null;
  }
  return result.stdout.trim();
}

function gitPaths(cwd, args, addFailure) {
  const result = spawnSync(gitBin, args, {
    cwd,
    encoding: 'buffer',
    env: cleanGitEnvironment(),
    maxBuffer: 16 * 1024 * 1024,
    timeout: TOOL_TIMEOUT_MS,
    killSignal: 'SIGKILL',
  });
  if (result.status !== 0) {
    addFailure(`git ${args[0]} failed while inspecting worktree state`);
    return [];
  }
  return result.stdout
    .toString('utf8')
    .split('\0')
    .filter(Boolean)
    .map((value) => value.replaceAll('\\', '/'));
}

function normalizeGitHubRemote(value) {
  if (/^git@github\.com:[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+(?:\.git)?$/u.test(value)) {
    return value.replace(/^git@github\.com:/u, '').replace(/\.git$/u, '');
  }
  if (/^ssh:\/\/git@github\.com\/[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+(?:\.git)?$/u.test(value)) {
    return value.replace(/^ssh:\/\/git@github\.com\//u, '').replace(/\.git$/u, '');
  }
  try {
    const url = new URL(value);
    if (url.protocol !== 'https:' || url.hostname !== 'github.com' || url.username || url.password || url.search || url.hash) return null;
    const match = url.pathname.match(/^\/([A-Za-z0-9_.-]+)\/([A-Za-z0-9_.-]+?)(?:\.git)?$/u);
    return match ? `${match[1]}/${match[2]}` : null;
  } catch {
    return null;
  }
}

function writeReport(target, value) {
  const parentDirectory = path.dirname(target);
  assertNoSymlinkPathComponents(parentDirectory, 'report output parent');
  fs.mkdirSync(parentDirectory, { recursive: true });
  if (fs.existsSync(target)) {
    const stat = fs.lstatSync(target);
    if (!stat.isFile() || stat.isSymbolicLink()) usage(`report output must be a regular non-symlink file: ${target}`);
  }
  assertNoSymlinkPathComponents(parentDirectory, 'report output parent');
  const temporary = `${target}.tmp-${process.pid}-${crypto.randomBytes(8).toString('hex')}`;
  fs.writeFileSync(temporary, `${JSON.stringify(value, null, 2)}\n`, { mode: 0o600, flag: 'wx' });
  assertNoSymlinkPathComponents(parentDirectory, 'report output parent');
  fs.renameSync(temporary, target);
}
