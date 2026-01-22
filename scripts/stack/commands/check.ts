import type { Command } from "../types.ts";
import { checkConflict, currentBranch, findRoot, getChildren, getCurrentStack, loadStack } from "../lib.ts";

export const command: Command = {
  category: "git",
  name: "check",
  help: "Dry-run conflict detection across the stack",
  run() {
    const stack = loadStack();
    const branch = currentBranch();

    if (Object.keys(stack).length === 0) {
      console.log("No branches tracked");
      return;
    }

    const currentStackBranches = getCurrentStack(stack, branch);
    if (currentStackBranches.length === 0) {
      console.log("Current branch is not in a tracked stack");
      return;
    }

    const currentStackSet = new Set(currentStackBranches);
    const conflicts: Array<{ child: string; parent: string; files: string[] }> = [];

    // Only check branches in the current stack
    for (const child of currentStackBranches) {
      const parent = stack[child];
      if (!parent) continue;
      const result = checkConflict(parent, child);
      if (result.hasConflict) {
        conflicts.push({ child, parent, files: result.files });
      }
    }

    const root = findRoot(stack, branch);

    function printTree(b: string, indent: string) {
      // Only print branches in current stack (plus root)
      if (b !== root && !currentStackSet.has(b)) return;

      const marker = b === branch ? " <-- you" : "";
      const conflict = conflicts.find((c) => c.child === b);
      const conflictMarker = conflict ? " ⚠ CONFLICT" : " ✓";
      const statusMarker = stack[b] ? conflictMarker : "";
      console.log(indent + b + marker + statusMarker);
      const children = getChildren(stack, b).filter((c) => currentStackSet.has(c));
      children.forEach((child) => {
        printTree(child, indent + "  ");
      });
    }

    printTree(root, "");

    if (conflicts.length > 0) {
      console.log("\nConflicts detected:\n");
      for (const { child, parent, files } of conflicts) {
        console.log(`  ${child} onto ${parent}:`);
        for (const file of files) {
          console.log(`    - ${file}`);
        }
      }
      process.exit(1);
    } else {
      console.log("\nNo conflicts detected. Safe to update.");
    }
  },
};
