---
title: 7 · Open decisions
section: Restore a deleted audience
order: 70
project: restore-mvp
lede: Six. Two change what gets built; four can be settled while building.
---

**Blocking — a superseded dump.** Guard (b) in [[restore-guards]] makes restoring an old dump correct but nearly silent: it restores almost nothing and reports zero. Is a silent zero right, or should the list refuse to offer a dump a later delete supersedes? It changes both the model and the UI, so it wants an answer before either is written.

**SETTLED — budget, not one pass.** Measured (`bench/audience-restore`): a page costs rows × *contact properties*, and property count is unbounded. At 200 properties a 20k page takes 24.7s, so a million contacts is ~20 minutes — past the point where the one-hour lock expires underneath the running job. The budget's original rationale was wrong (the poller heartbeats SQS visibility every 20s, so nothing was ever going to redeliver a long job), but the conclusion stands for a different reason. `jobs/delete-team.ts` already drains this way.

The cursor is one integer: the paged dump means resuming is `fromPage`, not the row counter the old line kept.

**A third counter.** A row can be neither restored nor skipped when someone already restored it. Lean: add `alreadyLive`; it costs nothing and makes a re-run legible.

**Aged-out dumps.** The objects expire on a window the app cannot see — no lifecycle rule lives in the repo. Lean: `headObject` on page zero when listing. One cheap call, tells the truth, no hard-coded number.

**A lock left by a hard kill.** The job releases in a `finally`, which a killed pod skips, so a dump can read "restoring" for an hour with nothing running. Lean: show the lock's age.

**Property drift.** Covered in [[restore-scope]]. Lean: accept the quiet degradation; note it in the summary rather than building a mechanism.
