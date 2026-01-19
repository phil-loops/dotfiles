import { execSync } from "child_process";
import type { Command } from "../types.ts";
import { currentBranch, findRoot, getChainFromRoot, getChildren, git, loadStack } from "../lib.ts";

type BranchStats = {
  branch: string;
  parent: string | null;
  additions: number;
  deletions: number;
  filesChanged: string[];
  commits: number;
};

function getBranchStats(branch: string, parent: string | null): BranchStats {
  if (!parent) {
    return {
      branch,
      parent: null,
      additions: 0,
      deletions: 0,
      filesChanged: [],
      commits: 0,
    };
  }

  try {
    const diffStat = git(`diff --stat ${parent}...${branch}`);
    const files = git(`diff --name-only ${parent}...${branch}`).split("\n").filter(Boolean);

    let additions = 0;
    let deletions = 0;
    const statMatch = diffStat.match(/(\d+) insertions?\(\+\)/);
    const delMatch = diffStat.match(/(\d+) deletions?\(-\)/);
    if (statMatch) additions = parseInt(statMatch[1]);
    if (delMatch) deletions = parseInt(delMatch[1]);

    const commits = git(`rev-list --count ${parent}..${branch}`);

    return {
      branch,
      parent,
      additions,
      deletions,
      filesChanged: files,
      commits: parseInt(commits) || 0,
    };
  } catch {
    return {
      branch,
      parent,
      additions: 0,
      deletions: 0,
      filesChanged: [],
      commits: 0,
    };
  }
}

function getUncommittedChanges(): { staged: string[]; unstaged: string[] } {
  try {
    const staged = git("diff --cached --name-only").split("\n").filter(Boolean);
    const unstaged = git("diff --name-only").split("\n").filter(Boolean);
    return { staged, unstaged };
  } catch {
    return { staged: [], unstaged: [] };
  }
}

function getUntrackedBranches(): string[] {
  const stack = loadStack();
  const trackedBranches = new Set([...Object.keys(stack), ...Object.values(stack)]);

  try {
    const allBranches = git("branch --format='%(refname:short)'")
      .split("\n")
      .map((b) => b.replace(/'/g, "").trim())
      .filter(Boolean)
      .filter((b) => !b.startsWith("backup/"));

    return allBranches.filter((b) => !trackedBranches.has(b) && b !== "main" && b !== "master");
  } catch {
    return [];
  }
}

function findFileOverlaps(stats: BranchStats[]): Map<string, string[]> {
  const fileMap = new Map<string, string[]>();

  for (const stat of stats) {
    for (const file of stat.filesChanged) {
      if (!fileMap.has(file)) {
        fileMap.set(file, []);
      }
      fileMap.get(file)!.push(stat.branch);
    }
  }

  return new Map([...fileMap.entries()].filter(([_, branches]) => branches.length > 1));
}

export const command: Command = {
  category: "util",
  name: "plan",
  help: "Analyze stack for PR planning (copies to clipboard)",
  run() {
    const stack = loadStack();
    const branch = currentBranch();

    console.log("Analyzing stack for PR planning...\n");

    const allBranches = Object.keys(stack);
    if (allBranches.length === 0) {
      console.error("No branches tracked. Use 'stack add <parent>' first.");
      process.exit(1);
    }

    const root = findRoot(stack, branch || allBranches[0]);
    const chain = getChainFromRoot(stack, branch || allBranches[0]);

    const stats: BranchStats[] = [];
    stats.push({ branch: root, parent: null, additions: 0, deletions: 0, filesChanged: [], commits: 0 });

    for (const b of chain) {
      const parent = stack[b];
      stats.push(getBranchStats(b, parent));
    }

    const overlaps = findFileOverlaps(stats.filter((s) => s.parent !== null));
    const uncommitted = getUncommittedChanges();
    const untrackedBranches = getUntrackedBranches();

    let prompt = `# Stack Analysis for PR Planning

## Goal
Help me organize my branches into small, atomic PRs (ideally under 200 lines changed each) that can be reviewed and merged independently without creating merge conflicts.

## Current Stack Structure

\`\`\`
`;

    function printTree(b: string, indent: string) {
      const stat = stats.find((s) => s.branch === b);
      const linesChanged = stat ? stat.additions + stat.deletions : 0;
      const marker = b === branch ? " <-- current" : "";
      const sizeWarning = linesChanged > 200 ? " ⚠️ LARGE" : "";

      if (stat && stat.parent) {
        prompt += `${indent}${b} (+${stat.additions}/-${stat.deletions}, ${stat.commits} commits)${marker}${sizeWarning}\n`;
      } else {
        prompt += `${indent}${b}${marker}\n`;
      }

      const children = getChildren(stack, b);
      children.forEach((child) => printTree(child, indent + "  "));
    }

    printTree(root, "");
    prompt += `\`\`\`

## Branch Details

`;

    for (const stat of stats) {
      if (!stat.parent) continue;

      const total = stat.additions + stat.deletions;
      prompt += `### ${stat.branch} (${total} lines, ${stat.commits} commits)
- Parent: ${stat.parent}
- Files changed (${stat.filesChanged.length}):
${stat.filesChanged.map((f) => `  - ${f}`).join("\n")}

`;
    }

    if (overlaps.size > 0) {
      prompt += `## ⚠️ File Overlaps (Potential Merge Conflicts)

These files are touched by multiple branches:

`;
      for (const [file, branches] of overlaps) {
        prompt += `- \`${file}\`: ${branches.join(", ")}\n`;
      }
      prompt += "\n";
    }

    if (uncommitted.staged.length > 0 || uncommitted.unstaged.length > 0) {
      prompt += `## Uncommitted Changes

`;
      if (uncommitted.staged.length > 0) {
        prompt += `Staged: ${uncommitted.staged.join(", ")}\n`;
      }
      if (uncommitted.unstaged.length > 0) {
        prompt += `Unstaged: ${uncommitted.unstaged.join(", ")}\n`;
      }
      prompt += "\n";
    }

    if (untrackedBranches.length > 0) {
      prompt += `## Untracked Branches

These branches exist but aren't in the stack:
${untrackedBranches.map((b) => `- ${b}`).join("\n")}

`;
    }

    prompt += `## Questions

1. Are there any branches that should be split into smaller PRs?
2. Are there branches that could be reordered to reduce file overlaps?
3. Should any changes be moved between branches (using \`stack fixup\`)?
4. Is there a better way to structure this stack?

## Available Commands

- \`stack insert <branch> --after <parent>\` - Insert a new branch in the middle
- \`stack fixup <branch>\` - Move staged changes to an ancestor branch
- \`stack edit <branch>\` / \`stack return\` - Edit an ancestor and cascade updates
- \`stack update\` - Rebase the stack after restructuring
`;

    console.log(prompt);

    try {
      execSync("which pbcopy", { stdio: "pipe" });
      execSync(`echo "${prompt.replace(/"/g, '\\"')}" | pbcopy`, { stdio: "pipe" });
      console.log("\n---\n✓ Copied to clipboard. Paste into Claude for analysis.");
    } catch {
      console.log("\n---\nCopy the above and paste into Claude for analysis.");
    }
  },
};
