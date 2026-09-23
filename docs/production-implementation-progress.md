# Production implementation goals

Started 2026-09-22. The Codex goal is full implementation of the user-approved Android and iOS production-readiness plan. This document records progress; it does not certify readiness.

## Fixed release requirements

- Complete the full feature set; temporary disabled states are not completion.
- Preserve existing keys, identities, addresses, signing/export, native TON and the accepted UX. Never reset or uninstall to make upgrades pass.
- Support phrase-free iOS-to-Android and Android-to-iOS recovery with the original devices unavailable. Use Google Drive on both; iCloud is an optional extra copy.
- Keep recovery keys and plaintext wallet material entirely client-side. Use native qualified passkey PRF, HKDF-SHA256 and AES-GCM; retain existing envelope compatibility.
- Keep wallet OS minimums. New recovery is available only on qualified OS/provider combinations, initially native GPM with iOS 18+ and supported Android.
- Require genuine independent reviews, production-service proof, exact-artifact CI, distribution-signed upgrade acceptance and explicitly capped test-wallet canaries. Never fabricate these inputs or declare skipped/blocked-state checks release-ready.

## Subgoals

| ID | Goal | State | Completion evidence |
| --- | --- | --- | --- |
| G1 | Preserve source; reconcile final mobile candidates and dependency deltas; unify release manifest, identities and audit tooling | In progress | Verified capture; remaining integration, clean publication and reviewed exact-source CI |
| G2 | Android API 36/16 KiB, XCM discovery/execution separation, signed fresh authorization and every required route | In progress | Compile/device tests, adversarial submission tests, route-bound live receipts |
| G3 | Portable encrypted Drive backups, native PRF, stable owner/grant authority, safe generations and credential lifecycle | In progress | Native cross-platform replacement-device recovery, secret-leak and failure/revocation tests |
| G4 | Reviewed source-matched Iroha SDKs and application-owned signing; complete general TON production-send qualification | In progress | SDK provenance/parity, device/R8 tests, exact finality/fee/recipient receipts |
| G5 | Production indexers, passkey services, associations, OAuth/attestation, signing trust and historical-secret revocation | Pending | Authenticated deployment/provisioning records and strict fresh live smokes |
| G6 | Independently reviewed exact releases, store-signed upgrades, full-live audit and staged rollout | Pending | Final Play/Apple artifact identities, acceptance evidence, full-live pass and rollout monitoring |

## Current checkpoint

The program remains incomplete. Android's latest scoped backup run passes 205 JVM tests; its preceding journal head passed two API 36 emulator filesystem cases. iOS's latest Drive coordinator passes 49 selected Release simulator tests, while an earlier broader key/sign/send candidate passed **463 Release integration tests**, zero failures/skips. These are development checks at different source heads. Both app source trees are committed and pushed on review branches, but exact-head hosted checks for the newest increments, independent security review, protected qualification and distribution acceptance remain outstanding.

The owner/grant authority core and its optional existing-owner WebAuthn verifier pass 52 tests on each of two Node runtimes; first-owner bootstrap, legacy credential transactions, deployment and native Drive/PRF recovery remain unintegrated. Iroha source/build inventory has identified concrete packaging/CI fixes and protocol migration requirements. The complete frozen route inventory/unified manifest, transaction-byte/fee/hash/receipt qualification, general TON sends, production-service repairs and store/device acceptance remain open. No local or CI result substitutes for independent review, replacement-device recovery or capped funded evidence.

## Source preservation

Before implementation, 16 root/mobile/dependency/backend source trees were captured privately at:

`build/reports/production-source-capture-20260922T065539Z`

The capture contains HEAD/tree identities, binary working/staged patches, NUL-delimited status, and archives of nonignored untracked files. Existing legacy/UX authority documents are separately archived. All 80 repository artifacts verified against their recorded SHA-256 digests.

Capture manifest SHA-256: `a24255625148735c0b2ad5c365412dcd43e677379ad28e472fc0f548abc415f4`.

Raw captures stay private and ignored. They are rollback inputs, not published source or release qualification. Existing generated/device evidence is preserved in place; no prior test result qualifies newly changed code.

## Implementation order and ownership

1. Root agent: candidate/audit reconciliation, shared release identity, iOS and portable-recovery integration. Android agent: API 36 and XCM discovery/execution safety first, then signed authorization and tests.
2. Build the new owner/grant authority and native recovery workflow; qualify exact shared vectors before enabling recovery.
3. Complete SDK, TON and XCM evidence requirements, while repairing and qualifying production dependencies.
4. Publish protected reviewed candidates; qualify exact store-delivered upgrades and recovery; run full-live audit; stage rollout.

New-feature mutation authorization must require compiled approval, signed current-process configuration and approved route identity. Maximum authorization lifetime is 15 minutes, with five-minute refresh. Check before signing and final broadcast. Failure must preserve legacy access and read-only destinations.

Portable recovery must use immutable verified backup generations, per-credential key wrappers, exact-body single-use grants and separate discoverable authentication. Cloud account identity cannot take over an existing wallet owner. PRF output must never be part of serialized credential requests.

## Outstanding external evidence

Access and evidence are checked during implementation, not assumed absent: independent reviewers; current signing trust and protected environments; Google/Apple provisioning; production DNS/TLS/deployment access; physical-device and store-track access; MoonPay revocation confirmation. Funded canaries require dedicated test accounts and separately specified caps before submission. Missing inputs remain explicit blockers while independent code work continues.

## Current implementation evidence — 2026-09-22

