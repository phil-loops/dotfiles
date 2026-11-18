+++
title = "Recognize a GitHub-side rebase and offer to take origin's copy"
kind = "fix"
state = "open"
area = "push"
size = "S"
why = "after GitHub's 'Update branch (rebase)' rewrote PR #11628, canopy read it as a divergence, offered a catch-up commit on top, and blocked replace on the review bot's review"
incarnation = "i_8bbf3fd29d7c459bacc7efc5c3595bd6"
created = "2026-11-17"
updated = "2026-11-17"
+++

2026-11-17, record-the-banned-word-activity-first (PR #11628, draft): Phil pushed 1b9c741 at 16:05; at 16:11:07 GitHub force-pushed the PR head (`head_ref_force_pushed` by phil-loops; commits d0e462f, 1932686, db05c55 have committer `GitHub <noreply@github.com>`), i.e. the PR page's **Update branch → rebase**. canopy then showed "diverged from its PR · push · origin replacement unavailable · ✗ no one else's reviews · sync carries it on top".

## What's wrong
- The divergence is GitHub's own rewrite of the same patches onto a newer base. The right move is to take origin's copy (reset local to origin, re-apply any local-only commits), never a catch-up commit on top and never a replace. (Memory: published history is canon.)
- "No one else's reviews" counted john-hankles[bot]'s COMMENTED review as a person's.

## Next steps
1. `sync.py`/`push.py` divergence classification: when origin's new commits have committer `GitHub <noreply@github.com>` and the same patch-ids as local's (`git cherry`), classify as "GitHub rebased it" and route `s`/`p` to "take origin's copy (+ replay N local commits)".
2. Decide (Phil): does a bot's review (`[bot]` logins) block replacing origin? Its threads are line-anchored, so a replace orphans them; but it is not someone else's review in the sense the guard means.
3. Test: a fixture where origin was rewritten by GitHub with identical patches routes to take-origin, and a bot-only review doesn't count as someone else's.
