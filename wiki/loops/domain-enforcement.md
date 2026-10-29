---
title: Domain enforcement
section: Sending domains
order: 20
project: domain-enforcement
ask: models/sending-domain.ts
lede: Every restriction records who imposed it and why; nothing is overwritten; what anyone sees is derived from that record.
---

**The problem.** When a sending domain is disabled, the reason is lost the moment it happens. Detectors flip `SendingDomain.disabled` and log a free-text `disableCriterion` nobody reads; the `DisableDomainEvent` they leave says only "a domain was disabled". Reviewers reconstruct the why from thousands of inlined account-limit-notice cards. Customers see one generic "contact support" for every cause, and the API answers a disabled domain with "No sending domain configured". The positive side is blunter: Reenable overrides every phishing-flagged email the team ever sent, approving one flagged email re-enables a domain disabled for an unrelated reason (including a deliberate admin block), Unleash silently grants a permanent safety-check exemption, and every admin ruling overwrites `decision` in place, so a wrong call leaves no trace.

**Prior art.** This is the archived safety-trail design ([[safety-loops-audit-trail]]) reached from the product side: its "one table of decisions; a ruling is a decision whose subject is another decision; the rest is derived" is the ledger below. Two of its invariants carry over unchanged: *a decision applies only at the state version it read, else it is recorded as superseded* (a stale check can't undo a newer ruling), and *a decision and its effect commit together, keyed so retries never duplicate*. What this page adds is the restriction as the unit of state, actor separated from reason, and a phase plan that starts from today's tables.

## Principles

1. **A restriction is the unit.** Each one has a target, a reason, an actor and (later) evidence, and stays in effect until lifted. A domain is disabled exactly when it has an in-effect restriction; `SendingDomain.disabled` is a cache of that. Every disable records a restriction, even when the domain is already off — at most one in effect per target per reason.
2. **Actor and reason are separate.** The actor is who acted: `detector`, `provider`, `admin` (+ user id), `system`. The reason is why, as a code whose subject — content, behavior or account — is derived in code. An admin is never a reason; an admin who blocks picks one.
3. **Append-only; truth is derived.** Restrictions are written once. Lifts, notes, snoozes and corrections are appended rows. "Is this in effect", "is this case open", "how often is this detector wrong" are all computed.
4. **Wrong is about something specific.** A correction overturns either the *evidence* (the detector mislabeled it — counts against the detector) or the *restriction* (the evidence was right, restricting was the wrong response — counts against the policy or the admin).
5. **An action touches only what it is about.** Approving an email lifts content restrictions on that content. It never lifts a complaint-rate restriction or an admin block.
6. **Machines may tighten; only people may loosen.** Detectors and providers may restrict. Lifting, exempting and overturning need a person and a note. Allowances lapse on their own (lapsing is tightening).
7. **What a lift clears depends on the subject and the verdict.** Content + wrong: clear the cited content. Content + fixed by the customer: the content stays flagged. Behavior: nothing to clear, maybe probation. Account + wrong: the only place a team-level allowance can be granted, explicitly, with an end date.
8. **Restrict the smallest thing that works.** One bad email → hold that content; repeat findings → block the team's publishing; complaint rates or the provider → disable sending.
9. **Our records are the truth; the provider mirrors them.** SES `DISABLED` is evidence that may restrict. SES `REINSTATED` is a note on the open restriction, never a lift.

## Vocabulary

| Term | Meaning |
|---|---|
| restriction | one reason a target is restricted; a row, written once |
| in effect | a restriction not yet lifted |
| lift | a person ends a restriction, with a note (and, from phase 2, an optional overturn) |
| overturn | an appended correction pointing at a restriction or its evidence |
| case | a view, not a record: a domain's restrictions grouped by overlap |
| allowance | a team-level loosening (today: the safety-check exemption), owned by a ledger row, with an end date |

Reason codes (TS union, string column): content — `unsafe_content`, `banned_words`; behavior — `complaint_rate`, `bounce_rate`, `provider_paused`; account — `banned_domain`, `new_domains_paused`, `suspicious_signup`, `team_deleted`; plus `unspecified` (an admin block before the picker) and `unknown` (rows written before phase 1).

## Phases

Each phase adds tables, columns, readers or callers; only phase 2 changes the meaning of an existing column (`decision` becomes a cache, then goes away).

### Phase 1 — Seed: every restriction says who and why

**Ships.** `reason`, `actor`, `actorUserId` on `DisableDomainEvent`. Every disable records a restriction with them — also when the domain is already off, unless one with the same reason is in effect. The domain review page and the queue show what is keeping a domain disabled. Approving a flagged email lifts only content restrictions and re-enables the domain only when none remain.

**Deliberately unchanged.** Re-enable and Block behave as today; `decision` keeps its meaning (Pending/BlockDomain in effect, Reenable/Unleash lifted). Admin blocks record `reason: "unspecified"`.

**Forest** (ticket LOO-6239):

1. `add-restriction-reason-and-actor` — migration + `create` params + an in-effect-for-domain query, with query tests.
2. `record-a-restriction-on-every-disable` — `SendingDomainModel.disable` / `disableForTeam` require `{ reason, actor, actorUserId? }`; all ten disable sites pass theirs (the health cron maps Spam/PreviewSpam → `complaint_rate`, Bounce → `bounce_rate`; SES → `provider_paused`; mark-unsafe → admin + `unsafe_content`; bulk new-signup block → admin + `suspicious_signup`; creation → `banned_domain` / `new_domains_paused`; team deletion → system + `team_deleted`).
3. `show-whats-keeping-a-domain-disabled` — DomainReview and the queue list in-effect restrictions with reason, actor and time.
4. `approve-lifts-only-content-restrictions` — `overrideEmailMessage` lifts content restrictions; the domain flips on only if nothing else is in effect; the ledger line names what still blocks.

**Learn.** The reason mix; how often restrictions overlap; how often each reason gets re-enabled. That picks the next phase.

### Phase 2 — Ledger: lifts and corrections are appended

**Ships.** `EnforcementAction`, append-only: `teamId`, `sendingDomainId?`, `restrictionId?`, `kind` (`lift`, `overturn`, `note`, later `snooze`, `exempt`, `revoke_exemption`), `overturnsTarget` (`evidence` | `restriction`), `overturnsActionId?`, `actorUserId?`, `note?`, `until?`. Every restriction also writes a `restrict` row so system and human decisions are overturned the same way. CHECK constraints enforce the per-kind fields (a `lift` has an actor and a note). In effect = no later `lift`. The assessment flow's four-way switch becomes model calls; the router stops writing Prisma directly. Admins pick a reason when blocking. Lift dialog: "was the flag accurate?" and "was restricting right?".

**Changes meaning.** Re-enable lifts every in-effect restriction, BlockDomain included — this reverses the 2026-10-26 "only Pending is open" call, which the derived state forces; the block survives as its row plus the appended lift. `decision` is written only as a cache until the queue reads the ledger, then dropped.

**Open.** One ledger with the safety log's Review, or a sibling linked through evidence (leaning sibling: different grain — messages vs domains — and the safety log's schema is frozen and unshipped).

