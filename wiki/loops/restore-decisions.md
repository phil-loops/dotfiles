---
title: 7 · Open decisions
section: Restore a deleted audience
order: 70
project: restore-mvp
lede: Six. Two change what gets built; four can be settled while building.
---

**Blocking — a superseded dump.** Guard (b) in [[restore-guards]] makes restoring an old dump correct but nearly silent: it restores almost nothing and reports zero. Is a silent zero right, or should the list refuse to offer a dump a later delete supersedes? It changes both the model and the UI, so it wants an answer before either is written.

**Blocking — one pass, or a budget.** The earlier line re-enqueued itself every twenty seconds; the rewrite dropped that on the theory that a free retry makes a single pass safe. Per page it is one SELECT and one UPDATE, so page count decides — and there is no measurement yet. This one needs a number off a real large team, not a judgement.

**A third counter.** A row can be neither restored nor skipped when someone already restored it. Lean: add `alreadyLive`; it costs nothing and makes a re-run legible.

**Aged-out dumps.** The objects expire on a window the app cannot see — no lifecycle rule lives in the repo. Lean: `headObject` on page zero when listing. One cheap call, tells the truth, no hard-coded number.

**A lock left by a hard kill.** The job releases in a `finally`, which a killed pod skips, so a dump can read "restoring" for an hour with nothing running. Lean: show the lock's age.

**Property drift.** Covered in [[restore-scope]]. Lean: accept the quiet degradation; note it in the summary rather than building a mechanism.
