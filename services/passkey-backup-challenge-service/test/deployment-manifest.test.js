import assert from 'node:assert/strict';
import { mkdtempSync, mkdirSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import test from 'node:test';

const DOCKERFILE = 'Dockerfile';
const DOCKERIGNORE = '.dockerignore';
const PRODUCTION_COMPOSE = 'docker-compose.production.yml';
const README = 'README.md';
const PRODUCTION_DOC = 'docs/production-deployment.md';
const RELEASE_CHECKLIST = 'docs/release-checklist.md';
const NODE_BASE_IMAGE = 'node:22-alpine@sha256:16e22a550f3863206a3f701448c45f7912c6896a62de43add43bb9c86130c3e2';

const requiredEnv = [
  ['NODE_ENV', 'production'],
  ['PORT', '8789'],
  ['PASSKEY_CREDENTIAL_STORE_FILE', '/data/passkey-backup/credentials.json'],
];

const escapeRegex = (value) => value.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
const readText = (root, relativePath) => readFileSync(join(root, relativePath), 'utf8');

function validateDeploymentManifest(root = process.cwd()) {
  const dockerfile = readText(root, DOCKERFILE);
  const dockerignore = readText(root, DOCKERIGNORE);
  const productionCompose = readText(root, PRODUCTION_COMPOSE);
  const readme = readText(root, README);
  const productionDoc = readText(root, PRODUCTION_DOC);
  const releaseChecklist = readText(root, RELEASE_CHECKLIST);

  assert.match(
    dockerfile,
    new RegExp(`FROM\\s+${escapeRegex(NODE_BASE_IMAGE)}(?:\\s|$)`, 'i'),
    'Dockerfile must pin the approved Node 22 Alpine runtime by immutable multi-architecture digest.',
  );
  assert.match(dockerfile, /COPY\s+package\.json\s+package-lock\.json\s+\.\//, 'Dockerfile must copy the lockfile.');
  assert.match(dockerfile, /npm\s+ci\s+--omit=dev\s+--ignore-scripts/, 'Dockerfile must install immutable production dependencies.');
  assert.doesNotMatch(dockerfile, /npm\s+install\b/, 'Dockerfile must not use mutable npm install.');
  assert.match(dockerfile, /\bUSER\s+node\b/i, 'Dockerfile must run as the bundled non-root node user.');
  assert.doesNotMatch(dockerfile, /\bUSER\s+root\b/i, 'Dockerfile must not run as root.');
  assert.match(dockerfile, /\bEXPOSE\s+8789\b/, 'Dockerfile must expose port 8789.');
  assert.match(
    dockerfile,
    /HEALTHCHECK[\s\S]+\/api\/passkey-backup\/v1\/health/i,
    'Dockerfile must healthcheck the passkey health route.',
  );
  for (const marker of [
    "body.ok === true",
    "body.service === 'fearless-passkey-backup'",
    "body.rpId === 'fearlesswallet.io'",
    'body.schemaVersion === 1',
  ]) {
    assert.ok(
      dockerfile.includes(marker),
      `Dockerfile healthcheck must validate strict service identity marker: ${marker}`,
    );
    assert.ok(
      productionCompose.includes(marker),
      `Compose healthcheck must validate strict service identity marker: ${marker}`,
    );
  }
  assert.match(
    dockerfile,
    /VOLUME\s+\[\s*"\/data\/passkey-backup"\s*\]/,
    'Dockerfile must declare the durable passkey data volume.',
  );
  assert.match(
    dockerfile,
    /mkdir\s+-p\s+\/data\/passkey-backup[\s\S]+chown\s+-R\s+node:node\s+\/data\/passkey-backup/i,
    'Dockerfile must create the durable data directory for the node user.',
  );
  assert.match(dockerfile, /CMD\s+\[\s*"node"\s*,\s*"src\/server\.js"\s*\]/, 'Dockerfile must start src/server.js.');

  for (const [key, value] of requiredEnv) {
    assert.match(
      dockerfile,
      new RegExp(`${key}\\s*=\\s*"?${escapeRegex(value)}"?`),
      `Dockerfile must set ${key}=${value}.`,
    );
    assert.match(
      productionCompose,
      new RegExp(`${key}:\\s*"?${escapeRegex(value)}"?`),
      `Production compose must set ${key}: ${value}.`,
    );
  }

  for (const requiredText of [
    'passkey-backup-challenge-service:',
    'dockerfile: Dockerfile',
    'image: passkey-backup-challenge-service:release',
    'restart: unless-stopped',
    'HOST: 0.0.0.0',
    'PASSKEY_ALLOWED_ORIGINS: https://fearlesswallet.io,https://backup.fearlesswallet.io',
    'PASSKEY_ANDROID_ALLOWED_ORIGIN: "${PASSKEY_ANDROID_ALLOWED_ORIGIN:?',
    'android:apk-key-hash:<unpadded-base64url-release-cert-sha256>',
    'PASSKEY_AUTHORIZATION_INTROSPECTION_URL: "${PASSKEY_AUTHORIZATION_INTROSPECTION_URL:?',
    'PASSKEY_AUTHORIZATION_AUDIENCE: fearless-passkey-backup',
    'PASSKEY_AUTHORIZATION_TIMEOUT_MS: "2000"',
    'PASSKEY_AUTHORIZATION_MAX_TTL_SECONDS: "300"',
    'PASSKEY_TRUST_PROXY_HOPS: "1"',
    'PASSKEY_TRUSTED_PROXY_CIDRS: "${PASSKEY_TRUSTED_PROXY_CIDRS:?',
    'PASSKEY_CHALLENGE_TTL_MS: "300000"',
    'PASSKEY_MAX_CEREMONIES: "10000"',
    'PASSKEY_RATE_LIMIT_WINDOW_MS: "60000"',
    'PASSKEY_RATE_LIMIT_MAX_REQUESTS: "120"',
    'PASSKEY_GLOBAL_RATE_LIMIT_MAX_REQUESTS: "5000"',
    '- "127.0.0.1:8789:8789"',
    '- passkey-backup-data:/data/passkey-backup',
    'read_only: true',
    'no-new-privileges:true',
    'pids_limit: 128',
    '- ALL',
    'http://127.0.0.1:8789/api/passkey-backup/v1/health',
    'passkey-backup-data:',
  ]) {
    assert.match(
      productionCompose,
      new RegExp(escapeRegex(requiredText)),
      `Production compose must mention ${requiredText}.`,
    );
  }
  assert.doesNotMatch(productionCompose, /privileged:\s*true/, 'Production compose must not run privileged.');
  assert.doesNotMatch(productionCompose, /\.env/, 'Production compose must not depend on an untracked env file.');

  const ignored = new Set(
    dockerignore
      .split(/\r?\n/)
      .map((line) => line.trim())
      .filter((line) => line.length > 0 && !line.startsWith('#')),
  );
  for (const pattern of ['.git', 'node_modules', 'coverage', '.env', '.env.*', 'test']) {
    assert.ok(ignored.has(pattern), `.dockerignore must exclude ${pattern}.`);
  }

  for (const requiredText of [
    'backup.fearlesswallet.io',
    'fearless-passkey-backup',
    'fearlesswallet.io',
    '/api/passkey-backup/v1/health',
    '/api/passkey-backup/v1/registration/challenge',
    '/api/passkey-backup/v1/assertion/complete',
    '/api/passkey-backup/v1/credentials/list',
    '/api/passkey-backup/v1/credentials/revoke-all',
    'PASSKEY_CREDENTIAL_STORE_FILE',
    'PASSKEY_ANDROID_ALLOWED_ORIGIN',
    'android:apk-key-hash:',
    'PASSKEY_AUTHORIZATION_INTROSPECTION_URL',
    'PASSKEY_AUTHORIZATION_AUDIENCE',
    'PASSKEY_TRUST_PROXY_HOPS',
    'PASSKEY_TRUSTED_PROXY_CIDRS',
    'PASSKEY_BACKUP_SMOKE_GRANT_HELPER',
    'stable Fearless wallet-ownership',
    'owner tombstone',
    'revoke all server credentials before deleting',
    '/data/passkey-backup',
  ]) {
    assert.match(readme, new RegExp(escapeRegex(requiredText)), `README must mention ${requiredText}.`);
    assert.match(productionDoc, new RegExp(escapeRegex(requiredText)), `Production docs must mention ${requiredText}.`);
  }

  for (const requiredText of [
    'docker build -t passkey-backup-challenge-service:release .',
    'docker compose -f docker-compose.production.yml up -d --build',
    'docker run',
    '-v passkey-backup-data:/data/passkey-backup',
    'PASSKEY_ALLOWED_ORIGINS=https://fearlesswallet.io,https://backup.fearlesswallet.io',
    'PASSKEY_ANDROID_ALLOWED_ORIGIN',
    'android:apk-key-hash:',
    'PASSKEY_AUTHORIZATION_INTROSPECTION_URL',
    'PASSKEY_AUTHORIZATION_AUDIENCE=fearless-passkey-backup',
    'PASSKEY_TRUST_PROXY_HOPS=1',
    'PASSKEY_TRUSTED_PROXY_CIDRS',
    'X-Forwarded-For',
    'PASSKEY_BACKUP_LIVE_HEALTH=1 PASSKEY_BACKUP_HEALTH_TIMEOUT_SECONDS=10',
    'PASSKEY_BACKUP_BASE_URL=https://backup.fearlesswallet.io',
    'PASSKEY_BACKUP_SMOKE_TIMEOUT_MS=10000 npm run smoke:production',
  ]) {
    assert.match(productionDoc, new RegExp(escapeRegex(requiredText)), `Production docs must mention ${requiredText}.`);
  }

  for (const requiredText of [
    'npm run lint:syntax',
    'npm test',
    'npm run audit:dependencies',
    'npm run test:deployment-evidence-template',
    'npm run generate:deployment-evidence-template -- --output build/reports/production-deployment-evidence-template.json',
    'npm run test:deployment-evidence-audit',
    'npm run audit:deployment-evidence',
    'PASSKEY_BACKUP_BASE_URL=https://backup.fearlesswallet.io PASSKEY_BACKUP_SMOKE_GRANT_HELPER=/run/secrets/passkey-smoke-grant-helper PASSKEY_BACKUP_SMOKE_TIMEOUT_MS=10000 npm run smoke:production',
    'bash ../../scripts/test-passkey-challenge-service-audit.sh',
    'bash ../../scripts/audit-passkey-challenge-service.sh',
    'docker build -t passkey-backup-challenge-service:release .',
    'docker compose -f docker-compose.production.yml up -d --build',
    'PASSKEY_CREDENTIAL_STORE_FILE=/data/passkey-backup/credentials.json',
    'PASSKEY_ANDROID_ALLOWED_ORIGIN',
    'android:apk-key-hash:',
    'PASSKEY_AUTHORIZATION_INTROSPECTION_URL',
    'PASSKEY_TRUST_PROXY_HOPS=1',
    'PASSKEY_TRUSTED_PROXY_CIDRS',
    'stable Fearless wallet-owner subject',
    'schema-v3',
    'passkey.credentials.revoke-all',
    'empty owner tombstone',
    'server revoke-all first',
    'PASSKEY_BACKUP_LIVE_HEALTH=1 PASSKEY_BACKUP_HEALTH_TIMEOUT_SECONDS=10',
    'scripts/production-deployment-evidence.json',
    'npm run audit:deployment-evidence -- --require-ready',
    'Android and iOS passkey backup release flags remain disabled',
  ]) {
    assert.match(
      releaseChecklist,
      new RegExp(escapeRegex(requiredText)),
      `Release checklist must mention ${requiredText}.`,
    );
  }
}

function writeFixture(files) {
  const root = mkdtempSync(join(tmpdir(), 'passkey-deployment-manifest-'));
  for (const [relativePath, content] of Object.entries(files)) {
    mkdirSync(dirname(join(root, relativePath)), { recursive: true });
    writeFileSync(join(root, relativePath), content);
  }
  return root;
}

function assertRejectsFixture(files, expected) {
  const root = writeFixture(files);
  try {
    assert.throws(() => validateDeploymentManifest(root), expected);
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
}

test('deployment manifest pins production container and release runbook contracts', () => {
  validateDeploymentManifest();
});

test('deployment manifest rejects adversarial production contract drift', () => {
  const actualFiles = {
    [DOCKERFILE]: readText(process.cwd(), DOCKERFILE),
    [DOCKERIGNORE]: readText(process.cwd(), DOCKERIGNORE),
    [PRODUCTION_COMPOSE]: readText(process.cwd(), PRODUCTION_COMPOSE),
    [README]: readText(process.cwd(), README),
    [PRODUCTION_DOC]: readText(process.cwd(), PRODUCTION_DOC),
    [RELEASE_CHECKLIST]: readText(process.cwd(), RELEASE_CHECKLIST),
  };

  assertRejectsFixture(
    {
      ...actualFiles,
      [DOCKERFILE]: actualFiles[DOCKERFILE].replace(NODE_BASE_IMAGE, 'node:22-alpine'),
    },
    /immutable multi-architecture digest/,
  );
  assertRejectsFixture(
    {
      ...actualFiles,
      [DOCKERFILE]: actualFiles[DOCKERFILE].replace(
        NODE_BASE_IMAGE,
        'node:22-alpine@sha256:06e22a550f3863206a3f701448c45f7912c6896a62de43add43bb9c86130c3e2',
      ),
    },
    /immutable multi-architecture digest/,
  );

  assertRejectsFixture(
    {
      ...actualFiles,
      [DOCKERFILE]: actualFiles[DOCKERFILE].replace('EXPOSE 8789', 'EXPOSE 8790'),
    },
    /Dockerfile must expose port 8789/,
  );
  assertRejectsFixture(
    {
      ...actualFiles,
      [DOCKERFILE]: actualFiles[DOCKERFILE].replace(
        "body.service === 'fearless-passkey-backup'",
        'true',
      ),
    },
    /Dockerfile healthcheck must validate strict service identity marker/,
  );
  assertRejectsFixture(
    {
      ...actualFiles,
      [PRODUCTION_COMPOSE]: actualFiles[PRODUCTION_COMPOSE].replace(
        "body.rpId === 'fearlesswallet.io'",
        'true',
      ),
    },
    /Compose healthcheck must validate strict service identity marker/,
  );
  assertRejectsFixture(
    {
      ...actualFiles,
      [DOCKERFILE]: actualFiles[DOCKERFILE].replace(
        'ENV PASSKEY_CREDENTIAL_STORE_FILE=/data/passkey-backup/credentials.json',
        'ENV PASSKEY_CREDENTIAL_STORE_FILE=/tmp/credentials.json',
      ),
    },
    /Dockerfile must set PASSKEY_CREDENTIAL_STORE_FILE=\/data\/passkey-backup\/credentials\.json/,
  );
  assertRejectsFixture(
    {
      ...actualFiles,
      [DOCKERFILE]: actualFiles[DOCKERFILE].replace('USER node', 'USER root'),
    },
    /Dockerfile must run as the bundled non-root node user/,
  );
  assertRejectsFixture(
    {
      ...actualFiles,
      [DOCKERIGNORE]: actualFiles[DOCKERIGNORE].replace(/^\.env\.\*\n/m, ''),
    },
    /\.dockerignore must exclude \.env\.\*/,
  );
  assertRejectsFixture(
    {
      ...actualFiles,
      [PRODUCTION_COMPOSE]: actualFiles[PRODUCTION_COMPOSE].replace('- "127.0.0.1:8789:8789"', '- "0.0.0.0:8789:8789"'),
    },
    /Production compose must mention - "127\.0\.0\.1:8789:8789"/,
  );
  assertRejectsFixture(
    {
      ...actualFiles,
      [DOCKERFILE]: actualFiles[DOCKERFILE].replace('npm ci --omit=dev --ignore-scripts', 'npm install'),
    },
    /Dockerfile must install immutable production dependencies/,
  );
  assertRejectsFixture(
    {
      ...actualFiles,
      [PRODUCTION_COMPOSE]: actualFiles[PRODUCTION_COMPOSE].replace('read_only: true', 'read_only: false'),
    },
    /Production compose must mention read_only: true/,
  );
  assertRejectsFixture(
    {
      ...actualFiles,
      [PRODUCTION_COMPOSE]: actualFiles[PRODUCTION_COMPOSE].replace('PASSKEY_RATE_LIMIT_MAX_REQUESTS: "120"', 'PASSKEY_RATE_LIMIT_MAX_REQUESTS: "0"'),
    },
    /Production compose must mention PASSKEY_RATE_LIMIT_MAX_REQUESTS: "120"/,
  );
  assertRejectsFixture(
    {
      ...actualFiles,
      [PRODUCTION_COMPOSE]: actualFiles[PRODUCTION_COMPOSE].replace(
        'PASSKEY_GLOBAL_RATE_LIMIT_MAX_REQUESTS: "5000"',
        'PASSKEY_GLOBAL_RATE_LIMIT_MAX_REQUESTS: "0"',
      ),
    },
    /Production compose must mention PASSKEY_GLOBAL_RATE_LIMIT_MAX_REQUESTS: "5000"/,
  );
  assertRejectsFixture(
    {
      ...actualFiles,
      [PRODUCTION_COMPOSE]: actualFiles[PRODUCTION_COMPOSE].replace(
        'PASSKEY_CREDENTIAL_STORE_FILE: /data/passkey-backup/credentials.json',
        'PASSKEY_CREDENTIAL_STORE_FILE: /tmp/credentials.json',
      ),
    },
    /Production compose must set PASSKEY_CREDENTIAL_STORE_FILE: \/data\/passkey-backup\/credentials\.json/,
  );
  assertRejectsFixture(
    {
      ...actualFiles,
      [PRODUCTION_COMPOSE]: actualFiles[PRODUCTION_COMPOSE].replace(
        'PASSKEY_ALLOWED_ORIGINS: https://fearlesswallet.io,https://backup.fearlesswallet.io',
        'PASSKEY_ALLOWED_ORIGINS: https://example.invalid',
      ),
    },
    /Production compose must mention PASSKEY_ALLOWED_ORIGINS: https:\/\/fearlesswallet\.io,https:\/\/backup\.fearlesswallet\.io/,
  );
  assertRejectsFixture(
    {
      ...actualFiles,
      [PRODUCTION_COMPOSE]: actualFiles[PRODUCTION_COMPOSE].replace(
        /^\s*PASSKEY_ANDROID_ALLOWED_ORIGIN:.*\n/m,
        '',
      ),
    },
    /Production compose must mention PASSKEY_ANDROID_ALLOWED_ORIGIN:/,
  );
  assertRejectsFixture(
    {
      ...actualFiles,
      [PRODUCTION_COMPOSE]: actualFiles[PRODUCTION_COMPOSE].replace(
        '${PASSKEY_ANDROID_ALLOWED_ORIGIN:?',
        '${PASSKEY_ANDROID_ALLOWED_ORIGIN:-',
      ),
    },
    /Production compose must mention PASSKEY_ANDROID_ALLOWED_ORIGIN: "\$\{PASSKEY_ANDROID_ALLOWED_ORIGIN:\?/,
  );
  assertRejectsFixture(
    {
      ...actualFiles,
      [PRODUCTION_COMPOSE]: actualFiles[PRODUCTION_COMPOSE].replace(
        /^\s*PASSKEY_AUTHORIZATION_INTROSPECTION_URL:.*\n/m,
        '',
      ),
    },
    /Production compose must mention PASSKEY_AUTHORIZATION_INTROSPECTION_URL:/,
  );
  assertRejectsFixture(
    {
      ...actualFiles,
      [PRODUCTION_COMPOSE]: actualFiles[PRODUCTION_COMPOSE].replace(
        '${PASSKEY_AUTHORIZATION_INTROSPECTION_URL:?',
        '${PASSKEY_AUTHORIZATION_INTROSPECTION_URL:-',
      ),
    },
    /Production compose must mention PASSKEY_AUTHORIZATION_INTROSPECTION_URL: "\$\{PASSKEY_AUTHORIZATION_INTROSPECTION_URL:\?/,
  );
  assertRejectsFixture(
    {
      ...actualFiles,
      [PRODUCTION_COMPOSE]: actualFiles[PRODUCTION_COMPOSE].replace(
        'PASSKEY_TRUST_PROXY_HOPS: "1"',
        'PASSKEY_TRUST_PROXY_HOPS: "0"',
      ),
    },
    /Production compose must mention PASSKEY_TRUST_PROXY_HOPS: "1"/,
  );
  assertRejectsFixture(
    {
      ...actualFiles,
      [PRODUCTION_COMPOSE]: actualFiles[PRODUCTION_COMPOSE].replace(
        /^\s*PASSKEY_TRUSTED_PROXY_CIDRS:.*\n/m,
        '',
      ),
    },
    /Production compose must mention PASSKEY_TRUSTED_PROXY_CIDRS:/,
  );
  assertRejectsFixture(
    {
      ...actualFiles,
      [PRODUCTION_COMPOSE]: `${actualFiles[PRODUCTION_COMPOSE]}\n    privileged: true\n`,
    },
    /Production compose must not run privileged/,
  );
  assertRejectsFixture(
    {
      ...actualFiles,
      [PRODUCTION_DOC]: actualFiles[PRODUCTION_DOC].replace(
        'docker compose -f docker-compose.production.yml up -d --build',
        'docker compose up -d',
      ),
    },
    /Production docs must mention docker compose -f docker-compose\.production\.yml up -d --build/,
  );
  assertRejectsFixture(
    {
      ...actualFiles,
      [RELEASE_CHECKLIST]: actualFiles[RELEASE_CHECKLIST].replaceAll(
        'docker compose -f docker-compose.production.yml up -d --build',
        'docker compose up -d',
      ),
    },
    /Release checklist must mention docker compose -f docker-compose\.production\.yml up -d --build/,
  );
  assertRejectsFixture(
    {
      ...actualFiles,
      [PRODUCTION_DOC]: actualFiles[PRODUCTION_DOC].replace(
        'PASSKEY_BACKUP_LIVE_HEALTH=1 PASSKEY_BACKUP_HEALTH_TIMEOUT_SECONDS=10',
        'PASSKEY_BACKUP_LIVE_HEALTH=0',
      ),
    },
    /Production docs must mention PASSKEY_BACKUP_LIVE_HEALTH=1 PASSKEY_BACKUP_HEALTH_TIMEOUT_SECONDS=10/,
  );
  assertRejectsFixture(
    {
      ...actualFiles,
      [RELEASE_CHECKLIST]: actualFiles[RELEASE_CHECKLIST].replaceAll(
        'PASSKEY_BACKUP_BASE_URL=https://backup.fearlesswallet.io PASSKEY_BACKUP_SMOKE_GRANT_HELPER=/run/secrets/passkey-smoke-grant-helper PASSKEY_BACKUP_SMOKE_TIMEOUT_MS=10000 npm run smoke:production',
        'curl https://backup.fearlesswallet.io/api/passkey-backup/v1/health',
      ),
    },
    /Release checklist must mention PASSKEY_BACKUP_BASE_URL=https:\/\/backup\.fearlesswallet\.io PASSKEY_BACKUP_SMOKE_GRANT_HELPER=\/run\/secrets\/passkey-smoke-grant-helper PASSKEY_BACKUP_SMOKE_TIMEOUT_MS=10000 npm run smoke:production/,
  );
  assertRejectsFixture(
    {
      ...actualFiles,
      [RELEASE_CHECKLIST]: actualFiles[RELEASE_CHECKLIST].replace(
        'docker build -t passkey-backup-challenge-service:release .',
        'npm start',
      ),
    },
    /Release checklist must mention docker build -t passkey-backup-challenge-service:release \./,
  );
});
