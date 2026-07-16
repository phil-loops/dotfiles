// probe: force-render the whole chat family (deferred five batches — no baseline surface
// covers any of it). Network-owned: /chat-jobs and /tmux-targets are intercepted; chat
// threads + the drawer target are seeded via their localStorage mirrors before first paint.
// States: the Home chats strip (live/ok/err marks), the forest-row ✦ badge, the file-rail
// ✦ chat button (working / done / 💬 badge), the cross-forest chat index overlay, the chat
// drawer (turns, markdown, an action button, attachments row, popout menu), and the docked
// pill (away → the ↗ return button). Emits shot-all-format png + rects.txt per state.
// --derive additionally reports which duplicate @keyframes chat-pulse wins (rule 12): it
// reads the LIVE animation's keyframes off rendered consumers before any freeze.
import puppeteer from "puppeteer-core";
import { createHash } from "node:crypto";
import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const HERE = dirname(fileURLToPath(import.meta.url));
const arg = (n, d) => { const i = process.argv.indexOf("--" + n); return i === -1 ? d : process.argv[i + 1]; };
const BASE = arg("base", "http://127.0.0.1:7491");
const OUT = arg("out", "/tmp/chat-probe");
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

const NOW = Math.floor(Date.now() / 1000);
const JOBS = [
  { turn: "t1", branch: "admin-user-membership-queries", path: "queries/user.ts", question: "is this index safe?", repo: "loops", project: "admin-user-memberships", status: "reading the diff", chars: 4200, done: false, ok: null, created: NOW - 90 },
  { turn: "t2", branch: "admin-user-membership-models", path: "", question: "summarize", repo: "loops", project: "admin-user-memberships", status: "done", chars: 12100, done: true, ok: true, created: NOW - 300 },
  { turn: "t3", branch: "cdc-parity", path: "models/contact/index.ts", question: "why does this fail?", repo: "loops", project: "cdc-parity", status: "done", chars: 800, done: true, ok: false, created: NOW - 500 },
  // rides a forest that renders as a live ForestRow (admin-user-memberships sits in the forgotten band)
  { turn: "t4", branch: "goals/attach-flow", path: "", question: "does the attach flow hold?", repo: "loops", project: "goals-ga", status: "reading the diff", chars: 900, done: false, ok: null, created: NOW - 45 },
];
const TARGETS = [
  { target: "main:2", name: "viewer", panes: 2 },
  { target: "cw-pool-1:1", name: "loops", panes: 1 },
];

const BRANCH = "admin-user-membership-queries";
const SEP = "\u0000"; // chatStore composite-key separator: a literal NUL
const THREADS = {};
// working — an in-flight turn (activeTurn present) pulses the ✦ chat button
THREADS[BRANCH + SEP + "queries/user.ts"] = {
  msgs: [
    { role: "you", text: "is this index safe?" },
    { role: "claude", text: "## Looking at the index\n\nThe composite key covers:\n\n- `teamId` first\n- `userId` second\n\nSo lookups by `teamId` alone [use the prefix](https://example.com).\n\n```sql\nCREATE INDEX ON m (team_id, user_id);\n```\n\n```loops-action\n{\"action\": \"whats-next\"}\n```\n", attachments: [{ name: "screen.png" }] },
  ],
  session: "sess-live-1",
  writtenAt: Date.now() - 60_000,
  activeTurn: { id: "t1", idx: 1 },
};
// done-unseen — finished while the drawer was closed: sage "done ✓"
THREADS[BRANCH + SEP + "queries/team-membership.ts"] = {
  msgs: [
    { role: "you", text: "walk me through the delete path" },
    { role: "claude", text: "It cascades through the membership table first." },
  ],
  session: "sess-done-2",
  writtenAt: Date.now() - 120_000,
  endedAt: Date.now() - 30_000,
  unseenDone: true,
};
// plain thread — message count badge only
THREADS[BRANCH + SEP + "queries/user.test.ts"] = {
  msgs: [
    { role: "you", text: "add a case for the null team" },
    { role: "claude", text: "Covered by the second describe block." },
  ],
  session: "sess-idle-3",
  writtenAt: Date.now() - 300_000,
};

const DRAWER = {
  branch: BRANCH,
  origin: { kind: "forest", name: "admin-user-memberships", node: BRANCH },
  path: "queries/user.ts",
  project: "",
  minimized: false,
};

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
  if (u.pathname.endsWith("/chat-jobs")) {
    return req.respond({ status: 200, contentType: "application/json", body: JSON.stringify(JOBS) });
  }
  if (u.pathname.endsWith("/tmux-targets")) {
    return req.respond({ status: 200, contentType: "application/json", body: JSON.stringify(TARGETS) });
  }
  req.continue();
});

