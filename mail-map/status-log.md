---
title: enqueued_email_status
section: Stores
order: 21
ask: packages/mail-pg/migrations/20260615000000_create_mail_queue_tables.sql
lede: Postgres, mail db — the append-only state trail, plus its denormalized twin.
---

Six states, not three: `pending → rendering → rendered → sending → sent`, or `error`. [The log table](src:packages/mail-pg/migrations/20260615000000_create_mail_queue_tables.sql#L37-L46@d32f983a) is append-only — one row per transition, with its timestamp and message.

The current state also lives on the [[enqueued-email]] row itself, as `current_status`, `current_status_at` and `current_status_message`. That duplication is deliberate: it is what makes the operational questions cheap. "Which emails are stuck in `rendering`" becomes an index scan on the row rather than an aggregate over the log.

The [partial indexes](src:packages/mail-pg/migrations/20260615000000_create_mail_queue_tables.sql#L30-L35@487afb66) go further and exclude finished mail entirely (`WHERE current_status NOT IN ('sent','error')`), so the hot index only ever covers in-flight work — which is a tiny fraction of the table.
