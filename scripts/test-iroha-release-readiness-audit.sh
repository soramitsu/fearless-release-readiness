#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
AUDIT_SCRIPT="$SCRIPT_DIR/audit-iroha-release-readiness.sh"

fail() {
  echo "[iroha-readiness-test][error] $*" >&2
  exit 1
}

tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

workspace="$tmp_dir/fearless"
parent="$tmp_dir"
nexus_url="https://minamoto.sora.org"
# Negative live-health fixtures must not spend production retry delays between attempts.
NEXUS_HEALTH_RETRY_DELAY_SECONDS=0
test_case_count=0

write_file() {
  local file="$1"
  shift
  mkdir -p "$(dirname "$file")"
  printf '%s\n' "$@" > "$file"
}

write_fake_mobile_validator() {
  local file="$1"
  local platform="$2"
  write_file "$file" \
    '#!/usr/bin/env bash' \
    'set -euo pipefail' \
    "platform=\"$platform\"" \
    'scenario="${FAKE_IROHA_READINESS_SCENARIO:-good}"' \
    'state_dir="${FAKE_IROHA_READINESS_STATE_DIR:-${TMPDIR:-/tmp}}"' \
    'mode=""' \
    'for arg in "$@"; do' \
    '  case "$arg" in' \
    '    --self-test) mode="self-test" ;;' \
    '    --download) mode="download" ;;' \
    '  esac' \
    'done' \
    'mkdir -p "$state_dir"' \
    'if [[ "$scenario:$platform:$mode" == "ios-download-flaky:ios:download" ]]; then' \
    '  marker="$state_dir/$scenario-$platform-$mode.count"' \
    '  count=0' \
    '  [[ -f "$marker" ]] && count="$(cat "$marker")"' \
    '  count=$((count + 1))' \
    '  printf "%s\n" "$count" > "$marker"' \
    '  if [[ "$count" -eq 1 ]]; then' \
    '    echo "$platform validator transient download failure" >&2' \
    '    exit 1' \
    '  fi' \
    'fi' \
    'case "$scenario:$platform:$mode" in' \
    '  android-self-test-fail:android:self-test|ios-self-test-fail:ios:self-test|android-download-fail:android:download|ios-download-fail:ios:download)' \
    '    echo "$platform validator failed for $scenario" >&2' \
    '    exit 1' \
    '    ;;' \
    'esac' \
    'if [[ "$mode" == "download" ]]; then' \
    '  [[ "$*" == *"--tag v1.2.3"* ]] || { echo "expected release tag" >&2; exit 1; }' \
    '  [[ "$*" == *"--repo hyperledger-iroha/iroha"* ]] || { echo "expected release repo" >&2; exit 1; }' \
    'fi' \
    'echo "$platform validator passed"'
  chmod +x "$file"
}

write_fake_web_validator() {
  local file="$1"
  write_file "$file" \
    '#!/usr/bin/env bash' \
    'set -euo pipefail' \
    'scenario="${FAKE_IROHA_READINESS_SCENARIO:-good}"' \
    'mode=""' \
    'for arg in "$@"; do' \
    '  case "$arg" in' \
    '    --self-test) mode="self-test" ;;' \
    '    --download) mode="download" ;;' \
    '    --github-release) mode="github-release" ;;' \
    '    --tarball) mode="tarball" ;;' \
    '    --package-dir) mode="package-dir" ;;' \
    '  esac' \
    'done' \
    'case "$scenario:$mode" in' \
    '  js-self-test-fail:self-test|js-fail:download|js-fail:github-release|js-fail:tarball|js-fail:package-dir)' \
    '    echo "js validator failed for $scenario" >&2' \
    '    exit 1' \
    '    ;;' \
    'esac' \
    'if [[ "$mode" == "github-release" ]]; then' \
    '  [[ "$*" == *"--repo hyperledger-iroha/iroha"* ]] || { echo "expected JS release repo" >&2; exit 1; }' \
    '  [[ "$*" == *"--tag v1.2.3"* ]] || { echo "expected JS release tag" >&2; exit 1; }' \
    '  [[ "$*" == *"--asset iroha-js-release.tgz"* ]] || { echo "expected JS release asset" >&2; exit 1; }' \
    '  [[ "$*" == *"--sha256 0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"* ]] || { echo "expected JS release SHA-256" >&2; exit 1; }' \
    'fi' \
    'echo "js validator passed"'
  chmod +x "$file"
}

