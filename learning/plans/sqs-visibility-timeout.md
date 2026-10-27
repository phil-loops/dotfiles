# Tutor plan: SQS visibility timeout and how loops manages it

Topic id: `sqs-visibility-timeout` (map recorded in graph.json — `learn state --topic sqs-visibility-timeout`).
Start: `/tutor sqs-visibility-timeout` (or `/tutor visibility timeout`). Prepared 2026-10-22, nothing run yet.
Motivating incident: LOO-6248 (today) — a `svixDispatch` job duplicated a webhook; one message landed in `dlq-webhooks-jobs`.

This file is prep, not a script: build each rung from Phil's last answer (focusing, not funneling).
Rung order below is the default climb; he steers.

## Calibration for this topic (from the graph)

- **Problem-first, not worked-run.** Strong analogs exist: `lease-renewal`, `lock-ttl`, `claim-lease-sweep`
  (transfer once), `ownership-token`. Enter stations 1–3 through those analogs ("how is this different
  from the croon lock / the mail-queue claim?").
- **Two open misses map straight onto this topic** — they are the openers and the hypercorrection payoff:
  - `ttl-vs-renewal-interval` — "attributed recovery time to how often you renew" → SQS: recovery = 30s
    visibility, not the 20s extension interval.
  - `lock-guards-holders-not-execution` — "believed the lock prevents concurrent execution" → SQS:
    lapsed visibility doesn't stop the running handler.
- Known tell: direction/ordering flips. Every timeline rung uses concrete timestamps (t=0, t=5, t=30).
- He audits credit. Under-claim: anything after a told fact is `scaffolded` at best.

## Facts to TELL (conventions — never make him derive these)

- F1 ReceiveMessage hides a message for the visibility timeout; it is "in flight". Only DeleteMessage removes
  it. Nothing else does — not success, not a throw. (`lib/sqs/enqueue.ts:138-149`, `:183-191`)
- F2 Loops queues set no `visibility_timeout_seconds` in terraform, so they get the SQS default, 30s.
  Receive doesn't pass `VisibilityTimeout` either. (monotoad `projects/terraform/shared/sqs/main.tf:13-26`;
  `lib/sqs/enqueue.ts:143-149`)
- F3 ChangeMessageVisibility(handle, N) sets the deadline to *now + N*, not +N on top of the old deadline.
- F4 Each receive increments the message's receive count. Redrive policy: once the count exceeds
  `maxReceiveCount` the message moves to the DLQ. Loops' shared module: `maxReceiveCount = 3`, DLQ named
  `dlq-<queue>`. (monotoad `shared/sqs/main.tf:22-25,49-55`, `variables.tf:20-23`; `webhooks-jobs` uses
  defaults: `production/loops/main.tf:55-69`)
- F5 The svix client mints `idempotency-key: auto_<uuid>` per `message.create` call, reuses it across its own
  3 attempts (50ms, then 100ms backoff). (`node_modules/svix/dist/index.mjs:216`, `:242-254`, svix 2.6.2)
- F6 svix-server holds a ~5s idempotency lock per key (source: the abort branch's note,
  `abort-timed-out-svix-dispatch` 1aa18f37e5).

## Code to pin raw (no annotations near the answer)

- `lib/job-queue/poll.ts:9` — `defaultVisibilityTimeout = 30_000`
- `lib/job-queue/poll.ts:93-107` — on receive: push to `inFlightMessages` with a `setInterval(extend, 30_000 - 10_000)`
- `lib/job-queue/poll.ts:116-126` — `extendVisibility` → ChangeMessageVisibility(30s); failure only logs
- `lib/job-queue/process.ts:92-118` — callDef; `{retry:true}` → return without delete; finally clearInterval; delete; catch logs; splice
- `lib/job-queue/process.ts:121-123` — `shouldDeleteMessage = !result.retry`
- `jobs/job-types.ts:171-174` — `svixDispatch` → `AppEnv.webhooksJobsQueueUrl`
- `lib/svixIntegration/svixDispatchLib.ts:20,51-66` — the old Promise.race 5s timeout (main today)
- `lib/svixIntegration/svixDispatchLib.ts:458-475` — `dispatchSvix` enqueues `{teamId, payload}` (no key on main)

## Opener (cold, bare, croon setting — no SQS framing yet)

**O1 · ttl-vs-renewal-interval (contrast re-test of the open miss).** Croon lock, TTL 30s. Holder A renews
every 20s. A renewed at 12:00:00 and the pod is OOM-killed at 12:00:07. B tries every second.
When does B first get the lock? Then: same, but A renewed every 5s (last renew 12:00:05, killed 12:00:07).
→ 12:00:30 vs 12:00:35. Recovery is TTL after the *last renew*; the interval only moves where that last renew
falls. Ask confidence before the reveal. Record against `ttl-vs-renewal-interval`.

