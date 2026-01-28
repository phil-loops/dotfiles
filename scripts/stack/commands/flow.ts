import { execSync } from "child_process";
import { getStackPrefix } from "../lib/git-town.ts";
import { push } from "./push.ts";

function run(cmd: string, dryRun: boolean): boolean {
  if (dryRun) {
    console.log(`  [dry-run] Would run: ${cmd}`);
    return true;
  }
  console.log(`  Running: ${cmd}`);
  try {
    execSync(cmd, { stdio: "inherit" });
    return true;
  } catch {
    return false;
  }
}

export function flow(args: string[]) {
  const dryRun = args.includes("--dry-run");
  const prefix = getStackPrefix();

  if (!prefix) {
    console.error("Could not detect stack prefix from current branch.");
    process.exit(1);
  }

  console.log(`\nStack flow: ${prefix}`);
  if (dryRun) console.log("(dry run mode)\n");
  else console.log();

  // 1. Sync
  console.log("Step 1: Sync stack");
  if (!run("git town sync --stack", dryRun)) {
    console.error("\nSync failed — check for conflicts and resolve them, then re-run.");
    process.exit(1);
  }

  // 2. Push (force since sync rebases)
  console.log("\nStep 2: Push stack branches");
  if (dryRun) {
    console.log(`  [dry-run] Would push all branches with --force`);
  } else {
    push(["--force"]);
  }

  // 3. Compress
  console.log("\nStep 3: Compress stack");
  if (!run("git town compress --stack", dryRun)) {
    console.error("\nCompress failed.");
    process.exit(1);
  }

  console.log("\nFlow complete.");
}
