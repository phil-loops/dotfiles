import { spawn } from "node:child_process";
import { readFile } from "node:fs/promises";
import { createServer } from "node:http";
import { resolve } from "node:path";
import { mergeWorkflowOverlay } from "./workflow-overlay.mjs";

const DEV_TOKEN = "00112233445566778899aabbccddeeff";
const DEFAULT_SPEC = "https://app.loops.so/openapi.json";

// Business rules the OpenAPI schema can't express: an enum field the spec lists in full
// but the server only accepts a subset of for a given endpoint (the rest 400). First value
// is the default. Key = "METHOD path::field".
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

// "You must provide one of these" rules the spec only states in prose. Key = "METHOD path",
// value = groups of field names; the first of each group is the one loaded by default.
const ONE_OF_HINTS = {
  "PUT /v1/contacts/update": [["email", "userId"]],
  "DELETE /v1/contacts/delete": [["email", "userId"]],
  "GET /v1/contacts/find": [["email", "userId"]],
  "GET /v1/contacts/suppression": [["email", "userId"]],
  "POST /v1/events/send": [["email", "userId"]],
};
const oneOfHint = (method, path) => ONE_OF_HINTS[`${method} ${path}`] ?? null;

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
  const init = { method, headers: { authorization: `Bearer ${token}` } };
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

/* ---------- spec → param model ------------------------------------------------------ */

const deref = (schema, spec) => {
  if (schema?.$ref) {
    const name = schema.$ref.split("/").pop();
    return spec.components?.schemas?.[name] ?? {};
  }
  return schema ?? {};
};

// Fold allOf into a single {properties, required, additionalProperties} view.
const flatten = (schema, spec) => {
  const s = deref(schema, spec);
  if (!s.allOf) {
    return s;
  }
  const out = { type: "object", properties: {}, required: [] };
  for (const part of [...s.allOf, s]) {
    const p = flatten(part, spec);
    Object.assign(out.properties, p.properties ?? {});
    out.required.push(...(p.required ?? []));
    if (p.additionalProperties) {
      out.additionalProperties = p.additionalProperties;
    }
  }
  return out;
};

const typeOf = (s) => {
  if (Array.isArray(s.type)) {
    return s.type.find((t) => t !== "null") ?? "string";
  }
  return s.type ?? (s.properties ? "object" : s.items ? "array" : "string");
};

const fieldOf = (name, raw, spec, required, method, path) => {
  const s = flatten(raw, spec);
  const allow = enumHint(method, path, name);
  const values = allow ?? (s.enum ? s.enum.map(String) : null);
  const shapes = s["x-shapes"];
  const f = {
    name,
    type: shapes ? "object" : typeOf(s),
    required: required.includes(name),
    nullable: !!s.nullable || (Array.isArray(s.type) && s.type.includes("null")),
    description: s.description ?? null,
    values,
    sample: values ? values[0] : sample(s, spec, name),
  };
  if (shapes) {
    f.shapesLabel = shapes.label;
    f.shapes = Object.entries(shapes.shapes).map(([label, def]) =>
      shapeOf(label, def, spec, method, path)
    );
  }
  return f;
};

// A hand-written shape (node-payloads.mjs) → the same model the spec-derived shapes use.
const shapeOf = (label, def, spec, method, path) => ({
  label,
  note: def.note ?? null,
  atLeastOne: !!def.atLeastOne,
  exclusive: def.exclusive ?? null,
  oneOf: null,
  additional: null,
  fields: Object.entries(def.properties ?? {}).map(([n, p]) =>
    fieldOf(n, p, spec, def.required ?? [], method, path)
  ),
});

const objectShape = (schema, spec, method, path, label) => {
  const s = flatten(schema, spec);
  const extra = s.additionalProperties;
  return {
    label,
    note: s.description ?? null,
    atLeastOne: false,
    exclusive: null,
    oneOf: oneOfHint(method, path),
    additional: extra && extra !== false ? additionalTypes(extra, spec) : null,
    fields: Object.entries(s.properties ?? {}).map(([n, p]) =>
      fieldOf(n, p, spec, s.required ?? [], method, path)
    ),
  };
};

const additionalTypes = (extra, spec) => {
  const s = deref(extra, spec);
  const branches = s.oneOf ?? s.anyOf;
  const types = branches ? branches.map((b) => typeOf(deref(b, spec))) : [typeOf(s)];
  return [...new Set(types)];
};

const shapeLabel = (s, spec, discriminator, i) => {
  if (s.title) {
    return s.title;
  }
  if (discriminator) {
    const v = singleEnumValue(s, spec, discriminator);
    if (v) {
      return v;
    }
  }
  for (const k of Object.keys(s.properties ?? {})) {
    const v = singleEnumValue(s, spec, k);
    if (v) {
      return v;
    }
  }
  return `variant ${i + 1}`;
};

const singleEnumValue = (schema, spec, prop) => {
  const vs = deref(schema.properties?.[prop], spec);
  const vals = vs?.enum ?? (vs?.const !== undefined ? [vs.const] : null);
  return vals?.length === 1 ? String(vals[0]) : null;
};

// A oneOf/anyOf body becomes several shapes the user picks between; a plain object, one.
// A discriminator hint trims the branches to the ones the server actually accepts.
const bodyOf = (op, spec, method, path) => {
  const schema = flatten(op.requestBody?.content?.["application/json"]?.schema, spec);
  const branches = schema.oneOf ?? schema.anyOf;
  if (!branches?.length && !schema.properties) {
    return null;
  }
  const head = {
    required: op.requestBody?.required !== false,
    description: op.requestBody?.description ?? null,
    selector: null,
  };
  if (!branches?.length) {
    return { ...head, shapes: [objectShape(schema, spec, method, path, "body")] };
  }
  const discriminator = schema.discriminator?.propertyName;
  const allow = discriminator ? enumHint(method, path, discriminator) : null;
  let shapes = branches.map((b, i) => {
    const s = flatten(b, spec);
    return {
      ...objectShape(s, spec, method, path, shapeLabel(s, spec, discriminator, i)),
      value: discriminator ? singleEnumValue(s, spec, discriminator) : null,
    };
  });
  if (allow?.length) {
    shapes = shapes
      .filter((s) => s.value == null || allow.includes(s.value))
      .sort((a, b) => allow.indexOf(a.value) - allow.indexOf(b.value));
  }
  return { ...head, selector: "body shape", shapes };
};

