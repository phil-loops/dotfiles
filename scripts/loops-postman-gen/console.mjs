import { spawn } from "node:child_process";
import { readFile } from "node:fs/promises";
import { createServer } from "node:http";
import { resolve } from "node:path";
import { mergeWorkflowOverlay } from "./workflow-overlay.mjs";

const DEV_TOKEN = "00112233445566778899aabbccddeeff";
const DEFAULT_SPEC = "https://app.loops.so/openapi.json";

// Business rules the OpenAPI schema can't express: an enum field the spec lists in full
// but the server only accepts a subset of for a given endpoint (the rest 400). First value
// is the default the sample body loads with. Key = "METHOD path::field".
const ENUM_HINTS = {
  "POST /v1/workflows/{workflowId}/nodes::nodeTypeName": [
    "SendEmailAction",
    "TimerAction",
    "AudienceFilter",
    "ExitAction",
    "BranchNode",
    "ExperimentBranchNode",
  ],
};
const enumHint = (method, path, field) => ENUM_HINTS[`${method} ${path}::${field}`];

// Restrict a produced sample object's hinted enum fields to legal values (mutates in place).
const applyHints = (obj, method, path) => {
  if (obj && typeof obj === "object" && !Array.isArray(obj)) {
    for (const k of Object.keys(obj)) {
      const allow = enumHint(method, path, k);
      if (allow?.length && !allow.includes(obj[k])) {
        obj[k] = allow[0];
      }
    }
  }
  return obj;
};

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
  mergeWorkflowOverlay(spec); // overlay the workflow builder writes the upstream spec omits
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
  if (body && method !== "GET") {
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
      const METHOD = method.toUpperCase();
      const variants = bodyVariants(op, spec, METHOD, path);
      out.push({
        method: METHOD,
        path,
        tag: op.tags?.[0] ?? "Other",
        summary: op.summary ?? "",
        pathParams,
        queryParams,
        bodyExample: variants?.length
          ? JSON.stringify(variants[0].sample, null, 2)
          : bodyExample(op, spec, METHOD, path),
        bodyVariants: variants,
        bodyEnums: enumSlots(op, spec, METHOD, path),
      });
    }
  }
  return out;
};

const bodyExample = (op, spec, method, path) => {
  const schema = op.requestBody?.content?.["application/json"]?.schema;
  if (!schema) {
    return null;
  }
  const obj = applyHints(sample(deref(schema, spec), spec, ""), method, path);
  return JSON.stringify(obj, null, 2);
};

// Each branch of a oneOf/anyOf body → a labeled, ready-to-load sample. Label is the
// branch's discriminator value (e.g. each nodeTypeName), else its single-value field.
// A discriminator hint (ENUM_HINTS keyed on the discriminator prop) trims branches to the
// legal ones and orders them, so the default is a value the server actually accepts.
const bodyVariants = (op, spec, method, path) => {
  const schema = deref(op.requestBody?.content?.["application/json"]?.schema, spec);
  const branches = schema?.oneOf ?? schema?.anyOf;
  if (!branches?.length) {
    return null;
  }
  const discrimProp = schema.discriminator?.propertyName;
  const allow = discrimProp ? enumHint(method, path, discrimProp) : null;
  let out = branches.map((b, i) => {
    const bs = deref(b, spec);
    const value = discrimProp ? singleEnumValue(bs, spec, discrimProp) : null;
    return {
      value,
      label: value ?? variantLabel(bs, spec, i),
      sample: applyHints(sample(bs, spec, ""), method, path),
    };
  });
  if (allow?.length) {
    out = out
      .filter((v) => v.value == null || allow.includes(v.value))
      .sort((a, b) => allow.indexOf(a.value) - allow.indexOf(b.value));
  }
  return out.length ? out : null;
};

const singleEnumValue = (schema, spec, prop) => {
  const vs = deref(schema.properties?.[prop], spec);
  const vals = vs?.enum ?? (vs?.const !== undefined ? [vs.const] : null);
  return vals?.length ? String(vals[0]) : null;
};

const variantLabel = (schema, spec, i) => {
  for (const [k] of Object.entries(schema.properties ?? {})) {
    const v = singleEnumValue(schema, spec, k);
    if (v != null) {
      return v;
    }
  }
  return `variant ${i + 1}`;
};

