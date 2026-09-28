#!/usr/bin/env node

import { verifyLegacyCutoverManifest } from '../src/legacy-cutover-manifest.js';

if (process.argv.length !== 7) {
  process.stderr.write('usage: verify-legacy-cutover-manifest.mjs ABSOLUTE_MANIFEST_PATH EXPECTED_MANIFEST_SHA256 ABSOLUTE_SEALED_JSON_PATH ABSOLUTE_OWNER_SQLITE_PATH EXPECTED_OWNER_IMAGE_SHA256\n');
  process.exitCode = 2;
} else {
  try {
    const report = verifyLegacyCutoverManifest({
      manifestPath: process.argv[2], expectedManifestSha256: process.argv[3],
      legacySnapshotPath: process.argv[4], ownerPath: process.argv[5],
      expectedOwnerImageSha256: process.argv[6],
    });
    process.stdout.write(`${JSON.stringify(report)}\n`);
    // A matched candidate is still not an authorized cutover.
    process.exitCode = 3;
  } catch {
    process.stderr.write('Cutover manifest verification failed; no migration or retirement authorized\n');
    process.exitCode = 1;
  }
}
