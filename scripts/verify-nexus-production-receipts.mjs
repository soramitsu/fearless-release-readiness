#!/usr/bin/env node

import { execFileSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';
import process from 'node:process';
import { TextDecoder } from 'node:util';

const EXPECTED_NETWORK = 'sora-nexus-mainnet';
const EXPECTED_CHAIN_ID = 'sora:nexus:global';
const EXPECTED_TORII_ORIGIN = 'https://minamoto.sora.org';
const EXPECTED_MCP_URL = 'https://minamoto.sora.org/v1/mcp';
const EXPECTED_ROUTE_SOURCE_PATH = 'artifacts/nexus/production-route-governance-action.json';
const EXPECTED_APPLY_WIRE_ID = 'iroha_data_model::isi::bridge::ApplySccpRouteGovernance';
const EXPECTED_TRANSFER_WIRE_ID = 'iroha.transfer';
const MAX_ARTIFACT_BYTES = 256 * 1024;
const MAX_RESPONSE_BYTES = 64 * 1024;
const MAX_FIXTURE_BYTES = 128 * 1024;
const REQUEST_TIMEOUT_MS = 10_000;
const TX_HASH_PATTERN = /^0x[0-9a-f]{64}$/u;
const COMMIT_PATTERN = /^[0-9a-f]{40}$/u;
const SHA256_PATTERN = /^sha256:[0-9a-f]{64}$/u;
const ENCODED_INSTRUCTION_PATTERN = /^0x(?:[0-9a-f]{2}){40,}$/u;
const SIGNATURE_PATTERN = /^(?:[0-9a-f]{2})+$/u;
const FORBIDDEN_JSON_KEYS = new Set(['__proto__', 'constructor', 'prototype']);

const args = process.argv.slice(2);
let evidenceFile = '';
let rootDir = '';
let selfTestReceiptsDir = '';
for (let index = 0; index < args.length; index += 1) {
  const arg = args[index];
  if (arg === '--evidence') evidenceFile = args[++index] || '';
  else if (arg === '--root') rootDir = args[++index] || '';
  else if (arg === '--self-test-receipts') selfTestReceiptsDir = args[++index] || '';
  else throw new Error(`unknown Nexus receipt verifier argument: ${arg}`);
}
if (!evidenceFile) throw new Error('--evidence is required');
if (!rootDir) throw new Error('--root is required');

function fail(message) {
  throw new Error(message);
}

function isRecord(value) {
  return value !== null && typeof value === 'object' && !Array.isArray(value);
}

function assertSafeJsonTree(value, label, depth = 0) {
  if (depth > 64) fail(`${label} exceeds the maximum JSON nesting depth`);
  if (Array.isArray(value)) {
    value.forEach((entry, index) => assertSafeJsonTree(entry, `${label}[${index}]`, depth + 1));
    return;
  }
  if (typeof value === 'number' && !Number.isSafeInteger(value)) {
    fail(`${label} numeric values must be safe integers; encode decimals and large integers as strings`);
  }
  if (!isRecord(value)) return;
  for (const [key, child] of Object.entries(value)) {
    if (FORBIDDEN_JSON_KEYS.has(key)) fail(`${label} contains forbidden JSON key ${key}`);
    assertSafeJsonTree(child, `${label}.${key}`, depth + 1);
  }
}

function assertNoDuplicateJsonKeys(text, label) {
  let offset = 0;
  const whitespace = () => {
    while (/\s/u.test(text[offset] || '')) offset += 1;
  };
  const stringToken = () => {
    const start = offset;
    if (text[offset] !== '"') fail(`${label} contains malformed JSON string syntax`);
    offset += 1;
    let escaped = false;
    while (offset < text.length) {
      const char = text[offset++];
      if (escaped) escaped = false;
      else if (char === '\\') escaped = true;
      else if (char === '"') return JSON.parse(text.slice(start, offset));
    }
    fail(`${label} contains an unterminated JSON string`);
  };
  const value = (depth = 0) => {
    if (depth > 64) fail(`${label} exceeds the maximum JSON nesting depth`);
    whitespace();
    if (text[offset] === '{') {
      offset += 1;
      const keys = new Set();
      whitespace();
      if (text[offset] === '}') { offset += 1; return; }
      while (offset < text.length) {
        whitespace();
        const key = stringToken();
        if (keys.has(key)) fail(`${label} contains duplicate JSON key ${key}`);
        keys.add(key);
        whitespace();
        if (text[offset++] !== ':') fail(`${label} contains malformed JSON object syntax`);
        value(depth + 1);
        whitespace();
        const delimiter = text[offset++];
        if (delimiter === '}') return;
        if (delimiter !== ',') fail(`${label} contains malformed JSON object syntax`);
      }
      fail(`${label} contains an unterminated JSON object`);
    }
    if (text[offset] === '[') {
      offset += 1;
      whitespace();
      if (text[offset] === ']') { offset += 1; return; }
      while (offset < text.length) {
        value(depth + 1);
        whitespace();
        const delimiter = text[offset++];
        if (delimiter === ']') return;
        if (delimiter !== ',') fail(`${label} contains malformed JSON array syntax`);
      }
      fail(`${label} contains an unterminated JSON array`);
    }
    if (text[offset] === '"') { stringToken(); return; }
    while (offset < text.length && !/[\s,\]}]/u.test(text[offset])) offset += 1;
  };
  value();
  whitespace();
  if (offset !== text.length) fail(`${label} contains trailing JSON data`);
}

