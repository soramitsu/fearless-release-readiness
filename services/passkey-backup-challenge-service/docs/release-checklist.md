# Passkey Challenge Service Release Checklist

Use this checklist for every production release of
`https://backup.fearlesswallet.io`.

## Before Release

- Confirm the release candidate is built from reviewed source and no private
  secrets, local `.env` files, credential-store snapshots, or deployment keys
  are committed.
- Run `npm run lint:syntax` and confirm JavaScript syntax checks pass.
- Run `npm test` and confirm service, persistence, HTTP, and deployment
  manifest tests pass, including real ES256 WebAuthn attestation/assertion,
  signature tampering, RP-ID/origin drift, missing UV, replay, user-handle, and
  signature-counter adversarial cases.
- Run `npm run audit:dependencies` and confirm production dependencies have no
  known npm advisories.
- Run `npm run test:deployment-evidence-template` and confirm the deterministic
  evidence-template generator rejects malformed schema, secret-like fields, and
  placeholder ready evidence.
- Run `npm run generate:deployment-evidence-template -- --output build/reports/production-deployment-evidence-template.json`
  and use the generated template as the operator checklist for real deployment
  evidence.
- Run `npm run test:deployment-evidence-audit` and confirm the deployment
  evidence adversarial cases pass.
- Run `npm run audit:deployment-evidence` and confirm
  `scripts/production-deployment-evidence.json` is blocked while live deployment
  evidence is missing.
- After deployment routing is available, run
  `PASSKEY_BACKUP_BASE_URL=https://backup.fearlesswallet.io PASSKEY_BACKUP_SMOKE_GRANT_HELPER=/run/secrets/passkey-smoke-grant-helper PASSKEY_BACKUP_SMOKE_TIMEOUT_MS=10000 npm run smoke:production`
  and confirm health, registration challenge, assertion challenge, registration
  completion, assertion completion, credential list, single revoke, and
  revoke-all routes all match the public contract
  without storing a persistent test credential.
- Run `bash ../../scripts/test-passkey-challenge-service-audit.sh` and confirm
  the adversarial audit fixture catches missing deployment, persistence, and
  WebAuthn controls.
- Run `bash ../../scripts/audit-passkey-challenge-service.sh` and confirm the
  service release gate passes.
- Run `docker build -t passkey-backup-challenge-service:release .` and confirm
  the production image builds from the checked-in Docker contract.
- Run `docker compose -f docker-compose.production.yml up -d --build` and
  confirm the checked production Compose contract still starts with the pinned
  port, durable volume, production origins, and healthcheck.
- Confirm the deployment mounts durable storage at `/data/passkey-backup` and
  uses `PASSKEY_CREDENTIAL_STORE_FILE=/data/passkey-backup/credentials.json`.
- Confirm a production preflight with `PASSKEY_CREDENTIAL_STORE_FILE` omitted
  fails before listening; production must never fall back to an in-memory
  credential store.
- Derive `PASSKEY_ANDROID_ALLOWED_ORIGIN` from the SHA-256 fingerprint of the
  actual signed release APK certificate as
  `android:apk-key-hash:<unpadded-base64url-release-cert-sha256>`. Independently
  compare it with release signing and Digital Asset Links records; never use a
  debug certificate or a package-name-derived guess.