Then: "what do you think an SQS visibility timeout is, more or less?" and show the 5-station map.

## Station 1 — In flight, not gone  (`sqs-in-flight-invisible`, `sqs-at-least-once`)

Enter via analog: "the mail queue claimed work into an in-progress set with an expiry and a sweeper requeued
it. What's the same here, what's missing?" (Answer to land: SQS *is* the sweeper; no separate process.)
Tell F1, F2.

**R1.1 predict.** Worker W1 receives message M (svixDispatch) at t=0. W1 calls ReceiveMessage again at t=10.
Worker W2 calls ReceiveMessage at t=10 and t=31. W1 never deletes M and is still alive. Who sees M, when?
→ Nobody at t=10; W2 (or W1) at t≈30+. *Except* loops would have extended at t=20 — hold that back; for this
rung say "imagine no extension".

**R1.2 predict (trap — frame as hard).** W1 finishes the svix call successfully at t=4 and the pod is
SIGKILLed at t=4.001, before `deleteMessage` (`process.ts:107`). What does the customer see by t=40?
→ Two webhooks. The queue can't tell "done, not deleted" from "never done". Summit of station 1:
**at-least-once**. Ask for his sentence (`learn restate sqs-at-least-once`).
Transfer available: `sqs-in-flight-invisible via claim-lease-sweep` — "in mail-queue terms, what is SQS's
in-progress set and what is its sweeper?"

## Station 2 — Success, throw, crash  (`throw-waits-out-visibility`, `crash-recovery-is-visibility`)

Pin `process.ts:92-118` raw.

**R2.1 misconception probe: "a thrown job is retried immediately".** svixDispatch received at t=0, svix call
times out and the handler throws at t=5. When does any worker next see M? Ask confidence.
→ ~t=30. The catch at `:110-111` only logs; nothing re-enqueues. The `finally` at `:103-105` clears the
extension timer, so the original t=0 deadline (0+30) stands. Miss → contrast: same, but the handler throws at
t=25 (one extension already ran at t=20) → next visible at t=50, not t=30.

**R2.2 predict.** Same message, handler returns `{retry: true}` instead of throwing (`:96-101`,
`:121-123`). Difference in what SQS sees? → None: no delete either way; only the log line differs
(`count-audience.ts:85`, `load-campaign-send.ts:69`, `translate-email.ts:246` use this on purpose).

**R2.3 contrast for the opener's miss — the SQS version.** Handler is mid-job, last extension at t=40,
pod killed at t=47. When is M visible again? → t=70 (40+30). Then "what if extensions ran every 5s,
last at t=45?" → t=75. Recovery = visibility timeout after the last extension. This is the transfer of
`ttl-vs-renewal-interval` (via `lock-ttl`) — record `crash-recovery-is-visibility` transfer via `lock-ttl`
only if unaided.

## Interleave (cold, before station 3)

**O2 · lock-guards-holders-not-execution (contrast re-test, croon setting).** Croon lock TTL 30s, holder A's
job is a 50s loop that never renews. At t=30 the key expires and B acquires it. What is A doing at t=31?
→ Still running its loop; two runners. Record against `lock-guards-holders-not-execution`.

## Station 3 — Keeping a long job's message  (`visibility-heartbeat`, `visibility-is-not-a-job-timeout`)

Enter via analog: "croon renewed at TTL/2. Loops extends at 20s with a 30s timeout. What's different?"
Pin `poll.ts:9,93-107,116-126`. Tell F3.

