---
title: Facets
section: Safety loops
order: 110
project: phishtank-facets
lede: Pure functions over recorded input, returning plain named values, never verdicts.
---

**The contract.** A facet is a question: a name plus a rubric version that fixes what its values mean. Implementations answer it, each with `observe` and `explain(values)`; values are facts or `unknown`. Several can run at once, each recording its own observations, and policies pin one. A code facet changes by PR, guarded by a golden file; a retrained model is a registry row, gated on metrics and frozen rubric cases. Corrections attach to the rubric, so one grades every implementation.

**Code facets.** Link destinations (registrable domain, text naming another domain, shorteners, IP and punycode hosts), reply-to (different domain, free mailbox), look-alike characters on sender name, from address and link hosts, content and destination fingerprints. Sender-site is about the sender, gathered at domain setup, not per email.

**Model readings.** One call per email returns narrow readings per element (what it asks for, which party it names and how, pressure, voice) and per email (purpose, topics, audience relationship, organisation identified, business fit, unsubscribe present). Evidence is element indexes, not quotes. The vocabulary lives in one rubric constant that builds the schema, the prompt and the reviewer's choices.

**Legacy facets.** Legacy tag reads production's recorded model answer the way production does; banned words reproduces production's substring scan. They give parity with today and stay as inputs.

**Fast versions.** An LLM and a small model answering the same rubric are one facet: every LLM reading is a training example for the small one, which takes over only when it agrees on unseen recent mail.
