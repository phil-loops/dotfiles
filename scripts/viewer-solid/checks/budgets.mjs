// npm run budgets [-- --base http://127.0.0.1:<port>]
//
// 1. The v2 initial bundle — every script and stylesheet dist/v2/index.html loads, transitively
//    through its imports — must stay under 250 KB gzipped (fonts are reported, not counted).
// 2. With --base (a running viewer; use viewer-sandbox, the check archives and restores a forest):
//    Forests paint and `x` feedback, measured in the page itself, against the latency budgets.
// Exits non-zero on any miss.
import { readFileSync } from "node:fs";
import { gzipSync } from "node:zlib";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";
import { createRequire } from "node:module";

const ROOT = join(dirname(fileURLToPath(import.meta.url)), "..");
const DIST = join(ROOT, "dist");
const BUNDLE_KB = 250;
const FEEDBACK_MS = 16.7; // one 60 Hz frame — the budgets.ts feedback budget
const PAINT_MS = 100;
let failed = false;
const line = (ok, what) => {
  console.log(`${ok ? "✓" : "✕"} ${what}`);
  if (!ok) failed = true;
};

// ── 1. bundle ──
const html = readFileSync(join(DIST, "v2", "index.html"), "utf8");
const seen = new Set();
const queue = [...html.matchAll(/(?:src|href)="\/(assets\/[^"]+\.(?:js|css))"/g)].map((m) => m[1]);
let total = 0;
const fonts = new Set();
while (queue.length) {
  const rel = queue.shift();
  if (seen.has(rel)) continue;
  seen.add(rel);
  const body = readFileSync(join(DIST, rel));
  total += gzipSync(body).length;
  const text = body.toString("utf8");
  for (const m of text.matchAll(/["'(/]((?:\.\/)?[\w.-]+\.(?:js|css))["')]/g)) {
    const name = m[1].replace(/^\.\//, "");
    if (/^[\w-]+-[\w-]{8}\.(js|css)$/.test(name)) queue.push(`assets/${name}`);
  }
  for (const m of text.matchAll(/([\w-]+-[\w-]{8}\.woff2)/g)) fonts.add(m[1]);
}
const fontKb = [...fonts].reduce((n, f) => n + readFileSync(join(DIST, "assets", f)).length, 0) / 1024;
line(total / 1024 <= BUNDLE_KB, `v2 initial bundle ${(total / 1024).toFixed(1)} KB gzipped (${seen.size} files) ≤ ${BUNDLE_KB} KB · fonts ${fontKb.toFixed(0)} KB, loaded on use`);

// ── 2. latency on a live server ──
const at = process.argv.indexOf("--base");
const base = at > 0 ? process.argv[at + 1] : process.env.BUDGET_BASE;
if (base) {
  const require = createRequire(import.meta.url);
  const puppeteer = require("puppeteer-core");
  const b = await puppeteer.launch({
    executablePath:
      process.env.CHROME ||
      `${process.env.HOME}/.cache/puppeteer/chrome-headless-shell/mac_arm-150.0.7871.24/chrome-headless-shell-mac-arm64/chrome-headless-shell`,
    headless: true,
  });
  const p = await b.newPage();
  await p.setViewport({ width: 1280, height: 860 });
  const errors = [];
  p.on("pageerror", (e) => errors.push(String(e)));
  const pct = (xs, q) => [...xs].sort((a, c) => a - c)[Math.min(xs.length - 1, Math.floor(q * xs.length))];
  const fmt = (xs) => `p50 ${pct(xs, 0.5).toFixed(1)} ms · p95 ${pct(xs, 0.95).toFixed(1)} ms (n=${xs.length})`;

  // entry: navigation start → [data-paint=forests]
  const entry = [];
  for (let i = 0; i < 5; i++) {
    await p.goto(`${base}/v2`);
    await p.waitForSelector('[data-paint="forests"]');
    entry.push(await p.evaluate(() => new Promise((r) => requestAnimationFrame(() => r(performance.now())))));
  }
  // in-app: `g f` from the dashboard → [data-paint=forests]
  const nav = [];
  for (let i = 0; i < 8; i++) {
    await p.goto(`${base}/v2/dashboard`);
    await p.waitForSelector('[data-paint="dashboard"]');
    nav.push(
      await p.evaluate(
        () =>
          new Promise((resolve) => {
            const key = (k) => document.dispatchEvent(new KeyboardEvent("keydown", { key: k, bubbles: true }));
            const t0 = performance.now();
            const obs = new MutationObserver(() => {
              if (!document.querySelector('[data-paint="forests"]')) return;
              obs.disconnect();
              requestAnimationFrame(() => resolve(performance.now() - t0));
            });
            obs.observe(document.body, { subtree: true, childList: true });
            key("g");
            key("f");
          }),
      ),
    );
  }
  // `x` on the selected workbench forest → its row leaves; `u` puts it back between runs
  await p.goto(`${base}/v2`);
  await p.waitForSelector('[data-paint="forests"]');
  const fb = [];
  for (let i = 0; i < 12; i++) {
    await p.evaluate(() => {
      const first = document.querySelectorAll("[data-row]")[1];
      first?.dispatchEvent(new MouseEvent("click", { bubbles: true }));
    });
    fb.push(
      await p.evaluate(
        () =>
          new Promise((resolve) => {
            const id = document.querySelector(".bg-gold-wash")?.getAttribute("data-row");
            const t0 = performance.now();
            const obs = new MutationObserver(() => {
              if (document.querySelector(`[data-row="${id}"]`)) return;
              obs.disconnect();
              requestAnimationFrame(() => resolve(performance.now() - t0));
            });
            obs.observe(document.body, { subtree: true, childList: true });
            document.dispatchEvent(new KeyboardEvent("keydown", { key: "x", bubbles: true }));
          }),
      ),
    );
    await new Promise((r) => setTimeout(r, 400));
    await p.evaluate(() => document.dispatchEvent(new KeyboardEvent("keydown", { key: "u", bubbles: true })));
    await new Promise((r) => setTimeout(r, 400));
  }
  await b.close();
  // the first load is cold (server-side snapshot, uncached assets) — p50 holds the budget, p95 is shown
  line(pct(entry, 0.5) <= PAINT_MS, `Forests entry paint (page load: html + js + /state) ${fmt(entry)}, p50 ≤ ${PAINT_MS} ms`);
  line(pct(nav, 0.95) <= PAINT_MS, `Forests navigation paint (g f) ${fmt(nav)} ≤ ${PAINT_MS} ms`);
  line(pct(fb, 0.95) <= FEEDBACK_MS, `x feedback (keydown → frame without the row) ${fmt(fb)} ≤ ${FEEDBACK_MS} ms`);
  line(!errors.length, `no page errors${errors.length ? `: ${errors.join(" | ")}` : ""}`);
}
process.exit(failed ? 1 : 0);
