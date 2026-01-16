import { execSync } from "child_process";
import { getForkRemote, loadStack } from "../lib.ts";

export function pushAll() {
  const stack = loadStack();

  if (Object.keys(stack).length === 0) {
    console.error("No branches tracked");
    process.exit(1);
  }

  const remote = getForkRemote();
  const allBranches = Object.keys(stack);

  console.log(`Pushing ${allBranches.length} branches to ${remote}...\n`);

  for (const branch of allBranches) {
    console.log(`Pushing ${branch}...`);
    try {
      execSync(`git push ${remote} ${branch} -f`, { stdio: "inherit" });
    } catch {
      console.error(`Failed to push ${branch}`);
    }
  }

  console.log("\nDone!");
}
