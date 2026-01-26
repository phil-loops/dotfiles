import type { Command } from "../types.ts";
import { currentBranch, git, loadStack, getDescendants } from "../lib.ts";
import { parseArgs } from "../args.ts";
import { execSync } from "child_process";
import * as readline from "readline";
import * as fs from "fs";

// ANSI colors
const RED = "\x1b[31m";
const GREEN = "\x1b[32m";
const YELLOW = "\x1b[33m";
const CYAN = "\x1b[36m";
const DIM = "\x1b[2m";
const BOLD = "\x1b[1m";
const RESET = "\x1b[0m";

type DriftedFile = {
  path: string;
  introducedIn: string;
  modifiedIn: string[];  // branches that modified it with deletions
  finalBranch: string;   // last branch in stack
};

/**
 * Find files introduced in this branch that have deletions downstream
 */
function findDriftedFiles(branch: string, stack: Record<string, string>): DriftedFile[] {
  const descendants = getDescendants(stack, branch);
  if (descendants.length === 0) return [];

  const finalBranch = descendants[descendants.length - 1];
  const parent = stack[branch];
  if (!parent) return [];

  // Get files introduced in this branch
  const introducedFiles = git(`diff --name-only ${parent}...${branch} -- "*.ts" ":!*.test.ts" ":!*.tsx"`)
    .split("\n")
    .filter(f => f.trim());

  const driftedFiles: DriftedFile[] = [];

  for (const file of introducedFiles) {
    const modifiedIn: string[] = [];

    // Check each descendant for deletions to this file
    let prevBranch = branch;
    for (const desc of descendants) {
      try {
        const numstat = git(`diff --numstat ${prevBranch}...${desc} -- "${file}"`);
        if (numstat.trim()) {
          const [added, removed] = numstat.split("\t");
          if (removed && parseInt(removed, 10) > 0) {
            modifiedIn.push(desc);
          }
        }
      } catch {
        // File might not exist in some branches
      }
      prevBranch = desc;
    }

    if (modifiedIn.length > 0) {
      driftedFiles.push({
        path: file,
        introducedIn: branch,
        modifiedIn,
        finalBranch,
      });
    }
  }

  return driftedFiles;
}

type Hunk = {
  header: string;
  lines: string[];
  startLine: number;
  context: string;  // First meaningful line for identification
  additions: number;
  deletions: number;
};

/**
 * Parse a diff into individual hunks
 */
function parseDiffHunks(diff: string): Hunk[] {
  const hunks: Hunk[] = [];
  const lines = diff.split("\n");

  let currentHunk: Hunk | null = null;

  for (const line of lines) {
    if (line.startsWith("@@")) {
      // Save previous hunk
      if (currentHunk) {
        hunks.push(currentHunk);
      }

      // Parse line number from @@ -start,count +start,count @@
      const match = line.match(/@@ -(\d+)/);
      const startLine = match ? parseInt(match[1], 10) : 0;

      currentHunk = {
        header: line,
        lines: [line],
        startLine,
        context: "",
        additions: 0,
        deletions: 0,
      };
    } else if (currentHunk) {
      currentHunk.lines.push(line);

      if (line.startsWith("+") && !line.startsWith("+++")) {
        currentHunk.additions++;
        // Capture first addition as context
        if (!currentHunk.context && line.length > 1) {
          currentHunk.context = line.substring(1).trim().substring(0, 50);
        }
      } else if (line.startsWith("-") && !line.startsWith("---")) {
        currentHunk.deletions++;
        // Use deletion as context if no addition yet
        if (!currentHunk.context && line.length > 1) {
          currentHunk.context = line.substring(1).trim().substring(0, 50);
        }
      }
    }
  }

  // Don't forget last hunk
  if (currentHunk) {
    hunks.push(currentHunk);
  }

  return hunks;
}

/**
 * Display a single hunk with colors
 */
function displayHunk(hunk: Hunk, index: number, total: number): void {
  console.log(`\n${CYAN}${BOLD}Hunk ${index + 1}/${total}${RESET} ${DIM}(line ${hunk.startLine})${RESET}`);
  console.log(`${DIM}Context: ${hunk.context || "(empty)"}${RESET}`);
  console.log(`${DIM}Changes: ${GREEN}+${hunk.additions}${RESET} ${RED}-${hunk.deletions}${RESET}\n`);

  for (const line of hunk.lines) {
    if (line.startsWith("+") && !line.startsWith("+++")) {
      console.log(`${GREEN}${line}${RESET}`);
    } else if (line.startsWith("-") && !line.startsWith("---")) {
      console.log(`${RED}${line}${RESET}`);
    } else if (line.startsWith("@@")) {
      console.log(`${CYAN}${line}${RESET}`);
    } else {
      console.log(DIM + line + RESET);
    }
  }
}

