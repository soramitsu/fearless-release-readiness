#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
AUDIT_SCRIPT="$SCRIPT_DIR/audit-passkey-challenge-service.sh"

fail() {
  echo "[passkey-challenge-service-audit-test][error] $*" >&2
  exit 1
}

tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

workspace="$tmp_dir/fearless"
service_dir="$workspace/services/passkey-backup-challenge-service"

write_file() {
  local file="$1"
  shift
  mkdir -p "$(dirname "$file")"
  printf '%s\n' "$@" > "$file"
}

setup_fixture() {
  rm -rf "$workspace"
  mkdir -p "$service_dir/src" "$service_dir/test" "$service_dir/scripts"

  write_file "$service_dir/package.json" \
    '{' \
    '  "name": "@fearless/passkey-backup-challenge-service",' \
    '  "version": "0.1.0",' \
    '  "private": true,' \
    '  "type": "module",' \
    '  "scripts": {' \
    '    "start": "node src/server.js",' \
    '    "test": "node --test",' \
    '    "audit:dependencies": "npm audit --omit=dev",' \
    '    "lint:syntax": "node --check src/authorization.js && node --check src/server.js && node --check scripts/production-smoke.mjs && node --check test/webauthn-fixture.js && node --check test/authorization.test.js && node --check test/security-regression.test.js && node --check test/openapi-contract.test.js && node --check test/deployment-manifest.test.js && node --check test/production-smoke.test.js",' \
    '    "smoke:production": "node scripts/production-smoke.mjs",' \
    '    "audit:deployment-evidence": "bash scripts/audit-deployment-evidence.sh",' \
    '    "generate:deployment-evidence-template": "bash scripts/generate-deployment-evidence-template.sh",' \
    '    "test:deployment-evidence-audit": "bash scripts/test-deployment-evidence-audit.sh",' \
    '    "test:deployment-evidence-template": "bash scripts/test-deployment-evidence-template.sh"' \
    '  },' \
    '  "engines": { "node": ">=22" },' \
    '  "dependencies": { "@simplewebauthn/server": "13.3.2" }' \
    '}'
  write_file "$service_dir/package-lock.json" \
    '{' \
    '  "name": "@fearless/passkey-backup-challenge-service",' \
    '  "version": "0.1.0",' \
    '  "lockfileVersion": 3,' \
    '  "packages": {' \
    '    "": {' \
    '      "dependencies": { "@simplewebauthn/server": "13.3.2" }' \
    '    }' \
    '  }' \
    '}'

  write_file "$service_dir/Dockerfile" \
    'FROM node:22-alpine@sha256:16e22a550f3863206a3f701448c45f7912c6896a62de43add43bb9c86130c3e2' \
    'WORKDIR /app' \
    'COPY package.json package-lock.json ./' \
    'RUN npm ci --omit=dev --ignore-scripts' \
    'ENV PASSKEY_CREDENTIAL_STORE_FILE=/data/passkey-backup/credentials.json' \
    'EXPOSE 8789' \
    'RUN mkdir -p /data/passkey-backup && chown -R node:node /data/passkey-backup' \
    'VOLUME ["/data/passkey-backup"]' \
    'USER node' \
    'HEALTHCHECK CMD node -e "fetch(\"http://127.0.0.1:8789/api/passkey-backup/v1/health\")"' \
    'CMD ["node", "src/server.js"]'
  write_file "$service_dir/docker-compose.production.yml" \
    'services:' \
    '  passkey-backup-challenge-service:' \
    '    image: passkey-backup-challenge-service:release' \
    '    restart: unless-stopped' \
    '    read_only: true' \
    '    cap_drop:' \
    '      - ALL' \
    '    security_opt:' \
    '      - no-new-privileges:true' \
    '    pids_limit: 128' \
    '    environment:' \
    '      NODE_ENV: production' \
    '      PORT: "8789"' \
      '      PASSKEY_ALLOWED_ORIGINS: https://fearlesswallet.io,https://backup.fearlesswallet.io' \
    '      PASSKEY_RATE_LIMIT_WINDOW_MS: "60000"' \
    '      PASSKEY_RATE_LIMIT_MAX_REQUESTS: "120"' \
    '      PASSKEY_GLOBAL_RATE_LIMIT_MAX_REQUESTS: "5000"' \
    '      PASSKEY_ANDROID_ALLOWED_ORIGIN: "${PASSKEY_ANDROID_ALLOWED_ORIGIN:?required}"' \
    '      PASSKEY_AUTHORIZATION_INTROSPECTION_URL: "${PASSKEY_AUTHORIZATION_INTROSPECTION_URL:?required}"' \
    '      PASSKEY_AUTHORIZATION_AUDIENCE: fearless-passkey-backup' \
    '      PASSKEY_TRUST_PROXY_HOPS: "1"' \
    '      PASSKEY_TRUSTED_PROXY_CIDRS: "${PASSKEY_TRUSTED_PROXY_CIDRS:?required}"' \
      '      PASSKEY_CREDENTIAL_STORE_FILE: /data/passkey-backup/credentials.json' \
    '    ports:' \
    '      - "127.0.0.1:8789:8789"' \
    '    volumes:' \
    '      - passkey-backup-data:/data/passkey-backup' \
    '    healthcheck:' \
    '      test: ["CMD", "node", "-e", "fetch(\"http://127.0.0.1:8789/api/passkey-backup/v1/health\")"]' \
    'volumes:' \
    '  passkey-backup-data:'
  write_file "$service_dir/.dockerignore" \
    '.git' \
    'node_modules' \
    '.env' \
    '.env.*'
  write_file "$service_dir/README.md" \
    'PASSKEY_ALLOWED_ORIGINS' \
    'PASSKEY_CHALLENGE_TTL_MS' \
    'PASSKEY_CREDENTIAL_STORE_FILE' \
    '/data/passkey-backup' \
    'docker-compose.production.yml' \
    'fearless-passkey-backup' \
    'docs/production-deployment.md' \
    'docs/release-checklist.md' \
    'cryptographically verifies WebAuthn' \
    'credential public keys, user handles, counters' \
    'single-writer contract' \
    'refuses to start in `NODE_ENV=production`' \
    'PASSKEY_RATE_LIMIT_WINDOW_MS' \
    '/api/passkey-backup/v1/registration/challenge' \
    '/api/passkey-backup/v1/assertion/complete'
	  write_file "$service_dir/docs/production-deployment.md" \
	    'backup.fearlesswallet.io' \
	    'docker build -t passkey-backup-challenge-service:release .' \
	    'docker compose -f docker-compose.production.yml up -d --build' \
	    'docker run' \
	    'PASSKEY_ALLOWED_ORIGINS=https://fearlesswallet.io,https://backup.fearlesswallet.io' \
	    'PASSKEY_CREDENTIAL_STORE_FILE=/data/passkey-backup/credentials.json' \
	    'PASSKEY_BACKUP_LIVE_HEALTH=1 PASSKEY_BACKUP_HEALTH_TIMEOUT_SECONDS=10' \
	    'PASSKEY_BACKUP_BASE_URL=https://backup.fearlesswallet.io' \
	    'PASSKEY_BACKUP_SMOKE_GRANT_HELPER=/run/secrets/passkey-smoke-grant-helper' \
	    'PASSKEY_BACKUP_SMOKE_TIMEOUT_MS=10000 npm run smoke:production' \
	    'PASSKEY_ANDROID_RELEASE_SIGNER_SHA256_FINGERPRINT="$PASSKEY_ANDROID_RELEASE_SIGNER_SHA256_FINGERPRINT"' \
	    'PASSKEY_ANDROID_RELEASE_SIGNER_EVIDENCE_SOURCE="$PASSKEY_ANDROID_RELEASE_SIGNER_EVIDENCE_SOURCE"' \
	    'distributed-apk or play-app-signing-certificate' \
	    'declared strings alone are never signer evidence' \
	    'PASSKEY_ANDROID_DISTRIBUTED_APK_FILE' \
	    'PASSKEY_ANDROID_PLAY_APP_SIGNING_ATTESTATION_FILE' \
	    'PASSKEY_ANDROID_PLAY_APP_SIGNING_ATTESTATION_SHA256' \
	    'PASSKEY_ANDROID_PLAY_APP_SIGNING_CERTIFICATE_FILE' \
	    'PASSKEY_ANDROID_PLAY_APP_SIGNING_CERTIFICATE_SHA256' \
	    'self-declared fingerprint cannot satisfy' \
	    'PASSKEY_ANDROID_RELEASE_ARTIFACT_SHA256' \
	    'submitted release AAB, made read-only' \
	    'compiled AAB base manifest' \
	    'upload-key fingerprint on the submitted AAB is not sufficient' \
	    'bash ../../scripts/audit-passkey-android-origin-parity.sh --require-ready' \
	    'scripts/production-deployment-evidence.json' \
	    'npm run generate:deployment-evidence-template -- --output build/reports/production-deployment-evidence-template.json' \
	    'npm run audit:deployment-evidence -- --require-ready'
	  printf '%s\n' 'ready evidence must be no more than 24 hours old liveHealthAttestation platformProvisioningAttestation' >> "$service_dir/docs/production-deployment.md"
	  write_file "$service_dir/docs/release-checklist.md" \
	    'docker build -t passkey-backup-challenge-service:release .' \
	    'docker compose -f docker-compose.production.yml up -d --build' \
	    'PASSKEY_BACKUP_LIVE_HEALTH=1 PASSKEY_BACKUP_HEALTH_TIMEOUT_SECONDS=10' \
	    'PASSKEY_BACKUP_BASE_URL=https://backup.fearlesswallet.io PASSKEY_BACKUP_SMOKE_GRANT_HELPER=/run/secrets/passkey-smoke-grant-helper PASSKEY_BACKUP_SMOKE_TIMEOUT_MS=10000 npm run smoke:production' \
	    'PASSKEY_ANDROID_RELEASE_SIGNER_SHA256_FINGERPRINT="$PASSKEY_ANDROID_RELEASE_SIGNER_SHA256_FINGERPRINT" PASSKEY_ANDROID_RELEASE_SIGNER_EVIDENCE_SOURCE="$PASSKEY_ANDROID_RELEASE_SIGNER_EVIDENCE_SOURCE" bash ../../scripts/audit-passkey-android-origin-parity.sh --require-ready' \
	    'distributed-apk or play-app-signing-certificate' \
	    'Expected fingerprint/source strings alone must fail' \
	    'PASSKEY_ANDROID_DISTRIBUTED_APK_FILE' \
	    'PASSKEY_ANDROID_PLAY_APP_SIGNING_ATTESTATION_FILE' \
	    'PASSKEY_ANDROID_PLAY_APP_SIGNING_CERTIFICATE_FILE' \
	    'PASSKEY_ANDROID_RELEASE_ARTIFACT_FILE after making it read-only' \
	    'AAB upload-key fingerprint is not sufficient' \
	    'npm run test:deployment-evidence-template' \
	    'npm run generate:deployment-evidence-template -- --output build/reports/production-deployment-evidence-template.json' \
	    'npm run test:deployment-evidence-audit' \
	    'npm run audit:deployment-evidence -- --require-ready' \
	    'Android and iOS passkey backup release flags remain disabled' \
	    'ready smoke must be no more than 24 hours old'
	  write_file "$service_dir/scripts/production-deployment-evidence.json" \
	    '{' \
	    '  "baseUrl": "https://backup.fearlesswallet.io",' \
	    '  "status": "blocked",' \
	    '  "releaseEnabled": false,' \
	    '  "blockers": [' \
	    '    "production-deployment-evidence-missing",' \
	    '    "live-health-failing",' \
	    '    "platform-provisioning-incomplete"' \
	    '  ],' \
	    '  "requiredCommands": [' \
	    '    "npm run test:deployment-evidence-template",' \
	    '    "npm run generate:deployment-evidence-template -- --output build/reports/production-deployment-evidence-template.json",' \
	    '    "PASSKEY_BACKUP_BASE_URL=https://backup.fearlesswallet.io PASSKEY_BACKUP_SMOKE_GRANT_HELPER=/run/secrets/passkey-smoke-grant-helper PASSKEY_BACKUP_SMOKE_TIMEOUT_MS=10000 npm run smoke:production"' \
	    '  ],' \
	    '  "requiredEvidenceFields": ["imageDigest", "deploymentId", "smokePassedAt", "liveHealthAttestation", "platformProvisioningAttestation"]' \
	    '}'
	  write_file "$service_dir/scripts/audit-deployment-evidence.sh" \
	    '#!/usr/bin/env bash' \
	    'echo "releaseEnabled must remain false while deployment evidence is blocked"' \
	    'echo "ready deployment evidence requires at least one successful live production smoke record"' \
	    'echo "imageDigest must be a sha256 image digest"' \
	    'echo "smokePassedAt must be an ISO-8601 UTC second timestamp"' \
	    'echo "deployedAt must not be in the future"' \
	    'echo "smokePassedAt must not be in the future"' \
	    'echo "smokePassedAt must be at or after deployedAt"' \
	    'echo "smokePassedAt must be no more than 24 hours old for ready evidence"' \
	    'echo "blocked deployment evidence must keep deploymentEvidence empty"' \
	    'echo "record.liveHealthAttestation"' \
	    'echo "record.platformProvisioningAttestation"' \
	    'echo "payloadSha256 must match the canonical attested payload"' \
	    'echo "production route smoke command"' \
	    'echo "assertNoSecretLikeValues(data)"' \
	    'echo "must not be included in public deployment evidence"'
	  write_file "$service_dir/scripts/test-deployment-evidence-audit.sh" \
	    '#!/usr/bin/env bash' \
	    'echo "release enabled while blocked"' \
	    'echo "ready evidence without live smoke"' \
	    'echo "bad image digest evidence"' \
	    'echo "wrong production smoke command evidence"' \
	    'echo "future deployment timestamp evidence"' \
	    'echo "future smoke timestamp evidence"' \
	    'echo "exact 24-hour ready evidence boundary"' \
	    'echo "fresh record cannot mask stale second deployment"' \
	    'echo "cross-deployment live health attestation substitution"' \
	    'echo "forged payload digest"' \
	    'echo "smoke before deployment evidence"' \
	    'echo "secret-like deployment evidence key"' \
	    'echo "secret-like deployment evidence value"' \
	    'echo "missing deployment evidence template command"'
	  write_file "$service_dir/scripts/generate-deployment-evidence-template.sh" \
	    '#!/usr/bin/env bash' \
	    'echo "TODO_64_HEX_IMAGE_DIGEST"' \
	    'echo "TODO_40_HEX_GIT_COMMIT"' \
	    'echo "platformProvisioning"' \
	    'echo "TODO_CANONICAL_HEALTH_RESPONSE_SHA256"' \
	    'echo "TODO_CANONICAL_PLATFORM_PROVISIONING_SHA256"' \
	    'echo "must not be read from public deployment evidence manifest"'
	  write_file "$service_dir/scripts/test-deployment-evidence-template.sh" \
	    '#!/usr/bin/env bash' \
	    'echo "template cannot pass ready audit with TODO placeholders"' \
	    'echo "unsupported evidence field"' \
	    'echo "secret-like manifest key"' \
	    'echo "nested secret-like manifest key"' \
	    'echo "liveHealthAttestation"' \
	    'echo "missing template generator command"'
	  write_file "$service_dir/scripts/production-smoke.mjs" \
	    'const registrationChallenge = true;' \
	    'const assertionChallenge = true;' \
	    'const registrationComplete = true;' \
	    'const assertionComplete = true;' \
	    'const credential_not_registered = true;' \
	    'const unknown_or_expired_registration = true;' \
	    'const unknown_or_expired_assertion = true;' \
	    'function formatFailureCause(cause) { return cause.code; }' \
	    'const networkFailureHint = "DNS/TLS/routing deploy services/passkey-backup-challenge-service";' \
	    'const responseAllowList = "contains unsupported field";' \
	    'const PASSKEY_BACKUP_SMOKE_GRANT_HELPER = true;' \
	    'const helperPath = realpathSync.native("/run/helper");' \
	    'const helperWritable = (stat.mode & 0o022) !== 0;' \
	    'function isCanonicalBase64Url32() { return true; }'

  write_file "$service_dir/src/base64url.js" 'export const marker = true;'
  write_file "$service_dir/src/errors.js" 'export const marker = true;'
  write_file "$service_dir/src/authorization.js" \
    'const scope = "passkey.registration.challenge";' \
    'const hash = `authorization-subject\0${subject}`;' \
    "const redirect = { redirect: 'error' };" \
    "const canonical = value.includes('%');"
  write_file "$service_dir/src/validation.js" \
    'const clientDataJSON = true;' \
    'const attestationObject = true;' \
    'const authenticatorData = true;' \
    'const signature = true;' \
    'const rawIdGate = "credential.id and credential.rawId must identify the same credential";' \
    'const cross_origin_not_allowed = true;' \
    'const SUPPORTED_CREDENTIAL_ALGORITHMS = new Set([-7, -257]);' \
    'const challenge_mismatch = true;' \
    'const origin_not_allowed = true;' \
    'const originCredentialGate = "PASSKEY_ALLOWED_ORIGINS must not contain credentials";' \
    'const originQueryFragmentGate = "PASSKEY_ALLOWED_ORIGINS must not contain query strings or fragments";' \
    'const originHttpsGate = "PASSKEY_ALLOWED_ORIGINS must use HTTPS outside localhost";' \
    'const credential_type_mismatch = true;'
  write_file "$service_dir/src/store.js" \
    'class FileBackedPasskeyChallengeStore {}' \
    'const CREDENTIAL_STORE_SCHEMA_VERSION = 3;' \
    'const schemaVersion = CREDENTIAL_STORE_SCHEMA_VERSION;' \
    'const credentialsByStorageKey = new Map();' \
    "const entryFields = ['storageKey', 'ownerSubjectHash', 'credentials'];" \
    "const fields = ['id', 'publicKey', 'userId', 'counter', 'deviceType', 'backedUp', 'aaguid', 'registrationPlatform'];" \
    'const credential_counter_replay = true;' \
    'function isSymbolicLink() {}' \
    'const O_NOFOLLOW = true;' \
    'function fsyncSync() {}' \
    'const credential_store_invalid = true;' \
    'const credential_store_unavailable = true;' \
    'function renameSync() {}' \
    'function createPasskeyChallengeStore() {}' \
    'const requireDurable = true;' \
    'function cleanupExpired() {}'
  write_file "$service_dir/src/service.js" \
    'const createType = "webauthn.create";' \
    'const getType = "webauthn.get";' \
    'function verifyRegistrationResponse() {}' \
    'function verifyAuthenticationResponse() {}' \
    'const verification = { requireUserVerification: true, expectedRPID: RP_ID };' \
    'const algorithms = { supportedAlgorithmIDs: [-7, -257] };' \
    'const authorizationPlatform = true;' \
    'const ownerSubjectHash = true;' \
    'const credential_user_mismatch = true;' \
    'function updateCredentialAfterAuthentication() {}' \
    'function consumeRegistration() {}' \
    'function consumeAssertion() {}' \
    'const credential_not_registered = true;'
  write_file "$service_dir/src/server.js" \
    'const PASSKEY_CREDENTIAL_STORE_FILE = true;' \
    'const payload_too_large = true;' \
    'const unsupported_media_type = true;' \
    'const method_not_allowed = true;' \
    'const rate_limit_exceeded = true;' \
    'const PASSKEY_GLOBAL_RATE_LIMIT_MAX_REQUESTS = true;' \
    'const PASSKEY_TRUSTED_PROXY_CIDRS = true;' \
    'function createRequestAuthorizerFromEnvironment() {}' \
    'function sha256Base64Url(rawBody) {}' \
    'function canonicalIpAddress() {}' \
    'const invalid_request_target = true;' \
    'const strictTransportSecurity = "strict-transport-security";' \
    'function parseIntegerSetting() {}'
  write_file "$service_dir/test/webauthn-fixture.js" \
    'export function createRegistrationCredential() {}' \
    'export function createAssertionCredential() {}'
  write_file "$service_dir/test/service.test.js" \
    'test("registration and assertion verify real ES256 WebAuthn cryptography", () => {})' \
    'test("registration and assertion verify real RS256 WebAuthn cryptography", () => {})' \
    'test("file-backed store persists public key, user handle, counter, and metadata across restart", () => {})' \
    'test("file-backed store keeps pending ceremonies transient across restart", () => {})' \
    'test("file-backed store rejects corrupted, legacy, unsupported, duplicate, and symlink stores", () => {})' \
    'test("file-backed store rejects unwritable path and does not retain failed writes", () => {})' \
    'test("createPasskeyChallengeStore selects durable store only when configured", () => {})' \
    'test("rejects request smuggling fields and invalid identifiers including noncanonical aliases", () => {})' \
    'test("malformed registration credential consumes its one-time ceremony", () => {})' \
    'test("concurrent registration replay has exactly one successful claimant", () => {})' \
    'test("rejects wrong origin, client-data type, and cross-origin registration", () => {})' \
    'test("rejects registration without user verification or with wrong RP hash", () => {})' \
    'test("rejects malformed attestation, mismatched rawId, extra fields, and unsupported algorithm", () => {})' \
    'test("rejects duplicate credential registration across storage keys", () => {})' \
    'test("rejects assertion before registration and credentials registered to another storage key", () => {})' \
    'test("rejects wrong user handle, missing user handle, tampered signature, wrong RP hash, and missing UV", () => {})' \
    'test("rejects non-advancing authenticator counters", () => {})' \
    'test("expired and capacity-exhausted ceremonies fail closed", () => {})' \
    'test("parses only canonical secure allowed origins", () => {})' \
    'test("strict integer settings reject partial, signed, unsafe, and out-of-range values", () => {})' \
    'test("HTTP server rejects MIME confusion, query smuggling, oversized bodies, and wrong methods", () => {})' \
    'test("HTTP server rate limits ceremony endpoints per client", () => {})'
	  write_file "$service_dir/test/deployment-manifest.test.js" \
	    'test("deployment manifest pins production container and release runbook contracts", () => {})' \
	    'test("deployment manifest rejects adversarial production contract drift", () => {})' \
	    'docker-compose.production.yml' \
	    'Production compose must mention - "8789:8789"' \
	    'Production compose must not run privileged' \
	    'PASSKEY_ALLOWED_ORIGINS: https://fearlesswallet.io,https://backup.fearlesswallet.io' \
	    'PASSKEY_BACKUP_LIVE_HEALTH=1 PASSKEY_BACKUP_HEALTH_TIMEOUT_SECONDS=10' \
	    'PASSKEY_BACKUP_BASE_URL=https://backup.fearlesswallet.io PASSKEY_BACKUP_SMOKE_GRANT_HELPER=/run/secrets/passkey-smoke-grant-helper PASSKEY_BACKUP_SMOKE_TIMEOUT_MS=10000 npm run smoke:production' \
	    'PASSKEY_CREDENTIAL_STORE_FILE=/data/passkey-backup/credentials.json' \
	    'scripts/production-deployment-evidence.json'
	  write_file "$service_dir/test/production-smoke.test.js" \
	    'test("production smoke validates health and challenge routes without storing credentials", () => {})' \
	    'test("production smoke rejects non-HTTPS non-localhost base URLs", () => {})' \
	    'test("production smoke rejects wrong health identity", () => {})' \
	    'test("production smoke fails closed before requests when the configured grant helper is missing", () => {})' \
	    'test("smoke grant helper rejects group- or world-writable files", () => {})' \
	    'test("smoke grant helper rejects extra output, and timeout", () => {})' \
	    'test("production smoke reports network failures with deployment hints", () => {})' \
	    'const ENOTFOUND = "ENOTFOUND";' \
	    'test("production smoke rejects unsupported registration response fields", () => {})' \
	    'test("production smoke rejects noncanonical 32-byte registration challenge and userId encodings", () => {})' \
	    'test("production smoke rejects missing assertion challenge route contract", () => {})' \
	    'test("production smoke rejects completion routes with wrong public error codes", () => {})'
	  write_file "$service_dir/test/authorization.test.js" \
	    'test("replayed one-time authorization is rejected by the consuming introspector", () => {})'
	  write_file "$service_dir/test/security-regression.test.js" \
	    'test("trusted-proxy rate limiting is opt-in, single-hop, and fail-closed", () => {})' \
	    'test("global request bucket bounds distributed client and introspection load", () => {})' \
	    'test("concurrent assertion replay permits one claimant only", () => {})'
	  write_file "$service_dir/test/openapi-contract.test.js" \
	    'test("OpenAPI requires one-time Bearer grants and exact hardened POST response matrices", () => {})'
	  write_file "$workspace/config/passkey-backup-challenge-service.openapi.json" \
	    '{"components":{"securitySchemes":{"bearerAuth":{}},"responses":{"AuthorizationForbidden":{}}}}'
}

