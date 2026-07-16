// probe-full — dump EVERY computed style of the first match of each selector, as JSON.
//   node probe-full.mjs --path /x --sel ".a,.b" > styles.json
import puppeteer from "puppeteer-core";

const arg = (n, d) => {
  const i = process.argv.indexOf("--" + n);
  return i === -1 ? d : process.argv[i + 1];
};
const BASE = arg("base", "http://127.0.0.1:7333");
const PATH = arg("path", "/work");
const SELS = arg("sel", "body").split(",");
const BIN = process.env.CHROME_BIN
  ?? "/Users/philbrockman/.cache/puppeteer/chrome-headless-shell/mac_arm-150.0.7871.24/chrome-headless-shell-mac-arm64/chrome-headless-shell";

const browser = await puppeteer.launch({ executablePath: BIN, headless: true });
const page = await browser.newPage();
await page.setViewport({ width: 1440, height: 900 });
await page.goto(BASE + PATH, { waitUntil: "domcontentloaded", timeout: 20000 });
await new Promise((r) => setTimeout(r, 3500));
const out = {};
for (const sel of SELS) {
  out[sel] = await page.evaluate((s) => {
    const el = document.querySelector(s);
    if (!el) return null;
    const cs = getComputedStyle(el);
    const o = {};
    for (const p of cs) o[p] = cs.getPropertyValue(p);
    return o;
  }, sel);
}
console.log(JSON.stringify(out, null, 1));
await browser.close();
