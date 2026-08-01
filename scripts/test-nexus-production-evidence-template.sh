#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
GENERATOR_SCRIPT="$SCRIPT_DIR/generate-nexus-production-evidence-template.sh"
AUDIT_SCRIPT="$SCRIPT_DIR/audit-nexus-production-evidence.sh"
DEFAULT_MANIFEST="$SCRIPT_DIR/../config/nexus-production-evidence.json"

fail() {
  echo "[nexus-production-evidence-template-test][error] $*" >&2
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
  NEXUS_FIXTURE="$file" node -e "$script"
}

tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

stdout_template="$tmp_dir/stdout-template.json"
output_template="$tmp_dir/output-template.json"
separator_template="$tmp_dir/separator-template.json"

generator_help="$(bash "$GENERATOR_SCRIPT" --help)"
[[ "$generator_help" == *"stale evidence cannot be"* && "$generator_help" == *"replayed behind evidence-missing blockers"* ]] \
  || fail "template help must document blocked-evidence replay protection"

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
  /(?:secret|password|token|private[_-]?key|authorization|cookie|seed|mnemonic|credentialStoreSnapshot|credentialsByStorageKey|clientDataJSON)/iu;

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
check(manifest.scope === 'sora-nexus-production-readiness', 'scope mismatch');
check(manifest.status === 'ready', 'template must show the operator target status');
check(manifest.releaseEnabled === true, 'template must show the operator target releaseEnabled value');
check(Array.isArray(manifest.blockers) && manifest.blockers.length === 0, 'template blockers must be empty');
check(secretLikeKeyReason(manifest) === null, 'template must not contain secret-like keys');
check(manifest.routePublicationEvidence?.length === 1, 'template must contain one publication record');
check(manifest.routeCanaryEvidence?.length === 1, 'template must contain one canary record');
check(manifest.walletSmokeEvidence?.length === 3, 'template must contain android, ios, and web wallet smoke records');
check(
  !JSON.stringify(manifest).includes('_SECONDS'),
  'legacy seconds-form Nexus timestamp placeholders must be rejected in favor of RFC3339',
);

const publication = manifest.routePublicationEvidence[0] || {};
const canary = manifest.routeCanaryEvidence[0] || {};
const wallets = new Map((manifest.walletSmokeEvidence || []).map((entry) => [entry.platform, entry]));
check(publication.routeManifestCommit === 'TODO_40_HEX_ROUTE_MANIFEST_COMMIT', 'route manifest commit placeholder mismatch');
check(
  publication.routeManifestSourcePath === 'artifacts/nexus/production-route-governance-action.json',
  'route governance action source path must pin the canonical committed artifact',
);
check(publication.routeManifestHash === 'sha256:TODO_64_HEX_ROUTE_MANIFEST_HASH', 'route manifest hash placeholder mismatch');
check(publication.publicationTransactionHash === '0xTODO_64_HEX_PUBLICATION_TX_HASH', 'publication tx placeholder mismatch');
check(publication.publishedAt === 'TODO_UTC_ROUTE_PUBLISHED_AT_RFC3339', 'publishedAt placeholder mismatch');
check(publication.toriiBaseUrl === manifest.toriiBaseUrl, 'publication torii URL mismatch');
check(publication.mcpUrl === manifest.mcpUrl, 'publication MCP URL mismatch');
check(canary.publishedRouteManifestHash === publication.routeManifestHash, 'canary must reference publication manifest hash placeholder');
check(canary.routeCanaryTransactionHash === '0xTODO_64_HEX_CANARY_TX_HASH', 'canary tx placeholder mismatch');
check(canary.sourceAccount === 'TODO_NEXUS_CANARY_SOURCE_ACCOUNT', 'canary source account placeholder mismatch');
check(canary.destinationAccount === 'TODO_NEXUS_CANARY_DESTINATION_ACCOUNT', 'canary destination account placeholder mismatch');
check(canary.assetId === 'xor#sora', 'canary asset placeholder mismatch');
check(canary.amount === 'TODO_POSITIVE_DECIMAL_AMOUNT', 'canary amount placeholder mismatch');
check(
  canary.routeCanaryCheckedAt === 'TODO_UTC_CANARY_CHECKED_WITHIN_24_HOURS_AT_RFC3339',
  'canary timestamp placeholder must declare the fixed 24-hour readiness window',
);
for (const platform of ['android', 'ios', 'web']) {
  const wallet = wallets.get(platform) || {};
  const upper = platform.toUpperCase();
  check(wallets.has(platform), `template missing ${platform} wallet smoke record`);
  check(wallet.routeManifestHash === publication.routeManifestHash, `${platform} wallet smoke must reference publication manifest hash placeholder`);
  check(wallet.walletCommit === `TODO_40_HEX_${upper}_WALLET_COMMIT`, `${platform} wallet commit placeholder mismatch`);
  check(
    wallet.walletSmokeTransactionHash === `0xTODO_64_HEX_${upper}_WALLET_SMOKE_TX_HASH`,
    `${platform} wallet smoke tx placeholder mismatch`,
  );
  check(wallet.sourceAccount === `TODO_NEXUS_${upper}_SOURCE_ACCOUNT`, `${platform} source account placeholder mismatch`);
  check(wallet.destinationAccount === `TODO_NEXUS_${upper}_DESTINATION_ACCOUNT`, `${platform} destination account placeholder mismatch`);
  check(
    wallet.walletSmokeSubmittedAt === `TODO_UTC_${upper}_WALLET_SMOKE_SUBMITTED_AT_RFC3339`,
    `${platform} wallet submitted timestamp placeholder mismatch`,
  );
  check(
    wallet.walletSmokeObservedAt === `TODO_UTC_${upper}_WALLET_SMOKE_OBSERVED_WITHIN_24_HOURS_AT_RFC3339`,
    `${platform} wallet observed timestamp placeholder must declare the fixed 24-hour readiness window`,
  );
  check(wallet.amount === 'TODO_POSITIVE_DECIMAL_AMOUNT', `${platform} wallet amount placeholder mismatch`);
}

