// shot-all — screenshot every surface in surfaces.json against a fixture-server.
// Animations/transitions/caret are disabled so shots are pixel-deterministic; Google-hosted
// fonts are pinned via fixtures/fonts (recorded on first run with RECORD_FONTS=1).
//
//   node shot-all.mjs --base http://127.0.0.1:7333 --out ./baseline
import puppeteer from "puppeteer-core";
import { createHash } from "node:crypto";
import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const HERE = dirname(fileURLToPath(import.meta.url));
const arg = (name, dflt) => {
  const i = process.argv.indexOf("--" + name);
  return i === -1 ? dflt : process.argv[i + 1];
};
const BASE = arg("base", "http://127.0.0.1:7333");
const OUT = arg("out", join(HERE, "baseline"));
const BIN = process.env.CHROME_BIN
  ?? "/Users/philbrockman/.cache/puppeteer/chrome-headless-shell/mac_arm-150.0.7871.24/chrome-headless-shell-mac-arm64/chrome-headless-shell";
const FONTS = join(HERE, "fixtures", "fonts");
const RECORD_FONTS = process.env.RECORD_FONTS === "1";

const FREEZE_CSS = `
*, *::before, *::after { animation: none !important; transition: none !important; caret-color: transparent !important; }
html { scrollbar-width: none !important; }
::-webkit-scrollbar { display: none !important; }
`;

mkdirSync(OUT, { recursive: true });
mkdirSync(FONTS, { recursive: true });
const keyOf = (url) => createHash("sha1").update(url).digest("hex").slice(0, 24);

const surfaces = JSON.parse(readFileSync(join(HERE, "surfaces.json"), "utf8"));
const browser = await puppeteer.launch({ executablePath: BIN, headless: true });
let failed = 0;

for (const s of surfaces) {
  const page = await browser.newPage();
  await page.setViewport({ width: 1440, height: 900, deviceScaleFactor: 2 });

  // pin external fonts to fixtures — a replay run never touches the network.
  await page.setRequestInterception(true);
  page.on("request", async (req) => {
    const url = req.url();
    if (!url.startsWith("https://fonts.")) return req.continue();
    const base = join(FONTS, keyOf(url));
    if (existsSync(base + ".bin")) {
      const { type } = JSON.parse(readFileSync(base + ".meta", "utf8"));
      return req.respond({ status: 200, contentType: type, body: readFileSync(base + ".bin") });
    }
    if (RECORD_FONTS) {
      const r = await fetch(url, { headers: { "User-Agent": await browser.userAgent() } });
      const body = Buffer.from(await r.arrayBuffer());
      const type = r.headers.get("content-type") ?? "font/woff2";
      writeFileSync(base + ".bin", body);
      writeFileSync(base + ".meta", JSON.stringify({ url, type }));
      return req.respond({ status: 200, contentType: type, body });
    }
    console.error(`  font MISS (run once with RECORD_FONTS=1): ${url}`);
    failed++;
    return req.abort();
  });

  try {
    await page.goto(BASE + s.path, { waitUntil: "domcontentloaded", timeout: 20000 });
    await page.evaluate((css) => {
      const el = document.createElement("style");
      el.textContent = css;
      document.head.appendChild(el);
    }, FREEZE_CSS);
    if (s.waitFor) await page.waitForSelector(s.waitFor, { timeout: 15000 });
    for (const sel of s.clicks ?? []) {
      await page.waitForSelector(sel, { timeout: 10000 });
      await page.click(sel);
      await new Promise((r) => setTimeout(r, 400));
    }
    if (s.waitAfter) await page.waitForSelector(s.waitAfter, { timeout: 15000 });
    await new Promise((r) => setTimeout(r, s.settle ?? 1500));
    await page.evaluate(() => document.fonts.ready);
    await page.screenshot({ path: join(OUT, s.name + ".png") });
    console.log(`  ✓ ${s.name}`);
  } catch (e) {
    console.error(`  ✗ ${s.name}: ${e.message}`);
    failed++;
  }
  await page.close();
}

await browser.close();
process.exit(failed ? 1 : 0);
