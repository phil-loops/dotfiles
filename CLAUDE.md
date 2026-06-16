# Dotfiles

When updating dotfiles (scripts, zshrc, CLAUDE.md, etc), `zsource` commits + pushes + reloads:

```
cd ~/.dotfiles && git add -A && git commit -m 'Update dotfiles' && git push && cd - && source ~/.zshrc
```

**Claude: do NOT use `zsource` / `git add -A` here.** Phil often has concurrent in-progress
dotfiles work, and `-A` sweeps his uncommitted WIP into your commit (it once bundled his ledger
scripts into an unrelated `.zshrc` commit). Instead: run `git status` as its own step, then stage
**explicit paths** (`git add .zshrc`), commit, push. **Never `git push --force` a branch another
session may be live on** — that clobbers pushed work; leave a cosmetically-wrong commit message
alone rather than rewrite shared history. The reload (`source ~/.zshrc`) only affects your own
subshell, so tell Phil to source it in his terminal to pick up the change.

**Concurrent sessions: claim a lane, respect others' (`own` + `OWNERS`).** When multiple Claude
sessions work this repo in parallel, each takes ONE lane (viewer / forest / stack / docs — see
`~/.dotfiles/OWNERS`). At the start of dotfiles work run `own claim <your-lane>`; before editing any
file run `own who <path>` — if it's YOUR lane, edit directly; if it's another lane (especially one
flagged ⚠ ACTIVE), use the patch protocol below. Explicit lanes keep two sessions out of the same file.

**Editing a file another session is live on → author via patch, never direct.** A file is "live"
if it's dirty in `git status`, has a recent mtime, or changed between your Read and Edit. Writing it
directly races/clobbers the other session. Instead:

1. **Author in a throwaway worktree at HEAD** — `git worktree add --detach /tmp/wt HEAD`, edit there
   (clean surface, zero collision).
2. **Capture a patch artifact** — `git -C /tmp/wt diff > ~/.dotfiles/patches/<name>.patch` (durable,
   reviewable, timing-independent, hand-off-able).
3. **Land with `git apply --3way`** — merges non-overlapping hunks, leaves conflict markers on
   overlap, *never* silent-clobbers. `git apply --check` tests it read-only first.

Apply when the file goes quiet, or hand the `.patch` to the session that owns the file. This is the
standard for any contested file — it turns "two hands on one file" into a clean merge-or-conflict.

## Script Placement

**Never put scripts in ~/bin.** Always place scripts in `~/.dotfiles/` so they're version controlled:

- Shell functions: `~/.dotfiles/.zshrc` or dedicated files sourced from it
- Standalone scripts: `~/.dotfiles/scripts/`

This ensures nothing is lost if the computer dies.

# Git Branch Forests

Think in **forests, not stacks** — a linear chain is just the degenerate case. Branches form a DAG: each has one git `parent` (its rebase base), and may **fan out** (many children) or **fan in** (carry several independent base branches at once). Claude manages this plumbing — the user delegates it and runs no stack-specific commands.

**The aim: maximize independently-mergeable base PRs, then converge them with fan-in.** If two capabilities don't depend on each other (e.g. a Valkey cache vs. a JobStatus query change), each forks off `main` and merges on its own schedule — do NOT chain one behind the other just to make a line. Linearizing independent work forces a false merge order and blocks each PR on the others. The integrator that needs both records them as fan-in deps.

## Two relationships per branch

- **`parent`** (single) — the git base this branch is rebased onto. `git config stack-branch.<name>.parent <parent>`.
- **`requires`** (multivar, optional) — fan-in deps: branches this one *carries* (cherry-picked) beyond its `parent`. Metadata only — the `parent...child` review diff is unchanged; `requires` drives the forest viewer's inbound edges and restack re-sync. `git config --add stack-branch.<name>.requires <dep>`.

A pure line uses only `parent`; fan-in adds `requires`. **Never any git merge commits** — fan-in is metadata over linear history (carried cherry-picks), so squash-merge still drops redundant commits cleanly on rebase.

## Branch purpose

Every branch carries a one-line **purpose** — what it's for / what it lays the foundation for — stored as git's native **branch description** (`git config branch.<name>.description`, a.k.a. `git branch --edit-description`). Git owns it, it's free to read, and it shows in the forest viewer under each node.

- **Set it as you create or edit a branch** — `loops purpose <branch> "<thesis>"`. Capturing intent at creation is the whole point; don't leave branches purposeless. When Claude creates branches for a stack, it sets each one's purpose.
- **Keep it current** — when a branch is repurposed, rebased onto different work, or its scope shifts, update the description. A stale purpose is worse than none.
- The viewer reads the description for **free** (no LLM). A "suggest" button can draft one from the diff (opt-in, haiku) which you then save as the description — **generation never runs automatically**, nothing burns tokens on its own.

## Creating branches

Always create from the intended parent (the branch this one stacks on top of). Use plain `git checkout -b`:

```bash
git checkout <parent-branch>           # switch to the intended parent first
git checkout -b <new-branch-name>      # child branch forks from current HEAD
```

