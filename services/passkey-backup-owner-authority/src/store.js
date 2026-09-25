import { DatabaseSync } from 'node:sqlite';
import { createHash } from 'node:crypto';
import { constants, closeSync, fstatSync, fsyncSync, lstatSync, openSync } from 'node:fs';
import { dirname, isAbsolute } from 'node:path';
import { AuthorityError, base64, deny, hash, opaque } from './validation.js';

const SCHEMA_VERSION = 9;
const SHA256_HEX = /^[a-f0-9]{64}$/;

export function legacyCutoverAssertionChallenge(row, role) {
  if (!['LEGACY', 'OWNER'].includes(role)) deny('invalid_request');
  const fields = [row.version, row.source_sha256, row.snapshot_name, row.storage_key,
    row.legacy_owner_hash, row.legacy_credential_id, row.legacy_public_key_sha256,
    row.legacy_counter, row.legacy_user_handle, row.legacy_scope,
    row.owner, row.generation, row.session, row.owner_credential_id,
    row.owner_credential_counter, row.rp_id, row.platform, row.nonce, row.expires];
  return hash(Buffer.from(`FP_LEGACY_CUTOVER_${role}_V1\0${JSON.stringify(fields)}`, 'utf8'));
}

// Public, domain-separated commitment. It is metadata for a future reviewed
// cutover, never a bearer token or authorization to import a credential.
export function legacyCutoverProofCommitment(proof) {
  const fields = [proof.challenge_id, proof.source_sha256, proof.owner,
    proof.legacy_credential_id, proof.owner_credential_id,
    proof.legacy_body_sha256, proof.owner_body_sha256,
    proof.legacy_challenge_sha256, proof.owner_challenge_sha256,
    proof.legacy_new_counter, proof.owner_new_counter,
    proof.legacy_device_type, proof.legacy_backed_up,
    proof.owner_device_type, proof.owner_backed_up, proof.verified_at];
  if (proof.proof_version === 2) {
    fields.push(proof.owner_public_key_sha256, proof.owner_public_key);
    return createHash('sha256').update(`FP_LEGACY_CUTOVER_VERIFIED_V2\0${JSON.stringify(fields)}`).digest('hex');
  }
  return createHash('sha256').update(`FP_LEGACY_CUTOVER_VERIFIED_V1\0${JSON.stringify(fields)}`).digest('hex');
}
export function legacyImportReceiptCommitment(receipt) {
  const fields = [receipt.source_sha256, receipt.source_schema_version,
    receipt.storage_keys, receipt.credentials, receipt.proof_set_sha256,
    receipt.binding_set_sha256, receipt.public_rows_sha256, receipt.imported_at];
  return createHash('sha256').update(`FP_LEGACY_IMPORT_RECEIPT_V1\0${JSON.stringify(fields)}`).digest('hex');
}
export function legacyImportProofSetSha256(rows) {
  return createHash('sha256').update(`FP_LEGACY_IMPORT_PROOFS_V1\0${JSON.stringify(rows)}`).digest('hex');
}
export function legacyImportBindingSetSha256(rows) {
  return createHash('sha256').update(`FP_LEGACY_IMPORT_BINDINGS_V1\0${JSON.stringify(rows)}`).digest('hex');
}
const BACKUP_HEAD_SCHEMA = `
CREATE TABLE backup_operations (
 operation_id TEXT PRIMARY KEY, owner TEXT NOT NULL REFERENCES owners(subject), request_hash TEXT NOT NULL,
 revision INTEGER NOT NULL CHECK(revision>0), generation_id TEXT NOT NULL UNIQUE,
 bundle_sha256 TEXT NOT NULL, key_epoch INTEGER NOT NULL CHECK(key_epoch>0),
 drive_file_id TEXT NOT NULL UNIQUE, account_binding TEXT NOT NULL,
 UNIQUE(owner,revision)
) STRICT;
CREATE INDEX backup_operations_owner ON backup_operations(owner);
CREATE TABLE backup_heads (
 owner TEXT PRIMARY KEY REFERENCES owners(subject), revision INTEGER NOT NULL CHECK(revision>0),
 operation_id TEXT NOT NULL REFERENCES backup_operations(operation_id)
) STRICT;
`;
// This adds capacity for a future proof-bound legacy cohort import. It does
// not import JSON, assign an owner, or expose a writer. Existing v2 credential
// rows and their per-credential user handles remain unchanged. A binding with
// zero credential metadata rows is the historical owner tombstone.
const LEGACY_COHORT_SCHEMA = `
CREATE TABLE storage_bindings (
 storage_key TEXT PRIMARY KEY CHECK(length(storage_key) BETWEEN 8 AND 128),
 owner TEXT NOT NULL REFERENCES owners(subject),
 legacy_owner_hash TEXT NOT NULL CHECK(length(legacy_owner_hash)=43),
 source_sha256 TEXT NOT NULL CHECK(length(source_sha256)=64),
 proof_sha256 TEXT NOT NULL UNIQUE CHECK(length(proof_sha256)=64),
 created INTEGER NOT NULL CHECK(created>=0)
) STRICT;
CREATE INDEX storage_bindings_owner ON storage_bindings(owner);
CREATE TABLE legacy_credential_metadata (
 credential_id TEXT PRIMARY KEY REFERENCES credentials(id) ON DELETE RESTRICT,
 storage_key TEXT NOT NULL REFERENCES storage_bindings(storage_key) ON DELETE RESTRICT,
 aaguid TEXT NOT NULL CHECK(length(aaguid)=36),
 transports_json TEXT CHECK(transports_json IS NULL OR length(transports_json)<=256),
 registration_platform TEXT NOT NULL CHECK(registration_platform IN ('android','ios'))
) STRICT;
CREATE INDEX legacy_credential_metadata_storage ON legacy_credential_metadata(storage_key);
CREATE TRIGGER storage_bindings_no_update BEFORE UPDATE ON storage_bindings
BEGIN SELECT RAISE(ABORT,'immutable storage binding'); END;
CREATE TRIGGER storage_bindings_no_delete BEFORE DELETE ON storage_bindings
BEGIN SELECT RAISE(ABORT,'immutable storage binding'); END;
CREATE TRIGGER legacy_credential_metadata_owner_insert BEFORE INSERT ON legacy_credential_metadata
BEGIN
 SELECT RAISE(ABORT,'legacy credential owner mismatch') WHERE NOT EXISTS (
  SELECT 1 FROM credentials c JOIN storage_bindings b ON b.storage_key=NEW.storage_key
  WHERE c.id=NEW.credential_id AND c.owner=b.owner
 );
END;
CREATE TRIGGER legacy_credential_metadata_no_update BEFORE UPDATE ON legacy_credential_metadata
BEGIN SELECT RAISE(ABORT,'immutable legacy credential metadata'); END;
CREATE TRIGGER legacy_credential_metadata_no_delete BEFORE DELETE ON legacy_credential_metadata
BEGIN SELECT RAISE(ABORT,'immutable legacy credential metadata'); END;
CREATE TRIGGER legacy_credential_identity_no_update
BEFORE UPDATE OF owner,public_key,user_handle ON credentials
WHEN EXISTS (SELECT 1 FROM legacy_credential_metadata WHERE credential_id=OLD.id)
BEGIN SELECT RAISE(ABORT,'immutable legacy credential identity'); END;
`;
const REQUIRED_LEGACY_TRIGGERS = [
  'storage_bindings_no_update', 'storage_bindings_no_delete',
  'legacy_credential_metadata_owner_insert', 'legacy_credential_metadata_no_update',
  'legacy_credential_metadata_no_delete', 'legacy_credential_identity_no_update',
];
// Every credential has exactly one explicit scope. The owner-wide scope is
// assigned on insertion; a proven legacy-key metadata insert narrows it to
// that immutable storage binding in the same writer transaction.
const CREDENTIAL_SCOPE_TABLE = `
CREATE TABLE credential_scopes (
 credential_id TEXT PRIMARY KEY REFERENCES credentials(id) ON DELETE RESTRICT,
 owner TEXT NOT NULL REFERENCES owners(subject),
 scope TEXT NOT NULL CHECK(scope IN ('owner','storage')),
 storage_key TEXT REFERENCES storage_bindings(storage_key) ON DELETE RESTRICT,
 CHECK((scope='owner' AND storage_key IS NULL) OR (scope='storage' AND storage_key IS NOT NULL))
) STRICT;
CREATE INDEX credential_scopes_storage ON credential_scopes(storage_key);
`;
const CREDENTIAL_SCOPE_TRIGGERS = `
CREATE TRIGGER credential_identity_no_update BEFORE UPDATE OF id,owner ON credentials
BEGIN SELECT RAISE(ABORT,'immutable credential identity'); END;
CREATE TRIGGER credential_scope_insert AFTER INSERT ON credentials
BEGIN INSERT INTO credential_scopes VALUES(NEW.id,NEW.owner,'owner',NULL); END;
CREATE TRIGGER credential_scope_validate_insert BEFORE INSERT ON credential_scopes
BEGIN
 SELECT RAISE(ABORT,'credential scope owner mismatch') WHERE NOT EXISTS (
  SELECT 1 FROM credentials c WHERE c.id=NEW.credential_id AND c.owner=NEW.owner
 );
 SELECT RAISE(ABORT,'credential scope storage owner mismatch') WHERE NEW.scope='storage' AND NOT EXISTS (
  SELECT 1 FROM storage_bindings b WHERE b.storage_key=NEW.storage_key AND b.owner=NEW.owner
 );
END;
CREATE TRIGGER credential_scope_validate_update BEFORE UPDATE ON credential_scopes
BEGIN
 SELECT RAISE(ABORT,'immutable credential scope') WHERE OLD.scope!='owner' OR NEW.scope!='storage' OR
  OLD.credential_id!=NEW.credential_id OR OLD.owner!=NEW.owner OR NOT EXISTS (
   SELECT 1 FROM legacy_credential_metadata m JOIN storage_bindings b ON b.storage_key=m.storage_key
   WHERE m.credential_id=OLD.credential_id AND m.storage_key=NEW.storage_key AND b.owner=OLD.owner
  );
END;
CREATE TRIGGER credential_scope_no_delete BEFORE DELETE ON credential_scopes
BEGIN SELECT RAISE(ABORT,'immutable credential scope'); END;
CREATE TRIGGER legacy_credential_scope_insert AFTER INSERT ON legacy_credential_metadata
BEGIN
 UPDATE credential_scopes SET scope='storage',storage_key=NEW.storage_key
 WHERE credential_id=NEW.credential_id AND scope='owner';
 SELECT RAISE(ABORT,'credential scope missing') WHERE changes()!=1;
END;
`;
const REQUIRED_SCOPE_TRIGGERS = [
  'credential_identity_no_update', 'credential_scope_insert', 'credential_scope_validate_insert',
  'credential_scope_validate_update', 'credential_scope_no_delete',
  'legacy_credential_scope_insert',
];
// A claim is durable before WebAuthn verification, and completion can only
// consume the exact claimed response. No client-supplied owner or key is stored.
const PENDING_CHALLENGE_SCHEMA = `
CREATE TABLE pending_challenges (
 id TEXT PRIMARY KEY, version INTEGER NOT NULL CHECK(version=1),
 kind TEXT NOT NULL CHECK(kind IN ('registration','assertion')),
 storage_key TEXT NOT NULL REFERENCES storage_bindings(storage_key),
 owner TEXT NOT NULL REFERENCES owners(subject), generation INTEGER NOT NULL CHECK(generation>=0),
 session TEXT NOT NULL REFERENCES sessions(digest) ON DELETE CASCADE,
 platform TEXT NOT NULL CHECK(platform IN ('android','ios')),
 nonce TEXT NOT NULL UNIQUE, expires INTEGER NOT NULL CHECK(expires>=0),
 user_handle TEXT NOT NULL, directed_credential_id TEXT,
 claimed INTEGER NOT NULL CHECK(claimed IN (0,1)),
 body_hash TEXT, credential_id TEXT,
 CHECK((claimed=0 AND body_hash IS NULL AND credential_id IS NULL) OR
       (claimed=1 AND body_hash IS NOT NULL AND credential_id IS NOT NULL)),
 CHECK(kind='assertion' OR directed_credential_id IS NULL)
) STRICT;
CREATE INDEX pending_challenges_expiry ON pending_challenges(expires);
CREATE INDEX pending_challenges_owner ON pending_challenges(owner);
CREATE TRIGGER pending_challenge_claim_once BEFORE UPDATE ON pending_challenges
BEGIN
 SELECT RAISE(ABORT,'immutable pending challenge') WHERE OLD.claimed!=0 OR
  NEW.claimed!=1 OR NEW.id!=OLD.id OR NEW.version!=OLD.version OR NEW.kind!=OLD.kind OR
  NEW.storage_key!=OLD.storage_key OR NEW.owner!=OLD.owner OR
  NEW.generation!=OLD.generation OR NEW.session!=OLD.session OR
  NEW.platform!=OLD.platform OR NEW.nonce!=OLD.nonce OR
  NEW.expires!=OLD.expires OR NEW.user_handle!=OLD.user_handle OR
  NEW.directed_credential_id IS NOT OLD.directed_credential_id;
END;
`;
// Any actual credential revocation fences the next accepted backup at a new
// key epoch. A persisted floor also survives a later rotation, so another
// revocation raises it again from the then-current head. A v5 migration must
// conservatively fence owners with historical revocations: their order relative
// to the existing backup head cannot be reconstructed from v5 metadata.
const KEY_ROTATION_SCHEMA = `
CREATE TABLE key_rotation_floors (
 owner TEXT PRIMARY KEY REFERENCES owners(subject),
 minimum_epoch INTEGER NOT NULL CHECK(minimum_epoch>0)
) STRICT;
CREATE TRIGGER key_rotation_floor_no_decrease BEFORE UPDATE ON key_rotation_floors
WHEN NEW.owner!=OLD.owner OR NEW.minimum_epoch<OLD.minimum_epoch
BEGIN SELECT RAISE(ABORT,'rotation floor cannot decrease'); END;
CREATE TRIGGER key_rotation_floor_no_delete BEFORE DELETE ON key_rotation_floors
BEGIN SELECT RAISE(ABORT,'rotation floor cannot be deleted'); END;
CREATE TRIGGER credential_revoke_rotation AFTER UPDATE OF revoked ON credentials
WHEN OLD.revoked=0 AND NEW.revoked=1
BEGIN
 INSERT INTO key_rotation_floors(owner,minimum_epoch)
 VALUES(NEW.owner,COALESCE((
  SELECT o.key_epoch+1 FROM backup_heads h
  JOIN backup_operations o ON o.operation_id=h.operation_id
  WHERE h.owner=NEW.owner
 ),1))
 ON CONFLICT(owner) DO UPDATE SET minimum_epoch=MAX(minimum_epoch,excluded.minimum_epoch);
END;
`;
// Preparation only: a claimed pair of public WebAuthn responses can be burned,
// but no row in this table constitutes verified ownership or permits import.
const LEGACY_CUTOVER_CHALLENGE_SCHEMA = `
CREATE TABLE legacy_cutover_challenges (
 id TEXT PRIMARY KEY, version INTEGER NOT NULL CHECK(version=1),
 source_sha256 TEXT NOT NULL CHECK(length(source_sha256)=64),
 snapshot_name TEXT NOT NULL CHECK(snapshot_name='legacy-'||source_sha256||'.json'),
 storage_key TEXT NOT NULL CHECK(length(storage_key) BETWEEN 8 AND 128),
 legacy_owner_hash TEXT NOT NULL CHECK(length(legacy_owner_hash)=43),
 legacy_credential_id TEXT NOT NULL UNIQUE, legacy_public_key_sha256 TEXT NOT NULL CHECK(length(legacy_public_key_sha256)=64),
 legacy_counter INTEGER NOT NULL CHECK(legacy_counter BETWEEN 0 AND 4294967295),
 legacy_user_handle TEXT NOT NULL, legacy_scope TEXT NOT NULL CHECK(legacy_scope='storage'),
 owner TEXT NOT NULL REFERENCES owners(subject), generation INTEGER NOT NULL CHECK(generation>=0),
 -- Preserve the bound digest as a replay tombstone even after session revocation.
 session TEXT NOT NULL CHECK(length(session)=43),
 owner_credential_id TEXT NOT NULL REFERENCES credentials(id),
 owner_credential_counter INTEGER NOT NULL CHECK(owner_credential_counter BETWEEN 0 AND 4294967295),
 rp_id TEXT NOT NULL CHECK(rp_id='fearlesswallet.io'),
 platform TEXT NOT NULL CHECK(platform IN ('android','ios')),
 nonce TEXT NOT NULL UNIQUE, expires INTEGER NOT NULL CHECK(expires>=0),
 state INTEGER NOT NULL CHECK(state IN (0,1,2)),
 legacy_body_sha256 TEXT, owner_body_sha256 TEXT,
 CHECK((state=0 AND legacy_body_sha256 IS NULL AND owner_body_sha256 IS NULL) OR
       (state IN (1,2) AND legacy_body_sha256 IS NOT NULL AND owner_body_sha256 IS NOT NULL AND
        length(legacy_body_sha256)=64 AND length(owner_body_sha256)=64))
) STRICT;
CREATE INDEX legacy_cutover_challenges_expiry ON legacy_cutover_challenges(expires);
CREATE INDEX legacy_cutover_challenges_owner ON legacy_cutover_challenges(owner);
CREATE TRIGGER legacy_cutover_challenge_transition BEFORE UPDATE ON legacy_cutover_challenges
BEGIN
 SELECT RAISE(ABORT,'immutable legacy cutover challenge') WHERE
  NEW.id IS NOT OLD.id OR NEW.version IS NOT OLD.version OR
  NEW.source_sha256 IS NOT OLD.source_sha256 OR NEW.snapshot_name IS NOT OLD.snapshot_name OR
  NEW.storage_key IS NOT OLD.storage_key OR NEW.legacy_owner_hash IS NOT OLD.legacy_owner_hash OR
  NEW.legacy_credential_id IS NOT OLD.legacy_credential_id OR
  NEW.legacy_public_key_sha256 IS NOT OLD.legacy_public_key_sha256 OR
  NEW.legacy_counter IS NOT OLD.legacy_counter OR NEW.legacy_user_handle IS NOT OLD.legacy_user_handle OR
  NEW.legacy_scope IS NOT OLD.legacy_scope OR NEW.owner IS NOT OLD.owner OR
  NEW.generation IS NOT OLD.generation OR NEW.session IS NOT OLD.session OR
  NEW.owner_credential_id IS NOT OLD.owner_credential_id OR
  NEW.owner_credential_counter IS NOT OLD.owner_credential_counter OR
  NEW.rp_id IS NOT OLD.rp_id OR NEW.platform IS NOT OLD.platform OR
  NEW.nonce IS NOT OLD.nonce OR NEW.expires IS NOT OLD.expires OR
  NOT ((OLD.state=0 AND NEW.state=1 AND NEW.legacy_body_sha256 IS NOT NULL AND
        NEW.owner_body_sha256 IS NOT NULL) OR
       (OLD.state=1 AND NEW.state=2 AND
        NEW.legacy_body_sha256 IS OLD.legacy_body_sha256 AND
        NEW.owner_body_sha256 IS OLD.owner_body_sha256));
END;
`;
// A v7 state-2 row has no corresponding row here and is always unverified.
// Verified metadata is retained beyond challenge expiry for reconciliation,
// but no caller accepts this row as a live authorization or migration grant.
const LEGACY_CUTOVER_VERIFIED_PROOF_SCHEMA = `
CREATE TABLE legacy_cutover_verified_proofs (
 challenge_id TEXT PRIMARY KEY REFERENCES legacy_cutover_challenges(id) ON DELETE RESTRICT,
 proof_sha256 TEXT NOT NULL UNIQUE CHECK(length(proof_sha256)=64),
 source_sha256 TEXT NOT NULL CHECK(length(source_sha256)=64),
 owner TEXT NOT NULL REFERENCES owners(subject),
 legacy_credential_id TEXT NOT NULL UNIQUE,
 owner_credential_id TEXT NOT NULL REFERENCES credentials(id),
 legacy_body_sha256 TEXT NOT NULL CHECK(length(legacy_body_sha256)=64),
 owner_body_sha256 TEXT NOT NULL CHECK(length(owner_body_sha256)=64),
 legacy_challenge_sha256 TEXT NOT NULL CHECK(length(legacy_challenge_sha256)=64),
 owner_challenge_sha256 TEXT NOT NULL CHECK(length(owner_challenge_sha256)=64),
 legacy_new_counter INTEGER NOT NULL CHECK(legacy_new_counter BETWEEN 0 AND 4294967295),
 owner_new_counter INTEGER NOT NULL CHECK(owner_new_counter BETWEEN 0 AND 4294967295),
 legacy_device_type TEXT NOT NULL CHECK(legacy_device_type IN ('singleDevice','multiDevice')),
 legacy_backed_up INTEGER NOT NULL CHECK(legacy_backed_up IN (0,1)),
 owner_device_type TEXT NOT NULL CHECK(owner_device_type IN ('singleDevice','multiDevice')),
 owner_backed_up INTEGER NOT NULL CHECK(owner_backed_up IN (0,1)),
 verified_at INTEGER NOT NULL CHECK(verified_at>=0),
 proof_version INTEGER NOT NULL DEFAULT 1 CHECK(proof_version IN (1,2)),
 owner_public_key_sha256 TEXT CHECK(owner_public_key_sha256 IS NULL OR length(owner_public_key_sha256)=64),
 owner_public_key TEXT,
 CHECK((proof_version=1 AND owner_public_key_sha256 IS NULL AND owner_public_key IS NULL) OR
       (proof_version=2 AND owner_public_key_sha256 IS NOT NULL AND owner_public_key IS NOT NULL)),
 CHECK(legacy_device_type='multiDevice' OR legacy_backed_up=0),
 CHECK(owner_device_type='multiDevice' OR owner_backed_up=0)
) STRICT;
CREATE TRIGGER legacy_cutover_verified_proof_insert BEFORE INSERT ON legacy_cutover_verified_proofs
BEGIN
 SELECT RAISE(ABORT,'invalid legacy cutover proof') WHERE NOT EXISTS (
  SELECT 1 FROM legacy_cutover_challenges c JOIN credentials k ON k.id=c.owner_credential_id
  WHERE c.id=NEW.challenge_id AND c.state=1 AND c.expires>NEW.verified_at
   AND c.source_sha256=NEW.source_sha256 AND c.owner=NEW.owner
   AND c.legacy_credential_id=NEW.legacy_credential_id
   AND c.owner_credential_id=NEW.owner_credential_id
   AND c.legacy_body_sha256=NEW.legacy_body_sha256
   AND c.owner_body_sha256=NEW.owner_body_sha256
   AND (c.legacy_counter=0 AND NEW.legacy_new_counter=0 OR
        NEW.legacy_new_counter>c.legacy_counter)
   AND (c.owner_credential_counter=0 AND NEW.owner_new_counter=0 OR
        NEW.owner_new_counter>c.owner_credential_counter)
   AND k.owner=c.owner AND k.revoked=0 AND k.counter=NEW.owner_new_counter
   AND k.device_type=NEW.owner_device_type AND k.backed_up=NEW.owner_backed_up
 );
END;
CREATE TRIGGER legacy_cutover_verified_proof_no_update BEFORE UPDATE ON legacy_cutover_verified_proofs
BEGIN SELECT RAISE(ABORT,'immutable legacy cutover proof'); END;
CREATE TRIGGER legacy_cutover_verified_proof_no_delete BEFORE DELETE ON legacy_cutover_verified_proofs
BEGIN SELECT RAISE(ABORT,'immutable legacy cutover proof'); END;
`;
const LEGACY_IMPORT_RECEIPT_SCHEMA = `
CREATE TABLE legacy_import_receipts (
 id INTEGER PRIMARY KEY CHECK(id=1),
 source_sha256 TEXT NOT NULL CHECK(length(source_sha256)=64),
 source_schema_version INTEGER NOT NULL CHECK(source_schema_version IN (3,4)),
 storage_keys INTEGER NOT NULL CHECK(storage_keys>0),
 credentials INTEGER NOT NULL CHECK(credentials>0),
 proof_set_sha256 TEXT NOT NULL CHECK(length(proof_set_sha256)=64),
 binding_set_sha256 TEXT NOT NULL CHECK(length(binding_set_sha256)=64),
 public_rows_sha256 TEXT NOT NULL CHECK(length(public_rows_sha256)=64),
 imported_at INTEGER NOT NULL CHECK(imported_at>=0),
 receipt_sha256 TEXT NOT NULL UNIQUE CHECK(length(receipt_sha256)=64)
) STRICT;
CREATE TRIGGER legacy_import_receipt_no_update BEFORE UPDATE ON legacy_import_receipts
BEGIN SELECT RAISE(ABORT,'immutable legacy import receipt'); END;
CREATE TRIGGER legacy_import_receipt_no_delete BEFORE DELETE ON legacy_import_receipts
BEGIN SELECT RAISE(ABORT,'immutable legacy import receipt'); END;
CREATE TRIGGER legacy_import_source_no_new_binding BEFORE INSERT ON storage_bindings
WHEN EXISTS (SELECT 1 FROM legacy_import_receipts WHERE source_sha256=NEW.source_sha256)
BEGIN SELECT RAISE(ABORT,'sealed legacy import source'); END;
CREATE TRIGGER legacy_import_source_no_new_proof BEFORE INSERT ON legacy_cutover_verified_proofs
WHEN EXISTS (SELECT 1 FROM legacy_import_receipts WHERE source_sha256=NEW.source_sha256)
BEGIN SELECT RAISE(ABORT,'sealed legacy import source'); END;
CREATE TRIGGER legacy_import_proof_v2_insert BEFORE INSERT ON legacy_cutover_verified_proofs
BEGIN
 SELECT RAISE(ABORT,'v2 owner key proof required') WHERE NEW.proof_version!=2 OR NOT EXISTS (
  SELECT 1 FROM credentials c WHERE c.id=NEW.owner_credential_id AND c.owner=NEW.owner
    AND c.public_key=NEW.owner_public_key
 );
END;
CREATE TRIGGER legacy_import_owner_key_no_update
BEFORE UPDATE OF public_key,user_handle ON credentials
WHEN EXISTS (SELECT 1 FROM legacy_cutover_verified_proofs p WHERE p.owner_credential_id=OLD.id)
BEGIN SELECT RAISE(ABORT,'immutable proven owner key'); END;
`;
const SCHEMA = `
CREATE TABLE meta (id INTEGER PRIMARY KEY CHECK(id=1), wall INTEGER NOT NULL CHECK(wall>=0), observed INTEGER NOT NULL CHECK(observed>=0), version INTEGER NOT NULL CHECK(version=9)) STRICT;
INSERT INTO meta VALUES(1,0,0,9);
CREATE TABLE owners (
 subject TEXT PRIMARY KEY, namespace TEXT UNIQUE NOT NULL, user_handle TEXT UNIQUE NOT NULL,
 wallet_binding TEXT UNIQUE NOT NULL, generation INTEGER NOT NULL CHECK(generation>=0), created INTEGER NOT NULL
) STRICT;
CREATE TABLE credentials (
 id TEXT PRIMARY KEY, owner TEXT NOT NULL REFERENCES owners(subject), public_key TEXT NOT NULL,
 user_handle TEXT NOT NULL, counter INTEGER NOT NULL CHECK(counter>=0),
 device_type TEXT NOT NULL CHECK(device_type IN ('singleDevice','multiDevice')),
 backed_up INTEGER NOT NULL CHECK(backed_up IN (0,1)), revoked INTEGER NOT NULL CHECK(revoked IN (0,1)),
 CHECK(device_type='multiDevice' OR backed_up=0)
) STRICT;
CREATE TABLE sessions (
 digest TEXT PRIMARY KEY, owner TEXT NOT NULL REFERENCES owners(subject), credential TEXT NOT NULL REFERENCES credentials(id),
 generation INTEGER NOT NULL, platform TEXT NOT NULL CHECK(platform IN ('android','ios')), expires INTEGER NOT NULL
) STRICT;
CREATE TABLE grants (
 digest TEXT PRIMARY KEY, session TEXT NOT NULL REFERENCES sessions(digest) ON DELETE CASCADE,
 owner TEXT NOT NULL REFERENCES owners(subject), generation INTEGER NOT NULL,
 audience TEXT NOT NULL, method TEXT NOT NULL CHECK(method='POST'), path TEXT NOT NULL, body_hash TEXT NOT NULL,
 scope TEXT NOT NULL, expires INTEGER NOT NULL
) STRICT;
CREATE TABLE ceremonies (
 id TEXT PRIMARY KEY, kind TEXT NOT NULL CHECK(kind IN ('bootstrap','authentication','enrollment')),
 challenge TEXT NOT NULL, subject TEXT, namespace TEXT, user_handle TEXT,
 session TEXT, generation INTEGER, platform TEXT NOT NULL CHECK(platform IN ('android','ios')),
 expires INTEGER NOT NULL, claimed INTEGER NOT NULL CHECK(claimed IN (0,1))
) STRICT;
CREATE TABLE limits (bucket INTEGER PRIMARY KEY, count INTEGER NOT NULL CHECK(count>=0)) STRICT;
CREATE INDEX sessions_owner ON sessions(owner);
CREATE INDEX grants_session ON grants(session);
CREATE INDEX ceremonies_expiry ON ceremonies(expires);
${BACKUP_HEAD_SCHEMA}
${LEGACY_COHORT_SCHEMA}
${CREDENTIAL_SCOPE_TABLE}
${CREDENTIAL_SCOPE_TRIGGERS}
${PENDING_CHALLENGE_SCHEMA}
${KEY_ROTATION_SCHEMA}
${LEGACY_CUTOVER_CHALLENGE_SCHEMA}
${LEGACY_CUTOVER_VERIFIED_PROOF_SCHEMA}
${LEGACY_IMPORT_RECEIPT_SCHEMA}
PRAGMA user_version=9;
`;
const MIGRATE_V1_TO_V2 = `
${BACKUP_HEAD_SCHEMA}
CREATE TABLE meta_v2 (id INTEGER PRIMARY KEY CHECK(id=1), wall INTEGER NOT NULL CHECK(wall>=0), observed INTEGER NOT NULL CHECK(observed>=0), version INTEGER NOT NULL CHECK(version=2)) STRICT;
INSERT INTO meta_v2 SELECT id,wall,observed,2 FROM meta WHERE id=1 AND version=1;
DROP TABLE meta;
ALTER TABLE meta_v2 RENAME TO meta;
PRAGMA user_version=2;
`;
const MIGRATE_V2_TO_V3 = `
${LEGACY_COHORT_SCHEMA}
CREATE TABLE meta_v3 (id INTEGER PRIMARY KEY CHECK(id=1), wall INTEGER NOT NULL CHECK(wall>=0), observed INTEGER NOT NULL CHECK(observed>=0), version INTEGER NOT NULL CHECK(version=3)) STRICT;
INSERT INTO meta_v3 SELECT id,wall,observed,3 FROM meta WHERE id=1 AND version=2;
DROP TABLE meta;
ALTER TABLE meta_v3 RENAME TO meta;
PRAGMA user_version=3;
`;
const MIGRATE_V3_TO_V4 = `
${CREDENTIAL_SCOPE_TABLE}
INSERT INTO credential_scopes
 SELECT c.id,c.owner,CASE WHEN m.credential_id IS NULL THEN 'owner' ELSE 'storage' END,m.storage_key
 FROM credentials c LEFT JOIN legacy_credential_metadata m ON m.credential_id=c.id;
${CREDENTIAL_SCOPE_TRIGGERS}
CREATE TABLE meta_v4 (id INTEGER PRIMARY KEY CHECK(id=1), wall INTEGER NOT NULL CHECK(wall>=0), observed INTEGER NOT NULL CHECK(observed>=0), version INTEGER NOT NULL CHECK(version=4)) STRICT;
INSERT INTO meta_v4 SELECT id,wall,observed,4 FROM meta WHERE id=1 AND version=3;
DROP TABLE meta;
ALTER TABLE meta_v4 RENAME TO meta;
PRAGMA user_version=4;
`;
const MIGRATE_V4_TO_V5 = `
${PENDING_CHALLENGE_SCHEMA}
CREATE TABLE meta_v5 (id INTEGER PRIMARY KEY CHECK(id=1), wall INTEGER NOT NULL CHECK(wall>=0), observed INTEGER NOT NULL CHECK(observed>=0), version INTEGER NOT NULL CHECK(version=5)) STRICT;
INSERT INTO meta_v5 SELECT id,wall,observed,5 FROM meta WHERE id=1 AND version=4;
DROP TABLE meta;
ALTER TABLE meta_v5 RENAME TO meta;
PRAGMA user_version=5;
`;
const MIGRATE_V5_TO_V6 = `
${KEY_ROTATION_SCHEMA}
INSERT INTO key_rotation_floors(owner,minimum_epoch)
 SELECT c.owner,COALESCE((
  SELECT o.key_epoch+1 FROM backup_heads h
  JOIN backup_operations o ON o.operation_id=h.operation_id
  WHERE h.owner=c.owner
 ),1)
 FROM credentials c WHERE c.revoked=1 GROUP BY c.owner;
CREATE TABLE meta_v6 (id INTEGER PRIMARY KEY CHECK(id=1), wall INTEGER NOT NULL CHECK(wall>=0), observed INTEGER NOT NULL CHECK(observed>=0), version INTEGER NOT NULL CHECK(version=6)) STRICT;
INSERT INTO meta_v6 SELECT id,wall,observed,6 FROM meta WHERE id=1 AND version=5;
DROP TABLE meta;
ALTER TABLE meta_v6 RENAME TO meta;
PRAGMA user_version=6;
`;
const MIGRATE_V6_TO_V7 = `
${LEGACY_CUTOVER_CHALLENGE_SCHEMA}
CREATE TABLE meta_v7 (id INTEGER PRIMARY KEY CHECK(id=1), wall INTEGER NOT NULL CHECK(wall>=0), observed INTEGER NOT NULL CHECK(observed>=0), version INTEGER NOT NULL CHECK(version=7)) STRICT;
INSERT INTO meta_v7 SELECT id,wall,observed,7 FROM meta WHERE id=1 AND version=6;
DROP TABLE meta;
ALTER TABLE meta_v7 RENAME TO meta;
PRAGMA user_version=7;
`;
const MIGRATE_V7_TO_V9 = `
${LEGACY_CUTOVER_VERIFIED_PROOF_SCHEMA}
${LEGACY_IMPORT_RECEIPT_SCHEMA}
CREATE TABLE meta_v9 (id INTEGER PRIMARY KEY CHECK(id=1), wall INTEGER NOT NULL CHECK(wall>=0), observed INTEGER NOT NULL CHECK(observed>=0), version INTEGER NOT NULL CHECK(version=9)) STRICT;
INSERT INTO meta_v9 SELECT id,wall,observed,9 FROM meta WHERE id=1 AND version=7;
DROP TABLE meta;
ALTER TABLE meta_v9 RENAME TO meta;
PRAGMA user_version=9;
`;
const MIGRATE_V8_TO_V9 = `
ALTER TABLE legacy_cutover_verified_proofs ADD COLUMN proof_version INTEGER NOT NULL DEFAULT 1 CHECK(proof_version IN (1,2));
ALTER TABLE legacy_cutover_verified_proofs ADD COLUMN owner_public_key_sha256 TEXT;
ALTER TABLE legacy_cutover_verified_proofs ADD COLUMN owner_public_key TEXT;
${LEGACY_IMPORT_RECEIPT_SCHEMA}
CREATE TABLE meta_v9 (id INTEGER PRIMARY KEY CHECK(id=1), wall INTEGER NOT NULL CHECK(wall>=0), observed INTEGER NOT NULL CHECK(observed>=0), version INTEGER NOT NULL CHECK(version=9)) STRICT;
INSERT INTO meta_v9 SELECT id,wall,observed,9 FROM meta WHERE id=1 AND version=8;
DROP TABLE meta;
ALTER TABLE meta_v9 RENAME TO meta;
PRAGMA user_version=9;
`;

