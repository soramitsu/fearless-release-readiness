import { createHash, timingSafeEqual } from 'node:crypto';
import { basename, isAbsolute } from 'node:path';
import { readPrivateLegacySnapshotBytes } from './legacy-quarantine.js';
import { verifySealedLegacyCutover } from './legacy-cutover-verifier.js';
import { SCOPES } from './validation.js';

const SHA256_HEX = /^[0-9a-f]{64}$/;
const MAX_MANIFEST_BYTES = 64 * 1024;

function deny(code = 'cutover_manifest_invalid') {
  const error = new Error(code);
  error.code = code;
  throw error;
}

function exact(value, fields) {
  if (value === null || typeof value !== 'object' || Array.isArray(value) ||
      Object.getPrototypeOf(value) !== Object.prototype ||
      Object.keys(value).length !== fields.length ||
      fields.some((field) => !Object.hasOwn(value, field))) deny();
}

function count(value) {
  if (!Number.isSafeInteger(value) || value < 0) deny();
}

function canonical(value) {
  if (Array.isArray(value)) return value.map(canonical);
  if (value && typeof value === 'object') {
    return Object.fromEntries(Object.keys(value).sort().map((key) => [key, canonical(value[key])]));
  }
  return value;
}

function sha256(bytes) {
  return createHash('sha256').update(bytes).digest('hex');
}

function sameDigest(left, right) {
  return typeof left === 'string' && typeof right === 'string' &&
    SHA256_HEX.test(left) && SHA256_HEX.test(right) &&
    timingSafeEqual(Buffer.from(left, 'hex'), Buffer.from(right, 'hex'));
}

/** The exact seven protected path/scope pairs, independent of iteration order. */
export function protectedRouteInventorySha256() {
  const routes = Object.keys(SCOPES).sort();
  if (routes.length !== 7) deny('cutover_route_inventory_changed');
  const rows = routes.map((route) => `${route} ${SCOPES[route]}`);
  return sha256(Buffer.from(`FP_OWNER_PROTECTED_ROUTES_V1\0${rows.join('\n')}\n`, 'utf8'));
}

/**
 * Read-only candidate binding. This does not verify a reviewer signature, a
 * running image, a drained old writer or a WebAuthn transcript, and it can
 * never admit production startup or authorize JSON-writer retirement.
 */
export function verifyLegacyCutoverManifest({ manifestPath, expectedManifestSha256,
  legacySnapshotPath, ownerPath, expectedOwnerImageSha256 }) {
  if (![manifestPath, legacySnapshotPath, ownerPath].every((path) =>
    typeof path === 'string' && isAbsolute(path)) ||
      typeof expectedManifestSha256 !== 'string' || !SHA256_HEX.test(expectedManifestSha256) ||
      typeof expectedOwnerImageSha256 !== 'string' || !SHA256_HEX.test(expectedOwnerImageSha256) ||
      basename(manifestPath) !== `cutover-${expectedManifestSha256}.json`) deny();
  const bytes = readPrivateLegacySnapshotBytes(manifestPath);
  if (bytes.length > MAX_MANIFEST_BYTES ||
      !sameDigest(sha256(bytes), expectedManifestSha256)) deny('cutover_manifest_mismatch');
  let manifest;
  try { manifest = JSON.parse(bytes.toString('utf8')); }
  catch { deny(); }
  exact(manifest, ['schemaVersion', 'source', 'owner', 'candidate']);
  exact(manifest.source, ['sha256', 'schemaVersion', 'storageKeys', 'credentials', 'tombstones']);
  if (![1, 2].includes(manifest.schemaVersion)) deny();
  exact(manifest.owner, manifest.schemaVersion === 2
    ? ['schemaVersion', 'publicRowsSha256', 'bindings', 'historicalMetadata',
      'verifiedProofs', 'importReceiptSha256']
    : ['schemaVersion', 'publicRowsSha256', 'bindings', 'historicalMetadata', 'verifiedProofs']);
  exact(manifest.candidate, ['ownerImageSha256', 'protectedRoutesSha256']);
  if (!Buffer.from(`${JSON.stringify(canonical(manifest), null, 2)}\n`, 'utf8').equals(bytes) ||
      !SHA256_HEX.test(manifest.source.sha256) ||
      ![3, 4].includes(manifest.source.schemaVersion) ||
      ![8, 9].includes(manifest.owner.schemaVersion) ||
      (manifest.schemaVersion === 2 && (manifest.owner.schemaVersion !== 9 ||
        !SHA256_HEX.test(manifest.owner.importReceiptSha256))) ||
      !SHA256_HEX.test(manifest.owner.publicRowsSha256)) deny();
  for (const value of [manifest.source.storageKeys, manifest.source.credentials,
    manifest.source.tombstones, manifest.owner.bindings,
    manifest.owner.historicalMetadata, manifest.owner.verifiedProofs]) count(value);
  if (!sameDigest(manifest.candidate.ownerImageSha256, expectedOwnerImageSha256) ||
      !sameDigest(manifest.candidate.protectedRoutesSha256, protectedRouteInventorySha256())) deny('cutover_manifest_candidate_mismatch');

  const report = verifySealedLegacyCutover({ legacySnapshotPath, ownerPath,
    expectedSourceSha256: manifest.source.sha256 });
  if (report.sourceSchemaVersion !== manifest.source.schemaVersion ||
      report.ownerSchemaVersion !== manifest.owner.schemaVersion ||
      !sameDigest(report.comparedTargetRowsSha256, manifest.owner.publicRowsSha256) ||
      report.counts.sourceStorageKeys !== manifest.source.storageKeys ||
      report.counts.sourceCredentials !== manifest.source.credentials ||
      report.counts.sourceTombstones !== manifest.source.tombstones ||
      report.counts.targetBindings !== manifest.owner.bindings ||
      report.counts.targetHistoricalMetadata !== manifest.owner.historicalMetadata ||
      report.proofMetadata.counts.retainedProofs !== manifest.owner.verifiedProofs) {
    deny('cutover_manifest_state_mismatch');
  }
  if (!report.publicRepresentationExact) deny('cutover_manifest_public_cohort_mismatch');
  if (manifest.schemaVersion === 2
    ? !sameDigest(report.importReceiptSha256, manifest.owner.importReceiptSha256)
    : report.importReceiptSha256 !== null) deny('cutover_manifest_receipt_mismatch');
  return Object.freeze({ schemaVersion: 1, mode: 'read-only',
    manifestSha256: expectedManifestSha256, sourceSha256: manifest.source.sha256,
    sourceAndTargetMatched: true,
    retainedProofMetadataComplete: report.proofMetadata.sourceAndBindingMetadataComplete,
    durableImportReceiptBound: manifest.schemaVersion === 2,
    migrationPermitted: false,
    blockers: Object.freeze([
      'manifest_signature_and_running_image_unverified',
      'legacy_writer_drain_and_retirement_unverified',
      ...(manifest.schemaVersion === 1 ? ['historical_cohort_import_receipt_missing'] : []),
      'webAuthn_proof_provenance_and_tombstones_unresolved',
      'production_startup_admission_missing',
    ]) });
}