run_audit() {
  PASSKEY_CHALLENGE_SERVICE_AUDIT_ROOT="$workspace" \
  PASSKEY_CHALLENGE_SERVICE_AUDIT_SKIP_COMMANDS="${PASSKEY_CHALLENGE_SERVICE_AUDIT_SKIP_COMMANDS:-1}" \
    bash "$AUDIT_SCRIPT"
}

expect_success() {
  local name="$1"
  local output
  if ! output="$(run_audit 2>&1)"; then
    echo "$output" >&2
    fail "$name unexpectedly failed"
  fi
}

expect_failure() {
  local name="$1"
  local expected="$2"
  local output
  set +e
  output="$(run_audit 2>&1)"
  local status=$?
  set -e

  if [[ "$status" -eq 0 ]]; then
    echo "$output" >&2
    fail "$name unexpectedly passed"
  fi

  if [[ "$output" != *"$expected"* ]]; then
    echo "$output" >&2
    fail "$name did not report expected text: $expected"
  fi
}

setup_fixture
expect_success "complete fixture"

setup_fixture
rm "$service_dir/Dockerfile"
expect_failure "missing Dockerfile" "Dockerfile missing"

setup_fixture
perl -0pi -e 's/\@sha256:[0-9a-f]{64}//' "$service_dir/Dockerfile"
expect_failure "mutable Node container base" "immutable approved Node 22 container base"

