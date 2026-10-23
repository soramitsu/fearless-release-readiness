#!/usr/bin/env node
import assert from 'node:assert/strict';
import test from 'node:test';
import { parseLockfile, queryOsv } from './scan-locked-dependencies.mjs';

test('Yarn scans actual resolved versions and exposes vendored coverage gaps', () => {
  const result = parseLockfile('yarn.lock', '__metadata:\n  version: 8\n"@scope/a@npm:^1":\n  resolution: "@scope/a@npm:1.2.3"\n"b@file:vendor/b":\n  resolution: "b@file:vendor/b#hash"\n');
  assert.deepEqual(result.queries, [{ package: { ecosystem: 'npm', name: '@scope/a' }, version: '1.2.3' }]);
  assert.equal(result.gaps.length, 1);
  assert.throws(() => parseLockfile('yarn.lock', '__metadata:\n  version: 8\n  resolution: "safe@npm:1.0.0"\n  resolution: unparsed@npm:2.0.0\n'));
});
test('npm nested packages/aliases use the real name and local code remains visible', () => {
  const result = parseLockfile('package-lock.json', JSON.stringify({ lockfileVersion: 3, packages: {
    '': { name: 'app' }, 'node_modules/a/node_modules/alias': { name: '@scope/real', version: '2.3.4', resolved: 'https://registry.npmjs.org/a/-/a.tgz', integrity: 'sha512-x' },
    'node_modules/local': { link: true, resolved: '../local' },
  } }));
  assert.equal(result.queries[0].package.name, '@scope/real');
  assert.equal(result.gaps[0].kind, 'non-registry-resolution');
});
test('Gradle rejects dynamic versions and malformed entries', () => {
  assert.equal(parseLockfile('gradle.lockfile', '# lock\ng:a:1.2.3=releaseRuntimeClasspath\nempty=\n').queries[0].package.name, 'g:a');
  assert.throws(() => parseLockfile('gradle.lockfile', 'g:a:1.+=runtime'));
  assert.throws(() => parseLockfile('gradle.lockfile', 'oops'));
});
test('Swift queries the locked revision as well as upstream version', () => {
  const result = parseLockfile('Package.resolved', JSON.stringify({ pins: [{ location: 'https://github.com/apple/swift-nio.git', state: { version: '2.100.0', revision: 'a'.repeat(40) } }] }));
  assert.equal(result.queries[0].package.ecosystem, 'SwiftURL');
  assert.equal(result.queries[0].package.name, 'https://github.com/apple/swift-nio');
  assert.equal(result.queries[1].commit.length, 40);
});
test('CocoaPods subspecs and mutable Git tags are accounted for', () => {
  const result = parseLockfile('Podfile.lock', 'PODS:\n  - One/Core (1.2.0)\n  - Two (2.0.0)\nDEPENDENCIES:\n  - One\nCHECKOUT OPTIONS:\n  One:\n    :git: https://example.org/one.git\n    :tag: 1.2.0\n  Two:\n    :commit: ' + 'b'.repeat(40) + '\nSPEC CHECKSUMS:\n  One: 123\n');
  assert.equal(result.queries.length, 1);
  assert.equal(result.gaps[0].kind, 'unsupported-cocoapods-ecosystem');
  assert.equal(result.gaps[2].kind, 'mutable-pod-checkout');
});
test('Cargo registry and pinned Git inputs are queried; local crates are excluded', () => {
  const result = parseLockfile('Cargo.lock', 'version = 3\n[[package]]\nname = "local"\nversion = "1.0.0"\n[[package]]\nname = "serde"\nversion = "1.0.1"\nsource = "registry+https://github.com/rust-lang/crates.io-index"\n[[package]]\nname = "fork"\nversion = "1.0.0"\nsource = "git+https://example.org/fork#' + 'c'.repeat(40) + '"\n');
  assert.equal(result.queries.length, 2);
});
test('empty, unsupported and partial inputs cannot report a clean inventory', () => {
  for (const file of ['yarn.lock', 'Package.resolved', 'Podfile.lock', 'Cargo.lock', 'unknown']) assert.throws(() => parseLockfile(file, '{}'));
  assert.throws(() => parseLockfile('package-lock.json', '{"lockfileVersion":1}'));
});
test('Bundler platform gems and pinned Git sources retain the correct advisory identity', () => {
  const result = parseLockfile('Gemfile.lock', 'GEM\n  remote: https://rubygems.org/\n  specs:\n    ffi (1.17.4-arm64-darwin)\n    rack (3.2.4)\n      dependency (~> 1)\n\nGIT\n  remote: https://example.org/fork\n  revision: ' + 'd'.repeat(40) + '\n  specs:\n    fork (1.0.0)\n\nPATH\n  remote: vendor/local\n\nPLATFORMS\n  ruby\n  arm64-darwin\n\nDEPENDENCIES\n  rack\n');
  assert.deepEqual(result.queries[0], { package: { ecosystem: 'RubyGems', name: 'ffi' }, version: '1.17.4' });
  assert.equal(result.queries.length, 3);
  assert.equal(result.gaps.length, 1);
  assert.throws(() => parseLockfile('Gemfile.lock', 'GIT\n  remote: https://example.org/unpinned\n'));
});
test('Bundler tooling is queried at BUNDLED WITH rather than its dependency requirement', () => {
  const gems = 'GEM\n  remote: https://rubygems.org/\n  specs:\n    rack (3.2.4)\n\nDEPENDENCIES\n  bundler (>= 1.0)\n  rack\n\n';
  for (const version of ['1.17.2', '2.5.23', '2.6.0.rc.1']) {
    const result = parseLockfile('Gemfile.lock', `${gems}BUNDLED WITH\n   ${version}\n`);
    assert.deepEqual(result.queries, [
      { package: { ecosystem: 'RubyGems', name: 'rack' }, version: '3.2.4' },
      { package: { ecosystem: 'RubyGems', name: 'bundler' }, version },
    ]);
    assert.deepEqual(result.gaps, []);
  }
});
test('malformed or ambiguous BUNDLED WITH sections cannot silently omit Bundler', () => {
  const gems = 'GEM\n  remote: https://rubygems.org/\n  specs:\n    rack (3.2.4)\n\n';
  for (const version of ['', '   ', '~> 2.5', '>=2.5.23', '2.5.*', 'latest', '2.5.23 extra', '2.5.23\n   1.17.2']) {
    assert.throws(() => parseLockfile('Gemfile.lock', `${gems}BUNDLED WITH\n   ${version}\n`), /Invalid locked Bundler version/);
  }
  assert.throws(() => parseLockfile('Gemfile.lock', `${gems}BUNDLED WITH`), /Invalid locked Bundler version/);
  assert.throws(() => parseLockfile('Gemfile.lock', `${gems}BUNDLED WITH\n   2.5.23\n\nBUNDLED WITH\n   1.17.2\n`), /Invalid locked Bundler version/);
});
test('OSV paging preserves package attribution, deduplicates and removes withdrawn records', async () => {
  let batches = 0;
  const result = await queryOsv([{ commit: 'a'.repeat(40) }, { commit: 'b'.repeat(40) }], async (path, body) => {
    if (path === '/querybatch') {
      if (++batches === 1) return { results: [{ vulns: [{ id: 'GHSA-one' }], next_page_token: 'next' }, { vulns: [{ id: 'GHSA-withdrawn' }] }] };
      assert.equal(body.queries.length, 1);
      assert.equal(body.queries[0].commit, 'a'.repeat(40));
      assert.equal(body.queries[0].page_token, 'next');
      return { results: [{ vulns: [{ id: 'GHSA-one' }, { id: 'MAL-two' }] }] };
    }
    const id = path.split('/').at(-1);
    return { id, withdrawn: id === 'GHSA-withdrawn' ? '2026-01-01T00:00:00Z' : undefined };
  });
  assert.equal(result[0].length, 2);
  assert.equal(result[0][1].malicious, true);
  assert.equal(result[1].length, 0);
});
test('truncated, malformed and failed advisory service responses fail closed', async () => {
  for (const response of [{}, { results: [] }, { results: [null] }, { results: [{ error: 'failed' }] }, { results: [{ vulns: {} }] }, { results: [{ next_page_token: 0 }] }]) {
    await assert.rejects(queryOsv([{ commit: 'a'.repeat(40) }], async () => response));
  }
  await assert.rejects(queryOsv([{}], async () => { throw new Error('network'); }));
  await assert.rejects(queryOsv([{}], async (path) => path === '/querybatch' ? { results: [{ vulns: [{ id: 'GHSA-one' }] }] } : { id: 'GHSA-other' }));
});
test('repeated pagination tokens fail instead of looping or silently truncating', async () => {
  await assert.rejects(queryOsv([{}], async () => ({ results: [{ next_page_token: 'loop' }] })));
});
test('malformed withdrawal metadata cannot silently hide an advisory', async () => {
  for (const withdrawn of [true, {}, [], '', '2026-01-01', '2026-99-99T00:00:00Z']) {
    await assert.rejects(queryOsv([{}], async path => path === '/querybatch'
      ? { results: [{ vulns: [{ id: 'GHSA-one' }] }] }
      : { id: 'GHSA-one', withdrawn }));
  }
});
