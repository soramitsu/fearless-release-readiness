#!/usr/bin/env node
import { createHash } from 'node:crypto';
import { lstatSync, realpathSync } from 'node:fs';
import { spawn } from 'node:child_process';
import { isAbsolute } from 'node:path';
import { pathToFileURL } from 'node:url';

const SERVICE_ID = 'fearless-passkey-backup';
const RP_ID = 'fearlesswallet.io';
const SCHEMA_VERSION = 1;
const DEFAULT_BASE_URL = 'https://backup.fearlesswallet.io';
const DEFAULT_TIMEOUT_MS = 10_000;
const MAX_TIMEOUT_MS = 60_000;
const DEFAULT_MAX_RESPONSE_BYTES = 1_048_576;
const MAX_RESPONSE_BYTES = 5_242_880;
const DEFAULT_GRANT_HELPER_TIMEOUT_MS = 2_000;
const BODY_PREVIEW_LIMIT = 500;
const DIAGNOSTIC_LIMIT = 300;
const DIAGNOSTIC_SCAN_LIMIT = 4_096;
const DEPLOYMENT_HINT = 'Verify backup.fearlesswallet.io DNS/TLS/routing and deploy services/passkey-backup-challenge-service.';

const PATHS = Object.freeze({
  health: '/api/passkey-backup/v1/health',
  registrationChallenge: '/api/passkey-backup/v1/registration/challenge',
  registrationComplete: '/api/passkey-backup/v1/registration/complete',
  assertionChallenge: '/api/passkey-backup/v1/assertion/challenge',
  assertionComplete: '/api/passkey-backup/v1/assertion/complete',
  credentialsList: '/api/passkey-backup/v1/credentials/list',
  credentialsRevoke: '/api/passkey-backup/v1/credentials/revoke',
  credentialsRevokeAll: '/api/passkey-backup/v1/credentials/revoke-all',
});

