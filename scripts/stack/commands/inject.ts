import type { Command } from "../types.ts";
import { parseArgs } from "../args.ts";
import {
  currentBranch,
  git,
  loadStack,
  findRoot,
  getCurrentStack,
  getDrifts,
  defaultFileFilter,
  type DriftInfo,
} from "../lib.ts";

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
      if (stackBranches.includes(branch)) {
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

function printUncommittedAnalysis(files: string[], allBranches: string[], current: string) {
  console.log("\x1b[34m━━━ Uncommitted Changes ━━━\x1b[0m\n");
  console.log(`\x1b[33mFiles:\x1b[0m ${files.length} changed\n`);

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
  if (branchCount === 1 && groups.has(current)) {
    console.log("\x1b[32m✓ All changes belong on current branch\x1b[0m");
    console.log("  Just commit here.");
  } else if (branchCount === 1) {
    const targetBranch = sortedBranches[0];
    const targetFiles = groups.get(targetBranch)!;
    console.log(`\x1b[33m⚡ All changes belong on ${targetBranch}\x1b[0m\n`);
    console.log(`  1. git stash push -m "for ${targetBranch}"`);
    console.log(`  2. loops stack edit ${targetBranch}`);
    console.log(`  3. git stash pop && git add -A && git commit`);
    console.log(`  4. loops stack return`);
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
    console.log("  unless PR cleanliness is critical.\n");

    // Still show the commands for each branch
    for (const branch of sortedBranches) {
      if (branch === current) continue;
      const branchFiles = groups.get(branch)!;
      console.log(`  For ${branch}:`);
      console.log(`    git stash push -m "for ${branch}" -- ${branchFiles.map(f => `"${f}"`).join(" ")}`);
    }
  }
}

function printDriftAnalysis(drifts: DriftInfo[], allBranches: string[], stack: Record<string, string>) {
  console.log("\x1b[34m━━━ Committed Drift ━━━\x1b[0m\n");

  if (drifts.length === 0) {
    console.log("\x1b[32m✓ No drift detected\x1b[0m");
    return;
  }

  console.log(`\x1b[33mDrifted files:\x1b[0m ${drifts.length}\n`);

  for (const drift of drifts) {
    const { file, introducedIn, modifiedIn } = drift;
    console.log(`\x1b[36m${file}\x1b[0m`);
    console.log(`  Added in:    ${introducedIn}`);
    console.log(`  Modified in: ${modifiedIn.join(" → ")}`);
    console.log();
  }

  console.log("\x1b[34m━━━ Fix Strategy ━━━\x1b[0m\n");

  // Group drifts by where they should be fixed (introducedIn branch)
  const fixGroups = new Map<string, DriftInfo[]>();
  for (const drift of drifts) {
    if (!fixGroups.has(drift.introducedIn)) {
      fixGroups.set(drift.introducedIn, []);
    }
    fixGroups.get(drift.introducedIn)!.push(drift);
  }

  const sortedFixBranches = [...fixGroups.keys()].sort((a, b) => {
    const aIdx = allBranches.indexOf(a);
    const bIdx = allBranches.indexOf(b);
    return aIdx - bIdx;
  });

  for (const branch of sortedFixBranches) {
    const branchDrifts = fixGroups.get(branch)!;
    console.log(`\x1b[33mTo fix drift in ${branch}:\x1b[0m\n`);

    for (const drift of branchDrifts) {
      const lastModified = drift.modifiedIn[drift.modifiedIn.length - 1];
      console.log(`  # ${drift.file}`);
      console.log(`  # Extract changes from ${lastModified} back to ${branch}`);
      console.log(`  loops stack edit ${branch}`);
      console.log(`  git checkout ${lastModified} -- "${drift.file}"`);
      console.log(`  git add "${drift.file}" && git commit --amend --no-edit`);
      console.log(`  loops stack return`);
      console.log();
    }
  }

  console.log("\x1b[33mNote:\x1b[0m Fixing drift may cause conflicts. Review changes carefully.");
}

export const command: Command = {
  category: "util",
  name: "inject",
  args: "[--drift] [--all]",
  help: "Analyze where changes should land (uncommitted or --drift for committed)",
  run(args: string[]) {
    const { values } = parseArgs(args, {
      drift: { type: "boolean", short: "d" },
      all: { type: "boolean", short: "a" },
    });

    const current = currentBranch();
    const stack = loadStack();

    if (Object.keys(stack).length === 0) {
      console.log("No stack found.");
      return;
    }

    const stackBranches = getCurrentStack(stack, current);
    const root = findRoot(stack, current);
    const allBranches = [root, ...stackBranches];

    console.log("\n\x1b[34m━━━ Stack Injection Analysis ━━━\x1b[0m\n");
    console.log(`\x1b[33mCurrent:\x1b[0m ${current}`);
    console.log(`\x1b[33mStack:\x1b[0m ${allBranches.length} branches\n`);

    const showUncommitted = !values.drift || values.all;
    const showDrift = values.drift || values.all;

    // Uncommitted changes analysis
    const changedFiles = git("diff --name-only").trim();
    if (showUncommitted && changedFiles) {
      const files = changedFiles.split("\n").filter(Boolean);
      printUncommittedAnalysis(files, allBranches, current);
    } else if (!showDrift && !changedFiles) {
      console.log("No uncommitted changes found.");
      console.log("Use --drift to analyze committed drift instead.\n");
      return;
    }

    // Committed drift analysis
    if (showDrift) {
      if (changedFiles) {
        console.log("\n");
      }
      const { fileDrifts } = getDrifts(allBranches, stack, defaultFileFilter);
      printDriftAnalysis(fileDrifts, allBranches, stack);
    }

    console.log();
  },
};
