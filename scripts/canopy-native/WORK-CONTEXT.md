# Work context

Canopy reads work status from the existing todo records. The home page's In progress pane shows items marked `doing`, across lists. Return opens the exact item on its list. Forest and branch context uses only explicitly linked items: `project` is the full `<repo>:<forest>` ID, and `solved_by` is the complete branch name.

In-progress work whose `solved_by` names a branch of a forest the home lists is shown on that forest's row instead: the branch's dot is ringed, and a line under the row names the branch, what the work is doing now (its first next step, else its why) and the session that claimed it. The home reads one line per forest (2026-11-18): its name, its purpose and its one next action; the chats on its branches are named once on that line (their evidence on hover), and a branch gets a line of its own only for its own work in progress. An in-progress row is its title and who holds it; its next step and latest direction are ↵ away. Chats on no branch are one quiet line that ↵ opens; a chat idle for two hours isn't counted or listed. `canopy-todo claim` records the checked-out branch as `solved_by` when it belongs to a forest and the item has none, for a viewer item or an item on that forest's own list. Work with no such branch keeps its line in the In progress pane.

An assignment is a reported claim, not a working-process heartbeat. `updated` is the tracker's recorded day, not the last code edit or tool call. Canopy keeps that precision and says when the date is absent. It does not infer activity from an open PR, a file modification time or a running process.

## Recording your input

The first section of an item's body can retain the latest input verbatim:

```markdown
## Your input

2026-11-17T18:00:00Z · chat

> Please keep the latest direction visible.
> Keep this second line too.

## Next steps

The agent's plan and progress go here.
```

The timestamp is when the input was recorded, in ISO 8601 format. Record chat instructions with source `chat`. Every line of the input is a blockquote, including blank lines. Use the actual recording time; do not invent the message's original send time. Preserve the user's words rather than replacing them with an agent summary. Review notes do not replace the latest chat instruction: a section with source `review` remains ordinary notes in the UI.

When a new instruction changes an item, replace this first section with that instruction and its recording time. Routine progress updates, `canopy-todo steps`, and completion notes preserve it. The reader does not mine prose, old summaries or arbitrary transcript files for purported input. Legacy or malformed bodies remain ordinary notes and say that input has not been recorded.

This recorded section is the legacy convention. It cannot prove complete message capture, safe concurrent updates or delivery of the newest instruction, and the UI labels it "not captured by the work journal".

## The work journal

Replies Phil sends in a Show deck section that declares `work` (a tracker id) are captured by the work journal (`scripts/srv/workjournal.py`) before anything is delivered, and reach the worker as the whole accumulated direction (see [DESIGN.md, round 26](DESIGN.md#round-26-the-freshness-contract-built)). An item whose record the journal knows shows, in place of the recorded section:

- the latest literal message, by source order, with when it was sent (or received) in UTC; with direction from more than one conversation there is no single latest, and the UI says so
- the direction revision and how many instructions are in force
- the newest delivery's revision and whether the host confirmed it; delivery means the host received it, not that it was followed
- the worker as observed: running, ended (and how), or unknown; an open attempt is never "working"
- the last dated progress and what it answers now (current, older direction, an earlier attempt, unverified); the full statement appears where the record is read in full
- whether a completion qualified for the current revision. New direction after it reopens the item, even if the tracker says done. Unknown or gapped capture coverage reads "freshness unknown", never answered

Other chat hosts are not captured; their direction stays unknown.

## Reading completed context

The latest chat instruction is selected by its own recording timestamp, independently of newer agent updates or review notes. It remains available after the item is done or dropped. Opening a named completed item temporarily reveals it under Opened records, with its full input and notes. This never reopens or otherwise writes the item. Opening another item retires that temporary reveal.

When the last in-progress row disappears while its pane has focus, the pane stays visible with an empty state until the reader leaves. New work cannot revive latent focus and pull the reader away from the main list. The ready filter follows the same rule.
