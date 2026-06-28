import { spawn } from "node:child_process";
import { readFile } from "node:fs/promises";
import { createServer } from "node:http";
import { resolve } from "node:path";

const DEV_TOKEN = "00112233445566778899aabbccddeeff";
const DEFAULT_SPEC = "https://app.loops.so/openapi.json";

export const serve = async (opts) => {
  const args = {
    spec: DEFAULT_SPEC,
    base: "http://localhost:3000/api",
    token: DEV_TOKEN,
    port: 7070,
    open: true,
    ...opts,
  };

  const rawSpec = /^https?:\/\//.test(args.spec)
    ? await (await fetch(args.spec)).text()
    : await readFile(resolve(args.spec), "utf8");
  const spec = JSON.parse(rawSpec);
  const endpoints = extractEndpoints(spec);

  const html = page({ endpoints, base: args.base });

  const server = createServer(async (req, res) => {
    if (req.method === "GET" && req.url === "/") {
      res.writeHead(200, { "content-type": "text/html; charset=utf-8" });
      return res.end(html);
    }
    if (req.method === "POST" && req.url === "/proxy") {
      try {
        const reqBody = JSON.parse(await readBody(req));
        const result = await proxy(reqBody, args.token);
        res.writeHead(200, { "content-type": "application/json" });
        return res.end(JSON.stringify(result));
      } catch (err) {
        res.writeHead(500, { "content-type": "application/json" });
        return res.end(JSON.stringify({ error: String(err.message ?? err) }));
      }
    }
    res.writeHead(404);
    res.end("not found");
  });

  server.listen(args.port, () => {
    const url = `http://localhost:${args.port}`;
    console.log(`loops console → ${url}`);
    console.log(`  proxying to ${args.base} with token ${mask(args.token)}`);
    if (args.open) {
      spawn("open", [url], { stdio: "ignore", detached: true }).unref();
    }
  });
};

const readBody = (req) =>
  new Promise((res) => {
    let data = "";
    req.on("data", (c) => (data += c));
    req.on("end", () => res(data));
  });

const mask = (t) => (t.length > 8 ? `${t.slice(0, 4)}…${t.slice(-4)}` : "****");

const proxy = async ({ method, path, query, body, base }, token) => {
  const url = new URL(base.replace(/\/$/, "") + path);
  for (const [k, v] of Object.entries(query ?? {})) {
    if (v !== "" && v != null) {
      url.searchParams.set(k, v);
    }
  }
  const init = {
    method,
    headers: { authorization: `Bearer ${token}` },
  };
  if (body && method !== "GET" && method !== "DELETE") {
    init.headers["content-type"] = "application/json";
    init.body = body;
  }
  const res = await fetch(url, init);
  const text = await res.text();
  let parsed;
  try {
    parsed = JSON.parse(text);
  } catch {
    parsed = text;
  }
  return { status: res.status, statusText: res.statusText, body: parsed };
};

const extractEndpoints = (spec) => {
  const out = [];
  for (const [path, methods] of Object.entries(spec.paths ?? {})) {
    for (const [method, op] of Object.entries(methods)) {
      if (!["get", "post", "put", "patch", "delete"].includes(method)) {
        continue;
      }
      const pathParams = [...path.matchAll(/\{([^}]+)\}/g)].map((m) => m[1]);
      const queryParams = (op.parameters ?? [])
        .filter((p) => p.in === "query")
        .map((p) => ({ name: p.name, required: !!p.required }));
      out.push({
        method: method.toUpperCase(),
        path,
        tag: op.tags?.[0] ?? "Other",
        summary: op.summary ?? "",
        pathParams,
        queryParams,
        bodyExample: bodyExample(op, spec),
      });
    }
  }
  return out;
};

const bodyExample = (op, spec) => {
  const schema = op.requestBody?.content?.["application/json"]?.schema;
  if (!schema) {
    return null;
  }
  return JSON.stringify(sample(deref(schema, spec), spec, ""), null, 2);
};

const deref = (schema, spec) => {
  if (schema?.$ref) {
    const name = schema.$ref.split("/").pop();
    return spec.components?.schemas?.[name] ?? {};
  }
  return schema ?? {};
};

const sample = (schema, spec, key) => {
  schema = deref(schema, spec);
  if (schema.example !== undefined) {
    return schema.example;
  }
  if (schema.enum) {
    return schema.enum[0];
  }
  if (schema.type === "object" || schema.properties) {
    const obj = {};
    for (const [k, v] of Object.entries(schema.properties ?? {})) {
      obj[k] = sample(v, spec, k);
    }
    return obj;
  }
  if (schema.type === "array") {
    return [sample(schema.items ?? {}, spec, key)];
  }
  if (schema.type === "boolean") {
    return /(subscribed|enabled|active)/i.test(key);
  }
  if (schema.type === "integer" || schema.type === "number") {
    return 1;
  }
  return sampleString(key);
};

