import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { test } from 'node:test';
import { environment, setupRepository, validateManifest } from './setup-workspace.mjs';

function fixture(t) {
  const base = fs.mkdtempSync(path.join(os.tmpdir(), 'fearless-workspace-test-'));
  t.after(() => fs.rmSync(base, { recursive: true, force: true }));
  const upstream = path.join(base, 'upstream');
  const root = path.join(base, 'workspace');
  fs.mkdirSync(upstream); fs.mkdirSync(root);
  const git = (cwd, ...args) => execFileSync('git', args, { cwd, encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] }).trim();
  git(upstream, 'init', '--initial-branch=reviewed');
  git(upstream, 'config', 'user.name', 'Workspace fixture');
  git(upstream, 'config', 'user.email', 'fixture@example.invalid');
  fs.writeFileSync(path.join(upstream, 'source.txt'), 'pinned source\n');
  git(upstream, 'add', 'source.txt'); git(upstream, 'commit', '-m', 'pin');
  const commit = git(upstream, 'rev-parse', 'HEAD');
  fs.writeFileSync(path.join(upstream, 'source.txt'), 'newer source\n');
  git(upstream, 'commit', '-am', 'advance upstream');
  const tip = git(upstream, 'rev-parse', 'HEAD');
  const url = path.join(base, 'remote.git');
  git(base, 'clone', '--bare', upstream, url);
  return { base, root, url, git, tip, row: { path: 'application', repository: 'example/application', branch: 'reviewed', commit, group: 'core' } };
}

test('fresh setup pins source even after upstream advances; repeat and offline check are idempotent', (t) => {
  const f = fixture(t);
  assert.equal(setupRepository(f.root, f.row, { url: f.url }), 'cloned');
  const repo = path.join(f.root, f.row.path);
  assert.equal(fs.readFileSync(path.join(repo, 'source.txt'), 'utf8'), 'pinned source\n');
  assert.equal(f.git(repo, 'rev-parse', 'HEAD'), f.row.commit);
  assert.equal(f.git(repo, 'rev-parse', '@{upstream}'), f.tip);
  assert.equal(setupRepository(f.root, f.row, { url: f.url }), 'verified');
  fs.renameSync(f.url, f.url + '.offline');
  assert.equal(setupRepository(f.root, f.row, { checkOnly: true, url: f.url }), 'verified');
});

test('missing checkout check makes no directories', (t) => {
  const f = fixture(t);
  assert.throws(() => setupRepository(f.root, f.row, { checkOnly: true, url: f.url }), /checkout is missing/);
  assert.deepEqual(fs.readdirSync(f.root), []);
});

test('tracked and untracked local work is never overwritten', (t) => {
  const f = fixture(t); setupRepository(f.root, f.row, { url: f.url });
  const repo = path.join(f.root, f.row.path);
  fs.writeFileSync(path.join(repo, 'source.txt'), 'my changes\n');
  fs.writeFileSync(path.join(repo, 'new.txt'), 'new work\n');
  assert.throws(() => setupRepository(f.root, f.row, { url: f.url }), /local changes/);
  assert.equal(fs.readFileSync(path.join(repo, 'source.txt'), 'utf8'), 'my changes\n');
  assert.equal(fs.readFileSync(path.join(repo, 'new.txt'), 'utf8'), 'new work\n');
  assert.equal(f.git(repo, 'rev-parse', 'HEAD'), f.row.commit);
});

test('a clean checkout at another revision or branch is left alone', (t) => {
  const f = fixture(t); setupRepository(f.root, f.row, { url: f.url });
  const repo = path.join(f.root, f.row.path);
  f.git(repo, 'switch', '-c', 'work-in-progress', f.tip);
  assert.throws(() => setupRepository(f.root, f.row, { url: f.url }), /commit differs/);
  assert.equal(f.git(repo, 'rev-parse', 'HEAD'), f.tip);
  f.git(repo, 'switch', '-c', 'other-branch', f.row.commit);
  assert.throws(() => setupRepository(f.root, f.row, { url: f.url }), /branch differs/);
  assert.equal(f.git(repo, 'branch', '--show-current'), 'other-branch');
});

