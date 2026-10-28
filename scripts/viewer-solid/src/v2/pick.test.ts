import { test } from "node:test";
import assert from "node:assert/strict";
import { ranked, score } from "./pick.ts";

test("the picker's filter: a run of the typed letters beats them scattered", () => {
  const rows = ["constructor constructor :6", "total function :20", "Circle class :12"];
  assert.deepEqual(ranked(rows, "tot", (r) => r), ["total function :20", "constructor constructor :6"]);
  assert.deepEqual(ranked(rows, "crc", (r) => r), ["Circle class :12", "constructor constructor :6"]);
  assert.equal(score("area", "zz"), null);
  assert.deepEqual(ranked(rows, "  ", (r) => r), rows);
});
