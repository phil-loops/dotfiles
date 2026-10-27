+++
title = "Bring the sync motion and its repairs to the v2 branch page"
kind = "build"
state = "done"
area = "review"
size = "S"
why = "prep, delta tests, dirty-tree decisions, reseat, rebase and restack are the everyday make-it-pushable path, and only v1 had them (/prep-push 41, /delta-tests 35, /dirty-resolve 10 uses in 60 days)"
created = "2026-10-27"
updated = "2026-10-27"
+++

## Next steps
Core landed 2026-10-27 (ed63e9b). Force-origin landed with the branch extras (f750baf); freeze dropped (1bf90a1).
Left, small:
1. After a seal, move to the commit words (e) the way v1 did.
2. Let the dirt list expand each file to its diff.