if (errors.length > 0) {
  for (const error of errors) console.error(error);
  process.exit(1);
}
NODE

expect_failure \
  "template cannot pass ready audit with TODO placeholders" \
  "routeManifestCommit must be a 40-character git commit" \
  bash "$AUDIT_SCRIPT" --evidence "$output_template" --require-ready

expect_failure "unknown generator argument" "Unknown argument" bash "$GENERATOR_SCRIPT" --nope
expect_failure "missing output argument" "--output requires a path" bash "$GENERATOR_SCRIPT" --output
expect_failure "missing manifest" "Nexus production evidence manifest missing" bash "$GENERATOR_SCRIPT" --evidence "$tmp_dir/missing.json"

bad_json="$tmp_dir/bad-json.json"
printf '{' >"$bad_json"
expect_failure "invalid manifest JSON" "must be valid JSON" bash "$GENERATOR_SCRIPT" --evidence "$bad_json"

wrong_scope="$tmp_dir/wrong-scope.json"
cp "$DEFAULT_MANIFEST" "$wrong_scope"
mutate_json "$wrong_scope" 'const fs=require("fs"); const f=process.env.NEXUS_FIXTURE; const d=JSON.parse(fs.readFileSync(f,"utf8")); d.scope="wrong-nexus-scope"; fs.writeFileSync(f, `${JSON.stringify(d, null, 2)}\n`);'
expect_failure "wrong evidence scope" "scope must be sora-nexus-production-readiness" bash "$GENERATOR_SCRIPT" --evidence "$wrong_scope"

wrong_status="$tmp_dir/wrong-status.json"
cp "$DEFAULT_MANIFEST" "$wrong_status"
mutate_json "$wrong_status" 'const fs=require("fs"); const f=process.env.NEXUS_FIXTURE; const d=JSON.parse(fs.readFileSync(f,"utf8")); d.status="ready"; d.releaseEnabled=true; d.blockers=[]; fs.writeFileSync(f, `${JSON.stringify(d, null, 2)}\n`);'
expect_failure "ready committed manifest rejected" "status must stay blocked in the committed Nexus manifest" bash "$GENERATOR_SCRIPT" --evidence "$wrong_status"

unsupported_blocker="$tmp_dir/unsupported-blocker.json"
cp "$DEFAULT_MANIFEST" "$unsupported_blocker"
mutate_json "$unsupported_blocker" 'const fs=require("fs"); const f=process.env.NEXUS_FIXTURE; const d=JSON.parse(fs.readFileSync(f,"utf8")); d.blockers.push("manual-approval-pending"); fs.writeFileSync(f, `${JSON.stringify(d, null, 2)}\n`);'
expect_failure "unsupported Nexus production evidence blocker" "unsupported Nexus production evidence blocker in manifest: manual-approval-pending" bash "$GENERATOR_SCRIPT" --evidence "$unsupported_blocker"