setup_fixture
perl -0pi -e 's/sha256:16e22/sha256:06e22/' "$service_dir/Dockerfile"
expect_failure "drifted Node container base digest" "immutable approved Node 22 container base"

setup_fixture
rm "$service_dir/docker-compose.production.yml"
expect_failure "missing production Docker Compose contract" "production Docker Compose contract missing"

setup_fixture
perl -0pi -e 's/"127\.0\.0\.1:8789:8789"/"0.0.0.0:8790:8789"/' "$service_dir/docker-compose.production.yml"
expect_failure "bad production Docker Compose port" "production compose port mapping"

setup_fixture
perl -0pi -e 's#https://fearlesswallet.io,https://backup.fearlesswallet.io#https://example.invalid#g' "$service_dir/docker-compose.production.yml"
expect_failure "bad production Docker Compose origins" "production compose origins"

setup_fixture
printf '%s\n' '    privileged: true' >> "$service_dir/docker-compose.production.yml"
expect_failure "privileged production Docker Compose" "production compose must not enable privileged mode"

setup_fixture
perl -0pi -e 's/clientDataJSON/clientDataREMOVED/' "$service_dir/src/validation.js"
expect_failure "missing clientDataJSON validation marker" "clientDataJSON validation"

setup_fixture
perl -0pi -e 's/PASSKEY_ALLOWED_ORIGINS must not contain credentials/PASSKEY_ALLOWED_ORIGINS accepts credentials/' "$service_dir/src/validation.js"
expect_failure "missing configured origin credential rejection marker" "configured origin credential rejection"

