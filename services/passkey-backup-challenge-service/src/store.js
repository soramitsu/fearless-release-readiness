import { createHash, randomUUID } from 'node:crypto';
import { dirname } from 'node:path';
import {
  closeSync,
  constants as fsConstants,
  existsSync,
  fstatSync,
  fsyncSync,
  lstatSync,
  mkdirSync,
  openSync,
  readSync,
  renameSync,
  rmSync,
  writeFileSync,
} from 'node:fs';
import { base64UrlDecode, base64UrlEncode } from './base64url.js';
import { serviceError } from './errors.js';

const CREDENTIAL_STORE_SCHEMA_VERSION = 4;
const MIGRATABLE_CREDENTIAL_STORE_SCHEMA_VERSION = 3;
const MAX_CREDENTIAL_STORE_BYTES = 16 * 1024 * 1024;
const MAX_STORAGE_KEYS = 100_000;
const MAX_CREDENTIALS_PER_STORAGE_KEY = 32;
const STORAGE_KEY_RE = /^[A-Za-z0-9._:-]{8,128}$/;
const DEVICE_TYPES = new Set(['singleDevice', 'multiDevice']);
const PLATFORMS = new Set(['android', 'ios']);
const TRANSPORTS = new Set(['ble', 'cable', 'hybrid', 'internal', 'nfc', 'smart-card', 'usb']);
const AAGUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;
const STORE_FILE_REPLACED = Symbol('credentialStoreFileReplaced');
const DEFAULT_FILE_OPERATIONS = Object.freeze({
  closeSync,
  fsyncSync,
  mkdirSync,
  openSync,
  renameSync,
  rmSync,
  writeFileSync,
});

function credentialStoreInvalid(message = 'Credential store file is invalid') {
  return serviceError(500, 'credential_store_invalid', message);
}

function credentialStoreUnavailable(message = 'Credential store file cannot be written') {
  return serviceError(500, 'credential_store_unavailable', message);
}

function assertPlainObject(value, description) {
  if (value === null || typeof value !== 'object' || Array.isArray(value)) {
    throw credentialStoreInvalid(`${description} must be an object`);
  }
}

function assertExactKeys(value, required, optional, description) {
  assertPlainObject(value, description);
  const allowed = new Set([...required, ...optional]);
  for (const field of required) {
    if (!Object.prototype.hasOwnProperty.call(value, field)) {
      throw credentialStoreInvalid(`${description} missing required field ${field}`);
    }
  }
  for (const field of Object.keys(value)) {
    if (!allowed.has(field)) {
      throw credentialStoreInvalid(`${description} contains unsupported field ${field}`);
    }
  }
}

function assertCanonicalBase64Url(value, description, maxLength) {
  if (typeof value !== 'string' || value.length > maxLength) {
    throw credentialStoreInvalid(`${description} must be canonical base64url`);
  }
  try {
    const bytes = base64UrlDecode(value, description, maxLength);
    if (bytes.length === 0) {
      throw new Error('empty');
    }
  } catch (error) {
    throw credentialStoreInvalid(`${description} must be canonical base64url`);
  }
}

function normalizeCounter(value, description) {
  if (!Number.isSafeInteger(value) || value < 0) {
    throw credentialStoreInvalid(`${description} must be a non-negative safe integer`);
  }
  return value;
}

function normalizeTransports(value, description) {
  if (value === undefined) {
    return undefined;
  }
  if (!Array.isArray(value) || value.length > TRANSPORTS.size) {
    throw credentialStoreInvalid(`${description} must be an array of supported transports`);
  }
  const transports = [];
  for (const transport of value) {
    if (typeof transport !== 'string' || !TRANSPORTS.has(transport)) {
      throw credentialStoreInvalid(`${description} contains an unsupported transport`);
    }
    if (transports.includes(transport)) {
      throw credentialStoreInvalid(`${description} contains duplicate transports`);
    }
    transports.push(transport);
  }
  return transports;
}

