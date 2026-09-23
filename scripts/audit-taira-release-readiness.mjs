#!/usr/bin/env node

import { createHash } from 'node:crypto';
import { spawnSync } from 'node:child_process';
import { promises as dns } from 'node:dns';
import { readFileSync } from 'node:fs';
import https from 'node:https';
import { isIP } from 'node:net';
import { dirname, resolve } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

const TAIRA_CHAIN_ID = 'fc56984b-2be7-431d-840e-21514d1883f0';
const TAIRA_XOR_ASSET_ID = '6TEAJqbb8oEPmLncoNiMRbLEK6tw';
const TAIRA_XOR_SCALE = 9;
const TAIRA_ORIGIN = 'https://taira.sora.org';
const TAIRA_ASSET_DEFINITIONS_PATH = '/v1/assets/definitions?limit=500&offset=0&count_mode=bounded';
const MAX_RESPONSE_BYTES = 1_048_576;
const MAX_BLOCK_AGE_MS = 60_000;
const MAX_NATIVE_VALIDATION_MS = 900_000;

class AuditError extends Error {}

function fail(message) {
  throw new AuditError(message);
}

function boundedDiagnostic(error) {
  const message =
    error instanceof Error
      ? error.message
      : typeof error === 'string' && error.trim()
        ? error
        : 'unexpected check failure';
  return message.replace(/[\u0000-\u001f\u007f-\u009f]/gu, ' ').slice(0, 512);
}

function requireText(path, label) {
  try {
    return readFileSync(path, 'utf8');
  } catch (error) {
    fail(`${label} is missing or unreadable at ${path}: ${error instanceof Error ? error.message : 'unknown error'}`);
  }
}

function requireJson(path, label) {
  const text = requireText(path, label);

  try {
    return JSON.parse(text);
  } catch {
    fail(`${label} must be valid JSON at ${path}`);
  }
}

function requireLiteral(text, literal, label) {
  if (!text.includes(literal)) fail(`${label} is missing ${JSON.stringify(literal)}`);
}

function rejectLiterals(text, literals, label) {
  for (const literal of literals) {
    if (text.includes(literal)) fail(`${label} must not contain ${JSON.stringify(literal)}`);
  }
}

function requirePattern(text, pattern, label) {
  if (!pattern.test(text)) fail(`${label} does not satisfy ${pattern}`);
}

function requireExactlyOnce(text, literal, label) {
  const first = text.indexOf(literal);
  if (first < 0) fail(`${label} is missing ${JSON.stringify(literal)}`);
  if (text.indexOf(literal, first + literal.length) >= 0) {
    fail(`${label} must contain ${JSON.stringify(literal)} exactly once`);
  }
  return first;
}

function requireScopedLiterals(text, start, end, literals, label) {
  const startIndex = requireExactlyOnce(text, start, `${label} start`);
  const endIndex = text.indexOf(end, startIndex + start.length);
  if (endIndex < 0) fail(`${label} is missing its closing scope ${JSON.stringify(end)}`);
  const scope = text.slice(startIndex, endIndex);
  for (const literal of literals) requireLiteral(scope, literal, label);
  return scope;
}

function requireOrdered(text, before, after, label) {
  const beforeIndex = text.indexOf(before);
  const afterIndex = text.indexOf(after);
  if (beforeIndex < 0 || afterIndex < 0 || beforeIndex >= afterIndex) {
    fail(`${label} must place ${JSON.stringify(before)} before ${JSON.stringify(after)}`);
  }
}

function requireAtLeast(text, literal, minimum, label) {
  let count = 0;
  let offset = 0;
  while ((offset = text.indexOf(literal, offset)) >= 0) {
    count += 1;
    offset += literal.length;
  }
  if (count < minimum) {
    fail(`${label} must contain ${JSON.stringify(literal)} at least ${minimum} times; found ${count}`);
  }
}

function isJsonObject(value) {
  return value !== null && typeof value === 'object' && !Array.isArray(value);
}

function requireExactObjectKeys(value, expectedKeys, label) {
  if (!isJsonObject(value)) fail(`${label} must be an object`);
  const actual = Object.keys(value).sort();
  const expected = [...expectedKeys].sort();
  if (actual.length !== expected.length || actual.some((key, index) => key !== expected[index])) {
    fail(`${label} fields must be exactly ${expected.join(', ')}`);
  }
}

function requireExactStringSet(value, expectedValues, label) {
  if (!Array.isArray(value) || value.some((item) => typeof item !== 'string')) {
    fail(`${label} must be an array of strings`);
  }
  const actual = [...value].sort();
  const expected = [...expectedValues].sort();
  if (actual.length !== expected.length || actual.some((item, index) => item !== expected[index])) {
    fail(`${label} must be exactly ${expected.join(', ')}`);
  }
}

function requireExactLeafSchema(value, expected, label) {
  requireExactObjectKeys(value, Object.keys(expected), label);
  for (const [key, expectedValue] of Object.entries(expected)) {
    if (value[key] !== expectedValue) {
      fail(`${label} ${key} must equal ${JSON.stringify(expectedValue)}`);
    }
  }
}

function requireStrictOpenApiObjectSchema(schemas, name, requiredFields, label) {
  const schema = schemas[name];
  requireExactObjectKeys(
    schema,
    ['additionalProperties', 'properties', 'required', 'type'],
    `${label} ${name}`
  );
  if (schema.type !== 'object' || schema.additionalProperties !== false) {
    fail(`${label} ${name} must be a strict object schema`);
  }
  requireExactStringSet(schema.required, requiredFields, `${label} ${name} required fields`);
  requireExactObjectKeys(schema.properties, requiredFields, `${label} ${name} properties`);
  return schema.properties;
}

function validateRuntimeExecutionHostOpenApi(specification, label) {
  let document;
  try {
    document = JSON.parse(specification);
  } catch {
    fail(`Iroha ${label} OpenAPI artifact must be valid JSON`);
  }

  const schemas = document?.components?.schemas;
  if (!isJsonObject(schemas)) fail(`Iroha ${label} OpenAPI artifact must expose component schemas`);
  const artifactLabel = `Iroha ${label} OpenAPI runtime execution-host contract`;
  if (Object.hasOwn(schemas, 'SoraRuntimeInrouReplicaHostV1')) {
    fail(`${artifactLabel} must not expose retired SoraRuntimeInrouReplicaHostV1`);
  }

  const deterministicProperties = requireStrictOpenApiObjectSchema(
    schemas,
    'SoraRuntimeDeterministicValidatorHostV1',
    ['lane_id', 'validator_account_id', 'peer_id'],
    artifactLabel
  );
  requireExactLeafSchema(
    deterministicProperties.lane_id,
    { format: 'uint32', maximum: 4_294_967_295, minimum: 0, type: 'integer' },
    `${artifactLabel} deterministic-validator lane_id`
  );
  requireExactLeafSchema(
    deterministicProperties.validator_account_id,
    { type: 'string' },
    `${artifactLabel} deterministic-validator validator_account_id`
  );
  requireExactLeafSchema(
    deterministicProperties.peer_id,
    { type: 'string' },
    `${artifactLabel} deterministic-validator peer_id`
  );

  const hfProperties = requireStrictOpenApiObjectSchema(
    schemas,
    'SoraRuntimeHfModelHostV1',
    [
      'placement_id',
      'source_id',
      'pool_id',
      'selection_seed_hash',
      'validator_account_id',
      'peer_id',
    ],
    artifactLabel
  );
  for (const digestField of ['placement_id', 'source_id', 'pool_id', 'selection_seed_hash']) {
    requireExactLeafSchema(
      hfProperties[digestField],
      { $ref: '#/components/schemas/Hash' },
      `${artifactLabel} HF model-host ${digestField}`
    );
  }
  requireExactLeafSchema(
    hfProperties.validator_account_id,
    { type: 'string' },
    `${artifactLabel} HF model-host validator_account_id`
  );
  requireExactLeafSchema(
    hfProperties.peer_id,
    { type: 'string' },
    `${artifactLabel} HF model-host peer_id`
  );

  const executionHost = schemas.SoraRuntimeExecutionHostV1;
  requireExactObjectKeys(executionHost, ['oneOf'], `${artifactLabel} SoraRuntimeExecutionHostV1`);
  if (!Array.isArray(executionHost.oneOf) || executionHost.oneOf.length !== 2) {
    fail(`${artifactLabel} variants must be exactly DeterministicValidator and HfModelHost`);
  }
  const expectedVariants = new Map([
    ['DeterministicValidator', '#/components/schemas/SoraRuntimeDeterministicValidatorHostV1'],
    ['HfModelHost', '#/components/schemas/SoraRuntimeHfModelHostV1'],
  ]);
  const seenVariants = new Set();
  for (const variant of executionHost.oneOf) {
    requireExactObjectKeys(
      variant,
      ['additionalProperties', 'properties', 'required', 'type'],
      `${artifactLabel} variant`
    );
    if (variant.type !== 'object' || variant.additionalProperties !== false) {
      fail(`${artifactLabel} variants must be strict object schemas`);
    }
    requireExactStringSet(
      variant.required,
      ['host_kind', 'value'],
      `${artifactLabel} variant required fields`
    );
    requireExactObjectKeys(
      variant.properties,
      ['host_kind', 'value'],
      `${artifactLabel} variant properties`
    );
    const hostKind = variant.properties.host_kind;
    if (!isJsonObject(hostKind)) fail(`${artifactLabel} variant host_kind must be an object`);
    const tag = hostKind.const;
    const expectedReference = expectedVariants.get(tag);
    if (expectedReference === undefined || seenVariants.has(tag)) {
      fail(`${artifactLabel} variants must be exactly DeterministicValidator and HfModelHost`);
    }
    requireExactLeafSchema(
      hostKind,
      { const: tag, type: 'string' },
      `${artifactLabel} ${tag} host_kind`
    );
    requireExactLeafSchema(
      variant.properties.value,
      { $ref: expectedReference },
      `${artifactLabel} ${tag} value`
    );
    seenVariants.add(tag);
  }
  if (seenVariants.size !== expectedVariants.size) {
    fail(`${artifactLabel} variants must be exactly DeterministicValidator and HfModelHost`);
  }
  rejectLiterals(
    specification,
    ['SoraRuntimeInrouReplicaHostV1', '"InrouReplica"'],
    `Iroha ${label} OpenAPI first-release runtime receipt host variants`
  );
}

function validateRuntimeExecutionHostOpenApiArtifacts({ canonical, current, packaged }) {
  for (const [label, specification] of [
    ['canonical', canonical],
    ['current', current],
    ['packaged', packaged],
  ]) {
    validateRuntimeExecutionHostOpenApi(specification, label);
  }
  if (canonical !== current || canonical !== packaged) {
    fail('Iroha Torii OpenAPI artifacts must remain byte-identical across canonical, current, and packaged copies');
  }
}

export function validateCanonicalTaggedTairaStatusDecoder(tairaCli) {
  const signature = "fn tagged_enum_name<'a>(value: &'a Value, field: &str)";
  const scope = requireScopedLiterals(
    tairaCli,
    signature,
    '\nfn mcp_tool_names(',
    [
      'let object = value.as_object()?;',
      'object.len() != 2',
      '!object.get("value").is_some_and(Value::is_null)',
      'object.get(field)?.as_str()',
    ],
    'Iroha canonical tagged Taira status decoder'
  );
  if (scope.includes('value.as_str()')) {
    fail('Iroha first-release Taira status must reject legacy untagged enum strings');
  }
}

function walk(value, visit) {
  if (!value || typeof value !== 'object') return;
  visit(value);
  if (Array.isArray(value)) value.forEach((item) => walk(item, visit));
  else Object.values(value).forEach((item) => walk(item, visit));
}

function sha256(value) {
  return createHash('sha256').update(value).digest('hex');
}

function validateReviewDigestChain(review, { baseConfig, baseGenesis, publicInputs, unsignedGenesis }) {
  if (!review || typeof review !== 'object' || Array.isArray(review)) {
    fail('Taira NEVO review must be an object');
  }
  if (!publicInputs || typeof publicInputs !== 'object' || Array.isArray(publicInputs)) {
    fail('Taira NEVO public inputs must be an object');
  }
  if (review.chain !== TAIRA_CHAIN_ID) fail('Taira NEVO review chain must equal the canonical UUID');

  const canonicalPublicInputs = `${JSON.stringify(
    Object.fromEntries(Object.entries(publicInputs).sort(([left], [right]) => (left < right ? -1 : left > right ? 1 : 0)))
  )}\n`;
  const expected = {
    base_config_sha256: sha256(baseConfig),
    base_genesis_sha256: sha256(baseGenesis),
    public_inputs_sha256: sha256(canonicalPublicInputs),
    unsigned_genesis_sha256: sha256(unsignedGenesis),
  };
  const mismatches = Object.entries(expected)
    .filter(([field, digest]) => review[field] !== digest)
    .map(([field]) => field);
  if (mismatches.length > 0) {
    fail(`Taira NEVO review digest chain is stale: ${mismatches.join(', ')}`);
  }
}

function validateNativeNevoReview({ irohaRoot, reviewPath, unsignedGenesisPath }) {
  let reviewBytes;
  let unsignedGenesisBytes;
  try {
    reviewBytes = readFileSync(reviewPath);
    unsignedGenesisBytes = readFileSync(unsignedGenesisPath);
  } catch {
    fail('native Kagami Taira NEVO validation inputs are missing or unreadable');
  }

  const command = spawnSync(
    'cargo',
    [
      'run',
      '--quiet',
      '--locked',
      '--offline',
      '-p',
      'iroha_kagami',
      '--bin',
      'kagami',
      '--',
      'privacy-bootstrap',
      'validate-taira-nevo-review-v1',
      '--unsigned-genesis',
      unsignedGenesisPath,
      '--review',
      reviewPath,
    ],
    {
      cwd: irohaRoot,
      encoding: 'utf8',
      env: {
        ...process.env,
        CARGO_NET_OFFLINE: 'true',
        CARGO_TERM_COLOR: 'never',
      },
      maxBuffer: MAX_RESPONSE_BYTES,
      timeout: MAX_NATIVE_VALIDATION_MS,
    }
  );

  if (command.error?.code === 'ETIMEDOUT') {
    fail(`native Kagami Taira NEVO validation failed: exceeded ${MAX_NATIVE_VALIDATION_MS}ms`);
  }
  if (command.error) fail('native Kagami Taira NEVO validation failed: validator could not run');
  if (command.signal) fail(`native Kagami Taira NEVO validation failed: terminated by ${command.signal}`);
  if (command.status !== 0) {
    const diagnostic = boundedDiagnostic(command.stderr || command.stdout);
    fail(
      `native Kagami Taira NEVO validation failed with exit status ${command.status ?? 'unknown'}: ${diagnostic}`
    );
  }
  const lines = command.stdout.trim().split(/\r?\n/u).filter(Boolean);
  if (lines.length !== 1) fail('native Kagami Taira NEVO validator must emit exactly one JSON receipt');

  let receipt;
  try {
    receipt = JSON.parse(lines[0]);
  } catch {
    fail('native Kagami Taira NEVO validator emitted an invalid JSON receipt');
  }
  if (!receipt || typeof receipt !== 'object' || Array.isArray(receipt)) {
    fail('native Kagami Taira NEVO validator receipt must be an object');
  }
  const expectedKeys = [
    'native_recomposition_passed',
    'review_sha256',
    'status',
    'unsigned_genesis_sha256',
  ];
  const actualKeys = Object.keys(receipt).sort();
  if (JSON.stringify(actualKeys) !== JSON.stringify(expectedKeys)) {
    fail('native Kagami Taira NEVO validator receipt has an unexpected shape');
  }
  if (
    receipt.status !== 'validated' ||
    receipt.native_recomposition_passed !== true ||
    receipt.review_sha256 !== sha256(reviewBytes) ||
    receipt.unsigned_genesis_sha256 !== sha256(unsignedGenesisBytes)
  ) {
    fail('native Kagami Taira NEVO validator receipt does not bind the reviewed artifacts');
  }

  return receipt;
}

function validateGenesis(genesis) {
  if (genesis?.chain !== TAIRA_CHAIN_ID) {
    fail('Taira genesis chain must equal the canonical UUID');
  }
  const definitions = [];
  const publicAliases = [];

  walk(genesis, (value) => {
    const definition = value?.Register?.AssetDefinition;
    if (definition?.id === TAIRA_XOR_ASSET_ID) definitions.push(definition);

    const alias = value?.SetAssetDefinitionAlias;
    if (alias?.alias === 'xor#universal') publicAliases.push(alias);
  });

  if (definitions.length !== 1) {
    fail(`Taira genesis must register canonical XOR exactly once; found ${definitions.length}`);
  }
  if (definitions[0]?.name !== 'xor' || definitions[0]?.spec?.scale !== TAIRA_XOR_SCALE) {
    fail('Taira canonical XOR must be named xor with spec.scale 9');
  }
  if (publicAliases.length !== 1 || publicAliases[0]?.asset_definition_id !== TAIRA_XOR_ASSET_ID) {
    fail('Taira genesis must bind xor#universal exactly once to canonical XOR');
  }
}

function validateDnsManifest(manifest) {
  const records = Array.isArray(manifest?.records) ? manifest.records : [];
  const validatorNames = Array.from({ length: 4 }, (_, index) => `taira-validator-${index + 1}.sora.org`);
  const known = new Set(validatorNames);
  const expected = new Set(validatorNames);
  const seen = new Set();

  for (const record of records) {
    if (!known.has(record?.name)) continue;
    if (record?.type !== 'A' || typeof record.value !== 'string' || isIP(record.value) !== 4) {
      fail(`Taira DNS manifest has an invalid validator A record for ${record?.name}`);
    }
    if (seen.has(record.name)) fail(`Taira DNS manifest has a duplicate validator A record for ${record.name}`);
    seen.add(record.name);
    expected.delete(record.name);
  }
  if (expected.size) fail(`Taira DNS manifest is missing validator A records: ${[...expected].join(', ')}`);
}

function validateWalletRegistry(text, label, { scopeEnd, scopeLiterals, scopeStart }) {
  requireLiteral(text, TAIRA_CHAIN_ID, `${label} Taira chain contract`);
  requireLiteral(text, TAIRA_XOR_ASSET_ID, `${label} Taira native asset contract`);
  requireScopedLiterals(text, scopeStart, scopeEnd, scopeLiterals, `${label} Taira registry entry`);
  if (text.includes('iroha3-taira')) fail(`${label} still contains the retired Taira chain alias`);
}