/**
 * Apply a single hunk to the working directory
 */
function applyHunk(file: DriftedFile, hunk: Hunk, branch: string): boolean {
  try {
    // Create a minimal patch for just this hunk
    const patchLines = [
      `--- a/${file.path}`,
      `+++ b/${file.path}`,
      ...hunk.lines,
    ];
    const patch = patchLines.join("\n") + "\n";

    // Write patch to temp file
    const tmpPatch = `/tmp/stack-resolve-hunk.patch`;
    fs.writeFileSync(tmpPatch, patch);

    // Apply the patch
    execSync(`git apply --3way "${tmpPatch}"`, { stdio: "pipe" });
    fs.unlinkSync(tmpPatch);

    return true;
  } catch (e: any) {
    // Try without --3way as fallback
    try {
      const patchLines = [
        `--- a/${file.path}`,
        `+++ b/${file.path}`,
        ...hunk.lines,
      ];
      const patch = patchLines.join("\n") + "\n";
      const tmpPatch = `/tmp/stack-resolve-hunk.patch`;
      fs.writeFileSync(tmpPatch, patch);
      execSync(`git apply "${tmpPatch}"`, { stdio: "pipe" });
      fs.unlinkSync(tmpPatch);
      return true;
    } catch {
      console.error(`${RED}Failed to apply hunk (may conflict)${RESET}`);
      return false;
    }
  }
}

/**
 * Show diff between current branch version and final version
 */
function showFileDiff(file: DriftedFile, branch: string): { additions: number; deletions: number; diff: string } {
  console.log(`\n${CYAN}━━━ ${file.path} ━━━${RESET}`);
  console.log(`${DIM}Introduced in: ${branch}${RESET}`);
  console.log(`${DIM}Modified in: ${file.modifiedIn.join(" → ")}${RESET}`);
  console.log(`${DIM}Final version: ${file.finalBranch}${RESET}`);

  // Get the diff between this branch and final
  try {
    const diff = git(`diff ${branch}..${file.finalBranch} -- "${file.path}"`);

    let additions = 0;
    let deletions = 0;

    for (const line of diff.split("\n")) {
      if (line.startsWith("+") && !line.startsWith("+++")) {
        additions++;
      } else if (line.startsWith("-") && !line.startsWith("---")) {
        deletions++;
      }
    }

    return { additions, deletions, diff };
  } catch {
    console.log(`${DIM}(Could not generate diff)${RESET}`);
    return { additions: 0, deletions: 0, diff: "" };
  }
}

/**
 * Pull final version of file into current branch
 */
function pullFinalVersion(file: DriftedFile): boolean {
  try {
    // Get file content from final branch
    const content = git(`show ${file.finalBranch}:"${file.path}"`);

    // Write to working directory
    const fs = require("fs");
    fs.writeFileSync(file.path, content);

    console.log(`${GREEN}✓ Pulled ${file.path} from ${file.finalBranch}${RESET}`);
    return true;
  } catch (e) {
    console.error(`${RED}✗ Failed to pull ${file.path}: ${e}${RESET}`);
    return false;
  }
}

/**
 * Interactive prompt
 */
async function prompt(question: string): Promise<string> {
  const rl = readline.createInterface({
    input: process.stdin,
    output: process.stdout,
  });

  return new Promise((resolve) => {
    rl.question(question, (answer) => {
      rl.close();
      resolve(answer.trim().toLowerCase());
    });
  });
}

