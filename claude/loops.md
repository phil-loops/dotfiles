# Loops Repo

## Remotes

- `origin` (`Loops-so/loops`) — the shared team repo; branches and PRs live here, origin-internal (head branch → `main`, same repo — never fork PRs). Phil pushes via GH Desktop / the viewer and opens every PR manually (spine hard rule).
- `phil-loops` (`phil-loops/loops`) — Phil's fork: bench/experimental branches only (e.g. `bench/goal-metrics`). A PR branch never goes here — it'd be orphaned. When in doubt, it's Phil's push either way.

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
task lint                # typecheck + oxlint + oxfmt + prisma format + package/openapi/knip checks
task clickhouse:migrate  # run ClickHouse migrations (uses correct URL)
task ci:run              # full CI pipeline locally
```

Run `task --list` for the full set.

**Exception — in a worktree whose `node_modules` is a symlink to the main checkout's** (the `cw` default): `@loops/*` resolve to the main checkout's `packages/` and its `.gen`, built for whatever commit that checkout is parked on, so a test or typecheck there can red (or green) on another commit's code. Run `seed-gen --sync .` first (~10s; the gates run it too) — it gives the tree its own packages dist and `.gen` when they differ. Then run the command under the task, not the task: `task test`, `task lint*` and `task build:packages` run `npm install`, which replaces the symlink with a private 1.5GB install. A focused test is `npx tsx --tsconfig typescript/tsconfig.test-runtime.json --test-reporter=dot --test <file>` (query tests need `.env` linked too).

## Migrations

**A new migration must pass squawk before it ships**, absent a stated reason. Run it the moment the file exists — CI (`lint-migrations`) runs the same check:

```bash
npx -y squawk-cli packages/prisma/migrations/<dir>/migration.sql
```

`.squawk.toml` applies automatically (already excludes `require-timeout-settings`, `prefer-timestamp-tz`); repo convention: `CREATE TABLE IF NOT EXISTS`. A wrong-for-the-case warning (e.g. `prefer-bigint-over-int` on a small bounded counter) gets an inline `-- squawk-ignore <rule>` directly above the statement — bare rule name, no trailing text — with the reason in the commit message.

## Typecheck

Whenever a change touches a typed boundary (zod validators, tRPC inputs, model/query signatures, exported types) run a full project typecheck before declaring done. **Default to `npx tsc` on CI's three configs** — tsc is the native fast compiler (seconds each), and these are what CI and the push gates check:

```bash
npx tsc --project typescript/tsconfig.next.json --noEmit
npx tsc --project typescript/tsconfig.test.json --noEmit
npx tsc --project typescript/tsconfig.runtime-build.json --noEmit
```

Never `tsconfig.runtime.json`: it checks every file under nodenext resolution, which no CI job does, and reds on main itself (stripe's cjs typings lack `CustomerSubscriptionUpdatedEvent`; 2026-11-05 a session chased that "error" across three branches). `task lint:typecheck` is the same surface but runs `npm install` first (below).

(A parked branch that predates the TS7 upgrade or the config split may still carry a single `tsconfig.node.json` and pin the slow tsc 6: the global `tsgo` preview exists for those trees. Typecheck runs in the viewer push gates, not the pre-push hook, which only blocks WIP commits and TODOs.)

Every typecheck goes through the machine-wide queue (`heavy-turn`: 2 slots, 1 while the box is under memory pressure). An interactive zsh routes `tsc`, `npx tsc` and the `task lint*`/`*:types` tasks there by itself; from a script or `bash -lc`, prefix `tsc-turn <cmd>` (2026-07-06: seven concurrent tscs flattened the machine; 2026-10-19: two *queued* 5GB tscs beside an unqueued 4.6GB job did too — hence the memory floor). `heavy-turn --status` names who holds a slot and why you wait; `~/.cache/heavy-turn/journal.tsv` says who ran what, how long it waited and ran. `oxlint --type-aware` and `oxfmt` are lints and formatting, NOT typecheckers.

**Caveat — the tRPC client type is a generated artifact.** Stale/missing generated types flood `tsc` with hundreds of `.tsx` errors tracing to one collapsed type (`TS2339` "…collides with a built-in method…" + cascading implicit-`any` params) — noise from un-built types, not your change. Filter to what you touched (`… --noEmit 2>&1 | grep <your-file>`) or build the types first (`task trpc:types`).
