#!/usr/bin/env node

import { retireJsonCredentialWriter } from '../src/retire-writer.js';

if (process.argv.length !== 5) {
  process.stderr.write('usage: retire-json-credential-writer.mjs ABSOLUTE_STORE_PATH EXPECTED_SOURCE_SHA256 CUTOVER_MANIFEST_SHA256\n');
  process.exitCode = 2;
} else {
  try {
    const report = retireJsonCredentialWriter({
      credentialStoreFile: process.argv[2],
      expectedSourceSha256: process.argv[3],
      cutoverManifestSha256: process.argv[4],
    });
    process.stdout.write(`${JSON.stringify(report)}\n`);
  } catch {
    process.stderr.write('JSON credential writer retirement failed; inspect the source and lease before any retry\n');
    process.exitCode = 1;
  }
}