const settle = (ms) => new Promise((r) => setTimeout(r, ms));
const freeze = () => page.evaluate((css) => {
  const el = document.createElement("style");
  el.id = "probe-freeze";
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

// live-animation report for a selector: name, duration, and the RESOLVED keyframes — the
// authoritative answer to "which duplicate @keyframes chat-pulse wins" (CSSOM last-wins).
const animOf = (sel) => page.evaluate((s) => {
  const el = document.querySelector(s);
  if (!el) return { sel: s, missing: true };
  const cs = getComputedStyle(el);
  const a = el.getAnimations()[0];
  return {
    sel: s,
    name: cs.animationName,
    duration: cs.animationDuration,
    keyframes: a ? a.effect.getKeyframes().map((k) => ({ offset: k.computedOffset, opacity: k.opacity })) : null,
    color: cs.color,
  };
}, sel);

// ── state 1: Home chats strip — live / done-ok / done-err marks ──
await page.goto(BASE + "/work", { waitUntil: "domcontentloaded", timeout: 20000 });
await page.waitForFunction(() => document.querySelectorAll(".chat-row").length === 4, { timeout: 15000 });
await settle(600);
const stripAnim = await animOf(".chat-mark.live");
console.log("chat-mark.live →", JSON.stringify(stripAnim));
await freeze();
await settle(1200);
await snap("chat-strip");

// ── state 2: forest row ✦ badge (a live chat on the forest) ──
await page.goto(BASE + "/forests", { waitUntil: "domcontentloaded", timeout: 20000 });
await page.waitForSelector(".forest-chat", { timeout: 15000 });
const forestAnim = await animOf(".forest-chat");
console.log("forest-chat →", JSON.stringify(forestAnim));
await freeze();
await settle(1200);
await snap("forest-chat");

// ── states 3-7 need seeded threads + drawer; new page so evaluateOnNewDocument applies ──
const NODE_URL = BASE + "/forests/admin-user-memberships/" + BRANCH;

// state 3: file-rail chat buttons — working (pulsing), done ✓, and the 💬 badge; drawer closed
await page.evaluateOnNewDocument((threads) => {
  localStorage.setItem("viewer.chat.threads.v1", JSON.stringify(threads));
  localStorage.removeItem("stack-chat-drawer");
}, THREADS);
await page.goto(NODE_URL, { waitUntil: "domcontentloaded", timeout: 20000 });
await page.waitForSelector(".chat-act.working", { timeout: 15000 });
await page.waitForSelector(".chat-act.done", { timeout: 15000 });
await page.waitForSelector(".chat-badge", { timeout: 15000 });
const actAnim = await animOf(".chat-act.working");
console.log("chat-act.working →", JSON.stringify(actAnim));
await freeze();
await settle(1500);
await snap("chat-act");

// state 4: cross-forest chat index overlay (⋯ menu → all chat threads)
await page.click('button[aria-haspopup="true"]');
await page.waitForSelector(".nh-menu", { timeout: 10000 });
await page.evaluate(() => {
  const item = [...document.querySelectorAll(".nh-menu .nh-item")].find((b) => b.textContent.includes("all chat threads"));
  item.click();
});
await page.waitForSelector(".chat-index", { timeout: 10000 });
await page.waitForFunction(() => document.querySelectorAll(".ci-row").length === 3, { timeout: 10000 });
const ciAnim = await animOf(".ci-state.working");
console.log("ci-state.working →", JSON.stringify(ciAnim));
await settle(800);
await snap("chat-index");

// state 5: the chat drawer — turns (you/claude), markdown, action button, attachment chips
await page.evaluateOnNewDocument((threads, drawer) => {
  localStorage.setItem("viewer.chat.threads.v1", JSON.stringify(threads));
  localStorage.setItem("stack-chat-drawer", JSON.stringify(drawer));
}, THREADS, DRAWER);
await page.goto(NODE_URL, { waitUntil: "domcontentloaded", timeout: 20000 });
await page.waitForSelector(".cp", { timeout: 15000 });
await page.waitForSelector(".cp-action", { timeout: 10000 });
await page.waitForSelector(".cp-att-chip", { timeout: 10000 });
await freeze();
await settle(1500);
await snap("chat-panel");

// state 6: popout menu open (targets intercepted)
await page.click(".cp-popout");
await page.waitForSelector(".cp-popout-menu", { timeout: 10000 });
await page.waitForFunction(() => document.querySelectorAll(".cp-popout-item").length === 3, { timeout: 10000 });
await settle(500);
await snap("chat-popout");

// state 7: minimized pill, pinned to a branch you've navigated AWAY from (↗ return shows)
await page.evaluateOnNewDocument((threads, drawer) => {
  localStorage.setItem("viewer.chat.threads.v1", JSON.stringify(threads));
  localStorage.setItem("stack-chat-drawer", JSON.stringify(drawer));
}, THREADS, { ...DRAWER, minimized: true });
await page.goto(BASE + "/forests/admin-user-memberships/admin-user-membership-models", { waitUntil: "domcontentloaded", timeout: 20000 });
await page.waitForSelector(".cp-pill", { timeout: 15000 });
await page.waitForSelector(".cp-pill-go", { timeout: 10000 });
await freeze();
await settle(1500);
await snap("chat-pill");

await browser.close();
