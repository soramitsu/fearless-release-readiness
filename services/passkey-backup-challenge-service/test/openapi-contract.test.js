import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import test from 'node:test';
import { AUTHORIZATION_SCOPES } from '../src/authorization.js';
import { PATHS } from '../src/validation.js';

const spec = JSON.parse(readFileSync('../../config/passkey-backup-challenge-service.openapi.json', 'utf8'));
const productionConfig = JSON.parse(readFileSync('../../config/passkey-backup-production.json', 'utf8'));

const matrices = {
  '/api/passkey-backup/v1/registration/challenge': ['200', '400', '401', '403', '413', '415', '429', '500', '503'],
  '/api/passkey-backup/v1/registration/complete': ['200', '400', '401', '403', '404', '409', '413', '415', '429', '500', '503'],
  '/api/passkey-backup/v1/assertion/challenge': ['200', '400', '401', '403', '404', '413', '415', '429', '500', '503'],
  '/api/passkey-backup/v1/assertion/complete': ['200', '400', '401', '403', '404', '409', '413', '415', '429', '500', '503'],
  '/api/passkey-backup/v1/credentials/list': ['200', '400', '401', '403', '404', '413', '415', '429', '500', '503'],
  '/api/passkey-backup/v1/credentials/revoke': ['200', '400', '401', '403', '409', '413', '415', '429', '500', '503'],
  '/api/passkey-backup/v1/credentials/revoke-all': ['200', '400', '401', '403', '409', '413', '415', '429', '500', '503'],
};

test('OpenAPI requires one-time Bearer grants and exact hardened POST response matrices', () => {
  assert.deepEqual(spec.components.securitySchemes.bearerAuth, {
    type: 'http',
    scheme: 'bearer',
    description: spec.components.securitySchemes.bearerAuth.description,
  });
  for (const [path, expectedResponses] of Object.entries(matrices)) {
    const operation = spec.paths[path].post;
    assert.deepEqual(operation.security, [{ bearerAuth: [] }], path);
    assert.deepEqual(Object.keys(operation.responses).sort(), expectedResponses, path);
    for (const status of expectedResponses.filter((value) => value !== '200')) {
      const responseRef = operation.responses[status].$ref;
      assert.match(responseRef, /^#\/components\/responses\//, `${path} HTTP ${status}`);
      const responseName = responseRef.split('/').at(-1);
      assert.equal(
        spec.components.responses[responseName].content['application/json'].schema.$ref,
        '#/components/schemas/ErrorResponse',
        `${path} HTTP ${status}`,
      );
    }
  }
});

test('OpenAPI user handle and generic error envelope match runtime validation', () => {
  assert.equal(spec.components.schemas.Base64UrlUserId.pattern, '^[A-Za-z0-9_-]{43}$');
  assert.ok(spec.components.schemas.AssertionAuthenticatorResponse.required.includes('userHandle'));
  assert.deepEqual(spec.components.schemas.AssertionAuthenticatorResponse.properties.userHandle.oneOf, [
    { $ref: '#/components/schemas/Base64UrlUserId' }, { type: 'null' },
  ]);
  assert.equal(spec.components.schemas.AssertionChallengeRequest.properties.credentialId.$ref,
    '#/components/schemas/Base64UrlCredentialId');
  assert.equal(spec.components.schemas.AssertionChallengeResponse.properties.credentialId.$ref,
    '#/components/schemas/Base64UrlCredentialId');
  assert.deepEqual(spec.components.schemas.ErrorResponse.required, [
    'ok', 'service', 'error', 'rpId', 'schemaVersion',
  ]);
  assert.equal(spec.components.schemas.ErrorResponse.additionalProperties, false);
});

test('OpenAPI credential lifecycle is bounded, non-secret, and documents the owner tombstone', () => {
  assert.deepEqual(spec.components.schemas.CredentialListResponse.properties.credentials.maxItems, 32);
  assert.deepEqual(spec.components.schemas.CredentialRevokeResponse.properties.remainingCredentials, {
    type: 'integer',
    minimum: 0,
    maximum: 32,
  });
  assert.deepEqual(spec.components.schemas.CredentialRevokeAllResponse.properties.remainingCredentials, {
    const: 0,
  });
  assert.deepEqual(spec.components.schemas.CredentialRevokeRequest.properties.confirmFinalRecoveryRemoval.const, true);
  assert.deepEqual(spec.components.schemas.CredentialRevokeAllRequest.properties.confirmFinalRecoveryRemoval.const, true);
  assert.equal(spec.paths['/api/passkey-backup/v1/credentials/revoke-all'].post.requestBody.content['application/json'].schema.$ref,
    '#/components/schemas/CredentialRevokeAllRequest');
  const descriptor = spec.components.schemas.CredentialDescriptor;
  assert.equal(descriptor.additionalProperties, false);
  assert.deepEqual(Object.keys(descriptor.properties).sort(), [
    'aaguid', 'backedUp', 'deviceType', 'id', 'registrationPlatform', 'transports',
  ]);
  for (const secretField of ['publicKey', 'userId', 'counter', 'ownerSubjectHash']) {
    assert.equal(Object.prototype.hasOwnProperty.call(descriptor.properties, secretField), false);
  }
  assert.match(spec.info.description, /owner tombstone/);
});

test('OpenAPI credential requests prohibit PRF and arbitrary local extension output', () => {
  const extension = spec.components.schemas.ServerCredentialExtensionResults;
  assert.equal(extension.additionalProperties, false);
  assert.deepEqual(Object.keys(extension.properties), ['credProps']);
  assert.deepEqual(extension.properties.credProps, {
    type: 'object', additionalProperties: false, required: ['rk'], properties: { rk: { type: 'boolean' } },
  });
  for (const name of ['RegistrationCredentialResponse', 'AssertionCredentialResponse']) {
    assert.deepEqual(spec.components.schemas[name].properties.clientExtensionResults, {
      $ref: '#/components/schemas/ServerCredentialExtensionResults',
    });
  }
});

test('runtime, OpenAPI, authorization scopes, and production config expose the same exact routes', () => {
  const runtimePostPaths = Object.entries(PATHS)
    .filter(([name]) => name !== 'health')
    .map(([, path]) => path)
    .sort();
  assert.deepEqual(Object.keys(AUTHORIZATION_SCOPES).sort(), runtimePostPaths);
  assert.deepEqual(Object.keys(matrices).sort(), runtimePostPaths);
  assert.deepEqual(
    Object.keys(spec.paths).filter((path) => path !== PATHS.health).sort(),
    runtimePostPaths,
  );
  assert.deepEqual(Object.values(productionConfig.challengeServicePaths).sort(), runtimePostPaths);
  assert.deepEqual([...productionConfig.requestAuthorization.protectedPaths].sort(), runtimePostPaths);
  assert.deepEqual(productionConfig.credentialLifecycle, {
    maxCredentialsPerStorageKey: 32,
    listExposesPublicKeyOrUserHandle: false,
    singleRevokeIdempotent: true,
    revokeAllIdempotent: true,
    finalRevocationRetainsOwnerTombstone: true,
    crossSubjectTakeoverDenied: true,
    sameOwnerReregistrationAllowed: true,
    ownerErasureEndpointEnabled: false,
    cloudDeletionOrdering: 'revoke-server-credentials-before-cloud-record',
  });
});
