#!/usr/bin/env node
// Smoke tests for scripts/yq-compatible.mjs.
// Run: node --test tests/
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { writeFileSync, mkdtempSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = join(dirname(fileURLToPath(import.meta.url)), '..');
const parser = join(root, 'scripts', 'yq-compatible.mjs');

const yamlDoc = `
source:
  repo: "https://example.com/repo.git"
  branch: "openwrt-24.10"
target:
  arch: x86_64
build:
  jobs: 0
  timeout: 330
features:
  virtio:
    enabled: true
    net: false
packages:
  include:
    - "luci-app-statistics"
    - "htop"
  exclude:
    - "ppp"
    - "ppp-mod-pppoe"
empty_key: null
`;

const dir = mkdtempSync(join(tmpdir(), 'yq-test-'));
const file = join(dir, 'config.yml');
writeFileSync(file, yamlDoc);

const q = (expr) => execFileSync('node', [parser, expr, file], { encoding: 'utf8' });

test('plain nested scalar', () => {
  assert.equal(q('.source.repo'), 'https://example.com/repo.git');
  assert.equal(q('.build.timeout'), '330');
});

test('boolean scalar', () => {
  assert.equal(q('.features.virtio.enabled'), 'true');
  assert.equal(q('.features.virtio.net'), 'false');
});

test('array joined with spaces (mikefarah subset)', () => {
  assert.equal(
    q('.packages.exclude | if type == "array" then join(" ") else . end'),
    'ppp ppp-mod-pppoe'
  );
  assert.equal(
    q('.packages.include | if type == "array" then join(" ") else . end'),
    'luci-app-statistics htop'
  );
});

test('missing key prints nothing, exit 0', () => {
  assert.equal(q('.does.not.exist'), '');
  assert.equal(q('.empty_key'), '');
});

test('trailing // "" default is tolerated', () => {
  assert.equal(q('.source.branch // ""'), 'openwrt-24.10');
});

test('--dump flattens to dot.path=value lines', () => {
  const dump = q('--dump');
  const map = Object.fromEntries(
    dump.split('\n').filter(Boolean).map((l) => [l.slice(0, l.indexOf('=')), l.slice(l.indexOf('=') + 1)])
  );
  assert.equal(map['source.repo'], 'https://example.com/repo.git');
  assert.equal(map['packages.exclude'], 'ppp ppp-mod-pppoe');
  assert.equal(map['features.virtio.net'], 'false');
  assert.ok(!('empty_key' in map), 'null values must be skipped');
});

test('malformed YAML exits non-zero', () => {
  const bad = join(dir, 'bad.yml');
  writeFileSync(bad, 'a: [1, 2\n  b: }{\n');
  assert.throws(
    () => execFileSync('node', [parser, '--dump', bad], { encoding: 'utf8', stdio: 'pipe' }),
    (err) => err.status === 3
  );
});
