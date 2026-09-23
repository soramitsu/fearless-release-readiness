#!/usr/bin/env bash
set -euo pipefail

SCRIPT_PATH="${BASH_SOURCE[0]:-$0}"
SCRIPT_DIR="$(cd "$(dirname "$SCRIPT_PATH")" && pwd)"
AUDIT_SCRIPT="$SCRIPT_DIR/audit-iroha-release-readiness.sh"
SOURCE_IROHA_ROOT="${IROHA_SOURCE_FIXTURE_ROOT:-$(cd "$SCRIPT_DIR/../../iroha" && pwd)}"

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

copy_iroha_source_fixture() {
  local relative_path="$1"
  local source="$SOURCE_IROHA_ROOT/$relative_path"
  local destination="$parent/iroha/$relative_path"
  [[ -f "$source" ]] || fail "Iroha source fixture is missing: $source"
  mkdir -p "$(dirname "$destination")"
  cp "$source" "$destination"
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

write_fake_cargo() {
  local file="$tmp_dir/bin/cargo"
  write_file "$file" \
    '#!/usr/bin/env bash' \
    'set -euo pipefail' \
    'unsigned_genesis=""' \
    'review=""' \
    'saw_validator=false' \
    'args=("$@")' \
    'for ((i = 0; i < ${#args[@]}; i += 1)); do' \
    '  case "${args[$i]}" in' \
    '    validate-taira-nevo-review-v1) saw_validator=true ;;' \
    '    --unsigned-genesis) unsigned_genesis="${args[$((i + 1))]:-}"; i=$((i + 1)) ;;' \
    '    --review) review="${args[$((i + 1))]:-}"; i=$((i + 1)) ;;' \
    '  esac' \
    'done' \
    '[[ "$saw_validator" == true ]] || { echo "unexpected cargo command" >&2; exit 2; }' \
    '[[ -f "$unsigned_genesis" && -f "$review" ]] || { echo "missing NEVO inputs" >&2; exit 2; }' \
    '[[ "$(basename "$review")" != "mutated-review.json" ]] || { echo "native recomposition rejected mutation" >&2; exit 1; }' \
    'unsigned_sha256="$(shasum -a 256 "$unsigned_genesis" | awk '\''{print $1}'\'')"' \
    'review_sha256="$(shasum -a 256 "$review" | awk '\''{print $1}'\'')"' \
    'printf '\''{"native_recomposition_passed":true,"review_sha256":"%s","status":"validated","unsigned_genesis_sha256":"%s"}\n'\'' "$review_sha256" "$unsigned_sha256"'
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
    'security_failure() { echo "curl security contract violation: $*" >&2; exit 2; }' \
    'for transport_variable in CURL_CA_BUNDLE SSL_CERT_FILE SSL_CERT_DIR OPENSSL_CONF HTTP_PROXY HTTPS_PROXY ALL_PROXY NO_PROXY http_proxy https_proxy all_proxy no_proxy; do' \
    '  [[ -z "${!transport_variable+x}" ]] || security_failure "ambient curl transport authority reached live health request: $transport_variable"' \
    'done' \
    'if [[ "${1:-}" == "--disable" && "${2:-}" == "--version" && $# -eq 2 ]]; then' \
    '  [[ "$scenario" == "nexus-health-old-curl" ]] && version=8.3.0 || version=8.4.0' \
    '  printf "curl %s (fixture) libcurl/%s\n" "$version" "$version"' \
    '  exit 0' \
    'fi' \
    ': > "$state_dir/curl.argv"' \
    'printf "%s\n" "$@" > "$state_dir/curl.argv"' \
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
    '    observed_ms="$((now_ms - 240000))"' \
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

  write_file "$parent/iroha/crates/iroha_kagami/src/genesis/profile.rs" \
    'pub const TAIRA_XOR_SCALE: u32 = 9;' \
    'const PUBLIC_TAIRA_CHAIN_ID: &str = "fc56984b-2be7-431d-840e-21514d1883f0";'
  write_file "$parent/iroha/crates/iroha_kagami/src/genesis/generate.rs" \
    'let spec = NumericSpec::fractional(TAIRA_XOR_SCALE);'
  write_file "$parent/iroha/crates/iroha_torii/src/explorer.rs" \
    '#[norito(rename = "box")]' \
    'pub r#box: ExplorerInstructionBoxDto,'
  write_file "$parent/iroha/crates/iroha_torii_shared/src/lib.rs" \
    'pub const SORACLOUD_SERVED_SERVICE_NAME_HEADER: &str = "x-iroha-soracloud-served-service-name";' \
    'pub const SORACLOUD_SERVED_SERVICE_VERSION_HEADER: &str = "x-iroha-soracloud-served-service-version";' \
    'pub const SORACLOUD_SERVED_REPLICA_SLOT_HEADER: &str = "x-iroha-soracloud-served-replica-slot";' \
    'pub const SORACLOUD_SERVED_PROCESS_GENERATION_HEADER: &str = "x-iroha-soracloud-served-process-generation";' \
    'pub const SORACLOUD_SERVED_MATERIALIZED_BUNDLE_HASH_HEADER: &str = "x-iroha-soracloud-served-materialized-bundle-hash";'
  write_file "$parent/iroha/crates/iroha_torii/src/lib.rs" \
    '#[cfg(any(feature = "p2p_ws", feature = "connect"))]' \
    'async fn execute_incoming_torii_proxy_request_with_admission_inner() {' \
    '    ToriiProxyRequestKindV4::HostedHttp(hosted_request);' \
    '    resolve_exact_hosted_http_runtime_target();' \
    '    overwrite_soracloud_served_revision_headers(&mut response, &target);' \
    '}' \
    '#[cfg(any(feature = "p2p_ws", feature = "connect"))]' \
    'fn reject_incoming_torii_proxy_request_capacity() {}' \
    'fn authoritative_weighted_hosted_http_versions() {' \
    '    if deployment.process_generation == 0 {' \
    '        fail("no positive generation");' \
    '    }' \
    '    Ok((versions, deployment.process_generation));' \
    '}' \
    '#[cfg(feature = "app_api")]' \
    '#[derive(Clone, Debug)]' \
    'struct ResolvedHostedHttpTarget {' \
    '    materialized_bundle_hash: String,' \
    '    process_generation: u64,' \
    '}' \
    '#[cfg(feature = "app_api")]' \
    '#[derive(Clone, Debug)]' \
    'struct LocalHostedHttpReplicaRuntime {' \
    '    materialized_bundle_hash: String,' \
    '    process_generation: u64,' \
    '}' \
    '#[cfg(feature = "app_api")]' \
    'fn ensure_matching_hosted_http_materialized_bundle_hash() {' \
    '    if authoritative_bundle_hash != local_bundle_hash {' \
    '        SoracloudRuntimeExecutionErrorKind::Unavailable;' \
    '        "local bundle hash does not match authoritative runtime state";' \
    '    }' \
    '    if authoritative_process_generation != local_process_generation {' \
    '        "local process generation";' \
    '        "does not match authoritative generation";' \
    '    }' \
    '}' \
    '#[cfg(feature = "app_api")]' \
    '#[cfg(any(feature = "p2p_ws", feature = "connect"))]' \
    'fn ensure_local_hosted_http_snapshot_origin() {' \
    '    snapshot.local_peer_id.as_deref().ok_or_else;' \
    '    app.local_peer_id.as_ref().ok_or_else;' \
    '    "runtime snapshot has no exact local peer identity";' \
    '    snapshot_peer_id == local_peer_id.to_string();' \
    '}' \
    '#[cfg(feature = "app_api")]' \
    '#[cfg(not(any(feature = "p2p_ws", feature = "connect")))]' \
    'fn ensure_local_hosted_http_snapshot_origin() {' \
    '    SoracloudRuntimeExecutionErrorKind::Unavailable;' \
    '    "runtime snapshot identity requires peer connectivity";' \
    '}' \
    '#[cfg(feature = "app_api")]' \
    'fn resolve_local_hosted_http_replica_runtime() {' \
    '    plan.process_generation.filter(|value| *value > 0)?;' \
    '    process_generation,' \
    '}' \
    '#[cfg(feature = "app_api")]' \
    'fn resolve_hosted_http_runtime_target() {' \
    '    authoritative_weighted_hosted_http_versions(world, current_sequence, &service_name);' \
    '    select_authoritative_hosted_http_replica();' \
    '    ensure_matching_hosted_http_materialized_bundle_hash();' \
    '    process_generation,' \
    '}' \
    '#[cfg(feature = "app_api")]' \
    'fn resolve_exact_hosted_http_runtime_target() {' \
    '    authoritative_weighted_hosted_http_versions(world, current_sequence, service_name);' \
    '    runtime_state.health_status;' \
    '    SoraServiceHealthStatusV1::Healthy;' \
    '    "has no matching healthy authoritative runtime state";' \
    '    "has no matching healthy local runtime";' \
    '    ensure_matching_hosted_http_materialized_bundle_hash();' \
    '    process_generation,' \
    '}' \
    '#[cfg(feature = "app_api")]' \
    'fn overwrite_soracloud_served_revision_headers() {' \
    '    target.materialized_bundle_hash;' \
    '    headers.insert(SORACLOUD_SERVED_SERVICE_NAME_HEADER, service_name);' \
    '    headers.insert(SORACLOUD_SERVED_SERVICE_VERSION_HEADER, service_version);' \
    '    headers.insert(SORACLOUD_SERVED_REPLICA_SLOT_HEADER, replica_slot);' \
    '    SORACLOUD_SERVED_PROCESS_GENERATION_HEADER;' \
    '    target.process_generation;' \
    '    headers.insert(SORACLOUD_SERVED_MATERIALIZED_BUNDLE_HASH_HEADER, materialized_bundle_hash);' \
    '}' \
    '#[cfg(feature = "app_api")]' \
    'fn exact_soracloud_served_revision_header() {' \
    '    let mut values = headers.get_all(name).iter();' \
    '    values.next().ok_or("missing Torii-owned")?;' \
    '    if values.next().is_some() {' \
    '        fail("duplicate Torii-owned");' \
    '    }' \
    '}' \
    '#[cfg(feature = "app_api")]' \
    'fn validate_soracloud_served_revision_headers() {' \
    '    let expected_replica_slot = target.replica_slot.to_string();' \
    '    SORACLOUD_SERVED_SERVICE_NAME_HEADER;' \
    '    target.route_match.service_name.as_str();' \
    '    SORACLOUD_SERVED_SERVICE_VERSION_HEADER;' \
    '    target.route_match.service_version.as_str();' \
    '    SORACLOUD_SERVED_REPLICA_SLOT_HEADER;' \
    '    target.replica_slot.to_string();' \
    '    SORACLOUD_SERVED_PROCESS_GENERATION_HEADER;' \
    '    target.process_generation.to_string();' \
    '    SORACLOUD_SERVED_MATERIALIZED_BUNDLE_HASH_HEADER;' \
    '    target.materialized_bundle_hash.as_str();' \
    '    exact_soracloud_served_revision_header(response.headers(), name)?;' \
    '    if actual != expected {' \
    '        fail("served revision mismatch");' \
    '    }' \
    '}' \
    '#[cfg(feature = "app_api")]' \
    'async fn proxy_soracloud_public_hosted_http_locally() {}' \
    'async fn proxy_soracloud_public_hosted_http() {' \
    '    overwrite_soracloud_served_revision_headers(&mut response, &target);' \
    '    match result {' \
    '        Ok(Some(mut response)) => {' \
    '            validate_soracloud_served_revision_headers(&response, &target)' \
    '                .and_then(|()| {' \
    '                    overwrite_soracloud_served_revision_headers(&mut response, &target);' \
    '                });' \
    '        }' \
    '        Ok(None) => {}' \
    '    }' \
    '}' \
    '#[cfg(feature = "app_api")]' \
    'fn current_public_soradns_ledger_time_ms() {}'
  write_file "$parent/iroha/crates/iroha_cli/src/taira.rs" \
    'const ROUTE_CHECKS: &[(&str, &str, &[u16])] = &[' \
    '    (' \
    '        "soracloud_status",' \
    '        "/v1/soracloud/status",' \
    '        &[401],' \
    '    ),' \
    '    (' \
    '        "sumeragi_status",' \
    '        "/v1/sumeragi/status",' \
    '        &[401],' \
    '    ),' \
    '];' \
    'fn run_doctor() {' \
    '    match name {' \
    '        "musubi_ordered_prefix" | "soracloud_status" => {' \
    '            validate_canonical_authentication_challenge(result.body.as_ref()).err();' \
    '        }' \
    '        "sumeragi_status" => {' \
    '            validate_operator_signature_authentication_challenge(result.body.as_ref()).err();' \
    '        }' \
    '    }' \
    '}' \
    'struct ExactInrouCanaryStatus { process_generation: u64 }' \
    'struct InrouCanaryConvergence { exact_status: Option<ExactInrouCanaryStatus>, identities: Identities }' \
    'impl InrouCanaryConvergence {' \
    '    fn observe_status() {' \
    '        current.process_generation != status.process_generation;' \
    '        self.identities.clear();' \
    '        self.exact_status = None;' \
    '        self.identities.clear();' \
    '        let error = "route evidence arrived without exact authoritative status";' \
    '        status.process_generation != evidence.process_generation;' \
    '    }' \
    '}' \
    'fn validate_exact_inrou_canary_status() {' \
    '    revision.get("service_version");' \
    '    Some(deployment.service_version.as_str());' \
    '    revision.get("service_manifest_hash");' \
    '    Some(deployment.service_manifest_hash.as_str());' \
    '    revision.get("container_manifest_hash");' \
    '    Some(deployment.container_manifest_hash.as_str());' \
    '    revision.get("process_generation");' \
    '    .filter(|generation| *generation > 0);' \
    '    matching_services.next().is_some();' \
    '}' \
    'fn exact_inrou_canary_header() {}' \
    'fn validate_exact_inrou_canary_route() {' \
    '    SORACLOUD_SERVED_SERVICE_NAME_HEADER;' \
    '    served_service_name != deployment.service_name.as_str();' \
    '    SORACLOUD_SERVED_SERVICE_VERSION_HEADER;' \
    '    served_service_version != deployment.service_version.as_str();' \
    '    SORACLOUD_SERVED_REPLICA_SLOT_HEADER;' \
    '    body_replica_slot != Some(replica_slot);' \
    '    SORACLOUD_SERVED_PROCESS_GENERATION_HEADER;' \
    '    process_generation != expected_process_generation;' \
    '    SORACLOUD_SERVED_MATERIALIZED_BUNDLE_HASH_HEADER;' \
    '    served_bundle_hash != deployment.bundle_hash.as_str();' \
    '    "served_process_generation": process_generation;' \
    '}' \
    'fn inrou_canary_health_path() {}' \
    'fn verify_inrou_canary() {' \
    '    crate::soracloud::fetch_taira_inrou_canary_status();' \
    '    match convergence.observe_status(observed_status) {' \
    '        Err(_) => {' \
    '            let detail = "route probe skipped until exact authoritative status is current";' \
    '            continue;' \
    '        }' \
    '    }' \
    '    // A full route set only becomes final after a later exact status poll' \
    '    if convergence.is_complete() {' \
    '        completion_confirmed = true;' \
    '        break;' \
    '    }' \
    '    validate_exact_inrou_canary_route();' \
    '    convergence.record_route(evidence);' \
    '    let routes_ready = identities.len() == 4 && completion_confirmed;' \
    '    "post_route_status_confirmed".to_owned();' \
    '}' \
    'fn run_write_canary() {}' \
    'fn validate_canonical_authentication_challenge() {' \
    '    if body.len() != 2 { return; }' \
    '    if body.get("code").and_then(Value::as_str) != Some("canonical_authentication_required") { return; }' \
    '    if body.get("message").and_then(Value::as_str)' \
    '        != Some("canonical account request authentication is required") { return; }' \
    '}' \
    'fn validate_operator_signature_authentication_challenge() {' \
    '    if body.len() != 2 { return; }' \
    '    if body.get("code").and_then(Value::as_str) != Some("operator_signature_missing") { return; }' \
    '    if body.get("message").and_then(Value::as_str)' \
    '        != Some("missing required operator signature header `x-iroha-operator-public-key`") { return; }' \
    '}' \
    'fn tagged_enum_name() {' \
    '    value.as_object()?.get(field)?.as_str();' \
    '}' \
    'fn mcp_tool_names() {}'
  write_file "$parent/iroha/crates/iroha_cli/src/soracloud.rs" \
    'const TAIRA_INROU_CANARY_SERVICE_VERSION_PREFIX_V1: &str = "artifact-";' \
    'fn derive_taira_inrou_canary_service_version() {' \
    '    revision_seed.service.service_version.clear();' \
    '    let revision_digest = Hash::new(json::to_vec(&revision_seed));' \
    '    TAIRA_INROU_CANARY_SERVICE_VERSION_PREFIX_V1;' \
    '    hex::encode(revision_digest.as_ref());' \
    '}' \
    'fn install_taira_inrou_canary_service_version() {}' \
    'fn validate_taira_inrou_canary_bundle() {' \
    '    let expected_service_version = derive_taira_inrou_canary_service_version(bundle)?;' \
    '    if bundle.service.service_version != expected_service_version {}' \
    '}' \
    '#[cfg(unix)]' \
    'fn fixture_boundary() {}' \
    'pub(crate) struct TairaInrouCanaryDeployment {' \
    '    pub service_version: String,' \
    '    pub service_manifest_hash: String,' \
    '    pub container_manifest_hash: String,' \
    '    pub bundle_hash: String,' \
    '}' \
    'fn derive_service_mutation_precondition() {' \
    '    if matching.next().is_some() { fail("duplicate snapshots"); }' \
    '    match (mode, current) {' \
    '        (MutationMode::Deploy, None) => Ok(SoraServiceMutationPreconditionV1::ServiceAbsent),' \
    '        (MutationMode::Deploy, Some(_)) => fail("before artifact publication"),' \
    '        (MutationMode::Upgrade, None) => fail("before artifact publication"),' \
    '        (MutationMode::Upgrade, Some(service)) => {' \
    '            service.get("current_version");' \
    '            if current_version == service_version { fail("before artifact publication"); }' \
    '            let revision = service.get("latest_revision");' \
    '            revision.get("service_version");' \
    '            if revision_version != current_version { fail("revision drift"); }' \
    '            let service_manifest_hash = revision.get("service_manifest_hash").parse::<Hash>();' \
    '            let container_manifest_hash = revision.get("container_manifest_hash").parse::<Hash>();' \
    '            let process_generation = revision.get("process_generation").filter(|generation| *generation > 0);' \
    '            let config_generation = revision.get("config_generation");' \
    '            let secret_generation = revision.get("secret_generation");' \
    '            if service.get("active_rollout").is_some() { fail("refuses to supersede the active rollout"); }' \
    '            Ok(SoraServiceMutationPreconditionV1::ExactCurrentRevision(' \
    '                SoraServiceExactCurrentRevisionPreconditionV1 {' \
    '                    service_version: current_version.to_owned(),' \
    '                    service_manifest_hash,' \
    '                    container_manifest_hash,' \
    '                    process_generation,' \
    '                    config_generation,' \
    '                    secret_generation,' \
    '                },' \
    '            ));' \
    '        }' \
    '    }' \
    '}' \
    'fn preflight_taira_inrou_mutation_target(' \
    ') -> Result<SoraServiceMutationPreconditionV1> {' \
    '    derive_service_mutation_precondition(status, service_name, service_version, mode, "Taira Inrou")' \
    '}' \
    'fn status_tagged_enum_name() {' \
    '    value.as_object()?.get(field)?.as_str();' \
    '}' \
    'fn preflight_service_upgrade_identity() {' \
    '    if mode == MutationMode::Deploy { return; }' \
    '    status_tagged_enum_name(value, "execution_plane");' \
    '    status_tagged_enum_name(value, "runtime");' \
    '    service.get("route_host");' \
    '    service.get("route_path_prefix");' \
    '    service.get("route_service_port");' \
    '    service.get("route_visibility");' \
    '    service.get("route_tls_mode");' \
    '    u64::from(route.service_port.get());' \
    '    fail("cannot change route identity before artifact publication");' \
    '}' \
    'pub(crate) fn run_taira_inrou_canary_deployment() {' \
    '    fetch_torii_soracloud_status();' \
    '    let precondition = preflight_taira_inrou_mutation_target();' \
    '    preflight_service_upgrade_identity();' \
    '    register_built_sorafs_manifest();' \
    '    run_service_bundle_mutation(' \
    '        precondition,' \
    '    );' \
    '    let receipt = TairaInrouCanaryDeployment {' \
    '        service_manifest_hash: staged.receipt.service_manifest_hash,' \
    '        container_manifest_hash: staged.receipt.container_manifest_hash,' \
    '    };' \
    '}' \
    '#[derive(clap::ValueEnum)]' \
    'enum FixtureBoundary {}' \
    'struct SignedBundleRequest {' \
    '    precondition: SoraServiceMutationPreconditionV1,' \
    '}' \
    '#[derive(Clone, Debug, JsonSerialize, JsonDeserialize)]' \
    'struct SignedAppInfraRequest {}' \
    'fn run_service_bundle_mutation(' \
    '    precondition: SoraServiceMutationPreconditionV1,' \
    ') {' \
    '    signed_bundle_request(' \
    '        precondition,' \
    '    );' \
    '}' \
    'fn run_signed_service_bundle_mutation() {}' \
    'fn signed_bundle_request(' \
    '    precondition: SoraServiceMutationPreconditionV1,' \
    ') {' \
    '    encode_bundle_with_materials_provenance_payload(' \
    '        &precondition,' \
    '    );' \
    '    SignedBundleRequest {' \
    '        precondition,' \
    '    };' \
    '}' \
    'fn signed_app_infra_request() {}' \
    'pub(crate) fn fetch_taira_inrou_canary_status() {' \
    '    send_torii_soracloud_authenticated_get("Taira Inrou canary status");' \
    '}' \
    'fn fetch_torii_soracloud_app_infra_status() {}' \
    '    fn taira_inrou_status_requires_and_uses_protected_read_signer() {' \
    '        let headers = requests[0].headers;' \
    '        let required = [HEADER_IROHA_ACCOUNT, HEADER_IROHA_SIGNATURE, HEADER_IROHA_TIMESTAMP_MS, HEADER_IROHA_NONCE];' \
    '    }' \
    '    fn taira_inrou_mutation_preflight_is_exact_and_runs_before_publication() {' \
    '        "execution_plane": {"execution_plane": "HttpService"};' \
    '        "runtime": {"runtime": "Inrou"};' \
    '        "route_service_port": TAIRA_INROU_CANARY_SERVICE_PORT_V1;' \
    '        "route_visibility": "Public";' \
    '        "route_tls_mode": "Required";' \
    '        preflight_service_upgrade_identity();' \
    '        "route drift must fail before artifact publication";' \
    '        "upgrade must not publish while another rollout is active";' \
    '    }' \
    '    #[test]' \
    '    fn taira_inrou_canary_validator_accepts_published_v1_bundle() {}' \
    '    #[test]' \
    '    fn fetch_torii_agent_autonomy_status_rejects_invalid_url() {}'
  write_file "$parent/iroha/crates/iroha_data_model/src/soracloud/deployment.rs" \
    'pub struct SoraServiceExactCurrentRevisionPreconditionV1 {' \
    '    pub service_version: String,' \
    '    pub service_manifest_hash: Hash,' \
    '    pub container_manifest_hash: Hash,' \
    '    pub process_generation: u64,' \
    '}' \
    '/// Signed compare-and-set condition for a service deploy or upgrade.' \
    'pub enum SoraServiceMutationPreconditionV1 {' \
    '    ServiceAbsent,' \
    '    ExactCurrentRevision(SoraServiceExactCurrentRevisionPreconditionV1),' \
    '}' \
    '/// Mutation mode recorded for authoritative Soracloud state updates.'
  write_file "$parent/iroha/crates/iroha_data_model/src/soracloud/hosting.rs" \
    'pub struct SoraAppInfraExactCurrentRevisionPreconditionV1 {' \
    '    pub app_version: String,' \
    '    pub manifest_hash: Hash,' \
    '    pub revision_count: u32,' \
    '}' \
    '/// Signed compare-and-set condition for an app topology deploy or upgrade.' \
    'pub enum SoraAppInfraMutationPreconditionV1 {' \
    '    AppAbsent,' \
    '    ExactCurrentRevision(SoraAppInfraExactCurrentRevisionPreconditionV1),' \
    '}' \
    '/// Authoritative app-level Soracloud infrastructure state.'
  write_file "$parent/iroha/crates/iroha_data_model/src/soracloud/tests/manifest_validation.rs" \
    'fn service_rollout_state_validate_rejects_missing_or_reused_baseline() {' \
    '    for baseline_version in ["", "1.1.0"] {' \
    '        "baseline must be present and distinct from the candidate";' \
    '        assert_soracloud_invalid_field(error, "baseline_version");' \
    '    }' \
    '}' \
    '#[test]' \
    'fn service_deployment_state_validate_rejects_active_candidate_different_from_current() {' \
    '    candidate_version = "1.2.0".to_owned();' \
    '    assert_soracloud_invalid_field(error, "active_rollout.candidate_version");' \
    '}' \
    '#[test]' \
    'fn service_deployment_state_validate_rejects_zero_or_full_canary_allocations() {' \
    '    for canary_percent in [0, 100] {}' \
    '    for traffic_percent in [0, 100] {}' \
    '    assert_soracloud_invalid_field(error, "canary_percent");' \
    '    assert_soracloud_invalid_field(error, "traffic_percent");' \
    '}' \
    '#[test]' \
    'fn service_deployment_state_validate_rejects_non_canary_active_rollout() {}'
  write_file "$parent/iroha/crates/iroha_data_model/src/isi/soracloud.rs" \
    'pub struct DeploySoracloudService {' \
    '    /// Signed atomic condition requiring this service to remain absent until execution.' \
    '    pub precondition: SoraServiceMutationPreconditionV1,' \
    '}' \
    'pub struct UpgradeSoracloudService {' \
    '    /// Signed atomic condition binding the exact active revision observed by the caller.' \
    '    pub precondition: SoraServiceMutationPreconditionV1,' \
    '}' \
    'pub struct RollbackSoracloudService {}' \
    'pub struct DeploySoracloudAppInfra {' \
    '    /// Signed atomic condition requiring this app topology to remain absent until execution.' \
    '    pub precondition: SoraAppInfraMutationPreconditionV1,' \
    '}' \
    'impl crate::seal::Instruction for DeploySoracloudAppInfra {}' \
    'pub struct UpgradeSoracloudAppInfra {' \
    '    /// Signed atomic condition binding the exact active topology observed by the caller.' \
    '    pub precondition: SoraAppInfraMutationPreconditionV1,' \
    '}' \
    'impl crate::seal::Instruction for UpgradeSoracloudAppInfra {}'
  write_file "$parent/iroha/crates/iroha_data_model/src/soracloud/host_protocol.rs" \
    'pub fn encode_app_infra_provenance_payload(' \
    '    precondition: &SoraAppInfraMutationPreconditionV1,' \
    ') {' \
    '    norito::encode_canonical(&(manifest.clone(), precondition.clone()));' \
    '}' \
    '/// Encode the canonical provenance signature payload for deployment bundles,' \
    'pub fn encode_bundle_with_materials_provenance_payload(' \
    '    precondition: &SoraServiceMutationPreconditionV1,' \
    ') {' \
    '    norito::encode_canonical(&(' \
    '        bundle.clone(),' \
    '        initial_service_configs.clone(),' \
    '        initial_service_secrets.clone(),' \
    '        precondition.clone(),' \
    '    ));' \
    '}' \
    '/// Encode the canonical provenance signature payload for service rollback.'
  write_file "$parent/iroha/crates/iroha_core/src/smartcontracts/isi/soracloud.rs" \
    'fn verify_bundle_provenance(' \
    '    precondition: &SoraServiceMutationPreconditionV1,' \
    ') {' \
    '    encode_bundle_with_materials_provenance_payload(' \
    '        precondition,' \
    '    );' \
    '}' \
    'fn verify_app_infra_provenance() {}' \
    'fn enforce_service_mutation_precondition() {' \
    '    match (action, precondition, existing) {' \
    '        (SoraServiceLifecycleActionV1::Deploy,' \
    '         SoraServiceMutationPreconditionV1::ServiceAbsent,' \
    '         None) => Ok(()),' \
    '        (SoraServiceLifecycleActionV1::Upgrade,' \
    '         SoraServiceMutationPreconditionV1::ExactCurrentRevision(' \
    '            SoraServiceExactCurrentRevisionPreconditionV1 {' \
    '                service_version,' \
    '                service_manifest_hash,' \
    '                container_manifest_hash,' \
    '                process_generation,' \
    '            },' \
    '         ), Some(current)) if' \
    '            service_version.trim().is_empty() || *process_generation == 0 =>' \
    '            fail("invalid exact revision"),' \
    '        (SoraServiceLifecycleActionV1::Upgrade,' \
    '         SoraServiceMutationPreconditionV1::ExactCurrentRevision(_),' \
    '         Some(current)) if' \
    '            current.current_service_version.as_str() == service_version.as_str()' \
    '            && &current.current_service_manifest_hash == service_manifest_hash' \
    '            && &current.current_container_manifest_hash == container_manifest_hash' \
    '            && current.process_generation == *process_generation => Ok(()),' \
    '        _ => fail("service upgrade requires a signed `ExactCurrentRevision` precondition: authoritative active revision changed after preflight"),' \
    '    }' \
    '}' \
    'fn admit_bundle(' \
    '    precondition: SoraServiceMutationPreconditionV1,' \
    ') {' \
    '    verify_bundle_provenance(' \
    '        &precondition,' \
    '    );' \
    '    let existing = state_transaction.world.soracloud_service_deployments.get(&service_name);' \
    '    enforce_service_mutation_precondition(action, &service_name, &precondition, existing.as_ref())?;' \
    '}' \
    'fn admit_app_infra() {}'
  write_file "$parent/iroha/crates/iroha_torii/src/soracloud.rs" \
    '#[norito(deny_unknown_fields)]' \
    'pub(crate) struct SignedBundleRequest {' \
    '    pub precondition: SoraServiceMutationPreconditionV1,' \
    '}' \
    '#[derive(Clone, Debug, JsonDeserialize, NoritoDeserialize, NoritoSerialize)]' \
    '#[norito(deny_unknown_fields)]' \
    'pub(crate) struct SignedAppInfraRequest {}' \
    'fn verify_bundle_signature() {' \
    '    encode_bundle_signature_payload(' \
    '        &request.precondition,' \
    '    );' \
    '    verify_signature_for_signer();' \
    '}' \
    'fn verify_app_infra_signature() {}' \
    'fn app_service_bundle_instruction() {' \
    '    verify_bundle_signature(&request)?;' \
    '    DeploySoracloudService {' \
    '        precondition: request.precondition,' \
    '    };' \
    '    UpgradeSoracloudService {' \
    '        precondition: request.precondition,' \
    '    };' \
    '}' \
    'fn encode_bundle_signature_payload() {}' \
    'pub(crate) async fn handle_deploy() {' \
    '    verify_bundle_signature(&request);' \
    '    DeploySoracloudService {' \
    '        precondition: request.precondition,' \
    '    };' \
    '}' \
    'pub(crate) async fn handle_upgrade() {' \
    '    verify_bundle_signature(&request);' \
    '    UpgradeSoracloudService {' \
    '        precondition: request.precondition,' \
    '    };' \
    '}' \
    'pub(crate) async fn handle_rollback() {}'
  for source_fixture in \
    crates/iroha_cli/src/soracloud.rs \
    crates/iroha_core/src/block.rs \
    crates/iroha_core/src/state.rs \
    crates/iroha_core/src/soracloud_runtime.rs \
    crates/iroha_core/src/smartcontracts/isi/soracloud.rs \
    crates/iroha_core/src/smartcontracts/isi/soracloud_tests.rs \
    crates/iroha_data_model/src/isi/soracloud.rs \
    crates/iroha_data_model/src/soracloud/deployment.rs \
    crates/iroha_data_model/src/soracloud/host_protocol.rs \
    crates/iroha_data_model/src/soracloud/hosting.rs \
    crates/iroha_data_model/src/soracloud/tests/manifest_validation.rs \
    crates/irohad/src/soracloud_runtime.rs \
    crates/irohad/src/soracloud_runtime/tests/runtime_tail.rs \
    crates/iroha_torii/src/lib.rs \
    crates/iroha_torii/src/soracloud.rs \
    crates/iroha_torii/src/tests/lib_runtime_handlers/part_6.rs \
    crates/iroha_torii/src/tests/lib_runtime_handlers/part_7.rs \
    crates/iroha_torii/src/tests/lib_runtime_handlers/part_8.rs \
    crates/iroha_torii_shared/src/lib.rs; do
    copy_iroha_source_fixture "$source_fixture"
  done
  write_file "$parent/iroha/configs/soranexus/taira/config.toml" \
    'chain = "fc56984b-2be7-431d-840e-21514d1883f0"' \
    'accepted_assets = ["6TEAJqbb8oEPmLncoNiMRbLEK6tw"]' \
    'fee_asset_id = "xor#universal"'
  write_file "$parent/iroha/configs/soranexus/taira/genesis.json" \
    '{"chain":"fc56984b-2be7-431d-840e-21514d1883f0","transactions":[{"instructions":[{"Register":{"AssetDefinition":{"id":"6TEAJqbb8oEPmLncoNiMRbLEK6tw","name":"xor","spec":{"scale":9}}}},{"SetAssetDefinitionAlias":{"alias":"xor#universal","asset_definition_id":"6TEAJqbb8oEPmLncoNiMRbLEK6tw"}}]}]}'
  write_file "$parent/iroha/configs/soranexus/taira/dns_records.json" \
    '{"records":[{"name":"taira-validator-1.sora.org","type":"A","value":"192.0.2.1"},{"name":"taira-validator-2.sora.org","type":"A","value":"192.0.2.2"},{"name":"taira-validator-3.sora.org","type":"A","value":"192.0.2.3"},{"name":"taira-validator-4.sora.org","type":"A","value":"192.0.2.4"}]}'
  write_file "$parent/iroha/skills/sora-taira-testnet/SKILL.md" \
    '# Taira' \
    'Chain `fc56984b-2be7-431d-840e-21514d1883f0` uses native XOR `6TEAJqbb8oEPmLncoNiMRbLEK6tw`.' \
    'Submit with `iroha.transactions.submit_and_wait` and {"body_base64":"..."}.'

  local nevo_fixture_dir="$parent/iroha/crates/iroha_kagami/tests/fixtures/taira_nevo_v2"
  write_file "$nevo_fixture_dir/public-inputs.json" '{"schema":"fixture"}'
  write_file "$nevo_fixture_dir/unsigned-genesis.json" '{"fixture":"unsigned"}'
  local nevo_config_sha256 nevo_genesis_sha256 nevo_public_inputs_sha256 nevo_unsigned_sha256
  nevo_config_sha256="$(shasum -a 256 "$parent/iroha/configs/soranexus/taira/config.toml" | awk '{print $1}')"
  nevo_genesis_sha256="$(shasum -a 256 "$parent/iroha/configs/soranexus/taira/genesis.json" | awk '{print $1}')"
  nevo_public_inputs_sha256="$(shasum -a 256 "$nevo_fixture_dir/public-inputs.json" | awk '{print $1}')"
  nevo_unsigned_sha256="$(shasum -a 256 "$nevo_fixture_dir/unsigned-genesis.json" | awk '{print $1}')"
  write_file "$nevo_fixture_dir/review.json" \
    "{\"chain\":\"fc56984b-2be7-431d-840e-21514d1883f0\",\"base_config_sha256\":\"$nevo_config_sha256\",\"base_genesis_sha256\":\"$nevo_genesis_sha256\",\"public_inputs_sha256\":\"$nevo_public_inputs_sha256\",\"unsigned_genesis_sha256\":\"$nevo_unsigned_sha256\"}"
}

