import type { Command } from "../types.ts";
import {
  checkConflict,
  currentBranch,
  getCurrentStack,
  getDescendants,
  git,
  gitTry,
  loadStack,
  saveSnapshot,
} from "../lib.ts";
import { parseArgs } from "../args.ts";

export const command: Command = {
  category: "git",
  name: "update",
  help: "Rebase current branch + descendants (--all for entire tree)",
  args: "[--all] [--force]",
  run(args) {
    const { values } = parseArgs(args, {
      all: { type: "boolean", short: "a" },
      force: { type: "boolean", short: "f" },
    });
    const branch = currentBranch();
    const stack = loadStack();

    if (Object.keys(stack).length === 0) {
      console.log("No branches tracked");
      return;
    }

    let toRebase: string[];
    if (values.all) {
      toRebase = getCurrentStack(stack, branch);
    } else {
      toRebase = [branch, ...getDescendants(stack, branch)].filter((b) => stack[b]);
    }

    if (toRebase.length === 0) {
      console.log("Nothing to rebase");
      return;
    }

    console.log(`\nWill rebase: ${toRebase.join(" -> ")}\n`);

    // Check for conflicts first (unless --force)
    if (!values.force) {
      const conflicts: Array<{ child: string; parent: string; files: string[] }> = [];
      for (const b of toRebase) {
        const parent = stack[b];
        if (!parent) continue;
        const result = checkConflict(parent, b);
        if (result.hasConflict) {
          conflicts.push({ child: b, parent, files: result.files });
        }
      }

      if (conflicts.length > 0) {
        console.error("Conflicts detected:\n");
        for (const { child, parent, files } of conflicts) {
          console.error(`  ${child} onto ${parent}:`);
          for (const file of files) {
            console.error(`    - ${file}`);
          }
        }
        console.error("\nAborting. Use --force to attempt anyway.");
        process.exit(1);
      }
      console.log("Conflict check passed.\n");
    }

    // Save snapshot of ALL branches before rebasing (so whatchanged shows full picture)
    const allBranches = Object.keys(stack);
    saveSnapshot("update", allBranches);

    for (const b of toRebase) {
      const parent = stack[b];
      if (!parent) continue;

      console.log(`Rebasing ${b} onto ${parent}...`);
      git(`checkout ${b}`);

      if (gitTry(`rebase ${parent}`)) {
        console.log(`Done: ${b}\n`);
      } else {
        console.error(`\nFailed: ${b} (merge conflict)`);
        console.error(`
To resolve:
  1. Edit the conflicted files
  2. git add <resolved files>
  3. git rebase --continue
  4. Re-run: stack update

To abort: git rebase --abort
Use 'git reflog' to find previous state if needed.
`);
        process.exit(1);
      }
    }

    git(`checkout ${branch}`);
    console.log(`Done! Back on ${branch}`);
  },
};
