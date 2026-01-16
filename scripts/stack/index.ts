#!/usr/bin/env -S node --no-warnings --experimental-strip-types

/**
 * stack - Simple local branch tree tool (stacked diffs)
 *
 * USAGE:
 *   stack add <parent>       # mark current branch as child of parent
 *   stack remove             # untrack current branch
 *   stack insert <b> --after <p>  # insert branch, reparent children
 *   stack list               # show the branch tree
 *   stack check              # dry-run conflict detection
 *   stack plan               # analyze stack for PR planning
 *   stack update             # rebase current branch + descendants
 *   stack update --all       # rebase entire tree from root
 *   stack parent             # print parent branch name
 *   stack pr                 # push and create PR targeting parent
 *   stack last               # switch to deepest branch in stack
 *   stack push-all           # push all tracked branches
 *   stack move-to-root       # stash changes and move to root branch
 *   stack move-to-last       # stash changes and move to deepest branch
 *   stack backup-restore     # list and restore from backups
 *
 *   stack edit <branch>      # stash, checkout branch, remember origin
 *   stack edit --abort       # cancel edit, return to original branch
 *   stack return             # update descendants, return, pop stash
 *   stack fixup <branch>     # apply staged changes to ancestor, update stack
 */

import { add } from "./commands/add.ts";
import { backupRestore } from "./commands/backup.ts";
import { check } from "./commands/check.ts";
import { abortEdit, edit, returnFromEdit } from "./commands/edit.ts";
import { fixup } from "./commands/fixup.ts";
import { insert } from "./commands/insert.ts";
import { last } from "./commands/last.ts";
import { list } from "./commands/list.ts";
import { moveChanges } from "./commands/move.ts";
import { parent } from "./commands/parent.ts";
import { plan } from "./commands/plan.ts";
import { pr } from "./commands/pr.ts";
import { remote } from "./commands/remote.ts";
import { pushAll } from "./commands/push-all.ts";
import { remove } from "./commands/remove.ts";
import { update } from "./commands/update.ts";

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
  case "insert": {
    // Parse: stack insert <new-branch> --after <parent>
    const afterIdx = args.indexOf("--after");
    if (afterIdx === -1 || !args[0] || !args[afterIdx + 1]) {
      console.error("Usage: stack insert <new-branch> --after <parent>");
      process.exit(1);
    }
    const newBranch = args[0];
    const afterBranch = args[afterIdx + 1];
    insert(newBranch, afterBranch);
    break;
  }
  case "list":
    list();
    break;
  case "check":
    check();
    break;
  case "plan":
    plan();
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
  case "remote":
    remote(args[0]);
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
  case "edit":
    if (args[0] === "--abort") {
      abortEdit();
    } else if (!args[0]) {
      console.error("Usage: stack edit <branch> or stack edit --abort");
      process.exit(1);
    } else {
      edit(args[0]);
    }
    break;
  case "return":
    returnFromEdit();
    break;
  case "fixup":
    if (!args[0]) {
      console.error("Usage: stack fixup <branch>");
      process.exit(1);
    }
    fixup(args[0]);
    break;
  default:
    console.log(`
stack - Branch Stack Tool

Commands:
  add <parent>      Track current branch as child of parent
  remove            Untrack current branch
  insert <branch> --after <parent>
                    Insert new branch, reparent children
  list              Show the branch tree
  check             Dry-run conflict detection across the stack
  plan              Analyze stack for PR planning (copies to clipboard)
  update            Rebase current branch + descendants
  update --all      Rebase entire tree from root
  parent            Print parent branch name
  pr                Push and create PR targeting parent
  remote            Show current remote
  remote <name>     Set remote (saves to .stackrc)
  last              Switch to deepest branch in stack
  push-all          Push all tracked branches
  move-to-root      Stash changes and move to root branch
  move-to-last      Stash changes and move to deepest branch
  backup-restore    List backups and show restore commands

  edit <branch>     Stash, checkout branch, remember where to return
  edit --abort      Cancel edit mode, return to original branch
  return            After editing: update descendants, return, pop stash
  fixup <branch>    Apply staged changes to ancestor branch, update stack

Examples:
  stack add main
  stack list
  stack update

  # Quick fix in ancestor branch (stay on current branch):
  git add -p                 # stage changes for ancestor
  stack fixup goals-2        # apply to goals-2, rebase back

  # Bigger edit in ancestor branch:
  stack edit goals-2         # stash, checkout goals-2
  # ... make changes, commit ...
  stack return               # rebase descendants, return

  # Insert a branch in the middle of a chain:
  stack insert goals-1.5 --after goals-1
  stack update               # rebase the chain
`);
}
