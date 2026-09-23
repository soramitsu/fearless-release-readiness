import { createServer as createHttpServer } from 'node:http';
import { isUtf8 } from 'node:buffer';
import { BlockList, isIP, SocketAddress } from 'node:net';
import { pathToFileURL } from 'node:url';
import {
  createRequestAuthorizerFromEnvironment,
  sha256Base64Url,
} from './authorization.js';
import { asServiceError, serviceError } from './errors.js';
import { createPasskeyBackupChallengeService } from './service.js';
import { createPasskeyChallengeStore } from './store.js';
import { PATHS, RP_ID, SCHEMA_VERSION, SERVICE_ID } from './validation.js';

const MAX_BODY_BYTES = 64 * 1024;
const MAX_REQUEST_TARGET_BYTES = 2048;
const DEFAULT_REQUEST_TIMEOUT_MS = 10_000;
const DEFAULT_RATE_LIMIT_WINDOW_MS = 60_000;
const DEFAULT_RATE_LIMIT_MAX_REQUESTS = 120;
const DEFAULT_GLOBAL_RATE_LIMIT_MAX_REQUESTS = 5_000;
const MAX_RATE_LIMIT_KEYS = 10_000;

function errorBody(error) {
  return {
    ok: false,
    service: SERVICE_ID,
    error: error.code,
    rpId: RP_ID,
    schemaVersion: SCHEMA_VERSION,
  };
}

function sendJson(response, status, payload, headers = {}) {
  const body = JSON.stringify(payload);
  response.writeHead(status, {
    'content-type': 'application/json; charset=utf-8',
    'cache-control': 'no-store',
    'content-length': Buffer.byteLength(body),
    'content-security-policy': "default-src 'none'; frame-ancestors 'none'",
    'cross-origin-resource-policy': 'same-site',
    'referrer-policy': 'no-referrer',
    'strict-transport-security': 'max-age=31536000; includeSubDomains',
    'x-content-type-options': 'nosniff',
    'x-frame-options': 'DENY',
    ...headers,
  });
  response.end(body);
}

async function readJsonBody(request) {
  const contentType = String(request.headers['content-type'] ?? '')
    .split(';', 1)[0]
    .trim()
    .toLowerCase();
  if (contentType !== 'application/json') {
    throw serviceError(415, 'unsupported_media_type', 'Content-Type must be application/json');
  }

  const contentLength = request.headers['content-length'];
  if (contentLength !== undefined &&
      (!/^(0|[1-9][0-9]*)$/.test(String(contentLength)) || Number(contentLength) > MAX_BODY_BYTES)) {
    throw serviceError(413, 'payload_too_large', 'Request body exceeds 64KiB');
  }

  let size = 0;
  const chunks = [];
  for await (const chunk of request) {
    size += chunk.length;
    if (size > MAX_BODY_BYTES) {
      throw serviceError(413, 'payload_too_large', 'Request body exceeds 64KiB');
    }
    chunks.push(chunk);
  }

  if (chunks.length === 0) {
    throw serviceError(400, 'invalid_json', 'Request body is required');
  }

  try {
    const rawBody = Buffer.concat(chunks);
    if (!isUtf8(rawBody)) {
      throw serviceError(400, 'invalid_json', 'Request body must be UTF-8 JSON');
    }
    return { body: JSON.parse(rawBody.toString('utf8')), rawBody };
  } catch (error) {
    throw serviceError(400, 'invalid_json', 'Request body must be valid JSON');
  }
}

function headerValues(request, name) {
  const distinct = request.headersDistinct?.[name];
  if (distinct !== undefined) return distinct;
  const value = request.headers[name];
  if (value === undefined) return [];
  return Array.isArray(value) ? value : [value];
}

function rejectAmbiguousHeaders(request) {
  for (const name of ['content-type', 'content-length', 'transfer-encoding', 'host',
    'x-forwarded-for', 'forwarded', 'proxy-authorization']) {
    if (headerValues(request, name).length > 1) {
      throw serviceError(400, 'ambiguous_headers', 'Request contains ambiguous headers');
    }
  }
  if (headerValues(request, 'content-length').length &&
      headerValues(request, 'transfer-encoding').length) {
    throw serviceError(400, 'ambiguous_headers', 'Request contains ambiguous headers');
  }
}

