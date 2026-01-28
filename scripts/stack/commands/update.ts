import { execSync } from "child_process";
import { getStackBranches, getCurrentBranch, getStackPrefix, git, gitOrFail } from "../lib/git-town.ts";

export function update(args: string[]) {
  const prefix = args.find(a => !a.startsWith("-") && !a.startsWith("--from")) || getStackPrefix();
  const dryRun = args.includes("--dry-run");
  const fromBranchArg = args.find(a => a.startsWith("--from="));
  const fromBranch = fromBranchArg?.split("=")[1] || getCurrentBranch();

  const stack = getStackBranches(prefix);

  if (stack.length === 0) {
    console.error("No stack branches found.");
    process.exit(1);
  }

  // Find the starting branch index
  const startIdx = stack.findIndex(b => b.name === fromBranch);
  if (startIdx === -1) {
    console.error(`Branch "${fromBranch}" not found in stack.`);
    console.error("Available branches:");
    stack.forEach((b, i) => console.error(`  [${String(i + 1).padStart(2, "0")}] ${b.name}`));
    process.exit(1);
  }

  // Get branches to rebase (everything after startIdx)
  const toRebase = stack.slice(startIdx + 1);

  if (toRebase.length === 0) {
    console.log(`No downstream branches to rebase from "${fromBranch}".`);
    return;
  }

  console.log(`\nRebasing ${toRebase.length} downstream branches from "${fromBranch}":\n`);
  for (const b of toRebase) {
    console.log(`  ${b.name} (onto ${b.parent})`);
  }
  console.log();

  if (dryRun) {
    console.log("(dry run - no changes made)");
    return;
  }

  // Save current branch to return to
  const originalBranch = getCurrentBranch();

  let failed = false;
  for (const branch of toRebase) {
    console.log(`Rebasing ${branch.name} onto ${branch.parent}...`);

    try {
      execSync(`git checkout ${branch.name}`, { stdio: "pipe" });
      execSync(`git rebase ${branch.parent}`, { stdio: "pipe" });
      console.log(`  Done.`);
    } catch (e: any) {
      console.error(`  FAILED: Rebase conflict in ${branch.name}`);
      console.error(`  Resolve conflicts and run: git rebase --continue`);
      console.error(`  Then re-run: loops stack update --from=${branch.name}`);
      failed = true;
      break;
    }
  }

  if (!failed) {
    // Return to original branch
    try {
      execSync(`git checkout ${originalBranch}`, { stdio: "pipe" });
    } catch {
      // Stay where we are if we can't go back
    }
    console.log(`\nAll ${toRebase.length} branches rebased successfully.`);
  }
}
