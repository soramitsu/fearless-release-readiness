import { createHash, randomBytes, timingSafeEqual } from 'node:crypto';
import {
  closeSync, constants, fstatSync, fsyncSync, linkSync, lstatSync, openSync,
  readSync, unlinkSync, writeSync,
} from 'node:fs';
import { dirname, isAbsolute, join, resolve } from 'node:path';
import { reconcileLegacyCredentialStores } from './legacy-reconciliation.js';

const MAX_SOURCE_BYTES = 16 * 1024 * 1024;
const SHA256_HEX = /^[0-9a-f]{64}$/;

function deny(code) {
  const error = new Error(code);
  error.code = code;
  throw error;
}

function privateStat(path, directory = false) {
  const stat = lstatSync(path);
  if (stat.isSymbolicLink() || (directory ? !stat.isDirectory() : !stat.isFile()) ||
      (stat.mode & 0o077) !== 0 || (!directory && stat.nlink !== 1) ||
      (process.getuid && stat.uid !== process.getuid())) deny('quarantine_path_unsafe');
  return stat;
}

function sameFile(left, right) {
  return left.dev === right.dev && left.ino === right.ino && left.size === right.size &&
    left.mtimeMs === right.mtimeMs && left.ctimeMs === right.ctimeMs;
}

function sourceBytes(path) {
  const before = privateStat(path);
  if (before.size < 1 || before.size > MAX_SOURCE_BYTES) deny('quarantine_source_invalid');
  const fd = openSync(path, constants.O_RDONLY | constants.O_NOFOLLOW);
  try {
    const opened = fstatSync(fd);
    if (!sameFile(before, opened) || !opened.isFile()) deny('quarantine_source_changed');
    const bytes = Buffer.allocUnsafe(before.size + 1);
    let length = 0;
    while (length < bytes.length) {
      const read = readSync(fd, bytes, length, bytes.length - length, null);
      if (read === 0) break;
      length += read;
    }
    if (length < 1 || length > MAX_SOURCE_BYTES || length !== before.size ||
        !sameFile(opened, fstatSync(fd)) || !sameFile(opened, privateStat(path))) {
      deny('quarantine_source_changed');
    }
    return bytes.subarray(0, length);
  } finally {
    closeSync(fd);
  }
}

/** Bounded, private, no-follow read for offline sealed-snapshot verification. */
export function readPrivateLegacySnapshotBytes(path) {
  if (typeof path !== 'string' || !isAbsolute(path)) deny('quarantine_invalid_request');
  privateStat(dirname(path), true);
  return sourceBytes(path);
}

function writeDurable(fd, bytes) {
  let written = 0;
  while (written < bytes.length) {
    const count = writeSync(fd, bytes, written, bytes.length - written);
    if (count < 1) deny('quarantine_unavailable');
    written += count;
  }
  fsyncSync(fd);
}

/**
 * Operator-only, offline quarantine. This captures one validated, exact JSON
 * source image without creating an owner, credential, binding, grant, or proof.
 * The caller must separately stop/drain the legacy writer before using this
 * source digest in a future reviewed migration ceremony. This API does not
 * assert that the writer was stopped and never authorizes cutover.
 */
export function quarantineLegacyCredentialSnapshot({
  legacyPath, ownerPath, quarantineDirectory, expectedSourceSha256,
}) {
  if (![legacyPath, ownerPath, quarantineDirectory].every((path) =>
    typeof path === 'string' && isAbsolute(path)) ||
      typeof expectedSourceSha256 !== 'string' || !SHA256_HEX.test(expectedSourceSha256)) {
    deny('quarantine_invalid_request');
  }
  if (resolve(dirname(legacyPath)) === resolve(quarantineDirectory) ||
      resolve(ownerPath) === resolve(legacyPath)) deny('quarantine_invalid_request');
  try {
    privateStat(quarantineDirectory, true);
    privateStat(dirname(legacyPath), true);
    const bytes = sourceBytes(legacyPath);
    const sourceSha256 = createHash('sha256').update(bytes).digest('hex');
    if (!timingSafeEqual(Buffer.from(sourceSha256, 'hex'), Buffer.from(expectedSourceSha256, 'hex'))) {
      deny('quarantine_digest_mismatch');
    }
    const basename = `legacy-${sourceSha256}.json`;
    const snapshotPath = join(quarantineDirectory, basename);
    const temporaryPath = join(quarantineDirectory, `.legacy-${randomBytes(16).toString('hex')}.tmp`);
    let fd;
    try {
      fd = openSync(temporaryPath,
        constants.O_CREAT | constants.O_EXCL | constants.O_WRONLY | constants.O_NOFOLLOW, 0o600);
      writeDurable(fd, bytes);
      closeSync(fd);
      fd = undefined;
      // Validate the exact private copy; no parser can race the source writer.
      const report = reconcileLegacyCredentialStores({ legacyPath: temporaryPath, ownerPath });
      if (report.migrationPermitted !== false) deny('quarantine_invariant_failed');
      // Hard-link publication is no-replace. Concurrent/replayed staging of
      // this digest cannot overwrite or silently trust a prior artifact.
      try { linkSync(temporaryPath, snapshotPath); }
      catch (error) {
        if (error.code === 'EEXIST') deny('quarantine_already_exists');
        throw error;
      }
      unlinkSync(temporaryPath);
      const dirFd = openSync(quarantineDirectory, constants.O_RDONLY | constants.O_NOFOLLOW);
      try { fsyncSync(dirFd); } finally { closeSync(dirFd); }
      if (createHash('sha256').update(sourceBytes(snapshotPath)).digest('hex') !== sourceSha256) {
        deny('quarantine_snapshot_changed');
      }
      return Object.freeze({ schemaVersion: 1, mode: 'quarantine-only',
        migrationPermitted: false, sourceSha256, snapshotPath, reconciliation: report });
    } finally {
      if (fd !== undefined) closeSync(fd);
      try { unlinkSync(temporaryPath); } catch (error) { if (error.code !== 'ENOENT') throw error; }
      // A published snapshot is intentionally retained after any later error.
      // An uncertain fsync outcome cannot erase operator evidence.
    }
  } catch (error) {
    if (error.code?.startsWith('quarantine_')) throw error;
    deny('quarantine_unavailable');
  }
}
