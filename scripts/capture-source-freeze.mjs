#!/usr/bin/env node

import { spawnSync } from 'node:child_process';
import crypto from 'node:crypto';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const SCRIPT_DIR = path.dirname(fileURLToPath(import.meta.url));
const WORKSPACE_ROOT = path.resolve(SCRIPT_DIR, '..');
const WORKSPACE_PARENT = path.dirname(WORKSPACE_ROOT);
const GIT_BIN = '/usr/bin/git';
const MAX_GIT_OUTPUT = 256 * 1024 * 1024;
const TOOL_TIMEOUT_MS = 120_000;
const REPOSITORIES = Object.freeze([
  'fearless-Android',
  'fearless-iOS',
  'fearless-wallet-web',
  'fearless-site-web-app-associations-20260726',
  '../ton-indexer',
  '../solswap-indexer',
  '../polkaswap-indexer',
  '../iroha',
]);
const PUBLIC_ROOT_SOURCE_PATHS = Object.freeze([
  'FEARLESS_PROJECT_PLAN.md',
  'config',
  'docs',
  'scripts',
  'services/passkey-backup-challenge-service',
]);
const EXCLUDED_PUBLIC_ROOT_COMPONENTS = new Set(['build', 'node_modules']);
const DANGEROUS_GIT_ENVIRONMENT = new Set([
  'GIT_ALTERNATE_OBJECT_DIRECTORIES',
  'GIT_ASKPASS',
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
  'GIT_SSH',
  'GIT_SSH_COMMAND',
  'GIT_WORK_TREE',
]);

function fail(message) {
  console.error(`[source-freeze][error] ${message}`);
  process.exit(1);
}

function parseArgs(args) {
  if (args.length !== 2 || args[0] !== '--output') {
    fail('usage: scripts/capture-source-freeze.mjs --output build/reports/source-freeze-<timestamp>');
  }
  const requested = path.resolve(WORKSPACE_ROOT, args[1]);
  const allowedRoot = path.join(WORKSPACE_ROOT, 'build', 'reports');
  if (requested === allowedRoot || !requested.startsWith(`${allowedRoot}${path.sep}`)) {
    fail(`output must be a new directory below ${allowedRoot}`);
  }
  return requested;
}

function assertNoSymlinkComponents(target, allowMissingSuffix = false) {
  const absolute = path.resolve(target);
  const filesystemRoot = path.parse(absolute).root;
  let current = filesystemRoot;
  for (const component of path.relative(filesystemRoot, absolute).split(path.sep).filter(Boolean)) {
    current = path.join(current, component);
    let stat;
    try {
      stat = fs.lstatSync(current);
    } catch (error) {
      if (allowMissingSuffix && error?.code === 'ENOENT') return;
      throw error;
    }
    if (stat.isSymbolicLink()) fail(`path must not contain symlinks: ${current}`);
  }
}

function cleanGitEnvironment() {
  const env = { ...process.env };
  for (const key of Object.keys(env)) {
    if (DANGEROUS_GIT_ENVIRONMENT.has(key) || /^GIT_CONFIG_(?:KEY|VALUE)_\d+$/u.test(key) || /^GIT_TRACE/u.test(key)) {
      delete env[key];
    }
  }
  return {
    ...env,
    GIT_CONFIG_GLOBAL: os.devNull,
    GIT_CONFIG_NOSYSTEM: '1',
    GIT_CONFIG_COUNT: '5',
    GIT_CONFIG_KEY_0: 'core.fsmonitor',
    GIT_CONFIG_VALUE_0: 'false',
    GIT_CONFIG_KEY_1: 'core.hooksPath',
    GIT_CONFIG_VALUE_1: os.devNull,
    GIT_CONFIG_KEY_2: 'core.askPass',
    GIT_CONFIG_VALUE_2: '/usr/bin/false',
    GIT_CONFIG_KEY_3: 'credential.helper',
    GIT_CONFIG_VALUE_3: '',
    GIT_CONFIG_KEY_4: 'credential.interactive',
    GIT_CONFIG_VALUE_4: 'false',
    GIT_TERMINAL_PROMPT: '0',
    GIT_PAGER: 'cat',
  };
}

