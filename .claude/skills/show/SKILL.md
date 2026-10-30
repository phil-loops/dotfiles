---
name: show
description: Present a design, plan or walkthrough as a native macOS app (Swift + AppKit) with a sidebar of sections and a sign-off checkbox + note per section that Claude reads back from disk. Use when Phil says "show me", "use show", "put it in show", "walk me through it in show", or wants to read and sign off on a design section by section. NOT for web pages or claude.ai artifacts.
---

# show — a native walkthrough Phil can sign off on

`show <file.json>` opens a file in the one Show window (section list, rendered markdown, a **Signed off** checkbox and a note field per section). The window never multiplies: a rail on its left edge switches between four **workspaces**, and each keeps its own open document, typed text and scroll while another is in front.

| Workspace | Key | Opens files with | Holds |
|---|---|---|---|
| Forest | ⌘1 | `"mode": "forest"` | a project's branches in merge order (branch-deck decks) |
| Review | ⌘2 | `"mode": "deck"` or no mode | plans and designs to sign off |
| Learn | ⌘3 | `"mode": "tutor"` | tutor sessions |
| Runs | ⌘4 | `"mode": "live"` | live runs, read-only |

An optional top-level `"workspace": "forest" | "review" | "learn" | "runs"` overrides the mode. `show <file>` switches to that file's workspace and opens it there; `show --check-routing <file>` prints where a file goes without opening anything. The only thing that crosses between workspaces is the count of documents waiting on Phil, a badge on each rail icon. The title band shows the document's title and, in the workspace's quiet tint, its progress.

**A library, not tabs.** One document is open per workspace. Each workspace's left column is a shelf of its documents from `~/.dotfiles/show` and `show/tutor/`, grouped by what they want from Phil: **Waiting on you** (◆: unsigned sections, or a tutor rung with no answer), **Running** (◉: Runs only, `status.state` `running`), and **Done** (●: fully signed, finished runs, tutor sessions waiting on Claude), which folds after 5. Each row shows the title, "4 of 9 signed" and when it was last touched. The open document's section list is a second column beside the shelf (marks: ● signed, ◆ has a note, ◐ open, ○ not yet); ⌃⌘S hides the shelf, and it collapses by itself when the window gets narrow.