write_fake_curl() {
  local file="$tmp_dir/bin/curl"
  write_file "$file" \
    '#!/usr/bin/env bash' \
    'set -euo pipefail' \
    'scenario="${FAKE_IROHA_READINESS_SCENARIO:-good}"' \
    'state_dir="${FAKE_IROHA_READINESS_STATE_DIR:-${TMPDIR:-/tmp}}"' \
    'mkdir -p "$state_dir"' \
    'if [[ "${1:-}" == "--disable" && "${2:-}" == "--version" && $# -eq 2 ]]; then' \
    '  [[ "$scenario" == "nexus-health-old-curl" ]] && version=8.3.0 || version=8.4.0' \
    '  printf "curl %s (fixture) libcurl/%s\n" "$version" "$version"' \
    '  exit 0' \
    'fi' \
    ': > "$state_dir/curl.argv"' \
    'printf "%s\n" "$@" > "$state_dir/curl.argv"' \
    'security_failure() { echo "curl security contract violation: $*" >&2; exit 2; }' \
    '[[ "${1:-}" == "--disable" || "${1:-}" == "-q" ]] || security_failure "--disable/-q must be the first argument; ambient curlrc would be loaded"' \
    'output_file=""' \
    'write_out=""' \
    'url="${@: -1}"' \
    'saw_proto=false' \
    'saw_proto_redir=false' \
    'saw_tls=false' \
    'saw_max_redirs=false' \
    'saw_connect_timeout=false' \
    'saw_max_time=false' \
    'connect_timeout_value=""' \
    'max_time_value=""' \
    'saw_max_filesize=false' \
    'saw_accept=false' \
    'args=("$@")' \
    'for ((i = 0; i < ${#args[@]}; i += 1)); do' \
    '  arg="${args[$i]}"' \
    '  case "$arg" in' \
    '    --location|-L|--location-trusted) security_failure "redirect following is forbidden" ;;' \
    '    --insecure|-k) security_failure "insecure TLS is forbidden" ;;' \
    '    --proto) [[ "${args[$((i + 1))]:-}" == "=https" ]] || security_failure "--proto must be =https"; saw_proto=true; i=$((i + 1)) ;;' \
    '    --proto-redir) [[ "${args[$((i + 1))]:-}" == "=https" ]] || security_failure "--proto-redir must be =https"; saw_proto_redir=true; i=$((i + 1)) ;;' \
    '    --tlsv1.2) saw_tls=true ;;' \
    '    --max-redirs) [[ "${args[$((i + 1))]:-}" == "0" ]] || security_failure "--max-redirs must be 0"; saw_max_redirs=true; i=$((i + 1)) ;;' \
    '    --connect-timeout) connect_timeout_value="${args[$((i + 1))]:-}"; [[ "$connect_timeout_value" =~ ^([1-9]|[1-5][0-9]|60)$ ]] || security_failure "unexpected connect timeout"; saw_connect_timeout=true; i=$((i + 1)) ;;' \
    '    --max-time) max_time_value="${args[$((i + 1))]:-}"; [[ "$max_time_value" =~ ^([1-9]|[1-5][0-9]|60)$ ]] || security_failure "unexpected max time"; saw_max_time=true; i=$((i + 1)) ;;' \
    '    --max-filesize) [[ "${args[$((i + 1))]:-}" == "131072" ]] || security_failure "unexpected max filesize"; saw_max_filesize=true; i=$((i + 1)) ;;' \
    '    --header) [[ "${args[$((i + 1))]:-}" == "Accept: application/json" ]] || security_failure "unexpected Accept header"; saw_accept=true; i=$((i + 1)) ;;' \
    '    --output) output_file="${args[$((i + 1))]:-}"; i=$((i + 1)) ;;' \
    '    --write-out) write_out="${args[$((i + 1))]:-}"; i=$((i + 1)) ;;' \
    '  esac' \
    'done' \
    '[[ "$saw_proto" == true ]] || security_failure "missing --proto =https"' \
    '[[ "$saw_proto_redir" == true ]] || security_failure "missing --proto-redir =https"' \
    '[[ "$saw_tls" == true ]] || security_failure "missing --tlsv1.2"' \
    '[[ "$saw_max_redirs" == true ]] || security_failure "missing --max-redirs 0"' \
    '[[ "$saw_connect_timeout" == true ]] || security_failure "missing --connect-timeout"' \
    '[[ "$saw_max_time" == true ]] || security_failure "missing --max-time"' \
    '[[ "$connect_timeout_value" == "$max_time_value" ]] || security_failure "connect and total timeout values must match"' \
    '[[ "$saw_max_filesize" == true ]] || security_failure "missing --max-filesize"' \
    '[[ "$saw_accept" == true ]] || security_failure "missing JSON Accept header"' \
    '[[ -n "$output_file" ]] || security_failure "missing --output"' \
    '[[ "$write_out" == "__NEXUS_HTTP_META__%{http_code}|%{content_type}" ]] || security_failure "unexpected --write-out metadata contract"' \
    'now_ms="$(( $(date +%s) * 1000 ))"' \
    'last_block_ms="$((now_ms - 1000))"' \
    'http_status=200' \
    'content_type=application/json' \
    'valid_body() {' \
    '  local observed_at="${1:-$now_ms}"' \
    '  local committed_at="${2:-$last_block_ms}"' \
    '  local queue_size="${3:-3}"' \
    '  local nexus_json="${4:-}"' \
    '  local since_last_block="${5:-1000}"' \
    '  local peers="${6:-3}"' \
    '  local commit="${7:-abcdef1234567890abcdef1234567890abcdef12}"' \
    '  local catalog_json="${8:-}"' \
    '  local chain_id="${9:-fixture:nexus:chain}"' \
    '  local genesis_hash="${10:-0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef}"' \
    '  [[ -n "$nexus_json" ]] || nexus_json="{\"routing_policy\":{\"default_lane\":0,\"default_dataspace\":0,\"rules\":[{\"lane\":1,\"dataspace_id\":1,\"matcher\":{\"instruction\":\"governance\",\"description\":\"Route governance instructions to the governance lane\"}},{\"lane\":2,\"dataspace_id\":2,\"matcher\":{\"instruction\":\"smartcontract::deploy\",\"description\":\"Route contract deployments to the zk lane for proof tracking\"}}]}}"' \
    '  [[ -n "$catalog_json" ]] || catalog_json="[{\"lane_id\":0,\"lane_alias\":\"default\",\"dataspace_id\":0,\"alias\":\"universal\",\"visibility\":\"public\",\"storage_profile\":\"default\",\"manifest_required\":false,\"manifest_ready\":false,\"sealed\":false},{\"lane_id\":1,\"lane_alias\":\"governance\",\"dataspace_id\":1,\"alias\":\"governance\",\"visibility\":\"public\",\"storage_profile\":\"governance\",\"manifest_required\":true,\"manifest_ready\":true,\"sealed\":false},{\"lane_id\":2,\"lane_alias\":\"zk\",\"dataspace_id\":2,\"alias\":\"zk\",\"visibility\":\"public\",\"storage_profile\":\"zk\",\"manifest_required\":true,\"manifest_ready\":true,\"sealed\":false}]"' \
    '  printf "{\"chain_id\":\"%s\",\"genesis_hash\":\"%s\",\"build\":{\"version\":\"2.0.0\",\"git_commit_sha\":\"%s\",\"cargo_features\":\"nexus\",\"target_triple\":\"x86_64-unknown-linux-gnu\"},\"observed_at_ms\":%s,\"peers\":%s,\"blocks\":42,\"blocks_non_empty\":40,\"txs_approved\":9,\"txs_rejected\":1,\"queue_size\":%s,\"queue_queued\":2,\"queue_inflight\":1,\"last_block_committed_at_ms\":%s,\"time_since_last_block_ms\":%s,\"dataspace_catalog\":%s,\"nexus\":%s}" "$chain_id" "$genesis_hash" "$commit" "$observed_at" "$peers" "$queue_size" "$committed_at" "$since_last_block" "$catalog_json" "$nexus_json"' \
    '}' \
    'body="$(valid_body)"' \
    'if [[ "$scenario" == "nexus-health-flaky" ]]; then' \
    '  marker="$state_dir/$scenario.count"' \
    '  count=0' \
    '  [[ -f "$marker" ]] && count="$(cat "$marker")"' \
    '  count=$((count + 1))' \
    '  printf "%s\n" "$count" > "$marker"' \
    '  if [[ "$count" -eq 1 ]]; then' \
    '    echo "transient nexus health timeout" >&2' \
    '    exit 28' \
    '  fi' \
    'fi' \
    'case "$scenario" in' \
    '  nexus-health-fail)' \
    '    printf "curl timeout token=transport-secret\033[31m\npassword=hunter2 Bearer live-bearer-value api_key=live-api-key\nAuthorization: Basic basic-auth-secret\nProxy-Authorization: Negotiate proxy-auth-secret\nCookie: session=cookie-secret\nSet-Cookie: sid=set-cookie-secret\n%05000d" 0 >&2' \
    '    exit 28' \
    '    ;;' \
    '  nexus-health-invalid)' \
    '    body="{\"status\":\"down\"}"' \
    '    ;;' \
    '  nexus-health-non-json)' \
    '    body="{\"token\":\"parser-secret-token\",\"password\":\"parser-password\" INVALID_JSON_FRAGMENT"' \
    '    ;;' \
    '  nexus-health-redirect)' \
    '    http_status=302' \
    '    body="{\"token\":\"redirect-secret-token\"}"' \
    '    ;;' \
    '  nexus-health-wrong-content-type)' \
    '    content_type=text/plain' \
    '    body="password=content-type-secret"' \
    '    ;;' \
    '  nexus-health-missing-chain-id)' \
    '    body="${body/\"chain_id\":\"fixture:nexus:chain\",/}"' \
    '    ;;' \
    '  nexus-health-nested-chain-id)' \
    '    body="${body/\"chain_id\":\"fixture:nexus:chain\",/}"' \
    '    body="${body/\"build\":{/\"build\":{\"chain_id\":\"fixture:nexus:chain\",}"' \
    '    ;;' \
    '  nexus-health-wrong-chain-id)' \
    '    body="$(valid_body "$now_ms" "$last_block_ms" 3 "" 1000 3 abcdef1234567890abcdef1234567890abcdef12 "" fixture:nexus:other)"' \
    '    ;;' \
    '  nexus-health-chain-id-number)' \
    '    body="${body/\"chain_id\":\"fixture:nexus:chain\"/\"chain_id\":7}"' \
    '    ;;' \
    '  nexus-health-chain-id-null)' \
    '    body="${body/\"chain_id\":\"fixture:nexus:chain\"/\"chain_id\":null}"' \
    '    ;;' \
    '  nexus-health-chain-id-uppercase)' \
    '    body="$(valid_body "$now_ms" "$last_block_ms" 3 "" 1000 3 abcdef1234567890abcdef1234567890abcdef12 "" Fixture:Nexus:Chain)"' \
    '    ;;' \
    '  nexus-health-chain-id-leading-separator)' \
    '    body="$(valid_body "$now_ms" "$last_block_ms" 3 "" 1000 3 abcdef1234567890abcdef1234567890abcdef12 "" :fixture:nexus:chain)"' \
    '    ;;' \
    '  nexus-health-chain-id-repeated-separator)' \
    '    body="$(valid_body "$now_ms" "$last_block_ms" 3 "" 1000 3 abcdef1234567890abcdef1234567890abcdef12 "" fixture::nexus:chain)"' \
    '    ;;' \
    '  nexus-health-chain-id-overlong)' \
    '    overlong_chain="$(printf "a%.0s" {1..129})"' \
    '    body="$(valid_body "$now_ms" "$last_block_ms" 3 "" 1000 3 abcdef1234567890abcdef1234567890abcdef12 "" "$overlong_chain")"' \
    '    ;;' \
    '  nexus-health-missing-genesis-hash)' \
    '    body="${body/\"genesis_hash\":\"0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef\",/}"' \
    '    ;;' \
    '  nexus-health-nested-genesis-hash)' \
    '    body="${body/\"genesis_hash\":\"0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef\",/}"' \
    '    body="${body/\"build\":{/\"build\":{\"genesis_hash\":\"0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef\",}"' \
    '    ;;' \
    '  nexus-health-wrong-genesis-hash)' \
    '    body="$(valid_body "$now_ms" "$last_block_ms" 3 "" 1000 3 abcdef1234567890abcdef1234567890abcdef12 "" fixture:nexus:chain 1234567890abcdef0123456789abcdef0123456789abcdef0123456789abcdef)"' \
    '    ;;' \
    '  nexus-health-genesis-hash-number)' \
    '    body="${body/\"genesis_hash\":\"0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef\"/\"genesis_hash\":7}"' \
    '    ;;' \
    '  nexus-health-genesis-hash-null)' \
    '    body="${body/\"genesis_hash\":\"0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef\"/\"genesis_hash\":null}"' \
    '    ;;' \
    '  nexus-health-genesis-hash-uppercase)' \
    '    body="$(valid_body "$now_ms" "$last_block_ms" 3 "" 1000 3 abcdef1234567890abcdef1234567890abcdef12 "" fixture:nexus:chain 0123456789ABCDEF0123456789abcdef0123456789abcdef0123456789abcdef)"' \
    '    ;;' \
    '  nexus-health-genesis-hash-placeholder)' \
    '    body="$(valid_body "$now_ms" "$last_block_ms" 3 "" 1000 3 abcdef1234567890abcdef1234567890abcdef12 "" fixture:nexus:chain aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa)"' \
    '    ;;' \
    '  nexus-health-genesis-hash-short)' \
    '    body="$(valid_body "$now_ms" "$last_block_ms" 3 "" 1000 3 abcdef1234567890abcdef1234567890abcdef12 "" fixture:nexus:chain 0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcde)"' \
    '    ;;' \
    '  nexus-health-stale)' \
    '    body="$(valid_body 1 1)"' \
    '    ;;' \
    '  nexus-health-missing-nexus)' \
    '    body="$(valid_body "$now_ms" "$last_block_ms" 3 null)"' \
    '    ;;' \
    '  nexus-health-incoherent-queue)' \
    '    body="$(valid_body "$now_ms" "$last_block_ms" 4)"' \
    '    ;;' \
    '  nexus-health-zero-peers)' \
    '    body="$(valid_body "$now_ms" "$last_block_ms" 3 "" 1000 0)"' \
    '    ;;' \
    '  nexus-health-stale-block)' \
    '    stale_block_ms="$((now_ms - 300001))"' \
    '    body="$(valid_body "$now_ms" "$stale_block_ms" 3 "" 300001)"' \
    '    ;;' \
    '  nexus-health-compounded-stale)' \
    '    observed_ms="$((now_ms - 299000))"' \
    '    stale_block_ms="$((observed_ms - 299000))"' \
    '    body="$(valid_body "$observed_ms" "$stale_block_ms" 3 "" 299000)"' \
    '    ;;' \
    '  nexus-health-future-block)' \
    '    future_ms="$((now_ms + 60000))"' \
    '    body="$(valid_body "$future_ms" "$future_ms" 3 "" 0)"' \
    '    ;;' \
    '  nexus-health-empty-routes)' \
    '    body="$(valid_body "$now_ms" "$last_block_ms" 3 "{\"routing_policy\":{\"default_lane\":0,\"default_dataspace\":0,\"rules\":[]}}")"' \
    '    ;;' \
    '  nexus-health-malformed-route)' \
    '    body="$(valid_body "$now_ms" "$last_block_ms" 3 "{\"routing_policy\":{\"default_lane\":0,\"default_dataspace\":0,\"rules\":[{\"lane\":1,\"dataspace_id\":null,\"matcher\":{}}]}}")"' \
    '    ;;' \
    '  nexus-health-empty-route-matcher)' \
    '    body="$(valid_body "$now_ms" "$last_block_ms" 3 "{\"routing_policy\":{\"default_lane\":0,\"default_dataspace\":0,\"rules\":[{\"lane\":1,\"dataspace_id\":1,\"matcher\":{}}]}}")"' \
    '    ;;' \
    '  nexus-health-wrong-default-route)' \
    '    body="$(valid_body "$now_ms" "$last_block_ms" 3 "{\"routing_policy\":{\"default_lane\":9,\"default_dataspace\":0,\"rules\":[{\"lane\":1,\"dataspace_id\":1,\"matcher\":{\"instruction\":\"governance\",\"description\":\"Route governance instructions to the governance lane\"}},{\"lane\":2,\"dataspace_id\":2,\"matcher\":{\"instruction\":\"smartcontract::deploy\",\"description\":\"Route contract deployments to the zk lane for proof tracking\"}}]}}")"' \
    '    ;;' \
    '  nexus-health-missing-second-route)' \
    '    body="$(valid_body "$now_ms" "$last_block_ms" 3 "{\"routing_policy\":{\"default_lane\":0,\"default_dataspace\":0,\"rules\":[{\"lane\":1,\"dataspace_id\":1,\"matcher\":{\"instruction\":\"governance\",\"description\":\"Route governance instructions to the governance lane\"}}]}}")"' \
    '    ;;' \
    '  nexus-health-wrong-route-selector)' \
    '    body="$(valid_body "$now_ms" "$last_block_ms" 3 "{\"routing_policy\":{\"default_lane\":0,\"default_dataspace\":0,\"rules\":[{\"lane\":1,\"dataspace_id\":1,\"matcher\":{\"instruction\":\"governance\",\"description\":\"Route governance instructions to the governance lane\"}},{\"lane\":2,\"dataspace_id\":2,\"matcher\":{\"instruction\":\"smartcontract::call\",\"description\":\"Route contract deployments to the zk lane for proof tracking\"}}]}}")"' \
    '    ;;' \
    '  nexus-health-reordered-routes)' \
    '    body="$(valid_body "$now_ms" "$last_block_ms" 3 "{\"routing_policy\":{\"default_lane\":0,\"default_dataspace\":0,\"rules\":[{\"lane\":2,\"dataspace_id\":2,\"matcher\":{\"instruction\":\"smartcontract::deploy\",\"description\":\"Route contract deployments to the zk lane for proof tracking\"}},{\"lane\":1,\"dataspace_id\":1,\"matcher\":{\"instruction\":\"governance\",\"description\":\"Route governance instructions to the governance lane\"}}]}}")"' \
    '    ;;' \
    '  nexus-health-missing-catalog)' \
    '    body="$(valid_body "$now_ms" "$last_block_ms" 3 "" 1000 3 abcdef1234567890abcdef1234567890abcdef12 null)"' \
    '    ;;' \
    '  nexus-health-missing-catalog-target)' \
    '    catalog="[{\"lane_id\":0,\"lane_alias\":\"default\",\"dataspace_id\":0,\"alias\":\"universal\",\"visibility\":\"public\",\"storage_profile\":\"default\",\"manifest_required\":false,\"manifest_ready\":false,\"sealed\":false},{\"lane_id\":1,\"lane_alias\":\"governance\",\"dataspace_id\":1,\"alias\":\"governance\",\"visibility\":\"public\",\"storage_profile\":\"governance\",\"manifest_required\":true,\"manifest_ready\":true,\"sealed\":false}]"' \
    '    body="$(valid_body "$now_ms" "$last_block_ms" 3 "" 1000 3 abcdef1234567890abcdef1234567890abcdef12 "$catalog")"' \
    '    ;;' \
    '  nexus-health-sealed-catalog-target|nexus-health-unready-catalog-target)' \
    '    [[ "$scenario" == "nexus-health-sealed-catalog-target" ]] && sealed=true || sealed=false' \
    '    catalog="[{\"lane_id\":0,\"lane_alias\":\"default\",\"dataspace_id\":0,\"alias\":\"universal\",\"visibility\":\"public\",\"storage_profile\":\"default\",\"manifest_required\":false,\"manifest_ready\":false,\"sealed\":false},{\"lane_id\":1,\"lane_alias\":\"governance\",\"dataspace_id\":1,\"alias\":\"governance\",\"visibility\":\"public\",\"storage_profile\":\"governance\",\"manifest_required\":true,\"manifest_ready\":true,\"sealed\":false},{\"lane_id\":2,\"lane_alias\":\"zk\",\"dataspace_id\":2,\"alias\":\"zk\",\"visibility\":\"public\",\"storage_profile\":\"zk\",\"manifest_required\":true,\"manifest_ready\":false,\"sealed\":$sealed}]"' \
    '    body="$(valid_body "$now_ms" "$last_block_ms" 3 "" 1000 3 abcdef1234567890abcdef1234567890abcdef12 "$catalog")"' \
    '    ;;' \
    '  nexus-health-duplicate-catalog-target)' \
    '    catalog="[{\"lane_id\":0,\"lane_alias\":\"default\",\"dataspace_id\":0,\"alias\":\"universal\",\"visibility\":\"public\",\"storage_profile\":\"default\",\"manifest_required\":false,\"manifest_ready\":false,\"sealed\":false},{\"lane_id\":0,\"lane_alias\":\"duplicate\",\"dataspace_id\":0,\"alias\":\"duplicate\",\"visibility\":\"public\",\"storage_profile\":\"default\",\"manifest_required\":false,\"manifest_ready\":false,\"sealed\":false},{\"lane_id\":1,\"lane_alias\":\"governance\",\"dataspace_id\":1,\"alias\":\"governance\",\"visibility\":\"public\",\"storage_profile\":\"governance\",\"manifest_required\":true,\"manifest_ready\":true,\"sealed\":false},{\"lane_id\":2,\"lane_alias\":\"zk\",\"dataspace_id\":2,\"alias\":\"zk\",\"visibility\":\"public\",\"storage_profile\":\"zk\",\"manifest_required\":true,\"manifest_ready\":true,\"sealed\":false}]"' \
    '    body="$(valid_body "$now_ms" "$last_block_ms" 3 "" 1000 3 abcdef1234567890abcdef1234567890abcdef12 "$catalog")"' \
    '    ;;' \
    '  nexus-health-placeholder-commit)' \
    '    body="$(valid_body "$now_ms" "$last_block_ms" 3 "" 1000 3 unknown)"' \
    '    ;;' \
    '  nexus-health-wrong-commit)' \
    '    body="$(valid_body "$now_ms" "$last_block_ms" 3 "" 1000 3 1234567890abcdef1234567890abcdef12345678)"' \
    '    ;;' \
    '  nexus-health-64-commit)' \
    '    body="$(valid_body "$now_ms" "$last_block_ms" 3 "" 1000 3 0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef)"' \
    '    ;;' \
    '  nexus-health-oversized)' \
    '    body="$(head -c 131073 /dev/zero | tr "\\000" A)"' \
    '    ;;' \
    '  nexus-health-multibyte-oversized)' \
    '    body="$(LC_ALL=C awk '\''BEGIN { for (i = 0; i < 70000; i += 1) printf "\\303\\251" }'\'')"' \
    '    ;;' \
    'esac' \
    'case "$url" in' \
    '  https://minamoto.sora.org/status)' \
    '    printf "%s" "$body" > "$output_file"' \
    '    printf "__NEXUS_HTTP_META__%s|%s" "$http_status" "$content_type"' \
    '    case "$scenario" in nexus-health-oversized|nexus-health-multibyte-oversized) exit 63 ;; esac' \
    '    ;;' \
    '  *)' \
    '    echo "unexpected health URL: $url" >&2' \
    '    exit 1' \
    '    ;;' \
    'esac'
  chmod +x "$file"
}

