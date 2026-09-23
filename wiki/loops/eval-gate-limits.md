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

**Support can be credited to the wrong rule.** A stop currently counts for every rule that fired on that email, whatever the reviewer's actual reason — so a rule can be endorsed for something nobody was endorsing.

**The count can be shallow.** The threshold counts reviewer votes, not distinct emails, so five reviewers looking at one email clears the same bar as one reviewer looking at five. Those are very different amounts of evidence about whether a rule generalises.

The last two are genuine policy choices rather than oversights, with real costs on both sides. They are written up with their alternatives in [[eval-open-questions]].

Separately, the gate is only as good as the judgements it counts, which is why hindsight is excluded from them — [[eval-judgement-basis]].
