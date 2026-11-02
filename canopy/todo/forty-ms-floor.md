+++
title = "Cut the ~40ms floor on the tutor pages and first overlay opens"
kind = "fix"
state = "open"
area = "perf"
size = "M"
why = "every key on /v2/tutor and the first :, ? or space b on a page take ~2.5 frames, not one"
created = "2026-11-02"
updated = "2026-11-02"
+++

## Next steps
- Profile one tutor j: what SwiftUI re-lays out beyond the cursor row.
- First overlay open: what is built on first appearance that a second open reuses.
