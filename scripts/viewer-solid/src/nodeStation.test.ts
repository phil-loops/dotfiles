import { test } from "node:test";
import assert from "node:assert/strict";
import { conflictWarning, nextStepOf } from "./nodeStation.ts";

test("a predicted collision names the PR it hits", () => {
  assert.equal(
    conflictWarning({ verdict: "will-conflict", conflict_pr: 9672, conflict_title: "reject whitespace-only notes" }),
    "⚠ the ambient dry-run predicts this rebase conflicts with #9672 — reject whitespace-only notes",
  );
});

test("a predicted collision with no PR still warns", () => {
  assert.equal(conflictWarning({ verdict: "will-conflict" }), "⚠ the ambient dry-run predicts this rebase conflicts");
});

// The normal case must stay silent — a button that always carries a warning teaches you to
// ignore the warning.
test("every other verdict is silence", () => {
  for (const verdict of ["clean", "would-restack", "would-contract", "skip-dirty", "error"]) {
    assert.equal(conflictWarning({ verdict }), "");
  }
});

test("absent ambient data is silence, not a crash", () => {
  assert.equal(conflictWarning(undefined), "");
  assert.equal(conflictWarning(null), "");
  assert.equal(conflictWarning({}), "");
});

test("a null conflict_pr is omitted rather than rendered", () => {
  assert.equal(
    conflictWarning({ verdict: "will-conflict", conflict_pr: null, conflict_title: null }),
    "⚠ the ambient dry-run predicts this rebase conflicts",
  );
});

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
