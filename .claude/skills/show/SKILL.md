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

## Verifying

**Never drive or capture his screen** — no `osascript`/System Events keystrokes, no `screencapture`. A clean compile is the check. `show --snapshot <deck> <out.png>` renders the window offscreen in-process; it currently draws the window chrome and the sign-off bar but not the scrolling panes, so it can confirm layout of the bar only. If something looks wrong, ask Phil.