function normalizeStoredCredential(value, description) {
  assertExactKeys(
    value,
    [
      'id',
      'publicKey',
      'userId',
      'counter',
      'deviceType',
      'backedUp',
      'aaguid',
      'registrationPlatform',
    ],
    ['transports'],
    description,
  );
  assertCanonicalBase64Url(value.id, `${description}.id`, 512);
  assertCanonicalBase64Url(value.publicKey, `${description}.publicKey`, 8192);
  assertCanonicalBase64Url(value.userId, `${description}.userId`, 128);
  const counter = normalizeCounter(value.counter, `${description}.counter`);
  if (!DEVICE_TYPES.has(value.deviceType)) {
    throw credentialStoreInvalid(`${description}.deviceType is unsupported`);
  }
  if (typeof value.backedUp !== 'boolean') {
    throw credentialStoreInvalid(`${description}.backedUp must be boolean`);
  }
  if (value.deviceType === 'singleDevice' && value.backedUp) {
    throw credentialStoreInvalid(`${description} has impossible backup flags`);
  }
  if (typeof value.aaguid !== 'string' || !AAGUID_RE.test(value.aaguid)) {
    throw credentialStoreInvalid(`${description}.aaguid must be a canonical UUID`);
  }
  if (!PLATFORMS.has(value.registrationPlatform)) {
    throw credentialStoreInvalid(`${description}.registrationPlatform is unsupported`);
  }
  const transports = normalizeTransports(value.transports, `${description}.transports`);
  return {
    id: value.id,
    publicKey: value.publicKey,
    userId: value.userId,
    counter,
    deviceType: value.deviceType,
    backedUp: value.backedUp,
    aaguid: value.aaguid,
    registrationPlatform: value.registrationPlatform,
    ...(transports === undefined ? {} : { transports }),
  };
}

function normalizeCredentialInput(value) {
  assertPlainObject(value, 'credential');
  assertCanonicalBase64Url(value.id, 'credential.id', 512);
  if (!(value.publicKey instanceof Uint8Array) || value.publicKey.length === 0 || value.publicKey.length > 6144) {
    throw credentialStoreInvalid('credential.publicKey must be non-empty public key bytes');
  }
  return normalizeStoredCredential({
    id: value.id,
    publicKey: base64UrlEncode(value.publicKey),
    userId: value.userId,
    counter: value.counter,
    deviceType: value.deviceType,
    backedUp: value.backedUp,
    aaguid: value.aaguid,
    registrationPlatform: value.registrationPlatform,
    ...(value.transports === undefined ? {} : { transports: value.transports }),
  }, 'credential');
}

function cloneCredentials(credentialsByStorageKey) {
  return new Map(
    [...credentialsByStorageKey.entries()].map(([storageKey, credentials]) => [
      storageKey,
      new Map(
        [...credentials.entries()].map(([credentialId, credential]) => [
          credentialId,
          {
            ...credential,
            ...(credential.transports === undefined ? {} : { transports: [...credential.transports] }),
          },
        ]),
      ),
    ]),
  );
}

function indexCredentialOwners(credentialsByStorageKey, ownersByStorageKey) {
  const index = new Map();
  for (const [storageKey, credentials] of credentialsByStorageKey) {
    const ownerSubjectHash = normalizeOwnerSubjectHash(ownersByStorageKey.get(storageKey));
    for (const credentialId of credentials.keys()) {
      if (index.has(credentialId)) {
        throw credentialStoreInvalid('Credential store contains duplicate credential IDs');
      }
      index.set(credentialId, { credentialId, storageKey, ownerSubjectHash });
    }
  }
  return index;
}

function validateCredentialOwnerIndex(value, expectedIndex) {
  if (!Array.isArray(value) || value.length !== expectedIndex.size) {
    throw credentialStoreInvalid('Credential owner index does not match registered credentials');
  }
  const seen = new Set();
  for (const entry of value) {
    assertExactKeys(entry, ['credentialId', 'storageKey', 'ownerSubjectHash'], [], 'credential owner index entry');
    const expected = expectedIndex.get(entry.credentialId);
    if (!expected || seen.has(entry.credentialId) ||
        entry.storageKey !== expected.storageKey || entry.ownerSubjectHash !== expected.ownerSubjectHash) {
      throw credentialStoreInvalid('Credential owner index does not match registered credentials');
    }
    seen.add(entry.credentialId);
  }
}

function serializeCredentials(credentialsByStorageKey, ownersByStorageKey) {
  return {
    schemaVersion: CREDENTIAL_STORE_SCHEMA_VERSION,
    credentialOwnersById: [...indexCredentialOwners(credentialsByStorageKey, ownersByStorageKey).values()]
      .sort((left, right) => left.credentialId.localeCompare(right.credentialId)),
    credentialsByStorageKey: [...credentialsByStorageKey.entries()]
      .sort(([left], [right]) => left.localeCompare(right))
      .map(([storageKey, credentials]) => ({
        storageKey,
        ownerSubjectHash: ownersByStorageKey.get(storageKey),
        credentials: [...credentials.values()]
          .sort((left, right) => left.id.localeCompare(right.id)),
      })),
  };
}

