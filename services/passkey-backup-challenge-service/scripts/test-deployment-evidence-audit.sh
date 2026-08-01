#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
AUDIT_SCRIPT="$SCRIPT_DIR/audit-deployment-evidence.sh"
FIXTURE_DIR="$(mktemp -d)"
FIXTURE_DEPLOYED_COMMIT="0123456789abcdef0123456789abcdef01234567"
trap 'rm -rf "$FIXTURE_DIR"' EXIT

MISSING_GIT_BIN="$FIXTURE_DIR/missing-git-bin"
mkdir -p "$MISSING_GIT_BIN"
printf '%s\n' '#!/usr/bin/env bash' 'exit 1' >"$MISSING_GIT_BIN/git"
chmod 700 "$MISSING_GIT_BIN/git"

write_blocked_fixture() {
  local file="$1"
  cat >"$file" <<'JSON'
{
  "schemaVersion": 1,
  "scope": "passkey-backup-challenge-service-production-deployment-readiness",
  "service": "fearless-passkey-backup",
  "rpId": "fearlesswallet.io",
  "baseUrl": "https://backup.fearlesswallet.io",
  "healthUrl": "https://backup.fearlesswallet.io/api/passkey-backup/v1/health",
  "imageName": "passkey-backup-challenge-service",
  "port": 8789,
  "credentialStoreVolume": "/data/passkey-backup",
  "credentialStoreFile": "/data/passkey-backup/credentials.json",
  "status": "blocked",
  "releaseEnabled": false,
  "blockers": [
    "production-deployment-evidence-missing",
    "live-health-failing",
    "platform-provisioning-incomplete",
    "request-access-introspection-unprovisioned",
    "trusted-proxy-evidence-missing"
  ],
  "dockerBuildCommand": "docker build -t passkey-backup-challenge-service:release .",
  "smokeCommand": "PASSKEY_BACKUP_BASE_URL=https://backup.fearlesswallet.io PASSKEY_BACKUP_SMOKE_GRANT_HELPER=/run/secrets/passkey-smoke-grant-helper PASSKEY_BACKUP_SMOKE_TIMEOUT_MS=10000 npm run smoke:production",
  "requiredCommands": [
    "npm run lint:syntax",
    "npm test",
    "npm run test:deployment-evidence-template",
    "npm run generate:deployment-evidence-template -- --output build/reports/production-deployment-evidence-template.json",
    "npm run test:deployment-evidence-audit",
    "npm run audit:deployment-evidence",
    "docker build -t passkey-backup-challenge-service:release .",
    "PASSKEY_BACKUP_LIVE_HEALTH=1 PASSKEY_BACKUP_HEALTH_TIMEOUT_SECONDS=10 bash ../../scripts/audit-passkey-backup-prerequisites.sh",
    "PASSKEY_BACKUP_BASE_URL=https://backup.fearlesswallet.io PASSKEY_BACKUP_SMOKE_GRANT_HELPER=/run/secrets/passkey-smoke-grant-helper PASSKEY_BACKUP_SMOKE_TIMEOUT_MS=10000 npm run smoke:production",
    "npm run audit:deployment-evidence -- --require-ready"
  ],
  "requiredEvidenceFields": [
    "imageDigest",
    "deploymentId",
    "deployedCommit",
    "deployedAt",
    "operator",
    "smokePassedAt",
    "smokeCommand",
    "healthUrl",
    "healthResponse",
    "liveHealthAttestation",
    "credentialStoreVolume",
    "credentialStoreFile",
    "webauthnAllowedOrigins",
    "requestAccessPolicy",
    "trustedProxyPolicy",
    "platformProvisioning",
    "platformProvisioningAttestation"
  ],
  "deploymentEvidence": []
}
JSON
}

run_audit() {
  local expected_commit="${PASSKEY_DEPLOYMENT_EXPECTED_COMMIT:-$FIXTURE_DEPLOYED_COMMIT}"
  PASSKEY_DEPLOYMENT_EXPECTED_COMMIT="$expected_commit" bash "$AUDIT_SCRIPT" --evidence "$1" "${@:2}"
}

expect_success() {
  local name="$1"
  shift
  local output
  if ! output="$("$@" 2>&1)"; then
    echo "$output" >&2
    echo "[passkey-deployment-evidence-test][error] $name unexpectedly failed" >&2
    exit 1
  fi
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
    echo "[passkey-deployment-evidence-test][error] $name unexpectedly passed" >&2
    exit 1
  fi
  if [[ "$output" != *"$expected"* ]]; then
    echo "$output" >&2
    echo "[passkey-deployment-evidence-test][error] $name did not report expected text: $expected" >&2
    exit 1
  fi
}

mutate_json() {
  local file="$1"
  local script="$2"
  PASSKEY_FIXTURE="$file" node -e "$script"
}

