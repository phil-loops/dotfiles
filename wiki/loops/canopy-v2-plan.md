---
title: Build plan and open questions
section: Canopy v2
order: 56
project: canopy-v2
lede: Built alongside the current app at /v2 on the same server, surface by surface, each switched to default once it beats the old one on the dashboard.
---

**Phase 0 — foundations (no visible UI).**

- the command registry, the event and latency tracking ([[canopy-v2-measure]]) and its dashboard;
- the store, `/state` and domain-diff events;
- the optimistic command runner;
- self-hosted fonts.

Done when the current app's top 20 commands are measured, giving a baseline.

**Phase 1 — Forests.** Focus, workbench, archive, inline branch spines, the ready filter (absorbing the outbox), `f`/`w`/`x`. Switch `/` to v2 when it beats v1 on paint and feedback.

**Phase 2 — Branch.** The reading column, words on `e`, types on `K`/`gd`, map and spine as overlays, the review packet. Switch branch routes.

**Phase 3 — the palette and the rest.** The universal palette; Tutor, Wiki and Machine reached through it. Delete v1.

Each phase ends with a read of the dashboard and a short note on what it changed.

**Ground rules.** v1 stays fully working until each switch. The server only gains endpoints; it never breaks v1's. Every phase is tested on `viewer-sandbox`, then read-only against the live repo.

**Open questions for Phil:**

1. Fold the outbox into Forests as a "ready" filter, or keep it as its own page?
2. Move Work, Wiki, Tutor and Machine off the rail and into the palette?
3. Keep Solid.js (recommended: it fits a live store), or move to React for familiarity?
4. Is a keyboard-first design with Helix-style keys right everywhere, or only on branch pages?
