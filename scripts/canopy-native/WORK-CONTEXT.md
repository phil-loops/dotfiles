# Work context

Canopy reads work status from the existing todo records. The home page's In progress pane shows items marked `doing`, across lists. Return opens the exact item on its list. Forest and branch context uses only explicitly linked items: `project` is the full `<repo>:<forest>` ID, and `solved_by` is the complete branch name.

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

The existing todo body is the sole storage. This format needs no new server field or separate activity registry. Automatic import from chat hosts remains a separate integration: a host must attach a real message and timestamp to an exact work item, rather than infer its target from a session's current directory or branch.

## Reading completed context

The latest chat instruction is selected by its own recording timestamp, independently of newer agent updates or review notes. It remains available after the item is done or dropped. Opening a named completed item temporarily reveals it under Opened records, with its full input and notes. This never reopens or otherwise writes the item. Opening another item retires that temporary reveal.

When the last in-progress row disappears while its pane has focus, the pane stays visible with an empty state until the reader leaves. New work cannot revive latent focus and pull the reader away from the main list. The ready filter follows the same rule.