- Extract the canonical uppercase, colon-delimited SHA-256 fingerprint directly
  from an actual distribution-signed release APK, or independently obtain the
  Play app-signing certificate fingerprint, and export it as
  `PASSKEY_ANDROID_RELEASE_SIGNER_SHA256_FINGERPRINT`. Export
  `PASSKEY_ANDROID_RELEASE_SIGNER_EVIDENCE_SOURCE` as exactly `distributed-apk`
  or `play-app-signing-certificate` to identify the independent evidence source.
  Expected fingerprint/source strings alone must fail. For `distributed-apk`,
  also set `PASSKEY_ANDROID_DISTRIBUTED_APK_FILE` to the canonical absolute path
  of the delivered APK and `PASSKEY_ANDROID_RELEASE_ARTIFACT_SHA256` to its
  independently recorded digest. For Play evidence, supply the canonical
  read-only `PASSKEY_ANDROID_PLAY_APP_SIGNING_ATTESTATION_FILE`, its
  `PASSKEY_ANDROID_PLAY_APP_SIGNING_ATTESTATION_SHA256`, the submitted AAB as
  `PASSKEY_ANDROID_RELEASE_ARTIFACT_FILE` after making it read-only with
  `chmod a-w`, and its
  `PASSKEY_ANDROID_RELEASE_ARTIFACT_SHA256`. Also independently export the
  actual Play app-signing X.509 certificate (DER or one-certificate PEM), make
  it read-only, and supply `PASSKEY_ANDROID_PLAY_APP_SIGNING_CERTIFICATE_FILE`
  plus `PASSKEY_ANDROID_PLAY_APP_SIGNING_CERTIFICATE_SHA256`. Confirm the audit
  derives the fingerprint from the certificate bytes; a self-authored JSON
  fingerprint must fail. Run
  `PASSKEY_ANDROID_ALLOWED_ORIGIN="$PASSKEY_ANDROID_ALLOWED_ORIGIN" PASSKEY_ANDROID_RELEASE_SIGNER_SHA256_FINGERPRINT="$PASSKEY_ANDROID_RELEASE_SIGNER_SHA256_FINGERPRINT" PASSKEY_ANDROID_RELEASE_SIGNER_EVIDENCE_SOURCE="$PASSKEY_ANDROID_RELEASE_SIGNER_EVIDENCE_SOURCE" PASSKEY_ANDROID_RELEASE_ARTIFACT_SHA256="$PASSKEY_ANDROID_RELEASE_ARTIFACT_SHA256" PASSKEY_ANDROID_DISTRIBUTED_APK_FILE="$PASSKEY_ANDROID_DISTRIBUTED_APK_FILE" bash ../../scripts/audit-passkey-android-origin-parity.sh --require-ready`
  for the APK path, or the corresponding six Play artifact variables for the
  Play path.
  When Play App Signing is enabled, an AAB upload-key fingerprint is not
  sufficient because it can differ from the certificate on distributed APKs.
  Do not populate both values from `assetlinks.json`: the signed artifact is the
  independent evidence that the published association and service origin are
  correct.
- Confirm production startup and
  `docker compose -f docker-compose.production.yml up -d --build` fail before
  listening/container creation when `PASSKEY_ANDROID_ALLOWED_ORIGIN` is
  omitted, empty, padded, standard-base64, noncanonical, duplicated, or
  whitespace-contaminated.
- Confirm only one writer replica mounts each credential-store file, and confirm
  rate limiting is configured with `PASSKEY_RATE_LIMIT_WINDOW_MS` and
  `PASSKEY_RATE_LIMIT_MAX_REQUESTS`.
- Confirm `PASSKEY_GLOBAL_RATE_LIMIT_MAX_REQUESTS=5000` (or a reviewed lower
  bound) and prove distributed client addresses hit the global bucket before
  additional introspection calls are made.
- Confirm production startup fails without a canonical HTTPS
  `PASSKEY_AUTHORIZATION_INTROSPECTION_URL`, the audience is exactly
  `fearless-passkey-backup`, and the atomic-consume endpoint rejects replay,
  cross-subject, path/method/body-hash/scope/platform drift, expiry, timeout,
  non-2xx, malformed JSON, and oversized responses without logging grants.
- Confirm the authorization issuer proves wallet/cloud ownership, maps Android
  and iOS to one stable Fearless wallet-owner subject, and does not use a shared
  mobile secret or a raw Google/Apple/device subject. Run an authorized
  Android-to-iOS same-subject ceremony and a rejected different-subject test.
- Confirm the issuer recognizes the exact `passkey.credentials.list`,
  `passkey.credentials.revoke`, and `passkey.credentials.revoke-all` scopes and
  atomically consumes a separately bound grant for each lifecycle request.
