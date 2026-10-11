---
title: Milestones
section: Safety loops
order: 140
project: phishtank-v4
lede: Five milestones, starting with production running on policy v0: a refactor that changes nothing customers see and gives every later step one clean seam.
---
**Milestones.**

1. **Production runs on policy v0** (`safety-extract`, `safety-record`, `safety-route-publish`, `safety-route-send`). Characterisation tests pin every touchpoint; production's decision becomes the phishtank package's policy v0, a drop-in replacement with no second copy; the app keeps only how to act (flag rows, alerts, domain actions), and reads sender history only when v0 acts on the sender; the banned-word scan is the package's facet; every decision is recorded with its inputs and the list hash. Exit: the pinned tests pass at every touchpoint and every check is recorded.
2. **Introduce the phishtank package** (`phishtank-v4`, `phishtank-facets`, `readings-shadow`). Exit: readings and code facets recorded for every publish-time check, within the cost budget.
3. **First fitted candidate**, compared offline with production's real decision function. Exit: beats production on held-out mail.
4. **Live window and promotion** for one touchpoint, with exit conditions written before it opens: no confirmed harmful email newly allowed, wrongly blocked mail within tolerance, no errors or latency problems.
5. **Reviewer tools**: the inspector and the review desk.

**Why v0 first.** With one seam (gather, decide, act, record) and v0 as production's own function, switching to a new policy is a setting, rollback is a setting, and every comparison is against what production actually runs.

**History.** The offline replay (`parity-replay`) reads stored checks by date range, after the last change to the check code (late June 2026). Each check is replayed against the ban list of its own time: the list production recorded with a match, else the admin ledger's last save before the check; checks older than the ledger aren't compared. Only records written within minutes of a check count as its own. Eval rows don't record their touchpoint, so a replayed match with no record is a preview check or a miss, and is reported as either. Models are never re-called: replay reads recordings.
