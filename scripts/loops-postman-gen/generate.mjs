#!/usr/bin/env node
import { spawn } from "node:child_process";
import { writeFileSync } from "node:fs";
import { readFile } from "node:fs/promises";
import { resolve } from "node:path";
import Converter from "openapi-to-postmanv2";

const DEFAULT_SPEC = "https://app.loops.so/openapi.json";

const parseArgs = (argv) => {
  const args = { spec: DEFAULT_SPEC, out: ".", name: "Loops API" };
  for (let i = 0; i < argv.length; i++) {
    const arg = argv[i];
    if (arg === "--spec" || arg === "-s") {
      args.spec = argv[++i];
    } else if (arg === "--out" || arg === "-o") {
      args.out = argv[++i];
    } else if (arg === "--name" || arg === "-n") {
      args.name = argv[++i];
    } else if (arg === "--html") {
      args.html = true;
    } else if (arg === "--open") {
      args.html = true;
      args.open = true;
    } else if (arg === "--help" || arg === "-h") {
      args.help = true;
    }
  }
  return args;
};

const HELP = `loops-postman — generate a Postman collection from an OpenAPI spec

Usage:
  loops-postman [--spec <path-or-url>] [--out <dir>] [--name <name>] [--html|--open]
  loops-postman serve [--base <url>] [--token <key>] [--spec <path-or-url>] [--port <n>]

Generate options:
  -s, --spec   OpenAPI spec URL or local path   (default: ${DEFAULT_SPEC})
  -o, --out    Output directory                  (default: current directory)
  -n, --name   Collection name                   (default: Loops API)
      --html   Also write an interactive HTML API reference
      --open   Write the HTML reference and open it in the browser

serve — responsive console that calls the API live and chains captured ids:
  -b, --base   API base URL    (default: http://localhost:3000/api — dev)
  -t, --token  Bearer token    (default: the seeded dev key)
  -p, --port   Console port    (default: 7070)
      --no-open  Don't open the browser

Generate writes <out>/loops.postman_collection.json + loops.postman_environment.json.
Import both into Postman, then set the environment's apiKey.`;

const htmlFor = (name, rawSpec) => {
  const inlineSpec = rawSpec.replace(/<\/script>/gi, "<\\/script>");
  return `<!doctype html>
<html>
  <head>
    <meta charset="utf-8" />
    <meta name="viewport" content="width=device-width, initial-scale=1" />
    <title>${name}</title>
  </head>
  <body>
    <script id="api-reference" type="application/json">${inlineSpec}</script>
    <script>
      document.getElementById("api-reference").dataset.configuration = JSON.stringify({
        theme: "purple",
        hideDownloadButton: false,
      });
    </script>
    <script src="https://cdn.jsdelivr.net/npm/@scalar/api-reference"></script>
  </body>
</html>
`;
};

const loadSpec = async (src) => {
  if (/^https?:\/\//.test(src)) {
    const res = await fetch(src);
    if (!res.ok) {
      throw new Error(`Failed to fetch spec: ${res.status} ${res.statusText}`);
    }
    return res.text();
  }
  return readFile(resolve(src), "utf8");
};

const sampleFor = (key, current) => {
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
  if (/(url|href|link|website|domain)$/i.test(key)) {
    return "https://example.com";
  }
  if (/(phone|mobile|tel)/i.test(key)) {
    return "+15555550123";
  }
  if (/(at$|date|timestamp)/i.test(key)) {
    return "2024-01-01T00:00:00Z";
  }
  if (/colou?r$/i.test(key)) {
    return "#3b82f6";
  }
  if (/(subject|title)$/i.test(key)) {
    return "Example subject";
  }
  if (/^id$/i.test(key)) {
    return "id_123";
  }
  if (/Id$/.test(key)) {
    return `${key.replace(/Id$/, "").toLowerCase()}_123`;
  }
  if (typeof current === "boolean" && /(subscribed|optedin|enabled|active|verified)/i.test(key)) {
    return true;
  }
  if (current === "string" || current === "<string>") {
    return "example";
  }
  return current;
};

const fillSensible = (value, key) => {
  if (Array.isArray(value)) {
    return value.map((item) => fillSensible(item, key));
  }
  if (value && typeof value === "object") {
    return Object.fromEntries(
      Object.entries(value).map(([k, v]) => [k, fillSensible(v, k)]),
    );
  }
  return sampleFor(key, value);
};

