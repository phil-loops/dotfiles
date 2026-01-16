#!/usr/bin/env npx tsx

/**
 * Simple local branch tree tool (commonly called "stacked diffs")
 *
 * USAGE:
 *   stack add <parent>       # mark current branch as child of parent
 *   stack remove             # untrack current branch
 *   stack list               # show the branch tree
 *   stack update             # rebase current branch + descendants
 *   stack update --all       # rebase entire tree from root
 *   stack parent             # print parent branch name
 *   stack pr                 # push and create PR targeting parent
 *   stack last               # switch to deepest branch in stack
 *   stack push-all           # push all tracked branches
 *   stack move-to-root       # stash changes and move to root branch
 *   stack move-to-last       # stash changes and move to deepest branch
 *   stack backup-restore     # list and restore from backups
 */

import { execSync } from "child_process";
import { existsSync, readFileSync, writeFileSync } from "fs";
import { join } from "path";

const STACK_FILE = join(process.cwd(), ".stack");

// Maps child branch -> parent branch
type Stack = Record<string, string>;

function loadStack(): Stack {
  if (!existsSync(STACK_FILE)) return {};
  const content = readFileSync(STACK_FILE, "utf-8");
  const stack: Stack = {};
  for (const line of content.trim().split("\n")) {
    if (!line) continue;
    const [child, parent] = line.split(":");
    if (child && parent) stack[child] = parent;
  }
  return stack;
}

function saveStack(stack: Stack) {
  const content = Object.entries(stack)
    .map(([child, parent]) => `${child}:${parent}`)
    .join("\n");
  writeFileSync(STACK_FILE, content + "\n");
}

function git(cmd: string): string {
  return execSync(`git ${cmd}`, { encoding: "utf-8" }).trim();
}

function gitTry(cmd: string): boolean {
  try {
    execSync(`git ${cmd}`, { encoding: "utf-8", stdio: "pipe" });
    return true;
  } catch {
    return false;
  }
}

function currentBranch(): string {
  return git("branch --show-current");
}

function getChildren(stack: Stack, branch: string): string[] {
  return Object.entries(stack)
    .filter(([_, parent]) => parent === branch)
    .map(([child]) => child);
}

function getDescendants(stack: Stack, branch: string): string[] {
  const children = getChildren(stack, branch);
  const descendants: string[] = [];
  for (const child of children) {
    descendants.push(child);
    descendants.push(...getDescendants(stack, child));
  }
  return descendants;
}

function findRoot(stack: Stack, branch: string): string {
  let current = branch;
  while (stack[current]) {
    current = stack[current];
  }
  return current;
}

/**
 * Detect if adding parent would create a cycle
 */
function wouldCreateCycle(stack: Stack, child: string, parent: string): boolean {
  let current = parent;
  while (stack[current]) {
    if (stack[current] === child) return true;
    current = stack[current];
  }
  return false;
}

/**
 * Get all branches in the tree starting from root, in rebase order
 */
function getChainFromRoot(stack: Stack, branch: string): string[] {
  const root = findRoot(stack, branch);
  const chain: string[] = [];

  function walk(b: string) {
    const children = getChildren(stack, b);
    for (const child of children) {
      chain.push(child);
      walk(child);
    }
  }

  walk(root);
  return chain;
}

function createBackup(branch: string): string {
  const timestamp = new Date().toISOString().replace(/[:.]/g, "-").slice(0, 19);
  const backupName = `backup/${branch}/${timestamp}`;
  git(`branch ${backupName} ${branch}`);
  return backupName;
}

function listBackups(branch: string): string[] {
  try {
    const output = git(`branch --list "backup/${branch}/*"`);
    return output
      .split("\n")
      .map((b) => b.trim().replace(/^\*?\s*/, ""))
      .filter(Boolean);
  } catch {
    return [];
  }
}

/**
 * Detect the fork remote (phil-loops if it exists, otherwise origin)
 */
function getForkRemote(): string {
  try {
    const remotes = git("remote").split("\n");
    if (remotes.includes("phil-loops")) return "phil-loops";
    return "origin";
  } catch {
    return "origin";
  }
}

/**
 * Get the GitHub repo in owner/repo format
 */
function getGitHubRepo(): string | null {
  try {
    const remote = getForkRemote();
    const url = git(`remote get-url ${remote}`);
    // Handle both SSH and HTTPS URLs
    const match = url.match(/github\.com[:/]([^/]+\/[^/.]+)/);
    return match ? match[1].replace(/\.git$/, "") : null;
  } catch {
    return null;
  }
}

// ============ COMMANDS ============

function add(parent: string) {
  const branch = currentBranch();
  if (!branch) {
    console.error("Not on a branch");
    process.exit(1);
  }

  if (branch === parent) {
    console.error("Cannot set branch as its own parent");
    process.exit(1);
  }

  const stack = loadStack();

  if (wouldCreateCycle(stack, branch, parent)) {
    console.error(`Cannot add: would create a cycle (${parent} is a descendant of ${branch})`);
    process.exit(1);
  }

  stack[branch] = parent;
  saveStack(stack);
  console.log(`Added: ${branch} -> ${parent}`);
}

