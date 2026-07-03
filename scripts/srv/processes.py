# srv/processes.py — GET /processes: one read-only view of everything the viewer set in
# motion that's still running. Fans in three sources that already exist separately —
# chat jobs (chat._JOBS), restack drivers (restack._drivers), and fired stack-claude runs
# (pgrep, the way restack finds its own drivers) — and normalizes them so the Activity dock
# renders one list regardless of kind. Fired claudes are the real gap: nothing else in the
# viewer surfaces them, so a coding agent you kicked off runs invisibly until now.
import json
import os
import subprocess
import time

from . import ctx
from . import chat
from . import restack


def _age(created_sec):
    s = max(0, int(time.time() - created_sec))
    return f"{s}s" if s < 60 else f"{s // 60}m" if s < 3600 else f"{s // 3600}h"


def _live_claude_pid(pane_pid):
    # A fired claude may BE the pane's foreground process, or run as a CHILD of the pane's shell —
    # /reconcile and /restack-resolve launch `claude` under zsh, so pane_current_command reads `zsh`
    # while the agent is very much alive. So liveness is the pane's process tree, not the pane
    # command: check the pane pid and its direct children for a claude/node. None → a bare shell
    # (agent finished) → skip. Returns the agent's own pid so etime is its runtime, not the shell's.
    kids = subprocess.run(["pgrep", "-P", str(pane_pid)], capture_output=True, text=True).stdout.split()
    for p in (str(pane_pid), *kids):
        comm = subprocess.run(["ps", "-o", "comm=", "-p", p], capture_output=True, text=True).stdout.strip()
        if os.path.basename(comm) in ("claude", "node"):
            return int(p)
    return None


def _fired_claudes():
    # Fired coding agents — the ask-Claude chip, /reconcile, and /restack-resolve — each run in a
    # tmux window named `claude:<branch>`. The window name is the seam; liveness is the pane's
    # process tree (see _live_claude_pid) — filtering on pane_current_command missed reconcile/
    # resolve, which run claude under the pane shell, so the exact agents this was meant to surface.
    fmt = "#{window_name}\t#{pane_pid}"
    out = subprocess.run(["tmux", "list-windows", "-a", "-F", fmt],
                         capture_output=True, text=True).stdout
    by_branch = {}
    for line in out.splitlines():
        parts = line.split("\t")
        if len(parts) < 2:
            continue
        name, pid = parts[0], parts[1]
        if not name.startswith("claude:") or not pid.isdigit():
            continue
        branch = name[len("claude:"):]
        if not branch or branch in by_branch:
            continue
        live = _live_claude_pid(int(pid))
        if live:
            by_branch[branch] = live
    if not by_branch:
        return []
    ps = subprocess.run(["ps", "-o", "pid=,etime=", "-p", ",".join(str(p) for p in by_branch.values())],
                        capture_output=True, text=True).stdout
    etimes = {}
    for line in ps.splitlines():
        p = line.split()
        if len(p) == 2 and p[0].isdigit():
            etimes[int(p[0])] = p[1].strip()
    return [{"pid": pid, "etime": etimes.get(pid, ""), "branch": b} for b, pid in by_branch.items()]


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

    # fired claudes — coding agents in worktrees, otherwise invisible in the viewer
    for f in _fired_claudes():
        procs.append({
            "kind": "claude", "id": str(f["pid"]),
            "label": f["branch"] or "worktree", "target": f["branch"],
            "status": "editing", "detail": f["etime"], "done": False, "age": f["etime"],
        })

    procs.sort(key=lambda p: (p.get("done", False),))
    req._send(200, json.dumps(procs))
