---
title: What the data says, and can't
section: Viewer redesign
order: 41
project: viewer-redesign
lede: Strong on what Phil does in the browser and where PR time goes. Blind to what Claude does through the server, and to whether anything made code better.
---

**High confidence**

- Message edit then push is the viewer's core loop: 365 header-editor saves, 89% followed by a push (median 9 s).
- Two-thirds of branches can't have a message edited in the viewer at all (185 of 283), because of UI gates `stack-reword` doesn't need.
- Edits mostly delete generated body text (median 174 → 51 chars) that never reaches main.
- Claude authors 97% of commits; Phil effectively never commits by hand.
- PR size fell 88 → 56 lines and first review came faster (1.7 → 0.8 h). Time to merge did not move.
- Contract fails 43% of the time it's clicked; checkout drew 40 rapid retries before falling out of use.

**Medium**

- Throughput rose 10 → 14 PRs a week, but the whole team rose 25–60%. Reviews given doubled (12 → 23 a week).
- Viewer intensity tracks weekly output (ρ ≈ 0.55), which mostly means "was working that week".

**Can't tell**

- Quality: there were zero reverts before or after.
- Causality: viewer, gates, skills, Claude-heavy coding and the team surge arrived within three weeks.
- Agent work: Claude's calls to the server never reach the usage log.

**Instrumentation holes to fix before the next read**

- Map clicks are untracked (they're 71% of navigation).
- `{ok:false}` refusals are logged as success.
- The push hook went silent on 08-19.
- Rebase replays duplicate 442 commit events.
- The request log keeps only seven days, 83% of it extension polling.
- No call says who made it: Phil, Claude, or the extension.
