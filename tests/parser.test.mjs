// 单元测试：scripts/yq-compatible.mjs（node --test，零依赖）
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

import { parseYaml, getPath } from "../scripts/yq-compatible.mjs";

const here = dirname(fileURLToPath(import.meta.url));
const configText = readFileSync(join(here, "..", "config.yml"), "utf8");

test("parses real config.yml into nested object", () => {
  const tree = parseYaml(configText);
  // 不要在这里断言具体的上游版本/内核版本：config.yml 会随上游 stable
  // release 更新（例如 24.10 -> 25.12、内核 6.6 -> 6.12），写死会让
  // parser-tests 在纯配置变更时误报。这里只校验结构与类型。
  assert.equal(typeof tree.source.branch, "string");
  assert.match(tree.source.branch, /^openwrt-/);
  assert.equal(typeof tree.source.repo, "string");
  assert.equal(tree.target.board, "x86");
  assert.equal(tree.target.subtarget, "64");
  assert.equal(tree.features.virtio.enabled, true);
  assert.equal(tree.features.virtiofs.enabled, true);
  assert.equal(tree.features.network.wireguard, true);
  assert.equal(tree.features.performance.bbr, true);
  assert.equal(tree.features.luci.theme, "bootstrap");
  assert.equal(tree.build.jobs, 0);
  assert.equal(typeof tree.kernel.version, "string");
  assert.match(tree.kernel.version, /^\d+\.\d+$/);
});

test("dotted path lookup", () => {
  const tree = parseYaml(configText);
  assert.equal(getPath(tree, "features.proxy.nikki"), false);
  // 版本随上游变化，这里只要求拿得到形如 6.12 的字符串
  assert.match(getPath(tree, "kernel.version"), /^\d+\.\d+$/);
  assert.equal(getPath(tree, "does.not.exist"), undefined);
});

test("comments and inline values", () => {
  const tree = parseYaml(`
a: 1        # trailing comment
b: "has # inside quotes"   # note
#c: full-line comment
d: hello # world
`);
  assert.equal(tree.a, 1);
  assert.equal(tree.b, "has # inside quotes");
  assert.equal(tree.c, undefined);
  assert.equal(tree.d, "hello");
});

test("flow sequences and block sequences", () => {
  const tree = parseYaml(`
inline: [x, y, "z"]
empty_inline: []
block:
  - one
  - two
nested:
  key: val
  deeper:
    n: 3
`);
  assert.deepEqual(tree.inline, ["x", "y", "z"]);
  assert.deepEqual(tree.empty_inline, []);
  assert.deepEqual(tree.block, ["one", "two"]);
  assert.equal(tree.nested.deeper.n, 3);
});

test("scalar types", () => {
  const tree = parseYaml(`
s_true: true
s_false: false
s_num: 42
s_float: 1.5
s_null: null
s_str: plain string
s_quoted: 'single'
`);
  assert.equal(tree.s_true, true);
  assert.equal(tree.s_false, false);
  assert.equal(tree.s_num, 42);
  assert.equal(tree.s_float, 1.5);
  assert.equal(tree.s_null, null);
  assert.equal(tree.s_str, "plain string");
  assert.equal(tree.s_quoted, "single");
});

test("url values keep their colon", () => {
  const tree = parseYaml(configText);
  assert.equal(tree.source.repo, "https://github.com/immortalwrt/immortalwrt.git");
});
