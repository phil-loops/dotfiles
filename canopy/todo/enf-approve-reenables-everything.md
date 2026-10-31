+++
title = "Approve re-enables only when nothing else holds the domain"
kind = "fix"
state = "open"
area = "admin"
project = "loops:domain-enforcement"
size = "M"
why = "approving one flagged email re-enables a domain blocked for something else — live bug (kernel 2)"
blocked_by = ["enf-restrictions-on-every-disable"]
links = ["show/enforcement-design.json"]
created = "2026-10-31"
updated = "2026-10-31"
+++
