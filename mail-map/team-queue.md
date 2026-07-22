---
title: The team queue
section: Stores
order: 24
ask: lib/valkey-mail-queue.ts
lede: Valkey sorted set — one queue per team, holding ids, sorted by priority then age.
---

One sorted set **per team**, at `{mail-schedule}:mail-queue:<teamId>`, holding email **ids only**.

A sorted set is just `(member, score)` pairs kept in score order — two columns with an index on the number. The trick is what goes in the score. [getQueueScore](src:lib/valkey-mail-queue.ts#getQueueScore) packs both dimensions into one float:

    score = priority × 10¹³ + createdAtMs

Because [the bucket size](src:lib/valkey-mail-queue.ts#PRIORITY_BUCKET_SIZE) is larger than any plausible millisecond timestamp, priority occupies the high digits and arrival time the low ones. One sort therefore yields "all priority-32, oldest first, then all priority-64, oldest first" — with no secondary sort and no separate queue per class.

That is what lets [[hop-peek]] select an entire priority class with a plain range read: everything scoring below `64 × 10¹³` **is** the high-priority set.

Priority is capped at 255 so the packed number stays inside the range where a float64 represents integers exactly. Past that, scores would start rounding and the ordering would quietly break.
