# srv/push.py — the "prepare to push" mobile flow's gate + push endpoints.
#
#   POST /gates  {branch}  → run stack-gates in the branch's worktree; JSON verdict
#   POST /push   {branch}  → fast-forward push to a SAFE remote (never origin); the
#                            repo's pre-push hook (stack-prepush-guard) still runs,
#                            so WIP commits are blocked at the door regardless.
import json
import os
import re

from . import ctx


def delta_tests(req, raw):
    # Run the tests RELATED to the branch's delta (stack-delta-tests: each changed X.ts's
    # co-located X.test.ts, plus changed *.test.ts). The prep-to-merge pipeline calls this
    # AFTER checkout, so it runs in the main checkout (HEAD = branch, real node_modules).
    d = json.loads(raw or "{}")
    branch = d.get("branch", "")
    r = ctx.run([os.path.join(ctx.SCRIPTS, "stack-delta-tests"), "--branch", branch])
    out = (r.stdout or "") + (r.stderr or "")

    def _n(label):
        # node:test summary lines are "<symbol> <label> <n>" — `ℹ ` under tsx, `# ` under plain
        # node. (`ℹ` is isalnum/\w, so a \W-class won't consume it — match one leading token.)
        m = re.search(rf"^\S* {label} (\d+)\s*$", out, re.M)
        return int(m.group(1)) if m else None

    total = _n("tests")
    tail = "\n".join(l for l in out.splitlines() if l.strip())[-2000:]
    req._send(200, json.dumps({
        "ok": r.returncode == 0,
        "ran": total is not None,                    # tsx printed a summary ⇒ tests executed
        "noTests": ("no related tests" in out or "nothing to run" in out),
        "passed": _n("pass"),
        "failed": _n("fail"),
        "total": total,
        "summary": tail,
    }))


def gates(req, raw):
    d = json.loads(raw or "{}")
    branch = d.get("branch", "")
    # --fix: a red gate with a remediation (e.g. fresh → rebase onto origin/main, format
    # → oxfmt) gets one auto-fix attempt before the verdict, so the card clears what it can.
    r = ctx.run([os.path.join(ctx.SCRIPTS, "stack-gates"), "--branch", branch, "--fix"])
    # stack-gates always prints a JSON verdict on stdout and exits 0
    req._send(200, r.stdout or json.dumps({"ok": False, "gates": [], "err": r.stderr or "gates crashed"}))


def _safe_remote(branch):
    """A non-origin remote to push to, or (None, reason). origin is read-only here."""
    configured = ctx.run(["git", "config", "stack-push.remote"]).stdout.strip()
    if configured:
        if configured == "origin":
            return None, "stack-push.remote is set to origin — refusing (origin is read-only)"
        return configured, None
    up = ctx.run(["git", "config", f"branch.{branch}.remote"]).stdout.strip()
    if up and up != "origin":
        return up, None
    if up == "origin":
        return None, "branch tracks origin — refusing to push there; set stack-push.remote to a fork"
    return None, "no push remote configured — set `git config stack-push.remote <fork>`"


def push(req, raw):
    d = json.loads(raw or "{}")
    branch = d.get("branch", "")
    if not branch:
        return req._send(400, json.dumps({"ok": False, "err": "no branch"}))

    remote, reason = _safe_remote(branch)
    if not remote:
        return req._send(200, json.dumps({"ok": False, "err": reason}))

    # plain push: never --force (only unpushed commits exist after prep, so it's a
    # fast-forward), and the pre-push guard fires here to block any stray WIP commit.
    r = ctx.run(["git", "push", remote, branch])
    ok = r.returncode == 0
    req._send(200, json.dumps({
        "ok": ok,
        "remote": remote,
        "out": (r.stdout or "").strip(),
        "err": (r.stderr or "").strip(),
    }))