write_iroha_ready() {
  write_file "$parent/iroha/.github/workflows/mobile_sdk_artifacts.yml" \
    "name: Mobile SDK Artifacts" \
    "on:" \
    "  push:" \
    "    tags:" \
    "      - \"v*\"" \
    "jobs:" \
    "  checker-self-test:" \
    "    steps:" \
    "      - run: bash scripts/check_mobile_sdk_artifacts_test.sh" \
    "  apple-mobile-sdk:" \
    "    steps:" \
    "      - run: bash scripts/package_mobile_sdk_artifacts.sh --apple --version v1.2.3" \
    "  android-mobile-sdk:" \
    "    steps:" \
    "      - run: bash scripts/package_mobile_sdk_artifacts.sh --android --version v1.2.3" \
    "  publish-release-assets:" \
    "    steps:" \
    "      - run: gh release upload v1.2.3 release-assets/* --clobber"

  for script in check_mobile_sdk_artifacts.sh check_mobile_sdk_artifacts_test.sh package_mobile_sdk_artifacts.sh; do
    write_file "$parent/iroha/scripts/$script" "#!/usr/bin/env bash" "exit 0"
    chmod +x "$parent/iroha/scripts/$script"
  done
}

write_wallet_ready_sources() {
  write_file "$workspace/fearless-wallet-web/src/consts/universalWallet.ts" \
    "const UNIVERSAL_WALLET_IROHA_NETWORKS = {" \
    "  nexus: { toriiBaseUrl: '$nexus_url', mcpPath: '/v1/mcp' }," \
    "} as const;" \
    "const UNIVERSAL_WALLET_NEXUS_REGISTRY_ENTRY = {" \
    "  endpoints: [{ id: 'sora-nexus-mainnet-torii-mcp', kind: 'torii-mcp', url: '${nexus_url}/v1/mcp' }]," \
    "};"

  write_file "$workspace/fearless-Android/common/src/main/java/jp/co/soramitsu/common/model/UniversalWalletRegistry.kt" \
    "object UniversalWalletRegistry {" \
    "  val nexus = IrohaNetwork(" \
    "    id = \"sora-nexus-mainnet\"," \
    "    chainId = \"sora:nexus:global\"," \
    "    toriiBaseUrl = \"$nexus_url\"," \
    "    mcpPath = \"/v1/mcp\"" \
    "  )" \
    "}"

  write_file "$workspace/fearless-iOS/fearless/Common/Model/UniversalWalletRegistry.swift" \
    "enum UniversalWalletRegistry {" \
    "  static let nexus = IrohaNetwork(" \
    "    id: \"sora-nexus-mainnet\"," \
    "    chainId: \"sora:nexus:global\"," \
    "    toriiBaseURL: URL(string: \"$nexus_url\")!," \
    "    mcpPath: \"/v1/mcp\"" \
    "  )" \
    "}"
}

