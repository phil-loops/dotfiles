---
title: Absence of evidence permits nothing
section: Email safety evaluation
order: 22
project: eval-findings
ask: packages/safety-eval/src/findings-policy.ts#collapseFindings
lede: Blocking requires an affirmative act; reviewing is free.
---

Reviewer support is supplied explicitly at the point of decision, and **supplying nothing means nothing may block.**

The direction is chosen. A caller who forgets the evidence gets an over-cautious system, not an over-confident one.

The first version had a convenient default, and a review named the trap precisely: missing wiring would compile fine and look exactly like "insufficient evidence" — indistinguishable from a rule that genuinely hasn't earned it. Making the argument required turns a silent policy change into a type error.

It paid immediately. The moment it was required, the code stopped compiling in one place: the running evaluation pipeline has no label snapshot to hand over. That was always true; it had simply been invisible. It is now a stated limitation rather than a plausible-looking zero, which also means the gate's "yes, this earned it" branch has never been exercised in production shape.

The same lesson recurs elsewhere in this project. A default that looks like a reasonable fallback is usually a policy decision wearing ordinary clothes — see the interface half of [[eval-basis-leaks]], where a defaulted value silently misclassified what reviewers knew.
