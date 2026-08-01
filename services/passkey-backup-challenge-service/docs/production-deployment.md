# Passkey Challenge Service Production Deployment

This service backs `https://backup.fearlesswallet.io` for Fearless Android and
iOS passkey backup challenge ceremonies.

## Required Public Contract

- `GET /api/passkey-backup/v1/health` must return `ok=true`,
  `service=fearless-passkey-backup`, `rpId=fearlesswallet.io`, and
  `schemaVersion=1`.
- Registration endpoints must stay reachable:
  - `/api/passkey-backup/v1/registration/challenge`
  - `/api/passkey-backup/v1/registration/complete`
- Assertion endpoints must stay reachable:
  - `/api/passkey-backup/v1/assertion/challenge`
  - `/api/passkey-backup/v1/assertion/complete`
- Credential lifecycle endpoints must stay reachable:
  - `/api/passkey-backup/v1/credentials/list`
  - `/api/passkey-backup/v1/credentials/revoke`
  - `/api/passkey-backup/v1/credentials/revoke-all`
- The service must verify WebAuthn attestation/assertion cryptography and must
  not store encrypted wallet backup payloads. It stores only credential public
  keys, user handles, signature counters, transports, and backup metadata;
  wallet payloads remain in Google Drive appdata or CloudKit private storage.

## Required Environment

```sh
NODE_ENV=production
HOST=0.0.0.0
PORT=8789
PASSKEY_ALLOWED_ORIGINS=https://fearlesswallet.io,https://backup.fearlesswallet.io
PASSKEY_ANDROID_ALLOWED_ORIGIN=android:apk-key-hash:<unpadded-base64url-release-cert-sha256>
PASSKEY_AUTHORIZATION_INTROSPECTION_URL=https://<wallet-owner-authority>/v1/passkey/consume
PASSKEY_AUTHORIZATION_AUDIENCE=fearless-passkey-backup
PASSKEY_AUTHORIZATION_TIMEOUT_MS=2000
PASSKEY_AUTHORIZATION_MAX_TTL_SECONDS=300
PASSKEY_TRUST_PROXY_HOPS=1
PASSKEY_TRUSTED_PROXY_CIDRS=<exact-tls-proxy-ip-or-cidr>
PASSKEY_CHALLENGE_TTL_MS=300000
PASSKEY_MAX_CEREMONIES=10000
PASSKEY_RATE_LIMIT_WINDOW_MS=60000
PASSKEY_RATE_LIMIT_MAX_REQUESTS=120
PASSKEY_GLOBAL_RATE_LIMIT_MAX_REQUESTS=5000
PASSKEY_CREDENTIAL_STORE_FILE=/data/passkey-backup/credentials.json
```

Mount `/data/passkey-backup` on durable storage. Registration and assertion
ceremonies intentionally remain in memory and expire by TTL; registered
credential verification records must survive container restarts through
`PASSKEY_CREDENTIAL_STORE_FILE`.
Startup is fail-closed: `NODE_ENV=production` without a non-empty
`PASSKEY_CREDENTIAL_STORE_FILE` is rejected rather than silently using memory.
Production also requires `PASSKEY_ANDROID_ALLOWED_ORIGIN` in the exact
`android:apk-key-hash:<unpadded-base64url-release-cert-sha256>` form. Derive the
43-character digest from the SHA-256 fingerprint of the actual release APK
signing certificate and independently compare it with the release signing and
Digital Asset Links records. A debug certificate, a padded digest, standard
base64, whitespace, or a package-name-derived guess must fail preflight.

`PASSKEY_AUTHORIZATION_INTROSPECTION_URL` must be a canonical HTTPS URL. Each
of the seven POST routes requires a different bounded RFC 6750 Bearer grant. The
introspection endpoint must atomically consume the grant and return an exact
schema-v1 response binding `schemaVersion=1`, `active=true`, a stable Fearless wallet-ownership
`subject`, `audience`, `method`, `path`, unpadded base64url `bodySha256`, the
path-specific `scope`, verified `platform` (`android` or `ios`), and integer
`expiresAt`. Replays, response extensions, mismatches, expiry, non-2xx, timeout,
oversized response, and malformed JSON all fail closed. The subject issuer must
prove wallet/cloud ownership and map it to one stable cross-platform identity;
raw Google/Apple/device subjects and platform attestation alone are
insufficient. Challenge and completion tokens are separately consumed even
when downstream request validation or WebAuthn verification fails.

