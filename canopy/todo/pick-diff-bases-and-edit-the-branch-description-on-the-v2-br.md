+++
title = "Pick diff bases and edit the branch description on the v2 branch page"
kind = "decide"
state = "open"
area = "v1-retire"
size = "S"
why = "v1 (deleted 2026-10-27) diffed against parent, main, last-blessed or outgoing and edited the description; v2 does neither"
created = "2026-10-27"
updated = "2026-10-27"
+++

## Next steps
Phil 2026-10-27: diff bases, the description editor, force-origin and freeze need a fleshed-out design before building — not a straight port. Design first.

v1 is gone (2026-10-27, fd75d07 and before): there is nothing to port from or fall back to — these four get designed and built fresh in v2. Last-blessed is not one of the bases any more (bless was removed; v2's `viewed` marks are the review-progress signal). What survives server-side to build on: `/node?branch=&base=` (any explicit base), `/outline` (saves the description with the outline), `POST /force-origin` and `POST /frozen-origin` (kept for this item; no v2 caller yet).
