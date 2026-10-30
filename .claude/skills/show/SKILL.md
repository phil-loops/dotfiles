---
name: show
description: Present a design, plan or walkthrough as a native macOS app (Swift + AppKit) with a sidebar of sections and a sign-off checkbox + note per section that Claude reads back from disk. Use when Phil says "show me", "use show", "put it in show", "walk me through it in show", or wants to read and sign off on a design section by section. NOT for web pages or claude.ai artifacts.
---

# show — a native walkthrough Phil can sign off on

`show <deck.json>` opens a deck as a tab in the one running Show app (sidebar of sections, rendered markdown, a **Signed off** checkbox and a note field per section). Each tab and window is titled with the deck's title, and its subtitle shows how many sections are signed off. The **Decks** menu lists every deck in `~/.dotfiles/show`, newest first, with sign-off counts. Open decks reload by themselves when their file changes on disk, keeping the selected section. When the launcher finishes a new build, the running app saves notes and relaunches into it with the same decks open. So rewriting a deck or editing Show.swift and then running `show --build` is all it takes. A bare `show` opens the newest deck. Sign-offs and notes save to `<deck>.signoff.json` beside the deck, which is how Phil's verdicts come back to you.

- Launcher: `~/.dotfiles/scripts/show` (on PATH). Source: `~/.dotfiles/scripts/show-app/Show.swift`. It rebuilds itself into `~/.cache/show/Show.app` whenever the source's hash changes (`show --build` to just build).
- Decks live in `~/.dotfiles/show/<name>.json`.

## Deck format

```json
{
  "title": "Domain enforcement — principles",
  "subtitle": "Sign off from the top",
  "replyTo": "<your session id prefix, from claude-say's list>",
  "sections": [
    { "id": "rule-1", "group": "Rules", "title": "1 · …", "tag": "optional mono subtitle", "body": "markdown" }
  ]
}
```

- `id` keys the sign-off; keep ids stable across regenerations so earlier sign-offs survive. When a section's meaning changes, give it a new id (its old sign-off then no longer applies).
- `group` becomes a sidebar header; consecutive sections with the same group sit under it.
- `url` (instead of `body`) shows a live page in the section, such as a preview server or a viewer page. It keeps its own login, which persists between launches.
- `body` markdown supported: `# ` / `## ` headings, `- ` and `1. ` lists (indent for nesting), `> ` a large pull quote, fenced code blocks, `|` tables (rendered monospaced), inline `**bold**`, `*italic*`, `` `code` ``, links.

## Recipe

1. Write the deck with a small generator script in the scratchpad (Python building the JSON) rather than hand-escaping JSON; write output to `~/.dotfiles/show/<name>.json`.
2. Order sections top-down for sign-off: the guiding idea first, then one page per principle, then what they produce, then plan and open questions. One idea per page.
3. Open it: `show ~/.dotfiles/show/<name>.json`. After regenerating a deck, run the same command again: it reloads the open tab instead of opening a second window. Give every deck a distinct `title`, since that is the tab label.
4. Tell Phil it's open and how sign-off works. Then wait. **Submit** (⌘↩) sends `claude-say <replyTo>` a line naming the sign-off file; read `<name>.signoff.json` when it arrives, or when he says he's been through it, and treat every note as pushback to address. Set `replyTo` to this session's id prefix (`$CLAUDE_CODE_SESSION_ID`, first 8 characters); without it, Submit only marks the deck done.

## Tutor space

The rail on the window's left edge switches spaces: **Decks** (⌘1) and **Tutor** (⌘2). The Tutor space runs a `/tutor` session as a worksheet: one rung at a time, answered in place.

- `show --tutor <file>` opens the Tutor space on a session; a bare `show --tutor` opens the newest one in `~/.dotfiles/show/tutor/`. The **Tutor → Sessions** menu lists the rest, newest first. Tutor files never appear in the Decks menu.
- `show --tutor-check <file>` prints the current rung, the station states and each rung's rail order without opening a window.

Session file `~/.dotfiles/show/tutor/<name>.json` (Claude writes it):

