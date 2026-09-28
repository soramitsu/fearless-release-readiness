# Source freeze attestation — 2026-08-01

Before any source cleanup or reconstruction, `scripts/capture-source-freeze.mjs` captured the exact local state of the eight production source repositories. The private raw capture was created at `2026-08-01T08:02:23.466Z` and contains each repository's HEAD, tree, branch, upstream, ahead/behind counts, a full Git binary patch relative to HEAD, NUL-delimited status and untracked inventories, and a collapsed ignored/generated-output inventory.

The raw capture is intentionally excluded from this public repository because it contains local path names and unpublished source patches. Its immutable `manifest.json` SHA-256 is:

```text
444e354655d6c4d6ac6f45fa32e04c883916be0f85c074a42f8685a7e6c31536
```

All files listed by the capture's `SHA256SUMS` verified successfully immediately after creation. The workspace root was not Git-owned at capture time; its intended public source inventory contained 86 files. Root ownership was bootstrapped only after this attestation completed.

| Source | HEAD | Tree | Branch / upstream | Ahead / behind | Tracked changes | Untracked | Generated roots | Binary diff SHA-256 |
| --- | --- | --- | --- | ---: | ---: | ---: | ---: | --- |
| `soramitsu/fearless-Android` | `f072bafba31cc8eba1681f62d16846ead1ff95c1` | `f4c67e8c816be69067b82faf3c1965c71de3ccfb` | `codex/android-xcm-evidence-release-commit` / `origin/codex/android-xcm-evidence-release-commit` | 0 / 1 | 159 | 149 | 49 | `1ae33a52741d040d73f5e21b306efd95e52f7ef681b27333a7e2d986cd0b1bb8` |
| `soramitsu/fearless-iOS` | `eb73120047b5d1dc499e93fde6e7231b042f02eb` | `5f8167df037cce1913b3ddb20074fce8e1309cfe` | `codex/ios-transaction-builder-ci-gate` / `origin/codex/ios-transaction-builder-ci-gate` | 0 / 0 | 120 | 52 | 12 | `1baec3efb3720c6f9039d858c9134a4718061c50ed3740ecf6ed541bedc35ec0` |
| `soramitsu/fearless-wallet-web` | `ff326cc9260b6baffc505c902d414cc1e019f693` | `71172cbe00e38957f7c51f77a35121b0bd9ddc61` | `codex/web-bitcoin-canonical-indexer-evidence` / same remote branch | 0 / 0 | 74 | 67 | 4 | `f643bf479546f6f10e9fafaafa8d84a205998284a52f746d5724f3789de8e81e` |
| `soramitsu/fearless-site-web` | `0856003b75a8d86867e70965a1c364539f5d5924` | `c5b4489ed90b4bf10d1eb1dfc067b36729313709` | `codex/site-todo-debt-baseline-hardening` / no upstream | — | 10 | 6 | 3 | `9f5f8c0492d7914fb4709bfa8f18d01f4353b90523d7c35bc18a1f8c2de9e968` |
| `tonswap-org/ton-indexer` | `2335a094866cf16406bfee3bd9d3998a7e40bc52` | `b9533aef60951760f0d5344129d724a79db97548` | `codex/ti-smoke-body-preview-tests` / same remote branch | 0 / 0 | 22 | 4 | 2 | `1702fbd77b4c6bc1ac36dadcf67e72cca3c0a42c60a63bd294048447fca0884f` |
| `solswap-io/solswap-indexer` | `dc27c55208af1b465837945a473f8af834f061bf` | `373e0b0913a1f812f2140c7284bf857c2c923868` | `codex/si-smoke-body-preview-tests` / same remote branch | 0 / 0 | 21 | 5 | 2 | `68c691e675276c4f77ef9004a05abc0ded834b33ae4ce8c02f6af49c9a26b3e8` |
| `sora-xor/polkaswap-indexer` | `536c6cdf50db3e6629d2cdd97ea795b130b07679` | `4281823cb8368a81dde7a9a6641b9714ddbaa668` | `codex/pi-deployment-evidence-gate` / same remote branch | 1 / 0 | 0 | 0 | 5 | `e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855` |
| `hyperledger-iroha/iroha` | `189c0ee66a2fca6252aff5d9760aed158b6fbfd0` | `831cb804ed400d8126d9cb8fd1a994ec75b1b700` | `optimizations` / `origin/optimizations` | 0 / 0 | 15 | 10 | 99 | `9c017811ed226476b9182911ebc3c9b2331f06f28c77bb60391bfc4204d2fa57` |

“Tracked changes” is the unstaged path count at capture time; every staged count was zero. The empty PI binary-diff hash is the SHA-256 of an empty byte stream because its unpublished source was already committed locally and one commit ahead of its configured upstream. No ignored/generated output was force-added or treated as published source.
