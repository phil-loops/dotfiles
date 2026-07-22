---
title: 1 · Birth
section: The six hops
order: 30
ask: lib/send-mail.ts
lede: any web or API process — the render request is written down and stamped with a priority.
---

Five callers funnel into `sendMail`: the transactional API, a workflow's send-email node, campaign fan-out, opt-in, and previews.

[getPriority](src:lib/send-mail.ts#getPriority) stamps the number that decides everything downstream — transactional 32, preview 48, workflow 64, campaign 128. Then a single Postgres transaction writes the [[enqueued-email]] row together with its first [[status-log]] entry, so a row can never exist without a state.

**Priority 64 is the fault line.** "High priority" is defined as strictly less than [the threshold](src:lib/mail-send-tokens.ts#HIGH_PRIORITY_THRESHOLD), and [isHighPriority](src:lib/mail-send-tokens.ts#isHighPriority) is the one-line test. Workflow mail is *exactly* 64 — so it falls on the low-priority side by a single point, sharing a class with campaign mail.

Within that class its lower number still sorts it ahead of campaigns. But the consequence that matters is at [[hop-peek]]: it is subject to the token gate, and transactional mail is not.
