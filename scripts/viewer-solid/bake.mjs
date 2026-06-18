// bake.mjs — snapshot the live review server's READ endpoints into static JSON
// blobs under dist/data, mirroring the URL shape the StaticProvider expects (see
// provider.ts). The result is a frozen, slice-in-time site that needs no live
// server or GitHub connection — `VITE_STATIC=1 vite build` + this bake = deployable.
//
//   node bake.mjs                 # needs the live viewer up on :62333
//   VIEWER_URL=… BAKE_OUT=… node bake.mjs
//
// GitHub auth + git access happen HERE, once, at bake time — never in the artifact.
import { mkdir, writeFile } from "node:fs/promises";
import { dirname, join } from "node:path";

const BASE = process.env.VIEWER_URL || "http://127.0.0.1:62333";
const OUT = process.env.BAKE_OUT || "dist/data";

// MUST match slug() in provider.ts: slashes → "~" so blobs are flat filenames.
const slug = (b) => b.replaceAll("/", "~");
const isGhost = (id) => id.startsWith("✦");

async function getJSON(path) {
  const r = await fetch(BASE + path);
  if (!r.ok) throw new Error(`${path} → ${r.status}`);
  return r.json();
}

async function writeBlob(rel, data) {
  const file = join(OUT, rel);
  await mkdir(dirname(file), { recursive: true });
  await writeFile(file, JSON.stringify(data));
}

// bounded concurrency so a big forest doesn't open hundreds of sockets at once.
async function pool(items, n, fn) {
  const q = [...items];
  await Promise.all(
    Array.from({ length: Math.min(n, q.length) }, async () => {
      while (q.length) await fn(q.shift());
    }),
  );
}

async function main() {
  try {
    const r = await fetch(BASE + "/sig");
    if (!r.ok) throw 0;
  } catch {
    console.error(`bake: no live viewer at ${BASE} — launch it first (stack-review-serve), or set VIEWER_URL.`);
    process.exit(1);
  }

  // top-level reads (home screen + jump-to-checkout).
  const [projects, myprs, standalone, branches, head] = await Promise.all([
    getJSON("/projects"),
    getJSON("/myprs"),
    getJSON("/standalone"),
    getJSON("/branches"),
    getJSON("/head"),
  ]);
  await Promise.all([
    writeBlob("projects.json", projects),
    writeBlob("myprs.json", myprs),
    writeBlob("standalone.json", standalone),
    writeBlob("branches.json", branches),
    writeBlob("head.json", head),
  ]);
  console.log(`✦ ${projects.length} projects, ${myprs.length} PRs, ${standalone.length} standalone`);

  // per-project forest model, then the union of real branches it names.
  const allBranches = new Set();
  await pool(projects, 6, async (p) => {
    const model = await getJSON("/model?branch=" + encodeURIComponent(p.name));
    await writeBlob(`model/${slug(p.name)}.json`, model);
    for (const id of Object.keys(model.nodes || {})) {
      if (!isGhost(id) && !model.nodes[id]?.ghost) allBranches.add(id);
    }
  });
  console.log(`✦ ${allBranches.size} branches`);

  // A multi-branch forest's project name isn't itself a branch, but the UI briefly
  // queries node(project) before the model resolves and picks the first real node.
  // Give those an empty node blob so static doesn't 404 on that transient request.
  for (const p of projects) {
    if (!allBranches.has(p.name)) await writeBlob(`node/${slug(p.name)}.json`, { branch: p.name, files: [] });
  }

  // per-branch diffs / commits / purpose / sync. A branch may fail individually
  // (e.g. no purpose) — log and continue rather than abort the whole bake.
  let done = 0;
  await pool([...allBranches], 8, async (b) => {
    const s = slug(b);
    for (const [path, rel] of [
      [`/node?branch=${encodeURIComponent(b)}`, `node/${s}.json`],
      [`/commits?branch=${encodeURIComponent(b)}`, `commits/${s}.json`],
      [`/purpose?branch=${encodeURIComponent(b)}`, `purpose/${s}.json`],
      [`/sync?branch=${encodeURIComponent(b)}`, `sync/${s}.json`],
    ]) {
      try {
        await writeBlob(rel, await getJSON(path));
      } catch (e) {
        console.warn(`  skip ${rel}: ${e.message}`);
      }
    }
    done++;
  });
  console.log(`✦ baked ${done} branches → ${OUT}`);
}

main().catch((e) => {
  console.error("bake failed:", e);
  process.exit(1);
});
