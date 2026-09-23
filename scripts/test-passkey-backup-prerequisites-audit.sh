#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
AUDIT_SCRIPT="$SCRIPT_DIR/audit-passkey-backup-prerequisites.sh"

fail() {
  echo "[passkey-backup-audit-test][error] $*" >&2
  exit 1
}

tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT
TEST_CASE_COUNT=0

workspace="$tmp_dir/fearless"
bin_dir="$tmp_dir/bin"

write_file() {
  local file="$1"
  shift
  mkdir -p "$(dirname "$file")"
  printf '%s\n' "$@" > "$file"
}

write_android_ready() {
  local repo="$workspace/fearless-Android"
  write_file "$repo/app/src/main/AndroidManifest.xml" \
    '<?xml version="1.0" encoding="utf-8"?>' \
    '<manifest xmlns:android="http://schemas.android.com/apk/res/android">' \
    '  <application android:allowBackup="false" />' \
    '</manifest>'
  write_file "$repo/gradle/libs.versions.toml" \
    '[libraries]' \
    'credentials = { module = "androidx.credentials:credentials", version = "1.5.0" }' \
    'credentials-play-services-auth = { module = "androidx.credentials:credentials-play-services-auth", version = "1.5.0" }'
  write_file "$repo/public-shared-features-backup/src/main/java/jp/co/soramitsu/backup/passkey/PasskeyBackupContract.kt" \
    'package jp.co.soramitsu.passkey' \
    'import androidx.credentials.CredentialManager' \
    'import androidx.credentials.CreatePublicKeyCredentialRequest' \
    'import androidx.credentials.GetPublicKeyCredentialOption' \
    'const val PASSKEY_RP_ID = "fearlesswallet.io"' \
    'interface PasskeyBackupCloudStorage' \
    'class PasskeyBackupCoordinator(private val storage: PasskeyBackupCloudStorage)' \
    'class PasskeyBackupWorkflow' \
    'class PasskeyBackup {' \
    '  fun backup(manager: CredentialManager) = CreatePublicKeyCredentialRequest("{}")' \
    '  fun restore() = GetPublicKeyCredentialOption("{}")' \
    '}' \
    'fun requireWalletId(value: String): String = value' \
    'fun requireCreatedAtMillis(value: Long): Long = value' \
    'data class PasskeyBackupEncryptedPayload(' \
    '  val storageKey: String,' \
    '  val walletId: String,' \
    '  val accountName: String,' \
    '  val createdAtMillis: Long,' \
    '  val encryptedPayload: ByteArray' \
    ')' \
    'object PasskeyBackupReleaseConfig {' \
    '  const val CHALLENGE_SERVICE_BASE_URL = "https://backup.fearlesswallet.io"' \
    '  const val PASSKEY_BACKUP_ENABLED = false' \
    '}'
  write_file "$repo/public-shared-features-backup/src/main/java/jp/co/soramitsu/backup/passkey/PasskeyBackupChallengeService.kt" \
    'package jp.co.soramitsu.passkey' \
    'private const val REGISTRATION_CHALLENGE_PATH = "/api/passkey-backup/v1/registration/challenge"' \
    'private const val REGISTRATION_COMPLETE_PATH = "/api/passkey-backup/v1/registration/complete"' \
    'private const val ASSERTION_CHALLENGE_PATH = "/api/passkey-backup/v1/assertion/challenge"' \
    'private const val ASSERTION_COMPLETE_PATH = "/api/passkey-backup/v1/assertion/complete"' \
    'private const val CREDENTIALS_LIST_PATH = "/api/passkey-backup/v1/credentials/list"' \
    'private const val CREDENTIALS_REVOKE_PATH = "/api/passkey-backup/v1/credentials/revoke"' \
    'private const val CREDENTIALS_REVOKE_ALL_PATH = "/api/passkey-backup/v1/credentials/revoke-all"' \
    'class HttpPasskeyBackupChallengeService'
  write_file "$repo/public-shared-features-backup/src/main/java/jp/co/soramitsu/backup/passkey/GoogleDrivePasskeyBackupCloudStorage.kt" \
    'package jp.co.soramitsu.passkey' \
    'object GoogleDrivePasskeyBackup {' \
    '  const val APP_DATA_SCOPE = "https://www.googleapis.com/auth/drive.appdata"' \
    '  const val OAUTH_APP_DATA_SCOPE = "oauth2:$APP_DATA_SCOPE"' \
    '}' \
    'fun metadata(appProperties: Map<String, String>) {' \
    '  addProperty("walletId", "wallet-001")' \
    '  addProperty("accountName", "alice@example.com")' \
    '  addProperty("createdAtMillis", "1767225600000")' \
    '  requiredAppProperty(appProperties, "walletId")' \
    '  requiredAppProperty(appProperties, "accountName")' \
    '  requiredAppProperty(appProperties, "createdAtMillis")' \
    '}' \
    'class GoogleDrivePasskeyBackupCloudStorage'
  write_file "$repo/public-shared-features-backup/src/main/java/jp/co/soramitsu/backup/passkey/GoogleDrivePasskeyBackupTokenProvider.kt" \
    'package jp.co.soramitsu.passkey' \
    'import com.google.android.gms.auth.GoogleAuthUtil' \
    'class GoogleDrivePasskeyBackupTokenProvider'
  write_file "$repo/docs/release-checklist.md" \
    'Run ../../config/passkey-backup-production.json passkey release config checks before release.' \
    'Keep PASSKEY_BACKUP_ENABLED=false unless live health passes.' \
    'Confirm Google account selection, Google Drive consent, and restore before creating a new backup.'
}

