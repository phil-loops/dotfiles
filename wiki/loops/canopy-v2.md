---
title: Canopy v2 — a frontend that feels instant
section: Canopy v2
order: 50
project: canopy-v2
lede: A ground-up rewrite of the viewer's frontend. Same server, same data; a new client built to be instant, ergonomic and a joy to use — and to measure itself, so we always know where the next improvement is.
---

**Why rewrite.** The frontend grew by accretion to 15,400 lines in 87 files. The server is fast — warm reads take 0.1–0.2 s — but the client makes it feel slow and clunky:

- every action waits on the server, then refetches;
- every page assembles itself from 6–12 separate requests;
- the same job happens in different places with different keys.

Patching that is what the last two days were, and it still doesn't delight. [[canopy-v2-diagnosis]] has the measurements.

**Three goals, each measurable:**

1. **Instant.** Every action shows its result within one frame; navigation paints in under 100 ms. Nothing waits on the network.
2. **Ergonomic.** One command model: every action has a name, a key, and a place in the palette; each job lives in one place.
3. **Joyful.** Calm by default, crafted motion, satisfying moments. The vellum and gold identity stays.

**The pages:**

- [[canopy-v2-architecture]] — one local store kept current by server-pushed changes; optimistic commands.
- [[canopy-v2-interaction]] — commands, keys, the palette, and the three surfaces.
- [[canopy-v2-joy]] — what makes it feel good.
- [[canopy-v2-measure]] — event tracking, latency budgets, and the dashboard that tells us where to focus.
- [[canopy-v2-plan]] — built alongside the current app, surface by surface; open questions.
