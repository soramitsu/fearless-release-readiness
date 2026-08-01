#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="${PASSKEY_CHALLENGE_SERVICE_AUDIT_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
SERVICE_DIR="${PASSKEY_CHALLENGE_SERVICE_DIR:-$ROOT_DIR/services/passkey-backup-challenge-service}"
SKIP_COMMANDS="${PASSKEY_CHALLENGE_SERVICE_AUDIT_SKIP_COMMANDS:-0}"

failures=()

log() { echo "[passkey-challenge-service-audit] $*"; }
warn() { echo "[passkey-challenge-service-audit][warn] $*" >&2; }

record_failure() {
  failures+=("$1")
  warn "$1"
}

require_file() {
  local file="$1"
  local description="$2"
  [[ -f "$file" ]] || record_failure "$description missing: $file"
}

require_pattern() {
  local file="$1"
  local pattern="$2"
  local description="$3"
  if [[ ! -f "$file" ]]; then
    return
  fi
  if ! grep -Eq -- "$pattern" "$file"; then
    record_failure "$description missing in $file"
  fi
}

run_command() {
  local description="$1"
  shift
  log "$description"
  if ! "$@"; then
    record_failure "$description failed"
  fi
}

check_package_contract() {
  local package_json="$SERVICE_DIR/package.json"
  local package_lock="$SERVICE_DIR/package-lock.json"
  require_file "$package_json" "passkey challenge service package.json"
  require_file "$package_lock" "passkey challenge service package lock"
  if [[ ! -f "$package_json" || ! -f "$package_lock" ]]; then
    return
  fi

  local output
  set +e
  output="$(
    PASSKEY_SERVICE_PACKAGE_JSON="$package_json" PASSKEY_SERVICE_PACKAGE_LOCK="$package_lock" node <<'NODE' 2>&1
const fs = require('fs');
const data = JSON.parse(fs.readFileSync(process.env.PASSKEY_SERVICE_PACKAGE_JSON, 'utf8'));
const lock = JSON.parse(fs.readFileSync(process.env.PASSKEY_SERVICE_PACKAGE_LOCK, 'utf8'));
function assert(condition, message) {
  if (!condition) throw new Error(message);
}
assert(data.type === 'module', 'package must be ESM');
assert(data.private === true, 'package must be private until deployment ownership is finalized');
assert(data.scripts?.start === 'node src/server.js', 'package start script must run src/server.js');
assert(data.scripts?.test === 'node --test', 'package test script must run node --test');
assert(data.scripts?.['audit:dependencies'] === 'npm audit --omit=dev', 'package audit:dependencies must audit production dependencies');
assert(String(data.scripts?.['lint:syntax'] || '').includes('node --check src/server.js'), 'package lint:syntax script must syntax-check server.js');
assert(String(data.scripts?.['lint:syntax'] || '').includes('src/authorization.js'), 'package lint:syntax script must syntax-check authorization.js');
assert(String(data.scripts?.['lint:syntax'] || '').includes('scripts/production-smoke.mjs'), 'package lint:syntax script must syntax-check production-smoke.mjs');
assert(String(data.scripts?.['lint:syntax'] || '').includes('test/authorization.test.js'), 'package lint:syntax script must syntax-check authorization tests');
assert(String(data.scripts?.['lint:syntax'] || '').includes('test/security-regression.test.js'), 'package lint:syntax script must syntax-check security regression tests');
assert(String(data.scripts?.['lint:syntax'] || '').includes('test/openapi-contract.test.js'), 'package lint:syntax script must syntax-check OpenAPI contract tests');
assert(String(data.scripts?.['lint:syntax'] || '').includes('test/deployment-manifest.test.js'), 'package lint:syntax script must syntax-check deployment-manifest.test.js');
assert(String(data.scripts?.['lint:syntax'] || '').includes('test/production-smoke.test.js'), 'package lint:syntax script must syntax-check production-smoke.test.js');
assert(String(data.scripts?.['lint:syntax'] || '').includes('test/webauthn-fixture.js'), 'package lint:syntax script must syntax-check the cryptographic WebAuthn fixture');
assert(data.scripts?.['smoke:production'] === 'node scripts/production-smoke.mjs', 'package smoke:production script must run the passkey production smoke');
assert(data.scripts?.['audit:deployment-evidence'] === 'bash scripts/audit-deployment-evidence.sh', 'package audit:deployment-evidence script must run the deployment evidence audit');
assert(data.scripts?.['generate:deployment-evidence-template'] === 'bash scripts/generate-deployment-evidence-template.sh', 'package generate:deployment-evidence-template script must run the deployment evidence template generator');
assert(data.scripts?.['test:deployment-evidence-audit'] === 'bash scripts/test-deployment-evidence-audit.sh', 'package test:deployment-evidence-audit script must run the deployment evidence audit self-test');
assert(data.scripts?.['test:deployment-evidence-template'] === 'bash scripts/test-deployment-evidence-template.sh', 'package test:deployment-evidence-template script must run the deployment evidence template self-test');
assert(String(data.engines?.node || '').includes('>=22'), 'package must require Node 22 or newer');
assert(data.dependencies?.['@simplewebauthn/server'] === '13.3.2', 'package must pin @simplewebauthn/server 13.3.2 exactly');
assert(lock.lockfileVersion === 3, 'package lock must use lockfileVersion 3');
assert(lock.packages?.['']?.dependencies?.['@simplewebauthn/server'] === '13.3.2', 'package lock must pin @simplewebauthn/server 13.3.2 exactly');
NODE
  )"
  local status=$?
  set -e

  if [[ "$status" -ne 0 ]]; then
    record_failure "passkey challenge service package contract invalid: $output"
  fi
}