function runStaticAudit({ root, parent }) {
  const webRegistry = requireText(
    resolve(root, 'fearless-wallet-web/src/consts/universalWallet.ts'),
    'web universal-wallet registry'
  );
  const webTorii = requireText(
    resolve(root, 'fearless-wallet-web/src/extension/background/extension-base/src/services/iroha-torii-service/index.ts'),
    'web Torii client'
  );
  const webBalance = requireText(
    resolve(root, 'fearless-wallet-web/src/extension/background/extension-base/src/services/balance-service/IrohaBalanceService.ts'),
    'web Iroha balance service'
  );
  const webHistory = requireText(
    resolve(root, 'fearless-wallet-web/src/history/fetchingHistory.ts'),
    'web Iroha history service'
  );
  const webTransfer = requireText(
    resolve(root, 'fearless-wallet-web/src/extension/background/extension-base/src/api/iroha/transfer.ts'),
    'web Iroha transfer service'
  );
  const webIrohaAddress = requireText(
    resolve(root, 'fearless-wallet-web/src/util/iroha.ts'),
    'web Iroha address codec'
  );
  const webBaseApi = requireText(
    resolve(root, 'fearless-wallet-web/src/util/BaseApi.ts'),
    'web foreground address routing'
  );
  const webState = requireText(
    resolve(root, 'fearless-wallet-web/src/extension/background/extension-base/src/background/handlers/State.ts'),
    'web background address routing'
  );
  const androidRegistry = requireText(
    resolve(root, 'fearless-Android/common/src/main/java/jp/co/soramitsu/common/model/UniversalWalletRegistry.kt'),
    'Android universal-wallet registry'
  );
  const androidTorii = requireText(
    resolve(root, 'fearless-Android/common/src/main/java/jp/co/soramitsu/common/data/network/iroha/IrohaToriiClient.kt'),
    'Android Torii client'
  );
  const androidToriiModels = requireText(
    resolve(root, 'fearless-Android/common/src/main/java/jp/co/soramitsu/common/data/network/iroha/IrohaToriiModels.kt'),
    'Android Torii models'
  );
  const androidToriiRoutes = requireText(
    resolve(root, 'fearless-Android/common/src/main/java/jp/co/soramitsu/common/data/network/iroha/IrohaToriiRoutes.kt'),
    'Android Torii routes'
  );
  const androidNetworkModule = requireText(
    resolve(root, 'fearless-Android/common/src/main/java/jp/co/soramitsu/common/di/modules/NetworkModule.kt'),
    'Android network module'
  );
  const androidHistory = requireText(
    resolve(root, 'fearless-Android/feature-wallet-impl/src/main/java/jp/co/soramitsu/wallet/impl/data/historySource/IrohaHistorySource.kt'),
    'Android Iroha history service'
  );
  const androidBalance = requireText(
    resolve(root, 'fearless-Android/feature-wallet-impl/src/main/java/jp/co/soramitsu/wallet/impl/data/network/blockchain/balance/IrohaBalanceLoader.kt'),
    'Android Iroha balance service'
  );
  const androidIdentity = requireText(
    resolve(root, 'fearless-Android/runtime/src/main/java/jp/co/soramitsu/runtime/ext/UniversalWalletIrohaExt.kt'),
    'Android Iroha identity routing'
  );
  const androidBalanceProvider = requireText(
    resolve(root, 'fearless-Android/feature-wallet-impl/src/main/java/jp/co/soramitsu/wallet/impl/data/network/blockchain/balance/BalanceLoaderProvider.kt'),
    'Android balance routing'
  );
  const androidTransfer = requireText(
    resolve(root, 'fearless-Android/feature-wallet-impl/src/main/java/jp/co/soramitsu/wallet/impl/data/repository/tranfser/TransferService.kt'),
    'Android transfer routing'
  );
  const androidMetaAccount = requireText(
    resolve(root, 'fearless-Android/feature-account-api/src/main/java/jp/co/soramitsu/account/api/domain/model/MetaAccount.kt'),
    'Android stored account routing'
  );
  const androidMigration = requireText(
    resolve(root, 'fearless-Android/feature-account-api/src/main/java/jp/co/soramitsu/account/api/domain/model/AndroidUniversalWalletMigrationSnapshotBuilder.kt'),
    'Android migration routing'
  );
  const iosRegistry = requireText(
    resolve(root, 'fearless-iOS/fearless/Common/Model/UniversalWalletRegistry.swift'),
    'iOS universal-wallet registry'
  );
  const iosTorii = requireText(
    resolve(root, 'fearless-iOS/fearless/Common/Model/IrohaToriiClient.swift'),
    'iOS Torii client'
  );
  const iosToriiContract = requireText(
    resolve(root, 'fearless-iOS/fearless/Common/Model/IrohaToriiContract.swift'),
    'iOS Torii contract'
  );
  const iosTransfer = requireText(
    resolve(root, 'fearless-iOS/fearless/ApplicationLayer/Services/Transfer/Tokens/TransferService.swift'),
    'iOS transfer service'
  );
  const iosHistory = requireText(
    resolve(root, 'fearless-iOS/fearless/CoreLayer/OperationFactory/BlockExplorer/History/Main/IrohaHistoryOperationFactory.swift'),
    'iOS Iroha history service'
  );
  const iosBalance = requireText(
    resolve(root, 'fearless-iOS/fearless/ApplicationLayer/Services/Balance/RemoteSubscription/AccountInfoRemoteService.swift'),
    'iOS Iroha balance service'
  );
  const iosAddressResolver = requireText(
    resolve(root, 'fearless-iOS/fearless/Common/Model/UniversalWalletAccountAddressResolver.swift'),
    'iOS stored account routing'
  );
  const iosMetaAccountMapper = requireText(
    resolve(root, 'fearless-iOS/fearless/Common/Storage/EntityToModel/MetaAccountMapper.swift'),
    'iOS stored account quarantine'
  );
  const iosAddressResolverTests = requireText(
    resolve(root, 'fearless-iOS/fearlessTests/UniversalWalletAccountAddressResolverTests.swift'),
    'iOS stored account routing tests'
  );
  const iosMetaAccountMapperTests = requireText(
    resolve(root, 'fearless-iOS/fearlessTests/Common/Storage/MetaAccountMapperTests.swift'),
    'iOS stored account quarantine tests'
  );
  const iosToriiContractTests = requireText(
    resolve(root, 'fearless-iOS/fearlessTests/IrohaToriiContractTests.swift'),
    'iOS Torii contract tests'
  );
  const iosMigration = requireText(
    resolve(root, 'fearless-iOS/fearless/Common/Model/UniversalWalletMigrationContract.swift'),
    'iOS migration routing'
  );
  const iosSendContainer = requireText(
    resolve(root, 'fearless-iOS/fearless/Modules/Send/SendDependencyContainer.swift'),
    'iOS send routing'
  );
  const profile = requireText(
    resolve(parent, 'iroha/crates/iroha_kagami/src/genesis/profile.rs'),
    'Iroha Taira genesis profile'
  );
  const generator = requireText(
    resolve(parent, 'iroha/crates/iroha_kagami/src/genesis/generate.rs'),
    'Iroha genesis generator'
  );
  const explorer = requireText(
    resolve(parent, 'iroha/crates/iroha_torii/src/explorer.rs'),
    'Iroha Torii explorer contract'
  );
  const torii = requireText(
    resolve(parent, 'iroha/crates/iroha_torii/src/lib.rs'),
    'Iroha Torii hosted-service ingress contract'
  );
  const toriiShared = requireText(
    resolve(parent, 'iroha/crates/iroha_torii_shared/src/lib.rs'),
    'Iroha Torii shared hosted-service response contract'
  );
  const tairaCli = requireText(
    resolve(parent, 'iroha/crates/iroha_cli/src/taira.rs'),
    'Iroha Taira doctor contract'
  );
  const soracloudCli = requireText(
    resolve(parent, 'iroha/crates/iroha_cli/src/soracloud.rs'),
    'Iroha SoraCloud authenticated read contract'
  );
  const soracloudCore = requireText(
    resolve(parent, 'iroha/crates/iroha_core/src/smartcontracts/isi/soracloud.rs'),
    'Iroha SoraCloud atomic service mutation contract'
  );
  const soracloudCoreTests = requireText(
    resolve(parent, 'iroha/crates/iroha_core/src/smartcontracts/isi/soracloud_tests.rs'),
    'Iroha SoraCloud rollout and compare-and-set tests'
  );
  const soracloudCoreInitialFixtureTests = requireText(
    resolve(parent, 'iroha/crates/iroha_core/src/smartcontracts/isi/soracloud_initial_fixture_tests.rs'),
    'Iroha SoraCloud initial authority fixture tests'
  );
  const soracloudCoreBlock = requireText(
    resolve(parent, 'iroha/crates/iroha_core/src/block.rs'),
    'Iroha SoraCloud block runtime-receipt ingress contract'
  );
  const soracloudCoreRuntime = requireText(
    resolve(parent, 'iroha/crates/iroha_core/src/soracloud_runtime.rs'),
    'Iroha shared SoraCloud runtime authority contract'
  );
  const irohaCoreState = requireText(
    resolve(parent, 'iroha/crates/iroha_core/src/state.rs'),
    'Iroha exact state-view lane authority contract'
  );
  const soracloudStateRestore = requireText(
    resolve(parent, 'iroha/crates/iroha_core/src/state/deserialize_world.rs'),
    'Iroha SoraCloud fail-closed persisted-state restore contract'
  );
  const soracloudStateTests = requireText(
    resolve(parent, 'iroha/crates/iroha_core/src/state/tests.rs'),
    'Iroha SoraCloud persisted-state restore regression tests'
  );
  const soracloudIrohad = requireText(
    resolve(parent, 'iroha/crates/irohad/src/soracloud_runtime.rs'),
    'Iroha daemon SoraCloud runtime reconciliation contract'
  );
  const soracloudIrohadRuntimeTail = requireText(
    resolve(parent, 'iroha/crates/irohad/src/soracloud_runtime/tests/runtime_tail.rs'),
    'Iroha daemon external Inrou smoke fixture contract'
  );
  const soracloudDataModel = requireText(
    resolve(parent, 'iroha/crates/iroha_data_model/src/soracloud.rs'),
    'Iroha SoraCloud canonical record identity contract'
  );
  const soracloudDataModelDeployment = requireText(
    resolve(parent, 'iroha/crates/iroha_data_model/src/soracloud/deployment.rs'),
    'Iroha SoraCloud mutation precondition data model'
  );
  const soracloudDataModelHosting = requireText(
    resolve(parent, 'iroha/crates/iroha_data_model/src/soracloud/hosting.rs'),
    'Iroha SoraCloud app mutation precondition data model'
  );
  const soracloudDataModelSchema = requireText(
    resolve(parent, 'iroha/crates/iroha_data_model/src/soracloud/schema.rs'),
    'Iroha SoraCloud shared canonical identity validators'
  );
  const soracloudDataModelTests = requireText(
    resolve(parent, 'iroha/crates/iroha_data_model/src/soracloud/tests/manifest_validation.rs'),
    'Iroha SoraCloud deployment validation tests'
  );
  const soracloudDataModelFixtureTests = requireText(
    resolve(parent, 'iroha/crates/iroha_data_model/src/soracloud/tests/fixtures_and_manifests.rs'),
    'Iroha SoraCloud canonical JSON fixture tests'
  );
  const soracloudDataModelRecordTests = requireText(
    resolve(parent, 'iroha/crates/iroha_data_model/src/soracloud/tests/decryption_and_records.rs'),
    'Iroha SoraCloud record validation tests'
  );
  const soracloudDataModelIsi = requireText(
    resolve(parent, 'iroha/crates/iroha_data_model/src/isi/soracloud.rs'),
    'Iroha SoraCloud service instruction data model'
  );
  const toriiOpenApiCanonical = requireText(
    resolve(parent, 'iroha/artifacts/openapi/torii.json'),
    'Iroha canonical Torii OpenAPI artifact'
  );
  const toriiOpenApiCurrent = requireText(
    resolve(parent, 'iroha/artifacts/openapi/versions/current/torii.json'),
    'Iroha current-version Torii OpenAPI artifact'
  );
  const toriiOpenApiPackaged = requireText(
    resolve(parent, 'iroha/crates/iroha_torii/assets/openapi/torii.json'),
    'Iroha packaged Torii OpenAPI artifact'
  );
  const soracloudDataModelHostProtocol = requireText(
    resolve(parent, 'iroha/crates/iroha_data_model/src/soracloud/host_protocol.rs'),
    'Iroha SoraCloud signed bundle payload contract'
  );
  const soracloudTorii = requireText(
    resolve(parent, 'iroha/crates/iroha_torii/src/soracloud.rs'),
    'Iroha SoraCloud mutation ingress contract'
  );
  const soracloudToriiLeaseTests = requireText(
    resolve(parent, 'iroha/crates/iroha_torii/src/soracloud/control_plane_lease_tests.rs'),
    'Iroha SoraCloud control-plane lease projection tests'
  );
  const soracloudToriiOpenApiTests = requireText(
    resolve(parent, 'iroha/crates/iroha_torii/src/openapi/tests/soracloud_lease_contracts.rs'),
    'Iroha SoraCloud OpenAPI first-release contract tests'
  );
  const soracloudToriiHostedTests = requireText(
    resolve(parent, 'iroha/crates/iroha_torii/src/tests/lib_runtime_handlers/part_6.rs'),
    'Iroha Torii hosted rollout fixture contract'
  );
  const soracloudToriiHostedTargetTests = requireText(
    resolve(parent, 'iroha/crates/iroha_torii/src/tests/lib_runtime_handlers/part_7.rs'),
    'Iroha Torii hosted target fail-closed tests'
  );
  const soracloudToriiProxyTests = requireText(
    resolve(parent, 'iroha/crates/iroha_torii/src/tests/lib_runtime_handlers/part_8.rs'),
    'Iroha Torii generated-HF proxy authority tests'
  );
  const soracloudToriiTopologyTests = requireText(
    resolve(parent, 'iroha/crates/iroha_torii/src/tests/lib_runtime_handlers/part_9.rs'),
    'Iroha Torii SoraCloud topology lifecycle tests'
  );
  validateRuntimeExecutionHostOpenApiArtifacts({
    canonical: toriiOpenApiCanonical,
    current: toriiOpenApiCurrent,
    packaged: toriiOpenApiPackaged,
  });
  requireScopedLiterals(
    soracloudToriiOpenApiTests,
    'fn soracloud_runtime_execution_host_openapi_is_first_release_exact()',
    '\n        "retired Inrou runtime-host schema must not remain public"',
    [
      'SoraRuntimeDeterministicValidatorHostV1',
      'DeterministicValidator',
      'SoraRuntimeHfModelHostV1',
      '!schemas.contains_key("SoraRuntimeInrouReplicaHostV1")',
    ],
    'Iroha OpenAPI exact runtime execution-host regression'
  );
  const configPath = resolve(parent, 'iroha/configs/soranexus/taira/config.toml');
  const genesisPath = resolve(parent, 'iroha/configs/soranexus/taira/genesis.json');
  const config = requireText(
    configPath,
    'Taira node configuration'
  );
  const genesisText = requireText(genesisPath, 'Taira genesis');
  let genesis;
  try {
    genesis = JSON.parse(genesisText);
  } catch {
    fail(`Taira genesis must be valid JSON at ${genesisPath}`);
  }
  const nevoFixtureRoot = resolve(parent, 'iroha/crates/iroha_kagami/tests/fixtures/taira_nevo_v2');
  const nevoReviewPath = resolve(nevoFixtureRoot, 'review.json');
  const nevoUnsignedGenesisPath = resolve(nevoFixtureRoot, 'unsigned-genesis.json');
  const nevoReview = requireJson(nevoReviewPath, 'Taira NEVO review');
  const nevoPublicInputs = requireJson(
    resolve(nevoFixtureRoot, 'public-inputs.json'),
    'Taira NEVO public inputs'
  );
  const nevoUnsignedGenesis = requireText(
    nevoUnsignedGenesisPath,
    'Taira NEVO unsigned genesis'
  );
  const dnsManifest = requireJson(
    resolve(parent, 'iroha/configs/soranexus/taira/dns_records.json'),
    'Taira DNS manifest'
  );
  const operatorSkill = requireText(
    resolve(parent, 'iroha/skills/sora-taira-testnet/SKILL.md'),
    'Taira operator skill'
  );

  const soracloudDoctorScope = requireScopedLiterals(
    tairaCli,
    '"soracloud_status",',
    '\n    ),',
    ['/v1/soracloud/status', '&[401]'],
    'Iroha public doctor protected SoraCloud route'
  );
  if (soracloudDoctorScope.includes('&[200]')) {
    fail('Iroha public doctor must not require an unauthenticated 200 from protected SoraCloud status');
  }
  const sumeragiDoctorScope = requireScopedLiterals(
    tairaCli,
    '"sumeragi_status",',
    '\n    ),',
    ['/v1/sumeragi/status', '&[401]'],
    'Iroha public doctor protected Sumeragi route'
  );
  if (sumeragiDoctorScope.includes('&[200]')) {
    fail('Iroha public doctor must not require an unauthenticated 200 from protected Sumeragi status');
  }
  requireScopedLiterals(
    tairaCli,
    'fn run_doctor(',
    '\nfn validate_exact_inrou_canary_status(',
    [
      '"musubi_ordered_prefix" | "soracloud_status"',
      'validate_canonical_authentication_challenge(result.body.as_ref())',
    ],
    'Iroha public doctor canonical authentication proof'
  );
  requireScopedLiterals(
    tairaCli,
    'fn run_doctor(',
    '\nfn validate_exact_inrou_canary_status(',
    [
      '"sumeragi_status"',
      'validate_operator_signature_authentication_challenge(result.body.as_ref())',
    ],
    'Iroha public doctor Sumeragi operator authentication proof'
  );
  requireScopedLiterals(
    tairaCli,
    'fn validate_canonical_authentication_challenge(',
    '\nfn validate_operator_signature_authentication_challenge(',
    [
      'body.len() != 2',
      'body.get("code").and_then(Value::as_str) != Some("canonical_authentication_required")',
      'body.get("message").and_then(Value::as_str)',
      '!= Some("canonical account request authentication is required")',
    ],
    'Iroha canonical authentication challenge validator'
  );
  requireScopedLiterals(
    tairaCli,
    'fn validate_operator_signature_authentication_challenge(',
    "\nfn tagged_enum_name<'a>(value: &'a Value, field: &str)",
    [
      'body.len() != 2',
      'body.get("code").and_then(Value::as_str) != Some("operator_signature_missing")',
      'body.get("message").and_then(Value::as_str)',
      '"missing required operator signature header `x-iroha-operator-public-key`"',
    ],
    'Iroha Sumeragi operator challenge validator'
  );
  validateCanonicalTaggedTairaStatusDecoder(tairaCli);
  const inrouVerifierScope = requireScopedLiterals(
    tairaCli,
    'fn verify_inrou_canary(',
    '\nfn run_write_canary(',
    ['account_signed_soracloud_status(status_client)'],
    'Iroha signed Inrou canary topology verifier'
  );
  if (inrouVerifierScope.includes('http_json(')) {
    fail('Iroha signed Inrou canary must not poll protected SoraCloud status through unsigned HTTP');
  }
  const inrouStatusHelperScope = requireScopedLiterals(
    tairaCli,
    'fn account_signed_soracloud_status(',
    '\nfn decode_http_json_response(',
    [
      '.get_soracloud_status_response()',
      'canonical account-signed Soracloud status request failed',
      'String::from_utf8(response.body().to_vec())',
    ],
    'Iroha signed Inrou protected-status helper'
  );
  for (const unsignedClientMarker of ['BlockingHttpClient::', 'reqwest::blocking', '.send()']) {
    if (inrouStatusHelperScope.includes(unsignedClientMarker)) {
      fail(`Iroha signed Inrou protected-status helper must not contain ${unsignedClientMarker}`);
    }
  }
  requireScopedLiterals(
    soracloudCli,
    'fn taira_inrou_status_requires_and_uses_protected_read_signer()',
    '\n    #[test]\n    fn fetch_torii_agent_autonomy_status_rejects_invalid_url',
    [
      'requests[0]',
      '.headers',
      'HEADER_IROHA_ACCOUNT',
      'HEADER_IROHA_SIGNATURE',
      'HEADER_IROHA_TIMESTAMP_MS',
      'HEADER_IROHA_NONCE',
    ],
    'Iroha signed Inrou canonical-header test'
  );

  const inrouRevisionDerivationScope = requireScopedLiterals(
    soracloudCli,
    'fn derive_taira_inrou_canary_service_version(',
    '\nfn install_taira_inrou_canary_service_version(',
    [
      'revision_seed.service.service_version.clear();',
      'Hash::new(',
      'json::to_vec(&revision_seed)',
      'TAIRA_INROU_CANARY_SERVICE_VERSION_PREFIX_V1',
      'hex::encode(revision_digest.as_ref())',
    ],
    'Iroha immutable Inrou revision derivation'
  );
  if (inrouRevisionDerivationScope.includes('"1.0.0"')) {
    fail('Iroha immutable Inrou revision derivation must not retain the fixed first-revision version');
  }
  requireScopedLiterals(
    soracloudCli,
    'fn validate_taira_inrou_canary_bundle(',
    '\n#[cfg(unix)]',
    [
      'let expected_service_version = derive_taira_inrou_canary_service_version(bundle)?;',
      'if bundle.service.service_version != expected_service_version',
    ],
    'Iroha immutable Inrou revision validator'
  );
  requireScopedLiterals(
    soracloudCli,
    'pub(crate) struct TairaInrouCanaryDeployment {',
    '\nfn preflight_taira_inrou_mutation_target(',
    [
      'pub service_version: String,',
      'pub service_manifest_hash: String,',
      'pub container_manifest_hash: String,',
      'pub bundle_hash: String,',
    ],
    'Iroha Inrou deployment artifact identity'
  );
  requireScopedLiterals(
    soracloudCli,
    'fn derive_service_mutation_precondition(',
    '\nfn preflight_taira_inrou_mutation_target(',
    [
      '(MutationMode::Deploy, None) => Ok(SoraServiceMutationPreconditionV1::ServiceAbsent)',
      '(MutationMode::Deploy, Some(_))',
      '(MutationMode::Upgrade, None)',
      '(MutationMode::Upgrade, Some(service))',
      'if matching.next().is_some()',
      '.get("current_version")',
      'if current_version == service_version',
      '.get("latest_revision")',
      '.get("service_version")',
      'if revision_version != current_version',
      '.get("service_manifest_hash")',
      '.parse::<Hash>()',
      '.get("container_manifest_hash")',
      '.get("process_generation")',
      '.filter(|generation| *generation > 0)',
      '.get("config_generation")',
      '.get("secret_generation")',
      '.get("active_rollout")',
      'refuses to supersede the active rollout',
      'SoraServiceMutationPreconditionV1::ExactCurrentRevision(',
      'SoraServiceExactCurrentRevisionPreconditionV1 {',
      'service_version: current_version.to_owned()',
      'service_manifest_hash,',
      'container_manifest_hash,',
      'process_generation,',
      'config_generation,',
      'secret_generation,',
      'before artifact publication',
    ],
    'Iroha signed service mutation precondition derivation'
  );
  requireScopedLiterals(
    soracloudCli,
    'fn preflight_taira_inrou_mutation_target(',
    '\nfn status_tagged_enum_name',
    [
      ') -> Result<SoraServiceMutationPreconditionV1>',
      'derive_service_mutation_precondition(',
      '"Taira Inrou"',
    ],
    'Iroha Inrou mutation target preflight'
  );
  const taggedServiceIdentityScope = requireScopedLiterals(
    soracloudCli,
    'fn status_tagged_enum_name',
    '\nfn preflight_service_upgrade_identity(',
    [
      'value.as_object()?.get(field)?.as_str()',
    ],
    'Iroha canonical tagged service identity decoder'
  );
  if (taggedServiceIdentityScope.includes('value.as_str()')) {
    fail('Iroha first-release service status identity must reject legacy untagged enum strings');
  }
  requireScopedLiterals(
    soracloudCli,
    'fn preflight_service_upgrade_identity(',
    '\npub(crate) fn run_taira_inrou_canary_deployment(',
    [
      'if mode == MutationMode::Deploy',
      'status_tagged_enum_name(value, "execution_plane")',
      'status_tagged_enum_name(value, "runtime")',
      '.get("route_host")',
      '.get("route_path_prefix")',
      '.get("route_service_port")',
      '.get("route_visibility")',
      '.get("route_tls_mode")',
      'u64::from(route.service_port.get())',
      'cannot change route identity',
      'before artifact publication',
    ],
    'Iroha pre-publication service upgrade identity check'
  );
  requireScopedLiterals(
    soracloudCli,
    'fn taira_inrou_mutation_preflight_is_exact_and_runs_before_publication()',
    '\n    #[test]\n    fn taira_inrou_canary_validator_accepts_published_v1_bundle()',
    [
      '"execution_plane": {"execution_plane": "HttpService"}',
      '"runtime": {"runtime": "Inrou"}',
      '"route_service_port": TAIRA_INROU_CANARY_SERVICE_PORT_V1',
      '"route_visibility": "Public"',
      '"route_tls_mode": "Required"',
      'preflight_service_upgrade_identity(',
      'route drift must fail before artifact publication',
      'upgrade must not publish while another rollout is active',
    ],
    'Iroha canonical service identity and active-rollout preflight test'
  );
  const inrouDeploymentScope = requireScopedLiterals(
    soracloudCli,
    'pub(crate) fn run_taira_inrou_canary_deployment(',
    '\n#[derive(clap::ValueEnum',
    [
      'fetch_torii_soracloud_status(',
      'preflight_taira_inrou_mutation_target(',
      'preflight_service_upgrade_identity(',
      'register_built_sorafs_manifest(',
      'run_service_bundle_mutation(',
      'precondition,',
      'service_manifest_hash: staged.receipt.service_manifest_hash,',
      'container_manifest_hash: staged.receipt.container_manifest_hash,',
    ],
    'Iroha Inrou pre-publication mutation flow'
  );
  requireOrdered(
    inrouDeploymentScope,
    'let precondition = preflight_taira_inrou_mutation_target(',
    'run_service_bundle_mutation(',
    'Iroha Inrou signed atomic mutation precondition forwarding'
  );
  requireOrdered(
    inrouDeploymentScope,
    'preflight_service_upgrade_identity(',
    'register_built_sorafs_manifest(',
    'Iroha Inrou pre-publication route identity check'
  );

  requireScopedLiterals(
    soracloudDataModelDeployment,
    'pub struct SoraServiceExactCurrentRevisionPreconditionV1 {',
    '\n}\n/// Signed compare-and-set condition for a service deploy or upgrade.',
    [
      'pub service_version: String,',
      'pub service_manifest_hash: Hash,',
      'pub container_manifest_hash: Hash,',
      'pub process_generation: u64,',
      'pub config_generation: u64,',
      'pub secret_generation: u64,',
    ],
    'Iroha exact current service revision precondition'
  );
  requireScopedLiterals(
    soracloudDataModelDeployment,
    'pub enum SoraServiceMutationPreconditionV1 {',
    '\n}\n/// Mutation mode recorded for authoritative Soracloud state updates.',
    [
      'ServiceAbsent,',
      'ExactCurrentRevision(SoraServiceExactCurrentRevisionPreconditionV1),',
    ],
    'Iroha service mutation compare-and-set data model'
  );
  requireScopedLiterals(
    soracloudDataModelHosting,
    'pub struct SoraAppInfraExactCurrentRevisionPreconditionV1 {',
    '\n}\n/// Signed compare-and-set condition for an app topology deploy or upgrade.',
    [
      'pub app_version: String,',
      'pub manifest_hash: Hash,',
      'pub revision_count: u32,',
    ],
    'Iroha exact current app topology precondition'
  );
  requireScopedLiterals(
    soracloudDataModelHosting,
    'pub enum SoraAppInfraMutationPreconditionV1 {',
    '\n}\n/// Authoritative app-level Soracloud infrastructure state.',
    [
      'AppAbsent,',
      'ExactCurrentRevision(SoraAppInfraExactCurrentRevisionPreconditionV1),',
    ],
    'Iroha app topology compare-and-set data model'
  );
  const rolloutStateScope = requireScopedLiterals(
    soracloudDataModelDeployment,
    'pub struct SoraServiceRolloutStateV1 {',
    '\n}\nimpl SoraServiceRolloutStateV1 {',
    [
      'pub baseline_version: String,',
      'pub candidate_version: String,',
      'pub canary_percent: u8,',
      'pub traffic_percent: u8,',
    ],
    'Iroha canonical rollout state schema'
  );
  if (rolloutStateScope.includes('baseline_version: Option<String>')) {
    fail('Iroha first-release rollout baseline must be mandatory');
  }
  requireScopedLiterals(
    soracloudDataModelDeployment,
    'impl SoraServiceRolloutStateV1 {',
    '\n}\n/// Authoritative deployment state for the currently active Soracloud service.',
    [
      'validate_nonblank_field(',
      '"baseline_version"',
      'if self.baseline_version == self.candidate_version',
      'if !(1..100).contains(&self.canary_percent)',
      'if !(self.canary_percent..100).contains(&self.traffic_percent)',
    ],
    'Iroha canonical rollout state validation'
  );
  requireScopedLiterals(
    soracloudDataModelDeployment,
    'impl SoraServiceDeploymentStateV1 {',
    '\n}\nfn validate_service_material_name(',
    [
      'if let Some(active_rollout) = self.active_rollout.as_ref()',
      'active_rollout.stage != SoraRolloutStageV1::Canary',
      'active_rollout.candidate_version != self.current_service_version',
      'active_rollout.traffic_percent',
      'active_rollout.canary_percent',
    ],
    'Iroha active rollout deployment invariants'
  );
  requireScopedLiterals(
    soracloudDataModelTests,
    'fn service_rollout_state_validate_rejects_missing_or_reused_baseline()',
    '\n#[test]\nfn service_deployment_state_validate_rejects_active_candidate_different_from_current()',
    [
      'for baseline_version in ["", "1.1.0"]',
      'baseline must be present and distinct from the candidate',
      'assert_soracloud_invalid_field(error, "baseline_version")',
    ],
    'Iroha rollout baseline validation test'
  );
  requireScopedLiterals(
    soracloudDataModelTests,
    'fn service_deployment_state_validate_rejects_active_candidate_different_from_current()',
    '\n#[test]\nfn service_deployment_state_validate_rejects_zero_or_full_canary_allocations()',
    [
      'candidate_version = "1.2.0".to_owned()',
      'assert_soracloud_invalid_field(error, "active_rollout.candidate_version")',
    ],
    'Iroha active rollout candidate validation test'
  );
  requireScopedLiterals(
    soracloudDataModelTests,
    'fn service_deployment_state_validate_rejects_zero_or_full_canary_allocations()',
    '\n#[test]\nfn service_deployment_state_validate_requires_exact_active_canary_relation()',
    [
      'for canary_percent in [0, 100]',
      'for traffic_percent in [0, 100]',
      'assert_soracloud_invalid_field(error, "canary_percent")',
      'assert_soracloud_invalid_field(error, "traffic_percent")',
    ],
    'Iroha active rollout partial-traffic validation test'
  );
  for (const [instruction, nextInstruction, expectedComment] of [
    [
      'pub struct DeploySoracloudService {',
      '\npub struct UpgradeSoracloudService {',
      'Signed atomic condition requiring this service to remain absent until execution.',
    ],
    [
      'pub struct UpgradeSoracloudService {',
      '\npub struct RollbackSoracloudService {',
      'Signed atomic condition binding the exact active revision observed by the caller.',
    ],
  ]) {
    const instructionScope = requireScopedLiterals(
      soracloudDataModelIsi,
      instruction,
      nextInstruction,
      [
        `/// ${expectedComment}`,
        'pub precondition: SoraServiceMutationPreconditionV1,',
      ],
      'Iroha service instruction atomic precondition'
    );
    if (/#\[norito\(default\)\]\s*pub precondition:/u.test(instructionScope)) {
      fail('Iroha service mutation precondition must be mandatory in the first-release wire contract');
    }
  }
  for (const [instruction, nextInstruction, expectedComment] of [
    [
      'pub struct DeploySoracloudAppInfra {',
      '\nimpl crate::seal::Instruction for DeploySoracloudAppInfra',
      'Signed atomic condition requiring this app topology to remain absent until execution.',
    ],
    [
      'pub struct UpgradeSoracloudAppInfra {',
      '\nimpl crate::seal::Instruction for UpgradeSoracloudAppInfra',
      'Signed atomic condition binding the exact active topology observed by the caller.',
    ],
  ]) {
    const instructionScope = requireScopedLiterals(
      soracloudDataModelIsi,
      instruction,
      nextInstruction,
      [
        `/// ${expectedComment}`,
        'pub precondition: SoraAppInfraMutationPreconditionV1,',
      ],
      'Iroha app topology instruction atomic precondition'
    );
    if (/#\[norito\(default\)\]\s*pub precondition:/u.test(instructionScope)) {
      fail('Iroha app topology mutation precondition must be mandatory in the first-release wire contract');
    }
  }
  const signedAppPayloadScope = requireScopedLiterals(
    soracloudDataModelHostProtocol,
    'pub fn encode_app_infra_provenance_payload(',
    '\n}\n/// Encode the canonical provenance signature payload for deployment bundles,',
    [
      'precondition: &SoraAppInfraMutationPreconditionV1,',
      'norito::encode_canonical(&(manifest.clone(), precondition.clone()))',
    ],
    'Iroha signed app topology precondition payload binding'
  );
  requireOrdered(
    signedAppPayloadScope,
    'manifest.clone()',
    'precondition.clone()',
    'Iroha signed app topology precondition payload binding'
  );
  const signedBundlePayloadScope = requireScopedLiterals(
    soracloudDataModelHostProtocol,
    'pub fn encode_bundle_with_materials_provenance_payload(',
    '\n}\n/// Encode the canonical provenance signature payload for service rollback.',
    [
      'precondition: &SoraServiceMutationPreconditionV1,',
      'norito::encode_canonical(&(',
      'bundle.clone(),',
      'initial_service_configs.clone(),',
      'initial_service_secrets.clone(),',
      'precondition.clone(),',
    ],
    'Iroha signed bundle precondition payload binding'
  );
  requireOrdered(
    signedBundlePayloadScope,
    'initial_service_secrets.clone(),',
    'precondition.clone(),',
    'Iroha signed bundle precondition payload binding'
  );
  requireScopedLiterals(
    soracloudCli,
    'struct SignedBundleRequest {',
    '\n}\n#[derive(Clone, Debug, JsonSerialize, JsonDeserialize)]\n#[norito(deny_unknown_fields)]\nstruct SignedAppInfraRequest',
    ['precondition: SoraServiceMutationPreconditionV1,'],
    'Iroha CLI signed service mutation request'
  );
  requireScopedLiterals(
    soracloudCli,
    'struct SignedAppInfraRequest {',
    '\n}\n#[derive(',
    ['precondition: SoraAppInfraMutationPreconditionV1,'],
    'Iroha CLI signed app topology mutation request'
  );
  requireScopedLiterals(
    soracloudCli,
    'fn derive_app_infra_mutation_precondition(',
    '\nfn preflight_taira_inrou_mutation_target(',
    [
      '(MutationMode::Deploy, None) => Ok(SoraAppInfraMutationPreconditionV1::AppAbsent)',
      '(MutationMode::Deploy, Some(_))',
      '(MutationMode::Upgrade, None)',
      '(MutationMode::Upgrade, Some(app))',
      'if matching.next().is_some()',
      '.get("current_app_version")',
      'if current_app_version == app_version',
      '.get("current_manifest_hash")',
      '.parse::<Hash>()',
      '.get("revision_count")',
      '.filter(|count| *count > 0)',
      'SoraAppInfraMutationPreconditionV1::ExactCurrentRevision(',
      'SoraAppInfraExactCurrentRevisionPreconditionV1 {',
      'app_version: current_app_version.to_owned()',
      'manifest_hash,',
      'revision_count,',
      'before artifact publication',
    ],
    'Iroha signed app topology mutation precondition derivation'
  );
  requireScopedLiterals(
    soracloudCli,
    'fn run_service_bundle_mutation(',
    '\nfn run_signed_service_bundle_mutation(',
    [
      'precondition: SoraServiceMutationPreconditionV1,',
      'signed_bundle_request(',
      'precondition,',
    ],
    'Iroha CLI service mutation precondition forwarding'
  );
  requireScopedLiterals(
    soracloudCli,
    'fn signed_bundle_request(',
    '\nfn signed_app_infra_request(',
    [
      'precondition: SoraServiceMutationPreconditionV1,',
      'encode_bundle_with_materials_provenance_payload(',
      '&precondition,',
      'precondition,',
    ],
    'Iroha CLI signed mutation precondition binding'
  );
  requireScopedLiterals(
    soracloudCli,
    'fn signed_app_infra_request(',
    '\nfn build_app_infra_manifest(',
    [
      'precondition: SoraAppInfraMutationPreconditionV1,',
      'encode_app_infra_provenance_payload(&manifest, &precondition)',
      'precondition,',
    ],
    'Iroha CLI signed app topology mutation precondition binding'
  );

  const appMutationScope = requireScopedLiterals(
    soracloudCli,
    'impl AppDeployArgs {',
    '\ndefine_torii_args! {',
    [
      'fetch_torii_soracloud_app_infra_status(',
      'derive_app_infra_mutation_precondition(',
      'let app_precondition =',
      'fetch_torii_soracloud_status(',
      'let planned_service_mutations =',
      'derive_service_mutation_precondition(',
      'preflight_service_upgrade_identity(',
      'publish_app_static_site(',
      'publish_service_artifacts(',
      'signed_bundle_request(',
      'signed_app_infra_request(',
      'app_precondition,',
      'precondition,',
    ],
    'Iroha app mutation pre-publication compare-and-set flow'
  );
  requireOrdered(
    appMutationScope,
    'derive_app_infra_mutation_precondition(',
    'publish_app_static_site(',
    'Iroha app topology preflight before publication'
  );
  requireOrdered(
    appMutationScope,
    'derive_service_mutation_precondition(',
    'publish_app_static_site(',
    'Iroha app mutation preflight before publication'
  );
  requireOrdered(
    appMutationScope,
    'preflight_service_upgrade_identity(',
    'publish_service_artifacts(',
    'Iroha app mutation route identity before service publication'
  );
  const directMutationScope = requireScopedLiterals(
    soracloudCli,
    'macro_rules! impl_service_bundle_mutation {',
    '\nimpl_service_bundle_mutation!(DeployArgs);',
    [
      'fetch_torii_soracloud_status(',
      'derive_service_mutation_precondition(',
      'preflight_service_upgrade_identity(',
      'publish_service_artifacts(',
      'run_service_bundle_mutation(',
      'precondition,',
    ],
    'Iroha direct service mutation pre-publication compare-and-set flow'
  );
  requireOrdered(
    directMutationScope,
    'derive_service_mutation_precondition(',
    'publish_service_artifacts(',
    'Iroha direct service mutation preflight before publication'
  );
  requireOrdered(
    directMutationScope,
    'preflight_service_upgrade_identity(',
    'publish_service_artifacts(',
    'Iroha direct service route identity before publication'
  );
  requireScopedLiterals(
    soracloudCli,
    'fn app_infra_mutation_preflight_is_exact_and_rejects_duplicate_snapshots()',
    '\n    #[test]\n    fn service_upgrade_preflight_accepts_an_exact_absent_route_identity()',
    [
      'SoraAppInfraMutationPreconditionV1::AppAbsent',
      'SoraAppInfraMutationPreconditionV1::ExactCurrentRevision(',
      'current_manifest_hash,',
      'revision_count: 3',
      'already-current app version must fail before publication',
      'duplicate authoritative app snapshots must fail closed',
    ],
    'Iroha app topology mutation preflight adversarial test'
  );
  requireScopedLiterals(
    soracloudCli,
    'fn signed_app_infra_request_binds_the_exact_mutation_precondition()',
    '\n    #[test]\n    fn signed_inrou_bundle_request_uses_canonical_guest_images_signature()',
    [
      'encode_app_infra_provenance_payload(&request.manifest, &request.precondition)',
      'encode_app_infra_provenance_payload(&request.manifest, &tampered_precondition)',
      'changing the signed app-infra precondition must invalidate the signature',
    ],
    'Iroha CLI signed app topology precondition signature test'
  );

  const corePreconditionScope = requireScopedLiterals(
    soracloudCore,
    'fn enforce_service_mutation_precondition(',
    '\nfn admit_bundle(',
    [
      'SoraServiceLifecycleActionV1::Deploy,',
      'SoraServiceMutationPreconditionV1::ServiceAbsent,',
      'SoraServiceLifecycleActionV1::Upgrade,',
      'SoraServiceMutationPreconditionV1::ExactCurrentRevision(',
      'service_version.trim().is_empty() || *process_generation == 0',
      'current.current_service_version.as_str() == service_version.as_str()',
      '&current.current_service_manifest_hash == service_manifest_hash',
      '&current.current_container_manifest_hash == container_manifest_hash',
      'current.process_generation == *process_generation',
      'current.config_generation == *config_generation',
      'current.secret_generation == *secret_generation',
      'authoritative active revision changed after preflight',
    ],
    'Iroha ledger atomic service mutation precondition enforcement'
  );
  requireScopedLiterals(
    soracloudCore,
    'pub(crate) fn next_soracloud_audit_sequence(',
    '\nfn parse_training_model_name(',
    [
      '-> Result<u64, InstructionExecutionError>',
      'crate::soracloud_runtime::latest_soracloud_sequence(&state_transaction.world)',
      '.checked_add(1)',
      'Soracloud audit sequence is exhausted',
    ],
    'Iroha checked shared Soracloud audit sequence'
  );
  requireScopedLiterals(
    soracloudCoreRuntime,
    'pub fn latest_soracloud_sequence(',
    '\npub fn soracloud_validator_is_active(',
    [
      'soracloud_service_audit_events()',
      'soracloud_app_infra_audit_events()',
      'soracloud_training_job_audit_events()',
      'soracloud_model_weight_audit_events()',
      'soracloud_model_artifact_audit_events()',
      'soracloud_hf_shared_lease_audit_events()',
      'soracloud_model_host_violation_evidence()',
      'soracloud_agent_apartment_audit_events()',
      'soracloud_private_uploaded_model_execution_receipts()',
      'soracloud_mailbox_messages()',
      'soracloud_runtime_receipts()',
      'pub fn authoritative_soracloud_sequence(',
      'latest_soracloud_sequence(world).saturating_add(1)',
    ],
    'Iroha canonical eleven-store Soracloud sequence domain'
  );
  requireScopedLiterals(
    soracloudCore,
    'fn ensure_soracloud_sequence_is_next(',
    '\nfn ensure_soracloud_audit_sequence_capacity(',
    [
      'let expected = next_soracloud_audit_sequence(state_transaction)?;',
      'if sequence != expected',
      'is stale or non-canonical; next authoritative sequence is',
    ],
    'Iroha global Soracloud sequence collision guard'
  );
  requireAtLeast(
    soracloudCore,
    'ensure_soracloud_sequence_is_next(',
    12,
    'Iroha global Soracloud sequence collision guard coverage'
  );
  requireScopedLiterals(
    soracloudStateRestore,
    "struct SoracloudInrouPersistedStateV1<'a> {",
    "\n}\n\nimpl SoracloudInrouPersistedStateV1<'_> {",
    [
      'decryption_request_records:',
      'agent_apartments:',
      'training_jobs:',
      'model_registries:',
      'model_weight_versions:',
      'model_artifacts:',
      'model_host_capabilities:',
      'hf_sources:',
      'hf_shared_lease_pools:',
      'hf_shared_lease_members:',
      'hf_placements:',
      'uploaded_model_bundles:',
      'mailbox_messages:',
      'runtime_receipts:',
      'private_uploaded_model_execution_receipts:',
    ],
    'Iroha persisted-state contextual Soracloud store boundary'
  );
  for (const requiredProjectionStore of [
    'soracloud_decryption_request_records',
    'soracloud_agent_apartments',
    'soracloud_training_jobs',
    'soracloud_model_registries',
    'soracloud_model_weight_versions',
    'soracloud_model_artifacts',
    'soracloud_model_host_capabilities',
    'soracloud_hf_sources',
    'soracloud_hf_shared_lease_pools',
    'soracloud_hf_shared_lease_members',
    'soracloud_hf_placements',
  ]) {
    requirePattern(
      soracloudStateRestore,
      new RegExp(
        `take_required\\(\\s*&mut map,\\s*"${requiredProjectionStore}"\\s*\\)\\?`,
        'u'
      ),
      `Iroha first-release required restore boundary for ${requiredProjectionStore}`
    );
  }
  requireScopedLiterals(
    soracloudCoreRuntime,
    'pub fn validate_soracloud_service_revision_identity(',
    '\n/// Resolve one authoritative Inrou placement record',
    [
      'candidate.service.state_bindings != current.service.state_bindings',
      'service revision cannot change durable state-binding contracts',
    ],
    'Iroha immutable durable state-binding revision contract'
  );
  requireScopedLiterals(
    soracloudStateRestore,
    'let mut service_binding_total_bytes =',
    '\n        let decryption_request_records =',
    [
      'references missing service revision',
      'references undeclared binding',
      'entry.encryption != binding.encryption',
      'entry.payload_bytes > binding.max_item_bytes',
      'service_audit_events',
      'must exactly match its producing service audit event',
      'aggregate payload size exceeds its admitted maximum',
    ],
    'Iroha service-state restore revision, binding, audit, and quota closure'
  );
  requireScopedLiterals(
    soracloudStateRestore,
    'let training_jobs = self.training_jobs.view();',
    '\n        let agent_apartments = self.agent_apartments.view();',
    [
      'training job is missing its exact updated_sequence audit event',
      'model registry references a missing retained service revision',
      'model weight must reference a retained service revision and registry',
      'model artifact must reference a retained revision and carry paired weight consumption metadata',
    ],
    'Iroha training and model restore lineage closure'
  );
  requireScopedLiterals(
    soracloudStateRestore,
    'let agent_apartment_audit_events = self.agent_apartment_audit_events.view();',
    '\n        let hf_sources = self.hf_sources.view();',
    [
      'audit status must equal the sequence-local lease projection',
      'wallet_daily_spend must equal the complete approved-event projection',
      'wallet_daily_spend entry does not equal its approved-event aggregate',
      'autonomy run is missing its exact approval audit event',
      'artifact allowlist rule must exactly match its audit event',
      'revoked apartment capability is missing its authoritative audit event',
    ],
    'Iroha apartment restore status, wallet, and reverse-audit closure'
  );
  requireScopedLiterals(
    soracloudStateRestore,
    'let hf_sources = self.hf_sources.view();',
    '\n        let inrou_host_capabilities = self.inrou_host_capabilities.view();',
    [
      'HF shared-lease audit account has no retained member in the exact pool',
      'HF placement must exactly bind its pool/source profile and eligible count',
      'warming/warm HF assignment must exactly match a capable retained host advert',
      'canonical HF source has no retained shared-lease pool',
    ],
    'Iroha HF restore pool, member, placement, and capability closure'
  );
  requireScopedLiterals(
    soracloudStateRestore,
    'let inrou_host_capabilities = self.inrou_host_capabilities.view();',
    '\n        let mailbox_messages = self.mailbox_messages.view();',
    [
      'Inrou assignment is missing its authoritative host capability',
      'supported_guest_isas',
      "Inrou assignment's per-replica resources exceed its retained host capability",
      'aggregate Inrou reservations exceed the retained host capability',
    ],
    'Iroha restored Inrou capability and aggregate reservation closure'
  );
  requireScopedLiterals(
    soracloudStateRestore,
    'fn register_soracloud_sequence(',
    '\nfn invalid_soracloud_state(',
    [
      'authoritative_sequences.insert(sequence)',
      'authoritative sequence `{sequence}` collides with another Soracloud record',
    ],
    'Iroha persisted-state global Soracloud sequence collision guard'
  );
  for (const sequenceStore of [
    'soracloud_app_infra_audit_events',
    'soracloud_service_audit_events',
    'soracloud_training_job_audit_events',
    'soracloud_model_weight_audit_events',
    'soracloud_model_artifact_audit_events',
    'soracloud_hf_shared_lease_audit_events',
    'soracloud_model_host_violation_evidence',
    'soracloud_agent_apartment_audit_events',
    'soracloud_mailbox_messages',
    'soracloud_runtime_receipts',
    'soracloud_private_uploaded_model_execution_receipts',
  ]) {
    requirePattern(
      soracloudStateRestore,
      new RegExp(
        `register_soracloud_sequence\\(\\s*&mut authoritative_sequences,\\s*"${sequenceStore}",`,
        'u'
      ),
      `Iroha persisted-state global sequence registration for ${sequenceStore}`
    );
  }
  requireScopedLiterals(
    soracloudStateRestore,
    'for (key, record) in self.model_host_violation_evidence.view().iter() {',
    '\n        let agent_apartment_audit_events = self.agent_apartment_audit_events.view();',
    [
      'record.validate()',
      'key != &record.evidence_id',
      'storage key must match the embedded evidence_id',
      'register_soracloud_sequence(',
    ],
    'Iroha restored model-host evidence key and global-sequence binding'
  );
  requireScopedLiterals(
    soracloudStateRestore,
    'let soracloud_uploaded_model_bundles =',
    '\n    .validate()?;',
    [
      'let soracloud_private_uploaded_model_execution_receipts =',
      'take_required(\n        &mut map,\n        "soracloud_private_uploaded_model_execution_receipts",\n    )?;',
      'uploaded_model_bundles: &soracloud_uploaded_model_bundles,',
      'mailbox_messages: &soracloud_mailbox_messages,',
      'runtime_receipts: &soracloud_runtime_receipts,',
      'private_uploaded_model_execution_receipts:',
      '&soracloud_private_uploaded_model_execution_receipts,',
    ],
    'Iroha first-release required private-receipt restore boundary'
  );
  requireScopedLiterals(
    soracloudCoreRuntime,
    'fn latest_and_authoritative_sequences_track_cross_domain_events_and_saturate()',
    '\n    fn sample_private_model_artifact_ref(',
    [
      'soracloud_private_uploaded_model_execution_receipts_mut_for_testing()',
      'emitted_sequence: 34,',
      'assert_eq!(latest_soracloud_sequence(&world.view()), 34);',
      'soracloud_mailbox_messages_mut_for_testing()',
      'enqueue_sequence: 35,',
      'assert_eq!(authoritative_soracloud_sequence(&world.view()), 36);',
    ],
    'Iroha eleven-store Soracloud sequence allocator regression'
  );
  requireScopedLiterals(
    soracloudCore,
    'fn ensure_soracloud_audit_sequence_capacity(',
    '\nfn parse_training_model_name(',
    [
      'next_soracloud_audit_sequence(state_transaction)?',
      'checked_add(additional_offset)',
      'Soracloud audit sequence is exhausted',
    ],
    'Iroha Soracloud batched audit capacity preflight'
  );
  requireScopedLiterals(
    soracloudCore,
    'pub(crate) fn validate_hf_placement_economics_and_status(',
    '\nfn record_hf_placement(',
    [
      'record.assigned_hosts.len() > usize::from(record.adaptive_target_host_count)',
      'recompute_hf_placement_total_reservation_fee(&mut expected_fee_record)?;',
      'record.total_reservation_fee != expected_fee_record.total_reservation_fee',
      'record.status == SoraHfPlacementStatusV1::Retired',
      'assignment.status != SoraHfPlacementHostStatusV1::Retired',
      'let expected_status = derive_hf_placement_status(record);',
      'record.status != expected_status',
    ],
    'Iroha canonical HF placement economics and lifecycle projection'
  );
  requireScopedLiterals(
    soracloudCore,
    'fn record_hf_placement(',
    '\nfn load_hf_placement_by_placement_id(',
    [
      'record.status = derive_hf_placement_status(&record);',
      'record\n        .validate()',
      'validate_hf_placement_economics_and_status(&record)?;',
      '.soracloud_hf_placements\n        .insert(record.pool_id, record);',
    ],
    'Iroha live HF placement canonical key, economics, and status admission'
  );
  requireScopedLiterals(
    soracloudCore,
    'impl Execute for isi::FinalizeSoracloudUploadedModelBundle {',
    '\nimpl Execute for isi::AdvanceSoracloudRollout {',
    [
      'ensure_soracloud_audit_sequence_capacity(state_transaction, 2)?;',
      'let weight_sequence = next_soracloud_audit_sequence(state_transaction)?;',
      'let artifact_sequence = weight_sequence.checked_add(1)',
      'registry_record.updated_sequence = weight_sequence;',
      'registered_sequence: weight_sequence,',
      'registered_sequence: artifact_sequence,',
      'sequence: weight_sequence,',
      'sequence: artifact_sequence,',
    ],
    'Iroha uploaded-model finalization allocates distinct weight and artifact audit sequences'
  );
  requireScopedLiterals(
    soracloudCoreTests,
    'fn soracloud_uploaded_model_finalize_uses_sorafs_pin_metadata_without_chunks()',
    '\n#[test]\nfn soracloud_uploaded_model_finalize_rejects_unregistered_bundle()',
    [
      'let weight_sequence = next_soracloud_audit_sequence(&stx)?;',
      'let artifact_sequence = weight_sequence.checked_add(1).expect("sequence capacity");',
      'assert_eq!(registry.updated_sequence, weight_sequence);',
      'assert_eq!(weight.registered_sequence, weight_sequence);',
      'assert_eq!(artifact.registered_sequence, artifact_sequence);',
      'latest_soracloud_sequence(&stx.world)',
      'artifact_sequence',
    ],
    'Iroha uploaded-model distinct audit-sequence regression'
  );
  requireScopedLiterals(
    soracloudCore,
    'fn assigned_heartbeat_miss_history(',
    '\nfn slash_validator_for_model_host_violation(',
    [
      'pool_id: &Hash',
      'window_started_at_ms: u64',
      'record.pool_id.as_ref() != Some(pool_id)',
      'record.window_started_at_ms != Some(window_started_at_ms)',
    ],
    'Iroha reservation-window-scoped heartbeat strike history'
  );
  requireScopedLiterals(
    soracloudCore,
    'fn model_host_validator_is_active(',
    '\nfn reconcile_inactive_model_host(',
    [
      'soracloud_validator_is_active(',
      'state_transaction.is_lane_active_for_authority(lane_id)',
    ],
    'Iroha centralized lane-aware model-host validator lifecycle gate'
  );
  requireLiteral(
    soracloudCore,
    'const MODEL_HOST_VALIDATOR_INACTIVE_REASON: &str = "validator lifecycle is no longer active";',
    'Iroha canonical inactive model-host reconciliation reason'
  );
  requireScopedLiterals(
    soracloudCore,
    'fn reconcile_inactive_model_host(',
    '\nfn report_model_host_violation(',
    [
      'if model_host_validator_is_active(',
      'soracloud_model_host_capabilities',
      '.remove(validator_account_id.clone())',
      'refresh_hf_placements_for_host_status(',
      'MODEL_HOST_VALIDATOR_INACTIVE_REASON',
      'Ok(true)',
    ],
    'Iroha non-penalizing inactive model-host eviction'
  );
  const activeHfAssignmentsScope = requireScopedLiterals(
    soracloudCore,
    'fn active_hf_assigned_placements_for_validator(',
    '\nfn model_host_capability_advert_contradiction_detail(',
    [
      'SoraHfSharedLeaseStatusV1::Expired | SoraHfSharedLeaseStatusV1::Retired',
      'if pool.window_expires_at_ms <= now_ms',
      'SoraHfPlacementHostStatusV1::Retired',
      'SoraHfPlacementHostStatusV1::Unavailable',
    ],
    'Iroha expired-window HF assignment exclusion'
  );
  if (activeHfAssignmentsScope.includes('queued_next_window')) {
    fail('Iroha expired-window HF assignments must not remain active merely because a renewal is queued');
  }
  const reservedHfUsageScope = requireScopedLiterals(
    soracloudCore,
    'fn hf_reserved_host_usage(',
    '\nfn hf_placement_seed_hash(',
    [
      'SoraHfSharedLeaseStatusV1::Expired | SoraHfSharedLeaseStatusV1::Retired',
      'if pool.window_expires_at_ms <= now_ms',
      'SoraHfPlacementHostStatusV1::Retired | SoraHfPlacementHostStatusV1::Unavailable',
    ],
    'Iroha expired-window HF reservation release'
  );
  if (reservedHfUsageScope.includes('queued_next_window')) {
    fail('Iroha expired-window HF reservations must not remain charged merely because a renewal is queued');
  }
  const modelHostReportScope = requireScopedLiterals(
    soracloudCore,
    'fn report_model_host_violation(',
    '\n#[derive(Clone, Copy, Debug, PartialEq, Eq)]\nenum ModelHostReconciliationCause',
    [
      'if reconcile_inactive_model_host(',
      'return Ok(());',
      'SoraHfPlacementStatusV1::Unavailable | SoraHfPlacementStatusV1::Retired',
      'SoraHfSharedLeaseStatusV1::Active | SoraHfSharedLeaseStatusV1::Draining',
      'pool.window_started_at_ms > observed_at_ms',
      'pool.window_expires_at_ms <= observed_at_ms',
      'model-host violation reports require an active assigned placement window',
      'model-host violation kind does not match the active assignment status',
    ],
    'Iroha active-context model-host violation admission'
  );
  requireOrdered(
    modelHostReportScope,
    'if reconcile_inactive_model_host(',
    'let placement = placement_id',
    'Iroha inactive-validator report reconciliation before evidence lookup'
  );
  const modelHostReconcileScope = requireScopedLiterals(
    soracloudCore,
    'fn reconcile_unavailable_model_hosts(',
    '\nfn record_hf_shared_lease_member(',
    [
      'ModelHostReconciliationCause::ValidatorInactive',
      'model_host_validator_is_active(',
      'if !validator_is_active {',
      'let reconciliation_plans =',
      'active_hf_assigned_placements_for_validator(',
      'warming_placement',
      'warm_placement',
      'impacted_placements.len()',
      'ensure_soracloud_audit_sequence_capacity(',
      'if cause == ModelHostReconciliationCause::ValidatorInactive {',
      'report_model_host_violation(',
      'soracloud_model_host_capabilities',
      'refresh_hf_placements_for_host_status(',
    ],
    'Iroha lifecycle-aware idempotent batched model-host reconciliation'
  );
  if (modelHostReconcileScope.includes('placement_id: None')) {
    fail('Iroha model-host reconciliation must not synthesize placementless heartbeat strikes');
  }
  const expiredHfWindowReconcileScope = requireScopedLiterals(
    soracloudCore,
    'fn reconcile_expired_hf_shared_lease_windows(',
    '\nfn bind_hf_shared_lease_targets(',
    [
      'pool.window_expires_at_ms <= now_ms',
      'SoraHfSharedLeaseStatusV1::Active | SoraHfSharedLeaseStatusV1::Draining',
      'if pool.queued_next_window.is_some()',
      'reconcile_hf_shared_lease_queued_window(',
      'expire_hf_shared_lease_members(state_transaction, &pool.pool_id, now_ms)?;',
      'pool.active_member_count = 0;',
      'pool.status = SoraHfSharedLeaseStatusV1::Expired;',
      'record_hf_shared_lease_pool(state_transaction, pool.clone())?;',
      'retire_hf_placement_for_pool(',
      'lease window expired without a queued next-window sponsor',
    ],
    'Iroha automatic authoritative HF lease-window rollover'
  );
  requireOrdered(
    expiredHfWindowReconcileScope,
    'expire_hf_shared_lease_members(state_transaction, &pool.pool_id, now_ms)?;',
    'retire_hf_placement_for_pool(',
    'Iroha unqueued HF window member expiry before placement retirement'
  );
  const expiredQueuedHfWindowScope = requireScopedLiterals(
    soracloudCore,
    'fn expire_hf_shared_lease_queued_window(',
    '\nfn reconcile_hf_shared_lease_queued_window(',
    [
      'sponsor_member.status != SoraHfSharedLeaseMemberStatusV1::Active',
      'expire_hf_shared_lease_members(state_transaction, &pool.pool_id, now_ms)?;',
      'pool.window_started_at_ms = next_window.window_started_at_ms;',
      'pool.window_expires_at_ms = next_window.window_expires_at_ms;',
      'pool.active_member_count = 0;',
      'pool.status = SoraHfSharedLeaseStatusV1::Expired;',
      'pool.queued_next_window = None;',
      'retire_hf_placement_for_pool(state_transaction, &pool.pool_id, now_ms, reason)',
      'let audit_sequence = next_soracloud_audit_sequence(state_transaction)?;',
      'action: SoraHfSharedLeaseActionV1::ActivationFailed,',
      'charged: Quantity::zero(),',
      'refunded: Quantity::zero(),',
      'failure_reason: Some(reason.to_owned()),',
    ],
    'Iroha terminal queued HF activation-failure audit'
  );
  if (
    expiredQueuedHfWindowScope.includes('transfer_hf_shared_lease_amount(') ||
    expiredQueuedHfWindowScope.includes('total_compute_refunded')
  ) {
    fail('Iroha unactivated queued HF termination must not transfer or refund uncharged compute');
  }
  requireOrdered(
    expiredQueuedHfWindowScope,
    'retire_hf_placement_for_pool(state_transaction, &pool.pool_id, now_ms, reason)',
    'let audit_sequence = next_soracloud_audit_sequence(state_transaction)?;',
    'Iroha terminal queued HF state transition before collision-free failure audit allocation'
  );
  const queuedHfWindowSettlementScope = requireScopedLiterals(
    soracloudCore,
    'fn reconcile_hf_shared_lease_queued_window(',
    '\nfn reconcile_expired_hf_shared_lease_windows(',
    [
      'pool.validate().map_err(',
      'source_record.validate().map_err(',
      'source_record.resource_profile.as_ref() != Some(&next_window.resource_profile)',
      'if now_ms >= next_window.window_expires_at_ms',
      'HF_QUEUED_WINDOW_EXPIRED_BEFORE_ACTIVATION_REASON',
      'ranked_hf_eligible_hosts_by_seed(',
      '&next_window.resource_profile,',
      '.is_empty()',
      'HF_QUEUED_WINDOW_UNFULFILLABLE_REASON',
      'let active_placement = select_hf_placement_for_window(',
      '&next_window.resource_profile,',
      'ensure_hf_compute_reservation_charge_within_cap(',
      'let remaining_window_ms = next_window',
      '.saturating_sub(now_ms)',
      '.min(pool.lease_term_ms);',
      'let settled_compute_reservation_fee = prorated_window_fee(',
      '&next_window.compute_reservation_cap',
      'hf_shared_lease_account_balance(',
      '< settled_compute_reservation_fee',
      'HF_QUEUED_WINDOW_UNFUNDED_REASON',
      'let activation_audit_sequence = next_soracloud_audit_sequence(state_transaction)?;',
      '.checked_add(&settled_compute_reservation_fee)',
      'transfer_hf_shared_lease_amount(',
      '&next_window.sponsor_account_id',
      'sponsor_member.total_compute_paid = total_compute_paid;',
      'sponsor_member.last_compute_charge = settled_compute_reservation_fee.clone();',
      'pool.queued_next_window = None;',
      'record_hf_placement(state_transaction, active_placement)?;',
      'action: SoraHfSharedLeaseActionV1::Activate,',
      'charged: settled_compute_reservation_fee,',
    ],
    'Iroha activation-time queued HF compute settlement'
  );
  requireOrdered(
    queuedHfWindowSettlementScope,
    'if now_ms >= next_window.window_expires_at_ms',
    'let active_placement = select_hf_placement_for_window(',
    'Iroha stale queued HF window rejection before host selection'
  );
  requireOrdered(
    queuedHfWindowSettlementScope,
    'HF_QUEUED_WINDOW_UNFULFILLABLE_REASON',
    'let active_placement = select_hf_placement_for_window(',
    'Iroha unfulfillable queued HF window rejection before host selection'
  );
  requireOrdered(
    queuedHfWindowSettlementScope,
    'hf_shared_lease_account_balance(',
    'let activation_audit_sequence = next_soracloud_audit_sequence(state_transaction)?;',
    'Iroha queued HF activation funding preflight before audit allocation'
  );
  requireOrdered(
    queuedHfWindowSettlementScope,
    'let activation_audit_sequence = next_soracloud_audit_sequence(state_transaction)?;',
    'transfer_hf_shared_lease_amount(',
    'Iroha queued HF activation audit-capacity preflight before compute transfer'
  );
  const queuedHfRenewalScope = requireScopedLiterals(
    soracloudCore,
    'impl Execute for isi::RenewSoracloudHfSharedLease {',
    '\n        expire_hf_shared_lease_members(state_transaction, &pool_id, now_ms)?;',
    [
      'let compute_reservation_cap =',
      'hf_shared_lease_max_compute_reservation_fee_v1(&resource_profile, lease_term_ms)',
      'transfer_hf_shared_lease_amount(',
      '&base_fee',
      'member.last_compute_charge = Quantity::zero();',
      'compute_reservation_cap,',
      'resource_profile,',
      'charged: base_fee,',
    ],
    'Iroha canonical-profile queued HF storage-only renewal charge'
  );
  if (queuedHfRenewalScope.includes('&queued_total_charge')) {
    fail('Iroha queued HF renewal must not pre-charge compute');
  }
  if (queuedHfRenewalScope.includes('select_hf_placement_for_window(')) {
    fail('Iroha queued HF renewal must defer placement selection until activation');
  }
  const queuedHfWireScope = requireScopedLiterals(
    soracloudDataModelHosting,
    'pub struct SoraHfSharedLeaseQueuedWindowV1 {',
    '\nimpl SoraHfSharedLeaseQueuedWindowV1 {',
    [
      'pub compute_reservation_cap: Quantity,',
      'pub resource_profile: SoraHfResourceProfileV1,',
      'Activation selects a fresh authoritative placement against this profile',
    ],
    'Iroha queued HF canonical resource-profile wire contract'
  );
  if (queuedHfWireScope.includes('quoted_placement')) {
    fail('Iroha first-release queued HF windows must not persist stale placement quotes');
  }
  requireScopedLiterals(
    soracloudDataModelHosting,
    'impl SoraHfSharedLeasePoolV1 {',
    '\n/// Account-scoped shared-lease membership',
    [
      'next_window.validate()?;',
      'next_window.lease_asset_definition_id != self.lease_asset_definition_id',
      '"queued_next_window.lease_asset_definition_id"',
      'hf_shared_lease_max_compute_reservation_fee_v1(',
      '&next_window.resource_profile,',
      'self.lease_term_ms,',
      'next_window.compute_reservation_cap != canonical_compute_reservation_cap',
      '"queued_next_window.compute_reservation_cap"',
    ],
    'Iroha queued HF canonical cap and settlement-asset binding'
  );
  requireScopedLiterals(
    soracloudDataModelHosting,
    'impl SoraHfSharedLeaseMemberV1 {',
    '\n/// Audit record for shared Hugging Face lease lifecycle changes.',
    [
      '("total_refunded", &self.total_refunded, &self.total_paid)',
      '"total_compute_refunded"',
      '&self.total_compute_refunded',
      '&self.total_compute_paid',
      'must not exceed the corresponding total paid',
      'self.last_charge > self.total_paid',
      'self.last_compute_charge > self.total_compute_paid',
    ],
    'Iroha HF shared-lease member monotonic accounting bounds'
  );
  requireScopedLiterals(
    soracloudCore,
    'fn hf_shared_lease_pool_id(',
    '\nfn ensure_hf_shared_lease_settlement_asset_matches(',
    ['derive_hf_shared_lease_pool_id_v1(source_id, storage_class, lease_term_ms)'],
    'Iroha core shared canonical HF pool identity derivation'
  );
  requireScopedLiterals(
    soracloudTorii,
    'fn hf_shared_lease_pool_id(',
    '\nfn hf_profile_http_client(',
    ['derive_hf_shared_lease_pool_id_v1(source_id, storage_class, lease_term_ms)'],
    'Iroha Torii shared canonical HF pool identity derivation'
  );
  requireScopedLiterals(
    soracloudDataModelHosting,
    'pub enum SoraHfSharedLeaseActionV1 {',
    '\n/// Queued next-window sponsorship metadata',
    [
      'Activate,',
      'ActivationFailed,',
      'A queued window reached activation but could not become active.',
    ],
    'Iroha terminal HF activation-failure action'
  );
  requireScopedLiterals(
    soracloudDataModelHosting,
    'pub struct SoraHfSharedLeaseAuditEventV1 {',
    '\nimpl SoraHfSharedLeaseAuditEventV1 {',
    [
      'pub failure_reason: Option<String>,',
      'Terminal activation failure reason',
    ],
    'Iroha HF activation-failure audit payload'
  );
  requireScopedLiterals(
    soracloudDataModelHosting,
    'impl SoraHfSharedLeaseAuditEventV1 {',
    '\n/// Audit record for model-artifact lifecycle changes.',
    [
      'SoraHfSharedLeaseActionV1::ActivationFailed =>',
      '.failure_reason',
      '"must be non-empty for activation failures"',
      '_ if self.failure_reason.is_some() =>',
      '"must be omitted unless action is activation_failed"',
    ],
    'Iroha HF activation-failure reason iff validation'
  );
  requireScopedLiterals(
    soracloudDataModelRecordTests,
    'fn hf_shared_lease_pool_binds_queued_profile_cap_and_asset()',
    '\n#[test]\nfn hf_shared_lease_pool_validation_rejects_misaligned_queued_window()',
    [
      'hf_shared_lease_max_compute_reservation_fee_v1(&resource_profile, pool.lease_term_ms)',
      'canonical queued-window cap and settlement asset are valid',
      'a non-canonical compute cap must fail',
      'field: "queued_next_window.compute_reservation_cap"',
      'a queued settlement asset mismatch must fail',
      'field: "queued_next_window.lease_asset_definition_id"',
    ],
    'Iroha queued HF cap and settlement-asset regression'
  );
  requireScopedLiterals(
    soracloudDataModelRecordTests,
    'fn hf_shared_lease_audit_event_binds_activation_failure_reason()',
    '\n#[test]\nfn hf_shared_lease_audit_event_validation_rejects_zero_prehash_digest_sentinels()',
    [
      'event.action = SoraHfSharedLeaseActionV1::ActivationFailed;',
      'event.failure_reason = Some("queued sponsor could not fund compute".to_owned());',
      'an activation failure with a reason is valid',
      'successful activation must not carry a failure reason',
      'field: "failure_reason"',
    ],
    'Iroha HF activation-failure reason validation regression'
  );
  requireScopedLiterals(
    soracloudTorii,
    'fn authoritative_hf_shared_lease_mutation_response(',
    '\nfn authoritative_agent_deploy_mutation_response(',
    [
      'let active_placement = world.soracloud_hf_placements().get(&pool_id).cloned();',
      'let queued_renewal = if event.action == SoraHfSharedLeaseActionV1::Renew',
      'A queued renewal has no authoritative next-window placement or compute charge yet.',
      'let placement = active_placement.clone();',
      'compute_reservation_fee: queued_renewal.map_or_else(',
      '_queued_window| Quantity::zero(),',
    ],
    'Iroha Torii queued HF response without phantom placement or compute settlement'
  );
  requireScopedLiterals(
    soracloudTorii,
    'fn authoritative_hf_shared_lease_status_reads_world_state()',
    '\n    #[test]\n    fn authoritative_hf_shared_lease_mutation_reads_world_state()',
    [
      'resource_profile:',
      'assert_eq!(mutation_response.action, SoraHfSharedLeaseActionV1::Renew);',
      'assert!(mutation_response.placement.is_none());',
      'assert!(mutation_response.compute_reservation_fee.is_zero());',
      '"0.00002".parse::<Quantity>().expect("queued base fee")',
    ],
    'Iroha Torii queued HF response semantics regression'
  );
  requireScopedLiterals(
    soracloudCore,
    'impl Execute for isi::SetSoracloudInrouReplicaRuntimeState {',
    '\nimpl Execute for isi::ClearSoracloudInrouReplicaRuntimeState {',
    [
      'state\n            .validate()',
      'load_admitted_bundle(',
      'state.materialized_bundle_hash != admitted_bundle.container.bundle_hash',
      'the admitted bundle hash is',
      'resolve_active_inrou_replica_assignment(',
      'has no authoritative Inrou placement',
      'is not assigned to service',
      'Inrou replica runtime state identity must exactly match its authoritative placement',
      'state.reporting_epoch != lease.reporting_epoch',
      'an assigned Inrou replica must open its zero usage checkpoint before serving',
      'write_soracloud_inrou_replica_runtime_state(state_transaction, state)',
    ],
    'Iroha ledger Inrou runtime assignment, accounting, and admitted-bundle binding'
  );
  requireScopedLiterals(
    soracloudCoreRuntime,
    'pub fn validate_soracloud_deployment_lease_volume_bindings(',
    '\n/// Validate the immutable identity shared by every admitted revision',
    [
      'let mut declared_names = BTreeSet::new();',
      'let mut authoritative_names = BTreeSet::new();',
      'declared_names != authoritative_names',
      'requires exact 1:1 admitted-to-authoritative lease-volume state',
      '.find(|state| state.volume_name == binding.volume_name)',
      '("kind", state.kind == binding.kind)',
      '"storage_class",',
      'state.storage_class == binding.storage_class',
      '("mount_path", state.mount_path == binding.mount_path)',
      'state.max_total_bytes == binding.max_total_bytes.get()',
    ],
    'Iroha exact admitted-to-authoritative lease-volume economics invariant'
  );
  requireScopedLiterals(
    soracloudStateRestore,
    'let service_deployments = self.service_deployments.view();',
    '\n        let app_infra_audit_events = self.app_infra_audit_events.view();',
    [
      'admitted revision `{service_version}` has no authoritative deployment',
      'deployment.revision_count != exact_revision_count',
      'validate_soracloud_deployment_lease_volume_bindings(',
      'validate_soracloud_service_revision_identity(',
      'invalid_soracloud_state("soracloud_service_revisions", message)',
    ],
    'Iroha restore closure over deployments, exact storage rows, and immutable retained revisions'
  );
  requireScopedLiterals(
    soracloudStateTests,
    'state_test! { sync service_deployment_restore_requires_exact_admitted_revision_binding',
    '\nstate_test! { sync runtime_and_inrou_restore_require_authoritative_references',
    [
      'every admitted revision must belong to an authoritative deployment',
      'restore must reject lease-volume rows absent from the admitted manifest',
      'error.to_string().contains("exact 1:1")',
      'restore must reject retained revisions with a distinct immutable identity',
      'error.to_string().contains("cannot change route identity")',
    ],
    'Iroha persisted deployment cross-record restore regressions'
  );
  requireScopedLiterals(
    soracloudStateTests,
    'state_test! { sync service_state_restore_requires_exact_revision_audit_and_binding_quota',
    '\nstate_test! { sync runtime_and_inrou_restore_require_authoritative_references',
    [
      'service-state row with exact revision, binding, audit, and quota must restore',
      'service-state row must bind its exact producing audit event',
      'service-state aggregate quota must fail closed during restore',
      'aggregate payload size exceeds its admitted maximum',
    ],
    'Iroha service-state restore closure regression'
  );
  requireScopedLiterals(
    soracloudStateTests,
    'state_test! { sync inrou_reachable_restore_rejects_invalid_and_miskeyed_runtime_records',
    '\nstate_test! { sync runtime_and_inrou_restore_require_authoritative_references',
    [
      'PeerId::from(BOB_ID.expect_single_signatory().clone())',
      'restore must reject account/peer-inconsistent Inrou capability state',
      'derived from the validator account',
    ],
    'Iroha restored Inrou capability canonical account/peer regression'
  );
  requireScopedLiterals(
    soracloudTorii,
    'pub(crate) fn resolve_public_route(',
    '\nfn normalize_public_route_host(',
    [
      'validate_soracloud_deployment_lease_volume_bindings(',
      '.is_err()',
      'continue;',
      'hosted_service_lease_active_at(current_sequence)',
    ],
    'Iroha public hosted routing rejects non-exact authoritative storage rows'
  );
  requireScopedLiterals(
    soracloudTorii,
    'pub(crate) fn control_plane_snapshot(',
    '\nfn authoritative_app_infra_status_response(',
    [
      'validate_soracloud_deployment_lease_volume_bindings(',
      'invalid authoritative lease-volume state',
      'let accounted_storage_bytes = deployment.accounted_storage_bytes();',
      'lease.status_at(current_sequence, accounted_storage_bytes)?',
    ],
    'Iroha control-plane accounting rejects non-exact authoritative storage rows'
  );
  requireScopedLiterals(
    soracloudTorii,
    'async fn resolve_public_route_projects_http_service_inrous()',
    '\n    #[tokio::test]\n    async fn resolve_public_route_splits_hosted_live_search_from_vault_handlers()',
    [
      'fixture_service_lease_volume_states(&bundle, Some(&lease))',
      'invalid_volume_world',
      '.lease_volume_states\n            .pop();',
      'public routing must fail closed when authoritative storage rows do not exactly match the admitted bundle',
    ],
    'Iroha public hosted route exact-storage regression'
  );
  requireScopedLiterals(
    soracloudToriiLeaseTests,
    'fn control_plane_snapshot_projects_full_hosted_service_lease()',
    '\n#[test]\nfn control_plane_audit_event_projects_lease_reporting_epoch_rollover()',
    [
      'fixture_service_lease_volume_states(&bundle, Some(&lease))',
      'validate_soracloud_deployment_lease_volume_bindings(',
      'invalid_volume_world',
      'control-plane accounting must reject non-exact authoritative storage rows',
      'lease.remaining_balance(10, accounted_storage_bytes)?',
    ],
    'Iroha control-plane exact-storage accounting regression'
  );
  requireScopedLiterals(
    soracloudIrohad,
    'fn build_lease_volume_plans(',
    '\nfn local_inrou_replica_placements(',
    [
      'validate_soracloud_deployment_lease_volume_bindings(',
      'validate exact admitted lease-volume state',
      'state.validate()',
      'authoritative.lease_expires_sequence',
      'authoritative.authoritative_generation',
    ],
    'Iroha daemon materialization through shared exact storage invariant'
  );
  requireScopedLiterals(
    soracloudCoreRuntime,
    'pub fn resolve_active_inrou_placement_record(',
    '\n#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]\nstruct ActiveInrouReservationUsage',
    [
      'record.validate()',
      'record.service_name != service_name_id || record.service_version != service_version',
      'deployment.validate()',
      'deployment.service_name != service_name_id',
      'hosted_service_lease_active_at(current_sequence)',
      'let version_is_active =',
      'bundle.validate_for_admission()',
      'bundle.service.service_name != service_name_id',
      'SoraContainerRuntimeV1::Inrou',
      'SoraServiceExecutionPlaneV1::HttpService',
      'record.desired_replica_count != bundle.service.replicas.get()',
      'deployment.current_service_manifest_hash != bundle.service_manifest_hash()',
      'validate_soracloud_deployment_lease_volume_bindings(deployment, bundle)',
      'deployment.lease_volume_states.iter().any(|volume|',
      'current_sequence < volume.lease_started_sequence',
      'current_sequence >= volume.lease_expires_sequence',
    ],
    'Iroha exact lifecycle, lease-volume, and record-bound Inrou placement resolver'
  );
  requireScopedLiterals(
    soracloudCoreTests,
    'fn active_inrou_resolver_requires_exact_admitted_lease_volume_economics()',
    '\n#[test]\nfn set_inrou_replica_runtime_state_rejects_missing_placement()',
    [
      'validate_soracloud_deployment_lease_volume_bindings(',
      'canonical.accounted_storage_bytes()',
      'missing.lease_volume_states.pop()',
      'SoraLeaseVolumeKindV1::ConfidentialLeaseVolume',
      'StorageClass::Hot',
      'mount_path = "/different"',
      '.max_total_bytes',
      'an under-accounted deployment must never resolve as active',
      'noncanonical lease-volume economics',
    ],
    'Iroha exact admitted lease-volume economics resolver regression'
  );
  requireScopedLiterals(
    soracloudCore,
    'fn require_soracloud_service_runtime_authority(',
    '\nfn verify_bundle_provenance(',
    [
      'resolve_active_inrou_replica_assignments(',
      'state_transaction.block_unix_timestamp_ms().max(1)',
      'state_transaction.is_lane_active_for_authority(lane_id)',
      'assignment.validator_account_id == *authority',
    ],
    'Iroha service runtime authority through the shared Inrou resolver'
  );
  requireScopedLiterals(
    soracloudCoreRuntime,
    'fn active_inrou_reservation_usage_by_validator(',
    '\nfn inrou_replica_assignment_has_active_capability(',
    [
      'resolve_active_inrou_placement_record(world, service_name, service_version)?',
      'checked_add(1)',
      'checked_add(cpu_millis)',
      'checked_add(memory_bytes)',
      'checked_add(storage_bytes)',
      'reservations overflow for validator',
    ],
    'Iroha fail-closed aggregate Inrou reservation arithmetic'
  );
  requireScopedLiterals(
    soracloudCoreRuntime,
    'fn inrou_replica_assignment_has_active_capability(',
    '\n/// Resolve all exact active replica assignments',
    [
      'capability.validate().is_ok()',
      'capability.validator_account_id == assignment.validator_account_id',
      'capability.peer_id == assignment.peer_id',
      'capability.can_host_replicas_at(now_ms)',
      '.contains(&assignment.selected_guest_isa)',
      'guest_images',
      'max_cpu_millis',
      'max_memory_bytes',
      'max_storage_bytes',
      'soracloud_validator_has_active_peer_binding(',
      '&assignment.peer_id,',
    ],
    'Iroha exact validator/capability/resource Inrou assignment gate'
  );
  requireScopedLiterals(
    soracloudCoreRuntime,
    'pub fn resolve_active_inrou_replica_assignments(',
    '\n/// Resolve one exact active replica-slot assignment',
    [
      'active_inrou_reservation_usage_by_validator(world)?',
      'usage.hosted_replicas <= u32::from(capability.max_hosted_replica_capacity)',
      'usage.cpu_millis <= u64::from(capability.max_cpu_millis)',
      'usage.memory_bytes <= capability.max_memory_bytes',
      'usage.storage_bytes <= capability.max_storage_bytes',
      'inrou_replica_assignment_has_active_capability(',
    ],
    'Iroha aggregate-capacity-authoritative Inrou assignment resolver'
  );
  requireScopedLiterals(
    soracloudCoreTests,
    'fn set_inrou_replica_runtime_state_rejects_missing_placement()',
    '\n#[test]\nfn clear_inrou_replica_runtime_state_rejects_missing_placement()',
    [
      'runtime state without an authoritative placement must fail',
      'assert_invariant_contains(error, "has no authoritative Inrou placement")',
      'a rejected runtime update must not clear stale state; the explicit clear instruction owns cleanup',
    ],
    'Iroha fail-closed missing-placement Inrou runtime update regression'
  );
  requireScopedLiterals(
    soracloudCoreTests,
    'fn clear_inrou_replica_runtime_state_rejects_missing_placement()',
    '\n#[test]\nfn set_inrou_replica_runtime_state_records_matching_placement()',
    [
      'runtime clear without an authoritative placement must fail',
      'assert_invariant_contains(error, "has no authoritative Inrou placement")',
      'a rejected clear must preserve stale state for an explicitly authorized reconciliation path',
    ],
    'Iroha fail-closed missing-placement Inrou runtime clear regression'
  );
  requireScopedLiterals(
    soracloudCoreTests,
    'fn reconcile_soracloud_model_hosts_rebalances_inactive_validator_without_violation()',
    '\n#[test]\nfn reconcile_soracloud_model_hosts_is_idempotent_after_primary_eviction()',
    [
      'PublicLaneValidatorStatus::Exited',
      'otherwise-live model-host advert',
      'validator lifecycle reconciliation must not slash stake',
      'inactive validator advert must be evicted immediately',
      'view.world().soracloud_model_host_violation_evidence().len(),\n        0,',
      'administrative validator exit must not manufacture violation evidence or a strike',
      'Some("validator lifecycle is no longer active")',
    ],
    'Iroha inactive-validator non-penalizing model-host failover test'
  );
  requireScopedLiterals(
    soracloudCoreTests,
    'fn report_model_host_violation_rebalances_inactive_validator_without_evidence()',
    '\n#[test]\nfn report_model_host_violation_rejects_retired_or_status_incompatible_history()',
    [
      'PublicLaneValidatorStatus::Exited',
      'inactive-validator report handling must not slash stake',
      'inactive validator advert must be evicted by report admission',
      'a racing runtime report after validator exit must not create evidence or a strike',
      'Some(MODEL_HOST_VALIDATOR_INACTIVE_REASON)',
    ],
    'Iroha racing inactive-validator report non-penalization test'
  );
  requireScopedLiterals(
    soracloudCoreTests,
    'fn report_model_host_violation_rejects_retired_or_status_incompatible_history()',
    '\n#[test]\nfn report_model_host_violation_slashes_and_evicts_warmup_no_show()',
    [
      'retired placement history must not be slashable',
      'heartbeat-miss evidence requires a warm assignment',
      'invalid delayed reports must not create evidence or strikes',
      'invalid delayed reports must not slash stake',
      'invalid delayed reports must not evict the live advert',
      'invalid delayed reports must not rewrite retired history',
    ],
    'Iroha retired and status-incompatible violation report rejection test'
  );
  requireScopedLiterals(
    soracloudCore,
    'impl Execute for isi::WithdrawSoracloudModelHost {',
    '\nimpl Execute for isi::ReconcileSoracloudModelHosts {',
    [
      'let now_ms = state_transaction.block_unix_timestamp_ms().max(1);',
      'reconcile_unavailable_model_hosts(state_transaction, now_ms)?;',
      'soracloud_model_host_capabilities',
      '.remove(validator_account_id.clone())',
    ],
    'Iroha post-expiry model-host withdrawal ordering'
  );
  const modelHostWithdrawalScope = requireScopedLiterals(
    soracloudCore,
    'impl Execute for isi::WithdrawSoracloudModelHost {',
    '\nimpl Execute for isi::ReconcileSoracloudModelHosts {',
    [],
    'Iroha post-expiry model-host withdrawal ordering scope'
  );
  requireOrdered(
    modelHostWithdrawalScope,
    'reconcile_unavailable_model_hosts(state_transaction, now_ms)?;',
    '.remove(validator_account_id.clone())',
    'Iroha expiry accounting before voluntary model-host withdrawal'
  );
  const modelHostAuthorityReconcileScope = requireScopedLiterals(
    soracloudCore,
    'impl Execute for isi::ReconcileSoracloudModelHosts {',
    '\nimpl Execute for isi::AdvertiseSoracloudInrouHost {',
    [
      'require_soracloud_runtime_authority(authority, state_transaction)?;',
      'reconcile_unavailable_model_hosts(state_transaction, now_ms)?;',
      'reconcile_expired_hf_shared_lease_windows(state_transaction, now_ms)',
    ],
    'Iroha validator-authorized model-host and lease-window reconciliation'
  );
  requireOrdered(
    modelHostAuthorityReconcileScope,
    'reconcile_unavailable_model_hosts(state_transaction, now_ms)?;',
    'reconcile_expired_hf_shared_lease_windows(state_transaction, now_ms)',
    'Iroha host-expiry evidence before HF lease-window transition'
  );
  requireScopedLiterals(
    soracloudCoreInitialFixtureTests,
    'fn reconcile_model_hosts_allows_active_validator_without_manage_permission()',
    '\n#[test]\nfn soracloud_permission_accepts_exact_assigned_role()',
    [
      'insert_active_public_lane_validator(&mut state_transaction, BOB_ID.clone(), 700);',
      'require_soracloud_permission(&BOB_ID, &state_transaction).is_err()',
      'isi::ReconcileSoracloudModelHosts.execute(&BOB_ID, &mut state_transaction)?;',
    ],
    'Iroha active-validator autonomous model-host reconciliation authority test'
  );
  requireScopedLiterals(
    soracloudCoreTests,
    'fn model_host_withdraw_after_assigned_heartbeat_expiry_records_violation()',
    '\n#[test]\nfn model_host_advertise_rejects_zero_signed_record_fields()',
    [
      'post-expiry withdrawal must not erase the miss',
      'SoraModelHostViolationKindV1::AssignedHeartbeatMiss',
      'assert_eq!(evidence[0].strike_count, 1)',
      'assigned host heartbeat expired',
    ],
    'Iroha post-expiry withdrawal violation regression'
  );
  requireScopedLiterals(
    soracloudCoreTests,
    'fn renew_hf_shared_lease_active_window_queues_next_window()',
    '\n#[test]\nfn reconcile_model_hosts_charges_only_prorated_compute_when_queued_hf_window_activates()',
    [
      'fee_sink_account_id = BOB_ID.to_string()',
      'Register::asset_definition(',
      'queued_next_window.compute_reservation_cap',
      'queued_next_window.resource_profile,',
      'sample_hf_resource_profile()',
      'member.total_compute_paid,',
      'active_placement.total_reservation_fee,',
      'assert!(member.last_compute_charge.is_zero());',
      'assert_eq!(audit_event.charged, renewed_fee);',
      'queueing must transfer storage only; compute remains deferred until activation',
    ],
    'Iroha real queued-renewal storage-only charge regression'
  );
  const queuedHfWindowReconcileTestScope = requireScopedLiterals(
    soracloudCoreTests,
    'fn reconcile_model_hosts_charges_only_prorated_compute_when_queued_hf_window_activates()',
    '\n#[test]\nfn reconcile_model_hosts_expires_unactivated_queued_hf_window_without_compute_charge()',
    [
      'active_hf_assigned_placements_for_validator(&reconcile_tx, &ALICE_ID, reconcile_at_ms)',
      'the expired current window must stop exposing old active assignments before promotion',
      'hf_reserved_host_usage(&reconcile_tx, reconcile_at_ms, None).is_empty()',
      'the expired current window must release old host reservations before promotion',
      'isi::ReconcileSoracloudModelHosts.execute(&ALICE_ID, &mut reconcile_tx)?;',
      'assert_eq!(pool.status, SoraHfSharedLeaseStatusV1::Active);',
      'assert!(pool.queued_next_window.is_none());',
      'assert_ne!(placement.placement_id, fixture.current_placement_id);',
      'assert!(settled_compute_fee <= fixture.compute_cap);',
      'assert!(member.last_charge.is_zero());',
      'let settled_compute_fee = prorated_window_fee(',
      'assert_eq!(member.last_compute_charge, settled_compute_fee);',
      'member.total_compute_paid,',
      'assert!(member.total_compute_refunded.is_zero());',
      'queue-time sink receives only base charge',
      'activation-time sink receives prorated compute charge',
      'automatic activation settlement must preserve the charged queued-renewal audit event byte-for-byte',
      'event.action == SoraHfSharedLeaseActionV1::Activate',
      'assert_eq!(activation_audit_event.charged, settled_compute_fee);',
    ],
    'Iroha automatic activation-time queued HF compute-charge regression'
  );
  requireOrdered(
    queuedHfWindowReconcileTestScope,
    'the expired current window must release old host reservations before promotion',
    'isi::ReconcileSoracloudModelHosts.execute(&ALICE_ID, &mut reconcile_tx)?;',
    'Iroha expired reservation release before queued-window promotion'
  );
  requireScopedLiterals(
    soracloudCoreTests,
    'fn reconcile_model_hosts_expires_unactivated_queued_hf_window_without_compute_charge()',
    '\n#[test]\nfn reconcile_model_hosts_terminally_expires_unfunded_queued_hf_window()',
    [
      '[("fully-expired", true), ("no-eligible-host", false)]',
      'fixture.queued_window_expires_at_ms',
      'fixture.current_window_expires_at_ms.saturating_add(1)',
      'assert_eq!(pool.status, SoraHfSharedLeaseStatusV1::Expired, "{case}");',
      'assert_eq!(pool.active_member_count, 0, "{case}");',
      'assert!(pool.queued_next_window.is_none(), "{case}");',
      'SoraHfSharedLeaseMemberStatusV1::Left,',
      'storage fee must remain charged',
      'assert!(member.total_compute_refunded.is_zero(), "{case}");',
      'member.total_compute_paid, fixture.current_compute_charge',
      'placement.placement_id, fixture.current_placement_id,',
      'HF_QUEUED_WINDOW_EXPIRED_BEFORE_ACTIVATION_REASON',
      'HF_QUEUED_WINDOW_UNFULFILLABLE_REASON',
      'queued base charge is funded',
      'queue-time sink keeps the base charge',
      'terminal activation handling must preserve the base-only queued-renewal audit event byte-for-byte',
      'event.action == SoraHfSharedLeaseActionV1::ActivationFailed',
      '.expect("terminal activation failure audit event")',
      'failure_event.sequence > fixture.queued_audit_sequence',
      'failure_event.failure_reason.as_deref()',
      'Some(expected_failure_reason)',
    ],
    'Iroha stale and unfulfillable queued HF terminal-audit regression'
  );
  requireScopedLiterals(
    soracloudCoreTests,
    'fn reconcile_model_hosts_terminally_expires_unfunded_queued_hf_window()',
    '\n#[test]\nfn reconcile_model_hosts_expires_unqueued_hf_window_without_lease_mutation()',
    [
      'Mint::asset_quantity(',
      'queued_base_charge.clone()',
      'isi::ReconcileSoracloudModelHosts.execute(&ALICE_ID, &mut reconcile_tx)?;',
      'assert_eq!(pool.status, SoraHfSharedLeaseStatusV1::Expired);',
      'assert!(pool.queued_next_window.is_none());',
      'assert_eq!(member.status, SoraHfSharedLeaseMemberStatusV1::Left);',
      'assert!(member.total_compute_refunded.is_zero());',
      'Some(HF_QUEUED_WINDOW_UNFUNDED_REASON)',
      'Quantity::zero()',
      'queue-time sink balance',
      'event.action == SoraHfSharedLeaseActionV1::ActivationFailed',
      '.expect("unfunded activation failure audit event")',
      'failure_event.failure_reason.as_deref()',
    ],
    'Iroha unfunded queued HF window terminal-audit regression'
  );
  requireScopedLiterals(
    soracloudCoreTests,
    'fn reconcile_model_hosts_expires_unqueued_hf_window_without_lease_mutation()',
    '\n#[test]\nfn join_hf_shared_lease_after_queued_sponsorship_promotes_next_window()',
    [
      'isi::ReconcileSoracloudModelHosts.execute(&ALICE_ID, &mut reconcile_tx)?;',
      'assert_eq!(pool.status, SoraHfSharedLeaseStatusV1::Expired);',
      'assert_eq!(pool.active_member_count, 0);',
      'assert_eq!(member.status, SoraHfSharedLeaseMemberStatusV1::Left);',
      'assert_eq!(placement.status, SoraHfPlacementStatusV1::Retired);',
      'assignment.status == SoraHfPlacementHostStatusV1::Retired',
      'Some("lease window expired without a queued next-window sponsor")',
      'assert_eq!(world.soracloud_model_host_violation_evidence().len(), 0);',
    ],
    'Iroha automatic unqueued HF window expiry regression'
  );
  requireScopedLiterals(
    soracloudCoreTests,
    'fn reconcile_soracloud_model_hosts_is_idempotent_after_primary_eviction()',
    '\n#[test]\nfn reconcile_soracloud_model_hosts_reports_one_violation_across_multiple_placements()',
    [
      'evidence_count_after_first',
      'must not manufacture another strike',
      'assert_eq!(*placement_after_second, placement_after_first)',
    ],
    'Iroha model-host reconciliation idempotence test'
  );
  requireScopedLiterals(
    soracloudCoreTests,
    'fn retired_hf_records_are_unchanged_by_heartbeat_and_inactive_host_eviction()',
    '\n#[test]\nfn model_host_readvertise_updates_assigned_placement_metadata()',
    [
      'heartbeat must not resurrect a retired placement or host assignment',
      'retired placement history must not manufacture violation evidence or strikes',
      'expired-host reconciliation must leave retired placement history byte-for-byte unchanged',
      'inactive-host eviction must leave a retired placement byte-for-byte unchanged',
    ],
    'Iroha retired HF history non-resurrection regression'
  );
  requireScopedLiterals(
    soracloudCoreTests,
    'fn reconcile_soracloud_model_hosts_reports_one_violation_across_multiple_placements()',
    '\n#[test]\nfn report_model_host_violation_slashes_and_evicts_warmup_no_show()',
    [
      'assert_eq!(evidence.len(), 1)',
      '2 authoritative placement(s)',
      'expired host must be removed from every impacted placement',
    ],
    'Iroha one-evidence multi-placement expiry test'
  );
  const repeatedExpiryStrikeScope = requireScopedLiterals(
    soracloudCoreTests,
    'fn reconcile_model_host_second_expiry_in_same_window_reaches_slash_threshold()',
    '\n#[test]\nfn assigned_heartbeat_miss_strikes_reset_for_a_new_reservation_window()',
    [
      'assigned_heartbeat_miss_strike_threshold = 2',
      'assert_eq!(first.strike_count, 1)',
      'assert!(first.host_evicted)',
      'isi::AdvertiseSoracloudModelHost {',
      'renewed_capability',
      'record_hf_placement(&mut readvertise_tx, reassigned_placement)',
      'assert_eq!(latest.strike_count, 2)',
      'assert_eq!(latest.window_started_at_ms, Some(100))',
      'assert!(latest.penalty_applied)',
      'assert!(latest.host_evicted)',
    ],
    'Iroha same-window repeated-expiry strike and slash lifecycle test'
  );
  requireAtLeast(
    repeatedExpiryStrikeScope,
    'isi::ReconcileSoracloudModelHosts.execute(',
    2,
    'Iroha same-window repeated-expiry reconciliation lifecycle'
  );
  requireScopedLiterals(
    soracloudCoreTests,
    'fn assigned_heartbeat_miss_strikes_reset_for_a_new_reservation_window()',
    '\n#[test]\nfn model_host_advertise_contradiction_emits_evidence_and_slashes_validator()',
    [
      'window_started_at_ms: Some(100)',
      'assert_eq!(latest.window_started_at_ms, Some(200))',
      'assert_eq!(latest.strike_count, 1)',
    ],
    'Iroha heartbeat strike new-window reset test'
  );
  requireScopedLiterals(
    soracloudCoreTests,
    'fn reconcile_model_hosts_preflights_audit_capacity_before_batch_writes()',
    '\n#[test]\nfn hf_shared_lease_audit_sequence_exhaustion_fails_before_authoritative_writes()',
    [
      'u64::MAX - 1',
      'two events must not partially consume the final audit sequence',
      'audit exhaustion must fail before recording any evidence',
      'capabilities_before',
      'placements_before',
      'pools_before',
    ],
    'Iroha model-host reconciliation audit batch atomicity test'
  );
  requireScopedLiterals(
    soracloudCoreTests,
    'fn set_inrou_replica_runtime_state_rejects_unadmitted_bundle_hash_atomically()',
    '\n#[test]\nfn set_inrou_replica_runtime_state_rejects_non_assigned_validator()',
    [
      'seed_active_inrou_replica_runtime_fixture(&mut stx, "hayahi_live", service_version)',
      'unadmitted-inrou-bundle',
      'an assigned validator must not report an unadmitted materialized bundle',
      'the admitted bundle hash is',
      'forged runtime telemetry must not replace the last admitted runtime state',
    ],
    'Iroha Inrou ledger admitted-bundle atomic rejection test'
  );
  requireScopedLiterals(
    soracloudCoreTests,
    'fn inrou_reconciliation_excludes_inactive_validator_with_live_capability()',
    '\n#[test]\nfn inrou_reconciliation_prunes_expired_host_capability()',
    [
      'PublicLaneValidatorStatus::Exited',
      'otherwise-live host advert',
      'assert_eq!(placement.eligible_validator_count, 0)',
      'assert!(placement.placements.is_empty())',
      'inactive validator capability must be evicted during reconciliation',
    ],
    'Iroha Inrou inactive-validator reconciliation test'
  );
  requireScopedLiterals(
    soracloudCoreTests,
    'fn inrou_reconciliation_prunes_expired_host_capability()',
    '\n#[test]\nfn deploy_soracloud_service_rejects_missing_shared_http_service_volume()',
    [
      'expired Inrou capability must be pruned authoritatively',
      'assert_eq!(placement.eligible_validator_count, 0)',
      'assert!(placement.placements.is_empty())',
    ],
    'Iroha Inrou expired-capability pruning test'
  );
  for (const [instruction, nextInstruction] of [
    [
      'impl Execute for isi::JoinSoracloudHfSharedLease {',
      '\nimpl Execute for isi::LeaveSoracloudHfSharedLease {',
    ],
    [
      'impl Execute for isi::LeaveSoracloudHfSharedLease {',
      '\nimpl Execute for isi::RenewSoracloudHfSharedLease {',
    ],
    [
      'impl Execute for isi::RenewSoracloudHfSharedLease {',
      '\nimpl Execute for isi::AdvertiseSoracloudModelHost {',
    ],
  ]) {
    const scope = requireScopedLiterals(
      soracloudCore,
      instruction,
      nextInstruction,
      [
        'let audit_sequence = next_soracloud_audit_sequence(state_transaction)?;',
        'sequence: audit_sequence,',
        'reconcile_hf_shared_lease_queued_window(',
      ],
      'Iroha checked HF shared-lease audit sequence and centralized queued-window settlement'
    );
    requireOrdered(
      scope,
      'let audit_sequence = next_soracloud_audit_sequence(state_transaction)?;',
      'record_hf_shared_lease_audit_event(',
      'Iroha HF shared-lease sequence allocation immediately before its audit write'
    );
  }
  requireAtLeast(
    corePreconditionScope,
    'service upgrade requires a signed `ExactCurrentRevision` precondition',
    1,
    'Iroha ledger atomic service mutation precondition enforcement'
  );
  const coreAdmissionScope = requireScopedLiterals(
    soracloudCore,
    'fn admit_bundle(',
    '\nfn admit_app_infra(',
    [
      'precondition: SoraServiceMutationPreconditionV1,',
      'verify_bundle_provenance(',
      '&precondition,',
      '.soracloud_service_deployments',
      'enforce_service_mutation_precondition(action, &service_name, &precondition, existing.as_ref())?',
      'upgrade cannot supersede an active rollout',
      'enforce_service_upgrade_identity(&current_bundle, &bundle)?;',
      'next_service_process_generation(&service_name, deployment.process_generation)?',
      'next_service_material_generation(&service_name, "config", config_generation)?',
      'next_service_material_generation(&service_name, "secret", secret_generation)?',
      'insert_admitted_bundle(state_transaction, bundle.clone());',
    ],
    'Iroha atomic service bundle admission'
  );
  requireOrdered(
    coreAdmissionScope,
    'verify_bundle_provenance(',
    'enforce_service_mutation_precondition(',
    'Iroha atomic signed service bundle admission'
  );
  requireOrdered(
    coreAdmissionScope,
    'next_service_process_generation(',
    'insert_admitted_bundle(',
    'Iroha fail-closed service generation before revision admission'
  );
  const coreAppPreconditionScope = requireScopedLiterals(
    soracloudCore,
    'fn enforce_app_infra_mutation_precondition(',
    '\nfn admit_app_infra(',
    [
      'SoraAppInfraActionV1::Deploy,',
      'SoraAppInfraMutationPreconditionV1::AppAbsent,',
      'SoraAppInfraActionV1::Upgrade,',
      'SoraAppInfraMutationPreconditionV1::ExactCurrentRevision(',
      'app_version.trim().is_empty() || *revision_count == 0',
      'current.current_app_version.as_str() == app_version.as_str()',
      '&current.current_manifest_hash == manifest_hash',
      'current.revision_count == *revision_count',
      'authoritative topology revision changed after preflight',
    ],
    'Iroha ledger atomic app topology mutation precondition enforcement'
  );
  requireAtLeast(
    coreAppPreconditionScope,
    'app upgrade requires a signed `ExactCurrentRevision` precondition',
    1,
    'Iroha ledger atomic app topology mutation precondition enforcement'
  );
  const coreAppAdmissionScope = requireScopedLiterals(
    soracloudCore,
    'fn admit_app_infra(',
    '\nimpl Execute for isi::DeploySoracloudAppInfra',
    [
      'precondition: SoraAppInfraMutationPreconditionV1,',
      'verify_app_infra_provenance(authority, &manifest, &precondition, &provenance)?;',
      'enforce_app_infra_mutation_precondition(action, &app_name, &precondition, existing.as_ref())?;',
      'next_soracloud_audit_sequence(state_transaction)?',
      'state.revision_count.checked_add(1)',
      'topology revision count is exhausted',
      'must admit a distinct topology version and manifest',
      'record_app_infra_state(',
      'record_app_infra_audit_event(',
    ],
    'Iroha atomic app topology admission'
  );
  requireOrdered(
    coreAppAdmissionScope,
    'next_soracloud_audit_sequence(state_transaction)?',
    'record_app_infra_state(',
    'Iroha checked app topology audit sequence before state mutation'
  );
  requireScopedLiterals(
    soracloudCore,
    'fn next_service_process_generation(',
    '\nfn next_service_material_generation(',
    [
      'if current_generation == 0',
      'current_generation.checked_add(1)',
      'process generation is exhausted',
    ],
    'Iroha checked service process generation'
  );
  requireScopedLiterals(
    soracloudCore,
    'fn next_service_material_generation(',
    '\nfn enforce_service_upgrade_identity(',
    [
      'current_generation.checked_add(1)',
      'generation is exhausted',
    ],
    'Iroha checked service material generation'
  );
  requireAtLeast(
    soracloudCore,
    'next_service_material_generation(',
    5,
    'Iroha checked service material generation call sites'
  );
  requireScopedLiterals(
    soracloudCore,
    'fn apply_service_config_mutation(',
    '\nfn apply_service_secret_mutation(',
    [
      'next_service_material_generation(service_name, "config", deployment.config_generation)?',
      'deployment.config_generation = next_config_generation;',
    ],
    'Iroha checked direct service config generation'
  );
  requireScopedLiterals(
    soracloudCore,
    'fn apply_service_secret_mutation(',
    '\nfn record_service_state_entry(',
    [
      'next_service_material_generation(service_name, "secret", deployment.secret_generation)?',
      'deployment.secret_generation = next_secret_generation;',
    ],
    'Iroha checked direct service secret generation'
  );
  requireScopedLiterals(
    soracloudCoreRuntime,
    'pub fn validate_soracloud_service_revision_identity(',
    '\n/// Resolve one authoritative Inrou placement record',
    [
      'candidate.service.service_name != current.service.service_name',
      'candidate.service.execution_plane != current.service.execution_plane',
      'candidate.container.runtime != current.container.runtime',
      'candidate.service.route != current.service.route',
      'cannot change route identity',
      'candidate.service.lease_volumes != current.service.lease_volumes',
      'cannot change lease-volume identity or economics',
    ],
    'Iroha shared immutable admitted service revision identity'
  );
  requireScopedLiterals(
    soracloudCore,
    'fn enforce_service_upgrade_identity(',
    '\nfn enforce_service_mutation_precondition(',
    [
      'validate_soracloud_service_revision_identity(current, candidate)',
      'InstructionExecutionError::InvariantViolation(message.into())',
    ],
    'Iroha service upgrade delegation to shared immutable revision identity'
  );
  const rollbackServiceScope = requireScopedLiterals(
    soracloudCore,
    'impl Execute for isi::RollbackSoracloudService {',
    '\nimpl Execute for isi::MutateSoracloudState {',
    [
      '&existing.current_service_version,',
      'validate_soracloud_service_revision_identity(',
      'next_service_process_generation(&self.service_name, existing.process_generation)?',
    ],
    'Iroha immutable-identity checked explicit rollback generation'
  );
  requireOrdered(
    rollbackServiceScope,
    'validate_soracloud_service_revision_identity(',
    'next_service_process_generation(&self.service_name, existing.process_generation)?',
    'Iroha rollback identity validation before generation and state mutation'
  );
  requireScopedLiterals(
    soracloudCoreTests,
    'fn rollback_soracloud_service_rejects_retained_revision_with_changed_identity()',
    '\n#[test]\nfn mutate_soracloud_state_records_authoritative_service_state()',
    [
      'retained revision is individually valid but has a distinct route identity',
      'rollback must not activate a retained revision with a distinct route identity',
      'assert_invariant_contains(error, "cannot change route identity")',
      'identity rejection must precede deployment mutation',
      'identity rejection must precede audit allocation',
    ],
    'Iroha retained-revision rollback identity atomicity regression'
  );
  requireScopedLiterals(
    soracloudCore,
    'impl Execute for isi::AdvanceSoracloudRollout {',
    '\nimpl Execute for isi::SetSoracloudRuntimeState {',
    [
      'let baseline_version = rollout.baseline_version.clone();',
      'next_service_process_generation(',
      'deployment.process_generation = process_generation;',
    ],
    'Iroha checked automatic rollback generation'
  );
  requireScopedLiterals(
    soracloudCore,
    'fn active_inrou_service_versions(',
    '\nfn reconcile_inrou_service_placements(',
    [
      'rollout.stage != SoraRolloutStageV1::Canary',
      '!(1..100).contains(&rollout.traffic_percent)',
      'rollout.candidate_version != deployment.current_service_version',
      'baseline_version == &rollout.candidate_version',
      'deployment.current_service_version.clone()',
      'baseline_version.clone()',
    ],
    'Iroha authoritative active Inrou rollout revisions'
  );
  requireScopedLiterals(
    irohaCoreState,
    '/// Return whether a lane is active for authority checks in this exact state snapshot.',
    '\n    /// Latest committed block hash (if any) for this snapshot.',
    [
      'pub fn is_lane_active_for_authority(&self, lane_id: LaneId) -> bool',
      'let authority_height = u64::try_from(self.height()).unwrap_or(u64::MAX);',
      'consensus_lane_dataspace_at_height(lane_id, &self.nexus, authority_height).is_some()',
    ],
    'Iroha exact state-view lane authority predicate'
  );
  requireScopedLiterals(
    soracloudCoreRuntime,
    'pub fn soracloud_validator_is_active(',
    '\n/// Return whether an account has one exact active validator record bound to its canonical peer.',
    [
      'world.public_lane_validators().iter().any',
      '&key.1 == validator_account_id',
      'public_lane_validator_record_matches_key(key, record)',
      'record.status == PublicLaneValidatorStatus::Active',
      'lane_is_active_for_authority: impl Fn(LaneId) -> bool',
      'lane_is_active_for_authority(key.0)',
    ],
    'Iroha shared exact active-validator lane-authority serving gate'
  );
  requireScopedLiterals(
    soracloudCoreRuntime,
    'pub fn soracloud_validator_has_active_peer_binding(',
    '\n#[derive(Encode)]\nstruct OrderedMailboxDestinationFingerprintV1',
    [
      'validator_account_id.try_signatory()',
      'PeerId::from(signatory.clone())',
      'canonical_peer_id.to_string() != peer_id',
      '&key.1 == validator_account_id',
      'public_lane_validator_record_matches_key(key, record)',
      'record.status == PublicLaneValidatorStatus::Active',
      'record.peer_id == canonical_peer_id',
      'lane_is_active_for_authority(key.0)',
    ],
    'Iroha canonical single-signatory validator peer binding'
  );
  requireScopedLiterals(
    soracloudCore,
    'fn require_inrou_host_peer_binding(',
    '\nfn require_soracloud_runtime_authority(',
    [
      'soracloud_validator_has_active_peer_binding(',
      'authority,',
      'peer_id,',
      'state_transaction.is_lane_active_for_authority(lane_id)',
      "derived from the validator account's single signatory",
    ],
    'Iroha ledger canonical Inrou advert peer admission'
  );
  requireScopedLiterals(
    soracloudCoreTests,
    'fn inrou_host_advertise_rejects_a_noncanonical_validator_record_peer()',
    '\n#[test]\nfn load_hf_placement_by_placement_id_rejects_duplicate_authoritative_state()',
    [
      'PeerId::from(BOB_ID.expect_single_signatory().clone())',
      '.public_lane_validators',
      'the validator record and advert must both bind to the account signatory',
      'a mutually matching but noncanonical record and advert must not publish capability',
    ],
    'Iroha noncanonical validator record and advert peer rejection regression'
  );
  requireScopedLiterals(
    soracloudCoreRuntime,
    'pub fn soracloud_hf_placement_assignment_has_active_capability(',
    '\n/// Resolve the current authoritative primary host',
    [
      'capability.validate().is_ok()',
      'capability.is_active_at(now_ms)',
      'capability.validator_account_id == assignment.validator_account_id',
      'soracloud_validator_is_active(',
      'lane_is_active_for_authority,',
      'capability.peer_id == assignment.peer_id',
      'capability.host_class == assignment.host_class',
    ],
    'Iroha generated-HF active validator and exact capability serving gate'
  );
  requireScopedLiterals(
    soracloudCoreRuntime,
    'pub fn resolve_generated_hf_active_placement(',
    '\n/// Return whether an HF placement assignment is backed by the exact active host capability.',
    [
      'pool.window_started_at_ms <= now_ms',
      'pool.window_expires_at_ms > now_ms',
      'SoraHfSharedLeaseStatusV1::Active | SoraHfSharedLeaseStatusV1::Draining',
      'SoraHfPlacementStatusV1::Ready | SoraHfPlacementStatusV1::Degraded',
      'return Ok(None);',
    ],
    'Iroha generated-HF serving-status placement gate'
  );
  requireScopedLiterals(
    soracloudCoreRuntime,
    'pub fn resolve_generated_hf_active_placement(',
    '\n/// Return whether an HF placement assignment is backed by the exact active host capability.',
    [
      'member.validate()',
      'member_pool_id != &member.pool_id.to_string()',
      'member_account_id != &member.account_id.to_string()',
      'pool.validate()',
      'pool.pool_id != member.pool_id',
      'placement.validate()',
      'placement.pool_id != pool_id || placement.source_id.to_string() != source_id',
    ],
    'Iroha generated-HF exact member, pool, and placement key binding'
  );
  requireScopedLiterals(
    soracloudCoreRuntime,
    'fn resolve_generated_hf_primary_assignment_rejects_non_serving_stale_warm_primary()',
    '\n    #[test]\n    fn resolve_generated_hf_primary_assignment_rejects_stale_mismatched_or_inactive_capability()',
    [
      'SoraHfPlacementStatusV1::Selecting',
      'SoraHfPlacementStatusV1::Warming',
      'SoraHfPlacementStatusV1::Unavailable',
      'SoraHfPlacementStatusV1::Retired',
      'a {non_serving_status:?} placement must not route through a stale Warm assignment',
    ],
    'Iroha generated-HF non-serving placement rejection test'
  );
  requireScopedLiterals(
    soracloudCoreRuntime,
    'fn resolve_generated_hf_active_placement_rejects_cross_bound_placement()',
    '\n    #[test]\n    fn resolve_generated_hf_primary_assignment_rejects_stale_mismatched_or_inactive_capability()',
    [
      'cross-bound-hf-source',
      'cross-bound-hf-pool',
      'cross-bound authoritative placement must fail closed',
      'does not match pool',
    ],
    'Iroha generated-HF cross-bound placement rejection test'
  );
  requireScopedLiterals(
    soracloudCoreRuntime,
    'fn resolve_generated_hf_primary_assignment_rejects_stale_mismatched_or_inactive_capability()',
    '\n    #[test]\n    fn private_uploaded_model_quantized_cpu_runtime_is_deterministic_and_receipted()',
    [
      'PublicLaneValidatorStatus::Exited',
      'malformed_capability.schema_version = 0',
      'a malformed capability record must fail generated-HF routing closed',
      'LaneId::new(1)',
      'view.is_lane_active_for_authority(lane_id)',
      'a validator record on an inactive lane must not authorize generated-HF serving',
    ],
    'Iroha generated-HF inactive validator lane serving rejection test'
  );
  requireScopedLiterals(
    soracloudCore,
    'fn select_inrou_replica_placement(',
    '\nfn active_inrou_service_versions(',
    [
      '&capability.validator_account_id != validator_account_id',
      'soracloud_validator_has_active_peer_binding(',
      '&capability.peer_id,',
      'inrou_host_supports_bundle(',
    ],
    'Iroha Inrou placement active-validator admission'
  );
  requireScopedLiterals(
    soracloudCore,
    'fn prune_unavailable_inrou_host_capabilities(',
    '\nfn active_inrou_service_versions(',
    [
      'capability.validate().is_err()',
      'capability.validator_account_id != *validator_account_id',
      'soracloud_validator_has_active_peer_binding(',
      '&capability.peer_id,',
      'state_transaction.is_lane_active_for_authority(lane_id)',
      '!capability.can_host_replicas_at(now_ms)',
      'soracloud_inrou_host_capabilities',
      '.remove(validator_account_id)',
    ],
    'Iroha authoritative unavailable Inrou capability pruning'
  );
  requireScopedLiterals(
    soracloudCore,
    'fn reconcile_inrou_service_placements(',
    '\nfn recompute_hf_placement_total_reservation_fee(',
    [
      'prune_unavailable_inrou_host_capabilities(state_transaction, now_ms);',
      '&capability.validator_account_id == *validator_account_id',
      'soracloud_validator_has_active_peer_binding(',
      '&capability.peer_id,',
      'eligible_validator_count',
    ],
    'Iroha Inrou eligible-validator count admission'
  );
  requireScopedLiterals(
    soracloudCoreTests,
    'fn inrou_peer_rotation_invalidates_stale_capability_and_placement_immediately()',
    '\n#[test]\nfn inrou_reconciliation_prunes_expired_host_capability()',
    [
      '.public_lane_validators',
      'PeerId::from(BOB_ID.expect_single_signatory().clone())',
      'resolve_active_inrou_replica_assignments(',
      'stale placement must stop serving before a reconcile transaction is committed',
      'ReconcileSoracloudInrouPlacements',
      'a capability stale after peer rotation must be pruned',
      'placement.placements.is_empty()',
    ],
    'Iroha immediate stale Inrou peer-rotation invalidation regression'
  );
  requireScopedLiterals(
    soracloudDataModelHosting,
    'pub struct SoraServiceMailboxMessageV1 {',
    '\nimpl SoraServiceMailboxMessageV1 {',
    [
      'pub from_service_version: String,',
      'pub to_service_version: String,',
      'pub delivery_delay_sequences: u32,',
      'pub enqueue_sequence: u64,',
      'pub available_after_sequence: u64,',
      'pub expires_at_sequence: u64,',
      'Ledger execution assigns all three from the',
      'destination handler\'s mailbox contract.',
    ],
    'Iroha ledger-owned mailbox revision and schedule wire contract'
  );
  requireScopedLiterals(
    soracloudDataModelHosting,
    'impl SoraServiceMailboxMessageV1 {',
    '\n/// Exact HF model-host assignment',
    [
      'self.validate_with_sequence_state(true)',
      'self.validate_with_sequence_state(false)',
      'ledger-bound service versions must be empty before ledger submission',
      'ledger-assigned schedule fields must be greater than zero before persistence',
      'ledger-assigned schedule fields must be zero before ledger submission',
      'Hash::new(self.payload_bytes.as_slice()) != self.payload_commitment',
      'must be greater than available_after_sequence',
    ],
    'Iroha disjoint mailbox submission and persisted schedule validation'
  );
  requireScopedLiterals(
    soracloudDataModelTests,
    'fn service_mailbox_message_validation_separates_submission_and_persisted_schedule_states()',
    '\nzero_prehash_field_rejection_test! {\n    service_mailbox_message_validate_rejects_zero_prehash_digest_sentinels,',
    [
      'ledger-assigned mailbox schedule must validate',
      'mailbox submission must not carry a caller-selected schedule',
      'message.from_service_version.clear();',
      'message.to_service_version.clear();',
      'message.enqueue_sequence = 0;',
      'message.available_after_sequence = 0;',
      'message.expires_at_sequence = 0;',
      'zero-sentinel mailbox submission must validate',
    ],
    'Iroha mailbox submission and persistence validation regression'
  );
  const mailboxWriterScope = requireScopedLiterals(
    soracloudCore,
    'pub(crate) fn write_soracloud_mailbox_message(',
    '\npub(crate) fn write_soracloud_runtime_receipt(',
    [
      'message\n        .validate_submission()',
      'has already been recorded',
      'source_deployment.current_service_version',
      'source handler',
      'source_handler.mailbox.is_none()',
      'destination_deployment.current_service_version',
      'destination handler',
      'destination_handler.mailbox.as_ref()',
      'payload_len > destination_mailbox.max_message_bytes.get()',
      'message.delivery_delay_sequences >= retention_sequences',
      'message.from_service_version = source_deployment.current_service_version;',
      'message.to_service_version = destination_deployment.current_service_version;',
      'message.enqueue_sequence = next_soracloud_audit_sequence(state_transaction)?;',
      '.checked_add(u64::from(message.delivery_delay_sequences))',
      '.checked_add(u64::from(retention_sequences))',
      'receipt.mailbox_message_id == Some(**message_id)',
      'pending_count >= max_pending_messages',
      'message\n        .validate()',
      'ensure_soracloud_sequence_is_next(state_transaction, message.enqueue_sequence)?;',
      'soracloud_mailbox_messages\n        .insert(message.message_id, message);',
    ],
    'Iroha contextual ledger-owned mailbox admission'
  );
  requireOrdered(
    mailboxWriterScope,
    'message.delivery_delay_sequences >= retention_sequences',
    'message.enqueue_sequence = next_soracloud_audit_sequence(state_transaction)?;',
    'Iroha mailbox handler, payload, and delay checks before schedule allocation'
  );
  requireOrdered(
    mailboxWriterScope,
    'message.enqueue_sequence = next_soracloud_audit_sequence(state_transaction)?;',
    'ensure_soracloud_sequence_is_next(state_transaction, message.enqueue_sequence)?;',
    'Iroha mailbox ledger assignment before global sequence collision guard'
  );
  requireOrdered(
    mailboxWriterScope,
    'ensure_soracloud_sequence_is_next(state_transaction, message.enqueue_sequence)?;',
    'soracloud_mailbox_messages\n        .insert(message.message_id, message);',
    'Iroha mailbox collision guard before persistence'
  );
  const runtimeReceiptWriterScope = requireScopedLiterals(
    soracloudCore,
    'pub(crate) fn write_soracloud_runtime_receipt(',
    '\npub(crate) fn write_soracloud_private_uploaded_model_execution_receipt(',
    [
      'receipt\n        .validate_submission()',
      'receipt.mailbox_message_id.is_none()',
      'derive_soracloud_local_read_receipt_id_v1(&receipt)',
      'receipt.receipt_id != expected_receipt_id',
      'canonical sequence-independent local-read receipt ID',
      'has already been recorded',
      'let revision_is_active =',
      'references inactive service revision',
      'let bundle = load_admitted_bundle(',
      '.find(|handler| handler.handler_name == receipt.handler_name)',
      'handler.class != receipt.handler_class',
      'handler.certified_response != receipt.certified_by',
      'message.to_service_version != receipt.service_version',
      'message.to_handler != receipt.handler_name',
      'message.payload_commitment != receipt.request_commitment',
      'existing.mailbox_message_id == Some(message_id)',
      'has already been consumed',
      'SoraRuntimeExecutionHostV1::HfModelHost(host)',
      'resolve_generated_hf_active_placement(',
      'soracloud_hf_placement_assignment_has_active_capability(',
      'receipt.emitted_sequence = next_soracloud_audit_sequence(state_transaction)?;',
      'receipt\n        .validate()',
      'ensure_soracloud_sequence_is_next(state_transaction, receipt.emitted_sequence)?;',
      'soracloud_service_runtime',
      'soracloud_runtime_receipts',
    ],
    'Iroha contextually validated ledger-owned runtime receipt writer'
  );
  rejectLiterals(
    runtimeReceiptWriterScope,
    ['SoraRuntimeExecutionHostV1::Inrou' + 'Replica', 'resolve_active_inrou_replica_assignment('],
    'Iroha runtime receipt writer excludes impossible handlerless Inrou attribution'
  );
  requireOrdered(
    runtimeReceiptWriterScope,
    'receipt\n        .validate_submission()',
    'receipt.emitted_sequence = next_soracloud_audit_sequence(state_transaction)?;',
    'Iroha runtime receipt structural submission validation before allocation'
  );
  requireOrdered(
    runtimeReceiptWriterScope,
    'has already been consumed',
    'receipt.emitted_sequence = next_soracloud_audit_sequence(state_transaction)?;',
    'Iroha mailbox exactly-once and contextual receipt checks before sequence allocation'
  );
  requireOrdered(
    runtimeReceiptWriterScope,
    'receipt.emitted_sequence = next_soracloud_audit_sequence(state_transaction)?;',
    'ensure_soracloud_sequence_is_next(state_transaction, receipt.emitted_sequence)?;',
    'Iroha runtime receipt sequence allocation before collision guard'
  );
  requireOrdered(
    runtimeReceiptWriterScope,
    'ensure_soracloud_sequence_is_next(state_transaction, receipt.emitted_sequence)?;',
    '.insert(',
    'Iroha runtime receipt collision guard before authoritative writes'
  );
  requireScopedLiterals(
    soracloudStateRestore,
    'let uploaded_model_bundles = self.uploaded_model_bundles.view();',
    '\n        let service_deployments = self.service_deployments.view();',
    [
      'bundle.validate()',
      'bundle.service_name.as_ref().to_owned()',
      'bundle.model_id.clone()',
      'bundle.weight_version.clone()',
      'storage key must match embedded service_name, model_id, and weight_version',
    ],
    'Iroha uploaded-model bundle restore key and structure binding'
  );
  const restoredMailboxScope = requireScopedLiterals(
    soracloudStateRestore,
    'let mailbox_messages = self.mailbox_messages.view();',
    '\n        let mut consumed_mailbox_messages = std::collections::BTreeSet::new();',
    [
      'key != &message.message_id',
      'message.from_service_version.clone()',
      'source handler must exist in the bound admitted service revision',
      'source handler must be an update/private_update mailbox handler',
      'message.to_service_version.clone()',
      'destination handler must exist in the bound admitted service revision',
      'destination handler must carry an admitted mailbox contract',
      'destination handler must be update/private_update',
      'payload_len > destination_mailbox.max_message_bytes.get()',
      'message.delivery_delay_sequences >= retention_sequences',
      '.checked_add(u64::from(message.delivery_delay_sequences))',
      '.checked_add(u64::from(retention_sequences))',
      'ledger schedule must be exactly derived from enqueue, delay, and destination retention',
    ],
    'Iroha fail-closed contextual mailbox restore validation'
  );
  requireOrdered(
    restoredMailboxScope,
    'register_soracloud_sequence(',
    'let source_bundle = service_revisions',
    'Iroha restored mailbox global sequence registration before contextual validation'
  );
  const restoredRuntimeReceiptScope = requireScopedLiterals(
    soracloudStateRestore,
    'let mut consumed_mailbox_messages = std::collections::BTreeSet::new();',
    '\n        for (key, receipt) in self.private_uploaded_model_execution_receipts.view().iter() {',
    [
      'key != &receipt.receipt_id',
      'receipt service revision must exist in admitted Soracloud state',
      'receipt handler must exist in the bound admitted service revision',
      'receipt_handler.class != receipt.handler_class',
      'receipt_handler.certified_response != receipt.certified_by',
      'soracloud_hf_generated_source_binding(receipt_bundle)',
      'SoraRuntimeExecutionHostV1::HfModelHost(_)',
      'HF-generated receipts and only those receipts must carry HF model-host attribution',
      'Executor eligibility was proven by the consensus Apply instruction.',
      'Do not',
      're-resolve it against mutable current validator topology here',
      'SoraRuntimeExecutionHostV1::DeterministicValidator(_)',
      'mailbox receipts must carry deterministic-validator execution_host attribution',
      'ordered_mailbox_runtime_receipt_id(receipt)',
      'canonical sequence-independent ordered-mailbox receipt ID',
      'message.to_service_version != receipt.service_version',
      'message.to_handler != receipt.handler_name',
      'message.payload_commitment != receipt.request_commitment',
      'receipt.emitted_sequence < message.available_after_sequence',
      'receipt.emitted_sequence >= message.expires_at_sequence',
      'consumed_mailbox_messages.insert(message_id)',
      'one mailbox message must not be consumed by multiple receipts',
      '} else {',
      'deterministic-validator attribution requires an authoritative mailbox message',
      'derive_soracloud_local_read_receipt_id_v1(',
      'canonical sequence-independent local-read receipt ID',
    ],
    'Iroha fail-closed contextual runtime-receipt restore validation'
  );
  rejectLiterals(
    restoredRuntimeReceiptScope,
    ['resolve_ordered_mailbox_executor(', 'public_lane_validators'],
    'Iroha historical mailbox restore independence from mutable validator topology'
  );
  requireOrdered(
    restoredRuntimeReceiptScope,
    'register_soracloud_sequence(',
    'let receipt_bundle = service_revisions',
    'Iroha restored runtime-receipt sequence registration before contextual validation'
  );
  requireScopedLiterals(
    soracloudStateTests,
    'state_test! { sync mailbox_and_receipt_restore_require_exact_ledger_context',
    '\nfn sample_snapshot_app_infra_state()',
    [
      'exact ledger-derived mailbox and receipt context must restore',
      'historical receipt attribution must survive later validator exit',
      'historical receipt attribution must survive later validator peer rotation',
      'mailbox receipt restore must require deterministic-validator attribution',
      'mailbox receipt restore must recompute its canonical receipt ID',
      'changing an execution host without its bound receipt ID must be rejected',
      'a recomputed receipt ID must not mask structurally invalid host attribution',
      'derived from the validator account',
      'deterministic-validator attribution must not restore without mailbox context',
      'one mailbox message must not restore as consumed twice',
      'canonical sequence-independent local-read receipt must restore',
      'local-read immutable content substitution must invalidate its receipt id',
      'canonical sequence-independent local-read',
    ],
    'Iroha canonical ordered-mailbox receipt restore regression'
  );
  requireScopedLiterals(
    soracloudStateRestore,
    'for (key, receipt) in self.private_uploaded_model_execution_receipts.view().iter() {',
    '\n        Ok(())',
    [
      'key != &receipt.receipt_id',
      'private receipt must reference an authoritative uploaded-model bundle',
      'bundle.sorafs_manifest_digest != receipt.model_manifest_digest',
      'bundle.bundle_root != receipt.model_bundle_root',
      'bundle.decryption_policy_ref != receipt.policy_id',
      'private receipt must exactly match its uploaded-model bundle and policy',
    ],
    'Iroha fail-closed private uploaded-model receipt restore validation'
  );
  requireScopedLiterals(
    soracloudDataModelHosting,
    'pub enum SoraRuntimeExecutionHostV1 {',
    '\n/// Authoritative execution receipt emitted by the generic Soracloud runtime.',
    [
      'DeterministicValidator(SoraRuntimeDeterministicValidatorHostV1)',
      'HfModelHost(SoraRuntimeHfModelHostV1)',
      'pub fn validate(&self)',
    ],
    'Iroha typed runtime execution-host attribution'
  );
  const runtimeExecutionHostScope = requireScopedLiterals(
    soracloudDataModelHosting,
    'pub enum SoraRuntimeExecutionHostV1 {',
    '\n/// Authoritative execution receipt emitted by the generic Soracloud runtime.',
    ['DeterministicValidator(', 'HfModelHost('],
    'Iroha first-release runtime receipt host enum'
  );
  rejectLiterals(
    runtimeExecutionHostScope,
    ['Inrou' + 'Replica', 'SoraRuntimeInrou' + 'ReplicaHostV1'],
    'Iroha first-release runtime receipt host enum excludes impossible Inrou attribution'
  );
  requireScopedLiterals(
    soracloudDataModelSchema,
    'fn validate_validator_account_peer_id(',
    '\nfn validate_optional_nonempty(',
    [
      'validate_peer_id_field(manifest, peer_id)',
      'validator_account_id.try_signatory()',
      'PeerId::from(signatory.clone()).to_string() != peer_id',
      "peer must be derived from the validator account's single signatory",
    ],
    'Iroha shared topology-independent validator account/peer identity contract'
  );
  requireScopedLiterals(
    soracloudDataModel,
    'pub fn derive_hf_placement_id_v1(',
    '\n/// Derive the canonical shared-lease pool identifier',
    [
      '"soracloud:hf-placement-id:v1"',
      'pool_id',
      'selection_seed_hash',
      'Hash::new(payload)',
    ],
    'Iroha canonical HF placement identity derivation'
  );
  requireScopedLiterals(
    soracloudDataModel,
    'pub fn derive_hf_shared_lease_pool_id_v1(',
    '\n/// Schema version for',
    [
      '"soracloud:hf-shared-lease-pool-id:v1"',
      'source_id',
      'storage_class',
      'lease_term_ms',
      'Hash::new(payload)',
    ],
    'Iroha canonical HF shared-lease pool identity derivation'
  );
  requireScopedLiterals(
    soracloudDataModelHosting,
    'impl SoraHfPlacementRecordV1 {',
    '\n/// Canonical Soracloud model-host violation kinds.',
    [
      'derive_hf_placement_id_v1(self.pool_id, self.selection_seed_hash)?',
      'self.placement_id != expected_placement_id',
      'must be canonically derived from pool_id and selection_seed_hash',
    ],
    'Iroha HF placement record canonical identity validation'
  );
  requireScopedLiterals(
    soracloudDataModelHosting,
    'impl SoraModelHostCapabilityRecordV1 {',
    '\n/// Active opt-in validator host capability advert for authoritative Inrou placement.',
    [
      'validate_validator_account_peer_id(',
      '"sora model host capability record"',
      '&self.validator_account_id',
      '&self.peer_id',
    ],
    'Iroha durable HF model-host capability account/peer identity contract'
  );
  requireScopedLiterals(
    soracloudDataModelHosting,
    'impl SoraHfPlacementHostAssignmentV1 {',
    '\n/// Authoritative placement record attached to the active HF lease window.',
    [
      'validate_validator_account_peer_id(',
      '"sora hf placement host assignment"',
      '&self.validator_account_id',
      '&self.peer_id',
    ],
    'Iroha durable HF placement account/peer identity contract'
  );
  requireScopedLiterals(
    soracloudDataModelHosting,
    'impl SoraRuntimeExecutionHostV1 {',
    '\n/// Authoritative execution receipt emitted by the generic Soracloud runtime.',
    [
      'Self::DeterministicValidator(host)',
      'validate_validator_account_peer_id(',
      '"sora runtime execution host"',
      '&host.validator_account_id',
      '&host.peer_id',
    ],
    'Iroha structurally canonical deterministic mailbox host attribution'
  );
  requireScopedLiterals(
    soracloudDataModelHosting,
    'impl SoraRuntimeExecutionHostV1 {',
    '\n/// Authoritative execution receipt emitted by the generic Soracloud runtime.',
    [
      'Self::HfModelHost(host)',
      'validate_validator_account_peer_id(',
      '"sora runtime execution host"',
      '&host.validator_account_id',
      '&host.peer_id',
    ],
    'Iroha structurally canonical HF runtime receipt host attribution'
  );
  requireScopedLiterals(
    soracloudDataModelHosting,
    'impl SoraInrouHostCapabilityRecordV1 {',
    '\n/// Authoritative host assignment for one placed Inrou replica slot.',
    [
      'validate_validator_account_peer_id(',
      '"sora inrou host capability record"',
      '&self.validator_account_id',
      '&self.peer_id',
    ],
    'Iroha durable Inrou capability account/peer identity contract'
  );
  requireScopedLiterals(
    soracloudDataModelHosting,
    'impl SoraInrouReplicaPlacementV1 {',
    '\n/// Authoritative per-revision placement record for hosted Inrou replicas.',
    [
      'validate_validator_account_peer_id(',
      '"sora inrou replica placement"',
      '&self.validator_account_id',
      '&self.peer_id',
    ],
    'Iroha durable Inrou placement account/peer identity contract'
  );
  requireScopedLiterals(
    soracloudDataModelHosting,
    'impl SoraInrouReplicaRuntimeStateV1 {',
    '\n/// Ordered asynchronous mailbox message used for replicated cross-service calls.',
    [
      'validate_validator_account_peer_id(',
      '"sora inrou replica runtime state"',
      '&self.validator_account_id',
      '&self.peer_id',
    ],
    'Iroha durable Inrou runtime account/peer identity contract'
  );
  requireScopedLiterals(
    soracloudCoreRuntime,
    'pub fn soracloud_validator_is_active(',
    '\n/// Return whether an account has one exact active validator record bound to its canonical peer.',
    [
      'validator_account_id.try_signatory()',
      'let canonical_peer_id = PeerId::from(signatory.clone());',
      'record.peer_id == canonical_peer_id',
      'record.status == PublicLaneValidatorStatus::Active',
      'lane_is_active_for_authority(key.0)',
    ],
    'Iroha active HF validator lifecycle gate requires canonical account-derived peer identity'
  );
  requireScopedLiterals(
    soracloudCore,
    'fn require_hf_model_host_peer_binding(',
    '\nfn require_soracloud_runtime_authority(',
    [
      'soracloud_validator_has_active_peer_binding(',
      'HF model host capability peer_id must be derived from the validator account',
    ],
    'Iroha live HF model-host exact active peer binding gate'
  );
  requireScopedLiterals(
    soracloudCore,
    'impl Execute for isi::AdvertiseSoracloudModelHost {',
    '\nimpl Execute for isi::HeartbeatSoracloudModelHost {',
    [
      'capability.validator_account_id != *authority',
      'capability\n            .validate()',
      'require_hf_model_host_peer_binding(authority, &capability.peer_id, state_transaction)?;',
      'record_model_host_capability(state_transaction, capability.clone())?;',
    ],
    'Iroha HF model-host advert authority and peer-binding admission'
  );
  const recordRuntimeReceiptScope = requireScopedLiterals(
    soracloudCore,
    'impl Execute for isi::RecordSoracloudRuntimeReceipt {',
    '\nimpl Execute for isi::RecordSoracloudPrivateUploadedModelExecutionReceipt {',
    [
      'self.receipt.mailbox_message_id.is_some()',
      'ordered-mailbox runtime receipts must use ApplySoracloudOrderedMailboxResult',
      'require_active_public_lane_validator(authority, state_transaction)?;',
      'must carry exact execution_host attribution',
      'execution_host.validator_account_id() != authority',
      'must identify submitting validator',
      'SoraRuntimeExecutionHostV1::HfModelHost(host)',
      'resolve_generated_hf_active_placement(',
      'SoraRuntimeExecutionHostV1::DeterministicValidator(_)',
      'deterministic mailbox receipts must use ApplySoracloudOrderedMailboxResult',
      'write_soracloud_runtime_receipt(state_transaction, self.receipt)',
    ],
    'Iroha exact HF runtime receipt attribution and deterministic-mailbox separation'
  );
  rejectLiterals(
    recordRuntimeReceiptScope,
    ['SoraRuntimeExecutionHostV1::Inrou' + 'Replica', 'require_soracloud_service_runtime_authority('],
    'Iroha generic receipt instruction excludes impossible handlerless Inrou attribution'
  );
  requireOrdered(
    recordRuntimeReceiptScope,
    'self.receipt.mailbox_message_id.is_some()',
    'require_soracloud_permission(authority, state_transaction).is_err()',
    'Iroha ordered-mailbox receipt rejection before manager permission bypass'
  );
  requireScopedLiterals(
    soracloudDataModelTests,
    'fn runtime_receipt_validate_rejects_invalid_host_attribution()',
    '\nzero_prehash_field_rejection_test! {\n    runtime_receipt_validate_rejects_zero_prehash_digest_sentinels,',
    [
      'SoraRuntimeExecutionHostV1::HfModelHost(',
      'peer_id: " ".to_owned()',
      'invalid host attribution must be rejected',
      'assert_soracloud_invalid_field(error, "peer_id")',
    ],
    'Iroha typed runtime execution-host structural regression'
  );
  requireScopedLiterals(
    soracloudDataModelTests,
    'fn deterministic_validator_host_requires_canonical_account_peer_binding()',
    '\nzero_prehash_field_rejection_test! {\n    runtime_receipt_validate_rejects_zero_prehash_digest_sentinels,',
    [
      'validator_account_id: sample_account_id(171)',
      'peer_id: sample_peer_id(171)',
      'host.peer_id = sample_peer_id(172)',
      'a syntactically valid peer from another account must be rejected',
      'assert_soracloud_invalid_field(error, "peer_id")',
    ],
    'Iroha deterministic mailbox host canonical-identity regression'
  );
  requireScopedLiterals(
    soracloudDataModelTests,
    'fn hf_model_host_receipt_requires_canonical_account_peer_binding()',
    '\nzero_prehash_field_rejection_test! {\n    runtime_receipt_validate_rejects_zero_prehash_digest_sentinels,',
    [
      'SoraRuntimeExecutionHostV1::HfModelHost(',
      'host.peer_id = sample_peer_id(172)',
      'an HF receipt peer belonging to another account must fail',
      'assert_soracloud_invalid_field(error, "peer_id")',
    ],
    'Iroha HF runtime receipt host canonical-identity regression'
  );
  requireScopedLiterals(
    soracloudDataModelTests,
    'fn model_host_capability_record_rejects_peer_from_another_account()',
    '\n#[test]\nfn hf_placement_host_assignment_rejects_peer_from_another_account()',
    [
      'capability.peer_id = sample_peer_id(0xC4)',
      'an HF host peer belonging to another account must fail',
      'assert_soracloud_invalid_field(error, "peer_id")',
    ],
    'Iroha HF model-host capability wrong-account peer regression'
  );
  requireScopedLiterals(
    soracloudDataModelTests,
    'fn hf_placement_host_assignment_rejects_peer_from_another_account()',
    '\n#[test]\nfn inrou_host_capability_record_validate_rejects_zero_capacity()',
    [
      'placement.assigned_hosts[0].peer_id = sample_peer_id(0xC4)',
      'an HF placement peer belonging to another account must fail',
      'assert_soracloud_invalid_field(error, "peer_id")',
    ],
    'Iroha HF placement wrong-account peer regression'
  );
  requireScopedLiterals(
    soracloudDataModelTests,
    'fn inrou_host_capability_record_rejects_peer_from_another_account()',
    '\n#[test]\nfn inrou_service_placement_record_validate_rejects_duplicate_slots()',
    [
      'capability.peer_id = sample_peer_id(0xD2)',
      'a canonical peer belonging to another account must fail',
      'mismatched account/peer attribution must never remain placement-eligible',
    ],
    'Iroha Inrou capability wrong-account peer regression'
  );
  requireScopedLiterals(
    soracloudDataModelTests,
    'fn inrou_service_placement_record_rejects_peer_from_another_account()',
    '\n#[test]\nfn inrou_replica_runtime_state_validate_rejects_missing_peer_id()',
    [
      'placement.placements[0].peer_id = sample_peer_id(0xD2)',
      'a placed peer belonging to another validator account must fail',
      'assert_soracloud_invalid_field(error, "peer_id")',
    ],
    'Iroha Inrou placement wrong-account peer regression'
  );
  requireScopedLiterals(
    soracloudDataModelTests,
    'fn inrou_replica_runtime_state_rejects_peer_from_another_account()',
    '\n#[test]\nfn runtime_receipt_validate_rejects_invalid_host_attribution()',
    [
      'runtime_state.peer_id = sample_peer_id(0xD2)',
      'an Inrou runtime peer belonging to another account must fail',
      'assert_soracloud_invalid_field(error, "peer_id")',
    ],
    'Iroha Inrou runtime wrong-account peer regression'
  );
  requireScopedLiterals(
    soracloudDataModelHosting,
    'pub struct SoraOrderedMailboxResultV1 {',
    '\nimpl SoraOrderedMailboxResultV1 {',
    [
      'pub observed_height: u64,',
      'pub observed_block_hash: Option<Hash>,',
      'pub observed_sequence: u64,',
      'pub state_mutations: Vec<SoraOrderedMailboxStateMutationV1>,',
      'pub outbound_mailbox_messages: Vec<SoraServiceMailboxMessageV1>,',
      'pub response_commitment: Hash,',
      'pub runtime_execution_commitment: Hash,',
      'pub observed_runtime_state: Option<SoraServiceRuntimeStateV1>,',
      'pub runtime_state: Option<SoraServiceRuntimeStateV1>,',
      'pub runtime_receipt: SoraRuntimeReceiptV1,',
    ],
    'Iroha first-release atomic ordered-mailbox result envelope'
  );
  requireScopedLiterals(
    soracloudDataModelHosting,
    'impl SoraOrderedMailboxResultV1 {',
    '\n/// Authoritative execution receipt emitted by the generic Soracloud runtime.',
    [
      'self.runtime_receipt.validate_submission()?;',
      'self.runtime_receipt.mailbox_message_id.is_none()',
      'must identify the consumed mailbox message',
      'Some(SoraRuntimeExecutionHostV1::DeterministicValidator(_))',
      'must carry deterministic-validator attribution',
    ],
    'Iroha ordered-mailbox submission requires consumption and deterministic-validator attribution'
  );
  requireScopedLiterals(
    soracloudDataModelFixtureTests,
    'fn canonical_deployment_and_hosting_json_graph_rejects_unknown_fields()',
    '\n#[cfg(feature = "json")]\n#[test]\nfn canonical_deployment_and_hosting_json_graph_requires_explicit_keys()',
    [
      'SoraOrderedMailboxStateMutationV1,',
      '"ordered mailbox state mutation"',
      'assert_unknown_rejected!(SoraOrderedMailboxResultV1, "ordered mailbox result");',
    ],
    'Iroha ordered-mailbox wire graph rejects unknown fields'
  );
  requireScopedLiterals(
    soracloudDataModelIsi,
    'pub struct ApplySoracloudOrderedMailboxResult {',
    '\nimpl crate::seal::Instruction for ApplySoracloudOrderedMailboxResult',
    ['pub result: SoraOrderedMailboxResultV1,'],
    'Iroha first-release ordered-mailbox atomic result instruction'
  );
  requireScopedLiterals(
    soracloudCoreRuntime,
    'pub fn resolve_ordered_mailbox_executor(',
    '\n/// Compute the canonical commitment to every authoritative effect',
    [
      'public_lane_validator_record_matches_key(key, record)',
      'record.status != PublicLaneValidatorStatus::Active',
      'lane_is_active_for_authority(key.0)',
      'key.1.try_signatory()',
      'PeerId::from(signatory.clone())',
      'record.peer_id != canonical_peer_id',
      'message_id: message.message_id,',
      'enqueue_sequence: message.enqueue_sequence,',
      'destination: OrderedMailboxDestinationFingerprintV1 {',
      'host: host.clone(),',
      '.max_by(|(left_score, left), (right_score, right)|',
    ],
    'Iroha deterministic lane-aware ordered-mailbox executor resolver'
  );
  requireScopedLiterals(
    soracloudCoreRuntime,
    'fn ordered_mailbox_executor_requires_the_exact_canonical_active_validator_record()',
    '\n    #[test]\n    fn latest_and_authoritative_sequences_track_cross_domain_events_and_saturate()',
    [
      'canonical active validator must be selected',
      'noncanonical_record.peer_id = checked_peer_id()',
      "an active record rebound away from the account's canonical peer must be ineligible",
    ],
    'Iroha canonical ordered-mailbox executor regression'
  );
  requireScopedLiterals(
    soracloudCoreRuntime,
    'pub fn ordered_mailbox_runtime_receipt_id(',
    '\n/// Validate the exact authoritative lease-volume economics',
    [
      'let message_id = receipt.mailbox_message_id?;',
      '"soracloud:ordered-mailbox-receipt:v1"',
      'receipt.service_name.as_ref()',
      'receipt.service_version.as_str()',
      'receipt.handler_name.as_ref()',
      'receipt.result_commitment',
      'receipt.execution_host.clone()',
      'ordered_mailbox_runtime_receipt_id(&result.runtime_receipt)',
    ],
    'Iroha canonical sequence-independent ordered-mailbox receipt identifier'
  );
  const orderedMailboxApplyScope = requireScopedLiterals(
    soracloudCore,
    'impl Execute for isi::ApplySoracloudOrderedMailboxResult {',
    '\nimpl Execute for isi::RecordSoracloudRuntimeReceipt {',
    [
      'validate_submission()',
      'resolve_ordered_mailbox_executor(',
      'is not the selected executor for mailbox message',
      'Some(SoraRuntimeExecutionHostV1::DeterministicValidator(attributed_host))',
      'result.observed_height != observed_height',
      'result.observed_sequence != current_sequence',
      'current_sequence < message.available_after_sequence',
      'current_sequence >= message.expires_at_sequence',
      'existing.mailbox_message_id == Some(message_id)',
      'has already been consumed',
      'result.observed_runtime_state != observed_runtime_state',
      'deployment.current_service_version != message.to_service_version',
      'bundle.service.execution_plane != SoraServiceExecutionPlaneV1::DeterministicService',
      'bundle.container.runtime != iroha_data_model::soracloud::SoraContainerRuntimeV1::Ivm',
      'SoraServiceHandlerClassV1::Update | SoraServiceHandlerClassV1::PrivateUpdate',
      'handler.mailbox.is_none()',
      'ordered mailbox execution cannot bypass governed FHE input-admission proofs',
      'outbound.from_service != receipt.service_name',
      'outbound.from_handler != receipt.handler_name',
      'runtime_state.active_service_version != receipt.service_version',
      'runtime_state.materialized_bundle_hash != bundle.container.bundle_hash',
      'ordered_mailbox_result_commitment(&result)',
      'does not bind its exact atomic effects',
      'ordered_mailbox_receipt_id(&result)',
      'write_soracloud_runtime_receipt(state_transaction, receipt.clone())?;',
      'for mutation in result.state_mutations',
      'for outbound in result.outbound_mailbox_messages',
      'if let Some(mut runtime_state) = result.runtime_state',
    ],
    'Iroha selected-executor OCC-checked atomic ordered-mailbox application'
  );
  requireOrdered(
    orderedMailboxApplyScope,
    'write_soracloud_runtime_receipt(state_transaction, receipt.clone())?;',
    'for mutation in result.state_mutations',
    'Iroha ordered-mailbox consuming receipt before atomic effects'
  );
  requireOrdered(
    orderedMailboxApplyScope,
    'for mutation in result.state_mutations',
    'for outbound in result.outbound_mailbox_messages',
    'Iroha ordered-mailbox state effects before outbound effects'
  );
  requireScopedLiterals(
    soracloudCoreTests,
    'fn ordered_mailbox_result_is_authorized_occ_checked_and_applied_atomically()',
    '\n#[test]\nfn soracloud_app_infra_mutation_preconditions_are_signed_atomic_compare_and_set()',
    [
      'even a Soracloud manager must not consume ordered mailbox work via RecordReceipt',
      'must use ApplySoracloudOrderedMailboxResult',
      'the rejected direct receipt must not consume the mailbox message',
      'the rejected direct receipt must not change runtime OCC state',
      'an unselected validator must not submit the result',
      'substituted execution-host identity must fail',
      'stale OCC sequence must fail',
      'effects not bound by the receipt commitment must fail',
      'atomic result must record its receipt',
      'atomic result must persist its declared state effect',
      'a consumed message must be exactly-once',
      'has already been consumed',
    ],
    'Iroha ordered-mailbox authorization, OCC, atomicity, and replay regression'
  );
  requireScopedLiterals(
    soracloudIrohad,
    '/// Execute and submit at most one globally ordered ready mailbox message.',
    '\n    fn desired_runtime_submission_keys(',
    [
      'Execution is deliberately off-consensus.',
      'deployment.current_service_version == message.to_service_version',
      'resolve_ordered_mailbox_executor(',
      'selected_host.validator_account_id != *local_validator_account_id',
      'selected_host.peer_id != local_peer_id',
      'last_ordered_mailbox_submission',
      'ordered_mailbox_result_commitment(&result)',
      'ordered_mailbox_receipt_id(&result)',
      'ApplySoracloudOrderedMailboxResult { result }',
      '/internal/soracloud/runtime/ordered-mailbox-result',
    ],
    'Iroha off-consensus ordered-mailbox worker with canonical atomic submission'
  );
  requireScopedLiterals(
    soracloudIrohad,
    'fn production_worker_submits_one_canonical_result_and_skips_stale_revision_head()',
    '\n    #[test]\n    fn execute_ordered_mailbox_requires_matching_authoritative_runtime_state()',
    [
      'a stale destination revision must not block a later executable message',
      'assert_eq!(submitted.len(), 1);',
      'ordered_mailbox_result_commitment(result)',
      'ordered_mailbox_receipt_id(result)',
      'Some(SoraRuntimeExecutionHostV1::DeterministicValidator(ref host))',
      'the same committed tip must not enqueue duplicate submissions',
    ],
    'Iroha ordered-mailbox worker stale-revision skipping and same-tip dedupe regression'
  );
  requireScopedLiterals(
    soracloudCoreBlock,
    '/// Test-only harness for legacy block-time mailbox execution.',
    '\n    #[cfg(feature = "telemetry")]\n    type MetricsRef',
    [
      'Production replay must not depend on a local Soracloud runtime.',
      '#[cfg(test)]\n    fn execute_soracloud_mailbox_runtime(',
    ],
    'Iroha legacy block-time mailbox execution is test-only'
  );
  const legacyMailboxInvocation = 'execute_soracloud_mailbox_runtime(state_block);';
  const guardedLegacyMailboxInvocation = `#[cfg(test)]\n            ${legacyMailboxInvocation}`;
  const legacyMailboxInvocationCount = soracloudCoreBlock.split(legacyMailboxInvocation).length - 1;
  const guardedLegacyMailboxInvocationCount =
    soracloudCoreBlock.split(guardedLegacyMailboxInvocation).length - 1;
  if (legacyMailboxInvocationCount !== 2 || guardedLegacyMailboxInvocationCount !== legacyMailboxInvocationCount) {
    fail('Iroha legacy block-time mailbox execution must remain cfg(test)-only at every call site');
  }
  requireScopedLiterals(
    soracloudTorii,
    'fn build_authoritative_agent_runtime_receipt_instruction(',
    '\nfn build_authoritative_agent_autonomy_execution_audit_instruction(',
    [
      'RecordSoracloudRuntimeReceipt {',
      'emitted_sequence: 0,',
    ],
    'Iroha Torii runtime receipt zero-sentinel ingress'
  );
  requireScopedLiterals(
    soracloudCoreTests,
    'fn runtime_receipt_sequence_is_ledger_owned_and_cannot_be_poisoned()',
    '\n#[test]\nfn soracloud_app_infra_mutation_preconditions_are_signed_atomic_compare_and_set()',
    [
      'ingress_receipt.receipt_id = derive_soracloud_local_read_receipt_id_v1(&ingress_receipt);',
      'local-read receipt ids must bind their exact immutable contents',
      'canonical sequence-independent local-read receipt ID',
      'for claimed_sequence in [1, expected_sequence.saturating_add(10_000), u64::MAX]',
      'caller-controlled runtime receipt sequences must be rejected',
      'rejected sequence claims must not update runtime state',
      'rejected sequence claims must not advance the authoritative allocator',
      'assert_eq!(persisted_receipt.emitted_sequence, expected_sequence)',
      'a zero-sentinel replay must not replace the assigned receipt',
      'runtime receipt admission must fail when the audit allocator is exhausted',
      'audit exhaustion must fail before runtime-state write-back',
      'runtime receipt admission must not overwrite the terminal audit event',
    ],
    'Iroha ledger-owned runtime receipt sequence adversarial test'
  );
  requireScopedLiterals(
    soracloudCoreInitialFixtureTests,
    'fn service_runtime_mutations_require_exact_validator_placement()',
    '\nfn bundle_provenance(',
    [
      'from_service_version: String::new(),',
      'to_service_version: String::new(),',
      'enqueue_sequence: 0,',
      'available_after_sequence: 0,',
      'expires_at_sequence: 0,',
      'mailbox message persisted with a ledger-assigned schedule',
      'assert!(persisted_mailbox_message.enqueue_sequence > 0);',
      'persisted mailbox schedule must validate',
      'an assigned validator must not replace a recorded mailbox message',
    ],
    'Iroha ledger-assigned mailbox schedule and collision regression'
  );
  requireScopedLiterals(
    soracloudDataModelTests,
    'fn runtime_receipt_validation_separates_submission_and_persisted_sequence_states()',
    '\n#[test]\nfn private_runtime_receipt_validation_separates_submission_and_persisted_sequence_states()',
    [
      'receipt.emitted_sequence = 0;',
      '.validate_submission()',
      'an unassigned runtime receipt is valid for ledger submission',
      'a persisted runtime receipt requires a ledger-assigned sequence',
      'receipt.emitted_sequence = 1;',
      'a submission must not select its authoritative sequence',
      'assert_soracloud_invalid_field(error, "emitted_sequence")',
    ],
    'Iroha disjoint runtime receipt submission/persistence validation test'
  );
  const runtimeReceiptValidationStart = requireExactlyOnce(
    soracloudDataModelHosting,
    'impl SoraRuntimeReceiptV1 {',
    'Iroha runtime receipt two-state validation contract start'
  );
  const runtimeReceiptValidationScope = soracloudDataModelHosting.slice(runtimeReceiptValidationStart);
  for (const literal of [
    'pub fn validate(&self)',
    'self.validate_with_sequence_state(true)',
    'pub fn validate_submission(&self)',
    'self.validate_with_sequence_state(false)',
    'must be zero before ledger submission',
    'must be assigned by the ledger before persistence',
  ]) {
    requireLiteral(runtimeReceiptValidationScope, literal, 'Iroha runtime receipt two-state validation contract');
  }
  requireScopedLiterals(
    soracloudDataModelHosting,
    'pub fn derive_soracloud_local_read_receipt_id_v1(',
    '\nimpl SoraRuntimeReceiptV1 {',
    [
      '"soracloud:local-read-receipt:v1"',
      'receipt.service_name.as_ref()',
      'receipt.service_version.as_str()',
      'receipt.handler_name.as_ref()',
      'receipt.handler_class',
      'receipt.request_commitment',
      'receipt.result_commitment',
      'receipt.certified_by',
      'receipt.execution_host.clone()',
      'receipt.journal_artifact_hash',
      'receipt.checkpoint_artifact_hash',
    ],
    'Iroha canonical sequence-independent local-read receipt identity'
  );
  const localReadReceiptScope = requireScopedLiterals(
    soracloudIrohad,
    'fn local_read_receipt(',
    '\nfn soracloud_runtime_observed_at_ms()',
    [
      'placement_host: Option<&ResolvedHfPlacementExecutionHost>',
      'SoraRuntimeExecutionHostV1::HfModelHost(SoraRuntimeHfModelHostV1 {',
      'placement_id: host.placement_id,',
      'validator_account_id: host.validator_account_id.clone(),',
      'peer_id: host.peer_id.clone(),',
      'emitted_sequence: 0,',
      'execution_host,',
      'receipt.receipt_id = derive_soracloud_local_read_receipt_id_v1(&receipt);',
    ],
    'Iroha node-issued typed local-read host attribution, identity, and submission sentinel'
  );
  if (localReadReceiptScope.includes('observed_height.max(1)')) {
    fail('Iroha node-issued local-read receipt must not claim an authoritative sequence');
  }
  requireScopedLiterals(
    torii,
    'fn validate_generated_hf_proxy_response_authority(',
    '\nasync fn execute_soracloud_local_read_via_proxy(',
    ['receipt.validate_submission()'],
    'Iroha generated-HF proxy validates node-issued submission receipts'
  );
  requireScopedLiterals(
    soracloudIrohad,
    'fn execute_generated_hf_infer_local_read(',
    '\nfn hf_local_runner_maximum_frame_bytes(',
    [
      'if hf_config.local_execution_enabled {',
      'HF_HOST_LOCAL_EXECUTION_DISABLED_REASON_V1',
      'if use_inference_bridge {',
      'HF_REMOTE_BRIDGE_DISABLED_REASON_V1',
      'if HF_HOST_LOCAL_EXECUTION_AVAILABLE_V1 && hf_config.local_execution_enabled',
      'no enabled or explicitly requested runtime backend',
    ],
    'Iroha generated-HF inference fail-closed execution corridors'
  );
  requireScopedLiterals(
    soracloudIrohad,
    'fn execute_local_read_generated_hf_infer_never_executes_imported_model_on_host()',
    '\n    #[test]\n    fn execute_local_read_generated_hf_infer_repeated_calls_never_spawn_host_worker()',
    [
      'generated HF inference must not execute through a host process',
      'SoracloudRuntimeExecutionErrorKind::Unavailable',
      'no enabled or explicitly requested runtime backend',
      'runtime.manager.hf_local_workers.lock().is_empty()',
    ],
    'Iroha generated-HF host-process execution rejection regression'
  );
  requireScopedLiterals(
    soracloudIrohad,
    'fn configured_remote_hf_provider_cannot_bypass_authoritative_execution_receipts()',
    '\n    #[test]\n    fn reconcile_once_prunes_stale_materializations_and_reports_missing_bundle_cache()',
    [
      'the uncertified remote execution corridor must fail closed',
      'configured credentials must not create execution authority',
      'HF_REMOTE_BRIDGE_DISABLED_REASON_V1',
      '.requests',
      '.is_empty()',
      'mutation_sink.submitted_violation_reports().is_empty()',
      'mutation_sink.submitted_model_host_reconciles(), 0',
      'manager.hf_local_workers.lock().is_empty()',
    ],
    'Iroha configured remote-HF provider fail-closed regression'
  );
  requireScopedLiterals(
    soracloudCoreTests,
    'fn soracloud_audit_sequence_exhaustion_fails_service_and_app_mutations_atomically()',
    '\n#[test]\nfn soracloud_app_infra_mutation_preconditions_are_signed_atomic_compare_and_set()',
    [
      'exhausted_audit.sequence = u64::MAX',
      'service deploy must fail when the shared audit sequence is exhausted',
      'app deploy must fail when the shared audit sequence is exhausted',
      'service upgrade must fail when the shared audit sequence is exhausted',
      'app upgrade must fail when the shared audit sequence is exhausted',
      'audit exhaustion must fail before candidate revision admission',
      'audit exhaustion must not overwrite the terminal audit event',
    ],
    'Iroha shared audit sequence failure-atomicity test'
  );
  requireScopedLiterals(
    soracloudCoreTests,
    'fn hf_shared_lease_audit_sequence_exhaustion_fails_before_authoritative_writes()',
    '\n#[test]\nfn leave_hf_shared_lease_last_member_uses_configured_drain_grace()',
    [
      'sequence: u64::MAX',
      'shared-lease join must fail when the audit sequence is exhausted',
      'soracloud_hf_sources.iter().count()',
      'soracloud_hf_shared_lease_pools.iter().count()',
      'soracloud_hf_shared_lease_members.iter().count()',
      'soracloud_hf_placements.iter().count()',
      'audit exhaustion must not overwrite the terminal shared-lease event',
    ],
    'Iroha HF shared-lease audit exhaustion atomicity test'
  );
  requireScopedLiterals(
    soracloudCoreTests,
    'fn soracloud_app_infra_mutation_preconditions_are_signed_atomic_compare_and_set()',
    '\n#[test]\nfn soracloud_service_mutation_preconditions_are_signed_atomic_compare_and_set()',
    [
      'SoraAppInfraMutationPreconditionV1::AppAbsent',
      'SoraAppInfraMutationPreconditionV1::ExactCurrentRevision(',
      'stale app topology precondition must fail',
      'changing a signed app precondition must invalidate provenance',
      'an exact signed app upgrade must not be replayable',
      'two app upgrades from the same snapshot must not both succeed',
      'a fresh condition must not readmit the current app topology',
      'assert_invariant_contains(same_revision_error, "must admit a distinct topology")',
      'revision_count = u32::MAX',
      'revision count exhaustion must not change app state',
      'revision count exhaustion must not append an app audit event',
    ],
    'Iroha signed atomic app topology mutation adversarial test'
  );
  const serviceCasTestScope = requireScopedLiterals(
    soracloudCoreTests,
    'fn soracloud_service_mutation_preconditions_are_signed_atomic_compare_and_set()',
    '\n#[test]\nfn deploy_soracloud_service_rejects_missing_shared_http_service_volume()',
    [
      '"config generation drift"',
      '"secret generation drift"',
      'a concurrent material mutation must stale the observed upgrade state',
      'cannot change route identity',
      'exhausted_deployment.process_generation = u64::MAX',
      'generation exhaustion must fail before the candidate revision is admitted',
      'cannot supersede an active rollout',
    ],
    'Iroha signed atomic service mutation adversarial test'
  );
  requireOrdered(
    serviceCasTestScope,
    'exhausted_deployment.process_generation = u64::MAX',
    'generation exhaustion must fail before the candidate revision is admitted',
    'Iroha generation exhaustion before revision admission test'
  );
  requireScopedLiterals(
    soracloudCoreTests,
    'fn lease_volume_mutation_fails_before_revision_admission()',
    '\n#[test]\nfn service_material_generation_exhaustion_fails_closed()',
    [
      'upgrade_bundle.service.lease_volumes[0].max_total_bytes',
      'a rolling revision must not mutate lease-volume economics',
      'cannot change lease-volume identity or economics',
      'lease-volume mutation must fail before candidate revision admission',
    ],
    'Iroha immutable rolling-revision lease-volume economics adversarial test'
  );
  requireScopedLiterals(
    soracloudCoreTests,
    'fn service_material_generation_exhaustion_fails_closed()',
    '\n#[test]\nfn upgrade_soracloud_service_starts_canary_rollout()',
    [
      'config_generation = u64::MAX',
      'secret_generation = u64::MAX',
      'direct config mutation must reject an exhausted generation',
      'direct secret mutation must reject an exhausted generation',
      'inline upgrade config must reject an exhausted generation',
      'inline upgrade secret must reject an exhausted generation',
      'material generation exhaustion must fail before candidate revision admission',
    ],
    'Iroha service material generation exhaustion adversarial test'
  );
  const ledgerRolloutTestScope = requireScopedLiterals(
    soracloudCoreTests,
    'fn upgrade_soracloud_service_starts_canary_rollout()',
    '\n#[test]\nfn unhealthy_rollout_auto_rolls_back_to_baseline()',
    [
      'isi::DeploySoracloudService {',
      'isi::UpgradeSoracloudService {',
      'assert_eq!(deployment.current_service_version, "1.1.0")',
      'assert_eq!(active_rollout.baseline_version, "1.0.0")',
      'assert_eq!(active_rollout.candidate_version, "1.1.0")',
      'active_inrou_service_versions(deployment)',
    ],
    'Iroha ledger-created rollout invariant test'
  );
  requireOrdered(
    ledgerRolloutTestScope,
    'isi::DeploySoracloudService {',
    'active_inrou_service_versions(deployment)',
    'Iroha ledger-created rollout invariant test'
  );
  requireScopedLiterals(
    soracloudCoreTests,
    'fn unhealthy_rollout_auto_rolls_back_to_baseline()',
    '\n#[test]\nfn rollback_soracloud_service_reuses_admitted_revision()',
    [
      'exhausted_deployment.process_generation = u64::MAX',
      'automatic rollback must fail when process generation is exhausted',
      'failed overflow transition must not persist the attempted health update',
    ],
    'Iroha automatic rollback generation exhaustion test'
  );
  requireScopedLiterals(
    soracloudCoreTests,
    'fn rollback_soracloud_service_reuses_admitted_revision()',
    '\n#[test]\nfn mutate_soracloud_state_records_authoritative_service_state()',
    [
      'exhausted_deployment.process_generation = u64::MAX',
      'explicit rollback must fail when process generation is exhausted',
    ],
    'Iroha explicit rollback generation exhaustion test'
  );
  requireScopedLiterals(
    soracloudCore,
    'fn verify_bundle_provenance(',
    '\nfn verify_app_infra_provenance(',
    [
      'precondition: &SoraServiceMutationPreconditionV1,',
      'encode_bundle_with_materials_provenance_payload(',
      'precondition,',
    ],
    'Iroha ledger bundle signature precondition binding'
  );
  requireScopedLiterals(
    soracloudCore,
    'fn verify_app_infra_provenance(',
    '\nfn verify_rollback_provenance(',
    [
      'precondition: &SoraAppInfraMutationPreconditionV1,',
      'encode_app_infra_provenance_payload(manifest, precondition)',
      'app infra provenance signature verification failed',
    ],
    'Iroha ledger app topology signature precondition binding'
  );

  const toriiSignedBundleScope = requireScopedLiterals(
    soracloudTorii,
    '#[norito(deny_unknown_fields)]\npub(crate) struct SignedBundleRequest {',
    '\n}\n#[derive(Clone, Debug, JsonDeserialize, NoritoDeserialize, NoritoSerialize)]\n#[norito(deny_unknown_fields)]\npub(crate) struct SignedAppInfraRequest',
    [
      'pub precondition: SoraServiceMutationPreconditionV1,',
    ],
    'Iroha Torii signed mutation request precondition'
  );
  if (/#\[norito\(default\)\]\s*pub precondition:/u.test(toriiSignedBundleScope)) {
    fail('Iroha Torii mutation precondition must be mandatory in the first-release request');
  }
  const toriiSignedAppScope = requireScopedLiterals(
    soracloudTorii,
    '#[norito(deny_unknown_fields)]\npub(crate) struct SignedAppInfraRequest {',
    '\n}\n#[derive(Clone, Debug, JsonDeserialize, NoritoDeserialize)]\n#[norito(deny_unknown_fields)]\npub(crate) struct AppInfraStatusQuery',
    ['pub precondition: SoraAppInfraMutationPreconditionV1,'],
    'Iroha Torii signed app topology mutation precondition'
  );
  if (/#\[norito\(default\)\]\s*pub precondition:/u.test(toriiSignedAppScope)) {
    fail('Iroha Torii app topology precondition must be mandatory in the first-release request');
  }
  requireScopedLiterals(
    soracloudTorii,
    'fn verify_bundle_signature(',
    '\nfn verify_app_infra_signature(',
    [
      'encode_bundle_signature_payload(',
      '&request.precondition,',
      'verify_signature_for_signer(',
    ],
    'Iroha Torii signed mutation precondition verification'
  );
  requireScopedLiterals(
    soracloudTorii,
    'fn verify_app_infra_signature(',
    '\nmacro_rules! define_provenance_signature_verifiers',
    [
      'encode_app_infra_provenance_payload(&request.manifest, &request.precondition)',
      'verify_signature_for_signer(',
      'app infra provenance signature verification failed',
    ],
    'Iroha Torii signed app topology precondition verification'
  );
  requireScopedLiterals(
    soracloudTorii,
    'fn app_service_bundle_instruction(',
    '\nfn encode_bundle_signature_payload(',
    [
      'verify_bundle_signature(&request)?;',
      'DeploySoracloudService {',
      'UpgradeSoracloudService {',
      'precondition: request.precondition,',
    ],
    'Iroha Torii app mutation precondition forwarding'
  );
  for (const [handler, nextHandler, instruction] of [
    ['pub(crate) async fn handle_deploy(', '\npub(crate) async fn handle_upgrade(', 'DeploySoracloudService {'],
    ['pub(crate) async fn handle_upgrade(', '\npub(crate) async fn handle_rollback(', 'UpgradeSoracloudService {'],
  ]) {
    requireScopedLiterals(
      soracloudTorii,
      handler,
      nextHandler,
      [
        'verify_bundle_signature(&request)',
        instruction,
        'precondition: request.precondition,',
      ],
      'Iroha Torii direct mutation precondition forwarding'
    );
  }
  for (const [handler, nextHandler, instruction] of [
    [
      'pub(crate) async fn handle_app_deploy(',
      '\npub(crate) async fn handle_app_upgrade(',
      'isi::soracloud::DeploySoracloudAppInfra {',
    ],
    [
      'pub(crate) async fn handle_app_upgrade(',
      '\npub(crate) async fn handle_app_status(',
      'isi::soracloud::UpgradeSoracloudAppInfra {',
    ],
  ]) {
    requireScopedLiterals(
      soracloudTorii,
      handler,
      nextHandler,
      [
        'verify_app_infra_signature(&request)',
        'precondition,',
        instruction,
      ],
      'Iroha Torii app topology mutation precondition forwarding'
    );
  }
  requireOrdered(
    inrouDeploymentScope,
    'preflight_taira_inrou_mutation_target(',
    'register_built_sorafs_manifest(',
    'Iroha Inrou pre-publication mutation flow'
  );

  const inrouConvergenceScope = requireScopedLiterals(
    tairaCli,
    'impl InrouCanaryConvergence {',
    '\nfn validate_exact_inrou_canary_status(',
    [
      'current.process_generation != status.process_generation',
      'self.exact_status = None;',
      'route evidence arrived without exact authoritative status',
      'status.process_generation != evidence.process_generation',
    ],
    'Iroha Inrou generation-scoped convergence state'
  );
  requireAtLeast(
    inrouConvergenceScope,
    'self.identities.clear();',
    2,
    'Iroha Inrou generation-scoped convergence state'
  );
  requireScopedLiterals(
    tairaCli,
    'fn validate_exact_inrou_canary_status(',
    '\nfn exact_inrou_canary_header',
    [
      'revision.get("service_version")',
      'Some(deployment.service_version.as_str())',
      '.get("service_manifest_hash")',
      'Some(deployment.service_manifest_hash.as_str())',
      '.get("container_manifest_hash")',
      'Some(deployment.container_manifest_hash.as_str())',
      '.get("process_generation")',
      '.filter(|generation| *generation > 0)',
      'matching_services.next().is_some()',
    ],
    'Iroha exact Inrou authoritative revision validator'
  );
  requireScopedLiterals(
    tairaCli,
    'fn validate_exact_inrou_canary_route(',
    '\nfn inrou_canary_health_path(',
    [
      'SORACLOUD_SERVED_SERVICE_NAME_HEADER',
      'served_service_name != deployment.service_name.as_str()',
      'SORACLOUD_SERVED_SERVICE_VERSION_HEADER',
      'served_service_version != deployment.service_version.as_str()',
      'SORACLOUD_SERVED_REPLICA_SLOT_HEADER',
      'body_replica_slot != Some(replica_slot)',
      'SORACLOUD_SERVED_PROCESS_GENERATION_HEADER',
      'process_generation != expected_process_generation',
      'SORACLOUD_SERVED_MATERIALIZED_BUNDLE_HASH_HEADER',
      'served_bundle_hash != deployment.bundle_hash.as_str()',
      '"served_process_generation": process_generation',
    ],
    'Iroha Torii-served Inrou route evidence validator'
  );
  requireScopedLiterals(
    tairaCli,
    'fn verify_inrou_canary(',
    '\nfn run_write_canary(',
    [
      'match convergence.observe_status(observed_status)',
      'route probe skipped until exact authoritative status is current',
      'continue;',
      'A full route set only becomes final after a later exact status poll',
      'if convergence.is_complete() {',
      'completion_confirmed = true;',
      'break;',
      'validate_exact_inrou_canary_route(',
      'convergence.record_route(evidence)',
      'let routes_ready = identities.len() == 4 && completion_confirmed;',
      '"post_route_status_confirmed".to_owned()',
    ],
    'Iroha fail-closed Inrou convergence verifier'
  );
  requireOrdered(
    inrouVerifierScope,
    'if convergence.is_complete() {',
    'validate_exact_inrou_canary_route(',
    'Iroha post-route authoritative status confirmation'
  );

  for (const [name, value] of [
    ['SORACLOUD_SERVED_SERVICE_NAME_HEADER', 'x-iroha-soracloud-served-service-name'],
    ['SORACLOUD_SERVED_SERVICE_VERSION_HEADER', 'x-iroha-soracloud-served-service-version'],
    ['SORACLOUD_SERVED_REPLICA_SLOT_HEADER', 'x-iroha-soracloud-served-replica-slot'],
    [
      'SORACLOUD_SERVED_PROCESS_GENERATION_HEADER',
      'x-iroha-soracloud-served-process-generation',
    ],
    [
      'SORACLOUD_SERVED_MATERIALIZED_BUNDLE_HASH_HEADER',
      'x-iroha-soracloud-served-materialized-bundle-hash',
    ],
  ]) {
    requireLiteral(
      toriiShared,
      `pub const ${name}: &str =`,
      `Iroha shared hosted-response header ${name}`
    );
    requireLiteral(toriiShared, `"${value}"`, `Iroha shared hosted-response header ${name}`);
  }
  requireScopedLiterals(
    torii,
    'struct ResolvedHostedHttpTarget {',
    '\n#[cfg(feature = "app_api")]\n#[derive(Clone, Debug)]\nstruct LocalHostedHttpReplicaRuntime',
    ['materialized_bundle_hash: String,', 'process_generation: u64,'],
    'Torii resolved hosted revision identity'
  );
  requireScopedLiterals(
    torii,
    'struct LocalHostedHttpReplicaRuntime {',
    '\n#[cfg(feature = "app_api")]\nfn ensure_matching_hosted_http_materialized_bundle_hash(',
    ['materialized_bundle_hash: String,', 'process_generation: u64,'],
    'Torii local hosted revision identity'
  );
  requireScopedLiterals(
    torii,
    'fn ensure_matching_hosted_http_materialized_bundle_hash(',
    '\n#[cfg(feature = "app_api")]\n#[cfg(any(feature = "p2p_ws", feature = "connect"))]\nfn ensure_local_hosted_http_snapshot_origin(',
    [
      'if admitted_bundle_hash != local_bundle_hash',
      'SoracloudRuntimeExecutionErrorKind::Unavailable',
      'local bundle hash does not match the admitted service revision',
      'if authoritative_process_generation != local_process_generation',
      'local process generation',
      'does not match authoritative generation',
    ],
    'Torii local and authoritative served-revision agreement'
  );
  requireScopedLiterals(
    torii,
    '#[cfg(feature = "app_api")]\n#[cfg(any(feature = "p2p_ws", feature = "connect"))]\nfn ensure_local_hosted_http_snapshot_origin(',
    '\n#[cfg(feature = "app_api")]\n#[cfg(not(any(feature = "p2p_ws", feature = "connect")))]\nfn ensure_local_hosted_http_snapshot_origin(',
    [
      'snapshot.local_peer_id.as_deref().ok_or_else',
      'app.local_peer_id.as_ref().ok_or_else',
      'runtime snapshot has no exact local peer identity',
      'snapshot_peer_id == local_peer_id.to_string()',
    ],
    'Torii exact local runtime snapshot ownership'
  );
  requireScopedLiterals(
    torii,
    '#[cfg(feature = "app_api")]\n#[cfg(not(any(feature = "p2p_ws", feature = "connect")))]\nfn ensure_local_hosted_http_snapshot_origin(',
    '\n#[cfg(feature = "app_api")]\nfn resolve_local_hosted_http_replica_runtime(',
    [
      'SoracloudRuntimeExecutionErrorKind::Unavailable',
      'runtime snapshot identity requires peer connectivity',
    ],
    'Torii no-connect runtime snapshot rejection'
  );
  requireScopedLiterals(
    torii,
    'fn authoritative_weighted_hosted_http_versions(',
    '\n#[cfg(feature = "app_api")]\n#[derive(Clone, Debug)]\nstruct ResolvedHostedHttpTarget',
    [
      'deployment.validate()',
      'if deployment.process_generation == 0',
      'vec![(deployment.current_service_version.clone(), 100)]',
      'rollout.candidate_version != deployment.current_service_version',
      '!(1..=99).contains(&candidate_weight)',
      'let baseline_version = rollout.baseline_version.trim();',
      'baseline_version == rollout.candidate_version',
      '(rollout.candidate_version.clone(), candidate_weight)',
      '(baseline_version.to_owned(), baseline_weight)',
      'configured revision weights must total 100',
      'Ok((versions, deployment.process_generation))',
    ],
    'Torii authoritative hosted process generation'
  );
  requireScopedLiterals(
    torii,
    'fn select_authoritative_hosted_http_replica(',
    '\n#[cfg(feature = "app_api")]\nfn authoritative_weighted_hosted_http_versions(',
    [
      'placements: &[iroha_data_model::soracloud::SoraInrouReplicaPlacementV1]',
      'hosted_http_runtime_state_matches_placement(',
      'admitted_bundle_hash',
      'SoraServiceHealthStatusV1::Healthy',
    ],
    'Torii public hosted target runtime-health binding over canonical assignments'
  );
  requireScopedLiterals(
    torii,
    'fn resolve_local_hosted_http_replica_runtime(',
    '\n#[cfg(feature = "app_api")]\nfn resolve_hosted_http_runtime_target(',
    [
      'plan.process_generation.filter(|value| *value > 0)?',
      'process_generation,',
    ],
    'Torii positive local runtime process generation'
  );
  const publicHostedTargetScope = requireScopedLiterals(
    torii,
    'fn resolve_hosted_http_runtime_target(',
    '\n#[cfg(feature = "app_api")]\nfn resolve_exact_hosted_http_runtime_target(',
    [
      'authoritative_weighted_hosted_http_versions(world, current_sequence, &service_name)',
      'resolve_active_inrou_replica_assignments(',
      'state_view.is_lane_active_for_authority(lane_id)',
      'select_authoritative_hosted_http_replica(',
      '.soracloud_service_revisions()',
      'admitted_bundle_hash',
      'ensure_matching_hosted_http_materialized_bundle_hash(',
      'process_generation,',
    ],
    'Torii authoritative public hosted-target binding'
  );
  if (publicHostedTargetScope.includes('local_healthy_hosted_http_placement')) {
    fail('Torii public hosted targets must not fall back to unauthoritative local runtime state');
  }
  if (torii.includes('fn hosted_http_capability_matches_placement(')) {
    fail('Torii must use the shared Inrou assignment resolver instead of a local capability matcher');
  }
  requireScopedLiterals(
    soracloudTorii,
    'pub(crate) enum PublicRouteMatch {',
    '\n#[derive(Clone, Debug, JsonSerialize, JsonDeserialize)]',
    [
      'LocalRead(LocalReadRouteMatch),',
      'HostedHttp(HostedHttpRouteMatch),',
    ],
    'Torii public route kinds exclude caller-owned mailbox execution'
  );
  const publicMethodScope = requireScopedLiterals(
    soracloudTorii,
    'fn public_method_supports_handler(',
    '\npub(crate) fn resolve_public_route(',
    [
      'request_method.eq_ignore_ascii_case("GET")',
      'request_method.eq_ignore_ascii_case("HEAD")',
      'SoraServiceHandlerClassV1::Asset',
      'SoraServiceHandlerClassV1::Query',
      '} else {\n        false\n    }',
    ],
    'Torii read-only deterministic public method gate'
  );
  if (
    publicMethodScope.includes('SoraServiceHandlerClassV1::Update')
    || publicMethodScope.includes('SoraServiceHandlerClassV1::PrivateUpdate')
  ) {
    fail('Torii public HTTP methods must not admit ledger-only mailbox handlers');
  }
  requireScopedLiterals(
    soracloudTorii,
    'pub(crate) fn resolve_public_route(',
    '\nfn normalize_public_route_host(',
    [
      'SoraServiceHandlerClassV1::Update\n                | iroha_data_model::soracloud::SoraServiceHandlerClassV1::PrivateUpdate => {\n                    continue;',
    ],
    'Torii ledger-only mailbox handler exclusion from public route resolution'
  );
  const publicRuntimeIngressScope = requireScopedLiterals(
    torii,
    'async fn execute_soracloud_public_runtime_request(',
    '\n#[cfg(feature = "app_api")]\nasync fn handler_soracloud_public_local_read(',
    [
      'soracloud::PublicRouteMatch::HostedHttp(route_match)',
      'soracloud::PublicRouteMatch::LocalRead(route_match)',
    ],
    'Torii public ingress limited to hosted HTTP and deterministic reads'
  );
  for (const staleMailboxIngress of [
    'OrderedMailboxRouteMatch',
    'PublicRouteMatch::OrderedMailbox',
    'soracloud_public_ordered_mailbox_request_commitment',
  ]) {
    if (soracloudTorii.includes(staleMailboxIngress) || torii.includes(staleMailboxIngress)) {
      fail(`Torii still exposes retired caller-owned mailbox ingress ${staleMailboxIngress}`);
    }
  }
  if (publicRuntimeIngressScope.includes('execute_ordered_mailbox')) {
    fail('Torii public ingress must not execute ledger mailbox work outside block processing');
  }
  for (const marker of [
    'async fn resolve_public_route_rejects_ledger_only_mailbox_handlers()',
    'update handlers must only execute through ledger-owned mailbox transactions',
    'private-update handlers must only execute through ledger-owned mailbox transactions',
  ]) {
    requireLiteral(
      soracloudTorii,
      marker,
      'Torii ledger-only mailbox public-route rejection tests'
    );
  }
  requireScopedLiterals(
    publicHostedTargetScope,
    '// Select the authoritative rollout bucket before considering health.',
    'let selected = healthy_targets.remove(selected_index);',
    [
      'Moving a request to a',
      'different revision would silently alter the configured rollout percentage.',
      'let bucket = hosted_http_rollout_bucket(',
      'let intended_version_index = weighted_versions',
      'let intended_version = &weighted_versions[intended_version_index].0;',
      'target.route_match.service_version == *intended_version',
      'selected for service `{service_name}` has no healthy replica',
    ],
    'Torii exact rollout-bucket health routing'
  );
  if (publicHostedTargetScope.includes('healthy_targets.len() == 1')) {
    fail('Torii must not implicitly promote the sole healthy canary into baseline traffic');
  }
  const exactHostedTargetScope = requireScopedLiterals(
    torii,
    'fn resolve_exact_hosted_http_runtime_target(',
    '\n#[cfg(feature = "app_api")]\nfn overwrite_soracloud_served_revision_headers(',
    [
      'authoritative_weighted_hosted_http_versions(world, current_sequence, service_name)',
      'runtime_state.health_status',
      'SoraServiceHealthStatusV1::Healthy',
      'has no matching healthy authoritative runtime state',
      'has no matching healthy local runtime',
      'resolve_active_inrou_replica_assignment(',
      'state_view.is_lane_active_for_authority(lane_id)',
      '.soracloud_service_revisions()',
      '&admitted_bundle_hash',
      'has no active matching authoritative host capability or placement',
      'ensure_matching_hosted_http_materialized_bundle_hash(',
      'process_generation,',
    ],
    'Torii exact remote-target authoritative served-revision agreement'
  );
  if (exactHostedTargetScope.includes('(None, Some(runtime))')) {
    fail('Torii exact remote targets must not relabel unauthoritative local runtime state');
  }
  requireScopedLiterals(
    soracloudToriiHostedTests,
    'fn seed_authoritative_hosted_http_revision(',
    '\nfn seed_public_hosted_http_rollout_app(',
    [
      'soracloud_inrou_host_capabilities_mut_for_testing()',
      'heartbeat_expires_at_ms: u64::MAX',
      'supported_guest_isas:',
      'max_hosted_replica_capacity:',
      'max_cpu_millis: u32::MAX',
      'max_memory_bytes: u64::MAX',
      'max_storage_bytes: u64::MAX',
      'soracloud_inrou_service_placements_mut_for_testing()',
      'soracloud_inrou_replica_runtime_mut_for_testing()',
      'selected_guest_isa: placement.selected_guest_isa',
      'materialized_bundle_hash: bundle.container.bundle_hash',
      'reporting_epoch: 1',
    ],
    'Torii hosted rollout authoritative capability fixture'
  );
  requireScopedLiterals(
    soracloudToriiHostedTests,
    'fn seed_public_hosted_http_rollout_app_with_replica_plans_and_snapshot_peer_id(',
    '\nfn hosted_http_rollout_test_ip<',
    [
      'current_service_version: candidate_version.to_owned()',
      'current_service_manifest_hash: candidate_bundle.service_manifest_hash()',
      'current_container_manifest_hash: candidate_bundle.container_manifest_hash()',
      'baseline_version: baseline_version.to_owned()',
      'candidate_version: candidate_version.to_owned()',
      'SoracloudRuntimeRevisionRole::Active',
      'SoracloudRuntimeRevisionRole::CanaryCandidate',
    ],
    'Torii hosted rollout authoritative candidate fixture'
  );
  requireScopedLiterals(
    soracloudToriiHostedTargetTests,
    'async fn resolve_hosted_http_runtime_target_routes_canary_traffic_by_rollout_percent()',
    '\n#[tokio::test]\nasync fn resolve_hosted_http_runtime_target_fails_closed_when_selected_canary_is_unhealthy()',
    [
      '|bucket| bucket < 20',
      'assert_eq!(canary_target.route_match.service_version, "2026.03.0")',
      '|bucket| bucket >= 20',
      'assert_eq!(baseline_target.route_match.service_version, "2026.02.0")',
    ],
    'Torii authoritative canary allocation test'
  );
  requireScopedLiterals(
    soracloudToriiHostedTargetTests,
    'async fn resolve_hosted_http_runtime_target_fails_closed_when_selected_canary_is_unhealthy()',
    '\n#[tokio::test]\nasync fn resolve_hosted_http_runtime_target_never_promotes_canary_when_baseline_is_unhealthy()',
    [
      'SoraServiceHealthStatusV1::Unavailable',
      'an unavailable selected canary must not redistribute traffic to the baseline',
      'authoritative hosted Soracloud revision `2026.03.0`',
      'has no healthy replica',
    ],
    'Torii selected-canary fail-closed test'
  );
  requireScopedLiterals(
    soracloudToriiHostedTargetTests,
    'async fn resolve_hosted_http_runtime_target_never_promotes_canary_when_baseline_is_unhealthy()',
    '\n#[tokio::test]\nasync fn resolve_hosted_http_runtime_target_fails_closed_without_any_healthy_revision()',
    [
      'the candidate may serve only its allocated canary bucket',
      'assert_eq!(candidate_target.route_match.service_version, "2026.03.0")',
      'an unavailable baseline must not implicitly promote the candidate',
      'authoritative hosted Soracloud revision `2026.02.0`',
      'has no healthy replica',
    ],
    'Torii unhealthy-baseline non-promotion test'
  );
  requireScopedLiterals(
    soracloudToriiHostedTargetTests,
    'async fn hosted_http_runtime_target_rejects_missing_or_expired_host_capability()',
    '\n#[tokio::test]\nasync fn hosted_http_runtime_target_rejects_inactive_validator_with_live_capability()',
    [
      'for remove_capability in [true, false]',
      'capabilities.remove(',
      'heartbeat_expires_at_ms = 2',
      'stale host authority must not serve public traffic',
      'no active matching authoritative host capability',
    ],
    'Torii missing and expired hosted capability tests'
  );
  requireScopedLiterals(
    soracloudToriiHostedTargetTests,
    'async fn hosted_http_runtime_target_rejects_inactive_validator_with_live_capability()',
    '\n#[tokio::test]\nasync fn resolve_hosted_http_runtime_target_fails_closed_without_service_lease()',
    [
      'PublicLaneValidatorStatus::Exited',
      'an exited validator must not serve with an unexpired advert',
      'no healthy authoritative',
      'exact execution must also reject an exited validator',
      'no active matching authoritative host capability',
    ],
    'Torii inactive-validator hosted serving rejection test'
  );
  requireScopedLiterals(
    soracloudToriiHostedTargetTests,
    'async fn resolve_hosted_http_runtime_target_fails_closed_without_service_lease()',
    '\n#[tokio::test]\nasync fn resolve_hosted_http_runtime_target_fails_closed_when_service_lease_expires()',
    [
      'Some(hosted_http_service_lease_state(',
      'deployment.service_lease = None;',
      'deployment.lease_volume_states.clear();',
      'missing hosted-service lease must fail closed',
      'lease for service `web_portal` is unavailable',
    ],
    'Torii explicit malformed-state missing hosted lease rejection test'
  );
  requireScopedLiterals(
    soracloudToriiHostedTargetTests,
    'async fn resolve_hosted_http_runtime_target_fails_closed_when_authoritative_runtime_state_lags()',
    '\n#[tokio::test]\nasync fn hosted_http_runtime_target_rejects_matching_forged_runtime_and_local_bundle_hashes()',
    [
      'node-local health must not override unavailable authoritative runtime state',
      'no healthy authoritative',
    ],
    'Torii missing healthy authoritative runtime test'
  );
  requireScopedLiterals(
    soracloudToriiHostedTargetTests,
    'async fn hosted_http_runtime_target_rejects_matching_forged_runtime_and_local_bundle_hashes()',
    '\n#[tokio::test]\nasync fn hosted_http_runtime_target_rejects_unadmitted_bundle_for_remote_replica()',
    [
      'Hash::new(b"unadmitted-authoritative-bundle")',
      'authoritative_state.materialized_bundle_hash = forged_bundle_hash',
      '.bundle_hash = forged_bundle_hash.to_string()',
      'matching forged runtime and local hashes must not bypass the admitted bundle',
      'exact hosted execution must reject an unadmitted runtime bundle',
    ],
    'Torii matching forged local and ledger bundle rejection test'
  );
  requireScopedLiterals(
    soracloudToriiHostedTargetTests,
    'async fn hosted_http_runtime_target_rejects_unadmitted_bundle_for_remote_replica()',
    '\n#[tokio::test]\nasync fn hosted_http_runtime_target_rejects_local_snapshot_bundle_mismatch()',
    [
      'Hash::new(b"unadmitted-remote-inrou-bundle")',
      'remote routing must reject runtime state for an unadmitted artifact',
      'no healthy authoritative',
    ],
    'Torii remote unadmitted bundle rejection test'
  );
  requireScopedLiterals(
    soracloudToriiHostedTargetTests,
    'async fn hosted_http_runtime_target_rejects_local_snapshot_bundle_mismatch()',
    '\n#[tokio::test]\nasync fn hosted_http_runtime_target_rejects_stale_local_process_generation()',
    [
      'Hash::new(b"stale-local-inrou-bundle")',
      'local runtime must materialize the admitted bundle exactly',
      'local bundle hash does not match the admitted service revision',
      'exact local execution must reject a stale materialized bundle',
    ],
    'Torii local admitted bundle snapshot rejection test'
  );
  requireScopedLiterals(
    soracloudToriiHostedTargetTests,
    'async fn hosted_http_runtime_target_rejects_stale_local_process_generation()',
    '\n#[tokio::test]\nasync fn resolve_hosted_http_runtime_target_fails_closed_without_snapshot_replica_targets()',
    [
      '.process_generation = 2',
      'a stale local process generation must not serve public traffic',
      'local process generation 1',
      'authoritative generation 2',
    ],
    'Torii stale local process generation test'
  );
  requireScopedLiterals(
    soracloudToriiHostedTargetTests,
    'async fn resolve_hosted_http_runtime_target_rejects_snapshot_without_peer_identity()',
    '\n#[tokio::test]\nasync fn resolve_hosted_http_runtime_target_rejects_snapshot_from_different_peer()',
    [
      'an originless local runtime snapshot must fail closed',
      'no exact local peer identity',
    ],
    'Torii missing runtime snapshot peer identity test'
  );
  requireScopedLiterals(
    soracloudToriiHostedTargetTests,
    'async fn resolve_hosted_http_runtime_target_rejects_snapshot_from_different_peer()',
    '\n#[tokio::test]\nasync fn hosted_http_proxy_candidate_peers_exclude_local_and_visited()',
    [
      'remote_peer_id',
      'local_peer_id',
      'foreign snapshot origin must fail closed',
    ],
    'Torii mismatched runtime snapshot peer identity test'
  );
  requireScopedLiterals(
    soracloudToriiHostedTargetTests,
    'fn hosted_http_origin_rejects_spoofed_or_duplicate_remote_served_revision_headers()',
    '\nfn sample_generated_hf_infer_request(',
    [
      'guest-provided served-revision headers must not bind a remote response',
      'a stale remote process generation must fail closed',
      'duplicate remote served-revision headers must fail closed',
    ],
    'Torii spoofed and duplicate remote served-revision header test'
  );
  requireScopedLiterals(
    torii,
    'fn soracloud_hosted_http_topology_section(',
    '\n#[cfg(feature = "telemetry")]\nasync fn soracloud_failed_admissions_section(',
    [
      'capability.validate().is_ok()',
      'capability.validator_account_id == *validator_account_id',
      'capability.can_host_replicas_at(now_ms)',
      'soracloud_validator_has_active_peer_binding(',
      '&capability.peer_id,',
      'view.is_lane_active_for_authority(lane_id)',
      'resolve_active_inrou_replica_assignments(',
      'world,',
      'service_name,',
      'service_version,',
    ],
    'Torii hosted topology through the shared Inrou assignment resolver'
  );
  requireScopedLiterals(
    soracloudToriiTopologyTests,
    'fn soracloud_hosted_http_topology_section_excludes_inactive_validator()',
    '\n#[tokio::test]\nasync fn soracloud_runtime_status_sections_report_degraded_for_hydrating_snapshots()',
    [
      'SoraContainerRuntimeV1::Inrou',
      'SoraServiceExecutionPlaneV1::HttpService',
      'NonZeroU16::new(2)',
      'SoraServiceLeaseStatusV1::Active',
      'validate_soracloud_deployment_lease_volume_bindings(',
      'PublicLaneValidatorStatus::Exited',
      'inactive validators must not contribute live topology adverts',
      'inactive validators must not contribute placed hosts',
      'inactive validators must not contribute hosted replicas',
    ],
    'Torii hosted topology inactive-validator exclusion test'
  );
  requireScopedLiterals(
    soracloudIrohad,
    'fn collect_active_versions(',
    '\nfn hydrated_ivm_service_health_status(',
    [
      '!(1..100).contains(&traffic_percent)',
      'rollout.stage != SoraRolloutStageV1::Canary',
      'rollout.candidate_version != deployment.current_service_version',
      'baseline_version == &rollout.candidate_version',
      'baseline_version.clone()',
      'SoracloudRuntimeRevisionRole::Active',
      'rollout.candidate_version.clone()',
      'SoracloudRuntimeRevisionRole::CanaryCandidate',
      'deployment.current_service_version.clone()',
    ],
    'Iroha daemon authoritative active rollout revisions'
  );
  requireScopedLiterals(
    soracloudIrohad,
    'fn inrou_hosting_available_for_reconcile(&self) -> bool {',
    '\n    fn initial_reconcile_baseline(',
    [
      'let available = self.inrou_startup_capability.is_some()',
      'match ensure_inrou_portable_vm_statically_available(&self.config.inrou)',
      'Ok(()) => self.config.inrou.enabled',
      'if !available {',
      'self.withdraw_local_inrou_host_if_needed(&view);',
      'Inrou PortableVM V1 is unavailable; withdrawing host and stopping local replicas',
    ],
    'Iroha daemon production-qualified Inrou hosting eligibility'
  );
  requireScopedLiterals(
    soracloudIrohad,
    'pub(super) fn reconcile_once(&self) -> eyre::Result<()> {',
    '\n    fn submit_http_service_runtime_state_updates(',
    [
      'validate_soracloud_runtime_manager_posture(&self.config)',
      'let inrou_hosting_available = self.inrou_hosting_available_for_reconcile();',
      'self.initial_reconcile_baseline(inrou_hosting_available)?;',
      'self.build_reconciled_snapshot(&bundle_registry, inrou_hosting_available)?;',
      'self.request_hf_lease_window_reconcile_if_needed(hf_lease_window_reconcile_needed);',
      'self.refresh_local_inrou_host_capability_if_needed(inrou_host_capability_refresh);',
      'self.request_inrou_placement_reconcile_if_needed(inrou_placement_reconcile_needed);',
      'self.execute_ready_ordered_mailbox_message()?;',
      'self.prune_stale_hf_local_workers(&view, &snapshot);',
    ],
    'Iroha daemon reconciliation integration and deterministic Inrou hosting seam'
  );
  requireScopedLiterals(
    soracloudIrohad,
    'fn hf_lease_window_reconcile_needed(',
    '\n    fn hf_lease_window_reconcile_attempt_allowed(',
    [
      'pool.window_expires_at_ms <= now_ms',
      'SoraHfSharedLeaseStatusV1::Active | SoraHfSharedLeaseStatusV1::Draining',
    ],
    'Iroha daemon expired HF lease-window detection'
  );
  requireScopedLiterals(
    soracloudIrohad,
    'fn hf_lease_window_reconcile_attempt_allowed(',
    '\n    fn request_hf_lease_window_reconcile_if_needed(',
    [
      'last_hf_lease_window_reconcile_attempt_ms.lock()',
      'HF_LEASE_WINDOW_RECONCILE_REQUEST_COOLDOWN_MS',
      '*last_attempt_ms = Some(now_ms);',
    ],
    'Iroha daemon HF lease-window reconcile retry throttle'
  );
  requireScopedLiterals(
    soracloudIrohad,
    'fn request_hf_lease_window_reconcile_if_needed(',
    '\n    fn build_local_inrou_host_capability_record(',
    [
      'self.hf_lease_window_reconcile_attempt_allowed(now_ms)',
      'InstructionBox::from(isi::soracloud::ReconcileSoracloudModelHosts)',
      '"/internal/soracloud/runtime/hf-lease-window-reconcile"',
    ],
    'Iroha daemon authoritative HF lease-window reconcile submission'
  );
  requireScopedLiterals(
    soracloudIrohad,
    'fn build_local_inrou_host_capability_record(',
    '\n    fn local_inrou_host_advert_attempt_allowed(',
    [
      'validator_account_id.try_signatory()?',
      'PeerId::from(',
      'if peer_id != expected_peer_id',
      'capability.validate().ok()?;',
      'Some(capability)',
    ],
    'Iroha daemon canonical local Inrou peer binding'
  );
  requireScopedLiterals(
    soracloudIrohad,
    'fn inrou_host_refuses_a_noncanonical_local_peer_identity()',
    '\n    #[test]\n    fn disabled_inrou_host_does_not_advertise_or_host()',
    [
      '12D3KooWLegacyAlias',
      '.build_local_inrou_host_capability_record(123)',
      '.is_none()',
      "a local peer alias that is not the validator's canonical public key must fail closed",
    ],
    'Iroha daemon noncanonical local Inrou peer regression'
  );
  requireScopedLiterals(
    soracloudIrohad,
    'fn reconcile_once_requests_authoritative_reconcile_for_every_expired_hf_window()',
    '\n    #[test]\n    fn reconcile_once_projects_hf_source_runtime_readiness_from_bound_services()',
    [
      'for queue_next_window in [false, true]',
      'insert_expired_hf_window_fixture(&mut state, now_ms, queue_next_window)?;',
      'fixture.manager.hf_lease_window_reconcile_needed(&view)',
      'fixture.manager.reconcile_once()?;',
      'mutation_sink.submitted_model_host_reconciles()',
      'runtime manager must submit exactly one model-host reconcile for the expired window',
    ],
    'Iroha daemon queued and unqueued expired HF window reconcile regression'
  );
  requireScopedLiterals(
    soracloudIrohad,
    'fn hf_local_host_identity_is_configured(',
    '\nfn local_hf_source_execution_hosts(',
    [
      'config.local_validator_account_id.is_some() && config.local_peer_id.is_some()',
      'let (Some(validator_account_id), Some(peer_id)) = (',
      'assignment.validator_account_id == *validator_account_id && assignment.peer_id == peer_id',
    ],
    'Iroha daemon complete exact HF local-host identity predicate'
  );
  requireScopedLiterals(
    soracloudIrohad,
    'fn resolve_local_hf_execution_host(',
    '\nfn ensure_generated_hf_execution_host_ready(',
    [
      'if !hf_local_host_identity_is_configured(config)',
      'SoracloudRuntimeExecutionErrorKind::Unavailable',
      'requires both the local validator account and peer identity',
      'hf_assignment_matches_local_host(config, assignment)',
      'soracloud_hf_placement_assignment_has_active_capability(',
    ],
    'Iroha daemon fail-closed generated-HF local execution identity gate'
  );
  requireScopedLiterals(
    soracloudIrohad,
    'fn ensure_generated_hf_execution_host_ready(',
    '\nfn resolve_asset_artifact',
    [
      'let Some(host) = host else',
      'SoracloudRuntimeExecutionErrorKind::Unavailable',
      'no exact authoritative local host assignment',
      'SoraHfPlacementHostStatusV1::Unavailable | SoraHfPlacementHostStatusV1::Retired',
      'require_primary && host.role != SoraHfPlacementHostRoleV1::Primary',
      'require_primary && host.status != SoraHfPlacementHostStatusV1::Warm',
    ],
    'Iroha daemon generated-HF execution assignment and warm-primary gate'
  );
  requireScopedLiterals(
    soracloudIrohad,
    'fn resolve_local_hf_execution_host_requires_complete_exact_identity()',
    '\n    #[tokio::test(flavor = "multi_thread")]\n    async fn reconcile_task_imports_generated_hf_source_without_panicking()',
    [
      'account_only.local_validator_account_id = Some(ALICE_ID.clone())',
      'peer_only.local_peer_id = Some(local_peer_id.to_owned())',
      'generated-HF execution must fail closed on a missing identity half',
      'requires both the local validator',
      'generated-HF execution must not treat a missing assignment as authorized',
      'no exact authoritative local host assignment',
    ],
    'Iroha daemon incomplete generated-HF local identity rejection test'
  );
  requireScopedLiterals(
    soracloudIrohad,
    'fn prune_stale_hf_local_workers(',
    '\n    fn desired_hosted_http_worker_keys(',
    [
      'view: &StateView',
      'hf_local_host_identity_is_configured(&self.config)',
      'local_hf_source_execution_hosts(view, source_id, &self.config)',
      'workers.retain(|source_id, worker|',
      'active_sources.contains(source_id)',
      'stale_workers.push(Arc::clone(worker));',
      'for worker in stale_workers',
      'worker.lock().stop();',
    ],
    'Iroha daemon locally-authorized resident HF worker pruning'
  );
  requireScopedLiterals(
    soracloudIrohad,
    'fn reconcile_once_does_not_probe_or_start_host_worker_for_warm_replica()',
    '\n    #[test]\n    fn reconcile_once_never_submits_model_host_heartbeat_from_host_probe()',
    [
      'SoraHfPlacementHostRoleV1::Replica',
      'SoraHfPlacementHostStatusV1::Warm',
      'runtime.manager.reconcile_once()?;',
      'runtime.manager.hf_local_workers.lock().is_empty()',
    ],
    'Iroha daemon warm-replica host-worker non-activation regression'
  );
  requireScopedLiterals(
    soracloudIrohad,
    'fn reconcile_once_never_submits_model_host_heartbeat_from_host_probe()',
    '\n    #[test]\n    fn reconcile_once_reports_advert_contradiction_for_local_peer_mismatch()',
    [
      'SoraHfPlacementHostRoleV1::Primary',
      'SoraHfPlacementHostStatusV1::Warming',
      'heartbeats.is_empty()',
      'runtime.manager.hf_local_workers.lock().is_empty()',
      'mutation_sink.submitted_violation_reports().is_empty()',
    ],
    'Iroha daemon host probe cannot self-authorize heartbeat or execution'
  );
  requireScopedLiterals(
    soracloudIrohad,
    'fn inrou_placement_reconcile_needed(',
    '\n    fn request_inrou_placement_reconcile_if_needed(',
    [
      'resolve_active_inrou_placement_record(',
      'resolve_active_inrou_replica_assignments(',
      'view.is_lane_active_for_authority(lane_id)',
      'active_assignments.len() != record.placements.len()',
      'authoritative Inrou assignment capacity requires reconciliation',
    ],
    'Iroha daemon Inrou reconciliation through the shared placement resolver'
  );
  requireScopedLiterals(
    soracloudIrohad,
    'fn local_inrou_host_capability_refresh_candidate(',
    '\n    fn refresh_local_inrou_host_capability_if_needed(',
    [
      'soracloud_validator_has_active_peer_binding(',
      '&desired.peer_id,',
      'view.is_lane_active_for_authority(lane_id)',
      'self.clear_pending_inrou_host_capability_advert();',
      'return None;',
    ],
    'Iroha daemon inactive-validator Inrou advert refresh suppression'
  );
  requireScopedLiterals(
    soracloudIrohad,
    'fn local_inrou_replica_placements(',
    '\nfn build_inrou_runtime_plan(',
    [
      'resolve_active_inrou_replica_assignments(',
      'view.is_lane_active_for_authority(lane_id)',
      'refusing to materialize malformed authoritative Inrou placement',
      '&placement.validator_account_id == local_validator_account_id',
      'placement.peer_id == local_peer_id',
      'placements.sort_by_key(|placement| placement.replica_slot);',
    ],
    'Iroha daemon local projection through the shared Inrou resolver'
  );
  requireScopedLiterals(
    soracloudIrohad,
    'fn inrou_placement_reconcile_detects_inactive_validator_with_live_capability()',
    '\n    #[test]\n    fn inrou_placement_reconcile_rejects_cross_keyed_record()',
    [
      'PublicLaneValidatorStatus::Exited',
      'otherwise-live Inrou host capability',
      'SoracloudRuntimeManager::inrou_placement_reconcile_needed(',
      'collect_service_revision_registry(&view)',
      'inactive validator must not refresh its Inrou capability',
      'assert!(plan.local_replica_slots.is_empty())',
      'assert!(plan.local_replicas.is_empty())',
      'assert_eq!(plan.process_generation, None)',
    ],
    'Iroha daemon inactive-validator Inrou reconciliation trigger test'
  );
  requireScopedLiterals(
    soracloudIrohad,
    'fn inrou_placement_reconcile_rejects_aggregate_capacity_downgrade()',
    '\n    #[test]\n    fn inrou_placement_reconcile_observes_authoritative_sequence_lease_boundary()',
    [
      'second_bundle.service.service_name = "capacity_peer"',
      'insert_inrou_service_placement_fixture(&mut state, &bundle, local_peer_id, [1_u16]);',
      '&second_bundle,',
      'capability.max_hosted_replica_capacity = 1;',
      'each placement lifecycle remains independently active',
      'assert_eq!(record.placements.len(), 1);',
      'assert_eq!(record.eligible_validator_count, 1);',
      'aggregate reservations above the downgraded host capacity must fail closed',
      'SoracloudRuntimeManager::inrou_placement_reconcile_needed(',
      'assert!(plan.local_replica_slots.is_empty());',
    ],
    'Iroha daemon aggregate capacity regression uses schema-valid independent placements'
  );
  const inrouLeaseBoundaryScope = requireScopedLiterals(
    soracloudIrohad,
    'fn inrou_placement_reconcile_observes_authoritative_sequence_lease_boundary()',
    '\n    #[test]\n    fn refresh_local_inrou_host_capability_submits_candidate()',
    [
      'soracloud_service_audit_events_mut_for_testing()',
      'sample_service_audit_event(&bundle, 99)',
      'assert_eq!(authoritative_soracloud_sequence(view.world()), 100)',
      'Some(SoraServiceLeaseStatusV1::Expired)',
    ],
    'Iroha daemon lease-boundary regression uses a valid authoritative sequence record'
  );
  rejectLiterals(
    inrouLeaseBoundaryScope,
    ['SoraRuntimeReceiptV1', 'soracloud_runtime_receipts_mut_for_testing'],
    'Iroha daemon lease-boundary fixture excludes impossible Inrou runtime receipts'
  );
  requireScopedLiterals(
    soracloudIrohad,
    'fn submit_http_service_runtime_state_retries_until_authoritative_state_catches_up()',
    '\n    #[test]\n    fn build_runtime_snapshot_rejects_corrupt_hosted_http_runtime_state()',
    [
      'forced-available Inrou runtime plan',
      'assert_eq!(plan.local_replica_slots, vec![1])',
      'assert_eq!(plan.local_replicas.len(), 1)',
      'submit_http_service_runtime_state_updates(&view, &snapshot, &bundle_registry)',
      'submitted_states.len(),\n            2,',
      'hosted replica runtime state must be retried while authoritative state is missing',
      'assert_eq!(submitted_state.replica_slot, 1)',
      'assert_eq!(submitted_state.validator_account_id, *ALICE_ID)',
      'assert_eq!(submitted_state.peer_id, local_peer_id)',
      'submitted_state.materialized_bundle_hash',
      'bundle.container.bundle_hash',
      'submitted_state.reporting_epoch > 0',
    ],
    'Iroha daemon deterministic Inrou runtime-state retry submission test'
  );
  requireScopedLiterals(
    soracloudIrohad,
    'fn sample_deployment_state(bundle: &SoraDeploymentBundleV1)',
    '\n    fn soracloud_entrypoint(',
    [
      'current_service_manifest_hash: bundle.service_manifest_hash()',
      'current_container_manifest_hash: bundle.container_manifest_hash()',
      'deployment\n            .validate()',
      'sample Soracloud deployment state must be production-valid',
    ],
    'Iroha daemon production-valid deployment fixture hashes'
  );
  requireScopedLiterals(
    soracloudIrohad,
    'fn insert_generated_hf_placement_fixture(',
    '\n    fn set_generated_hf_primary_assignment_status(',
    [
      'insert_public_lane_validator_account_fixture(',
      'PublicLaneValidatorStatus::Active',
      'insert_model_host_capability_fixture(',
      'u64::MAX',
    ],
    'Iroha daemon production-authoritative generated-HF placement fixture'
  );
  requireScopedLiterals(
    soracloudIrohad,
    'fn portable_smoke_bundle_fixture(',
    '\n    fn inrou_portable_smoke_boots_debian_guest_and_serves_healthcheck()',
    [
      'bundle.service.container.manifest_hash = bundle.container_manifest_hash();',
      '.validate_for_admission()',
      'invalid PortableVM smoke-test bundle',
    ],
    'Iroha daemon production-valid PortableVM smoke fixture'
  );
  requireScopedLiterals(
    soracloudIrohadRuntimeTail,
    'fn inrou_portable_smoke_boots_external_bundle_and_serves_healthcheck()',
    '\n#[test]\nfn probe_hosted_http_health_accepts_paths_without_a_leading_slash()',
    [
      'bundle.service.container.manifest_hash = bundle.container_manifest_hash();',
      '.validate_for_admission()',
      'invalid external Inrou smoke-test bundle',
    ],
    'Iroha daemon production-valid external Inrou smoke fixture'
  );
  requireScopedLiterals(
    soracloudIrohad,
    'fn reconcile_once_materializes_canary_http_service_inrou_runtime_state()',
    '\n    #[test]\n    fn submit_http_service_lease_usage_update_deduplicates_with_bounded_retry_until_catch_up()',
    [
      'deployment.current_service_version = canary_bundle.service.service_version.clone()',
      'deployment.current_service_manifest_hash = canary_bundle.service_manifest_hash()',
      'deployment.current_container_manifest_hash = canary_bundle.container_manifest_hash()',
      'baseline_version: active_bundle.service.service_version.clone()',
      'candidate_version: canary_bundle.service.service_version.clone()',
      'active_plan.process_generation',
      'canary_plan.process_generation',
      'Some(expected_process_generation)',
      'SoracloudRuntimeRevisionRole::CanaryCandidate',
    ],
    'Iroha daemon canary runtime reconciliation test'
  );
  requireAtLeast(
    torii,
    'ensure_matching_hosted_http_materialized_bundle_hash(',
    3,
    'Torii public and remote served-revision agreement'
  );
  requireScopedLiterals(
    torii,
    'async fn execute_incoming_torii_proxy_request_with_admission_inner(',
    '\n#[cfg(any(feature = "p2p_ws", feature = "connect"))]\nfn reject_incoming_torii_proxy_request_capacity(',
    [
      'ToriiProxyRequestKindV4::HostedHttp(hosted_request)',
      'resolve_exact_hosted_http_runtime_target(',
      'overwrite_soracloud_served_revision_headers(',
    ],
    'Torii remote hosting-peer served-revision stamping'
  );
  const servedHeaderScope = requireScopedLiterals(
    torii,
    'fn overwrite_soracloud_served_revision_headers(',
    '\n#[cfg(feature = "app_api")]\nfn exact_soracloud_served_revision_header',
    [
      'headers.insert(SORACLOUD_SERVED_SERVICE_NAME_HEADER, service_name);',
      'headers.insert(SORACLOUD_SERVED_SERVICE_VERSION_HEADER, service_version);',
      'headers.insert(SORACLOUD_SERVED_REPLICA_SLOT_HEADER, replica_slot);',
      'SORACLOUD_SERVED_PROCESS_GENERATION_HEADER',
      'target.process_generation',
      'SORACLOUD_SERVED_MATERIALIZED_BUNDLE_HASH_HEADER',
      'target.materialized_bundle_hash',
    ],
    'Torii canonical served-revision response headers'
  );
  if (servedHeaderScope.includes('headers.append(')) {
    fail('Torii served-revision headers must overwrite upstream values rather than append them');
  }
  requireScopedLiterals(
    torii,
    'fn exact_soracloud_served_revision_header',
    '\n#[cfg(feature = "app_api")]\nfn validate_soracloud_served_revision_headers(',
    [
      'headers.get_all(name).iter()',
      'if values.next().is_some()',
      'missing Torii-owned',
      'duplicate Torii-owned',
    ],
    'Torii exact remote served-revision header parser'
  );
  requireScopedLiterals(
    torii,
    'fn validate_soracloud_served_revision_headers(',
    '\n#[cfg(feature = "app_api")]\nasync fn proxy_soracloud_public_hosted_http_locally(',
    [
      'SORACLOUD_SERVED_SERVICE_NAME_HEADER',
      'target.route_match.service_name.as_str()',
      'SORACLOUD_SERVED_SERVICE_VERSION_HEADER',
      'target.route_match.service_version.as_str()',
      'SORACLOUD_SERVED_REPLICA_SLOT_HEADER',
      'target.replica_slot.to_string()',
      'SORACLOUD_SERVED_PROCESS_GENERATION_HEADER',
      'target.process_generation.to_string()',
      'SORACLOUD_SERVED_MATERIALIZED_BUNDLE_HASH_HEADER',
      'target.materialized_bundle_hash.as_str()',
      'exact_soracloud_served_revision_header(response.headers(), name)?',
      'if actual != expected',
    ],
    'Torii origin validation of remote served-revision proof'
  );
  const hostedIngressScope = requireScopedLiterals(
    torii,
    'async fn proxy_soracloud_public_hosted_http(',
    '\n#[cfg(feature = "app_api")]\nfn current_public_ingress_ledger_time_ms(',
    ['overwrite_soracloud_served_revision_headers(&mut response, &target)'],
    'Torii hosted-service ingress served-revision binding'
  );
  requireAtLeast(
    hostedIngressScope,
    'overwrite_soracloud_served_revision_headers(&mut response, &target)',
    2,
    'Torii hosted-service ingress local and remote response binding'
  );
  const remoteIngressScope = requireScopedLiterals(
    hostedIngressScope,
    'Ok(Some(mut response)) => {',
    '\n        Ok(None)',
    [
      'validate_soracloud_served_revision_headers(&response, &target)',
      'overwrite_soracloud_served_revision_headers(&mut response, &target)',
    ],
    'Torii origin remote served-revision validation and overwrite'
  );
  requireOrdered(
    remoteIngressScope,
    'validate_soracloud_served_revision_headers(&response, &target)',
    'overwrite_soracloud_served_revision_headers(&mut response, &target)',
    'Torii origin remote served-revision validation and overwrite'
  );
  requireScopedLiterals(
    torii,
    'fn exact_local_soracloud_runtime_peer_id(',
    '\n#[cfg(feature = "app_api")]\nfn resolve_soracloud_local_read_proxy_target(',
    [
      'runtime.local_peer_id()',
      'app.local_peer_id.as_ref()',
      'SoracloudRuntimeExecutionErrorKind::Unavailable',
      'torii_peer_id != &runtime_peer_id',
      'does not match Torii peer',
    ],
    'Torii exact local runtime-to-ingress peer identity binding'
  );
  for (const [scopeStart, scopeEnd, label] of [
    [
      'fn resolve_soracloud_local_read_proxy_target(',
      '\n#[cfg(feature = "app_api")]\nfn report_soracloud_local_read_proxy_failure(',
      'generated-HF outgoing proxy target',
    ],
    [
      'fn local_soracloud_proxy_receiver_is_assigned_host(',
      '\n#[cfg(feature = "app_api")]\nfn validate_generated_hf_proxy_response_authority(',
      'generated-HF local assigned-host receiver',
    ],
    [
      'fn validate_incoming_soracloud_proxy_request_authority(',
      '\n#[cfg(feature = "app_api")]\nasync fn process_incoming_soracloud_proxy_request(',
      'generated-HF incoming proxy authority',
    ],
  ]) {
    requireScopedLiterals(
      torii,
      scopeStart,
      scopeEnd,
      ['let local_peer_id = exact_local_soracloud_runtime_peer_id(app)?;'],
      `Torii ${label} exact local peer binding`
    );
  }
  requireScopedLiterals(
    torii,
    'fn local_soracloud_proxy_receiver_is_assigned_host(',
    '\n#[cfg(feature = "app_api")]\nfn validate_generated_hf_proxy_response_authority(',
    [
      'SoraHfPlacementHostStatusV1::Warming',
      'SoraHfPlacementHostStatusV1::Warm',
      'soracloud_hf_placement_assignment_has_active_capability(',
    ],
    'Torii generated-HF proxy receiver serving-assignment gate'
  );
  requireScopedLiterals(
    soracloudToriiHostedTargetTests,
    'async fn resolve_soracloud_local_read_proxy_target_rejects_runtime_torii_peer_mismatch()',
    '\n#[tokio::test]\nasync fn resolve_soracloud_local_read_proxy_target_rejects_missing_exact_peer_identity()',
    [
      'claimed_primary_peer_id',
      'actual_torii_peer_id',
      'a runtime must not claim another Torii peer',
      'does not match Torii peer',
    ],
    'Torii generated-HF outgoing proxy peer mismatch test'
  );
  requireScopedLiterals(
    soracloudToriiHostedTargetTests,
    'async fn resolve_soracloud_local_read_proxy_target_rejects_missing_exact_peer_identity()',
    '\n#[tokio::test]\nasync fn soracloud_proxy_response_completes_pending_request()',
    [
      'a missing Torii peer identity must fail closed',
      'configured local peer identity',
      'a missing runtime peer identity must fail closed',
      'does not advertise a local peer id',
    ],
    'Torii generated-HF missing exact local peer identity tests'
  );
  requireScopedLiterals(
    soracloudToriiProxyTests,
    'async fn validate_incoming_soracloud_proxy_request_authority_rejects_runtime_torii_peer_mismatch()',
    '\n#[tokio::test]\nasync fn validate_incoming_soracloud_proxy_request_authority_rejects_commitment_mismatch()',
    [
      'claimed_primary_peer_id',
      'actual_torii_peer_id',
      'a runtime may not receive proxy work under another Torii peer identity',
      'does not match Torii peer',
    ],
    'Torii generated-HF incoming proxy peer mismatch test'
  );
  requireScopedLiterals(
    soracloudToriiProxyTests,
    'async fn resolve_incoming_soracloud_proxy_forward_target_rejects_unavailable_receiver()',
    '\n#[tokio::test]\nasync fn resolve_incoming_soracloud_proxy_forward_target_rejects_unassigned_receiver()',
    [
      'SoraHfPlacementHostStatusV1::Unavailable',
      'forward_target.is_none()',
      'an unavailable assignment must not remain an authorized proxy intermediary',
    ],
    'Torii generated-HF unavailable proxy receiver rejection test'
  );
  requireScopedLiterals(
    soracloudToriiProxyTests,
    'async fn local_soracloud_proxy_receiver_rejects_runtime_torii_peer_mismatch()',
    '\n#[tokio::test]\nasync fn resolve_incoming_soracloud_proxy_forward_target_rejects_invalid_request()',
    [
      'claimed_replica_peer_id',
      'actual_torii_peer_id',
      'a runtime may not forward under another Torii peer identity',
      'does not match Torii peer',
    ],
    'Torii generated-HF assigned receiver peer mismatch test'
  );
  requireScopedLiterals(
    torii,
    'fn validate_generated_hf_proxy_response_authority(',
    '\n#[cfg(all(feature = "app_api", any(feature = "p2p_ws", feature = "connect")))]\nasync fn execute_soracloud_local_read_via_proxy(',
    [
      'let primary_assignment = iroha_core::soracloud_runtime::resolve_generated_hf_primary_assignment(',
      'receipt.execution_host.as_ref()',
      'SoraRuntimeExecutionHostV1::HfModelHost(host)',
      'host.placement_id == placement.placement_id',
      'host.validator_account_id == primary_assignment.validator_account_id',
      'host.peer_id == primary_assignment.peer_id',
      'target_peer_id.to_string() != primary_assignment.peer_id || !receipt_host_matches',
      'receipt attribution that does not match authoritative placement',
    ],
    'Torii generated-HF proxy typed responding-host authority binding'
  );
  requireScopedLiterals(
    soracloudToriiProxyTests,
    'async fn validate_generated_hf_proxy_response_authority_rejects_response_from_previous_primary()',
    '\n#[tokio::test]\nasync fn validate_generated_hf_proxy_response_authority_rejects_result_commitment_mismatch()',
    [
      'current_primary_peer_id',
      'previous_primary_peer_id',
      '&previous_primary_peer_id',
      'a prior primary must not claim the current primary',
      'receipt attribution',
    ],
    'Torii previous generated-HF primary response rejection test'
  );

  validateWalletRegistry(webRegistry, 'web', {
    scopeStart: '  taira: {',
    scopeEnd: '  nexus: {',
    scopeLiterals: [
      `chainId: '${TAIRA_CHAIN_ID}'`,
      `toriiBaseUrl: '${TAIRA_ORIGIN}'`,
      'nativeAsset: {',
      `id: '${TAIRA_XOR_ASSET_ID}'`,
      "symbol: 'XOR'",
      'decimals: 9',
    ],
  });
  validateWalletRegistry(androidRegistry, 'Android', {
    scopeStart: '    val taira = IrohaNetwork(',
    scopeEnd: '    val nexus = IrohaNetwork(',
    scopeLiterals: [
      'chainId = TAIRA_CHAIN_ID',
      `toriiBaseUrl = "${TAIRA_ORIGIN}"`,
      'nativeAsset = IrohaNativeAsset(',
      'id = TAIRA_XOR_ASSET_DEFINITION_ID',
      'symbol = "XOR"',
      'decimals = 9',
    ],
  });
  validateWalletRegistry(iosRegistry, 'iOS', {
    scopeStart: '    static let taira = IrohaNetwork(',
    scopeEnd: '    static let nexus = IrohaNetwork(',
    scopeLiterals: [
      'chainId: tairaChainId',
      `toriiBaseURL: URL(string: "${TAIRA_ORIGIN}")!`,
      'nativeAsset: IrohaNativeAsset(',
      'id: tairaXorAssetDefinitionId',
      'symbol: "XOR"',
      'decimals: 9',
    ],
  });
  requireLiteral(webTorii, "'iroha_torii_partial_response'", 'web strict fanout handling');
  requireLiteral(
    webTorii,
    'if (present.length !== Object.keys(headerNames).length)',
    'web mandatory six-header fanout contract'
  );
  if (webTorii.includes('if (present.length === 0) return')) {
    fail('web Torii client still accepts routed reads without fanout evidence');
  }
  requireLiteral(webTorii, "'iroha.transactions.submit_and_wait'", 'web terminal transaction workflow');
  requireLiteral(webTorii, 'body_base64', 'web canonical MCP signing envelope');
  requireLiteral(webTorii, 'if (status < 200 || status > 299)', 'web nested routed status boundary');
  requireLiteral(
    webTorii,
    'requireJsonResponseMediaType(response, body);',
    'web outer MCP JSON media-type requirement'
  );
  requireLiteral(webTorii, 'const hash = payload?.entrypoint_hash;', 'web canonical submit receipt hash');
  requireLiteral(webTorii, 'const finalHash = finalStatus.body.hash;', 'web canonical final-status hash');
  for (const marker of [
    "rpcResponse.jsonrpc !== '2.0' || rpcResponse.id !== requestId",
    "Object.hasOwn(rpcResponse, 'result') === Object.hasOwn(rpcResponse, 'error')",
    "typeof hash !== 'string' || !/^[0-9a-f]{63}[13579bdf]$/u.test(hash)",
    'return hash;',
  ]) {
    requireLiteral(webTorii, marker, `web exact JSON-RPC/hash contract ${marker}`);
  }
  for (const marker of [
    "typeof value !== 'string' || !/^[0-9a-f]{63}[13579bdf]$/u.test(value)",
    'return value;',
  ]) {
    requireLiteral(webTransfer, marker, `web exact locally-derived hash contract ${marker}`);
  }
  if (webTorii.includes('tx_hash_hex')) {
    fail('web Torii client still accepts the retired submit receipt hash alias');
  }
  requireLiteral(webTorii, "redirect: 'error'", 'web redirect refusal');
  requireLiteral(
    webTorii,
    'if (Object.hasOwn(headers, normalizedName))',
    'web case-colliding routed-header refusal'
  );
  requireLiteral(webTorii, "mediaType !== 'application/json'", 'web routed JSON media-type requirement');
  requireLiteral(webTorii, 'url.search ||', 'web query-bearing Torii URL refusal');
  requireLiteral(webTorii, 'url.hash', 'web fragment-bearing Torii URL refusal');
  requireLiteral(
    webTorii,
    'summary.notFound > summary.failed - summary.denied - summary.unavailable',
    'web overflow-safe fanout validation'
  );
  for (const marker of [
    "throw new Error('invalid_iroha_chain_id')",
    'if (network.chainId !== profile.chainId) return false',
    "throw new Error('noncanonical_iroha_chain_id')",
    "throw new Error('unsupported_iroha_network')",
  ]) {
    requireLiteral(webTransfer, marker, `web exact Iroha transfer identity ${marker}`);
  }
  for (const [source, label, marker] of [
    [webBaseApi, 'web foreground address routing', '({ chainId, name }) => chainId === network || isSameString(name, network)'],
    [webState, 'web background address routing', 'resolveCanonicalIrohaAddressNetwork(network.chainId)'],
  ]) {
    requireLiteral(source, marker, `${label} canonical chain identity`);
    for (const forbidden of ["contract.includes('taira')", "contract.includes('nexus')"]) {
      if (source.includes(forbidden)) fail(`${label} still permits name/alias Iroha fallthrough`);
    }
  }
  requireLiteral(
    webBaseApi,
    'resolveCanonicalIrohaAddressNetwork(networkJson.chainId)',
    'web foreground exact canonical Iroha address identity'
  );
  requireLiteral(
    webIrohaAddress,
    "if (chainId === UNIVERSAL_WALLET_IROHA_NETWORKS.taira.chainId) return 'taira';",
    'web exact Taira address identity'
  );
  requireLiteral(
    webIrohaAddress,
    "if (chainId === UNIVERSAL_WALLET_IROHA_NETWORKS.nexus.chainId) return 'nexus';",
    'web exact Nexus address identity'
  );
  requireLiteral(webIrohaAddress, "throw new Error('unsupported_iroha_chain_id')", 'web unknown Iroha identity refusal');
  for (const [client, label] of [
    [androidTorii, 'Android'],
    [iosTorii, 'iOS'],
  ]) {
    requireLiteral(client, 'iroha.transactions.submit_and_wait', `${label} terminal transaction workflow`);
    requireLiteral(client, 'body_base64', `${label} canonical MCP signing envelope`);
    requireLiteral(client, 'x-iroha-fanout-routes-denied', `${label} denied fanout proof`);
    requireLiteral(client, 'x-iroha-fanout-routes-not-found', `${label} not-found fanout proof`);
    requireLiteral(client, '^[0-9a-f]{63}[13579bdf]$', `${label} canonical Iroha transaction hash`);
  }
  requireLiteral(
    androidTorii,
    'listOf(hash, transactionHash, receiptHash, finalHash).any { it != expectedHash }',
    'Android local transaction hash binding'
  );
  requireLiteral(androidToriiModels, 'val jsonrpc: String? = null', 'Android observable JSON-RPC version');
  requireLiteral(
    androidTorii,
    'val hasExactlyOnePayload = (response.result == null) != (response.error == null)',
    'Android exclusive JSON-RPC result/error contract'
  );
  requireLiteral(
    androidTorii,
    'response.jsonrpc != "2.0" || response.id != request.id || !hasExactlyOnePayload',
    'Android JSON-RPC version and request binding'
  );
  requireLiteral(
    androidTorii,
    'return value?.takeIf(CANONICAL_TRANSACTION_HASH::matches)',
    'Android exact Torii transaction hash spelling'
  );
  requireLiteral(androidToriiRoutes, 'if (!HASH_256.matches(hash))', 'Android exact status hash spelling');
  requireLiteral(androidToriiRoutes, 'return hash', 'Android unmodified status hash');
  requireLiteral(
    androidTransfer,
    'return this?.takeIf(IROHA_TRANSACTION_HASH_PATTERN::matches)',
    'Android exact locally-derived transaction hash spelling'
  );
  requireLiteral(
    androidTorii,
    'validateFanoutHeaders { response.headers().values(it).singleOrNull() }',
    'Android unique outer fanout-header requirement'
  );
  requireLiteral(androidTorii, 'requireJsonContentType(response)', 'Android outer JSON media-type requirement');
  requireLiteral(
    androidTorii,
    'duplicate case-insensitive headers',
    'Android nested case-colliding header refusal'
  );
  requireLiteral(
    androidTorii,
    'val contentType = (route["content_type"] as? String)',
    'Android nested JSON media-type requirement'
  );
  requireLiteral(androidTorii, 'terminalKind != IrohaPipelineTransactionStatusKind.Applied', 'Android Applied finality');
  requireLiteral(
    iosTorii,
    'canonicalTransactionHash(outcome.finalStatus.body.hash) == canonicalExpectedHash',
    'iOS local transaction hash binding'
  );
  requireLiteral(iosToriiContract, 'let jsonrpc: String?', 'iOS observable JSON-RPC version');
  requireLiteral(
    iosTorii,
    'let hasExactlyOnePayload = (response.result == nil) != (response.error == nil)',
    'iOS exclusive JSON-RPC result/error contract'
  );
  requireLiteral(iosTorii, 'response.id == .string(request.id)', 'iOS JSON-RPC request binding');
  requireLiteral(iosTorii, 'response.jsonrpc == "2.0"', 'iOS JSON-RPC version binding');
  requireLiteral(iosTorii, 'return value', 'iOS unmodified Torii transaction hash');
  requireLiteral(
    iosToriiContract,
    'guard matches(hash, "^[0-9a-f]{63}[13579bdf]$") else',
    'iOS exact status hash spelling'
  );
  requireLiteral(
    iosTransfer,
    'guard value.range(of: "^[0-9a-f]{63}[13579bdf]$", options: .regularExpression) != nil else',
    'iOS exact locally-derived transaction hash spelling'
  );
  requireLiteral(iosTorii, 'outcome.terminalKind == .applied', 'iOS Applied finality');
  requireLiteral(
    iosTorii,
    'let headers = try normalizedResponseHeaders(response.headers)',
    'iOS unique outer response-header requirement'
  );
  requireLiteral(iosTorii, 'try requireJSONContentType(headers)', 'iOS outer JSON media-type requirement');
  requireLiteral(
    iosTorii,
    'isJSONMediaType(outcome.submit.contentType)',
    'iOS nested JSON media-type requirement'
  );
  requireLiteral(iosToriiContract, 'let contentType: String', 'iOS required nested content type');
  requireLiteral(iosToriiContract, 'let headers: [String: String]', 'iOS required nested fanout headers');
  if (iosToriiContract.includes('let contentType: String?')) {
    fail('iOS nested MCP content type must not be optional');
  }
  if (iosToriiContract.includes('let headers: [String: String]?')) {
    fail('iOS nested MCP fanout headers must not be optional');
  }
  if (androidTorii.includes('if (rawFanout.any { it != null })')) {
    fail('Android Torii client still accepts routed reads without fanout evidence');
  }
  if (iosTorii.includes('if rawValues.contains(where: { $0 != nil })')) {
    fail('iOS Torii client still accepts routed reads without fanout evidence');
  }
  for (const marker of [
    'return id == UniversalWalletRegistry.taira.chainId ||',
    'id == UniversalWalletRegistry.nexus.chainId',
    'fun Chain.hasNonCanonicalUniversalWalletIrohaIdentity()',
    'UniversalWalletRegistry.taira.chainId -> UniversalWalletRegistry.taira',
    'UniversalWalletRegistry.nexus.chainId -> UniversalWalletRegistry.nexus',
  ]) {
    requireLiteral(androidIdentity, marker, `Android exact Iroha identity ${marker}`);
  }
  requireLiteral(
    androidBalanceProvider,
    'chain.hasNonCanonicalUniversalWalletIrohaIdentity() -> throw IllegalArgumentException(',
    'Android noncanonical Iroha balance-route refusal'
  );
  requireLiteral(
    androidTransfer,
    '} else if (chain.hasNonCanonicalUniversalWalletIrohaIdentity()) {',
    'Android noncanonical Iroha transfer-route refusal'
  );
  for (const source of [androidMetaAccount, androidMigration]) {
    requireLiteral(source, 'UniversalWalletRegistry.taira.chainId', 'Android exact stored Taira identity');
    requireLiteral(source, 'UniversalWalletRegistry.nexus.chainId', 'Android exact stored Nexus identity');
    if (source.includes('UniversalWalletRegistry.taira.id') || source.includes('UniversalWalletRegistry.nexus.id')) {
      fail('Android Iroha registry aliases must not be stored-account or migration identities');
    }
  }
  for (const marker of [
    'if exactIrohaNetwork(for: requestedChainId) != nil {',
    'return storedChainId == requestedChainId',
    'case UniversalWalletRegistry.taira.chainId:',
    'case UniversalWalletRegistry.nexus.chainId:',
  ]) {
    requireLiteral(iosAddressResolver, marker, `iOS exact Iroha account identity ${marker}`);
  }
  for (const marker of [
    'let trimmedChainId = chainId.trimmingCharacters(in: .whitespacesAndNewlines)',
    'trimmedChainId.caseInsensitiveCompare(UniversalWalletRegistry.taira.id) == .orderedSame',
    'trimmedChainId.caseInsensitiveCompare(UniversalWalletRegistry.nexus.id) == .orderedSame',
    'trimmedChainId.caseInsensitiveCompare(UniversalWalletRegistry.taira.chainId) == .orderedSame',
    'trimmedChainId.caseInsensitiveCompare(UniversalWalletRegistry.nexus.chainId) == .orderedSame',
    'trimmedChainId.caseInsensitiveCompare("iroha3-taira") == .orderedSame',
  ]) {
    requireLiteral(iosAddressResolver, marker, `iOS noncanonical Iroha identity classifier ${marker}`);
  }
  requireLiteral(
    iosMigration,
    'chainAccount(matchingExactly: Self.tairaChainIds)',
    'iOS exact Taira migration identity'
  );
  requireLiteral(
    iosMigration,
    'chainAccount(matchingExactly: Self.nexusChainIds)',
    'iOS exact Nexus migration identity'
  );
  if (iosMigration.includes('UniversalWalletRegistry.taira.id') || iosMigration.includes('UniversalWalletRegistry.nexus.id')) {
    fail('iOS Iroha registry aliases must not be migration identities');
  }
  requireLiteral(
    iosSendContainer,
    'if UniversalWalletChainAccountSupport.isNonCanonicalIrohaProfile(chainAsset.chain) {',
    'iOS noncanonical Iroha send-route refusal'
  );
  for (const marker of [
    'chainId == chainId.trimmingCharacters(in: .whitespacesAndNewlines)',
    '!UniversalWalletChainAccountSupport.isNonCanonicalIrohaIdentity(chainId)',
  ]) {
    requireLiteral(iosMetaAccountMapper, marker, `iOS stored Iroha identity quarantine invariant ${marker}`);
  }
  requireLiteral(
    iosMetaAccountMapperTests,
    'func testSingleNoncanonicalIrohaStoredRowIsQuarantined()',
    'iOS stored Iroha identity quarantine test'
  );
  requireLiteral(
    iosAddressResolverTests,
    'func testIrohaAddressResolutionRejectsAliasesCaseMutationsAndUnknownIdentifiers()',
    'iOS noncanonical Iroha identity adversarial test'
  );
  requireLiteral(
    iosAddressResolverTests,
    'func testIrohaAddressResolutionRejectsWhitespaceWrappedKnownIdentities()',
    'iOS whitespace-wrapped Iroha identity adversarial test'
  );
  requireLiteral(
    iosMetaAccountMapperTests,
    'func testSingleWhitespaceWrappedIrohaStoredRowIsQuarantined()',
    'iOS whitespace-wrapped stored Iroha quarantine test'
  );
  requireLiteral(
    iosToriiContract,
    'assetDefinitionId == assetDefinitionId.trimmingCharacters(in: .whitespacesAndNewlines)',
    'iOS exact asset-definition identifier routing'
  );
  requireLiteral(
    iosToriiContractTests,
    'func testRejectsPaddedAssetDefinitionIdentifiersWithoutCanonicalizing()',
    'iOS padded asset-definition identifier adversarial test'
  );
  requireLiteral(
    androidToriiModels,
    'notFound > failed - denied - unavailable',
    'Android overflow-safe fanout validation'
  );
  requireLiteral(
    iosToriiContract,
    'notFound <= failed - denied - unavailable',
    'iOS overflow-safe fanout validation'
  );
  requireLiteral(androidNetworkModule, '.followRedirects(false)', 'Android Iroha HTTP redirect refusal');
  requireLiteral(androidNetworkModule, '.followSslRedirects(false)', 'Android Iroha HTTPS redirect refusal');
  requireLiteral(
    androidNetworkModule,
    'irohaNoRedirectHttpClient(okHttpClient)',
    'Android Iroha no-redirect transport binding'
  );
  requireLiteral(iosTorii, 'completionHandler(nil)', 'iOS Iroha redirect refusal');
  requireLiteral(
    iosTorii,
    'transport: IrohaToriiHTTPTransport = IrohaNoRedirectHTTPTransport()',
    'iOS Iroha no-redirect transport binding'
  );
  for (const marker of ['parsed.userInfo != null', 'parsed.query != null', 'parsed.ref != null']) {
    requireLiteral(androidToriiRoutes, marker, `Android unsafe Torii URL refusal ${marker}`);
  }
  requireLiteral(
    androidToriiRoutes,
    '(parsed.protocol != "https" && !(parsed.protocol == "http" && isLocal))',
    'Android HTTPS-or-loopback-HTTP Torii URL policy'
  );
  for (const marker of ['url.user == nil', 'url.password == nil', 'url.query == nil', 'url.fragment == nil']) {
    requireLiteral(iosToriiContract, marker, `iOS unsafe Torii URL refusal ${marker}`);
  }
  requireLiteral(
    iosToriiContract,
    'scheme == "https" || (scheme == "http" && isLocal)',
    'iOS HTTPS-or-loopback-HTTP Torii URL policy'
  );
  for (const [client, label, routedMarker, mcpMarker] of [
    [androidTorii, 'Android', 'return completeRoutedBody(', 'return completeMcpBody('],
    [iosTorii, 'iOS', 'completeRoutedData(try await transport.performResponse', 'completeMCPData(try await transport.performResponse'],
  ]) {
    requireLiteral(client, routedMarker, `${label} direct routed-read fanout boundary`);
    requireLiteral(client, mcpMarker, `${label} outer MCP transport boundary`);
  }
  for (const [history, label, literals] of [
    [webHistory, 'web', [
      'const precision = await validateIrohaHistoryAssetDefinition',
      "!hasExactRecordKeys(body, ['pagination', 'items'])",
      "!hasExactRecordKeys(body.pagination, ['page', 'per_page', 'total_pages', 'total_items'])",
      'page !== requestedPage',
      'parsed.totalItems !== expectedTotalItems',
      "throw new Error('noncanonical_iroha_history_field')",
      "if (transactionStatus !== 'Committed')",
      "const box = item['box']",
      "!hasExactRecordKeys(box, ['encoded', 'framed_sha256', 'json'])",
      "mode.mode !== 'Atomic'",
      'mode.value !== null',
      'new TextEncoder().encode(legId).length',
      'MAX_IROHA_QUANTITY = (1n << 511n) - 1n',
      "throw new Error('duplicate_iroha_history_id')",
      'scaledIrohaIntegerToBaseUnits',
      'fee: null',
      'unsupported_iroha_chain_id',
      "return typeof left === 'string' && left === right;",
    ]],
    [androidHistory, 'Android', [
      'toolResult["isError"] != false',
      'toolResult["structuredContent"]',
      'Torii omitted the fixed scale',
      'Torii MCP history returned a non-canonical field alias',
      'if (transactionStatus != "Committed")',
      '!body.hasExactKeys(HISTORY_PAGE_KEYS)',
      '!pagination.hasExactKeys(PAGINATION_KEYS)',
      'page != requestedPage.toLong()',
      'totalPages != calculatedTotalPages',
      'val box = this["box"] as? Map<*, *>',
      'mode.canonicalString("mode") != "Atomic"',
      'mode["value"] != null',
      'it.toByteArray(Charsets.UTF_8).size <= MAX_BATCH_LEG_ID_LENGTH',
      'BigInteger.ONE.shiftLeft(511).subtract(BigInteger.ONE)',
      'fee = null',
      'val outgoing = sourceAccount == accountAddress',
    ]],
    [iosHistory, 'iOS', [
      'instructionPage(',
      'toolResult["structuredContent"]',
      'case missingScale(String)',
      'rejectingAliases: ["transactionStatus", "status"]',
      'guard transactionStatus == "Committed"',
      'body.hasExactKeys(historyPageKeys)',
      'pagination.hasExactKeys(paginationKeys)',
      'page == Int64(requestedPage)',
      'totalPages == calculatedTotalPages',
      'let box = self["box"]?.objectValue',
      'mode["mode"] == .string("Atomic")',
      'mode["value"] == .null',
      'legId.utf8.count <= maxIrohaBatchLegIdLength',
      '(BigUInt(1) << 511) - 1',
      'duplicate_history_identity',
      'fees: []',
      'let outgoing = sourceAccount == accountAddress',
      'amount.toSubstrateAmount(precision: Int16(precision)) == transfer.amount',
    ]],
  ]) {
    for (const literal of literals) requireLiteral(history, literal, `${label} strict Taira history contract`);
  }
  for (const [history, label] of [
    [webHistory, 'web'],
    [androidHistory, 'Android'],
    [iosHistory, 'iOS'],
  ]) {
    if (history.includes('r#box')) fail(`${label} history still consumes the private Rust field spelling r#box`);
  }
  for (const [history, label, retiredFallback] of [
    [webHistory, 'web', 'source?.includes(address)'],
    [androidHistory, 'Android', 'source?.contains(accountAddress)'],
    [iosHistory, 'iOS', 'source?.contains(accountAddress)'],
  ]) {
    if (history.includes(retiredFallback)) {
      fail(`${label} history still classifies an asset source by wallet-address substring`);
    }
  }
  for (const [history, label, retiredComparison] of [
    [webHistory, 'web', 'left.toLowerCase() === right.toLowerCase()'],
    [androidHistory, 'Android', 'sourceAccount?.equals(accountAddress, ignoreCase = true)'],
    [iosHistory, 'iOS', 'sourceAccount?.caseInsensitiveEquals(accountAddress) == true'],
  ]) {
    if (history.includes(retiredComparison)) {
      fail(`${label} history still compares canonical I105 account IDs case-insensitively`);
    }
  }
  for (const [history, label, retiredStatusCheck] of [
    [webHistory, 'web', "transactionStatus !== 'Rejected'"],
    [androidHistory, 'Android', 'transactionStatus != "Rejected"'],
    [iosHistory, 'iOS', 'transactionStatus != "Rejected"'],
  ]) {
    if (history.includes(retiredStatusCheck)) {
      fail(`${label} history still treats a non-Rejected transaction as committed`);
    }
  }
  if (androidHistory.includes('if (rawValues.none { it != null }) return')) {
    fail('Android history still accepts MCP route results without fanout evidence');
  }
  const nullableHasMoreCount = androidToriiModels.match(/val hasMore: Boolean\?/gu)?.length ?? 0;
  if (nullableHasMoreCount !== 2) {
    fail('Android account-asset and asset-definition completeness fields must both remain nullable');
  }
  requireLiteral(androidHistory, 'definitions.hasMore != false', 'Android complete history definitions snapshot');
  requireLiteral(androidBalance, 'definitions.hasMore != false', 'Android complete balance definitions snapshot');
  requireLiteral(androidBalance, 'response.hasMore != false', 'Android complete account-assets snapshot');
  requireLiteral(
    webBalance,
    'network.chainId === UNIVERSAL_WALLET_IROHA_NETWORKS.taira.chainId',
    'web exact Taira balance network identity'
  );
  for (const marker of [
    "countMode: 'bounded'",
    'limit: IROHA_BALANCE_PAGE_SIZE',
    'limit: IROHA_DEFINITION_PAGE_SIZE',
    'offset: 0',
    "response.body?.has_more !== false || response.body?.count_mode !== 'bounded'",
    'item.account_id !== requestedAccountId',
    'item.accountId !== undefined',
    'item.asset_id !== undefined',
    'item.value !== undefined',
    'isCanonicalIrohaAssetDefinitionId(this.getAssetId(item), network)',
    "? /^[1-9A-HJ-NP-Za-km-z]{20,64}$/u.test(value)",
    'seenScopes.has(scopeKey)',
    'MAX_IROHA_NUMERIC = (1n << 511n) - 1n',
    'sumCanonicalIrohaQuantities',
  ]) {
    requireLiteral(webBalance, marker, `web strict Taira balance contract ${marker}`);
  }
  for (const marker of [
    'limit = IrohaToriiRoutes.MAX_LIMIT',
    'offset = 0',
    'countMode = IrohaToriiRoutes.CountMode.Bounded',
    'definitions.countMode != IrohaToriiRoutes.CountMode.Bounded.apiValue',
    'response.countMode != IrohaToriiRoutes.CountMode.Bounded.apiValue',
    'if (item.accountId != address)',
    'if (item.assetId != null)',
    'IrohaToriiRoutes.normalizeAssetDefinitionId(presentItemAsset)',
    'IrohaToriiRoutes.normalizeAccountAssetScope(itemScope)',
    'seenAccountAssetScopes.add(canonicalItemAsset to canonicalScope)',
    'val maxBalanceInPlanks = MAX_QUANTITY.multiply(BigInteger.TEN.pow(precision))',
    'value > maxBalanceInPlanks.subtract(total)',
  ]) {
    requireLiteral(androidBalance, marker, `Android strict Taira balance contract ${marker}`);
  }
  for (const marker of [
    'limit: IrohaToriiRoutes.maxLimit',
    'offset: 0',
    'countMode: .bounded',
    'definitions.countMode == IrohaToriiCountMode.bounded.rawValue',
    'response.countMode == IrohaToriiCountMode.bounded.rawValue',
    'guard item.accountID == address',
    'guard item.assetID == nil',
    'IrohaToriiRoutes.normalizeAssetDefinitionId(item.asset)',
    'IrohaToriiRoutes.normalizeAccountAssetScope(scope)',
    'seenAssetScopes.insert("\\(canonicalAsset)\\u{0}\\(canonicalScope)").inserted',
    'let maxBalanceInPlanks = maxIrohaNumeric * scaleFactor',
    'value <= maxBalanceInPlanks - total',
  ]) {
    requireLiteral(iosBalance, marker, `iOS strict Taira balance contract ${marker}`);
  }
  requireLiteral(profile, `pub const TAIRA_XOR_SCALE: u32 = ${TAIRA_XOR_SCALE};`, 'Iroha Taira scale pin');
  requireLiteral(profile, `const PUBLIC_TAIRA_CHAIN_ID: &str = "${TAIRA_CHAIN_ID}";`, 'Iroha Taira chain pin');
  requireLiteral(generator, 'NumericSpec::fractional(TAIRA_XOR_SCALE)', 'Iroha Taira genesis scale');
  requireLiteral(explorer, '#[norito(rename = "box")]', 'Iroha explorer canonical instruction container key');
  requirePattern(config, new RegExp(`^chain = "${TAIRA_CHAIN_ID}"$`, 'mu'), 'Taira node chain pin');
  requireLiteral(config, `accepted_assets = ["${TAIRA_XOR_ASSET_ID}"]`, 'Taira fee asset allowlist');
  requireLiteral(config, 'fee_asset_id = "xor#universal"', 'Taira public fee alias');
  requireLiteral(operatorSkill, TAIRA_CHAIN_ID, 'Taira operator skill chain contract');
  requireLiteral(operatorSkill, TAIRA_XOR_ASSET_ID, 'Taira operator skill native asset contract');
  requireLiteral(operatorSkill, '`iroha.transactions.submit_and_wait`', 'Taira operator terminal submission contract');
  requireLiteral(operatorSkill, '"body_base64"', 'Taira operator canonical transaction envelope');
  for (const retired of ['`iroha.status`', '`iroha.sumeragi.status`', 'signed_tx_base64', '`iroha.asset-definitions.get`']) {
    if (operatorSkill.includes(retired)) fail(`Taira operator skill still contains retired contract ${retired}`);
  }
  validateGenesis(genesis);
  validateReviewDigestChain(nevoReview, {
    baseConfig: config,
    baseGenesis: genesisText,
    publicInputs: nevoPublicInputs,
    unsignedGenesis: nevoUnsignedGenesis,
  });
  validateNativeNevoReview({
    irohaRoot: resolve(parent, 'iroha'),
    reviewPath: nevoReviewPath,
    unsignedGenesisPath: nevoUnsignedGenesisPath,
  });
  validateDnsManifest(dnsManifest);

  return { dnsManifest };
}

