import { test } from "node:test";
import assert from "node:assert/strict";
import { expand, parsePatch, unifiedRows } from "./review/diff.ts";

// new file: 30 lines "n1".."n30". The branch changed line 10 and line 25 (old file had one extra
// line before 25, so old numbers run one ahead after it).
const lines = Array.from({ length: 30 }, (_, i) => `n${i + 1}`).concat("");
const patch = [
  "@@ -8,5 +8,5 @@ function a() {",
  " n8", " n9", "-old10", "+n10", " n11", " n12",
  "@@ -23,6 +23,5 @@ function b() {",
  " n23", " n24", "-gone", "-old25", "+n25", " n26", " n27",
].join("\n");
const f = parsePatch("x.ts", patch);
const nums = (file: ReturnType<typeof expand>["file"]) => unifiedRows(file).map((r) => `${r.left?.old ?? "-"}/${r.right?.new ?? "-"}`).join(" ");

test("unread: the gaps before each hunk, and an open-ended one after", () => {
  const { gaps } = expand(f, undefined, new Map());
  assert.deepEqual(gaps.map((g) => [g.at, g.first, g.last, g.label]), [[0, 1, 7, "function a() {"], [1, 13, 22, "function b() {"], [2, 28, null, ""]]);
});

test("revealing above a hunk adds context lines with both numbers, nearest the change first", () => {
  const { file, gaps } = expand(f, lines, new Map([[1, 3]]));
  assert.match(nums(file), /12\/12 20\/20 21\/21 22\/22 23\/23/);
  assert.deepEqual(gaps.map((g) => [g.at, g.first, g.last]), [[0, 1, 7], [1, 13, 19], [2, 28, 30]]);
  assert.equal(file.hunks[1].lines[0].text, "n20");
});

test("revealing past a gap's size closes it; after the last hunk old numbers keep the offset", () => {
  const { file, gaps } = expand(f, lines, new Map([[0, 50], [2, 2]]));
  assert.deepEqual(gaps.map((g) => g.at), [1, 2]);
  assert.match(nums(file), /^1\/1 2\/2 .* 7\/7 8\/8/);
  assert.match(nums(file), / 28\/27 29\/28 30\/29$/);
  assert.deepEqual([gaps[1].first, gaps[1].last], [30, 30]);
});

test("added, deleted and binary files have nothing hidden", () => {
  assert.deepEqual(expand({ ...f, status: "added" }, lines, new Map()).gaps, []);
  assert.deepEqual(expand({ ...f, status: "deleted" }, undefined, new Map()).gaps, []);
});
