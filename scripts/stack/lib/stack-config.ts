import { execSync } from "child_process";
import { gitRun } from "./git.ts";

// Parent pointers live in `.git/config`:
//   [stack-branch "<name>"]
//       parent = <parent-branch>

const PARENT_SECTION = "stack-branch";
const PARENT_REGEX = new RegExp(`^${PARENT_SECTION}\\.(.+)\\.parent\\s+(.+)$`);

export function git(cmd: string): string {
  try {
    return execSync(`git ${cmd}`, {
      encoding: "utf-8",
      stdio: ["ignore", "pipe", "pipe"],
    }).trim();
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
  const config = git(`config --get-regexp "^${PARENT_SECTION}\\."`);
  const result: { name: string; parent: string }[] = [];
  for (const line of config.split("\n")) {
    const match = line.match(PARENT_REGEX);
    if (match) result.push({ name: match[1], parent: match[2] });
  }
  return result;
}

/**
 * Get ordered stack branches along the current branch's lineage.
 *
 * Returns the linear chain that runs from the current branch's stack root,
 * through the current branch, and down the longest descendant path. Branches
 * in sibling stacks (and sibling forks within the same root) are excluded.
 *
 * If the current branch is not tracked, falls back to the first config-order
 * tracked root (the legacy "pick something reasonable" behavior).
 *
 * @param prefix Optional prefix to restrict the universe of tracked branches.
 * @returns Branches in stack order (root to tip).
 */
export function getStackBranches(prefix?: string): StackBranch[] {
  const all = readAllRawPointers();
  const filtered = prefix ? all.filter((b) => b.name.startsWith(prefix)) : all;
  if (filtered.length === 0) return [];

  const byName = new Map(filtered.map((b) => [b.name, b]));
  const childrenOf = new Map<string, { name: string; parent: string }[]>();
  for (const b of filtered) {
    const arr = childrenOf.get(b.parent) ?? [];
    arr.push(b);
    childrenOf.set(b.parent, arr);
  }

  // Anchor on the current branch if it's tracked; otherwise fall back to the
  // first tracked branch whose parent is untracked (a root).
  const currentBranch = getCurrentBranch();
  let anchor: string;
  if (byName.has(currentBranch)) {
    anchor = currentBranch;
  } else {
    const root = filtered.find((b) => !byName.has(b.parent));
    if (!root) return [];
    anchor = root.name;
  }

  // Walk up from anchor to root within the tracked set.
  const lineage: string[] = [anchor];
  let n = anchor;
  while (true) {
    const p = byName.get(n)?.parent;
    if (!p || !byName.has(p)) break;
    lineage.unshift(p);
    n = p;
  }

  // Walk down from anchor along the longest descendant path.
  const longestPath = (b: string): string[] => {
    let best: string[] = [];
    for (const c of childrenOf.get(b) ?? []) {
      const sub = [c.name, ...longestPath(c.name)];
      if (sub.length > best.length) best = sub;
    }
    return best;
  };
  lineage.push(...longestPath(anchor));

  return lineage.map((name) => {
    const b = byName.get(name)!;
    const commitList = git(`log ${b.parent}..${b.name} --format=%H`);
    const commits = new Set(commitList.split("\n").filter(Boolean));
    return { ...b, commits };
  });
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
 */
export function getParent(branch: string): string | null {
  const r = gitRun(["config", "--local", `${PARENT_SECTION}.${branch}.parent`]);
  if (r.exitCode === 0 && r.stdout) return r.stdout;
  return null;
}

/** Write (or overwrite) a branch's parent pointer. */
export function setParent(branch: string, parent: string): void {
  const r = gitRun(["config", "--local", `${PARENT_SECTION}.${branch}.parent`, parent]);
  if (r.exitCode !== 0) {
    throw new Error(`failed to set parent for ${branch}: ${r.stderr}`);
  }
}

/** Remove a branch's parent pointer. */
export function clearBranchConfig(branch: string): void {
  gitRun(["config", "--local", "--remove-section", `${PARENT_SECTION}.${branch}`]);
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
 * Resolve the trunk branch name from `stack.main-branch`; defaults to "main".
 */
export function getTrunkBranch(): string {
  const r = gitRun(["config", "--local", "stack.main-branch"]);
  if (r.exitCode === 0 && r.stdout) return r.stdout;
  return "main";
}

// =====================================================================
// Project membership (stack-project.<name>.branch = <branch>, multi-value;
// optional stack-project.<name>.memory = <path>, single-value).
// =====================================================================

const PROJECT_SECTION = "stack-project";
const PROJECT_BRANCH_REGEX = new RegExp(`^${PROJECT_SECTION}\\.(.+)\\.branch\\s+(.+)$`);

/** List all known project names. */
export function getProjects(): string[] {
  const config = git(`config --get-regexp "^${PROJECT_SECTION}\\."`);
  const names = new Set<string>();
  for (const line of config.split("\n")) {
    const match = line.match(/^stack-project\.(.+)\.(branch|memory)\s+/);
    if (match) names.add(match[1]);
  }
  return [...names].sort();
}

/** Branches that belong to a project, in config order. */
export function getProjectBranches(project: string): string[] {
  const r = gitRun(["config", "--local", "--get-all", `${PROJECT_SECTION}.${project}.branch`]);
  if (r.exitCode !== 0 || !r.stdout) return [];
  return r.stdout.split("\n").filter(Boolean);
}

/** Reverse lookup: which projects contain a given branch. */
export function getProjectsForBranch(branch: string): string[] {
  const config = git(`config --get-regexp "^${PROJECT_SECTION}\\..+\\.branch$"`);
  const out = new Set<string>();
  for (const line of config.split("\n")) {
    const match = line.match(PROJECT_BRANCH_REGEX);
    if (match && match[2] === branch) out.add(match[1]);
  }
  return [...out].sort();
}

/** Add a branch to a project (no-op if already a member). */
export function addProjectBranch(project: string, branch: string): void {
  const existing = getProjectBranches(project);
  if (existing.includes(branch)) return;
  const r = gitRun(["config", "--local", "--add", `${PROJECT_SECTION}.${project}.branch`, branch]);
  if (r.exitCode !== 0) {
    throw new Error(`failed to add ${branch} to project ${project}: ${r.stderr}`);
  }
}

/** Remove a single branch from a project. */
export function removeProjectBranch(project: string, branch: string): void {
  const r = gitRun([
    "config",
    "--local",
    "--unset-all",
    `${PROJECT_SECTION}.${project}.branch`,
    `^${branch}$`,
  ]);
  // exit 5 = key not present, which is fine
  if (r.exitCode !== 0 && r.exitCode !== 5) {
    throw new Error(`failed to remove ${branch} from project ${project}: ${r.stderr}`);
  }
}

/** Remove a project entirely (drops every key under stack-project.<name>). */
export function removeProject(project: string): void {
  const r = gitRun(["config", "--local", "--remove-section", `${PROJECT_SECTION}.${project}`]);
  if (r.exitCode !== 0 && r.exitCode !== 128) {
    throw new Error(`failed to remove project ${project}: ${r.stderr}`);
  }
}

/** Set or replace a project's memory-file path. */
export function setProjectMemory(project: string, path: string): void {
  const r = gitRun(["config", "--local", `${PROJECT_SECTION}.${project}.memory`, path]);
  if (r.exitCode !== 0) {
    throw new Error(`failed to set memory for project ${project}: ${r.stderr}`);
  }
}

/** Read a project's memory-file path, or null if unset. */
export function getProjectMemory(project: string): string | null {
  const r = gitRun(["config", "--local", `${PROJECT_SECTION}.${project}.memory`]);
  if (r.exitCode === 0 && r.stdout) return r.stdout;
  return null;
}
