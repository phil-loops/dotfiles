---
title: Milestones
section: Safety loops
order: 140
project: phishtank-v4
lede: Production first runs on policy v0, a refactor nothing customers see; every later step goes through that one seam.
---
**Stages.**

1. **Spike** (`phishtank-v4`, `safety-spike`). Production imports the package and swaps two rules in place: the classifier tag rule and the banned-word match. Control flow unchanged.
2. **Production runs on v0** (`safety-v0`). Characterisation tests pin every touchpoint; every touchpoint goes gather, v0 `decide`, act, record. The app keeps only how to act; sender history is read only when v0 acts on the sender; every decision is recorded with its inputs and the ban-list hash. Exit: the pinned tests pass at every touchpoint and every check is recorded.
3. **Sender cleanup.** v0's new-sender rule (fewer than 5,000 delivered, or a domain under 7 days old) is the only copy of the cutoff, and the email-health cron asks it too; the count is asked directly ("has delivered at least 5,000") as of the check; disabling or alerting is one app action both callers use. The cutoff is arbitrary, so it stays a plain constant.
4. **Record what a better policy needs** (`readings-shadow`, `phishtank-facets`, `content-fingerprints`). Exit: readings and code facets recorded for every publish-time check, within the cost budget.
5. **Measure production offline** (`parity-replay`). v0 replayed over recorded checks gives the baseline.
6. **First fitted candidate**, compared offline with v0 on held-out mail. Needs labelled outcomes. Exit: beats v0.
7. **Live window and promotion** for one touchpoint, exit conditions written first: no confirmed harmful email newly allowed, wrongly blocked mail within tolerance, no errors or latency problems. Switching and rollback are settings.
8. **Reviewer tools**: the inspector and the review desk.

**History.** The offline replay reads stored checks by date range, after the last change to the check code (late June 2026). Each check is replayed against the ban list of its own time: the list production recorded with a match, else the admin ledger's last save before the check; checks older than the ledger aren't compared. Only records written within minutes of a check count as its own. Eval rows don't record their touchpoint, so a replayed match with no record is a preview check or a miss, and is reported as either. Models are never re-called: replay reads recordings.
