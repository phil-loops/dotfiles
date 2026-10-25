+++
title = "Keep a branch's green gates through a rebase that leaves its own changes unchanged"
kind = "build"
state = "open"
area = "gates"
size = "M"
why = "a main merge or catch-up stops relocking push and re-costing a typecheck on code that didn't change"
links = ["memory:project_push-gates-tree-keyed.md", "patches/gates-green-delta.patch"]
created = "2026-10-25"
updated = "2026-10-25"
+++

Phil, 2026-09-14: "the bytes of the delta should be sealed, not the commit". Today the verdict is keyed by tree, so every forward rebase relocks push.
Design (patch `~/.dotfiles/patches/gates-green-delta.patch`, no longer applies to push.py): also record `gates-green-delta` = hash of `git diff <parent>...<tip>` minus index lines with hunk offsets normalised; a `_verdict_stands(branch)` → tree|delta|"" replaces every tree-equality read (push cache, door ward, pregate, picker, sync). Context lines stay in the hash on purpose.
Never hand-write the gates-green keys for a real branch.
