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
