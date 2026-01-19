import type { Command } from "../types.ts";
import { currentBranch, findRoot, getChainFromRoot, git, loadStack } from "../lib.ts";

function moveChanges(target: "root" | "last") {
  const stack = loadStack();
  const branch = currentBranch();

  if (Object.keys(stack).length === 0) {
    console.error("No branches tracked");
    process.exit(1);
  }

  const status = git("status --porcelain");
  if (!status.trim()) {
    console.error("No uncommitted changes to move");
    process.exit(1);
  }

  const chain = getChainFromRoot(stack, branch || Object.keys(stack)[0]);
  const root = findRoot(stack, branch || Object.keys(stack)[0]);

  const targetBranch = target === "root" ? root : chain[chain.length - 1];

  if (targetBranch === branch) {
    console.log(`Already on ${target} branch (${targetBranch})`);
    process.exit(0);
  }

  console.log(`Moving uncommitted changes from ${branch} to ${targetBranch}...`);

  git("stash push -u -m 'stack-move-changes'");
  git(`checkout ${targetBranch}`);
  git("stash pop");

  console.log(`\nDone! Now on ${targetBranch} with your changes.`);
}

export const commands: Command[] = [
  {
    category: "util",
  name: "move-to-root",
    help: "Stash changes and move to root branch",
    run() {
      moveChanges("root");
    },
  },
  {
    category: "util",
  name: "move-to-last",
    help: "Stash changes and move to deepest branch",
    run() {
      moveChanges("last");
    },
  },
];
