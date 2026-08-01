#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="${IROHA_WALLET_COVERAGE_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"

failures=()

log() { echo "[iroha-wallet-coverage] $*"; }
warn() { echo "[iroha-wallet-coverage][warn] $*" >&2; }

record_failure() {
  failures+=("$1")
  warn "$1"
}

require_file() {
  local file="$1"
  local description="$2"
  [[ -f "$file" ]] || record_failure "$description missing: $file"
}

require_executable_file() {
  local file="$1"
  local description="$2"
  if [[ ! -f "$file" || -L "$file" ]]; then
    record_failure "$description missing or not a regular file: $file"
  elif [[ ! -x "$file" ]]; then
    record_failure "$description is not executable: $file"
  fi
}

require_literal() {
  local file="$1"
  local literal="$2"
  local description="$3"
  if [[ ! -f "$file" ]]; then
    return
  fi
  if ! grep -Fq "$literal" "$file"; then
    record_failure "$description missing in $file"
  fi
}

check_web_coverage() {
  local web="$ROOT_DIR/fearless-wallet-web"
  local transfer_test="$web/tests/unit/iroha-background-transfer.spec.ts"
  local smoke="$web/scripts/solana-extension-smoke.mjs"
  local codec="$web/src/extension/background/extension-base/src/api/iroha/nexusSdkTransferCodec.ts"
  local transfer="$web/src/extension/background/extension-base/src/api/iroha/transfer.ts"
  local public_artifact_test="$web/scripts/test-public-artifacts-audit.sh"

  log "Checking web Iroha/Nexus transfer coverage"
  require_file "$transfer_test" "web Iroha background transfer unit test"
  require_file "$smoke" "web Iroha browser smoke"
  require_file "$codec" "web Nexus SDK transfer codec"
  require_file "$transfer" "web Iroha transfer implementation"
  require_file "$public_artifact_test" "web public artifact audit self-test"

  require_literal "$transfer_test" "builds and signs with an injected Nexus browser SDK transaction codec" "web Nexus SDK positive transfer test"
  require_literal "$transfer_test" "rejects Nexus SDK signing when the stored mnemonic does not match the account public key" "web Nexus mnemonic mismatch test"
  require_literal "$transfer_test" "rejects incomplete or malformed Nexus SDK transaction codec outputs" "web Nexus malformed codec output test"
  require_literal "$transfer_test" "fails closed while Iroha transfers are not release-enabled" "web Iroha disabled-transfer fail-closed test"
  require_literal "$transfer_test" "forwards only a snapshotted exact web wallet-smoke metadata object on Nexus" "web immutable Nexus wallet-smoke metadata test"
  require_literal "$transfer_test" "rejects malformed and adversarial wallet-smoke metadata before signing" "web wallet-smoke adversarial rejection test"
  require_literal "$transfer_test" "submits an operator-only Nexus wallet smoke with exact bound metadata" "web operator-only Nexus wallet-smoke test"
  require_literal "$transfer_test" "rejects unsafe wallet-smoke requests before codec or Torii access" "web pre-signer wallet-smoke route rejection test"
  require_literal "$codec" "finalizeSignedTransaction" "web Nexus transaction finalizer seam"
  require_literal "$codec" "iroha_signing_key_mismatch" "web Nexus signing-key mismatch guard"
  require_literal "$codec" "invalid_iroha_signed_transaction_hash" "web Nexus signed-transaction hash guard"
  require_literal "$codec" "normalizeIrohaWalletSmokeMetadata" "web exact wallet-smoke metadata codec guard"
  require_literal "$codec" "iroha_wallet_smoke_requires_nexus" "web wallet-smoke Nexus-only codec guard"
  require_literal "$transfer" "makeIrohaWalletSmokeTransfer" "web operator-only wallet-smoke entry point"
  require_literal "$smoke" "Expected fail-closed Iroha signing rejection" "web browser Iroha signing fail-closed smoke"
  require_literal "$smoke" "startIrohaConnect(cdp, dappSession, 'nexus')" "web browser Nexus connect smoke"
  require_literal "$public_artifact_test" "transfer enablement with pinned old package still blocked without reviewed codec artifact" "web Iroha reviewed-codec release blocker test"
  require_literal "$public_artifact_test" "browser_transaction_codec_unpublished_source_only" "web Iroha unpublished-source blocker diagnostic test"
}

