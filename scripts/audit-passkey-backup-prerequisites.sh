#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
PRODUCTION_ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd -P)"
ROOT_DIR="${PASSKEY_AUDIT_ROOT:-$PRODUCTION_ROOT_DIR}"
readonly PASSKEY_REVIEWED_BASE_URL="https://backup.fearlesswallet.io"
readonly PASSKEY_REVIEWED_HEALTH_PATH="/api/passkey-backup/v1/health"
readonly PASSKEY_REVIEWED_HEALTH_URL="${PASSKEY_REVIEWED_BASE_URL}${PASSKEY_REVIEWED_HEALTH_PATH}"
readonly PASSKEY_PRODUCTION_CURL_BIN="/usr/bin/curl"
readonly PASSKEY_HEALTH_DEFAULT_CONNECT_TIMEOUT_SECONDS=5
readonly PASSKEY_HEALTH_DEFAULT_TIMEOUT_SECONDS=10
readonly PASSKEY_HEALTH_MAX_TIMEOUT_SECONDS=60
readonly PASSKEY_HEALTH_DEFAULT_MAX_RESPONSE_BYTES=4096
readonly PASSKEY_HEALTH_MAX_RESPONSE_BYTES=65536
readonly PASSKEY_HEALTH_MAX_ATTEMPTS=5
readonly PASSKEY_HEALTH_MAX_RETRY_DELAY_SECONDS=30

