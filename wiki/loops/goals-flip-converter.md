---
title: Conversions by recomputation (Stage A)
section: Goals
order: 20
project: goal-flip-converter
lede: A contact update only records that a goal target flipped. A batched job turns flips into conversions, and recomputing them is what keeps the answer right.
---

**Plan, 2026-11-17. Not built.** This replaces the Postgres-copy forest (`goal-active-windows`, built, not pushed) as the import fix. It also fixes imports that flip a goal target, which that forest doesn't. Background, measurements and the review are on the [checkpoint page](wiki:goals-clickhouse-hot-path).

## The idea

A conversion is a **join of two high-volume streams on (contact, time)**: enrollment windows (written at send) and contact changes (written in the app). Three moves make it cheap and correct:

1. **Filter first, in memory.** A contact update matters only if it flips a goal's target, false → true or true → false. Checking that needs just the team's target filters, cached. Almost every update stops there.
2. **Join in batches, shortly after.** Flips go into a small Postgres queue. A converter joins them against ClickHouse windows with one batched read, and writes conversions with one batched insert.
3. **Recompute until it converges.** Conversions are a pure function of flips and windows. An hourly pass recomputes the last ~2 days of flips and inserts any conversion that's missing. Ids are derived from the cause, so recomputing is harmless. Late windows, retries and crashes become "a later pass gets it right": no horizon, no watermark, no discard step.

Result: **correct regardless of timing; wrong only if an input was never recorded, and that's visible.**

## Principles

1. Postgres holds small things: config, the flip queue. Nothing per enrollment.
2. ClickHouse holds high-volume history, written in large batches and read in large batches.
3. Every row's id comes from its cause.
4. Delivery is at-least-once, and storage tolerates duplicates.
5. Derived data is recomputed, not decided once.
6. Every guarantee is measured.

## Data

**`GoalFlip` (Postgres, new):** `id` (cuid), `teamId`, `goalId`, `contactId`, `converted` (bool), `at` (captured once, at the contact update), `createdAt`, `processedAt` (null until the 30s pass handles it).
- Indexes: `(processedAt) WHERE processedAt IS NULL` for the claim, `(at)` for the catch-up range and retention.
- Rows are kept ~3 days, then deleted by a daily sweep.
- Volume is one row per flip, not per enrollment. On prod's biggest attachment that's thousands, not millions.

**`GoalConversionEvent` (ClickHouse):** add `id String DEFAULT ''`, a metadata-only `ADD COLUMN`.
- `id = hash(attachmentId, contactId, enrolledAt as ClickHouse prints it, converted, at)`. Every writer computes it through one shared function.
- **No table rebuild.** All six readers already deduplicate (`uniqExact(contactId)`, `uniq(goalId, attachmentId, contactId)`, `min(at)`, `LIMIT 1 BY contactId`, `argMax`), so a rare duplicate row costs storage, not correctness.

## Flow

```
contact update ─► targets(team), cached 60s ─► target flipped? ─► GoalFlip append
                   (no ClickHouse on this path)

converter, every 30s (croon → job, one run at a time)
  claim unprocessed flips (SKIP LOCKED, ≤ N)
  → one window lookup: (teamId, contactId) IN (…), chunks of ≤ 1000      [contact_lookup projection]
  → match: window.goalId = flip.goalId, attachment still live, enrolledAt ≤ at < windowEnd
  → one GoalConversionEvent insert (derived ids) → set processedAt

catch-up, hourly
  flips with at in the last 2 days → same lookup + match
  → read which derived ids already exist: (teamId, goalId, contactId) IN (…) AND id IN (…)
  → insert only the missing ones
  → metric: repaired count. Steady nonzero means the 30s pass misses things (late windows); alert on it
```

**Why the targets cache is 60s, not a day** like `goalAttachmentCache`: a new goal or attachment starts counting within a minute. Goal filters lock once a goal has exposure, so a stale filter can't miscount past that. An import then pays one Postgres query a minute instead of one per changed row (the ~0.4ms per row measured locally).

## The pure function

`matchFlips({ flips, windows, liveAttachmentIds }) → conversion rows`, tested as plain tables:

| case | expect |
|---|---|
| flip inside a window | one conversion, `converted` copied over, id derived |
| flip before `enrolledAt` / at or after `windowEnd` | none |
| flip on another goal | none |
| two attachments of the same goal, both open | two conversions |
| window whose attachment was deleted | none |
| flip back (`converted = false`) | one row with `converted = 0` |
| the same inputs twice | identical ids |

## Forest

```
main
├─ 1. cache team goal targets                 queries/goal-attachment findActiveWithTargetForTeam + 60s cache
├─ 2. add goal flip queue                     Prisma GoalFlip + migration + queries (append, claimUnprocessed, findSince, markProcessed, deleteBefore) + tests
├─ 3. add goal conversion id                  ClickHouse ADD COLUMN + shared conversionId() + recordConversion writes it
├─ 4. add batched goal window lookup          clickhouse query by (teamId, contactId) tuples, chunked + test
│
├─ 5. add goal flip matching                  the pure function + its case table          (requires 3)
│     └─ 6. add goal flip converter          30s pass + hourly catch-up models, fake-deps tests   (requires 2, 4)
│           └─ 7. run the goal flip converter      croon entries + jobs + retention sweep + metrics (queue depth, oldest unprocessed, repaired)
│
├─ 8. queue goal flips in handleConversion    append a flip when goalFlipQueueEnabled; inline path kept behind goalInlineConversionEnabled   (requires 1, 2; ⇢ after 7)
│     └─ 9. remove the inline conversion path     drops findActiveByContact, hasActiveForTeam, findWithGoalByIds and the inline insert   (⇢ after the cutover)
```

Carried over from `goal-active-windows`: the targets query (branch 1 here) and the lookup removal (branch 9). Retired from it: `GoalActiveWindow`, its backfill, its prune, and the window-recording at enrollment.

## Cutover: overlap, then switch

1. Ship 1–7. The converter runs, the queue is empty.
2. Ship 8 with both settings on. Contact updates append flips **and** the inline path still writes conversions. Both compute the same derived ids, so nothing double-counts.
3. Watch for a few days. The catch-up's repaired count should read 0 for flips the 30s pass already handled. Compare per-day conversion counts against before the change.
4. Turn `goalInlineConversionEnabled` off. Imports lose the ClickHouse lookup and the ~75–100ms insert. Turning it back on is instant.
5. Ship 9.

During the overlap, imports stay as slow as today, because the inline path is still on. Keep the overlap short.

## What it still can't catch

- **A flip that's never queued:** the contact update fails between saving and appending. Same exposure as today. Closing it means appending inside the contact update's transaction, a deeper change to `ContactModel.save`.
- **A window that's never written:** enrollment fails after the email went out. Today's behavior; Stage B makes enrollment writes durable.
- **A window that lands more than 2 days after its flip:** an alert on queue age fires well before then, and the catch-up range is a constant.

## Later stages

- **Stage B, enrollment writes:**
  - impressions and windows go through a Postgres buffer;
  - ids are derived from the send (the enrollment job carries the SES message id);
  - `ReplacingMergeTree` rebuilds for impressions and windows, with no `FINAL`;
  - a duplicate-count metric.

  This removes the ~2.6M single-row inserts per big send.
- **Stage C, batched enrollment:** the one-SQS-job-per-contact model is the 100M ceiling. It needs a product call on when a contact counts as enrolled.