function deserializeCredentials(raw) {
  let parsed;
  try {
    parsed = JSON.parse(raw);
  } catch (error) {
    throw credentialStoreInvalid();
  }

  assertPlainObject(parsed, 'credential store');
  const needsMigration = parsed.schemaVersion === MIGRATABLE_CREDENTIAL_STORE_SCHEMA_VERSION;
  if (!needsMigration && parsed.schemaVersion !== CREDENTIAL_STORE_SCHEMA_VERSION) {
    throw credentialStoreInvalid('Credential store schemaVersion is unsupported');
  }
  assertExactKeys(
    parsed,
    needsMigration ? ['schemaVersion', 'credentialsByStorageKey']
      : ['schemaVersion', 'credentialsByStorageKey', 'credentialOwnersById'],
    [],
    'credential store',
  );
  if (!Array.isArray(parsed.credentialsByStorageKey) || parsed.credentialsByStorageKey.length > MAX_STORAGE_KEYS) {
    throw credentialStoreInvalid('credentialsByStorageKey must be a bounded array');
  }

  const credentialsByStorageKey = new Map();
  const ownersByStorageKey = new Map();
  const globalCredentialIds = new Set();
  for (const [index, entry] of parsed.credentialsByStorageKey.entries()) {
    const description = `credentialsByStorageKey[${index}]`;
    assertExactKeys(entry, ['storageKey', 'ownerSubjectHash', 'credentials'], [], description);
    if (typeof entry.storageKey !== 'string' || !STORAGE_KEY_RE.test(entry.storageKey)) {
      throw credentialStoreInvalid(`${description}.storageKey is invalid`);
    }
    if (credentialsByStorageKey.has(entry.storageKey)) {
      throw credentialStoreInvalid('Credential store contains duplicate storageKey entries');
    }
    assertCanonicalBase64Url(entry.ownerSubjectHash, `${description}.ownerSubjectHash`, 43);
    if (entry.ownerSubjectHash.length !== 43) {
      throw credentialStoreInvalid(`${description}.ownerSubjectHash must be a SHA-256 digest`);
    }
    if (!Array.isArray(entry.credentials) ||
        entry.credentials.length > MAX_CREDENTIALS_PER_STORAGE_KEY) {
      throw credentialStoreInvalid(`${description}.credentials must be a bounded array`);
    }

    const credentials = new Map();
    for (const [credentialIndex, rawCredential] of entry.credentials.entries()) {
      const credential = normalizeStoredCredential(
        rawCredential,
        `${description}.credentials[${credentialIndex}]`,
      );
      if (credential.userId !== expectedUserIdForStorageKey(entry.storageKey)) {
        throw credentialStoreInvalid('Credential userId does not match its storageKey');
      }
      if (credentials.has(credential.id) || globalCredentialIds.has(credential.id)) {
        throw credentialStoreInvalid('Credential store contains duplicate credential IDs');
      }
      credentials.set(credential.id, credential);
      globalCredentialIds.add(credential.id);
    }
    credentialsByStorageKey.set(entry.storageKey, credentials);
    ownersByStorageKey.set(entry.storageKey, entry.ownerSubjectHash);
  }

  const credentialOwnersById = indexCredentialOwners(credentialsByStorageKey, ownersByStorageKey);
  if (!needsMigration) validateCredentialOwnerIndex(parsed.credentialOwnersById, credentialOwnersById);
  return { credentialsByStorageKey, ownersByStorageKey, needsMigration };
}

function expectedUserIdForStorageKey(storageKey) {
  return createHash('sha256').update(`user\0${storageKey}`).digest('base64url');
}

function normalizeOwnerSubjectHash(value) {
  assertCanonicalBase64Url(value, 'ownerSubjectHash', 43);
  if (value.length !== 43) {
    throw credentialStoreInvalid('ownerSubjectHash must be a SHA-256 digest');
  }
  return value;
}

function readBoundedRegularFile(filePath) {
  let fileDescriptor;
  try {
    // O_NOFOLLOW closes the lstat/open race: replacing the checked path with a
    // symlink must fail instead of redirecting the subsequent read.
    fileDescriptor = openSync(filePath, fsConstants.O_RDONLY | fsConstants.O_NOFOLLOW);
    const initialStat = fstatSync(fileDescriptor);
    if (!initialStat.isFile() || initialStat.size > MAX_CREDENTIAL_STORE_BYTES) {
      throw credentialStoreInvalid('Credential store path must be a bounded regular file');
    }

    // Never let a file that grows after fstat force an unbounded allocation.
    // The extra byte distinguishes an exact-limit file from an oversized one.
    const buffer = Buffer.allocUnsafe(MAX_CREDENTIAL_STORE_BYTES + 1);
    let offset = 0;
    while (offset < buffer.length) {
      const bytesRead = readSync(fileDescriptor, buffer, offset, buffer.length - offset, null);
      if (bytesRead === 0) break;
      offset += bytesRead;
    }
    const finalStat = fstatSync(fileDescriptor);
    if (offset > MAX_CREDENTIAL_STORE_BYTES || finalStat.size > MAX_CREDENTIAL_STORE_BYTES) {
      throw credentialStoreInvalid('Credential store path must be a bounded regular file');
    }
    return buffer.subarray(0, offset).toString('utf8');
  } finally {
    if (fileDescriptor !== undefined) closeSync(fileDescriptor);
  }
}

