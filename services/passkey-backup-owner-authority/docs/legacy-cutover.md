# Legacy credential cutover: admission contract

This is a design for a future, reviewed migration. **No live credential route is
converted or admitted by this document.** The current challenge HTTP process
writes schema-4 JSON after separate grant introspection; the owner authority
uses schema-3 SQLite and has no HTTP listener. The read-only reconciliation
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

## Cutover transaction and admission

1. Stop and drain the sole JSON writer and all outstanding challenge/grant
   requests. Take a private, durable schema-3/4 snapshot and record its digest.
   Reconcile every credential, owner tombstone, ID, counter, backup flag,
   AAGUID, transport and platform field. Reject unknown schema, duplicate ID,
   conflicting owner hash, missing proof, changed snapshot or an owner binding
   already claimed by another namespace. Never initialize an empty database to
   bypass failure.
2. SQLite schema v3 now has storage-key→random-owner binding and capacity for
   complete historical public metadata and zero-credential tombstones. It
   preserves credential-scoped historical user handles in `credentials` rather
   than replacing them with `owners.user_handle`. No legacy row or owner link
   has been imported. A future reviewed importer must verify the proof and
   source digest, then import a proven cohort and its proof commitment in one
   durable SQLite transaction with collision and counter checks. Retain an
   encrypted, immutable pre-cutover snapshot for audit and forward recovery.
   Import is not a Google-account operation.
3. A new HTTP composition must use that same SQLite database as the **sole**
   credential and grant writer for all seven protected routes. The exact raw
   request-body grant and registration/counter/revocation change must commit
   together under `BEGIN IMMEDIATE`. After asynchronous WebAuthn work, recheck
   the owner session/generation, credential identity, handle, counter,
   revocation and storage binding before commit. Challenge discovery and
   listing must read the same authority; no JSON fallback, dual write or
   route-by-route mixed mode is permitted.
4. Production startup must verify a reviewed cutover manifest naming the
   sealed source digest, migration schema, proof commitments, route inventory,
   SQLite file identity and shipping binary. It must reject a writable legacy
   JSON store, an unproven/unreconciled cohort, schema rollback or mixed
   authority configuration. Switchover is forward-only: failures use feature
   disablement and compatible fixes, never wallet reset or JSON/database
   downgrade over newer counters or revocations.

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
by an adapter without the claimed server record is insufficient.

The current HTTP registration challenge derives its user handle by hashing
the UTF-8 bytes `user`, one NUL byte, then the storage key. Owner-native
enrollment instead uses a random owner handle. A proven legacy-key
registration needs the deterministic handle
and an atomic credential-to-key mapping with its verified public metadata.
The current v3 `legacy_credential_metadata` table can retain imported
historical rows, but a reviewed versioned credential-scope model must also
classify post-cutover credentials as wallet-key-scoped or owner-wide. A
wallet-key revoke-all may change only credentials mapped to that key; an
owner-wide recovery credential must remain outside that route. Before such a
model exists, the current internal mutation rejects an ambiguous revoke-all
when it sees a live unmapped owner credential. That conservative rejection is
not completion of the route.

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
names the protocol fence, not the database schema version; v3 retains it.
It does not convert a route, prove a legacy owner, or make two stores atomic; a future
integrated HTTP service needs a new reviewed, explicit owner-authority contract.
The trusted introspection endpoint must preserve the marker; a proxy or
different service that strips or forges responses is outside this narrow
protocol fence and requires separate deployment identity controls.