**R3.1 predict.** A job runs 75s. Lay out the deadline after each tick: receive t=0 (deadline 30);
extensions fire at t=20, 40, 60 → deadlines 50, 70, 90; finishes t=75, `clearInterval`, delete. Ask him to
produce the column, not just "it works". Margin per beat = 10s (vs croon's TTL/2).

**R3.2 misconception probe: "visibility timeout = job timeout" (trap).** Same 75s job, but the SQS endpoint
503s on the t=20 ChangeMessageVisibility (`poll.ts:123-125` only logs). t=40 succeeds. What happens between
t=30 and t=40, and at t=40? → At t=30 M is visible; W2 receives it (new receipt handle) and starts a second
copy. W1 keeps running — nothing stops it. W1's t=40 extension uses W1's *old* receipt handle (behavior of a
stale handle is an AWS detail — tell it if asked; don't make it the point). Both run concurrently; both may
call svix. Summit: visibility guards *delivery*, not *execution* — same shape as his croon miss.

**R3.3 invent (budget 1 of 2).** "Invent the rule for choosing the extension interval given the visibility
timeout." Contrast cases to run his rule against: (a) interval 29s / timeout 30s, ChangeMessageVisibility p99
= 2s; (b) interval 1s / timeout 30s, 500 in-flight messages per worker (`concurrency` from
`lib/job-queue/index.ts:42`); (c) interval 20s / timeout 30s, one failed extension. No verdict until he has run
his rule on all three; then the canonical: margin ≥ one failed beat + call latency, overhead ∝ in-flight/interval.

## Station 4 — Receive count and the DLQ  (`receive-count-redrive`)

Tell F4 (convention). Pin the monotoad module.

**R4.1 predict — the incident timeline.** svix-server pod wedged for 2 minutes. svixDispatch M received t=0;
each attempt throws at +5s. Build the timeline: receives at ~0, ~30, ~60 (each throw at +5, reappear at the
original +30). At ~90 the next receive would be the 4th > maxReceiveCount 3 → M moves to
`dlq-webhooks-jobs`. Ask: when does it land in the DLQ, and how many svix calls were made? (3 delivery
attempts; with the old code each was one hanging request — see station 5.) Pitfall to probe: does the DLQ
move happen "after the 3rd failure" or "on the 4th receive"? → on the receive that would exceed the count.

**R4.2 predict.** `load-campaign-send` returns `{retry: true}` on purpose to wait for something. It waits
3 times. Where is the message after ~90s? → The DLQ — `{retry:true}` attempts count too. (Only true if that
job's queue uses the default count; the shared module default is 3, the deployer queues override to 1:
monotoad `production/deployer/main.tf:20`.)

## Station 5 — Making redelivery harmless  (`timeout-doesnt-cancel-remote`, `idempotency-key-minted-before-retry-boundary`, `nested-retry-layers`)

Pin `svixDispatchLib.ts:51-66` (main, old code) raw.

**R5.1 predict (trap).** Old code. At t=0 `svix.message.create` goes out on a connection to a wedged pod. At
t=5 the race rejects; the handler throws. At t=7 the wedged pod un-wedges and writes the message. At t=30 the
redelivery calls `message.create` again on a healthy pod. How many webhooks? → Two. The race abandoned the
promise, not the HTTP request (`timeout-doesnt-cancel-remote`).

**R5.2 invent (budget 2 of 2).** "Invent a rule for the svixDispatch job so the R5.1 sequence yields one
webhook." Contrast cases for his rule: (a) key = `crypto.randomUUID()` inside the handler; (b) key = hash of
payload (two genuinely distinct identical events, e.g. two `contact.unsubscribed` for the same contact on
different days); (c) key minted in `dispatchSvix` at enqueue and carried in the message. Then tell F5 and
show what the client already does (`index.mjs:216`) — a per-call key, so it is case (a). Canonical: mint
before the outermost retry boundary. The fix: branch `pin-svix-idempotency-key-across-retries`
(1a5b59edd8) mints it in `dispatchSvix` and threads it through `jobs/svix-dispatch.ts`.
Transfer available: via `ownership-token` ("croon's token was minted per acquisition — what would break if
it were minted per renew call?") or via `durable-row-before-send` (tag must exist before the send).

**R5.3 predict — layers nest (summit).** Tell F6. New code from both LOO-6248 branches: key pinned at
enqueue; each svix attempt aborted at 5s (`abort-timed-out-svix-dispatch`, 54f62d1e3f) so the client's own
retries (50ms, 100ms) reconnect. Attempt 1 times out at t=5 after svix-server took the key's lock. Attempt 2
leaves at t=5.05 with the same key. What does it hit? → the still-held ~5s idempotency lock → it stalls/
conflicts; that's why the timeout must cover the lock (1aa18f37e5). Then: if all 3 attempts fail, the job
throws, the SQS redelivery at ~t=30 carries the same key → svix returns the original message, no duplicate.
Ask him to draw the two loops: inner (svix, ms, one key per call) inside outer (SQS, 30s, 3 receives, key per
enqueue). His sentence → `learn restate nested-retry-layers`.

Critique row (earned only on real code): pin `jobs/svix-dispatch.ts` on main vs on
`pin-svix-idempotency-key-across-retries` and ask "safe under redelivery?" — or `jobs/count-audience.ts:85`.

## Recording cheat-sheet

```
learn evidence '{"concept":"<id>","level":"predict","credit":"unaided","outcome":"hit","confidence":"medium","rung":"predict","note":"..."}' --topic sqs-visibility-timeout
# a miss also needs "contrast": "<same situation, one variable changed>"
# an unaided transfer needs "via": "<analog id>"
learn restate <id> '<his sentence>'
learn question '<text>' --concept <id> --topic sqs-visibility-timeout
```
