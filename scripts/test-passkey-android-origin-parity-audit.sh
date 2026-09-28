#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
AUDIT="$ROOT_DIR/scripts/audit-passkey-android-origin-parity.sh"
APK_HELPER="$ROOT_DIR/scripts/extract-android-apk-signer-evidence.mjs"
TMP_DIR="$(mktemp -d)"
TMP_DIR="$(cd "$TMP_DIR" && pwd -P)"
trap 'chmod -R u+w "$TMP_DIR" 2>/dev/null || true; rm -rf "$TMP_DIR"' EXIT
JAVA_HOME="${JAVA_HOME:-/opt/homebrew/opt/openjdk@21/libexec/openjdk.jdk/Contents/Home}"
export JAVA_HOME
KEYTOOL="$JAVA_HOME/bin/keytool"
[[ -x "$KEYTOOL" ]] || {
  echo '[passkey-android-origin-parity-test][error] JDK keytool is required' >&2
  exit 1
}
BUILD_TOOLS_DIR="$(find "$HOME/Library/Android/sdk/build-tools" -mindepth 1 -maxdepth 1 -type d | sort -V | tail -n 1)"
ANDROID_JAR="$(find "$HOME/Library/Android/sdk/platforms" -mindepth 2 -maxdepth 2 -type f -name android.jar | sort -V | tail -n 1)"
[[ -x "$BUILD_TOOLS_DIR/aapt" && -x "$BUILD_TOOLS_DIR/aapt2" && -x "$BUILD_TOOLS_DIR/apksigner" && -x "$BUILD_TOOLS_DIR/zipalign" && -f "$ANDROID_JAR" ]] || {
  echo '[passkey-android-origin-parity-test][error] Android SDK build tools are required' >&2
  exit 1
}

FINGERPRINT='CC:17:CB:D4:30:43:22:C5:8E:27:89:03:45:E6:00:9B:28:17:B7:7E:A2:3D:85:FF:DB:E3:33:8C:57:F3:62:C3'
ORIGIN='android:apk-key-hash:zBfL1DBDIsWOJ4kDReYAmygXt36iPYX_2-MzjFfzYsM'
ASSOCIATION="$TMP_DIR/assetlinks.json"
EVIDENCE="$TMP_DIR/evidence.json"
CONFIG="$TMP_DIR/passkey-backup-production.json"
AAB="$TMP_DIR/fearless-release.aab"
ATTESTATION="$TMP_DIR/play-app-signing-attestation.json"
PLAY_KEYSTORE="$TMP_DIR/play-app-signing-test.jks"
PLAY_CERTIFICATE="$TMP_DIR/play-app-signing-certificate.pem"
PLAY_CERT_FINGERPRINT=''
failure_count=0

sha256_file() {
  shasum -a 256 "$1" | awk '{print "sha256:" $1}'
}

reset_config() {
  cp "$ROOT_DIR/config/passkey-backup-production.json" "$CONFIG"
}

write_association() {
  cat >"$ASSOCIATION" <<JSON
[{"relation":["delegate_permission/common.get_login_creds"],"target":{"namespace":"android_app","package_name":"jp.co.soramitsu.fearless","sha256_cert_fingerprints":["$FINGERPRINT"]}}]
JSON
}

write_blocked() {
  cat >"$EVIDENCE" <<'JSON'
{"status":"blocked","releaseEnabled":false,"deploymentEvidence":[]}
JSON
}

write_ready() {
  cat >"$EVIDENCE" <<JSON
{"status":"ready","releaseEnabled":true,"deploymentEvidence":[{"webauthnAllowedOrigins":["https://fearlesswallet.io","https://backup.fearlesswallet.io","$ORIGIN"]}]}
JSON
}

write_aab() {
  local package_name="${1:-jp.co.soramitsu.fearless}"
  local version_code="${2:-42000}"
  local content="$TMP_DIR/aab-content"
  rm -rf "$content"
  mkdir -p "$content/base/manifest"
  cat >"$content/source-manifest.xml" <<XML
<manifest xmlns:android="http://schemas.android.com/apk/res/android" package="$package_name" android:versionCode="$version_code">
  <uses-sdk android:minSdkVersion="23" android:targetSdkVersion="35" />
  <application android:hasCode="false" android:label="Play attestation fixture" />
</manifest>
XML
  "$BUILD_TOOLS_DIR/aapt2" link --proto-format -o "$content/base.apk" -I "$ANDROID_JAR" --manifest "$content/source-manifest.xml"
  unzip -p "$content/base.apk" AndroidManifest.xml >"$content/base/manifest/AndroidManifest.xml"
  unzip -p "$content/base.apk" resources.pb >"$content/base/resources.pb"
  printf 'fixture-bundle-config\n' >"$content/BundleConfig.pb"
  rm -f "$AAB"
  (cd "$content" && /usr/bin/zip -q "$AAB" BundleConfig.pb base/manifest/AndroidManifest.xml base/resources.pb)
  chmod a-w "$AAB"
}

