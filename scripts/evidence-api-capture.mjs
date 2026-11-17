// evidence-api-capture.mjs — ONE attempt: capture an api recipe's requests from a running server.
//
//   node evidence-api-capture.mjs <base-url> <recipe-dir> <out-dir>      (NODE_PATH = node_modules with playwright)
//   env EVIDENCE_LOGIN = JSON {email, token}: a fresh magic-link token the caller stored for this attempt
//
// The server is the tree under test (a preview of exactly one commit); this script only sends requests.
// Reads only: a write would change the dev database the next attempt and the other side read.
// Each scene's artifact is canonical JSON {status, contentType, body} after the request's masks.
// out/result.json is written last — a dir without it is an incomplete attempt, never evidence.
import { createRequire } from "node:module";
import crypto from "node:crypto";
import fs from "node:fs";
import path from "node:path";
import { canon, mask } from "./evidence-json.mjs";

const [base, recipeDir, out] = process.argv.slice(2);
const need = createRequire(path.join(path.resolve(process.env.NODE_PATH || ""), "noop.js"));
const recipe = JSON.parse(fs.readFileSync(path.join(path.resolve(recipeDir), "recipe.json"), "utf8"));
const login = JSON.parse(process.env.EVIDENCE_LOGIN || "null");
const sha = (b) => crypto.createHash("sha256").update(b).digest("hex");
const fail = async (why, ctx) => {
  fs.writeFileSync(path.join(out, "failed.json"), JSON.stringify({ why }, null, 1));
  console.error("evidence-api-capture:", why);
  if (ctx) await ctx.dispose().catch(() => {});
  process.exit(1);
};
fs.mkdirSync(path.join(out, "scenes"), { recursive: true });

const variants = recipe.variants?.length ? recipe.variants : [null];
const scenes = recipe.requests.flatMap((r) => variants.map((v) => ({ ...r, ...(v || {}), id: v ? `${r.id}-${v.id}` : r.id })));

const { request } = need("playwright");
const ctx = await request.newContext({ baseURL: base, extraHTTPHeaders: { accept: "application/json" } });
if (login) {
  const q = new URLSearchParams({ callbackUrl: base + "/", token: login.token, email: login.email });
  const r = await ctx.get(`/api/auth/callback/email?${q}`, { maxRedirects: 0 });
  const signedIn = (await ctx.storageState()).cookies.some((c) => /session-token/.test(c.name));
  if (!signedIn) await fail(`sign-in failed: callback answered ${r.status()} ${r.headers().location || ""}`, ctx);
}

const result = {};
for (const scene of scenes) {
  if ((scene.method || "GET").toUpperCase() !== "GET") await fail(`${scene.id}: only GET requests are captured`, ctx);
  const r = await ctx.get(scene.path, { maxRedirects: 0 });
  const contentType = (r.headers()["content-type"] || "").split(";")[0].trim();
  const raw = await r.body();
  let body;
  if (contentType === "application/json") {
    try {
      body = mask(JSON.parse(raw.toString("utf8")), scene.mask || []);
    } catch (e) {
      await fail(`${scene.id}: ${e.message}`, ctx);
    }
  } else {
    body = { text: raw.toString("utf8").slice(0, 20000) };
  }
  const artifact = canon({ status: r.status(), contentType, body });
  fs.writeFileSync(path.join(out, "scenes", `${scene.id}.json`), artifact);
  result[scene.id] = { sha: sha(artifact), file: `${scene.id}.json`, status: r.status() };
}
await ctx.dispose();
fs.writeFileSync(path.join(out, "result.json.tmp"), JSON.stringify({ scenes: result }, null, 1));
fs.renameSync(path.join(out, "result.json.tmp"), path.join(out, "result.json"));
