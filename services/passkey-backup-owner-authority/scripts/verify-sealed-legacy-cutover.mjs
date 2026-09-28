import { verifySealedLegacyCutover } from '../src/legacy-cutover-verifier.js';

if (process.argv.length !== 5) {
  process.stderr.write('Usage: node scripts/verify-sealed-legacy-cutover.mjs ABSOLUTE_QUARANTINED_JSON ABSOLUTE_OWNER_SQLITE EXPECTED_SOURCE_SHA256\n');
  process.exitCode = 2;
} else {
  try {
    const report = verifySealedLegacyCutover({
      legacySnapshotPath: process.argv[2], ownerPath: process.argv[3],
      expectedSourceSha256: process.argv[4],
    });
    process.stdout.write(`${JSON.stringify(report, null, 2)}\n`);
    // An exact public representation still cannot prove the link to
    // the random owner or that the deployed JSON writer has been drained.
    process.exitCode = 3;
  } catch {
    process.stderr.write('[legacy-cutover] sealed source or owner store invalid; no migration performed\n');
    process.exitCode = 1;
  }
}
