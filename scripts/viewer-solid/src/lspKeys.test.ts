import { test } from "node:test";
import assert from "node:assert/strict";
import { chord, sideOf, wordAt } from "./lspKeys.ts";

test("K hovers on its own; space·k and g·d are chords", () => {
  assert.deepEqual(chord("", "K"), { leader: "", action: "hover", consumed: true });
  assert.deepEqual(chord("", " "), { leader: "space", action: null, consumed: true });
  assert.deepEqual(chord("space", "k"), { leader: "", action: "hover", consumed: true });
  assert.deepEqual(chord("", "g"), { leader: "g", action: null, consumed: true });
  assert.deepEqual(chord("g", "d"), { leader: "", action: "definition", consumed: true });
});

test("a bare k or d, or a broken chord, falls through untouched", () => {
  assert.deepEqual(chord("", "k"), { leader: "", action: null, consumed: false });
  assert.deepEqual(chord("", "d"), { leader: "", action: null, consumed: false });
  assert.deepEqual(chord("g", "c"), { leader: "", action: null, consumed: false });
  assert.deepEqual(chord("space", "d"), { leader: "", action: null, consumed: false });
});

test("wordAt finds the identifier under or just behind the caret", () => {
  const line = "\treturn listWidgets().filter((w) => w.price <= max);";
  const at = line.indexOf("listWidgets");
  assert.deepEqual(wordAt(line, at + 3), { start: at, end: at + "listWidgets".length });
  assert.deepEqual(wordAt(line, at + "listWidgets".length), { start: at, end: at + "listWidgets".length });
  assert.equal(wordAt(line, line.indexOf(" <=") + 1), null);
});

test("wordAt counts UTF-16 units, as LSP positions do", () => {
  const line = 'const label = "💡 " + w.name;';
  const at = line.indexOf("name");
  assert.equal(at, 24); // the emoji is two units
  assert.deepEqual(wordAt(line, at), { start: 24, end: 28 });
});

test("sideOf: removed lines are old, kept lines on the old half point at their new twin", () => {
  assert.equal(sideOf(["d2h-del", "d2h-change"], null), "old");
  assert.equal(sideOf(["d2h-ins"], null), "new");
  assert.equal(sideOf(["d2h-cntx"], null), "new");
  assert.equal(sideOf(["d2h-cntx"], 0), "twin");
  assert.equal(sideOf(["d2h-cntx"], 1), "new");
  assert.equal(sideOf(["d2h-info"], 1), "none");
  assert.equal(sideOf(["d2h-emptyplaceholder", "d2h-code-side-emptyplaceholder"], 1), "none");
});
