import { test } from "node:test";
import assert from "node:assert/strict";
import { computeForestLayout, NODE_H } from "./forestLayout.ts";
import { indexById } from "./forestGraph.ts";
import type { SpineNode } from "./types.ts";

// Same shape-fixtures as forestGraph.test.ts: node(id, parent, requires), counters zeroed.
const node = (id: string, parent?: string, requires?: string[], extra: Partial<SpineNode> = {}): SpineNode =>
  ({ id, depth: 0, stale: 0, total: 0, clean: 0, ...(parent ? { parent } : {}), ...(requires ? { requires } : {}), ...extra }) as SpineNode;

// base ← mid, side ← fan(requires mid) ← leaf, plus the ✦ sink assembling the tips.
const forest = (): SpineNode[] => [
  node("base"),
  node("mid", "base"),
  node("side"),
  node("fan", "side", ["mid"]),
  node("leaf", "fan"),
  node("✦ project", "main", ["mid", "leaf"]),
];

const layoutOf = () => computeForestLayout(indexById(forest()));

test("fan-in indent clears every carried base, not just the parent chain", () => {
  const { pos } = layoutOf();
  const unit = pos["mid"].x - pos["base"].x;
  // parent (side) alone would put fan one unit in; carrying mid (itself one unit deep)
  // pushes it to two — indentation reads "lands after everything left of me".
  assert.equal(pos["fan"].x, pos["base"].x + 2 * unit);
  assert.equal(pos["leaf"].x, pos["fan"].x + unit, "a deepened node's subtree stays right of it");
});

test("a prerequisite's row sits above its dependent's", () => {
  const { pos } = layoutOf();
  assert.ok(pos["mid"].y < pos["fan"].y);
});

test("the ✦ sink seats last, back on main's column, below every work row", () => {
  const { pos, mainPos, list } = layoutOf();
  const ghost = pos["✦ project"];
  for (const n of list) {
    if (n.id === "✦ project") continue;
    assert.ok(ghost.y > pos[n.id].y, `${n.id} must sit above the sink`);
    assert.ok(ghost.x < pos[n.id].x, `${n.id} must sit right of the sink's column`);
  }
  assert.ok(ghost.x < mainPos.x, "the spine drop (mainPos.x) enters inside the sink's row");
});

test("the sink draws spine + lands edges, never a tree elbow or fan-in", () => {
  const { edges } = layoutOf();
  const inbound = edges.filter((e) => e.to === "✦ project");
  assert.deepEqual(inbound.map((e) => e.kind).sort(), ["lands", "lands", "spine"]);
  const spine = inbound.find((e) => e.kind === "spine")!;
  assert.equal(spine.from, "main");
  assert.equal(spine.x1, spine.x2, "the spine is main's column continuing straight down");
  assert.ok(spine.y2 < layoutOf().pos["✦ project"].y - NODE_H / 2 + 1);
  assert.deepEqual(inbound.filter((e) => e.kind === "lands").map((e) => e.from).sort(), ["leaf", "mid"]);
});

test("a real branch's requires still draws merge-blocking fan-in, not lands", () => {
  const { edges } = layoutOf();
  const fanins = edges.filter((e) => e.kind === "fanin");
  assert.deepEqual(fanins.map((e) => `${e.from}→${e.to}`), ["mid→fan"]);
});

test("no ghost, no sink machinery: a plain forest emits only tree + fanin edges", () => {
  const plain = forest().filter((n) => n.id !== "✦ project");
  const { edges } = computeForestLayout(indexById(plain));
  assert.equal(edges.some((e) => e.kind === "spine" || e.kind === "lands"), false);
});
