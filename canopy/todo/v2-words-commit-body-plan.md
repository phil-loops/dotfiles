+++
title = "Flag a forest plan baked into a commit body in the v2 words view, with strip-it"
kind = "build"
state = "done"
area = "review"
size = "S"
why = "a commit body carrying the merge-order block shows on GitHub's commits tab and pre-fills a one-commit PR's description; v2 never says so"
links = ["scripts/viewer-solid/src/outlineHints.ts", "scripts/srv/outline.py"]
created = "2026-10-25"
updated = "2026-10-25"
+++

From loops-wt-122131 (2026-10-25): scope-assessment-event-to-team @44f5789ec0 has a 13-step "Part of a stack, in merge order:" block in its body, written by a session's plain `git commit` on Oct 21.
`outlineHints.ts` already has `hasPlan()` and the `stripPlan()` fix, but only v1's OutlineEditor calls them. v2's words overlay (`v2/review/Overlays.tsx`, `e`) shows commit subjects only — no bodies, no hints — and nothing flags it at push.
Cosmetic: the repo squash-merges with PR_TITLE/PR_BODY, so the body never reaches main.
Suggested: show the hasPlan hint in v2 words with strip-it (a registry command), reusing srv/outline.py's commit-tree reword for unpushed commits.

## Done
2026-10-25 — 122ee68 — bodies in e and on the forest page, plan hint + strip it (undoable)
