---
name: ticket-check
description: Check whether work already exists locally for a Linear ticket (LOO-####) before starting fresh work. Auto-triggers when about to create a worktree, branch, or otherwise start fresh work tied to a ticket ID. Surfaces existing branches and worktrees so we don't duplicate or fork off in a stale spot.
---

# Ticket Check

Given a Linear-style ticket ID (e.g. `LOO-5041`), check for existing local work tied to that ticket so we don't accidentally start a second branch or worktree for the same thing.

## When to use

Run this **before** starting fresh work on a ticket. Trigger signals:

- User says "let's start LOO-####", "work on LOO-####", "spin up a worktree for LOO-####"
- About to call `git worktree add` or `git checkout -b` for a ticket
- User pastes a Linear URL or ticket ID and is clearly heading into new work

Skip if the user has already named a specific branch/worktree to use, or is asking a read-only question.

## How to use

The Linear convention in this account is `LOO-####`. Match case-insensitively.

### Steps

1. **Find git repo root.** This skill is meaningless outside a git repo — bail with a one-line note if there isn't one.

2. **Check local branches:**
   ```bash
   git branch -a --list "*<ticket-lower>*" "*<ticket-upper>*"
   ```
   (Or simpler: `git branch -a | grep -i <ticket>`.)

3. **Check worktrees:**
   ```bash
   git worktree list | grep -i <ticket>
   ```

4. **Report.** Surface a compact summary:
   - If nothing found: one line, "No existing local work found for LOO-####" — then continue with whatever the user asked.
   - If matches found: list them (branch names + worktree paths) and **pause** before creating anything new. Ask the user whether to reuse the existing branch/worktree or proceed with a new one.

### Output shape

Keep it short. Example with matches:

```
LOO-5041 already has local work:
  - branch: phil/loo-5041-unsuppression-history
  - worktree: /Users/philbrockman/coding/loops-loo-5041 (phil/loo-5041-unsuppression-history)

Reuse this, or start a new branch?
```

Example without matches:

```
No existing local work found for LOO-5041. Proceeding.
```

## What this skill does NOT do

- Doesn't check GitHub PRs (intentionally — local-only).
- Doesn't check Linear itself.
- Doesn't search recent commits on main (squash-merged PRs don't carry branch names; the ticket prefix in commit messages is the signal but it's noisy).
- Doesn't modify anything — read-only.
