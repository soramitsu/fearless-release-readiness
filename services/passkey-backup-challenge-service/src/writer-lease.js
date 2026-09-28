import { randomBytes } from 'node:crypto';
import {
  closeSync, constants, fstatSync, fsyncSync, lstatSync,
  mkdirSync, openSync, readSync, realpathSync, rmdirSync, unlinkSync,
  writeFileSync,
} from 'node:fs';
import { basename, dirname, isAbsolute, join } from 'node:path';
import { serviceError } from './errors.js';

function unavailable() {
  return serviceError(500, 'credential_store_unavailable', 'Credential store writer lease is unavailable');
}

function changedInitialFile() {
  const error = unavailable();
  error.writerLeaseNeedsReview = true;
  return error;
}

function sameIdentity(left, right) {
  return left.dev === right.dev && left.ino === right.ino;
}

function privateDirectory(path) {
  const stat = lstatSync(path);
  if (!stat.isDirectory() || stat.isSymbolicLink() ||
      (stat.mode & 0o077) !== 0 ||
      (process.getuid && stat.uid !== process.getuid())) throw unavailable();
  return stat;
}

function syncDirectory(path) {
  const fd = openSync(path, constants.O_RDONLY | constants.O_DIRECTORY | constants.O_NOFOLLOW);
  try { fsyncSync(fd); } finally { closeSync(fd); }
}

function existingFileStat(path) {
  try { return lstatSync(path); }
  catch (error) {
    if (error.code === 'ENOENT') return null;
    throw error;
  }
}

function snapshotIdentity(stat) {
  return stat && Object.freeze({ dev: stat.dev, ino: stat.ino, size: stat.size,
    mtimeMs: stat.mtimeMs, ctimeMs: stat.ctimeMs });
}

function sameSnapshot(left, right) {
  return (left === null && right === null) ||
    (left !== null && right !== null && sameIdentity(left, right) &&
      left.size === right.size && left.mtimeMs === right.mtimeMs &&
      left.ctimeMs === right.ctimeMs);
}

/**
 * Exclusive, persistent local-filesystem lease for the legacy JSON writer.
 * A process crash intentionally leaves the lease behind. No PID or elapsed
 * time can authorize automatic takeover of a credential/revocation writer.
 */
export function acquireCredentialWriterLease(credentialStoreFile) {
  if (typeof credentialStoreFile !== 'string' || !isAbsolute(credentialStoreFile) ||
      basename(credentialStoreFile) === '.' || basename(credentialStoreFile) === '..') {
    throw unavailable();
  }
  let lockPath;
  let ownerPath;
  let retirementMarkerPath;
  let parentIdentity;
  let directoryIdentity;
  let ownerIdentity;
  let ownerBytes;
  let acquired = false;
  try {
    mkdirSync(dirname(credentialStoreFile), { recursive: true, mode: 0o700 });
    const directory = realpathSync(dirname(credentialStoreFile));
    parentIdentity = privateDirectory(directory);
    const canonicalFile = join(directory, basename(credentialStoreFile));
    lockPath = join(directory, `.${basename(canonicalFile)}.writer-lease`);
    ownerPath = join(lockPath, 'owner.json');
    retirementMarkerPath = join(directory, `.${basename(canonicalFile)}.retired`);
    if (existingFileStat(retirementMarkerPath)) throw unavailable();
    mkdirSync(lockPath, { mode: 0o700 });
    acquired = true;
    directoryIdentity = lstatSync(lockPath);
    privateDirectory(lockPath);
    if (existingFileStat(retirementMarkerPath)) throw unavailable();
    const file = existingFileStat(canonicalFile);
    if (file && (!file.isFile() || file.isSymbolicLink() || file.nlink !== 1)) throw unavailable();
    const initialFileIdentity = snapshotIdentity(file);
    const token = randomBytes(32).toString('hex');
    ownerBytes = Buffer.from(`${JSON.stringify({ schemaVersion: 1, file: canonicalFile,
      pid: process.pid, token })}\n`);
    const fd = openSync(ownerPath,
      constants.O_CREAT | constants.O_EXCL | constants.O_WRONLY | constants.O_NOFOLLOW, 0o600);
    try {
      ownerIdentity = fstatSync(fd);
      writeFileSync(fd, ownerBytes);
      fsyncSync(fd);
    } finally { closeSync(fd); }
    syncDirectory(lockPath);
    syncDirectory(directory);

    let released = false;
    const assertOwned = () => {
      if (released) throw unavailable();
      try {
        if (existingFileStat(retirementMarkerPath)) throw unavailable();
        if (!sameIdentity(privateDirectory(directory), parentIdentity)) throw unavailable();
        if (!sameIdentity(privateDirectory(lockPath), directoryIdentity)) throw unavailable();
        const current = lstatSync(ownerPath);
        if (!current.isFile() || current.isSymbolicLink() || current.nlink !== 1 ||
            (current.mode & 0o077) !== 0 || current.size !== ownerBytes.length ||
            !sameIdentity(current, ownerIdentity)) throw unavailable();
        const fd = openSync(ownerPath, constants.O_RDONLY | constants.O_NOFOLLOW);
        try {
          const opened = fstatSync(fd);
          if (!sameIdentity(opened, ownerIdentity) || opened.size !== ownerBytes.length) throw unavailable();
          const bytes = Buffer.alloc(ownerBytes.length + 1);
          const count = readSync(fd, bytes, 0, bytes.length, 0);
          if (count !== ownerBytes.length || !bytes.subarray(0, count).equals(ownerBytes)) throw unavailable();
        } finally { closeSync(fd); }
      } catch { throw unavailable(); }
    };
    return Object.freeze({ lockPath, canonicalFile, retirementMarkerPath, initialFileIdentity, assertOwned,
      assertInitialFile() {
        assertOwned();
        try {
          const current = existingFileStat(canonicalFile);
          if (!sameSnapshot(current, initialFileIdentity)) throw changedInitialFile();
        } catch { throw changedInitialFile(); }
      },
      release() {
        if (released) return;
        assertOwned();
        try {
          unlinkSync(ownerPath);
          rmdirSync(lockPath);
          syncDirectory(directory);
          released = true;
        } catch { throw unavailable(); }
      },
    });
  } catch {
    // Only remove the directory and owner file created by this invocation.
    // A pre-existing or replaced lease is never taken over or cleared.
    if (acquired && directoryIdentity) {
      try {
        if (sameIdentity(lstatSync(lockPath), directoryIdentity)) {
          if (ownerIdentity) {
            const current = lstatSync(ownerPath);
            if (current.isFile() && !current.isSymbolicLink() &&
                sameIdentity(current, ownerIdentity)) unlinkSync(ownerPath);
          }
          rmdirSync(lockPath);
          syncDirectory(dirname(lockPath));
        }
      } catch { /* A partial or changed lease remains fail-closed for operator review. */ }
    }
    throw unavailable();
  }
}
