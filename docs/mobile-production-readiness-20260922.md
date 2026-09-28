# Android and iOS production readiness — 22 September 2026

**Recommendation: hold broad production release.** Legacy-wallet preservation and the September UX work have substantial recorded qualification, and iOS 4.2.0 (2026.9.6) reached internal TestFlight. Remaining work includes a failing Android transfer-safety gate, Android store compatibility, reconciling divergent release sources, store-signed upgrade acceptance, and production service failures. Passkey backup and new Iroha sends still require implementation/integration and operational evidence before enablement.

This is a readiness assessment of the current working trees, release configuration, selected executable gates, GitHub PR state, and read-only live endpoints. It is not an exhaustive penetration test or a fresh full mobile build. No deployments, store uploads, funded transactions, secret rotation, or application-source changes were performed. The security-best-practices skill supplied the report workflow; its framework references do not cover native Kotlin/Swift or this plain Node HTTP service.

## Completed work to preserve

- September legacy-upgrade qualification records Android 117 JVM/device passes, iOS 526 unique app cases plus 41 SDK cases. Preserve existing keys, identities, signing/export and legacy native TON functionality; the earlier mandatory replacement/export-only migration policy is superseded. [Upgrade authority](/Users/takemiyamakoto/dev/fearless/LEGACY-UPGRADE-GOALS.md:3).
- The September UX and accessibility acceptance is complete, including user-confirmed physical VoiceOver acceptance. It should not be reopened as an uncompleted generic checklist item. [Acceptance](/Users/takemiyamakoto/dev/fearless/UX-MANUAL-ACCEPTANCE.md:5).
- iOS release source `645c15373bef2c9e384abf4f28deaef34007e7bf` was accepted into internal TestFlight on September 6, according to the publication record. The recorded signed archive passed identity, entitlements, Keychain, storage, service-config and symbol audits. This session did not re-query App Store Connect. [Publication](/Users/takemiyamakoto/dev/fearless/fearless-iOS-testflight-4.2.0-2026.9.6/docs/testflight-4.2.0-2026.9.6.md:102).

## High priority — required before broad rollout

### 1. Reconcile Android XCM enablement with the reviewed safety contract

**Verified blocker.** The current release build sets `ENABLE_PRODUCTION_XCM_TRANSFERS=true`, but production evidence is still blocked and empty. The effective-registry audit fails because the reviewed release policy requires a compiled false. The require-ready evidence audit also fails, including missing independently verified evidence for all 15 required routes.

There is a runtime submission guard; this is not evidence of unrestricted sending. However, that guard now consumes persisted remote booleans, and a fetch failure retains previously enabled values. Review authority, freshness, failure and rollback behavior alongside the release policy. Keep the reviewed compiled disable, or complete an explicit review of the replacement control and route evidence before shipping enablement; do not merely weaken the audit.

Evidence: [Release flag](/Users/takemiyamakoto/dev/fearless/fearless-Android-production-consolidated-20260731/feature-wallet-impl/build.gradle:41), [blocked evidence](/Users/takemiyamakoto/dev/fearless/fearless-Android-production-consolidated-20260731/scripts/xcm-production-evidence.json:4), [persistent flags](/Users/takemiyamakoto/dev/fearless/fearless-Android-production-consolidated-20260731/common/src/main/java/jp/co/soramitsu/common/data/network/config/ProductFeatureToggleStore.kt:20), [fetch-failure behavior](/Users/takemiyamakoto/dev/fearless/fearless-Android-production-consolidated-20260731/feature-account-api/src/main/java/jp/co/soramitsu/account/api/domain/PendulumPreInstalledAccountsScenario.kt:61).

### 2. Establish one reviewed, reproducible release source per platform

**Verified blocker.** The authoritative working checkouts include substantial uncommitted September changes. Android's consolidation PR [#1260](https://github.com/soramitsu/fearless-Android/pull/1260) and iOS [#1303](https://github.com/soramitsu/fearless-iOS/pull/1303) are both open and `REVIEW_REQUIRED` as checked today. Their current heads differ from the reviewed hashes in the root release configuration. An approved old commit cannot qualify later working-tree changes.

The root runner still addresses `fearless-Android` and `fearless-iOS`, whereas the latest upgrade authority names the consolidated checkouts. Root ownership configuration is still null/blocked even though `soramitsu/fearless-release-readiness` now exists with default branch `main`. Update the source inventory, ownership record, reviewed pins and release tooling together, then merge through protected branches and qualify exact immutable commits and artifact hashes.

There is additional iOS drift: the consolidated checkout's TON audit currently fails with `reviewed TonAPI send-origin allowlist drifted`, while the September TestFlight checkout passes its blocked-state contract, including the legacy native-account exception. Port/reconcile the reviewed source and corresponding audit rather than disabling restored legacy signing. Both September iOS checkouts also lack the `--require-ready` option the root runner expects for the shared-features gate. The supported diagnostic command passes and reports 11 carried dependency deltas; upstream/vendor those deltas or formally retain and verify them under the agreed release contract.