check_android_coverage() {
  local android="$ROOT_DIR/fearless-Android"
  local transfer_test="$android/feature-wallet-impl/src/test/java/jp/co/soramitsu/wallet/impl/data/repository/tranfser/BitcoinTransferServiceProviderTest.kt"
  local metadata_test="$android/feature-wallet-impl/src/test/java/jp/co/soramitsu/wallet/impl/data/repository/tranfser/IrohaTransferMetadataTest.kt"
  local metadata="$android/feature-wallet-impl/src/main/java/jp/co/soramitsu/wallet/impl/data/repository/tranfser/IrohaTransferMetadata.kt"
  local transfer="$android/feature-wallet-impl/src/main/java/jp/co/soramitsu/wallet/impl/data/repository/tranfser/TransferService.kt"
  local bridge="$android/iroha-sdk-bridge/src/main/java/jp/co/soramitsu/iroha/bridge/IrohaTransferBridge.java"
  local bridge_test="$android/iroha-sdk-bridge/src/test/java/jp/co/soramitsu/iroha/bridge/IrohaTransferBridgeTest.java"
  local torii_test="$android/common/src/test/java/jp/co/soramitsu/common/wallet/IrohaToriiClientTest.kt"
  local routing_test="$android/feature-wallet-impl/src/test/java/jp/co/soramitsu/wallet/impl/data/repository/UniversalWalletIrohaRoutingTest.kt"

  log "Checking Android Iroha/Nexus transfer coverage"
  require_file "$transfer_test" "Android Iroha transfer provider test"
  require_file "$metadata_test" "Android Iroha wallet-smoke metadata test"
  require_file "$metadata" "Android Iroha wallet-smoke metadata contract"
  require_file "$transfer" "Android Iroha transfer service"
  require_file "$bridge" "Android staged Iroha bridge"
  require_file "$bridge_test" "Android staged Iroha bridge test"
  require_file "$torii_test" "Android Iroha Torii client test"
  require_file "$routing_test" "Android Iroha routing test"

  require_literal "$transfer_test" "provider routes iroha chains to fail closed iroha transfer service" "Android Iroha disabled-signer fail-closed transfer test"
  require_literal "$transfer_test" "iroha transfer builds signed transfer request and submits norito to torii" "Android Taira signed transfer submission test"
  require_literal "$transfer_test" "iroha transfer builds nexus signed transfer request and submits norito to minamoto torii" "Android Nexus signed transfer submission test"
  require_literal "$transfer_test" "iroha transfer rejects mnemonic mismatch before signer or torii calls" "Android Iroha mnemonic mismatch test"
  require_literal "$transfer_test" "assertEquals(\"nexus\", signer.lastRequest?.network)" "Android Nexus signer network assertion"
  require_literal "$transfer_test" "nexus wallet smoke evidence uses exact immutable metadata and canonical minamoto" "Android immutable Nexus wallet-smoke metadata test"
  require_literal "$transfer_test" "wallet smoke evidence rejects taira and noncanonical minamoto before signer or torii" "Android wallet-smoke route rejection test"
  require_literal "$transfer_test" "wallet smoke evidence rejects malformed and aliasing metadata before signer or torii" "Android wallet-smoke adversarial rejection test"
  require_literal "$metadata_test" "wallet smoke factory emits exact canonical all-string contract" "Android exact wallet-smoke metadata contract test"
  require_literal "$metadata_test" "explicit wallet smoke path preserves ordinary empty metadata and fail closed signer selection" "Android wallet-smoke unavailable-signer fail-closed test"
  require_literal "$metadata_test" "rejects malformed wallet smoke metadata before signer or torii calls" "Android pre-signer malformed metadata test"
  require_literal "$metadata_test" "metadata snapshots mutable input and returns immutable defensive copies" "Android wallet-smoke metadata anti-aliasing test"
  require_literal "$metadata_test" "wallet smoke metadata is rejected outside exact Nexus global context" "Android exact Nexus context test"
  require_literal "$metadata" "requireNexusWalletSmokeContext" "Android wallet-smoke Nexus-only construction guard"
  require_literal "$transfer" "transferWalletSmokeEvidence" "Android operator-only Nexus wallet-smoke entry point"
  require_literal "$bridge" "wallet-smoke transaction metadata is Nexus-only; staged Taira bridge requires empty metadata" "Android staged Taira bridge metadata rejection guard"
  require_literal "$bridge_test" "rejectsCanonicalNexusWalletSmokeMetadataBeforeClockOrSigning" "Android staged bridge pre-signer Nexus metadata rejection test"
  require_literal "$bridge_test" "transactionMetadataIsDefensivelyCopiedAndImmutable" "Android staged bridge metadata immutability test"
  require_literal "$torii_test" "routes nexus through registry torii url while allowing runtime override" "Android Nexus Torii routing test"
  require_literal "$torii_test" "rejects wrong-network iroha account ids before fetch" "Android wrong-network Iroha account rejection"
  require_literal "$routing_test" "meta account derives nexus address from the same public key with nexus discriminant" "Android Nexus address derivation test"
  require_literal "$routing_test" "iroha address normalization rejects wrong network discriminant" "Android Iroha wrong-discriminant rejection"
}

