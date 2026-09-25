# Passkey Challenge Service Rollback Checklist

Use this checklist when a production release of
`https://backup.fearlesswallet.io` must be replaced with a previously reviewed
image. A rollback changes only the service image. It must preserve the durable
credential store and all revocation state.

## Entry Gate

- If `/data/passkey-backup/.credentials.json.retired` exists, stop this JSON
  rollback. Its retained writer lease and marker fence the old authority after
  a one-way cutover. Do not remove either file or start an older image that
  ignores the marker; use the reviewed SQLite-authority forward-recovery plan.
- Record the incident or release identifier, rollback owner, storage owner,
  monitoring owner, start time, current immutable image reference, and reason.
- Select a last-known-good image only as the full
  `ghcr.io/soramitsu/fearless-passkey-backup@sha256:<64-lowercase-hex>`
  reference. Never select a mutable tag, a local build, or an image ID alone.
- Obtain the publication evidence artifact from the image's GitHub Actions run.
  Confirm its `sourceCommit` is a reviewed commit from protected `main`, its
  `imageDigest` equals the chosen digest, and its attestation URL belongs to
  `soramitsu/fearless-release-readiness`.
- Verify the image before touching the running service:

  ```sh
  gh attestation verify \
    oci://ghcr.io/soramitsu/fearless-passkey-backup@sha256:<last-known-good-digest> \
    --repo soramitsu/fearless-release-readiness \
    --signer-workflow soramitsu/fearless-release-readiness/.github/workflows/passkey-image-publish.yml \
    --source-digest <last-known-good-protected-main-commit> \
    --source-ref refs/heads/main \
    --deny-self-hosted-runners
  ```

- Confirm the selected binary supports the current schema-v4 credential-store
  contract, including its validated credential owner index and bounded empty owner tombstones. If compatibility is not
  proven, stop and fail closed; do not restore an older store to make it start.

## Preserve Durable State

- Confirm a private, encrypted, storage-native pre-release snapshot exists and
  record its immutable snapshot ID, creation time, byte count, and SHA-256 or
  provider integrity proof. Test readability and restrict access to the storage
  and incident owners. Never attach credential-store bytes to public evidence.
- Pull the reviewed rollback image before the outage window. Then drain new
  traffic and stop the current writer before taking the rollback-time snapshot:

  ```sh
  export PASSKEY_BACKUP_IMAGE_REPOSITORY=ghcr.io/soramitsu/fearless-passkey-backup
  export PASSKEY_BACKUP_IMAGE_DIGEST=<last-known-good-64-lowercase-hex-without-prefix>
  docker compose -f docker-compose.production.yml pull
  docker compose -f docker-compose.production.yml stop passkey-backup-challenge-service
  ```

- Prove the current container is stopped and no other replica, maintenance job,
  or host has the credential file open for writing. Exactly one writer may mount
  each credential-store file. Never share the JSON file over NFS or another
  network filesystem.
- With all writers stopped, take a private, encrypted, storage-native
  rollback-time snapshot of the existing `passkey-backup-data` volume. Record
  its immutable ID, creation time, byte count, integrity proof, and access
  controls. Keep both snapshots until the incident is closed.
- Preserve `/data/passkey-backup/credentials.json` in place. Never run
  `docker compose down -v`, `docker volume rm`, delete or replace
  `credentials.json`, initialize an empty volume, or copy a snapshot over the
  live store as a routine rollback step.
- Treat every schema-v4 record, credential owner index entry, signature counter, credential, owner-subject
  binding, and empty owner tombstone as durable security state. An older
  snapshot can resurrect a revoked credential, lose an advanced counter, or
  remove a takeover-prevention tombstone.

## Replace Only the Image

- Reconfirm the repository and digest variables contain only the reviewed
  values. Validate interpolation without printing the rendered configuration,
  then start only the service with the existing named volume:

  ```sh
  docker compose -f docker-compose.production.yml config --quiet
  docker compose -f docker-compose.production.yml up -d --no-build --no-deps passkey-backup-challenge-service
  ```

- Confirm there is exactly one running writer and that it mounts the original
  durable volume at `/data/passkey-backup`. Do not start the previous and current
  containers concurrently, even briefly.
- If the selected version rejects the existing store, stop it and keep traffic
  drained. A snapshot restore requires separate security-owner and storage-owner
  approval plus an explicit reconciliation of every registration, counter
  advance, revocation, and tombstone since the snapshot. If that reconciliation
  cannot prove that no revoked credential or removed tombstone will return,
  restoration must fail closed.

## Revocation Ordering Invariant

- Client deletion remains ordered during and after rollback: the server
  `/api/passkey-backup/v1/credentials/revoke-all` request must succeed and the
  durable empty owner tombstone must be persisted before the encrypted Google
  Drive or CloudKit backup record is deleted.
- If server revocation fails or its durable result is uncertain, retain the
  recoverable cloud record and retry later. Never delete cloud data first.
- A rollback must not reverse a completed revocation, restore a revoked
  credential, remove an owner tombstone, or lower a signature counter. Escalate
  any ambiguity to the security owner and keep release flags disabled.

## Verification and Evidence

- Run the strict live health gate and the authorized route smoke against the
  rollback image:

  ```sh
  PASSKEY_BACKUP_LIVE_HEALTH=1 PASSKEY_BACKUP_HEALTH_TIMEOUT_SECONDS=10 \
    bash ../../scripts/audit-passkey-backup-prerequisites.sh
  PASSKEY_BACKUP_BASE_URL=https://backup.fearlesswallet.io \
    PASSKEY_BACKUP_SMOKE_GRANT_HELPER=/run/secrets/passkey-smoke-grant-helper \
    PASSKEY_BACKUP_SMOKE_TIMEOUT_MS=10000 npm run smoke:production
  ```

- Verify the intended immutable digest is running, the original durable volume
  remains mounted, counters advance, expected credentials still authenticate,
  revoked credentials remain rejected, and owner tombstones survive a controlled
  restart. Do not create a persistent smoke credential.
- Record the old and rollback image digests, source commits, publication run and
  attestation URLs, snapshot IDs and integrity proofs, stop/start timestamps,
  one-writer proof, health/smoke results, approvals, and follow-up owner. Public
  evidence may contain references and digests only, never credential data,
  grants, tokens, snapshot contents, or secret values.
- Keep Android and iOS passkey backup release flags disabled until the incident
  owner, security owner, storage owner, and monitoring owner approve exit.
