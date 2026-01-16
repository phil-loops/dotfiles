import { currentBranch, getBranchesByPrefix, getChildren, loadConvention, loadStack } from "../lib.ts";

export function list() {
  const convention = loadConvention();
  const branch = currentBranch();

  // Convention mode
  if (convention) {
    const branches = getBranchesByPrefix(convention.prefix);
    if (branches.length === 0) {
      console.log(`No branches matching ${convention.prefix}*`);
      console.log(`Create one with: git checkout -b ${convention.prefix}1`);
      return;
    }

    console.log(convention.root);
    for (let i = 0; i < branches.length; i++) {
      const b = branches[i];
      const marker = b === branch ? " <-- you" : "";
      const indent = "  ".repeat(i + 1);
      console.log(indent + b + marker);
    }
    return;
  }

  // Explicit mode
  const stack = loadStack();

  if (Object.keys(stack).length === 0) {
    console.log("No branches tracked.");
    console.log("Use: stack add <parent>    (explicit mode)");
    console.log("Or:  stack init <prefix>   (convention mode)");
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