function validateStorageKey(storageKey) {
  if (typeof storageKey !== 'string' || !STORAGE_KEY_RE.test(storageKey)) {
    throw serviceError(400, 'invalid_request', 'storageKey is invalid');
  }
  return storageKey;
}

function registrationCoordinationKey(storageKey, ownerSubjectHash) {
  return `${storageKey}\0${ownerSubjectHash}`;
}

export class InMemoryPasskeyChallengeStore {
  constructor({ ttlMillis = 5 * 60 * 1000, maxCeremonies = 10000, now = () => Date.now() } = {}) {
    if (!Number.isInteger(ttlMillis) || ttlMillis <= 0) {
      throw new Error('ttlMillis must be a positive integer');
    }
    if (!Number.isInteger(maxCeremonies) || maxCeremonies <= 0) {
      throw new Error('maxCeremonies must be a positive integer');
    }

    this.ttlMillis = ttlMillis;
    this.maxCeremonies = maxCeremonies;
    this.now = now;
    this.registrationCeremonies = new Map();
    this.assertionCeremonies = new Map();
    this.inFlightRegistrationsByStorageKey = new Map();
    this.credentialsByStorageKey = new Map();
    this.ownersByStorageKey = new Map();
    this.credentialOwnersById = new Map();
    // Versions only coordinate in-flight ceremonies within this process. The
    // durable owner tombstone is the cross-restart takeover defense; pending
    // ceremonies are intentionally transient and cannot survive a restart.
    this.credentialMutationVersions = new Map();
  }

  createRegistration(ceremony) {
    this.cleanupExpired();
    this.requireCapacity();
    this.registrationCeremonies.set(ceremony.registrationId, this.withExpiry(ceremony));
  }

  getRegistration(registrationId) {
    this.cleanupExpired();
    const ceremony = this.registrationCeremonies.get(registrationId);
    if (!ceremony) {
      throw serviceError(404, 'unknown_or_expired_registration', 'Registration ceremony is unknown or expired');
    }
    return ceremony;
  }

  consumeRegistration(registrationId, authorization) {
    const ceremony = this.getRegistration(registrationId);
    if (authorization &&
        (ceremony.authorizationSubjectHash !== authorization.subjectHash ||
         ceremony.authorizationPlatform !== authorization.platform)) {
      throw serviceError(403, 'request_authorization_failed', 'Request authorization failed');
    }
    this.registrationCeremonies.delete(registrationId);
    const coordinationKey = registrationCoordinationKey(
      ceremony.storageKey,
      ceremony.authorizationSubjectHash,
    );
    this.inFlightRegistrationsByStorageKey.set(
      coordinationKey,
      (this.inFlightRegistrationsByStorageKey.get(coordinationKey) ?? 0) + 1,
    );
    return ceremony;
  }

  releaseRegistration(storageKey, ownerSubjectHash) {
    const coordinationKey = registrationCoordinationKey(storageKey, ownerSubjectHash);
    const current = this.inFlightRegistrationsByStorageKey.get(coordinationKey) ?? 0;
    if (current <= 1) {
      this.inFlightRegistrationsByStorageKey.delete(coordinationKey);
    } else {
      this.inFlightRegistrationsByStorageKey.set(coordinationKey, current - 1);
    }

    if (!this.inFlightRegistrationsByStorageKey.has(coordinationKey) &&
        this.ownersByStorageKey.get(storageKey) !== ownerSubjectHash &&
        ![...this.registrationCeremonies.values()].some((ceremony) => (
          ceremony.storageKey === storageKey &&
          ceremony.authorizationSubjectHash === ownerSubjectHash
        ))) {
      this.credentialMutationVersions.delete(coordinationKey);
    }
  }