write_play_attestation() {
  local fingerprint="${1:-$PLAY_CERT_FINGERPRINT}"
  local artifact_digest="${2:-$(sha256_file "$AAB")}"
  local issued_at="${3:-$(date -u '+%Y-%m-%dT%H:%M:%SZ')}"
  chmod u+w "$ATTESTATION" 2>/dev/null || true
  PASSKEY_ATTESTATION="$ATTESTATION" \
  PASSKEY_FINGERPRINT="$fingerprint" \
  PASSKEY_ARTIFACT_DIGEST="$artifact_digest" \
  PASSKEY_CERTIFICATE_DIGEST="$(sha256_file "${PLAY_CERTIFICATE_OVERRIDE:-$PLAY_CERTIFICATE}")" \
  PASSKEY_ISSUED_AT="$issued_at" \
  node <<'NODE'
const fs = require('fs');
const value = {
  schemaVersion: 1,
  source: 'play-app-signing-certificate',
  packageName: 'jp.co.soramitsu.fearless',
  artifactType: 'aab',
  artifactSha256: process.env.PASSKEY_ARTIFACT_DIGEST,
  versionCode: 42000,
  certificateSha256Fingerprint: process.env.PASSKEY_FINGERPRINT,
  certificateFileSha256: process.env.PASSKEY_CERTIFICATE_DIGEST,
  issuedAt: process.env.PASSKEY_ISSUED_AT,
  playConsoleReleaseId: 'fearless-production-42000',
};
fs.writeFileSync(process.env.PASSKEY_ATTESTATION, `${JSON.stringify(value, null, 2)}\n`);
NODE
  chmod a-w "$ATTESTATION"
}

write_play_certificate() {
  rm -f "$PLAY_KEYSTORE" "$PLAY_CERTIFICATE"
  "$KEYTOOL" -genkeypair -keystore "$PLAY_KEYSTORE" -storepass changeit -keypass changeit \
    -alias play -dname 'CN=Play App Signing Test' -keyalg RSA -validity 3650 -noprompt >/dev/null 2>&1
  "$KEYTOOL" -exportcert -rfc -keystore "$PLAY_KEYSTORE" -storepass changeit -alias play \
    -file "$PLAY_CERTIFICATE" >/dev/null 2>&1
  chmod a-w "$PLAY_CERTIFICATE"
  PLAY_CERT_FINGERPRINT="$(PLAY_CERTIFICATE="$PLAY_CERTIFICATE" node -e 'const fs=require("fs"),crypto=require("crypto");process.stdout.write(new crypto.X509Certificate(fs.readFileSync(process.env.PLAY_CERTIFICATE)).fingerprint256)')"
}

run_audit() {
  PASSKEY_ANDROID_ASSOCIATION_FILE="$ASSOCIATION" \
  PASSKEY_DEPLOYMENT_EVIDENCE_FILE="$EVIDENCE" \
  PASSKEY_BACKUP_PRODUCTION_CONFIG_FILE="$CONFIG" \
  "$@" bash "$AUDIT"
}

play_env() {
  env \
    PASSKEY_ANDROID_ALLOWED_ORIGIN="$ORIGIN" \
    PASSKEY_ANDROID_RELEASE_SIGNER_SHA256_FINGERPRINT="${PLAY_FINGERPRINT_OVERRIDE:-$PLAY_CERT_FINGERPRINT}" \
    PASSKEY_ANDROID_RELEASE_SIGNER_EVIDENCE_SOURCE='play-app-signing-certificate' \
    PASSKEY_ANDROID_PLAY_APP_SIGNING_ATTESTATION_FILE="$ATTESTATION" \
    PASSKEY_ANDROID_PLAY_APP_SIGNING_ATTESTATION_SHA256="$(sha256_file "$ATTESTATION")" \
    PASSKEY_ANDROID_PLAY_APP_SIGNING_CERTIFICATE_FILE="${PLAY_CERTIFICATE_OVERRIDE:-$PLAY_CERTIFICATE}" \
    PASSKEY_ANDROID_PLAY_APP_SIGNING_CERTIFICATE_SHA256="${PLAY_CERT_SHA_OVERRIDE:-$(sha256_file "${PLAY_CERTIFICATE_OVERRIDE:-$PLAY_CERTIFICATE}")}" \
    PASSKEY_ANDROID_RELEASE_ARTIFACT_FILE="$AAB" \
    PASSKEY_ANDROID_RELEASE_ARTIFACT_SHA256="$(sha256_file "$AAB")" \
    "$@"
}

