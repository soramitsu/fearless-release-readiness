#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="${WORKFLOW_ACTION_PIN_AUDIT_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
PARENT_DIR="${WORKFLOW_ACTION_PIN_AUDIT_PARENT:-$(cd "$ROOT_DIR/.." && pwd)}"
MAX_WORKFLOW_BYTES=$((1024 * 1024))

repos=(
  "$ROOT_DIR"
  "$ROOT_DIR/fearless-Android-production-consolidated-20260731"
  "$ROOT_DIR/fearless-iOS-production-consolidated-20260731"
  "$ROOT_DIR/fearless-wallet-web"
  "$ROOT_DIR/fearless-site-web"
  "$PARENT_DIR/ton-indexer"
  "$PARENT_DIR/solswap-indexer"
  "$PARENT_DIR/polkaswap-indexer"
)

workflow_files=()
for repo in "${repos[@]}"; do
  workflow_dir="$repo/.github/workflows"
  if [[ ! -d "$workflow_dir" || -L "$workflow_dir" ]]; then
    echo "[workflow-action-pins][error] workflow directory missing or unsafe: $workflow_dir" >&2
    exit 1
  fi
  unsafe_workflow="$(find "$workflow_dir" -maxdepth 1 -type l \( -name '*.yml' -o -name '*.yaml' \) -print -quit)"
  if [[ -n "$unsafe_workflow" ]]; then
    echo "[workflow-action-pins][error] workflow must be a regular non-symlink file: $unsafe_workflow" >&2
    exit 1
  fi
  repo_workflow_count=0
  while IFS= read -r workflow; do
    if [[ ! -f "$workflow" || -L "$workflow" ]]; then
      echo "[workflow-action-pins][error] workflow must be a regular non-symlink file: $workflow" >&2
      exit 1
    fi
    size="$(stat -c '%s' "$workflow" 2>/dev/null || stat -f '%z' "$workflow")"
    if [[ ! "$size" =~ ^[0-9]+$ || "$size" -gt "$MAX_WORKFLOW_BYTES" ]]; then
      echo "[workflow-action-pins][error] workflow exceeds 1 MiB: $workflow" >&2
      exit 1
    fi
    workflow_files+=("$workflow")
    ((repo_workflow_count += 1))
  done < <(find "$workflow_dir" -maxdepth 1 -type f \( -name '*.yml' -o -name '*.yaml' \) -print | LC_ALL=C sort)
  if ((repo_workflow_count == 0)); then
    echo "[workflow-action-pins][error] no workflow YAML files found: $workflow_dir" >&2
    exit 1
  fi
done

WORKFLOW_ACTION_PIN_FILES="$(printf '%s\n' "${workflow_files[@]}")" \
WORKFLOW_ACTION_PIN_ROOT_PUBLICATION="$ROOT_DIR/.github/workflows/passkey-image-publish.yml" \
node <<'NODE'
const fs = require('node:fs');

const expectedPins = new Map([
  ['actions/checkout', '34e114876b0b11c390a56381ad16ebd13914f8d5'],
  ['actions/setup-node', '49933ea5288caeca8642d1e84afbd3f7d6820020'],
]);
const publicationExpectedPins = new Map([
  ['actions/checkout', '34e114876b0b11c390a56381ad16ebd13914f8d5'],
  ['actions/attest-build-provenance', '977bb373ede98d70efdf65b84cb5f73e068dcc2a'],
  ['actions/upload-artifact', 'ea165f8d65b6e75b540449e92b4886f43607fa02'],
  ['docker/build-push-action', '10e90e3645eae34f1e60eeb005ba3a3d33f178e8'],
  ['docker/login-action', 'c94ce9fb468520275223c153574b00df6fe4bcc9'],
  ['docker/setup-buildx-action', '8d2750c68a42422c14e847fe6c8ac0403b4cbd6f'],
  ['docker/setup-qemu-action', 'c7c53464625b32c7a7e944ae62b3e17d2b600130'],
]);
const files = process.env.WORKFLOW_ACTION_PIN_FILES.split('\n').filter(Boolean);
const publicationFile = process.env.WORKFLOW_ACTION_PIN_ROOT_PUBLICATION;
let actionCount = 0;

function fail(message) {
  console.error(`[workflow-action-pins][error] ${message}`);
  process.exitCode = 1;
}

for (const file of files) {
  const source = fs.readFileSync(file, 'utf8');
  const lines = source.split(/\r?\n/);
  for (let index = 0; index < lines.length; index += 1) {
    if (!/^\s*(?:-\s*)?uses\s*:/.test(lines[index])) continue;
    const match = /^\s*(?:-\s*)?uses\s*:\s*([^\s#]+)(?:\s+#.*)?\s*$/.exec(lines[index]);
    if (!match) {
      fail(`${file}:${index + 1} has a noncanonical uses declaration`);
      continue;
    }
    const reference = match[1];
    actionCount += 1;
    if (reference.startsWith('./')) {
      if (reference.includes('..') || reference.includes('\\')) {
        fail(`${file}:${index + 1} has an unsafe local action reference: ${reference}`);
      }
      continue;
    }
    if (reference.startsWith('docker://')) {
      if (!/^docker:\/\/[^\s@]+@sha256:[0-9a-f]{64}$/.test(reference)) {
        fail(`${file}:${index + 1} Docker action is not pinned by sha256 digest: ${reference}`);
      }
      continue;
    }
    const remote = /^([A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+)(?:\/[A-Za-z0-9_./-]+)?@([0-9a-f]{40})$/.exec(reference);
    if (!remote) {
      fail(`${file}:${index + 1} action is not pinned by a full lowercase commit SHA: ${reference}`);
      continue;
    }
    const expected = (file === publicationFile ? publicationExpectedPins : expectedPins).get(remote[1]);
    if (expected && remote[2] !== expected) {
      fail(`${file}:${index + 1} ${remote[1]} must use reviewed commit ${expected}`);
    }
  }
}

if (actionCount === 0) fail('maintained workflows contain no action references');
if (process.exitCode) process.exit(process.exitCode);
console.log(`[workflow-action-pins] verified ${actionCount} immutable action references across ${files.length} workflows`);
NODE
