---
title: Two experiments, never one table
section: Email safety evaluation
order: 34
project: eval-findings
ask: packages/safety-eval/src/safety-replay.ts#comparableBasis
lede: "Could better rules have done better then?" and "would we decide differently now?" must not be averaged.
---

There are two useful questions and they must never be answered in the same table.

**"Could better rules have made a better decision with what we knew then?"** replays the original context snapshot. This is the fair comparison, and by [[eval-replay-asymmetry]] it is free.

**"Knowing what we know now, would we decide differently?"** uses a newer snapshot. A legitimate question and an illegitimate comparison — the answer had knowledge the original decision could not have had.

Each result carries which of the two it is. The comparison helper refuses to read a mixed set as one experiment, and refuses two reassessments taken against *different* snapshots, because those are two states of knowledge and averaging them means nothing.

One caveat is baked into the name. A reassessment recomputes the deterministic facts against the new snapshot but **reuses the model's observations**, which were made under the old one. Where the model saw only the email, that reuse is sound; where the model was shown context, those observations describe context that has since changed. So it is called *evidence-only*: the name is the warning, and a complete reassessment needs a fresh model run.

A subtler trap this closed: while replay was ungated and decisions were gated, replaying an unchanged rule set reported a change that had not happened.
