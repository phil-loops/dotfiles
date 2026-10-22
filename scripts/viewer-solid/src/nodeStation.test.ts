import { test } from "node:test";
import assert from "node:assert/strict";
import { nextStepOf } from "./nodeStation.ts";

test("a landed, droppable node is at rest — the restack walk drops it", () => {
  assert.equal(nextStepOf({ merged: true, contractable: true, prepRoute: "nothing" }), null);
});

test("a merged-but-not-droppable node rebases forward rather than offering a dead drop", () => {
  const step = nextStepOf({ merged: true, contractable: false });
  assert.equal(step?.kind, "prep");
  assert.equal(step?.label, "↑ rebase forward →");
});

test("a branch at rest with a healthy parent renders no slot", () => {
  assert.equal(nextStepOf({ prepRoute: "nothing" }), null);
});

test("a branch behind main offers sync", () => {
  const step = nextStepOf({ behind: 2, syncable: true, prepRoute: "nothing" });
  assert.equal(step?.label, "⟲ sync");
  assert.match(step!.title, /rebase forward \(2 behind\)/);
});
