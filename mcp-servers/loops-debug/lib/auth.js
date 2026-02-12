const { randomBytes, createHash } = require("crypto");
const { Client } = require("pg");
const cuid = require("cuid");
const { getBaseUrl, getDatabaseUrl, getNextAuthSecret } = require("./config");

function getDevAuth(email) {
  return { Authorization: email };
}

function hashToken(token, secret) {
  return createHash("sha256").update(`${token}${secret}`).digest("hex");
}

async function getSigninUrl({ email }) {
  const databaseUrl = getDatabaseUrl();
  const nextAuthSecret = getNextAuthSecret();
  const baseUrl = getBaseUrl();

  if (!databaseUrl) throw new Error("DATABASE_URL is required");
  if (!nextAuthSecret) throw new Error("NEXTAUTH_SECRET is required");

  const client = new Client({ connectionString: databaseUrl });
  await client.connect();

  try {
    const userResult = await client.query(
      'SELECT email FROM "User" WHERE email = $1 LIMIT 1',
      [email]
    );
    if (userResult.rowCount === 0) {
      throw new Error(`User not found: ${email}`);
    }

    const token = randomBytes(32).toString("hex");
    const hashedToken = hashToken(token, nextAuthSecret);
    const expires = new Date(Date.now() + 120 * 1000).toISOString();
    const id = cuid();

    await client.query(
      'INSERT INTO "VerificationToken" ("id", "identifier", "token", "expires") VALUES ($1, $2, $3, $4)',
      [id, email, hashedToken, expires]
    );

    return `${baseUrl}/api/auth/callback/email?${new URLSearchParams({
      callbackUrl: baseUrl,
      token,
      email,
    }).toString()}`;
  } finally {
    await client.end();
  }
}

async function getCookieAuth(email) {
  const signinUrl = await getSigninUrl({ email });

  const response = await fetch(signinUrl, { redirect: "manual" });
  const setCookie = response.headers.get("set-cookie") || "";

  const match = setCookie.match(/next-auth\.session-token=([^;]+)/);
  if (!match) {
    throw new Error(
      `Failed to extract session token. Status: ${response.status}, Set-Cookie: ${setCookie}`
    );
  }

  return { Cookie: `next-auth.session-token=${match[1]}` };
}

module.exports = { getDevAuth, getCookieAuth };
