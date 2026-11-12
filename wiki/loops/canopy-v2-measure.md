---
title: Measure first — where to focus improvements
section: Canopy v2
order: 55
project: canopy-v2
lede: Built before any surface: every command and navigation is named and timed on the client, so a dashboard always shows what's slow, what's used, and what fails.
---

> **The client is native since 2026-10-29.** This page was written for the web client (`viewer-solid`, retired 2026-10-31); canopy is now the macOS app in `scripts/canopy-native/` (Show's ⌘1). The goals and invariants here stand; the keys live in `scripts/canopy-native/NAV.md`, and anything naming a `.tsx`/`.ts` file is history.

**Event tracking, keyed by command id.** Every command run records:

- id, scope, target and how it was invoked (key, click, palette, menu);
- the outcome (ok, refused with a reason, failed);
- the actor (Phil, Claude, the extension, headless), via the existing actor stamp.

Navigation records from and to, by surface. This replaces label-based tracking, so a copy change never splits a control's history.

**Latency, measured where it's felt.** For every command and navigation the client records:

- **feedback** — input to the first visible change (budget 16 ms);
- **settled** — input to server confirmation (budget 300 ms for config writes);
- **paint** — navigation to meaningful content (budget 100 ms).

Long tasks and layout shifts come from the browser's own performance APIs. The server adds its own timing per request (it already logs ms), joined by a request id.

**A dashboard in the viewer** (a Machine-page panel, or `viewer-usage-report --html`):

- the slowest commands and surfaces, at p50 and p95, against their budgets;
- the most used commands, and the ones never used — candidates to cut;
- refusal and failure rates per command;
- a weekly trend, so a regression shows up the week it lands.

**How it steers the work.** Each phase of [[canopy-v2-plan]] ends by reading the dashboard. The next phase starts with whatever is furthest over budget, weighted by how often it's used. Nothing ships without its events and timings wired.

**Kept from today:** the actor stamp, refusal logging, the 90-day request log, and the replay-tagged commit events from the instrumentation work.
