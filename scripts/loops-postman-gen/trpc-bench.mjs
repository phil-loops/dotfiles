import { spawn } from "node:child_process";
import { readFile } from "node:fs/promises";
import { createServer } from "node:http";
import { dirname, resolve } from "node:path";

// tRPC procedures are session-authed: the cookie is HttpOnly and lives in the app tab, so
// requests can't be proxied from here. Instead a snippet pasted into the app tab's console
// becomes a bridge — this page postMessages each call to it, the app tab runs the fetch with
// its own session, and posts the response back.

const APPS = {
  dev: "http://localhost:3000",
  staging: "https://app.l3s.email",
  prod: "https://app.loops.so",
};

// Returns the balanced (...) or {...} text starting at `open`.
const balanced = (src, open) => {
  const pairs = { "(": ")", "{": "}", "[": "]" };
  const stack = [];
  let quote = null;
  for (let i = open; i < src.length; i++) {
    const c = src[i];
    if (quote) {
      if (c === "\\") i++;
      else if (c === quote) quote = null;
      continue;
    }
    if (c === '"' || c === "'" || c === "`") quote = c;
    else if (pairs[c]) stack.push(pairs[c]);
    else if (c === stack[stack.length - 1]) {
      stack.pop();
      if (!stack.length) return src.slice(open, i + 1);
    }
  }
  return src.slice(open);
};

