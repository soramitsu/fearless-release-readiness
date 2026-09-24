import { appAttestation, deny } from './validation.js';
import { GoogleAuth } from 'google-auth-library';

const PACKAGE_NAME = /^[a-zA-Z][a-zA-Z0-9_]*(?:\.[a-zA-Z][a-zA-Z0-9_]*)+$/u;
const SHA256_HEX = /^[a-f0-9]{64}$/u;
const VERSION_CODE = /^[1-9][0-9]{0,18}$/u;
const OAUTH_TOKEN = /^[A-Za-z0-9._~-]{16,4096}$/u;
const SERVICE_ACCOUNT_EMAIL = /^[a-z0-9][a-z0-9._-]{1,127}@[a-z0-9][a-z0-9.-]+\.gserviceaccount\.com$/u;
const PLAY_INTEGRITY_SCOPE = 'https://www.googleapis.com/auth/playintegrity';
const MAX_VERDICT_BYTES = 64 * 1024;
const MAX_TOKEN_AGE_MS = 120_000;
const MAX_FUTURE_SKEW_MS = 30_000;
const REQUEST_TIMEOUT_MS = 5_000;

/**
 * Server-only ADC provider. The operator pins the service-account identity;
 * a developer's local user ADC or a substituted workload identity is refused.
 * GoogleAuth owns refresh and caches credentials; the token is never returned
 * to a mobile caller or persisted by the owner authority.
 */
export function createPlayIntegrityAdcAccessTokenProvider({ expectedServiceAccountEmail,
  authFactory = () => new GoogleAuth({ scopes: PLAY_INTEGRITY_SCOPE }) } = {}) {
  if (typeof expectedServiceAccountEmail !== 'string' ||
      !SERVICE_ACCOUNT_EMAIL.test(expectedServiceAccountEmail) ||
      typeof authFactory !== 'function') deny('invalid_configuration');
  const auth = authFactory();
  if (!auth || typeof auth.getCredentials !== 'function' ||
      typeof auth.getAccessToken !== 'function') deny('invalid_configuration');
  return async function getAccessToken({ scope, signal } = {}) {
    if (scope !== PLAY_INTEGRITY_SCOPE || !(signal instanceof AbortSignal) || signal.aborted) {
      deny('verification_failed');
    }
    try {
      const credentials = await auth.getCredentials();
      if (signal.aborted || credentials?.client_email !== expectedServiceAccountEmail ||
          (credentials.universe_domain !== undefined &&
            credentials.universe_domain !== 'googleapis.com')) deny('verification_failed');
      const token = await auth.getAccessToken();
      if (signal.aborted || typeof token !== 'string' || !OAUTH_TOKEN.test(token)) {
        deny('verification_failed');
      }
      return token;
    } catch {
      // Google auth failures and credentials may contain sensitive details.
      deny('verification_failed');
    }
  };
}

function object(value) {
  return value !== null && typeof value === 'object' && !Array.isArray(value);
}

function certificateDigest(value) {
  if (typeof value !== 'string' || !/^[A-Za-z0-9_-]{43}=?$/u.test(value)) return null;
  const bytes = Buffer.from(value, 'base64url');
  if (bytes.length !== 32 || bytes.toString('base64url') !== value.replace(/=$/u, '')) return null;
  return bytes.toString('hex');
}

async function boundedJson(response) {
  if (!response.ok || !response.body ||
      !response.headers.get('content-type')?.toLowerCase().startsWith('application/json')) {
    deny('verification_failed');
  }
  const claimedLength = response.headers.get('content-length');
  if (claimedLength !== null && (!/^[0-9]+$/u.test(claimedLength) ||
      Number(claimedLength) > MAX_VERDICT_BYTES)) deny('verification_failed');
  const chunks = [];
  let length = 0;
  for await (const chunk of response.body) {
    length += chunk.byteLength;
    if (length > MAX_VERDICT_BYTES) deny('verification_failed');
    chunks.push(Buffer.from(chunk));
  }
  if (length === 0) deny('verification_failed');
  return JSON.parse(Buffer.concat(chunks, length).toString('utf8'));
}

