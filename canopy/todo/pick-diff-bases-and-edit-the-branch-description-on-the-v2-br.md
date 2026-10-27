+++
title = "Pick diff bases and edit the branch description on the v2 branch page"
kind = "build"
state = "done"
area = "v1-retire"
size = "S"
why = "v1 (deleted 2026-10-27) diffed against parent, main, last-blessed or outgoing and edited the description; v2 does neither"
created = "2026-10-27"
updated = "2026-10-27"
+++

## Next steps
Design: wiki/loops/canopy-v2-branch-extras.md (decided 2026-10-27: space d diff base; force folded into p when eligible; freeze dropped).
1. Diff base (space d, ?base=, files-tab header).
2. Description field in the words tab + space e inline on forest rows.
3. Force-origin folded into p with the guard list.
4. Remove freeze (endpoint + sync/prep reads).

## Done
2026-10-27 — 110fd28 a1e49c6 f750baf ad753cd 1bf90a1 — space d diff base (p/m/o, ?base=), description field in the words + i on forest rows (space e was taken), force folded into p via new GET /force-scope with guards ✓/✗, freeze removed. Verified in viewer-sandbox (writes, undo, a real force-with-lease) and GET-only on 62497.
