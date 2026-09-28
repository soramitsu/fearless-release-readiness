import { createHash, timingSafeEqual, X509Certificate } from 'node:crypto';
import { readFileSync } from 'node:fs';
import * as asn1js from 'asn1js';
import {
  KeyUsageFlags, KeyUsagesExtension, X509Certificate as ParsedCertificate,
} from '@peculiar/x509';
import { Certificate, ContentInfo, SignedData } from 'pkijs';
import { deny } from './validation.js';

// Apple Root CA - G3 from https://www.apple.com/certificateauthority/.
// Its DER SHA-256 is also published in Apple's platform trust-store inventory.
const ROOT_DER = readFileSync(new URL('./apple-root-ca-g3.cer', import.meta.url));
const ROOT_SHA256 = '63343abfb89a6a03ebb57e9b3f5fa7be7c4f5c756f3017b3a8c488c3653e9179';
if (createHash('sha256').update(ROOT_DER).digest('hex') !== ROOT_SHA256) {
  throw new Error('Apple receipt root pin mismatch');
}
const ROOT = Certificate.fromBER(Uint8Array.from(ROOT_DER));
const RECEIPT_SIGNING_OID = '1.2.840.113635.100.12.15';
const MAX_AGE_MS = 5 * 60 * 1000;

function bytes(value, min, max) {
  if (!(value instanceof Uint8Array) || value.byteLength < min || value.byteLength > max) {
    deny('verification_failed');
  }
  return Buffer.from(value);
}

function equal(a, b) {
  return a.length === b.length && timingSafeEqual(a, b);
}

function attributeBytes(attribute) {
  if (!(attribute instanceof asn1js.OctetString) || attribute.idBlock.isConstructed) {
    deny('verification_failed');
  }
  return Buffer.from(attribute.valueBlock.valueHexView);
}

function receiptAttributes(content) {
  const parsed = asn1js.fromBER(Uint8Array.from(bytes(content, 1, 8192)));
  if (parsed.offset !== content.length || !(parsed.result instanceof asn1js.Set)) {
    deny('verification_failed');
  }
  const rows = parsed.result.valueBlock.value;
  if (rows.length < 6 || rows.length > 32) deny('verification_failed');
  const result = new Map();
  for (const row of rows) {
    if (!(row instanceof asn1js.Sequence) || row.valueBlock.value.length !== 3) {
      deny('verification_failed');
    }
    const [type, version, value] = row.valueBlock.value;
    if (!(type instanceof asn1js.Integer) || !(version instanceof asn1js.Integer) ||
        !Number.isSafeInteger(type.valueBlock.valueDec) || type.valueBlock.valueDec < 1 ||
        version.valueBlock.valueDec !== 1 || result.has(type.valueBlock.valueDec)) {
      deny('verification_failed');
    }
    result.set(type.valueBlock.valueDec, attributeBytes(value));
  }
  return result;
}

function textField(fields, id, maxLength) {
  const value = bytes(fields.get(id), 1, maxLength);
  return new TextDecoder('utf-8', { fatal: true }).decode(value);
}

function timeField(fields, id) {
  const value = textField(fields, id, 32);
  if (!/^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d\.\d{3}Z$/u.test(value)) {
    deny('verification_failed');
  }
  const millis = Date.parse(value);
  if (!Number.isSafeInteger(millis) || new Date(millis).toISOString() !== value) {
    deny('verification_failed');
  }
  return millis;
}

function certificateKeyId(der) {
  const jwk = new X509Certificate(der).publicKey.export({ format: 'jwk' });
  if (jwk.kty !== 'EC' || jwk.crv !== 'P-256' ||
      typeof jwk.x !== 'string' || typeof jwk.y !== 'string') deny('verification_failed');
  const x = Buffer.from(jwk.x, 'base64url');
  const y = Buffer.from(jwk.y, 'base64url');
  if (x.length !== 32 || y.length !== 32 ||
      x.toString('base64url') !== jwk.x || y.toString('base64url') !== jwk.y) {
    deny('verification_failed');
  }
  return createHash('sha256').update(Buffer.concat([Buffer.from([4]), x, y]))
    .digest('base64url');
}

