import type { Stack } from "./state.ts";

export function getChildren(stack: Stack, branch: string): string[] {
  return Object.entries(stack)
    .filter(([_, parent]) => parent === branch)
    .map(([child]) => child);
}

export function getDescendants(stack: Stack, branch: string): string[] {
  const children = getChildren(stack, branch);
  const descendants: string[] = [];
  for (const child of children) {
    descendants.push(child);
    descendants.push(...getDescendants(stack, child));
  }
  return descendants;
}

export function findRoot(stack: Stack, branch: string): string {
  let current = branch;
  while (stack[current]) {
    current = stack[current];
  }
  return current;
}

export function wouldCreateCycle(stack: Stack, child: string, parent: string): boolean {
  let current = parent;
  while (stack[current]) {
    if (stack[current] === child) return true;
    current = stack[current];
  }
  return false;
}

export function getChainFromRoot(stack: Stack, branch: string): string[] {
  const root = findRoot(stack, branch);
  const chain: string[] = [];

  function walk(b: string) {
    const children = getChildren(stack, b);
    for (const child of children) {
      chain.push(child);
      walk(child);
    }
  }

  walk(root);
  return chain;
}

/**
 * Get only the branches in the current stack (not all stacks).
 * Finds the first-level child of root that contains the current branch,
 * then returns that branch and all its descendants.
 */
export function getCurrentStack(stack: Stack, branch: string): string[] {
  // If branch isn't tracked, return empty
  if (!stack[branch]) return [];

  // Walk up to find the stack root (first tracked branch whose parent is untracked)
  let stackRoot = branch;
  let current = branch;
  while (stack[current]) {
    stackRoot = current;
    current = stack[current];
  }

  // Return stack root and all its descendants
  return [stackRoot, ...getDescendants(stack, stackRoot)];
}
