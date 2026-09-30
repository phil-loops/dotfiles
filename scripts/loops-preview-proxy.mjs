#!/usr/bin/env node
// Sits on a loops-preview's public port in front of `next dev` (which listens on --upstream).
// Forwards every request and websocket unchanged, injects <script src="/__preview/badge.js">
// into HTML responses, and serves:
//   /__preview/badge.js   the badge (scripts/loops-preview-badge.js, read per request)
//   /__preview/log        SSE tail of the server log + setup log (?tail=N initial lines)
//   /__preview/meta       {name, port, branch, upstreamUp, upstreamDied, grafana, log, setupLog}
// While next is still booting it answers HTML requests with a boot page that carries the
// badge open, so the boot log is what you look at instead of a spinner. Started by
// scripts/loops-preview; stopped with its tmux session.
import http from "node:http";
import net from "node:net";
import fs from "node:fs";
import path from "node:path";
import { execFileSync } from "node:child_process";
import { fileURLToPath } from "node:url";

const args = Object.fromEntries(process.argv.slice(2).map((a, i, all) => a.startsWith("--") ? [a.slice(2), all[i + 1] ?? ""] : []).filter((p) => p.length));
const PORT = Number(args.port), UPSTREAM = Number(args.upstream);
const LOG = args.log, SETUP_LOG = args["setup-log"] || "", NAME = args.name || "preview", DIR = args.dir || process.cwd();
if (!PORT || !UPSTREAM || !LOG) { console.error("usage: loops-preview-proxy --port N --upstream N --log FILE [--setup-log FILE] [--name NAME] [--dir DIR] [--branch NAME]"); process.exit(2); }
const BADGE = path.join(path.dirname(fileURLToPath(import.meta.url)), "loops-preview-badge.js");
const GRAFANA = `http://localhost:3900/d/loops-logs?var-port=${PORT}`;