run_play_audit() {
  PASSKEY_ANDROID_ASSOCIATION_FILE="$ASSOCIATION" \
  PASSKEY_DEPLOYMENT_EVIDENCE_FILE="$EVIDENCE" \
  PASSKEY_BACKUP_PRODUCTION_CONFIG_FILE="$CONFIG" \
  play_env bash "$AUDIT" "$@"
}

expect_failure() {
  local expected="$1"
  shift
  local output status
  set +e
  output="$("$@" 2>&1)"
  status=$?
  set -e
  [[ $status -ne 0 ]] || { echo "expected failure: $expected" >&2; exit 1; }
  [[ "$output" == *"$expected"* ]] || { echo "$output" >&2; echo "missing: $expected" >&2; exit 1; }
  failure_count=$((failure_count + 1))
}

write_association
write_blocked
reset_config
write_aab
write_play_certificate
write_play_attestation

run_audit env >/dev/null
run_audit env PASSKEY_ANDROID_ALLOWED_ORIGIN="$ORIGIN" >/dev/null

expect_failure 'PASSKEY_ANDROID_RELEASE_SIGNER_SHA256_FINGERPRINT requires PASSKEY_ANDROID_RELEASE_SIGNER_EVIDENCE_SOURCE' \
  run_audit env PASSKEY_ANDROID_RELEASE_SIGNER_SHA256_FINGERPRINT="$FINGERPRINT"

expect_failure 'signer artifact inputs require PASSKEY_ANDROID_RELEASE_SIGNER_EVIDENCE_SOURCE' \
  run_audit env PASSKEY_ANDROID_DISTRIBUTED_APK_FILE="$TMP_DIR/no.apk"

expect_failure 'distributed-apk evidence requires PASSKEY_ANDROID_DISTRIBUTED_APK_FILE' \
  run_audit env PASSKEY_ANDROID_RELEASE_SIGNER_SHA256_FINGERPRINT="$FINGERPRINT" PASSKEY_ANDROID_RELEASE_SIGNER_EVIDENCE_SOURCE='distributed-apk'

expect_failure 'immutable X.509 certificate, attestation, and release artifact files with digests' \
  run_audit env PASSKEY_ANDROID_RELEASE_SIGNER_SHA256_FINGERPRINT="$FINGERPRINT" PASSKEY_ANDROID_RELEASE_SIGNER_EVIDENCE_SOURCE='play-app-signing-certificate'

expect_failure 'does not match the public Digital Asset Links fingerprint' \
  run_audit env PASSKEY_ANDROID_ALLOWED_ORIGIN='android:apk-key-hash:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA'

node -e 'const fs=require("fs");const f=process.argv[1];const d=JSON.parse(fs.readFileSync(f));d[0].target.sha256_cert_fingerprints[0]="AA:".repeat(31)+"AA";fs.writeFileSync(f,JSON.stringify(d));' "$ASSOCIATION"
expect_failure 'fingerprint drifted from the reviewed public release association' run_audit env
write_association

write_ready
expect_failure '--require-ready requires PASSKEY_ANDROID_ALLOWED_ORIGIN' \
  env PASSKEY_ANDROID_ASSOCIATION_FILE="$ASSOCIATION" PASSKEY_DEPLOYMENT_EVIDENCE_FILE="$EVIDENCE" PASSKEY_BACKUP_PRODUCTION_CONFIG_FILE="$CONFIG" bash "$AUDIT" --require-ready

expect_failure '--require-ready requires PASSKEY_ANDROID_RELEASE_SIGNER_SHA256_FINGERPRINT from an independently obtained distribution signer' \
  env PASSKEY_ANDROID_ASSOCIATION_FILE="$ASSOCIATION" PASSKEY_DEPLOYMENT_EVIDENCE_FILE="$EVIDENCE" PASSKEY_BACKUP_PRODUCTION_CONFIG_FILE="$CONFIG" PASSKEY_ANDROID_ALLOWED_ORIGIN="$ORIGIN" bash "$AUDIT" --require-ready

for rejected_source in aab signed-aab aab-upload-key upload-key play-app-signing-certificate-from-aab ' distributed-apk' 'distributed-apk '; do
  expect_failure 'AAB and upload-key evidence are not accepted' \
    env PASSKEY_ANDROID_ASSOCIATION_FILE="$ASSOCIATION" PASSKEY_DEPLOYMENT_EVIDENCE_FILE="$EVIDENCE" PASSKEY_BACKUP_PRODUCTION_CONFIG_FILE="$CONFIG" PASSKEY_ANDROID_ALLOWED_ORIGIN="$ORIGIN" PASSKEY_ANDROID_RELEASE_SIGNER_SHA256_FINGERPRINT="$FINGERPRINT" PASSKEY_ANDROID_RELEASE_SIGNER_EVIDENCE_SOURCE="$rejected_source" bash "$AUDIT" --require-ready
