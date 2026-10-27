import { test } from "node:test";
import assert from "node:assert/strict";
import { planSteps, prepOf, rebaseOf, sealed, syncNeeds, testsOf, type SyncFacts } from "./syncing.ts";
import type { Branch } from "./types.ts";

const br = (over: Partial<Branch> = {}): Branch => ({
  id: "r:b", repo: "r", name: "f/b", project: "r:f", parent: "f/a", parentId: "r:f/a", description: "", subject: "s",
  commits: 1, outline: ["s"], tip: "t", tree: "x", pushed: "local", ahead: 0, gates: "none", redGates: [], order: 1, holdUntil: null,
  behind: 0, drifted: false, upstream: "", upstreamBad: false, diverged: false, ...over,
});
const facts = (over: Partial<SyncFacts> = {}): SyncFacts => ({
  behind: 0, syncable: false, restack: false, published: false, dirty: [], dirtyWorktree: "", why: "", ...over,
});

test("a branch at rest needs no sync", () => {
  assert.deepEqual(syncNeeds(br(), facts(), { route: "ready", why: "" }), []);
  assert.deepEqual(syncNeeds(br(), facts(), { route: "nothing", why: "" }), []);
});

test("dirt, drift, a rebasable lag and an unvoiced tail each make it need one", () => {
  assert.deepEqual(syncNeeds(br(), facts({ dirty: ["a.ts", "b.ts"] })), ["2 uncommitted"]);
  assert.deepEqual(syncNeeds(br({ drifted: true })), ["off f/a's tip"]);
  assert.deepEqual(syncNeeds(br(), facts({ behind: 3, restack: true })), ["3 behind main"]);
  assert.deepEqual(syncNeeds(br(), null, { route: "squash", why: "" }), ["not one voiced commit"]);
  assert.deepEqual(syncNeeds(br(), null, { route: "additive", why: "" }), ["diverged from its PR"]);
  assert.deepEqual(syncNeeds(br({ diverged: true }), null, { route: "ready", why: "" }), ["diverged from origin"]);
});

test("behind main alone isn't a reason when nothing could rebase it (an open PR)", () => {
  assert.deepEqual(syncNeeds(br(), facts({ behind: 3, published: true })), []);
});

test("the steps follow v1's order, with only the repairs the branch needs", () => {
  assert.deepEqual(planSteps({ drifted: false, facts: facts() }).map((s) => s.id), ["dirt", "prep", "gates", "tests"]);
  assert.deepEqual(planSteps({ drifted: true, facts: facts({ behind: 2, syncable: true }) }).map((s) => s.id), ["dirt", "reseat", "rebase", "prep", "gates", "tests"]);
  assert.equal(planSteps({ drifted: false, facts: facts({ behind: 2, restack: true }) })[1].label, "restack");
});

test("a /sync answer reads as rebased, a queued restack, already merged, a conflict for Claude, or a refusal", () => {
  assert.deepEqual(rebaseOf(true, { rebased: true, summary: "replayed 2 commits onto origin/main" }), { kind: "rebased", note: "replayed 2 commits onto origin/main" });
  assert.deepEqual(rebaseOf(true, { restack: true, project: "f" }), { kind: "restack", project: "f" });
  assert.deepEqual(rebaseOf(true, { contract: true }), { kind: "contract" });
  assert.deepEqual(rebaseOf(true, { ejected: true, conflict: true, stream: "rebase:f/b" }), { kind: "conflict" });
  assert.equal(rebaseOf(false, { err: "has an open PR" }).kind, "refused");
});

test("a /prep-push answer: nothing to push and a built vehicle are states, a divergence goes to Claude", () => {
  assert.deepEqual(prepOf(true, { routed: ["sealed 3 unpushed commits into one (voiced)"] }), { kind: "ok", note: "sealed 3 unpushed commits into one (voiced)" });
  assert.equal(prepOf(false, { err: "nothing to push — origin already has this" }).kind, "rest");
  assert.equal(prepOf(false, { vehiclePending: true, err: "x" }).kind, "rest");
  assert.equal(prepOf(false, { reconcile: true, err: "diverged from origin without an open PR" }).kind, "claude");
  assert.deepEqual(prepOf(false, { err: "unpushed commits include a merge" }), { kind: "fail", note: "unpushed commits include a merge" });
});

test("the tests are advice: a failure keeps its whole summary", () => {
  assert.equal(testsOf({ ran: true, ok: true, passed: 4 }).note, "4 ✓");
  assert.equal(testsOf({ noTests: true }).note, "no changed tests");
  const red = testsOf({ ran: true, ok: false, failed: 1, summary: "✖ it breaks\nat line 3" });
  assert.equal(red.state, "fail");
  assert.match(red.note, /it breaks\nat line 3$/);
  assert.equal(testsOf({ err: "network" }).note, "couldn't run");
});

test("only a seal sends you to the words", () => {
  assert.equal(sealed({ routed: ["sealed 3 unpushed commits into one (voiced)"] }), true);
  assert.equal(sealed({ routed: ["2 voiced commits — pushed as they are, no seal"] }), false);
  assert.equal(sealed({}), false);
});
