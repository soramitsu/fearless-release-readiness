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
  ['fearless-site-web-app-associations-20260726', 'soramitsu/fearless-site-web', 'fix/app-association-publication', 'develop', '49'],
  ['../ton-indexer', 'tonswap-org/ton-indexer', 'codex/ti-smoke-body-preview-tests', 'develop', '13'],
  ['../solswap-indexer', 'solswap-io/solswap-indexer', 'codex/si-smoke-body-preview-tests', 'develop', '16'],
  ['../polkaswap-indexer', 'sora-xor/polkaswap-indexer', 'codex/pi-deployment-evidence-gate', 'develop', '1'],
  ['../iroha', 'hyperledger-iroha/iroha', 'optimizations', 'optimizations', '-'],
];
const dependencyPaths = {
  'android-utils': 'fearless-utils-Android-production-20260922',
  'android-websocket': 'fearless-nv-websocket-production-20260922',
  'ios-shared-features': 'shared-features-spm-production-20260922',
  'ios-starscream': 'fearless-starscream-production-20260922',
};
const dependencyRepositories = {
  'android-utils': 'soramitsu/fearless-utils-Android',
  'android-websocket': 'soramitsu/fearless-nv-websocket-client',
  'ios-shared-features': 'soramitsu/shared-features-spm',
  'ios-starscream': 'soramitsu/fearless-starscream',
};
const filePaths = {
  'passkey-policy': 'config/passkey-backup-production.json',
  'android-route-manifest': 'fearless-Android-production-consolidated-20260731/common/src/main/assets/mutation_route_manifest.json',
  'android-approved-routes': 'fearless-Android-production-consolidated-20260731/runtime/src/main/assets/approved_xcm_routes.tsv',
  'android-required-routes': 'fearless-Android-production-consolidated-20260731/scripts/xcm-required-routes.tsv',
  'android-discovery-gaps': 'fearless-Android-production-consolidated-20260731/scripts/xcm-discovery-only-routes.tsv',
  'android-local-chains': 'fearless-Android-production-consolidated-20260731/runtime/src/main/assets/local_chains.json',
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
const ROUTE_ROW = `${'a'.repeat(64)} ${'b'.repeat(64)} DOT\n`;
const LOCAL_CHAINS = '{}\n';
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
  git(directory, '-c', 'gc.auto=0', '-c', 'maintenance.auto=false',
    '-c', 'user.name=Manifest Test', '-c', 'user.email=manifest-test@example.invalid',
    'commit', '-m', 'Synthetic source for manifest audit');
  return git(directory, 'rev-parse', 'HEAD');
}
function repository(directory, branch, origin) {
  mkdirSync(directory, { recursive: true });
  git(directory, 'init', '-q', '-b', branch);
  if (origin) git(directory, 'remote', 'add', 'origin', origin);
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
    role, path: relative, sourceCommit: repository(path.resolve(root, relative), 'main',
      `https://github.com/${dependencyRepositories[role]}.git`),
  }));
  const selected = (role) => dependencies.find((row) => row.role === role);
  const tree = (role) => git(path.join(root, dependencyPaths[role]), 'rev-parse', 'HEAD^{tree}');
  write(root, `${dependencyPaths['ios-shared-features']}/Package.swift`,
    `.package(url: "https://github.com/soramitsu/fearless-starscream", .revision("${selected('ios-starscream').sourceCommit}"))\n`);
  selected('ios-shared-features').sourceCommit = commit(path.join(root, dependencyPaths['ios-shared-features']));
  write(root, `${sourceRows[0][0]}/config/android-runtime-source-pins.json`, `${JSON.stringify({
    schemaVersion: 1,
    utils: { repository: dependencyRepositories['android-utils'], commit: selected('android-utils').sourceCommit,
      tree: tree('android-utils') },
    websocket: { repository: dependencyRepositories['android-websocket'], commit: selected('android-websocket').sourceCommit,
      tree: tree('android-websocket') },
  })}\n`);
  for (const [role, relative, repositoryUrl] of [
    ['ios-shared-features', 'config/shared-features-source.json', 'https://github.com/soramitsu/shared-features-spm.git'],
    ['ios-starscream', 'config/starscream-source.json', 'https://github.com/soramitsu/fearless-starscream'],
  ]) {
    write(root, `${sourceRows[1][0]}/${relative}`, `${JSON.stringify({
      schema: 1, repository: repositoryUrl, revision: selected(role).sourceCommit, tree: tree(role),
    })}\n`);
  }
  write(root, `${sourceRows[1][0]}/Packages/FearlessUtilsCompat/Package.swift`,
    `.package(url: "https://github.com/soramitsu/shared-features-spm.git", revision: "${selected('ios-shared-features').sourceCommit}")\n`);
  write(root, `${sourceRows[1][0]}/fearless.xcodeproj/project.pbxproj`,
    `repositoryURL = "https://github.com/soramitsu/shared-features-spm.git"; requirement = { kind = revision; revision = ${selected('ios-shared-features').sourceCommit}; };\n`);
  const resolved = `${JSON.stringify({ version: 3, pins: [
    { identity: 'shared-features-spm', kind: 'remoteSourceControl',
      location: 'https://github.com/soramitsu/shared-features-spm.git',
      state: { revision: selected('ios-shared-features').sourceCommit } },
    { identity: 'fearless-starscream', kind: 'remoteSourceControl',
      location: 'https://github.com/soramitsu/fearless-starscream',
      state: { revision: selected('ios-starscream').sourceCommit } },
  ] })}\n`;
  const files = Object.entries(filePaths).map(([kind, relative]) => {
    let bytes;
    if (kind === 'passkey-policy') bytes = '{"releaseEnabled":true}\n';
    else if (kind === 'android-approved-routes' || kind === 'android-required-routes') bytes = ROUTE_ROW;
    else if (kind === 'android-discovery-gaps') bytes = '# no remaining discovery-only routes\n';
    else if (kind === 'android-local-chains') bytes = LOCAL_CHAINS;
    else if (kind === 'android-route-manifest') bytes = `${JSON.stringify({
      schema: '1', files: {
        'approved_xcm_routes.tsv': digest(ROUTE_ROW),
        'local_chains.json': digest(LOCAL_CHAINS),
      },
    })}\n`;
    else if (kind === 'ios-workspace-packages' || kind === 'ios-project-packages') bytes = resolved;
    else bytes = `${kind}\n`;
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
      androidApprovedSha256: files.find((row) => row.kind === 'android-approved-routes').sha256,
      androidRequiredSha256: files.find((row) => row.kind === 'android-required-routes').sha256,
      androidDiscoveryGapsSha256: files.find((row) => row.kind === 'android-discovery-gaps').sha256,
      androidLocalChainsSha256: files.find((row) => row.kind === 'android-local-chains').sha256,
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
function repinAndroidSource(f) {
  f.manifest.repositories[0].sourceCommit = commit(path.join(f.root, sourceRows[0][0]));
  f.manifest.android.sourceCommit = f.manifest.repositories[0].sourceCommit;
  for (const row of f.manifest.artifacts.filter((item) =>
    !item.kind.startsWith('iroha-') && item.kind !== 'apple-delivered-ipa')) {
    row.sourceCommit = f.manifest.android.sourceCommit;
  }
}
function repinIosSource(f) {
  f.manifest.repositories[1].sourceCommit = commit(path.join(f.root, sourceRows[1][0]));
  f.manifest.ios.sourceCommit = f.manifest.repositories[1].sourceCommit;
  f.manifest.artifacts.find((row) => row.kind === 'apple-delivered-ipa').sourceCommit = f.manifest.ios.sourceCommit;
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
  } finally { rmSync(f.sandbox, { recursive: true, force: true, maxRetries: 10, retryDelay: 100 }); }
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
  } finally { rmSync(f.sandbox, { recursive: true, force: true, maxRetries: 10, retryDelay: 100 }); }
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
  } finally { rmSync(f.sandbox, { recursive: true, force: true, maxRetries: 10, retryDelay: 100 }); }
});