done

# A generated X.509 control proves the Play path derives the fingerprint from
# certificate bytes and reaches the production association comparison. It must
# fail there because a test certificate cannot equal the reviewed Play signer.
expect_failure 'distribution signer evidence does not match the public Digital Asset Links fingerprint' \
  run_play_audit --require-ready

chmod u+w "$AAB"
expect_failure 'Play release artifact must be immutable at audit time' \
  run_play_audit --require-ready
chmod a-w "$AAB"

chmod u+w "$PLAY_CERTIFICATE"
expect_failure 'Play app-signing X.509 certificate must be immutable at audit time' \
  run_play_audit --require-ready
chmod a-w "$PLAY_CERTIFICATE"

PLAY_CERT_SHA_OVERRIDE="sha256:$(printf '3%.0s' {1..64})" \
expect_failure 'certificate digest does not match the immutable X.509 certificate file' \
  run_play_audit --require-ready

write_play_attestation
chmod u+w "$ATTESTATION"
node -e 'const fs=require("fs");const f=process.argv[1];const d=JSON.parse(fs.readFileSync(f));d.certificateFileSha256="sha256:"+"4".repeat(64);fs.writeFileSync(f,JSON.stringify(d,null,2)+"\n");' "$ATTESTATION"
chmod a-w "$ATTESTATION"
expect_failure 'certificateFileSha256 must bind the immutable X.509 certificate bytes' \
  run_play_audit --require-ready

invalid_certificate="$TMP_DIR/invalid-play-certificate.pem"
printf '%s\n' 'not an X.509 certificate' >"$invalid_certificate"
chmod a-w "$invalid_certificate"
write_play_attestation
PLAY_CERTIFICATE_OVERRIDE="$invalid_certificate" \
expect_failure 'must contain one valid DER or PEM X.509 certificate' \
  run_play_audit --require-ready

multiple_certificate="$TMP_DIR/multiple-play-certificates.pem"
PLAY_SOURCE_CERTIFICATE="$PLAY_CERTIFICATE" PLAY_MULTIPLE_CERTIFICATE="$multiple_certificate" node <<'NODE'
const fs = require('fs');
const certificate = fs.readFileSync(process.env.PLAY_SOURCE_CERTIFICATE, 'utf8').trim();
fs.writeFileSync(process.env.PLAY_MULTIPLE_CERTIFICATE, `${certificate}\n${certificate}\n`);
NODE
chmod a-w "$multiple_certificate"
PLAY_CERTIFICATE_OVERRIDE="$multiple_certificate" \
expect_failure 'PEM must contain exactly one X.509 certificate and no extra content' \
  run_play_audit --require-ready

write_play_attestation

expect_failure 'attestation digest does not match the immutable attestation file' \
  env PASSKEY_ANDROID_ASSOCIATION_FILE="$ASSOCIATION" PASSKEY_DEPLOYMENT_EVIDENCE_FILE="$EVIDENCE" PASSKEY_BACKUP_PRODUCTION_CONFIG_FILE="$CONFIG" \
    PASSKEY_ANDROID_ALLOWED_ORIGIN="$ORIGIN" PASSKEY_ANDROID_RELEASE_SIGNER_SHA256_FINGERPRINT="$FINGERPRINT" PASSKEY_ANDROID_RELEASE_SIGNER_EVIDENCE_SOURCE='play-app-signing-certificate' \
    PASSKEY_ANDROID_PLAY_APP_SIGNING_ATTESTATION_FILE="$ATTESTATION" PASSKEY_ANDROID_PLAY_APP_SIGNING_ATTESTATION_SHA256="sha256:$(printf '0%.0s' {1..64})" \
    PASSKEY_ANDROID_PLAY_APP_SIGNING_CERTIFICATE_FILE="$PLAY_CERTIFICATE" PASSKEY_ANDROID_PLAY_APP_SIGNING_CERTIFICATE_SHA256="$(sha256_file "$PLAY_CERTIFICATE")" \
    PASSKEY_ANDROID_RELEASE_ARTIFACT_FILE="$AAB" PASSKEY_ANDROID_RELEASE_ARTIFACT_SHA256="$(sha256_file "$AAB")" bash "$AUDIT" --require-ready

