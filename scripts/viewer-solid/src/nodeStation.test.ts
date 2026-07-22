import { test } from "node:test";
import assert from "node:assert/strict";
import { conflictWarning } from "./nodeStation.ts";

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
