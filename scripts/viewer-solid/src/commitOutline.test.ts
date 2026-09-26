import { test } from "node:test";
import assert from "node:assert/strict";
import { outlineOf, outlineNumber } from "./commitOutline.ts";

const commit = (sha: string, extra: { own?: boolean; carried?: boolean } = {}) => ({
  sha,
  subject: sha,
  author: "a",
  date: "d",
  ...extra,
});

// /commits returns git log order (newest first); the outline reads oldest first
test("the outline is the branch's own commits, oldest first", () => {
  const log = [commit("c3", { own: true }), commit("c2", { own: true }), commit("c1", { own: true }), commit("a0", { own: false })];
  assert.deepEqual(
    outlineOf(log).map((c) => c.sha),
    ["c1", "c2", "c3"],
  );
});

test("carried fan-in picks sit in the outline but take no number", () => {
  const outline = outlineOf([
    commit("s2", { own: true }),
    commit("s1", { own: true }),
    commit("h1", { own: true, carried: true }),
  ]);
  assert.equal(outlineNumber(outline, "h1"), undefined);
  assert.equal(outlineNumber(outline, "s1"), 1);
  assert.equal(outlineNumber(outline, "s2"), 2);
});

test("an ancestor has no outline number", () => {
  assert.equal(outlineNumber(outlineOf([commit("c1", { own: true })]), "a0"), undefined);
});
