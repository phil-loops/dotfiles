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

Waiting comes in two kinds, and each has its own shape:

- **Can't act yet.** The key was pressed before its page could act (teammate J / K before the stack is read, space d before the findings are). It's a `local` that throws `Hold`: the runner keeps it, runs it when the page calls `releaseHeld`, and drops it on the next key, so it never yanks you somewhere after you've moved on.
- **Acting, but it takes time.** A keys reload, the forest merge check, a tutor pickup. It's a `task`: the runner awaits it and records ok, with the line it returns, only once it has finished; a throw is the refusal.

- **Held by:** the runner owns both outcomes (`Hold`/`releaseHeld`/`dropHeld`, and `task`). `RunnerTests` proves a task isn't ok while it runs.
- **Not held by the type:** Swift can't stop a `local` from starting a task of its own and returning. Today the only ones that do are the sync motion's start and its dirt decisions, which show their outcome step by step on the branch page and record each step's write. The shapes make the honest path the easy one; review still has to catch the other.
- **Evidence:** J / K and space d reported success before reading anything; the PR packet said "green for this exact tree" for a tree no gate ran on; telemetry lost undo pairs across restarts. A test asserted on "the next post" while the previous one was still in flight, and failed one run in three under load.

## 3 · Every fact has one owner

Refs and config live in the repo snapshot. Everything else derives from them, cached under a key that never changes meaning: a commit sha, a tree sha, a write generation.

- **Held by:** `repostate` owns refs, config, the trunk (`trunk()`, `diff_base()`) and trees by commit. `openprs` owns which PRs are open on origin and the fork, and what GitHub says about each. The client store owns entities; `/state` and its stream are the only way in.
- **Evidence:** two private tree caches, five copies of the trunk rule, a telemetry map outside the rollup it fed, a search memo keyed by text length, the CLI's packet deciding "green" with a different rule from the viewer's. Worst: three sweeps of GitHub's open-PR list, on 30, 60 and 90 second clocks, that could disagree about whether a PR existed.

**Friction, and the revision:**

- *External data has no identity.* GitHub's answers can't be keyed by a sha, so "a key that never changes meaning" can't hold for them. The rule for external data is one owner per listing, which reports its age and whether its last read failed. Readers needing different freshness ask the one owner with `fresh=True`; they never keep a copy.
- *One owner, two costs.* Mergeability and reviews cost GitHub 2.3 s against 0.5 s for the list. So the owner keeps two sweeps: the cheap one defines which PRs exist, and the costly one only decorates PRs the cheap one has.
- *Not every global is a fact.* The server has 119 mutable module globals. Most are constants, counters, or jobs in flight, not copies of facts. The test this rule needs asks each one to say which kind it is and what keys it, at the line that defines it. Not built yet.
- *Still more than one owner:* open PRs' bodies and threads (`packet`, `ghreview`) and every PR's state (`sync`, through `stack-forest`) are separate GitHub reads with their own caches.
