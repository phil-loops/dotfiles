import { readdirSync } from "fs";
import { dirname, join } from "path";
import { fileURLToPath } from "url";
import { CATEGORIES, type Category, type Command } from "./types.ts";

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
  console.log(`\nstack - Branch Stack Tool\n`);

  // Group commands by category
  const byCategory = new Map<Category, Command[]>();
  for (const cmd of commands.values()) {
    const list = byCategory.get(cmd.category) || [];
    list.push(cmd);
    byCategory.set(cmd.category, list);
  }

  // Find max width for alignment
  const allCmds = [...commands.values()];
  const maxWidth = Math.max(...allCmds.map((c) => c.name.length + (c.args?.length || 0) + 1));
  const padWidth = Math.max(maxWidth + 4, 20);

  // Display in category order
  const categoryOrder: Category[] = ["nav", "stack", "git", "util"];
  for (const cat of categoryOrder) {
    const cmds = byCategory.get(cat);
    if (!cmds || cmds.length === 0) continue;

    console.log(`${CATEGORIES[cat]}:`);
    cmds.sort((a, b) => a.name.localeCompare(b.name));
    for (const cmd of cmds) {
      const args = cmd.args ? ` ${cmd.args}` : "";
      const name = `  ${cmd.name}${args}`.padEnd(padWidth);
      console.log(`${name}${cmd.help}`);
    }
    console.log();
  }

  console.log(`Examples:
  stack init goals-          # init from branch prefix
  stack list                 # show branch tree
  stack update --all         # rebase entire stack
  stack pr                   # push and create PR`);
}