test('checkout symlink substitution is rejected even when its Git commit is identical', () => {
  const f = fixture();
  try {
    const original = path.join(f.root, dependencyPaths['android-websocket']);
    const moved = `${original}.moved`;
    renameSync(original, moved);
    symlinkSync(moved, original);
    assert.throws(() => auditReleaseShippingManifest(f.root), /checkout path is substituted/u);
  } finally { rmSync(f.sandbox, { recursive: true, force: true, maxRetries: 10, retryDelay: 100 }); }
});

for (const role of ['android-utils', 'android-websocket']) {
  test(`clean ${role} checkout cannot replace the Android runtime source pin`, () => {
    const f = fixture();
    try {
      const directory = path.join(f.root, dependencyPaths[role]);
      appendFileSync(path.join(directory, 'fixture.txt'), 'different clean source\n');
      f.manifest.dependencies.find((row) => row.role === role).sourceCommit = commit(directory);
      f.save();
      assert.throws(() => auditReleaseShippingManifest(f.root), new RegExp(`${role} runtime commit mismatch`, 'u'));
    } finally { rmSync(f.sandbox, { recursive: true, force: true, maxRetries: 10, retryDelay: 100 }); }
  });
}

test('clean Android source cannot replace the pinned Utils tree', () => {
  const f = fixture();
  try {
    const relative = `${sourceRows[0][0]}/config/android-runtime-source-pins.json`;
    const pins = JSON.parse(readFileSync(path.join(f.root, relative), 'utf8'));
    pins.utils.tree = HEX40;
    write(f.root, relative, `${JSON.stringify(pins)}\n`);
    repinAndroidSource(f);
    f.save();
    assert.throws(() => auditReleaseShippingManifest(f.root), /android-utils runtime tree mismatch/u);
  } finally { rmSync(f.sandbox, { recursive: true, force: true, maxRetries: 10, retryDelay: 100 }); }
});

