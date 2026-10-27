+++
title = "Focus sync: an open-PR base shouldn't freeze the whole forest"
kind = "fix"
state = "open"
area = "sync"
size = "S"
why = "#11228 merged but record-every-domain-disable was skipped wholesale ('its base has an open PR' = #11196), so the merged node wasn't contracted and its child (fan-in over the merged node + record-team-deletion-disables) wasn't re-chained. Skip only the open-PR subtree; contract + restack the rest. Also no manual 'sync now' key in the viewer."
created = "2026-10-27"
updated = "2026-10-27"
+++
