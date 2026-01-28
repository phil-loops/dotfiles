import { getStackBranches, getCurrentBranch, getStackPrefix } from "../lib/git-town.ts";

export function branches(args: string[]) {
  const prefix = args.find(a => !a.startsWith("-")) || getStackPrefix();
  const jsonOutput = args.includes("--json");
  const namesOnly = args.includes("--names");

  const stack = getStackBranches(prefix);

  if (stack.length === 0) {
    console.error("No stack branches found.");
    console.error("Make sure git-town parents are configured.");
    process.exit(1);
  }

  const currentBranch = getCurrentBranch();

  if (jsonOutput) {
    const output = stack.map((b, i) => ({
      index: i,
      name: b.name,
      parent: b.parent,
      isCurrent: b.name === currentBranch,
      commitCount: b.commits.size,
    }));
    console.log(JSON.stringify(output, null, 2));
    return;
  }

  if (namesOnly) {
    // Just print names, one per line (useful for scripting)
    for (const b of stack) {
      console.log(b.name);
    }
    return;
  }

  // Pretty print
  console.log(`\nStack branches${prefix ? ` (prefix: ${prefix})` : ""}:\n`);

  for (let i = 0; i < stack.length; i++) {
    const b = stack[i];
    const num = String(i + 1).padStart(2, "0");
    const current = b.name === currentBranch ? " *" : "  ";
    const commits = b.commits.size > 0 ? ` (${b.commits.size} commit${b.commits.size === 1 ? "" : "s"})` : "";
    console.log(`${current}[${num}] ${b.name}${commits}`);
  }

  console.log(`\nTotal: ${stack.length} branches`);
}
