#!/usr/bin/env node

import { spawnSync } from 'node:child_process';
import crypto from 'node:crypto';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

const SCRIPT_DIR = path.dirname(fileURLToPath(import.meta.url));
const DEFAULT_ROOT = path.resolve(SCRIPT_DIR, '..');
const FORBIDDEN_REPOSITORY = '../iroha';
const MAINTAINED_REPOSITORIES = Object.freeze([
  'fearless-Android-production-consolidated-20260731',
  'fearless-iOS-production-consolidated-20260731',
  'fearless-wallet-web',
  'fearless-site-web-app-associations-20260726',
  '../ton-indexer',
  '../solswap-indexer',
  '../polkaswap-indexer',
]);
const EXPECTED_CONFIG_PATHS = Object.freeze([...MAINTAINED_REPOSITORIES, FORBIDDEN_REPOSITORY]);
const WORKTREE_OWNERS = Object.freeze({
  'fearless-Android-production-consolidated-20260731': 'fearless-Android',
  'fearless-iOS-production-consolidated-20260731': 'fearless-iOS',
  'fearless-site-web-app-associations-20260726': 'fearless-site-web',
});
const TOOL_TIMEOUT_MS = 30_000;
const MAX_GIT_OUTPUT = 64 * 1024 * 1024;
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
  throw new Error(message);
}

function parseArgs(args) {
  const parsed = { mode: 'dry-run', root: null, config: null, rollbackManifest: null, testMode: false };
  for (let index = 0; index < args.length; index += 1) {
    const arg = args[index];
    if (arg === '--apply') {
      if (parsed.mode !== 'dry-run') fail('--apply and --rollback are mutually exclusive');
      parsed.mode = 'apply';
      continue;
    }
    if (arg === '--rollback') {
      if (parsed.mode !== 'dry-run') fail('--apply and --rollback are mutually exclusive');
      const value = args[index + 1];
      if (!value) fail('--rollback requires a manifest path');
      parsed.mode = 'rollback';
      parsed.rollbackManifest = value;
      index += 1;
      continue;
    }
    if (arg === '--test-mode') {
      parsed.testMode = true;
      continue;
    }
    if (arg === '--root' || arg === '--config') {
      const value = args[index + 1];
      if (!value) fail(`${arg} requires a value`);
      parsed[arg.slice(2)] = value;
      index += 1;
      continue;
    }
    fail(`unknown argument: ${arg}`);
  }
  return parsed;
}

function assertNoSymlinkComponents(target, label, allowMissingSuffix = false) {
  const absolute = path.resolve(target);
  const filesystemRoot = path.parse(absolute).root;
  let current = filesystemRoot;
  for (const segment of path.relative(filesystemRoot, absolute).split(path.sep).filter(Boolean)) {
    current = path.join(current, segment);
    let stat;
    try {
      stat = fs.lstatSync(current);
    } catch (error) {
      if (allowMissingSuffix && error?.code === 'ENOENT') return;
      fail(`${label} path component is unavailable: ${current}`);
    }
    if (stat.isSymbolicLink()) fail(`${label} must not use a symlinked path component: ${current}`);
  }
}

function assertRealDirectory(target, label) {
  assertNoSymlinkComponents(target, label);
  const stat = fs.lstatSync(target);
  if (!stat.isDirectory() || stat.isSymbolicLink()) fail(`${label} must be a real non-symlink directory: ${target}`);
  return fs.realpathSync.native(target);
}

function readRegularFile(target, label, maxBytes = 4096) {
  assertNoSymlinkComponents(target, label);
  const before = snapshotEntry(target);
  if (before.type !== 'file' || Number(before.size) > maxBytes) fail(`${label} must be a bounded regular file`);
  const contents = fs.readFileSync(target);
  const after = snapshotEntry(target);
  if (!sameSnapshot(before, after)) fail(`${label} changed while it was read`);
  return contents.toString('utf8');
}

