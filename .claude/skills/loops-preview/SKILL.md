---
name: loops-preview
description: Preview a loops worktree/branch in the browser on a side port without disturbing the primary dev server or another session's checkout. Use when the user wants to "see this branch", "preview the worktree", "run a second dev server", "view my changes in the browser without killing the main one", or when two checkouts/sessions are sharing one machine and you need to render a non-main branch. Wraps ~/.dotfiles/scripts/loops-preview.
---

# Loops Preview Server

Runs a **web-only** `next dev` for a given loops checkout in a detached tmux
session, on an **auto-picked free port**, reusing the main checkout's
`node_modules` + `.env` and the **already-running Docker services**. Wraps
`~/.dotfiles/scripts/loops-preview`.

## Why a dedicated tool

The full dev stack (`task dev`) is heavy and singular — it owns `:3000`, several
healthcheck ports, and a Docker compose project. You can't just run it twice:

- **Port/Docker collisions.** A second `task dev` dies on `:3000` already in use
  and `Bind … already allocated`. This runs only the **Next app** on a free side
  port (3010+), and reuses the existing Postgres/ClickHouse/Valkey containers — so
  there's one DB, shared by both servers (your seed data is already there).
- **Worktrees lack `node_modules` and untracked `.env`.** A `git worktree` has the
  source but no installed deps and no env file (env is gitignored, lives only in
  the main checkout). The script symlinks both from the main checkout so the app
  boots.
- **Shared-checkout safety.** When two Claude sessions (or you + a session) share
  one machine, restarting/relocating the primary dev server steps on the other.
  This leaves `:3000` and the main checkout untouched — the preview is fully
  isolated in its own tmux session + worktree.

## Usage

```bash
loops-preview [dir] [--port N] [--main path]   # start; dir defaults to $PWD
loops-preview [dir] --kill                      # stop the preview for that dir
loops-preview --list                            # list running previews
```

- `dir` — the worktree/checkout to preview (defaults to current directory).
- `--port N` — force a port (default: first free in 3010–3060).
- `--main path` — main checkout supplying node_modules/.env/Docker (default
  `~/coding/loops`, or `$LOOPS_MAIN`).
- One tmux session per checkout (`loops-preview-<dirname>`), logging to
  `/tmp/loops-preview-<dirname>.log`. Several previews can run at once.

## How to drive it

1. Make sure the **primary dev stack is running** in the main checkout (this reuses
   its Docker services + DB). If Docker is down, start it there first
   (`task docker:compose:up`) or use the `loops-restart` skill.
2. Run `loops-preview /path/to/worktree`. It prints the URL (e.g.
   `http://localhost:3010`), the branch, and the tmux/log handles.
3. First request compiles on demand (~10–20s). Hand the user the URL; offer to
   `open` it. Deep-link admin tabs etc. as needed.
4. Tear down with `loops-preview <dir> --kill` (or `tmux kill-session -t
   loops-preview-<dirname>`).

## Caveat

The preview shares the main checkout's **built workspace packages** (via the
symlinked `node_modules`), so a branch that changes `packages/*` won't reflect
those until the main checkout rebuilds them. App code (`app/`, `pages/`,
`components/`, `trpc/`, `lib/`) compiles from the preview checkout itself, so
UI/route/API changes render fine — which is the common case.

## Don't

- Don't use this to pick up a **package** change — rebuild packages in the main
  checkout (or use `loops-restart`).
- Don't run it when no Docker services are up — the app will boot but every DB
  call fails. Bring the main stack up first.
