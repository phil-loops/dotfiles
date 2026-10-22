import { test } from "node:test";
import assert from "node:assert/strict";
import { headsOf, upstreamOf, downstreamOf, computeDams, indexById } from "./forestGraph.ts";
import type { SpineNode } from "./types.ts";

// A forest is a shape, so the fixtures are shapes: node(id, parent, requires) and let the
// helpers fill the counters nothing here reads.
const node = (id: string, parent?: string, requires?: string[], extra: Partial<SpineNode> = {}): SpineNode =>
  ({ id, depth: 0, stale: 0, total: 0, clean: 0, ...(parent ? { parent } : {}), ...(requires ? { requires } : {}), ...extra }) as SpineNode;

// base ← mid ← tip, plus side, and fan which requires both mid and side.
const forest = (): SpineNode[] => [
  node("base"),
  node("mid", "base"),
  node("tip", "mid"),
  node("side"),
  node("fan", "side", ["mid"]),
];

test("headsOf: only branches nothing builds on are tips", () => {
  assert.deepEqual([...headsOf(forest())].sort(), ["fan", "tip"]);
});

test("headsOf: the ghost endstate is a destination, not a tip", () => {
  const withGhost = [...forest(), node("✦ project", "tip")];
  assert.equal(headsOf(withGhost).has("✦ project"), false);
});

test("upstreamOf: closes over the parent chain AND transitive requires", () => {
  const { byId } = indexById(forest());
  assert.deepEqual([...upstreamOf(byId, "fan")].sort(), ["base", "mid", "side"]);
});

test("upstreamOf: a parent outside the forest is not invented", () => {
  const { byId } = indexById([node("solo", "main")]);
  assert.deepEqual([...upstreamOf(byId, "solo")], []);
});

test("downstreamOf: dependents by parent and by requires, excluding self", () => {
  assert.deepEqual([...downstreamOf(forest(), "mid")].sort(), ["fan", "tip"]);
});

test("computeDams: dirt colliding with a downstream diff dams the subtree", () => {
  const list = [
    node("base", undefined, undefined, { dirty: ["src/a.ts"] }),
    node("mid", "base", undefined, { files: [{ path: "src/a.ts", status: "M" }] as SpineNode["files"] }),
    node("tip", "mid"),
  ];
  const { damSet, conflictSet, frozen } = computeDams(list, indexById(list).byId);
  assert.deepEqual([...damSet], ["base"]);
  assert.deepEqual([...conflictSet], ["mid"]);
  assert.deepEqual([...frozen].sort(), ["mid", "tip"]);
});

test("computeDams: dirt that collides with nothing downstream is not a dam", () => {
  const list = [
    node("base", undefined, undefined, { dirty: ["src/only-here.ts"] }),
    node("mid", "base", undefined, { files: [{ path: "src/other.ts", status: "M" }] as SpineNode["files"] }),
  ];
  assert.equal(computeDams(list, indexById(list).byId).damSet.size, 0);
});