usage() {
  cat <<'USAGE'
Usage: scripts/audit-passkey-backup-prerequisites.sh

Checks whether Android and iOS have the minimum public prerequisites for
passkey-backed cloud backup. This is a release-readiness gate: current repos
should fail until product, platform, entitlement, and recovery contracts exist.

Environment:
  PASSKEY_AUDIT_ROOT                  Workspace root containing fearless-Android and fearless-iOS.
  PASSKEY_BACKUP_LIVE_HEALTH          Set to 1/true to require the configured
                                      challenge service health endpoint.
  PASSKEY_BACKUP_HEALTH_TIMEOUT_SECONDS
                                      Optional total curl timeout (1-60 seconds).
                                      Defaults to 10.
  PASSKEY_BACKUP_HEALTH_CONNECT_TIMEOUT_SECONDS
                                      Optional connect timeout (1-60 seconds and
                                      no greater than the total timeout).
                                      Defaults to 5.
  PASSKEY_BACKUP_HEALTH_MAX_RESPONSE_BYTES
                                      Optional response cap (1-65536 bytes).
                                      Defaults to 4096.
  PASSKEY_BACKUP_HEALTH_ATTEMPTS      Attempts for live health checks. Defaults
                                      to 3; maximum 5.
  PASSKEY_BACKUP_HEALTH_RETRY_DELAY_SECONDS
                                      Delay between live health attempts.
                                      Defaults to 2; maximum 30.
USAGE
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

if (($# > 0)); then
  echo "[passkey-backup-audit][error] Unknown argument: $1" >&2
  usage >&2
  exit 2
fi

failures=()
temporary_paths=()
CONFIG_FILE="$ROOT_DIR/config/passkey-backup-production.json"
OPENAPI_FILE="$ROOT_DIR/config/passkey-backup-challenge-service.openapi.json"
PASSKEY_CONFIG_RP_ID=""
PASSKEY_CONFIG_BASE_URL=""
PASSKEY_CONFIG_HEALTH_PATH=""
PASSKEY_CONFIG_REGISTRATION_CHALLENGE=""
PASSKEY_CONFIG_REGISTRATION_COMPLETE=""
PASSKEY_CONFIG_ASSERTION_CHALLENGE=""
PASSKEY_CONFIG_ASSERTION_COMPLETE=""
PASSKEY_CONFIG_CREDENTIALS_LIST=""
PASSKEY_CONFIG_CREDENTIALS_REVOKE=""
PASSKEY_CONFIG_CREDENTIALS_REVOKE_ALL=""
PASSKEY_CONFIG_ANDROID_SCOPE=""
PASSKEY_CONFIG_ANDROID_OAUTH_SCOPE=""
PASSKEY_CONFIG_IOS_ASSOCIATED_DOMAIN=""
PASSKEY_CONFIG_IOS_RECORD_TYPE=""
PASSKEY_CONFIG_IOS_CONTAINERS=""
PASSKEY_HEALTH_CURL_BIN=""

log() { echo "[passkey-backup-audit] $*"; }
warn() { echo "[passkey-backup-audit][warn] $*" >&2; }

cleanup_temporaries() {
  local path
  for path in "${temporary_paths[@]:-}"; do
    [[ -n "$path" ]] && /bin/rm -rf -- "$path"
  done
  return 0
}
trap cleanup_temporaries EXIT
trap 'cleanup_temporaries; exit 129' HUP
trap 'cleanup_temporaries; exit 130' INT
trap 'cleanup_temporaries; exit 143' TERM

body_preview() {
  local value="$1"
  value="$(printf '%s' "$value" | tr '\n\r\t' '   ' | sed -E 's/[[:space:]]+/ /g; s/^ //; s/ $//')"
  if [[ -z "$value" ]]; then
    printf '<empty body>'
  elif ((${#value} > 300)); then
    printf '%s...' "${value:0:300}"
  else
    printf '%s' "$value"
  fi
}

record_failure() {
  failures+=("$1")
  warn "$1"
}

canonical_integer_in_range() {
  local raw="$1"
  local minimum="$2"
  local maximum="$3"
  [[ "$raw" =~ ^(0|[1-9][0-9]{0,5})$ ]] || return 1
  ((10#$raw >= minimum && 10#$raw <= maximum))
}

select_health_curl() {
  local test_mode="${PASSKEY_BACKUP_HEALTH_TEST_MODE:-0}"
  local test_curl="${PASSKEY_BACKUP_HEALTH_TEST_CURL_BIN:-}"
  local target_root="$ROOT_DIR"
  if [[ -d "$ROOT_DIR" ]]; then
    target_root="$(cd "$ROOT_DIR" && pwd -P)"
  fi

  if [[ "$test_mode" == "1" ]]; then
    if [[ -z "$test_curl" ]]; then
      record_failure "PASSKEY_BACKUP_HEALTH_TEST_MODE requires PASSKEY_BACKUP_HEALTH_TEST_CURL_BIN"
      return 1
    fi
    if [[ "$target_root" == "$PRODUCTION_ROOT_DIR" ]]; then
      record_failure "Passkey backup health test curl is forbidden for the production workspace"
      return 1
    fi
    if [[ "$test_curl" != /* || ! -f "$test_curl" || ! -x "$test_curl" || -L "$test_curl" ]]; then
      record_failure "PASSKEY_BACKUP_HEALTH_TEST_CURL_BIN must be an absolute, regular, executable, non-symlink test fixture"
      return 1
    fi
    PASSKEY_HEALTH_CURL_BIN="$test_curl"
    return 0
  fi

  if [[ -n "$test_curl" ]]; then
    record_failure "PASSKEY_BACKUP_HEALTH_TEST_CURL_BIN is rejected unless PASSKEY_BACKUP_HEALTH_TEST_MODE=1"
    return 1
  fi
  if [[ ! -f "$PASSKEY_PRODUCTION_CURL_BIN" || ! -x "$PASSKEY_PRODUCTION_CURL_BIN" || -L "$PASSKEY_PRODUCTION_CURL_BIN" ]]; then
    record_failure "Canonical curl is required at $PASSKEY_PRODUCTION_CURL_BIN for passkey backup live health check"
    return 1
  fi
  PASSKEY_HEALTH_CURL_BIN="$PASSKEY_PRODUCTION_CURL_BIN"
}

run_isolated_health_curl() {
  local curl_bin="$1"
  shift
  local -a clean_environment
  clean_environment=(
    /usr/bin/env -i
    'HOME=/var/empty'
    'CURL_HOME=/var/empty'
    'XDG_CONFIG_HOME=/var/empty'
    'PATH=/usr/bin:/bin'
    'LC_ALL=C'
  )

  # Only the opt-in fixture receives test-control values. Production curl gets
  # no inherited proxy, CA, credential, curl-config, or shell-function state.
  if [[ "${PASSKEY_BACKUP_HEALTH_TEST_MODE:-0}" == "1" ]]; then
    clean_environment+=(
      "FAKE_PASSKEY_AUDIT_SCENARIO=${FAKE_PASSKEY_AUDIT_SCENARIO:-good}"
      "FAKE_PASSKEY_AUDIT_STATE_DIR=${FAKE_PASSKEY_AUDIT_STATE_DIR:-/tmp}"
    )
  fi

  "${clean_environment[@]}" "$curl_bin" "$@"
}

repo_files_matching() {
  local root="$1"
  shift
  find "$root" \
    \( -path '*/.git' -o -path '*/.gradle' -o -path '*/build' -o -path '*/Pods' -o -path '*/SourcePackages' -o -path '*/.build' -o -path '*/DerivedData' \) -prune \
    -o -type f "$@" -print
}

repo_has_pattern() {
  local root="$1"
  local pattern="$2"
  shift 2
  local file
  while IFS= read -r file; do
    if grep -Eq "$pattern" "$file"; then
      return 0
    fi
  done < <(repo_files_matching "$root" "$@")

  return 1
}

require_repo_pattern() {
  local root="$1"
  local pattern="$2"
  local description="$3"
  shift 3
  if ! repo_has_pattern "$root" "$pattern" "$@"; then
    record_failure "$description"
  fi
}

require_file_literal() {
  local file="$1"
  local literal="$2"
  local description="$3"
  if [[ ! -f "$file" ]]; then
    record_failure "$description source missing: $file"
    return
  fi
  if ! grep -Fq "$literal" "$file"; then
    record_failure "$description missing in $file"
  fi
}

reject_file_literal() {
  local file="$1"
  local literal="$2"
  local description="$3"
  if [[ -f "$file" ]] && grep -Fq "$literal" "$file"; then
    record_failure "$description present in $file"
  fi
}

load_release_config() {
  log "Checking passkey backup production release config"

  if [[ ! -f "$CONFIG_FILE" ]]; then
    record_failure "Passkey backup production config missing: $CONFIG_FILE"
    return
  fi
  if ! command -v node >/dev/null 2>&1; then
    record_failure "node is required to validate $CONFIG_FILE"
    return
  fi

  local output
  set +e
  output="$(PASSKEY_CONFIG_FILE="$CONFIG_FILE" node <<'NODE' 2>&1
const fs = require('fs');

const file = process.env.PASSKEY_CONFIG_FILE;
const expectedBaseUrl = 'https://backup.fearlesswallet.io';
const expectedPaths = {
  registrationChallenge: '/api/passkey-backup/v1/registration/challenge',
  registrationComplete: '/api/passkey-backup/v1/registration/complete',
  assertionChallenge: '/api/passkey-backup/v1/assertion/challenge',
  assertionComplete: '/api/passkey-backup/v1/assertion/complete',
  credentialsList: '/api/passkey-backup/v1/credentials/list',
  credentialsRevoke: '/api/passkey-backup/v1/credentials/revoke',
  credentialsRevokeAll: '/api/passkey-backup/v1/credentials/revoke-all',
};
const expectedMetadata = ['storageKey', 'walletId', 'accountName', 'createdAtMillis', 'schemaVersion'];
const expectedCredentialLifecycle = {
  maxCredentialsPerStorageKey: 32,
  listExposesPublicKeyOrUserHandle: false,
  singleRevokeIdempotent: true,
  revokeAllIdempotent: true,
  finalRevocationRetainsOwnerTombstone: true,
  crossSubjectTakeoverDenied: true,
  sameOwnerReregistrationAllowed: true,
  ownerErasureEndpointEnabled: false,
  cloudDeletionOrdering: 'revoke-server-credentials-before-cloud-record',
};
const expectedAndroidUx = [
  'google-account-selection',
  'google-drive-consent',
  'restore-before-create',
  'disabled-until-live-health',
];
const expectedIosUx = [
  'icloud-account-availability',
  'associated-domain-provisioning',
  'cloudkit-production-schema',
  'restore-before-create',
  'disabled-until-live-health',
];

function assert(condition, message) {
  if (!condition) throw new Error(message);
}

const data = JSON.parse(fs.readFileSync(file, 'utf8'));
assert(data.schemaVersion === 1, 'schemaVersion must be 1');
assert(data.relyingPartyId === 'fearlesswallet.io', 'relyingPartyId must be fearlesswallet.io');

const baseUrl = new URL(data.challengeServiceBaseUrl);
assert(baseUrl.protocol === 'https:', 'challengeServiceBaseUrl must use HTTPS');
assert(baseUrl.hostname === 'backup.fearlesswallet.io', 'challengeServiceBaseUrl must use the reviewed backup.fearlesswallet.io host');
assert(baseUrl.port === '', 'challengeServiceBaseUrl must use the default HTTPS port');
assert(baseUrl.hostname && !['localhost', '127.0.0.1', '0.0.0.0'].includes(baseUrl.hostname), 'challengeServiceBaseUrl must not be local');
assert(!baseUrl.hostname.endsWith('.example') && !baseUrl.hostname.includes('example.'), 'challengeServiceBaseUrl must not be an example domain');
assert(baseUrl.username === '' && baseUrl.password === '', 'challengeServiceBaseUrl must not contain credentials');
assert(baseUrl.search === '' && baseUrl.hash === '', 'challengeServiceBaseUrl must not contain query strings or fragments');
assert(baseUrl.pathname === '' || baseUrl.pathname === '/', 'challengeServiceBaseUrl must not contain a path');
assert(data.challengeServiceBaseUrl === expectedBaseUrl, `challengeServiceBaseUrl must exactly match ${expectedBaseUrl}`);

assert(data.healthPath === '/api/passkey-backup/v1/health', 'healthPath must be /api/passkey-backup/v1/health');
assert(JSON.stringify(Object.keys(data.challengeServicePaths ?? {})) === JSON.stringify(Object.keys(expectedPaths)), 'challengeServicePaths must expose exactly seven POST routes');
for (const [key, value] of Object.entries(expectedPaths)) {
  assert(data.challengeServicePaths?.[key] === value, `${key} path must be ${value}`);
}
assert(Array.isArray(data.encryptedBackupMetadata), 'encryptedBackupMetadata must be an array');
assert(JSON.stringify(data.encryptedBackupMetadata) === JSON.stringify(expectedMetadata), 'encryptedBackupMetadata must exactly contain storageKey, walletId, accountName, createdAtMillis, and schemaVersion');
assert(JSON.stringify(data.credentialLifecycle) === JSON.stringify(expectedCredentialLifecycle), 'credentialLifecycle must retain the bounded tombstone and server-first deletion contract');
assert(data.requestAuthorization?.failClosed === true, 'requestAuthorization must fail closed');
assert(JSON.stringify(data.requestAuthorization?.protectedPaths) === JSON.stringify(Object.values(expectedPaths)), 'requestAuthorization.protectedPaths must cover all seven POST routes exactly');

assert(data.android?.backupStorage === 'google-drive-appdata', 'Android backupStorage must be google-drive-appdata');
assert(data.android?.googleDriveScope === 'https://www.googleapis.com/auth/drive.appdata', 'Android Drive scope must be appdata');
assert(data.android?.oauthScope === 'oauth2:https://www.googleapis.com/auth/drive.appdata', 'Android OAuth scope must be appdata');
assert(Array.isArray(data.android?.releaseUxChecklist), 'Android releaseUxChecklist must be an array');
assert(expectedAndroidUx.every((field) => data.android.releaseUxChecklist.includes(field)), 'Android releaseUxChecklist must include google-account-selection, google-drive-consent, restore-before-create, and disabled-until-live-health');

assert(data.ios?.backupStorage === 'cloudkit-private-database', 'iOS backupStorage must be cloudkit-private-database');
assert(data.ios?.associatedDomain === 'webcredentials:fearlesswallet.io', 'iOS associated domain must match RP ID');
assert(data.ios?.cloudKitRecordType === 'FearlessPasskeyBackup', 'iOS CloudKit record type must be FearlessPasskeyBackup');
assert(Array.isArray(data.ios?.cloudKitContainers) && data.ios.cloudKitContainers.length === 2, 'iOS CloudKit containers must contain exactly the release and dev containers');
assert(data.ios.cloudKitContainers[0] === 'iCloud.jp.co.soramitsu.fearlesswallet', 'iOS release CloudKit container must match the App Store bundle identifier');
assert(data.ios.cloudKitContainers[1] === 'iCloud.jp.co.soramitsu.fearlesswallet.dev', 'iOS dev CloudKit container must match the development bundle identifier');
assert(Array.isArray(data.ios?.releaseUxChecklist), 'iOS releaseUxChecklist must be an array');
assert(expectedIosUx.every((field) => data.ios.releaseUxChecklist.includes(field)), 'iOS releaseUxChecklist must include icloud-account-availability, associated-domain-provisioning, cloudkit-production-schema, restore-before-create, and disabled-until-live-health');

const pairs = {
  RP_ID: data.relyingPartyId,
  BASE_URL: baseUrl.origin,
  HEALTH_PATH: data.healthPath,
  REGISTRATION_CHALLENGE: data.challengeServicePaths.registrationChallenge,
  REGISTRATION_COMPLETE: data.challengeServicePaths.registrationComplete,
  ASSERTION_CHALLENGE: data.challengeServicePaths.assertionChallenge,
  ASSERTION_COMPLETE: data.challengeServicePaths.assertionComplete,
  CREDENTIALS_LIST: data.challengeServicePaths.credentialsList,
  CREDENTIALS_REVOKE: data.challengeServicePaths.credentialsRevoke,
  CREDENTIALS_REVOKE_ALL: data.challengeServicePaths.credentialsRevokeAll,
  ANDROID_SCOPE: data.android.googleDriveScope,
  ANDROID_OAUTH_SCOPE: data.android.oauthScope,
  IOS_ASSOCIATED_DOMAIN: data.ios.associatedDomain,
  IOS_RECORD_TYPE: data.ios.cloudKitRecordType,
  IOS_CONTAINERS: data.ios.cloudKitContainers.join(','),
};

for (const [key, value] of Object.entries(pairs)) {
  console.log(`${key}=${value}`);
}
NODE
)"
  local status=$?
  set -e

  if [[ "$status" -ne 0 ]]; then
    record_failure "Passkey backup production config invalid: $output"
    return
  fi

  local key value
  while IFS='=' read -r key value; do
    case "$key" in
      RP_ID) PASSKEY_CONFIG_RP_ID="$value" ;;
      BASE_URL) PASSKEY_CONFIG_BASE_URL="$value" ;;
      HEALTH_PATH) PASSKEY_CONFIG_HEALTH_PATH="$value" ;;
      REGISTRATION_CHALLENGE) PASSKEY_CONFIG_REGISTRATION_CHALLENGE="$value" ;;
      REGISTRATION_COMPLETE) PASSKEY_CONFIG_REGISTRATION_COMPLETE="$value" ;;
      ASSERTION_CHALLENGE) PASSKEY_CONFIG_ASSERTION_CHALLENGE="$value" ;;
      ASSERTION_COMPLETE) PASSKEY_CONFIG_ASSERTION_COMPLETE="$value" ;;
      CREDENTIALS_LIST) PASSKEY_CONFIG_CREDENTIALS_LIST="$value" ;;
      CREDENTIALS_REVOKE) PASSKEY_CONFIG_CREDENTIALS_REVOKE="$value" ;;
      CREDENTIALS_REVOKE_ALL) PASSKEY_CONFIG_CREDENTIALS_REVOKE_ALL="$value" ;;
      ANDROID_SCOPE) PASSKEY_CONFIG_ANDROID_SCOPE="$value" ;;
      ANDROID_OAUTH_SCOPE) PASSKEY_CONFIG_ANDROID_OAUTH_SCOPE="$value" ;;
      IOS_ASSOCIATED_DOMAIN) PASSKEY_CONFIG_IOS_ASSOCIATED_DOMAIN="$value" ;;
      IOS_RECORD_TYPE) PASSKEY_CONFIG_IOS_RECORD_TYPE="$value" ;;
      IOS_CONTAINERS) PASSKEY_CONFIG_IOS_CONTAINERS="$value" ;;
    esac
  done <<< "$output"
}

