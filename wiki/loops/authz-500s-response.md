---
title: Pentest 500s — response
section: Pentest LOO-5926
order: 10
project: authz-500s
ask: trpc/routers/incoming-webhook.ts
lede: Their finding was an error shape; the audit it triggered found a cross-tenant write they never reached.
---

The reported finding is real and now largely closed. Written up here as a reply to the tester,
plus the three issues the same audit turned up that their test did not reach — one of which is a
genuine cross-tenant write, materially more serious than the 500s they reported.

## Their remediation bullets, one by one

**1. "Add an explicit ownership assertion … before any query runs."** Done, but at the seam that
already existed rather than through a new helper. Every affected procedure runs under `loopsAuth`,
which takes a `meta` select scoping the lookup to the caller's team and runs it before the handler
body. The ownership constraint was therefore always in the `where` clause — a foreign id simply
matched nothing. What was missing was a decision about the empty result: the handler read
`team.<relation>[0]` and carried `undefined` into the next call, or bare-threw an `Error`. Both
surfaced as the generic 500.

We audited all 60 `loopsAuth` procedures whose `meta` scopes a relation by an input id. 47 already
answered 404. The remainder now do: **#10636** closed every unguarded dereference in that category
and converted 8 bare throws across 6 procedures. `userImports.getFullJob` — their literal repro —
answers `NOT_FOUND`. So does `mailingLists.importSegment`, which is the closest analogue and was
trivially reachable (`toMailingListId` is a required input).

Worth naming explicitly: a scoped-select 404 genuinely cannot distinguish "exists on another team"
from "does not exist", because the query never matched either way. That removes the existence
oracle they flagged rather than papering over it.

**2. "Wrap multi-step mutations such as the webhook update in a transaction."** **#10630** fixed the
ordering rather than the atomicity. `incomingWebhook.updateWebhook` now loads the team's mailing
lists and event patterns up front under the caller's team and answers `NOT_FOUND` for any unknown
id **before** the settings write. The partial write they observed — signing secret persisted, then
a later step threw — cannot happen by that route any more. The writes are still sequential; a
single atomic write is built and parked, since what remains is a crash mid-loop rather than a
rejected reference.

The more interesting half of this one, which their repro did not surface: the event pattern id was
never tenant-checked at all. Another team's **real** `EventPattern` id could be saved onto your
mapping — a cross-tenant reference write, not an error shape. A production query found 0 such rows;
it was never exploited.

**3. "Separate expected authorisation failures from genuine exceptions in the error pipeline."**
Agreed, not shipped. It is a four-line change, parked behind the correctness work. Every new 404
still flows through `logError`, so their noise point stands — and, strictly, the 404s we added made
it marginally worse until that lands.

## One 500 kept deliberately

`transactionals.create` falls back to the team's `order: 0` transactional group. An early pass
404'd that fallback, which was wrong: no user-supplied id is involved, and a 404 would have hidden a
real data bug — 33 production teams have no order-0 group — behind a user-facing error with no
alert. It now throws a 500 carrying `MISSING_DEFAULT_TRANSACTIONAL_GROUP` and fires an alert.

That is the line we drew, and it is the one their finding is really asking for: **an authorization
outcome answers 4xx; a violated internal invariant stays 5xx and pages someone.** A blanket
"unauthorized lookups must not 500" rule would have erased a real signal.

## What the audit found that the test did not

Their report cites only tRPC. The REST handlers under `pages/api/**` carry the same class of bug,
and there it is not limited to error shape.

**A. `POST /api/campaignGroups/updateAll` — cross-tenant write (the serious one).**
The handler *did* check ownership: it compared each element's `teamId` to the session's team. But
that `teamId` arrives in the request body, so the attacker writes both sides of the comparison and
it always passes — while `element.id`, which actually selects the row to write, was never checked.
A request carrying another team's group id and your own `teamId` reorders that team's campaign
groups. The damaging case is setting their order-0 group to anything else: `campaigns/create`
selects the default group by `order: 0` and dereferences `[0]` unguarded, so the victim's team gets
a 500 on every campaign creation until the data is repaired. Fixed by matching the ids against the
team's own groups and removing `teamId` from the body type so nothing invites trusting it again.

**B. `POST /api/campaigns/create` — unowned group reference.**
`campaignGroupId` was taken from the body and connected to the new campaign with no check, filing
your campaign under another team's group. Fixed with a team-scoped lookup and a 404 before any
write. (The duplicate path reassigns the id from the source campaign, which is already team-checked.)

**C. `GET /api/sending-domains/download` — no authentication at all.**
No session, no API key, no shared secret: anyone who knew a `sendingDomainId` could fetch that
team's DNS records. The id is not secret — it sits in the app URL at
`/sending-domain/<id>/domain-records`. The records themselves are published in public DNS by design,
so this is an enumeration-and-disclosure oracle (confirming an id exists and naming the domain
behind it) rather than a secret leak. Fixed: session required, and another team's domain answers
404 rather than 403 so the endpoint stops distinguishing "not yours" from "not a thing".

**D. `TriggerNodeQueries.update` — unscoped write, reachable from a `userAuth` procedure.**
`createPlatformEventPatternIfNotExist` passed a caller-supplied trigger node id to a query that
updated by id alone, so any signed-in user holding another team's trigger node id could repoint that
node at an event pattern they control and break the victim's workflow trigger. The query now
requires a `teamId` and returns null when nothing matches. Landed separately as #10652.

## Non-security 500s in the same family

Deleted mailing lists linger in webhook mapping JSON — 11 production mappings across 8 teams. Those
teams' webhook saves now 500 (previously they 500'd later, in the write), and the receiver silently
skips the mapping's other lists. A cleanup script is written and parked; it needs a production run.

## Status

| Item | Where | State |
| --- | --- | --- |
| Webhook reference ownership + checks before write | #10630 | merged 2026-09-22 |
| 404 for empty team-scoped tRPC lookups (incl. `getFullJob`) | #10636 | merged 2026-09-23 |
| Trigger node update scoped by team | #10652 | merged 2026-09-23 |
| `campaignGroups/updateAll` cross-tenant write | `check-group-ownership-before-write` | gates-green, awaiting push |
| `campaigns/create` unowned group | `reject-unowned-campaign-group-on-create` | gates-green, awaiting push |
| `sending-domains/download` unauthenticated | `authenticate-domain-record-download` | gates-green, awaiting push |
| Expected 4xx out of error tracking | `trpc-quiet-client-errors` | parked (4 lines) |
| Atomic webhook write | `webhook-save-atomic` | parked |
| Stale webhook mailing-list cleanup | `webhook-stale-list-cleanup` | parked, needs prod run |

## Retest surface

`userImports.getFullJob`, `mailingLists.importSegment`, `incomingWebhook.updateWebhook` (both the
foreign mailing-list id and the foreign event-pattern id), and — once pushed — the three REST
handlers above. The webhook case is worth re-running with the receiver check they used, since that
is what made the partial write observable.
