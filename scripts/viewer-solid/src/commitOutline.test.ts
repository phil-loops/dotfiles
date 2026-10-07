import { test } from "node:test";
import assert from "node:assert/strict";
import { outlineOf, outlineNumber, sliceOf, outgoingOf } from "./commitOutline.ts";
import type { Commit } from "./types.ts";

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

test("sliceOf returns the contiguous run between two commits, oldest first, in either click order", () => {
  const outline = outlineOf([
    { sha: "d", subject: "four", own: true },
    { sha: "c", subject: "three", own: true },
    { sha: "b", subject: "two", own: true },
    { sha: "a", subject: "one", own: true },
  ] as Commit[]);
  assert.deepEqual(sliceOf(outline, "b", "d").map((c) => c.sha), ["b", "c", "d"]);
  assert.deepEqual(sliceOf(outline, "d", "b").map((c) => c.sha), ["b", "c", "d"]);
  assert.deepEqual(sliceOf(outline, "b", "b").map((c) => c.sha), ["b"]);
  assert.deepEqual(sliceOf(outline, "b", "zz"), []);
});

test("outgoingOf is everything from the first unpushed commit, and nothing without a remote", () => {
  const pushed = (sha: string, p?: boolean) => ({ sha, subject: sha, own: true, pushed: p }) as Commit;
  assert.deepEqual(outgoingOf(outlineOf([pushed("c", false), pushed("b", false), pushed("a", true)])).map((c) => c.sha), ["b", "c"]);
  assert.deepEqual(outgoingOf(outlineOf([pushed("b", true), pushed("a", true)])), []);
  assert.deepEqual(outgoingOf(outlineOf([pushed("b"), pushed("a")])), []);
});