- Reconciled the iOS TON production-send audit and checklist against published September source `645c15373bef2c9e384abf4f28deaef34007e7bf`. The blocked-contract audit and all 84 adversarial fixtures pass. These checks preserve the legacy TON exception; they do not qualify general production sends.
- Reconciled the stricter iOS dependency-delta audit and fixed its Bash 3.2 empty-array failure. Its adversarial suite passes. This initial legacy report was superseded by the pinned-source integration recorded below; release review and final distribution qualification remain open.
- Reconciled iOS safe service-configuration generation, built-product-only Google identity injection and archive configuration continuity checks from that exact September source. All 10 generation tests, 33 configuration/injection tests and the archive signing contract plus 10 override mutations pass. Production build numbering is unchanged pending allocation of a new unused candidate version.
- Reconciled September EVM node selection, provider credential host boundaries and Substrate reconnect/recovery behavior together with their tests. Fresh Release compilation exposed ambiguous optional inference in Iroha history pagination; explicit cursor types and missing/malformed/negative cursor tests are added. The fresh Release run passes all 46 selected network/history tests with no failures or skips. This run uses a newly created simulator and separate build outputs; historical upgrade/device evidence remains separate.
- Android implementation has moved to target API 36 while retaining its minimum OS version. Compiled production XCM submission is disabled during qualification, while immutable route loading and fee quotation remain available. The fee quotation path no longer accesses signing keys; it encodes an invalid placeholder signature of the correct variant and width for fee RPC use only. All 121 scoped JVM tests pass (114 XCM, 5 wallet debug, 2 wallet release), along with 135 effective-registry, 117 production-evidence and 21 native-page-size fixture cases. These are not native-device, fee-parity or funded-route evidence.
- Added a durable schema-v3-to-v4 credential-to-owner index migration in the challenge service. The migration preserves credential IDs, public keys, historical user handles, counters and owner tombstones; malformed or cross-owner indexes fail closed. The service now rejects PRF and other local extension data in credential requests, with a matching OpenAPI contract. All 104 backend tests and the passkey shell audit fixture suite pass. This is migration and request-boundary groundwork; discoverable authentication, owner/grant issuance and native portable recovery remain outstanding.
- Assigned the root source-owner mapping to the verified `soramitsu/fearless-release-readiness` PR #1 (`codex/release-readiness-root-owner` → `main`). Its published head is `318f58d7a8c5e688d551e00ebc81fdd80473f8f6`; GitHub reports it OPEN and REVIEW_REQUIRED. Existing workflow run `30695422294` succeeded for that older head only. The release gate now requires this root PR to be merged, reviewed and checked at the pinned identity; ownership assignment is not approval or qualification of current dirty source. The complete source-publication fixture suite passes all 83 negative cases. A fresh real local audit recognizes the assigned owner but correctly remains failed on dirty inputs, outdated checkout selections and publication mismatches; its report is `build/reports/production-root-owner-20260922.json`.
- Implemented the shared FWMA1 signed-authorization core on Android and iOS: Ed25519, exact package/build/policy/route binding, 900-second maximum lifetime, 300-second refresh, durable revision/digest/clock high-water state, fresh-process fetch requirements and intent-bound leases. Identical nine-vector fixtures are tracked in `config/fixtures/mutation-authorization-v1.json`; contract is `docs/mutation-authorization-v1.md`. Android's 21 focused tests, app Kotlin compilation and Hilt compilation pass. iOS's final Release run passes 103 tests (19 authorization, 9 configuration, 75 Main Tab), with zero failures or skips. A second-agent review caught the future-clock-skew lifetime and production decoder alias issues; both were fixed and included in that run. This is not the required independent release security approval.
- Android phase3 passes 240 scoped JVM tests (Utils 59, core 5, common 41, account 9, XCM 115, wallet 2, Polkamarkt 9) and exact-source Hilt compilation. Key access and SCALE signing now carry exact intent leases, queued Utils requests recheck and avoid replay, and fee/availability paths avoid private-key reads. Detekt remains blocked by 285 working-tree issues; this is not claimed baseline-only. Both platforms have an additional WebSocket library writer queue below their current send-call boundary. Android phase4 now owns a preserved nv-websocket source fork verified byte-identical to the Maven 2.14 sources; iOS has a preserved Starscream source checkout. These deeper handoff guards remain required before production authorization is qualified.
- iOS authority now re-samples time after each durable high-water/revision save and fails closed after three unstable samples. Persisted maximum observed wall time prevents a small clock rollback from reviving observed expiry. All 24 Release authorization tests pass without failures/skips, including delayed persistence and authority-lock waits; receipt `build/production-reconciliation-20260922/clock-stabilization-implementation.json`. Actual key/sign/send integration remains open.
- Published [Starscream draft PR #5](https://github.com/soramitsu/fearless-starscream/pull/5) at `b6ef58590241babdb4fe52e916a02c9e2b749e3d`, based on exact historical 4.0.12 source. It moves authorization after framing and blocking lock waits to synchronous `NWConnection.send`, cancels dequeued writes still waiting for authority, binds connection epochs, and preserves unknown outcomes without replay. It also rejects missing/incorrect WebSocket upgrade headers. All 38 local tests pass without skips (22 guarded-write/handshake/real TCP tests, 16 legacy framing/compression regressions); the Release framework builds at existing iOS 15 minimum. Both exact-head GitHub CI runs passed. The base branch is unprotected; independent review, protected CI, shared SDK/app integration and distribution qualification remain required. Root release pins now require this exact candidate to be merged and checked.
- Android phase4 source candidates are published as [nv-websocket PR #1](https://github.com/soramitsu/fearless-nv-websocket-client/pull/1) at `9714b30b6a16d40a2122765077bb71cf44314798` and [Utils PR #153](https://github.com/soramitsu/fearless-utils-Android/pull/153) at `aaea597bd35ada4783e64003b242dd831322207d`. Both GitHub CI runs passed for each exact head; root release pins bind the verified workflow identities. Local evidence includes 90 transport tests (two real loopback handshakes), 31 canonical Utils tests plus five core tests, and 27 key/store plus nine account regressions. Final app/Hilt and source-binding validation are still running. Both historical base branches are unprotected, so independent review and protected-branch qualification remain explicit prerequisites.
- Production trust remains unprovisioned. Exact generated route/catalog coverage and unified-manifest binding remain open; temporary denied configurations do not complete qualification. Key/sign/send lease integration is the active next work: Android and its runtime-compatible Utils source are being updated to guard queued actual sends. iOS's corresponding async extrinsic/SSFUtils path is identified but not yet integrated. Both retain legacy Polkaswap behavior; Android also retains its historical Demeter path.
- Replaced the iOS build’s mutating SwiftFormat phase with `--lint`. The actual bundled formatter passed and left all 2,865 Swift source files byte-for-byte unchanged; project syntax validation passes. This build-phase-only edit follows the 103-test run and has its own explicit receipt. Pinned dependency source integration now follows below; final-source build/manifest qualification remains outstanding.
- Moved the iOS carried dependency fixes onto the exact historical SDK base in clean source revision `9a91c22b9baa60f7237637a032d4c29159b8e16b`, tree `5d7829e5d9d0e04b13a5e28359dd0671c6cc9e76`. Draft [shared-features-spm PR #82](https://github.com/soramitsu/shared-features-spm/pull/82) targets `feature/neon-fix-fearless`; PR #81 targets a different wallet storage/API line and is not substituted. Native tests exposed and removed an intermediate scrypt-buffer `printf`; zero work factors now fail safely. Three RFC 7914 vectors, invalid parameters, and four Apple architecture link variants pass. All 153 retained framework files match the original bytes; four redundant sidecars are removed. Both GitHub native-compatibility runs passed on this candidate, with workflow/app provenance captured; independent review, protected-base CI and existing Jenkins gate remain required. GitHub confirms the current PR82 base is unprotected, which remains an explicit release prerequisite.
- The iOS app pins that commit in both resolver files, its Xcode project and FearlessUtilsCompat. A read-only verifier binds commit/tree and hashes every dependency file, rejecting staged edits, hidden changes, wrong modes/symlinks and additional ignored/untracked files. Twenty-one verifier/report adversarial tests and the historical delta-audit fixtures pass. CI/setup/test/Xcode paths now verify instead of applying patches, and old patch entry points are read-only compatibility wrappers. Pin enforcement no longer rewrites identities. The isolated clean cache passes `removalReadiness=ready`; the report explicitly says `releaseQualified=false`. The final scale-enabled Release run passes 328 migration/import/mnemonic-export/signing/authorization tests with zero failures/skips, including a 113,989-row migration; all 25 integration source hashes stayed unchanged. The historical JSON-keystore export suite contributed no tests to that result because it was commented out. Its restored eight tests now pass in a separate Release run alongside nine signing tests (17 total, no failures/skips), verifying original-key round trips for sr25519, ed25519, Substrate ECDSA and standalone EVM; chain-key selection, missing-key refusal, and wrong-password/tampered-ciphertext rejection. Four signing tests now fail explicitly when their wallet fixture is absent. The receipt is `build/production-reconciliation-20260922/legacy-export-implementation.json`. Original resolved caches and before-change capture remain preserved.
- Reconciled the root static XCM audit with independent read-only discovery and compiled submission authorization. Four scoped XCM fixtures pass, including disabled discovery and bypassed compiled/wrapper guards. The full static fixture baseline fails on nine existing web/project-plan marker mismatches; the default historical TestFlight fixture source is also missing in the old canonical checkout. Full manifest/checkout and aggregate-fixture reconciliation remain outstanding; this is not a full audit pass.

- Android phase4 final source candidates are Utils `1c80a2bf3fa1f996cf1328873e09f282ee29b69e` (PR153) and NV `9714b30b6a16d40a2122765077bb71cf44314798` (PR1). Final app validation passes 194 scoped tests plus Hilt; exact-source release runtime graph verification passes. Utils CI passes 36 source tests and NV passes 90 tests including real loopback. Source/provenance/IAS adversarial checks pass, with 56 scoped app source hashes captured. Receipt `fearless-Android-production-consolidated-20260731/build/reports/android-production-phase4-20260922.json`, SHA-256 `1a654441f747d3327ebe7a4156976fe2da55be4bc19ee35f7c7ab2410bda7325`. At that snapshot the app was unpublished/dirty and Detekt findings were unresolved; the current source status is below. The source PRs await independent review, and Release/R8/AAB, API36/16KiB/device, native signing and Play upgrades remain unqualified.
- iOS guarded RPC candidate [shared-features PR83](https://github.com/soramitsu/shared-features-spm/pull/83), `239371cc124d08ee9c7838028a08d4032a587b93`, pins Starscream PR5 `b6ef58590241babdb4fe52e916a02c9e2b749e3d`. Both native-compatibility and authorized-rpc CI jobs pass on that exact source. App verification now requires both strict source contracts, both resolver identities, SDK transport declaration and 1,257 exact source files; 30 adversarial tests and delta-audit fixtures pass. The integrated Release app run passes 341 tests without failures/skips, including original-key signing/export and scale migration. Receipt `build/production-reconciliation-20260922/authorized-rpc-app-pass1-implementation.json` is development evidence for that pre-review commit. Internal review subsequently found operation-cancellation publication and node-failover deadlock/retry gaps; fixes and fresh verification are in progress, so this run does not qualify the revised candidate.

- The reviewed-fix SDK candidate for PR83 is `6361213410aaa184b56a4030b626b0b62b6352ee`, tree `18757523d651855f51937e15e60fd8b93158009e`. It closes cancellation before request-ID publication, preserves the first terminal outcome, avoids callback reentrancy deadlocks, restarts node failover with a fresh socket and reserves live/manual RPC IDs. All 37 scoped source tests pass without skips; both exact-source GitHub CI runs (`35717431668`, `35717436735`) pass native-compatibility and authorized-rpc. The integrated app Release run passes 362 tests without failures/skips; receipt `fearless-iOS-production-consolidated-20260731/build/production-reconciliation-20260922/rpc-review-fixes-app-pass1-implementation.json`. This supersedes the earlier 341-test integration result for code coverage, but is still development evidence. Transport generation isolation, read-only XCM and app signing leases are separate subsequent work.

- Starscream PR5 is now `c26d9665fc44fd55aa1170427b1aef007a944fd7`, tree `d4f521899950b579064ac188ee7901e0ad4b69a9`. Retired TCP state/read/TLS callbacks, deferred parsers, queued close frames and WebSocket events are bound to their physical connection/session; stop revokes parser admission immediately. All 59 local/CI tests pass with no skips, including 21 generation regressions and real TCP tests, and the Release iOS15 framework build passes. Exact-head push run `35720142331` and PR merge run `35720147240` pass; the latter explicitly tested its synthetic merge. Receipt `fearless-starscream-production-20260922/build/reports/transport-generation-reviewed-final-20260922/manifest.json`, SHA-256 `9a069a5f1db6fbde515b85d9f59904323aa32f81682c401a0d67cb3a46a59125`. Independent review/protected merge and integrated device/store qualification remain open.

- Read-only iOS XCM now uses a public-account-only SDK factory, a non-downcastable fee interface and a signer that always refuses; browsing and fee quotation no longer fetch wallet keys or require mutation permission. Submission still constructs a separate gated authorizer. Final [shared SDK PR84](https://github.com/soramitsu/shared-features-spm/pull/84) is `04c0d25190b748b3cc219c8d33630cb48f679d3e`, tree `2cbfed467120ef8c0656c7dadc836a985e762969`, with Starscream `c26d9665fc44fd55aa1170427b1aef007a944fd7`. The initial test compile error was corrected; transport integration also corrected a test that used a closed writer as a queue barrier. All 37 RPC cases pass with no skips, including cancelled-frame denial after reopening the detached fixture. Both exact-source SDK CI runs (`35720652850`, `35720657444`) pass native-compatibility and authorized-rpc; GitHub Actions app identity15368 is verified.
- The final pinned iOS app passes **441 Release tests, zero failures/skips**, including the four byte-identical canonical XCM cases, 75 Main Tab cases, authorization, node failover, legacy signing/export and historical migration coverage. All 4,089 app source hashes stayed unchanged; both dependency checkouts pass raw-file verification (1,262 source files), and all 30 verifier adversarial cases pass. Final receipt: `fearless-iOS-production-consolidated-20260731/build/production-reconciliation-20260922/xcm-transport-app-pass4-implementation.json`. The preceding simulator attempt failed before test launch with a Busy preflight error and is retained; rebooting the same dedicated simulator resolved it without erasure or uninstall. Internal XCM review found no introduced wallet-secret read or transfer dispatch. Full assembly/UI, actual app key/sign/send leases, frozen route completion, independent security review, protected CI, device/store acceptance and the unified release manifest remain open. The dependency patch-removal audit passes but explicitly remains `releaseQualified=false`.

Private before/after digests for the iOS transplants are retained under `build/reports/production-ios-reconciliation-20260922`. Generated logs, simulator results and capture patches are development evidence only. None qualifies a dirty checkout, a substituted artifact, or a skipped production gate.

## iOS app signing authorization — 2026-09-23

XCM, Demeter and Polkamarkt submission executors now require one intent-bound authorization through the actual Keychain read, native signature, extrinsic binding and final guarded RPC handoff. Their fee executors carry no signer. Guarded batching/replay is refused; legacy nil-authorization signing and submission options remain unchanged. Ordered length-prefixed intent hashes bind the confirmed capability, wallet/account, runtime, route/call fields and quoted amounts.

Internal review exposed a mutable-context check before authority lock/Keychain waits. The corrected authority performs durable freshness checks, revalidates context after those waits, and then samples freshness without I/O; crossing a new persisted wall-clock second forces another context check, bounded to three attempts. Nonblocking registry/runtime reads prevent socket/registry inversion. A second existing race in the newly used connection lookup is fixed by searching one SafeArray snapshot; deterministic and concurrent-reset tests cover it. Context is a fresh final observation, not an atomic freeze of every mutable app object, and signed-byte/fee/receipt qualification remains separate.

Final validation passes **463 Release tests, no failures/skips**, with 4,090 app source hashes unchanged, 1,262 pinned dependency source files verified and the canonical XCM tests byte-identical. Receipt: `fearless-iOS-production-consolidated-20260731/build/production-reconciliation-20260922/mutation-signing-app-pass5-implementation.json` (SHA-256 `a3bb31fe94f0aa9a31c4463d1f3e8c2594898bf1869ea073bf57450daddcd3a9`). The 458-test pre-review pass is retained as historical evidence; subsequent compile failures are retained and corrected before the final pass. Internal review receipt: `build/reports/ios-mutation-internal-review-20260923.json`. This does not qualify the app for distribution or substitute for independent security review.

## Recovery authority core — 2026-09-23

The new `services/passkey-backup-owner-authority` implements metadata-only random owner namespaces, discoverable credential indexing, opaque hashed sessions and exact-request single-use grants. SQLite transactions serialize authorization, owner generations, credential counters and revocation; uncertain commits poison the current writer. The default cryptographic verifier rejects all ceremonies, so this core cannot be mistaken for a provisioned authentication service.

All 37 tests pass on Node 22.13.0 and 26.9.0, including a 12-process grant race, crashes before/after commit and after revocation, delayed writer/commit expiry, replay/counter races, durable restart and rollback checks. Existing challenge-service tests still pass all 104 cases; captured challenge/config source is unchanged. Ten new source files and four validation logs were independently hash-checked against `build/reports/passkey-owner-authority-core-20260923/manifest.json` (SHA-256 `1aece09bddf6ecd045bdb7335744fcee4aec7c1cd46767a0b09f950b97a0e794`).

This core is committed on root [PR #1](https://github.com/soramitsu/fearless-release-readiness/pull/1), without a production verifier, HTTP listener or deployment. Atomic integration with legacy credential storage, local decryption before enrollment, confirmed final-route removal, key rotation, native Drive/PRF and real replacement-device acceptance remain required. The source-publication gate now requires all ten component files, including the lockfile; source stays visible while local SQLite state, build outputs and dependencies stay ignored. All 84 adversarial cases pass on the final gate source, including rejection when the owner authority is omitted. Receipt: `build/reports/owner-source-gate-final-20260923.json`.

## Iroha source delivery work — 2026-09-23

Read-only inventory is recorded in `build/reports/iroha-g4-source-inventory-20260923/inventory.md`. Canonical source is `8d3c527027d01f335a4f398610d651678a042f0f`; the historical mobile .3 artifact pins are not compatible with current NetworkId, fee-intent, TTL, payload-hash and native address-validation interfaces. Fresh packaging alone cannot qualify that migration or establish parity with the deployed node.

Build/delivery fixes were developed from that exact base and are now staged only on the existing `../iroha` `optimizations` checkout at `bc13f3bbbb42c603433ae5b6419b76fbd7afadfe`. Scope: validate artifacts from canonical external Kotlin build roots, run core JVM tests explicitly in mobile CI, and generate the SBOM from the canonical Kotlin source. The nine target paths did not change between the tested base and current `optimizations` HEAD; the staged patch has the same SHA-256 (`961949a477ddd378917dfda3d4ae08c9f44a08f36a9ee7f4413ae6865b39c880`) in both places. The pre-existing `iroha-docs` submodule modification is untouched. No new SDK release artifact is published or qualified yet.

The source-delivery fixes pass 52 focused tests, the checker/Python contract and actual three-module Kotlin SBOM generation; receipt `build/reports/iroha-g4-build-fixes-20260923/receipt.json`. Nine files remain staged on `optimizations` for the repository owner to sign and publish. The repository requires signed commits: after installing GnuPG, `git commit -S` failed because the configured identity has no available secret key. No unsigned commit or Iroha push was made. The temporary development worktree and its branch were removed after byte-identical transfer to `optimizations`; a preserved binary patch is at `build/reports/iroha-g4-build-fixes-20260923/mobile-sdk-source-delivery.patch`.

## Source publication and CI — 2026-09-23

The Android candidate is committed and pushed to `codex/android-production-consolidated-20260731` at `2bf823661acaf1a796a7ddf4d52fcd87cc4e8c30`, updating [PR #1260](https://github.com/soramitsu/fearless-Android/pull/1260). The iOS candidate is committed and pushed to `codex/testflight-redesign-2026.8.17` at `49f2f7eecb8d3203a2f73bdb53cc0ff33e08dc56`, opened as [draft PR #1304](https://github.com/soramitsu/fearless-iOS/pull/1304). Both app worktrees are clean. No distribution binary follows from these source commits.

The first exact-head CI runs exposed a missing iOS signing-test fixture dSYM handoff and stale Android Utils-source instructions. The fixture now asserts the dSYM handoff, and its signing, bootstrap, audit and real symbol-materializer tests pass locally. Android's public-dependency handoff self-test and exporter pass with the pinned Utils commit; the native sr25519 source tree was verified identical at the old and new dependency commits, while the actual binary provenance remains recorded at its original build commit. Later Android CI exposed stale checkout and pinned-dependency scan inventories; the corrected guarded step and 50 selected JVM tests pass locally. Android's 270 new Detekt findings were addressed with formatting, bounded code changes and documented structural suppressions while retaining `maxIssues: 0`; local `detektAll` and all three affected module unit-test suites now pass. Internal App Sharing rejects Git environment overrides before source-pin verification; the focused adversarial case passes. iOS's public-artifact and TODO audits are repaired. Its transaction-builder audit now asserts the preserved native TON Release exception and network-scoped journal/origin guards; the real-source audit and 140 destructive fixtures pass. Its Codecov source-delta report now runs only after the pinned dependency bootstrap, with ordering/negative fixture coverage. Android's exact-head full CI and IAS workflow are running; iOS Release Safety passes on its exact head while Codecov is running. Full build/emulator evidence and independent reviews remain pending.

The source-publication gate now selects the consolidated Android/iOS checkout paths and iOS PR #1304. Its 84 adversarial fixtures passed after the checkout selection change. A real remote audit at `build/reports/source-publication-current-20260923.json` confirmed the new paths and PRs, then correctly failed on open reviews, root/unrelated dirty repositories and generated outputs. The aggregate audit's execution roots and preflight/postflight path classifier now select the same production candidates; the rest of the full-live gate remains blocked. A single final release manifest binding all source, dependency, route, artifact and evidence digests still has to be completed.

The release-bundle exporter and verifier now bind the same consolidated mobile source/PR identities. Their Iroha source-publication row still points to a historical review branch; it must be replaced with an `optimizations`-only source contract before a production audit can pass. The root PR's exact-head review pin also cannot be embedded in its own final commit without a detached, reviewed manifest. Both are fail-closed manifest-design work, not grounds to accept a stale pin.

## Earlier candidate and enabled-feature checkpoint — 2026-09-23

The source-publication row, bundle exporter/verifier and aggregate audit are being reconciled to require Iroha's existing `optimizations` branch only. The user will handle the required signed Iroha commit and publication; no other Iroha branch is authorized for this release. Root and mobile code can be committed and pushed independently, but an unstaged or unsigned Iroha source change cannot become a qualified SDK artifact.

At that checkpoint, Android candidate `0986721e5cb24e0177a067cecc443c1ec4b7d532` was pushed on `codex/android-production-consolidated-20260731`, [PR #1260](https://github.com/soramitsu/fearless-Android/pull/1260). It retained API 36 targeting and disabled production XCM submission while preserving read-only discovery/quotation. iOS candidate `024664259740547bd25611f5bacd3238fa9b4333` was pushed on `codex/testflight-redesign-2026.8.17`, [PR #1304](https://github.com/soramitsu/fearless-iOS/pull/1304). Its focused accessibility regression run passed 16/16 selected simulator tests, and its exact-head Release Safety CI passed. Android's exact-head full CI and Internal App Sharing checks, and iOS Codecov, were still in progress when this checkpoint was written; their final conclusions must be rechecked before using them as evidence. These candidate hashes and test totals are historical, not shipping pins.

The passkey production policy now specifies Google Drive app-data as primary on Android and iOS, with optional iCloud on iOS. The global and both platform enable flags remain false. A new enabled-feature acceptance gate requires a reviewed shipping manifest, two independent Ed25519-signed QA/security attestations, exact artifact and source binding, raw evidence digests, native PRF and shared Drive-file interoperability, replacement-device recovery in both directions with original devices unavailable, and store-signed in-place upgrades. Its 21 synthetic rejection cases pass; the production gate correctly fails because the manifest, trust keys, attestation and actual device evidence are absent. The complete release manifest and its separate validator are still required. Source-publication and bundle fixtures still encode the interim disabled policy and must be deliberately updated when enabled artifacts actually qualify.

The passkey challenge service now rejects ambiguous duplicate security-critical HTTP headers before authorization; 105 security regression tests pass. The Drive-primary prerequisite audit has 124 passing fixture cases. The real full-plan static audit still reports hundreds of missing markers across mobile, services, Iroha and old test contracts. That result is a failing inventory, not a production acceptance result; some checks describe historical implementation arrangements and need reconciliation, while genuine feature and live-evidence gaps remain. No substitute markers or fabricated receipts were added to make it pass.

## Owner WebAuthn verifier increment — 2026-09-23

An optional adapter in the owner authority now performs actual WebAuthn verification for existing-owner authentication and adding credentials. It binds the exact server challenge, RP and approved platform origin, checks user presence/verification, the persisted COSE public key and user handle, counters, and backup eligibility/state. It strips no client secret: the owner core rejects PRF extension output before the adapter, and native clients must still avoid transmitting it. Focused tests cover iOS/Android origins, synced passkey flags, wrong origins/RP/challenges, signature tampering, counter replay and missing UV/UP. The full 45-test owner suite passes on Node 22.13.0 and Node 26. Its exact pinned `@simplewebauthn/server` dependency has zero reported npm audit findings at this checkpoint.

First-owner bootstrap still rejects, because self-custody wallet proof and app attestation have not been integrated. The existing challenge store and owner authority are still separate, so atomic credential lifecycle, safe legacy migration, decryption proof before enrollment and final-route rotation remain unresolved. The adapter is not deployed and does not authorize passkey recovery. The source-publication and release-bundle required-file lists now include its code and focused tests; protected CI is configured to run the owner suite on Node 22.13.0.

The root review candidate at `0ce474d54e2b2d1bc8efdf76a968711048077c10`
passed all three exact-head hosted jobs (`validate`, `verify`, and
`verify-owner`). The `validate` job exercises blocked-state/readiness contracts;
its success is not a full-live release pass. PR #1 still requires independent
review and a final reviewed shipping manifest.

## Drive and credential-wrapper increments — 2026-09-23

Android's disabled Google Drive adapter now pins each operation to one selected
account/token, traverses bounded file-list pages and rejects ambiguous,
incomplete, mismatched or oversized legacy metadata. The Android backup module
passes 149 tests using an isolated clean checkout of the pinned Utils source;
that avoids both dependency-verification overrides and changes to the user's
modified Utils checkout. Local Detekt passes. The `2a23224b` full CI stopped at
one Detekt issue in the Drive pager; the next run exposed HMAC usage in the
MoonPay scanner and was corrected with a SHA-256-pinned wrapper-only exception.
The new client-only WebAuthn PRF/HKDF/AES-GCM wrapper and canonical opaque
binary record bind owner, credential, wallet metadata and key epoch to the
random 32-byte backup key. Fixed independent Node vector and tamper/round-trip
tests pass; the [shared format](passkey-credential-wrapper-v1.md) is published
for iOS parity. Public PRF salts can now be requested during registration, or
evaluated by a fresh assertion restricted to one known credential when creation
omits output. The native result rejects mismatched or noncanonical IDs before
exposing local PRF output. Those PRF changes were pushed at
`b322702b00cc0ad2b6f19ce24c28e41225674f24`; its exact-head full CI and IAS
passed, including API 30/31/36 migration, startup instrumentation and
source-bound complete AAB/native payload checks. Two subsequent commits pin
Drive requests to a verified stable Google subject and add canonical immutable
FPBKGEN1 generations with append-only Drive create/read primitives. Android
head `828994258a37acfeeb9a0623169fcc14baf0757f` passes 181 strict offline
backup tests and Detekt; its exact-head CI and IAS are running. The generation
format permits 512 KiB while retaining the legacy 256 KiB envelope/default
transport bound. Its 785-byte cross-platform vector has SHA-256
`1c92b544dc25c687c202317d0e5747b5690a1056cf72e61d1dfab84c07c057a4`.
Upload acknowledgment is not decrypted-wallet verification.

iOS native Google Drive appData access is pushed on the existing iOS review
branch. It uses explicit
Google account selection and `drive.appdata` consent, pins the selected account
to a bounded transport, and retains the existing encrypted `FPBKAEAD` envelope.
Its 84 focused Release tests pass. The matching iOS PRF/HKDF/AES-GCM credential
wrapper and exact cross-platform vector are pushed on the same review branch;
its exact-head Release Safety CI passed at `0feef6db19b1b020ad8e1ae6e071587ec87e2ccf`.
A separate iOS 18+ native PRF ceremony path is now pushed at
`f9d25054e8cc4da30286ecad9fe8c881cc8c5ed2`; 117 focused Release tests
passed with zero failures/skips, targeted lint is clean, and Branch Flow,
Release Safety and Codecov passed at that exact head. Typed local
PRF results require an exact server-verification receipt; the production adapter
is unavailable because the service does not yet return one. The iOS 15 minimum
and legacy executor remain unchanged. Both Drive adapters remain disabled.
Android now has a verified-subject, append-only generation primitive, while
iOS has a separately pushed FPBKGEN1 codec at
`7d0844c4310d5d0e90f0b858e3f3cd74f21c80e6`; all 16 focused arm64 Release
wrapper/generation simulator tests pass, including the exact Android vector.
Its Branch Flow and Release Safety jobs pass, with Codecov still running.
Security and Fearless team reviews are requested. iOS generation storage,
qualification and the durable journal, verified
decryption-before-complete, owner lifecycle and replacement-device restoration
remain. Both clients accept a stable Google subject across email changes, but
real same-app-data access still requires a cross-platform provider test. No
server or app has been enabled.

The full-live root audit now invokes a detached canonical shipping-manifest
validator before enabled passkey acceptance. Its synthetic fixture accepts one
complete exact-source/artifact/evidence set and rejects dirty or symlinked
sources, substituted Iroha branches, missing evidence, noncanonical JSON and changed
digests. It binds all selected repositories, four source dependencies, route and
feature-policy digests, distribution identities, artifacts and raw evidence.
No actual shipping manifest exists yet, so the production gate correctly fails.

## Backup-head authority increment — 2026-09-23

The detached shipping-manifest and signed passkey-acceptance gates now require
the same exact raw evidence rows for the seven enabled-recovery categories and
reject reuse of one retained file for multiple artifact/evidence kinds. The
five shipping-manifest synthetic tests and 23 enabled-acceptance cases pass.
Root head `5721ecfad30c2ce3c1a74bf92428c4d9d9833da4` passed all three hosted
jobs; subsequent heads were superseded by new pushes. Owner-head commit
`901895c` passed all three exact-head hosted jobs, including the release audit
validation job. The 88-case source-publication suite
and both release-bundle export/verification suites passed locally before the
new authority increment below.

The non-deployed owner core now has schema-v2 backup-head metadata and an
explicit transactional v1→v2 migration preserving owner/credential state.
Authenticated reads expose current and retained previous descriptors, including
each generation's parent revision/digest; an exact
operation ID reconciles ambiguous commits. The SQLite transaction compares the
expected head revision/digest, keeps the storage-account binding fixed, rejects
unreviewed backup-key epoch changes and duplicate generation/Drive IDs, then
advances one head. Separate-process concurrent writers, crash before/after
commit, altered replay, revocation, migration and malformed inputs are covered.
All 52 owner tests pass on local Node 24 and 26. No new HTTP/grant route is
exposed, no Drive file is deleted, and the server cannot attest client-side
upload/download/decryption. Atomic integration with the existing challenge
store, native immutable-generation clients and live device evidence are still
required. This is metadata groundwork, not portable recovery acceptance.

## Durable Drive-generation journal increment — 2026-09-23

The iOS review branch now includes a private no-backup Application Support
journal for exact encrypted FPBKGEN1 candidates, their preallocated Drive IDs,
owner/account scope and one durable upload-attempt marker. The Drive create API
requires this journal and returns a reconciliation result rather than sending a
second POST for an existing attempt. Corrupt, partial, mismatched or reused
operations fail closed; the journal cannot advance an owner head or mark backup
complete. A separate read-only review found that the new directory entry and
complete-looking interrupted records needed additional fsync before admission;
both paths now fail closed on sync errors. Exact pushed iOS source head
`8267a564abf6116d729ad599e7c41717bbe2a9ba` passes 44 selected arm64
Release simulator tests, zero failures/skips, including parent-sync failure,
interrupted-record re-sync, restart, single-POST and prior generation/wrapper
cases. The local receipt is
`fearless-iOS-production-consolidated-20260731/build/reports/ios-drive-journal-20260923/authfix-receipt.json`,
SHA-256 `851aa87985c876a2919de45767b0807625c9183457fff3be5b9ae9b4961093f7`.
Exact-head hosted CI and independent security approval remain required.

Android's separate journal uses app-private no-backup storage, exact ciphertext
and context checks, fsynced attempt admission and cross-process locking. Its
public Drive generation create API now requires a journal, operation ID and
independently supplied scope; the POST helper only accepts the journal-returned
candidate. A selected-account/token failure now occurs before the one-attempt
marker, leaving an unsent candidate retryable under the same operation and ID.
Exact pushed Android source head
`4c0d21c65a3dcab45727cee546ece205f8f18acc` passes 200 backup JVM tests,
Detekt, instrumentation APK packaging and two API 36 emulator cases covering
native filesystem behavior and replay denial. The local receipt is
`fearless-Android-production-consolidated-20260731/build/reports/android-generation-journal-authfix-20260923/authfix-receipt.json`,
SHA-256 `96123d61475681ae506b109c64db444f908444e5ba107ca2cf13df785bf9f2b7`.
Exact-head Branch Flow CI passes; Android full CI and IAS are running, and
independent security approval remains pending. Neither platform has an owner/grant upload
coordinator, local decrypt-before-complete or real replacement-device proof;
recovery remains disabled. These local journals are not a portable backup
format, while their FPBKGEN1 ciphertext is shared.

## Final route inventory binding — 2026-09-23

The detached final shipping-manifest gate now binds the Android approved,
required and discovery-gap route files and the bundled local-chain registry in
addition to its compiled route manifest. It compares required routes with the
compiled allowlist, checks the compiled manifest's raw input hashes and refuses
any remaining discovery-only route. Eight synthetic exact-source/tamper cases
pass. This deliberately keeps the current candidate unshippable while the
frozen discovery gaps and their funded transaction receipts are outstanding;
it does not qualify or enable an XCM route.

## Exact mobile Drive round-trip candidates — 2026-09-23

The latest pushed Android source is
`b93ce04ab0f0a0786aef1f3ec2f2c2e3ba5d380c`. Its read-only reconciler
requires an admitted journal marker and independently supplied owner, Google
account and wallet identities. It downloads the same Drive ID, compares exact
canonical FPBKGEN1 bytes, requires local decrypt/sign/export evidence and
rechecks the journal and selected Google subject before returning local
round-trip evidence. It never retries POST, advances an owner head or marks
backup complete. All 205 backup-module JVM tests and `detektAll` pass with zero
failures/errors/skips. Receipt:
`fearless-Android-production-consolidated-20260731/build/reports/android-generation-reconcile-20260923/handoff-receipt.json`,
SHA-256 `3d38ad2adc622eaf9b220b991a849e973a7a1bff03bd42a2640d4947fbbe17cf`.

The latest pushed iOS source is
`87901e64625aca8d3b6ba9927040372ab26d052b`. Its matching coordinator
reconciles an uncertain upload and 404 using the same journaled file ID and
requires exact download plus an independently supplied local wallet verifier.
Its final selected arm64 Release simulator suite passes 49/49 tests with zero
failures/skips, strict SwiftLint and source formatting pass, and dependency
source remains pinned. Receipt:
`fearless-iOS-production-consolidated-20260731/build/reports/ios-drive-coordinator-20260923/handoff-receipt.json`,
SHA-256 `f5ec61f2e664151bd68a394bc77ef70288a10b3d8b978cf4e8d0394a18447543`.
Both verifier interfaces deliberately lack a production implementation. Native
PRF unwrap/decryption and original-wallet identity/sign/export, owner/grant
atomic integration and real replacement-device proof remain unqualified;
recovery stays disabled. The root route-manifest commit
`1a7405eff5a1a0332882cc4eb67e447f516bcfa6` passed all three exact-head
hosted jobs, including the 88-case source-publication fixture suite locally.
Mobile exact-head hosted CI and reviewer decisions must be rechecked after the
new pushes.

## Current local access check

Read-only inspection on 2026-09-22 found valid Apple Development and Apple Distribution identities. Apple device records exist, but none had an active tunnel (81 disconnected, one unavailable). The configured Android SDK's `adb` is available and reported zero connected devices. Receipt: `build/reports/mobile-local-access-summary-20260922.json`. These checks establish local inventory only; store access, provisioning, private-key use and actual device qualification remain unverified. No device was reset or uninstalled.

## Completion record

No subgoal is complete yet. No new build has been uploaded or deployed, no production feature has been enabled, and no funded transaction has been submitted by this implementation run.

## Next active work

- Finish Android independent review, green CI, full Release/R8/AAB, API36/16KiB, native-device and Play-upgrade qualification. Scoped key/sign/send implementation and phase4 verification are recorded above; these do not complete device or distribution acceptance.
- Obtain independent review and green CI for the published iOS key/sign/send boundary; qualify exact signed transaction bytes, fees, hashes, receipts, node changes and distribution artifacts. The 463-test development pass does not satisfy enabled-feature or store/device acceptance.
- Generate and bind the full route inventory and shared shipping manifest, then finish portable native PRF/Drive recovery and owner/grant issuance. Existing credentials and wallet identities remain preserved.
