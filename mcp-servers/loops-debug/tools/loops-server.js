const { z } = require("zod");
const { spawn, execSync } = require("child_process");
const net = require("net");
const path = require("path");
const { getLoopsDir, getBaseUrl } = require("../lib/config");

const schema = {
  name: "loops_server",
  description:
    "Manage the Loops dev server lifecycle. Check status, start/stop the Next.js dev server, view logs, run database migrations and seeds.",
  inputSchema: {
    op: z
      .enum(["status", "start", "stop", "logs", "seed", "migrate"])
      .describe("Operation to perform"),
  },
};

// Ring buffer for dev server logs
const LOG_BUFFER_SIZE = 500;
let logBuffer = [];
let serverProcess = null;

function addLog(line) {
  logBuffer.push({ time: new Date().toISOString(), line });
  if (logBuffer.length > LOG_BUFFER_SIZE) {
    logBuffer = logBuffer.slice(-LOG_BUFFER_SIZE);
  }
}

async function checkPort(port) {
  return new Promise((resolve) => {
    const socket = new net.Socket();
    socket.setTimeout(1000);
    socket.on("connect", () => {
      socket.destroy();
      resolve(true);
    });
    socket.on("timeout", () => {
      socket.destroy();
      resolve(false);
    });
    socket.on("error", () => {
      resolve(false);
    });
    socket.connect(port, "127.0.0.1");
  });
}

function getPort() {
  const url = new URL(getBaseUrl());
  return parseInt(url.port || "3000", 10);
}

async function execute({ op }) {
  switch (op) {
    case "status":
      return await status();
    case "start":
      return await start();
    case "stop":
      return await stopServer();
    case "logs":
      return logs();
    case "seed":
      return await runPrismaCommand("db seed");
    case "migrate":
      return await runPrismaCommand("migrate deploy");
    default:
      return { content: [{ type: "text", text: `Unknown op: ${op}` }], isError: true };
  }
}

async function status() {
  const port = getPort();
  const running = await checkPort(port);
  const managedByUs = serverProcess !== null && !serverProcess.killed;

  return {
    content: [
      {
        type: "text",
        text: JSON.stringify(
          {
            port,
            running,
            managedByUs,
            pid: managedByUs ? serverProcess.pid : null,
            logLines: logBuffer.length,
          },
          null,
          2
        ),
      },
    ],
  };
}

async function start() {
  const port = getPort();
  const running = await checkPort(port);
  if (running) {
    return {
      content: [{ type: "text", text: `Dev server already running on port ${port}` }],
    };
  }

  const loopsDir = getLoopsDir();
  logBuffer = [];

  serverProcess = spawn("node_modules/.bin/next", ["dev", "--webpack", "-p", String(port)], {
    cwd: loopsDir,
    stdio: ["ignore", "pipe", "pipe"],
    env: { ...process.env, NODE_ENV: "development" },
    detached: true,
  });

  serverProcess.stdout.on("data", (data) => {
    data
      .toString()
      .split("\n")
      .filter(Boolean)
      .forEach((line) => addLog(`[stdout] ${line}`));
  });

  serverProcess.stderr.on("data", (data) => {
    data
      .toString()
      .split("\n")
      .filter(Boolean)
      .forEach((line) => addLog(`[stderr] ${line}`));
  });

  serverProcess.on("exit", (code) => {
    addLog(`[process] exited with code ${code}`);
    serverProcess = null;
  });

  // Wait briefly for startup
  await new Promise((resolve) => setTimeout(resolve, 3000));
  const nowRunning = await checkPort(port);

  return {
    content: [
      {
        type: "text",
        text: JSON.stringify(
          {
            started: true,
            pid: serverProcess?.pid,
            port,
            running: nowRunning,
            note: nowRunning
              ? "Server is accepting connections"
              : "Server started but not yet accepting connections (may still be compiling)",
          },
          null,
          2
        ),
      },
    ],
  };
}

async function stopServer() {
  if (!serverProcess || serverProcess.killed) {
    return { content: [{ type: "text", text: "No managed server process to stop" }] };
  }

  const pid = serverProcess.pid;
  try {
    process.kill(-pid, "SIGTERM");
  } catch {
    serverProcess.kill("SIGTERM");
  }

  await new Promise((resolve) => setTimeout(resolve, 1000));

  if (serverProcess && !serverProcess.killed) {
    try {
      process.kill(-pid, "SIGKILL");
    } catch {
      serverProcess.kill("SIGKILL");
    }
  }

  serverProcess = null;
  return { content: [{ type: "text", text: `Stopped server (pid ${pid})` }] };
}

function logs() {
  const recent = logBuffer.slice(-100);
  return {
    content: [
      {
        type: "text",
        text:
          recent.length === 0
            ? "No logs captured"
            : recent.map((l) => `${l.time} ${l.line}`).join("\n"),
      },
    ],
  };
}

async function runPrismaCommand(subcommand) {
  const loopsDir = getLoopsDir();
  try {
    const output = execSync(`npx prisma ${subcommand}`, {
      cwd: loopsDir,
      encoding: "utf8",
      timeout: 60000,
      env: { ...process.env, NODE_ENV: "development" },
    });
    return { content: [{ type: "text", text: output }] };
  } catch (err) {
    return {
      content: [{ type: "text", text: `Error: ${err.message}\n\n${err.stderr || ""}` }],
      isError: true,
    };
  }
}

module.exports = { schema, execute };
