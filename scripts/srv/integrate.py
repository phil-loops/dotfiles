# srv/integrate.py — integrate-preview for a project's ghost "feature" node.
#   POST /integrate {project}                 → clean/conflicts + playground worktree status
#   POST /integrate {project, checkout:true}  → refresh/create the playground (kept as-is if it has tracked edits)
#   POST /integrate {project, reset:true}     → FORCE the playground onto the latest integration (discards tracked edits)
import json
import os

from . import ctx



def check(req, raw):
    body = json.loads(raw or "{}")
    project = body.get("project", "")
    reset = bool(body.get("reset"))
    checkout = bool(body.get("checkout")) or reset
    if not project:
        req._send(400, json.dumps({"ok": False, "err": "no project"}))
        return
    # stack-integrate replays the project onto main in merge order into an ephemeral
    # refs/stack/ ref (never a branch, never pushed) and exits 0 clean / 1 on conflict
    # (naming the member that doesn't apply, its commit and the files) / 2 when it couldn't check
    # (a bad project, or git failing without a conflict — never reported as "doesn't merge"). All three modes also emit
    # "k: v" playground-status lines (path / exists / dirty / fresh) on stdout.
    mode = "--worktree-reset" if reset else "--worktree" if checkout else "--status"
    r = ctx.run([os.path.join(ctx.SCRIPTS, "stack-integrate"), project, mode])
    playground = {}
    detail_lines = []
    for line in r.stdout.splitlines():
        s = line.strip()
        if s.startswith("playground: "):
            playground["path"] = s.split(": ", 1)[1]
        elif s.startswith(("exists: ", "dirty: ", "fresh: ")):
            key, _, val = s.partition(": ")
            playground[key] = val == "1"
        elif s:
            detail_lines.append(line)
    req._send(200, json.dumps({
        "ok": r.returncode != 2,
        "project": project,
        "clean": r.returncode == 0,
        "detail": ("\n".join(detail_lines) + r.stderr).strip()[:1000],
        "playground": playground,
    }))

