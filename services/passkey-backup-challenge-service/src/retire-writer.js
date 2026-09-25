import { createHash, timingSafeEqual } from 'node:crypto';
import {
  closeSync, constants, fstatSync, fsyncSync, lstatSync, openSync, readSync, writeSync,
} from 'node:fs';
import { dirname, isAbsolute } from 'node:path';
import { parseCredentialStoreSnapshotBytes } from './store.js';
import { acquireCredentialWriterLease } from './writer-lease.js';

const SHA256_HEX = /^[0-9a-f]{64}$/u;
const MAX_SOURCE_BYTES = 16 * 1024 * 1024;

function deny() {
  const error = new Error('Credential writer retirement requires operator review');
  error.code = 'credential_writer_retirement_failed';
  throw error;
}

function sameStat(left, right) {
  return left.dev === right.dev && left.ino === right.ino &&
    left.size === right.size && left.mtimeMs === right.mtimeMs &&
    left.ctimeMs === right.ctimeMs;
}

function readPrivateSource(path, expectedStat) {
  const fd = openSync(path, constants.O_RDONLY | constants.O_NOFOLLOW);
  try {
    const initial = fstatSync(fd);
    if (!initial.isFile() || initial.nlink !== 1 || initial.size < 1 ||
        initial.size > MAX_SOURCE_BYTES || (initial.mode & 0o077) !== 0 ||
        (process.getuid && initial.uid !== process.getuid()) ||
        !sameStat(initial, expectedStat)) deny();
    const chunks = [];
    const buffer = Buffer.alloc(64 * 1024);
    let size = 0;
    for (;;) {
      const count = readSync(fd, buffer, 0, buffer.length, null);
      if (count === 0) break;
      size += count;
      if (size > MAX_SOURCE_BYTES) deny();
      chunks.push(Buffer.from(buffer.subarray(0, count)));
    }
    if (!sameStat(initial, fstatSync(fd)) || size !== initial.size) deny();
    return Buffer.concat(chunks);
  } finally { closeSync(fd); }
}

/**
 * One-way operator primitive. The retired marker and the exclusive legacy
 * writer lease are both left in place; neither service may remove them as an
 * automatic rollback. This records a sealed JSON source digest but does not
 * prove owner migration or authorize the SQLite authority to start.
 */
export function retireJsonCredentialWriter({ credentialStoreFile,
  expectedSourceSha256, cutoverManifestSha256 }) {
  if (typeof credentialStoreFile !== 'string' || !isAbsolute(credentialStoreFile) ||
      typeof expectedSourceSha256 !== 'string' || !SHA256_HEX.test(expectedSourceSha256) ||
      typeof cutoverManifestSha256 !== 'string' || !SHA256_HEX.test(cutoverManifestSha256)) deny();
  const lease = acquireCredentialWriterLease(credentialStoreFile);
  let markerCreated = false;
  try {
    const initial = lease.initialFileIdentity;
    if (!initial) deny();
    lease.assertInitialFile();
    const source = readPrivateSource(lease.canonicalFile, initial);
    try {
      parseCredentialStoreSnapshotBytes(source);
      const actual = createHash('sha256').update(source).digest();
      if (!timingSafeEqual(actual, Buffer.from(expectedSourceSha256, 'hex'))) deny();
    } finally { source.fill(0); }
    lease.assertInitialFile();
    const marker = Buffer.from(`${JSON.stringify({ schemaVersion: 1,
      credentialStoreSha256: expectedSourceSha256, cutoverManifestSha256 })}\n`, 'utf8');
    const fd = openSync(lease.retirementMarkerPath,
      constants.O_CREAT | constants.O_EXCL | constants.O_WRONLY | constants.O_NOFOLLOW, 0o600);
    markerCreated = true;
    let markerIdentity;
    try {
      for (let offset = 0; offset < marker.length;) {
        const count = writeSync(fd, marker, offset, marker.length - offset);
        if (count <= 0) deny();
        offset += count;
      }
      fsyncSync(fd);
      markerIdentity = fstatSync(fd);
    } finally { closeSync(fd); }
    const dirFd = openSync(dirname(lease.canonicalFile),
      constants.O_RDONLY | constants.O_DIRECTORY | constants.O_NOFOLLOW);
    try { fsyncSync(dirFd); } finally { closeSync(dirFd); }
    const published = lstatSync(lease.retirementMarkerPath);
    if (!published.isFile() || published.isSymbolicLink() || published.nlink !== 1 ||
        (published.mode & 0o077) !== 0 || published.dev !== markerIdentity.dev ||
        published.ino !== markerIdentity.ino || published.size !== marker.length) deny();
    const markerFd = openSync(lease.retirementMarkerPath, constants.O_RDONLY | constants.O_NOFOLLOW);
    try {
      if (fstatSync(markerFd).ino !== markerIdentity.ino) deny();
      const observed = Buffer.alloc(marker.length + 1);
      const count = readSync(markerFd, observed, 0, observed.length, 0);
      if (count !== marker.length || !observed.subarray(0, count).equals(marker)) deny();
    } finally { closeSync(markerFd); }
    return Object.freeze({ schemaVersion: 1, credentialStoreSha256: expectedSourceSha256,
      cutoverManifestSha256, retired: true });
  } catch (error) {
    if (!markerCreated) {
      // A stable rejected input can return to the incumbent writer. An
      // uncertain source or publication retains this process's lease.
      try { lease.assertInitialFile(); lease.release(); } catch { /* preserve lease */ }
    }
    throw error;
  }
}
