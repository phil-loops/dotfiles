---
title: The epic card, two renderings
section: Viewer
order: 22
project: viewer-epics
lede: "Crisp, minimal, lovely and delightful. Not heavy. Not laden." The current card reads as a list of forests; it has to read as one effort with a current stage, and a pinned epic should stop explaining itself entirely.
---

Schema: [[viewer-epics]]. Ordering: [[viewer-epics-order]].

Phil's reaction to the existing cluster card was "this doesn't really feel like an epic" — five
equal rows in reverse creation order, no stage, no order, no sense that they are one thing.

**Expanded** reads as one effort with a current stage: the epic name, the current milestone's
short name, and a row of milestone dots — filled done, ringed current, hollow later. Then the
current milestone's projects as the **existing forest rows**, reused so gates, PRs and links
behave exactly as they do everywhere else, in merge order, with the first unmerged one quietly
marked next. Other milestones collapse to one line each, listing their projects in merge
order. Loose members sit quietly at the end, or come off the card entirely.

**Collapsed** is what a focus-pinned epic gets (`stack-epic.<id>.focus`): one line — name,
current milestone, dots — and no project rows at all. Pinning an epic is a statement that you
already know what it is; the card should stop explaining it.

**The forest page** gets a chip in the header, `phishtank · M2`, linking to the epic page.
Nothing else: the node header stays at two buttons and rails do not grow controls.

**Deliberately absent**, both renderings: dates, timelines, burndown, assignees, progress
percentages. It is a map of what merges in what order and why.

One thing the card drops today and must not: `ForestsList.tsx:86` skips a project that is
shelved, not committed-tier, focused, or recently merged, and needs two survivors — so a
parked or focused member silently leaves its epic. Defensible for the card, wrong for the
page, which shows every member.