ready_json_mutator='
const fs = require("fs");
const crypto = require("crypto");
const file = process.env.PASSKEY_FIXTURE;
const data = JSON.parse(fs.readFileSync(file, "utf8"));
const now = Math.floor(Date.now() / 60000) * 60000;
const timestamp = (millis) => new Date(millis).toISOString().replace(".000Z", "Z");
const digest = (payload) => "sha256:" + crypto.createHash("sha256").update(JSON.stringify(payload)).digest("hex");
data.status = "ready";
data.releaseEnabled = true;
data.blockers = [];
const record = {
  imageDigest: "sha256:" + "0123456789abcdef".repeat(4),
  deploymentId: "render-passkey-prod-001",
  deployedCommit: "0123456789abcdef0123456789abcdef01234567",
  deployedAt: timestamp(now - 5 * 60 * 1000),
  operator: "release-operator",
  smokePassedAt: timestamp(now),
  smokeCommand: data.smokeCommand,
  healthUrl: data.healthUrl,
  healthResponse: {
    ok: true,
    service: "fearless-passkey-backup",
    rpId: "fearlesswallet.io",
    schemaVersion: 1
  },
  credentialStoreVolume: data.credentialStoreVolume,
  credentialStoreFile: data.credentialStoreFile,
  webauthnAllowedOrigins: [
    "https://fearlesswallet.io",
    "https://backup.fearlesswallet.io",
    "android:apk-key-hash:" + Buffer.alloc(32, 0xa5).toString("base64url")
  ],
  requestAccessPolicy: {
    introspectionUrl: "https://authority.fearlesswallet.io/v1/passkey/consume",
    audience: "fearless-passkey-backup",
    mode: "atomic-one-time-consume",
    allPostRoutesProtected: true,
    stableCrossPlatformWalletSubject: true,
    authorizedSmokePassed: true,
    noRawSubjectPersisted: true,
    credentialLifecycleSmokePassed: true,
    ownerTombstonePersistencePassed: true,
    crossSubjectTakeoverDenied: true,
    sameOwnerReregistrationPassed: true,
    cloudDeleteRevokesServerFirst: true,
    listExcludesVerificationMaterial: true
  },
  trustedProxyPolicy: {
    hops: 1,
    forwardedHeader: "X-Forwarded-For",
    directPeerAllowlistConfigured: true,
    incomingHeaderSanitized: true,
    directPublicAccessBlocked: true,
    adversarialProxyTestsPassed: true
  },
  platformProvisioning: {
    androidGoogleDriveConsent: true,
    androidReleaseFlagDisabled: true,
    iosAssociatedDomain: true,
    iosCloudKitProductionSchema: true,
    iosReleaseFlagDisabled: true
  }
};
const binding = (payload) => ({
  deploymentId: record.deploymentId,
  deployedCommit: record.deployedCommit,
  imageDigest: record.imageDigest,
  observedAt: record.smokePassedAt,
  payloadSha256: digest(payload)
});
record.liveHealthAttestation = binding({
  ok: record.healthResponse.ok,
  service: record.healthResponse.service,
  rpId: record.healthResponse.rpId,
  schemaVersion: record.healthResponse.schemaVersion
});
record.platformProvisioningAttestation = binding({
  androidGoogleDriveConsent: record.platformProvisioning.androidGoogleDriveConsent,
  androidReleaseFlagDisabled: record.platformProvisioning.androidReleaseFlagDisabled,
  iosAssociatedDomain: record.platformProvisioning.iosAssociatedDomain,
  iosCloudKitProductionSchema: record.platformProvisioning.iosCloudKitProductionSchema,
  iosReleaseFlagDisabled: record.platformProvisioning.iosReleaseFlagDisabled
});
data.deploymentEvidence = [record];
fs.writeFileSync(file, JSON.stringify(data, null, 2) + "\n");
'

rebind_all_json_mutator='
const fs = require("fs");
const crypto = require("crypto");
const file = process.env.PASSKEY_FIXTURE;
const data = JSON.parse(fs.readFileSync(file, "utf8"));
const digest = (payload) => "sha256:" + crypto.createHash("sha256").update(JSON.stringify(payload)).digest("hex");
for (const record of data.deploymentEvidence) {
  const binding = (payload) => ({
    deploymentId: record.deploymentId,
    deployedCommit: record.deployedCommit,
    imageDigest: record.imageDigest,
    observedAt: record.smokePassedAt,
    payloadSha256: digest(payload)
  });
  record.liveHealthAttestation = binding({
    ok: record.healthResponse.ok,
    service: record.healthResponse.service,
    rpId: record.healthResponse.rpId,
    schemaVersion: record.healthResponse.schemaVersion
  });
  record.platformProvisioningAttestation = binding({
    androidGoogleDriveConsent: record.platformProvisioning.androidGoogleDriveConsent,
    androidReleaseFlagDisabled: record.platformProvisioning.androidReleaseFlagDisabled,
    iosAssociatedDomain: record.platformProvisioning.iosAssociatedDomain,
    iosCloudKitProductionSchema: record.platformProvisioning.iosCloudKitProductionSchema,
    iosReleaseFlagDisabled: record.platformProvisioning.iosReleaseFlagDisabled
  });
}
fs.writeFileSync(file, JSON.stringify(data, null, 2) + "\n");
'

fixture="$FIXTURE_DIR/evidence.json"
write_blocked_fixture "$fixture"
expect_success "blocked evidence without --require-ready" run_audit "$fixture"
expect_failure "blocked evidence with --require-ready" "--require-ready requires status ready" run_audit "$fixture" --require-ready

write_blocked_fixture "$fixture"
mutate_json "$fixture" 'const fs=require("fs"); const f=process.env.PASSKEY_FIXTURE; const d=JSON.parse(fs.readFileSync(f,"utf8")); d.deploymentEvidence=[{}]; fs.writeFileSync(f, JSON.stringify(d));'
expect_failure "blocked evidence with partial record" "blocked deployment evidence must keep deploymentEvidence empty; partial or stale records cannot coexist with blockers" run_audit "$fixture"

write_blocked_fixture "$fixture"
mutate_json "$fixture" 'const fs=require("fs"); const f=process.env.PASSKEY_FIXTURE; const d=JSON.parse(fs.readFileSync(f,"utf8")); d.releaseEnabled=true; fs.writeFileSync(f, JSON.stringify(d));'
expect_failure "release enabled while blocked" "releaseEnabled must remain false while deployment evidence is blocked" run_audit "$fixture"

write_blocked_fixture "$fixture"
mutate_json "$fixture" 'const fs=require("fs"); const f=process.env.PASSKEY_FIXTURE; const d=JSON.parse(fs.readFileSync(f,"utf8")); d.blockers=d.blockers.filter((b)=>b!=="platform-provisioning-incomplete"); fs.writeFileSync(f, JSON.stringify(d));'
expect_failure "blocked evidence missing platform blocker" "blocked deployment evidence must list missing deployment, live health, and platform provisioning blockers" run_audit "$fixture"