const fillBody = (raw) => {
  let parsed;
  try {
    parsed = JSON.parse(raw);
  } catch {
    return raw;
  }
  return JSON.stringify(fillSensible(parsed, ""), null, 2);
};

const walkItems = (items, fn) => {
  for (const item of items) {
    if (item.request) {
      fn(item);
    }
    if (item.item) {
      walkItems(item.item, fn);
    }
  }
};

const convert = (spec) =>
  new Promise((resolveConv, reject) => {
    Converter.convert(
      { type: "string", data: spec },
      {
        folderStrategy: "Tags",
        requestParametersResolution: "Example",
        exampleParametersResolution: "Example",
        requestNameSource: "Fallback",
        shortValidationErrors: true,
      },
      (err, result) => {
        if (err) {
          return reject(err instanceof Error ? err : new Error(String(err)));
        }
        if (!result.result) {
          return reject(new Error(result.reason));
        }
        resolveConv(result.output[0].data);
      },
    );
  });

const runServe = async (argv) => {
  const { serve } = await import("./console.mjs");
  const opts = { open: true };
  for (let i = 0; i < argv.length; i++) {
    const arg = argv[i];
    if (arg === "--spec" || arg === "-s") {
      opts.spec = argv[++i];
    } else if (arg === "--base" || arg === "-b") {
      opts.base = argv[++i];
    } else if (arg === "--token" || arg === "-t") {
      opts.token = argv[++i];
    } else if (arg === "--port" || arg === "-p") {
      opts.port = Number(argv[++i]);
    } else if (arg === "--no-open") {
      opts.open = false;
    }
  }
  await serve(opts);
};

const main = async () => {
  if (process.argv[2] === "serve") {
    return runServe(process.argv.slice(3));
  }

  const args = parseArgs(process.argv.slice(2));
  if (args.help) {
    console.log(HELP);
    return;
  }

  const rawSpec = await loadSpec(args.spec);
  const spec = JSON.parse(rawSpec);
  const baseUrl = spec.servers?.[0]?.url ?? "https://app.loops.so/api";

  const collection = await convert(rawSpec);

  collection.info.name = args.name;
  collection.info.description = `Generated from ${args.spec} by loops-postman.`;
  collection.auth = {
    type: "bearer",
    bearer: [{ key: "token", value: "{{apiKey}}", type: "string" }],
  };
  collection.variable = [{ key: "baseUrl", value: baseUrl, type: "string" }];

  let requests = 0;
  walkItems(collection.item, (item) => {
    requests++;
    delete item.request.auth;
    if (item.request.body?.mode === "raw" && item.request.body.raw) {
      item.request.body.raw = fillBody(item.request.body.raw);
    }
    for (const q of item.request.url?.query ?? []) {
      q.value = sampleFor(q.key, q.value);
    }
    for (const v of item.request.url?.variable ?? []) {
      v.value = sampleFor(v.key, v.value);
    }
  });

  const environment = {
    id: "loops-api",
    name: args.name,
    values: [
      { key: "baseUrl", value: baseUrl, enabled: true, type: "default" },
      { key: "apiKey", value: "", enabled: true, type: "secret" },
    ],
    _postman_variable_scope: "environment",
  };

  const collectionPath = resolve(args.out, "loops.postman_collection.json");
  const environmentPath = resolve(args.out, "loops.postman_environment.json");
  writeFileSync(collectionPath, JSON.stringify(collection, null, 2) + "\n");
  writeFileSync(environmentPath, JSON.stringify(environment, null, 2) + "\n");

  console.log(
    `Wrote ${collectionPath}\n  ${collection.item.length} folders, ${requests} requests (spec v${spec.info?.version ?? "?"})`,
  );
  console.log(`Wrote ${environmentPath}`);

  if (args.html) {
    const htmlPath = resolve(args.out, "loops.api.html");
    writeFileSync(htmlPath, htmlFor(args.name, rawSpec));
    console.log(`Wrote ${htmlPath}`);
    if (args.open) {
      spawn("open", [htmlPath], { stdio: "ignore", detached: true }).unref();
    }
  }
};

main().catch((err) => {
  console.error(err.message ?? err);
  process.exit(1);
});