- **⌘O** or **/** opens a fuzzy finder over the current workspace's shelf; **⌘[** goes back to the previously open document; **⌥⌘O** opens any file.
- **Every action has a key**, listed in the menu bar with its shortcut and in the **`?`** sheet (⌘/ too), grouped by workspace. Focus: **⇥ / ⇧⇥** cycle shelf → section list → page → note (Learn: the rung's fields, then the composer); **j/k** or ↓/↑ move in a list and **↵** opens; **n** jumps into the note or composer; **⎋** leaves a field (its text stays) or closes an overlay; **⌘S** toggles Signed off. The focused column wears an accent outline.
- **⌫** on a shelf row archives the document, moving it and its `.signoff.json` / `.answers.json` into `~/.dotfiles/show/archive/`. Nothing is ever deleted.
- `show <file>` moves the document to the top of its group.

Open documents reload by themselves when their file changes on disk, keeping the selected section, scroll and cursor. When the launcher finishes a new build, the running app saves notes and relaunches into it, each workspace back on its document. So rewriting a deck or editing the Swift source and then running `show --build` is all it takes. A bare `show` opens the newest deck. Sign-offs and notes save to `<deck>.signoff.json` beside the deck, which is how Phil's verdicts come back to you.

- Launcher: `~/.dotfiles/scripts/show` (on PATH). Source: `~/.dotfiles/scripts/show-app/*.swift`. It compiles every file there into `~/.cache/show/Show.app` whenever any of their hashes changes (`show --build` to just build).

**Source layout** (`scripts/show-app/`, one file per area): `App.swift` is the AppDelegate, launch, menus, the one window and `Workspace` routing; `main.swift` parses the command line and starts the app (Swift only runs top-level code from `main.swift`). `Shell.swift` holds the rail, `WorkspaceController`, the shelf/library and the ⌘O finder; `Render.swift` the markdown renderer (tables, code, images); `Decks.swift` `DeckController` with sign-off and Submit (`claude-say`); `Forest.swift` the merge-order `ForestOrder`, the forest tint and ⌘⇧O's canopy command; `Tutor.swift` the Learn session types, sidecar, headless `TutorAgent`, worksheet and `--tutor-ask`; `Live.swift` the Live view (status header, status-grouped list, compare/data/source rendering, Stop after this round, `--check-live`, the live-runs registry); `Keys.swift` the `KeyTable` (one list that generates the menus and the `?` sheet; other areas add keys with `KeyTable.register([...])`), the key router, the focus order and its outline; `Snapshot.swift` `--snapshot` plus `--check-routing` / `--tutor-check`; `Model.swift` the shared `Deck` / `Section` / `SignOff` types.
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
- `"mode": "live"` makes the deck a read-only **Live view**: no sign-off bar, no `.signoff.json`. Write it atomically (temp file + rename) and keep section ids stable. Top-level `"status": {"state": "preparing|running|paused|done|failed", "done", "total", "current"}` and `"runDir"` feed a pinned header: a thin progress bar, "312 of 500", the state, "now: <current>", counts ◆ disagree/flagged · ● agreed · ○ pending (from section statuses), and "updated Ns ago", which turns orange when a running run has been quiet over 30s. `failed` shows in orange with `current` as the reason. The Runs tint turns orange while `state` is `running`.
  - Live sections take optional `"status": "pending|agreed|disagree|flagged"` (the list groups by it: sections without one in Overview on top, then Disagreements (⚑ = flagged), Agreed, Pending, with counts; `group` is ignored and may be left out), `"compare": {"columns": [models], "rows": [{"field", "values"}], "diffs"?: [[row, col]]}` (cells that differ from the row majority, or listed in `diffs`, get an orange tint; **d** shows only rows that differ), `"tables": [{"title", "columns", "rows"}]` and `"source": {"title", "text"}` (numbered monospace, last). Order on the page: body, compare, tables, source. A live section needs no `body`.
  - **Stop after this round** (⌘., confirmed with ↵, Esc cancels) creates `<runDir>/STOP`; the runner checkpoints and exits after the current round. While STOP exists and the run still says `running`, the header reads "Stopping after this round". The button is disabled, with the reason beside it, when there's no writable `runDir`, STOP already exists, or the run is done or failed. Show never removes STOP and writes nothing else in `runDir`.
  - Every live deck Show opens is recorded in `~/Library/Application Support/Show/live-runs.json` (`[{path, title, openedAt}]`, missing files pruned; `SHOW_LIVE_RUNS` swaps the path); the SwiftBar plugin's **Runs** group lists them with state and done/total, and so does the Runs workspace's shelf (◉ running, ● done, ◆ failed; files that are gone drop out). ⌫ on a run that lives outside `~/.dotfiles/show` only removes it from `live-runs.json`; the run's files are never moved or touched.
- `url` (instead of `body`) shows a live page in the section, such as a preview server or a viewer page. It keeps its own login, which persists between launches.
- `body` markdown supported: `# ` / `## ` headings, `- ` and `1. ` lists (indent for nesting), `> ` a large pull quote, fenced code blocks (one panel; box-drawing lines join up), `|` tables (real table cells sized to their content, first row as header), `![alt](path)` on its own line for an image (absolute or relative to the deck; shrunk to the column, never enlarged; name a Retina PNG `…@2x.png`; the alt text becomes a caption), inline `**bold**`, `*italic*`, `` `code` ``, links.

## Recipe

1. Write the deck with a small generator script in the scratchpad (Python building the JSON) rather than hand-escaping JSON; write output to `~/.dotfiles/show/<name>.json`.
2. Order sections top-down for sign-off: the guiding idea first, then one page per principle, then what they produce, then plan and open questions. One idea per page.
3. Open it: `show ~/.dotfiles/show/<name>.json`. After regenerating a deck, run the same command again: it reloads the open tab instead of opening a second window. Give every deck a distinct `title`, since that is the tab label.
4. Tell Phil it's open and how sign-off works. Then wait. **Submit** (⌘↩) sends `claude-say <replyTo>` a line naming the sign-off file; read `<name>.signoff.json` when it arrives, or when he says he's been through it, and treat every note as pushback to address. Set `replyTo` to this session's id prefix (`$CLAUDE_CODE_SESSION_ID`, first 8 characters); without it, Submit only marks the deck done.

## Forest workspace

A Forest file is a deck with top-level `"mode": "forest"`, `"project"` and `"repo"` (the branch-deck skill writes them). Each branch section adds `"rank"` (Int, from `stack-merge-rank`) and `"parent"` (the branch's stack-parent), and its `id` is the branch name. Show never shells out to git for any of it.

- The shelf has one row per forest deck (project).
- The section list puts sections without a `rank` (the merge-story overview, `url` live pages) in an **Overview** group on top, in file order; the overview opens first. **Merge order** follows: branches sorted by rank, then parent, then file order, numbered by rank (tied siblings share a number) and indented under their parent when the parent is in the deck.
- Sign-off, `<deck>.signoff.json` and Submit → `claude-say <replyTo>` work exactly as for decks.
- **⌘⇧O** runs `~/.dotfiles/scripts/canopy /v2/b/<repo>/<branch>` for the selected branch. On a non-branch section it does nothing and says why at the foot of the shelf. `SHOW_CANOPY=<path>` swaps the binary for testing.
- `show --check-routing <deck>` prints the overview and the numbered merge order.

## Learn workspace

The Learn workspace (⌘3) runs a `/tutor` session as a worksheet: one rung at a time, answered in place.

- `show --tutor <file>` (or plain `show <file>`) opens Learn on a session; a bare `show --tutor` opens the newest one in `~/.dotfiles/show/tutor/`. Learn's shelf lists the rest; tutor files never appear on another workspace's shelf.
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

- On the first send to a file without `agent.session`, Show mints a UUID and writes it into the file. A session Claude has no transcript for boots in one turn: `claude -p --session-id <uuid>` with the tutor's rules (edit only the session file, one rung per turn, evidence via `learn`, never the answers file, the schema) followed by the opening message. `--add-dir` grants the session's folder, and `LEARNING_GRAPH` / `LEARNING_MEMORY` pass through when set, so a test can point `learn` at a scratch graph. Every send after that runs `claude -p --resume <uuid> --output-format stream-json --include-partial-messages --permission-mode acceptEdits --allowedTools "Read,Edit,Write,Grep,Glob,Bash(~/.dotfiles/scripts/learn:*),Bash(~/.dotfiles/scripts/sim-play:*),Bash(date:*)" -- "<message>"` in `~/.dotfiles`, resolving `claude` on the login-shell PATH with `~/.local/bin` in front.
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

**Never drive or capture his screen** — no `osascript`/System Events keystrokes, no `screencapture`. A clean compile is the check. `show --snapshot <file> <out.png>` renders the whole window offscreen in-process (`<out>.png`, a composite with the lists painted in) and never touches the running app or its saved state. It also writes `<out>-rail.png` (the workspace rail), `<out>-detail.png` (the rendered section at full height) and `<out>-sidebar.png` (the section list), and for a tutor session `<out>-worksheet.png`, the full worksheet column. It writes `<out>-shelf.png` (the workspace's shelf) too and prints the shelf and back history. `SHOW_SNAPSHOT_SECTION=<id>` picks the section, `SHOW_SNAPSHOT_APPEARANCE=dark` renders dark, `SHOW_SNAPSHOT_KEYS=d,cmd-.,confirm|cancel` types Live's keys and answers the stop sheet (fixture `runDir`s only), `SHOW_SNAPSHOT_WORKSPACE=<name>` brings another workspace forward, `SHOW_SNAPSHOT_FINDER=<query>` opens the finder on a query, `SHOW_SNAPSHOT_BACK=1` goes back once, `SHOW_SNAPSHOT_ARCHIVE=<path>` archives that shelf row (fixtures only), `SHOW_SNAPSHOT_TABS=<n>` presses ⇥ n times, `SHOW_SNAPSHOT_SHEET=1` opens the `?` key sheet, `SHOW_SNAPSHOT_CANOPY=1` presses ⌘⇧O and prints the status line, and `SHOW_DIR=<dir>` points the library at fixtures instead of `~/.dotfiles/show`. `show --check-live <deck>` prints a live deck's header, list groups and each compare table with its differing cells, without a window. If something looks wrong, ask Phil.