check_ios_coverage() {
  local ios="$ROOT_DIR/fearless-iOS"
  local transfer_test="$ios/fearlessTests/ApplicationLayer/Services/FeatureToggle/TonChainSelectionTests.swift"
  local transfer="$ios/fearless/ApplicationLayer/Services/Transfer/Tokens/TransferService.swift"
  local torii_test="$ios/fearlessTests/IrohaToriiClientTests.swift"
  local routing_test="$ios/fearlessTests/UniversalWalletAccountAddressResolverTests.swift"

  log "Checking iOS Iroha/Nexus transfer coverage"
  require_file "$transfer_test" "iOS Iroha transfer routing test"
  require_file "$transfer" "iOS Iroha transfer service"
  require_file "$torii_test" "iOS Iroha Torii client test"
  require_file "$routing_test" "iOS Iroha address resolver test"

  require_literal "$transfer_test" "testPrepareDependenciesCreatesIrohaTransferServiceForTairaAccount" "iOS Taira transfer service routing test"
  require_literal "$transfer_test" "testPrepareDependenciesCreatesIrohaTransferServiceForNexusAccount" "iOS Nexus transfer service routing test"
  require_literal "$transfer_test" "testIrohaTransferServiceBuildsSignerRequestAndSubmitsNorito" "iOS Taira signed transfer submission test"
  require_literal "$transfer_test" "testIrohaTransferServiceBuildsNexusSignerRequestAndSubmitsNorito" "iOS Nexus signed transfer submission test"
  require_literal "$transfer_test" "testIrohaTransferServiceRejectsMnemonicMismatchBeforeSignerOrToriiCalls" "iOS Iroha mnemonic mismatch test"
  require_literal "$transfer_test" "XCTAssertEqual(signer.lastRequest?.network, \"nexus\")" "iOS Nexus signer network assertion"
  require_literal "$transfer_test" "testIrohaNexusWalletSmokeEvidenceThreadsExactImmutableMetadataToSigner" "iOS immutable Nexus wallet-smoke metadata test"
  require_literal "$transfer_test" "testIrohaWalletSmokeMetadataSnapshotDoesNotAliasInputOrReturnedValues" "iOS wallet-smoke metadata anti-aliasing test"
  require_literal "$transfer_test" "testIrohaNexusWalletSmokeEvidenceRejectsMalformedMetadataBeforeSignerOrTorii" "iOS wallet-smoke adversarial rejection test"
  require_literal "$transfer_test" "testIrohaWalletSmokeEvidenceRejectsTairaAndNoncanonicalNexusBeforeSignerOrTorii" "iOS wallet-smoke route rejection test"
  require_literal "$transfer_test" "testIrohaWalletSmokeEvidenceRemainsFailClosedWithUnavailableSigner" "iOS wallet-smoke unavailable-signer fail-closed test"
  require_literal "$transfer" "IrohaWalletSmokeTransactionMetadata" "iOS typed wallet-smoke metadata contract"
  require_literal "$transfer" "submitNexusWalletSmokeEvidence" "iOS operator-only Nexus wallet-smoke entry point"
  require_literal "$torii_test" "testUsesMinamotoForNexusByDefaultAndAllowsRuntimeOverride" "iOS Nexus Torii routing test"
  require_literal "$torii_test" "testRejectsWrongNetworkIrohaAccountIDsBeforeFetch" "iOS wrong-network Iroha account rejection"
  require_literal "$routing_test" "testResolvesNexusI105AddressFromSamePublicKeyWithNexusDiscriminant" "iOS Nexus address derivation test"
}

check_web_coverage
check_android_coverage
check_ios_coverage

production_send_audit="$ROOT_DIR/scripts/audit-iroha-production-send-readiness.sh"
production_send_test="$ROOT_DIR/scripts/test-iroha-production-send-readiness-audit.sh"
require_executable_file "$production_send_audit" "aggregate Iroha production-send blocked-readiness audit"
require_executable_file "$production_send_test" "aggregate Iroha production-send adversarial self-test"
if [[ -x "$production_send_test" ]]; then
  IROHA_SEND_AGGREGATE_ROOT="$ROOT_DIR" bash "$production_send_test" ||
    record_failure "aggregate Iroha production-send adversarial self-test failed"
fi
if [[ -x "$production_send_audit" ]]; then
  IROHA_SEND_AGGREGATE_ROOT="$ROOT_DIR" bash "$production_send_audit" ||
    record_failure "aggregate Iroha production-send blocked-readiness audit failed"
fi

if ((${#failures[@]} > 0)); then
  echo "[iroha-wallet-coverage][error] Iroha/Nexus wallet coverage audit failed:" >&2
  printf '  - %s\n' "${failures[@]}" >&2
  exit 1
fi

log "Iroha/Nexus wallet coverage audit passed."
