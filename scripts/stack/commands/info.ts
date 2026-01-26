import type { Command } from "../types.ts";
import { parseArgs } from "../args.ts";
import {
  checkConflict,
  currentBranch,
  extractKeyChangeNames,
  findRoot,
  getChainFromRoot,
  getChildren,
  getCurrentStack,
  git,
  loadStack,
} from "../lib.ts";

// ============ Size helpers ============

function getTsLoc(parent: string, child: string): number {
  try {
    const diffOutput = git(
      `diff --numstat ${parent}...${child} -- "*.ts" ":!*.tsx" ":!*.test.ts"`
    );
    if (!diffOutput.trim()) return 0;

    let totalLoc = 0;
    for (const line of diffOutput.split("\n")) {
      if (!line.trim()) continue;
      const [added, removed] = line.split("\t");
      if (added !== "-" && removed !== "-") {
        totalLoc += parseInt(added, 10) + parseInt(removed, 10);
      }
    }
    return totalLoc;
  } catch {
    return 0;
  }
}

// ============ Drift helpers ============

type DriftInfo = { file: string; introducedIn: string; modifiedIn: string[] };
type BranchDriftInfo = {
  fileDrifts: DriftInfo[];
  // Per-branch: how many files from this branch are edited downstream
  branchHealth: Map<string, { clean: boolean; driftedFiles: number; totalFiles: number }>;
};

function getDrifts(orderedBranches: string[], stack: Record<string, string>): BranchDriftInfo {
  const fileIntroducedIn = new Map<string, string>();
  const fileDrifts: DriftInfo[] = [];
  const filesPerBranch = new Map<string, Set<string>>();

  // First pass: track which files each branch introduces
  for (let i = 1; i < orderedBranches.length; i++) {
    const parent = orderedBranches[i - 1];
    const child = orderedBranches[i];

    try {
      const diffOutput = git(`diff --name-only ${parent}...${child}`);
      if (!diffOutput) continue;

      const files = diffOutput.split("\n").filter((f) => {
        return f.endsWith(".ts") && !f.endsWith(".test.ts") && !f.endsWith(".tsx");
      });

      for (const file of files) {
        if (!fileIntroducedIn.has(file)) {
          fileIntroducedIn.set(file, child);
          if (!filesPerBranch.has(child)) {
            filesPerBranch.set(child, new Set());
          }
          filesPerBranch.get(child)!.add(file);
        } else {
          const introducedIn = fileIntroducedIn.get(file)!;
          let drift = fileDrifts.find((d) => d.file === file);
          if (!drift) {
            drift = { file, introducedIn, modifiedIn: [] };
            fileDrifts.push(drift);
          }
          drift.modifiedIn.push(child);
        }
      }
    } catch {
      // skip
    }
  }

  // Second pass: compute per-branch health
  const branchHealth = new Map<string, { clean: boolean; driftedFiles: number; totalFiles: number }>();

  for (const branch of orderedBranches) {
    const files = filesPerBranch.get(branch) || new Set();
    const driftedFiles = fileDrifts.filter((d) => d.introducedIn === branch).length;
    branchHealth.set(branch, {
      clean: driftedFiles === 0,
      driftedFiles,
      totalFiles: files.size,
    });
  }

  return { fileDrifts, branchHealth };
}

// ============ Conflicts helpers ============

type ConflictInfo = { child: string; parent: string; files: string[] };

function getConflicts(stack: Record<string, string>, branches: string[]): ConflictInfo[] {
  const conflicts: ConflictInfo[] = [];
  const branchSet = new Set(branches);

  for (const child of branches) {
    const parent = stack[child];
    if (!parent) continue;
    const result = checkConflict(parent, child);
    if (result.hasConflict) {
      conflicts.push({ child, parent, files: result.files });
    }
  }

  return conflicts;
}

// ============ Main command ============

