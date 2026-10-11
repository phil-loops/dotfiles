---
title: Audit trail
section: Safety loops
order: 145
project: safety-trail
lede: Every deliberate choice is a decision, appended once; every state change names the decision that caused it. The rest is derived.
---
**Why today's trail fails.** A check or action writes no row, a row is overwritten (an override replaces the model's verdict), or rows don't point at their cause (the team feed sorts six sources by time and links none).

**One table of decisions.** A check by policy v0, an admin's ruling, the health cron, SES disabling a tenant and an owner deleting a team are all decisions: a decider (policy and version, person, or external source), a subject (an email, a domain, another decision), the state version it read, the evidence it saw, and a verdict. All are columns except the evidence, a snapshot typed by the decider's version. A ruling is a person's decision whose subject is another decision.

**State changes cite one decision.** A database trigger versions each safety field (domain disabled, skip flag, override) and stamps the decision id the writing transaction declared; a change with none is visibly unattributed.

**Derived, not stored.** The timeline is decisions and versions in causal order. Pending review is a policy decision with effects and no person's decision on it. The overturn rate is person decisions over policy decisions. Whether an admin action took effect is whether a version cites it.

**Invariants doing the work.** A decision is a function of state as of the version it read, so its effect applies only at that version; otherwise it is recorded as superseded. That one rule stops a stale check undoing a ruling and a stale ruling undoing a newer disable. Order comes from versions and links, not clocks. A decision and its effect commit together, and a check's decision id is its check id, so retries never duplicate.

**Retired by it.** `DisableDomainEvent`, in-place review flags, overrides overwriting the classification, eval rows' prod columns, the feed's ad-hoc sources.
