---
title: Data and models
section: Safety loops
order: 150
project: phishtank-facets
lede: Real mail stays with Codex or production jobs. Invented mail, written by several authors, builds and tests everything else.
---

**The boundary.** Claude never sees production email content. Codex reads real mail privately and returns only categories and coarse bands, through a mailbox: numbered notes in `~/.codex-private/handoff/to-codex/`, replies and a status log in `from-codex/`.

**Invented corpora.** Codex writes abstract pattern cards from real mail; a headless generator turns cards into labelled emails without seeing real mail, with a JSON Schema so output cannot slip. Separate sets from Claude, Fable and Opus give cross-writer tests: a model trained on one writer and scored on another is the honest check. Labels follow the current rubric; each email records whether each label comes from the element's own words or its neighbours.

**What the evidence says so far.** On invented mail, large models labelled credential requests at 88 to 97% precision with near-complete recall from a one-page rule. A fine-tuned small multilingual model reached about 79% and missed real lures when its training set lacked them. Real mail is far sparser: credential requests are under 1% of elements, so false-flag rates dominate and no single facet should decide.

**Speed.** Fine-tuning with the vocabulary table frozen, pre-tokenised, length-bucketed half-precision batches takes minutes on a laptop. Serving runs in tens of milliseconds per email, cached by content.

**Vocabulary.** Codex checked the rubric against real mail and proposed a revision; a slimmed version is planned for the readings facet.
