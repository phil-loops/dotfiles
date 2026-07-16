# srv/preview.py — spin a side-port `next dev` for a branch, and stop them. Wraps the
# loops-preview script (auto-picks a free 3010-3060 port, borrows MAIN's node_modules/.env
# and the running Docker) so a branch renders in the browser WITHOUT moving the main checkout
# off :3000. The Activity dock lists the running ones (processes.list_all reads loops-preview
# --json) and kills them per-row.
#   POST /preview       {branch}  → {ok, url, port, dir}   start (materialises a worktree if none)
#   POST /preview-kill  {dir}     → {ok}                   stop one (dir-string only; orphan-safe)
#   POST /preview-reap            → {ok, out}              stop orphaned/crashed previews
import json
import os
import re
import subprocess

from . import ctx, checkout


def _script():
    return os.path.join(ctx.SCRIPTS, "loops-preview")


def start(req, raw):
    d = json.loads(raw or "{}")
    branch = d.get("branch", "")
    if not branch:
        req._send(400, json.dumps({"ok": False, "err": "no branch"}))
        return
    # resolve (materialise) the branch's worktree — same synchronous path checkout.worktree opens
    # in Finder, so a watched/PR branch checked out nowhere still gets a tree to run.
    r = ctx.run([os.path.join(ctx.SCRIPTS, "stack-open"), "--path", branch])
    dirp = (r.stdout or "").strip()
    if r.returncode != 0 or not dirp:
        req._send(500, json.dumps({"ok": False, "err": (r.stderr or "could not resolve a worktree").strip()}))
        return
    # loops-preview detaches the server into tmux and returns immediately with the URL on stdout.
    p = subprocess.run([_script(), dirp, "--main", checkout._active_main_wt()], capture_output=True, text=True)
    m = re.search(r"localhost:(\d+)", p.stdout)
    if not m:
        req._send(500, json.dumps({"ok": False, "err": (p.stderr or p.stdout or "preview failed").strip()[:400]}))
        return
    port = int(m.group(1))
    req._send(200, json.dumps({"ok": True, "port": port, "url": "http://localhost:%d" % port, "dir": dirp}))


def kill(req, raw):
    d = json.loads(raw or "{}")
    dirp = d.get("dir", "")
    if not dirp:
        req._send(400, json.dumps({"ok": False, "err": "no dir"}))
        return
    subprocess.run([_script(), dirp, "--kill"], capture_output=True, text=True)
    req._send(200, json.dumps({"ok": True}))


def reap(req, raw):
    p = subprocess.run([_script(), "--reap"], capture_output=True, text=True)
    req._send(200, json.dumps({"ok": True, "out": (p.stdout or "").strip()}))
