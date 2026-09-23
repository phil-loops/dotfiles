---
title: Blocking has to be earned
section: Email safety evaluation
order: 20
project: eval-findings
ask: packages/safety-eval/src/feedback.ts#activateRules
lede: A rule may only stop a send once reviewers have backed it.
---

A rule that stops mail makes a claim: *this pattern is bad enough to be worth the cost of being wrong.* Nothing originally checked that claim. A rule could be written on a Tuesday and start stopping customer email immediately, with no feedback but complaints.

The invariant: **a rule may only stop a send once reviewers have said it should** — enough decisive judgements, enough of them agreeing. Below the bar it is downgraded to *review* rather than dropped.

Downgrading matters. Disabling an unproven rule would be worse than useless: you would stop seeing the cases it fires on, which are exactly the cases needed to decide whether it deserves to block. Downgrading keeps the rule visible and keeps its examples flowing to reviewers. A rule earns its way up by being right in public.

Today, with no labels collected, **every blocking rule downgrades.** That is honesty, not breakage — and it is why the labelling queue puts unvalidated blocking rules first. Those have the most to prove.

The default behind this is deliberate and is the part most likely to be undone by accident: see [[eval-gate-default]]. What the gate cannot do is in [[eval-gate-limits]].
