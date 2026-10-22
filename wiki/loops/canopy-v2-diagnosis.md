---
title: What makes today's viewer feel slow
section: Canopy v2
order: 51
project: canopy-v2
lede: Measured 2026-10-22 on the live viewer. The server is not the problem; the client's shape is.
---

**The server is fast.** Warm reads: `/projects` 0.1 s, `/node` 0.2 s, `/outline` 0.1 s, `/outbox` 0.1 s. Only the first `/model` and `/push-preview` per branch are slow (2.5 s cold).

**The client's shape is the problem:**

- **Actions wait, then refetch.** Archiving a forest posted, waited, then refetched `/projects` before the row moved. Nearly every action works this way. (Archive is now optimistic as a stopgap.)
- **Pages are request waterfalls.** The branch page assembles itself from `/model`, `/node`, `/commits`, `/sync`, `/prep-route`, `/push-preview`, `/outline` and more — each with its own loading state.
- **Change notifications are blunt.** One server pulse invalidates about 13 query keys at once, so a single config write refetches half the app.
- **Accreted structure.** 15,400 lines; the largest files are the Tutor (1,248), the forest map (1,004) and the node actions menu (764). Keys mean different things on different pages.

**What usage says to keep** (four months of telemetry, `~/sweeps/viewer-redesign-2026-10-21/`):

- The core loop is: read a branch → fix the words → push. 73% of pushes follow a message save.
- Navigation is node → map → node (`m` pressed 1,348 times); the palette is a branch finder.
- Reading happens on branch pages (median 21 s); home pages are 3-second pass-throughs.
- `o` (open in Helix) was pressed 242 times — reading wants types, which v1 now has.

**What the telemetry can't yet say:** how long anything *feels* — there is no client-side timing of action-to-feedback or navigation-to-paint. [[canopy-v2-measure]] fixes that first.
