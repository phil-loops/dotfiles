---
name: bench-shas
description: A/B benchmark the SAME function across two git refs against the same pre-seeded data, to measure a perf change (e.g. a ClickHouse query rewrite). Use when the user wants to compare how a query/function performs between two commits/branches/SHAs ("is the new version faster?", "bench old vs new", "did this rewrite help / regress?", "compare main vs my branch on X").
---

# Bench across SHAs

Compare one function's performance between two git refs by running each ref's
version of the code against the *same* externally-seeded data (ClickHouse,
Postgres, etc.) and diffing wall time + memory. The data is the constant; only
the code varies per ref.

## When to use

- "Is my rewrite of `<query>` actually faster than main?"
- "Bench `<branch>` vs `origin/main` on `<function>`"
- "Did this change regress / improve perf?"
- Any "old version vs new version, same data, who's faster" question.

NOT for: profiling a single version (just run it), or micro-benchmarks of pure
functions (no external data to hold constant).

## The model (why it works)

The seeded data lives **outside git** — it doesn't change when you check out a
different ref. So seed once, then run each ref's *code* against it. A
**scenario** names the call to make and the dataset to hit; the harness runs
that scenario inside a worktree per ref.

In the loops repo the harness exists: `scripts/bench-shas/` (run
`~/.volta/bin/node --import tsx scripts/bench-shas/index.ts <refA> <refB>
--scenario <name>`). Elsewhere, build the same shape from the steps below.

## Procedure

1. **Worktree per ref** — `git worktree add <path> <sha>` (detached). Symlink
   the main checkout's `node_modules` in (worktrees have none):
   `ln -s <main>/node_modules <worktree>/node_modules`. Leave the user's main
   checkout alone — they may be driving it via GitHub Desktop.
2. **Generate the driver into each worktree at runtime.** Old refs won't
   contain a newly-written scenario file, so the harness writes a small driver
   (`.bench-driver.mjs`) into each worktree, which imports THAT ref's query
   module by relative path and runs the call.
3. **Run + measure** — 1+ warmup, then ≥3 measured iterations; report best and
   median wall time, plus peak memory.
4. **Clean up** worktrees (`git worktree remove --force` + `prune`) unless
   `--keep`.

## Gotchas (each of these cost real debugging — honor them)

- **Return shapes differ across refs** (that's the point — `{conversions}` vs
  `{net}` vs `{cumulativeConverted}`). The scenario must return only a scalar
  (`rowCount`) and never assume a shared TS type. Serialize the call as source,
  eval it in the worktree; don't import a shared type.
- **Cap query memory** (e.g. ClickHouse `max_memory_usage`). A heavy version
  (`uniqExact`, `argMax` at scale) can OOM-kill a *shared* DB node — on CH that
  means exit 137 → restart → every tenant's in-flight queries die. The cap makes
  an over-budget query fail *alone* (captured as an ERROR row), not crash the
  node. Also disable query cache for honest timing (`use_query_cache=0`).
- **Reuse seeded data; never re-seed millions of rows.** Re-seeding at scale
  OOMs the DB. Confirm the dataset exists (`count()`) before benchmarking; if
  it's missing, say so — don't seed 100M rows.
- **Settle background work before timing.** On CH, poll `system.merges` until it
  drains; active merges can 5× query times and skew the comparison.
- **Pull peak memory from the engine, not the client.** On CH: tag each query
  with a unique `log_comment` and read `max(memory_usage)` from
  `system.query_log` (`type='QueryFinish'`). It's async/best-effort; wall time
  is the primary metric.
- **`WORKTREE` pseudo-ref** — support benchmarking the current checkout's
  *uncommitted* changes, since the version under test often isn't committed yet.
- **A ref may lack the function entirely** (it was added on one branch). Capture
  that as an ERROR row, don't crash the harness.

## Adding a scenario

A scenario = dataset (team/goal or table filter) + the call expression +
iteration counts. Keep them in the harness's scenarios file so new comparisons
are one small entry, not a new script.