test('clean dependency checkout with substituted origin is rejected', () => {
  const f = fixture();
  try {
    git(path.join(f.root, dependencyPaths['android-utils']), 'remote', 'set-url', 'origin',
      'https://github.com/attacker/fearless-utils-Android.git');
    assert.throws(() => auditReleaseShippingManifest(f.root), /android-utils configured origin repository mismatch/u);
  } finally { rmSync(f.sandbox, { recursive: true, force: true, maxRetries: 10, retryDelay: 100 }); }
});

for (const flag of ['--assume-unchanged', '--skip-worktree']) {
  test(`dependency ${flag} index flag cannot hide modified tracked source`, () => {
    const f = fixture();
    try {
      const directory = path.join(f.root, dependencyPaths['android-utils']);
      git(directory, 'update-index', flag, 'fixture.txt');
      appendFileSync(path.join(directory, 'fixture.txt'), 'hidden changed bytes\n');
      assert.equal(git(directory, 'status', '--porcelain=v1', '--untracked-files=all'), '');
      assert.throws(() => auditReleaseShippingManifest(f.root), /android-utils source index flags hide tracked files/u);
    } finally { rmSync(f.sandbox, { recursive: true, force: true, maxRetries: 10, retryDelay: 100 }); }
  });
}

test('multiple configured origin URLs cannot impersonate one dependency repository', () => {
  const f = fixture();
  try {
    const directory = path.join(f.root, dependencyPaths['android-websocket']);
    git(directory, 'config', '--add', 'remote.origin.url',
      'https://github.com/soramitsu/fearless-nv-websocket-client.git');
    assert.throws(() => auditReleaseShippingManifest(f.root), /android-websocket configured origin URL count mismatch/u);
  } finally { rmSync(f.sandbox, { recursive: true, force: true, maxRetries: 10, retryDelay: 100 }); }
});

test('effective origin URL rewrite cannot redirect a configured Fearless dependency', () => {
  const f = fixture();
  try {
    const directory = path.join(f.root, dependencyPaths['android-websocket']);
    git(directory, 'config', '--local', 'url.https://github.com/attacker/.insteadOf',
      'https://github.com/soramitsu/');
    assert.equal(git(directory, 'remote', 'get-url', '--all', 'origin'),
      'https://github.com/attacker/fearless-nv-websocket-client.git');
    assert.throws(() => auditReleaseShippingManifest(f.root), /android-websocket effective origin repository mismatch/u);
  } finally { rmSync(f.sandbox, { recursive: true, force: true, maxRetries: 10, retryDelay: 100 }); }
});

for (const role of ['ios-shared-features', 'ios-starscream']) {
  test(`clean ${role} checkout cannot replace the iOS source contract`, () => {
    const f = fixture();
    try {
      const directory = path.join(f.root, dependencyPaths[role]);
      appendFileSync(path.join(directory, 'fixture.txt'), 'different clean source\n');
      f.manifest.dependencies.find((row) => row.role === role).sourceCommit = commit(directory);
      f.save();
      assert.throws(() => auditReleaseShippingManifest(f.root), new RegExp(`${role} source revision mismatch`, 'u'));
    } finally { rmSync(f.sandbox, { recursive: true, force: true, maxRetries: 10, retryDelay: 100 }); }
  });
}

