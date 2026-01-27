import type { Command } from "../types.ts";
import { currentBranch, getChildren, loadStack } from "../lib.ts";

export const command: Command = {
  category: "nav",
  name: "list",
  help: "Show the stack",
  run() {
    const stack = loadStack();
    const branch = currentBranch();

    if (Object.keys(stack).length === 0) {
      console.log("No branches tracked.");
      console.log("Use: stack add <parent>    (track current branch)");
      console.log("Or:  stack init <prefix>   (init from branch prefix)");
      return;
    }

    const allParents = new Set(Object.values(stack));
    const allChildren = new Set(Object.keys(stack));
    const roots = [...allParents].filter((p) => !allChildren.has(p));

    // Show note if current branch isn't in the stack
    if (!stack[branch] && !roots.includes(branch)) {
      console.log(`(You're on ${branch}, not in the stack)\n`);
    }

    function printTree(b: string, indent: string) {
      const marker = b === branch ? " <-- you" : "";
      console.log(indent + b + marker);
      const children = getChildren(stack, b);
      children.forEach((child) => {
        printTree(child, indent + "  ");
      });
    }

    for (const root of roots) {
      printTree(root, "");
    }
  },
};
