import type { Command } from "../types.ts";
import { currentBranch, git, loadStack, getCurrentStack, findRoot } from "../lib.ts";

export const command: Command = {
  category: "util",
  name: "drift",
  help: "Find .ts files modified after being added in the stack",
  run() {
    const stack = loadStack();
    const branch = currentBranch();

    if (Object.keys(stack).length === 0) {
      console.log("No branches tracked");
      return;
    }

    const currentStackBranches = getCurrentStack(stack, branch);
    if (currentStackBranches.length === 0) {
      console.log("Current branch is not in a tracked stack");
      return;
    }

    const root = findRoot(stack, branch);

    // Build ordered list: root -> ... -> leaf
    const orderedBranches = [root, ...currentStackBranches];

    // Track where each file was first introduced
    const fileIntroducedIn = new Map<string, string>();
    // Track modifications after introduction
    const drifts: Array<{ file: string; introducedIn: string; modifiedIn: string[] }> = [];

    for (let i = 1; i < orderedBranches.length; i++) {
      const parent = orderedBranches[i - 1];
      const child = orderedBranches[i];

      // Get files changed between parent and child
      const diffOutput = git(`diff --name-only ${parent}...${child}`);
      if (!diffOutput) continue;

      const files = diffOutput.split("\n").filter((f) => {
        // Only .ts files, exclude .test.ts and .tsx
        return f.endsWith(".ts") && !f.endsWith(".test.ts") && !f.endsWith(".tsx");
      });

      for (const file of files) {
        if (!fileIntroducedIn.has(file)) {
          // First time seeing this file
          fileIntroducedIn.set(file, child);
        } else {
          // File was modified again after introduction
          const introducedIn = fileIntroducedIn.get(file)!;
          let drift = drifts.find((d) => d.file === file);
          if (!drift) {
            drift = { file, introducedIn, modifiedIn: [] };
            drifts.push(drift);
          }
          drift.modifiedIn.push(child);
        }
      }
    }

    if (drifts.length === 0) {
      console.log("No drifted files found. All .ts files stay in their original branches.");
      return;
    }

    console.log(`Found ${drifts.length} file(s) modified after introduction:\n`);

    for (const { file, introducedIn, modifiedIn } of drifts) {
      console.log(`  ${file}`);
      console.log(`    Added in:    ${introducedIn}`);
      console.log(`    Modified in: ${modifiedIn.join(", ")}`);
      console.log();
    }
  },
};