function resolveCanonicalGit() {
  for (const candidate of ['/usr/bin/git', '/opt/homebrew/bin/git', '/usr/local/bin/git']) {
    try {
      const resolved = fs.realpathSync.native(candidate);
      const stat = fs.lstatSync(resolved);
      fs.accessSync(resolved, fs.constants.X_OK);
      assertNoSymlinkComponents(resolved, 'Git executable');
      if (stat.isFile() && !stat.isSymbolicLink()) return resolved;
    } catch {
      // Try the next fixed canonical location.
    }
  }
  fail('canonical Git executable is unavailable');
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

function runGit(gitBin, cwd, args, { buffer = false } = {}) {
  const result = spawnSync(gitBin, ['--literal-pathspecs', ...args], {
    cwd,
    encoding: buffer ? 'buffer' : 'utf8',
    env: cleanGitEnvironment(),
    maxBuffer: MAX_GIT_OUTPUT,
    timeout: TOOL_TIMEOUT_MS,
    killSignal: 'SIGKILL',
  });
  if (result.status !== 0) {
    const stderr = Buffer.isBuffer(result.stderr) ? result.stderr.toString('utf8') : result.stderr;
    fail(`git ${args[0]} failed in ${cwd}: ${(stderr ?? '').trim() || result.error?.code || `status ${result.status}`}`);
  }
  return result.stdout;
}

function decodeNulPaths(value, label) {
  const decoder = new TextDecoder('utf-8', { fatal: true });
  const records = [];
  let start = 0;
  for (let index = 0; index < value.length; index += 1) {
    if (value[index] !== 0) continue;
    if (index > start) {
      try {
        records.push(decoder.decode(value.subarray(start, index)));
      } catch {
        fail(`${label} contains a non-UTF-8 path; refusing to mutate it`);
      }
    }
    start = index + 1;
  }
  if (start !== value.length) fail(`${label} returned a non-NUL-terminated path list`);
  return records;
}

function normalizeCandidate(value) {
  const candidate = value.endsWith('/') ? value.slice(0, -1) : value;
  if (
    !candidate ||
    candidate.startsWith('/') ||
    candidate.startsWith('./') ||
    candidate.includes('\\') ||
    /[\u0000-\u001f\u007f]/u.test(candidate) ||
    candidate.split('/').some((segment) => !segment || segment === '.' || segment === '..') ||
    candidate === '.git' ||
    candidate.startsWith('.git/') ||
    path.posix.normalize(candidate) !== candidate
  ) {
    fail(`Git returned an unsafe ignored path: ${JSON.stringify(value)}`);
  }
  return candidate;
}

export function collapseCandidatePaths(values) {
  const unique = [...new Set(values.map(normalizeCandidate))].sort((left, right) => {
    const segmentDifference = left.split('/').length - right.split('/').length;
    return segmentDifference || left.localeCompare(right, 'en');
  });
  const roots = [];
  const covered = new Map();
  for (const candidate of unique) {
    const ancestor = roots.find((root) => candidate.startsWith(`${root}/`));
    if (ancestor) {
      covered.get(ancestor).push(candidate);
      continue;
    }
    roots.push(candidate);
    covered.set(candidate, []);
  }
  return roots.map((relativePath) => ({ relativePath, coveredPaths: covered.get(relativePath) }));
}

function parseConfig(configFile) {
  assertNoSymlinkComponents(configFile, 'source publication config');
  const before = snapshotEntry(configFile);
  if (before.type !== 'file') fail('source publication config must be a regular non-symlink file');
  const contents = fs.readFileSync(configFile);
  const after = snapshotEntry(configFile);
  if (!sameSnapshot(before, after)) fail('source publication config changed while it was read');
  const lines = contents.toString('utf8').split(/\r?\n/u).filter(Boolean);
  if (lines[0] !== '# path\trepository\thead\tbase\tpull_request') fail('source publication config header mismatch');
  const paths = lines.slice(1).map((line, index) => {
    const fields = line.split('\t');
    if (fields.length !== 5) fail(`source publication config row ${index + 1} must contain five tab-separated fields`);
    return fields[0];
  });
  if (paths.length !== EXPECTED_CONFIG_PATHS.length || paths.some((value, index) => value !== EXPECTED_CONFIG_PATHS[index])) {
    fail(`source publication config paths must be exactly: ${EXPECTED_CONFIG_PATHS.join(', ')}`);
  }
  return crypto.createHash('sha256').update(contents).digest('hex');
}

function snapshotEntry(target) {
  const stat = fs.lstatSync(target, { bigint: true });
  const type = stat.isDirectory() ? 'directory' : stat.isFile() ? 'file' : stat.isSymbolicLink() ? 'symlink' : 'other';
  return {
    type,
    dev: stat.dev.toString(),
    ino: stat.ino.toString(),
    mode: Number(stat.mode & 0o7777n),
    size: stat.size.toString(),
    mtimeNs: stat.mtimeNs.toString(),
  };
}

function sameIdentity(left, right) {
  return left.type === right.type && left.dev === right.dev && left.ino === right.ino;
}

function sameSnapshot(left, right) {
  return (
    sameIdentity(left, right) &&
    left.mode === right.mode &&
    left.size === right.size &&
    left.mtimeNs === right.mtimeNs
  );
}

function validateRepository(gitBin, workspaceRoot, configuredPath) {
  const repositoryPath = path.resolve(workspaceRoot, configuredPath);
  if (configuredPath === FORBIDDEN_REPOSITORY || repositoryPath === path.resolve(workspaceRoot, FORBIDDEN_REPOSITORY)) {
    fail(`forbidden repository selected: ${FORBIDDEN_REPOSITORY}`);
  }
  const realPath = assertRealDirectory(repositoryPath, `maintained repository ${configuredPath}`);
  if (realPath !== repositoryPath) fail(`maintained repository path is not canonical: ${repositoryPath}`);
  const gitMetadata = path.join(repositoryPath, '.git');
  assertNoSymlinkComponents(gitMetadata, `repository .git metadata for ${configuredPath}`);
  const marker = fs.lstatSync(gitMetadata);
  let commonMetadata = gitMetadata;
  if (marker.isFile() && !marker.isSymbolicLink()) {
    const owner = WORKTREE_OWNERS[configuredPath];
    if (!owner) fail(`linked Git metadata is forbidden for ${configuredPath}`);
    const expectedCommon = path.join(workspaceRoot, owner, '.git');
    const expectedAdmin = path.join(expectedCommon, 'worktrees', configuredPath);
    if (readRegularFile(gitMetadata, `worktree Git metadata pointer for ${configuredPath}`) !== `gitdir: ${expectedAdmin}\n`) {
      fail(`worktree Git metadata pointer mismatch for ${configuredPath}`);
    }
    assertRealDirectory(expectedCommon, `worktree common Git metadata for ${configuredPath}`);
    assertRealDirectory(expectedAdmin, `worktree administrative Git metadata for ${configuredPath}`);
    if (readRegularFile(path.join(expectedAdmin, 'gitdir'), `worktree Git metadata backlink for ${configuredPath}`) !== `${gitMetadata}\n` ||
        readRegularFile(path.join(expectedAdmin, 'commondir'), `worktree common Git metadata link for ${configuredPath}`) !== '../..\n') {
      fail(`worktree Git metadata backlink mismatch for ${configuredPath}`);
    }
    commonMetadata = expectedCommon;
  } else if (marker.isDirectory() && !marker.isSymbolicLink()) {
    const realGitMetadata = assertRealDirectory(gitMetadata, `repository .git metadata for ${configuredPath}`);
    if (realGitMetadata !== gitMetadata) fail(`repository .git metadata is not canonical for ${configuredPath}`);
  } else {
    fail(`repository .git metadata is unsafe for ${configuredPath}`);
  }
  const objectDirectory = path.join(commonMetadata, 'objects');
  assertRealDirectory(objectDirectory, `repository object directory for ${configuredPath}`);
  if (commonMetadata === gitMetadata && pathIdentityOrNull(path.join(gitMetadata, 'commondir'))) {
    fail(`linked/common Git metadata is forbidden for ${configuredPath}`);
  }
  if (pathIdentityOrNull(path.join(objectDirectory, 'info', 'alternates'))) fail(`alternate Git object storage is forbidden for ${configuredPath}`);
  const localConfig = path.join(commonMetadata, 'config');
  const localConfigText = readRegularFile(localConfig, `repository config for ${configuredPath}`, 64 * 1024);
  if (/^\s*\[include(?:If\b[^\]]*)?\]/imu.test(localConfigText)) {
    fail(`repository config includes external configuration for ${configuredPath}`);
  }
  if (commonMetadata !== gitMetadata) {
    const worktreeConfig = path.join(commonMetadata, 'worktrees', configuredPath, 'config.worktree');
    if (pathIdentityOrNull(worktreeConfig)) {
      const worktreeConfigText = readRegularFile(worktreeConfig, `worktree config for ${configuredPath}`, 64 * 1024);
      if (/^\s*\[include(?:If\b[^\]]*)?\]/imu.test(worktreeConfigText)) {
        fail(`worktree config is unsafe for ${configuredPath}`);
      }
    }
  }
  const topLevel = runGit(gitBin, repositoryPath, ['rev-parse', '--show-toplevel']).trim();
  if (topLevel !== repositoryPath || fs.realpathSync.native(topLevel) !== realPath) {
    fail(`Git top-level mismatch for ${configuredPath}: ${topLevel}`);
  }
  const head = runGit(gitBin, repositoryPath, ['rev-parse', '--verify', 'HEAD^{commit}']).trim();
  if (!/^[0-9a-f]{40}$/u.test(head)) fail(`repository HEAD is invalid for ${configuredPath}`);
  return { configuredPath, repositoryPath, realPath, head };
}

