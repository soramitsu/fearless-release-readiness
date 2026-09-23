import { mkdtempSync, rmSync } from 'node:fs';
import { DatabaseSync } from 'node:sqlite';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { createOwnerAuthority } from '../src/authority.js';
import { hash, SCOPES } from '../src/validation.js';

export const audience = 'fearless.passkey-backup';
export const b64 = (value, length = 32) => Buffer.alloc(length, value).toString('base64url');
export const proof = { scheme: 'ed25519', publicKey: b64(4), signature: b64(5, 64) };
export const register = (id = b64(2)) => ({ id, rawId: id, type: 'public-key',
  clientExtensionResults: {}, response: { clientDataJSON: b64(1), attestationObject: b64(3) } });
export const assertion = (userHandle, id = b64(2)) => ({ id, rawId: id, type: 'public-key', clientExtensionResults: {},
  response: { clientDataJSON: b64(1), authenticatorData: b64(3, 37), signature: b64(4, 64), userHandle } });
export const request = (path = Object.keys(SCOPES)[0], body = '{}') => ({ schemaVersion: 1, audience,
  method: 'POST', path, bodySha256: hash(body), scope: SCOPES[path] });

// Test-only reconstruction of a pre-v3 file. No production downgrade exists.
export function downgradeStoreFixture(path, version) {
  if (version !== 1 && version !== 2) throw new Error('unsupported fixture version');
  const db = new DatabaseSync(path);
  try {
    db.exec(`
      BEGIN IMMEDIATE;
      DROP TRIGGER legacy_credential_identity_no_update;
      DROP TRIGGER legacy_credential_metadata_no_delete;
      DROP TRIGGER legacy_credential_metadata_no_update;
      DROP TRIGGER legacy_credential_metadata_owner_insert;
      DROP TRIGGER storage_bindings_no_delete;
      DROP TRIGGER storage_bindings_no_update;
      DROP TABLE legacy_credential_metadata;
      DROP TABLE storage_bindings;
      ${version === 1 ? 'DROP TABLE backup_heads; DROP TABLE backup_operations;' : ''}
      CREATE TABLE meta_previous (id INTEGER PRIMARY KEY CHECK(id=1), wall INTEGER NOT NULL CHECK(wall>=0), observed INTEGER NOT NULL CHECK(observed>=0), version INTEGER NOT NULL CHECK(version=${version})) STRICT;
      INSERT INTO meta_previous SELECT id,wall,observed,${version} FROM meta;
      DROP TABLE meta;
      ALTER TABLE meta_previous RENAME TO meta;
      PRAGMA user_version=${version};
      COMMIT;
    `);
  } finally { db.close(); }
}
// Deliberately noncryptographic server-only doubles. Never exported from src or
// configured by an environment variable/production fallback.
export function verifier(overrides = {}) {
  return {
    async bootstrap({ ceremony, credential, walletProof }) {
      return { walletBindingHash: hash(walletProof.publicKey), credential: {
        id: credential.id, publicKey: b64(8), userHandle: ceremony.userHandle, counter: 0, deviceType: 'multiDevice', backedUp: true,
      } };
    },
    async authentication({ registeredCredential }) {
      return { credentialId: registeredCredential.id, newCounter: registeredCredential.counter + 1, deviceType: registeredCredential.deviceType, backedUp: registeredCredential.backedUp };
    },
    async enrollment({ ceremony, credential }) {
      return { credential: { id: credential.id, publicKey: b64(9), userHandle: ceremony.userHandle, counter: 0, deviceType: 'multiDevice', backedUp: true } };
    },
    ...overrides,
  };
}
export function setup(t, options = {}) {
  const dir = mkdtempSync(join(tmpdir(), 'fearless-owner-test-'));
  const path = join(dir, 'authority.sqlite');
  const clock = { wall: 1_800_000_000_000, mono: 0 };
  const config = { path, audience, now: () => clock.wall, monotonic: () => clock.mono, verifier: verifier(), ...options };
  const instances = [];
  const open = (extra = {}) => {
    const core = createOwnerAuthority({ ...config, ...extra });
    instances.push(core);
    return core;
  };
  const core = open({ create: true });
  t.after(() => {
    for (const instance of instances) { try { instance.close(); } catch {} }
    rmSync(dir, { recursive: true, force: true });
  });
  const bootstrap = async (instance = core, id = b64(2), key = proof.publicKey) => {
    const challenge = instance.beginBootstrap('android');
    const owner = await instance.completeBootstrap({ ceremonyId: challenge.ceremonyId, credential: register(id), walletProof: { ...proof, publicKey: key } });
    return { owner, challenge };
  };
  return { core, path, dir, clock, open, bootstrap };
}
