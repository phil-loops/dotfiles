+++
title = "Decide when replies to people and new threads may reach GitHub"
kind = "decide"
state = "open"
area = "review"
size = "S"
why = "the review page becomes the whole review, not just the bot half"
blocked_by = ["hankles-replies-to-pending"]
links = ["wiki/loops/canopy-v2-review.md", "memory:project_canopy-v2.md", "b1a8621"]
rank = 20
created = "2026-10-25"
updated = "2026-10-25"
+++

Today only replies on john-hankles threads can leave the machine; replies to teammates and new threads stay local drafts until `git config stack.viewer-github-scope all` (the sandbox already sets it).
Worth deciding only after the hankles-only rollout has run cleanly for a while.
