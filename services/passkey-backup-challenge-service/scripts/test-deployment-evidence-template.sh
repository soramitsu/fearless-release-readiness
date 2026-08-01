#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
GENERATOR_SCRIPT="$SCRIPT_DIR/generate-deployment-evidence-template.sh"
AUDIT_SCRIPT="$SCRIPT_DIR/audit-deployment-evidence.sh"
DEFAULT_MANIFEST="$SCRIPT_DIR/production-deployment-evidence.json"

fail() {
  echo "[passkey-deployment-evidence-template-test][error] $*" >&2
  exit 1
}

expect_failure() {
  local name="$1"
  local expected="$2"
  shift 2
  local output

  set +e
  output="$("$@" 2>&1)"
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

mutate_json() {
  local file="$1"
  local script="$2"
  PASSKEY_FIXTURE="$file" node -e "$script"
}

tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

stdout_template="$tmp_dir/stdout-template.json"
output_template="$tmp_dir/output-template.json"
separator_template="$tmp_dir/separator-template.json"

bash "$GENERATOR_SCRIPT" --evidence "$DEFAULT_MANIFEST" >"$stdout_template"
bash "$GENERATOR_SCRIPT" --evidence "$DEFAULT_MANIFEST" --output "$output_template" >"$tmp_dir/output-stdout.json"
cmp "$output_template" "$tmp_dir/output-stdout.json" >/dev/null || fail "template output file must match stdout"
cmp "$stdout_template" "$output_template" >/dev/null || fail "template generation must be deterministic"

bash "$GENERATOR_SCRIPT" -- --evidence "$DEFAULT_MANIFEST" --output "$separator_template" >"$tmp_dir/separator-stdout.json"
cmp "$output_template" "$separator_template" >/dev/null || fail "template generation must accept a standalone argument separator"
cmp "$separator_template" "$tmp_dir/separator-stdout.json" >/dev/null || fail "separator template output file must match stdout"

node - "$output_template" <<'NODE'
const fs = require('fs');
const file = process.argv[2];
const manifest = JSON.parse(fs.readFileSync(file, 'utf8'));
const errors = [];
const secretKeyPattern =
  /(?:secret|password|token|private[_-]?key|authorization|cookie|credentialStoreSnapshot|credentialsByStorageKey|clientDataJSON|mnemonic|seed)/iu;

function check(condition, message) {
  if (!condition) errors.push(message);
}

function isRecord(value) {
  return value && typeof value === 'object' && !Array.isArray(value);
}

function secretLikeKeyReason(value, currentPath = '$') {
  if (Array.isArray(value)) {
    for (let index = 0; index < value.length; index += 1) {
      const reason = secretLikeKeyReason(value[index], `${currentPath}[${index}]`);
      if (reason) return reason;
    }
    return null;
  }
  if (!isRecord(value)) return null;

  for (const [key, child] of Object.entries(value)) {
    if (secretKeyPattern.test(key)) return `${currentPath}.${key}`;
    const reason = secretLikeKeyReason(child, `${currentPath}.${key}`);
    if (reason) return reason;
  }
  return null;
}

check(manifest.schemaVersion === 1, 'schemaVersion must be 1');
check(manifest.scope === 'passkey-backup-challenge-service-production-deployment-readiness', 'scope mismatch');
check(manifest.status === 'ready', 'template must show the operator target status');
check(manifest.releaseEnabled === true, 'template must show the operator target releaseEnabled value');
check(Array.isArray(manifest.blockers) && manifest.blockers.length === 0, 'template blockers must be empty');
check(Array.isArray(manifest.deploymentEvidence) && manifest.deploymentEvidence.length === 1, 'template must contain one deployment evidence record');
check(secretLikeKeyReason(manifest) === null, 'template must not contain secret-like keys');

const evidence = manifest.deploymentEvidence[0] || {};
check(evidence.imageDigest === 'sha256:TODO_64_HEX_IMAGE_DIGEST', 'image digest placeholder mismatch');
check(evidence.deploymentId === 'TODO_PRODUCTION_DEPLOYMENT_ID', 'deployment id placeholder mismatch');
check(evidence.deployedCommit === 'TODO_40_HEX_GIT_COMMIT', 'deployed commit placeholder mismatch');
check(evidence.deployedAt === 'TODO_UTC_DEPLOYED_AT_SECONDS', 'deployedAt placeholder mismatch');
check(evidence.operator === 'TODO_RELEASE_OPERATOR', 'operator placeholder mismatch');
check(evidence.smokePassedAt === 'TODO_UTC_SMOKE_TIMESTAMP_SECONDS', 'smoke timestamp placeholder mismatch');
check(evidence.smokeCommand === manifest.smokeCommand, 'smokeCommand must be copied from manifest');
check(evidence.healthUrl === manifest.healthUrl, 'healthUrl must be copied from manifest');
check(evidence.credentialStoreVolume === manifest.credentialStoreVolume, 'credentialStoreVolume must be copied from manifest');
check(evidence.credentialStoreFile === manifest.credentialStoreFile, 'credentialStoreFile must be copied from manifest');
check(
  JSON.stringify(evidence.webauthnAllowedOrigins) === JSON.stringify([
    'https://fearlesswallet.io',
    'https://backup.fearlesswallet.io',
    'android:apk-key-hash:TODO_RELEASE_CERT_SHA256_BASE64URL',
  ]),
  'WebAuthn allowed origins must include the explicit Android release-certificate placeholder',
);
check(evidence.requestAccessPolicy?.mode === 'atomic-one-time-consume', 'request access policy must atomically consume one-time grants');
check(evidence.requestAccessPolicy?.audience === 'fearless-passkey-backup', 'request access audience mismatch');
check(evidence.requestAccessPolicy?.stableCrossPlatformWalletSubject === true, 'request access subject must be cross-platform stable');
check(evidence.requestAccessPolicy?.authorizedSmokePassed === true, 'authorized smoke target must be true');
check(evidence.requestAccessPolicy?.credentialLifecycleSmokePassed === true, 'credential lifecycle smoke target must be true');
check(evidence.requestAccessPolicy?.ownerTombstonePersistencePassed === true, 'owner tombstone persistence target must be true');
check(evidence.requestAccessPolicy?.crossSubjectTakeoverDenied === true, 'cross-subject takeover target must be denied');
check(evidence.requestAccessPolicy?.sameOwnerReregistrationPassed === true, 'same-owner re-registration target must be true');
check(evidence.requestAccessPolicy?.cloudDeleteRevokesServerFirst === true, 'cloud deletion ordering target must be true');
check(evidence.requestAccessPolicy?.listExcludesVerificationMaterial === true, 'credential list non-secret target must be true');
check(evidence.trustedProxyPolicy?.hops === 1, 'trusted proxy hops must be 1');
check(evidence.trustedProxyPolicy?.directPeerAllowlistConfigured === true, 'trusted proxy direct peer allowlist target must be true');
check(evidence.trustedProxyPolicy?.incomingHeaderSanitized === true, 'trusted proxy header sanitation target must be true');
check(evidence.healthResponse?.ok === true, 'health response must show ok target');
check(evidence.healthResponse?.service === manifest.service, 'health response service mismatch');
check(evidence.healthResponse?.rpId === manifest.rpId, 'health response rpId mismatch');
check(evidence.healthResponse?.schemaVersion === manifest.schemaVersion, 'health response schemaVersion mismatch');
for (const [name, payloadPlaceholder] of [
  ['liveHealthAttestation', 'sha256:TODO_CANONICAL_HEALTH_RESPONSE_SHA256'],
  ['platformProvisioningAttestation', 'sha256:TODO_CANONICAL_PLATFORM_PROVISIONING_SHA256'],
]) {
  const attestation = evidence[name];
  check(attestation?.deploymentId === evidence.deploymentId, `${name} deployment id binding mismatch`);
  check(attestation?.deployedCommit === evidence.deployedCommit, `${name} commit binding mismatch`);
  check(attestation?.imageDigest === evidence.imageDigest, `${name} image digest binding mismatch`);
  check(attestation?.observedAt === evidence.smokePassedAt, `${name} timestamp binding mismatch`);
  check(attestation?.payloadSha256 === payloadPlaceholder, `${name} payload digest placeholder mismatch`);
}
for (const field of [
  'androidGoogleDriveConsent',
  'androidReleaseFlagDisabled',
  'iosAssociatedDomain',
  'iosCloudKitProductionSchema',
  'iosReleaseFlagDisabled',
]) {
  check(evidence.platformProvisioning?.[field] === true, `${field} target must be true`);
}

for (const field of manifest.requiredEvidenceFields || []) {
  check(Object.prototype.hasOwnProperty.call(evidence, field), `${field} missing from template evidence`);
}

if (errors.length > 0) {
  for (const error of errors) console.error(error);
  process.exit(1);
}
NODE

expect_failure \
  "template cannot pass ready audit with TODO placeholders" \
  "imageDigest must be a sha256 image digest" \
  bash "$AUDIT_SCRIPT" --evidence "$output_template" --require-ready

expect_failure "unknown generator argument" "Unknown argument" bash "$GENERATOR_SCRIPT" --nope
expect_failure "missing output argument" "--output requires a path" bash "$GENERATOR_SCRIPT" --output
expect_failure "missing manifest" "production deployment evidence manifest missing" bash "$GENERATOR_SCRIPT" --evidence "$tmp_dir/missing.json"

bad_json="$tmp_dir/bad-json.json"
printf '{' >"$bad_json"
expect_failure "invalid manifest JSON" "must be valid JSON" bash "$GENERATOR_SCRIPT" --evidence "$bad_json"

wrong_service="$tmp_dir/wrong-service.json"
cp "$DEFAULT_MANIFEST" "$wrong_service"
mutate_json "$wrong_service" 'const fs=require("fs"); const f=process.env.PASSKEY_FIXTURE; const d=JSON.parse(fs.readFileSync(f,"utf8")); d.service="wrong-service"; fs.writeFileSync(f, `${JSON.stringify(d, null, 2)}\n`);'
expect_failure "wrong service identity" "service must be fearless-passkey-backup" bash "$GENERATOR_SCRIPT" --evidence "$wrong_service"

unsupported_blocker="$tmp_dir/unsupported-blocker.json"
cp "$DEFAULT_MANIFEST" "$unsupported_blocker"
mutate_json "$unsupported_blocker" 'const fs=require("fs"); const f=process.env.PASSKEY_FIXTURE; const d=JSON.parse(fs.readFileSync(f,"utf8")); d.blockers.push("manual-approval-pending"); fs.writeFileSync(f, `${JSON.stringify(d, null, 2)}\n`);'
expect_failure "unsupported deployment evidence blocker" "unsupported deployment evidence blocker in manifest: manual-approval-pending" bash "$GENERATOR_SCRIPT" --evidence "$unsupported_blocker"

duplicate_blocker="$tmp_dir/duplicate-blocker.json"
cp "$DEFAULT_MANIFEST" "$duplicate_blocker"
mutate_json "$duplicate_blocker" 'const fs=require("fs"); const f=process.env.PASSKEY_FIXTURE; const d=JSON.parse(fs.readFileSync(f,"utf8")); d.blockers.push("platform-provisioning-incomplete"); fs.writeFileSync(f, `${JSON.stringify(d, null, 2)}\n`);'
expect_failure "duplicate deployment evidence blocker" "duplicate deployment evidence blocker in manifest" bash "$GENERATOR_SCRIPT" --evidence "$duplicate_blocker"

missing_required_field="$tmp_dir/missing-required-field.json"
cp "$DEFAULT_MANIFEST" "$missing_required_field"
mutate_json "$missing_required_field" 'const fs=require("fs"); const f=process.env.PASSKEY_FIXTURE; const d=JSON.parse(fs.readFileSync(f,"utf8")); d.requiredEvidenceFields=d.requiredEvidenceFields.filter((field)=>field!=="imageDigest"); fs.writeFileSync(f, `${JSON.stringify(d, null, 2)}\n`);'
expect_failure "missing image digest field" "requiredEvidenceFields missing imageDigest" bash "$GENERATOR_SCRIPT" --evidence "$missing_required_field"

missing_origin_field="$tmp_dir/missing-origin-field.json"
cp "$DEFAULT_MANIFEST" "$missing_origin_field"
mutate_json "$missing_origin_field" 'const fs=require("fs"); const f=process.env.PASSKEY_FIXTURE; const d=JSON.parse(fs.readFileSync(f,"utf8")); d.requiredEvidenceFields=d.requiredEvidenceFields.filter((field)=>field!=="webauthnAllowedOrigins"); fs.writeFileSync(f, `${JSON.stringify(d, null, 2)}\n`);'
expect_failure "missing WebAuthn origin field" "requiredEvidenceFields missing webauthnAllowedOrigins" bash "$GENERATOR_SCRIPT" --evidence "$missing_origin_field"

missing_access_field="$tmp_dir/missing-access-field.json"
cp "$DEFAULT_MANIFEST" "$missing_access_field"
mutate_json "$missing_access_field" 'const fs=require("fs"); const f=process.env.PASSKEY_FIXTURE; const d=JSON.parse(fs.readFileSync(f,"utf8")); d.requiredEvidenceFields=d.requiredEvidenceFields.filter((field)=>field!=="requestAccessPolicy"); fs.writeFileSync(f, `${JSON.stringify(d, null, 2)}\n`);'
expect_failure "missing request access evidence field" "requiredEvidenceFields missing requestAccessPolicy" bash "$GENERATOR_SCRIPT" --evidence "$missing_access_field"

duplicate_required_command="$tmp_dir/duplicate-required-command.json"
cp "$DEFAULT_MANIFEST" "$duplicate_required_command"
mutate_json "$duplicate_required_command" 'const fs=require("fs"); const f=process.env.PASSKEY_FIXTURE; const d=JSON.parse(fs.readFileSync(f,"utf8")); d.requiredCommands.push("npm run test:deployment-evidence-audit"); fs.writeFileSync(f, `${JSON.stringify(d, null, 2)}\n`);'
expect_failure "duplicate deployment evidence required command" "duplicate deployment evidence required command in manifest" bash "$GENERATOR_SCRIPT" --evidence "$duplicate_required_command"

duplicate_required_field="$tmp_dir/duplicate-required-field.json"
cp "$DEFAULT_MANIFEST" "$duplicate_required_field"
mutate_json "$duplicate_required_field" 'const fs=require("fs"); const f=process.env.PASSKEY_FIXTURE; const d=JSON.parse(fs.readFileSync(f,"utf8")); d.requiredEvidenceFields.push("imageDigest"); fs.writeFileSync(f, `${JSON.stringify(d, null, 2)}\n`);'
expect_failure "duplicate deployment evidence required field" "duplicate deployment evidence required field in manifest" bash "$GENERATOR_SCRIPT" --evidence "$duplicate_required_field"

unsupported_field="$tmp_dir/unsupported-field.json"
cp "$DEFAULT_MANIFEST" "$unsupported_field"
mutate_json "$unsupported_field" 'const fs=require("fs"); const f=process.env.PASSKEY_FIXTURE; const d=JSON.parse(fs.readFileSync(f,"utf8")); d.requiredEvidenceFields.push("region"); fs.writeFileSync(f, `${JSON.stringify(d, null, 2)}\n`);'
expect_failure "unsupported evidence field" "unsupported deployment evidence field in manifest: region" bash "$GENERATOR_SCRIPT" --evidence "$unsupported_field"

unsupported_top_level="$tmp_dir/unsupported-top-level.json"
cp "$DEFAULT_MANIFEST" "$unsupported_top_level"
mutate_json "$unsupported_top_level" 'const fs=require("fs"); const f=process.env.PASSKEY_FIXTURE; const d=JSON.parse(fs.readFileSync(f,"utf8")); d.region="us-east-1"; fs.writeFileSync(f, `${JSON.stringify(d, null, 2)}\n`);'
expect_failure "unsupported top-level deployment evidence field" "deployment evidence.region is not supported in public deployment evidence manifest" bash "$GENERATOR_SCRIPT" --evidence "$unsupported_top_level"

unsupported_record_field="$tmp_dir/unsupported-record-field.json"
cp "$DEFAULT_MANIFEST" "$unsupported_record_field"
mutate_json "$unsupported_record_field" 'const fs=require("fs"); const f=process.env.PASSKEY_FIXTURE; const d=JSON.parse(fs.readFileSync(f,"utf8")); d.deploymentEvidence=[{ region: "us-east-1" }]; fs.writeFileSync(f, `${JSON.stringify(d, null, 2)}\n`);'
expect_failure "unsupported deployment evidence record field" "deploymentEvidence[0].region is not supported in public deployment evidence manifest" bash "$GENERATOR_SCRIPT" --evidence "$unsupported_record_field"

unsupported_health_field="$tmp_dir/unsupported-health-field.json"
cp "$DEFAULT_MANIFEST" "$unsupported_health_field"
mutate_json "$unsupported_health_field" 'const fs=require("fs"); const f=process.env.PASSKEY_FIXTURE; const d=JSON.parse(fs.readFileSync(f,"utf8")); d.deploymentEvidence=[{ healthResponse: { commit: "c".repeat(40) } }]; fs.writeFileSync(f, `${JSON.stringify(d, null, 2)}\n`);'
expect_failure "unsupported health response evidence field" "deploymentEvidence[0].healthResponse.commit is not supported in public deployment evidence manifest" bash "$GENERATOR_SCRIPT" --evidence "$unsupported_health_field"

unsupported_platform_field="$tmp_dir/unsupported-platform-field.json"
cp "$DEFAULT_MANIFEST" "$unsupported_platform_field"
mutate_json "$unsupported_platform_field" 'const fs=require("fs"); const f=process.env.PASSKEY_FIXTURE; const d=JSON.parse(fs.readFileSync(f,"utf8")); d.deploymentEvidence=[{ platformProvisioning: { iosManualApprovalTicket: "APPROVED-1" } }]; fs.writeFileSync(f, `${JSON.stringify(d, null, 2)}\n`);'
expect_failure "unsupported platform provisioning evidence field" "deploymentEvidence[0].platformProvisioning.iosManualApprovalTicket is not supported in public deployment evidence manifest" bash "$GENERATOR_SCRIPT" --evidence "$unsupported_platform_field"

unsupported_live_attestation_field="$tmp_dir/unsupported-live-attestation-field.json"
cp "$DEFAULT_MANIFEST" "$unsupported_live_attestation_field"
mutate_json "$unsupported_live_attestation_field" 'const fs=require("fs"); const f=process.env.PASSKEY_FIXTURE; const d=JSON.parse(fs.readFileSync(f,"utf8")); d.deploymentEvidence=[{ liveHealthAttestation: { accessToken: "do-not-commit" } }]; fs.writeFileSync(f, `${JSON.stringify(d, null, 2)}\n`);'
expect_failure "secret-like live attestation field" "must not be read from public deployment evidence manifest" bash "$GENERATOR_SCRIPT" --evidence "$unsupported_live_attestation_field"

unsupported_platform_attestation_field="$tmp_dir/unsupported-platform-attestation-field.json"
cp "$DEFAULT_MANIFEST" "$unsupported_platform_attestation_field"
mutate_json "$unsupported_platform_attestation_field" 'const fs=require("fs"); const f=process.env.PASSKEY_FIXTURE; const d=JSON.parse(fs.readFileSync(f,"utf8")); d.deploymentEvidence=[{ platformProvisioningAttestation: { ticket: "APPROVED-1" } }]; fs.writeFileSync(f, `${JSON.stringify(d, null, 2)}\n`);'
expect_failure "unsupported platform attestation field" "deploymentEvidence[0].platformProvisioningAttestation.ticket is not supported in public deployment evidence manifest" bash "$GENERATOR_SCRIPT" --evidence "$unsupported_platform_attestation_field"

prefilled_deployment="$tmp_dir/prefilled-deployment.json"
cp "$DEFAULT_MANIFEST" "$prefilled_deployment"
mutate_json "$prefilled_deployment" 'const fs=require("fs"); const f=process.env.PASSKEY_FIXTURE; const d=JSON.parse(fs.readFileSync(f,"utf8")); d.deploymentEvidence=[{ imageDigest: "sha256:"+"a".repeat(64), deploymentId: "deploy-1", deployedCommit: "b".repeat(40), deployedAt: "2026-06-26T00:00:00Z", operator: "release", smokePassedAt: "2026-06-26T00:05:00Z", smokeCommand: d.smokeCommand, healthUrl: d.healthUrl, healthResponse: { ok: true, service: d.service, rpId: d.rpId, schemaVersion: d.schemaVersion }, credentialStoreVolume: d.credentialStoreVolume, credentialStoreFile: d.credentialStoreFile, platformProvisioning: { androidGoogleDriveConsent: true, androidReleaseFlagDisabled: true, iosAssociatedDomain: true, iosCloudKitProductionSchema: true, iosReleaseFlagDisabled: true } }]; fs.writeFileSync(f, `${JSON.stringify(d, null, 2)}\n`);'
expect_failure "prefilled deployment evidence" "committed deployment evidence manifest must not prefill deploymentEvidence" bash "$GENERATOR_SCRIPT" --evidence "$prefilled_deployment"

secret_manifest="$tmp_dir/secret-manifest.json"
cp "$DEFAULT_MANIFEST" "$secret_manifest"
mutate_json "$secret_manifest" 'const fs=require("fs"); const f=process.env.PASSKEY_FIXTURE; const d=JSON.parse(fs.readFileSync(f,"utf8")); d.authorization="Bearer do-not-commit"; fs.writeFileSync(f, `${JSON.stringify(d, null, 2)}\n`);'
expect_failure "secret-like manifest key" "must not be read from public deployment evidence manifest" bash "$GENERATOR_SCRIPT" --evidence "$secret_manifest"

secret_nested_manifest="$tmp_dir/secret-nested-manifest.json"
cp "$DEFAULT_MANIFEST" "$secret_nested_manifest"
mutate_json "$secret_nested_manifest" 'const fs=require("fs"); const f=process.env.PASSKEY_FIXTURE; const d=JSON.parse(fs.readFileSync(f,"utf8")); d.deploymentEvidence=[{ healthResponse: { clientDataJSON: "do-not-commit" } }]; fs.writeFileSync(f, `${JSON.stringify(d, null, 2)}\n`);'
expect_failure "nested secret-like manifest key" "must not be read from public deployment evidence manifest" bash "$GENERATOR_SCRIPT" --evidence "$secret_nested_manifest"

missing_template_command="$tmp_dir/missing-template-command.json"
cp "$DEFAULT_MANIFEST" "$missing_template_command"
mutate_json "$missing_template_command" 'const fs=require("fs"); const f=process.env.PASSKEY_FIXTURE; const d=JSON.parse(fs.readFileSync(f,"utf8")); d.requiredCommands=d.requiredCommands.filter((command)=>!command.includes("generate:deployment-evidence-template")); fs.writeFileSync(f, `${JSON.stringify(d, null, 2)}\n`);'
expect_failure "missing template generator command" "requiredCommands missing npm run generate:deployment-evidence-template" bash "$GENERATOR_SCRIPT" --evidence "$missing_template_command"

missing_template_self_test="$tmp_dir/missing-template-self-test.json"
cp "$DEFAULT_MANIFEST" "$missing_template_self_test"
mutate_json "$missing_template_self_test" 'const fs=require("fs"); const f=process.env.PASSKEY_FIXTURE; const d=JSON.parse(fs.readFileSync(f,"utf8")); d.requiredCommands=d.requiredCommands.filter((command)=>!command.includes("test:deployment-evidence-template")); fs.writeFileSync(f, `${JSON.stringify(d, null, 2)}\n`);'
expect_failure "missing template self-test command" "requiredCommands missing npm run test:deployment-evidence-template" bash "$GENERATOR_SCRIPT" --evidence "$missing_template_self_test"

echo "[passkey-deployment-evidence-template-test] all assertions passed"
