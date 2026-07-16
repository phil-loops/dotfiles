// probe: force the batch-9 cluster-1 gated states — the commits tab (list + divider +
// one expanded commit-diff), the `?` kbd-help modal, the file-filter :focus ring, the
// open-in-nvim flash toast, the map purpose-tip, and the home forest-tip (rows + landed
// band) — and emit shot-all-format png + rects.txt per state so diff.mjs can gate
// before/after at threshold 0.
import puppeteer from "puppeteer-core";
import { createHash } from "node:crypto";
import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const HERE = dirname(fileURLToPath(import.meta.url));
const arg = (n, d) => { const i = process.argv.indexOf("--" + n); return i === -1 ? d : process.argv[i + 1]; };
const BASE = arg("base", "http://127.0.0.1:7461");
const OUT = arg("out", "/tmp/batch9-c1-probe");
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
const PATCH = `diff --git a/queries/team-membership.ts b/queries/team-membership.ts
index 1111111..2222222 100644
--- a/queries/team-membership.ts
+++ b/queries/team-membership.ts
@@ -1,4 +1,6 @@
 import { db } from "../lib/db";
+
+export const findByUser = (userId: string) => db.teamMembership.findMany({ where: { userId } });
`;
const COMMITS = [
  { sha: "abc1234", subject: "queries: add membership lookups", author: "phil", date: "2d ago", own: true },
  { sha: "def5678", subject: "queries: add user lookups", author: "phil", date: "2d ago", own: true },
  { sha: "9876fed", subject: "chore: bump deps", author: "nalanj", date: "9d ago", own: false },
  { sha: "5432cba", subject: "fix: webhook endpoint url", author: "nalanj", date: "10d ago", own: false },
];
const COMMIT_DIFF = { sha: "abc1234", files: [{ path: "queries/team-membership.ts", status: "unblessed", add: 2, del: 0, patch: PATCH, stale: "" }] };
const PURPOSE = { thesis: "adds the queries the membership repair needs" };
const FOREST_PURPOSES = [
  { branch: "admin-user-membership-queries", thesis: "adds the queries the membership repair needs" },
  { branch: "admin-user-membership-models", thesis: "business rules for repairing a membership" },
  { branch: "admin-user-membership-panel", thesis: "" },
];

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
  if (u.pathname.endsWith("/commits")) return json(COMMITS);
  if (u.pathname.endsWith("/commit-diff")) return json(COMMIT_DIFF);
  if (u.pathname.endsWith("/purpose")) return json(PURPOSE);
  if (u.pathname.endsWith("/forest-purposes")) return json(FOREST_PURPOSES);
  if (u.pathname.endsWith("/open")) return json({ ok: true });
  if (u.pathname.endsWith("/projects")) {
    // graft a landed band onto the first project so forest-tip-landed renders
    return fetch(BASE + "/projects").then(async (r) => {
      const list = await r.json();
      if (list[0]) list[0].landed = [
        { pr: 9578, branch: "admin-user-membership-queries", at: "2026-07-14T12:00:00Z", title: "queries" },
        { pr: 9500, branch: "slack-notification-sqs", at: "2026-07-10T12:00:00Z", title: "sqs base" },
      ];
      return json(list);
    }).catch(() => req.continue());
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
const freeze = () => page.evaluate((css) => { const el = document.createElement("style"); el.textContent = css; document.head.appendChild(el); }, FREEZE_CSS);

// ── node-detail: commits view (list + divider), one commit expanded ──
await page.goto(BASE + "/forests/admin-user-memberships/" + BRANCH, { waitUntil: "domcontentloaded", timeout: 20000 });
await freeze();
await page.waitForSelector(".entry", { timeout: 20000 });
await settle(1500);
await page.keyboard.press("c");
await page.waitForSelector(".commits-divider", { timeout: 10000 });
await settle(800);
await snap("c1-commits");

await page.click(".commit-head");
await page.waitForSelector(".commit-diff .entry", { timeout: 10000 });
await settle(800);
await snap("c1-commit-open");

// ── kbd-help modal (`?`) ──
await page.keyboard.press("c"); // back to diffs
await settle(400);
await page.keyboard.press("?");
await page.waitForSelector(".kbd-help", { timeout: 10000 });
await settle(500);
await snap("c1-kbd-help");
await page.keyboard.press("Escape");
await settle(300);

// ── file-filter :focus ──
await page.click(".file-filter");
await settle(300);
await snap("c1-filter-focus");
await page.keyboard.press("Escape");
await settle(200);

// ── flash toast: hover a diff line number, press o (POST /open intercepted) ──
const lineBox = await page.evaluate(() => {
  // needs a NUMBERED cell inside the viewport — empty gutter cells arm nothing, and a
  // below-the-fold hover silently no-ops (the probe-craft warning in CONVERTING.md)
  const el = [...document.querySelectorAll(".d2h-code-side-linenumber, .d2h-code-linenumber")]
    .find((e) => {
      const r = e.getBoundingClientRect();
      return r.y > 100 && r.y < window.innerHeight - 40 && r.height > 0 && /^\d+$/.test((e.textContent || "").trim());
    });
  if (!el) return null;
  const r = el.getBoundingClientRect();
  return { x: r.x + r.width / 2, y: r.y + r.height / 2 };
});
if (!lineBox) { console.error("✗ no in-viewport numbered diff line found — hover would no-op"); process.exit(2); }
await page.mouse.move(lineBox.x, lineBox.y);
await settle(200);
await page.keyboard.press("o");
await page.waitForSelector(".flash", { timeout: 5000 });
// re-assert the pointer: Chrome intermittently drops the :hover PAINT on the armed line
// after the flash insertion (state and computed style stay hovered) — reproduced HEAD-vs-HEAD
await page.mouse.move(lineBox.x + 2, lineBox.y);
await page.mouse.move(lineBox.x, lineBox.y);
await settle(250);
await snap("c1-flash");

// ── purpose-tip: hover a map node on the forest overview ──
// freeze AFTER the map settles: an early freeze races the fm-fade entrance fills
// (animation:none strips the forwards fill → nodes stick at opacity 0 in some runs)
await page.goto(BASE + "/forests/admin-user-memberships", { waitUntil: "domcontentloaded", timeout: 20000 });
await page.waitForSelector(".fm-node:not(.fm-main)", { timeout: 20000 });
await settle(2000);
await freeze();
await settle(200);
await page.hover(".fm-node:not(.fm-main)");
await page.waitForSelector(".purpose-tip", { timeout: 10000 });
await settle(400);
await snap("c1-purpose-tip");

// ── forest-tip: hover a forest row on home (rows + landed band) ──
await page.goto(BASE + "/forests", { waitUntil: "domcontentloaded", timeout: 20000 });
await freeze();
await page.waitForSelector(".forest-row", { timeout: 20000 });
await settle(1500);
await page.hover(".forest-row");
await page.waitForSelector(".forest-tip", { timeout: 10000 });
await settle(400);
await snap("c1-forest-tip");

await browser.close();