Credential lifecycle responses expose at most 32 descriptors and exclude the
public key, user handle, signature counter, and owner-subject hash. Single and
revoke-all operations are idempotent and protected by distinct
`passkey.credentials.*` scopes. Final revocation persists a schema-v3 empty
credential array with the owner hash as a bounded takeover-prevention
tombstone; it must survive restart, deny a different subject, and permit the
same subject to register a replacement. Unknown revocation must not create an
owner record. There is no owner-erasure route in this contract. Clients must
revoke all server credentials before deleting the encrypted Google Drive or
CloudKit backup record; if revocation fails, the recoverable cloud record must
remain.
The owner tombstone and lifecycle ordering are release-gated behavior.

`PASSKEY_TRUST_PROXY_HOPS=1` is required because TLS terminates at the
loopback-bound reverse proxy. Configure that proxy to sanitize the incoming
header and forward exactly one canonical client IP in `X-Forwarded-For`, and
block direct public access to port 8789. The service rejects missing,
multi-valued, comma-separated, and malformed forwarded addresses. Setting the
value to `0` is permitted only outside production and ignores spoofed forwarded
headers when calculating the rate-limit key.
Set `PASSKEY_TRUSTED_PROXY_CIDRS` to only the direct TLS proxy peer; forwarded
headers received from any other peer are rejected before request-body streaming
or introspection.
Keep `PASSKEY_GLOBAL_RATE_LIMIT_MAX_REQUESTS` bounded in addition to the
per-client bucket so distributed addresses cannot churn the client-key map into
unbounded introspection load. The TLS proxy and authorization issuer must apply
their own global abuse controls as defense in depth.

Run exactly one writer process for each mounted credential-store file. Multiple
replicas require an external transactional credential database; they must not
share this JSON file over a network filesystem.

## Container Contract

Build the production image from this service directory:

```sh
docker build -t passkey-backup-challenge-service:release .
```

The checked production Compose contract is suitable for a single-host Docker
deployment and keeps the same port, volume, environment, and health route:

```sh
export PASSKEY_ANDROID_ALLOWED_ORIGIN='android:apk-key-hash:<actual-release-cert-sha256-base64url>'
export PASSKEY_AUTHORIZATION_INTROSPECTION_URL='https://<wallet-owner-authority>/v1/passkey/consume'
export PASSKEY_TRUSTED_PROXY_CIDRS='<exact-tls-proxy-ip-or-cidr>'
docker compose -f docker-compose.production.yml up -d --build
```

The `${PASSKEY_ANDROID_ALLOWED_ORIGIN:?…}` interpolation is intentional:
Compose must stop before creating a container when the operator has not supplied
the verified release signing-certificate origin. At runtime, an authorization
claim for `android` is accepted only with that Android origin; an `ios` claim is
accepted only with a configured HTTPS origin. A grant for one platform cannot
authorize the other platform's WebAuthn origin.

Run the image with a persistent data volume and route
`https://backup.fearlesswallet.io` to port `8789`:

```sh
docker run --rm -p 127.0.0.1:8789:8789 \
  -v passkey-backup-data:/data/passkey-backup \
  -e PASSKEY_ALLOWED_ORIGINS=https://fearlesswallet.io,https://backup.fearlesswallet.io \
  -e PASSKEY_ANDROID_ALLOWED_ORIGIN="$PASSKEY_ANDROID_ALLOWED_ORIGIN" \
  -e PASSKEY_AUTHORIZATION_INTROSPECTION_URL="$PASSKEY_AUTHORIZATION_INTROSPECTION_URL" \
  -e PASSKEY_AUTHORIZATION_AUDIENCE=fearless-passkey-backup \
  -e PASSKEY_TRUST_PROXY_HOPS=1 \
  -e PASSKEY_TRUSTED_PROXY_CIDRS="$PASSKEY_TRUSTED_PROXY_CIDRS" \
  passkey-backup-challenge-service:release
```

