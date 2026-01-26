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
 * Show a summary of what changed after applying
 */
function showChangeSummary(files: string[], plan: { path: string; action: string; reason: string; changes?: any[] }[]): void {
  console.log(`\n${CYAN}${BOLD}━━━ WHAT CHANGED ━━━${RESET}\n`);

  for (const file of files) {
    // Get the actual diff for this file
    try {
      const diff = execSync(`git diff HEAD -- "${file}"`, { encoding: "utf8" });
      if (!diff.trim()) {
        // File was staged, check staged diff
        const stagedDiff = execSync(`git diff --cached -- "${file}"`, { encoding: "utf8" });
        if (stagedDiff.trim()) {
          console.log(`${GREEN}✓ ${file}${RESET}`);
          // Show summary stats
          const additions = (stagedDiff.match(/^\+[^+]/gm) || []).length;
          const deletions = (stagedDiff.match(/^-[^-]/gm) || []).length;
          console.log(`  ${GREEN}+${additions}${RESET} ${RED}-${deletions}${RESET} lines\n`);

          // Show the actual changes (truncated)
          const lines = stagedDiff.split("\n").slice(0, 30);
          for (const line of lines) {
            if (line.startsWith("+") && !line.startsWith("+++")) {
              console.log(`  ${GREEN}${line}${RESET}`);
            } else if (line.startsWith("-") && !line.startsWith("---")) {
              console.log(`  ${RED}${line}${RESET}`);
            }
          }
          if (stagedDiff.split("\n").length > 30) {
            console.log(`  ${DIM}... (truncated)${RESET}`);
          }
          console.log();
        }
      }
    } catch {}

    // Compare to plan
    const plannedFile = plan.find(p => p.path === file);
    if (plannedFile) {
      console.log(`  ${DIM}Plan: ${plannedFile.action} - ${plannedFile.reason}${RESET}`);
      if (plannedFile.changes) {
        for (const c of plannedFile.changes) {
          console.log(`  ${DIM}  • ${c.type}: ${c.description}${RESET}`);
        }
      }
      console.log();
    }
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
  help: "Resolve drift by analyzing with Claude and applying recommended changes",
  args: "[--manual] [--dry-run] [file...]",
  async run(args) {
    const { values, positionals } = parseArgs(args, {
      "manual": { type: "boolean", short: "m" },  // Skip AI, manual mode
      "dry-run": { type: "boolean", short: "n" },  // Show plan without applying
      "json": { type: "boolean", short: "j" },  // Output JSON only
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

    // === SECTION 1: SITUATION ===
    console.log(`${CYAN}${BOLD}━━━ SITUATION ━━━${RESET}\n`);
    console.log(`Branch: ${CYAN}${branch}${RESET}`);
    console.log(`Drifted files: ${YELLOW}${filesToResolve.length}${RESET}\n`);

    for (const f of filesToResolve) {
      console.log(`  ${YELLOW}⚠${RESET}  ${f.path}`);
      console.log(`    ${DIM}Added here, modified in: ${f.modifiedIn.join(" → ")}${RESET}`);
    }
    console.log();

    // Default: AI-assisted analysis
    if (!values["manual"]) {
      console.log(`${CYAN}${BOLD}━━━ PLAN (analyzing with Claude) ━━━${RESET}\n`);

      // Get diffs for each file
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

      // PHASE 1: Send only diffs to get recommendations
      const phase1Prompt = `You are helping with "append-only" development in a stacked PR workflow.

CONTEXT:
- Current branch: "${branch}"
- This branch adds code that gets modified in later branches
- Goal: Minimize churn by using the FINAL version of code from the start

I'm showing you the DIFFS for each file (- = current branch, + = final version).

YOUR TASK:
Analyze each diff and recommend an action:
- REPLACE_FILE: The whole file should use the final version (simple case)
- APPLY_CHANGES: Only some changes should be applied (cherry-pick beneficial changes, skip purely additive downstream code)
- SKIP: Current version is fine, changes are all additive

Output JSON:
{
  "files": [
    {
      "path": "file/path.ts",
      "action": "REPLACE_FILE" | "APPLY_CHANGES" | "SKIP",
      "reason": "brief explanation",
      "changes": [
        {"type": "rename|refactor|remove", "description": "what changed"}
      ]
    }
  ],
  "summary": "one sentence"
}

DIFFS:
${fileDiffs.map((fd, i) => `
=== FILE ${i + 1}: ${fd.file} ===
${fd.diff}
`).join("\n---\n")}`;

      // Phase 1: Get recommendations
      const tmpPrompt = `/tmp/stack-resolve-prompt.txt`;
      fs.writeFileSync(tmpPrompt, phase1Prompt);

      let phase1Output = "";
      try {
        phase1Output = execSync(`claude -p < "${tmpPrompt}"`, {
          encoding: "utf8",
          maxBuffer: 10 * 1024 * 1024,
          timeout: 120000,
        });
      } catch (e: any) {
        console.error(`${RED}Failed to run claude CLI${RESET}`);
        console.log(`${DIM}Error: ${e.message}${RESET}`);
        try { fs.unlinkSync(tmpPrompt); } catch {}
        return;
      }
      try { fs.unlinkSync(tmpPrompt); } catch {}

      // Parse Phase 1 response
      const phase1Match = phase1Output.match(/\{[\s\S]*"files"[\s\S]*\}/);
      if (!phase1Match) {
        console.log(`${YELLOW}Claude's response:${RESET}\n${phase1Output}`);
        return;
      }

      let phase1Recs: { path: string; action: string; reason: string; changes?: any[] }[];
      let phase1Summary = "";
      try {
        const parsed = JSON.parse(phase1Match[0]);
        phase1Recs = parsed.files || [];
        phase1Summary = parsed.summary || "";
      } catch {
        console.log(`${YELLOW}Could not parse response:${RESET}\n${phase1Output}`);
        return;
      }

      // Show Claude's analysis
      console.log(`${CYAN}${BOLD}Claude's Analysis:${RESET}\n`);
      if (phase1Summary) console.log(`${phase1Summary}\n`);

      for (const rec of phase1Recs) {
        const color = rec.action === "SKIP" ? DIM : rec.action === "REPLACE_FILE" ? GREEN : YELLOW;
        const icon = rec.action === "SKIP" ? "○" : rec.action === "REPLACE_FILE" ? "✓" : "△";
        console.log(`${color}${icon} ${rec.path}${RESET} - ${rec.action}`);
        console.log(`  ${DIM}${rec.reason}${RESET}`);
        if (rec.changes) {
          for (const c of rec.changes) {
            console.log(`  • ${c.type}: ${c.description}`);
          }
        }
        console.log();
      }

      // Filter to files that need changes
      const filesToChange = phase1Recs.filter(r => r.action !== "SKIP");

      if (filesToChange.length === 0) {
        console.log(`${GREEN}✓ No changes needed${RESET}`);
        return;
      }

      // PHASE 2: For files needing changes, get the actual modified content
      console.log(`\n${CYAN}Generating code for ${filesToChange.length} file(s)...${RESET}\n`);

      const phase2Files: { path: string; currentContent: string; finalContent: string; rec: typeof phase1Recs[0] }[] = [];

      for (const rec of filesToChange) {
        const fd = fileDiffs.find(f => f.file === rec.path);
        if (!fd) continue;

        try {
          const currentContent = fs.readFileSync(rec.path, "utf8");
          const finalContent = git(`show ${fd.finalBranch}:"${rec.path}"`);
          phase2Files.push({ path: rec.path, currentContent, finalContent, rec });
        } catch {}
      }

      const phase2Prompt = `Generate the modified file content based on these recommendations.

For each file, I'll give you:
- The recommendation from Phase 1
- The current file content
- The final file content

YOUR TASK:
Generate the newFileContent for each file:
- For REPLACE_FILE: Use the final version exactly
- For APPLY_CHANGES: Apply only the beneficial changes (renames, refactors, removals) but skip purely additive downstream code

Output JSON:
{
  "files": [
    {
      "path": "file/path.ts",
      "newFileContent": "the complete file content to use"
    }
  ]
}

FILES:
${phase2Files.map(f => `
=== ${f.path} ===
RECOMMENDATION: ${f.rec.action}
REASON: ${f.rec.reason}
CHANGES TO APPLY: ${JSON.stringify(f.rec.changes || [])}

CURRENT:
${f.currentContent}

FINAL:
${f.finalContent}
`).join("\n---\n")}`;

      fs.writeFileSync(tmpPrompt, phase2Prompt);

      let phase2Output = "";
      try {
        phase2Output = execSync(`claude -p < "${tmpPrompt}"`, {
          encoding: "utf8",
          maxBuffer: 10 * 1024 * 1024,
          timeout: 180000,
        });
      } catch (e: any) {
        console.error(`${RED}Phase 2 failed${RESET}`);
        console.log(`${DIM}Error: ${e.message}${RESET}`);
        try { fs.unlinkSync(tmpPrompt); } catch {}
        return;
      }
      try { fs.unlinkSync(tmpPrompt); } catch {}

      // Parse Phase 2 response
      const phase2Match = phase2Output.match(/\{[\s\S]*"files"[\s\S]*\}/);
      if (!phase2Match) {
        console.log(`${YELLOW}Phase 2 response:${RESET}\n${phase2Output}`);
        return;
      }

      let phase2Results: { path: string; newFileContent: string }[];
      try {
        const parsed = JSON.parse(phase2Match[0]);
        phase2Results = parsed.files || [];
      } catch {
        console.log(`${YELLOW}Could not parse Phase 2 response${RESET}`);
        return;
      }

      // Merge Phase 1 and Phase 2 results
      const claudeOutput = JSON.stringify({
        files: phase1Recs.map(rec => {
          const phase2 = phase2Results.find(p => p.path === rec.path);
          return { ...rec, newFileContent: phase2?.newFileContent };
        }),
        summary: phase1Summary,
      });

      // Try to parse JSON from Claude's response
      type FileRec = {
        path: string;
        action: "REPLACE_FILE" | "APPLY_CHANGES" | "SKIP";
        reason: string;
        changes?: { type: string; description: string; oldCode?: string; newCode?: string }[];
        newFileContent?: string;  // The actual code to use
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

        // Files with newFileContent can be applied (either REPLACE_FILE or APPLY_CHANGES)
        if ((rec.action === "REPLACE_FILE" || rec.action === "APPLY_CHANGES") && rec.newFileContent) {
          filesToReplace.push({ path: rec.path, rec });
        } else if (rec.action === "APPLY_CHANGES" && !rec.newFileContent) {
          console.log(`  ${YELLOW}⚠ No newFileContent provided - cannot apply${RESET}`);
          filesToSkip.push({ path: rec.path, rec });
        } else {
          filesToSkip.push({ path: rec.path, rec });
        }
      }

      // Summary
      console.log(`${CYAN}━━━ Summary ━━━${RESET}`);
      console.log(`  ${GREEN}Apply: ${filesToReplace.length}${RESET} file(s)`);
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
      const answer = await prompt(`${YELLOW}Apply changes to ${filesToReplace.length} file(s)?${RESET} [y/n/v] `);

      if (answer === "v" || answer === "view") {
        // Open each file in diff view - comparing current to Claude's recommended version
        for (const { path, rec } of filesToReplace) {
          const tmpNew = `/tmp/stack-resolve-new.ts`;
          fs.writeFileSync(tmpNew, rec.newFileContent || "");

          console.log(`\n${CYAN}Viewing: ${path}${RESET}`);
          console.log(`${DIM}Left: current | Right: Claude's recommendation${RESET}`);
          try {
            execSync(`nvim -d "${path}" "${tmpNew}" -c "wincmd l | set readonly | set nomodifiable | wincmd h"`, { stdio: "inherit" });
          } catch {}
          try { fs.unlinkSync(tmpNew); } catch {}
        }

        const confirmAnswer = await prompt(`\n${YELLOW}Apply the changes?${RESET} [y/n] `);
        if (confirmAnswer !== "y" && confirmAnswer !== "yes") {
          console.log(`${DIM}Aborted.${RESET}`);
          return;
        }
      } else if (answer !== "y" && answer !== "yes") {
        console.log(`${DIM}Aborted.${RESET}`);
        return;
      }

      // Apply the changes using Claude's newFileContent
      const appliedFiles: string[] = [];
      for (const { path, rec } of filesToReplace) {
        if (!rec.newFileContent) {
          console.error(`${RED}✗ No content for ${path}${RESET}`);
          continue;
        }

        try {
          fs.writeFileSync(path, rec.newFileContent);
          appliedFiles.push(path);
          console.log(`${GREEN}✓ Applied changes to ${path}${RESET}`);
        } catch (e: any) {
          console.error(`${RED}✗ Failed to update ${path}: ${e.message}${RESET}`);
        }
      }

      if (appliedFiles.length === 0) {
        console.log(`${YELLOW}No files could be replaced.${RESET}`);
        return;
      }

      // Stage files
      for (const file of appliedFiles) {
        execSync(`git add "${file}"`, { stdio: "inherit" });
      }

      // Show what changed vs the plan
      showChangeSummary(appliedFiles, phase1Recs);

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
