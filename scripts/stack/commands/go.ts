import type { Command } from "../types.ts";
import {
  currentBranch,
  extractKeyChanges,
  findRoot,
  getChainFromRoot,
  git,
  gitTry,
  loadStack,
} from "../lib.ts";

type Direction = "next" | "prev" | "last" | "root";

function go(direction: Direction) {
  const stack = loadStack();
  const branch = currentBranch();

  if (Object.keys(stack).length === 0) {
    console.error("No branches tracked");
    process.exit(1);
  }

  const chain = getChainFromRoot(stack, branch || Object.keys(stack)[0]);
  const root = findRoot(stack, branch || Object.keys(stack)[0]);
  const fullChain = [root, ...chain];
  const currentIdx = fullChain.indexOf(branch);

  let targetIdx: number;
  let targetBranch: string;

  switch (direction) {
    case "next":
      if (currentIdx === -1) {
        console.error(`Current branch "${branch}" not in stack`);
        process.exit(1);
      }
      targetIdx = currentIdx + 1;
      if (targetIdx >= fullChain.length) {
        console.log("Already at the end of the stack");
        process.exit(0);
      }
      targetBranch = fullChain[targetIdx];
      break;

    case "prev":
      if (currentIdx === -1) {
        console.error(`Current branch "${branch}" not in stack`);
        process.exit(1);
      }
      targetIdx = currentIdx - 1;
      if (targetIdx < 0) {
        console.log("Already at the root of the stack");
        process.exit(0);
      }
      targetBranch = fullChain[targetIdx];
      break;

    case "last":
      const localBranches = fullChain.filter((b) =>
        gitTry(`show-ref --verify --quiet refs/heads/${b}`)
      );
      if (localBranches.length === 0) {
        console.error("No local branches in chain");
        process.exit(1);
      }
      targetBranch = localBranches[localBranches.length - 1];
      targetIdx = fullChain.indexOf(targetBranch);
      break;

    case "root":
      targetBranch = root;
      targetIdx = 0;
      break;
  }

  if (targetBranch === branch) {
    console.log(`Already at ${direction} (${targetBranch})`);
    process.exit(0);
  }

  // Check for uncommitted changes - offer to stash
  const status = git("status --porcelain");
  if (status.trim()) {
    console.log("Stashing uncommitted changes...");
    git("stash push -u -m 'stack-go-stash'");
  }

  // For next, check if target needs rebasing
  const parentBranch = targetIdx > 0 ? fullChain[targetIdx - 1] : null;
  if (direction === "next" && parentBranch) {
    try {
      const mergeBase = git(`merge-base ${parentBranch} ${targetBranch}`);
      const parentHead = git(`rev-parse ${parentBranch}`);

      if (mergeBase !== parentHead) {
        console.log(`\n${targetBranch} is behind ${parentBranch}, updating...`);
        git(`checkout ${targetBranch}`);
        if (!gitTry(`rebase ${parentBranch}`)) {
          console.error(`\nRebase failed. Resolve conflicts then continue.`);
          process.exit(1);
        }
        console.log("Updated.\n");
      } else {
        git(`checkout ${targetBranch}`);
      }
    } catch {
      git(`checkout ${targetBranch}`);
    }
  } else {
    git(`checkout ${targetBranch}`);
  }

  // Pop stash if we stashed
  if (status.trim()) {
    console.log("Restoring stashed changes...");
    gitTry("stash pop");
  }

  console.log(`\n→ ${targetBranch} (${fullChain.indexOf(targetBranch)}/${fullChain.length - 1})`);
  console.log("─".repeat(40));

  // Show diff summary for context
  if (parentBranch && direction !== "root") {
    try {
      const stat = git(`diff --stat ${parentBranch}...${targetBranch}`);
      if (stat) {
        console.log(stat);
      } else {
        console.log("(no changes from parent)");
      }
    } catch {
      console.log("(could not compute diff)");
    }

    console.log("\nKey changes:");
    try {
      const diff = git(`diff ${parentBranch}...${targetBranch} -U0`);
      const changes = extractKeyChanges(diff);
      if (changes.length > 0) {
        changes.slice(0, 8).forEach((c) => console.log(`  ${c}`));
        if (changes.length > 8) {
          console.log(`  ... and ${changes.length - 8} more`);
        }
      } else {
        console.log("  (none detected)");
      }
    } catch {
      console.log("  (could not extract)");
    }
  } else if (direction === "root") {
    console.log("(root branch)");
  }

  console.log();
}

export const command: Command = {
  category: "nav",
  name: "go",
  args: "<next|prev|last|root>",
  help: "Navigate stack (next, prev, last, root)",
  run(args: string[]) {
    const direction = args[0] as Direction;

    if (!direction || !["next", "prev", "last", "root"].includes(direction)) {
      console.log("Usage: stack go <next|prev|last|root>");
      console.log("");
      console.log("  next  - Move to next branch (toward leaf)");
      console.log("  prev  - Move to previous branch (toward root)");
      console.log("  last  - Jump to deepest branch");
      console.log("  root  - Jump to root branch");
      process.exit(1);
    }

    go(direction);
  },
};