function validateLegacyCohortSchema(db) {
  db.prepare('SELECT storage_key,owner,legacy_owner_hash,source_sha256,proof_sha256,created FROM storage_bindings LIMIT 0').all();
  db.prepare('SELECT credential_id,storage_key,aaguid,transports_json,registration_platform FROM legacy_credential_metadata LIMIT 0').all();
  for (const name of REQUIRED_LEGACY_TRIGGERS) {
    if (!db.prepare("SELECT name FROM sqlite_master WHERE type='trigger' AND name=?").get(name)) deny('store_invalid');
  }
}

function validateCredentialScopeSchema(db) {
  db.prepare('SELECT credential_id,owner,scope,storage_key FROM credential_scopes LIMIT 0').all();
  for (const name of REQUIRED_SCOPE_TRIGGERS) {
    if (!db.prepare("SELECT name FROM sqlite_master WHERE type='trigger' AND name=?").get(name)) deny('store_invalid');
  }
  if (db.prepare(`SELECT 1 FROM credentials c LEFT JOIN credential_scopes s ON s.credential_id=c.id
    WHERE s.credential_id IS NULL OR s.owner!=c.owner LIMIT 1`).get() ||
      db.prepare(`SELECT 1 FROM credential_scopes s
      LEFT JOIN legacy_credential_metadata m ON m.credential_id=s.credential_id
      LEFT JOIN storage_bindings b ON b.storage_key=s.storage_key
    WHERE (s.scope='storage' AND (m.storage_key IS NULL OR m.storage_key!=s.storage_key)) OR
      (s.scope='storage' AND (b.owner IS NULL OR b.owner!=s.owner)) OR
      (s.scope='owner' AND m.credential_id IS NOT NULL) LIMIT 1`).get()) deny('store_invalid');
}

