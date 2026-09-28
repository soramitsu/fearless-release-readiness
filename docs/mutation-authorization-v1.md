# Fearless mutation authorization v1 (shared Android/iOS contract)

This is a contract and test-only fixture bundle, not production authority.

Remote configuration field: `mutation_authorization` on both platforms.

Wire: FWMA1.<keyId>.<payloadBase64url>.<signatureBase64url>. Exactly four segments, no whitespace, maximum 8192 ASCII bytes. keyId matches [a-z0-9-]{1,64}. Base64url is unpadded and canonical (decode/re-encode equality). Signature is 64 bytes; trusted public key is 32 bytes.

Signature: pure RFC8032 Ed25519 over UTF8("FearlessWallet-MutationAuthorization-v1\n" + keyId + "\n") concatenated with the decoded payload bytes. Do not use Ed25519ph or Ed25519ctx.

Payload: canonical ASCII JSON, no BOM, no whitespace, exactly the following fields IN THIS ORDER: schema, audience, environment, minAppVersion, maxAppVersion, policySha256, routeManifestSha256, revision, issuedAt, expiresAt, capabilities. Schema is string "1". Audience is the exact production application package/bundle identifier; environment is exact "production". Audience grammar [A-Za-z0-9.-]{1,128}. Both SHA256 values are exactly 64 lowercase hexadecimal characters. All integral wire values are strings: canonical nonnegative decimal with no leading zeros, at most signed 64-bit MAX. App version bounds are inclusive positive build numbers, min<=max; revision is positive. Timestamps are Unix seconds in 0..253402300799.

Capabilities is a closed object IN THIS ORDER: demeter, polkamarkt, polkaswap, polkaswapBridge, xcm. Each value is a JSON boolean. Parse then rebuild this exact canonical representation and require byte equality: duplicate/unknown fields, escapes, alternate ordering, number-valued integers, leading zeros and whitespace are rejected.

Acceptance: trusted key, signature, expected audience/environment, current app version bounds, exact locally reviewed policySha256 and routeManifestSha256 must all match. Require issuedAt<=now+60, issuedAt<expiresAt, now<expiresAt, and expiresAt-issuedAt<=900 seconds. Enabling also requires compiled approval; tokens never supply execution metadata or replace per-route evidence.

State: persist the greatest accepted revision and its payload SHA256 atomically and durably before granting. Reject lower revisions and same revision with a different payload digest; identical current revision may refresh but never extend beyond its signed expiry. A failed or ambiguous durable write poisons authority until process restart because the higher revision may already have reached disk. Persist a maximum observed wall-clock value; a rollback beyond 60 seconds denies. Start every process denied until a fresh network fetch verifies. Within a process preserve the earliest monotonic deadline for an identical payload across failed refreshes and invalidation; reacceptance after failure creates a new lease generation. Enforce elapsed-time expiry as well as wall expiry, and invalidate leases on an accepted changed authorization or failed refresh. Invalid/missing/unavailable refresh clears active grants but never reduces the durable high-water mark. Refresh every 300 seconds; no persistent boolean grants.

Operation leases bind capability, payload digest/revision, local policy/route manifest and transaction-intent digest. Check before key access, immediately before signing and at transport submission enqueue; changed authorization, expiry or revoke aborts. Serialize the final check with authorization updates at the enqueue boundary; bytes already handed to transport cannot be recalled.

Production trust: only operator-approved keys bundled in the reviewed release manifest; no downloaded keys, fabricated production signer or fallback. An absent production key/policy is denied. Read-only and legacy paths stay independent.

Test vectors use only the public RFC8032 TEST1 fixture key. The valid payload variants deliberately reuse revision 42 with different bytes to test same-revision substitution rejection in the state machine. Their independent verification results do not authorize replacing a previously accepted revision 42 payload.

Android composition: immutable `mutation_authorization_trust.json` contains schema, policySha256, routeManifestSha256 and key-ID to raw-public-key hex mapping. `mutation_authorization_policy.json` binds schema, audience, environment, exact appVersion and compiled capability booleans. `mutation_route_manifest.json` binds the actual bundled approved_xcm_routes.tsv and local_chains.json hashes. The installed PackageManager package name and versionCode must match the reviewed policy exactly. iOS must bind its exact artifact version via a reviewed canonical mapping; an arbitrary version ordinal is never acceptable. A missing production key or digest denies all new capabilities.

Scope: existing legacy Polkaswap (and historical Android Demeter) behavior stays independent. Wire capabilities for these names are reserved for expanded behavior. Additional bridge/catalog policy coverage is a provisioning prerequisite. The Android verifier/state/refresh checkpoint supplies intent-bound leases but does not yet wire final key/sign/actual-send boundaries; asynchronous transport guarding remains a required implementation phase.


## Release and integration requirements

Android binds the actual installed package and versionCode to its compiled policy.
iOS additionally binds the exact CFBundleVersion string to a reviewed positive
build ordinal in its bundled policy. A different source build, package or version
must not reuse that binding. The unified shipping manifest must bind the policy,
route inventory, trust resources and compiled source; resource hashes alone do
not prove that the corresponding source was reviewed or shipped.

The JSON vectors in `config/fixtures/mutation-authorization-v1.json` are test-only.
They must never be used as production trust or copied into application resources.
The iOS test target carries an identical copy; Android consumes the same bytes in
its test resources. No production signing key has been provisioned by this work.

The state machine preserves the continuous-time deadline for repeated payloads
even across refresh failures. A failed or ambiguous durable write poisons that
process's authority until restart, which must reload durable high-water state
and perform another verified fetch. Expiry observations also advance the durable
wall-clock high-water mark before denial. A failed capability check alone does
not revoke unrelated allowed capabilities.

Intent leases and the synchronized enqueue API are primitives, not proof that
every application's async signing and transport path uses them. Both platform
integrations must check at actual key access, signature creation, and the final
socket/network send; a check before an asynchronous SDK enqueue is insufficient.
These boundary integrations and provider/device tests remain release gates.


Durable writes may block. A final check must acquire its authority lock before
sampling, persist any increased wall-clock high-water value, and sample again
after each write. After three unstable samples it denies; it must never grant
from a sample taken before a blocking save. Token acceptance rechecks freshness
after persisting the revision, without extending the deadline by persistence
time. Effective expiry uses the greatest observed wall time, so a permitted
small clock correction cannot revive an expiry that was already observed.

At transport handoff, perform frame serialization, masking and blocking writer
lock acquisition before entering the application authorizer. A final operation
state check may only use a nonblocking commit; contention denies the write.
Cancellation must still prevent a dequeued request while its writer waits for
authority. Once the OS has accepted bytes, cancellation or transport failure
requires unknown-outcome reconciliation; no automatic replay is permitted.
