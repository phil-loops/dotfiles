import type { Command } from "../types.ts";
import {
  currentBranch,
  getChildren,
  git,
  loadConvention,
  loadStack,
  getBranchesByPrefix,
  getConventionParent,
} from "../lib.ts";

const DEFAULT_THRESHOLD = 150;

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
  name: "size",
  args: "[threshold]",
  help: "Check .ts LOC changes per branch (default: 150)",
  run(args: string[]) {
    const threshold = args[0] ? parseInt(args[0], 10) : DEFAULT_THRESHOLD;

    if (isNaN(threshold) || threshold <= 0) {
      console.error("Threshold must be a positive number");
      process.exit(1);
    }

    const stack = loadStack();
    const convention = loadConvention();
    const branch = currentBranch();

    const stats: BranchStats[] = [];

    // Handle convention mode
    if (convention) {
      const branches = getBranchesByPrefix(convention.prefix);
      for (const b of branches) {
        const parent = getConventionParent(b, convention);
        if (parent) {
          const loc = getTsLoc(parent, b);
          stats.push({ branch: b, parent, loc, exceeds: loc > threshold });
        }
      }
    }

    // Handle explicit mode
    for (const [child, parent] of Object.entries(stack)) {
      // Skip if already handled by convention
      if (convention && child.startsWith(convention.prefix)) continue;

      const loc = getTsLoc(parent, child);
      stats.push({ branch: child, parent, loc, exceeds: loc > threshold });
    }

    if (stats.length === 0) {
      console.log("No branches tracked");
      return;
    }

    // Build tree for display
    const allParents = new Set([...stats.map((s) => s.parent)]);
    const allChildren = new Set(stats.map((s) => s.branch));
    const roots = [...allParents].filter((p) => !allChildren.has(p));

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

      // Get children from both stack and convention
      const children = new Set<string>();
      for (const s of stats) {
        if (s.parent === b) children.add(s.branch);
      }
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
