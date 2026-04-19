import { execSync } from "child_process";
import { getStackBranchNames, getStackPrefix, git } from "../lib/stack-config.ts";

export function push(args: string[]) {
  const prefix = args.find(a => !a.startsWith("-")) || getStackPrefix();
  const dryRun = args.includes("--dry-run");
  const force = args.includes("--force") || args.includes("-f");
  const remote = args.find(a => a.startsWith("--remote="))?.split("=")[1] || "origin";

  const branches = getStackBranchNames(prefix);

  if (branches.length === 0) {
    console.error("No stack branches found.");
    process.exit(1);
  }

  console.log(`\nPushing ${branches.length} branches to ${remote}:\n`);
  for (const b of branches) {
    console.log(`  ${b}`);
  }
  console.log();

  const branchList = branches.join(" ");
  const forceFlag = force ? "--force-with-lease" : "";
  const cmd = `git push ${remote} ${forceFlag} ${branchList}`;

  if (dryRun) {
    console.log(`Would run: ${cmd}`);
    console.log("(dry run - no changes made)");
    return;
  }

  console.log(`Running: git push ${remote} ${forceFlag} ...`);

  try {
    execSync(cmd, { stdio: "inherit" });
    console.log(`\nAll ${branches.length} branches pushed successfully.`);
  } catch (e) {
    console.error("\nPush failed. You may need to use --force if branches were rebased.");
    process.exit(1);
  }
}
