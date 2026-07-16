// probe: force the ctx-menu grammar open — Home's conviction menu (right-click a forest
// row), an item hovered, the destructive drop two-click arm, and FocusLane's reprioritize
// menu when pinned rows exist. Emits shot-all-format png + rects.txt per state.
import puppeteer from "puppeteer-core";
import { createHash } from "node:crypto";
import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const HERE = dirname(fileURLToPath(import.meta.url));
const arg = (n, d) => { const i = process.argv.indexOf("--" + n); return i === -1 ? d : process.argv[i + 1]; };
const BASE = arg("base", "http://127.0.0.1:7461");
const OUT = arg("out", "/tmp/ctxmenu-probe");
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
  if (!url.startsWith("https://fonts.")) return req.continue();
  const base = join(FONTS, keyOf(url));
  if (existsSync(base + ".bin")) {
    const { type } = JSON.parse(readFileSync(base + ".meta", "utf8"));
    return req.respond({ status: 200, contentType: type, body: readFileSync(base + ".bin") });
  }
  return req.abort();
});

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
const settle = (ms) => new Promise((r) => setTimeout(r, ms));

await page.goto(BASE + "/forests", { waitUntil: "domcontentloaded", timeout: 20000 });
await page.evaluate((css) => { const el = document.createElement("style"); el.textContent = css; document.head.appendChild(el); }, FREEZE_CSS);
await page.waitForSelector(".forest-row", { timeout: 20000 });
await settle(2000);

await page.click(".forest-row", { button: "right" });
await page.waitForSelector(".ctx-menu", { timeout: 10000 });
await settle(600);
await snap("ctx-home");

await page.hover(".ctx-menu .ctx-item:nth-of-type(2)");
await settle(400);
await snap("ctx-home-hover");

const armed = await page.evaluate(() => {
  const b = document.querySelector(".ctx-drop");
  if (!b) return false;
  b.click();
  return true;
});
if (!armed) { console.error("✗ ctx-drop not found"); process.exit(2); }
await page.waitForSelector(".ctx-drop.armed", { timeout: 5000 });
await settle(400);
await snap("ctx-home-armed");

const hasLane = await page.$(".focus-row");
if (hasLane) {
  await page.click(".ctx-scrim");
  await settle(400);
  await page.click(".focus-row", { button: "right" });
  await page.waitForSelector(".ctx-menu", { timeout: 10000 });
  await settle(600);
  await snap("ctx-focuslane");
} else {
  console.log("  – ctx-focuslane skipped (no pinned rows in fixture)");
}

await browser.close();
