const fs = require("fs");
const path = require("path");
const dotenv = require("dotenv");

let _loopsEnv = null;

function getLoopsDir() {
  if (process.env.LOOPS_DIR) return process.env.LOOPS_DIR;
  throw new Error("LOOPS_DIR environment variable is required");
}

function loadLoopsEnv() {
  if (_loopsEnv) return _loopsEnv;
  const loopsDir = getLoopsDir();
  const envPath = path.join(loopsDir, ".env");
  if (!fs.existsSync(envPath)) {
    throw new Error(`Missing .env at ${envPath}`);
  }
  _loopsEnv = dotenv.parse(fs.readFileSync(envPath, "utf8"));
  return _loopsEnv;
}

function getDatabaseUrl() {
  const env = loadLoopsEnv();
  return env.DATABASE_URL;
}

function getNextAuthSecret() {
  const env = loadLoopsEnv();
  return env.NEXTAUTH_SECRET;
}

function getBaseUrl() {
  return process.env.LOOPS_BASE_URL || "http://localhost:3000";
}

module.exports = { getLoopsDir, loadLoopsEnv, getDatabaseUrl, getNextAuthSecret, getBaseUrl };