function listIgnoredRoots(gitBin, repository) {
  const output = runGit(
    gitBin,
    repository.repositoryPath,
    ['ls-files', '--others', '--ignored', '--exclude-standard', '--directory', '-z'],
    { buffer: true },
  );
  return collapseCandidatePaths(decodeNulPaths(output, `${repository.configuredPath} ignored output`));
}

function queryPaths(gitBin, repositoryPath, args, label) {
  const separator = args.indexOf('--');
  const nulArgs = separator === -1
    ? [...args, '-z']
    : [...args.slice(0, separator), '-z', ...args.slice(separator)];
  return decodeNulPaths(runGit(gitBin, repositoryPath, nulArgs, { buffer: true }), label);
}

function validateCandidate(gitBin, repository, candidate, expectedIdentity = null) {
  assertNoSymlinkComponents(repository.repositoryPath, `repository ${repository.configuredPath}`);
  const source = path.join(repository.repositoryPath, ...candidate.relativePath.split('/'));
  if (!source.startsWith(`${repository.repositoryPath}${path.sep}`)) fail(`candidate escapes repository: ${candidate.relativePath}`);
  assertNoSymlinkComponents(source, `ignored candidate ${repository.configuredPath}:${candidate.relativePath}`);
  const identity = snapshotEntry(source);
  if (!['file', 'directory'].includes(identity.type)) fail(`ignored candidate must be a regular file or real directory: ${candidate.relativePath}`);
  const tracked = queryPaths(
    gitBin,
    repository.repositoryPath,
    ['ls-files', '--', candidate.relativePath],
    `${repository.configuredPath} tracked-path proof`,
  );
  if (tracked.length) fail(`ignored candidate contains tracked content: ${repository.configuredPath}:${candidate.relativePath}`);
  const nonIgnored = queryPaths(
    gitBin,
    repository.repositoryPath,
    ['ls-files', '--others', '--exclude-standard', '--', candidate.relativePath],
    `${repository.configuredPath} non-ignored-path proof`,
  );
  if (nonIgnored.length) fail(`ignored candidate contains non-ignored untracked content: ${repository.configuredPath}:${candidate.relativePath}`);
  const currentIgnored = listIgnoredRoots(gitBin, repository).map((entry) => entry.relativePath);
  if (!currentIgnored.includes(candidate.relativePath)) {
    fail(`candidate is no longer an ignored-only root: ${repository.configuredPath}:${candidate.relativePath}`);
  }
  if (expectedIdentity && !sameSnapshot(identity, expectedIdentity)) {
    fail(`ignored candidate identity changed before rename: ${repository.configuredPath}:${candidate.relativePath}`);
  }
  return { source, identity };
}

