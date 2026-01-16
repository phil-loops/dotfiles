import { createBackup, currentBranch, getChainFromRoot, getDescendants, git, gitTry, loadStack } from "../lib.ts";

export function update(all: boolean) {
  const stack = loadStack();
  const branch = currentBranch();

  if (Object.keys(stack).length === 0) {
    console.log("No branches tracked");
    return;
  }

  let toRebase: string[];
  if (all) {
    toRebase = getChainFromRoot(stack, branch);
  } else {
    toRebase = [branch, ...getDescendants(stack, branch)].filter((b) => stack[b]);
  }

  if (toRebase.length === 0) {
    console.log("Nothing to rebase");
    return;
  }

  console.log(`\nWill rebase: ${toRebase.join(" -> ")}\n`);

  console.log("Creating backups...");
  const backups: Record<string, string> = {};
  for (const b of toRebase) {
    backups[b] = createBackup(b);
    console.log(`  ${b} -> ${backups[b]}`);
  }
  console.log("");

  for (const b of toRebase) {
    const parent = stack[b];
    if (!parent) continue;

    console.log(`Rebasing ${b} onto ${parent}...`);
    git(`checkout ${b}`);

    if (gitTry(`rebase ${parent}`)) {
      console.log(`Done: ${b}\n`);
    } else {
      console.error(`\nFailed: ${b} (merge conflict)`);
      console.error(`
To resolve:
  1. Edit the conflicted files
  2. git add <resolved files>
  3. git rebase --continue
  4. Re-run: stack update

To abort and restore:
  1. git rebase --abort
  2. git reset --hard ${backups[b]}
`);
      process.exit(1);
    }
  }

  git(`checkout ${branch}`);
  console.log(`Done! Back on ${branch}`);
}
