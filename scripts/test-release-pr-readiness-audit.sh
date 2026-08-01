#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
AUDIT_SCRIPT="$SCRIPT_DIR/audit-release-pr-readiness.sh"

fail() {
  echo "[release-pr-readiness-test][error] $*" >&2
  exit 1
}

tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

config_file="$tmp_dir/release-readiness-prs.tsv"
fake_gh="$tmp_dir/gh"
expected_merged_oid="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
expected_drift_oid="bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
ton_pr_12_head_oid="8da98205b47ef2b86e88fb063f647df06a8a7075"
site_pr_49_head_oid="3b2b04f071e0afc264d2d350941d6fa3afc0f4db"
shared_features_pr_81_head_oid="43e999ee10e64b5dd740b4695ed9766866e2168d"
iroha_consolidated_pr_5619_head_oid="9e146c135f91c0fff5d7b9f5c27af6b5a8e476de"

write_config() {
  cat > "$config_file" <<'TSV'
# repo	head	base	required_state	required_checks
soramitsu/fearless-Android	codex/android-universal-wallet-readiness	develop	merged	validate,build-and-test
soramitsu/fearless-Android	codex/android-xcm-evidence-release-commit	develop	merged	validate,build-and-test
soramitsu/fearless-iOS	codex/ios-universal-wallet-readiness	develop	merged	validate,build,continuous-integration/jenkins/pr-merge
soramitsu/fearless-iOS	codex/ios-transaction-builder-ci-gate	develop	merged	validate,build,continuous-integration/jenkins/pr-merge
soramitsu/fearless-iOS	codex/ios-production-consolidated-20260731	develop	merged	validate,build,continuous-integration/jenkins/pr-merge
soramitsu/shared-features-spm	codex/ios-shared-features-delta-20260731	develop	merged	continuous-integration/jenkins/pr-merge
soramitsu/fearless-wallet-web	codex/web-bitcoin-broadcast-evidence	develop	merged	validate,verify
soramitsu/fearless-wallet-web	codex/web-bitcoin-canonical-indexer-evidence	develop	merged	validate,verify
soramitsu/fearless-site-web	codex/site-todo-debt-baseline-hardening	develop	merged	validate,build,Vercel
soramitsu/fearless-site-web	fix/app-association-publication	develop	merged	validate,build,Vercel
tonswap-org/ton-indexer	hotfix/production-smoke-diagnostics	master	merged	validate,verify
solswap-io/solswap-indexer	hotfix/production-smoke-diagnostics	master	merged	validate,verify
tonswap-org/ton-indexer	chore/sync-master-to-develop	develop	merged	validate,verify
solswap-io/solswap-indexer	chore/sync-master-to-develop	develop	merged	validate,verify
solswap-io/solswap-indexer	release/sync-develop-into-master	master	merged	validate,verify
tonswap-org/ton-indexer	codex/ton-health-identity-gate	develop	merged	validate,verify
solswap-io/solswap-indexer	codex/solswap-health-identity-gate	develop	merged	validate,verify
tonswap-org/ton-indexer	release/ton-health-identity-master	master	merged	validate,verify
solswap-io/solswap-indexer	release/solswap-health-identity-master	master	merged	validate,verify
solswap-io/solswap-indexer	release/solana-indexer-master-sync-20260628	master	merged	validate,verify
tonswap-org/ton-indexer	release/ton-indexer-master-sync-20260701	master	merged	validate,verify
tonswap-org/ton-indexer	hotfix/indexer-service-info-schema-smoke	master	merged	validate,verify
solswap-io/solswap-indexer	hotfix/indexer-service-info-schema-smoke	master	merged	validate,verify
tonswap-org/ton-indexer	hotfix/deployment-evidence-placeholder-quality	master	merged	validate,verify
solswap-io/solswap-indexer	hotfix/deployment-evidence-placeholder-quality	master	merged	validate,verify
tonswap-org/ton-indexer	chore/sync-master-to-develop-20260630	develop	merged	validate,verify
solswap-io/solswap-indexer	chore/sync-master-to-develop-20260630	develop	merged	validate,verify
tonswap-org/ton-indexer	codex/ti-smoke-body-preview-tests	develop	merged	validate,verify
solswap-io/solswap-indexer	codex/si-smoke-body-preview-tests	develop	merged	validate,verify
sora-xor/polkaswap-indexer	codex/pi-deployment-evidence-gate	develop	merged	validate,verify
sora-xor/polkaswap-indexer	hotfix/migration-replay-order	master	merged	validate,verify
hyperledger-iroha/iroha	codex/kagemusha-first-release-canonical-selector	optimizations	merged	DCO
hyperledger-iroha/iroha	codex/kagemusha-selector-hardening	optimizations	merged	DCO
hyperledger-iroha/iroha	codex/fearless-production-consolidated-20260731	optimizations	merged	DCO
TSV
  node - "$config_file" "$expected_merged_oid" <<'NODE'
const fs = require('fs')
const [file, headSha] = process.argv.slice(2)
const source = fs.readFileSync(file, 'utf8').split(/\r?\n/)
const output = [
  '# Each release PR requirement is bound to immutable review evidence.',
  '# reviewed_pr_pin\trepo\thead\tbase\treviewed_pr_number\treviewed_head_sha',
]
for (const line of source) {
  if (!line || line.startsWith('#')) continue
  const [repo, head, base] = line.split('\t')
  output.push(`# reviewed_pr_pin\t${repo}\t${head}\t${base}\t42\t${headSha}`)
  output.push(line)
}
fs.writeFileSync(file, `${output.join('\n')}\n`)
NODE
}

write_single_config() {
  local repo="$1"
  local head="$2"
  local base="$3"
  local required_state="$4"
  local required_checks="$5"
  local reviewed_pr_number="${6:-42}"
  local reviewed_head_sha="${7:-$expected_merged_oid}"
  printf '%s\n' \
    "# reviewed_pr_pin	$repo	$head	$base	$reviewed_pr_number	$reviewed_head_sha" \
    "$repo	$head	$base	$required_state	$required_checks" > "$config_file"
}

append_duplicate_check_provenance_pin() {
  local repo="$1"
  local head="$2"
  local base="$3"
  local check_name="$4"
  local workflow_id="$5"
  local workflow_path="$6"
  printf '%s\n' \
    "# duplicate_check_provenance_pin	$repo	$head	$base	$check_name	15368	github-actions	$workflow_id	$workflow_path" >> "$config_file"
}

cat > "$fake_gh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail

scenario="${FAKE_GH_SCENARIO:-merged}"
merged_oid="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
drift_oid="bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
pr_number=42
case "$scenario" in
  exact-ton-pr-12-merged|exact-ton-pr-12-open)
    merged_oid="8da98205b47ef2b86e88fb063f647df06a8a7075"
    pr_number=12
    ;;
  exact-site-pr-49-merged|exact-site-pr-49-open|exact-site-pr-49-pending)
    merged_oid="3b2b04f071e0afc264d2d350941d6fa3afc0f4db"
    pr_number=49
    ;;
  exact-shared-features-pr-81-merged|exact-shared-features-pr-81-open|exact-shared-features-pr-81-pending)
    merged_oid="43e999ee10e64b5dd740b4695ed9766866e2168d"
    pr_number=81
    ;;
  exact-iroha-pr-5619-merged|exact-iroha-pr-5619-open|exact-iroha-pr-5619-pending)
    merged_oid="9e146c135f91c0fff5d7b9f5c27af6b5a8e476de"
    pr_number=5619
    ;;
esac
repo=""
head=""
base=""
state=""
json_fields=""

