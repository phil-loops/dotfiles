---
title: What a stop is evidence for
section: Email safety evaluation
order: 26
project: eval-findings
ask: packages/safety-eval/src/feedback.ts#ruleSupport
lede: Co-occurrence is not endorsement, and agreement is not breadth.
---

Several rules usually match one email, and a reviewer judges the email as a whole. Crediting the verdict to every rule that fired sounds fair and is not.

Five crypto-scheme emails each match an impersonation rule **and** a rule about free reply-to addresses with differing link hosts. You stop all five — because the business is prohibited. Both rules reach a perfect record. The reply-to rule now blocks any small business using a Gmail contact address. You endorsed "these five are scams"; it heard "this pattern is worth blocking on".

So the reviewer names **which** of the fired rules justified the stop, and only those are credited. A rule that merely fired alongside the real reason records that it fired and earns nothing.

The asymmetry matters: a **send** still counts against every rule that fired. The rule flagged mail you would have sent, whatever the reviewer was thinking — that is a false positive regardless of reasoning.

Eligibility also counts **distinct emails**, not votes. Five reviewers agreeing about one email tells you the reviewers agree; it says nothing about whether the rule generalises.

A note on where this leads: a policy reason like *prohibited business* currently has no rule at all. If it is a real reason to stop mail, it should be a rule — and then attribution has somewhere to land instead of leaking into whichever content rule happened to fire.
