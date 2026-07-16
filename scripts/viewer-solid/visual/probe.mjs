// probe — dump computed styles for selectors on a surface (reconciliation forensics).
//   node probe.mjs --path /forests/x/y --sel ".d2h-code-line-ctn,.d2h-diff-table td"
import puppeteer from "puppeteer-core";

const arg = (n, d) => {
  const i = process.argv.indexOf("--" + n);
  return i === -1 ? d : process.argv[i + 1];
};
const BASE = arg("base", "http://127.0.0.1:7333");
const PATH = arg("path", "/work");
const SELS = arg("sel", "body").split(",");
const PROPS = (arg("props", "font-family,font-size,line-height,white-space,border-collapse,padding,margin,letter-spacing")).split(",");
const BIN = process.env.CHROME_BIN
  ?? "/Users/philbrockman/.cache/puppeteer/chrome-headless-shell/mac_arm-150.0.7871.24/chrome-headless-shell-mac-arm64/chrome-headless-shell";

const browser = await puppeteer.launch({ executablePath: BIN, headless: true });
const page = await browser.newPage();
await page.setViewport({ width: 1440, height: 900 });
await page.goto(BASE + PATH, { waitUntil: "domcontentloaded", timeout: 20000 });
await new Promise((r) => setTimeout(r, 3500));
for (const sel of SELS) {
  const out = await page.evaluate((s, props) => {
    const el = document.querySelector(s);
    if (!el) return null;
    const cs = getComputedStyle(el);
    const o = { tag: el.tagName, rect: el.getBoundingClientRect().width };
    for (const p of props) o[p] = cs.getPropertyValue(p);
    return o;
  }, sel, PROPS);
  console.log(sel, "→", JSON.stringify(out));
}
await browser.close();