function buildPlan(gitBin, root) {
  const repositories = MAINTAINED_REPOSITORIES.map((configuredPath) => validateRepository(gitBin, root, configuredPath));
  const entries = [];
  for (const repository of repositories) {
    for (const candidate of listIgnoredRoots(gitBin, repository)) {
      const validated = validateCandidate(gitBin, repository, candidate);
      entries.push({
        repository: repository.configuredPath,
        repositoryPath: repository.repositoryPath,
        head: repository.head,
        relativePath: candidate.relativePath,
        coveredPaths: candidate.coveredPaths,
        identity: validated.identity,
        status: 'planned',
      });
    }
  }
  return { repositories, entries };
}

function mkdirPrivate(target) {
  assertNoSymlinkComponents(path.dirname(target), 'quarantine parent');
  fs.mkdirSync(target, { mode: 0o700 });
  const stat = fs.lstatSync(target);
  if (!stat.isDirectory() || stat.isSymbolicLink()) fail(`quarantine directory is unsafe: ${target}`);
  fs.chmodSync(target, 0o700);
}

function ensurePrivateMirror(root, segments) {
  let current = root;
  for (const segment of segments) {
    current = path.join(current, segment);
    if (!fs.existsSync(current)) {
      fs.mkdirSync(current, { mode: 0o700 });
    } else {
      const stat = fs.lstatSync(current);
      if (!stat.isDirectory() || stat.isSymbolicLink()) fail(`quarantine mirror path is unsafe: ${current}`);
    }
    fs.chmodSync(current, 0o700);
  }
  return current;
}

