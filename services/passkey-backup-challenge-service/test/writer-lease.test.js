import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { createHash } from 'node:crypto';
import { once } from 'node:events';
import {
  chmodSync, existsSync, fsyncSync, mkdtempSync, readFileSync, renameSync,
  rmSync, statSync, writeFileSync, mkdirSync, symlinkSync, unlinkSync, rmdirSync,
} from 'node:fs';
import { tmpdir } from 'node:os';
import { connect, createServer as createNetServer } from 'node:net';
import { dirname, join } from 'node:path';
import test from 'node:test';
import { createPasskeyBackupChallengeService } from '../src/service.js';
import { createServer as createChallengeServer } from '../src/server.js';
import { retireJsonCredentialWriter } from '../src/retire-writer.js';
import { createPasskeyChallengeStore, readCredentialStoreSnapshot } from '../src/store.js';

const storeUrl = new URL('../src/store.js', import.meta.url).href;
const serverPath = new URL('../src/server.js', import.meta.url).pathname;

function waitForOutput(child, expected) {
  return new Promise((resolve, reject) => {
    const timeout = setTimeout(() => reject(new Error('child startup timed out')), 5000);
    let output = '';
    let errors = '';
    child.stderr.on('data', (chunk) => { errors += chunk.toString(); });
    child.stdout.on('data', (chunk) => {
      output += chunk.toString();
      if (output.includes(expected)) { clearTimeout(timeout); resolve(); }
    });
    child.once('exit', (code) => {
      clearTimeout(timeout);
      reject(new Error(`child exited ${code}: ${errors}`));
    });
  });
}

function fixture(t) {
  const directory = mkdtempSync(join(tmpdir(), 'passkey-writer-lease-'));
  t.after(() => rmSync(directory, { recursive: true, force: true }));
  const file = join(directory, 'credentials.json');
  const lock = join(directory, '.credentials.json.writer-lease');
  const open = () => createPasskeyChallengeStore({ credentialStoreFile: file,
    requireDurable: true, productionMode: true, recoveryEnabled: 'false' });
  return { file, lock, open };
}

const sha256 = (bytes) => createHash('sha256').update(bytes).digest('hex');

test('a digest-bound retirement permanently fences the JSON credential writer', (t) => {
  const { file, lock, open } = fixture(t);
  const incumbent = open();
  incumbent.close();
  const before = readFileSync(file);
  const digest = sha256(before);
  const manifestDigest = sha256('reviewed cutover manifest fixture');
  const report = retireJsonCredentialWriter({ credentialStoreFile: file,
    expectedSourceSha256: digest, cutoverManifestSha256: manifestDigest });
  assert.deepEqual(report, { schemaVersion: 1, credentialStoreSha256: digest,
    cutoverManifestSha256: manifestDigest, retired: true });
  assert.equal(existsSync(lock), true);
  const marker = join(dirname(file), '.credentials.json.retired');
  assert.deepEqual(JSON.parse(readFileSync(marker, 'utf8')), {
    schemaVersion: 1, credentialStoreSha256: digest, cutoverManifestSha256: manifestDigest,
  });
  assert.deepEqual(readFileSync(file), before);
  assert.throws(open, { code: 'credential_store_unavailable' });
  assert.throws(() => retireJsonCredentialWriter({ credentialStoreFile: file,
    expectedSourceSha256: digest, cutoverManifestSha256: manifestDigest }),
  { code: 'credential_store_unavailable' });
});

test('retirement refuses an active writer or a changed source without publishing a marker', (t) => {
  const { file, lock, open } = fixture(t);
  const incumbent = open();
  const digest = sha256(readFileSync(file));
  const marker = join(dirname(file), '.credentials.json.retired');
  const args = { credentialStoreFile: file, expectedSourceSha256: digest,
    cutoverManifestSha256: sha256('manifest') };
  assert.throws(() => retireJsonCredentialWriter(args), { code: 'credential_store_unavailable' });
  assert.equal(existsSync(marker), false);
  incumbent.close();
  assert.throws(() => retireJsonCredentialWriter({ ...args,
    expectedSourceSha256: sha256('wrong source') }),
  { code: 'credential_writer_retirement_failed' });
  assert.equal(existsSync(marker), false);
  assert.equal(existsSync(lock), false);
  const restarted = open();
  restarted.close();
});

