---
title: What the reviewer knew
section: Email safety evaluation
order: 30
project: eval-findings
ask: packages/safety-eval/src/feedback.ts#asEvaluated
lede: Later knowledge must not make an earlier detector look better or worse than it was.
---

A detector reads an email in March and allows it. In May the team behind it is disabled for fraud. In June you sit down to grade the detector.

You now know something it could not have known. Record "should have stopped this" and count it, and you have graded a March decision with June's knowledge. Run the trick the other way — let a candidate see today's verified-domain data while comparing it against last year's decision — and the candidate looks **better** than it is. That second failure is the dangerous one, because it flatters whatever you are trying to ship.

So every judgement records its **basis**: *as evaluated* (the reviewer saw what the evaluation saw) or *after the fact* (they knew something it could not have).

Both are true and both are kept. Only the first counts toward whether a rule has earned the right to block. The second measures something genuinely valuable — what eventually happened — and is reported separately, because "was this decision justified at the time?" and "did this turn out to be fraud?" are different questions, easy to conflate and expensive to conflate.

Recording it correctly turned out to be the easy part: [[eval-basis-leaks]]. The same reasoning applied to experiments rather than judgements gives [[eval-replay-vs-reassess]].