function parseJsonText(text, label) {
  let parsed;
  try {
    parsed = JSON.parse(text);
  } catch {
    fail(`${label} must be valid JSON`);
  }
  assertNoDuplicateJsonKeys(text, label);
  assertSafeJsonTree(parsed, label);
  return parsed;
}

function readBoundedFile(file, maxBytes, label) {
  let stat;
  try {
    stat = fs.lstatSync(file);
  } catch {
    fail(`${label} missing`);
  }
  if (!stat.isFile() || stat.isSymbolicLink()) fail(`${label} must be a regular non-symlink file`);
  if (stat.size > maxBytes) fail(`${label} exceeds ${maxBytes} bytes`);
  return fs.readFileSync(file, 'utf8');
}

function stableJson(value) {
  if (Array.isArray(value)) return `[${value.map(stableJson).join(',')}]`;
  if (isRecord(value)) {
    return `{${Object.keys(value)
      .sort()
      .map((key) => `${JSON.stringify(key)}:${stableJson(value[key])}`)
      .join(',')}}`;
  }
  if (value === null || typeof value === 'string' || typeof value === 'boolean') return JSON.stringify(value);
  if (typeof value === 'number' && Number.isFinite(value)) return JSON.stringify(value);
  fail('JSON comparison contains an unsupported value');
}

function deepEqual(left, right) {
  return stableJson(left) === stableJson(right);
}

function assertExactKeys(value, expectedKeys, label) {
  if (!isRecord(value)) fail(`${label} must be an object`);
  const actual = Object.keys(value).sort();
  const expected = [...expectedKeys].sort();
  if (!deepEqual(actual, expected)) fail(`${label} has unsupported or missing fields`);
}

function assertAllowedKeys(value, requiredKeys, optionalKeys, label) {
  if (!isRecord(value)) fail(`${label} must be an object`);
  const allowed = new Set([...requiredKeys, ...optionalKeys]);
  for (const key of Object.keys(value)) {
    if (!allowed.has(key)) fail(`${label} has unsupported field ${key}`);
  }
  for (const key of requiredKeys) {
    if (!(key in value)) fail(`${label} is missing field ${key}`);
  }
}

function normalizeTxHash(value, label) {
  const original = String(value || '');
  const normalized = original.toLowerCase();
  if (!TX_HASH_PATTERN.test(normalized)) fail(`${label} must be a lowercase 0x-prefixed 32-byte hash`);
  if (original !== normalized) fail(`${label} must be a lowercase 0x-prefixed 32-byte hash`);
  return normalized;
}

function validateRouteActionHash(value, label) {
  if (typeof value !== 'string' || !SHA256_PATTERN.test(value)) {
    fail(`${label} must be a lowercase sha256 route governance action hash`);
  }
  if (value === `sha256:${'0'.repeat(64)}`) {
    fail(`${label} must not be an all-zero placeholder hash`);
  }
}

function validateWalletCommit(value, label) {
  if (typeof value !== 'string' || !COMMIT_PATTERN.test(value)) {
    fail(`${label} must be a lowercase 40-character wallet commit`);
  }
  if (value === '0'.repeat(40)) fail(`${label} must not be an all-zero placeholder commit`);
}

function noPrefix(hash) {
  return hash.slice(2);
}

