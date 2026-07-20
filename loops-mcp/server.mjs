#!/usr/bin/env node
// MCP stdio server for the Loops REST API, driven entirely by the bundled
// OpenAPI spec (openapi.json next to this file, or LOOPS_OPENAPI_SPEC).
// Env: LOOPS_API_KEY (bearer), LOOPS_API_BASE (default https://app.loops.so/api).

import { readFileSync } from "node:fs";
import { createInterface } from "node:readline";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

const here = dirname(fileURLToPath(import.meta.url));
const specPath = process.env.LOOPS_OPENAPI_SPEC ?? join(here, "openapi.json");
const spec = JSON.parse(readFileSync(specPath, "utf8"));
const baseUrl = (process.env.LOOPS_API_BASE ?? "https://app.loops.so/api").replace(/\/+$/, "");
const apiKey = process.env.LOOPS_API_KEY ?? "";

const METHODS = ["get", "post", "put", "patch", "delete"];
const MAX_OUTPUT = 60_000;

function listOperations() {
  const ops = [];
  for (const [path, item] of Object.entries(spec.paths)) {
    for (const method of METHODS) {
      const op = item[method];
      if (!op) continue;
      ops.push({
        method: method.toUpperCase(),
        path,
        tag: op.tags?.[0] ?? "",
        summary: op.summary ?? "",
        deprecated: op.deprecated === true,
        op,
        pathItem: item,
      });
    }
  }
  return ops;
}

function resolveRefs(node, seen = new Set()) {
  if (Array.isArray(node)) return node.map((n) => resolveRefs(n, seen));
  if (node && typeof node === "object") {
    if (typeof node.$ref === "string") {
      if (seen.has(node.$ref)) return { $circular: node.$ref };
      const target = node.$ref
        .replace(/^#\//, "")
        .split("/")
        .reduce((acc, k) => (acc == null ? acc : acc[k]), spec);
      if (target == null) return { $unresolved: node.$ref };
      return resolveRefs(target, new Set([...seen, node.$ref]));
    }
    const out = {};
    for (const [k, v] of Object.entries(node)) {
      if (k === "x-mint") continue;
      out[k] = resolveRefs(v, seen);
    }
    return out;
  }
  return node;
}

function truncate(text) {
  if (text.length <= MAX_OUTPUT) return text;
  return text.slice(0, MAX_OUTPUT) + `\n… [truncated, ${text.length} chars total]`;
}

function findOperation(method, path) {
  const m = method.toLowerCase();
  const item = spec.paths[path];
  if (item?.[m]) return { op: item[m], pathItem: item, template: path };
  const want = path.split("/").filter(Boolean);
  for (const [tpl, it] of Object.entries(spec.paths)) {
    if (!it[m]) continue;
    const parts = tpl.split("/").filter(Boolean);
    if (parts.length !== want.length) continue;
    if (parts.every((p, i) => p.startsWith("{") || p === want[i])) {
      return { op: it[m], pathItem: it, template: tpl };
    }
  }
  return null;
}

const tools = [
  {
    name: "list_operations",
    description:
      "List Loops API operations (method, path, summary), optionally filtered by tag or free-text search. Start here to find the right endpoint, then use get_operation for its exact schema.",
    inputSchema: {
      type: "object",
      properties: {
        tag: { type: "string", description: "Filter to one tag, e.g. 'Contacts', 'Campaigns', 'Workflows'." },
        search: { type: "string", description: "Case-insensitive substring match on path and summary." },
      },
    },
  },
  {
    name: "get_operation",
    description:
      "Get the full definition of one Loops API operation: parameters, request-body schema, and response schemas, with all $refs resolved. Call this before request when you need exact field names or constraints.",
    inputSchema: {
      type: "object",
      properties: {
        method: { type: "string", description: "HTTP method, e.g. GET or POST." },
        path: { type: "string", description: "Spec path template, e.g. /v1/campaigns/{campaignId}." },
      },
      required: ["method", "path"],
    },
  },
  {
    name: "request",
    description:
      `Execute a Loops API call against ${baseUrl} using the configured API key. Provide the spec path template plus path_params, or a concrete path. Returns the HTTP status and JSON response.`,
    inputSchema: {
      type: "object",
      properties: {
        method: { type: "string", description: "HTTP method, e.g. GET, POST, PUT, DELETE." },
        path: { type: "string", description: "Path template (/v1/campaigns/{campaignId}) or concrete path (/v1/campaigns/abc123)." },
        path_params: {
          type: "object",
          description: "Values for {placeholders} in path.",
          additionalProperties: { type: "string" },
        },
        query: {
          type: "object",
          description: "Query-string parameters.",
          additionalProperties: { type: "string" },
        },
        body: { type: "object", description: "JSON request body." },
        headers: {
          type: "object",
          description: "Extra headers, e.g. {\"Idempotency-Key\": \"…\"}.",
          additionalProperties: { type: "string" },
        },
      },
      required: ["method", "path"],
    },
  },
];

function runListOperations({ tag, search } = {}) {
  let ops = listOperations();
  if (tag) ops = ops.filter((o) => o.tag.toLowerCase() === tag.toLowerCase());
  if (search) {
    const q = search.toLowerCase();
    ops = ops.filter((o) => (o.path + " " + o.summary).toLowerCase().includes(q));
  }
  const byTag = new Map();
  for (const o of ops) {
    if (!byTag.has(o.tag)) byTag.set(o.tag, []);
    byTag.get(o.tag).push(o);
  }
  const lines = [`Loops API ${spec.info.version} — base: ${baseUrl}`, ""];
  for (const [t, group] of byTag) {
    lines.push(`## ${t}`);
    for (const o of group) {
      lines.push(`${o.method} ${o.path} — ${o.summary}${o.deprecated ? " [DEPRECATED]" : ""}`);
    }
    lines.push("");
  }
  return lines.join("\n").trim();
}

function runGetOperation({ method, path }) {
  const found = findOperation(method, path);
  if (!found) throw new Error(`No operation ${method.toUpperCase()} ${path} in the spec. Use list_operations.`);
  const { op, pathItem, template } = found;
  const parameters = [...(pathItem.parameters ?? []), ...(op.parameters ?? [])];
  const responses = {};
  for (const [code, r] of Object.entries(op.responses ?? {})) {
    responses[code] = {
      description: r.description,
      schema: resolveRefs(r.content?.["application/json"]?.schema ?? null),
    };
  }
  return JSON.stringify(
    {
      method: method.toUpperCase(),
      path: template,
      summary: op.summary,
      description: op.description,
      deprecated: op.deprecated === true,
      parameters: resolveRefs(parameters),
      requestBody: {
        required: op.requestBody?.required ?? false,
        description: op.requestBody?.description,
        schema: resolveRefs(op.requestBody?.content?.["application/json"]?.schema ?? null),
      },
      responses,
    },
    null,
    2,
  );
}

async function runRequest({ method, path, path_params = {}, query = {}, body, headers = {} }) {
  let resolved = path.replace(/\{([^}]+)\}/g, (_, name) => {
    if (path_params[name] == null) throw new Error(`Missing path_params.${name} for ${path}`);
    return encodeURIComponent(path_params[name]);
  });
  const notes = [];
  if (!findOperation(method, resolved)) {
    notes.push(`note: ${method.toUpperCase()} ${path} is not in the bundled spec (${spec.info.version}); sending anyway.`);
  }
  const url = new URL(baseUrl + resolved);
  for (const [k, v] of Object.entries(query)) url.searchParams.set(k, String(v));
  const init = {
    method: method.toUpperCase(),
    headers: { Authorization: `Bearer ${apiKey}`, ...headers },
  };
  if (body !== undefined) {
    init.headers["Content-Type"] = "application/json";
    init.body = JSON.stringify(body);
  }
  const res = await fetch(url, init);
  const text = await res.text();
  let rendered = text;
  try {
    rendered = JSON.stringify(JSON.parse(text), null, 2);
  } catch {}
  return [...notes, `HTTP ${res.status} ${init.method} ${url}`, rendered].join("\n");
}

