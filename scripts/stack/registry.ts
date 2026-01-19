import { readdirSync } from "fs";
import { dirname, join } from "path";
import { fileURLToPath } from "url";
import type { Command } from "./types.ts";

const __dirname = dirname(fileURLToPath(import.meta.url));
const commandsDir = join(__dirname, "commands");

export const commands = new Map<string, Command>();

// Auto-discover and load all command files
const files = readdirSync(commandsDir).filter((f) => f.endsWith(".ts"));

for (const file of files) {
  const module = await import(join(commandsDir, file));

  // Support single command export
  if (module.command) {
    const cmd = module.command as Command;
    commands.set(cmd.name, cmd);
  }

  // Support multiple commands from one file (e.g., edit.ts exports edit, return, edit --abort)
  if (module.commands) {
    for (const cmd of module.commands as Command[]) {
      commands.set(cmd.name, cmd);
    }
  }
}

export function showHelp() {
  console.log(`
stack - Branch Stack Tool

Commands:`);

  // Group and display commands
  const sorted = [...commands.values()].sort((a, b) => a.name.localeCompare(b.name));

  // Find max width for alignment
  const maxWidth = Math.max(...sorted.map((c) => c.name.length + (c.args?.length || 0) + 1));
  const padWidth = Math.max(maxWidth + 4, 20);

  for (const cmd of sorted) {
    const args = cmd.args ? ` ${cmd.args}` : "";
    const name = `  ${cmd.name}${args}`.padEnd(padWidth);
    console.log(`${name}${cmd.help}`);
  }

  console.log(`
Examples:
  # Init from existing branches:
  stack init goals-          # finds goals-1, goals-2, etc.
  stack list                 # shows: main -> goals-1 -> goals-2
  stack update               # rebase in order

  # Or add branches manually:
  stack add main             # track current branch with parent
  stack list
  stack update
`);
}
