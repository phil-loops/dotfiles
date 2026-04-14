import { execSync } from "child_process";
import { gitRun } from "./git.ts";

export function git(cmd: string): string {
  try {
    return execSync(`git ${cmd}`, { encoding: "utf-8" }).trim();
  } catch {
    return "";
  }
}

export function gitOrFail(cmd: string): string {
  return execSync(`git ${cmd}`, { encoding: "utf-8" }).trim();
}

export interface StackBranch {
  name: string;
  parent: string;
  commits: Set<string>;
}

/**
 * Get ordered stack branches from git-town config
 * @param prefix Optional prefix to filter branches (e.g., "goals-v2")
 * @returns Branches in stack order (root to tip)
 */
export function getStackBranches(prefix?: string): StackBranch[] {
  const config = git("config --get-regexp git-town-branch");
  const branches: { name: string; parent: string }[] = [];

  for (const line of config.split("\n")) {
    const match = line.match(/git-town-branch\.(.+)\.parent\s+(.+)/);
    if (match) {
      const name = match[1];
      if (prefix && !name.startsWith(prefix)) continue;
      branches.push({ name, parent: match[2] });
    }
  }

  // Sort by chain from main (or first root found)
  const sorted: StackBranch[] = [];
  const remaining = [...branches];

  // Find the root - a branch whose parent is not in our set
  const branchNames = new Set(branches.map(b => b.name));
  let current = branches.find(b => !branchNames.has(b.parent))?.parent || "main";

  while (remaining.length > 0) {
    const idx = remaining.findIndex((b) => b.parent === current);
    if (idx === -1) break;
    const branch = remaining.splice(idx, 1)[0];

    // Get commits unique to this branch (not in parent)
    const commitList = git(`log ${branch.parent}..${branch.name} --format=%H`);
    const commits = new Set(commitList.split("\n").filter(Boolean));

    sorted.push({ ...branch, commits });
    current = branch.name;
  }

  return sorted;
}

/**
 * Get just the branch names in order
 */
export function getStackBranchNames(prefix?: string): string[] {
  return getStackBranches(prefix).map(b => b.name);
}

/**
 * Get current branch name
 */
export function getCurrentBranch(): string {
  return git("branch --show-current");
}

/**
 * Get the stack prefix from current branch or .stack file
 */
export function getStackPrefix(): string | undefined {
  const current = getCurrentBranch();

  // Try to extract prefix from branch name (e.g., "goals-v2-01-schema" -> "goals-v2")
  const match = current.match(/^(.+?-v\d+)-\d+/);
  if (match) return match[1];

  // Could also read from .stack file if it exists
  return undefined;
}

/**
 * Read a branch's parent from git-town config. Returns null if not tracked.
 */
export function getParent(branch: string): string | null {
  const r = gitRun(["config", "--local", `git-town-branch.${branch}.parent`]);
  return r.exitCode === 0 && r.stdout ? r.stdout : null;
}

/** Write (or overwrite) a branch's parent pointer. */
export function setParent(branch: string, parent: string): void {
  const r = gitRun(["config", "--local", `git-town-branch.${branch}.parent`, parent]);
  if (r.exitCode !== 0) {
    throw new Error(`failed to set parent for ${branch}: ${r.stderr}`);
  }
}

/** Remove a branch's git-town config entries entirely. */
export function clearBranchConfig(branch: string): void {
  gitRun(["config", "--local", "--remove-section", `git-town-branch.${branch}`]);
}

/**
 * Return every tracked branch->parent pair, no prefix filtering.
 */
export function getAllParentPointers(): { name: string; parent: string }[] {
  const config = git("config --get-regexp git-town-branch");
  const out: { name: string; parent: string }[] = [];
  for (const line of config.split("\n")) {
    const m = line.match(/git-town-branch\.(.+)\.parent\s+(.+)/);
    if (m) {
      out.push({ name: m[1], parent: m[2] });
    }
  }
  return out;
}

export interface StackTreeNode {
  name: string;
  parent: string;
  children: StackTreeNode[];
}

/**
 * Build a tree (or forest) of tracked branches. Roots are branches whose parents
 * are not themselves tracked (typically `main`). If `prefix` is given, only
 * branches matching it are included, and the tree may be pruned.
 */
export function getStackTree(prefix?: string): StackTreeNode[] {
  const all = getAllParentPointers();
  const filtered = prefix ? all.filter((b) => b.name.startsWith(prefix)) : all;
  const byName = new Map<string, StackTreeNode>();
  for (const b of filtered) {
    byName.set(b.name, { name: b.name, parent: b.parent, children: [] });
  }
  const roots: StackTreeNode[] = [];
  for (const node of byName.values()) {
    const parent = byName.get(node.parent);
    if (parent) {
      parent.children.push(node);
    } else {
      roots.push(node);
    }
  }
  return roots;
}

/** Walk a forest top-down (root-first, then BFS-ish by insertion order). */
export function walkTopDown(roots: StackTreeNode[]): StackTreeNode[] {
  const out: StackTreeNode[] = [];
  const queue = [...roots];
  while (queue.length > 0) {
    const node = queue.shift()!;
    out.push(node);
    queue.push(...node.children);
  }
  return out;
}
