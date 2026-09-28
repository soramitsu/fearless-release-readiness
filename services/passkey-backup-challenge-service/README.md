# Fearless Passkey Backup Challenge Service

Reference implementation for the public passkey backup challenge service used by
Fearless Android and iOS passkey backup flows.

The service implements the contract in
`../../config/passkey-backup-challenge-service.openapi.json`:

- `GET /api/passkey-backup/v1/health`
- `POST /api/passkey-backup/v1/registration/challenge`
- `POST /api/passkey-backup/v1/registration/complete`
- `POST /api/passkey-backup/v1/assertion/challenge`
- `POST /api/passkey-backup/v1/assertion/complete`
- `POST /api/passkey-backup/v1/credentials/list`
- `POST /api/passkey-backup/v1/credentials/revoke`
- `POST /api/passkey-backup/v1/credentials/revoke-all`

It cryptographically verifies WebAuthn registration and assertion responses,
including RP-ID hashes, origins, challenges, user presence/verification,
credential signatures, user handles, and signature counters. It stores only
short-lived ceremonies and the public verification records required for later
assertions. Encrypted wallet backup payloads remain in platform cloud storage.

An assertion challenge may include an exact registered `credentialId` for a
credential-directed PRF ceremony. The challenge echoes and stores that ID, and
completion rejects a different credential. Only that directed ceremony accepts
WebAuthn's nullable `userHandle`; a discoverable challenge without `credentialId`
still requires the exact stored user handle. This does not provide owner
bootstrap, cross-device recovery, or approval to enable the backup feature.

## Environment

| Variable | Default | Purpose |
| --- | --- | --- |
| `PORT` | `8789` | HTTP listen port. |
| `HOST` | `0.0.0.0` | HTTP listen host. |
| `PASSKEY_ALLOWED_ORIGINS` | `https://fearlesswallet.io,https://backup.fearlesswallet.io` | Comma-separated canonical HTTPS WebAuthn origins allowed in `clientDataJSON`; empty entries, whitespace, aliases, and duplicates are rejected. |
| `PASSKEY_ANDROID_ALLOWED_ORIGIN` | unset | Exact `android:apk-key-hash:<unpadded-base64url-sha256>` origin derived from the release APK signing certificate; required in production. |
| `PASSKEY_AUTHORIZATION_INTROSPECTION_URL` | unset | Canonical HTTPS endpoint that atomically consumes one-time ceremony grants; required at startup. |
| `PASSKEY_AUTHORIZATION_AUDIENCE` | unset; `fearless-passkey-backup` in Compose | Exact introspection audience. |
| `PASSKEY_AUTHORIZATION_TIMEOUT_MS` | `2000` | Total introspection request and bounded-response timeout. |
| `PASSKEY_AUTHORIZATION_MAX_TTL_SECONDS` | `300` | Maximum accepted remaining lifetime for an introspected grant. |
| `PASSKEY_TRUST_PROXY_HOPS` | unset locally; `1` in Compose | `1` trusts exactly one sanitized `X-Forwarded-For` client address; production requires this behind the loopback TLS proxy. |
| `PASSKEY_TRUSTED_PROXY_CIDRS` | unset | Comma-separated allowlist of direct TLS proxy IP addresses/CIDRs; required whenever proxy trust is enabled. |
| `PASSKEY_CHALLENGE_TTL_MS` | `300000` | Registration/assertion challenge lifetime. |
| `PASSKEY_MAX_CEREMONIES` | `10000` | Maximum in-memory ceremonies retained before rejecting new challenges. |
| `PASSKEY_RATE_LIMIT_WINDOW_MS` | `60000` | Per-client ceremony endpoint rate-limit window. |
| `PASSKEY_RATE_LIMIT_MAX_REQUESTS` | `120` | Maximum ceremony requests per client and window. |
| `PASSKEY_GLOBAL_RATE_LIMIT_MAX_REQUESTS` | `5000` | Maximum authorized ceremony requests across all clients per window, bounding distributed introspection load. |
| `PASSKEY_CREDENTIAL_STORE_FILE` | unset locally; `/data/passkey-backup/credentials.json` in Docker | JSON file used to persist credential public keys, user handles, counters, transports, and backup metadata. |
| `PASSKEY_BACKUP_SMOKE_GRANT_HELPER` | unset | Absolute non-symlink, non-group/world-writable executable used only by production smoke to mint a distinct one-time grant for each exact method/path/body hash. |
| `PASSKEY_BACKUP_SMOKE_GRANT_HELPER_TIMEOUT_MS` | `2000` | Smoke grant helper timeout (100-10000 ms). |

