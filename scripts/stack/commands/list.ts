import { currentBranch, getChildren, loadStack } from "../lib.ts";

export function list() {
  const stack = loadStack();
  const branch = currentBranch();

  if (Object.keys(stack).length === 0) {
    console.log("No branches tracked. Use: stack add <parent>");
    return;
  }

  const allParents = new Set(Object.values(stack));
  const allChildren = new Set(Object.keys(stack));
  const roots = [...allParents].filter((p) => !allChildren.has(p));

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
}
