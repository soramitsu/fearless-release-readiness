# Portable wallet semantic material v1 (candidate)

This is the candidate **plaintext** byte contract inside the existing encrypted
`FPBKAEAD` backup envelope. It does not authorize backup, restoration or wallet
installation. The Android and iOS codecs must agree on the bytes and reject the
same invalid records before either platform may write this format. Capture,
cryptographic identity checks, atomic installation, original-key signing/export
and replacement-device recovery remain separate release gates. Plaintext and
decoded secret arrays must be erased after use.

The outer `FPWMLE01` envelope remains version 1. Its new pair is source format
`3` (`portableSemanticV1`) with derivation mode `1` (`portable`), for either
origin `1` Android or `2` iOS. Existing origin-specific local-opaque pairs
remain valid but are never portable. The semantic payload has at most 262,084
bytes: the 256 KiB `FPBKAEAD` plaintext ceiling less its 44-byte header and the
16-byte `FPWMLE01` header. All integers are unsigned big-endian. Text uses
strict UTF-8, with a `u16` byte length and at most 2,048 bytes. Unknown IDs,
duplicate IDs, noncanonical order, truncation and trailing bytes are errors.

```
ASCII "FPWMSM01"  (8 bytes)
u8 version = 1
u16 walletCount in 1...128
u16 selectedIndex < walletCount
wallet[walletCount], in presentation order

wallet:
    portableId[16], nonzero and unique in this snapshot
    u32 sourcePosition (historical value; ties are permitted)
    u8 initialized in {0,1}
    text name (may be empty)
    u8 metadataCount in 0...9
    metadata[metadataCount], ascending unique ID
    u16 slotCount in 1...1412
    slot[slotCount], ascending by role then unsigned UTF-8 key bytes

metadata: u8 ID, u16 valueLength, value[valueLength]
slot: u8 role, text key, u8 fieldCount in 1...23,
      field[fieldCount] in ascending unique ID order
field: u8 ID, u16 valueLength, value[valueLength]
```

The portable ID groups a wallet's roots; it is not a replacement for any
chain-specific address. Record order and `selectedIndex` are authoritative.
Each source app derives a stable 16-byte portable ID from its durable local
wallet ID with an app-specific SHA-256 domain. A receiving installer must
persist and reuse that portable ID for subsequent backup generations instead
of deriving a fresh one from its newly assigned local database ID. It must
still verify every public address against the original signing material.
Each wallet needs at least one root or explicitly non-signable watch identity;
an auxiliary source alone does not count. Root slots use the empty key. Chain
and favorite slots use a nonempty chain ID. Auxiliary and watch keys are
lowercase, zero-padded, four-digit hexadecimal ordinals starting at `0000`.
No role/key pair may repeat. There may be at most 128 chain accounts, 128
favorites, 128 watch identities and 1,024 auxiliary sources per wallet.

| Metadata ID | Meaning and value encoding |
| --- | --- |
| 1 | Asset keys order: `u16 count` followed by `text[count]`. |
| 2 | Unused chain IDs: the same ordered string-list encoding. |
| 3 | Selected currency identifier: raw strict UTF-8. A restoring app must resolve it in its current currency catalog; it must not silently select another currency. The codec accepts empty bytes only for legacy parsing; capture must omit this item when no identifier exists. |
| 4 | Network management filter: raw strict UTF-8 (empty allowed). |
| 5 | Asset visibility: `u16 count`, then ascending unique nonempty `text assetId, u8 hidden` pairs. |
| 6 | Favorite chain IDs: ordered string list; mutually exclusive with role 6 slots. |
| 7 | Asset filter options: ordered string list. |
| 8 | Zero-balance assets hidden: canonical single-byte boolean. |
| 9 | Can export Ethereum mnemonic: canonical single-byte boolean. |

String lists and visibility maps have at most 128 entries. The list order is
preserved, including duplicates if the source itself contains them; the map
must be sorted and unique. Each metadata value is at most 32 KiB.

| Slot role | Key | Required field IDs | Allowed additional field IDs |
| --- | --- | --- | --- |
| 1 Substrate signed root | empty | 1, 2, 7, 8, 11 | 3, 4, 5, 6 |
| 2 EVM signed root | empty | 1, 2, 7, 11 | 3, 4, 5, 6 |
| 3 native TON signed root | empty | 1, 2, 7, 11, 13, 14 | 4, 5, 12 |
| 4 historical V1 Substrate source | empty | 1, 2, 7, 8, 11 | 3, 4, 5, 6, 12 |
| 5 per-chain signed account | chain ID | 1, 2, 7, 8, 9, 10, 11 | 3, 4, 5, 6 |
| 6 favorite chain | chain ID | 10 | none |
| 7 verbatim historical source | ordinal | 11, 15, 16, 17, 19, 20 | 18, 21 when account-bound |
| 8 non-signable watch identity | ordinal | 7, 22 | 1, 8, 9, 10, 13, 14, 23 as constrained below |

