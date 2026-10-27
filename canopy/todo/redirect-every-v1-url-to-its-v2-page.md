+++
title = "Redirect every v1 URL to its v2 page"
kind = "build"
state = "done"
area = "v1-retire"
size = "M"
why = "stack-review-serve, hx-ship, the Chrome extension, swiftbar and the preview back-link all open v1 (2,339 v1 branch-page visits vs 170 on v2)"
blocked_by = ["bring-the-sync-motion-and-its-repairs-to-the-v2-branch-page", "decide-whether-bless-survives-next-to-v2-s-viewed-marks"]
created = "2026-10-27"
updated = "2026-10-27"
+++

## Done
2026-10-27 — 0fd4853 + 7d41425 — v1 URLs with a v2 page 302 to it (/, /forests[/<repo>]/<p>[/<b>], /branch, /review/N → review/pr-N, /machine, /outbox → /v2); ?v1 or stack.viewer-v1-redirect=false bypasses; producers emit v2; stack.viewer-v2-home retired
