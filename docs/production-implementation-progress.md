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

The program remains incomplete. The latest pushed Android and iOS source
candidates are identified below. Earlier Android and iOS test and CI results
qualify only their respective older commits; exact-head hosted checks for the
latest app sources must complete. Both app trees are on review branches, and
independent security review, protected qualification and distribution
acceptance remain outstanding.

The deployed JSON challenge service remains a separate credential writer from
the non-deployed SQLite owner authority. A test-admitted, one-writer HTTP
candidate now covers all seven protected routes. Its opt-in first-owner
wallet proof still lacks real platform attestation; verified legacy migration,
production startup admission, live cutover,
deployment and native Drive/PRF recovery remain unintegrated. The root source gate selects the consolidated
mobile worktrees and site-association PR #49. The complete frozen route
inventory/unified manifest, transaction-byte/fee/hash/receipt qualification,
general TON sends, production-service repairs and store/device acceptance
remain open. No local or CI result substitutes for independent review,
replacement-device recovery or capped funded evidence.

## Current source checkpoint — 2026-09-24

The shipping-manifest audit now selects the clean Android Utils checkout at
`1c80a2bf3fa1f996cf1328873e09f282ee29b69e` and rejects dependency
commits or trees that differ from the exact Android runtime pins, iOS source
contracts, Swift package declarations and both iOS resolver files. It also
rejects hidden dependency index flags and substituted effective Git origins.
The aggregate Android public-dependency gate now uses that same source pin;
the older `7500809...` commit remains only as provenance for already vendored
SR25519 native binaries. Synthetic shipping-manifest tests pass 21/21; the
clean Utils checkout passed its strict source check, derived-tree tests,
public dependency handoff tests and strict binary provenance audit. No final
shipping manifest has been issued: the enabled features, exact distribution
artifacts and acceptance evidence are still unavailable. The aggregate
release-audit fixture passes 239 scenarios, including rejection of a shipping
manifest mismatch before live passkey smoke. The real full-live and static
plan audits remain red on separate candidate and external qualification gaps.
The static audit no longer reports the five obsolete Android Utils/patch
expectations, and the new XCM UI/fee gates pass against the current source.
The real audit still reports 332 warnings across IAS, migration/Play, route
qualification, Iroha readiness, native passkey ceremonies and other release
requirements; that result is not a production pass.