check_challenge_service_openapi_contract() {
  log "Checking passkey backup challenge service OpenAPI contract"

  if [[ -z "$PASSKEY_CONFIG_RP_ID" ]]; then
    return
  fi
  if [[ ! -f "$OPENAPI_FILE" ]]; then
    record_failure "Passkey backup challenge service OpenAPI contract missing: $OPENAPI_FILE"
    return
  fi
  if ! command -v node >/dev/null 2>&1; then
    record_failure "node is required to validate $OPENAPI_FILE"
    return
  fi

  local output
  set +e
  output="$(
    PASSKEY_CONFIG_FILE="$CONFIG_FILE" \
    PASSKEY_OPENAPI_FILE="$OPENAPI_FILE" \
    node <<'NODE' 2>&1
const fs = require('fs');

const config = JSON.parse(fs.readFileSync(process.env.PASSKEY_CONFIG_FILE, 'utf8'));
const spec = JSON.parse(fs.readFileSync(process.env.PASSKEY_OPENAPI_FILE, 'utf8'));
const paths = config.challengeServicePaths;
const requiredPaths = {
  [config.healthPath]: { method: 'get', response: 'HealthResponse' },
  [paths.registrationChallenge]: {
    method: 'post',
    request: 'RegistrationChallengeRequest',
    response: 'RegistrationChallengeResponse',
  },
  [paths.registrationComplete]: {
    method: 'post',
    request: 'RegistrationCompleteRequest',
    response: 'ChallengeResult',
  },
  [paths.assertionChallenge]: {
    method: 'post',
    request: 'AssertionChallengeRequest',
    response: 'AssertionChallengeResponse',
  },
  [paths.assertionComplete]: {
    method: 'post',
    request: 'AssertionCompleteRequest',
    response: 'ChallengeResult',
  },
  [paths.credentialsList]: {
    method: 'post',
    request: 'CredentialListRequest',
    response: 'CredentialListResponse',
  },
  [paths.credentialsRevoke]: {
    method: 'post',
    request: 'CredentialRevokeRequest',
    response: 'CredentialRevokeResponse',
  },
  [paths.credentialsRevokeAll]: {
    method: 'post',
    request: 'CredentialListRequest',
    response: 'CredentialRevokeAllResponse',
  },
};
const schemaRequirements = {
  HealthResponse: ['ok', 'service', 'rpId', 'schemaVersion'],
  RegistrationChallengeRequest: ['walletId', 'accountName', 'displayName', 'rpId', 'schemaVersion'],
  RegistrationChallengeResponse: ['registrationId', 'challenge', 'userId', 'userName', 'displayName', 'storageKey', 'rpId', 'schemaVersion'],
  RegistrationCompleteRequest: ['registrationId', 'rpId', 'credential'],
  AssertionChallengeRequest: ['storageKey', 'rpId', 'schemaVersion'],
  AssertionChallengeResponse: ['assertionId', 'challenge', 'storageKey', 'rpId', 'schemaVersion'],
  AssertionCompleteRequest: ['assertionId', 'rpId', 'credential'],
  ChallengeResult: ['storageKey', 'rpId', 'schemaVersion'],
  RegistrationCredentialResponse: ['id', 'rawId', 'type', 'clientExtensionResults', 'response'],
  RegistrationAuthenticatorResponse: ['clientDataJSON', 'attestationObject'],
  AssertionCredentialResponse: ['id', 'rawId', 'type', 'clientExtensionResults', 'response'],
  AssertionAuthenticatorResponse: ['clientDataJSON', 'authenticatorData', 'signature', 'userHandle'],
  CredentialListRequest: ['storageKey', 'rpId', 'schemaVersion'],
  CredentialRevokeRequest: ['storageKey', 'credentialId', 'rpId', 'schemaVersion'],
  CredentialListResponse: ['storageKey', 'credentials', 'rpId', 'schemaVersion'],
  CredentialRevokeResponse: ['storageKey', 'credentialId', 'remainingCredentials', 'rpId', 'schemaVersion'],
  CredentialRevokeAllResponse: ['storageKey', 'remainingCredentials', 'rpId', 'schemaVersion'],
};

function assert(condition, message) {
  if (!condition) throw new Error(message);
}

function schemaRefName(ref) {
  const prefix = '#/components/schemas/';
  assert(typeof ref === 'string' && ref.startsWith(prefix), `schema ref must point to components/schemas, got ${ref}`);
  return ref.slice(prefix.length);
}

function contentSchema(operation, status, context) {
  const response = operation.responses?.[status];
  assert(response, `${context} must define HTTP ${status}`);
  const schema = response.content?.['application/json']?.schema;
  assert(schema, `${context} HTTP ${status} must define application/json schema`);
  return schemaRefName(schema.$ref);
}

function requestSchema(operation, context) {
  assert(operation.requestBody?.required === true, `${context} requestBody must be required`);
  const schema = operation.requestBody.content?.['application/json']?.schema;
  assert(schema, `${context} must define application/json request schema`);
  return schemaRefName(schema.$ref);
}

function assertRequired(schemaName, fields) {
  const schema = spec.components?.schemas?.[schemaName];
  assert(schema, `${schemaName} schema missing`);
  assert(schema.type === 'object', `${schemaName} schema must be an object`);
  assert(schema.additionalProperties === false, `${schemaName} must reject additional properties`);
  for (const field of fields) {
    assert(schema.required?.includes(field), `${schemaName} schema must require ${field}`);
  }
}

assert(/^3\./.test(String(spec.openapi)), 'OpenAPI version must be 3.x');
assert(spec.servers?.some((server) => server.url === config.challengeServiceBaseUrl), 'OpenAPI servers must include the production challengeServiceBaseUrl');

for (const [path, expectation] of Object.entries(requiredPaths)) {
  const operation = spec.paths?.[path]?.[expectation.method];
  assert(operation, `${path} ${expectation.method.toUpperCase()} operation missing`);
  if (expectation.request) {
    assert(requestSchema(operation, path) === expectation.request, `${path} request schema must be ${expectation.request}`);
  }
  if (expectation.method === 'post') {
    assert(JSON.stringify(operation.security) === JSON.stringify([{ bearerAuth: [] }]), `${path} must require bearerAuth`);
  }
  assert(contentSchema(operation, '200', path) === expectation.response, `${path} response schema must be ${expectation.response}`);
}

for (const [schemaName, fields] of Object.entries(schemaRequirements)) {
  assertRequired(schemaName, fields);
}

const schemas = spec.components.schemas;
assert(schemas.HealthResponse.properties.ok.const === true, 'HealthResponse ok must be const true');
assert(schemas.HealthResponse.properties.service.const === 'fearless-passkey-backup', 'HealthResponse service must identify fearless-passkey-backup');
assert(schemas.HealthResponse.properties.rpId.const === config.relyingPartyId, 'HealthResponse rpId must match relyingPartyId');
assert(schemas.HealthResponse.properties.schemaVersion.const === config.schemaVersion, 'HealthResponse schemaVersion must match schemaVersion');
assert(schemas.RelyingPartyId.const === config.relyingPartyId, 'RelyingPartyId const must match relyingPartyId');
assert(schemas.SchemaVersion.const === config.schemaVersion, 'SchemaVersion const must match schemaVersion');
for (const schemaName of ['WalletId', 'StorageKey', 'CeremonyId']) {
  assert(schemas[schemaName].pattern === '^[A-Za-z0-9._:-]{8,128}$', `${schemaName} pattern must match mobile validators`);
}
assert(schemas.AccountName.pattern === '^[^\\s@]+@[^\\s@]+$', 'AccountName pattern must reject whitespace and require email shape');
assert(schemaRefName(schemas.RegistrationCompleteRequest.properties?.credential?.$ref) === 'RegistrationCredentialResponse', 'RegistrationCompleteRequest credential must use the registration WebAuthn schema');
assert(schemaRefName(schemas.AssertionCompleteRequest.properties?.credential?.$ref) === 'AssertionCredentialResponse', 'AssertionCompleteRequest credential must use the assertion WebAuthn schema');
assert(schemas.Base64UrlCredentialId.minLength === 1, 'Base64UrlCredentialId must be non-empty');
assert(schemas.Base64UrlCredentialId.maxLength === 512, 'Base64UrlCredentialId must be bounded');
assert(schemaRefName(schemas.RegistrationCredentialResponse.properties?.id?.$ref) === 'Base64UrlCredentialId', 'registration credential id must use Base64UrlCredentialId');
assert(schemaRefName(schemas.RegistrationCredentialResponse.properties?.rawId?.$ref) === 'Base64UrlCredentialId', 'registration credential rawId must use Base64UrlCredentialId');
assert(schemaRefName(schemas.RegistrationCredentialResponse.properties?.response?.$ref) === 'RegistrationAuthenticatorResponse', 'registration credential response must reference RegistrationAuthenticatorResponse');
assert(schemaRefName(schemas.RegistrationAuthenticatorResponse.properties?.clientDataJSON?.$ref) === 'Base64UrlBlob', 'registration clientDataJSON must use Base64UrlBlob');
assert(schemaRefName(schemas.RegistrationAuthenticatorResponse.properties?.attestationObject?.$ref) === 'Base64UrlBlob', 'registration attestationObject must use Base64UrlBlob');
assert(schemaRefName(schemas.AssertionCredentialResponse.properties?.id?.$ref) === 'Base64UrlCredentialId', 'assertion credential id must use Base64UrlCredentialId');
assert(schemaRefName(schemas.AssertionCredentialResponse.properties?.response?.$ref) === 'AssertionAuthenticatorResponse', 'assertion credential response must reference AssertionAuthenticatorResponse');
for (const field of ['clientDataJSON', 'authenticatorData', 'signature']) {
  assert(schemaRefName(schemas.AssertionAuthenticatorResponse.properties?.[field]?.$ref) === 'Base64UrlBlob', `assertion ${field} must use Base64UrlBlob`);
}
assert(schemaRefName(schemas.AssertionAuthenticatorResponse.properties?.userHandle?.$ref) === 'Base64UrlUserId', 'assertion userHandle must use Base64UrlUserId');
assert(schemas.CredentialListResponse.properties?.credentials?.maxItems === 32, 'CredentialListResponse credentials must be bounded to 32');
assert(schemaRefName(schemas.CredentialListResponse.properties?.credentials?.items?.$ref) === 'CredentialDescriptor', 'CredentialListResponse credentials must use CredentialDescriptor');
assert(schemas.CredentialDescriptor?.additionalProperties === false, 'CredentialDescriptor must reject additional properties');
for (const secretField of ['publicKey', 'userId', 'counter', 'ownerSubjectHash']) {
  assert(!Object.hasOwn(schemas.CredentialDescriptor.properties ?? {}, secretField), `CredentialDescriptor must not expose ${secretField}`);
}
assert(schemas.CredentialRevokeResponse.properties?.remainingCredentials?.maximum === 32, 'CredentialRevokeResponse remainingCredentials must be bounded to 32');
assert(schemas.CredentialRevokeAllResponse.properties?.remainingCredentials?.const === 0, 'CredentialRevokeAllResponse remainingCredentials must be zero');
NODE
)"
  local status=$?
  set -e

  if [[ "$status" -ne 0 ]]; then
    record_failure "Passkey backup challenge service OpenAPI contract invalid: $output"
  fi
}

