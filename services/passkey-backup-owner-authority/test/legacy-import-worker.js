import { importSealedLegacyCredentialCohort } from '../src/legacy-import.js';

try {
  const [legacySnapshotPath, ownerPath, expectedSourceSha256, expectedCandidateSha256] = process.argv.slice(2);
  const result = importSealedLegacyCredentialCohort({ legacySnapshotPath, ownerPath,
    expectedSourceSha256, expectedCandidateSha256,
    now: () => 1_800_000_000_000, monotonic: () => 0 });
  process.stdout.write(`${JSON.stringify(result)}\n`);
} catch (error) {
  process.stderr.write(`${error.code ?? 'error'}\n`);
  process.exitCode = 1;
}
