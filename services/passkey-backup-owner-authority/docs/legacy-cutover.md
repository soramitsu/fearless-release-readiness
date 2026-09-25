# Legacy credential cutover: admission contract

This is a design for a future, reviewed migration. **No live credential route is
converted or admitted by this document.** The current challenge HTTP process
writes schema-4 JSON after separate grant introspection; the owner authority
uses schema-8 SQLite. Its local HTTP candidate requires explicit test admission
and rejects production construction. The read-only reconciliation
report always denies migration. Its two file snapshots are sequential and are
not proof of ownership or an atomic cross-store view.

## Required proof before a historical storage key can be linked

An existing JSON `ownerSubjectHash`, Google account, Drive file, credential ID,
user handle or matching database row cannot establish the random owner. The
link ceremony must require both of the following, bound to one fresh nonce,
the exact storage key, legacy owner-subject hash and credential ID, a sealed
JSON snapshot digest, the random owner subject, RP, platform and expiry:

1. A current random-owner session established by a verified owner credential.
   First-owner creation also requires local original-wallet possession and app
   attestation under a reviewed, domain-separated challenge. The currently
   optional verifier deliberately denies that production bootstrap.
2. A fresh WebAuthn assertion from a credential in the historical JSON record,
   verified server-side against that record's exact COSE public key, historical
   user handle, sign counter, RP, qualified platform origin, challenge and
   user-presence/user-verification flags. Claim the nonce once before asynchronous
   verification. Recheck the owner session generation and claimed nonce under
   the SQLite writer lock; compare the verified counter and public-key identity
   with the sealed, read-only legacy record before committing its future import.
   A credential
   which cannot complete this proof must remain recoverable through the old
   path until an independently reviewed possession path is available; it must
   not be silently assigned to a new owner.

The proof must be recorded as non-secret metadata bound to the sealed source
digest and exact public credential cohort. It must not contain a recovery phrase,
private key, PRF output, backup key, Google token or decrypted backup. A proof
for one storage key must not authorize another, even if account names match.

Schema v7 introduced the preparation state machine, retained by v8:
an internal API issues two role-separated challenges bound to the sealed JSON
digest/name, historical storage key and owner hash, source credential ID,
public-key digest, counter, user handle and scope, random owner/session and
credential counter, RP, platform, nonce and expiry. A single-use claim stores
only hashes of the two typed public responses before asynchronous verification;
a subsequent burn rechecks those hashes and the exact sealed source under the
SQLite writer lock. At most 128 rows globally and eight per owner are retained.
Challenges can be used for at most two minutes; unverified claimed and consumed
rows remain replay tombstones until expiry even after session revocation.
Verified rows and their challenge metadata remain retained after expiry for
audit. Neither step verifies a
WebAuthn signature, establishes an owner link, imports a credential or permits
migration. Pending claims for a storage key and historical owner must use the
same sealed source digest and random owner; a commit that crosses expiry cannot
return successful claim or consume authority. An ID-directed assertion may omit
its user handle, but any supplied handle must match the stored credential.

The internal `verifyAndConsumeLegacyCutoverClaim` path claims both exact
public responses before asynchronous work, reads the historical COSE key,
handle and counter from the independently SHA-pinned sealed JSON bytes, and
reads the current owner credential from SQLite. The server-owned
`createWebAuthnVerifier` adapter verifies both distinct challenges, response
IDs, RP, configured qualified platform origin, UV/UP, signatures and counters
with `@simplewebauthn/server`. After verification, the core reopens the sealed
source and rechecks the response commitments, live session and generation,
revocation, credential public key, handle and counter under the SQLite writer
lock before committing a schema-v8 proof row and the owner authenticator's
new counter in one SQLite transaction. A failed signature leaves a claimed
replay tombstone until expiry. Schema v8 records the validated legacy and owner
new counters, exact source and response hashes, both challenge hashes,
verification time and a domain-separated SHA-256 consistency commitment. The
proof row is immutable and distinguishable from `consumeLegacyCutoverClaim`,
which writes no proof. A v7 consumed row migrates without proof and the insert
trigger will not add one after its state-2 burn. Startup and offline readers
recompute commitments against the retained challenge. A counter change,
revocation, source substitution or expiry observed during the locked recheck
prevents proof. A slow commit can cross expiry after that check: the proof and
counter update then remain durable while the caller receives
`authorization_expired`; that response never grants migration authority. A
verified row remains for audit after expiry, with an intentional 128-row
lifetime cap for this non-deployed preparation path. The digest is **not** a
cryptographic signature transcript, bearer token, owner link or import
authorization; the method always returns `migrationPermitted: false`. A future
reviewed importer must separately establish the drained source cohort and
commit the owner link and historical credential cohort atomically.

