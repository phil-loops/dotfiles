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

type DeletionZone = {
  file: string;
  lineStart: number;
  lineEnd: number;
  deletedLines: string[];  // The actual lines that were removed
  contextBefore: string[]; // Context lines before deletion
  contextAfter: string[];  // Context lines after deletion
  hunkHeader: string;
};

/**
 * Extract only the DELETION zones from a diff
 * These are the parts where code from the current branch was removed downstream
 */
function extractDeletionZones(diff: string, filepath: string): DeletionZone[] {
  const zones: DeletionZone[] = [];
  const lines = diff.split("\n");

  let currentLine = 0;
  let hunkHeader = "";
  let hunkStartLine = 0;

  for (let i = 0; i < lines.length; i++) {
    const line = lines[i];

    if (line.startsWith("@@")) {
      // Parse @@ -start,count +start,count @@
      const match = line.match(/@@ -(\d+)/);
      hunkStartLine = match ? parseInt(match[1], 10) : 0;
      currentLine = hunkStartLine;
      hunkHeader = line;
      continue;
    }

    // Skip file headers
    if (line.startsWith("---") || line.startsWith("+++") || line.startsWith("diff ")) {
      continue;
    }

    // Found a deletion - collect consecutive deletions
    if (line.startsWith("-")) {
      const deletedLines: string[] = [];
      const contextBefore: string[] = [];
      const contextAfter: string[] = [];
      const zoneStartLine = currentLine;

      // Get context before (look back for context lines)
      for (let j = i - 1; j >= 0 && j >= i - 3; j--) {
        const prevLine = lines[j];
        if (prevLine.startsWith(" ")) {
          contextBefore.unshift(prevLine.substring(1));
        } else if (prevLine.startsWith("@@")) {
          break;
        }
      }

      // Collect all consecutive deletions
      while (i < lines.length && lines[i].startsWith("-")) {
        deletedLines.push(lines[i].substring(1));
        currentLine++;
        i++;
      }

      const zoneEndLine = currentLine - 1;

      // Get context after
      let j = i;
      while (j < lines.length && j < i + 3) {
        const nextLine = lines[j];
        if (nextLine.startsWith(" ")) {
          contextAfter.push(nextLine.substring(1));
        } else if (nextLine.startsWith("@@")) {
          break;
        }
        j++;
      }

      // Adjust i back since we're in a loop
      i--;

      zones.push({
        file: filepath,
        lineStart: zoneStartLine,
        lineEnd: zoneEndLine,
        deletedLines,
        contextBefore,
        contextAfter,
        hunkHeader,
      });
    } else if (line.startsWith(" ")) {
      currentLine++;
    }
    // Note: additions (+) don't increment currentLine since they're in the "new" file
  }

  return zones;
}

/**
 * Display a deletion zone with context
 */
function displayDeletionZone(zone: DeletionZone, index: number, total: number): void {
  console.log(`\n${CYAN}${BOLD}Zone ${index + 1}/${total}${RESET} ${DIM}(lines ${zone.lineStart}-${zone.lineEnd})${RESET}`);
  console.log(`${DIM}File: ${zone.file}${RESET}`);
  console.log();

  // Context before
  for (const line of zone.contextBefore) {
    console.log(`${DIM}  ${line}${RESET}`);
  }

  // Deleted lines (highlighted)
  for (const line of zone.deletedLines) {
    console.log(`${RED}- ${line}${RESET}`);
  }

  // Context after
  for (const line of zone.contextAfter) {
    console.log(`${DIM}  ${line}${RESET}`);
  }
}

/**
 * Apply a deletion zone to the working file
 * This removes the deleted lines from the current branch so they don't need to be removed downstream
 */