write_ios_ready() {
  local repo="$workspace/fearless-iOS"
  write_file "$repo/fearless/Common/Model/PasskeyBackupContract.swift" \
    'import AuthenticationServices' \
    'import CloudKit' \
    'let PASSKEY_RP_ID = "fearlesswallet.io"' \
    'enum PasskeyBackupContract {' \
    '  static func validateAccountName(_ value: String) throws -> String { value }' \
    '  static func validateMatchingAccountName(expected: String, actual: String) throws -> String { expected }' \
    '  static func validateWalletId(_ value: String) throws -> String { value }' \
    '  static func validateCreatedAtMillis(_ value: Int64) throws -> Int64 { value }' \
    '}' \
    'struct PasskeyBackupEncryptedRecord {' \
    '  let storageKey: String' \
    '  let walletId: String' \
    '  let accountName: String' \
    '  let createdAtMillis: Int64' \
    '}' \
    'final class PasskeyBackup {' \
    '  let provider = ASAuthorizationPlatformPublicKeyCredentialProvider(relyingPartyIdentifier: PASSKEY_RP_ID)' \
    '  let controller: ASAuthorizationController? = nil' \
    '  let container = CKContainer(identifier: "iCloud.io.fearless.wallet")' \
    '}' \
    'protocol PasskeyBackupChallengeService {}' \
    'final class HTTPPasskeyBackupChallengeService: PasskeyBackupChallengeService {' \
    '  let registrationChallengePath = "/api/passkey-backup/v1/registration/challenge"' \
    '  let registrationCompletePath = "/api/passkey-backup/v1/registration/complete"' \
    '  let assertionChallengePath = "/api/passkey-backup/v1/assertion/challenge"' \
    '  let assertionCompletePath = "/api/passkey-backup/v1/assertion/complete"' \
    '  let credentialsListPath = "/api/passkey-backup/v1/credentials/list"' \
    '  let credentialsRevokePath = "/api/passkey-backup/v1/credentials/revoke"' \
    '  let credentialsRevokeAllPath = "/api/passkey-backup/v1/credentials/revoke-all"' \
    '}' \
    'enum PasskeyBackupReleaseConfig {' \
    '  static let challengeServiceBaseURL = URL(string: "https://backup.fearlesswallet.io")!' \
    '  static let isPasskeyBackupEnabled = false' \
    '}' \
    'enum PasskeyBackupHTTPTransportPolicy {' \
    '  static let maximumResponseBytes = 256 * 1024' \
    '  static let followsRedirects = false' \
    '}' \
    'func boundedTransportFixture(response: PasskeyBackupHTTPResponse, request: URLRequest) async throws {' \
    '  guard response.body.count <= PasskeyBackupHTTPTransportPolicy.maximumResponseBytes else { return }' \
    '  _ = PasskeyBackupHTTPTransportPolicy.followsRedirects ? request : nil' \
    '  _ = try await withTaskCancellationHandler(operation: {}, onCancel: {})' \
    '}' \
    'func identityFixture(result: PasskeyBackupCredentialRevokeResult, revoked: PasskeyBackupCredentialRevokeResult, credentialId: String) {' \
    '  guard result.credentialId == credentialId else { return }' \
    '  guard revoked.credentialId == nil else { return }' \
    '}' \
    'enum PasskeyBackupError: Error {' \
    '  case unavailableCloudKitAccount' \
    '}' \
    'final class PasskeyBackupWorkflow {}' \
    'protocol PasskeyBackupCloudKitAccountStatusProvider {' \
    '  func accountStatus() async throws -> CKAccountStatus' \
    '}' \
    'final class CloudKitPasskeyBackupCloudStorage {' \
    '  static let recordType = "FearlessPasskeyBackup"' \
    '  static let storageKeyField = "storageKey"' \
    '  static let walletIdField = "walletId"' \
    '  static let accountNameField = "accountName"' \
    '  static let createdAtMillisField = "createdAtMillis"' \
    '}' \
    'enum PasskeyCredentialResponseSerializer {' \
    '  static func registrationJSON(for credential: ASAuthorizationPlatformPublicKeyCredentialRegistration) throws -> String {' \
    '    _ = credential.rawAttestationObject' \
    '    let response = ["attestationObject": "value", "authenticatorData": "value"]' \
    '    return String(describing: response)' \
    '  }' \
    '  static func assertionJSON(for credential: ASAuthorizationPlatformPublicKeyCredentialAssertion, userHandle: Data) throws -> String {' \
    '    _ = credential.rawAuthenticatorData' \
    '    _ = credential.signature' \
    '    let encodedCredentialID = "credential-id"' \
    '    let credential: [String: Any] = [' \
    '      "id": encodedCredentialID,' \
    '      "rawId": encodedCredentialID,' \
    '      "type": "public-key",' \
    '      "clientExtensionResults": [String: Any](),' \
    '      "authenticatorData": "value",' \
    '      "signature": "value",' \
    '      "userHandle": userHandle' \
    '    ]' \
    '    return Data().base64EncodedString()' \
    '      .replacingOccurrences(of: "+", with: "-")' \
    '      .replacingOccurrences(of: "/", with: "_")' \
    '      .replacingOccurrences(of: "=", with: "")' \
    '  }' \
    '}'
  write_file "$repo/fearlessTests/PasskeyBackupCredentialResponseSerializerTests.swift" \
    'final class PasskeyCredentialResponseSerializerTests {' \
    '  func testRegistrationSerializerProducesWebAuthnEnvelopeAndBase64URLFields() {}' \
    '  func testAssertionSerializerProducesRequiredWebAuthnResponseFields() {}' \
    '  func testRegistrationSerializerRejectsEveryEmptyRequiredField() {}' \
    '  func testAssertionSerializerRejectsEveryEmptyRequiredField() {}' \
    '  func testSerializerRejectsFieldsBeyondChallengeServiceLimits() {}' \
    '  func testSerializerAcceptsFieldsAtChallengeServiceLimits() {}' \
    '  func testChallengeClientRejectsOversizedInjectedTransportResponsesBeforeStatusOrJSON() {}' \
    '  func testURLSessionTransportRejectsInvalidResponseLimits() {}' \
    '  func testURLSessionTransportRejectsOversizedDeclaredResponseBeforeBody() {}' \
    '  func testURLSessionTransportRejectsChunkedResponseBeyondLimit() {}' \
    '  func testURLSessionTransportBoundsDecodedStreamingBytes() {}' \
    '  func testURLSessionTransportCancellationStopsTaskAndClearsState() {}' \
    '  func testRegistrationCompensationRejectsMismatchedRevokeResultIdentities() {}' \
    '  func testWorkflowRejectsRevokeAllResultContainingCredentialIdentity() {}' \
    '  func testCoordinatorRejectsRevokeAllResultContainingCredentialIdentity() {}' \
    '}'
  write_file "$repo/fearless/Common/Model/GoogleDrivePasskeyBackupCloudStorage.swift" \
    'import Foundation' \
    'final class GoogleDrivePasskeyBackupCloudStorage {' \
    '  static let scope = "https://www.googleapis.com/auth/drive.appdata"' \
    '  static let folder = "appDataFolder"' \
    '}'
  write_file "$repo/fearless/WalletConnect.entitlements" \
    '<?xml version="1.0" encoding="UTF-8"?>' \
    '<plist version="1.0">' \
    '<dict>' \
    '  <key>com.apple.developer.associated-domains</key>' \
    '  <array><string>applinks:fearlesswallet.io</string><string>webcredentials:fearlesswallet.io</string></array>' \
    '  <key>com.apple.developer.icloud-services</key>' \
    '  <array><string>CloudKit</string></array>' \
    '  <key>com.apple.developer.icloud-container-identifiers</key>' \
    '  <array><string>iCloud.$(PRODUCT_BUNDLE_IDENTIFIER)</string></array>' \
    '  <key>com.apple.security.application-groups</key>' \
    '  <array><string>group.$(PRODUCT_BUNDLE_IDENTIFIER)</string></array>' \
    '</dict>' \
    '</plist>'
  write_file "$repo/fearless.xcodeproj/project.pbxproj" \
    'PRODUCT_BUNDLE_IDENTIFIER = jp.co.soramitsu.fearlesswallet;' \
    'PRODUCT_BUNDLE_IDENTIFIER = jp.co.soramitsu.fearlesswallet.dev;'
  write_file "$repo/docs/release-checklist.md" \
    'Run ../config/passkey-backup-production.json passkey release config checks before release.' \
    'Keep isPasskeyBackupEnabled=false unless live health passes.' \
    'Confirm Google account selection, Google Drive consent, cross-platform restore, optional iCloud copy, iCloud account availability, CloudKit production schema, associated-domain provisioning, provisioning profiles, and restore before creating a new backup.'
}

write_passkey_config() {
  write_file "$workspace/config/passkey-backup-production.json" \
    '{' \
    '  "schemaVersion": 1,' \
    '  "relyingPartyId": "fearlesswallet.io",' \
    '  "challengeServiceBaseUrl": "https://backup.fearlesswallet.io",' \
    '  "healthPath": "/api/passkey-backup/v1/health",' \
    '  "challengeServicePaths": {' \
    '    "registrationChallenge": "/api/passkey-backup/v1/registration/challenge",' \
    '    "registrationComplete": "/api/passkey-backup/v1/registration/complete",' \
    '    "assertionChallenge": "/api/passkey-backup/v1/assertion/challenge",' \
    '    "assertionComplete": "/api/passkey-backup/v1/assertion/complete",' \
    '    "credentialsList": "/api/passkey-backup/v1/credentials/list",' \
    '    "credentialsRevoke": "/api/passkey-backup/v1/credentials/revoke",' \
    '    "credentialsRevokeAll": "/api/passkey-backup/v1/credentials/revoke-all"' \
    '  },' \
    '  "requestAuthorization": {' \
    '    "failClosed": true,' \
    '    "protectedPaths": [' \
    '      "/api/passkey-backup/v1/registration/challenge",' \
    '      "/api/passkey-backup/v1/registration/complete",' \
    '      "/api/passkey-backup/v1/assertion/challenge",' \
    '      "/api/passkey-backup/v1/assertion/complete",' \
    '      "/api/passkey-backup/v1/credentials/list",' \
    '      "/api/passkey-backup/v1/credentials/revoke",' \
    '      "/api/passkey-backup/v1/credentials/revoke-all"' \
    '    ]' \
    '  },' \
    '  "credentialLifecycle": {' \
    '    "maxCredentialsPerStorageKey": 32,' \
    '    "listExposesPublicKeyOrUserHandle": false,' \
    '    "singleRevokeIdempotent": true,' \
    '    "revokeAllIdempotent": true,' \
    '    "finalRevocationRetainsOwnerTombstone": true,' \
    '    "crossSubjectTakeoverDenied": true,' \
    '    "sameOwnerReregistrationAllowed": true,' \
    '    "ownerErasureEndpointEnabled": false,' \
    '    "cloudDeletionOrdering": "revoke-server-credentials-before-cloud-record"' \
    '  },' \
    '  "encryptedBackupMetadata": [' \
    '    "storageKey",' \
    '    "walletId",' \
    '    "accountName",' \
    '    "createdAtMillis",' \
    '    "schemaVersion"' \
    '  ],' \
    '  "android": {' \
    '    "backupStorage": "google-drive-appdata",' \
    '    "googleDriveScope": "https://www.googleapis.com/auth/drive.appdata",' \
    '    "oauthScope": "oauth2:https://www.googleapis.com/auth/drive.appdata",' \
    '    "releaseUxChecklist": [' \
    '      "google-account-selection",' \
    '      "google-drive-consent",' \
    '      "restore-before-create",' \
    '      "disabled-until-live-health"' \
    '    ]' \
    '  },' \
    '  "ios": {' \
    '    "backupStorage": "google-drive-appdata",' \
    '    "googleDriveScope": "https://www.googleapis.com/auth/drive.appdata",' \
    '    "additionalBackupStorage": "cloudkit-private-database",' \
    '    "associatedDomain": "webcredentials:fearlesswallet.io",' \
    '    "cloudKitRecordType": "FearlessPasskeyBackup",' \
    '    "cloudKitContainers": [' \
    '      "iCloud.jp.co.soramitsu.fearlesswallet",' \
    '      "iCloud.jp.co.soramitsu.fearlesswallet.dev"' \
    '    ],' \
    '    "releaseUxChecklist": [' \
    '      "google-account-selection",' \
    '      "google-drive-consent",' \
    '      "cross-platform-restore",' \
    '      "optional-icloud-copy",' \
      '      "icloud-account-availability",' \
    '      "associated-domain-provisioning",' \
    '      "cloudkit-production-schema",' \
    '      "restore-before-create",' \
    '      "disabled-until-live-health"' \
    '    ]' \
    '  }' \
    '}'
}

write_passkey_openapi() {
  mkdir -p "$workspace/config"
  cp "$(cd "$SCRIPT_DIR/.." && pwd)/config/passkey-backup-challenge-service.openapi.json" \
    "$workspace/config/passkey-backup-challenge-service.openapi.json"
}

