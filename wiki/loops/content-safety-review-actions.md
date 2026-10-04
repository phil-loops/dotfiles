---
title: What a support engineer can do with a hold
section: Content safety
order: 62
project: safety-viewer
lede: Two questions per message: did the model read it right, and is the hold right. Reasons for a release are the labels.
---

Part of [[content-safety-m4-viewer]]. The screen asks two things, and its gate words say what they do: *waiting for review* (stopped before anyone received it; a person decides), *clear to send*, *stopped*.

**Did the model read it right?** Three lines under the evidence, each with the words it cited. One gesture per kind of feedback:

- **Right.** Nothing to do.
- **Wrong.** Click *wrong*, set the value, optionally select the real words. The rules run again at once.
- **Missed.** Select the words in the evidence; a popover asks what they are: a sender claim, a data request, a payment, a new destination, or something no line covers. The last names a rule, or none, with a note.

None of this resolves the message; a corrected reading can still be stopped.

**Should this go out?** Send it, stop it, or keep it waiting. When no rule stops it after a correction, sending needs no reason. Otherwise it asks why, offering only what applies: this team sends for that entity; this rule should not stop this team's mail, with scope and expiry; or just this once, with a closed-list reason.

**Stop it** asks the kind, and whether to suspend the team. **Keep it waiting** takes a note and records the fraud assessment as unknown.

**Disagreement is not a button.** Sending what a rule stopped is the disagreement, counted per rule with the waivers; past a threshold the rule drops from reject to hold. A template family across many teams is one item.

Every gesture writes a row, listed until the verdict.