write_blocked_fixture "$fixture"
mutate_json "$fixture" 'const fs=require("fs"); const f=process.env.PASSKEY_FIXTURE; const d=JSON.parse(fs.readFileSync(f,"utf8")); d.blockers.push("manual-approval-pending"); fs.writeFileSync(f, JSON.stringify(d));'
expect_failure "unsupported deployment evidence blocker" "unsupported deployment evidence blocker: manual-approval-pending" run_audit "$fixture"

write_blocked_fixture "$fixture"
mutate_json "$fixture" 'const fs=require("fs"); const f=process.env.PASSKEY_FIXTURE; const d=JSON.parse(fs.readFileSync(f,"utf8")); d.blockers.push("platform-provisioning-incomplete"); fs.writeFileSync(f, JSON.stringify(d));'
expect_failure "duplicate deployment evidence blocker" "duplicate deployment evidence blocker" run_audit "$fixture"

write_blocked_fixture "$fixture"
mutate_json "$fixture" 'const fs=require("fs"); const f=process.env.PASSKEY_FIXTURE; const d=JSON.parse(fs.readFileSync(f,"utf8")); d.requiredCommands=d.requiredCommands.filter((command)=>!command.includes("generate:deployment-evidence-template")); fs.writeFileSync(f, JSON.stringify(d));'
expect_failure "missing deployment evidence template command" "requiredCommands must include lint, tests, Docker build, deployment evidence audits, template generation, ready audit, live health command, and route smoke command" run_audit "$fixture"

write_blocked_fixture "$fixture"
mutate_json "$fixture" 'const fs=require("fs"); const f=process.env.PASSKEY_FIXTURE; const d=JSON.parse(fs.readFileSync(f,"utf8")); d.requiredCommands.push("npm run test:deployment-evidence-audit"); fs.writeFileSync(f, JSON.stringify(d));'
expect_failure "duplicate deployment evidence required command" "duplicate deployment evidence required command" run_audit "$fixture"

write_blocked_fixture "$fixture"
mutate_json "$fixture" 'const fs=require("fs"); const f=process.env.PASSKEY_FIXTURE; const d=JSON.parse(fs.readFileSync(f,"utf8")); d.requiredCommands.push("curl https://evil.example/deploy"); fs.writeFileSync(f, JSON.stringify(d));'
expect_failure "unsupported deployment evidence required command" "unsupported deployment evidence required command: curl https://evil.example/deploy" run_audit "$fixture"

write_blocked_fixture "$fixture"
mutate_json "$fixture" 'const fs=require("fs"); const f=process.env.PASSKEY_FIXTURE; const d=JSON.parse(fs.readFileSync(f,"utf8")); d.requiredCommands=d.requiredCommands.filter((command)=>command!=="npm test"); fs.writeFileSync(f, JSON.stringify(d));'
expect_failure "missing deployment npm test command" "requiredCommands must include lint, tests, Docker build, deployment evidence audits, template generation, ready audit, live health command, and route smoke command" run_audit "$fixture"

write_blocked_fixture "$fixture"
mutate_json "$fixture" 'const fs=require("fs"); const f=process.env.PASSKEY_FIXTURE; const d=JSON.parse(fs.readFileSync(f,"utf8")); d.requiredCommands=d.requiredCommands.filter((command)=>command!=="docker build -t passkey-backup-challenge-service:release ."); fs.writeFileSync(f, JSON.stringify(d));'
expect_failure "missing deployment Docker build command" "requiredCommands must include lint, tests, Docker build, deployment evidence audits, template generation, ready audit, live health command, and route smoke command" run_audit "$fixture"

write_blocked_fixture "$fixture"
mutate_json "$fixture" 'const fs=require("fs"); const f=process.env.PASSKEY_FIXTURE; const d=JSON.parse(fs.readFileSync(f,"utf8")); d.requiredEvidenceFields.push("region"); fs.writeFileSync(f, JSON.stringify(d));'
expect_failure "unsupported required evidence field" "unsupported deployment evidence field in manifest: region" run_audit "$fixture"

write_blocked_fixture "$fixture"
mutate_json "$fixture" 'const fs=require("fs"); const f=process.env.PASSKEY_FIXTURE; const d=JSON.parse(fs.readFileSync(f,"utf8")); d.requiredEvidenceFields.push("imageDigest"); fs.writeFileSync(f, JSON.stringify(d));'
expect_failure "duplicate deployment evidence required field" "duplicate deployment evidence required field" run_audit "$fixture"

write_blocked_fixture "$fixture"
mutate_json "$fixture" 'const fs=require("fs"); const f=process.env.PASSKEY_FIXTURE; const d=JSON.parse(fs.readFileSync(f,"utf8")); d.extraEvidence="operator note"; fs.writeFileSync(f, JSON.stringify(d));'
expect_failure "unsupported top-level evidence field" "deployment evidence.extraEvidence is not supported in public deployment evidence" run_audit "$fixture"

printf '{not-json\n' >"$fixture"
expect_failure "malformed JSON" "production deployment evidence must be valid JSON" run_audit "$fixture"

write_blocked_fixture "$fixture"
mutate_json "$fixture" "$ready_json_mutator"
expect_success "ready evidence with live health and platform proof" run_audit "$fixture" --require-ready

