// probe: force the node-header chrome's gated states — synthetic
// /push-preview (red push button, ✎ message, ↗ view PR), the ⋯ menu, the message editor
// with plan steps, the commits viewnote, and review-node's "they pushed" — and emit
// shot-all-format png + rects.txt per state so diff.mjs can gate before/after.
import puppeteer from "puppeteer-core";
import { createHash } from "node:crypto";
import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const HERE = dirname(fileURLToPath(import.meta.url));
const arg = (n, d) => { const i = process.argv.indexOf("--" + n); return i === -1 ? d : process.argv[i + 1]; };
const BASE = arg("base", "http://127.0.0.1:7461");
const OUT = arg("out", "/tmp/nodehead-probe");
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

const BRANCH = "admin-user-membership-queries";
const PREVIEW = {
  ok: true, outgoing: 1, reasons: [], originExists: true, published: true,
  web: "https://github.com/example/repo/pull/9999",
  commit: { sha: "abc1234", subject: "queries: add membership lookups", body: "Thin data-access helpers.\n\nPart of admin-user-memberships." },
};
const PLAN_STEPS = { steps: [
  { n: 1, branch: BRANCH, job: "add the queries the membership repair needs", story: "", landed: false, me: true },
  { n: 2, branch: "admin-user-membership-models", job: "business rules for repairing a membership", story: "override text", landed: false, me: false },
  { n: 3, branch: "admin-user-membership-panel", job: "the admin panel itself", story: "", landed: true, me: false },
] };
const PREP_ROUTE = { route: "squash", why: "3 commits outgoing" };
const REMOTE = { available: true, remote: "abc1234", local: "def5678" };

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
  const json = (body) => req.respond({ status: 200, contentType: "application/json", body: JSON.stringify(body) });
  if (u.pathname.endsWith("/push-preview")) return json(PREVIEW);
  if (u.pathname.endsWith("/plan-steps")) return json(PLAN_STEPS);
  if (u.pathname.endsWith("/prep-route")) return json(PREP_ROUTE);
  if (u.pathname.endsWith("/review-remote")) return json(REMOTE);
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

// state 1-4: node-detail with synthetic push-preview
await page.goto(BASE + "/forests/admin-user-memberships/" + BRANCH, { waitUntil: "domcontentloaded", timeout: 20000 });
await page.evaluate((css) => { const el = document.createElement("style"); el.textContent = css; document.head.appendChild(el); }, FREEZE_CSS);
await page.waitForSelector(".entry", { timeout: 20000 });
await page.waitForSelector(".nh-push-red", { timeout: 15000 });
await settle(2000);
await snap("nodehead-rest");

await page.click(".icon-btn[aria-haspopup='true']");
await page.waitForSelector(".nh-menu", { timeout: 10000 });
await settle(600);
await snap("nodehead-menu");

await page.click(".icon-btn[aria-haspopup='true']"); // toggle the menu closed
await settle(400);
const openedEditor = await page.evaluate(() => {
  const b = [...document.querySelectorAll("button")].find((x) => x.textContent.includes("✎ message"));
  if (!b) return false;
  b.click();
  return true;
});
if (!openedEditor) { console.error("✗ ✎ message button not found"); process.exit(2); }
await page.waitForSelector(".nh-editor", { timeout: 10000 });
await page.waitForSelector(".plan-step", { timeout: 10000 });
await settle(800);
await snap("nodehead-editor");

await page.evaluate(() => { const b = [...document.querySelectorAll("button")].find((x) => x.textContent === "close"); b?.click(); });
await settle(300);
await page.keyboard.press("c");
await page.waitForSelector(".nh-viewnote", { timeout: 10000 });
await settle(800);
await snap("nodehead-viewnote");

// state 5: review-node with synthetic "they pushed"
await page.goto(BASE + "/review/8633", { waitUntil: "domcontentloaded", timeout: 20000 });
await page.evaluate((css) => { const el = document.createElement("style"); el.textContent = css; document.head.appendChild(el); }, FREEZE_CSS);
await page.waitForSelector(".entry", { timeout: 20000 });
await page.waitForSelector(".nh-pushed", { timeout: 15000 });
await settle(2000);
await snap("reviewhead-pushed");

await browser.close();