function ensureSelfTestConfinement() {
  if (!selfTestReceiptsDir) return;
  if (process.env.NEXUS_EVIDENCE_SELF_TEST !== '1') {
    fail('self-test receipt fixtures require NEXUS_EVIDENCE_SELF_TEST=1');
  }
  const fixtures = fs.realpathSync(selfTestReceiptsDir);
  const evidence = fs.realpathSync(evidenceFile);
  const tempRoot = fs.realpathSync(process.env.TMPDIR || '/tmp');
  const inside = (candidate, parent) => candidate === parent || candidate.startsWith(`${parent}${path.sep}`);
  if (!inside(fixtures, tempRoot) || !inside(evidence, tempRoot)) {
    fail('self-test receipt fixtures and evidence must be confined to the system temporary directory');
  }
  if (!inside(evidence, path.dirname(fixtures)) && !inside(evidence, fixtures)) {
    fail('self-test evidence must share the temporary fixture workspace');
  }
  const marker = path.join(fixtures, '.nexus-receipt-self-test-v1');
  if (readBoundedFile(marker, 64, 'Nexus receipt self-test marker').trim() !== 'nexus-receipt-self-test-v1') {
    fail('Nexus receipt self-test marker mismatch');
  }
}

function validateArtifact(artifact, label) {
  assertExactKeys(artifact, ['schemaVersion', 'network', 'chainId', 'publicationInstruction'], label);
  if (artifact.schemaVersion !== 1) fail(`${label}.schemaVersion must be 1`);
  if (artifact.network !== EXPECTED_NETWORK) fail(`${label}.network must be ${EXPECTED_NETWORK}`);
  if (artifact.chainId !== EXPECTED_CHAIN_ID) fail(`${label}.chainId must be ${EXPECTED_CHAIN_ID}`);
  const instruction = artifact.publicationInstruction;
  assertExactKeys(instruction, ['kind', 'wireId', 'encoded'], `${label}.publicationInstruction`);
  if (instruction.kind !== 'ApplySccpRouteGovernance') {
    fail(`${label}.publicationInstruction.kind must be ApplySccpRouteGovernance`);
  }
  if (instruction.wireId !== EXPECTED_APPLY_WIRE_ID) {
    fail(`${label}.publicationInstruction.wireId must be ${EXPECTED_APPLY_WIRE_ID}`);
  }
  if (typeof instruction.encoded !== 'string' || !ENCODED_INSTRUCTION_PATTERN.test(instruction.encoded)) {
    fail(`${label}.publicationInstruction.encoded must be lowercase 0x-prefixed canonical Norito bytes of at least 40 bytes`);
  }
  const bytes = Buffer.from(instruction.encoded.slice(2), 'hex');
  const digest = createHash('sha256').update(bytes).digest('hex');
  return { hash: `sha256:${digest}`, instruction };
}

function readProductionArtifact(commit, sourcePath) {
  if (!COMMIT_PATTERN.test(commit)) fail('route governance action commit must be a lowercase 40-character commit');
  if (sourcePath !== EXPECTED_ROUTE_SOURCE_PATH) {
    fail(`route governance action source path must be ${EXPECTED_ROUTE_SOURCE_PATH}`);
  }
  const repo = path.resolve(rootDir, '..', 'iroha');
  let raw;
  try {
    raw = execFileSync('/usr/bin/git', ['-C', repo, 'show', `${commit}:${sourcePath}`], {
      encoding: 'utf8',
      maxBuffer: MAX_ARTIFACT_BYTES + 1,
      timeout: 10_000,
      stdio: ['ignore', 'pipe', 'pipe'],
      env: {
        PATH: '/usr/bin:/bin',
        HOME: '/',
        GIT_CONFIG_NOSYSTEM: '1',
        GIT_CONFIG_GLOBAL: '/dev/null',
        GIT_NO_REPLACE_OBJECTS: '1',
        GIT_TERMINAL_PROMPT: '0',
      },
    });
  } catch {
    fail(`canonical route governance action artifact ${sourcePath} is unavailable at pinned commit ${commit}`);
  }
  if (Buffer.byteLength(raw, 'utf8') > MAX_ARTIFACT_BYTES) {
    fail('canonical route governance action artifact exceeds 262144 bytes');
  }
  return validateArtifact(
    parseJsonText(raw, 'canonical route governance action artifact'),
    'canonical route governance action artifact',
  );
}

function expectedRouteCommit() {
  const override = process.env.NEXUS_ROUTE_MANIFEST_EXPECTED_COMMIT;
  if (override !== undefined && override !== '') {
    if (!COMMIT_PATTERN.test(override)) {
      fail('NEXUS_ROUTE_MANIFEST_EXPECTED_COMMIT must be a lowercase 40-character commit');
    }
    return override;
  }
  const repo = path.resolve(rootDir, '..', 'iroha');
  try {
    const commit = execFileSync('/usr/bin/git', ['-C', repo, 'rev-parse', 'HEAD'], {
      encoding: 'utf8',
      maxBuffer: 256,
      timeout: 10_000,
      stdio: ['ignore', 'pipe', 'pipe'],
      env: {
        PATH: '/usr/bin:/bin',
        HOME: '/',
        GIT_CONFIG_NOSYSTEM: '1',
        GIT_CONFIG_GLOBAL: '/dev/null',
        GIT_NO_REPLACE_OBJECTS: '1',
        GIT_TERMINAL_PROMPT: '0',
      },
    }).trim();
    if (!COMMIT_PATTERN.test(commit)) fail('../iroha HEAD is not a lowercase 40-character commit');
    return commit;
  } catch (error) {
    if (String(error?.message || '').includes('../iroha HEAD')) throw error;
    fail('NEXUS_ROUTE_MANIFEST_EXPECTED_COMMIT must be set because ../iroha HEAD could not be determined');
  }
}

