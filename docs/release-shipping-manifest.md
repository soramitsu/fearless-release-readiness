# Shipping manifest contract

`config/release-shipping-manifest.json` is the single **detached release artifact**
for the final Android and iOS distribution pair. It is deliberately ignored by
Git: a committed manifest cannot contain its own final root commit SHA. Reviewers
must examine the exact canonical JSON bytes, then sign or attest their SHA-256
digest as part of the enabled-feature acceptance record. The manifest and raw
evidence must be retained with the release record. A source commit or old binary
cannot be substituted after attestation.

The production-only `node scripts/audit-release-shipping-manifest.mjs` takes no
path overrides. It runs before passkey acceptance in the full-live audit. It
rejects a missing or noncanonical manifest, unexpected fields, dirty checkouts,
wrong branches or HEAD commits, missing or differently pinned dependencies,
route or feature-policy digest changes, substituted artifacts, and changed raw
evidence. It allows Iroha only at the existing `optimizations` checkout.
Synthetic tests in `node --test scripts/test-release-shipping-manifest.mjs`
exercise clean and tampered inputs; a passing synthetic test is not release
evidence.

The canonical file is a UTF-8 JSON object with recursively sorted keys,
two-space indentation and one final newline. Its closed schema is enforced by
the audit script:

| Field | Required binding |
| --- | --- |
| `schemaVersion`, `releaseId` | Version 1 and an immutable release identifier. |
| `root` | Repository, selected branch and exact clean root source commit from the root-owner contract. |
| `repositories` | Every selected source-publication row in order, including Android, iOS, web, site, TI, SI, PI and Iroha; each row has its own exact clean HEAD. |
| `dependencies` | Clean, exact source commits for Android Utils/WebSocket and iOS shared-features/Starscream, cross-checked against each mobile candidate's build pins and dependency source contracts. |
| `files` | Digests for passkey policy, Android mutation policy/trust/route manifest, approved/required/discovery-gap routes, local chains and dependency lock/verification files, plus iOS package/pod locks. |
| `routeInventories`, `featurePolicies` | Android route-manifest, approved, required, discovery-gap and local-chain digests plus policy digests; iOS compiled-route/policy extraction digests, bound to the corresponding file or raw evidence row. |
| `android`, `ios` | Exact mobile source commits, distribution artifact SHA-256 values and compiled passkey-recovery approval. |
| `distribution` | Android package, Play signing-certificate SHA-256, Apple bundle ID and team ID. |
| `artifacts` | Exact hashes, retained paths and source commits for Android AAB, Play-distributed APK, Apple-delivered IPA and new Android/iOS Iroha SDK packages. |
| `evidence` | Exact hashes and retained paths for both replacement-device directions, Drive interoperability, secret-leak inspection, signed upgrades, independent security review, funded transfers, migration/restart, services and compiled iOS route/policy extraction. |
| `googleApplicationId`, `passkeyConfigSha256` | One Google application identity and the exact root passkey production-policy bytes. |

Artifact and evidence paths must be regular nonsymlink files under
`build/reports/`; a retained path cannot represent more than one artifact or
evidence kind. The manifest references their bytes by SHA-256. The source
publication and platform artifact audits must independently establish that the
named builds came from those commits and that the compiled-route/policy files
were actually extracted from the exact distributed artifacts. This validator
binds the inputs; it does not manufacture a store signature, route receipt,
provider ceremony, review approval or deployment proof.

The Android route check reads the frozen route inputs from the exact clean
Android checkout. Required routes must equal the compiled approved routes,
the compiled route manifest must bind the approved routes and local chains by
hash, and the discovery-gap file must have no active entries. Any remaining
discovery-only route blocks this final shipping manifest. The current Android
candidate still has such gaps, so this check is expected to fail until their
reviewed execution semantics and independently verified transfers are complete.

Dependency rows alone are insufficient: a clean, wrong checkout can satisfy its
own manifest row. The Android Utils row selects the separate clean
`fearless-utils-Android-production-20260922` checkout. Both Android dependency
commits, repositories and Git trees must match the checked-in
`config/android-runtime-source-pins.json` in the exact Android source commit.
Both iOS dependency commits and Git trees must match the checked-in
`config/shared-features-source.json` and `config/starscream-source.json` in the
exact iOS source commit. Their revisions and repository URLs must also match
both workspace and project `Package.resolved` pins. The app's Swift package and
Xcode project declarations must select that shared-features revision, and the
shared-features package must select the same Starscream revision. Dependency
checkouts must have no assume-unchanged or skip-worktree index flags that could
hide modified tracked bytes. Each must have exactly one configured and one
effective `origin` URL for its expected GitHub repository; the effective check
catches local URL rewrites. A remote URL alone is not proof of source
authenticity. The platform source audits still verify the dependency contents
and resolved build graph independently.

No shipping manifest has been generated for the current disabled candidates.
Its required enabled policy, actual distribution artifacts, Iroha signed source,
clean dependency checkouts, two-direction device recovery, and independent
attestations are still missing. Leaving the file absent keeps the full-live
gate red rather than accepting historical or placeholder evidence.
