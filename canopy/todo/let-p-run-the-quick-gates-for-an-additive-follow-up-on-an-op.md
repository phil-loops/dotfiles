+++
title = "Let p run the quick gates for an additive follow-up on an open PR"
kind = "fix"
state = "open"
area = "gates"
size = "S"
why = "each 1–2 commit Hankles fix on an open PR runs the full ~3-minute gate set although CI runs typecheck and lint on the push; push-ready already says to use quick there"
incarnation = "i_37f8ceb876224a1083eb1623b1a55b58"
created = "2026-11-17"
updated = "2026-11-17"
+++

From Phil via the disable-evidence session, 2026-11-17: "that's a lot of machinery just to push." `p` on a branch with an open PR routes to `branch.gates.run` (full: env, fresh, typecheck ~1.5 min, format, lint, tests), plus queueing. `branch.gates.quick` exists and the strip offers a separate "quick" button (`ShipStripView.swift`, shown when the route is gates.run and a PR exists), but `p` never picks it.

## Next steps
1. `BranchCommands.pushRoute`: open PR on origin + the push is additive (origin's head is an ancestor of the tip, no restack) → `branch.gates.quick`; a first push, a restack, a replace → full.
2. The strip says which tier `p` will run ("p · quick gates — CI runs typecheck and lint").
3. Pair with tooling-doctor step 5 (changed-file oxlint on commit), so the lint quick skips is still caught locally in seconds, as consistent-type-imports was today.
4. Test on pushRoute: open PR + additive → quick; restacked → full; no PR → full.