function parseJsonBody(response, label) {
  try {
    return JSON.parse(response.body.toString('utf8'));
  } catch {
    fail(`${label} must return valid JSON`);
  }
}

function requireMediaType(headers, expected, label) {
  const contentType = headers['content-type'];
  if (typeof contentType !== 'string' || contentType.split(';', 1)[0].trim().toLowerCase() !== expected) {
    fail(`${label} must return Content-Type ${expected}`);
  }
}

function headerCount(headers, name) {
  const value = headers[name];
  if (typeof value !== 'string' || !/^(?:0|[1-9]\d*)$/u.test(value)) {
    fail(`Taira response is missing valid ${name}`);
  }
  const count = Number(value);
  if (!Number.isSafeInteger(count)) fail(`Taira response has unsafe ${name}`);
  return count;
}

function assertCompleteFanout(headers) {
  const attempted = headerCount(headers, 'x-iroha-fanout-routes-attempted');
  const succeeded = headerCount(headers, 'x-iroha-fanout-routes-succeeded');
  const failed = headerCount(headers, 'x-iroha-fanout-routes-failed');
  const denied = headerCount(headers, 'x-iroha-fanout-routes-denied');
  const unavailable = headerCount(headers, 'x-iroha-fanout-routes-unavailable');
  const notFound = headerCount(headers, 'x-iroha-fanout-routes-not-found');

  if (attempted < 4 || succeeded !== attempted || failed !== 0 || denied !== 0 || unavailable !== 0 || notFound !== 0) {
    fail(
      `Taira fanout is incomplete: attempted=${attempted} succeeded=${succeeded} failed=${failed} denied=${denied} unavailable=${unavailable} not_found=${notFound}`
    );
  }
}

