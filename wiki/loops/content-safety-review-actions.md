---
title: What a support engineer can do with a hold
section: Content safety
order: 62
project: safety-viewer
lede: Four actions, each a row; "other" is allowed, carries a note, and is counted per rule.
---

Part of [[content-safety-m4-viewer]]. The queue is the labeling tool. Support engineers label by doing their job.

**Four actions on a held or rejected message.**

1. **Correct an observation.** The model misread the claim, the request, or the payment. Fix the field; the system re-evaluates; if the rule no longer fires, the release follows. The correction is the reason, and it moves the extractor's accuracy number.
2. **Record a relationship.** This agency sends for that client; this brand is theirs. A representation on file. The next send passes authorization untouched.
3. **Waive a rule.** Right in general, wrong for this team. Scope, rule, expiry. Waivers per rule are that rule's false-positive rate, measured for free.
4. **Release once.** Nothing to correct, record, or waive. The only action that needs a stated reason, from a closed list: first-party flow, disclosed representation, known customer relationship, expected brand mention, rule too broad, other.

**Confirming a block** is the mirror: verdict fraud with a subtype from a short list.

**Other.** Allowed, requires a sentence, counted per rule on the dashboard. When its share climbs for a rule, the notes are read and either a new code is minted or the UI nudges toward one of the first three actions next time.

**Scope picker, narrowest first.** This message. This rule for this team, with expiry. Every rule for this team, short expiry, required note, which is the old skip flag made honest. Widening is a deliberate click.

**Clusters.** A block across twelve teams on one template family is one queue item; one confirm or release covers the family.

Every action writes a label row and an audit entry.