check_release_config_sources() {
  if [[ -z "$PASSKEY_CONFIG_RP_ID" ]]; then
    return
  fi

  local android_contract="$ROOT_DIR/fearless-Android/public-shared-features-backup/src/main/java/jp/co/soramitsu/backup/passkey/PasskeyBackupContract.kt"
  local android_challenge="$ROOT_DIR/fearless-Android/public-shared-features-backup/src/main/java/jp/co/soramitsu/backup/passkey/PasskeyBackupChallengeService.kt"
  local android_drive="$ROOT_DIR/fearless-Android/public-shared-features-backup/src/main/java/jp/co/soramitsu/backup/passkey/GoogleDrivePasskeyBackupCloudStorage.kt"
  local android_token="$ROOT_DIR/fearless-Android/public-shared-features-backup/src/main/java/jp/co/soramitsu/backup/passkey/GoogleDrivePasskeyBackupTokenProvider.kt"
  local ios_contract="$ROOT_DIR/fearless-iOS/fearless/Common/Model/PasskeyBackupContract.swift"
  local ios_serializer_test="$ROOT_DIR/fearless-iOS/fearlessTests/PasskeyBackupCredentialResponseSerializerTests.swift"
  local ios_entitlements="$ROOT_DIR/fearless-iOS/fearless/WalletConnect.entitlements"
  local ios_project="$ROOT_DIR/fearless-iOS/fearless.xcodeproj/project.pbxproj"
  local android_release="$ROOT_DIR/fearless-Android/docs/release-checklist.md"
  local ios_release="$ROOT_DIR/fearless-iOS/docs/release-checklist.md"

  require_file_literal "$android_contract" "PASSKEY_RP_ID = \"$PASSKEY_CONFIG_RP_ID\"" "Android passkey RP ID"
  require_file_literal "$android_contract" "CHALLENGE_SERVICE_BASE_URL = \"$PASSKEY_CONFIG_BASE_URL\"" "Android passkey challenge service URL"
  require_file_literal "$android_contract" "PASSKEY_BACKUP_ENABLED = false" "Android passkey backup release flag disabled by default"
  require_file_literal "$android_contract" "fun requireWalletId" "Android passkey backup wallet metadata validator"
  require_file_literal "$android_contract" "fun requireCreatedAtMillis" "Android passkey backup creation timestamp validator"
  require_file_literal "$android_contract" "val walletId: String" "Android passkey encrypted payload wallet metadata"
  require_file_literal "$android_contract" "val accountName: String" "Android passkey encrypted payload account metadata"
  require_file_literal "$android_contract" "val createdAtMillis: Long" "Android passkey encrypted payload creation timestamp metadata"
  require_file_literal "$android_challenge" "$PASSKEY_CONFIG_REGISTRATION_CHALLENGE" "Android registration challenge path"
  require_file_literal "$android_challenge" "$PASSKEY_CONFIG_REGISTRATION_COMPLETE" "Android registration completion path"
  require_file_literal "$android_challenge" "$PASSKEY_CONFIG_ASSERTION_CHALLENGE" "Android assertion challenge path"
  require_file_literal "$android_challenge" "$PASSKEY_CONFIG_ASSERTION_COMPLETE" "Android assertion completion path"
  require_file_literal "$android_challenge" "$PASSKEY_CONFIG_CREDENTIALS_LIST" "Android credential list path"
  require_file_literal "$android_challenge" "$PASSKEY_CONFIG_CREDENTIALS_REVOKE" "Android credential revoke path"
  require_file_literal "$android_challenge" "$PASSKEY_CONFIG_CREDENTIALS_REVOKE_ALL" "Android credential revoke-all path"
  require_file_literal "$android_drive" "$PASSKEY_CONFIG_ANDROID_SCOPE" "Android Drive appdata scope"
  require_file_literal "$android_drive" "oauth2:\$APP_DATA_SCOPE" "Android Drive OAuth scope derivation"
  require_file_literal "$android_drive" 'addProperty("walletId"' "Android Drive passkey backup wallet metadata persistence"
  require_file_literal "$android_drive" 'addProperty("accountName"' "Android Drive passkey backup account metadata persistence"
  require_file_literal "$android_drive" 'addProperty("createdAtMillis"' "Android Drive passkey backup creation timestamp persistence"
  require_file_literal "$android_drive" 'requiredAppProperty(appProperties, "walletId")' "Android Drive passkey backup wallet metadata load validation"
  require_file_literal "$android_drive" 'requiredAppProperty(appProperties, "accountName")' "Android Drive passkey backup account metadata load validation"
  require_file_literal "$android_drive" 'requiredAppProperty(appProperties, "createdAtMillis")' "Android Drive passkey backup creation timestamp load validation"
  require_file_literal "$android_token" "GoogleAuthUtil" "Android Google Drive token fetcher"

  require_file_literal "$ios_contract" "PASSKEY_RP_ID = \"$PASSKEY_CONFIG_RP_ID\"" "iOS passkey RP ID"
  require_file_literal "$ios_contract" "challengeServiceBaseURL = URL(string: \"$PASSKEY_CONFIG_BASE_URL\")!" "iOS passkey challenge service URL"
  require_file_literal "$ios_contract" "isPasskeyBackupEnabled = false" "iOS passkey backup release flag disabled by default"
  require_file_literal "$ios_contract" "recordType = \"$PASSKEY_CONFIG_IOS_RECORD_TYPE\"" "iOS CloudKit record type"
  require_file_literal "$ios_contract" "static func validateWalletId" "iOS passkey backup wallet metadata validator"
  require_file_literal "$ios_contract" "static func validateCreatedAtMillis" "iOS passkey backup creation timestamp validator"
  require_file_literal "$ios_contract" "let walletId: String" "iOS passkey encrypted record wallet metadata"
  require_file_literal "$ios_contract" "let accountName: String" "iOS passkey encrypted record account metadata"
  require_file_literal "$ios_contract" "let createdAtMillis: Int64" "iOS passkey encrypted record creation timestamp metadata"
  require_file_literal "$ios_contract" 'storageKeyField = "storageKey"' "iOS CloudKit passkey backup storage key metadata persistence"
  require_file_literal "$ios_contract" 'walletIdField = "walletId"' "iOS CloudKit passkey backup wallet metadata persistence"
  require_file_literal "$ios_contract" 'accountNameField = "accountName"' "iOS CloudKit passkey backup account metadata persistence"
  require_file_literal "$ios_contract" 'createdAtMillisField = "createdAtMillis"' "iOS CloudKit passkey backup creation timestamp persistence"
  require_file_literal "$ios_contract" "$PASSKEY_CONFIG_REGISTRATION_CHALLENGE" "iOS registration challenge path"
  require_file_literal "$ios_contract" "$PASSKEY_CONFIG_REGISTRATION_COMPLETE" "iOS registration completion path"
  require_file_literal "$ios_contract" "$PASSKEY_CONFIG_ASSERTION_CHALLENGE" "iOS assertion challenge path"
  require_file_literal "$ios_contract" "$PASSKEY_CONFIG_ASSERTION_COMPLETE" "iOS assertion completion path"
  require_file_literal "$ios_contract" "$PASSKEY_CONFIG_CREDENTIALS_LIST" "iOS credential list path"
  require_file_literal "$ios_contract" "$PASSKEY_CONFIG_CREDENTIALS_REVOKE" "iOS credential revoke path"
  require_file_literal "$ios_contract" "$PASSKEY_CONFIG_CREDENTIALS_REVOKE_ALL" "iOS credential revoke-all path"
  require_file_literal "$ios_contract" "enum PasskeyCredentialResponseSerializer" "iOS standard WebAuthn credential response serializer"
  require_file_literal "$ios_contract" "ASAuthorizationPlatformPublicKeyCredentialRegistration" "iOS typed WebAuthn registration credential serializer"
  require_file_literal "$ios_contract" "ASAuthorizationPlatformPublicKeyCredentialAssertion" "iOS typed WebAuthn assertion credential serializer"
  require_file_literal "$ios_contract" '"rawId": encodedCredentialID' "iOS WebAuthn credential rawId binding"
  require_file_literal "$ios_contract" '"type": "public-key"' "iOS WebAuthn public-key credential type"
  require_file_literal "$ios_contract" '"clientExtensionResults": [String: Any]()' "iOS WebAuthn client extension result envelope"
  require_file_literal "$ios_contract" '"attestationObject"' "iOS WebAuthn registration attestation serialization"
  require_file_literal "$ios_contract" '"authenticatorData"' "iOS WebAuthn authenticator-data serialization"
  require_file_literal "$ios_contract" '"signature"' "iOS WebAuthn assertion signature serialization"
  require_file_literal "$ios_contract" '"userHandle"' "iOS WebAuthn assertion user-handle serialization"
  require_file_literal "$ios_contract" "userHandle: Data" "iOS WebAuthn assertion user handle required by the challenge service"
  reject_file_literal "$ios_contract" "userHandle: Data?" "iOS WebAuthn optional assertion user handle is forbidden by the challenge service"
  require_file_literal "$ios_contract" 'replacingOccurrences(of: "+", with: "-")' "iOS WebAuthn base64url plus normalization"
  require_file_literal "$ios_contract" 'replacingOccurrences(of: "/", with: "_")' "iOS WebAuthn base64url slash normalization"
  require_file_literal "$ios_contract" 'replacingOccurrences(of: "=", with: "")' "iOS WebAuthn unpadded base64url serialization"
  require_file_literal "$ios_contract" 'maximumResponseBytes = 256 * 1024' "iOS passkey transport hard response-size ceiling"
  require_file_literal "$ios_contract" 'response.body.count <= PasskeyBackupHTTPTransportPolicy.maximumResponseBytes' "iOS passkey service injected-transport response-size guard"
  require_file_literal "$ios_contract" 'PasskeyBackupHTTPTransportPolicy.followsRedirects ? request : nil' "iOS passkey transport fail-closed redirect policy"
  require_file_literal "$ios_contract" 'withTaskCancellationHandler' "iOS passkey transport structured-cancellation propagation"
  require_file_literal "$ios_contract" 'result.credentialId == credentialId' "iOS registration compensation credential-identity validation"
  require_file_literal "$ios_contract" 'revoked.credentialId == nil' "iOS revoke-all response credential-identity rejection"
  require_file_literal "$ios_serializer_test" "PasskeyCredentialResponseSerializerTests" "iOS WebAuthn serializer test suite"
  require_file_literal "$ios_serializer_test" "testRegistrationSerializerProducesWebAuthnEnvelopeAndBase64URLFields" "iOS WebAuthn registration serialization test"
  require_file_literal "$ios_serializer_test" "testAssertionSerializerProducesRequiredWebAuthnResponseFields" "iOS WebAuthn assertion serialization test"
  require_file_literal "$ios_serializer_test" "testRegistrationSerializerRejectsEveryEmptyRequiredField" "iOS WebAuthn registration empty-field adversarial test"
  require_file_literal "$ios_serializer_test" "testAssertionSerializerRejectsEveryEmptyRequiredField" "iOS WebAuthn assertion empty-field adversarial test"
  require_file_literal "$ios_serializer_test" "testSerializerRejectsFieldsBeyondChallengeServiceLimits" "iOS WebAuthn oversized-field adversarial test"
  require_file_literal "$ios_serializer_test" "testSerializerAcceptsFieldsAtChallengeServiceLimits" "iOS WebAuthn boundary acceptance test"
  require_file_literal "$ios_serializer_test" "testChallengeClientRejectsOversizedInjectedTransportResponsesBeforeStatusOrJSON" "iOS injected-transport oversized-response adversarial test"
  require_file_literal "$ios_serializer_test" "testURLSessionTransportRejectsInvalidResponseLimits" "iOS invalid transport response-limit adversarial test"
  require_file_literal "$ios_serializer_test" "testURLSessionTransportRejectsOversizedDeclaredResponseBeforeBody" "iOS declared oversized-response adversarial test"
  require_file_literal "$ios_serializer_test" "testURLSessionTransportRejectsChunkedResponseBeyondLimit" "iOS streamed oversized-response adversarial test"
  require_file_literal "$ios_serializer_test" "testURLSessionTransportBoundsDecodedStreamingBytes" "iOS compressed-expansion oversized-response adversarial test"
  require_file_literal "$ios_serializer_test" "testURLSessionTransportCancellationStopsTaskAndClearsState" "iOS transport cancellation cleanup adversarial test"
  require_file_literal "$ios_serializer_test" "testRegistrationCompensationRejectsMismatchedRevokeResultIdentities" "iOS compensation response-identity adversarial test"
  require_file_literal "$ios_serializer_test" "testWorkflowRejectsRevokeAllResultContainingCredentialIdentity" "iOS workflow revoke-all identity-injection adversarial test"
  require_file_literal "$ios_serializer_test" "testCoordinatorRejectsRevokeAllResultContainingCredentialIdentity" "iOS coordinator revoke-all identity-injection adversarial test"
  require_file_literal "$ios_entitlements" "$PASSKEY_CONFIG_IOS_ASSOCIATED_DOMAIN" "iOS associated-domain entitlement"
  require_file_literal "$ios_entitlements" 'iCloud.$(PRODUCT_BUNDLE_IDENTIFIER)' "iOS configuration-resolved CloudKit container entitlement"
  require_file_literal "$ios_entitlements" 'group.$(PRODUCT_BUNDLE_IDENTIFIER)' "iOS configuration-resolved application-group entitlement"
  reject_file_literal "$ios_entitlements" '<key>keychain-access-groups</key>' "iOS unprovisioned explicit keychain access-group entitlement"
  require_file_literal "$ios_project" 'PRODUCT_BUNDLE_IDENTIFIER = jp.co.soramitsu.fearlesswallet;' "iOS App Store bundle identifier"
  require_file_literal "$ios_project" 'PRODUCT_BUNDLE_IDENTIFIER = jp.co.soramitsu.fearlesswallet.dev;' "iOS development bundle identifier"

  require_file_literal "$android_release" "config/passkey-backup-production.json" "Android release checklist passkey production config"
  require_file_literal "$android_release" "PASSKEY_BACKUP_ENABLED" "Android release checklist passkey release flag"
  require_file_literal "$android_release" "Google account selection" "Android release checklist passkey Google account selection UX"
  require_file_literal "$android_release" "Google Drive consent" "Android release checklist passkey Google Drive consent UX"
  require_file_literal "$android_release" "restore before creating a new backup" "Android release checklist passkey recovery UX"
  require_file_literal "$ios_release" "config/passkey-backup-production.json" "iOS release checklist passkey production config"
  require_file_literal "$ios_release" "isPasskeyBackupEnabled" "iOS release checklist passkey release flag"
  require_file_literal "$ios_release" "iCloud account availability" "iOS release checklist passkey iCloud account UX"
  require_file_literal "$ios_release" "CloudKit production schema" "iOS release checklist passkey CloudKit production schema"
  require_file_literal "$ios_release" "associated-domain provisioning" "iOS release checklist passkey associated-domain provisioning"
  require_file_literal "$ios_release" "provisioning profiles" "iOS release checklist passkey provisioning profiles"
  require_file_literal "$ios_release" "restore before creating a new backup" "iOS release checklist passkey recovery UX"
}

