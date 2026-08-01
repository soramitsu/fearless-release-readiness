#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
AUDIT_SCRIPT="$SCRIPT_DIR/audit-iroha-wallet-coverage.sh"

fail() {
  echo "[iroha-wallet-coverage-test][error] $*" >&2
  exit 1
}

tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

workspace="$tmp_dir/fearless"

write_file() {
  local file="$1"
  shift
  mkdir -p "$(dirname "$file")"
  printf '%s\n' "$@" > "$file"
}

write_fixture() {
  rm -rf "$workspace"

  write_file "$workspace/scripts/audit-iroha-production-send-readiness.sh" \
    "#!/usr/bin/env bash" \
    "exit 0"
  write_file "$workspace/scripts/test-iroha-production-send-readiness-audit.sh" \
    "#!/usr/bin/env bash" \
    "exit 0"
  chmod +x "$workspace/scripts/audit-iroha-production-send-readiness.sh" \
    "$workspace/scripts/test-iroha-production-send-readiness-audit.sh"

  write_file "$workspace/fearless-wallet-web/tests/unit/iroha-background-transfer.spec.ts" \
    "it('builds and signs with an injected Nexus browser SDK transaction codec', () => {})" \
    "it('rejects Nexus SDK signing when the stored mnemonic does not match the account public key', () => {})" \
    "it('rejects incomplete or malformed Nexus SDK transaction codec outputs', () => {})" \
    "it('fails closed while Iroha transfers are not release-enabled', () => {})" \
    "it('forwards only a snapshotted exact web wallet-smoke metadata object on Nexus', () => {})" \
    "it('rejects malformed and adversarial wallet-smoke metadata before signing', () => {})" \
    "it('submits an operator-only Nexus wallet smoke with exact bound metadata', () => {})" \
    "it('rejects unsafe wallet-smoke requests before codec or Torii access', () => {})"
  write_file "$workspace/fearless-wallet-web/src/extension/background/extension-base/src/api/iroha/nexusSdkTransferCodec.ts" \
    "finalizeSignedTransaction" \
    "iroha_signing_key_mismatch" \
    "invalid_iroha_signed_transaction_hash" \
    "normalizeIrohaWalletSmokeMetadata" \
    "iroha_wallet_smoke_requires_nexus"
  write_file "$workspace/fearless-wallet-web/src/extension/background/extension-base/src/api/iroha/transfer.ts" \
    "makeIrohaWalletSmokeTransfer"
  write_file "$workspace/fearless-wallet-web/scripts/solana-extension-smoke.mjs" \
    "Expected fail-closed Iroha signing rejection" \
    "startIrohaConnect(cdp, dappSession, 'nexus')"
  write_file "$workspace/fearless-wallet-web/scripts/test-public-artifacts-audit.sh" \
    "transfer enablement with pinned old package still blocked without reviewed codec artifact" \
    "browser_transaction_codec_unpublished_source_only"

  write_file "$workspace/fearless-Android/feature-wallet-impl/src/test/java/jp/co/soramitsu/wallet/impl/data/repository/tranfser/BitcoinTransferServiceProviderTest.kt" \
    "provider routes iroha chains to fail closed iroha transfer service" \
    "iroha transfer builds signed transfer request and submits norito to torii" \
    "iroha transfer builds nexus signed transfer request and submits norito to minamoto torii" \
    "iroha transfer rejects mnemonic mismatch before signer or torii calls" \
    "assertEquals(\"nexus\", signer.lastRequest?.network)" \
    "nexus wallet smoke evidence uses exact immutable metadata and canonical minamoto" \
    "wallet smoke evidence rejects taira and noncanonical minamoto before signer or torii" \
    "wallet smoke evidence rejects malformed and aliasing metadata before signer or torii"
  write_file "$workspace/fearless-Android/feature-wallet-impl/src/test/java/jp/co/soramitsu/wallet/impl/data/repository/tranfser/IrohaTransferMetadataTest.kt" \
    "wallet smoke factory emits exact canonical all-string contract" \
    "explicit wallet smoke path preserves ordinary empty metadata and fail closed signer selection" \
    "rejects malformed wallet smoke metadata before signer or torii calls" \
    "metadata snapshots mutable input and returns immutable defensive copies" \
    "wallet smoke metadata is rejected outside exact Nexus global context"
  write_file "$workspace/fearless-Android/feature-wallet-impl/src/main/java/jp/co/soramitsu/wallet/impl/data/repository/tranfser/IrohaTransferMetadata.kt" \
    "requireNexusWalletSmokeContext"
  write_file "$workspace/fearless-Android/feature-wallet-impl/src/main/java/jp/co/soramitsu/wallet/impl/data/repository/tranfser/TransferService.kt" \
    "transferWalletSmokeEvidence"
  write_file "$workspace/fearless-Android/iroha-sdk-bridge/src/main/java/jp/co/soramitsu/iroha/bridge/IrohaTransferBridge.java" \
    "wallet-smoke transaction metadata is Nexus-only; staged Taira bridge requires empty metadata"
  write_file "$workspace/fearless-Android/iroha-sdk-bridge/src/test/java/jp/co/soramitsu/iroha/bridge/IrohaTransferBridgeTest.java" \
    "rejectsCanonicalNexusWalletSmokeMetadataBeforeClockOrSigning" \
    "transactionMetadataIsDefensivelyCopiedAndImmutable"
  write_file "$workspace/fearless-Android/common/src/test/java/jp/co/soramitsu/common/wallet/IrohaToriiClientTest.kt" \
    "routes nexus through registry torii url while allowing runtime override" \
    "rejects wrong-network iroha account ids before fetch"
  write_file "$workspace/fearless-Android/feature-wallet-impl/src/test/java/jp/co/soramitsu/wallet/impl/data/repository/UniversalWalletIrohaRoutingTest.kt" \
    "meta account derives nexus address from the same public key with nexus discriminant" \
    "iroha address normalization rejects wrong network discriminant"

  write_file "$workspace/fearless-iOS/fearlessTests/ApplicationLayer/Services/FeatureToggle/TonChainSelectionTests.swift" \
    "testPrepareDependenciesCreatesIrohaTransferServiceForTairaAccount" \
    "testPrepareDependenciesCreatesIrohaTransferServiceForNexusAccount" \
    "testIrohaTransferServiceBuildsSignerRequestAndSubmitsNorito" \
    "testIrohaTransferServiceBuildsNexusSignerRequestAndSubmitsNorito" \
    "testIrohaTransferServiceRejectsMnemonicMismatchBeforeSignerOrToriiCalls" \
    "XCTAssertEqual(signer.lastRequest?.network, \"nexus\")" \
    "testIrohaNexusWalletSmokeEvidenceThreadsExactImmutableMetadataToSigner" \
    "testIrohaWalletSmokeMetadataSnapshotDoesNotAliasInputOrReturnedValues" \
    "testIrohaNexusWalletSmokeEvidenceRejectsMalformedMetadataBeforeSignerOrTorii" \
    "testIrohaWalletSmokeEvidenceRejectsTairaAndNoncanonicalNexusBeforeSignerOrTorii" \
    "testIrohaWalletSmokeEvidenceRemainsFailClosedWithUnavailableSigner"
  write_file "$workspace/fearless-iOS/fearless/ApplicationLayer/Services/Transfer/Tokens/TransferService.swift" \
    "IrohaWalletSmokeTransactionMetadata" \
    "submitNexusWalletSmokeEvidence"
  write_file "$workspace/fearless-iOS/fearlessTests/IrohaToriiClientTests.swift" \
    "testUsesMinamotoForNexusByDefaultAndAllowsRuntimeOverride" \
    "testRejectsWrongNetworkIrohaAccountIDsBeforeFetch"
  write_file "$workspace/fearless-iOS/fearlessTests/UniversalWalletAccountAddressResolverTests.swift" \
    "testResolvesNexusI105AddressFromSamePublicKeyWithNexusDiscriminant"
}

