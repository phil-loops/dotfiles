// probe: the page skeleton's stateful chrome that the baseline surfaces don't reach.
// node-detail's fixture already renders the uncommitted rail (dirty: ['.gen']), so the
// idle rail is baseline-covered; this drives what needs interaction:
//   - `b` collapses the file panel (.shell one-column, spine hidden, ⟩ reopen tab) and
//     `b` again restores it — geometry asserted via grid-template-columns both ways
//   - the rail's ↓ commit form (input + go), a per-file ✓ accept form, and the armed
//     ✕ reject (confirm: discard)
//   - the dirt receipt line — /commit-dirty is intercepted with {ok:true} so the
//     otherwise-unreachable .dirt-receipt renders
// Emits shot-all-format png + rects.txt per state for pre/post diffing.
import puppeteer from "puppeteer-core";
import { createHash } from "node:crypto";
import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const HERE = dirname(fileURLToPath(import.meta.url));
const arg = (n, d) => { const i = process.argv.indexOf("--" + n); return i === -1 ? d : process.argv[i + 1]; };
const BASE = arg("base", "http://127.0.0.1:7491");
const OUT = arg("out", "/tmp/skeleton-probe");
const BIN = process.env.CHROME_BIN
  ?? "/Users/philbrockman/.cache/puppeteer/chrome-headless-shell/mac_arm-150.0.7871.24/chrome-headless-shell-mac-arm64/chrome-headless-shell";
const FONTS = join(HERE, "fixtures", "fonts");
const keyOf = (url) => createHash("sha1").update(url).digest("hex").slice(0, 24);
const FREEZE_CSS = `
*, *::before, *::after { animation: none !important; transition: none !important; caret-color: transparent !important; }
html { scrollbar-width: none !important; }
::-webkit-scrollbar { display: none !important; }
`;
mkdirSync(OUT, { recursive: true });

const browser = await puppeteer.launch({ executablePath: BIN, headless: true });
const page = await browser.newPage();
await page.setViewport({ width: 1440, height: 900, deviceScaleFactor: 2 });
await page.setRequestInterception(true);
page.on("request", (req) => {
  const url = req.url();
  if (url.startsWith("https://fonts.")) {
    const base = join(FONTS, keyOf(url));
    if (existsSync(base + ".bin")) {
      const { type } = JSON.parse(readFileSync(base + ".meta", "utf8"));
      return req.respond({ status: 200, contentType: type, body: readFileSync(base + ".bin") });
    }
    return req.abort();
  }
  if (req.method() === "POST" && new URL(url).pathname.endsWith("/commit-dirty")) {
    return req.respond({ status: 200, contentType: "application/json", body: JSON.stringify({ ok: true }) });
  }
  req.continue();
});

const settle = (ms) => new Promise((r) => setTimeout(r, ms));
const freeze = () => page.evaluate((css) => {
  const el = document.createElement("style");
  el.textContent = css;
  document.head.appendChild(el);
}, FREEZE_CSS);

const snap = async (name) => {
  await page.evaluate(() => document.fonts.ready);
  await page.screenshot({ path: join(OUT, name + ".png") });
  const rects = await page.evaluate(() => {
    const out = [];
    const walk = (el, path) => {
      let i = 0;
      for (const c of el.children) {
        i++;
        const p = `${path}/${c.tagName.toLowerCase()}[${i}]`;
        if (!["SCRIPT", "STYLE", "LINK", "META"].includes(c.tagName)) {
          const r = c.getBoundingClientRect();
          out.push(`${p} ${Math.round(r.x)},${Math.round(r.y)} ${Math.round(r.width)}x${Math.round(r.height)}`);
        }
        walk(c, p);
      }
    };
    walk(document.body, "");
    return out.join("\n");
  });
  writeFileSync(join(OUT, name + ".rects.txt"), rects + "\n");
  console.log("  ✓ " + name);
};

const gridCols = () => page.evaluate(() => getComputedStyle(document.querySelector(".shell")).gridTemplateColumns);

await page.goto(BASE + "/forests/admin-user-memberships/admin-user-membership-queries", { waitUntil: "domcontentloaded", timeout: 20000 });
await page.waitForSelector(".entry", { timeout: 20000 });
await page.waitForSelector(".uncommitted-rail", { timeout: 15000 });
await freeze();
await settle(2000);

// ── b: collapse the panel ──
const openCols = await gridCols();
await page.keyboard.press("b");
await page.waitForSelector(".panel-reopen", { timeout: 10000 });
const collapsedCols = await gridCols();
const spineHidden = await page.evaluate(() => {
  const s = document.querySelector(".spine");
  return !s || getComputedStyle(s).display === "none";
});
console.log(`shell cols open=${openCols} collapsed=${collapsedCols} spineHidden=${spineHidden}`);
if (!spineHidden) { console.error("✗ spine still visible when collapsed"); process.exit(2); }
await settle(600);
await snap("skeleton-collapsed");

// ── b again: restore ──
await page.keyboard.press("b");
await page.waitForSelector(".spine", { visible: true, timeout: 10000 });
const restoredCols = await gridCols();
if (restoredCols !== openCols) { console.error(`✗ restore mismatch: ${restoredCols} != ${openCols}`); process.exit(2); }
await settle(600);
await snap("skeleton-restored");

// ── the rail's whole-tree commit form ──
await page.evaluate(() => document.querySelector(".uncommitted-rail").scrollIntoView({ block: "center" }));
await page.click(".ur-commit-btn");
await page.waitForSelector(".ur-commit-form", { timeout: 10000 });
await settle(400);
await snap("skeleton-ur-form");

// ── armed reject (first click arms), then the per-file accept form (it replaces the verdicts) ──
await page.click(".ur-file-reject"); // first click arms it
await page.waitForFunction(() => document.querySelector(".ur-file-reject")?.textContent?.includes("confirm"), { timeout: 10000 });
await settle(400);
await snap("skeleton-ur-armed");
await page.click(".ur-file-accept");
await page.waitForSelector(".ur-file-acts .ur-commit-input", { timeout: 10000 });
await settle(400);
await snap("skeleton-ur-file");

// ── dirt receipt: commit the file (POST intercepted → ok) ──
await page.type(".ur-file-acts .ur-commit-input", "chore: sweep dirt");
await page.click(".ur-file-acts .ur-commit-go");
await page.waitForSelector(".dirt-receipt", { timeout: 10000 });
await page.evaluate(() => document.querySelector(".dirt-receipt").scrollIntoView({ block: "center" }));
await settle(600);
await snap("skeleton-receipt");

await browser.close();