write_fake_curl() {
  write_file "$bin_dir/curl" \
    '#!/usr/bin/env bash' \
    'set -euo pipefail' \
    'scenario="${FAKE_PASSKEY_AUDIT_SCENARIO:-good}"' \
    'state_dir="${FAKE_PASSKEY_AUDIT_STATE_DIR:-${TMPDIR:-/tmp}}"' \
    '[[ "${1:-}" == "--disable" ]] || { echo "--disable must be the first curl argument" >&2; exit 2; }' \
    '[[ "${HOME:-}" == "/var/empty" ]] || { echo "unsafe HOME leaked into curl" >&2; exit 2; }' \
    '[[ "${CURL_HOME:-}" == "/var/empty" ]] || { echo "unsafe CURL_HOME leaked into curl" >&2; exit 2; }' \
    '[[ "${XDG_CONFIG_HOME:-}" == "/var/empty" ]] || { echo "unsafe XDG_CONFIG_HOME leaked into curl" >&2; exit 2; }' \
    '[[ "${PATH:-}" == "/usr/bin:/bin" ]] || { echo "unsafe PATH leaked into curl" >&2; exit 2; }' \
    'for forbidden in HTTPS_PROXY HTTP_PROXY ALL_PROXY NO_PROXY https_proxy http_proxy all_proxy no_proxy CURL_CA_BUNDLE SSL_CERT_FILE SSL_CERT_DIR CURLRC; do' \
    '  [[ -z "${!forbidden+x}" ]] || { echo "unsafe $forbidden leaked into curl" >&2; exit 2; }' \
    'done' \
    'mkdir -p "$state_dir"' \
    'if [[ "${2:-}" == "--version" ]]; then' \
    '  [[ $# -eq 2 ]] || { echo "unexpected curl version arguments" >&2; exit 2; }' \
    '  if [[ "$scenario" == "live-health-old-curl" ]]; then' \
    '    printf "%s\n" "curl 8.3.0 fake"' \
    '  else' \
    '    printf "%s\n" "curl 8.7.1 fake"' \
    '  fi' \
    '  exit 0' \
    'fi' \
    'output_file=""' \
    'write_out=""' \
    'expected_write_out="%{http_code}\\n%{url_effective}\\n%{content_type}\\n%{size_download}\\n"' \
    'url=""' \
    'connect_timeout=""' \
    'total_timeout=""' \
    'max_filesize=""' \
    'proto=""' \
    'proto_redir=""' \
    'max_redirs=""' \
    'proxy="unset"' \
    'noproxy=""' \
    'request_method=""' \
    'accept_header=0' \
    'encoding_header=0' \
    'seen_disable=0' \
    'seen_silent=0' \
    'seen_show_error=0' \
    'seen_fail_with_body=0' \
    'seen_tls=0' \
    'while (($#)); do' \
    '  case "$1" in' \
    '    --disable) seen_disable=$((seen_disable + 1)); shift ;;' \
    '    --silent) seen_silent=$((seen_silent + 1)); shift ;;' \
    '    --show-error) seen_show_error=$((seen_show_error + 1)); shift ;;' \
    '    --fail-with-body) seen_fail_with_body=$((seen_fail_with_body + 1)); shift ;;' \
    '    --tlsv1.2) seen_tls=$((seen_tls + 1)); shift ;;' \
    '    --request) request_method="${2:-}"; shift 2 ;;' \
    '    --proto) proto="${2:-}"; shift 2 ;;' \
    '    --proto-redir) proto_redir="${2:-}"; shift 2 ;;' \
    '    --max-redirs) max_redirs="${2:-}"; shift 2 ;;' \
    '    --proxy) proxy="${2+x}:${2:-}"; shift 2 ;;' \
    '    --noproxy) noproxy="${2:-}"; shift 2 ;;' \
    '    --connect-timeout) connect_timeout="${2:-}"; shift 2 ;;' \
    '    --max-time) total_timeout="${2:-}"; shift 2 ;;' \
    '    --max-filesize) max_filesize="${2:-}"; shift 2 ;;' \
    '    --header)' \
    '      [[ "${2:-}" == "Accept: application/json" ]] && accept_header=$((accept_header + 1))' \
    '      [[ "${2:-}" == "Accept-Encoding: identity" ]] && encoding_header=$((encoding_header + 1))' \
    '      shift 2' \
    '      ;;' \
    '    --output) output_file="${2:-}"; shift 2 ;;' \
    '    --write-out) write_out="${2:-}"; shift 2 ;;' \
    '    --url) url="${2:-}"; shift 2 ;;' \
    '    *) echo "unexpected curl argument: $1" >&2; exit 2 ;;' \
    '  esac' \
    'done' \
    '[[ "$seen_disable" -eq 1 && "$seen_silent" -eq 1 && "$seen_show_error" -eq 1 && "$seen_fail_with_body" -eq 1 && "$seen_tls" -eq 1 ]] || { echo "missing singleton curl safety flag" >&2; exit 2; }' \
    '[[ "$request_method" == "GET" ]] || { echo "curl method must be GET" >&2; exit 2; }' \
    '[[ "$proto" == "=https" && "$proto_redir" == "=https" ]] || { echo "curl protocols must be HTTPS-only" >&2; exit 2; }' \
    '[[ "$max_redirs" == "0" ]] || { echo "curl redirects must be disabled" >&2; exit 2; }' \
    '[[ "$proxy" == "x:" && "$noproxy" == "*" ]] || { echo "curl proxies must be disabled" >&2; exit 2; }' \
    '[[ "$connect_timeout" =~ ^(0|[1-9][0-9]*)$ && "$total_timeout" =~ ^(0|[1-9][0-9]*)$ ]] || { echo "noncanonical curl timeout contract" >&2; exit 2; }' \
    '((10#$connect_timeout >= 1 && 10#$connect_timeout <= 60 && 10#$total_timeout >= 1 && 10#$total_timeout <= 60 && 10#$connect_timeout <= 10#$total_timeout)) || { echo "unbounded curl timeout contract" >&2; exit 2; }' \
    '[[ "$max_filesize" =~ ^[1-9][0-9]*$ ]] && ((10#$max_filesize <= 65536)) || { echo "unexpected curl response cap" >&2; exit 2; }' \
    '[[ "$accept_header" -eq 1 && "$encoding_header" -eq 1 ]] || { echo "missing exact curl request headers" >&2; exit 2; }' \
    '[[ -n "$output_file" && "$write_out" == "$expected_write_out" ]] || { echo "missing exact curl output contract" >&2; exit 2; }' \
    '[[ "$url" == "https://backup.fearlesswallet.io/api/passkey-backup/v1/health" ]] || {' \
    '  echo "unexpected health URL: $url" >&2' \
    '  exit 1' \
    '}' \
    'if [[ "$scenario" == "live-health-flaky" ]]; then' \
    '  marker="$state_dir/$scenario.count"' \
    '  count=0' \
    '  [[ -f "$marker" ]] && count="$(cat "$marker")"' \
    '  count=$((count + 1))' \
    '  printf "%s\n" "$count" > "$marker"' \
    '  if [[ "$count" -eq 1 ]]; then' \
    '    echo "transient health timeout" >&2' \
    '    exit 28' \
    '  fi' \
    'fi' \
    'case "$scenario" in' \
    '  live-health-fail)' \
    '    echo "health unavailable" >&2' \
    '    exit 22' \
    '    ;;' \
    'esac' \
    'body="{\"ok\":true,\"service\":\"fearless-passkey-backup\",\"rpId\":\"fearlesswallet.io\",\"schemaVersion\":1}"' \
    'http_status="200"' \
    'effective_url="$url"' \
    'content_type="application/json; charset=utf-8"' \
    'case "$scenario" in' \
    '  live-health-non-json) body="not-json" ;;' \
    '  live-health-empty) body="" ;;' \
    '  live-health-extra-field) body="{\"ok\":true,\"service\":\"fearless-passkey-backup\",\"rpId\":\"fearlesswallet.io\",\"schemaVersion\":1,\"debug\":true}" ;;' \
    '  live-health-duplicate-field) body="{\"ok\":false,\"ok\":true,\"service\":\"fearless-passkey-backup\",\"rpId\":\"fearlesswallet.io\",\"schemaVersion\":1}" ;;' \
    '  live-health-escaped-duplicate-field) body="{\"ok\":false,\"\\u006fk\":true,\"service\":\"fearless-passkey-backup\",\"rpId\":\"fearlesswallet.io\",\"schemaVersion\":1}" ;;' \
    '  live-health-redirect) http_status="302"; content_type="text/html"; body="redirect" ;;' \
    '  live-health-downgrade) effective_url="http://backup.fearlesswallet.io/api/passkey-backup/v1/health" ;;' \
    '  live-health-foreign-effective-url) effective_url="https://evil.example/api/passkey-backup/v1/health" ;;' \
    '  live-health-wrong-content-type) content_type="text/plain" ;;' \
    '  live-health-json-prefix-content-type) content_type="application/jsonp" ;;' \
    '  live-health-multiple-content-type) content_type="application/json, text/html" ;;' \
    '  live-health-wrong-status) http_status="204"; body="" ;;' \
    '  live-health-oversize) printf -v body "%5000s" ""; body="${body// /A}" ;;' \
    'esac' \
    'if [[ "$scenario" == "live-health-invalid-utf8" ]]; then' \
    '  printf "\\377" > "$output_file"' \
    'elif [[ "$scenario" == "live-health-bom" ]]; then' \
    '  printf "\\357\\273\\277%s" "$body" > "$output_file"' \
    'else' \
    '  printf "%s" "$body" > "$output_file"' \
    'fi' \
    'body_size="$(LC_ALL=C wc -c < "$output_file" | tr -d "[:space:]")"' \
    'reported_size="$body_size"' \
    '[[ "$scenario" == "live-health-size-mismatch" ]] && reported_size=$((body_size + 1))' \
    'if [[ "$scenario" == "live-health-malformed-metadata" ]]; then' \
    '  printf "%s\n%s\n%s\n" "$http_status" "$effective_url" "$content_type"' \
    'else' \
    '  printf "%s\n%s\n%s\n%s\n" "$http_status" "$effective_url" "$content_type" "$reported_size"' \
    'fi'
  chmod +x "$bin_dir/curl"
}

