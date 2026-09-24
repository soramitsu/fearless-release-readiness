import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { readFileSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { DatabaseSync } from 'node:sqlite';
import test from 'node:test';
import {
  authenticationCredential, createAuthenticator,
} from '../../passkey-backup-challenge-service/test/webauthn-fixture.js';
import { createWebAuthnVerifier } from '../src/webauthn-verifier.js';
import { readOwnerCredentialSnapshot } from '../src/store.js';
import { hash } from '../src/validation.js';
import { b64, setup, verifier as fakeVerifier } from './fixtures.js';

const storageKey = 'storage:signed-cutover';
const androidOrigin = `android:apk-key-hash:${Buffer.alloc(32, 0xa5).toString('base64url')}`;
const originPolicy = { android: [androidOrigin], ios: ['https://fearlesswallet.io'] };
const realVerifier = createWebAuthnVerifier({ allowedOrigins: originPolicy });
const sha256 = (value) => createHash('sha256').update(value).digest('hex');

function denied(promise, code = 'verification_failed') {
  return assert.rejects(promise, (error) => error.code === code, `expected ${code}`);
}

function database(path, action) {
  const db = new DatabaseSync(path);
  try { return action(db); }
  finally { db.close(); }
}

function row(path, id) {
  return database(path, (db) => db.prepare('SELECT * FROM legacy_cutover_challenges WHERE id=?').get(id));
}

function signedResponse(challenge, authenticator, userHandle, credentialId, options = {}) {
  const { authenticatorAttachment, ...rest } = authenticationCredential(
    challenge, authenticator, userHandle,
    { origin: androidOrigin, flags: 0x1d, counter: 1, credentialId: Buffer.from(credentialId, 'base64url'),
      ...options });
  void authenticatorAttachment;
  return rest;
}

async function fixture(t, { onVerify, wrongSourceKey = false } = {}) {
  const adapter = { ...fakeVerifier(),
    async legacyCutoverAssertion(input) {
      const evidence = await realVerifier.legacyCutoverAssertion(input);
      if (onVerify) await onVerify(input);
      return evidence;
    },
  };
  const item = setup(t, { verifier: adapter });
  const { owner } = await item.bootstrap();
  const ownerCredential = readOwnerCredentialSnapshot(item.path).credentials[0];
  const ownerAuthenticator = createAuthenticator(`cutover-owner-${item.dir}`);
  const legacyAuthenticator = createAuthenticator(`cutover-legacy-${item.dir}`);
  const sourceAuthenticator = wrongSourceKey
    ? createAuthenticator(`cutover-other-source-${item.dir}`) : legacyAuthenticator;
  const legacyId = Buffer.from(legacyAuthenticator.credentialId).toString('base64url');
  const legacyUserHandle = hash(`user\0${storageKey}`);
  database(item.path, (db) => db.prepare('UPDATE credentials SET public_key=?,counter=1 WHERE id=?')
    .run(Buffer.from(ownerAuthenticator.credentialPublicKey).toString('base64url'), ownerCredential.id));
  const source = {
    schemaVersion: 4,
    credentialOwnersById: [{ credentialId: legacyId, storageKey,
      ownerSubjectHash: hash('signed-cutover-source-owner') }],
    credentialsByStorageKey: [{ storageKey, ownerSubjectHash: hash('signed-cutover-source-owner'),
      credentials: [{ id: legacyId,
        publicKey: Buffer.from(sourceAuthenticator.credentialPublicKey).toString('base64url'),
        userId: legacyUserHandle, counter: 7, deviceType: 'multiDevice', backedUp: true,
        aaguid: '00000000-0000-0000-0000-000000000000', registrationPlatform: 'ios',
        transports: ['internal'] }] }],
  };
  const sourceBytes = Buffer.from(`${JSON.stringify(source)}\n`);
  const expectedSourceSha256 = sha256(sourceBytes);
  const legacySnapshotPath = join(item.dir, `legacy-${expectedSourceSha256}.json`);
  writeFileSync(legacySnapshotPath, sourceBytes, { mode: 0o600 });
  const issued = item.core.issueLegacyCutoverChallenge(owner.sessionToken, {
    schemaVersion: 1, legacySnapshotPath, expectedSourceSha256, storageKey, credentialId: legacyId,
  });
  const input = { schemaVersion: 1, challengeId: issued.challengeId,
    legacySnapshotPath, expectedSourceSha256,
    legacyAssertion: signedResponse(issued.legacyChallenge, legacyAuthenticator,
      legacyUserHandle, legacyId, { counter: 8 }),
    ownerAssertion: signedResponse(issued.ownerChallenge, ownerAuthenticator,
      ownerCredential.user_handle, ownerCredential.id, { counter: 2 }),
  };
  return { ...item, owner, ownerCredential, ownerAuthenticator, legacyAuthenticator,
    legacyId, legacyUserHandle, source, sourceBytes, issued, input };
}

test('two signed, role-separated assertions verify and consume only a read-only cutover claim', async (t) => {
  const item = await fixture(t);
  const before = readOwnerCredentialSnapshot(item.path);
  const result = await item.core.verifyAndConsumeLegacyCutoverClaim(item.owner.sessionToken, item.input);
  assert.deepEqual(result, { schemaVersion: 1, challengeId: item.issued.challengeId,
    state: 'consumed-after-verification', expiresAt: item.issued.expiresAt,
    migrationPermitted: false });
  assert.equal(row(item.path, item.issued.challengeId).state, 2);
  await denied(item.core.verifyAndConsumeLegacyCutoverClaim(item.owner.sessionToken, item.input),
    'authorization_failed');
  const after = readOwnerCredentialSnapshot(item.path);
  assert.deepEqual(after.credentials, before.credentials);
  assert.deepEqual(after.storageBindings, []);
  assert.deepEqual(readFileSync(item.input.legacySnapshotPath), item.sourceBytes);
});

test('directed signed assertions can omit both user handles', async (t) => {
  const item = await fixture(t);
  item.input.legacyAssertion.response.userHandle = null;
  item.input.ownerAssertion.response.userHandle = null;
  const result = await item.core.verifyAndConsumeLegacyCutoverClaim(item.owner.sessionToken, item.input);
  assert.equal(result.migrationPermitted, false);
  assert.equal(row(item.path, item.issued.challengeId).state, 2);
});

test('a signature made by a different legacy key cannot pass the sealed source key', async (t) => {
  const item = await fixture(t, { wrongSourceKey: true });
  await denied(item.core.verifyAndConsumeLegacyCutoverClaim(item.owner.sessionToken, item.input));
  assert.equal(row(item.path, item.issued.challengeId).state, 1);
});

test('legacy or owner signature, challenge, origin, RP, flags, handle and counter failures burn the claim', async (t) => {
  const cases = [
    ['legacy signature', (item) => { item.input.legacyAssertion.response.signature = b64(99, 64); }],
    ['owner signature', (item) => { item.input.ownerAssertion.response.signature = b64(99, 64); }],
    ['legacy challenge', (item) => { item.input.legacyAssertion = signedResponse(item.issued.ownerChallenge,
      item.legacyAuthenticator, item.legacyUserHandle, item.legacyId, { counter: 8 }); }],
    ['owner challenge', (item) => { item.input.ownerAssertion = signedResponse(item.issued.legacyChallenge,
      item.ownerAuthenticator, item.ownerCredential.user_handle, item.ownerCredential.id); }],
    ['origin', (item) => { item.input.legacyAssertion = signedResponse(item.issued.legacyChallenge,
      item.legacyAuthenticator, item.legacyUserHandle, item.legacyId,
      { counter: 8, origin: 'https://fearlesswallet.io' }); }],
    ['RP', (item) => { item.input.ownerAssertion = signedResponse(item.issued.ownerChallenge,
      item.ownerAuthenticator, item.ownerCredential.user_handle, item.ownerCredential.id,
      { rpId: 'evil.example' }); }],
    ['presence', (item) => { item.input.legacyAssertion = signedResponse(item.issued.legacyChallenge,
      item.legacyAuthenticator, item.legacyUserHandle, item.legacyId, { counter: 8, flags: 0x1c }); }],
    ['verification', (item) => { item.input.ownerAssertion = signedResponse(item.issued.ownerChallenge,
      item.ownerAuthenticator, item.ownerCredential.user_handle, item.ownerCredential.id,
      { flags: 0x19 }); }],
    ['legacy handle', (item) => { item.input.legacyAssertion.response.userHandle = b64(87); }],
    ['owner handle', (item) => { item.input.ownerAssertion.response.userHandle = b64(87); }],
    ['legacy ID', (item) => { item.input.legacyAssertion = signedResponse(item.issued.legacyChallenge,
      item.legacyAuthenticator, item.legacyUserHandle, b64(86), { counter: 8 }); }],
    ['owner ID', (item) => { item.input.ownerAssertion = signedResponse(item.issued.ownerChallenge,
      item.ownerAuthenticator, item.ownerCredential.user_handle, b64(86), { counter: 2 }); }],
    ['legacy counter', (item) => { item.input.legacyAssertion = signedResponse(item.issued.legacyChallenge,
      item.legacyAuthenticator, item.legacyUserHandle, item.legacyId, { counter: 7 }); }],
    ['owner counter', (item) => { item.input.ownerAssertion = signedResponse(item.issued.ownerChallenge,
      item.ownerAuthenticator, item.ownerCredential.user_handle, item.ownerCredential.id,
      { counter: 1 }); }],
  ];
  for (const [name, mutate] of cases) {
    await t.test(name, async (subtest) => {
      const item = await fixture(subtest);
      mutate(item);
      await assert.rejects(item.core.verifyAndConsumeLegacyCutoverClaim(
        item.owner.sessionToken, item.input));
      assert.equal(row(item.path, item.issued.challengeId).state,
        name.endsWith('handle') || name.endsWith('ID') ? 0 : 1);
      await denied(item.core.verifyAndConsumeLegacyCutoverClaim(item.owner.sessionToken, item.input),
        'authorization_failed');
    });
  }
});

test('verified assertions fail at commit when the owner or sealed source changes during verification', async (t) => {
  for (const [name, change] of [
    ['counter', (item) => database(item.path, (db) => db.prepare(
      'UPDATE credentials SET counter=counter+1 WHERE id=?').run(item.ownerCredential.id))],
    ['revocation', (item) => database(item.path, (db) => db.prepare(
      'UPDATE credentials SET revoked=1 WHERE id=?').run(item.ownerCredential.id))],
    ['generation', (item) => item.core.revokeSessions(item.owner.sessionToken)],
    ['public key', (item) => database(item.path, (db) => db.prepare(
      'UPDATE credentials SET public_key=? WHERE id=?').run(b64(11), item.ownerCredential.id))],
    ['source bytes', (item) => writeFileSync(item.input.legacySnapshotPath,
      Buffer.from('changed sealed source'), { mode: 0o600 })],
    ['expiry', (item) => { item.clock.mono += 121_000; }],
  ]) {
    await t.test(name, async (subtest) => {
      let item;
      let changed = false;
      item = await fixture(subtest, { onVerify(input) {
        if (input.role === 'OWNER' && !changed) { changed = true; change(item); }
      } });
      await assert.rejects(item.core.verifyAndConsumeLegacyCutoverClaim(
        item.owner.sessionToken, item.input));
      assert.equal(row(item.path, item.issued.challengeId).state, 1);
    });
  }
});

test('one concurrent verifier wins the durable claim', async (t) => {
  const item = await fixture(t);
  const results = await Promise.allSettled([
    item.core.verifyAndConsumeLegacyCutoverClaim(item.owner.sessionToken, item.input),
    item.core.verifyAndConsumeLegacyCutoverClaim(item.owner.sessionToken, item.input),
  ]);
  assert.equal(results.filter((result) => result.status === 'fulfilled').length, 1);
  assert.equal(row(item.path, item.issued.challengeId).state, 2);
});
