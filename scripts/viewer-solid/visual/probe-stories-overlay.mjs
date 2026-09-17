// probe: the node page's forest-steps strip and the story editor it opens — synthetic
// /push-preview + /plan-steps + /step-evidence, so a click never touches a real forest's
// stories (2026-09-09: a probe click deleted a real one). Emits shot-all-format png +
// rects.txt per state.
//   node visual/probe-stories-overlay.mjs --base http://127.0.0.1:7333 --out /tmp/stories-probe
import puppeteer from "puppeteer-core";
import { createHash } from "node:crypto";
import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const HERE = dirname(fileURLToPath(import.meta.url));
const arg = (n, d) => { const i = process.argv.indexOf("--" + n); return i === -1 ? d : process.argv[i + 1]; };
const BASE = arg("base", "http://127.0.0.1:7333");
const OUT = arg("out", "/tmp/stories-probe");
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
const PLAN_STEPS = { project: "admin-user-memberships", branch: BRANCH, steps: [
  { n: 1, branch: BRANCH, job: "add the queries the membership repair needs", story: "",
    description: "add the queries the membership repair needs", subject: "queries: add membership lookups", pr: null, landed: false, me: true },
  { n: 2, branch: "admin-user-membership-models", job: "repair a membership without trusting the caller's team",
    story: "repair a membership without trusting the caller's team", description: "business rules for repairing a membership",
    subject: "models: membership repair", pr: null, landed: false, me: false },
  { n: 3, branch: "admin-user-membership-panel", job: "the admin panel itself", story: "",
    description: "", subject: "the admin panel itself", pr: 8601, landed: true, me: false },
] };
const EVIDENCE = {
  branch: BRANCH, parent: "main",
  subjects: ["queries: add membership lookups", "queries: cover the soft-deleted team case"],
  files: ["queries/team-membership.ts", "queries/team-membership.test.ts", "queries/user.ts"],
  fileCount: 3, adds: 184, dels: 12,
};
// the per-file payload the story fold reads the change off — same shape as /node
const PATCH = `diff --git a/queries/team-membership.ts b/queries/team-membership.ts
index 1111111..2222222 100644
--- a/queries/team-membership.ts
+++ b/queries/team-membership.ts
@@ -1,3 +1,7 @@
 import prisma from "../lib/prisma.js";
+
+export const findByUserAndTeam = (userId: string, teamId: string) =>
+  prisma.teamMembership.findFirst({ where: { userId, teamId } });
`;
const LONG_PATCH = `diff --git a/queries/user.ts b/queries/user.ts
index 3333333..4444444 100644
--- a/queries/user.ts
+++ b/queries/user.ts
@@ -1,4 +1,24 @@
 import prisma from "../lib/prisma.js";
${Array.from({ length: 20 }, (_, i) => `+export const lookup${i} = (id: string) => prisma.user.findFirst({ where: { id } });`).join("\n")}
`;
const NODE_FILES = { branch: BRANCH, files: [
  { path: "queries/team-membership.ts", status: "unblessed", add: "4", del: "0", patch: PATCH, stale: "" },
  { path: "queries/team-membership.test.ts", status: "unblessed", add: "12", del: "1", patch: PATCH, stale: "" },
  { path: "queries/user.ts", status: "unblessed", add: "20", del: "0", patch: LONG_PATCH, stale: "" },
], dirty: [], worktree: "" };
const PREP_ROUTE = { route: "squash", why: "3 commits outgoing" };
const REMOTE = { available: true, remote: "abc1234", local: "def5678" };

