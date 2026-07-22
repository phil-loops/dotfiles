---
title: 6 · Send
section: The six hops
order: 35
ask: jobs/mail-send.ts
lede: jobs/mail-send, a worker — SES, then the verdict flows back into the throttle.
---

The worker ranged-GETs its slice of the artifact, calls SES, and appends `sent` or `error` to [[status-log]].

Then it measures [queueDelayMs](src:jobs/mail-send.ts#/queueDelayMs/) — sent-at minus enqueued-at — and reports it. This is the number the [10-second SLA](src:lib/app-env/mail-send.ts#/MAIL_SEND_HIGH_PRIORITY_SLA_MS/) judges. Inside the SLA, tokens are credited; a miss decays the balance. See [[throttles]].

The subtlety is what that number covers. `queueDelayMs` spans the **entire pipeline** — enqueue to SES-accepted — not just the send step. It absorbs time parked in Valkey, waiting for a claim, sitting in SQS, and rendering. That is deliberate: it is a customer-visible latency measure, not a component metric.

Which is why the feedback loop bites the way it does. When *anything* upstream is slow, transactional mail misses the SLA, the balance decays, and low-priority mail is throttled to give the whole pipeline room. **Workflow throughput is the shock absorber for transactional latency.**

After SES accepts, the story continues only through inbound SES webhooks — deliveries and bounces arrive later, as separate events.