Evidence: [Working checkout authority](/Users/takemiyamakoto/dev/fearless/LEGACY-UPGRADE-GOALS.md:25), [root runner paths and strict command](/Users/takemiyamakoto/dev/fearless/scripts/audit-release-readiness.sh:2253), [PR pins](/Users/takemiyamakoto/dev/fearless/config/release-readiness-prs.tsv:18), [ownership record](/Users/takemiyamakoto/dev/fearless/config/source-publication-root-owner.json:3), [TON gate](/Users/takemiyamakoto/dev/fearless/fearless-iOS-production-consolidated-20260731/scripts/audit-ton-production-send-readiness.sh:486).

### 3. Prove real distribution-signed upgrades without losing wallet access

**Explicitly outstanding acceptance gate.** Upgrade historical App Store/Play installations in place, using sanitized/unfunded test wallets and the actual distribution identities. Verify preserved addresses, keys, balances/history, PIN/biometric access, export, signing readiness, optional network enrollment, interruption/retry and repeat cold launches. Include legacy native TON/Jetton/TonConnect on iOS and historical Android Ethereum storage transitions. Do not uninstall or reset to make an upgrade pass.

Android's final-source matrix calls for API 30, 31 and 36. Internal App Sharing cannot establish an in-place upgrade from the Play-signed production app; use the appropriate Play testing track. For iOS, TestFlight upload and a freshly installed development-signed phone check do not establish the historical-install upgrade gate. Requalify the final merged source, not a mixture of older tested artifacts.

Evidence: [Android final acceptance](/Users/takemiyamakoto/dev/fearless/fearless-Android-production-consolidated-20260731/docs/legacy-upgrade-audit-20260906.md:127), [iOS outstanding acceptance](/Users/takemiyamakoto/dev/fearless/fearless-iOS-testflight-4.2.0-2026.9.6/docs/testflight-4.2.0-2026.9.6.md:114).

### 4. Repair and qualify the production service dependencies

Read-only checks from this machine on September 22 found:

| Endpoint | Observed result | Required follow-up |
| --- | --- | --- |
| `ti.soramitsu.io/api/indexer/v1/service-info` and `/health` | HTTP 200, but `chainId=ton:testnet`, `network=testnet`; health lag 6,285 seconds | Route/deploy the intended fresh mainnet service and pass the strict identity/freshness smoke. |
| `si.soramitsu.io/api/indexer/v1/service-info` | TLS validation failed because the certificate is expired | Renew/fix certificate delivery, then verify mainnet identity and all required API contracts. |
| `pi.soramitsu.io/graphql` | The current mobile-capability query rejects all five requested capability fields | Deploy/align the reviewed mobile contract, then run the complete cryptographic health/state and capability smoke. |
| `backup.fearlesswallet.io` | DNS resolution failed | Deploy/provision DNS, TLS, service and authorization before passkey enablement. |
| `taira.sora.org/status` | HTTP 502 | Restore service and pass the pinned full live contract, including identity, progress, fanout, precision and DNS. |
| `minamoto.sora.org/status` | Timed out | Establish reachable, independently pinned mainnet identity and complete route/canary evidence before Nexus enablement. |

These are point-in-time observations, not claims about outage duration. The PI result establishes schema mismatch, not a full assessment of its other fields. TI/SI/PI deployment-evidence manifests remain blocked. Record reviewed image digest, source commit, deployment identity, operator, fresh smokes and rollback procedure for enabled dependencies. Do not bypass TLS or identity failures.

Contract evidence: [TI expected mainnet identity](/Users/takemiyamakoto/dev/ton-indexer/src/scripts/production-smoke.ts:52), [PI query](/Users/takemiyamakoto/dev/polkaswap-indexer/src/scripts/production-smoke.ts:98), [missing Taira/Nexus pins](/Users/takemiyamakoto/dev/fearless/config/iroha-release-readiness.env:11).

### 5. Complete signing trust and credential-revocation evidence

Android's checked-in release-tag signer fingerprint is still the literal unconfigured sentinel. Configure the reviewed fingerprint and matching public-key repository variable. Verify the protected build/signing environments, independent reviewers, actual Play signing identity, upload-key custody and unused version code across all tracks. External environment/console settings were not inspected; their absence is not established.

The Android checklist also requires provider-side revocation/rotation of the MoonPay signing secret formerly embedded in released artifacts. Today's source-policy audit passes, but removal from current source does not prove revocation. Obtain that confirmation before production.

Evidence: [Signer trust anchor](/Users/takemiyamakoto/dev/fearless/fearless-Android-production-consolidated-20260731/.github/release/android-tag-signer-fingerprints.txt:3), [revocation and version requirements](/Users/takemiyamakoto/dev/fearless/fearless-Android-production-consolidated-20260731/docs/release-checklist.md:13).

## Medium priority — store compatibility and release operations

### 6. Target API 36 and requalify final native artifacts

