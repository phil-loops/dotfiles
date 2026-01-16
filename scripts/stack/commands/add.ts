import { currentBranch, loadStack, saveStack, wouldCreateCycle } from "../lib.ts";

export function add(parent: string) {
  const branch = currentBranch();
  if (!branch) {
    console.error("Not on a branch");
    process.exit(1);
  }

  if (branch === parent) {
    console.error("Cannot set branch as its own parent");
    process.exit(1);
  }

  const stack = loadStack();

  if (wouldCreateCycle(stack, branch, parent)) {
    console.error(`Cannot add: would create a cycle (${parent} is a descendant of ${branch})`);
    process.exit(1);
  }

  stack[branch] = parent;
  saveStack(stack);
  console.log(`Added: ${branch} -> ${parent}`);
}
