// fixture-server — deterministic stand-in for the Python viewer backend, for visual regression.
// Serves a built dist/ plus API responses from disk fixtures (record them once with --record
// against a live server; replay forever after, no live server or git state needed).
//
//   node fixture-server.mjs --dist ../dist --fixtures ./fixtures --port 7333
//   node fixture-server.mjs --dist ../dist --fixtures ./fixtures --port 7333 \
//        --record --upstream http://127.0.0.1:62497
import { createServer } from "node:http";
import { createHash } from "node:crypto";
import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { extname, join } from "node:path";

const arg = (name, dflt) => {
  const i = process.argv.indexOf("--" + name);
  return i === -1 ? dflt : process.argv[i + 1];
};
const DIST = arg("dist", "../dist");
const FIXTURES = arg("fixtures", "./fixtures");
const PORT = parseInt(arg("port", "7333"), 10);
const RECORD = process.argv.includes("--record");
const UPSTREAM = arg("upstream", "http://127.0.0.1:62497");

// API routes the SPA calls (mirror of vite.config.js ROUTES) — everything else is a page path.
const API = new Set([
  "/model", "/node", "/projects", "/prs", "/myprs", "/commits", "/file", "/sig",
  "/head", "/sync", "/syncs", "/restack-status", "/branches", "/standalone",
  "/check-origin", "/purpose", "/heartbeat", "/previews", "/preview-log", "/processes",
]);
const MIME = {
  ".html": "text/html", ".js": "text/javascript", ".css": "text/css", ".json": "application/json",
  ".png": "image/png", ".svg": "image/svg+xml", ".woff2": "font/woff2", ".ico": "image/x-icon",
};

mkdirSync(FIXTURES, { recursive: true });
const keyOf = (url) => createHash("sha1").update(url).digest("hex").slice(0, 24);

const misses = [];
createServer(async (req, res) => {
  const url = new URL(req.url, "http://x");
  const route = url.pathname;

  // SSE — hold the connection open, never send events; live-update paths stay quiet.
  if (route === "/events") {
    res.writeHead(200, { "Content-Type": "text/event-stream", "Cache-Control": "no-store" });
    return; // never ends; shots are short-lived
  }
  // mutation/telemetry endpoints the app may poke during a shot — accept and discard.
  if (req.method === "POST") {
    res.writeHead(200, { "Content-Type": "application/json" });
    res.end("{}");
    return;
  }

  // static asset from dist (exact file)
  const file = join(DIST, route === "/" ? "index.html" : route);
  if (route !== "/" && !route.includes("..") && existsSync(file) && extname(file)) {
    res.writeHead(200, { "Content-Type": MIME[extname(file)] ?? "application/octet-stream" });
    res.end(readFileSync(file));
    return;
  }

  // API → fixture (record: tee from upstream)
  if (API.has(route)) {
    const fix = join(FIXTURES, keyOf(req.url) + ".json");
    const meta = fix + ".meta";
    if (RECORD && !existsSync(fix)) {
      const r = await fetch(UPSTREAM + req.url).catch(() => null);
      if (!r || !r.ok) {
        res.writeHead(r ? r.status : 502);
        res.end();
        return;
      }
      const body = Buffer.from(await r.arrayBuffer());
      writeFileSync(fix, body);
      writeFileSync(meta, JSON.stringify({ url: req.url, type: r.headers.get("content-type") ?? "application/json" }));
      console.log(`  rec ${req.url}`);
    }
    if (existsSync(fix)) {
      const { type } = JSON.parse(readFileSync(meta, "utf8"));
      res.writeHead(200, { "Content-Type": type });
      res.end(readFileSync(fix));
    } else {
      misses.push(req.url);
      console.warn(`  MISS ${req.url}`);
      res.writeHead(404);
      res.end();
    }
    return;
  }

  // anything else: SPA fallback
  res.writeHead(200, { "Content-Type": "text/html" });
  res.end(readFileSync(join(DIST, "index.html")));
}).listen(PORT, () => console.log(`fixture-server :${PORT} dist=${DIST} fixtures=${FIXTURES}${RECORD ? " RECORD←" + UPSTREAM : ""}`))
  .on("error", (e) => {
    // lose the port race LOUDLY — a silent death here left a stale server green-lighting
    // someone else's build (the 2026-07-16 false-green). shot-all also asserts the dist.
    console.error(`fixture-server: cannot listen on :${PORT} (${e.code}) — another server owns it. Kill it or use --port.`);
    process.exit(4);
  });

process.on("SIGINT", () => {
  if (misses.length) console.warn(`\n${misses.length} fixture misses`);
  process.exit(misses.length ? 2 : 0);
});
