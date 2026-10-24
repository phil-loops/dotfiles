import { test } from "node:test";
import assert from "node:assert/strict";
import { anchorsOf, parsePatch, rowAnchors, splitRows, unifiedRows } from "./review/diff.ts";
import { highlight } from "./review/highlight.ts";
import { inline, plain, renderMarkdown, suggestionOf } from "./review/markdown.ts";

const PATCH = `diff --git a/x.ts b/x.ts
index 1..2 100644
--- a/x.ts
+++ b/x.ts
@@ -1,4 +1,5 @@
 keep
-old one
-old two
+new one
+new two
+new three
 tail
`;

test("a patch parses into numbered lines", () => {
  const f = parsePatch("x.ts", PATCH);
  assert.equal(f.add, 3);
  assert.equal(f.del, 2);
  assert.deepEqual(
    f.hunks[0].lines.map((l) => [l.kind, l.old, l.new]),
    [["ctx", 1, 1], ["del", 2, null], ["del", 3, null], ["add", null, 2], ["add", null, 3], ["add", null, 4], ["ctx", 4, 5]],
  );
});

test("a new file is added and keeps its blank lines", () => {
  const f = parsePatch("n.ts", "new file mode 100644\n--- /dev/null\n+++ b/n.ts\n@@ -0,0 +1,3 @@\n+a\n+\n+b\n");
  assert.equal(f.status, "added");
  assert.deepEqual(f.hunks[0].lines.map((l) => l.new), [1, 2, 3]);
});

test("split pairs each removal with the addition beside it", () => {
  const rows = splitRows(parsePatch("x.ts", PATCH));
  assert.deepEqual(rows.map((r) => [r.left?.old ?? null, r.right?.new ?? null]), [[1, 1], [2, 2], [3, 3], [null, 4], [4, 5]]);
  assert.deepEqual(rowAnchors(rows[1]), ["R:2", "L:2"]);
});

test("unified rows anchor by side; a kept line answers to both", () => {
  const f = parsePatch("x.ts", PATCH);
  assert.deepEqual(unifiedRows(f).map((r) => r.key), ["R:1", "L:2", "L:3", "R:2", "R:3", "R:4", "R:5"]);
  assert.deepEqual(anchorsOf(f.hunks[0].lines[0]), ["R:1", "L:1"]);
});

test("markdown escapes everything it doesn't render", () => {
  const html = renderMarkdown('<img src=x onerror=alert(1)> **b** [x](javascript:alert(1)) `<i>`');
  assert.ok(!html.includes("<img"));
  assert.ok(html.includes("&lt;img"));
  assert.ok(!html.includes('href="javascript'));
  assert.ok(html.includes("<strong>b</strong>"));
  assert.ok(html.includes("<code class=\"md-code\">&lt;i&gt;</code>"));
});

test("markdown links stay inside their attribute", () => {
  const html = inline('[a](https://x.test/"onmouseover="alert(1))');
  assert.ok(!/href="[^"]*"onmouseover/.test(html));
});

test("a suggestion renders as a suggested change over the lines it replaces", () => {
  const html = renderMarkdown("Try:\n\n```suggestion\nconst x = 1;\n```", { replaces: ["let x = 1;"] });
  assert.ok(html.includes("Suggested change"));
  assert.ok(html.includes('<div class="md-sg-del"><span>-</span>let x = 1;</div>'));
  assert.ok(html.includes('<div class="md-sg-add"><span>+</span>const x = 1;</div>'));
});

test("suggestionOf reads the block, an empty one deletes", () => {
  assert.deepEqual(suggestionOf("x\n```suggestion\na\n  b\n```"), ["a", "  b"]);
  assert.deepEqual(suggestionOf("```suggestion\n```"), []);
  assert.equal(suggestionOf("```ts\na\n```"), null);
});

test("lists, quotes and PR-template comments", () => {
  const html = renderMarkdown("<!-- hidden -->\n- [x] done\n- open\n\n> quoted");
  assert.ok(!html.includes("hidden"));
  assert.ok(html.includes("☑ done"));
  assert.ok(html.includes("<blockquote>"));
});

test("plain folds markdown to one line", () => {
  assert.equal(plain("**Bold** `code`\n\n```suggestion\nx\n```\nmore"), "Bold code more");
});

test("highlight keeps the line's text exactly", () => {
  const line = 'export const x: Widget = "a<b>" // note';
  const html = highlight(line, "ts");
  const text = html.replace(/<[^>]+>/g, "").replace(/&lt;/g, "<").replace(/&gt;/g, ">").replace(/&amp;/g, "&");
  assert.equal(text, line);
  assert.ok(html.includes('<span class="hl-k">export</span>'));
  assert.ok(html.includes('<span class="hl-c">// note</span>'));
});