# The 24-hour boundary is inclusive. Regenerate immediately if the wall clock
# crosses a second between fixture construction and the audit.
boundary_passed=0
for _attempt in 1 2 3; do
  write_blocked_fixture "$fixture"
  mutate_json "$fixture" "$ready_json_mutator"
  mutate_json "$fixture" 'const fs=require("fs"); const f=process.env.PASSKEY_FIXTURE; const d=JSON.parse(fs.readFileSync(f,"utf8")); const now=Math.floor(Date.now()/1000)*1000; d.deploymentEvidence[0].smokePassedAt=new Date(now-24*60*60*1000).toISOString().replace(".000Z","Z"); d.deploymentEvidence[0].deployedAt=new Date(now-24*60*60*1000-5*60*1000).toISOString().replace(".000Z","Z"); fs.writeFileSync(f, JSON.stringify(d));'
  mutate_json "$fixture" "$rebind_all_json_mutator"
  if run_audit "$fixture" --require-ready >/dev/null 2>&1; then
    boundary_passed=1
    break
  fi
done
[[ "$boundary_passed" -eq 1 ]] || {
  echo "[passkey-deployment-evidence-test][error] exact 24-hour ready evidence boundary unexpectedly failed" >&2
  exit 1
}

write_blocked_fixture "$fixture"
mutate_json "$fixture" "$ready_json_mutator"
mutate_json "$fixture" 'const fs=require("fs"); const f=process.env.PASSKEY_FIXTURE; const d=JSON.parse(fs.readFileSync(f,"utf8")); const now=Math.floor(Date.now()/1000)*1000; d.deploymentEvidence[0].smokePassedAt=new Date(now-24*60*60*1000-1000).toISOString().replace(".000Z","Z"); d.deploymentEvidence[0].deployedAt=new Date(now-24*60*60*1000-6*60*1000).toISOString().replace(".000Z","Z"); fs.writeFileSync(f, JSON.stringify(d));'
mutate_json "$fixture" "$rebind_all_json_mutator"
expect_failure "ready evidence one second beyond 24-hour boundary" "smokePassedAt must be no more than 24 hours old for ready evidence" run_audit "$fixture" --require-ready

write_blocked_fixture "$fixture"
mutate_json "$fixture" "$ready_json_mutator"
mutate_json "$fixture" 'const fs=require("fs"); const f=process.env.PASSKEY_FIXTURE; const d=JSON.parse(fs.readFileSync(f,"utf8")); const second=structuredClone(d.deploymentEvidence[0]); second.deploymentId="render-passkey-prod-002"; second.imageDigest="sha256:"+"fedcba9876543210".repeat(4); d.deploymentEvidence.push(second); fs.writeFileSync(f, JSON.stringify(d));'
mutate_json "$fixture" "$rebind_all_json_mutator"
expect_success "multiple independently bound fresh deployment records" run_audit "$fixture" --require-ready

mutate_json "$fixture" 'const fs=require("fs"); const f=process.env.PASSKEY_FIXTURE; const d=JSON.parse(fs.readFileSync(f,"utf8")); const now=Math.floor(Date.now()/1000)*1000; d.deploymentEvidence[1].smokePassedAt=new Date(now-24*60*60*1000-1000).toISOString().replace(".000Z","Z"); d.deploymentEvidence[1].deployedAt=new Date(now-24*60*60*1000-6*60*1000).toISOString().replace(".000Z","Z"); fs.writeFileSync(f, JSON.stringify(d));'
mutate_json "$fixture" "$rebind_all_json_mutator"
expect_failure "fresh record cannot mask stale second deployment" "deploymentEvidence[1].smokePassedAt must be no more than 24 hours old for ready evidence" run_audit "$fixture" --require-ready

for binding_case in \
  'liveHealthAttestation deploymentId legacy-deployment deploymentId' \
  'liveHealthAttestation deployedCommit fedcba9876543210fedcba9876543210fedcba98 deployedCommit' \
  'liveHealthAttestation imageDigest sha256:fedcba9876543210fedcba9876543210fedcba9876543210fedcba9876543210 imageDigest' \
  'platformProvisioningAttestation deploymentId legacy-deployment deploymentId' \
  'platformProvisioningAttestation deployedCommit fedcba9876543210fedcba9876543210fedcba98 deployedCommit' \
  'platformProvisioningAttestation imageDigest sha256:fedcba9876543210fedcba9876543210fedcba9876543210fedcba9876543210 imageDigest'; do
  read -r attestation field bad_value label <<<"$binding_case"
  write_blocked_fixture "$fixture"
  mutate_json "$fixture" "$ready_json_mutator"
  PASSKEY_ATTESTATION="$attestation" PASSKEY_FIELD="$field" PASSKEY_BAD_VALUE="$bad_value" mutate_json "$fixture" 'const fs=require("fs"); const f=process.env.PASSKEY_FIXTURE; const d=JSON.parse(fs.readFileSync(f,"utf8")); d.deploymentEvidence[0][process.env.PASSKEY_ATTESTATION][process.env.PASSKEY_FIELD]=process.env.PASSKEY_BAD_VALUE; fs.writeFileSync(f, JSON.stringify(d));'
  expect_failure "$attestation $field cannot bind another release" "$attestation.$field must match deploymentEvidence[0].$label" run_audit "$fixture" --require-ready
done

for attestation in liveHealthAttestation platformProvisioningAttestation; do
  write_blocked_fixture "$fixture"
  mutate_json "$fixture" "$ready_json_mutator"
  PASSKEY_ATTESTATION="$attestation" mutate_json "$fixture" 'const fs=require("fs"); const f=process.env.PASSKEY_FIXTURE; const d=JSON.parse(fs.readFileSync(f,"utf8")); d.deploymentEvidence[0][process.env.PASSKEY_ATTESTATION].payloadSha256="sha256:"+"ab".repeat(32); fs.writeFileSync(f, JSON.stringify(d));'
  expect_failure "$attestation forged payload digest" "$attestation.payloadSha256 must match the canonical attested payload" run_audit "$fixture" --require-ready
done