duplicate_blocker="$tmp_dir/duplicate-blocker.json"
cp "$DEFAULT_MANIFEST" "$duplicate_blocker"
mutate_json "$duplicate_blocker" 'const fs=require("fs"); const f=process.env.NEXUS_FIXTURE; const d=JSON.parse(fs.readFileSync(f,"utf8")); d.blockers.push("route-publication-evidence-missing"); fs.writeFileSync(f, `${JSON.stringify(d, null, 2)}\n`);'
expect_failure "duplicate Nexus production evidence blocker" "duplicate Nexus production evidence blocker in manifest" bash "$GENERATOR_SCRIPT" --evidence "$duplicate_blocker"

duplicate_ready_command="$tmp_dir/duplicate-ready-command.json"
cp "$DEFAULT_MANIFEST" "$duplicate_ready_command"
mutate_json "$duplicate_ready_command" 'const fs=require("fs"); const f=process.env.NEXUS_FIXTURE; const d=JSON.parse(fs.readFileSync(f,"utf8")); d.readyVerificationCommands.push("bash scripts/test-nexus-production-evidence-template.sh"); fs.writeFileSync(f, `${JSON.stringify(d, null, 2)}\n`);'
expect_failure "duplicate Nexus production evidence verification command" "duplicate Nexus production evidence verification command in manifest" bash "$GENERATOR_SCRIPT" --evidence "$duplicate_ready_command"

missing_required_field="$tmp_dir/missing-required-field.json"
cp "$DEFAULT_MANIFEST" "$missing_required_field"
mutate_json "$missing_required_field" 'const fs=require("fs"); const f=process.env.NEXUS_FIXTURE; const d=JSON.parse(fs.readFileSync(f,"utf8")); d.requiredEvidenceFields=d.requiredEvidenceFields.filter((field)=>field!=="publicationTransactionHash"); fs.writeFileSync(f, `${JSON.stringify(d, null, 2)}\n`);'
expect_failure "missing publication tx field" "requiredEvidenceFields missing publicationTransactionHash" bash "$GENERATOR_SCRIPT" --evidence "$missing_required_field"

missing_route_source_field="$tmp_dir/missing-route-source-field.json"
cp "$DEFAULT_MANIFEST" "$missing_route_source_field"
mutate_json "$missing_route_source_field" 'const fs=require("fs"); const f=process.env.NEXUS_FIXTURE; const d=JSON.parse(fs.readFileSync(f,"utf8")); d.requiredEvidenceFields=d.requiredEvidenceFields.filter((field)=>field!=="routeManifestSourcePath"); fs.writeFileSync(f, `${JSON.stringify(d, null, 2)}\n`);'
expect_failure "missing canonical route source field" "requiredEvidenceFields missing routeManifestSourcePath" bash "$GENERATOR_SCRIPT" --evidence "$missing_route_source_field"

missing_canary_amount_field="$tmp_dir/missing-canary-amount-field.json"
cp "$DEFAULT_MANIFEST" "$missing_canary_amount_field"
mutate_json "$missing_canary_amount_field" 'const fs=require("fs"); const f=process.env.NEXUS_FIXTURE; const d=JSON.parse(fs.readFileSync(f,"utf8")); d.requiredEvidenceFields=d.requiredEvidenceFields.filter((field)=>field!=="routeCanaryAmount"); fs.writeFileSync(f, `${JSON.stringify(d, null, 2)}\n`);'
expect_failure "missing route canary amount field" "requiredEvidenceFields missing routeCanaryAmount" bash "$GENERATOR_SCRIPT" --evidence "$missing_canary_amount_field"

duplicate_required_field="$tmp_dir/duplicate-required-field.json"
cp "$DEFAULT_MANIFEST" "$duplicate_required_field"
mutate_json "$duplicate_required_field" 'const fs=require("fs"); const f=process.env.NEXUS_FIXTURE; const d=JSON.parse(fs.readFileSync(f,"utf8")); d.requiredEvidenceFields.push("publicationTransactionHash"); fs.writeFileSync(f, `${JSON.stringify(d, null, 2)}\n`);'
expect_failure "duplicate Nexus production evidence required field" "duplicate Nexus production evidence required field in manifest" bash "$GENERATOR_SCRIPT" --evidence "$duplicate_required_field"

unsupported_field="$tmp_dir/unsupported-field.json"
cp "$DEFAULT_MANIFEST" "$unsupported_field"
mutate_json "$unsupported_field" 'const fs=require("fs"); const f=process.env.NEXUS_FIXTURE; const d=JSON.parse(fs.readFileSync(f,"utf8")); d.requiredEvidenceFields.push("region"); fs.writeFileSync(f, `${JSON.stringify(d, null, 2)}\n`);'
expect_failure "unsupported evidence field" "unsupported Nexus production evidence field in manifest: region" bash "$GENERATOR_SCRIPT" --evidence "$unsupported_field"