test('a retirement marker blocks a fresh writer even without a surviving lease', (t) => {
  const { file, lock, open } = fixture(t);
  const incumbent = open();
  incumbent.close();
  writeFileSync(join(dirname(file), '.credentials.json.retired'), 'incomplete\n', { mode: 0o600 });
  assert.throws(open, { code: 'credential_store_unavailable' });
  assert.equal(existsSync(lock), false);
});

test('a marker appearing after startup poisons the incumbent before its next write', (t) => {
  const { file, lock, open } = fixture(t);
  const incumbent = open();
  const before = readFileSync(file);
  writeFileSync(join(dirname(file), '.credentials.json.retired'), 'pending cutover\n', { mode: 0o600 });
  assert.throws(() => incumbent.persistCredentials(new Map(), new Map()),
    { code: 'credential_store_unavailable' });
  assert.deepEqual(readFileSync(file), before);
  assert.equal(incumbent.poisoned, true);
  assert.throws(() => incumbent.close(), { code: 'credential_store_unavailable' });
  assert.equal(existsSync(lock), true);
});

test('a marker appearing during temporary-file fsync blocks the JSON replacement', (t) => {
  const { file, lock } = fixture(t);
  const seeded = createPasskeyChallengeStore({ credentialStoreFile: file,
    requireDurable: true, productionMode: false });
  seeded.close();
  const before = readFileSync(file);
  let placed = false;
  const incumbent = createPasskeyChallengeStore({ credentialStoreFile: file,
    requireDurable: true, productionMode: true, recoveryEnabled: 'false', fileOperations: {
      fsyncSync(fd) {
        fsyncSync(fd);
        if (!placed) {
          placed = true;
          writeFileSync(join(dirname(file), '.credentials.json.retired'), 'cutover\n', { mode: 0o600 });
        }
      },
    } });
  assert.throws(() => incumbent.persistCredentials(new Map(), new Map()),
    { code: 'credential_store_unavailable' });
  assert.equal(placed, true);
  assert.deepEqual(readFileSync(file), before);
  assert.equal(incumbent.poisoned, true);
  assert.throws(() => incumbent.close(), { code: 'credential_store_unavailable' });
  assert.equal(existsSync(lock), true);
});

async function childWriter(t, file) {
  const script = `import { createPasskeyChallengeStore } from ${JSON.stringify(storeUrl)};
    const store = createPasskeyChallengeStore({ credentialStoreFile: process.argv[1],
      requireDurable: true, productionMode: true, recoveryEnabled: 'false' });
    process.once('SIGTERM', () => { store.close(); process.exit(0); });
    process.stdout.write('READY\\n');
    setInterval(() => {}, 1000);`;
  const child = spawn(process.execPath, ['--input-type=module', '-e', script, file], {
    stdio: ['ignore', 'pipe', 'pipe'],
    env: { ...process.env, PASSKEY_OWNER_AUTHORITY_STORE_FILE: undefined },
  });
  t.after(() => { if (child.exitCode === null && child.signalCode === null) child.kill('SIGKILL'); });
  await waitForOutput(child, 'READY\n');
  return child;
}

test('a second process cannot write the same production JSON credential file', async (t) => {
  const { file, lock, open } = fixture(t);
  const child = await childWriter(t, file);
  assert.equal(existsSync(lock), true);
  assert.throws(open, { code: 'credential_store_unavailable' });
  child.kill('SIGTERM');
  const [code, signal] = await once(child, 'exit');
  assert.equal(code, 0);
  assert.equal(signal, null);
  assert.equal(existsSync(lock), false);
  const restarted = open();
  restarted.close();
});