function bearerToken(request) {
  const values = headerValues(request, 'authorization');
  if (values.length !== 1 || typeof values[0] !== 'string') {
    throw serviceError(401, 'request_authorization_failed', 'Request authorization failed');
  }
  const match = /^Bearer ([A-Za-z0-9._~+\/-]+={0,})$/.exec(values[0]);
  if (!match || match[1].length === 0 || match[1].length > 4096) {
    throw serviceError(401, 'request_authorization_failed', 'Request authorization failed');
  }
  return match[1];
}

function normalizeRemoteAddress(value) {
  const mapped = /^::ffff:(\d{1,3}(?:\.\d{1,3}){3})$/i.exec(value ?? '');
  return mapped && isIP(mapped[1]) === 4 ? mapped[1] : value;
}

function canonicalIpAddress(value) {
  const family = isIP(value);
  if (family === 0) return undefined;
  try {
    return new SocketAddress({
      address: value,
      family: family === 4 ? 'ipv4' : 'ipv6',
    }).address;
  } catch (error) {
    return undefined;
  }
}

function ipAddressBytes(address, family) {
  if (family === 4) return address.split('.').map(Number);
  const [left = '', right = ''] = address.split('::');
  const leftParts = left ? left.split(':') : [];
  const rightParts = right ? right.split(':') : [];
  const zeroCount = 8 - leftParts.length - rightParts.length;
  const parts = [...leftParts, ...Array.from({ length: zeroCount }, () => '0'), ...rightParts];
  return parts.flatMap((part) => {
    const value = Number.parseInt(part, 16);
    return [value >>> 8, value & 0xff];
  });
}

function hasCidrHostBits(bytes, prefix) {
  const fullBytes = Math.floor(prefix / 8);
  const remainingBits = prefix % 8;
  if (remainingBits > 0 && (bytes[fullBytes] & (0xff >>> remainingBits)) !== 0) return true;
  const firstHostByte = fullBytes + (remainingBits > 0 ? 1 : 0);
  return bytes.slice(firstHostByte).some((byte) => byte !== 0);
}

function proxyNetworksOverlap(left, right) {
  if (left.family !== right.family) return false;
  const prefix = Math.min(left.prefix, right.prefix);
  const fullBytes = Math.floor(prefix / 8);
  for (let index = 0; index < fullBytes; index += 1) {
    if (left.bytes[index] !== right.bytes[index]) return false;
  }
  const remainingBits = prefix % 8;
  if (remainingBits === 0) return true;
  const mask = (0xff << (8 - remainingBits)) & 0xff;
  return (left.bytes[fullBytes] & mask) === (right.bytes[fullBytes] & mask);
}

function rateLimitClient(request, trustedProxyHops, trustedProxyCidrs) {
  if (trustedProxyHops === 0) {
    return request.socket.remoteAddress ?? 'unknown';
  }
  const remoteAddress = normalizeRemoteAddress(request.socket.remoteAddress);
  if (!remoteAddress || !trustedProxyCidrs.matches(remoteAddress)) {
    throw serviceError(400, 'untrusted_proxy', 'Forwarded client address is not accepted from this peer');
  }
  const values = headerValues(request, 'x-forwarded-for');
  const forwarded = values[0];
  if (values.length !== 1 || typeof forwarded !== 'string' || forwarded.includes(',') ||
      forwarded !== forwarded.trim() || canonicalIpAddress(forwarded) !== forwarded ||
      normalizeRemoteAddress(forwarded) !== forwarded) {
    throw serviceError(400, 'invalid_forwarded_client', 'Forwarded client address is invalid');
  }
  return forwarded;
}

function methodNotAllowed(response, allowedMethods) {
  const error = serviceError(405, 'method_not_allowed', 'Method not allowed');
  sendJson(response, error.status, errorBody(error), {
    allow: allowedMethods.join(', '),
  });
}

function routeExists(pathname) {
  return Object.values(PATHS).includes(pathname);
}

function requestPath(request) {
  const target = request.url ?? '/';
  if (typeof target !== 'string' || target.length === 0 ||
      Buffer.byteLength(target) > MAX_REQUEST_TARGET_BYTES ||
      !target.startsWith('/') || target.startsWith('//') || target.includes('\\') ||
      /[\u0000-\u001f\u007f]/.test(target)) {
    throw serviceError(400, 'invalid_request_target', 'Request target is invalid');
  }
  const url = new URL(target, 'http://127.0.0.1');
  if (url.search || url.hash) {
    throw serviceError(400, 'invalid_request_target', 'Query strings and fragments are not supported');
  }
  if (target.includes('%') || url.pathname !== target) {
    throw serviceError(400, 'invalid_request_target', 'Request target must use a canonical unencoded path');
  }
  return url.pathname;
}

