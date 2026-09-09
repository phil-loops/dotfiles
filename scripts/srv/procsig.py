# srv/procsig.py — one fingerprint of everything the viewer polls that is NOT git: chat turns,
# fired agents, restack drivers and their state files, the ambient daemon's reports, the
# preview servers. The pulse thread reads it ~1/s while an /events stream is open and pushes
# `event: procs` on change, so the pages drop their per-query timers (2s–15s, nine of them)
# for one server-side check whose cost is bounded here: in-memory dicts and file mtimes every
# beat, the two process scans (pgrep for drivers, loops-preview --json) on their own throttles.
import glob
import hashlib
import json
import os
import time

from . import chat, agents, restack, preview

_DRIVERS = {"at": 0.0, "val": ""}
_DRIVERS_TTL = 5.0
_PREVIEWS_TTL = 10.0


def _mt(path):
    try:
        return str(os.path.getmtime(path))
    except OSError:
        return "-"


_AGENTS = {"at": 0.0, "val": ""}
_AGENTS_TTL = 5.0


def _agents():
    # agents.live() spawns several ps/pgrep per registered agent (heartbeat, lstart, children):
    # fine on a 5s clock, not on the beat
    now = time.monotonic()
    if now - _AGENTS["at"] > _AGENTS_TTL:
        try:
            _AGENTS["val"] = json.dumps(agents.live(), sort_keys=True, default=str)
        except Exception:
            _AGENTS["val"] = "agents?"
        _AGENTS["at"] = now
    return _AGENTS["val"]


def _drivers():
    now = time.monotonic()
    if now - _DRIVERS["at"] > _DRIVERS_TTL:
        try:
            _DRIVERS["val"] = json.dumps(restack._drivers(), sort_keys=True)
        except Exception:
            _DRIVERS["val"] = "?"
        _DRIVERS["at"] = now
    return _DRIVERS["val"]


def sig():
    parts = []
    with chat._JOBS_LOCK:
        parts.append(json.dumps(sorted((t, j.status, j.done, j.chars) for t, j in chat._JOBS.items()), default=str))
    parts.append(_agents())
    parts.append(_drivers())
    try:
        gd = restack._gitdir()
        parts += [_mt(os.path.join(gd, "restack-ambient.json")), _mt(os.path.join(gd, "restack-merges.json"))]
    except Exception:
        parts.append("gitdir?")
    try:
        parts.append(_mt(restack._state_path() or ""))
    except Exception:
        parts.append("state?")
    # the preview scan is a multi-second shell (tmux/lsof/meta) — never run it on the beat.
    # Hash whatever the shared cache holds, and let it refresh on its own slower clock: the
    # pages that showed this used 3–10s timers, so 10s here loses nothing they had.
    try:
        age = time.monotonic() - preview._list_cache["at"]
        data = preview._list_json() if age > _PREVIEWS_TTL or preview._list_cache["data"] is None else preview._list_cache["data"]
        parts.append(json.dumps(data, sort_keys=True, default=str))
    except Exception:
        parts.append("previews?")
    parts.append(",".join(sorted(os.path.basename(p) for p in glob.glob("/tmp/loops-preview-*.meta"))))
    return hashlib.sha1("\x1e".join(parts).encode()).hexdigest()
