#!/usr/bin/env node

import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const MANIFEST = path.join(ROOT, 'config/workspace-repositories.json');
const GROUPS = new Set(['core', 'services', 'private']);
const COMPONENT = /^[A-Za-z0-9][A-Za-z0-9._-]*$/u;
const COMMIT = /^[a-f0-9]{40}$/u;

function git(cwd, ...args) {
  const env = Object.fromEntries(Object.entries(process.env).filter(([key]) => !key.startsWith('GIT_')));
  const result = spawnSync('git', ['-c', 'core.hooksPath=' + os.devNull, ...args], {
    cwd, encoding: 'utf8', env: { ...env, GIT_TERMINAL_PROMPT: '0', GIT_NO_REPLACE_OBJECTS: '1' },
    maxBuffer: 8 * 1024 * 1024,
  });
  if (result.status !== 0) throw new Error(`git ${args[0]} failed: ${result.stderr?.trim() || result.error?.message}`);
  return result.stdout.trim();
}

export function validateManifest(manifest) {
  assert.equal(manifest.schemaVersion, 1, 'Unsupported workspace manifest');
  assert.ok(Array.isArray(manifest.repositories) && manifest.repositories.length > 0, 'Repository list is empty');
  const seen = new Set();
  for (const row of manifest.repositories) {
    assert.ok(GROUPS.has(row.group), 'Unknown repository group');
    const name = row.group === 'services' ? row.path?.replace(/^\.\.\//u, '') : row.path;
    assert.ok(typeof name === 'string' && COMPONENT.test(name) && !['.', '..'].includes(name), 'Unsafe repository path');
    assert.equal(row.path, row.group === 'services' ? '../' + name : name, 'Invalid repository location');
    assert.ok(!seen.has(name.toLowerCase()), 'Duplicate repository directory');
    seen.add(name.toLowerCase());
    assert.ok(typeof row.repository === 'string' && row.repository.split('/').length === 2 &&
      row.repository.split('/').every((value) => COMPONENT.test(value) && !['.', '..'].includes(value)), 'Invalid GitHub repository');
    assert.ok(COMMIT.test(row.commit), 'Expected a full commit ID');
    assert.ok(typeof row.branch === 'string' && row.branch.length > 0 &&
      !row.branch.startsWith('-') && !row.branch.startsWith('refs/'), 'Invalid branch');
    git(ROOT, 'check-ref-format', 'refs/heads/' + row.branch);
  }
  return manifest;
}

function exists(target) {
  try { return fs.lstatSync(target); } catch (error) { if (error.code === 'ENOENT') return null; throw error; }
}

function canonicalOrigin(value) {
  return value.replace(/^git@github\.com:/u, 'https://github.com/').replace(/\.git\/?$/u, '').replace(/\/$/u, '');
}

function verifyCheckout(directory, row, url) {
  const entry = exists(directory);
  assert.ok(entry?.isDirectory() && !entry.isSymbolicLink(), `${row.path}: expected a real directory`);
  const dotgit = exists(path.join(directory, '.git'));
  assert.ok(dotgit?.isDirectory() && !dotgit.isSymbolicLink(), `${row.path}: expected an independent Git clone`);
  assert.equal(fs.realpathSync(git(directory, 'rev-parse', '--show-toplevel')), fs.realpathSync(directory), `${row.path}: wrong Git root`);
  assert.ok(canonicalOrigin(git(directory, 'remote', 'get-url', 'origin')) === canonicalOrigin(url), `${row.path}: origin differs from manifest`);
  assert.equal(git(directory, 'status', '--porcelain=v1', '--untracked-files=all'), '', `${row.path}: local changes must be committed or preserved first`);
  assert.equal(git(directory, 'rev-parse', 'HEAD'), row.commit, `${row.path}: commit differs from manifest; existing checkout was not changed`);
  assert.equal(git(directory, 'symbolic-ref', '--short', 'HEAD'), row.branch, `${row.path}: branch differs from manifest; existing checkout was not changed`);
  const alternates = path.join(directory, '.git/objects/info/alternates');
  assert.ok(!exists(alternates), `${row.path}: clone depends on an external Git object store`);
}

// The optional URL argument lets tests use local bare Git repositories without network access.
export function setupRepository(root, row, { checkOnly = false, url = `https://github.com/${row.repository}.git` } = {}) {
  validateManifest({ schemaVersion: 1, repositories: [row] });
  root = fs.realpathSync(root);
  const directory = path.resolve(root, row.path);
  if (exists(directory)) {
    verifyCheckout(directory, row, url);
    return 'verified';
  }
  assert.ok(!checkOnly, `${row.path}: checkout is missing; run setup without --check`);
  const temporary = fs.mkdtempSync(path.join(path.dirname(directory), '.' + path.basename(directory) + '-setup-'));
  try {
    git(temporary, 'init', '--quiet');
    git(temporary, 'remote', 'add', 'origin', url);
    const upstream = 'refs/remotes/origin/' + row.branch;
    git(temporary, 'fetch', '--no-tags', '--filter=blob:none', 'origin', 'refs/heads/' + row.branch + ':' + upstream);
    git(temporary, 'cat-file', '-e', row.commit + '^{commit}');
    git(temporary, 'merge-base', '--is-ancestor', row.commit, upstream);
    git(temporary, 'switch', '--quiet', '-c', row.branch, row.commit);
    git(temporary, 'branch', '--set-upstream-to=origin/' + row.branch, row.branch);
    verifyCheckout(temporary, row, url);
    assert.ok(!exists(directory), `${row.path}: destination appeared during clone`);
    fs.renameSync(temporary, directory);
    return 'cloned';
  } finally {
    if (exists(temporary)) fs.rmSync(temporary, { recursive: true });
  }
}

export function environment(root) {
  const quote = (value) => "'" + value.replaceAll("'", "'\\''") + "'";
  return [
    ['FEARLESS_UTILS_PATH', 'fearless-utils-Android'],
    ['FEARLESS_NV_WEBSOCKET_PATH', 'fearless-nv-websocket-client'],
  ].map(([key, relative]) => `export ${key}=${quote(path.resolve(root, relative))}`).join('\n') + '\n';
}

function main(args) {
  const options = { root: ROOT, checkOnly: false, groups: new Set(['core']), env: false };
  for (let index = 0; index < args.length; index += 1) {
    const arg = args[index];
    if (arg === '--check') options.checkOnly = true;
    else if (arg === '--include-services') options.groups.add('services');
    else if (arg === '--include-private') options.groups.add('private');
    else if (arg === '--env') options.env = true;
    else if (arg === '--root') {
      assert.ok(args[index + 1] && !args[index + 1].startsWith('--'), '--root requires a directory');
      options.root = path.resolve(args[++index]);
    } else if (arg === '--help') {
      console.log('Usage: node scripts/setup-workspace.mjs [--check] [--include-services] [--include-private] [--root DIR] [--env]\nClones missing repositories at manifest revisions. Existing checkouts are verified, never overwritten.\n--check is offline and read-only. --env prints shell exports for the canonical Android dependency paths.');
      return;
    } else throw new Error(`Unknown option: ${arg}`);
  }
  const manifest = validateManifest(JSON.parse(fs.readFileSync(MANIFEST, 'utf8')));
  if (options.env) { process.stdout.write(environment(options.root)); return; }
  const rows = manifest.repositories.filter((row) => options.groups.has(row.group));
  const failures = [];
  for (const row of rows) {
    try {
      const action = setupRepository(options.root, row, options);
      console.log(`[workspace] ${action}: ${row.path} (${row.commit.slice(0, 12)})`);
    } catch (error) { failures.push(`${row.path}: ${error.message}`); }
  }
  if (failures.length) throw new Error(failures.join('\n'));
  console.log(`[workspace] ${rows.length} pinned repositories ready`);
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try { main(process.argv.slice(2)); } catch (error) { console.error(`[workspace] ${error.message}`); process.exitCode = 1; }
}
