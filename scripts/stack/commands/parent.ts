import { currentBranch, loadStack } from "../lib.ts";

export function parent() {
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

  console.log(p);
}
