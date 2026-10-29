---
title: Domain enforcement
section: Sending domains
order: 20
project: domain-enforcement
ask: models/sending-domain.ts
lede: Every enforcement decision is appended once with who made it and why; what anyone sees is folded from that log.
---

**The problem.** When a sending domain is disabled, the reason is lost the moment it happens. Detectors flip `SendingDomain.disabled` and log a free-text `disableCriterion` nobody reads; the `DisableDomainEvent` they leave says only "a domain was disabled". Reviewers reconstruct the why from thousands of inlined account-limit-notice cards. Customers see one generic "contact support" for every cause, and the API answers a disabled domain with "No sending domain configured". The positive side is blunter: Reenable overrides every phishing-flagged email the team ever sent, approving one flagged email re-enables a domain disabled for an unrelated reason (including a deliberate admin block), Unleash silently grants a permanent safety-check exemption, and every admin ruling overwrites `decision` in place, so a wrong call leaves no trace.

## Principles

1. **A restriction is the unit.** Each one has a target, a reason, an actor and (later) evidence, and stays in effect until lifted. A domain is disabled exactly when it has an in-effect restriction; `SendingDomain.disabled` is a cache of that. Every disable records a restriction, even when the domain is already off — at most one in effect per target per reason.
2. **Actor and reason are separate.** The actor is who acted: `detector`, `provider`, `admin` (+ user id), `system`. The reason is why, as a code whose subject — content, behavior or account — comes from the reason registry. An admin is never a reason; an admin who blocks picks one.
3. **Append-only; truth is derived.** Every decision — restrict, lift, overturn, note, snooze, exempt — is a row written once. "Is this in effect", "is this case open", "how often is this detector wrong" are folded from the log.
4. **Wrong is about something specific.** A correction overturns either the *evidence* (the detector mislabeled it — counts against the detector) or the *decision* (the evidence was right, restricting was the wrong response — counts against the policy or the admin).
5. **An action touches only what it is about.** Approving an email lifts content restrictions on that content. It never lifts a complaint-rate restriction or an admin block.
6. **Machines may tighten; only people may loosen.** Detectors and providers may restrict. Lifting, exempting and overturning need a person and a note. Allowances lapse on their own (lapsing is tightening).
7. **What a lift clears depends on the subject and the verdict.** Content + wrong: clear the cited content. Content + fixed by the customer: the content stays flagged. Behavior: nothing to clear, maybe probation. Account + wrong: the only place a team-level allowance can be granted, explicitly, with an end date.
8. **Restrict the smallest thing that works.** One bad email → hold that content; repeat findings → block the team's publishing; complaint rates or the provider → disable sending.
9. **Our records are the truth; the provider mirrors them.** SES `DISABLED` is evidence that may restrict. SES `REINSTATED` is a note on the in-effect restriction, never a lift.
10. **A decision applies only to the state it read.** Each decision stores `basedOnDecisionId`, the latest decision on its target when it was made; it takes effect only if that is still the latest, else it is recorded as superseded. A slow check can't undo a ruling made while it ran.
11. **A decision and its effect commit together, and retries never duplicate.** Each decision carries a unique `idempotencyKey` — the check id for a detector, the SES event id for the provider, the request id for an admin — so a retried job finds its row instead of writing a second.

## Kernels

Everything else is a reader or a caller of these five.

| | Kernel | Shape |
|---|---|---|
| K1 | **Decision log** | one append-only table, `EnforcementDecision` |
| K2 | **Reason registry** | one TS map: `reason → { subject, clearsOnLift, customerCopy, policy }`; adding a reason is one entry and the compiler checks every field |
| K3 | **Fold** | pure `inEffect(decisions, asOf)`; domain disabled = an in-effect restriction on it; also the queue, the case view and "what's blocking re-enable". `SendingDomain.disabled` is its cache, and a consistency job recomputes it and flags drift |
| K4 | **Decide + commit** | pure `decide(evidence, context, policyVersion)` → a proposed decision; `commit` applies principles 10 and 11 and writes the decision with its effect in one transaction. Pure `decide` lets a policy change replay against history before it ships |
| K5 | **Views** | queue, case page, banner, API error, approve result — all read K3, worded through K2 |