function remove() {
  const branch = currentBranch();
  if (!branch) {
    console.error("Not on a branch");
    process.exit(1);
  }

  const stack = loadStack();
  if (!stack[branch]) {
    console.error(`Branch "${branch}" is not tracked`);
    process.exit(1);
  }

  // Check if this branch has children
  const children = getChildren(stack, branch);
  if (children.length > 0) {
    console.error(`Cannot remove: ${branch} has children: ${children.join(", ")}`);
    console.error("Remove or reparent them first");
    process.exit(1);
  }

  delete stack[branch];
  saveStack(stack);
  console.log(`Removed: ${branch}`);
}

function list() {
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

function update(all: boolean) {
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

function backupRestore() {
  const branch = currentBranch();
  const backups = listBackups(branch);

  if (backups.length === 0) {
    console.log(`No backups found for ${branch}`);
    return;
  }

  console.log(`Backups for ${branch}:\n`);
  backups.forEach((b, i) => {
    console.log(`  ${i + 1}. ${b}`);
  });

  console.log(`\nTo restore, run:`);
  console.log(`  git reset --hard <backup-name>`);
  console.log(`\nExample (restore latest):`);
  console.log(`  git reset --hard ${backups[backups.length - 1]}`);
}

function parent() {
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

function pr() {
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

  const repo = getGitHubRepo();
  if (!repo) {
    console.error("Could not detect GitHub repo");
    process.exit(1);
  }

  console.log("Pushing...\n");
  try {
    execSync(`/bin/zsh -ic 'ppl'`, { stdio: "inherit" });
  } catch {
    console.error("Push failed");
    process.exit(1);
  }

  console.log(`\nCreating PR targeting ${p}...`);
  try {
    execSync(`gh pr create --repo ${repo} --base ${p} --fill`, {
      stdio: "inherit",
    });
  } catch {
    // gh handles "PR already exists" message
  }
}

function last() {
  const stack = loadStack();
  const branch = currentBranch();

  if (Object.keys(stack).length === 0) {
    console.error("No branches tracked");
    process.exit(1);
  }

  const chain = getChainFromRoot(stack, branch || Object.keys(stack)[0]);
  if (chain.length === 0) {
    console.error("No branches in chain");
    process.exit(1);
  }

  const lastBranch = chain[chain.length - 1];
  console.log(`Switching to ${lastBranch}`);
  git(`checkout ${lastBranch}`);
}

function pushAll() {
  const stack = loadStack();

  if (Object.keys(stack).length === 0) {
    console.error("No branches tracked");
    process.exit(1);
  }

  const remote = getForkRemote();
  const allBranches = Object.keys(stack);

  console.log(`Pushing ${allBranches.length} branches to ${remote}...\n`);

  for (const branch of allBranches) {
    console.log(`Pushing ${branch}...`);
    try {
      execSync(`git push ${remote} ${branch} -f`, { stdio: "inherit" });
    } catch {
      console.error(`Failed to push ${branch}`);
    }
  }

  console.log("\nDone!");
}

function moveChanges(target: "root" | "last") {
  const stack = loadStack();
  const branch = currentBranch();

  if (Object.keys(stack).length === 0) {
    console.error("No branches tracked");
    process.exit(1);
  }

  const status = git("status --porcelain");
  if (!status.trim()) {
    console.error("No uncommitted changes to move");
    process.exit(1);
  }

  const chain = getChainFromRoot(stack, branch || Object.keys(stack)[0]);
  const root = findRoot(stack, branch || Object.keys(stack)[0]);

  // Fix: root is the actual root, chain[0] is first child
  const targetBranch = target === "root" ? root : chain[chain.length - 1];

  if (targetBranch === branch) {
    console.log(`Already on ${target} branch (${targetBranch})`);
    process.exit(0);
  }

  console.log(`Moving uncommitted changes from ${branch} to ${targetBranch}...`);

  git("stash push -u -m 'stack-move-changes'");
  git(`checkout ${targetBranch}`);
  git("stash pop");

  console.log(`\nDone! Now on ${targetBranch} with your changes.`);
}

// ============ CLI ============

const [cmd, ...args] = process.argv.slice(2);

switch (cmd) {
  case "add":
    if (!args[0]) {
      console.error("Usage: stack add <parent>");
      process.exit(1);
    }
    add(args[0]);
    break;
  case "remove":
    remove();
    break;
  case "list":
    list();
    break;
  case "update":
    update(args.includes("--all"));
    break;
  case "backup-restore":
    backupRestore();
    break;
  case "parent":
    parent();
    break;
  case "pr":
    pr();
    break;
  case "last":
    last();
    break;
  case "push-all":
    pushAll();
    break;
  case "move-to-root":
    moveChanges("root");
    break;
  case "move-to-last":
    moveChanges("last");
    break;
  default:
    console.log(`
Branch Stack Tool

Commands:
  add <parent>      Track current branch as child of parent
  remove            Untrack current branch
  list              Show the branch tree
  update            Rebase current branch + descendants
  update --all      Rebase entire tree from root
  parent            Print parent branch name
  pr                Push and create PR targeting parent
  last              Switch to deepest branch in stack
  push-all          Push all tracked branches
  move-to-root      Stash changes and move to root branch
  move-to-last      Stash changes and move to deepest branch
  backup-restore    List backups and show restore commands

Examples:
  stack add main
  stack list
  stack update
`);
}