write_iroha_release_config() {
  local chain_id="${1-fixture:nexus:chain}"
  local genesis_hash="${2-0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef}"
  local build_commit="${3-abcdef1234567890abcdef1234567890abcdef12}"
  write_file "$workspace/config/iroha-release-readiness.env" \
    "IROHA_MOBILE_SDK_RELEASE_REPO=hyperledger-iroha/iroha" \
    "IROHA_MOBILE_SDK_RELEASE_TAG=v1.2.3" \
    "IROHA_JS_SDK_RELEASE_REPO=hyperledger-iroha/iroha" \
    "IROHA_JS_SDK_RELEASE_TAG=v1.2.3" \
    "IROHA_JS_SDK_RELEASE_ASSET=iroha-js-release.tgz" \
    "IROHA_JS_SDK_RELEASE_SHA256=0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef" \
    "NEXUS_EXPECTED_BUILD_COMMIT=$build_commit" \
    "NEXUS_EXPECTED_CHAIN_ID=$chain_id" \
    "NEXUS_EXPECTED_GENESIS_HASH=$genesis_hash"
}

write_nexus_production_evidence_config() {
  write_file "$workspace/config/nexus-production-evidence.json" \
    "{" \
    '  "schemaVersion": 1,' \
    '  "scope": "sora-nexus-production-readiness",' \
    '  "network": "sora-nexus-mainnet",' \
    '  "chainId": "sora:nexus:global",' \
    '  "toriiBaseUrl": "https://minamoto.sora.org",' \
    '  "mcpUrl": "https://minamoto.sora.org/v1/mcp",' \
    '  "healthUrl": "https://minamoto.sora.org/status",' \
    '  "status": "blocked",' \
    '  "releaseEnabled": false,' \
    '  "blockers": [' \
    '    "nexus-live-health-failing",' \
    '    "route-publication-evidence-missing",' \
    '    "route-canary-evidence-missing",' \
    '    "wallet-live-transfer-smoke-missing"' \
    '  ],' \
    '  "readyVerificationCommands": [' \
    '    "bash scripts/test-nexus-production-evidence-template.sh",' \
    '    "bash scripts/generate-nexus-production-evidence-template.sh --output build/reports/nexus-production-evidence-template.json",' \
    '    "bash scripts/test-nexus-production-evidence-audit.sh",' \
    '    "bash scripts/audit-nexus-production-evidence.sh --require-ready",' \
    '    "IROHA_NEXUS_REQUIRE_PRODUCTION_EVIDENCE=1 IROHA_NEXUS_LIVE_HEALTH=1 bash scripts/audit-iroha-release-readiness.sh",' \
    '    "bash scripts/audit-iroha-wallet-coverage.sh"' \
    '  ],' \
    '  "requiredEvidenceFields": [' \
    '    "routeManifestCommit",' \
    '    "routeManifestSourcePath",' \
    '    "routeManifestHash",' \
    '    "publicationTransactionHash",' \
    '    "publicationAuthority",' \
    '    "publishedAt",' \
    '    "routeCanaryTransactionHash",' \
    '    "routeCanaryCheckedAt",' \
    '    "routeCanarySourceAccount",' \
    '    "routeCanaryDestinationAccount",' \
    '    "routeCanaryAssetId",' \
    '    "routeCanaryAmount",' \
    '    "walletPlatform",' \
    '    "walletCommit",' \
    '    "walletSmokeTransactionHash",' \
    '    "walletSmokeSubmittedAt",' \
    '    "walletSmokeObservedAt",' \
    '    "operator"' \
    '  ],' \
    '  "routePublicationEvidence": [],' \
    '  "routeCanaryEvidence": [],' \
    '  "walletSmokeEvidence": []' \
    "}"
}

write_mobile_only_iroha_release_config() {
  write_file "$workspace/config/iroha-release-readiness.env" \
    "IROHA_MOBILE_SDK_RELEASE_REPO=hyperledger-iroha/iroha" \
    "IROHA_MOBILE_SDK_RELEASE_TAG=v1.2.3"
}

setup_fixture() {
  rm -rf "$workspace" "$parent/iroha" "$tmp_dir/state"
  mkdir -p "$workspace"
  write_iroha_ready
  write_iroha_release_config
  write_nexus_production_evidence_config
  write_fake_mobile_validator "$workspace/fearless-Android/scripts/check-iroha-mobile-sdk-release-assets.sh" android
  write_fake_mobile_validator "$workspace/fearless-iOS/scripts/check-iroha-mobile-sdk-release-assets.sh" ios
  write_fake_web_validator "$workspace/fearless-wallet-web/scripts/check-iroha-js-sdk-artifact.sh"
  write_fake_curl
  write_wallet_ready_sources
}

run_audit() {
  local scenario="$1"
  local mobile_tag="${2-v1.2.3}"
  local js_version="${3-}"
  local url="${4-}"
  local env_args=(
    "FAKE_IROHA_READINESS_SCENARIO=$scenario"
    "FAKE_IROHA_READINESS_STATE_DIR=$tmp_dir/state"
    "IROHA_READINESS_ROOT=$workspace"
    "IROHA_READINESS_PARENT=$parent"
    "PATH=$tmp_dir/bin:$PATH"
  )

  if [[ -n "$js_version" ]]; then
    env_args+=("IROHA_JS_SDK_VERSION=$js_version")
  fi
  if [[ -n "$mobile_tag" ]]; then
    env_args+=("IROHA_MOBILE_SDK_RELEASE_TAG=$mobile_tag")
  fi
  if [[ -n "$url" ]]; then
    env_args+=("NEXUS_TORII_URL=$url")
  fi
  if [[ "${IROHA_NEXUS_LIVE_HEALTH+x}" == "x" ]]; then
    env_args+=("IROHA_NEXUS_LIVE_HEALTH=$IROHA_NEXUS_LIVE_HEALTH")
  fi
  if [[ "${IROHA_NEXUS_REQUIRE_PRODUCTION_EVIDENCE+x}" == "x" ]]; then
    env_args+=("IROHA_NEXUS_REQUIRE_PRODUCTION_EVIDENCE=$IROHA_NEXUS_REQUIRE_PRODUCTION_EVIDENCE")
  fi
  if [[ -n "${NEXUS_PRODUCTION_EVIDENCE_AUDIT:-}" ]]; then
    env_args+=("NEXUS_PRODUCTION_EVIDENCE_AUDIT=$NEXUS_PRODUCTION_EVIDENCE_AUDIT")
  fi
  if [[ -n "${NEXUS_PRODUCTION_EVIDENCE_TEST:-}" ]]; then
    env_args+=("NEXUS_PRODUCTION_EVIDENCE_TEST=$NEXUS_PRODUCTION_EVIDENCE_TEST")
  fi
  if [[ "${NEXUS_HEALTH_PATH+x}" == "x" ]]; then
    env_args+=("NEXUS_HEALTH_PATH=$NEXUS_HEALTH_PATH")
  fi
  if [[ "${NEXUS_HEALTH_TIMEOUT_SECONDS+x}" == "x" ]]; then
    env_args+=("NEXUS_HEALTH_TIMEOUT_SECONDS=$NEXUS_HEALTH_TIMEOUT_SECONDS")
  fi
  if [[ "${NEXUS_HEALTH_ATTEMPTS+x}" == "x" ]]; then
    env_args+=("NEXUS_HEALTH_ATTEMPTS=$NEXUS_HEALTH_ATTEMPTS")
  fi
  if [[ "${NEXUS_HEALTH_RETRY_DELAY_SECONDS+x}" == "x" ]]; then
    env_args+=("NEXUS_HEALTH_RETRY_DELAY_SECONDS=$NEXUS_HEALTH_RETRY_DELAY_SECONDS")
  fi
  if [[ "${NEXUS_EXPECTED_BUILD_COMMIT+x}" == "x" ]]; then
    env_args+=("NEXUS_EXPECTED_BUILD_COMMIT=$NEXUS_EXPECTED_BUILD_COMMIT")
  fi
  if [[ "${NEXUS_EXPECTED_CHAIN_ID+x}" == "x" ]]; then
    env_args+=("NEXUS_EXPECTED_CHAIN_ID=$NEXUS_EXPECTED_CHAIN_ID")
  fi
  if [[ "${NEXUS_EXPECTED_GENESIS_HASH+x}" == "x" ]]; then
    env_args+=("NEXUS_EXPECTED_GENESIS_HASH=$NEXUS_EXPECTED_GENESIS_HASH")
  fi

  env "${env_args[@]}" bash "$AUDIT_SCRIPT"
}