reset_fixture() {
  rm -rf "$workspace" "$bin_dir" "$tmp_dir/state"
  mkdir -p "$workspace" "$bin_dir"
  write_passkey_config
  write_passkey_openapi
  write_fake_curl
  write_android_ready
  write_ios_ready
}

set_passkey_config_value() {
  local key="$1"
  local value="$2"
  PASSKEY_FIXTURE="$workspace/config/passkey-backup-production.json" \
    PASSKEY_FIXTURE_KEY="$key" \
    PASSKEY_FIXTURE_VALUE="$value" \
    node <<'NODE'
const fs = require('fs');
const file = process.env.PASSKEY_FIXTURE;
const data = JSON.parse(fs.readFileSync(file, 'utf8'));
data[process.env.PASSKEY_FIXTURE_KEY] = process.env.PASSKEY_FIXTURE_VALUE;
fs.writeFileSync(file, JSON.stringify(data, null, 2));
NODE
}

run_audit() {
    PASSKEY_AUDIT_ROOT="$workspace" \
    PASSKEY_BACKUP_HEALTH_TEST_MODE=1 \
    PASSKEY_BACKUP_HEALTH_TEST_CURL_BIN="${PASSKEY_BACKUP_HEALTH_TEST_CURL_BIN:-$bin_dir/curl}" \
    PASSKEY_BACKUP_HEALTH_RETRY_DELAY_SECONDS="${PASSKEY_BACKUP_HEALTH_RETRY_DELAY_SECONDS:-0}" \
    FAKE_PASSKEY_AUDIT_STATE_DIR="$tmp_dir/state" \
    PATH="${PASSKEY_TEST_AMBIENT_PATH_PREFIX:+$PASSKEY_TEST_AMBIENT_PATH_PREFIX:}$bin_dir:$PATH" \
    bash "$AUDIT_SCRIPT"
}

expect_success() {
  local name="$1"
  local output
  if ! output="$(run_audit 2>&1)"; then
    echo "$output" >&2
    fail "$name unexpectedly failed"
  fi
  TEST_CASE_COUNT=$((TEST_CASE_COUNT + 1))
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
  TEST_CASE_COUNT=$((TEST_CASE_COUNT + 1))
}

expect_command_failure() {
  local name="$1"
  local expected="$2"
  shift 2
  local output status
  set +e
  output="$("$@" 2>&1)"
  status=$?
  set -e
  if [[ "$status" -eq 0 ]]; then
    echo "$output" >&2
    fail "$name unexpectedly passed"
  fi
  if [[ "$output" != *"$expected"* ]]; then
    echo "$output" >&2
    fail "$name did not report expected text: $expected"
  fi
  TEST_CASE_COUNT=$((TEST_CASE_COUNT + 1))
}

reset_fixture
expect_success "complete passkey backup fixture"

reset_fixture
PASSKEY_BACKUP_LIVE_HEALTH=1 FAKE_PASSKEY_AUDIT_SCENARIO=good expect_success "complete passkey backup fixture with live health"

reset_fixture
PASSKEY_BACKUP_LIVE_HEALTH=TRUE expect_failure "live health rejects ambiguous enablement value" "PASSKEY_BACKUP_LIVE_HEALTH must be exactly 0, false, 1, or true"

reset_fixture
PASSKEY_BACKUP_LIVE_HEALTH=1 PASSKEY_BACKUP_HEALTH_RETRY_DELAY_SECONDS=0 FAKE_PASSKEY_AUDIT_SCENARIO=live-health-flaky expect_success "live health retries transient failure"

reset_fixture
PASSKEY_BACKUP_LIVE_HEALTH=1 FAKE_PASSKEY_AUDIT_SCENARIO=live-health-fail expect_failure "live health failure" "Passkey backup challenge service live health check failed"

reset_fixture
PASSKEY_BACKUP_LIVE_HEALTH=1 FAKE_PASSKEY_AUDIT_SCENARIO=live-health-non-json expect_failure "live health non-json body preview" "Body preview: <withheld by strict health validator>"

reset_fixture
perl -0pi -e 's/fearless-passkey-backup/wrong-passkey-service/' "$bin_dir/curl"
PASSKEY_BACKUP_LIVE_HEALTH=1 expect_failure "live health identity failure" "health service must identify fearless-passkey-backup"

reset_fixture
PASSKEY_BACKUP_LIVE_HEALTH=1 FAKE_PASSKEY_AUDIT_SCENARIO=live-health-non-json expect_failure "live health rejects non-JSON without parser fragments" "health response must contain valid JSON"

reset_fixture
malicious_home="$tmp_dir/malicious-home"
malicious_curl_home="$tmp_dir/malicious-curl-home"
malicious_xdg="$tmp_dir/malicious-xdg"
malicious_path="$tmp_dir/malicious-path"
ambient_curl_marker="$tmp_dir/ambient-curl-invoked"
mkdir -p "$malicious_home" "$malicious_curl_home" "$malicious_xdg/curl" "$malicious_path"
write_file "$malicious_home/.curlrc" '--url http://evil.example/' '--location'
write_file "$malicious_curl_home/.curlrc" '--proxy http://evil.example:8080'
write_file "$malicious_xdg/curl/curlrc" '--cacert /tmp/evil-ca.pem'
write_file "$malicious_path/curl" \
  '#!/usr/bin/env bash' \
  "printf '%s\\n' path >> '$ambient_curl_marker'" \
  'exit 99'
chmod +x "$malicious_path/curl"
curl() {
  printf '%s\n' function >> "$ambient_curl_marker"
  return 99
}
export -f curl
HOME="$malicious_home" \
  CURL_HOME="$malicious_curl_home" \
  XDG_CONFIG_HOME="$malicious_xdg" \
  HTTPS_PROXY="http://proxy.example:8080" \
  HTTP_PROXY="http://proxy.example:8080" \
  ALL_PROXY="socks5://proxy.example:1080" \
  NO_PROXY="" \
  CURL_CA_BUNDLE="/tmp/evil-ca.pem" \
  SSL_CERT_FILE="/tmp/evil-cert.pem" \
  SSL_CERT_DIR="/tmp/evil-certs" \
  CURLRC="$malicious_home/.curlrc" \
  PASSKEY_TEST_AMBIENT_PATH_PREFIX="$malicious_path" \
  PASSKEY_BACKUP_LIVE_HEALTH=1 \
  expect_success "live health neutralizes curlrc PATH function proxy and CA injection"
unset -f curl
[[ ! -e "$ambient_curl_marker" ]] || fail "ambient curl injection was invoked"

reset_fixture
PASSKEY_BACKUP_LIVE_HEALTH=1 \
  PASSKEY_BACKUP_HEALTH_CONNECT_TIMEOUT_SECONDS=60 \
  PASSKEY_BACKUP_HEALTH_TIMEOUT_SECONDS=60 \
  PASSKEY_BACKUP_HEALTH_MAX_RESPONSE_BYTES=65536 \
  PASSKEY_BACKUP_HEALTH_ATTEMPTS=5 \
  PASSKEY_BACKUP_HEALTH_RETRY_DELAY_SECONDS=0 \
  expect_success "live health accepts exact bounded maximum controls"

reset_fixture
PASSKEY_BACKUP_LIVE_HEALTH=1 PASSKEY_BACKUP_HEALTH_TIMEOUT_SECONDS=0 expect_failure "live health rejects zero total timeout" "PASSKEY_BACKUP_HEALTH_TIMEOUT_SECONDS must be a canonical integer"

reset_fixture
PASSKEY_BACKUP_LIVE_HEALTH=1 PASSKEY_BACKUP_HEALTH_TIMEOUT_SECONDS=01 expect_failure "live health rejects noncanonical total timeout" "PASSKEY_BACKUP_HEALTH_TIMEOUT_SECONDS must be a canonical integer"

reset_fixture
PASSKEY_BACKUP_LIVE_HEALTH=1 PASSKEY_BACKUP_HEALTH_TIMEOUT_SECONDS=61 expect_failure "live health rejects excessive total timeout" "PASSKEY_BACKUP_HEALTH_TIMEOUT_SECONDS must be a canonical integer"