setup_fixture
perl -0pi -e 's/PASSKEY_ALLOWED_ORIGINS must not contain query strings or fragments/PASSKEY_ALLOWED_ORIGINS accepts query strings or fragments/' "$service_dir/src/validation.js"
expect_failure "missing configured origin query-fragment rejection marker" "configured origin query-fragment rejection"

setup_fixture
perl -0pi -e 's/PASSKEY_ALLOWED_ORIGINS must use HTTPS outside localhost/PASSKEY_ALLOWED_ORIGINS accepts HTTP origins/' "$service_dir/src/validation.js"
expect_failure "missing configured origin HTTPS gate marker" "configured origin HTTPS gate"

setup_fixture
perl -0pi -e 's/verifyRegistrationResponse/registrationVerifierRemoved/g' "$service_dir/src/service.js"
expect_failure "missing registration cryptographic verifier" "registration cryptographic verifier"

setup_fixture
perl -0pi -e 's/parses only canonical secure allowed origins/accepts malformed configured origins/' "$service_dir/test/service.test.js"
expect_failure "missing configured origin adversarial test" "configured origin adversarial test"

setup_fixture
perl -0pi -e 's/verifyAuthenticationResponse/authenticationVerifierRemoved/g' "$service_dir/src/service.js"
expect_failure "missing assertion cryptographic verifier" "assertion cryptographic verifier"

