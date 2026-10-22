---
title: Viewer redesign — a shipping desk
section: Viewer redesign
order: 40
project: viewer-redesign
lede: Built 2026-10-21 (dotfiles a03a767 → 7255352) — the outbox home, the words column, the map overlay, the cuts and the instrumentation. The three bets are live as human-driven tools; `viewer-usage-report` measures them.
---

**What the viewer is, measured.** 73% of 305 viewer pushes follow a message save on the same branch within 30 minutes. Prep, gates and sync moved into `/push-ready` on 08-19 and now run from Claude, not the browser (171 of 175 gate runs last week). Reading happens on node pages; forest and home pages are 3-second pass-throughs; navigation is one loop, node → `m` → map → node (1,348 presses). Nineteen wired endpoints have never been used.

**Where the time goes, measured.** 75% of a PR's wall-clock is before it reaches GitHub. Forest PRs mostly open only after a sibling merges, so a four-node forest takes about a week. Review is not the bottleneck: changes are requested on about 2% of PRs. A PR opened after 15:00 PT takes 18.8 h to merge, against 3.2 h before.

**So the redesign has two jobs:**

1. Make the words-then-push ritual instant, with one honest model of which text lands — [[viewer-redesign-landing-text]].
2. Spend R&D on getting whole forests onto GitHub together, early in the day — [[viewer-redesign-rnd]].

Everything else shrinks to fit: [[viewer-redesign-surfaces]]. The numbers and their confidence: [[viewer-redesign-evidence]]. Raw reports and scripts: `~/sweeps/viewer-redesign-2026-10-21/`.