reset_fixture
PASSKEY_BACKUP_LIVE_HEALTH=1 PASSKEY_BACKUP_HEALTH_CONNECT_TIMEOUT_SECONDS=11 expect_failure "live health rejects connect timeout beyond total" "PASSKEY_BACKUP_HEALTH_CONNECT_TIMEOUT_SECONDS must not exceed"

reset_fixture
PASSKEY_BACKUP_LIVE_HEALTH=1 PASSKEY_BACKUP_HEALTH_CONNECT_TIMEOUT_SECONDS=-1 expect_failure "live health rejects negative connect timeout" "PASSKEY_BACKUP_HEALTH_CONNECT_TIMEOUT_SECONDS must be a canonical integer"

reset_fixture
PASSKEY_BACKUP_LIVE_HEALTH=1 PASSKEY_BACKUP_HEALTH_MAX_RESPONSE_BYTES=0 expect_failure "live health rejects zero response cap" "PASSKEY_BACKUP_HEALTH_MAX_RESPONSE_BYTES must be a canonical integer"

reset_fixture
PASSKEY_BACKUP_LIVE_HEALTH=1 PASSKEY_BACKUP_HEALTH_MAX_RESPONSE_BYTES=65537 expect_failure "live health rejects excessive response cap" "PASSKEY_BACKUP_HEALTH_MAX_RESPONSE_BYTES must be a canonical integer"

reset_fixture
PASSKEY_BACKUP_LIVE_HEALTH=1 PASSKEY_BACKUP_HEALTH_MAX_RESPONSE_BYTES=1 expect_failure "live health enforces configured small response cap" "health response exceeded the configured 1-byte limit"

reset_fixture
PASSKEY_BACKUP_LIVE_HEALTH=1 PASSKEY_BACKUP_HEALTH_ATTEMPTS=6 expect_failure "live health rejects excessive attempts" "PASSKEY_BACKUP_HEALTH_ATTEMPTS must be a canonical integer"

reset_fixture
PASSKEY_BACKUP_LIVE_HEALTH=1 PASSKEY_BACKUP_HEALTH_RETRY_DELAY_SECONDS=31 expect_failure "live health rejects excessive retry delay" "PASSKEY_BACKUP_HEALTH_RETRY_DELAY_SECONDS must be a canonical integer"

reset_fixture
PASSKEY_BACKUP_LIVE_HEALTH=1 FAKE_PASSKEY_AUDIT_SCENARIO=live-health-old-curl expect_failure "live health requires streaming response limit support" "curl 8.4 or newer is required"

reset_fixture
PASSKEY_BACKUP_LIVE_HEALTH=1 FAKE_PASSKEY_AUDIT_SCENARIO=live-health-redirect expect_failure "live health redirect rejection" "health endpoint must return HTTP 200"

reset_fixture
PASSKEY_BACKUP_LIVE_HEALTH=1 FAKE_PASSKEY_AUDIT_SCENARIO=live-health-downgrade expect_failure "live health downgrade rejection" "effective URL must remain the exact reviewed health URL"

reset_fixture
PASSKEY_BACKUP_LIVE_HEALTH=1 FAKE_PASSKEY_AUDIT_SCENARIO=live-health-foreign-effective-url expect_failure "live health foreign redirect target rejection" "effective URL must remain the exact reviewed health URL"

reset_fixture
PASSKEY_BACKUP_LIVE_HEALTH=1 FAKE_PASSKEY_AUDIT_SCENARIO=live-health-wrong-content-type expect_failure "live health content type rejection" "Content-Type must be application/json; charset=utf-8"

reset_fixture
PASSKEY_BACKUP_LIVE_HEALTH=1 FAKE_PASSKEY_AUDIT_SCENARIO=live-health-json-prefix-content-type expect_failure "live health JSON prefix content type rejection" "Content-Type must be application/json; charset=utf-8"

reset_fixture
PASSKEY_BACKUP_LIVE_HEALTH=1 FAKE_PASSKEY_AUDIT_SCENARIO=live-health-multiple-content-type expect_failure "live health multiple content type rejection" "Content-Type must be application/json; charset=utf-8"

reset_fixture
PASSKEY_BACKUP_LIVE_HEALTH=1 FAKE_PASSKEY_AUDIT_SCENARIO=live-health-wrong-status expect_failure "live health non-200 status rejection" "health endpoint must return HTTP 200"

reset_fixture
PASSKEY_BACKUP_LIVE_HEALTH=1 FAKE_PASSKEY_AUDIT_SCENARIO=live-health-oversize expect_failure "live health response size bound" "health response exceeded the configured 4096-byte limit"

reset_fixture
PASSKEY_BACKUP_LIVE_HEALTH=1 FAKE_PASSKEY_AUDIT_SCENARIO=live-health-malformed-metadata expect_failure "live health malformed curl metadata rejection" "metadata must contain exactly four fields"

reset_fixture
PASSKEY_BACKUP_LIVE_HEALTH=1 FAKE_PASSKEY_AUDIT_SCENARIO=live-health-size-mismatch expect_failure "live health downloaded size mismatch rejection" "downloaded size must match"

reset_fixture
PASSKEY_BACKUP_LIVE_HEALTH=1 FAKE_PASSKEY_AUDIT_SCENARIO=live-health-empty expect_failure "live health empty response rejection" "health response body must not be empty"

reset_fixture
PASSKEY_BACKUP_LIVE_HEALTH=1 FAKE_PASSKEY_AUDIT_SCENARIO=live-health-extra-field expect_failure "live health extra field rejection" "must contain exactly ok, service, rpId, and schemaVersion"

reset_fixture
PASSKEY_BACKUP_LIVE_HEALTH=1 FAKE_PASSKEY_AUDIT_SCENARIO=live-health-duplicate-field expect_failure "live health duplicate field rejection" "must contain exactly four JSON properties without duplicates"

reset_fixture
PASSKEY_BACKUP_LIVE_HEALTH=1 FAKE_PASSKEY_AUDIT_SCENARIO=live-health-escaped-duplicate-field expect_failure "live health escaped duplicate field rejection" "must contain exactly four JSON properties without duplicates"

reset_fixture
PASSKEY_BACKUP_LIVE_HEALTH=1 FAKE_PASSKEY_AUDIT_SCENARIO=live-health-invalid-utf8 expect_failure "live health invalid UTF-8 rejection" "health response must contain valid UTF-8"

reset_fixture
PASSKEY_BACKUP_LIVE_HEALTH=1 FAKE_PASSKEY_AUDIT_SCENARIO=live-health-bom expect_failure "live health UTF-8 BOM rejection" "health response must not contain a UTF-8 BOM"

reset_fixture
PASSKEY_BACKUP_LIVE_HEALTH=1 \
  PASSKEY_BACKUP_HEALTH_TEST_CURL_BIN="relative/curl" \
  expect_failure "live health rejects relative test curl" "must be an absolute, regular, executable, non-symlink test fixture"

reset_fixture
real_test_curl="$bin_dir/curl"
ln -s "$real_test_curl" "$tmp_dir/symlink-curl"
PASSKEY_BACKUP_LIVE_HEALTH=1 \
  PASSKEY_BACKUP_HEALTH_TEST_CURL_BIN="$tmp_dir/symlink-curl" \
  expect_failure "live health rejects symlink test curl" "must be an absolute, regular, executable, non-symlink test fixture"

reset_fixture
expect_command_failure \
  "live health rejects test curl outside explicit test mode" \
  "PASSKEY_BACKUP_HEALTH_TEST_CURL_BIN is rejected unless PASSKEY_BACKUP_HEALTH_TEST_MODE=1" \
  /usr/bin/env \
    PASSKEY_AUDIT_ROOT="$workspace" \
    PASSKEY_BACKUP_LIVE_HEALTH=1 \
    PASSKEY_BACKUP_HEALTH_TEST_CURL_BIN="$bin_dir/curl" \
    PATH="$bin_dir:$PATH" \
    /bin/bash "$AUDIT_SCRIPT"

reset_fixture
rm "$workspace/config/passkey-backup-production.json"
expect_failure "missing passkey production config" "Passkey backup production config missing"

reset_fixture
rm "$workspace/config/passkey-backup-challenge-service.openapi.json"
expect_failure "missing passkey OpenAPI contract" "Passkey backup challenge service OpenAPI contract missing"

reset_fixture
perl -0pi -e 's/"required": \["ok", "service", "rpId", "schemaVersion"\]/"required": ["ok", "rpId", "schemaVersion"]/' "$workspace/config/passkey-backup-challenge-service.openapi.json"
expect_failure "missing health service identity schema" "HealthResponse schema must require service"

reset_fixture
perl -0pi -e 's/"storageKey", //' "$workspace/config/passkey-backup-challenge-service.openapi.json"
expect_failure "missing storageKey response schema" "RegistrationChallengeResponse schema must require storageKey"

reset_fixture
perl -0pi -e 's/"required": \["clientDataJSON", "attestationObject"\]/"required": ["clientDataJSON"]/' "$workspace/config/passkey-backup-challenge-service.openapi.json"
expect_failure "missing credential attestationObject schema" "RegistrationAuthenticatorResponse schema must require attestationObject"

