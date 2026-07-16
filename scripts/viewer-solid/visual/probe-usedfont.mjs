// probe-usedfont — report the PLATFORM font the renderer actually used for a selector
// (computed font-family is just the request; this is what got rasterized).
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
await page.evaluate(() => document.fonts.ready);
const cdp = await page.createCDPSession();
await cdp.send("DOM.enable");
await cdp.send("CSS.enable");
const { root } = await cdp.send("DOM.getDocument");
for (const sel of SELS) {
  const { nodeId } = await cdp.send("DOM.querySelector", { nodeId: root.nodeId, selector: sel });
  if (!nodeId) {
    console.log(sel, "→ not found");
    continue;
  }
  const { fonts } = await cdp.send("CSS.getPlatformFontsForNode", { nodeId });
  console.log(sel, "→", JSON.stringify(fonts));
}
await browser.close();
