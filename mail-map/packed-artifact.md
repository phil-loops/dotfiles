---
title: email_send and the packed artifact
section: Stores
order: 22
ask: jobs/mail-render.ts
lede: Postgres + S3 — the pointer to the rendered bytes, and why it carries a byte range.
---

[The table](src:packages/mail-pg/migrations/20260615000000_create_mail_queue_tables.sql#L53-L63@8e5c7e30) records `bucket`, `key`, `byte_offset`, `byte_length` and `schema_version`.

An offset *and* a length means one S3 object holds **many rendered emails packed end to end**, each addressed as a slice. [The write](src:jobs/mail-render.ts#/writeToStorage\(/) happens once per render batch.

Why: a batch is up to 500 emails. 500 separate PUTs is 500 round trips and 500 objects to lifecycle. One packed object is a single PUT, and the send worker does a **ranged GET** for just its own slice. `schema_version` is what allows the packing format to change without stranding artifacts already written.

So S3 itself is unremarkable here — the idea is that the queue message stays tiny (a pointer) while the payload, which is far too big to put in a queue, sits in object storage addressed by arithmetic.