/**
 * Verify the CMS fraud receipt embedded in an App Attest object. The original
 * receipt must be fresh and refer to this exact signed attestation leaf,
 * application and client-data hash. This does not query Apple's risk metric.
 */
async function verifyAppleAppAttestReceipt({ receipt, application, keyId,
  attestationCertificateSha256, clientDataHash, nowMillis }) {
  try {
    const raw = bytes(receipt, 256, 16384);
    const clientHash = bytes(clientDataHash, 1, 64);
    if (typeof application !== 'string' ||
        !/^ios:[A-Z0-9]{10}:[A-Za-z][A-Za-z0-9-]*(?:\.[A-Za-z][A-Za-z0-9-]*)+$/u.test(application) ||
        typeof keyId !== 'string' || !/^[A-Za-z0-9_-]{43}$/u.test(keyId) ||
        typeof attestationCertificateSha256 !== 'string' ||
        !/^[a-f0-9]{64}$/u.test(attestationCertificateSha256) ||
        !Number.isSafeInteger(nowMillis) || nowMillis < 0) deny('verification_failed');

    const decoded = asn1js.fromBER(Uint8Array.from(raw));
    if (decoded.offset !== raw.length) deny('verification_failed');
    const info = new ContentInfo({ schema: decoded.result });
    if (info.contentType !== ContentInfo.SIGNED_DATA) deny('verification_failed');
    const signed = new SignedData({ schema: info.content });
    if (signed.signerInfos.length !== 1 || !signed.certificates ||
        signed.certificates.length < 2 || signed.certificates.length > 6 ||
        signed.encapContentInfo.eContentType !== ContentInfo.DATA ||
        !signed.encapContentInfo.eContent) deny('verification_failed');
    const verification = await signed.verify({
      signer: 0, checkChain: true, trustedCerts: [ROOT],
      checkDate: new Date(nowMillis), extendedMode: true,
    });
    if (verification.signatureVerified !== true ||
        verification.signerCertificateVerified !== true ||
        !verification.signerCertificate) deny('verification_failed');
    const signerBytes = Buffer.from(verification.signerCertificate.toSchema().toBER(false));
    const signer = new X509Certificate(signerBytes);
    const parsedSigner = new ParsedCertificate(signerBytes);
    const usage = parsedSigner.getExtension(KeyUsagesExtension)?.usages;
    if (signer.ca || (usage & KeyUsageFlags.digitalSignature) === 0 ||
        parsedSigner.getExtensions(RECEIPT_SIGNING_OID).length !== 1) {
      deny('verification_failed');
    }

    const fields = receiptAttributes(
      Buffer.from(signed.encapContentInfo.eContent.getValue()));
    const leaf = bytes(fields.get(3), 256, 8192);
    if (textField(fields, 2, 256) !== application.slice(4).replace(':', '.') ||
        !equal(createHash('sha256').update(leaf).digest(),
          Buffer.from(attestationCertificateSha256, 'hex')) ||
        certificateKeyId(leaf) !== keyId ||
        !equal(bytes(fields.get(4), 1, 64), clientHash) ||
        textField(fields, 6, 16) !== 'ATTEST' ||
        textField(fields, 7, 16) !== 'production') deny('verification_failed');

    const created = timeField(fields, 12);
    // Field 19 is the earliest allowed refresh time, not a validity start.
    if (created > nowMillis || nowMillis - created > MAX_AGE_MS ||
        (fields.has(21) && timeField(fields, 21) <= nowMillis)) deny('verification_failed');
    return true;
  } catch { deny('verification_failed'); }
}

export function createAppleAppAttestReceiptVerifier({ now = Date.now } = {}) {
  if (typeof now !== 'function') deny('invalid_configuration');
  return (input) => verifyAppleAppAttestReceipt({ ...input, nowMillis: now() });
}
