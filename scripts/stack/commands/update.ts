import type { Command } from "../types.ts";
import {
  currentBranch,
  getChainFromRoot,
  getDescendants,
  git,
  gitTry,
  loadStack,
} from "../lib.ts";

export const command: Command = {
  name: "update",
  help: "Rebase current branch + descendants (--all for entire tree)",
  args: "[--all]",
  run(args) {
    const all = args.includes("--all");
    const branch = currentBranch();
    const stack = loadStack();

    if (Object.keys(stack).length === 0) {
      console.log("No branches tracked");
      return;
    }

    let toRebase: string[];
    if (all) {
      toRebase = getChainFromRoot(stack, branch);
    } else {
      toRebase = [branch, ...getDescendants(stack, branch)].filter((b) => stack[b]);
    }

    if (toRebase.length === 0) {
      console.log("Nothing to rebase");
      return;
    }

    console.log(`\nWill rebase: ${toRebase.join(" -> ")}\n`);

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
