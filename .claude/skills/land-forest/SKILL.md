---
name: land-forest
description: Land an already-built stacked-PR forest — the shipping motion that complements /reforest's building motion. Restacks every branch onto fresh origin/main (raw git, bottom-up, contracting any already-merged node), confirms the canonical merge order, drafts a forest-framed PR body per branch (stack-pr-body), hands the push + PR-opening to the user, and contracts the forest after each base merges. Use when the work is split into a forest and the user wants to ship it — "see this forest out", "land these PRs", "ship the stack", "get this forest merged", "prep the forest for push", or after /reforest when it's time to merge. NOT for building/splitting a forest (that's /reforest) or a routine single-branch restack.
---

# Land Forest — ship an existing forest out to merged

`/reforest` builds the forest; this lands it. **Restack mechanics, contraction, and config hygiene
live in `claude/forests.md` (*Restacking after a merge*) — apply them, don't restate them here.**
This skill sequences them across a whole forest and drains it to zero. Tools it orchestrates:
`stack-merge-rank` (canonical order), `stack-pr-body` (PR bodies), raw git.

## When to use

- "see this forest out", "land these PRs", "ship the stack", "prep for push" — on a forest whose
  branches + `stack-*` config already exist. Often right after `/reforest`.
- NOT building/splitting (that's `/reforest`), NOT a routine single-branch rebase.

## The motion

### 1 · Recon

`stack-merge-rank <project>` gives the canonical bottom-up landing order — consume it, don't
re-derive. Mark convergence-only ★ nodes (`requires` several bases — a whole-feature view, never
a PR). `git fetch origin main`; if any branch is behind, restack before anything else — a PR off
a stale base is noise.

### 2 · Restack onto fresh origin/main

Follow forests.md *Restacking* exactly (refresh main → snapshot SHAs → bottom-up `--onto`,
naming the branch → diffstat parity → contract empty nodes as part of the walk). Forest-wide
additions: carry `requires` cherry-picks, and **never rewrite a branch with an open PR** — once
a PR is live, its history is frozen.

### 3 · Draft the PR bodies

`stack-pr-body <branch>` per PR-able branch, in merge order. Default output is furniture — the
purpose + merge-order block shaped to sit UNDER the user's own prose (above the Traffic Cop
template); `--full` emits the standalone document. Hand over paste-ready blocks; skip ★ nodes.

### 4 · Hand off

Present the landing order plainly: what merges first, what waits on what. The user pushes every
branch and opens every PR (spine hard rule); independent bases go in parallel, a chained child
after its parent lands.

### 5 · Contract until drained

Each time a base squash-merges, repeat step 2 — the merged node drops, its children rewire, the
graph contracts by one. A rebase is the comment-gate checkpoint (style topic *Comments*). Loop
until only `main` remains.

## Guardrails

- No push, no PRs (spine); worktree, never the user's main checkout.
- Restack onto **fresh** `origin/main` before drafting or handing off.
- Contract empty nodes the moment they appear; leave open-PR branches unrewritten.
- The ★ convergence node is a view — never draft a body for it or count it in the order.
