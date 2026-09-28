import { reconcileLegacyCredentialStores } from '../src/legacy-reconciliation.js';

if (process.argv.length !== 4) {
  process.stderr.write('Usage: node scripts/reconcile-legacy-credentials.mjs ABSOLUTE_LEGACY_JSON ABSOLUTE_OWNER_SQLITE\n');
  process.exitCode = 2;
} else {
  try {
    const report = reconcileLegacyCredentialStores({ legacyPath: process.argv[2], ownerPath: process.argv[3] });
    process.stdout.write(`${JSON.stringify(report, null, 2)}\n`);
    // Even a collision-free inventory is not authorization to import or enable.
    process.exitCode = 3;
  } catch {
    process.stderr.write('[legacy-reconciliation] stores unavailable or invalid; no migration performed\n');
    process.exitCode = 1;
  }
}
