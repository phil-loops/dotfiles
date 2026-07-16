// probe: force the batch-9 cluster-2 gated states — the overview header's armed stage
// button + stage/ship outcome messages, the fo-warm reading→read cycle, the empty-forest
// landing (+ interest pips), the home amb-chips (conflict/link, clean + landed-mine,
// stale + landed-other), the review-import pin + "on viewer ✓", the work-row hover
// action pill (default .action-btn), and the origin-btn hover — png + rects per state
// so diff.mjs can gate before/after at threshold 0.
import puppeteer from "puppeteer-core";
import { createHash } from "node:crypto";
import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const HERE = dirname(fileURLToPath(import.meta.url));
const arg = (n, d) => { const i = process.argv.indexOf("--" + n); return i === -1 ? d : process.argv[i + 1]; };
const BASE = arg("base", "http://127.0.0.1:7461");
const OUT = arg("out", "/tmp/batch9-c2-probe");
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

const EMPTY_MODEL = { project: "__b9empty__", roots: [], nodes: {}, mergeOrder: [], interest: 2 };
const AMBIENT = {
  conflict: {
    available: true, tier: "dry-run", age_s: 120,
    report: {
      branches: [{ branch: "goals-pg-live-window", parent: "main", behind: 3, verdict: "will-conflict", would_do: "conflict", conflict_pr: 9550, conflict_title: "goals: window store" }],
      summary: { clean: 4, would_restack: 0, would_contract: 0, will_conflict: 1, skipped: 1 },
    },
  },
  clean: {
    available: true, tier: "apply", age_s: 60,
    report: { branches: [], summary: { clean: 6, would_restack: 0, would_contract: 0, will_conflict: 0, skipped: 0 } },
  },
  stale: {
    available: true, tier: "dry-run", age_s: 7200,
    report: { branches: [], summary: { clean: 6, would_restack: 0, would_contract: 0, will_conflict: 0, skipped: 0 } },
  },
};
const MERGES = {
  other: { available: true, age_s: 300, prs: [{ number: 9581, title: "fix webhook url", branch: "webhook-url", author: "nalanj", mergedAt: null, mine: false }] },
  mine: { available: true, age_s: 300, prs: [{ number: 9578, title: "membership queries", branch: "admin-user-membership-queries", author: "phil", mergedAt: null, mine: true }] },
  none: { available: false },
};
const FOREST_BRANCHES = [{ branch: "goals-pg-live-window", project: "goals-pg", parent: "main" }];
const REVIEW_REQS = [
  { number: 8633, title: "workflow trigger drift repair", author: "nalanj", url: "https://github.com/example/repo/pull/8633", imported: true },
  { number: 8790, title: "csv upload DLQ guard", author: "sam", url: "https://github.com/example/repo/pull/8790", imported: false },
];

// per-state interception config, mutated between navigations
let mode = {};

const browser = await puppeteer.launch({ executablePath: BIN, headless: true });
const page = await browser.newPage();
await page.setViewport({ width: 1440, height: 900, deviceScaleFactor: 2 });
await page.setRequestInterception(true);
const held = [];
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
  if (u.pathname.endsWith("/model") && u.searchParams.get("branch") === "__b9empty__") return json(EMPTY_MODEL);
  if (u.pathname.endsWith("/restack-ambient") && mode.ambient) return json(mode.ambient);
  if (u.pathname.endsWith("/restack-merges") && mode.merges) return json(mode.merges);
  if (u.pathname.endsWith("/forest-branches") && mode.forestBranches) return json(mode.forestBranches);
  if (u.pathname.endsWith("/review-requests") && mode.reviewReqs) return json(mode.reviewReqs);
  if (u.pathname.endsWith("/stage")) return json({ ok: true, tip: "admin-user-membership-panel", moved: ["a", "b"] });
  if (u.pathname.endsWith("/ship")) return json({ ok: false, err: "refused: dirty worktree on admin-user-membership-models" });
  if (u.pathname.endsWith("/forest-health") && mode.holdHealth) { held.push(req); return; } // held → "reading"
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
const freeze = () => page.evaluate((css) => { const el = document.createElement("style"); el.textContent = css; document.head.appendChild(el); }, FREEZE_CSS);