write_wallet_ready_sources() {
  write_file "$workspace/fearless-wallet-web/src/consts/universalWallet.ts" \
    "const UNIVERSAL_WALLET_IROHA_NETWORKS = {" \
    "  taira: { chainId: 'fc56984b-2be7-431d-840e-21514d1883f0', toriiBaseUrl: 'https://taira.sora.org', nativeAsset: { id: '6TEAJqbb8oEPmLncoNiMRbLEK6tw', symbol: 'XOR', decimals: 9 } }," \
    "  nexus: { toriiBaseUrl: '$nexus_url', mcpPath: '/v1/mcp' }," \
    "} as const;" \
    "const UNIVERSAL_WALLET_NEXUS_REGISTRY_ENTRY = {" \
    "  endpoints: [{ id: 'sora-nexus-mainnet-torii-mcp', kind: 'torii-mcp', url: '${nexus_url}/v1/mcp' }]," \
    "};"

  write_file "$workspace/fearless-wallet-web/src/extension/background/extension-base/src/services/iroha-torii-service/index.ts" \
    "const PARTIAL = 'iroha_torii_partial_response';" \
    "const SUBMIT = 'iroha.transactions.submit_and_wait';" \
    'const FIELD = "body_base64";' \
    'if (present.length !== Object.keys(headerNames).length) fail();' \
    'if (status < 200 || status > 299) fail();' \
    'requireJsonResponseMediaType(response, body);' \
    'const hash = payload?.entrypoint_hash;' \
    'const finalHash = finalStatus.body.hash;' \
    'if (Object.hasOwn(headers, normalizedName)) fail();' \
    "if (mediaType !== 'application/json') fail();" \
    "fetch(url, { redirect: 'error' });" \
    'if (url.search || url.hash) fail();' \
    'if (summary.notFound > summary.failed - summary.denied - summary.unavailable) fail();' \
    "if (rpcResponse.jsonrpc !== '2.0' || rpcResponse.id !== requestId) fail();" \
    "if (Object.hasOwn(rpcResponse, 'result') === Object.hasOwn(rpcResponse, 'error')) fail();" \
    "if (typeof hash !== 'string' || !/^[0-9a-f]{63}[13579bdf]$/u.test(hash)) fail();" \
    'return hash;'

  write_file "$workspace/fearless-wallet-web/src/extension/background/extension-base/src/api/iroha/transfer.ts" \
    "throw new Error('invalid_iroha_chain_id');" \
    'if (network.chainId !== profile.chainId) return false;' \
    "throw new Error('noncanonical_iroha_chain_id');" \
    "throw new Error('unsupported_iroha_network');" \
    "if (typeof value !== 'string' || !/^[0-9a-f]{63}[13579bdf]$/u.test(value)) fail();" \
    'return value;'

  write_file "$workspace/fearless-wallet-web/src/util/iroha.ts" \
    "if (chainId === UNIVERSAL_WALLET_IROHA_NETWORKS.taira.chainId) return 'taira';" \
    "if (chainId === UNIVERSAL_WALLET_IROHA_NETWORKS.nexus.chainId) return 'nexus';" \
    "throw new Error('unsupported_iroha_chain_id');"

  write_file "$workspace/fearless-wallet-web/src/util/BaseApi.ts" \
    '({ chainId, name }) => chainId === network || isSameString(name, network)' \
    'resolveCanonicalIrohaAddressNetwork(networkJson.chainId)'

  write_file "$workspace/fearless-wallet-web/src/extension/background/extension-base/src/background/handlers/State.ts" \
    'resolveCanonicalIrohaAddressNetwork(network.chainId)'

  write_file "$workspace/fearless-wallet-web/src/extension/background/extension-base/src/services/balance-service/IrohaBalanceService.ts" \
    'if (network.chainId === UNIVERSAL_WALLET_IROHA_NETWORKS.taira.chainId) return "taira";' \
    "const options = { countMode: 'bounded' };" \
    'const accountOptions = { limit: IROHA_BALANCE_PAGE_SIZE, offset: 0 };' \
    'const definitionOptions = { limit: IROHA_DEFINITION_PAGE_SIZE, offset: 0 };' \
    "if (response.body?.has_more !== false || response.body?.count_mode !== 'bounded') fail();" \
    'if (item.account_id !== requestedAccountId) fail();' \
    'if (item.accountId !== undefined) fail();' \
    'if (item.asset_id !== undefined) fail();' \
    'if (item.value !== undefined) fail();' \
    'if (!isCanonicalIrohaAssetDefinitionId(this.getAssetId(item), network)) fail();' \
    'const valid = network === "taira" ? /^[1-9A-HJ-NP-Za-km-z]{20,64}$/u.test(value) : false;' \
    'if (seenScopes.has(scopeKey)) fail();' \
    'const MAX_IROHA_NUMERIC = (1n << 511n) - 1n;' \
    'sumCanonicalIrohaQuantities(values);'
  write_file "$workspace/fearless-wallet-web/src/history/fetchingHistory.ts" \
    'const precision = await validateIrohaHistoryAssetDefinition(client);' \
    "if (!hasExactRecordKeys(body, ['pagination', 'items'])) fail();" \
    "if (!hasExactRecordKeys(body.pagination, ['page', 'per_page', 'total_pages', 'total_items'])) fail();" \
    'if (page !== requestedPage) fail();' \
    'if (parsed.totalItems !== expectedTotalItems) fail();' \
    "throw new Error('noncanonical_iroha_history_field');" \
    "if (transactionStatus !== 'Committed') fail();" \
    "const box = item['box'];" \
    "if (!hasExactRecordKeys(box, ['encoded', 'framed_sha256', 'json'])) fail();" \
    "if (mode.mode !== 'Atomic') fail();" \
    'if (mode.value !== null) fail();' \
    'new TextEncoder().encode(legId).length;' \
    'const MAX_IROHA_QUANTITY = (1n << 511n) - 1n;' \
    "throw new Error('duplicate_iroha_history_id');" \
    'scaledIrohaIntegerToBaseUnits(mantissa, scale, precision);' \
    'const transfer = { fee: null };' \
    'throw new Error("unsupported_iroha_chain_id");' \
    'const isOutgoing = isSameIrohaLiteral(sourceAccount, address);' \
    "return typeof left === 'string' && left === right;"

  write_file "$workspace/fearless-Android/common/src/main/java/jp/co/soramitsu/common/model/UniversalWalletRegistry.kt" \
    "object UniversalWalletRegistry {" \
    '  const val TAIRA_CHAIN_ID = "fc56984b-2be7-431d-840e-21514d1883f0"' \
    '  const val TAIRA_XOR_ASSET_DEFINITION_ID = "6TEAJqbb8oEPmLncoNiMRbLEK6tw"' \
    "    val taira = IrohaNetwork(" \
    '      chainId = TAIRA_CHAIN_ID,' \
    '      toriiBaseUrl = "https://taira.sora.org",' \
    '      nativeAsset = IrohaNativeAsset(' \
    '        id = TAIRA_XOR_ASSET_DEFINITION_ID,' \
    '        symbol = "XOR",' \
    '        decimals = 9' \
    '      )' \
    '    )' \
    "    val nexus = IrohaNetwork(" \
    "    id = \"sora-nexus-mainnet\"," \
    "    chainId = \"sora:nexus:global\"," \
    "    toriiBaseUrl = \"$nexus_url\"," \
    "    mcpPath = \"/v1/mcp\"" \
    "  )" \
    "}"

  write_file "$workspace/fearless-Android/common/src/main/java/jp/co/soramitsu/common/data/network/iroha/IrohaToriiClient.kt" \
    'const val SUBMIT_AND_WAIT_TOOL = "iroha.transactions.submit_and_wait"' \
    'const val BODY_FIELD = "body_base64"' \
    'const val FANOUT_DENIED_HEADER = "x-iroha-fanout-routes-denied"' \
    'const val FANOUT_NOT_FOUND_HEADER = "x-iroha-fanout-routes-not-found"' \
    'val CANONICAL_TRANSACTION_HASH = Regex("^[0-9a-f]{63}[13579bdf]$")' \
    'if (listOf(hash, transactionHash, receiptHash, finalHash).any { it != expectedHash }) fail()' \
    'if (terminalKind != IrohaPipelineTransactionStatusKind.Applied) fail()' \
    'validateFanoutHeaders { response.headers().values(it).singleOrNull() }' \
    'requireJsonContentType(response)' \
    'error("duplicate case-insensitive headers")' \
    'val contentType = (route["content_type"] as? String)' \
    'val hasExactlyOnePayload = (response.result == null) != (response.error == null)' \
    'if (response.jsonrpc != "2.0" || response.id != request.id || !hasExactlyOnePayload) fail()' \
    'return value?.takeIf(CANONICAL_TRANSACTION_HASH::matches)' \
    'return completeRoutedBody(response)' \
    'return completeMcpBody(response)'

  write_file "$workspace/fearless-Android/common/src/main/java/jp/co/soramitsu/common/data/network/iroha/IrohaToriiModels.kt" \
    'data class AccountAssets(val hasMore: Boolean?)' \
    'data class Definitions(val hasMore: Boolean?)' \
    'val jsonrpc: String? = null' \
    'if (notFound > failed - denied - unavailable) return false'

  write_file "$workspace/fearless-Android/common/src/main/java/jp/co/soramitsu/common/data/network/iroha/IrohaToriiRoutes.kt" \
    'if (parsed.protocol != "https" && !(parsed.protocol == "http" && isLocal)) fail()' \
    'if (parsed.userInfo != null || parsed.query != null || parsed.ref != null) fail()' \
    'if (!HASH_256.matches(hash)) fail()' \
    'return hash'

  write_file "$workspace/fearless-Android/common/src/main/java/jp/co/soramitsu/common/di/modules/NetworkModule.kt" \
    'fun irohaNoRedirectHttpClient(client: OkHttpClient) = client.newBuilder()' \
    '  .followRedirects(false)' \
    '  .followSslRedirects(false)' \
    'val api = irohaNoRedirectHttpClient(okHttpClient)' \
    'irohaNoRedirectHttpClient(okHttpClient)'

  write_file "$workspace/fearless-Android/feature-wallet-impl/src/main/java/jp/co/soramitsu/wallet/impl/data/historySource/IrohaHistorySource.kt" \
    'if (definitions.hasMore != false) fail()' \
    'if (toolResult["isError"] != false) fail()' \
    'val route = toolResult["structuredContent"]' \
    'error("Torii omitted the fixed scale")' \
    'error("Torii MCP history returned a non-canonical field alias")' \
    'if (transactionStatus != "Committed") fail()' \
    'if (!body.hasExactKeys(HISTORY_PAGE_KEYS)) fail()' \
    'if (!pagination.hasExactKeys(PAGINATION_KEYS)) fail()' \
    'if (page != requestedPage.toLong()) fail()' \
    'if (totalPages != calculatedTotalPages) fail()' \
    'val box = this["box"] as? Map<*, *>' \
    'if (mode.canonicalString("mode") != "Atomic") fail()' \
    'if (mode["value"] != null) fail()' \
    'it.toByteArray(Charsets.UTF_8).size <= MAX_BATCH_LEG_ID_LENGTH' \
    'BigInteger.ONE.shiftLeft(511).subtract(BigInteger.ONE)' \
    'val fee = null' \
    'val outgoing = sourceAccount == accountAddress'

  write_file "$workspace/fearless-Android/feature-wallet-impl/src/main/java/jp/co/soramitsu/wallet/impl/data/network/blockchain/balance/IrohaBalanceLoader.kt" \
    'val definitions = torii.assetDefinitions(limit = IrohaToriiRoutes.MAX_LIMIT, offset = 0, countMode = IrohaToriiRoutes.CountMode.Bounded)' \
    'if (definitions.hasMore != false || definitions.countMode != IrohaToriiRoutes.CountMode.Bounded.apiValue) fail()' \
    'val response = torii.accountAssets(limit = IrohaToriiRoutes.MAX_LIMIT, offset = 0, countMode = IrohaToriiRoutes.CountMode.Bounded)' \
    'if (response.hasMore != false || response.countMode != IrohaToriiRoutes.CountMode.Bounded.apiValue) fail()' \
    'if (item.accountId != address) fail()' \
    'if (item.assetId != null) fail()' \
    'IrohaToriiRoutes.normalizeAssetDefinitionId(presentItemAsset)' \
    'IrohaToriiRoutes.normalizeAccountAssetScope(itemScope)' \
    'seenAccountAssetScopes.add(canonicalItemAsset to canonicalScope)' \
    'val maxBalanceInPlanks = MAX_QUANTITY.multiply(BigInteger.TEN.pow(precision))' \
    'if (value > maxBalanceInPlanks.subtract(total)) fail()'

  write_file "$workspace/fearless-Android/runtime/src/main/java/jp/co/soramitsu/runtime/ext/UniversalWalletIrohaExt.kt" \
    'return id == UniversalWalletRegistry.taira.chainId ||' \
    'id == UniversalWalletRegistry.nexus.chainId' \
    'fun Chain.hasNonCanonicalUniversalWalletIrohaIdentity() = false' \
    'UniversalWalletRegistry.taira.chainId -> UniversalWalletRegistry.taira' \
    'UniversalWalletRegistry.nexus.chainId -> UniversalWalletRegistry.nexus'

  write_file "$workspace/fearless-Android/feature-wallet-impl/src/main/java/jp/co/soramitsu/wallet/impl/data/network/blockchain/balance/BalanceLoaderProvider.kt" \
    'chain.hasNonCanonicalUniversalWalletIrohaIdentity() -> throw IllegalArgumentException('

  write_file "$workspace/fearless-Android/feature-wallet-impl/src/main/java/jp/co/soramitsu/wallet/impl/data/repository/tranfser/TransferService.kt" \
    '} else if (chain.hasNonCanonicalUniversalWalletIrohaIdentity()) {' \
    'return this?.takeIf(IROHA_TRANSACTION_HASH_PATTERN::matches)'

  write_file "$workspace/fearless-Android/feature-account-api/src/main/java/jp/co/soramitsu/account/api/domain/model/MetaAccount.kt" \
    'UniversalWalletRegistry.taira.chainId' \
    'UniversalWalletRegistry.nexus.chainId'

  write_file "$workspace/fearless-Android/feature-account-api/src/main/java/jp/co/soramitsu/account/api/domain/model/AndroidUniversalWalletMigrationSnapshotBuilder.kt" \
    'UniversalWalletRegistry.taira.chainId' \
    'UniversalWalletRegistry.nexus.chainId'

  write_file "$workspace/fearless-iOS/fearless/Common/Model/UniversalWalletRegistry.swift" \
    "enum UniversalWalletRegistry {" \
    '  static let tairaChainId = "fc56984b-2be7-431d-840e-21514d1883f0"' \
    '  static let tairaXorAssetDefinitionId = "6TEAJqbb8oEPmLncoNiMRbLEK6tw"' \
    '    static let taira = IrohaNetwork(' \
    '      chainId: tairaChainId,' \
    '      toriiBaseURL: URL(string: "https://taira.sora.org")!,' \
    '      nativeAsset: IrohaNativeAsset(' \
    '        id: tairaXorAssetDefinitionId,' \
    '        symbol: "XOR",' \
    '        decimals: 9' \
    '      )' \
    '    )' \
    "    static let nexus = IrohaNetwork(" \
    "    id: \"sora-nexus-mainnet\"," \
    "    chainId: \"sora:nexus:global\"," \
    "    toriiBaseURL: URL(string: \"$nexus_url\")!," \
    "    mcpPath: \"/v1/mcp\"" \
    "  )" \
    "}"

  write_file "$workspace/fearless-iOS/fearless/Common/Model/IrohaToriiClient.swift" \
    'let submitTool = "iroha.transactions.submit_and_wait"' \
    'let bodyField = "body_base64"' \
    'let deniedHeader = "x-iroha-fanout-routes-denied"' \
    'let notFoundHeader = "x-iroha-fanout-routes-not-found"' \
    'let canonicalHashPattern = "^[0-9a-f]{63}[13579bdf]$"' \
    'canonicalTransactionHash(outcome.finalStatus.body.hash) == canonicalExpectedHash' \
    'outcome.terminalKind == .applied' \
    'let headers = try normalizedResponseHeaders(response.headers)' \
    'try requireJSONContentType(headers)' \
    'isJSONMediaType(outcome.submit.contentType)' \
    'let hasExactlyOnePayload = (response.result == nil) != (response.error == nil)' \
    'response.jsonrpc == "2.0"' \
    'response.id == .string(request.id)' \
    'return value' \
    'completeRoutedData(try await transport.performResponse(request))' \
    'completeMCPData(try await transport.performResponse(request))' \
    'completionHandler(nil)' \
    'transport: IrohaToriiHTTPTransport = IrohaNoRedirectHTTPTransport()'

  write_file "$workspace/fearless-iOS/fearless/Common/Model/IrohaToriiContract.swift" \
    'let headers: [String: String]' \
    'let contentType: String' \
    'let jsonrpc: String?' \
    'guard assetDefinitionId == assetDefinitionId.trimmingCharacters(in: .whitespacesAndNewlines) else { fail() }' \
    'guard matches(hash, "^[0-9a-f]{63}[13579bdf]$") else' \
    'guard notFound <= failed - denied - unavailable else { return false }' \
    'guard (scheme == "https" || (scheme == "http" && isLocal)) else { fail() }' \
    'guard url.user == nil, url.password == nil, url.query == nil, url.fragment == nil else { fail() }'

  write_file "$workspace/fearless-iOS/fearless/ApplicationLayer/Services/Transfer/Tokens/TransferService.swift" \
    'guard value.range(of: "^[0-9a-f]{63}[13579bdf]$", options: .regularExpression) != nil else'

  write_file "$workspace/fearless-iOS/fearless/CoreLayer/OperationFactory/BlockExplorer/History/Main/IrohaHistoryOperationFactory.swift" \
    'let items = try response.instructionPage(' \
    'let route = toolResult["structuredContent"]' \
    'case missingScale(String)' \
    'let aliases = rejectingAliases: ["transactionStatus", "status"]' \
    'guard transactionStatus == "Committed" else { fail() }' \
    'guard body.hasExactKeys(historyPageKeys) else { fail() }' \
    'guard pagination.hasExactKeys(paginationKeys) else { fail() }' \
    'guard page == Int64(requestedPage) else { fail() }' \
    'guard totalPages == calculatedTotalPages else { fail() }' \
    'let box = self["box"]?.objectValue' \
    'guard mode["mode"] == .string("Atomic") else { fail() }' \
    'guard mode["value"] == .null else { fail() }' \
    'guard legId.utf8.count <= maxIrohaBatchLegIdLength else { fail() }' \
    'let maxIrohaQuantity = (BigUInt(1) << 511) - 1' \
    'throw IrohaHistoryReadError.invalidMcpResponse("duplicate_history_identity")' \
    'fees: []' \
    'let outgoing = sourceAccount == accountAddress' \
    'amount.toSubstrateAmount(precision: Int16(precision)) == transfer.amount'

  write_file "$workspace/fearless-iOS/fearless/ApplicationLayer/Services/Balance/RemoteSubscription/AccountInfoRemoteService.swift" \
    'let definitions = try await client.assetDefinitions(limit: IrohaToriiRoutes.maxLimit, offset: 0, countMode: .bounded)' \
    'guard definitions.countMode == IrohaToriiCountMode.bounded.rawValue else { fail() }' \
    'let response = try await client.accountAssets(limit: IrohaToriiRoutes.maxLimit, offset: 0, countMode: .bounded)' \
    'guard response.countMode == IrohaToriiCountMode.bounded.rawValue else { fail() }' \
    'guard item.accountID == address else { fail() }' \
    'guard item.assetID == nil else { fail() }' \
    'IrohaToriiRoutes.normalizeAssetDefinitionId(item.asset)' \
    'IrohaToriiRoutes.normalizeAccountAssetScope(scope)' \
    'seenAssetScopes.insert("\(canonicalAsset)\u{0}\(canonicalScope)").inserted' \
    'let maxBalanceInPlanks = maxIrohaNumeric * scaleFactor' \
    'guard value <= maxBalanceInPlanks - total else { fail() }'

  write_file "$workspace/fearless-iOS/fearless/Common/Model/UniversalWalletAccountAddressResolver.swift" \
    'if exactIrohaNetwork(for: requestedChainId) != nil {' \
    'return storedChainId == requestedChainId' \
    'case UniversalWalletRegistry.taira.chainId:' \
    'case UniversalWalletRegistry.nexus.chainId:' \
    'let trimmedChainId = chainId.trimmingCharacters(in: .whitespacesAndNewlines)' \
    'trimmedChainId.caseInsensitiveCompare(UniversalWalletRegistry.taira.id) == .orderedSame' \
    'trimmedChainId.caseInsensitiveCompare(UniversalWalletRegistry.nexus.id) == .orderedSame' \
    'trimmedChainId.caseInsensitiveCompare(UniversalWalletRegistry.taira.chainId) == .orderedSame' \
    'trimmedChainId.caseInsensitiveCompare(UniversalWalletRegistry.nexus.chainId) == .orderedSame' \
    'trimmedChainId.caseInsensitiveCompare("iroha3-taira") == .orderedSame'

  write_file "$workspace/fearless-iOS/fearless/Common/Storage/EntityToModel/MetaAccountMapper.swift" \
    'chainId == chainId.trimmingCharacters(in: .whitespacesAndNewlines)' \
    '!UniversalWalletChainAccountSupport.isNonCanonicalIrohaIdentity(chainId)'

  write_file "$workspace/fearless-iOS/fearlessTests/UniversalWalletAccountAddressResolverTests.swift" \
    'func testIrohaAddressResolutionRejectsAliasesCaseMutationsAndUnknownIdentifiers() {}' \
    'func testIrohaAddressResolutionRejectsWhitespaceWrappedKnownIdentities() {}'

  write_file "$workspace/fearless-iOS/fearlessTests/Common/Storage/MetaAccountMapperTests.swift" \
    'func testSingleNoncanonicalIrohaStoredRowIsQuarantined() {}' \
    'func testSingleWhitespaceWrappedIrohaStoredRowIsQuarantined() {}'

  write_file "$workspace/fearless-iOS/fearlessTests/IrohaToriiContractTests.swift" \
    'func testRejectsPaddedAssetDefinitionIdentifiersWithoutCanonicalizing() {}'

  write_file "$workspace/fearless-iOS/fearless/Common/Model/UniversalWalletMigrationContract.swift" \
    'chainAccount(matchingExactly: Self.tairaChainIds)' \
    'chainAccount(matchingExactly: Self.nexusChainIds)'

  write_file "$workspace/fearless-iOS/fearless/Modules/Send/SendDependencyContainer.swift" \
    'if UniversalWalletChainAccountSupport.isNonCanonicalIrohaProfile(chainAsset.chain) {'
}