if [[ "${1:-}" == "api" ]]; then
  shift
  if [[ "${1:-}" == "graphql" ]]; then
    shift
    graphql_owner=""
    graphql_name=""
    graphql_number=""

    while (($#)); do
      case "$1" in
        -F)
          case "$2" in
            owner=*) graphql_owner="${2#owner=}" ;;
            name=*) graphql_name="${2#name=}" ;;
            number=*) graphql_number="${2#number=}" ;;
          esac
          shift 2
          ;;
        -f)
          shift 2
          ;;
        *)
          shift
          ;;
      esac
    done

    graphql_repo="$graphql_owner/$graphql_name"
    if [[ -z "$graphql_owner" || -z "$graphql_name" || -z "$graphql_number" ]]; then
      echo "missing GraphQL variables owner=$graphql_owner name=$graphql_name number=$graphql_number" >&2
      exit 1
    fi

    case "$scenario:$graphql_repo" in
      review-thread-query-fails:soramitsu/fearless-iOS)
        echo "GitHub GraphQL review thread API unavailable" >&2
        exit 1
        ;;
    malformed-review-threads:soramitsu/fearless-iOS)
        cat <<'JSON'
{"data":{"repository":{"pullRequest":{"reviewThreads":{"nodes":[{"isResolved":"no"}],"pageInfo":{"hasNextPage":false}}}}}}
JSON
        ;;
      missing-review-thread-id:soramitsu/fearless-iOS)
        cat <<'JSON'
{"data":{"repository":{"pullRequest":{"reviewThreads":{"nodes":[{"isResolved":false,"isOutdated":false,"path":"fearless/Common/Model/SolanaIndexerContract.swift","line":154,"originalLine":150,"comments":{"nodes":[{"url":"https://github.com/soramitsu/fearless-iOS/pull/42#discussion_r1"}]}}],"pageInfo":{"hasNextPage":false}}}}}}
JSON
        ;;
      open-review-required:soramitsu/fearless-iOS|open-supersedes-merged:soramitsu/fearless-iOS)
        cat <<'JSON'
{"data":{"repository":{"pullRequest":{"reviewThreads":{"nodes":[{"id":"PRRT_ios_current","isResolved":false,"isOutdated":false,"path":"fearless/Common/Model/SolanaIndexerContract.swift","line":154,"originalLine":150,"comments":{"nodes":[{"url":"https://github.com/soramitsu/fearless-iOS/pull/42#discussion_r1"}]}},{"id":"PRRT_ios_resolved","isResolved":true,"isOutdated":false,"path":"resolved.swift","line":1,"originalLine":1,"comments":{"nodes":[{"url":"https://github.com/soramitsu/fearless-iOS/pull/42#discussion_r2"}]}},{"id":"PRRT_ios_outdated","isResolved":false,"isOutdated":true,"path":"fearless/Common/Model/BitcoinBalanceContract.swift","line":null,"originalLine":88,"comments":{"nodes":[{"url":"https://github.com/soramitsu/fearless-iOS/pull/42#discussion_r3"}]}}],"pageInfo":{"hasNextPage":false}}}}}}
JSON
        ;;
      open-pending-check:soramitsu/fearless-Android)
        cat <<'JSON'
{"data":{"repository":{"pullRequest":{"reviewThreads":{"nodes":[{"id":"PRRT_android_current","isResolved":false,"isOutdated":false,"path":"public-shared-features-xcm/src/main/java/jp/co/soramitsu/xcm/SubstrateXcmTransferEngine.kt","line":171,"originalLine":169,"comments":{"nodes":[{"url":"https://github.com/soramitsu/fearless-Android/pull/42#discussion_r1"}]}}],"pageInfo":{"hasNextPage":true}}}}}}
JSON
        ;;
      open-outdated-only:soramitsu/fearless-wallet-web)
        cat <<'JSON'
{"data":{"repository":{"pullRequest":{"reviewThreads":{"nodes":[{"id":"PRRT_web_outdated","isResolved":false,"isOutdated":true,"path":"scripts/audit-bitcoin-broadcast-evidence.sh","line":null,"originalLine":284,"comments":{"nodes":[{"url":"https://github.com/soramitsu/fearless-wallet-web/pull/42#discussion_r3478239652"}]}}],"pageInfo":{"hasNextPage":false}}}}}}
JSON
        ;;
      *)
        cat <<'JSON'
{"data":{"repository":{"pullRequest":{"reviewThreads":{"nodes":[],"pageInfo":{"hasNextPage":false}}}}}}
JSON
        ;;
    esac
    exit 0
  fi

  api_path="${1:-}"
  if [[ "$api_path" == repos/*/pulls\?* ]]; then
    api_repo="${api_path#repos/}"
    api_repo="${api_repo%%/pulls\?*}"

    case "$scenario:$api_repo" in
      rest-fallback-merged:tonswap-org/ton-indexer)
        cat <<JSON
[{"number":42,"html_url":"https://github.com/$api_repo/pull/42","state":"closed","merged_at":"2026-06-27T11:10:31Z","draft":false,"head":{"ref":"hotfix/production-smoke-diagnostics","sha":"$merged_oid"},"base":{"ref":"master"}}]
JSON
        ;;
      query-fails:soramitsu/fearless-Android)
        echo "GitHub REST pulls API unavailable" >&2
        exit 1
        ;;
      *)
        echo "unexpected REST pulls query: $api_path" >&2
        exit 1
        ;;
    esac
    exit 0
  fi

  if [[ "$api_path" == repos/*/commits/*/check-runs* ]]; then
    if [[ "$api_path" != *"/check-runs?filter=latest&per_page=100" ]]; then
      echo "required check-runs query must request the latest complete SHA-bound page" >&2
      exit 1
    fi
    api_repo="${api_path#repos/}"
    api_repo="${api_repo%%/commits/*}"
    api_oid="${api_path#repos/$api_repo/commits/}"
    api_oid="${api_oid%%/*}"

    case "$scenario:$api_repo" in
      check-evidence-query-fails:soramitsu/fearless-Android)
        echo "request failed token=CHECK_QUERY_SECRET_SENTINEL" >&2
        exit 1
        ;;
      malformed-check-rollup:soramitsu/fearless-Android)
        echo '{"total_count":2,"check_runs":{}}'
        ;;
      incomplete-check-pagination:soramitsu/fearless-Android)
        cat <<JSON
{"total_count":3,"check_runs":[{"id":101,"name":"validate","status":"completed","conclusion":"success","head_sha":"$merged_oid","check_suite":{"id":1001}},{"id":102,"name":"build-and-test","status":"completed","conclusion":"success","head_sha":"$merged_oid","check_suite":{"id":1004}}]}
JSON
        ;;
      missing-required-check:soramitsu/fearless-wallet-web)
        cat <<JSON
{"total_count":1,"check_runs":[{"id":101,"name":"validate","status":"completed","conclusion":"success","head_sha":"$merged_oid","check_suite":{"id":1001}}]}
JSON
        ;;
      skipped-required-check:soramitsu/fearless-wallet-web)
        cat <<JSON
{"total_count":2,"check_runs":[{"id":101,"name":"validate","status":"completed","conclusion":"skipped","head_sha":"$merged_oid","check_suite":{"id":1001}},{"id":102,"name":"verify","status":"completed","conclusion":"success","head_sha":"$merged_oid","check_suite":{"id":1002}}]}
JSON
        ;;
      duplicate-required-check:soramitsu/fearless-Android|all-unrelated-duplicate:soramitsu/fearless-Android|duplicate-workflow-head-branch-missing:soramitsu/fearless-Android|duplicate-non-pr-event:soramitsu/fearless-Android)
        cat <<JSON
{"total_count":3,"check_runs":[{"id":101,"name":"validate","status":"completed","conclusion":"success","head_sha":"$merged_oid","app":{"id":15368,"slug":"github-actions"},"details_url":"https://github.com/$api_repo/actions/runs/501001/job/601001","check_suite":{"id":1001}},{"id":111,"name":"validate","status":"completed","conclusion":"success","head_sha":"$merged_oid","app":{"id":15368,"slug":"github-actions"},"details_url":"https://github.com/$api_repo/actions/runs/501011/job/601011","check_suite":{"id":1011}},{"id":102,"name":"build-and-test","status":"completed","conclusion":"success","head_sha":"$merged_oid","check_suite":{"id":1004}}]}
JSON
        ;;
      cross-branch-authoritative-failure:soramitsu/fearless-Android)
        cat <<JSON
{"total_count":3,"check_runs":[{"id":101,"name":"validate","status":"completed","conclusion":"success","head_sha":"$merged_oid","app":{"id":15368,"slug":"github-actions"},"details_url":"https://github.com/$api_repo/actions/runs/501001/job/601001","check_suite":{"id":1001}},{"id":111,"name":"validate","status":"completed","conclusion":"failure","head_sha":"$merged_oid","app":{"id":15368,"slug":"github-actions"},"details_url":"https://github.com/$api_repo/actions/runs/501011/job/601011","check_suite":{"id":1011}},{"id":102,"name":"build-and-test","status":"completed","conclusion":"success","head_sha":"$merged_oid","check_suite":{"id":1004}}]}
JSON
        ;;
      duplicate-wrong-sha:soramitsu/fearless-Android|duplicate-wrong-app:soramitsu/fearless-Android|duplicate-wrong-workflow:soramitsu/fearless-Android|duplicate-missing-workflow:soramitsu/fearless-Android|duplicate-workflow-sha:soramitsu/fearless-Android|duplicate-workflow-repository:soramitsu/fearless-Android)
        second_sha="$merged_oid"
        second_app_id=15368
        if [[ "$scenario" == "duplicate-wrong-sha" ]]; then second_sha="$drift_oid"; fi
        if [[ "$scenario" == "duplicate-wrong-app" ]]; then second_app_id=99999; fi
        cat <<JSON
{"total_count":3,"check_runs":[{"id":101,"name":"validate","status":"completed","conclusion":"success","head_sha":"$merged_oid","app":{"id":15368,"slug":"github-actions"},"details_url":"https://github.com/$api_repo/actions/runs/501001/job/601001","check_suite":{"id":1001}},{"id":111,"name":"validate","status":"completed","conclusion":"success","head_sha":"$second_sha","app":{"id":$second_app_id,"slug":"github-actions"},"details_url":"https://github.com/$api_repo/actions/runs/501011/job/601011","check_suite":{"id":1011}},{"id":102,"name":"build-and-test","status":"completed","conclusion":"success","head_sha":"$merged_oid","check_suite":{"id":1004}}]}
JSON
        ;;
      stale-duplicate-checks:solswap-io/solswap-indexer|cross-branch-conflicting-duplicate:solswap-io/solswap-indexer)
        cat <<JSON
{"total_count":4,"check_runs":[{"id":201,"name":"validate","status":"completed","conclusion":"failure","head_sha":"$merged_oid","app":{"id":15368,"slug":"github-actions"},"details_url":"https://github.com/$api_repo/actions/runs/501001/job/601001","started_at":"2099-01-01T00:00:00Z","completed_at":"2099-01-01T00:01:00Z","check_suite":{"id":1001}},{"id":211,"name":"validate","status":"completed","conclusion":"success","head_sha":"$merged_oid","app":{"id":15368,"slug":"github-actions"},"details_url":"https://github.com/$api_repo/actions/runs/501011/job/601011","started_at":"2000-01-01T00:00:00Z","completed_at":"2000-01-01T00:01:00Z","check_suite":{"id":1011}},{"id":202,"name":"verify","status":"completed","conclusion":"failure","head_sha":"$merged_oid","app":{"id":15368,"slug":"github-actions"},"details_url":"https://github.com/$api_repo/actions/runs/501002/job/601002","started_at":"2099-01-01T00:00:00Z","completed_at":"2099-01-01T00:01:00Z","check_suite":{"id":1002}},{"id":212,"name":"verify","status":"completed","conclusion":"success","head_sha":"$merged_oid","app":{"id":15368,"slug":"github-actions"},"details_url":"https://github.com/$api_repo/actions/runs/501012/job/601012","started_at":"2000-01-01T00:00:00Z","completed_at":"2000-01-01T00:01:00Z","check_suite":{"id":1012}}]}
JSON
        ;;
      reverse-timestamp-duplicate:tonswap-org/ton-indexer)
        cat <<JSON
{"total_count":3,"check_runs":[{"id":201,"name":"validate","status":"completed","conclusion":"success","head_sha":"$merged_oid","app":{"id":15368,"slug":"github-actions"},"details_url":"https://github.com/$api_repo/actions/runs/501001/job/601001","started_at":"2099-01-01T00:00:00Z","completed_at":"2099-01-01T00:01:00Z","check_suite":{"id":1001}},{"id":211,"name":"validate","status":"completed","conclusion":"failure","head_sha":"$merged_oid","app":{"id":15368,"slug":"github-actions"},"details_url":"https://github.com/$api_repo/actions/runs/501011/job/601011","started_at":"2000-01-01T00:00:00Z","completed_at":"2000-01-01T00:01:00Z","check_suite":{"id":1011}},{"id":202,"name":"verify","status":"completed","conclusion":"success","head_sha":"$merged_oid","check_suite":{"id":1002}}]}
JSON
        ;;
      wrong-check-head-provenance:soramitsu/fearless-Android|secret-safe-provenance:soramitsu/fearless-Android)
        cat <<JSON
{"total_count":2,"check_runs":[{"id":101,"name":"validate","status":"completed","conclusion":"success","head_sha":"$drift_oid","details_url":"https://ci.invalid/result?token=CHECK_DETAILS_SECRET_SENTINEL","output":{"summary":"CHECK_OUTPUT_SECRET_SENTINEL"},"check_suite":{"id":1001}},{"id":102,"name":"build-and-test","status":"completed","conclusion":"success","head_sha":"$merged_oid","check_suite":{"id":1004}}]}
JSON
        ;;
      open-pending-check:soramitsu/fearless-Android)
        cat <<JSON
{"total_count":2,"check_runs":[{"id":101,"name":"validate","status":"completed","conclusion":"success","head_sha":"$merged_oid","check_suite":{"id":1001}},{"id":102,"name":"build-and-test","status":"in_progress","conclusion":null,"head_sha":"$merged_oid","check_suite":{"id":1004}}]}
JSON
        ;;
      exact-site-pr-49-pending:soramitsu/fearless-site-web)
        cat <<JSON
{"total_count":2,"check_runs":[{"id":101,"name":"validate","status":"completed","conclusion":"success","head_sha":"$merged_oid","check_suite":{"id":1001}},{"id":103,"name":"build","status":"in_progress","conclusion":null,"head_sha":"$merged_oid","check_suite":{"id":1003}}]}
JSON
        ;;
      exact-shared-features-pr-81-pending:soramitsu/shared-features-spm)
        cat <<JSON
{"total_count":1,"check_runs":[{"id":105,"name":"continuous-integration/jenkins/pr-merge","status":"queued","conclusion":null,"head_sha":"$merged_oid","check_suite":{"id":1005}}]}
JSON
        ;;
      exact-iroha-pr-5619-pending:hyperledger-iroha/iroha)
        cat <<JSON
{"total_count":1,"check_runs":[{"id":106,"name":"DCO","status":"queued","conclusion":null,"head_sha":"$merged_oid","check_suite":{"id":1006}}]}
JSON
        ;;
      *)
        case "$api_repo" in
          soramitsu/fearless-Android)
            cat <<JSON
{"total_count":2,"check_runs":[{"id":101,"name":"validate","status":"completed","conclusion":"success","head_sha":"$merged_oid","check_suite":{"id":1001}},{"id":102,"name":"build-and-test","status":"completed","conclusion":"success","head_sha":"$merged_oid","check_suite":{"id":1004}}]}
JSON
            ;;
          soramitsu/fearless-iOS)
            cat <<JSON
{"total_count":3,"check_runs":[{"id":101,"name":"validate","status":"completed","conclusion":"success","head_sha":"$merged_oid","check_suite":{"id":1001}},{"id":103,"name":"build","status":"completed","conclusion":"success","head_sha":"$merged_oid","check_suite":{"id":1003}},{"id":105,"name":"continuous-integration/jenkins/pr-merge","status":"completed","conclusion":"success","head_sha":"$merged_oid","check_suite":{"id":1005}}]}
JSON
            ;;
          soramitsu/shared-features-spm)
            cat <<JSON
{"total_count":1,"check_runs":[{"id":105,"name":"continuous-integration/jenkins/pr-merge","status":"completed","conclusion":"success","head_sha":"$merged_oid","check_suite":{"id":1005}}]}
JSON
            ;;
          soramitsu/fearless-wallet-web|tonswap-org/ton-indexer|solswap-io/solswap-indexer|sora-xor/polkaswap-indexer)
            cat <<JSON
{"total_count":2,"check_runs":[{"id":101,"name":"validate","status":"completed","conclusion":"success","head_sha":"$merged_oid","check_suite":{"id":1001}},{"id":102,"name":"verify","status":"completed","conclusion":"success","head_sha":"$merged_oid","check_suite":{"id":1002}}]}
JSON
            ;;
          soramitsu/fearless-site-web)
            cat <<JSON
{"total_count":2,"check_runs":[{"id":101,"name":"validate","status":"completed","conclusion":"success","head_sha":"$merged_oid","check_suite":{"id":1001}},{"id":103,"name":"build","status":"completed","conclusion":"success","head_sha":"$merged_oid","check_suite":{"id":1003}}]}
JSON
            ;;
          hyperledger-iroha/iroha)
            cat <<JSON
{"total_count":1,"check_runs":[{"id":106,"name":"DCO","status":"completed","conclusion":"success","head_sha":"$merged_oid","check_suite":{"id":1006}}]}
JSON
            ;;
          *)
            echo "unexpected REST check-runs query: $api_path" >&2
            exit 1
            ;;
        esac
        ;;
    esac
    exit 0
  fi

  if [[ "$api_path" == repos/*/commits/*/status* ]]; then
    if [[ "$api_path" != *"/status?per_page=100" ]]; then
      echo "required commit-status query must request the complete SHA-bound page" >&2
      exit 1
    fi
    api_repo="${api_path#repos/}"
    api_repo="${api_repo%%/commits/*}"
    api_oid="${api_path#repos/$api_repo/commits/}"
    api_oid="${api_oid%%/*}"

    case "$scenario:$api_repo" in
      exact-site-pr-49-pending:soramitsu/fearless-site-web)
        cat <<JSON
{"sha":"$merged_oid","total_count":1,"statuses":[{"id":301,"context":"Vercel","state":"pending"}]}
JSON
        ;;
      wrong-status-head-provenance:soramitsu/fearless-site-web)
        cat <<JSON
{"sha":"$drift_oid","total_count":1,"statuses":[{"id":301,"context":"Vercel","state":"success"}]}
JSON
        ;;
      malformed-status:soramitsu/fearless-site-web)
        echo '{"sha":"malformed","total_count":1,"statuses":{}}'
        ;;
      *:soramitsu/fearless-site-web)
        cat <<JSON
{"sha":"$merged_oid","total_count":1,"statuses":[{"id":301,"context":"Vercel","state":"success"}]}
JSON
        ;;
      *)
        cat <<JSON
{"sha":"$merged_oid","total_count":0,"statuses":[]}
JSON
        ;;
    esac
    exit 0
  fi

  if [[ "$api_path" == repos/*/actions/runs* && "$api_path" == *"check_suite_id="* ]]; then
    if [[ "$api_path" != *"&per_page=100" ]]; then
      echo "Actions workflow provenance query must request the complete suite-bound page" >&2
      exit 1
    fi
    api_repo="${api_path#repos/}"
    api_repo="${api_repo%%/actions/runs*}"
    suite_id="${api_path#*check_suite_id=}"
    suite_id="${suite_id%%&*}"
    workflow_id=9001
    workflow_path=".github/workflows/branch-flow.yml"
    case "$suite_id" in
      1002|1012)
        workflow_id=9002
        workflow_path=".github/workflows/ci.yml"
        ;;
    esac
    run_id=$((500000 + suite_id))
    workflow_sha="$merged_oid"
    workflow_repo="$api_repo"
    workflow_event="pull_request"
    case "$api_repo" in
      soramitsu/fearless-Android)
        workflow_head_branch="codex/android-universal-wallet-readiness"
        ;;
      solswap-io/solswap-indexer)
        workflow_head_branch="release/sync-develop-into-master"
        ;;
      tonswap-org/ton-indexer)
        workflow_head_branch="release/ton-health-identity-master"
        ;;
      *)
        workflow_head_branch="codex/test-head"
        ;;
    esac

    if [[ "$scenario" == "duplicate-missing-workflow" && "$suite_id" == "1011" ]]; then
      echo '{"total_count":0,"workflow_runs":[]}'
      exit 0
    fi
    if [[ "$scenario" == "duplicate-wrong-workflow" && "$suite_id" == "1011" ]]; then
      workflow_id=9999
      workflow_path=".github/workflows/untrusted.yml"
    fi
    if [[ "$scenario" == "duplicate-workflow-sha" && "$suite_id" == "1011" ]]; then
      workflow_sha="$drift_oid"
    fi
    if [[ "$scenario" == "duplicate-workflow-repository" && "$suite_id" == "1011" ]]; then
      workflow_repo="attacker/forged"
    fi
    if [[ "$scenario" == "cross-branch-conflicting-duplicate" && ( "$suite_id" == "1001" || "$suite_id" == "1002" ) ]]; then
      workflow_head_branch="codex/unrelated-same-sha"
    fi
    if [[ "$scenario" == "cross-branch-authoritative-failure" && "$suite_id" == "1001" ]]; then
      workflow_head_branch="codex/unrelated-same-sha"
    fi
    if [[ "$scenario" == "all-unrelated-duplicate" ]]; then
      workflow_head_branch="codex/unrelated-same-sha-$suite_id"
    fi
    if [[ "$scenario" == "duplicate-non-pr-event" ]]; then
      workflow_event="push"
    fi

    workflow_head_branch_json="\"$workflow_head_branch\""
    if [[ "$scenario" == "duplicate-workflow-head-branch-missing" && "$suite_id" == "1011" ]]; then
      workflow_head_branch_json="null"
    fi
    cat <<JSON
{"total_count":1,"workflow_runs":[{"id":$run_id,"check_suite_id":$suite_id,"head_sha":"$workflow_sha","head_branch":$workflow_head_branch_json,"event":"$workflow_event","workflow_id":$workflow_id,"path":"$workflow_path","repository":{"full_name":"$workflow_repo"},"head_repository":{"full_name":"$workflow_repo"}}]}
JSON
    exit 0
  fi

  if [[ "$api_path" == repos/*/check-suites/* ]]; then
    api_repo="${api_path#repos/}"
    api_repo="${api_repo%%/check-suites/*}"
    suite_id="${api_path##*/}"
    case "$scenario:$api_repo:$suite_id" in
      check-suite-query-fails:soramitsu/fearless-Android:1001)
        echo "suite request failed token=CHECK_SUITE_SECRET_SENTINEL" >&2
        exit 1
        ;;
      wrong-suite-sha-provenance:soramitsu/fearless-Android:1001)
        cat <<JSON
{"id":1001,"head_sha":"$drift_oid","private_payload":"CHECK_SUITE_PAYLOAD_SECRET_SENTINEL"}
JSON
        ;;
      wrong-suite-id-provenance:soramitsu/fearless-Android:1001)
        cat <<JSON
{"id":9999,"head_sha":"$merged_oid"}
JSON
        ;;
      duplicate-wrong-app:soramitsu/fearless-Android:1011)
        cat <<JSON
{"id":1011,"head_sha":"$merged_oid","app":{"id":99999,"slug":"github-actions"}}
JSON
        ;;
      *)
        cat <<JSON
{"id":$suite_id,"head_sha":"$merged_oid","app":{"id":15368,"slug":"github-actions"}}
JSON
        ;;
    esac
    exit 0
  fi

  api_repo="${api_path#repos/}"
  api_repo="${api_repo%%/git/matching-refs/heads/*}"
  api_head="${api_path#repos/$api_repo/git/matching-refs/heads/}"

  if [[ "$api_path" == "$api_repo" || -z "$api_repo" || -z "$api_head" ]]; then
    echo "unexpected gh api path: $api_path" >&2
    exit 2
  fi

  case "$api_repo" in
    soramitsu/fearless-Android|soramitsu/fearless-iOS|soramitsu/shared-features-spm|soramitsu/fearless-wallet-web|soramitsu/fearless-site-web|tonswap-org/ton-indexer|solswap-io/solswap-indexer|sora-xor/polkaswap-indexer|hyperledger-iroha/iroha)
      ;;
    *)
      echo "unexpected gh api repo=$api_repo head=$api_head" >&2
      exit 1
      ;;
  esac

  case "$scenario:$api_repo" in
    branch-ref-query-fails:soramitsu/fearless-Android)
      echo "GitHub branch-ref API unavailable" >&2
      exit 1
      ;;
    bad-branch-ref-json:soramitsu/fearless-Android)
      echo "{not-json"
      ;;
    merged-branch-deleted:soramitsu/fearless-wallet-web)
      echo "[]"
      ;;
    merged-branch-drift:soramitsu/fearless-wallet-web)
      cat <<JSON