// ── forest overview: armed stage button, then stage + ship outcome messages ──
// freeze after settle — an early freeze strips the fm-fade fills (see probe-batch9-c1)
await page.goto(BASE + "/forests/admin-user-memberships", { waitUntil: "domcontentloaded", timeout: 20000 });
await page.waitForSelector(".fo-stage", { timeout: 20000 });
await settle(2000);
await freeze();
await settle(200);
const stageButtons = await page.$$(".fo-stage");
await stageButtons[stageButtons.length - 1].click(); // ⇪ stage → armed
await settle(300);
await snap("c2-stage-armed");
await stageButtons[stageButtons.length - 1].click(); // confirm → POST /stage (intercepted) → ✓ msg
await page.waitForSelector(".fo-stage-msg", { timeout: 5000 });
await settle(300);
await snap("c2-stage-msg");
await stageButtons[0].click(); // ▸ ready → armed
await settle(300);
await stageButtons[0].click(); // confirm → POST /ship (intercepted) → ✗ bad msg
await page.waitForSelector(".fo-stage-msg.bad", { timeout: 5000 });
await settle(300);
await snap("c2-ship-badmsg");

// ── fo-warm: hold /forest-health → reading; release with a drifted branch → read + count ──
mode = { holdHealth: true };
await page.goto(BASE + "/forests/admin-user-memberships", { waitUntil: "domcontentloaded", timeout: 20000 });
await page.waitForSelector(".fo-warm.reading", { timeout: 20000 });
await settle(1200);
await freeze();
await settle(200);
await snap("c2-warm-reading");
mode.holdHealth = false;
const HEALTH = { "admin-user-membership-queries": { drifted: true, merged: false, contractable: false } };
for (const req of held.splice(0)) req.respond({ status: 200, contentType: "application/json", body: JSON.stringify(HEALTH) });
await page.waitForSelector(".fo-warm.read", { timeout: 10000 });
await snap("c2-warm-read");

// ── empty forest + interest pips ──
mode = {};
await page.goto(BASE + "/forests/__b9empty__", { waitUntil: "domcontentloaded", timeout: 20000 });
await freeze();
await page.waitForSelector(".fo-empty", { timeout: 20000 });
await settle(1200);
await snap("c2-fo-empty");

// ── home chips: three ambient variants × landed variants ──
const chipState = async (name, ambient, merges, forestBranches) => {
  mode = { ambient, merges, forestBranches };
  await page.goto(BASE + "/forests", { waitUntil: "domcontentloaded", timeout: 20000 });
  await freeze();
  await page.waitForSelector(".amb-chip", { timeout: 20000 });
  await settle(1500);
  await snap(name);
};
await chipState("c2-chips-conflict", AMBIENT.conflict, MERGES.other, FOREST_BRANCHES); // amb-conflict + amb-link + landed-other
await chipState("c2-chips-clean", AMBIENT.clean, MERGES.mine, undefined);              // amb-clean + landed-mine
await chipState("c2-chips-stale", AMBIENT.stale, MERGES.none, undefined);              // amb-stale alone

// ── work tab: review-import pin + "on viewer ✓", then the hover action pill ──
mode = { reviewReqs: REVIEW_REQS };
await page.goto(BASE + "/work", { waitUntil: "domcontentloaded", timeout: 20000 });
await freeze();
await page.waitForSelector(".review-import", { timeout: 20000 });
await page.waitForSelector(".review-on", { timeout: 20000 });
await settle(1500);
await snap("c2-review-reqs");

// the pills live below the fold — scroll one into view first (a below-fold hover no-ops)
const rowBox = await page.evaluate(() => {
  const btn = document.querySelector(".work-acts button");
  if (!btn) return null;
  btn.scrollIntoView({ behavior: "instant", block: "center" });
  const r = btn.getBoundingClientRect();
  return { x: r.x + r.width / 2, y: r.y + r.height / 2, ih: window.innerHeight };
});
if (!rowBox || rowBox.y < 0 || rowBox.y > rowBox.ih) { console.error("✗ no in-viewport work-row action button found"); process.exit(2); }
await settle(200);
await page.mouse.move(rowBox.x, rowBox.y); // hovers the row (reveals .work-acts) AND the pill
await settle(300);
await snap("c2-action-hover");

// ── origin-btn hover ──
await page.hover(".origin-btn");
await settle(300);
await snap("c2-origin-hover");

await browser.close();