function validatePendingChallengeSchema(db) {
  db.prepare(`SELECT id,version,kind,storage_key,owner,generation,session,platform,nonce,expires,
    user_handle,directed_credential_id,claimed,body_hash,credential_id FROM pending_challenges LIMIT 0`).all();
  if (!db.prepare("SELECT name FROM sqlite_master WHERE type='trigger' AND name='pending_challenge_claim_once'").get()) deny('store_invalid');
  if (db.prepare(`SELECT 1 FROM pending_challenges p JOIN storage_bindings b ON b.storage_key=p.storage_key
    JOIN sessions s ON s.digest=p.session JOIN owners o ON o.subject=p.owner
    WHERE b.owner!=p.owner OR s.owner!=p.owner OR s.generation!=p.generation OR
    o.generation!=p.generation OR s.platform!=p.platform OR
    (p.directed_credential_id IS NOT NULL AND NOT EXISTS (
      SELECT 1 FROM credential_scopes c WHERE c.credential_id=p.directed_credential_id
        AND c.owner=p.owner AND c.scope='storage' AND c.storage_key=p.storage_key)) LIMIT 1`).get()) deny('store_invalid');
  const pending = db.prepare(`SELECT id,storage_key,user_handle,nonce,directed_credential_id,
    claimed,body_hash,credential_id FROM pending_challenges`).all();
  if (pending.length > 256) deny('store_invalid');
  for (const row of pending) {
    opaque(row.id, 'pending.');
    base64(row.nonce, 32, 32);
    base64(row.user_handle, 32, 32);
    if (row.directed_credential_id !== null) base64(row.directed_credential_id, 1, 384);
    if (row.claimed === 1) {
      base64(row.body_hash, 32, 32);
      base64(row.credential_id, 1, 384);
    }
    if (row.user_handle !== hash(Buffer.from(`user\0${row.storage_key}`, 'utf8'))) deny('store_invalid');
  }
}

