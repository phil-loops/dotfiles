import type { Command } from "../types.ts";
import { currentBranch, getChildren, git, loadStack } from "../lib.ts";
import { parseArgs } from "../args.ts";

const DEFAULT_THRESHOLD = 150;

/**
 * Get the root ancestor of a branch (the branch that has no parent in the stack)
 */
function getRoot(stack: Record<string, string>, branch: string): string {
  let current = branch;
  while (stack[current]) {
    current = stack[current];
  }
  return current;
}

/**
 * Get all branches in the same tree as the given branch
 */
function getTreeBranches(stack: Record<string, string>, branch: string): Set<string> {
  const root = getRoot(stack, branch);
  const tree = new Set<string>();

  function collectDescendants(b: string) {
    tree.add(b);
    for (const child of getChildren(stack, b)) {
      collectDescendants(child);
    }
  }

  collectDescendants(root);
  return tree;
}

type BranchStats = {
  branch: string;
  parent: string;
  loc: number;
  exceeds: boolean;
};

/**
 * Get lines changed (added + removed) for .ts files only
 * Excludes .tsx and .test.ts files
 */
function getTsLoc(parent: string, child: string): number {
  try {
    // Get diff stats for .ts files, excluding .tsx and .test.ts
    const diffOutput = git(
      `diff --numstat ${parent}...${child} -- "*.ts" ":!*.tsx" ":!*.test.ts"`
    );

    if (!diffOutput.trim()) return 0;

    let totalLoc = 0;
    for (const line of diffOutput.split("\n")) {
      if (!line.trim()) continue;
      const [added, removed] = line.split("\t");
      // Handle binary files (shows as "-")
      if (added !== "-" && removed !== "-") {
        totalLoc += parseInt(added, 10) + parseInt(removed, 10);
      }
    }
    return totalLoc;
  } catch {
    return 0;
  }
}

export const command: Command = {
  category: "util",
  name: "size",
  args: "[threshold] [--all]",
  help: "Check .ts LOC changes per branch (default: 150, current tree only)",
  run(args: string[]) {
    const { values, positionals } = parseArgs(args, {
      all: { type: "boolean", short: "a" },
    });
    const threshold = positionals[0] ? parseInt(positionals[0], 10) : DEFAULT_THRESHOLD;

    if (isNaN(threshold) || threshold <= 0) {
      console.error("Threshold must be a positive number");
      process.exit(1);
    }

    const stack = loadStack();
    const branch = currentBranch();

    if (Object.keys(stack).length === 0) {
      console.log("No branches tracked");
      return;
    }

    // Filter to current tree unless --all is specified
    const treeBranches = branch && !values.all ? getTreeBranches(stack, branch) : null;

    const stats: BranchStats[] = [];

    for (const [child, parent] of Object.entries(stack)) {
      if (treeBranches && !treeBranches.has(child)) continue;
      const loc = getTsLoc(parent, child);
      stats.push({ branch: child, parent, loc, exceeds: loc > threshold });
    }

    // Build tree for display
    const allParents = new Set(stats.map((s) => s.parent));
    const allChildren = new Set(stats.map((s) => s.branch));
    const roots = treeBranches
      ? [getRoot(stack, branch!)]
      : [...allParents].filter((p) => !allChildren.has(p));

    const statsMap = new Map(stats.map((s) => [s.branch, s]));

    function printTree(b: string, indent: string) {
      const stat = statsMap.get(b);
      const marker = b === branch ? " <-- you" : "";

      if (stat) {
        const flag = stat.exceeds ? " ⚠" : " ✓";
        const locStr = `(${stat.loc} LOC)`;
        console.log(`${indent}${b}${marker} ${locStr}${flag}`);
      } else {
        console.log(`${indent}${b}${marker}`);
      }

      // Get children
      const children = getChildren(stack, b);
      for (const child of children) {
        printTree(child, indent + "  ");
      }
    }

    console.log(`Threshold: ${threshold} LOC\n`);

    for (const root of roots) {
      printTree(root, "");
    }

    const exceeding = stats.filter((s) => s.exceeds);
    if (exceeding.length > 0) {
      console.log(`\n⚠ ${exceeding.length} branch(es) exceed ${threshold} LOC:`);
      for (const { branch: b, loc } of exceeding) {
        console.log(`  ${b}: ${loc} LOC`);
      }
    } else {
      console.log(`\n✓ All branches under ${threshold} LOC`);
    }
  },
};
