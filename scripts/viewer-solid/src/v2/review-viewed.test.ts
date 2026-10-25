import { test } from "node:test";
import assert from "node:assert/strict";
import { blocksOf, parsePatch } from "./review/diff.ts";

const keys = (patch: string, path = "x.ts") => blocksOf(parsePatch(path, patch)).map((b) => b.key);

// two changes 4 lines apart: one hunk at -U3, two hunks at -U1
const wide = ["@@ -1,12 +1,12 @@", " a", " b", "-c", "+C", " d", " e", " f", " g", "-h", "+H", " i", " j", " k"].join("\n");
const narrow = ["@@ -2,3 +2,3 @@", " b", "-c", "+C", " d", "@@ -7,3 +7,3 @@", " g", "-h", "+H", " i"].join("\n");

test("a change keeps its key whether git groups it into one hunk or two", () => {
  assert.equal(keys(wide).length, 2);
  assert.deepEqual(keys(wide), keys(narrow));
});

test("line shifts and edited context don't change a key; editing the change does", () => {
  const shifted = ["@@ -40,3 +52,3 @@", " other", "-c", "+C", " lines"].join("\n");
  assert.equal(keys(shifted)[0], keys(narrow)[0]);
  const edited = ["@@ -2,3 +2,3 @@", " b", "-c", "+C2", " d"].join("\n");
  assert.notEqual(keys(edited)[0], keys(narrow)[0]);
});

test("the same change in another file, or twice in one file, gets its own key", () => {
  assert.notEqual(keys(narrow, "y.ts")[0], keys(narrow)[0]);
  const twice = ["@@ -1,3 +1,3 @@", " a", "-c", "+C", " b", "@@ -9,3 +9,3 @@", " y", "-c", "+C", " z"].join("\n");
  const [k1, k2] = keys(twice);
  assert.notEqual(k1, k2);
});

test("a block knows its hunk; a file with no changed lines still has one thing to view", () => {
  assert.deepEqual(blocksOf(parsePatch("x.ts", narrow)).map((b) => b.hunk), [0, 1]);
  const bin = blocksOf({ ...parsePatch("img.png", ""), status: "binary" });
  assert.equal(bin.length, 1);
  assert.equal(bin[0].hunk, -1);
});
