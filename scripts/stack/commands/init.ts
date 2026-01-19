import type { Command } from "../types.ts";
import { currentBranch, getBranchesByPrefix, gitTry, loadStack, saveStack } from "../lib.ts";

export const command: Command = {
  name: "init",
  help: "Initialize stack from branch prefix (e.g., stack init goals-)",
  args: "[prefix]",
  run(args) {
    const prefix = args[0];

    if (!prefix) {
      // Try to detect prefix from current branch
      const branch = currentBranch();
      const match = branch.match(/^(.+-)(\d+(?:\.\d+)?)$/);
      if (match) {
        console.log(`Detected prefix: ${match[1]}`);
        console.log(`Run: stack init ${match[1]}`);
      } else {
        console.log("Usage: stack init <prefix>");
        console.log("Example: stack init goals-");
      }
      return;
    }

    // Ensure prefix ends with a separator
    const normalizedPrefix = prefix.endsWith("-") ? prefix : prefix + "-";

    // Find branches matching prefix
    const branches = getBranchesByPrefix(normalizedPrefix);

    if (branches.length === 0) {
      console.log(`No branches matching ${normalizedPrefix}*`);
      console.log(`Create one with: git checkout -b ${normalizedPrefix}1`);
      return;
    }

    // Detect root (default to main)
    let root = "main";
    if (!gitTry("rev-parse --verify main")) {
      if (gitTry("rev-parse --verify master")) {
        root = "master";
      }
    }

    // Build stack: each branch's parent is the previous one
    const stack = loadStack();
    for (let i = 0; i < branches.length; i++) {
      const branch = branches[i];
      const parent = i === 0 ? root : branches[i - 1];
      stack[branch] = parent;
    }
    saveStack(stack);

    console.log(`Initialized stack from ${normalizedPrefix}*:`);
    console.log(`  Root: ${root}`);
    console.log(`  Branches: ${branches.join(" -> ")}`);
    console.log(`\nRun 'stack list' to see the tree.`);
  },
};
