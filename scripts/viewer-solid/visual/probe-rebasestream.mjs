// probe: force the ejected-rebase live stream (RebaseStream) open — intercept the sync
// state to make the branch syncable, click the spine's ⟲ sync edge, answer POST /sync with
// the eject verdict ({ok, rebased:false}), and own POST /rebase-stream with a synthetic SSE
// body. Two states: live (spinner, status, streamed markdown incl. a pre block, take-over +
// stop buttons) and settled (event:gone terminal — title swap, lone ✕). Emits shot-all-format
// png + rects.txt per state so diff.mjs can gate before/after.
import puppeteer from "puppeteer-core";
import { createHash } from "node:crypto";
import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const HERE = dirname(fileURLToPath(import.meta.url));
const arg = (n, d) => { const i = process.argv.indexOf("--" + n); return i === -1 ? d : process.argv[i + 1]; };
const BASE = arg("base", "http://127.0.0.1:7461");
const OUT = arg("out", "/tmp/rebasestream-probe");
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
const SYNC_STATE = {
  branch: BRANCH, behind: 6, parent: "main", published: true, syncable: true, restack: false,
  project: "admin-user-memberships", shared: "synced", aheadOfOrigin: 0,
  dirty: [], dirtyWorktree: "", deployCritical: [], why: "",
};
const sse = (frames) => frames.map((f) => `event: ${f.event}\ndata: ${JSON.stringify(f.data)}\n\n`).join("");
const LIVE_BODY = sse([
  { event: "session", data: { session_id: "sess-0123456789abcdef" } },
  { event: "status", data: { s: "resolving queries/user.ts" } },
  { event: "token", data: { t: "Rebasing onto `origin/main` — one conflict in " } },
  { event: "token", data: { t: "`queries/user.ts`.\n\n```ts\nexport async function findByIdOrEmail(idOrEmail: string) {\n  return rows.at(0) ?? null;\n}\n```\n\n" } },
  { event: "token", data: { t: "Taking the branch's version of the helper and replaying the remaining commits." } },
]);
const GONE_BODY = sse([
  { event: "status", data: { s: "starting" } },
  { event: "token", data: { t: "Picking the rebase job back up…" } },
  { event: "gone", data: {} },
]);

let streamBody = LIVE_BODY;

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
  if (u.pathname.endsWith("/sync") && req.method() === "GET") return json(SYNC_STATE);
  if (u.pathname.endsWith("/sync") && req.method() === "POST") return json({ ok: true, rebased: false });
  if (u.pathname.endsWith("/rebase-stream")) {
    return req.respond({ status: 200, contentType: "text/event-stream", body: streamBody });
  }
  if (u.pathname.endsWith("/rebase-stop")) return json({ ok: true });
  if (u.pathname.endsWith("/chat-popout")) return json({ ok: true });
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

const openStream = async () => {
  await page.goto(BASE + "/forests/admin-user-memberships/" + BRANCH, { waitUntil: "domcontentloaded", timeout: 20000 });
  await page.evaluate((css) => { const el = document.createElement("style"); el.textContent = css; document.head.appendChild(el); }, FREEZE_CSS);
  await page.waitForSelector(".entry", { timeout: 20000 });
  await page.waitForSelector(".spine-slot", { timeout: 15000 });
  await settle(1500);
  // the edge must be inside the viewport — a below-the-fold click silently no-ops
  const visible = await page.evaluate(() => {
    const el = document.querySelector(".spine-slot");
    const r = el?.getBoundingClientRect();
    return !!r && r.y >= 0 && r.y < window.innerHeight;
  });
  if (!visible) { console.error("✗ .spine-slot outside the viewport"); process.exit(2); }
  await page.click(".spine-slot");
  await page.waitForSelector(".rebase-stream", { timeout: 15000 });
};

// state 1: live — spinner title, take over + ■ stop + ✕, streamed markdown body with a pre
streamBody = LIVE_BODY;
await openStream();
await page.waitForSelector(".rs-body pre", { timeout: 10000 });
await settle(1200);
await snap("rebasestream-live");

// state 2: settled — the job's gone terminal; title swaps to patina, buttons collapse to ✕
streamBody = GONE_BODY;
await openStream();
await page.waitForFunction(() => document.querySelector(".rs-title")?.textContent?.includes("rebase job gone"), { timeout: 10000 });
await settle(1200);
await snap("rebasestream-gone");

await browser.close();
