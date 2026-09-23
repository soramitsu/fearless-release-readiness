# Client-side passkey credential wrapper v1

This is the common byte contract for the disabled Android and iOS recovery
implementation. It wraps one random 32-byte wallet-backup key (DEK) for one
WebAuthn credential. The existing `FPBKAEAD` v1 wallet-backup envelope remains
unchanged. Neither the DEK nor a native WebAuthn PRF result belongs in a server
request, Drive metadata, logs or crash reports. The owner service stores only
credential/authorization metadata; Drive stores encrypted envelopes and opaque
wrappers. This contract alone does not make a backup recoverable.

All strings below are UTF-8 with a four-byte big-endian byte-length prefix;
integers are signed big-endian and must be nonnegative where appropriate. Base64url
values are unpadded and canonical. The owner subject is `owner:` followed by
exactly 32 random bytes encoded as base64url. A credential ID decodes to 1–384
bytes. The context is:

```
ASCII "FPBKWRAP1"
int32 wrapperVersion = 1
string rpId = "fearlesswallet.io"
string ownerSubject
string envelope.storageKey
string envelope.walletId
string envelope.accountName
int64 envelope.createdAtMillis
int32 envelope.schemaVersion = 1
string credentialId
int64 keyEpoch
```

The client generates a fresh 32-byte `prfSalt` for the native ceremony, a fresh
32-byte `hkdfSalt` and a fresh 12-byte AES-GCM nonce. It requires exactly 32
bytes of local PRF output. HKDF-SHA256 uses `HMAC-SHA256(hkdfSalt, prfOutput)`
for extract and one expand block:

```
KEK = HMAC-SHA256(PRK,
  ASCII "FPBK-PRF-KEK-v1" || context || prfSalt || 0x01)
AAD = ASCII "FPBK-WRAP-AAD-v1" || context || prfSalt || hkdfSalt
ciphertextAndTag = AES-256-GCM(KEK, nonce, backupKey, AAD)
```

The opaque binary record is exact-length and versioned. Decoding requires a
trusted expected context from the verified owner/credential and authenticated
backup-generation manifest. Unknown versions, truncation, extension and
context mismatch fail closed. Authentication failure returns no key.

```
ASCII "FPBKWRP1"                  8 bytes
int32 wrapperVersion = 1          4 bytes
int32 contextLength                4 bytes, at most 4096
context                            contextLength bytes
prfSalt                            32 bytes
hkdfSalt                           32 bytes
nonce                              12 bytes
ciphertextAndTag                   48 bytes
```

The deterministic cross-platform vector uses owner
`owner:ERERERERERERERERERERERERERERERERERERERERERE`, credential
`IiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiI`, storage key `wallet-1234`, wallet
ID `wallet-001`, Google account name `alice@example.com`, creation time
`1767225600000`, envelope schema 1 and key epoch 7. Set the PRF salt to `0x33`
repeated 32 times, HKDF salt to `0x44` repeated 32 times, nonce to `0x55`
repeated 12 times, local PRF output to `0x66` repeated 32 times, and backup key
to `0x77` repeated 32 times. The context is 204 bytes with SHA-256
`8904743b6310afddbf7dec05ae3a4f6d1de438a0a51847eb598e5fe55bce93e3`.
The KEK is `a70d98717014284aa2932615c28fb61152e8e20606303ce48b9fc2968b2d3d60`.
The ciphertext plus tag is
`m_xnd6ezMk5VjmGJjqjAVrBDJYQTp7NxcktIT8CmyM8uzo4ZphIMYP-2QRflGgs5`
in base64url. The full binary record is 344 bytes with SHA-256
`2ac784e30e93efb4a7fe2505724e1c67ae6f4f16e9aa834029e0bb08c27509dc`.

Enrollment must acquire a real native PRF result from the exact credential
before declaring a wrapper usable. Some providers do not return a PRF result at
credential creation, so an authenticated assertion may be required. An absent
PRF result is a hard failure. Restoration also requires the synchronized
provider credential and the selected Google Drive account, both qualified on
replacement devices. Removing a credential must revoke server access and
rotate the DEK for survivors; retain the last decryptable immutable generation
until its successor has been downloaded and decrypted. These lifecycle and
storage requirements are not implemented by the wrapper primitive.