unsupported_top_level="$tmp_dir/unsupported-top-level.json"
cp "$DEFAULT_MANIFEST" "$unsupported_top_level"
mutate_json "$unsupported_top_level" 'const fs=require("fs"); const f=process.env.NEXUS_FIXTURE; const d=JSON.parse(fs.readFileSync(f,"utf8")); d.region="jp"; fs.writeFileSync(f, `${JSON.stringify(d, null, 2)}\n`);'
expect_failure "unsupported top-level manifest field" "unsupported Nexus production evidence manifest field manifest.region" bash "$GENERATOR_SCRIPT" --evidence "$unsupported_top_level"

unsupported_publication_record="$tmp_dir/unsupported-publication-record.json"
cp "$DEFAULT_MANIFEST" "$unsupported_publication_record"
mutate_json "$unsupported_publication_record" 'const fs=require("fs"); const f=process.env.NEXUS_FIXTURE; const d=JSON.parse(fs.readFileSync(f,"utf8")); d.routePublicationEvidence=[{ region: "jp" }]; fs.writeFileSync(f, `${JSON.stringify(d, null, 2)}\n`);'
expect_failure "unsupported publication evidence field" "unsupported Nexus route publication evidence field routePublicationEvidence[0].region" bash "$GENERATOR_SCRIPT" --evidence "$unsupported_publication_record"

unsupported_canary_record="$tmp_dir/unsupported-canary-record.json"
cp "$DEFAULT_MANIFEST" "$unsupported_canary_record"
mutate_json "$unsupported_canary_record" 'const fs=require("fs"); const f=process.env.NEXUS_FIXTURE; const d=JSON.parse(fs.readFileSync(f,"utf8")); d.routeCanaryEvidence=[{ latencyMs: 10 }]; fs.writeFileSync(f, `${JSON.stringify(d, null, 2)}\n`);'
expect_failure "unsupported canary evidence field" "unsupported Nexus route canary evidence field routeCanaryEvidence[0].latencyMs" bash "$GENERATOR_SCRIPT" --evidence "$unsupported_canary_record"

unsupported_wallet_record="$tmp_dir/unsupported-wallet-record.json"
cp "$DEFAULT_MANIFEST" "$unsupported_wallet_record"
mutate_json "$unsupported_wallet_record" 'const fs=require("fs"); const f=process.env.NEXUS_FIXTURE; const d=JSON.parse(fs.readFileSync(f,"utf8")); d.walletSmokeEvidence=[{ memo: "release" }]; fs.writeFileSync(f, `${JSON.stringify(d, null, 2)}\n`);'
expect_failure "unsupported wallet smoke evidence field" "unsupported Nexus wallet smoke evidence field walletSmokeEvidence[0].memo" bash "$GENERATOR_SCRIPT" --evidence "$unsupported_wallet_record"

prefilled_publication="$tmp_dir/prefilled-publication.json"
cp "$DEFAULT_MANIFEST" "$prefilled_publication"
mutate_json "$prefilled_publication" 'const fs=require("fs"); const f=process.env.NEXUS_FIXTURE; const d=JSON.parse(fs.readFileSync(f,"utf8")); d.routePublicationEvidence=[{ routeManifestCommit: "1111111111111111111111111111111111111111", routeManifestHash: "sha256:2222222222222222222222222222222222222222222222222222222222222222", publicationTransactionHash: "0x3333333333333333333333333333333333333333333333333333333333333333", publicationAuthority: "release-authority@sora", publishedAt: "2026-06-26T00:00:00Z", toriiBaseUrl: d.toriiBaseUrl, mcpUrl: d.mcpUrl, operator: "release" }]; fs.writeFileSync(f, `${JSON.stringify(d, null, 2)}\n`);'
expect_failure "prefilled route publication evidence" "committed Nexus production evidence manifest must not prefill routePublicationEvidence" bash "$GENERATOR_SCRIPT" --evidence "$prefilled_publication"

prefilled_canary="$tmp_dir/prefilled-canary.json"
cp "$DEFAULT_MANIFEST" "$prefilled_canary"
mutate_json "$prefilled_canary" 'const fs=require("fs"); const f=process.env.NEXUS_FIXTURE; const d=JSON.parse(fs.readFileSync(f,"utf8")); d.routeCanaryEvidence=[{ publishedRouteManifestHash: "sha256:2222222222222222222222222222222222222222222222222222222222222222", routeCanaryTransactionHash: "0x4444444444444444444444444444444444444444444444444444444444444444", authority: "release-authority@sora", routeCanaryCheckedAt: "2026-06-26T00:10:00Z", toriiBaseUrl: d.toriiBaseUrl, operator: "release" }]; fs.writeFileSync(f, `${JSON.stringify(d, null, 2)}\n`);'
expect_failure "prefilled route canary evidence" "committed Nexus production evidence manifest must not prefill routeCanaryEvidence" bash "$GENERATOR_SCRIPT" --evidence "$prefilled_canary"

