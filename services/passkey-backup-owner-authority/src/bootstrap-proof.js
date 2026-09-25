import { createHash, createPublicKey, ECDH, verify } from 'node:crypto';
import { RP_ID, base64, credentialResponse, deny, opaque, platform, walletProof } from './validation.js';

const WALLET_DOMAIN = Buffer.from('FP_OWNER_BOOTSTRAP_WALLET_V1\0', 'ascii');
const ATTESTATION_DOMAIN = Buffer.from('FP_OWNER_BOOTSTRAP_APP_V1\0', 'ascii');
const BINDING_DOMAIN = Buffer.from('FP_OWNER_WALLET_BINDING_V1\0', 'ascii');
const ED25519_SPKI = Buffer.from('302a300506032b6570032100', 'hex');
const SECP256K1_SPKI = Buffer.from('3056301006072a8648ce3d020106052b8104000a034200', 'hex');

function sha256(bytes) { return createHash('sha256').update(bytes).digest(); }
function field(bytes) {
  const content = Buffer.isBuffer(bytes) ? bytes : Buffer.from(bytes, 'utf8');
  const length = Buffer.alloc(4);
  length.writeUInt32BE(content.length);
  return Buffer.concat([length, content]);
}
function credentialCommitment(credential) {
  // Fixed positional encoding prevents JSON key order from changing the signed
  // meaning. Every public registration field accepted by credentialResponse is
  // included; absent optional fields are represented by null.
  const response = credentialResponse(credential, 'registration');
  return sha256(Buffer.from(JSON.stringify([
    response.id, response.rawId, response.type,
    response.authenticatorAttachment ?? null,
    response.clientExtensionResults.credProps?.rk ?? null,
    response.response.clientDataJSON,
    response.response.attestationObject,
    response.response.authenticatorData ?? null,
    response.response.publicKeyAlgorithm ?? null,
    response.response.publicKey ?? null,
    response.response.transports ?? null,
  ]), 'utf8'));
}

/** Binary FP_OWNER_BOOTSTRAP_WALLET_V1 message; all fields are length-prefixed. */
export function bootstrapWalletMessage(ceremony, credential) {
  if (!ceremony || ceremony.kind !== 'bootstrap' || ceremony.rpId !== RP_ID) deny('verification_failed');
  opaque(ceremony.ceremonyId, 'ceremony.');
  base64(ceremony.challenge, 32, 32);
  base64(ceremony.userHandle, 32, 32);
  opaque(ceremony.subject, 'owner:');
  opaque(ceremony.namespace, 'backup:');
  platform(ceremony.platform);
  return Buffer.concat([
    WALLET_DOMAIN,
    field(ceremony.ceremonyId),
    field(Buffer.from(ceremony.challenge, 'base64url')),
    field(RP_ID),
    field(ceremony.platform),
    field(ceremony.subject),
    field(ceremony.namespace),
    field(Buffer.from(ceremony.userHandle, 'base64url')),
    field(credentialCommitment(credential)),
  ]);
}

function verificationKey(proof) {
  const bytes = Buffer.from(proof.publicKey, 'base64url');
  if (proof.scheme === 'ed25519') {
    if (bytes.length !== 32) deny('verification_failed');
    return { key: createPublicKey({ key: Buffer.concat([ED25519_SPKI, bytes]), format: 'der', type: 'spki' }),
      normalizedKey: bytes, algorithm: null };
  }
  if (proof.scheme === 'secp256k1') {
    if (bytes.length !== 33 && bytes.length !== 65) deny('verification_failed');
    const uncompressed = ECDH.convertKey(bytes, 'secp256k1', undefined, undefined, 'uncompressed');
    const compressed = ECDH.convertKey(bytes, 'secp256k1', undefined, undefined, 'compressed');
    return { key: createPublicKey({ key: Buffer.concat([SECP256K1_SPKI, uncompressed]), format: 'der', type: 'spki' }),
      normalizedKey: compressed, algorithm: 'sha256' };
  }
  // Node's built-in crypto has no SR25519 verifier. Never reinterpret this
  // scheme as Ed25519 or admit a claimed signature via another curve.
  deny('verifier_unavailable');
}

export function verifyBootstrapWalletProof(ceremony, credential, input) {
  const proof = walletProof(input);
  const message = bootstrapWalletMessage(ceremony, credential);
  let key;
  try { key = verificationKey(proof); }
  catch (error) {
    if (error?.code === 'verifier_unavailable') throw error;
    deny('verification_failed');
  }
  const signature = Buffer.from(proof.signature, 'base64url');
  if (signature.length !== 64) deny('verification_failed');
  let valid = false;
  try {
    valid = verify(key.algorithm, message,
      key.algorithm === null ? key.key : { key: key.key, dsaEncoding: 'ieee-p1363' }, signature);
  } catch { deny('verification_failed'); }
  if (!valid) deny('verification_failed');
  const walletBindingHash = sha256(Buffer.concat([
    BINDING_DOMAIN, field(proof.scheme), field(key.normalizedKey),
  ])).toString('base64url');
  const attestationNonce = sha256(Buffer.concat([
    ATTESTATION_DOMAIN, field(message), field(proof.scheme),
    field(key.normalizedKey), field(signature),
  ])).toString('base64url');
  return Object.freeze({ walletBindingHash, attestationNonce });
}
