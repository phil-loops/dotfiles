import { test } from "node:test";
import assert from "node:assert/strict";
import { nearestInDirection } from "./spatialNav.ts";

// one row per branch, 74 apart; chains stack in a column, branch points indent 46
const pts = {
  root: { x: 96, y: 64 },
  chain: { x: 96, y: 138 },
  kid: { x: 142, y: 212 },
  side: { x: 96, y: 286 },
};

test("down takes the next row even when it is indented", () => {
  assert.equal(nearestInDirection(pts, "chain", "down"), "kid");
  assert.equal(nearestInDirection(pts, "root", "down"), "chain");
});

test("up and down walk back the way they came", () => {
  assert.equal(nearestInDirection(pts, "kid", "up"), "chain");
  assert.equal(nearestInDirection(pts, "side", "up"), "kid");
});

test("left/right only move to nodes on that side", () => {
  assert.equal(nearestInDirection(pts, "chain", "right"), "kid");
  assert.equal(nearestInDirection(pts, "kid", "left"), "chain");
  assert.equal(nearestInDirection(pts, "root", "left"), null);
});

test("an edge of the map or an unknown node goes nowhere", () => {
  assert.equal(nearestInDirection(pts, "side", "down"), null);
  assert.equal(nearestInDirection(pts, "nope", "down"), null);
});
