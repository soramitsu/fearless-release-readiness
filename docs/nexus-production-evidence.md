# Nexus production evidence contract

`config/nexus-production-evidence.json` is deliberately blocked. A release
operator starts from the generated template and may set it to `ready` only after
all required public evidence exists.

## Canonical governance artifact

The exact Iroha commit in `routeManifestCommit` must contain
`artifacts/nexus/production-route-governance-action.json`. The legacy
`UpsertSccpRouteManifest` shape is not accepted: the current Iroha data model
uses the supported `ApplySccpRouteGovernance` instruction. The artifact is
bounded to 256 KiB and has this exact structure:

```json
{
  "schemaVersion": 1,
  "network": "sora-nexus-mainnet",
  "chainId": "sora:nexus:global",
  "publicationInstruction": {
    "kind": "ApplySccpRouteGovernance",
    "wireId": "iroha_data_model::isi::bridge::ApplySccpRouteGovernance",
    "encoded": "0x<lowercase canonical Norito instruction bytes>"
  }
}
```

The verifier computes `sha256:<lowercase hex>` over the raw bytes represented
by `publicationInstruction.encoded`. That digest must equal every recorded
`routeManifestHash`. The historical evidence field names are retained for
manifest compatibility, but the hash now identifies one exact, closed route
governance action—not an operator-authored JSON route manifest. A governance
authority must commit and execute these exact bytes; the evidence gate does not
pretend that an unsupported direct route upsert or Nexus settlement exists.

Git reads use an absolute executable, ignore global/system configuration and
replacement objects, and read the artifact from the pinned 40-character commit.
The ledger-latest verified publication must use the expected current Iroha
commit (or the explicit release commit override).

## On-chain receipt proof

For every publication, canary, and Android/iOS/web wallet smoke transaction the
audit makes three credential-free requests to the hard-coded Minamoto origin:

1. `GET /v1/pipeline/transactions/status?hash=<64 lowercase hex>&scope=global`.
2. `POST /v1/mcp`, JSON-RPC `tools/call` for `iroha.transactions.get` with the
   transaction hash.
3. `POST /v1/mcp`, JSON-RPC `tools/call` for `iroha.instructions.list`, filtered
   by transaction hash and committed status with `page=0&per_page=2`.

Requests use no authorization, cookies, client secrets, URL credentials, or
ambient endpoint override. They use a single 10-second deadline that includes
reading the complete body, manual redirect mode, exact response URL, HTTP 200,
JSON content type, strict UTF-8, and a 64-KiB decoded-body cap.

The pipeline response must match the real `PipelineTransactionStatusResponse`
DTO: the requested hash, `scope=global`, terminal `status.kind=Applied`, a
positive block height, no rejection, and `resolved_from=cache|state`.

The transaction detail must match the real `ExplorerTransactionDetailDto`: the
same hash, authority, creation time, and block; `status=Committed`;
`executable=Instructions`; no rejection; and exactly one instruction. Its
signature must be present and its signed transaction metadata must be exactly:

```json
// Publication
{
  "evidence_role": "route-publication",
  "route_governance_action_hash": "sha256:<64 lowercase hex>"
}

// Canary
{
  "evidence_role": "route-canary",
  "route_governance_action_hash": "sha256:<64 lowercase hex>"
}

// Wallet smoke
{
  "evidence_role": "wallet-smoke",
  "route_governance_action_hash": "sha256:<64 lowercase hex>",
  "wallet_platform": "android|ios|web",
  "wallet_commit": "<40 lowercase git hex>"
}
```

All metadata values are JSON strings and extra metadata keys fail closed. This
binding must be present before signing; a receipt-side field cannot substitute
for signed transaction metadata. Android, iOS, and web now expose exact,
operator-only wallet-smoke request seams that snapshot and validate these four
fields before the signer boundary, require Nexus plus the canonical Minamoto
origin, and leave ordinary transfers metadata-free. None of those seams enables
production send: mobile defaults still use unavailable signers, the staged
Android codec remains Taira-only and rejects wallet-smoke metadata, and the web
release flag remains disabled. A reviewed Nexus codec and funded live receipt
are still required independently on every platform.

The instruction page must use the real `{pagination,items}` response with one
item, `total_items=1`, index zero, and the same hash, authority, creation time,
status, and block. Publication evidence must reproduce the pinned
`ApplySccpRouteGovernance` bytes and fallback explorer JSON exactly. Canary and
wallet evidence must contain one `iroha.transfer` / `Transfer` / `Asset`
instruction whose source, destination, asset, and amount match the manifest.
Self-transfers are rejected.

Status, transaction-detail, and instruction block heights must agree. Among the
evidence-listed and verified publications, the ledger block—not an
evidence-supplied timestamp—selects the unique latest publication. Every canary
and wallet receipt must bind that publication hash and occur in a later block.
Distinct transaction hashes are required across all records.

Explorer `created_at` must exactly equal `publishedAt`,
`routeCanaryCheckedAt`, or `walletSmokeSubmittedAt`. Canonical UTC RFC3339 with
optional 1–9 digit fractions is accepted because normal wallet builders use
millisecond creation times. Canary time, wallet submission time, and wallet
observation time must all be within the 24-hour readiness window; checking only
the observation time is insufficient to prevent an old transaction replay.
The generated fill-in template therefore uses timestamp placeholders ending in
`_RFC3339`. Legacy Nexus placeholders ending in `_SECONDS` are not aliases and
must be rejected by bundle export and verification instead of silently changing
the evidence representation.

## Trust boundary and release command

The current pipeline and Explorer DTOs do not return a chain/network identifier,
so this gate cannot cryptographically prove chain identity from those receipts.
It pins the credential-free `https://minamoto.sora.org` origin and cross-checks
three views from that node, but Minamoto remains one trust domain and the
responses are not independent inclusion proofs. The verifier also cannot prove
that an operator omitted no later `ApplySccpRouteGovernance` transaction because
the current contract does not enumerate a canonical current route state. These
residual dependencies must remain explicit in release review.

Run the real release gate only as:

```sh
bash scripts/audit-nexus-production-evidence.sh --require-ready
```

`--self-test-receipts` exists only for the adversarial test suite. It requires
an explicit marker, confines evidence and fixtures to the system temporary
directory, and cannot be combined with `--require-ready`; fixtures cannot
satisfy the release command.
