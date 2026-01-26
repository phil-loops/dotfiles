import type { Command } from "../types.ts";
import { currentBranch, git, loadStack, getDescendants } from "../lib.ts";
import { parseArgs } from "../args.ts";
import { execSync } from "child_process";
import * as readline from "readline";

// ANSI colors
const RED = "\x1b[31m";
const GREEN = "\x1b[32m";
const YELLOW = "\x1b[33m";
const CYAN = "\x1b[36m";
const DIM = "\x1b[2m";
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

/**
 * Show diff between current branch version and final version
 */
function showFileDiff(file: DriftedFile, branch: string): { additions: number; deletions: number } {
  console.log(`\n${CYAN}━━━ ${file.path} ━━━${RESET}`);
  console.log(`${DIM}Introduced in: ${branch}${RESET}`);
  console.log(`${DIM}Modified in: ${file.modifiedIn.join(" → ")}${RESET}`);
  console.log(`${DIM}Final version: ${file.finalBranch}${RESET}\n`);

  // Show the diff between this branch and final
  try {
    const diff = git(`diff ${branch}...${file.finalBranch} -- "${file.path}"`);

    let additions = 0;
    let deletions = 0;

    for (const line of diff.split("\n")) {
      if (line.startsWith("+") && !line.startsWith("+++")) {
        console.log(`${GREEN}${line}${RESET}`);
        additions++;
      } else if (line.startsWith("-") && !line.startsWith("---")) {
        console.log(`${RED}${line}${RESET}`);
        deletions++;
      } else if (line.startsWith("@@")) {
        console.log(`${CYAN}${line}${RESET}`);
      } else {
        console.log(DIM + line + RESET);
      }
    }

    return { additions, deletions };
  } catch {
    console.log(`${DIM}(Could not generate diff)${RESET}`);
    return { additions: 0, deletions: 0 };
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
  args: "[--dry-run] [--all] [file...]",
  async run(args) {
    const { values, positionals } = parseArgs(args, {
      "dry-run": { type: "boolean", short: "n" },
      all: { type: "boolean", short: "a" },
      yes: { type: "boolean", short: "y" },
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

    if (values["dry-run"]) {
      console.log(`\n${DIM}(dry-run mode - no changes made)${RESET}`);

      for (const file of filesToResolve) {
        showFileDiff(file, branch);
      }
      return;
    }

    // Process each file
    const pulledFiles: string[] = [];

    for (const file of filesToResolve) {
      const { additions, deletions } = showFileDiff(file, branch);

      console.log(`\n${DIM}This diff shows what changes downstream.${RESET}`);
      console.log(`${DIM}Pulling final version will incorporate ${GREEN}+${additions}${RESET}${DIM}/${RED}-${deletions}${RESET}${DIM} into this branch.${RESET}\n`);

      let action: string;
      if (values.yes || values.all) {
        action = "p";
        console.log(`${DIM}Auto-pulling (--yes or --all flag)${RESET}`);
      } else {
        action = await prompt(
          `${CYAN}[p]${RESET}ull final version, ${CYAN}[s]${RESET}kip, ${CYAN}[q]${RESET}uit? `
        );
      }

      if (action === "q") {
        console.log(`\n${YELLOW}Aborted.${RESET}`);
        return;
      }

      if (action === "p" || action === "pull") {
        if (pullFinalVersion(file)) {
          pulledFiles.push(file.path);
        }
      } else {
        console.log(`${DIM}Skipped ${file.path}${RESET}`);
      }
    }

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