expect_success() {
  local name="$1"
  shift
  local output
  if ! output="$(run_audit "$@" 2>&1)"; then
    echo "$output" >&2
    fail "$name unexpectedly failed"
  fi
  test_case_count=$((test_case_count + 1))
}

expect_failure() {
  local name="$1"
  local expected="$2"
  shift 2
  local output
  set +e
  output="$(run_audit "$@" 2>&1)"
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
  test_case_count=$((test_case_count + 1))
}

expect_failure_without_leaks() {
  local name="$1"
  local expected="$2"
  local scenario="$3"
  shift 3
  local output forbidden
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
  for forbidden in "$@"; do
    if [[ "$output" == *"$forbidden"* ]]; then
      echo "$output" >&2
      fail "$name leaked forbidden diagnostic text: $forbidden"
    fi
  done
  if LC_ALL=C grep -q $'\033' <<<"$output"; then
    echo "$output" >&2
    fail "$name leaked ANSI/control sequences"
  fi
  local longest_line
  longest_line="$(printf '%s\n' "$output" | LC_ALL=C awk '{ if (length > max) max = length } END { print max + 0 }')"
  if ((longest_line > 700)); then
    echo "$output" >&2
    fail "$name emitted an unbounded diagnostic line ($longest_line bytes)"
  fi
  test_case_count=$((test_case_count + 1))
}

assert_curl_argv_contract() {
  local argv_file="$tmp_dir/state/curl.argv"
  [[ -f "$argv_file" ]] || fail "curl argv capture missing"
  [[ "$(sed -n '1p' "$argv_file")" == "--disable" ]] || fail "curl --disable was not the first argument"
  local required
  for required in \
    "--proto" "=https" "--proto-redir" "--tlsv1.2" \
    "--max-redirs" "0" "--connect-timeout" "--max-time" \
    "--max-filesize" "131072" "--output" "--write-out" \
    "__NEXUS_HTTP_META__%{http_code}|%{content_type}" \
    "https://minamoto.sora.org/status"; do
    grep -Fxq -- "$required" "$argv_file" || fail "curl argv missing required argument: $required"
  done
  if grep -Eq '^(--location|-L|--location-trusted|--insecure|-k)$' "$argv_file"; then
    fail "curl argv contained redirect-following or insecure TLS flags"
  fi
}

write_mutated_audit() {
  local name="$1"
  local expression="$2"
  local target="$tmp_dir/$name.sh"
  cp "$SCRIPT_DIR/audit-iroha-release-readiness.sh" "$target"
  perl -0pi -e "$expression" "$target"
  chmod +x "$target"
  printf '%s' "$target"
}

setup_fixture
expect_success "complete fixture with default Minamoto URL" good

setup_fixture
expect_success "complete fixture uses configured mobile SDK release tag" good "" "1.2.3" "$nexus_url"

setup_fixture
IROHA_RELEASE_ASSET_VALIDATION_RETRY_DELAY_SECONDS=0 expect_success "iOS mobile release asset download retries transient failure" ios-download-flaky

setup_fixture
IROHA_NEXUS_LIVE_HEALTH=1 expect_success "complete fixture with live Nexus health" good

setup_fixture
IROHA_NEXUS_LIVE_HEALTH=1 \
NEXUS_EXPECTED_BUILD_COMMIT=abcdef1234567890abcdef1234567890abcdef12 \
NEXUS_EXPECTED_CHAIN_ID=fixture:nexus:chain \
NEXUS_EXPECTED_GENESIS_HASH=0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef \
  expect_success "process identity pins may repeat but cannot replace committed values" good

setup_fixture
mkdir -p "$tmp_dir/curl-home"
write_file "$tmp_dir/curl-home/.curlrc" \
  "location" \
  "insecure" \
  "header = \"Authorization: Bearer curlrc-secret\""
HOME="$tmp_dir/curl-home" IROHA_NEXUS_LIVE_HEALTH=true expect_success "curl argv disables ambient curlrc before every option" good
assert_curl_argv_contract

setup_fixture
IROHA_NEXUS_LIVE_HEALTH=1 NEXUS_HEALTH_TIMEOUT_SECONDS=60 NEXUS_HEALTH_ATTEMPTS=10 NEXUS_HEALTH_RETRY_DELAY_SECONDS=30 \
  expect_success "bounded Nexus live health settings accept their upper limits" good

setup_fixture
perl -0pi -e 's/abcdef1234567890abcdef1234567890abcdef12/0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef/' "$workspace/config/iroha-release-readiness.env"
IROHA_NEXUS_LIVE_HEALTH=1 NEXUS_EXPECTED_BUILD_COMMIT=0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef \
  expect_success "Nexus live health accepts an exact 64-character deployed build commit" nexus-health-64-commit

setup_fixture
IROHA_NEXUS_LIVE_HEALTH=1 expect_success "canonical /v1/mcp input normalizes to the Minamoto origin" good "v1.2.3" "" "https://MINAMOTO.sora.org/v1/mcp/"

setup_fixture
IROHA_NEXUS_LIVE_HEALTH=1 expect_success "explicit default HTTPS port normalizes to the Minamoto origin" good "v1.2.3" "" "https://minamoto.sora.org:443"

setup_fixture
IROHA_NEXUS_LIVE_HEALTH=1 NEXUS_HEALTH_RETRY_DELAY_SECONDS=0 expect_success "Nexus live health retries transient failure" nexus-health-flaky

setup_fixture
IROHA_NEXUS_REQUIRE_PRODUCTION_EVIDENCE=1 expect_failure "blocked Nexus production evidence cannot satisfy strict release" "status must be ready when --require-ready is used" good

setup_fixture
rm "$workspace/config/nexus-production-evidence.json"
expect_failure "missing Nexus production evidence manifest" "SORA Nexus production evidence manifest" good

setup_fixture
perl -0pi -e 's/"releaseEnabled": false/"releaseEnabled": true/' "$workspace/config/nexus-production-evidence.json"
expect_failure "release enabled while Nexus evidence blocked" "releaseEnabled must remain false while Nexus production evidence is blocked" good

setup_fixture
mkdir -p "$workspace/scripts"
cp "$SCRIPT_DIR/audit-nexus-production-evidence.sh" "$workspace/scripts/audit-nexus-production-evidence.sh"
chmod +x "$workspace/scripts/audit-nexus-production-evidence.sh"
perl -0pi -e 's/assertNoSecretLikeValues\(manifest\)/assertSecretLikeValuesAllowed(manifest)/' "$workspace/scripts/audit-nexus-production-evidence.sh"
NEXUS_PRODUCTION_EVIDENCE_AUDIT="$workspace/scripts/audit-nexus-production-evidence.sh" \
  expect_failure "missing Nexus production evidence secret-like value gate" "SORA Nexus production evidence secret-like value gate" good

setup_fixture
mkdir -p "$workspace/scripts"
cp "$SCRIPT_DIR/test-nexus-production-evidence-audit.sh" "$workspace/scripts/test-nexus-production-evidence-audit.sh"
chmod +x "$workspace/scripts/test-nexus-production-evidence-audit.sh"
perl -0pi -e 's/secret-like Nexus evidence value/Nexus secret value accepted/' "$workspace/scripts/test-nexus-production-evidence-audit.sh"
NEXUS_PRODUCTION_EVIDENCE_TEST="$workspace/scripts/test-nexus-production-evidence-audit.sh" \
  expect_failure "missing Nexus production evidence secret-like value negative test" "SORA Nexus production evidence secret-like value negative test" good

