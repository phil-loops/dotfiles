import type { Command } from "../types.ts";
import { currentBranch, getConventionParent, loadConvention, loadStack } from "../lib.ts";

export const command: Command = {
  name: "parent",
  help: "Print parent branch name",
  run() {
    const branch = currentBranch();

    if (!branch) {
      console.error("Not on a branch");
      process.exit(1);
    }

    // Convention mode
    const convention = loadConvention();
    if (convention) {
      const p = getConventionParent(branch, convention);
      if (p) {
        console.log(p);
      } else {
        console.error(`Branch "${branch}" doesn't match prefix ${convention.prefix}`);
        process.exit(1);
      }
      return;
    }

    // Explicit mode
    const stack = loadStack();
    const p = stack[branch];
    if (!p) {
      console.error(`Branch "${branch}" not tracked`);
      process.exit(1);
    }

    console.log(p);
  },
};
