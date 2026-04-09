const { McpServer } = require("@modelcontextprotocol/sdk/server/mcp.js");
const { StdioServerTransport } = require("@modelcontextprotocol/sdk/server/stdio.js");
const { z } = require("zod");

// Load all tools
const tools = [
  require("./tools/loops-db"),
  require("./tools/loops-auth"),
  require("./tools/loops-api"),
  require("./tools/loops-contact"),
  require("./tools/loops-server"),
  require("./tools/loops-ses-event"),
];

const server = new McpServer({
  name: "loops-debug",
  version: "1.0.0",
});

// Register each tool
for (const tool of tools) {
  server.tool(tool.schema.name, tool.schema.description, tool.schema.inputSchema, async (params) => {
    try {
      return await tool.execute(params);
    } catch (err) {
      return {
        content: [{ type: "text", text: `Error: ${err.message}\n\n${err.stack}` }],
        isError: true,
      };
    }
  });
}

async function main() {
  const transport = new StdioServerTransport();
  await server.connect(transport);
}

main().catch((err) => {
  console.error("MCP server failed to start:", err);
  process.exit(1);
});
