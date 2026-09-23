---
title: Open questions
section: Email safety evaluation
order: 50
project: eval-findings
ask: packages/safety-eval/src/feedback.ts#ruleSupport
lede: Decisions deliberately not made, two of which change what "earned" means.
---

Not TODOs. Places where the code makes a choice that looks technical and is actually a policy, where the other option is defensible. Written down so the choice gets made on purpose.

**One judged claim completes an answer.** A detector makes seven observations per email; judging one marks the whole answer done and the rest are never asked about. Tracking unjudged claims is more precise and materially more work per email. Related: an *uncertain* review also completes an email while contributing nothing decisive.

**Reviewer agreement ignores basis and revision**, so judgements overwrite each other by iteration order. Lower stakes only because nothing calls it yet.

**A policy reason with no rule.** *Prohibited business* is a real reason to stop mail and matches no rule, so the detector is not even trying to catch it. Attribution now refuses to leak such a stop into whichever content rule happened to fire — see [[eval-attribution]] — which makes the gap visible rather than fixing it.

Not built: support never reaches the running pipeline (see [[eval-gate-default]]), and provenance is per-snapshot rather than per-claim (see [[eval-capture-time]]).

Decided, not open: credit follows the reviewer's stated reason, and eligibility counts distinct emails.
