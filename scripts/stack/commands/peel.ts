import type { Command } from "../types.ts";
import { currentBranch, git } from "../lib.ts";
import { parseArgs } from "../args.ts";

export const command: Command = {
  name: "peel",
  help: "Create new branch with diff as uncommitted changes",
  args: "[name] [--base <branch>]",
  run(args) {
    const { values, positionals } = parseArgs(args, {
      base: { type: "string", short: "b", default: "main" },
    });

    const newBranchName = positionals[0];
    const baseBranch = values.base!;

    const sourceBranch = currentBranch();

    if (!sourceBranch) {
      console.error("Not on a branch");
      process.exit(1);
    }

    // Check for uncommitted changes
    const status = git("status --porcelain");
    if (status) {
      console.error("Error: You have uncommitted changes. Please commit or stash them first.");
      process.exit(1);
    }

    // Verify base branch exists
    try {
      git(`rev-parse --verify ${baseBranch}`);
    } catch {
      console.error(`Error: Base branch "${baseBranch}" does not exist`);
      process.exit(1);
    }

    // Check if there are any differences
    const diffCheck = git(`diff ${baseBranch}...${sourceBranch} --stat`);
    if (!diffCheck) {
      console.error(`No differences between "${sourceBranch}" and "${baseBranch}"`);
      process.exit(1);
    }

    // Generate branch name if not provided
    const targetBranch = newBranchName || `${sourceBranch}-peeled`;

    // Check if target branch already exists
    try {
      git(`rev-parse --verify ${targetBranch}`);
      console.error(`Error: Branch "${targetBranch}" already exists`);
      process.exit(1);
    } catch {
      // Good - branch doesn't exist
    }

    console.log(`Peeling "${sourceBranch}" onto new branch "${targetBranch}" from "${baseBranch}"...`);

    // Create new branch from base
    git(`checkout ${baseBranch}`);
    git(`checkout -b ${targetBranch}`);

    // Apply changes from source branch as uncommitted changes
    try {
      git(`merge --squash ${sourceBranch}`);
    } catch {
      console.error("\nMerge conflicts detected. Resolve them and commit manually.");
      console.log("Files with conflicts:");
      console.log(git("diff --name-only --diff-filter=U"));
      process.exit(1);
    }

    // Reset the index but keep changes in working directory
    try {
      git("reset HEAD");
    } catch {
      // Ignore - may fail if nothing staged
    }

    console.log(`\n✓ Created branch "${targetBranch}" with uncommitted changes from "${sourceBranch}"`);
    console.log("\nChanges ready to review and commit:");
    console.log(git("status --short"));
  },
};