expect_failure 'release artifact digest does not match the actual release artifact' \
  env PASSKEY_ANDROID_ASSOCIATION_FILE="$ASSOCIATION" PASSKEY_DEPLOYMENT_EVIDENCE_FILE="$EVIDENCE" PASSKEY_BACKUP_PRODUCTION_CONFIG_FILE="$CONFIG" \
    PASSKEY_ANDROID_ALLOWED_ORIGIN="$ORIGIN" PASSKEY_ANDROID_RELEASE_SIGNER_SHA256_FINGERPRINT="$FINGERPRINT" PASSKEY_ANDROID_RELEASE_SIGNER_EVIDENCE_SOURCE='play-app-signing-certificate' \
    PASSKEY_ANDROID_PLAY_APP_SIGNING_ATTESTATION_FILE="$ATTESTATION" PASSKEY_ANDROID_PLAY_APP_SIGNING_ATTESTATION_SHA256="$(sha256_file "$ATTESTATION")" \
    PASSKEY_ANDROID_PLAY_APP_SIGNING_CERTIFICATE_FILE="$PLAY_CERTIFICATE" PASSKEY_ANDROID_PLAY_APP_SIGNING_CERTIFICATE_SHA256="$(sha256_file "$PLAY_CERTIFICATE")" \
    PASSKEY_ANDROID_RELEASE_ARTIFACT_FILE="$AAB" PASSKEY_ANDROID_RELEASE_ARTIFACT_SHA256="sha256:$(printf '1%.0s' {1..64})" bash "$AUDIT" --require-ready

chmod u+w "$ATTESTATION"
expect_failure 'must be immutable at audit time' \
  env PASSKEY_ANDROID_ASSOCIATION_FILE="$ASSOCIATION" PASSKEY_DEPLOYMENT_EVIDENCE_FILE="$EVIDENCE" PASSKEY_BACKUP_PRODUCTION_CONFIG_FILE="$CONFIG" \
    PASSKEY_ANDROID_ALLOWED_ORIGIN="$ORIGIN" PASSKEY_ANDROID_RELEASE_SIGNER_SHA256_FINGERPRINT="$FINGERPRINT" PASSKEY_ANDROID_RELEASE_SIGNER_EVIDENCE_SOURCE='play-app-signing-certificate' \
    PASSKEY_ANDROID_PLAY_APP_SIGNING_ATTESTATION_FILE="$ATTESTATION" PASSKEY_ANDROID_PLAY_APP_SIGNING_ATTESTATION_SHA256="$(sha256_file "$ATTESTATION")" \
    PASSKEY_ANDROID_PLAY_APP_SIGNING_CERTIFICATE_FILE="$PLAY_CERTIFICATE" PASSKEY_ANDROID_PLAY_APP_SIGNING_CERTIFICATE_SHA256="$(sha256_file "$PLAY_CERTIFICATE")" \
    PASSKEY_ANDROID_RELEASE_ARTIFACT_FILE="$AAB" PASSKEY_ANDROID_RELEASE_ARTIFACT_SHA256="$(sha256_file "$AAB")" bash "$AUDIT" --require-ready
chmod a-w "$ATTESTATION"

write_play_attestation "$FINGERPRINT" "sha256:$(printf '2%.0s' {1..64})"
expect_failure 'artifactSha256 must bind the actual release artifact digest' \
  run_play_audit --require-ready

write_play_attestation "$FINGERPRINT" "$(sha256_file "$AAB")" '2024-01-01T00:00:00Z'
expect_failure 'must be no more than 30 days old' \
  run_play_audit --require-ready

write_play_attestation "$FINGERPRINT" "$(sha256_file "$AAB")" '2999-01-01T00:00:00Z'
expect_failure 'issuedAt must not be in the future' \
  run_play_audit --require-ready

write_play_attestation 'AA:AA:AA:AA:AA:AA:AA:AA:AA:AA:AA:AA:AA:AA:AA:AA:AA:AA:AA:AA:AA:AA:AA:AA:AA:AA:AA:AA:AA:AA:AA:AA'
expect_failure 'attestation certificate fingerprint must be derived from the X.509 certificate file' \
  run_play_audit --require-ready

write_play_attestation
chmod u+w "$ATTESTATION"
node -e 'const fs=require("fs");const f=process.argv[1];const d=JSON.parse(fs.readFileSync(f));d.extra="forged";fs.writeFileSync(f,JSON.stringify(d,null,2)+"\n");' "$ATTESTATION"
chmod a-w "$ATTESTATION"
expect_failure 'must contain exactly the reviewed schema fields' \
  run_play_audit --require-ready

write_play_attestation
chmod u+w "$ATTESTATION"
node -e 'const fs=require("fs");const f=process.argv[1];const d=JSON.parse(fs.readFileSync(f));fs.writeFileSync(f,JSON.stringify(d));' "$ATTESTATION"
chmod a-w "$ATTESTATION"
expect_failure 'must use canonical two-space JSON with one trailing newline' \
  run_play_audit --require-ready

