import type { Command } from "../types.ts";
import { currentBranch, git, loadStack } from "../lib.ts";
import { execSync } from "child_process";

interface ExportedSymbol {
  name: string;
  file: string;
  line: number;
  isDefault: boolean;
}

interface DeadCodeResult {
  symbol: ExportedSymbol;
  usageCount: number;
}

export const command: Command = {
  category: "util",
  name: "dead-code",
  help: "Find unused exports (optionally scoped to feature branch)",
  args: "[--branch] [--all] [--verbose]",
  run(args) {
    const verbose = args.includes("--verbose") || args.includes("-v");
    const scanAll = args.includes("--all") || args.includes("-a");
    const branchScoped = args.includes("--branch") || args.includes("-b");

    let filesToScan: string[] = [];
    let scopeDescription = "codebase";

    if (branchScoped) {
      // Scope to files changed in the feature branch vs main
      const stack = loadStack();
      const branch = currentBranch();

      if (!stack[branch]) {
        console.error(`Branch "${branch}" not tracked in stack`);
        process.exit(1);
      }

      // Find the root (main) by walking up the stack
      let base = stack[branch];
      while (stack[base]) {
        base = stack[base];
      }

      filesToScan = getChangedFiles(base, branch).filter(
        (f) => f.endsWith(".ts") || f.endsWith(".tsx")
      );
      scopeDescription = `feature branch (${branch} vs ${base})`;

      if (filesToScan.length === 0) {
        console.log("No TypeScript files changed in this feature branch.");
        return;
      }
    } else {
      // Scan common source directories
      filesToScan = findTypeScriptFiles();
    }

    console.log(`\n🔍 Scanning for unused exports in ${scopeDescription}\n`);

    if (verbose) {
      console.log(`Files to scan: ${filesToScan.length}`);
    }

    // Extract all exports from the files
    const allExports = extractExports(filesToScan);

    if (allExports.length === 0) {
      console.log("No exports found.");
      return;
    }

    console.log(`Found ${allExports.length} exports, checking usage...\n`);

    // Check each export for usages
    const results: DeadCodeResult[] = [];
    let checked = 0;

    for (const exp of allExports) {
      const count = countUsages(exp.name, exp.file, exp.isDefault);
      results.push({ symbol: exp, usageCount: count });
      checked++;

      // Progress indicator
      if (checked % 50 === 0) {
        process.stdout.write(`\r  Checked ${checked}/${allExports.length}...`);
      }
    }
    process.stdout.write(`\r  Checked ${allExports.length}/${allExports.length}   \n\n`);

    // Filter to unused (or limit results if not --all)
    const deadCode = results.filter((r) => r.usageCount === 0);
    const displayResults = scanAll ? deadCode : deadCode.slice(0, 30);

    if (deadCode.length === 0) {
      console.log("🎉 No unused exports detected!");
      return;
    }

    console.log(`⚠️  Potentially unused exports (${deadCode.length}):\n`);

    for (const r of displayResults) {
      const defaultMarker = r.symbol.isDefault ? " (default)" : "";
      console.log(`  ${r.symbol.name}${defaultMarker}`);
      console.log(`    └─ ${r.symbol.file}:${r.symbol.line}`);
    }

    if (!scanAll && deadCode.length > 30) {
      console.log(`\n  ... and ${deadCode.length - 30} more (use --all to see all)`);
    }

    console.log(`\n📊 Summary: ${deadCode.length} potentially unused exports`);
  },
};

function getChangedFiles(base: string, branch: string): string[] {
  try {
    const output = git(`diff --name-only ${base}...${branch}`);
    return output.split("\n").filter(Boolean);
  } catch {
    return [];
  }
}

