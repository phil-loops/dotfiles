import { test } from "node:test";
import assert from "node:assert/strict";
import { normalizeTicket } from "./ticket.ts";

test("canonical and sloppy forms normalize to TEAM-####", () => {
  assert.equal(normalizeTicket("LOO-5271"), "LOO-5271");
  assert.equal(normalizeTicket("loo-5271"), "LOO-5271");
  assert.equal(normalizeTicket("loo5271"), "LOO-5271");
  assert.equal(normalizeTicket("  eng-42  "), "ENG-42");
});

test("bare digits assume the LOO team", () => {
  assert.equal(normalizeTicket("5271"), "LOO-5271");
});

test("blank clears", () => {
  assert.equal(normalizeTicket(""), "");
  assert.equal(normalizeTicket("   "), "");
});

test("junk is invalid, not silently saved", () => {
  assert.equal(normalizeTicket("LOO-"), null);
  assert.equal(normalizeTicket("x 123"), null);
  assert.equal(normalizeTicket("12a"), null);
  assert.equal(normalizeTicket("loo-12b"), null);
  assert.equal(normalizeTicket("-42"), null);
});
