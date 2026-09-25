# Credential owner index migration

Schema 4 adds a credential-ID-to-owner index for replacement-device authentication. It retains every schema-3 public key, user handle, counter, AAGUID, platform, transport, backup flag, storage key and owner hash. Empty owner tombstones remain durable. This migration does not itself create an owner session, enroll a new owner, or permit Google identity to replace an existing owner.

The internal `findCredentialOwner` lookup returns a copy of public verification metadata. Possession of a credential ID or user handle is not authentication. A discoverable ceremony must still verify the signature, RP, origin, user verification and exact stored handle; its counter update must recheck revocation before an owner session is issued. The existing seven lifecycle routes retain their authorization requirements. The owner authority and discoverable ceremony are source-level candidates, not deployed HTTP integration.

The challenge service still writes JSON after separate grant introspection;
the owner SQLite candidate is not its transactional credential store. Its
historical deterministic user handles and
storage-key owner bindings cannot be silently mapped to the new authority's
random owner identities. The read-only operator inventory in the owner-authority
README compares public metadata on private copies, never imports records, and
always denies migration permission. Its sequential snapshots are not an atomic
cross-store view. Portable recovery remains disabled until all seven routes,
migration, and owner revocation use one qualified lifecycle authority.

On startup, a valid schema-3 file is validated completely, indexed, and atomically replaced with schema 4 before any request can be accepted. The replacement is written with mode 0600, file fsync, rename, and directory fsync. Migration refuses malformed input, duplicate credential IDs, unsupported older schemas and output exceeding the existing 16 MiB bound. A failed migration before rename leaves the original bytes intact. A failure after rename is reported; restart reads the complete schema-4 state. Do not initialize an empty store to bypass a failed migration.

Schema-4 startup requires an exact index: missing, duplicate, extra, cross-storage or cross-owner entries are rejected. Startup does not silently rebuild a substituted index. Registration, counter updates and revocation commit records and index together; after a rename followed by an fsync error, the process adopts the visible state and immediately invalidates revoked lookup entries.

Before deployment, stop and drain the sole writer, retain an encrypted storage-native snapshot, and rehearse migration on a private copy. Record only snapshot identities and integrity digests in release evidence. Run:

```sh
node --test test/credential-owner-index.test.js
npm test
```

Compare all credential and tombstone fields before and after migration, then verify an existing credential can authenticate and a revoked credential remains revoked after restart. Once schema 4 is written, use only a reviewed binary that supports it. Recovery uses compatible forward fixes; never downgrade the database or restore an old snapshot over later revocations/counters.

Server credential requests accept only empty extension metadata or public `credProps.rk`. PRF, large-blob and unknown extension results are rejected with generic diagnostics. Native clients must extract local PRF bytes before constructing a request; rejection after receipt cannot undo a client's transmission. Keep request-body logging disabled throughout proxies and application monitoring.