function createRateLimiter({
  windowMillis = DEFAULT_RATE_LIMIT_WINDOW_MS,
  maxRequests = DEFAULT_RATE_LIMIT_MAX_REQUESTS,
  now = () => Date.now(),
} = {}) {
  if (!Number.isInteger(windowMillis) || windowMillis <= 0 ||
      !Number.isInteger(maxRequests) || maxRequests <= 0) {
    throw new Error('Rate-limit settings must be positive integers');
  }
  const clients = new Map();
  return (client) => {
    const timestamp = now();
    let entry = clients.get(client);
    if (!entry || entry.resetAt <= timestamp) {
      entry = { count: 0, resetAt: timestamp + windowMillis };
      clients.set(client, entry);
    }
    entry.count += 1;

    if (clients.size > MAX_RATE_LIMIT_KEYS) {
      for (const [key, candidate] of clients.entries()) {
        if (candidate.resetAt <= timestamp) clients.delete(key);
      }
      while (clients.size > MAX_RATE_LIMIT_KEYS) {
        clients.delete(clients.keys().next().value);
      }
    }

    return {
      allowed: entry.count <= maxRequests,
      retryAfterSeconds: Math.max(1, Math.ceil((entry.resetAt - timestamp) / 1000)),
    };
  };
}

export function parseIntegerSetting(value, name, { minimum, maximum }) {
  if (typeof value !== 'string' || !/^(0|[1-9][0-9]*)$/.test(value)) {
    throw new Error(`${name} must be an integer between ${minimum} and ${maximum}`);
  }
  const parsed = Number(value);
  if (!Number.isSafeInteger(parsed) || parsed < minimum || parsed > maximum) {
    throw new Error(`${name} must be an integer between ${minimum} and ${maximum}`);
  }
  return parsed;
}

export function parseNodeEnvironment(value = process.env.NODE_ENV ?? 'development') {
  if (!['development', 'test', 'production'].includes(value)) {
    throw new Error('NODE_ENV must be development, test, or production');
  }
  return value;
}

export function parseTrustedProxyHops(value, nodeEnvironment = 'development') {
  if (value === undefined) {
    if (nodeEnvironment === 'production') {
      throw new Error('PASSKEY_TRUST_PROXY_HOPS=1 is required in production');
    }
    return 0;
  }
  if (value !== '0' && value !== '1') {
    throw new Error('PASSKEY_TRUST_PROXY_HOPS must be 0 or 1');
  }
  const parsed = Number(value);
  if (nodeEnvironment === 'production' && parsed !== 1) {
    throw new Error('PASSKEY_TRUST_PROXY_HOPS=1 is required in production');
  }
  return parsed;
}

export function parseTrustedProxyCidrs(value) {
  if (typeof value !== 'string' || value.length === 0) {
    throw new Error('PASSKEY_TRUSTED_PROXY_CIDRS must contain at least one IP address or CIDR');
  }
  const entries = value.split(',');
  if (entries.length === 0 || entries.length > 16 || new Set(entries).size !== entries.length) {
    throw new Error('PASSKEY_TRUSTED_PROXY_CIDRS must contain 1-16 unique entries');
  }
  const blockList = new BlockList();
  const networks = [];
  for (const entry of entries) {
    if (entry.length === 0 || entry !== entry.trim()) {
      throw new Error('PASSKEY_TRUSTED_PROXY_CIDRS entries must be canonical and contain no whitespace');
    }
    const parts = entry.split('/');
    if (parts.length > 2 || isIP(parts[0]) === 0) {
      throw new Error(`PASSKEY_TRUSTED_PROXY_CIDRS contains invalid entry: ${entry}`);
    }
    const family = isIP(parts[0]);
    if (canonicalIpAddress(parts[0]) !== parts[0] || normalizeRemoteAddress(parts[0]) !== parts[0]) {
      throw new Error(`PASSKEY_TRUSTED_PROXY_CIDRS contains noncanonical entry: ${entry}`);
    }
    const type = family === 4 ? 'ipv4' : 'ipv6';
    const maximum = family === 4 ? 32 : 128;
    let prefix = maximum;
    if (parts.length === 1) {
      blockList.addAddress(parts[0], type);
    } else {
      if (!/^(0|[1-9][0-9]{0,2})$/.test(parts[1])) {
        throw new Error(`PASSKEY_TRUSTED_PROXY_CIDRS contains invalid entry: ${entry}`);
      }
      prefix = Number(parts[1]);
      const minimum = family === 4 ? 8 : 32;
      if (prefix < minimum || prefix > maximum) {
        throw new Error(`PASSKEY_TRUSTED_PROXY_CIDRS contains invalid or overbroad entry: ${entry}`);
      }
      if (hasCidrHostBits(ipAddressBytes(parts[0], family), prefix)) {
        throw new Error(`PASSKEY_TRUSTED_PROXY_CIDRS contains CIDR host bits: ${entry}`);
      }
      blockList.addSubnet(parts[0], prefix, type);
    }
    networks.push({ family, prefix, bytes: ipAddressBytes(parts[0], family), entry });
  }
  for (let left = 0; left < networks.length; left += 1) {
    for (let right = left + 1; right < networks.length; right += 1) {
      if (proxyNetworksOverlap(networks[left], networks[right])) {
        throw new Error(
          `PASSKEY_TRUSTED_PROXY_CIDRS contains overlapping entries: ${networks[left].entry},${networks[right].entry}`,
        );
      }
    }
  }
  return Object.freeze({
    entries: Object.freeze([...entries]),
    matches(address) {
      const family = isIP(address);
      return family !== 0 && blockList.check(address, family === 4 ? 'ipv4' : 'ipv6');
    },
  });
}

