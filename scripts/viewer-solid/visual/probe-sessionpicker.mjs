// probe: force the ✦ session picker open on node-detail's header — /claude-sessions is
// intercepted so both runs list identical rows. Three states: a populated list, the second
// row hovered, and the no-other-sessions empty case. Emits shot-all-format png + rects.txt
// per state so diff.mjs can gate before/after.
import puppeteer from "puppeteer-core";
import { createHash } from "node:crypto";
import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const HERE = dirname(fileURLToPath(import.meta.url));
const arg = (n, d) => { const i = process.argv.indexOf("--" + n); return i === -1 ? d : process.argv[i + 1]; };
const BASE = arg("base", "http://127.0.0.1:7461");
const OUT = arg("out", "/tmp/sessionpicker-probe");
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

const SESSIONS = [
  { session_id: "sess-a1", repo_name: "loops", branch: "goals-pg-window-store", area: "", pane: "%12", addr: "cw-pool-2:1.0", idle_s: 42 },
  { session_id: "sess-b2", repo_name: "dotfiles", branch: "", area: "viewer", pane: "%31", addr: "main:2.1", idle_s: 1740 },
  { session_id: "sess-c3", repo_name: "loops", branch: "admin-user-membership-models", area: "", pane: "%7", addr: "cw-pool-4:1.2", idle_s: 9000 },
];
let sessions = SESSIONS;

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
  const u = new URL(url);
  if (u.pathname.endsWith("/claude-sessions")) {
    return req.respond({ status: 200, contentType: "application/json", body: JSON.stringify({ sessions }) });
  }
  req.continue();
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

const openPicker = async () => {
  await page.goto(BASE + "/forests/admin-user-memberships/admin-user-membership-queries", { waitUntil: "domcontentloaded", timeout: 20000 });
  await page.evaluate((css) => { const el = document.createElement("style"); el.textContent = css; document.head.appendChild(el); }, FREEZE_CSS);
  await page.waitForSelector(".sp-anchor .icon-btn", { timeout: 20000 });
  const visible = await page.evaluate(() => {
    const r = document.querySelector(".sp-anchor .icon-btn")?.getBoundingClientRect();
    return !!r && r.y >= 0 && r.y < window.innerHeight;
  });
  if (!visible) { console.error("✗ ✦ anchor outside the viewport"); process.exit(2); }
  await settle(1500);
  await page.click(".sp-anchor .icon-btn");
  await page.waitForSelector(".session-pop", { timeout: 10000 });
};

// state 1: populated — new-pane row + three live sessions (target/name/where columns)
await openPicker();
await page.waitForFunction(() => document.querySelectorAll(".sp-item").length === 4, { timeout: 10000 });
await settle(800);
await snap("sessionpicker-list");

// state 2: second row hovered — the .sp-item hover wash
await page.hover(".session-pop .sp-item:nth-of-type(2)");
await settle(400);
await snap("sessionpicker-hover");

// state 3: no other live sessions — the italic empty line under the new-pane row
sessions = [];
await openPicker();
await page.waitForFunction(() => document.querySelector(".sp-empty")?.textContent?.includes("no other live sessions"), { timeout: 10000 });
await settle(800);
await snap("sessionpicker-empty");

await browser.close();
