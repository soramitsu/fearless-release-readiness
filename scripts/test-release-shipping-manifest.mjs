#!/usr/bin/env node
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { appendFileSync, mkdirSync, mkdtempSync, readFileSync, renameSync, rmSync, symlinkSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';
import test from 'node:test';
import { auditReleaseShippingManifest } from './audit-release-shipping-manifest.mjs';

const HEX40 = 'a'.repeat(40);
const HEX64 = 'b'.repeat(64);
const sourceRows = [
  ['fearless-Android-production-consolidated-20260731', 'soramitsu/fearless-Android', 'codex/android-production-consolidated-20260731', 'develop', '1260'],
  ['fearless-iOS-production-consolidated-20260731', 'soramitsu/fearless-iOS', 'codex/testflight-redesign-2026.8.17', 'develop', '1304'],
  ['fearless-wallet-web', 'soramitsu/fearless-wallet-web', 'codex/web-bitcoin-canonical-indexer-evidence', 'develop', '1062'],
  ['fearless-site-web', 'soramitsu/fearless-site-web', 'codex/site-todo-debt-baseline-hardening', 'develop', '45'],
  ['../ton-indexer', 'tonswap-org/ton-indexer', 'codex/ti-smoke-body-preview-tests', 'develop', '13'],
  ['../solswap-indexer', 'solswap-io/solswap-indexer', 'codex/si-smoke-body-preview-tests', 'develop', '16'],
  ['../polkaswap-indexer', 'sora-xor/polkaswap-indexer', 'codex/pi-deployment-evidence-gate', 'develop', '1'],
  ['../iroha', 'hyperledger-iroha/iroha', 'optimizations', 'optimizations', '-'],
];
const dependencyPaths = {
  'android-utils': 'fearless-utils-Android',
  'android-websocket': 'fearless-nv-websocket-production-20260922',
  'ios-shared-features': 'shared-features-spm-production-20260922',
  'ios-starscream': 'fearless-starscream-production-20260922',
};
const filePaths = {
  'passkey-policy': 'config/passkey-backup-production.json',
  'android-route-manifest': 'fearless-Android-production-consolidated-20260731/common/src/main/assets/mutation_route_manifest.json',
  'android-mutation-policy': 'fearless-Android-production-consolidated-20260731/common/src/main/assets/mutation_authorization_policy.json',
  'android-mutation-trust': 'fearless-Android-production-consolidated-20260731/common/src/main/assets/mutation_authorization_trust.json',
  'android-dependency-verification': 'fearless-Android-production-consolidated-20260731/gradle/verification-metadata.xml',
  'android-settings-lock': 'fearless-Android-production-consolidated-20260731/settings-gradle.lockfile',
  'android-buildscript-lock': 'fearless-Android-production-consolidated-20260731/buildscript-gradle.lockfile',
  'android-app-lock': 'fearless-Android-production-consolidated-20260731/app/gradle.lockfile',
  'ios-pods-lock': 'fearless-iOS-production-consolidated-20260731/Podfile.lock',
  'ios-workspace-packages': 'fearless-iOS-production-consolidated-20260731/fearless.xcworkspace/xcshareddata/swiftpm/Package.resolved',
  'ios-project-packages': 'fearless-iOS-production-consolidated-20260731/fearless.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved',
  'ios-dependency-packages': 'fearless-iOS-production-consolidated-20260731/Packages/FearlessDependencies/Package.resolved',
};
const artifactKinds = [
  'android-aab', 'play-distributed-apk', 'apple-delivered-ipa',
  'iroha-android-sdk', 'iroha-ios-sdk',
];
const evidenceKinds = [
  'ios-to-replacement-android', 'android-to-replacement-ios',
  'drive-appdata-interoperability', 'sanitized-network-traffic',
  'play-signed-upgrade', 'apple-delivered-upgrade',
  'independent-security-review', 'funded-transfers',
  'migration-and-restart', 'production-services',
  'ios-compiled-route-inventory', 'ios-compiled-feature-policy',
];

function digest(bytes) { return createHash('sha256').update(bytes).digest('hex'); }
function canonical(value) {
  if (Array.isArray(value)) return value.map(canonical);
  if (value && typeof value === 'object') {
    return Object.fromEntries(Object.keys(value).sort().map((key) => [key, canonical(value[key])]));
  }
  return value;
}
function write(root, relative, bytes) {
  const file = path.join(root, relative);
  mkdirSync(path.dirname(file), { recursive: true });
  writeFileSync(file, bytes);
  return file;
}
function git(directory, ...args) {
  return execFileSync('/usr/bin/git', ['-C', directory, ...args], { encoding: 'utf8' }).trim();
}
function commit(directory) {
  git(directory, 'add', '.');
  git(directory, '-c', 'user.name=Manifest Test', '-c', 'user.email=manifest-test@example.invalid',
    'commit', '-m', 'Synthetic source for manifest audit');
  return git(directory, 'rev-parse', 'HEAD');
}
function repository(directory, branch) {
  mkdirSync(directory, { recursive: true });
  git(directory, 'init', '-q', '-b', branch);
  write(directory, 'fixture.txt', `${branch}\n`);
  return commit(directory);
}

function fixture() {
  const sandbox = mkdtempSync(path.join(tmpdir(), 'fearless-shipping-manifest-'));
  const root = path.join(sandbox, 'fearless');
  mkdirSync(root);
  git(root, 'init', '-q', '-b', 'codex/release-readiness-root-owner');
  write(root, '.gitignore', '/config/release-shipping-manifest.json\n/build/\n/fearless-*\n/shared-features-spm-production-20260922/\n');
  write(root, 'config/source-publication-readiness.tsv',
    `# synthetic source inventory\n${sourceRows.map((row) => row.join('\t')).join('\n')}\n`);
  write(root, 'config/source-publication-root-owner.json', JSON.stringify({
    repository: 'soramitsu/fearless-release-readiness', head: 'codex/release-readiness-root-owner',
  }));
  const repositories = sourceRows.map(([relative, name, head]) => ({
    path: relative, repository: name, head, sourceCommit: repository(path.resolve(root, relative), head),
  }));
  const dependencies = Object.entries(dependencyPaths).map(([role, relative]) => ({
    role, path: relative, sourceCommit: repository(path.resolve(root, relative), 'main'),
  }));
  const files = Object.entries(filePaths).map(([kind, relative]) => {
    const bytes = kind === 'passkey-policy' ? '{"releaseEnabled":true}\n' : `${kind}\n`;
    write(root, relative, bytes);
    return { kind, path: relative, sha256: digest(bytes) };
  });
  for (const row of repositories.slice(0, 2)) {
    row.sourceCommit = commit(path.resolve(root, row.path));
  }
  const artifacts = artifactKinds.map((kind) => {
    const relative = `build/reports/shipping/${kind}.bin`;
    const bytes = `synthetic ${kind}\n`;
    write(root, relative, bytes);
    const sourceCommit = kind.startsWith('iroha-') ? repositories[7].sourceCommit
      : kind === 'apple-delivered-ipa' ? repositories[1].sourceCommit : repositories[0].sourceCommit;
    return { kind, path: relative, sha256: digest(bytes), sourceCommit };
  });
  const evidence = evidenceKinds.map((kind) => {
    const relative = `build/reports/shipping/evidence/${kind}.txt`;
    const bytes = `synthetic ${kind}\n`;
    write(root, relative, bytes);
    return { kind, path: relative, sha256: digest(bytes) };
  });
  const rootCommit = commit(root);
  const manifest = {
    schemaVersion: 1, releaseId: 'synthetic-release-1',
    root: { repository: 'soramitsu/fearless-release-readiness', head: 'codex/release-readiness-root-owner', sourceCommit: rootCommit },
    repositories, dependencies, files, artifacts, evidence,
    routeInventories: {
      androidSha256: files.find((row) => row.kind === 'android-route-manifest').sha256,
      iosSha256: evidence.find((row) => row.kind === 'ios-compiled-route-inventory').sha256,
    },
    featurePolicies: {
      rootPasskeySha256: files[0].sha256,
      androidMutationSha256: files.find((row) => row.kind === 'android-mutation-policy').sha256,
      iosMutationSha256: evidence.find((row) => row.kind === 'ios-compiled-feature-policy').sha256,
    },
    distribution: {
      androidPackage: 'jp.co.soramitsu.fearless', playSigningCertificateSha256: HEX64,
      iosBundleId: 'jp.co.soramitsu.fearlesswallet', appleTeamId: 'YLWWUD25VZ',
    },
    android: { sourceCommit: repositories[0].sourceCommit,
      artifactSha256: artifacts[1].sha256, compiledPasskeyRecoveryEnabled: true },
    ios: { sourceCommit: repositories[1].sourceCommit,
      artifactSha256: artifacts[2].sha256, compiledPasskeyRecoveryEnabled: true },
    googleApplicationId: 'synthetic-shared-google-application',
    passkeyConfigSha256: files[0].sha256,
  };
  const manifestFile = path.join(root, 'config/release-shipping-manifest.json');
  const save = () => writeFileSync(manifestFile, `${JSON.stringify(canonical(manifest), null, 2)}\n`);
  save();
  return { sandbox, root, manifest, save };
}

test('detached manifest binds clean exact source, dependency, file, artifact and evidence identities', () => {
  const f = fixture();
  try {
    assert.equal(auditReleaseShippingManifest(f.root).releaseId, 'synthetic-release-1');
    write(f.root, 'build/reports/shipping/android-aab.bin', 'substituted artifact\n');
    assert.throws(() => auditReleaseShippingManifest(f.root), /android-aab digest mismatch/u);
    write(f.root, 'build/reports/shipping/android-aab.bin', 'synthetic android-aab\n');
    f.manifest.artifacts.find((row) => row.kind === 'iroha-ios-sdk').sourceCommit = HEX40;
    f.save();
    assert.throws(() => auditReleaseShippingManifest(f.root), /iroha-ios-sdk source binding mismatch/u);
  } finally { rmSync(f.sandbox, { recursive: true, force: true }); }
});

test('dirty checkout and substituted Iroha branch fail before shipping', () => {
  const f = fixture();
  try {
    appendFileSync(path.join(f.root, sourceRows[0][0], 'fixture.txt'), 'dirty\n');
    assert.throws(() => auditReleaseShippingManifest(f.root), /source is dirty/u);
    write(f.root, `${sourceRows[0][0]}/fixture.txt`, `${sourceRows[0][2]}\n`);
    f.manifest.repositories[7].head = 'codex/other-iroha-branch';
    f.save();
    assert.throws(() => auditReleaseShippingManifest(f.root), /source selection substituted/u);
  } finally { rmSync(f.sandbox, { recursive: true, force: true }); }
});

test('manifest requires canonical unique-key bytes and complete release inputs', () => {
  const f = fixture();
  try {
    const manifestFile = path.join(f.root, 'config/release-shipping-manifest.json');
    writeFileSync(manifestFile, `${readFileSync(manifestFile, 'utf8').trim()} `);
    assert.throws(() => auditReleaseShippingManifest(f.root), /unique canonical JSON/u);
    f.manifest.evidence.pop();
    f.save();
    assert.throws(() => auditReleaseShippingManifest(f.root), /evidence coverage mismatch/u);
    f.manifest.evidence = evidenceKinds.map((kind) => ({
      kind, path: `build/reports/shipping/evidence/${kind}.txt`, sha256: digest(`synthetic ${kind}\n`),
    }));
    f.manifest.files[0].sha256 = HEX64;
    f.manifest.passkeyConfigSha256 = HEX64;
    f.manifest.featurePolicies.rootPasskeySha256 = HEX64;
    f.save();
    assert.throws(() => auditReleaseShippingManifest(f.root), /passkey-policy digest mismatch/u);
  } finally { rmSync(f.sandbox, { recursive: true, force: true }); }
});

test('checkout symlink substitution is rejected even when its Git commit is identical', () => {
  const f = fixture();
  try {
    const original = path.join(f.root, dependencyPaths['android-websocket']);
    const moved = `${original}.moved`;
    renameSync(original, moved);
    symlinkSync(moved, original);
    assert.throws(() => auditReleaseShippingManifest(f.root), /checkout path is substituted/u);
  } finally { rmSync(f.sandbox, { recursive: true, force: true }); }
});
