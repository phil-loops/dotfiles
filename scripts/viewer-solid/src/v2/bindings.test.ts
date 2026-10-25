// A key means one thing everywhere: the same key on two pages runs the same command — or a
// command listed below as the same move. Loads the real registry, so it checks what ships.
import { test } from "node:test";
import assert from "node:assert/strict";
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

// Keys whose move is the same on every page, each page doing it to its own things.
const SAME_MOVE: Record<string, string[]> = {
  "next": ["cursor.down", "review.down"],
  "previous": ["cursor.up", "review.up"],
  "back out": ["overlay.close", "review.back"],
  "out": ["forest.collapse", "review.leave"],
  "the thing's main action": ["row.primary", "review.fold"],
  "send to GitHub": ["branch.push", "review.send"],
};

test("a key means one thing on every page", async () => {
  for (const m of ["app", "project", "branch", "review"]) await import(`./commands/${m}`);
  const { commands } = await import("./registry");
  const { SURFACE_SCOPES } = await import("./sheet");
  const surfaces = Object.entries(SURFACE_SCOPES as Record<string, string[]>);
  const move = (id: string) => Object.keys(SAME_MOVE).find((k) => SAME_MOVE[k].includes(id)) ?? id;

  const byKey = new Map<string, Map<string, Set<string>>>();
  for (const c of commands()) {
    for (const key of c.keys ?? []) {
      const pages = c.scope === "global" ? surfaces.map(([s]) => s) : surfaces.filter(([, scopes]) => scopes.includes(c.scope)).map(([s]) => s);
      assert.ok(pages.length, `${c.id}: scope ${c.scope} is on no page — add it to SURFACE_SCOPES`);
      const at = byKey.get(key) ?? new Map<string, Set<string>>();
      for (const p of pages) at.set(p, (at.get(p) ?? new Set()).add(c.id));
      byKey.set(key, at);
    }
  }

  const clashes: string[] = [];
  for (const [key, at] of byKey) {
    // On one page a key may run several commands — the narrowest live scope picks — so a page's
    // meaning is what its own commands do, and the global one only where it has none.
    const meaning = new Map<string, string>();
    for (const [page, ids] of at) {
      const own = [...ids].filter((id) => commands().find((c) => c.id === id)!.scope !== "global");
      meaning.set(page, [...new Set((own.length ? own : [...ids]).map(move))].sort().join(" | "));
    }
    const distinct = new Set(meaning.values());
    if (distinct.size > 1) clashes.push(`${key}: ${[...meaning].map(([p, m]) => `${p} → ${m}`).join(", ")}`);
  }
  assert.deepEqual(clashes, [], `keys that mean different things on different pages:\n  ${clashes.join("\n  ")}`);
});
