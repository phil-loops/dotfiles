import type { Command } from "../types.ts";
import { currentBranch, git, loadStack } from "../lib.ts";

interface CodeSnippet {
  file: string;
  line: number;
  code: string[];
}

export const command: Command = {
  category: "nav",
  name: "show",
  help: "Show code snippets for a branch's changes",
  args: "[branch]",
  run(args) {
    const stack = loadStack();
    const targetBranch = args[0] || currentBranch();

    // Find parent for this branch
    const parent = stack[targetBranch];
    if (!parent) {
      console.error(`Branch "${targetBranch}" not tracked in stack`);
      process.exit(1);
    }

    console.log(`\n── ${targetBranch} vs ${parent} ──────────────────────────────────\n`);

    try {
      const diff = git(`diff ${parent}...${targetBranch}`);
      const snippets = extractCodeSnippets(diff);

      if (snippets.length === 0) {
        console.log("(no key changes detected)");
        return;
      }

      for (const snippet of snippets) {
        console.log(`+ ${snippet.file}:${snippet.line}`);
        for (const line of snippet.code) {
          console.log(`  ${line}`);
        }
        console.log();
      }
    } catch {
      console.log("(could not compute diff)");
    }
  },
};

function extractCodeSnippets(diff: string): CodeSnippet[] {
  const snippets: CodeSnippet[] = [];
  const lines = diff.split("\n");

  let currentFile = "";
  let currentHunkStart = 0;
  let lineOffset = 0;

  // Patterns to identify function/class starts
  const startPatterns = [
    // TypeScript/JavaScript
    /^(export\s+)?(async\s+)?function\s+\w+/,
    /^(export\s+)?(const|let|var)\s+\w+\s*=\s*(async\s+)?\(/,
    /^(export\s+)?class\s+\w+/,
    // Python
    /^def\s+\w+/,
    /^class\s+\w+/,
    // Go
    /^func\s+\w+/,
    // Rust
    /^(pub\s+)?fn\s+\w+/,
    /^(pub\s+)?struct\s+\w+/,
  ];

  // Track which functions we've seen
  const seenFunctions = new Set<string>();

  for (let i = 0; i < lines.length; i++) {
    const line = lines[i];

    // File header
    if (line.startsWith("diff --git")) {
      const match = line.match(/b\/(.+)$/);
      if (match) {
        currentFile = match[1];
      }
      continue;
    }

    // Hunk header - captures line number
    if (line.startsWith("@@")) {
      const match = line.match(/@@ .+ \+(\d+)/);
      if (match) {
        currentHunkStart = parseInt(match[1], 10);
        lineOffset = 0;
      }
      continue;
    }

    // Added line that matches a function pattern
    if (line.startsWith("+") && !line.startsWith("+++")) {
      const content = line.slice(1); // Remove the +
      const trimmed = content.trim();

      for (const pattern of startPatterns) {
        if (pattern.test(trimmed)) {
          // Create a key to dedupe
          const funcKey = `${currentFile}:${trimmed.slice(0, 50)}`;
          if (seenFunctions.has(funcKey)) break;
          seenFunctions.add(funcKey);

          // Collect the function body (up to 15 lines)
          const codeLines: string[] = [];
          let braceDepth = 0;
          let started = false;

          for (let j = i; j < lines.length && codeLines.length < 15; j++) {
            const codeLine = lines[j];

            // Stop at next file or hunk
            if (codeLine.startsWith("diff --git") || codeLine.startsWith("@@")) {
              break;
            }

            // Only include added or context lines
            if (codeLine.startsWith("+") || codeLine.startsWith(" ")) {
              const actualCode = codeLine.slice(1);
              codeLines.push(actualCode);

              // Track brace depth to know when function ends
              for (const char of actualCode) {
                if (char === "{" || char === "(") {
                  braceDepth++;
                  started = true;
                }
                if (char === "}" || char === ")") {
                  braceDepth--;
                }
              }

              // End if we've closed all braces
              if (started && braceDepth === 0) {
                break;
              }
            }
          }

          // Add truncation indicator if needed
          if (codeLines.length === 15) {
            codeLines.push("  ...");
          }

          snippets.push({
            file: currentFile,
            line: currentHunkStart + lineOffset,
            code: codeLines,
          });

          break;
        }
      }
    }

    // Track line offset within hunk
    if (line.startsWith("+") && !line.startsWith("+++")) {
      lineOffset++;
    } else if (line.startsWith(" ")) {
      lineOffset++;
    }
  }

  return snippets;
}
