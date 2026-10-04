---
title: What a support engineer can do with a hold
section: Content safety
order: 62
project: safety-viewer
lede: Two questions per message: did the model read it right, and is the hold right. Reasons for a release are the labels.
---

Part of [[content-safety-m4-viewer]]. The queue is the labeling tool; the screen asks two things.

**Did the model read it right?** Three lines under the evidence, each with the words it cited. Three kinds of feedback, one gesture each:

- **Right.** Nothing to do.
- **Wrong.** Click *wrong*, set the value, optionally select the real words. The rules run again at once.
- **Missed.** Select the words in the evidence; a popover asks what they are: a sender claim, a data request, a payment, a new destination, or something no line covers. The first four fix the line; the last names a rule, or none, with a note.

None of this resolves the message; a corrected reading can still be blocked.

**Is the hold right?** Release, block, or can't tell. When nothing fires after a correction, release needs no reason. Otherwise release asks why, offering only what applies: this team sends for that entity; this rule should not apply to this team, with scope and expiry; or just this once, with a reason from a closed list and a note for other.

**Block** asks the kind, and whether to suspend the team. **Can't tell** leaves it held with a note and a fraud assessment of unknown.

**Disagreement is not a button.** A release against a hold is the disagreement, counted per rule with the waivers; past a threshold the rule drops from reject to hold. A template family across many teams is one item.

Every gesture writes a row, listed under the reading until the verdict.
