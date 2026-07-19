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
from . import preview


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
            "working": not j.done, "count": 1,
        })

    # restack drivers — a rebase walking a forest (Hearth alarms on tangles; this just lists them)
    for d in restack._drivers():
        procs.append({
            "kind": "restack", "id": str(d["pid"]),
            "label": d["project"] or "all projects",
            "target": d["project"], "status": d["mode"],
            "detail": d["etime"].strip(), "done": False, "age": d["etime"].strip(),
            "working": True, "count": 1,
        })

    # fired agents — every launcher registers itself when it spawns (agents.live()), so a new fire
    # path can't go missing without any tmux/pgrep discovery. Each carries a heartbeat (working?) and
    # is deduped per branch; an idle-but-alive agent reads "idle", a finished one lingers as "done".
    for a in agents.live():
        done = a.get("done", False)
        working = a.get("working", False) and not done
        procs.append({
            "kind": "claude", "id": str(a["pid"]),
            "label": a["branch"] or a["kind"], "target": a["branch"], "repo": a.get("repo", ""),
            "status": "done" if done
            else ("resolving" if a["kind"] == "resolver" else "editing") if working
            else "idle",
            "detail": a.get("etime", ""), "done": done, "working": working, "count": a.get("count", 1),
            "age": a["age"] if (done or working) else a.get("idle_age", a["age"]),
        })

    # side-port dev-server previews (loops-preview) — durable tmux sessions that survive a server
    # bounce, so we read them from the script rather than any in-memory registry. Each row carries
    # its url + dir so the dock can open it and kill it (/preview-kill). "up" is working; a "dead"
    # (crashed) or "orphaned" (worktree gone) row lingers as idle so it's visible to reap.
    # Shares preview's TTL snapshot — the dock and the drawer land in the same beat, one shell.
    for pv in preview._list_json():
        up = pv.get("state") == "up"
        procs.append({
            "kind": "preview", "id": pv.get("name", ""),
            "label": pv.get("branch") or pv.get("name", ""),
            "target": pv.get("dir", ""), "dir": pv.get("dir", ""), "url": pv.get("url", ""),
            "status": pv.get("state", ""), "detail": ":" + str(pv.get("port", "")),
            "done": False, "working": up, "age": pv.get("age", ""), "count": 1,
        })

    procs.sort(key=lambda p: (p.get("done", False),))
    req._send(200, json.dumps(procs))