  registerCredential(storageKey, credentialInput, expectedMutationVersion) {
    const normalizedStorageKey = validateStorageKey(storageKey);
    const credential = normalizeCredentialInput(credentialInput);
    const ownerSubjectHash = normalizeOwnerSubjectHash(credentialInput.ownerSubjectHash);
    if (credential.userId !== expectedUserIdForStorageKey(normalizedStorageKey)) {
      throw credentialStoreInvalid('Credential userId does not match its storageKey');
    }
    const existingOwner = this.ownersByStorageKey.get(normalizedStorageKey);
    if (existingOwner !== undefined && existingOwner !== ownerSubjectHash) {
      throw serviceError(403, 'request_authorization_failed', 'Request authorization failed');
    }
    if (expectedMutationVersion !== undefined &&
        expectedMutationVersion !== this.storageMutationVersion(normalizedStorageKey, ownerSubjectHash)) {
      throw serviceError(409, 'credential_lifecycle_conflict', 'Credential lifecycle changed during registration');
    }
    if (this.credentialOwnersById.has(credential.id)) {
      throw serviceError(409, 'credential_already_registered', 'Credential is already registered');
    }

    const nextCredentials = cloneCredentials(this.credentialsByStorageKey);
    const nextOwners = new Map(this.ownersByStorageKey);
    const storageCredentials = nextCredentials.get(normalizedStorageKey) ?? new Map();
    if (storageCredentials.size >= MAX_CREDENTIALS_PER_STORAGE_KEY) {
      throw serviceError(409, 'credential_limit_reached', 'Credential limit reached for this storageKey');
    }
    if (!nextOwners.has(normalizedStorageKey) && nextOwners.size >= MAX_STORAGE_KEYS) {
      throw serviceError(503, 'credential_store_full', 'Credential store is full');
    }
    storageCredentials.set(credential.id, credential);
    nextCredentials.set(normalizedStorageKey, storageCredentials);
    nextOwners.set(normalizedStorageKey, ownerSubjectHash);
    this.commitStateWithAppliedCallback(nextCredentials, nextOwners, () => {
      this.bumpStorageMutationVersion(normalizedStorageKey, ownerSubjectHash);
    });
  }

  hasAnyCredential(storageKey) {
    return (this.credentialsByStorageKey.get(storageKey)?.size ?? 0) > 0;
  }

  hasCredential(storageKey, credentialId) {
    return this.credentialsByStorageKey.get(storageKey)?.has(credentialId) === true;
  }

  isStorageOwner(storageKey, ownerSubjectHash) {
    return this.ownersByStorageKey.get(storageKey) === ownerSubjectHash;
  }

  hasStorageOwner(storageKey) {
    return this.ownersByStorageKey.has(storageKey);
  }

  storageMutationVersion(storageKey, ownerSubjectHash) {
    return this.credentialMutationVersions.get(
      registrationCoordinationKey(storageKey, ownerSubjectHash),
    ) ?? 0;
  }

  bumpStorageMutationVersion(storageKey, ownerSubjectHash) {
    const coordinationKey = registrationCoordinationKey(storageKey, ownerSubjectHash);
    const current = this.storageMutationVersion(storageKey, ownerSubjectHash);
    this.credentialMutationVersions.set(coordinationKey, current + 1);
  }

  listCredentials(storageKey, ownerSubjectHash) {
    const normalizedStorageKey = validateStorageKey(storageKey);
    const normalizedOwner = normalizeOwnerSubjectHash(ownerSubjectHash);
    if (!this.ownersByStorageKey.has(normalizedStorageKey)) {
      throw serviceError(404, 'credential_storage_not_registered', 'Credential storage is not registered');
    }
    if (!this.isStorageOwner(normalizedStorageKey, normalizedOwner)) {
      throw serviceError(403, 'request_authorization_failed', 'Request authorization failed');
    }
    return [...(this.credentialsByStorageKey.get(normalizedStorageKey)?.values() ?? [])]
      .sort((left, right) => left.id.localeCompare(right.id))
      .map((credential) => ({
        id: credential.id,
        aaguid: credential.aaguid,
        registrationPlatform: credential.registrationPlatform,
        deviceType: credential.deviceType,
        backedUp: credential.backedUp,
        ...(credential.transports === undefined ? {} : { transports: [...credential.transports] }),
      }));
  }

  revokeCredential(storageKey, credentialId, ownerSubjectHash, confirmFinalRecoveryRemoval = false) {
    const normalizedStorageKey = validateStorageKey(storageKey);
    const normalizedOwner = normalizeOwnerSubjectHash(ownerSubjectHash);
    const existingOwner = this.ownersByStorageKey.get(normalizedStorageKey);
    if (existingOwner === undefined) {
      return { remainingCredentials: 0 };
    }
    if (existingOwner !== normalizedOwner) {
      throw serviceError(403, 'request_authorization_failed', 'Request authorization failed');
    }
    const currentCredentials = this.credentialsByStorageKey.get(normalizedStorageKey) ?? new Map();
    if (!currentCredentials.has(credentialId)) {
      return { remainingCredentials: currentCredentials.size };
    }
    // Other records are not evidence of independently decryptable backups.
    // Treat every live credential removal as potentially final.
    if (!confirmFinalRecoveryRemoval) {
      throw serviceError(409, 'final_recovery_route_confirmation_required', 'Final recovery route requires explicit confirmation');
    }

    const nextCredentials = cloneCredentials(this.credentialsByStorageKey);
    // Retain an empty credential map and its ownerSubjectHash as a bounded,
    // durable tombstone. Otherwise a different subject that can derive the
    // deterministic storageKey could claim it after the final revocation.
    nextCredentials.get(normalizedStorageKey).delete(credentialId);
    this.commitStateWithAppliedCallback(
      nextCredentials,
      new Map(this.ownersByStorageKey),
      () => {
        this.bumpStorageMutationVersion(normalizedStorageKey, normalizedOwner);
        this.invalidateAssertionsForStorageKey(normalizedStorageKey);
      },
    );
    return { remainingCredentials: nextCredentials.get(normalizedStorageKey).size };
  }