```prisma
model EnforcementDecision {
  id                   String    @id @default(cuid())
  createdAt            DateTime  @default(now())
  teamId               String
  kind                 String    // restrict | lift | overturn | note | snooze | exempt | revoke_exemption
  targetKind           String    // domain | content | team
  sendingDomainId      String?
  contentHash          String?
  reason               String?   // restrict
  actor                String    // detector | provider | admin | system
  actorUserId          String?
  aboutDecisionId      String?   // lift / overturn / snooze / note → the decision it is about
  overturns            String?   // evidence | decision
  suspiciousActivityId String?
  policyVersion        String?
  basedOnDecisionId    String?
  idempotencyKey       String?   @unique
  until                DateTime?
  note                 String?

  @@index([sendingDomainId, createdAt])
  @@index([teamId, createdAt])
}
```

CHECK constraints tie each `kind` and `targetKind` to its columns (a `restrict` has a `reason`; a `lift` has an `aboutDecisionId`, an `actorUserId` and a `note`; `targetKind = domain` has a `sendingDomainId`). No catch-all JSON: evidence stays in the record it already lives in, typed at the `decide` boundary.

## Vocabulary

| Term | Meaning |
|---|---|
| decision | one row of the log: something someone or something decided, written once |
| restriction | a `restrict` decision |
| in effect | a restriction with no later `lift` about it that took effect |
| lift | a person ends a restriction, with a note, optionally citing an overturn |
| overturn | a correction about a decision or its evidence |
| superseded | a decision whose `basedOnDecisionId` was stale; recorded, no effect |
| case | a view, not a record: a domain's restrictions grouped by overlap |
| allowance | a team-level loosening (today: the safety-check exemption), owned by an `exempt` decision, with an end date |

Reason codes: content — `unsafe_content`, `banned_words`; behavior — `complaint_rate`, `bounce_rate`, `provider_paused`; account — `banned_domain`, `new_domains_paused`, `suspicious_signup`, `team_deleted`; plus `unspecified` (an admin block before the picker).

## Phases

Each phase adds decision kinds, columns, readers or callers. Nothing changes meaning: `DisableDomainEvent` keeps today's meaning until no reader needs it, then stops being written.

### Phase 1 — Seed: every restriction says who and why

**Ships.** The `EnforcementDecision` table with `restrict` decisions only, written by every disable through one commit path (principles 10 and 11 from day one) — also when the domain is already off, unless a restriction with the same reason is in effect. The reason registry and the pure `inEffect` fold. The domain review page and the queue show what is keeping a domain disabled. Approving a flagged email lifts only content restrictions (a `lift` decision) and re-enables the domain only when nothing else is in effect.

**Deliberately unchanged.** `DisableDomainEvent` is still written exactly as today, so the existing queue, Reenable and Block keep working. Admin blocks record `reason: "unspecified"`.

**Forest** (ticket LOO-6239):

1. `add-the-enforcement-decision-log` — migration (table, CHECKs, unique key) + queries (append, list for a domain) with query tests.
2. `add-the-reason-registry-and-fold` — the registry and pure `inEffect`, with unit tests.
3. `record-a-restriction-on-every-disable` — `SendingDomainModel.disable` / `disableForTeam` require `{ reason, actor, actorUserId?, idempotencyKey }` and append through `commit`; all ten disable sites pass theirs (health cron: Spam/PreviewSpam → `complaint_rate`, Bounce → `bounce_rate`; SES → `provider_paused`; mark-unsafe → admin + `unsafe_content`; bulk new-signup block → admin + `suspicious_signup`; creation → `banned_domain` / `new_domains_paused`; team deletion → system + `team_deleted`).
4. `show-whats-keeping-a-domain-disabled` — DomainReview and the queue read the fold.
5. `approve-lifts-only-content-restrictions` — `overrideEmailMessage` appends lifts for content restrictions; the domain flips on only if the fold says nothing else is in effect; the result names what still blocks.

