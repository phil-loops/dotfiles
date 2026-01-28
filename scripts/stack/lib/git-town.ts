import { execSync } from "child_process";

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
