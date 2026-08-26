---
title: 2 · Park
section: The six hops
order: 31
ask: lib/enqueue-email.ts
lede: same process, right after the commit — the id goes into the team's queue and nothing runs.
---

[enqueueEmails](src:lib/enqueue-email.ts#enqueueEmails) pushes just the **id** (with teamId, priority, createdAt) into that team's queue, then marks the team active. See [[team-queue]] and [[team-lease]] for what those two writes land in.

Nothing is executing yet. The mail is parked — and that pause is the point.

An id sitting in a sorted set can still be **reordered** and **metered**. A job already handed to SQS can be neither: it delivers in roughly arrival order, with no place to say "these five million wait, that one transactional email goes now." So the two levers this whole pipeline turns on only exist while the mail is a parked id — [[hop-peek]] pulls the highest-priority class first because [[team-queue]] holds the ids sorted by priority, and the [[throttles]] decide how fast they leave.

Push straight to SQS and both levers vanish: a five-million-recipient campaign floods the queue, transactional mail waits behind it, and there is no single place to intervene. That is exactly what Hops 3 and 4 are — the ordering and pacing this buffer makes possible.