- Confirm `PASSKEY_TRUST_PROXY_HOPS=1`, direct public access to port 8789 is
  blocked, and the TLS proxy sanitizes `X-Forwarded-For` to exactly one canonical
  client IP. Prove missing, duplicate, comma-separated, and spoofed headers fail
  closed or cannot rotate the per-client rate-limit key.
- Confirm `PASSKEY_TRUSTED_PROXY_CIDRS` contains only the direct TLS proxy peer
  and prove the same forwarded header from an untrusted direct peer is rejected.
- Confirm persisted schema-v3 records contain the credential AAGUID,
  registration platform, and domain-separated wallet-owner subject hash, never
  the raw subject or Bearer grant.
- Confirm final credential revocation persists a bounded empty owner tombstone,
  survives restart, rejects cross-subject takeover, permits same-owner
  re-registration, and does not expose public keys, user handles, counters, or
  owner hashes through the list route.
- Confirm Android and iOS cloud-backup deletion calls server revoke-all first
  and leaves the encrypted cloud record intact when revocation fails.
- Confirm routing for `https://backup.fearlesswallet.io` targets service port
  `8789` and preserves HTTPS.
- Confirm Android and iOS passkey backup release flags remain disabled until
  live health, platform provisioning, and recovery UX evidence are complete.
- Run `PASSKEY_BACKUP_LIVE_HEALTH=1 PASSKEY_BACKUP_HEALTH_TIMEOUT_SECONDS=10 bash ../../scripts/audit-passkey-backup-prerequisites.sh`
  against the deployed service and confirm the health identity contract passes.
- Run `PASSKEY_BACKUP_BASE_URL=https://backup.fearlesswallet.io PASSKEY_BACKUP_SMOKE_GRANT_HELPER=/run/secrets/passkey-smoke-grant-helper PASSKEY_BACKUP_SMOKE_TIMEOUT_MS=10000 npm run smoke:production`
  against the deployed service and confirm the route-level production smoke
  passes.
- Update `scripts/production-deployment-evidence.json`, set `releaseEnabled: true`,
  record image digest, deployment ID, deployed commit, live health response, and
  the exact Android WebAuthn allowed origin plus Android/iOS platform
  provisioning evidence. Blocked evidence must keep `deploymentEvidence`
  empty. Every ready smoke must be no more than 24 hours old, and each
  `liveHealthAttestation` and `platformProvisioningAttestation` must bind its
  canonical payload to the same deployment ID, deployed commit, image digest,
  and smoke timestamp. Verify the exact 24-hour boundary before promotion; a
  fresh record must not mask a stale second record. The ready audit compares
  `deployedCommit` with the service repository `HEAD` when available; when
  validating a tagged release or running from the aggregate workspace, set
  `PASSKEY_DEPLOYMENT_EXPECTED_COMMIT` to the exact 40-character release commit,
  then run
  `npm run audit:deployment-evidence -- --require-ready`.
- Confirm rollback owner, monitoring owner, alert route, and release
  communication channel.

## After Release

- Re-run `PASSKEY_BACKUP_LIVE_HEALTH=1 PASSKEY_BACKUP_HEALTH_TIMEOUT_SECONDS=10 bash ../../scripts/audit-passkey-backup-prerequisites.sh`
  after DNS propagation.
- Re-run `PASSKEY_BACKUP_BASE_URL=https://backup.fearlesswallet.io PASSKEY_BACKUP_SMOKE_GRANT_HELPER=/run/secrets/passkey-smoke-grant-helper PASSKEY_BACKUP_SMOKE_TIMEOUT_MS=10000 npm run smoke:production`
  after DNS propagation.
- Verify the deployed service is serving the intended image tag.
- Re-run
  `PASSKEY_BACKUP_LIVE_HEALTH=1 PASSKEY_BACKUP_HEALTH_TIMEOUT_SECONDS=10 bash ../../scripts/audit-passkey-backup-prerequisites.sh`;
  do not substitute an ad hoc curl command. Confirm it validates `ok=true`,
  `service=fearless-passkey-backup`,
  `rpId=fearlesswallet.io`, and `schemaVersion=1`.
- Monitor DNS/TLS health, HTTP 5xx rate, challenge completion failures,
  credential-store write failures, and container restarts.
