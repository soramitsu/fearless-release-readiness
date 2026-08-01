import { createHash } from 'node:crypto';
import { serviceError } from './errors.js';

const AUTHORIZATION_RESPONSE_MAX_BYTES = 16 * 1024;
const DEFAULT_TIMEOUT_MS = 2_000;
const DEFAULT_MAX_TTL_SECONDS = 300;
const AUDIENCE_RE = /^[A-Za-z0-9._:-]{8,128}$/;
const SUBJECT_RE = /^[A-Za-z0-9._:@/-]{8,256}$/;
const BODY_SHA256_RE = /^[A-Za-z0-9_-]{43}$/;
const PLATFORMS = new Set(['android', 'ios']);

export const AUTHORIZATION_SCOPES = Object.freeze({
  '/api/passkey-backup/v1/registration/challenge': 'passkey.registration.challenge',
  '/api/passkey-backup/v1/registration/complete': 'passkey.registration.complete',
  '/api/passkey-backup/v1/assertion/challenge': 'passkey.assertion.challenge',
  '/api/passkey-backup/v1/assertion/complete': 'passkey.assertion.complete',
  '/api/passkey-backup/v1/credentials/list': 'passkey.credentials.list',
  '/api/passkey-backup/v1/credentials/revoke': 'passkey.credentials.revoke',
  '/api/passkey-backup/v1/credentials/revoke-all': 'passkey.credentials.revoke-all',
});

function authorizationFailed() {
  return serviceError(401, 'request_authorization_failed', 'Request authorization failed');
}

function authorizationUnavailable() {
  return serviceError(503, 'authorization_service_unavailable', 'Request authorization is temporarily unavailable');
}

function exactObject(value, required) {
  if (value === null || typeof value !== 'object' || Array.isArray(value)) return false;
  const keys = Object.keys(value);
  return keys.length === required.length &&
    required.every((field) => Object.prototype.hasOwnProperty.call(value, field));
}

function parseBoundedInteger(value, name, minimum, maximum) {
  if (typeof value !== 'string' || !/^(0|[1-9][0-9]*)$/.test(value)) {
    throw new Error(`${name} must be an integer between ${minimum} and ${maximum}`);
  }
  const parsed = Number(value);
  if (!Number.isSafeInteger(parsed) || parsed < minimum || parsed > maximum) {
    throw new Error(`${name} must be an integer between ${minimum} and ${maximum}`);
  }
  return parsed;
}

export function sha256Base64Url(value) {
  return createHash('sha256').update(value).digest('base64url');
}

export function authorizationSubjectHash(subject) {
  return sha256Base64Url(`authorization-subject\0${subject}`);
}

export function normalizeIntrospectionUrl(value) {
  if (typeof value !== 'string' || value.length === 0 || value !== value.trim()) {
    throw new Error('PASSKEY_AUTHORIZATION_INTROSPECTION_URL must be a canonical HTTPS URL');
  }
  let url;
  try {
    url = new URL(value);
  } catch (error) {
    throw new Error('PASSKEY_AUTHORIZATION_INTROSPECTION_URL must be a canonical HTTPS URL');
  }
  if (value.includes('%') || url.protocol !== 'https:' || url.username || url.password || url.search || url.hash ||
      url.pathname === '/' || url.href !== value) {
    throw new Error('PASSKEY_AUTHORIZATION_INTROSPECTION_URL must be a canonical HTTPS URL');
  }
  return url.href;
}

export function normalizeAuthorizationAudience(value) {
  if (typeof value !== 'string' || !AUDIENCE_RE.test(value)) {
    throw new Error('PASSKEY_AUTHORIZATION_AUDIENCE must be 8-128 URL-safe characters');
  }
  return value;
}

async function readBoundedResponse(response) {
  if (!response.body) return Buffer.alloc(0);
  const chunks = [];
  let total = 0;
  for await (const chunk of response.body) {
    total += chunk.length;
    if (total > AUTHORIZATION_RESPONSE_MAX_BYTES) {
      await response.body.cancel().catch(() => {});
      throw authorizationUnavailable();
    }
    chunks.push(Buffer.from(chunk));
  }
  return Buffer.concat(chunks, total);
}

