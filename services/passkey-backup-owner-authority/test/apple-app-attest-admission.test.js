import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { test } from 'node:test';
import { decodeCBOR, encodeCBOR } from '@levischuck/tiny-cbor';
import {
  createAppleAppAttestBootstrapVerifier, verifyAppleAppAttestObject,
} from '../src/apple-app-attest-admission.js';

// Apple's public guide is a parser/chain/nonce vector. Its sample passes the
// challenge bytes directly as clientDataHash, unlike our native SHA-256 input;
// it cannot establish native ceremony interoperability or live receipt trust.
const sample = JSON.parse(readFileSync(new URL('./apple-app-attest-sample.json', import.meta.url)));
const keyId = Buffer.from(sample.keyId, 'base64');
const objectBytes = Buffer.from(sample.attestationObject, 'base64');
const args = () => ({
  attestationObject: objectBytes, keyId,
  clientDataHash: Buffer.from(sample.clientDataHash, 'utf8'),
  teamId: sample.teamId, bundleId: sample.bundleId,
  allowedBundleVersions: new Set([sample.bundleVersion]),
  nowMillis: Date.parse(sample.sampleTime),
});
const denied = (operation) => assert.throws(operation,
  (error) => error.code === 'verification_failed' && error.message === 'verification_failed');
function mutateObject(change) {
  const object = decodeCBOR(Uint8Array.from(objectBytes));
  change(object);
  return Buffer.from(encodeCBOR(object));
}

test('Apple published production App Attest object validates against the pinned root', () => {
  const evidence = verifyAppleAppAttestObject(args());
  assert.equal(evidence.keyId, keyId.toString('base64url'));
  assert.ok(evidence.receipt.length > 0);
});

test('Apple App Attest rejects swapped key, challenge, app, version and expiry', () => {
  const changedId = Buffer.from(keyId); changedId[0] ^= 1;
  denied(() => verifyAppleAppAttestObject({ ...args(), keyId: changedId }));
  denied(() => verifyAppleAppAttestObject({ ...args(), clientDataHash: Buffer.from('other') }));
  denied(() => verifyAppleAppAttestObject({ ...args(), teamId: 'ABCDE12345' }));
  denied(() => verifyAppleAppAttestObject({ ...args(), bundleId: 'com.example.other' }));
  denied(() => verifyAppleAppAttestObject({ ...args(), allowedBundleVersions: new Set(['2']) }));
  denied(() => verifyAppleAppAttestObject({ ...args(), nowMillis: Date.parse('2026-09-24') }));
});

test('Apple App Attest rejects tampered certificate, authenticator and extension bytes', () => {
  const badCert = mutateObject((object) => {
    const chain = object.get('attStmt').get('x5c');
    const leaf = Uint8Array.from(chain[0]); leaf[250] ^= 1; chain[0] = leaf;
  });
  denied(() => verifyAppleAppAttestObject({ ...args(), attestationObject: badCert }));

  const badAuthenticator = mutateObject((object) => {
    const auth = Uint8Array.from(object.get('authData')); auth[32] = 0;
    object.set('authData', auth);
  });
  denied(() => verifyAppleAppAttestObject({ ...args(), attestationObject: badAuthenticator }));

  const badExtension = mutateObject((object) => {
    const auth = Uint8Array.from(object.get('authData')); auth[auth.length - 1] ^= 1;
    object.set('authData', auth);
  });
  denied(() => verifyAppleAppAttestObject({ ...args(), attestationObject: badExtension }));
});

test('Apple adapter hardwires receipt verification and refuses invalid ceremonies', async () => {
  assert.throws(() => createAppleAppAttestBootstrapVerifier({
    teamId: 'ABCDE12345', bundleId: 'io.soramitsu.fearless',
    allowedBundleVersions: ['1'], verifyReceipt: async () => true,
  }), (error) => error.code === 'invalid_configuration');
  const verify = createAppleAppAttestBootstrapVerifier({
    teamId: 'ABCDE12345', bundleId: 'io.soramitsu.fearless',
    allowedBundleVersions: ['1'],
  });
  for (const input of [
    { platform: 'android', expectedApplication: 'ios:ABCDE12345:io.soramitsu.fearless',
      expectedNonce: Buffer.alloc(32).toString('base64url') },
    { platform: 'ios', expectedApplication: 'ios:wrong',
      expectedNonce: Buffer.alloc(32).toString('base64url') },
    { platform: 'ios', expectedApplication: 'ios:ABCDE12345:io.soramitsu.fearless',
      expectedNonce: 'not-canonical' },
    { platform: 'ios', expectedApplication: 'ios:ABCDE12345:io.soramitsu.fearless',
      expectedNonce: Buffer.alloc(32).toString('base64url'),
      attestation: { kind: 'app-attest', keyId: keyId.toString('base64url'),
        attestationObject: objectBytes.toString('base64url') } },
  ]) {
    await assert.rejects(verify(input), (error) => error.code === 'verification_failed' &&
      error.message === 'verification_failed');
  }
});
