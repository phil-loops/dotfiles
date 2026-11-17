---
title: Conversions by recomputation (Stage A)
section: Goals
order: 20
project: goal-flip-converter
lede: A contact update only records that a goal target flipped. A batched job turns flips into conversions, and recomputing them is what keeps the answer right.
---

**Plan, 2026-11-17. Not built.** This replaces the Postgres-copy forest (`goal-active-windows`, built, not pushed) as the import fix. It also fixes imports that flip a goal target, which that forest doesn't. Background, measurements and the review are on the [checkpoint page](canopy://v2/wiki/goals-clickhouse-hot-path).

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
├─ 8. return previous values from the contact update    queries/contact: one UPDATE … FROM (SELECT … FOR UPDATE) old RETURNING old + new + test
│     └─ 9. record goal flips with the contact update  contact update + flip append in one transaction, only when the team has targets;
│           │                                           inline path kept behind goalInlineConversionEnabled   (requires 1, 2; ⇢ after 7)
│           └─ 10. remove the inline conversion path   drops findActiveByContact, hasActiveForTeam, findWithGoalByIds and the inline insert   (⇢ after the cutover)
├─ 11. check every conversion reader tolerates duplicates   fixture with duplicated rows; every reader's answer unchanged
└─ 12. derive enrollment ids from the delivery       job payload carries emailId + deliveredAt; impressionId = hash(emailId, attachmentId); enrolledAt = deliveredAt
```

Carried over from `goal-active-windows`: the targets query (branch 1 here) and the lookup removal (branch 10). Retired from it: `GoalActiveWindow`, its backfill, its prune, and the window-recording at enrollment.

## Hardening: closing the soft spots

**1. A flip that's never recorded.** Two problems with appending the flip after the contact save:
- **It isn't atomic.** A crash between the save and the append loses the only evidence of the flip.
- **It compares against stale values.** `handleUpdatingContact` compares the update against a **preloaded** contact (`preloadedContact`), read before the `UPDATE`. Two concurrent updates to one contact can both see the same "old" value, which means a missed flip-back or a duplicate flip. That's true in prod today too.

**Fix (branches 8 and 9):** one transaction per changed contact, **only on teams that have goal targets** (the cached targets say so; no-goal teams keep today's plain update):
1. `UPDATE "Contact" … FROM (SELECT … FROM "Contact" WHERE id = $1 FOR UPDATE) old … RETURNING old.*, contact.*`. The row lock serialises concurrent updates, and the old values are exactly the ones this update replaced.
2. Evaluate the targets on old versus new, in memory, inside the transaction. It's microseconds of work: no reads and nothing external.
3. Insert the flips into `GoalFlip`.
4. Commit. The contact change and its flips persist together or not at all.

That makes "correct regardless of timing" true end to end. A flip exists if and only if the contact really changed across a target.

**2. Windows, the other input.** For conversions specifically, duplicate windows are already harmless: they produce the same conversion id, or readers deduplicate by contact. The real risk is a **missing** window.
- **Branch 12 makes enrollment deterministic.** The SES delivery handler already has the `Email` record and the delivery time when it enqueues the job (`processNotificationWebhook.ts`, `evaluateGoalEnrollment`). Pass both through:
  - `impressionId = hash(emailId, attachmentId)`;
  - `enrolledAt = deliveredAt`.

  A retried or duplicate SNS notification then rewrites identical rows instead of minting new ones. **Decided 2026-11-17 (Phil): `enrolledAt` means delivery time.** It used to mean "when the job ran", which is minutes after delivery under load. Days-to-convert shifts slightly for new enrollments.
- **A lost enrollment is already visible.** No branch is needed. The `background-jobs` SQS queue (monotoad `production/loops/main.tf`, module `shared/sqs`) has a dead-letter queue after 3 receives, a Slack alert on it (`@slack-monitoring-production-dlq`), and an alert on the oldest message's age at 900s. Once branch 12 ships, **redriving** dead-lettered enrollment jobs is safe: they rewrite identical rows. After a redrive, run the catch-up over a range that reaches back to the redriven deliveries.
- **Stage B** later makes impression and window *storage* deduplicate (`ReplacingMergeTree`) and moves the writes into the buffer.

**3. Tolerating duplicates was a convention.** **Branch 11** turns it into a test. Load a fixture where every conversion row appears twice, run all six readers, and assert their answers equal the deduplicated fixture's. A future reader using a bare `count()` then fails CI instead of silently overcounting.

**Still assumed, with an alarm on each:**
- **The 2-day catch-up range.** A flip only matches windows enrolled before it, so a window can only arrive late if enrollment itself is that far behind. Alert on enrollment-job lag and on flip-queue age.
- **Clock skew between app servers** at a window's edges: milliseconds. With branch 12, `enrolledAt` comes from SES, so the remaining skew is SES's clock against ours.

## Cutover: overlap, then switch

1. Ship 1–8, 11 and 12. The converter runs, the queue is empty.
2. Ship 9 with both settings on. Contact updates append flips **and** the inline path still writes conversions. Both compute the same derived ids, so nothing double-counts.
3. Watch for a few days. The catch-up's repaired count should read 0 for flips the 30s pass already handled. Compare per-day conversion counts against before the change.
4. Turn `goalInlineConversionEnabled` off. Imports lose the ClickHouse lookup and the ~75–100ms insert. Turning it back on is instant.
5. Ship 10.

During the overlap, imports stay as slow as today, because the inline path is still on. Keep the overlap short.

## Later stages

- **Stage B, enrollment writes:**
  - impressions and windows go through a Postgres buffer;
  - ids are derived from the send (the enrollment job carries the SES message id);
  - `ReplacingMergeTree` rebuilds for impressions and windows, with no `FINAL`;
  - a duplicate-count metric.

  This removes the ~2.6M single-row inserts per big send.
- **Stage C, batched enrollment:** the one-SQS-job-per-contact model is the 100M ceiling. It needs a product call on when a contact counts as enrolled.