function readSelfTestArtifact(commit) {
  const file = path.join(selfTestReceiptsDir, `route-governance-action-${commit}.json`);
  const raw = readBoundedFile(file, MAX_ARTIFACT_BYTES, `self-test route governance action artifact for ${commit}`);
  return validateArtifact(
    parseJsonText(raw, 'self-test route governance action artifact'),
    'self-test route governance action artifact',
  );
}

function statusRequest(hash) {
  return {
    url: `${EXPECTED_TORII_ORIGIN}/v1/pipeline/transactions/status?hash=${noPrefix(hash)}&scope=global`,
    method: 'GET',
    headers: { accept: 'application/json' },
    body: null,
  };
}

function mcpRequest(hash, suffix, name, callArguments) {
  const id = `nexus-${suffix}-${noPrefix(hash).slice(0, 24)}`;
  return {
    url: EXPECTED_MCP_URL,
    method: 'POST',
    headers: { accept: 'application/json', 'content-type': 'application/json' },
    body: {
      jsonrpc: '2.0',
      id,
      method: 'tools/call',
      params: { name, arguments: callArguments },
    },
  };
}

function transactionRequest(hash) {
  return mcpRequest(hash, 'tx', 'iroha.transactions.get', {
    hash: noPrefix(hash),
    accept: 'application/json',
  });
}

function instructionRequest(hash) {
  return mcpRequest(hash, 'isi', 'iroha.instructions.list', {
    transaction_hash: noPrefix(hash),
    transaction_status: 'committed',
    page: 0,
    per_page: 2,
    accept: 'application/json',
  });
}

async function readResponseBodyBounded(response, label) {
  const declared = response.headers.get('content-length');
  if (declared !== null && (!/^\d+$/u.test(declared) || Number(declared) > MAX_RESPONSE_BYTES)) {
    fail(`${label} response content-length is invalid or exceeds ${MAX_RESPONSE_BYTES} bytes`);
  }
  if (!response.body) fail(`${label} response body is missing`);
  const chunks = [];
  let total = 0;
  for await (const chunk of response.body) {
    total += chunk.byteLength;
    if (total > MAX_RESPONSE_BYTES) fail(`${label} response exceeds ${MAX_RESPONSE_BYTES} bytes`);
    chunks.push(Buffer.from(chunk));
  }
  try {
    return new TextDecoder('utf-8', { fatal: true }).decode(Buffer.concat(chunks));
  } catch {
    fail(`${label} response must be valid UTF-8`);
  }
}

function responseContentType(headers, label) {
  const value = headers['content-type'];
  if (typeof value !== 'string' || !/^application\/json(?:\s*;\s*charset=utf-8)?$/iu.test(value.trim())) {
    fail(`${label} response content-type must be application/json`);
  }
}

function validateTransportEnvelope(envelope, request, label) {
  assertExactKeys(envelope, ['url', 'redirected', 'status', 'headers', 'rawBody'], `${label} transport response`);
  if (envelope.url !== request.url) fail(`${label} response URL must remain ${request.url}`);
  if (envelope.redirected !== false) fail(`${label} redirects are forbidden`);
  if (envelope.status !== 200) fail(`${label} response must be HTTP 200`);
  if (!isRecord(envelope.headers)) fail(`${label} response headers must be an object`);
  responseContentType(envelope.headers, label);
  if (typeof envelope.rawBody !== 'string') fail(`${label} response body must be a string`);
  if (Buffer.byteLength(envelope.rawBody, 'utf8') > MAX_RESPONSE_BYTES) {
    fail(`${label} response exceeds ${MAX_RESPONSE_BYTES} bytes`);
  }
  return parseJsonText(envelope.rawBody, `${label} response`);
}

