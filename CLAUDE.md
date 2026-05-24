# Dotfiles

When updating dotfiles (scripts, zshrc, CLAUDE.md, etc), use `zsource` to commit and reload:

```
cd ~/.dotfiles && git add -A && git commit -m 'Update dotfiles' && git push && cd - && source ~/.zshrc
```

## Script Placement

**Never put scripts in ~/bin.** Always place scripts in `~/.dotfiles/` so they're version controlled:

- Shell functions: `~/.dotfiles/.zshrc` or dedicated files sourced from it
- Standalone scripts: `~/.dotfiles/scripts/`

This ensures nothing is lost if the computer dies.

# Git Branch Stacks

Use plain git for stacked PRs. Claude manages parent relationships — the user delegates stack plumbing and does not need to know or run any stack-specific commands.

## Creating branches

Always create from the intended parent (the branch this one stacks on top of). Use plain `git checkout -b`:

```bash
git checkout <parent-branch>           # switch to the intended parent first
git checkout -b <new-branch-name>      # child branch forks from current HEAD
```

The parent relationship is **implicit in the fork point** — git does not track it natively. Two places need to know the parent explicitly:

1. **PRs**: pass `--base <parent>` to `gh pr create` so GitHub shows only this branch's diff, not the whole stack.
2. **Rebase after parent changes**: `git rebase <parent>` (or `git rebase --onto <new-parent> <old-parent>` when moving a branch).

Record the parent in the PR body when opening (e.g. "Stacked on: #1234") so reviewers can see the order.

## Common tasks

| Task                       | Command                                                     |
| -------------------------- | ----------------------------------------------------------- |
| Create child branch        | `git checkout <parent> && git checkout -b <name>`           |
| Print stack as tree        | `stack-print [<tip>]` (walks `stack-branch.<name>.parent`)  |
| Review stack in nvim       | `loops stack review [<branch>]`                             |
| Review stack as HTML       | `loops stack review [<branch>] --html` (one tab per link)   |
| Update branch after parent change | `git rebase <parent>`                                |
| Move branch to new parent  | `git rebase --onto <new-parent> <old-parent> <branch>`      |
| Create PR                  | `gh pr create --base <parent> --head <branch>`              |
| Squash commits             | `git reset --soft <parent> && git commit`                   |

## Reviewing changes

- `loops stack review` — opens nvim diffview and steps through each branch's incremental diff (`parent...child`) in stack order. Add `--html` to render each link as a side-by-side HTML diff and open them all in browser tabs (useful when sharing or scanning quickly).
- `wt [base-branch] [--html|-H]` — fzf-picks a sibling worktree and shows its full diff vs `base` (default `main`). Not stack-aware; use `loops stack review` for per-link stepping. `--html` mode renders one HTML and opens it.

## Stack hygiene

- When the bottom branch of a stack merges, rebase every downstream branch onto the new `main` in order (lowest → highest). Resolve conflicts once per branch.
- When PRs squash-merge, the commit on `main` won't match the branch's commits — this is expected. `git rebase main` will drop the now-redundant commits cleanly.
- Keep the stack linear — no merge commits between branches in the same stack.

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

# Stacked PR Design

Each branch in a stack should be **one reviewable unit** — a single concern that compiles and makes sense on its own.

## Branch ordering

Stack branches bottom-up by dependency, not by feature area:

1. **Schema / migrations** — table changes land first, everything else builds on them
2. **Queries** — thin DB wrappers for the new tables, one branch per entity or closely-related group
3. **Models** — business logic that composes queries, one branch per domain operation
4. **Wiring** — plug models into handlers/routers/jobs, one branch per integration point
5. **Refactors / fixes** — clean up layering violations or tech debt on top

## Branch boundaries

- A branch should touch **one layer** (query, model, or wiring) for **one entity or concern**
- Test files and factories land alongside the code they test — `createX` with queries, `fakeX` with models
- UI branches are separate from API branches even if they're for the same feature
- If a branch has changes across 3+ unrelated directories, it's probably too big — split it
- A branch that only makes sense *with* its child should be merged into the child

## What NOT to do

- Don't put business logic in query branches (status checks, authorization, cross-entity cascades)
- Don't mix query expansions + tRPC endpoints + UI components in one branch
- Don't add a column/migration in a middle branch if the schema branch already exists — amend the schema branch or prepend a new one

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
tsgo --project tsconfig.node.json --noEmit
```

tsgo (the Go-native TypeScript port) does the whole loops project in ~1.5s vs tsc's 30s+. Same error coverage. `oxlint --type-aware` and `oxfmt` are NOT typecheckers — they catch lints and formatting, not assignment compatibility across function boundaries.

# Git Changes

Never add Co-Authored-By lines. Never amend commits — always create new commits. History doesn't matter since PRs are squash-merged. Never commit — the user will handle commits themselves.

Structure changes atomically — each branch/commit should be a single, self-contained change. When working on multi-part changes, decouple them into separate branches in the stack, ordering zero-dependency changes first.

# Git Pushing & PRs

**Never push to origin or open PRs on origin.** The user will handle pushing and opening PRs themselves.

In the loops repo specifically:
- `phil-loops` (`phil-loops/loops`) — Phil's fork. This is our workspace for branches, PRs, and experimentation. Push here freely when needed. **Only open PRs on this remote.**
- `origin` (`Loops-so/loops`) — Shared team repo. **Never push here. Never open PRs here.** Treat as read-only.
