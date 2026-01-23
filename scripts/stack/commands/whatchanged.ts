import type { Command } from "../types.ts";
import { git, loadAck, loadStack, saveAck } from "../lib.ts";
import { parseArgs } from "../args.ts";
import { execSync } from "child_process";

export const command: Command = {
  category: "info",
  name: "whatchanged",
  help: "Show what changed since you last reviewed (--ack to mark reviewed)",
  args: "[--files] [--diff] [--ack]",
  run(args) {
    const { values } = parseArgs(args, {
      files: { type: "boolean", short: "f" },
      diff: { type: "boolean", short: "d" },
      ack: { type: "boolean", short: "a" },
    });

    const stack = loadStack();
    const branches = Object.keys(stack);

    if (branches.length === 0) {
      console.log("No branches tracked.");
      return;
    }

    // If --ack, save current state and exit
    if (values.ack) {
      saveAck(branches);
      console.log("Acknowledged. Current branch states saved.");
      return;
    }

    const ack = loadAck();
    if (!ack) {
      console.log("No previous state to compare. Run 'stack whatchanged --ack' to set baseline.");
      return;
    }

    console.log(`Last reviewed: ${ack.timestamp}\n`);

    let anyChanges = false;
    const changedFiles = new Set<string>();

    for (const branch of branches) {
      const oldHash = ack.branches[branch];

      let currentHash: string;
      try {
        currentHash = git(`rev-parse ${branch}`);
      } catch {
        if (oldHash) {
          console.log(`${branch}: (deleted)`);
          anyChanges = true;
        }
        continue;
      }

      // New branch since last ack
      if (!oldHash) {
        console.log(`${branch}: (new branch)`);
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
        try {
          const filesChanged = execSync(
            `git diff --name-only ${oldHash}..${currentHash}`,
            { encoding: "utf-8" }
          ).trim();

          if (filesChanged) {
            for (const file of filesChanged.split("\n")) {
              console.log(`  ${file}`);
              changedFiles.add(file);
            }
          }
        } catch {
          console.log("  (could not determine changed files)");
        }

        if (values.diff) {
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
      console.log("No branches changed since last review.");
    } else if (values.files && changedFiles.size > 0) {
      console.log("\n--- All changed files ---");
      for (const file of [...changedFiles].sort()) {
        console.log(file);
      }
    }
  },
};
