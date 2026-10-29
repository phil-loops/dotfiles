---
name: show
description: Present a design, plan or walkthrough as a native macOS app (Swift + AppKit) with a sidebar of sections and a sign-off checkbox + note per section that Claude reads back from disk. Use when Phil says "show me", "use show", "put it in show", "walk me through it in show", or wants to read and sign off on a design section by section. NOT for web pages or claude.ai artifacts.
---

# show — a native walkthrough Phil can sign off on

`show <deck.json>` opens a deck in a small AppKit app (sidebar of sections, rendered markdown, a **Signed off** checkbox and a note field per section). Sign-offs and notes save to `<deck>.signoff.json` beside the deck, which is how Phil's verdicts come back to you.

- Launcher: `~/.dotfiles/scripts/show` (on PATH). Source: `~/.dotfiles/scripts/show-app/Show.swift`. It rebuilds itself into `~/.cache/show/Show.app` whenever the source's hash changes (`show --build` to just build).
- Decks live in `~/.dotfiles/show/<name>.json`.

## Deck format

```json
{
  "title": "Domain enforcement — principles",
  "subtitle": "Sign off from the top",
  "sections": [
    { "id": "rule-1", "group": "Rules", "title": "1 · …", "tag": "optional mono subtitle", "body": "markdown" }
  ]
}
```

- `id` keys the sign-off; keep ids stable across regenerations so earlier sign-offs survive. When a section's meaning changes, give it a new id (its old sign-off then no longer applies).
- `group` becomes a sidebar header; consecutive sections with the same group sit under it.
- `body` markdown supported: `# ` / `## ` headings, `- ` and `1. ` lists (indent for nesting), `> ` a large pull quote, fenced code blocks, `|` tables (rendered monospaced), inline `**bold**`, `*italic*`, `` `code` ``, links.

## Recipe

1. Write the deck with a small generator script in the scratchpad (Python building the JSON) rather than hand-escaping JSON; write output to `~/.dotfiles/show/<name>.json`.
2. Order sections top-down for sign-off: the guiding idea first, then one page per principle, then what they produce, then plan and open questions. One idea per page.
3. Open it: `show ~/.dotfiles/show/<name>.json` (launching with `open` is fine).
4. Tell Phil it's open and how sign-off works. Then wait — read `<name>.signoff.json` when he says he's been through it, and treat every note as pushback to address.

## Verifying

**Never drive or capture his screen** — no `osascript`/System Events keystrokes, no `screencapture`. A clean compile is the check. `show --snapshot <deck> <out.png>` renders the window offscreen in-process; it currently draws the window chrome and the sign-off bar but not the scrolling panes, so it can confirm layout of the bar only. If something looks wrong, ask Phil.
