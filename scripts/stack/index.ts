#!/usr/bin/env node
import { execSync } from "child_process";
import { webview } from "./commands/webview.ts";

const args = process.argv.slice(2);
const command = args[0];

const commands: Record<string, { run: (args: string[]) => void; desc: string }> = {
  webview: {
    run: webview,
    desc: "Open interactive stack viewer in browser (usage: webview [prefix])",
  },
};

function showHelp() {
  console.log("stack - Branch Stack Viewer\n");
  console.log("Commands:");
  for (const [name, { desc }] of Object.entries(commands)) {
    console.log(`  ${name.padEnd(20)} ${desc}`);
  }
}

if (!command || command === "help" || command === "--help") {
  showHelp();
  process.exit(0);
}

const cmd = commands[command];
if (!cmd) {
  console.error(`Unknown command: ${command}`);
  showHelp();
  process.exit(1);
}

cmd.run(args.slice(1));
