---
title: 3 · Claim
section: The six hops
order: 32
ask: apps/mail-schedule/src/scheduler.ts
lede: apps/mail-schedule, its own deployed service — picks up a whole team to work on.
---

This is not a job handler. It is a **while loop** in its own long-running app: [runMailScheduleLoop](src:apps/mail-schedule/src/scheduler.ts#runMailScheduleLoop) ticks continuously and only sleeps when it finds nothing to do.

Each tick, in order: sweep leases that have expired, then claim up to `teamClaimLimit` teams by moving them from active to processing, then schedule each claimed team.

The claim and lease mechanics — the atomic move, the expiry score, the crash sweep — are all properties of the sets themselves, described in [[team-lease]].

What is worth noticing here is the **unit**. The scheduler reasons about teams, not emails. That is what keeps its per-tick cost bounded no matter how much mail is queued: a five-million-email campaign is still exactly one member of one sorted set.