export const command: Command = {
  category: "edit",
  name: "resolve",
  help: "Resolve drift by pulling final versions of files into current branch",
  args: "[--hierarchical-text-dump] [file...]",
  async run(args) {
    const { values, positionals } = parseArgs(args, {
      "text": { type: "boolean", short: "t" },  // Old text-based mode
    });

    const stack = loadStack();
    const branch = currentBranch();

    if (!stack[branch]) {
      console.error(`${RED}Current branch "${branch}" is not in the stack${RESET}`);
      process.exit(1);
    }

    // Find drifted files
    console.log(`${CYAN}Analyzing drift for ${branch}...${RESET}\n`);
    const driftedFiles = findDriftedFiles(branch, stack);

    if (driftedFiles.length === 0) {
      console.log(`${GREEN}✓ No drift detected - all files match their final versions${RESET}`);
      return;
    }

    // Filter to specific files if provided
    let filesToResolve = driftedFiles;
    if (positionals.length > 0) {
      filesToResolve = driftedFiles.filter(f =>
        positionals.some(p => f.path.includes(p))
      );
    }

    console.log(`${YELLOW}Found ${filesToResolve.length} file(s) with drift:${RESET}`);
    for (const f of filesToResolve) {
      console.log(`  ${YELLOW}⚠${RESET}  ${f.path}`);
    }

    // Visual mode (default): open nvim with side-by-side diff
    if (!values["text"]) {
      console.log(`\n${CYAN}Opening visual diff in nvim...${RESET}`);
      console.log(`${DIM}Left: your version (editable) | Right: final version (reference)${RESET}`);
      console.log(`${DIM}Use :diffget (or do) to pull changes, :diffput (or dp) to push${RESET}`);
      console.log(`${DIM}Save with :w when done, then :qa to finish${RESET}\n`);

      for (const file of filesToResolve) {
        const answer = await prompt(`${YELLOW}Review ${file.path}?${RESET} [y/n/q] `);

        if (answer === "q") {
          console.log(`${DIM}Aborted.${RESET}`);
          return;
        }

        if (answer !== "y" && answer !== "yes" && answer !== "") {
          console.log(`${DIM}Skipped${RESET}`);
          continue;
        }

        // Create temp file with final version for reference
        const finalContent = git(`show ${file.finalBranch}:"${file.path}"`);
        const tmpFinal = `/tmp/stack-resolve-final.ts`;
        fs.writeFileSync(tmpFinal, finalContent);

        // Open nvim: left = actual file (editable), right = final version (reference)
        try {
          execSync(`nvim -d "${file.path}" "${tmpFinal}" -c "wincmd l | set readonly | set nomodifiable | wincmd h"`, { stdio: "inherit" });
        } catch {
          // User quit nvim
        }

        // Clean up temp file
        try { fs.unlinkSync(tmpFinal); } catch {}

        // Check if file was modified
        const status = git(`status --porcelain "${file.path}"`);
        if (status.trim()) {
          console.log(`${GREEN}✓ ${file.path} was modified${RESET}`);
        } else {
          console.log(`${DIM}No changes to ${file.path}${RESET}`);
        }
      }

      // If any files were modified, offer to commit
      const overallStatus = git(`status --porcelain`);
      if (overallStatus.trim()) {
        console.log(`\n${CYAN}━━━ Changes detected ━━━${RESET}`);
        execSync(`git status --short`, { stdio: "inherit" });

        const commitAnswer = await prompt(`\n${YELLOW}Commit changes?${RESET} [a]mend, [n]ew commit, [s]kip: `);

        if (commitAnswer === "a" || commitAnswer === "amend") {
          for (const file of filesToResolve) {
            const status = git(`status --porcelain "${file.path}"`);
            if (status.trim()) {
              execSync(`git add "${file.path}"`, { stdio: "inherit" });
            }
          }
          execSync(`git commit --amend --no-edit`, { stdio: "inherit" });
          console.log(`${GREEN}✓ Amended commit${RESET}`);

          const rebaseAnswer = await prompt(`\n${YELLOW}Rebase downstream branches?${RESET} [y/n] `);
          if (rebaseAnswer === "y" || rebaseAnswer === "yes") {
            console.log(`\n${CYAN}Running: loops stack return${RESET}\n`);
            try {
              execSync(`node --no-warnings --experimental-strip-types ~/.dotfiles/scripts/stack/index.ts return`, { stdio: "inherit" });
              console.log(`\n${GREEN}✓ Stack updated!${RESET}`);
            } catch {
              console.error(`\n${RED}Rebase had conflicts. Resolve and run: loops stack return --continue${RESET}`);
            }
          }
        } else if (commitAnswer === "n" || commitAnswer === "new") {
          for (const file of filesToResolve) {
            const status = git(`status --porcelain "${file.path}"`);
            if (status.trim()) {
              execSync(`git add "${file.path}"`, { stdio: "inherit" });
            }
          }
          execSync(`git commit -m "resolve: incorporate final versions of drifted code"`, { stdio: "inherit" });
          console.log(`${GREEN}✓ Created commit${RESET}`);
        } else {
          console.log(`${DIM}Changes left unstaged.${RESET}`);
        }
      } else {
        console.log(`\n${DIM}No changes made.${RESET}`);
      }

      return;
    }

    // Text mode (--text flag): old hunk-based flow
    console.log(`${DIM}(Text mode - use without --text for visual diff)${RESET}\n`);

    // Process each file
    const modifiedFiles: string[] = [];

    for (const file of filesToResolve) {
      const { additions, deletions, diff } = showFileDiff(file, branch);

      if (!diff) {
        console.log(`${DIM}No diff found, skipping${RESET}`);
        continue;
      }

      const hunks = parseDiffHunks(diff);
      console.log(`\n${YELLOW}${hunks.length} hunk(s) to review${RESET}`);
      console.log(`${DIM}Total changes: ${GREEN}+${additions}${RESET}${DIM} ${RED}-${deletions}${RESET}\n`);

      if (hunks.length === 0) {
        continue;
      }

      // Ask for mode
      console.log(`${CYAN}[a]${RESET}pply all hunks for this file`);
      console.log(`${CYAN}[i]${RESET}nteractive - review each hunk`);
      console.log(`${CYAN}[s]${RESET}kip this file`);
      console.log(`${CYAN}[q]${RESET}uit\n`);
      const mode = await prompt(`Mode for ${file.path}? `);

      if (mode === "q") {
        console.log(`\n${YELLOW}Aborted.${RESET}`);
        return;
      }

      if (mode === "s" || mode === "skip") {
        console.log(`${DIM}Skipped ${file.path}${RESET}`);
        continue;
      }

      let appliedAny = false;

      if (mode === "a" || mode === "all") {
        // Apply all hunks
        for (const hunk of hunks) {
          if (applyHunk(file, hunk, branch)) {
            appliedAny = true;
          }
        }
        if (appliedAny) {
          console.log(`${GREEN}✓ Applied all hunks to ${file.path}${RESET}`);
        }
      } else if (mode === "i" || mode === "interactive") {
        // Interactive mode - review each hunk
        for (let i = 0; i < hunks.length; i++) {
          const hunk = hunks[i];
          displayHunk(hunk, i, hunks.length);

          const action = await prompt(
            `${CYAN}[y]${RESET}es apply, ${CYAN}[n]${RESET}o skip, ${CYAN}[a]${RESET}ll remaining, ${CYAN}[q]${RESET}uit file? `
          );

          if (action === "q") {
            console.log(`${DIM}Stopping at this hunk${RESET}`);
            break;
          }

          if (action === "a") {
            // Apply this and all remaining
            for (let j = i; j < hunks.length; j++) {
              if (applyHunk(file, hunks[j], branch)) {
                appliedAny = true;
              }
            }
            console.log(`${GREEN}✓ Applied remaining hunks${RESET}`);
            break;
          }

          if (action === "y" || action === "yes") {
            if (applyHunk(file, hunk, branch)) {
              appliedAny = true;
              console.log(`${GREEN}✓ Applied${RESET}`);
            }
          } else {
            console.log(`${DIM}Skipped${RESET}`);
          }
        }
      }

      if (appliedAny) {
        modifiedFiles.push(file.path);
      }
    }

    const pulledFiles = modifiedFiles;

    if (pulledFiles.length === 0) {
      console.log(`\n${DIM}No files changed.${RESET}`);
      return;
    }

    // Stage and amend
    console.log(`\n${CYAN}━━━ Committing changes ━━━${RESET}`);

    for (const file of pulledFiles) {
      execSync(`git add "${file}"`, { stdio: "inherit" });
    }

    console.log(`\n${YELLOW}Files staged. How do you want to commit?${RESET}`);
    console.log(`  ${CYAN}[a]${RESET}mend - Add to current branch's commit (recommended)`);
    console.log(`  ${CYAN}[n]${RESET}ew   - Create new commit "resolve: pull final versions"`);
    console.log(`  ${CYAN}[s]${RESET}kip  - Leave staged, don't commit yet`);

    const commitAction = values.yes ? "a" : await prompt("\nCommit action? ");

    if (commitAction === "a" || commitAction === "amend") {
      execSync(`git commit --amend --no-edit`, { stdio: "inherit" });
      console.log(`${GREEN}✓ Amended commit${RESET}`);
    } else if (commitAction === "n" || commitAction === "new") {
      execSync(`git commit -m "resolve: pull final versions from downstream"`, { stdio: "inherit" });
      console.log(`${GREEN}✓ Created new commit${RESET}`);
    } else {
      console.log(`${DIM}Changes staged but not committed.${RESET}`);
      return;
    }

    // Offer to rebase downstream
    console.log(`\n${CYAN}━━━ Rebase downstream branches ━━━${RESET}`);
    console.log(`${YELLOW}You've changed this branch. Downstream branches need to be rebased.${RESET}`);
    console.log(`${DIM}This may cause conflicts if the same code was modified downstream.${RESET}\n`);

    const rebaseAction = values.yes ? "y" : await prompt(
      `Run ${CYAN}loops stack return${RESET} to rebase? [y/n] `
    );

    if (rebaseAction === "y" || rebaseAction === "yes") {
      console.log(`\n${CYAN}Rebasing downstream branches...${RESET}\n`);
      try {
        execSync(`node --no-warnings --experimental-strip-types ~/.dotfiles/scripts/stack/index.ts return`, {
          stdio: "inherit"
        });
        console.log(`\n${GREEN}✓ Stack updated successfully!${RESET}`);
        console.log(`${DIM}The drifted code is now in its original branch, and downstream branches are rebased.${RESET}`);
      } catch (e) {
        console.error(`\n${RED}Rebase had conflicts. Resolve them and run: loops stack return --continue${RESET}`);
      }
    } else {
      console.log(`\n${YELLOW}Remember to run 'loops stack return' when ready to rebase.${RESET}`);
    }
  },
};