write_blocked_fixture "$fixture"
mutate_json "$fixture" "$ready_json_mutator"
mutate_json "$fixture" 'const fs=require("fs"); const f=process.env.PASSKEY_FIXTURE; const d=JSON.parse(fs.readFileSync(f,"utf8")); const second=structuredClone(d.deploymentEvidence[0]); second.deploymentId="render-passkey-prod-002"; second.imageDigest="sha256:"+"fedcba9876543210".repeat(4); d.deploymentEvidence.push(second); fs.writeFileSync(f, JSON.stringify(d));'
mutate_json "$fixture" "$rebind_all_json_mutator"
mutate_json "$fixture" 'const fs=require("fs"); const f=process.env.PASSKEY_FIXTURE; const d=JSON.parse(fs.readFileSync(f,"utf8")); d.deploymentEvidence[1].liveHealthAttestation=structuredClone(d.deploymentEvidence[0].liveHealthAttestation); fs.writeFileSync(f, JSON.stringify(d));'
expect_failure "cross-deployment live health attestation substitution" "deploymentEvidence[1].liveHealthAttestation.deploymentId must match deploymentEvidence[1].deploymentId" run_audit "$fixture" --require-ready

expect_failure "stale deployed commit evidence" "deployedCommit must match expected deployment commit fedcba9876543210fedcba9876543210fedcba98" \
  env PASSKEY_DEPLOYMENT_EXPECTED_COMMIT=fedcba9876543210fedcba9876543210fedcba98 bash "$AUDIT_SCRIPT" --evidence "$fixture" --require-ready

expect_failure "malformed expected deployment commit" "PASSKEY_DEPLOYMENT_EXPECTED_COMMIT must be a 40-character lowercase git commit" \
  env PASSKEY_DEPLOYMENT_EXPECTED_COMMIT=not-a-commit bash "$AUDIT_SCRIPT" --evidence "$fixture" --require-ready

expect_failure "missing expected deployment commit source" "PASSKEY_DEPLOYMENT_EXPECTED_COMMIT must be set because repository HEAD could not be determined" \
  env -u PASSKEY_DEPLOYMENT_EXPECTED_COMMIT PATH="$MISSING_GIT_BIN:$PATH" bash "$AUDIT_SCRIPT" --evidence "$fixture" --require-ready

write_blocked_fixture "$fixture"
mutate_json "$fixture" 'const fs=require("fs"); const f=process.env.PASSKEY_FIXTURE; const d=JSON.parse(fs.readFileSync(f,"utf8")); d.status="ready"; d.releaseEnabled=true; d.blockers=[]; fs.writeFileSync(f, JSON.stringify(d));'
expect_failure "ready evidence without live smoke" "ready deployment evidence requires at least one successful live production smoke record" run_audit "$fixture" --require-ready

write_blocked_fixture "$fixture"
mutate_json "$fixture" "$ready_json_mutator"
mutate_json "$fixture" 'const fs=require("fs"); const f=process.env.PASSKEY_FIXTURE; const d=JSON.parse(fs.readFileSync(f,"utf8")); d.deploymentEvidence[0].imageDigest="sha256:bad"; fs.writeFileSync(f, JSON.stringify(d));'
expect_failure "bad image digest evidence" "imageDigest must be a sha256 image digest" run_audit "$fixture" --require-ready

write_blocked_fixture "$fixture"
mutate_json "$fixture" "$ready_json_mutator"
mutate_json "$fixture" 'const fs=require("fs"); const f=process.env.PASSKEY_FIXTURE; const d=JSON.parse(fs.readFileSync(f,"utf8")); d.deploymentEvidence[0].imageDigest="sha256:"+"a".repeat(64); fs.writeFileSync(f, JSON.stringify(d));'
expect_failure "placeholder image digest evidence" "imageDigest must not be a placeholder image digest" run_audit "$fixture" --require-ready

write_blocked_fixture "$fixture"
mutate_json "$fixture" "$ready_json_mutator"
mutate_json "$fixture" 'const fs=require("fs"); const f=process.env.PASSKEY_FIXTURE; const d=JSON.parse(fs.readFileSync(f,"utf8")); d.deploymentEvidence[0].deployedCommit="b".repeat(40); fs.writeFileSync(f, JSON.stringify(d));'
expect_failure "placeholder deployed commit evidence" "deployedCommit must not be a placeholder git commit" run_audit "$fixture" --require-ready

write_blocked_fixture "$fixture"
mutate_json "$fixture" "$ready_json_mutator"
mutate_json "$fixture" 'const fs=require("fs"); const f=process.env.PASSKEY_FIXTURE; const d=JSON.parse(fs.readFileSync(f,"utf8")); d.deploymentEvidence[0].deploymentId="TODO_PRODUCTION_DEPLOYMENT_ID"; fs.writeFileSync(f, JSON.stringify(d));'
expect_failure "placeholder deployment id evidence" "deploymentId must not be a placeholder deployment id" run_audit "$fixture" --require-ready

write_blocked_fixture "$fixture"
mutate_json "$fixture" "$ready_json_mutator"
mutate_json "$fixture" 'const fs=require("fs"); const f=process.env.PASSKEY_FIXTURE; const d=JSON.parse(fs.readFileSync(f,"utf8")); d.deploymentEvidence[0].deploymentId="sample-deployment"; fs.writeFileSync(f, JSON.stringify(d));'
expect_failure "sample deployment id evidence" "deploymentId must not be a placeholder deployment id" run_audit "$fixture" --require-ready

write_blocked_fixture "$fixture"
mutate_json "$fixture" "$ready_json_mutator"
mutate_json "$fixture" 'const fs=require("fs"); const f=process.env.PASSKEY_FIXTURE; const d=JSON.parse(fs.readFileSync(f,"utf8")); d.deploymentEvidence[0].operator="TODO_RELEASE_OPERATOR"; fs.writeFileSync(f, JSON.stringify(d));'
expect_failure "placeholder operator evidence" "operator must not be a placeholder operator" run_audit "$fixture" --require-ready

