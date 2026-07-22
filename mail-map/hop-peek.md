---
title: 4 · Peek
section: The six hops
order: 33
ask: lib/valkey-mail-queue.ts
lede: scheduler, one Lua script per team — the single atomic doorway every email passes through.
---

[The peek script](src:lib/valkey-mail-queue.ts#PEEK_SCHEDULABLE_MAIL_SCRIPT) is the choke point. Read it top to bottom; it is the most important thirty lines in the pipeline.

In **one indivisible step** it: trims the rolling window and sees what is left of the cap → takes high-priority ids until the batch is full → hands leftover capacity to low-priority mail *only if tokens allow* → records what it took.

High priority can take the **entire** batch. Low priority gets what remains, and only as much as the balance covers. That asymmetry is the answer to "can transactional mail starve workflow mail" — yes, by design, and [[throttles]] is the dial that decides how hard.

**Why it has to be Lua.** Both throttles are shared counters with concurrent deciders. In TypeScript, `GET tokens` … decide … `DECRBY` is three round trips with gaps in between: two team-workers, or two replicas, both read "1,000 left" and both spend it. A Lua script runs atomically inside Valkey, so read-decide-mutate is a single step.

The general rule, and the reason this file looks the way it does: **when a decision depends on shared state, the decision has to execute where the state lives.**
