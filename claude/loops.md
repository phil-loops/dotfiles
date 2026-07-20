# Loops Repo

## Remotes

- `origin` (`Loops-so/loops`) — the shared team repo, and where branches **and** PRs actually live: branches are pushed straight to origin and PRs are opened origin-internal (head branch → `main`, same repo — not fork PRs). **Claude never pushes here and never opens PRs.** Phil pushes branches himself (GH Desktop, → viewer per the push-to-origin work) and opens every PR manually. Claude's job ends at a prepped local branch + a drafted PR body handed off.
- `phil-loops` (`phil-loops/loops`) — Phil's fork. **Not part of the PR workflow** (those branches are origin-internal, above), but not dead: it holds bench/experimental branches (e.g. `bench/goal-metrics`) and is the repo's `stack-push.remote` default. So a *PR* branch never goes here (it'd be orphaned); a throwaway/bench branch may. When in doubt, it's Phil's push either way.

## Script runner

The loops repo has a centralized script runner at `script-runner/`.

```bash
# Run a script (DRY_RUN=true by default)
npm run script-runner <scriptName> -- <args...>

# Run for real
DRY_RUN=false npm run script-runner <scriptName> -- <args...>
```

Each script exports `(dryRun: boolean, ...args: string[]) => Promise<void>` and is registered in `script-runner/index.ts`.

## Taskfile

The loops repo uses [go-task](https://taskfile.dev/) for project commands. **Always prefer Taskfile tasks over raw commands** (npm, npx, etc.):

```bash
task lint                # oxlint + oxfmt + prisma format
task clickhouse:migrate  # run ClickHouse migrations (uses correct URL)
task ci:run              # full CI pipeline locally
```

Run `task --list` to see all available tasks. Use the team's tools — don't reinvent with raw commands.

## Typecheck

Whenever a change touches a typed boundary (zod validators, tRPC inputs, model/query signatures, exported types) run a full project typecheck before declaring done. **Default to tsgo** — since the nodenext migration it typechecks this repo cleanly and ~3.6× faster than tsc (≈10s vs ≈37s):

```bash
tsgo --project typescript/tsconfig.runtime.json --noEmit   # the default full typecheck
tsgo --project typescript/tsconfig.test.json --noEmit      # + tests
```

(`tsconfig.node.json` was split into these two by PR #9599 on 2026-07-19 — a branch from before the split still carries the old single config. The loops pre-push hook runs the same checks, gated to TS-changed pushes; bypass with `TSGO_SKIP=1`.)

CI typechecks the same surfaces via `task lint:typecheck` (many per-entry configs) and agrees with tsgo on this repo, so **don't run tsc locally as a routine check** — reach for it only when you need the CI-exact verdict (e.g. CI is red but tsgo is green), and then always queued: `tsc-turn npx tsc --project typescript/tsconfig.runtime.json --noEmit`. `tsc-turn` (`~/.dotfiles/scripts/tsc-turn`) is a machine-wide compile queue: at most 2 heavy checks run at once, extra callers wait their turn. With several Claude sessions live, seven concurrent `tsc` runs flatten the machine (2026-07-06) — route any tsc run or build through it; it adds nothing when the machine is idle.

`oxlint --type-aware` and `oxfmt` are NOT typecheckers — they catch lints and formatting, not assignment compatibility across function boundaries.

**Caveat — the tRPC client type is a generated artifact.** A worktree with stale/missing generated types floods `tsc` with hundreds of `.tsx` errors that all trace to one collapsed type (`TS2339` "Property X does not exist on type '...collides with a built-in method...'" plus cascading implicit-`any` params). That's noise from un-built types, not your change. Filter to what you touched (`... --noEmit 2>&1 | grep <your-file>`) to read the real signal, or build the types first (`task trpc:types`).
