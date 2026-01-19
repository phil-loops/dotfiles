import type { Command } from "../types.ts";
import { currentBranch, getChainFromRoot, git, loadStack } from "../lib.ts";

export const command: Command = {
  category: "nav",
  name: "last",
  help: "Switch to deepest branch in stack",
  run() {
    const stack = loadStack();
    const branch = currentBranch();

    if (Object.keys(stack).length === 0) {
      console.error("No branches tracked");
      process.exit(1);
    }

    const chain = getChainFromRoot(stack, branch || Object.keys(stack)[0]);
    if (chain.length === 0) {
      console.error("No branches in chain");
      process.exit(1);
    }

    const lastBranch = chain[chain.length - 1];
    console.log(`Switching to ${lastBranch}`);
    git(`checkout ${lastBranch}`);
  },
};
