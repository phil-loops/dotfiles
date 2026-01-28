import { execSync } from "child_process";

function git(cmd: string): string {
  try {
    return execSync(`git ${cmd}`, { encoding: "utf-8" }).trim();
  } catch {
    return "";
  }
}

interface Hunk {
  file: string;
  startLine: number;
  lineCount: number;
  header: string;
  content: string;
  targetBranch: string | null;
  confidence: "high" | "medium" | "low";
  reason: string;
}

interface StackBranch {
  name: string;
  parent: string;
  commits: Set<string>;
}

function getStackBranches(prefix?: string): StackBranch[] {
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

  // Sort by chain from main
  const sorted: StackBranch[] = [];
  const remaining = [...branches];
  let current = "main";

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

function parseDiff(diff: string): Hunk[] {
  const hunks: Hunk[] = [];
  let currentFile = "";
  let currentHunk: Partial<Hunk> | null = null;

  for (const line of diff.split("\n")) {
    // New file
    if (line.startsWith("diff --git")) {
      const match = line.match(/diff --git a\/(.+) b\//);
      if (match) currentFile = match[1];
      continue;
    }

    // Hunk header: @@ -oldStart,oldCount +newStart,newCount @@
    if (line.startsWith("@@")) {
      if (currentHunk && currentHunk.file) {
        hunks.push(currentHunk as Hunk);
      }

      const match = line.match(/@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@/);
      if (match) {
        currentHunk = {
          file: currentFile,
          startLine: parseInt(match[1]),
          lineCount: parseInt(match[2] || "1"),
          header: line,
          content: line + "\n",
          targetBranch: null,
          confidence: "low",
          reason: "",
        };
      }
      continue;
    }

    // Accumulate hunk content
    if (currentHunk && (line.startsWith("+") || line.startsWith("-") || line.startsWith(" "))) {
      currentHunk.content += line + "\n";
    }
  }

  // Don't forget last hunk
  if (currentHunk && currentHunk.file) {
    hunks.push(currentHunk as Hunk);
  }

  return hunks;
}

function findHunkTarget(hunk: Hunk, stack: StackBranch[]): void {
  // Use git blame to find which commits introduced the lines we're modifying
  const blameOutput = git(
    `blame -L ${hunk.startLine},${hunk.startLine + hunk.lineCount} --porcelain "${hunk.file}" 2>/dev/null`
  );

  if (!blameOutput) {
    // File might be new or lines are all additions
    // Check which branch introduced the file
    const fileIntroCommit = git(`log --diff-filter=A --format=%H -- "${hunk.file}" | head -1`);
    if (fileIntroCommit) {
      for (const branch of stack) {
        if (branch.commits.has(fileIntroCommit)) {
          hunk.targetBranch = branch.name;
          hunk.confidence = "high";
          hunk.reason = `File introduced in this branch`;
          return;
        }
      }
    }
    hunk.reason = "Could not determine origin (new file or new lines)";
    return;
  }

  // Parse blame output to get commit hashes
  const commitCounts = new Map<string, number>();
  for (const line of blameOutput.split("\n")) {
    const match = line.match(/^([a-f0-9]{40})/);
    if (match && !match[1].startsWith("0000000")) {
      commitCounts.set(match[1], (commitCounts.get(match[1]) || 0) + 1);
    }
  }

  // Find which branch owns the most blamed commits
  const branchCounts = new Map<string, number>();
  for (const [commit, count] of commitCounts) {
    for (const branch of stack) {
      if (branch.commits.has(commit)) {
        branchCounts.set(branch.name, (branchCounts.get(branch.name) || 0) + count);
        break;
      }
    }
  }

  if (branchCounts.size === 0) {
    hunk.reason = "Lines originated before the stack (main or earlier)";
    return;
  }

  // Pick branch with most ownership
  let maxBranch = "";
  let maxCount = 0;
  let totalCount = 0;
  for (const [branch, count] of branchCounts) {
    totalCount += count;
    if (count > maxCount) {
      maxCount = count;
      maxBranch = branch;
    }
  }

  hunk.targetBranch = maxBranch;
  const ownership = Math.round((maxCount / totalCount) * 100);

  if (ownership >= 80) {
    hunk.confidence = "high";
  } else if (ownership >= 50) {
    hunk.confidence = "medium";
  } else {
    hunk.confidence = "low";
  }

  hunk.reason = `${ownership}% of modified lines from this branch`;
}

function groupByBranch(hunks: Hunk[]): Map<string, Hunk[]> {
  const groups = new Map<string, Hunk[]>();
  for (const hunk of hunks) {
    const key = hunk.targetBranch || "(unknown)";
    if (!groups.has(key)) groups.set(key, []);
    groups.get(key)!.push(hunk);
  }
  return groups;
}

function printResults(groups: Map<string, Hunk[]>, stack: StackBranch[]) {
  const stackOrder = new Map(stack.map((b, i) => [b.name, i]));

  // Sort groups by stack order
  const sortedGroups = [...groups.entries()].sort((a, b) => {
    const orderA = stackOrder.get(a[0]) ?? 999;
    const orderB = stackOrder.get(b[0]) ?? 999;
    return orderA - orderB;
  });

  console.log("\n=== Injection Analysis ===\n");

  for (const [branch, hunks] of sortedGroups) {
    const branchNum = stackOrder.get(branch);
    const label = branchNum !== undefined ? `[${String(branchNum + 1).padStart(2, "0")}]` : "[??]";

    console.log(`${label} ${branch}`);
    console.log("─".repeat(60));

    for (const hunk of hunks) {
      const conf =
        hunk.confidence === "high" ? "●" : hunk.confidence === "medium" ? "◐" : "○";
      console.log(`  ${conf} ${hunk.file}:${hunk.startLine} (${hunk.reason})`);

      // Show first few lines of the hunk
      const preview = hunk.content
        .split("\n")
        .slice(0, 6)
        .map((l) => `      ${l}`)
        .join("\n");
      console.log(preview);
      if (hunk.content.split("\n").length > 6) {
        console.log(`      ... (${hunk.content.split("\n").length - 6} more lines)`);
      }
      console.log();
    }
  }

  // Print suggested workflow
  console.log("\n=== Suggested Workflow ===\n");

  const branchesNeeded = sortedGroups
    .filter(([b]) => b !== "(unknown)")
    .map(([b]) => b);

  if (branchesNeeded.length === 0) {
    console.log("No clear injection targets found. Changes may need manual review.");
    return;
  }

  console.log("1. Stash your changes:");
  console.log("   git stash -u\n");

  for (let i = 0; i < branchesNeeded.length; i++) {
    const branch = branchesNeeded[i];
    const num = i + 2;
    console.log(`${num}. Inject into ${branch}:`);
    console.log(`   git checkout ${branch}`);
    console.log(`   git stash pop`);
    console.log(`   # Stage only hunks for this branch, then:`);
    console.log(`   git add -p  # select relevant hunks`);
    console.log(`   git commit --amend --no-edit`);
    console.log(`   git stash -u  # re-stash remaining changes`);
    console.log();
  }

  const lastBranch = branchesNeeded[branchesNeeded.length - 1];
  console.log(`${branchesNeeded.length + 2}. Rebase downstream branches:`);
  console.log(`   git town sync  # or manually rebase each branch`);
  console.log();

  console.log("Legend: ● high confidence  ◐ medium  ○ low");
}

export function inject(args: string[]) {
  const prefix = args.find((a) => !a.startsWith("-"));
  const useStaged = args.includes("--staged");

  console.log("Analyzing changes for injection points...");
  if (prefix) console.log(`Stack prefix: ${prefix}`);

  // Get the stack
  const stack = getStackBranches(prefix);
  if (stack.length === 0) {
    console.error("No stack branches found. Make sure git-town parents are configured.");
    process.exit(1);
  }

  console.log(`Found ${stack.length} branches in stack`);

  // Get diff (uncommitted changes)
  const diffCmd = useStaged ? "diff --cached" : "diff";
  let diff = git(diffCmd);

  if (!diff) {
    // Try diff against parent branch
    const currentBranch = git("branch --show-current");
    const parent = git(`config git-town-branch.${currentBranch}.parent`);
    if (parent) {
      console.log(`No uncommitted changes. Comparing ${currentBranch} to parent ${parent}...`);
      diff = git(`diff ${parent}..${currentBranch}`);
    }
  }

  if (!diff) {
    console.log("No changes to analyze.");
    process.exit(0);
  }

  // Parse diff into hunks
  const hunks = parseDiff(diff);
  console.log(`Found ${hunks.length} hunks to analyze`);

  // Analyze each hunk
  for (const hunk of hunks) {
    process.stdout.write(`  Analyzing ${hunk.file}:${hunk.startLine}...`);
    findHunkTarget(hunk, stack);
    console.log(` -> ${hunk.targetBranch || "(unknown)"}`);
  }

  // Group and display
  const groups = groupByBranch(hunks);
  printResults(groups, stack);
}
