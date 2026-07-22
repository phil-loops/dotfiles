---
title: active and processing teams
section: Stores
order: 25
ask: lib/valkey-mail-queue.ts
lede: Valkey sorted sets — the scheduler's own work queue, where the unit of work is a team.
---

Two more sorted sets, but here the members are **teams**, not emails.

`active-mail-teams` holds teams with mail waiting, scored by when they started waiting. [markTeamActive](src:lib/valkey-mail-queue.ts#markTeamActive) puts them there — and skips a team already being processed. `processing-mail-teams` holds claimed teams, scored by **lease expiry**.

[claimActiveTeams](src:lib/valkey-mail-queue.ts#claimActiveTeams) atomically **moves** a team from one to the other, writing `now + teamLeaseMs` as the new score. A move can only succeed once, so two replicas can never work the same team — that is the double-send defense, at team granularity. [The move script](src:packages/valkey/src/index.ts#MOVE_MIN_SORTED_SET_MEMBERS_SCRIPT) takes lowest scores first, which is what makes it fair: the longest-waiting team goes first.

If the instance holding a claim dies, its team would be stranded in `processing` forever. So [the sweep](src:lib/valkey-mail-queue.ts#REQUEUE_EXPIRED_PROCESSING_TEAMS_SCRIPT) runs first thing each tick, returning teams whose lease is in the past — but only if their queue is still non-empty. Worst case after a crash is one team pausing for one lease period.

If the shape feels familiar: it is SQS's receive-plus-visibility-timeout, hand-rolled, with "a team with pending mail" as the message.
