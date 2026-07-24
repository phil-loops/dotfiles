---
title: 9 · Restore as a third action
section: Restore a deleted audience
order: 90
project: restore-mvp
ask: lib/types/bulkAudienceAction.ts
lede: Make restore an action type and the bespoke machinery deletes itself.
---

Restore stops being an annotation on the delete and becomes its own kind of bulk action:

```
data.type = "bulkRestore"
  { teamId, archiveKey, pageCount, contactsProcessed, nextPage?, sourceActionId }
```

Everything in the table on [[restore-rails]] then comes from the record. `restore-lock.ts` is deleted outright — "is a restore running" is a bulkRestore row at Processing, read like any other action. The stamp goes too. The cursor moves onto the record beside `contactsProcessed`, so the message stays `{ jobId }` and the queue stops carrying resume state. The job shrinks to a wrapper mirroring the existing one. And an attempt becomes a row rather than an overwrite, so the history survives.

**What survives untouched:** the engine and the archive-key stamp. The engine is a pure function over `(teamId, archiveKey, pageCount, deletedAt, fromPage)` — the paged read, the both-slot probe and the staleness guard care nothing about how it is scheduled. Those two branches stand as they are.

**What changes:** the job becomes a wrapper plus a dispatcher case; the list model becomes a plain query over actions instead of a fan-out to Valkey; the admin page reads a status instead of reconciling a lock against a stamp. It removes more than it adds.

**The one genuinely new thing** is the budget, which has no precedent among these two handlers — `jobs/delete-team.ts` is the model for it.

Known wart: the dispatcher loads `team.loops` for every type, which restore does not need. Accept it rather than refactor a shared path for one caller.