setup_fixture
perl -0pi -e 's/requireUserVerification: true/requireUserVerification: false/' "$service_dir/src/service.js"
expect_failure "missing mandatory user verification" "mandatory user verification"

setup_fixture
perl -0pi -e 's/expectedRPID: RP_ID/expectedRPID: request.rpId/' "$service_dir/src/service.js"
expect_failure "missing RP-ID binding" "RP-ID binding"

setup_fixture
perl -0pi -e 's/credential_user_mismatch/credential_user_unchecked/' "$service_dir/src/service.js"
expect_failure "missing user-handle ownership binding" "user-handle ownership binding"

setup_fixture
perl -0pi -e 's/updateCredentialAfterAuthentication/leaveCounterUnchanged/g' "$service_dir/src/service.js"
expect_failure "missing authenticator counter persistence" "authenticator counter persistence"

setup_fixture
perl -0pi -e 's/credential\.id and credential\.rawId must identify the same credential/rawId unchecked/' "$service_dir/src/validation.js"
expect_failure "missing raw credential ID binding" "raw credential ID binding"

setup_fixture
perl -0pi -e 's/cross_origin_not_allowed/cross_origin_allowed/' "$service_dir/src/validation.js"
expect_failure "missing cross-origin ceremony rejection" "cross-origin ceremony rejection"

setup_fixture
perl -0pi -e 's/credential_counter_replay/credential_counter_accepted/' "$service_dir/src/store.js"
expect_failure "missing monotonic authenticator counter gate" "monotonic authenticator counter gate"

setup_fixture
perl -0pi -e 's/rate_limit_exceeded/rate_limit_disabled/' "$service_dir/src/server.js"
expect_failure "missing request rate limiting" "request rate limiting"

setup_fixture
perl -0pi -e 's/parseIntegerSetting/parseInt/g' "$service_dir/src/server.js"
expect_failure "missing strict environment integer parsing" "strict environment integer parsing"

setup_fixture
perl -0pi -e 's/"13\.3\.2"/"^13.3.2"/' "$service_dir/package.json"
expect_failure "floating WebAuthn verifier dependency" "package contract invalid"

setup_fixture
rm "$service_dir/package-lock.json"
expect_failure "missing immutable package lock" "package lock missing"

setup_fixture
perl -0pi -e 's/npm ci --omit=dev --ignore-scripts/npm install --omit=dev/' "$service_dir/Dockerfile"
expect_failure "mutable production dependency install" "immutable production dependency install"

setup_fixture
perl -0pi -e 's/read_only: true/read_only: false/' "$service_dir/docker-compose.production.yml"
expect_failure "writable production root filesystem" "read-only production root filesystem"

setup_fixture
perl -0pi -e 's/no-new-privileges:true/no-new-privileges:false/' "$service_dir/docker-compose.production.yml"
expect_failure "missing production no-new-privileges" "production no-new-privileges"

setup_fixture
perl -0pi -e 's/FileBackedPasskeyChallengeStore/FileBackedREMOVED/' "$service_dir/src/store.js"
expect_failure "missing durable credential store" "durable credential store"

setup_fixture
perl -0pi -e 's/requireDurable/allowEphemeralProduction/' "$service_dir/src/store.js"
expect_failure "missing fail-closed production durable store" "fail-closed production durable-store gate"

setup_fixture
perl -0pi -e 's/persists public key, user handle, counter, and metadata across restart/persists credential identifier only/' "$service_dir/test/service.test.js"
expect_failure "missing restart persistence adversarial test" "restart persistence adversarial test"

setup_fixture
perl -0pi -e 's/registration and assertion verify real ES256 WebAuthn cryptography/registration and assertion accept fake credentials/' "$service_dir/test/service.test.js"
expect_failure "missing real cryptography positive test" "real cryptography positive test"

setup_fixture
perl -0pi -e 's/concurrent registration replay has exactly one successful claimant/concurrent registration replay succeeds twice/' "$service_dir/test/service.test.js"
expect_failure "missing concurrent replay adversarial test" "concurrent replay adversarial test"

setup_fixture
perl -0pi -e 's/rejects wrong user handle, missing user handle, tampered signature, wrong RP hash, and missing UV/accepts tampered assertions/' "$service_dir/test/service.test.js"
expect_failure "missing assertion cryptography adversarial test" "assertion cryptography adversarial test"

setup_fixture
perl -0pi -e 's/ENV PASSKEY_CREDENTIAL_STORE_FILE=\/data\/passkey-backup\/credentials\.json/ENV PASSKEY_CREDENTIAL_STORE_REMOVED=\/tmp\/credentials.json/' "$service_dir/Dockerfile"
expect_failure "missing durable credential file env" "durable credential file env"

setup_fixture
rm "$service_dir/docs/production-deployment.md"
expect_failure "missing production deployment docs" "production deployment docs missing"

setup_fixture
perl -0pi -e 's/PASSKEY_BACKUP_LIVE_HEALTH=1 PASSKEY_BACKUP_HEALTH_TIMEOUT_SECONDS=10/PASSKEY_BACKUP_LIVE_HEALTH=0/' "$service_dir/docs/release-checklist.md"
expect_failure "missing release live health checklist" "release live health checklist"

setup_fixture
rm "$service_dir/scripts/production-smoke.mjs"
expect_failure "missing production smoke script" "production smoke missing"

setup_fixture
perl -0pi -e 's/"smoke:production": "node scripts\/production-smoke\.mjs"/"smoke:production": "curl https:\/\/backup.fearlesswallet.io\/api\/passkey-backup\/v1\/health"/' "$service_dir/package.json"
expect_failure "missing production smoke package script" "smoke:production script"

setup_fixture
perl -0pi -e 's/registrationChallenge/registrationRouteRemoved/' "$service_dir/scripts/production-smoke.mjs"
expect_failure "missing production smoke registration challenge route" "production smoke registration challenge route"

setup_fixture
perl -0pi -e 's/contains unsupported field/accepts unsupported fields/' "$service_dir/scripts/production-smoke.mjs"
expect_failure "missing production smoke response allow-list" "production smoke response allow-list"