function validateStatus(status, expectedCommit, now = Date.now()) {
  if (!status || typeof status !== 'object' || Array.isArray(status)) fail('Taira /status must return an object');
  const failures = [];
  if (status.chain_id !== TAIRA_CHAIN_ID) failures.push('chain_id does not match the canonical UUID');
  if (!Number.isSafeInteger(status.blocks) || status.blocks < 1) failures.push('blocks must be positive');
  if (!Number.isSafeInteger(status.peers) || status.peers < 4) failures.push('at least four peers are required');
  if (
    !Number.isSafeInteger(status.time_since_last_block_ms) ||
    status.time_since_last_block_ms < 0 ||
    status.time_since_last_block_ms > MAX_BLOCK_AGE_MS
  ) {
    failures.push('a block must have committed within the last 60 seconds');
  }
  if (
    !Number.isSafeInteger(status.last_block_committed_at_ms) ||
    status.last_block_committed_at_ms < now - MAX_BLOCK_AGE_MS ||
    status.last_block_committed_at_ms > now + 30_000
  ) {
    failures.push('last_block_committed_at_ms is stale or in the future');
  }
  if (status?.build?.git_commit_sha !== expectedCommit) {
    failures.push('build.git_commit_sha does not match TAIRA_EXPECTED_BUILD_COMMIT');
  }

  walk(status, (value) => {
    for (const [key, candidate] of Object.entries(value)) {
      if (key === 'manifest_path' && typeof candidate === 'string' && candidate.startsWith('/')) {
        failures.push('an absolute manifest_path is exposed');
      }
    }
  });
  if (failures.length > 0) fail(`Taira /status failed release checks: ${[...new Set(failures)].join('; ')}`);
}