The parent relationship is **implicit in the fork point** — git does not track it natively. Two places need to know the parent explicitly:

1. **PRs**: always `gh pr create --base main` — every branch merges into main, never onto its parent. Independent bases (forked off main) keep each PR's diff to its own work; a genuinely-dependent branch merges in order after its base lands. (Never let tooling open PRs — that's manual.)
2. **Rebase after parent changes**: `git rebase <parent>` (or `git rebase --onto <new-parent> <old-parent>` when moving a branch).

Record the parent in the PR body when opening (e.g. "Stacked on: #1234") so reviewers can see the order. And **set the branch's purpose right after creating it** — `loops purpose <new-branch-name> "<one-line thesis>"` — so the intent is captured while it's fresh.

## Common tasks

| Task                       | Command                                                     |
| -------------------------- | ----------------------------------------------------------- |
| Create child branch        | `git checkout <parent> && git checkout -b <name>`           |
| Fork an independent base off main | `git checkout main && git checkout -b <name>` (no parent → roots off main) |
| Add a fan-in dep           | `git config --add stack-branch.<name>.requires <dep>`       |
| Set/update a branch's purpose | `loops purpose <name> "<thesis>"` (git branch description) |
| Review the forest (live)   | `loops stack review [<branch>]` (blessing-ledger server, reads git config per request) |
| Update branch after parent change | `git rebase <parent>`                                |
| Move branch to new parent  | `git rebase --onto <new-parent> <old-parent> <branch>`      |
| Restack whole project after a merge | `loops stack restack <project>` (see below)           |
| Create PR                  | `gh pr create --base main --head <branch>`                  |
| Squash commits             | `git reset --soft <parent> && git commit`                   |

## Restacking after a merge — `loops stack restack`

When the bottom of a stack merges, `loops stack restack <project>` rebases every
member onto fresh `origin/main`, bottom-up (topological), snapshotting SHAs so
descendants land on their moved parents. After the walk it drops branches that
became empty/merged and rewires children's parent metadata.

**Conflict handling is automated via headless `claude` (conservative bar).** On a
conflict the script invokes `claude -p` to attempt resolution and auto-resolves
*only* mechanically-certain cases — redundant squash-merged commits, generated
files / lockfiles, non-overlapping add/add — then continues the rebase. Anything
touching hand-written logic, delete/modify, or overlapping edits is **escalated**:
the script pauses, saves state, and prints a ready-to-run interactive `claude`
command (plus the manual git steps). Resolve, then `--continue` resumes the walk.

- `loops stack restack <project> --plan` — dry-run: topo order + parent map, no mutations
- `loops stack restack <project> --continue` — resume after a manual/escalated resolve
- `loops stack restack <project> --abort` — discard saved restack state
- `loops stack restack <project> --no-claude` — disable auto-resolve, always pause for a human
- Tunables: `CLAUDE_BIN` (default `claude`), `STACK_RESTACK_BUDGET_USD` (default 2)

Script: `~/.dotfiles/scripts/stack-restack`. Requires the project registered via
`stack-project.<name>.branch` config (not just the `stack-branch.*.parent` pointers).

## Reviewing changes

Two tools, different jobs — don't conflate them:

- **`loops stack review [<branch>]`** — solves the **stack-stepping** problem. Walks `stack-branch.<name>.parent` and shows each branch's incremental diff (`parent...child`) one link at a time in nvim diffview. Add `--html` to render each link as a side-by-side HTML and open them all in browser tabs. Doesn't know worktrees exist.
- **`wt [base-branch] [--html|-H]`** — solves the **worktree-discovery** problem. fzf-picks across sibling worktrees and shows the picked branch's *full* cumulative diff vs `base` (default `main`), including uncommitted working-tree changes (`--imply-local`). Not stack-aware — a 6-branch stack shows as one giant diff.

Decision rule:
- Branch is a stack, you know which one → `loops stack review`
- Single-branch feature, or scanning across many worktrees → `wt`
- Stacked branch lives in a sibling worktree → `cd` into it, then `loops stack review` (use both)

## Forest hygiene

- When a base branch merges, `loops stack restack <project>` rebases the forest onto fresh `main`, drops the now-redundant branch, and rewires its children. **The graph contracts by that node** — and keeps contracting as each independent base PR lands.
- When PRs squash-merge, the commit on `main` won't match the branch's commits — expected. `git rebase main` drops the now-redundant commits cleanly (holds for both `parent` and carried `requires`).
- **Git history stays linear — no merge commits**, even with fan-in. Fan-in lives in `requires` metadata + carried cherry-picks, not a git merge. (`stack-integrate` builds an *ephemeral* octopus-merge ref only as a "whole-feature-merged" preview, never as a branch base.)

# Loops Script Runner

The loops repo has a centralized script runner at `script-runner/`.

```bash
# Run a script (DRY_RUN=true by default)
npm run script-runner <scriptName> -- <args...>

# Run for real
DRY_RUN=false npm run script-runner <scriptName> -- <args...>
```

