# Immutable passkey backup generation v1

`FPBKGEN1` is the common Android/iOS byte format for one encrypted wallet
backup generation. It contains the existing `FPBKAEAD` v1 encrypted envelope
and one or more opaque `FPBKWRP1` credential wrappers. Drive stores only these
encrypted bytes and nonsecret indexing metadata. The owner authority stores
the generation ID, Drive file ID, SHA-256 digest, account binding, key epoch
and current/previous head relationships; it stores no envelope, recovery
phrase, backup key or PRF output.

All integers are unsigned-compatible, big-endian values within signed 64-bit
range where eight bytes are used. Every text or variable-length binary field
has a four-byte big-endian length followed by exactly that many bytes. Text
is UTF-8. No trailing bytes, alternate encodings or unknown fields are
allowed. The complete generation is at most 512 KiB; the pre-existing
encrypted envelope remains bounded separately by its legacy 256 KiB policy.

| Field, in byte order | Encoding and constraint |
| --- | --- |
| Magic, version | ASCII `FPBKGEN1` (8 bytes), then `uint32(1)` |
| Owner subject | Length-prefixed UTF-8 `owner:` plus canonical 32-byte base64url ID |
| Backup namespace | Length-prefixed UTF-8 `backup:` plus canonical 32-byte base64url ID |
| Generation ID | Length-prefixed UTF-8 canonical 32-byte base64url ID |
| Parent head revision | `uint64`; zero only for the first generation |
| Parent digest | One-byte marker `0` for first generation, or `1` followed by raw 32-byte SHA-256 digest |
| Backup-key epoch | `uint64`, at least one |
| Google account binding | Raw 32-byte SHA-256 digest |
| Envelope metadata | Length-prefixed UTF-8 storage key, wallet ID and historical account name; `uint64` creation time in milliseconds; `uint32(1)` envelope schema |
| Encrypted envelope | Length-prefixed existing `FPBKAEAD` bytes |
| Wrappers | `uint32` count from 1 through 32; each entry is a length-prefixed UTF-8 credential ID and length-prefixed opaque `FPBKWRP1` record |

Each text field is at most 2,048 bytes; each wrapper record is at most 8,192
bytes. Wrapper entries are ordered strictly by credential ID, with no
duplicates. Each wrapper's authenticated context must match the generation's
owner, key epoch and exact envelope metadata. The account binding is
`SHA-256(ASCII "FPBK-GOOGLE-SUB-v1" || 0x00 || ASCII verifiedGoogleSubject)`;
it is based on the verified stable Google subject, not a mutable email
address. The historical account name remains inside the encrypted-envelope
metadata for existing envelope compatibility.

The writer allocates one Drive file ID, generates a random generation ID and
records the exact bytes, SHA-256 digest, owner operation ID, expected parent
head and selected account durably **before** attempting an append-only upload.
The Drive create primitive must never PATCH or DELETE an existing generation.
An upload acknowledgment, timeout, cancellation or missing response cannot
alone mark the backup complete: an uncertain outcome is reconciled by reading
the same preallocated file ID. A retry may use only the same journaled bytes
and ID. The client downloads the uploaded bytes, checks exact file metadata,
size, digest and authenticated generation context, unwraps a key using the
qualified local credential, decrypts the envelope, and verifies the expected
wallet identities and original-key signing/export before advancing the owner
head with a single-use authenticated compare-and-swap operation. The prior
decryptable generation stays addressable until the replacement is verified.

The owner head descriptor includes the generation's own revision, parent
revision/digest, generation ID, bundle digest, key epoch, Drive file ID and
account binding. The client must obtain the expected context and digest from
an authenticated head or its own durable candidate journal. Decoding a
digest-matching generation cannot itself prove that the wallet can be
decrypted, that Drive accounts interoperate, or that a synced passkey works on
a replacement device. Those are separate acceptance tests.

The synthetic cross-platform vector has 785 encoded bytes and SHA-256
`1c92b544dc25c687c202317d0e5747b5690a1056cf72e61d1dfab84c07c057a4`.
It uses parent revision `6`, parent digest `aa` repeated 32 times, key epoch
`7`, the wrapper vector in [the credential-wrapper contract](passkey-credential-wrapper-v1.md),
and the plaintext test string `cross-platform-passkey-backup`. Both mobile
codecs reproduce that digest and round-trip the wrapper. These synthetic
bytes are a format check, not release or device evidence.
