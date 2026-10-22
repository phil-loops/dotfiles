import { test } from "node:test";
import assert from "node:assert/strict";
import { createKeymap, keyName } from "./keys.ts";

const km = () =>
  createKeymap([
    { id: "menu", keys: ["space"], scope: "global" },
    { id: "def", keys: ["g d"], scope: "global" },
    { id: "forests", keys: ["g f"], scope: "global" },
    { id: "archive", keys: ["x"], scope: "project" },
    { id: "close", keys: ["x"], scope: "global" },
  ]);

test("key names follow Helix", () => {
  assert.equal(keyName({ key: " " }), "space");
  assert.equal(keyName({ key: "Escape" }), "esc");
  assert.equal(keyName({ key: "G" }), "G");
  assert.equal(keyName({ key: "k", ctrlKey: true }), "C-k");
  assert.equal(keyName({ key: "k", metaKey: true }), null);
  assert.equal(keyName({ key: "Shift" }), null);
});

test("chords wait for their second key", () => {
  const k = km();
  assert.deepEqual(k.feed("g", ["global"]), { kind: "pending", prefix: "g" });
  assert.deepEqual(k.feed("d", ["global"]), { kind: "run", id: "def" });
  assert.deepEqual(k.feed("g", ["global"]), { kind: "pending", prefix: "g" });
  assert.deepEqual(k.feed("q", ["global"]), { kind: "none" });
  assert.deepEqual(k.feed("space", ["global"]), { kind: "run", id: "menu" });
});

test("the narrowest active scope wins a shared key", () => {
  assert.deepEqual(km().feed("x", ["project", "global"]), { kind: "run", id: "archive" });
  assert.deepEqual(km().feed("x", ["global"]), { kind: "run", id: "close" });
});