  revokeAllCredentials(storageKey, ownerSubjectHash, confirmFinalRecoveryRemoval = false) {
    const normalizedStorageKey = validateStorageKey(storageKey);
    const normalizedOwner = normalizeOwnerSubjectHash(ownerSubjectHash);
    const existingOwner = this.ownersByStorageKey.get(normalizedStorageKey);
    if (existingOwner === undefined) {
      // A revoke-all issued after challenge creation but before the first
      // credential is registered must cancel only this subject's pending work
      // without creating an owner tombstone for an otherwise unknown key.
      this.invalidateRegistrationsForStorageKey(
        normalizedStorageKey,
        normalizedOwner,
      );
      // Pending challenges are deleted synchronously. Only a completion that
      // already claimed the challenge needs a mutation version so it cannot
      // resurrect the credential after this revoke-all returns.
      const coordinationKey = registrationCoordinationKey(normalizedStorageKey, normalizedOwner);
      if ((this.inFlightRegistrationsByStorageKey.get(coordinationKey) ?? 0) > 0) {
        this.bumpStorageMutationVersion(normalizedStorageKey, normalizedOwner);
      }
      return { remainingCredentials: 0 };
    }
    if (existingOwner !== normalizedOwner) {
      throw serviceError(403, 'request_authorization_failed', 'Request authorization failed');
    }
    const currentCredentials = this.credentialsByStorageKey.get(normalizedStorageKey) ?? new Map();
    if (currentCredentials.size > 0 && !confirmFinalRecoveryRemoval) {
      throw serviceError(409, 'final_recovery_route_confirmation_required', 'Final recovery route requires explicit confirmation');
    }
    const applyLifecycleEffects = () => {
      this.bumpStorageMutationVersion(normalizedStorageKey, normalizedOwner);
      this.invalidateAssertionsForStorageKey(normalizedStorageKey);
      this.invalidateRegistrationsForStorageKey(normalizedStorageKey, normalizedOwner);
    };
    if (currentCredentials.size > 0) {
      const nextCredentials = cloneCredentials(this.credentialsByStorageKey);
      nextCredentials.set(normalizedStorageKey, new Map());
      this.commitStateWithAppliedCallback(
        nextCredentials,
        new Map(this.ownersByStorageKey),
        applyLifecycleEffects,
      );
    } else {
      applyLifecycleEffects();
    }
    return { remainingCredentials: 0 };
  }

  invalidateRegistrationsForStorageKey(storageKey, ownerSubjectHash) {
    let invalidated = 0;
    for (const [registrationId, ceremony] of this.registrationCeremonies.entries()) {
      if (ceremony.storageKey === storageKey &&
          ceremony.authorizationSubjectHash === ownerSubjectHash) {
        this.registrationCeremonies.delete(registrationId);
        invalidated += 1;
      }
    }
    return invalidated;
  }

  invalidateAssertionsForStorageKey(storageKey) {
    for (const [assertionId, ceremony] of this.assertionCeremonies.entries()) {
      if (ceremony.storageKey === storageKey) this.assertionCeremonies.delete(assertionId);
    }
  }

  getCredential(storageKey, credentialId) {
    const credential = this.credentialsByStorageKey.get(storageKey)?.get(credentialId);
    if (!credential) {
      throw serviceError(403, 'credential_not_registered', 'Credential is not registered for this storageKey');
    }
    return {
      id: credential.id,
      publicKey: new Uint8Array(base64UrlDecode(credential.publicKey, 'credential.publicKey', 8192)),
      userId: credential.userId,
      counter: credential.counter,
      ...(credential.transports === undefined ? {} : { transports: [...credential.transports] }),
      deviceType: credential.deviceType,
      backedUp: credential.backedUp,
      aaguid: credential.aaguid,
      registrationPlatform: credential.registrationPlatform,
    };
  }

  // Internal lookup for discoverable authentication. This identifies a candidate
  // public key only; it does not authenticate the caller or authorize a session.
  // The caller must verify the assertion and exact stored userHandle, then commit
  // the counter update (which rechecks revocation) before issuing any authority.
  findCredentialOwner(credentialId) {
    const owner = this.credentialOwnersById.get(credentialId);
    if (!owner) {
      throw serviceError(403, 'credential_not_registered', 'Credential is not registered');
    }
    return { ...owner, credential: this.getCredential(owner.storageKey, credentialId) };
  }