setup_fixture
perl -0pi -e 's/DNS\/TLS\/routing/network hidden/' "$service_dir/scripts/production-smoke.mjs"
expect_failure "missing production smoke network failure hint" "production smoke network failure deployment hint"

setup_fixture
perl -0pi -e 's/formatFailureCause/failureCauseFormatterRemoved/g' "$service_dir/scripts/production-smoke.mjs"
expect_failure "missing production smoke fetch-cause diagnostic" "production smoke fetch-cause diagnostic"

setup_fixture
perl -0pi -e 's/deploy services\/passkey-backup-challenge-service/deploy hidden/' "$service_dir/scripts/production-smoke.mjs"
expect_failure "missing production smoke deploy-current-service hint" "production smoke deploy-current-service hint"

setup_fixture
perl -0pi -e 's/production smoke reports network failures with deployment hints/production smoke hides network failures/' "$service_dir/test/production-smoke.test.js"
expect_failure "missing production smoke network-failure adversarial test" "production smoke network-failure adversarial test"

setup_fixture
perl -0pi -e 's/ENOTFOUND/DNS_CAUSE_REMOVED/g' "$service_dir/test/production-smoke.test.js"
expect_failure "missing production smoke fetch-cause adversarial test" "production smoke fetch-cause adversarial test"

setup_fixture
perl -0pi -e 's/without storing credentials/with persistent smoke credentials/' "$service_dir/test/production-smoke.test.js"
expect_failure "missing production smoke non-persistent positive test" "production smoke non-persistent positive test"

setup_fixture
perl -0pi -e 's/rejects missing assertion challenge route contract/rejects generic route drift/' "$service_dir/test/production-smoke.test.js"
expect_failure "missing production smoke assertion route adversarial test" "production smoke assertion route adversarial test"

setup_fixture
perl -0pi -e 's/PASSKEY_BACKUP_BASE_URL=https:\/\/backup\.fearlesswallet\.io PASSKEY_BACKUP_SMOKE_GRANT_HELPER=\/run\/secrets\/passkey-smoke-grant-helper PASSKEY_BACKUP_SMOKE_TIMEOUT_MS=10000 npm run smoke:production/curl https:\/\/backup.fearlesswallet.io\/api\/passkey-backup\/v1\/health/' "$service_dir/docs/release-checklist.md"
expect_failure "missing authorized release route smoke checklist" "authorized release route smoke checklist"

setup_fixture
perl -0pi -e 's/PASSKEY_BACKUP_SMOKE_GRANT_HELPER=\/run\/secrets\/passkey-smoke-grant-helper/PASSKEY_BACKUP_SMOKE_GRANT_HELPER_REMOVED/g' "$service_dir/docs/production-deployment.md"
expect_failure "missing authorized production route smoke helper" "authorized production route smoke docs"

setup_fixture
printf '%s\n' 'npm run smoke:production' >> "$service_dir/docs/production-deployment.md"
expect_failure "unauthorized bare production smoke documentation" "must not recommend an unauthorized bare production smoke"

setup_fixture
perl -0pi -e 's/PASSKEY_ANDROID_RELEASE_SIGNER_SHA256_FINGERPRINT/PASSKEY_ANDROID_UNVERIFIED_SIGNER/g' "$service_dir/docs/production-deployment.md"
expect_failure "missing signed Android release artifact deployment evidence" "signed Android release artifact evidence docs"

setup_fixture
perl -0pi -e 's/PASSKEY_ANDROID_RELEASE_SIGNER_EVIDENCE_SOURCE/PASSKEY_ANDROID_UNVERIFIED_SIGNER_SOURCE/g' "$service_dir/docs/production-deployment.md"
expect_failure "missing Android signer evidence-source deployment docs" "Android signer evidence-source docs"

setup_fixture
perl -0pi -e 's/distributed-apk or play-app-signing-certificate/signed-aab/g' "$service_dir/docs/release-checklist.md"
expect_failure "missing canonical signer evidence sources checklist" "distributed APK signer source checklist"

setup_fixture
perl -0pi -e 's/audit-passkey-android-origin-parity\.sh --require-ready/audit-passkey-android-origin-parity.sh/g' "$service_dir/docs/release-checklist.md"
expect_failure "missing Android origin parity ready checklist" "Android origin parity ready checklist"

setup_fixture
perl -0pi -e 's/AAB upload-key fingerprint is not sufficient/AAB upload key is accepted/' "$service_dir/docs/release-checklist.md"
expect_failure "missing Play app-signing certificate distinction checklist" "Play app-signing certificate distinction checklist"

setup_fixture
perl -0pi -e 's/declared strings alone are never signer evidence/declared strings are accepted/' "$service_dir/docs/production-deployment.md"
expect_failure "missing signer artifact requirement docs" "signer artifact requirement docs"

setup_fixture
perl -0pi -e 's/PASSKEY_ANDROID_DISTRIBUTED_APK_FILE/PASSKEY_ANDROID_UNVERIFIED_APK/g' "$service_dir/docs/release-checklist.md"
expect_failure "missing distributed APK artifact path checklist" "distributed APK path checklist"

setup_fixture
perl -0pi -e 's/PASSKEY_ANDROID_PLAY_APP_SIGNING_ATTESTATION_FILE/PASSKEY_ANDROID_UNVERIFIED_PLAY_RECORD/g' "$service_dir/docs/production-deployment.md"
expect_failure "missing Play attestation artifact path docs" "Play attestation path docs"

setup_fixture
perl -0pi -e 's/deployment manifest rejects adversarial production contract drift/deployment manifest accepts production contract drift/' "$service_dir/test/deployment-manifest.test.js"
expect_failure "missing deployment manifest adversarial test" "deployment manifest adversarial test"

setup_fixture
rm "$service_dir/scripts/production-deployment-evidence.json"
expect_failure "missing deployment evidence manifest" "production deployment evidence missing"

setup_fixture
perl -0pi -e 's/live-health-failing/live-health-optional/' "$service_dir/scripts/production-deployment-evidence.json"
expect_failure "missing deployment live health blocker" "deployment live health blocker"

setup_fixture
perl -0pi -e 's/ready evidence without live smoke/ready evidence without health/' "$service_dir/scripts/test-deployment-evidence-audit.sh"
expect_failure "missing deployment missing-live negative test" "missing live smoke negative test"

setup_fixture
perl -0pi -e 's/smokePassedAt must be at or after deployedAt/smokePassedAt timestamp unchecked/' "$service_dir/scripts/audit-deployment-evidence.sh"
expect_failure "missing deployment timestamp ordering gate" "timestamp ordering gate"

setup_fixture
perl -0pi -e 's/deployedAt must not be in the future/deployedAt future accepted/' "$service_dir/scripts/audit-deployment-evidence.sh"
expect_failure "missing future deployment timestamp gate" "future deployment timestamp gate"

setup_fixture
perl -0pi -e 's/smokePassedAt must not be in the future/smokePassedAt future accepted/' "$service_dir/scripts/audit-deployment-evidence.sh"
expect_failure "missing future smoke timestamp gate" "future smoke timestamp gate"

