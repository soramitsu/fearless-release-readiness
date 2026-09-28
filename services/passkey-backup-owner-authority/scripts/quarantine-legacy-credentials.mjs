import { basename } from 'node:path';
import { quarantineLegacyCredentialSnapshot } from '../src/legacy-quarantine.js';

if (process.argv.length !== 6) {
  process.stderr.write('Usage: node scripts/quarantine-legacy-credentials.mjs ABSOLUTE_LEGACY_JSON ABSOLUTE_OWNER_SQLITE PRIVATE_QUARANTINE_DIR EXPECTED_SOURCE_SHA256\n');
  process.exitCode = 2;
} else {
  try {
    const result = quarantineLegacyCredentialSnapshot({
      legacyPath: process.argv[2], ownerPath: process.argv[3],
      quarantineDirectory: process.argv[4], expectedSourceSha256: process.argv[5],
    });
    process.stdout.write(`${JSON.stringify({ schemaVersion: result.schemaVersion,
      mode: result.mode, migrationPermitted: false, sourceSha256: result.sourceSha256,
      snapshotFile: basename(result.snapshotPath), reconciliation: result.reconciliation }, null, 2)}\n`);
    // A valid private snapshot is not authorization to link owners or cut over.
    process.exitCode = 3;
  } catch {
    process.stderr.write('[legacy-quarantine] no migration performed; source, store or private snapshot unavailable\n');
    process.exitCode = 1;
  }
}
