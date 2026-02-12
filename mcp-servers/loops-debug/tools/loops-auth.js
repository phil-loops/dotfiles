const { z } = require("zod");
const { getDevAuth, getCookieAuth } = require("../lib/auth");

const schema = {
  name: "loops_auth",
  description:
    'Generate auth credentials for the Loops dev server. "dev" mode returns the email as an Authorization header (works for tRPC endpoints). "cookie" mode generates a real NextAuth session cookie (works for pages/api/ routes).',
  inputSchema: {
    email: z.string().describe("User email to authenticate as"),
    mode: z
      .enum(["dev", "cookie"])
      .default("dev")
      .describe('Auth mode: "dev" for tRPC header auth, "cookie" for NextAuth session'),
  },
};

async function execute({ email, mode }) {
  let headers;
  if (mode === "cookie") {
    headers = await getCookieAuth(email);
  } else {
    headers = getDevAuth(email);
  }

  return {
    content: [
      {
        type: "text",
        text: JSON.stringify({ mode, email, headers }, null, 2),
      },
    ],
  };
}

module.exports = { schema, execute };
