import type { Command } from "../types.ts";
import { currentBranch, extractKeyChanges, getChainFromRoot, git, loadStack } from "../lib.ts";
import { parseArgs } from "../args.ts";

export const command: Command = {
  category: "nav",
  name: "step",
  help: "Move to next branch and show diff summary",
  args: "[--back]",
  run(args) {
    const { values } = parseArgs(args, {
      back: { type: "boolean", short: "b" },
    });
    const branch = currentBranch();
    const stack = loadStack();

    if (Object.keys(stack).length === 0) {
      console.error("No branches tracked");
      process.exit(1);
    }

    const chain = getChainFromRoot(stack, branch);

    // Find root
    const allParents = new Set(Object.values(stack));
    const allChildren = new Set(Object.keys(stack));
    const root = [...allParents].find((p) => !allChildren.has(p)) || "main";

    // Include root at the beginning for navigation
    const fullChain = [root, ...chain];
    const currentIdx = fullChain.indexOf(branch);

    if (currentIdx === -1) {
      console.error(`Current branch "${branch}" not in stack`);
      process.exit(1);
    }

    const nextIdx = values.back ? currentIdx - 1 : currentIdx + 1;

    if (nextIdx < 0) {
      console.log("Already at the root of the stack");
      process.exit(0);
    }

    if (nextIdx >= fullChain.length) {
      console.log("Already at the end of the stack");
      process.exit(0);
    }

    const targetBranch = fullChain[nextIdx];
    const parentBranch = nextIdx > 0 ? fullChain[nextIdx - 1] : null;

    git(`checkout ${targetBranch}`);

    console.log(`\n→ ${targetBranch} (${nextIdx}/${fullChain.length - 1})`);
    console.log("─".repeat(40));

    if (parentBranch) {
      // Show diff stats
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

      // Show changed functions (rough heuristic - look for function/class definitions)
      console.log("\nKey changes:");
      try {
        const diff = git(`diff ${parentBranch}...${targetBranch} -U0`);
        const changes = extractKeyChanges(diff);
        if (changes.length > 0) {
          changes.slice(0, 10).forEach((c) => console.log(`  ${c}`));
          if (changes.length > 10) {
            console.log(`  ... and ${changes.length - 10} more`);
          }
        } else {
          console.log("  (none detected)");
        }
      } catch {
        console.log("  (could not extract)");
      }
    } else {
      console.log("(root branch)");
    }

    console.log();
  },
};
