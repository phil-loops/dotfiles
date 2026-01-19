import type { Command } from "../types.ts";
import { currentBranch, getChainFromRoot, git, loadStack } from "../lib.ts";
import { parseArgs } from "../args.ts";

export const command: Command = {
  category: "nav",
  name: "step",
  help: "Move to next branch and show diff summary",
  args: "[--back]",
  run(args) {
    const { values } = parseArgs(args, {
      back: { type: "boolean", short: "b" },
    });
    const branch = currentBranch();
    const stack = loadStack();

    if (Object.keys(stack).length === 0) {
      console.error("No branches tracked");
      process.exit(1);
    }

    const chain = getChainFromRoot(stack, branch);

    // Find root
    const allParents = new Set(Object.values(stack));
    const allChildren = new Set(Object.keys(stack));
    const root = [...allParents].find((p) => !allChildren.has(p)) || "main";

    // Include root at the beginning for navigation
    const fullChain = [root, ...chain];
    const currentIdx = fullChain.indexOf(branch);

    if (currentIdx === -1) {
      console.error(`Current branch "${branch}" not in stack`);
      process.exit(1);
    }

    const nextIdx = values.back ? currentIdx - 1 : currentIdx + 1;

    if (nextIdx < 0) {
      console.log("Already at the root of the stack");
      process.exit(0);
    }

    if (nextIdx >= fullChain.length) {
      console.log("Already at the end of the stack");
      process.exit(0);
    }

    const targetBranch = fullChain[nextIdx];
    const parentBranch = nextIdx > 0 ? fullChain[nextIdx - 1] : null;

    git(`checkout ${targetBranch}`);

    console.log(`\n→ ${targetBranch} (${nextIdx}/${fullChain.length - 1})`);
    console.log("─".repeat(40));

    if (parentBranch) {
      // Show diff stats
      try {
        const stat = git(`diff --stat ${parentBranch}...${targetBranch}`);
        if (stat) {
          console.log(stat);
        } else {
          console.log("(no changes from parent)");
        }
      } catch {
        console.log("(could not compute diff)");
      }

      // Show changed functions (rough heuristic - look for function/class definitions)
      console.log("\nKey changes:");
      try {
        const diff = git(`diff ${parentBranch}...${targetBranch} -U0`);
        const changes = extractKeyChanges(diff);
        if (changes.length > 0) {
          changes.slice(0, 10).forEach((c) => console.log(`  ${c}`));
          if (changes.length > 10) {
            console.log(`  ... and ${changes.length - 10} more`);
          }
        } else {
          console.log("  (none detected)");
        }
      } catch {
        console.log("  (could not extract)");
      }
    } else {
      console.log("(root branch)");
    }

    console.log();
  },
};

function extractKeyChanges(diff: string): string[] {
  const changes: string[] = [];
  const seen = new Set<string>();

  const patterns = [
    // TypeScript/JavaScript
    /^\+\s*(export\s+)?(async\s+)?function\s+(\w+)/,
    /^\+\s*(export\s+)?(const|let|var)\s+(\w+)\s*=\s*(async\s+)?\(/,
    /^\+\s*(export\s+)?class\s+(\w+)/,
    /^\+\s*(export\s+)?(const|let|var)\s+(\w+)\s*=\s*\{/,
    // SQL
    /^\+\s*CREATE\s+(TABLE|INDEX|UNIQUE INDEX)\s+(?:IF NOT EXISTS\s+)?"?(\w+)"?/i,
    /^\+\s*ALTER\s+TABLE\s+"?(\w+)"?/i,
    // Python
    /^\+\s*def\s+(\w+)/,
    /^\+\s*class\s+(\w+)/,
    // Go
    /^\+\s*func\s+(\w+|\(\w+\s+\*?\w+\)\s+\w+)/,
    // Rust
    /^\+\s*(pub\s+)?fn\s+(\w+)/,
    /^\+\s*(pub\s+)?struct\s+(\w+)/,
  ];

  for (const line of diff.split("\n")) {
    for (const pattern of patterns) {
      const match = line.match(pattern);
      if (match) {
        // Get the most meaningful capture group
        const name = match[match.length - 1] || match[match.length - 2];
        if (name && !seen.has(name)) {
          seen.add(name);
          // Clean up the line for display
          const cleaned = line.slice(1).trim().slice(0, 60);
          changes.push(cleaned + (line.length > 61 ? "..." : ""));
        }
        break;
      }
    }
  }

  return changes;
}
