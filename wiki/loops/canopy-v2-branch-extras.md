# canopy v2 — the branch page's four extras

v1 had four branch-page tools that v2 never ported: a diff-base picker, the branch-description
editor, force-origin and freeze. v1 is gone (2026-10-27); these get built fresh in v2. The server
already has every endpoint they need — this is client work only.

## 1. Diff base — "what am I comparing against?"

v1: a four-way toggle (parent · main · last blessed · outgoing). Bless is gone, and v2's viewed
marks already answer "what changed since I looked", so v2 keeps three:

| base | means | `/node?base=` |
|---|---|---|
| **parent** (default) | this branch's own change — what the PR shows | `` |
| **main** | the whole stack up to here, as it would land | `main` |
| **outgoing** | what origin doesn't have yet — the next push | `@origin` |

- Shown in the files tab header as `vs parent`; the word is the control.
- `space d` opens a which-key with `p` / `m` / `o`; the choice rides the URL (`?base=main`) so a link
  reproduces the view, and resets to parent when you leave the branch.
- `outgoing` only offered once the branch is on origin; for a PR'd branch it's the review of the
  follow-ups you're about to push — the case that made v1 grow it.
- Viewed marks are per hunk content, so they carry across bases unchanged.

## 2. The branch description

The description is the branch's one human line — the forest's spine, the PR-body drafter and the
commit gate all read it. v2 edits commit messages and the PR text (`e`, `review.words`) but not this.

- It shows under the title where the PR title isn't (no PR yet), and on the forest page's rows.
- Edit in place: the words tab gets a first field, `description`, above the PR title; `e` opens the
  words tab as today. Saved via the existing `/outline {description}` write, optimistic, `u` undoes.
- On the forest page, `space e` on a branch row edits it inline (the row's text becomes the input).
- Copy rule from forests.md: one verb-first plain line — the field shows the description's length
  and warns on an "and" (the split-point test), never blocks.

## 3. Force-origin — the one sanctioned force

`POST /force-origin {branch, lease}` replaces a pushed branch's history only when it has no PR, or a
draft PR with zero reviews and zero comments, gates green for this exact tree, and origin still at
the lease. The server re-checks everything; the client's job is to make the scope legible.

- Never a key on its own. When the ship line sees `diverged` and the scope is eligible, the push
  button's state reads `diverged · replace origin?` and `p` arms a **force** instead of a push —
  same arm-then-send motion, but the armed state says `force-with-lease over origin's <sha>`.
- Out of scope (a reviewed PR): the ship line says why and offers the additive path (prep's vehicle)
  — force is never offered past a reader.
- The guard list (`forceScope.guards`) shows in the hover and in the step strip, each ✓/✗, so a
  refusal reads as the failed guard, not an error.

## 4. Freeze — "origin is deliberately behind"

`frozen-origin` marks a branch whose pushed PR stays the review artifact while local carries the
restacked truth: sync/prep stop treating the divergence as something to fix.

- Lives in the space menu as `freeze origin` / `unfreeze origin` (only when the branch is pushed).
- A frozen branch shows `❄ origin frozen` in the ship line; `p` doesn't arm (nothing to push by
  design) and `s` skips the divergence step. Unfreeze is one command, undoable with `u`.

## Open questions for Phil

1. Diff base key — `space d` + which-key, or cycle with one key?
2. Force — fold into `p` when eligible (above), or keep it a separate, menu-only command?
3. Freeze — still used? It was last set in v1's era; if nothing sets it, drop it instead of porting.
