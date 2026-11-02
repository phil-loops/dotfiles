+++
title = "Rethink the review page's left column as a guide to the review, not a file list"
kind = "decide"
state = "open"
area = "review"
size = "M"
why = "Phil: the file column and its folded strip are 'a bunch of wasted space and frontend design needs help' — leaf names collide (queries/ vs models/ account-limit-notice.ts), it shows for any 2+ files even when the diff fits on one screen, and it repeats the file headers"
created = "2026-11-02"
updated = "2026-11-02"
+++

Phil turned down narrower fixes (full paths, hiding it on short diffs). He wants the space rethought.

Proposal from session wt-144142: the column becomes a guide to the review. It holds the branch description; a TO CHECK list (stack-review-flag entries, open threads, gates); a "you're in: file › enclosing function" line with progress. The full file list appears only on demand.

## Next steps
- Design round as a Show deck: what the column is for, a few ASCII layouts (guide / nothing until asked / overlay on demand), and what keys reach each part. Then Phil signs off.
- Keep ada487b's rule: whatever the column shows, it never changes the diff's width when focus moves (benched by canopy-benchwatch).
