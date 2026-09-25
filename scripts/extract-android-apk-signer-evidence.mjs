#!/usr/bin/env node
import { execFileSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { closeSync, lstatSync, openSync, readSync, realpathSync } from 'node:fs';
import { basename, extname } from 'node:path';
import { pathToFileURL } from 'node:url';

const EXPECTED_PACKAGE = 'jp.co.soramitsu.fearless';
const MAX_APK_BYTES = 512 * 1024 * 1024;
const MAX_TOOL_OUTPUT_BYTES = 1024 * 1024;

function fail(message) {
  throw new Error(message);
}

function assertRegularFile(file, label, { executable = false, maxBytes = MAX_APK_BYTES } = {}) {
  let stat;
  let realPath;
  try {
    stat = lstatSync(file);
    realPath = realpathSync.native(file);
  } catch {
    fail(`${label} missing: ${file}`);
  }
  if (!stat.isFile() || stat.isSymbolicLink() || realPath !== file) {
    fail(`${label} must be an absolute regular non-symlink file`);
  }
  if (stat.size <= 0 || stat.size > maxBytes) {
    fail(`${label} must be 1-${maxBytes} bytes`);
  }
  if (executable && (stat.mode & 0o111) === 0) {
    fail(`${label} must be executable`);
  }
  if (executable && (stat.mode & 0o022) !== 0) {
    fail(`${label} must not be group- or world-writable`);
  }
}

function runTool(file, args, label) {
  const javaHomeCandidates = [
    process.env.JAVA_HOME,
    '/opt/homebrew/opt/openjdk@21/libexec/openjdk.jdk/Contents/Home',
    '/opt/homebrew/opt/openjdk/libexec/openjdk.jdk/Contents/Home',
    '/opt/homebrew/opt/openjdk@17/libexec/openjdk.jdk/Contents/Home',
    '/usr/local/opt/openjdk/libexec/openjdk.jdk/Contents/Home',
  ].filter(Boolean);
  const javaHome = javaHomeCandidates.find((candidate) => {
    try {
      return lstatSync(`${candidate}/bin/java`).isFile();
    } catch {
      return false;
    }
  });
  try {
    return execFileSync(file, args, {
      encoding: 'utf8',
      maxBuffer: MAX_TOOL_OUTPUT_BYTES,
      timeout: 30_000,
      stdio: ['ignore', 'pipe', 'pipe'],
      env: {
        HOME: process.env.HOME || '',
        ...(javaHome ? { JAVA_HOME: javaHome } : {}),
        LANG: 'C',
        LC_ALL: 'C',
        PATH: `${javaHome ? `${javaHome}/bin:` : ''}/usr/bin:/bin:/usr/sbin:/sbin`,
      },
    });
  } catch (error) {
    const stderr = String(error.stderr || '').trim().replace(/\s+/gu, ' ').slice(0, 500);
    fail(`${label} failed${stderr ? `: ${stderr}` : ''}`);
  }
}

function canonicalFingerprint(hexDigest) {
  const upper = hexDigest.toUpperCase();
  return upper.match(/.{2}/gu).join(':');
}

function sha256File(file) {
  const hash = createHash('sha256');
  const buffer = Buffer.allocUnsafe(1024 * 1024);
  const descriptor = openSync(file, 'r');
  try {
    for (;;) {
      const bytesRead = readSync(descriptor, buffer, 0, buffer.length, null);
      if (bytesRead === 0) break;
      hash.update(buffer.subarray(0, bytesRead));
    }
  } finally {
    closeSync(descriptor);
  }
  return `sha256:${hash.digest('hex')}`;
}

export function extractDistributedApkEvidence({ apkFile, apksignerFile, aaptFile }) {
  if (extname(apkFile) !== '.apk' || basename(apkFile) === '.apk') {
    fail('distributed APK evidence path must end in lowercase .apk');
  }
  assertRegularFile(apkFile, 'distributed APK');
  assertRegularFile(apksignerFile, 'Android apksigner', { executable: true, maxBytes: 64 * 1024 * 1024 });
  assertRegularFile(aaptFile, 'Android aapt', { executable: true, maxBytes: 64 * 1024 * 1024 });
  const artifactSha256BeforeVerification = sha256File(apkFile);

  const signerOutput = runTool(
    apksignerFile,
    ['verify', '--verbose', '--print-certs', apkFile],
    'distributed APK signature verification',
  );
  const signerDigests = [...signerOutput.matchAll(
    /^Signer #\d+ certificate SHA-256 digest: ([0-9a-f]{64})$/gmu,
  )].map((match) => match[1]);
  if (signerDigests.length !== 1) {
    fail('distributed APK must verify with exactly one signing certificate');
  }
  if (!/^Signer #1 certificate SHA-256 digest:/mu.test(signerOutput)) {
    fail('distributed APK signer output must identify exactly Signer #1');
  }
  if (!/^Verified using v(?:2|3) scheme .*: true$/mu.test(signerOutput)) {
    fail('distributed APK must verify with APK Signature Scheme v2 or v3');
  }

  const badging = runTool(aaptFile, ['dump', 'badging', apkFile], 'distributed APK package inspection');
  const packageNames = [...badging.matchAll(/^package: name='([^']+)'/gmu)].map((match) => match[1]);
  if (packageNames.length !== 1 || packageNames[0] !== EXPECTED_PACKAGE) {
    fail(`distributed APK package must be exactly ${EXPECTED_PACKAGE}`);
  }

  const artifactSha256 = sha256File(apkFile);
  if (artifactSha256 !== artifactSha256BeforeVerification) {
    fail('distributed APK changed during signer and package verification');
  }
  return {
    source: 'distributed-apk',
    packageName: EXPECTED_PACKAGE,
    artifactSha256,
    signerSha256Fingerprint: canonicalFingerprint(signerDigests[0]),
  };
}

function parseArgs(argv) {
  const values = {};
  for (let index = 0; index < argv.length; index += 2) {
    const option = argv[index];
    const value = argv[index + 1];
    if (!['--apk', '--apksigner', '--aapt'].includes(option) || value === undefined) {
      fail('usage: extract-android-apk-signer-evidence.mjs --apk <file> --apksigner <file> --aapt <file>');
    }
    if (values[option] !== undefined) fail(`duplicate argument: ${option}`);
    values[option] = value;
  }
  for (const option of ['--apk', '--apksigner', '--aapt']) {
    if (values[option] === undefined) fail(`missing required argument: ${option}`);
  }
  return values;
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  try {
    const args = parseArgs(process.argv.slice(2));
    const result = extractDistributedApkEvidence({
      apkFile: args['--apk'],
      apksignerFile: args['--apksigner'],
      aaptFile: args['--aapt'],
    });
    process.stdout.write(`${JSON.stringify(result)}\n`);
  } catch (error) {
    console.error(`[passkey-android-apk-signer][error] ${error.message}`);
    process.exit(1);
  }
}
