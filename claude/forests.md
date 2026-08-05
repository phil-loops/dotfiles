# Git Branch Forests

**Reviewability is the only goal: a reviewer holds each entire PR in their head in one sitting.** Branches form a DAG — one git `parent` (the rebase base) each, fanning out (many children) or fanning in (carrying several bases). Claude runs all this plumbing; Phil runs no stack commands and opens every PR himself.

## Shape heuristics — what decides a split

- **One branch = one capability that compiles alone**, named with one verb (`add X`, `emit X`, `use X in Y`, `remove X`). Write the one-line purpose FIRST: **every "and" joining two behaviors is a split point.**
- **Concern-count, not line-count — and moved code counts the same as new code.** An extraction has one concern per relocated function that has its own callers or reason to exist ("extracts the checks *and* the insert" = two branches). Moves slice *smaller* than new code — reviewing a move means verifying faithful relocation line by line. The "cohesive primitive + its tests, even ~250 lines" allowance covers NEW primitives only, never relocations. (2026-08-04: a 361-line extract-to-model node passed every written test here and read as a mess.)
- **Is this its own capability?** A change that stands alone — a generic helper, a different layer, a separate entity — gets its own base, never folded into the branch that happened to need it first (a generic S3 helper used by an engine is its own base; the engine chains on it).
- **Independent capabilities are siblings off `main`**, each independently mergeable. Chain only on a real compile/content dependency; never linearize independent work to avoid fan-in. Prefer 3× 80-line PRs over 1× 200-line PR. Reference standard: nalanj's PRs — a feature as ~7 single-verb stacked PRs, tests co-located, each metric its own tiny PR.
- **The ladder**: cleanup-that-later-bands-build-on (bottom, only when downstream depends on it) → queries+tests → models+tests → wiring+tests → endpoints+tests (tRPC routers are wiring). Let a band be empty rather than fuse two. Tests ride in the band of the code they cover. UI branches separate from API branches. Observability/metrics get their own small PRs.
- **Don't**: business logic in query branches; queries+tRPC+UI in one branch; 3+ unrelated directories (split it); a migration in a middle branch when a schema branch exists. A branch that only makes sense with its child merges into the child.

## When the split rules bind — while building, not at review

Shape rules consulted only at reforest time have already failed. They bind at three moments:

- **Before the first commit: plan the forest.** Name the branches and their one-line purposes before writing code. Work discovered mid-build gets its own branch — usually a base cut underneath — never a commit on top of the current one.
- **Before every commit: the description is the gate.** If the diff does anything `branch.<n>.description` doesn't say, stop — that work is another branch. A commit subject needing a different verb than the description IS the "and" test failing, caught while the fix is one `git checkout -b`. (2026-08-04: "move the domain writes into query functions" committed onto a branch described "moves the sending-domain insert into the model" — queries introduced, modified, and consumed in one node.)
- **Before handoff: the band scan.** Bands map to directories — `queries/` → `models/` → wiring (`pages/api`, tRPC, jobs) → UI. A `parent...branch` diff spanning three bands is fused: re-cut it. Two adjacent bands is occasionally legit (a model plus its single adoption site).

## Two relationships per branch

- `parent` (single) — the rebase base: `git config stack-branch.<n>.parent <p>`.
- `requires` (multivar) — fan-in deps this branch carries as cherry-picks beyond its parent: `git config --add stack-branch.<n>.requires <dep>`. Metadata only — the review diff stays `parent...child`. **Reserved for branches converging 2+ bases**; exactly one dep is a chain (`parent = <dep>`) — a lone `requires` makes the diff re-review the dep. Never merge commits; history stays linear.

## Config + purpose — part of the operation itself, never a follow-up

At branch creation, in one motion: `git config branch.<n>.description "<thesis>"` + `stack-branch.<n>.parent` + `stack-branch.<n>.project` + `git config --add stack-project.<proj>.branch <n>`. The description is one verb-first plain line — behavior, not identifiers or terms-of-art (forest vocab is fine); it seeds the viewer and the PR-body drafter. **Refresh every touched description on ANY ancestry or scope change** — a description naming a parent the branch no longer has is a bug the operation introduced. Never ask permission for any of this.

The `stack-*` keys rot (git manages only the `branch.<n>.*` namespace — deletes/renames leave dangling `stack-*` entries). Rename checklist: `git branch -m`, migrate `.parent` + `.project`, fix the registry entry, re-point children's `.parent`. Health-scan: `stack-doctor [<project>]`; sweep dead config: `stack-doctor --prune` (`--dry-run` previews).

Commit bodies' forest section bakes at prep-time only — never regenerate mid-flight (rewriting tips orphans children); descriptions DO refresh freely (config, not history).

## Creating

`git checkout <parent> && git checkout -b <name>`; an independent base forks from `origin/main` with `--no-track`. Squash within a branch: `git reset --soft <base-sha> && git commit` — use the branch's REAL base SHA, never a `main`/`origin/main` ref that may have moved mid-session (2026-08-04: a soft-reset onto a just-advanced ref silently baked a revert of other people's merged work). PR bases: nearest ancestor with an open PR, else main; record "Stacked on: #N" in the body. PR bodies stay terse: one line of purpose + a numbered forest-position list.

## Restacking after a merge — raw git, no wrapper

1. `git fetch origin main && git branch -f main origin/main` — refresh main BEFORE diagnosing or diffing anything.
2. Snapshot every branch's SHA first — descendants need the pre-rebase parent SHA as the cut point.
3. Bottom-up: `git rebase --onto <new-parent> <old-parent-sha> <branch>` — always name the branch; run each rebase in the worktree that has the branch checked out (throwaway worktree for unchecked-out branches). Verify diffstat parity after each move.
4. **Contract as part of the walk**: a branch whose `parent...child` diff is empty (or that's now an ancestor of main) is done — `git branch -D`, rewire its children's `parent`, clean its config. Never report "the branch is empty" and stop. Squash-merged commits drop cleanly.
5. A rebase is a comment-review checkpoint: re-read the diff against the comment gate and trim.

Conflicts: resolve them yourself, honestly; a real overlapping-logic conflict → check with Phil. The viewer's Restack button is Phil's, not Claude's plumbing.

## Reviewing

- **`stack web [<project>]`** — the primary review surface (browser; per-repo port from `stack-review-port`; reads git config live). This is where Phil reviews.
- **`wt [base]`** — cross-worktree, single-branch cumulative diff picker. **`stack review`** — legacy nvim stepping, offline only.
- The viewer also has mutating endpoints (`/checkout` moves the main working tree, `/squash`, `/restack`, `/prep`, …) and a read-only per-file `✦ chat`. Bouncing the server is safe and free — state is durable (gates verdicts in git config keyed by tree SHA; detached runs re-adopted via sidecar). The two hard taboos (probe mutating routes only with `__probe__`, never hand-write `gates-green-tree`) live in the spine.
