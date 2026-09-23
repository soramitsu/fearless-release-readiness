#!/usr/bin/env node

import assert from 'node:assert/strict';
import { chmodSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

import {
  assertCompleteFanout,
  runStaticAudit,
  TAIRA_ASSET_DEFINITIONS_PATH,
  validateCanonicalTaggedTairaStatusDecoder,
  validateAssetDefinitions,
  validateDnsManifest,
  validateGenesis,
  validateNativeNevoReview,
  validateReviewDigestChain,
  validateRuntimeExecutionHostOpenApiArtifacts,
  validateStatus,
  validateToolsList,
} from './audit-taira-release-readiness.mjs';

const CHAIN_ID = 'fc56984b-2be7-431d-840e-21514d1883f0';
const XOR_ID = '6TEAJqbb8oEPmLncoNiMRbLEK6tw';
const COMMIT = '0123456789abcdef0123456789abcdef01234567';
const SCRIPT_DIR = dirname(fileURLToPath(import.meta.url));
let cases = 0;

function expectFailure(label, callback, expected) {
  assert.throws(callback, expected, label);
  cases += 1;
}

const genesis = {
  chain: CHAIN_ID,
  transactions: [
    {
      instructions: [
        {
          Register: {
            AssetDefinition: { id: XOR_ID, name: 'xor', spec: { scale: 9 } },
          },
        },
        {
          SetAssetDefinitionAlias: { alias: 'xor#universal', asset_definition_id: XOR_ID },
        },
      ],
    },
  ],
};
validateGenesis(genesis);
cases += 1;
expectFailure(
  'retired Taira chain identity is rejected',
  () => validateGenesis({ ...genesis, chain: 'iroha3-taira' }),
  /canonical UUID/u
);

expectFailure(
  'unconstrained canonical XOR is rejected',
  () => validateGenesis({ ...genesis, transactions: [{ instructions: [
    { Register: { AssetDefinition: { id: XOR_ID, name: 'xor', spec: { scale: null } } } },
    { SetAssetDefinitionAlias: { alias: 'xor#universal', asset_definition_id: XOR_ID } },
  ] }] }),
  /spec\.scale 9/u
);

const completeFanout = {
  'x-iroha-fanout-routes-attempted': '4',
  'x-iroha-fanout-routes-succeeded': '4',
  'x-iroha-fanout-routes-failed': '0',
  'x-iroha-fanout-routes-denied': '0',
  'x-iroha-fanout-routes-unavailable': '0',
  'x-iroha-fanout-routes-not-found': '0',
};
assertCompleteFanout(completeFanout);
cases += 1;
expectFailure(
  'partial 2xx fanout is rejected',
  () => assertCompleteFanout({
    ...completeFanout,
    'x-iroha-fanout-routes-succeeded': '1',
    'x-iroha-fanout-routes-failed': '3',
    'x-iroha-fanout-routes-unavailable': '3',
  }),
  /fanout is incomplete/u
);

const now = Date.now();
const status = {
  chain_id: CHAIN_ID,
  blocks: 3,
  peers: 4,
  time_since_last_block_ms: 1_000,
  last_block_committed_at_ms: now - 1_000,
  build: { git_commit_sha: COMMIT },
};
validateStatus(status, COMMIT, now);
cases += 1;
expectFailure(
  'status reports every independent release failure in one run',
  () => validateStatus({
    ...status,
    chain_id: '00000000-0000-0000-0000-000000000000',
    peers: 1,
    time_since_last_block_ms: 90_000,
    last_block_committed_at_ms: now - 90_000,
    build: { git_commit_sha: 'fedcba9876543210fedcba9876543210fedcba98' },
    consensus: { manifest_path: '/private/operator/manifest.json' },
  }, COMMIT, now),
  (error) => {
    assert.match(error.message, /canonical UUID/u);
    assert.match(error.message, /four peers/u);
    assert.match(error.message, /last 60 seconds/u);
    assert.match(error.message, /TAIRA_EXPECTED_BUILD_COMMIT/u);
    assert.match(error.message, /absolute manifest_path/u);
    return true;
  }
);
expectFailure(
  'stale block progress is rejected',
  () => validateStatus({ ...status, time_since_last_block_ms: 90_000 }, COMMIT, now),
  /last 60 seconds/u
);
expectFailure(
  'negative block age is rejected',
  () => validateStatus({ ...status, time_since_last_block_ms: -1 }, COMMIT, now),
  /last 60 seconds/u
);
expectFailure(
  'absolute manifest paths are rejected',
  () => validateStatus({ ...status, consensus: { manifest_path: '/srv/private/manifest.json' } }, COMMIT, now),
  /absolute manifest_path/u
);

assert.equal(
  TAIRA_ASSET_DEFINITIONS_PATH,
  '/v1/assets/definitions?limit=500&offset=0&count_mode=bounded'
);
validateAssetDefinitions({ count_mode: 'bounded', has_more: false, items: [{ id: XOR_ID, spec: { scale: 9 } }] });
cases += 1;
expectFailure(
  'live unconstrained XOR is rejected',
  () =>
    validateAssetDefinitions({
      count_mode: 'bounded',
      has_more: false,
      items: [{ id: XOR_ID, spec: { scale: null } }],
    }),
  /spec\.scale 9/u
);
expectFailure(
  'unproven live asset-definition pagination is rejected',
  () => validateAssetDefinitions({ count_mode: 'bounded', items: [{ id: XOR_ID, spec: { scale: 9 } }] }),
  /complete canonical XOR snapshot/u
);
for (const countMode of [undefined, null, 'exact', 'Bounded', true]) {
  expectFailure(
    `noncanonical live asset-definition count mode ${String(countMode)} is rejected`,
    () =>
      validateAssetDefinitions({
        count_mode: countMode,
        has_more: false,
        items: [{ id: XOR_ID, spec: { scale: 9 } }],
      }),
    /complete canonical XOR snapshot/u
  );
}

validateToolsList({
  jsonrpc: '2.0',
  id: 1,
  result: {
    tools: [
      {
        name: 'iroha.transactions.submit_and_wait',
        inputSchema: {
          additionalProperties: false,
          properties: { body_base64: { type: 'string' }, hash: { type: 'string' } },
          required: ['body_base64'],
        },
      },
    ],
  },
});
cases += 1;
expectFailure(
  'retired signed transaction field is rejected',
  () => validateToolsList({
    jsonrpc: '2.0',
    id: 1,
    result: {
      tools: [
        {
          name: 'iroha.transactions.submit_and_wait',
          inputSchema: {
            additionalProperties: false,
            properties: {
              body_base64: { type: 'string' },
              hash: { type: 'string' },
              signed_tx_base64: { type: 'string' },
            },
            required: ['signed_tx_base64'],
          },
        },
      ],
    },
  }),
  /required body_base64/u
);

expectFailure(
  'submit-and-wait without an explicit hash field is rejected',
  () => validateToolsList({
    jsonrpc: '2.0',
    id: 1,
    result: {
      tools: [
        {
          name: 'iroha.transactions.submit_and_wait',
          inputSchema: {
            additionalProperties: false,
            properties: { body_base64: { type: 'string' } },
            required: ['body_base64'],
          },
        },
      ],
    },
  }),
  /required body_base64/u
);

const dnsManifest = {
  records: Array.from({ length: 4 }, (_, index) => ({
    name: `taira-validator-${index + 1}.sora.org`,
    type: 'A',
    value: `192.0.2.${index + 1}`,
  })),
};
validateDnsManifest(dnsManifest);
cases += 1;
expectFailure(
  'duplicate validator DNS authority is rejected',
  () => validateDnsManifest({ ...dnsManifest, records: [...dnsManifest.records, dnsManifest.records[0]] }),
  /duplicate validator A record/u
);

const wrapper = readFileSync(resolve(SCRIPT_DIR, 'audit-taira-release-readiness.sh'), 'utf8');
for (const variable of [
  'NODE_EXTRA_CA_CERTS',
  'NODE_TLS_REJECT_UNAUTHORIZED',
  'NODE_USE_ENV_PROXY',
  'NODE_OPTIONS',
  'SSLKEYLOGFILE',
  'SSL_CERT_FILE',
  'HTTPS_PROXY',
  'GLOBAL_AGENT_HTTPS_PROXY',
]) {
  assert.match(wrapper, new RegExp(`-u ${variable}(?: \\\\)?$`, 'mu'), `wrapper must clear ${variable}`);
}
cases += 1;

const staticAuditSource = readFileSync(resolve(SCRIPT_DIR, 'audit-taira-release-readiness.mjs'), 'utf8');
for (const stalePositivePin of [
  "'&quoted_placement.total_reservation_fee',",
  "'pub quoted_placement: SoraHfPlacementRecordV1,',",
  "'fn hosted_http_capability_matches_placement(',",
  "'hosted_http_capability_matches_placement(',",
  "'SoracloudServiceRuntimeAuthority::AssignedValidator',",
  "'fn validate_and_record_transactions_executes_soracloud_mailbox_runtime_once()',",
  "'Iroha block runtime receipt contextual validation and zero-sentinel ingress'",
  "'Iroha exactly-once mailbox receipt consumption regression'",
  'cannot change lease-volume identity or economics during a rolling revision',
  'seed_public_hosted_http_rollout_app_with_local_replicas_and_snapshot_peer_id',
  'inrou_hosting_available_override',
  'production-qualified and test-overridable Inrou hosting eligibility',
]) {
  assert.ok(
    !staticAuditSource.includes(stalePositivePin),
    `Taira readiness audit must not retain stale positive pin ${stalePositivePin}`
  );
}
for (const firstReleasePin of [
  'pub resource_profile: SoraHfResourceProfileV1,',
  'first-release queued HF windows must not persist stale placement quotes',
  'shared Inrou assignment resolver instead of a local capability matcher',
  'SoraHfSharedLeaseActionV1::ActivationFailed',
  'pub failure_reason: Option<String>,',
  'queued_next_window.lease_asset_definition_id',
  'deployment.lease_volume_states.iter().any(|volume|',
  'validate_soracloud_deployment_lease_volume_bindings(',
  'validate_soracloud_service_revision_identity(',
  'soracloud_validator_has_active_peer_binding(',
  'Iroha shared topology-independent validator account/peer identity contract',
  'Iroha canonical HF placement identity derivation',
  'Iroha canonical HF shared-lease pool identity derivation',
  'Iroha HF placement record canonical identity validation',
  'Iroha durable HF model-host capability account/peer identity contract',
  'Iroha durable HF placement account/peer identity contract',
  'Iroha structurally canonical HF runtime receipt host attribution',
  'Iroha durable Inrou capability account/peer identity contract',
  'Iroha durable Inrou placement account/peer identity contract',
  'Iroha durable Inrou runtime account/peer identity contract',
  'Iroha active HF validator lifecycle gate requires canonical account-derived peer identity',
  'Iroha live HF model-host exact active peer binding gate',
  'Iroha HF model-host advert authority and peer-binding admission',
  'Iroha HF model-host capability wrong-account peer regression',
  'Iroha HF placement wrong-account peer regression',
  'Iroha HF runtime receipt host canonical-identity regression',
  'Iroha Inrou capability wrong-account peer regression',
  'Iroha Inrou placement wrong-account peer regression',
  'Iroha Inrou runtime wrong-account peer regression',
  'Iroha HF shared-lease member monotonic accounting bounds',
  'Iroha core shared canonical HF pool identity derivation',
  'Iroha Torii shared canonical HF pool identity derivation',
  'Iroha canonical HF placement economics and lifecycle projection',
  'Iroha live HF placement canonical key, economics, and status admission',
  'Iroha uploaded-model finalization allocates distinct weight and artifact audit sequences',
  'Iroha uploaded-model distinct audit-sequence regression',
  'Iroha restored Inrou capability canonical account/peer regression',
  'Iroha immutable durable state-binding revision contract',
  'Iroha service-state restore revision, binding, audit, and quota closure',
  'Iroha service-state restore closure regression',
  'Iroha training and model restore lineage closure',
  'Iroha apartment restore status, wallet, and reverse-audit closure',
  'Iroha HF restore pool, member, placement, and capability closure',
  'Iroha restored Inrou capability and aggregate reservation closure',
  'Iroha first-release required restore boundary for ${requiredProjectionStore}',
  'cannot change lease-volume identity or economics',
  'admitted revision `{service_version}` has no authoritative deployment',
  'Iroha persisted deployment cross-record restore regressions',
  'Iroha public hosted routing rejects non-exact authoritative storage rows',
  'Iroha control-plane accounting rejects non-exact authoritative storage rows',
  'Iroha daemon materialization through shared exact storage invariant',
  'seed_public_hosted_http_rollout_app_with_replica_plans_and_snapshot_peer_id',
  'Iroha daemon production-qualified Inrou hosting eligibility',
  'Iroha daemon aggregate capacity regression uses schema-valid independent placements',
  'Iroha daemon lease-boundary regression uses a valid authoritative sequence record',
  'active_inrou_resolver_requires_exact_admitted_lease_volume_economics()',
  'inrou_peer_rotation_invalidates_stale_capability_and_placement_immediately()',
  'resolve_active_inrou_replica_assignments(',
  'pub enum SoraRuntimeExecutionHostV1 {',
  'Iroha structurally canonical deterministic mailbox host attribution',
  'Iroha deterministic mailbox host canonical-identity regression',
  'Iroha first-release runtime receipt host enum excludes impossible Inrou attribution',
  'Iroha runtime receipt writer excludes impossible handlerless Inrou attribution',
  'Iroha generic receipt instruction excludes impossible handlerless Inrou attribution',
  'Iroha Torii OpenAPI artifacts must remain byte-identical across canonical, current, and packaged copies',
  'OpenAPI first-release runtime receipt host variants',
  'Iroha OpenAPI exact runtime execution-host regression',
  'resolve_generated_hf_active_placement(',
  'message.from_service_version = source_deployment.current_service_version;',
  'message.delivery_delay_sequences >= retention_sequences',
  'has already been consumed',
  'soracloud_private_uploaded_model_execution_receipts()',
  'soracloud_mailbox_messages()',
  'ensure_soracloud_sequence_is_next(',
  'authoritative_sequences.insert(sequence)',
  'storage key must match the embedded evidence_id',
  'Iroha first-release required private-receipt restore boundary',
  'source handler must be an update/private_update mailbox handler',
  'ledger schedule must be exactly derived from enqueue, delay, and destination retention',
  'HF-generated receipts and only those receipts must carry HF model-host attribution',
  'one mailbox message must not be consumed by multiple receipts',
  'private receipt must exactly match its uploaded-model bundle and policy',
  'pub struct SoraOrderedMailboxResultV1 {',
  'pub struct ApplySoracloudOrderedMailboxResult {',
  'must carry deterministic-validator attribution',
  'Iroha ordered-mailbox wire graph rejects unknown fields',
  'resolve_ordered_mailbox_executor(',
  'ordered mailbox execution cannot bypass governed FHE input-admission proofs',
  'runtime_state.materialized_bundle_hash != bundle.container.bundle_hash',
  'ordered_mailbox_result_is_authorized_occ_checked_and_applied_atomically()',
  'ordered_mailbox_runtime_receipt_id(',
  'receipt.execution_host.clone()',
  'mailbox receipts must carry deterministic-validator execution_host attribution',
  'Iroha canonical ordered-mailbox receipt restore regression',
  'Iroha canonical sequence-independent local-read receipt identity',
  'Iroha node-issued typed local-read host attribution, identity, and submission sentinel',
  'local-read receipt ids must bind their exact immutable contents',
  'historical receipt attribution must survive later validator peer rotation',
  'a recomputed receipt ID must not mask structurally invalid host attribution',
  'Iroha historical mailbox restore independence from mutable validator topology',
  'deterministic-validator attribution must not restore without mailbox context',
  'Iroha canonical ordered-mailbox executor regression',
  'Execution is deliberately off-consensus.',
  'production_worker_submits_one_canonical_result_and_skips_stale_revision_head()',
  'the same committed tip must not enqueue duplicate submissions',
  'Iroha daemon canonical local Inrou peer binding',
  'inrou_host_refuses_a_noncanonical_local_peer_identity()',
  'legacy block-time mailbox execution must remain cfg(test)-only at every call site',
  'Torii public route kinds exclude caller-owned mailbox execution',
  'Torii read-only deterministic public method gate',
  'Torii public ingress limited to hosted HTTP and deterministic reads',
  'Torii ledger-only mailbox public-route rejection tests',
]) {
  assert.ok(
    staticAuditSource.includes(firstReleasePin),
    `Taira readiness audit must pin first-release contract ${firstReleasePin}`
  );
}
cases += 1;

const irohaRoot = resolve(SCRIPT_DIR, '../../iroha');
const runtimeExecutionHostOpenApiArtifacts = {
  canonical: readFileSync(resolve(irohaRoot, 'artifacts/openapi/torii.json'), 'utf8'),
  current: readFileSync(resolve(irohaRoot, 'artifacts/openapi/versions/current/torii.json'), 'utf8'),
  packaged: readFileSync(resolve(irohaRoot, 'crates/iroha_torii/assets/openapi/torii.json'), 'utf8'),
};
validateRuntimeExecutionHostOpenApiArtifacts(runtimeExecutionHostOpenApiArtifacts);
cases += 1;

function mutateRuntimeExecutionHostOpenApi(specification, mutation) {
  const document = JSON.parse(specification);
  mutation(document.components.schemas);
  return `${JSON.stringify(document)}\n`;
}

function omitHfModelHostSelectionSeedHash(specification) {
  return mutateRuntimeExecutionHostOpenApi(specification, (schemas) => {
    const hfSchema = schemas.SoraRuntimeHfModelHostV1;
    delete hfSchema.properties.selection_seed_hash;
    hfSchema.required = hfSchema.required.filter((field) => field !== 'selection_seed_hash');
  });
}

function substituteHfModelHostVariant(specification) {
  return mutateRuntimeExecutionHostOpenApi(specification, (schemas) => {
    const hfVariant = schemas.SoraRuntimeExecutionHostV1.oneOf.find(
      (variant) => variant.properties?.host_kind?.const === 'HfModelHost'
    );
    hfVariant.properties.value.$ref =
      '#/components/schemas/SoraRuntimeDeterministicValidatorHostV1';
  });
}

function allowAdditionalHfModelHostProperties(specification) {
  return mutateRuntimeExecutionHostOpenApi(specification, (schemas) => {
    schemas.SoraRuntimeHfModelHostV1.additionalProperties = true;
  });
}

for (const artifact of ['canonical', 'current', 'packaged']) {
  expectFailure(
    `${artifact} OpenAPI artifact cannot omit an HF model-host identity field`,
    () => validateRuntimeExecutionHostOpenApiArtifacts({
      ...runtimeExecutionHostOpenApiArtifacts,
      [artifact]: omitHfModelHostSelectionSeedHash(
        runtimeExecutionHostOpenApiArtifacts[artifact]
      ),
    }),
    /SoraRuntimeHfModelHostV1/u
  );
  expectFailure(
    `${artifact} OpenAPI artifact cannot substitute the HF model-host variant`,
    () => validateRuntimeExecutionHostOpenApiArtifacts({
      ...runtimeExecutionHostOpenApiArtifacts,
      [artifact]: substituteHfModelHostVariant(runtimeExecutionHostOpenApiArtifacts[artifact]),
    }),
    /HfModelHost value/u
  );
  expectFailure(
    `${artifact} OpenAPI artifact must keep the HF model-host schema closed`,
    () => validateRuntimeExecutionHostOpenApiArtifacts({
      ...runtimeExecutionHostOpenApiArtifacts,
      [artifact]: allowAdditionalHfModelHostProperties(
        runtimeExecutionHostOpenApiArtifacts[artifact]
      ),
    }),
    /SoraRuntimeHfModelHostV1 must be a strict object schema/u
  );
}

const identicallyOmittedHfModelHostField = omitHfModelHostSelectionSeedHash(
  runtimeExecutionHostOpenApiArtifacts.canonical
);
expectFailure(
  'byte-identical OpenAPI artifacts cannot jointly omit an HF model-host identity field',
  () => validateRuntimeExecutionHostOpenApiArtifacts({
    canonical: identicallyOmittedHfModelHostField,
    current: identicallyOmittedHfModelHostField,
    packaged: identicallyOmittedHfModelHostField,
  }),
  /SoraRuntimeHfModelHostV1/u
);

const identicallySubstitutedHfModelHostVariant = substituteHfModelHostVariant(
  runtimeExecutionHostOpenApiArtifacts.canonical
);
expectFailure(
  'byte-identical OpenAPI artifacts cannot jointly substitute the HF model-host variant',
  () => validateRuntimeExecutionHostOpenApiArtifacts({
    canonical: identicallySubstitutedHfModelHostVariant,
    current: identicallySubstitutedHfModelHostVariant,
    packaged: identicallySubstitutedHfModelHostVariant,
  }),
  /HfModelHost value/u
);

const nevoFixtureRoot = resolve(irohaRoot, 'crates/iroha_kagami/tests/fixtures/taira_nevo_v2');
const nevoDigestInputs = {
  baseConfig: readFileSync(resolve(irohaRoot, 'configs/soranexus/taira/config.toml'), 'utf8'),
  baseGenesis: readFileSync(resolve(irohaRoot, 'configs/soranexus/taira/genesis.json'), 'utf8'),
  publicInputs: JSON.parse(readFileSync(resolve(nevoFixtureRoot, 'public-inputs.json'), 'utf8')),
  unsignedGenesis: readFileSync(resolve(nevoFixtureRoot, 'unsigned-genesis.json'), 'utf8'),
};
const nevoReview = JSON.parse(readFileSync(resolve(nevoFixtureRoot, 'review.json'), 'utf8'));
validateReviewDigestChain(nevoReview, nevoDigestInputs);
cases += 1;
expectFailure(
  'stale NEVO source-template digest is rejected',
  () => validateReviewDigestChain({ ...nevoReview, base_config_sha256: '0'.repeat(64) }, nevoDigestInputs),
  /base_config_sha256/u
);
const cargoFailureRoot = mkdtempSync(resolve(tmpdir(), 'fearless-taira-cargo-failure-'));
const originalPath = process.env.PATH;
try {
  const fakeBin = resolve(cargoFailureRoot, 'bin');
  const fakeCargo = resolve(fakeBin, 'cargo');
  mkdirSync(fakeBin);
  writeFileSync(
    fakeCargo,
    "#!/bin/sh\nprintf '%s\\n' 'error: could not find `Cargo.toml` in the requested workspace' >&2\nexit 101\n",
    { flag: 'wx' }
  );
  chmodSync(fakeCargo, 0o755);
  process.env.PATH = fakeBin;
  expectFailure(
    'native validator failures retain a bounded Cargo diagnostic',
    () =>
      validateNativeNevoReview({
        irohaRoot: cargoFailureRoot,
        reviewPath: resolve(nevoFixtureRoot, 'review.json'),
        unsignedGenesisPath: resolve(nevoFixtureRoot, 'unsigned-genesis.json'),
      }),
    /could not find `Cargo\.toml`/u
  );
} finally {
  if (originalPath === undefined) delete process.env.PATH;
  else process.env.PATH = originalPath;
  rmSync(cargoFailureRoot, { force: true, recursive: true });
}

validateNativeNevoReview({
  irohaRoot,
  reviewPath: resolve(nevoFixtureRoot, 'review.json'),
  unsignedGenesisPath: resolve(nevoFixtureRoot, 'unsigned-genesis.json'),
});
cases += 1;

const mutationRoot = mkdtempSync(resolve(tmpdir(), 'fearless-taira-nevo-'));
try {
  const mutatedReview = structuredClone(nevoReview);
  mutatedReview.public_identities = {
    ...(mutatedReview.public_identities ?? {}),
    onboarding_authority_account_id:
      'testuﾛ1PｵEmｷjMZZﾑﾙeｱﾁﾎﾅﾂﾊmECepdbﾎｳ2uWﾃｸﾊﾘvｵi2ｦP1Y18A',
  };
  validateReviewDigestChain(mutatedReview, nevoDigestInputs);
  const mutatedReviewPath = resolve(mutationRoot, 'mutated-review.json');
  writeFileSync(mutatedReviewPath, `${JSON.stringify(mutatedReview)}\n`, { flag: 'wx' });
  expectFailure(
    'digest-unbound NEVO identity mutation is rejected by native recomposition',
    () => validateNativeNevoReview({
      irohaRoot,
      reviewPath: mutatedReviewPath,
      unsignedGenesisPath: resolve(nevoFixtureRoot, 'unsigned-genesis.json'),
    }),
    /native Kagami Taira NEVO validation failed/u
  );
} finally {
  rmSync(mutationRoot, { force: true, recursive: true });
}

runStaticAudit({ root: resolve(SCRIPT_DIR, '..'), parent: resolve(SCRIPT_DIR, '../..') });
cases += 1;

const tairaCliSource = readFileSync(resolve(irohaRoot, 'crates/iroha_cli/src/taira.rs'), 'utf8');
validateCanonicalTaggedTairaStatusDecoder(tairaCliSource);
cases += 1;
expectFailure(
  'permissive tagged Taira status decoding is rejected',
  () =>
    validateCanonicalTaggedTairaStatusDecoder(
      tairaCliSource.replace(
        '    if object.len() != 2 || !object.get("value").is_some_and(Value::is_null) {\n        return None;\n    }\n',
        ''
      )
    ),
  /canonical tagged Taira status decoder/u
);

process.stdout.write(`[taira-readiness-test] ${cases} cases passed\n`);
