import { createHash } from 'node:crypto';
import { basename, isAbsolute, resolve } from 'node:path';
import { readSealedSource, verifySealedLegacyCutover } from './legacy-cutover-verifier.js';
import { AuthorityStore, legacyImportBindingSetSha256,
  legacyImportProofSetSha256, legacyImportReceiptCommitment,
  readOwnerCredentialSnapshot } from './store.js';
import { deny } from './validation.js';

const SHA256_HEX = /^[0-9a-f]{64}$/;

function checkedInput({ legacySnapshotPath, ownerPath, expectedSourceSha256 }) {
  if (typeof legacySnapshotPath !== 'string' || !isAbsolute(legacySnapshotPath) ||
      typeof ownerPath !== 'string' || !isAbsolute(ownerPath) ||
      resolve(legacySnapshotPath) === resolve(ownerPath) ||
      typeof expectedSourceSha256 !== 'string' || !SHA256_HEX.test(expectedSourceSha256) ||
      basename(legacySnapshotPath) !== `legacy-${expectedSourceSha256}.json`) {
    deny('legacy_import_invalid_request');
  }
}

function sha256(domain, value) {
  return createHash('sha256').update(`${domain}\0${JSON.stringify(value)}`).digest('hex');
}

function publicRowsSha256(target) {
  return sha256('FP_LEGACY_PUBLIC_STATE_V1', [target.owners, target.credentials,
    target.storageBindings, target.legacyCredentialMetadata, target.credentialScopes]);
}

function preflightSha256(sourceSha256, target) {
  return sha256('FP_LEGACY_IMPORT_PREFLIGHT_V1', [sourceSha256, target.schemaVersion,
    target.owners, target.credentials, target.storageBindings,
    target.legacyCredentialMetadata, target.credentialScopes,
    target.legacyCutoverChallenges, target.legacyCutoverVerifiedProofs,
    target.legacyImportReceipts]);
}

function ownerRows(tx) {
  return {
    schemaVersion: tx.query('PRAGMA user_version').user_version,
    owners: tx.all('SELECT subject,user_handle,generation FROM owners ORDER BY subject'),
    credentials: tx.all(`SELECT id,owner,public_key,user_handle,counter,device_type,
      backed_up,revoked FROM credentials ORDER BY id`),
    storageBindings: tx.all(`SELECT storage_key,owner,legacy_owner_hash,source_sha256,
      proof_sha256,created FROM storage_bindings ORDER BY storage_key`),
    legacyCredentialMetadata: tx.all(`SELECT credential_id,storage_key,aaguid,
      transports_json,registration_platform FROM legacy_credential_metadata ORDER BY credential_id`),
    credentialScopes: tx.all(`SELECT credential_id,owner,scope,storage_key
      FROM credential_scopes ORDER BY credential_id`),
    legacyCutoverChallenges: tx.all('SELECT * FROM legacy_cutover_challenges ORDER BY id'),
    legacyCutoverVerifiedProofs: tx.all('SELECT * FROM legacy_cutover_verified_proofs ORDER BY challenge_id'),
    legacyImportReceipts: tx.all('SELECT * FROM legacy_import_receipts ORDER BY id'),
  };
}

