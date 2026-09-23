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

FAKE_GH_BIN="$FIXTURE_DIR/fake-gh"
FAKE_GH_LOG="$FIXTURE_DIR/fake-gh-calls.log"
NON_EXECUTABLE_GH_BIN="$FIXTURE_DIR/non-executable-gh"
SYMLINK_GH_BIN="$FIXTURE_DIR/symlink-gh"
printf '%s\n' '#!/usr/bin/env bash' 'exit 1' >"$NON_EXECUTABLE_GH_BIN"
chmod 600 "$NON_EXECUTABLE_GH_BIN"

cat >"$FAKE_GH_BIN" <<'FAKE_GH'
#!/usr/bin/env bash
set -euo pipefail

: "${PASSKEY_FAKE_GH_LOG:?}"
{
  separator=""
  for argument in "$@"; do
    printf '%s%s' "$separator" "$argument"
    separator=$'\t'
  done
  printf '\n'
} >>"$PASSKEY_FAKE_GH_LOG"

scenario="${PASSKEY_FAKE_GH_SCENARIO:-valid}"
[[ "${GH_HOST:-}" == "github.com" ]]
expected_repository="soramitsu/fearless-release-readiness"
expected_workflow=".github/workflows/passkey-image-publish.yml"
expected_commit="0123456789abcdef0123456789abcdef01234567"
expected_run_url="https://github.com/soramitsu/fearless-release-readiness/actions/runs/123456789"
expected_bundle='{"mediaType":"application/vnd.dev.sigstore.bundle.v0.3+json","verificationMaterial":{"certificate":"fixture"},"dsseEnvelope":{"payload":"fixture"}}'
expected_predicate_type="https://slsa.dev/provenance/v1"

if [[ "${1:-}" == "api" ]]; then
  [[ "$#" -eq 10 ]]
  [[ "$2" == "--hostname" && "$3" == "github.com" ]]
  [[ "$4" == "--method" && "$5" == "GET" ]]
  [[ "$6" == "-H" && "$7" == "Accept: application/vnd.github+json" ]]
  [[ "$8" == "-H" && "$9" == "X-GitHub-Api-Version: 2026-03-10" ]]
  endpoint="${10}"
fi

