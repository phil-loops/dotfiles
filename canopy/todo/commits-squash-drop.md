+++
title = "Squash or drop unpushed commits from the commit list"
kind = "build"
state = "open"
area = "review"
size = "M"
why = "reshape a branch's history where its messages are edited, without a terminal"
links = ["scripts/srv/outline.py"]
created = "2026-10-25"
updated = "2026-10-25"
+++

Follow-up to the v2 message editor (words.save). Unlike rewording, squashing or dropping changes trees: the gates verdict (keyed by tree) goes stale, viewed change blocks can shift, descendants need a real rebase that can conflict, and v1's /squash is a different operation with its own failure modes. Wants its own commands (adjacent-pair squash, drop with a confirm), the same guarded head check, and undo via the reflog.