function validateKeyRotationSchema(db) {
  db.prepare('SELECT owner,minimum_epoch FROM key_rotation_floors LIMIT 0').all();
  for (const name of ['credential_revoke_rotation', 'key_rotation_floor_no_decrease', 'key_rotation_floor_no_delete']) {
    if (!db.prepare("SELECT name FROM sqlite_master WHERE type='trigger' AND name=?").get(name)) deny('store_invalid');
  }
  if (db.prepare(`SELECT 1 FROM credentials c LEFT JOIN key_rotation_floors f ON f.owner=c.owner
    WHERE c.revoked=1 AND f.owner IS NULL LIMIT 1`).get() ||
      db.prepare(`SELECT 1 FROM key_rotation_floors f LEFT JOIN backup_heads h ON h.owner=f.owner
    LEFT JOIN backup_operations o ON o.operation_id=h.operation_id
    WHERE (h.owner IS NULL AND f.minimum_epoch!=1) OR
      (h.owner IS NOT NULL AND (o.operation_id IS NULL OR f.minimum_epoch>o.key_epoch+1)) LIMIT 1`).get()) deny('store_invalid');
}

function validateLegacyCutoverChallengeSchema(db) {
  db.prepare(`SELECT id,version,source_sha256,snapshot_name,storage_key,legacy_owner_hash,
    legacy_credential_id,legacy_public_key_sha256,legacy_counter,legacy_user_handle,legacy_scope,
    owner,generation,session,owner_credential_id,owner_credential_counter,rp_id,platform,
    nonce,expires,state,legacy_body_sha256,owner_body_sha256 FROM legacy_cutover_challenges LIMIT 0`).all();
  if (!db.prepare(`SELECT name FROM sqlite_master WHERE type='trigger' AND
    name='legacy_cutover_challenge_transition'`).get() ||
      db.prepare(`SELECT 1 FROM legacy_cutover_challenges p
      LEFT JOIN sessions s ON s.digest=p.session
      LEFT JOIN owners o ON o.subject=p.owner
      WHERE o.subject IS NULL OR (s.digest IS NOT NULL AND
        (s.owner!=p.owner OR s.generation!=p.generation OR s.platform!=p.platform OR
         s.credential!=p.owner_credential_id)) LIMIT 1`).get()) deny('store_invalid');
  const rows = db.prepare(`SELECT id,source_sha256,snapshot_name,storage_key,legacy_owner_hash,
    legacy_credential_id,legacy_public_key_sha256,legacy_user_handle,session,owner_credential_id,
    nonce,state,legacy_body_sha256,owner_body_sha256 FROM legacy_cutover_challenges`).all();
  if (rows.length > 128) deny('store_invalid');
  for (const row of rows) {
    opaque(row.id, 'cutover.');
    if (!/^[0-9a-f]{64}$/.test(row.source_sha256) ||
        !/^[0-9a-f]{64}$/.test(row.legacy_public_key_sha256) ||
        row.snapshot_name !== `legacy-${row.source_sha256}.json` ||
        !/^[A-Za-z0-9._:-]{8,128}$/.test(row.storage_key)) deny('store_invalid');
    base64(row.legacy_owner_hash, 32, 32);
    base64(row.legacy_credential_id, 1, 384);
    base64(row.legacy_user_handle, 32, 32);
    base64(row.session, 32, 32);
    base64(row.owner_credential_id, 1, 384);
    base64(row.nonce, 32, 32);
    if ((row.state === 0 && (row.legacy_body_sha256 !== null || row.owner_body_sha256 !== null)) ||
        ([1, 2].includes(row.state) &&
          (!/^[0-9a-f]{64}$/.test(row.legacy_body_sha256 ?? '') ||
           !/^[0-9a-f]{64}$/.test(row.owner_body_sha256 ?? '')))) deny('store_invalid');
  }
}

