---
name: design
description: Co-author a project/feature design doc with the user in nvim, iterating via :submit. Use when the user wants to design, spec, plan, or whiteboard something before building — "design X", "let's spec Y", "whiteboard this", "write up a plan for Z", or any time a feature is fuzzy and worth shaping collaboratively before code. Produces a living doc you both edit; the user edits in nvim and :submit hands it back to you to revise. Iterate until it's right, then build.
---

# Design Doc Loop

Co-author a design doc with the user in nvim. You draft → they edit the "whiteboard" in nvim →
they run `:submit` → it lands back in your input → you revise → repeat. No copy-paste, no
chat-only back-and-forth. When it converges, build from it.

## When to use

- The user wants to **design / spec / plan / whiteboard** a feature before writing code.
- A task is fuzzy or has real design forks worth resolving collaboratively (storage choice,
  job shape, schema, tradeoffs) rather than you guessing.
- Signals: "design X", "let's spec this", "write up a plan", "whiteboard it", "I want to iterate
  on the design", or you're about to make several consequential design calls on the user's behalf.

Skip for trivial/mechanical work, or when the user just wants it built now.

## Prerequisites (already installed in dotfiles)

- `design <file>` — `~/.dotfiles/scripts/design`: opens the doc in nvim (tmux `loops` session,
  window `design`) and records **your** tmux pane in a `<file>.submit-target` sidecar.
- `:submit` / `:Submit` — `nvim/lua/custom/submit.lua`: writes the buffer + `tmux send-keys` the
  doc path back into your pane. `:submit <note>` rides a steering note along.

If `$TMUX` is unset (not in tmux) the hand-back can't work — fall back to: write the doc, tell the
user the path, ask them to edit and paste back / tell you when ready.

## How to run the loop

1. **Draft the doc.** Write a real design doc to `~/design-docs/<slug>.md`. Good bones:
   `# Design: <title>`, a one-line "edit then `:submit`" banner, **Problem**, **Design**
   (with the concrete shape — names, signatures, data flow), **Branch structure** (forest, per
   the repo's conventions if it's a code project), and an **Open questions** section with the real
   forks called out. Ground it in actual code/benchmarks where you can — don't hand-wave.

2. **Launch it:** ```bash
   ~/.dotfiles/scripts/design ~/design-docs/<slug>.md
   ``` Tell the user it's open in the `design` tmux window: *edit, then `:submit`*.

3. **On each `:submit`** (you'll receive a message like `design doc submitted, please re-read <path>`):
   - **Re-read the file** — the user's edits + inline notes are in it (the system reminder shows the diff).
   - **Answer every note inline** with `→` lines right where they asked, so your replies show up when
     they reload. Bake resolved decisions into the design prose. Keep open forks in **Open questions**.
   - **Rewrite the file** (Write the whole doc), then tell the user to **`:e` to reload** and review,
     and `:submit` again. (nvim won't auto-reload; remind them.)

4. **Converge, then build.** When the open questions are resolved, summarize the final design and
   start building (as a stack/forest if the repo uses one). Offer to keep the doc (relocate into the
   repo to version it) or leave it scratch in `~/design-docs/`.

## Conventions that make it feel good

- **`→` for your voice, plain prose for the doc.** The user scans for `→` to see what you answered.
- **Resolve, don't just acknowledge** — when the user picks an option, delete the fork and write the
  decision into the design; don't leave a graveyard of settled questions.
- **One open call at a time** when possible — fewer, sharper forks beat a wall of questions.
- **Be opinionated** — give a recommendation on each fork (`→ My rec: …`), the user can override.
