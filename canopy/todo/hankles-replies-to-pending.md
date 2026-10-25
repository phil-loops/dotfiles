+++
title = "Turn on sending replies to john-hankles threads into my pending GitHub review"
kind = "decide"
state = "waiting"
area = "review"
size = "S"
why = "review replies land on GitHub without retyping them there, while still nothing posts until I press Submit"
waiting = "john-hankles's next review on one of Phil's PRs, for the first real reply-joins-pending check"
links = ["wiki/loops/canopy-v2-review.md", "memory:project_canopy-v2.md", "b1a8621"]
created = "2026-10-25"
updated = "2026-10-25"
+++

The review page's GitHub writer (`srv/ghreview.py`) can only create/add to Phil's PENDING review; real sends stay off until `git config stack.viewer-github-pending true`.
`ghreview.scope_refusal` already limits real sends to replies on threads john-hankles opened (b1a8621).
Before flipping: one real check with Phil that a reply lands inside his pending review on github.com. No open hankles thread on his PRs on 2026-10-23, so the check waits for the bot's next review.
