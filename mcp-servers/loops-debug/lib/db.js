const { Client } = require("pg");
const { getDatabaseUrl } = require("./config");

async function query(sql, params = []) {
  const client = new Client({ connectionString: getDatabaseUrl() });
  await client.connect();
  try {
    const result = await client.query(sql, params);
    return { rows: result.rows, rowCount: result.rowCount, command: result.command };
  } finally {
    await client.end();
  }
}

module.exports = { query };
