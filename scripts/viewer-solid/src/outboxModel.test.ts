import { test } from "node:test";
import assert from "node:assert/strict";
import { pushWindow, nextMorning, ptParts, laneItems, launchSteps, type OutboxData, type OutboxNode, type OutboxForest } from "./outboxModel.ts";

const W = { cliffHourPT: 15, slowH: 18.8, fastH: 3.2, serialForestH: 164, morningHourPT: 9 };

test("the window is open before 14:00 PT, closing in the last hour, late from 15:00", () => {
  assert.equal(pushWindow(Date.parse("2026-10-21T10:30:00-07:00"), W).phase, "open");
  const closing = pushWindow(Date.parse("2026-10-21T14:20:00-07:00"), W);
  assert.equal(closing.phase, "closing");
  assert.equal(closing.minutesToCliff, 40);
  assert.equal(pushWindow(Date.parse("2026-10-21T15:00:00-07:00"), W).phase, "late");
  assert.equal(pushWindow(Date.parse("2026-10-24T11:00:00-07:00"), W).phase, "weekend");
});

test("hold for morning lands on the next weekday 9:00 PT", () => {
  const wedEvening = Date.parse("2026-10-21T16:10:00-07:00");
  assert.equal(new Date(nextMorning(wedEvening, 9)).toISOString(), "2026-10-22T16:00:00.000Z");
  const friEvening = Date.parse("2026-10-23T17:00:00-07:00");
  const p = ptParts(nextMorning(friEvening, 9));
  assert.deepEqual([p.weekday, p.hour], [1, 9]);
  const earlyThu = Date.parse("2026-10-22T07:00:00-07:00");
  assert.equal(new Date(nextMorning(earlyThu, 9)).toISOString(), "2026-10-22T16:00:00.000Z");
});

const node = (branch: string, extra: Partial<OutboxNode> = {}): OutboxNode => ({
  branch, leaf: branch, position: 1, rank: 1, parent: "main", base: "main", stackedOn: null, description: "",
  title: branch, titleSource: "commit", subjects: [branch], commits: 1, pushed: "local", ahead: 0, gates: "green",
  redGates: [], pr: null, status: "ready", holdUntil: "", ...extra,
});
const forest = (project: string, nodes: OutboxNode[]): OutboxForest => ({
  repo: "loops", project, ticket: "", summary: "ready", size: nodes.length, unopened: 0, focus: null, nodes,
});
const data = (forests: OutboxForest[]): OutboxData => ({ forests, window: W, prSource: "fixture", generatedAt: "", ms: 0 });

test("two unopened nodes make a launch card; PR'd nodes still sit in their own lanes", () => {
  const pr = { number: 9, url: "u", state: "OPEN" as const, review: "APPROVED" };
  const items = laneItems(data([
    forest("f", [node("a"), node("b", { status: "work", gates: "red" }), node("c", { status: "approved", pr })]),
    forest("solo", [node("s")]),
  ]));
  assert.deepEqual(items.map((i) => [i.lane, i.kind === "forest" ? i.forest.project : i.node.branch]),
    [["ready", "s"], ["launch", "f"], ["approved", "c"]]);
});

test("a held node leads the outbox; a fully held forest's launch card goes with it", () => {
  const items = laneItems(data([
    forest("f", [node("a", { holdUntil: "x" }), node("b", { holdUntil: "x" })]),
    forest("solo", [node("s", { holdUntil: "x" })]),
    forest("z", [node("r")]),
  ]));
  assert.deepEqual(items.map((i) => i.lane), ["first", "first", "ready"]);
});

test("launch steps: push waits on the parent, open waits on the push", () => {
  const parent = node("p");
  assert.deepEqual(launchSteps(node("c"), parent), { push: "waiting", open: "waiting" });
  assert.deepEqual(launchSteps(node("c"), { ...parent, pushed: "synced" }), { push: "now", open: "waiting" });
  assert.deepEqual(launchSteps(node("c", { pushed: "synced" }), parent), { push: "done", open: "now" });
  assert.deepEqual(launchSteps(node("c", { gates: "red" }), undefined), { push: "blocked", open: "waiting" });
});
