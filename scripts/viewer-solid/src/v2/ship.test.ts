import { test } from "node:test";
import assert from "node:assert/strict";
import { baseFor, isClosed, nextMorning, phaseAt, stand, windowLine } from "./ship.ts";
import type { Branch, Pr } from "./types.ts";

const NOW = Date.parse("2026-10-22T18:00:00Z"); // Thu 11:00 PT

const br = (over: Partial<Branch> = {}): Branch => ({
  id: "r:b", repo: "r", name: "f/b", project: "r:f", parent: "main", parentId: null, description: "", subject: "s",
  commits: 1, tip: "t", tree: "x", pushed: "local", ahead: 0, gates: "none", redGates: [], order: 1, holdUntil: null, ...over,
});
const pr = (over: Partial<Pr> = {}): Pr => ({
  id: "r:b", repo: "r", branch: "f/b", project: "r:f", number: 7, url: "u", state: "OPEN", review: null, draft: false,
  base: null, approvals: null, mergeState: null, mergeable: null, approvedAt: null, title: null, ...over,
});

test("each ship state has one action on ↵", () => {
  assert.deepEqual([stand(br(), undefined, undefined, NOW).ship, stand(br(), undefined, undefined, NOW).action], ["local", "open"]);
  assert.equal(stand(br({ gates: "green" }), undefined, undefined, NOW).action, "push");
  assert.equal(stand(br({ gates: "green", pushed: "synced" }), undefined, undefined, NOW).action, "pr");
  assert.equal(stand(br(), pr(), undefined, NOW).ship, "review");
  assert.equal(stand(br(), pr({ review: "APPROVED" }), undefined, NOW).ship, "approved");
  assert.equal(stand(br(), pr({ state: "MERGED" }), undefined, NOW).ship, "landed");
});

test("ready means you can act now: green with its parent on origin, pushed without a PR, approved and not waiting on a parent", () => {
  const localParent = { ship: "green" as const, name: "f/a" };
  assert.equal(stand(br({ gates: "green" }), undefined, undefined, NOW).ready, true);
  assert.equal(stand(br({ gates: "green" }), undefined, localParent, NOW).ready, false);
  assert.equal(stand(br({ gates: "green" }), undefined, { ship: "pushed", name: "f/a" }, NOW).ready, true);
  assert.equal(stand(br({ pushed: "synced" }), undefined, undefined, NOW).ready, true);
  assert.equal(stand(br(), pr(), undefined, NOW).ready, false);
  const appr = pr({ review: "APPROVED", mergeState: "CLEAN" });
  assert.equal(stand(br(), appr, undefined, NOW).ready, true);
  assert.equal(stand(br(), appr, undefined, NOW).waiting[0].kind, "merge");
  const waits = stand(br(), appr, { ship: "review", pr: pr({ number: 3 }), name: "f/a" }, NOW);
  assert.deepEqual([waits.ready, waits.waiting[0].label], [false, "parent #3 to merge"]);
  assert.equal(stand(br(), appr, { ship: "landed", name: "f/a" }, NOW).ready, true);
});

test("a hold keeps a branch out of ready until it comes due", () => {
  const held = br({ gates: "green", holdUntil: "2026-10-23T16:00:00Z" });
  assert.deepEqual([stand(held, undefined, undefined, NOW).held, stand(held, undefined, undefined, NOW).ready], [true, false]);
  const due = stand(held, undefined, undefined, Date.parse("2026-10-23T16:05:00Z"));
  assert.deepEqual([due.held, due.ready], [false, true]);
});

test("a compare link stacks on an unlanded parent, else trunk", () => {
  assert.equal(baseFor(br(), { ship: "pushed", name: "f/a" }, "main"), "f/a");
  assert.equal(baseFor(br(), { ship: "landed", name: "f/a" }, "main"), "main");
  assert.equal(baseFor(br(), undefined, "main"), "main");
});

test("a forest closes when everything in it has landed", () => {
  assert.equal(isClosed(["landed", "landed"]), true);
  assert.equal(isClosed(["landed", "approved"]), false);
  assert.equal(isClosed([]), false);
});

test("the push window speaks only near and after the cliff", () => {
  assert.equal(windowLine(NOW), "");
  assert.equal(phaseAt(Date.parse("2026-10-22T21:30:00Z")).phase, "closing"); // 14:30 PT
  assert.match(windowLine(Date.parse("2026-10-22T21:30:00Z")), /^30m to 3pm/);
  assert.match(windowLine(Date.parse("2026-10-22T23:00:00Z")), /^past 3pm .* from Fri 9am$/);
  assert.match(windowLine(Date.parse("2026-10-24T18:00:00Z")), /until Mon 9am$/);
  assert.equal(new Date(nextMorning(Date.parse("2026-10-23T23:00:00Z"))).toISOString(), "2026-10-26T16:00:00.000Z"); // Fri late → Mon 9 PT
});