test('wrong origin, non-repository folders and symlinks are not adopted', (t) => {
  const f = fixture(t); setupRepository(f.root, f.row, { url: f.url });
  const repo = path.join(f.root, f.row.path);
  f.git(repo, 'remote', 'set-url', 'origin', 'https://github.com/other/project.git');
  assert.throws(() => setupRepository(f.root, f.row, { url: f.url }), /origin differs/);
  fs.renameSync(repo, repo + '-retained');
  fs.mkdirSync(repo); fs.writeFileSync(path.join(repo, 'keep'), 'not a checkout');
  assert.throws(() => setupRepository(f.root, f.row, { url: f.url }), /independent Git clone/);
  assert.equal(fs.readFileSync(path.join(repo, 'keep'), 'utf8'), 'not a checkout');
  fs.renameSync(repo, repo + '-ordinary');
  fs.symlinkSync(repo + '-retained', repo, 'dir');
  assert.throws(() => setupRepository(f.root, f.row, { url: f.url }), /real directory/);
});

test('external object stores are rejected to keep clones independent', (t) => {
  const f = fixture(t); setupRepository(f.root, f.row, { url: f.url });
  const repo = path.join(f.root, f.row.path);
  fs.writeFileSync(path.join(repo, '.git/objects/info/alternates'), path.join(f.url, 'objects') + '\n');
  assert.throws(() => setupRepository(f.root, f.row, { url: f.url }), /external Git object store/);
});

test('unavailable revisions and failed fetches clean up temporary clones', (t) => {
  const f = fixture(t);
  assert.throws(() => setupRepository(f.root, { ...f.row, commit: 'a'.repeat(40) }, { url: f.url }), /git cat-file failed/);
  assert.deepEqual(fs.readdirSync(f.root), []);
  assert.throws(() => setupRepository(f.root, f.row, { url: path.join(f.base, 'missing.git') }), /git fetch failed/);
  assert.deepEqual(fs.readdirSync(f.root), []);
});

test('service clones use a sibling directory only when explicitly selected', (t) => {
  const f = fixture(t);
  const row = { ...f.row, path: '../service', group: 'services' };
  setupRepository(f.root, row, { url: f.url });
  assert.ok(fs.existsSync(path.join(f.base, 'service/.git')));
  assert.deepEqual(fs.readdirSync(f.root), []);
});

test('manifest rejects traversal, duplicate directories and invalid refs', () => {
  const row = { path: 'app', repository: 'example/app', branch: 'develop', commit: 'a'.repeat(40), group: 'core' };
  const validate = (rows) => validateManifest({ schemaVersion: 1, repositories: rows });
  for (const invalid of ['../../outside', '/absolute', '../app', '.git', '.', '..']) {
    assert.throws(() => validate([{ ...row, path: invalid }]));
  }
  assert.throws(() => validate([row, { ...row, path: 'APP' }]), /Duplicate/);
  assert.throws(() => validate([{ ...row, branch: 'bad..ref' }]));
  assert.throws(() => validate([{ ...row, commit: 'develop' }]), /full commit/);
  assert.throws(() => validate([{ ...row, group: 'unknown' }]), /Unknown/);
});

test('environment exports preserve spaces and quotes in workspace paths', () => {
  const root = "/tmp/fearless user's workspace";
  const actual = execFileSync('bash', ['-c', environment(root) + '\nprintf "%s\\n%s" "$FEARLESS_UTILS_PATH" "$FEARLESS_NV_WEBSOCKET_PATH"'], { encoding: 'utf8' });
  assert.equal(actual, root + '/fearless-utils-Android\n' + root + '/fearless-nv-websocket-client');
});