write_play_attestation
attestation_link="$TMP_DIR/attestation-link.json"
ln -s "$ATTESTATION" "$attestation_link"
expect_failure 'must be a regular non-symlink file' \
  env PASSKEY_ANDROID_ASSOCIATION_FILE="$ASSOCIATION" PASSKEY_DEPLOYMENT_EVIDENCE_FILE="$EVIDENCE" PASSKEY_BACKUP_PRODUCTION_CONFIG_FILE="$CONFIG" \
    PASSKEY_ANDROID_ALLOWED_ORIGIN="$ORIGIN" PASSKEY_ANDROID_RELEASE_SIGNER_SHA256_FINGERPRINT="$FINGERPRINT" PASSKEY_ANDROID_RELEASE_SIGNER_EVIDENCE_SOURCE='play-app-signing-certificate' \
    PASSKEY_ANDROID_PLAY_APP_SIGNING_ATTESTATION_FILE="$attestation_link" PASSKEY_ANDROID_PLAY_APP_SIGNING_ATTESTATION_SHA256="$(sha256_file "$ATTESTATION")" \
    PASSKEY_ANDROID_PLAY_APP_SIGNING_CERTIFICATE_FILE="$PLAY_CERTIFICATE" PASSKEY_ANDROID_PLAY_APP_SIGNING_CERTIFICATE_SHA256="$(sha256_file "$PLAY_CERTIFICATE")" \
    PASSKEY_ANDROID_RELEASE_ARTIFACT_FILE="$AAB" PASSKEY_ANDROID_RELEASE_ARTIFACT_SHA256="$(sha256_file "$AAB")" bash "$AUDIT" --require-ready

invalid_aab="$TMP_DIR/invalid.aab"
printf 'not a zip\n' >"$invalid_aab"
chmod a-w "$invalid_aab"
write_play_attestation "$FINGERPRINT" "$(sha256_file "$invalid_aab")"
expect_failure 'must be a valid AAB ZIP archive' \
  env PASSKEY_ANDROID_ASSOCIATION_FILE="$ASSOCIATION" PASSKEY_DEPLOYMENT_EVIDENCE_FILE="$EVIDENCE" PASSKEY_BACKUP_PRODUCTION_CONFIG_FILE="$CONFIG" \
    PASSKEY_ANDROID_ALLOWED_ORIGIN="$ORIGIN" PASSKEY_ANDROID_RELEASE_SIGNER_SHA256_FINGERPRINT="$FINGERPRINT" PASSKEY_ANDROID_RELEASE_SIGNER_EVIDENCE_SOURCE='play-app-signing-certificate' \
    PASSKEY_ANDROID_PLAY_APP_SIGNING_ATTESTATION_FILE="$ATTESTATION" PASSKEY_ANDROID_PLAY_APP_SIGNING_ATTESTATION_SHA256="$(sha256_file "$ATTESTATION")" \
    PASSKEY_ANDROID_PLAY_APP_SIGNING_CERTIFICATE_FILE="$PLAY_CERTIFICATE" PASSKEY_ANDROID_PLAY_APP_SIGNING_CERTIFICATE_SHA256="$(sha256_file "$PLAY_CERTIFICATE")" \
    PASSKEY_ANDROID_RELEASE_ARTIFACT_FILE="$invalid_aab" PASSKEY_ANDROID_RELEASE_ARTIFACT_SHA256="$(sha256_file "$invalid_aab")" bash "$AUDIT" --require-ready

write_aab 'com.attacker.substitute'
write_play_attestation
expect_failure 'base manifest package must be exactly jp.co.soramitsu.fearless' \
  run_play_audit --require-ready

write_aab 'jp.co.soramitsu.fearless' '42001'
write_play_attestation
expect_failure 'packageName/versionCode must bind the compiled AAB base manifest' \
  run_play_audit --require-ready

missing_entries="$TMP_DIR/missing-aab-entries"
rm -rf "$missing_entries"
mkdir -p "$missing_entries"
printf 'fixture-bundle-config\n' >"$missing_entries/BundleConfig.pb"
rm -f "$AAB"
(cd "$missing_entries" && /usr/bin/zip -q "$AAB" BundleConfig.pb)
chmod a-w "$AAB"
write_play_attestation
expect_failure 'missing required AAB entry base/manifest/AndroidManifest.xml' \
  run_play_audit --require-ready

# Exercise the real APK verification helper with a locally generated v2-signed
# APK. Its signer intentionally differs from the reviewed production signer.
APK_DIR="$TMP_DIR/apk-fixture"
mkdir -p "$APK_DIR"
cat >"$APK_DIR/AndroidManifest.xml" <<'XML'
<manifest xmlns:android="http://schemas.android.com/apk/res/android" package="jp.co.soramitsu.fearless">
  <uses-sdk android:minSdkVersion="23" android:targetSdkVersion="35" />
  <application android:hasCode="false" android:label="Signer fixture" />