function fsyncDirectory(directory) {
  let fd;
  try {
    fd = fs.openSync(directory, fs.constants.O_RDONLY);
    fs.fsyncSync(fd);
  } finally {
    if (fd !== undefined) fs.closeSync(fd);
  }
}

function writeManifest(manifestPath, manifest) {
  const parent = path.dirname(manifestPath);
  assertNoSymlinkComponents(parent, 'manifest parent');
  const temporary = path.join(parent, `.manifest-${process.pid}-${crypto.randomBytes(6).toString('hex')}.tmp`);
  let fd;
  try {
    fd = fs.openSync(temporary, fs.constants.O_CREAT | fs.constants.O_EXCL | fs.constants.O_WRONLY, 0o600);
    fs.writeFileSync(fd, `${JSON.stringify(manifest, null, 2)}\n`);
    fs.fsyncSync(fd);
  } finally {
    if (fd !== undefined) fs.closeSync(fd);
  }
  fs.renameSync(temporary, manifestPath);
  fs.chmodSync(manifestPath, 0o600);
  fsyncDirectory(parent);
}

function destinationFor(quarantineRoot, entry) {
  const repositoryDirectory = entry.repository.startsWith('../') ? entry.repository.slice(3) : entry.repository;
  return path.join(quarantineRoot, repositoryDirectory, ...entry.relativePath.split('/'));
}

function sourceFor(entry) {
  return path.join(entry.repositoryPath, ...entry.relativePath.split('/'));
}

function pathIdentityOrNull(target) {
  try {
    return snapshotEntry(target);
  } catch (error) {
    if (error?.code === 'ENOENT') return null;
    throw error;
  }
}

function rollbackEntries(manifest, manifestPath) {
  let complete = true;
  for (const entry of [...manifest.entries].reverse()) {
    if (!['moved', 'moving'].includes(entry.status)) continue;
    const source = sourceFor(entry);
    const destination = destinationFor(manifest.quarantineRoot, entry);
    const sourceIdentity = pathIdentityOrNull(source);
    const destinationIdentity = pathIdentityOrNull(destination);
    if (sourceIdentity && sameSnapshot(sourceIdentity, entry.identity) && !destinationIdentity) {
      entry.status = 'rolled-back';
      writeManifest(manifestPath, manifest);
      continue;
    }
    if (sourceIdentity || !destinationIdentity || !sameSnapshot(destinationIdentity, entry.identity)) {
      entry.status = 'rollback-failed';
      entry.rollbackError = sourceIdentity
        ? 'source path is occupied; refusing to overwrite it'
        : 'quarantined entry is missing or changed; refusing to move it';
      complete = false;
      writeManifest(manifestPath, manifest);
      continue;
    }
    assertNoSymlinkComponents(path.dirname(source), 'rollback source parent');
    fs.renameSync(destination, source);
    if (!sameSnapshot(snapshotEntry(source), entry.identity)) fail(`rollback identity verification failed: ${entry.repository}:${entry.relativePath}`);
    entry.status = 'rolled-back';
    writeManifest(manifestPath, manifest);
  }
  manifest.status = complete ? 'rolled-back' : 'partial';
  manifest.completedAt = new Date().toISOString();
  writeManifest(manifestPath, manifest);
  return complete;
}

