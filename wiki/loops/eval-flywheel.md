---
title: The safety evaluation flywheel
section: Email safety evaluation
order: 10
project: eval-findings
ask: packages/safety-eval/src/feedback.ts
lede: A detector nobody grades never improves; this is the machinery for grading one.
---

Loops sends email for its customers. A few of those customers are running a scam, and if their mail goes out, Loops' sending reputation and every other customer pays for it. So an automated check reads outgoing mail and can stop it.

The problem this project exists to solve: **nobody was grading that check.** It ran, it decided, and no one could say how often it was right — not because the question is hard, but because nothing recorded what answering it would need.

The loop is: a candidate detector reads an email and produces observations about it, plus a decision derived from those observations. A human later says what they would have done. Comparing the two teaches you something — but only if you are careful about *what*, and that care is most of the design.

Everything stored, and every invariant, follows from [[eval-replay-asymmetry]] and from the fact that there are [[eval-two-judgements]] which are not interchangeable.

## What this is not

Not a detector ready to protect anyone. Every result so far ran in **shadow**: alongside the real decision, changing nothing. The shadow has no authority and isn't asking for any.

Not a measurement of how good the detector is, either. It is the apparatus that would let you measure, plus invariants that stop the apparatus flattering itself: [[eval-blocking-earned]], [[eval-judgement-basis]], [[eval-evaluation-is-a-row]]. What is still genuinely undecided is in [[eval-open-questions]].
