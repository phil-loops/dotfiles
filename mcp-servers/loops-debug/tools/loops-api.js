const { z } = require("zod");
const { getBaseUrl } = require("../lib/config");
const { getDevAuth, getCookieAuth } = require("../lib/auth");

const schema = {
  name: "loops_api",
  description:
    "Make authenticated HTTP requests to the running Loops dev server. Uses dev-mode auth (Authorization header) by default, which works for tRPC endpoints. Use cookie mode for pages/api/ routes.",
  inputSchema: {
    method: z
      .enum(["GET", "POST", "PUT", "PATCH", "DELETE"])
      .default("GET")
      .describe("HTTP method"),
    path: z.string().describe('URL path (e.g. "/api/audience/123/update" or "/api/trpc/...")'),
    body: z.any().optional().describe("Request body (will be JSON-serialized)"),
    email: z
      .string()
      .optional()
      .describe("Email to authenticate as (required for authenticated endpoints)"),
    authMode: z
      .enum(["dev", "cookie", "none"])
      .default("dev")
      .describe('Auth mode: "dev" for tRPC, "cookie" for pages/api/, "none" for public'),
  },
};

async function execute({ method, path, body, email, authMode }) {
  const baseUrl = getBaseUrl();
  const url = `${baseUrl}${path.startsWith("/") ? path : "/" + path}`;

  const headers = { "Content-Type": "application/json" };

  if (authMode !== "none") {
    if (!email) {
      return {
        content: [{ type: "text", text: "Error: email is required for authenticated requests" }],
        isError: true,
      };
    }
    if (authMode === "cookie") {
      Object.assign(headers, await getCookieAuth(email));
    } else {
      Object.assign(headers, getDevAuth(email));
    }
  }

  const fetchOpts = { method, headers };
  if (body !== undefined && method !== "GET") {
    fetchOpts.body = JSON.stringify(body);
  }

  const response = await fetch(url, fetchOpts);

  let responseBody;
  const contentType = response.headers.get("content-type") || "";
  if (contentType.includes("application/json")) {
    responseBody = await response.json();
  } else {
    responseBody = await response.text();
  }

  return {
    content: [
      {
        type: "text",
        text: JSON.stringify(
          {
            status: response.status,
            statusText: response.statusText,
            headers: Object.fromEntries(response.headers.entries()),
            body: responseBody,
          },
          null,
          2
        ),
      },
    ],
  };
}

module.exports = { schema, execute };
