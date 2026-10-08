---
title: Epic and milestone ids
section: Viewer
order: 23
project: viewer-epics
lede: One config sweep reads a whole epic, which fixes the key shape and bans dots in an id. And milestone ids must be stable slugs, never ordinals — the plan gets renumbered, and an ordinal id makes that a multi-key rewrite with an inconsistent window.
---

Schema: [[viewer-epics]].

Verified against git: `stack-epic.<id>.<mid>.key` stores as section `stack-epic`, subsection
`<id>.<mid>`. So **one `git config --get-regexp '^stack-epic\.'` reads a whole epic** — the
only affordable shape against a 7,969-line config, where the per-key spawn floor is the entire
cost. Two constraints follow: **no dots in an epic or milestone id**, since
`stack-epic.a.b.title` is ambiguous between epic `a.b` and epic `a` milestone `b`; and ids stay
lowercase, because git subsections are case-sensitive.

**Milestone ids are stable slugs, never ordinals.** `m1`/`m2` is the obvious choice and the
wrong one. The ordered multivar already carries the order, so an ordinal id duplicates it, and
the duplicate then has to be rewritten whenever the plan moves.

The phishtank plan was renumbered twice inside one evening — M0–M4 became M1–M5, and then the
whole shape went back under rework. Under ordinal ids each renumber is a multi-key rewrite:
every `stack-epic.<id>.<mid>.*` key moves and every `stack-project.<p>.milestone` has to move
with it, and in between there is a window where assignments point at a milestone id that no
longer exists. That is the same transient-inconsistency shape that blinded the command palette
on 2026-10-07 — a reader that happened to sweep mid-rewrite saw a project with no home.

With slugs — `refactor`, `package`, `candidate`, `window`, `tools` — reordering edits one
multivar, renaming a stage edits one `title`, and no project assignment moves at all. An
inserted stage is one `--add`. The ordinal the UI shows ("M2") is then a render-time index into
the multivar, which is where a number that changes belongs.
