#!/usr/bin/env node
// ---------------------------------------------------------------------------
// yq-compatible.mjs — 确定性的 config.yml 读取器（Node.js，零依赖）。
//
// 背景：GitHub Actions runner 镜像里同时存在两个互不相关的 `yq`
// （python-yq 与 mikefarah-yq），行为不一致。因此本仓库**任何地方都不
// 直接使用裸 `yq`**，统一通过本脚本解析 config.yml。
//
// 用法：
//   node scripts/yq-compatible.mjs <key.path> [config.yml]
//   node scripts/yq-compatible.mjs --list features.network [config.yml]
//   node scripts/yq-compatible.mjs --json [config.yml]      # 整棵树 JSON
//
// 支持的 YAML 子集（足以覆盖本仓库 config.yml）：
//   - 任意深度缩进 mapping（按缩进栈处理）
//   - 标量：字符串（带/不带引号）、布尔、数字、null
//   - 行内流式数组：[a, b, "c"]
//   - 块数组：以 "-" 开头的行
//   - 注释（# 起始，尊重引号内的 #）
// 退出码：0 成功；1 key 不存在；2 用法/解析错误。
// ---------------------------------------------------------------------------

import { readFileSync } from "node:fs";
import { resolve } from "node:path";

const USAGE =
  "usage: node yq-compatible.mjs [--json | --list] <dotted.key.path> [config.yml]";

function stripComment(line) {
  let inS = false;
  let inD = false;
  for (let i = 0; i < line.length; i++) {
    const c = line[i];
    if (c === "'" && !inD) inS = !inS;
    else if (c === '"' && !inS) inD = !inD;
    else if (c === "#" && !inS && !inD) {
      // treat as comment only when at start or preceded by whitespace
      if (i === 0 || /\s/.test(line[i - 1])) return line.slice(0, i);
    }
  }
  return line;
}

function parseScalar(raw) {
  const s = raw.trim();
  if (s === "" || s === "null" || s === "~") return null;
  if ((s.startsWith('"') && s.endsWith('"')) || (s.startsWith("'") && s.endsWith("'"))) {
    return s.slice(1, -1);
  }
  if (s === "true") return true;
  if (s === "false") return false;
  if (/^-?\d+(\.\d+)?$/.test(s)) return Number(s);
  return s;
}

function parseFlowSeq(s) {
  // s like: [a, b, "c"]  (no nested brackets supported)
  const inner = s.slice(1, -1).trim();
  if (inner === "") return [];
  const parts = [];
  let cur = "";
  let depth = 0;
  let inQ = null;
  for (const c of inner) {
    if (inQ) {
      cur += c;
      if (c === inQ) inQ = null;
      continue;
    }
    if (c === '"' || c === "'") { inQ = c; cur += c; continue; }
    if (c === "[") depth++;
    if (c === "]") depth--;
    if (c === "," && depth === 0) { parts.push(cur); cur = ""; continue; }
    cur += c;
  }
  if (cur.trim() !== "") parts.push(cur);
  return parts.map((p) => parseScalar(p));
}

export function parseYaml(text) {
  const root = {};
  // stack of {indent, container}
  const stack = [{ indent: -1, container: root }];
  const lines = text.split(/\r?\n/);
  let pendingBlockList = null; // {container, key}

  for (let ln = 0; ln < lines.length; ln++) {
    const rawLine = lines[ln];
    const line = stripComment(rawLine);
    if (line.trim() === "") continue;
    const indent = line.length - line.trimStart().length;
    const content = line.trim();

    // block list item
    if (content.startsWith("- ") || content === "-") {
      if (pendingBlockList) {
        const { container, key } = pendingBlockList;
        if (!Array.isArray(container[key])) container[key] = [];
        container[key].push(parseScalar(content.slice(1)));
        continue;
      }
      throw new Error(`line ${ln + 1}: list item without a key`);
    }

    const m = content.match(/^([^:]+):(.*)$/);
    if (!m) throw new Error(`line ${ln + 1}: cannot parse "${content}"`);
    const key = m[1].trim().replace(/^["']|["']$/g, "");
    const rest = m[2].trim();

    // unwind stack to parent level
    while (stack.length > 1 && indent <= stack[stack.length - 1].indent) {
      stack.pop();
    }
    const parent = stack[stack.length - 1].container;

    pendingBlockList = null;

    if (rest === "") {
      const child = {};
      parent[key] = child;
      stack.push({ indent, container: child });
      pendingBlockList = { container: parent, key };
    } else if (rest.startsWith("[") && rest.endsWith("]")) {
      parent[key] = parseFlowSeq(rest);
    } else {
      parent[key] = parseScalar(rest);
    }
  }
  return root;
}

export function getPath(tree, dotted) {
  if (!dotted) return tree;
  let cur = tree;
  for (const seg of dotted.split(".")) {
    if (cur === null || cur === undefined || typeof cur !== "object") return undefined;
    cur = cur[seg];
  }
  return cur;
}

function emit(value) {
  if (value === undefined) return undefined;
  if (Array.isArray(value)) return value.join("\n");
  if (typeof value === "boolean") return value ? "true" : "false";
  if (value === null) return "";
  if (typeof value === "object") return JSON.stringify(value);
  return String(value);
}

function main(argv) {
  const args = argv.slice(2);
  if (args.length === 0) { console.error(USAGE); process.exit(2); }

  let mode = "get";
  const positional = [];
  for (const a of args) {
    if (a === "--json") mode = "json";
    else if (a === "--list") mode = "list";
    else if (a === "--help" || a === "-h") { console.log(USAGE); process.exit(0); }
    else positional.push(a);
  }

  const file = positional.length > 1 ? resolve(positional[1]) : resolve("config.yml");
  const keyPath = positional[0] || "";

  let tree;
  try {
    tree = parseYaml(readFileSync(file, "utf8"));
  } catch (e) {
    console.error(`error: ${e.message}`);
    process.exit(2);
  }

  if (mode === "json") {
    console.log(JSON.stringify(keyPath ? getPath(tree, keyPath) ?? null : tree, null, 2));
    process.exit(0);
  }

  const value = getPath(tree, keyPath);
  if (value === undefined) {
    console.error(`error: key not found: ${keyPath}`);
    process.exit(1);
  }
  if (mode === "list") {
    if (Array.isArray(value)) { console.log(value.join("\n")); process.exit(0); }
    if (value && typeof value === "object") { console.log(Object.keys(value).join("\n")); process.exit(0); }
    console.log(String(value));
    process.exit(0);
  }
  console.log(emit(value));
}

// Only run CLI when executed directly (allows unit tests to import).
if (import.meta.url === `file://${process.argv[1]}`) {
  main(process.argv);
}