## Cutover transaction and admission

1. Stop and drain the sole JSON writer and all outstanding challenge/grant
   requests. Take a private, durable schema-3/4 snapshot and record its digest.
   Reconcile every credential, owner tombstone, ID, counter, backup flag,
   AAGUID, transport and platform field. Reject unknown schema, duplicate ID,
   conflicting owner hash, missing proof, changed snapshot or an owner binding
   already claimed by another namespace. Never initialize an empty database to
   bypass failure.
2. SQLite schema v8 has storage-key→random-owner binding and capacity for
   complete historical public metadata and zero-credential tombstones. It
   preserves credential-scoped historical user handles in `credentials` rather
   than replacing them with `owners.user_handle`, and records explicit owner-wide
   or wallet-key credential scope. No legacy row or owner link
   has been imported. A future reviewed importer must verify the proof and
   source digest, then import a proven cohort and its proof commitment in one
   durable SQLite transaction with collision and counter checks. Retain an
   encrypted, immutable pre-cutover snapshot for audit and forward recovery.
   Import is not a Google-account operation.

   The offline `quarantineLegacyCredentialSnapshot` tool can now capture an
   exact, digest-checked, schema-validated private JSON image and report a
   redacted read-only reconciliation. It requires an independently supplied
   expected digest and refuses to overwrite a duplicate image. It cannot prove
   that the JSON writer was stopped, cannot establish a random owner, and
   cannot import or activate a credential. Its file remains an operator-held
   snapshot; future admission must verify its digest again against a durable
   cutover manifest and collect the two fresh ownership proofs above.

   The offline `verify-sealed-legacy-cutover.mjs` command now checks a private
   `legacy-<sha256>.json` image against its independently supplied digest and
   compares **every** source storage key, empty tombstone, credential ID,
   COSE public key, historical user handle, counter, device/backup/revocation
   state, AAGUID, transports, platform and wallet-key scope with schema-v8
   SQLite. When a retained verified proof exists, the target credential counter
   must equal that proof's post-assertion counter, not the older sealed-source
   counter. Restoring the old counter would reopen a cloned-authenticator replay
   window. The tool still compares the sealed counter with the proof's claimed
   pre-assertion counter. It checks each binding's exact source digest and
   historical owner hash, rejects missing/extra target rows, and flags split
   historical hashes or merged random-owner aliases. Its report gives only
   aggregate counts, entry positions, the sealed source digest, and a SHA-256
   commitment to the specific target public rows it compared.
   `publicRepresentationExact: true` means the target public fields match the
   sealed image, except that a proven credential must carry its verified
   post-assertion counter. It is **not** an owner proof. A separate
   `proofMetadata` section compares retained schema-v8
   challenge/proof metadata with the exact sealed source and each binding's
   commitment in the same pinned SQLite read transaction. Every source
   credential needs a matching proof aligned to the binding owner; one proof
   commitment anchors each nonempty storage key, including keys with several
   credentials. Its completion flag stays false for a missing or mismatched
   proof and for an empty historical tombstone without a credential-specific
   proof. A true flag establishes only consistency of the retained proof,
   source and binding metadata; it does not replay the WebAuthn
   signature transcript, prove the JSON writer has stopped, import anything,
   or allow production startup. Schema v7 has no verified-proof table.
   It always reports `migrationPermitted: false` and exits `3` on a valid
   read-only report. A changed/unsafe image or invalid SQLite store exits `1`.
   The descriptor-pinned SQLite read rejects rollback-journal and WAL sidecars
   before and after its transaction. A crashed writer can leave uncommitted
   pages in the main file; reading through an fd alias alone would miss the
   journal at the original pathname. An interrupted database must be recovered
   through its canonical path before a fresh offline comparison.
   Example after an operator-controlled quarantine capture:

   ```sh
   node services/passkey-backup-owner-authority/scripts/verify-sealed-legacy-cutover.mjs \
     /private/quarantine/legacy-<sha256>.json /private/authority.sqlite <sha256>
   ```
