# Design note: select-to-Claude (mouse-selection, not shift-click)

_Status: design / not built. Captured 2026-06-17. Phil wants this on the soon side — it's
arguably the highest-value feature (it's what makes this a Claude review surface, not just a
diff browser), and it has no dependency on the graph port, so it doesn't need to wait._

## The problem with the vanilla flow

The vanilla viewer's select-to-Claude works by **shift-clicking individual diff lines** to
accumulate a selection, then typing an instruction in a bottom "ask Claude" bar (`POST /claude`).
Phil's verdict: the per-line shift-click is awkward. Lines are the wrong unit of interaction.

## The target UX

Just **sweep-select text with the mouse** over the diff (the obvious gesture), and on selection
a small floating **"ask Claude" chip** appears near the cursor with an optional one-line
instruction field. Send hands the selected ranges to Claude.

- **Context rides along silently.** The app already knows `project` + `branch` from the URL
  (`?branch=<project>#node=<branch>`) and the file path from the diff card. Phil never types or
  picks the branch — it's ambient, attached under the hood.
- **Multi-region accumulates.** Select in file A, then file B — ranges accumulate (same as the
  vanilla multi-line behavior, minus the tedium). A small "N ranges · M files" affordance + clear.

## Implementation wrinkle: diff2html side-by-side is a TABLE

We render diffs with `Diff2Html.html(patch, { outputFormat: "side-by-side" })` — a two-column
table (old | new) with gutter line-number cells and `+`/`−` marker cells. A raw
`window.getSelection().toString()` over that drags in line numbers and `+`/`−` markers and can
span both columns into garbage. So **don't ship the raw selection string.**

**Chosen approach — capture touched rows, not the raw string:**
On `selectionchange` (debounced), walk the selection range to the `<tr>`s it intersects, and for
each row pull:
- the real code text (the line-content cell, not the gutter/marker cells), and
- the **new-side line number** from the data attributes diff2html already emits on the row.

That yields clean per-file `{ path, ranges: [[start, end], …] }` — exactly the shape the existing
`/claude` endpoint wants — instead of a blob. Keeps the side-by-side view we already have.

Endpoint contract (from `scripts/srv/assist.py`):
`POST /claude { branch, selections: [{ path, ranges: [[start, end], …] }], instruction }`
— note `ranges` are `[start, end]` **pairs**, not `{start,end}` objects.

_Alternative considered:_ switch this diff to single-column line-format, where selection is
naturally clean. Rejected — costs the side-by-side view; the row-walk keeps both.

## Prerequisite: proxy `/claude`

`vite.config.js` `ROUTES` currently lists `/open`, `/bless`, … but **not `/claude`**. The
endpoint exists on the Python server (`stack-review-server.py`) — it's just not forwarded. Add
`/claude` to `ROUTES` (it gets anchored as `^/claude(?:\\?|$)` like the rest). One line.

## Build sketch (rough order)

1. ✅ **DONE** — Added `/claude` to the Vite proxy `ROUTES` (`vite.config.js`).
2. ✅ **DONE** — `src/useDiffSelection.ts`: listens for `selectionchange` (debounced 120ms),
   resolves the selection's ranges → intersected `<tr>`s within `.d2h-diff-tbody`, attributes
   each row to a file via the closest `[data-claude-path]`, reads new-side (right)
   `td.d2h-code-side-linenumber`, and collapses to contiguous `[start,end]` ranges. Returns
   `{ selection(), clear() }` where `selection()` is
   `{ files: [{ path, ranges }], lineCount, fileCount } | null`.
   - **Wiring contract it depends on:** each file's diff must sit under an element with
     `data-path="<repo-relative path>"` — App.tsx's `FileEntry` `<article>` ALREADY has this
     (it also drives the open-in-nvim line handler), so step 4 adds no attribute.
3. ✅ **DONE** — `src/AskClaudeChip.tsx`: floating chip anchored to the selection rect, shows
   "N lines · M files", optional instruction input (Enter to send), posts `/claude` with
   `{ branch, selections: files, instruction }`, brief "sent ✦" flash, then `clear()`.
   Self-contained `.dsc-*` styling (no index.css edit). Handles the floating-toolbar trap by
   **snapshotting** the selection on appear (focusing the input collapses the live selection,
   so we send the snapshot). Esc / × / outside-click dismiss.
   - Props: `selection` (from `useDiffSelection`), `branch` (accessor), `onClear`.
4. ✅ **DONE (landed 2026-06-17)** — wired into `App.tsx` once it went quiet after the TS
   migration: the 2 imports, the `useDiffSelection()` call, and `<AskClaudeChip … />` after
   `</main>`. NodeActions was already wired by the migrator (left untouched). Whole app
   bundles clean (esbuild, all local imports resolve). Recipe kept below for reference:

   **Wire-in recipe (3 edits, anchor-keyed — survives line churn):**
   1. After `import { fetchJSON } from "./api";` add:
      ```ts
      import { useDiffSelection } from "./useDiffSelection";
      import AskClaudeChip from "./AskClaudeChip";
      ```
   2. In `NodeDetail`, near the other signal decls (e.g. just after `const [showMap, …]`):
      ```ts
      const { selection: claudeSel, clear: clearClaudeSel } = useDiffSelection();
      ```
   3. Just after `</main>` in `NodeDetail`'s return:
      ```tsx
      <AskClaudeChip selection={claudeSel} branch={active} onClear={clearClaudeSel} />
      ```
   No `data-path` edit needed — `FileEntry`'s `<article>` already carries it.

## Collision log

- **2026-06-17 ~11:1x** — while building this, another session migrated the whole Solid app
  to **TypeScript**: `App.jsx→App.tsx`, `api.js→api.ts`, `main.jsx→main.tsx`, added
  `tsconfig.json` (`strict: true`, `allowJs: false`) + a `./types` module, and is still
  type-annotating App.tsx (it changes every few minutes). Consequences:
  - Our new files were converted `.js/.jsx → .ts/.tsx` to fit (`allowJs:false` would ignore JS).
  - The step-4 wire-in can't be landed as a line patch against a file being rewritten — hence
    the anchor-keyed recipe above. Land it (or hand it to whoever owns App.tsx) once it settles.

## App.tsx wire-in landing (pending — when App.tsx quiets)

**Only the select-to-Claude wire-in remains to land.** Apply the 3-edit recipe above
(imports + `useDiffSelection()` + `<AskClaudeChip … />` after `</main>`). Re-verify anchors
at landing time — App.tsx moves.

- **NodeActions — ALREADY WIRED, do NOT re-add.** The migrator session (9eea070c) mounted it
  in App.tsx (import ~`:18`, `<NodeActions branch={active()} />` ~`:674` in node-head by the
  map button), typechecks clean, shipping in their commit. Re-adding the import+mount would
  duplicate and break the build.
- **Known backend gap (separate task, `stack` lane):** Phil wants the squashed commit to have
  a smart subject and **NO body**. `/squash → stack-squash` currently emits a voiced subject +
  body bullets. Needs a `stack-squash --subject-only` flag — out of scope for the frontend.

## Not in scope

- Not a parity port — this is a redesign of the vanilla interaction, deliberately diverging from
  shift-click. The graph is the actual parity port; this is its own track.
- No bless-all / bulk anything (unrelated, but the house rule still stands).
