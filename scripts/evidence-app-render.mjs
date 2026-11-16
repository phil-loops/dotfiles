// evidence-app-render.mjs — ONE attempt: capture an app recipe's scenes from a running server.
//
//   node evidence-app-render.mjs <base-url> <recipe-dir> <out-dir>      (NODE_PATH = node_modules with playwright)
//   env EVIDENCE_LOGIN = JSON {email, token}: a fresh magic-link token the caller stored for this attempt
//
// The server is the tree under test (a preview of exactly one commit); this script only drives it.
// Signs in through the app's own email callback (the repo's Playwright fixture does the same), sets the
// color scheme the way pages/_document.tsx reads it, and crops each scene to a fixed window at its field, recording where
// the field sits inside the crop so the caller can tell a change in the field from a change around it.
// out/result.json is written last — a dir without it is an incomplete attempt, never evidence.
import { createRequire } from "node:module";
import crypto from "node:crypto";
import fs from "node:fs";
import path from "node:path";

const [base, recipeDir, out] = process.argv.slice(2);
const need = createRequire(path.join(path.resolve(process.env.NODE_PATH || ""), "noop.js"));
const recipe = JSON.parse(fs.readFileSync(path.join(path.resolve(recipeDir), "recipe.json"), "utf8"));
const login = JSON.parse(process.env.EVIDENCE_LOGIN || "null");
const sha = (b) => crypto.createHash("sha256").update(b).digest("hex");
const fail = async (why, browser) => {
  fs.writeFileSync(path.join(out, "failed.json"), JSON.stringify({ why }, null, 1));
  console.error("evidence-app-render:", why);
  if (browser) await browser.close().catch(() => {});
  process.exit(1);
};
fs.mkdirSync(path.join(out, "scenes"), { recursive: true });

export function scenesOf(r) {
  return r.views.flatMap((v) => r.variants.map((x) => ({ ...v, ...x, id: `${v.id}-${x.id}`, title: `${v.title}, ${x.title}`, view: v.id })));
}

const { chromium } = need("playwright");
// GPU rasterization differs by a pixel or two between identical runs; admission needs identical bytes
const browser = await chromium.launch({
  channel: "chrome",
  args: ["--disable-gpu", "--disable-gpu-rasterization", "--force-color-profile=srgb", "--disable-lcd-text",
    "--font-render-hinting=none", "--disable-partial-raster", "--disable-skia-runtime-opts"],
});
const viewport = recipe.viewport || { width: 1440, height: 900 };

// ── sign in once; every scene context starts from these cookies ──
let storageState;
if (login) {
  const ctx = await browser.newContext();
  const q = new URLSearchParams({ callbackUrl: base + "/", token: login.token, email: login.email });
  const r = await ctx.request.get(`${base}/api/auth/callback/email?${q}`, { maxRedirects: 0 });
  storageState = await ctx.storageState();
  const signedIn = storageState.cookies.some((c) => /session-token/.test(c.name));
  await ctx.close();
  if (!signedIn) await fail(`sign-in failed: callback answered ${r.status()} ${r.headers().location || ""}`, browser);
}

const scenes = {};
for (const scene of scenesOf(recipe)) {
  const ctx = await browser.newContext({
    viewport, deviceScaleFactor: 2, colorScheme: scene.theme, reducedMotion: "reduce",
    serviceWorkers: "block", storageState, timezoneId: "UTC", locale: "en-US",
  });
  await ctx.addInitScript((theme) => { try { localStorage.setItem("colorScheme", theme); } catch {} }, scene.theme);
  const page = await ctx.newPage();
  const errors = [];
  page.on("pageerror", (e) => errors.push(String(e).slice(0, 300)));
  try {
    // a page that keeps a request open never goes network-idle, so settle with a bound; a step taken
    // before React hydrates is silently dropped, so wait for Next's router first
    const settle = () => page.waitForLoadState("networkidle", { timeout: 20_000 }).catch(() => {});
    await page.goto(base + scene.path, { waitUntil: "load", timeout: 600_000 });
    await page.waitForFunction(() => window.next?.router?.isReady === true, null, { timeout: 120_000 });
    await settle();
    for (const step of scene.steps || []) {
      if (step.click) await page.locator(step.click).first().click();
      if (step.fill) await page.locator(step.fill[0]).first().fill(step.fill[1]);
      if (step.press) await page.locator(step.press[0]).first().press(step.press[1]);
      if (step.select) await page.locator(step.select[0]).first().selectOption(step.select[1]);
      await settle();
    }
    const field = page.locator(scene.field).first();
    await field.waitFor({ state: "visible", timeout: 60_000 });
    await field.scrollIntoViewIfNeeded();
    if (scene.focus) await field.focus();
    else await page.evaluate(() => document.activeElement instanceof HTMLElement && document.activeElement.blur());
    await page.evaluate(() => document.fonts.ready);
    await page.mouse.move(0, 0);
    // a fixed window anchored at the field's corner: the same size on both sides, so a field that grows
    // shows as change inside the window instead of a differently sized picture
    const box = await field.evaluate((f, { pad, win, theme }) => {
      const fr = f.getBoundingClientRect();
      const fit = (want, size, room) => Math.max(0, Math.min(want, room - size));
      const clip = { x: fit(fr.left - pad, win[0], innerWidth), y: fit(fr.top - pad, win[1], innerHeight), width: win[0], height: win[1] };
      return {
        clip, field: [fr.left - clip.x, fr.top - clip.y, fr.width, fr.height],
        checks: { theme: document.documentElement.classList.contains(theme), focus: document.activeElement === f },
      };
    }, { pad: scene.pad ?? 24, win: scene.window || [560, 140], theme: scene.theme });
    const checks = { theme: box.checks.theme, focus: box.checks.focus === Boolean(scene.focus) };
    const failed = Object.entries(checks).filter(([, ok]) => !ok).map(([k]) => k);
    if (failed.length) await fail(`scene ${scene.id}: precondition failed: ${failed.join(", ")}`, browser);
    const png = await page.screenshot({
      clip: box.clip, animations: "disabled", caret: "hide",
      mask: (scene.mask || recipe.mask || []).map((m) => page.locator(m)), maskColor: "#FF00FF",
    });
    fs.writeFileSync(path.join(out, "scenes", `${scene.id}.png`), png);
    scenes[scene.id] = { sha: sha(png), checks, field: box.field.map((n) => Math.round(n * 2)), errors };
  } catch (e) {
    await page.screenshot({ path: path.join(out, `failed-${scene.id}.png`), fullPage: true }).catch(() => {});
    await fail(`scene ${scene.id}: ${String(e.message || e).split("\n")[0]}`, browser);
  }
  await ctx.close();
}
const browserVersion = browser.version();
await browser.close();
const result = { scenes, build: { base }, browser: browserVersion };
fs.writeFileSync(path.join(out, "result.json.tmp"), JSON.stringify(result, null, 1));
fs.renameSync(path.join(out, "result.json.tmp"), path.join(out, "result.json"));
