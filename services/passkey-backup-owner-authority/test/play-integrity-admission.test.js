import assert from 'node:assert/strict';
import test from 'node:test';
import { createPlayIntegrityBootstrapVerifier } from '../src/play-integrity-admission.js';
import { AuthorityError } from '../src/validation.js';

const packageName = 'io.fearless.wallet';
const signingCertificateSha256 = 'a5'.repeat(32);
const application = `android:${packageName}:${signingCertificateSha256}`;
const nonce = Buffer.alloc(32, 0xc4).toString('base64url');
const attestationToken = 'A'.repeat(128);
const at = 1_797_000_000_000;
const input = Object.freeze({ platform: 'android', expectedNonce: nonce,
  expectedApplication: application,
  attestation: Object.freeze({ kind: 'play-integrity', token: attestationToken }) });

function verdict() {
  return {
    tokenPayloadExternal: {
      requestDetails: { requestPackageName: packageName, requestHash: nonce,
        timestampMillis: String(at - 1000) },
      appIntegrity: { appRecognitionVerdict: 'PLAY_RECOGNIZED', packageName,
        certificateSha256Digest: [Buffer.from(signingCertificateSha256, 'hex').toString('base64url')],
        versionCode: '420' },
      accountDetails: { appLicensingVerdict: 'LICENSED' },
      deviceIntegrity: { deviceRecognitionVerdict: ['MEETS_DEVICE_INTEGRITY'] },
    },
  };
}

function makeVerifier({ payload = verdict(), getAccessToken, fetchImpl, now = () => at } = {}) {
  return createPlayIntegrityBootstrapVerifier({ packageName, signingCertificateSha256,
    allowedVersionCodes: ['420'], now,
    getAccessToken: getAccessToken ?? (async () => 'ya29.test_access_token'),
    fetchImpl: fetchImpl ?? (async () => Response.json(payload)),
  });
}

function denied(error) {
  return error instanceof AuthorityError && error.code === 'verification_failed' &&
    !error.message.includes(attestationToken) && !error.message.includes('ya29.');
}

test('Google decode is server-owned, fixed-host and returns only bound admission', async () => {
  let oauth;
  let request;
  const verify = makeVerifier({
    getAccessToken: async (value) => { oauth = value; return 'ya29.test_access_token'; },
    fetchImpl: async (...args) => { request = args; return Response.json(verdict()); },
  });
  assert.deepEqual(await verify(input), { platform: 'android', nonce, application });
  assert.equal(oauth.scope, 'https://www.googleapis.com/auth/playintegrity');
  assert.equal(request[0], `https://playintegrity.googleapis.com/v1/${packageName}:decodeIntegrityToken`);
  assert.equal(request[1].method, 'POST');
  assert.equal(request[1].redirect, 'error');
  assert.equal(request[1].headers.authorization, 'Bearer ya29.test_access_token');
  assert.deepEqual(JSON.parse(request[1].body), { integrityToken: attestationToken });
});

test('bad caller input cannot obtain a service account token or call Google', async () => {
  let calls = 0;
  const verify = makeVerifier({ getAccessToken: async () => { calls += 1; return 'ya29.test_access_token'; },
    fetchImpl: async () => { calls += 1; return Response.json(verdict()); } });
  for (const override of [
    { platform: 'ios' }, { expectedApplication: 'android:attacker:0'.repeat(3) },
    { expectedNonce: 'A'.repeat(42) },
    { attestation: { kind: 'play-integrity', token: 'short' } },
    { attestation: { kind: 'play-integrity', token: attestationToken, prfOutput: 'secret' } },
  ]) await assert.rejects(verify({ ...input, ...override }), denied);
  assert.equal(calls, 0);
});

for (const [name, mutate] of [
  ['wrong request hash', (p) => { p.requestDetails.requestHash = 'A'.repeat(43); }],
  ['wrong request package', (p) => { p.requestDetails.requestPackageName = 'com.attacker.app'; }],
  ['classic nonce substitution', (p) => { delete p.requestDetails.requestHash; p.requestDetails.nonce = nonce; }],
  ['stale request', (p) => { p.requestDetails.timestampMillis = String(at - 120_001); }],
  ['future request', (p) => { p.requestDetails.timestampMillis = String(at + 30_001); }],
  ['malformed timestamp', (p) => { p.requestDetails.timestampMillis = '1e12'; }],
  ['unrecognized app', (p) => { p.appIntegrity.appRecognitionVerdict = 'UNRECOGNIZED_VERSION'; }],
  ['wrong app package', (p) => { p.appIntegrity.packageName = 'com.attacker.app'; }],
  ['wrong Play signing certificate', (p) => { p.appIntegrity.certificateSha256Digest = [Buffer.alloc(32, 3).toString('base64url')]; }],
  ['wrong version code', (p) => { p.appIntegrity.versionCode = '421'; }],
  ['unlicensed install', (p) => { p.accountDetails.appLicensingVerdict = 'UNLICENSED'; }],
  ['uncertified device', (p) => { p.deviceIntegrity.deviceRecognitionVerdict = ['MEETS_BASIC_INTEGRITY']; }],
  ['cleared replay verdict', (p) => { p.appIntegrity.appRecognitionVerdict = 'UNEVALUATED';
    p.deviceIntegrity.deviceRecognitionVerdict = []; }],
  ['Play Console testing override', (p) => { p.testingDetails = { isTestingResponse: true }; }],
]) {
  test(`denies ${name}`, async () => {
    const payload = verdict();
    mutate(payload.tokenPayloadExternal);
    await assert.rejects(makeVerifier({ payload })(input), denied);
  });
}

test('Google error, redirect, malformed and oversized responses fail closed', async () => {
  for (const response of [
    new Response('failure', { status: 401 }),
    new Response('redirect', { status: 302, headers: { location: 'https://attacker.invalid' } }),
    new Response('not json', { headers: { 'content-type': 'text/plain' } }),
    new Response('{', { headers: { 'content-type': 'application/json' } }),
    Response.json({ tokenPayloadExternal: null }),
    Response.json({ padding: 'x'.repeat(65_536) }),
  ]) await assert.rejects(makeVerifier({ fetchImpl: async () => response })(input), denied);
  await assert.rejects(makeVerifier({ getAccessToken: async () => { throw new Error('private key'); } })(input), denied);
  await assert.rejects(makeVerifier({ fetchImpl: async () => { throw new Error('bearer token'); } })(input), denied);
});

test('configuration requires a concrete Play identity and release version allowlist', () => {
  for (const override of [
    { packageName: 'UNCONFIGURED' }, { signingCertificateSha256: 'UNCONFIGURED' },
    { allowedVersionCodes: [] }, { allowedVersionCodes: ['420', '420'] },
  ]) assert.throws(() => createPlayIntegrityBootstrapVerifier({ packageName,
    signingCertificateSha256, allowedVersionCodes: ['420'],
    getAccessToken: async () => 'ya29.test_access_token', ...override }),
  (error) => error instanceof AuthorityError && error.code === 'invalid_configuration');
});
