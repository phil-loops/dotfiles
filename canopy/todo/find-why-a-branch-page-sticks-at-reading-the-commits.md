+++
title = "Find why a branch page sticks at 'reading the commits…'"
kind = "look"
state = "open"
area = "review"
size = "S"
why = "cite-the-openai-checks-activity's page stayed on 'reading the commits…' this afternoon, after 5d0f0a64's history-read fix landed"
created = "2026-11-17"
updated = "2026-11-17"
+++

Seen 2026-11-17 afternoon on cite-the-openai-checks-activity: the branch page stayed at "reading the commits…". `keep-branch-history-reads-truthful-through-failure-and-navigation` (done, 9940c996 + 5d0f0a64, landed 05:39) was meant to make this impossible — loading, failure and empty are explicit, with a retry command. Show was relaunched at 15:04, so check whether the sighting predates the relaunch.

## Next steps
1. Reproduce on that branch with the current Show build; note whether `:review.commits.retry` is offered.
2. If it reproduces: capture `/branch-history` (or whatever the reader calls) for that branch and see whether the answer never arrives, arrives for a different source, or is fenced as stale.
3. File the cause as a fix with its own regression test.