prefilled_wallet="$tmp_dir/prefilled-wallet.json"
cp "$DEFAULT_MANIFEST" "$prefilled_wallet"
mutate_json "$prefilled_wallet" 'const fs=require("fs"); const f=process.env.NEXUS_FIXTURE; const d=JSON.parse(fs.readFileSync(f,"utf8")); d.walletSmokeEvidence=[{ platform: "web", walletCommit: "5555555555555555555555555555555555555555", routeManifestHash: "sha256:2222222222222222222222222222222222222222222222222222222222222222", walletSmokeTransactionHash: "0x6666666666666666666666666666666666666666666666666666666666666666", sourceAccount: "nexus-source", destinationAccount: "nexus-destination", assetId: "xor#sora", amount: "1.0", walletSmokeSubmittedAt: "2026-06-26T00:20:00Z", walletSmokeObservedAt: "2026-06-26T00:25:00Z", toriiBaseUrl: d.toriiBaseUrl, operator: "release" }]; fs.writeFileSync(f, `${JSON.stringify(d, null, 2)}\n`);'
expect_failure "prefilled wallet smoke evidence" "committed Nexus production evidence manifest must not prefill walletSmokeEvidence" bash "$GENERATOR_SCRIPT" --evidence "$prefilled_wallet"

secret_manifest="$tmp_dir/secret-manifest.json"
cp "$DEFAULT_MANIFEST" "$secret_manifest"
mutate_json "$secret_manifest" 'const fs=require("fs"); const f=process.env.NEXUS_FIXTURE; const d=JSON.parse(fs.readFileSync(f,"utf8")); d.privateKey="do-not-commit"; fs.writeFileSync(f, `${JSON.stringify(d, null, 2)}\n`);'
expect_failure "secret-like manifest key" "must not be read from public Nexus production evidence manifest" bash "$GENERATOR_SCRIPT" --evidence "$secret_manifest"

secret_nested_manifest="$tmp_dir/secret-nested-manifest.json"
cp "$DEFAULT_MANIFEST" "$secret_nested_manifest"
mutate_json "$secret_nested_manifest" 'const fs=require("fs"); const f=process.env.NEXUS_FIXTURE; const d=JSON.parse(fs.readFileSync(f,"utf8")); d.walletSmokeEvidence=[{ clientDataJSON: "do-not-commit" }]; fs.writeFileSync(f, `${JSON.stringify(d, null, 2)}\n`);'
expect_failure "nested secret-like manifest key" "must not be read from public Nexus production evidence manifest" bash "$GENERATOR_SCRIPT" --evidence "$secret_nested_manifest"

missing_template_command="$tmp_dir/missing-template-command.json"
cp "$DEFAULT_MANIFEST" "$missing_template_command"
mutate_json "$missing_template_command" 'const fs=require("fs"); const f=process.env.NEXUS_FIXTURE; const d=JSON.parse(fs.readFileSync(f,"utf8")); d.readyVerificationCommands=d.readyVerificationCommands.filter((command)=>!command.includes("generate-nexus-production-evidence-template")); fs.writeFileSync(f, `${JSON.stringify(d, null, 2)}\n`);'
expect_failure "missing template generator command" "readyVerificationCommands missing bash scripts/generate-nexus-production-evidence-template.sh" bash "$GENERATOR_SCRIPT" --evidence "$missing_template_command"

missing_template_self_test="$tmp_dir/missing-template-self-test.json"
cp "$DEFAULT_MANIFEST" "$missing_template_self_test"
mutate_json "$missing_template_self_test" 'const fs=require("fs"); const f=process.env.NEXUS_FIXTURE; const d=JSON.parse(fs.readFileSync(f,"utf8")); d.readyVerificationCommands=d.readyVerificationCommands.filter((command)=>!command.includes("test-nexus-production-evidence-template")); fs.writeFileSync(f, `${JSON.stringify(d, null, 2)}\n`);'
expect_failure "missing template self-test command" "readyVerificationCommands missing bash scripts/test-nexus-production-evidence-template.sh" bash "$GENERATOR_SCRIPT" --evidence "$missing_template_self_test"

echo "[nexus-production-evidence-template-test] all assertions passed"
