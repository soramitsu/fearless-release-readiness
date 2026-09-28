#!/usr/bin/env node

// The shipping manifest is a detached, ignored release artifact. Keeping it
// outside Git avoids a commit naming its own SHA; exact source heads are
// independently reviewed and the raw manifest digest is signed at acceptance.
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { constants, closeSync, fstatSync, lstatSync, openSync, readSync, realpathSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const MANIFEST = 'config/release-shipping-manifest.json';
const COMMIT = /^[a-f0-9]{40}$/u;
const DIGEST = /^[a-f0-9]{64}$/u;
const RELEASE_ID = /^[A-Za-z0-9][A-Za-z0-9._-]{7,63}$/u;
const DEPENDENCIES = new Map([
  ['android-utils', 'fearless-utils-Android-production-20260922'],
  ['android-websocket', 'fearless-nv-websocket-production-20260922'],
  ['ios-shared-features', 'shared-features-spm-production-20260922'],
  ['ios-starscream', 'fearless-starscream-production-20260922'],
]);
const DEPENDENCY_REPOSITORIES = new Map([
  ['android-utils', 'soramitsu/fearless-utils-Android'],
  ['android-websocket', 'soramitsu/fearless-nv-websocket-client'],
  ['ios-shared-features', 'soramitsu/shared-features-spm'],
  ['ios-starscream', 'soramitsu/fearless-starscream'],
]);
const IOS_SOURCE_CONTRACTS = new Map([
  ['ios-shared-features', ['config/shared-features-source.json', 'https://github.com/soramitsu/shared-features-spm.git']],
  ['ios-starscream', ['config/starscream-source.json', 'https://github.com/soramitsu/fearless-starscream']],
]);
const FILES = new Map([
  ['passkey-policy', 'config/passkey-backup-production.json'],
  ['android-route-manifest', 'fearless-Android-production-consolidated-20260731/common/src/main/assets/mutation_route_manifest.json'],
  ['android-approved-routes', 'fearless-Android-production-consolidated-20260731/runtime/src/main/assets/approved_xcm_routes.tsv'],
  ['android-required-routes', 'fearless-Android-production-consolidated-20260731/scripts/xcm-required-routes.tsv'],
  ['android-discovery-gaps', 'fearless-Android-production-consolidated-20260731/scripts/xcm-discovery-only-routes.tsv'],
  ['android-local-chains', 'fearless-Android-production-consolidated-20260731/runtime/src/main/assets/local_chains.json'],
  ['android-mutation-policy', 'fearless-Android-production-consolidated-20260731/common/src/main/assets/mutation_authorization_policy.json'],
  ['android-mutation-trust', 'fearless-Android-production-consolidated-20260731/common/src/main/assets/mutation_authorization_trust.json'],
  ['android-dependency-verification', 'fearless-Android-production-consolidated-20260731/gradle/verification-metadata.xml'],
  ['android-settings-lock', 'fearless-Android-production-consolidated-20260731/settings-gradle.lockfile'],
  ['android-buildscript-lock', 'fearless-Android-production-consolidated-20260731/buildscript-gradle.lockfile'],
  ['android-app-lock', 'fearless-Android-production-consolidated-20260731/app/gradle.lockfile'],
  ['ios-pods-lock', 'fearless-iOS-production-consolidated-20260731/Podfile.lock'],
  ['ios-workspace-packages', 'fearless-iOS-production-consolidated-20260731/fearless.xcworkspace/xcshareddata/swiftpm/Package.resolved'],
  ['ios-project-packages', 'fearless-iOS-production-consolidated-20260731/fearless.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved'],
  ['ios-dependency-packages', 'fearless-iOS-production-consolidated-20260731/Packages/FearlessDependencies/Package.resolved'],
]);
const ARTIFACTS = new Set([
  'android-aab', 'play-distributed-apk', 'apple-delivered-ipa',
  'iroha-android-sdk', 'iroha-ios-sdk',
]);
const EVIDENCE = new Set([
  'ios-to-replacement-android', 'android-to-replacement-ios',
  'drive-appdata-interoperability', 'sanitized-network-traffic',
  'play-signed-upgrade', 'apple-delivered-upgrade',
  'independent-security-review', 'funded-transfers',
  'migration-and-restart', 'production-services',
  'ios-compiled-route-inventory', 'ios-compiled-feature-policy',
]);
const SIBLING_SOURCES = new Set(['../ton-indexer', '../solswap-indexer', '../polkaswap-indexer', '../iroha']);
const ROUTE = /^[a-f0-9]{64} [a-f0-9]{64} [A-Z][A-Z0-9_-]*$/u;

function keys(value, expected, label) {
  assert.ok(value && typeof value === 'object' && !Array.isArray(value), `${label} must be an object`);
  assert.deepEqual(Object.keys(value).sort(), [...expected].sort(), `${label} fields mismatch`);
}
function nonempty(value, label) {
  assert.ok(typeof value === 'string' && value.length > 0 && value.length <= 512, `${label} invalid`);
}
function matches(value, expression, label) {
  assert.ok(typeof value === 'string' && expression.test(value), `${label} invalid`);
}
function canonical(value) {
  if (Array.isArray(value)) return value.map(canonical);
  if (value && typeof value === 'object') {
    return Object.fromEntries(Object.keys(value).sort().map((key) => [key, canonical(value[key])]));
  }
  return value;
}
function canonicalBytes(value) {
  return Buffer.from(`${JSON.stringify(canonical(value), null, 2)}\n`, 'utf8');
}
function safeRelative(value, label) {
  nonempty(value, label);
  assert.ok(!path.isAbsolute(value) && !value.includes('\\') && !value.includes('\0') &&
    value === path.posix.normalize(value) &&
    value.split('/').every((part) => part && part !== '.' && part !== '..'), `${label} path invalid`);
  return value;
}
function regularFile(root, relative, label) {
  safeRelative(relative, label);
  let current = root;
  const parts = relative.split('/');
  for (let i = 0; i < parts.length; i += 1) {
    current = path.join(current, parts[i]);
    const info = lstatSync(current);
    assert.ok(!info.isSymbolicLink() && (i === parts.length - 1 ? info.isFile() : info.isDirectory()),
      `${label} must be a regular nonsymlink file`);
  }
  return current;
}
function checkoutDirectory(root, relative, label) {
  const sibling = SIBLING_SOURCES.has(relative);
  const suffix = sibling ? relative.slice(3) : relative;
  safeRelative(suffix, label);
  let current = sibling ? path.dirname(realpathSync(root)) : realpathSync(root);
  for (const part of suffix.split('/')) {
    current = path.join(current, part);
    const info = lstatSync(current);
    assert.ok(info.isDirectory() && !info.isSymbolicLink(), `${label} checkout path is substituted`);
  }
  return current;
}
function readFile(file, limit = 1024 * 1024) {
  const fd = openSync(file, constants.O_RDONLY | constants.O_NOFOLLOW);
  const chunks = [];
  const buffer = Buffer.alloc(64 * 1024);
  let total = 0;
  try {
    assert.ok(fstatSync(fd).isFile(), 'input is not a regular file');
    for (;;) {
      const count = readSync(fd, buffer, 0, buffer.length, null);
      if (!count) break;
      total += count;
      assert.ok(total <= limit, 'input exceeds size limit');
      chunks.push(Buffer.from(buffer.subarray(0, count)));
    }
  } finally { closeSync(fd); }
  return Buffer.concat(chunks);
}
function sha256(file) {
  const fd = openSync(file, constants.O_RDONLY | constants.O_NOFOLLOW);
  const digest = createHash('sha256');
  const buffer = Buffer.alloc(64 * 1024);
  try {
    assert.ok(fstatSync(fd).isFile(), 'hashed input is not a regular file');
    for (;;) {
      const count = readSync(fd, buffer, 0, buffer.length, null);
      if (!count) break;
      digest.update(buffer.subarray(0, count));
    }
  } finally { closeSync(fd); }
  return digest.digest('hex');
}
function routeRows(bytes, label) {
  const rows = bytes.toString('utf8').split('\n')
    .map((line) => line.trim()).filter((line) => line && !line.startsWith('#'));
  assert.ok(rows.length > 0, `${label} must contain routes`);
  assert.ok(rows.every((line) => ROUTE.test(line)), `${label} has an invalid route`);
  assert.equal(new Set(rows).size, rows.length, `${label} has duplicate routes`);
  return rows.sort();
}
function validateAndroidRoutes(root, files) {
  const file = (kind) => regularFile(root, files.find((row) => row.kind === kind).path, kind);
  const approved = routeRows(readFile(file('android-approved-routes')), 'Android approved routes');
  const required = routeRows(readFile(file('android-required-routes')), 'Android required routes');
  assert.deepEqual(required, approved, 'Android required and approved routes differ');
  const gaps = readFile(file('android-discovery-gaps')).toString('utf8')
    .split('\n').map((line) => line.trim()).filter((line) => line && !line.startsWith('#'));
  assert.equal(gaps.length, 0, 'Android discovery-only routes remain');
  const routeManifest = JSON.parse(readFile(file('android-route-manifest')).toString('utf8'));
  keys(routeManifest, ['schema', 'files'], 'Android route manifest');
  assert.equal(routeManifest.schema, '1', 'Android route manifest schema mismatch');
  keys(routeManifest.files, ['approved_xcm_routes.tsv', 'local_chains.json'], 'Android route manifest files');
  assert.equal(routeManifest.files['approved_xcm_routes.tsv'],
    files.find((row) => row.kind === 'android-approved-routes').sha256,
    'Android compiled approved-route digest mismatch');
  assert.equal(routeManifest.files['local_chains.json'],
    files.find((row) => row.kind === 'android-local-chains').sha256,
    'Android compiled local-chain digest mismatch');
}
function git(directory, ...args) {
  const env = {
    ...Object.fromEntries(Object.entries(process.env).filter(([key]) => !key.startsWith('GIT_'))),
    GIT_NO_REPLACE_OBJECTS: '1',
  };
  const result = spawnSync('/usr/bin/git', ['-C', directory, ...args], {
    env, encoding: 'utf8', timeout: 20_000, maxBuffer: 1024 * 1024,
  });
  assert.equal(result.status, 0, `Git ${args[0]} failed for ${directory}`);
  return result.stdout.trim();
}
function gitIdentity(directory, branch, commit, label) {
  assert.equal(realpathSync(git(directory, 'rev-parse', '--show-toplevel')),
    realpathSync(directory), `${label} checkout substituted`);
  assert.equal(git(directory, 'symbolic-ref', '--quiet', '--short', 'HEAD'), branch, `${label} branch mismatch`);
  assert.equal(git(directory, 'rev-parse', 'HEAD'), commit, `${label} source commit mismatch`);
  assert.equal(git(directory, 'status', '--porcelain=v1', '--untracked-files=all'), '', `${label} source is dirty`);
  const entries = git(directory, 'ls-files', '-v', '-z').split('\0').filter(Boolean);
  assert.ok(entries.length > 0, `${label} tracked source is empty`);
  assert.ok(entries.every((entry) => entry.startsWith('H ')),
    `${label} source index flags hide tracked files`);
}
function dependency(manifest, role) {
  return manifest.dependencies.find((row) => row.role === role);
}
function dependencyDirectory(root, manifest, role) {
  return checkoutDirectory(root, dependency(manifest, role).path, role);
}
function dependencyRepository(directory, role) {
  const repository = DEPENDENCY_REPOSITORIES.get(role);
  const configured = git(directory, 'config', '--null', '--get-all', 'remote.origin.url')
    .split('\0').filter(Boolean);
  assert.equal(configured.length, 1, `${role} configured origin URL count mismatch`);
  const effective = git(directory, 'remote', 'get-url', '--all', 'origin').split('\n');
  assert.equal(effective.length, 1, `${role} effective origin URL count mismatch`);
  const expected = [
    `https://github.com/${repository}`, `https://github.com/${repository}.git`,
    `git@github.com:${repository}`, `git@github.com:${repository}.git`,
    `ssh://git@github.com/${repository}`, `ssh://git@github.com/${repository}.git`,
  ];
  assert.ok(expected.includes(configured[0]), `${role} configured origin repository mismatch`);
  assert.ok(expected.includes(effective[0]), `${role} effective origin repository mismatch`);
}
function pinnedJson(root, relative, label) {
  return JSON.parse(readFile(regularFile(root, relative, label)).toString('utf8'));
}
function validateAndroidDependencyPins(root, manifest) {
  const pins = pinnedJson(root,
    'fearless-Android-production-consolidated-20260731/config/android-runtime-source-pins.json',
    'Android runtime source pins');
  keys(pins, ['schemaVersion', 'utils', 'websocket'], 'Android runtime source pins');
  assert.equal(pins.schemaVersion, 1, 'Android runtime source pin schema mismatch');
  for (const [role, name] of [['android-utils', 'utils'], ['android-websocket', 'websocket']]) {
    const pin = pins[name];
    keys(pin, ['repository', 'commit', 'tree'], `${role} runtime pin`);
    assert.equal(pin.repository, DEPENDENCY_REPOSITORIES.get(role), `${role} runtime repository mismatch`);
    matches(pin.commit, COMMIT, `${role} runtime commit`);
    matches(pin.tree, COMMIT, `${role} runtime tree`);
    assert.equal(dependency(manifest, role).sourceCommit, pin.commit, `${role} runtime commit mismatch`);
    assert.equal(git(dependencyDirectory(root, manifest, role), 'rev-parse', 'HEAD^{tree}'),
      pin.tree, `${role} runtime tree mismatch`);
  }
}
function sourceContract(root, manifest, role) {
  const [relative, repository] = IOS_SOURCE_CONTRACTS.get(role);
  const contract = pinnedJson(root, `fearless-iOS-production-consolidated-20260731/${relative}`, `${role} source contract`);
  assert.equal(contract.schema, 1, `${role} source contract schema mismatch`);
  assert.equal(contract.repository, repository, `${role} source repository mismatch`);
  matches(contract.revision, COMMIT, `${role} source revision`);
  matches(contract.tree, COMMIT, `${role} source tree`);
  assert.equal(contract.revision, dependency(manifest, role).sourceCommit, `${role} source revision mismatch`);
  assert.equal(contract.tree, git(dependencyDirectory(root, manifest, role), 'rev-parse', 'HEAD^{tree}'),
    `${role} source tree mismatch`);
  return contract;
}
function swiftPackageRevision(root, relative, expression, label, expected) {
  const source = readFile(regularFile(root, relative, label), 4 * 1024 * 1024).toString('utf8');
  const revisions = [...source.matchAll(expression)].map((match) => match[1]);
  assert.deepEqual(revisions, [expected], `${label} revision mismatch`);
}
function validateIosDependencyPins(root, manifest) {
  const shared = sourceContract(root, manifest, 'ios-shared-features');
  const starscream = sourceContract(root, manifest, 'ios-starscream');
  for (const kind of ['ios-workspace-packages', 'ios-project-packages']) {
    const resolved = pinnedJson(root, FILES.get(kind), kind);
    assert.ok(Array.isArray(resolved.pins), `${kind} pins missing`);
    for (const [role, identity, contract] of [
      ['ios-shared-features', 'shared-features-spm', shared],
      ['ios-starscream', 'fearless-starscream', starscream],
    ]) {
      const matches = resolved.pins.filter((pin) => pin.identity === identity);
      assert.equal(matches.length, 1, `${kind} ${identity} pin coverage mismatch`);
      const pin = matches[0];
      keys(pin, ['identity', 'kind', 'location', 'state'], `${kind} ${identity} pin`);
      keys(pin.state, ['revision'], `${kind} ${identity} state`);
      assert.equal(pin.kind, 'remoteSourceControl', `${kind} ${identity} source kind mismatch`);
      assert.equal(pin.location, contract.repository, `${kind} ${identity} repository mismatch`);
      assert.equal(pin.state.revision, dependency(manifest, role).sourceCommit,
        `${kind} ${identity} revision mismatch`);
    }
  }
  swiftPackageRevision(root, 'fearless-iOS-production-consolidated-20260731/Packages/FearlessUtilsCompat/Package.swift',
    /\.package\(url:\s*"https:\/\/github\.com\/soramitsu\/shared-features-spm\.git",\s*revision:\s*"([a-f0-9]{40})"\)/gu,
    'FearlessUtilsCompat shared-features source', shared.revision);
  swiftPackageRevision(root, 'fearless-iOS-production-consolidated-20260731/fearless.xcodeproj/project.pbxproj',
    /repositoryURL = "https:\/\/github\.com\/soramitsu\/shared-features-spm\.git";\s*requirement = \{\s*kind = revision;\s*revision = ([a-f0-9]{40});\s*\};/gu,
    'iOS project shared-features source', shared.revision);
  swiftPackageRevision(dependencyDirectory(root, manifest, 'ios-shared-features'), 'Package.swift',
    /\.package\(url:\s*"https:\/\/github\.com\/soramitsu\/fearless-starscream",\s*\.revision\("([a-f0-9]{40})"\)\)/gu,
    'shared-features Starscream source', starscream.revision);
}
function rows(list, names, label, sourceBound = false) {
  assert.ok(Array.isArray(list) && list.length === names.size, `${label} coverage mismatch`);
  const found = new Set();
  for (const row of list) {
    keys(row, sourceBound ? ['kind', 'path', 'sha256', 'sourceCommit'] : ['kind', 'path', 'sha256'], `${label} row`);
    assert.ok(names.has(row.kind) && !found.has(row.kind), `${label} kind missing or duplicated`);
    matches(row.sha256, DIGEST, `${label} digest`);
    if (sourceBound) matches(row.sourceCommit, COMMIT, `${label} source commit`);
    safeRelative(row.path, `${label} path`);
    found.add(row.kind);
  }
}

export function validateShippingManifestShape(manifest, sourceRows) {
  keys(manifest, [
    'schemaVersion', 'releaseId', 'root', 'repositories', 'dependencies',
    'files', 'artifacts', 'evidence', 'distribution', 'android', 'ios',
    'routeInventories', 'featurePolicies',
    'googleApplicationId', 'passkeyConfigSha256',
  ], 'shipping manifest');
  assert.equal(manifest.schemaVersion, 1, 'shipping manifest schema mismatch');
  matches(manifest.releaseId, RELEASE_ID, 'release ID');
  keys(manifest.root, ['repository', 'head', 'sourceCommit'], 'root');
  assert.equal(manifest.root.repository, 'soramitsu/fearless-release-readiness', 'root repository mismatch');
  matches(manifest.root.sourceCommit, COMMIT, 'root commit');
  nonempty(manifest.root.head, 'root branch');
  assert.ok(Array.isArray(manifest.repositories) && manifest.repositories.length === sourceRows.length,
    'source repository coverage mismatch');
  const sourcePaths = new Set();
  for (let i = 0; i < sourceRows.length; i += 1) {
    const row = manifest.repositories[i];
    keys(row, ['path', 'repository', 'head', 'sourceCommit'], 'source repository');
    assert.deepEqual([row.path, row.repository, row.head], sourceRows[i], 'source selection substituted');
    assert.ok(!sourcePaths.has(row.path), 'duplicate source repository');
    matches(row.sourceCommit, COMMIT, 'source commit');
    sourcePaths.add(row.path);
  }
  assert.ok(Array.isArray(manifest.dependencies) && manifest.dependencies.length === DEPENDENCIES.size,
    'dependency coverage mismatch');
  const dependencyRoles = new Set();
  for (const row of manifest.dependencies) {
    keys(row, ['role', 'path', 'sourceCommit'], 'dependency');
    assert.equal(row.path, DEPENDENCIES.get(row.role), 'dependency path substituted');
    assert.ok(!dependencyRoles.has(row.role), 'duplicate dependency');
    matches(row.sourceCommit, COMMIT, 'dependency commit');
    dependencyRoles.add(row.role);
  }
  rows(manifest.files, FILES, 'release file');
  for (const row of manifest.files) assert.equal(row.path, FILES.get(row.kind), 'release file substituted');
  rows(manifest.artifacts, ARTIFACTS, 'artifact', true);
  rows(manifest.evidence, EVIDENCE, 'evidence');
  const retainedPaths = new Set();
  for (const row of [...manifest.artifacts, ...manifest.evidence]) {
    assert.ok(row.path.startsWith('build/reports/'), 'artifact/evidence must stay under build/reports');
    assert.ok(!retainedPaths.has(row.path), 'artifact/evidence path is reused');
    retainedPaths.add(row.path);
  }
  keys(manifest.routeInventories, [
    'androidSha256', 'androidApprovedSha256', 'androidRequiredSha256',
    'androidDiscoveryGapsSha256', 'androidLocalChainsSha256', 'iosSha256',
  ], 'route inventories');
  matches(manifest.routeInventories.androidSha256, DIGEST, 'Android route digest');
  matches(manifest.routeInventories.iosSha256, DIGEST, 'iOS route digest');
  assert.equal(manifest.routeInventories.androidSha256,
    manifest.files.find((row) => row.kind === 'android-route-manifest').sha256,
    'Android route inventory binding mismatch');
  for (const [field, kind] of [
    ['androidApprovedSha256', 'android-approved-routes'],
    ['androidRequiredSha256', 'android-required-routes'],
    ['androidDiscoveryGapsSha256', 'android-discovery-gaps'],
    ['androidLocalChainsSha256', 'android-local-chains'],
  ]) {
    matches(manifest.routeInventories[field], DIGEST, `${field} digest`);
    assert.equal(manifest.routeInventories[field], manifest.files.find((row) => row.kind === kind).sha256,
      `${field} binding mismatch`);
  }
  assert.equal(manifest.routeInventories.iosSha256,
    manifest.evidence.find((row) => row.kind === 'ios-compiled-route-inventory').sha256,
    'iOS route inventory binding mismatch');
  keys(manifest.featurePolicies, ['rootPasskeySha256', 'androidMutationSha256', 'iosMutationSha256'], 'feature policies');
  for (const [name, value] of Object.entries(manifest.featurePolicies)) matches(value, DIGEST, name);
  assert.equal(manifest.featurePolicies.rootPasskeySha256, manifest.passkeyConfigSha256,
    'root passkey policy binding mismatch');
  assert.equal(manifest.featurePolicies.androidMutationSha256,
    manifest.files.find((row) => row.kind === 'android-mutation-policy').sha256,
    'Android mutation policy binding mismatch');
  assert.equal(manifest.featurePolicies.iosMutationSha256,
    manifest.evidence.find((row) => row.kind === 'ios-compiled-feature-policy').sha256,
    'iOS mutation policy binding mismatch');
  keys(manifest.distribution, ['androidPackage', 'playSigningCertificateSha256', 'iosBundleId', 'appleTeamId'], 'distribution');
  assert.equal(manifest.distribution.androidPackage, 'jp.co.soramitsu.fearless', 'Android package mismatch');
  assert.equal(manifest.distribution.iosBundleId, 'jp.co.soramitsu.fearlesswallet', 'iOS bundle mismatch');
  matches(manifest.distribution.playSigningCertificateSha256, DIGEST, 'Play signer digest');
  matches(manifest.distribution.appleTeamId, /^[A-Z0-9]{10}$/u, 'Apple team ID');
  for (const platform of ['android', 'ios']) {
    keys(manifest[platform], ['sourceCommit', 'artifactSha256', 'compiledPasskeyRecoveryEnabled'], platform);
    matches(manifest[platform].sourceCommit, COMMIT, `${platform} source commit`);
    matches(manifest[platform].artifactSha256, DIGEST, `${platform} artifact digest`);
    assert.equal(manifest[platform].compiledPasskeyRecoveryEnabled, true, `${platform} recovery approval is not compiled`);
  }
  nonempty(manifest.googleApplicationId, 'Google application ID');
  matches(manifest.passkeyConfigSha256, DIGEST, 'passkey configuration digest');
  assert.equal(manifest.files.find((row) => row.kind === 'passkey-policy').sha256,
    manifest.passkeyConfigSha256, 'passkey configuration binding mismatch');
  assert.equal(manifest.android.sourceCommit, manifest.repositories[0].sourceCommit, 'Android source binding mismatch');
  assert.equal(manifest.ios.sourceCommit, manifest.repositories[1].sourceCommit, 'iOS source binding mismatch');
  assert.equal(manifest.android.artifactSha256,
    manifest.artifacts.find((row) => row.kind === 'play-distributed-apk').sha256,
    'Play artifact binding mismatch');
  assert.equal(manifest.ios.artifactSha256,
    manifest.artifacts.find((row) => row.kind === 'apple-delivered-ipa').sha256,
    'Apple artifact binding mismatch');
  for (const row of manifest.artifacts) {
    const expectedCommit = row.kind.startsWith('iroha-') ? manifest.repositories[7].sourceCommit
      : row.kind === 'apple-delivered-ipa' ? manifest.ios.sourceCommit : manifest.android.sourceCommit;
    assert.equal(row.sourceCommit, expectedCommit, `${row.kind} source binding mismatch`);
  }
}

export function auditReleaseShippingManifest(root = ROOT) {
  const manifestFile = regularFile(root, MANIFEST, 'shipping manifest');
  const manifestBytes = readFile(manifestFile);
  const manifest = JSON.parse(manifestBytes.toString('utf8'));
  assert.ok(manifestBytes.equals(canonicalBytes(manifest)), 'shipping manifest must use unique canonical JSON');
  const sourceText = readFile(regularFile(root, 'config/source-publication-readiness.tsv', 'source inventory')).toString('utf8');
  const sourceRows = sourceText.split(/\r?\n/u).filter((line) => line && !line.startsWith('#'))
    .map((line) => line.split('\t'));
  assert.ok(sourceRows.length === 8 && sourceRows.every((row) => row.length === 5), 'source inventory changed');
  assert.deepEqual(sourceRows[7].slice(0, 3), ['../iroha', 'hyperledger-iroha/iroha', 'optimizations'],
    'Iroha source must be the optimizations branch');
  const rootOwner = JSON.parse(readFile(regularFile(root, 'config/source-publication-root-owner.json', 'root owner')).toString('utf8'));
  validateShippingManifestShape(manifest, sourceRows.map((row) => row.slice(0, 3)));
  assert.equal(manifest.root.head, rootOwner.head, 'root branch selection mismatch');
  assert.equal(manifest.root.repository, rootOwner.repository, 'root owner mismatch');
  gitIdentity(root, manifest.root.head, manifest.root.sourceCommit, 'root');
  for (const row of manifest.repositories) {
    assert.ok(SIBLING_SOURCES.has(row.path) || (!row.path.startsWith('../') && !path.isAbsolute(row.path)),
      'source checkout escapes selection');
    const directory = checkoutDirectory(root, row.path, row.repository);
    gitIdentity(directory, row.head, row.sourceCommit, row.repository);
  }
  for (const row of manifest.dependencies) {
    const directory = checkoutDirectory(root, row.path, row.role);
    gitIdentity(directory, git(directory, 'symbolic-ref', '--quiet', '--short', 'HEAD'), row.sourceCommit, row.role);
    dependencyRepository(directory, row.role);
  }
  for (const row of [...manifest.files, ...manifest.artifacts, ...manifest.evidence]) {
    assert.equal(sha256(regularFile(root, row.path, row.kind)), row.sha256, `${row.kind} digest mismatch`);
  }
  validateAndroidDependencyPins(root, manifest);
  validateIosDependencyPins(root, manifest);
  validateAndroidRoutes(root, manifest.files);
  return { releaseId: manifest.releaseId, manifestSha256: createHash('sha256').update(manifestBytes).digest('hex') };
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try {
    assert.equal(process.argv.length, 2, 'production manifest audit takes no arguments');
    const result = auditReleaseShippingManifest();
    process.stdout.write(`[release-shipping-manifest] PASS ${result.releaseId} ${result.manifestSha256}\n`);
  } catch (error) {
    process.stderr.write(`[release-shipping-manifest][error] ${error.message}\n`);
    process.exitCode = 1;
  }
}
