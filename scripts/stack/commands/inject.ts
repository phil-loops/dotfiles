import { execSync, spawnSync } from "child_process";
import { writeFileSync, mkdtempSync, rmSync } from "fs";
import { tmpdir } from "os";
import { join } from "path";
import { git, getStackBranches, type StackBranch } from "../lib/stack-config.ts";

interface FilePatch {
  file: string;
  patch: string;
  isNew: boolean;
}

interface InjectionDecision {
  file: string;
  targetBranch: string;
  reasoning: string;
  confidence: "high" | "medium" | "low";
}

function getPatches(): FilePatch[] {
  const patches: FilePatch[] = [];

  // Get list of changed files
  const status = git("status --porcelain");
  if (!status) return patches;

  const files = new Set<string>();
  for (const line of status.split("\n")) {
    if (!line.trim()) continue;
    const statusCode = line.substring(0, 2);
    const file = line.substring(3).trim();

    // Handle renames
    if (file.includes(" -> ")) {
      files.add(file.split(" -> ")[1]);
    } else {
      files.add(file);
    }

    // Track new files
    if (statusCode.includes("?") || statusCode.includes("A")) {
      // For new files, read the content as a "patch"
      try {
        const content = execSync(`cat "${file}"`, { encoding: "utf-8" });
        patches.push({
          file,
          patch: `+++ ${file} (new file)\n${content}`,
          isNew: true,
        });
      } catch {
        // File might not exist or be readable
      }
    }
  }

  // Get diffs for modified files
  const diff = git("diff");
  if (diff) {
    let currentFile = "";
    let currentPatch = "";

    for (const line of diff.split("\n")) {
      if (line.startsWith("diff --git")) {
        // Save previous patch
        if (currentFile && currentPatch) {
          // Don't duplicate new files
          if (!patches.find((p) => p.file === currentFile)) {
            patches.push({ file: currentFile, patch: currentPatch, isNew: false });
          }
        }
        const match = line.match(/diff --git a\/(.+) b\//);
        currentFile = match ? match[1] : "";
        currentPatch = line + "\n";
      } else {
        currentPatch += line + "\n";
      }
    }

    // Don't forget last file
    if (currentFile && currentPatch) {
      if (!patches.find((p) => p.file === currentFile)) {
        patches.push({ file: currentFile, patch: currentPatch, isNew: false });
      }
    }
  }

  return patches;
}

function buildStackSummary(stack: StackBranch[]): string {
  const lines: string[] = ["Branch stack (in order from base to tip):"];

  for (let i = 0; i < stack.length; i++) {
    const branch = stack[i];
    // Get commit messages for this branch
    const parent = i === 0 ? "main" : stack[i - 1].name;
    const commits = git(`log --oneline ${parent}..${branch.name} 2>/dev/null`) || "(no commits)";
    const firstCommit = commits.split("\n")[0] || "(empty)";

    lines.push(`  ${String(i + 1).padStart(2, "0")}. ${branch.name}`);
    lines.push(`      ${firstCommit}`);
  }

  return lines.join("\n");
}

function buildPatchSummary(patches: FilePatch[]): string {
  const lines: string[] = ["Files changed:"];

  for (const patch of patches) {
    const lineCount = patch.patch.split("\n").length;
    const status = patch.isNew ? "(new)" : "(modified)";
    lines.push(`  - ${patch.file} ${status} (~${lineCount} lines)`);
  }

  return lines.join("\n");
}

async function analyzeWithClaude(
  patch: FilePatch,
  allPatches: FilePatch[],
  stack: StackBranch[],
  featureDescription: string
): Promise<InjectionDecision> {
  const stackSummary = buildStackSummary(stack);
  const patchSummary = buildPatchSummary(allPatches);

  const prompt = `You are analyzing a code change to determine which branch in a stacked PR workflow it should be applied to.

## Feature Overview
${featureDescription}

## Branch Stack
${stackSummary}

## All Patches in This Change Set
${patchSummary}

## Specific Patch to Analyze
File: ${patch.file}
${patch.isNew ? "(This is a NEW file)" : "(This is a MODIFIED file)"}

\`\`\`diff
${patch.patch.slice(0, 8000)}${patch.patch.length > 8000 ? "\n... (truncated)" : ""}
\`\`\`

## Task
Determine which branch this patch should be applied to. Consider:
1. The file path and what layer it represents (schema, queries, logic, jobs, UI, etc.)
2. The content of the changes and what they depend on
3. The branch naming conventions and what each branch likely contains

Respond with ONLY a JSON object (no markdown, no explanation outside the JSON):
{
  "targetBranch": "exact-branch-name-from-list",
  "reasoning": "Brief explanation of why this branch",
  "confidence": "high" | "medium" | "low"
}

If the change should go on the CURRENT branch (tip of stack), use the last branch in the list.
If you're unsure, use "low" confidence and pick the most likely branch.`;

  // Write prompt to temp file
  const tmpDir = mkdtempSync(join(tmpdir(), "inject-"));
  const promptFile = join(tmpDir, "prompt.txt");
  writeFileSync(promptFile, prompt);

  try {
    // Call Claude CLI
    const result = spawnSync(
      "claude",
      ["-p", prompt, "--output-format", "text"],
      {
        encoding: "utf-8",
        timeout: 60000,
        maxBuffer: 10 * 1024 * 1024,
      }
    );

    if (result.error) {
      console.error(`  Claude CLI error: ${result.error.message}`);
      return {
        file: patch.file,
        targetBranch: stack[stack.length - 1].name,
        reasoning: "Claude CLI failed, defaulting to current branch",
        confidence: "low",
      };
    }

    const output = result.stdout?.trim() || "";

    // Try to parse JSON from response
    try {
      // Find JSON in the response (might have extra text)
      const jsonMatch = output.match(/\{[\s\S]*\}/);
      if (jsonMatch) {
        const parsed = JSON.parse(jsonMatch[0]);
        return {
          file: patch.file,
          targetBranch: parsed.targetBranch || stack[stack.length - 1].name,
          reasoning: parsed.reasoning || "No reasoning provided",
          confidence: parsed.confidence || "low",
        };
      }
    } catch (parseErr) {
      console.error(`  Failed to parse Claude response: ${output.slice(0, 200)}`);
    }

    return {
      file: patch.file,
      targetBranch: stack[stack.length - 1].name,
      reasoning: "Could not parse Claude response",
      confidence: "low",
    };
  } finally {
    rmSync(tmpDir, { recursive: true, force: true });
  }
}

function printResults(decisions: InjectionDecision[], stack: StackBranch[]) {
  const stackOrder = new Map(stack.map((b, i) => [b.name, i]));

  // Group by target branch
  const groups = new Map<string, InjectionDecision[]>();
  for (const dec of decisions) {
    if (!groups.has(dec.targetBranch)) groups.set(dec.targetBranch, []);
    groups.get(dec.targetBranch)!.push(dec);
  }

  // Sort groups by stack order
  const sortedGroups = [...groups.entries()].sort((a, b) => {
    const orderA = stackOrder.get(a[0]) ?? 999;
    const orderB = stackOrder.get(b[0]) ?? 999;
    return orderA - orderB;
  });

  console.log("\n=== Injection Plan ===\n");

  for (const [branch, decs] of sortedGroups) {
    const branchNum = stackOrder.get(branch);
    const label = branchNum !== undefined ? `[${String(branchNum + 1).padStart(2, "0")}]` : "[??]";

    console.log(`${label} ${branch}`);
    console.log("─".repeat(60));

    for (const dec of decs) {
      const conf = dec.confidence === "high" ? "●" : dec.confidence === "medium" ? "◐" : "○";
      console.log(`  ${conf} ${dec.file}`);
      console.log(`      ${dec.reasoning}`);
    }
    console.log();
  }

  // Print workflow
  console.log("=== Apply Workflow ===\n");

  const branchesNeeded = sortedGroups.filter(([b]) => stackOrder.has(b)).map(([b]) => b);

  if (branchesNeeded.length === 0) {
    console.log("No injection targets identified.");
    return;
  }

  if (branchesNeeded.length === 1 && branchesNeeded[0] === stack[stack.length - 1].name) {
    console.log("All changes belong on current branch. Just commit them!");
    return;
  }

  console.log("1. Save patches to temp directory:");
  console.log("   loops stack inject --save\n");

  console.log("2. Reset working directory:");
  console.log("   git checkout -- .\n");

  let step = 3;
  for (const branch of branchesNeeded) {
    const files = groups.get(branch)!.map((d) => d.file);
    console.log(`${step}. Apply to ${branch}:`);
    console.log(`   git checkout ${branch}`);
    for (const file of files) {
      console.log(`   git apply /tmp/stack-patches/${file.replace(/\//g, "_")}.patch`);
    }
    console.log(`   git add -A && git commit -m "fix: apply windowKey changes"`);
    step++;
  }

  console.log(`\n${step}. Sync the stack (rebase downstream branches):`);
  console.log("   loops stack sync");

  console.log("\nLegend: ● high confidence  ◐ medium  ○ low");
}

function savePatches(patches: FilePatch[]) {
  const dir = "/tmp/stack-patches";
  execSync(`rm -rf ${dir} && mkdir -p ${dir}`);

  for (const patch of patches) {
    const safeName = patch.file.replace(/\//g, "_") + ".patch";
    writeFileSync(join(dir, safeName), patch.patch);
    console.log(`  Saved: ${dir}/${safeName}`);
  }

  console.log(`\nPatches saved to ${dir}/`);
}

export async function inject(args: string[]) {
  const prefix = args.find((a) => !a.startsWith("-"));
  const shouldSave = args.includes("--save");
  const skipClaude = args.includes("--no-claude");

  // Get feature description from .goals/docs.md or prompt
  let featureDescription = "Goals feature - tracking contact conversions via attribution windows";
  try {
    const docs = execSync("cat .goals/docs.md 2>/dev/null", { encoding: "utf-8" });
    if (docs) featureDescription = docs.slice(0, 2000);
  } catch {
    // Use default
  }

  console.log("Analyzing changes for injection...");
  if (prefix) console.log(`Stack prefix: ${prefix}`);

  // Get the stack
  const stack = getStackBranches(prefix);
  if (stack.length === 0) {
    console.error("No stack branches found.");
    process.exit(1);
  }
  console.log(`Found ${stack.length} branches in stack`);

  // Get patches
  const patches = getPatches();
  if (patches.length === 0) {
    console.log("No changes to analyze.");
    process.exit(0);
  }
  console.log(`Found ${patches.length} file(s) with changes\n`);

  // Save patches if requested
  if (shouldSave) {
    savePatches(patches);
    return;
  }

  if (skipClaude) {
    // Just show patches without Claude analysis
    for (const patch of patches) {
      console.log(`  ${patch.file} ${patch.isNew ? "(new)" : "(modified)"}`);
    }
    console.log("\nRun without --no-claude to get AI-powered injection suggestions.");
    return;
  }

  // Analyze each patch with Claude
  const decisions: InjectionDecision[] = [];

  for (const patch of patches) {
    process.stdout.write(`  Analyzing ${patch.file}...`);
    const decision = await analyzeWithClaude(patch, patches, stack, featureDescription);
    decisions.push(decision);
    console.log(` -> ${decision.targetBranch} (${decision.confidence})`);
  }

  printResults(decisions, stack);
}