write_iroha_release_config() {
  local chain_id="${1-fixture:nexus:chain}"
  local genesis_hash="${2-0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef}"
  local build_commit="${3-abcdef1234567890abcdef1234567890abcdef12}"
  local taira_build_commit="${4-}"
  local lines=(
    "IROHA_MOBILE_SDK_RELEASE_REPO=hyperledger-iroha/iroha"
    "IROHA_MOBILE_SDK_RELEASE_TAG=v1.2.3"
    "IROHA_JS_SDK_RELEASE_REPO=hyperledger-iroha/iroha"
    "IROHA_JS_SDK_RELEASE_TAG=v1.2.3"
    "IROHA_JS_SDK_RELEASE_ASSET=iroha-js-release.tgz"
    "IROHA_JS_SDK_RELEASE_SHA256=0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
    "NEXUS_EXPECTED_BUILD_COMMIT=$build_commit"
    "NEXUS_EXPECTED_CHAIN_ID=$chain_id"
    "NEXUS_EXPECTED_GENESIS_HASH=$genesis_hash"
  )
  if [[ -n "$taira_build_commit" ]]; then
    lines+=("TAIRA_EXPECTED_BUILD_COMMIT=$taira_build_commit")
  fi
  write_file "$workspace/config/iroha-release-readiness.env" \
    "${lines[@]}"
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
  write_fake_cargo
  write_wallet_ready_sources
  mkdir -p "$workspace/scripts"
  cp "$SCRIPT_DIR/audit-taira-release-readiness.sh" "$workspace/scripts/audit-taira-release-readiness.sh"
  cp "$SCRIPT_DIR/audit-taira-release-readiness.mjs" "$workspace/scripts/audit-taira-release-readiness.mjs"
  cp "$SCRIPT_DIR/test-taira-release-readiness-audit.mjs" "$workspace/scripts/test-taira-release-readiness-audit.mjs"
  chmod +x \
    "$workspace/scripts/audit-taira-release-readiness.sh" \
    "$workspace/scripts/audit-taira-release-readiness.mjs" \
    "$workspace/scripts/test-taira-release-readiness-audit.mjs"
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

if [[ "${IROHA_READINESS_TEST_DEFINE_ONLY:-0}" == "1" ]]; then
  return 0 2>/dev/null || exit 0
fi

setup_fixture
expect_success "complete fixture with default Minamoto URL" good

setup_fixture
NEXUS_RECEIPT_BASE_URL=https://forged.invalid \
NEXUS_TORII_BASE_URL=https://forged.invalid \
NEXUS_MCP_URL=https://forged.invalid/v1/mcp \
NEXUS_RECEIPT_FIXTURE_DIR=/tmp/forged-nexus-receipts \
NODE_USE_ENV_PROXY=1 \
NODE_TLS_REJECT_UNAUTHORIZED=0 \
SSL_CERT_FILE=/tmp/forged-ca.pem \
HTTPS_PROXY=http://127.0.0.1:1 \
  expect_success "nested Nexus evidence audit ignores ambient transport authority" good

setup_fixture
expect_success "complete fixture uses configured mobile SDK release tag" good "" "1.2.3" "$nexus_url"

setup_fixture
write_file "$parent/iroha/configs/soranexus/taira/config.toml" \
  'chain = "fc56984b-2be7-431d-840e-21514d1883f0"' \
  'accepted_assets = ["6TEAJqbb8oEPmLncoNiMRbLEK6tw"]' \
  'fee_asset_id = "xor#universal"' \
  '# unreviewed source-template drift'
expect_failure \
  "Taira NEVO review rejects source-template drift" \
  "base_config_sha256" good

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
HOME="$tmp_dir/curl-home" \
CURL_CA_BUNDLE=/tmp/forged-ca.pem \
SSL_CERT_FILE=/tmp/forged-ca.pem \
SSL_CERT_DIR=/tmp/forged-ca-dir \
OPENSSL_CONF=/tmp/forged-openssl.cnf \
HTTPS_PROXY=http://127.0.0.1:1 \
ALL_PROXY=socks5://127.0.0.1:1 \
IROHA_NEXUS_LIVE_HEALTH=true \
  expect_success "curl transport boundary neutralizes ambient curlrc proxy and CA authority" good
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
IROHA_NEXUS_REQUIRE_PRODUCTION_EVIDENCE=1 expect_failure \
  "strict Nexus production evidence rejects a divergent live-health chain identity" \
  "Strict SORA Nexus production evidence requires committed NEXUS_EXPECTED_CHAIN_ID to equal sora:nexus:global; resolved fixture:nexus:chain" good

setup_fixture
write_iroha_release_config "sora:nexus:global"
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
IROHA_TAIRA_LIVE_HEALTH=yes expect_failure \
  "Taira live-health flag rejects non-boolean values" \
  "IROHA_TAIRA_LIVE_HEALTH must be exactly one of" good

setup_fixture
IROHA_TAIRA_LIVE_HEALTH=1 expect_failure \
  "Taira live health requires a committed deployed build pin" \
  "TAIRA_EXPECTED_BUILD_COMMIT must be pinned in the committed Iroha release defaults" good

setup_fixture
write_iroha_release_config \
  "fixture:nexus:chain" \
  "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef" \
  "abcdef1234567890abcdef1234567890abcdef12" \
  "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
expect_failure \
  "committed Taira build pin rejects uppercase values without live mode" \
  "committed TAIRA_EXPECTED_BUILD_COMMIT must be exactly 40 or 64 lowercase hexadecimal" good

setup_fixture
write_iroha_release_config \
  "fixture:nexus:chain" \
  "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef" \
  "abcdef1234567890abcdef1234567890abcdef12" \
  "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbc"
TAIRA_EXPECTED_BUILD_COMMIT=cccccccccccccccccccccccccccccccccccccccd expect_failure \
  "process environment cannot override the committed Taira build pin" \
  "process TAIRA_EXPECTED_BUILD_COMMIT must not override the committed Taira build pin" good

setup_fixture
mutated_audit="$(write_mutated_audit nexus-no-disable 's/run_isolated_nexus_curl --disable -sS/run_isolated_nexus_curl -sS/')"
mkdir -p "$tmp_dir/curl-home"
write_file "$tmp_dir/curl-home/.curlrc" "location" "insecure"
HOME="$tmp_dir/curl-home" AUDIT_SCRIPT="$mutated_audit" IROHA_NEXUS_LIVE_HEALTH=1 NEXUS_HEALTH_ATTEMPTS=1 \
  expect_failure "ambient curlrc cannot alter the Nexus request" "--disable/-q must be the first argument" good

setup_fixture
mutated_audit="$(write_mutated_audit nexus-ambient-ca 's/-u CURL_CA_BUNDLE/-u CURL_CA_BUNDLE_REMOVED/')"
CURL_CA_BUNDLE=/tmp/forged-ca.pem AUDIT_SCRIPT="$mutated_audit" IROHA_NEXUS_LIVE_HEALTH=1 NEXUS_HEALTH_ATTEMPTS=1 \
  expect_failure "ambient CURL_CA_BUNDLE cannot alter the Nexus request" "curl version could not be verified for the SORA Nexus live health response-size contract" good

setup_fixture
mutated_audit="$(write_mutated_audit nexus-follow-redirects 's/run_isolated_nexus_curl --disable -sS/run_isolated_nexus_curl --disable --location -sS/')"
AUDIT_SCRIPT="$mutated_audit" IROHA_NEXUS_LIVE_HEALTH=1 NEXUS_HEALTH_ATTEMPTS=1 \
  expect_failure "Nexus curl contract rejects redirect following" "redirect following is forbidden" good

setup_fixture
mutated_audit="$(write_mutated_audit nexus-insecure-tls 's/run_isolated_nexus_curl --disable -sS/run_isolated_nexus_curl --disable --insecure -sS/')"
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

setup_fixture
sed -i.bak 's/requireJsonResponseMediaType(response, body)/acceptAnySuccessfulBody(response, body)/' \
  "$workspace/fearless-wallet-web/src/extension/background/extension-base/src/services/iroha-torii-service/index.ts"
rm -f "$workspace/fearless-wallet-web/src/extension/background/extension-base/src/services/iroha-torii-service/index.ts.bak"
expect_failure "web outer MCP JSON media-type guard removed" "web outer MCP JSON media-type requirement" good

setup_fixture
sed -i.bak 's/payload?.entrypoint_hash/payload?.tx_hash_hex/' \
  "$workspace/fearless-wallet-web/src/extension/background/extension-base/src/services/iroha-torii-service/index.ts"
rm -f "$workspace/fearless-wallet-web/src/extension/background/extension-base/src/services/iroha-torii-service/index.ts.bak"
expect_failure "web retired receipt hash alias restored" "web canonical submit receipt hash" good

setup_fixture
sed -i.bak 's/requireJsonContentType(response)/acceptAnySuccessfulBody(response)/' \
  "$workspace/fearless-Android/common/src/main/java/jp/co/soramitsu/common/data/network/iroha/IrohaToriiClient.kt"
rm -f "$workspace/fearless-Android/common/src/main/java/jp/co/soramitsu/common/data/network/iroha/IrohaToriiClient.kt.bak"
expect_failure "Android outer JSON media-type guard removed" "Android outer JSON media-type requirement" good

setup_fixture
sed -i.bak 's/duplicate case-insensitive headers/ignored case-insensitive headers/' \
  "$workspace/fearless-Android/common/src/main/java/jp/co/soramitsu/common/data/network/iroha/IrohaToriiClient.kt"
rm -f "$workspace/fearless-Android/common/src/main/java/jp/co/soramitsu/common/data/network/iroha/IrohaToriiClient.kt.bak"
expect_failure "Android nested header collision guard removed" "Android nested case-colliding header refusal" good

setup_fixture
sed -i.bak 's/try requireJSONContentType(headers)/try acceptAnySuccessfulBody(headers)/' \
  "$workspace/fearless-iOS/fearless/Common/Model/IrohaToriiClient.swift"
rm -f "$workspace/fearless-iOS/fearless/Common/Model/IrohaToriiClient.swift.bak"
expect_failure "iOS outer JSON media-type guard removed" "iOS outer JSON media-type requirement" good

setup_fixture
sed -i.bak 's/let contentType: String/let contentType: String?/' \
  "$workspace/fearless-iOS/fearless/Common/Model/IrohaToriiContract.swift"
rm -f "$workspace/fearless-iOS/fearless/Common/Model/IrohaToriiContract.swift.bak"
expect_failure "iOS nested content type made optional" "iOS nested MCP content type must not be optional" good

setup_fixture
sed -i.bak 's/let headers: \[String: String\]/let headers: [String: String]?/' \
  "$workspace/fearless-iOS/fearless/Common/Model/IrohaToriiContract.swift"
rm -f "$workspace/fearless-iOS/fearless/Common/Model/IrohaToriiContract.swift.bak"
expect_failure "iOS nested fanout headers made optional" "iOS nested MCP fanout headers must not be optional" good

setup_fixture
sed -i.bak 's/network.chainId !== profile.chainId/network.chainId.toLowerCase() !== profile.chainId.toLowerCase()/' \
  "$workspace/fearless-wallet-web/src/extension/background/extension-base/src/api/iroha/transfer.ts"
rm -f "$workspace/fearless-wallet-web/src/extension/background/extension-base/src/api/iroha/transfer.ts.bak"
expect_failure "web case-insensitive Iroha routing restored" "web exact Iroha transfer identity" good

setup_fixture
sed -i.bak 's/return id == UniversalWalletRegistry.taira.chainId ||/return id == UniversalWalletRegistry.taira.id ||/' \
  "$workspace/fearless-Android/runtime/src/main/java/jp/co/soramitsu/runtime/ext/UniversalWalletIrohaExt.kt"
rm -f "$workspace/fearless-Android/runtime/src/main/java/jp/co/soramitsu/runtime/ext/UniversalWalletIrohaExt.kt.bak"
expect_failure "Android Iroha registry-alias routing restored" "Android exact Iroha identity" good

setup_fixture
sed -i.bak 's/seenAccountAssetScopes.add(canonicalItemAsset to canonicalScope)/true/' \
  "$workspace/fearless-Android/feature-wallet-impl/src/main/java/jp/co/soramitsu/wallet/impl/data/network/blockchain/balance/IrohaBalanceLoader.kt"
rm -f "$workspace/fearless-Android/feature-wallet-impl/src/main/java/jp/co/soramitsu/wallet/impl/data/network/blockchain/balance/IrohaBalanceLoader.kt.bak"
expect_failure "Android duplicate account-asset scope accepted" "Android strict Taira balance contract" good

setup_fixture
sed -i.bak 's/return storedChainId == requestedChainId/return storedChainId.lowercased() == requestedChainId.lowercased()/' \
  "$workspace/fearless-iOS/fearless/Common/Model/UniversalWalletAccountAddressResolver.swift"
rm -f "$workspace/fearless-iOS/fearless/Common/Model/UniversalWalletAccountAddressResolver.swift.bak"
expect_failure "iOS case-insensitive Iroha stored-account matching restored" "iOS exact Iroha account identity" good

setup_fixture
sed -i.bak 's/seenAssetScopes.insert("\\(canonicalAsset)\\u{0}\\(canonicalScope)").inserted/true/' \
  "$workspace/fearless-iOS/fearless/ApplicationLayer/Services/Balance/RemoteSubscription/AccountInfoRemoteService.swift"
rm -f "$workspace/fearless-iOS/fearless/ApplicationLayer/Services/Balance/RemoteSubscription/AccountInfoRemoteService.swift.bak"
expect_failure "iOS duplicate account-asset scope accepted" "iOS strict Taira balance contract" good

setup_fixture
sed -i.bak 's/assetDefinitionId == assetDefinitionId.trimmingCharacters(in: .whitespacesAndNewlines)/true/' \
  "$workspace/fearless-iOS/fearless/Common/Model/IrohaToriiContract.swift"
rm -f "$workspace/fearless-iOS/fearless/Common/Model/IrohaToriiContract.swift.bak"
expect_failure "iOS asset-definition padding normalized" "iOS exact asset-definition identifier routing" good

setup_fixture
sed -i.bak 's/testRejectsPaddedAssetDefinitionIdentifiersWithoutCanonicalizing/testAcceptsPaddedAssetDefinitionIdentifiers/' \
  "$workspace/fearless-iOS/fearlessTests/IrohaToriiContractTests.swift"
rm -f "$workspace/fearless-iOS/fearlessTests/IrohaToriiContractTests.swift.bak"
expect_failure "iOS padded asset-definition regression test removed" "iOS padded asset-definition identifier adversarial test" good

setup_fixture
sed -i.bak 's/!UniversalWalletChainAccountSupport.isNonCanonicalIrohaIdentity(chainId)/true/' \
  "$workspace/fearless-iOS/fearless/Common/Storage/EntityToModel/MetaAccountMapper.swift"
rm -f "$workspace/fearless-iOS/fearless/Common/Storage/EntityToModel/MetaAccountMapper.swift.bak"
expect_failure "iOS stored Iroha quarantine bypassed" "iOS stored Iroha identity quarantine invariant" good

setup_fixture
sed -i.bak 's/testSingleNoncanonicalIrohaStoredRowIsQuarantined/testSingleIrohaStoredRowIsAccepted/' \
  "$workspace/fearless-iOS/fearlessTests/Common/Storage/MetaAccountMapperTests.swift"
rm -f "$workspace/fearless-iOS/fearlessTests/Common/Storage/MetaAccountMapperTests.swift.bak"
expect_failure "iOS stored Iroha quarantine test removed" "iOS stored Iroha identity quarantine test" good

setup_fixture
sed -i.bak 's/testIrohaAddressResolutionRejectsAliasesCaseMutationsAndUnknownIdentifiers/testIrohaAddressResolutionAcceptsAliases/' \
  "$workspace/fearless-iOS/fearlessTests/UniversalWalletAccountAddressResolverTests.swift"
rm -f "$workspace/fearless-iOS/fearlessTests/UniversalWalletAccountAddressResolverTests.swift.bak"
expect_failure "iOS noncanonical identity adversarial test removed" "iOS noncanonical Iroha identity adversarial test" good

setup_fixture
sed -i.bak 's/let trimmedChainId = chainId.trimmingCharacters(in: .whitespacesAndNewlines)/let trimmedChainId = chainId/' \
  "$workspace/fearless-iOS/fearless/Common/Model/UniversalWalletAccountAddressResolver.swift"
rm -f "$workspace/fearless-iOS/fearless/Common/Model/UniversalWalletAccountAddressResolver.swift.bak"
expect_failure "iOS whitespace-wrapped Iroha identity accepted" "iOS noncanonical Iroha identity classifier" good

setup_fixture
sed -i.bak 's/trimmedChainId.caseInsensitiveCompare("iroha3-taira") == .orderedSame/false/' \
  "$workspace/fearless-iOS/fearless/Common/Model/UniversalWalletAccountAddressResolver.swift"
rm -f "$workspace/fearless-iOS/fearless/Common/Model/UniversalWalletAccountAddressResolver.swift.bak"
expect_failure "iOS retired Taira identity accepted" "iOS noncanonical Iroha identity classifier" good

setup_fixture
sed -i.bak 's/testIrohaAddressResolutionRejectsWhitespaceWrappedKnownIdentities/testIrohaAddressResolutionAcceptsWhitespaceWrappedKnownIdentities/' \
  "$workspace/fearless-iOS/fearlessTests/UniversalWalletAccountAddressResolverTests.swift"
rm -f "$workspace/fearless-iOS/fearlessTests/UniversalWalletAccountAddressResolverTests.swift.bak"
expect_failure "iOS whitespace-wrapped identity test removed" "iOS whitespace-wrapped Iroha identity adversarial test" good

setup_fixture
sed -i.bak 's/testSingleWhitespaceWrappedIrohaStoredRowIsQuarantined/testSingleWhitespaceWrappedIrohaStoredRowIsAccepted/' \
  "$workspace/fearless-iOS/fearlessTests/Common/Storage/MetaAccountMapperTests.swift"
rm -f "$workspace/fearless-iOS/fearlessTests/Common/Storage/MetaAccountMapperTests.swift.bak"
expect_failure "iOS whitespace-wrapped stored-row test removed" "iOS whitespace-wrapped stored Iroha quarantine test" good

setup_fixture
printf '\nval retiredIrohaIdentity = UniversalWalletRegistry.taira.id\n' >> \
  "$workspace/fearless-Android/feature-account-api/src/main/java/jp/co/soramitsu/account/api/domain/model/AndroidUniversalWalletMigrationSnapshotBuilder.kt"
expect_failure "Android Iroha migration registry alias restored" "Android Iroha registry aliases must not be stored-account or migration identities" good

setup_fixture
printf '\nlet retiredIrohaIdentity = UniversalWalletRegistry.taira.id\n' >> \
  "$workspace/fearless-iOS/fearless/Common/Model/UniversalWalletMigrationContract.swift"
expect_failure "iOS Iroha migration registry alias restored" "iOS Iroha registry aliases must not be migration identities" good

setup_fixture
sed -i.bak 's/&\[401\]/\&[200]/' \
  "$parent/iroha/crates/iroha_cli/src/taira.rs"
rm -f "$parent/iroha/crates/iroha_cli/src/taira.rs.bak"
expect_failure "public doctor accepts unauthenticated SoraCloud status" "public doctor protected SoraCloud route" good

setup_fixture
sed -i.bak 's/validate_canonical_authentication_challenge(result.body.as_ref())/status_only(result.body.as_ref())/' \
  "$parent/iroha/crates/iroha_cli/src/taira.rs"
rm -f "$parent/iroha/crates/iroha_cli/src/taira.rs.bak"
expect_failure "public doctor accepts an arbitrary 401 challenge" "public doctor canonical authentication proof" good

setup_fixture
sed -i.bak 's/validate_operator_signature_authentication_challenge(result.body.as_ref())/status_only(result.body.as_ref())/' \
  "$parent/iroha/crates/iroha_cli/src/taira.rs"
rm -f "$parent/iroha/crates/iroha_cli/src/taira.rs.bak"
expect_failure "public doctor accepts an arbitrary Sumeragi 401 challenge" "public doctor Sumeragi operator authentication proof" good

setup_fixture
sed -i.bak '/"sumeragi_status",/,/    ),/ s/&\[401\]/\&[200]/' \
  "$parent/iroha/crates/iroha_cli/src/taira.rs"
rm -f "$parent/iroha/crates/iroha_cli/src/taira.rs.bak"
expect_failure "public doctor accepts unauthenticated Sumeragi status" "public doctor protected Sumeragi route" good

setup_fixture
sed -i.bak 's/body.get("code")/body.get("ignored_code")/' \
  "$parent/iroha/crates/iroha_cli/src/taira.rs"
rm -f "$parent/iroha/crates/iroha_cli/src/taira.rs.bak"
expect_failure "public doctor ignores the canonical authentication code field" "canonical authentication challenge validator" good

setup_fixture
sed -i.bak 's/body.get("message")/body.get("ignored_message")/' \
  "$parent/iroha/crates/iroha_cli/src/taira.rs"
rm -f "$parent/iroha/crates/iroha_cli/src/taira.rs.bak"
expect_failure "public doctor ignores the canonical authentication message field" "canonical authentication challenge validator" good

setup_fixture
sed -i.bak '/fn validate_operator_signature_authentication_challenge/,/fn tagged_enum_name/ s/body.get("code")/body.get("ignored_code")/' \
  "$parent/iroha/crates/iroha_cli/src/taira.rs"
rm -f "$parent/iroha/crates/iroha_cli/src/taira.rs.bak"
expect_failure "public doctor ignores the Sumeragi operator code field" "Sumeragi operator challenge validator" good

setup_fixture
sed -i.bak '/fn validate_operator_signature_authentication_challenge/,/fn tagged_enum_name/ s/body.get("message")/body.get("ignored_message")/' \
  "$parent/iroha/crates/iroha_cli/src/taira.rs"
rm -f "$parent/iroha/crates/iroha_cli/src/taira.rs.bak"
expect_failure "public doctor ignores the Sumeragi operator message field" "Sumeragi operator challenge validator" good

setup_fixture
sed -i.bak '/fn validate_operator_signature_authentication_challenge/,/fn tagged_enum_name/ s/body.len() != 2/body.len() == 0/' \
  "$parent/iroha/crates/iroha_cli/src/taira.rs"
rm -f "$parent/iroha/crates/iroha_cli/src/taira.rs.bak"
expect_failure "public doctor accepts extended Sumeragi operator envelopes" "Sumeragi operator challenge validator" good

setup_fixture
sed -i.bak 's/crate::soracloud::fetch_taira_inrou_canary_status/http_json/' \
  "$parent/iroha/crates/iroha_cli/src/taira.rs"
rm -f "$parent/iroha/crates/iroha_cli/src/taira.rs.bak"
expect_failure "signed Inrou canary polls protected status without canonical auth" "signed Inrou canary topology verifier" good

setup_fixture
sed -i.bak 's/send_torii_soracloud_authenticated_get/unsigned_http_get/' \
  "$parent/iroha/crates/iroha_cli/src/soracloud.rs"
rm -f "$parent/iroha/crates/iroha_cli/src/soracloud.rs.bak"
expect_failure "signed Inrou helper drops canonical authentication" "signed Inrou protected-status helper" good

setup_fixture
sed -i.bak 's/HEADER_IROHA_SIGNATURE/HEADER_REMOVED/' \
  "$parent/iroha/crates/iroha_cli/src/soracloud.rs"
rm -f "$parent/iroha/crates/iroha_cli/src/soracloud.rs.bak"
expect_failure "signed Inrou header assertion removed" "signed Inrou canonical-header test" good

setup_fixture
sed -i.bak 's/revision_seed.service.service_version.clear()/revision_seed.service.service_version.clone()/' \
  "$parent/iroha/crates/iroha_cli/src/soracloud.rs"
rm -f "$parent/iroha/crates/iroha_cli/src/soracloud.rs.bak"
expect_failure "Inrou revision identity includes its mutable version" "immutable Inrou revision derivation" good

setup_fixture
sed -i.bak 's/bundle.service.service_version != expected_service_version/bundle.service.service_version == expected_service_version/' \
  "$parent/iroha/crates/iroha_cli/src/soracloud.rs"
rm -f "$parent/iroha/crates/iroha_cli/src/soracloud.rs.bak"
expect_failure "Inrou artifact-derived version comparison inverted" "immutable Inrou revision validator" good

setup_fixture
perl -0pi -e 's/(    let precondition = preflight_taira_inrou_mutation_target\()/    register_built_sorafs_manifest();\n$1/' \
  "$parent/iroha/crates/iroha_cli/src/soracloud.rs"
expect_failure "Inrou artifacts publish before mutation preflight" "must place" good

setup_fixture
sed -i.bak '/pub(crate) struct TairaInrouCanaryDeployment/,/fn preflight_taira_inrou_mutation_target/ s/pub service_manifest_hash/pub ignored_service_manifest_hash/' \
  "$parent/iroha/crates/iroha_cli/src/soracloud.rs"
rm -f "$parent/iroha/crates/iroha_cli/src/soracloud.rs.bak"
expect_failure "Inrou deployment drops staged service manifest identity" "deployment artifact identity" good

setup_fixture
sed -i.bak '/fn derive_service_mutation_precondition/,/fn preflight_taira_inrou_mutation_target/ s/SoraServiceMutationPreconditionV1::ServiceAbsent/SoraServiceMutationPreconditionV1::ExactCurrentRevision(default_revision)/' \
  "$parent/iroha/crates/iroha_cli/src/soracloud.rs"
rm -f "$parent/iroha/crates/iroha_cli/src/soracloud.rs.bak"
expect_failure "Inrou deploy no longer signs an absent-service compare-and-set" "signed service mutation precondition derivation" good

setup_fixture
sed -i.bak '/fn derive_service_mutation_precondition/,/fn preflight_taira_inrou_mutation_target/ s/\.get("service_manifest_hash")/.get("unbound_service_manifest_hash")/' \
  "$parent/iroha/crates/iroha_cli/src/soracloud.rs"
rm -f "$parent/iroha/crates/iroha_cli/src/soracloud.rs.bak"
expect_failure "Inrou upgrade precondition drops the active service manifest hash" "signed service mutation precondition derivation" good

setup_fixture
sed -i.bak '/fn signed_bundle_request/,/fn signed_app_infra_request/ s/&precondition/&untrusted_precondition/' \
  "$parent/iroha/crates/iroha_cli/src/soracloud.rs"
rm -f "$parent/iroha/crates/iroha_cli/src/soracloud.rs.bak"
expect_failure "CLI signature omits the exact mutation precondition" "signed mutation precondition binding" good

setup_fixture
sed -i.bak '/pub struct SoraServiceExactCurrentRevisionPreconditionV1/,/Signed compare-and-set/ s/pub process_generation/pub generation/' \
  "$parent/iroha/crates/iroha_data_model/src/soracloud/deployment.rs"
rm -f "$parent/iroha/crates/iroha_data_model/src/soracloud/deployment.rs.bak"
expect_failure "upgrade precondition drops process generation" "exact current service revision precondition" good

setup_fixture
perl -0pi -e 's/(    pub precondition: SoraServiceMutationPreconditionV1,)/    #[norito(default)]\n$1/' \
  "$parent/iroha/crates/iroha_data_model/src/isi/soracloud.rs"
expect_failure "service mutation wire precondition becomes optional" "must be mandatory in the first-release wire contract" good

setup_fixture
sed -i.bak '/pub fn encode_bundle_with_materials_provenance_payload/,/Encode the canonical provenance signature payload for service rollback/ s/precondition.clone()/condition.clone()/' \
  "$parent/iroha/crates/iroha_data_model/src/soracloud/host_protocol.rs"
rm -f "$parent/iroha/crates/iroha_data_model/src/soracloud/host_protocol.rs.bak"
expect_failure "bundle signature payload omits the mutation precondition" "signed bundle precondition payload binding" good

setup_fixture
sed -i.bak '/fn enforce_service_mutation_precondition/,/fn admit_bundle/ s/current.process_generation == \*process_generation/current.process_generation != *process_generation/' \
  "$parent/iroha/crates/iroha_core/src/smartcontracts/isi/soracloud.rs"
rm -f "$parent/iroha/crates/iroha_core/src/smartcontracts/isi/soracloud.rs.bak"
expect_failure "ledger compare-and-set accepts a different process generation" "atomic service mutation precondition enforcement" good

setup_fixture
sed -i.bak '/fn admit_bundle/,/fn admit_app_infra/ s/enforce_service_mutation_precondition/ignore_service_mutation_precondition/' \
  "$parent/iroha/crates/iroha_core/src/smartcontracts/isi/soracloud.rs"
rm -f "$parent/iroha/crates/iroha_core/src/smartcontracts/isi/soracloud.rs.bak"
expect_failure "ledger admission skips the atomic service mutation precondition" "atomic service bundle admission" good

setup_fixture
perl -0pi -e 's/(    pub precondition: SoraServiceMutationPreconditionV1,)/    #[norito(default)]\n$1/' \
  "$parent/iroha/crates/iroha_torii/src/soracloud.rs"
expect_failure "Torii mutation request makes the compare-and-set optional" "must be mandatory in the first-release request" good

setup_fixture
sed -i.bak '/fn verify_bundle_signature/,/fn verify_app_infra_signature/ s/&request.precondition/&request.untrusted_precondition/' \
  "$parent/iroha/crates/iroha_torii/src/soracloud.rs"
rm -f "$parent/iroha/crates/iroha_torii/src/soracloud.rs.bak"
expect_failure "Torii verifies a signature that does not bind the mutation precondition" "signed mutation precondition verification" good

setup_fixture
sed -i.bak '/pub(crate) async fn handle_upgrade/,/pub(crate) async fn handle_rollback/ s/precondition: request.precondition/precondition: request.untrusted_precondition/' \
  "$parent/iroha/crates/iroha_torii/src/soracloud.rs"
rm -f "$parent/iroha/crates/iroha_torii/src/soracloud.rs.bak"
expect_failure "Torii upgrade endpoint drops the verified mutation precondition" "direct mutation precondition forwarding" good

setup_fixture
sed -i.bak 's/revision.get("service_version")/revision.get("ignored_version")/' \
  "$parent/iroha/crates/iroha_cli/src/taira.rs"
rm -f "$parent/iroha/crates/iroha_cli/src/taira.rs.bak"
expect_failure "Inrou status ignores latest revision version" "authoritative revision validator" good

setup_fixture
sed -i.bak 's/revision.get("service_manifest_hash")/revision.get("ignored_service_hash")/' \
  "$parent/iroha/crates/iroha_cli/src/taira.rs"
rm -f "$parent/iroha/crates/iroha_cli/src/taira.rs.bak"
expect_failure "Inrou status ignores service manifest hash" "authoritative revision validator" good

setup_fixture
sed -i.bak 's/revision.get("container_manifest_hash")/revision.get("ignored_container_hash")/' \
  "$parent/iroha/crates/iroha_cli/src/taira.rs"
rm -f "$parent/iroha/crates/iroha_cli/src/taira.rs.bak"
expect_failure "Inrou status ignores container manifest hash" "authoritative revision validator" good

setup_fixture
sed -i.bak 's/.filter(|generation| \*generation > 0)/.filter(|generation| *generation >= 0)/' \
  "$parent/iroha/crates/iroha_cli/src/taira.rs"
rm -f "$parent/iroha/crates/iroha_cli/src/taira.rs.bak"
expect_failure "Inrou status accepts zero process generation" "authoritative revision validator" good

setup_fixture
sed -i.bak '/impl InrouCanaryConvergence/,/fn validate_exact_inrou_canary_status/ s/self.identities.clear()/self.identities.retain_stale_evidence()/g' \
  "$parent/iroha/crates/iroha_cli/src/taira.rs"
rm -f "$parent/iroha/crates/iroha_cli/src/taira.rs.bak"
expect_failure "Inrou convergence retains stale route identities" "generation-scoped convergence state" good

setup_fixture
sed -i.bak '/fn validate_exact_inrou_canary_route/,/fn inrou_canary_health_path/ s/SORACLOUD_SERVED_SERVICE_VERSION_HEADER/SORACLOUD_UNTRUSTED_SERVICE_VERSION_HEADER/' \
  "$parent/iroha/crates/iroha_cli/src/taira.rs"
rm -f "$parent/iroha/crates/iroha_cli/src/taira.rs.bak"
expect_failure "Inrou route ignores Torii served version" "route evidence validator" good

setup_fixture
sed -i.bak '/fn validate_exact_inrou_canary_route/,/fn inrou_canary_health_path/ s/SORACLOUD_SERVED_PROCESS_GENERATION_HEADER/SORACLOUD_UNTRUSTED_PROCESS_GENERATION_HEADER/' \
  "$parent/iroha/crates/iroha_cli/src/taira.rs"
rm -f "$parent/iroha/crates/iroha_cli/src/taira.rs.bak"
expect_failure "Inrou route trusts caller-labeled process generation" "route evidence validator" good

setup_fixture
sed -i.bak '/fn validate_exact_inrou_canary_route/,/fn inrou_canary_health_path/ s/deployment.bundle_hash.as_str()/deployment.unbound_bundle_hash.as_str()/' \
  "$parent/iroha/crates/iroha_cli/src/taira.rs"
rm -f "$parent/iroha/crates/iroha_cli/src/taira.rs.bak"
expect_failure "Inrou route ignores materialized bundle identity" "route evidence validator" good

setup_fixture
sed -i.bak '/fn verify_inrou_canary/,/fn run_write_canary/ s/continue;/accept_route_anyway;/' \
  "$parent/iroha/crates/iroha_cli/src/taira.rs"
rm -f "$parent/iroha/crates/iroha_cli/src/taira.rs.bak"
expect_failure "Inrou verifier probes route after invalid status" "fail-closed Inrou convergence verifier" good

setup_fixture
sed -i.bak '/fn verify_inrou_canary/,/fn run_write_canary/ s/if convergence.is_complete()/if route_set_is_unconfirmed()/' \
  "$parent/iroha/crates/iroha_cli/src/taira.rs"
rm -f "$parent/iroha/crates/iroha_cli/src/taira.rs.bak"
expect_failure "Inrou verifier omits post-route status confirmation" "fail-closed Inrou convergence verifier" good

setup_fixture
sed -i.bak 's/x-iroha-soracloud-served-service-version/x-iroha-soracloud-self-reported-version/' \
  "$parent/iroha/crates/iroha_torii_shared/src/lib.rs"
rm -f "$parent/iroha/crates/iroha_torii_shared/src/lib.rs.bak"
expect_failure "Torii shared served-version header drifts" "shared hosted-response header" good

setup_fixture
sed -i.bak 's/x-iroha-soracloud-served-process-generation/x-iroha-soracloud-self-reported-generation/' \
  "$parent/iroha/crates/iroha_torii_shared/src/lib.rs"
rm -f "$parent/iroha/crates/iroha_torii_shared/src/lib.rs.bak"
expect_failure "Torii shared served-generation header drifts" "shared hosted-response header" good

setup_fixture
sed -i.bak 's/headers.insert(SORACLOUD_SERVED_SERVICE_VERSION_HEADER/headers.append(SORACLOUD_SERVED_SERVICE_VERSION_HEADER/' \
  "$parent/iroha/crates/iroha_torii/src/lib.rs"
rm -f "$parent/iroha/crates/iroha_torii/src/lib.rs.bak"
expect_failure "Torii appends guest-spoofable served version" "served-revision response headers" good

setup_fixture
sed -i.bak '/fn overwrite_soracloud_served_revision_headers/,/fn exact_soracloud_served_revision_header/ s/target.process_generation/target.untrusted_process_generation/' \
  "$parent/iroha/crates/iroha_torii/src/lib.rs"
rm -f "$parent/iroha/crates/iroha_torii/src/lib.rs.bak"
expect_failure "Torii served headers omit authoritative process generation" "served-revision response headers" good

setup_fixture
sed -i.bak '/if let Some(listen_base_url)/,/let local_peer_id/ s/overwrite_soracloud_served_revision_headers/trust_upstream_served_revision_headers/' \
  "$parent/iroha/crates/iroha_torii/src/lib.rs"
rm -f "$parent/iroha/crates/iroha_torii/src/lib.rs.bak"
expect_failure "Torii local ingress omits served-revision overwrite" "local and remote response binding" good

setup_fixture
sed -i.bak '/fn resolve_exact_hosted_http_runtime_target/,/fn overwrite_soracloud_served_revision_headers/ s/ensure_matching_hosted_http_materialized_bundle_hash/trust_authoritative_bundle_hash/' \
  "$parent/iroha/crates/iroha_torii/src/lib.rs"
rm -f "$parent/iroha/crates/iroha_torii/src/lib.rs.bak"
expect_failure "Torii remote resolution skips local served-revision agreement" "exact remote-target authoritative served-revision agreement" good

setup_fixture
sed -i.bak '/fn resolve_hosted_http_runtime_target/,/fn resolve_exact_hosted_http_runtime_target/ s/ensure_matching_hosted_http_materialized_bundle_hash/trust_authoritative_bundle_hash/' \
  "$parent/iroha/crates/iroha_torii/src/lib.rs"
rm -f "$parent/iroha/crates/iroha_torii/src/lib.rs.bak"
expect_failure "Torii public local target skips served-revision agreement" "authoritative public hosted-target binding" good

setup_fixture
sed -i.bak '/fn resolve_hosted_http_runtime_target/,/fn resolve_exact_hosted_http_runtime_target/ s/select_authoritative_hosted_http_replica/local_healthy_hosted_http_placement/' \
  "$parent/iroha/crates/iroha_torii/src/lib.rs"
rm -f "$parent/iroha/crates/iroha_torii/src/lib.rs.bak"
expect_failure "Torii public target falls back to local-only runtime state" "authoritative public hosted-target binding" good

setup_fixture
sed -i.bak '/fn ensure_local_hosted_http_snapshot_origin/,/cfg(not(any(feature/ s/snapshot.local_peer_id.as_deref().ok_or_else/snapshot.local_peer_id.as_deref/' \
  "$parent/iroha/crates/iroha_torii/src/lib.rs"
rm -f "$parent/iroha/crates/iroha_torii/src/lib.rs.bak"
expect_failure "Torii accepts runtime snapshot without exact peer identity" "exact local runtime snapshot ownership" good

setup_fixture
perl -0pi -e 's/(#\[cfg\(feature = "app_api"\)\]\n#\[cfg\(not\(any\(feature = "p2p_ws", feature = "connect"\)\)\)\]\nfn ensure_local_hosted_http_snapshot_origin\(.*?SoracloudRuntimeExecutionErrorKind::)Unavailable/${1}Internal/s' \
  "$parent/iroha/crates/iroha_torii/src/lib.rs"
expect_failure "Torii without peer connectivity accepts unverifiable runtime snapshot identity" "no-connect runtime snapshot rejection" good

setup_fixture
sed -i.bak '/fn resolve_local_hosted_http_replica_runtime/,/fn resolve_hosted_http_runtime_target/ s/plan.process_generation.filter(|value| \*value > 0)?/plan.process_generation.unwrap_or(0)/' \
  "$parent/iroha/crates/iroha_torii/src/lib.rs"
rm -f "$parent/iroha/crates/iroha_torii/src/lib.rs.bak"
expect_failure "Torii accepts missing local runtime process generation" "positive local runtime process generation" good

setup_fixture
sed -i.bak '/fn resolve_exact_hosted_http_runtime_target/,/fn overwrite_soracloud_served_revision_headers/ s/SoraServiceHealthStatusV1::Healthy/SoraServiceHealthStatusV1::Unavailable/' \
  "$parent/iroha/crates/iroha_torii/src/lib.rs"
rm -f "$parent/iroha/crates/iroha_torii/src/lib.rs.bak"
expect_failure "Torii remote target accepts unhealthy authoritative runtime state" "exact remote-target authoritative served-revision agreement" good

setup_fixture
sed -i.bak '/execute_incoming_torii_proxy_request_with_admission_inner/,/reject_incoming_torii_proxy_request_capacity/ s/overwrite_soracloud_served_revision_headers/omit_soracloud_served_revision_headers/' \
  "$parent/iroha/crates/iroha_torii/src/lib.rs"
rm -f "$parent/iroha/crates/iroha_torii/src/lib.rs.bak"
expect_failure "Torii remote peer omits authoritative served-revision stamping" "remote hosting-peer served-revision stamping" good

setup_fixture
sed -i.bak '/fn exact_soracloud_served_revision_header/,/fn validate_soracloud_served_revision_headers/ s/if values.next().is_some()/if values.next().is_none()/' \
  "$parent/iroha/crates/iroha_torii/src/lib.rs"
rm -f "$parent/iroha/crates/iroha_torii/src/lib.rs.bak"
expect_failure "Torii origin accepts duplicate served-revision headers" "exact remote served-revision header parser" good

setup_fixture
sed -i.bak '/fn validate_soracloud_served_revision_headers/,/fn proxy_soracloud_public_hosted_http_locally/ s/target.process_generation.to_string()/target.untrusted_process_generation.to_string()/' \
  "$parent/iroha/crates/iroha_torii/src/lib.rs"
rm -f "$parent/iroha/crates/iroha_torii/src/lib.rs.bak"
expect_failure "Torii origin ignores remote served process generation" "origin validation of remote served-revision proof" good

setup_fixture
sed -i.bak '/Ok(Some(mut response))/,/Ok(None)/ s/validate_soracloud_served_revision_headers/trust_remote_soracloud_served_revision_headers/' \
  "$parent/iroha/crates/iroha_torii/src/lib.rs"
rm -f "$parent/iroha/crates/iroha_torii/src/lib.rs.bak"
expect_failure "Torii origin trusts unvalidated remote served-revision headers" "origin remote served-revision validation and overwrite" good

setup_fixture
perl -0pi -e 's/state\.materialized_bundle_hash != admitted_bundle\.container\.bundle_hash/state.materialized_bundle_hash == admitted_bundle.container.bundle_hash/' \
  "$parent/iroha/crates/iroha_core/src/smartcontracts/isi/soracloud.rs"
expect_failure "Inrou runtime telemetry accepts a bundle other than the admitted revision" "ledger Inrou runtime admitted-bundle binding" good

setup_fixture
perl -0pi -e 's/consensus_lane_dataspace_at_height\(lane_id, &self\.nexus, authority_height\)\.is_some\(\)/true/' \
  "$parent/iroha/crates/iroha_core/src/state.rs"
expect_failure "Exact state-view lane authority predicate accepts every lane" "exact state-view lane authority predicate" good

setup_fixture
perl -0pi -e 's/ && lane_is_active_for_authority\(key\.0\)//' \
  "$parent/iroha/crates/iroha_core/src/soracloud_runtime.rs"
expect_failure "Shared Soracloud serving gate accepts a validator row on an inactive lane" "shared exact active-validator lane-authority serving gate" good

setup_fixture
perl -0pi -e 's/(pub fn soracloud_hf_placement_assignment_has_active_capability\(.*?&& )soracloud_validator_is_active/${1}soracloud_validator_has_capability/s' \
  "$parent/iroha/crates/iroha_core/src/soracloud_runtime.rs"
expect_failure "Generated HF serving ignores authoritative validator lifecycle" "generated-HF active validator and exact capability serving gate" good

setup_fixture
perl -0pi -e 's/(fn resolve_generated_hf_primary_assignment_rejects_stale_mismatched_or_inactive_capability\(\).*?)LaneId::new\(1\)/${1}LaneId::SINGLE/s' \
  "$parent/iroha/crates/iroha_core/src/soracloud_runtime.rs"
expect_failure "Generated HF inactive-lane serving regression test no longer exercises an inactive lane" "generated-HF inactive validator lane serving rejection test" good

setup_fixture
perl -0pi -e 's/(fn select_inrou_replica_placement\(.*?crate::soracloud_runtime::)soracloud_validator_is_active/${1}soracloud_validator_has_capability/s' \
  "$parent/iroha/crates/iroha_core/src/smartcontracts/isi/soracloud.rs"
expect_failure "Inrou placement admits an inactive validator with a live capability advert" "Inrou placement active-validator admission" good

setup_fixture
perl -0pi -e 's/(fn reconcile_inrou_service_placements\(.*?crate::soracloud_runtime::)soracloud_validator_is_active/${1}soracloud_validator_has_capability/s' \
  "$parent/iroha/crates/iroha_core/src/smartcontracts/isi/soracloud.rs"
expect_failure "Inrou eligible-host accounting includes an inactive validator" "Inrou eligible-validator count admission" good

setup_fixture
perl -0pi -e 's/(fn inrou_host_platform_supports_static_local_materialization\(\).*?)ensure_configured_inrou_backends_statically_available/${1}ensure_configured_inrou_backends_available/s' \
  "$parent/iroha/crates/irohad/src/soracloud_runtime.rs"
expect_failure "Iroha daemon tests branch on a transient dynamic probe instead of production static eligibility" "test branch matches static Inrou production eligibility" good

setup_fixture
perl -0pi -e 's/(fn inrou_placement_reconcile_needed\(.*?soracloud_runtime::)soracloud_validator_is_active/${1}soracloud_validator_has_capability/s' \
  "$parent/iroha/crates/irohad/src/soracloud_runtime.rs"
expect_failure "Iroha daemon does not reconcile an Inrou placement after validator exit" "daemon Inrou placement validator-lifecycle reconciliation trigger" good

setup_fixture
perl -0pi -e 's/(fn inrou_placement_reconcile_detects_inactive_validator_with_live_capability\(\).*?status: )PublicLaneValidatorStatus::Exited/${1}PublicLaneValidatorStatus::Active/s' \
  "$parent/iroha/crates/irohad/src/soracloud_runtime.rs"
expect_failure "Iroha daemon inactive-validator reconciliation test no longer exits the validator" "daemon inactive-validator Inrou reconciliation trigger test" good

setup_fixture
perl -0pi -e 's/(fn reconcile_once_retries_http_service_runtime_state_until_authoritative_state_catches_up\(\).*?with_inrou_hosting_available_override\()true/${1}false/s' \
  "$parent/iroha/crates/irohad/src/soracloud_runtime.rs"
expect_failure "Iroha daemon deterministic projection test forces the Inrou positive path off" "deterministic positive Inrou projection and runtime-state submission test" good

setup_fixture
perl -0pi -e 's/let inrou_hosting_available_override: Option<bool> = None;/let inrou_hosting_available_override: Option<bool> = Some(true);/' \
  "$parent/iroha/crates/irohad/src/soracloud_runtime.rs"
expect_failure "Iroha daemon leaks the test availability override into production" "test-only deterministic Inrou hosting availability seam" good

setup_fixture
perl -0pi -e 's/(fn inrou_portable_smoke_boots_debian_guest_and_serves_healthcheck\(\).*?)bundle\.service\.container\.manifest_hash = bundle\.container_manifest_hash\(\);/${1}bundle.service.container.manifest_hash = bundle.service.container.manifest_hash;/s' \
  "$parent/iroha/crates/irohad/src/soracloud_runtime.rs"
expect_failure "PortableVM smoke fixture stores a stale container manifest hash" "production-valid PortableVM smoke fixture" good

setup_fixture
perl -0pi -e 's/(fn inrou_portable_smoke_boots_external_bundle_and_serves_healthcheck\(\).*?)bundle\.service\.container\.manifest_hash = bundle\.container_manifest_hash\(\);/${1}bundle.service.container.manifest_hash = bundle.service.container.manifest_hash;/s' \
  "$parent/iroha/crates/irohad/src/soracloud_runtime/tests/runtime_tail.rs"
expect_failure "External PortableVM smoke fixture stores a stale container manifest hash" "production-valid external Inrou smoke fixture" good

setup_fixture
perl -0pi -e 's/record\.window_started_at_ms != Some\(window_started_at_ms\)/record.window_started_at_ms == Some(window_started_at_ms)/' \
  "$parent/iroha/crates/iroha_core/src/smartcontracts/isi/soracloud.rs"
expect_failure "Generated HF heartbeat strikes leak across reservation windows" "reservation-window-scoped heartbeat strike history" good

setup_fixture
perl -0pi -e 's/    let reconciliation_plans =/    let placement_id: None;\n    let reconciliation_plans =/' \
  "$parent/iroha/crates/iroha_core/src/smartcontracts/isi/soracloud.rs"
expect_failure "Generated HF reconciliation synthesizes placementless strike evidence" "must not synthesize placementless heartbeat strikes" good

setup_fixture
perl -0pi -e 's/if !validator_is_active \{/if validator_is_active {/' \
  "$parent/iroha/crates/iroha_core/src/smartcontracts/isi/soracloud.rs"
expect_failure "Generated HF reconciliation ignores validator lifecycle withdrawal" "lifecycle-aware idempotent batched model-host reconciliation" good

setup_fixture
perl -0pi -e 's/if cause == ModelHostReconciliationCause::ValidatorInactive \{/if cause != ModelHostReconciliationCause::ValidatorInactive {/' \
  "$parent/iroha/crates/iroha_core/src/smartcontracts/isi/soracloud.rs"
expect_failure "Generated HF validator exit is misclassified as a slashable hosting violation" "lifecycle-aware idempotent batched model-host reconciliation" good

setup_fixture
perl -0pi -e 's/(fn reconcile_soracloud_model_hosts_rebalances_inactive_validator_without_violation\(\).*?view\.world\(\)\.soracloud_model_host_violation_evidence\(\)\.len\(\),\n        )0,/${1}1,/s' \
  "$parent/iroha/crates/iroha_core/src/smartcontracts/isi/soracloud_tests.rs"
expect_failure "Inactive-validator failover test accepts manufactured violation evidence" "inactive-validator non-penalizing model-host failover test" good

setup_fixture
perl -0pi -e 's/if torii_peer_id != &runtime_peer_id/if torii_peer_id == \&runtime_peer_id/' \
  "$parent/iroha/crates/iroha_torii/src/lib.rs"
expect_failure "Torii accepts a runtime identity that differs from its configured peer" "exact local runtime-to-ingress peer identity binding" good

setup_fixture
perl -0pi -e 's/(fn resolve_soracloud_local_read_proxy_target\(.*?let local_peer_id = )exact_local_soracloud_runtime_peer_id/${1}unchecked_local_soracloud_runtime_peer_id/s' \
  "$parent/iroha/crates/iroha_torii/src/lib.rs"
expect_failure "Generated HF outgoing proxy routing bypasses exact local peer binding" "outgoing proxy target exact local peer binding" good

setup_fixture
perl -0pi -e 's/(fn local_soracloud_proxy_receiver_is_assigned_host\(.*?let local_peer_id = )exact_local_soracloud_runtime_peer_id/${1}unchecked_local_soracloud_runtime_peer_id/s' \
  "$parent/iroha/crates/iroha_torii/src/lib.rs"
expect_failure "Generated HF assigned-host receiver bypasses exact local peer binding" "local assigned-host receiver exact local peer binding" good

setup_fixture
perl -0pi -e 's/(fn validate_incoming_soracloud_proxy_request_authority\(.*?let local_peer_id = )exact_local_soracloud_runtime_peer_id/${1}unchecked_local_soracloud_runtime_peer_id/s' \
  "$parent/iroha/crates/iroha_torii/src/lib.rs"
expect_failure "Generated HF incoming authority bypasses exact local peer binding" "incoming proxy authority exact local peer binding" good

setup_fixture
perl -0pi -e 's/target_peer_id\.to_string\(\) != primary_assignment\.peer_id/target_peer_id.to_string() == primary_assignment.peer_id/' \
  "$parent/iroha/crates/iroha_torii/src/lib.rs"
expect_failure "Generated HF accepts a response from a superseded primary peer" "proxy responding-peer authority binding" good

setup_fixture
perl -0pi -e 's/(fn hosted_http_capability_matches_placement\(.*?soracloud_runtime::)soracloud_validator_is_active/${1}soracloud_validator_has_capability/s' \
  "$parent/iroha/crates/iroha_torii/src/lib.rs"
expect_failure "Torii hosted-service routing admits an inactive validator advert" "active matching hosted-service capability admission" good

echo "[iroha-readiness-test] all $test_case_count tests passed"
