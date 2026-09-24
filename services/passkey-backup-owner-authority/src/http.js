import { isUtf8 } from 'node:buffer';
import { createServer } from 'node:http';
import { AuthorityError, RP_ID, SCOPES, exact, hash, platform } from './validation.js';

const PREFIX = '/api/passkey-backup/v1';
const BOOTSTRAP_CHALLENGE = `${PREFIX}/owner/bootstrap/challenge`;
const BOOTSTRAP_COMPLETE = `${PREFIX}/owner/bootstrap/complete`;
const AUTH_CHALLENGE = `${PREFIX}/owner/authentication/challenge`;
const AUTH_COMPLETE = `${PREFIX}/owner/authentication/complete`;
const GRANT = `${PREFIX}/owner/grant`;
const BACKUP_HEAD = `${PREFIX}/owner/backup/head`;
const BACKUP_OPERATION = `${PREFIX}/owner/backup/operation`;
const BACKUP_GRANT = `${PREFIX}/owner/backup/grant`;
const BACKUP_COMMIT = `${PREFIX}/owner/backup/commit`;
const HEALTH = `${PREFIX}/health`;
const MAX_BODY_BYTES = 64 * 1024;
const MAX_BOOTSTRAP_BODY_BYTES = 128 * 1024;
const SENSITIVE_HEADERS = new Set([
  'authorization', 'x-passkey-owner-session', 'content-type', 'content-length',
  'transfer-encoding', 'host', 'x-forwarded-for', 'forwarded',
]);
const READ_ROUTES = new Set([
  `${PREFIX}/registration/challenge`,
  `${PREFIX}/assertion/challenge`,
  `${PREFIX}/credentials/list`,
]);
const COMPLETION_ROUTES = new Set([
  `${PREFIX}/registration/complete`,
  `${PREFIX}/assertion/complete`,
]);
const ROUTES = new Set([
  BOOTSTRAP_CHALLENGE, BOOTSTRAP_COMPLETE,
  AUTH_CHALLENGE, AUTH_COMPLETE, GRANT, BACKUP_HEAD,
  BACKUP_OPERATION, BACKUP_GRANT, BACKUP_COMMIT, HEALTH, ...Object.keys(SCOPES),
]);

function deny(code = 'invalid_request') { throw new AuthorityError(code); }

function send(response, status, body, extraHeaders = {}) {
  if (response.destroyed || response.headersSent) return;
  const bytes = Buffer.from(JSON.stringify(body));
  response.writeHead(status, {
    'content-type': 'application/json; charset=utf-8',
    'content-length': String(bytes.length),
    'cache-control': 'no-store',
    'content-security-policy': "default-src 'none'; frame-ancestors 'none'",
    'cross-origin-resource-policy': 'same-site',
    'referrer-policy': 'no-referrer',
    'strict-transport-security': 'max-age=31536000; includeSubDomains',
    'x-content-type-options': 'nosniff',
    ...extraHeaders,
  });
  response.end(bytes);
}

function statusFor(error) {
  switch (error) {
    case 'invalid_request': return 400;
    case 'unsupported_media_type': return 415;
    case 'payload_too_large': return 413;
    case 'method_not_allowed': return 405;
    case 'not_found': return 404;
    case 'credential_not_registered': return 404;
    case 'authorization_failed': return 403;
    case 'verification_failed': return 403;
    case 'credential_counter_replay': return 409;
    case 'credential_already_linked': return 409;
    case 'owner_already_exists': return 409;
    case 'head_conflict': return 409;
    case 'operation_conflict': return 409;
    case 'generation_conflict': return 409;
    case 'key_epoch_transition_required': return 409;
    case 'storage_account_changed': return 409;
    case 'final_recovery_route_confirmation_required': return 409;
    case 'rate_limited': return 429;
    case 'capacity_exceeded': return 503;
    case 'verifier_unavailable': return 503;
    default: return 500;
  }
}

