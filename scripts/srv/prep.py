# srv/prep.py — the "prep to push" state ROUTER. The node header's one prep button asks
# what motion this branch needs next and delegates to the endpoint that already does it —
# the verdict machinery lives here, not in a row of peer buttons. (Message editing lives in
# the viewer session's POST /prep-message, which owns the reseat-after-rewrite; an earlier
# /outgoing-commit editor here was retired as its duplicate.)
#
#   GET /prep-route?branch=X    what prep would do next: {route, why, next?, outgoing}
import json
from urllib.parse import parse_qs

from . import ctx
from . import push
from . import sync


def _outgoing(branch):
    # commits origin doesn't have, newest first — the same rule /push-preview enforces:
    # a stacked branch's parent commits (already on origin via the parent) never count.
    has_remote = ctx.run(["git", "rev-parse", "--verify", "-q",
                          f"refs/remotes/origin/{branch}"]).returncode == 0
    range_args = [f"origin/{branch}..{branch}"] if has_remote else [branch, "--not", "--remotes=origin"]
    return ctx.run(["git", "rev-list", *range_args]).stdout.split()


def _commit(sha):
    subject = ctx.run(["git", "log", "-1", "--format=%s", sha]).stdout.strip()
    body = ctx.run(["git", "log", "-1", "--format=%b", sha]).stdout.strip()
    stat = ctx.run(["git", "show", "--shortstat", "--format=", sha]).stdout.strip()
    return {"sha": sha[:10], "subject": subject, "body": body, "stat": stat}


def route(req, u):
    # GET /prep-route?branch=X — read-only: classify the branch and name the ONE next motion.
    # Routes, in precedence order:
    #   dirty        — uncommitted files in the holding worktree: fold or stash → POST /dirty-resolve
    #   push-vehicle — diverged w/ open PR and the additive vehicle exists: push it (no next)
    #   additive     — diverged w/ open PR: draft the vehicle        → POST /diverged-additive
    #   restack      — behind origin/main, unpublished root          → POST /sync
    #   nothing      — outgoing set is empty: everything is shared
    #   squash       — >1 outgoing, or a WIP subject: collapse/voice → POST /prep
    #   ready        — exactly one voiced commit (needsBody flags an empty why)
    branch = (parse_qs(u.query).get("branch", [""]) or [""])[0]
    if not branch or ctx.run(["git", "rev-parse", "--verify", "--quiet",
                              f"refs/heads/{branch}"]).returncode != 0:
        req._send(404, json.dumps({"ok": False, "err": f"no local branch {branch}"}))
        return
    h = sync.state(branch)
    main = ctx.run(["git", "config", "stack.main-branch"]).stdout.strip() or "main"
    up = sync._upstream_state(branch, main)

    def send(route_name, why, next_call=None, **extra):
        req._send(200, json.dumps({"ok": True, "branch": branch, "route": route_name,
                                   "why": why, "next": next_call, **extra}))

    # dirt outranks everything: every motion below (additive draft, rebase, squash) needs a
    # clean tree, and a "ready" verdict over uncommitted files lies to the push button.
    if h.get("dirty"):
        n = len(h["dirty"])
        send("dirty",
             f"{n} uncommitted file{'s' if n != 1 else ''} in "
             f"{h.get('dirtyWorktree') or 'the holding worktree'} — fold into the outgoing "
             "commit or stash before this branch can be ready",
             {"method": "POST", "path": "/dirty-resolve",
              "body": {"branch": branch, "action": "include | stash"}},
             dirty=h["dirty"], dirtyWorktree=h.get("dirtyWorktree", ""))
        return

    if up.get("diverged") and h.get("published"):
        vehicle = f"{branch}-additive"
        if ctx.run(["git", "rev-parse", "--verify", "--quiet",
                    f"refs/heads/{vehicle}"]).returncode == 0:
            send("push-vehicle",
                 f"the additive update is drafted on {vehicle} — pushing it fast-forwards the PR",
                 push_cmd=f"git push origin {vehicle}:{branch}", vehicle=vehicle)
            return
        send("additive",
             "local diverged from the pushed PR head — draft one commit on top of it "
             "carrying local's content (history preserved, never a force-push)",
             {"method": "POST", "path": "/diverged-additive", "body": {"branch": branch}})
        return

    if h.get("syncable"):
        send("restack",
             f"{h.get('behind', 0)} behind origin/{main} and safely rebasable "
             "(unpublished root) — restack first so the push carries a current base",
             {"method": "POST", "path": "/sync", "body": {"branch": branch}})
        return

    outgoing = _outgoing(branch)
    if not outgoing:
        send("nothing", "everything here is already shared with origin", outgoing=None)
        return
    tip = _commit(outgoing[0])
    if len(outgoing) > 1 or push._WIP_SUBJECT.match(tip["subject"]):
        send("squash",
             (f"{len(outgoing)} unpushed commits" if len(outgoing) > 1
              else "the unpushed commit has a WIP subject")
             + " — collapse the unpushed tail to one voiced commit",
             {"method": "POST", "path": "/prep", "body": {"branch": branch}},
             outgoing={"count": len(outgoing), "tip": tip})
        return
    send("ready",
         "one voiced commit outgoing"
         + ("" if tip["body"] else " — no body (optional; add a why if it helps a reviewer)"),
         outgoing={"count": 1, "tip": tip}, needsBody=not tip["body"])