export function createServer({
  service = createPasskeyBackupChallengeService(),
  requestAuthorizer,
  trustedProxyHops = 0,
  trustedProxyCidrs,
  rateLimitWindowMillis = DEFAULT_RATE_LIMIT_WINDOW_MS,
  rateLimitMaxRequests = DEFAULT_RATE_LIMIT_MAX_REQUESTS,
  globalRateLimitMaxRequests = DEFAULT_GLOBAL_RATE_LIMIT_MAX_REQUESTS,
  now = () => Date.now(),
} = {}) {
  if (!requestAuthorizer || typeof requestAuthorizer.authorize !== 'function') {
    throw new Error('A request authorizer is required');
  }
  if (trustedProxyHops !== 0 && trustedProxyHops !== 1) {
    throw new Error('trustedProxyHops must be 0 or 1');
  }
  if (trustedProxyHops === 1 &&
      (!trustedProxyCidrs || typeof trustedProxyCidrs.matches !== 'function')) {
    throw new Error('trustedProxyCidrs is required when trustedProxyHops is 1');
  }
  const checkRateLimit = createRateLimiter({
    windowMillis: rateLimitWindowMillis,
    maxRequests: rateLimitMaxRequests,
    now,
  });
  const checkGlobalRateLimit = createRateLimiter({
    windowMillis: rateLimitWindowMillis,
    maxRequests: globalRateLimitMaxRequests,
    now,
  });
  const server = createHttpServer(async (request, response) => {
    try {
      rejectAmbiguousHeaders(request);
      const pathname = requestPath(request);

      if (pathname === PATHS.health) {
        if (request.method !== 'GET') {
          methodNotAllowed(response, ['GET']);
          return;
        }
        sendJson(response, 200, service.health());
        return;
      }

      if (!routeExists(pathname)) {
        throw serviceError(404, 'not_found', 'Route not found');
      }

      if (request.method !== 'POST') {
        methodNotAllowed(response, ['POST']);
        return;
      }

      const rateLimit = checkRateLimit(rateLimitClient(request, trustedProxyHops, trustedProxyCidrs));
      if (!rateLimit.allowed) {
        const error = serviceError(429, 'rate_limit_exceeded', 'Too many requests');
        sendJson(response, error.status, errorBody(error), {
          'retry-after': String(rateLimit.retryAfterSeconds),
        });
        return;
      }
      const globalRateLimit = checkGlobalRateLimit('all-clients');
      if (!globalRateLimit.allowed) {
        const error = serviceError(429, 'rate_limit_exceeded', 'Too many requests');
        sendJson(response, error.status, errorBody(error), {
          'retry-after': String(globalRateLimit.retryAfterSeconds),
        });
        return;
      }

      const token = bearerToken(request);
      const { body, rawBody } = await readJsonBody(request);
      const authorization = await requestAuthorizer.authorize({
        token,
        method: 'POST',
        path: pathname,
        bodySha256: sha256Base64Url(rawBody),
      });
      if (pathname === PATHS.registrationChallenge) {
        sendJson(response, 200, service.createRegistrationChallenge(body, authorization));
        return;
      }
      if (pathname === PATHS.registrationComplete) {
        sendJson(response, 200, await service.completeRegistration(body, authorization));
        return;
      }
      if (pathname === PATHS.assertionChallenge) {
        sendJson(response, 200, service.createAssertionChallenge(body, authorization));
        return;
      }
      if (pathname === PATHS.assertionComplete) {
        sendJson(response, 200, await service.completeAssertion(body, authorization));
        return;
      }
      if (pathname === PATHS.credentialsList) {
        sendJson(response, 200, service.listCredentials(body, authorization));
        return;
      }
      if (pathname === PATHS.credentialsRevoke) {
        sendJson(response, 200, service.revokeCredential(body, authorization));
        return;
      }
      if (pathname === PATHS.credentialsRevokeAll) {
        sendJson(response, 200, service.revokeAllCredentials(body, authorization));
        return;
      }

      throw serviceError(404, 'not_found', 'Route not found');
    } catch (error) {
      const serviceErr = asServiceError(error);
      sendJson(response, serviceErr.status, errorBody(serviceErr));
    }
  });
  server.requestTimeout = DEFAULT_REQUEST_TIMEOUT_MS;
  server.headersTimeout = DEFAULT_REQUEST_TIMEOUT_MS;
  server.keepAliveTimeout = 5_000;
  server.maxRequestsPerSocket = 100;
  return server;
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  const nodeEnvironment = parseNodeEnvironment();
  const trustedProxyHops = parseTrustedProxyHops(
    process.env.PASSKEY_TRUST_PROXY_HOPS,
    nodeEnvironment,
  );
  const trustedProxyCidrs = trustedProxyHops === 1
    ? parseTrustedProxyCidrs(process.env.PASSKEY_TRUSTED_PROXY_CIDRS)
    : undefined;
  const port = parseIntegerSetting(process.env.PORT ?? '8789', 'PORT', { minimum: 1, maximum: 65535 });
  const host = process.env.HOST ?? '0.0.0.0';
  const ttlMillis = parseIntegerSetting(
    process.env.PASSKEY_CHALLENGE_TTL_MS ?? `${5 * 60 * 1000}`,
    'PASSKEY_CHALLENGE_TTL_MS',
    { minimum: 1_000, maximum: 3_600_000 },
  );
  const maxCeremonies = parseIntegerSetting(
    process.env.PASSKEY_MAX_CEREMONIES ?? '10000',
    'PASSKEY_MAX_CEREMONIES',
    { minimum: 100, maximum: 1_000_000 },
  );
  const rateLimitWindowMillis = parseIntegerSetting(
    process.env.PASSKEY_RATE_LIMIT_WINDOW_MS ?? `${DEFAULT_RATE_LIMIT_WINDOW_MS}`,
    'PASSKEY_RATE_LIMIT_WINDOW_MS',
    { minimum: 1_000, maximum: 3_600_000 },
  );
  const rateLimitMaxRequests = parseIntegerSetting(
    process.env.PASSKEY_RATE_LIMIT_MAX_REQUESTS ?? `${DEFAULT_RATE_LIMIT_MAX_REQUESTS}`,
    'PASSKEY_RATE_LIMIT_MAX_REQUESTS',
    { minimum: 1, maximum: 100_000 },
  );
  const globalRateLimitMaxRequests = parseIntegerSetting(
    process.env.PASSKEY_GLOBAL_RATE_LIMIT_MAX_REQUESTS ?? `${DEFAULT_GLOBAL_RATE_LIMIT_MAX_REQUESTS}`,
    'PASSKEY_GLOBAL_RATE_LIMIT_MAX_REQUESTS',
    { minimum: 1, maximum: 1_000_000 },
  );
  const service = createPasskeyBackupChallengeService({
    store: createPasskeyChallengeStore({
      ttlMillis,
      maxCeremonies,
      credentialStoreFile: process.env.PASSKEY_CREDENTIAL_STORE_FILE,
      requireDurable: nodeEnvironment === 'production',
    }),
  });

  const requestAuthorizer = createRequestAuthorizerFromEnvironment();
  createServer({
    service,
    requestAuthorizer,
    trustedProxyHops,
    trustedProxyCidrs,
    rateLimitWindowMillis,
    rateLimitMaxRequests,
    globalRateLimitMaxRequests,
  }).listen(port, host, () => {
    console.log(`${SERVICE_ID} listening on ${host}:${port}`);
  });
}