function findTypeScriptFiles(): string[] {
  try {
    // Find TS files in common source directories, excluding node_modules, .next, etc.
    const result = execSync(
      `find . -type f \\( -name "*.ts" -o -name "*.tsx" \\) \
        -not -path "*/node_modules/*" \
        -not -path "*/.next/*" \
        -not -path "*/dist/*" \
        -not -path "*/.git/*" \
        -not -path "*/coverage/*" \
        -not -name "*.d.ts" \
        2>/dev/null | head -2000`,
      { encoding: "utf-8", maxBuffer: 10 * 1024 * 1024 }
    );
    return result.split("\n").filter(Boolean).map((f) => f.replace(/^\.\//, ""));
  } catch {
    return [];
  }
}

function extractExports(files: string[]): ExportedSymbol[] {
  const exports: ExportedSymbol[] = [];

  // Patterns to match exported symbols
  const patterns = [
    // export function name / export async function name
    { regex: /^export\s+(async\s+)?function\s+(\w+)/, nameGroup: 2, isDefault: false },
    // export const/let/var name
    { regex: /^export\s+(?:const|let|var)\s+(\w+)/, nameGroup: 1, isDefault: false },
    // export class name
    { regex: /^export\s+class\s+(\w+)/, nameGroup: 1, isDefault: false },
    // export type name
    { regex: /^export\s+type\s+(\w+)/, nameGroup: 1, isDefault: false },
    // export interface name
    { regex: /^export\s+interface\s+(\w+)/, nameGroup: 1, isDefault: false },
    // export enum name
    { regex: /^export\s+enum\s+(\w+)/, nameGroup: 1, isDefault: false },
    // export default function name
    { regex: /^export\s+default\s+(async\s+)?function\s+(\w+)/, nameGroup: 2, isDefault: true },
    // export default class name
    { regex: /^export\s+default\s+class\s+(\w+)/, nameGroup: 1, isDefault: true },
  ];

  for (const file of files) {
    try {
      const content = execSync(`cat "${file}" 2>/dev/null`, {
        encoding: "utf-8",
        maxBuffer: 5 * 1024 * 1024,
      });

      const lines = content.split("\n");
      for (let i = 0; i < lines.length; i++) {
        const line = lines[i].trim();

        for (const pattern of patterns) {
          const match = line.match(pattern.regex);
          if (match) {
            const name = match[pattern.nameGroup];
            // Skip common false positives
            if (shouldSkip(name, file)) continue;

            exports.push({
              name,
              file,
              line: i + 1,
              isDefault: pattern.isDefault,
            });
            break;
          }
        }
      }
    } catch {
      // Skip files that can't be read
    }
  }

  return exports;
}

function shouldSkip(name: string, file: string): boolean {
  // Skip test files
  if (file.includes(".test.") || file.includes(".spec.") || file.includes("__tests__")) {
    return true;
  }

  // Skip common Next.js page exports
  if (name === "getServerSideProps" || name === "getStaticProps" || name === "getStaticPaths") {
    return true;
  }

  // Skip common React exports that are used by framework
  if (name === "metadata" || name === "generateMetadata") {
    return true;
  }

  // Skip if it's a page/layout default export (used by Next.js routing)
  if (file.includes("/pages/") || file.includes("/app/")) {
    if (name.endsWith("Page") || name.endsWith("Layout")) {
      return true;
    }
  }

  return false;
}

function countUsages(symbolName: string, definitionFile: string, _isDefault: boolean): number {
  try {
    // Simple word-boundary search for the symbol name
    // Escape any regex special chars in the symbol name
    const escapedName = symbolName.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");

    const result = execSync(
      `rg -c -g '*.ts' -g '*.tsx' '\\b${escapedName}\\b' 2>/dev/null || true`,
      { encoding: "utf-8", maxBuffer: 10 * 1024 * 1024 }
    );

    let totalCount = 0;
    const defFileBase = definitionFile.replace(/\.[^.]+$/, ""); // Remove extension

    for (const line of result.split("\n").filter(Boolean)) {
      const match = line.match(/^(.+):(\d+)$/);
      if (match) {
        const file = match[1];
        const count = parseInt(match[2], 10);

        // Don't count usages in the definition file itself
        if (file === definitionFile || file.replace(/\.[^.]+$/, "") === defFileBase) {
          continue;
        }

        totalCount += count;
      }
    }

    return totalCount;
  } catch {
    return 0;
  }
}