if [[ "${1:-}" == "api" ]]; then
  endpoint="${!#}"
  case "$endpoint" in
    repos/soramitsu/fearless-release-readiness/actions/runs/123456789)
      run_id=123456789
      run_url="$expected_run_url"
      repository="$expected_repository"
      repository_id=424242
      head_repository="$expected_repository"
      workflow="$expected_workflow"
      event="workflow_dispatch"
      branch="main"
      status="completed"
      conclusion="success"
      head_sha="$expected_commit"
      case "$scenario" in
        run-repository-drift) repository="attacker/fearless-release-readiness" ;;
        run-repository-id-drift) repository_id=0 ;;
        run-head-repository-drift) head_repository="attacker/fearless-release-readiness" ;;
        run-workflow-drift) workflow=".github/workflows/unreviewed.yml" ;;
        run-event-drift) event="push" ;;
        run-branch-drift) branch="develop" ;;
        run-status-drift) status="in_progress" ;;
        run-conclusion-drift) conclusion="failure" ;;
        run-id-drift) run_id=123456788 ;;
        run-url-drift) run_url="https://github.com/soramitsu/fearless-release-readiness/actions/runs/123456788" ;;
        run-head-sha-drift) head_sha="fedcba9876543210fedcba9876543210fedcba98" ;;
      esac
      printf '{"id":%s,"html_url":"%s","repository":{"id":%s,"full_name":"%s"},"head_repository":{"full_name":"%s"},"path":"%s","event":"%s","head_branch":"%s","status":"%s","conclusion":"%s","head_sha":"%s"}\n' \
        "$run_id" "$run_url" "$repository_id" "$repository" "$head_repository" "$workflow" \
        "$event" "$branch" "$status" "$conclusion" "$head_sha"
      ;;
    repos/soramitsu/fearless-release-readiness/attestations/sha256:*\?per_page=2\&predicate_type=provenance)
      digest="${endpoint#repos/soramitsu/fearless-release-readiness/attestations/}"
      digest="${digest%%\?*}"
      case "$digest" in
        sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef)
          expected_attestation_id=987654321
          ;;
        sha256:fedcba9876543210fedcba9876543210fedcba9876543210fedcba9876543210)
          expected_attestation_id=987654322
          ;;
        *)
          echo "unexpected attestation subject digest: $digest" >&2
          exit 92
          ;;
      esac
      case "$scenario" in
        missing-attestation)
          printf '%s\n' '{"attestations":[]}'
          exit 0
          ;;
        malformed-attestation-collection) printf '%s\n' '"not-an-attestation-collection"'; exit 0 ;;
        missing-attestations-array) printf '%s\n' '{}'; exit 0 ;;
        multiple-attestations)
          printf '{"attestations":[{"repository_id":424242,"bundle_url":"https://tmaproduction.blob.core.windows.net/attestations/424242/2026/08/14/%s.json.sn?sig=fixture"},{"repository_id":424242,"bundle_url":"https://tmaproduction.blob.core.windows.net/attestations/424242/2026/08/14/999999999.json.sn?sig=fixture"}]}\n' "$expected_attestation_id"
          exit 0
          ;;
        attestation-id-drift) expected_attestation_id=987654399 ;;
        attestation-repository-drift) attestation_repository_id=31337 ;;
        malformed-attestation-bundle-url)
          printf '%s\n' '{"attestations":[{"repository_id":424242,"bundle_url":"https://attacker.invalid/not-an-attestation"}]}'
          exit 0
          ;;
      esac
      printf '{"attestations":[{"repository_id":%s,"bundle_url":"https://tmaproduction.blob.core.windows.net/attestations/424242/2026/08/14/%s.json.sn?sig=fixture","initiator":"user","bundle":null}]}\n' \
        "${attestation_repository_id:-424242}" "$expected_attestation_id"
      ;;
    *)
      echo "unexpected gh api endpoint: $endpoint" >&2
      exit 92
      ;;
  esac
  exit 0
fi

