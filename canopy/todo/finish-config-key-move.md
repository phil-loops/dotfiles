+++
title = "Finish the config-key move: stop writing, then stop reading, the old stack-branch keys"
kind = "build"
state = "open"
area = "config"
size = "M"
why = "deleted branches stop leaving config residue, and every reader loses a fallback arm"
links = ["memory:project_stack-config-namespace-migration.md", "memory:reference_stack-config-keys.md"]
rank = 17
created = "2026-10-25"
updated = "2026-10-25"
+++

Keystone ran 2026-09-13; loops has 0 disagreements and 0 legacy-only keys since 2026-09-23. Still dual-writing: `srv/stackcfg.py` and `scripts/stack-config-lib.zsh` both write `stack-branch.<b>.<k>`.
Order: (1) drop the legacy write arm in those two helpers; (2) drop the read arm (`RepoState.branch_key` + the `||` fallbacks in ~20 stack-* scripts); (3) move test fixtures and docs/skills off the old spelling.
Before (2): check other repos' `.git/config` (dotfiles, monotoad) were swept with `stack-config-move --check`.