function validateAssetDefinitions(body) {
  const items = Array.isArray(body?.items) ? body.items : [];
  const definitions = items.filter((item) => item?.id === TAIRA_XOR_ASSET_ID);

  if (
    body?.count_mode !== 'bounded' ||
    body?.has_more !== false ||
    definitions.length !== 1 ||
    definitions[0]?.spec?.scale !== TAIRA_XOR_SCALE
  ) {
    fail('live Taira must expose one complete canonical XOR snapshot with spec.scale 9');
  }
}

function validateToolsList(body) {
  if (body?.jsonrpc !== '2.0' || body?.id !== 1 || !body?.result || body.error !== undefined) {
    fail('Taira MCP tools/list returned an invalid JSON-RPC envelope');
  }
  const tool = Array.isArray(body.result.tools)
    ? body.result.tools.find((candidate) => candidate?.name === 'iroha.transactions.submit_and_wait')
    : undefined;
  const required = tool?.inputSchema?.required;
  const properties = tool?.inputSchema?.properties;

  if (
    !tool ||
    tool.inputSchema?.additionalProperties !== false ||
    !Array.isArray(required) ||
    required.length !== 1 ||
    required[0] !== 'body_base64' ||
    !properties ||
    typeof properties !== 'object' ||
    !Object.hasOwn(properties, 'body_base64') ||
    !Object.hasOwn(properties, 'hash') ||
    Object.hasOwn(properties, 'signed_tx_base64')
  ) {
    fail('Taira MCP must expose iroha.transactions.submit_and_wait with required body_base64');
  }
}

