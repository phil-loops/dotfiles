---
title: Keys like Helix
section: Canopy v2
order: 64
project: canopy-v2
lede: No bottom hint line. Motions are Helix's and go uncaptioned; actions on the thing under the cursor keep one key, captioned on that thing; everything page-wide moves under space and g, with a which-key popup. Plus the layout fixes behind "gruggy". Specced and built 2026-10-25.
---

**Why.** The hint line repeated what the page already showed, and it was the busiest strip on the screen. Helix has no such line. It has a few layers you learn once, and a popup when you press a layer's key.

## Three kinds of key

1. **Motion, search, undo.** These are Helix's keys, and nothing captions them: `j` `k` `h` `l`, `g g` / `G` (and `g e`, Helix's "last line"), `n` / `⇧n`, `]` / `[`, `/`, `u`, `x`, `esc`.
2. **Actions on the thing under the cursor.** Each keeps one key, captioned on that thing, and only while the cursor is on it:
   - thread header: `↵ fold · r reply · ⇧e address`;
   - pending draft: `p send · d delete`;
   - hidden lines: `↵ 20 more`;
   - the selected forest row: `↵ page`;
   - tab labels: `1` `2` `3`.

   Other keys that act on the cursor's thing keep their single key but no caption, because a caption on every diff line would be noise: `c`, `o`, `v`, `e`, `f`/`w`/`⇧x`, `b`, `⇧l`, `⌃k`/`⌃j`. They're in `?`.
3. **Actions on the page or the app** (toggles, overlays, pickers, going elsewhere) move under `space` or `g`. Pressing the prefix opens a which-key popup in the bottom-right corner listing what follows it here. The popup stays until a key or `esc`, as in Helix.

`?` stays the full list. The command palette moves from `space` to `space ?` (Helix's own key for it) and `:`.

## What moves

| command | was | now | why that key |
|---|---|---|---|
| command palette | `space` | `space ?` · `:` | Helix |
| find a file | `t` | `space f` · `/` | Helix file picker / search |
| type on hover | `⇧k` | `space k` | Helix hover |
| split ↔ unified | `s` | `space s` | |
| show outdated | `⇧o` | `space o` | |
| forest map | `m` | `space m` | |
| history, one commit at a time | `⇧h` | `space h` | |
| send every draft | `⇧p` | `space p` | |
| open on GitHub to submit | `⇧s` | `g h` | same move as a row's `g h` (open the PR) |
| only what's ready | `⇧f` | `space r` | |
| show the archive | `⇧a` | `space a` | |
| dashboard window | `⇧t` | `space t` | |

Everything else keeps its key. The `g` layer (`g f` forests, `g o` todo, `g d` definition, `g h` PR, …) gets the same popup.

## Gone with the line

- The ⇧ layer, the chord preview and the "known after 12 presses" fading (`hints.ts`). The popup replaces the chord preview.
- "x · nothing here" becomes a note.
- `Command.label` and `pair` stay: the popup uses `label`.

## Why it feels clunky, and the fixes

From screenshots of every page at 1440×900.

1. **Three bars of chrome.** The review page spends about 180px before the first line of code: the app bar (`canopy review … space menu · ? keys`), the title, then tabs plus buttons. A 35px footer sits under it all.
   → The app bar becomes a one-line breadcrumb, `canopy › forest › branch`, which is also the `h` ladder. The connection dot shows only when the connection isn't live. The footer goes; notes float bottom-left while they last.
2. **Buttons that are captions.** `Open on GitHub ⇧s`, `unified s`, `show outdated ⇧o` and `⇥ cycles` are keys dressed up as buttons.
   → Removed; they're in the `space` popup. The diff's own "1 outdated" stays clickable.
3. **Tab labels misread.** In "Conversation 1 ⑤", the key and the count look alike.
   → The key goes in a faint key box; the count is plain text.
4. **Fixed columns clip the part that tells rows apart:**
   - Forest names cut at 200px ("message-bounce-warnin…") while the description beside them has room. → Names size to fit, up to 32ch; the description truncates.
   - The file tree shows "disable-domain-even…" twice, for two different files. → The middle of the name is cut, never the end.
   - Commit meta wraps across three lines ("2026-␤10-25 · pushed"). → One line: `39dd2c0 · 10-25`, plus `· local` when it isn't pushed.
   - Todo rows truncate two columns side by side, so neither reads. → The title takes the row; the why shows only on the selected row.
5. **Thread headers crowded.** Every folded thread repeats `↵ fold · r reply · ⇧r reopen on GitHub · i its draft · z note`, which clips the comment to two words.
   → Captions already showed only on the thread under the cursor; they're cut to `↵ fold · r reply · ⇧e address`, plus `a apply` or `i draft` when there's one. Resolve and the note's toggle are in `?`.
6. **Raw HTML in comments.** linear-code's comment renders as `<p><a href=…>`. → Bot HTML (links, paragraphs) renders as markdown.

## Built

- **Keys:** `WhichKey.tsx` is the popup. In `keyboard.ts`, a prefix now waits until the next key; `esc` or a click cancels it.
- **Removed:** `HintLine.tsx` and `hints.ts`.
- **Moved keys:** in `commands/*.ts`. `bindings.ts` gains the "open on GitHub" group.
- **Tab keys** always run; they were hidden on their own tab only to keep them off the old line.
- **Misses:** "x · nothing here" now comes from the runner as a note.
- **Layout:** `App.tsx` (crumbs, floating note), `review/Review.tsx` (header, tabs, tree, history), `Forests.tsx`, `Todo.tsx`, `review/markdown.ts`.
- **Checked:**
  - `npm test` (106), including one-meaning-per-key.
  - Puppeteer:
    - `space` and `g` popups on Forests and review;
    - `esc` closes them;
    - `space f` focuses the finder;
    - nothing is fixed to the bottom 40px;
    - no writes.
