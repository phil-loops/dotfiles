import type { Command } from "../types.ts";
import { currentBranch, extractKeyChanges, getChainFromRoot, git, gitTry, loadStack } from "../lib.ts";
import { parseArgs } from "../args.ts";
import { execSync } from "child_process";

export const command: Command = {
  category: "nav",
  name: "step",
  help: "Move to next branch and show diff summary",
  args: "[--back] [--skip-lint] [--skip-compile]",
  run(args) {
    const { values } = parseArgs(args, {
      back: { type: "boolean", short: "b" },
      "skip-lint": { type: "boolean" },
      "skip-compile": { type: "boolean" },
    });
    const branch = currentBranch();

    // Run lint unless skipped
    if (!values["skip-lint"] && !values.back) {
      console.log("Running lint...");
      try {
        execSync("task lint:warn", { stdio: "inherit" });
      } catch {
        console.error("\nLint failed. Fix errors or use --skip-lint to proceed anyway.");
        process.exit(1);
      }
    }

    // Run compile unless skipped
    if (!values["skip-compile"] && !values.back) {
      console.log("Running compile check...");
      try {
        execSync("npx tsc --noEmit", { stdio: "inherit" });
      } catch {
        console.error("\nCompile failed. Fix errors or use --skip-compile to proceed anyway.");
        process.exit(1);
      }
    }
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

    // Check if target branch needs rebasing onto its parent
    if (parentBranch && !values.back) {
      try {
        const mergeBase = git(`merge-base ${parentBranch} ${targetBranch}`);
        const parentHead = git(`rev-parse ${parentBranch}`);

        if (mergeBase !== parentHead) {
          console.log(`\n${targetBranch} is behind ${parentBranch}, updating...`);
          git(`checkout ${targetBranch}`);
          if (!gitTry(`rebase ${parentBranch}`)) {
            console.error(`\nRebase failed (conflict). Resolve with:`);
            console.error(`  1. Edit conflicted files`);
            console.error(`  2. git add <files>`);
            console.error(`  3. git rebase --continue`);
            process.exit(1);
          }
          console.log("Updated.\n");
        }
      } catch {
        // If we can't check, just proceed
      }
    }

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
