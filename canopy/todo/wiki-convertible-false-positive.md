+++
title = "Stop the wiki calling a design page convertible before its forest exists"
kind = "fix"
state = "open"
area = "wiki"
size = "S"
why = "the lint list only nags about pages whose work actually landed"
links = ["memory:project_viewer-foreign-forests.md", "memory:project_viewer-redesign-2026-10.md"]
created = "2026-10-25"
updated = "2026-10-25"
+++

`srv/wiki.py` lint flags `convertible` whenever a design page's `project:` isn't a live stack-project — which is also true before the forest is ever created (viewer-redesign, canopy-v2, foreign-forest pages).
It can't tell "landed" from "never started". Candidate signal: the project once existed (merge ledger / archived config) vs never did.
