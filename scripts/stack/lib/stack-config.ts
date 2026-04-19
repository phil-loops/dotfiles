import { execSync } from "child_process";
import { gitRun } from "./git.ts";

// Parent pointers live in `.git/config`:
//   [stack-branch "<name>"]
//       parent = <parent-branch>
// Legacy installs used `git-town-branch.<name>.parent`; we still read those as
// a fallback so code keeps working for repos that haven't run `loops stack migrate`.

const PARENT_SECTION = "stack-branch";
const LEGACY_PARENT_SECTION = "git-town-branch";
const PARENT_REGEX = new RegExp(`^(?:${PARENT_SECTION}|${LEGACY_PARENT_SECTION})\\.(.+)\\.parent\\s+(.+)$`);

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

function readAllRawPointers(): { name: string; parent: string }[] {
  const config = git(`config --get-regexp "^(${PARENT_SECTION}|${LEGACY_PARENT_SECTION})\\."`);
  const byName = new Map<string, string>();
  for (const line of config.split("\n")) {
    const match = line.match(PARENT_REGEX);
    if (!match) continue;
    // New key wins if both are present.
    if (line.startsWith(`${PARENT_SECTION}.`) || !byName.has(match[1])) {
      byName.set(match[1], match[2]);
    }
  }
  return [...byName.entries()].map(([name, parent]) => ({ name, parent }));
}

/**
 * Get ordered stack branches.
 * @param prefix Optional prefix to filter branches (e.g., "goals-v2")
 * @returns Branches in stack order (root to tip)
 */
export function getStackBranches(prefix?: string): StackBranch[] {
  const all = readAllRawPointers();
  const branches = prefix ? all.filter((b) => b.name.startsWith(prefix)) : all;

  const sorted: StackBranch[] = [];
  const remaining = [...branches];

  const branchNames = new Set(branches.map((b) => b.name));
  let current = branches.find((b) => !branchNames.has(b.parent))?.parent || "main";

  while (remaining.length > 0) {
    const idx = remaining.findIndex((b) => b.parent === current);
    if (idx === -1) break;
    const branch = remaining.splice(idx, 1)[0];

    const commitList = git(`log ${branch.parent}..${branch.name} --format=%H`);
    const commits = new Set(commitList.split("\n").filter(Boolean));

    sorted.push({ ...branch, commits });
    current = branch.name;
  }

  return sorted;
}

export function getStackBranchNames(prefix?: string): string[] {
  return getStackBranches(prefix).map((b) => b.name);
}

export function getCurrentBranch(): string {
  return git("branch --show-current");
}

/**
 * Infer the stack prefix from the current branch name (e.g. `goals-v2-01-schema` → `goals-v2`).
 */
export function getStackPrefix(): string | undefined {
  const current = getCurrentBranch();
  const match = current.match(/^(.+?-v\d+)-\d+/);
  if (match) return match[1];
  return undefined;
}

/**
 * Read a branch's parent. Returns null if not tracked.
 * Prefers the new `stack-branch` key; falls back to legacy `git-town-branch`.
 */
export function getParent(branch: string): string | null {
  const newKey = gitRun(["config", "--local", `${PARENT_SECTION}.${branch}.parent`]);
  if (newKey.exitCode === 0 && newKey.stdout) return newKey.stdout;
  const legacyKey = gitRun(["config", "--local", `${LEGACY_PARENT_SECTION}.${branch}.parent`]);
  if (legacyKey.exitCode === 0 && legacyKey.stdout) return legacyKey.stdout;
  return null;
}

/** Write (or overwrite) a branch's parent pointer. */
export function setParent(branch: string, parent: string): void {
  const r = gitRun(["config", "--local", `${PARENT_SECTION}.${branch}.parent`, parent]);
  if (r.exitCode !== 0) {
    throw new Error(`failed to set parent for ${branch}: ${r.stderr}`);
  }
}

/** Remove a branch's parent pointer (both new and legacy keys). */
export function clearBranchConfig(branch: string): void {
  gitRun(["config", "--local", "--remove-section", `${PARENT_SECTION}.${branch}`]);
  gitRun(["config", "--local", "--remove-section", `${LEGACY_PARENT_SECTION}.${branch}`]);
}

/**
 * Return every tracked branch->parent pair, no prefix filtering.
 */
export function getAllParentPointers(): { name: string; parent: string }[] {
  return readAllRawPointers();
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

/**
 * Resolve the trunk branch name. Prefers `stack.main-branch`; falls back to
 * legacy `git-town.main-branch` / `git-town.main`; defaults to "main".
 */
export function getTrunkBranch(): string {
  for (const key of ["stack.main-branch", "git-town.main-branch", "git-town.main"]) {
    const r = gitRun(["config", "--local", key]);
    if (r.exitCode === 0 && r.stdout) return r.stdout;
  }
  return "main";
}