export function createIntrospectionRequestAuthorizer({
  introspectionUrl,
  audience,
  timeoutMs = DEFAULT_TIMEOUT_MS,
  maxTtlSeconds = DEFAULT_MAX_TTL_SECONDS,
  fetchImpl = globalThis.fetch,
  now = () => Date.now(),
} = {}) {
  const normalizedUrl = normalizeIntrospectionUrl(introspectionUrl);
  const normalizedAudience = normalizeAuthorizationAudience(audience);
  if (!Number.isSafeInteger(timeoutMs) || timeoutMs < 100 || timeoutMs > 10_000) {
    throw new Error('authorization timeout must be 100-10000 milliseconds');
  }
  if (!Number.isSafeInteger(maxTtlSeconds) || maxTtlSeconds < 1 || maxTtlSeconds > 3_600) {
    throw new Error('authorization max TTL must be 1-3600 seconds');
  }
  if (typeof fetchImpl !== 'function') throw new Error('authorization fetch implementation is required');

  return Object.freeze({
    async authorize({ token, method, path, bodySha256 }) {
      const expectedScope = AUTHORIZATION_SCOPES[path];
      if (method !== 'POST' || !expectedScope || !BODY_SHA256_RE.test(bodySha256)) {
        throw authorizationFailed();
      }

      const controller = new AbortController();
      const timeout = setTimeout(() => controller.abort(), timeoutMs);
      let response;
      try {
        response = await fetchImpl(normalizedUrl, {
          method: 'POST',
          headers: {
            authorization: `Bearer ${token}`,
            'content-type': 'application/json',
            accept: 'application/json',
          },
          body: JSON.stringify({
            schemaVersion: 1,
            audience: normalizedAudience,
            method,
            path,
            bodySha256,
            scope: expectedScope,
          }),
          redirect: 'error',
          signal: controller.signal,
        });
      } catch (error) {
        clearTimeout(timeout);
        throw authorizationUnavailable();
      }

      try {
        if (response.status !== 200) {
        throw response.status === 401 || response.status === 403
          ? authorizationFailed()
          : authorizationUnavailable();
      }
      const contentType = String(response.headers?.get?.('content-type') ?? '')
        .split(';', 1)[0]
        .trim()
        .toLowerCase();
      if (contentType !== 'application/json') throw authorizationUnavailable();

      let authorization;
      try {
        const raw = await readBoundedResponse(response);
        authorization = JSON.parse(raw.toString('utf8'));
      } catch (error) {
        if (error?.code === 'authorization_service_unavailable') throw error;
        throw authorizationUnavailable();
      }
      const required = [
        'schemaVersion',
        'active',
        'subject',
        'audience',
        'method',
        'path',
        'bodySha256',
        'scope',
        'platform',
        'expiresAt',
      ];
      if (!exactObject(authorization, required) || authorization.schemaVersion !== 1 ||
          authorization.active !== true ||
          !SUBJECT_RE.test(authorization.subject) ||
          authorization.audience !== normalizedAudience || authorization.method !== method ||
          authorization.path !== path || authorization.bodySha256 !== bodySha256 ||
          authorization.scope !== expectedScope || !PLATFORMS.has(authorization.platform) ||
          !Number.isSafeInteger(authorization.expiresAt)) {
        throw authorizationFailed();
      }
      const nowSeconds = Math.floor(now() / 1000);
      if (authorization.expiresAt <= nowSeconds ||
          authorization.expiresAt > nowSeconds + maxTtlSeconds) {
        throw authorizationFailed();
      }

        return Object.freeze({
          subjectHash: authorizationSubjectHash(authorization.subject),
          platform: authorization.platform,
          expiresAt: authorization.expiresAt,
        });
      } finally {
        clearTimeout(timeout);
      }
    },
  });
}

export function createRequestAuthorizerFromEnvironment(env = process.env) {
  const introspectionUrl = env.PASSKEY_AUTHORIZATION_INTROSPECTION_URL;
  const audience = env.PASSKEY_AUTHORIZATION_AUDIENCE;
  if (!introspectionUrl || !audience) {
    throw new Error('PASSKEY_AUTHORIZATION_INTROSPECTION_URL and PASSKEY_AUTHORIZATION_AUDIENCE are required');
  }
  return createIntrospectionRequestAuthorizer({
    introspectionUrl,
    audience,
    timeoutMs: parseBoundedInteger(
      env.PASSKEY_AUTHORIZATION_TIMEOUT_MS ?? `${DEFAULT_TIMEOUT_MS}`,
      'PASSKEY_AUTHORIZATION_TIMEOUT_MS',
      100,
      10_000,
    ),
    maxTtlSeconds: parseBoundedInteger(
      env.PASSKEY_AUTHORIZATION_MAX_TTL_SECONDS ?? `${DEFAULT_MAX_TTL_SECONDS}`,
      'PASSKEY_AUTHORIZATION_MAX_TTL_SECONDS',
      1,
      3_600,
    ),
  });
}