setup_fixture
IROHA_NEXUS_LIVE_HEALTH=1 expect_failure "Nexus live health failure" "SORA Nexus Torii live health check failed" nexus-health-fail

setup_fixture
IROHA_NEXUS_LIVE_HEALTH=1 expect_failure "Nexus live health invalid body" "SORA Nexus Torii live health response invalid" nexus-health-invalid

setup_fixture
IROHA_NEXUS_LIVE_HEALTH=1 expect_failure_without_leaks \
  "Nexus live health rejects non-JSON without parser fragments" \
  "health response must be valid JSON" \
  nexus-health-non-json \
  "parser-secret-token" "parser-password" "INVALID_JSON_FRAGMENT"

setup_fixture
health_tmp_root="$tmp_dir/nexus-health-temp-root"
mkdir -p "$health_tmp_root"
TMPDIR="$health_tmp_root" IROHA_NEXUS_LIVE_HEALTH=1 expect_failure \
  "Nexus invalid responses still clean temporary response artifacts" \
  "health response must be valid JSON" nexus-health-non-json
if find "$health_tmp_root" -mindepth 1 -maxdepth 1 -name 'fearless-nexus-health.*' -print -quit | grep -q .; then
  fail "Nexus live-health temporary response artifacts were not cleaned"
fi

setup_fixture
IROHA_NEXUS_LIVE_HEALTH=1 expect_failure "Nexus live health redirect rejection" "HTTP 302 returned" nexus-health-redirect

setup_fixture
IROHA_NEXUS_LIVE_HEALTH=1 expect_failure_without_leaks \
  "Nexus redirect diagnostics withhold secret response bodies" \
  "response body withheld" \
  nexus-health-redirect \
  "redirect-secret-token"

setup_fixture
IROHA_NEXUS_LIVE_HEALTH=1 expect_failure "Nexus live health content type rejection" "unexpected Content-Type text/plain" nexus-health-wrong-content-type

setup_fixture
IROHA_NEXUS_LIVE_HEALTH=1 expect_failure_without_leaks \
  "Nexus MIME diagnostics withhold secret response bodies" \
  "response body withheld" \
  nexus-health-wrong-content-type \
  "content-type-secret"

setup_fixture
IROHA_NEXUS_LIVE_HEALTH=1 expect_failure \
  "Nexus live health requires top-level chain identity" \
  "chain_id must be an exact top-level /status field" nexus-health-missing-chain-id

setup_fixture
IROHA_NEXUS_LIVE_HEALTH=1 expect_failure \
  "Nexus live health rejects nested-only chain identity" \
  "chain_id must be an exact top-level /status field" nexus-health-nested-chain-id

setup_fixture
IROHA_NEXUS_LIVE_HEALTH=1 expect_failure \
  "Nexus live health binds the exact chain identity" \
  "chain_id must exactly match NEXUS_EXPECTED_CHAIN_ID" nexus-health-wrong-chain-id

for chain_type_scenario in nexus-health-chain-id-number nexus-health-chain-id-null; do
  setup_fixture
  IROHA_NEXUS_LIVE_HEALTH=1 expect_failure \
    "Nexus live health rejects non-string chain identity $chain_type_scenario" \
    "chain_id must be a canonical lowercase ASCII identifier" \
    "$chain_type_scenario"
done

for chain_shape_scenario in \
  nexus-health-chain-id-uppercase \
  nexus-health-chain-id-leading-separator \
  nexus-health-chain-id-repeated-separator \
  nexus-health-chain-id-overlong; do
  setup_fixture
  IROHA_NEXUS_LIVE_HEALTH=1 expect_failure \
    "Nexus live health rejects noncanonical chain identity $chain_shape_scenario" \
    "chain_id must be a canonical lowercase ASCII identifier" \
    "$chain_shape_scenario"
done

setup_fixture
IROHA_NEXUS_LIVE_HEALTH=1 expect_failure \
  "Nexus live health requires top-level genesis identity" \
  "genesis_hash must be an exact top-level /status field" nexus-health-missing-genesis-hash

setup_fixture
IROHA_NEXUS_LIVE_HEALTH=1 expect_failure \
  "Nexus live health rejects nested-only genesis identity" \
  "genesis_hash must be an exact top-level /status field" nexus-health-nested-genesis-hash

setup_fixture
IROHA_NEXUS_LIVE_HEALTH=1 expect_failure \
  "Nexus live health binds the exact genesis identity" \
  "genesis_hash must exactly match NEXUS_EXPECTED_GENESIS_HASH" nexus-health-wrong-genesis-hash

for genesis_scenario in \
  nexus-health-genesis-hash-number \
  nexus-health-genesis-hash-null \
  nexus-health-genesis-hash-uppercase \
  nexus-health-genesis-hash-placeholder \
  nexus-health-genesis-hash-short; do
  setup_fixture
  IROHA_NEXUS_LIVE_HEALTH=1 expect_failure \
    "Nexus live health rejects malformed genesis identity $genesis_scenario" \
    "genesis_hash must be an exact non-placeholder 64-character lowercase hexadecimal hash" \
    "$genesis_scenario"
done

setup_fixture
IROHA_NEXUS_LIVE_HEALTH=1 expect_failure "Nexus live health stale observation" "observed_at_ms must be no more than 30 seconds ahead or five minutes behind" nexus-health-stale

setup_fixture
IROHA_NEXUS_LIVE_HEALTH=1 expect_failure "Nexus live health requires Nexus mode" "nexus must be an object" nexus-health-missing-nexus

setup_fixture
IROHA_NEXUS_LIVE_HEALTH=1 expect_failure "Nexus live health queue coherence" "queue_size must equal queue_queued plus queue_inflight" nexus-health-incoherent-queue

setup_fixture
IROHA_NEXUS_LIVE_HEALTH=1 expect_failure "Nexus live health requires a connected peer" "peers must be a positive safe integer" nexus-health-zero-peers

setup_fixture
IROHA_NEXUS_LIVE_HEALTH=1 expect_failure "Nexus live health rejects stale block progress" "block committed within the last five minutes" nexus-health-stale-block

setup_fixture
IROHA_NEXUS_LIVE_HEALTH=1 expect_failure "Nexus live health rejects compounded observation and block staleness" "last_block_committed_at_ms must be no more than 30 seconds ahead and must be within five minutes" nexus-health-compounded-stale

setup_fixture
IROHA_NEXUS_LIVE_HEALTH=1 expect_failure "Nexus live health rejects future block timestamps" "observed_at_ms must be no more than 30 seconds ahead" nexus-health-future-block

setup_fixture
IROHA_NEXUS_LIVE_HEALTH=1 expect_failure "Nexus live health requires non-empty route entries" "nexus.routing_policy.rules must be a non-empty array" nexus-health-empty-routes

setup_fixture
IROHA_NEXUS_LIVE_HEALTH=1 expect_failure "Nexus live health rejects malformed route entries" "nexus.routing_policy.rules[0].dataspace_id must be a safe integer" nexus-health-malformed-route

setup_fixture
IROHA_NEXUS_LIVE_HEALTH=1 expect_failure "Nexus live health rejects route entries without selectors" "matcher must contain account or instruction" nexus-health-empty-route-matcher

for route_scenario in \
  nexus-health-wrong-default-route \
  nexus-health-missing-second-route \
  nexus-health-wrong-route-selector \
  nexus-health-reordered-routes; do
  setup_fixture
  IROHA_NEXUS_LIVE_HEALTH=1 expect_failure \
    "Nexus live health rejects noncanonical policy $route_scenario" \
    "nexus.routing_policy must exactly match the canonical ordered SORA" \
    "$route_scenario"
done

setup_fixture
IROHA_NEXUS_LIVE_HEALTH=1 expect_failure "Nexus live health requires dataspace catalog" "dataspace_catalog must be a non-empty array" nexus-health-missing-catalog

setup_fixture
IROHA_NEXUS_LIVE_HEALTH=1 expect_failure "Nexus live health requires every canonical catalog target" "dataspace_catalog must contain canonical routing target 2/2" nexus-health-missing-catalog-target

setup_fixture
IROHA_NEXUS_LIVE_HEALTH=1 expect_failure "Nexus live health rejects sealed canonical catalog targets" "dataspace_catalog routing target 2/2 must not be sealed" nexus-health-sealed-catalog-target

setup_fixture
IROHA_NEXUS_LIVE_HEALTH=1 expect_failure "Nexus live health requires ready canonical lane manifests" "dataspace_catalog routing target 2/2 requires a ready governance manifest" nexus-health-unready-catalog-target

setup_fixture
IROHA_NEXUS_LIVE_HEALTH=1 expect_failure "Nexus live health rejects duplicate catalog targets" "dataspace_catalog contains duplicate lane/dataspace target 0/0" nexus-health-duplicate-catalog-target

setup_fixture
IROHA_NEXUS_LIVE_HEALTH=1 expect_failure "Nexus live health rejects placeholder build identities" "build.git_commit_sha must be a non-placeholder hexadecimal commit" nexus-health-placeholder-commit

setup_fixture
IROHA_NEXUS_LIVE_HEALTH=1 expect_failure "Nexus live health binds the exact deployed build identity" "build.git_commit_sha must exactly match NEXUS_EXPECTED_BUILD_COMMIT" nexus-health-wrong-commit