// Top-level multi-value enum fields in the body → a pill row that swaps that field's value.
// Uses the first oneOf branch as representative; hinted fields are trimmed to legal values.
const enumSlots = (op, spec, method, path) => {
  let schema = deref(op.requestBody?.content?.["application/json"]?.schema, spec);
  const branches = schema.oneOf ?? schema.anyOf;
  if (branches?.length) {
    schema = deref(branches[0], spec);
  }
  const slots = [];
  for (const [field, v] of Object.entries(schema.properties ?? {})) {
    const vs = deref(v, spec);
    if (!vs.enum || vs.enum.length < 2) {
      continue;
    }
    const allow = enumHint(method, path, field);
    const values = allow ? vs.enum.filter((x) => allow.includes(x)) : vs.enum;
    if (values.length > 1) {
      slots.push({ field, values });
    }
  }
  return slots.length ? slots : null;
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
  if (schema.allOf) {
    return schema.allOf.reduce(
      (acc, s) => Object.assign(acc, sample(s, spec, key)),
      {}
    );
  }
  const branches = schema.oneOf ?? schema.anyOf;
  if (branches?.length) {
    return sample(branches[0], spec, key);
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
  // Auto-chaining placeholders: {{var}} is substituted from the last response's captured
  // ids at send time, so multi-step flows don't need manual id/revision copying.
  if (/^expectedRevisionId$/.test(key)) {
    return "{{workflowRevisionId}}";
  }
  if (/^(fromNodeId|toNodeId)$/.test(key)) {
    return key === "fromNodeId" ? "n1" : "n2";
  }
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
<link rel="preconnect" href="https://fonts.googleapis.com">
<link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
<link href="https://fonts.googleapis.com/css2?family=Space+Grotesk:wght@400;500;600;700&display=swap" rel="stylesheet">
<style>
:root {
  color-scheme: dark;
  --ink:#151320; --panel:#1e1a2c; --well:#100e18; --edge:#302a45;
  --fg:#eae7f4; --muted:#8f88a8;
  --signal:#b79bff; --signal-dim:#7d6bb0; --patch:#ffc76b;
  --get:#5fd0a6; --post:#79a6ff; --put:#f4c05b; --del:#f47c8c;
  --mono: ui-monospace,SFMono-Regular,Menlo,monospace;
  --ui: 'Space Grotesk', ui-sans-serif, system-ui, sans-serif;
}
* { box-sizing: border-box; }
body { margin:0; font:13px/1.55 var(--mono); background:var(--ink); color:var(--fg);
  display:grid; grid-template-columns:280px 1fr 320px; grid-template-rows:auto 1fr; height:100vh; }

.top { grid-column:1/-1; display:flex; align-items:center; gap:18px; padding:11px 16px;
  border-bottom:1px solid var(--edge); background:var(--panel); }
.brand { display:flex; align-items:center; gap:9px; font:600 14px/1 var(--ui); letter-spacing:.16em;
  text-transform:uppercase; white-space:nowrap; }
.brand .loop { color:var(--signal); font-size:17px; }
.brand small { color:var(--muted); font-weight:500; letter-spacing:.16em; }
.baseline { display:flex; align-items:center; gap:10px; flex:1; min-width:0; }
.baseline label { margin:0; }
.live { display:flex; align-items:center; gap:7px; font:500 10px/1 var(--ui); letter-spacing:.14em;
  text-transform:uppercase; color:var(--muted); white-space:nowrap; }
.live .dot { width:7px; height:7px; border-radius:50%; background:var(--get); box-shadow:0 0 9px var(--get); }

.col { overflow:auto; padding:14px; }
#list { border-right:1px solid var(--edge); }
#store { border-left:1px solid var(--edge); background:var(--panel); }
#filter { margin-bottom:12px; }

h2 { font:600 10px/1 var(--ui); text-transform:uppercase; letter-spacing:.18em; color:var(--muted); margin:20px 0 9px; }
h2:first-child { margin-top:0; }

.ep { padding:5px 8px; border-radius:7px; cursor:pointer; display:flex; gap:10px; align-items:baseline;
  border:1px solid transparent; }
.ep:hover { background:var(--well); }
.ep.active { background:var(--well); border-color:var(--signal-dim); }
.m { font:700 10px/1.4 var(--mono); letter-spacing:.03em; flex:0 0 46px; text-align:right; }
.GET{color:var(--get);} .POST{color:var(--post);} .PUT{color:var(--put);} .PATCH{color:var(--put);} .DELETE{color:var(--del);}
.path { color:var(--fg); word-break:break-all; }

.reqline { display:flex; gap:12px; align-items:baseline; padding-bottom:10px; margin-bottom:12px;
  border-bottom:1px solid var(--edge); }
.reqline .m { flex:0 0 auto; font-size:12px; }
.reqline .path { font:500 15px/1.3 var(--mono); }
.sum { color:var(--muted); font-size:12px; margin:0 0 10px; }

label { display:block; font:500 10px/1 var(--ui); letter-spacing:.15em; text-transform:uppercase;
  color:var(--muted); margin:12px 0 5px; }
input, textarea, select { width:100%; background:var(--well); border:1px solid var(--edge); color:var(--fg);
  border-radius:7px; padding:8px 9px; font:13px/1.4 var(--mono); }
input::placeholder, textarea::placeholder { color:var(--muted); opacity:.7; }
input:focus, textarea:focus, select:focus { outline:none; border-color:var(--signal);
  box-shadow:0 0 0 3px rgba(183,155,255,.16); }
textarea { min-height:150px; resize:vertical; }

.threaded > input { border-left:3px solid var(--patch);
  background:linear-gradient(90deg, rgba(255,199,107,.10), var(--well) 42%); }
.threaded > label::after { content:'◗ patched'; float:right; color:var(--patch); letter-spacing:.12em; }

button { background:var(--signal); color:#1a1330; border:none; border-radius:7px; padding:10px 18px;
  font:600 12px/1 var(--ui); letter-spacing:.07em; cursor:pointer; }
button:hover { filter:brightness(1.09); }
button:focus-visible { outline:2px solid var(--fg); outline-offset:2px; }
button.ghost { background:transparent; color:var(--signal); border:1px solid var(--edge);
  padding:5px 11px; font-size:10px; font-weight:500; letter-spacing:.12em; text-transform:uppercase; }
button.ghost:hover { border-color:var(--signal); background:var(--well); filter:none; }

.pills { display:flex; flex-direction:column; gap:6px; margin:2px 0 9px; }
.pillrow { display:flex; flex-wrap:wrap; gap:6px; align-items:center; }
.pilllabel { font:500 9px/1 var(--ui); letter-spacing:.14em; text-transform:uppercase;
  color:var(--muted); min-width:58px; }
.pill { background:var(--well); color:var(--signal); border:1px solid var(--edge);
  border-radius:999px; padding:4px 11px; font:500 11px/1 var(--mono); letter-spacing:.02em; cursor:pointer; }
.pill:hover { border-color:var(--signal); background:rgba(183,155,255,.13); filter:none; }

.row { display:flex; gap:8px; align-items:center; }
.bar { display:flex; gap:10px; align-items:center; margin-bottom:10px; }
#send { margin-top:14px; }

.status { font:700 11px/1 var(--mono); letter-spacing:.03em; padding:5px 10px; border-radius:6px; }
.ok { background:rgba(95,208,166,.16); color:var(--get); border:1px solid rgba(95,208,166,.38); }
.bad { background:rgba(244,124,140,.16); color:var(--del); border:1px solid rgba(244,124,140,.42); }

pre { background:var(--well); border:1px solid var(--edge); border-radius:8px; padding:12px; overflow:auto;
  max-height:44vh; white-space:pre-wrap; word-break:break-word; }
.json .cap { color:var(--signal); cursor:pointer; border-bottom:1px dashed var(--signal-dim); border-radius:3px; padding:0 1px; }
.json .cap:hover { background:rgba(183,155,255,.18); border-bottom-color:var(--signal); }

.var { display:flex; align-items:center; gap:9px; padding:7px 9px; border-radius:8px; cursor:pointer;
  border:1px solid var(--edge); background:var(--well); margin-bottom:6px; }
.var:hover { border-color:var(--signal); }
.var .jack { color:var(--signal); font-size:12px; line-height:1; }
.var b { color:var(--fg); font-weight:600; }
.var .val { color:var(--muted); margin-left:auto; max-width:150px; overflow:hidden; text-overflow:ellipsis; white-space:nowrap; }

.related a { display:block; color:var(--post); cursor:pointer; padding:4px 0; text-decoration:none; }
.related a:hover { color:var(--signal); }
.empty { color:var(--muted); font-size:12px; line-height:1.6; }
code.b { color:var(--signal); }

.sending { color:var(--signal); }
@keyframes pulse { 0%,100%{opacity:.45} 50%{opacity:1} }
@media (prefers-reduced-motion:no-preference) { .sending { animation:pulse 1.1s ease-in-out infinite; } }

@media (max-width:900px) {
  body { grid-template-columns:1fr; grid-template-rows:auto auto auto auto; height:auto; }
  #list, #store { border:none; border-top:1px solid var(--edge); }
  .top { flex-wrap:wrap; }
}
</style>
</head>
<body>
<header class="top">
  <div class="brand"><span class="loop">◗</span>Loops <small>API Console</small></div>
  <div class="baseline"><label>base</label><input id="base" value="${base}" /></div>
  <div class="live"><span class="dot"></span>local</div>
</header>
<div id="list" class="col">
  <input id="filter" placeholder="filter endpoints…" autocomplete="off" spellcheck="false" />
  <div id="eps"></div>
</div>
<div id="main" class="col">
  <div id="form"><p class="empty">Pick an endpoint on the left to build a request.</p></div>
</div>
<div id="store" class="col">
  <h2>Captured</h2>
  <div id="vars"><p class="empty">Nothing captured yet. Every response's ids &amp; workflowRevisionId are captured automatically — reference them in the body/params as <b>{{workflowRevisionId}}</b>, <b>{{id}}</b>, etc. and they fill in at send. (Click a highlighted id to pin it too.)</p></div>
  <h2>Related</h2>
  <div id="related" class="related"><p class="empty">Pick a captured id to see where it fits.</p></div>
</div>
<script>
const ENDPOINTS = ${JSON.stringify(endpoints)};
const store = {};      // varName -> value
let current = null;
let selectedVar = null;

const el = (h) => { const d=document.createElement('div'); d.innerHTML=h; return d.firstElementChild; };
const byTag = ENDPOINTS.reduce((a,e)=>((a[e.tag]??=[]).push(e),a),{});

function renderList(q) {
  const list = document.getElementById('eps');
  q = (q||'').trim().toLowerCase();
  list.innerHTML = '';
  for (const tag of Object.keys(byTag)) {
    const eps = byTag[tag].filter(e=> !q || (e.method+' '+e.path).toLowerCase().includes(q));
    if (!eps.length) continue;
    list.appendChild(el('<h2>'+tag+'</h2>'));
    for (const e of eps) {
      const node = el('<div class="ep"><span class="m '+e.method+'">'+e.method+'</span><span class="path">'+e.path+'</span></div>');
      node.onclick = ()=>selectEndpoint(e, node);
      list.appendChild(node);
    }
  }
  if (!list.children.length) list.appendChild(el('<p class="empty">No endpoints match “'+escapeHtml(q)+'”.</p>'));
}

function selectEndpoint(e, node) {
  current = e;
  document.querySelectorAll('.ep').forEach(n=>n.classList.remove('active'));
  node?.classList.add('active');
  const form = document.getElementById('form');
  form.innerHTML = '';
  form.appendChild(el('<div class="reqline"><span class="m '+e.method+'">'+e.method+'</span><b class="path">'+e.path+'</b></div>'));
  if (e.summary) form.appendChild(el('<p class="sum">'+e.summary+'</p>'));
  for (const p of e.pathParams) form.appendChild(field('path:'+p, p, lookupStore(p)));
  for (const q of e.queryParams) form.appendChild(field('query:'+q.name, q.name+(q.required?' *':''), lookupStore(q.name)));
  if (e.bodyExample) {
    const head = el('<div class="bar" style="margin:0 0 4px"><label style="margin:0">body</label><button id="beautify" class="ghost" type="button">Beautify</button></div>');
    form.appendChild(head);
    const ta = el('<textarea id="body"></textarea>'); ta.value = e.bodyExample;
    if ((e.bodyVariants && e.bodyVariants.length > 1) || (e.bodyEnums && e.bodyEnums.length)) {
      const pills = el('<div class="pills"></div>');
      if (e.bodyVariants && e.bodyVariants.length > 1) {
        const row = el('<div class="pillrow"><span class="pilllabel">variant</span></div>');
        for (const v of e.bodyVariants) {
          const b = el('<button type="button" class="pill">'+escapeHtml(v.label)+'</button>');
          b.onclick = ()=>{ ta.value = JSON.stringify(v.sample, null, 2); };
          row.appendChild(b);
        }
        pills.appendChild(row);
      }
      for (const slot of (e.bodyEnums||[])) {
        const row = el('<div class="pillrow"><span class="pilllabel">'+escapeHtml(slot.field)+'</span></div>');
        for (const val of slot.values) {
          const b = el('<button type="button" class="pill">'+escapeHtml(val)+'</button>');
          b.onclick = ()=>{
            try { const o = JSON.parse(ta.value); o[slot.field] = val; ta.value = JSON.stringify(o, null, 2); }
            catch (err) { badJson('INVALID JSON', 'fix the body before switching '+slot.field); }
          };
          row.appendChild(b);
        }
        pills.appendChild(row);
      }
      form.appendChild(pills);
    }
    form.appendChild(ta);
    head.querySelector('#beautify').onclick = ()=>{
      try { ta.value = JSON.stringify(JSON.parse(ta.value), null, 2); }
      catch (e) { badJson('INVALID JSON', e.message); }
    };
  }
  const send = el('<div class="bar" style="margin-top:12px"><button id="send">Send</button></div>');
  form.appendChild(send);
  document.getElementById('send').onclick = sendRequest;
  form.appendChild(el('<div id="resp"></div>'));
}

function field(id, label, value) {
  const wrap = el('<div></div>');
  if (value) wrap.classList.add('threaded');
  wrap.appendChild(el('<label>'+label+'</label>'));
  const input = el('<input data-k="'+id+'" autocomplete="off" spellcheck="false" />'); input.value = value;
  wrap.appendChild(input);
  return wrap;
}

function collectInputs(prefix) {
  const out = {};
  document.querySelectorAll('[data-k^="'+prefix+':"]').forEach(i=>{ out[i.dataset.k.split(':')[1]] = i.value; });
  return out;
}

// Replace {{name}} with the captured store value (last response's ids/revision). Unknown
// vars are left as-is so a missing capture is visible rather than silently blanked.
function subst(str) {
  return typeof str === 'string'
    ? str.replace(/\{\{\s*([A-Za-z0-9_]+)\s*\}\}/g, (m, k) => (store[k] != null ? store[k] : m))
    : str;
}

async function sendRequest() {
  const pathParams = collectInputs('path');
  let path = current.path;
  for (const [k,v] of Object.entries(pathParams)) path = path.replace('{'+k+'}', encodeURIComponent(subst(v)));
  const query = collectInputs('query');
  for (const k of Object.keys(query)) query[k] = subst(query[k]);
  const bodyEl = document.getElementById('body');
  const resp = document.getElementById('resp');
  const bodyStr = bodyEl ? subst(bodyEl.value) : undefined;
  if (bodyStr && bodyStr.trim()) {
    try { JSON.parse(bodyStr); }
    catch (e) { return badJson('INVALID JSON', e.message); }
  }
  const payload = { method: current.method, path, query, base: document.getElementById('base').value, body: bodyStr };
  resp.innerHTML = '<p class="sending">◗ sending…</p>';
  let r;
  try {
    r = await fetch('/proxy', { method:'POST', headers:{'content-type':'application/json'}, body: JSON.stringify(payload) }).then(r=>r.json());
  } catch (e) {
    return badJson('PROXY UNREACHABLE', e.message + ' — is the console server running?');
  }
  const ok = r.status>=200 && r.status<300;
  resp.innerHTML = '';
  resp.appendChild(el('<div class="bar" style="margin-top:10px"><span class="status '+(ok?'ok':'bad')+'">'+(r.status||'ERR')+' '+(r.statusText||'')+'</span><span class="sum">click any highlighted id to capture it</span></div>'));
  resp.appendChild(renderResp(r.body ?? r.error));
  capture(r.body);
}

function badJson(label, msg) {
  const resp = document.getElementById('resp');
  resp.innerHTML = '';
  resp.appendChild(el('<div class="bar" style="margin-top:10px"><span class="status bad">'+label+'</span><span class="sum">'+escapeHtml(msg)+'</span></div>'));
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
    const row = el('<div class="var"><span class="jack">◗</span><b>'+k+'</b><span class="val">'+escapeHtml(store[k])+'</span></div>');
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
  document.querySelectorAll('[data-k]').forEach(i=>{ if (idMatch(i.dataset.k.split(':')[1], k)) { i.value = store[k]; if (i.parentElement) i.parentElement.classList.add('threaded'); } });
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
document.getElementById('filter').oninput = (ev)=>renderList(ev.target.value);
</script>
</body>
</html>`;
