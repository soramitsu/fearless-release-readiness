import { isAbsolute } from 'node:path';
import { readCredentialStoreSnapshot } from '../../passkey-backup-challenge-service/src/store.js';
import { authorizationSubjectHash } from '../../passkey-backup-challenge-service/src/authorization.js';
import { readOwnerCredentialSnapshot } from './store.js';

const MAX_DIAGNOSTICS = 512;

/**
 * Read-only, fail-closed migration inventory. It never links an owner, imports a
 * credential, rewrites JSON, or opens SQLite for writing. Even an exact match
 * cannot authorize migration: v3 has representation capacity but no verified
 * proof or import path, and the live JSON writer still runs independently.
 */
export function reconcileLegacyCredentialStores({ legacyPath, ownerPath }) {
  if (!isAbsolute(legacyPath) || !isAbsolute(ownerPath)) throw new Error('absolute_store_paths_required');
  const legacy = readCredentialStoreSnapshot(legacyPath);
  const owner = readOwnerCredentialSnapshot(ownerPath);
  const byHash = new Map();
  for (const record of owner.owners) {
    const key = authorizationSubjectHash(record.subject);
    if (byHash.has(key)) throw new Error('owner_subject_hash_collision');
    byHash.set(key, record);
  }
  const ownerCredentials = new Map(owner.credentials.map((record) => [record.id, record]));
  const storageBindings = new Map(owner.storageBindings.map((record) => [record.storage_key, record]));
  const legacyMetadata = new Map(owner.legacyCredentialMetadata.map((record) => [record.credential_id, record]));
  const legacyCredentialIds = new Set();
  const counts = {
    legacyStorageKeys: legacy.credentialsByStorageKey.size,
    legacyCredentials: 0,
    ownerSubjects: owner.owners.length,
    ownerCredentials: owner.credentials.length,
    matchingPublicCredentialRows: 0,
    unmappedStorageKeys: 0,
    unmappedCredentials: 0,
    conflictingCredentials: 0,
    ownerOnlyCredentials: 0,
  };
  const diagnostics = [];
  let omittedDiagnostics = 0;
  const add = (kind, storageEntryIndex, credentialEntryIndex) => {
    if (diagnostics.length < MAX_DIAGNOSTICS) diagnostics.push(Object.freeze({ kind,
      storageEntryIndex,
      ...(credentialEntryIndex === undefined ? {} : { credentialEntryIndex }),
    }));
    else omittedDiagnostics += 1;
  };
  let storageEntryIndex = 0;
  for (const [storageKey, credentials] of legacy.credentialsByStorageKey) {
    const currentStorageIndex = storageEntryIndex++;
    const subjectHash = legacy.ownersByStorageKey.get(storageKey);
    const mapped = byHash.get(subjectHash);
    if (!mapped) {
      counts.unmappedStorageKeys += 1;
      add('owner_unmapped', currentStorageIndex);
    }
    // Empty maps are durable tombstones. A v3 row can represent one but this
    // inventory cannot validate a proof commitment or authorize the link.
    const binding = storageBindings.get(storageKey);
    add(!binding ? 'storage_binding_unrepresented' :
      binding.owner !== mapped?.subject || binding.legacy_owner_hash !== subjectHash
        ? 'storage_binding_conflict' : 'storage_binding_unverified', currentStorageIndex);
    let credentialEntryIndex = 0;
    for (const [id, record] of credentials) {
      const currentCredentialIndex = credentialEntryIndex++;
      counts.legacyCredentials += 1;
      legacyCredentialIds.add(id);
      const linked = ownerCredentials.get(id);
      if (!linked) {
        counts.unmappedCredentials += 1;
        add('credential_unmapped', currentStorageIndex, currentCredentialIndex);
        continue;
      }
      if (!mapped || linked.owner !== mapped.subject || linked.revoked !== 0 ||
          linked.public_key !== record.publicKey || linked.user_handle !== record.userId ||
          linked.counter !== record.counter || linked.device_type !== record.deviceType ||
          linked.backed_up !== Number(record.backedUp)) {
        counts.conflictingCredentials += 1;
        add('credential_state_conflict', currentStorageIndex, currentCredentialIndex);
        continue;
      }
      counts.matchingPublicCredentialRows += 1;
      const metadata = legacyMetadata.get(id);
      add(!metadata ? 'credential_metadata_unrepresented' :
        metadata.storage_key !== storageKey || metadata.aaguid !== record.aaguid ||
        metadata.registration_platform !== record.registrationPlatform ||
        metadata.transports_json !== (record.transports === undefined ? null : JSON.stringify(record.transports))
          ? 'credential_metadata_conflict' : 'credential_metadata_unverified',
      currentStorageIndex, currentCredentialIndex);
    }
  }
  for (const id of ownerCredentials.keys()) {
    if (!legacyCredentialIds.has(id)) counts.ownerOnlyCredentials += 1;
  }
  return Object.freeze({
    schemaVersion: 1,
    mode: 'read-only',
    migrationPermitted: false,
    legacySchemaVersion: legacy.needsMigration ? 3 : 4,
    ownerSchemaVersion: owner.schemaVersion,
    counts: Object.freeze(counts),
    diagnostics: Object.freeze(diagnostics),
    omittedDiagnostics,
    blockers: Object.freeze([
      'challenge_http_still_writes_json',
      'storage_key_owner_binding_unverified',
      'historical_metadata_import_unverified',
      'verified_legacy_owner_migration_missing',
    ]),
  });
}
