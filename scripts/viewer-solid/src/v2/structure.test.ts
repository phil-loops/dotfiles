// The instrumentation rules, enforced: telemetry comes only from the three choke points (the
// runner, the router, sync), the network only through sync (and the telemetry sink), and every
// clickable thing dispatches a registered command — so a new feature is measured by construction.
//
// Limits (it's a source scan, not a type-aware analysis): an aliased call (`const f = fetch`,
// `window["fetch"]`) or a handler built by some helper other than bind() slips past; a command id
// built at runtime is only checked against the registry's id patterns; keyboard handlers inside a
// component (the menu's input) aren't checked — they must call the runner's dispatch by review.
import { test } from "node:test";
import assert from "node:assert/strict";
import { readdirSync, readFileSync, statSync } from "node:fs";
import { join, relative } from "node:path";

const ROOT = new URL(".", import.meta.url).pathname;
const files = (dir: string): string[] =>
  readdirSync(dir).flatMap((n) => {
    const p = join(dir, n);
    return statSync(p).isDirectory() ? files(p) : /\.tsx?$/.test(n) && !n.endsWith(".test.ts") ? [p] : [];
  });
const SRC = files(ROOT).map((p) => ({ name: relative(ROOT, p), text: readFileSync(p, "utf8").replace(/^\s*\/\/.*$/gm, "") }));

const NETWORK = new Set(["sync.ts", "telemetry.ts"]);
const CHOKE = new Set(["runner.ts", "router.ts", "sync.ts", "telemetry.ts"]);

test("only sync (and the telemetry sink) touch the network", () => {
  for (const f of SRC) {
    if (NETWORK.has(f.name)) continue;
    assert.ok(!/\bfetch\s*\(|sendBeacon\s*\(|new\s+EventSource\s*\(|XMLHttpRequest/.test(f.text), `${f.name} talks to the server — go through sync.ts`);
  }
});

test("only the runner, the router and sync emit telemetry", () => {
  for (const f of SRC) {
    if (CHOKE.has(f.name)) continue;
    assert.ok(!/\b(emit|track|count|nextPaint|contentPaint)\s*\(/.test(f.text), `${f.name} records telemetry itself — the runner, router and sync do that`);
    const imports = [...f.text.matchAll(/import\s*\{([^}]*)\}\s*from\s*["']\.\.?\/telemetry["']/g)].flatMap((m) => m[1].split(",").map((s) => s.trim()));
    const allowed = f.name === "main.tsx" ? ["installPageTelemetry"] : [];
    for (const name of imports) assert.ok(allowed.includes(name), `${f.name} imports ${name} from telemetry`);
  }
});

// command ids as the registry declares them: literals, or `prefix.${…}` templates → patterns
const ID_PATTERNS = SRC.flatMap((f) =>
  [...f.text.matchAll(/command\(\{\s*id:\s*(["'`])(.*?)\1/gs)].map((m) => new RegExp("^" + m[2].replace(/[.]/g, "\\.").replace(/\$\{[^}]*\}/g, ".+") + "$")),
);

test("every clickable element dispatches a registered command", () => {
  assert.ok(ID_PATTERNS.length > 5, "found the registry");
  for (const f of SRC.filter((f) => f.name.endsWith(".tsx"))) {
    for (const m of f.text.matchAll(/\bon(Click|DblClick|PointerDown|PointerUp|MouseDown|MouseUp|ContextMenu)=\{([^}]*)/g)) {
      assert.ok(/^bind\(/.test(m[2].trim()), `${f.name}: on${m[1]} must be bind("<command>", …), got ${m[2].slice(0, 40)}`);
    }
  }
  for (const f of SRC) {
    for (const m of f.text.matchAll(/\b(bind|dispatch)\(\s*["']([^"']+)["']/g)) {
      assert.ok(ID_PATTERNS.some((re) => re.test(m[2])), `${f.name}: ${m[1]}("${m[2]}") names no registered command`);
    }
  }
});
