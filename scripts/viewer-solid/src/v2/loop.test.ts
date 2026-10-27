import { test } from "node:test";
import assert from "node:assert/strict";
import { loopSteps } from "./loop.ts";
import { stand } from "./ship.ts";
import type { Branch, Pr } from "./types.ts";

const NOW = Date.parse("2026-10-22T18:00:00Z");
const br = (over: Partial<Branch> = {}): Branch => ({
  id: "r:b", repo: "r", name: "f/b", project: "r:f", parent: "main", parentId: null, description: "", subject: "s",
  commits: 1, outline: ["s"], tip: "t", tree: "x", pushed: "local", ahead: 0, gates: "none", redGates: [], order: 1, holdUntil: null,
  behind: 0, drifted: false, upstream: "", upstreamBad: false, diverged: false, ...over,
});
const pr = (over: Partial<Pr> = {}): Pr => ({
  id: "r:b", repo: "r", branch: "f/b", project: "r:f", number: 7, url: "u", state: "OPEN", review: null, draft: false,
  base: null, approvals: null, mergeState: null, mergeable: null, approvedAt: null, title: null, ...over,
});
const at = (b: Branch, p?: Pr, words = []) => {
  const steps = loopSteps(b, p, stand(b, p, undefined, NOW), words);
  const now = steps.filter((s) => s.id !== "words").find((s) => s.state === "now");
  return now ? `${now.id}${now.note ? ` ${now.note}` : ""}` : "done";
};

test("the step in the way, with what it waits on", () => {
  assert.equal(at(br()), "gates not run");
  assert.equal(at(br({ gates: "running" })), "gates running");
  assert.equal(at(br({ gates: "red", redGates: ["typecheck"] })), "gates typecheck");
  assert.equal(at(br({ gates: "green" })), "push 1 local");
  assert.equal(at(br({ gates: "green", pushed: "synced" })), "pr open it");
  assert.equal(at(br({ gates: "green", pushed: "synced" }), pr()), "review waiting");
  assert.equal(at(br({ gates: "green", pushed: "synced" }), pr({ review: "APPROVED" })), "merged you — merge it");
  assert.equal(at(br({ pushed: "synced" }), pr({ state: "MERGED" })), "done");
});

test("new commits on an open PR send the loop back to gates, then push", () => {
  assert.equal(at(br({ pushed: "ahead", ahead: 2, gates: "stale" }), pr()), "gates stale");
  assert.equal(at(br({ pushed: "ahead", ahead: 2, gates: "green" }), pr()), "push 2 to push");
});

test("words flag without blocking, and stop mattering once the PR exists", () => {
  const scope = [{ id: "scope", tone: "warn" as const, text: "" }];
  const words = (b: Branch, p?: Pr) => loopSteps(b, p, stand(b, p, undefined, NOW), scope)[0];
  assert.deepEqual(words(br({ gates: "green" })), { id: "words", state: "now", flag: true, note: "scope" });
  assert.equal(at(br({ gates: "green" }), undefined), "push 1 local");
  assert.equal(words(br({ pushed: "synced" }), pr()).state, "done");
});