async function fetchProduction(request, label) {
  const parsed = new URL(request.url);
  if (parsed.origin !== EXPECTED_TORII_ORIGIN || parsed.username || parsed.password) {
    fail(`${label} request must use the credential-free canonical Minamoto origin`);
  }
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), REQUEST_TIMEOUT_MS);
  try {
    const response = await fetch(request.url, {
      method: request.method,
      headers: request.headers,
      body: request.body === null ? undefined : JSON.stringify(request.body),
      redirect: 'manual',
      credentials: 'omit',
      cache: 'no-store',
      referrerPolicy: 'no-referrer',
      signal: controller.signal,
    });
    const headers = Object.fromEntries(response.headers.entries());
    const rawBody = await readResponseBodyBounded(response, label);
    return validateTransportEnvelope(
      { url: response.url, redirected: response.redirected, status: response.status, headers, rawBody },
      request,
      label,
    );
  } catch (error) {
    if (String(error?.message || '').startsWith(`${label} `)) throw error;
    fail(`${label} request failed or exceeded ${REQUEST_TIMEOUT_MS}ms`);
  } finally {
    clearTimeout(timer);
  }
}

function readSelfTestResponse(request, hash, kind, label) {
  const file = path.join(selfTestReceiptsDir, `${noPrefix(hash)}.${kind}.json`);
  const fixture = parseJsonText(readBoundedFile(file, MAX_FIXTURE_BYTES, `${label} fixture`), `${label} fixture`);
  assertExactKeys(fixture, ['mode', 'request', 'response'], `${label} fixture`);
  if (fixture.mode !== 'nexus-receipt-self-test-v1') {
    fail(`${label} fixture must declare nexus-receipt-self-test-v1`);
  }
  if (!deepEqual(fixture.request, request)) fail(`${label} fixture request does not match the canonical Minamoto request`);
  return validateTransportEnvelope(fixture.response, request, label);
}

async function query(request, hash, kind, label) {
  if (selfTestReceiptsDir) return readSelfTestResponse(request, hash, kind, label);
  return fetchProduction(request, label);
}

function validateStatus(body, hash, label) {
  assertAllowedKeys(
    body,
    ['hash', 'status', 'summary', 'scope', 'resolved_from'],
    ['diagnostics', 'trigger_completions'],
    `${label} status response`,
  );
  if (body.hash !== noPrefix(hash)) fail(`${label} status response hash mismatch`);
  if (body.scope !== 'global') fail(`${label} status response scope must be global`);
  if (!['cache', 'state'].includes(body.resolved_from)) {
    fail(`${label} applied status resolved_from must be cache or state`);
  }
  assertExactKeys(body.status, ['kind', 'block_height'], `${label} status response status`);
  if (body.status.kind !== 'Applied' || body.summary !== 'Applied') {
    fail(`${label} pipeline transaction status must be Applied`);
  }
  if (!Number.isSafeInteger(body.status.block_height) || body.status.block_height <= 0) {
    fail(`${label} applied transaction must have a positive block_height`);
  }
  if ('diagnostics' in body && (!Array.isArray(body.diagnostics) || body.diagnostics.length !== 0)) {
    fail(`${label} applied status diagnostics must be absent or empty`);
  }
  if ('trigger_completions' in body && !Array.isArray(body.trigger_completions)) {
    fail(`${label} status trigger_completions must be an array when present`);
  }
  return body.status.block_height;
}

function extractMcpStructuredBody(body, request, label) {
  assertExactKeys(body, ['jsonrpc', 'id', 'result'], `${label} JSON-RPC response`);
  if (body.jsonrpc !== '2.0' || body.id !== request.body.id) {
    fail(`${label} response must match the canonical JSON-RPC request`);
  }
  assertExactKeys(body.result, ['content', 'isError', 'structuredContent'], `${label} result`);
  if (body.result.isError !== false) fail(`${label} result must be successful`);
  if (!deepEqual(body.result.content, [{ type: 'text', text: 'http 200' }])) {
    fail(`${label} result content must report http 200`);
  }
  const structured = body.result.structuredContent;
  assertExactKeys(structured, ['status', 'headers', 'content_type', 'body'], `${label} structuredContent`);
  if (
    structured.status !== 200 ||
    structured.content_type !== 'application/json' ||
    !isRecord(structured.headers) ||
    structured.headers['content-type'] !== 'application/json'
  ) {
    fail(`${label} route must return HTTP 200 application/json structured content`);
  }
  return structured.body;
}

function validateOptionalDuration(value, label) {
  if (value === null) return;
  assertExactKeys(value, ['ms'], label);
  if (!Number.isSafeInteger(value.ms) || value.ms < 0) fail(`${label}.ms must be a non-negative safe integer`);
}

