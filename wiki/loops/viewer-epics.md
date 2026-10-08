---
title: Epics and milestones
section: Viewer
order: 20
project: viewer-epics
lede: An epic groups forest projects into ordered milestones with written exit criteria. Done is derived from merges; the criteria are text the viewer shows and never judges. A pinned epic collapses to one line.
---

Page shape and ordering: [[viewer-epics-order]].

`stack-project.<p>.epic` already exists and `picker.py` paints it fresh per serve
(`_OVERLAY_SUFFIXES`), so retagging never rebuilds. What was missing is stage structure,
ordering and a page.

## Config

```
stack-epic.<id>.title        one line
stack-epic.<id>.description  one verb-first line, same contract as a branch description
stack-epic.<id>.focus        1-based focus-lane rank (pinning collapses the card)
stack-epic.<id>.milestone    <mid>   ordered multivar — the order IS the stage order
stack-epic.<id>.<mid>.title  short name for the track ("refactor", "package")
stack-epic.<id>.<mid>.goal   one line
stack-epic.<id>.<mid>.exit   one assertion   (ordered multivar)
stack-project.<p>.milestone  <mid>
```

Verified against git: `stack-epic.<id>.<mid>.key` stores as section `stack-epic`, subsection
`<id>.<mid>` — so **one `git config --get-regexp '^stack-epic\.'` reads a whole epic**, the
only affordable shape against a 7,969-line config. Two constraints follow: **no dots in an
epic or milestone id** (`stack-epic.a.b.title` is ambiguous between epic `a.b` and epic `a`
milestone `b`), and ids stay lowercase, because subsections are case-sensitive.

Exit criteria are a multivar of one-liners, not a prose blob: append-friendly, each assertion
readable on its own, and no newlines in git config.

## State is derived, in one place

`/epics` returns **structure only** — ids, order, titles, goals, criteria, project assignment.
Live state (branches, gates, PRs, merged) is already on the `/projects` rows the client holds,
so the endpoint is one config sweep and never a fan-out; an epic page that opened its own build
would be another 16s endpoint ([[viewer-derived-state-measurements]]).

A milestone is **done when all its projects have merged**, derived client-side from those rows.
Exit criteria are displayed, never adjudicated — if ticking is ever wanted it is a palette
command writing config, not a button the page grows. One edge case has teeth: **a milestone
with no projects is `planned`, not vacuously done**, so M1 reads as current while
`safety-decision` is still being created.

**Current milestone** is the first in *declared* order that is not done — not the one with
activity. The order is the plan, and a stage jumped over is something to see.
