// probe-overflow — find horizontal spill: routes × widths, report scrollWidth vs viewport
// and the elements whose right edge escapes (deepest offenders first).
//   node probe-overflow.mjs --base http://127.0.0.1:7333 [--widths 1280,1440,1512,1600]
import puppeteer from "puppeteer-core";
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const HERE = dirname(fileURLToPath(import.meta.url));
const arg = (n, d) => {
  const i = process.argv.indexOf("--" + n);
  return i === -1 ? d : process.argv[i + 1];
};
const BASE = arg("base", "http://127.0.0.1:7333");
const WIDTHS = (arg("widths", "1280,1440,1512,1600")).split(",").map(Number);
const BIN = process.env.CHROME_BIN
  ?? "/Users/philbrockman/.cache/puppeteer/chrome-headless-shell/mac_arm-150.0.7871.24/chrome-headless-shell-mac-arm64/chrome-headless-shell";

const surfaces = JSON.parse(readFileSync(join(HERE, "surfaces.json"), "utf8"));
const browser = await puppeteer.launch({ executablePath: BIN, headless: true });
let spills = 0;
for (const w of WIDTHS) {
  for (const s of surfaces) {
    const page = await browser.newPage();
    await page.setViewport({ width: w, height: 900 });
    try {
      await page.goto(BASE + s.path, { waitUntil: "domcontentloaded", timeout: 20000 });
      if (s.waitFor) await page.waitForSelector(s.waitFor, { timeout: 15000 });
      for (const sel of s.clicks ?? []) {
        await page.waitForSelector(sel, { timeout: 10000 });
        await page.click(sel);
        await new Promise((r) => setTimeout(r, 400));
      }
      await new Promise((r) => setTimeout(r, 1200));
      const r = await page.evaluate(() => {
        const vw = document.documentElement.clientWidth;
        const sw = document.documentElement.scrollWidth;
        if (sw <= vw) return null;
        // offenders: elements poking past the viewport, deepest (most specific) first
        const out = [];
        for (const el of document.querySelectorAll("*")) {
          const b = el.getBoundingClientRect();
          if (b.right > vw + 1 && b.width > 0) {
            out.push({
              sel: el.tagName.toLowerCase() + (el.classList.length ? "." + [...el.classList].slice(0, 3).join(".") : ""),
              right: Math.round(b.right), width: Math.round(b.width),
              depth: (function d(e) { let n = 0; while (e.parentElement) { n++; e = e.parentElement; } return n; })(el),
            });
          }
        }
        out.sort((a, b) => b.depth - a.depth);
        return { vw, sw, offenders: out.slice(0, 5) };
      });
      if (r) {
        spills++;
        console.error(`✗ ${s.name} @ ${w}px: scrollWidth ${r.sw} > viewport ${r.vw} (+${r.sw - r.vw}px)`);
        for (const o of r.offenders) console.error(`    ${o.sel} → right ${o.right}, width ${o.width}`);
      }
    } catch (e) {
      console.error(`? ${s.name} @ ${w}px: ${e.message}`);
    }
    await page.close();
  }
  if (!spills) console.log(`✓ no spill at ${w}px (all surfaces)`);
}
process.exit(spills ? 1 : 0);
