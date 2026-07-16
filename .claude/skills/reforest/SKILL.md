---
name: reforest
description: Reshape a chunk of work into a reviewable stacked-PR forest, then execute it. Splits the work into single-capability branches (bases + children + fan-in), writes a plain one-line purpose for each, and emits the MERGE-STORY plan — ordered semantic commits (type(scope): subject) with builds-on/requires sequencing and a per-node implementation note — for sign-off, then creates the branches + sets parent/requires/project/description and moves the commits. Use when the user wants to restructure a fat branch, a fused PR, or a pile of uncommitted changes into properly-scoped PRs — "reforest this", "split this into a forest/stack", "restructure these changes into PRs", "turn this branch into a forest". NOT for designing-before-code (that's /design) or routine restack-after-merge (raw git per CLAUDE.md *Restacking*).
---

# Reforest — reshape work into a reviewable forest

Take a chunk of work — a fat branch, a fused PR, a pile of uncommitted changes — and reshape it
into a clean stacked-PR forest: single-capability branches (bases + children + fan-in), each with a
plain one-line purpose, in dependency order. Produce the **merge-story plan** for sign-off, then
execute the branch/commit moves on approval.

This is the restructure motion CLAUDE.md calls "reforesting." It leans **entirely** on the forest
conventions there — read them first, don't re-derive: **Forest PR Design**, **Git Branch Forests**,
**Branch purpose**, **Creating branches**, **Restacking**. This skill is the workflow that applies
them to a concrete pile of work and ends in the viewer's story view.

## When to use

- "reforest this", "split this branch into a forest/stack", "restructure these changes into PRs",
  "turn this into properly-scoped PRs", "this fat branch should be N PRs".
- NOT `/design` (that's designing *before* code) and NOT routine restack-after-merge (raw git).

## The loop

1. Read the work → 2. Propose the forest → 3. Write plain purposes → 4. Emit the merge-story plan →
5. Sign-off → 6. Execute. Steps 2–4 are **one artifact you revise with the user**; nothing touches
git until they approve.

## 1 · Read the work

- Identify the source: a branch (`git diff main...<branch>`), a PR, or uncommitted changes.
- Inventory by **capability, not by file**: what distinct, independently-reviewable things does this
  do? A generic helper/primitive, a schema change, a query layer, a model, wiring, a cleanup — each
  is a candidate branch. The test is the capability, not the caller: a helper used by an engine is
  its OWN base (the engine chains on it), not a commit buried inside the engine.

## 2 · Propose the forest

- One **single-verb** branch per capability (`add X`, `record X`, `emit X`, `use X in Y`,
  `remove X`). Size tracks concern-count, not a line budget.
- **Bottom-up by dependency**: schema/migration → queries → models → wiring → refactors/cleanup.
- **Independent capabilities fork off `main` as siblings** — each its own base, independently
  mergeable. **Chain** (set a non-main `parent`) on a *real* dependency: the branch needs that one
  base's content to compile, build, or run. Integrators converging **two or more** independent
  bases **fan in** via `requires` (parent = one, `requires` = the rest); exactly one `requires` on
  a main-rooted branch is a mis-encoded chain. Splitting is the default; when unsure, split more.
- **Query and model branches must carry tests** — a query branch ships with its query tests (real
  DB, `createX` factories) and a model branch with its model tests (DI + `t.mock.fn()`), co-located.
  A query/model branch without tests is mis-scoped the same way a non-compiling base is — plan the
  tests into the branch, don't defer them to a later PR.
- For each branch decide its `parent` (git rebase base) and any `requires` (fan-in deps it carries).

## 3 · Write plain purposes

- Each branch gets a one-line **purpose** in the plain register (CLAUDE.md *Branch purpose*): what
  it DOES, no raw identifiers (`markLocked`, `getOrFetch`) or terms-of-art (`idempotent`,
  `monotonic`, `short-circuit`); keep forest vocab (`requires`, fan-in, convergence). This one line
  seeds both the story and the PR body — write it well, not as a later de-jargon pass.

## 4 · Emit the merge-story plan

Present the forest as the **merge-story** — the same artifact the viewer renders, as text:

```
<project> → main, in merge order:
1  feat(<scope>): <plain subject>
2  feat(<scope>): <plain subject>            (independent base off main)
   3  feat(<scope>): <plain subject>         ↳ builds on 1                  (true child, indented)
   4  refactor(<scope>): <plain subject>     ↳ builds on 2
★  feat(<scope>): converge …                 converges 1·3·4 — never merges
```

- **Order** = topological over `parent` + `requires`. For an already-built forest the canonical
  order is `stack-merge-rank <project>` (a stable sort with the declared-order tie-break baked in) —
  consume it, don't re-derive.
- **`type`** = `feat` for a new capability, `refactor`/`chore` for cleanup, by the branch's nature.
- Distinguish **`↳ builds on N`** (a true `parent` — stacked code) from **`⤿ requires N — merges
  after`** (an integrator carrying ≥2 bases beyond its parent lists the extras this way). A branch
  with exactly ONE prerequisite builds on it — one dep is a parent, never a lone `requires`.
  Indent true children.
- For each branch: the **plain subject** (identifier-free) + one **non-trivial implementation note**
  from its slice of the diff (a mechanism, invariant, gotcha, or perf/correctness choice).
- This is the **contract**. Revise it with the user until the split, order, labels, and purposes are
  right. Nothing moves in git until sign-off.

## 5 · Sign-off

Get explicit approval on the plan before any branch/commit surgery.

## 6 · Execute (on approval)

Do **all** surgery in a `git worktree`, never the user's main checkout (they drive that via GitHub
Desktop concurrently). Walk the branches in dependency order; per branch:

- `git checkout <parent> && git checkout -b <branch>` — fork from the intended parent (`main` for an
  independent base). The parent relationship is implicit in the fork point.
- Move the work onto it: cherry-pick the relevant commits, or `git restore -p` / `git checkout -p`
  the capability's hunks from the source, then commit (clean, single-purpose commit; no
  Co-Authored-By; never amend). Each **base must compile on its own** — typecheck it
  (`npx tsc --project tsconfig.node.json --noEmit`) before moving on. A base that won't compile
  alone is mis-split — re-cut it. For query/model branches, run their tests too — untested
  queries/models don't leave this step.
- Set its config in the **same motion** (the forest config is hand-maintained; the viewer reads it):
  - `git config branch.<branch>.description "<purpose>"`
  - `git config stack-branch.<branch>.parent <parent>`
  - `git config stack-branch.<branch>.project <project>` and
    `git config --add stack-project.<project>.branch <branch>`
  - fan-in: `git config --add stack-branch.<branch>.requires <dep>` per dep
- **Never push, never open PRs** — the user does that.

When done, the viewer renders the forest's story straight from this config (`⌘K → "merge story"`,
or `≣ story` on the forest overview), and `stack-pr-body <branch>` drafts each PR body — same plain
purposes underneath. Run the comment gate (CLAUDE.md *Comments*) as you go: reforesting is the free
moment to delete narration that survived the first pass.

## Guardrails

- Plan before surgery; explicit approval before any git move.
- Worktree, not the main checkout. No push, no PRs.
- A base that doesn't compile on its own is mis-split — re-cut, don't ship.
- Query and model branches ship with their tests — no test-less query/model PRs.
- More small independently-mergeable bases beats one fused branch. When unsure, split.
