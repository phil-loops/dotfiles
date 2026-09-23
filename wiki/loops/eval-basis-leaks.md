---
title: Storage is not enforcement
section: Email safety evaluation
order: 32
project: eval-findings
ask: models/safety-review.ts#currentJudgements
lede: The basis was stored correctly and still leaked twice — in selection, and in the interface.
---

Both leaks were the same mistake in different clothes, and both are worth remembering because neither showed up as a failing test.

**Selection.** Judgements were collapsed to "the latest one per reviewer per email." So a later after-the-fact judgement *replaced* the as-evaluated one before anything looked at the basis — the honest earlier judgement was simply gone, and the filter downstream had nothing left to protect. Basis had to become part of a judgement's identity, not merely a column on it. The same reviewer can now hold one as-evaluated and one after-the-fact judgement at once, and correcting either leaves the other alone.

**The interface.** The server defaulted the basis and the review screen never offered the choice. A reviewer who knew perfectly well they were judging with hindsight had it recorded as if they weren't — so every careful thing underneath was dead on arrival. The screen now asks what you are judging on, and the server refuses to assume.

The shared lesson: **an invariant enforced only in storage is not enforced.** It has to survive selection, and it has to survive the interface. Anywhere between the two that quietly supplies a value is where it will fail, usually silently — compare [[eval-gate-default]].
