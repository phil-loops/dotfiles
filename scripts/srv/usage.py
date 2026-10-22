# POST /track — append local usage events (nav / cmd / action / …; one, or a batch) to a JSONL log in the
# git-common-dir, so it survives across worktrees and is never committed. Single-user,
# never leaves the machine. Best-effort: a telemetry failure must never break a user
# action, so every path still returns 200. Kill switch: STACK_USAGE=0.
import os
import json
import time

from . import ctx, telemetry


def _usage_file():
    gd = ctx.run(["git", "rev-parse", "--git-common-dir"]).stdout.strip()
    if gd and not os.path.isabs(gd):
        gd = os.path.join(ctx.CWD, gd)
    return os.path.join(gd, "stack-usage.jsonl") if gd else ""


BATCH_MAX = 200


def track(req, raw):
    # one event, or {"type": "batch", "events": [...]} — v2 batches its events and flushes by
    # sendBeacon; each is stamped and appended exactly as a single post would be
    try:
        if os.environ.get("STACK_USAGE") != "0":
            ev = json.loads(raw or "{}")
            path = _usage_file()
            evs = ev.get("events") if isinstance(ev, dict) and ev.get("type") == "batch" else [ev]
            lines = []
            now = int(time.time())
            for e in (evs or [])[:BATCH_MAX]:
                if not isinstance(e, dict) or not e.get("type") or e.get("type") == "batch":
                    continue
                e["ts"] = now
                # stamped from the request, never trusted from the body: a headless run posting
                # /track must not read as Phil
                e["actor"] = getattr(req, "_actor", None) or "unknown"
                if getattr(req, "_sid", None):
                    e["session"] = req._sid
                lines.append(json.dumps(e) + "\n")
            if path and lines:
                telemetry.rotate_usage(path)
                with open(path, "a") as f:
                    f.write("".join(lines))
    except Exception:
        pass
    req._send(200, '{"ok":true}')