check_live_challenge_service() {
  case "${PASSKEY_BACKUP_LIVE_HEALTH:-0}" in
    0|false|'') return ;;
    1|true) ;;
    *)
      record_failure "PASSKEY_BACKUP_LIVE_HEALTH must be exactly 0, false, 1, or true"
      return
      ;;
  esac
  if [[ -z "$PASSKEY_CONFIG_BASE_URL" || -z "$PASSKEY_CONFIG_HEALTH_PATH" ]]; then
    record_failure "Passkey backup live health requires a valid production config"
    return
  fi
  if ! select_health_curl; then
    return
  fi

  local health_url="${PASSKEY_CONFIG_BASE_URL}${PASSKEY_CONFIG_HEALTH_PATH}"
  if [[ "$PASSKEY_CONFIG_BASE_URL" != "$PASSKEY_REVIEWED_BASE_URL" ||
        "$PASSKEY_CONFIG_HEALTH_PATH" != "$PASSKEY_REVIEWED_HEALTH_PATH" ||
        "$health_url" != "$PASSKEY_REVIEWED_HEALTH_URL" ]]; then
    record_failure "Passkey backup live health URL must exactly match $PASSKEY_REVIEWED_HEALTH_URL"
    return
  fi

  local timeout="${PASSKEY_BACKUP_HEALTH_TIMEOUT_SECONDS:-$PASSKEY_HEALTH_DEFAULT_TIMEOUT_SECONDS}"
  local connect_timeout="${PASSKEY_BACKUP_HEALTH_CONNECT_TIMEOUT_SECONDS:-$PASSKEY_HEALTH_DEFAULT_CONNECT_TIMEOUT_SECONDS}"
  local max_response_bytes="${PASSKEY_BACKUP_HEALTH_MAX_RESPONSE_BYTES:-$PASSKEY_HEALTH_DEFAULT_MAX_RESPONSE_BYTES}"
  local attempts="${PASSKEY_BACKUP_HEALTH_ATTEMPTS:-3}"
  local delay="${PASSKEY_BACKUP_HEALTH_RETRY_DELAY_SECONDS:-2}"
  if ! canonical_integer_in_range "$timeout" 1 "$PASSKEY_HEALTH_MAX_TIMEOUT_SECONDS"; then
    record_failure "PASSKEY_BACKUP_HEALTH_TIMEOUT_SECONDS must be a canonical integer from 1 through $PASSKEY_HEALTH_MAX_TIMEOUT_SECONDS"
    return
  fi
  if ! canonical_integer_in_range "$connect_timeout" 1 "$PASSKEY_HEALTH_MAX_TIMEOUT_SECONDS"; then
    record_failure "PASSKEY_BACKUP_HEALTH_CONNECT_TIMEOUT_SECONDS must be a canonical integer from 1 through $PASSKEY_HEALTH_MAX_TIMEOUT_SECONDS"
    return
  fi
  if ((10#$connect_timeout > 10#$timeout)); then
    record_failure "PASSKEY_BACKUP_HEALTH_CONNECT_TIMEOUT_SECONDS must not exceed PASSKEY_BACKUP_HEALTH_TIMEOUT_SECONDS"
    return
  fi
  if ! canonical_integer_in_range "$max_response_bytes" 1 "$PASSKEY_HEALTH_MAX_RESPONSE_BYTES"; then
    record_failure "PASSKEY_BACKUP_HEALTH_MAX_RESPONSE_BYTES must be a canonical integer from 1 through $PASSKEY_HEALTH_MAX_RESPONSE_BYTES"
    return
  fi
  if ! canonical_integer_in_range "$attempts" 1 "$PASSKEY_HEALTH_MAX_ATTEMPTS"; then
    record_failure "PASSKEY_BACKUP_HEALTH_ATTEMPTS must be a canonical integer from 1 through $PASSKEY_HEALTH_MAX_ATTEMPTS"
    return
  fi
  if ! canonical_integer_in_range "$delay" 0 "$PASSKEY_HEALTH_MAX_RETRY_DELAY_SECONDS"; then
    record_failure "PASSKEY_BACKUP_HEALTH_RETRY_DELAY_SECONDS must be a canonical integer from 0 through $PASSKEY_HEALTH_MAX_RETRY_DELAY_SECONDS"
    return
  fi

  local curl_version_output first_version_line major_version minor_version
  local status
  set +e
  curl_version_output="$(run_isolated_health_curl "$PASSKEY_HEALTH_CURL_BIN" --disable --version 2>/dev/null)"
  status=$?
  set -e
  first_version_line="${curl_version_output%%$'\n'*}"
  if [[ "$status" -ne 0 || ! "$first_version_line" =~ ^curl[[:space:]]+([0-9]+)\.([0-9]+)\.[0-9]+ ]]; then
    record_failure "Canonical curl version could not be verified for the passkey backup health response-size contract"
    return
  fi
  major_version="${BASH_REMATCH[1]}"
  minor_version="${BASH_REMATCH[2]}"
  if ((major_version < 8 || (major_version == 8 && minor_version < 4))); then
    record_failure "curl 8.4 or newer is required so --max-filesize bounds unknown-length passkey health responses"
    return
  fi

  local health_tmp_dir response_file metadata_file error_file
  health_tmp_dir="$(/usr/bin/mktemp -d /tmp/fearless-passkey-health.XXXXXX)" || {
    record_failure "Unable to create a temporary directory for passkey backup live health validation"
    return
  }
  temporary_paths+=("$health_tmp_dir")
  response_file="$health_tmp_dir/response.bin"
  metadata_file="$health_tmp_dir/curl-metadata.txt"
  error_file="$health_tmp_dir/curl-error.txt"

  local attempt response_bytes curl_error validation_output diagnostic
  log "Checking live passkey backup challenge service health at $health_url"

  status=0
  diagnostic="health request failed without diagnostic output"
  for ((attempt = 1; attempt <= attempts; attempt += 1)); do
    : > "$response_file"
    : > "$metadata_file"
    : > "$error_file"
    set +e
    run_isolated_health_curl "$PASSKEY_HEALTH_CURL_BIN" \
      --disable \
      --silent \
      --show-error \
      --fail-with-body \
      --request GET \
      --proto '=https' \
      --proto-redir '=https' \
      --tlsv1.2 \
      --max-redirs 0 \
      --proxy '' \
      --noproxy '*' \
      --connect-timeout "$connect_timeout" \
      --max-time "$timeout" \
      --max-filesize "$max_response_bytes" \
      --header 'Accept: application/json' \
      --header 'Accept-Encoding: identity' \
      --output "$response_file" \
      --write-out '%{http_code}\n%{url_effective}\n%{content_type}\n%{size_download}\n' \
      --url "$health_url" \
      >"$metadata_file" 2>"$error_file"
    status=$?
    set -e

    response_bytes="$(LC_ALL=C /usr/bin/wc -c < "$response_file")"
    response_bytes="${response_bytes//[[:space:]]/}"
    curl_error="$(LC_ALL=C /usr/bin/head -c 1024 "$error_file")"

    if [[ ! "$response_bytes" =~ ^[0-9]+$ ]]; then
      status=22
      diagnostic="health response size could not be measured"
    elif ((response_bytes > max_response_bytes)); then
      status=63
      diagnostic="health response exceeded the configured $max_response_bytes-byte limit"
    elif [[ "$status" -eq 63 ]]; then
      diagnostic="curl enforced the configured $max_response_bytes-byte health response limit"
    elif [[ "$status" -ne 0 ]]; then
      diagnostic="curl transport failed: $(body_preview "$curl_error")"
    else
      set +e
      validation_output="$(
        PASSKEY_HEALTH_RESPONSE_FILE="$response_file" \
        PASSKEY_HEALTH_METADATA_FILE="$metadata_file" \
        PASSKEY_HEALTH_EXPECTED_URL="$PASSKEY_REVIEWED_HEALTH_URL" \
        PASSKEY_HEALTH_EXPECTED_RP_ID="$PASSKEY_CONFIG_RP_ID" \
        PASSKEY_HEALTH_MAX_BYTES="$max_response_bytes" \
        node <<'NODE' 2>&1
const fs = require('fs');
const { TextDecoder } = require('util');

function assert(condition, message) {
  if (!condition) throw new Error(message);
}

try {
const response = fs.readFileSync(process.env.PASSKEY_HEALTH_RESPONSE_FILE);
const maximumBytes = Number(process.env.PASSKEY_HEALTH_MAX_BYTES);

const metadata = fs.readFileSync(process.env.PASSKEY_HEALTH_METADATA_FILE, 'utf8');
assert(metadata.endsWith('\n'), 'curl response metadata must end with a newline');
const metadataLines = metadata.slice(0, -1).split('\n');
assert(metadataLines.length === 4, 'curl response metadata must contain exactly four fields');
const [httpStatus, effectiveUrl, contentType, downloadedSize] = metadataLines;
assert(httpStatus === '200', `health endpoint must return HTTP 200, got ${httpStatus || '<missing>'}`);
assert(effectiveUrl === process.env.PASSKEY_HEALTH_EXPECTED_URL, 'curl effective URL must remain the exact reviewed health URL');
assert(/^application\/json;[ \t]*charset=utf-8$/i.test(contentType), `health endpoint Content-Type must be application/json; charset=utf-8, got ${contentType || '<missing>'}`);
assert(/^(0|[1-9][0-9]*)$/.test(downloadedSize), 'curl downloaded size must be a canonical integer');
assert(Number(downloadedSize) === response.length, 'curl downloaded size must match the validated response bytes');
assert(response.length > 0, 'health response body must not be empty');
assert(response.length <= maximumBytes, `health response exceeds ${maximumBytes} bytes`);

const decoder = new TextDecoder('utf-8', { fatal: true, ignoreBOM: false });
assert(!(response[0] === 0xef && response[1] === 0xbb && response[2] === 0xbf), 'health response must not contain a UTF-8 BOM');
let text;
try {
  text = decoder.decode(response);
} catch {
  throw new Error('health response must contain valid UTF-8');
}
let data;
try {
  data = JSON.parse(text);
} catch {
  throw new Error('health response must contain valid JSON');
}
assert(data !== null && typeof data === 'object' && !Array.isArray(data), 'health response must be a JSON object');
const expectedKeys = ['ok', 'rpId', 'schemaVersion', 'service'];
assert(JSON.stringify(Object.keys(data).sort()) === JSON.stringify(expectedKeys), 'health response must contain exactly ok, service, rpId, and schemaVersion');
const rawPropertyNames = Array.from(
  text.matchAll(/"((?:\\["\\/bfnrt]|\\u[0-9a-fA-F]{4}|[^"\\])*)"[ \t\r\n]*:/g),
  (match) => match[1],
);
assert(rawPropertyNames.length === 4, 'health response must contain exactly four JSON properties without duplicates');
assert(JSON.stringify(rawPropertyNames.sort()) === JSON.stringify(expectedKeys), 'health response property names must be canonical and unescaped');
assert(data.ok === true, 'health ok must be true');
assert(data.service === 'fearless-passkey-backup', 'health service must identify fearless-passkey-backup');
assert(data.rpId === process.env.PASSKEY_HEALTH_EXPECTED_RP_ID, 'health rpId must match production config');
assert(data.schemaVersion === 1, 'health schemaVersion must be 1');
} catch (error) {
  console.error(`[passkey-health-validation] ${error instanceof Error ? error.message : 'validation failed'}`);
  process.exit(1);
}
NODE
      )"
      status=$?
      set -e
      if [[ "$status" -ne 0 ]]; then
        status=22
        diagnostic="invalid live health response: $(body_preview "$validation_output"). Body preview: <withheld by strict health validator>"
      else
        diagnostic=""
      fi
    fi

    if [[ "$status" -eq 0 ]]; then
      break
    fi

    if ((attempt < attempts)); then
      warn "Passkey backup challenge service live health attempt $attempt/$attempts failed for $health_url. Curl output: $(body_preview "$diagnostic"). Retrying."
      if ((delay > 0)); then
        sleep "$delay"
      fi
    fi
  done

  if [[ "$status" -ne 0 ]]; then
    record_failure "Passkey backup challenge service live health check failed for $health_url. Curl output: $(body_preview "$diagnostic"). Verify backup.fearlesswallet.io DNS/TLS/routing and deploy services/passkey-backup-challenge-service."
    return
  fi
}

