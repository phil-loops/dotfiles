---
title: Rules are cheap, prompts are expensive
section: Email safety evaluation
order: 14
project: eval-findings
ask: packages/safety-eval/src/safety-replay.ts#replayEvaluation
lede: One kind of change re-tests for free over everything already recorded; the other costs a model run per email.
---

Changing a **rule** — how observations become a decision — can be re-tested against every evaluation ever recorded, at no cost, because the observations are still sitting there. Ask "what would this rule set have decided?" and the answer is a computation over stored data.

Changing the **prompt** — how the model makes observations — cannot. Every stored observation came from the old prompt. Testing a new one means paying for a fresh model run across the corpus, and the results are not comparable to what came before.

This asymmetry is the single most useful fact about the system, and the storage exists to preserve it. Observations, the deterministic facts extracted from the email, and the decision are kept as separate things rather than one blob, precisely so the cheap experiment stays cheap.

It also shapes where feedback goes. A reviewer disagreeing with an outcome might mean the rules mapped the observations badly — cheap to fix, testable immediately. Or it might mean the observations themselves were wrong, which needs a new prompt generation. The report distinguishes these, because sending a prompt problem to the rules layer wastes the expensive lever on a question it cannot answer.

The nuance: replaying rules is free, but it answers only what *those observations* support. A rule that needs a fact the detector never extracted cannot be tested by replay at all.