</manifest>
XML
"$BUILD_TOOLS_DIR/aapt" package -f -M "$APK_DIR/AndroidManifest.xml" -I "$ANDROID_JAR" -F "$APK_DIR/unsigned.apk"
"$BUILD_TOOLS_DIR/zipalign" -f 4 "$APK_DIR/unsigned.apk" "$APK_DIR/aligned.apk"
"$KEYTOOL" -genkeypair -keystore "$APK_DIR/test.jks" -storepass changeit -keypass changeit -alias signer -dname 'CN=Fearless Test' -keyalg RSA -validity 3650 -noprompt >/dev/null 2>&1
"$BUILD_TOOLS_DIR/apksigner" sign --ks "$APK_DIR/test.jks" --ks-pass pass:changeit --key-pass pass:changeit --out "$APK_DIR/signed.apk" "$APK_DIR/aligned.apk"

helper_json="$(node "$APK_HELPER" --apk "$APK_DIR/signed.apk" --apksigner "$BUILD_TOOLS_DIR/apksigner" --aapt "$BUILD_TOOLS_DIR/aapt")"
node -e 'const d=JSON.parse(process.argv[1]);if(d.source!=="distributed-apk"||d.packageName!=="jp.co.soramitsu.fearless"||!/^sha256:[0-9a-f]{64}$/.test(d.artifactSha256)||!/^(?:[0-9A-F]{2}:){31}[0-9A-F]{2}$/.test(d.signerSha256Fingerprint))process.exit(1);' "$helper_json"

generated_fingerprint="$(node -e 'process.stdout.write(JSON.parse(process.argv[1]).signerSha256Fingerprint)' "$helper_json")"
expect_failure 'distribution signer evidence does not match the public Digital Asset Links fingerprint' \
  env PASSKEY_ANDROID_ASSOCIATION_FILE="$ASSOCIATION" PASSKEY_DEPLOYMENT_EVIDENCE_FILE="$EVIDENCE" PASSKEY_BACKUP_PRODUCTION_CONFIG_FILE="$CONFIG" \
    PASSKEY_ANDROID_ALLOWED_ORIGIN="$ORIGIN" PASSKEY_ANDROID_RELEASE_SIGNER_SHA256_FINGERPRINT="$generated_fingerprint" PASSKEY_ANDROID_RELEASE_SIGNER_EVIDENCE_SOURCE='distributed-apk' \
    PASSKEY_ANDROID_DISTRIBUTED_APK_FILE="$APK_DIR/signed.apk" PASSKEY_ANDROID_RELEASE_ARTIFACT_SHA256="$(sha256_file "$APK_DIR/signed.apk")" bash "$AUDIT" --require-ready

expect_failure 'distributed APK artifact digest does not match PASSKEY_ANDROID_RELEASE_ARTIFACT_SHA256' \
  env PASSKEY_ANDROID_ASSOCIATION_FILE="$ASSOCIATION" PASSKEY_DEPLOYMENT_EVIDENCE_FILE="$EVIDENCE" PASSKEY_BACKUP_PRODUCTION_CONFIG_FILE="$CONFIG" \
    PASSKEY_ANDROID_ALLOWED_ORIGIN="$ORIGIN" PASSKEY_ANDROID_RELEASE_SIGNER_SHA256_FINGERPRINT="$generated_fingerprint" PASSKEY_ANDROID_RELEASE_SIGNER_EVIDENCE_SOURCE='distributed-apk' \
    PASSKEY_ANDROID_DISTRIBUTED_APK_FILE="$APK_DIR/signed.apk" PASSKEY_ANDROID_RELEASE_ARTIFACT_SHA256="sha256:$(printf '5%.0s' {1..64})" bash "$AUDIT" --require-ready

"$KEYTOOL" -genkeypair -keystore "$APK_DIR/second.jks" -storepass changeit -keypass changeit -alias second -dname 'CN=Fearless Second Test' -keyalg RSA -validity 3650 -noprompt >/dev/null 2>&1
"$BUILD_TOOLS_DIR/apksigner" sign --v3-signing-enabled false \
  --ks "$APK_DIR/test.jks" --ks-pass pass:changeit --key-pass pass:changeit \
  --next-signer --ks "$APK_DIR/second.jks" --ks-pass pass:changeit --key-pass pass:changeit \
  --out "$APK_DIR/multiple-signers.apk" "$APK_DIR/aligned.apk"
expect_failure 'distributed APK must verify with exactly one signing certificate' \
  node "$APK_HELPER" --apk "$APK_DIR/multiple-signers.apk" --apksigner "$BUILD_TOOLS_DIR/apksigner" --aapt "$BUILD_TOOLS_DIR/aapt"

v1_dir="$APK_DIR/v1-only"
mkdir -p "$v1_dir"
cat >"$v1_dir/AndroidManifest.xml" <<'XML'
<manifest xmlns:android="http://schemas.android.com/apk/res/android" package="jp.co.soramitsu.fearless">
  <uses-sdk android:minSdkVersion="21" android:targetSdkVersion="23" />
  <application android:hasCode="false" android:label="V1 signer fixture" />
