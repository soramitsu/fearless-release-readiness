import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { readFileSync } from 'node:fs';
import { test } from 'node:test';
import { decodeCBOR } from '@levischuck/tiny-cbor';
import {
  createAppleAppAttestReceiptVerifier,
} from '../src/apple-app-attest-receipt.js';

// Apple's published example signs a production ATTEST receipt. It uses raw
// challenge bytes as clientDataHash and is only valid at its historical time;
// it is not evidence for our native SHA-256 ceremony or a live Apple service.
const sample = JSON.parse(readFileSync(new URL('./apple-app-attest-sample.json', import.meta.url)));
const object = decodeCBOR(Uint8Array.from(Buffer.from(sample.attestationObject, 'base64url')));
const leaf = Buffer.from(object.get('attStmt').get('x5c')[0]);
const receipt = Buffer.from(object.get('attStmt').get('receipt'));
const nowMillis = Date.parse(sample.sampleTime);
const proof = () => ({
  receipt,
  application: `ios:${sample.teamId}:${sample.bundleId}`,
  keyId: Buffer.from(sample.keyId, 'base64').toString('base64url'),
  attestationCertificateSha256: createHash('sha256').update(leaf).digest('hex'),
  clientDataHash: Buffer.from(sample.clientDataHash, 'utf8'),
});
const verifyAt = (time) => createAppleAppAttestReceiptVerifier({ now: () => time });
const denied = (request, time = nowMillis) => assert.rejects(verifyAt(time)(request),
  (error) => error.code === 'verification_failed' && error.message === 'verification_failed');

test('Apple published fraud receipt verifies signed content, pinned chain and bound fields', async () => {
  const verify = verifyAt(nowMillis);
  assert.equal(await verify(proof()), true);
  assert.throws(() => createAppleAppAttestReceiptVerifier({ now: 1 }),
    (error) => error.code === 'invalid_configuration');
});

test('Apple receipt rejects wrong application, attested key and server challenge', async () => {
  await denied({ ...proof(), application: `ios:${sample.teamId}:com.example.other` });
  await denied({ ...proof(), keyId: Buffer.alloc(32).toString('base64url') });
  await denied({ ...proof(), attestationCertificateSha256: '0'.repeat(64) });
  await denied({ ...proof(), clientDataHash: Buffer.from('other-challenge') });
});

test('Apple receipt rejects stale, future and malformed receipt bytes', async () => {
  await denied(proof(), nowMillis + 5 * 60 * 1000);
  await denied(proof(), nowMillis - 1000);
  const tampered = Buffer.from(receipt); tampered[tampered.length - 20] ^= 1;
  await denied({ ...proof(), receipt: tampered });
  await denied({ ...proof(), receipt: Buffer.concat([receipt, Buffer.from([0])]) });
  await denied({ ...proof(), receipt: receipt.subarray(0, receipt.length - 1) });
});