### Phase 3 — Evidence: one entry point decides

**Ships.** `enforce({ sendingDomain, reason, evidence })` in `models/sending-domain.ts`: a typed evidence shape per reason; it writes the `SuspiciousActivity`, applies the policy (today's volume/age gate from `handleDisableNewDomain`), and records the restriction with `suspiciousActivityId`, `policyVersion` and the read set (sent count) in one transaction. Detectors move behind it one per branch (AI check — `isSafe` stops writing evidence; banned words; health cron, which starts writing evidence for the reading that tripped); then `handleDisableNewDomain` is deleted. SES and team deletion stay direct restrictions.

**Open.** Whether the env-flag health path (`DISABLE_SPAMMY_SENDING_DOMAINS`, no gate, emails owners) becomes a per-reason policy branch; whether every enforced restriction emails owners (LOO-6237).

### Phase 4 — Workflow: snooze, probation, queue

**Ships.** `snooze` actions with a reason (`awaiting_customer`, `cooling_off`, `probation`) and `until`. The queue hides a snoozed restriction until its deadline, a manual "customer replied", or a new restriction or evidence on the same team; it returns labelled with why. Probation keeps watching after a lift; a new restriction during it links back. Queue columns: reason, plan (paying first), age against the SLA. The account-limit-notice chart replaces the inlined cards: an hourly aggregate query in `queries/account-limit-notice.ts`, limit lines, and a marker at the restriction.

**Open.** SLA per plan; what a missed `awaiting_customer` deadline does (auto-restrict and pause billing, or top of queue); default durations.

### Phase 5 — Allowances

**Ships.** `Team.exemptFromChecksUntil`, set only alongside an `exempt` ledger row; `revoke_exemption`; one predicate `isExemptFromChecks(team, now)` replacing the ~9 raw `skipSafetyChecks` readers; lapsing needs no cron. Unleash becomes lift + exempt, offered only on account-subject restrictions; Block stops resetting the exemption as a side effect.

**Open.** Default length; whether a lapse notifies anyone.

### Phase 6 — Customer surfaces

**Ships.** The banner, the notification email and the API error (`sending_domain_disabled` + `reason`) all read the in-effect restrictions and word themselves by subject.

**Open.** How much to reveal for content flags (Zoe).

### Phase 7 — Other targets

**Ships.** A restriction gains `targetKind` (`domain` | `content` | `team`) and `contentHash?`; the model is renamed via `@@map` so the table keeps its name. Content holds key on the content, not a row, so drafts, republishes and duplicates stay held and edits get re-checked. The content-clearance store becomes their positive counterpart, retiring `safetyClassification = "override"` (and its copy-on-duplicate hole). `enforce` picks the smallest restriction. The safety log, once it enforces, is one more `enforce` caller with a `SafetyDecision` as evidence.

**Depends on.** The `content-units` facet (stable content hash), unmerged.

## Decisions so far

- Restriction is the unit; state derived; record even when already off (reverses the 2026-10-19 "an event exists exactly when a domain flips").
- Case is a view, not a record.
- Actor and reason separate; admins pick a reason.
- Append-only, including corrections; overturn names evidence or restriction.
- Re-enable lifts BlockDomain too (phase 2; reverses 2026-10-26).
- Trust level is out of scope for enforcement.
- No catch-all JSON on new tables; evidence lives in the record it already lives in, typed at the `enforce` boundary.