async function handleToolCall(name, args) {
  if (name === "list_operations") return runListOperations(args);
  if (name === "get_operation") return runGetOperation(args);
  if (name === "request") return runRequest(args);
  throw new Error(`Unknown tool: ${name}`);
}

function send(msg) {
  process.stdout.write(JSON.stringify(msg) + "\n");
}

const rl = createInterface({ input: process.stdin });
rl.on("line", async (line) => {
  line = line.trim();
  if (!line) return;
  let req;
  try {
    req = JSON.parse(line);
  } catch {
    return;
  }
  const { id, method, params } = req;
  if (id === undefined) return; // notification
  try {
    if (method === "initialize") {
      send({
        jsonrpc: "2.0",
        id,
        result: {
          protocolVersion: params?.protocolVersion ?? "2024-11-05",
          capabilities: { tools: {} },
          serverInfo: { name: "loops", version: spec.info.version },
        },
      });
    } else if (method === "tools/list") {
      send({ jsonrpc: "2.0", id, result: { tools } });
    } else if (method === "tools/call") {
      try {
        const text = await handleToolCall(params.name, params.arguments ?? {});
        send({ jsonrpc: "2.0", id, result: { content: [{ type: "text", text: truncate(text) }] } });
      } catch (err) {
        send({
          jsonrpc: "2.0",
          id,
          result: { content: [{ type: "text", text: String(err?.message ?? err) }], isError: true },
        });
      }
    } else if (method === "ping") {
      send({ jsonrpc: "2.0", id, result: {} });
    } else {
      send({ jsonrpc: "2.0", id, error: { code: -32601, message: `Method not found: ${method}` } });
    }
  } catch (err) {
    send({ jsonrpc: "2.0", id, error: { code: -32603, message: String(err?.message ?? err) } });
  }
});
