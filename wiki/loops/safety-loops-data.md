---
title: Data and models
section: Safety loops
order: 150
project: phishtank-facets
lede: Real mail stays with Codex or production jobs. Invented mail, written by several authors, builds and tests everything else.
---

**The boundary.** Claude never sees production email content. Codex reads real mail privately and returns only categories and coarse bands, through a mailbox: numbered notes in `~/.codex-private/handoff/to-codex/`, replies and a status log in `from-codex/`.

**Invented corpora.** Codex writes abstract pattern cards from real mail; a headless generator turns cards into labelled emails without seeing real mail, with a JSON Schema so output cannot slip. Separate sets from Claude, Fable and Opus give cross-writer tests: a model trained on one writer and scored on another is the honest check. Labels follow the current rubric; each email records whether each label comes from the element's own words or its neighbours.

**What the evidence says so far.** Rule v3 gives each label one test question. On real mail the v3 student keeps credential recall but flags too much, and rare labels are too sparse to measure; seed noise swamps gains under 0.05. Teacher-labelled real mail is the next lever, not a bigger model. e5-base is the starting student.

**Serving.** A stateless Python service in the Helm chart scores a content revision; Node gathers, calls it and writes observations, so packing and tokenising stay identical to training. In shadow only an async job calls it. After promotion, publish uses the revision's cached reading, else awaits about two seconds, else follows the policy's fallback; never allow because the observer was down. Per-send paths never wait.