const git = (...a) => { try { return execFileSync("git", ["-C", DIR, ...a], { encoding: "utf8" }).trim(); } catch { return ""; } };
const branch = args.branch || (() => { const b = git("rev-parse", "--abbrev-ref", "HEAD"); return b && b !== "HEAD" ? b : `detached@${git("rev-parse", "--short", "HEAD") || "?"}`; })();
const ANSI = /\x1b\[[0-9;]*[A-Za-z]/g;

let upstreamUp = false, upstreamEverUp = false;
let grafanaUp = false;
const probe = (port) => new Promise((res) => {
  const s = net.connect({ port, host: "127.0.0.1" });
  const done = (v) => { s.destroy(); res(v); };
  s.setTimeout(400, () => done(false));
  s.once("connect", () => done(true)); s.once("error", () => done(false));
});
const meta = () => ({ name: NAME, port: PORT, upstream: UPSTREAM, branch, dir: DIR, log: LOG, setupLog: SETUP_LOG, upstreamUp, upstreamDied: upstreamEverUp && !upstreamUp, grafana: grafanaUp ? GRAFANA : null });
const sseClients = new Set();
const broadcast = (event, data) => { const msg = `event: ${event}\ndata: ${JSON.stringify(data)}\n\n`; for (const c of sseClients) c.write(msg); };
const refreshState = async () => {
  const [u, g] = await Promise.all([probe(UPSTREAM), probe(3900)]);
  const changed = u !== upstreamUp || g !== grafanaUp;
  upstreamUp = u; if (u) upstreamEverUp = true; grafanaUp = g;
  if (changed) broadcast("meta", meta());
};
refreshState(); setInterval(refreshState, 1000);

// Tail a file from its current end (or the last `tail` lines on request), following appends;
// a shrink (truncate/rotate) resets. Emits complete lines only.
class Tailer {
  constructor(file, src) { this.file = file; this.src = src; this.pos = 0; this.buf = ""; this.listeners = new Set(); this.recent = []; this.prime(); setInterval(() => this.poll(), 250); }
  prime() {
    try { const text = fs.readFileSync(this.file, "utf8"); this.pos = Buffer.byteLength(text); this.recent = text.split("\n").filter(Boolean).slice(-2000).map((t) => ({ text: t.replace(ANSI, ""), src: this.src, time: Date.now() })); }
    catch { this.pos = 0; }
  }
  poll() {
    let st; try { st = fs.statSync(this.file); } catch { return; }
    if (st.size < this.pos) { this.pos = 0; this.buf = ""; this.recent = []; broadcast("reset", { src: this.src }); }
    if (st.size === this.pos) return;
    const fd = fs.openSync(this.file, "r");
    try {
      const chunk = Buffer.alloc(st.size - this.pos);
      fs.readSync(fd, chunk, 0, chunk.length, this.pos); this.pos = st.size;
      this.buf += chunk.toString("utf8");
    } finally { fs.closeSync(fd); }
    const parts = this.buf.split("\n"); this.buf = parts.pop();
    for (const text of parts) {
      if (!text) continue;
      const line = { text: text.replace(ANSI, ""), src: this.src, time: Date.now() };
      this.recent.push(line); if (this.recent.length > 2000) this.recent.shift();
      broadcast("line", line);
    }
  }
}
const tailers = [new Tailer(LOG, "server")];
if (SETUP_LOG) tailers.unshift(new Tailer(SETUP_LOG, "setup"));

const bootPage = () => `<!doctype html><html data-preview-boot="1"><head><meta charset="utf-8"><title>${NAME} · booting</title>
<style>html{color-scheme:light dark}body{margin:0;min-height:100vh;display:grid;place-items:center;font:14px/1.5 ui-monospace,Menlo,monospace;background:#fbfbfa;color:#1d1d1b}@media(prefers-color-scheme:dark){body{background:#17181a;color:#e8e8e4}}
p{opacity:.7;margin:0}h1{font-size:15px;font-weight:600;margin:0 0 6px}</style></head>
<body><div><h1>${NAME} is booting on :${PORT}</h1><p>${branch} · this page reloads when next dev answers</p></div>
<script src="/__preview/badge.js" defer></script></body></html>`;

const send = (res, code, type, body) => { res.writeHead(code, { "content-type": type, "cache-control": "no-store", "content-length": Buffer.byteLength(body) }); res.end(body); };

const serveInternal = (req, res, url) => {
  if (url.pathname === "/__preview/badge.js") {
    try { return send(res, 200, "application/javascript; charset=utf-8", fs.readFileSync(BADGE, "utf8")); }
    catch (e) { return send(res, 500, "text/plain", `badge missing: ${e.message}`); }
  }
  if (url.pathname === "/__preview/meta") return send(res, 200, "application/json", JSON.stringify(meta()));
  if (url.pathname === "/__preview/log") {
    const n = Math.min(Number(url.searchParams.get("tail")) || 300, 2000);
    res.writeHead(200, { "content-type": "text/event-stream", "cache-control": "no-store", connection: "keep-alive", "x-accel-buffering": "no" });
    const setup = tailers.find((t) => t.src === "setup")?.recent ?? [];
    const server = tailers.find((t) => t.src === "server").recent.slice(-n);
    res.write(`event: init\ndata: ${JSON.stringify({ lines: [...setup, ...server], meta: meta() })}\n\n`);
    sseClients.add(res);
    const ping = setInterval(() => res.write(": ping\n\n"), 15000);
    req.on("close", () => { clearInterval(ping); sseClients.delete(res); });
    return;
  }
  return send(res, 404, "text/plain", "no such preview route");
};

const wantsHtml = (req) => /\btext\/html\b/.test(req.headers.accept || "") && req.method === "GET";
const INJECT = `<script src="/__preview/badge.js" defer></script>`;

const server = http.createServer((req, res) => {
  const url = new URL(req.url, `http://localhost:${PORT}`);
  if (url.pathname.startsWith("/__preview/")) return serveInternal(req, res, url);
  const html = wantsHtml(req);
  const headers = { ...req.headers };
  if (html) delete headers["accept-encoding"];
  const up = http.request({ host: "127.0.0.1", port: UPSTREAM, method: req.method, path: req.url, headers }, (ur) => {
    const type = ur.headers["content-type"] || "";
    if (!html || !type.startsWith("text/html") || ur.headers["content-encoding"]) {
      res.writeHead(ur.statusCode, ur.headers); return ur.pipe(res);
    }
    const chunks = [];
    ur.on("data", (c) => chunks.push(c));
    ur.on("end", () => {
      let body = Buffer.concat(chunks).toString("utf8");
      if (!body.includes("/__preview/badge.js")) {
        if (body.includes("</body>")) body = body.replace("</body>", `${INJECT}</body>`);
        else if (body.includes("</head>")) body = body.replace("</head>", `${INJECT}</head>`);
        else body += INJECT;
      }
      const h = { ...ur.headers, "content-length": String(Buffer.byteLength(body)) };
      delete h["transfer-encoding"];
      res.writeHead(ur.statusCode, h); res.end(body);
    });
  });
  up.on("error", (e) => {
    if (res.headersSent) return res.destroy();
    if (html) return send(res, 503, "text/html; charset=utf-8", bootPage());
    send(res, 502, "text/plain", `next dev on :${UPSTREAM} is not answering (${e.code || e.message})`);
  });
  req.pipe(up);
});

server.on("upgrade", (req, socket, head) => {
  const up = net.connect({ port: UPSTREAM, host: "127.0.0.1" }, () => {
    const lines = [`${req.method} ${req.url} HTTP/${req.httpVersion}`];
    for (const [k, v] of Object.entries(req.headers)) for (const val of [].concat(v)) lines.push(`${k}: ${val}`);
    up.write(lines.join("\r\n") + "\r\n\r\n");
    if (head.length) up.write(head);
    socket.pipe(up); up.pipe(socket);
  });
  const drop = () => { socket.destroy(); up.destroy(); };
  up.on("error", drop); socket.on("error", drop);
});

server.on("clientError", (_e, socket) => socket.destroy());
server.listen(PORT, () => console.log(`loops-preview-proxy :${PORT} → next dev :${UPSTREAM} · log ${LOG}`));
for (const sig of ["SIGINT", "SIGTERM"]) process.on(sig, () => { server.close(); process.exit(0); });
