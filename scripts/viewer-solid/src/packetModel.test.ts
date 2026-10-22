import { test } from "node:test";
import assert from "node:assert/strict";
import { claimHint, findingsByClaim, handJson, normalizeHand, sameHand, staleLabel, verdictLabel, EMPTY_HAND } from "./packetModel.ts";

test("claimHint passes a checkable claim and flags activity verbs", () => {
  assert.equal(claimHint("Clicking a property cell opens the row's contact."), null);
  assert.match(claimHint("Improves the table code.")!, /Improves/);
  assert.match(claimHint("Cleans up the widget model.")!, /Cleans up/);
  assert.match(claimHint("Refactor things")!, /checkable|too short/);
  assert.match(claimHint("Fixes it")!, /too short/);
  assert.equal(claimHint("   "), null);
});

test("handJson keeps only what was written by hand", () => {
  assert.equal(handJson(EMPTY_HAND), "");
  assert.equal(handJson({ ...EMPTY_HAND, intent: ["  a  claim ", ""] }), '{"intent":["a claim"]}');
  assert.equal(handJson({ ...EMPTY_HAND, intent: [] }), '{"intent":[]}');
  assert.equal(handJson({ lead: " hi ", intent: null, not: ["x"], read: null }), '{"lead":"hi","not":["x"]}');
});

test("sameHand ignores blank lines and spacing", () => {
  assert.ok(sameHand({ ...EMPTY_HAND, not: ["a", " "] }, { ...EMPTY_HAND, not: ["a"] }));
  assert.ok(!sameHand({ ...EMPTY_HAND, intent: [] }, EMPTY_HAND));
  assert.deepEqual(normalizeHand({ lead: "", intent: ["a  b"], not: [], read: null }).intent, ["a b"]);
});

test("staleLabel names what moved", () => {
  assert.equal(staleLabel({ mergedSince: [43], openedSince: [] }), "#43 merged since");
  assert.equal(staleLabel({ mergedSince: [43, 44], openedSince: [45] }), "#43, #44 merged since · #45 opened since");
});

test("findingsByClaim groups under claims, unplaced last", () => {
  const f = (claim: number | null) => ({ path: "a.ts", line: 1, url: "", body: "x", claim, outdated: false });
  const g = findingsByClaim({ claims: ["one", "two"], findings: [f(1), f(null), f(1), f(7)] });
  assert.deepEqual(g.map((x) => [x.claim, x.findings.length]), [[1, 2], [null, 2]]);
});

test("verdictLabel: findings, held, or silent", () => {
  assert.equal(verdictLabel(null), "");
  assert.equal(verdictLabel({ findings: [], botRan: true, packet: true }), "claims held");
  assert.equal(verdictLabel({ findings: [], botRan: true, packet: false }), "");
  assert.equal(verdictLabel({ findings: [{ path: "", line: null, url: "", body: "", claim: null, outdated: false }], botRan: true, packet: true }), "1 finding");
});
