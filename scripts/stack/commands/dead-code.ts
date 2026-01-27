import type { Command } from "../types.ts";
import { currentBranch, git, loadStack } from "../lib.ts";
import { execSync } from "child_process";

interface ExportedSymbol {
  name: string;
  type: "function" | "const" | "class" | "type" | "interface" | "enum";
  file: string;
  line: number;
}

interface DeadCodeResult {
  symbol: ExportedSymbol;
  usageCount: number;
  usageFiles: string[];
}

export const command: Command = {
  category: "util",
  name: "dead-code",
  help: "Find potentially unused exports in branch changes",
  args: "[branch] [--verbose]",
  run(args) {
    const verbose = args.includes("--verbose") || args.includes("-v");
    const branchArg = args.find((a) => !a.startsWith("-"));

    const stack = loadStack();
    const branch = branchArg || currentBranch();

    if (!stack[branch]) {
      console.error(`Branch "${branch}" not tracked in stack`);
      process.exit(1);
    }

    // Find the root (main) by walking up the stack
    let base = stack[branch];
    while (stack[base]) {
      base = stack[base];
    }

    console.log(`\n🔍 Analyzing exports in ${branch} (vs ${base})\n`);

    // Get changed files
    const changedFiles = getChangedFiles(base, branch);
    const tsFiles = changedFiles.filter(
      (f) => f.endsWith(".ts") || f.endsWith(".tsx")
    );

    if (tsFiles.length === 0) {
      console.log("No TypeScript files changed in this branch.");
      return;
    }

    if (verbose) {
      console.log(`Changed TS files: ${tsFiles.length}`);
      tsFiles.forEach((f) => console.log(`  ${f}`));
      console.log();
    }

    // Get the diff and extract new exports
    const exports = extractNewExports(base, branch, tsFiles);

    if (exports.length === 0) {
      console.log("No new exports detected in this branch.");
      return;
    }

    console.log(`Found ${exports.length} new export(s):\n`);

    // Check each export for usages
    const results: DeadCodeResult[] = [];

    for (const exp of exports) {
      const { count, files } = findUsages(exp.name, exp.file);
      results.push({
        symbol: exp,
        usageCount: count,
        usageFiles: files,
      });
    }

    // Report results
    const deadCode = results.filter((r) => r.usageCount === 0);
    const usedCode = results.filter((r) => r.usageCount > 0);

    if (deadCode.length > 0) {
      console.log(`⚠️  Potentially unused (${deadCode.length}):\n`);
      for (const r of deadCode) {
        console.log(
          `  ${r.symbol.type} ${r.symbol.name}`
        );
        console.log(`    └─ ${r.symbol.file.replace(/^b\//, "")}:${r.symbol.line}`);
      }
      console.log();
    }

    if (usedCode.length > 0) {
      console.log(`✅ Used exports (${usedCode.length}):\n`);
      for (const r of usedCode) {
        const fileList =
          r.usageFiles.length <= 3
            ? r.usageFiles.join(", ")
            : `${r.usageFiles.slice(0, 3).join(", ")} +${r.usageFiles.length - 3} more`;
        console.log(
          `  ${r.symbol.type} ${r.symbol.name} (${r.usageCount} usage${r.usageCount === 1 ? "" : "s"})`
        );
        if (verbose) {
          console.log(`    └─ defined: ${r.symbol.file}:${r.symbol.line}`);
          console.log(`    └─ used in: ${fileList}`);
        }
      }
      console.log();
    }

    // Summary
    if (deadCode.length === 0) {
      console.log("🎉 All new exports appear to be used!");
    } else {
      console.log(
        `\n📊 Summary: ${deadCode.length}/${exports.length} exports may be unused`
      );
    }
  },
};

function getChangedFiles(parent: string, branch: string): string[] {
  try {
    const output = git(`diff --name-only ${parent}...${branch}`);
    return output.split("\n").filter(Boolean);
  } catch {
    return [];
  }
}

