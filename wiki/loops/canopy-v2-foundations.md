---
title: Foundations — three rules the structure enforces
section: Canopy v2
order: 50
project: canopy-v2
lede: Who may do what, whether an answer is true, and where each fact lives. Each rule is enforced by the code's shape, so breaking it fails a test or the server's start instead of waiting for a review to notice.
---

**Why.** The 2026-11-12 audit found twenty defects in one day's work. Every one broke a rule that existed only as a comment or a habit ("human finger only", "one source of truth"). A rule that nothing enforces holds until the next feature. So each rule below names the mechanism that holds it, and where that mechanism doesn't exist yet.

The goals on [[canopy-v2]] (instant, ergonomic, joyful) sit on top of these.

## 1 · Authority is declared, not commented

Every route says what it touches, and one dispatcher enforces it before the handler runs.

- **Effects:** `repo` (this repo's local state), `history` (moves a branch), `machine` (dev servers, the queue, windows, sessions the machine shares), `outward` (origin, GitHub). No effects means a read.
- **Who:** `outward` is always Phil's click in Show. Any route may also be marked click-only (process kills, the gates waiver). `machine` refuses in the sandbox.
- **Held by:** `scripts/srv/routes.py`, the one POST dispatcher. `scripts/test-routes.py` drives every route as Phil and as a session, in and out of the sandbox. A route can't exist outside the table, and an `outward` route can't be declared open.
- **Evidence:** in three weeks of the request log, Claude sessions called 25 POST routes legitimately (660 gates and review runs, previews, rename commits). Every call they made to a click-only route was refused.

**Friction, and the call made:**

- *Authority that depends on arguments.* A gates run is open, but skipping a gate or moving a run next is Phil's. Those checks stay in the handler, which is the only place that reads the arguments.
- *Reads with effects.* GET routes are reads by contract and aren't in the table yet. Two have effects: `/review-progress` records a finished review's verdict (idempotent, and only the server's own run), and `/preview-wait` boots a dev server. Moving all fifty GETs for two exceptions isn't worth it yet. The open question is whether a finished run should record its own verdict instead.

## 2 · Every answer is true when it's given

A command reports ok only once its effect has happened. Work it can't finish now is held or shown pending, never "ok". A claim names the evidence it rests on.

- **Held by:** the runner's hold (`Hold`, `releaseHeld`, `dropHeld`) for keys pressed before their data arrives. Teammate J / K and space d use it.
- **Not held yet:** a `local` command can still start a task and return, which the runner records as ok. Four commands do (keys reload, forest merge check, tutor pickup, sync); their pages show the result, so they're honest today, but the type doesn't stop the next one. The fix is a command shape whose outcome the runner owns.
- **Evidence:** J / K and space d reported success before reading anything; the PR packet said "green for this exact tree" for a tree no gate ran on; telemetry lost undo pairs across restarts.

## 3 · Every fact has one owner

Refs and config live in the repo snapshot. Everything else derives from them, cached under a key that never changes meaning: a commit sha, a tree sha, a write generation.

- **Held by:** `repostate` owns refs, config, the trunk (`trunk()`, `diff_base()`) and trees by commit. The client store owns entities; `/state` and its stream are the only way in.
- **Not held yet:** the server has 44 module-level caches. A test can import every module and fail on a mutable global that isn't registered with an owner and a key.
- **Evidence:** two private tree caches, five copies of the trunk rule, a telemetry map outside the rollup it fed, a search memo keyed by text length, and the CLI's packet deciding "green" with a different rule from the viewer's.
