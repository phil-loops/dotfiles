// invariants — assert IDENTITY facts across every surface, not drift from a baseline.
// The pixel/geometry gates compare against baselines shot from some build — a defect present
// on day one is encoded as truth and no drift gate can ever see it (the Fraunces-eyebrow case:
// invisible at 10px caps in a reviewed screenshot, wrong on arrival for weeks). Invariants are
// build-independent: "every eyebrow label computes IBM Plex Mono" is checkable on ANY build.
//
//   node invariants.mjs --base http://127.0.0.1:7333
//
// Rules live in invariants.json: { selector, property, expect (prefix match), except? (selector
// the element may also match to be exempt) }. Checked on every surfaces.json route, post-clicks.
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
const BIN = process.env.CHROME_BIN
  ?? "/Users/philbrockman/.cache/puppeteer/chrome-headless-shell/mac_arm-150.0.7871.24/chrome-headless-shell-mac-arm64/chrome-headless-shell";

const surfaces = JSON.parse(readFileSync(join(HERE, "surfaces.json"), "utf8"));
const rules = JSON.parse(readFileSync(join(HERE, "invariants.json"), "utf8"));

const browser = await puppeteer.launch({ executablePath: BIN, headless: true });
let bad = 0;
for (const s of surfaces) {
  const page = await browser.newPage();
  await page.setViewport({ width: 1440, height: 900 });
  try {
    await page.goto(BASE + s.path, { waitUntil: "domcontentloaded", timeout: 20000 });
    if (s.waitFor) await page.waitForSelector(s.waitFor, { timeout: 15000 });
    for (const sel of s.clicks ?? []) {
      await page.waitForSelector(sel, { timeout: 10000 });
      await page.click(sel);
      await new Promise((r) => setTimeout(r, 400));
    }
    await new Promise((r) => setTimeout(r, 800));
    const violations = await page.evaluate((rules) => {
      const out = [];
      const pathOf = (el) => {
        const parts = [];
        while (el && el !== document.body) {
          const parent = el.parentElement;
          const idx = parent ? [...parent.children].indexOf(el) + 1 : 1;
          parts.unshift(`${el.tagName.toLowerCase()}[${idx}]`);
          el = parent;
        }
        return "/" + parts.join("/");
      };
      for (const r of rules) {
        for (const el of document.querySelectorAll(r.selector)) {
          if (r.except && el.matches(r.except)) continue;
          const got = getComputedStyle(el).getPropertyValue(r.property).trim();
          if (!got.startsWith(r.expect)) {
            out.push(`${r.selector} @ ${pathOf(el)}: ${r.property} = ${got.slice(0, 60)} (want ${r.expect}…)`);
          }
        }
      }
      return out;
    }, rules);
    if (violations.length) {
      console.error(`✗ ${s.name}:`);
      for (const v of violations.slice(0, 6)) console.error(`    ${v}`);
      if (violations.length > 6) console.error(`    … ${violations.length - 6} more`);
      bad += violations.length;
    } else {
      console.log(`✓ ${s.name}`);
    }
  } catch (e) {
    console.error(`✗ ${s.name}: ${e.message}`);
    bad++;
  }
  await page.close();
}
await browser.close();
process.exit(bad ? 1 : 0);
