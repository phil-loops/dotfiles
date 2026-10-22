---
title: What the gate keys on
section: Working with safety classifiers
order: 11
project: classifier-framing
lede: Four levers separate the flagged brief from the one that passed. All four are surface, not operation.
---

The gate reads how the ask is worded, not what it does. Four levers, in rough order of weight — the A/B that isolated them is in [[framing-reframe]].

1. **Target ownership and authorization.** "We own this repo, we are fixing our own gaps" reads as first-party defensive work. Silence on ownership reads as targeting something unnamed.
2. **Adversarial vocabulary density.** `exploit / attack / takeover / spoof / attacker / pentest` is the single biggest trigger. The same finding in correctness language — `scope`, `invariant`, `gap` — does not fire it.
3. **Requested output shape.** Asking for *operational exploit steps* trips harder than asking for a *defect plus remediation*. Same defect, different deliverable.
4. **Intent valence.** "Find how to break in" versus "verify a safety property holds and fix where it doesn't."

That the operation is constant across both briefs is the point: the classifier never measured the operation. That is also its weakness, which [[framing-classifier-lesson]] draws out.
