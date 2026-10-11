---
title: Audit trail
section: Safety loops
order: 145
project: safety-trail
lede: Three kinds of fact, each appended and never edited, each naming its cause. The team timeline is just those facts in order.
---
**Why today's trail fails.** Each gap is one of three kinds: a check or action writes no row (allows, previews, render scans), a row is overwritten (an override replaces the model's verdict; a domain ruling is updated in place), or rows don't point at their cause (the team feed sorts six sources by time and links none; flagged emails are dated by when the email was created).

**Three facts.**

- *Decision*: one per check, with inputs, reasons and policy version (`SafetyDecision`). Answers why an email was blocked or allowed.
- *State change*: a safety field's new value and its cause, written by a database trigger so no code path can skip it (`SendingDomainStatusVersion`, then the team skip flag and the email override). Answers why a domain is off, and whether an admin action took effect: do changes cite its ledger entry?
- *Ruling*: a person's judgment on a decision or a change, a new row each time. Answers how often each rule is overturned; "pending review" is a change with no ruling.

**Causes.** A writer names its cause for the transaction: a decision, an admin ledger entry, a health alarm, an SES event or a deletion request. A change with none is recorded as unattributed, visibly.

**Retired by it.** `DisableDomainEvent` (disable becomes a change, its ruling a ruling), in-place review flags, overrides overwriting the classification, the prod columns on eval rows, and the team feed's ad-hoc sources.

**Order.** Decision record, then causes on domain changes, then rulings, then the timeline; each answers a question on its own.