function boundedRequest(path, { method = 'GET', headers = {}, body } = {}) {
  const url = new URL(path, TAIRA_ORIGIN);
  if (url.origin !== TAIRA_ORIGIN || url.protocol !== 'https:') fail(`unsafe Taira audit URL: ${url}`);

  return new Promise((resolveRequest, rejectRequest) => {
    const request = https.request(
      url,
      {
        agent: false,
        headers: { 'user-agent': 'fearless-taira-release-audit/1', ...headers },
        method,
        minVersion: 'TLSv1.2',
        rejectUnauthorized: true,
        timeout: 10_000,
      },
      (response) => {
        const chunks = [];
        let size = 0;

        response.on('data', (chunk) => {
          size += chunk.length;
          if (size > MAX_RESPONSE_BYTES) {
            request.destroy(new AuditError(`Taira ${path} response exceeded ${MAX_RESPONSE_BYTES} bytes`));
            return;
          }
          chunks.push(chunk);
        });
        response.on('end', () => {
          const status = response.statusCode ?? 0;
          if (status < 200 || status >= 300) {
            rejectRequest(new AuditError(`Taira ${path} returned HTTP ${status}`));
            return;
          }
          resolveRequest({ body: Buffer.concat(chunks), headers: response.headers, status });
        });
      }
    );
    request.on('timeout', () => request.destroy(new AuditError(`Taira ${path} timed out`)));
    request.on('error', rejectRequest);
    if (body !== undefined) request.write(body);
    request.end();
  });
}