const extractEndpoints = (spec) => {
  const out = [];
  for (const [path, methods] of Object.entries(spec.paths ?? {})) {
    for (const [method, op] of Object.entries(methods)) {
      if (!["get", "post", "put", "patch", "delete"].includes(method)) {
        continue;
      }
      const METHOD = method.toUpperCase();
      const params = op.parameters ?? [];
      out.push({
        method: METHOD,
        path,
        tag: op.tags?.[0] ?? "Other",
        summary: op.summary ?? "",
        description: op.description ?? "",
        pathParams: [...path.matchAll(/\{([^}]+)\}/g)].map((m) => {
          const p = params.find((x) => x.in === "path" && x.name === m[1]);
          return { name: m[1], description: p?.description ?? null };
        }),
        queryParams: params
          .filter((p) => p.in === "query")
          .map((p) => ({
            ...fieldOf(p.name, p.schema ?? {}, spec, p.required ? [p.name] : [], METHOD, path),
            description: p.description ?? null,
          })),
        queryOneOf: oneOfHint(METHOD, path),
        body: bodyOf(op, spec, METHOD, path),
      });
    }
  }
  return out;
};

const sample = (schema, spec, key) => {
  schema = deref(schema, spec);
  if (schema.example !== undefined) {
    return schema.example;
  }
  if (schema.examples?.length) {
    return schema.examples[0];
  }
  if (schema.enum) {
    return schema.enum[0];
  }
  if (schema.allOf) {
    return schema.allOf.reduce((acc, s) => Object.assign(acc, sample(s, spec, key)), {});
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
    return /(subscribed|enabled|active|eligible)/i.test(key);
  }
  if (schema.type === "integer" || schema.type === "number") {
    return 1;
  }
  return sampleString(key);
};

