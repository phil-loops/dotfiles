#!/usr/bin/env node
import { webview } from "./commands/webview/index.ts";
import { inject } from "./commands/inject.ts";
import { branches } from "./commands/branches.ts";
import { update } from "./commands/update.ts";
import { push } from "./commands/push.ts";
import { flow } from "./commands/flow.ts";
import { sync } from "./commands/sync.ts";

const args = process.argv.slice(2);
const command = args[0];

const commands: Record<string, { run: (args: string[]) => void | Promise<void>; desc: string }> = {
  branches: {
    run: branches,
    desc: "List stack branches in order (--json, --names)",
  },
  update: {
    run: update,
    desc: "Rebase downstream branches (--from=<branch>, --dry-run)",
  },
  push: {
    run: push,
    desc: "Push all stack branches (--force, --remote=<remote>)",
  },
  webview: {
    run: webview,
    desc: "Open interactive stack viewer in browser",
  },
  inject: {
    run: inject,
    desc: "AI-powered patch routing (--save, --no-claude)",
  },
  flow: {
    run: flow,
    desc: "Sync + push (--dry-run)",
  },
  sync: {
    run: sync,
    desc: "Rebase stack onto trunk, prune merged, push (--continue, --abort, --dry-run, --no-auto-resolve, --no-prune, --all, --remote=)",
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

Promise.resolve(cmd.run(args.slice(1))).catch((err) => {
  console.error(err);
  process.exit(1);
});