Production deployment for the current release plan is
`https://backup.fearlesswallet.io` with relying party id `fearlesswallet.io`.
The health response service identity is `fearless-passkey-backup`.
The production deployment runbook lives in
[`docs/production-deployment.md`](docs/production-deployment.md), and release
promotion must follow [`docs/release-checklist.md`](docs/release-checklist.md).
Production images are published from the exact protected `main` commit by
`.github/workflows/passkey-image-publish.yml`, carry GitHub build-provenance
attestation, and are deployed only as
`ghcr.io/soramitsu/fearless-passkey-backup@sha256:<reviewed-digest>`; local
mutable release tags are not production artifacts. Incident recovery must
follow [`docs/rollback-checklist.md`](docs/rollback-checklist.md) so the durable
credential store, signature counters, revocations, owner tombstones, and
single-writer invariant survive an image rollback.

Registration and assertion ceremonies remain in memory and expire by TTL; only
registered public verification records are persisted. Docker deployments must mount
`/data/passkey-backup` on durable storage so registered passkeys continue to
work after a container restart. The process refuses to start in `NODE_ENV=production`
without `PASSKEY_CREDENTIAL_STORE_FILE`; an in-memory credential store is for
local development and tests only. Production also refuses to start without a
canonical `PASSKEY_ANDROID_ALLOWED_ORIGIN`. Android Credential Manager signs
`clientDataJSON` with a certificate-bound native origin, so an HTTPS origin
cannot substitute for the exact release signing-certificate origin. Do not use
a debug certificate or infer this value from the package name.

Release origin parity does not trust a declared fingerprint/source pair by
itself. Ready promotion must either verify an actual distribution-signed APK
with Android SDK `apksigner`/`aapt`, or validate a canonical read-only Play
app-signing attestation whose digest and `artifactSha256` bind the exact release
AAB (sealed read-only before audit) and whose signer fingerprint is derived from a separately exported,
read-only X.509 Play app-signing certificate. See the deployment runbook for the
artifact-path and digest variables.
Deployment smoke evidence expires after 24 hours and its live-health and
platform-provisioning attestations must bind the same deployment ID, commit,
image digest, timestamp, and canonical payload. Blocked manifests keep their
deployment evidence array empty.

All seven ceremony and credential-lifecycle POST routes require an RFC 6750 Bearer grant. The service
sends the grant only in the introspector `Authorization` header and sends an
exact schema-v1 method, path, audience, scope, and unpadded base64url SHA-256
hash of the raw request body for atomic consumption. The exact schema-v1
response must bind those values to
a verified `android` or `ios` platform and a stable Fearless wallet-ownership
subject. That subject must be stable across platforms; raw Google, Apple, or
device account identifiers are not valid substitutes. Each ceremony also binds
that verified platform to its origin family: `android` grants accept only the
configured `android:apk-key-hash:` origin, while `ios` grants accept only the
configured web origins. Only the subject's domain-separated
SHA-256 digest is stored. Registration/assertion challenge and completion calls
must use separate one-time grants. There is no shared mobile secret and no
production unauthenticated fallback.
Production service calls require the introspected grant expiry to be current,
and registration/assertion completion rechecks it immediately before changing
credential state after asynchronous WebAuthn verification. This expiry check
does not fence an owner revocation in the separate authority store; coordinated
same-transaction lifecycle commits are still required before recovery is enabled.