function validateExpectedMetadata(metadata, label) {
  if (!isRecord(metadata)) fail(`${label} expected signed metadata must be an object`);
  const role = metadata.evidence_role;
  if (!['route-publication', 'route-canary', 'wallet-smoke'].includes(role)) {
    fail(`${label} expected signed metadata evidence_role is invalid`);
  }
  validateRouteActionHash(metadata.route_governance_action_hash, `${label} metadata.route_governance_action_hash`);
  if (role === 'wallet-smoke') {
    assertExactKeys(
      metadata,
      ['evidence_role', 'route_governance_action_hash', 'wallet_platform', 'wallet_commit'],
      `${label} expected signed metadata`,
    );
    if (!['android', 'ios', 'web'].includes(metadata.wallet_platform)) {
      fail(`${label} metadata.wallet_platform must be android, ios, or web`);
    }
    validateWalletCommit(metadata.wallet_commit, `${label} metadata.wallet_commit`);
  } else {
    assertExactKeys(
      metadata,
      ['evidence_role', 'route_governance_action_hash'],
      `${label} expected signed metadata`,
    );
  }
}

function validateTransactionDetail(body, request, hash, expected, label) {
  const detail = extractMcpStructuredBody(body, request, `${label} transaction`);
  assertExactKeys(
    detail,
    [
      'authority', 'hash', 'block', 'created_at', 'executable', 'status',
      'rejection_reason', 'executable_payload', 'metadata', 'nonce',
      'signature', 'time_to_live',
    ],
    `${label} transaction detail`,
  );
  if (detail.authority !== expected.authority) fail(`${label} transaction authority mismatch`);
  if (detail.hash !== noPrefix(hash)) fail(`${label} transaction detail hash mismatch`);
  if (!Number.isSafeInteger(detail.block) || detail.block <= 0) {
    fail(`${label} transaction detail block must be positive`);
  }
  if (detail.created_at !== expected.createdAt) fail(`${label} transaction created_at mismatch`);
  if (detail.executable !== 'Instructions') fail(`${label} executable must be Instructions`);
  if (detail.status !== 'Committed' || detail.rejection_reason !== null) {
    fail(`${label} explorer transaction must be committed without rejection`);
  }
  if (!deepEqual(detail.executable_payload, { instruction_count: 1 })) {
    fail(`${label} transaction must contain exactly one instruction`);
  }
  if (!deepEqual(detail.metadata, expected.metadata)) fail(`${label} signed transaction metadata mismatch`);
  if (detail.nonce !== null && (!Number.isSafeInteger(detail.nonce) || detail.nonce <= 0)) {
    fail(`${label} transaction nonce must be null or a positive safe integer`);
  }
  if (typeof detail.signature !== 'string' || !SIGNATURE_PATTERN.test(detail.signature)) {
    fail(`${label} transaction signature must be non-empty lowercase hexadecimal bytes`);
  }
  validateOptionalDuration(detail.time_to_live, `${label} transaction time_to_live`);
  return { block: detail.block, createdAt: detail.created_at };
}

function extractInstruction(body, request, hash, label) {
  const routeBody = extractMcpStructuredBody(body, request, `${label} instructions`);
  assertExactKeys(routeBody, ['pagination', 'items'], `${label} instruction page`);
  assertExactKeys(routeBody.pagination, ['page', 'per_page', 'total_pages', 'total_items'], `${label} pagination`);
  if (!deepEqual(routeBody.pagination, { page: 0, per_page: 2, total_pages: 1, total_items: 1 })) {
    fail(`${label} transaction must resolve to one complete instruction page`);
  }
  if (!Array.isArray(routeBody.items) || routeBody.items.length !== 1) {
    fail(`${label} transaction must resolve to exactly one instruction record`);
  }
  const item = routeBody.items[0];
  assertExactKeys(
    item,
    ['authority', 'created_at', 'kind', 'box', 'transaction_hash', 'transaction_status', 'block', 'index'],
    `${label} instruction record`,
  );
  if (item.transaction_hash !== noPrefix(hash)) fail(`${label} instruction transaction hash mismatch`);
  if (item.transaction_status !== 'Committed') fail(`${label} instruction transaction_status must be Committed`);
  if (!Number.isSafeInteger(item.block) || item.block <= 0) fail(`${label} instruction block must be positive`);
  if (item.index !== 0) fail(`${label} instruction index must be zero`);
  return item;
}

