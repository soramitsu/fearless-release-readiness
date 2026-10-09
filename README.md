# Fearless release readiness

This repository is the public release-readiness control plane for Fearless Wallet production delivery. It contains the production completion plan, public audit configuration and tooling, documentation, and the passkey backup challenge service.

The repository deliberately excludes application and dependency checkouts, generated outputs, raw release and device evidence, signing material, credentials, and private infrastructure overlays. Those inputs remain in their canonical public source repositories or appropriately access-controlled private systems.

The application and dependency repositories use stable folder names such as
`fearless-Android`, `fearless-iOS`, and `fearless-utils-Android`. Their GitHub
repositories, branches, and exact commits are checked in at
[`config/workspace-repositories.json`](config/workspace-repositories.json).
Source belongs in those repositories; temporary release worktrees are not
required to reconstruct this workspace.

From a fresh clone, with Git and Node.js 22 or newer installed:

```sh
node scripts/setup-workspace.mjs
node scripts/setup-workspace.mjs --check
```

Setup clones the eight public application/dependency repositories at their
pinned commits. It verifies existing folders and refuses to overwrite local
changes, a different branch or commit, or an unrelated repository. `--check`
is offline and makes no changes. Commit and push source in its owning repository,
then update the manifest's branch and commit when adopting a new revision.

Add `--include-services` to also clone the four indexer/Iroha sibling repositories,
or `--include-private` for the private mobile overlays and keys repository
(requires GitHub access). Existing sibling work is never reset by setup.
Generated credentials, signing material, and local build evidence are not
included in the manifest and must still come from authorized private systems.

Before running Android commands in this multi-repository workspace, load the
canonical dependency paths into Bash or Zsh:

```sh
source <(node scripts/setup-workspace.mjs --env)
cd fearless-Android
./gradlew help
```

The manifest also records preservation branches for local utility and website
edits saved during consolidation. Those branches are pushed to their owning
repositories and are not designated release candidates. Manifest pins establish
reproducible source, not release approval; the publication and shipping audits
still check their independent review and evidence requirements.

Production completion is defined by [`FEARLESS_PROJECT_PLAN.md`](FEARLESS_PROJECT_PLAN.md) and is not established until every cited gate is satisfied and `scripts/audit-release-readiness.sh` exits successfully without `--skip-live`.

The canonical Iroha source is `../iroha` on `optimizations`, tracking `origin/optimizations` in `hyperledger-iroha/iroha`. Publication checks compare the current local and authoritative remote commit identities; they do not pin an old branch tip or treat historical topic PRs as review of the current source. The source gate remains blocked until a verifiable review/protected policy for the exact canonical commit is implemented and satisfied. An unreviewed branch tip never counts as approval.

The final live passkey smoke also requires [enabled-feature acceptance](docs/passkey-enabled-acceptance.md) bound to the shipping manifest and independent QA/security attestations. Safe disabled defaults are interim evidence, not completed production acceptance.