if [[ "${1:-}" == "attestation" && "${2:-}" == "download" ]]; then
  [[ "$#" -eq 11 ]]
  [[ "$3" =~ ^oci://ghcr\.io/soramitsu/fearless-passkey-backup@sha256:[0-9a-f]{64}$ ]]
  [[ "$4" == "--repo" && "$5" == "$expected_repository" ]]
  [[ "$6" == "--predicate-type" && "$7" == "$expected_predicate_type" ]]
  [[ "$8" == "--limit" && "$9" == "2" ]]
  [[ "${10}" == "--hostname" && "${11}" == "github.com" ]]
  if [[ "$scenario" == "download-failure" ]]; then
    echo "fixture attestation download failed" >&2
    exit 93
  fi
  if [[ "$scenario" != "missing-downloaded-bundle" ]]; then
    bundle_name="${3##*@}.jsonl"
    if [[ "$scenario" == "malformed-downloaded-bundle" ]]; then
      printf '%s\n' '{}' >"$bundle_name"
    elif [[ "$scenario" == "multiple-downloaded-bundles" ]]; then
      printf '%s\n%s\n' "$expected_bundle" "$expected_bundle" >"$bundle_name"
    else
      printf '%s\n' "$expected_bundle" >"$bundle_name"
    fi
    if [[ "$scenario" == "extra-downloaded-bundle" ]]; then
      printf '%s\n' "$expected_bundle" >unexpected.jsonl
    fi
  fi
  exit 0
fi

if [[ "${1:-}" == "attestation" && "${2:-}" == "verify" ]]; then
  [[ "$#" -eq 20 ]]
  [[ "$3" =~ ^oci://ghcr\.io/soramitsu/fearless-passkey-backup@sha256:[0-9a-f]{64}$ ]]
  [[ "$4" == "--bundle" && -f "$5" && ! -L "$5" ]]
  [[ "$(<"$5")" == "$expected_bundle" ]]
  [[ "$6" == "--repo" && "$7" == "$expected_repository" ]]
  [[ "$8" == "--signer-workflow" && "$9" == "$expected_repository/$expected_workflow" ]]
  [[ "${10}" == "--source-digest" && "${11}" == "$expected_commit" ]]
  [[ "${12}" == "--source-ref" && "${13}" == "refs/heads/main" ]]
  [[ "${14}" == "--predicate-type" && "${15}" == "$expected_predicate_type" ]]
  [[ "${16}" == "--deny-self-hosted-runners" ]]
  [[ "${17}" == "--hostname" && "${18}" == "github.com" ]]
  [[ "${19}" == "--format" && "${20}" == "json" ]]
  if [[ "$scenario" == "verify-failure" ]]; then
    echo "fixture attestation verification failed" >&2
    exit 93
  fi
  if [[ "$scenario" == "verify-invalid-json" ]]; then
    printf '%s\n' 'not-json'
    exit 0
  fi
  if [[ "$scenario" == "verify-multiple-results" ]]; then
    printf '%s\n' '[{},{}]'
    exit 0
  fi
  printf '%s\n' '[{"attestation":{},"verificationResult":{}}]'
  exit 0
fi

echo "unexpected fake gh invocation" >&2
exit 94
FAKE_GH
chmod 700 "$FAKE_GH_BIN"
ln -s "$FAKE_GH_BIN" "$SYMLINK_GH_BIN"
: >"$FAKE_GH_LOG"

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
  "imageRepository": "ghcr.io/soramitsu/fearless-passkey-backup",
  "imagePublicationWorkflow": ".github/workflows/passkey-image-publish.yml",
  "imagePublicationCommand": "gh workflow run passkey-image-publish.yml --repo soramitsu/fearless-release-readiness --ref main -f source_commit=<protected-main-commit>",
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
  "smokeCommand": "PASSKEY_BACKUP_BASE_URL=https://backup.fearlesswallet.io PASSKEY_BACKUP_SMOKE_GRANT_HELPER=/run/secrets/passkey-smoke-grant-helper PASSKEY_BACKUP_SMOKE_TIMEOUT_MS=10000 npm run smoke:production",
  "requiredCommands": [
    "npm run lint:syntax",
    "npm test",
    "npm run test:deployment-evidence-template",
    "npm run generate:deployment-evidence-template -- --output build/reports/production-deployment-evidence-template.json",
    "npm run test:deployment-evidence-audit",
    "npm run audit:deployment-evidence",
    "gh workflow run passkey-image-publish.yml --repo soramitsu/fearless-release-readiness --ref main -f source_commit=<protected-main-commit>",
    "PASSKEY_BACKUP_LIVE_HEALTH=1 PASSKEY_BACKUP_HEALTH_TIMEOUT_SECONDS=10 bash ../../scripts/audit-passkey-backup-prerequisites.sh",
    "PASSKEY_BACKUP_BASE_URL=https://backup.fearlesswallet.io PASSKEY_BACKUP_SMOKE_GRANT_HELPER=/run/secrets/passkey-smoke-grant-helper PASSKEY_BACKUP_SMOKE_TIMEOUT_MS=10000 npm run smoke:production",
    "npm run audit:deployment-evidence -- --require-ready"
  ],
  "requiredEvidenceFields": [
    "imageRepository",
    "imageDigest",
    "imagePublicationRunUrl",
    "imageProvenanceAttestationUrl",
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
  local gh_bin="${PASSKEY_DEPLOYMENT_GH_BIN-$FAKE_GH_BIN}"
  PASSKEY_DEPLOYMENT_EXPECTED_COMMIT="$expected_commit" \
  PASSKEY_DEPLOYMENT_GH_BIN="$gh_bin" \
  PASSKEY_FAKE_GH_LOG="$FAKE_GH_LOG" \
  PASSKEY_FAKE_GH_SCENARIO="${PASSKEY_FAKE_GH_SCENARIO:-valid}" \
    bash "$AUDIT_SCRIPT" --evidence "$1" "${@:2}"
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

reset_fake_gh_calls() {
  : >"$FAKE_GH_LOG"
}

expect_no_fake_gh_calls() {
  local name="$1"
  if [[ -s "$FAKE_GH_LOG" ]]; then
    echo "$(<"$FAKE_GH_LOG")" >&2
    echo "[passkey-deployment-evidence-test][error] $name unexpectedly invoked gh" >&2
    exit 1
  fi
}

expect_fake_gh_call_count() {
  local name="$1"
  local expected="$2"
  local actual=0
  while IFS= read -r _call; do
    actual=$((actual + 1))
  done <"$FAKE_GH_LOG"
  if [[ "$actual" -ne "$expected" ]]; then
    echo "$(<"$FAKE_GH_LOG")" >&2
    echo "[passkey-deployment-evidence-test][error] $name expected $expected gh calls, got $actual" >&2
    exit 1
  fi
}

expect_fake_gh_call() {
  local name="$1"
  local expected="$2"
  local calls
  calls="$(<"$FAKE_GH_LOG")"
  if [[ "$calls" != *"$expected"* ]]; then
    echo "$calls" >&2
    echo "[passkey-deployment-evidence-test][error] $name missing gh call marker: $expected" >&2
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
  imageRepository: "ghcr.io/soramitsu/fearless-passkey-backup",
  imageDigest: "sha256:" + "0123456789abcdef".repeat(4),
  imagePublicationRunUrl: "https://github.com/soramitsu/fearless-release-readiness/actions/runs/123456789",
  imageProvenanceAttestationUrl: "https://github.com/soramitsu/fearless-release-readiness/attestations/987654321",
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
reset_fake_gh_calls
expect_success "blocked evidence without --require-ready" run_audit "$fixture"
expect_no_fake_gh_calls "blocked evidence makes zero GitHub calls"
reset_fake_gh_calls
expect_failure "blocked evidence with --require-ready" "--require-ready requires status ready" run_audit "$fixture" --require-ready
expect_no_fake_gh_calls "blocked --require-ready evidence makes zero GitHub calls"

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
expect_failure "missing deployment evidence template command" "requiredCommands must include lint, tests, protected-main image publication, deployment evidence audits, template generation, ready audit, live health command, and route smoke command" run_audit "$fixture"

write_blocked_fixture "$fixture"
mutate_json "$fixture" 'const fs=require("fs"); const f=process.env.PASSKEY_FIXTURE; const d=JSON.parse(fs.readFileSync(f,"utf8")); d.requiredCommands.push("npm run test:deployment-evidence-audit"); fs.writeFileSync(f, JSON.stringify(d));'
expect_failure "duplicate deployment evidence required command" "duplicate deployment evidence required command" run_audit "$fixture"

write_blocked_fixture "$fixture"
mutate_json "$fixture" 'const fs=require("fs"); const f=process.env.PASSKEY_FIXTURE; const d=JSON.parse(fs.readFileSync(f,"utf8")); d.requiredCommands.push("curl https://evil.example/deploy"); fs.writeFileSync(f, JSON.stringify(d));'
expect_failure "unsupported deployment evidence required command" "unsupported deployment evidence required command: curl https://evil.example/deploy" run_audit "$fixture"

write_blocked_fixture "$fixture"
mutate_json "$fixture" 'const fs=require("fs"); const f=process.env.PASSKEY_FIXTURE; const d=JSON.parse(fs.readFileSync(f,"utf8")); d.requiredCommands=d.requiredCommands.filter((command)=>command!=="npm test"); fs.writeFileSync(f, JSON.stringify(d));'
expect_failure "missing deployment npm test command" "requiredCommands must include lint, tests, protected-main image publication, deployment evidence audits, template generation, ready audit, live health command, and route smoke command" run_audit "$fixture"

write_blocked_fixture "$fixture"
mutate_json "$fixture" 'const fs=require("fs"); const f=process.env.PASSKEY_FIXTURE; const d=JSON.parse(fs.readFileSync(f,"utf8")); d.requiredCommands=d.requiredCommands.filter((command)=>command!==d.imagePublicationCommand); fs.writeFileSync(f, JSON.stringify(d));'
expect_failure "missing protected-main image publication command" "requiredCommands must include lint, tests, protected-main image publication, deployment evidence audits, template generation, ready audit, live health command, and route smoke command" run_audit "$fixture"

for required_publication_field in imageRepository imagePublicationRunUrl imageProvenanceAttestationUrl; do
  write_blocked_fixture "$fixture"
  PASSKEY_PUBLICATION_FIELD="$required_publication_field" mutate_json "$fixture" 'const fs=require("fs"); const f=process.env.PASSKEY_FIXTURE; const d=JSON.parse(fs.readFileSync(f,"utf8")); d.requiredEvidenceFields=d.requiredEvidenceFields.filter((field)=>field!==process.env.PASSKEY_PUBLICATION_FIELD); fs.writeFileSync(f, JSON.stringify(d));'
  expect_failure "missing required publication evidence field: $required_publication_field" "requiredEvidenceFields must include all release proof fields" run_audit "$fixture"
done

write_blocked_fixture "$fixture"
mutate_json "$fixture" 'const fs=require("fs"); const f=process.env.PASSKEY_FIXTURE; const d=JSON.parse(fs.readFileSync(f,"utf8")); d.imageRepository="ghcr.io/attacker/fearless-passkey-backup"; fs.writeFileSync(f, JSON.stringify(d));'
expect_failure "wrong immutable image repository" "imageRepository must be ghcr.io/soramitsu/fearless-passkey-backup" run_audit "$fixture"

write_blocked_fixture "$fixture"
mutate_json "$fixture" 'const fs=require("fs"); const f=process.env.PASSKEY_FIXTURE; const d=JSON.parse(fs.readFileSync(f,"utf8")); d.imagePublicationWorkflow=".github/workflows/unreviewed.yml"; fs.writeFileSync(f, JSON.stringify(d));'
expect_failure "wrong image publication workflow" "imagePublicationWorkflow must be .github/workflows/passkey-image-publish.yml" run_audit "$fixture"

write_blocked_fixture "$fixture"
mutate_json "$fixture" 'const fs=require("fs"); const f=process.env.PASSKEY_FIXTURE; const d=JSON.parse(fs.readFileSync(f,"utf8")); d.imagePublicationCommand="docker build -t passkey-backup-challenge-service:release ."; fs.writeFileSync(f, JSON.stringify(d));'
expect_failure "mutable local image publication command" "imagePublicationCommand must dispatch the protected-main image publication workflow" run_audit "$fixture"

write_blocked_fixture "$fixture"
mutate_json "$fixture" 'const fs=require("fs"); const f=process.env.PASSKEY_FIXTURE; const d=JSON.parse(fs.readFileSync(f,"utf8")); d.dockerBuildCommand="docker build -t passkey-backup-challenge-service:release ."; fs.writeFileSync(f, JSON.stringify(d));'
expect_failure "deprecated mutable Docker build contract" "deployment evidence.dockerBuildCommand is not supported in public deployment evidence" run_audit "$fixture"

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
reset_fake_gh_calls
GH_HOST=attacker.invalid
export GH_HOST
expect_success "ready evidence authenticates exact GitHub Actions run and attestation bundle" run_audit "$fixture" --require-ready
unset GH_HOST
expect_fake_gh_call_count "ready evidence exact provenance call count" 4
expect_fake_gh_call "ready evidence queries exact run on github.com" $'api\t--hostname\tgithub.com\t--method\tGET\t-H\tAccept: application/vnd.github+json\t-H\tX-GitHub-Api-Version: 2026-03-10\trepos/soramitsu/fearless-release-readiness/actions/runs/123456789'
expect_fake_gh_call "ready evidence lists provenance by exact subject digest" $'api\t--hostname\tgithub.com\t--method\tGET\t-H\tAccept: application/vnd.github+json\t-H\tX-GitHub-Api-Version: 2026-03-10\trepos/soramitsu/fearless-release-readiness/attestations/sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef?per_page=2&predicate_type=provenance'
expect_fake_gh_call "ready evidence downloads the uniquely digest-listed attestation" $'attestation\tdownload\toci://ghcr.io/soramitsu/fearless-passkey-backup@sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef\t--repo\tsoramitsu/fearless-release-readiness\t--predicate-type\thttps://slsa.dev/provenance/v1\t--limit\t2\t--hostname\tgithub.com'
expect_fake_gh_call "ready evidence verifies exact OCI subject with exact signer and source" $'attestation\tverify\toci://ghcr.io/soramitsu/fearless-passkey-backup@sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef\t--bundle\t'
expect_fake_gh_call "ready evidence pins repository signer source digest source ref predicate hosted runner and host" $'--repo\tsoramitsu/fearless-release-readiness\t--signer-workflow\tsoramitsu/fearless-release-readiness/.github/workflows/passkey-image-publish.yml\t--source-digest\t0123456789abcdef0123456789abcdef01234567\t--source-ref\trefs/heads/main\t--predicate-type\thttps://slsa.dev/provenance/v1\t--deny-self-hosted-runners\t--hostname\tgithub.com\t--format\tjson'

expect_failure "ready evidence rejects missing explicit gh binary" "PASSKEY_DEPLOYMENT_GH_BIN must be set to an absolute executable gh binary for ready evidence" \
  env -u PASSKEY_DEPLOYMENT_GH_BIN PASSKEY_DEPLOYMENT_EXPECTED_COMMIT="$FIXTURE_DEPLOYED_COMMIT" \
    bash "$AUDIT_SCRIPT" --evidence "$fixture" --require-ready

expect_failure "ready evidence rejects non-absolute gh binary" "PASSKEY_DEPLOYMENT_GH_BIN must be an absolute path for ready evidence" \
  env PASSKEY_DEPLOYMENT_GH_BIN=gh PASSKEY_DEPLOYMENT_EXPECTED_COMMIT="$FIXTURE_DEPLOYED_COMMIT" \
    bash "$AUDIT_SCRIPT" --evidence "$fixture" --require-ready

expect_failure "ready evidence rejects non-executable gh binary" "PASSKEY_DEPLOYMENT_GH_BIN must name an existing executable file" \
  env PASSKEY_DEPLOYMENT_GH_BIN="$NON_EXECUTABLE_GH_BIN" PASSKEY_DEPLOYMENT_EXPECTED_COMMIT="$FIXTURE_DEPLOYED_COMMIT" \
    bash "$AUDIT_SCRIPT" --evidence "$fixture" --require-ready

expect_failure "ready evidence rejects symlinked gh binary" "PASSKEY_DEPLOYMENT_GH_BIN must not be a symbolic link" \
  env PASSKEY_DEPLOYMENT_GH_BIN="$SYMLINK_GH_BIN" PASSKEY_DEPLOYMENT_EXPECTED_COMMIT="$FIXTURE_DEPLOYED_COMMIT" \
    bash "$AUDIT_SCRIPT" --evidence "$fixture" --require-ready

for run_drift_case in \
  'run-repository-drift|repository.full_name must be soramitsu/fearless-release-readiness' \
  'run-repository-id-drift|repository.id must be a positive integer' \
  'run-head-repository-drift|head_repository.full_name must be soramitsu/fearless-release-readiness' \
  'run-workflow-drift|path must be .github/workflows/passkey-image-publish.yml' \
  'run-event-drift|event must be workflow_dispatch' \
  'run-branch-drift|head_branch must be main' \
  'run-status-drift|status must be completed' \
  'run-conclusion-drift|conclusion must be success' \
  'run-id-drift|run id must exactly match the evidence URL id' \
  'run-url-drift|html_url must exactly match the evidence URL' \
  'run-head-sha-drift|head_sha must exactly match deployedCommit'; do
  IFS='|' read -r scenario expected_diagnostic <<<"$run_drift_case"
  reset_fake_gh_calls
  PASSKEY_FAKE_GH_SCENARIO="$scenario" expect_failure \
    "authenticated Actions run drift is rejected: $scenario" "$expected_diagnostic" \
    run_audit "$fixture" --require-ready
done

for attestation_case in \
  'missing-attestation|imageDigest must resolve to exactly one provenance attestation' \
  'malformed-attestation-collection|imageDigest attestation-list response must contain an attestations array' \
  'missing-attestations-array|imageDigest attestation-list response must contain an attestations array' \
  'multiple-attestations|imageDigest must resolve to exactly one provenance attestation' \
  'attestation-id-drift|imageProvenanceAttestationUrl id must exactly match the digest-listed bundle_url id' \
  'attestation-repository-drift|imageDigest provenance attestation repository_id must match the authenticated Actions repository' \
  'malformed-attestation-bundle-url|imageProvenanceAttestationUrl id must exactly match the digest-listed bundle_url id'; do
  IFS='|' read -r scenario expected_diagnostic <<<"$attestation_case"
  reset_fake_gh_calls
  PASSKEY_FAKE_GH_SCENARIO="$scenario" expect_failure \
    "missing malformed or incomplete exact attestation bundle is rejected: $scenario" "$expected_diagnostic" \
    run_audit "$fixture" --require-ready
done

for download_case in \
  'download-failure|gh attestation download failed: fixture attestation download failed' \
  'missing-downloaded-bundle|download must create exactly the digest-named bundle file' \
  'extra-downloaded-bundle|download must create exactly the digest-named bundle file' \
  'multiple-downloaded-bundles|download must contain exactly one Sigstore bundle' \
  'malformed-downloaded-bundle|download must contain a structurally valid Sigstore bundle'; do
  IFS='|' read -r scenario expected_diagnostic <<<"$download_case"
  reset_fake_gh_calls
  PASSKEY_FAKE_GH_SCENARIO="$scenario" expect_failure \
    "attestation download fails closed: $scenario" "$expected_diagnostic" \
    run_audit "$fixture" --require-ready
done

reset_fake_gh_calls
PASSKEY_FAKE_GH_SCENARIO=verify-failure expect_failure \
  "attestation verification failure is fail closed" "gh attestation verify failed: fixture attestation verification failed" \
  run_audit "$fixture" --require-ready

for verification_shape_case in \
  'verify-invalid-json|gh attestation verify response must be valid JSON' \
  'verify-multiple-results|verification must return exactly one verified provenance result'; do
  IFS='|' read -r scenario expected_diagnostic <<<"$verification_shape_case"
  reset_fake_gh_calls
  PASSKEY_FAKE_GH_SCENARIO="$scenario" expect_failure \
    "attestation verification output fails closed: $scenario" "$expected_diagnostic" \
    run_audit "$fixture" --require-ready
done

write_blocked_fixture "$fixture"
mutate_json "$fixture" "$ready_json_mutator"
mutate_json "$fixture" 'const fs=require("fs"); const f=process.env.PASSKEY_FIXTURE; const d=JSON.parse(fs.readFileSync(f,"utf8")); delete d.deploymentEvidence[0].imageRepository; fs.writeFileSync(f, JSON.stringify(d));'
expect_failure "ready evidence missing immutable image repository" "deploymentEvidence[0].imageRepository must be ghcr.io/soramitsu/fearless-passkey-backup" run_audit "$fixture" --require-ready

for missing_url_field in imagePublicationRunUrl imageProvenanceAttestationUrl; do
  write_blocked_fixture "$fixture"
  mutate_json "$fixture" "$ready_json_mutator"
  PASSKEY_PUBLICATION_FIELD="$missing_url_field" mutate_json "$fixture" 'const fs=require("fs"); const f=process.env.PASSKEY_FIXTURE; const d=JSON.parse(fs.readFileSync(f,"utf8")); delete d.deploymentEvidence[0][process.env.PASSKEY_PUBLICATION_FIELD]; fs.writeFileSync(f, JSON.stringify(d));'
  expect_failure "ready evidence missing $missing_url_field" "$missing_url_field must be a canonical protected-repository GitHub" run_audit "$fixture" --require-ready
done

write_blocked_fixture "$fixture"
mutate_json "$fixture" "$ready_json_mutator"
mutate_json "$fixture" 'const fs=require("fs"); const f=process.env.PASSKEY_FIXTURE; const d=JSON.parse(fs.readFileSync(f,"utf8")); d.deploymentEvidence[0].imageRepository="ghcr.io/attacker/fearless-passkey-backup"; fs.writeFileSync(f, JSON.stringify(d));'
expect_failure "ready evidence from wrong image repository" "deploymentEvidence[0].imageRepository must be ghcr.io/soramitsu/fearless-passkey-backup" run_audit "$fixture" --require-ready

for bad_run_url in \
  'https://github.com/attacker/fearless-release-readiness/actions/runs/123456789' \
  'https://github.com/soramitsu/fearless-release-readiness/actions/runs/0' \
  'https://github.com/soramitsu/fearless-release-readiness/actions/runs/123456789?attempt=2'; do
  write_blocked_fixture "$fixture"
  mutate_json "$fixture" "$ready_json_mutator"
  PASSKEY_BAD_URL="$bad_run_url" mutate_json "$fixture" 'const fs=require("fs"); const f=process.env.PASSKEY_FIXTURE; const d=JSON.parse(fs.readFileSync(f,"utf8")); d.deploymentEvidence[0].imagePublicationRunUrl=process.env.PASSKEY_BAD_URL; fs.writeFileSync(f, JSON.stringify(d));'
  expect_failure "non-canonical publication run URL: $bad_run_url" "imagePublicationRunUrl must be a canonical protected-repository GitHub Actions run URL with a positive integer id" run_audit "$fixture" --require-ready
done

write_blocked_fixture "$fixture"
mutate_json "$fixture" "$ready_json_mutator"
mutate_json "$fixture" 'const fs=require("fs"); const f=process.env.PASSKEY_FIXTURE; const d=JSON.parse(fs.readFileSync(f,"utf8")); d.deploymentEvidence[0].imagePublicationRunUrl += "\n"; fs.writeFileSync(f, JSON.stringify(d));'
expect_failure "publication run URL with trailing newline" "imagePublicationRunUrl must be a canonical protected-repository GitHub Actions run URL with a positive integer id" run_audit "$fixture" --require-ready

for bad_attestation_url in \
  'https://github.com/attacker/fearless-release-readiness/attestations/987654321' \
  'https://github.com/soramitsu/fearless-release-readiness/attestations/0' \
  'https://github.com/soramitsu/fearless-release-readiness/attestations/987654321#details'; do
  write_blocked_fixture "$fixture"
  mutate_json "$fixture" "$ready_json_mutator"
  PASSKEY_BAD_URL="$bad_attestation_url" mutate_json "$fixture" 'const fs=require("fs"); const f=process.env.PASSKEY_FIXTURE; const d=JSON.parse(fs.readFileSync(f,"utf8")); d.deploymentEvidence[0].imageProvenanceAttestationUrl=process.env.PASSKEY_BAD_URL; fs.writeFileSync(f, JSON.stringify(d));'
  expect_failure "non-canonical provenance attestation URL: $bad_attestation_url" "imageProvenanceAttestationUrl must be a canonical protected-repository GitHub attestation URL with a positive integer id" run_audit "$fixture" --require-ready
done

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
mutate_json "$fixture" 'const fs=require("fs"); const f=process.env.PASSKEY_FIXTURE; const d=JSON.parse(fs.readFileSync(f,"utf8")); const second=structuredClone(d.deploymentEvidence[0]); second.deploymentId="render-passkey-prod-002"; second.imageDigest="sha256:"+"fedcba9876543210".repeat(4); second.imageProvenanceAttestationUrl="https://github.com/soramitsu/fearless-release-readiness/attestations/987654322"; d.deploymentEvidence.push(second); fs.writeFileSync(f, JSON.stringify(d));'
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
