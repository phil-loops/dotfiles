---
title: What the gate does not do
section: Email safety evaluation
order: 24
project: eval-findings
ask: packages/safety-eval/src/feedback.ts#ruleSupport
lede: It measures agreement, not correctness, and agreement can be inflated.
---

The gate in [[eval-blocking-earned]] is worth exactly what its inputs are worth, and there are three ways those inputs mislead.

**It measures agreement, not correctness.** If reviewers are consistently wrong in the same direction, a rule earns the right to block on the strength of a shared mistake. Nothing here fixes that. It is an argument about who reviews and how, not evidence that the detector is right.

Two other ways it could mislead were closed rather than accepted: credit now follows the reviewer's stated reason, and eligibility counts distinct emails rather than votes. See [[eval-attribution]].

The gate is also only as good as the judgements it counts, which is why hindsight is excluded from them — [[eval-judgement-basis]].

What remains unbuilt, rather than undecided, is in [[eval-open-questions]].
