// npm run budgets [-- --base http://127.0.0.1:<port>]
//
// 1. The v2 initial bundle — every script and stylesheet dist/v2/index.html loads, transitively
//    through its imports — must stay under 250 KB gzipped (fonts are reported, not counted).
// 2. With --base (a running viewer; use viewer-sandbox — the check archives, reorders and holds
//    forests and undoes each): Forests paint and every local key's feedback, measured in the page
//    itself, and each config write's feedback and settle time as the app's own `cmd` events report
//    them (read off its /track batches), against the latency budgets. On a `--github` sandbox the
//    review page too: entry and in-app paint, every review key, and its draft / viewed writes.
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
const SETTLED_MS = { "config-write": 300, "git-write": 3000 }; // budgets.ts settledMs for the classes this check exercises
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
  await p.setExtraHTTPHeaders({ "X-Stack-Actor": "headless" });
  await p.setViewport({ width: 1280, height: 860 });
  const cmds = [];
  p.on("request", (r) => {
    if (!r.url().endsWith("/track") || r.method() !== "POST") return;
    try {
      const body = JSON.parse(r.postData() || "{}");
      for (const e of body.events ?? [body]) if (e.type === "cmd") cmds.push(e);
    } catch {}
  });
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
  // every local key on Forests: keydown → the frame that paints its change
  const press = (k, mods = {}) =>
    p.evaluate(
      (k, mods) =>
        new Promise((resolve) => {
          const t0 = performance.now();
          const obs = new MutationObserver(() => {
            obs.disconnect();
            requestAnimationFrame(() => resolve(performance.now() - t0));
          });
          obs.observe(document.body, { subtree: true, childList: true, attributes: true, characterData: true });
          document.dispatchEvent(new KeyboardEvent("keydown", { key: k, bubbles: true, ...mods }));
          setTimeout(() => (obs.disconnect(), resolve(null)), 1000);
        }),
      k,
      mods,
    );
  await p.goto(`${base}/v2`);
  await p.waitForSelector('[data-paint="forests"]');
  const local = {};
  const LOCAL = [["j"], ["l"], ["j"], ["k"], ["h"], ["r"], ["r"], ["a"], ["a"], ["?"], ["Escape"], [" "]];
  for (let round = 0; round < 6; round++) {
    for (const [k, mods] of LOCAL) {
      const ms = await press(k, mods);
      if (k === " ") await p.keyboard.press("Escape");
      if (ms != null) (local[k] ??= []).push(ms);
      await new Promise((r) => setTimeout(r, 60));
    }
  }
  // config writes beyond x: reorder the focus lane, hold a forest — each undone
  const sel = (n) => p.evaluate((n) => document.querySelectorAll('[data-row^="p:"]')[n]?.dispatchEvent(new MouseEvent("click", { bubbles: true })), n);
  for (let i = 0; i < 6; i++) {
    await sel(0);
    await press("j", { ctrlKey: true });
    await new Promise((r) => setTimeout(r, 400));
    await press("u");
    await new Promise((r) => setTimeout(r, 400));
    await press("z");
    await new Promise((r) => setTimeout(r, 400));
    await press("u");
    await new Promise((r) => setTimeout(r, 400));
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
  // ── the review page, when the server has PRs with review data (`viewer-sandbox <dir> --github`) ──
  const st = await (await fetch(`${base}/state`, { headers: { "X-Stack-Actor": "headless" } })).json();
  const convs = Object.values(st.entities.conv ?? {});
  const rv = { entry: [], cold: [], warm: [], keys: {} };
  if (convs.length) {
    const pick = (b) => convs.find((c) => c.branch === b) ?? convs[0];
    const main = pick("demo/model");
    const other = pick("review/pr-77");
    const at = (c) => `/v2/b/${encodeURIComponent(c.repo)}/${c.branch}`;
    const painted = (sel) =>
      p.evaluate(
        (sel) =>
          new Promise((resolve) => {
            const t0 = performance.now();
            const ok = () => document.querySelector(sel);
            const obs = new MutationObserver(() => {
              if (!ok()) return;
              obs.disconnect();
              requestAnimationFrame(() => resolve(performance.now() - t0));
            });
            obs.observe(document.body, { subtree: true, childList: true, attributes: true });
            window.__go();
          }),
        sel,
      );
    for (let i = 0; i < 5; i++) {
      await p.goto(`${base}${at(main)}`);
      await p.waitForSelector('[data-paint="review"]');
      rv.entry.push(await p.evaluate(() => new Promise((r) => requestAnimationFrame(() => r(performance.now())))));
    }
    // in-app (back/forward-shaped): Forests → the review page, its first visit and a return visit
    for (let i = 0; i < 4; i++) {
      await p.goto(`${base}/v2`);
      await p.waitForSelector('[data-paint="forests"]');
      for (const into of [rv.cold, rv.warm]) {
        await p.evaluate((path) => {
          window.__go = () => {
            history.pushState(null, "", path);
            dispatchEvent(new PopStateEvent("popstate"));
          };
        }, at(main));
        into.push(await painted('[data-paint="review"] [data-stop^="l|"]'));
        await p.evaluate(() => {
          window.__go = () => {
            history.pushState(null, "", "/v2");
            dispatchEvent(new PopStateEvent("popstate"));
          };
        });
        await painted('[data-paint="forests"]');
      }
    }
    await p.goto(`${base}${at(main)}`);
    await p.waitForSelector('[data-paint="review"]');
    const KEYS = [["j"], ["j"], ["k"], ["n"], ["N"], ["]"], ["["], ["s"], ["s"], ["O"], ["O"], ["Tab"], ["Tab"], ["?"], ["Escape"], ["e"], ["e"], ["m"], ["Escape"]];
    for (let round = 0; round < 5; round++) {
      for (const [k] of KEYS) {
        const ms = await press(k);
        if (ms != null) (rv.keys[k] ??= []).push(ms);
        await new Promise((r) => setTimeout(r, 50));
      }
    }
    // config writes: a draft comment saved and deleted, a file marked viewed and back
    await p.goto(`${base}${at(other)}`);
    await p.waitForSelector('[data-paint="review"]');
    for (let i = 0; i < 5; i++) {
      await press("j");
      await press("c");
      await p.keyboard.type("budget probe");
      await p.keyboard.down("Control");
      await p.keyboard.down("Shift");
      await p.keyboard.press("Enter"); // ⌘⇧↵ keeps it a draft: the budget run never touches the (fake) GitHub
      await p.keyboard.up("Shift");
      await p.keyboard.up("Control");
      await new Promise((r) => setTimeout(r, 400));
      await press("j");
      await press("d");
      await new Promise((r) => setTimeout(r, 400));
      await press("k");
      await press("v");
      await new Promise((r) => setTimeout(r, 1200)); // u undoes the last SETTLED write: let the view land first
      await press("u");
      await new Promise((r) => setTimeout(r, 1200));
    }
  }
  await p.evaluate(() => document.dispatchEvent(new Event("visibilitychange")));
  await p.goto("about:blank");
  await new Promise((r) => setTimeout(r, 300));
  await b.close();
  // the first load is cold (server-side snapshot, uncached assets) — p50 holds the budget, p95 is shown
  line(pct(entry, 0.5) <= PAINT_MS, `Forests entry paint (page load: html + js + /state) ${fmt(entry)}, p50 ≤ ${PAINT_MS} ms`);
  line(pct(nav, 0.95) <= PAINT_MS, `Forests navigation paint (g f) ${fmt(nav)} ≤ ${PAINT_MS} ms`);
  line(pct(fb, 0.95) <= FEEDBACK_MS, `x feedback (keydown → frame without the row) ${fmt(fb)} ≤ ${FEEDBACK_MS} ms`);
  for (const [k, xs] of Object.entries(local)) line(pct(xs, 0.95) <= FEEDBACK_MS, `"${k === " " ? "space" : k}" feedback ${fmt(xs)} ≤ ${FEEDBACK_MS} ms`);
  if (rv.entry.length) {
    line(pct(rv.entry, 0.5) <= PAINT_MS, `Review entry paint (page load: html + js + /state + /node) ${fmt(rv.entry)}, p50 ≤ ${PAINT_MS} ms`);
    line(pct(rv.warm, 0.95) <= PAINT_MS, `Review navigation paint, diff already read ${fmt(rv.warm)} ≤ ${PAINT_MS} ms`);
    console.log(`· Review navigation paint, first visit (reads the diff) ${fmt(rv.cold)}`);
    for (const [k, xs] of Object.entries(rv.keys)) line(pct(xs, 0.95) <= FEEDBACK_MS, `review "${k}" feedback ${fmt(xs)} ≤ ${FEEDBACK_MS} ms`);
  } else console.log("· no review data on this server — run it as `viewer-sandbox <dir> --github` to measure the review page");
  const byId = {};
  for (const e of cmds) (byId[e.id] ??= []).push(e);
  for (const [id, es] of Object.entries(byId)) {
    const fb = es.map((e) => e.feedbackMs).filter((v) => v != null);
    if (fb.length) line(pct(fb, 0.95) <= FEEDBACK_MS, `${id} feedback (the app's own cmd events) ${fmt(fb)} ≤ ${FEEDBACK_MS} ms`);
    const budget = SETTLED_MS[es[0].budget];
    const st = es.map((e) => e.settledMs).filter((v) => v != null);
    if (budget && st.length) line(pct(st, 0.95) <= budget, `${id} settled ${fmt(st)} ≤ ${budget} ms`);
  }
  line(!errors.length, `no page errors${errors.length ? `: ${errors.join(" | ")}` : ""}`);
}
process.exit(failed ? 1 : 0);