reset_fixture
perl -0pi -e 's/"required": \["clientDataJSON", "authenticatorData", "signature", "userHandle"\]/"required": ["clientDataJSON", "authenticatorData"]/' "$workspace/config/passkey-backup-challenge-service.openapi.json"
expect_failure "missing assertion signature and userHandle schema" "AssertionAuthenticatorResponse schema must require signature"

reset_fixture
perl -0pi -e 's/"required": \["id", "rawId", "type", "clientExtensionResults", "response"\]/"required": ["id", "response"]/' "$workspace/config/passkey-backup-challenge-service.openapi.json"
expect_failure "missing credential envelope fields" "RegistrationCredentialResponse schema must require rawId"

reset_fixture
perl -0pi -e 's#"challengeServiceBaseUrl": "https://backup\.fearlesswallet\.io"#"challengeServiceBaseUrl": "http://backup.fearlesswallet.io"#' "$workspace/config/passkey-backup-production.json"
expect_failure "invalid passkey production config" "challengeServiceBaseUrl must use HTTPS"

reset_fixture
perl -0pi -e 's|"challengeServiceBaseUrl": "https://backup\.fearlesswallet\.io"|"challengeServiceBaseUrl": "https://operator:secret\@backup.fearlesswallet.io"|' "$workspace/config/passkey-backup-production.json"
expect_failure "credentialed passkey production config URL" "challengeServiceBaseUrl must not contain credentials"

reset_fixture
perl -0pi -e 's|"challengeServiceBaseUrl": "https://backup\.fearlesswallet\.io"|"challengeServiceBaseUrl": "https://backup.fearlesswallet.io?token=secret#fragment"|' "$workspace/config/passkey-backup-production.json"
expect_failure "query-fragment passkey production config URL" "challengeServiceBaseUrl must not contain query strings or fragments"

reset_fixture
set_passkey_config_value challengeServiceBaseUrl "https://backup.fearlesswallet.io:443"
expect_failure "explicit default port passkey production config URL" "challengeServiceBaseUrl must exactly match https://backup.fearlesswallet.io"

reset_fixture
set_passkey_config_value challengeServiceBaseUrl "https://backup.fearlesswallet.io:444"
expect_failure "nondefault port passkey production config URL" "challengeServiceBaseUrl must use the default HTTPS port"

reset_fixture
set_passkey_config_value challengeServiceBaseUrl "https://BACKUP.fearlesswallet.io"
expect_failure "mixed-case host passkey production config URL" "challengeServiceBaseUrl must exactly match https://backup.fearlesswallet.io"

reset_fixture
set_passkey_config_value challengeServiceBaseUrl "https://backup.fearlesswallet.io."
expect_failure "trailing-dot host passkey production config URL" "challengeServiceBaseUrl must use the reviewed backup.fearlesswallet.io host"

reset_fixture
set_passkey_config_value challengeServiceBaseUrl "https://%62ackup.fearlesswallet.io"
expect_failure "encoded host passkey production config URL" "Passkey backup production config invalid"

reset_fixture
set_passkey_config_value challengeServiceBaseUrl "https://backup.fearlesswallet.io/%2e%2e/admin"
expect_failure "encoded path traversal passkey production config URL" "Passkey backup production config invalid"

reset_fixture
set_passkey_config_value healthPath "/api/passkey-backup/v1/%2e%2e/admin"
expect_failure "encoded health path traversal production config" "healthPath must be /api/passkey-backup/v1/health"

reset_fixture
set_passkey_config_value healthPath "//evil.example/api/passkey-backup/v1/health"
expect_failure "scheme-relative health path production config" "healthPath must be /api/passkey-backup/v1/health"

reset_fixture
perl -0pi -e 's#    "createdAtMillis",\n##' "$workspace/config/passkey-backup-production.json"
expect_failure "missing encrypted backup metadata manifest field" "encryptedBackupMetadata must exactly contain"

reset_fixture
node - "$workspace/config/passkey-backup-production.json" <<'NODE'
const fs = require('fs')
const file = process.argv[2]
const data = JSON.parse(fs.readFileSync(file, 'utf8'))
delete data.challengeServicePaths.credentialsRevokeAll
fs.writeFileSync(file, JSON.stringify(data, null, 2))
NODE
expect_failure "missing credential revoke-all production path" "challengeServicePaths must expose exactly seven POST routes"

reset_fixture
perl -0pi -e 's/"finalRevocationRetainsOwnerTombstone": true/"finalRevocationRetainsOwnerTombstone": false/' "$workspace/config/passkey-backup-production.json"
expect_failure "weakened credential owner tombstone contract" "credentialLifecycle must retain the bounded tombstone and server-first deletion contract"

reset_fixture
node - "$workspace/config/passkey-backup-production.json" <<'NODE'
const fs = require('fs')
const file = process.argv[2]
const data = JSON.parse(fs.readFileSync(file, 'utf8'))
data.requestAuthorization.protectedPaths.pop()
fs.writeFileSync(file, JSON.stringify(data, null, 2))
NODE
expect_failure "unprotected credential revoke-all production path" "requestAuthorization.protectedPaths must cover all seven POST routes exactly"

reset_fixture
node - "$workspace/config/passkey-backup-challenge-service.openapi.json" <<'NODE'
const fs = require('fs')
const file = process.argv[2]
const data = JSON.parse(fs.readFileSync(file, 'utf8'))
data.components.schemas.CredentialDescriptor.properties.publicKey = { $ref: '#/components/schemas/Base64UrlBlob' }
fs.writeFileSync(file, JSON.stringify(data, null, 2))
NODE
expect_failure "leaked credential descriptor verification material" "CredentialDescriptor must not expose publicKey"

reset_fixture
node - "$workspace/config/passkey-backup-challenge-service.openapi.json" <<'NODE'
const fs = require('fs')
const file = process.argv[2]
const data = JSON.parse(fs.readFileSync(file, 'utf8'))
data.paths['/api/passkey-backup/v1/credentials/revoke-all'].post.security = []
fs.writeFileSync(file, JSON.stringify(data, null, 2))
NODE
expect_failure "unprotected OpenAPI credential revoke-all" "/api/passkey-backup/v1/credentials/revoke-all must require bearerAuth"

reset_fixture
perl -0pi -e 's#      "google-drive-consent",\n##' "$workspace/config/passkey-backup-production.json"
expect_failure "missing Android passkey release UX manifest field" "Android releaseUxChecklist must include"

reset_fixture
perl -0pi -e 's#      "cloudkit-production-schema",\n##' "$workspace/config/passkey-backup-production.json"
expect_failure "missing iOS passkey release UX manifest field" "iOS releaseUxChecklist must include"

reset_fixture
node - "$workspace/config/passkey-backup-production.json" <<'NODE'
const fs = require('fs');
const file = process.argv[2];
const data = JSON.parse(fs.readFileSync(file, 'utf8'));
data.ios.backupStorage = 'cloudkit-private-database';
fs.writeFileSync(file, JSON.stringify(data, null, 2));
NODE
expect_failure "iOS cannot use iCloud as its only recovery copy" "iOS backupStorage must be google-drive-appdata"

reset_fixture
perl -0pi -e 's#"additionalBackupStorage": "cloudkit-private-database"#"additionalBackupStorage": "google-drive-appdata"#' "$workspace/config/passkey-backup-production.json"
expect_failure "iOS additional copy cannot replace Drive" "iOS CloudKit must be an optional additional copy"

reset_fixture
node - "$workspace/config/passkey-backup-production.json" <<'NODE'
const fs = require('fs');
const file = process.argv[2];
const data = JSON.parse(fs.readFileSync(file, 'utf8'));
data.ios.googleDriveScope = 'https://www.googleapis.com/auth/drive';
fs.writeFileSync(file, JSON.stringify(data, null, 2));
NODE
expect_failure "iOS Drive scope must remain appdata" "iOS Drive scope must match Android drive.appdata"

reset_fixture
perl -0pi -e 's#https://backup\.fearlesswallet\.io#https://example.com#' "$workspace/fearless-Android/public-shared-features-backup/src/main/java/jp/co/soramitsu/backup/passkey/PasskeyBackupContract.kt"
expect_failure "android release config drift" "Android passkey challenge service URL"

reset_fixture
perl -0pi -e 's#  const val PASSKEY_BACKUP_ENABLED = false\n##' "$workspace/fearless-Android/public-shared-features-backup/src/main/java/jp/co/soramitsu/backup/passkey/PasskeyBackupContract.kt"
expect_failure "android missing disabled passkey flag" "Android passkey backup release flag disabled by default"

reset_fixture
perl -0pi -e 's#Google account selection, ##' "$workspace/fearless-Android/docs/release-checklist.md"
expect_failure "android missing Google account selection release gate" "Android release checklist passkey Google account selection UX"

reset_fixture
perl -0pi -e 's#Google Drive consent, ##' "$workspace/fearless-Android/docs/release-checklist.md"
expect_failure "android missing Google Drive consent release gate" "Android release checklist passkey Google Drive consent UX"

reset_fixture
rm -rf "$workspace/fearless-Android/public-shared-features-backup/src/main/java/jp/co/soramitsu/backup/passkey"
expect_failure "android system backup disabled without app-owned backup" "Android app must define a reviewed backup posture"

reset_fixture
rm "$workspace/fearless-Android/public-shared-features-backup/src/main/java/jp/co/soramitsu/backup/passkey/PasskeyBackupContract.kt"
expect_failure "android missing Credential Manager code" "Android must contain Credential Manager"