[{"ref":"refs/heads/$api_head","object":{"sha":"$drift_oid"}}]
JSON
      ;;
    *)
      cat <<JSON
[{"ref":"refs/heads/$api_head","object":{"sha":"$merged_oid"}}]
JSON
      ;;
  esac
  exit 0
fi

if [[ "${1:-}" != "pr" || "${2:-}" != "list" ]]; then
  echo "expected gh pr list" >&2
  exit 2
fi
shift 2

while (($#)); do
  case "$1" in
    --repo)
      repo="$2"
      shift 2
      ;;
    --head)
      head="$2"
      shift 2
      ;;
    --base)
      base="$2"
      shift 2
      ;;
    --state)
      state="$2"
      shift 2
      ;;
    --json)
      json_fields="$2"
      shift 2
      ;;
    --limit)
      shift 2
      ;;
    *)
      shift
      ;;
  esac
done

case "$repo:$base" in
  soramitsu/*:develop|tonswap-org/ton-indexer:master|tonswap-org/ton-indexer:develop|solswap-io/solswap-indexer:master|solswap-io/solswap-indexer:develop|sora-xor/polkaswap-indexer:develop|sora-xor/polkaswap-indexer:master|hyperledger-iroha/iroha:optimizations)
    ;;
  *)
    echo "unexpected query repo=$repo head=$head base=$base state=$state" >&2
    exit 1
    ;;
esac

if [[ -z "$head" || "$state" != "all" ]]; then
  echo "unexpected query repo=$repo head=$head base=$base state=$state" >&2
  exit 1
fi

if [[ "$json_fields" != *"headRefOid"* || "$json_fields" != *"isDraft"* || "$json_fields" != *"reviewDecision"* || "$json_fields" != *"mergeStateStatus"* || "$json_fields" != *"reviews"* ]]; then
  echo "query is missing release-readiness fields" >&2
  exit 1
fi
if [[ "$json_fields" == *"statusCheckRollup"* ]]; then
  echo "PR query must not be used as unprovenanced required-check evidence" >&2
  exit 1
fi

success_checks() {
  case "$repo" in
    soramitsu/fearless-Android)
      printf '%s' '[{"name":"validate","status":"COMPLETED","conclusion":"SUCCESS"},{"name":"build-and-test","status":"COMPLETED","conclusion":"SUCCESS"}]'
      ;;
    soramitsu/fearless-iOS)
      printf '%s' '[{"name":"validate","status":"COMPLETED","conclusion":"SUCCESS"},{"name":"build","status":"COMPLETED","conclusion":"SUCCESS"},{"__typename":"StatusContext","context":"continuous-integration/jenkins/pr-merge","state":"SUCCESS"}]'
      ;;
    soramitsu/shared-features-spm)
      printf '%s' '[{"__typename":"StatusContext","context":"continuous-integration/jenkins/pr-merge","state":"SUCCESS"}]'
      ;;
    soramitsu/fearless-wallet-web)
      printf '%s' '[{"name":"validate","status":"COMPLETED","conclusion":"SUCCESS"},{"name":"verify","status":"COMPLETED","conclusion":"SUCCESS"}]'
      ;;
    soramitsu/fearless-site-web)
      printf '%s' '[{"name":"validate","status":"COMPLETED","conclusion":"SUCCESS"},{"name":"build","status":"COMPLETED","conclusion":"SUCCESS"},{"__typename":"StatusContext","context":"Vercel","state":"SUCCESS"}]'
      ;;
    tonswap-org/ton-indexer|solswap-io/solswap-indexer|sora-xor/polkaswap-indexer)
      printf '%s' '[{"name":"validate","status":"COMPLETED","conclusion":"SUCCESS"},{"name":"verify","status":"COMPLETED","conclusion":"SUCCESS"}]'
      ;;
    hyperledger-iroha/iroha)
      printf '%s' '[{"name":"DCO","status":"COMPLETED","conclusion":"SUCCESS"}]'
      ;;
    *)
      printf '%s' '[{"name":"validate","status":"COMPLETED","conclusion":"SUCCESS"}]'
      ;;
  esac
}

if [[ "$scenario" == "rest-fallback-merged" && "$repo" == "tonswap-org/ton-indexer" && "$head" == "hotfix/production-smoke-diagnostics" ]]; then
  echo "GraphQL: Something went wrong while executing your query" >&2
  exit 1
fi

case "$scenario:$repo" in
  merged:*|exact-ton-pr-12-merged:tonswap-org/ton-indexer|exact-site-pr-49-merged:soramitsu/fearless-site-web|exact-shared-features-pr-81-merged:soramitsu/shared-features-spm|exact-iroha-pr-5619-merged:hyperledger-iroha/iroha)
    cat <<JSON
[{"number":$pr_number,"url":"https://github.com/$repo/pull/$pr_number","state":"MERGED","mergedAt":"2026-06-26T12:00:00Z","headRefOid":"$merged_oid","isDraft":false,"reviewDecision":"APPROVED","mergeStateStatus":"CLEAN","statusCheckRollup":$(success_checks)}]
JSON
    ;;
  open-review-required:soramitsu/fearless-iOS|review-thread-query-fails:soramitsu/fearless-iOS|malformed-review-threads:soramitsu/fearless-iOS|missing-review-thread-id:soramitsu/fearless-iOS|open-polkaswap-hotfix:sora-xor/polkaswap-indexer|exact-ton-pr-12-open:tonswap-org/ton-indexer|exact-site-pr-49-open:soramitsu/fearless-site-web|exact-site-pr-49-pending:soramitsu/fearless-site-web|exact-shared-features-pr-81-open:soramitsu/shared-features-spm|exact-shared-features-pr-81-pending:soramitsu/shared-features-spm|exact-iroha-pr-5619-open:hyperledger-iroha/iroha|exact-iroha-pr-5619-pending:hyperledger-iroha/iroha)
    cat <<JSON
[{"number":$pr_number,"url":"https://github.com/$repo/pull/$pr_number","state":"OPEN","mergedAt":null,"headRefOid":"$merged_oid","isDraft":false,"reviewDecision":"REVIEW_REQUIRED","mergeStateStatus":"BLOCKED","statusCheckRollup":$(success_checks),"reviews":[]}]
JSON
    ;;
  open-draft:soramitsu/fearless-site-web)
    cat <<JSON
[{"number":42,"url":"https://github.com/$repo/pull/42","state":"OPEN","mergedAt":null,"headRefOid":"$merged_oid","isDraft":true,"reviewDecision":"REVIEW_REQUIRED","mergeStateStatus":"DRAFT","statusCheckRollup":$(success_checks),"reviews":[]}]
JSON
    ;;
  open-pending-check:soramitsu/fearless-Android)
    cat <<JSON
[{"number":42,"url":"https://github.com/$repo/pull/42","state":"OPEN","mergedAt":null,"headRefOid":"$merged_oid","isDraft":false,"reviewDecision":"APPROVED","mergeStateStatus":"BLOCKED","statusCheckRollup":[{"name":"build-and-test","status":"COMPLETED","conclusion":"SUCCESS","completedAt":"2099-01-01T00:00:00Z"}],"reviews":[{"state":"APPROVED","submittedAt":"2026-06-26T12:00:00Z","commit":{"oid":"$merged_oid"}}]}]
JSON
    ;;
  open-outdated-only:soramitsu/fearless-wallet-web)
    cat <<JSON
[{"number":42,"url":"https://github.com/$repo/pull/42","state":"OPEN","mergedAt":null,"headRefOid":"$merged_oid","isDraft":false,"reviewDecision":"REVIEW_REQUIRED","mergeStateStatus":"BLOCKED","statusCheckRollup":$(success_checks),"reviews":[]}]
JSON
    ;;
  open-supersedes-merged:soramitsu/fearless-iOS)
    cat <<JSON
[{"number":41,"url":"https://github.com/$repo/pull/41","state":"MERGED","mergedAt":"2026-06-25T12:00:00Z","headRefOid":"$merged_oid","isDraft":false,"reviewDecision":"APPROVED","mergeStateStatus":"CLEAN","statusCheckRollup":$(success_checks),"reviews":[]},{"number":42,"url":"https://github.com/$repo/pull/42","state":"OPEN","mergedAt":null,"headRefOid":"$merged_oid","isDraft":false,"reviewDecision":"REVIEW_REQUIRED","mergeStateStatus":"BLOCKED","statusCheckRollup":$(success_checks),"reviews":[]}]
JSON
    ;;
  open-current-ineligible-approval:soramitsu/fearless-Android)
    cat <<JSON
[{"number":42,"url":"https://github.com/$repo/pull/42","state":"OPEN","mergedAt":null,"headRefOid":"$merged_oid","isDraft":false,"reviewDecision":"REVIEW_REQUIRED","mergeStateStatus":"BLOCKED","statusCheckRollup":$(success_checks),"reviews":[{"state":"APPROVED","submittedAt":"2026-06-26T12:00:00Z","commit":{"oid":"$merged_oid"}}]}]
JSON
    ;;
  open-stale-approval:soramitsu/fearless-Android)
    cat <<JSON
[{"number":42,"url":"https://github.com/$repo/pull/42","state":"OPEN","mergedAt":null,"headRefOid":"$merged_oid","isDraft":false,"reviewDecision":"REVIEW_REQUIRED","mergeStateStatus":"BLOCKED","statusCheckRollup":$(success_checks),"reviews":[{"state":"APPROVED","submittedAt":"2026-06-26T12:00:00Z","commit":{"oid":"$drift_oid"}}]}]
JSON
    ;;
  open-unavailable-review-details:soramitsu/fearless-Android)
    cat <<JSON
[{"number":42,"url":"https://github.com/$repo/pull/42","state":"OPEN","mergedAt":null,"headRefOid":"$merged_oid","isDraft":false,"reviewDecision":"REVIEW_REQUIRED","mergeStateStatus":"BLOCKED","statusCheckRollup":$(success_checks)}]
JSON
    ;;
  open-malformed-review-details:soramitsu/fearless-Android)
    cat <<JSON
[{"number":42,"url":"https://github.com/$repo/pull/42","state":"OPEN","mergedAt":null,"headRefOid":"$merged_oid","isDraft":false,"reviewDecision":"REVIEW_REQUIRED","mergeStateStatus":"BLOCKED","statusCheckRollup":$(success_checks),"reviews":{}}]
JSON
    ;;
  closed-unmerged:soramitsu/fearless-wallet-web)
    cat <<JSON
[{"number":42,"url":"https://github.com/$repo/pull/42","state":"CLOSED","mergedAt":null,"headRefOid":"$merged_oid","isDraft":false,"reviewDecision":"APPROVED","mergeStateStatus":"UNKNOWN","statusCheckRollup":[]}]
JSON
    ;;
  missing-pr:soramitsu/fearless-wallet-web)
    echo "[]"
    ;;
  bad-json:soramitsu/fearless-Android)
    echo "{not-json"
    ;;
  query-fails:soramitsu/fearless-Android)
    echo "GitHub API unavailable token=PR_QUERY_SECRET_SENTINEL" >&2
    exit 1
    ;;
  noncanonical-pr-url:soramitsu/fearless-Android)
    cat <<JSON
[{"number":42,"url":"https://github.com/attacker/forged/pull/42?token=PR_URL_SECRET_SENTINEL","state":"MERGED","mergedAt":"2026-06-26T12:00:00Z","headRefOid":"$merged_oid","isDraft":false,"reviewDecision":"APPROVED","mergeStateStatus":"CLEAN","reviews":[]}]
JSON
    ;;
  duplicate-pinned-pr-record:soramitsu/fearless-Android)
    cat <<JSON
[{"number":42,"url":"https://github.com/$repo/pull/42","state":"MERGED","mergedAt":"2026-06-26T12:00:00Z","headRefOid":"$merged_oid","isDraft":false,"reviewDecision":"APPROVED","mergeStateStatus":"CLEAN","reviews":[]},{"number":42,"url":"https://github.com/$repo/pull/42","state":"MERGED","mergedAt":"2026-06-26T12:00:00Z","headRefOid":"$merged_oid","isDraft":false,"reviewDecision":"APPROVED","mergeStateStatus":"CLEAN","reviews":[]}]
JSON
    ;;
  *)
    cat <<JSON
[{"number":42,"url":"https://github.com/$repo/pull/42","state":"MERGED","mergedAt":"2026-06-26T12:01:00Z","headRefOid":"$merged_oid","isDraft":false,"reviewDecision":"APPROVED","mergeStateStatus":"CLEAN","statusCheckRollup":[{"name":"validate","status":"COMPLETED","conclusion":"SUCCESS","completedAt":"2099-12-31T23:59:59Z","detailsUrl":"https://ci.invalid/?token=UNTRUSTED_ROLLUP_SECRET_SENTINEL"}]}]
JSON
    ;;
esac
SH

chmod +x "$fake_gh"

run_audit() {
  local scenario="$1"
  shift
  FAKE_GH_SCENARIO="$scenario" GH_BIN="$fake_gh" bash "$AUDIT_SCRIPT" --config "$config_file" "$@"
}

expect_success() {
  local name="$1"
  local scenario="$2"
  local output
  if ! output="$(run_audit "$scenario" 2>&1)"; then
    echo "$output" >&2
    fail "$name unexpectedly failed"
  fi
}

expect_failure() {
  local name="$1"
  local scenario="$2"
  local expected="$3"
  local output
  set +e
  output="$(run_audit "$scenario" 2>&1)"
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

expect_secret_safe_failure() {
  local name="$1"
  local scenario="$2"
  local expected="$3"
  shift 3
  local output forbidden
  set +e
  output="$(run_audit "$scenario" 2>&1)"
  local status=$?
  set -e
  if [[ "$status" -eq 0 || "$output" != *"$expected"* ]]; then
    echo "$output" >&2
    fail "$name did not fail with expected safe diagnostic: $expected"
  fi
  for forbidden in "$@"; do
    if [[ "$output" == *"$forbidden"* ]]; then
      echo "$output" >&2
      fail "$name leaked forbidden diagnostic content: $forbidden"
    fi
  done
}

write_config
expect_success "merged fixture" merged

write_single_config \
  tonswap-org/ton-indexer \
  release/ton-indexer-master-sync-20260701 \
  master merged validate,verify 12 "$ton_pr_12_head_oid"
expect_success "exact TON PR 12 refreshed immutable pin fixture" exact-ton-pr-12-merged

write_single_config \
  tonswap-org/ton-indexer \
  release/ton-indexer-master-sync-20260701 \
  master merged validate,verify 13 "$ton_pr_12_head_oid"
expect_failure \
  "exact TON PR 12 number mutation fixture" \
  exact-ton-pr-12-merged \
  "reviewedPrNumberPinMismatch expected=13 available=12"

write_single_config \
  tonswap-org/ton-indexer \
  release/ton-indexer-master-sync-20260701 \
  master merged validate,verify 12 "$expected_drift_oid"
expect_failure \
  "exact TON PR 12 head mutation fixture" \
  exact-ton-pr-12-merged \
  "reviewedHeadShaPinMismatch expected=$expected_drift_oid actual=$ton_pr_12_head_oid"

write_single_config \
  tonswap-org/ton-indexer \
  release/ton-indexer-master-sync-20260701 \
  master merged validate,verify 12 "$ton_pr_12_head_oid"
expect_failure \
  "open exact TON PR 12 remains merge-blocking fixture" \
  exact-ton-pr-12-open \
  "tonswap-org/ton-indexer#12 is open and is not release-ready"

write_single_config \
  soramitsu/fearless-site-web \
  fix/app-association-publication \
  develop merged validate,build,Vercel 49 "$site_pr_49_head_oid"
expect_success "exact website association PR 49 immutable pin fixture" exact-site-pr-49-merged

write_single_config \
  soramitsu/fearless-site-web \
  fix/app-association-publication \
  develop merged validate,build,Vercel 50 "$site_pr_49_head_oid"
expect_failure \
  "exact website association PR 49 number mutation fixture" \
  exact-site-pr-49-merged \
  "reviewedPrNumberPinMismatch expected=50 available=49"

write_single_config \
  soramitsu/fearless-site-web \
  fix/app-association-publication \
  develop merged validate,build,Vercel 49 "$expected_drift_oid"
expect_failure \
  "exact website association PR 49 head mutation fixture" \
  exact-site-pr-49-merged \
  "reviewedHeadShaPinMismatch expected=$expected_drift_oid actual=$site_pr_49_head_oid"

write_single_config \
  soramitsu/fearless-site-web \
  fix/app-association-publication \
  develop merged validate,build,Vercel 49 "$site_pr_49_head_oid"
expect_failure \
  "open exact website association PR 49 remains merge-blocking fixture" \
  exact-site-pr-49-open \
  "soramitsu/fearless-site-web#49 is open and is not release-ready"

write_single_config \
  soramitsu/fearless-site-web \
  fix/app-association-publication \
  develop merged validate,build,Vercel 49 "$site_pr_49_head_oid"
expect_failure \
  "pending exact website association PR 49 checks remain merge-blocking fixture" \
  exact-site-pr-49-pending \
  "incompleteRequiredChecks=build:IN_PROGRESS/PENDING,Vercel:STATUS/PENDING"

write_single_config \
  soramitsu/shared-features-spm \
  codex/ios-shared-features-delta-20260731 \
  develop merged continuous-integration/jenkins/pr-merge 81 "$shared_features_pr_81_head_oid"
expect_success "exact shared-features PR 81 immutable pin fixture" exact-shared-features-pr-81-merged

write_single_config \
  soramitsu/shared-features-spm \
  codex/ios-shared-features-delta-20260731 \
  develop merged continuous-integration/jenkins/pr-merge 82 "$shared_features_pr_81_head_oid"
expect_failure \
  "exact shared-features PR 81 number mutation fixture" \
  exact-shared-features-pr-81-merged \
  "reviewedPrNumberPinMismatch expected=82 available=81"

write_single_config \
  soramitsu/shared-features-spm \
  codex/ios-shared-features-delta-20260731 \
  develop merged continuous-integration/jenkins/pr-merge 81 "$expected_drift_oid"
expect_failure \
  "exact shared-features PR 81 head mutation fixture" \
  exact-shared-features-pr-81-merged \
  "reviewedHeadShaPinMismatch expected=$expected_drift_oid actual=$shared_features_pr_81_head_oid"

write_single_config \
  soramitsu/shared-features-spm \
  codex/ios-shared-features-delta-20260731 \
  develop merged continuous-integration/jenkins/pr-merge 81 "$shared_features_pr_81_head_oid"
expect_failure \
  "open exact shared-features PR 81 remains merge-blocking fixture" \
  exact-shared-features-pr-81-open \
  "soramitsu/shared-features-spm#81 is open and is not release-ready"

write_single_config \
  soramitsu/shared-features-spm \
  codex/ios-shared-features-delta-20260731 \
  develop merged continuous-integration/jenkins/pr-merge 81 "$shared_features_pr_81_head_oid"
expect_failure \
  "pending exact shared-features PR 81 Jenkins remains merge-blocking fixture" \
  exact-shared-features-pr-81-pending \
  "incompleteRequiredChecks=continuous-integration/jenkins/pr-merge:QUEUED/PENDING"

write_single_config \
  hyperledger-iroha/iroha \
  codex/fearless-production-consolidated-20260731 \
  optimizations merged DCO 5619 "$iroha_consolidated_pr_5619_head_oid"
expect_success "exact consolidated Iroha PR 5619 immutable pin fixture" exact-iroha-pr-5619-merged

write_single_config \
  hyperledger-iroha/iroha \
  codex/fearless-production-consolidated-20260731 \
  optimizations merged DCO 5618 "$iroha_consolidated_pr_5619_head_oid"
expect_failure \
  "exact consolidated Iroha PR 5619 number mutation fixture" \
  exact-iroha-pr-5619-merged \
  "reviewedPrNumberPinMismatch expected=5618 available=5619"

write_single_config \
  hyperledger-iroha/iroha \
  codex/fearless-production-consolidated-20260731 \
  optimizations merged DCO 5619 "$expected_drift_oid"
expect_failure \
  "exact consolidated Iroha PR 5619 head mutation fixture" \
  exact-iroha-pr-5619-merged \
  "reviewedHeadShaPinMismatch expected=$expected_drift_oid actual=$iroha_consolidated_pr_5619_head_oid"

write_single_config \
  hyperledger-iroha/iroha \
  codex/fearless-production-consolidated-20260731 \
  optimizations merged DCO 5619 "$iroha_consolidated_pr_5619_head_oid"
expect_failure \
  "open exact consolidated Iroha PR 5619 remains merge-blocking fixture" \
  exact-iroha-pr-5619-open \
  "hyperledger-iroha/iroha#5619 is open and is not release-ready"

write_single_config \
  hyperledger-iroha/iroha \
  codex/fearless-production-consolidated-20260731 \
  optimizations merged DCO 5619 "$iroha_consolidated_pr_5619_head_oid"
expect_failure \
  "pending exact consolidated Iroha PR 5619 DCO remains merge-blocking fixture" \
  exact-iroha-pr-5619-pending \
  "incompleteRequiredChecks=DCO:QUEUED/PENDING"

write_config
merged_report="$tmp_dir/merged-report.json"
if ! merged_report_output="$(run_audit merged --write-report "$merged_report" 2>&1)"; then
  echo "$merged_report_output" >&2
  fail "merged report fixture unexpectedly failed"
fi
node - "$merged_report" <<'NODE'
const fs = require('fs')
const file = process.argv[2]
if (!fs.existsSync(file)) throw new Error('report file missing')
const report = JSON.parse(fs.readFileSync(file, 'utf8'))
if (report.schemaVersion !== 1) throw new Error('schemaVersion mismatch')
if (report.status !== 'passed') throw new Error(`status mismatch: ${report.status}`)
if (report.checkedCount !== 34) throw new Error(`checkedCount mismatch: ${report.checkedCount}`)
if (report.totals.passed !== 34 || report.totals.failed !== 0 || report.totals.total !== 34) {
  throw new Error(`totals mismatch: ${JSON.stringify(report.totals)}`)
}
if (!Array.isArray(report.failures) || report.failures.length !== 0) throw new Error('success report failures mismatch')
if (!Array.isArray(report.requirements) || report.requirements.length !== 34) throw new Error('requirements length mismatch')
if (!report.requirements.every((record) => record.status === 'passed' && record.pr?.url?.startsWith('https://github.com/'))) {
  throw new Error('success report missing passed PR records')
}
if (!report.requirements.every((record) => Array.isArray(record.requiredChecks) && record.requiredChecks.length > 0)) {
  throw new Error('success report missing required checks')
}
NODE

write_config
failed_report="$tmp_dir/failed-report.json"
set +e
failed_report_output="$(run_audit open-current-ineligible-approval --write-report "$failed_report" 2>&1)"
failed_report_status=$?
set -e
if [[ "$failed_report_status" -eq 0 ]]; then
  echo "$failed_report_output" >&2
  fail "failed report fixture unexpectedly passed"
fi
node - "$failed_report" <<'NODE'
const fs = require('fs')
const file = process.argv[2]
if (!fs.existsSync(file)) throw new Error('report file missing')
const report = JSON.parse(fs.readFileSync(file, 'utf8'))
if (report.schemaVersion !== 1) throw new Error('schemaVersion mismatch')
if (report.status !== 'failed') throw new Error(`status mismatch: ${report.status}`)
if (report.checkedCount !== 34) throw new Error(`checkedCount mismatch: ${report.checkedCount}`)
if (report.totals.total !== 34 || report.totals.failed < 1) throw new Error(`totals mismatch: ${JSON.stringify(report.totals)}`)
if (!Array.isArray(report.failures) || report.failures.length !== report.totals.failed) throw new Error('failure report failures mismatch')
if (!Array.isArray(report.requirements) || report.requirements.length !== 34) throw new Error('requirements length mismatch')
const failed = report.requirements.filter((record) => record.status === 'failed')
if (failed.length !== report.totals.failed) throw new Error('failed requirement count mismatch')
if (JSON.stringify(report.failures) !== JSON.stringify(failed.map((record) => record.message))) {
  throw new Error('failure messages must match failed requirement messages')
}
if (!failed.some((record) => record.currentApprovalNotEligible === true && record.currentHeadApprovalCount > 0)) {
  throw new Error('failure report missing approval eligibility diagnostics')
}
NODE

write_config
set +e
rest_fallback_output="$(run_audit rest-fallback-merged 2>&1)"
rest_fallback_status=$?
set -e
if [[ "$rest_fallback_status" -ne 0 ]]; then
  echo "$rest_fallback_output" >&2
  fail "REST fallback merged fixture unexpectedly failed"
fi
if [[ "$rest_fallback_output" != *"using REST fallback for PR state"* || "$rest_fallback_output" != *"tonswap-org/ton-indexer#42 is merged with required checks validate,verify"* ]]; then
  echo "$rest_fallback_output" >&2
  fail "REST fallback merged fixture did not report fallback use and merged PR readiness"
fi

write_config
expect_success "merged branch deleted fixture" merged-branch-deleted

write_single_config \
  soramitsu/fearless-wallet-web \
  codex/web-bitcoin-broadcast-evidence \
  develop merged validate,verify 42 "$expected_merged_oid"
expect_success "exact pin permits reviewed merged PR after branch deletion" merged-branch-deleted

printf '%s\n' "soramitsu/fearless-wallet-web	codex/web-bitcoin-broadcast-evidence	develop	merged	validate,verify" > "$config_file"
expect_failure \
  "deleted branch without immutable PR/head pin fixture" \
  merged-branch-deleted \
  "missing immutable reviewed PR number/head commit pin"

write_single_config \
  soramitsu/fearless-wallet-web \
  codex/web-bitcoin-broadcast-evidence \
  develop merged validate,verify 41 "$expected_merged_oid"
expect_failure "stale reviewed PR number pin fixture" merged-branch-deleted "reviewedPrNumberPinMismatch expected=41"

write_single_config \
  soramitsu/fearless-wallet-web \
  codex/web-bitcoin-broadcast-evidence \
  develop merged validate,verify 42 "$expected_drift_oid"
expect_failure "mismatched reviewed head SHA pin fixture" merged-branch-deleted "reviewedHeadShaPinMismatch expected=$expected_drift_oid actual=$expected_merged_oid"

write_config
expect_failure "merged branch drift fixture" merged-branch-drift "has new commits after merge"

write_config
expect_failure "bad branch-ref JSON fixture" bad-branch-ref-json "gh returned invalid branch-ref JSON"

write_config
expect_failure "branch-ref query failure fixture" branch-ref-query-fails "unable to query current PR head branch ref"

write_config
expect_secret_safe_failure \
  "secret-safe PR query failure fixture" \
  query-fails \
  "unable to query PR state; primary and REST response details suppressed" \
  PR_QUERY_SECRET_SENTINEL

write_config
expect_secret_safe_failure \
  "secret-safe noncanonical PR URL fixture" \
  noncanonical-pr-url \
  "has invalid canonical PR URL" \
  PR_URL_SECRET_SENTINEL

write_config
expect_failure "ambiguous duplicate pinned PR record fixture" duplicate-pinned-pr-record "ambiguous reviewed PR pin"

write_config
set +e
review_required_output="$(run_audit open-review-required 2>&1)"
review_required_status=$?
set -e
if [[ "$review_required_status" -eq 0 ]]; then
  echo "$review_required_output" >&2
  fail "open review-required fixture unexpectedly passed"
fi
if [[ "$review_required_output" != *"reviewDecision=REVIEW_REQUIRED"* || "$review_required_output" != *"eligibleReviewerApprovalRequired=true"* || "$review_required_output" != *"approvalCount=0"* || "$review_required_output" != *"currentHeadApprovalCount=0"* || "$review_required_output" != *"https://github.com/soramitsu/fearless-iOS/pull/42"* || "$review_required_output" != *"unresolvedReviewThreads=2"* || "$review_required_output" != *"currentUnresolvedReviewThreads=1"* || "$review_required_output" != *"outdatedUnresolvedReviewThreads=1"* || "$review_required_output" != *"reviewConversationResolutionRequired=true"* || "$review_required_output" != *"unresolvedReviewThreadRefs=current:fearless/Common/Model/SolanaIndexerContract.swift:154:https://github.com/soramitsu/fearless-iOS/pull/42#discussion_r1;outdated:fearless/Common/Model/BitcoinBalanceContract.swift:88:https://github.com/soramitsu/fearless-iOS/pull/42#discussion_r3"* || "$review_required_output" != *"unresolvedReviewThreadIds=PRRT_ios_current,PRRT_ios_outdated"* ]]; then
  echo "$review_required_output" >&2
  fail "open review-required fixture did not preserve PR URL, review state, approval diagnostics, unresolved review-thread counts, thread refs, and thread IDs"
fi
if [[ "$review_required_output" == *"required release PR is not merged"* ]]; then
  echo "$review_required_output" >&2
  fail "open review-required fixture regressed to a generic final failure"
fi

write_single_config sora-xor/polkaswap-indexer hotfix/migration-replay-order master merged validate,verify
expect_failure \
  "open Polkaswap migration replay-order production blocker fixture" \
  open-polkaswap-hotfix \
  "sora-xor/polkaswap-indexer#42 is open and is not release-ready"

write_config
set +e
current_ineligible_output="$(run_audit open-current-ineligible-approval 2>&1)"
current_ineligible_status=$?
set -e
if [[ "$current_ineligible_status" -eq 0 ]]; then
  echo "$current_ineligible_output" >&2
  fail "open current ineligible approval fixture unexpectedly passed"
fi
if [[ "$current_ineligible_output" != *"eligibleReviewerApprovalRequired=true"* || "$current_ineligible_output" != *"approvalCount=1"* || "$current_ineligible_output" != *"currentHeadApprovalCount=1"* || "$current_ineligible_output" != *"currentApprovalNotEligible=true"* || "$current_ineligible_output" != *"latestApprovalCommit=$expected_merged_oid"* ]]; then
  echo "$current_ineligible_output" >&2
  fail "open current ineligible approval fixture did not report current approval eligibility diagnostics"
fi

write_config
set +e
stale_approval_output="$(run_audit open-stale-approval 2>&1)"
stale_approval_status=$?
set -e
if [[ "$stale_approval_status" -eq 0 ]]; then
  echo "$stale_approval_output" >&2
  fail "open stale approval fixture unexpectedly passed"
fi
if [[ "$stale_approval_output" != *"eligibleReviewerApprovalRequired=true"* || "$stale_approval_output" != *"approvalCount=1"* || "$stale_approval_output" != *"currentHeadApprovalCount=0"* || "$stale_approval_output" != *"staleApprovalCount=1"* || "$stale_approval_output" != *"freshApprovalRequired=true"* || "$stale_approval_output" != *"latestApprovalCommit=$expected_drift_oid"* ]]; then
  echo "$stale_approval_output" >&2
  fail "open stale approval fixture did not report stale approval diagnostics"
fi

write_config
expect_failure "open unavailable review details fixture" open-unavailable-review-details "reviewDetails=unavailable"

write_config
expect_failure "open malformed review details fixture" open-malformed-review-details "reviewDetails=malformed"

write_config
expect_failure "open draft fixture" open-draft "isDraft=true"

write_config
expect_failure "open pending-check fixture" open-pending-check "build-and-test:IN_PROGRESS/PENDING"

write_config
set +e
outdated_only_output="$(run_audit open-outdated-only 2>&1)"
outdated_only_status=$?
set -e
if [[ "$outdated_only_status" -eq 0 ]]; then
  echo "$outdated_only_output" >&2
  fail "open outdated-only review thread fixture unexpectedly passed"
fi
if [[ "$outdated_only_output" != *"unresolvedReviewThreads=1"* || "$outdated_only_output" != *"currentUnresolvedReviewThreads=0"* || "$outdated_only_output" != *"outdatedUnresolvedReviewThreads=1"* || "$outdated_only_output" != *"reviewConversationResolutionRequired=true"* || "$outdated_only_output" != *"outdatedReviewThreadsStillBlockMerge=true"* || "$outdated_only_output" != *"outdated:scripts/audit-bitcoin-broadcast-evidence.sh:284:https://github.com/soramitsu/fearless-wallet-web/pull/42#discussion_r3478239652"* || "$outdated_only_output" != *"unresolvedReviewThreadIds=PRRT_web_outdated"* ]]; then
  echo "$outdated_only_output" >&2
  fail "open outdated-only fixture did not report conversation-resolution, stale-thread merge blockers, and thread IDs"
fi

write_config
expect_failure "review thread query failure fixture" review-thread-query-fails "reviewThreadsQuery=failed:GitHub review-thread query failed; response details suppressed"

write_config
expect_failure "malformed review thread fixture" malformed-review-threads "malformedReviewThreads=1"

write_config
expect_failure "missing review thread id fixture" missing-review-thread-id "malformedReviewThreads=1"

write_config
expect_failure "open supersedes stale merged fixture" open-supersedes-merged "https://github.com/soramitsu/fearless-iOS/pull/42"

write_config
expect_failure "closed unmerged fixture" closed-unmerged "closed without merge"

write_config
expect_failure "missing required-check fixture" missing-required-check "missingRequiredChecks=verify"

write_config
expect_failure "skipped required-check fixture" skipped-required-check "incompleteRequiredChecks=validate:COMPLETED/SKIPPED"

write_single_config soramitsu/fearless-Android codex/android-universal-wallet-readiness develop merged validate,build-and-test
expect_failure \
  "duplicate required-check fixture missing provenance pin" \
  duplicate-required-check \
  "invalidRequiredCheckProvenance=validate:duplicate-check-provenance-pin-missing"

write_single_config soramitsu/fearless-Android codex/android-universal-wallet-readiness develop merged validate,build-and-test
append_duplicate_check_provenance_pin soramitsu/fearless-Android codex/android-universal-wallet-readiness develop validate 9001 .github/workflows/branch-flow.yml
expect_success "fully provenanced successful duplicate required-check fixture" duplicate-required-check

write_single_config solswap-io/solswap-indexer release/sync-develop-into-master master merged validate,verify
append_duplicate_check_provenance_pin solswap-io/solswap-indexer release/sync-develop-into-master master validate 9001 .github/workflows/branch-flow.yml
append_duplicate_check_provenance_pin solswap-io/solswap-indexer release/sync-develop-into-master master verify 9002 .github/workflows/ci.yml
expect_success \
  "exact PR-head checks ignore conflicting same-SHA checks from another branch" \
  cross-branch-conflicting-duplicate

write_single_config soramitsu/fearless-Android codex/android-universal-wallet-readiness develop merged validate,build-and-test
append_duplicate_check_provenance_pin soramitsu/fearless-Android codex/android-universal-wallet-readiness develop validate 9001 .github/workflows/branch-flow.yml
expect_failure \
  "exact PR-head failure is not hidden by an unrelated same-SHA success" \
  cross-branch-authoritative-failure \
  "incompleteRequiredChecks=validate:COMPLETED/FAILURE"

write_single_config soramitsu/fearless-Android codex/android-universal-wallet-readiness develop merged validate,build-and-test
append_duplicate_check_provenance_pin soramitsu/fearless-Android codex/android-universal-wallet-readiness develop validate 9001 .github/workflows/branch-flow.yml
expect_failure \
  "all duplicate checks from unrelated branches fail closed" \
  all-unrelated-duplicate \
  "invalidRequiredCheckProvenance=validate:actions-workflow-required-head-pull-request-missing"

write_single_config soramitsu/fearless-Android codex/android-universal-wallet-readiness develop merged validate,build-and-test
append_duplicate_check_provenance_pin soramitsu/fearless-Android codex/android-universal-wallet-readiness develop validate 9001 .github/workflows/branch-flow.yml
expect_failure \
  "missing duplicate workflow head-branch provenance fails closed" \
  duplicate-workflow-head-branch-missing \
  "invalidRequiredCheckProvenance=validate:actions-workflow-head-branch-missing"

write_single_config soramitsu/fearless-Android codex/android-universal-wallet-readiness develop merged validate,build-and-test
append_duplicate_check_provenance_pin soramitsu/fearless-Android codex/android-universal-wallet-readiness develop validate 9001 .github/workflows/branch-flow.yml
expect_failure \
  "non-PR duplicate workflow events cannot satisfy exact-head provenance" \
  duplicate-non-pr-event \
  "invalidRequiredCheckProvenance=validate:actions-workflow-required-head-pull-request-missing"

write_single_config soramitsu/fearless-Android codex/android-universal-wallet-readiness develop merged validate,build-and-test
append_duplicate_check_provenance_pin soramitsu/fearless-Android codex/android-universal-wallet-readiness develop validate 9001 .github/workflows/branch-flow.yml
expect_failure \
  "duplicate wrong SHA provenance fixture" \
  duplicate-wrong-sha \
  "invalidRequiredCheckProvenance=validate:check-run-head-sha-mismatch"

write_single_config soramitsu/fearless-Android codex/android-universal-wallet-readiness develop merged validate,build-and-test
append_duplicate_check_provenance_pin soramitsu/fearless-Android codex/android-universal-wallet-readiness develop validate 9001 .github/workflows/branch-flow.yml
expect_failure \
  "duplicate wrong GitHub app provenance fixture" \
  duplicate-wrong-app \
  "invalidRequiredCheckProvenance=validate:check-run-app-mismatch"

write_single_config soramitsu/fearless-Android codex/android-universal-wallet-readiness develop merged validate,build-and-test
append_duplicate_check_provenance_pin soramitsu/fearless-Android codex/android-universal-wallet-readiness develop validate 9001 .github/workflows/branch-flow.yml
expect_failure \
  "duplicate wrong workflow provenance fixture" \
  duplicate-wrong-workflow \
  "invalidRequiredCheckProvenance=validate:actions-workflow-id-mismatch"

write_single_config soramitsu/fearless-Android codex/android-universal-wallet-readiness develop merged validate,build-and-test
append_duplicate_check_provenance_pin soramitsu/fearless-Android codex/android-universal-wallet-readiness develop validate 9001 .github/workflows/branch-flow.yml
expect_failure \
  "duplicate missing workflow provenance fixture" \
  duplicate-missing-workflow \
  "invalidRequiredCheckProvenance=validate:actions-workflow-provenance-missing"

write_single_config soramitsu/fearless-Android codex/android-universal-wallet-readiness develop merged validate,build-and-test
append_duplicate_check_provenance_pin soramitsu/fearless-Android codex/android-universal-wallet-readiness develop validate 9001 .github/workflows/branch-flow.yml
expect_failure \
  "duplicate workflow SHA provenance fixture" \
  duplicate-workflow-sha \
  "invalidRequiredCheckProvenance=validate:actions-workflow-head-sha-mismatch"

write_single_config soramitsu/fearless-Android codex/android-universal-wallet-readiness develop merged validate,build-and-test
append_duplicate_check_provenance_pin soramitsu/fearless-Android codex/android-universal-wallet-readiness develop validate 9001 .github/workflows/branch-flow.yml
expect_failure \
  "duplicate workflow repository provenance fixture" \
  duplicate-workflow-repository \
  "invalidRequiredCheckProvenance=validate:actions-workflow-repository-mismatch"

write_single_config solswap-io/solswap-indexer release/sync-develop-into-master master merged validate,verify
append_duplicate_check_provenance_pin solswap-io/solswap-indexer release/sync-develop-into-master master validate 9001 .github/workflows/branch-flow.yml
append_duplicate_check_provenance_pin solswap-io/solswap-indexer release/sync-develop-into-master master verify 9002 .github/workflows/ci.yml
expect_failure \
  "future-failure timestamp duplicate fixture rejects conflicting conclusions" \
  stale-duplicate-checks \
  "conflictingRequiredCheckConclusions=validate,verify"

write_single_config tonswap-org/ton-indexer release/ton-health-identity-master master merged validate,verify
append_duplicate_check_provenance_pin tonswap-org/ton-indexer release/ton-health-identity-master master validate 9001 .github/workflows/branch-flow.yml
expect_failure \
  "future-success timestamp duplicate fixture rejects conflicting conclusions" \
  reverse-timestamp-duplicate \
  "conflictingRequiredCheckConclusions=validate"

write_config
expect_failure "malformed SHA-bound check response fixture" malformed-check-rollup "check-runs response was malformed; response details suppressed"

write_config
expect_failure "incomplete check pagination fixture" incomplete-check-pagination "malformedChecks=check-runs-pagination-incomplete"

write_config
expect_failure "wrong check head SHA provenance fixture" wrong-check-head-provenance "invalidRequiredCheckProvenance=validate:check-run-head-sha-mismatch"

write_config
expect_failure "wrong check-suite head SHA provenance fixture" wrong-suite-sha-provenance "invalidRequiredCheckProvenance=validate:check-suite-head-sha-mismatch"

write_config
expect_failure "wrong check-suite identity provenance fixture" wrong-suite-id-provenance "invalidRequiredCheckProvenance=validate:check-suite-id-mismatch"

write_config
expect_failure "wrong status-context head SHA provenance fixture" wrong-status-head-provenance "invalidRequiredCheckProvenance=Vercel:commit-status-head-sha-mismatch"

write_config
expect_failure "malformed commit status evidence fixture" malformed-status "malformedChecks=commit-status-response-shape"

write_config
expect_secret_safe_failure \
  "secret-safe provenance diagnostic fixture" \
  secret-safe-provenance \
  "invalidRequiredCheckProvenance=validate:check-run-head-sha-mismatch" \
  CHECK_DETAILS_SECRET_SENTINEL CHECK_OUTPUT_SECRET_SENTINEL UNTRUSTED_ROLLUP_SECRET_SENTINEL

write_config
expect_secret_safe_failure \
  "secret-safe check query failure fixture" \
  check-evidence-query-fails \
  "check-runs request failed; GitHub response details suppressed" \
  CHECK_QUERY_SECRET_SENTINEL

write_config
expect_secret_safe_failure \
  "secret-safe check-suite query failure fixture" \
  check-suite-query-fails \
  "check-suite provenance request failed for suite 1001; GitHub response details suppressed" \
  CHECK_SUITE_SECRET_SENTINEL

write_config
expect_failure "missing PR fixture" missing-pr "no pull request found"

write_config
expect_failure "bad JSON fixture" bad-json "gh returned invalid JSON"

write_config
expect_failure "query failure fixture" query-fails "unable to query PR state"

printf '%s\n' "soramitsu/fearless-wallet-web codex/web develop merged validate" > "$config_file"
expect_failure "malformed config fixture" merged "invalid release PR config line"

write_single_config soramitsu/fearless-wallet-web codex/web develop open validate
expect_failure "unsupported required state fixture" merged "unsupported required_state"

printf '%s\n' "soramitsu/fearless-wallet-web	codex/web	develop	merged" > "$config_file"
expect_failure "missing required checks config fixture" merged "invalid release PR config line"

write_single_config soramitsu/fearless-wallet-web codex/web develop merged validate,validate
expect_failure "duplicate required checks config fixture" merged "duplicate required_checks entries"

write_single_config soramitsu/fearless-Android codex/android-universal-wallet-readiness develop merged validate,build-and-test
printf '%s\n' \
  "# duplicate_check_provenance_pin	soramitsu/fearless-Android	codex/android-universal-wallet-readiness	develop	validate	99999	github-actions	9001	.github/workflows/branch-flow.yml" >> "$config_file"
expect_failure \
  "noncanonical duplicate-check app pin fixture" \
  merged \
  "duplicate required-check provenance pin must use the canonical GitHub Actions app"

write_single_config soramitsu/fearless-Android codex/android-universal-wallet-readiness develop merged validate,build-and-test
printf '%s\n' \
  "# duplicate_check_provenance_pin	soramitsu/fearless-Android	codex/android-universal-wallet-readiness	develop	validate	15368	github-actions	9001	.github/workflows/../untrusted.yml" >> "$config_file"
expect_failure \
  "noncanonical duplicate-check workflow path pin fixture" \
  merged \
  "duplicate required-check provenance pin has invalid workflow path"

write_single_config soramitsu/fearless-Android codex/android-universal-wallet-readiness develop merged validate,build-and-test
append_duplicate_check_provenance_pin soramitsu/fearless-Android codex/android-universal-wallet-readiness develop validate 9001 .github/workflows/branch-flow.yml
append_duplicate_check_provenance_pin soramitsu/fearless-Android codex/android-universal-wallet-readiness develop validate 9001 .github/workflows/branch-flow.yml
expect_failure \
  "duplicate duplicate-check provenance pin fixture" \
  merged \
  "duplicate required-check provenance pin"

write_single_config soramitsu/fearless-Android codex/android-universal-wallet-readiness develop merged validate,build-and-test
append_duplicate_check_provenance_pin soramitsu/fearless-Android codex/android-universal-wallet-readiness develop unrequired 9001 .github/workflows/branch-flow.yml
expect_failure \
  "unrequired duplicate-check provenance pin fixture" \
  merged \
  "duplicate required-check provenance pin names an unrequired check"

write_single_config soramitsu/fearless-wallet-web codex/../web develop merged validate
expect_failure "invalid head branch ref fixture" merged "invalid head branch ref"

write_single_config soramitsu/fearless-wallet-web codex/web develop.lock merged validate
expect_failure "invalid base branch ref fixture" merged "invalid base branch ref"

{
  printf '%s\n' "# reviewed_pr_pin	soramitsu/fearless-wallet-web	codex/web-bitcoin-broadcast-evidence	develop	42	$expected_merged_oid"
  printf '%s\n' "soramitsu/fearless-wallet-web	codex/web-bitcoin-broadcast-evidence	develop	merged	validate,verify"
  printf '%s\n' "soramitsu/fearless-wallet-web	codex/web-bitcoin-broadcast-evidence	develop	merged	validate"
} > "$config_file"
expect_failure "duplicate release PR row fixture" merged "duplicate release PR requirement row for soramitsu/fearless-wallet-web:codex/web-bitcoin-broadcast-evidence -> develop"

{
  printf '%s\n' "# reviewed_pr_pin	soramitsu/fearless-wallet-web	codex/web	develop	0	$expected_merged_oid"
  printf '%s\n' "soramitsu/fearless-wallet-web	codex/web	develop	merged	validate"
} > "$config_file"
expect_failure "noncanonical reviewed PR number pin fixture" merged "reviewed PR pin number must be canonical positive digits"

{
  printf '%s\n' "# reviewed_pr_pin	soramitsu/fearless-wallet-web	codex/web	develop	42	AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
  printf '%s\n' "soramitsu/fearless-wallet-web	codex/web	develop	merged	validate"
} > "$config_file"
expect_failure "noncanonical reviewed head SHA pin fixture" merged "reviewed PR head pin must be an exact lowercase 40-character commit SHA"

{
  printf '%s\n' "# reviewed_pr_pin	soramitsu/fearless-wallet-web	codex/web	develop	42	$expected_merged_oid"
  printf '%s\n' "# reviewed_pr_pin	soramitsu/fearless-wallet-web	codex/web	develop	43	$expected_merged_oid"
  printf '%s\n' "soramitsu/fearless-wallet-web	codex/web	develop	merged	validate"
} > "$config_file"
expect_failure "duplicate reviewed PR pin fixture" merged "duplicate reviewed PR pin"

printf '%s\n' "# reviewed_pr_pin	soramitsu/fearless-wallet-web	codex/orphan	develop	42	$expected_merged_oid" > "$config_file"
expect_failure "orphan reviewed PR pin fixture" merged "reviewed PR pin has no matching release PR requirement"

printf '%s\n' "# only comments" > "$config_file"
expect_failure "empty config fixture" merged "no release PR requirements were found"

rm "$config_file"
set +e
missing_output="$(GH_BIN="$fake_gh" bash "$AUDIT_SCRIPT" --config "$config_file" 2>&1)"
missing_status=$?
set -e
if [[ "$missing_status" -eq 0 || "$missing_output" != *"Required PR config missing"* ]]; then
  echo "$missing_output" >&2
  fail "missing config fixture did not fail as expected"
fi

echo "[release-pr-readiness-test] all tests passed"