</manifest>
XML
"$BUILD_TOOLS_DIR/aapt" package -f -M "$v1_dir/AndroidManifest.xml" -I "$ANDROID_JAR" -F "$v1_dir/unsigned.apk"
"$BUILD_TOOLS_DIR/zipalign" -f 4 "$v1_dir/unsigned.apk" "$v1_dir/aligned.apk"
"$BUILD_TOOLS_DIR/apksigner" sign --v1-signing-enabled true --v2-signing-enabled false \
  --v3-signing-enabled false --v4-signing-enabled false \
  --ks "$APK_DIR/test.jks" --ks-pass pass:changeit --key-pass pass:changeit \
  --out "$v1_dir/signed.apk" "$v1_dir/aligned.apk"
expect_failure 'distributed APK must verify with APK Signature Scheme v2 or v3' \
  node "$APK_HELPER" --apk "$v1_dir/signed.apk" --apksigner "$BUILD_TOOLS_DIR/apksigner" --aapt "$BUILD_TOOLS_DIR/aapt"

wrong_package_dir="$APK_DIR/wrong-package"
mkdir -p "$wrong_package_dir"
cat >"$wrong_package_dir/AndroidManifest.xml" <<'XML'
<manifest xmlns:android="http://schemas.android.com/apk/res/android" package="com.attacker.substitute">
  <uses-sdk android:minSdkVersion="23" android:targetSdkVersion="35" />
  <application android:hasCode="false" android:label="Wrong package fixture" />
</manifest>
XML
"$BUILD_TOOLS_DIR/aapt" package -f -M "$wrong_package_dir/AndroidManifest.xml" -I "$ANDROID_JAR" -F "$wrong_package_dir/unsigned.apk"
"$BUILD_TOOLS_DIR/zipalign" -f 4 "$wrong_package_dir/unsigned.apk" "$wrong_package_dir/aligned.apk"
"$BUILD_TOOLS_DIR/apksigner" sign --ks "$APK_DIR/test.jks" --ks-pass pass:changeit --key-pass pass:changeit \
  --out "$wrong_package_dir/signed.apk" "$wrong_package_dir/aligned.apk"
expect_failure 'distributed APK package must be exactly jp.co.soramitsu.fearless' \
  node "$APK_HELPER" --apk "$wrong_package_dir/signed.apk" --apksigner "$BUILD_TOOLS_DIR/apksigner" --aapt "$BUILD_TOOLS_DIR/aapt"

cp "$APK_DIR/signed.apk" "$APK_DIR/tampered.apk"
printf 'tamper' >>"$APK_DIR/tampered.apk"
expect_failure 'distributed APK signature verification failed' \
  node "$APK_HELPER" --apk "$APK_DIR/tampered.apk" --apksigner "$BUILD_TOOLS_DIR/apksigner" --aapt "$BUILD_TOOLS_DIR/aapt"

ln -s "$APK_DIR/signed.apk" "$APK_DIR/symlink.apk"
expect_failure 'must be an absolute regular non-symlink file' \
  node "$APK_HELPER" --apk "$APK_DIR/symlink.apk" --apksigner "$BUILD_TOOLS_DIR/apksigner" --aapt "$BUILD_TOOLS_DIR/aapt"

write_blocked
reset_config
node -e 'const fs=require("fs");const f=process.argv[1];const d=JSON.parse(fs.readFileSync(f));d.android.webauthnOrigin="android:apk-key-hash:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA";fs.writeFileSync(f,JSON.stringify(d));' "$CONFIG"
expect_failure 'Android origin does not match the public Digital Asset Links fingerprint' run_audit env

reset_config
node -e 'const fs=require("fs");const f=process.argv[1];const d=JSON.parse(fs.readFileSync(f));d.releaseEnabled=true;fs.writeFileSync(f,JSON.stringify(d));' "$CONFIG"
expect_failure 'release flags must remain disabled' run_audit env

reset_config
node -e 'const fs=require("fs");const f=process.argv[1];const d=JSON.parse(fs.readFileSync(f));d.webauthnAllowedOrigins.reverse();fs.writeFileSync(f,JSON.stringify(d));' "$CONFIG"
expect_failure 'webauthnAllowedOrigins must contain the exact reviewed origins' run_audit env

[[ "$failure_count" -eq 46 ]] || {
  echo "[passkey-android-origin-parity-test][error] expected 46 negative cases, ran $failure_count" >&2
  exit 1
}
echo '[passkey-android-origin-parity-test] all tests passed (46 negative cases; X.509-derived Play attestation and real APK extraction exercised)'
