import type { Command } from "../types.ts";
import { parseArgs } from "../args.ts";
import {
  currentBranch,
  getChildren,
  getDescendants,
  loadStack,
  saveStack,
} from "../lib.ts";

export const command: Command = {
  category: "stack",
  name: "remove",
  help: "Untrack a branch (default: current)",
  args: "[branch] [-r|--recursive]",
  run(args: string[]) {
    const { values, positionals } = parseArgs(args, {
      recursive: { type: "boolean", short: "r" },
    });

    const branch = positionals[0] || currentBranch();
    if (!branch) {
      console.error("Not on a branch");
      process.exit(1);
    }

    const stack = loadStack();
    if (!stack[branch]) {
      console.error(`Branch "${branch}" is not tracked`);
      process.exit(1);
    }

    const children = getChildren(stack, branch);
    if (children.length > 0 && !values.recursive) {
      console.error(`Cannot remove: ${branch} has a child: ${children[0]}`);
      console.error("Use --recursive to remove branch and all descendants in the chain");
      process.exit(1);
    }

    if (values.recursive) {
      const descendants = getDescendants(stack, branch);
      for (const desc of descendants) {
        delete stack[desc];
      }
      delete stack[branch];
      saveStack(stack);
      console.log(`Removed: ${branch} and ${descendants.length} descendants`);
    } else {
      delete stack[branch];
      saveStack(stack);
      console.log(`Removed: ${branch}`);
    }
  },
};
