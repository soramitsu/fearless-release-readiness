# Locked dependency advisory scan

Run the read-only scanner against the exact candidate lockfiles. It sends only
package coordinates and Git revisions to the public OSV API; it does not install
packages, execute their scripts, or read credentials.

```sh
node --test scripts/test-locked-dependency-scan.mjs
node scripts/scan-locked-dependencies.mjs output/dependency-scan.json \
  services/passkey-backup-challenge-service/package-lock.json \
  services/passkey-backup-owner-authority/package-lock.json
```

Additional positional inputs may be Yarn Berry `yarn.lock`, Gradle
`gradle.lockfile`, SwiftPM `Package.resolved`, CocoaPods `Podfile.lock`, Rust
`Cargo.lock`, or Bundler `Gemfile.lock`. Pass the release candidate's files explicitly; the canonical
workspace and a pending release branch may have different dependency graphs.
Scan native-library Cargo locks as well as the mobile package resolvers.

The report hashes every input, records the scan time, combines duplicate
coordinates while retaining every source path, and includes advisory details.
Swift packages are queried by both URL/version and exact Git revision because
the two indexes can have different coverage. The scanner follows each result's
pagination and rejects truncated or malformed responses. Exit status is 0 for
no known advisory matches, 1 for matches, and 2 for an incomplete/failed scan.
An older report file is not evidence for a failed newer invocation: check the
process exit status, report timestamp and input hashes together.

## Coverage and review

- Gemfile locks query registry gems and the exact Bundler tool version in
  `BUNDLED WITH` as RubyGems packages. A present but empty, malformed, or repeated
  `BUNDLED WITH` section fails the scan. Older locks without that section do not
  identify the Bundler version; review the build environment separately.
- OSV does not support a CocoaPods package ecosystem. Pod versions are recorded
  as coverage gaps, and only exact Git checkout commits can be queried. Review
  CocoaPods source and upstream advisories separately.
- Vendored, patched and local resolutions are explicit coverage gaps. Review
  their provenance, patches and focused regression tests independently.
- Git commit results depend on OSV indexing and do not prove fork equivalence.
- A matching advisory is a triage input. Check affected functions, build versus
  runtime usage, target platform, and any mitigations before changing wallet
  cryptography or declaring a finding unreachable.
- A zero-match scan proves neither absence of malicious code nor release
  readiness. Opaque binaries, licenses, runtime remote imports, exposed service
  secrets, source pinning and immutable artifact verification need separate
  review. Keep confidential incident findings in ignored local evidence.

API contract: [OSV batch queries and pagination](https://google.github.io/osv.dev/post-v1-querybatch/).
