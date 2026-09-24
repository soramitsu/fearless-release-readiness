import { createHash, timingSafeEqual } from 'node:crypto';
import { basename, isAbsolute, resolve } from 'node:path';
import { parseCredentialStoreSnapshotBytes } from '../../passkey-backup-challenge-service/src/store.js';
import { readPrivateLegacySnapshotBytes } from './legacy-quarantine.js';
import { readOwnerCredentialSnapshot } from './store.js';

const SHA256_HEX = /^[0-9a-f]{64}$/;
const MAX_DIAGNOSTICS = 512;

function deny(code) {
  const error = new Error(code);
  error.code = code;
  throw error;
}

function readSealedSource(path, expectedSha256) {
  const before = readPrivateLegacySnapshotBytes(path);
  const actual = createHash('sha256').update(before).digest();
  if (!timingSafeEqual(actual, Buffer.from(expectedSha256, 'hex'))) deny('cutover_snapshot_mismatch');
  // Parse the same verified bytes: a second path open could race replacement.
  // This still cannot prove that the deployed JSON writer was drained.
  return parseCredentialStoreSnapshotBytes(before);
}

/** Exact public credential from an independently named and digest-pinned private image.
 * This is source evidence only: it proves neither wallet ownership nor that the
 * live JSON writer has stopped. No source bytes or public key enter the report.
 */
export function readSealedLegacyCredential({ legacySnapshotPath, expectedSourceSha256, storageKey, credentialId }) {
  if (typeof legacySnapshotPath !== 'string' || !isAbsolute(legacySnapshotPath) ||
      typeof expectedSourceSha256 !== 'string' || !SHA256_HEX.test(expectedSourceSha256) ||
      basename(legacySnapshotPath) !== `legacy-${expectedSourceSha256}.json` ||
      typeof storageKey !== 'string' || !/^[A-Za-z0-9._:-]{8,128}$/.test(storageKey) ||
      typeof credentialId !== 'string') deny('cutover_invalid_request');
  const source = readSealedSource(legacySnapshotPath, expectedSourceSha256);
  const cohort = source.credentialsByStorageKey.get(storageKey);
  const credential = cohort?.get(credentialId);
  if (!credential) deny('cutover_source_credential_missing');
  return Object.freeze({
    sourceSha256: expectedSourceSha256,
    snapshotName: `legacy-${expectedSourceSha256}.json`,
    storageKey,
    legacyOwnerHash: source.ownersByStorageKey.get(storageKey),
    legacyCredentialId: credential.id,
    // Internal verification material from the exact digest-pinned bytes. Never
    // include this value in a cutover report or a public challenge response.
    legacyPublicKey: credential.publicKey,
    legacyPublicKeySha256: createHash('sha256').update(Buffer.from(credential.publicKey, 'base64url')).digest('hex'),
    legacyCounter: credential.counter,
    legacyUserHandle: credential.userId,
    legacyDeviceType: credential.deviceType,
    legacyBackedUp: credential.backedUp,
    legacyScope: 'storage',
    legacyRegistrationPlatform: credential.registrationPlatform,
  });
}

/**
 * Compare a privately quarantined JSON image with schema-v7 SQLite without
 * opening either store for writing. This is a representation check only:
 * proof_sha256 is a commitment, not an authenticated ownership ceremony.
 * The return value can never authorize import, startup, or recovery.
 */
