import { currentBranch, getChildren, loadStack, saveStack } from "../lib.ts";

export function remove() {
  const branch = currentBranch();
  if (!branch) {
    console.error("Not on a branch");
    process.exit(1);
  }

  const stack = loadStack();
  if (!stack[branch]) {
    console.error(`Branch "${branch}" is not tracked`);
    process.exit(1);
  }

  const children = getChildren(stack, branch);
  if (children.length > 0) {
    console.error(`Cannot remove: ${branch} has children: ${children.join(", ")}`);
    console.error("Remove or reparent them first");
    process.exit(1);
  }

  delete stack[branch];
  saveStack(stack);
  console.log(`Removed: ${branch}`);
}
