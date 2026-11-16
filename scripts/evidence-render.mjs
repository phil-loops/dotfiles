// evidence-render.mjs — ONE attempt: render one recipe's scenes from one tree snapshot.
//
//   node evidence-render.mjs <snapshot-dir> <recipe-dir> <out-dir>     (NODE_PATH = the donor node_modules)
//
// Everything the page consumes comes from the snapshot (component source, tailwind config, styles,
// fonts) or from the donor packages the caller pinned (react, react-dom, tailwind, postcss, esbuild,
// playwright). Every module esbuild resolves and every request the page makes is recorded; anything
// outside those roots fails the attempt rather than rendering foreign code. out/result.json is
// written last — a dir without it is an incomplete attempt, never evidence.
import { createRequire } from "node:module";
import crypto from "node:crypto";
import fs from "node:fs";
import path from "node:path";

const [snap, recipeDir, out] = process.argv.slice(2).map((p) => path.resolve(p));
const donor = path.resolve(process.env.NODE_PATH || "");
const need = createRequire(path.join(donor, "noop.js"));
const recipe = JSON.parse(fs.readFileSync(path.join(recipeDir, "recipe.json"), "utf8"));
const sha = (b) => crypto.createHash("sha256").update(b).digest("hex");
const fail = (why) => {
  fs.writeFileSync(path.join(out, "failed.json"), JSON.stringify({ why }, null, 1));
  console.error("evidence-render:", why);
  process.exit(1);
};
const under = (p, root) => p === root || p.startsWith(root + path.sep);

fs.mkdirSync(path.join(out, "scenes"), { recursive: true });
process.chdir(snap);   // tailwind's content globs resolve against the tree being rendered

// ── the tree's own stylesheet ──
const postcss = need("postcss");
const tailwind = need("tailwindcss");
const config = createRequire(path.join(snap, "tailwind.config.js"))(path.join(snap, "tailwind.config.js"));
const cssIn = path.join(snap, "styles", "globals.css");
const css = await postcss([need("postcss-import")(), tailwind(config), need("autoprefixer")])
  .process(fs.readFileSync(cssIn, "utf8"), { from: cssIn, to: path.join(snap, "styles", "evidence.css") })
  .catch((e) => fail(`css build: ${e.message}`));
fs.writeFileSync(path.join(out, "app.css"), css.css);

// ── the tree's own component ──
const esbuild = need("esbuild");
const allowed = [snap, ...["react", "react-dom", "scheduler"].map((p) => path.join(donor, p))];
const resolved = new Set();
const entry = `
import * as React from "react";
import { createRoot } from "react-dom/client";
import * as M from ${JSON.stringify(path.join(snap, recipe.component.file))};
const C = M[${JSON.stringify(recipe.component.export)}];
const props = { ...window.__PROPS__ };
for (const k of ${JSON.stringify(recipe.callbacks || [])}) props[k] = () => {};
createRoot(document.getElementById("frame")).render(React.createElement(C, props));
`;
const built = await esbuild.build({
  stdin: { contents: entry, resolveDir: snap, loader: "tsx" },
  bundle: true, write: false, format: "iife", jsx: "automatic", platform: "browser",
  nodePaths: [donor], absWorkingDir: snap, logLevel: "silent",
  define: { "process.env.NODE_ENV": '"production"' },
  plugins: [{
    name: "closure",
    setup(b) {
      b.onLoad({ filter: /.*/ }, (a) => {
        const real = fs.realpathSync(a.path);
        if (!allowed.some((r) => under(real, r))) return { errors: [{ text: `outside the closure: ${real}` }] };
        resolved.add(under(real, snap) ? "tree:" + path.relative(snap, real) : "donor:" + path.relative(donor, real));
        return undefined;
      });
    },
  }],
}).catch((e) => fail(`bundle: ${e.message}`));
const js = built.outputFiles[0].contents;
fs.writeFileSync(path.join(out, "app.js"), js);

