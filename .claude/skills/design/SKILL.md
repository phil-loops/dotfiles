---
name: design
description: Co-author a project/feature design doc with the user in nvim, iterating via :submit. Use when the user wants to design, spec, plan, or whiteboard something before building — "design X", "let's spec Y", "whiteboard this", "write up a plan for Z", or any time a feature is fuzzy and worth shaping collaboratively before code. Produces a living doc you both edit; the user edits in nvim and :submit hands it back to you to revise. Iterate until it's right, then build.
---

# Design Doc Loop

Co-author a design doc with the user in nvim. You draft → they edit the "whiteboard" in nvim →
they run `:submit` → it lands back in your input → you revise → repeat. No copy-paste, no
chat-only back-and-forth. When it converges, build from it.

**Never open nvim or switch the user's window yourself.** Draft the doc, record the hand-back
target, and drop a small "launchpad" shell pane below your own (step 2). The user presses `dd`
there to jump into the doc — *they* drive the jump, with zero model latency. The only tmux move
you make is spawning that one pane.

## When to use

- The user wants to **design / spec / plan / whiteboard** a feature before writing code.
- A task is fuzzy or has real design forks worth resolving collaboratively (storage choice,
  job shape, schema, tradeoffs) rather than you guessing.
- Signals: "design X", "let's spec this", "write up a plan", "whiteboard it", "I want to iterate
  on the design", or you're about to make several consequential design calls on the user's behalf.

Skip for trivial/mechanical work, or when the user just wants it built now.

## Prerequisites (already installed in dotfiles)

- The hand-back works off a `<file>.submit-target` sidecar holding **your** (Claude's) tmux pane
  id. `:submit` reads it and `send-keys` the doc path back to that pane.
- `:submit` / `:Submit` — `nvim/lua/custom/submit.lua`: writes the buffer + hands the doc path
  back to the pane named in the sidecar. `:submit <note>` rides a steering note along.
- `dd` → `~/.dotfiles/scripts/dd-design`: the **user's one-keystroke jump** into the doc. It opens
  the doc (`$DESIGN_DOC`, else newest `~/design-docs/*.md`) in the `design` tmux window and **kills
  the pane it ran in**. It does NOT touch the sidecar. The intended flow: you spawn a small shell
  pane (the "launchpad") below your own pane; the user types `dd` there; they land in nvim and the
  launchpad vanishes — zero model latency. This is why the user drives the jump, not you.
- `design <file>` — `~/.dotfiles/scripts/design`: a legacy *user-run* manual open. **You don't run
  it** — it steals focus and re-points the sidecar to the launching pane. Prefer the `dd` launchpad.

If `$TMUX` is unset (not in tmux) the hand-back can't work — fall back to: write the doc, tell the
user the path, ask them to edit and paste back / tell you when ready.

## How to run the loop

1. **Draft the doc.** Write a real design doc to `~/design-docs/<slug>.md`. Good bones:
   `# Design: <title>`, a one-line "edit then `:submit`" banner, **Problem**, **Design**
   (with the concrete shape — names, signatures, data flow), **Branch structure** (forest, per
   the repo's conventions if it's a code project), and an **Open questions** section with the real
   forks called out. Ground it in actual code/benchmarks where you can — don't hand-wave.

2. **Record the hand-back, spawn the launchpad, announce — never open nvim yourself.** Two
   commands (skip both if `$TMUX` is unset — see the fallback above), with `$DOC` = the doc path:
   ```bash
   # a) point :submit back at you
   print -r -- "$TMUX_PANE" > "$DOC.submit-target"
   # b) drop a small shell pane below your own; it inherits DESIGN_DOC so the user's `dd` knows the doc
   tmux split-window -v -l 30% -t "$TMUX_PANE" -e DESIGN_DOC="$DOC" -c "$HOME"
   ```
   The launchpad is a fresh interactive zsh (it sources `.zshrc`, so the `dd` alias is live). Then
   announce: *"Drafted `<path>` — type `dd` in the pane below to jump in, edit, then `:submit`."*
   Do **not** run `dd`, `design`, `nvim`, or any `select-window`/`new-window` yourself — spawning
   the launchpad is the only tmux move you make; the user presses `dd` to actually jump.

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
