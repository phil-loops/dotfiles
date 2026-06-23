# HEADS-UP: launchd socket-activation for the :62333 review server

**Patch:** `patches/launchd-socket-activation.patch` (author: srv/restack.py-lane session, 2026-06-18)
**Lane:** viewer (`scripts/stack-review-server.py`) — yours to land.

## What it does

Makes `:62333` socket-activated instead of self-spawned. launchd owns the listening
socket; the server is launched on the first connection and `os._exit(0)`s on idle as
today. When you return to a stale tab, the next `/sig` poll itself relaunches the
server — the ember "reconnecting…" dot mostly disappears, and `/__revive` becomes
unnecessary (the bootstrapping flaw: a dead server has no listener to receive a revive).

## Land it

```bash
git apply --3way patches/launchd-socket-activation.patch   # verified clean vs HEAD cfa4f72
ln -sf ~/.dotfiles/launchd/so.loops.review-server.plist ~/Library/LaunchAgents/
pkill -f "stack-review-server.py"                          # free :62333 from any self-spawn
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/so.loops.review-server.plist
curl -sf http://127.0.0.1:62333/sig && echo " up (socket-activated)"   # the curl wakes it
# unload: launchctl bootout gui/$(id -u)/so.loops.review-server
```

## What the patch contains (additive, gated on `--launchd` — dev runs unaffected)

- **plist** `launchd/so.loops.review-server.plist` — `Sockets` on 127.0.0.1:62333, on-demand
  (no RunAtLoad/KeepAlive), **no inetdCompatibility** (that forks per-connection and would
  shred `_index_cache`/`_pulse`/SSE; we want one long-lived multi-conn server).
- **server bind** — `launchd_socket()` ctypes wrapper around `launch_activate_socket(3)`
  (stdlib doesn't expose it); inherits the fd and skips bind under `--launchd`. Never takes
  the ephemeral-port fallback in launchd mode (would strand tabs on a random port).
- **watcher** — in launchd mode, `os._exit(0)` on srv/*.py change instead of `os.execv`
  (re-exec breaks: `launch_activate_socket` returns EALREADY 2nd call; fd needs
  set_inheritable to survive execv). launchd relaunches fresh on next connection (~0.4s).

## NOT in the patch — two decisions left to you

1. **`stack-review-serve` wrapper slim-down.** It still spawns the process today. Once
   launchd owns the spawn, the wrapper should become "build dist/ if stale → `open` URL"
   (the `open` triggers activation). Its "reuse if live on :62333" curl-check already works
   unchanged against the launchd server, so this is non-urgent — the old wrapper and the
   agent can coexist (whoever binds :62333 first wins; `allow_reuse_address` + pkill above
   avoids a clash).
2. **Who builds `dist/`?** A cold socket-launch has no wrapper in the path. Recommend
   keeping the build in the wrapper (option a) and letting a cold launchd-launch serve the
   last-built dist/ (server already 503s "viewer not built" if absent) — keeps `npm run
   build` out of the request-latency path. Alternative: a build-if-missing in the
   `--launchd` startup.

## Verify after landing

- `curl :62333/sig` cold (server down) should return 200 within ~1s (activation latency).
- Edit a `srv/*.py`, hit any route, confirm the server relaunched with new code (check
  `/tmp/loops-review-server.log`).
- Idle 15min, confirm `os._exit(0)` reap, then a poll revives it.
