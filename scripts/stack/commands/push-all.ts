import { execSync } from "child_process";
import type { Command } from "../types.ts";
import { currentBranch, getCurrentStack, getForkRemote, loadStack } from "../lib.ts";

export const command: Command = {
  category: "git",
  name: "push-all",
  help: "Push all tracked branches",
  run() {
    const stack = loadStack();
    const branch = currentBranch();

    if (Object.keys(stack).length === 0) {
      console.error("No branches tracked");
      process.exit(1);
    }

    const branches = getCurrentStack(stack, branch);
    if (branches.length === 0) {
      console.error("Current branch is not in a tracked stack");
      process.exit(1);
    }

    const remote = getForkRemote();

    console.log(`Pushing ${branches.length} branches in current stack to ${remote}...\n`);

    for (const b of branches) {
      console.log(`Pushing ${b}...`);
      try {
        execSync(`git push ${remote} ${b} -f`, { stdio: "inherit" });
      } catch {
        console.error(`Failed to push ${b}`);
      }
    }

    console.log("\nDone!");
  },
};