test('an unclean exit retains the lease until an operator preserves and reviews the store', async (t) => {
  const { file, lock, open } = fixture(t);
  const child = await childWriter(t, file);
  child.kill('SIGKILL');
  const [, signal] = await once(child, 'exit');
  assert.equal(signal, 'SIGKILL');
  const snapshot = readFileSync(file);
  const owner = readFileSync(join(lock, 'owner.json'));
  assert.equal(existsSync(lock), true);
  assert.throws(open, { code: 'credential_store_unavailable' });
  assert.deepEqual(readFileSync(file), snapshot);
  assert.deepEqual(readFileSync(join(lock, 'owner.json')), owner);
  // Test-only simulation of the documented, operator-reviewed stale lease
  // removal; the service itself never takes over a crashed writer's lease.
  unlinkSync(join(lock, 'owner.json'));
  rmdirSync(lock);
  const restarted = open();
  restarted.close();
  assert.deepEqual(readFileSync(file), snapshot);
});

test('health and close reject a changed lease without clearing it or exposing its token', async (t) => {
  const { file, lock, open } = fixture(t);
  const store = open();
  const service = createPasskeyBackupChallengeService({ store });
  const server = createChallengeServer({ service, requestAuthorizer: {
    async authorize() { throw new Error('health must not authorize'); },
  } });
  await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
  t.after(() => new Promise((resolve) => server.close(resolve)));
  const healthUrl = `http://127.0.0.1:${server.address().port}/api/passkey-backup/v1/health`;
  const healthy = await fetch(healthUrl);
  assert.equal(healthy.status, 200);
  const ownerPath = join(lock, 'owner.json');
  const original = readFileSync(ownerPath);
  const before = readFileSync(file);
  writeFileSync(ownerPath, Buffer.from('replaced owner token\n'));
  const unhealthy = await fetch(healthUrl);
  assert.equal(unhealthy.status, 503);
  const body = await unhealthy.text();
  assert.match(body, /"error":"credential_store_unavailable"/);
  assert.equal(body.includes('replaced owner token'), false);
  assert.equal(body.includes(JSON.parse(original.toString()).token), false);
  assert.throws(() => store.persistCredentials(new Map(), new Map()),
    { code: 'credential_store_unavailable' });
  assert.deepEqual(readFileSync(file), before);
  writeFileSync(ownerPath, original);
  assert.throws(() => store.persistCredentials(new Map(), new Map()),
    { code: 'credential_store_unavailable' });
  writeFileSync(ownerPath, Buffer.from('replaced owner token\n'));
  assert.throws(() => store.close(), { code: 'credential_store_unavailable' });
  assert.equal(existsSync(lock), true);
  assert.equal(readFileSync(ownerPath, 'utf8'), 'replaced owner token\n');
  assert.throws(open, { code: 'credential_store_unavailable' });
  assert.notDeepEqual(readFileSync(ownerPath), original);
});

test('a lease replaced during temporary-file fsync blocks the atomic rename', (t) => {
  const { file, lock } = fixture(t);
  const seeded = createPasskeyChallengeStore({ credentialStoreFile: file, requireDurable: true,
    productionMode: false });
  seeded.close();
  const before = readFileSync(file);
  let replaced = false;
  const store = createPasskeyChallengeStore({ credentialStoreFile: file, requireDurable: true,
    productionMode: true, recoveryEnabled: 'false', fileOperations: {
      fsyncSync(fd) {
        fsyncSync(fd);
        if (!replaced) {
          replaced = true;
          writeFileSync(join(lock, 'owner.json'), 'different lease owner\n');
        }
      },
    } });
  assert.throws(() => store.persistCredentials(new Map(), new Map()),
    { code: 'credential_store_unavailable' });
  assert.equal(replaced, true);
  assert.deepEqual(readFileSync(file), before);
  assert.throws(() => store.close(), { code: 'credential_store_unavailable' });
});

test('failed construction clears only its own partial lease', (t) => {
  const { file, lock, open } = fixture(t);
  writeFileSync(file, '{invalid json');
  assert.throws(open, { code: 'credential_store_invalid' });
  assert.equal(existsSync(lock), false);
  rmSync(file);
  mkdirSync(lock, { mode: 0o700 });
  writeFileSync(join(lock, 'owner.json'), 'foreign owner\n', { mode: 0o600 });
  assert.throws(open, { code: 'credential_store_unavailable' });
  assert.equal(readFileSync(join(lock, 'owner.json'), 'utf8'), 'foreign owner\n');
});

