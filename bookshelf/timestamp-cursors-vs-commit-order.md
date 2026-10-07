# Timestamp cursors vs commit order

**The idea.** A row is stamped (timestamp, sequence id) when its writer builds it, but other sessions only see it when the writer commits. A reader that pages by that stamp and moves its cursor forward can pass a row that commits late. The row then sits behind the cursor forever.

**Where it bit.** [loops#10905 review comment](https://github.com/loops-so/loops/pull/10905/changes#r4211505158), 2026-10-07: `listSendEventsForReconciliation` in `packages/mail-pg/src/ses-event.ts` takes a caller-supplied `until`, while its sibling `listForProjection` bounds on `TRANSACTION_TIMESTAMP() - safetyLag`.

**Three questions to ask of any cursor reader.**

1. Who assigns the ordering column, and when?
2. When does the row become visible to the reader?
3. What happens to a row that becomes visible behind the cursor?

## Read

Roughly in order. Each has one question to answer before moving on.

- [ ] **[PostgreSQL docs: Transaction Isolation](https://www.postgresql.org/docs/current/transaction-iso.html)** — section 13.2.1, Read Committed, is the part that matters.
  *Question:* what exactly does a `SELECT` see of a transaction that started earlier and has not committed yet?
- [ ] **[PostgreSQL docs: Introduction to MVCC](https://www.postgresql.org/docs/current/mvcc-intro.html)** — one page of background for the chapter above.
  *Question:* why do readers never block writers, and what does that cost a cursor reader?
- [ ] **[PostgreSQL docs: Date/Time Functions, "Current Date/Time"](https://www.postgresql.org/docs/current/functions-datetime.html#FUNCTIONS-DATETIME-CURRENT)** — `transaction_timestamp()` vs `statement_timestamp()` vs `clock_timestamp()`.
  *Question:* why does `listForProjection` use the transaction clock and require a transaction client?
- [ ] **[microservices.io: Transactional outbox](https://microservices.io/patterns/data/transactional-outbox.html)** and **[Polling publisher](https://microservices.io/patterns/data/polling-publisher.html)** — the pattern our projection and reconciliation readers are instances of. Short pages; they name the pattern but understate the pitfall.
  *Question:* which part of our SES pipeline is the outbox and which is the poller?
- [ ] **[Sequin: Postgres sequences can commit out-of-order](https://blog.sequinstream.com/postgres-sequences-can-commit-out-of-order/)** — the pitfall itself, shown for both timestamps and sequence ids.
  *Question:* why does switching the cursor column from a timestamp to a `bigserial` not fix it?
- [ ] **[Oskar Dudycz: How Postgres sequences issues can impact your messaging guarantees](https://event-driven.io/en/ordering_in_postgres_outbox/)** — the same hole in an outbox, fixed with transaction ids and `pg_snapshot_xmin(pg_current_snapshot())` instead of a time lag.
  *Question:* how does that fix differ from our safety lag, and what does each one cost?

## Do

- [ ] Reproduce it with two `psql` sessions against the dev DB. Session A: `BEGIN`, insert a row with an explicit past `received_at`, do not commit. Session B: select up to `now()` and note the highest cursor. Session A: `COMMIT`. Session B: select after the cursor and confirm the row is missing.
- [ ] Re-read `listForProjection`'s JSDoc and say out loud why each sentence is there.

## Notes

