import { test } from "node:test";
import assert from "node:assert/strict";
import { gateRows } from "./gates.ts";

const plan = { event: "plan", gates: ["env", "typecheck", "tests"] };

test("a run in flight: done, running with its time, queued", () => {
  const rows = gateRows({ running: true, events: [plan, { event: "done", gate: "env", ok: true, ms: 900 }, { event: "start", gate: "typecheck", ts: 100 }] }, 130);
  assert.deepEqual(rows.map((r) => `${r.name}:${r.state}:${r.ms}`), ["env:green:900", "typecheck:running:30000", "tests:queued:null"]);
});

test("a run that died mid-gate says stopped, not running", () => {
  const rows = gateRows({ running: false, dead: true, events: [plan, { event: "start", gate: "env", ts: 1 }] }, 500);
  assert.deepEqual(rows.map((r) => r.state), ["stopped", "stopped", "stopped"]);
});

test("a finished run carries each gate's summary", () => {
  const rows = gateRows({ running: false, events: [plan, { event: "done", gate: "env", ok: true, ms: 5 }, { event: "done", gate: "typecheck", ok: false, ms: 6 }, { event: "done", gate: "tests", ok: true, ms: 7 },
    { event: "result", ok: false, gates: [{ name: "typecheck", ok: false, ms: 6, summary: "3 errors" }] }] }, 0);
  assert.deepEqual(rows.map((r) => `${r.name}:${r.state}`), ["env:green", "typecheck:red", "tests:green"]);
  assert.equal(rows[1].summary, "3 errors");
});

test("a waived gate reads as waived with its reason, not as a pass", () => {
  const rows = gateRows({ running: false, events: [{ event: "plan", gates: ["tests"] }, { event: "done", gate: "tests", ok: true, ms: 0, warn: "tests skipped by you" }] }, 0);
  assert.deepEqual(rows, [{ name: "tests", state: "waived", ms: 0, summary: "tests skipped by you" }]);
});