function canonicalPath(request) {
  const target = request.url;
  if (typeof target !== 'string' || target.length === 0 || target.length > 2048 ||
      !target.startsWith('/') || target.startsWith('//') ||
      /[?#%\\\u0000-\u001f\u007f]/.test(target)) deny();
  return target;
}

function rejectAmbiguousHeaders(request) {
  const counts = new Map();
  for (let index = 0; index < request.rawHeaders.length; index += 2) {
    const name = request.rawHeaders[index].toLowerCase();
    if (!SENSITIVE_HEADERS.has(name)) continue;
    counts.set(name, (counts.get(name) ?? 0) + 1);
    if (counts.get(name) > 1) deny();
  }
  if (counts.has('content-length') && counts.has('transfer-encoding')) deny();
}

function bearer(request, prefix) {
  const value = request.headers.authorization;
  const match = typeof value === 'string' && /^Bearer ([A-Za-z0-9._-]{1,384})$/.exec(value);
  if (!match || !match[1].startsWith(prefix)) deny('authorization_failed');
  return match[1];
}

function ownerSession(request) {
  const value = request.headers['x-passkey-owner-session'];
  if (typeof value !== 'string' || !/^session\.[A-Za-z0-9_-]{43}$/.test(value)) {
    deny('authorization_failed');
  }
  return value;
}

async function readBody(request, maximum = MAX_BODY_BYTES) {
  const type = request.headers['content-type'];
  if (typeof type !== 'string' || type.split(';', 1)[0].trim().toLowerCase() !== 'application/json') {
    deny('unsupported_media_type');
  }
  if (request.headers['content-length'] !== undefined &&
      (!/^(0|[1-9][0-9]*)$/.test(request.headers['content-length']) ||
       Number(request.headers['content-length']) > maximum)) deny('payload_too_large');
  const chunks = [];
  let size = 0;
  for await (const chunk of request) {
    size += chunk.length;
    if (size > maximum) deny('payload_too_large');
    chunks.push(chunk);
  }
  if (size === 0) deny();
  const raw = Buffer.concat(chunks);
  if (!isUtf8(raw)) deny();
  try {
    return { body: JSON.parse(raw.toString('utf8')), raw };
  } catch { deny(); }
}

function createRateLimiter() {
  const clients = new Map();
  return (key) => {
    const now = Date.now();
    const existing = clients.get(key);
    const row = existing && existing.expires > now ? existing : { expires: now + 60_000, count: 0 };
    row.count += 1;
    clients.set(key, row);
    if (clients.size > 10_000) {
      for (const [client, entry] of clients) if (entry.expires <= now) clients.delete(client);
      while (clients.size > 10_000) clients.delete(clients.keys().next().value);
    }
    // A bounded local transport limit supplements the durable global ceremony
    // limit. Production still needs reviewed proxy identity and deployment.
    if (row.count > 120) deny('rate_limited');
  };
}

function legacyMutationResult(path, request, result) {
  if (COMPLETION_ROUTES.has(path)) {
    return { storageKey: result.storageKey, rpId: RP_ID, schemaVersion: 1 };
  }
  if (path === `${PREFIX}/credentials/revoke`) {
    return { storageKey: request.storageKey, credentialId: request.credentialId,
      remainingCredentials: result.remainingCredentials, rpId: RP_ID, schemaVersion: 1 };
  }
  return { storageKey: request.storageKey, remainingCredentials: result.remainingCredentials,
    rpId: RP_ID, schemaVersion: 1 };
}

/**
 * Undeployed, single-writer HTTP composition candidate. It deliberately has no
 * executable entrypoint and rejects production construction until a sealed
 * legacy import, startup manifest, and proxy policy are reviewed.
 */
export function createOwnerHttpServer({ authority, audience, enableCandidate = false } = {}) {
  if (process.env.NODE_ENV === 'production' || enableCandidate !== true) {
    throw new Error('owner HTTP cutover is not admitted for production');
  }
  if (!authority || typeof authority.beginBootstrap !== 'function' ||
      typeof authority.completeBootstrap !== 'function' ||
      typeof authority.beginAuthentication !== 'function' ||
      typeof authority.commitChallengeReadRoute !== 'function' ||
      typeof authority.verifyAndCommitChallengeCredentialMutation !== 'function' ||
      typeof authority.commitChallengeCredentialMutation !== 'function' ||
      typeof authority.issueGrant !== 'function' ||
      typeof authority.completeAuthentication !== 'function' ||
      typeof authority.readBackupHead !== 'function' ||
      typeof authority.backupOperationStatus !== 'function' ||
      typeof authority.issueGenerationGrant !== 'function' ||
      typeof authority.commitGenerationMetadata !== 'function' ||
      typeof audience !== 'string' || !/^[A-Za-z0-9._:-]{8,128}$/.test(audience)) {
    throw new Error('owner HTTP authority and audience are required');
  }
  const limit = createRateLimiter();
  const server = createServer(async (request, response) => {
    try {
      rejectAmbiguousHeaders(request);
      const path = canonicalPath(request);
      if (!ROUTES.has(path)) deny('not_found');
      if (path === HEALTH) {
        if (request.method !== 'GET') deny('method_not_allowed');
        send(response, 200, { ok: true, service: 'fearless-passkey-backup',
          credentialAuthority: 'owner-sqlite-v2', rpId: RP_ID, schemaVersion: 1,
          productionAdmitted: false });
        return;
      }
      if (request.method !== 'POST') deny('method_not_allowed');
      limit(request.socket.remoteAddress ?? 'unknown');
      const { body, raw } = await readBody(request,
        path === BOOTSTRAP_COMPLETE ? MAX_BOOTSTRAP_BODY_BYTES : MAX_BODY_BYTES);
      if (path === BOOTSTRAP_CHALLENGE) {
        if (request.headers.authorization || request.headers['x-passkey-owner-session']) deny();
        exact(body, ['schemaVersion', 'platform']);
        if (body.schemaVersion !== 1) deny();
        send(response, 200, authority.beginBootstrap(platform(body.platform)));
        return;
      }
      if (path === BOOTSTRAP_COMPLETE) {
        if (request.headers.authorization || request.headers['x-passkey-owner-session']) deny();
        exact(body, ['schemaVersion', 'ceremonyId', 'credential', 'walletProof', 'appAttestation']);
        if (body.schemaVersion !== 1) deny();
        send(response, 200, await authority.completeBootstrap({
          ceremonyId: body.ceremonyId, credential: body.credential,
          walletProof: body.walletProof, appAttestation: body.appAttestation,
        }));
        return;
      }
      if (path === AUTH_CHALLENGE) {
        if (request.headers.authorization || request.headers['x-passkey-owner-session']) deny();
        exact(body, ['schemaVersion', 'platform']);
        if (body.schemaVersion !== 1) deny();
        send(response, 200, authority.beginAuthentication(platform(body.platform)));
        return;
      }
      if (path === AUTH_COMPLETE) {
        if (request.headers.authorization || request.headers['x-passkey-owner-session']) deny();
        exact(body, ['schemaVersion', 'ceremonyId', 'credential']);
        if (body.schemaVersion !== 1) deny();
        send(response, 200, await authority.completeAuthentication({
          ceremonyId: body.ceremonyId, credential: body.credential,
        }));
        return;
      }
      if (path === GRANT) {
        if (request.headers['x-passkey-owner-session']) deny();
        exact(body, ['schemaVersion', 'method', 'path', 'bodySha256', 'scope']);
        send(response, 200, authority.issueGrant(bearer(request, 'session.'), {
          ...body, audience,
        }));
        return;
      }
      if (path === BACKUP_HEAD || path === BACKUP_OPERATION || path === BACKUP_GRANT) {
        if (request.headers['x-passkey-owner-session']) deny();
        const session = bearer(request, 'session.');
        if (path === BACKUP_HEAD) {
          exact(body, ['schemaVersion']);
          if (body.schemaVersion !== 1) deny();
          send(response, 200, authority.readBackupHead(session));
        } else if (path === BACKUP_OPERATION) {
          exact(body, ['schemaVersion', 'operationId']);
          if (body.schemaVersion !== 1) deny();
          send(response, 200, authority.backupOperationStatus(session, body.operationId));
        } else {
          send(response, 200, authority.issueGenerationGrant(session, body));
        }
        return;
      }
      if (path === BACKUP_COMMIT) {
        send(response, 200, authority.commitGenerationMetadata(
          bearer(request, 'grant.'), body, ownerSession(request)));
        return;
      }
      const grant = bearer(request, 'grant.');
      const session = ownerSession(request);
      const binding = { schemaVersion: 1, audience, method: 'POST', path,
        bodySha256: hash(raw), scope: SCOPES[path] };
      if (READ_ROUTES.has(path)) {
        send(response, 200, authority.commitChallengeReadRoute(session, grant, binding, raw));
        return;
      }
      const result = COMPLETION_ROUTES.has(path)
        ? await authority.verifyAndCommitChallengeCredentialMutation(session, grant, binding, raw)
        : authority.commitChallengeCredentialMutation(grant, binding, raw, {});
      send(response, 200, legacyMutationResult(path, body, result));
    } catch (error) {
      const code = error instanceof AuthorityError ? error.code : 'internal_error';
      send(response, statusFor(code), { ok: false, service: 'fearless-passkey-backup',
        error: code, rpId: RP_ID, schemaVersion: 1 },
      code === 'method_not_allowed' ? { allow: 'POST' } : {});
    }
  });
  server.requestTimeout = 10_000;
  server.headersTimeout = 10_000;
  server.keepAliveTimeout = 5_000;
  server.maxRequestsPerSocket = 100;
  return server;
}
