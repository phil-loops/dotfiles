---
title: Open questions
section: Email safety evaluation
order: 50
project: eval-findings
ask: packages/safety-eval/src/feedback.ts#ruleSupport
lede: Decisions deliberately not made, two of which change what "earned" means.
---

Not TODOs. Places where the code makes a choice that looks technical and is actually a policy, where the other option is defensible. Written down so the choice gets made on purpose.

**Any reason to stop validates every rule that fired.** Stop five emails for prohibited business, and an impersonation rule that happened to fire on the same five gets a perfect record and permission to block. The alternative — a stop counts only for rules the reviewer attributed it to — costs reviewer effort and slows activation, but is true.

**The threshold counts votes, not emails.** Five reviewers on one email clears the same bar as one reviewer on five. The first tells you reviewers agree; it says nothing about whether the rule generalises. Counting distinct emails, or requiring both, is the alternative.

**One judged claim completes an answer.** A detector makes seven observations per email; judging one marks the whole answer done and the rest are never asked about. Tracking unjudged claims is more precise and materially more work per email. Related: an *uncertain* review also completes an email while contributing nothing decisive.

**Reviewer agreement ignores basis and revision**, so judgements overwrite each other by iteration order. Lower stakes only because nothing calls it yet.

Not built: support never reaches the running pipeline (see [[eval-gate-default]]), and provenance is per-snapshot rather than per-claim (see [[eval-capture-time]]).