function validateInstructionBox(item, expected, label) {
  assertExactKeys(item.box, ['encoded', 'json'], `${label} instruction box`);
  const box = item.box;
  if (typeof box.encoded !== 'string' || !ENCODED_INSTRUCTION_PATTERN.test(box.encoded)) {
    fail(`${label} instruction box encoded bytes must be canonical lowercase 0x-prefixed hex`);
  }
  assertExactKeys(box.json, ['kind', 'payload', 'wire_id', 'encoded'], `${label} instruction JSON`);
  if (box.json.encoded !== noPrefix(box.encoded)) fail(`${label} instruction encoded byte mirrors mismatch`);

  if (expected.kind === 'ApplySccpRouteGovernance') {
    if (item.kind !== 'ApplySccpRouteGovernance') fail(`${label} instruction kind mismatch`);
    if (box.encoded !== expected.encoded) fail(`${label} route governance action encoded bytes mismatch`);
    const expectedJson = {
      kind: 'Custom',
      payload: {
        variant: 'ApplySccpRouteGovernance',
        value: { wire_id: EXPECTED_APPLY_WIRE_ID, encoded: noPrefix(expected.encoded) },
      },
      wire_id: EXPECTED_APPLY_WIRE_ID,
      encoded: noPrefix(expected.encoded),
    };
    if (!deepEqual(box.json, expectedJson)) fail(`${label} route governance instruction JSON mismatch`);
    return;
  }

  if (item.kind !== 'Transfer') fail(`${label} instruction kind mismatch`);
  if (box.json.kind !== 'Transfer' || box.json.wire_id !== EXPECTED_TRANSFER_WIRE_ID) {
    fail(`${label} transfer instruction wire identity mismatch`);
  }
  if (!deepEqual(box.json.payload, expected.payload)) fail(`${label} instruction payload mismatch`);
}

function validateInstruction(item, expected, label) {
  if (item.authority !== expected.authority) fail(`${label} instruction authority mismatch`);
  if (item.created_at !== expected.createdAt) fail(`${label} instruction created_at mismatch`);
  validateInstructionBox(item, expected, label);
  return { block: item.block, createdAt: item.created_at };
}

function transferPayload(sourceAccount, destinationAccount, assetId, amount) {
  return {
    variant: 'Asset',
    value: {
      source: `${assetId}#${sourceAccount}`,
      destination: destinationAccount,
      object: amount,
    },
  };
}

async function verifyTransaction(hashValue, expected, label) {
  validateExpectedMetadata(expected.metadata, label);
  const hash = normalizeTxHash(hashValue, `${label} transaction hash`);
  const statusBody = await query(statusRequest(hash), hash, 'status', `${label} status`);
  const statusBlock = validateStatus(statusBody, hash, label);

  const txRequest = transactionRequest(hash);
  const txBody = await query(txRequest, hash, 'transaction', `${label} transaction`);
  const txReceipt = validateTransactionDetail(txBody, txRequest, hash, expected, label);

  const isiRequest = instructionRequest(hash);
  const instructionBody = await query(isiRequest, hash, 'instructions', `${label} instructions`);
  const item = extractInstruction(instructionBody, isiRequest, hash, label);
  const instructionReceipt = validateInstruction(item, expected, label);

  if (statusBlock !== txReceipt.block || statusBlock !== instructionReceipt.block) {
    fail(`${label} receipt block heights must match across status, transaction detail, and instruction`);
  }
  if (txReceipt.createdAt !== instructionReceipt.createdAt) {
    fail(`${label} receipt created_at must match across transaction detail and instruction`);
  }
  return { hash, block: statusBlock, createdAt: txReceipt.createdAt };
}

