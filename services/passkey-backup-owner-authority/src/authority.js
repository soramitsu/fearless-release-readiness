import { AuthorityStore } from './store.js';
import {
  AuthorityError, RP_ID, backupFlags, base64, counter, credentialRecord, credentialResponse,
  deny, exact, hash, opaque, platform, random, requestBinding, walletProof,
} from './validation.js';

const CEREMONY_MS = 120_000;
const SESSION_MS = 600_000;
const GRANT_MS = 60_000;
// Internal metadata mutation only. This is deliberately outside the seven
// challenge-service routes and cannot be consumed by their introspection API.
const GENERATION_COMMIT_PATH = '/internal/passkey-backup/v1/generations/commit';
const GENERATION_COMMIT_SCOPE = 'passkey.backup.generation.commit';
const MAX_BACKUP_GENERATIONS = 256;
const SHA256_HEX = /^[a-f0-9]{64}$/;
const DRIVE_FILE_ID = /^[A-Za-z0-9_-]{1,256}$/;
const DECIMAL = /^(0|[1-9][0-9]{0,15})$/;
const unavailableVerifier = Object.freeze({
  async bootstrap() { deny('verifier_unavailable'); },
  async authentication() { deny('verifier_unavailable'); },
  async enrollment() { deny('verifier_unavailable'); },
});

