import { DatabaseSync } from 'node:sqlite';
import { constants, closeSync, fstatSync, fsyncSync, lstatSync, openSync } from 'node:fs';
import { dirname, isAbsolute } from 'node:path';
import { AuthorityError, base64, deny, hash, opaque } from './validation.js';

const SCHEMA_VERSION = 6;
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
const SCHEMA = `
CREATE TABLE meta (id INTEGER PRIMARY KEY CHECK(id=1), wall INTEGER NOT NULL CHECK(wall>=0), observed INTEGER NOT NULL CHECK(observed>=0), version INTEGER NOT NULL CHECK(version=6)) STRICT;
INSERT INTO meta VALUES(1,0,0,6);
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
PRAGMA user_version=6;
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
    if (![2, 3, 4, 5, SCHEMA_VERSION].includes(schemaVersion) ||
        db.prepare('SELECT version FROM meta WHERE id=1').get()?.version !== schemaVersion ||
        db.prepare('PRAGMA quick_check').get().quick_check !== 'ok' ||
        db.prepare('PRAGMA foreign_key_check').all().length) deny('store_invalid');
    if (schemaVersion >= 3) validateLegacyCohortSchema(db);
    if (schemaVersion >= 4) validateCredentialScopeSchema(db);
    if (schemaVersion >= 5) validatePendingChallengeSchema(db);
    if (schemaVersion >= 6) validateKeyRotationSchema(db);
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
    db.exec('COMMIT');
    assertNoSqliteSidecars(path);
    if (!sameFileImage(fileBefore, assertPrivateFileStat(fstatSync(fd))) ||
        !sameFileImage(fileBefore, privateFile(path)) ||
        !sameFileIdentity(directoryBefore, privateFile(dirname(path), true))) deny('store_unavailable');
    return Object.freeze({ schemaVersion,
      owners: Object.freeze(owners), credentials: Object.freeze(credentials),
      storageBindings: Object.freeze(storageBindings),
      legacyCredentialMetadata: Object.freeze(legacyCredentialMetadata),
      credentialScopes: Object.freeze(credentialScopes) });
  } catch {
    try { db?.exec('ROLLBACK'); } catch { /* connection may not have begun */ }
    deny('store_unavailable');
  } finally {
    try { db?.close(); }
    finally { if (fd !== undefined) closeSync(fd); }
  }
}
