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
 * Compare a privately quarantined JSON image with schema-v7/v8 SQLite without
 * opening either store for writing. Public representation and retained proof
 * metadata are reported separately; neither can authorize an owner link.
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
  if (![7, 8].includes(target.schemaVersion)) deny('cutover_owner_schema_mismatch');
  const comparedTargetRowsSha256 = createHash('sha256')
    .update('FP_LEGACY_PUBLIC_STATE_V1\0')
    .update(JSON.stringify([target.owners, target.credentials, target.storageBindings,
      target.legacyCredentialMetadata, target.credentialScopes]))
    .digest('hex');

  const bindings = new Map(target.storageBindings.map((row) => [row.storage_key, row]));
  const credentials = new Map(target.credentials.map((row) => [row.id, row]));
  const metadata = new Map(target.legacyCredentialMetadata.map((row) => [row.credential_id, row]));
  const scopes = new Map(target.credentialScopes.map((row) => [row.credential_id, row]));
  const challenges = new Map(target.legacyCutoverChallenges.map((row) => [row.id, row]));
  const proofs = new Map(target.legacyCutoverVerifiedProofs.map((row) => [row.legacy_credential_id, row]));
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
  const proofCounts = {
    retainedProofs: target.legacyCutoverVerifiedProofs.length,
    sourceAlignedProofs: 0, ownerAlignedProofs: 0, anchoredStorageKeys: 0,
    missingProofs: 0, unprovenEmptyTombstones: 0, discrepancies: 0,
  };
  const proofDiagnostics = [];
  let omittedProofDiagnostics = 0;
  const proofIssue = (kind, storageEntryIndex = null, credentialEntryIndex = null) => {
    proofCounts.discrepancies += 1;
    if (proofDiagnostics.length < MAX_DIAGNOSTICS) {
      proofDiagnostics.push(Object.freeze({ kind, storageEntryIndex, credentialEntryIndex }));
    } else omittedProofDiagnostics += 1;
  };
  if (target.schemaVersion < 8) proofIssue('verified_proof_schema_unavailable');

  let storageEntryIndex = 0;
  for (const [storageKey, sourceCredentials] of source.credentialsByStorageKey) {
    const index = storageEntryIndex++;
    const historicalHash = source.ownersByStorageKey.get(storageKey);
    const binding = bindings.get(storageKey);
    if (sourceCredentials.size === 0) {
      counts.sourceTombstones += 1;
      proofCounts.unprovenEmptyTombstones += 1;
      proofIssue('empty_tombstone_has_no_credential_proof', index);
    }
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
    let bindingAnchorMatched = false;
    for (const [id, sourceCredential] of sourceCredentials) {
      const credentialIndex = credentialEntryIndex++;
      counts.sourceCredentials += 1;
      sourceCredentialIds.add(id);
      const proof = proofs.get(id);
      if (!proof) {
        proofCounts.missingProofs += 1;
        proofIssue('verified_proof_missing', index, credentialIndex);
      } else {
        const challenge = challenges.get(proof.challenge_id);
        if (!challenge || challenge.state !== 2) {
          proofIssue('verified_proof_source_mismatch', index, credentialIndex);
        } else if (challenge.storage_key !== storageKey) {
          proofIssue('verified_proof_storage_key_mismatch', index, credentialIndex);
        } else if (proof.source_sha256 !== expectedSourceSha256 ||
            challenge.source_sha256 !== expectedSourceSha256 ||
            challenge.snapshot_name !== `legacy-${expectedSourceSha256}.json`) {
          proofIssue('verified_proof_source_mismatch', index, credentialIndex);
        } else if (challenge.legacy_owner_hash !== historicalHash ||
            challenge.legacy_credential_id !== id || proof.legacy_credential_id !== id ||
            challenge.legacy_public_key_sha256 !== createHash('sha256')
              .update(Buffer.from(sourceCredential.publicKey, 'base64url')).digest('hex') ||
            challenge.legacy_counter !== sourceCredential.counter ||
            challenge.legacy_user_handle !== sourceCredential.userId ||
            challenge.legacy_scope !== 'storage' || challenge.rp_id !== 'fearlesswallet.io' ||
            challenge.owner !== proof.owner ||
            proof.legacy_device_type !== sourceCredential.deviceType ||
            proof.legacy_backed_up !== Number(sourceCredential.backedUp)) {
          proofIssue('verified_proof_credential_mismatch', index, credentialIndex);
        } else {
          proofCounts.sourceAlignedProofs += 1;
          if (!binding || binding.owner !== proof.owner ||
              binding.source_sha256 !== expectedSourceSha256 ||
              binding.legacy_owner_hash !== historicalHash) {
            proofIssue('verified_proof_binding_owner_mismatch', index, credentialIndex);
          } else {
            proofCounts.ownerAlignedProofs += 1;
            if (binding.proof_sha256 === proof.proof_sha256) bindingAnchorMatched = true;
          }
        }
      }
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
    if (sourceCredentials.size > 0) {
      if (bindingAnchorMatched) proofCounts.anchoredStorageKeys += 1;
      else proofIssue('verified_proof_binding_anchor_missing', index);
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
  for (const proof of target.legacyCutoverVerifiedProofs) {
    if (proof.source_sha256 === expectedSourceSha256 && !sourceCredentialIds.has(proof.legacy_credential_id)) {
      proofIssue('verified_proof_not_in_source');
    }
  }
  return Object.freeze({ schemaVersion: 1, mode: 'read-only', migrationPermitted: false,
    publicRepresentationExact: counts.discrepancies === 0,
    sourceSha256: expectedSourceSha256, comparedTargetRowsSha256,
    sourceSchemaVersion: source.needsMigration ? 3 : 4,
    ownerSchemaVersion: target.schemaVersion, counts: Object.freeze(counts),
    diagnostics: Object.freeze(diagnostics), omittedDiagnostics,
    proofMetadata: Object.freeze({
      sourceAndBindingMetadataComplete: target.schemaVersion === 8 && counts.sourceCredentials > 0 &&
        proofCounts.ownerAlignedProofs === counts.sourceCredentials &&
        proofCounts.anchoredStorageKeys === counts.sourceStorageKeys - counts.sourceTombstones &&
        proofCounts.discrepancies === 0,
      counts: Object.freeze(proofCounts),
      diagnostics: Object.freeze(proofDiagnostics), omittedDiagnostics: omittedProofDiagnostics }),
    blockers: Object.freeze([
      'fresh_legacy_credential_assertion_and_random_owner_proof_unverified',
      'legacy_json_writer_drain_unverified',
      'single_writer_cutover_manifest_and_startup_gate_missing',
      'exact_signed_upgrade_and_replacement_device_acceptance_missing',
    ]) });
}
