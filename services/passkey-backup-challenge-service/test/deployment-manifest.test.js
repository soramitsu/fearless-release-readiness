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
const ROLLBACK_CHECKLIST = 'docs/rollback-checklist.md';
const PUBLICATION_WORKFLOW = '.github/workflows/passkey-image-publish.yml';
const NODE_BASE_IMAGE = 'node:22-alpine@sha256:16e22a550f3863206a3f701448c45f7912c6896a62de43add43bb9c86130c3e2';

const requiredEnv = [
  ['NODE_ENV', 'production'],
  ['PORT', '8789'],
  ['PASSKEY_CREDENTIAL_STORE_FILE', '/data/passkey-backup/credentials.json'],
];

const escapeRegex = (value) => value.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
const readText = (root, relativePath) => readFileSync(join(root, relativePath), 'utf8');

function validateDeploymentManifest(root = process.cwd(), workspaceRoot = join(root, '..', '..')) {
  const dockerfile = readText(root, DOCKERFILE);
  const dockerignore = readText(root, DOCKERIGNORE);
  const productionCompose = readText(root, PRODUCTION_COMPOSE);
  const readme = readText(root, README);
  const productionDoc = readText(root, PRODUCTION_DOC);
  const releaseChecklist = readText(root, RELEASE_CHECKLIST);
  const rollbackChecklist = readText(root, ROLLBACK_CHECKLIST);
  const publicationWorkflow = readText(workspaceRoot, PUBLICATION_WORKFLOW);

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
  assert.match(dockerfile, /chmod\s+0700\s+\/data\/passkey-backup/i,
    'Dockerfile must make the credential volume private for its writer lease.');
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
    'image: "${PASSKEY_BACKUP_IMAGE_REPOSITORY:?Set the reviewed passkey image repository}@sha256:${PASSKEY_BACKUP_IMAGE_DIGEST:?Set the reviewed 64-character lowercase image digest}"',
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
  assert.doesNotMatch(productionCompose, /^\s*build:/m, 'Production compose must never build production source locally.');
  assert.doesNotMatch(
    productionCompose,
    /^\s*image:\s*[^\n]*:(?:latest|release)\b/m,
    'Production compose must never select a mutable latest or release tag.',
  );

  assert.match(publicationWorkflow, /^  workflow_dispatch:/m, 'Image publication must be manually dispatched.');
  assert.doesNotMatch(
    publicationWorkflow,
    /^  (?:pull_request|pull_request_target|push|schedule):/m,
    'Privileged image publication must not be triggered by pull requests, pushes, or schedules.',
  );
  const triggerBlock = /^on:\n([\s\S]*?)\npermissions:/m.exec(publicationWorkflow);
  assert.ok(triggerBlock, 'Publication workflow must define triggers before permissions.');
  assert.deepEqual(
    [...triggerBlock[1].matchAll(/^  ([a-z_]+):/gm)].map((match) => match[1]),
    ['workflow_dispatch'],
    'Publication workflow must expose only workflow_dispatch.',
  );
  const permissionBlock = /^    permissions:\n((?:      [^\n]+\n)+)    steps:/m.exec(publicationWorkflow);
  assert.ok(permissionBlock, 'Publication job must define explicit permissions.');
  assert.deepEqual(
    permissionBlock[1].trim().split(/\r?\n/).map((line) => line.trim()),
    ['contents: read', 'packages: write', 'id-token: write', 'attestations: write'],
    'Publication job permissions must be exactly the reviewed least-privilege set.',
  );
  const referencedSecrets = [...publicationWorkflow.matchAll(/\$\{\{\s*secrets\.([A-Za-z0-9_]+)\s*\}\}/g)].map(
    (match) => match[1],
  );
  assert.ok(
    referencedSecrets.length > 0 && referencedSecrets.every((name) => name === 'GITHUB_TOKEN'),
    'Publication workflow must consume only the job-scoped GITHUB_TOKEN.',
  );
  for (const requiredText of [
    'permissions: {}',
    "github.repository == 'soramitsu/fearless-release-readiness'",
    "github.ref == 'refs/heads/main'",
    'github.ref_protected == true',
    'REQUESTED_SOURCE_COMMIT: ${{ inputs.source_commit }}',
    '"$REQUESTED_SOURCE_COMMIT" != "$GITHUB_SHA"',
    'git ls-remote --exit-code origin refs/heads/main',
    'persist-credentials: false',
    'contents: read',
    'packages: write',
    'id-token: write',
    'attestations: write',
    'IMAGE_REPOSITORY: ghcr.io/soramitsu/fearless-passkey-backup',
    'Resolve an attestable prior publication',
    'gh attestation verify "oci://${IMAGE_REPOSITORY}@${existing_digest}"',
    '--source-digest "$GITHUB_SHA"',
    '--source-ref refs/heads/main',
    '--deny-self-hosted-runners',
    "if: steps.resume.outputs.resumed != 'true'",
    'PUBLISHED_DIGEST: ${{ steps.resume.outputs.digest || steps.build.outputs.digest }}',
    'platforms: linux/amd64,linux/arm64',
    'tags: ${{ env.IMAGE_REPOSITORY }}:staging-${{ github.run_id }}-${{ github.run_attempt }}',
    'push: true',
    'docker buildx imagetools inspect "$immutable_reference"',
    'subject-digest: ${{ steps.image.outputs.digest }}',
    'push-to-registry: true',
    'passkey-image-publication-${{ github.sha }}-${{ github.run_id }}-${{ github.run_attempt }}',
    'retention-days: 90',
    'source_tag="${IMAGE_REPOSITORY}:sha-${GITHUB_SHA}"',
    'Promote the immutable source tag',
    'refusing to overwrite source tag with a different digest',
    'source tag already points to the exact published digest',
    'attestationBundleSha256',
    'workflowRunUrl',
    'echo "- Source commit: \\`$GITHUB_SHA\\`"',
    'echo "- Immutable image: \\`$IMMUTABLE_REFERENCE\\`"',
    'echo "- Provenance: $ATTESTATION_URL"',
    'echo "- Evidence artifact digest: \\`$EVIDENCE_ARTIFACT_DIGEST\\`"',
  ]) {
    assert.match(
      publicationWorkflow,
      new RegExp(escapeRegex(requiredText)),
      `Publication workflow must mention ${requiredText}.`,
    );
  }
  for (const action of [
    'actions/checkout@34e114876b0b11c390a56381ad16ebd13914f8d5',
    'docker/setup-qemu-action@c7c53464625b32c7a7e944ae62b3e17d2b600130',
    'docker/setup-buildx-action@8d2750c68a42422c14e847fe6c8ac0403b4cbd6f',
    'docker/login-action@c94ce9fb468520275223c153574b00df6fe4bcc9',
    'docker/build-push-action@10e90e3645eae34f1e60eeb005ba3a3d33f178e8',
    'actions/attest-build-provenance@977bb373ede98d70efdf65b84cb5f73e068dcc2a',
    'actions/upload-artifact@ea165f8d65b6e75b540449e92b4886f43607fa02',
  ]) {
    assert.match(publicationWorkflow, new RegExp(escapeRegex(action)), `Publication workflow must pin ${action}.`);
  }
  for (const match of publicationWorkflow.matchAll(/^\s*uses:\s*[^\s#]+@([^\s#]+)/gm)) {
    assert.match(match[1], /^[0-9a-f]{40}$/, `Publication action ref must be an immutable lowercase SHA: ${match[0]}`);
  }
  assert.ok(
    publicationWorkflow.indexOf('Validate exact protected-main source') < publicationWorkflow.indexOf('Log in to GHCR'),
    'Protected-main source validation must run before registry authentication.',
  );
  assert.ok(
    publicationWorkflow.indexOf('Validate exact protected-main source') < publicationWorkflow.indexOf('Build and publish exact source'),
    'Protected-main source validation must run before executing the source build.',
  );
  assert.ok(
    publicationWorkflow.indexOf('Log in to GHCR') < publicationWorkflow.indexOf('Resolve an attestable prior publication') &&
      publicationWorkflow.indexOf('Resolve an attestable prior publication') < publicationWorkflow.indexOf('Build and publish exact source'),
    'A prior source tag must be registry-authenticated and provenance-verified before build resume.',
  );
  assert.equal(
    publicationWorkflow.lastIndexOf('      - name:'),
    publicationWorkflow.indexOf('      - name: Promote the immutable source tag'),
    'Immutable source-tag promotion must be the final workflow step.',
  );
  assert.equal(
    [...publicationWorkflow.matchAll(/^        if: steps\.resume\.outputs\.resumed != 'true'$/gm)].length,
    4,
    'Build, attestation, evidence creation, and evidence upload must all be skipped for a verified no-op resume.',
  );
  assert.doesNotMatch(
    publicationWorkflow,
    /(?:^|\s)(?:kubectl|helm|ssh|scp|rsync)\s|docker\s+(?:compose|service|stack)\b/i,
    'Image publication workflow must not contain deployment commands.',
  );
  assert.doesNotMatch(
    publicationWorkflow,
    /(?:tags:|source_tag=)[^\n]*:(?:latest|release)\b/i,
    'Image publication workflow must never create a mutable latest or release tag.',
  );

  for (const requiredText of [
    'last-known-good',
    'ghcr.io/soramitsu/fearless-passkey-backup@sha256:<64-lowercase-hex>',
    'gh attestation verify',
    'private, encrypted, storage-native pre-release snapshot',
    'private, encrypted, storage-native rollback-time snapshot',
    'Exactly one writer',
    'Never share the JSON file over NFS',
    'docker compose down -v',
    'docker volume rm',
    'credentials.json',
    'schema-v4',
    'signature counter',
    'empty owner tombstone',
    'resurrect a revoked credential',
    'docker compose -f docker-compose.production.yml up -d --no-build --no-deps',
    '/api/passkey-backup/v1/credentials/revoke-all',
    'before the encrypted Google Drive or CloudKit backup record is deleted',
    'If server revocation fails',
    'retain the recoverable cloud record',
  ]) {
    assert.match(
      rollbackChecklist,
      new RegExp(escapeRegex(requiredText).replaceAll(' ', '\\s+'), 'i'),
      `Rollback checklist must mention ${requiredText}.`,
    );
  }

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
    'gh workflow run passkey-image-publish.yml --repo soramitsu/fearless-release-readiness',
    '--ref main -f source_commit=<protected-main-commit>',
    'gh attestation verify',
    'ghcr.io/soramitsu/fearless-passkey-backup@sha256:<reviewed-image-digest>',
    'PASSKEY_BACKUP_IMAGE_REPOSITORY=ghcr.io/soramitsu/fearless-passkey-backup',
    'PASSKEY_BACKUP_IMAGE_DIGEST=<reviewed-64-lowercase-hex-without-sha256-prefix>',
    'docker compose -f docker-compose.production.yml config --quiet',
    'docker compose -f docker-compose.production.yml pull',
    'docker compose -f docker-compose.production.yml up -d --no-build',
    'docker run',
    '-v passkey-backup-data:/data/passkey-backup',
    'PASSKEY_ALLOWED_ORIGINS=https://fearlesswallet.io,https://backup.fearlesswallet.io',
    'PASSKEY_ANDROID_ALLOWED_ORIGIN',
    'android:apk-key-hash:',
    'PASSKEY_AUTHORIZATION_INTROSPECTION_URL',
    'PASSKEY_AUTHORIZATION_AUDIENCE=fearless-passkey-backup',
    'PASSKEY_TRUST_PROXY_HOPS=1',
    'PASSKEY_TRUSTED_PROXY_CIDRS',
    'rollback-checklist.md',
    'retained for 90 days',
    'retention-controlled public',
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
    'gh workflow run passkey-image-publish.yml --repo soramitsu/fearless-release-readiness --ref main -f source_commit=<protected-main-commit>',
    'gh attestation verify oci://ghcr.io/soramitsu/fearless-passkey-backup@sha256:<reviewed-image-digest>',
    'PASSKEY_BACKUP_IMAGE_REPOSITORY=ghcr.io/soramitsu/fearless-passkey-backup',
    'PASSKEY_BACKUP_IMAGE_DIGEST=<reviewed-64-lowercase-hex-without-sha256-prefix>',
    'docker compose -f docker-compose.production.yml config --quiet',
    'docker compose -f docker-compose.production.yml pull',
    'docker compose -f docker-compose.production.yml up -d --no-build',
    'PASSKEY_CREDENTIAL_STORE_FILE=/data/passkey-backup/credentials.json',
    '.credentials.json.writer-lease',
    'PASSKEY_ANDROID_ALLOWED_ORIGIN',
    'android:apk-key-hash:',
    'PASSKEY_AUTHORIZATION_INTROSPECTION_URL',
    'PASSKEY_TRUST_PROXY_HOPS=1',
    'PASSKEY_TRUSTED_PROXY_CIDRS',
    'stable Fearless wallet-owner subject',
    'schema-v4',
    'passkey.credentials.revoke-all',
    'empty owner tombstone',
    'server revoke-all first',
    'rollback-checklist.md',
    '90-day Actions artifact retention',
    'retention-controlled public',
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
  const workspaceRoot = mkdtempSync(join(tmpdir(), 'passkey-deployment-manifest-'));
  const root = join(workspaceRoot, 'services', 'passkey-backup-challenge-service');
  for (const [relativePath, content] of Object.entries(files)) {
    const destination = relativePath === PUBLICATION_WORKFLOW
      ? join(workspaceRoot, relativePath)
      : join(root, relativePath);
    mkdirSync(dirname(destination), { recursive: true });
    writeFileSync(destination, content);
  }
  return { root, workspaceRoot };
}

function assertRejectsFixture(files, expected) {
  const { root, workspaceRoot } = writeFixture(files);
  try {
    assert.throws(() => validateDeploymentManifest(root, workspaceRoot), expected);
  } finally {
    rmSync(workspaceRoot, { recursive: true, force: true });
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
    [ROLLBACK_CHECKLIST]: readText(process.cwd(), ROLLBACK_CHECKLIST),
    [PUBLICATION_WORKFLOW]: readText(join(process.cwd(), '..', '..'), PUBLICATION_WORKFLOW),
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
      [DOCKERFILE]: actualFiles[DOCKERFILE].replace('chmod 0700 /data/passkey-backup', 'chmod 0755 /data/passkey-backup'),
    },
    /Dockerfile must make the credential volume private/,
  );
  assertRejectsFixture(
    {
      ...actualFiles,
      [RELEASE_CHECKLIST]: actualFiles[RELEASE_CHECKLIST].replace('.credentials.json.writer-lease', 'unfenced-store'),
    },
    /Release checklist must mention \.credentials\.json\.writer-lease/,
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
      [PRODUCTION_COMPOSE]: actualFiles[PRODUCTION_COMPOSE].replace(
        'image: "${PASSKEY_BACKUP_IMAGE_REPOSITORY:?Set the reviewed passkey image repository}@sha256:${PASSKEY_BACKUP_IMAGE_DIGEST:?Set the reviewed 64-character lowercase image digest}"',
        'image: passkey-backup-challenge-service:release',
      ),
    },
    /Production compose must mention image:/,
  );
  assertRejectsFixture(
    {
      ...actualFiles,
      [PRODUCTION_COMPOSE]: actualFiles[PRODUCTION_COMPOSE].replace(
        'restart: unless-stopped',
        'build: .\n    restart: unless-stopped',
      ),
    },
    /Production compose must never build production source locally/,
  );
  assertRejectsFixture(
    {
      ...actualFiles,
      [PRODUCTION_DOC]: actualFiles[PRODUCTION_DOC].replace(
        'docker compose -f docker-compose.production.yml up -d --no-build',
        'docker compose up -d',
      ),
    },
    /Production docs must mention docker compose -f docker-compose\.production\.yml up -d --no-build/,
  );
  assertRejectsFixture(
    {
      ...actualFiles,
      [RELEASE_CHECKLIST]: actualFiles[RELEASE_CHECKLIST].replaceAll(
        'docker compose -f docker-compose.production.yml up -d --no-build',
        'docker compose up -d',
      ),
    },
    /Release checklist must mention docker compose -f docker-compose\.production\.yml up -d --no-build/,
  );
  assertRejectsFixture(
    {
      ...actualFiles,
      [PUBLICATION_WORKFLOW]: actualFiles[PUBLICATION_WORKFLOW].replace('  workflow_dispatch:', '  pull_request:'),
    },
    /Image publication must be manually dispatched/,
  );
  assertRejectsFixture(
    {
      ...actualFiles,
      [PUBLICATION_WORKFLOW]: actualFiles[PUBLICATION_WORKFLOW].replace('github.ref_protected == true', 'true'),
    },
    /Publication workflow must mention github\.ref_protected == true/,
  );
  assertRejectsFixture(
    {
      ...actualFiles,
      [PUBLICATION_WORKFLOW]: actualFiles[PUBLICATION_WORKFLOW].replace(
        '      contents: read',
        '      contents: read\n      pull-requests: write',
      ),
    },
    /permissions must be exactly the reviewed least-privilege set/,
  );
  assertRejectsFixture(
    {
      ...actualFiles,
      [PUBLICATION_WORKFLOW]: actualFiles[PUBLICATION_WORKFLOW].replace(
        'actions/checkout@34e114876b0b11c390a56381ad16ebd13914f8d5',
        'actions/checkout@v4',
      ),
    },
    /Publication workflow must pin actions\/checkout/,
  );
  assertRejectsFixture(
    {
      ...actualFiles,
      [PUBLICATION_WORKFLOW]: `${actualFiles[PUBLICATION_WORKFLOW]}\n# kubectl apply -f production.yml\n`,
    },
    /must not contain deployment commands/,
  );
  assertRejectsFixture(
    {
      ...actualFiles,
      [PUBLICATION_WORKFLOW]: actualFiles[PUBLICATION_WORKFLOW].replace(
        'source tag already points to the exact published digest',
        'source tag retry is rejected',
      ),
    },
    /Publication workflow must mention source tag already points to the exact published digest/,
  );
  assertRejectsFixture(
    {
      ...actualFiles,
      [PUBLICATION_WORKFLOW]: actualFiles[PUBLICATION_WORKFLOW].replace(
        '--source-digest "$GITHUB_SHA"',
        '--source-digest "$existing_digest"',
      ),
    },
    /Publication workflow must mention --source-digest "\$GITHUB_SHA"/,
  );
  assertRejectsFixture(
    {
      ...actualFiles,
      [PUBLICATION_WORKFLOW]: actualFiles[PUBLICATION_WORKFLOW].replace(
        "if: steps.resume.outputs.resumed != 'true'",
        'if: always()',
      ),
    },
    /must all be skipped for a verified no-op resume/,
  );
  assertRejectsFixture(
    {
      ...actualFiles,
      [PUBLICATION_WORKFLOW]: actualFiles[PUBLICATION_WORKFLOW].replace(
        'echo "- Source commit: \\`$GITHUB_SHA\\`"',
        "echo '- Source commit: `$GITHUB_SHA`'",
      ),
    },
    /Publication workflow must mention echo "- Source commit/,
  );
  assertRejectsFixture(
    {
      ...actualFiles,
      [ROLLBACK_CHECKLIST]: actualFiles[ROLLBACK_CHECKLIST].replace('docker compose down -v', 'docker compose down'),
    },
    /Rollback checklist must mention docker compose down -v/,
  );
  assertRejectsFixture(
    {
      ...actualFiles,
      [ROLLBACK_CHECKLIST]: actualFiles[ROLLBACK_CHECKLIST].replace(
        'If server revocation fails',
        'If cloud deletion fails',
      ),
    },
    /Rollback checklist must mention If server revocation fails/,
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
});
