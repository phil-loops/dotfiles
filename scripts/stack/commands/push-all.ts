import { execSync } from "child_process";
import type { Command } from "../types.ts";
import { currentBranch, getCurrentStack, getForkRemote, loadStack } from "../lib.ts";

// ANSI colors
const YELLOW = "\x1b[33m";
const DIM = "\x1b[2m";
const RESET = "\x1b[0m";

function checkForDrift(): number {
  try {
    const output = execSync(
      `node --no-warnings --experimental-strip-types ~/.dotfiles/scripts/stack/index.ts info -d`,
      { encoding: "utf8", stdio: ["pipe", "pipe", "pipe"] }
    );
    // Count lines with ⚠️
    const driftCount = (output.match(/⚠️/g) || []).length;
    return driftCount;
  } catch {
    return 0;
  }
}

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

    // Check for drift (non-blocking)
    const driftCount = checkForDrift();
    if (driftCount > 0) {
      console.log(`${YELLOW}⚠ ${driftCount} branch(es) have drift${RESET}`);
      console.log(`${DIM}  Run 'loops stack resolve' to fix with AI assistance${RESET}\n`);
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
