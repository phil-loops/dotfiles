---
title: Safety loops
section: Safety loops
order: 100
project: phishtank-v4
lede: A policy turns recorded evidence into a decision, always the same way. Everything else exists to make that evidence and that policy better.
---

**The core rules.** A policy is a pure function: the same evidence and the same knowledge cutoff always produce the same decision. Evidence is recorded once and never edited, so any policy can replay any past check.

A review is a judgment and, when something was wrong or missing, a diagnosis. The judgment is the only gold a policy is fitted and graded against. The diagnosis names the faulty input, a reading, a fact or an unobserved reason, and changes only that input; no review edits a policy directly.

**The pieces.**

- An *email* is one revision of an EmailMessage, read as *elements* in LMX vocabulary.
- A *facet* asks one narrow question. Code facets compute facts; the model-readings facet reads for meaning in one call per email.
- An *observation* is what a facet found. *Trusted information* is what is on file as legitimate for a sender.
- A *policy* weighs observations and decides. Policies are fitted to judgments, never hand-weighted.
- A *judgment* is a reviewer's send-or-block answer; a *diagnosis* is what they say was wrong or missing.

**Two words that must not blur.** A *disagreement* is a reviewer's judgment differing from a policy's decision. A *difference* is two policies deciding the same check differently. Disagreements teach; differences pick what to review.

**Three lanes.** The fast lane decides at publish and at send, with no model call once readings are cached. The slow lane records, reviews, fits and replays. Production is the only live policy; candidates run offline, then in shadow before promotion.

See [[safety-loops-facets]], [[safety-loops-flywheel]], [[safety-loops-review]], [[safety-loops-mvp]] and [[safety-loops-data]].
