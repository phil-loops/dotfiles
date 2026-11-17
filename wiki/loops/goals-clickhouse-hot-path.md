---
title: Goals off the ClickHouse hot path
section: Goals
order: 10
project: goal-active-windows
lede: Imports spent ~40–60% of their time asking ClickHouse one row at a time. Hot-path state moves to Postgres; ClickHouse gets buffered history only.
---

**Checkpoint 2026-11-17.** Phase 1 is built as the `goal-active-windows` forest (not pushed, gates not run). The ClickHouse write buffer (phase 2) is designed and under review by Fable 5.2. Nothing is decided past that.

## The problem

Every contact update on a team with a goal ran [`findActiveByContact`](src:clickhouse/queries/goal-contact-window.ts#findActiveByContact), one ClickHouse query per changed row, from [`handleConversion`](src:models/goals/goal-conversion.ts#handleConversion). On prod, a 100k CSV import spent 294.6s on it, 37.8% of the import (Alan's measurement). The figure works out to about 2.9 ms per row, which implies only about 42k rows actually changed; that count is unverified.

The ClickHouse owner gave two rules:
- **Buffer writes:** at most about one insert per table per 30s, unless a batch is 10k+ rows.
- **Read lots of rows per query:** no point lookups.

## What we measured

**Prod:**
- The lookup is cheap per call: it uses the `contact_lookup` projection, takes 7 ms and reads 24k rows. The cost is the number of calls.
- `GoalContactWindow` is about 16M rows. About 1.26M windows are open (the biggest team has about 398k); open windows per contact per attachment are about 1.
- Batched lookups:
  - a tuple `(teamId, contactId) IN (…)` uses the projection: 9 ms;
  - 500 literal ids read 2M rows in 56 ms;
  - `IN (subquery)` does **not** use the projection.
- A read-time join of flips × windows was exact (1737 = 1737), but cost about 200 ms per attachment and about 700 ms goal-wide. Rejected as "spooky" for metric reads.

**Local, 10k rows, main versus the forest, on the same data:**

| scenario | main | forest |
|---|---|---|
| goal, rows don't flip the target | 205–274 rows/s; goal check 60–65% of row time | **835–958 rows/s; 22–25%** |
| team with no goal | ~940 rows/s | about the same (one Postgres query per row either way) |
| rows flip the target | 24 rows/s | not fixed: each conversion insert waits ~75–100 ms on the async-insert flush |

## Designs considered

| design | verdict |
|---|---|
| Reorder (look up only on a flip), keep ClickHouse | Helps, but keeps a ClickHouse point read on every flip |
| Flip log in ClickHouse, matched with a read-time join | Exact, but slow and spooky reads, and every reader rewritten |
| Flip queue plus a converter (match when draining) | A drain-time "no window, discard" decision. That's the SES-projection failure mode (stabilisation windows, repair scripts) |
| **Open windows in Postgres, inline lookup** | **Chosen.** A Postgres row is visible on commit, so there's no timing machinery |
| Async insert without waiting for the flush | Rejected: silent loss on a failed flush |

## Principles

1. Hot-path questions are answered by Postgres.
2. ClickHouse only receives history, buffered and delivered exactly once.
3. Metrics read ClickHouse in large queries; readers don't change.

## Phase 1, built: `goal-active-windows`

- **The `GoalActiveWindow` table:** unique on `(attachmentId, contactId, enrolledAt)`, indexed on `(teamId, contactId)` and `windowEnd`.
- **Enrollment** writes ClickHouse first, then Postgres, so Postgres never holds a window ClickHouse lacks.
- **The backfill script** copies open windows from ClickHouse, paged per team with a cursor that keeps full timestamp precision.
- **A daily prune** deletes expired windows.
- **The switch:** `handleConversion` evaluates the team's targets first, then looks up Postgres windows only for goals that flipped.
- **Cleanup:** removes `findActiveByContact`, `hasActiveForTeam` and `findWithGoalByIds`.

Deploy order: enrollment records first, then run the backfill, then the switch.

**Known gaps:**
- **Team purge** doesn't yet delete `GoalActiveWindow` rows.
- **The dual write in `enroll`:** if the process dies between the two writes, Postgres misses a window.
- **The targets query** costs about 0.4 ms per changed row. Cache it for the length of an import.

## Phase 2, designed: ClickHouse write buffer

The remaining single-row ClickHouse writes are all in goals: impression and window inserts at enrollment, and conversion inserts on a flip. The fix is a Postgres write buffer:
- **Callers** call `append(table, rows)`, joining their own transaction where one exists.
- **A drainer** runs every 30s under an advisory lock. It claims rows with `SKIP LOCKED`, makes one insert per table with `async_insert=0`, then deletes.
- **Crash recovery doesn't rely on ClickHouse dedup.** For a batch claimed earlier but never deleted, wait until `claimedAt + 5 min`, check which row ids already exist (impression `id`, window `impressionId`, and a **new `id` column on `GoalConversionEvent`**), and insert only the missing ones.
- **Follow-ons:**
  - enrollment in one transaction (Postgres window plus buffer row), which removes the dual write;
  - idempotent enrollment keyed by the send, a pre-existing bug where a retry creates a second window.

Open questions are in the design doc: Postgres churn (~2.6M rows per big send), purge racing the drainer, the recovery wait versus the client timeout, batch size, and how Dates serialize through jsonb.

## Not yet done

- The Fable review of the buffer design.
- The push gates on phase 1.
- Confirming with Alan that "open windows in Postgres" is the shape he wants.
