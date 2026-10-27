// A key means one thing on every page — in the defaults and with your keys.toml laid over them.
// Loads the real registry, so it checks what ships.
import { test } from "node:test";
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { registerHooks } from "node:module";

registerHooks({
  resolve(spec, ctx, next) {
    if (!spec.startsWith(".") || /\.[cm]?[jt]sx?$/.test(spec)) return next(spec, ctx);
    return next(`${spec}.ts`, ctx);
  },
});
Object.assign(globalThis, {
  location: { pathname: "/v2", search: "", hash: "", origin: "http://localhost" },
  history: { pushState() {}, replaceState() {} },
  addEventListener() {},
  localStorage: { getItem: () => null, setItem() {}, removeItem() {} },
  document: { addEventListener() {}, querySelector: () => null, documentElement: { dataset: {} } },
});
globalThis.window = globalThis as never;
const every = globalThis.setInterval;
globalThis.setInterval = ((fn: () => void, ms: number) => every(fn, ms).unref()) as never;
const { applyKeys, clashes, validKey } = await import("./bindings");

async function registry() {
  for (const m of ["app", "project", "branch", "review", "todo", "words", "machine"]) await import(`./commands/${m}`);
  const { commands } = await import("./registry");
  return commands().map((c) => ({ id: c.id, scope: c.scope, keys: c.keys && [...c.keys] }));
}

const yours = () =>
  JSON.parse(execFileSync("python3", ["-I", "-c", "import json,sys; sys.path.insert(0, \".\"); import srv.keymap as k; print(json.dumps(k.load()))"], { cwd: new URL("../../../", import.meta.url).pathname }).toString());

test("the default keys mean one thing on every page", async () => {
  assert.deepEqual(clashes(await registry()), []);
});

test("your keys.toml applies cleanly and keeps the rule", async () => {
  const cmds = await registry();
  const { keys, errors } = yours();
  assert.deepEqual([...errors, ...applyKeys(cmds, keys), ...clashes(cmds)], []);
});

test("an override that clashes, names nothing, or isn't a key is reported", () => {
  const cmds = [
    { id: "project.archive", scope: "project", keys: ["X"] },
    { id: "review.extend", scope: "line", keys: ["x"] },
  ];
  assert.deepEqual(applyKeys(cmds, { "project.archive": ["x"], "nope": ["q"], "review.extend": ["Ctrl+x"] }), [
    "nope: no such command",
    'review.extend: not a key — "Ctrl+x"',
  ]);
  assert.deepEqual(clashes(cmds), []);
  applyKeys(cmds, { "review.extend": ["x"] });
  assert.match(clashes(cmds).join(), /^x: forests → put it away, forest → put it away, review → review.extend$/);
});

test("key names are what the keyboard produces", () => {
  for (const k of ["x", "X", "?", "g d", "C-k", "A-x", "space", "esc", "ret", "tab", "down"]) assert.ok(validKey(k), k);
  for (const k of ["Ctrl+x", "", "gd", "enter", "cmd-k"]) assert.ok(!validKey(k), k);
});