  updateCredentialAfterAuthentication(storageKey, credentialId, {
    newCounter,
    deviceType,
    backedUp,
  }) {
    const current = this.credentialsByStorageKey.get(storageKey)?.get(credentialId);
    if (!current) {
      throw serviceError(403, 'credential_not_registered', 'Credential is not registered for this storageKey');
    }
    normalizeCounter(newCounter, 'newCounter');
    if ((current.counter !== 0 || newCounter !== 0) && newCounter <= current.counter) {
      throw serviceError(409, 'credential_counter_replay', 'Credential counter did not advance');
    }
    if (!DEVICE_TYPES.has(deviceType) || typeof backedUp !== 'boolean') {
      throw serviceError(500, 'invalid_webauthn_verification', 'WebAuthn verification metadata is invalid');
    }
    if (deviceType === 'singleDevice' && backedUp) {
      throw serviceError(500, 'invalid_webauthn_verification', 'WebAuthn verification metadata is invalid');
    }
    if (current.deviceType !== deviceType) {
      throw serviceError(409, 'credential_backup_eligibility_changed', 'Credential backup eligibility changed');
    }

    const nextCredentials = cloneCredentials(this.credentialsByStorageKey);
    nextCredentials.get(storageKey).set(credentialId, {
      ...current,
      counter: newCounter,
      deviceType,
      backedUp,
    });
    this.commitState(nextCredentials, new Map(this.ownersByStorageKey));
  }

  commitState(nextCredentials, nextOwners) {
    const nextIndex = indexCredentialOwners(nextCredentials, nextOwners);
    this.credentialsByStorageKey = nextCredentials;
    this.ownersByStorageKey = nextOwners;
    this.credentialOwnersById = nextIndex;
  }

  commitStateWithAppliedCallback(nextCredentials, nextOwners, onApplied) {
    try {
      this.commitState(nextCredentials, nextOwners);
    } catch (error) {
      // A durable file replacement can succeed before directory fsync/close
      // reports failure. File-backed commitState adopts that visible state and
      // marks the error, so its mutation guards and ceremony invalidations must
      // also take effect even though the caller still receives a 500 response.
      if (error?.[STORE_FILE_REPLACED] === true) onApplied();
      throw error;
    }
    onApplied();
  }

  createAssertion(ceremony) {
    this.cleanupExpired();
    this.requireCapacity();
    this.assertionCeremonies.set(ceremony.assertionId, this.withExpiry(ceremony));
  }

  getAssertion(assertionId) {
    this.cleanupExpired();
    const ceremony = this.assertionCeremonies.get(assertionId);
    if (!ceremony) {
      throw serviceError(404, 'unknown_or_expired_assertion', 'Assertion ceremony is unknown or expired');
    }
    return ceremony;
  }

  consumeAssertion(assertionId, authorization) {
    const ceremony = this.getAssertion(assertionId);
    if (authorization &&
        (ceremony.authorizationSubjectHash !== authorization.subjectHash ||
         ceremony.authorizationPlatform !== authorization.platform)) {
      throw serviceError(403, 'request_authorization_failed', 'Request authorization failed');
    }
    this.assertionCeremonies.delete(assertionId);
    return ceremony;
  }

  withExpiry(ceremony) {
    return { ...ceremony, expiresAt: this.now() + this.ttlMillis };
  }

  requireCapacity() {
    const inFlightRegistrations = [...this.inFlightRegistrationsByStorageKey.values()]
      .reduce((total, count) => total + count, 0);
    const totalCeremonies = this.registrationCeremonies.size +
      this.assertionCeremonies.size + inFlightRegistrations;
    if (totalCeremonies >= this.maxCeremonies) {
      throw serviceError(503, 'ceremony_store_full', 'Challenge ceremony store is full');
    }
  }

  cleanupExpired() {
    const now = this.now();
    for (const [id, ceremony] of this.registrationCeremonies.entries()) {
      if (ceremony.expiresAt <= now) this.registrationCeremonies.delete(id);
    }
    for (const [id, ceremony] of this.assertionCeremonies.entries()) {
      if (ceremony.expiresAt <= now) this.assertionCeremonies.delete(id);
    }
  }
}

export class FileBackedPasskeyChallengeStore extends InMemoryPasskeyChallengeStore {
  constructor({ credentialStoreFile, fileOperations = {}, ...options } = {}) {
    super(options);
    if (typeof credentialStoreFile !== 'string' || credentialStoreFile.trim() === '') {
      throw credentialStoreUnavailable('PASSKEY_CREDENTIAL_STORE_FILE must be a non-empty file path');
    }
    this.credentialStoreFile = credentialStoreFile;
    this.fileOperations = { ...DEFAULT_FILE_OPERATIONS, ...fileOperations };
    if (Object.values(this.fileOperations).some((operation) => typeof operation !== 'function')) {
      throw credentialStoreUnavailable('Credential store file operations are invalid');
    }
    const loaded = this.loadCredentials();
    // Persist the complete v4 replacement before accepting requests. Existing
    // public keys, handles, counters, metadata and empty owner tombstones are
    // retained unchanged. A failed migration never opens a partially usable store.
    if (loaded.needsMigration) {
      this.persistCredentials(loaded.credentialsByStorageKey, loaded.ownersByStorageKey);
    }
    super.commitState(loaded.credentialsByStorageKey, loaded.ownersByStorageKey);
  }

