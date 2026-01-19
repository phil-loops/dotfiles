import type { Command } from "../types.ts";
import { currentBranch, extractKeyChangeNames, getChildren, git, loadStack } from "../lib.ts";

export const command: Command = {
  category: "nav",
  name: "overview",
  help: "Show tree with key changes per branch",
  run() {
    const stack = loadStack();
    const branch = currentBranch();

    if (Object.keys(stack).length === 0) {
      console.log("No branches tracked.");
      return;
    }

    // Find roots (branches that are parents but not children)
    const allParents = new Set(Object.values(stack));
    const allChildren = new Set(Object.keys(stack));
    const roots = [...allParents].filter((p) => !allChildren.has(p));

    function getChangesForBranch(b: string, parent: string | null): string[] {
      if (!parent) return [];
      try {
        const diff = git(`diff ${parent}...${b} -U0`);
        return extractKeyChangeNames(diff);
      } catch {
        return [];
      }
    }

    function printBranch(
      b: string,
      parent: string | null,
      linePrefix: string,
      contentPrefix: string
    ) {
      const marker = b === branch ? " <-- you" : "";
      const children = getChildren(stack, b);
      const changes = getChangesForBranch(b, parent);

      // Branch line with change count
      const changeCount = changes.length > 0 ? ` (${changes.length} changes)` : "";
      console.log(`${linePrefix}${b}${changeCount}${marker}`);

      // Show changes indented below the branch name
      if (changes.length > 0) {
        const changePrefix = contentPrefix + (children.length > 0 ? "│  " : "   ");
        const displayChanges = changes.slice(0, 5);
        console.log(`${changePrefix}${displayChanges.join(", ")}`);
        if (changes.length > 5) {
          console.log(`${changePrefix}... and ${changes.length - 5} more`);
        }
      }

      // Print children
      children.forEach((child, i) => {
        const isLastChild = i === children.length - 1;
        const connector = isLastChild ? "└─ " : "├─ ";
        const nextContentPrefix = contentPrefix + (isLastChild ? "   " : "│  ");
        printBranch(child, b, contentPrefix + connector, nextContentPrefix);
      });
    }

    for (const root of roots) {
      printBranch(root, null, "", "");
    }
  },
};
