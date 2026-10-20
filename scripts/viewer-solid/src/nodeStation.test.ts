import { test } from "node:test";
import assert from "node:assert/strict";
import { nextStepOf } from "./nodeStation.ts";

// A node whose parent landed is stranded on a base that is about to vanish. The contraction
// belongs to the parent, but it is this node's next step — so the slot has to offer it here.
test("a landed parent offers the drop from the child's own slot", () => {
  const step = nextStepOf({ parentGhost: "api-key-creator/list-keys-with-creator", prepRoute: "nothing" });
  assert.equal(step?.kind, "contract-parent");
  assert.equal(step?.label, "drop parent ghost & rewire →");
  assert.match(step!.title, /list-keys-with-creator already merged/);
});

test("the node's own contraction still wins over its parent's", () => {
  const step = nextStepOf({ merged: true, contractable: true, parentGhost: "some/parent" });
  assert.equal(step?.kind, "contract");
  assert.equal(step?.label, "drop ghost & rewire →");
});

test("a merged-but-not-droppable node rebases forward rather than offering a dead drop", () => {
  const step = nextStepOf({ merged: true, contractable: false });
  assert.equal(step?.kind, "prep");
  assert.equal(step?.label, "↑ rebase forward →");
});

test("a parent that landed but is not yet droppable is not offered", () => {
  assert.equal(nextStepOf({ parentGhost: null, prepRoute: "nothing" }), null);
});

test("a branch at rest with a healthy parent renders no slot", () => {
  assert.equal(nextStepOf({ prepRoute: "nothing" }), null);
});