function runGit(repositoryPath, args, { allowFailure = false } = {}) {
  const result = spawnSync(GIT_BIN, ['--literal-pathspecs', ...args], {
    cwd: repositoryPath,
    encoding: 'buffer',
    env: cleanGitEnvironment(),
    maxBuffer: MAX_GIT_OUTPUT,
    timeout: TOOL_TIMEOUT_MS,
    killSignal: 'SIGKILL',
  });
  if (result.status !== 0) {
    if (allowFailure) return null;
    const diagnostic = result.stderr?.toString('utf8').trim() || result.error?.code || `status ${result.status}`;
    fail(`git ${args[0]} failed in ${repositoryPath}: ${diagnostic}`);
  }
  return result.stdout;
}

function sha256(buffer) {
  return crypto.createHash('sha256').update(buffer).digest('hex');
}

function decodeText(buffer, label) {
  try {
    return new TextDecoder('utf-8', { fatal: true }).decode(buffer).trim();
  } catch {
    fail(`${label} is not valid UTF-8`);
  }
}

function decodeNulPaths(buffer, label) {
  if (buffer.length === 0) return [];
  if (buffer[buffer.length - 1] !== 0) fail(`${label} is not NUL-terminated`);
  const decoder = new TextDecoder('utf-8', { fatal: true });
  const result = [];
  let start = 0;
  for (let index = 0; index < buffer.length; index += 1) {
    if (buffer[index] !== 0) continue;
    try {
      result.push(decoder.decode(buffer.subarray(start, index)));
    } catch {
      fail(`${label} contains a non-UTF-8 path`);
    }
    start = index + 1;
  }
  return result;
}

