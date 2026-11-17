+++
title = "Name the broken link and offer the sync when a push is refused for a moved ancestor"
kind = "fix"
state = "open"
area = "push"
size = "S"
why = "'retry the push' was offered for a refusal no retry can fix, and the message was cut off before the branch that moved"
incarnation = "i_50c2a932e71b4129a001fd246f2f3420"
created = "2026-11-17"
updated = "2026-11-17"
+++

From Phil, 2026-11-17 15:47, on record-the-banned-word-activity-first: "retry the push p — record-the-banned-word-activity-first didn't push — history diverged from" (cut off). Three `POST /push-origin` refusals (15:45:41, 15:46:58) with `refused=history-diverged-from`.

## Cause
The push's chain ward (`push.py` `_chain_break`) found `origin/let-disable-take-a-suspicious-activity` (d5138e1, committed 15:36:53 by an agent and pushed 15:43:37) missing from this branch's history: the grandparent moved and was pushed, and neither `cite-the-openai-checks-activity` nor this branch was caught up. Retrying can never pass. The fix is to catch the chain up, parent first.

## Next steps
1. The refusal names its next step: `chain` refused → the button is "sync <the link> first" (or a restack of the chain), not "retry the push".
2. The message never truncates the branch name: put the moved branch first ("let-disable-… moved on origin — catch cite-… and this branch up"), or wrap.
3. Prevention (tooling-doctor): a commit pushed to a stacked branch flags its descendants as owing a catch-up, so the chain shows the debt before anyone presses push.
4. Test: a push refused by the chain ward routes `p` to the catch-up, never to a retry.
