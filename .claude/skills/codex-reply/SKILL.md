---
name: codex-reply
description: Send an attributed Claude Code reply into Phil's Codex detector-research chat (Codex CLI in a tmux pane). Use when replying to Codex detector research, handing back a detector assessment, or when Phil asks to send a result to Codex. Tests go only to a throwaway pane.
argument-hint: "[reply text, or --test reply text]"
---

Phil authorized Opus work replies to the `detector-research` chat (Codex title:
"Review override cases"). This is standing authorization for that research
conversation, not permission to forward unrelated material or choose another chat.
Never use `claude-say` (it only reaches Claude sessions) or hand-rolled tmux keys.

The current Claude Code source session is `${CLAUDE_SESSION_ID}`. Pass that exact
value to `--source-session`; do not invent a session ID or impersonate Phil/Codex.

Requested reply or test request:

$ARGUMENTS

If a reply is already provided, preserve its text; otherwise compose the concise
research handback from the current authorized work. Do not attach full transcripts
or unrelated files. For multiline text, write a UTF-8 file in the scratchpad and pass
`--message-file ABSOLUTE_PATH`; for a short one, `--message TEXT` quoted as data.

Phil runs the research chat in the Codex CLI in a tmux pane titled "Review override
cases" (2026-10-22: he left the GUI after a desktop update tripped the IPC build pin).

```text
/Users/philbrockman/.dotfiles/scripts/codex-pane-say --source-session SESSION_ID --message-file PATH
```

It finds exactly one pane by title, refuses if the composer holds text, bracketed-
pastes a signed note and presses Enter. `sent to <pane>` means Codex took it into its
composer queue, not that it finished or agreed; capture the pane to see it working.
Any refusal (no pane, several panes, composer busy): report it and stop; never
retarget with `--pane` to a guess. For tests, run `--pane` against a throwaway Codex
pane Phil names, never the research pane. There is no GUI path: the desktop IPC bridge
(`codex-say`) was retired 2026-10-22; if Phil is only in the GUI, hand him the text.
