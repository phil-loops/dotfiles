import { test } from "node:test";
import assert from "node:assert/strict";
import { contractionDone } from "./contractResult.ts";

test("a 200 with ok is done", () => {
  assert.equal(contractionDone({ status: 200, ok: true }), true);
});

test("the handler's own 404 is done — that IS contraction's outcome", () => {
  assert.equal(contractionDone({ status: 404, ok: false }), true);
});

// The regression this module exists for: the server answers an unrouted path with 404 + `{}`,
// which carries no `ok`. Read as success it drops a node that never moved.
test("an unrouted 404 (bare {}) is NOT done", () => {
  assert.equal(contractionDone({ status: 404 }), false);
});

test("a refusal parks: 409 unmerged work, 500", () => {
  assert.equal(contractionDone({ status: 409, ok: false }), false);
  assert.equal(contractionDone({ status: 500, ok: false }), false);
});

// /contract does send ok:true on success; this pins that a missing `ok` still isn't a refusal,
// so a future handler that drops the field can't turn every drop into "⊘ drop failed".
test("a 200 without an explicit ok is done", () => {
  assert.equal(contractionDone({ status: 200 }), true);
});