// ── capture ──
const { chromium } = need("playwright");
const browser = await chromium.launch({ channel: "chrome" });
const blocked = [];
const scenes = {};
const ORIGIN = "http://evidence.local";
const frame = recipe.frame || {};
for (const scene of recipe.scenes) {
  const ctx = await browser.newContext({
    viewport: recipe.viewport || { width: 640, height: 400 }, deviceScaleFactor: 2,
    colorScheme: scene.theme, reducedMotion: "reduce", serviceWorkers: "block",
  });
  const page = await ctx.newPage();
  const errors = [];
  page.on("pageerror", (e) => errors.push(String(e)));
  page.on("console", (m) => m.type() === "error" && errors.push(m.text()));
  const html = `<!doctype html><html class="${scene.theme === "dark" ? "dark" : ""}" data-color-scheme="${scene.theme}">
<head><meta charset="utf-8"><link rel="stylesheet" href="/styles/evidence.css"></head>
<body style="margin:0"><div id="frame" class="${frame.class || ""}" style="display:inline-block;${frame.style || ""}"></div>
<script>window.__PROPS__=${JSON.stringify(recipe.props || {})}</script><script src="/app.js"></script></body></html>`;
  await page.route("**/*", (r) => {
    const u = new URL(r.request().url());
    if (u.origin !== ORIGIN) { blocked.push(r.request().url()); return r.abort(); }
    if (u.pathname === "/") return r.fulfill({ body: html, contentType: "text/html" });
    if (u.pathname === "/app.js") return r.fulfill({ body: Buffer.from(js), contentType: "text/javascript" });
    if (u.pathname === "/styles/evidence.css") return r.fulfill({ body: css.css, contentType: "text/css" });
    const file = path.join(snap, decodeURIComponent(u.pathname));
    if (u.pathname.startsWith("/styles/") && under(file, path.join(snap, "styles")) && fs.existsSync(file)) {
      return r.fulfill({ body: fs.readFileSync(file) });
    }
    blocked.push(r.request().url());
    return r.abort();
  });
  await page.goto(ORIGIN + "/");
  await page.waitForSelector("#frame > *");
  if (scene.focus) await page.focus(scene.focus);
  await page.evaluate(() => document.fonts.ready);
  const checks = await page.evaluate(({ scene, value, valueSel }) => {
    const el = scene.focus ? document.querySelector(scene.focus) : null;
    const v = valueSel ? document.querySelector(valueSel) : null;
    return {
      theme: document.documentElement.classList.contains("dark") === (scene.theme === "dark"),
      focus: scene.focus ? document.activeElement === el && el !== null : document.activeElement === document.body,
      value: valueSel ? v !== null && v.value === String(value) : true,
      fonts: document.fonts.status === "loaded" && [...document.fonts].some((f) => f.status === "loaded"),
    };
  }, { scene, value: recipe.props?.value, valueSel: recipe.valueSelector });
  const failed = Object.entries(checks).filter(([, ok]) => !ok).map(([k]) => k);
  if (errors.length) failed.push("page errors: " + errors.join(" | "));
  if (failed.length) { await browser.close(); fail(`scene ${scene.id}: precondition failed: ${failed.join(", ")}`); }
  const png = await page.locator("#frame").screenshot({ animations: "disabled", caret: "hide" });
  fs.writeFileSync(path.join(out, "scenes", `${scene.id}.png`), png);
  scenes[scene.id] = { sha: sha(png), checks };
  await ctx.close();
}
const browserVersion = browser.version();
await browser.close();
if (blocked.length) fail(`requests outside the snapshot: ${[...new Set(blocked)].join(", ")}`);

const result = {
  scenes,
  build: { css: sha(css.css), js: sha(js), resolved: [...resolved].sort() },
  browser: browserVersion,
};
fs.writeFileSync(path.join(out, "result.json.tmp"), JSON.stringify(result, null, 1));
fs.renameSync(path.join(out, "result.json.tmp"), path.join(out, "result.json"));