3. The local HTTP composition candidate must use that same SQLite database as the **sole**
   credential and grant writer for all seven protected routes. The exact raw
   request-body grant and registration/counter/revocation change must commit
   together under `BEGIN IMMEDIATE`. After asynchronous WebAuthn work, recheck
   the owner session/generation, credential identity, handle, counter,
   revocation and storage binding before commit. The candidate now exercises
   all seven protected routes under fixture-proven bindings. Challenge
   discovery and listing must read the same authority; no JSON fallback,
   dual write or route-by-route mixed mode is permitted.
4. Production startup must verify a reviewed cutover manifest naming the
   sealed source digest, migration schema, proof commitments, route inventory,
   SQLite file identity and shipping binary. It must reject a writable legacy
   JSON store, an unproven/unreconciled cohort, schema rollback or mixed
   authority configuration. Switchover is forward-only: failures use feature
   disablement and compatible fixes, never wallet reset or JSON/database
   downgrade over newer counters or revocations.

The candidate JSON service now has a source-level retirement fence. After a
separately proven import and reviewed manifest, its offline retirement
primitive can hold the old writer lease, compare the private schema-3/4 bytes
with an independently recorded SHA-256 digest, and publish a durable no-replace
marker bound to the manifest digest. New JSON writer startup and pre-publish
checks reject that marker. The primitive has **not** been run on a deployed
store and does not verify the manifest, import records, old image version or
SQLite readiness; production admission must establish all of those first.
The legacy marker and surviving lease must not be cleared as a rollback.

The read-only `verify-legacy-cutover-manifest.mjs` candidate check now accepts
a private canonical `cutover-<sha256>.json` image, its independent expected
digest, the exact sealed JSON path, SQLite path and expected owner-image digest.
It pins the source schema/counts, the SQLite public-row commitment and counts,
the seven protected challenge-route path/scope pairs and the candidate image digest.
It rechecks the sealed source and target through the existing offline verifier
and reports whether public representation and retained proof metadata match.
The closed version-1 object has `source` (SHA-256, schema version and exact
storage-key/credential/tombstone counts), `owner` (schema version, public-row
SHA-256 and binding/metadata/proof counts), and `candidate` (owner-image and
protected-route SHA-256). The route digest is SHA-256 over UTF-8
`FP_OWNER_PROTECTED_ROUTES_V1`, a NUL, then seven lexically sorted
`path scope` lines with a final newline. The file uses recursively sorted
JSON keys, two-space indentation and one final newline; its basename is
`cutover-<sha256>.json` for its exact bytes. The caller must obtain the
expected manifest and image digests independently; this verifier cannot
establish their authenticity.
Even a match exits `3` with `migrationPermitted: false`: this check does not
verify a reviewer signature, running image, drained old writer, WebAuthn
transcripts or a durable import receipt. It is not accepted by the retirement
primitive or production startup. The v8 proof limits (128 globally/eight per
owner), unproven empty tombstones and missing historical-cohort importer remain
blocking design work.

Before admission, exercise in-flight assertion-versus-revoke, registration-
versus-revoke, duplicate counter, final-route removal, wrong owner/storage key,
expired/replayed proof, changed source digest, interrupted import and restart,
unknown commit outcome, and multi-process writers. Verify every historical
credential still signs or exports the original key after an exact signed app
upgrade. None of those acceptance results exists for this cutover yet.

## Pending challenge and credential-scope contract