```json
{
  "mode": "tutor",
  "title": "SQS visibility timeout",
  "replyTo": "<your session id prefix>",
  "stations": [{ "name": "In flight, not gone", "state": "done | current | todo" }],
  "due": [{ "concept": "lock-guards-holders-not-execution", "why": "missed: believed the lock prevents concurrent execution" }],
  "rungs": [{
    "id": "r1",
    "station": "In flight, not gone",
    "title": "One message or two?",
    "situation": "markdown",
    "ask": "predict | explain | restate | invent",
    "timeline": [{ "t": "0", "event": "W1 calls ReceiveMessage, gets M" }],
    "parts": [{ "id": "a", "at": "20", "ask": "How many messages does SQS have?" }, { "id": "b", "ask": "Why?" }],
    "reveal": "markdown, or { \"a\": \"markdown\", \"b\": \"markdown\" }, or null",
    "verdicts": { "a": "held", "b": "revised" },
    "followup": "markdown or null"
  }],
  "notes": [{ "at": "ISO-8601", "text": "markdown: the tutor's reply to a learner message" }],
  "agent": { "session": "<uuid Show minted for this file's headless tutor>" }
}
```

- `"kind": "tutor"` is still accepted in place of `mode`; a file with neither is a deck.
- `timeline` draws a vertical rail with the time in the gutter. A part with `at` sits on the rail at that time (after the last event at or before it) with its answer field under it; a part without `at` goes below the rail. A rung with no `parts` gets one field (part id `_`).
- The **current rung** is the one after the last answered rung. Its fields are editable (Tab and ⇧Tab move between them), with a confidence control (Guessing / Fairly sure / Certain, ⌃1–⌃3; required for `predict` and optional otherwise) and **Send prediction** / **Send answer** (⌘↩). Earlier rungs are dimmed and locked.
- A keyed `reveal` renders under that part's answer and a string reveal renders under the whole rung; reveals fade in when they arrive. `verdicts` puts a margin mark beside each part: a filled dot for held, a ring for revised.

Answers sidecar `<name>.answers.json` beside the session. **Show writes it; Claude never does.**

```json
{
  "r1": { "parts": { "a": "text", "b": "text" }, "confidence": "low | medium | high | null", "at": "ISO-8601" },
  "messages": [{ "at": "ISO-8601", "text": "why 30s?" }]
}
```

**The window is the chat.** A composer is pinned under the thread ("Ask the tutor anything"). Rungs, Phil's messages (right-aligned, in ink) and the tutor's `notes` (left-aligned) interleave by time; a rung counts from when the previous rung was answered. ⌘↩ sends whichever has focus: the composer, or the current rung's fields.

**Each tutor file has its own headless tutor.** Show runs it, not your terminal session:

- On the first send to a file without `agent.session`, Show mints a UUID and writes it into the file. It then boots the tutor with `claude -p --session-id <uuid>`, telling it to run the /tutor skill for this file and reply only by editing the file. Every send after that runs `claude -p --resume <uuid> --output-format stream-json --include-partial-messages --permission-mode acceptEdits --allowedTools "Read,Edit,Write,Bash(~/.dotfiles/scripts/learn:*),Bash(~/.dotfiles/scripts/sim-play:*)" -- "<message>"` in `~/.dotfiles`, resolving `claude` on the login-shell PATH with `~/.local/bin` in front.
- The messages are `tutor answer: <session path> rung <id>` and `learner says: <text>`.
- One turn runs at a time per file, and further sends queue. While a turn runs, a "Tutor is typing…" row streams the reply's text faintly. The row goes away when the turn ends, because the tutor's file edit reloads the real content. A failed turn leaves a quiet error row with the stderr tail and **Retry**.
- A file that has a `replyTo` and no `agent` stays on the old path: sends go to `claude-say <replyTo>` (your terminal session) instead. Once `agent` exists, `replyTo` is ignored.
- `show --tutor-ask <file> "<text>"` does what the composer does, without a window, and streams the reply to stdout. `SHOW_CLAUDE=<path>` swaps in another `claude` binary for testing.

The tutor's loop, whether it's the headless tutor or you via `replyTo`:

1. Write a rung, then run `show --tutor <file>`.
2. Phil answers and sends. Show writes the sidecar, and the tutor gets `tutor answer: … rung <id>`. His fields lock under "Sent. Waiting for Claude's reveal."
3. Read `.answers.json`. Then rewrite the session file atomically: add the reveal (and `verdicts`) to that rung, and append the next rung. Answer a `learner says:` message by appending to `notes`.
4. The open session reloads within a second of the file changing. It keeps unsent text, focus and scroll, and scrolls to a new current rung. Re-running `show --tutor <file>` also brings it forward.

## Verifying

**Never drive or capture his screen** — no `osascript`/System Events keystrokes, no `screencapture`. A clean compile is the check. `show --snapshot <deck> <out.png>` renders the window offscreen in-process; it currently draws the window chrome and the sign-off bar but not the scrolling panes, so it can confirm layout of the bar only. For a tutor session it also writes `<out>-worksheet.png`, the full worksheet column. If something looks wrong, ask Phil.