const sampleString = (key) => {
  if (/email/i.test(key)) {
    return "hello@example.com";
  }
  if (/^firstName$/i.test(key)) {
    return "Jane";
  }
  if (/^lastName$/i.test(key)) {
    return "Doe";
  }
  if (/name$/i.test(key)) {
    return "Jane Doe";
  }
  if (/(url|href|link)$/i.test(key)) {
    return "https://example.com";
  }
  if (/^id$/i.test(key)) {
    return "id_123";
  }
  if (/Id$/.test(key)) {
    return `${key.replace(/Id$/, "").toLowerCase()}_123`;
  }
  return "example";
};

const page = ({ endpoints, base }) => `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8" />
<meta name="viewport" content="width=device-width, initial-scale=1" />
<title>Loops API Console</title>
<style>
:root { color-scheme: light dark; --bg:#0f1115; --panel:#171a21; --line:#272b35; --fg:#e6e8ec; --muted:#8b93a3; --accent:#a78bfa; --get:#34d399; --post:#60a5fa; --put:#fbbf24; --del:#f87171; }
* { box-sizing: border-box; }
body { margin:0; font:13px/1.5 ui-monospace,SFMono-Regular,Menlo,monospace; background:var(--bg); color:var(--fg); display:grid; grid-template-columns:300px 1fr 320px; height:100vh; }
.col { overflow:auto; padding:12px; }
#list { border-right:1px solid var(--line); }
#store { border-left:1px solid var(--line); background:var(--panel); }
h2 { font-size:11px; text-transform:uppercase; letter-spacing:.08em; color:var(--muted); margin:16px 0 6px; }
h2:first-child { margin-top:0; }
.ep { padding:5px 7px; border-radius:6px; cursor:pointer; display:flex; gap:7px; align-items:baseline; }
.ep:hover { background:var(--panel); }
.ep.active { background:#222634; }
.m { font-weight:700; font-size:10px; width:42px; flex:0 0 42px; }
.GET{color:var(--get);} .POST{color:var(--post);} .PUT{color:var(--put);} .PATCH{color:var(--put);} .DELETE{color:var(--del);}
.path { color:var(--fg); word-break:break-all; }
.sum { color:var(--muted); font-size:11px; }
label { display:block; color:var(--muted); margin:10px 0 3px; font-size:11px; }
input, textarea, select { width:100%; background:#0b0d11; border:1px solid var(--line); color:var(--fg); border-radius:6px; padding:7px; font:inherit; }
textarea { min-height:140px; resize:vertical; }
button { background:var(--accent); color:#1a1330; border:none; border-radius:6px; padding:9px 14px; font:inherit; font-weight:700; cursor:pointer; }
button.ghost { background:transparent; color:var(--accent); border:1px solid var(--line); padding:4px 9px; font-weight:400; }
.row { display:flex; gap:8px; align-items:center; }
.bar { display:flex; gap:8px; align-items:center; margin-bottom:10px; }
.status { font-weight:700; padding:2px 8px; border-radius:5px; }
.ok{ background:#0c3; color:#021; } .bad{ background:#f55; color:#200; }
pre { background:#0b0d11; border:1px solid var(--line); border-radius:6px; padding:10px; overflow:auto; max-height:42vh; white-space:pre-wrap; word-break:break-word; }
.json .cap { color:var(--accent); cursor:pointer; border-bottom:1px dotted var(--muted); }
.json .cap:hover { background:#2a2150; border-bottom-color:var(--accent); }
.var { display:flex; justify-content:space-between; gap:6px; padding:4px 6px; border-radius:5px; cursor:pointer; }
.var:hover { background:#222634; }
.var b { color:var(--accent); font-weight:600; }
.var span { color:var(--muted); max-width:150px; overflow:hidden; text-overflow:ellipsis; white-space:nowrap; }
.related a { display:block; color:var(--post); cursor:pointer; padding:3px 0; }
.empty { color:var(--muted); font-style:italic; }
code.b { color:var(--accent); }
</style>
</head>
<body>
<div id="list" class="col"></div>
<div id="main" class="col">
  <div class="bar">
    <label style="margin:0">base</label>
    <input id="base" value="${base}" style="flex:1" />
  </div>
  <div id="form"><p class="empty">Pick an endpoint on the left.</p></div>
</div>
<div id="store" class="col">
  <h2>Captured ids</h2>
  <div id="vars"><p class="empty">Send a request — ids in the response land here, then autofill matching params.</p></div>
  <h2>Related to selection</h2>
  <div id="related" class="related"><p class="empty">Click a captured id.</p></div>
</div>
<script>
const ENDPOINTS = ${JSON.stringify(endpoints)};
const store = {};      // varName -> value
let current = null;
let selectedVar = null;

const el = (h) => { const d=document.createElement('div'); d.innerHTML=h; return d.firstElementChild; };
const byTag = ENDPOINTS.reduce((a,e)=>((a[e.tag]??=[]).push(e),a),{});

function renderList() {
  const list = document.getElementById('list');
  list.innerHTML = '';
  for (const tag of Object.keys(byTag)) {
    list.appendChild(el('<h2>'+tag+'</h2>'));
    for (const e of byTag[tag]) {
      const node = el('<div class="ep"><span class="m '+e.method+'">'+e.method+'</span><span class="path">'+e.path+'</span></div>');
      node.onclick = ()=>selectEndpoint(e, node);
      list.appendChild(node);
    }
  }
}

function selectEndpoint(e, node) {
  current = e;
  document.querySelectorAll('.ep').forEach(n=>n.classList.remove('active'));
  node?.classList.add('active');
  const form = document.getElementById('form');
  form.innerHTML = '';
  form.appendChild(el('<div class="row"><span class="m '+e.method+'">'+e.method+'</span><b class="path">'+e.path+'</b></div>'));
  if (e.summary) form.appendChild(el('<p class="sum">'+e.summary+'</p>'));
  for (const p of e.pathParams) form.appendChild(field('path:'+p, p, lookupStore(p)));
  for (const q of e.queryParams) form.appendChild(field('query:'+q.name, q.name+(q.required?' *':''), lookupStore(q.name)));
  if (e.bodyExample) {
    form.appendChild(el('<label>body</label>'));
    const ta = el('<textarea id="body"></textarea>'); ta.value = e.bodyExample; form.appendChild(ta);
  }
  const send = el('<div class="bar" style="margin-top:12px"><button id="send">Send</button></div>');
  form.appendChild(send);
  document.getElementById('send').onclick = sendRequest;
  form.appendChild(el('<div id="resp"></div>'));
}

function field(id, label, value) {
  const wrap = el('<div></div>');
  wrap.appendChild(el('<label>'+label+'</label>'));
  const input = el('<input data-k="'+id+'" />'); input.value = value;
  wrap.appendChild(input);
  return wrap;
}

function collectInputs(prefix) {
  const out = {};
  document.querySelectorAll('[data-k^="'+prefix+':"]').forEach(i=>{ out[i.dataset.k.split(':')[1]] = i.value; });
  return out;
}

async function sendRequest() {
  const pathParams = collectInputs('path');
  let path = current.path;
  for (const [k,v] of Object.entries(pathParams)) path = path.replace('{'+k+'}', encodeURIComponent(v));
  const query = collectInputs('query');
  const bodyEl = document.getElementById('body');
  const payload = { method: current.method, path, query, base: document.getElementById('base').value, body: bodyEl?bodyEl.value:undefined };
  const resp = document.getElementById('resp');
  resp.innerHTML = '<p class="empty">…sending</p>';
  const r = await fetch('/proxy', { method:'POST', headers:{'content-type':'application/json'}, body: JSON.stringify(payload) }).then(r=>r.json());
  const ok = r.status>=200 && r.status<300;
  resp.innerHTML = '';
  resp.appendChild(el('<div class="bar" style="margin-top:10px"><span class="status '+(ok?'ok':'bad')+'">'+(r.status||'ERR')+' '+(r.statusText||'')+'</span><span class="sum">click any highlighted id to capture it</span></div>'));
  resp.appendChild(renderResp(r.body ?? r.error));
  capture(r.body);
}

function capture(body) {
  walk(body, '', childResourceParam(current?.path));
  renderStore();
}

function captureValue(name, val) {
  store[name] = val;
  const child = childResourceParam(current?.path);
  if (name === 'id' && child) store[child] = val;
  renderStore();
  selectVar(name);
}

function isIdish(key, val) {
  if (/(^id$|Id$)/.test(key)) return true;
  return typeof val === 'string' && /^[A-Za-z0-9][A-Za-z0-9_-]{14,}$/.test(val) && /[0-9]/.test(val);
}

function capSpan(name, val, inner) {
  return '<span class="cap" data-cn="'+escapeHtml(name)+'" data-cv="'+escapeHtml(val)+'">'+inner+'</span>';
}

function renderJson(v, key, indent) {
  const pad = '  '.repeat(indent);
  if (Array.isArray(v)) {
    if (!v.length) return '[]';
    return '[\\n' + v.map(x=>'  '.repeat(indent+1)+renderJson(x, key, indent+1)).join(',\\n') + '\\n'+pad+']';
  }
  if (v && typeof v === 'object') {
    const keys = Object.keys(v);
    if (!keys.length) return '{}';
    const param = key.endsWith('s') && isIdMap(v) ? key.slice(0,-1)+'Id' : null;
    const keyIsId = param && paramExists(param);
    const rows = keys.map(k=>{
      const label = keyIsId ? capSpan(param, k, '"'+escapeHtml(k)+'"') : '"'+escapeHtml(k)+'"';
      return '  '.repeat(indent+1) + label + ': ' + renderJson(v[k], k, indent+1);
    }).join(',\\n');
    return '{\\n'+rows+'\\n'+pad+'}';
  }
  if (typeof v === 'string') {
    const inner = '"'+escapeHtml(v)+'"';
    return isIdish(key, v) ? capSpan(key||'value', v, inner) : inner;
  }
  if (typeof v === 'number') {
    return isIdish(key, v) ? capSpan(key||'value', String(v), String(v)) : String(v);
  }
  return escapeHtml(String(v));
}

function renderResp(body) {
  const pre = el('<pre class="json"></pre>');
  pre.innerHTML = renderJson(body, '', 0);
  pre.querySelectorAll('.cap').forEach(s=>{
    s.onclick = ()=>captureValue(s.dataset.cn, s.dataset.cv);
  });
  return pre;
}
function childResourceParam(path) {
  if (!path) return null;
  const prefix = path + '/{';
  for (const e of ENDPOINTS) {
    if (e.path.startsWith(prefix) && e.path.endsWith('}')) {
      const inner = e.path.slice(prefix.length, -1);
      if (!inner.includes('/')) return inner;
    }
  }
  return null;
}
function paramExists(p){ return ENDPOINTS.some(e=>e.pathParams.some(pp=>idMatch(pp,p)) || e.queryParams.some(q=>idMatch(q.name,p))); }
function isIdMap(o){ const ks=Object.keys(o); return ks.length>0 && ks.every(k=>k.length<=40) && Object.values(o).every(x=>x && (typeof x==='object'||typeof x==='boolean')); }
function walk(v, key, childParam) {
  if (Array.isArray(v)) { v.forEach(x=>walk(x, key, childParam)); return; }
  if (v && typeof v === 'object') {
    if (key.endsWith('s') && isIdMap(v)) {
      const param = key.slice(0,-1) + 'Id';
      if (paramExists(param)) { for (const mk of Object.keys(v)) store[param] = String(mk); }
    }
    for (const [k,val] of Object.entries(v)) walk(val, k, childParam);
    return;
  }
  if (/(^id$|Id$)/.test(key) && (typeof v==='string'||typeof v==='number')) {
    store[key] = String(v);
    if (key === 'id' && childParam) store[childParam] = String(v);
  }
}

function renderStore() {
  const vars = document.getElementById('vars');
  const keys = Object.keys(store);
  if (!keys.length) { vars.innerHTML='<p class="empty">No ids captured yet.</p>'; return; }
  vars.innerHTML='';
  for (const k of keys) {
    const row = el('<div class="var"><b>'+k+'</b><span>'+escapeHtml(store[k])+'</span></div>');
    row.onclick = ()=>selectVar(k);
    vars.appendChild(row);
  }
}

function idMatch(param, key) {
  param = param.toLowerCase(); key = key.toLowerCase();
  if (param === key) return true;
  const short = param.length < key.length ? param : key;
  const long = param.length < key.length ? key : param;
  return short.length >= 4 && long.endsWith(short);
}
function lookupStore(param) {
  if (store[param] != null) return store[param];
  const k = Object.keys(store).find(k=>idMatch(param, k));
  return k ? store[k] : '';
}

function selectVar(k) {
  selectedVar = k;
  document.querySelectorAll('[data-k]').forEach(i=>{ if (idMatch(i.dataset.k.split(':')[1], k)) i.value = store[k]; });
  const rel = document.getElementById('related');
  const matches = ENDPOINTS.filter(e=>e.pathParams.some(p=>idMatch(p,k)) || e.queryParams.some(q=>idMatch(q.name,k)));
  if (!matches.length) { rel.innerHTML='<p class="empty">No endpoints use {'+k+'}.</p>'; return; }
  rel.innerHTML='<p class="sum">Endpoints using <code class="b">'+k+'</code>:</p>';
  for (const e of matches) {
    const a = el('<a><span class="m '+e.method+'">'+e.method+'</span> '+e.path+'</a>');
    a.onclick = ()=>{ selectEndpoint(e); setTimeout(()=>selectVar(k),0); };
    rel.appendChild(a);
  }
}

function escapeHtml(s){ return String(s).replace(/[&<>]/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;'}[c])); }
renderList();
</script>
</body>
</html>`;
