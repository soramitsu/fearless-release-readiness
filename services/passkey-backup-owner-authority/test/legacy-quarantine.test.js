import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { createHash } from 'node:crypto';
import {
  chmodSync, mkdirSync, readFileSync, readdirSync, statSync, symlinkSync, writeFileSync,
} from 'node:fs';
import { join } from 'node:path';
import test from 'node:test';
import { quarantineLegacyCredentialSnapshot } from '../src/legacy-quarantine.js';
import { readOwnerCredentialSnapshot } from '../src/store.js';
import { hash } from '../src/validation.js';
import { b64, setup } from './fixtures.js';

const storageKey = 'storage:historical-wallet';
const emptyStorageKey = 'storage:historical-tombstone';
const sha256 = (bytes) => createHash('sha256').update(bytes).digest('hex');

function legacyDocument() {
  const id = b64(77);
  const ownerSubjectHash = hash('historical-authorization-subject');
  return {
    schemaVersion: 4,
    credentialOwnersById: [{ credentialId: id, storageKey, ownerSubjectHash }],
    credentialsByStorageKey: [
      { storageKey, ownerSubjectHash, credentials: [{
        id, publicKey: b64(8), userId: hash(`user\0${storageKey}`), counter: 42,
        deviceType: 'multiDevice', backedUp: true,
        aaguid: '00000000-0000-0000-0000-000000000000',
        registrationPlatform: 'ios', transports: ['internal', 'hybrid'],
      }] },
      { storageKey: emptyStorageKey, ownerSubjectHash, credentials: [] },
    ],
  };
}

function inputs(dir, ownerPath) {
  const legacyPath = join(dir, 'credentials.json');
  const quarantineDirectory = join(dir, 'quarantine');
  mkdirSync(quarantineDirectory, { mode: 0o700 });
  const bytes = Buffer.from(`${JSON.stringify(legacyDocument())}\n`);
  writeFileSync(legacyPath, bytes, { mode: 0o600 });
  return { legacyPath, ownerPath, quarantineDirectory, expectedSourceSha256: sha256(bytes), bytes };
}

function runCli(args) {
  const script = new URL('../scripts/quarantine-legacy-credentials.mjs', import.meta.url);
  return new Promise((resolve, reject) => {
    const child = spawn(process.execPath, [script.pathname,
      args.legacyPath, args.ownerPath, args.quarantineDirectory, args.expectedSourceSha256],
    { stdio: ['ignore', 'pipe', 'pipe'] });
    let stdout = '';
    let stderr = '';
    child.stdout.on('data', (chunk) => { stdout += chunk; });
    child.stderr.on('data', (chunk) => { stderr += chunk; });
    child.on('error', reject);
    child.on('close', (code) => resolve({ code, stdout, stderr }));
  });
}

test('quarantines exact validated public metadata and tombstone without changing SQLite or source', (t) => {
  const { path, dir } = setup(t);
  const input = inputs(dir, path);
  const ownerBefore = readFileSync(path);
  const result = quarantineLegacyCredentialSnapshot(input);
  assert.equal(result.mode, 'quarantine-only');
  assert.equal(result.migrationPermitted, false);
  assert.equal(result.sourceSha256, input.expectedSourceSha256);
  assert.equal(result.reconciliation.counts.legacyStorageKeys, 2);
  assert.equal(result.reconciliation.counts.legacyCredentials, 1);
  assert.equal(result.reconciliation.migrationPermitted, false);
  assert.deepEqual(readFileSync(result.snapshotPath), input.bytes);
  assert.equal(statSync(result.snapshotPath).mode & 0o777, 0o600);
  assert.equal(statSync(result.snapshotPath).nlink, 1);
  assert.deepEqual(readFileSync(input.legacyPath), input.bytes);
  assert.deepEqual(readFileSync(path), ownerBefore);
  assert.equal(readOwnerCredentialSnapshot(path).storageBindings.length, 0);
  assert.deepEqual(readdirSync(input.quarantineDirectory),
    [`legacy-${input.expectedSourceSha256}.json`]);
});

test('digest mismatch, unsafe paths and malformed JSON leave no published snapshot', (t) => {
  const { path, dir } = setup(t);
  const input = inputs(dir, path);
  assert.throws(() => quarantineLegacyCredentialSnapshot({
    ...input, expectedSourceSha256: sha256('different'),
  }), { code: 'quarantine_digest_mismatch' });
  const alias = join(dir, 'alias.json');
  symlinkSync(input.legacyPath, alias);
  assert.throws(() => quarantineLegacyCredentialSnapshot({ ...input, legacyPath: alias }),
    { code: 'quarantine_path_unsafe' });
  chmodSync(input.legacyPath, 0o644);
  assert.throws(() => quarantineLegacyCredentialSnapshot(input), { code: 'quarantine_path_unsafe' });
  chmodSync(input.legacyPath, 0o600);
  writeFileSync(input.legacyPath, Buffer.from('{"schemaVersion":4}'));
  assert.throws(() => quarantineLegacyCredentialSnapshot({
    ...input, expectedSourceSha256: sha256(readFileSync(input.legacyPath)),
  }), { code: 'quarantine_unavailable' });
  assert.deepEqual(readdirSync(input.quarantineDirectory), []);
});

test('replay cannot overwrite a captured cohort or change an active owner store', (t) => {
  const { path, dir } = setup(t);
  const input = inputs(dir, path);
  const first = quarantineLegacyCredentialSnapshot(input);
  const ownerBefore = readFileSync(path);
  assert.throws(() => quarantineLegacyCredentialSnapshot(input),
    { code: 'quarantine_already_exists' });
  assert.deepEqual(readFileSync(first.snapshotPath), input.bytes);
  assert.deepEqual(readFileSync(path), ownerBefore);
  assert.deepEqual(readdirSync(input.quarantineDirectory),
    [`legacy-${input.expectedSourceSha256}.json`]);
});

test('two processes racing the same digest publish exactly one private snapshot', async (t) => {
  const { path, dir } = setup(t);
  const input = inputs(dir, path);
  const ownerBefore = readFileSync(path);
  const results = await Promise.all([runCli(input), runCli(input)]);
  assert.deepEqual(results.map((result) => result.code).sort(), [1, 3], JSON.stringify(results));
  const success = results.find((result) => result.code === 3);
  const report = JSON.parse(success.stdout);
  assert.equal(report.migrationPermitted, false);
  assert.equal(report.reconciliation.migrationPermitted, false);
  assert.equal(report.sourceSha256, input.expectedSourceSha256);
  assert.equal(success.stdout.includes(storageKey), false);
  assert.equal(success.stdout.includes(b64(77)), false);
  assert.equal(success.stdout.includes(b64(8)), false);
  assert.deepEqual(readFileSync(join(input.quarantineDirectory, report.snapshotFile)), input.bytes);
  assert.deepEqual(readFileSync(path), ownerBefore);
  assert.deepEqual(readdirSync(input.quarantineDirectory),
    [`legacy-${input.expectedSourceSha256}.json`]);
});