function validateLegacyCutoverVerifiedProofSchema(db) {
  db.prepare(`SELECT challenge_id,proof_sha256,source_sha256,owner,legacy_credential_id,
    owner_credential_id,legacy_body_sha256,owner_body_sha256,legacy_challenge_sha256,
    owner_challenge_sha256,legacy_new_counter,owner_new_counter,legacy_device_type,
    legacy_backed_up,owner_device_type,owner_backed_up,verified_at
    FROM legacy_cutover_verified_proofs LIMIT 0`).all();
  for (const name of ['legacy_cutover_verified_proof_insert',
    'legacy_cutover_verified_proof_no_update', 'legacy_cutover_verified_proof_no_delete']) {
    if (!db.prepare("SELECT 1 FROM sqlite_master WHERE type='trigger' AND name=?").get(name)) {
      deny('store_invalid');
    }
  }
  const proofs = db.prepare('SELECT * FROM legacy_cutover_verified_proofs').all();
  if (proofs.length > 128) deny('store_invalid');
  for (const proof of proofs) {
    if (proof.proof_version === 2) base64(proof.owner_public_key, 1, 6144);
    const row = db.prepare('SELECT * FROM legacy_cutover_challenges WHERE id=?').get(proof.challenge_id);
    if (!row || row.state !== 2 || proof.verified_at >= row.expires ||
        proof.verified_at < row.expires - 120_000 ||
        proof.source_sha256 !== row.source_sha256 || proof.owner !== row.owner ||
        proof.legacy_credential_id !== row.legacy_credential_id ||
        proof.owner_credential_id !== row.owner_credential_id ||
        proof.legacy_body_sha256 !== row.legacy_body_sha256 ||
        proof.owner_body_sha256 !== row.owner_body_sha256 ||
        proof.legacy_challenge_sha256 !== createHash('sha256').update(
          legacyCutoverAssertionChallenge(row, 'LEGACY')).digest('hex') ||
        proof.owner_challenge_sha256 !== createHash('sha256').update(
          legacyCutoverAssertionChallenge(row, 'OWNER')).digest('hex') ||
        !SHA256_HEX.test(proof.proof_sha256) ||
        proof.proof_sha256 !== legacyCutoverProofCommitment(proof) ||
        (proof.proof_version !== undefined &&
          (proof.proof_version === 2
            ? (!SHA256_HEX.test(proof.owner_public_key_sha256) ||
              proof.owner_public_key_sha256 !== createHash('sha256').update(
                Buffer.from(proof.owner_public_key ?? '', 'base64url')).digest('hex') ||
              db.prepare('SELECT public_key FROM credentials WHERE id=?').get(
                proof.owner_credential_id)?.public_key !== proof.owner_public_key)
            : (proof.proof_version !== 1 || proof.owner_public_key_sha256 !== null ||
              proof.owner_public_key !== null))) ||
        ((row.legacy_counter !== 0 || proof.legacy_new_counter !== 0) &&
          proof.legacy_new_counter <= row.legacy_counter) ||
        ((row.owner_credential_counter !== 0 || proof.owner_new_counter !== 0) &&
          proof.owner_new_counter <= row.owner_credential_counter)) deny('store_invalid');
  }
}

