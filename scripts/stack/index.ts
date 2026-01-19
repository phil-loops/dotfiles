#!/usr/bin/env -S node --no-warnings --experimental-strip-types

import { commands, showHelp } from "./registry.ts";

const [cmd, ...args] = process.argv.slice(2);

if (!cmd || cmd === "--help" || cmd === "-h") {
  showHelp();
  process.exit(0);
}

const command = commands.get(cmd);

if (!command) {
  console.error(`Unknown command: ${cmd}`);
  console.error("Run 'stack' for help");
  process.exit(1);
}

command.run(args);
