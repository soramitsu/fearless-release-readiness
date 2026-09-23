import { DatabaseSync } from 'node:sqlite';
import { constants, closeSync, fsyncSync, lstatSync, openSync } from 'node:fs';
import { dirname, isAbsolute } from 'node:path';
import { AuthorityError, deny } from './validation.js';

const SCHEMA = `
CREATE TABLE meta (id INTEGER PRIMARY KEY CHECK(id=1), wall INTEGER NOT NULL CHECK(wall>=0), observed INTEGER NOT NULL CHECK(observed>=0), version INTEGER NOT NULL CHECK(version=1)) STRICT;
INSERT INTO meta VALUES(1,0,0,1);
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
PRAGMA user_version=1;
`;

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
  constructor({ path, create = false, now = Date.now, monotonic = () => Number(process.hrtime.bigint() / 1_000_000n), fault = () => {} }) {
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
        if (this.#db.prepare('PRAGMA user_version').get().user_version !== 1 ||
            this.#db.prepare('SELECT version FROM meta WHERE id=1').get()?.version !== 1 ||
            this.#db.prepare('PRAGMA quick_check').get().quick_check !== 'ok' ||
            this.#db.prepare('PRAGMA foreign_key_check').all().length) deny('store_invalid');
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