The checked-in Dockerfile pins its Node 22 Alpine base by immutable
multi-architecture digest, runs as the non-root `node` user, exposes port
`8789`, uses `/api/passkey-backup/v1/health` for its container healthcheck, and
defaults `PASSKEY_CREDENTIAL_STORE_FILE` to
`/data/passkey-backup/credentials.json`.
The checked-in Compose file must keep `PASSKEY_ALLOWED_ORIGINS` set to
`https://fearlesswallet.io,https://backup.fearlesswallet.io`, require the
operator-supplied `PASSKEY_ANDROID_ALLOWED_ORIGIN`, mount
`passkey-backup-data:/data/passkey-backup`, and not depend on untracked `.env`
files.
It must also require `PASSKEY_AUTHORIZATION_INTROSPECTION_URL`, pin
`PASSKEY_AUTHORIZATION_AUDIENCE=fearless-passkey-backup`, and set
`PASSKEY_TRUST_PROXY_HOPS=1` with an operator-supplied
`PASSKEY_TRUSTED_PROXY_CIDRS` allowlist.

## Preflight

Run before promoting the service image:

```sh
npm run lint:syntax
npm test
npm run audit:dependencies
npm run test:deployment-evidence-template
npm run generate:deployment-evidence-template -- --output build/reports/production-deployment-evidence-template.json
npm run test:deployment-evidence-audit
npm run audit:deployment-evidence
PASSKEY_BACKUP_BASE_URL=https://backup.fearlesswallet.io \
  PASSKEY_BACKUP_SMOKE_GRANT_HELPER=/run/secrets/passkey-smoke-grant-helper \
  PASSKEY_BACKUP_SMOKE_TIMEOUT_MS=10000 npm run smoke:production
bash ../../scripts/test-passkey-challenge-service-audit.sh
bash ../../scripts/audit-passkey-challenge-service.sh
```

## Smoke Checks

After DNS and routing are updated:

```sh
PASSKEY_BACKUP_LIVE_HEALTH=1 PASSKEY_BACKUP_HEALTH_TIMEOUT_SECONDS=10 \
  bash ../../scripts/audit-passkey-backup-prerequisites.sh
PASSKEY_BACKUP_BASE_URL=https://backup.fearlesswallet.io \
  PASSKEY_BACKUP_SMOKE_GRANT_HELPER=/run/secrets/passkey-smoke-grant-helper \
  PASSKEY_BACKUP_SMOKE_TIMEOUT_MS=10000 npm run smoke:production
PASSKEY_ANDROID_ALLOWED_ORIGIN="$PASSKEY_ANDROID_ALLOWED_ORIGIN" \
  PASSKEY_ANDROID_RELEASE_SIGNER_SHA256_FINGERPRINT="$PASSKEY_ANDROID_RELEASE_SIGNER_SHA256_FINGERPRINT" \
  PASSKEY_ANDROID_RELEASE_SIGNER_EVIDENCE_SOURCE="$PASSKEY_ANDROID_RELEASE_SIGNER_EVIDENCE_SOURCE" \
  PASSKEY_ANDROID_RELEASE_ARTIFACT_SHA256="$PASSKEY_ANDROID_RELEASE_ARTIFACT_SHA256" \
  PASSKEY_ANDROID_DISTRIBUTED_APK_FILE=/absolute/path/to/distributed-fearless.apk \
  bash ../../scripts/audit-passkey-android-origin-parity.sh --require-ready
PASSKEY_ANDROID_ALLOWED_ORIGIN="$PASSKEY_ANDROID_ALLOWED_ORIGIN" \
  PASSKEY_ANDROID_RELEASE_SIGNER_SHA256_FINGERPRINT="$PASSKEY_ANDROID_RELEASE_SIGNER_SHA256_FINGERPRINT" \
  PASSKEY_ANDROID_RELEASE_SIGNER_EVIDENCE_SOURCE=play-app-signing-certificate \
  PASSKEY_ANDROID_PLAY_APP_SIGNING_ATTESTATION_FILE=/absolute/path/to/play-attestation.json \
  PASSKEY_ANDROID_PLAY_APP_SIGNING_ATTESTATION_SHA256="$PASSKEY_ANDROID_PLAY_APP_SIGNING_ATTESTATION_SHA256" \
  PASSKEY_ANDROID_PLAY_APP_SIGNING_CERTIFICATE_FILE=/absolute/path/to/play-app-signing-certificate.pem \
  PASSKEY_ANDROID_PLAY_APP_SIGNING_CERTIFICATE_SHA256="$PASSKEY_ANDROID_PLAY_APP_SIGNING_CERTIFICATE_SHA256" \
  PASSKEY_ANDROID_RELEASE_ARTIFACT_FILE=/absolute/path/to/submitted-release.aab \
  PASSKEY_ANDROID_RELEASE_ARTIFACT_SHA256="$PASSKEY_ANDROID_RELEASE_ARTIFACT_SHA256" \
  bash ../../scripts/audit-passkey-android-origin-parity.sh --require-ready
```