function applyPlan(gitBin, root, configFile, configSha256, plan, testMode) {
  if (plan.entries.length === 0) {
    return {
      schemaVersion: 1,
      generatedAt: new Date().toISOString(),
      mode: 'apply',
      status: 'no-op',
      workspaceRoot: root,
      configFile,
      configSha256,
      forbiddenRepository: FORBIDDEN_REPOSITORY,
      maintainedRepositories: [...MAINTAINED_REPOSITORIES],
      quarantineRoot: null,
      entries: [],
    };
  }
  const quarantineParent = path.join(root, 'build', 'quarantine');
  assertNoSymlinkComponents(quarantineParent, 'quarantine parent', true);
  fs.mkdirSync(quarantineParent, { recursive: true, mode: 0o700 });
  assertRealDirectory(quarantineParent, 'quarantine parent');
  fs.chmodSync(quarantineParent, 0o700);
  const suffix = `${new Date().toISOString().replace(/[-:.]/gu, '')}-${crypto.randomBytes(6).toString('hex')}`;
  const quarantineRoot = path.join(quarantineParent, `source-publication-${suffix}`);
  mkdirPrivate(quarantineRoot);
  const manifestPath = path.join(quarantineRoot, 'manifest.json');
  const manifest = {
    schemaVersion: 1,
    generatedAt: new Date().toISOString(),
    mode: 'apply',
    status: 'applying',
    workspaceRoot: root,
    configFile,
    configSha256,
    forbiddenRepository: FORBIDDEN_REPOSITORY,
    maintainedRepositories: [...MAINTAINED_REPOSITORIES],
    quarantineRoot,
    entries: plan.entries,
  };
  writeManifest(manifestPath, manifest);
  try {
    let movedCount = 0;
    let raceInjected = false;
    let nonIgnoredInjected = false;
    let trackedInjected = false;
    for (const entry of manifest.entries) {
      const repository = validateRepository(gitBin, root, entry.repository);
      if (repository.head !== entry.head) fail(`repository HEAD changed before rename: ${entry.repository}`);
      const candidate = { relativePath: entry.relativePath, coveredPaths: entry.coveredPaths };
      if (testMode && !nonIgnoredInjected && process.env.SOURCE_PUBLICATION_QUARANTINE_TEST_ADD_NONIGNORED) {
        const candidateRoot = path.join(repository.repositoryPath, ...entry.relativePath.split('/'));
        if (!fs.lstatSync(candidateRoot).isDirectory()) fail('non-ignored test injection requires a directory candidate');
        fs.writeFileSync(path.join(repository.repositoryPath, '.gitignore'), 'ignored/*\n!ignored/keep.txt\n*.tmp\n');
        fs.writeFileSync(path.join(candidateRoot, 'keep.txt'), 'must remain published\n');
        nonIgnoredInjected = true;
      }
      if (testMode && !trackedInjected && process.env.SOURCE_PUBLICATION_QUARANTINE_TEST_ADD_TRACKED) {
        const candidateRoot = path.join(repository.repositoryPath, ...entry.relativePath.split('/'));
        if (!fs.lstatSync(candidateRoot).isDirectory()) fail('tracked test injection requires a directory candidate');
        const trackedPath = path.join(candidateRoot, 'tracked-after-plan.txt');
        fs.writeFileSync(trackedPath, 'tracked source must not be quarantined\n');
        runGit(gitBin, repository.repositoryPath, ['add', '-f', '--', path.relative(repository.repositoryPath, trackedPath)]);
        trackedInjected = true;
      }
      const validated = validateCandidate(gitBin, repository, candidate, entry.identity);
      const destination = destinationFor(quarantineRoot, entry);
      ensurePrivateMirror(quarantineRoot, path.relative(quarantineRoot, path.dirname(destination)).split(path.sep).filter(Boolean));
      if (fs.existsSync(destination)) fail(`quarantine destination already exists: ${destination}`);
      const destinationParentDevice = snapshotEntry(path.dirname(destination)).dev;
      if (destinationParentDevice !== entry.identity.dev) {
        fail(`cross-filesystem quarantine is forbidden: ${entry.repository}:${entry.relativePath}`);
      }
      entry.status = 'moving';
      writeManifest(manifestPath, manifest);
      if (testMode && !raceInjected && process.env.SOURCE_PUBLICATION_QUARANTINE_TEST_SWAP_BEFORE_RENAME) {
        const outsideTarget = path.resolve(process.env.SOURCE_PUBLICATION_QUARANTINE_TEST_SWAP_BEFORE_RENAME);
        const displaced = `${validated.source}.race-original`;
        if (fs.existsSync(displaced)) fail(`test race displacement already exists: ${displaced}`);
        fs.renameSync(validated.source, displaced);
        fs.symlinkSync(outsideTarget, validated.source);
        raceInjected = true;
      }
      assertNoSymlinkComponents(validated.source, `ignored candidate ${entry.repository}:${entry.relativePath}`);
      if (!sameSnapshot(snapshotEntry(validated.source), entry.identity)) {
        fail(`ignored candidate changed at rename checkpoint: ${entry.repository}:${entry.relativePath}`);
      }
      fs.renameSync(validated.source, destination);
      if (!sameSnapshot(snapshotEntry(destination), entry.identity)) {
        fail(`quarantined identity verification failed: ${entry.repository}:${entry.relativePath}`);
      }
      entry.status = 'moved';
      writeManifest(manifestPath, manifest);
      movedCount += 1;
      if (
        testMode &&
        process.env.SOURCE_PUBLICATION_QUARANTINE_TEST_FAIL_AFTER_MOVES &&
        movedCount === Number(process.env.SOURCE_PUBLICATION_QUARANTINE_TEST_FAIL_AFTER_MOVES)
      ) {
        fail(`injected test failure after ${movedCount} move(s)`);
      }
    }
    for (const repository of plan.repositories) {
      const remaining = listIgnoredRoots(gitBin, validateRepository(gitBin, root, repository.configuredPath));
      if (remaining.length) fail(`ignored outputs were recreated during quarantine: ${repository.configuredPath}`);
    }
    manifest.status = 'applied';
    manifest.completedAt = new Date().toISOString();
    writeManifest(manifestPath, manifest);
    return manifest;
  } catch (error) {
    manifest.error = error.message;
    manifest.status = 'rollback-in-progress';
    writeManifest(manifestPath, manifest);
    const rolledBack = rollbackEntries(manifest, manifestPath);
    if (!rolledBack) throw new Error(`${error.message}; automatic rollback was incomplete; inspect ${manifestPath}`);
    throw new Error(`${error.message}; completed moves were rolled back; inspect ${manifestPath}`);
  }
}

