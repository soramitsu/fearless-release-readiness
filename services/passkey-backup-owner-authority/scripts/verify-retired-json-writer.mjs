#!/usr/bin/env node

import { verifyRetiredJsonCredentialWriter } from '../src/legacy-retirement-verifier.js';

if (process.argv.length !== 6) {
  process.stderr.write('usage: verify-retired-json-writer.mjs ABSOLUTE_LEGACY_STORE_PATH ABSOLUTE_SEALED_JSON_PATH EXPECTED_SOURCE_SHA256 EXPECTED_CUTOVER_MANIFEST_SHA256\n');
  process.exitCode = 2;
} else {
  try {
    const report = verifyRetiredJsonCredentialWriter({
      credentialStoreFile: process.argv[2], legacySnapshotPath: process.argv[3],
      expectedSourceSha256: process.argv[4], expectedManifestSha256: process.argv[5],
    });
    process.stdout.write(`${JSON.stringify(report)}\n`);
    // Matching read-only artifacts are never replacement-service admission.
    process.exitCode = 3;
  } catch {
    process.stderr.write('Legacy writer retirement readback failed; no production admission authorized\n');
    process.exitCode = 1;
  }
}
