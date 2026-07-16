// scratch probe: force the DivergedDetailPanel to render on the node-detail surface by
// intercepting forest-health (mark the active branch diverged) and diverged-detail
// (synthetic payload exercising overlap verdict, ahead/behind twins, all prFiles states),
// then open the ⋯ menu and click "inspect divergence". Emits rects + element screenshot.
import puppeteer from "puppeteer-core";

const arg = (n, d) => {
  const i = process.argv.indexOf("--" + n);
  return i === -1 ? d : process.argv[i + 1];
};
const BASE = arg("base", "http://127.0.0.1:7433");
const SHOT = arg("shot", "/tmp/diverged.png");
const BIN = process.env.CHROME_BIN
  ?? "/Users/philbrockman/.cache/puppeteer/chrome-headless-shell/mac_arm-150.0.7871.24/chrome-headless-shell-mac-arm64/chrome-headless-shell";

const BRANCH = "admin-user-membership-queries";
const DETAIL = {
  ok: true,
  upstream: "origin/" + BRANCH,
  trunk: "origin/main",
  ahead: [
    { sha: "aaa1111", subject: "queries: add membership lookups", matched: true, fromMain: false },
    { sha: "bbb2222", subject: "chore: restack onto main", matched: false, fromMain: true },
    { sha: "ccc3333", subject: "queries: cover deleted teams", matched: false, fromMain: false },
  ],
  behind: [
    { sha: "ddd4444", subject: "queries: add membership lookups", matched: true },
    { sha: "eee5555", subject: "wip: old approach", matched: false },
  ],
  containment: "overlap",
  overlap: ["src/queries/team-membership.ts", "src/queries/user.ts"],
  prNow: "+120 −4 across 3 files",
  prAfter: "+134 −6 across 4 files",
  prFiles: [
    { path: "src/queries/team-membership.ts", status: "changed", now: "+80 −2", after: "+92 −4" },
    { path: "src/queries/user.ts", status: "same", now: "+30 −2", after: "+30 −2" },
    { path: "src/queries/team.ts", status: "enters", now: null, after: "+12 −0" },
    { path: "src/queries/legacy.ts", status: "leaves", now: "+10 −0", after: null },
  ],
};

const browser = await puppeteer.launch({ executablePath: BIN, headless: true });
const page = await browser.newPage();
await page.setViewport({ width: 1440, height: 900, deviceScaleFactor: 2 });
await page.setRequestInterception(true);
page.on("request", (req) => {
  const u = new URL(req.url());
  if (u.pathname.endsWith("/forest-health")) {
    const body = {};
    for (const b of u.searchParams.getAll("branch")) {
      body[b] = { drifted: false, merged: false, diverged: b === BRANCH, ahead: 3, behind: 2, upstream: "origin/" + b };
    }
    req.respond({ status: 200, contentType: "application/json", body: JSON.stringify(body) });
    return;
  }
  if (u.pathname.endsWith("/diverged-detail")) {
    req.respond({ status: 200, contentType: "application/json", body: JSON.stringify(DETAIL) });
    return;
  }
  req.continue();
});
await page.goto(BASE + "/forests/admin-user-memberships/" + BRANCH, { waitUntil: "domcontentloaded", timeout: 20000 });
await page.waitForSelector(".entry", { timeout: 20000 });
await new Promise((r) => setTimeout(r, 2000));
await page.click(".icon-btn[aria-haspopup='true']");
await page.waitForSelector(".nh-menu", { timeout: 10000 });
const clicked = await page.evaluate(() => {
  const item = [...document.querySelectorAll(".nh-item")].find((b) => b.textContent.includes("inspect divergence"));
  if (!item) return false;
  item.click();
  return true;
});
if (!clicked) {
  console.error("inspect divergence item not found");
  process.exit(2);
}
await page.waitForSelector(".nh-diverged-detail", { timeout: 10000 });
await new Promise((r) => setTimeout(r, 1500));
const lines = await page.evaluate(() => {
  const out = [];
  const seen = new Map();
  for (const el of document.querySelectorAll(".nh-diverged-detail, .nh-diverged-detail *")) {
    const cls = [...el.classList].sort().join(".");
    const base = el.tagName.toLowerCase() + (cls ? "." + cls : "");
    const n = (seen.get(base) ?? 0) + 1;
    seen.set(base, n);
    const r = el.getBoundingClientRect();
    out.push(`${base}#${n} → ${Math.round(r.x)},${Math.round(r.y)} ${Math.round(r.width)}x${Math.round(r.height)}`);
  }
  return out;
});
const el = await page.$(".nh-diverged-detail");
await el.screenshot({ path: SHOT });
console.log(lines.join("\n"));
await browser.close();