android_manifest_has_application() {
  local manifest="$1"
  [[ -f "$manifest" ]] || return 1
  grep -Eq '<application($|[[:space:]>])' "$manifest"
}

android_system_backup_disabled() {
  local manifest="$1"
  [[ -f "$manifest" ]] || return 1
  grep -Eq 'android:allowBackup="false"' "$manifest"
}

android_has_app_owned_passkey_backup() {
  local repo="$1"
  repo_has_pattern "$repo" 'PasskeyBackupCoordinator|PasskeyBackupCloudStorage' \( -name '*.kt' -o -name '*.java' \)
}

android_has_reviewed_cloud_backup_posture() {
  local repo="$1"
  local manifest="$2"

  android_manifest_has_application "$manifest" || return 1

  if ! android_system_backup_disabled "$manifest"; then
    return 0
  fi

  android_has_app_owned_passkey_backup "$repo"
}

check_android() {
  local repo="$ROOT_DIR/fearless-Android"
  log "Checking Android passkey backup prerequisites"

  if [[ ! -d "$repo" ]]; then
    record_failure "Android repo missing: $repo"
    return
  fi

  local manifest="$repo/app/src/main/AndroidManifest.xml"
  if ! android_has_reviewed_cloud_backup_posture "$repo" "$manifest"; then
    record_failure "Android app must define a reviewed backup posture: app-owned PasskeyBackupCloudStorage with system backup disabled, or reviewed Android system backup rules"
  fi

  require_repo_pattern \
    "$repo" \
    'androidx\.credentials:credentials([^-]|$)' \
    "Android must declare androidx.credentials:credentials for passkey support" \
    \( -name '*.gradle' -o -name '*.gradle.kts' -o -name 'libs.versions.toml' \)

  require_repo_pattern \
    "$repo" \
    'androidx\.credentials:credentials-play-services-auth' \
    "Android must declare androidx.credentials:credentials-play-services-auth for Google-backed passkeys" \
    \( -name '*.gradle' -o -name '*.gradle.kts' -o -name 'libs.versions.toml' \)

  require_repo_pattern \
    "$repo" \
    'CredentialManager|CreatePublicKeyCredentialRequest|GetPublicKeyCredentialOption|PublicKeyCredential' \
    "Android must contain Credential Manager passkey registration and restore code" \
    \( -name '*.kt' -o -name '*.java' \)

  require_repo_pattern \
    "$repo" \
    'PASSKEY_RP_ID|passkeyRelyingPartyId|relyingPartyId|rpId' \
    "Android must expose an explicit passkey relying-party identifier contract" \
    \( -name '*.kt' -o -name '*.java' -o -name '*.gradle' -o -name '*.gradle.kts' -o -name '*.properties' -o -name '*.xml' \)

  require_repo_pattern \
    "$repo" \
    'PasskeyBackup|passkey.*backup|backup.*passkey|GoogleDrive|DriveBackup|CloudBackup' \
    "Android must wire passkey authentication into cloud backup/recovery storage" \
    \( -name '*.kt' -o -name '*.java' \)

  require_repo_pattern \
    "$repo" \
    'PasskeyBackupWorkflow|PendingPasskeyBackupRegistration|PendingPasskeyBackupAssertion' \
    "Android passkey backup must expose a testable registration and restore workflow" \
    \( -name '*.kt' -o -name '*.java' \)

  require_repo_pattern \
    "$repo" \
    'drive\.appdata|APP_DATA_SCOPE' \
    "Android passkey backup must request the Google Drive appdata scope for app-owned encrypted backup storage" \
    \( -name '*.kt' -o -name '*.java' -o -name '*.xml' \)

  require_repo_pattern \
    "$repo" \
    'GoogleDrivePasskeyBackupCloudStorage|GoogleDrivePasskeyBackupDriveClient|appDataFolder' \
    "Android must include a Google Drive appDataFolder passkey backup storage adapter" \
    \( -name '*.kt' -o -name '*.java' \)

  require_repo_pattern \
    "$repo" \
    'GoogleDrivePasskeyBackupTokenProvider|GoogleDriveOAuthTokenFetcher|GoogleAuthUtil|OAUTH_APP_DATA_SCOPE' \
    "Android passkey backup must include a Google Drive access-token provider for appdata storage" \
    \( -name '*.kt' -o -name '*.java' \)

  require_repo_pattern \
    "$repo" \
    'PasskeyBackupChallengeService|HttpPasskeyBackupChallengeService' \
    "Android passkey backup must include a remote challenge service contract for WebAuthn ceremonies" \
    \( -name '*.kt' -o -name '*.java' \)

  require_repo_pattern \
    "$repo" \
    'registration/challenge|registration/complete' \
    "Android passkey backup challenge service must define registration challenge and completion endpoints" \
    \( -name '*.kt' -o -name '*.java' \)

  require_repo_pattern \
    "$repo" \
    'assertion/challenge|assertion/complete' \
    "Android passkey backup challenge service must define assertion challenge and completion endpoints" \
    \( -name '*.kt' -o -name '*.java' \)
}