check_files_and_markers() {
  require_file "$SERVICE_DIR/Dockerfile" "passkey challenge service Dockerfile"
  require_file "$SERVICE_DIR/docker-compose.production.yml" "passkey challenge service production Docker Compose contract"
  require_file "$SERVICE_DIR/.dockerignore" "passkey challenge service .dockerignore"
  require_file "$SERVICE_DIR/README.md" "passkey challenge service README"
  require_file "$SERVICE_DIR/docs/production-deployment.md" "passkey challenge service production deployment docs"
	  require_file "$SERVICE_DIR/docs/release-checklist.md" "passkey challenge service release checklist"
	  require_file "$SERVICE_DIR/scripts/production-deployment-evidence.json" "passkey challenge service production deployment evidence"
	  require_file "$SERVICE_DIR/scripts/audit-deployment-evidence.sh" "passkey challenge service deployment evidence audit"
	  require_file "$SERVICE_DIR/scripts/generate-deployment-evidence-template.sh" "passkey challenge service deployment evidence template generator"
	  require_file "$SERVICE_DIR/scripts/test-deployment-evidence-audit.sh" "passkey challenge service deployment evidence audit self-test"
	  require_file "$SERVICE_DIR/scripts/test-deployment-evidence-template.sh" "passkey challenge service deployment evidence template self-test"
	  require_file "$SERVICE_DIR/scripts/production-smoke.mjs" "passkey challenge service production smoke"
	  require_file "$SERVICE_DIR/src/base64url.js" "passkey challenge service base64url helper"
  require_file "$SERVICE_DIR/src/authorization.js" "passkey challenge service request authorization module"
  require_file "$SERVICE_DIR/src/errors.js" "passkey challenge service error helper"
  require_file "$SERVICE_DIR/src/validation.js" "passkey challenge service validation module"
  require_file "$SERVICE_DIR/src/store.js" "passkey challenge service ceremony store"
  require_file "$SERVICE_DIR/src/service.js" "passkey challenge service domain service"
  require_file "$SERVICE_DIR/src/server.js" "passkey challenge service HTTP server"
  require_file "$SERVICE_DIR/test/service.test.js" "passkey challenge service tests"
  require_file "$SERVICE_DIR/test/authorization.test.js" "passkey challenge service authorization tests"
  require_file "$SERVICE_DIR/test/security-regression.test.js" "passkey challenge service security regression tests"
  require_file "$SERVICE_DIR/test/openapi-contract.test.js" "passkey challenge service OpenAPI contract tests"
  require_file "$SERVICE_DIR/test/deployment-manifest.test.js" "passkey challenge service deployment manifest tests"
  require_file "$SERVICE_DIR/test/production-smoke.test.js" "passkey challenge service production smoke tests"
  require_file "$SERVICE_DIR/test/webauthn-fixture.js" "passkey challenge service cryptographic WebAuthn fixture"
  require_file "$ROOT_DIR/config/passkey-backup-challenge-service.openapi.json" "passkey challenge service OpenAPI contract"

  require_pattern "$SERVICE_DIR/Dockerfile" '^FROM node:22-alpine@sha256:16e22a550f3863206a3f701448c45f7912c6896a62de43add43bb9c86130c3e2$' "passkey challenge service immutable approved Node 22 container base"
  require_pattern "$SERVICE_DIR/Dockerfile" 'COPY package\.json package-lock\.json \./' "passkey challenge service immutable dependency inputs"
  require_pattern "$SERVICE_DIR/Dockerfile" 'npm ci --omit=dev --ignore-scripts' "passkey challenge service immutable production dependency install"
  require_pattern "$SERVICE_DIR/Dockerfile" 'USER node' "passkey challenge service non-root container user"
  require_pattern "$SERVICE_DIR/Dockerfile" 'HEALTHCHECK' "passkey challenge service container healthcheck"
  require_pattern "$SERVICE_DIR/Dockerfile" 'EXPOSE 8789' "passkey challenge service container port contract"
  require_pattern "$SERVICE_DIR/Dockerfile" 'PASSKEY_CREDENTIAL_STORE_FILE' "passkey challenge service durable credential file env"
  require_pattern "$SERVICE_DIR/Dockerfile" '/data/passkey-backup' "passkey challenge service durable credential data directory"
  require_pattern "$SERVICE_DIR/Dockerfile" 'VOLUME \["/data/passkey-backup"\]' "passkey challenge service durable credential volume"
  require_pattern "$SERVICE_DIR/Dockerfile" 'CMD \["node", "src/server\.js"\]' "passkey challenge service container start command"
  require_pattern "$SERVICE_DIR/docker-compose.production.yml" 'image: passkey-backup-challenge-service:release' "passkey challenge service production compose image"
  require_pattern "$SERVICE_DIR/docker-compose.production.yml" 'restart: unless-stopped' "passkey challenge service production compose restart policy"
  require_pattern "$SERVICE_DIR/docker-compose.production.yml" 'NODE_ENV: production' "passkey challenge service production compose NODE_ENV"
  require_pattern "$SERVICE_DIR/docker-compose.production.yml" 'PORT: "8789"' "passkey challenge service production compose port env"
  require_pattern "$SERVICE_DIR/docker-compose.production.yml" 'PASSKEY_ALLOWED_ORIGINS: https://fearlesswallet\.io,https://backup\.fearlesswallet\.io' "passkey challenge service production compose origins"
  require_pattern "$SERVICE_DIR/docker-compose.production.yml" 'PASSKEY_CREDENTIAL_STORE_FILE: /data/passkey-backup/credentials\.json' "passkey challenge service production compose credential file"
  require_pattern "$SERVICE_DIR/docker-compose.production.yml" '"127\.0\.0\.1:8789:8789"' "passkey challenge service loopback-only production compose port mapping"
  require_pattern "$SERVICE_DIR/docker-compose.production.yml" 'passkey-backup-data:/data/passkey-backup' "passkey challenge service production compose durable volume"
  require_pattern "$SERVICE_DIR/docker-compose.production.yml" 'PASSKEY_RATE_LIMIT_WINDOW_MS: "60000"' "passkey challenge service production compose rate-limit window"
  require_pattern "$SERVICE_DIR/docker-compose.production.yml" 'PASSKEY_RATE_LIMIT_MAX_REQUESTS: "120"' "passkey challenge service production compose rate-limit cap"
  require_pattern "$SERVICE_DIR/docker-compose.production.yml" 'PASSKEY_GLOBAL_RATE_LIMIT_MAX_REQUESTS: "5000"' "passkey challenge service production compose global rate-limit cap"
  require_pattern "$SERVICE_DIR/docker-compose.production.yml" 'PASSKEY_ANDROID_ALLOWED_ORIGIN:' "passkey challenge service production compose Android release origin"
  require_pattern "$SERVICE_DIR/docker-compose.production.yml" 'PASSKEY_AUTHORIZATION_INTROSPECTION_URL:' "passkey challenge service production compose authorization introspection endpoint"
  require_pattern "$SERVICE_DIR/docker-compose.production.yml" 'PASSKEY_AUTHORIZATION_AUDIENCE: fearless-passkey-backup' "passkey challenge service production compose authorization audience"
  require_pattern "$SERVICE_DIR/docker-compose.production.yml" 'PASSKEY_TRUST_PROXY_HOPS: "1"' "passkey challenge service production compose single trusted proxy hop"
  require_pattern "$SERVICE_DIR/docker-compose.production.yml" 'PASSKEY_TRUSTED_PROXY_CIDRS:' "passkey challenge service production compose direct proxy peer allowlist"
  require_pattern "$SERVICE_DIR/docker-compose.production.yml" 'read_only: true' "passkey challenge service read-only production root filesystem"
  require_pattern "$SERVICE_DIR/docker-compose.production.yml" 'cap_drop:' "passkey challenge service production capability drop"
  require_pattern "$SERVICE_DIR/docker-compose.production.yml" 'no-new-privileges:true' "passkey challenge service production no-new-privileges"
  require_pattern "$SERVICE_DIR/docker-compose.production.yml" 'pids_limit: 128' "passkey challenge service production PID limit"
  require_pattern "$SERVICE_DIR/docker-compose.production.yml" '/api/passkey-backup/v1/health' "passkey challenge service production compose healthcheck route"
  if grep -Eq 'privileged:[[:space:]]*true|\.env' "$SERVICE_DIR/docker-compose.production.yml"; then
    record_failure "passkey challenge service production compose must not enable privileged mode or depend on .env files"
  fi

  require_pattern "$SERVICE_DIR/.dockerignore" '^\.git$' "passkey challenge service Docker context excludes git metadata"
  require_pattern "$SERVICE_DIR/.dockerignore" '^node_modules$' "passkey challenge service Docker context excludes node_modules"
  require_pattern "$SERVICE_DIR/.dockerignore" '^\.env$' "passkey challenge service Docker context excludes env files"
  require_pattern "$SERVICE_DIR/.dockerignore" '^\.env\.\*$' "passkey challenge service Docker context excludes env variants"

  require_pattern "$SERVICE_DIR/README.md" 'PASSKEY_ALLOWED_ORIGINS' "passkey challenge service allowed origins docs"
  require_pattern "$SERVICE_DIR/README.md" 'PASSKEY_CHALLENGE_TTL_MS' "passkey challenge service TTL docs"
  require_pattern "$SERVICE_DIR/README.md" 'PASSKEY_CREDENTIAL_STORE_FILE' "passkey challenge service durable credential env docs"
  require_pattern "$SERVICE_DIR/README.md" '/data/passkey-backup' "passkey challenge service durable volume docs"
  require_pattern "$SERVICE_DIR/README.md" 'fearless-passkey-backup' "passkey challenge service health identity docs"
  require_pattern "$SERVICE_DIR/README.md" 'docs/production-deployment\.md' "passkey challenge service production deployment doc link"
  require_pattern "$SERVICE_DIR/README.md" 'docs/release-checklist\.md' "passkey challenge service release checklist doc link"
  require_pattern "$SERVICE_DIR/README.md" 'cryptographically verifies WebAuthn' "passkey challenge service cryptographic verification docs"
  require_pattern "$SERVICE_DIR/README.md" 'credential public keys, user handles, counters' "passkey challenge service persisted credential scope docs"
  require_pattern "$SERVICE_DIR/README.md" 'single-writer contract' "passkey challenge service persistence concurrency docs"
  require_pattern "$SERVICE_DIR/README.md" 'refuses to start in `NODE_ENV=production`' "passkey challenge service fail-closed production persistence docs"
  require_pattern "$SERVICE_DIR/README.md" 'PASSKEY_RATE_LIMIT_WINDOW_MS' "passkey challenge service rate-limit docs"
  require_pattern "$SERVICE_DIR/README.md" '/api/passkey-backup/v1/registration/challenge' "passkey challenge service registration endpoint docs"
  require_pattern "$SERVICE_DIR/README.md" '/api/passkey-backup/v1/assertion/complete' "passkey challenge service assertion endpoint docs"

  require_pattern "$SERVICE_DIR/docs/production-deployment.md" 'backup\.fearlesswallet\.io' "passkey challenge service production host docs"
  require_pattern "$SERVICE_DIR/docs/production-deployment.md" 'docker build -t passkey-backup-challenge-service:release \.' "passkey challenge service production Docker build docs"
  require_pattern "$SERVICE_DIR/docs/production-deployment.md" 'docker compose -f docker-compose\.production\.yml up -d --build' "passkey challenge service production compose deployment docs"
  require_pattern "$SERVICE_DIR/docs/production-deployment.md" 'docker run' "passkey challenge service production Docker run docs"
  require_pattern "$SERVICE_DIR/docs/production-deployment.md" 'PASSKEY_ALLOWED_ORIGINS=https://fearlesswallet\.io,https://backup\.fearlesswallet\.io' "passkey challenge service production origins docs"
	  require_pattern "$SERVICE_DIR/docs/production-deployment.md" 'PASSKEY_CREDENTIAL_STORE_FILE=/data/passkey-backup/credentials\.json' "passkey challenge service production credential store docs"
	  require_pattern "$SERVICE_DIR/docs/production-deployment.md" 'PASSKEY_BACKUP_LIVE_HEALTH=1 PASSKEY_BACKUP_HEALTH_TIMEOUT_SECONDS=10' "passkey challenge service live health smoke docs"
	  require_pattern "$SERVICE_DIR/docs/production-deployment.md" 'PASSKEY_BACKUP_BASE_URL=https://backup\.fearlesswallet\.io' "passkey challenge service production route smoke base URL docs"
	  require_pattern "$SERVICE_DIR/docs/production-deployment.md" 'PASSKEY_BACKUP_SMOKE_GRANT_HELPER=/run/secrets/passkey-smoke-grant-helper' "passkey challenge service authorized production route smoke docs"
	  require_pattern "$SERVICE_DIR/docs/production-deployment.md" 'PASSKEY_BACKUP_SMOKE_TIMEOUT_MS=10000 npm run smoke:production' "passkey challenge service production route smoke command docs"
	  require_pattern "$SERVICE_DIR/docs/production-deployment.md" 'PASSKEY_ANDROID_RELEASE_SIGNER_SHA256_FINGERPRINT=' "passkey challenge service signed Android release artifact evidence docs"
	  require_pattern "$SERVICE_DIR/docs/production-deployment.md" 'PASSKEY_ANDROID_RELEASE_SIGNER_EVIDENCE_SOURCE=' "passkey challenge service Android signer evidence-source docs"
	  require_pattern "$SERVICE_DIR/docs/production-deployment.md" 'distributed-apk' "passkey challenge service distributed APK signer source docs"
	  require_pattern "$SERVICE_DIR/docs/production-deployment.md" 'play-app-signing-certificate' "passkey challenge service Play app-signing signer source docs"
	  require_pattern "$SERVICE_DIR/docs/production-deployment.md" 'alone are never signer evidence' "passkey challenge service signer artifact requirement docs"
	  require_pattern "$SERVICE_DIR/docs/production-deployment.md" 'PASSKEY_ANDROID_DISTRIBUTED_APK_FILE' "passkey challenge service distributed APK path docs"
	  require_pattern "$SERVICE_DIR/docs/production-deployment.md" 'PASSKEY_ANDROID_PLAY_APP_SIGNING_ATTESTATION_FILE' "passkey challenge service Play attestation path docs"
	  require_pattern "$SERVICE_DIR/docs/production-deployment.md" 'PASSKEY_ANDROID_PLAY_APP_SIGNING_ATTESTATION_SHA256' "passkey challenge service Play attestation digest docs"
	  require_pattern "$SERVICE_DIR/docs/production-deployment.md" 'PASSKEY_ANDROID_PLAY_APP_SIGNING_CERTIFICATE_FILE' "passkey challenge service Play X.509 certificate docs"
	  require_pattern "$SERVICE_DIR/docs/production-deployment.md" 'PASSKEY_ANDROID_PLAY_APP_SIGNING_CERTIFICATE_SHA256' "passkey challenge service Play X.509 digest docs"
	  require_pattern "$SERVICE_DIR/docs/production-deployment.md" 'self-declared fingerprint' "passkey challenge service self-declared Play fingerprint rejection docs"
	  require_pattern "$SERVICE_DIR/docs/production-deployment.md" 'PASSKEY_ANDROID_RELEASE_ARTIFACT_SHA256' "passkey challenge service release artifact digest docs"
	  require_pattern "$SERVICE_DIR/docs/production-deployment.md" 'submitted release AAB, made read-only' "passkey challenge service immutable Play release artifact docs"
	  require_pattern "$SERVICE_DIR/docs/production-deployment.md" 'compiled AAB base manifest' "passkey challenge service AAB identity binding docs"
	  require_pattern "$SERVICE_DIR/docs/production-deployment.md" 'upload-key fingerprint on the submitted' "passkey challenge service Play app-signing certificate distinction docs"
	  require_pattern "$SERVICE_DIR/docs/production-deployment.md" 'audit-passkey-android-origin-parity\.sh --require-ready' "passkey challenge service Android origin parity ready command docs"
	  require_pattern "$SERVICE_DIR/docs/production-deployment.md" 'scripts/production-deployment-evidence\.json' "passkey challenge service deployment evidence docs"
	  require_pattern "$SERVICE_DIR/docs/production-deployment.md" 'generate:deployment-evidence-template -- --output build/reports/production-deployment-evidence-template\.json' "passkey challenge service deployment evidence template docs"
	  require_pattern "$SERVICE_DIR/docs/production-deployment.md" 'npm run audit:deployment-evidence -- --require-ready' "passkey challenge service deployment evidence ready docs"
	  require_pattern "$SERVICE_DIR/docs/production-deployment.md" 'no more than 24 hours old' "passkey challenge service ready evidence freshness docs"
	  require_pattern "$SERVICE_DIR/docs/production-deployment.md" 'liveHealthAttestation' "passkey challenge service live attestation binding docs"
	  require_pattern "$SERVICE_DIR/docs/production-deployment.md" 'platformProvisioningAttestation' "passkey challenge service platform attestation binding docs"
	  if grep -Eq -- '^[[:space:]]*npm run smoke:production[[:space:]]*$' "$SERVICE_DIR/docs/production-deployment.md"; then
	    record_failure "passkey challenge service production deployment docs must not recommend an unauthorized bare production smoke"
	  fi
	  require_pattern "$SERVICE_DIR/docs/release-checklist.md" 'docker build -t passkey-backup-challenge-service:release \.' "passkey challenge service release Docker build checklist"
	  require_pattern "$SERVICE_DIR/docs/release-checklist.md" 'docker compose -f docker-compose\.production\.yml up -d --build' "passkey challenge service release Docker Compose checklist"
	  require_pattern "$SERVICE_DIR/docs/release-checklist.md" 'PASSKEY_BACKUP_LIVE_HEALTH=1 PASSKEY_BACKUP_HEALTH_TIMEOUT_SECONDS=10' "passkey challenge service release live health checklist"
	  require_pattern "$SERVICE_DIR/docs/release-checklist.md" 'PASSKEY_BACKUP_BASE_URL=https://backup\.fearlesswallet\.io PASSKEY_BACKUP_SMOKE_GRANT_HELPER=/run/secrets/passkey-smoke-grant-helper PASSKEY_BACKUP_SMOKE_TIMEOUT_MS=10000 npm run smoke:production' "passkey challenge service authorized release route smoke checklist"
	  require_pattern "$SERVICE_DIR/docs/release-checklist.md" 'PASSKEY_ANDROID_RELEASE_SIGNER_SHA256_FINGERPRINT=' "passkey challenge service signed Android release artifact checklist"
	  require_pattern "$SERVICE_DIR/docs/release-checklist.md" 'PASSKEY_ANDROID_RELEASE_SIGNER_EVIDENCE_SOURCE=' "passkey challenge service Android signer evidence-source checklist"
	  require_pattern "$SERVICE_DIR/docs/release-checklist.md" 'distributed-apk' "passkey challenge service distributed APK signer source checklist"
	  require_pattern "$SERVICE_DIR/docs/release-checklist.md" 'play-app-signing-certificate' "passkey challenge service Play app-signing signer source checklist"
	  require_pattern "$SERVICE_DIR/docs/release-checklist.md" 'Expected fingerprint/source strings alone must fail' "passkey challenge service signer string-only rejection checklist"
	  require_pattern "$SERVICE_DIR/docs/release-checklist.md" 'PASSKEY_ANDROID_DISTRIBUTED_APK_FILE' "passkey challenge service distributed APK path checklist"
	  require_pattern "$SERVICE_DIR/docs/release-checklist.md" 'PASSKEY_ANDROID_PLAY_APP_SIGNING_ATTESTATION_FILE' "passkey challenge service Play attestation path checklist"
	  require_pattern "$SERVICE_DIR/docs/release-checklist.md" 'PASSKEY_ANDROID_PLAY_APP_SIGNING_CERTIFICATE_FILE' "passkey challenge service Play X.509 certificate checklist"
	  require_pattern "$SERVICE_DIR/docs/release-checklist.md" 'PASSKEY_ANDROID_RELEASE_ARTIFACT_FILE.*making it read-only' "passkey challenge service immutable Play release artifact checklist"
	  require_pattern "$SERVICE_DIR/docs/release-checklist.md" 'AAB upload-key fingerprint is not' "passkey challenge service Play app-signing certificate distinction checklist"
	  require_pattern "$SERVICE_DIR/docs/release-checklist.md" 'audit-passkey-android-origin-parity\.sh --require-ready' "passkey challenge service Android origin parity ready checklist"
	  require_pattern "$SERVICE_DIR/docs/release-checklist.md" 'Android and iOS passkey backup release flags remain disabled' "passkey challenge service mobile release flag checklist"
	  require_pattern "$SERVICE_DIR/docs/release-checklist.md" 'test:deployment-evidence-template' "passkey challenge service deployment evidence template self-test checklist"
	  require_pattern "$SERVICE_DIR/docs/release-checklist.md" 'generate:deployment-evidence-template -- --output' "passkey challenge service deployment evidence template generation checklist"
	  require_pattern "$SERVICE_DIR/docs/release-checklist.md" 'test:deployment-evidence-audit' "passkey challenge service deployment evidence self-test checklist"
	  require_pattern "$SERVICE_DIR/docs/release-checklist.md" 'audit:deployment-evidence -- --require-ready' "passkey challenge service deployment evidence ready checklist"
	  require_pattern "$SERVICE_DIR/docs/release-checklist.md" 'no more than 24 hours old' "passkey challenge service evidence freshness checklist"

	  require_pattern "$SERVICE_DIR/scripts/production-deployment-evidence.json" '"baseUrl":[[:space:]]*"https://backup\.fearlesswallet\.io"' "passkey challenge service deployment evidence production base URL"
	  require_pattern "$SERVICE_DIR/scripts/production-deployment-evidence.json" '"status":[[:space:]]*"blocked"' "passkey challenge service deployment evidence blocked state"
	  require_pattern "$SERVICE_DIR/scripts/production-deployment-evidence.json" '"releaseEnabled":[[:space:]]*false' "passkey challenge service deployment evidence release-disabled state"
	  require_pattern "$SERVICE_DIR/scripts/production-deployment-evidence.json" 'production-deployment-evidence-missing' "passkey challenge service deployment missing-evidence blocker"
	  require_pattern "$SERVICE_DIR/scripts/production-deployment-evidence.json" 'live-health-failing' "passkey challenge service deployment live health blocker"
	  require_pattern "$SERVICE_DIR/scripts/production-deployment-evidence.json" 'platform-provisioning-incomplete' "passkey challenge service platform provisioning blocker"
	  require_pattern "$SERVICE_DIR/scripts/production-deployment-evidence.json" 'imageDigest' "passkey challenge service deployment image digest field"
	  require_pattern "$SERVICE_DIR/scripts/production-deployment-evidence.json" 'deploymentId' "passkey challenge service deployment id field"
	  require_pattern "$SERVICE_DIR/scripts/production-deployment-evidence.json" 'smokePassedAt' "passkey challenge service live health timestamp field"
	  require_pattern "$SERVICE_DIR/scripts/production-deployment-evidence.json" 'liveHealthAttestation' "passkey challenge service live health attestation field"
	  require_pattern "$SERVICE_DIR/scripts/production-deployment-evidence.json" 'platformProvisioningAttestation' "passkey challenge service platform attestation field"
	  require_pattern "$SERVICE_DIR/scripts/production-deployment-evidence.json" 'npm run test:deployment-evidence-template' "passkey challenge service deployment evidence template self-test command"
	  require_pattern "$SERVICE_DIR/scripts/production-deployment-evidence.json" 'npm run generate:deployment-evidence-template -- --output build/reports/production-deployment-evidence-template\.json' "passkey challenge service deployment evidence template generator command"
	  require_pattern "$SERVICE_DIR/scripts/production-deployment-evidence.json" 'PASSKEY_BACKUP_BASE_URL=https://backup\.fearlesswallet\.io PASSKEY_BACKUP_SMOKE_GRANT_HELPER=/run/secrets/passkey-smoke-grant-helper PASSKEY_BACKUP_SMOKE_TIMEOUT_MS=10000 npm run smoke:production' "passkey challenge service authorized deployment production route smoke command"
	  require_pattern "$SERVICE_DIR/scripts/audit-deployment-evidence.sh" 'releaseEnabled must remain false while deployment evidence is blocked' "passkey challenge service blocked deployment release gate"
	  require_pattern "$SERVICE_DIR/scripts/audit-deployment-evidence.sh" 'ready deployment evidence requires at least one successful live production smoke record' "passkey challenge service ready deployment evidence gate"
	  require_pattern "$SERVICE_DIR/scripts/audit-deployment-evidence.sh" 'imageDigest.*sha256 image digest' "passkey challenge service image digest audit gate"
	  require_pattern "$SERVICE_DIR/scripts/audit-deployment-evidence.sh" 'smokePassedAt.*ISO-8601 UTC second timestamp' "passkey challenge service smoke timestamp audit gate"
	  require_pattern "$SERVICE_DIR/scripts/audit-deployment-evidence.sh" 'deployedAt.*not be in the future' "passkey challenge service future deployment timestamp gate"
	  require_pattern "$SERVICE_DIR/scripts/audit-deployment-evidence.sh" 'smokePassedAt.*not be in the future' "passkey challenge service future smoke timestamp gate"
	  require_pattern "$SERVICE_DIR/scripts/audit-deployment-evidence.sh" 'smokePassedAt must be at or after deployedAt' "passkey challenge service deployment timestamp ordering gate"
	  require_pattern "$SERVICE_DIR/scripts/audit-deployment-evidence.sh" 'smokePassedAt must be no more than 24 hours old for ready evidence' "passkey challenge service ready evidence freshness gate"
	  require_pattern "$SERVICE_DIR/scripts/audit-deployment-evidence.sh" 'blocked deployment evidence must keep deploymentEvidence empty' "passkey challenge service blocked evidence emptiness gate"
	  require_pattern "$SERVICE_DIR/scripts/audit-deployment-evidence.sh" 'record\.liveHealthAttestation' "passkey challenge service live attestation binding gate"
	  require_pattern "$SERVICE_DIR/scripts/audit-deployment-evidence.sh" 'record\.platformProvisioningAttestation' "passkey challenge service platform attestation binding gate"
	  require_pattern "$SERVICE_DIR/scripts/audit-deployment-evidence.sh" 'payloadSha256 must match the canonical attested payload' "passkey challenge service attestation payload digest gate"
	  require_pattern "$SERVICE_DIR/scripts/audit-deployment-evidence.sh" 'production route smoke command' "passkey challenge service route smoke evidence gate"
	  require_pattern "$SERVICE_DIR/scripts/audit-deployment-evidence.sh" 'must not be included in public deployment evidence' "passkey challenge service public evidence secret-leak gate"
	  require_pattern "$SERVICE_DIR/scripts/audit-deployment-evidence.sh" 'assertNoSecretLikeValues\(data\)' "passkey challenge service deployment secret-like value gate"
	  require_pattern "$SERVICE_DIR/scripts/test-deployment-evidence-audit.sh" 'release enabled while blocked' "passkey challenge service blocked deployment negative test"
	  require_pattern "$SERVICE_DIR/scripts/test-deployment-evidence-audit.sh" 'ready evidence without live smoke' "passkey challenge service missing live smoke negative test"
	  require_pattern "$SERVICE_DIR/scripts/test-deployment-evidence-audit.sh" 'bad image digest evidence' "passkey challenge service bad image digest negative test"
	  require_pattern "$SERVICE_DIR/scripts/test-deployment-evidence-audit.sh" 'wrong production smoke command evidence' "passkey challenge service wrong smoke command negative test"
	  require_pattern "$SERVICE_DIR/scripts/test-deployment-evidence-audit.sh" 'future deployment timestamp evidence' "passkey challenge service future deployment timestamp negative test"
	  require_pattern "$SERVICE_DIR/scripts/test-deployment-evidence-audit.sh" 'future smoke timestamp evidence' "passkey challenge service future smoke timestamp negative test"
	  require_pattern "$SERVICE_DIR/scripts/test-deployment-evidence-audit.sh" 'exact 24-hour ready evidence boundary' "passkey challenge service exact freshness boundary test"
	  require_pattern "$SERVICE_DIR/scripts/test-deployment-evidence-audit.sh" 'fresh record cannot mask stale second deployment' "passkey challenge service multiple-record freshness negative test"
	  require_pattern "$SERVICE_DIR/scripts/test-deployment-evidence-audit.sh" 'cross-deployment live health attestation substitution' "passkey challenge service cross-deployment attestation negative test"
	  require_pattern "$SERVICE_DIR/scripts/test-deployment-evidence-audit.sh" 'forged payload digest' "passkey challenge service attestation payload negative test"
	  require_pattern "$SERVICE_DIR/scripts/test-deployment-evidence-audit.sh" 'smoke before deployment evidence' "passkey challenge service timestamp-order negative test"
	  require_pattern "$SERVICE_DIR/scripts/test-deployment-evidence-audit.sh" 'secret-like deployment evidence key' "passkey challenge service secret-like evidence negative test"
	  require_pattern "$SERVICE_DIR/scripts/test-deployment-evidence-audit.sh" 'secret-like deployment evidence value' "passkey challenge service secret-like value negative test"
	  require_pattern "$SERVICE_DIR/scripts/test-deployment-evidence-audit.sh" 'missing deployment evidence template command' "passkey challenge service missing template command negative test"
	  require_pattern "$SERVICE_DIR/scripts/generate-deployment-evidence-template.sh" 'TODO_64_HEX_IMAGE_DIGEST' "passkey challenge service deployment evidence template image digest placeholder"
	  require_pattern "$SERVICE_DIR/scripts/generate-deployment-evidence-template.sh" 'TODO_40_HEX_GIT_COMMIT' "passkey challenge service deployment evidence template commit placeholder"
	  require_pattern "$SERVICE_DIR/scripts/generate-deployment-evidence-template.sh" 'platformProvisioning' "passkey challenge service deployment evidence template platform provisioning target"
	  require_pattern "$SERVICE_DIR/scripts/generate-deployment-evidence-template.sh" 'TODO_CANONICAL_HEALTH_RESPONSE_SHA256' "passkey challenge service live attestation digest template"
	  require_pattern "$SERVICE_DIR/scripts/generate-deployment-evidence-template.sh" 'TODO_CANONICAL_PLATFORM_PROVISIONING_SHA256' "passkey challenge service platform attestation digest template"
	  require_pattern "$SERVICE_DIR/scripts/generate-deployment-evidence-template.sh" 'must not be read from public deployment evidence manifest' "passkey challenge service deployment evidence template secret-like manifest gate"
	  require_pattern "$SERVICE_DIR/scripts/test-deployment-evidence-template.sh" 'template cannot pass ready audit with TODO placeholders' "passkey challenge service deployment evidence template ready-audit negative test"
	  require_pattern "$SERVICE_DIR/scripts/test-deployment-evidence-template.sh" 'unsupported evidence field' "passkey challenge service deployment evidence template unsupported-field negative test"
	  require_pattern "$SERVICE_DIR/scripts/test-deployment-evidence-template.sh" 'secret-like manifest key' "passkey challenge service deployment evidence template secret-like manifest negative test"
	  require_pattern "$SERVICE_DIR/scripts/test-deployment-evidence-template.sh" 'nested secret-like manifest key' "passkey challenge service deployment evidence template nested-secret negative test"
	  require_pattern "$SERVICE_DIR/scripts/test-deployment-evidence-template.sh" 'liveHealthAttestation' "passkey challenge service live attestation template self-test"
	  require_pattern "$SERVICE_DIR/scripts/test-deployment-evidence-template.sh" 'missing template generator command' "passkey challenge service deployment evidence template command negative test"
	  require_pattern "$SERVICE_DIR/scripts/production-smoke.mjs" 'registrationChallenge' "passkey challenge service production smoke registration challenge route"
	  require_pattern "$SERVICE_DIR/scripts/production-smoke.mjs" 'assertionChallenge' "passkey challenge service production smoke assertion challenge route"
	  require_pattern "$SERVICE_DIR/scripts/production-smoke.mjs" 'registrationComplete' "passkey challenge service production smoke registration complete route"
	  require_pattern "$SERVICE_DIR/scripts/production-smoke.mjs" 'assertionComplete' "passkey challenge service production smoke assertion complete route"
	  require_pattern "$SERVICE_DIR/scripts/production-smoke.mjs" 'credential_not_registered' "passkey challenge service production smoke unregistered assertion contract"
	  require_pattern "$SERVICE_DIR/scripts/production-smoke.mjs" 'unknown_or_expired_registration' "passkey challenge service production smoke registration completion contract"
	  require_pattern "$SERVICE_DIR/scripts/production-smoke.mjs" 'unknown_or_expired_assertion' "passkey challenge service production smoke assertion completion contract"
	  require_pattern "$SERVICE_DIR/scripts/production-smoke.mjs" 'contains unsupported field' "passkey challenge service production smoke response allow-list"
	  require_pattern "$SERVICE_DIR/scripts/production-smoke.mjs" 'formatFailureCause' "passkey challenge service production smoke fetch-cause diagnostic"
	  require_pattern "$SERVICE_DIR/scripts/production-smoke.mjs" 'DNS/TLS/routing' "passkey challenge service production smoke network failure deployment hint"
	  require_pattern "$SERVICE_DIR/scripts/production-smoke.mjs" 'deploy services/passkey-backup-challenge-service' "passkey challenge service production smoke deploy-current-service hint"
	  require_pattern "$SERVICE_DIR/scripts/production-smoke.mjs" 'PASSKEY_BACKUP_SMOKE_GRANT_HELPER' "passkey challenge service authorized smoke helper"
	  require_pattern "$SERVICE_DIR/scripts/production-smoke.mjs" 'realpathSync\.native' "passkey challenge service smoke helper canonical path gate"
	  require_pattern "$SERVICE_DIR/scripts/production-smoke.mjs" 'stat\.mode.*0o022' "passkey challenge service smoke helper writable-file gate"
	  require_pattern "$SERVICE_DIR/test/production-smoke.test.js" 'configured grant helper is missing' "passkey challenge service missing smoke helper negative test"
	  require_pattern "$SERVICE_DIR/test/production-smoke.test.js" 'group- or world-writable' "passkey challenge service writable smoke helper negative test"
	  require_pattern "$SERVICE_DIR/test/production-smoke.test.js" 'extra output, and timeout' "passkey challenge service failing smoke helper negative tests"
	  require_pattern "$SERVICE_DIR/scripts/production-smoke.mjs" 'isCanonicalBase64Url32' "passkey challenge service smoke canonical 32-byte challenge gate"

  require_pattern "$SERVICE_DIR/src/authorization.js" 'passkey\.registration\.challenge' "passkey challenge service route-scoped authorization"
  require_pattern "$SERVICE_DIR/src/authorization.js" 'authorization-subject\\0' "passkey challenge service domain-separated authorization subject hash"
  require_pattern "$SERVICE_DIR/src/authorization.js" "redirect: 'error'" "passkey challenge service authorization redirect rejection"
  require_pattern "$SERVICE_DIR/src/authorization.js" "value\.includes\('%'\)" "passkey challenge service canonical introspection URL gate"

  require_pattern "$SERVICE_DIR/src/validation.js" 'clientDataJSON' "passkey challenge service clientDataJSON validation"
  require_pattern "$SERVICE_DIR/src/validation.js" 'challenge_mismatch' "passkey challenge service challenge mismatch rejection"
  require_pattern "$SERVICE_DIR/src/validation.js" 'origin_not_allowed' "passkey challenge service origin allow-list rejection"
  require_pattern "$SERVICE_DIR/src/validation.js" 'PASSKEY_ALLOWED_ORIGINS must not contain credentials' "passkey challenge service configured origin credential rejection"
  require_pattern "$SERVICE_DIR/src/validation.js" 'PASSKEY_ALLOWED_ORIGINS must not contain query strings or fragments' "passkey challenge service configured origin query-fragment rejection"
  require_pattern "$SERVICE_DIR/src/validation.js" 'PASSKEY_ALLOWED_ORIGINS must use HTTPS outside localhost' "passkey challenge service configured origin HTTPS gate"
  require_pattern "$SERVICE_DIR/src/validation.js" 'credential_type_mismatch' "passkey challenge service WebAuthn ceremony type rejection"
  require_pattern "$SERVICE_DIR/src/validation.js" 'attestationObject' "passkey challenge service registration attestation validation"
  require_pattern "$SERVICE_DIR/src/validation.js" 'authenticatorData' "passkey challenge service authenticator-data validation"
  require_pattern "$SERVICE_DIR/src/validation.js" 'signature' "passkey challenge service assertion signature validation"
  require_pattern "$SERVICE_DIR/src/validation.js" 'credential\.id and credential\.rawId must identify the same credential' "passkey challenge service raw credential ID binding"
  require_pattern "$SERVICE_DIR/src/validation.js" 'cross_origin_not_allowed' "passkey challenge service cross-origin ceremony rejection"
  require_pattern "$SERVICE_DIR/src/validation.js" 'SUPPORTED_CREDENTIAL_ALGORITHMS' "passkey challenge service credential algorithm allow-list"
  require_pattern "$SERVICE_DIR/src/service.js" 'webauthn\.create' "passkey challenge service registration WebAuthn type check"
  require_pattern "$SERVICE_DIR/src/service.js" 'webauthn\.get' "passkey challenge service assertion WebAuthn type check"
  require_pattern "$SERVICE_DIR/src/service.js" 'verifyRegistrationResponse' "passkey challenge service registration cryptographic verifier"
  require_pattern "$SERVICE_DIR/src/service.js" 'verifyAuthenticationResponse' "passkey challenge service assertion cryptographic verifier"
  require_pattern "$SERVICE_DIR/src/service.js" 'requireUserVerification: true' "passkey challenge service mandatory user verification"
  require_pattern "$SERVICE_DIR/src/service.js" 'expectedRPID: RP_ID' "passkey challenge service RP-ID binding"
  require_pattern "$SERVICE_DIR/src/service.js" 'credential_user_mismatch' "passkey challenge service user-handle ownership binding"
  require_pattern "$SERVICE_DIR/src/service.js" 'updateCredentialAfterAuthentication' "passkey challenge service authenticator counter persistence"
  require_pattern "$SERVICE_DIR/src/service.js" 'supportedAlgorithmIDs: \[-7, -257\]' "passkey challenge service explicitly verified ES256 and RS256 algorithms"
  require_pattern "$SERVICE_DIR/src/service.js" 'authorizationPlatform' "passkey challenge service ceremony platform authorization binding"
  require_pattern "$SERVICE_DIR/src/service.js" 'ownerSubjectHash' "passkey challenge service stable owner authorization binding"
  require_pattern "$SERVICE_DIR/src/service.js" 'consumeRegistration' "passkey challenge service one-time registration ceremony consumption"
  require_pattern "$SERVICE_DIR/src/service.js" 'consumeAssertion' "passkey challenge service one-time assertion ceremony consumption"
  require_pattern "$SERVICE_DIR/src/service.js" 'credential_not_registered' "passkey challenge service unregistered credential rejection"
  require_pattern "$SERVICE_DIR/src/store.js" 'class FileBackedPasskeyChallengeStore' "passkey challenge service durable credential store"
  require_pattern "$SERVICE_DIR/src/store.js" 'schemaVersion' "passkey challenge service credential store schema version"
  require_pattern "$SERVICE_DIR/src/store.js" 'credentialsByStorageKey' "passkey challenge service credential store storage-key map"
  require_pattern "$SERVICE_DIR/src/store.js" 'CREDENTIAL_STORE_SCHEMA_VERSION = 3' "passkey challenge service credential store schema-v3"
  require_pattern "$SERVICE_DIR/src/store.js" 'ownerSubjectHash' "passkey challenge service persisted owner-subject binding"
  require_pattern "$SERVICE_DIR/src/store.js" ''"'"'aaguid'"'"'' "passkey challenge service persisted credential AAGUID"
  require_pattern "$SERVICE_DIR/src/store.js" ''"'"'registrationPlatform'"'"'' "passkey challenge service persisted registration platform"
  require_pattern "$SERVICE_DIR/src/store.js" 'credential_counter_replay' "passkey challenge service monotonic authenticator counter gate"
  require_pattern "$SERVICE_DIR/src/store.js" 'isSymbolicLink' "passkey challenge service symlink credential-store rejection"
  require_pattern "$SERVICE_DIR/src/store.js" 'O_NOFOLLOW' "passkey challenge service no-follow credential-store read"
  require_pattern "$SERVICE_DIR/src/store.js" 'fsyncSync' "passkey challenge service durable credential-store write"
  require_pattern "$SERVICE_DIR/src/store.js" 'credential_store_invalid' "passkey challenge service corrupt credential store rejection"
  require_pattern "$SERVICE_DIR/src/store.js" 'credential_store_unavailable' "passkey challenge service unavailable credential store rejection"
  require_pattern "$SERVICE_DIR/src/store.js" 'renameSync' "passkey challenge service atomic credential store write"
  require_pattern "$SERVICE_DIR/src/store.js" 'createPasskeyChallengeStore' "passkey challenge service credential store factory"
  require_pattern "$SERVICE_DIR/src/store.js" 'requireDurable' "passkey challenge service fail-closed production durable-store gate"
  require_pattern "$SERVICE_DIR/src/store.js" 'cleanupExpired' "passkey challenge service expired ceremony cleanup"
  require_pattern "$SERVICE_DIR/src/server.js" 'PASSKEY_CREDENTIAL_STORE_FILE' "passkey challenge service server durable credential env"
  require_pattern "$SERVICE_DIR/src/server.js" 'payload_too_large' "passkey challenge service oversized HTTP body rejection"
  require_pattern "$SERVICE_DIR/src/server.js" 'unsupported_media_type' "passkey challenge service content-type rejection"
  require_pattern "$SERVICE_DIR/src/server.js" 'method_not_allowed' "passkey challenge service method rejection"
  require_pattern "$SERVICE_DIR/src/server.js" 'rate_limit_exceeded' "passkey challenge service request rate limiting"
  require_pattern "$SERVICE_DIR/src/server.js" 'PASSKEY_GLOBAL_RATE_LIMIT_MAX_REQUESTS' "passkey challenge service global request rate limiting"
  require_pattern "$SERVICE_DIR/src/server.js" 'createRequestAuthorizerFromEnvironment' "passkey challenge service request authorization startup gate"
  require_pattern "$SERVICE_DIR/src/server.js" 'sha256Base64Url\(rawBody\)' "passkey challenge service exact raw-body authorization binding"
  require_pattern "$SERVICE_DIR/src/server.js" 'PASSKEY_TRUSTED_PROXY_CIDRS' "passkey challenge service trusted proxy direct-peer allowlist"
  require_pattern "$SERVICE_DIR/src/server.js" 'canonicalIpAddress' "passkey challenge service canonical forwarded client address gate"
  require_pattern "$SERVICE_DIR/src/server.js" 'parseIntegerSetting' "passkey challenge service strict environment integer parsing"
  require_pattern "$SERVICE_DIR/src/server.js" 'invalid_request_target' "passkey challenge service request-target smuggling rejection"
  require_pattern "$SERVICE_DIR/src/server.js" 'strict-transport-security' "passkey challenge service hardened HTTP response headers"

  require_pattern "$SERVICE_DIR/test/service.test.js" 'registration and assertion verify real ES256 WebAuthn cryptography' "passkey challenge service real cryptography positive test"
  require_pattern "$SERVICE_DIR/test/service.test.js" 'registration and assertion verify real RS256 WebAuthn cryptography' "passkey challenge service real RS256 cryptography positive test"
  require_pattern "$SERVICE_DIR/test/service.test.js" 'persists public key, user handle, counter, and metadata across restart' "passkey challenge service restart persistence adversarial test"
  require_pattern "$SERVICE_DIR/test/service.test.js" 'parses only canonical secure allowed origins' "passkey challenge service configured origin adversarial test"
  require_pattern "$SERVICE_DIR/test/service.test.js" 'invalid identifiers including noncanonical aliases' "passkey challenge service noncanonical identifier adversarial test"
  require_pattern "$SERVICE_DIR/test/authorization.test.js" 'replayed one-time authorization is rejected' "passkey challenge service one-time authorization replay test"
  require_pattern "$SERVICE_DIR/test/security-regression.test.js" 'trusted-proxy rate limiting is opt-in, single-hop, and fail-closed' "passkey challenge service trusted-proxy adversarial test"
  require_pattern "$SERVICE_DIR/test/security-regression.test.js" 'global request bucket bounds distributed client and introspection load' "passkey challenge service global rate-limit adversarial test"
  require_pattern "$SERVICE_DIR/test/security-regression.test.js" 'concurrent assertion replay permits one claimant only' "passkey challenge service concurrent assertion replay test"
  require_pattern "$SERVICE_DIR/test/openapi-contract.test.js" 'exact hardened POST response matrices' "passkey challenge service OpenAPI response-matrix test"
  require_pattern "$SERVICE_DIR/test/production-smoke.test.js" 'noncanonical 32-byte registration challenge and userId encodings' "passkey challenge service smoke encoding adversarial test"
  require_pattern "$ROOT_DIR/config/passkey-backup-challenge-service.openapi.json" '"bearerAuth"' "passkey challenge service OpenAPI Bearer security scheme"
  require_pattern "$ROOT_DIR/config/passkey-backup-challenge-service.openapi.json" '"AuthorizationForbidden"' "passkey challenge service OpenAPI authorization error response"
  require_pattern "$SERVICE_DIR/test/service.test.js" 'keeps pending ceremonies transient across restart' "passkey challenge service transient ceremony restart adversarial test"
  require_pattern "$SERVICE_DIR/test/service.test.js" 'rejects corrupted, legacy, unsupported, duplicate, and symlink stores' "passkey challenge service corrupt credential store adversarial test"
  require_pattern "$SERVICE_DIR/test/service.test.js" 'rejects unwritable path and does not retain failed writes' "passkey challenge service failed persistence adversarial test"
  require_pattern "$SERVICE_DIR/test/service.test.js" 'createPasskeyChallengeStore' "passkey challenge service credential store factory test"
  require_pattern "$SERVICE_DIR/test/service.test.js" 'rejects request smuggling fields and invalid identifiers' "passkey challenge service strict request adversarial test"
  require_pattern "$SERVICE_DIR/test/service.test.js" 'malformed registration credential consumes its one-time ceremony' "passkey challenge service fail-closed ceremony consumption test"
  require_pattern "$SERVICE_DIR/test/service.test.js" 'concurrent registration replay has exactly one successful claimant' "passkey challenge service concurrent replay adversarial test"
  require_pattern "$SERVICE_DIR/test/service.test.js" 'rejects wrong origin, client-data type, and cross-origin registration' "passkey challenge service origin and WebAuthn type adversarial test"
  require_pattern "$SERVICE_DIR/test/service.test.js" 'rejects registration without user verification or with wrong RP hash' "passkey challenge service registration UV and RP-ID adversarial test"
  require_pattern "$SERVICE_DIR/test/service.test.js" 'rejects malformed attestation, mismatched rawId, extra fields, and unsupported algorithm' "passkey challenge service attestation envelope adversarial test"
  require_pattern "$SERVICE_DIR/test/service.test.js" 'rejects duplicate credential registration across storage keys' "passkey challenge service global credential uniqueness test"
  require_pattern "$SERVICE_DIR/test/service.test.js" 'rejects assertion before registration and credentials registered to another storage key' "passkey challenge service credential ownership adversarial test"
  require_pattern "$SERVICE_DIR/test/service.test.js" 'rejects wrong user handle, missing user handle, tampered signature, wrong RP hash, and missing UV' "passkey challenge service assertion cryptography adversarial test"
  require_pattern "$SERVICE_DIR/test/service.test.js" 'rejects non-advancing authenticator counters' "passkey challenge service counter replay adversarial test"
  require_pattern "$SERVICE_DIR/test/service.test.js" 'expired and capacity-exhausted ceremonies fail closed' "passkey challenge service expiry and capacity adversarial test"
  require_pattern "$SERVICE_DIR/test/service.test.js" 'strict integer settings reject partial, signed, unsafe, and out-of-range values' "passkey challenge service environment parsing adversarial test"
  require_pattern "$SERVICE_DIR/test/service.test.js" 'oversized' "passkey challenge service oversized HTTP request body adversarial test"
  require_pattern "$SERVICE_DIR/test/service.test.js" 'rejects MIME confusion, query smuggling' "passkey challenge service HTTP smuggling adversarial test"
  require_pattern "$SERVICE_DIR/test/service.test.js" 'rate limits ceremony endpoints per client' "passkey challenge service rate-limit adversarial test"
	  require_pattern "$SERVICE_DIR/test/deployment-manifest.test.js" 'deployment manifest pins production container' "passkey challenge service deployment manifest positive test"
	  require_pattern "$SERVICE_DIR/test/deployment-manifest.test.js" 'rejects adversarial production contract drift' "passkey challenge service deployment manifest adversarial test"
	  require_pattern "$SERVICE_DIR/test/deployment-manifest.test.js" 'PASSKEY_BACKUP_LIVE_HEALTH=1 PASSKEY_BACKUP_HEALTH_TIMEOUT_SECONDS=10' "passkey challenge service deployment live health test marker"
	  require_pattern "$SERVICE_DIR/test/deployment-manifest.test.js" 'PASSKEY_CREDENTIAL_STORE_FILE=/data/passkey-backup/credentials\.json' "passkey challenge service deployment credential store test marker"
	  require_pattern "$SERVICE_DIR/test/deployment-manifest.test.js" 'production-deployment-evidence\.json' "passkey challenge service deployment evidence manifest test marker"
	  require_pattern "$SERVICE_DIR/test/production-smoke.test.js" 'without storing credentials' "passkey challenge service production smoke non-persistent positive test"
	  require_pattern "$SERVICE_DIR/test/production-smoke.test.js" 'rejects non-HTTPS non-localhost base URLs' "passkey challenge service production smoke HTTPS adversarial test"
	  require_pattern "$SERVICE_DIR/test/production-smoke.test.js" 'rejects wrong health identity' "passkey challenge service production smoke identity adversarial test"
	  require_pattern "$SERVICE_DIR/test/production-smoke.test.js" 'ENOTFOUND' "passkey challenge service production smoke fetch-cause adversarial test"
	  require_pattern "$SERVICE_DIR/test/production-smoke.test.js" 'production smoke reports network failures with deployment hints' "passkey challenge service production smoke network-failure adversarial test"
	  require_pattern "$SERVICE_DIR/test/production-smoke.test.js" 'rejects unsupported registration response fields' "passkey challenge service production smoke response allow-list adversarial test"
	  require_pattern "$SERVICE_DIR/test/production-smoke.test.js" 'rejects missing assertion challenge route contract' "passkey challenge service production smoke assertion route adversarial test"
	  require_pattern "$SERVICE_DIR/test/production-smoke.test.js" 'rejects completion routes with wrong public error codes' "passkey challenge service production smoke completion route adversarial test"
}

