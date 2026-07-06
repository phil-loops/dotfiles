---
name: loops-restart
description: Find every running loops instance (dev stack + preview servers), kill them all, rebuild packages, and restart the :3000 service and its dependencies cleanly — including when it's running out of the wrong worktree or a Docker port is "already allocated". Use when the user says "restart the dev server", "kill and restart dev", "rebuild + restart", "my dev server is in the wrong checkout", "port already allocated", or the dev stack is wedged.
---

# Loops Dev Restart

Identifies **every** running loops instance — the `task dev` stack, `next dev` preview servers on :3010+, anything listening on the dev/preview ports from a `~/coding/loops*` checkout — kills them all, and brings the :3000 service and its dependencies back up in the intended checkout. Wraps `~/.dotfiles/scripts/loops-restart`.

## Why a dedicated tool

Killing the dev server is more than `pkill node`:

- **The node processes are not the whole stack.** `task dev` also starts a Docker compose project (psql, minio, clickhouse, valkey, elasticmq, …). Killing only the node tree leaves those containers holding `:5432 / :9000 / :8123 / …`, so a restart in a *different* checkout dies on `Bind for 0.0.0.0:9000 failed: port is already allocated`.
- **Runaway previews accumulate.** `loops-preview` side servers (:3010+) outlive the sessions that started them. The script enumerates them alongside the dev stack and kills all of it — including their `loops-preview-*` tmux sessions — in one motion.
- **The dev server can be running out of a stale worktree.** The script discovers where it's actually running and can relocate it to the main checkout.
- **Kill must be precise.** Targeting "every process whose cwd is the checkout" is a footgun in the main checkout (also the cwd of the stack viewer, shells, editors). The script kills by **process group**, only groups rooted in `~/coding/loops*`, and never a `claude` session.
- **`docker compose down` destroys the dev database.** The psql service has **no volume** — its data dies with the container. The script therefore only downs the compose project when relocating checkouts or on `--reset`; a same-checkout `--keep` restart leaves the containers (and your data) running. If the DB does come up empty, it migrates + reseeds (via `tsx --import dotenv/config` — Prisma 7's `prisma db seed` no longer loads `.env` and dies on missing `DEV_EMAIL`).

## Usage

```bash
loops-restart [--dir <checkout>] [--reset|--keep] [--no-restart] [--dry-run]
```

- `--dir <path>` — checkout to restart in. **Default `~/coding/loops`** (main).
- `--keep` *(default)* — `task dev:watch`: rebuild packages + restart node services. Same-checkout: docker and dev data untouched. Relocating: compose moves (which wipes the DB — psql has no volume) and the empty DB is reseeded.
- `--reset` — `task dev`: `prisma migrate reset --force` + reseed + `clickhouse:reset`. Fresh slate, **destroys dev data**.
- `--no-restart` — kill all instances (+ docker-down if relocating) only.
- `--dry-run` — print the full inventory of instances it would kill / what docker would do; touches nothing.

Always: runs the server in a detached **tmux session `loops-dev`** logging to **`/tmp/loops-dev.log`** (which the `dev-tail` skill reads), so it outlives the shell.

## How to drive it

1. **The default flow is "kill all, restart :3000 in main".** Confirm the two choices that change outcomes: which checkout (`--dir`, default main) and `--reset` vs `--keep` (default). Don't assume `--reset`.
2. **`--dry-run` first** — it prints the full inventory (each process group with its checkout, plus preview tmux sessions). Show it to the user when anything looks unusual; killing previews is expected, but a preview another session started *minutes ago* may be worth flagging.
3. Run for real. Then verify: `tmux ls | grep loops-dev`, `tail -n 30 /tmp/loops-dev.log`, and `lsof -iTCP:3000 -sTCP:LISTEN` — don't declare done until :3000 answers.
4. Hand back: `tmux attach -t loops-dev` to watch, `dev-tail` skill to diagnose.

## Don't

- Don't kill `claude` processes — the script never does; neither should you.
- Don't `docker compose down` by hand in keep mode — psql has no volume, so down = data wipe. Let the script decide (it only downs on relocate/reset).
- Don't run it to "pick up a viewer (:62333) change" — that's a different server; this is the app dev stack only.