function safeArtifactName(relativePath) {
  return relativePath.replace(/^\.\.\//u, 'parent-').replaceAll('/', '-').replace(/[^A-Za-z0-9._-]/gu, '_');
}

function writePrivateFile(target, value) {
  fs.writeFileSync(target, value, { mode: 0o600, flag: 'wx' });
}

function normalizeOrigin(value) {
  const text = value.trim();
  const https = /^https:\/\/github\.com\/([^/\s]+)\/([^/\s]+?)(?:\.git)?$/u.exec(text);
  if (https) return `${https[1]}/${https[2]}`;
  const ssh = /^(?:ssh:\/\/git@github\.com\/|git@github\.com:)([^/\s]+)\/([^/\s]+?)(?:\.git)?$/u.exec(text);
  return ssh ? `${ssh[1]}/${ssh[2]}` : null;
}

function countPaths(repositoryPath, args, label) {
  const buffer = runGit(repositoryPath, args);
  return { buffer, paths: decodeNulPaths(buffer, label) };
}

function captureRepository(relativePath, outputDirectory) {
  const repositoryPath = path.resolve(WORKSPACE_ROOT, relativePath);
  assertNoSymlinkComponents(repositoryPath);
  const stat = fs.lstatSync(repositoryPath);
  if (!stat.isDirectory()) fail(`repository path is not a directory: ${repositoryPath}`);

  const topLevel = decodeText(runGit(repositoryPath, ['rev-parse', '--show-toplevel']), `${relativePath} top-level`);
  if (fs.realpathSync.native(topLevel) !== fs.realpathSync.native(repositoryPath)) {
    fail(`Git top-level mismatch for ${relativePath}: ${topLevel}`);
  }

  const statusBefore = runGit(repositoryPath, ['status', '--porcelain=v2', '-z', '--untracked-files=all']);
  const headSha = decodeText(runGit(repositoryPath, ['rev-parse', '--verify', 'HEAD^{commit}']), `${relativePath} HEAD`);
  const treeSha = decodeText(runGit(repositoryPath, ['rev-parse', '--verify', 'HEAD^{tree}']), `${relativePath} tree`);
  const branchBuffer = runGit(repositoryPath, ['symbolic-ref', '--quiet', '--short', 'HEAD'], { allowFailure: true });
  const branch = branchBuffer ? decodeText(branchBuffer, `${relativePath} branch`) : null;
  const upstreamBuffer = runGit(repositoryPath, ['rev-parse', '--abbrev-ref', '--symbolic-full-name', '@{upstream}'], { allowFailure: true });
  const upstream = upstreamBuffer ? decodeText(upstreamBuffer, `${relativePath} upstream`) : null;
  const upstreamShaBuffer = upstream
    ? runGit(repositoryPath, ['rev-parse', '--verify', `${upstream}^{commit}`], { allowFailure: true })
    : null;
  const upstreamSha = upstreamShaBuffer ? decodeText(upstreamShaBuffer, `${relativePath} upstream SHA`) : null;
  let ahead = null;
  let behind = null;
  if (upstream) {
    const countsBuffer = runGit(repositoryPath, ['rev-list', '--left-right', '--count', `${upstream}...HEAD`], { allowFailure: true });
    if (countsBuffer) {
      const counts = decodeText(countsBuffer, `${relativePath} ahead/behind`).split(/\s+/u).map(Number);
      if (counts.length === 2 && counts.every(Number.isSafeInteger)) [behind, ahead] = counts;
    }
  }
  const originBuffer = runGit(repositoryPath, ['remote', 'get-url', 'origin'], { allowFailure: true });
  const originRepository = originBuffer ? normalizeOrigin(decodeText(originBuffer, `${relativePath} origin`)) : null;

  const binaryDiff = runGit(repositoryPath, [
    'diff',
    '--binary',
    '--full-index',
    '--no-ext-diff',
    '--no-textconv',
    '--ignore-submodules=none',
    'HEAD',
    '--',
  ]);
  const staged = countPaths(repositoryPath, ['diff', '--cached', '--name-only', '-z', '--'], `${relativePath} staged paths`);
  const unstaged = countPaths(repositoryPath, ['diff', '--name-only', '-z', '--'], `${relativePath} unstaged paths`);
  const untracked = countPaths(repositoryPath, ['ls-files', '--others', '--exclude-standard', '-z'], `${relativePath} untracked paths`);
  const generated = countPaths(
    repositoryPath,
    ['ls-files', '--others', '--ignored', '--exclude-standard', '--directory', '-z'],
    `${relativePath} generated paths`,
  );

  const artifactPrefix = safeArtifactName(relativePath);
  const patchName = `${artifactPrefix}.binary.patch`;
  const statusName = `${artifactPrefix}.status-v2.nul`;
  const untrackedName = `${artifactPrefix}.untracked.nul`;
  const generatedName = `${artifactPrefix}.generated.nul`;
  writePrivateFile(path.join(outputDirectory, patchName), binaryDiff);
  writePrivateFile(path.join(outputDirectory, statusName), statusBefore);
  writePrivateFile(path.join(outputDirectory, untrackedName), untracked.buffer);
  writePrivateFile(path.join(outputDirectory, generatedName), generated.buffer);

  const statusAfter = runGit(repositoryPath, ['status', '--porcelain=v2', '-z', '--untracked-files=all']);
  const headAfter = decodeText(runGit(repositoryPath, ['rev-parse', '--verify', 'HEAD^{commit}']), `${relativePath} final HEAD`);
  if (headAfter !== headSha || !statusAfter.equals(statusBefore)) {
    fail(`source state changed while capturing ${relativePath}; discard this incomplete freeze and retry`);
  }

  return {
    path: relativePath,
    repositoryPath,
    originRepository,
    headSha,
    treeSha,
    branch,
    upstream,
    upstreamSha,
    ahead,
    behind,
    stagedCount: staged.paths.length,
    unstagedCount: unstaged.paths.length,
    untrackedCount: untracked.paths.length,
    generatedRootCount: generated.paths.length,
    binaryDiff: { file: patchName, bytes: binaryDiff.length, sha256: sha256(binaryDiff) },
    status: { file: statusName, bytes: statusBefore.length, sha256: sha256(statusBefore) },
    untrackedInventory: { file: untrackedName, bytes: untracked.buffer.length, sha256: sha256(untracked.buffer) },
    generatedOutputInventory: { file: generatedName, bytes: generated.buffer.length, sha256: sha256(generated.buffer) },
  };
}

function walkPublicRootSource() {
  const records = [];
  const visit = (absolutePath, relativePath) => {
    const stat = fs.lstatSync(absolutePath);
    if (stat.isSymbolicLink()) {
      records.push({ path: relativePath, type: 'symlink', target: fs.readlinkSync(absolutePath) });
      return;
    }
    if (stat.isDirectory()) {
      if (relativePath.split('/').some((component) => EXCLUDED_PUBLIC_ROOT_COMPONENTS.has(component))) return;
      for (const entry of fs.readdirSync(absolutePath).sort()) visit(path.join(absolutePath, entry), `${relativePath}/${entry}`);
      return;
    }
    if (stat.isFile()) {
      const content = fs.readFileSync(absolutePath);
      records.push({ path: relativePath, type: 'file', mode: stat.mode & 0o777, bytes: stat.size, sha256: sha256(content) });
      return;
    }
    records.push({ path: relativePath, type: 'other', mode: stat.mode & 0o777 });
  };
  for (const relativePath of PUBLIC_ROOT_SOURCE_PATHS) {
    const absolutePath = path.join(WORKSPACE_ROOT, relativePath);
    if (fs.existsSync(absolutePath)) visit(absolutePath, relativePath);
  }
  return records;
}

function captureWorkspaceIdentity() {
  const gitEntry = path.join(WORKSPACE_ROOT, '.git');
  if (!fs.existsSync(gitEntry)) return { gitOwned: false };
  const topLevel = runGit(WORKSPACE_ROOT, ['rev-parse', '--show-toplevel'], { allowFailure: true });
  if (!topLevel) return { gitOwned: false, invalidGitMetadata: true };
  return {
    gitOwned: true,
    topLevel: decodeText(topLevel, 'workspace Git top-level'),
    headSha: decodeText(runGit(WORKSPACE_ROOT, ['rev-parse', '--verify', 'HEAD^{commit}']), 'workspace HEAD'),
    treeSha: decodeText(runGit(WORKSPACE_ROOT, ['rev-parse', '--verify', 'HEAD^{tree}']), 'workspace tree'),
  };
}

const outputDirectory = parseArgs(process.argv.slice(2));
assertNoSymlinkComponents(path.dirname(outputDirectory));
if (fs.existsSync(outputDirectory)) fail(`output directory already exists: ${outputDirectory}`);
fs.mkdirSync(outputDirectory, { mode: 0o700 });
assertNoSymlinkComponents(outputDirectory);

const generatedAt = new Date().toISOString();
const manifest = {
  schemaVersion: 1,
  generatedAt,
  workspaceRoot: WORKSPACE_ROOT,
  workspaceParent: WORKSPACE_PARENT,
  workspaceIdentity: captureWorkspaceIdentity(),
  publicRootSourceInventory: walkPublicRootSource(),
  repositories: REPOSITORIES.map((repository) => captureRepository(repository, outputDirectory)),
};
const manifestBuffer = Buffer.from(`${JSON.stringify(manifest, null, 2)}\n`, 'utf8');
writePrivateFile(path.join(outputDirectory, 'manifest.json'), manifestBuffer);

const checksumLines = fs.readdirSync(outputDirectory)
  .sort()
  .map((file) => {
    const content = fs.readFileSync(path.join(outputDirectory, file));
    return `${sha256(content)}  ${file}`;
  });
writePrivateFile(path.join(outputDirectory, 'SHA256SUMS'), Buffer.from(`${checksumLines.join('\n')}\n`, 'utf8'));

console.log(`[source-freeze] captured ${manifest.repositories.length} repositories in ${outputDirectory}`);
console.log(`[source-freeze] manifest_sha256=${sha256(manifestBuffer)}`);
