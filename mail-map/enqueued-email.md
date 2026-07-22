---
title: enqueued_email
section: Stores
order: 20
ask: packages/mail-pg/migrations/20260615000000_create_mail_queue_tables.sql
lede: Postgres, mail db — a render request, not an email.
---

The row is a **render request**. It holds ids pointing at the template, contact, list and attachments, plus frozen JSONB copies of everything that could change before it sends. There is **no subject and no body** in it — [the CREATE TABLE](src:packages/mail-pg/migrations/20260615000000_create_mail_queue_tables.sql#L2-L23@6c9fb1a0) has every column, and [InsertSchema](src:packages/mail-pg/src/enqueued-email.ts#InsertSchema) is the same shape in TypeScript.

The split is: anything cheap and volatile is **copied**; anything big and shared is **referenced**. That keeps the row small enough to write millions of at campaign speed.

It also produces the one behaviour that surprises people. Merge data is frozen, so a contact who changes their name after enqueue still gets the old one. But the template is **not** frozen — render fetches the live row by id with [no version pin](src:queries/email-message.ts#findByIdsForSend), so editing a campaign after enqueue but before render **changes what actually goes out**.

Current state is stored twice, on purpose — see [[status-log]]. The rendered bytes live elsewhere — see [[packed-artifact]].
