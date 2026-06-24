// viewer-verify — headless smoke-test of the blessed forest viewer in a REAL browser.
//
// Why this exists: the Claude browser extension isn't connected and raw `chrome --screenshot`
// HANGS on this app (the /events SSE never lets the page reach idle). Playwright (already a dep
// in the loops checkout) drives system Chrome and lets us ABORT /events so the page settles —
// then we screenshot + assert the new surfaces render. This is the harness the CLAUDE.md
// "use Puppeteer/Playwright" note points at.
//
//   node ~/.dotfiles/scripts/viewer-verify.mjs [BASE_URL] [path1 path2 ...]
//   defaults: BASE from $VIEWER_BASE or http://127.0.0.1:62497, a couple of representative paths.
//
// Resolves playwright from the loops checkout (where it's installed); screenshots land in /tmp.
import { createRequire } from "module";
const require = createRequire(process.env.LOOPS_DIR || "/Users/philbrockman/coding/loops/");
const { chromium } = require("playwright");

const CHROME = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome";
const args = process.argv.slice(2);
const BASE = (args[0]?.startsWith("http") ? args.shift() : null) || process.env.VIEWER_BASE || "http://127.0.0.1:62497";
const paths = args.length ? args : ["/", "/forests", "/watching"];

const browser = await chromium.launch({ executablePath: CHROME, headless: true });
const page = await browser.newPage({ viewport: { width: 1500, height: 950 } });
await page.route("**/events", (r) => r.abort()); // the SSE that hangs raw headless
page.on("pageerror", (e) => console.log("  PAGEERROR:", e.message));

let bad = 0;
for (const p of paths) {
  // 'load' not 'networkidle' — the app polls, so it never idles; the DOM is ready at load.
  await page.goto(BASE + p, { waitUntil: "load", timeout: 15000 }).catch((e) => console.log("  goto failed:", e.message));
  await page.waitForTimeout(1400); // let solid-query settle model/health fetches
  const text = (await page.textContent("body").catch(() => "")) || "";
  const name = p.replace(/[^a-z0-9]+/gi, "-").replace(/^-|-$/g, "") || "root";
  await page.screenshot({ path: `/tmp/vv-${name}.png` });
  const ok = text.trim().length > 40;
  if (!ok) bad++;
  console.log(`  ${ok ? "✓" : "✗ BLANK"}  ${p}  (${text.trim().length} chars)  → /tmp/vv-${name}.png`);
}
await browser.close();
console.log(bad ? `\n${bad} blank page(s) — FAIL` : "\nall pages rendered ✓");
process.exit(bad ? 1 : 0);
