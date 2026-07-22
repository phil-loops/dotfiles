---
title: 5 · Render
section: The six hops
order: 34
ask: jobs/mail-render.ts
lede: jobs/mail-render, a worker — the first time anyone reads actual content.
---

[scheduleTeamRenderBatch](src:apps/mail-schedule/src/scheduler.ts#scheduleTeamRenderBatch) submits the batch to SQS, and **only then** removes the ids from the team queue.

That order is the whole crash-safety design. If the process dies between the two, the ids are still in the queue and get picked up again. A duplicate render is recoverable; a lost email is not. Choosing which way to fail is the decision being made here.

The worker then loads the message, contact and list from the **main** database — live, not from the request row — builds the SES payload, writes it to [[packed-artifact]], and [fans out](src:jobs/mail-render.ts#/mailSend/) into per-email send jobs.

This is where the freshness asymmetry from [[enqueued-email]] actually bites: the template and contact are read live, while the merge data comes frozen off the request row. Same email, two different moments in time.
