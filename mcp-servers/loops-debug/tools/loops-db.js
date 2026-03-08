const { z } = require("zod");
const { query } = require("../lib/db");

const schema = {
  name: "loops_db",
  description:
    "Execute SQL queries against the local Loops Postgres database. Use parameterized queries ($1, $2, ...) for safety. Note: The API key used for Bearer auth is the ApiKey.id column (not Team.id). Look up with: SELECT id FROM \"ApiKey\" WHERE \"teamId\" = $1",
  inputSchema: {
    query: z.string().describe("SQL query to execute"),
    params: z
      .array(z.union([z.string(), z.number(), z.boolean(), z.null()]))
      .optional()
      .describe("Query parameters for $1, $2, ... placeholders"),
  },
};

async function execute({ query: sql, params }) {
  const result = await query(sql, params || []);
  return {
    content: [
      {
        type: "text",
        text: JSON.stringify(
          { rows: result.rows, rowCount: result.rowCount, command: result.command },
          null,
          2
        ),
      },
    ],
  };
}

module.exports = { schema, execute };