async function main() {
  ensureSelfTestConfinement();
  const manifest = parseJsonText(
    readBoundedFile(evidenceFile, MAX_ARTIFACT_BYTES, 'Nexus production evidence'),
    'Nexus production evidence',
  );
  if (!isRecord(manifest)) fail('Nexus production evidence must be an object');
  if (manifest.status !== 'ready' && manifest.releaseEnabled !== true) {
    console.log('[nexus-production-receipts] skipped=blocked');
    process.exit(0);
  }
  if (manifest.status !== 'ready' || manifest.releaseEnabled !== true) {
    fail('Nexus production receipt verification requires status=ready and releaseEnabled=true');
  }
  const requiredRouteCommit = expectedRouteCommit();
  if (
    manifest.routePublicationEvidence.length === 1 &&
    manifest.routePublicationEvidence[0].routeManifestCommit !== requiredRouteCommit
  ) {
    fail(
      `routePublicationEvidence[0].routeManifestCommit must match expected route manifest commit ${requiredRouteCommit}`,
    );
  }

  const artifacts = new Map();
  const verifiedPublications = [];
  for (let index = 0; index < manifest.routePublicationEvidence.length; index += 1) {
    const record = manifest.routePublicationEvidence[index];
    const label = `routePublicationEvidence[${index}]`;
    validateRouteActionHash(record.routeManifestHash, `${label}.routeManifestHash`);
    const artifact = selfTestReceiptsDir
      ? readSelfTestArtifact(record.routeManifestCommit)
      : readProductionArtifact(record.routeManifestCommit, record.routeManifestSourcePath);
    if (!SHA256_PATTERN.test(record.routeManifestHash) || record.routeManifestHash !== artifact.hash) {
      fail(`${label}.routeManifestHash must equal recomputed canonical route governance action hash ${artifact.hash}`);
    }
    artifacts.set(record.routeManifestHash, artifact);
    const receipt = await verifyTransaction(
      record.publicationTransactionHash,
      {
        authority: record.publicationAuthority,
        kind: artifact.instruction.kind,
        encoded: artifact.instruction.encoded,
        createdAt: record.publishedAt,
        metadata: {
          evidence_role: 'route-publication',
          route_governance_action_hash: record.routeManifestHash,
        },
      },
      label,
    );
    verifiedPublications.push({
      index,
      hash: record.routeManifestHash,
      commit: record.routeManifestCommit,
      block: receipt.block,
    });
  }

  const latestBlock = Math.max(...verifiedPublications.map((record) => record.block));
  const latestPublications = verifiedPublications.filter((record) => record.block === latestBlock);
  if (latestPublications.length !== 1) {
    fail('ready Nexus production evidence requires one unique latest route publication by ledger block height');
  }
  const latestRouteHash = latestPublications[0].hash;
  if (latestPublications[0].commit !== requiredRouteCommit) {
    fail(
      `routePublicationEvidence[${latestPublications[0].index}].routeManifestCommit must match expected route manifest commit ${requiredRouteCommit}`,
    );
  }

  for (let index = 0; index < manifest.routeCanaryEvidence.length; index += 1) {
    const record = manifest.routeCanaryEvidence[index];
    const label = `routeCanaryEvidence[${index}]`;
    validateRouteActionHash(record.publishedRouteManifestHash, `${label}.publishedRouteManifestHash`);
    if (!artifacts.has(record.publishedRouteManifestHash)) fail(`${label} references an unverified route governance action hash`);
    if (record.publishedRouteManifestHash !== latestRouteHash) {
      fail(`${label}.publishedRouteManifestHash must match ledger-latest route publication hash ${latestRouteHash}`);
    }
    const receipt = await verifyTransaction(
      record.routeCanaryTransactionHash,
      {
        authority: record.authority,
        kind: 'Transfer',
        createdAt: record.routeCanaryCheckedAt,
        metadata: {
          evidence_role: 'route-canary',
          route_governance_action_hash: record.publishedRouteManifestHash,
        },
        payload: transferPayload(record.sourceAccount, record.destinationAccount, record.assetId, record.amount),
      },
      label,
    );
    if (receipt.block <= latestBlock) {
      fail(`${label} ledger block must be after the ledger-latest route publication block ${latestBlock}`);
    }
  }

  for (let index = 0; index < manifest.walletSmokeEvidence.length; index += 1) {
    const record = manifest.walletSmokeEvidence[index];
    const label = `walletSmokeEvidence[${index}]`;
    validateRouteActionHash(record.routeManifestHash, `${label}.routeManifestHash`);
    validateWalletCommit(record.walletCommit, `${label}.walletCommit`);
    if (!artifacts.has(record.routeManifestHash)) fail(`${label} references an unverified route governance action hash`);
    if (record.routeManifestHash !== latestRouteHash) {
      fail(`${label}.routeManifestHash must match ledger-latest route publication hash ${latestRouteHash}`);
    }
    const receipt = await verifyTransaction(
      record.walletSmokeTransactionHash,
      {
        authority: record.sourceAccount,
        kind: 'Transfer',
        createdAt: record.walletSmokeSubmittedAt,
        metadata: {
          evidence_role: 'wallet-smoke',
          route_governance_action_hash: record.routeManifestHash,
          wallet_platform: record.platform,
          wallet_commit: record.walletCommit,
        },
        payload: transferPayload(record.sourceAccount, record.destinationAccount, record.assetId, record.amount),
      },
      label,
    );
    if (receipt.block <= latestBlock) {
      fail(`${label} ledger block must be after the ledger-latest route publication block ${latestBlock}`);
    }
  }

  console.log(
    `[nexus-production-receipts] verified publications=${manifest.routePublicationEvidence.length} canaries=${manifest.routeCanaryEvidence.length} walletSmokes=${manifest.walletSmokeEvidence.length} selfTest=${Boolean(selfTestReceiptsDir)}`,
  );
}

main().catch((error) => {
  const safeMessage = String(error?.message || error || 'unknown Nexus receipt verification failure')
    .replace(/[\u0000-\u001f\u007f]/gu, ' ')
    .slice(0, 700);
  console.error(`[nexus-production-receipts][error] ${safeMessage}`);
  process.exit(1);
});