| Field ID | Meaning and validation |
| --- | --- |
| 1 | Public key, 1...128 bytes. Optional for EVM/TON watch identities; required for signed and Substrate/chain watch identities. |
| 2 | Private key, 1...32,768 bytes; signed roles only. |
| 3 | SR25519 nonce, 1...32,768 bytes. |
| 4 | Original entropy, 1...32,768 bytes. |
| 5 | Original seed, 1...32,768 bytes. |
| 6 | Derivation path, raw strict UTF-8. |
| 7 | Original account ID or address. Usually 1...128 bytes; V1 SS58 is strict UTF-8, and TON follows field 14. |
| 8 | Protocol crypto type, one byte: `1` SR25519, `2` ED25519, `3` ECDSA. Map explicitly; iOS `CryptoType.rawValue` is 0...2. |
| 9 | Chain name, raw strict UTF-8. |
| 10 | Initialized/favorite, canonical one-byte boolean. |
| 11 | Source recipe, one byte: `0` for normal roots, `1...5` for V1 and auxiliary provenance. |
| 12 | Original mnemonic, raw nonempty strict UTF-8; V1 or native TON only. |
| 13 | TON contract version, exactly byte `2` for the released Wallet V4R2 contract. Other contracts need a reviewed format revision. |
| 14 | TON address encoding, one byte: `1` means canonical 33-byte workchain plus account hash; `2` means nonempty strict UTF-8 TonSwift JSON bytes. |
| 15 | Historical source platform, one byte: `1` Android or `2` iOS. |
| 16 | Historical source slot role, one byte, restricted by platform below. |
| 17 | Historical binding kind, one byte: `1` wallet, `2` Substrate, `3` EVM, `4` TON, `5` chain account. |
| 18 | Chain ID for binding kind 5, nonempty strict UTF-8. |
| 19 | Historical source format, one byte: iOS Keychain `1`, Android V1 SCALE `2`, Android chain V2 SCALE `3`, Android V3 SCALE `4`. |
| 20 | Verbatim historical source bytes, 1...32,768 bytes. These are retained losslessly but never installable by themselves. |
| 21 | Exact account ID for binding kind 5, 1...128 bytes. |
| 22 | Watch ecosystem, one byte: `1` Substrate, `2` EVM, `3` TON, `4` chain. |
| 23 | Watch chain ID, nonempty strict UTF-8, required only for ecosystem 4. |

For V1 role 4, recipe values follow the historical source cases: `1` create,
`2` seed, `3` JSON, `4` mnemonic and `5` unspecified. Recipes 1 and 4 require
both original mnemonic and derived entropy; all others forbid both. JSON and
unspecified forbid a derivation path; unspecified also forbids a seed. This
preserves provenance without pretending a raw key derives from a phrase.

For role 7, Android source-slot roles `10...14` are respectively V1,
Substrate V3, EVM V3, TON V3 and chain V2. They require their matching binding
kind `2, 2, 3, 4, 5` and format `2, 4, 4, 4, 3`. iOS source-slot roles `1...9`
are respectively Substrate secret, Ethereum secret, TON secret, entropy,
Substrate seed, Ethereum seed, Substrate derivation, Ethereum derivation and
universal wallet source. They require format 1 and a compatible wallet/root/
chain binding. TON secret also permits an account binding because the released
capture scans account-scoped TON Keychain tags. Account binding requires both
fields 18 and 21, which must match a role 5 slot; root binding requires a
matching root. Wallet binding attaches to the containing portable wallet.
These opaque bytes preserve historical source material, including incidental
Keychain tags, without granting them signing authority.

For named root-derived chain accounts, field 2 is a checked derived key for
the recorded public account, not a substitute for the original root recipe.
In particular, an iOS Bitcoin field-2 key is the first receive key, not the
account master key. A receiving installer must rederive the named account
from preserved root material, verify its public identity and derivation path,
and prove the complete released signing/export behavior before marking the
wallet restored. It must not promote an auxiliary Keychain slot to signing
authority merely because that slot is present.

Role 8 cannot carry a private key or seed. Substrate and chain watch identities
need fields 1 and 8; chain additionally needs 23. TON watch identities need
fields 13 and 14, and field 7 must satisfy the selected TON address encoding.
An installer must still verify cryptographic identity and chain semantics;
this structural codec does not establish that the bytes are a spendable key.

The canonical one-wallet EVM vector is:

```
4650574d534d303101000100000102030405060708090a0b0c0d0e0f10000000070100014500000102000004010002020302000104070001050b000100
```

The multi-root vector SHA-256 is
`784647ca5aa76953d4d19404d7fe78c461b9df329a2dd698cc8b5cc18b49d22c`.
The full nine-metadata vector SHA-256 is
`181f843dcbafbd0ba151a7476b1f63c3a6060df9c9fd45055869ff8383608b16`.
These vectors must be exercised independently by both platform codecs before
the format is promoted from candidate status.
