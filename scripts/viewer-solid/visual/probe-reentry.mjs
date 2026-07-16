// scratch probe: force ReEntry to render by seeding the last-seen anchor to epoch,
// then emit probe-rects-style geometry lines + a full-page screenshot for pixel parity.
import puppeteer from "puppeteer-core";

const arg = (n, d) => {
  const i = process.argv.indexOf("--" + n);
  return i === -1 ? d : process.argv[i + 1];
};
const BASE = arg("base", "http://127.0.0.1:7433");
const SHOT = arg("shot", "/tmp/reentry.png");
const BIN = process.env.CHROME_BIN
  ?? "/Users/philbrockman/.cache/puppeteer/chrome-headless-shell/mac_arm-150.0.7871.24/chrome-headless-shell-mac-arm64/chrome-headless-shell";

const browser = await puppeteer.launch({ executablePath: BIN, headless: true });
const page = await browser.newPage();
await page.setViewport({ width: 1440, height: 900, deviceScaleFactor: 2 });
await page.evaluateOnNewDocument(() => localStorage.setItem("viewerLastSeen", "1"));
await page.goto(BASE + "/work", { waitUntil: "domcontentloaded", timeout: 20000 });
await page.waitForSelector(".reentry", { timeout: 15000 });
await new Promise((r) => setTimeout(r, 2500));
const lines = await page.evaluate(() => {
  const out = [];
  const seen = new Map();
  for (const el of document.querySelectorAll(".reentry, .reentry *")) {
    const cls = [...el.classList].sort().join(".");
    const base = el.tagName.toLowerCase() + (cls ? "." + cls : "");
    const n = (seen.get(base) ?? 0) + 1;
    seen.set(base, n);
    const r = el.getBoundingClientRect();
    out.push(`${base}#${n} → ${Math.round(r.x)},${Math.round(r.y)} ${Math.round(r.width)}x${Math.round(r.height)}`);
  }
  return out;
});
const el = await page.$(".reentry");
await el.screenshot({ path: SHOT });
console.log(lines.join("\n"));
await browser.close();
