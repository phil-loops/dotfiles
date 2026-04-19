import { getStackPrefix } from "../lib/stack-config.ts";
import { push } from "./push.ts";
import { sync } from "./sync.ts";

export async function flow(args: string[]) {
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
  const syncArgs = [prefix];
  if (dryRun) syncArgs.push("--dry-run");
  try {
    await sync(syncArgs);
  } catch (e: any) {
    console.error(`\nSync failed: ${e.message}`);
    process.exit(1);
  }

  // 2. Push (force since sync rebases)
  console.log("\nStep 2: Push stack branches");
  if (dryRun) {
    console.log(`  [dry-run] Would push all branches with --force`);
  } else {
    push(["--force"]);
  }

  console.log("\nFlow complete.");
}
