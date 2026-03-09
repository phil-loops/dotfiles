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

Use **git-town** for stacked PRs.

**IMPORTANT: Always create branches with git-town, never `git checkout -b`:**

```bash
git town append <name>   # Create child of current branch
git town prepend <name>  # Create parent of current branch
```

If you accidentally created a branch with `git checkout -b`, fix it:

```bash
git town set-parent <parent-branch>
```

| Task                       | Command                         |
| -------------------------- | ------------------------------- |
| Create child branch        | `git town append <name>`        |
| Create parent branch       | `git town prepend <name>`       |
| Set parent (fix untracked) | `git town set-parent <branch>`  |
| Sync all branches          | `git town sync`                 |
| Create PR                  | `git town propose`              |
| Navigate up/down           | `git town up` / `git town down` |
| View stack                 | `git town branch`               |
| Squash commits             | `git town compress`             |
| Move branch out of stack   | `git town detach`               |

Run `git town help` for full reference.

# Code Layering

Follow a strict layering pattern: **queries → models → wiring**.

- **Queries** are thin data-access wrappers — one DB call per function, no business logic, no authorization, no cross-table joins or transactions
- **Models** contain business logic with dependency injection — validation, authorization, cross-entity operations, cascading deletes
- **Wiring** integrates models into handlers/routers/jobs — minimal glue code
- tRPC routers, API routes, and job handlers are all **wiring** — they call models, not queries directly
- If a function touches multiple tables, has conditional logic, or does authorization checks, it belongs in models, not queries

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

# Git Changes

Never add Co-Authored-By lines. Never commit — the user will handle commits themselves.

Structure changes atomically — each branch/commit should be a single, self-contained change. When working on multi-part changes, decouple them into separate branches in the stack, ordering zero-dependency changes first.

# Git Pushing & PRs

**Never push to origin or open PRs.** The user will handle pushing and opening PRs themselves.

In the loops repo specifically:
- `phil-loops` (`phil-loops/loops`) — Phil's fork. This is our workspace for branches, PRs, and experimentation. Push here freely when needed.
- `origin` (`Loops-so/loops`) — Shared team repo. **Never push here or open PRs** unless the action is 100% unambiguous and explicitly requested. Treat as read-only.