function validateLegacyImportReceiptSchema(db) {
  db.prepare(`SELECT proof_version,owner_public_key_sha256,owner_public_key
    FROM legacy_cutover_verified_proofs LIMIT 0`).all();
  db.prepare(`SELECT id,source_sha256,source_schema_version,storage_keys,credentials,
    proof_set_sha256,binding_set_sha256,public_rows_sha256,imported_at,receipt_sha256
    FROM legacy_import_receipts LIMIT 0`).all();
  for (const name of ['legacy_import_receipt_no_update', 'legacy_import_receipt_no_delete',
    'legacy_import_source_no_new_binding', 'legacy_import_source_no_new_proof',
    'legacy_import_proof_v2_insert', 'legacy_import_owner_key_no_update']) {
    if (!db.prepare("SELECT 1 FROM sqlite_master WHERE type='trigger' AND name=?").get(name)) {
      deny('store_invalid');
    }
  }
  const receipts = db.prepare('SELECT * FROM legacy_import_receipts').all();
  if (receipts.length > 1) deny('store_invalid');
  for (const receipt of receipts) {
    if (![receipt.source_sha256, receipt.proof_set_sha256, receipt.binding_set_sha256,
      receipt.public_rows_sha256, receipt.receipt_sha256].every((value) => SHA256_HEX.test(value)) ||
        receipt.receipt_sha256 !== legacyImportReceiptCommitment(receipt)) deny('store_invalid');
    const bindings = db.prepare(`SELECT storage_key,owner,legacy_owner_hash,source_sha256,proof_sha256
      FROM storage_bindings WHERE source_sha256=? ORDER BY storage_key`).all(receipt.source_sha256);
    const bindingRows = bindings.map((row) => [row.storage_key, row.owner,
      row.legacy_owner_hash, row.source_sha256, row.proof_sha256]);
    const proofs = db.prepare(`SELECT p.legacy_credential_id,p.proof_sha256
      FROM legacy_cutover_verified_proofs p WHERE p.source_sha256=?
      ORDER BY p.legacy_credential_id`).all(receipt.source_sha256);
    const proofRows = proofs.map((row) => [row.legacy_credential_id, row.proof_sha256]);
    if (bindings.length !== receipt.storage_keys || proofs.length !== receipt.credentials ||
        legacyImportBindingSetSha256(bindingRows) !== receipt.binding_set_sha256 ||
        legacyImportProofSetSha256(proofRows) !== receipt.proof_set_sha256 ||
        db.prepare(`SELECT count(*) AS n FROM legacy_cutover_verified_proofs p
          JOIN legacy_cutover_challenges h ON h.id=p.challenge_id
          JOIN storage_bindings b ON b.storage_key=h.storage_key AND b.owner=p.owner
          JOIN legacy_credential_metadata m ON m.credential_id=p.legacy_credential_id
            AND m.storage_key=h.storage_key
          JOIN credentials c ON c.id=m.credential_id AND c.owner=p.owner
          JOIN credential_scopes s ON s.credential_id=c.id AND s.scope='storage'
            AND s.storage_key=h.storage_key
          WHERE p.source_sha256=? AND b.source_sha256=?`).get(
          receipt.source_sha256, receipt.source_sha256).n !== receipt.credentials) deny('store_invalid');
  }
}