setup_fixture
IROHA_NEXUS_LIVE_HEALTH=1 expect_failure "Nexus live health response size bound" "response exceeded 131072 bytes" nexus-health-oversized

setup_fixture
IROHA_NEXUS_LIVE_HEALTH=1 expect_failure "Nexus live health enforces the response limit by bytes for multibyte bodies" "response exceeded 131072 bytes" nexus-health-multibyte-oversized

setup_fixture
IROHA_NEXUS_LIVE_HEALTH=1 NEXUS_HEALTH_ATTEMPTS=1 expect_failure_without_leaks \
  "Nexus transport diagnostics redact controls and credentials and stay bounded" \
  "curl transport failed" \
  nexus-health-fail \
  "transport-secret" "hunter2" "live-bearer-value" "live-api-key" \
  "basic-auth-secret" "proxy-auth-secret" "cookie-secret" "set-cookie-secret"

setup_fixture
IROHA_NEXUS_LIVE_HEALTH=1 expect_failure "Nexus live health requires curl streaming limit support" "curl 8.4 or newer is required" nexus-health-old-curl

setup_fixture
rm "$workspace/config/iroha-release-readiness.env"
expect_failure "missing mobile release tag" "IROHA_MOBILE_SDK_RELEASE_TAG" good "" "1.2.3" "$nexus_url"

setup_fixture
expect_failure "android release asset download fails" "Android Iroha mobile SDK release asset validation" android-download-fail

setup_fixture
write_mobile_only_iroha_release_config
expect_failure "missing JS SDK source" "One of IROHA_JS_SDK_VERSION" good "v1.2.3" "" "$nexus_url"

setup_fixture
write_file "$workspace/config/iroha-release-readiness.env" \
  "IROHA_MOBILE_SDK_RELEASE_REPO=hyperledger-iroha/iroha" \
  "IROHA_MOBILE_SDK_RELEASE_TAG=v1.2.3" \
  "IROHA_JS_SDK_RELEASE_REPO=hyperledger-iroha/iroha"
expect_failure "partial JS SDK GitHub release source" "IROHA_JS_SDK_RELEASE_REPO, IROHA_JS_SDK_RELEASE_TAG, IROHA_JS_SDK_RELEASE_ASSET, and IROHA_JS_SDK_RELEASE_SHA256 are required together" good "v1.2.3" "" "$nexus_url"

setup_fixture
expect_failure "JS SDK artifact validation fails" "Iroha JS SDK artifact validation" js-fail

setup_fixture
expect_failure "invalid Nexus URL" "NEXUS_TORII_URL must be an https URL" good "v1.2.3" "1.2.3" "http://minamoto.sora.org"

setup_fixture
expect_failure "credentialed Nexus URL" "NEXUS_TORII_URL must not contain credentials" good "v1.2.3" "1.2.3" "https://operator:secret@minamoto.sora.org"

setup_fixture
expect_failure "query-fragment Nexus URL" "NEXUS_TORII_URL must not contain query strings or fragments" good "v1.2.3" "1.2.3" "https://minamoto.sora.org?token=secret#fragment"

setup_fixture
expect_failure "Taira cannot satisfy Nexus URL" "canonical SORA Nexus production origin" good "v1.2.3" "1.2.3" "https://taira.sora.org"

setup_fixture
expect_failure "arbitrary public origin cannot satisfy Nexus URL" "canonical SORA Nexus production origin" good "v1.2.3" "1.2.3" "https://nexus.sora.org"

setup_fixture
expect_failure "loopback IPv4 cannot satisfy Nexus URL" "canonical SORA Nexus production origin" good "v1.2.3" "1.2.3" "https://127.0.0.1"

setup_fixture
expect_failure "loopback IPv6 cannot satisfy Nexus URL" "canonical SORA Nexus production origin" good "v1.2.3" "1.2.3" "https://[::1]"

setup_fixture
expect_failure "private RFC1918 origin cannot satisfy Nexus URL" "canonical SORA Nexus production origin" good "v1.2.3" "1.2.3" "https://10.0.0.8"

setup_fixture
expect_failure "non-default Minamoto port cannot satisfy Nexus URL" "canonical SORA Nexus production origin" good "v1.2.3" "1.2.3" "https://minamoto.sora.org:8443"

setup_fixture
expect_failure "Nexus URL rejects backslash path ambiguity" "path must be empty, /, or exactly /v1/mcp" good "v1.2.3" "1.2.3" 'https://minamoto.sora.org\v1\mcp'

setup_fixture
expect_failure "Nexus URL rejects literal dot segments" "must not contain dot segments" good "v1.2.3" "1.2.3" "https://minamoto.sora.org/v1/../status"

setup_fixture
expect_failure "Nexus URL rejects encoded dot segments" "must not contain dot segments" good "v1.2.3" "1.2.3" "https://minamoto.sora.org/v1/%2e%2e/status"

setup_fixture
expect_failure "Nexus URL rejects arbitrary paths" "path must be empty, /, or exactly /v1/mcp" good "v1.2.3" "1.2.3" "https://minamoto.sora.org/status"

setup_fixture
NEXUS_HEALTH_PATH=status expect_failure "Nexus health path must be exact" "NEXUS_HEALTH_PATH must be exactly /status" good

setup_fixture
NEXUS_HEALTH_PATH=/status/ expect_failure "Nexus health path rejects trailing slash drift" "NEXUS_HEALTH_PATH must be exactly /status" good

setup_fixture
NEXUS_HEALTH_PATH='/status?token=secret' expect_failure "Nexus health path rejects query drift" "NEXUS_HEALTH_PATH must be exactly /status" good

setup_fixture
IROHA_NEXUS_LIVE_HEALTH=TRUE expect_failure "Nexus live-health boolean rejects ambiguous truthy values" "IROHA_NEXUS_LIVE_HEALTH must be exactly one of" good

setup_fixture
IROHA_NEXUS_LIVE_HEALTH= expect_failure "Nexus live-health boolean rejects empty values" "IROHA_NEXUS_LIVE_HEALTH must be exactly one of" good

setup_fixture
IROHA_NEXUS_REQUIRE_PRODUCTION_EVIDENCE=yes expect_failure "Nexus evidence boolean rejects ambiguous truthy values" "IROHA_NEXUS_REQUIRE_PRODUCTION_EVIDENCE must be exactly one of" good

setup_fixture
IROHA_NEXUS_REQUIRE_PRODUCTION_EVIDENCE= expect_failure "Nexus evidence boolean rejects empty values" "IROHA_NEXUS_REQUIRE_PRODUCTION_EVIDENCE must be exactly one of" good

setup_fixture
NEXUS_HEALTH_TIMEOUT_SECONDS=0 expect_failure "Nexus timeout rejects zero" "NEXUS_HEALTH_TIMEOUT_SECONDS must be an integer from 1 through 60" good

setup_fixture
NEXUS_HEALTH_TIMEOUT_SECONDS=61 expect_failure "Nexus timeout rejects values above the bound" "NEXUS_HEALTH_TIMEOUT_SECONDS must be an integer from 1 through 60" good

setup_fixture
NEXUS_HEALTH_TIMEOUT_SECONDS=1.5 expect_failure "Nexus timeout rejects non-integers" "NEXUS_HEALTH_TIMEOUT_SECONDS must be an integer from 1 through 60" good

setup_fixture
NEXUS_HEALTH_ATTEMPTS=0 expect_failure "Nexus attempts reject zero" "NEXUS_HEALTH_ATTEMPTS must be an integer from 1 through 10" good

setup_fixture
NEXUS_HEALTH_ATTEMPTS=11 expect_failure "Nexus attempts reject values above the bound" "NEXUS_HEALTH_ATTEMPTS must be an integer from 1 through 10" good

setup_fixture
NEXUS_HEALTH_RETRY_DELAY_SECONDS=-1 expect_failure "Nexus retry delay rejects negative values" "NEXUS_HEALTH_RETRY_DELAY_SECONDS must be an integer from 0 through 30" good

setup_fixture
NEXUS_HEALTH_RETRY_DELAY_SECONDS=31 expect_failure "Nexus retry delay rejects values above the bound" "NEXUS_HEALTH_RETRY_DELAY_SECONDS must be an integer from 0 through 30" good

setup_fixture
perl -0pi -e 's/^NEXUS_EXPECTED_BUILD_COMMIT=.*\n?//m' "$workspace/config/iroha-release-readiness.env"
IROHA_NEXUS_LIVE_HEALTH=1 expect_failure "Nexus live health requires a pinned deployed build commit" "NEXUS_EXPECTED_BUILD_COMMIT is required" good

setup_fixture
perl -0pi -e 's/^NEXUS_EXPECTED_CHAIN_ID=.*\n?//m' "$workspace/config/iroha-release-readiness.env"
IROHA_NEXUS_LIVE_HEALTH=1 expect_failure \
  "Nexus live health requires a committed chain identity pin" \
  "NEXUS_EXPECTED_CHAIN_ID is required" good

setup_fixture
perl -0pi -e 's/^NEXUS_EXPECTED_GENESIS_HASH=.*\n?//m' "$workspace/config/iroha-release-readiness.env"
IROHA_NEXUS_LIVE_HEALTH=1 expect_failure \
  "Nexus live health requires a committed genesis identity pin" \
  "NEXUS_EXPECTED_GENESIS_HASH is required" good