async function validateLiveDns(dnsManifest) {
  const records = dnsManifest.records.filter(
    (record) => record?.type === 'A' && /^taira-validator-[1-4]\.sora\.org$/u.test(record.name)
  );

  const failures = await Promise.all(
    records.map(async (record) => {
      let addresses;
      try {
        addresses = await dns.resolve4(record.name);
      } catch (error) {
        return `${record.name} does not resolve (${error instanceof Error ? error.code : 'unknown'})`;
      }
      if (!addresses.includes(record.value)) {
        return `${record.name} does not publish committed address ${record.value}`;
      }
      return null;
    })
  );
  const unresolved = failures.filter((failure) => failure !== null);
  if (unresolved.length > 0) fail(`Taira validator DNS failed release checks: ${unresolved.join('; ')}`);
}

async function runLiveAudit(dnsManifest, expectedCommit) {
  if (!/^(?:[0-9a-f]{40}|[0-9a-f]{64})$/u.test(expectedCommit) || /^(.)\1+$/u.test(expectedCommit)) {
    fail('TAIRA_EXPECTED_BUILD_COMMIT must be a non-placeholder 40- or 64-character lowercase commit');
  }

  const checks = [
    ['health', async () => {
      const health = await boundedRequest('/health', { headers: { accept: 'text/plain' } });
      requireMediaType(health.headers, 'text/plain', 'Taira /health');
      if (health.body.toString('utf8').trim() !== 'Healthy') fail('Taira /health did not return Healthy');
    }],
    ['status', async () => {
      const response = await boundedRequest('/status', { headers: { accept: 'application/json' } });
      requireMediaType(response.headers, 'application/json', 'Taira /status');
      validateStatus(parseJsonBody(response, 'Taira /status'), expectedCommit);
    }],
    ['asset definitions', async () => {
      const response = await boundedRequest(TAIRA_ASSET_DEFINITIONS_PATH, {
        headers: { accept: 'application/json' },
      });
      requireMediaType(response.headers, 'application/json', 'Taira asset definitions');
      const body = parseJsonBody(response, 'Taira asset definitions');
      const failures = [];
      for (const check of [
        () => assertCompleteFanout(response.headers),
        () => validateAssetDefinitions(body),
      ]) {
        try {
          check();
        } catch (error) {
          failures.push(boundedDiagnostic(error));
        }
      }
      if (failures.length > 0) fail(failures.join('; '));
    }],
    ['MCP tool contract', async () => {
      const body = JSON.stringify({ jsonrpc: '2.0', id: 1, method: 'tools/list', params: {} });
      const response = await boundedRequest('/v1/mcp', {
        body,
        headers: { accept: 'application/json', 'content-length': Buffer.byteLength(body), 'content-type': 'application/json' },
        method: 'POST',
      });
      requireMediaType(response.headers, 'application/json', 'Taira MCP tools/list');
      validateToolsList(parseJsonBody(response, 'Taira MCP tools/list'));
    }],
    ['validator DNS', () => validateLiveDns(dnsManifest)],
  ];
  const results = await Promise.all(
    checks.map(async ([label, check]) => {
      try {
        await check();
        return null;
      } catch (error) {
        return `${label}: ${boundedDiagnostic(error)}`;
      }
    })
  );
  const failures = results.filter((result) => result !== null);
  if (failures.length > 0) fail(`live Taira release checks failed:\n  - ${failures.join('\n  - ')}`);
}

