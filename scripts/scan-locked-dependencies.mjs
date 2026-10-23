#!/usr/bin/env node
// Read-only advisory inventory. Never installs or executes dependency code.
import { readFileSync, writeFileSync, mkdirSync } from 'node:fs';
import { basename, dirname, resolve } from 'node:path';
import { pathToFileURL } from 'node:url';
import { createHash } from 'node:crypto';

export function parseLockfile(file, text) {
  const queries = [], gaps = [];
  const add = (ecosystem, name, version) => {
    if (!name || !version || /[\s<>=~^*]/.test(version) || version.endsWith('+') || version.startsWith('latest.')) throw new Error(`Invalid locked version in ${file}`);
    queries.push({ package: { ecosystem, name }, version });
  };
  const commit = (value) => {
    if (!/^[a-f0-9]{40}$/.test(value || '')) throw new Error(`Invalid locked commit in ${file}`);
    queries.push({ commit: value });
  };
  const name = basename(file);
  if (name === 'yarn.lock') {
    if (!/^__metadata:/m.test(text)) throw new Error('Only Yarn Berry lockfiles are supported');
    for (const line of text.split('\n').filter(line => /^\s+resolution:/.test(line))) {
      const m = line.match(/^  resolution: "([^"\n]+)"$/);
      if (!m) throw new Error(`Unrecognized Yarn resolution in ${file}`);
      const npm = m[1].match(/^(@?[^@]+)@npm:([^:]+)$/);
      if (npm) add('npm', npm[1], npm[2]);
      else if (!m[1].includes('@workspace:')) gaps.push({ kind: 'non-registry-resolution', locator: m[1] });
    }
  } else if (name === 'package-lock.json') {
    const lock = JSON.parse(text);
    if (![2, 3].includes(lock.lockfileVersion) || !lock.packages) throw new Error('Expected npm lockfile v2/v3');
    for (const [path, pkg] of Object.entries(lock.packages)) {
      if (!path) continue;
      if (pkg.link || !pkg.version || !/^https:\/\/registry\.npmjs\.org\//.test(pkg.resolved || '')) {
        gaps.push({ kind: 'non-registry-resolution', locator: path });
        continue;
      }
      add('npm', pkg.name || path.split('node_modules/').at(-1), pkg.version);
      if (!pkg.integrity) gaps.push({ kind: 'missing-integrity', locator: path });
    }
  } else if (name.endsWith('gradle.lockfile')) {
    for (const line of text.split('\n')) {
      if (!line || line.startsWith('#') || line.startsWith('empty=')) continue;
      const m = line.match(/^([^:=\s]+):([^:=\s]+):([^=\s]+)=.+$/);
      if (!m) throw new Error(`Unrecognized Gradle lock entry in ${file}`);
      add('Maven', `${m[1]}:${m[2]}`, m[3]);
    }
  } else if (name === 'Package.resolved') {
    const lock = JSON.parse(text), pins = lock.pins || lock.object?.pins;
    if (!Array.isArray(pins)) throw new Error('Missing SwiftPM pins');
    for (const pin of pins) {
      const url = (pin.location || pin.repositoryURL || '').replace(/\.git$/, '');
      if (!/^https:\/\//.test(url)) throw new Error('Expected public HTTPS Swift package URL');
      if (pin.state?.version) add('SwiftURL', url, pin.state.version);
      if (pin.state?.revision) commit(pin.state.revision);
      else gaps.push({ kind: 'missing-commit', locator: url });
    }
  } else if (name === 'Podfile.lock') {
    const pods = text.match(/^PODS:\n([\s\S]*?)(?=^\S|$(?![\s\S]))/m)?.[1];
    if (!pods) throw new Error('Missing CocoaPods inventory');
    // OSV has no CocoaPods ecosystem. Do not pretend a name/version query is
    // covered; exact Git checkouts can still be checked below.
    for (const m of pods.matchAll(/^  - ([^\s/(]+)(?:\/[^\s(]+)? \(([^)]+)\)/gm)) {
      gaps.push({ kind: 'unsupported-cocoapods-ecosystem', locator: `${m[1]}@${m[2]}` });
    }
    const checkouts = text.match(/^CHECKOUT OPTIONS:\n([\s\S]*?)(?=^\S|$(?![\s\S]))/m)?.[1] || '';
    for (const block of checkouts.split(/(?=^  [^\s])/m).filter(x => x.trim())) {
      const revision = block.match(/^    :commit: ([a-f0-9]{40})$/m)?.[1];
      if (revision) commit(revision);
      else gaps.push({ kind: 'mutable-pod-checkout', locator: block.split('\n')[0].trim() });
    }
  } else if (name === 'Gemfile.lock') {
    const sections = text.split(/(?=^[A-Z][A-Z ]*(?:\n|$))/m);
    const platforms = (sections.find(section => section.startsWith('PLATFORMS\n')) || '').split('\n').slice(1).map(line => line.trim()).filter(Boolean).sort((a, b) => b.length - a.length);
    let bundledWithSeen = false;
    for (const section of sections) {
      if (section.startsWith('GIT\n')) {
        const revision = section.match(/^  revision: ([a-f0-9]{40})$/m)?.[1];
        if (revision) commit(revision);
        else throw new Error(`Unpinned Git gem in ${file}`);
      } else if (section.startsWith('PATH\n')) {
        gaps.push({ kind: 'non-registry-resolution', locator: section.match(/^  remote: (.+)$/m)?.[1] || 'local gems' });
      } else if (/^BUNDLED WITH(?:\n|$)/.test(section)) {
        const versions = section.split('\n').slice(1).map(line => line.trim()).filter(Boolean);
        // Bundler itself is usually absent from GEM specs. Require one exact
        // RubyGems version, including prereleases, rather than a requirement.
        if (bundledWithSeen || versions.length !== 1 || !/^[0-9]+(?:\.[0-9A-Za-z]+)*(?:-[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?$/.test(versions[0])) {
          throw new Error(`Invalid locked Bundler version in ${file}`);
        }
        bundledWithSeen = true;
        add('RubyGems', 'bundler', versions[0]);
      } else if (section.startsWith('GEM\n')) {
        const remotes = [...section.matchAll(/^  remote: (.+)$/gm)].map(match => match[1]);
        if (remotes.length !== 1 || !/^https:\/\/rubygems\.org\/?$/.test(remotes[0])) {
          gaps.push({ kind: 'non-registry-resolution', locator: remotes.join(',') || 'gem source' });
          continue;
        }
        for (const match of section.matchAll(/^    ([^\s]+) \(([^)]+)\)$/gm)) {
          const platform = platforms.find(platform => match[2].endsWith(`-${platform}`));
          add('RubyGems', match[1], platform ? match[2].slice(0, -platform.length - 1) : match[2]);
        }
      }
    }
  } else if (name === 'Cargo.lock') {
    for (const block of text.split('[[package]]').slice(1)) {
      const field = (key) => block.match(new RegExp(`^${key} = "([^"\\n]+)"$`, 'm'))?.[1];
      const source = field('source');
      if (!source) continue; // Local workspace package.
      if (source === 'registry+https://github.com/rust-lang/crates.io-index') add('crates.io', field('name'), field('version'));
      else if (/^git\+.*#[a-f0-9]{40}$/.test(source)) commit(source.split('#').at(-1));
      else gaps.push({ kind: 'non-registry-resolution', locator: field('name') });
    }
  } else throw new Error(`Unsupported lockfile: ${file}`);
  if (!queries.length && !gaps.length) throw new Error(`No packages found in ${file}`);
  return { queries, gaps };
}

export async function queryOsv(queries, request) {
  const hits = queries.map(() => new Set());
  // Handle pagination independently for every package; never interpret malformed
  // or partial responses as a clean scan.
  for (let start = 0; start < queries.length; start += 200) {
    let pending = queries.slice(start, start + 200).map((query, offset) => ({ query, index: start + offset, seen: new Set() }));
    for (let page = 0; pending.length; page++) {
      if (page >= 100) throw new Error('OSV pagination limit exceeded');
      const result = await request('/querybatch', { queries: pending.map(x => x.query) });
      if (!Array.isArray(result.results) || result.results.length !== pending.length) throw new Error('Incomplete OSV batch response');
      const next = [];
      result.results.forEach((row, i) => {
        if (!row || typeof row !== 'object' || Array.isArray(row) || row.error || (row.vulns !== undefined && !Array.isArray(row.vulns))) throw new Error('Invalid OSV package response');
        for (const vuln of row.vulns || []) {
          if (typeof vuln.id !== 'string' || !/^[A-Za-z0-9._-]+$/.test(vuln.id)) throw new Error('Invalid OSV advisory ID');
          hits[pending[i].index].add(vuln.id);
        }
        if (row.next_page_token !== undefined && typeof row.next_page_token !== 'string') throw new Error('Invalid OSV page token');
        if (row.next_page_token) {
          if (typeof row.next_page_token !== 'string' || pending[i].seen.has(row.next_page_token)) throw new Error('Invalid/repeated OSV page token');
          pending[i].seen.add(row.next_page_token);
          next.push({ ...pending[i], query: { ...pending[i].query, page_token: row.next_page_token } });
        }
      });
      pending = next;
    }
  }
  const details = {};
  for (const id of new Set(hits.flatMap(x => [...x]))) {
    const v = await request(`/vulns/${encodeURIComponent(id)}`);
    if (v.id !== id) throw new Error('OSV advisory identity mismatch');
    if (v.withdrawn !== undefined && v.withdrawn !== null && (
      typeof v.withdrawn !== 'string' ||
      !/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}:\d{2})$/.test(v.withdrawn) ||
      !Number.isFinite(Date.parse(v.withdrawn))
    )) throw new Error('Invalid OSV withdrawal timestamp');
    details[id] = { id, summary: v.summary || '', aliases: v.aliases || [], withdrawn: v.withdrawn || null,
      severity: v.database_specific?.severity || null, affected: v.affected || [],
      url: `https://osv.dev/vulnerability/${id}`, malicious: id.startsWith('MAL-') };
  }
  return hits.map(ids => [...ids].map(id => details[id]).filter(v => !v.withdrawn));
}

async function request(path, body) {
  let error;
  for (let attempt = 0; attempt < 3; attempt++) {
    try {
      const response = await fetch(`https://api.osv.dev/v1${path}`, {
        ...(body ? { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify(body) } : {}),
        signal: AbortSignal.timeout(30000), redirect: 'error',
      });
      if (!response.ok) throw new Error(`OSV HTTP ${response.status}`);
      return await response.json();
    } catch (e) { error = e; }
  }
  throw error;
}

async function main(args) {
  const [out, ...files] = args;
  if (!out || !files.length) throw new Error('Usage: node scripts/scan-locked-dependencies.mjs REPORT.json LOCKFILE...');
  if (files.some(file => resolve(file) === resolve(out))) throw new Error('Report must not overwrite an input');
  const unique = new Map(), inputs = [], coverageGaps = [];
  for (const file of files) {
    const bytes = readFileSync(file), parsed = parseLockfile(file, bytes.toString('utf8'));
    inputs.push({ file, sha256: createHash('sha256').update(bytes).digest('hex'), queries: parsed.queries.length });
    coverageGaps.push(...parsed.gaps.map(gap => ({ file, ...gap })));
    for (const query of parsed.queries) {
      const key = JSON.stringify(query);
      if (!unique.has(key)) unique.set(key, { query, sources: [] });
      if (!unique.get(key).sources.includes(file)) unique.get(key).sources.push(file);
    }
  }
  const records = [...unique.values()];
  if (!records.length) throw new Error('No queryable packages; all inputs require manual review');
  console.error(`Querying OSV for ${records.length} unique package versions/commits from ${inputs.length} lockfiles`);
  const results = await queryOsv(records.map(x => x.query), request);
  const findings = records.flatMap((record, i) => results[i].length ? [{ ...record, advisories: results[i] }] : []);
  const report = { schemaVersion: 1, scannedAt: new Date().toISOString(), inputs, queryCount: records.length,
    findingCount: findings.length, findings, coverageGaps,
    limitations: ['Known advisories only; no proof of absence of malware or exploitable code.',
      'Git commit coverage depends on OSV source indexing. Forks may need upstream-equivalence review.',
      'Vendored, local, binary and unsupported resolutions require independent source/provenance review.',
      'No reachability analysis or release qualification; source and runtime usage must be reviewed.'] };
  mkdirSync(dirname(resolve(out)), { recursive: true });
  writeFileSync(out, JSON.stringify(report, null, 2) + '\n');
  console.log(JSON.stringify({ report: resolve(out), queries: records.length, affected: findings.length, coverageGaps: coverageGaps.length }));
  process.exitCode = findings.length ? 1 : 0;
}

if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) {
  main(process.argv.slice(2)).catch(error => { console.error(`[dependency-scan] ${error.message}`); process.exitCode = 2; });
}
