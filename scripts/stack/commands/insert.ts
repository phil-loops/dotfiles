import { getChildren, git, loadStack, saveStack } from "../lib.ts";

/**
 * Insert a new branch after a parent, reparenting the parent's children
 *
 * Before: main -> goals-1 -> goals-2 -> goals-3
 * Run:    stack insert goals-1.5 --after goals-1
 * After:  main -> goals-1 -> goals-1.5 -> goals-2 -> goals-3
 */
export function insert(newBranch: string, afterBranch: string) {
  const stack = loadStack();

  // Check if new branch name already exists
  try {
    git(`rev-parse --verify ${newBranch}`);
    console.error(`Branch "${newBranch}" already exists`);
    process.exit(1);
  } catch {
    // Good - branch doesn't exist
  }

  // Verify the "after" branch exists
  try {
    git(`rev-parse --verify ${afterBranch}`);
  } catch {
    console.error(`Branch "${afterBranch}" does not exist`);
    process.exit(1);
  }

  // Get current children of the "after" branch
  const children = getChildren(stack, afterBranch);

  // Create the new branch from the "after" branch
  console.log(`Creating branch ${newBranch} from ${afterBranch}...`);
  git(`branch ${newBranch} ${afterBranch}`);

  // Add new branch to stack with "after" as its parent
  stack[newBranch] = afterBranch;

  // Reparent all children to point to the new branch
  for (const child of children) {
    console.log(`Reparenting ${child}: ${afterBranch} -> ${newBranch}`);
    stack[child] = newBranch;
  }

  saveStack(stack);

  console.log(`\nInserted ${newBranch} after ${afterBranch}`);

  if (children.length > 0) {
    console.log(`Reparented: ${children.join(", ")}`);
    console.log(`\nRun 'stack update' to rebase the chain`);
  }

  // Switch to the new branch
  git(`checkout ${newBranch}`);
  console.log(`\nNow on ${newBranch}`);
}
