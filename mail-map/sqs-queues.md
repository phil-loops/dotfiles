---
title: mailRender and mailSend
section: Stores
order: 27
ask: apps/mail-schedule/src/scheduler.ts
lede: SQS — two job queues, both carrying ids and pointers, never bodies.
---

[submitRenderBatch](src:apps/mail-schedule/src/scheduler.ts#submitRenderBatch) puts one message per batch on `mailRender`. `messageGroupId = teamId`, which keeps one team's batches in order relative to each other without ordering the whole queue.

Render and send are **separate queues** because they fail differently. Rendering is slow and CPU-bound — template, merge data, safety checks. Sending is a fast network call to SES. Splitting them means a slow render can't occupy a send slot, and each half **retries independently**: a transient SES error re-sends the artifact that was already rendered, instead of re-rendering it from scratch.

It is also where the fan-out changes shape. One `mailRender` message covers a whole batch of ids; render explodes it into per-email `mailSend` jobs, each pointing at a byte range in [[packed-artifact]].
