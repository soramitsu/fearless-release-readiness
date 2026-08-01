# Fearless release readiness

This repository is the public release-readiness control plane for Fearless Wallet production delivery. It contains the production completion plan, public audit configuration and tooling, documentation, and the passkey backup challenge service.

The repository deliberately excludes application and dependency checkouts, generated outputs, raw release and device evidence, signing material, credentials, and private infrastructure overlays. Those inputs remain in their canonical public source repositories or appropriately access-controlled private systems.

Production completion is defined by [`FEARLESS_PROJECT_PLAN.md`](FEARLESS_PROJECT_PLAN.md) and is not established until every cited gate is satisfied and `scripts/audit-release-readiness.sh` exits successfully without `--skip-live`.
