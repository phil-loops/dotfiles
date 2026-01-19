import type { Command } from "../types.ts";
import { currentBranch, loadStack } from "../lib.ts";

export const command: Command = {
  category: "nav",
  name: "parent",
  help: "Print parent branch name",
  run() {
    const branch = currentBranch();

    if (!branch) {
      console.error("Not on a branch");
      process.exit(1);
    }

    const stack = loadStack();
    const parent = stack[branch];

    if (!parent) {
      console.error(`Branch "${branch}" not tracked`);
      process.exit(1);
    }

    console.log(parent);
  },
};
