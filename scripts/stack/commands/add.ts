import type { Command } from "../types.ts";
import { currentBranch, getChildren, gitTry, loadStack, saveStack, wouldCreateCycle } from "../lib.ts";
import { parseArgs } from "../args.ts";

export const command: Command = {
  category: "stack",
  name: "add",
  help: "Track current branch as child of parent",
  args: "<parent> [--reparent]",
  run(args) {
    const { values, positionals } = parseArgs(args, {
      reparent: { type: "boolean", short: "r" },
    });

    const parent = positionals[0];
    if (!parent) {
      console.error("Usage: stack add <parent> [--reparent]");
      process.exit(1);
    }

    const branch = currentBranch();
    if (!branch) {
      console.error("Not on a branch");
      process.exit(1);
    }

    if (branch === parent) {
      console.error("Cannot set branch as its own parent");
      process.exit(1);
    }

    if (!gitTry(`rev-parse --verify ${parent}`)) {
      console.error(`Branch '${parent}' does not exist`);
      process.exit(1);
    }

    const stack = loadStack();

    if (wouldCreateCycle(stack, branch, parent)) {
      console.error(`Cannot add: would create a cycle (${parent} is a descendant of ${branch})`);
      process.exit(1);
    }

    // Enforce linked list structure: no branching allowed
    const existingChildren = getChildren(stack, parent);
    if (existingChildren.length > 0 && !existingChildren.includes(branch) && !values.reparent) {
      console.error(`Cannot add: '${parent}' already has child '${existingChildren[0]}'`);
      console.error(`Stack must be a linked list (no branching).`);
      console.error(`Use --reparent to insert this branch into the chain.`);
      process.exit(1);
    }

    stack[branch] = parent;
    console.log(`Added: ${branch} -> ${parent}`);

    // Optionally reparent children of parent to point to this branch
    if (values.reparent) {
      const children = getChildren(stack, parent);
      const toReparent = children.filter((c) => c !== branch);

      for (const child of toReparent) {
        console.log(`Reparenting: ${child} -> ${branch}`);
        stack[child] = branch;
      }

      if (toReparent.length > 0) {
        console.log(`\nRun 'stack update' to rebase the chain`);
      }
    }

    saveStack(stack);
  },
};
