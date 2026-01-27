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

// ============ File filter ============

type FileFilter = { includeTsx: boolean; includeTests: boolean };

function matchesFilter(file: string, filter: FileFilter): boolean {
  if (!file.endsWith(".ts") && !file.endsWith(".tsx")) return false;
  if (file.endsWith(".tsx") && !filter.includeTsx) return false;
  if (file.endsWith(".test.ts") && !filter.includeTests) return false;
  if (file.endsWith(".test.tsx") && !filter.includeTests) return false;
  return true;
}

// ============ Size helpers ============

function getTsLoc(parent: string, child: string, filter: FileFilter): number {
  try {
    let pathSpec = `-- "*.ts"`;
    if (filter.includeTsx) {
      pathSpec = `-- "*.ts" "*.tsx"`;
    }
    if (!filter.includeTests) {
      pathSpec += ` ":!*.test.ts" ":!*.test.tsx"`;
    }
    if (!filter.includeTsx) {
      pathSpec += ` ":!*.tsx"`;
    }

    const diffOutput = git(`diff --numstat ${parent}...${child} ${pathSpec}`);
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

// ============ Churn helpers ============

// Check if a file diff has deletions (churn) vs just additions (acceptable growth)
function hasMinusLines(parent: string, child: string, file: string): boolean {
  try {
    const diff = git(`diff ${parent}...${child} -- "${file}"`);
    return diff.split("\n").some((l) => l.startsWith("-") && !l.startsWith("---"));
  } catch {
    return false;
  }
}

type ChurnInfo = { file: string; introducedIn: string; churnedIn: string[] };
type BranchChurnInfo = {
  fileChurns: ChurnInfo[];
  // Per-branch: how many files from this branch have churn (deletions) downstream
  branchHealth: Map<string, { clean: boolean; churnedFiles: number; churnedFileList: string[]; totalFiles: number }>;
};

function getChurns(orderedBranches: string[], stack: Record<string, string>, filter: FileFilter): BranchChurnInfo {
  const fileIntroducedIn = new Map<string, string>();
  const fileChurns: ChurnInfo[] = [];
  const filesPerBranch = new Map<string, Set<string>>();

  // First pass: track which files each branch introduces
  for (let i = 1; i < orderedBranches.length; i++) {
    const parent = orderedBranches[i - 1];
    const child = orderedBranches[i];

    try {
      const diffOutput = git(`diff --name-only ${parent}...${child}`);
      if (!diffOutput) continue;

      const files = diffOutput.split("\n").filter((f) => matchesFilter(f, filter));

      for (const file of files) {
        if (!fileIntroducedIn.has(file)) {
          fileIntroducedIn.set(file, child);
          if (!filesPerBranch.has(child)) {
            filesPerBranch.set(child, new Set());
          }
          filesPerBranch.get(child)!.add(file);
        } else {
          // Only count as churn if there are deletions (not just additions)
          if (hasMinusLines(parent, child, file)) {
            const introducedIn = fileIntroducedIn.get(file)!;
            let churn = fileChurns.find((c) => c.file === file);
            if (!churn) {
              churn = { file, introducedIn, churnedIn: [] };
              fileChurns.push(churn);
            }
            churn.churnedIn.push(child);
          }
        }
      }
    } catch {
      // skip
    }
  }

  // Second pass: compute per-branch health
  const branchHealth = new Map<string, { clean: boolean; churnedFiles: number; churnedFileList: string[]; totalFiles: number }>();

  for (const branch of orderedBranches) {
    const files = filesPerBranch.get(branch) || new Set();
    const churnedFilesInfo = fileChurns.filter((c) => c.introducedIn === branch);
    branchHealth.set(branch, {
      clean: churnedFilesInfo.length === 0,
      churnedFiles: churnedFilesInfo.length,
      churnedFileList: churnedFilesInfo.map((c) => c.file),
      totalFiles: files.size,
    });
  }

  return { fileChurns, branchHealth };
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
  args: "[-s|--size] [-u|--churn] [-c|--conflicts] [-p|--plan] [--tsx] [--tests]",
  help: "Show stack info (flags: size, churn, conflicts, plan, tsx, tests)",
  run(args: string[]) {
    const { values } = parseArgs(args, {
      size: { type: "boolean", short: "s" },
      churn: { type: "boolean", short: "u" },
      conflicts: { type: "boolean", short: "c" },
      plan: { type: "boolean", short: "p" },
      all: { type: "boolean", short: "a" },
      tsx: { type: "boolean" },
      tests: { type: "boolean" },
    });

    const fileFilter = {
      includeTsx: values.tsx || false,
      includeTests: values.tests || false,
    };

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
    const showOverview = !values.size && !values.churn && !values.conflicts && !values.plan;

    // Gather data based on flags
    const sizeData = (values.size || showOverview) ? new Map<string, number>() : null;
    const churnResult = (values.churn || showOverview) ? getChurns(orderedBranches, stack, fileFilter) : null;
    const conflictData = (values.conflicts || showOverview) ? getConflicts(stack, currentStackBranches) : null;

    if (sizeData) {
      for (const b of currentStackBranches) {
        const parent = stack[b];
        if (parent) {
          sizeData.set(b, getTsLoc(parent, b, fileFilter));
        }
      }
    }

    // Print stack with annotations
    console.log();
    printTree(root, "", "", stack, branch, currentStackBranches, sizeData, churnResult?.branchHealth || null, conflictData, showOverview);

    // Size summary
    if (values.size || showOverview) {
      const threshold = 150;
      const exceeding = [...(sizeData?.entries() || [])].filter(([_, loc]) => loc > threshold);
      if (exceeding.length > 0) {
        console.log(`\n${exceeding.length} branch(es) exceed ${threshold} LOC`);
      }
    }

    // Churn details
    if (values.churn && churnResult && churnResult.fileChurns.length > 0) {
      console.log(`\nChurned files (${churnResult.fileChurns.length}):\n`);
      for (const { file, introducedIn, churnedIn } of churnResult.fileChurns) {
        console.log(`  ${file}`);
        console.log(`    added: ${introducedIn} -> churned: ${churnedIn.join(", ")}`);
      }
    } else if (showOverview && churnResult && churnResult.fileChurns.length > 0) {
      console.log(`\n${churnResult.fileChurns.length} file(s) churned (use -u for details)`);
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

type BranchHealth = { clean: boolean; churnedFiles: number; churnedFileList: string[]; totalFiles: number };

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

  // Health indicator: ✅ only if no churn AND not large
  const health = branchHealth?.get(b);
  const loc = sizeData?.get(b) || 0;
  const hasChurn = health && health.churnedFiles > 0;
  const isLarge = loc > 150;
  const isClean = !hasChurn && !isLarge;

  if (isClean && loc > 0) {
    annotations.push(`✅ ${loc}`);
  } else {
    if (hasChurn) {
      annotations.push(`⚠️${health!.churnedFiles}`);
    }
    if (isLarge) {
      annotations.push(`🔴${loc}`);
    } else if (loc > 0 && hasChurn) {
      // Show LOC after churn indicator if not large
      annotations.push(`${loc}`);
    }
  }

  if (conflictData?.find((c) => c.child === b)) {
    annotations.push("💥");
  }

  const suffix = annotations.length > 0 ? ` (${annotations.join(" ")})` : "";

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

  // Print churned files inline
  if (showOverview && health && health.churnedFileList.length > 0) {
    const churnIndent = contentPrefix + (children.length > 0 ? "│  " : "   ");
    const maxFiles = 3;
    const fileNames = health.churnedFileList.slice(0, maxFiles).map((f) => f.split("/").pop());
    let churnLine = `↳ churn: ${fileNames.join(", ")}`;
    if (health.churnedFileList.length > maxFiles) {
      churnLine += ` + ${health.churnedFileList.length - maxFiles} more`;
    }
    console.log(`${churnIndent}${churnLine}`);
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