main() {
  log "Checking passkey challenge service under $SERVICE_DIR"
  if [[ ! -d "$SERVICE_DIR" ]]; then
    record_failure "passkey challenge service directory missing: $SERVICE_DIR"
  fi

  check_package_contract
  check_files_and_markers

  if [[ "$SKIP_COMMANDS" != "1" ]]; then
    if ! command -v npm >/dev/null 2>&1; then
      record_failure "npm is required for passkey challenge service tests"
    else
	      run_command "passkey challenge service command npm run lint:syntax" npm run lint:syntax --prefix "$SERVICE_DIR"
	      run_command "passkey challenge service command npm test" npm test --prefix "$SERVICE_DIR"
	      run_command "passkey challenge service command npm run audit:dependencies" npm run audit:dependencies --prefix "$SERVICE_DIR"
	      run_command "passkey challenge service command npm run test:deployment-evidence-template" npm run test:deployment-evidence-template --prefix "$SERVICE_DIR"
	      run_command "passkey challenge service command npm run test:deployment-evidence-audit" npm run test:deployment-evidence-audit --prefix "$SERVICE_DIR"
	      run_command "passkey challenge service command npm run audit:deployment-evidence" npm run audit:deployment-evidence --prefix "$SERVICE_DIR"
	    fi
  else
    log "Skipping npm command execution for fixture-only audit run"
  fi

  if ((${#failures[@]} > 0)); then
    echo "[passkey-challenge-service-audit][error] Passkey challenge service audit failed:" >&2
    printf '  - %s\n' "${failures[@]}" >&2
    exit 1
  fi

  log "Passkey challenge service audit passed."
}

main "$@"