run_audit() {
  IROHA_WALLET_COVERAGE_ROOT="$workspace" bash "$AUDIT_SCRIPT"
}

expect_success() {
  local name="$1"
  local output
  if ! output="$(run_audit 2>&1)"; then
    echo "$output" >&2
    fail "$name unexpectedly failed"
  fi
}

expect_failure() {
  local name="$1"
  local expected="$2"
  local output
  set +e
  output="$(run_audit 2>&1)"
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

write_fixture
expect_success "complete fixture"

write_fixture
perl -0pi -e 's/builds and signs with an injected Nexus browser SDK transaction codec/builds and signs with an injected SDK transaction codec/' \
  "$workspace/fearless-wallet-web/tests/unit/iroha-background-transfer.spec.ts"
expect_failure "missing web Nexus SDK transfer test" "web Nexus SDK positive transfer test"

write_fixture
perl -0pi -e 's/iroha transfer builds nexus signed transfer request and submits norito to minamoto torii/iroha transfer builds signed transfer request and submits norito/' \
  "$workspace/fearless-Android/feature-wallet-impl/src/test/java/jp/co/soramitsu/wallet/impl/data/repository/tranfser/BitcoinTransferServiceProviderTest.kt"
expect_failure "missing Android Nexus transfer test" "Android Nexus signed transfer submission test"

write_fixture
perl -0pi -e 's/testIrohaTransferServiceBuildsNexusSignerRequestAndSubmitsNorito/testIrohaTransferServiceBuildsSignerRequestAndSubmitsNoritoAgain/' \
  "$workspace/fearless-iOS/fearlessTests/ApplicationLayer/Services/FeatureToggle/TonChainSelectionTests.swift"
expect_failure "missing iOS Nexus transfer test" "iOS Nexus signed transfer submission test"

write_fixture
perl -0pi -e 's/Expected fail-closed Iroha signing rejection/Expected Iroha signing rejection/' \
  "$workspace/fearless-wallet-web/scripts/solana-extension-smoke.mjs"
expect_failure "missing web fail-closed signing smoke" "web browser Iroha signing fail-closed smoke"

write_fixture
perl -0pi -e 's/transfer enablement with pinned old package still blocked without reviewed codec artifact/transfer enablement with pinned old package/' \
  "$workspace/fearless-wallet-web/scripts/test-public-artifacts-audit.sh"
expect_failure "missing web reviewed-codec blocker test" "web Iroha reviewed-codec release blocker test"

write_fixture
perl -0pi -e 's/browser_transaction_codec_unpublished_source_only/browser_transaction_codec_absent/' \
  "$workspace/fearless-wallet-web/scripts/test-public-artifacts-audit.sh"
expect_failure "stale web browser codec absence diagnostic" "web Iroha unpublished-source blocker diagnostic test"

write_fixture
perl -0pi -e 's/forwards only a snapshotted exact web wallet-smoke metadata object on Nexus/forwards wallet metadata/' \
  "$workspace/fearless-wallet-web/tests/unit/iroha-background-transfer.spec.ts"
expect_failure "missing web immutable wallet-smoke proof" "web immutable Nexus wallet-smoke metadata test"

write_fixture
perl -0pi -e 's/rejects malformed and adversarial wallet-smoke metadata before signing/rejects malformed metadata/' \
  "$workspace/fearless-wallet-web/tests/unit/iroha-background-transfer.spec.ts"
expect_failure "missing web adversarial wallet-smoke proof" "web wallet-smoke adversarial rejection test"

write_fixture
perl -0pi -e 's/submits an operator-only Nexus wallet smoke with exact bound metadata/submits a wallet smoke/' \
  "$workspace/fearless-wallet-web/tests/unit/iroha-background-transfer.spec.ts"
expect_failure "missing web operator-only wallet-smoke proof" "web operator-only Nexus wallet-smoke test"

write_fixture
perl -0pi -e 's/rejects unsafe wallet-smoke requests before codec or Torii access/rejects unsafe wallet-smoke requests/' \
  "$workspace/fearless-wallet-web/tests/unit/iroha-background-transfer.spec.ts"
expect_failure "missing web pre-signer route proof" "web pre-signer wallet-smoke route rejection test"

write_fixture
perl -0pi -e 's/normalizeIrohaWalletSmokeMetadata/normalizeWalletMetadata/' \
  "$workspace/fearless-wallet-web/src/extension/background/extension-base/src/api/iroha/nexusSdkTransferCodec.ts"
expect_failure "missing web exact metadata codec guard" "web exact wallet-smoke metadata codec guard"

write_fixture
perl -0pi -e 's/iroha_wallet_smoke_requires_nexus/iroha_wallet_smoke_wrong_network/' \
  "$workspace/fearless-wallet-web/src/extension/background/extension-base/src/api/iroha/nexusSdkTransferCodec.ts"
expect_failure "missing web Nexus-only codec guard" "web wallet-smoke Nexus-only codec guard"

write_fixture
perl -0pi -e 's/makeIrohaWalletSmokeTransfer/makeIrohaTransfer/' \
  "$workspace/fearless-wallet-web/src/extension/background/extension-base/src/api/iroha/transfer.ts"
expect_failure "missing web operator-only entry point" "web operator-only wallet-smoke entry point"

write_fixture
perl -0pi -e 's/nexus wallet smoke evidence uses exact immutable metadata and canonical minamoto/nexus wallet smoke evidence/' \
  "$workspace/fearless-Android/feature-wallet-impl/src/test/java/jp/co/soramitsu/wallet/impl/data/repository/tranfser/BitcoinTransferServiceProviderTest.kt"
expect_failure "missing Android immutable wallet-smoke proof" "Android immutable Nexus wallet-smoke metadata test"

write_fixture
perl -0pi -e 's/wallet smoke evidence rejects taira and noncanonical minamoto before signer or torii/wallet smoke evidence rejects wrong routes/' \
  "$workspace/fearless-Android/feature-wallet-impl/src/test/java/jp/co/soramitsu/wallet/impl/data/repository/tranfser/BitcoinTransferServiceProviderTest.kt"
expect_failure "missing Android route rejection proof" "Android wallet-smoke route rejection test"

write_fixture
perl -0pi -e 's/wallet smoke evidence rejects malformed and aliasing metadata before signer or torii/wallet smoke evidence rejects malformed metadata/' \
  "$workspace/fearless-Android/feature-wallet-impl/src/test/java/jp/co/soramitsu/wallet/impl/data/repository/tranfser/BitcoinTransferServiceProviderTest.kt"
expect_failure "missing Android adversarial metadata proof" "Android wallet-smoke adversarial rejection test"

write_fixture
perl -0pi -e 's/wallet smoke factory emits exact canonical all-string contract/wallet smoke factory emits metadata/' \
  "$workspace/fearless-Android/feature-wallet-impl/src/test/java/jp/co/soramitsu/wallet/impl/data/repository/tranfser/IrohaTransferMetadataTest.kt"
expect_failure "missing Android exact metadata contract proof" "Android exact wallet-smoke metadata contract test"

write_fixture
perl -0pi -e 's/explicit wallet smoke path preserves ordinary empty metadata and fail closed signer selection/explicit wallet smoke path/' \
  "$workspace/fearless-Android/feature-wallet-impl/src/test/java/jp/co/soramitsu/wallet/impl/data/repository/tranfser/IrohaTransferMetadataTest.kt"
expect_failure "missing Android unavailable-signer proof" "Android wallet-smoke unavailable-signer fail-closed test"

write_fixture
perl -0pi -e 's/rejects malformed wallet smoke metadata before signer or torii calls/rejects malformed wallet smoke metadata/' \
  "$workspace/fearless-Android/feature-wallet-impl/src/test/java/jp/co/soramitsu/wallet/impl/data/repository/tranfser/IrohaTransferMetadataTest.kt"
expect_failure "missing Android pre-signer malformed proof" "Android pre-signer malformed metadata test"

write_fixture
perl -0pi -e 's/metadata snapshots mutable input and returns immutable defensive copies/metadata accepts mutable input/' \
  "$workspace/fearless-Android/feature-wallet-impl/src/test/java/jp/co/soramitsu/wallet/impl/data/repository/tranfser/IrohaTransferMetadataTest.kt"
expect_failure "missing Android anti-aliasing proof" "Android wallet-smoke metadata anti-aliasing test"

write_fixture
perl -0pi -e 's/wallet smoke metadata is rejected outside exact Nexus global context/wallet smoke metadata is accepted/' \
  "$workspace/fearless-Android/feature-wallet-impl/src/test/java/jp/co/soramitsu/wallet/impl/data/repository/tranfser/IrohaTransferMetadataTest.kt"
expect_failure "missing Android exact Nexus context proof" "Android exact Nexus context test"

write_fixture
perl -0pi -e 's/requireNexusWalletSmokeContext/allowWalletSmokeContext/' \
  "$workspace/fearless-Android/feature-wallet-impl/src/main/java/jp/co/soramitsu/wallet/impl/data/repository/tranfser/IrohaTransferMetadata.kt"
expect_failure "missing Android Nexus construction guard" "Android wallet-smoke Nexus-only construction guard"

write_fixture
perl -0pi -e 's/transferWalletSmokeEvidence/transferEvidence/' \
  "$workspace/fearless-Android/feature-wallet-impl/src/main/java/jp/co/soramitsu/wallet/impl/data/repository/tranfser/TransferService.kt"
expect_failure "missing Android operator-only entry point" "Android operator-only Nexus wallet-smoke entry point"

write_fixture
perl -0pi -e 's/wallet-smoke transaction metadata is Nexus-only; staged Taira bridge requires empty metadata/wallet-smoke metadata accepted/' \
  "$workspace/fearless-Android/iroha-sdk-bridge/src/main/java/jp/co/soramitsu/iroha/bridge/IrohaTransferBridge.java"
expect_failure "missing Android Taira bridge metadata guard" "Android staged Taira bridge metadata rejection guard"

write_fixture
perl -0pi -e 's/rejectsCanonicalNexusWalletSmokeMetadataBeforeClockOrSigning/acceptsNexusWalletSmokeMetadata/' \
  "$workspace/fearless-Android/iroha-sdk-bridge/src/test/java/jp/co/soramitsu/iroha/bridge/IrohaTransferBridgeTest.java"
expect_failure "missing Android bridge pre-signer proof" "Android staged bridge pre-signer Nexus metadata rejection test"

write_fixture
perl -0pi -e 's/transactionMetadataIsDefensivelyCopiedAndImmutable/transactionMetadataIsMutable/' \
  "$workspace/fearless-Android/iroha-sdk-bridge/src/test/java/jp/co/soramitsu/iroha/bridge/IrohaTransferBridgeTest.java"
expect_failure "missing Android bridge immutability proof" "Android staged bridge metadata immutability test"

write_fixture
perl -0pi -e 's/testIrohaNexusWalletSmokeEvidenceThreadsExactImmutableMetadataToSigner/testIrohaWalletSmokeEvidence/' \
  "$workspace/fearless-iOS/fearlessTests/ApplicationLayer/Services/FeatureToggle/TonChainSelectionTests.swift"
expect_failure "missing iOS immutable wallet-smoke proof" "iOS immutable Nexus wallet-smoke metadata test"

write_fixture
perl -0pi -e 's/testIrohaWalletSmokeMetadataSnapshotDoesNotAliasInputOrReturnedValues/testIrohaWalletSmokeMetadataSnapshot/' \
  "$workspace/fearless-iOS/fearlessTests/ApplicationLayer/Services/FeatureToggle/TonChainSelectionTests.swift"
expect_failure "missing iOS anti-aliasing proof" "iOS wallet-smoke metadata anti-aliasing test"

write_fixture
perl -0pi -e 's/testIrohaNexusWalletSmokeEvidenceRejectsMalformedMetadataBeforeSignerOrTorii/testIrohaWalletSmokeEvidenceRejectsMalformedMetadata/' \
  "$workspace/fearless-iOS/fearlessTests/ApplicationLayer/Services/FeatureToggle/TonChainSelectionTests.swift"
expect_failure "missing iOS adversarial wallet-smoke proof" "iOS wallet-smoke adversarial rejection test"

write_fixture
perl -0pi -e 's/testIrohaWalletSmokeEvidenceRejectsTairaAndNoncanonicalNexusBeforeSignerOrTorii/testIrohaWalletSmokeEvidenceRejectsTaira/' \
  "$workspace/fearless-iOS/fearlessTests/ApplicationLayer/Services/FeatureToggle/TonChainSelectionTests.swift"
expect_failure "missing iOS route rejection proof" "iOS wallet-smoke route rejection test"

write_fixture
perl -0pi -e 's/testIrohaWalletSmokeEvidenceRemainsFailClosedWithUnavailableSigner/testIrohaWalletSmokeEvidenceUsesUnavailableSigner/' \
  "$workspace/fearless-iOS/fearlessTests/ApplicationLayer/Services/FeatureToggle/TonChainSelectionTests.swift"
expect_failure "missing iOS unavailable-signer proof" "iOS wallet-smoke unavailable-signer fail-closed test"

write_fixture
perl -0pi -e 's/IrohaWalletSmokeTransactionMetadata/IrohaTransactionMetadata/' \
  "$workspace/fearless-iOS/fearless/ApplicationLayer/Services/Transfer/Tokens/TransferService.swift"
expect_failure "missing iOS typed metadata contract" "iOS typed wallet-smoke metadata contract"

write_fixture
perl -0pi -e 's/submitNexusWalletSmokeEvidence/submitWalletSmoke/' \
  "$workspace/fearless-iOS/fearless/ApplicationLayer/Services/Transfer/Tokens/TransferService.swift"
expect_failure "missing iOS operator-only entry point" "iOS operator-only Nexus wallet-smoke entry point"

write_fixture
rm "$workspace/scripts/audit-iroha-production-send-readiness.sh"
expect_failure "missing aggregate Iroha production-send audit" "aggregate Iroha production-send blocked-readiness audit missing"

echo "[iroha-wallet-coverage-test] all tests passed"
