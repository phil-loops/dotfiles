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

1. Server: add `dirty`, `drifted`, `behind`, `prepRoute` to v2's branch entity in `/state` + its patches (srv/state.py), computed from the same sources v1's /sync GET and /prep-route use. Fields only — no new mutation endpoints.
2. v2 `branch.sync` command (scope branch, own key): chain the existing endpoints in v1's order — /dirty-resolve decision (when dirty, ask fold/stash/stop), /reseat-children (drifted), /sync (behind; restack → /restack queue; conflict → hand to Claude), /prep-push, detached /gates, advisory /delta-tests. Step strip in review/Ship.tsx with full failure reasons.
3. Rare repairs (reseat, detach upstream, inspect divergence, force-origin, freeze) as space-menu commands available only when they apply.
4. Retire v1's NodeActions sync path once v2's matches it on the dashboard.
