import type { Command } from "../types.ts";
import { git, loadSnapshot, loadStack } from "../lib.ts";
import { parseArgs } from "../args.ts";
import { execSync } from "child_process";

export const command: Command = {
  category: "info",
  name: "whatchanged",
  help: "Show what changed since last stack operation",
  args: "[--files] [--diff]",
  run(args) {
    const { values } = parseArgs(args, {
      files: { type: "boolean", short: "f" },
      diff: { type: "boolean", short: "d" },
    });

    const snapshot = loadSnapshot();
    if (!snapshot) {
      console.log("No snapshot found. Run 'stack update' first.");
      return;
    }

    const stack = loadStack();
    const branches = Object.keys(stack);

    console.log(`Last operation: ${snapshot.operation}`);
    console.log(`Timestamp: ${snapshot.timestamp}\n`);

    let anyChanges = false;

    for (const branch of branches) {
      const oldHash = snapshot.branches[branch];
      if (!oldHash) continue;

      let currentHash: string;
      try {
        currentHash = git(`rev-parse ${branch}`);
      } catch {
        console.log(`${branch}: (deleted)`);
        anyChanges = true;
        continue;
      }

      if (oldHash === currentHash) {
        continue; // No change
      }

      anyChanges = true;
      const shortOld = oldHash.slice(0, 8);
      const shortNew = currentHash.slice(0, 8);
      console.log(`${branch}: ${shortOld} -> ${shortNew}`);

      if (values.files || values.diff) {
        // Show files that changed
        try {
          const filesChanged = execSync(
            `git diff --name-only ${oldHash}..${currentHash}`,
            { encoding: "utf-8" }
          ).trim();

          if (filesChanged) {
            for (const file of filesChanged.split("\n")) {
              console.log(`  ${file}`);
            }
          }
        } catch {
          console.log("  (could not determine changed files)");
        }

        if (values.diff) {
          // Show actual diff
          try {
            const diff = execSync(
              `git diff --stat ${oldHash}..${currentHash}`,
              { encoding: "utf-8" }
            ).trim();
            if (diff) {
              console.log("");
              for (const line of diff.split("\n")) {
                console.log(`  ${line}`);
              }
            }
          } catch {
            // Ignore
          }
        }
        console.log("");
      }
    }

    if (!anyChanges) {
      console.log("No branches changed since last snapshot.");
    }
  },
};