setup_fixture
perl -0pi -e 's/future deployment timestamp evidence/future deployment timestamp accepted/' "$service_dir/scripts/test-deployment-evidence-audit.sh"
expect_failure "missing future deployment timestamp negative test" "future deployment timestamp negative test"

setup_fixture
perl -0pi -e 's/future smoke timestamp evidence/future smoke timestamp accepted/' "$service_dir/scripts/test-deployment-evidence-audit.sh"
expect_failure "missing future smoke timestamp negative test" "future smoke timestamp negative test"

setup_fixture
perl -0pi -e 's/smokePassedAt must be no more than 24 hours old for ready evidence/smokePassedAt never expires/' "$service_dir/scripts/audit-deployment-evidence.sh"
expect_failure "missing ready evidence freshness gate" "ready evidence freshness gate"

setup_fixture
perl -0pi -e 's/blocked deployment evidence must keep deploymentEvidence empty/blocked evidence may retain stale records/' "$service_dir/scripts/audit-deployment-evidence.sh"
expect_failure "missing blocked evidence emptiness gate" "blocked evidence emptiness gate"

setup_fixture
perl -0pi -e 's/record\.liveHealthAttestation/record.unboundHealthClaim/' "$service_dir/scripts/audit-deployment-evidence.sh"
expect_failure "missing live attestation binding gate" "live attestation binding gate"

setup_fixture
perl -0pi -e 's/exact 24-hour ready evidence boundary/approximate evidence freshness/' "$service_dir/scripts/test-deployment-evidence-audit.sh"
expect_failure "missing exact freshness boundary test" "exact freshness boundary test"

setup_fixture
perl -0pi -e 's/fresh record cannot mask stale second deployment/fresh record masks stale record/' "$service_dir/scripts/test-deployment-evidence-audit.sh"
expect_failure "missing multiple-record freshness negative test" "multiple-record freshness negative test"

setup_fixture
perl -0pi -e 's/cross-deployment live health attestation substitution/cross-deployment health accepted/' "$service_dir/scripts/test-deployment-evidence-audit.sh"
expect_failure "missing cross-deployment attestation negative test" "cross-deployment attestation negative test"

setup_fixture
perl -0pi -e 's/secret-like deployment evidence key/secret evidence accepted/' "$service_dir/scripts/test-deployment-evidence-audit.sh"
expect_failure "missing secret-like evidence negative test" "secret-like evidence negative test"

setup_fixture
perl -0pi -e 's/assertNoSecretLikeValues\(data\)/assertSecretLikeValuesAllowed(data)/' "$service_dir/scripts/audit-deployment-evidence.sh"
expect_failure "missing deployment secret-like value gate" "deployment secret-like value gate"

setup_fixture
perl -0pi -e 's/secret-like deployment evidence value/secret value accepted/' "$service_dir/scripts/test-deployment-evidence-audit.sh"
expect_failure "missing secret-like value negative test" "secret-like value negative test"

setup_fixture
perl -0pi -e 's/missing deployment evidence template command/missing template command accepted/' "$service_dir/scripts/test-deployment-evidence-audit.sh"
expect_failure "missing template command audit negative test" "missing template command negative test"

setup_fixture
rm "$service_dir/scripts/generate-deployment-evidence-template.sh"
expect_failure "missing deployment evidence template generator" "deployment evidence template generator missing"

setup_fixture
rm "$service_dir/scripts/test-deployment-evidence-template.sh"
expect_failure "missing deployment evidence template self-test" "deployment evidence template self-test missing"

setup_fixture
perl -0pi -e 's/TODO_64_HEX_IMAGE_DIGEST/IMAGE_DIGEST_REMOVED/' "$service_dir/scripts/generate-deployment-evidence-template.sh"
expect_failure "missing deployment evidence template image digest placeholder" "template image digest placeholder"

setup_fixture
perl -0pi -e 's/TODO_CANONICAL_HEALTH_RESPONSE_SHA256/HEALTH_ATTESTATION_DIGEST_REMOVED/' "$service_dir/scripts/generate-deployment-evidence-template.sh"
expect_failure "missing live attestation digest template" "live attestation digest template"

setup_fixture
perl -0pi -e 's/template cannot pass ready audit with TODO placeholders/template ready audit not checked/' "$service_dir/scripts/test-deployment-evidence-template.sh"
expect_failure "missing deployment evidence template ready negative test" "template ready-audit negative test"

setup_fixture
perl -0pi -e 's/nested secret-like manifest key/nested secret fixture removed/' "$service_dir/scripts/test-deployment-evidence-template.sh"
expect_failure "missing deployment evidence template nested secret negative test" "nested-secret negative test"

setup_fixture
perl -0pi -e 's/npm run test:deployment-evidence-template//' "$service_dir/docs/release-checklist.md"
expect_failure "missing deployment evidence template release checklist" "template self-test checklist"

setup_fixture
perl -0pi -e 's/"generate:deployment-evidence-template":/"generate:deployment-proof-template":/' "$service_dir/package.json"
expect_failure "missing package deployment evidence template generator script" "package contract invalid"

setup_fixture
perl -0pi -e 's/USER node/USER root/' "$service_dir/Dockerfile"
expect_failure "missing non-root Dockerfile user" "non-root container user"

setup_fixture
rm "$service_dir/src/authorization.js"
expect_failure "missing request authorization module" "request authorization module missing"

setup_fixture
perl -0pi -e 's/passkey\.registration\.challenge/passkey.registration.disabled/' "$service_dir/src/authorization.js"
expect_failure "missing route-scoped authorization" "route-scoped authorization"

setup_fixture
perl -0pi -e 's/authorization-subject/authorization-owner/' "$service_dir/src/authorization.js"
expect_failure "missing domain-separated authorization subject" "domain-separated authorization subject hash"

setup_fixture
perl -0pi -e "s/redirect: 'error'/redirect: 'follow'/" "$service_dir/src/authorization.js"
expect_failure "authorization redirects enabled" "authorization redirect rejection"

setup_fixture
perl -0pi -e 's/value\.includes/value.accepts/' "$service_dir/src/authorization.js"
expect_failure "missing canonical introspection URL gate" "canonical introspection URL gate"

setup_fixture
perl -0pi -e 's/PASSKEY_GLOBAL_RATE_LIMIT_MAX_REQUESTS/PASSKEY_GLOBAL_LIMIT_REMOVED/' "$service_dir/docker-compose.production.yml"
expect_failure "missing production global rate limit" "production compose global rate-limit cap"

setup_fixture
perl -0pi -e 's/PASSKEY_AUTHORIZATION_INTROSPECTION_URL/PASSKEY_AUTHORIZATION_URL_REMOVED/g' "$service_dir/docker-compose.production.yml"
expect_failure "missing production authorization endpoint" "production compose authorization introspection endpoint"

setup_fixture
perl -0pi -e 's/PASSKEY_TRUST_PROXY_HOPS/PASSKEY_PROXY_HOPS_REMOVED/' "$service_dir/docker-compose.production.yml"
expect_failure "missing production trusted proxy hop" "production compose single trusted proxy hop"

