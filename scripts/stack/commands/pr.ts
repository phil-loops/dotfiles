import { execSync } from "child_process";
import type { Command } from "../types.ts";
import { currentBranch, getGitHubRepo, loadStack } from "../lib.ts";

export const command: Command = {
  name: "pr",
  help: "Push and create PR targeting parent",
  run() {
    const stack = loadStack();
    const branch = currentBranch();

    if (!branch) {
      console.error("Not on a branch");
      process.exit(1);
    }

    const p = stack[branch];
    if (!p) {
      console.error(`Branch "${branch}" not tracked`);
      process.exit(1);
    }

    const repo = getGitHubRepo();
    if (!repo) {
      console.error("Could not detect GitHub repo");
      process.exit(1);
    }

    console.log("Pushing...\n");
    try {
      execSync(`/bin/zsh -ic 'ppl'`, { stdio: "inherit" });
    } catch {
      console.error("Push failed");
      process.exit(1);
    }

    console.log(`\nCreating PR targeting ${p}...`);
    try {
      execSync(`gh pr create --repo ${repo} --base ${p} --fill`, {
        stdio: "inherit",
      });
    } catch {
      // gh handles "PR already exists" message
    }
  },
};
