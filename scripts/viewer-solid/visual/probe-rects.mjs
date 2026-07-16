// probe-rects — walk every element on a surface, emit "path → rect" lines (document order).
// Diff two runs to find the FIRST element whose geometry moved: the reflow origin.
//   node probe-rects.mjs --path /forests > rects.txt
import puppeteer from "puppeteer-core";

const arg = (n, d) => {
  const i = process.argv.indexOf("--" + n);
  return i === -1 ? d : process.argv[i + 1];
};
const BASE = arg("base", "http://127.0.0.1:7333");
const PATH = arg("path", "/work");
const BIN = process.env.CHROME_BIN
  ?? "/Users/philbrockman/.cache/puppeteer/chrome-headless-shell/mac_arm-150.0.7871.24/chrome-headless-shell-mac-arm64/chrome-headless-shell";

const browser = await puppeteer.launch({ executablePath: BIN, headless: true });
const page = await browser.newPage();
await page.setViewport({ width: 1440, height: 900 });
await page.goto(BASE + PATH, { waitUntil: "domcontentloaded", timeout: 20000 });
await new Promise((r) => setTimeout(r, 3500));
const lines = await page.evaluate(() => {
  const out = [];
  const seen = new Map();
  for (const el of document.querySelectorAll("*")) {
    if (["SCRIPT", "STYLE", "LINK", "META"].includes(el.tagName)) continue;
    const cls = [...el.classList].sort().join(".");
    const base = el.tagName.toLowerCase() + (cls ? "." + cls : "");
    const n = (seen.get(base) ?? 0) + 1;
    seen.set(base, n);
    const r = el.getBoundingClientRect();
    out.push(`${base}#${n} → ${Math.round(r.x)},${Math.round(r.y)} ${Math.round(r.width)}x${Math.round(r.height)}`);
  }
  return out;
});
console.log(lines.join("\n"));
await browser.close();