function assertPrivateFileStat(st, directory = false) {
  if (st.isSymbolicLink() || (directory ? !st.isDirectory() : !st.isFile()) ||
      (st.mode & 0o077) !== 0 || (!directory && st.nlink !== 1) ||
      (process.getuid && st.uid !== process.getuid())) deny('store_unavailable');
  return st;
}

function privateFile(path, directory = false) {
  return assertPrivateFileStat(lstatSync(path), directory);
}

function sameFileIdentity(left, right) {
  return left.dev === right.dev && left.ino === right.ino && left.mode === right.mode &&
    left.uid === right.uid && left.nlink === right.nlink;
}

function sameFileImage(left, right) {
  return sameFileIdentity(left, right) && left.size === right.size &&
    left.mtimeMs === right.mtimeMs && left.ctimeMs === right.ctimeMs;
}

function pinnedSqlitePath(fd) {
  // DatabaseSync accepts a pathname, not an existing descriptor. The OS fd
  // namespace makes its SQLite open refer to the already checked inode.
  if (process.platform === 'darwin') return `/dev/fd/${fd}`;
  if (process.platform === 'linux') return `/proc/self/fd/${fd}`;
  deny('store_unavailable');
}

function assertNoSqliteSidecars(path) {
  // An fd alias has a different pathname from the checked database. SQLite
  // would look for an interrupted writer's hot rollback journal beside the
  // alias and could return uncommitted main-file pages as valid rows.
  for (const suffix of ['-journal', '-wal', '-shm']) {
    try {
      lstatSync(`${path}${suffix}`);
      deny('store_unavailable');
    } catch (error) {
      if (error?.code !== 'ENOENT') throw error;
    }
  }
}

