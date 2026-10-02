---
title: Measure the model bare
section: Content safety
order: 44
project: safety-shadow
lede: Bare agreement decides which model runs. Retrieved corrections are a patch, measured separately, and retired into rules.
---

Part of [[content-safety-m2-shadow]]. Two measurements that must never share a column.

**The floor is measured bare.** A candidate is scored on the holdout with its prompt, its schema, and nothing else in context. Agreement means the value and the quoted span both match the reviewer's; the right value with the wrong sentence is a miss. Scored per slice: language, length, image-heavy. Each replay call logs time to first token and total time, so the run also yields our latency on our schema and network. This number picks the live model.

**Retrieved corrections are not model quality.** Scoring the holdout with past corrections in the prompt is testing with the answer key in the room; a same-family near-duplicate leaks as surely as the case itself. Retrieval is never part of the floor. If measured at all, it is measured as the deployed system, on families disjoint from everything it can retrieve, under its own heading.

**Retrieval is bounded and temporary.** At most three exemplars, only on a fingerprint or family match; most calls retrieve nothing. A recurring correction means the rule or catalogue is wrong, not that the model needs reminding. The brand-in-a-review mistake is a rule about where a sender claim may live: the display name and from-line, not the body. When the rule lands, the exemplar retires.

**Ruled out.** Fine-tuning on the correction log before bare agreement, label volume, and a re-validation plan justify it. Any column blending bare and retrieved results. Any exemplar that outlives the rule it was waiting for.
