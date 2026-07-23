---
title: 7 · Open decisions
section: Restore a deleted audience
order: 70
project: restore-mvp
lede: One still blocks. The rest have leans and can be settled while building.
---

**Blocking — a superseded dump.** Guard (b) in [[restore-guards]] makes restoring an old dump correct but nearly silent: it restores almost nothing and reports zero. Is a silent zero right, or should the list refuse to offer a dump a later delete supersedes? It changes both the model and the UI, so it wants an answer before either is written.

**A third counter.** A row can be neither restored nor skipped when someone already restored it. Lean: add `alreadyLive`; it costs nothing and makes a re-run legible.

**Aged-out dumps.** The objects expire on a window the app cannot see — no lifecycle rule lives in the repo. Lean: `headObject` on page zero when listing. One cheap call, tells the truth, no hard-coded number.

**A lock left by a hard kill.** A killed pod releases nothing, so a dump reads "restoring" until the hold lapses — fifteen minutes now that each pass renews it rather than one TTL covering the whole restore. Lean: show the hold's age.

**Property drift.** Covered in [[restore-scope]]. Lean: accept the quiet degradation; note it in the summary rather than building a mechanism.