**Learn.** The reason mix; how often restrictions overlap; how often each reason gets lifted.

### Phase 2 — The log takes over

**Ships.** `lift`, `overturn` (of `evidence` or `decision`) and `note` from the assessment flow. Its four-way switch becomes model calls and the router stops writing Prisma directly. Admins pick a reason when blocking. Lift dialog: "was the flag accurate?" and "was restricting right?". The queue reads the fold; `DisableDomainEvent` stops being written.

**Behavior change.** Re-enable lifts every in-effect restriction, an admin's block included — derived state requires it. The block survives as its own `restrict` row with the `lift` about it.

**Open.** One log with the safety log's Review, or a sibling linked through evidence (leaning sibling: different grain — messages vs domains — and the safety log's schema is frozen and unshipped).

### Phase 3 — Evidence: one entry point decides

**Ships.** `enforce({ sendingDomain, reason, evidence })` = pure `decide` + `commit`: a typed evidence shape per reason; it writes the `SuspiciousActivity`, applies the policy (today's volume/age gate from `handleDisableNewDomain`), and records the restriction with `suspiciousActivityId`, `policyVersion` and the read set. Detectors move behind it one per branch (AI check — `isSafe` stops writing evidence; banned words; health cron, which starts writing evidence for the reading that tripped); then `handleDisableNewDomain` is deleted. SES and team deletion stay direct restrictions.

**Open.** Whether the env-flag health path (`DISABLE_SPAMMY_SENDING_DOMAINS`, no gate, emails owners) becomes a per-reason policy; whether every enforced restriction emails owners (LOO-6237).

### Phase 4 — Workflow: snooze, probation, queue

**Ships.** `snooze` decisions (`awaiting_customer`, `cooling_off`, `probation`) with `until`. The queue hides a snoozed restriction until its deadline, a manual "customer replied", or a new restriction or evidence on the same team; it returns labelled with why. Probation keeps watching after a lift; a new restriction during it links back. Queue columns: reason, plan (paying first), age against the SLA. The account-limit-notice chart replaces the inlined cards: an hourly aggregate query in `queries/account-limit-notice.ts`, limit lines, and a marker at the restriction.

**Open.** SLA per plan; what a missed `awaiting_customer` deadline does (auto-restrict and pause billing, or top of queue); default durations.

### Phase 5 — Allowances

**Ships.** `exempt` / `revoke_exemption` decisions with `until`; `Team.exemptFromChecksUntil` as their cache; one predicate `isExemptFromChecks(team, now)` replacing the ~9 raw `skipSafetyChecks` readers; lapsing needs no cron. Unleash becomes lift + exempt, offered only on account-subject restrictions; Block stops resetting the exemption as a side effect.

**Open.** Default length; whether a lapse notifies anyone.

### Phase 6 — Customer surfaces

**Ships.** The banner, the notification email and the API error (`sending_domain_disabled` + `reason`) read the fold and word themselves through the registry.

**Open.** How much to reveal for content flags (Zoe).

### Phase 7 — Other targets

**Ships.** `targetKind` `content` and `team`. Content holds key on the content hash, not a row, so drafts, republishes and duplicates stay held and edits get re-checked. The content-clearance store becomes their positive counterpart, retiring `safetyClassification = "override"` (and its copy-on-duplicate hole). `decide` picks the smallest restriction. The safety log, once it enforces, is one more `enforce` caller with a `SafetyDecision` as evidence.

**Depends on.** The `content-units` facet (stable content hash), unmerged.

## Decisions so far

- Restriction is the unit; state is folded; record even when already off (reverses 2026-10-19 "an event exists exactly when a domain flips").
- One decision log, not restriction rows plus a ledger.
- Case is a view, not a record.
- Actor and reason separate; admins pick a reason.
- Append-only, including corrections; overturn names evidence or decision.
- Re-enable lifts an admin's block too (phase 2; reverses 2026-10-26).
- Trust level is out of scope for enforcement.
- No catch-all JSON on new tables.
