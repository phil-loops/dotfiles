import { execSync } from "child_process";
import { writeFileSync } from "fs";
import { join } from "path";
import { createBackup, currentBranch, getDescendants, git, gitTry, loadStack } from "../lib.ts";

export function fixup(targetBranch: string) {
  const stack = loadStack();
  const branch = currentBranch();

  if (!branch) {
    console.error("Not on a branch");
    process.exit(1);
  }

  // Verify target is an ancestor
  let isAncestor = false;
  let current = branch;
  while (stack[current]) {
    if (stack[current] === targetBranch || current === targetBranch) {
      isAncestor = true;
      break;
    }
    current = stack[current];
  }
  if (current === targetBranch) isAncestor = true;

  if (!isAncestor) {
    console.error(`${targetBranch} is not an ancestor of ${branch}`);
    process.exit(1);
  }

  const staged = git("diff --cached --name-only");
  if (!staged.trim()) {
    console.error("No staged changes. Stage your changes with 'git add' first");
    process.exit(1);
  }

  const unstaged = git("diff --name-only");
  const hasUnstaged = unstaged.trim().length > 0;

  if (hasUnstaged) {
    console.log("Stashing unstaged changes...");
    git("stash push --keep-index -m 'stack-fixup-unstaged'");
  }

  console.log("Creating patch from staged changes...");
  const patch = git("diff --cached");
  const patchFile = join(process.cwd(), ".stack-fixup.patch");
  writeFileSync(patchFile, patch);

  git("reset HEAD");
  git(`checkout ${targetBranch}`);

  console.log(`Applying changes to ${targetBranch}...`);
  try {
    execSync(`git apply ${patchFile}`, { encoding: "utf-8" });
  } catch {
    console.error("Failed to apply patch. There may be conflicts.");
    console.error("Aborting...");
    git(`checkout ${branch}`);
    if (hasUnstaged) git("stash pop");
    execSync(`rm ${patchFile}`);
    process.exit(1);
  }

  git("add -A");
  const commitMsg = `fixup from ${branch}`;
  git(`commit -m "${commitMsg}"`);
  console.log(`Committed to ${targetBranch}`);

  execSync(`rm ${patchFile}`);

  const toRebase = getDescendants(stack, targetBranch).filter((b) => {
    let c = branch;
    while (c && c !== targetBranch) {
      if (c === b) return true;
      c = stack[c];
    }
    return false;
  });

  if (stack[branch]) {
    toRebase.push(branch);
  }

  if (toRebase.length > 0) {
    console.log(`\nUpdating: ${toRebase.join(" -> ")}`);

    for (const b of toRebase) {
      const parent = stack[b];
      if (!parent) continue;

      createBackup(b);
      git(`checkout ${b}`);

      if (gitTry(`rebase ${parent}`)) {
        console.log(`Rebased: ${b}`);
      } else {
        console.error(`\nFailed to rebase ${b}`);
        console.error("Resolve conflicts and run 'git rebase --continue'");
        if (hasUnstaged) {
          console.error("Your unstaged changes are still in the stash");
        }
        process.exit(1);
      }
    }
  }

  git(`checkout ${branch}`);

  if (hasUnstaged) {
    console.log("Restoring unstaged changes...");
    git("stash pop");
  }

  console.log(`\nDone! Fixup applied to ${targetBranch} and propagated to ${branch}`);
}
