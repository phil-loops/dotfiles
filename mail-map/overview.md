---
title: Six hops, end to end
section: Orientation
order: 10
ask: lib/send-mail.ts
lede: What happens between sendMail() and SES, and where the mail physically sits at each step.
---

Every email in the product enters through one function — [sendMail](src:lib/send-mail.ts#sendMail) — and leaves through SES. Between those two points it is written down, parked, claimed, metered, rendered and sent, by four different processes that share no memory.

The hops:

1. **[[hop-birth]]** — a *render request* row is written to Postgres, stamped with a priority.
2. **[[hop-park]]** — its id is pushed into that team's Valkey queue. Nothing is running yet.
3. **[[hop-claim]]** — a separate long-running service claims a whole team to work on.
4. **[[hop-peek]]** — one atomic script decides which ids may move, and how many.
5. **[[hop-render]]** — a worker turns ids into bytes and puts them in S3.
6. **[[hop-send]]** — another worker calls SES and reports how long the whole trip took.

That timing report feeds back into hop 4, which is the part worth understanding: the pipeline throttles itself based on its own measured latency. See [[throttles]].

The stores are described separately, because most confusion here is about *where a thing lives*, not *what runs next*: [[enqueued-email]], [[status-log]], [[packed-artifact]], [[team-queue]], [[team-lease]], [[throttles]], [[sqs-queues]], [[partitions]].