function prune(tx) {
  tx.run('DELETE FROM grants WHERE expires<=?', tx.now);
  tx.run('DELETE FROM sessions WHERE expires<=?', tx.now);
  tx.run('DELETE FROM ceremonies WHERE expires<=?', tx.now);
  tx.run('DELETE FROM limits WHERE bucket<?', Math.floor(tx.now / 60_000) - 1);
}
function createLimit(tx, owner) {
  prune(tx);
  const bucket = Math.floor(tx.now / 60_000);
  const used = tx.query('SELECT count FROM limits WHERE bucket=?', bucket)?.count ?? 0;
  if (used >= 60 || tx.query('SELECT count(*) AS n FROM ceremonies').n >= 256 ||
      (owner && tx.query('SELECT count(*) AS n FROM ceremonies WHERE subject=?', owner).n >= 8)) deny('rate_limited');
  tx.run('INSERT INTO limits VALUES(?,1) ON CONFLICT(bucket) DO UPDATE SET count=count+1', bucket);
}
function activeOwner(tx, subject, generation) {
  const owner = tx.query('SELECT * FROM owners WHERE subject=?', subject);
  if (!owner || (generation !== undefined && owner.generation !== generation)) deny();
  return owner;
}
function activeCredential(tx, id, subject) {
  const credential = tx.query('SELECT * FROM credentials WHERE id=?', id);
  if (!credential || credential.revoked !== 0 || (subject && credential.owner !== subject)) deny();
  return credential;
}
function session(tx, token) {
  const digest = hash(opaque(token, 'session.'));
  const found = tx.query('SELECT * FROM sessions WHERE digest=?', digest);
  if (!found || found.expires <= tx.now) deny();
  activeOwner(tx, found.owner, found.generation);
  activeCredential(tx, found.credential, found.owner);
  return found;
}
function newSession(tx, owner, credentialId, verifiedPlatform) {
  prune(tx);
  if (tx.query('SELECT count(*) AS n FROM sessions WHERE owner=?', owner.subject).n >= 32 ||
      tx.query('SELECT count(*) AS n FROM sessions').n >= 100_000) deny('capacity_exceeded');
  const token = random('session.');
  const expires = Math.floor((tx.now + SESSION_MS) / 1000) * 1000;
  tx.run('INSERT INTO sessions VALUES(?,?,?,?,?,?)', hash(token), owner.subject, credentialId, owner.generation, verifiedPlatform, expires);
  return { sessionToken: token, subject: owner.subject, namespace: owner.namespace, generation: owner.generation, platform: verifiedPlatform, expiresAt: expires / 1000 };
}
function bumpGeneration(tx, owner) {
  if (!Number.isSafeInteger(owner.generation) || owner.generation >= Number.MAX_SAFE_INTEGER) deny('generation_exhausted');
  tx.run('UPDATE owners SET generation=generation+1 WHERE subject=?', owner.subject);
  tx.run('DELETE FROM sessions WHERE owner=?', owner.subject); // Cascades outstanding grants.
  tx.run('DELETE FROM ceremonies WHERE subject=?', owner.subject);
  return { ...owner, generation: owner.generation + 1 };
}
function insertCredential(tx, owner, record) {
  // Revoked IDs remain permanent tombstones. No reassignment or resurrection.
  if (tx.query('SELECT id FROM credentials WHERE id=?', record.id)) deny('credential_already_linked');
  if (tx.query('SELECT count(*) AS n FROM credentials WHERE owner=?', owner.subject).n >= 32) deny('capacity_exceeded');
  tx.run('INSERT INTO credentials VALUES(?,?,?,?,?,?,?,0)', record.id, owner.subject, record.publicKey, record.userHandle, record.counter, record.deviceType, Number(record.backedUp));
}
function publicChallenge(row) {
  return { ceremonyId: row.id, kind: row.kind, challenge: row.challenge, rpId: RP_ID,
    platform: row.platform, subject: row.subject, namespace: row.namespace,
    userHandle: row.user_handle, expiresAt: row.expires / 1000 };
}
function verifierContext(row) {
  return Object.freeze(publicChallenge(row));
}
function decimal(value, minimum = 0) {
  if (typeof value !== 'string' || !DECIMAL.test(value)) deny('invalid_request');
  const number = Number(value);
  if (!Number.isSafeInteger(number) || number < minimum) deny('invalid_request');
  return number;
}
function digest(value) {
  if (typeof value !== 'string' || !SHA256_HEX.test(value)) deny('invalid_request');
  return value;
}
function generationRequest(input) {
  exact(input, [
    'schemaVersion', 'operationId', 'generationId', 'backupNamespace', 'expectedHeadRevision',
    'expectedHeadSha256', 'bundleSha256', 'keyEpoch', 'driveFileId', 'storageAccountBinding',
  ]);
  if (input.schemaVersion !== 1 || typeof input.backupNamespace !== 'string' ||
      !/^backup:[A-Za-z0-9_-]{43}$/.test(input.backupNamespace)) deny('invalid_request');
  base64(input.operationId, 32, 32);
  base64(input.generationId, 32, 32);
  if (input.operationId === input.generationId) deny('invalid_request');
  const expectedRevision = decimal(input.expectedHeadRevision);
  if (expectedRevision === 0 ? input.expectedHeadSha256 !== null : !SHA256_HEX.test(input.expectedHeadSha256)) {
    deny('invalid_request');
  }
  digest(input.bundleSha256);
  decimal(input.keyEpoch, 1);
  if (typeof input.driveFileId !== 'string' || !DRIVE_FILE_ID.test(input.driveFileId)) deny('invalid_request');
  digest(input.storageAccountBinding);
  return {
    schemaVersion: 1, operationId: input.operationId, generationId: input.generationId,
    backupNamespace: input.backupNamespace, expectedHeadRevision: input.expectedHeadRevision,
    expectedHeadSha256: input.expectedHeadSha256, bundleSha256: input.bundleSha256,
    keyEpoch: input.keyEpoch, driveFileId: input.driveFileId,
    storageAccountBinding: input.storageAccountBinding,
  };
}
function generationBinding(request, audience) {
  return { audience, method: 'POST', path: GENERATION_COMMIT_PATH,
    bodySha256: hash(JSON.stringify(request)), scope: GENERATION_COMMIT_SCOPE };
}
function mintGrant(tx, current, binding) {
  if (tx.query('SELECT count(*) AS n FROM grants WHERE session=?', current.digest).n >= 64 ||
      tx.query('SELECT count(*) AS n FROM grants').n >= 100_000) deny('capacity_exceeded');
  const grant = random('grant.');
  const expires = Math.floor(Math.min(current.expires, tx.now + GRANT_MS) / 1000) * 1000;
  if (expires <= tx.now) deny();
  tx.run('INSERT INTO grants VALUES(?,?,?,?,?,?,?,?,?,?)', hash(grant), current.digest, current.owner, current.generation,
    binding.audience, binding.method, binding.path, binding.bodySha256, binding.scope, expires);
  return { token: grant, expiresAt: expires / 1000 };
}
function liveGrant(tx, token, binding) {
  const grant = tx.query('SELECT * FROM grants WHERE digest=?', hash(opaque(token, 'grant.')));
  if (!grant || grant.expires <= tx.now || grant.audience !== binding.audience ||
      grant.method !== binding.method || grant.path !== binding.path ||
      grant.body_hash !== binding.bodySha256 || grant.scope !== binding.scope) deny();
  const current = tx.query('SELECT * FROM sessions WHERE digest=?', grant.session);
  if (!current || current.expires <= tx.now || current.owner !== grant.owner ||
      current.generation !== grant.generation) deny();
  const owner = activeOwner(tx, grant.owner, grant.generation);
  activeCredential(tx, current.credential, grant.owner);
  return { grant, current, owner };
}
function challengeMutationRequest(request, rawBody) {
  if (!(rawBody instanceof Uint8Array) || rawBody.byteLength === 0 || rawBody.byteLength > 64 * 1024) deny('invalid_request');
  // Own one immutable snapshot for both hashing and parsing. A caller must not
  // be able to change a shared byte view between those two checks.
  const bytes = Buffer.from(rawBody);
  if (hash(bytes) !== request.bodySha256) deny('invalid_request');
  let body;
  try {
    body = JSON.parse(new TextDecoder('utf-8', { fatal: true }).decode(bytes));
  } catch { deny('invalid_request'); }
  const registration = '/api/passkey-backup/v1/registration/complete';
  const assertion = '/api/passkey-backup/v1/assertion/complete';
  const revoke = '/api/passkey-backup/v1/credentials/revoke';
  const revokeAll = '/api/passkey-backup/v1/credentials/revoke-all';
  if (request.path === registration || request.path === assertion) {
    exact(body, [request.path === registration ? 'registrationId' : 'assertionId', 'rpId', 'credential']);
    if (body.rpId !== RP_ID) deny('invalid_request');
    const response = credentialResponse(body.credential, request.path === registration ? 'registration' : 'authentication');
    return { kind: request.path === registration ? 'registration' : 'assertion',
      credentialId: response.id,
      ...(request.path === assertion ? { userHandle: response.response.userHandle } : {}) };
  }
  if (request.path === revoke) {
    exact(body, ['storageKey', 'credentialId', 'rpId', 'schemaVersion', 'confirmFinalRecoveryRemoval']);
    if (body.rpId !== RP_ID || body.schemaVersion !== 1 || body.confirmFinalRecoveryRemoval !== true) deny('invalid_request');
    base64(body.credentialId, 1, 384);
    return { kind: 'revoke', credentialId: body.credentialId };
  }
  if (request.path === revokeAll) {
    exact(body, ['storageKey', 'rpId', 'schemaVersion', 'confirmFinalRecoveryRemoval']);
    if (body.rpId !== RP_ID || body.schemaVersion !== 1 || body.confirmFinalRecoveryRemoval !== true) deny('invalid_request');
    return { kind: 'revoke-all' };
  }
  deny('invalid_request');
}
function verifiedMutationEvidence(kind, evidence, credentialId, owner) {
  if (kind === 'registration') {
    exact(evidence, ['credential']);
    let snapshot;
    try { snapshot = structuredClone(evidence.credential); }
    catch { deny('invalid_request'); }
    return credentialRecord(snapshot, credentialId, owner.user_handle);
  }
  if (kind === 'assertion') {
    exact(evidence, ['expectedCounter', 'newCounter', 'deviceType', 'backedUp']);
    const snapshot = { expectedCounter: evidence.expectedCounter, newCounter: evidence.newCounter,
      deviceType: evidence.deviceType, backedUp: evidence.backedUp };
    counter(snapshot.expectedCounter);
    counter(snapshot.newCounter);
    backupFlags(snapshot);
    return snapshot;
  }
  exact(evidence, []);
  return evidence;
}
function generationDescriptor(tx, row) {
  if (!row) return null;
  const parentRevision = row.revision - 1;
  const parent = parentRevision > 0 ? tx.query(
    'SELECT bundle_sha256 FROM backup_operations WHERE owner=? AND revision=?', row.owner, parentRevision,
  ) : null;
  if (parentRevision > 0 && !parent) throw Error('Backup generation has no retained parent');
  return Object.freeze({
    headRevision: String(row.revision), parentHeadRevision: String(parentRevision),
    parentHeadSha256: parent?.bundle_sha256 ?? null, generationId: row.generation_id,
    bundleSha256: row.bundle_sha256, keyEpoch: String(row.key_epoch),
    driveFileId: row.drive_file_id, storageAccountBinding: row.account_binding,
  });
}
function backupHead(tx, owner) {
  const current = tx.query('SELECT revision, operation_id FROM backup_heads WHERE owner=?', owner.subject);
  if (!current) return { schemaVersion: 1, ownerSubject: owner.subject, backupNamespace: owner.namespace, head: null, previous: null };
  const head = tx.query('SELECT * FROM backup_operations WHERE operation_id=? AND owner=? AND revision=?',
    current.operation_id, owner.subject, current.revision);
  if (!head) throw Error('Backup head references a missing operation');
  const previous = current.revision > 1 ? tx.query('SELECT * FROM backup_operations WHERE owner=? AND revision=?',
    owner.subject, current.revision - 1) : null;
  if (current.revision > 1 && !previous) throw Error('Backup head has no retained predecessor');
  return { schemaVersion: 1, ownerSubject: owner.subject, backupNamespace: owner.namespace,
    head: generationDescriptor(tx, head), previous: generationDescriptor(tx, previous) };
}

