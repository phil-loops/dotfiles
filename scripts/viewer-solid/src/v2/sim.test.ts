import { test } from "node:test";
import assert from "node:assert/strict";
import { createSim, type Divergence } from "./sim.ts";
import { scenario, scenarios } from "./simScenarios.ts";

const run = (id: string, kernels = {}) => createSim(scenario(id), kernels).runToEnd();
const kinds = (d: Divergence[]) => d.map((x) => `${x.event}:${x.kind}`).sort();

test("every scenario with a kernel stays green with it and goes red without it", () => {
  for (const s of scenarios.filter((x) => x.kernel)) {
    assert.equal(run(s.id).outcome, "green", `${s.id} with every kernel`);
    assert.equal(run(s.id, { [s.kernel!]: false }).outcome, "red", `${s.id} without ${s.kernel}`);
  }
});

test("a crash between counts and bookmark double-counts the page only when they commit apart", () => {
  assert.deepEqual(kinds(run("crash-before-bookmark", { atomicCommit: false }).divergence), ["e1:double", "e2:double", "e3:double"]);
  const r = run("crash-before-bookmark");
  assert.equal(r.actual, 3);
  assert.equal(r.truth, 3);
});

test("without the lag a slow insert is skipped forever, with no error", () => {
  assert.deepEqual(kinds(run("slow-insert", { safetyLag: false }).divergence), ["e2:skipped"]);
});

test("the advisory lock turns the second projector away", () => {
  assert.equal(run("two-projectors").busy, 1);
  assert.deepEqual(kinds(run("two-projectors", { lock: false }).divergence), ["e1:double", "e2:double"]);
});

test("a lost lease costs nothing while the lock holds, and double-counts without it", () => {
  const r = run("lease-lost");
  assert.equal(r.outcome, "green");
  assert.equal(r.busy, 1);
  assert.deepEqual(kinds(run("lease-lost", { lock: false }).divergence), ["e1:double", "e2:double"]);
});

test("regrouping with group-owned bookmarks skips what landed before the new bookmarks' start", () => {
  assert.deepEqual(kinds(run("regroup", { shardBookmarks: false }).divergence), ["e5:skipped", "e6:skipped", "e7:skipped", "e8:skipped"]);
  assert.equal(run("regroup").actual, 8);
});

test("an unfenced old writer counts alongside the shards", () => {
  assert.deepEqual(kinds(run("handoff-live-writer", { fence: false }).divergence), ["e3:double", "e4:double"]);
  const sim = createSim(scenario("handoff-live-writer"));
  sim.runToEnd();
  assert.match(sim.state().log.join("\n"), /activation is busy: g holds global/);
});

test("a cutoff behind the old writer recounts what it already counted", () => {
  assert.deepEqual(kinds(run("handoff-cutoff", { cutoffCheck: false }).divergence), ["e1:double", "e2:double"]);
});

test("the handoff skips the event between the old writer's last page and the cutoff even with every kernel on", () => {
  assert.deepEqual(kinds(run("handoff-gap").divergence), ["e2:skipped"]);
});

test("a removed reader's leftover bookmark pins retention", () => {
  assert.deepEqual(kinds(run("dropped-reader", { retireBookmark: false }).divergence), ["e2:pinned", "e3:pinned"]);
  const sim = createSim(scenario("dropped-reader"));
  sim.runToEnd();
  assert.deepEqual(sim.state().events.filter((e) => e.retained).map((e) => e.id), ["e4"]);
});

test("toReveal freezes the setup and the rest plays from there", () => {
  const sim = createSim(scenario("crash-before-bookmark"));
  const frozen = sim.toReveal();
  assert.deepEqual(frozen.workers.map((w) => `${w.id}:${w.status}`), ["w1:crashed"]);
  assert.equal(frozen.log.length, 7);
  assert.equal(sim.done(), false);
  assert.equal(sim.runToEnd().outcome, "green");
});

test("a run is deterministic and its state is a copy", () => {
  const a = createSim(scenario("regroup"));
  const b = createSim(scenario("regroup"));
  assert.deepEqual(a.runToEnd(), b.runToEnd());
  a.state().events[0].applied.metrics = 99;
  assert.equal(a.state().events[0].applied.metrics, 1);
});

test("revealAt sits inside every script", () => {
  for (const s of scenarios) assert.ok(s.revealAt > 0 && s.revealAt < s.steps.length, s.id);
});
