import type { Command } from "../types.ts";
import { parseArgs } from "../args.ts";
import { currentBranch, git, loadStack, findRoot, getCurrentStack } from "../lib.ts";

type FileAnalysis = {
  file: string;
  introducedIn: string | null;
  lastModifiedIn: string | null;
  recommendedBranch: string;
};

function analyzeFile(file: string, stackBranches: string[], current: string): FileAnalysis {
  let introducedIn: string | null = null;
  let lastModifiedIn: string | null = null;

  // Check if file was added in a stack branch
  try {
    const addCommit = git(`log --oneline --all --diff-filter=A -- "${file}"`).split("\n")[0];
    if (addCommit) {
      const hash = addCommit.split(" ")[0];
      const branch = git(`name-rev --name-only ${hash}`).trim().replace(/~\d+$/, "").replace(/\^.*$/, "");
      if (branch.startsWith("goals-") || stackBranches.includes(branch)) {
        introducedIn = branch;
      }
    }
  } catch {}

  // Check last modification in stack
  try {
    const lastMod = git(`log --oneline main..HEAD -- "${file}"`).split("\n")[0];
    if (lastMod) {
      const hash = lastMod.split(" ")[0];
      const branch = git(`name-rev --name-only ${hash}`).trim().replace(/~\d+$/, "").replace(/\^.*$/, "");
      if (stackBranches.includes(branch)) {
        lastModifiedIn = branch;
      }
    }
  } catch {}

  // Determine recommended branch
  let recommendedBranch = current;
  if (introducedIn && stackBranches.includes(introducedIn)) {
    recommendedBranch = introducedIn;
  } else if (lastModifiedIn) {
    recommendedBranch = lastModifiedIn;
  }

  return { file, introducedIn, lastModifiedIn, recommendedBranch };
}

export const command: Command = {
  category: "util",
  name: "inject",
  args: "[--apply]",
  help: "Analyze where uncommitted changes should land in the stack",
  run(args: string[]) {
    const { values } = parseArgs(args, {
      apply: { type: "boolean" },
    });

    // Get uncommitted changes
    const changedFiles = git("diff --name-only").trim();
    if (!changedFiles) {
      console.log("No uncommitted changes found.");
      return;
    }

    const files = changedFiles.split("\n").filter(Boolean);
    const current = currentBranch();
    const stack = loadStack();

    if (Object.keys(stack).length === 0) {
      console.log("No stack found. Just commit here.");
      return;
    }

    const stackBranches = getCurrentStack(stack, current);
    const root = findRoot(stack, current);
    const allBranches = [root, ...stackBranches];

    console.log("\n\x1b[34m━━━ Stack Injection Analysis ━━━\x1b[0m\n");
    console.log(`\x1b[33mCurrent:\x1b[0m ${current}`);
    console.log(`\x1b[33mFiles:\x1b[0m ${files.length} changed\n`);

    // Analyze each file
    const analyses = files.map(f => analyzeFile(f, allBranches, current));

    // Group by recommended branch
    const groups = new Map<string, string[]>();
    for (const a of analyses) {
      if (!groups.has(a.recommendedBranch)) {
        groups.set(a.recommendedBranch, []);
      }
      groups.get(a.recommendedBranch)!.push(a.file);
    }

    console.log("\x1b[34m━━━ Recommended Injection Points ━━━\x1b[0m\n");

    const sortedBranches = [...groups.keys()].sort((a, b) => {
      const aIdx = allBranches.indexOf(a);
      const bIdx = allBranches.indexOf(b);
      return aIdx - bIdx;
    });

    for (const branch of sortedBranches) {
      const branchFiles = groups.get(branch)!;
      const isCurrent = branch === current;
      const color = isCurrent ? "\x1b[32m" : "\x1b[36m";
      const marker = isCurrent ? "●" : "○";
      const suffix = isCurrent ? " (current)" : "";

      console.log(`${color}${marker} ${branch}\x1b[0m${suffix} - ${branchFiles.length} file(s)`);
      for (const f of branchFiles) {
        console.log(`    ${f}`);
      }
      console.log();
    }

    // Strategy recommendation
    console.log("\x1b[34m━━━ Strategy ━━━\x1b[0m\n");

    const branchCount = groups.size;
    if (branchCount === 1) {
      console.log("\x1b[32m✓ All changes belong on current branch\x1b[0m");
      console.log("  Just commit here.");
    } else if (branchCount === 2) {
      console.log("\x1b[33m⚡ Split across 2 branches\x1b[0m");
      const other = sortedBranches.find(b => b !== current)!;
      const otherFiles = groups.get(other)!;
      console.log(`\n  To move ${otherFiles.length} file(s) to ${other}:\n`);
      console.log(`  1. git stash push -m "for ${other}" -- \\`);
      for (const f of otherFiles) {
        console.log(`       "${f}" \\`);
      }
      console.log(`  2. Commit remaining changes here`);
      console.log(`  3. loops stack edit ${other}`);
      console.log(`  4. git stash pop && git add -A && git commit`);
      console.log(`  5. loops stack return`);
    } else {
      console.log(`\x1b[31m⚠ Split across ${branchCount} branches\x1b[0m`);
      console.log("  High complexity. Consider keeping all on current branch");
      console.log("  unless PR cleanliness is critical.");
    }

    console.log();
    console.log("\x1b[33mTip:\x1b[0m Use 'loops stack edit <branch>' to modify earlier branches");
    console.log();
  },
};
