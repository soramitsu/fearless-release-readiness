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
wrong branches or HEAD commits, missing dependencies, route or feature-policy
digest changes, substituted artifacts, and changed raw evidence. It allows
Iroha only at the existing `optimizations` checkout. Synthetic tests in
`node --test scripts/test-release-shipping-manifest.mjs` exercise clean and
tampered inputs; a passing synthetic test is not release evidence.

The canonical file is a UTF-8 JSON object with recursively sorted keys,
two-space indentation and one final newline. Its closed schema is enforced by
the audit script:

| Field | Required binding |
| --- | --- |
| `schemaVersion`, `releaseId` | Version 1 and an immutable release identifier. |
| `root` | Repository, selected branch and exact clean root source commit from the root-owner contract. |
| `repositories` | Every selected source-publication row in order, including Android, iOS, web, site, TI, SI, PI and Iroha; each row has its own exact clean HEAD. |
| `dependencies` | Clean, exact source commits for Android Utils/WebSocket and iOS shared-features/Starscream. |
| `files` | Digests for passkey policy, Android mutation policy/trust/route manifest and dependency lock/verification files, plus iOS package/pod locks. |
| `routeInventories`, `featurePolicies` | Android source-route/policy digests and iOS compiled-route/policy extraction digests, bound to the corresponding file or raw evidence row. |
| `android`, `ios` | Exact mobile source commits, distribution artifact SHA-256 values and compiled passkey-recovery approval. |
| `distribution` | Android package, Play signing-certificate SHA-256, Apple bundle ID and team ID. |
| `artifacts` | Exact hashes, retained paths and source commits for Android AAB, Play-distributed APK, Apple-delivered IPA and new Android/iOS Iroha SDK packages. |
| `evidence` | Exact hashes and retained paths for both replacement-device directions, Drive interoperability, secret-leak inspection, signed upgrades, independent security review, funded transfers, migration/restart, services and compiled iOS route/policy extraction. |
| `googleApplicationId`, `passkeyConfigSha256` | One Google application identity and the exact root passkey production-policy bytes. |

Artifact and evidence paths must be regular nonsymlink files under
`build/reports/`; the manifest references their bytes by SHA-256. The source
publication and platform artifact audits must independently establish that the
named builds came from those commits and that the compiled-route/policy files
were actually extracted from the exact distributed artifacts. This validator
binds the inputs; it does not manufacture a store signature, route receipt,
provider ceremony, review approval or deployment proof.

No shipping manifest has been generated for the current disabled candidates.
Its required enabled policy, actual distribution artifacts, Iroha signed source,
clean dependency checkouts, two-direction device recovery, and independent
attestations are still missing. Leaving the file absent keeps the full-live
gate red rather than accepting historical or placeholder evidence.
