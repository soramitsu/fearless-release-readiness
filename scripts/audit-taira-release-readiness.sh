#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="${IROHA_READINESS_ROOT:-$(cd "$SCRIPT_DIR/.." && pwd)}"
PARENT_DIR="${IROHA_READINESS_PARENT:-$(cd "$ROOT_DIR/.." && pwd)}"
args=(--root "$ROOT_DIR" --parent "$PARENT_DIR")

case "${IROHA_TAIRA_LIVE_HEALTH:-0}" in
  1|true) args+=(--live) ;;
  0|false) ;;
  *)
    echo "[taira-readiness][error] IROHA_TAIRA_LIVE_HEALTH must be exactly one of: 0, 1, false, true" >&2
    exit 2
    ;;
esac

exec /usr/bin/env \
  -u NODE_EXTRA_CA_CERTS \
  -u NODE_TLS_REJECT_UNAUTHORIZED \
  -u NODE_USE_ENV_PROXY \
  -u NODE_USE_SYSTEM_CA \
  -u NODE_PATH \
  -u NODE_OPTIONS \
  -u NPM_CONFIG_NODE_OPTIONS \
  -u npm_config_node_options \
  -u NODE_DEBUG \
  -u SSLKEYLOGFILE \
  -u SSL_CERT_FILE \
  -u SSL_CERT_DIR \
  -u OPENSSL_CONF \
  -u HTTP_PROXY \
  -u HTTPS_PROXY \
  -u ALL_PROXY \
  -u NO_PROXY \
  -u http_proxy \
  -u https_proxy \
  -u all_proxy \
  -u no_proxy \
  -u GLOBAL_AGENT_HTTP_PROXY \
  -u GLOBAL_AGENT_HTTPS_PROXY \
  -u GLOBAL_AGENT_NO_PROXY \
  -u GLOBAL_AGENT_ENVIRONMENT_VARIABLE_NAMESPACE \
  node "$SCRIPT_DIR/audit-taira-release-readiness.mjs" "${args[@]}"
