import type { Command } from "../types.ts";
import { getChildren, git, loadStack, saveStack } from "../lib.ts";
import { parseArgs } from "../args.ts";

export const command: Command = {
  category: "stack",
  name: "adopt",
  help: "Add existing branch to stack, optionally reparent children",
  args: "<branch> --after <parent> [--reparent]",
  run(args) {
    const { values, positionals } = parseArgs(args, {
      after: { type: "string", short: "a" },
      reparent: { type: "boolean", short: "r" },
    });

    const branch = positionals[0];
    const afterBranch = values.after;

    if (!branch || !afterBranch) {
      console.error("Usage: stack adopt <branch> --after <parent> [--reparent]");
      process.exit(1);
    }

    const stack = loadStack();

    // Verify the branch exists
    try {
      git(`rev-parse --verify ${branch}`);
    } catch {
      console.error(`Branch "${branch}" does not exist`);
      process.exit(1);
    }

    // Verify the "after" branch exists
    try {
      git(`rev-parse --verify ${afterBranch}`);
    } catch {
      console.error(`Branch "${afterBranch}" does not exist`);
      process.exit(1);
    }

    // Check if branch is already tracked
    if (stack[branch]) {
      console.error(`Branch "${branch}" is already tracked (parent: ${stack[branch]})`);
      console.error(`Use 'stack remove ${branch}' first, or edit the stack file directly`);
      process.exit(1);
    }

    // Add branch to stack with "after" as its parent
    stack[branch] = afterBranch;
    console.log(`Added ${branch} -> ${afterBranch}`);

    // Optionally reparent children of "after" to point to the new branch
    if (values.reparent) {
      const children = getChildren(stack, afterBranch);
      // Don't reparent the branch we just added
      const toReparent = children.filter((c) => c !== branch);

      for (const child of toReparent) {
        console.log(`Reparenting ${child}: ${afterBranch} -> ${branch}`);
        stack[child] = branch;
      }

      if (toReparent.length > 0) {
        console.log(`\nRun 'stack update' to rebase the chain`);
      }
    }

    saveStack(stack);

    console.log(`\nDone! Stack updated.`);
  },
};
