---
name: reforest
description: Reshape a chunk of work into a reviewable stacked-PR forest, then execute it. Splits the work into single-capability branches (bases + children + fan-in), writes a plain one-line purpose for each, and emits the MERGE-STORY plan — ordered semantic commits (type(scope): subject) with builds-on/requires sequencing and a per-node implementation note — for sign-off, then creates the branches + sets parent/requires/project/description and moves the commits. Use when the user wants to restructure a fat branch, a fused PR, or a pile of uncommitted changes into properly-scoped PRs — "reforest this", "split this into a forest/stack", "restructure these changes into PRs", "turn this branch into a forest". NOT for designing-before-code (that's /design) or routine restack-after-merge (raw git per CLAUDE.md *Restacking*).
---

# Reforest — reshape work into a reviewable forest

Take a chunk of work — a fat branch, a fused PR, a pile of uncommitted changes — and reshape it
into a clean stacked-PR forest. **Every shape, purpose, and config rule lives in
`claude/forests.md` — apply it, never re-derive or restate it here.** This skill adds only the
workflow: read → propose → merge-story plan → sign-off → execute, ending in the viewer's story view.

## When to use

- "reforest this", "split this branch into a forest/stack", "restructure these changes into PRs",
  "this fat branch should be N PRs".
- NOT `/design` (designing *before* code), NOT routine restack-after-merge (forests.md *Restacking*).

## The loop

1. Read the work → 2. Propose the forest → 3. Emit the merge-story plan → 4. Sign-off →
5. Execute. Steps 2–3 are **one artifact you revise with the user**; nothing touches git until
they approve.

## 1 · Read the work

Identify the source — a branch (`git diff main...<branch>`), a PR, or uncommitted changes — and
inventory it by **capability, not by file**. For work already shaped into branches, the first
check per branch is **atomicity**: diff vs its own description — anything the diff does that the
description doesn't say is an accreted concern, a candidate split.

## 2 · Propose the forest

Split per forests.md *Shape* (one capability per branch, concern-count, the ladder, siblings vs
chains, tests ride in their band; when unsure, split more). For each branch decide its `parent`
and any `requires`, and write its one-line purpose per forests.md *Config + purpose* — purpose
first, it seeds the story and the PR body.

## 3 · Emit the merge-story plan

Present the forest as the **merge-story** — the same artifact the viewer renders, as text:

```
<project> → main, in merge order:
1  feat(<scope>): <plain subject>
2  feat(<scope>): <plain subject>            (independent base off main)
   3  feat(<scope>): <plain subject>         ↳ builds on 1                  (true child, indented)
   4  refactor(<scope>): <plain subject>     ↳ builds on 2
★  feat(<scope>): converge …                 converges 1·3·4 — never merges
```

- **Order** = topological over `parent` + `requires`. For an already-built forest, consume
  `stack-merge-rank <project>` — don't re-derive.
- **`type`** = `feat` for a new capability, `refactor`/`chore` for cleanup.
- **`<scope>`** = the project's lowercased Linear ticket when one is set
  (`stack-project.<project>.ticket`), else the project name. Same scope on every branch.
- **`↳ builds on N`** = a true `parent` (indent these); **`⤿ requires N — merges after`** = the
  extra bases an integrator carries. One dep is a parent, never a lone `requires`.
- Per branch: the plain subject + one **non-trivial implementation note** from its slice of the
  diff (a mechanism, invariant, gotcha, or perf/correctness choice).
- This is the **contract** — revise until split, order, labels, and purposes are right.

## 4 · Sign-off

Explicit approval on the plan before any branch/commit surgery.

## 5 · Execute (on approval)

All surgery in a `git worktree`, never the user's main checkout. Walk branches in dependency
order; per branch:

- Fork from the intended parent (`git checkout <parent> && git checkout -b <branch>`), move its
  slice on (cherry-pick, or `git restore -p` the capability's hunks), commit clean and
  single-purpose.
- **Each base must compile alone** — `tsgo --project typescript/tsconfig.runtime.json --noEmit` —
  and query/model branches run their tests before moving on. Failing either = mis-split; re-cut.
- Set description + parent/project/requires (+ the project's Linear ticket, once) in the same
  motion, per forests.md *Config + purpose*.

The viewer then renders the story (`⌘K → "merge story"`, or `≣ story`), and
`stack-pr-body <branch>` drafts each PR body. Run the comment gate (style topic *Comments*) as
you go — reforesting is the free moment to delete narration.

## Guardrails

- Plan → approval → surgery, in that order. Worktree only. No push, no PRs (spine).
- A base that doesn't compile alone, or a query/model branch without tests, is mis-split — re-cut.
- More small independently-mergeable bases beats one fused branch.
- **Atomicity decays through iteration** — each revision round lands fixes "where the code already
  is." Re-run the diff-vs-description gate on every touched branch after every round, not only at
  creation.