function parseArgs(argv) {
  const scriptDir = dirname(fileURLToPath(import.meta.url));
  const options = {
    live: false,
    parent: resolve(scriptDir, '../..'),
    root: resolve(scriptDir, '..'),
  };

  for (let index = 0; index < argv.length; index += 1) {
    const argument = argv[index];
    if (argument === '--live') options.live = true;
    else if (argument === '--root' && argv[index + 1]) options.root = resolve(argv[++index]);
    else if (argument === '--parent' && argv[index + 1]) options.parent = resolve(argv[++index]);
    else fail(`unknown or incomplete argument: ${argument}`);
  }

  return options;
}

async function main() {
  const options = parseArgs(process.argv.slice(2));
  const { dnsManifest } = runStaticAudit(options);

  if (options.live) await runLiveAudit(dnsManifest, process.env.TAIRA_EXPECTED_BUILD_COMMIT ?? '');

  process.stdout.write(`[taira-readiness] ${options.live ? 'static and live' : 'static'} audit passed\n`);
}

if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) {
  main().catch((error) => {
    const message = error instanceof AuditError ? error.message : 'unexpected Taira release audit failure';
    process.stderr.write(`[taira-readiness][error] ${message}\n`);
    process.exitCode = 1;
  });
}

export {
  AuditError,
  TAIRA_ASSET_DEFINITIONS_PATH,
  assertCompleteFanout,
  runLiveAudit,
  runStaticAudit,
  validateAssetDefinitions,
  validateDnsManifest,
  validateGenesis,
  validateNativeNevoReview,
  validateReviewDigestChain,
  validateRuntimeExecutionHostOpenApi,
  validateRuntimeExecutionHostOpenApiArtifacts,
  validateStatus,
  validateToolsList,
};