Android compiles against API 36 but still targets 35. New Play submissions/updates require target API 36 from August 31, 2026, subject to any actual granted extension. Update target behavior and rerun the device matrix, final AAB signing checks and 16 KiB native-library compatibility checks. Compilation against 36 alone is insufficient. [Source](/Users/takemiyamakoto/dev/fearless/fearless-Android-production-consolidated-20260731/build.gradle:37), [Google's current requirement](https://support.google.com/googleplay/android-developer/answer/11926878?hl=en).

For the final iOS archive, retain production bundle/team/Keychain identity, historical storage models, audited entitlements/configuration and dSYM checks; build with the currently accepted SDK. Apple requires Xcode 26 and iOS 26 SDK or later for uploads since April 28, 2026. The recorded September upload was accepted; old developer instructions mentioning Xcode 15 are not current upload authority. [Apple requirement](https://developer.apple.com/news/upcoming-requirements/?id=04282026a).

Complete final privacy/store declarations, release notes, review status and crash/prelaunch checks against the actual enabled features. Use staged rollout with named monitoring and rollback owners. Console completion was not verified in this review. BNB history enablement and replacement Kaia/X Layer history access are recorded service follow-ups; explicit retry/explorer recovery already exists, so these are not automatically wallet-startup blockers. [iOS service follow-ups](/Users/takemiyamakoto/dev/fearless/LEGACY-UPGRADE-GOALS.md:39).

## Conditional blockers — before enabling these capabilities

### 7. Passkey backup requires key recovery and authorization integration as well as deployment

Flags remain off. iOS still exposes unavailable default implementations for the cross-device recoverable key and one-time authorization grants. Provision/review the actual wallet-owned recovery-key design and stable cross-platform ownership authorization, then validate backup/restore/revocation across devices and failure/retry paths. A device-local key does not satisfy recovery.

Deploy the attested challenge-service image with durable storage, restricted proxy access, atomic one-use authorization and reviewed rollback. Publish correct website associations; today's live verifier fails because Android `get_login_creds` and Apple `webcredentials` are absent, bodies differ from source, and required content headers are missing. Independently bind the Android origin to the actual Play-distributed signing certificate; complete Google Drive and CloudKit production provisioning. Require fresh complete deployment evidence before changing release flags.

Evidence: [Recovery-key boundary](/Users/takemiyamakoto/dev/fearless/fearless-iOS-production-consolidated-20260731/fearless/Common/Model/PasskeyBackupContract.swift:92), [authorization boundary](/Users/takemiyamakoto/dev/fearless/fearless-iOS-production-consolidated-20260731/fearless/Common/Model/PasskeyBackupContract.swift:830), [blocked deployment](/Users/takemiyamakoto/dev/fearless/services/passkey-backup-challenge-service/scripts/production-deployment-evidence.json:15).

### 8. New Iroha/Nexus and general iOS TON sends require their own release evidence

Android and iOS Iroha audits pass their blocked-state invariants; they do not certify working production signing. Finish reviewed SDK/codec integration, source-to-binary provenance, transaction/hash/receipt parity, authoritative fee/asset mapping, minimal secret lifetime and device qualification, followed by explicitly authorized funded evidence against the exact deployed network. The iOS manifest still records unresolved package compilation/resolution, binary-hash and provenance issues. [iOS exit criteria](/Users/takemiyamakoto/dev/fearless/fearless-iOS-production-consolidated-20260731/config/iroha-production-send-readiness.json:110).

General iOS TON-send enablement remains blocked pending exact fee parity, credential/origin provisioning, funded mainnet proof and expired-pending-intent recovery policy. Preserve the separately reviewed legacy native-account exception already shipped to TestFlight. [General TON gates](/Users/takemiyamakoto/dev/fearless/fearless-iOS-production-consolidated-20260731/docs/ton-production-send-readiness.md:9).

A narrower mobile release could retain unavailable capabilities behind reviewed fail-closed controls, with accurate UX and store claims. That would require an explicit release-scope and gate update: the current full-program readiness contract still includes those capabilities and web/backend prerequisites. A skipped gate is not evidence of production completion.

## Verification performed and final sequence

Fresh checks: Android XCM effective-registry and require-ready evidence **failed**; Android MoonPay source policy and Iroha blocked-state audit **passed**. Consolidated iOS TON guard **failed**; September TestFlight TON guard and consolidated Iroha blocked-state audit **passed**. iOS dependency diagnostic **passed**, with 11 carried deltas and removal readiness still blocked. Passkey service **92/92 tests passed**, and the production npm dependency audit returned **zero known advisories**. Live app-association verifier **failed**. GitHub PR and endpoint observations are described above.

Do the remaining work in this order: reconcile the final source and scope; correct the failing safety/API/signing gates; repair the services needed by enabled features; obtain protected reviews and build exact artifacts; prove store-signed upgrades; complete console review and staged rollout preparation; rerun the reconciled full-live release audit and retain its source/artifact-bound evidence. The last retained aggregate summary is from July 31 and cannot certify September source. No full aggregate audit, fresh mobile build, store-console inspection or funded canary was performed in this assessment.