ios_has_entitlement_value() {
  local repo="$1"
  local key_pattern="$2"
  local value_pattern="$3"
  local file

  while IFS= read -r file; do
    if grep -Eq "$key_pattern" "$file" && grep -Eq "$value_pattern" "$file"; then
      return 0
    fi
  done < <(repo_files_matching "$repo" -name '*.entitlements')

  return 1
}

check_ios() {
  local repo="$ROOT_DIR/fearless-iOS"
  log "Checking iOS passkey backup prerequisites"

  if [[ ! -d "$repo" ]]; then
    record_failure "iOS repo missing: $repo"
    return
  fi

  require_repo_pattern \
    "$repo" \
    'import[[:space:]]+AuthenticationServices|ASAuthorizationPlatformPublicKeyCredential|ASAuthorizationController|ASAuthorizationPublicKeyCredential' \
    "iOS must contain AuthenticationServices passkey registration and restore code" \
    \( -name '*.swift' -o -name '*.m' -o -name '*.mm' \)

  require_repo_pattern \
    "$repo" \
    'import[[:space:]]+CloudKit|CKContainer|CKDatabase|NSUbiquitousKeyValueStore' \
    "iOS must contain iCloud/CloudKit backup storage integration" \
    \( -name '*.swift' -o -name '*.m' -o -name '*.mm' \)

  require_repo_pattern \
    "$repo" \
    'PasskeyBackupCloudKitAccountStatusProvider' \
    "iOS passkey backup must expose a CloudKit account-status provider" \
    \( -name '*.swift' -o -name '*.m' -o -name '*.mm' \)

  require_repo_pattern \
    "$repo" \
    'accountStatus\(' \
    "iOS passkey backup must query CloudKit account availability before backup storage access" \
    \( -name '*.swift' -o -name '*.m' -o -name '*.mm' \)

  require_repo_pattern \
    "$repo" \
    'unavailableCloudKitAccount' \
    "iOS passkey backup must fail closed when the CloudKit account is unavailable" \
    \( -name '*.swift' -o -name '*.m' -o -name '*.mm' \)

  if ! ios_has_entitlement_value "$repo" 'com\.apple\.developer\.associated-domains' 'webcredentials:'; then
    record_failure "iOS entitlements must include associated domains with a webcredentials: relying-party domain"
  fi

  if ! ios_has_entitlement_value "$repo" 'com\.apple\.developer\.icloud-services|com\.apple\.developer\.icloud-container-identifiers' 'CloudKit|iCloud|icloud'; then
    record_failure "iOS entitlements must include iCloud/CloudKit container capability for backup storage"
  fi

  require_repo_pattern \
    "$repo" \
    'PASSKEY_RP_ID|passkeyRelyingPartyId|relyingPartyId|rpId' \
    "iOS must expose an explicit passkey relying-party identifier contract" \
    \( -name '*.swift' -o -name '*.xcconfig' -o -name '*.plist' -o -name '*.entitlements' \)

  require_repo_pattern \
    "$repo" \
    'validateAccountName' \
    "iOS passkey backup must validate selected account names before registration" \
    \( -name '*.swift' -o -name '*.m' -o -name '*.mm' \)

  require_repo_pattern \
    "$repo" \
    'validateMatchingAccountName' \
    "iOS passkey backup must reject registration account mismatches" \
    \( -name '*.swift' -o -name '*.m' -o -name '*.mm' \)

  require_repo_pattern \
    "$repo" \
    'PasskeyBackup|passkey.*backup|backup.*passkey|CloudBackup|iCloudBackup' \
    "iOS must wire passkey authentication into cloud backup/recovery storage" \
    \( -name '*.swift' -o -name '*.m' -o -name '*.mm' \)

  require_repo_pattern \
    "$repo" \
    'PasskeyBackupWorkflow|PendingPasskeyBackupRegistration|PendingPasskeyBackupAssertion' \
    "iOS passkey backup must expose a testable registration and restore workflow" \
    \( -name '*.swift' -o -name '*.m' -o -name '*.mm' \)

  require_repo_pattern \
    "$repo" \
    'PasskeyBackupChallengeService|HTTPPasskeyBackupChallengeService|HttpPasskeyBackupChallengeService' \
    "iOS passkey backup must include a remote challenge service contract for WebAuthn ceremonies" \
    \( -name '*.swift' -o -name '*.m' -o -name '*.mm' \)

  require_repo_pattern \
    "$repo" \
    'registration/challenge|registration/complete' \
    "iOS passkey backup challenge service must define registration challenge and completion endpoints" \
    \( -name '*.swift' -o -name '*.m' -o -name '*.mm' \)

  require_repo_pattern \
    "$repo" \
    'assertion/challenge|assertion/complete' \
    "iOS passkey backup challenge service must define assertion challenge and completion endpoints" \
    \( -name '*.swift' -o -name '*.m' -o -name '*.mm' \)
}

load_release_config
check_challenge_service_openapi_contract
check_android
check_ios
check_release_config_sources
check_live_challenge_service

if ((${#failures[@]} > 0)); then
  echo "[passkey-backup-audit][error] Passkey backup prerequisites are incomplete:" >&2
  printf '  - %s\n' "${failures[@]}" >&2
  exit 1
fi

log "Passkey backup prerequisites passed."