/** Local durable filesystem only; no network filesystem, silent init, or memory fallback. */
export class AuthorityStore {
  #db;
  #poisoned = false;
  #wall;
  #monotonic;
  #anchorWall;
  #anchorMonotonic;
  #fault;
  constructor({ path, create = false, migrate = false, now = Date.now, monotonic = () => Number(process.hrtime.bigint() / 1_000_000n), fault = () => {} }) {
    if (!isAbsolute(path)) deny('store_unavailable');
    this.#wall = now;
    this.#monotonic = monotonic;
    this.#anchorWall = now();
    this.#anchorMonotonic = monotonic();
    this.#fault = fault; // Server-owned fault injection for crash/durability tests only.
    try {
      privateFile(dirname(path), true);
      if (create) {
        const fd = openSync(path, constants.O_CREAT | constants.O_EXCL | constants.O_WRONLY | constants.O_NOFOLLOW, 0o600);
        fsyncSync(fd);
        closeSync(fd);
        const dir = openSync(dirname(path), constants.O_RDONLY);
        fsyncSync(dir);
        closeSync(dir);
      }
      privateFile(path);
      this.#db = new DatabaseSync(path);
      this.#db.exec('PRAGMA foreign_keys=ON; PRAGMA busy_timeout=1000; PRAGMA journal_mode=DELETE; PRAGMA synchronous=FULL; PRAGMA fullfsync=ON; PRAGMA trusted_schema=OFF;');
      this.#db.exec('BEGIN IMMEDIATE');
      try {
        if (create) this.#db.exec(SCHEMA);
        let oldVersion = this.#db.prepare('PRAGMA user_version').get().user_version;
        if (!create && migrate && oldVersion === 1 &&
            this.#db.prepare('SELECT version FROM meta WHERE id=1').get()?.version === 1) {
          this.#db.exec(MIGRATE_V1_TO_V2);
          oldVersion = 2;
        }
        if (!create && migrate && oldVersion === 2 &&
            this.#db.prepare('SELECT version FROM meta WHERE id=1').get()?.version === 2) {
          this.#db.exec(MIGRATE_V2_TO_V3);
          oldVersion = 3;
        }
        if (!create && migrate && oldVersion === 3 &&
            this.#db.prepare('SELECT version FROM meta WHERE id=1').get()?.version === 3) {
          this.#db.exec(MIGRATE_V3_TO_V4);
          oldVersion = 4;
        }
        if (!create && migrate && oldVersion === 4 &&
            this.#db.prepare('SELECT version FROM meta WHERE id=1').get()?.version === 4) {
          this.#db.exec(MIGRATE_V4_TO_V5);
          oldVersion = 5;
        }
        if (!create && migrate && oldVersion === 5 &&
            this.#db.prepare('SELECT version FROM meta WHERE id=1').get()?.version === 5) {
          this.#db.exec(MIGRATE_V5_TO_V6);
          oldVersion = 6;
        }
        if (!create && migrate && oldVersion === 6 &&
            this.#db.prepare('SELECT version FROM meta WHERE id=1').get()?.version === 6) {
          this.#db.exec(MIGRATE_V6_TO_V7);
          oldVersion = 7;
        }
        if (!create && migrate && oldVersion === 7 &&
            this.#db.prepare('SELECT version FROM meta WHERE id=1').get()?.version === 7) {
          validateLegacyCutoverChallengeSchema(this.#db);
          this.#db.exec(MIGRATE_V7_TO_V9);
          oldVersion = 9;
        }
        if (!create && migrate && oldVersion === 8 &&
            this.#db.prepare('SELECT version FROM meta WHERE id=1').get()?.version === 8) {
          validateLegacyCutoverVerifiedProofSchema(this.#db);
          this.#db.exec(MIGRATE_V8_TO_V9);
        }
        if (this.#db.prepare('PRAGMA user_version').get().user_version !== SCHEMA_VERSION ||
            this.#db.prepare('SELECT version FROM meta WHERE id=1').get()?.version !== SCHEMA_VERSION ||
            this.#db.prepare('PRAGMA quick_check').get().quick_check !== 'ok' ||
            this.#db.prepare('PRAGMA foreign_key_check').all().length) deny('store_invalid');
        this.#db.prepare('SELECT owner, revision, operation_id FROM backup_heads LIMIT 0').all();
        this.#db.prepare('SELECT owner, revision, operation_id FROM backup_operations LIMIT 0').all();
        validateLegacyCohortSchema(this.#db);
        validateCredentialScopeSchema(this.#db);
        validatePendingChallengeSchema(this.#db);
        validateKeyRotationSchema(this.#db);
        validateLegacyCutoverChallengeSchema(this.#db);
        validateLegacyCutoverVerifiedProofSchema(this.#db);
        validateLegacyImportReceiptSchema(this.#db);
        this.#db.exec('COMMIT');
      } catch (error) {
        this.#db.exec('ROLLBACK');
        throw error;
      }
    } catch {
      this.#db?.close();
      deny('store_unavailable');
    }
  }
  close() { this.#poisoned = true; this.#db.close(); }
  #time() {
    const wall = this.#wall();
    const mono = this.#monotonic();
    const effective = Math.max(wall, this.#anchorWall + mono - this.#anchorMonotonic);
    if (![wall, mono, effective].every(Number.isSafeInteger) || wall < 0 || mono < this.#anchorMonotonic) deny('clock_invalid');
    this.#anchorWall = effective;
    this.#anchorMonotonic = mono;
    return { wall, effective };
  }
  transaction(action) {
    if (this.#poisoned) deny('store_unavailable');
    let started = false;
    let result;
    let rejected;
    try {
      this.#db.exec('BEGIN IMMEDIATE');
      started = true;
      const { wall, effective: sampled } = this.#time(); // Sample AFTER waiting for SQLite's writer lock.
      const previous = this.#db.prepare('SELECT wall, observed FROM meta WHERE id=1').get();
      const effective = Math.max(previous.observed, sampled);
      // Carry observed continuous time forward across a process restart.
      this.#anchorWall += effective - sampled;
      this.#db.prepare('UPDATE meta SET wall=?, observed=? WHERE id=1').run(Math.max(previous.wall, wall), effective);
      this.#db.exec('SAVEPOINT mutation');
      try {
        if (wall < previous.wall) deny('clock_rollback');
        const query = (sql, ...args) => this.#db.prepare(sql).get(...args);
        const all = (sql, ...args) => this.#db.prepare(sql).all(...args);
        const run = (sql, ...args) => this.#db.prepare(sql).run(...args);
        result = action({ now: effective, query, all, run });
        if (result?.then) deny('async_transaction_forbidden');
      } catch (error) {
        if (!(error instanceof AuthorityError)) throw error;
        rejected = error;
        this.#db.exec('ROLLBACK TO mutation');
      }
      this.#db.exec('RELEASE mutation');
      this.#fault('beforeCommit');
      this.#db.exec('COMMIT');
      started = false;
      this.#fault('afterCommit');
      // An unusually slow durable commit must not return already-expired authority.
      if (result?.expiresAt !== undefined && result.expiresAt * 1000 <= this.#time().effective) deny('authorization_expired');
    } catch (error) {
      if (started) {
        try { this.#db.exec('ROLLBACK'); } catch { /* poison below */ }
      }
      if (error instanceof AuthorityError && error.code === 'authorization_expired' && !started) throw error;
      // Includes a commit which may have completed before an I/O error. No use
      // of a stale in-memory view, retry or grant restoration in this process.
      this.#poisoned = true;
      deny('store_unavailable');
    }
    if (rejected) throw rejected;
    return result;
  }
}

/** Read-only operator snapshot for planning a verified legacy migration. */
export function readOwnerCredentialSnapshot(path) {
  if (!isAbsolute(path)) deny('store_unavailable');
  let db;
  let fd;
  try {
    const directoryBefore = privateFile(dirname(path), true);
    assertNoSqliteSidecars(path);
    const fileBefore = privateFile(path);
    fd = openSync(path, constants.O_RDONLY | constants.O_NOFOLLOW);
    if (!sameFileImage(fileBefore, assertPrivateFileStat(fstatSync(fd)))) deny('store_unavailable');
    db = new DatabaseSync(pinnedSqlitePath(fd), { readOnly: true });
    db.exec('PRAGMA query_only=ON; PRAGMA busy_timeout=1000; PRAGMA foreign_keys=ON; PRAGMA trusted_schema=OFF;');
    db.exec('BEGIN');
    // The authority writer always uses DELETE journaling. A WAL database read
    // through an fd alias might otherwise omit an uncheckpointed sidecar.
    if (db.prepare('PRAGMA journal_mode').get().journal_mode !== 'delete') deny('store_invalid');
    const schemaVersion = db.prepare('PRAGMA user_version').get().user_version;
    if (![2, 3, 4, 5, 6, 7, 8, SCHEMA_VERSION].includes(schemaVersion) ||
        db.prepare('SELECT version FROM meta WHERE id=1').get()?.version !== schemaVersion ||
        db.prepare('PRAGMA quick_check').get().quick_check !== 'ok' ||
        db.prepare('PRAGMA foreign_key_check').all().length) deny('store_invalid');
    if (schemaVersion >= 3) validateLegacyCohortSchema(db);
    if (schemaVersion >= 4) validateCredentialScopeSchema(db);
    if (schemaVersion >= 5) validatePendingChallengeSchema(db);
    if (schemaVersion >= 6) validateKeyRotationSchema(db);
    if (schemaVersion >= 7) validateLegacyCutoverChallengeSchema(db);
    if (schemaVersion >= 8) validateLegacyCutoverVerifiedProofSchema(db);
    if (schemaVersion >= 9) validateLegacyImportReceiptSchema(db);
    const owners = db.prepare('SELECT subject,user_handle,generation FROM owners ORDER BY subject').all()
      .map((row) => Object.freeze({ ...row }));
    const credentials = db.prepare('SELECT id,owner,public_key,user_handle,counter,device_type,backed_up,revoked FROM credentials ORDER BY id').all()
      .map((row) => Object.freeze({ ...row }));
    const storageBindings = schemaVersion >= 3
      ? db.prepare('SELECT storage_key,owner,legacy_owner_hash,source_sha256,proof_sha256,created FROM storage_bindings ORDER BY storage_key').all()
        .map((row) => Object.freeze({ ...row })) : [];
    const legacyCredentialMetadata = schemaVersion >= 3
      ? db.prepare('SELECT credential_id,storage_key,aaguid,transports_json,registration_platform FROM legacy_credential_metadata ORDER BY credential_id').all()
        .map((row) => Object.freeze({ ...row })) : [];
    const credentialScopes = schemaVersion >= 4
      ? db.prepare('SELECT credential_id,owner,scope,storage_key FROM credential_scopes ORDER BY credential_id').all()
        .map((row) => Object.freeze({ ...row })) : [];
    // Keep proof/challenge metadata in the same pinned read transaction as
    // credentials and bindings. Offline comparison must not join snapshots
    // taken from different SQLite states. This is never a migration grant.
    const legacyCutoverChallenges = schemaVersion >= 7
      ? db.prepare(`SELECT * FROM legacy_cutover_challenges ORDER BY id`).all()
        .map((row) => Object.freeze({ ...row })) : [];
    const legacyCutoverVerifiedProofs = schemaVersion >= 8
      ? db.prepare(`SELECT * FROM legacy_cutover_verified_proofs ORDER BY challenge_id`).all()
        .map((row) => Object.freeze({ ...row })) : [];
    const legacyImportReceipts = schemaVersion >= 9
      ? db.prepare('SELECT * FROM legacy_import_receipts ORDER BY id').all()
        .map((row) => Object.freeze({ ...row })) : [];
    db.exec('COMMIT');
    assertNoSqliteSidecars(path);
    if (!sameFileImage(fileBefore, assertPrivateFileStat(fstatSync(fd))) ||
        !sameFileImage(fileBefore, privateFile(path)) ||
        !sameFileIdentity(directoryBefore, privateFile(dirname(path), true))) deny('store_unavailable');
    return Object.freeze({ schemaVersion,
      owners: Object.freeze(owners), credentials: Object.freeze(credentials),
      storageBindings: Object.freeze(storageBindings),
      legacyCredentialMetadata: Object.freeze(legacyCredentialMetadata),
      credentialScopes: Object.freeze(credentialScopes),
      legacyCutoverChallenges: Object.freeze(legacyCutoverChallenges),
      legacyCutoverVerifiedProofs: Object.freeze(legacyCutoverVerifiedProofs),
      legacyImportReceipts: Object.freeze(legacyImportReceipts) });
  } catch {
    try { db?.exec('ROLLBACK'); } catch { /* connection may not have begun */ }
    deny('store_unavailable');
  } finally {
    try { db?.close(); }
    finally { if (fd !== undefined) closeSync(fd); }
  }
}