test('constructor retains its lease after a visible but nondurable initial replacement', (t) => {
  const { file, lock, open } = fixture(t);
  let syncCount = 0;
  assert.throws(() => createPasskeyChallengeStore({ credentialStoreFile: file,
    requireDurable: true, productionMode: true, recoveryEnabled: 'false', fileOperations: {
      fsyncSync(fd) {
        if (++syncCount === 2) throw new Error('directory fsync failed after rename');
        fsyncSync(fd);
      },
    } }), { code: 'credential_store_unavailable' });
  assert.equal(syncCount, 2);
  assert.equal(existsSync(file), true);
  assert.equal(JSON.parse(readFileSync(file, 'utf8')).schemaVersion, 4);
  assert.equal(existsSync(lock), true);
  assert.throws(open, { code: 'credential_store_unavailable' });
});

test('fresh startup never overwrites a credential file created after lease acquisition', (t) => {
  const { file, lock, open } = fixture(t);
  const unexpected = 'concurrent credential file\n';
  let inserted = false;
  assert.throws(() => createPasskeyChallengeStore({ credentialStoreFile: file,
    requireDurable: true, productionMode: true, recoveryEnabled: 'false', fileOperations: {
      fsyncSync(fd) {
        fsyncSync(fd);
        if (!inserted) {
          inserted = true;
          writeFileSync(file, unexpected, { mode: 0o600 });
        }
      },
    } }), { code: 'credential_store_unavailable' });
  assert.equal(inserted, true);
  assert.equal(readFileSync(file, 'utf8'), unexpected);
  assert.equal(existsSync(lock), true);
  assert.throws(open, { code: 'credential_store_unavailable' });
});

test('initial read rejects a different opened credential-file inode even with identical bytes', (t) => {
  const { file } = fixture(t);
  const seed = createPasskeyChallengeStore({ credentialStoreFile: file, requireDurable: true,
    productionMode: false });
  seed.close();
  const expected = statSync(file);
  const replacement = `${file}.replacement`;
  writeFileSync(replacement, readFileSync(file), { mode: 0o600 });
  renameSync(replacement, file);
  assert.throws(() => readCredentialStoreSnapshot(file, expected),
    { code: 'credential_store_unavailable', writerLeaseNeedsReview: true });
});

test('runtime post-rename uncertainty poisons the production writer and retains its lease', (t) => {
  const { file, lock } = fixture(t);
  const seed = createPasskeyChallengeStore({ credentialStoreFile: file, requireDurable: true,
    productionMode: false });
  seed.close();
  let syncCount = 0;
  const store = createPasskeyChallengeStore({ credentialStoreFile: file,
    requireDurable: true, productionMode: true, recoveryEnabled: 'false', fileOperations: {
      fsyncSync(fd) {
        if (++syncCount === 2) throw new Error('directory fsync failed after rename');
        fsyncSync(fd);
      },
    } });
  const service = createPasskeyBackupChallengeService({ store });
  assert.equal(service.health().ok, true);
  assert.throws(() => store.commitState(new Map(), new Map()),
    { code: 'credential_store_unavailable' });
  assert.equal(store.poisoned, true);
  assert.throws(() => service.health(), { status: 503, code: 'credential_store_unavailable' });
  const afterUncertainCommit = readFileSync(file);
  assert.throws(() => store.commitState(new Map(), new Map()),
    { code: 'credential_store_unavailable' });
  assert.equal(syncCount, 2, 'poisoned writer must not start a second persistence attempt');
  assert.deepEqual(readFileSync(file), afterUncertainCommit);
  assert.throws(() => store.close(), { code: 'credential_store_unavailable' });
  assert.equal(existsSync(lock), true);
});