Each script exports `(dryRun: boolean, ...args: string[]) => Promise<void>` and is registered in `script-runner/index.ts`.

# Code Layering

Follow a strict layering pattern: **queries → models → wiring**.

- **Queries** are thin data-access wrappers — one DB call per function, no business logic, no authorization, no cross-table joins or transactions
- **Models** contain business logic with dependency injection — validation, authorization, cross-entity operations, cascading deletes
- **Wiring** integrates models into handlers/routers/jobs — minimal glue code
- tRPC routers, API routes, and job handlers are all **wiring** — they call models, not queries directly
- If a function touches multiple tables, has conditional logic, or does authorization checks, it belongs in models, not queries

## Naming conventions

- **File names** follow the team's kebab-case convention: `goal-contact-window.ts`, not `goalContactWindow.ts`
- **Query imports** use namespace imports with the full descriptive name: `import * as GoalContactWindowQueries from "..."` — not shorthand like `GCWQueries`. In tests the bare function name (`insert`, `findActiveByContact`) is obvious from context, but in model/wiring code the qualified name (`GoalContactWindowQueries.insert`) improves legibility.

## Type style

- **Inline object-parameter type literals in function signatures.** Don't declare a separate named type alias just to name the input shape. Example: `function update(input: { id: string; name?: string })` — not `type UpdateInput = { ... }; function update(input: UpdateInput)`. Standalone aliases pollute the file's mental context: readers have to scroll up to resolve the alias to understand the contract. Inlining keeps the contract at the call site, even with 5+ fields. Test code that uses `Deps<typeof fn>` / `Parameters<typeof fn>` extracts from the function itself, so inline types don't break it. Don't refactor pre-existing standalone types unless asked.

# Forest PR Design

Each branch is **one reviewable unit — a single capability that compiles on its own**, named with one verb (`add X`, `record X`, `emit X`, `use X in Y`, `remove X`). Size tracks concern-count, not a line budget: prefer 3× 80-line PRs over 1× 200-line PR — but a cohesive primitive + its tests is fine even at ~250. The reference standard is **nalanj's PRs**: a feature shipped as ~7 single-verb stacked PRs, tests co-located, each metric its own tiny PR.

## Ordering & shape

- **Bottom-up by dependency**: schema/migration → queries → models → wiring → refactors/cleanup.
- **Independent capabilities fork off `main` as siblings**, not chained — each independently mergeable. Only chain on a real dependency.
- **Integrators fan in**: a branch that needs several independent bases sets `requires` on them (and carries their commits), rather than forcing the bases into a false line.
- **Tests co-locate** with the code they test (`createX` with queries, `fakeX` with models).
- **Observability/metrics get their own small PRs.**

## Boundaries

- One layer (query / model / wiring) for one entity or concern per branch.
- UI branches separate from API branches, even for the same feature.
- Changes across 3+ unrelated directories → too big, split it.
- A branch that only makes sense *with* its child → merge it into the child.

## What NOT to do

- Don't put business logic in query branches (status checks, authorization, cross-entity cascades).
- Don't mix query expansions + tRPC endpoints + UI components in one branch.
- **Don't chain independent base capabilities into a line just to avoid fan-in** — that blocks each PR on the others' merge order.
- Don't add a column/migration in a middle branch when a schema branch exists — prepend/extend the schema branch.

# Taskfile

The loops repo uses [go-task](https://taskfile.dev/) for project commands. **Always prefer Taskfile tasks over raw commands** (npm, npx, etc.):

```bash
task lint              # oxlint + oxfmt + prisma format
task clickhouse:migrate  # run ClickHouse migrations (uses correct URL)
task ci:run            # full CI pipeline locally
```

Run `task --list` to see all available tasks. Use the team's tools — don't reinvent with raw commands.

# Typecheck

Whenever a change touches a typed boundary (zod validators, tRPC inputs, model/query signatures, exported types) run a full project typecheck before declaring done:

```bash
./node_modules/.bin/tsc --project tsconfig.node.json --noEmit
```

`oxlint --type-aware` and `oxfmt` are NOT typecheckers — they catch lints and formatting, not assignment compatibility across function boundaries.

# Git Changes

Never add Co-Authored-By lines. Never amend commits — always create new commits. History doesn't matter since PRs are squash-merged. Committing locally is fine (make clean, self-contained commits) — but never push or open PRs; the user handles those (see *Git Pushing & PRs*).

Structure changes atomically — each branch/commit should be a single, self-contained change. When working on multi-part changes, decouple them into separate branches in the stack, ordering zero-dependency changes first.

# Git Pushing & PRs

**Never push to origin or open PRs on origin.** The user will handle pushing and opening PRs themselves.

In the loops repo specifically:
- `phil-loops` (`phil-loops/loops`) — Phil's fork. This is our workspace for branches, PRs, and experimentation. Push here freely when needed. **Only open PRs on this remote.**
- `origin` (`Loops-so/loops`) — Shared team repo. **Never push here. Never open PRs here.** Treat as read-only.
