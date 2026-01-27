import type { Command } from "../types.ts";
import {
  currentBranch,
  getCurrentStack,
  git,
  gitTry,
  loadStack,
  saveSnapshot,
} from "../lib.ts";
import { parseArgs } from "../args.ts";

// ANSI colors
const GREEN = "\x1b[32m";
const DIM = "\x1b[2m";
const RESET = "\x1b[0m";

/**
 * Get the number of commits between parent and child
 */
function getCommitCount(parent: string, child: string): number {
  const output = git(`rev-list --count ${parent}..${child}`);
  return parseInt(output, 10);
}

/**
 * Get all commit messages between parent and child (oldest first)
 */
function getCommitMessages(parent: string, child: string): string[] {
  const output = git(`log --reverse --format=%B ${parent}..${child}`);
  return output
    .split("\n")
    .map((line) => line.trim())
    .filter((line) => line.length > 0);
}

/**
 * Squash all commits on a branch into one
 * Uses soft reset to keep all changes staged, then recommits
 */
function squashBranch(branch: string, parent: string, message: string): boolean {
  git(`checkout ${branch}`);

  // Soft reset to parent - keeps all changes staged
  git(`reset --soft ${parent}`);

  // Commit with combined message
  // Use a temp file for the message to handle special characters
  const fs = require("fs");
  const os = require("os");
  const path = require("path");
  const msgFile = path.join(os.tmpdir(), `stack-compress-msg-${Date.now()}.txt`);
  fs.writeFileSync(msgFile, message);

  try {
    if (!gitTry(`commit -F "${msgFile}"`)) {
      fs.unlinkSync(msgFile);
      return false;
    }
    fs.unlinkSync(msgFile);
    return true;
  } catch {
    try { fs.unlinkSync(msgFile); } catch {}
    return false;
  }
}

export const command: Command = {
  category: "git",
  name: "compress",
  help: "Squash all commits on each branch in the stack into one",
  args: "[--all] [--first-only]",
  run(args) {
    const { values } = parseArgs(args, {
      all: { type: "boolean", short: "a" },
      "first-only": { type: "boolean", short: "f" },
    });

    const branch = currentBranch();
    const stack = loadStack();

    if (Object.keys(stack).length === 0) {
      console.log("No branches tracked");
      return;
    }

    // Get branches to compress
    let toCompress: string[];
    if (values.all) {
      toCompress = getCurrentStack(stack, branch);
    } else {
      // Just current branch
      if (!stack[branch]) {
        console.log("Current branch is not tracked in the stack");
        return;
      }
      toCompress = [branch];
    }

    if (toCompress.length === 0) {
      console.log("Nothing to compress");
      return;
    }

    // Analyze what will be compressed
    console.log("\nAnalyzing commits...\n");

    const compressionPlan: Array<{
      branch: string;
      parent: string;
      commitCount: number;
      messages: string[];
    }> = [];

    for (const b of toCompress) {
      const parent = stack[b];
      if (!parent) continue;

      const commitCount = getCommitCount(parent, b);
      if (commitCount > 1) {
        const messages = getCommitMessages(parent, b);
        compressionPlan.push({ branch: b, parent, commitCount, messages });
        console.log(`  ${b}: ${commitCount} commits -> 1`);
      } else {
        console.log(`  ${DIM}${b}: already 1 commit (skipping)${RESET}`);
      }
    }

    if (compressionPlan.length === 0) {
      console.log("\nAll branches already have single commits. Nothing to do.");
      return;
    }

    console.log(`\nWill compress ${compressionPlan.length} branch(es)\n`);

    // Save snapshot before modifying
    const allBranches = Object.keys(stack);
    saveSnapshot("compress", allBranches);

    // Compress each branch
    for (const { branch: b, parent, commitCount, messages } of compressionPlan) {
      // Build commit message
      let finalMessage: string;
      if (values["first-only"]) {
        // Use only the first commit message
        finalMessage = messages[0] || "Squashed commits";
      } else {
        // Combine all messages, deduped and filtered
        const uniqueMessages = [...new Set(messages)];
        finalMessage = uniqueMessages.join("\n\n");
      }

      console.log(`Compressing ${b} (${commitCount} commits -> 1)...`);

      if (squashBranch(b, parent, finalMessage)) {
        console.log(`${GREEN}Done: ${b}${RESET}\n`);
      } else {
        console.error(`\nFailed to compress ${b}`);
        console.error(`Use 'git reflog' to find previous state if needed.`);
        process.exit(1);
      }
    }

    // Return to original branch
    git(`checkout ${branch}`);

    console.log(`\n${GREEN}Compressed ${compressionPlan.length} branch(es)!${RESET}`);
    console.log(`${DIM}Run 'loops stack push-all --force' to update remotes${RESET}`);
  },
};
