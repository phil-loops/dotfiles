# srv/processes.py — GET /processes: one read-only view of everything the viewer set in motion
# that's still running. Fans in three sources — chat jobs (chat._JOBS), restack drivers
# (restack._drivers), and fired coding agents (agents.live(), the registration seam) — and
# normalizes them so the Activity dock renders one list regardless of kind. Fired agents used to
# need tmux/pgrep archaeology to discover; now every launcher registers itself, so we just read it.
import json
import time

from . import chat
from . import restack
from . import agents


def _age(created_sec):
    s = max(0, int(time.time() - created_sec))
    return f"{s}s" if s < 60 else f"{s // 60}m" if s < 3600 else f"{s // 3600}h"


def list_all(req):
    procs = []
    now = time.time()

    # chat jobs — running now, plus recently-finished so an answer that landed elsewhere lingers
    with chat._JOBS_LOCK:
        snap = list(chat._JOBS.items())
    for turn, j in snap:
        branch = j.meta.get("branch")
        if not branch:
            continue
        if j.done and now - j.created > 900:
            continue
        procs.append({
            "kind": "chat", "id": turn,
            "label": j.meta.get("project") or branch,
            "target": branch, "repo": j.meta.get("repo", ""),
            "project": j.meta.get("project", ""),
            "status": "done" if j.done else j.status,
            "detail": f"{j.chars} chars",
            "done": j.done, "ok": j.ok, "age": _age(j.created),
        })

    # restack drivers — a rebase walking a forest (Hearth alarms on tangles; this just lists them)
    for d in restack._drivers():
        procs.append({
            "kind": "restack", "id": str(d["pid"]),
            "label": d["project"] or "all projects",
            "target": d["project"], "status": d["mode"],
            "detail": d["etime"].strip(), "done": False, "age": d["etime"].strip(),
        })

    # fired agents — every launcher registers itself when it spawns (agents.live()), so a new fire
    # path can't go missing without any tmux/pgrep discovery. kind=resolver renders "resolving".
    for a in agents.live():
        procs.append({
            "kind": "claude", "id": str(a["pid"]),
            "label": a["branch"] or a["kind"], "target": a["branch"], "repo": a.get("repo", ""),
            "status": "resolving" if a["kind"] == "resolver" else "editing",
            "detail": a["etime"], "done": False, "age": a["age"],
        })

    procs.sort(key=lambda p: (p.get("done", False),))
    req._send(200, json.dumps(procs))