function cohortPlan(source, target, sourceSha256) {
  if (target.schemaVersion !== 9 || target.legacyImportReceipts.length !== 0 ||
      target.storageBindings.length !== 0 || target.legacyCredentialMetadata.length !== 0 ||
      target.credentialScopes.some((row) => row.scope === 'storage')) {
    deny('legacy_import_target_conflict');
  }
  const owners = new Map(target.owners.map((row) => [row.subject, row]));
  const credentials = new Map(target.credentials.map((row) => [row.id, row]));
  const scopes = new Map(target.credentialScopes.map((row) => [row.credential_id, row]));
  const challenges = new Map(target.legacyCutoverChallenges.map((row) => [row.id, row]));
  const proofs = new Map(target.legacyCutoverVerifiedProofs.map((row) => [row.legacy_credential_id, row]));
  const historicalOwnerToRandom = new Map();
  const randomOwnerToHistorical = new Map();
  const sourceCredentialIds = new Set();
  const bindings = [];
  const imports = [];
  const proofRows = [];
  if (source.credentialsByStorageKey.size < 1 ||
      source.credentialsByStorageKey.size > 128) deny('legacy_import_cohort_unsupported');
  for (const [storageKey, sourceCredentials] of source.credentialsByStorageKey) {
    // A zero-credential historical tombstone has no WebAuthn key with which
    // to prove its owner. It must remain on the legacy path until a separate
    // possession ceremony has been reviewed.
    if (sourceCredentials.size === 0) deny('legacy_import_tombstone_unproven');
    const historicalHash = source.ownersByStorageKey.get(storageKey);
    let selectedOwner;
    let selectedProof;
    const ordered = [...sourceCredentials.values()].sort((left, right) =>
      left.id < right.id ? -1 : left.id > right.id ? 1 : 0);
    for (const credential of ordered) {
      sourceCredentialIds.add(credential.id);
      if (credentials.has(credential.id)) deny('legacy_import_credential_collision');
      const proof = proofs.get(credential.id);
      const challenge = proof && challenges.get(proof.challenge_id);
      const owner = challenge && owners.get(challenge.owner);
      const ownerCredential = challenge && credentials.get(challenge.owner_credential_id);
      const ownerScope = ownerCredential && scopes.get(ownerCredential.id);
      if (!proof || !challenge || !owner || !ownerCredential ||
          proof.proof_version !== 2 || challenge.state !== 2 ||
          proof.source_sha256 !== sourceSha256 || challenge.source_sha256 !== sourceSha256 ||
          challenge.snapshot_name !== `legacy-${sourceSha256}.json` ||
          challenge.storage_key !== storageKey || challenge.legacy_owner_hash !== historicalHash ||
          challenge.legacy_credential_id !== credential.id ||
          challenge.legacy_public_key_sha256 !== createHash('sha256').update(
            Buffer.from(credential.publicKey, 'base64url')).digest('hex') ||
          challenge.legacy_counter !== credential.counter ||
          challenge.legacy_user_handle !== credential.userId ||
          challenge.legacy_scope !== 'storage' || challenge.rp_id !== 'fearlesswallet.io' ||
          proof.owner !== challenge.owner || proof.owner_credential_id !== ownerCredential.id ||
          proof.legacy_credential_id !== credential.id ||
          proof.legacy_device_type !== credential.deviceType ||
          proof.legacy_backed_up !== Number(credential.backedUp) ||
          (credential.counter !== 0 && proof.legacy_new_counter <= credential.counter) ||
          owner.generation !== challenge.generation || ownerCredential.owner !== owner.subject ||
          ownerCredential.revoked !== 0 || ownerCredential.counter < proof.owner_new_counter ||
          ownerCredential.public_key !== proof.owner_public_key ||
          ownerScope?.scope !== 'owner' || ownerScope.owner !== owner.subject) {
        deny('legacy_import_proof_unverified');
      }
      if (selectedOwner && selectedOwner !== owner.subject) deny('legacy_import_owner_conflict');
      selectedOwner = owner.subject;
      selectedProof ??= proof;
      proofRows.push([credential.id, proof.proof_sha256]);
      imports.push({ storageKey, owner: owner.subject, credential });
    }
    if (historicalOwnerToRandom.has(historicalHash) &&
        historicalOwnerToRandom.get(historicalHash) !== selectedOwner) deny('legacy_import_owner_conflict');
    if (randomOwnerToHistorical.has(selectedOwner) &&
        randomOwnerToHistorical.get(selectedOwner) !== historicalHash) deny('legacy_import_owner_conflict');
    historicalOwnerToRandom.set(historicalHash, selectedOwner);
    randomOwnerToHistorical.set(selectedOwner, historicalHash);
    bindings.push({ storageKey, owner: selectedOwner, historicalHash,
      sourceSha256, proofSha256: selectedProof.proof_sha256 });
  }
  if (imports.length < 1 || imports.length > 128 ||
      proofs.size !== imports.length ||
      target.legacyCutoverVerifiedProofs.some((row) =>
        row.source_sha256 !== sourceSha256 || !sourceCredentialIds.has(row.legacy_credential_id))) {
    deny('legacy_import_proof_unverified');
  }
  proofRows.sort((left, right) => left[0] < right[0] ? -1 : left[0] > right[0] ? 1 : 0);
  bindings.sort((left, right) => left.storageKey < right.storageKey ? -1
    : left.storageKey > right.storageKey ? 1 : 0);
  const bindingRows = bindings.map((row) => [row.storageKey, row.owner,
    row.historicalHash, row.sourceSha256, row.proofSha256]);
  return { bindings, imports, proofSetSha256: legacyImportProofSetSha256(proofRows),
    bindingSetSha256: legacyImportBindingSetSha256(bindingRows) };
}

/** Read-only, redacted eligibility for an offline schema-v9 transaction. */
export function inspectSealedLegacyImport({ legacySnapshotPath, ownerPath,
  expectedSourceSha256 }) {
  checkedInput({ legacySnapshotPath, ownerPath, expectedSourceSha256 });
  const source = readSealedSource(legacySnapshotPath, expectedSourceSha256);
  const target = readOwnerCredentialSnapshot(ownerPath);
  const candidateSha256 = preflightSha256(expectedSourceSha256, target);
  try {
    const plan = cohortPlan(source, target, expectedSourceSha256);
    return Object.freeze({ schemaVersion: 1, mode: 'offline-preflight',
      sourceSha256: expectedSourceSha256, candidateSha256,
      sourceSchemaVersion: source.needsMigration ? 3 : 4,
      storageKeys: plan.bindings.length, credentials: plan.imports.length,
      offlineImportEligible: true, productionAdmission: false });
  } catch (error) {
    if (!error.code?.startsWith('legacy_import_')) throw error;
    return Object.freeze({ schemaVersion: 1, mode: 'offline-preflight',
      sourceSha256: expectedSourceSha256, candidateSha256,
      sourceSchemaVersion: source.needsMigration ? 3 : 4,
      storageKeys: source.credentialsByStorageKey.size,
      credentials: [...source.credentialsByStorageKey.values()].reduce((n, rows) => n + rows.size, 0),
      offlineImportEligible: false, blocker: error.code, productionAdmission: false });
  }
}