write_blocked_fixture "$fixture"
mutate_json "$fixture" "$ready_json_mutator"
mutate_json "$fixture" 'const fs=require("fs"); const f=process.env.PASSKEY_FIXTURE; const d=JSON.parse(fs.readFileSync(f,"utf8")); d.deploymentEvidence[0].operator="dummy operator"; fs.writeFileSync(f, JSON.stringify(d));'
expect_failure "dummy operator evidence" "operator must not be a placeholder operator" run_audit "$fixture" --require-ready

write_blocked_fixture "$fixture"
mutate_json "$fixture" "$ready_json_mutator"
mutate_json "$fixture" 'const fs=require("fs"); const f=process.env.PASSKEY_FIXTURE; const d=JSON.parse(fs.readFileSync(f,"utf8")); d.deploymentEvidence[0].operator="release\noperator"; fs.writeFileSync(f, JSON.stringify(d));'
expect_failure "multi-line operator evidence" "operator must be a single-line public value" run_audit "$fixture" --require-ready

write_blocked_fixture "$fixture"
mutate_json "$fixture" "$ready_json_mutator"
mutate_json "$fixture" 'const fs=require("fs"); const f=process.env.PASSKEY_FIXTURE; const d=JSON.parse(fs.readFileSync(f,"utf8")); d.deploymentEvidence[0].operator="ghp_1234567890abcdefghijklmnop"; fs.writeFileSync(f, JSON.stringify(d));'
expect_failure "secret-like operator evidence" "operator must not contain secret-like token" run_audit "$fixture" --require-ready

write_blocked_fixture "$fixture"
mutate_json "$fixture" "$ready_json_mutator"
mutate_json "$fixture" 'const fs=require("fs"); const f=process.env.PASSKEY_FIXTURE; const d=JSON.parse(fs.readFileSync(f,"utf8")); d.deploymentEvidence[0].region="us-east-1"; fs.writeFileSync(f, JSON.stringify(d));'
expect_failure "unsupported deployment evidence field" "deploymentEvidence[0].region is not supported in public deployment evidence" run_audit "$fixture" --require-ready

write_blocked_fixture "$fixture"
mutate_json "$fixture" "$ready_json_mutator"
mutate_json "$fixture" 'const fs=require("fs"); const f=process.env.PASSKEY_FIXTURE; const d=JSON.parse(fs.readFileSync(f,"utf8")); const duplicate={...d.deploymentEvidence[0], imageDigest:"sha256:"+"fedcba9876543210".repeat(4), smokePassedAt:"2026-06-26T01:10:00Z"}; d.deploymentEvidence.push(duplicate); fs.writeFileSync(f, JSON.stringify(d));'
expect_failure "duplicate deployment id evidence" "duplicate deployment evidence id: render-passkey-prod-001" run_audit "$fixture" --require-ready

write_blocked_fixture "$fixture"
mutate_json "$fixture" "$ready_json_mutator"
mutate_json "$fixture" 'const fs=require("fs"); const f=process.env.PASSKEY_FIXTURE; const d=JSON.parse(fs.readFileSync(f,"utf8")); d.deploymentEvidence[0].smokePassedAt="2026-06-26T01:05:00+04:00"; fs.writeFileSync(f, JSON.stringify(d));'
expect_failure "bad smoke timestamp evidence" "smokePassedAt must be an ISO-8601 UTC second timestamp" run_audit "$fixture" --require-ready

write_blocked_fixture "$fixture"
mutate_json "$fixture" "$ready_json_mutator"
mutate_json "$fixture" 'const fs=require("fs"); const f=process.env.PASSKEY_FIXTURE; const d=JSON.parse(fs.readFileSync(f,"utf8")); d.deploymentEvidence[0].deployedAt="2026-02-30T01:00:00Z"; fs.writeFileSync(f, JSON.stringify(d));'
expect_failure "impossible deployment calendar timestamp" "deployedAt must be an ISO-8601 UTC second timestamp" run_audit "$fixture" --require-ready

write_blocked_fixture "$fixture"
mutate_json "$fixture" "$ready_json_mutator"
mutate_json "$fixture" 'const fs=require("fs"); const f=process.env.PASSKEY_FIXTURE; const d=JSON.parse(fs.readFileSync(f,"utf8")); d.deploymentEvidence[0].smokePassedAt="2025-02-29T01:05:00Z"; fs.writeFileSync(f, JSON.stringify(d));'
expect_failure "non-leap-day smoke timestamp" "smokePassedAt must be an ISO-8601 UTC second timestamp" run_audit "$fixture" --require-ready

write_blocked_fixture "$fixture"
mutate_json "$fixture" "$ready_json_mutator"
mutate_json "$fixture" 'const fs=require("fs"); const f=process.env.PASSKEY_FIXTURE; const d=JSON.parse(fs.readFileSync(f,"utf8")); d.deploymentEvidence[0].smokePassedAt="2026-06-26T24:00:00Z"; fs.writeFileSync(f, JSON.stringify(d));'
expect_failure "hour-24 smoke timestamp" "smokePassedAt must be an ISO-8601 UTC second timestamp" run_audit "$fixture" --require-ready

write_blocked_fixture "$fixture"
mutate_json "$fixture" "$ready_json_mutator"
mutate_json "$fixture" 'const fs=require("fs"); const f=process.env.PASSKEY_FIXTURE; const d=JSON.parse(fs.readFileSync(f,"utf8")); d.deploymentEvidence[0].deployedAt="2024-02-29T01:00:00Z"; d.deploymentEvidence[0].smokePassedAt="2024-02-29T01:05:00Z"; fs.writeFileSync(f, JSON.stringify(d));'
expect_failure "historical leap-day smoke is stale ready evidence" "smokePassedAt must be no more than 24 hours old for ready evidence" run_audit "$fixture" --require-ready

