import { test } from "node:test";
import assert from "node:assert/strict";
import { contractNodes, headsOf, upstreamOf, downstreamOf, computeDams, indexById } from "./forestGraph.ts";
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

test("contractNodes: a dropped node's children inherit its parent", () => {
  const out = contractNodes(forest(), new Set(["mid"]));
  assert.deepEqual(out.map((n) => n.id), ["base", "tip", "side", "fan"]);
  assert.equal(out.find((n) => n.id === "tip")!.parent, "base");
});

test("contractNodes: a requires edge naming a dropped node is severed, not dangled", () => {
  const out = contractNodes(forest(), new Set(["mid"]));
  assert.deepEqual(out.find((n) => n.id === "fan")!.requires, []);
});

test("contractNodes: a whole dropped chain reparents to the nearest survivor", () => {
  const out = contractNodes(forest(), new Set(["base", "mid"]));
  assert.equal(out.find((n) => n.id === "tip")!.parent, undefined);
});

// The map asks `depth === 0` for "is this a root" (the main-hover spotlight). Dropping a merged
// base — the auto-contract case — promotes its children, so their depth has to come down with it.
test("contractNodes: children promoted to roots re-read as depth 0", () => {
  const seeded = forest().map((n) => ({ ...n, depth: n.parent ? 1 : 0 }));
  const out = contractNodes(seeded, new Set(["base"]));
  assert.equal(out.find((n) => n.id === "mid")!.depth, 0);
  assert.equal(out.find((n) => n.id === "tip")!.depth, 1);
});

test("contractNodes: a parent cycle terminates instead of hanging the map", () => {
  const cyclic = [node("a", "b"), node("b", "a"), node("c", "a")];
  assert.doesNotThrow(() => contractNodes(cyclic, new Set(["a"])));
});

test("contractNodes: an empty drop set returns the list untouched", () => {
  const list = forest();
  assert.equal(contractNodes(list, new Set()), list);
});

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