const browser = await puppeteer.launch({ executablePath: BIN, headless: true });
const page = await browser.newPage();
await page.setViewport({ width: 1440, height: 900, deviceScaleFactor: 2 });
await page.setRequestInterception(true);
const mutations = [];
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
  // a POST leaving this probe would write somebody's real story — record and refuse it
  if (req.method() !== "GET") {
    if (!u.pathname.endsWith("/track")) mutations.push(req.method() + " " + u.pathname);   // /track is usage telemetry, not a forest write
    return json({ ok: true, prev: "" });
  }
  if (u.pathname.endsWith("/push-preview")) return json(PREVIEW);
  if (u.pathname.endsWith("/plan-steps")) return json(PLAN_STEPS);
  if (u.pathname.endsWith("/step-evidence")) return json(EVIDENCE);
  if (u.pathname.endsWith("/node")) return json(NODE_FILES);
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

await page.goto(BASE + "/forests/admin-user-memberships/" + BRANCH, { waitUntil: "domcontentloaded", timeout: 20000 });
await page.evaluate((css) => { const el = document.createElement("style"); el.textContent = css; document.head.appendChild(el); }, FREEZE_CSS);
await page.waitForSelector(".entry", { timeout: 20000 });
await page.waitForSelector(".nh-push-red", { timeout: 15000 });
await settle(1500);

const openedEditor = await page.evaluate(() => {
  const b = [...document.querySelectorAll("button")].find((x) => x.textContent.includes("✎ message"));
  if (!b) return false;
  b.click();
  return true;
});
if (!openedEditor) { console.error("✗ ✎ message button not found"); process.exit(2); }
await page.waitForSelector(".plan-step", { timeout: 10000 });
await settle(600);
await snap("stories-strip");

// clicking step 2's line opens the editor focused on THAT branch, with step 1 marked this-branch
await page.evaluate(() => {
  const lines = [...document.querySelectorAll(".plan-step .ps-line")];
  lines[1].click();
});
await page.waitForSelector(".stories-sheet", { timeout: 10000 });
await page.waitForSelector(".stories-file-diff", { timeout: 10000 });
await settle(700);
await snap("stories-overlay");

const audit = await page.evaluate(() => {
  const rows = [...document.querySelectorAll(".stories-row")];
  const focused = document.activeElement;
  return {
    rows: rows.length,
    boxes: rows.map((r) => {
      const t = r.querySelector("textarea");
      return {
        value: t ? t.value : null,
        placeholder: t ? t.placeholder : null,
        badge: r.querySelector(".stories-src")?.textContent ?? "",
        here: !!r.querySelector(".stories-here"),
        fallback: r.querySelector(".stories-under")?.textContent?.trim() ?? "",
        wraps: t ? t.scrollWidth <= t.clientWidth + 1 : null,
      };
    }),
    focusedIsTextarea: focused?.tagName === "TEXTAREA",
    focusedValue: focused?.tagName === "TEXTAREA" ? focused.value : null,
    evidence: document.querySelector(".stories-ev-body")?.textContent?.replace(/\s+/g, " ").trim() ?? "",
    fileRows: [...document.querySelectorAll(".stories-file-head")].map((el) => el.textContent?.replace(/\s+/g, " ").trim()),
    diffsOpen: document.querySelectorAll(".stories-file-diff").length,
    diffHasCode: (document.querySelector(".stories-file-diff")?.textContent ?? "").includes("findByUserAndTeam"),
    readingHead: document.querySelector(".stories-read-head")?.textContent?.replace(/\s+/g, " ").trim() ?? "",
    // the ergonomic claim: two panes that scroll separately, and the typing column holds its place
    panes: (() => {
      const col = document.querySelector(".stories-col");
      const read = document.querySelector(".stories-read");
      if (!col || !read) return null;
      const box = document.querySelector(".stories-row.on textarea")?.getBoundingClientRect();
      return {
        colScrolls: col.scrollHeight > col.clientHeight + 1,
        readScrolls: read.scrollHeight > read.clientHeight + 1,
        sideBySide: Math.abs(col.getBoundingClientRect().top - read.getBoundingClientRect().top) < 2,
        boxTop: box ? Math.round(box.top) : null,
      };
    })(),
    overlayCoversEditor: (() => {
      const sheet = document.querySelector(".stories-sheet")?.getBoundingClientRect();
      return sheet ? Math.round(sheet.width) : 0;
    })(),
  };
});
console.log(JSON.stringify(audit, null, 2));
// the ergonomics under test: scrolling the change must not move the box you type in, and the
// keyboard alone must walk the list (↵ and ↓), the reading pane following each row
const ergo = await page.evaluate(async () => {
  const boxOf = () => document.querySelector(".stories-row.on textarea")?.getBoundingClientRect().top ?? null;
  const read = document.querySelector(".stories-read");
  const before = boxOf();
  read.scrollTop = read.scrollHeight;
  await new Promise((r) => requestAnimationFrame(r));
  return { boxBefore: Math.round(before ?? -1), boxAfterScroll: Math.round(boxOf() ?? -1), scrolled: read.scrollTop > 0 };
});
const focusedBranch = () => page.evaluate(() =>
  document.activeElement?.closest(".stories-row")?.querySelector(".stories-branch")?.textContent ?? "");
