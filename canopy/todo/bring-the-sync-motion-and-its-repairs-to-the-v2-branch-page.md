+++
title = "Bring the sync motion and its repairs to the v2 branch page"
kind = "build"
state = "open"
area = "v1-retire"
size = "L"
why = "prep, delta tests, dirty-tree decisions, reseat, rebase and restack are the everyday make-it-pushable path, and only v1 has them (/prep-push 41, /delta-tests 35, /dirty-resolve 10 uses in 60 days)"
created = "2026-10-27"
updated = "2026-10-27"
+++

## Next steps
Decided with Phil 2026-10-27:
- Sync gets its OWN key (`s` if free on the branch page, else the nearest free one); `p` stays gates → push only. The ship line shows "⟲ sync" when the branch needs it, beside the push state.
- Conflicts are handed to a Claude session (claude-say / a tmux Claude), not streamed inline; the ship line just says "conflict — with Claude".

Built 2026-10-27 (sandbox-verified end to end: rebase, restack, conflict, dirt stash/pop, reseat, WIP seal, reconcile, detach):
- [x] Server: /state's branch carries `behind` (one for-each-ref ahead-behind per ref move), `drifted` (from the graph), `upstream`/`upstreamBad`, `diverged`. `dirty` and `prepRoute` are NOT in /state — dirt needs a `status` per worktree and moves with no ref moving; the route walks commit bodies — so the branch page reads GET /sync and /prep-route per branch (memoised server-side) and re-reads on tab focus.
- [x] `s` = sync on Forests, the forest page and the branch page (branch.sync + review.sync, one SAME_MOVE). Machine swap moved to `space w` (`space s` is the review page's split toggle).
- [x] Ship line: "⟲ sync s" with the reasons in its title; "⟲ <step>…" while running; "conflict — with Claude" / "no mechanical route — with Claude" until the tip moves; "restack queued". Step strip under it with full notes, the dirt decision inline (fold / stash & continue / stop), × to put it away. Off the branch page the outcome is the quiet line.
- [x] Hand-offs use the server's existing paths: /sync ejects a headless Claude rebase into the branch's worktree; /reconcile opens a Claude session (now falls back to origin/<branch> when there's no upstream — the forest norm). No claude-say needed.
- [x] Repairs in the space menu only when they apply: reseat (drifted), detach upstream (tracks the trunk), inspect divergence (diverged with an upstream).

Left:
1. Force-origin and freeze repairs — left out (not trivial: force_scope's guard sheet + a confirm flow).
2. v1's "words" step (focus the outline column after a seal) — v2 has `e`; nothing hands off to it yet.
3. The dirt gate lists the files but not each one's uncommitted diff (v1 expands them; GET /sync already returns dirtyRows).
4. Inspect divergence needs an @{upstream} (/diverged-detail does); --no-track branches diverged from origin/<branch> get sync's reconcile but no inspect.
5. Retire v1's NodeActions sync path once v2's matches it on the dashboard.
