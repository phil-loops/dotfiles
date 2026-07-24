---
title: 8 · The rails already there
section: Restore a deleted audience
order: 80
project: restore-mvp
ask: lib/processBulkJob.ts
lede: Every bulk audience operation already has a lifecycle. Restore built its own alongside it.
---

Two operations ride one path today — `bulkDelete` and `assignAudienceToList`. A tRPC call creates a `BulkAudienceAction` row with `status: Pending`, enqueues the job with just `{ jobId }`, and [processBulkJob](src:lib/processBulkJob.ts#processBulkJob) does the rest: it refuses a record that is not Pending or Processing, sets Processing, and switches on `data.type` to the handler. The [job wrapper](src:jobs/segment-to-mailing-list.ts#segmentToMailingList) marks Complete or Failed at the end. Progress rides the record as `data.contactsProcessed`, bumped by whichever handler is running.

So the record already answers every question a long bulk operation raises: is it running, did it finish, did it fail, how far did it get, and is this delivery a duplicate.

The restore built a parallel set of answers:

| built for restore | already expressed by |
|---|---|
| a Valkey lock | `status = Processing` |
| a `restore` blob on the delete action | `status = Complete \| Failed` |
| a lock pre-check against double-enqueue | the not-Pending-or-Processing guard |
| a cursor carried in the message | progress lives on the record |
| its own job, outside the dispatcher | one more `case` |

Five mechanisms for things the record says already. The blob is the worst of them: one overwritten field on the *delete* action, where a row per attempt would show that someone tried three times.

What this should have been instead is [[restore-reshape]].
