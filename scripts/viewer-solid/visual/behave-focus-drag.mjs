// behave-focus-drag — BEHAVIOR probe for the FocusLane pointer-drag (pin at position,
// sideways unpin, optimistic paint). The pixel/geometry/invariant gates cannot see any of
// this: all 9 surfaces stay green with the drag fully dead. Adapted from 5bf6bd76's live
// verify scripts to be fixture-safe — every network effect is owned here, so it NEVER
// mutates a real focus lane. Run against a fixture-server:
//
//   node behave-focus-drag.mjs --base http://127.0.0.1:7333
//
// Asserts the CLIENT contract only: drag affordances (ghost, drop-line, hot lane), the
// optimistic reorder painting BEFORE the held /focus response lands, the POST payload
// firing, and the unpin mid-state. Server reconciliation is deliberately out of scope
// (the fixture is stateless; the lane reverting on refetch here is expected).
import puppeteer from "puppeteer-core";

const arg = (n, d) => {
  const i = process.argv.indexOf("--" + n);
  return i === -1 ? d : process.argv[i + 1];
};
const BASE = arg("base", "http://127.0.0.1:7333");
const BIN = process.env.CHROME_BIN
  ?? "/Users/philbrockman/.cache/puppeteer/chrome-headless-shell/mac_arm-150.0.7871.24/chrome-headless-shell-mac-arm64/chrome-headless-shell";
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

const browser = await puppeteer.launch({ executablePath: BIN, headless: true });
const page = await browser.newPage();
// The viewport must hold BOTH the lane (page top) and the first draggable row: synthetic
// pointer events below the fold silently no-op, which reads as "feature broken". That false
// signal bisected cleanly to an innocent commit that merely made the page taller (the
// forgotten band) before the real cause surfaced — size generously and assert visibility.
await page.setViewport({ width: 1440, height: 2600 });

// own the network: hold /focus responses 1200ms (optimistic paint must beat them),
// capture their payloads, and answer from here — nothing reaches any real server but
// the fixture GETs.
const focusPosts = [];
await page.setRequestInterception(true);
page.on("request", async (req) => {
  if (req.method() === "POST" && new URL(req.url()).pathname === "/focus") {
    focusPosts.push(req.postData() ?? "");
    await sleep(1200);
    return req.respond({ status: 200, contentType: "application/json", body: '{"ok":true}' });
  }
  if (req.method() === "POST") {
    return req.respond({ status: 200, contentType: "application/json", body: "{}" });
  }
  return req.continue();
});

const fail = (msg) => {
  console.error(`✗ ${msg}`);
  process.exitCode = 1;
};
const ok = (msg) => console.log(`✓ ${msg}`);

await page.goto(BASE + "/forests", { waitUntil: "domcontentloaded", timeout: 20000 });
await page.waitForSelector(".focus-lane", { timeout: 15000 });
await sleep(1500);

const laneNames = () => page.$$eval(".focus-row .focus-name", (els) => els.map((e) => e.textContent.trim()));
const before = await laneNames();
if (before.length < 2) {
  fail(`need ≥2 lane rows to target a drop slot, fixture has ${before.length}`);
  await browser.close();
  process.exit(1);
}

// grip the first tier row, drag into the lane between rows 1 and 2
const wrap = await page.waitForSelector(".row-drag-wrap", { timeout: 5000 });
const inView = await wrap.evaluate((el) => {
  const r = el.getBoundingClientRect();
  return r.top >= 0 && r.bottom <= window.innerHeight;
});
if (!inView) {
  fail("first draggable row is outside the viewport — grow the viewport; pointer events below the fold no-op");
  await browser.close();
  process.exit(1);
}
await wrap.hover();
await sleep(300);
const grip = await wrap.$(".row-drag-grip");
const gb = grip && (await grip.boundingBox());
if (!gb) {
  fail("drag grip missing or invisible on hover");
  await browser.close();
  process.exit(1);
}
ok("grip appears on row hover");

const rows = await page.$$(".focus-row");
const r0 = await rows[0].boundingBox();
const r1 = await rows[1].boundingBox();
await page.mouse.move(gb.x + gb.width / 2, gb.y + gb.height / 2);
await page.mouse.down();
for (let i = 1; i <= 12; i++) {
  await page.mouse.move(
    gb.x + ((r0.x + r0.width / 2) - gb.x) * (i / 12),
    gb.y + (((r0.y + r0.height + r1.y) / 2) - gb.y) * (i / 12));
  await sleep(25);
}
await sleep(200);
const mid = await page.evaluate(() => ({
  ghost: !!document.querySelector(".drag-ghost"),
  line: !!document.querySelector(".focus-drop-line"),
  hot: !!document.querySelector(".focus-lane.drop-target"),
}));
mid.ghost ? ok("drag ghost renders") : fail("no .drag-ghost mid-drag");
mid.line ? ok("drop line renders") : fail("no .focus-drop-line mid-drag");
mid.hot ? ok("lane goes hot as drop target") : fail("no .focus-lane.drop-target mid-drag");

await page.mouse.up();
await sleep(80);
const atDrop = await laneNames();
if (atDrop.length === before.length + 1) {
  ok(`pin paints optimistically (+1 row at 80ms, response still held; pinned "${atDrop[1]}")`);
} else {
  fail(`NOT optimistic: lane ${before.length}→${atDrop.length} rows 80ms after drop`);
}
if (focusPosts.length >= 1) {
  ok(`POST /focus fired (payload: ${focusPosts[0]?.slice(0, 80)})`);
} else {
  fail("no POST /focus fired on drop");
}

// sideways unpin of the row we just added, before any settle
const rows2 = await page.$$(".focus-row");
const grip2 = rows2[1] && (await rows2[1].$(".focus-grip"));
const g2 = grip2 && (await grip2.boundingBox());
if (!g2) {
  fail("pinned row has no .focus-grip");
} else {
  await page.mouse.move(g2.x + g2.width / 2, g2.y + g2.height / 2);
  await page.mouse.down();
  for (let i = 1; i <= 10; i++) {
    await page.mouse.move(g2.x + g2.width / 2 + i * 18, g2.y + g2.height / 2);
    await sleep(25);
  }
  await sleep(150);
  const unpinning = await page.evaluate(() => !!document.querySelector(".focus-row.unpinning"));
  unpinning ? ok("sideways drag arms the unpin state") : fail("no .focus-row.unpinning during sideways drag");
  await page.mouse.up();
  await sleep(80);
  const atUnpin = await laneNames();
  if (atUnpin.length === before.length) {
    ok("unpin paints optimistically (row gone at 80ms)");
  } else {
    fail(`NOT optimistic: ${atUnpin.length} rows 80ms after unpin (want ${before.length})`);
  }
  if (focusPosts.length >= 2) {
    ok(`second POST /focus fired (payload: ${focusPosts[1]?.slice(0, 80)})`);
  } else {
    fail("no POST /focus fired on unpin");
  }
}

await browser.close();
console.log(process.exitCode ? "BEHAVIOR: FAIL" : "BEHAVIOR: OK");
