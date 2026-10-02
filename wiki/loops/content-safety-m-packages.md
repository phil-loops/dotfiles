---
title: M0.5, the packages and their database
section: Content safety
order: 25
project: safety-packages
lede: Three workspace packages and a Postgres cluster of their own, mirroring mail-pg. Everything after depends on this spine.
---

Part of [[content-safety-epic]]. Sits between the fixes and the overrides; M1, M2 and M3 chain on its tip.

**Why its own cluster.** Evidence and decisions are high-volume, time-partitioned, PII-bearing, and dropped on a retention schedule. None of that belongs in the application schema. `mail-pg` already proved the shape: a workspace package wrapping `pg`, its own dbmate migrations, a Taskfile include, a local database on the compose Postgres, one connection-string env var.

**`@loops/safety-pg`.** The pool, `SAFETY_PG_DATABASE_URL`, migrations, partition maintenance, typed queries per table: evidence, signal, decision, label, override, config, family, blocklist, representation. Columns for anything queried; JSONB only for segments, raw detector output, resolved spans; HTML in the object-storage bucket by hash. No business logic.

**`@loops/safety-core`.** Pure, no I/O: the fact vocabulary, evidence builder, deterministic detectors and catalogues, policy rules and version, fingerprints, the model's output contract. The semantic detector too, taking the model call as an injected function, so the package never imports a provider SDK.

**`@loops/safety-replay`.** Replay, holdout split, agreement and interval math. Run from script-runner.

**The app keeps** the orchestrating models, the jobs, the admin router and UI, and the provider client it hands to core.

1. **add-the-safety-pg-package** — skeleton, pool, migrations runner, test utils, Taskfile, local db.
2. **add-the-safety-core-package** — facts, evidence builder, output contract.
3. **provision-the-safety-database** — env var in app-env, charts, compose. The cluster itself is infrastructure, provisioned where the mail cluster was.

Done when a worker can open a pool to the safety database in every environment and a test can build an evidence bundle without touching a database.
