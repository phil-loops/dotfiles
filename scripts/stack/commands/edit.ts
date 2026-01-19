import type { Command } from "../types.ts";
import {
  clearEditState,
  currentBranch,
  getDescendants,
  git,
  gitTry,
  loadEditState,
  loadStack,
  saveEditState,
} from "../lib.ts";

function editBranch(targetBranch: string) {
  const branch = currentBranch();
  if (!branch) {
    console.error("Not on a branch");
    process.exit(1);
  }

  if (branch === targetBranch) {
    console.error(`Already on ${targetBranch}`);
    process.exit(1);
  }

  const existingState = loadEditState();
  if (existingState) {
    console.error(`Already in edit mode (editing from ${existingState.returnBranch})`);
    console.error("Run 'stack return' first or 'stack edit --abort' to cancel");
    process.exit(1);
  }

  const status = git("status --porcelain");
  const hasChanges = status.trim().length > 0;

  if (hasChanges) {
    console.log("Stashing uncommitted changes...");
    git("stash push -u -m 'stack-edit-stash'");
  }

  saveEditState({ returnBranch: branch, hasStash: hasChanges });
  git(`checkout ${targetBranch}`);

  console.log(`\nNow on ${targetBranch}`);
  console.log("Make your changes, commit, then run 'stack return'");
}

function abortEdit() {
  const state = loadEditState();
  if (!state) {
    console.error("Not in edit mode");
    process.exit(1);
  }

  git(`checkout ${state.returnBranch}`);

  if (state.hasStash) {
    console.log("Restoring stashed changes...");
    git("stash pop");
  }

  clearEditState();
  console.log(`Aborted. Back on ${state.returnBranch}`);
}

export const commands: Command[] = [
  {
    name: "edit",
    help: "Stash, checkout branch, remember where to return",
    args: "<branch>",
    run(args) {
      if (args[0] === "--abort") {
        abortEdit();
      } else if (!args[0]) {
        console.error("Usage: stack edit <branch> or stack edit --abort");
        process.exit(1);
      } else {
        editBranch(args[0]);
      }
    },
  },
  {
    name: "return",
    help: "After editing: update descendants, return, pop stash",
    run() {
      const state = loadEditState();
      if (!state) {
        console.error("Not in edit mode. Use 'stack edit <branch>' first");
        process.exit(1);
      }

      const branch = currentBranch();
      const stack = loadStack();

      const status = git("status --porcelain");
      if (status.trim()) {
        console.error("You have uncommitted changes. Commit or stash them first.");
        process.exit(1);
      }

      const descendants = getDescendants(stack, branch);
      const toRebase = descendants.filter((b) => {
        let current = state.returnBranch;
        while (current) {
          if (current === b) return true;
          current = stack[current];
        }
        return false;
      });

      if (toRebase.length > 0) {
        console.log(`\nUpdating descendants: ${toRebase.join(" -> ")}\n`);

        for (const b of toRebase) {
          const parent = stack[b];
          if (!parent) continue;

          console.log(`Rebasing ${b} onto ${parent}...`);
          git(`checkout ${b}`);

          if (gitTry(`rebase ${parent}`)) {
            console.log(`Done: ${b}`);
          } else {
            console.error(`\nFailed: ${b} (merge conflict)`);
            console.error("Resolve the conflict, then run 'stack return' again");
            process.exit(1);
          }
        }
      }

      git(`checkout ${state.returnBranch}`);

      if (state.hasStash) {
        console.log("\nRestoring stashed changes...");
        git("stash pop");
      }

      clearEditState();
      console.log(`\nBack on ${state.returnBranch}`);
    },
  },
];