export function verifySealedLegacyCutover({ legacySnapshotPath, ownerPath, expectedSourceSha256 }) {
  if (typeof legacySnapshotPath !== 'string' || !isAbsolute(legacySnapshotPath) ||
      typeof ownerPath !== 'string' || !isAbsolute(ownerPath) ||
      resolve(legacySnapshotPath) === resolve(ownerPath) ||
      typeof expectedSourceSha256 !== 'string' || !SHA256_HEX.test(expectedSourceSha256) ||
      basename(legacySnapshotPath) !== `legacy-${expectedSourceSha256}.json`) {
    deny('cutover_invalid_request');
  }
  const source = readSealedSource(legacySnapshotPath, expectedSourceSha256);
  const target = readOwnerCredentialSnapshot(ownerPath);
  if (target.schemaVersion !== 7) deny('cutover_owner_schema_mismatch');
  const comparedTargetRowsSha256 = createHash('sha256')
    .update('FP_LEGACY_PUBLIC_STATE_V1\0')
    .update(JSON.stringify([target.owners, target.credentials, target.storageBindings,
      target.legacyCredentialMetadata, target.credentialScopes]))
    .digest('hex');

  const bindings = new Map(target.storageBindings.map((row) => [row.storage_key, row]));
  const credentials = new Map(target.credentials.map((row) => [row.id, row]));
  const metadata = new Map(target.legacyCredentialMetadata.map((row) => [row.credential_id, row]));
  const scopes = new Map(target.credentialScopes.map((row) => [row.credential_id, row]));
  const ownerSubjects = new Set(target.owners.map((row) => row.subject));
  const sourceKeys = new Set(source.credentialsByStorageKey.keys());
  const sourceCredentialIds = new Set();
  const ownersByHistoricalHash = new Map();
  const historicalHashesByOwner = new Map();
  const counts = {
    sourceStorageKeys: sourceKeys.size, sourceCredentials: 0, sourceTombstones: 0,
    targetBindings: bindings.size, targetHistoricalMetadata: metadata.size,
    matchedBindings: 0, matchedCredentials: 0, matchedTombstones: 0,
    targetOwnerOnlyCredentials: 0, discrepancies: 0,
  };
  const diagnostics = [];
  let omittedDiagnostics = 0;
  const issue = (kind, storageEntryIndex = null, credentialEntryIndex = null) => {
    counts.discrepancies += 1;
    if (diagnostics.length < MAX_DIAGNOSTICS) {
      diagnostics.push(Object.freeze({ kind, storageEntryIndex, credentialEntryIndex }));
    } else omittedDiagnostics += 1;
  };

  let storageEntryIndex = 0;
  for (const [storageKey, sourceCredentials] of source.credentialsByStorageKey) {
    const index = storageEntryIndex++;
    const historicalHash = source.ownersByStorageKey.get(storageKey);
    const binding = bindings.get(storageKey);
    if (sourceCredentials.size === 0) counts.sourceTombstones += 1;
    if (!binding) issue('storage_binding_missing', index);
    else {
      let exact = true;
      if (binding.source_sha256 !== expectedSourceSha256) {
        issue('binding_source_digest_mismatch', index);
        exact = false;
      }
      if (binding.legacy_owner_hash !== historicalHash) {
        issue('binding_legacy_owner_hash_mismatch', index);
        exact = false;
      }
      if (!ownerSubjects.has(binding.owner)) {
        issue('binding_owner_missing', index);
        exact = false;
      }
      if (!SHA256_HEX.test(binding.proof_sha256)) {
        issue('proof_commitment_malformed', index);
        exact = false;
      }
      if (exact) {
        counts.matchedBindings += 1;
        if (sourceCredentials.size === 0) counts.matchedTombstones += 1;
      }
      if (!ownersByHistoricalHash.has(historicalHash)) ownersByHistoricalHash.set(historicalHash, new Set());
      ownersByHistoricalHash.get(historicalHash).add(binding.owner);
      if (!historicalHashesByOwner.has(binding.owner)) historicalHashesByOwner.set(binding.owner, new Set());
      historicalHashesByOwner.get(binding.owner).add(historicalHash);
    }
    let credentialEntryIndex = 0;
    for (const [id, sourceCredential] of sourceCredentials) {
      const credentialIndex = credentialEntryIndex++;
      counts.sourceCredentials += 1;
      sourceCredentialIds.add(id);
      const targetCredential = credentials.get(id);
      const targetMetadata = metadata.get(id);
      const targetScope = scopes.get(id);
      if (!targetCredential) {
        issue('credential_missing', index, credentialIndex);
        continue;
      }
      let exact = true;
      if (!binding || targetCredential.owner !== binding.owner ||
          targetCredential.public_key !== sourceCredential.publicKey ||
          targetCredential.user_handle !== sourceCredential.userId ||
          targetCredential.counter !== sourceCredential.counter ||
          targetCredential.device_type !== sourceCredential.deviceType ||
          targetCredential.backed_up !== Number(sourceCredential.backedUp) ||
          targetCredential.revoked !== 0) {
        issue('credential_public_state_mismatch', index, credentialIndex);
        exact = false;
      }
      if (!targetMetadata) {
        issue('credential_metadata_missing', index, credentialIndex);
        exact = false;
      } else if (targetMetadata.storage_key !== storageKey ||
          targetMetadata.aaguid !== sourceCredential.aaguid ||
          targetMetadata.registration_platform !== sourceCredential.registrationPlatform ||
          targetMetadata.transports_json !==
            (sourceCredential.transports === undefined ? null : JSON.stringify(sourceCredential.transports))) {
        issue('credential_metadata_mismatch', index, credentialIndex);
        exact = false;
      }
      if (!binding || !targetScope || targetScope.owner !== binding.owner ||
          targetScope.scope !== 'storage' || targetScope.storage_key !== storageKey) {
        issue('credential_scope_mismatch', index, credentialIndex);
        exact = false;
      }
      if (exact) counts.matchedCredentials += 1;
    }
  }
  for (const owners of ownersByHistoricalHash.values()) {
    if (owners.size !== 1) issue('historical_owner_split');
  }
  for (const historicalHashes of historicalHashesByOwner.values()) {
    if (historicalHashes.size !== 1) issue('random_owner_alias_ambiguous');
  }
  for (const key of bindings.keys()) {
    if (!sourceKeys.has(key)) issue('target_binding_not_in_source');
  }
  for (const row of target.legacyCredentialMetadata) {
    if (!sourceCredentialIds.has(row.credential_id)) issue('target_metadata_not_in_source');
  }
  for (const row of target.credentialScopes) {
    if (row.scope === 'storage' && !sourceCredentialIds.has(row.credential_id)) {
      issue('target_storage_scope_not_in_source');
    }
  }
  for (const row of target.credentials) {
    if (!sourceCredentialIds.has(row.id) && scopes.get(row.id)?.scope === 'owner') {
      counts.targetOwnerOnlyCredentials += 1;
    }
  }
  return Object.freeze({ schemaVersion: 1, mode: 'read-only', migrationPermitted: false,
    publicRepresentationExact: counts.discrepancies === 0,
    sourceSha256: expectedSourceSha256, comparedTargetRowsSha256,
    sourceSchemaVersion: source.needsMigration ? 3 : 4,
    ownerSchemaVersion: target.schemaVersion, counts: Object.freeze(counts),
    diagnostics: Object.freeze(diagnostics), omittedDiagnostics,
    blockers: Object.freeze([
      'fresh_legacy_credential_assertion_and_random_owner_proof_unverified',
      'legacy_json_writer_drain_unverified',
      'single_writer_cutover_manifest_and_startup_gate_missing',
      'exact_signed_upgrade_and_replacement_device_acceptance_missing',
    ]) });
}
