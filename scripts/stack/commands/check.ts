import type { Command } from "../types.ts";
import { checkConflict, currentBranch, getChildren, loadStack } from "../lib.ts";

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

    const allParents = new Set(Object.values(stack));
    const allChildren = new Set(Object.keys(stack));
    const roots = [...allParents].filter((p) => !allChildren.has(p));

    const conflicts: Array<{ child: string; parent: string; files: string[] }> = [];

    for (const [child, parent] of Object.entries(stack)) {
      const result = checkConflict(parent, child);
      if (result.hasConflict) {
        conflicts.push({ child, parent, files: result.files });
      }
    }

    function printTree(b: string, indent: string) {
      const marker = b === branch ? " <-- you" : "";
      const conflict = conflicts.find((c) => c.child === b);
      const conflictMarker = conflict ? " ⚠ CONFLICT" : " ✓";
      const statusMarker = stack[b] ? conflictMarker : "";
      console.log(indent + b + marker + statusMarker);
      const children = getChildren(stack, b);
      children.forEach((child) => {
        printTree(child, indent + "  ");
      });
    }

    for (const root of roots) {
      printTree(root, "");
    }

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