setup_fixture
perl -0pi -e 's/PASSKEY_TRUSTED_PROXY_CIDRS/PASSKEY_PROXY_CIDRS_REMOVED/g' "$service_dir/docker-compose.production.yml"
expect_failure "missing production proxy peer allowlist" "production compose direct proxy peer allowlist"

setup_fixture
perl -0pi -e 's/supportedAlgorithmIDs/untestedAlgorithmIDs/' "$service_dir/src/service.js"
expect_failure "missing verified algorithm allowlist" "explicitly verified ES256 and RS256 algorithms"

setup_fixture
perl -0pi -e 's/authorizationPlatform/platformBindingGone/' "$service_dir/src/service.js"
expect_failure "missing platform authorization binding" "ceremony platform authorization binding"

setup_fixture
perl -0pi -e 's/ownerSubjectHash/subjectBindingGone/' "$service_dir/src/service.js"
expect_failure "missing stable owner authorization binding" "stable owner authorization binding"

setup_fixture
perl -0pi -e 's/CREDENTIAL_STORE_SCHEMA_VERSION = 3/CREDENTIAL_STORE_SCHEMA_VERSION = 2/' "$service_dir/src/store.js"
expect_failure "legacy credential store schema" "credential store schema-v3"

setup_fixture
perl -0pi -e 's/ownerSubjectHash/subjectBindingGone/' "$service_dir/src/store.js"
expect_failure "missing persisted owner subject" "persisted owner-subject binding"

setup_fixture
perl -0pi -e 's/aaguid/attestationIdRemoved/' "$service_dir/src/store.js"
expect_failure "missing persisted AAGUID" "persisted credential AAGUID"

setup_fixture
perl -0pi -e 's/registrationPlatform/platformRemoved/' "$service_dir/src/store.js"
expect_failure "missing persisted registration platform" "persisted registration platform"

setup_fixture
perl -0pi -e 's/O_NOFOLLOW/FOLLOW_SYMLINKS/' "$service_dir/src/store.js"
expect_failure "missing no-follow store read" "no-follow credential-store read"

setup_fixture
perl -0pi -e 's/sha256Base64Url\(rawBody\)/sha256Base64Url(JSON.stringify(body))/' "$service_dir/src/server.js"
expect_failure "missing raw body authorization binding" "exact raw-body authorization binding"

setup_fixture
perl -0pi -e 's/canonicalIpAddress/forwardedAddressValidator/g' "$service_dir/src/server.js"
expect_failure "missing canonical forwarded IP gate" "canonical forwarded client address gate"

setup_fixture
perl -0pi -e 's/registration and assertion verify real RS256 WebAuthn cryptography/registration and assertion skip RS256 cryptography/' "$service_dir/test/service.test.js"
expect_failure "missing RS256 cryptography test" "real RS256 cryptography positive test"

setup_fixture
perl -0pi -e 's/invalid identifiers including noncanonical aliases/invalid identifiers with aliases allowed/' "$service_dir/test/service.test.js"
expect_failure "missing noncanonical identifier test" "noncanonical identifier adversarial test"

setup_fixture
perl -0pi -e 's/replayed one-time authorization is rejected/replayed authorization is accepted/' "$service_dir/test/authorization.test.js"
expect_failure "missing authorization replay test" "one-time authorization replay test"

setup_fixture
perl -0pi -e 's/trusted-proxy rate limiting is opt-in, single-hop, and fail-closed/trusted proxy is optional/' "$service_dir/test/security-regression.test.js"
expect_failure "missing trusted proxy adversarial test" "trusted-proxy adversarial test"

setup_fixture
perl -0pi -e 's/global request bucket bounds distributed client and introspection load/global request bucket disabled/' "$service_dir/test/security-regression.test.js"
expect_failure "missing global request adversarial test" "global rate-limit adversarial test"

setup_fixture
perl -0pi -e 's/concurrent assertion replay permits one claimant only/concurrent assertion replay permits all/' "$service_dir/test/security-regression.test.js"
expect_failure "missing assertion replay concurrency test" "concurrent assertion replay test"

setup_fixture
perl -0pi -e 's/exact hardened POST response matrices/loose POST responses/' "$service_dir/test/openapi-contract.test.js"
expect_failure "missing OpenAPI response matrix test" "OpenAPI response-matrix test"

setup_fixture
perl -0pi -e 's/noncanonical 32-byte registration challenge and userId encodings/loose challenge encodings/' "$service_dir/test/production-smoke.test.js"
expect_failure "missing smoke encoding adversarial test" "smoke encoding adversarial test"

setup_fixture
perl -0pi -e 's/PASSKEY_BACKUP_SMOKE_GRANT_HELPER/PASSKEY_BACKUP_UNAUTHORIZED_SMOKE/' "$service_dir/scripts/production-smoke.mjs"
expect_failure "missing authorized smoke helper" "authorized smoke helper"

setup_fixture
perl -0pi -e 's/realpathSync\.native/unsafePath/' "$service_dir/scripts/production-smoke.mjs"
expect_failure "missing smoke helper canonical path gate" "smoke helper canonical path gate"

setup_fixture
perl -0pi -e 's/stat\.mode/helperMode/' "$service_dir/scripts/production-smoke.mjs"
expect_failure "missing smoke helper writable-file gate" "smoke helper writable-file gate"

setup_fixture
perl -0pi -e 's/configured grant helper is missing/helper is optional/' "$service_dir/test/production-smoke.test.js"
expect_failure "missing smoke helper absence test" "missing smoke helper negative test"

setup_fixture
perl -0pi -e 's/group- or world-writable/unsafe permissions accepted/' "$service_dir/test/production-smoke.test.js"
expect_failure "missing writable smoke helper test" "writable smoke helper negative test"

setup_fixture
perl -0pi -e 's/extra output, and timeout/helper failures accepted/' "$service_dir/test/production-smoke.test.js"
expect_failure "missing failing smoke helper tests" "failing smoke helper negative tests"

setup_fixture
perl -0pi -e 's/isCanonicalBase64Url32/isLooseBase64Url/' "$service_dir/scripts/production-smoke.mjs"
expect_failure "missing smoke canonical challenge gate" "smoke canonical 32-byte challenge gate"

setup_fixture
perl -0pi -e 's/bearerAuth/noAuthentication/' "$workspace/config/passkey-backup-challenge-service.openapi.json"
expect_failure "missing OpenAPI Bearer security" "OpenAPI Bearer security scheme"

setup_fixture
perl -0pi -e 's/AuthorizationForbidden/AuthorizationIgnored/' "$workspace/config/passkey-backup-challenge-service.openapi.json"
expect_failure "missing OpenAPI authorization response" "OpenAPI authorization error response"

setup_fixture
perl -0pi -e 's/"test": "node --test"/"test": "echo missing"/' "$service_dir/package.json"
expect_failure "missing package test script" "package contract invalid"

setup_fixture
perl -0pi -e 's/node --check src\/server\.js/node -e "process.exit\\(7\\)"/' "$service_dir/package.json"
PASSKEY_CHALLENGE_SERVICE_AUDIT_SKIP_COMMANDS=0 expect_failure \
  "failing npm command" \
  "passkey challenge service command npm run lint:syntax failed"

echo "[passkey-challenge-service-audit-test] all tests passed"