function applyDeletionZone(zone: DeletionZone): boolean {
  try {
    const content = fs.readFileSync(zone.file, "utf8");
    const lines = content.split("\n");

    // Find the deletion zone by matching context + deleted lines
    let matchStart = -1;

    for (let i = 0; i <= lines.length - zone.deletedLines.length; i++) {
      let matches = true;

      // Check if deleted lines match at this position
      for (let j = 0; j < zone.deletedLines.length; j++) {
        if (lines[i + j] !== zone.deletedLines[j]) {
          matches = false;
          break;
        }
      }

      if (matches) {
        // Also verify context if available
        if (zone.contextBefore.length > 0) {
          const contextMatches = zone.contextBefore.every((ctx, idx) => {
            const lineIdx = i - zone.contextBefore.length + idx;
            return lineIdx >= 0 && lines[lineIdx] === ctx;
          });
          if (!contextMatches) continue;
        }

        matchStart = i;
        break;
      }
    }

    if (matchStart === -1) {
      console.error(`${YELLOW}Warning: Could not locate deletion zone in current file (code may have changed)${RESET}`);
      return false;
    }

    // Remove the lines
    lines.splice(matchStart, zone.deletedLines.length);
    fs.writeFileSync(zone.file, lines.join("\n"));

    return true;
  } catch (e: any) {
    console.error(`${RED}Failed to apply deletion: ${e.message}${RESET}`);
    return false;
  }
}

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
  args: "[--deletions] [--json] [file...]",
  async run(args) {
    const { values, positionals } = parseArgs(args, {
      "text": { type: "boolean", short: "t" },  // Old text-based mode
      "deletions": { type: "boolean", short: "d" },  // Show only deletion zones
      "json": { type: "boolean", short: "j" },  // Output JSON for AI processing
      "ai": { type: "boolean" },  // Use Claude CLI to analyze and recommend
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

    // AI mode: use Claude CLI to analyze diffs
    if (values["ai"]) {
      console.log(`\n${CYAN}Gathering diffs for Claude analysis...${RESET}\n`);

      // Get full diffs for each file (showing both deletions AND additions)
      const fileDiffs: { file: string; diff: string; finalBranch: string }[] = [];

      for (const file of filesToResolve) {
        const diff = git(`diff ${branch}..${file.finalBranch} -- "${file.path}"`);
        if (diff.trim()) {
          fileDiffs.push({ file: file.path, diff, finalBranch: file.finalBranch });
        }
      }

      if (fileDiffs.length === 0) {
        console.log(`\n${GREEN}✓ No diffs found${RESET}`);
        return;
      }

      // Also get current file contents for context
      const fileContents: { file: string; currentContent: string; finalContent: string }[] = [];
      for (const fd of fileDiffs) {
        try {
          const currentContent = fs.readFileSync(fd.file, "utf8");
          const finalContent = git(`show ${fd.finalBranch}:"${fd.file}"`);
          fileContents.push({ file: fd.file, currentContent, finalContent });
        } catch {}
      }

      const prompt = `You are helping with "append-only" development in a stacked PR workflow.

CONTEXT:
- Current branch: "${branch}"
- This branch adds code that gets modified in later branches
- Goal: Minimize churn by using the FINAL version of code from the start

For each file, I'm showing you:
1. The unified diff (- lines exist in current branch, + lines are the final version)
2. The current file content
3. The final file content

YOUR TASK:
Analyze the diffs and recommend specific changes to make to the CURRENT branch.
Focus on cases where code was:
- RENAMED (use the final name from the start)
- REFACTORED (use the cleaner version from the start)
- REMOVED (don't add it if it gets removed)

Output a JSON response with this structure:
{
  "files": [
    {
      "path": "file/path.ts",
      "action": "REPLACE_FILE" | "APPLY_CHANGES" | "SKIP",
      "reason": "explanation",
      "changes": [
        {
          "type": "rename" | "refactor" | "remove",
          "description": "what changed",
          "oldCode": "brief snippet of old code",
          "newCode": "brief snippet of new code (or null if removed)"
        }
      ]
    }
  ],
  "summary": "overall summary"
}

If REPLACE_FILE: The whole file should use the final version
If APPLY_CHANGES: Specific changes should be cherry-picked
If SKIP: The current version is fine, changes are additive only

FILES:
${fileDiffs.map((fd, i) => `
=== FILE ${i + 1}: ${fd.file} ===

DIFF (current → final):
${fd.diff}

CURRENT VERSION:
${fileContents[i]?.currentContent || "(could not read)"}

FINAL VERSION:
${fileContents[i]?.finalContent || "(could not read)"}
`).join("\n---\n")}`;

      // Write prompt to temp file and pipe to claude
      const tmpPrompt = `/tmp/stack-resolve-prompt.txt`;
      fs.writeFileSync(tmpPrompt, prompt);

      console.log(`${CYAN}Sending to Claude CLI (this may take a moment)...${RESET}\n`);

      let claudeOutput = "";
      try {
        // Use -p flag and increase timeout for longer prompts
        claudeOutput = execSync(`claude -p < "${tmpPrompt}"`, {
          encoding: "utf8",
          maxBuffer: 10 * 1024 * 1024,
          timeout: 180000,  // 3 minute timeout for larger files
        });
      } catch (e: any) {
        console.error(`${RED}Failed to run claude CLI${RESET}`);
        if (e.stderr) {
          console.error(`${DIM}${e.stderr}${RESET}`);
        }
        if (e.stdout) {
          console.log(`${DIM}Partial output: ${e.stdout}${RESET}`);
        }
        console.log(`${DIM}Error: ${e.message}${RESET}`);
        try { fs.unlinkSync(tmpPrompt); } catch {}
        return;
      }

      try { fs.unlinkSync(tmpPrompt); } catch {}

      // Try to parse JSON from Claude's response
      type FileRec = {
        path: string;
        action: "REPLACE_FILE" | "APPLY_CHANGES" | "SKIP";
        reason: string;
        changes?: { type: string; description: string; oldCode?: string; newCode?: string }[];
      };
      let fileRecs: FileRec[] = [];
      let summary = "";

      // Extract JSON from response (Claude might include explanation text)
      const jsonMatch = claudeOutput.match(/\{[\s\S]*"files"[\s\S]*\}/);
      if (jsonMatch) {
        try {
          const parsed = JSON.parse(jsonMatch[0]);
          fileRecs = parsed.files || [];
          summary = parsed.summary || "";
        } catch {
          console.log(`${YELLOW}Could not parse Claude's JSON response. Showing raw output:${RESET}\n`);
          console.log(claudeOutput);
          return;
        }
      } else {
        console.log(`${YELLOW}Claude's response:${RESET}\n`);
        console.log(claudeOutput);
        return;
      }

      // Display recommendations
      console.log(`${CYAN}${BOLD}━━━ Claude's Analysis ━━━${RESET}\n`);
      if (summary) {
        console.log(`${summary}\n`);
      }

      const filesToReplace: { path: string; rec: FileRec }[] = [];
      const filesToSkip: { path: string; rec: FileRec }[] = [];

      for (const rec of fileRecs) {
        const actionColor = rec.action === "REPLACE_FILE" ? GREEN : rec.action === "APPLY_CHANGES" ? YELLOW : DIM;
        const actionIcon = rec.action === "REPLACE_FILE" ? "✓" : rec.action === "APPLY_CHANGES" ? "△" : "○";

        console.log(`${actionColor}${actionIcon} ${rec.path}${RESET}`);
        console.log(`  ${DIM}Action: ${rec.action}${RESET}`);
        console.log(`  ${DIM}Reason: ${rec.reason}${RESET}`);

        if (rec.changes && rec.changes.length > 0) {
          console.log(`  ${DIM}Changes:${RESET}`);
          for (const change of rec.changes) {
            console.log(`    • ${change.type}: ${change.description}`);
            if (change.oldCode && change.newCode) {
              console.log(`      ${RED}- ${change.oldCode.substring(0, 60)}${change.oldCode.length > 60 ? "..." : ""}${RESET}`);
              console.log(`      ${GREEN}+ ${change.newCode.substring(0, 60)}${change.newCode.length > 60 ? "..." : ""}${RESET}`);
            }
          }
        }
        console.log();

        if (rec.action === "REPLACE_FILE") {
          filesToReplace.push({ path: rec.path, rec });
        } else {
          filesToSkip.push({ path: rec.path, rec });
        }
      }

      // Summary
      console.log(`${CYAN}━━━ Summary ━━━${RESET}`);
      console.log(`  ${GREEN}Replace: ${filesToReplace.length}${RESET} file(s) with final version`);
      console.log(`  ${YELLOW}Skip: ${filesToSkip.length}${RESET} file(s)\n`);

      if (filesToReplace.length === 0) {
        console.log(`${DIM}No files to replace.${RESET}`);
        return;
      }

      // Log the analysis
      const logFile = `.stack-resolve-log.md`;
      const logContent = `# Drift Resolution - ${new Date().toISOString()}

## Branch: ${branch}

## Summary
${summary}

${fileRecs.map(rec => `### ${rec.path}
**Action:** ${rec.action}
**Reason:** ${rec.reason}

${rec.changes?.map(c => `- **${c.type}**: ${c.description}`).join("\n") || ""}
`).join("\n")}
`;
      fs.writeFileSync(logFile, logContent);
      console.log(`${DIM}Analysis logged to ${logFile}${RESET}\n`);

      // Ask for confirmation
      const answer = await prompt(`${YELLOW}Replace ${filesToReplace.length} file(s) with final versions?${RESET} [y/n/v] `);

      if (answer === "v" || answer === "view") {
        // Open each file in diff view
        for (const { path } of filesToReplace) {
          const fileData = filesToResolve.find(f => f.path === path);
          if (!fileData) continue;

          const finalContent = git(`show ${fileData.finalBranch}:"${path}"`);
          const tmpFinal = `/tmp/stack-resolve-final.ts`;
          fs.writeFileSync(tmpFinal, finalContent);

          console.log(`\n${CYAN}Viewing: ${path}${RESET}`);
          try {
            execSync(`nvim -d "${path}" "${tmpFinal}" -c "wincmd l | set readonly | set nomodifiable | wincmd h"`, { stdio: "inherit" });
          } catch {}
          try { fs.unlinkSync(tmpFinal); } catch {}
        }

        const confirmAnswer = await prompt(`\n${YELLOW}Apply the replacements?${RESET} [y/n] `);
        if (confirmAnswer !== "y" && confirmAnswer !== "yes") {
          console.log(`${DIM}Aborted.${RESET}`);
          return;
        }
      } else if (answer !== "y" && answer !== "yes") {
        console.log(`${DIM}Aborted.${RESET}`);
        return;
      }

      // Apply the replacements
      const appliedFiles: string[] = [];
      for (const { path } of filesToReplace) {
        const fileData = filesToResolve.find(f => f.path === path);
        if (!fileData) continue;

        try {
          const finalContent = git(`show ${fileData.finalBranch}:"${path}"`);
          fs.writeFileSync(path, finalContent);
          appliedFiles.push(path);
          console.log(`${GREEN}✓ Replaced ${path} with version from ${fileData.finalBranch}${RESET}`);
        } catch (e: any) {
          console.error(`${RED}✗ Failed to replace ${path}: ${e.message}${RESET}`);
        }
      }

      if (appliedFiles.length === 0) {
        console.log(`${YELLOW}No files could be replaced.${RESET}`);
        return;
      }

      // Stage and commit
      for (const file of appliedFiles) {
        execSync(`git add "${file}"`, { stdio: "inherit" });
      }

      const commitAnswer = await prompt(`\n${YELLOW}Commit changes?${RESET} [a]mend, [n]ew commit, [s]kip: `);

      if (commitAnswer === "a" || commitAnswer === "amend") {
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
        execSync(`git commit -m "resolve: use final versions of drifted files (AI-assisted)"`, { stdio: "inherit" });
        console.log(`${GREEN}✓ Created commit${RESET}`);
      } else {
        console.log(`${DIM}Changes staged but not committed.${RESET}`);
      }

      return;
    }

    // Deletions mode: extract and show only the deletion zones
    if (values["deletions"] || values["json"]) {
      const allZones: DeletionZone[] = [];

      for (const file of filesToResolve) {
        const diff = git(`diff ${branch}..${file.finalBranch} -- "${file.path}"`);
        const zones = extractDeletionZones(diff, file.path);
        allZones.push(...zones);
      }

      if (allZones.length === 0) {
        console.log(`\n${GREEN}✓ No deletion zones found - downstream changes are additions only${RESET}`);
        return;
      }

      // JSON mode for AI processing
      if (values["json"]) {
        const output = {
          branch,
          totalDeletionZones: allZones.length,
          zones: allZones.map((z, i) => ({
            id: i + 1,
            file: z.file,
            lineRange: `${z.lineStart}-${z.lineEnd}`,
            deletedLineCount: z.deletedLines.length,
            contextBefore: z.contextBefore,
            deletedLines: z.deletedLines,
            contextAfter: z.contextAfter,
          })),
        };
        console.log(JSON.stringify(output, null, 2));
        return;
      }

      // Interactive deletion zone review
      console.log(`\n${CYAN}Found ${allZones.length} deletion zone(s)${RESET}`);
      console.log(`${DIM}These are code blocks that exist in ${branch} but were removed downstream.${RESET}`);
      console.log(`${DIM}Applying a deletion here means the code won't need to be removed downstream.${RESET}\n`);

      const appliedZones: DeletionZone[] = [];

      for (let i = 0; i < allZones.length; i++) {
        const zone = allZones[i];
        displayDeletionZone(zone, i, allZones.length);

        console.log();
        console.log(`${CYAN}[y]${RESET}es - Remove this code from ${branch} (apply deletion)`);
        console.log(`${CYAN}[n]${RESET}o  - Keep this code (don't apply deletion)`);
        console.log(`${CYAN}[v]${RESET}im - Open in vim diff to see full context`);
        console.log(`${CYAN}[a]${RESET}ll - Apply all remaining deletions`);
        console.log(`${CYAN}[q]${RESET}uit\n`);

        const action = await prompt(`Apply this deletion? `);

        if (action === "q") {
          console.log(`${DIM}Aborted.${RESET}`);
          break;
        }

        if (action === "a") {
          // Apply all remaining
          for (let j = i; j < allZones.length; j++) {
            if (applyDeletionZone(allZones[j])) {
              appliedZones.push(allZones[j]);
              console.log(`${GREEN}✓ Applied deletion ${j + 1}/${allZones.length}${RESET}`);
            }
          }
          break;
        }

        if (action === "v" || action === "vim") {
          // Open in vim diff mode
          const finalContent = git(`show ${filesToResolve.find(f => f.path === zone.file)!.finalBranch}:"${zone.file}"`);
          const tmpFinal = `/tmp/stack-resolve-final.ts`;
          fs.writeFileSync(tmpFinal, finalContent);
          try {
            execSync(`nvim -d "${zone.file}" "${tmpFinal}" -c "wincmd l | set readonly | set nomodifiable | wincmd h | normal ${zone.lineStart}G"`, { stdio: "inherit" });
          } catch {}
          try { fs.unlinkSync(tmpFinal); } catch {}

          // Re-ask after vim
          i--;
          continue;
        }

        if (action === "y" || action === "yes") {
          if (applyDeletionZone(zone)) {
            appliedZones.push(zone);
            console.log(`${GREEN}✓ Applied${RESET}`);
          }
        } else {
          console.log(`${DIM}Skipped${RESET}`);
        }
      }

      if (appliedZones.length > 0) {
        console.log(`\n${CYAN}━━━ Applied ${appliedZones.length} deletion(s) ━━━${RESET}`);

        // Stage modified files
        const modifiedFiles = [...new Set(appliedZones.map(z => z.file))];
        for (const file of modifiedFiles) {
          execSync(`git add "${file}"`, { stdio: "inherit" });
        }

        const commitAnswer = await prompt(`${YELLOW}Commit changes?${RESET} [a]mend, [n]ew commit, [s]kip: `);

        if (commitAnswer === "a" || commitAnswer === "amend") {
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
          execSync(`git commit -m "resolve: apply ${appliedZones.length} deletion(s) from downstream"`, { stdio: "inherit" });
          console.log(`${GREEN}✓ Created commit${RESET}`);
        } else {
          console.log(`${DIM}Changes staged but not committed.${RESET}`);
        }
      } else {
        console.log(`\n${DIM}No deletions applied.${RESET}`);
      }

      return;
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