Credential listing returns at most 32 non-secret descriptors and never returns
the stored public key, user handle, signature counter, or wallet-owner hash.
Single-credential and storage-owner revoke-all requests are idempotent. A request
that removes any live credential, or removes all live credentials, requires
`confirmFinalRecoveryRemoval: true` in the exact body covered by its one-time
owner grant. Another credential record is not proof of a surviving decryptable
backup. Without the field, the service returns HTTP 409 and leaves credentials
intact. The client must obtain explicit user confirmation before submitting that
field, except when rolling back enrollment that never established a usable
backup. The service cannot attest the UI, rollback state or client-side backup-key rotation.
After
the final revocation, schema-v4 storage retains a bounded zero-credential owner
tombstone: this prevents a different subject that derives the deterministic
storage key from taking it over, while the original stable owner can register a
replacement passkey. Unknown revocations do not create tombstones. Owner-record
erasure is deliberately not exposed by this API; it requires a separately
reviewed identity proof and retention policy. Mobile backup deletion must call
`credentials/revoke-all` before deleting the encrypted cloud record so a server
failure leaves recoverable encrypted data instead of an orphaned live passkey.
This owner tombstone is durable, and clients must revoke all server credentials before deleting cloud data.

Schema-v3 stores migrate atomically to schema-v4, preserving historical credentials,
user handles, counters and tombstones while adding a validated credential-to-owner
index. See [migration and recovery requirements](docs/credential-store-migration.md).
The index is an internal public-key lookup; it does not authenticate a caller or
issue an owner session. Native clients must keep PRF outputs local. Credential
requests reject PRF, large-blob and unreviewed extension fields.

## Local Commands

```sh
npm run lint:syntax
npm test
npm run audit:dependencies
npm start
PASSKEY_BACKUP_BASE_URL=https://backup.fearlesswallet.io PASSKEY_BACKUP_SMOKE_GRANT_HELPER=/run/secrets/passkey-smoke-grant-helper PASSKEY_BACKUP_SMOKE_TIMEOUT_MS=10000 npm run smoke:production
```

Production route smoke additionally requires `PASSKEY_BACKUP_SMOKE_GRANT_HELPER`.
The helper is executed directly with no shell or arguments. It receives one
schema-v1 JSON object containing `method`, `path`, and `bodySha256` on stdin and
must write exactly one bounded RFC 6750 token (with at most one trailing newline)
to stdout. Non-executable, symlinked, group/world-writable paths, timeout, nonzero exit, extra output,
control characters, and malformed tokens fail without logging stdout or stderr.

The Docker image pins its Node 22 Alpine base by immutable multi-architecture
digest, runs as the non-root `node` user, and exposes port `8789`.
Use `docker-compose.production.yml` for the checked production container
contract: it binds `127.0.0.1:8789`, mounts `passkey-backup-data` at
`/data/passkey-backup`, pins production origins, and runs the same health route
as the Dockerfile healthcheck. It is hardened with a read-only root filesystem,
all Linux capabilities dropped, `no-new-privileges`, a bounded PID count, and a
non-root runtime. The file store is a single-writer contract; run one service
replica per mounted credential-store file. Compose uses required-variable
interpolation for `PASSKEY_ANDROID_ALLOWED_ORIGIN`, so configuration fails
before container creation when the release origin has not been supplied.
The production process requires `PASSKEY_RECOVERY_ENABLED=false` and rejects
`PASSKEY_OWNER_AUTHORITY_STORE_FILE`. These are fail-closed legacy-mode
configuration checks, not a transaction bridge: the existing seven HTTP
routes still use JSON after separate grant introspection. They do not enable
portable recovery or make owner revocation atomic with JSON writes. Keep the
owner SQLite authority out of this deployment until a reviewed migration and
one authoritative lifecycle transaction are in place.
The owner authority's `credentialAuthority: "owner-sqlite-v2"` introspection
response is intentionally outside this JSON service's closed response schema;
its grants are rejected before any credential mutation handler runs. See the
[legacy cutover admission contract](../passkey-backup-owner-authority/docs/legacy-cutover.md).
It also requires the introspection endpoint, pins its audience, and enables a
single-hop forwarded-client contract. The TLS proxy must overwrite or append a
single canonical client IP and must block direct public access; missing,
duplicate, comma-separated, or malformed `X-Forwarded-For` values fail closed.
Forwarded headers from a peer outside `PASSKEY_TRUSTED_PROXY_CIDRS` are rejected.
