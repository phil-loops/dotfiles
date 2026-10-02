---
title: Invariants of the loop
section: Content safety
order: 15
project: safety-shadow
lede: Eleven properties of the live path, the labels, and the operations around the decision. Each has an enforcer.
---

Part of [[content-safety-epic]]. The decision path's own twelve: [[content-safety-invariants]].

**Cost and the live path**
13. The model runs only at send-intent, and identical content is checked once. A counter on cache misses.
14. Reasoning is off on the synchronous path, output is bounded, and budget exhaustion degrades to `unknown`, never to a silent allow.

**Labels and evaluation**
15. A label is a judgment on evidence, not an operational decision. An override never writes one on its own.
16. The floor is measured bare; retrieval never enters it ([[content-safety-measure-bare]]). The replay script has no retrieval path.
17. The holdout is split by team and template family, and nothing that tunes a prompt, rule, or threshold reads it. The split is assigned when the label is written.
18. Inter-rater agreement is the ceiling. The rubric is versioned; every label carries reviewer, mode, and version ([[content-safety-ground-truth]]).
19. No operation moves to enforce while its hold backlog is growing.

**Storage and operations**
20. Durable state lives in the safety database, owned by `safety-pg`, never in the application schema. Valkey holds only projections rebuildable from rows.
21. Evidence has a retention window, and tokens are redacted before storage.
22. Shadow always writes and never gates. Every cutover is a config row with a way back.
23. A prompt change and a rule change never share a PR.

Most likely to erode: 16 and 17. Each is a shortcut that looks harmless the first time.