function verifiedVerdict(payload, { packageName, signingCertificateSha256, versionCodes,
  expectedNonce, nowMillis }) {
  if (!object(payload) || !object(payload.requestDetails) || !object(payload.appIntegrity) ||
      !object(payload.deviceIntegrity) || !object(payload.accountDetails) ||
      (payload.testingDetails !== undefined &&
        (!object(payload.testingDetails) || payload.testingDetails.isTestingResponse !== false))) {
    deny('verification_failed');
  }
  const request = payload.requestDetails;
  const timestamp = request.timestampMillis;
  if (request.requestPackageName !== packageName || request.requestHash !== expectedNonce ||
      Object.hasOwn(request, 'nonce') || typeof timestamp !== 'string' ||
      !/^[1-9][0-9]{12}$/u.test(timestamp)) deny('verification_failed');
  const age = nowMillis - Number(timestamp);
  if (!Number.isSafeInteger(nowMillis) || age > MAX_TOKEN_AGE_MS ||
      age < -MAX_FUTURE_SKEW_MS) deny('verification_failed');

  const app = payload.appIntegrity;
  if (app.appRecognitionVerdict !== 'PLAY_RECOGNIZED' ||
      app.packageName !== packageName || !versionCodes.has(app.versionCode) ||
      !Array.isArray(app.certificateSha256Digest) ||
      !app.certificateSha256Digest.some((digest) =>
        certificateDigest(digest) === signingCertificateSha256)) deny('verification_failed');
  if (payload.accountDetails.appLicensingVerdict !== 'LICENSED' ||
      !Array.isArray(payload.deviceIntegrity.deviceRecognitionVerdict) ||
      !payload.deviceIntegrity.deviceRecognitionVerdict.includes('MEETS_DEVICE_INTEGRITY')) {
    deny('verification_failed');
  }
}

/**
 * Server-owned Google Play standard-token admission for first-owner bootstrap.
 * The access-token callback must use a service account scoped to
 * https://www.googleapis.com/auth/playintegrity. Neither it nor fetchImpl may
 * be supplied by a mobile request. The production HTTP listener remains gated.
 */
export function createPlayIntegrityBootstrapVerifier({ packageName, signingCertificateSha256,
  allowedVersionCodes, getAccessToken, fetchImpl = globalThis.fetch, now = Date.now } = {}) {
  if (typeof packageName !== 'string' || !PACKAGE_NAME.test(packageName) ||
      typeof signingCertificateSha256 !== 'string' ||
      !SHA256_HEX.test(signingCertificateSha256) ||
      !Array.isArray(allowedVersionCodes) || allowedVersionCodes.length === 0 ||
      allowedVersionCodes.length > 32 ||
      allowedVersionCodes.some((code) => typeof code !== 'string' || !VERSION_CODE.test(code)) ||
      new Set(allowedVersionCodes).size !== allowedVersionCodes.length ||
      typeof getAccessToken !== 'function' || typeof fetchImpl !== 'function' ||
      typeof now !== 'function') deny('invalid_configuration');
  const versionCodes = new Set(allowedVersionCodes);
  const application = `android:${packageName}:${signingCertificateSha256}`;
  const url = `https://playintegrity.googleapis.com/v1/${packageName}:decodeIntegrityToken`;

  return async function verifyAppAttestation(input) {
    // Validate before requesting a server credential or making a network call.
    if (!object(input) || input.platform !== 'android' ||
        input.expectedApplication !== application ||
        typeof input.expectedNonce !== 'string' ||
        !/^[A-Za-z0-9_-]{43}$/u.test(input.expectedNonce) ||
        Buffer.from(input.expectedNonce, 'base64url').toString('base64url') !== input.expectedNonce) {
      deny('verification_failed');
    }
    let attestation;
    try { attestation = appAttestation(input.attestation, 'android'); }
    catch { deny('verification_failed'); }
    const controller = new AbortController();
    const timeout = setTimeout(() => controller.abort(), REQUEST_TIMEOUT_MS);
    const aborted = new Promise((_, reject) => {
      controller.signal.addEventListener('abort', () => reject(new Error('timeout')), { once: true });
    });
    try {
      const accessToken = await Promise.race([
        getAccessToken({ scope: PLAY_INTEGRITY_SCOPE,
          signal: controller.signal }), aborted,
      ]);
      if (typeof accessToken !== 'string' || !OAUTH_TOKEN.test(accessToken)) deny('verification_failed');
      const response = await Promise.race([fetchImpl(url, {
        method: 'POST', redirect: 'error', signal: controller.signal,
        headers: { authorization: `Bearer ${accessToken}`, 'content-type': 'application/json' },
        body: JSON.stringify({ integrityToken: attestation.token }),
      }), aborted]);
      const decoded = await Promise.race([boundedJson(response), aborted]);
      if (!object(decoded) || !object(decoded.tokenPayloadExternal)) deny('verification_failed');
      verifiedVerdict(decoded.tokenPayloadExternal, { packageName, signingCertificateSha256,
        versionCodes, expectedNonce: input.expectedNonce, nowMillis: now() });
      return Object.freeze({ platform: 'android', nonce: input.expectedNonce, application });
    } catch {
      // Never reflect Google's response, bearer token, attestation token or
      // remote error body into an HTTP response or log from this adapter.
      deny('verification_failed');
    } finally { clearTimeout(timeout); }
  };
}