reset_fixture
perl -0pi -e 's#const val APP_DATA_SCOPE = "https://www\.googleapis\.com/auth/drive\.appdata"\n##' "$workspace/fearless-Android/public-shared-features-backup/src/main/java/jp/co/soramitsu/backup/passkey/GoogleDrivePasskeyBackupCloudStorage.kt"
perl -0pi -e 's#const val OAUTH_APP_DATA_SCOPE = "oauth2:\\$APP_DATA_SCOPE"\n##' "$workspace/fearless-Android/public-shared-features-backup/src/main/java/jp/co/soramitsu/backup/passkey/GoogleDrivePasskeyBackupCloudStorage.kt"
expect_failure "android missing Google Drive appdata scope" "Android Drive appdata scope"

reset_fixture
perl -0pi -e 's#class GoogleDrivePasskeyBackupCloudStorage##' "$workspace/fearless-Android/public-shared-features-backup/src/main/java/jp/co/soramitsu/backup/passkey/GoogleDrivePasskeyBackupCloudStorage.kt"
expect_failure "android missing Google Drive appDataFolder adapter" "Android must include a Google Drive appDataFolder passkey backup storage adapter"

reset_fixture
perl -0pi -e 's#const val OAUTH_APP_DATA_SCOPE = "oauth2:\\$APP_DATA_SCOPE"\n##' "$workspace/fearless-Android/public-shared-features-backup/src/main/java/jp/co/soramitsu/backup/passkey/GoogleDrivePasskeyBackupCloudStorage.kt"
perl -0pi -e 's#GoogleAuthUtil##' "$workspace/fearless-Android/public-shared-features-backup/src/main/java/jp/co/soramitsu/backup/passkey/GoogleDrivePasskeyBackupTokenProvider.kt"
perl -0pi -e 's#class GoogleDrivePasskeyBackupTokenProvider\n##' "$workspace/fearless-Android/public-shared-features-backup/src/main/java/jp/co/soramitsu/backup/passkey/GoogleDrivePasskeyBackupTokenProvider.kt"
expect_failure "android missing Google Drive token provider" "Android Google Drive token fetcher"

reset_fixture
perl -0pi -e 's#class HttpPasskeyBackupChallengeService##' "$workspace/fearless-Android/public-shared-features-backup/src/main/java/jp/co/soramitsu/backup/passkey/PasskeyBackupChallengeService.kt"
expect_failure "android missing remote challenge service" "Android passkey backup must include a remote challenge service contract"

reset_fixture
perl -0pi -e 's#class PasskeyBackupWorkflow\n##' "$workspace/fearless-Android/public-shared-features-backup/src/main/java/jp/co/soramitsu/backup/passkey/PasskeyBackupContract.kt"
expect_failure "android missing passkey workflow" "Android passkey backup must expose a testable registration and restore workflow"

reset_fixture
perl -0pi -e 's#  val walletId: String,\n##' "$workspace/fearless-Android/public-shared-features-backup/src/main/java/jp/co/soramitsu/backup/passkey/PasskeyBackupContract.kt"
expect_failure "android missing payload wallet metadata" "Android passkey encrypted payload wallet metadata"

reset_fixture
perl -0pi -e 's#^.*createdAtMillis.*\n##mg' "$workspace/fearless-Android/public-shared-features-backup/src/main/java/jp/co/soramitsu/backup/passkey/GoogleDrivePasskeyBackupCloudStorage.kt"
expect_failure "android missing Drive created timestamp metadata validation" "Android Drive passkey backup creation timestamp persistence"

reset_fixture
perl -0pi -e 's#<string>webcredentials:fearlesswallet\.io</string>##' "$workspace/fearless-iOS/fearless/WalletConnect.entitlements"
expect_failure "ios missing webcredentials" "iOS entitlements must include associated domains"

reset_fixture
perl -0pi -e 's#iCloud\.\$\(PRODUCT_BUNDLE_IDENTIFIER\)#iCloud.jp.co.soramitsu.fearless#' "$workspace/fearless-iOS/fearless/WalletConnect.entitlements"
expect_failure "ios stale literal CloudKit entitlement" "iOS configuration-resolved CloudKit container entitlement"

reset_fixture
perl -0pi -e 's#group\.\$\(PRODUCT_BUNDLE_IDENTIFIER\)#group.com.walletconnect.sdk#' "$workspace/fearless-iOS/fearless/WalletConnect.entitlements"
expect_failure "ios stale literal application group" "iOS configuration-resolved application-group entitlement"

reset_fixture
perl -0pi -e 's#</dict>#  <key>keychain-access-groups</key><array><string>group.com.walletconnect.sdk</string></array></dict>#' "$workspace/fearless-iOS/fearless/WalletConnect.entitlements"
expect_failure "ios unprovisioned explicit keychain group" "iOS unprovisioned explicit keychain access-group entitlement"

reset_fixture
perl -0pi -e 's#PRODUCT_BUNDLE_IDENTIFIER = jp\.co\.soramitsu\.fearlesswallet;#PRODUCT_BUNDLE_IDENTIFIER = jp.co.soramitsu.fearless;#' "$workspace/fearless-iOS/fearless.xcodeproj/project.pbxproj"
expect_failure "ios App Store bundle id no longer matches entitlement expansion" "iOS App Store bundle identifier"

reset_fixture
perl -0pi -e 's#iCloud\.jp\.co\.soramitsu\.fearlesswallet"#iCloud.jp.co.soramitsu.fearless"#' "$workspace/config/passkey-backup-production.json"
expect_failure "ios production config uses stale release CloudKit container" "iOS release CloudKit container must match the App Store bundle identifier"

reset_fixture
rm "$workspace/fearless-iOS/fearless/Common/Model/GoogleDrivePasskeyBackupCloudStorage.swift"
expect_failure "ios missing Google Drive primary backup" "iOS Google Drive appdata scope source missing"

reset_fixture
perl -0pi -e 's#https://www\.googleapis\.com/auth/drive\.appdata#https://www.googleapis.com/auth/drive#' "$workspace/fearless-iOS/fearless/Common/Model/GoogleDrivePasskeyBackupCloudStorage.swift"
expect_failure "ios Drive requests wrong OAuth scope" "iOS Google Drive appdata scope"

reset_fixture
perl -0pi -e 's/import CloudKit\n//' "$workspace/fearless-iOS/fearless/Common/Model/PasskeyBackupContract.swift"
perl -0pi -e 's/  let container = CKContainer\(identifier: "iCloud\.io\.fearless\.wallet"\)\n//' "$workspace/fearless-iOS/fearless/Common/Model/PasskeyBackupContract.swift"
expect_failure "ios missing CloudKit code" "iOS must contain iCloud/CloudKit backup storage integration"

reset_fixture
perl -0pi -e 's#enum PasskeyBackupError: Error \{\n  case unavailableCloudKitAccount\n\}\n##' "$workspace/fearless-iOS/fearless/Common/Model/PasskeyBackupContract.swift"
perl -0pi -e 's#protocol PasskeyBackupCloudKitAccountStatusProvider \{\n  func accountStatus\\(\\) async throws -> CKAccountStatus\n\}\n##' "$workspace/fearless-iOS/fearless/Common/Model/PasskeyBackupContract.swift"
expect_failure "ios missing CloudKit account status guard" "iOS passkey backup must fail closed when the CloudKit account is unavailable"

reset_fixture
perl -0pi -e 's#  static func validateAccountName\(_ value: String\) throws -> String \{ value \}\n##; s#  static func validateMatchingAccountName\(expected: String, actual: String\) throws -> String \{ expected \}\n##' "$workspace/fearless-iOS/fearless/Common/Model/PasskeyBackupContract.swift"
expect_failure "ios missing selected account validation" "iOS passkey backup must validate selected account names before registration"

reset_fixture
perl -0pi -e 's#  static func validateWalletId\(_ value: String\) throws -> String \{ value \}\n##' "$workspace/fearless-iOS/fearless/Common/Model/PasskeyBackupContract.swift"
expect_failure "ios missing wallet metadata validator" "iOS passkey backup wallet metadata validator"

reset_fixture
perl -0pi -e 's#  static let createdAtMillisField = "createdAtMillis"\n##' "$workspace/fearless-iOS/fearless/Common/Model/PasskeyBackupContract.swift"
expect_failure "ios missing CloudKit creation timestamp metadata" "iOS CloudKit passkey backup creation timestamp persistence"

reset_fixture
perl -0pi -e 's/PasskeyBackupChallengeService/RemovedChallengeService/g' "$workspace/fearless-iOS/fearless/Common/Model/PasskeyBackupContract.swift"
expect_failure "ios missing remote challenge service" "iOS passkey backup must include a remote challenge service contract"

reset_fixture
perl -0pi -e 's#  static let isPasskeyBackupEnabled = false\n##' "$workspace/fearless-iOS/fearless/Common/Model/PasskeyBackupContract.swift"
expect_failure "ios missing disabled passkey flag" "iOS passkey backup release flag disabled by default"

reset_fixture
perl -0pi -e 's#iCloud account availability, ##' "$workspace/fearless-iOS/docs/release-checklist.md"
expect_failure "ios missing iCloud account release gate" "iOS release checklist passkey iCloud account UX"