/**
 * Operator-only candidate: one proven nonempty sealed cohort, one SQLite
 * BEGIN IMMEDIATE transaction, and an immutable receipt. This never admits
 * production startup or retires the JSON writer. The caller must independently
 * establish the sealed source, reviewed preflight digest and writer drain.
 */
export function importSealedLegacyCredentialCohort({ legacySnapshotPath, ownerPath,
  expectedSourceSha256, expectedCandidateSha256,
  now = Date.now, monotonic, fault } = {}) {
  checkedInput({ legacySnapshotPath, ownerPath, expectedSourceSha256 });
  if (typeof expectedCandidateSha256 !== 'string' ||
      !SHA256_HEX.test(expectedCandidateSha256)) deny('legacy_import_invalid_request');
  const initial = inspectSealedLegacyImport({ legacySnapshotPath, ownerPath, expectedSourceSha256 });
  if (!initial.offlineImportEligible) deny(initial.blocker);
  if (initial.candidateSha256 !== expectedCandidateSha256) deny('legacy_import_state_changed');
  const store = new AuthorityStore({ path: ownerPath, now,
    ...(monotonic ? { monotonic } : {}), ...(fault ? { fault } : {}) });
  let receipt;
  try {
    receipt = store.transaction((tx) => {
      const source = readSealedSource(legacySnapshotPath, expectedSourceSha256);
      const target = ownerRows(tx);
      if (preflightSha256(expectedSourceSha256, target) !== expectedCandidateSha256) {
        deny('legacy_import_state_changed');
      }
      const plan = cohortPlan(source, target, expectedSourceSha256);
      for (const binding of plan.bindings) {
        tx.run('INSERT INTO storage_bindings VALUES(?,?,?,?,?,?)', binding.storageKey,
          binding.owner, binding.historicalHash, binding.sourceSha256,
          binding.proofSha256, tx.now);
      }
      for (const item of plan.imports) {
        const credential = item.credential;
        const proof = tx.query(`SELECT legacy_new_counter FROM legacy_cutover_verified_proofs
          WHERE legacy_credential_id=? AND source_sha256=?`, credential.id, expectedSourceSha256);
        if (!proof) deny('legacy_import_proof_unverified');
        tx.run('INSERT INTO credentials VALUES(?,?,?,?,?,?,?,0)', credential.id,
          item.owner, credential.publicKey, credential.userId, proof.legacy_new_counter,
          credential.deviceType, Number(credential.backedUp));
        tx.run('INSERT INTO legacy_credential_metadata VALUES(?,?,?,?,?)', credential.id,
          item.storageKey, credential.aaguid,
          credential.transports === undefined ? null : JSON.stringify(credential.transports),
          credential.registrationPlatform);
      }
      const imported = ownerRows(tx);
      const row = { source_sha256: expectedSourceSha256,
        source_schema_version: source.needsMigration ? 3 : 4,
        storage_keys: plan.bindings.length, credentials: plan.imports.length,
        proof_set_sha256: plan.proofSetSha256,
        binding_set_sha256: plan.bindingSetSha256,
        public_rows_sha256: publicRowsSha256(imported), imported_at: tx.now };
      const receiptSha256 = legacyImportReceiptCommitment(row);
      tx.run(`INSERT INTO legacy_import_receipts VALUES(1,?,?,?,?,?,?,?,?,?)`,
        row.source_sha256, row.source_schema_version, row.storage_keys,
        row.credentials, row.proof_set_sha256, row.binding_set_sha256,
        row.public_rows_sha256, row.imported_at, receiptSha256);
      return Object.freeze({ schemaVersion: 1, mode: 'offline-import',
        sourceSha256: expectedSourceSha256, receiptSha256,
        storageKeys: row.storage_keys, credentials: row.credentials,
        durableReceiptCommitted: true, productionAdmission: false });
    });
  } finally { store.close(); }
  const check = verifySealedLegacyCutover({ legacySnapshotPath, ownerPath, expectedSourceSha256 });
  if (!check.publicRepresentationExact || !check.proofMetadata.sourceAndBindingMetadataComplete ||
      readOwnerCredentialSnapshot(ownerPath).legacyImportReceipts[0]?.receipt_sha256 !==
        receipt.receiptSha256) deny('legacy_import_post_commit_review_required');
  return receipt;
}