The live health gate must fail if DNS does not resolve, TLS is invalid, the
service identity is not `fearless-passkey-backup`, the relying party ID is not
`fearlesswallet.io`, or the schema version is not `1`.
Use the prerequisite gate for operator health checks instead of an ad hoc curl
command. It invokes the canonical system curl with configuration loading
disabled, an empty proxy/CA/config environment, HTTPS-only transport, no
redirects, bounded connect/total deadlines and response size, and strict URL,
HTTP status, media-type, byte-count, UTF-8, and JSON identity validation.
The production smoke must also prove the four ceremony routes and all three
credential lifecycle routes are routed to the passkey service and return the
expected public JSON contracts without recording a persistent test credential
or creating an owner tombstone for an unknown revocation.
The origin-parity command requires an actual release artifact; declared strings
alone are never signer evidence. For `distributed-apk`, set
`PASSKEY_ANDROID_DISTRIBUTED_APK_FILE` to the absolute canonical path of the APK
delivered to users and set `PASSKEY_ANDROID_RELEASE_ARTIFACT_SHA256` to its
independently recorded `sha256:<64-lowercase-hex>` digest. The audit invokes the
Android SDK's `apksigner verify --verbose --print-certs`, requires exactly one
v2/v3 signer, confirms the package with `aapt`, derives the signer fingerprint
and artifact digest from the APK bytes, then compares both with the declarations.

For `play-app-signing-certificate`, supply all of:

- `PASSKEY_ANDROID_PLAY_APP_SIGNING_ATTESTATION_FILE`, an absolute path to a
  canonical two-space JSON attestation made read-only with `chmod a-w`;
- `PASSKEY_ANDROID_PLAY_APP_SIGNING_ATTESTATION_SHA256`, the independently
  recorded digest of those exact attestation bytes;
- `PASSKEY_ANDROID_PLAY_APP_SIGNING_CERTIFICATE_FILE`, the canonical absolute
  path to the independently exported Play app-signing X.509 certificate (DER or
  single-certificate PEM), made read-only with `chmod a-w`;
- `PASSKEY_ANDROID_PLAY_APP_SIGNING_CERTIFICATE_SHA256`, the independently
  recorded digest of those exact certificate-file bytes;
- `PASSKEY_ANDROID_RELEASE_ARTIFACT_FILE`, the absolute canonical path to the
  submitted release AAB, made read-only with `chmod a-w`; and
- `PASSKEY_ANDROID_RELEASE_ARTIFACT_SHA256`, its independently recorded digest.

The attestation contains exactly `schemaVersion`, `source`, `packageName`,
`artifactType`, `artifactSha256`, `versionCode`,
`certificateSha256Fingerprint`, `certificateFileSha256`, `issuedAt`, and
`playConsoleReleaseId`. It must
identify the Fearless production package and AAB, be no more than 30 days old,
and bind the actual immutable AAB ZIP digest. The audit rejects a writable AAB,
requires unique
`BundleConfig.pb`, `base/manifest/AndroidManifest.xml`, and `base/resources.pb`
entries, parses the compiled AAB base manifest with Android SDK `aapt2`, and
requires its package and positive version code to match the attestation. The
audit parses the separate X.509 file, derives `fingerprint256` from its bytes,
requires the certificate to be valid at attestation and audit time, and binds
its exact file digest into the attestation. A self-declared fingerprint in JSON
cannot satisfy this gate. The attestation's certificate is the
Play app-signing certificate, never the AAB upload certificate. Review and seal
the Play Console evidence before calculating the attestation digest.