setup_fixture
IROHA_NEXUS_LIVE_HEALTH=1 NEXUS_EXPECTED_BUILD_COMMIT=abcdef expect_failure "Nexus expected build commit rejects short hashes" "must be exactly 40 or 64 lowercase hexadecimal" good

setup_fixture
IROHA_NEXUS_LIVE_HEALTH=1 NEXUS_EXPECTED_BUILD_COMMIT=AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA expect_failure "Nexus expected build commit rejects uppercase hashes" "must be exactly 40 or 64 lowercase hexadecimal" good

setup_fixture
IROHA_NEXUS_LIVE_HEALTH=1 NEXUS_EXPECTED_BUILD_COMMIT=0000000000000000000000000000000000000000 expect_failure "Nexus expected build commit rejects placeholder hashes" "must not be a repeated-character placeholder" good

setup_fixture
IROHA_NEXUS_LIVE_HEALTH=1 NEXUS_EXPECTED_BUILD_COMMIT=1234567890abcdef1234567890abcdef12345678 expect_failure \
  "process environment cannot override the committed Nexus build pin" \
  "process NEXUS_EXPECTED_BUILD_COMMIT must not override the committed Iroha build pin" good

setup_fixture
NEXUS_EXPECTED_CHAIN_ID=Fixture:Nexus:Chain expect_failure \
  "process Nexus chain pin rejects uppercase identity" \
  "process NEXUS_EXPECTED_CHAIN_ID must use canonical lowercase ASCII segments" good

setup_fixture
NEXUS_EXPECTED_CHAIN_ID=fixture::nexus expect_failure \
  "process Nexus chain pin rejects repeated separators" \
  "process NEXUS_EXPECTED_CHAIN_ID must use canonical lowercase ASCII segments" good

setup_fixture
overlong_chain_pin="$(printf 'a%.0s' {1..129})"
NEXUS_EXPECTED_CHAIN_ID="$overlong_chain_pin" expect_failure \
  "process Nexus chain pin enforces the byte bound" \
  "process NEXUS_EXPECTED_CHAIN_ID must be at most 128 ASCII bytes" good

setup_fixture
NEXUS_EXPECTED_CHAIN_ID=fixture:nexus:other expect_failure \
  "process environment cannot override the committed Nexus chain pin" \
  "process NEXUS_EXPECTED_CHAIN_ID must not override the committed Iroha release pin" good

setup_fixture
NEXUS_EXPECTED_GENESIS_HASH=abcdef expect_failure \
  "process Nexus genesis pin rejects short hashes" \
  "process NEXUS_EXPECTED_GENESIS_HASH must be exactly 64 lowercase hexadecimal characters" good

setup_fixture
NEXUS_EXPECTED_GENESIS_HASH=0123456789ABCDEF0123456789abcdef0123456789abcdef0123456789abcdef expect_failure \
  "process Nexus genesis pin rejects uppercase hashes" \
  "process NEXUS_EXPECTED_GENESIS_HASH must be exactly 64 lowercase hexadecimal characters" good

setup_fixture
NEXUS_EXPECTED_GENESIS_HASH=0000000000000000000000000000000000000000000000000000000000000000 expect_failure \
  "process Nexus genesis pin rejects repeated placeholders" \
  "process NEXUS_EXPECTED_GENESIS_HASH must not be a repeated-character placeholder" good

setup_fixture
NEXUS_EXPECTED_GENESIS_HASH=1123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef expect_failure \
  "process environment cannot override the committed Nexus genesis pin" \
  "process NEXUS_EXPECTED_GENESIS_HASH must not override the committed Iroha release pin" good

setup_fixture
write_iroha_release_config "Fixture:Nexus:Chain"
expect_failure \
  "committed Nexus chain pin rejects noncanonical values even without live mode" \
  "committed NEXUS_EXPECTED_CHAIN_ID must use canonical lowercase ASCII segments" good

setup_fixture
write_iroha_release_config \
  "fixture:nexus:chain" \
  "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
expect_failure \
  "committed Nexus genesis pin rejects placeholders even without live mode" \
  "committed NEXUS_EXPECTED_GENESIS_HASH must not be a repeated-character placeholder" good

setup_fixture
write_file "$workspace/config/iroha-release-readiness.env" \
  "IROHA_MOBILE_SDK_RELEASE_REPO=hyperledger-iroha/iroha" \
  "IROHA_MOBILE_SDK_RELEASE_TAG=v1.2.3" \
  "IROHA_JS_SDK_RELEASE_REPO=hyperledger-iroha/iroha" \
  "IROHA_JS_SDK_RELEASE_TAG=v1.2.3" \
  "IROHA_JS_SDK_RELEASE_ASSET=iroha-js-release.tgz" \
  "IROHA_JS_SDK_RELEASE_SHA256=0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef" \
  "NEXUS_EXPECTED_BUILD_COMMIT=abcdef1234567890abcdef1234567890abcdef12" \
  "NEXUS_EXPECTED_CHAIN_ID=fixture:nexus:chain" \
  "NEXUS_EXPECTED_CHAIN_ID=fixture:nexus:other" \
  "NEXUS_EXPECTED_GENESIS_HASH=0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
expect_failure \
  "duplicate committed Nexus identity pins fail closed" \
  "Duplicate NEXUS_EXPECTED_CHAIN_ID in Iroha release defaults" good

setup_fixture
mutated_audit="$(write_mutated_audit nexus-no-disable 's/curl --disable -sS/curl -sS/')"
mkdir -p "$tmp_dir/curl-home"
write_file "$tmp_dir/curl-home/.curlrc" "location" "insecure"
HOME="$tmp_dir/curl-home" AUDIT_SCRIPT="$mutated_audit" IROHA_NEXUS_LIVE_HEALTH=1 NEXUS_HEALTH_ATTEMPTS=1 \
  expect_failure "ambient curlrc cannot alter the Nexus request" "--disable/-q must be the first argument" good

setup_fixture
mutated_audit="$(write_mutated_audit nexus-follow-redirects 's/curl --disable -sS/curl --disable --location -sS/')"
AUDIT_SCRIPT="$mutated_audit" IROHA_NEXUS_LIVE_HEALTH=1 NEXUS_HEALTH_ATTEMPTS=1 \
  expect_failure "Nexus curl contract rejects redirect following" "redirect following is forbidden" good

setup_fixture
mutated_audit="$(write_mutated_audit nexus-insecure-tls 's/curl --disable -sS/curl --disable --insecure -sS/')"
AUDIT_SCRIPT="$mutated_audit" IROHA_NEXUS_LIVE_HEALTH=1 NEXUS_HEALTH_ATTEMPTS=1 \
  expect_failure "Nexus curl contract rejects insecure TLS" "insecure TLS is forbidden" good

setup_fixture
mutated_audit="$(write_mutated_audit nexus-broadened-protocol "s/--proto '=https'/--proto '=http,https'/")"
AUDIT_SCRIPT="$mutated_audit" IROHA_NEXUS_LIVE_HEALTH=1 NEXUS_HEALTH_ATTEMPTS=1 \
  expect_failure "Nexus curl contract rejects broadened transport protocols" "--proto must be =https" good

setup_fixture
mutated_audit="$(write_mutated_audit nexus-no-redirect-protocol "s/--proto-redir '=https'/--silent/")"
AUDIT_SCRIPT="$mutated_audit" IROHA_NEXUS_LIVE_HEALTH=1 NEXUS_HEALTH_ATTEMPTS=1 \
  expect_failure "Nexus curl contract rejects missing HTTPS redirect policy" "missing --proto-redir =https" good

setup_fixture
mutated_audit="$(write_mutated_audit nexus-no-tls-floor 's/--tlsv1\.2/--silent/')"
AUDIT_SCRIPT="$mutated_audit" IROHA_NEXUS_LIVE_HEALTH=1 NEXUS_HEALTH_ATTEMPTS=1 \
  expect_failure "Nexus curl contract rejects missing TLS floor" "missing --tlsv1.2" good

setup_fixture
mutated_audit="$(write_mutated_audit nexus-follow-limit 's/--max-redirs 0/--max-redirs 1/')"
AUDIT_SCRIPT="$mutated_audit" IROHA_NEXUS_LIVE_HEALTH=1 NEXUS_HEALTH_ATTEMPTS=1 \
  expect_failure "Nexus curl contract rejects nonzero redirect limits" "--max-redirs must be 0" good

setup_fixture
mutated_audit="$(write_mutated_audit nexus-response-limit-drift 's/--max-filesize 131072/--max-filesize 131073/')"
AUDIT_SCRIPT="$mutated_audit" IROHA_NEXUS_LIVE_HEALTH=1 NEXUS_HEALTH_ATTEMPTS=1 \
  expect_failure "Nexus curl contract rejects response-limit drift" "unexpected max filesize" good

setup_fixture
write_file "$workspace/fearless-wallet-web/src/consts/universalWallet.ts" \
  "const UNIVERSAL_WALLET_IROHA_NETWORKS = { nexus: { toriiBaseUrl: null } };" \
  "const UNIVERSAL_WALLET_NEXUS_REGISTRY_ENTRY = { endpoints: [] };"
expect_failure "Nexus URL missing from committed sources" "SORA Nexus Torii URL" good

setup_fixture
rm "$parent/iroha/.github/workflows/mobile_sdk_artifacts.yml"
expect_failure "missing Iroha mobile workflow" "Iroha mobile SDK GitHub Actions workflow" good

echo "[iroha-readiness-test] all $test_case_count tests passed"