export const command: Command = {
  category: "util",
  name: "info",
  args: "[-s|--size] [-d|--drift] [-c|--conflicts] [-p|--plan]",
  help: "Show stack info (flags: size, drift, conflicts, plan)",
  run(args: string[]) {
    const { values } = parseArgs(args, {
      size: { type: "boolean", short: "s" },
      drift: { type: "boolean", short: "d" },
      conflicts: { type: "boolean", short: "c" },
      plan: { type: "boolean", short: "p" },
      all: { type: "boolean", short: "a" },
    });

    const stack = loadStack();
    const branch = currentBranch();

    if (Object.keys(stack).length === 0) {
      console.log("No branches tracked");
      return;
    }

    const currentStackBranches = getCurrentStack(stack, branch);
    if (currentStackBranches.length === 0) {
      console.log("Current branch is not in a tracked stack");
      return;
    }

    const root = findRoot(stack, branch);
    const orderedBranches = [root, ...currentStackBranches];

    // If no flags, show overview
    const showOverview = !values.size && !values.drift && !values.conflicts && !values.plan;

    // Gather data based on flags
    const sizeData = (values.size || showOverview) ? new Map<string, number>() : null;
    const driftResult = (values.drift || showOverview) ? getDrifts(orderedBranches, stack) : null;
    const conflictData = (values.conflicts || showOverview) ? getConflicts(stack, currentStackBranches) : null;

    if (sizeData) {
      for (const b of currentStackBranches) {
        const parent = stack[b];
        if (parent) {
          sizeData.set(b, getTsLoc(parent, b));
        }
      }
    }

    // Print tree with annotations
    console.log();
    printTree(root, "", "", stack, branch, currentStackBranches, sizeData, driftResult?.branchHealth || null, conflictData, showOverview);

    // Size summary
    if (values.size || showOverview) {
      const threshold = 150;
      const exceeding = [...(sizeData?.entries() || [])].filter(([_, loc]) => loc > threshold);
      if (exceeding.length > 0) {
        console.log(`\n${exceeding.length} branch(es) exceed ${threshold} LOC`);
      }
    }

    // Drift details
    if (values.drift && driftResult && driftResult.fileDrifts.length > 0) {
      console.log(`\nDrifted files (${driftResult.fileDrifts.length}):\n`);
      for (const { file, introducedIn, modifiedIn } of driftResult.fileDrifts) {
        console.log(`  ${file}`);
        console.log(`    added: ${introducedIn} -> modified: ${modifiedIn.join(", ")}`);
      }
    } else if (showOverview && driftResult && driftResult.fileDrifts.length > 0) {
      console.log(`\n${driftResult.fileDrifts.length} file(s) drifted (use -d for details)`);
    }

    // Conflict details
    if (values.conflicts && conflictData && conflictData.length > 0) {
      console.log(`\nConflicts:\n`);
      for (const { child, parent, files } of conflictData) {
        console.log(`  ${child} onto ${parent}:`);
        for (const file of files) {
          console.log(`    - ${file}`);
        }
      }
    } else if (showOverview && conflictData && conflictData.length > 0) {
      console.log(`\n${conflictData.length} conflict(s) detected (use -c for details)`);
    } else if ((values.conflicts || showOverview) && conflictData?.length === 0) {
      console.log(`\nNo conflicts`);
    }

    // Plan output
    if (values.plan) {
      printPlan(stack, branch, root, currentStackBranches);
    }

    console.log();
  },
};

type BranchHealth = { clean: boolean; driftedFiles: number; totalFiles: number };

function printTree(
  b: string,
  linePrefix: string,
  contentPrefix: string,
  stack: Record<string, string>,
  currentBranch: string,
  stackBranches: string[],
  sizeData: Map<string, number> | null,
  branchHealth: Map<string, BranchHealth> | null,
  conflictData: ConflictInfo[] | null,
  showOverview: boolean
) {
  const marker = b === currentBranch ? " <-- you" : "";
  const children = getChildren(stack, b).filter((c) => stackBranches.includes(c));

  let annotations: string[] = [];

  // Health indicator: ✓ for clean, ~N for drifted files
  const health = branchHealth?.get(b);
  if (health && health.totalFiles > 0) {
    if (health.clean) {
      annotations.push("✓");
    } else {
      annotations.push(`~${health.driftedFiles}`);
    }
  }

  if (sizeData?.has(b)) {
    const loc = sizeData.get(b)!;
    const flag = loc > 150 ? "!" : "";
    annotations.push(`${loc}${flag}`);
  }

  if (conflictData?.find((c) => c.child === b)) {
    annotations.push("conflict");
  }

  const suffix = annotations.length > 0 ? ` (${annotations.join(", ")})` : "";

  // Get key changes for overview
  let changes: string[] = [];
  if (showOverview && stack[b]) {
    try {
      const diff = git(`diff ${stack[b]}...${b} -U0`);
      changes = extractKeyChangeNames(diff).slice(0, 3);
    } catch {}
  }

  console.log(`${linePrefix}${b}${suffix}${marker}`);

  if (changes.length > 0) {
    const changeIndent = contentPrefix + (children.length > 0 ? "│  " : "   ");
    console.log(`${changeIndent}${changes.join(", ")}`);
  }

  children.forEach((child, i) => {
    const isLast = i === children.length - 1;
    const connector = isLast ? "└─ " : "├─ ";
    const nextContentPrefix = contentPrefix + (isLast ? "   " : "│  ");
    printTree(child, contentPrefix + connector, nextContentPrefix, stack, currentBranch, stackBranches, sizeData, branchHealth, conflictData, showOverview);
  });
}

function printPlan(
  stack: Record<string, string>,
  branch: string,
  root: string,
  branches: string[]
) {
  console.log(`\n─── PR Plan ───\n`);

  for (const b of branches) {
    const parent = stack[b];
    if (!parent) continue;

    try {
      const diffStat = git(`diff --stat ${parent}...${b}`);
      const statMatch = diffStat.match(/(\d+) insertions?\(\+\)/);
      const delMatch = diffStat.match(/(\d+) deletions?\(-\)/);
      const adds = statMatch ? parseInt(statMatch[1]) : 0;
      const dels = delMatch ? parseInt(delMatch[1]) : 0;
      const total = adds + dels;
      const warning = total > 200 ? " (large)" : "";

      console.log(`${b}: +${adds}/-${dels}${warning}`);
    } catch {
      console.log(`${b}: (no stats)`);
    }
  }
}