test('a closed production store cannot publish another credential file', (t) => {
  const { file, open } = fixture(t);
  const store = open();
  const before = readFileSync(file);
  store.close();
  assert.throws(() => store.persistCredentials(new Map(), new Map()),
    { code: 'credential_store_unavailable' });
  assert.deepEqual(readFileSync(file), before);
});

test('production startup rejects a public volume root and a dangling credential-file symlink', (t) => {
  const { file, lock, open } = fixture(t);
  chmodSync(dirname(file), 0o755);
  assert.throws(open, { code: 'credential_store_unavailable' });
  assert.equal(existsSync(lock), false);
  chmodSync(dirname(file), 0o700);
  symlinkSync(join(dirname(file), 'missing.json'), file);
  assert.throws(open, { code: 'credential_store_unavailable' });
  assert.equal(existsSync(lock), false);
  unlinkSync(file);
  const store = open();
  store.close();
});

test('production uses one canonical writer lease across directory aliases', (t) => {
  const { file, lock, open } = fixture(t);
  const alias = `${dirname(file)}-alias`;
  symlinkSync(dirname(file), alias);
  t.after(() => unlinkSync(alias));
  const first = open();
  assert.throws(() => createPasskeyChallengeStore({ credentialStoreFile: join(alias, 'credentials.json'),
    requireDurable: true, productionMode: true, recoveryEnabled: 'false' }),
  { code: 'credential_store_unavailable' });
  assert.equal(existsSync(lock), true);
  first.close();
});

test('production SIGTERM drains an in-flight HTTP request before releasing its writer lease', async (t) => {
  const { file, lock } = fixture(t);
  const probe = createNetServer();
  await new Promise((resolve) => probe.listen(0, '127.0.0.1', resolve));
  const port = probe.address().port;
  await new Promise((resolve) => probe.close(resolve));
  const child = spawn(process.execPath, [serverPath], { stdio: ['ignore', 'pipe', 'pipe'],
    env: { ...process.env, NODE_ENV: 'production', HOST: '127.0.0.1', PORT: String(port),
      PASSKEY_CREDENTIAL_STORE_FILE: file, PASSKEY_RECOVERY_ENABLED: 'false',
      PASSKEY_OWNER_AUTHORITY_STORE_FILE: undefined,
      PASSKEY_ALLOWED_ORIGINS: 'https://fearlesswallet.io,https://backup.fearlesswallet.io',
      PASSKEY_ANDROID_ALLOWED_ORIGIN: `android:apk-key-hash:${Buffer.alloc(32, 1).toString('base64url')}`,
      PASSKEY_AUTHORIZATION_INTROSPECTION_URL: 'https://example.com/v1/passkey/consume',
      PASSKEY_AUTHORIZATION_AUDIENCE: 'fearless-passkey-backup',
      PASSKEY_TRUST_PROXY_HOPS: '1', PASSKEY_TRUSTED_PROXY_CIDRS: '127.0.0.1',
    } });
  t.after(() => { if (child.exitCode === null && child.signalCode === null) child.kill('SIGKILL'); });
  await waitForOutput(child, `listening on 127.0.0.1:${port}`);
  const socket = connect(port, '127.0.0.1');
  t.after(() => socket.destroy());
  await once(socket, 'connect');
  socket.write('POST /api/passkey-backup/v1/registration/challenge HTTP/1.1\r\n' +
    'Host: 127.0.0.1\r\nX-Forwarded-For: 127.0.0.2\r\n' +
    'Authorization: Bearer incomplete-test\r\nContent-Type: application/json\r\n' +
    'Content-Length: 1024\r\nConnection: close\r\n\r\n{');
  await new Promise((resolve) => setTimeout(resolve, 100));
  child.kill('SIGTERM');
  await new Promise((resolve) => setTimeout(resolve, 100));
  assert.equal(child.exitCode, null, 'listener must wait for the active request');
  assert.equal(existsSync(lock), true, 'lease must remain while the active request drains');
  socket.destroy();
  const [code, signal] = await once(child, 'exit');
  assert.equal(code, 0);
  assert.equal(signal, null);
  assert.equal(existsSync(lock), false);
});
