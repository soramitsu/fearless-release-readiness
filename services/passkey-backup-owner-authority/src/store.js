import { DatabaseSync } from 'node:sqlite';
import { constants, closeSync, fsyncSync, lstatSync, openSync } from 'node:fs';
import { dirname, isAbsolute } from 'node:path';
import { AuthorityError, deny } from './validation.js';

const SCHEMA_VERSION = 3;
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
const SCHEMA = `
CREATE TABLE meta (id INTEGER PRIMARY KEY CHECK(id=1), wall INTEGER NOT NULL CHECK(wall>=0), observed INTEGER NOT NULL CHECK(observed>=0), version INTEGER NOT NULL CHECK(version=3)) STRICT;
INSERT INTO meta VALUES(1,0,0,3);
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
PRAGMA user_version=3;
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

function validateLegacyCohortSchema(db) {
  db.prepare('SELECT storage_key,owner,legacy_owner_hash,source_sha256,proof_sha256,created FROM storage_bindings LIMIT 0').all();
  db.prepare('SELECT credential_id,storage_key,aaguid,transports_json,registration_platform FROM legacy_credential_metadata LIMIT 0').all();
  for (const name of REQUIRED_LEGACY_TRIGGERS) {
    if (!db.prepare("SELECT name FROM sqlite_master WHERE type='trigger' AND name=?").get(name)) deny('store_invalid');
  }
}

function privateFile(path, directory = false) {
  const st = lstatSync(path);
  if (st.isSymbolicLink() || (directory ? !st.isDirectory() : !st.isFile()) ||
      (st.mode & 0o077) !== 0 || (!directory && st.nlink !== 1) ||
      (process.getuid && st.uid !== process.getuid())) deny('store_unavailable');
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
        }
        if (this.#db.prepare('PRAGMA user_version').get().user_version !== SCHEMA_VERSION ||
            this.#db.prepare('SELECT version FROM meta WHERE id=1').get()?.version !== SCHEMA_VERSION ||
            this.#db.prepare('PRAGMA quick_check').get().quick_check !== 'ok' ||
            this.#db.prepare('PRAGMA foreign_key_check').all().length) deny('store_invalid');
        this.#db.prepare('SELECT owner, revision, operation_id FROM backup_heads LIMIT 0').all();
        this.#db.prepare('SELECT owner, revision, operation_id FROM backup_operations LIMIT 0').all();
        validateLegacyCohortSchema(this.#db);
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
  try {
    privateFile(dirname(path), true);
    privateFile(path);
    db = new DatabaseSync(path, { readOnly: true });
    db.exec('PRAGMA query_only=ON; PRAGMA busy_timeout=1000; PRAGMA foreign_keys=ON; PRAGMA trusted_schema=OFF;');
    db.exec('BEGIN');
    const schemaVersion = db.prepare('PRAGMA user_version').get().user_version;
    if (![2, SCHEMA_VERSION].includes(schemaVersion) ||
        db.prepare('SELECT version FROM meta WHERE id=1').get()?.version !== schemaVersion ||
        db.prepare('PRAGMA quick_check').get().quick_check !== 'ok' ||
        db.prepare('PRAGMA foreign_key_check').all().length) deny('store_invalid');
    if (schemaVersion === SCHEMA_VERSION) validateLegacyCohortSchema(db);
    const owners = db.prepare('SELECT subject,user_handle,generation FROM owners ORDER BY subject').all()
      .map((row) => Object.freeze({ ...row }));
    const credentials = db.prepare('SELECT id,owner,public_key,user_handle,counter,device_type,backed_up,revoked FROM credentials ORDER BY id').all()
      .map((row) => Object.freeze({ ...row }));
    const storageBindings = schemaVersion === SCHEMA_VERSION
      ? db.prepare('SELECT storage_key,owner,legacy_owner_hash,source_sha256,proof_sha256,created FROM storage_bindings ORDER BY storage_key').all()
        .map((row) => Object.freeze({ ...row })) : [];
    const legacyCredentialMetadata = schemaVersion === SCHEMA_VERSION
      ? db.prepare('SELECT credential_id,storage_key,aaguid,transports_json,registration_platform FROM legacy_credential_metadata ORDER BY credential_id').all()
        .map((row) => Object.freeze({ ...row })) : [];
    db.exec('COMMIT');
    return Object.freeze({ schemaVersion,
      owners: Object.freeze(owners), credentials: Object.freeze(credentials),
      storageBindings: Object.freeze(storageBindings),
      legacyCredentialMetadata: Object.freeze(legacyCredentialMetadata) });
  } catch {
    try { db?.exec('ROLLBACK'); } catch { /* connection may not have begun */ }
    deny('store_unavailable');
  } finally {
    db?.close();
  }
}