write_blocked_fixture "$fixture"
mutate_json "$fixture" "$ready_json_mutator"
mutate_json "$fixture" 'const fs=require("fs"); const f=process.env.PASSKEY_FIXTURE; const d=JSON.parse(fs.readFileSync(f,"utf8")); d.deploymentEvidence[0].deployedAt="2999-01-01T00:00:00Z"; d.deploymentEvidence[0].smokePassedAt="2999-01-01T00:05:00Z"; fs.writeFileSync(f, JSON.stringify(d));'
expect_failure "future deployment timestamp evidence" "deployedAt must not be in the future" run_audit "$fixture" --require-ready

write_blocked_fixture "$fixture"
mutate_json "$fixture" "$ready_json_mutator"
mutate_json "$fixture" 'const fs=require("fs"); const f=process.env.PASSKEY_FIXTURE; const d=JSON.parse(fs.readFileSync(f,"utf8")); d.deploymentEvidence[0].smokePassedAt="2999-01-01T00:05:00Z"; fs.writeFileSync(f, JSON.stringify(d));'
expect_failure "future smoke timestamp evidence" "smokePassedAt must not be in the future" run_audit "$fixture" --require-ready

write_blocked_fixture "$fixture"
mutate_json "$fixture" "$ready_json_mutator"
mutate_json "$fixture" 'const fs=require("fs"); const f=process.env.PASSKEY_FIXTURE; const d=JSON.parse(fs.readFileSync(f,"utf8")); d.deploymentEvidence[0].smokePassedAt="2026-06-26T00:59:59Z"; fs.writeFileSync(f, JSON.stringify(d));'
expect_failure "smoke before deployment evidence" "smokePassedAt must be at or after deployedAt" run_audit "$fixture" --require-ready

write_blocked_fixture "$fixture"
mutate_json "$fixture" "$ready_json_mutator"
mutate_json "$fixture" 'const fs=require("fs"); const f=process.env.PASSKEY_FIXTURE; const d=JSON.parse(fs.readFileSync(f,"utf8")); d.deploymentEvidence[0].smokeCommand="curl https://backup.fearlesswallet.io"; fs.writeFileSync(f, JSON.stringify(d));'
expect_failure "wrong production smoke command evidence" "smokeCommand must be the production route smoke command" run_audit "$fixture" --require-ready

write_blocked_fixture "$fixture"
mutate_json "$fixture" "$ready_json_mutator"
mutate_json "$fixture" 'const fs=require("fs"); const f=process.env.PASSKEY_FIXTURE; const d=JSON.parse(fs.readFileSync(f,"utf8")); d.deploymentEvidence[0].healthUrl="https://backup.fearlesswallet.io/status"; fs.writeFileSync(f, JSON.stringify(d));'
expect_failure "wrong health URL evidence" "healthUrl must be https://backup.fearlesswallet.io/api/passkey-backup/v1/health" run_audit "$fixture" --require-ready

write_blocked_fixture "$fixture"
mutate_json "$fixture" "$ready_json_mutator"
mutate_json "$fixture" 'const fs=require("fs"); const f=process.env.PASSKEY_FIXTURE; const d=JSON.parse(fs.readFileSync(f,"utf8")); d.deploymentEvidence[0].healthResponse.commit="c".repeat(40); fs.writeFileSync(f, JSON.stringify(d));'
expect_failure "unsupported health response evidence field" "deploymentEvidence[0].healthResponse.commit is not supported in public deployment evidence" run_audit "$fixture" --require-ready

write_blocked_fixture "$fixture"
mutate_json "$fixture" "$ready_json_mutator"
mutate_json "$fixture" 'const fs=require("fs"); const f=process.env.PASSKEY_FIXTURE; const d=JSON.parse(fs.readFileSync(f,"utf8")); delete d.deploymentEvidence[0].webauthnAllowedOrigins; fs.writeFileSync(f, JSON.stringify(d));'
expect_failure "missing WebAuthn origin evidence" "webauthnAllowedOrigins must be an array" run_audit "$fixture" --require-ready

write_blocked_fixture "$fixture"
mutate_json "$fixture" "$ready_json_mutator"
mutate_json "$fixture" 'const fs=require("fs"); const f=process.env.PASSKEY_FIXTURE; const d=JSON.parse(fs.readFileSync(f,"utf8")); d.deploymentEvidence[0].webauthnAllowedOrigins[2] += "="; fs.writeFileSync(f, JSON.stringify(d));'
expect_failure "padded Android WebAuthn origin evidence" "Android origin must contain an unpadded base64url SHA-256 release certificate digest" run_audit "$fixture" --require-ready

write_blocked_fixture "$fixture"
mutate_json "$fixture" "$ready_json_mutator"
mutate_json "$fixture" 'const fs=require("fs"); const f=process.env.PASSKEY_FIXTURE; const d=JSON.parse(fs.readFileSync(f,"utf8")); d.deploymentEvidence[0].webauthnAllowedOrigins.pop(); fs.writeFileSync(f, JSON.stringify(d));'
expect_failure "missing Android WebAuthn origin evidence" "must contain two HTTPS origins and one Android release origin" run_audit "$fixture" --require-ready

write_blocked_fixture "$fixture"
mutate_json "$fixture" "$ready_json_mutator"
mutate_json "$fixture" 'const fs=require("fs"); const f=process.env.PASSKEY_FIXTURE; const d=JSON.parse(fs.readFileSync(f,"utf8")); d.deploymentEvidence[0].webauthnAllowedOrigins[2] = d.deploymentEvidence[0].webauthnAllowedOrigins[0]; fs.writeFileSync(f, JSON.stringify(d));'
expect_failure "duplicate WebAuthn origin evidence" "webauthnAllowedOrigins must not contain duplicates" run_audit "$fixture" --require-ready