test('clean iOS source cannot replace the shared-features tree contract', () => {
  const f = fixture();
  try {
    const relative = `${sourceRows[1][0]}/config/shared-features-source.json`;
    const contract = JSON.parse(readFileSync(path.join(f.root, relative), 'utf8'));
    contract.tree = HEX40;
    write(f.root, relative, `${JSON.stringify(contract)}\n`);
    repinIosSource(f);
    f.save();
    assert.throws(() => auditReleaseShippingManifest(f.root), /ios-shared-features source tree mismatch/u);
  } finally { rmSync(f.sandbox, { recursive: true, force: true, maxRetries: 10, retryDelay: 100 }); }
});

for (const kind of ['ios-workspace-packages', 'ios-project-packages']) {
  test(`clean iOS ${kind} lock cannot disagree with the Starscream checkout`, () => {
    const f = fixture();
    try {
      const relative = filePaths[kind];
      const resolved = JSON.parse(readFileSync(path.join(f.root, relative), 'utf8'));
      resolved.pins.find((pin) => pin.identity === 'fearless-starscream').state.revision = HEX40;
      const bytes = `${JSON.stringify(resolved)}\n`;
      write(f.root, relative, bytes);
      repinIosSource(f);
      f.manifest.files.find((row) => row.kind === kind).sha256 = digest(bytes);
      f.save();
      assert.throws(() => auditReleaseShippingManifest(f.root), new RegExp(`${kind} fearless-starscream revision mismatch`, 'u'));
    } finally { rmSync(f.sandbox, { recursive: true, force: true, maxRetries: 10, retryDelay: 100 }); }
  });
}

test('one retained file cannot stand in for two independent evidence kinds', () => {
  const f = fixture();
  try {
    f.manifest.evidence[1].path = f.manifest.evidence[0].path;
    f.manifest.evidence[1].sha256 = f.manifest.evidence[0].sha256;
    f.save();
    assert.throws(() => auditReleaseShippingManifest(f.root), /artifact\/evidence path is reused/u);
  } finally { rmSync(f.sandbox, { recursive: true, force: true, maxRetries: 10, retryDelay: 100 }); }
});

test('remaining Android discovery-only routes block shipping even with re-pinned exact source', () => {
  const f = fixture();
  try {
    const bytes = `${'a'.repeat(64)} ${'c'.repeat(64)} USDT non-native-asset -\n`;
    write(f.root, filePaths['android-discovery-gaps'], bytes);
    repinAndroidSource(f);
    const digestRow = f.manifest.files.find((row) => row.kind === 'android-discovery-gaps');
    digestRow.sha256 = digest(bytes);
    f.manifest.routeInventories.androidDiscoveryGapsSha256 = digestRow.sha256;
    f.save();
    assert.throws(() => auditReleaseShippingManifest(f.root), /Android discovery-only routes remain/u);
  } finally { rmSync(f.sandbox, { recursive: true, force: true, maxRetries: 10, retryDelay: 100 }); }
});

test('required Android routes must equal compiled approved routes, even with matching hashes', () => {
  const f = fixture();
  try {
    const bytes = `${'a'.repeat(64)} ${'b'.repeat(64)} KSM\n`;
    write(f.root, filePaths['android-required-routes'], bytes);
    repinAndroidSource(f);
    const digestRow = f.manifest.files.find((row) => row.kind === 'android-required-routes');
    digestRow.sha256 = digest(bytes);
    f.manifest.routeInventories.androidRequiredSha256 = digestRow.sha256;
    f.save();
    assert.throws(() => auditReleaseShippingManifest(f.root), /Android required and approved routes differ/u);
  } finally { rmSync(f.sandbox, { recursive: true, force: true, maxRetries: 10, retryDelay: 100 }); }
});

test('compiled Android route manifest must bind approved routes and local chains', () => {
  const f = fixture();
  try {
    const bytes = `${JSON.stringify({
      schema: '1', files: {
        'approved_xcm_routes.tsv': HEX64,
        'local_chains.json': digest(LOCAL_CHAINS),
      },
    })}\n`;
    write(f.root, filePaths['android-route-manifest'], bytes);
    repinAndroidSource(f);
    const digestRow = f.manifest.files.find((row) => row.kind === 'android-route-manifest');
    digestRow.sha256 = digest(bytes);
    f.manifest.routeInventories.androidSha256 = digestRow.sha256;
    f.save();
    assert.throws(() => auditReleaseShippingManifest(f.root), /Android compiled approved-route digest mismatch/u);
  } finally { rmSync(f.sandbox, { recursive: true, force: true, maxRetries: 10, retryDelay: 100 }); }
});
