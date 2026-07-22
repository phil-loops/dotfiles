---
title: 2 · Park
section: The six hops
order: 31
ask: lib/enqueue-email.ts
lede: same process, right after the commit — the id goes into the team's queue and nothing runs.
---

[enqueueEmails](src:lib/enqueue-email.ts#enqueueEmails) pushes just the **id** (with teamId, priority, createdAt) into that team's queue, then marks the team active. See [[team-queue]] and [[team-lease]] for what those two writes land in.

Nothing is executing yet. The mail is parked — and that buffer is the reason everything downstream is controllable at all.

Consider the alternative. If enqueue pushed straight to SQS, a five-million-recipient campaign would flood the job queue and transactional mail would sit behind it. SQS cannot reorder, and there would be no single place to intervene, because pushes arrive from many processes at once.

Parking in Valkey creates the one place that **can** decide order and pace. Hops 3 and 4 exist entirely because of this choice.
