import { createHash, generateKeyPairSync, sign } from 'node:crypto';
import { base64UrlDecode, base64UrlEncode } from '../src/base64url.js';
import { RP_ID } from '../src/validation.js';

function cborHeader(major, value) {
  if (!Number.isInteger(value) || value < 0) throw new Error('CBOR length must be a non-negative integer');
  if (value < 24) return Buffer.from([(major << 5) | value]);
  if (value <= 0xff) return Buffer.from([(major << 5) | 24, value]);
  if (value <= 0xffff) {
    const output = Buffer.alloc(3);
    output[0] = (major << 5) | 25;
    output.writeUInt16BE(value, 1);
    return output;
  }
  const output = Buffer.alloc(5);
  output[0] = (major << 5) | 26;
  output.writeUInt32BE(value, 1);
  return output;
}

function cborInteger(value) {
  return value >= 0 ? cborHeader(0, value) : cborHeader(1, -1 - value);
}

function cborBytes(value) {
  const bytes = Buffer.from(value);
  return Buffer.concat([cborHeader(2, bytes.length), bytes]);
}

function cborText(value) {
  const bytes = Buffer.from(value, 'utf8');
  return Buffer.concat([cborHeader(3, bytes.length), bytes]);
}

function cborMap(entries) {
  return Buffer.concat([
    cborHeader(5, entries.length),
    ...entries.flatMap(([key, value]) => [key, value]),
  ]);
}

function uint16(value) {
  const output = Buffer.alloc(2);
  output.writeUInt16BE(value);
  return output;
}

function uint32(value) {
  const output = Buffer.alloc(4);
  output.writeUInt32BE(value);
  return output;
}

function clientData(challenge, type, origin, extra = {}) {
  return Buffer.from(JSON.stringify({ type, challenge, origin, crossOrigin: false, ...extra }));
}

function rpIdHash(rpId) {
  return createHash('sha256').update(rpId).digest();
}

export function createAuthenticator(seed = 'fearless-test-passkey', { algorithm = -7 } = {}) {
  if (algorithm !== -7 && algorithm !== -257) {
    throw new Error('test authenticator algorithm must be ES256 or RS256');
  }
  const keyPair = algorithm === -7
    ? generateKeyPairSync('ec', { namedCurve: 'prime256v1' })
    : generateKeyPairSync('rsa', { modulusLength: 2048, publicExponent: 0x10001 });
  const credentialId = createHash('sha256').update(seed).digest();
  const publicJwk = keyPair.publicKey.export({ format: 'jwk' });
  const credentialPublicKey = algorithm === -7
    ? cborMap([
      [cborInteger(1), cborInteger(2)],
      [cborInteger(3), cborInteger(-7)],
      [cborInteger(-1), cborInteger(1)],
      [cborInteger(-2), cborBytes(base64UrlDecode(publicJwk.x, 'jwk.x', 128))],
      [cborInteger(-3), cborBytes(base64UrlDecode(publicJwk.y, 'jwk.y', 128))],
    ])
    : cborMap([
      [cborInteger(1), cborInteger(3)],
      [cborInteger(3), cborInteger(-257)],
      [cborInteger(-1), cborBytes(base64UrlDecode(publicJwk.n, 'jwk.n', 1024))],
      [cborInteger(-2), cborBytes(base64UrlDecode(publicJwk.e, 'jwk.e', 16))],
    ]);
  return { algorithm, keyPair, credentialId, credentialPublicKey };
}

export function registrationCredential(challenge, authenticator, {
  origin = 'https://wallet.example.test',
  rpId = RP_ID,
  flags = 0x45,
  clientDataExtra = {},
} = {}) {
  const rawClientData = clientData(challenge, 'webauthn.create', origin, clientDataExtra);
  const authData = Buffer.concat([
    rpIdHash(rpId),
    Buffer.from([flags]),
    uint32(0),
    Buffer.alloc(16),
    uint16(authenticator.credentialId.length),
    authenticator.credentialId,
    authenticator.credentialPublicKey,
  ]);
  const attestationObject = cborMap([
    [cborText('fmt'), cborText('none')],
    [cborText('attStmt'), cborMap([])],
    [cborText('authData'), cborBytes(authData)],
  ]);
  const id = base64UrlEncode(authenticator.credentialId);
  return {
    id,
    rawId: id,
    type: 'public-key',
    authenticatorAttachment: 'platform',
    clientExtensionResults: {},
    response: {
      clientDataJSON: base64UrlEncode(rawClientData),
      attestationObject: base64UrlEncode(attestationObject),
      transports: ['internal'],
      publicKeyAlgorithm: authenticator.algorithm,
    },
  };
}

export function authenticationCredential(challenge, authenticator, userHandle, {
  origin = 'https://wallet.example.test',
  rpId = RP_ID,
  flags = 0x05,
  counter = 1,
  credentialId = authenticator.credentialId,
  clientDataExtra = {},
} = {}) {
  const rawClientData = clientData(challenge, 'webauthn.get', origin, clientDataExtra);
  const authenticatorData = Buffer.concat([rpIdHash(rpId), Buffer.from([flags]), uint32(counter)]);
  const clientDataHash = createHash('sha256').update(rawClientData).digest();
  const signature = sign('sha256', Buffer.concat([authenticatorData, clientDataHash]), authenticator.keyPair.privateKey);
  const id = base64UrlEncode(credentialId);
  return {
    id,
    rawId: id,
    type: 'public-key',
    authenticatorAttachment: 'platform',
    clientExtensionResults: {},
    response: {
      clientDataJSON: base64UrlEncode(rawClientData),
      authenticatorData: base64UrlEncode(authenticatorData),
      signature: base64UrlEncode(signature),
      userHandle,
    },
  };
}