// Placeholder input from the zod source: top-level keys of the first z.object({...}).
const skeleton = (zodText) => {
  const at = zodText.indexOf("z.object(");
  if (at < 0) return {};
  const body = balanced(zodText, zodText.indexOf("{", at));
  const out = {};
  let depth = 0;
  let i = 1;
  while (i < body.length - 1) {
    const c = body[i];
    if ("({[".includes(c)) depth++;
    else if (")}]".includes(c)) depth--;
    else if (depth === 0) {
      const m = /^\s*(\w+)\s*:\s*/.exec(body.slice(i));
      if (m && /[\s,{]/.test(body[i - 1] ?? " ")) {
        const valueStart = i + m[0].length;
        let j = valueStart;
        let d = 0;
        while (j < body.length - 1 && !(d === 0 && body[j] === ",")) {
          if ("({[".includes(body[j])) d++;
          else if (")}]".includes(body[j])) d--;
          j++;
        }
        const v = body.slice(valueStart, j);
        const optional = /\.(optional|default|nullish)\((?:[^()]|\([^()]*\))*\)\s*$/.test(v.trim());
        if (!optional) {
          out[m[1]] = /\.nullable\(\)\s*$/.test(v.trim())
            ? null
            : /^z\.array\(\s*z\.object\(/.test(v)
              ? [skeleton(v.slice(v.indexOf("z.object(")))]
            : /^z\.(string|enum|literal|nativeEnum)/.test(v)
              ? ""
              : /^z\.(number|coerce\.number)/.test(v)
                ? 0
                : /^z\.boolean/.test(v)
                  ? false
                  : /^z\.array/.test(v)
                    ? []
                    : /^z\.(object|record)/.test(v)
                      ? {}
                      : "";
        }
        i = j + 1;
        continue;
      }
    }
    i++;
  }
  return out;
};

const importsOf = (src, fromFile) => {
  const map = {};
  for (const m of src.matchAll(/import\s*\{([^}]+)\}\s*from\s*"([^"]+)"/g)) {
    for (const name of m[1].split(",").map((s) => s.trim().split(/\s+as\s+/).pop())) {
      if (name) map[name] = resolve(dirname(fromFile), m[2]);
    }
  }
  return map;
};

const readTs = async (base) => {
  for (const f of [`${base}.ts`, `${base}/index.ts`, base]) {
    try {
      return { file: f, src: await readFile(f, "utf8") };
    } catch {}
  }
  return null;
};

// Splits the inside of {...} on top-level commas.
const topLevelEntries = (body) => {
  const out = [];
  let depth = 0;
  let quote = null;
  let from = 1;
  for (let i = 1; i < body.length - 1; i++) {
    const c = body[i];
    if (quote) {
      if (c === "\\") i++;
      else if (c === quote) quote = null;
      continue;
    }
    if (c === '"' || c === "'" || c === "`") quote = c;
    else if ("({[".includes(c)) depth++;
    else if (")}]".includes(c)) depth--;
    else if (c === "," && depth === 0) {
      out.push(body.slice(from, i));
      from = i + 1;
    }
  }
  out.push(body.slice(from, body.length - 1));
  return out.map((e) => e.replace(/^\s*(\/\/[^\n]*\n\s*)*/, "").trim()).filter(Boolean);
};

// The source text of `const <name> = <expr>` in a file, following one import hop.
const definitionOf = async (name, file, src) => {
  const m = new RegExp(`\\bconst\\s+${name}\\s*(:[^=]+)?=\\s*`).exec(src);
  if (m) {
    let i = m.index + m[0].length;
    let depth = 0;
    let quote = null;
    for (; i < src.length; i++) {
      const c = src[i];
      if (quote) {
        if (c === "\\") i++;
        else if (c === quote) quote = null;
        continue;
      }
      if (c === '"' || c === "'" || c === "`") quote = c;
      else if ("({[".includes(c)) depth++;
      else if (")}]".includes(c)) depth--;
      else if (c === ";" && depth === 0) break;
    }
    return { file, src, text: src.slice(m.index + m[0].length, i) };
  }
  const target = importsOf(src, file)[name];
  if (!target) return null;
  const read = await readTs(target);
  return read ? definitionOf(name, read.file, read.src) : null;
};

const procedureFrom = (path, text) => {
  const kindAt = text.search(/\.(query|mutation|subscription)\(/);
  if (kindAt < 0) return null;
  const kind = /\.(query|mutation|subscription)\(/.exec(text)[1];
  const builder = /^(\w+)/.exec(text.trim())?.[1] ?? "";
  const z = text.indexOf("z.");
  const zod = z >= 0 && z < kindAt ? balancedExpr(text, z) : "";
  return { path, kind, builder, zod, input: skeleton(zod) };
};

// Walks a createTRPCRouter({...}) body: an entry resolving to another router recurses, one
// ending in .query/.mutation is a procedure. Shorthand and imported procedures resolve by name.
const walkRouter = async (file, src, routerText, prefix, out, seen) => {
  const at = routerText.indexOf("createTRPCRouter(");
  if (at < 0) return;
  const body = balanced(routerText, routerText.indexOf("{", at));
  for (const entry of topLevelEntries(body)) {
    const m = /^(\w+)\s*(?::\s*([\s\S]*))?$/.exec(entry);
    if (!m) continue;
    const key = m[1];
    const expr = (m[2] ?? key).trim();
    let def = { file, src, text: expr };
    if (/^\w+$/.test(expr)) {
      def = await definitionOf(expr, file, src);
      if (!def) continue;
    }
    if (def.text.includes("createTRPCRouter(")) {
      const id = `${def.file}#${expr}`;
      if (seen.has(id)) continue;
      seen.add(id);
      await walkRouter(def.file, def.src, def.text, `${prefix}${key}.`, out, seen);
      continue;
    }
    const proc = procedureFrom(`${prefix}${key}`, def.text);
    if (proc) out.push(proc);
  }
};

// A zod expression: `z.object(...)` plus any chained `.x(...)` calls.
const balancedExpr = (s, start) => {
  let i = start;
  let text = "";
  const head = /^z(\.\w+)+/.exec(s.slice(i))?.[0] ?? "z";
  text += head;
  i += head.length;
  while (s[i] === "(") {
    const call = balanced(s, i);
    text += call;
    i += call.length;
    const chained = /^\s*\.\w+/.exec(s.slice(i));
    if (!chained) break;
    text += chained[0].trim();
    i += chained[0].length;
  }
  return text;
};

const catalog = async (repo) => {
  const root = await readTs(resolve(repo, "trpc/root"));
  if (!root) return [];
  const out = [];
  const app = await definitionOf("appRouter", root.file, root.src);
  if (app) await walkRouter(root.file, root.src, app.text, "", out, new Set());
  return out.filter((p) => p.kind !== "subscription");
};

export async function serveTrpc({ repo = process.cwd(), port = 7071, open = true } = {}) {
  const procedures = await catalog(repo);
  const tool = `http://localhost:${port}`;
  const html = page({ procedures, tool });
  createServer((req, res) => {
    if (req.url === "/procedures.json") {
      res.writeHead(200, { "content-type": "application/json" });
      res.end(JSON.stringify(procedures));
      return;
    }
    res.writeHead(200, { "content-type": "text/html; charset=utf-8" });
    res.end(html);
  }).listen(port, "127.0.0.1", () => {
    console.log(`loops tRPC bench → ${tool}  (${procedures.length} procedures from ${repo})`);
    if (open) spawn("open", [tool], { stdio: "ignore", detached: true }).unref();
  });
}

const bridgeSnippet = (tool) => `(() => {
  const TOOL = ${JSON.stringify(tool)};
  if (window.__loopsTrpcBridge) {
    window.removeEventListener("message", window.__loopsTrpcBridge.handler);
    clearInterval(window.__loopsTrpcBridge.timer);
  }
  const handler = async (e) => {
    if (e.origin !== TOOL || e.data?.type !== "loops-trpc-call") return;
    const { id, path, kind, input } = e.data;
    const payload = JSON.stringify({ json: input });
    const url = "/api/trpc/" + path + (kind === "query" ? "?input=" + encodeURIComponent(payload) : "");
    const started = performance.now();
    const reply = (status, body) =>
      e.source.postMessage({ type: "loops-trpc-result", id, status, body, ms: Math.round(performance.now() - started) }, TOOL);
    try {
      const r = await fetch(url, kind === "query"
        ? { credentials: "include" }
        : { method: "POST", credentials: "include", headers: { "Content-Type": "application/json" }, body: payload });
      const text = await r.text();
      let body;
      try { body = JSON.parse(text); } catch { body = text; }
      reply(r.status, body);
    } catch (err) {
      reply(0, String(err));
    }
  };
  window.addEventListener("message", handler);
  const peer = window.opener && !window.opener.closed ? window.opener : window.open(TOOL, "loops-trpc-bench");
  const hello = () => peer && !peer.closed && peer.postMessage({ type: "loops-trpc-hello", origin: location.origin }, TOOL);
  const timer = setInterval(hello, 1500);
  hello();
  window.__loopsTrpcBridge = { handler, timer };
  console.log("%cloops tRPC bridge → " + TOOL, "color:#16a34a;font-weight:bold");
})();`;

const page = ({ procedures, tool }) => `<!doctype html>
<html>
<head>
<meta charset="utf-8" />
<meta name="viewport" content="width=device-width, initial-scale=1" />
<title>tRPC bench</title>
<style>
  :root { --bg:#0f1115; --panel:#171a21; --line:#262b36; --fg:#e6e8ee; --dim:#8a93a6; --accent:#7aa2ff;
          --ok:#22c55e; --warn:#f59e0b; --bad:#ef4444; --mono: ui-monospace, SFMono-Regular, Menlo, monospace; }
  * { box-sizing: border-box; }
  body { margin:0; background:var(--bg); color:var(--fg); font:14px/1.45 -apple-system, system-ui, sans-serif; }
  header { display:flex; gap:12px; align-items:center; padding:10px 16px; border-bottom:1px solid var(--line); flex-wrap:wrap; }
  header h1 { font-size:15px; margin:0; }
  .pill { padding:3px 10px; border-radius:999px; font-size:12px; border:1px solid var(--line); color:var(--dim); }
  .pill.ok { color:var(--ok); border-color:var(--ok); } .pill.prod { color:#fff; background:var(--bad); border-color:var(--bad); }
  main { display:grid; grid-template-columns: 300px 1fr; min-height: calc(100vh - 50px); }
  @media (max-width: 800px) { main { grid-template-columns: 1fr; } nav { max-height: 240px; } }
  nav { border-right:1px solid var(--line); overflow:auto; padding:8px; max-height: calc(100vh - 50px); }
  nav input { width:100%; padding:7px 9px; background:var(--panel); border:1px solid var(--line); color:var(--fg); border-radius:6px; }
  nav a { display:flex; gap:6px; padding:4px 6px; border-radius:5px; cursor:pointer; font-family:var(--mono); font-size:12px; color:var(--fg); word-break:break-all; }
  nav a:hover, nav a.on { background:var(--panel); }
  .k { font-size:10px; padding:1px 5px; border-radius:4px; align-self:flex-start; flex:none; }
  .k.query { background:#1e3a8a; } .k.mutation { background:#7c2d12; }
  section { padding:14px 16px; display:flex; flex-direction:column; gap:12px; min-width:0; }
  .card { background:var(--panel); border:1px solid var(--line); border-radius:8px; padding:12px; }
  .card h2 { font-size:12px; text-transform:uppercase; letter-spacing:.05em; color:var(--dim); margin:0 0 8px; }
  .row { display:flex; gap:8px; align-items:center; flex-wrap:wrap; }
  input.path { flex:1; min-width:200px; font-family:var(--mono); padding:7px 9px; background:var(--bg); border:1px solid var(--line); color:var(--fg); border-radius:6px; }
  select, button { padding:7px 12px; border-radius:6px; border:1px solid var(--line); background:var(--bg); color:var(--fg); cursor:pointer; }
  button.primary { background:var(--accent); color:#0b1020; border-color:var(--accent); font-weight:600; }
  button:disabled { opacity:.4; cursor:not-allowed; }
  textarea { width:100%; min-height:200px; font-family:var(--mono); font-size:12.5px; background:var(--bg); color:var(--fg); border:1px solid var(--line); border-radius:6px; padding:10px; resize:vertical; }
  pre { margin:0; font-family:var(--mono); font-size:12.5px; white-space:pre-wrap; word-break:break-word; max-height:50vh; overflow:auto; }
  pre.snip { max-height:120px; color:var(--dim); }
  .status { font-family:var(--mono); font-weight:700; }
  .s2 { color:var(--ok); } .s4 { color:var(--warn); } .s5, .s0 { color:var(--bad); }
  .hint { color:var(--dim); font-size:12px; }
  details summary { cursor:pointer; color:var(--dim); font-size:12px; }
  .hist a { display:block; font-family:var(--mono); font-size:12px; color:var(--dim); cursor:pointer; padding:2px 0; }
</style>
</head>
<body>
<header>
  <h1>tRPC bench</h1>
  <span id="conn" class="pill">bridge: not connected</span>
  <span class="hint">1 · open the app &nbsp; 2 · paste the snippet in its console &nbsp; 3 · send</span>
</header>
<main>
  <nav>
    <input id="filter" placeholder="filter ${procedures.length} procedures…" />
    <div id="list"></div>
  </nav>
  <section>
    <div class="card">
      <h2>Bridge</h2>
      <div class="row">
        <select id="app">${Object.entries(APPS).map(([k, v]) => `<option value="${v}"${k === "staging" ? " selected" : ""}>${k} — ${v}</option>`).join("")}</select>
        <button id="openApp">Open app</button>
        <button id="copy" class="primary">Copy console snippet</button>
      </div>
      <p class="hint">Log in, open DevTools → Console in the app tab, paste, Enter. Calls run with that tab's session. Chrome may ask you to type <code>allow pasting</code> first.</p>
      <details><summary>snippet</summary><pre class="snip" id="snip"></pre></details>
    </div>
    <div class="card">
      <h2>Request</h2>
      <div class="row">
        <select id="kind"><option>mutation</option><option>query</option></select>
        <input id="path" class="path" placeholder="incomingWebook.updateWebhook" />
        <button id="send" class="primary" disabled>Send</button>
      </div>
      <p class="hint">Input JSON — sent as <code>{ "json": … }</code> (superjson).</p>
      <textarea id="input" spellcheck="false">{}</textarea>
      <details id="zodBox"><summary>input schema (from source)</summary><pre id="zod"></pre></details>
    </div>
    <div class="card">
      <h2>Response <span id="meta" class="hint"></span></h2>
      <pre id="out" class="hint">—</pre>
    </div>
    <div class="card hist">
      <h2>History</h2>
      <div id="hist"></div>
    </div>
  </section>
</main>
<script>
const PROCS = ${JSON.stringify(procedures).replace(/</g, "\\u003c")};
const SNIPPET = ${JSON.stringify(bridgeSnippet(tool)).replace(/</g, "\\u003c")};
window.name = "loops-trpc-bench";
const $ = (id) => document.getElementById(id);
$("snip").textContent = SNIPPET;
let bridge = null, bridgeOrigin = null, seq = 0;
const pending = new Map();

$("copy").onclick = async () => { await navigator.clipboard.writeText(SNIPPET); $("copy").textContent = "Copied ✓"; setTimeout(() => $("copy").textContent = "Copy console snippet", 1500); };
$("openApp").onclick = () => window.open($("app").value, "_blank");

window.addEventListener("message", (e) => {
  const d = e.data || {};
  if (d.type === "loops-trpc-hello" && d.origin === e.origin) {
    bridge = e.source; bridgeOrigin = e.origin;
    const prod = e.origin === ${JSON.stringify(APPS.prod)};
    $("conn").textContent = "bridge: " + e.origin + (prod ? " — PRODUCTION" : "");
    $("conn").className = "pill " + (prod ? "prod" : "ok");
    $("send").disabled = false;
  }
  if (d.type === "loops-trpc-result" && e.origin === bridgeOrigin && pending.has(d.id)) {
    const req = pending.get(d.id); pending.delete(d.id);
    show(d); record(req, d);
  }
});

function show(d) {
  const cls = "s" + String(d.status)[0];
  const code = d.body?.error?.json?.data?.code || "";
  $("meta").innerHTML = '<span class="status ' + cls + '">' + d.status + '</span> ' + code + ' · ' + d.ms + 'ms';
  const data = d.body?.result?.data?.json ?? d.body?.error?.json ?? d.body;
  $("out").className = "";
  $("out").textContent = typeof data === "string" ? data : JSON.stringify(data, null, 2);
}

$("send").onclick = () => {
  let input;
  try { input = JSON.parse($("input").value || "null"); } catch (err) { $("out").textContent = "Invalid JSON: " + err.message; return; }
  const path = $("path").value.trim(), kind = $("kind").value;
  if (!path) return;
  if (bridgeOrigin === ${JSON.stringify(APPS.prod)} && kind === "mutation" && !confirm("Run a MUTATION against PRODUCTION?")) return;
  const id = ++seq;
  pending.set(id, { path, kind, input, origin: bridgeOrigin, at: new Date().toLocaleTimeString() });
  $("meta").textContent = "sending…";
  bridge.postMessage({ type: "loops-trpc-call", id, path, kind, input }, bridgeOrigin);
};

function select(p, keepInput) {
  $("path").value = p.path; $("kind").value = p.kind;
  if (!keepInput) $("input").value = JSON.stringify(p.input, null, 2);
  $("zod").textContent = p.zod || "(no input schema found)";
  document.querySelectorAll("nav a").forEach((a) => a.classList.toggle("on", a.dataset.path === p.path));
  history.replaceState({}, "", "?p=" + encodeURIComponent(p.path));
}

function renderList(q) {
  const list = $("list"); list.innerHTML = "";
  const needle = q.toLowerCase();
  for (const p of PROCS.filter((p) => p.path.toLowerCase().includes(needle))) {
    const a = document.createElement("a");
    a.dataset.path = p.path;
    a.innerHTML = '<span class="k ' + p.kind + '">' + (p.kind === "query" ? "Q" : "M") + '</span>';
    a.appendChild(document.createTextNode(p.path));
    a.onclick = () => select(p);
    list.appendChild(a);
  }
}
$("filter").oninput = (e) => renderList(e.target.value);

function loadHist() { try { return JSON.parse(localStorage.getItem("trpc.hist") || "[]"); } catch { return []; } }
function record(req, d) {
  const h = [{ ...req, status: d.status, ms: d.ms }, ...loadHist()].slice(0, 30);
  try { localStorage.setItem("trpc.hist", JSON.stringify(h)); } catch {}
  renderHist();
}
function renderHist() {
  const box = $("hist"); box.innerHTML = "";
  const h = loadHist();
  if (!h.length) { box.innerHTML = '<span class="hint">No calls yet.</span>'; return; }
  for (const r of h) {
    const a = document.createElement("a");
    a.textContent = r.at + "  " + r.status + "  " + r.kind[0].toUpperCase() + " " + r.path + "  (" + (r.origin || "") + ")";
    a.onclick = () => { $("path").value = r.path; $("kind").value = r.kind; $("input").value = JSON.stringify(r.input, null, 2); };
    box.appendChild(a);
  }
}

renderList("");
renderHist();
const start = new URLSearchParams(location.search).get("p");
const found = start && PROCS.find((p) => p.path === start);
if (found) select(found);
</script>
</body>
</html>`;