At that checkpoint, the pushed Android candidate was
`3c43d9bb75f907ef25778adf0e4efd83e0df246f` on
[PR #1260](https://github.com/soramitsu/fearless-Android/pull/1260). Its
Android-local draft captures validated V3 Substrate/EVM/TON, V2 chain-account
and separately guarded V1 source material across multiple wallets. Active V1
aliases without one durable wallet owner, malformed aliases and inventory
changes block capture without deleting the source; its plaintext staging
buffer is wiped. The preceding head passed 26/26 focused material tests and
the full account module passed 194/194 against a clean checkout of pinned
Utils source. The later material head added a bounded `FPWMLE01` envelope grammar with
byte-identical Android/iOS synthetic vectors and only a `localOpaque`
derivation mode; its focused codec and draft tests passed 6/6. The new codec and
test files pass forced scoped Detekt, while the existing draft test retains 11
style findings. Default Detekt excludes this module. The current head keeps
XCM route discovery and fee quotes available while the balance-detail send
action follows compiled and signed runtime submission permission. Its
confirmation path now binds the origin fee to the origin utility asset and
converts it to base units exactly, rejecting asset mismatch or fractional
base units before signing. Focused XCM service/engine tests passed 50/50 on
the preceding head; the current head passes its 5/5 mutation guard tests and
`detektAll`. Exact-head Android CI and IAS validation are pending. Production
XCM execution remains disabled. The local envelope is not a cross-platform
serializer, installer or enabled Drive backup.

At that checkpoint, the pushed iOS candidate was
`aee2792a001645708012fe8778c254984cfe8129` on
[PR #1304](https://github.com/soramitsu/fearless-iOS/pull/1304). Its in-memory
draft captures every known V2 root and chain-account Keychain slot, plus wallet
identities, selection/order and the two historical Core Data display
preferences that the ordinary wallet model omits. Signing preflight runs after
capture and a final present/absent-slot reread detects stable substitutions;
reflection is redacted. The draft now rejects mnemonic/path bytes that do not
rederive the original Substrate root, advertised EVM root, or applicable generic
chain public identity. It retains ambiguous historical seed bytes without
guessing their derivation. Earlier heads passed 22/22 focused iOS simulator
tests, 11/11 adjacent export tests and hosted checks. A matching `FPWMLE01`
envelope codec passed 2/2 focused simulator tests. Its iOS inventory subtype
is reserved; no serializer or installer uses the grammar yet. The current
head accepts a standalone EVM wallet only with a matching public key/address,
quarantines partial TON and mismatched public records, and requires the
original EVM private key during backup preflight. Root-mnemonic and
stored-seed adoption skip wallets without a Substrate root. The focused
workspace simulator suite passed 34/34 mapper/preflight tests on the preceding
code head; both `git diff --check` and project `plutil` lint passed. The
current documentation-only commit corrects the material inventory's EVM-only
description. Exact-head hosted checks are
pending. A shared Core Data/Keychain writer lock,
account-level export/reimport proof, specialized chain derivation proof and
the shared serializer/installer remain required before backup completion.

At that checkpoint, the next cross-platform material step was to assign a portable wallet identity
instead of copying Android's numeric database ID or iOS's string meta ID.
The then-current `FPWMLE01` grammar shared only its header; Android's payload was an
Android draft, while the iOS inventory source had no serializer. A bounded
semantic record must preserve the original independent keys and derivation
provenance, then each receiving app must independently derive public identity,
prove original-key signing and export, and install the whole wallet snapshot
through a durable, idempotent journal. Neither platform has that installer.

The non-deployed SQLite owner authority's one-writer HTTP candidate covers all
seven protected route contracts in local tests (111/111). Its root source at
`617475d16e772d2f657e72c5f2bb1055582fde1b` passed all three hosted CI jobs.
The deployed JSON challenge service remains the live writer; verified legacy
migration, first-owner wallet proof, production startup admission and live
cutover have not occurred. The Iroha `optimizations` checkout remains with its
repository owner; no other Iroha branch is authorized.

## Candidate update — 2026-09-24

The non-deployed owner authority now has SQLite schema v5: an explicit v4→v5
migration and durable, single-use, key-bound registration/assertion challenges.
Issuance requires an already proven storage-key→random-owner binding. A claim
commits the exact response digest before asynchronous verification. Completion
rechecks the claimed row, owner session/generation, exact grant, platform,
nonce, per-key user handle and credential scope under the SQLite writer lock.
Registration inserts the public credential, historical metadata and wallet-key
scope atomically. A null assertion handle is allowed only for a challenge whose
stored directed ID matches that credential. Restart, replay, expiry, generation,
wrong-owner/key, concurrent claim, counter and durability cases pass locally.
The internal verifier now claims before asynchronous WebAuthn work and checks
the exact nonce, RP, qualified configured origin, UV/UP, stored assertion
public key/counter and public registration AAGUID/transports. Synthetic signed
iOS/Android credential tests cover success, tampering, replay, PRF rejection
and owner revocation during verification. This is internal machinery only:
there is no live HTTP composition, verified historical JSON import, native
provider qualification or owner admission.
The protocol fence still rejects owner grants at the JSON writer; portable
recovery remains disabled.

At the preceding checkpoint, the pushed Android candidate was
`93b58fc593d70e70628fb1eb2be44eab122e6a2c`, including exact amount-property
integrity and confirmation/submission parity checks for XCM; its focused tests
and Detekt pass locally. The
then-pushed iOS candidate was `c29acdf15781574ae566aa50d676ca632dd6b4cd`;
102 impacted tests passed locally at the earlier accessibility checkpoint.
At the current iOS head, a focused iOS 18.1 simulator preflight suite passes
14/14: it locally signs and verifies SR25519/ED25519/ECDSA Substrate, EVM and
explicit chain keys. The checked native SR25519 signer returns an error for
the malformed key that previously aborted the simulator process. The focused
wallet signing-wrapper suite passes 12/12. Recovery remains disabled; this
preflight cannot establish cross-device restoration. Exact-head
hosted qualification, independent review, distribution-signed upgrade and
cross-device recovery evidence remain open. The shared-features candidate is
`4323032511ee788b178aa3f9ed05e2518ee21c74`, and the website-association
candidate is `fb824cf23ee4bb606f4a5168242da701b6ec78ac`.

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

The release-bundle exporter and verifier now bind the same consolidated mobile source/PR identities. Their Iroha source-publication row selects only the existing `optimizations` branch and rejects historical topic PRs. The exact-commit reviewed/protected policy for that branch is still unavailable, so the gate deliberately fails. The root PR's exact-head review pin also cannot be embedded in its own final commit without a detached, reviewed manifest. Both are fail-closed manifest-design work, not grounds to accept a stale pin.

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

The initial pushed iOS coordinator source was
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

The latest pushed iOS source `87c494ea11014ce3dfdbc42c92f4f6f562eec12e`
also rechecks the exact attempted journal record and selected Google subject
after the asynchronous local verifier. A removed journal or switched account
cannot produce local round-trip evidence. The same arm64 Release simulator
suite now passes 51/51 tests, zero failures/skips; the changed Swift files
pass bundled SwiftFormat and strict SwiftLint. Receipt:
`fearless-iOS-production-consolidated-20260731/build/reports/ios-drive-coordinator-postverify-20260923/handoff-receipt.json`,
SHA-256 `366a545acd27e95a7324a093a2c6ee8600586307698f5569abf5c910045012ec`.
Hosted CI and independent review are pending for this exact head. The verifier
remains a test fixture, and portable recovery remains disabled.

Android source `97bf278870b77a37697965d946a664427d310d3f` is now pushed on
the same production candidate branch. The preceding full hosted run reached
Android 11 migration setup, then rejected the emulator process group before
running migration tests. Its archived log shows the captured emulator process
had started and initialized; a one-shot PGID sample may have raced `setsid`.
The launcher now waits at most ten seconds for the captured PID to become its
own group leader, fails if it exits or stays in the wrong group, and records
the observed PID/PGID. The CI gate's one positive and 106 negative/adversarial
local fixtures pass, as do shell syntax and the direct gate verifier. The
exact-head hosted emulator run is still in progress, so this does not yet
establish Android 11/12/16 migration evidence or a distributed build.

The root Iroha production-send aggregate now reads the consolidated Android
and iOS candidate checkouts selected by the shipping audit. Its adversarial
fixtures reject a missing current Android gate even when the old checkout
contains executable scripts. The real aggregate passed Android, iOS and web
blocked-state self-tests and audits on the selected sources, including 110 iOS
and 48 web negative/adversarial fixtures. This closes a checkout-selection
gap in the gate; it does not qualify new SDK artifacts or funded sends.

## Consolidated candidate audit reconciliation — 2026-09-23

The root passkey prerequisite, Iroha wallet coverage and release, Taira source,
Nexus evidence, private-overlay and workflow-action audits now select the
consolidated Android/iOS candidates. Historical mobile trees cannot substitute
for missing or changed current source in the added fixtures. The real wallet
coverage audit passes on the current source, including the iOS production-send
denial test. Its result is explicitly blocked-state coverage: enabled Taira/Nexus
send, new SDK artifacts and funded receipts remain unqualified. The Nexus
evidence suite passes 14 positive and 161 negative cases; it now derives wallet
commit identities from the consolidated checkouts. The action-pin audit checks
72 immutable references across 20 selected workflows.

The passkey prerequisite audit initially reported six gaps that were stale
source-pattern assumptions. Android already persists the wallet, account and
timestamp fields through a bounded Drive-property writer. The iOS production
entitlements use the exact App Store CloudKit container and application group;
the provisioning checklist phrase wraps across two lines. The audit now verifies
those actual contracts, and its 128 adversarial fixtures and real source check
pass. This is a source prerequisite check only: provider provisioning, native
PRF/decryption, owner integration and replacement-device proof remain open.

Root and mobile private-overlay audits now accept real Git worktrees and invoke
Git with an isolated environment for both checkout validation and private-file
enumeration. The platform and root fixtures pass, including ambient `GIT_DIR`
and `GIT_INDEX_FILE` substitution attempts; the real Android/iOS private-overlay
comparison passes. Android commit `62a6e5709` and iOS commit `04e521410` contain
the platform fixes. Both are pushed; exact-head CI remains in progress.

The Taira audit's mobile lookups now read consolidated candidates, but its full
suite and real static audit stop on the current Iroha OpenAPI artifact: required
`SoraRuntimeHfModelHostV1` is missing. The nested Iroha release fixture also
omits that artifact. Focused candidate-substitution fixtures pass; no Iroha
source or branch was modified. The user's Iroha work is restricted to its
`optimizations` branch. These failures remain release blockers, not waived gates.

## Owner backup-head authorization — 2026-09-23

The non-deployed owner authority now mints an internal 60-second grant bound
to one canonical generation request, owner session/generation and audience.
Its SQLite head-CAS transaction checks and consumes that grant atomically with
the metadata update. A session token, any of the existing seven-route grants,
an altered body, an expired grant or a revoked session cannot advance the head;
successful operation replays require a fresh grant. The seven-route challenge
grant contract remains unchanged. All 55 owner-service tests pass locally,
including separate-process same-grant races and before/after-commit crash
reconciliation. The full root source-publication adversarial suite also passes
88 negative cases locally. This adds no HTTP service, native decrypt verifier, owner
lifecycle integration or permission to enable recovery. Exact-head hosted CI
and independent review remain required after publication.

## Published candidate heads and remaining audit debt — 2026-09-23

The consolidated Android branch is pushed at
`84c1d31291340a42309fa42bedca3251e0d4dff5` and the iOS branch at
`04e52141081d97863cf0df09bf647bddd036f4cf`. Both PR descriptions now
identify those heads and their still-disabled recovery/send boundaries. The
prior Android hosted run passed the API 30, 31 and 36 compatibility shards and
its IAS job passed. The full API 34 instrumentation run was interrupted by the
new push; its partial result-parser failure was a consequence of cancellation,
not a completed migration result. The prior iOS hosted build passed. New
exact-head mobile CI is running. Root commit `0e7d2317` passed hosted CI.

The broad `audit-plan-readiness.sh` still fails. A diagnostic full run during
candidate reconciliation reported 319 static failures across current mobile
sources, other maintained services, root plan assertions and the separately
owned Iroha checkout. Some are stale
assumptions from older candidates; others are genuine missing release evidence.
Its 4,211-case fixture also needs source reconciliation. No gate was waived to
turn this into a passing result, and no Iroha files or branches were changed.
The final release PR pins and detached shipping manifest remain open until the
shipping heads have current independent review and exact artifacts.
Root PR #1 now uses a narrowly scoped self-pin resolved from a clean committed
checkout, with exact GitHub origin, branch, review and required-check binding.
Focused substitution and replay fixtures pass. The full PR-audit fixture was
still progressing after 15 minutes locally and was stopped; exact-head hosted
CI must complete it. The self-pin validator must run from a clean checkout of
`codex/release-readiness-root-owner` at the reviewed PR head even after merge;
the detached manifest then binds that exact source commit.

## Directed recovery assertions and revocation boundary — 2026-09-23

The current pushed Android candidate on `codex/android-production-consolidated-20260731`
is `ea271c827574a70cce988747edf1e7a8f1093519`. Its credential-directed
PRF assertion client and native result parser bind the exact selected credential
and accept a null WebAuthn user handle only for that directed ceremony. Android
also distinguishes rollback of an enrollment that never verified its backup
from ordinary credential removal. Only that rollback sends the new exact-body
confirmation flag. Detekt and all 210 backup-module tests pass locally; exact-head
CI and IAS validation are queued. Ordinary live-route deletion remains blocked
until confirmed UX, backup-key rotation and coordinated service revocation exist.

The iOS candidate on `codex/testflight-redesign-2026.8.17` is pushed at
`2ca7389faceb1d1713d5234bcddf0c4c6fcd1916`. It binds directed PRF
assertions to the challenged credential and keeps discoverable assertions strict.
The prior head's targeted simulator suites passed 81 tests and Release Safety
passed. The current head adds a dedicated incomplete-registration rollback
body; its focused iOS 18.1 simulator suite passed 60 tests. Current exact-head
CI is queued. Native Google Password Manager PRF
interoperability on iOS 18+ is unproved by these simulator tests.

The root challenge service now binds a directed assertion to its exact
credential and accepts a null user handle only on that path. Its prior pushed
head `edd7c08aaf4289ce1228a498cbdab20fcded75cf` passed all three
exact-head hosted jobs. New local changes require an explicit, authorization-bound
`confirmFinalRecoveryRemoval: true` before revoking any live credential, since
another stored credential does not prove a decryptable surviving backup. The
non-deployed owner authority applies the same guard. The Android/iOS clients
reserve this field for incomplete-enrollment compensation; ordinary removal
stays blocked until explicit user confirmation is implemented. The full local
challenge and owner suites pass 106 and 55 tests, respectively. This guard does
not prove that the client displayed confirmation or rotated the backup key.
Revocation is not yet atomic across the challenge and owner stores, so a
partially revoked identity remains a production blocker. No recovery capability
was enabled or deployed by this increment. The root source-publication fixture
passed all 88 adversarial cases locally before this new root source is pushed.

## Current local access check

Read-only inspection on 2026-09-22 found valid Apple Development and Apple Distribution identities. A 2026-09-23 recheck still finds both identities and zero connected Android devices; the sole listed physical iPhone is unavailable, while one simulator is connected. The visible GitHub repository and `android-play-testing` environment secret inventories are empty, though organization or external operator credentials may exist. That protected Android environment has a required reviewer and prevents self-review; its approval path must be verified with an actual candidate. Receipt for the earlier inventory: `build/reports/mobile-local-access-summary-20260922.json`. These checks establish access inventory only; store publication, provisioning, private-key use and device qualification remain unverified. No device was reset or uninstalled.

## Grant expiry and legacy Drive retention — 2026-09-23

Root commit `7bbb2d27bf3bcf5aa4bb2e114bc22f72532239b9` requires a live expiration on production passkey authorization and rechecks it just before WebAuthn registration or assertion mutates credential state. Controlled-clock tests cover expiry during both asynchronous ceremonies; all 108 challenge-service tests pass locally. The owner authority still passes 55 tests. This closes an expired-grant commit window, but the separate challenge/owner stores remain non-atomic and no recovery service is deployed. Exact-head root CI is running; independent review is pending.

Android commit `94d994bbf54d092d41f8bbf662449e65d61f7d51` and iOS commit `e190373b87a0913cfb009bc2e4cd520225cd3ce1` refuse to overwrite an existing legacy Google Drive backup. Both retain read access to historical ciphertext, while their immutable generation primitives remain separate and disabled. Android's 210 backup JVM tests and Detekt pass locally; iOS's 26 focused Drive simulator tests pass with zero failures/skips. The old list/create operation is not atomic across devices, legacy deletion remains possible through lower-level adapters, and neither platform has an integrated owner-authorized migration or verified backup-head promotion. Fresh exact-head mobile CI is pending or running. No physical Google Password Manager/Drive interoperability or replacement-device recovery was inferred from these tests.

## Exact-readback and assertion lifecycle increment — 2026-09-23

Root commit `32c1805bb8f8eb2813ba933721d99d760bdec9c1` rejects an assertion counter commit if the credential lifecycle changed during asynchronous WebAuthn verification, including revoke and re-register of the same credential ID. All 109 challenge and 55 owner tests pass locally; its three exact-head hosted jobs passed at [run 35858794034](https://github.com/soramitsu/fearless-release-readiness/actions/runs/35858794034). This closes an in-process late-commit window, not the separate challenge/owner store transaction gap. The backend remains non-deployed.

Android commit `a102e48b645684ff8c67d953f586ddff07eb0868` and iOS commit `c05df34769b7dcb4af6a9eb223b7d34be91c13d1` require exact cloud readback and local decryption before the disabled legacy save paths report success. Registration readback failure invokes the existing new-credential compensation. Android's 215 backup JVM tests and Detekt pass locally; iOS's 63 focused Release simulator tests, SwiftFormat lint and diff check pass. The previous Android head passed validation-only IAS at [run 35856661016](https://github.com/soramitsu/fearless-Android/actions/runs/35856661016), and the previous iOS head passed Codecov and Release Safety. These older results are not exact-head qualification of the new commits. The new iOS Branch Flow and Release Safety jobs passed; full mobile CI is still running or queued. Neither platform has a complete immutable-generation promotion, physical replacement-device recovery or store-signed upgrade. The Google Drive list/create path and credential/owner cross-store revocation remain unqualified.

## Owner-side transactional credential mutation candidate — 2026-09-23

The non-deployed owner authority has a server-only `commitChallengeCredentialMutation`
candidate. It binds the exact existing route grant and raw request-body digest,
checks the live owner/session/credential, and consumes the grant in the same
SQLite transaction as a public credential insert, counter compare-and-swap or
revocation/generation bump. Separate-process assertion-versus-revocation and
duplicate-counter races, wrong-body/PRF rejection, before/after-commit ambiguity,
restart and explicit v1→v2 owner database migration are covered. All 66 owner
tests and 109 existing challenge-service tests pass locally; syntax checks pass.
The release source and bundle inventories now require the new test file. The
bundle OpenAPI expectations were also brought into line with the existing 409
final-route confirmation response and exact credential-directed null-handle
schema. The source-publication suite passed 88 adversarial cases; release-bundle
export and verifier fixture suites both passed. These validate source/evidence
contracts, not a deployed integrated credential store.

This is **not** cross-store atomicity in the running challenge service. Its HTTP
routes still mutate independent schema-4 JSON after separate grant introspection
and do not invoke the new SQLite method. Historical deterministic user handles
cannot be silently replaced by the random owner handles, and there is no
verified legacy credential/owner migration or storage-key binding yet. The
transaction candidate must remain internal until all seven routes use one
reviewed authoritative store, historical records are preserved, and crash and
device acceptance pass. Recovery remains disabled and undeployed.

In parallel, the Android head-binding candidate was pushed at
`b3238631c`; its pinned-Utils backup suite passed 217/217 locally and Detekt
passed. This is source-level progress on the disabled path, not verified
portable recovery or a final Android distribution result.
The iOS head-binding candidate was pushed at
`613affcdd018b14623d85602cf7d33b2f0fc3ab0`; its pinned dependency
verifier and 29/29 focused arm64 Release simulator tests passed with no
failures or skips on an iOS 26.5 simulator. This is also disabled-path
plumbing, not replacement-device recovery or distribution acceptance.

## Legacy credential reconciliation and HTTP isolation — 2026-09-23

The existing challenge HTTP implementation still consumes a grant through
configured introspection and then writes schema-4 JSON separately. Its deterministic
historical user handles, storage-key owner binding and full public credential
metadata cannot be inferred from the random owner namespace and narrower
SQLite schema. Replacing one live route with a SQLite write would create two
authorities and would not close the revocation race. **No cross-store atomicity
or portable recovery integration is claimed.**

The root candidate now has a read-only operator inventory for existing
schema-3/4 JSON and schema-2 owner SQLite. It checks both stores, reports
bounded conflict counts and JSON entry positions without emitting credential
IDs or storage keys, preserves tombstones, and always returns
`migrationPermitted: false`. SQLite rows are read in one read transaction;
the two files are sampled sequentially, so an inventory must use drained
private copies. The JSON snapshot does not trigger schema migration. Invalid,
symlinked or missing stores and oversized JSON are rejected; mismatched
metadata produces a blocked report. The legacy production container
explicitly sets `PASSKEY_RECOVERY_ENABLED=false`, and
its store factory rejects a recovery-enabled setting or an owner SQLite path
beside the JSON writer. This is a configuration guard, not a lifecycle
transaction bridge; existing legacy HTTP credential routes remain available.

For root commit `001a6c9439879d33ba70e72f416f8c5ad01828a3`, local checks were owner authority **70/70**, challenge service
**111/111**, both syntax suites and diff check pass. The source-publication
and release-bundle required-file inventories include the new reconciliation
tool and adversarial tests. The source-publication fixture passed all 88
negative cases, and both release-bundle export and verifier fixture suites
passed. These checks validate source/evidence contracts, not deployed
recovery. That commit passed exact-head CI at [run 35867210624](https://github.com/soramitsu/fearless-release-readiness/actions/runs/35867210624).
Recovery remains disabled until one
reviewed authority owns all seven live routes, verified historical migration
preserves every credential/tombstone, and device/cloud acceptance passes.

Android's subsequent disabled-path verifier candidate is pushed at
`64ce2dd96` with 221/221 backup-module tests and strict Detekt passing
locally. It verifies local PRF unwrap, authenticated decryption and
wallet-owned signing/export evidence, but has no production wallet callback
or native replacement-device recovery. The subsequent iOS disabled-path PRF
verifier candidate is pushed at `5f0adf0a814a9a030bbef8e6d3bb0950380cd3c0`;
24/24 focused Release simulator verifier tests pass locally. It remains short
of native replacement-device recovery and distribution acceptance.

## Owner-authority protocol fence and cutover admission — 2026-09-23

The random-owner SQLite core and the legacy JSON HTTP service must not be
composed through grant introspection while they have separate credential
writers. The owner core now marks its consumed-grant response with
`credentialAuthority: "owner-sqlite-v2"`; the JSON service's strict response
validator rejects that extra field before any of its four HTTP mutation
handlers. Tests cover all seven owner grant bindings and adversarial HTTP
calls to registration completion, assertion completion, single revoke and
revoke-all. The marker prevents accidental composition of these two source
implementations; it is not a cryptographic defense against a trusted proxy
stripping it and does not make two stores atomic.

The [legacy cutover admission contract](../services/passkey-backup-owner-authority/docs/legacy-cutover.md)
now requires a fresh historical-credential WebAuthn assertion and a separately
authenticated random-owner session, both bound to an immutable source digest,
storage key and owner; first-owner creation additionally needs original-wallet
proof and app attestation. The cutover must drain JSON writes, preserve every
credential field and tombstone in a versioned SQLite schema, then switch all
seven routes together to one grant/credential transaction. The subsequent v3
schema adds full-field capacity, but no verified link, transactional import or
integrated HTTP service exists yet.
Therefore no live route was converted, and portable recovery remains disabled.
Neither mobile platform yet serializes and restores every historical wallet
secret. iOS `MetaAccountModel` and Keychain tags for entropy, Substrate/EVM
keys, seeds, derivations and TON roots still need an explicit inventory and
cross-platform original-key signing/export proof.
Local checks on this source passed: owner authority 70/70 tests, challenge
service 112/112 tests, both syntax suites, diff check, source-publication 88
negative cases, and both release-bundle fixture suites. These are blocked-path
checks, not production recovery or transaction acceptance.

## Owner SQLite v3 metadata capacity — 2026-09-23

The owner authority now explicitly upgrades v1→v2→v3 or v2→v3 within one
SQLite transaction. Existing credentials, per-credential handles, counters,
sessions, grants and backup heads survive; failed migration rolls back and
normal startup still rejects older or incomplete schemas. New immutable
storage-key bindings hold an owner link, historical owner hash, sealed-source
digest and proof commitment. Separate legacy metadata rows hold AAGUID,
optional ordered transports and registration platform. An empty binding can
represent a durable owner tombstone. Tests cover both upgrade paths, a
partially colliding migration, missing safety trigger, metadata immutability,
wrong-owner attachment and post-upgrade grant/head continuity. Source and
release-bundle required-file lists now include the migration test.

These tables are only representation capacity. No JSON rows were imported,
no proof was validated, no random owner was inferred from a Google identity,
and no live challenge route was converted. Read-only reconciliation remains
`migrationPermitted: false`; the HTTP JSON writer and SQLite core are still
separate and recovery remains disabled. A reviewed proof-bound cohort importer,
one-writer HTTP cutover, crash/race acceptance and replacement-device tests
remain mandatory before production recovery can be enabled.

Current-source checks passed: owner authority 75/75 tests, challenge service
112/112 tests, both syntax suites, source-publication 88 negative cases, both
release-bundle fixture suites and diff check. These are source and blocked-path
checks, not production recovery acceptance.

## Selected website source and reversible worktree quarantine — 2026-09-23

The root source-publication, shipping-manifest, aggregate, live-association,
action-pin and release-bundle inventories now select the app-association site
worktree on `fix/app-association-publication`, [PR #49](https://github.com/soramitsu/fearless-site-web/pull/49),
instead of the retired website checkout and PR #45. The old PR remains a
historical release requirement; stale reviewed-head pins were not relabeled as
new approvals. Production association content, headers and Play-distribution
certificate parity remain unverified, so recovery stays disabled.

The source-output quarantine helper now binds the selected Android, iOS and
website worktrees to their exact local Git owners through regular `.git`
pointers, canonical admin directories and bidirectional links. It still
excludes `../iroha`. Its production dry run succeeds and inventories ignored
build caches plus ignored documentation and evidence; it moved nothing. Apply
must preserve those bytes in its private reversible manifest and be followed
by an exact-source audit before publication.

On the combined root source, the worktree quarantine adversarial suite,
shipping manifest 8/8, workflow action pins, unblock command contracts,
source-publication 88 negative cases, and both release-bundle fixture suites
pass. The plan-readiness synthetic complete fixture and its first three
action-pin negative controls now pass after fixture reconciliation; the full
4,211-case mutation catalog has not been run on this head. The production audit
still fails on dirty and unqualified sources, as intended. The root PR is open
and requires review and final exact-head CI. Neither mobile app has passed
store-delivered upgrade acceptance or cross-platform replacement-device
recovery.

## Legacy wallet-material preservation checkpoint — 2026-09-24

Android [PR #1260](https://github.com/soramitsu/fearless-Android/pull/1260)
now points to pushed source `2ae7fe4f43a2462a479f25d334ee0d4512690f71`.
The legacy Google-backup importer no longer drops a separately backed-up EVM
private key when a Substrate mnemonic is present. Both roots enter one durable
wallet creation. A key that matches mnemonic derivation retains its export
metadata; an independent key retains its exact address and is not falsely
represented as derived from the Substrate phrase. Malformed keys fail before
the wallet mutation, and an import failure cannot advance to the success view.
Focused repository/interactor/importer JVM tests pass with the exact pinned
Utils and WebSocket source checkouts. `docs/portable-wallet-material-inventory.md`
records V3 Substrate/EVM/TON roots, V2 chain keys, historical V1 material and
multi-wallet identity requirements. This repairs a legacy path; the public
remote-backup compatibility stub remains unavailable and portable recovery is
still disabled. Exact-head hosted Android [CI run 35880595419](https://github.com/soramitsu/fearless-Android/actions/runs/35880595419)
passed, including the API 30/31/36 migration, instrumentation, AAB and native
binary checks. This does not replace signed Play upgrade or device acceptance.

iOS [PR #1304](https://github.com/soramitsu/fearless-iOS/pull/1304)
now points to pushed source `51884d7f60d0c284b8c483eee503b77384f94e89`.
The legacy cloud-backup flow rejects absent cloud storage and incomplete seed
or keystore exports. After upload it downloads and decrypts the candidate,
compares all intended wallet-material fields, and reports completion only
after the local backed-up state write succeeds. The code at preceding commit
`10b33d20e037a507682d7956e63197717f195f7d` passes a single-architecture
iOS Simulator Debug workspace build and diff check. The subsequent documentation
commit inventories the original Keychain roots, native TON material and
chain-specific accounts that a shared wallet format must preserve. Hosted
Release Safety passed at preceding head `7fe6dadcbe3a3fd89be03ba222872b2630410a66`;
the new scene head requires its own hosted checks. The local Release build
could not complete because its dual-architecture Charts dependency compiler
jobs consumed excessive memory. This change does not provide the production
passkey wallet serializer, owner-session integration, or replacement-device
recovery.

The root [PR #1](https://github.com/soramitsu/fearless-release-readiness/pull/1)
has green hosted `verify`, `verify-owner` and `validate` checks at
`83c910018a6e674f75c34208519acb1ab6d193ea`. These validate the source
tooling and metadata-only, non-deployed credential authority, not a live
recovery service or shipping build.

## Exact-file legacy Drive backup checkpoint — 2026-09-24

At this checkpoint, shared-features [PR #84](https://github.com/soramitsu/shared-features-spm/pull/84)
pointed to immutable source `b7ef68761b7962fc06193b500467da7ba5498070`
(tree `53bb7f75f3cd1a30f2ab53e189535decbffa42e9`). The legacy iOS Google
Drive backup flow captures the ID returned by a new upload, downloads that exact
file, compares its encrypted bytes and decrypts it before allowing the app to
report backup completion. Legacy restore looks for the exact address filename
inside every strict backup folder, follows Drive pagination, and selects the
newest unambiguous generation. It fails closed on incomplete listings, download
errors, wrong wallet identity and a password failure for that generation.
Deletion removes every exact-name mobile generation, oldest first, without
selecting extension files.
Focused iOS Simulator cloud-storage tests passed 32/32. These checks protect
the legacy flow from verifying or restoring a different same-named file; they
are not the portable passkey backup format or a replacement-device recovery
test. Real Drive concurrency and historical wallet cohorts remain unqualified.

The iOS candidate at `51884d7f60d0c284b8c483eee503b77384f94e89` pins
that exact shared-features revision in both workspace resolution files, the
project, the compatibility package and the source
manifest. Package resolution, exact-source verification of 1,262 files and
SwiftPM pin consistency pass. The exact-head hosted iOS Release Safety and
Codecov workflows remain pending; Branch Flow has passed.
The prior iOS head's hosted simulator job executed 1,582 tests and failed one
connection-pool stress test on its ten-second completion bound; the remaining
tests had no failures. The subsequent source retains all 1,000 reset cycles
and gives the concurrent work a 60-second bound. That exact test passed on an
iOS 27 simulator with a focused scene-configuration test (2/2).

The same iOS head adopts a single UIWindowScene, preserving the iOS 15
minimum, the root presenter, custom-scheme callbacks and Google Drive OAuth
handler. The Xcode 27 Debug simulator app builds and no longer triggers the
missing-scene lifecycle assertion. A local fresh-install app built without
signing entitlements failed a Keychain lookup with Security status `-34018`;
the temporary diagnostic was removed. Attempts to run a manually re-signed
simulator artifact did not launch, so signed fresh-install and upgrade startup
remain unqualified. They require a correctly provisioned device or delivered
build, not an unsigned simulator result. No existing wallet simulator data was
reset.

## Historical passkey handle preservation — 2026-09-24

The non-deployed owner authority now uses each selected credential's stored
WebAuthn user handle for discoverable authentication and its atomic challenge
counter mutation. Schema v3 already retained historical per-credential handles,
but these two paths also required equality with the new random owner's handle;
that would reject a correctly linked historical credential. New enrollment
still uses the random owner handle. Focused tests seed a differing historical
handle, verify an owner session and exact counter commit, and reject substitution
with the owner's handle. All 77 owner-authority tests and syntax checks pass.
This compatibility fix does not import a JSON credential, establish a verified
owner mapping, convert the seven HTTP routes or enable recovery. The one-writer
cutover, wallet proof, app attestation and live replacement-device evidence are
still required.

## Credential-directed assertion compatibility and live site check — 2026-09-24

The non-deployed owner authority's internal exact-grant mutation now preserves
the legacy challenge service's credential-directed assertion: a null WebAuthn
user handle is accepted only with server-owned evidence naming the exact
credential ID selected by that challenge. Discoverable owner authentication
still requires the historical credential's concrete handle. Wrong or absent
direction evidence leaves the credential counter and grant unchanged. The full
owner suite passed 79/79 with syntax and diff checks at this checkpoint. No
HTTP service supplies that evidence yet, and the shared one-writer cutover
remains blocked.

The same internal target now requires a matching immutable legacy storage-key
binding for revocation. Revoke-all touches only credentials in the named
wallet cohort, leaving another wallet under the same owner intact. An unknown
or mismatched binding fails without consuming the exact grant. These tests
also deny an ambiguous revoke-all success when any live owner credential has
no storage-key mapping. They seed public metadata fixtures; no verified legacy
import exists, and registration/assertion still need trusted pending-challenge
storage-key binding before the route cutover can run. The full owner suite
passed 82/82 with syntax and diff checks at this checkpoint.

The selected site branch [PR #49](https://github.com/soramitsu/fearless-site-web/pull/49)
contains the intended JSON association contracts and response headers. The
strict live verifier against `https://fearlesswallet.io` still fails: Android
does not publish `delegate_permission/common.get_login_creds`; Apple publishes
an extensionless AASA as `application/octet-stream` without `webcredentials`;
all three association URLs lack `X-Content-Type-Options: nosniff` and differ
from source. The live development app ID is also the old
`YLWWUD25VZ.jp.co.soramitsu.fearless.dev`, rather than the selected source
`YLWWUD25VZ.jp.co.soramitsu.fearlesswallet.dev`. The source PR still needs
review, deployment and exact Play-distributed certificate comparison before
passkey recovery can be enabled.

## Review follow-up and idempotent revoke guard — 2026-09-24

Read-only review of the non-deployed owner core identified a further one-writer
cutover blocker: the current HTTP registration route derives its WebAuthn user
handle from the wallet storage key, while owner enrollment uses a random owner
handle and the internal route mutation does not add a key mapping. The
assertion completion body likewise cannot prove the pending challenge's wallet
key or credential-directed selection. The required integration is a single
SQLite-owned challenge claim with exact owner, key, nonce, platform, handle,
credential selection and generation, followed by verification and mutation
under that same writer. New owner-wide credentials also need explicit scope
separate from proven legacy wallet-key credentials. This review was an internal
code review, not independent production security approval.

The internal mutation now accepts omitted final-route confirmation only for
idempotent single-key retries or an empty, proven revoke-all scope. It still
requires explicit `true` before removing a live credential; `false` remains
invalid. Unknown storage-key ownership fails closed. Local owner tests pass
85/85 with syntax and diff checks. No live HTTP route uses this code.

Android [PR #1260](https://github.com/soramitsu/fearless-Android/pull/1260)
has advanced to pushed source `49f58b42a8ca9f7c7ca8ffc3809ab78fb99f28ec`.
Its new read-only wallet-material preflight checks every persisted wallet,
independent EVM and native TON roots, and per-chain keys through validated
repository access, rejecting missing/quarantined material and public metadata
drift without returning secrets or reporting backup completion. The full
account-module suite passes 177/177 and `detektAll` passes locally; exact-head
Android CI and IAS remain in progress. V1-only/watch-only cohorts, the shared
multi-wallet plaintext format, restore installer, and replacement-device
acceptance remain open.

The live passkey-service hostname `backup.fearlesswallet.io` did not resolve in
the release workspace while `fearlesswallet.io` did. The health service and its
deployment evidence remain absent; the Google Drive recovery feature stays
disabled. The selected website source still differs from the live association
files as recorded above.

## SQLite challenge and list route candidates — 2026-09-24

The non-deployed owner authority now has an internal exact-body, grant-bound
candidate for all three existing read/challenge-service routes. For an already
proven wallet storage key, registration and assertion challenge issuance consume
their owner grants and insert single-use SQLite pending rows in one writer transaction.
Registration derives the same storage key and user handle as the legacy
service from its wallet ID and account name, then requires that key to have an
independently proven immutable owner binding. A different account name does
not establish ownership or spend the grant.
Credential listing consumes its grant in that transaction and projects only
live credentials scoped to that key, preserving historical public AAGUID,
registration platform, device type, backup flag and transports. Owner-wide
recovery credentials are excluded; empty bound tombstones list empty. Wrong
session/key/body, replay, absent credential and a two-process same-grant race
fail closed. An explicit v4→v5 fixture compares public credential, scope,
binding and metadata rows before/after migration. A frozen legacy key/handle
vector and an internal registration completion also pass. All 107 owner tests, syntax
checks and dependency audit pass locally, with zero audit vulnerabilities.

These are internal source candidates, not a service cutover. The existing
registration-challenge body still cannot establish a random owner or proven wallet
storage-key binding from wallet/account names alone; the internal adapter accepts
only a previously proven binding. Tests seed proof commitments and do not verify JSON-to-owner admission or
historical JSON import. The seven live HTTP routes still use the JSON writer;
one-writer switchover, independent review, provider/device qualification and
cross-platform recovery remain open. Portable recovery stays disabled.

## Checked SR25519 signing checkpoint — 2026-09-24

Shared-features [PR #84](https://github.com/soramitsu/shared-features-spm/pull/84)
now points to `4323032511ee788b178aa3f9ed05e2518ee21c74` (tree
`bda39df7a41621190c3c34be9a60aa87c73141c2`). The rebuilt, source-pinned
SR25519 library retains the old C ABI and signing compatibility while its new
checked signing entrypoint rejects malformed secrets/public keys and mismatched
keypairs without a process abort. Rust tests pass 9/9, old/new simulator
signatures verify across libraries, three Apple architectures link, and device
and simulator IrohaCrypto Release builds pass. Shared exact-head hosted native
and RPC checks are green. Device execution and the full shared-package XCTest
suite remain open; the latter is blocked by existing SSFXCM test-mock compile
errors.

The iOS app pins that exact source at
`c29acdf15781574ae566aa50d676ca632dd6b4cd`. Source verification and pin
consistency pass; focused iOS 18.1 simulator wallet-material preflight tests
pass 14/14, including valid SR25519 signing and malformed-key rejection, and
signing-wrapper tests pass 12/12. The Android candidate at
`93b58fc593d70e70628fb1eb2be44eab122e6a2c` has green exact-head hosted
build/test CI. This resolves one native signing safety blocker, not the
production wallet serializer, original-key export proof, native provider
interoperability or replacement-device restoration. New-feature activation
remains disabled.

## One-writer HTTP composition candidate — 2026-09-24

The SQLite owner authority now has a non-deployed HTTP composition candidate
for the seven existing protected passkey routes. It also exposes separate
discoverable authentication challenge/completion and exact-body grant issuance
in local tests. Registration and assertion completion call the server-owned
WebAuthn verification path; read/challenge, credential insert, counter update
and revocation use the same SQLite lifecycle writer that consumes their
single-use grants. Responses preserve the existing route shapes, including
the proven storage key returned after a completion. A protected request needs
both a current owner session and its one-use grant. Local transport checks
cover body limits, duplicate sensitive headers, exact paths, missing sessions,
wrong body, replay, generation invalidation and all seven route contracts.
The owner suite passes 111/111 with syntax checks.

This factory has no executable deployment entrypoint, requires explicit test
admission and rejects production construction. The existing deployed JSON
service has not switched. Tests use fixture-proven storage bindings and
test-only verifiers; they do not prove historical JSON credential ownership,
first-owner wallet possession, app attestation or native provider recovery.
The cutover needs a sealed verified import, reviewed startup manifest, proxy
identity, independent review and device acceptance before production admission.
The current iOS `c29acdf15781574ae566aa50d676ca632dd6b4cd` Release Safety
check passed at exact head; Codecov remains in progress at this checkpoint.

## Offline legacy credential quarantine — 2026-09-24

The non-deployed owner-authority tooling can now capture an exact, expected-
digest-matched private image of the historical schema-3/4 credential JSON,
validate its public-metadata inventory against the read-only SQLite view, and
publish it without replacing an existing snapshot. Concurrent capture and
replay tests show only one private snapshot is retained. The command returns
a redacted count/diagnostic report and always denies migration; it creates no
owner, credential, binding, grant or proof. It cannot establish that the live
JSON writer was drained. The fresh legacy-credential assertion, random-owner
session, wallet possession, attestation and reviewed one-writer cutover remain
required. The owner-authority tests pass 115/115 with syntax checks. The root
source and bundle inventories now include the quarantine files and the
previously omitted owner HTTP composition source and test.

## Shared wallet-material byte contract candidate — 2026-09-24

The [candidate semantic-material contract](portable-wallet-semantic-v1.md)
specifies a bounded, canonical `FPWMSM01` plaintext payload under the existing
encrypted backup envelope. It includes separately signed Substrate, EVM and
native TON roots, per-chain keys, explicitly non-signable watch identities,
presentation metadata and lossless historical source slots. The format preserves
wallet order and selection and binds auxiliary bytes to their matching wallet,
root or exact chain account. A parser is only a structural check: cryptographic
identity validation, original-key signing/export proof and atomic installation
are still required before cross-platform recovery may be enabled.

Android [PR #1260](https://github.com/soramitsu/fearless-Android/pull/1260)
now points to pushed head `7f0a04adb3edafc71347fbf73aa527847c84165d`.
Its pure semantic codec validates the candidate wire grammar and exact EVM,
multi-root and full-metadata vectors. The `FPWMLE01` container recognizes the
portable source/mode pair for either platform while retaining the local-opaque
pairs. Focused tests pass 11/11 with the clean pinned Android dependency
checkouts; a forced four-file Detekt/format run has zero findings. TON root and
watch entries accept only the released Wallet V4R2 contract code. This codec
has no capture, Drive upload, backup-completion or installer call site.
Watch-only cohorts still fail in the Android local draft capture, and no
Android adapter yet converts that draft to the shared format.

iOS [PR #1304](https://github.com/soramitsu/fearless-iOS/pull/1304)
points to pushed head `a63592e218ac86c4dd2fbf3e3e74771140dbee7b`.
Its `FPWMLE01` header recognizes the same portable pair, and its independent
`FPWMSM01` codec decodes and reencodes Android's exact EVM bytes while matching
the Android multi-root and nine-metadata SHA-256 vectors. Signed and watch TON
records require the released V4R2 code. The focused iPhone 15 Simulator suite
passes 13/13 (10 semantic codec, three envelope), with scoped SwiftFormat,
strict SwiftLint, source typecheck, project lint and diff checks passing. Swift
buffer cleanup is best effort because prior copy-on-write copies may remain.
This is still an unwired structural parser, not an original-key verifier or
restore installer. Neither platform has replacement-device recovery evidence
or an enabled portable backup path. The exact Android and iOS heads still need
hosted CI completion and independent review.

## Guarded draft-to-semantic projection — 2026-09-24

Android [PR #1260](https://github.com/soramitsu/fearless-Android/pull/1260)
now points to pushed `ca12af94f4b381efbb331bfdc337b4474665067c`.
A pure converter projects the validated local draft into `FPWMSM01`, retaining
independent V3 Substrate/EVM/TON roots, V2 chain keys, V1 derivation/source
details, wallet order/selection, favorites and exact V3/V2 SCALE bytes in
bound auxiliary slots. Its portable ID is deterministic from the durable
Android wallet ID. It derives the released V4R2 TON workchain-zero address.
The Android decoder also accepts an iOS account-scoped TON Keychain source
only with an exact chain-account binding. Six focused material/preflight/
codec/transcoder JVM classes pass 43/43 against clean pinned Utils and
WebSocket checkouts. Forced scoped Detekt over the seven semantic source/test
files reports zero findings. Current Android `validate` CI passes;
`build-and-test` and IAS validation remain pending at this head.

iOS [PR #1304](https://github.com/soramitsu/fearless-iOS/pull/1304)
now points to pushed `e1702861b9f5096b9989f9d1d49b8c321474ca07`.
Its guarded converter maps a freshly captured iOS draft into the same bytes:
separate signed roots and chain accounts, original selection/order, display
metadata and every scanned Keychain slot verbatim as a bound auxiliary
record. Native TON phrase-only material yields a key checked against the
released V4R2 public identity. Named Bitcoin and Taira accounts take their
root-derived signer; incidental scoped Keychain bytes remain historical only.
An iPhone 15 simulator run passes 40/40 focused capture/adapter/codec tests;
scoped SwiftFormat, strict SwiftLint and project-file lint pass. Current iOS
`validate`, `release-contracts` and `ios-release-safety` CI pass; hosted
`build` remains pending at this head.

These adapters are isolated from backup completion, Drive upload, restore and
wallet installation. iOS capture still lacks a cross-store writer lock and
Android capture still rejects watch-only wallets. A receiving installer must
derive and verify every original identity and sign/export path, preserve the
portable ID across generations, and atomically install the full snapshot.
The iOS Bitcoin field-2 key identifies the first receive path, not an
account-wide signing master; root material and named derivation must be
rechecked during installation. A read-only peer comparison found no concrete
codec mismatch for captured cohorts, but it is not the independent security
review required by the release plan. Neither platform has real
replacement-device recovery or distribution-signed upgrade evidence.

## Read-only imported-root signing proof — 2026-09-24

iOS [PR #1304](https://github.com/soramitsu/fearless-iOS/pull/1304)
now points to pushed `46b6ace1e915d4da4cfcddc7d460795b6d098ed0`.
A separate read-only proof decodes `FPWMSM01` and signs a domain-separated
local challenge from each imported Substrate, standalone EVM, historical V1
Substrate and native TON root key. It verifies the recorded public key,
Substrate account ID or V1 SS58 address, EVM address, and TON V4R2 workchain
and account hash in either supported address encoding. If a native TON phrase
is present, it must derive the same original private key. Altered secrets,
addresses and phrase material fail closed. Four new tests exercise real
captured iOS roots, all three released Substrate crypto types, historical V1
and both TON address encodings. The focused iPhone 15 simulator capture and
codec suites pass 44/44 at the exact pushed source; scoped SwiftFormat,
strict SwiftLint, project-file lint and diff checks pass. Hosted exact-head
CI and independent review remain pending.

This result proves only signed root identities. It does not validate every
chain account or derivation recipe, make Keychain/Core Data writes atomic,
establish export parity on a replacement device, or authorize backup
completion. The proof has no installer or recovery call site. Android
historical watch-only rows remain ambiguous: released storage has no custody
provenance, so an absent key can mean either a watch-only wallet or a lost
signing key. The Android adapter continues to reject those rows rather than
silently downgrade them. A forward-only explicit watch provenance path is in
progress; previously stored ambiguous rows cannot be auto-classified safely.

The same iOS PR has advanced to pushed
`775af4808c4dd9723cd5ab8692d444da07f15104`. Its second read-only proof
checks named Bitcoin and Taira chain slots against the original root mnemonic
or explicit raw-wallet-seed bridge. It verifies the Bitcoin first-receive
private/public key and Taira ED25519 key against the released derivation,
recorded account identity and chain address, rejecting altered keys and source
markers. Focused simulator suites pass 45/45 at this exact head; scoped
SwiftFormat, strict SwiftLint, project-file lint and diff checks pass. This
does not verify other per-chain signers or install a wallet.
The native TON root proof also accepts Android V3's original 32-byte private
seed only with its mnemonic in field 5; native iOS retains its 64-byte
seed-plus-public key and field-12 phrase. Both shapes must prove the same
V4R2 public key and address. The simulator test covers these representations
using one fixture; a real Android-derived cross-platform vector and provider
restoration remain open.

## Forward-only Android custody and Android-origin TON wire proof — 2026-09-24

Android [PR #1260](https://github.com/soramitsu/fearless-Android/pull/1260)
now points to pushed `33aa779eff73cdf6cbb139975e65cb9445e5d5a5`.
Room v78 adds an explicit wallet custody marker. The migration does not mark
any existing wallet: historical rows remain UNKNOWN because their public
metadata cannot distinguish a true watch-only wallet from missing signing
material. A separate, unwired enrollment path can atomically create a new
public-only wallet and WATCH marker after checking the wallet's secret
namespace and legacy V1 source inventory. Validated new signing-wallet
creation records SIGNED; an EVM-key addition invalidates stale provenance.
An unwired semantic capture emits role-8 watch slots only for a matching
WATCH marker and otherwise requires the original signing material. Named
universal public-chain watch identities still fail closed until each chain
has an appropriate public-identity proof. Historical watch-only wallets
remain an unresolved migration/recovery cohort; no existing record is
silently promoted.

On that Android source, focused migration/provenance/enrollment/preflight/
transcoder/coordinator JVM suites pass 129/129, Android migration tests
compile, and a forced Detekt scan of all 10 new Kotlin files has zero
findings. At that checkpoint the v77→v78 instrumentation test had not run;
subsequent emulator results are recorded below. A broader scan reports 523 findings in
existing legacy files, including some added-line style findings; this is
not a clean changed-file Detekt result. Exact-head hosted CI and independent
review are pending.

iOS [PR #1304](https://github.com/soramitsu/fearless-iOS/pull/1304)
now points to pushed `27418b24a745126eafcb4291fefff439f9d438a1`.
An Android-produced 604-byte `FPWMSM01` payload from a valid native TON
mnemonic is committed as an iOS test resource. Its SHA-256 is
`e0d14e7109cc5d4cb7b187ea83e8e5279b775e85d18971b2763e35a6580db302`.
iOS decodes and reencodes the exact bytes, matches the original native TON
public identity and mnemonic-derived 32-byte private seed, and passes the
read-only root-signing proof. The focused iPhone 15 simulator material and
semantic-codec suites pass 46/46 at this pushed head; project-file lint and
diff check pass. Exact-head hosted CI, native GPM/Drive ceremonies, both
replacement-device directions and an installer with original-key export
parity remain open. No feature was enabled.

Android's exact `33aa779eff73cdf6cbb139975e65cb9445e5d5a5` source also
passes `:app:compileDebugKotlin` with the pinned local Utils/WebSocket
checkouts. The v77→v78 migration instrumentation test ran on dedicated API
30, 31 and 36 emulators, one test on each with zero failures; each preserved
historical watch-shaped and signer-shaped rows as UNKNOWN. This is narrower
than the required full historical migration and Play-delivered upgrade
matrix. A direct `:app:compileReleaseKotlin` attempt stopped at the
repository's release-task provenance guard because only full release entry
tasks activate source-pin checks before project configuration. No Release
artifact or signing conclusion follows from that attempted command; the
actual upload keystore and Play-signed certificate still need operator
qualification.

The iOS PR subsequently advanced to pushed
`77f9f1dfe0338b1a3a9b7c6d503e4c3b9f3a018e`. A third unwired read-only
proof checks regular Substrate chain-account material against a caller-supplied
reviewed set of canonical genesis IDs, the recorded account ID and an
original-key local signature bound to the wallet and chain. Unapproved or
named accounts remain explicitly unproven; an approved account with a wrong
key, address or crypto type fails. The semantic format does not carry the
source chain's Ethereum-based flag, so a future caller must attest its
approved genesis set independently. Focused iPhone 15 simulator material and
semantic-codec suites pass 50/50 at this pushed head; targeted SwiftFormat,
strict SwiftLint, project-file lint and diff checks pass. This does not prove
Android-origin V2 chain bytes, every chain signer, export parity or safe
installation, and no recovery path invokes the proof.

## Portable receiving-key proof — 2026-09-24

iOS [PR #1304](https://github.com/soramitsu/fearless-iOS/pull/1304)
advanced to pushed `eff35fb6d1fd24ca38c1becd81463926ba8fb5cd`.
Its unwired read-only proof now checks Solana mainnet/devnet, TON V4R2 and
Nexus ED25519 private/public key bindings, recorded account IDs and chain
addresses, in addition to the existing Bitcoin and Taira derivation checks.
It accepts a separately imported scoped key on those chains rather
than misclassifying it as a root-derived key. A tampered private key fails.
The focused iPhone 15/iOS 17.2 material/capture/adapter/signing-proof suite
passes 41/41 on that head, with targeted SwiftFormat, strict SwiftLint
and diff checks clean.
This does not prove final signer selection, safe installation, auxiliary
source restoration or replacement-device export parity. Recovery stays off.

The iOS PR then advanced to pushed
`e849c6058c314637716354e2275e71913582a8b9`. An explicit
`MetaAccountSelectionMapper` write path now persists captured display
preferences only when a caller supplies them, applying the same bounds as
the capture path. Ordinary wallet saves leave existing preferences intact.
The combined material and mapper suites pass 51/51 on iPhone 15/iOS 17.2;
targeted production-file SwiftFormat and diff checks pass. Strict SwiftLint
on that existing mapper has the same five pre-existing findings as its prior
revision; its test file retains the same eight pre-existing SwiftFormat
findings. A scoped read-only review found no actionable issue. No production
recovery installer calls this path, and exact-head hosted CI and formal
independent security review remain pending.

The iOS PR then advanced to pushed
`f67935b8031297f303b05d5adc3f44e6173123be`. Its pure, unwired receiving
plan runs the root, reviewed-genesis Substrate and named-chain key proofs,
preserves the complete decoded wallet cohort, and records unproven sources,
chains, watch identities and the unavailable transactional installer as
blockers. It makes no Core Data or Keychain write. The exact-source preflight
suite passes 45/45 on iPhone 15/iOS 17.2. The new production file passes
SwiftFormat and strict SwiftLint; the modified test file has the same 58
SwiftFormat and six strict SwiftLint findings by rule count as its prior
revision. Project-file and diff checks pass. Hosted CI and independent
security review for this head remain open; recovery stays disabled.

The iOS PR then advanced to pushed
`9f75d56dbc4e69c8b84155905c5a147bfc73ca4a`. The receiving plan now
distinguishes a proven chain signing key from unverified optional seed/export
bytes and always blocks historical legacy Substrate source recipes. The
expanded preflight suite passed 46/46 before the final legacy guard; both
focused legacy and chain-source tests pass 2/2 on the final source. The new
production file still passes SwiftFormat and strict SwiftLint, and the
modified test file retains the same baseline rule counts. Hosted CI,
independent review and the actual installer remain open.

The iOS PR then advanced to pushed
`a97a7c69be6b9ad3da75576b92e4997eda1c0281`. A scoped read-only review
found that the receive plan did not explicitly block unmapped favorite and
metadata state, a false wallet-initialized flag, or Android chain names and
initialized flags unsupported by current iOS storage. Those now produce
separate blockers, and a valid native TON root exercises the export-source
blocker. The exact-source preflight suite passes 48/48 on iPhone 15/iOS 17.2;
the production file passes SwiftFormat and strict SwiftLint. The modified
test file retains its prior 58 SwiftFormat and six strict SwiftLint findings
by rule count. Hosted CI, formal independent security review and a real
transactional installer remain open. Recovery stays disabled.

Android [PR #1260](https://github.com/soramitsu/fearless-Android/pull/1260)
advanced to pushed `23dab9199957d7760fed87fca1290dda773888a8`.
Its unwired receiving proof verifies Android-origin Substrate ED25519,
ECDSA and SR25519 roots, standalone EVM roots, Android TON seed/phrase roots
and native iOS TON seed-plus-public/phrase roots against the original public
identity. A wrong signing key, account identity, TON address or phrase fails.
It counts legacy, chain, watch and auxiliary slots plus optional unverified
root-source fields as unproven. The JVM proof suite passes 10/10 on that
head; an API 36 arm64 emulator passes the native SR25519 proof/substitution
test 1/1; scoped Detekt on all three new files and diff checks pass.

The Android PR then advanced to pushed
`b1ff7090002b63538855bb344077c7995aab611d`. Its still-unwired proof
accepts iOS's 64-byte SR25519 scalar-plus-nonce secret and verifies exact
native vector parity with Android JNI. It also accepts iOS's 64-byte
ED25519 storage while proving only the first 32-byte miniSeed and counting
the unused suffix as unproven recovery material. An ambiguous nonce or
64-byte ECDSA secret fails. Exact-head focused JVM tests pass 12/12, and
both SR25519 device proofs pass 2/2 on an API 36 arm64 emulator. Forced
scoped Detekt on all three changed proof files and diff checks pass; a
scoped read-only review found no actionable issue. Exact-head hosted CI and
formal independent security review remain pending. This does not prove
the remaining chain and legacy slots, complete export or a safe installer,
so it is not iOS-to-replacement-Android recovery. No installer invokes the
proof.

The Android PR then advanced to pushed
`1bb014a23016844811e2d44930dac1efd7f2d1a6`. A pure, unwired receiving
plan copies and labels the full portable wallet cohort, verifies the proven
roots, and records explicit blockers for unproven material and the missing
transactional installer. It makes no storage write. Its focused JVM tests
pass 5/5; forced scoped Detekt and diff checks pass. The existing mutation
journal covers individual wallet roots, not a replayable multiwallet install
across V1/V2/V3 stores, auxiliary originals and selection. That broader
journal, key/export parity, exact-head hosted CI, and independent security
review remain open. Cross-device recovery is still disabled.

The Android PR then advanced to pushed
`29bbd53a7c0ccf186746801f0a1df92b9b694c67`. A pure, versioned
`FPWCAI01` cohort after-image binds ordered local wallet IDs to the exact
canonical semantic bytes, derives candidate V3/V2/V1 secret namespaces and
retains wallet, metadata, source, watch, selection and blocker inventories.
It rejects duplicate candidate keys, malformed wire, unsupported V2 IDs and
V1 address/public-key mismatches. It cannot stage or install a wallet. Its
focused JVM tests pass 6/6; forced scoped Detekt on the three touched Kotlin
files and diff checks pass. Cohort-wide journal replay, original-source
storage, exact-head hosted CI and independent review remain open.

The root [PR #1](https://github.com/soramitsu/fearless-release-readiness/pull/1)
at `8c814c2527ce6b4d7465a9ef9fc8c3d533b2ba93` passed its `verify`,
`verify-owner` and `validate` CI jobs. This supports that prior root commit
only; the shipping source/artifact manifest and independent reviews remain
open.

## First-owner admission and exact iOS restore writes — 2026-09-24

The root [PR #1](https://github.com/soramitsu/fearless-release-readiness/pull/1)
advanced to pushed `6f1ad83cfe09028b1d88140b64603b5b61e56fd4`. The
metadata-only owner authority now has an opt-in first-owner verifier that
requires an Ed25519 or secp256k1 wallet signature over the random owner,
challenge, RP, platform, user handle and every accepted public registration
field. A separate typed Play Integrity or App Attest input is bound to the
signed proof by an exact nonce and configured app identity. Android's
WebAuthn origin must agree with the configured Play signing certificate.
The default verifier and production HTTP still deny bootstrap; neither a
Google nor Apple attestation verifier is provisioned, SR25519 proof is not
implemented, and native interoperability and historical one-writer cutover
remain open. The final service suite passes 120/120, syntax checks and diff
checks pass. A supplemental scoped read-only review found no concrete
bypass; this does not replace the required independent security review.

The iOS [PR #1304](https://github.com/soramitsu/fearless-iOS/pull/1304)
advanced through pushed `3d56e0f72` and
`011c6ff86b816c2c1bc7b99c660093737edb1166`. An explicit Core Data
restore-write mode can now remove obsolete chain-account and asset-visibility
rows and clear an earlier native TON identity while ordinary wallet saves
retain their released merge behavior. A scoped review found stale ecosystem
metadata on retained chain rows and a duplicate-visibility regression in
ordinary saves; both were corrected in the final source. The exact-source
iPhone 15/iOS 17.2 mapper suite passes 14/14, with SwiftFormat's existing
22 findings and strict SwiftLint's existing count reduced from 12 to 11;
diff checks pass. This write mode is not wired to the portable receive plan,
has no cross-store transaction journal, and does not establish replacement-
device recovery. Hosted build CI and formal security review remain open.

The iOS PR then advanced through pushed
`1ced02e90c35f56fe49f2507a97713724686fc2b` and
`a9cb8c74f1321d9875a3d08d6e06f0d1275d6f9c`, then pushed
`1506552651b81cfa5cd6a879726501612c47b6b6`. It now has an unwired,
versioned receiving-journal record for one canonical `FPWMSM01` cohort. The
record binds the exact semantic bytes, ordered portable identities, candidate
version-4 destination wallet IDs and scoped Keychain tag digests. Its replay
classifier quarantines locked or unavailable stores, partial or mismatched keys and
database state, and committed rows that cannot be fully verified. A
staging-only cleanup result is explicitly a candidate that needs proof its
tags did not exist before staging. This is not a Keychain/Core Data writer,
and no restore path invokes it. The exact-source iPhone 15/iOS 17.2 journal
suite passes 7/7; targeted SwiftFormat and strict SwiftLint have zero
findings, and project syntax and diff checks pass. Hosted CI and formal
independent security review remain outstanding; portable recovery stays off.
The final head accepts Foundation's canonical uppercase UUIDv4 strings with
`A` or `B` variant digits while rejecting a duplicate destination UUID in
opposite casing. Earlier journal commits accepted only some uppercase UUIDs
or allowed that case-variant collision. A supplemental scoped read-only
review found the duplicate issue, which was fixed before this final head;
it does not replace independent security review.

Android [PR #1260](https://github.com/soramitsu/fearless-Android/pull/1260)
advanced through pushed `38b3e0a4a7e451ee068cc505fa0f4a49cb42c832`
to `a1e75462820fb5ac83b3a8cc4b0b369ce5f22d92`. The first commit
corrects the hosted migration-evidence verifier's stale schema-77 test
identities: it now requires all seven exact schema-78 upgrades and checks the
checked-in database version, matrix method and parameter label. The prior
hosted `build-and-test` reached and passed API 30 instrumentation, then
failed on that stale verifier; the new head must rerun hosted CI. Local
verifier fixtures pass two positive and 34 adversarial cases, and evidence
packaging passes 49/49.

The Android candidate now has an internal versioned, encrypted `FPWCJ001`
journal for one exact `FPWCAI01` multiwallet after-image. It durably stages
and revalidates the blocked cohort across restart, refuses known occupied
V1/V2/V3 namespaces and active mutation journals, and binds known target
keys plus the TON Connect and legacy journals to compare-and-swap on staging
and exact-token abandonment. A supplemental scoped read-only review found
that abandonment initially failed to bind those target keys to its atomic
comparison; the final source fixes that race and tests it. The exact-source
JVM suite passes 14/14 against clean pinned Utils
`1c80a2bf3fa1f996cf1328873e09f282ee29b69e`; forced scoped Detekt on
both new Kotlin files passes, as do syntax and diff checks. Prefix-based
namespace checks cannot reserve a wallet ID atomically; replay rejects a
later collision. This journal installs no secret or Room row and does not
remove the transactional-installer blocker. Hosted CI, formal independent
security review and replacement-device recovery remain open.

## Read-only iOS metadata receiver — 2026-09-24

The iOS [PR #1304](https://github.com/soramitsu/fearless-iOS/pull/1304)
advanced to pushed `f12d3dd72d86924b7b564ebb2c672896714e3a1d`.
The receiving plan now projects all nine shared semantic display-metadata
fields without changing the source snapshot. It preserves absent versus
explicitly empty ordered lists, decodes visibility and boolean values, and
rejects filter options that cannot fit the current Core Data model. A
missing or unrepresentable projection never clears the metadata or
transactional-installer blockers. The exact-source iPhone 15/iOS 17.2
receiving preflight and new metadata suites pass 53/53; targeted SwiftFormat
and strict SwiftLint, project syntax and diff checks pass. Hosted CI and
formal independent security review remain outstanding. There is still no
Core Data/Keychain cohort installer or replacement-device recovery proof.

## Read-only Android V2 original-key proof — 2026-09-24

Android [PR #1260](https://github.com/soramitsu/fearless-Android/pull/1260)
advanced to pushed `e0353261d0d6fa32866b5f1c7e0cdd28c8e91eb5`. An
unwired receiver component requires an explicit canonical genesis and
Substrate/Ethereum identity-kind policy. For each V2 chain account it requires
one byte-exact Android V2 original SCALE source, checks original signing and
recovery fields against the semantic slot with the production V2 validator,
and signs and verifies a wallet-, genesis- and account-bound challenge.
Unknown or wrong-kind genesis IDs and missing, duplicate, altered or lossy
originals fail closed. The exact-source focused JVM suite passes 6/6 against
clean pinned Utils `1c80a2bf3fa1f996cf1328873e09f282ee29b69e`; forced
scoped Detekt and diff checks pass. SR25519 native-provider/device proof,
iOS-specific chain originals, a reviewed compiled policy, installed-key
signing/export and the cohort installer remain open. The receiving and
backup-completion blockers have not changed, and hosted CI and independent
review remain pending.

## Exact iOS new-wallet restore order — 2026-09-24

The iOS [PR #1304](https://github.com/soramitsu/fearless-iOS/pull/1304)
advanced to pushed `15dae3bcdf01e882a6a6754010d7d562bc69838b`.
For a new Core Data wallet row in exact-replacement mode with an explicit
cohort order, the mapper now persists that order instead of assigning the
next local order. Ordinary new-wallet saves retain their append behavior.
The exact-source iPhone 15/iOS 17.2 mapper suite passes 15/15, including
the order regression. The modified existing files retain their prior lint
baseline; the source diff check passes. This mode still requires a verified
receiving cohort and transactional Keychain/Core Data installer before use.

## iOS cohort-order allocation — 2026-09-24

The iOS [PR #1304](https://github.com/soramitsu/fearless-iOS/pull/1304)
advanced to pushed `c3bd41f547eef1cb3fce83073b0cc3383ab76dda`.
The portable semantic record sequence is authoritative while historical
`sourcePosition` values may tie or exceed the Core Data signed-order range.
The read-only receive plan now allocates fresh positive, unique orders after
the observed existing maximum, rejecting invalid existing values and
overflow. Exact new-wallet writes reject orders beyond `Int32.max`; ordinary
new-wallet saves keep append behavior. The future installer must read and
recheck existing orders inside its writer/transaction boundary. Exact-source
iPhone 15/iOS 17.2 mapper, metadata and receive-preflight suites pass 70/70;
targeted new-file lint and diff checks pass. The source still has no cohort
Keychain/Core Data installer or replacement-device recovery proof.

## Sealed historical credential cutover comparison — 2026-09-24

The non-deployed owner authority now has an offline read-only verifier for a
private, digest-named schema-3/4 JSON challenge-store image against schema-5
SQLite. It parses the exact bytes whose SHA-256 was checked and compares all
historical storage keys, empty tombstones, public credential bytes, user
handles, counters, backup/revocation flags, metadata, wallet-key scopes and
source commitments. It reports extra or missing rows and split or merged
owner aliases without emitting credentials or raw owner subjects. The
verifier always returns `migrationPermitted: false`: representation equality
cannot prove the historical hash-to-random-owner link, drain the live JSON
writer or authorize recovery. Its CLI exits blocked on a valid report.
The source reader rejects shadowed JSON members, and the SQLite reader pins a
private descriptor so pathname replacement cannot substitute target rows.
Local owner-authority tests pass 150/150 and the challenge-service suite
passes 112/112; syntax and diff checks pass. Fresh legacy-credential
assertion plus random-owner proof, reviewed one-writer cutover and production
admission still remain required.

## Interrupted SQLite writer safety — 2026-09-24

A scoped Codex Security diff scan of root `55b503a95b45353542d4298671529b857c4b5d6d`
through `3a7cdad707c224ddd361fb9c2e1537bfdd87e53d` reviewed six changed source files.
It had no reportable security finding under its operator-only reachability
policy, but a disposable macOS/Node SQLite reproduction showed an offline
integrity defect: reading the owner DB through a checked fd alias can miss a
hot rollback journal at the canonical path and see uncommitted rows. The
reader now refuses `-journal`, `-wal` and `-shm` sidecars before and after its
transaction, so interrupted databases must first be recovered through their
canonical path. Focused sidecar and migration tests pass 16/16; the combined
owner-authority suite passes 154/154 with syntax and diff checks clean. This
repair is not a production owner cutover or a substitute for independent
review. Linux/deployment-image journal behavior and full owner-v5 crash
recovery still require qualification.

## Journal-bound iOS Keychain receive projection — 2026-09-24

The iOS [PR #1304](https://github.com/soramitsu/fearless-iOS/pull/1304)
advanced to pushed `8e6a5798fe8f648423fa0a313c1ee49e32a57e78`.
A read-only receiver now projects captured released iOS Keychain source bytes
onto fresh destination tags. It requires the canonical semantic cohort and
fresh wallet IDs to match the durable journal, and requires every projected
tag and SHA-256 digest to equal the journal's complete key inventory. It
rejects missing, duplicate, oversized, conflicting root signer and
unsupported Android-source items. The separately preserved Bitcoin/Taira
root-derived signing recipe remains distinct from a historical scoped key.
The exact-source iPhone 15/iOS 17.2 focused suite passes 6/6; the full app
compiled, targeted SwiftFormat/SwiftLint and project-file checks pass. This
projection writes no Keychain or Core Data item and does not prove an
installed wallet's signing/export behavior. The transactional installer,
Android-source mapping, replacement-device recovery and independent review
remain open.

## iOS root-source coverage in receive projection — 2026-09-24

The iOS [PR #1304](https://github.com/soramitsu/fearless-iOS/pull/1304)
advanced to pushed `66523499dfbde61828677f39dfd04153fdfb8116`.
The journal-bound Keychain projection now rejects a cohort if an active
Substrate or EVM root lacks its original signer item, or a native TON root
lacks its required phrase item. It also rejects wallet-wide entropy that
disagrees with the corresponding signed root field. Candidate destination IDs
are not considered fresh until an installer proves they are unoccupied under
its writer lock. The exact-source iPhone 15/iOS 17.2 focused suite passes
7/7; targeted SwiftFormat, strict SwiftLint and diff checks pass. This still
does not write a destination, prove every optional export source, or qualify
replacement-device recovery.

## Android API 34 current-schema instrumentation — 2026-09-24

The Android [PR #1260](https://github.com/soramitsu/fearless-Android/pull/1260)
advanced to pushed `4e812d5849cc97c30fb22dc4e442840347b0c87a`.
The preceding hosted `build-and-test` job failed 60 core-db and five account
API 34 instrumentation cases because current-version assertions expected
schema 77 after the candidate advanced to schema 78. The affected tests now
use the current database-version constant or schema 78 target as appropriate;
one named current-version startup fixture now creates the current schema.
Pinned Utils/WebSocket source checks and Android test-source compilation pass.
The local API 34 connected run passes core-db 301/301 and
feature-account-impl 12/12, with a focused 1/1 rerun after the final fixture
edit. The later hosted Android head fails for a separate discovery-test
portability issue, recorded below, so the CI gate remains open. These test
corrections do not qualify API 36, 16 KiB native binaries,
release signing or distribution upgrades.

## Android Asset Hub to Moonbeam USDt discovery inventory — 2026-09-24

Android [PR #1260](https://github.com/soramitsu/fearless-Android/pull/1260)
advanced to pushed `df22529b75d078d378bbf1bbcb06c1fee9700e67`.
A read-only, source-digested report now binds the bundled chain registry,
frozen discovery-only gap, approved and required route lists, and production
evidence for Polkadot Asset Hub to Moonbeam USDt. It records the advertised
USDt route, the origin Asset Hub asset with six decimal places, and Moonbeam
`xcusdt` as a possible destination asset without treating that mapping as
verified. The focused drift test and local registry/production-evidence gates
pass locally; the exact-head hosted `validate` job passes. Hosted
`build-and-test` fails because the new discovery test invokes `rg`, which is
not installed on that runner. Later migration-evidence steps also report
missing markers after the early failure; they do not establish completed
instrumentation. IAS validation has not passed. This route remains
discovery-only,
unapproved for execution and `releaseEnabled=false`. Canonical chain-state
asset mapping, runtime call and fee review, capped funded receipts and
independent route approval remain required. The report does not authorize
signing or submit a transfer.

At that checkpoint, the pushed iOS source was
`66523499dfbde61828677f39dfd04153fdfb8116` on
[PR #1304](https://github.com/soramitsu/fearless-iOS/pull/1304). Its hosted
`validate`, `release-contracts` and `ios-release-safety` jobs pass, while
`build` has not passed yet. The iOS receive projection and both platform
candidates remain non-shipping until their remaining recovery, security, device and
distribution gates pass.

## Mobile candidate update — 2026-09-24

Android [PR #1260](https://github.com/soramitsu/fearless-Android/pull/1260)
advanced to pushed `1f5228513ded1ef42e18a33bd8ac881c688f09df`.
The Asset Hub to Moonbeam USDt discovery drift test now uses portable `grep`
instead of the runner-unavailable `rg`. Its local focused suite passes,
including fail-closed drift cases. Exact-head hosted `validate` passes;
`build-and-test` and IAS validation are in progress and have not passed.
The prior `df22529...` CI failure remains historical evidence, not a pass for
this source. The route remains discovery-only, unapproved for execution and
`releaseEnabled=false`. Canonical asset mapping, reviewed runtime call and
fees, capped funded receipts and independent route approval remain open.

The iOS [PR #1304](https://github.com/soramitsu/fearless-iOS/pull/1304)
advanced to pushed `f4189ad1e5794d2841fc638a9651c5cac4c0639d`.
Its read-only Keychain projection now requires every recorded root entropy,
seed and derivation-path export field to have a byte-matching original iOS
source item. A native TON root must carry its mnemonic field and the matching
phrase item; absence or conflict blocks projection. The exact-source iPhone
15/iOS 17.2 focused suite passes 9/9, with targeted SwiftFormat, strict
SwiftLint and diff checks passing. Exact-head hosted `validate` passes;
`release-contracts` and `build` have not passed yet. The projection still
does not install a cohort, prove all receiving export/signing behavior or
establish replacement-device recovery. Independent review remains required.

## Android Etherscan V2 history — 2026-09-24

Android [PR #1260](https://github.com/soramitsu/fearless-Android/pull/1260)
advanced to clean, pushed `bbd9f34f4fc137444ce01defe45d5ba57e5b766c`.
Bundled Ethereum, BNB Smart Chain, Sepolia and Polygon Etherscan-family
history now uses the V2 endpoint with an explicit chain ID and one unified
key. Goerli and Mumbai are rejected as retired provider chains. Independently
configured HTTPS Etherscan-compatible explorers remain available for known
and other chains without receiving the unified key. Official host matching
normalizes case and a trailing DNS dot before enforcing chain binding.
Provider errors, malformed data, missing keys and transport failures now
propagate to the history retry path without replacing cached operations or
cursor state with an empty result. Exact-source focused tests pass 11/11 and
`detektAll` passes; the branch and PR identify this head. Hosted `validate`
passes, while `build-and-test` and IAS validation have not passed at this
checkpoint. Real Etherscan V2 account/key provisioning, live BNB/ETH/Polygon
history and failure/retry checks, and Play-signed acceptance remain open.

## iOS Etherscan V2 history and Drive account consent — 2026-09-24

The iOS [PR #1304](https://github.com/soramitsu/fearless-iOS/pull/1304)
advanced to clean, pushed `27dada4d641fca02b94fb20a38fc49534c761635`.
The preceding `185698b8035afab40cbf58b258e13e978f1c5c41` added a mandatory
selected-Google-account confirmation callback to native Drive consent, then
rechecks the current account, OAuth client, scope and token. The focused
iPhone 15/iOS 17.2 Drive suite passed 28/28. No enabled screen invokes that
callback, and same-project OAuth/provider interoperability remains unproved.

At the current head, known Etherscan-family history hosts, including BNB
mainnet, use `https://api.etherscan.io/v2/api` with a host-bound chain ID and
the unified Etherscan key. Independent Etherscan-compatible explorers keep
their own endpoint and receive no unified key. Non-2xx responses and provider
errors no longer become successful empty histories; only an explicit
no-transactions response does. The Release service audit now treats the
retired chain-specific explorer keys as optional. A provider failure now
shows the existing localized service-unavailable state when no history is
cached; later refresh failures retain cached transactions and retry. The
preceding `889a6162681ce55a0e42764497e5530023aaf979` iPhone 15/iOS 17.2
suite passed 8/8, while the V2-only head passed 7/7. The synthetic Release
configuration audit passed 33/33 before the latest provider-only edit.
SwiftFormat, project syntax and diff checks pass; the new Etherscan/Kaia
provider files pass strict SwiftLint, while modified historical UI/OKLink and
test files retain existing lint findings. The preceding `9253552` head passed
hosted `validate`, `release-contracts` and iOS release-safety; its `build` job
has not passed. Exact-head `validate` passes for `27dada4`, while its
`release-contracts` and `build` jobs are pending. Live API-key/provider
qualification, device history/retry behavior and independent review remain
open. The historical Goerli and Mumbai aliases may require provider
replacement if V2 rejects those retired testnets; no such live evidence has
been claimed. The
preceding JSON-only follow-up corrects the X Layer mainnet and testnet explorer
fallback templates to their respective OKX routes; JSON parsing and exact
route assertions pass. The historical X Layer testnet row still identifies
chain `195`, while current OKX documentation identifies testnet `1952`.
Changing that wallet chain identity needs a migration review, so the mismatch
remains a gate. The latest source also rejects non-2xx HTTP responses and
provider-declared failures from Kaia and OKLink history instead of treating
them as empty pages. Its exact-source iPhone 15/iOS 17.2 history suite passes
10/10. A separate read-only review found no definite compile defect but
confirmed that these model fixtures do not prove live HTTP-to-UI/cache
recovery. The old Kaia Scope endpoint needs migration to KaiaScan OAPI and
real provider-response qualification; current OKX authentication and X Layer
history still need live checks. Neither provider is claimed production-ready.

## Android history failure handling and iOS KaiaScan candidate — 2026-09-24

Android [PR #1260](https://github.com/soramitsu/fearless-Android/pull/1260)
advanced to clean, pushed `9180bc535a55ad93f79c16e53b1f17a16364c82b`.
OKLink and legacy Klaytn history no longer turn transport, provider or
malformed-page failures into successful empty pages. The OKLink mapper now
binds native history to the native symbol and token history to the exact
contract, rejects precision loss, and uses the native utility asset's units
for a token-transfer fee when known. The bundled X Layer explorer templates
now distinguish mainnet and testnet. Focused history tests pass 7/7, the
wallet module passes 202/202, and `detektAll` passes but excludes that
module. Live authenticated provider, freshness, pagination and on-device
retry/explorer checks remain open. The historical X Layer testnet chain ID
has not been changed without a wallet-identity migration.

Before that patch, the clean Android head
`bbd9f34f4fc137444ce01defe45d5ba57e5b766c` built an unsigned,
source-bound release AAB against the pinned Utils and WebSocket checkouts,
Android SDK 36 and JDK 21. Artifact SHA-256
`f958b9c6da5c55228db7ca107b736f1006ddf668b30206a8f8810f6091c183bc`
passed the structural native check for all 16 libraries across four ABIs at
16 KiB alignment. That AAB predates `9180bc535` and is not a Play-signed
or accepted distribution artifact. The clean `9180bc535` head then built an
unsigned intermediate AAB with SHA-256
`90fdb72e05b4db15192ac474983a535f90e0834d08f7e899278db4b5cfe5d745`;
the same structural verifier passed 16 native libraries across four ABIs at
16 KiB alignment. The source-pin check and Release/R8 build passed. Real
16 KiB-device startup/crypto, externally signed distribution and upgrade
acceptance still need qualification.

iOS [PR #1304](https://github.com/soramitsu/fearless-iOS/pull/1304)
advanced to clean, pushed `3bfc8ead4716a7eae95abf60f68a7bfa01071ec8`.
The native Kaia history source uses the documented KaiaScan account
transaction and token-transfer feeds with a separately configured Bearer key,
exact decimal amounts and fees, page validation, contract matching and
fail-closed provider responses. Its iPhone 15/iOS 17.2 focused suite passes
15/15 and the synthetic Release configuration audit passes 33/33. Exact-head
hosted checks and independent review are pending. No live authenticated
KaiaScan response, funded transfer/fee reconciliation, freshness or device
retry result has been established; the provider key is not provisioned here.

The iOS follow-up at clean, pushed
`e617c1e998241a963ee0bcaacd056d5014c836a4` excludes a Kaia row where
the wallet appears only as `fee_payer` from transfer amounts. Without that
guard, a delegated fee for someone else's transaction could appear as an
incoming wallet transfer. It also rejects inconsistent page totals and
unknown provider statuses. The exact-source iPhone 15/iOS 17.2 Kaia suite
passes 7/7, and SwiftFormat plus strict SwiftLint pass on the changed source
and test file. Fee-only activity presentation and funded fee reconciliation
remain release gates; the exact-head hosted checks and independent review
are still pending.

## Completion record

No subgoal is complete yet. No new build has been uploaded or deployed, no production feature has been enabled, and no funded transaction has been submitted by this implementation run.

## Next active work

- Finish Android independent review, green CI, full Release/R8/AAB, API36/16KiB, native-device and Play-upgrade qualification. Scoped key/sign/send implementation and phase4 verification are recorded above; these do not complete device or distribution acceptance.
- Obtain independent review and green CI for the published iOS key/sign/send boundary; qualify exact signed transaction bytes, fees, hashes, receipts, node changes and distribution artifacts. The 463-test development pass does not satisfy enabled-feature or store/device acceptance.
- Generate and bind the full route inventory and shared shipping manifest, then finish portable native PRF/Drive recovery and owner/grant issuance. Existing credentials and wallet identities remain preserved.