`PASSKEY_ANDROID_ALLOWED_ORIGIN` is the exact production service setting, while
`PASSKEY_ANDROID_RELEASE_SIGNER_SHA256_FINGERPRINT` is the canonical uppercase,
colon-delimited SHA-256 fingerprint extracted from an actual distribution-signed
release APK, or independently obtained from the Play app-signing certificate.
Set `PASSKEY_ANDROID_RELEASE_SIGNER_EVIDENCE_SOURCE` to exactly
`distributed-apk` or `play-app-signing-certificate` to state which independent
source supplied that fingerprint.
When Play App Signing is enabled, the upload-key fingerprint on the submitted
AAB is not sufficient because it can differ from the certificate on APKs
delivered to users. The audit derives the Android WebAuthn origin from that
distribution signer and requires it to match the service setting, production
config, deployment evidence, and checked Digital Asset Links body. Do not derive
both inputs from the checked association file; that would not be independent
signer evidence.
Every smoke request refuses redirects, applies one total deadline across grant
acquisition, HTTP exchange, and response streaming, requires an exact JSON
media type (registered `+json` subtypes are supported), and caps the decoded
response at 1 MiB. `PASSKEY_BACKUP_SMOKE_TIMEOUT_MS` and
`PASSKEY_BACKUP_SMOKE_MAX_RESPONSE_BYTES` are fail-closed canonical integers
with hard maxima of 60 seconds and 5 MiB. Failure previews are bounded and
redact URL credentials, bearer values, and token/password/API-key-like fields.
The smoke grant helper must be an absolute, non-symlink executable path that is
not group- or world-writable. The public command records only this conventional
path; it never records a grant or issuer credential. The helper is
invoked without a shell or arguments, receives exact method/path/body-SHA JSON
on stdin, and returns one grant on stdout. Keep issuer credentials inside the
helper or its protected runtime; never place grants in docs, evidence, argv, or
committed files.

## Deployment Evidence

`scripts/production-deployment-evidence.json` must stay blocked with
`releaseEnabled: false` until the deployed image digest, deployment ID, commit,
operator, durable credential-store volume, live health response, and Android/iOS
platform provisioning evidence are recorded. A blocked manifest must keep
`deploymentEvidence` empty; partial or historical records cannot coexist with
blockers. Use
`npm run generate:deployment-evidence-template -- --output build/reports/production-deployment-evidence-template.json`
to create a deterministic fill-in-ready manifest template from the committed
schema; the template keeps TODO placeholders and must not pass the ready audit
until real evidence replaces them.

Before enabling the mobile passkey backup flags, update the evidence manifest,
set `releaseEnabled: true`, and run:

```sh
PASSKEY_BACKUP_BASE_URL=https://backup.fearlesswallet.io \
  PASSKEY_BACKUP_SMOKE_GRANT_HELPER=/run/secrets/passkey-smoke-grant-helper \
  PASSKEY_BACKUP_SMOKE_TIMEOUT_MS=10000 npm run smoke:production
npm run audit:deployment-evidence -- --require-ready
```

The ready audit requires `deploymentEvidence[].deployedCommit` to match the
release commit under validation. It uses the service repository `HEAD` when git
metadata is available; when validating a tag or running from the aggregate
workspace, set `PASSKEY_DEPLOYMENT_EXPECTED_COMMIT` to the exact 40-character
release commit before running the ready audit.

Every ready record is current-release evidence, not an archive. Its
`smokePassedAt` must be no more than 24 hours old at audit start; the exact
24-hour boundary is accepted and one second older is rejected. Every record's
`liveHealthAttestation` and `platformProvisioningAttestation` must repeat the
same `deploymentId`, `deployedCommit`, `imageDigest`, and `smokePassedAt` as
`observedAt`. Their `payloadSha256` values are lowercase `sha256:` digests of
the compact canonical JSON payloads. Health field order is `ok`, `service`,
`rpId`, `schemaVersion`; platform field order is `androidGoogleDriveConsent`,
`androidReleaseFlagDisabled`, `iosAssociatedDomain`,
`iosCloudKitProductionSchema`, `iosReleaseFlagDisabled`. All records are
validated, so a fresh record cannot mask a stale or cross-bound attestation.
