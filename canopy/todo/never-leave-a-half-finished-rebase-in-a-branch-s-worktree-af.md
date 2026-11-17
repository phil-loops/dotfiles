+++
title = "Never leave a half-finished rebase in a branch's worktree after sync"
kind = "fix"
state = "open"
area = "forests"
size = "M"
why = "twice today sync left rebase-merge + detached HEAD behind, so the branch read 'used by worktree' and couldn't be moved"
created = "2026-11-17"
updated = "2026-11-17"
+++

Seen 2026-11-17 (twice): after canopy's sync, the branch's worktree held a `rebase-merge` dir and a detached HEAD. The branch then showed "used by worktree" and nothing could move it until the rebase was aborted by hand.

## Next steps
1. Find the sync path that rebases without an abort-on-failure (server `/sync`, viewer lane) — a conflict or a killed process must end in `git rebase --abort`, never a parked rebase.
2. sync's preflight: refuse (and say so) when the worktree already has `rebase-merge`/`rebase-apply`, rather than stacking another operation on it.
3. Regression test in the server's sync tests: a rebase that conflicts leaves no `rebase-merge` dir and the branch at its old tip.
