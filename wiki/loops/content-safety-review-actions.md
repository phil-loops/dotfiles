---
title: What a support engineer can do with a hold
section: Content safety
order: 62
project: safety-viewer
lede: One question per message. The reasons for a release are the labels; "other" is allowed, carries a note, and is counted per rule.
---

Part of [[content-safety-m4-viewer]]. The queue is the labeling tool: support engineers label by doing their job, and the screen asks one thing.

**Is the hold right?** Release, block, or can't tell. Nothing else is on the screen until that is answered.

**Release asks why**, with choices built from the file, so only applicable ones appear:

1. **The model misread it.** Fix the wrong line; the rules run again and the release follows if nothing fires. The fix is an exemplar for similar messages.
2. **This team sends for that entity.** Only when the claim is unestablished. A representation on file.
3. **This rule should not apply to this team.** One per live rule, with scope and expiry. Waivers per rule are that rule's false-positive rate.
4. **Just this once.** Reason from a closed list: first-party flow, disclosed representation, known customer relationship, expected brand mention, rule too broad, other.

If a reason leaves the message held, the screen names the rule still holding it.

**Block asks what it is**: a subtype, and whether to suspend the team. **Can't tell** leaves it held with a note and a fraud assessment of unknown.

**Disagreement is not a button.** A release against a hold is the disagreement, counted per rule with the waivers; past a threshold the rule drops from reject to hold.

**Other** requires a sentence and is counted per rule; a climbing share mints a new code.

**Clusters.** A template family across many teams is one item; one verdict covers it.

Every answer writes label rows and an audit entry.
