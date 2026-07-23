---
title: 2 · The two guards
section: Restore a deleted audience
order: 20
project: restore-mvp
lede: Two conditions in one WHERE clause carry the entire safety argument.
---

The revive is a single `UPDATE … FROM (VALUES …)` per page. Two conditions decide which rows it touches, and between them they replace a whole category of machinery.

```
AND c."softDeleteAt" IS NOT NULL      -- (a)
AND c."softDeleteAt" <= :deletedAt    -- (b)
```

**(a) still soft-deleted — makes a re-run free.** A redelivered SQS message, or a pod killed halfway through, re-reads every page and no-ops every row already back. This is what buys a *stateless* job: no progress cursor, no resume record, no partial-state table. Restart from page zero and the result is identical.

**(b) not deleted again since — stops an old dump stomping a newer one.** If a contact was deleted, restored, edited, then deleted again, restoring the older dump would otherwise write stale values over the newer state. `deletedAt` is the delete action's own `createdAt`, threaded down from the job.

Worth being explicit about what is *not* doing this work: the Valkey lock. Two concurrent restores of the same dump would still land a correct result, because of (a). The lock exists to drive the spinner in the admin UI and to stop two admins double-enqueueing — it is a light, not a latch. Nothing depends on it for correctness.

The collision probe that runs before this UPDATE is [[restore-slots]], and it is the one place the June engine is outright wrong.
