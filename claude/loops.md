# Loops Repo

## Remotes

- `phil-loops` (`phil-loops/loops`) — Phil's fork. This is our workspace for branches, PRs, and experimentation. Push here freely when needed. **Only open PRs on this remote.**
- `origin` (`Loops-so/loops`) — Shared team repo. **Never push here. Never open PRs here.** Treat as read-only.

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

Whenever a change touches a typed boundary (zod validators, tRPC inputs, model/query signatures, exported types) run a full project typecheck before declaring done:

```bash
tsc-turn npx tsc --project tsconfig.node.json --noEmit   # the repo's own CI typecheck, queued
```

`tsc-turn` (`~/.dotfiles/scripts/tsc-turn`) is a machine-wide compile queue: at most 2 heavy checks run at once, extra callers wait their turn. With several Claude sessions live, seven concurrent `tsc` runs flatten the machine (2026-07-06) — always route full typechecks and builds through it; it adds nothing when the machine is idle.

This is the exact command CI runs, so it's the source of truth. `tsgo` (the global native compiler) now typechecks this repo cleanly — the old `moduleResolution=node10` rejection was fixed by the nodenext migration, so it's a valid *fast* local typecheck (the loops pre-push hook uses it, gated to TS-changed pushes; bypass a run with `TSGO_SKIP=1`). Keep `tsc-turn npx tsc` as the CI-canonical check. `oxlint --type-aware` and `oxfmt` are NOT typecheckers — they catch lints and formatting, not assignment compatibility across function boundaries.

**Caveat — the tRPC client type is a generated artifact.** A worktree with stale/missing generated types floods `tsc` with hundreds of `.tsx` errors that all trace to one collapsed type (`TS2339` "Property X does not exist on type '...collides with a built-in method...'" plus cascading implicit-`any` params). That's noise from un-built types, not your change. Filter to what you touched (`... --noEmit 2>&1 | grep <your-file>`) to read the real signal, or build the types first (`npx tsc --project tsconfig.trpc-types.json`).
