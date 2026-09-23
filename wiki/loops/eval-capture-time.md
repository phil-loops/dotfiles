---
title: Capture time is not fact time
section: Email safety evaluation
order: 36
project: eval-findings
ask: packages/safety-eval/src/safety-context.ts#asKnownAt
lede: "We fetched this today" does not establish when it became true.
---

The detector is given context beyond the email itself: which domains the team has verified, which brands it is authorised to send as. That context is a snapshot, and a snapshot knows when it was *fetched* — not when each fact inside it became true.

A domain verified today may not have been verified when the email was sent. A team active then may be disabled now. Asking a recent snapshot about an earlier moment and taking its answer at face value invents history.

So a snapshot asked about an earlier moment does not get to vouch for what was true then. Claims it cannot stand behind come back as **unknown** rather than as confident falsehoods — unless the claim carries its own effective date, in which case that date decides and the claim survives.

Unknown is a worse input than a fact and a far better input than a wrong fact. The rules already treat unknown as unknown rather than as false, so this degrades honestly instead of quietly flipping conclusions.

This is a first step, not the finished idea. Provenance currently lives on the snapshot as a whole — "this came from these tables at this time" — and not on each claim within it. Per-claim provenance is listed among the [[eval-open-questions]].