await page.evaluate(() => document.querySelector(".stories-row.on textarea")?.focus());
const fromRow = await focusedBranch();
// from mid-text the first ArrowUp takes the caret to the start of the line (every text field
// does); the next one, with nowhere left to go, walks up the list
await page.keyboard.press("ArrowUp");
await settle(120);
await page.keyboard.press("ArrowUp");
await settle(250);
const afterUp = await focusedBranch();
const readAfterUp = await page.evaluate(() => document.querySelector(".stories-read-head span")?.textContent?.trim() ?? "");
console.log(`typing box held still while the change scrolled: ${ergo.boxBefore === ergo.boxAfterScroll} (${ergo.boxBefore} → ${ergo.boxAfterScroll}, scrolled=${ergo.scrolled})`);
console.log(`↑ moved rows: ${fromRow} → ${afterUp} · reading pane followed: ${readAfterUp}`);
if (ergo.boxBefore !== ergo.boxAfterScroll || afterUp === fromRow) process.exitCode = 6;

console.log("mutating requests attempted: " + (mutations.length ? mutations.join(", ") : "none"));

await page.keyboard.press("Escape");   // esc inside a row reverts, does not close
await settle(300);
const stillOpen = await page.evaluate(() => !!document.querySelector(".stories-sheet"));
await page.evaluate(() => document.activeElement?.blur());
await page.keyboard.press("Escape");   // esc outside a row closes the sheet
await settle(400);
const closed = await page.evaluate(() => !document.querySelector(".stories-sheet"));
console.log(`esc in row keeps it open: ${stillOpen} · esc outside closes: ${closed}`);

// ⌘K → "✎ stories" must open the same sheet over the node page, with no message editor open
await page.evaluate(() => {
  const b = [...document.querySelectorAll("button")].find((x) => x.textContent === "close");
  b?.click();                                       // shut the message editor
});
await settle(300);
const stripGone = await page.evaluate(() => !document.querySelector(".plan-step"));
await page.keyboard.down("Meta");
await page.keyboard.press("k");
await page.keyboard.up("Meta");
await page.waitForSelector(".cmdk-backdrop", { timeout: 10000 });
await page.type(".cmdk-backdrop input", "stories");
await settle(400);
await snap("stories-palette");
await page.keyboard.press("Enter");
await page.waitForSelector(".stories-sheet", { timeout: 10000 });
await settle(600);
const fromPalette = await page.evaluate(() => ({
  sheet: !!document.querySelector(".stories-sheet"),
  editorOpen: !!document.querySelector(".nh-editor"),
  rows: document.querySelectorAll(".stories-row").length,
  navigated: location.pathname,
}));
console.log(`strip gone with the editor: ${stripGone} · ⌘K opened: ${JSON.stringify(fromPalette)}`);
await snap("stories-from-palette");
if (!stripGone || !fromPalette.sheet || fromPalette.editorOpen) process.exitCode = 5;

await browser.close();
if (mutations.length) process.exit(3);
if (!stillOpen || !closed) process.exit(4);