The JSON service's registration and assertion completion bodies contain only a
challenge ID and public WebAuthn response. They do not establish the wallet
storage key, chosen credential, random owner or platform. Before those routes
can switch, the SQLite writer must issue and durably claim a versioned,
single-use pending challenge containing the exact storage key, random owner,
owner generation, platform, nonce, expiry, expected per-key WebAuthn user
handle and (for a credential-directed assertion) allowed credential ID. Claim
must commit before asynchronous WebAuthn work. Verification must use that
record's nonce and qualified origin; completion must recheck the claimed row,
session, grant, owner generation, credential public key/handle/counter and
storage-key mapping under one SQLite writer lock before consuming the grant
and committing the mutation. A null response user handle is admissible only
when the claimed challenge already names the same credential ID. An ID supplied
by an adapter without the claimed server record is insufficient. Schema v8
implements this **internal** issue/claim/commit state machine for an already
proven storage binding. The internal server-owned WebAuthn adapter now verifies
the claimed nonce, RP, configured platform origin, UV/UP, registration
metadata, stored assertion public key and counter before the same core commits
typed public evidence. The live JSON HTTP routes do not call this path. A
non-deployed test HTTP candidate calls it for all seven protected routes, but
independently proven legacy-owner admission and reviewed production startup
gates remain required before cutover.

The same non-deployed SQLite core consumes an exact-body owner grant and
issues `registration/challenge` and `assertion/challenge` pending rows in one
writer transaction for an already proven storage key. Registration derives
the historical key from the exact wallet ID and account name but refuses to
create an owner/key link from those names. Its `credentials/list` projection
consumes a grant in that transaction and returns only live credentials scoped
to the key with preserved public historical metadata; a bound empty tombstone
lists empty. The route tests compare explicit v4→v8 metadata preservation,
check a frozen legacy key/handle vector, and serialize a two-process grant
race. They use manually seeded proof commitments and do not prove any JSON
credential was safely assigned to a random owner. All seven live HTTP routes
still use the JSON service; mixed-mode cutover remains forbidden.

The current HTTP registration challenge derives its user handle by hashing
the UTF-8 bytes `user`, one NUL byte, then the storage key. Owner-native
enrollment instead uses a random owner handle. A proven legacy-key
registration needs the deterministic handle
and an atomic credential-to-key mapping with its verified public metadata.
The `credential_scopes` table introduced in v4 classifies each credential as owner-wide or
wallet-key-scoped. A historical metadata insert narrows its credential to the
proven wallet key in the same SQLite transaction; the internal wallet-key
revoke-all leaves owner-wide recovery credentials alone. Missing scope rows
invalidate the store. This still does not authorize a live registration: its
pending challenge and verified public metadata must bind the exact storage
key before a new wallet-key credential can be inserted. The internal v8
registration commit now performs that atomic insert when such a proven
binding exists; no live route or import creates the binding.

A previously unseen wallet storage key cannot be assigned to a random owner
from `walletId`, account name, Google identity or a completion body's
credential ID. Its creation needs a separate verified wallet-possession and
owner-binding ceremony. For a proven key, unknown or already-revoked
credential IDs may retain the old route's idempotent no-op behavior without a
final-route confirmation. Any live removal still requires explicit true
confirmation. An unbound storage key must fail closed until a reviewed
authorization and tombstone policy defines its behavior.

## Current protocol fence

The owner core's `consumeGrant` now returns
`credentialAuthority: "owner-sqlite-v2"`. The legacy challenge introspector's
closed schema-1 response rejects that extra field before calling any of its
four HTTP mutation handlers. This prevents this non-deployed owner core from
being accidentally wired as a grant source for the JSON writer. The marker
names the protocol fence, not the database schema version; v8 retains it.
It does not convert a route, prove a legacy owner, or make two stores atomic; a future
integrated HTTP service needs a new reviewed, explicit owner-authority contract.
The trusted introspection endpoint must preserve the marker; a proxy or
different service that strips or forges responses is outside this narrow
protocol fence and requires separate deployment identity controls.
