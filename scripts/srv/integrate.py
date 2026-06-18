# srv/integrate.py — integrate-preview for a project's ghost "feature" node.
#   POST /integrate {project}  → does the whole project land on main cleanly?
import json
import os

from . import ctx


def check(req, raw):
    project = json.loads(raw or "{}").get("project", "")
    if not project:
        req._send(400, json.dumps({"ok": False, "err": "no project"}))
        return
    # stack-integrate <project> --check octopus-merges the project's leaves onto main in an
    # ephemeral refs/stack/ ref (never a branch, never pushed) and exits 0 clean / 1 on
    # conflict (printing the conflicting leaves) / 2 on a bad project.
    r = ctx.run([os.path.join(ctx.SCRIPTS, "stack-integrate"), project, "--check"])
    req._send(200, json.dumps({
        "ok": r.returncode != 2,
        "project": project,
        "clean": r.returncode == 0,
        "detail": (r.stdout + r.stderr).strip()[:1000],
    }))