function loadRollbackManifest(root, manifestArgument) {
  const quarantineParent = path.join(root, 'build', 'quarantine');
  assertRealDirectory(quarantineParent, 'quarantine parent');
  const manifestPath = path.resolve(manifestArgument);
  if (!manifestPath.startsWith(`${quarantineParent}${path.sep}`) || path.basename(manifestPath) !== 'manifest.json') {
    fail(`rollback manifest must be a manifest.json below ${quarantineParent}`);
  }
  assertNoSymlinkComponents(manifestPath, 'rollback manifest');
  const stat = fs.lstatSync(manifestPath);
  if (!stat.isFile() || stat.isSymbolicLink()) fail('rollback manifest must be a regular non-symlink file');
  const manifest = JSON.parse(fs.readFileSync(manifestPath, 'utf8'));
  if (
    manifest?.schemaVersion !== 1 ||
    manifest.workspaceRoot !== root ||
    manifest.quarantineRoot !== path.dirname(manifestPath) ||
    manifest.forbiddenRepository !== FORBIDDEN_REPOSITORY ||
    JSON.stringify(manifest.maintainedRepositories) !== JSON.stringify(MAINTAINED_REPOSITORIES) ||
    !Array.isArray(manifest.entries)
  ) {
    fail('rollback manifest identity is invalid');
  }
  for (const entry of manifest.entries) {
    if (!MAINTAINED_REPOSITORIES.includes(entry.repository)) fail('rollback manifest contains a forbidden repository');
    normalizeCandidate(entry.relativePath);
    const expectedRepositoryPath = path.resolve(root, entry.repository);
    if (entry.repositoryPath !== expectedRepositoryPath) fail('rollback manifest repository path mismatch');
    if (!entry.identity || !['file', 'directory'].includes(entry.identity.type)) fail('rollback manifest entry identity is invalid');
    const expectedDestination = destinationFor(manifest.quarantineRoot, entry);
    if (!expectedDestination.startsWith(`${manifest.quarantineRoot}${path.sep}`)) fail('rollback manifest destination escapes quarantine');
  }
  return { manifest, manifestPath };
}

