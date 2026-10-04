# Loops Repo

## Remotes

- `origin` (`Loops-so/loops`) — the shared team repo; branches and PRs live here, origin-internal (head branch → `main`, same repo — never fork PRs). Phil pushes via GH Desktop / the viewer and opens every PR manually (spine hard rule).
- `phil-loops` (`phil-loops/loops`) — Phil's fork: bench/experimental branches only (e.g. `bench/goal-metrics`), and the repo's `stack-push.remote` default. A PR branch never goes here — it'd be orphaned. When in doubt, it's Phil's push either way.

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

Run `task --list` for the full set.

## Migrations

**A new migration must pass squawk before it ships**, absent a stated reason. Run it the moment the file exists — CI (`lint-migrations`) runs the same check:

```bash
npx -y squawk-cli packages/prisma/migrations/<dir>/migration.sql
```

`.squawk.toml` applies automatically (already excludes `require-timeout-settings`, `prefer-timestamp-tz`); repo convention: `CREATE TABLE IF NOT EXISTS`. A wrong-for-the-case warning (e.g. `prefer-bigint-over-int` on a small bounded counter) gets an inline `-- squawk-ignore <rule>` directly above the statement — bare rule name, no trailing text — with the reason in the commit message.

## Typecheck

Whenever a change touches a typed boundary (zod validators, tRPC inputs, model/query signatures, exported types) run a full project typecheck before declaring done. **Default to `npx tsc`** — on main, tsc is the native fast compiler (~16s full runtime check), so the routine check and the CI-exact verdict are the same command:

```bash
npx tsc --project typescript/tsconfig.runtime.json --noEmit   # the default full typecheck
npx tsc --project typescript/tsconfig.test.json --noEmit      # + tests
```

(A parked branch that predates the TS7 upgrade or the config split may still carry a single `tsconfig.node.json` and pin the slow tsc 6: the global `tsgo` preview exists for those trees. Typecheck runs in the viewer push gates, not the pre-push hook, which only blocks WIP commits and TODOs.)

`tsc-turn <cmd>` is still the machine-wide compile queue, max 2 heavy checks at once — route batch or concurrent typechecks through it (2026-07-06: seven concurrent tscs flattened the machine). `oxlint --type-aware` and `oxfmt` are lints and formatting, NOT typecheckers.

**Caveat — the tRPC client type is a generated artifact.** Stale/missing generated types flood `tsc` with hundreds of `.tsx` errors tracing to one collapsed type (`TS2339` "…collides with a built-in method…" + cascading implicit-`any` params) — noise from un-built types, not your change. Filter to what you touched (`… --noEmit 2>&1 | grep <your-file>`) or build the types first (`task trpc:types`).
