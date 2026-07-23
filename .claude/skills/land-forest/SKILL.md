---
name: land-forest
description: Land an already-built stacked-PR forest — the shipping motion that complements /reforest's building motion. Restacks every branch onto fresh origin/main (raw git, bottom-up, contracting any already-merged node), confirms the canonical merge order, drafts a forest-framed PR body per branch (stack-pr-body), hands the push + PR-opening to the user, and contracts the forest after each base merges. Use when the work is split into a forest and the user wants to ship it — "see this forest out", "land these PRs", "ship the stack", "get this forest merged", "prep the forest for push", or after /reforest when it's time to merge. NOT for building/splitting a forest (that's /reforest) or a routine single-branch restack.
---

# Land Forest — ship an existing forest out to merged

`/reforest` builds the forest; this lands it. Take a forest whose branches + config already exist and
carry it to merged: restack onto fresh `origin/main`, draft the PR bodies, hand off the push/PRs to
the user, and contract the forest as each base lands — until it drains to zero.

Leans **entirely** on CLAUDE.md — read these first, don't re-derive: **Restacking after a merge —
first principles**, **Forest hygiene**, **Git Pushing & PRs**, **Worktree for multi-step git work**.
This skill is the workflow that sequences them for a whole forest. Tools it orchestrates:
`stack-merge-rank` (canonical order), `stack-pr-body` (PR bodies), raw git for restack/contract.

## When to use

- "see this forest out", "land these PRs", "ship the stack", "get this merged", "prep for push" —
  on a forest whose branches + `stack-branch.*`/`stack-project.*` config already exist.
- Often **right after `/reforest`**: the forest is built, now merge it.
- NOT `/reforest` (that builds the forest) and NOT a routine single-branch `task`/rebase.

## Hard rule

**Claude never pushes and never opens PRs** (CLAUDE.md *Git Pushing & PRs*). This skill restacks,
drafts bodies, and contracts; the **user** pushes and opens PRs (origin, via GitHub Desktop). Every
git move happens in a `git worktree`, never the user's main checkout.

## The motion

### 1 · Recon — order + staleness

- Canonical merge order: `stack-merge-rank <project>` → the bottom-up landing sequence (stable sort,
  declared-order tie-break baked in). Consume it; don't re-derive a topo.
- Mark **convergence-only** nodes (the ★ integrator — `requires` several bases, never its own PR).
  These are NOT PRs; they're a whole-feature view.
- Staleness: `git fetch origin main`; per branch `git rev-list --count <branch>..origin/main`. If any
  is behind, restack before anything else — a PR off a stale base is noise.

### 2 · Restack onto fresh origin/main (raw git, bottom-up)

Per CLAUDE.md *Restacking — first principles*, in a worktree:

- `git branch -f main origin/main` (move the ref; main usually isn't checked out here).
- **Snapshot each branch's tip SHA before moving anything** — descendants need the pre-rebase parent
  SHA as the `--onto` cut point.
- Rebase **bottom-up**: roots onto `main`, then each child onto its *moved* parent —
  `git rebase --onto <new-parent> <old-parent-sha> <branch>`. Carry `requires` cherry-picks too.
- **Contract as you go**: any branch whose `git diff <parent>...<branch>` is now empty (its work
  squash-merged) is done — `git branch -D` it and rewire its children's `.parent` onto the dropped
  node's parent (and fix the `stack-project.*.branch` list + any child descriptions that named it).
  An empty node left hanging is the confusing state; contracting preserves graph integrity.
- Resolve real conflicts in the rebase (don't `--skip`/`-X`); a genuine logic clash is a check-in
  point, not a guess. A value-only redundant-with-main clash → take main's value, drop the empty
  commit, flag it (CLAUDE.md *Value-only rebase conflict*).
- **Don't rewrite a branch with an open PR** — once a PR is live, leave its history alone.
- Refresh every touched branch's `description` if an ancestry change made it stale (CLAUDE.md
  *Branch purpose*).

### 3 · Draft the PR bodies

`stack-pr-body <branch>` per PR-able branch, in merge order. The default output is furniture, not a
document: the branch's one-line purpose plus the merge-order block, shaped to sit UNDER the user's
own prose (and above the Traffic Cop template) — the user's voice goes on top, the furniture
guarantees the rationale and forest position ship with it. `--full` still emits the old complete
document (where-it-fits + stored change summary + mermaid) when a body needs to stand alone. Hand
the user paste-ready blocks; skip the convergence-only ★ node (no PR).

### 4 · Hand off — the user pushes + opens PRs

Present the landing order plainly: which PR merges first, what each waits on. The user pushes each
branch and opens its PR into `main` (independent bases in parallel; a chained child after its parent
lands). Claude does not push or open PRs.

### 5 · Contract after each merge — until the forest drains

When a base squash-merges (the user reports it, or `origin/main` advances), repeat **step 2**: rebase
the forest onto fresh `origin/main`, drop the now-empty merged node, rewire its children. The graph
contracts by that node. Re-read any rewritten branch's `parent...child` diff against the comment gate
(CLAUDE.md *Comments*) — a rebase is the free moment to trim narration. Loop until every PR-able node
has merged and only `main` remains.

## Guardrails

- Never push, never open PRs — the user does both. Worktree, not the main checkout.
- Restack onto **fresh** `origin/main` before drafting/handing off — a stale base makes a noisy PR.
- Contract empty nodes the moment they appear; never leave a zero-diff branch hanging.
- Leave branches with open PRs unrewritten.
- The ★ convergence node is a view, not a PR — never draft a body for it or count it in the order.
