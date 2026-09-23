# Fearless release readiness

This repository is the public release-readiness control plane for Fearless Wallet production delivery. It contains the production completion plan, public audit configuration and tooling, documentation, and the passkey backup challenge service.

The repository deliberately excludes application and dependency checkouts, generated outputs, raw release and device evidence, signing material, credentials, and private infrastructure overlays. Those inputs remain in their canonical public source repositories or appropriately access-controlled private systems.

Production completion is defined by [`FEARLESS_PROJECT_PLAN.md`](FEARLESS_PROJECT_PLAN.md) and is not established until every cited gate is satisfied and `scripts/audit-release-readiness.sh` exits successfully without `--skip-live`.

The canonical Iroha source is `../iroha` on `optimizations`, tracking `origin/optimizations` in `hyperledger-iroha/iroha`. Publication checks compare the current local and authoritative remote commit identities; they do not pin an old branch tip or treat historical topic PRs as review of the current source. The source gate remains blocked until a verifiable review/protected policy for the exact canonical commit is implemented and satisfied. An unreviewed branch tip never counts as approval.

The final live passkey smoke also requires [enabled-feature acceptance](docs/passkey-enabled-acceptance.md) bound to the shipping manifest and independent QA/security attestations. Safe disabled defaults are interim evidence, not completed production acceptance.