reset_fixture
perl -0pi -e 's#Google Drive consent, ##' "$workspace/fearless-iOS/docs/release-checklist.md"
expect_failure "ios missing Google Drive consent release gate" "iOS release checklist Google Drive consent UX"

reset_fixture
perl -0pi -e 's#cross-platform restore, ##' "$workspace/fearless-iOS/docs/release-checklist.md"
expect_failure "ios missing cross-platform restore release gate" "iOS release checklist cross-platform recovery UX"

reset_fixture
perl -0pi -e 's#CloudKit production schema, ##' "$workspace/fearless-iOS/docs/release-checklist.md"
expect_failure "ios missing CloudKit production schema release gate" "iOS release checklist passkey CloudKit production schema"

reset_fixture
perl -0pi -e 's#final class PasskeyBackupWorkflow \{\}\n##' "$workspace/fearless-iOS/fearless/Common/Model/PasskeyBackupContract.swift"
expect_failure "ios missing passkey workflow" "iOS passkey backup must expose a testable registration and restore workflow"

reset_fixture
perl -0pi -e 's/enum PasskeyCredentialResponseSerializer/enum RemovedCredentialResponseSerializer/' "$workspace/fearless-iOS/fearless/Common/Model/PasskeyBackupContract.swift"
expect_failure "ios missing standard WebAuthn serializer" "iOS standard WebAuthn credential response serializer"

reset_fixture
perl -0pi -e 's/"rawId": encodedCredentialID/"rawId": "different-id"/' "$workspace/fearless-iOS/fearless/Common/Model/PasskeyBackupContract.swift"
expect_failure "ios WebAuthn rawId no longer bound to id" "iOS WebAuthn credential rawId binding"

reset_fixture
perl -0pi -e 's/"type": "public-key"/"type": "password"/' "$workspace/fearless-iOS/fearless/Common/Model/PasskeyBackupContract.swift"
expect_failure "ios WebAuthn credential type drift" "iOS WebAuthn public-key credential type"

reset_fixture
perl -0pi -e 's/userHandle: Data/userHandle: Data?/' "$workspace/fearless-iOS/fearless/Common/Model/PasskeyBackupContract.swift"
expect_failure "ios optional WebAuthn user handle" "iOS WebAuthn optional assertion user handle is forbidden by the challenge service"

reset_fixture
perl -0pi -e 's/replacingOccurrences\(of: "=", with: ""\)/replacingOccurrences(of: "=", with: "=")/' "$workspace/fearless-iOS/fearless/Common/Model/PasskeyBackupContract.swift"
expect_failure "ios padded WebAuthn base64url output" "iOS WebAuthn unpadded base64url serialization"

reset_fixture
perl -0pi -e 's/testAssertionSerializerRejectsEveryEmptyRequiredField/testAssertionSerializerAcceptsEmptyFields/' "$workspace/fearless-iOS/fearlessTests/PasskeyBackupCredentialResponseSerializerTests.swift"
expect_failure "ios missing assertion empty-field adversarial test" "iOS WebAuthn assertion empty-field adversarial test"

reset_fixture
perl -0pi -e 's/testSerializerRejectsFieldsBeyondChallengeServiceLimits/testSerializerAcceptsOversizedFields/' "$workspace/fearless-iOS/fearlessTests/PasskeyBackupCredentialResponseSerializerTests.swift"
expect_failure "ios missing oversized-field adversarial test" "iOS WebAuthn oversized-field adversarial test"

reset_fixture
perl -0pi -e 's/maximumResponseBytes = 256 \* 1024/maximumResponseBytes = 512 * 1024/' "$workspace/fearless-iOS/fearless/Common/Model/PasskeyBackupContract.swift"
expect_failure "ios passkey response ceiling increased" "iOS passkey transport hard response-size ceiling"

reset_fixture
perl -0pi -e 's/response\.body\.count <= PasskeyBackupHTTPTransportPolicy\.maximumResponseBytes/response.body.count < PasskeyBackupHTTPTransportPolicy.maximumResponseBytes/' "$workspace/fearless-iOS/fearless/Common/Model/PasskeyBackupContract.swift"
expect_failure "ios injected transport response cap drift" "iOS passkey service injected-transport response-size guard"

reset_fixture
perl -0pi -e 's/PasskeyBackupHTTPTransportPolicy\.followsRedirects \? request : nil/PasskeyBackupHTTPTransportPolicy.followsRedirects ? nil : request/' "$workspace/fearless-iOS/fearless/Common/Model/PasskeyBackupContract.swift"
expect_failure "ios passkey redirect policy inversion" "iOS passkey transport fail-closed redirect policy"

reset_fixture
perl -0pi -e 's/withTaskCancellationHandler/withoutTaskCancellationHandler/' "$workspace/fearless-iOS/fearless/Common/Model/PasskeyBackupContract.swift"
expect_failure "ios passkey transport cancellation handler removed" "iOS passkey transport structured-cancellation propagation"

reset_fixture
perl -0pi -e 's/result\.credentialId == credentialId/result.credentialId != credentialId/' "$workspace/fearless-iOS/fearless/Common/Model/PasskeyBackupContract.swift"
expect_failure "ios compensation credential identity guard inverted" "iOS registration compensation credential-identity validation"

reset_fixture
perl -0pi -e 's/revoked\.credentialId == nil/revoked.credentialId != nil/g' "$workspace/fearless-iOS/fearless/Common/Model/PasskeyBackupContract.swift"
expect_failure "ios revoke-all credential injection guard inverted" "iOS revoke-all response credential-identity rejection"

reset_fixture
perl -0pi -e 's/testChallengeClientRejectsOversizedInjectedTransportResponsesBeforeStatusOrJSON/testChallengeClientAcceptsOversizedInjectedTransportResponses/' "$workspace/fearless-iOS/fearlessTests/PasskeyBackupCredentialResponseSerializerTests.swift"
expect_failure "ios missing injected transport cap adversarial test" "iOS injected-transport oversized-response adversarial test"

reset_fixture
perl -0pi -e 's/testURLSessionTransportRejectsInvalidResponseLimits/testURLSessionTransportAcceptsInvalidResponseLimits/' "$workspace/fearless-iOS/fearlessTests/PasskeyBackupCredentialResponseSerializerTests.swift"
expect_failure "ios missing invalid response limit adversarial test" "iOS invalid transport response-limit adversarial test"

reset_fixture
perl -0pi -e 's/testURLSessionTransportRejectsOversizedDeclaredResponseBeforeBody/testURLSessionTransportAcceptsOversizedDeclaredResponse/' "$workspace/fearless-iOS/fearlessTests/PasskeyBackupCredentialResponseSerializerTests.swift"
expect_failure "ios missing declared response cap adversarial test" "iOS declared oversized-response adversarial test"

reset_fixture
perl -0pi -e 's/testURLSessionTransportRejectsChunkedResponseBeyondLimit/testURLSessionTransportAcceptsChunkedResponseBeyondLimit/' "$workspace/fearless-iOS/fearlessTests/PasskeyBackupCredentialResponseSerializerTests.swift"
expect_failure "ios missing streamed response cap adversarial test" "iOS streamed oversized-response adversarial test"

reset_fixture
perl -0pi -e 's/testURLSessionTransportBoundsDecodedStreamingBytes/testURLSessionTransportIgnoresDecodedStreamingBytes/' "$workspace/fearless-iOS/fearlessTests/PasskeyBackupCredentialResponseSerializerTests.swift"
expect_failure "ios missing compressed expansion cap adversarial test" "iOS compressed-expansion oversized-response adversarial test"

reset_fixture
perl -0pi -e 's/testURLSessionTransportCancellationStopsTaskAndClearsState/testURLSessionTransportCancellationLeaksState/' "$workspace/fearless-iOS/fearlessTests/PasskeyBackupCredentialResponseSerializerTests.swift"
expect_failure "ios missing cancellation cleanup adversarial test" "iOS transport cancellation cleanup adversarial test"

reset_fixture
perl -0pi -e 's/testRegistrationCompensationRejectsMismatchedRevokeResultIdentities/testRegistrationCompensationAcceptsMismatchedRevokeResultIdentities/' "$workspace/fearless-iOS/fearlessTests/PasskeyBackupCredentialResponseSerializerTests.swift"
expect_failure "ios missing compensation identity adversarial test" "iOS compensation response-identity adversarial test"

reset_fixture
perl -0pi -e 's/testWorkflowRejectsRevokeAllResultContainingCredentialIdentity/testWorkflowAcceptsRevokeAllResultContainingCredentialIdentity/' "$workspace/fearless-iOS/fearlessTests/PasskeyBackupCredentialResponseSerializerTests.swift"
expect_failure "ios missing workflow revoke-all identity adversarial test" "iOS workflow revoke-all identity-injection adversarial test"

reset_fixture
perl -0pi -e 's/testCoordinatorRejectsRevokeAllResultContainingCredentialIdentity/testCoordinatorAcceptsRevokeAllResultContainingCredentialIdentity/' "$workspace/fearless-iOS/fearlessTests/PasskeyBackupCredentialResponseSerializerTests.swift"
expect_failure "ios missing coordinator revoke-all identity adversarial test" "iOS coordinator revoke-all identity-injection adversarial test"

echo "[passkey-backup-audit-test] all $TEST_CASE_COUNT tests passed"