write_blocked_fixture "$fixture"
mutate_json "$fixture" "$ready_json_mutator"
mutate_json "$fixture" 'const fs=require("fs"); const f=process.env.PASSKEY_FIXTURE; const d=JSON.parse(fs.readFileSync(f,"utf8")); d.deploymentEvidence[0].requestAccessPolicy.mode="passive-introspection"; fs.writeFileSync(f, JSON.stringify(d));'
expect_failure "non-consuming request access policy" "requestAccessPolicy.mode must be atomic-one-time-consume" run_audit "$fixture" --require-ready

write_blocked_fixture "$fixture"
mutate_json "$fixture" "$ready_json_mutator"
mutate_json "$fixture" 'const fs=require("fs"); const f=process.env.PASSKEY_FIXTURE; const d=JSON.parse(fs.readFileSync(f,"utf8")); d.deploymentEvidence[0].requestAccessPolicy.stableCrossPlatformWalletSubject=false; fs.writeFileSync(f, JSON.stringify(d));'
expect_failure "platform-local request subject" "requestAccessPolicy.stableCrossPlatformWalletSubject must be true" run_audit "$fixture" --require-ready

for lifecycle_field in credentialLifecycleSmokePassed ownerTombstonePersistencePassed crossSubjectTakeoverDenied sameOwnerReregistrationPassed cloudDeleteRevokesServerFirst listExcludesVerificationMaterial; do
  write_blocked_fixture "$fixture"
  mutate_json "$fixture" "$ready_json_mutator"
  PASSKEY_LIFECYCLE_FIELD="$lifecycle_field" mutate_json "$fixture" 'const fs=require("fs"); const f=process.env.PASSKEY_FIXTURE; const d=JSON.parse(fs.readFileSync(f,"utf8")); d.deploymentEvidence[0].requestAccessPolicy[process.env.PASSKEY_LIFECYCLE_FIELD]=false; fs.writeFileSync(f, JSON.stringify(d));'
  expect_failure "missing lifecycle evidence: $lifecycle_field" "requestAccessPolicy.$lifecycle_field must be true" run_audit "$fixture" --require-ready
done

write_blocked_fixture "$fixture"
mutate_json "$fixture" "$ready_json_mutator"
mutate_json "$fixture" 'const fs=require("fs"); const f=process.env.PASSKEY_FIXTURE; const d=JSON.parse(fs.readFileSync(f,"utf8")); d.deploymentEvidence[0].trustedProxyPolicy.directPeerAllowlistConfigured=false; fs.writeFileSync(f, JSON.stringify(d));'
expect_failure "missing trusted proxy peer allowlist" "trustedProxyPolicy.directPeerAllowlistConfigured must be true" run_audit "$fixture" --require-ready

write_blocked_fixture "$fixture"
mutate_json "$fixture" "$ready_json_mutator"
mutate_json "$fixture" 'const fs=require("fs"); const f=process.env.PASSKEY_FIXTURE; const d=JSON.parse(fs.readFileSync(f,"utf8")); d.deploymentEvidence[0].platformProvisioning.iosCloudKitProductionSchema=false; fs.writeFileSync(f, JSON.stringify(d));'
expect_failure "incomplete platform provisioning evidence" "platformProvisioning.iosCloudKitProductionSchema must be true" run_audit "$fixture" --require-ready

write_blocked_fixture "$fixture"
mutate_json "$fixture" "$ready_json_mutator"
mutate_json "$fixture" 'const fs=require("fs"); const f=process.env.PASSKEY_FIXTURE; const d=JSON.parse(fs.readFileSync(f,"utf8")); d.deploymentEvidence[0].platformProvisioning.iosManualApprovalTicket="APPROVED-1"; fs.writeFileSync(f, JSON.stringify(d));'
expect_failure "unsupported platform provisioning evidence field" "deploymentEvidence[0].platformProvisioning.iosManualApprovalTicket is not supported in public deployment evidence" run_audit "$fixture" --require-ready

write_blocked_fixture "$fixture"
mutate_json "$fixture" "$ready_json_mutator"
mutate_json "$fixture" 'const fs=require("fs"); const f=process.env.PASSKEY_FIXTURE; const d=JSON.parse(fs.readFileSync(f,"utf8")); d.deploymentEvidence[0].privateKey="do-not-commit"; fs.writeFileSync(f, JSON.stringify(d));'
expect_failure "secret-like deployment evidence key" "privateKey must not be included in public deployment evidence" run_audit "$fixture" --require-ready

write_blocked_fixture "$fixture"
mutate_json "$fixture" "$ready_json_mutator"
mutate_json "$fixture" 'const fs=require("fs"); const f=process.env.PASSKEY_FIXTURE; const d=JSON.parse(fs.readFileSync(f,"utf8")); d.deploymentEvidence[0].deploymentId="render-ghp_1234567890abcdefghijklmnop"; fs.writeFileSync(f, JSON.stringify(d));'
expect_failure "secret-like deployment evidence value" "deploymentId must not contain secret-like token" run_audit "$fixture" --require-ready

write_blocked_fixture "$fixture"
mutate_json "$fixture" "$ready_json_mutator"
mutate_json "$fixture" 'const fs=require("fs"); const f=process.env.PASSKEY_FIXTURE; const d=JSON.parse(fs.readFileSync(f,"utf8")); d.deploymentEvidence[0].healthResponse.clientDataJSON="secret-client-data"; fs.writeFileSync(f, JSON.stringify(d));'
expect_failure "nested credential evidence leak" "clientDataJSON must not be included in public deployment evidence" run_audit "$fixture" --require-ready

echo "[passkey-deployment-evidence-test] all tests passed"
