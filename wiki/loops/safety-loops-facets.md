---
title: Facets
section: Safety loops
order: 110
project: phishtank-facets
lede: Pure functions over recorded input, returning plain named values, never verdicts.
---

**The contract.** Each facet module exports `name`, `version`, `observe` and `explain(values)`. Input is gathered by the app; the facet only interprets it. Values are facts or `unknown`. A facet's version covers its code and any data or weights it uses; a golden file of invented cases fails the build when outputs change without a version bump.

**Code facets.** Link destinations (registrable domain, text naming another domain, shorteners, IP and punycode hosts), reply-to (different domain, free mailbox), look-alike characters on sender name, from address and link hosts, content and destination fingerprints. Sender-site is about the sender, gathered at domain setup, not per email.

**Model readings.** One call per email returns narrow readings per element (what it asks for, which party it names and how, pressure, voice) and per email (purpose, topics, audience relationship, organisation identified, business fit, unsubscribe present). Evidence is element indexes, not quotes. The vocabulary lives in one rubric constant that builds the schema, the prompt and the reviewer's choices.

**Legacy facets.** Legacy tag reads production's recorded model answer the way production does; banned words reproduces production's substring scan. They give parity with today and stay as inputs.

**Fast versions.** Every model reading is recorded with its rubric version, so each is a training example for a local model that later replaces it, accepted only when it agrees with the model on unseen recent mail.
