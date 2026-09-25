import { createHash, timingSafeEqual } from 'node:crypto';
import { lstatSync, realpathSync } from 'node:fs';
import { basename, dirname, isAbsolute, join, resolve } from 'node:path';
import { parseCredentialStoreSnapshotBytes } from '../../passkey-backup-challenge-service/src/store.js';
import { readPrivateLegacySnapshotBytes } from './legacy-quarantine.js';

const SHA256_HEX = /^[0-9a-f]{64}$/;
const TOKEN_HEX = /^[0-9a-f]{64}$/;

function deny(code = 'legacy_retirement_invalid') {
  const error = new Error(code);
  error.code = code;
  throw error;
}

function privateDirectory(path) {
  const stat = lstatSync(path);
  if (!stat.isDirectory() || stat.isSymbolicLink() ||
      (stat.mode & 0o077) !== 0 ||
      (process.getuid && stat.uid !== process.getuid())) deny('legacy_retirement_path_unsafe');
  return stat;
}

function sameIdentity(left, right) {
  return left.dev === right.dev && left.ino === right.ino &&
    left.size === right.size && left.mtimeMs === right.mtimeMs &&
    left.ctimeMs === right.ctimeMs;
}

function digest(bytes) {
  return createHash('sha256').update(bytes).digest();
}

function matchesDigest(bytes, expected) {
  return timingSafeEqual(digest(bytes), Buffer.from(expected, 'hex'));
}

function exactLeaseOwner(bytes, canonicalFile) {
  if (bytes.length > 1024) deny('legacy_retirement_lease_invalid');
  let owner;
  try { owner = JSON.parse(bytes.toString('utf8')); }
  catch { deny('legacy_retirement_lease_invalid'); }
  if (!owner || typeof owner !== 'object' || Array.isArray(owner) ||
      Object.keys(owner).length !== 4 || owner.schemaVersion !== 1 ||
      owner.file !== canonicalFile || !Number.isSafeInteger(owner.pid) ||
      owner.pid <= 0 || typeof owner.token !== 'string' ||
      !TOKEN_HEX.test(owner.token) ||
      !bytes.equals(Buffer.from(`${JSON.stringify({ schemaVersion: 1,
        file: canonicalFile, pid: owner.pid, token: owner.token })}\n`, 'utf8'))) {
    deny('legacy_retirement_lease_invalid');
  }
}

/**
 * Read back the legacy writer's one-way retirement artifacts against the
 * exact sealed source and manifest digest. This checks artifact consistency,
 * not the authenticity of an operator/reviewer, a running image, or admission
 * of the replacement service. It never consumes or changes either store.
 */
export function verifyRetiredJsonCredentialWriter({ credentialStoreFile,
  legacySnapshotPath, expectedSourceSha256, expectedManifestSha256 } = {}) {
  if (![credentialStoreFile, legacySnapshotPath].every((path) =>
    typeof path === 'string' && isAbsolute(path)) ||
      resolve(credentialStoreFile) === resolve(legacySnapshotPath) ||
      typeof expectedSourceSha256 !== 'string' || !SHA256_HEX.test(expectedSourceSha256) ||
      typeof expectedManifestSha256 !== 'string' || !SHA256_HEX.test(expectedManifestSha256) ||
      basename(legacySnapshotPath) !== `legacy-${expectedSourceSha256}.json`) {
    deny('legacy_retirement_invalid_request');
  }
  try {
    const directory = realpathSync(dirname(credentialStoreFile));
    const directoryBefore = privateDirectory(directory);
    const canonicalFile = join(directory, basename(credentialStoreFile));
    const lockPath = join(directory, `.${basename(canonicalFile)}.writer-lease`);
    const markerPath = join(directory, `.${basename(canonicalFile)}.retired`);
    const lockBefore = privateDirectory(lockPath);
    const sourceBefore = lstatSync(canonicalFile);
    const markerBefore = lstatSync(markerPath);
    const leaseBefore = lstatSync(join(lockPath, 'owner.json'));
    if (markerBefore.size > 512 || leaseBefore.size > 1024) {
      deny('legacy_retirement_artifact_oversize');
    }

    const live = readPrivateLegacySnapshotBytes(canonicalFile);
    const sealed = readPrivateLegacySnapshotBytes(legacySnapshotPath);
    if (!live.equals(sealed) || !matchesDigest(live, expectedSourceSha256)) {
      deny('legacy_retirement_source_mismatch');
    }
    parseCredentialStoreSnapshotBytes(live);

    const marker = readPrivateLegacySnapshotBytes(markerPath);
    const expectedMarker = Buffer.from(`${JSON.stringify({ schemaVersion: 1,
      credentialStoreSha256: expectedSourceSha256,
      cutoverManifestSha256: expectedManifestSha256 })}\n`, 'utf8');
    if (!marker.equals(expectedMarker)) deny('legacy_retirement_marker_mismatch');
    exactLeaseOwner(readPrivateLegacySnapshotBytes(join(lockPath, 'owner.json')), canonicalFile);

    if (!sameIdentity(directoryBefore, privateDirectory(directory)) ||
        !sameIdentity(lockBefore, privateDirectory(lockPath)) ||
        !sameIdentity(sourceBefore, lstatSync(canonicalFile)) ||
        !sameIdentity(markerBefore, lstatSync(markerPath)) ||
        !sameIdentity(leaseBefore, lstatSync(join(lockPath, 'owner.json')))) {
      deny('legacy_retirement_changed');
    }
    return Object.freeze({ schemaVersion: 1, mode: 'read-only',
      sourceSha256: expectedSourceSha256,
      cutoverManifestSha256: expectedManifestSha256,
      sealedSourceMatchesRetiredStore: true,
      retirementMarkerMatches: true,
      leaseArtifactPresent: true,
      migrationPermitted: false,
      productionAdmission: false });
  } catch (error) {
    if (error.code?.startsWith('legacy_retirement_')) throw error;
    deny('legacy_retirement_unavailable');
  }
}