  commitState(nextCredentials, nextOwners) {
    try {
      this.persistCredentials(nextCredentials, nextOwners);
    } catch (error) {
      // rename(2) makes the replacement visible before directory durability is
      // confirmed. Keep the process view aligned with the file that is now at
      // the canonical path even though the caller must still see the failure.
      if (error?.[STORE_FILE_REPLACED] === true) {
        super.commitState(nextCredentials, nextOwners);
      }
      throw error;
    }
    super.commitState(nextCredentials, nextOwners);
  }

  loadCredentials() {
    if (!existsSync(this.credentialStoreFile)) {
      this.persistCredentials(new Map(), new Map());
      return { credentialsByStorageKey: new Map(), ownersByStorageKey: new Map() };
    }

    try {
      const stat = lstatSync(this.credentialStoreFile);
      if (!stat.isFile() || stat.isSymbolicLink() || stat.size > MAX_CREDENTIAL_STORE_BYTES) {
        throw credentialStoreInvalid('Credential store path must be a bounded regular file');
      }
      return deserializeCredentials(readBoundedRegularFile(this.credentialStoreFile));
    } catch (error) {
      if (error.code === 'credential_store_invalid') throw error;
      throw credentialStoreUnavailable('Credential store file cannot be read');
    }
  }

  persistCredentials(credentialsByStorageKey, ownersByStorageKey) {
    const credentialStoreDirectory = dirname(this.credentialStoreFile);
    const temporaryFile = `${this.credentialStoreFile}.${randomUUID()}.tmp`;
    const payload = `${JSON.stringify(serializeCredentials(credentialsByStorageKey, ownersByStorageKey), null, 2)}\n`;
    if (Buffer.byteLength(payload) > MAX_CREDENTIAL_STORE_BYTES) {
      throw credentialStoreUnavailable('Credential store exceeds maximum size');
    }

    let fileDescriptor;
    let directoryDescriptor;
    let storeFileReplaced = false;
    const {
      closeSync: closeFileSync,
      fsyncSync: syncFileSync,
      mkdirSync: makeDirectorySync,
      openSync: openFileSync,
      renameSync: renameFileSync,
      rmSync: removeFileSync,
      writeFileSync: writeToFileSync,
    } = this.fileOperations;
    try {
      makeDirectorySync(credentialStoreDirectory, { recursive: true, mode: 0o700 });
      fileDescriptor = openFileSync(temporaryFile, 'wx', 0o600);
      writeToFileSync(fileDescriptor, payload);
      syncFileSync(fileDescriptor);
      closeFileSync(fileDescriptor);
      fileDescriptor = undefined;
      renameFileSync(temporaryFile, this.credentialStoreFile);
      storeFileReplaced = true;
      directoryDescriptor = openFileSync(credentialStoreDirectory, 'r');
      syncFileSync(directoryDescriptor);
      closeFileSync(directoryDescriptor);
      directoryDescriptor = undefined;
    } catch (error) {
      if (fileDescriptor !== undefined) {
        try { closeFileSync(fileDescriptor); } catch (closeError) { /* best effort */ }
      }
      if (directoryDescriptor !== undefined) {
        try { closeFileSync(directoryDescriptor); } catch (closeError) { /* best effort */ }
      }
      try { removeFileSync(temporaryFile, { force: true }); } catch (cleanupError) { /* best effort */ }
      const unavailable = credentialStoreUnavailable();
      if (storeFileReplaced) unavailable[STORE_FILE_REPLACED] = true;
      throw unavailable;
    }
  }
}

export function createPasskeyChallengeStore({
  credentialStoreFile = process.env.PASSKEY_CREDENTIAL_STORE_FILE,
  requireDurable = process.env.NODE_ENV === 'production',
  ...options
} = {}) {
  if (credentialStoreFile === undefined || credentialStoreFile === null ||
      String(credentialStoreFile).trim() === '') {
    if (requireDurable) {
      throw credentialStoreUnavailable('PASSKEY_CREDENTIAL_STORE_FILE is required in production');
    }
    return new InMemoryPasskeyChallengeStore(options);
  }
  return new FileBackedPasskeyChallengeStore({ ...options, credentialStoreFile });
}
