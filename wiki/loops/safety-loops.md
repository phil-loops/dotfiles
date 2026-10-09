---
title: Safety loops
section: Safety loops
order: 100
project: phishtank-v4
lede: A policy turns recorded evidence into a decision, always the same way. Everything else exists to make that evidence and that policy better.
---

**The core rules.** A policy is a pure function: the same evidence and the same knowledge cutoff always produce the same decision. Evidence is recorded once and never edited, so any policy can replay any past check.

A review is a judgment and, when something was wrong or missing, a diagnosis. The judgment is the only gold a policy is fitted and graded against. The diagnosis changes only the faulty input (a reading, a fact or an unobserved reason); no review edits a policy directly.

**The pieces.**

- An *email* is one revision of an EmailMessage, read as LMX *elements*.
- A *facet* asks one narrow question; an *observation* is what it found. *Trusted information* is what is on file as legitimate for a sender.
- A *policy* has two parts. A *verdict*, whether the email should be sent, is fitted to judgments. A hand-written *response* table maps the verdict and the check's context (touchpoint, sender stage, mail type) to actions: allow, hold, reject, warn, alert or disable.
- A *judgment* is a reviewer's send-or-block answer; a *diagnosis* is what they say was wrong or missing.

**Two words that must not blur.** A *disagreement* is a reviewer's judgment differing from a policy's decision. A *difference* is two policies deciding the same check differently. Disagreements teach; differences pick what to review.

**Three lanes.** The fast lane decides at publish and send. The slow lane records, reviews, fits and replays. Production is the only live policy; candidates run offline, then in shadow before promotion.

See [[safety-loops-facets]], [[safety-loops-flywheel]], [[safety-loops-review]], [[safety-loops-mvp]] and [[safety-loops-data]].
