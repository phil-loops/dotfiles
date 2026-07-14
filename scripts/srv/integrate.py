# srv/integrate.py — integrate-preview for a project's ghost "feature" node.
#   POST /integrate {project}                 → clean/conflicts + playground worktree status
#   POST /integrate {project, checkout:true}  → refresh/create the playground (kept as-is if it has tracked edits)
#   POST /integrate {project, reset:true}     → FORCE the playground onto the latest integration (discards tracked edits)
#   POST /integrate {project, here:true}      → move the MAIN checkout onto the integration (detached)
import json
import os

from . import checkout as checkout_srv
from . import ctx

INTEG_REF = "refs/stack/{}-integration"


def check(req, raw):
    body = json.loads(raw or "{}")
    project = body.get("project", "")
    reset = bool(body.get("reset"))
    checkout = bool(body.get("checkout")) or reset
    if not project:
        req._send(400, json.dumps({"ok": False, "err": "no project"}))
        return
    # stack-integrate octopus-merges the project's leaves onto main in an ephemeral
    # refs/stack/ ref (never a branch, never pushed) and exits 0 clean / 1 on conflict
    # (printing the conflicting leaves) / 2 on a bad project. All three modes also emit
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


def here(req, raw):
    # The playground's sibling: instead of a scratch worktree you have to `cd` to, put the whole
    # integrated feature in the PRIMARY checkout — the tree the dev server already runs from.
    # Detached, on the same ephemeral refs/stack/ ref: no branch is created, moved, or pushed.
    project = json.loads(raw or "{}").get("project", "")
    if not project:
        req._send(400, json.dumps({"ok": False, "err": "no project"}))
        return
    # --status re-integrates and updates the ref, so we check out what the ghost's badge just
    # verified rather than a stale ref from an earlier preview.
    r = ctx.run([os.path.join(ctx.SCRIPTS, "stack-integrate"), project, "--status"])
    if r.returncode != 0:
        err = "unknown project" if r.returncode == 2 else "the feature does not land clean — resolve the conflicts first"
        req._send(409, json.dumps({"ok": False, "err": err, "detail": (r.stdout + r.stderr).strip()[:1000]}))
        return

    ref = INTEG_REF.format(project)
    main_wt = checkout_srv._active_main_wt()
    prev = ctx.run(["git", "-C", main_wt, "rev-parse", "--abbrev-ref", "HEAD"]).stdout.strip()
    co = ctx.run(["git", "-C", main_wt, "checkout", "--detach", ref])
    if co.returncode != 0:
        req._send(500, json.dumps({"ok": False, "err": (co.stderr or co.stdout or "checkout failed").strip()[:1000]}))
        return
    req._send(200, json.dumps({
        "ok": True,
        "project": project,
        "worktree": main_wt,
        # "HEAD" = it was already detached, so there is no branch name to offer as the way back.
        "prev": "" if prev == "HEAD" else prev,
        "sha": ctx.run(["git", "-C", main_wt, "rev-parse", "--short", "HEAD"]).stdout.strip(),
    }))