const IDENTIFIER_RE = /^[A-Za-z0-9._:-]{8,128}$/;
const BASE64URL_32_BYTE_RE = /^[A-Za-z0-9_-]{43}$/;
const BEARER_TOKEN_RE = /^[A-Za-z0-9._~+\/-]+={0,}$/;
const JSON_CONTENT_TYPE = /^application\/(?:json|[a-z0-9!#$&^_.+-]+\+json)(?:\s*;\s*[a-z0-9!#$%&'*+.^_`|~-]+\s*=\s*(?:[a-z0-9!#$%&'*+.^_`|~-]+|"[^"\r\n]*"))*\s*$/i;

function assert(condition, message) {
  if (!condition) {
    throw new Error(message);
  }
}

function redactSecrets(value) {
  return value
    .replace(/("(?:access[_-]?token|refresh[_-]?token|token|password|passwd|api[-_]?key|secret|authorization|cookie|set-cookie)"\s*:\s*)(?:"(?:\\.|[^"\\])*"|[^,}\]\s]+)/gi, '$1"<redacted>"')
    .replace(/(\b(?:bearer|basic)\s+)[A-Za-z0-9+/=_~.-]+/gi, '$1<redacted>')
    .replace(/(https?:\/\/)[^/\s@]+@/gi, '$1<redacted>@')
    .replace(/([?&](?:access[_-]?token|refresh[_-]?token|token|password|passwd|api[-_]?key|secret|authorization|key)=)[^&#\s]*/gi, '$1<redacted>')
    .replace(/(\b(?:access[_-]?token|refresh[_-]?token|token|password|passwd|api[-_]?key|secret|authorization)\b\s*[:=]\s*)(?:["'][^"'\r\n]*["']|[^\s,;&]+)/gi, '$1<redacted>');
}

function bodyPreview(text) {
  const normalized = redactSecrets(String(text ?? '').slice(0, DIAGNOSTIC_SCAN_LIMIT))
    .replace(/[\n\r\t]+/g, ' ')
    .replace(/\s+/g, ' ')
    .trim();
  if (normalized.length === 0) {
    return '<empty body>';
  }
  return normalized.length > BODY_PREVIEW_LIMIT ? `${normalized.slice(0, BODY_PREVIEW_LIMIT)}...` : normalized;
}

function diagnosticPreview(value) {
  const normalized = redactSecrets(String(value ?? '').slice(0, DIAGNOSTIC_SCAN_LIMIT))
    .replace(/[\u0000-\u001f\u007f]+/g, ' ')
    .replace(/\s+/g, ' ')
    .trim();
  if (!normalized) return '<empty>';
  return normalized.length > DIAGNOSTIC_LIMIT ? `${normalized.slice(0, DIAGNOSTIC_LIMIT)}...` : normalized;
}

function requestFailureReason(error, timeoutMs) {
  if (error?.name === 'AbortError' || error instanceof RequestTimeoutError) {
    return `timed out after ${timeoutMs}ms`;
  }
  const message = error instanceof Error && error.message ? diagnosticPreview(error.message) : diagnosticPreview(error);
  if (error?.cause) {
    return diagnosticPreview(`${message}; cause: ${formatFailureCause(error.cause)}`);
  }
  return message;
}

function formatFailureCause(cause, depth = 0) {
  if (depth >= 3) return '<nested cause omitted>';
  if (cause === null || cause === undefined) {
    return diagnosticPreview(cause);
  }

  const details = [];
  if (cause instanceof Error && cause.message) {
    details.push(diagnosticPreview(cause.message));
  } else if (typeof cause === 'object') {
    details.push(diagnosticPreview(cause.message || cause));
  } else {
    details.push(diagnosticPreview(cause));
  }

  const metadata = ['code', 'errno', 'syscall', 'hostname', 'address', 'port']
    .map((key) => {
      const value = cause?.[key];
      return value === undefined || value === null || value === '' ? null : `${key}=${diagnosticPreview(value)}`;
    })
    .filter(Boolean);
  if (metadata.length > 0) {
    details.push(metadata.join(', '));
  }

  if (cause?.cause) {
    details.push(`cause: ${formatFailureCause(cause.cause, depth + 1)}`);
  }

  return diagnosticPreview(details.join('; '));
}

class RequestTimeoutError extends Error {}
class ResponseTooLargeError extends Error {}
class RedirectRejectedError extends Error {
  constructor(status) {
    super(`redirect response HTTP ${status}`);
    this.status = status;
  }
}

function boundedInteger(value, name, fallback, max) {
  if (value === undefined) return fallback;
  const candidate = typeof value === 'string' ? value : String(value);
  if (!/^[1-9][0-9]*$/.test(candidate)) {
    throw new Error(`${name} must be an integer between 1 and ${max}`);
  }
  const parsed = Number(candidate);
  if (!Number.isSafeInteger(parsed) || parsed > max) {
    throw new Error(`${name} must be an integer between 1 and ${max}`);
  }
  return parsed;
}

async function withinDeadline(operation, controller, timeoutMs) {
  let timer;
  const timeout = new Promise((_resolve, reject) => {
    timer = setTimeout(() => {
      controller.abort();
      reject(new RequestTimeoutError(`timed out after ${timeoutMs}ms`));
    }, timeoutMs);
  });
  try {
    return await Promise.race([operation(), timeout]);
  } finally {
    clearTimeout(timer);
  }
}

async function readBoundedBody(response, maxResponseBytes) {
  const contentLength = response.headers?.get?.('content-length');
  if (contentLength && /^(?:0|[1-9][0-9]*)$/.test(contentLength)) {
    const declared = Number(contentLength);
    if (Number.isSafeInteger(declared) && declared > maxResponseBytes) {
      throw new ResponseTooLargeError(`declared ${declared} bytes`);
    }
  }

  if (!response.body?.getReader) {
    const text = await response.text();
    if (Buffer.byteLength(text, 'utf8') > maxResponseBytes) {
      throw new ResponseTooLargeError(`received more than ${maxResponseBytes} bytes`);
    }
    return text;
  }

  const reader = response.body.getReader();
  const decoder = new TextDecoder('utf-8', { fatal: true });
  let bytes = 0;
  let text = '';
  try {
    while (true) {
      const { done, value } = await reader.read();
      if (done) break;
      bytes += value.byteLength;
      if (bytes > maxResponseBytes) {
        void reader.cancel().catch(() => undefined);
        throw new ResponseTooLargeError(`received more than ${maxResponseBytes} bytes`);
      }
      text += decoder.decode(value, { stream: true });
    }
    text += decoder.decode();
    return text;
  } finally {
    reader.releaseLock();
  }
}

function isJsonContentType(value) {
  return JSON_CONTENT_TYPE.test(value.trim());
}

function normalizeBaseUrl(value) {
  const raw = value || DEFAULT_BASE_URL;
  const url = new URL(raw);
  if (url.username || url.password) {
    throw new Error('PASSKEY_BACKUP_BASE_URL must not contain credentials');
  }
  if (url.search || url.hash) {
    throw new Error('PASSKEY_BACKUP_BASE_URL must not contain query strings or fragments');
  }
  const isLocalhost = ['localhost', '127.0.0.1', '[::1]'].includes(url.hostname.toLowerCase());
  if (url.protocol !== 'https:' && !(url.protocol === 'http:' && isLocalhost)) {
    throw new Error('PASSKEY_BACKUP_BASE_URL must use HTTPS outside localhost smoke tests');
  }
  url.pathname = url.pathname.replace(/\/+$/, '');
  return url.toString().replace(/\/$/, '');
}

function parseHelperTimeout(value) {
  if (typeof value !== 'string' || !/^(0|[1-9][0-9]*)$/.test(value)) {
    throw new Error('PASSKEY_BACKUP_SMOKE_GRANT_HELPER_TIMEOUT_MS must be 100-10000');
  }
  const timeout = Number(value);
  if (!Number.isSafeInteger(timeout) || timeout < 100 || timeout > 10_000) {
    throw new Error('PASSKEY_BACKUP_SMOKE_GRANT_HELPER_TIMEOUT_MS must be 100-10000');
  }
  return timeout;
}

export function createExecutableSmokeAuthorizationProvider(
  helperPath,
  { timeoutMs = DEFAULT_GRANT_HELPER_TIMEOUT_MS } = {},
) {
  if (typeof helperPath !== 'string' || helperPath.length === 0 ||
      helperPath !== helperPath.trim() || !isAbsolute(helperPath)) {
    throw new Error('PASSKEY_BACKUP_SMOKE_GRANT_HELPER must be an absolute executable path without arguments');
  }
  if (!Number.isSafeInteger(timeoutMs) || timeoutMs < 100 || timeoutMs > 10_000) {
    throw new Error('smoke grant helper timeout must be 100-10000 milliseconds');
  }
  let stat;
  let realPath;
  try {
    stat = lstatSync(helperPath);
    realPath = realpathSync.native(helperPath);
  } catch (error) {
    throw new Error('PASSKEY_BACKUP_SMOKE_GRANT_HELPER must be a readable executable file');
  }
  if (!stat.isFile() || stat.isSymbolicLink() || realPath !== helperPath || (stat.mode & 0o111) === 0) {
    throw new Error('PASSKEY_BACKUP_SMOKE_GRANT_HELPER must be a non-symlink executable file');
  }
  if ((stat.mode & 0o022) !== 0) {
    throw new Error('PASSKEY_BACKUP_SMOKE_GRANT_HELPER must not be group- or world-writable');
  }

  return async ({ method, path, bodySha256 }) => new Promise((resolve, reject) => {
    const child = spawn(helperPath, [], {
      shell: false,
      stdio: ['pipe', 'pipe', 'pipe'],
    });
    const stdout = [];
    let stdoutBytes = 0;
    let stderrBytes = 0;
    let failed = false;
    const fail = () => {
      if (failed) return;
      failed = true;
      child.kill('SIGKILL');
      reject(new Error('smoke grant helper failed'));
    };
    const timer = setTimeout(fail, timeoutMs);
    child.stdout.on('data', (chunk) => {
      stdoutBytes += chunk.length;
      if (stdoutBytes > 4097) {
        fail();
        return;
      }
      stdout.push(Buffer.from(chunk));
    });
    child.stderr.on('data', (chunk) => {
      stderrBytes += chunk.length;
      if (stderrBytes > 16 * 1024) fail();
    });
    child.once('error', fail);
    child.once('close', (code, signal) => {
      clearTimeout(timer);
      if (failed) return;
      if (code !== 0 || signal !== null) {
        fail();
        return;
      }
      const raw = Buffer.concat(stdout, stdoutBytes).toString('utf8');
      const token = raw.endsWith('\n') ? raw.slice(0, -1) : raw;
      if (token.length === 0 || token.length > 4096 || raw !== token && raw !== `${token}\n` ||
          !BEARER_TOKEN_RE.test(token)) {
        fail();
        return;
      }
      resolve(token);
    });
    child.stdin.on('error', fail);
    child.stdin.end(`${JSON.stringify({
      schemaVersion: 1,
      method,
      path,
      bodySha256,
    })}\n`);
  });
}

function exactKeys(value, keys, context) {
  assert(value !== null && typeof value === 'object' && !Array.isArray(value), `${context} must be a JSON object`);
  const expected = new Set(keys);
  for (const key of keys) {
    assert(Object.prototype.hasOwnProperty.call(value, key), `${context} missing ${key}`);
  }
  for (const key of Object.keys(value)) {
    assert(expected.has(key), `${context} contains unsupported field ${key}`);
  }
}

function assertIdentity(value, context, ok) {
  assert(value.ok === ok, `${context}.ok must be ${ok}`);
  assert(value.service === SERVICE_ID, `${context}.service must be ${SERVICE_ID}`);
  assert(value.rpId === RP_ID, `${context}.rpId must be ${RP_ID}`);
  assert(value.schemaVersion === SCHEMA_VERSION, `${context}.schemaVersion must be ${SCHEMA_VERSION}`);
}

function isCanonicalBase64Url32(value) {
  if (typeof value !== 'string' || !BASE64URL_32_BYTE_RE.test(value)) return false;
  const decoded = Buffer.from(value, 'base64url');
  return decoded.length === 32 && decoded.toString('base64url') === value;
}

function assertHealth(value) {
  exactKeys(value, ['ok', 'service', 'rpId', 'schemaVersion'], 'health response');
  assertIdentity(value, 'health response', true);
}

function assertServiceError(value, expectedError, context) {
  exactKeys(value, ['ok', 'service', 'error', 'rpId', 'schemaVersion'], `${context} error response`);
  assertIdentity(value, `${context} error response`, false);
  assert(value.error === expectedError, `${context} error must be ${expectedError}`);
}

function assertRegistrationChallenge(value, request) {
  exactKeys(
    value,
    ['registrationId', 'challenge', 'userId', 'userName', 'displayName', 'storageKey', 'rpId', 'schemaVersion'],
    'registration challenge response',
  );
  assert(IDENTIFIER_RE.test(value.registrationId), 'registrationId must use the public ceremony-id format');
  assert(isCanonicalBase64Url32(value.challenge), 'registration challenge must be canonical unpadded base64url for 32 bytes');
  assert(isCanonicalBase64Url32(value.userId), 'registration userId must be canonical unpadded base64url for 32 bytes');
  assert(IDENTIFIER_RE.test(value.storageKey), 'registration storageKey must use the public storage-key format');
  assert(value.userName === request.accountName, 'registration userName must echo accountName');
  assert(value.displayName === request.displayName, 'registration displayName must echo displayName');
  assert(value.rpId === RP_ID, `registration rpId must be ${RP_ID}`);
  assert(value.schemaVersion === SCHEMA_VERSION, `registration schemaVersion must be ${SCHEMA_VERSION}`);
}

function assertCredentialRevoke(value, request) {
  exactKeys(
    value,
    ['storageKey', 'credentialId', 'remainingCredentials', 'rpId', 'schemaVersion'],
    'credential revoke response',
  );
  assert(value.storageKey === request.storageKey, 'credential revoke storageKey must echo the request');
  assert(value.credentialId === request.credentialId, 'credential revoke credentialId must echo the request');
  assert(value.remainingCredentials === 0, 'unknown credential revoke must report zero remaining credentials');
  assert(value.rpId === RP_ID, `credential revoke rpId must be ${RP_ID}`);
  assert(value.schemaVersion === SCHEMA_VERSION, `credential revoke schemaVersion must be ${SCHEMA_VERSION}`);
}

function assertCredentialRevokeAll(value, request) {
  exactKeys(
    value,
    ['storageKey', 'remainingCredentials', 'rpId', 'schemaVersion'],
    'credential revoke-all response',
  );
  assert(value.storageKey === request.storageKey, 'credential revoke-all storageKey must echo the request');
  assert(value.remainingCredentials === 0, 'credential revoke-all must report zero remaining credentials');
  assert(value.rpId === RP_ID, `credential revoke-all rpId must be ${RP_ID}`);
  assert(value.schemaVersion === SCHEMA_VERSION, `credential revoke-all schemaVersion must be ${SCHEMA_VERSION}`);
}

function smokeRegistrationRequest() {
  const suffix = Date.now().toString(36);
  return {
    walletId: `smoke-wallet-${suffix}`,
    accountName: `passkey-smoke-${suffix}@fearlesswallet.io`,
    displayName: 'Fearless Passkey Smoke',
    rpId: RP_ID,
    schemaVersion: SCHEMA_VERSION,
  };
}

function syntheticCredential() {
  return {
    id: 'passkey-smoke-credential',
    response: {
      clientDataJSON: 'eyJzbW9rZSI6dHJ1ZX0',
    },
  };
}

async function requestJson({
  baseUrl,
  path,
  method = 'GET',
  body,
  expectedStatus,
  timeoutMs,
  maxResponseBytes,
  fetchImpl,
  authorizationProvider,
}) {
  const controller = new AbortController();
  let response;
  let text;
  try {
    ({ response, text } = await withinDeadline(async () => {
      const serializedBody = body === undefined ? undefined : JSON.stringify(body);
      let authorization;
      if (method === 'POST') {
        assert(
          typeof authorizationProvider === 'function',
          'PASSKEY_BACKUP_SMOKE_GRANT_HELPER or an injected authorizationProvider is required for POST smoke checks',
        );
        const token = await authorizationProvider({
          method,
          path,
          bodySha256: createHash('sha256').update(serializedBody).digest('base64url'),
        });
        assert(
          typeof token === 'string' && token.length > 0 && token.length <= 4096 &&
            BEARER_TOKEN_RE.test(token),
          'smoke authorization provider returned an invalid bearer token',
        );
        authorization = `Bearer ${token}`;
      }
      const received = await fetchImpl(`${baseUrl}${path}`, {
        method,
        headers: {
          accept: 'application/json',
          ...(body === undefined ? {} : { 'content-type': 'application/json' }),
          ...(authorization === undefined ? {} : { authorization }),
        },
        body: serializedBody,
        signal: controller.signal,
        redirect: 'manual',
      });
      if (received.status >= 300 && received.status < 400) {
        throw new RedirectRejectedError(received.status);
      }
      return {
        response: received,
        text: await readBoundedBody(received, maxResponseBytes),
      };
    }, controller, timeoutMs));
  } catch (error) {
    if (error instanceof RedirectRejectedError) {
      throw new Error(
        `${method} ${path} refused redirect HTTP ${error.status}; production smoke redirects are forbidden. ${DEPLOYMENT_HINT}`,
      );
    }
    if (error instanceof ResponseTooLargeError) {
      throw new Error(
        `${method} ${path} response exceeded the ${maxResponseBytes}-byte limit. ${DEPLOYMENT_HINT}`,
      );
    }
    throw new Error(
      `${method} ${path} request to ${baseUrl} failed: ${requestFailureReason(error, timeoutMs)}. ${DEPLOYMENT_HINT}`,
    );
  }
  assert(
    response.status === expectedStatus,
    `${method} ${path} expected HTTP ${expectedStatus}, got ${response.status}. Body preview: ${bodyPreview(text)}`,
  );
  const contentType = response.headers?.get?.('content-type') ?? '';
  assert(
    isJsonContentType(contentType),
    `${method} ${path} did not return JSON. Content-Type: ${contentType ? diagnosticPreview(contentType) : '<missing>'}. Body preview: ${bodyPreview(text)}`,
  );
  try {
    return JSON.parse(text);
  } catch (error) {
    throw new Error(`${method} ${path} must return valid JSON. Body preview: ${bodyPreview(text)}`);
  }
}

export async function runProductionSmoke({
  baseUrl = process.env.PASSKEY_BACKUP_BASE_URL,
  timeoutMs = process.env.PASSKEY_BACKUP_SMOKE_TIMEOUT_MS,
  maxResponseBytes = process.env.PASSKEY_BACKUP_SMOKE_MAX_RESPONSE_BYTES,
  fetchImpl = globalThis.fetch,
  authorizationProvider,
} = {}) {
  const boundedTimeoutMs = boundedInteger(
    timeoutMs,
    'PASSKEY_BACKUP_SMOKE_TIMEOUT_MS',
    DEFAULT_TIMEOUT_MS,
    MAX_TIMEOUT_MS,
  );
  const boundedMaxResponseBytes = boundedInteger(
    maxResponseBytes,
    'PASSKEY_BACKUP_SMOKE_MAX_RESPONSE_BYTES',
    DEFAULT_MAX_RESPONSE_BYTES,
    MAX_RESPONSE_BYTES,
  );
  assert(typeof fetchImpl === 'function', 'fetch implementation is required');
  const normalizedBaseUrl = normalizeBaseUrl(baseUrl);
  const effectiveAuthorizationProvider = authorizationProvider ?? (
    process.env.PASSKEY_BACKUP_SMOKE_GRANT_HELPER
      ? createExecutableSmokeAuthorizationProvider(
        process.env.PASSKEY_BACKUP_SMOKE_GRANT_HELPER,
        {
          timeoutMs: parseHelperTimeout(
            process.env.PASSKEY_BACKUP_SMOKE_GRANT_HELPER_TIMEOUT_MS ?? `${DEFAULT_GRANT_HELPER_TIMEOUT_MS}`,
          ),
        },
      )
      : undefined
  );

  const health = await requestJson({
    baseUrl: normalizedBaseUrl,
    path: PATHS.health,
    expectedStatus: 200,
    timeoutMs: boundedTimeoutMs,
    maxResponseBytes: boundedMaxResponseBytes,
    fetchImpl,
    authorizationProvider: effectiveAuthorizationProvider,
  });
  assertHealth(health);

  const registrationRequest = smokeRegistrationRequest();
  const registration = await requestJson({
    baseUrl: normalizedBaseUrl,
    path: PATHS.registrationChallenge,
    method: 'POST',
    body: registrationRequest,
    expectedStatus: 200,
    timeoutMs: boundedTimeoutMs,
    maxResponseBytes: boundedMaxResponseBytes,
    fetchImpl,
    authorizationProvider: effectiveAuthorizationProvider,
  });
  assertRegistrationChallenge(registration, registrationRequest);

  const assertionForUnregisteredCredential = await requestJson({
    baseUrl: normalizedBaseUrl,
    path: PATHS.assertionChallenge,
    method: 'POST',
    body: {
      storageKey: registration.storageKey,
      rpId: RP_ID,
      schemaVersion: SCHEMA_VERSION,
    },
    expectedStatus: 404,
    timeoutMs: boundedTimeoutMs,
    maxResponseBytes: boundedMaxResponseBytes,
    fetchImpl,
    authorizationProvider: effectiveAuthorizationProvider,
  });
  assertServiceError(
    assertionForUnregisteredCredential,
    'credential_not_registered',
    'assertion challenge for unregistered credential',
  );

  const unknownRegistration = await requestJson({
    baseUrl: normalizedBaseUrl,
    path: PATHS.registrationComplete,
    method: 'POST',
    body: {
      registrationId: 'reg:passkey-smoke-missing',
      rpId: RP_ID,
      credential: syntheticCredential(),
    },
    expectedStatus: 404,
    timeoutMs: boundedTimeoutMs,
    maxResponseBytes: boundedMaxResponseBytes,
    fetchImpl,
    authorizationProvider: effectiveAuthorizationProvider,
  });
  assertServiceError(unknownRegistration, 'unknown_or_expired_registration', 'registration completion');

  const unknownAssertion = await requestJson({
    baseUrl: normalizedBaseUrl,
    path: PATHS.assertionComplete,
    method: 'POST',
    body: {
      assertionId: 'assert:passkey-smoke-missing',
      rpId: RP_ID,
      credential: syntheticCredential(),
    },
    expectedStatus: 404,
    timeoutMs: boundedTimeoutMs,
    maxResponseBytes: boundedMaxResponseBytes,
    fetchImpl,
    authorizationProvider: effectiveAuthorizationProvider,
  });
  assertServiceError(unknownAssertion, 'unknown_or_expired_assertion', 'assertion completion');

  const lifecycleBaseRequest = {
    storageKey: registration.storageKey,
    rpId: RP_ID,
    schemaVersion: SCHEMA_VERSION,
  };
  const unknownCredentialList = await requestJson({
    baseUrl: normalizedBaseUrl,
    path: PATHS.credentialsList,
    method: 'POST',
    body: lifecycleBaseRequest,
    expectedStatus: 404,
    timeoutMs: boundedTimeoutMs,
    maxResponseBytes: boundedMaxResponseBytes,
    fetchImpl,
    authorizationProvider: effectiveAuthorizationProvider,
  });
  assertServiceError(
    unknownCredentialList,
    'credential_storage_not_registered',
    'credential list for unregistered storage',
  );

  const revokeRequest = {
    ...lifecycleBaseRequest,
    credentialId: registration.userId,
  };
  const unknownCredentialRevoke = await requestJson({
    baseUrl: normalizedBaseUrl,
    path: PATHS.credentialsRevoke,
    method: 'POST',
    body: revokeRequest,
    expectedStatus: 200,
    timeoutMs: boundedTimeoutMs,
    maxResponseBytes: boundedMaxResponseBytes,
    fetchImpl,
    authorizationProvider: effectiveAuthorizationProvider,
  });
  assertCredentialRevoke(unknownCredentialRevoke, revokeRequest);

  const unknownCredentialRevokeAll = await requestJson({
    baseUrl: normalizedBaseUrl,
    path: PATHS.credentialsRevokeAll,
    method: 'POST',
    body: lifecycleBaseRequest,
    expectedStatus: 200,
    timeoutMs: boundedTimeoutMs,
    maxResponseBytes: boundedMaxResponseBytes,
    fetchImpl,
    authorizationProvider: effectiveAuthorizationProvider,
  });
  assertCredentialRevokeAll(unknownCredentialRevokeAll, lifecycleBaseRequest);

  const listAfterUnknownRevocations = await requestJson({
    baseUrl: normalizedBaseUrl,
    path: PATHS.credentialsList,
    method: 'POST',
    body: lifecycleBaseRequest,
    expectedStatus: 404,
    timeoutMs: boundedTimeoutMs,
    maxResponseBytes: boundedMaxResponseBytes,
    fetchImpl,
    authorizationProvider: effectiveAuthorizationProvider,
  });
  assertServiceError(
    listAfterUnknownRevocations,
    'credential_storage_not_registered',
    'credential list after unknown revocations',
  );

  return {
    baseUrl: normalizedBaseUrl,
    service: SERVICE_ID,
    rpId: RP_ID,
    schemaVersion: SCHEMA_VERSION,
    checkedRoutes: Object.values(PATHS),
  };
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  runProductionSmoke()
    .then((result) => {
      console.log(`[passkey-production-smoke] all assertions passed for ${result.baseUrl}`);
    })
    .catch((error) => {
      console.error(`[passkey-production-smoke][error] ${error.message}`);
      process.exit(1);
    });
}
