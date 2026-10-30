#!/usr/bin/env node
// =============================================================================
// scripts/yq-compatible.mjs - deterministic YAML reader for config.yml
// =============================================================================
// Why this exists:
//   ubuntu-24.04 GitHub runners ship *two* unrelated tools named "yq"
//   (the Python jq-wrapper and mikefarah's Go binary via snapd). Depending on
//   PATH order, `yq '.packages.exclude'` may be interpreted as a jq filter
//   against JSON and fail silently, which left packages.include/exclude empty
//   in scripts/build.sh and produced a corrupt .config line
//   ("# CONFIG_PACKAGE_ is not set") that made `make defconfig` fail while
//   building scripts/config/conf.
//
// This script removes the ambiguity: it uses Node.js + the pinned `yaml`
// package from package.json / package-lock.json (installed with `npm ci`) and
// implements exactly the tiny query subset the bash helpers use:
//
//   yq-compatible.mjs --dump <file>
//       -> print every leaf as "dot.path=value"; scalar sequences are joined
//          with spaces under their own path; null values are skipped.
//
//   yq-compatible.mjs '<expr>' <file>
//       -> <expr> is one of:
//             .a.b.c
//             .a.b.c | if type == "array" then join(" ") else . end
//          Prints the raw value; prints nothing for missing keys/null.
//          A trailing `// ""` alternative is tolerated (no-op).
//
// Exits 0 even when the key is absent (prints nothing), exits non-zero only
// on genuine parse/usage errors so callers can fall back to the pure-bash
// parser.
// =============================================================================

import { readFileSync } from 'node:fs';
import { createRequire } from 'node:module';

const require = createRequire(import.meta.url);

// Prefer the workspace `yaml` package; fall back to js-yaml if present.
let parseYaml;
try {
  ({ parse: parseYaml } = require('yaml'));
} catch {
  try {
    const jsyaml = require('js-yaml');
    parseYaml = (text) => jsyaml.load(text);
  } catch {
    console.error('yq-compatible.mjs: neither "yaml" nor "js-yaml" is installed (run: npm ci)');
    process.exit(2);
  }
}

function usage() {
  console.error('usage: yq-compatible.mjs (--dump | "<.dot.path>[ | if type == array ...]") <file>');
  process.exit(2);
}

const argv = process.argv.slice(2);
if (argv.length !== 2) usage();
const [queryOrFlag, file] = argv;

let doc;
try {
  doc = parseYaml(readFileSync(file, 'utf8'));
} catch (err) {
  console.error(`yq-compatible.mjs: failed to parse ${file}: ${err.message}`);
  process.exit(3);
}

function scalarText(v) {
  if (v === true) return 'true';
  if (v === false) return 'false';
  return String(v);
}

// ---- --dump: flatten to dot.path=value lines -------------------------------
if (queryOrFlag === '--dump') {
  const out = [];
  const walk = (node, path) => {
    if (node === null || node === undefined) return;
    if (Array.isArray(node)) {
      const scalars = node.filter((x) => x !== null && typeof x !== 'object');
      if (scalars.length > 0) out.push(`${path}=${scalars.map(scalarText).join(' ')}`);
      node.forEach((item, i) => {
        if (item !== null && typeof item === 'object') walk(item, `${path}.${i}`);
      });
      return;
    }
    if (typeof node === 'object') {
      for (const [k, v] of Object.entries(node)) {
        if (v !== null && typeof v === 'object') walk(v, path ? `${path}.${k}` : `${k}`);
        else if (v !== null && v !== undefined) out.push(`${path ? `${path}.${k}` : k}=${scalarText(v)}`);
      }
      return;
    }
    // bare scalar at root
    out.push(`${path}=${scalarText(node)}`);
  };
  walk(doc, '');
  process.stdout.write(out.join('\n') + (out.length ? '\n' : ''));
  process.exit(0);
}

// ---- expression form --------------------------------------------------------
// Strip an optional trailing `// ""` / `// ''` default (mikefarah syntax we
// accept but do not need - absent keys already print nothing).
let expr = queryOrFlag.replace(/\s*\/\/\s*(""|'')\s*$/, '');

// Optional pipe suffix: | if type == "array" then join(" ") else . end
let joinArrays = false;
const pipeIdx = expr.indexOf('|');
if (pipeIdx !== -1) {
  const suffix = expr.slice(pipeIdx + 1);
  if (/type\s*==\s*"array"[\s\S]*join\(\s*" "\s*\)/.test(suffix)) joinArrays = true;
  expr = expr.slice(0, pipeIdx);
}

expr = expr.trim();
if (!expr.startsWith('.')) usage();
const parts = expr
  .slice(1)
  .split('.')
  .filter((p) => p !== '')
  .map((p) => p.replace(/^"|"$/g, ''));

let cur = doc;
for (const p of parts) {
  if (cur === null || cur === undefined) { cur = undefined; break; }
  if (Array.isArray(cur) && /^\d+$/.test(p)) cur = cur[Number(p)];
  else if (typeof cur === 'object') cur = cur[p];
  else { cur = undefined; break; }
}

if (cur === undefined || cur === null) process.exit(0);

if (Array.isArray(cur)) {
  const scalars = cur.filter((x) => x !== null && typeof x !== 'object').map(scalarText);
  if (joinArrays) {
    process.stdout.write(scalars.join(' '));
  } else {
    process.stdout.write(cur.map((x) => JSON.stringify(x)).join('\n'));
  }
  process.exit(0);
}

if (typeof cur === 'object') {
  process.stdout.write(JSON.stringify(cur));
} else {
  process.stdout.write(scalarText(cur));
}
process.exit(0);
