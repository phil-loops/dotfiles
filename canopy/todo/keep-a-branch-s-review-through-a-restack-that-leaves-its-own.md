+++
title = "Keep a branch's review through a restack that leaves its own changes unchanged"
kind = "build"
state = "done"
area = "review"
size = "S"
why = "a fix low in a stack drops every descendant's review even when its own diff is byte-identical, so each one pays a fresh model run (2026-11-15: 8-branch forest, three full review rounds)"
created = "2026-11-15"
updated = "2026-11-15"
+++

Gates already seal the delta (`gates-survive-rebase`: `verdict_stands` returns "delta" when `_delta_id` matches). Reviews are tree-only: `review-flags-tree` must equal the tip's tree.

The reviewer reads `parent...branch` — exactly the delta — so a forward restack under it changes nothing the review looked at. Proposal: `POST /review` records `review-flags-delta` beside `review-flags-tree`, and the readers ask one `review_stands()` returning "tree" | "delta" | "", mirroring `verdict_stands`.

**Needs Phil's call before building**: this changes what "reviewed" means (the verdict-key rule's territory). Counter-case to weigh: a review that judged code against its parent's API — a parent change can make a byte-identical delta wrong. Gates catch that through typecheck on the new base; a delta-sealed review would not re-read it.

## Done
2026-11-15 — verdicts.review_stands + review-flags-delta recorded from the run's start; harvest crosses a forward rebase; POST /review answers cached while it stands; guard covers the new key; scripts/test-review-verdict-delta.py