function dryRunReport(root, configFile, configSha256, plan) {
  return {
    schemaVersion: 1,
    generatedAt: new Date().toISOString(),
    mode: 'dry-run',
    status: plan.entries.length ? 'planned' : 'no-op',
    workspaceRoot: root,
    configFile,
    configSha256,
    forbiddenRepository: FORBIDDEN_REPOSITORY,
    maintainedRepositories: [...MAINTAINED_REPOSITORIES],
    quarantineRoot: null,
    entries: plan.entries,
  };
}

export function main(argv = process.argv.slice(2)) {
  process.umask(0o077);
  const options = parseArgs(argv);
  if (options.testMode !== (process.env.SOURCE_PUBLICATION_QUARANTINE_TEST_MODE === '1')) {
    fail('--test-mode and SOURCE_PUBLICATION_QUARANTINE_TEST_MODE=1 must be used together');
  }
  if (!options.testMode && (options.root || options.config || process.env.SOURCE_PUBLICATION_QUARANTINE_TEST_MODE)) {
    fail('root/config overrides and test environment are forbidden in production mode');
  }
  if (!options.testMode) {
    const injected = Object.keys(process.env).find((key) => key.startsWith('SOURCE_PUBLICATION_QUARANTINE_'));
    if (injected) fail(`${injected} is forbidden in production mode`);
  }
  const root = path.resolve(options.root ?? DEFAULT_ROOT);
  const canonicalRoot = assertRealDirectory(root, 'workspace root');
  if (canonicalRoot !== root) fail('workspace root must be canonical');
  const configFile = path.resolve(options.config ?? path.join(root, 'config/source-publication-readiness.tsv'));
  if (!options.testMode && configFile !== path.join(root, 'config/source-publication-readiness.tsv')) {
    fail('production source publication config path is fixed');
  }
  const configSha256 = parseConfig(configFile);
  const gitBin = resolveCanonicalGit();
  let report;
  if (options.mode === 'rollback') {
    const { manifest, manifestPath } = loadRollbackManifest(root, options.rollbackManifest);
    if (manifest.configFile !== configFile || manifest.configSha256 !== configSha256) {
      fail('rollback manifest config identity does not match the current canonical config');
    }
    const complete = rollbackEntries(manifest, manifestPath);
    report = manifest;
    if (!complete) fail(`rollback was incomplete; inspect ${manifestPath}`);
  } else {
    const plan = buildPlan(gitBin, root);
    report = options.mode === 'apply'
      ? applyPlan(gitBin, root, configFile, configSha256, plan, options.testMode)
      : dryRunReport(root, configFile, configSha256, plan);
  }
  process.stdout.write(`${JSON.stringify(report, null, 2)}\n`);
  return report;
}

const invokedAsMain = process.argv[1] && pathToFileURL(path.resolve(process.argv[1])).href === import.meta.url;
if (invokedAsMain) {
  try {
    main();
  } catch (error) {
    process.stderr.write(`[source-publication-quarantine][error] ${error.message}\n`);
    process.exitCode = 1;
  }
}