function extractNewExports(
  parent: string,
  branch: string,
  files: string[]
): ExportedSymbol[] {
  const exports: ExportedSymbol[] = [];

  // Patterns to match exported symbols
  const patterns = [
    // export function name
    {
      regex: /^export\s+(async\s+)?function\s+(\w+)/,
      type: "function" as const,
      nameGroup: 2,
    },
    // export const/let/var name
    {
      regex: /^export\s+(?:const|let|var)\s+(\w+)/,
      type: "const" as const,
      nameGroup: 1,
    },
    // export class name
    {
      regex: /^export\s+class\s+(\w+)/,
      type: "class" as const,
      nameGroup: 1,
    },
    // export type name
    {
      regex: /^export\s+type\s+(\w+)/,
      type: "type" as const,
      nameGroup: 1,
    },
    // export interface name
    {
      regex: /^export\s+interface\s+(\w+)/,
      type: "interface" as const,
      nameGroup: 1,
    },
    // export enum name
    {
      regex: /^export\s+enum\s+(\w+)/,
      type: "enum" as const,
      nameGroup: 1,
    },
    // export default function name
    {
      regex: /^export\s+default\s+(async\s+)?function\s+(\w+)/,
      type: "function" as const,
      nameGroup: 2,
    },
    // export default class name
    {
      regex: /^export\s+default\s+class\s+(\w+)/,
      type: "class" as const,
      nameGroup: 1,
    },
  ];

  try {
    const diff = git(`diff ${parent}...${branch} -- ${files.join(" ")}`);
    const lines = diff.split("\n");

    let currentFile = "";
    let currentLineNum = 0;
    let lineOffset = 0;

    for (const line of lines) {
      // Track file changes
      if (line.startsWith("diff --git")) {
        const match = line.match(/b\/(.+)$/);
        if (match) currentFile = match[1]; // Already strips the b/ prefix
        continue;
      }

      // Track line numbers from hunk headers
      if (line.startsWith("@@")) {
        const match = line.match(/@@ .+ \+(\d+)/);
        if (match) {
          currentLineNum = parseInt(match[1], 10);
          lineOffset = 0;
        }
        continue;
      }

      // Only look at added lines
      if (line.startsWith("+") && !line.startsWith("+++")) {
        const content = line.slice(1).trim();

        for (const pattern of patterns) {
          const match = content.match(pattern.regex);
          if (match) {
            const name = match[pattern.nameGroup];
            // Skip if we already have this export
            if (!exports.some((e) => e.name === name && e.file === currentFile)) {
              exports.push({
                name,
                type: pattern.type,
                file: currentFile,
                line: currentLineNum + lineOffset,
              });
            }
            break;
          }
        }
        lineOffset++;
      } else if (line.startsWith(" ")) {
        lineOffset++;
      }
    }
  } catch (e) {
    console.error("Error parsing diff:", e);
  }

  return exports;
}

function findUsages(
  symbolName: string,
  definitionFile: string
): { count: number; files: string[] } {
  try {
    // Use ripgrep to find usages
    // Search for the symbol as a word boundary to avoid partial matches
    // Use glob patterns for ts/tsx files since --type tsx isn't built-in
    const result = execSync(
      `rg -l -g '*.ts' -g '*.tsx' "\\b${symbolName}\\b" 2>/dev/null || true`,
      { encoding: "utf-8", maxBuffer: 10 * 1024 * 1024 }
    );

    // Clean up the definition file path (remove b/ prefix if present)
    const cleanDefFile = definitionFile.replace(/^b\//, "");

    const files = result
      .split("\n")
      .filter(Boolean)
      .filter((f) => !f.endsWith(cleanDefFile) && !f.includes(cleanDefFile));

    // Get actual count of usages (not just files)
    let count = 0;
    if (files.length > 0) {
      try {
        const countResult = execSync(
          `rg -c -g '*.ts' -g '*.tsx' "\\b${symbolName}\\b" ${files.map(f => `"${f}"`).join(" ")} 2>/dev/null || true`,
          { encoding: "utf-8", maxBuffer: 10 * 1024 * 1024 }
        );
        for (const line of countResult.split("\n").filter(Boolean)) {
          const match = line.match(/:(\d+)$/);
          if (match) count += parseInt(match[1], 10);
        }
      } catch {
        count = files.length; // Fallback to file count
      }
    }

    return { count, files };
  } catch {
    return { count: 0, files: [] };
  }
}