/**
 * verifier is a server-only cryptographic adapter, never request-supplied data.
 * It is deliberately unavailable by default. See README for its exact proof
 * obligations; returning {verified:true} is not the adapter contract.
 */
export function createOwnerAuthority({ path, create = false, migrate = false, audience, verifier = unavailableVerifier, now, monotonic, fault } = {}) {
  if (typeof audience !== 'string' || !/^[A-Za-z0-9._:-]{8,128}$/.test(audience)) deny('invalid_configuration');
  if (!verifier || ['bootstrap', 'authentication', 'enrollment'].some((key) => typeof verifier[key] !== 'function')) deny('invalid_configuration');
  const store = new AuthorityStore({ path, create, migrate, now, monotonic, fault });
  const challenge = (kind, requestedPlatform, token) => store.transaction((tx) => {
    let context;
    if (kind === 'enrollment') {
      context = session(tx, token);
      if (requestedPlatform !== context.platform) deny();
    }
    createLimit(tx, context?.owner);
    const owner = context && activeOwner(tx, context.owner, context.generation);
    const row = {
      id: random('ceremony.'), kind, challenge: random(),
      subject: owner?.subject ?? (kind === 'bootstrap' ? random('owner:') : null),
      namespace: owner?.namespace ?? (kind === 'bootstrap' ? random('backup:') : null),
      user_handle: owner?.user_handle ?? (kind === 'bootstrap' ? random() : null),
      session: context?.digest ?? null, generation: context?.generation ?? null,
      platform: platform(requestedPlatform), expires: Math.floor((tx.now + CEREMONY_MS) / 1000) * 1000,
    };
    tx.run('INSERT INTO ceremonies VALUES(?,?,?,?,?,?,?,?,?,?,0)', row.id, row.kind, row.challenge, row.subject, row.namespace,
      row.user_handle, row.session, row.generation, row.platform, row.expires);
    return publicChallenge(row);
  });
  const claim = (id, kind, token, credentialId) => store.transaction((tx) => {
    opaque(id, 'ceremony.');
    const row = tx.query('SELECT * FROM ceremonies WHERE id=?', id);
    if (!row || row.kind !== kind || row.claimed || row.expires <= tx.now) deny();
    let credential;
    if (kind === 'enrollment') {
      const current = session(tx, token);
      if (current.digest !== row.session || current.generation !== row.generation || current.owner !== row.subject) deny();
    }
    if (kind === 'authentication') {
      credential = activeCredential(tx, credentialId);
      const owner = activeOwner(tx, credential.owner);
      row.subject = owner.subject;
      row.namespace = owner.namespace;
      row.user_handle = owner.user_handle;
      row.generation = owner.generation;
    }
    tx.run('UPDATE ceremonies SET claimed=1 WHERE id=?', id);
    return { row, credential };
  });
  const finish = (row, action) => store.transaction((tx) => {
    const current = tx.query('SELECT * FROM ceremonies WHERE id=?', row.id);
    if (!current || current.claimed !== 1 || current.expires <= tx.now) deny();
    const result = action(tx);
    tx.run('DELETE FROM ceremonies WHERE id=?', row.id);
    return result;
  });
  const verify = async (kind, context) => {
    try { return await verifier[kind](context); }
    catch (error) {
      if (error instanceof AuthorityError && error.code === 'verifier_unavailable') throw error;
      deny('verification_failed'); // Never expose verifier errors, public proof, or response data.
    }
  };

  return Object.freeze({
    close: () => store.close(),
    beginBootstrap(requestedPlatform) { return challenge('bootstrap', platform(requestedPlatform)); },
    beginAuthentication(requestedPlatform) { return challenge('authentication', platform(requestedPlatform)); },
    beginEnrollment(token) {
      const verifiedPlatform = store.transaction((tx) => session(tx, token).platform);
      return challenge('enrollment', verifiedPlatform, token);
    },
    async completeBootstrap(input) {
      exact(input, ['ceremonyId', 'credential', 'walletProof']);
      const credential = credentialResponse(input.credential, 'registration');
      const proof = walletProof(input.walletProof);
      const { row } = claim(input.ceremonyId, 'bootstrap');
      const evidence = await verify('bootstrap', { ceremony: verifierContext(row), credential, walletProof: proof });
      exact(evidence, ['credential', 'walletBindingHash']);
      base64(evidence.walletBindingHash, 32, 32);
      const record = credentialRecord(evidence.credential, credential.id, row.user_handle);
      return finish(row, (tx) => {
        if (tx.query('SELECT subject FROM owners WHERE wallet_binding=?', evidence.walletBindingHash)) deny('owner_already_exists');
        if (tx.query('SELECT count(*) AS n FROM owners').n >= 100_000) deny('capacity_exceeded');
        const owner = { subject: row.subject, namespace: row.namespace, user_handle: row.user_handle, generation: 0 };
        tx.run('INSERT INTO owners VALUES(?,?,?,?,0,?)', owner.subject, owner.namespace, owner.user_handle, evidence.walletBindingHash, tx.now);
        insertCredential(tx, owner, record);
        return newSession(tx, owner, record.id, row.platform);
      });
    },
    async completeAuthentication(input) {
      exact(input, ['ceremonyId', 'credential']);
      const credential = credentialResponse(input.credential, 'authentication');
      const { row, credential: linked } = claim(input.ceremonyId, 'authentication', undefined, credential.id);
      if (credential.response.userHandle !== linked.user_handle) deny('verification_failed');
      const evidence = await verify('authentication', {
        ceremony: verifierContext(row), credential,
        registeredCredential: Object.freeze({ id: linked.id, publicKey: linked.public_key, userHandle: linked.user_handle, counter: linked.counter, deviceType: linked.device_type, backedUp: !!linked.backed_up }),
      });
      exact(evidence, ['credentialId', 'newCounter', 'deviceType', 'backedUp']);
      backupFlags(evidence);
      if (evidence.deviceType !== linked.device_type) deny('verification_failed');
      if (evidence.credentialId !== linked.id) deny('verification_failed');
      counter(evidence.newCounter);
      return finish(row, (tx) => {
        const owner = activeOwner(tx, linked.owner, row.generation);
        const current = activeCredential(tx, linked.id, linked.owner);
        if (current.public_key !== linked.public_key || current.user_handle !== linked.user_handle ||
            current.counter !== linked.counter ||
            ((current.counter !== 0 || evidence.newCounter !== 0) && evidence.newCounter <= current.counter)) deny('credential_counter_replay');
        tx.run('UPDATE credentials SET counter=?, backed_up=? WHERE id=?', evidence.newCounter, Number(evidence.backedUp), linked.id);
        return newSession(tx, owner, linked.id, row.platform);
      });
    },
    async completeEnrollment(input) {
      exact(input, ['ceremonyId', 'sessionToken', 'credential']);
      const credential = credentialResponse(input.credential, 'registration');
      const { row } = claim(input.ceremonyId, 'enrollment', input.sessionToken);
      const evidence = await verify('enrollment', { ceremony: verifierContext(row), credential });
      exact(evidence, ['credential']);
      const record = credentialRecord(evidence.credential, credential.id, row.user_handle);
      return finish(row, (tx) => {
        const current = session(tx, input.sessionToken);
        if (current.digest !== row.session || current.owner !== row.subject || current.generation !== row.generation) deny();
        const owner = activeOwner(tx, current.owner, current.generation);
        insertCredential(tx, owner, record);
        return newSession(tx, bumpGeneration(tx, owner), record.id, row.platform);
      });
    },
    issueGrant(token, request) {
      const binding = requestBinding(request, audience);
      return store.transaction((tx) => {
        prune(tx);
        const current = session(tx, token);
        return mintGrant(tx, current, binding);
      });
    },
    consumeGrant(token, request) {
      const binding = requestBinding(request, audience);
      return store.transaction((tx) => {
        const { grant, current } = liveGrant(tx, token, binding);
        tx.run('DELETE FROM grants WHERE digest=?', grant.digest); // Consumption committed before response; never restored on disconnect.
        // This response must not be accepted by the legacy JSON challenge
        // service. Its strict v1 introspector rejects the extra authority
        // marker until all seven routes share this SQLite lifecycle writer.
        return { schemaVersion: 1, credentialAuthority: 'owner-sqlite-v2', active: true,
          subject: grant.owner, audience: binding.audience,
          method: binding.method, path: binding.path, bodySha256: binding.bodySha256, scope: binding.scope,
          platform: current.platform, expiresAt: grant.expires / 1000 };
      });
    },
    // Server-only migration target for the challenge service's four credential
    // mutations. The exact route grant, current owner/session/credential and
    // canonical public credential row are checked and changed under one SQLite
    // writer lock. The existing JSON-backed HTTP routes do not call this yet.
    commitChallengeCredentialMutation(token, request, rawBody, evidence) {
      const binding = requestBinding(request, audience);
      const target = challengeMutationRequest(binding, rawBody);
      return store.transaction((tx) => {
        const { grant, owner } = liveGrant(tx, token, binding);
        const verified = verifiedMutationEvidence(target.kind, evidence, target.credentialId, owner);
        let result;
        if (target.kind === 'registration') {
          insertCredential(tx, owner, verified);
          result = { status: 'registered', credentialId: target.credentialId,
            generation: bumpGeneration(tx, owner).generation };
        } else if (target.kind === 'assertion') {
          const credential = activeCredential(tx, target.credentialId, owner.subject);
          if (target.userHandle !== credential.user_handle || target.userHandle !== owner.user_handle) deny('verification_failed');
          if (credential.counter !== verified.expectedCounter || credential.device_type !== verified.deviceType ||
              ((credential.counter !== 0 || verified.newCounter !== 0) && verified.newCounter <= credential.counter)) {
            deny('credential_counter_replay');
          }
          tx.run('UPDATE credentials SET counter=?, backed_up=? WHERE id=?',
            verified.newCounter, Number(verified.backedUp), credential.id);
          result = { status: 'authenticated', credentialId: credential.id, counter: verified.newCounter };
        } else if (target.kind === 'revoke') {
          activeCredential(tx, target.credentialId, owner.subject);
          tx.run('UPDATE credentials SET revoked=1 WHERE id=?', target.credentialId);
          const remaining = tx.query('SELECT count(*) AS n FROM credentials WHERE owner=? AND revoked=0', owner.subject).n;
          result = { status: 'revoked', credentialId: target.credentialId,
            remainingCredentials: remaining, generation: bumpGeneration(tx, owner).generation };
        } else {
          tx.run('UPDATE credentials SET revoked=1 WHERE owner=?', owner.subject);
          result = { status: 'revoked-all', remainingCredentials: 0,
            generation: bumpGeneration(tx, owner).generation };
        }
        tx.run('DELETE FROM grants WHERE digest=?', grant.digest);
        return result;
      });
    },
    revokeCredential(token, credentialId, confirmFinalRecoveryRemoval = false) {
      base64(credentialId, 1, 384);
      if (typeof confirmFinalRecoveryRemoval !== 'boolean') deny('invalid_request');
      return store.transaction((tx) => {
        const current = session(tx, token);
        activeCredential(tx, credentialId, current.owner);
        const owner = activeOwner(tx, current.owner, current.generation);
        // An enrolled credential is not proof that its client ever verified a
        // decryptable backup. Any other record may be unusable, so every live
        // credential removal can be the final recovery route.
        if (!confirmFinalRecoveryRemoval) deny('final_recovery_route_confirmation_required');
        tx.run('UPDATE credentials SET revoked=1 WHERE id=?', credentialId);
        return { generation: bumpGeneration(tx, owner).generation };
      });
    },
    revokeAll(token, confirmFinalRecoveryRemoval = false) {
      if (typeof confirmFinalRecoveryRemoval !== 'boolean') deny('invalid_request');
      return store.transaction((tx) => {
        const current = session(tx, token);
        const owner = activeOwner(tx, current.owner, current.generation);
        const remaining = tx.query('SELECT count(*) AS n FROM credentials WHERE owner=? AND revoked=0', owner.subject).n;
        if (remaining > 0 && !confirmFinalRecoveryRemoval) deny('final_recovery_route_confirmation_required');
        tx.run('UPDATE credentials SET revoked=1 WHERE owner=?', owner.subject);
        return { generation: bumpGeneration(tx, owner).generation };
      });
    },
    revokeSessions(token) {
      return store.transaction((tx) => {
        const current = session(tx, token);
        return { generation: bumpGeneration(tx, activeOwner(tx, current.owner, current.generation)).generation };
      });
    },
    readBackupHead(token) {
      return store.transaction((tx) => {
        const current = session(tx, token);
        return backupHead(tx, activeOwner(tx, current.owner, current.generation));
      });
    },
    backupOperationStatus(token, operationId) {
      base64(operationId, 32, 32);
      return store.transaction((tx) => {
        const current = session(tx, token);
        const owner = activeOwner(tx, current.owner, current.generation);
        const operation = tx.query('SELECT * FROM backup_operations WHERE operation_id=? AND owner=?', operationId, owner.subject);
        return operation ? { status: 'committed', descriptor: generationDescriptor(tx, operation) } : { status: 'absent' };
      });
    },
    issueGenerationGrant(token, input) {
      const request = generationRequest(input);
      const binding = generationBinding(request, audience);
      return store.transaction((tx) => {
        prune(tx);
        const current = session(tx, token);
        const owner = activeOwner(tx, current.owner, current.generation);
        if (request.backupNamespace !== owner.namespace) deny();
        return mintGrant(tx, current, binding);
      });
    },
    // Metadata CAS only. The caller must have uploaded, downloaded, unwrapped,
    // decrypted and checked the exact immutable bytes before invoking this.
    // This core has no HTTP route and does not claim to verify that device work.
    commitGenerationMetadata(grantToken, input) {
      const request = generationRequest(input);
      const binding = generationBinding(request, audience);
      const requestHash = binding.bodySha256;
      return store.transaction((tx) => {
        const grantDigest = hash(opaque(grantToken, 'grant.'));
        const grant = tx.query('SELECT * FROM grants WHERE digest=?', grantDigest);
        if (!grant || grant.expires <= tx.now || grant.audience !== binding.audience ||
            grant.method !== binding.method || grant.path !== binding.path ||
            grant.body_hash !== binding.bodySha256 || grant.scope !== binding.scope) deny();
        const current = tx.query('SELECT * FROM sessions WHERE digest=?', grant.session);
        if (!current || current.expires <= tx.now || current.owner !== grant.owner ||
            current.generation !== grant.generation) deny();
        activeCredential(tx, current.credential, grant.owner);
        const owner = activeOwner(tx, current.owner, current.generation);
        if (request.backupNamespace !== owner.namespace) deny();
        const priorOperation = tx.query('SELECT * FROM backup_operations WHERE operation_id=?', request.operationId);
        if (priorOperation) {
          if (priorOperation.owner !== owner.subject || priorOperation.request_hash !== requestHash) deny('operation_conflict');
          tx.run('DELETE FROM grants WHERE digest=?', grantDigest);
          return { status: 'committed', descriptor: generationDescriptor(tx, priorOperation) };
        }
        const state = backupHead(tx, owner);
        const expectedRevision = decimal(request.expectedHeadRevision);
        if (Number(state.head?.headRevision ?? 0) !== expectedRevision) deny('head_conflict');
        if ((state.head?.bundleSha256 ?? null) !== request.expectedHeadSha256) deny('head_conflict');
        const epoch = decimal(request.keyEpoch, 1);
        if (epoch !== (state.head === null ? 1 : Number(state.head.keyEpoch))) deny('key_epoch_transition_required');
        if (state.head && state.head.storageAccountBinding !== request.storageAccountBinding) deny('storage_account_changed');
        const revision = expectedRevision + 1;
        if (!Number.isSafeInteger(revision) ||
            tx.query('SELECT count(*) AS n FROM backup_operations WHERE owner=?', owner.subject).n >= MAX_BACKUP_GENERATIONS) {
          deny('capacity_exceeded');
        }
        if (tx.query('SELECT operation_id FROM backup_operations WHERE generation_id=? OR drive_file_id=?',
          request.generationId, request.driveFileId)) deny('generation_conflict');
        tx.run('INSERT INTO backup_operations VALUES(?,?,?,?,?,?,?,?,?)', request.operationId, owner.subject,
          requestHash, revision, request.generationId, request.bundleSha256, epoch, request.driveFileId,
          request.storageAccountBinding);
        tx.run('INSERT INTO backup_heads VALUES(?,?,?) ON CONFLICT(owner) DO UPDATE SET revision=excluded.revision, operation_id=excluded.operation_id',
          owner.subject, revision, request.operationId);
        tx.run('DELETE FROM grants WHERE digest=?', grantDigest);
        return { status: 'committed', descriptor: generationDescriptor(tx,
          tx.query('SELECT * FROM backup_operations WHERE operation_id=?', request.operationId)) };
      });
    },
  });
}
