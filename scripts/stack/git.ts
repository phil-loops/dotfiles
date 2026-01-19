import { execSync } from "child_process";

export function git(cmd: string): string {
  return execSync(`git ${cmd}`, { encoding: "utf-8" }).trim();
}

export function gitTry(cmd: string): boolean {
  try {
    execSync(`git ${cmd}`, { encoding: "utf-8", stdio: "pipe" });
    return true;
  } catch {
    return false;
  }
}

export function currentBranch(): string {
  return git("branch --show-current");
}

export type ConflictResult = {
  hasConflict: boolean;
  files: string[];
};

/**
 * Check if rebasing child onto parent would cause conflicts
 * Uses git merge-tree to simulate the merge without touching working directory
 */
export function checkConflict(parent: string, child: string): ConflictResult {
  try {
    const mergeBase = git(`merge-base ${parent} ${child}`);
    execSync(`git merge-tree ${mergeBase} ${parent} ${child}`, {
      encoding: "utf-8",
      stdio: ["pipe", "pipe", "pipe"],
    });
    return { hasConflict: false, files: [] };
  } catch (e: any) {
    const output = e.stdout?.toString() || "";
    const stderr = e.stderr?.toString() || "";
    const conflictFiles: string[] = [];

    const lines = (output + stderr).split("\n");
    for (const line of lines) {
      if (line.includes("CONFLICT")) {
        const match = line.match(/Merge conflict in (.+)$/);
        if (match) {
          conflictFiles.push(match[1]);
        }
      }
    }

    if (conflictFiles.length === 0 && output.includes("<<<<<<")) {
      return { hasConflict: true, files: ["(unable to parse specific files)"] };
    }

    return { hasConflict: conflictFiles.length > 0, files: conflictFiles };
  }
}

/**
 * Get all branches matching a prefix, sorted numerically
 * Handles: goals-1, goals-1.5, goals-2, goals-10
 */
export function getBranchesByPrefix(prefix: string): string[] {
  try {
    const allBranches = git("branch --list").split("\n").map((b) => b.trim().replace(/^\*\s*/, ""));
    const matching = allBranches.filter((b) => b.startsWith(prefix));

    return matching.sort((a, b) => {
      const numA = parseFloat(a.slice(prefix.length)) || 0;
      const numB = parseFloat(b.slice(prefix.length)) || 0;
      return numA - numB;
    });
  } catch {
    return [];
  }
}