const sampleString = (key) => {
  // {{var}} placeholders are substituted from captured response ids at send time, so
  // multi-step flows don't need manual id copying.
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

/* ---------- page --------------------------------------------------------------------- */

const page = ({ endpoints, base }) => `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8" />
<meta name="viewport" content="width=device-width, initial-scale=1" />
<title>Loops API Bench</title>
<link rel="preconnect" href="https://fonts.googleapis.com">
<link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
<link href="https://fonts.googleapis.com/css2?family=Bricolage+Grotesque:opsz,wdth,wght@12..96,75..100,500;600;700&family=JetBrains+Mono:wght@400;500;700&display=swap" rel="stylesheet">
<style>
:root {
  color-scheme: dark;
  --ink:#0F1417; --panel:#151C20; --well:#0A0F11; --edge:#222E33; --edge-lit:#33444B;
  --fg:#DCE5E4; --muted:#7B8F92; --faint:#4E6165;
  --GET:#4FD1A5; --POST:#6FA8FF; --PUT:#F2B347; --PATCH:#F2B347; --DELETE:#FF7A85;
  --verb:#6FA8FF;                      /* retinted to the selected endpoint's method */
  --warn:#F2B347;
  --mono:'JetBrains Mono', ui-monospace, SFMono-Regular, Menlo, monospace;
  --ui:'Bricolage Grotesque', ui-sans-serif, system-ui, sans-serif;
}
* { box-sizing:border-box; }
body { margin:0; font:13px/1.55 var(--mono); background:var(--ink); color:var(--fg);
  display:grid; grid-template-columns:264px 1fr 300px; grid-template-rows:auto 1fr; height:100vh; }

/* the one display face, used only for the wordmark and the small caps labels */
.wordmark { font:700 15px/1 var(--ui); font-stretch:100%; letter-spacing:-.01em; }
.wordmark em { font-style:normal; color:var(--muted); font-weight:500; }
h2, .cap { font:600 9px/1 var(--ui); text-transform:uppercase; letter-spacing:.17em; color:var(--muted); }

.top { grid-column:1/-1; display:flex; align-items:center; gap:20px; padding:12px 16px;
  border-bottom:1px solid var(--edge); background:var(--panel); }
.rule { flex:1; height:1px; background:linear-gradient(90deg, var(--edge), transparent); }
.baseline { display:flex; align-items:center; gap:9px; min-width:340px; }
.baseline input { font-size:12px; padding:6px 9px; }
.live { display:flex; align-items:center; gap:7px; white-space:nowrap; }
.live .dot { width:6px; height:6px; border-radius:50%; background:var(--GET); box-shadow:0 0 8px var(--GET); }

.col { overflow:auto; padding:14px; }
#list { border-right:1px solid var(--edge); }
#store { border-left:1px solid var(--edge); background:var(--panel); }
#main { padding:18px 22px 60px; }
h2 { margin:20px 0 8px; }
h2:first-child { margin-top:0; }

.ep { padding:5px 8px; border-radius:6px; cursor:pointer; display:flex; gap:9px; align-items:baseline;
  border-left:2px solid transparent; }
.ep:hover { background:var(--well); }
.ep.active { background:var(--well); border-left-color:var(--verb); }
.m { font:700 9px/1.5 var(--mono); letter-spacing:.04em; flex:0 0 44px; text-align:right; }
.GET{color:var(--GET);} .POST{color:var(--POST);} .PUT{color:var(--PUT);} .PATCH{color:var(--PATCH);} .DELETE{color:var(--DELETE);}
.ep .path { word-break:break-all; font-size:12px; }

/* the request line: path params are editable slots inside the real URL */
.reqline { display:flex; gap:12px; align-items:center; flex-wrap:wrap; padding-bottom:12px;
  border-bottom:1px solid var(--edge); }
.reqline .m { flex:0 0 auto; font-size:11px; padding:4px 8px; border-radius:5px;
  border:1px solid currentColor; text-align:center; }
.url { font:500 15px/1.9 var(--mono); word-break:break-all; }
.slot { display:inline-block; background:var(--well); border:1px solid var(--edge-lit); border-bottom:2px solid var(--verb);
  border-radius:5px 5px 3px 3px; color:var(--fg); font:500 14px/1 var(--mono); padding:5px 7px; width:11ch;
  transition:width .12s ease; }
.slot:focus { outline:none; border-color:var(--verb); box-shadow:0 0 0 3px color-mix(in srgb, var(--verb) 16%, transparent); }
.slot.filled { color:var(--verb); }
.sum { color:var(--muted); font-size:12px; margin:12px 0 0; max-width:70ch; }
.sum a, .sum code { color:var(--fg); }

/* param rack — the spine of the bench */
.rack { margin-top:22px; }
.band { display:flex; align-items:center; gap:9px; margin:20px 0 8px; }
.band .n { color:var(--verb); font-weight:700; }
.band .rule { height:1px; }
.hint { color:var(--faint); font-size:11px; margin:-2px 0 8px; }
.hint b { color:var(--muted); font-weight:500; }

.p { display:grid; grid-template-columns:minmax(120px,180px) 1fr auto; gap:10px; align-items:start;
  padding:8px 10px; border-radius:7px; border:1px solid transparent; }
.p + .p { margin-top:2px; }
.p.on { background:var(--well); border-color:var(--edge); }
.p.off { cursor:pointer; opacity:.62; }
.p.off:hover { opacity:1; background:var(--well); }
.p.blocked { opacity:.4; }
.p.blocked:hover { opacity:.75; }
.p.extra { border-color:color-mix(in srgb, var(--warn) 40%, transparent);
  background:color-mix(in srgb, var(--warn) 7%, var(--well)); }
.p .k { display:flex; flex-direction:column; gap:3px; padding-top:6px; }
.p .k b { font:500 13px/1.2 var(--mono); color:var(--fg); }
.p.off .k b { color:var(--muted); }
.p .meta { display:flex; gap:6px; align-items:center; flex-wrap:wrap; }
.t { font:500 9px/1 var(--ui); letter-spacing:.1em; text-transform:uppercase; color:var(--faint); }
.t.req { color:var(--verb); }
.t.warn { color:var(--warn); }
.p .d { color:var(--faint); font-size:11px; line-height:1.5; grid-column:2; margin-top:5px; }
.p.off .v { display:none; }
.p.off .d { grid-column:2; margin-top:6px; }
.act { display:flex; gap:4px; align-items:center; padding-top:3px; }

input, textarea, select { width:100%; background:var(--well); border:1px solid var(--edge); color:var(--fg);
  border-radius:6px; padding:7px 9px; font:13px/1.4 var(--mono); }
.p.on input, .p.on textarea, .p.on select { background:var(--ink); }
input::placeholder { color:var(--faint); }
input:focus, textarea:focus, select:focus { outline:none; border-color:var(--verb);
  box-shadow:0 0 0 3px color-mix(in srgb, var(--verb) 15%, transparent); }
textarea { min-height:76px; resize:vertical; }
input.nulled { color:var(--faint); font-style:italic; }
.seg { display:flex; gap:0; }
.seg button { border-radius:0; border:1px solid var(--edge); background:var(--well); color:var(--muted);
  padding:7px 14px; font:500 12px/1.4 var(--mono); letter-spacing:0; }
.seg button:first-child { border-radius:6px 0 0 6px; }
.seg button:last-child { border-radius:0 6px 6px 0; border-left:none; }
.seg button[aria-pressed="true"] { background:color-mix(in srgb, var(--verb) 18%, var(--well));
  color:var(--verb); border-color:var(--verb); }

button { background:var(--verb); color:var(--ink); border:none; border-radius:6px; padding:10px 20px;
  font:600 12px/1 var(--ui); letter-spacing:.06em; cursor:pointer; }
button:hover { filter:brightness(1.1); }
button:focus-visible { outline:2px solid var(--fg); outline-offset:2px; }
.x { background:transparent; color:var(--faint); border:1px solid transparent; padding:5px 8px;
  font:500 13px/1 var(--mono); letter-spacing:0; }
.x:hover { color:var(--DELETE); border-color:var(--edge); filter:none; }
.null { background:transparent; color:var(--faint); border:1px solid var(--edge); padding:5px 8px;
  font:500 11px/1 var(--mono); letter-spacing:0; border-radius:5px; }
.null:hover { color:var(--fg); border-color:var(--edge-lit); filter:none; }
.null[aria-pressed="true"] { color:var(--verb); border-color:var(--verb);
  background:color-mix(in srgb, var(--verb) 14%, transparent); }
.add { color:var(--verb); background:transparent; border:1px dashed var(--edge-lit); width:100%;
  text-align:left; padding:9px 11px; font:500 12px/1 var(--mono); letter-spacing:0; }
.add:hover { border-color:var(--verb); border-style:solid; background:var(--well); filter:none; }

.pills { display:flex; flex-wrap:wrap; gap:5px; align-items:center; margin:6px 0 2px; }
.pill { background:var(--well); color:var(--muted); border:1px solid var(--edge); border-radius:999px;
  padding:5px 12px; font:500 11px/1 var(--mono); letter-spacing:0; }
.pill:hover { border-color:var(--edge-lit); color:var(--fg); filter:none; }
.pill[aria-pressed="true"] { background:color-mix(in srgb, var(--verb) 16%, transparent);
  color:var(--verb); border-color:var(--verb); }

.sub { grid-column:1/-1; margin:10px 0 2px; padding:12px 0 4px 14px;
  border-left:1px solid var(--edge); }
.tabs { display:flex; gap:2px; margin:0 0 10px; }
.tab { background:transparent; color:var(--muted); border:none; border-bottom:2px solid transparent;
  border-radius:0; padding:6px 12px; font:600 10px/1 var(--ui); letter-spacing:.14em; text-transform:uppercase; }
.tab:hover { color:var(--fg); filter:none; }
.tab[aria-pressed="true"] { color:var(--fg); border-bottom-color:var(--verb); }
#raw { min-height:220px; }

.bar { display:flex; gap:12px; align-items:center; margin-top:22px; }
.status { font:700 11px/1 var(--mono); padding:6px 10px; border-radius:5px; }
.ok { background:color-mix(in srgb, var(--GET) 15%, transparent); color:var(--GET); border:1px solid color-mix(in srgb, var(--GET) 40%, transparent); }
.bad { background:color-mix(in srgb, var(--DELETE) 15%, transparent); color:var(--DELETE); border:1px solid color-mix(in srgb, var(--DELETE) 42%, transparent); }
pre { background:var(--well); border:1px solid var(--edge); border-radius:8px; padding:13px; overflow:auto;
  max-height:42vh; white-space:pre-wrap; word-break:break-word; margin-top:12px; }
.json .cap2 { color:var(--verb); cursor:pointer; border-bottom:1px dashed color-mix(in srgb, var(--verb) 55%, transparent); }
.json .cap2:hover { background:color-mix(in srgb, var(--verb) 18%, transparent); }

.var { display:flex; align-items:center; gap:8px; padding:7px 9px; border-radius:6px; cursor:pointer;
  border:1px solid var(--edge); background:var(--well); margin-bottom:5px; }
.var:hover { border-color:var(--verb); }
.var b { color:var(--fg); font-weight:500; font-size:12px; }
.var .val { color:var(--faint); margin-left:auto; max-width:130px; overflow:hidden; text-overflow:ellipsis;
  white-space:nowrap; font-size:11px; }
.related a { display:block; color:var(--muted); cursor:pointer; padding:4px 0; font-size:12px; }
.related a:hover { color:var(--fg); }
.empty { color:var(--faint); font-size:11px; line-height:1.7; }
code.b { color:var(--verb); }
.note { color:var(--muted); font-size:11px; line-height:1.6; border-left:2px solid var(--edge-lit);
  padding:2px 0 2px 10px; margin:10px 0; }
.note.warn { border-left-color:var(--warn); color:var(--warn); }

.sending { color:var(--verb); }
@keyframes pulse { 0%,100%{opacity:.4} 50%{opacity:1} }
@keyframes lift { from { opacity:0; transform:translateY(5px); } }
@media (prefers-reduced-motion:no-preference) {
  .sending { animation:pulse 1.1s ease-in-out infinite; }
  .p.on.fresh { animation:lift .18s ease-out; }
}
@media (max-width:980px) {
  body { grid-template-columns:1fr; grid-template-rows:auto auto auto auto; height:auto; }
  #list, #store { border:none; border-top:1px solid var(--edge); }
  .top { flex-wrap:wrap; }
  .baseline { min-width:0; flex:1; }
  .p { grid-template-columns:1fr; }
  .p .d, .p .v { grid-column:1; }
}
</style>
</head>
<body>
<header class="top">
  <div class="wordmark">Loops <em>API bench</em></div>
  <div class="rule"></div>
  <div class="baseline"><span class="cap">base</span><input id="base" value="${base}" spellcheck="false" /></div>
  <div class="live"><span class="dot"></span><span class="cap">local</span></div>
</header>

<div id="list" class="col">
  <input id="filter" placeholder="filter endpoints…" autocomplete="off" spellcheck="false" style="margin-bottom:12px" />
  <div id="eps"></div>
</div>

<div id="main" class="col">
  <div id="form"><p class="empty">Pick an endpoint to build a request.</p></div>
</div>

<div id="store" class="col">
  <h2>Captured</h2>
  <div id="vars"></div>
  <h2>Related</h2>
  <div id="related" class="related"><p class="empty">Pick a captured id to see which endpoints take it.</p></div>
</div>

<script>
const ENDPOINTS = ${JSON.stringify(endpoints)};
const store = {};        // captured ids: name -> value
let current = null;      // selected endpoint
let st = null;           // request state for the selected endpoint
let selectedVar = null;

const el = (h) => { const d = document.createElement('div'); d.innerHTML = h; return d.firstElementChild; };
const esc = (s) => String(s).replace(/[&<>"]/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;'}[c]));
// Spec descriptions are written for the docs site: backticked code, <br>, markdown links.
const md = (s) => esc(s)
  .replace(/&lt;br&gt;/g, '<br>')
  .replace(/\`([^\`]+)\`/g, '<code class="b">$1</code>')
  .replace(/\\[([^\\]]+)\\]\\(([^)]+)\\)/g, '<a href="$2" target="_blank" rel="noreferrer">$1</a>');
// Every path is under /v1 — the index reads better without it, and stops wrapping mid-word.
const shortPath = (p) => (p.startsWith('/v1/') ? p.slice(4) : p);
const byTag = ENDPOINTS.reduce((a,e) => ((a[e.tag] ??= []).push(e), a), {});

/* ---------- endpoint index ---------- */

function renderList(q) {
  const list = document.getElementById('eps');
  q = (q || '').trim().toLowerCase();
  list.innerHTML = '';
  for (const tag of Object.keys(byTag)) {
    const eps = byTag[tag].filter(e => !q || (e.method + ' ' + e.path + ' ' + e.summary).toLowerCase().includes(q));
    if (!eps.length) continue;
    list.appendChild(el('<h2>' + esc(tag) + '</h2>'));
    for (const e of eps) {
      const node = el('<div class="ep"><span class="m ' + e.method + '">' + e.method + '</span><span class="path">' + esc(shortPath(e.path)) + '</span></div>');
      node.onclick = () => selectEndpoint(e, node);
      list.appendChild(node);
    }
  }
  if (!list.children.length) list.appendChild(el('<p class="empty">No endpoint matches that.</p>'));
}

/* ---------- request state ---------- */

// One entry per field: on (is it in the request), value (always a string — parsed at build),
// isNull (send an explicit null), sub (nested rack for a field whose shape depends on a pick).
function entryFor(f) {
  return {
    on: false,
    isNull: false,
    value: f.shapes ? '' : toStr(f.sample),
    sub: f.shapes ? subState(f, f.shapes[0].label) : null,
  };
}
function subState(f, label) {
  const shape = f.shapes.find(s => s.label === label) || f.shapes[0];
  return { label: shape.label, fields: seedFields(shape), extra: {}, custom: [] };
}
function seedFields(shape) {
  const fields = {};
  for (const f of shape.fields) fields[f.name] = entryFor(f);
  for (const f of shape.fields) if (f.required) fields[f.name].on = true;
  for (const g of (shape.oneOf || [])) if (!g.some(n => fields[n]?.on)) { if (fields[g[0]]) fields[g[0]].on = true; }
  // "at least one field" shapes have nothing required, so open with the first real field on —
  // an empty body is never a legal request for them.
  if (shape.atLeastOne && !Object.values(fields).some(e => e.on)) {
    const first = shape.fields.find(f => f.name !== 'typeName');
    if (first) fields[first.name].on = true;
  }
  return fields;
}
function toStr(v) {
  if (v == null) return '';
  return typeof v === 'object' ? JSON.stringify(v, null, 2) : String(v);
}
function shapeOfState(sh, s) { return sh.find(x => x.label === s.label) || sh[0]; }

function selectEndpoint(e, node) {
  current = e;
  document.body.style.setProperty('--verb', getComputedStyle(document.body).getPropertyValue('--' + e.method));
  document.querySelectorAll('.ep').forEach(n => n.classList.remove('active'));
  if (node) node.classList.add('active');
  else document.querySelectorAll('.ep').forEach(n => {
    if (n.querySelector('.path').textContent === e.path && n.querySelector('.m').textContent === e.method) n.classList.add('active');
  });
  st = {
    path: Object.fromEntries(e.pathParams.map(p => [p.name, lookupStore(p.name)])),
    query: { fields: seedFields({ fields: e.queryParams, oneOf: e.queryOneOf }), extra: {}, custom: null },
    body: e.body ? subState({ shapes: e.body.shapes }, e.body.shapes[0].label) : null,
    tab: 'fields',
    raw: '',
  };
  render();
}

/* ---------- render ---------- */

function render() {
  const e = current, form = document.getElementById('form');
  const resp = document.getElementById('resp');
  const keep = resp ? resp.innerHTML : '';
  form.innerHTML = '';

  const line = el('<div class="reqline"><span class="m ' + e.method + '">' + e.method + '</span></div>');
  line.appendChild(urlLine(e));
  form.appendChild(line);
  if (e.summary) form.appendChild(el('<p class="sum">' + esc(e.summary) + '</p>'));
  if (e.description) form.appendChild(el('<p class="sum">' + md(e.description) + '</p>'));

  const rack = el('<div class="rack"></div>');
  if (e.queryParams.length) {
    rack.appendChild(bandOf('query', null));
    if (e.queryOneOf) rack.appendChild(oneOfHint(e.queryOneOf));
    renderRack(rack, { fields: e.queryParams, oneOf: e.queryOneOf }, st.query, () => render());
  }
  if (e.body) renderBody(rack, e);
  form.appendChild(rack);

  const send = el('<div class="bar"><button id="send">Send ' + e.method + '</button></div>');
  form.appendChild(send);
  document.getElementById('send').onclick = sendRequest;
  const box = el('<div id="resp"></div>');
  box.innerHTML = keep;
  form.appendChild(box);
  if (keep) rewireCaptures(box);
}

// The path renders as the URL you're about to hit, with each {param} an editable slot.
function urlLine(e) {
  const wrap = el('<div class="url"></div>');
  const parts = e.path.split(/(\\{[^}]+\\})/);
  for (const part of parts) {
    const m = part.match(/^\\{([^}]+)\\}$/);
    if (!m) { wrap.appendChild(document.createTextNode(part)); continue; }
    const name = m[1];
    const input = el('<input class="slot" spellcheck="false" autocomplete="off" placeholder="' + esc(name) + '" title="' + esc(name) + '" />');
    input.value = st.path[name] || '';
    const fit = () => {
      input.style.width = (Math.max(name.length, input.value.length) + 2) + 'ch';
      input.classList.toggle('filled', !!input.value);
    };
    fit();
    input.oninput = () => { st.path[name] = input.value; fit(); };
    wrap.appendChild(input);
  }
  return wrap;
}

function bandOf(label, n) {
  const count = n == null ? '' : ' <span class="n">' + n + '</span>';
  return el('<div class="band"><span class="cap">' + esc(label) + count + '</span><span class="rule"></span></div>');
}

function oneOfHint(groups) {
  const txt = groups.map(g => g.map(n => '<b>' + esc(n) + '</b>').join(' or ')).join(', ');
  return el('<p class="hint">Provide at least one of ' + txt + '.</p>');
}

function renderBody(rack, e) {
  const shapes = e.body.shapes;
  const shape = shapeOfState(shapes, st.body);

  const head = el('<div class="band"><span class="cap">body</span><span class="rule"></span></div>');
  const tabs = el('<div class="tabs"></div>');
  for (const t of ['fields', 'json']) {
    const b = el('<button class="tab" aria-pressed="' + (st.tab === t) + '">' + t + '</button>');
    b.onclick = () => switchTab(t);
    tabs.appendChild(b);
  }
  head.appendChild(tabs);
  rack.appendChild(head);

  if (st.tab === 'json') {
    const ta = el('<textarea id="raw" spellcheck="false"></textarea>');
    ta.value = st.raw || JSON.stringify(buildShape(shape, st.body), null, 2);
    ta.oninput = () => { st.raw = ta.value; };
    rack.appendChild(ta);
    rack.appendChild(el('<p class="hint">Edited here, then switch back to <b>fields</b> — anything the schema does not name shows up as an unknown parameter.</p>'));
    return;
  }

  if (shapes.length > 1) rack.appendChild(picker(e.body.selector || 'shape', shapes, st.body.label, l => {
    st.body = subState({ shapes }, l);
    render();
  }));
  if (e.body.description) rack.appendChild(el('<p class="hint">' + md(e.body.description) + '</p>'));
  renderRack(rack, shape, st.body, () => render());
}

function picker(label, shapes, active, onPick) {
  const row = el('<div class="pills"></div>');
  row.appendChild(el('<span class="cap" style="margin-right:4px">' + esc(label) + '</span>'));
  for (const s of shapes) {
    const b = el('<button class="pill" aria-pressed="' + (s.label === active) + '">' + esc(s.label) + '</button>');
    b.onclick = () => onPick(s.label);
    row.appendChild(b);
  }
  return row;
}

// The rack: what the request is sending, then every parameter it could still take.
function renderRack(rack, shape, state, redraw) {
  const fields = shape.fields;
  const on = fields.filter(f => state.fields[f.name]?.on);
  const off = fields.filter(f => !state.fields[f.name]?.on);
  const extras = Object.keys(state.extra || {});

  if (shape.note) rack.appendChild(el('<p class="note">' + esc(shape.note) + '</p>'));
  if (shape.oneOf) rack.appendChild(oneOfHint(shape.oneOf));
  if (shape.atLeastOne && !on.length) rack.appendChild(el('<p class="note warn">This node type needs at least one field — add one below.</p>'));

  if (on.length && off.length) rack.appendChild(bandOf('sending', on.length));
  for (const f of on) rack.appendChild(paramOn(f, shape, state, redraw));
  for (const k of extras) rack.appendChild(paramExtra(k, state, redraw));

  if (state.custom) {
    for (let i = 0; i < state.custom.length; i++) rack.appendChild(paramCustom(i, state, redraw));
  }

  if (off.length || shape.additional) {
    rack.appendChild(bandOf('can also send', off.length + (shape.additional ? 1 : 0)));
    for (const f of off) rack.appendChild(paramOff(f, shape, state, redraw));
    if (shape.additional) {
      const b = el('<button class="add">+ custom property &nbsp;<span class="t">' + shape.additional.join(' · ') + '</span></button>');
      b.onclick = () => { state.custom.push({ key: '', value: '' }); redraw(); };
      rack.appendChild(b);
    }
  }
}

const blockers = (f, shape, state) =>
  (shape.exclusive || [])
    .filter(g => g.includes(f.name))
    .flatMap(g => g.filter(n => n !== f.name && state.fields[n]?.on));

function meta(f, extra) {
  const bits = [];
  bits.push('<span class="t">' + esc(f.type) + (f.nullable ? ' | null' : '') + '</span>');
  if (f.required) bits.push('<span class="t req">required</span>');
  return bits.concat(extra || []).join('');
}

function paramOn(f, shape, state, redraw) {
  const e = state.fields[f.name];
  const row = el('<div class="p on fresh"></div>');
  row.appendChild(el('<div class="k"><b>' + esc(f.name) + '</b><span class="meta">' + meta(f) + '</span></div>'));

  const v = el('<div class="v"></div>');
  if (f.shapes) {
    const sub = el('<div class="sub"></div>');
    const shapeNow = shapeOfState(f.shapes, e.sub);
    if (f.description) sub.appendChild(el('<p class="hint">' + md(f.description) + '</p>'));
    sub.appendChild(picker(f.shapesLabel, f.shapes, e.sub.label, l => { e.sub = subState(f, l); redraw(); }));
    renderRack(sub, shapeNow, e.sub, redraw);
    row.appendChild(el('<div class="v"></div>'));
    row.appendChild(el('<div class="act"></div>'));
    row.appendChild(sub);
    return row;
  } else if (e.isNull) {
    const i = el('<input class="nulled" value="null" readonly />');
    v.appendChild(i);
  } else if (f.values) {
    const sel = el('<select></select>');
    for (const val of f.values) sel.appendChild(el('<option ' + (String(e.value) === String(val) ? 'selected' : '') + '>' + esc(val) + '</option>'));
    sel.onchange = () => { e.value = sel.value; };
    v.appendChild(sel);
  } else if (f.type === 'boolean') {
    const seg = el('<div class="seg"></div>');
    for (const val of ['true', 'false']) {
      const b = el('<button aria-pressed="' + (e.value === val) + '">' + val + '</button>');
      b.onclick = () => { e.value = val; redraw(); };
      seg.appendChild(b);
    }
    v.appendChild(seg);
  } else if (f.type === 'object' || f.type === 'array') {
    const ta = el('<textarea spellcheck="false"></textarea>');
    ta.value = e.value;
    ta.oninput = () => { e.value = ta.value; };
    v.appendChild(ta);
  } else {
    const i = el('<input spellcheck="false" autocomplete="off" data-k="' + esc(f.name) + '" />');
    i.value = e.value;
    i.oninput = () => { e.value = i.value; };
    v.appendChild(i);
  }

  if (!f.shapes) {
    row.appendChild(v);
    const act = el('<div class="act"></div>');
    if (f.nullable) {
      const nb = el('<button class="null" aria-pressed="' + e.isNull + '" title="send an explicit null">null</button>');
      nb.onclick = () => { e.isNull = !e.isNull; redraw(); };
      act.appendChild(nb);
    }
    if (!f.required) {
      const x = el('<button class="x" title="remove from the request">✕</button>');
      x.onclick = () => { e.on = false; redraw(); };
      act.appendChild(x);
    }
    row.appendChild(act);
  }
  if (f.description) row.appendChild(el('<p class="d">' + md(f.description) + '</p>'));
  setTimeout(() => row.classList.remove('fresh'), 250);
  return row;
}

function paramOff(f, shape, state, redraw) {
  const blocked = blockers(f, shape, state);
  const row = el('<div class="p off' + (blocked.length ? ' blocked' : '') + '"></div>');
  const note = blocked.length
    ? '<span class="t warn">swaps out ' + esc(blocked.join(', ')) + '</span>'
    : '';
  row.appendChild(el('<div class="k"><b>+ ' + esc(f.name) + '</b><span class="meta">' + meta(f, [note]) + '</span></div>'));
  if (f.description) row.appendChild(el('<p class="d">' + md(f.description) + '</p>'));
  row.onclick = () => {
    for (const b of blocked) state.fields[b].on = false;
    state.fields[f.name].on = true;
    redraw();
  };
  return row;
}

// A key the endpoint's schema doesn't name — kept, but flagged: these endpoints are strict.
function paramExtra(key, state, redraw) {
  const row = el('<div class="p on extra"></div>');
  row.appendChild(el('<div class="k"><b>' + esc(key) + '</b><span class="meta"><span class="t warn">unknown parameter</span></span></div>'));
  const v = el('<div class="v"></div>');
  const i = el('<input spellcheck="false" />');
  i.value = toStr(state.extra[key]);
  i.oninput = () => { state.extra[key] = i.value; };
  v.appendChild(i);
  row.appendChild(v);
  const act = el('<div class="act"></div>');
  const x = el('<button class="x">✕</button>');
  x.onclick = () => { delete state.extra[key]; redraw(); };
  act.appendChild(x);
  row.appendChild(act);
  row.appendChild(el('<p class="d">Not in the schema. Most endpoints reject a body they do not recognise.</p>'));
  return row;
}

function paramCustom(i, state, redraw) {
  const c = state.custom[i];
  const row = el('<div class="p on"></div>');
  const k = el('<div class="k"></div>');
  const ki = el('<input placeholder="property name" spellcheck="false" />');
  ki.value = c.key;
  ki.oninput = () => { c.key = ki.value; };
  k.appendChild(ki);
  row.appendChild(k);
  const v = el('<div class="v"></div>');
  const vi = el('<input placeholder="value" spellcheck="false" />');
  vi.value = c.value;
  vi.oninput = () => { c.value = vi.value; };
  v.appendChild(vi);
  row.appendChild(v);
  const act = el('<div class="act"></div>');
  const x = el('<button class="x">✕</button>');
  x.onclick = () => { state.custom.splice(i, 1); redraw(); };
  act.appendChild(x);
  row.appendChild(act);
  return row;
}

/* ---------- fields ⇄ json ---------- */

function switchTab(t) {
  if (t === st.tab) return;
  const shapes = current.body.shapes;
  const shape = shapeOfState(shapes, st.body);
  if (t === 'json') {
    st.raw = JSON.stringify(buildShape(shape, st.body), null, 2);
  } else {
    let parsed;
    try { parsed = JSON.parse(st.raw || '{}'); }
    catch (err) { return fail('INVALID JSON', err.message); }
    if (!parsed || typeof parsed !== 'object' || Array.isArray(parsed)) return fail('INVALID JSON', 'the body must be an object');
    hydrate(shape, st.body, parsed);
  }
  st.tab = t;
  render();
}

// Re-seat a hand-edited body onto the rack: named keys light up their field, the rest are
// held as unknown parameters rather than silently dropped.
function hydrate(shape, state, obj) {
  state.extra = {};
  for (const f of shape.fields) {
    const e = state.fields[f.name];
    const has = Object.prototype.hasOwnProperty.call(obj, f.name);
    e.on = has;
    e.isNull = has && obj[f.name] === null;
    if (!has || e.isNull) continue;
    if (f.shapes) {
      const sub = obj[f.name] || {};
      const guess = f.shapes.find(s => s.label === sub.typeName) || shapeOfState(f.shapes, e.sub);
      e.sub = subState(f, guess.label);
      hydrate(guess, e.sub, sub);
    } else {
      e.value = toStr(obj[f.name]);
    }
  }
  const named = new Set(shape.fields.map(f => f.name));
  for (const [k, v] of Object.entries(obj)) if (!named.has(k)) state.extra[k] = v;
}

function buildShape(shape, state) {
  const out = {};
  for (const f of shape.fields) {
    const e = state.fields[f.name];
    if (!e || !e.on) continue;
    if (e.isNull) { out[f.name] = null; continue; }
    if (f.shapes) { const s = shapeOfState(f.shapes, e.sub); out[f.name] = buildShape(s, e.sub); continue; }
    out[f.name] = coerce(f, e.value);
  }
  for (const c of (state.custom || [])) if (c.key) out[c.key] = coerce({ type: 'auto' }, c.value);
  for (const [k, v] of Object.entries(state.extra || {})) out[k] = v;
  return out;
}

function coerce(f, raw) {
  const v = subst(raw);
  if (f.type === 'boolean') return v === 'true';
  if (f.type === 'number' || f.type === 'integer') return Number(v);
  if (f.type === 'object' || f.type === 'array') { try { return JSON.parse(v); } catch { return v; } }
  if (f.type === 'auto') {
    if (v === 'true' || v === 'false') return v === 'true';
    if (v !== '' && !isNaN(Number(v))) return Number(v);
    return v;
  }
  return v;
}

// {{name}} → the captured value. Unknown names are left alone so a missing capture is visible.
function subst(s) {
  return typeof s === 'string'
    ? s.replace(/\\{\\{\\s*([A-Za-z0-9_]+)\\s*\\}\\}/g, (m, k) => (store[k] != null ? store[k] : m))
    : s;
}

/* ---------- send ---------- */

async function sendRequest() {
  let path = current.path;
  for (const [k, v] of Object.entries(st.path)) path = path.replace('{' + k + '}', encodeURIComponent(subst(v || '')));

  const query = {};
  for (const f of current.queryParams) {
    const e = st.query.fields[f.name];
    if (e?.on && !e.isNull) query[f.name] = subst(e.value);
  }

  let body;
  if (current.body) {
    if (st.tab === 'json') {
      try { JSON.parse(st.raw || '{}'); }
      catch (err) { return fail('INVALID JSON', err.message); }
      body = subst(st.raw);
    } else {
      body = JSON.stringify(buildShape(shapeOfState(current.body.shapes, st.body), st.body));
    }
  }

  const resp = document.getElementById('resp');
  resp.innerHTML = '<p class="sending">sending…</p>';
  let r;
  try {
    r = await fetch('/proxy', {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ method: current.method, path, query, base: document.getElementById('base').value, body }),
    }).then(x => x.json());
  } catch (err) {
    return fail('PROXY UNREACHABLE', err.message + ' — is the bench still running?');
  }
  const ok = r.status >= 200 && r.status < 300;
  resp.innerHTML = '';
  resp.appendChild(el('<div class="bar" style="margin-top:14px"><span class="status ' + (ok ? 'ok' : 'bad') + '">' + (r.status || 'ERR') + ' ' + esc(r.statusText || '') + '</span><span class="empty">click a highlighted id to capture it</span></div>'));
  resp.appendChild(renderResp(r.body ?? r.error));
  capture(r.body);
}

function fail(label, msg) {
  const resp = document.getElementById('resp');
  resp.innerHTML = '';
  resp.appendChild(el('<div class="bar" style="margin-top:14px"><span class="status bad">' + esc(label) + '</span><span class="empty">' + esc(msg) + '</span></div>'));
}

/* ---------- captured ids ---------- */

function capture(body) { walk(body, '', childResourceParam(current?.path)); renderStore(); }

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
  return '<span class="cap2" data-cn="' + esc(name) + '" data-cv="' + esc(val) + '">' + inner + '</span>';
}
function renderJson(v, key, indent) {
  const pad = '  '.repeat(indent);
  if (Array.isArray(v)) {
    if (!v.length) return '[]';
    return '[\\n' + v.map(x => '  '.repeat(indent + 1) + renderJson(x, key, indent + 1)).join(',\\n') + '\\n' + pad + ']';
  }
  if (v && typeof v === 'object') {
    const keys = Object.keys(v);
    if (!keys.length) return '{}';
    const param = key.endsWith('s') && isIdMap(v) ? key.slice(0, -1) + 'Id' : null;
    const keyIsId = param && paramExists(param);
    const rows = keys.map(k => {
      const label = keyIsId ? capSpan(param, k, '"' + esc(k) + '"') : '"' + esc(k) + '"';
      return '  '.repeat(indent + 1) + label + ': ' + renderJson(v[k], k, indent + 1);
    }).join(',\\n');
    return '{\\n' + rows + '\\n' + pad + '}';
  }
  if (typeof v === 'string') {
    const inner = '"' + esc(v) + '"';
    return isIdish(key, v) ? capSpan(key || 'value', v, inner) : inner;
  }
  if (typeof v === 'number') return isIdish(key, v) ? capSpan(key || 'value', String(v), String(v)) : String(v);
  return esc(String(v));
}
function renderResp(body) {
  const pre = el('<pre class="json"></pre>');
  pre.innerHTML = renderJson(body, '', 0);
  rewireCaptures(pre);
  return pre;
}
function rewireCaptures(root) {
  root.querySelectorAll('.cap2').forEach(s => { s.onclick = () => captureValue(s.dataset.cn, s.dataset.cv); });
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
function paramExists(p) {
  return ENDPOINTS.some(e => e.pathParams.some(pp => idMatch(pp.name, p)) || e.queryParams.some(q => idMatch(q.name, p)));
}
function isIdMap(o) {
  const ks = Object.keys(o);
  return ks.length > 0 && ks.every(k => k.length <= 40) && Object.values(o).every(x => x && (typeof x === 'object' || typeof x === 'boolean'));
}
function walk(v, key, childParam) {
  if (Array.isArray(v)) { v.forEach(x => walk(x, key, childParam)); return; }
  if (v && typeof v === 'object') {
    if (key.endsWith('s') && isIdMap(v)) {
      const param = key.slice(0, -1) + 'Id';
      if (paramExists(param)) for (const mk of Object.keys(v)) store[param] = String(mk);
    }
    for (const [k, val] of Object.entries(v)) walk(val, k, childParam);
    return;
  }
  if (/(^id$|Id$)/.test(key) && (typeof v === 'string' || typeof v === 'number')) {
    store[key] = String(v);
    if (key === 'id' && childParam) store[childParam] = String(v);
  }
}

function renderStore() {
  const vars = document.getElementById('vars');
  const keys = Object.keys(store);
  if (!keys.length) {
    vars.innerHTML = '<p class="empty">Ids from every response are captured here. Reference one anywhere as <code class="b">{{name}}</code> and it fills in when you send.</p>';
    return;
  }
  vars.innerHTML = '';
  for (const k of keys) {
    const row = el('<div class="var"><b>' + esc(k) + '</b><span class="val">' + esc(store[k]) + '</span></div>');
    row.onclick = () => selectVar(k);
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
  const k = Object.keys(store).find(k => idMatch(param, k));
  return k ? store[k] : '';
}

function selectVar(k) {
  selectedVar = k;
  if (st) {
    for (const p of current.pathParams) if (idMatch(p.name, k)) st.path[p.name] = store[k];
    render();
  }
  const rel = document.getElementById('related');
  const matches = ENDPOINTS.filter(e => e.pathParams.some(p => idMatch(p.name, k)) || e.queryParams.some(q => idMatch(q.name, k)));
  if (!matches.length) { rel.innerHTML = '<p class="empty">No endpoint takes ' + esc(k) + '.</p>'; return; }
  rel.innerHTML = '<p class="empty">Endpoints taking <code class="b">' + esc(k) + '</code></p>';
  for (const e of matches) {
    const a = el('<a><span class="m ' + e.method + '">' + e.method + '</span> ' + esc(e.path) + '</a>');
    a.onclick = () => selectEndpoint(e);
    rel.appendChild(a);
  }
}

renderList();
renderStore();
document.getElementById('filter').oninput = (ev) => renderList(ev.target.value);
</script>
</body>
</html>`;
