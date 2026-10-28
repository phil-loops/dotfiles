+++
title = "Move Wiki and Tutor onto v2"
kind = "build"
state = "done"
area = "v1-retire"
size = "L"
why = "Phil wants both kept; they are the last v1 pages besides Work, which retires"
created = "2026-10-27"
updated = "2026-10-27"
+++

## Done
2026-10-27 — Built 2026-10-27 (1b1dd3d wiki, 5a69e63 tutor, c51d328 finder + redirects). /wiki and /tutor 302 to v2; ?v1 bypasses. 2026-10-28 hardening (ce3dd51, 30bf297): C-c stop, reload re-attach and terminal pick-up exercised against live turns in the sandbox (isolated LEARNING_GRAPH); stop no longer reads as 'claude exited -9', a reload no longer drops the turn; /v2/tutor?import=<id>&say= picks a session up by link. Code pane types: space k / g d (cdcf9e7, 71ec1fa).
