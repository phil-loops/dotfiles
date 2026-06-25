# POST /track — append one local usage event (nav / cmd / action) to a JSONL log in the
# git-common-dir, so it survives across worktrees and is never committed. Single-user,
# never leaves the machine. Best-effort: a telemetry failure must never break a user
# action, so every path still returns 200. Kill switch: STACK_USAGE=0.
import os
import json
import time

from . import ctx


def _usage_file():
    gd = ctx.run(["git", "rev-parse", "--git-common-dir"]).stdout.strip()
    if gd and not os.path.isabs(gd):
        gd = os.path.join(ctx.CWD, gd)
    return os.path.join(gd, "stack-usage.jsonl") if gd else ""


def track(req, raw):
    try:
        if os.environ.get("STACK_USAGE") != "0":
            ev = json.loads(raw or "{}")
            path = _usage_file()
            if path and isinstance(ev, dict) and ev.get("type"):
                ev["ts"] = int(time.time())
                with open(path, "a") as f:
                    f.write(json.dumps(ev) + "\n")
    except Exception:
        pass
    req._send(200, '{"ok":true}')
