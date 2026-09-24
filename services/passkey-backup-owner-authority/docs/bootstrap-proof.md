# First-owner bootstrap proof v1 (candidate)

This is a candidate native/server interoperability contract, not a deployed recovery path. A fresh random owner is created only after a local wallet signature, platform app attestation, and first WebAuthn registration are verified. Google sign-in and a client-provided wallet label do not authorize an owner. The app attestation and wallet proof are checked in memory and are never persisted; the authority stores only the normalized public wallet binding and public credential metadata.

The wallet signs these bytes, in order:

1. ASCII `FP_OWNER_BOOTSTRAP_WALLET_V1` followed by a zero byte.
2. Eight fields, each preceded by its unsigned 32-bit big-endian byte length: ceremony ID as UTF-8; decoded 32-byte server challenge; ASCII RP ID `fearlesswallet.io`; ASCII platform `android` or `ios`; random owner subject as UTF-8; random backup namespace as UTF-8; decoded 32-byte WebAuthn user handle; and the 32-byte SHA-256 registration commitment.

The registration commitment is SHA-256 over the UTF-8 JSON encoding of this **positional array** (no whitespace):

```text
[id,rawId,type,authenticatorAttachment|null,credProps.rk|null,
 clientDataJSON,attestationObject,authenticatorData|null,
 publicKeyAlgorithm|null,publicKey|null,transports|null]
```

All base64url strings must be canonical and unpadded. Optional absent properties become `null`, while the transports array preserves its supplied order. The server rejects unknown properties, PRF output and largeBlob data before constructing the commitment. This is a public WebAuthn response commitment, not a hash of wallet backup bytes.

Ed25519 signs the message bytes directly with a 32-byte public key and 64-byte signature. secp256k1 signs SHA-256 of the message using a 64-byte IEEE P1363 signature; compressed 33-byte and uncompressed 65-byte public keys normalize to the same compressed key. SR25519 is deliberately rejected until a reviewed verifier and native vectors are available. The stable public owner binding is SHA-256 of ASCII `FP_OWNER_WALLET_BINDING_V1` plus zero byte, then length-prefixed scheme and normalized public-key bytes.

The platform attestation nonce is SHA-256 of ASCII `FP_OWNER_BOOTSTRAP_APP_V1` plus zero byte, then length-prefixed wallet message, scheme, normalized public-key bytes and signature bytes. It is encoded as canonical unpadded base64url. The server-configured Android app identity is `android:<packageName>:<lowercase Play signing certificate SHA-256 hex>`; the iOS identity is `ios:<TeamID>:<bundleID>`. Every allowed Android WebAuthn origin must encode that same Play signing certificate digest. A trusted server adapter must verify the actual Play Integrity token or App Attest object and return **exactly** that nonce, platform and app identity. Truthy flags or echoes supplied by a client are insufficient. No such platform adapter is shipped here, so omission keeps bootstrap unavailable and the production HTTP factory still rejects construction.

The one-use ceremony is claimed before asynchronous verification. A bad proof may burn that ceremony but cannot create or reassign an owner. A native client must keep local PRF output and backup keys out of this request entirely. Production admission still requires real Apple/Google attestation validation, SR25519 support for relevant wallets, historical-owner migration, native vectors, independent review and replacement-device tests.
