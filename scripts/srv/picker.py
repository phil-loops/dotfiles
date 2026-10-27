# srv/picker.py — the open-in-nvim actions.
#   POST /open            open a file on a branch in the warm review-nvim
import os
import re
import json
import signal
import subprocess

from . import ctx


def _project_of(branch):
    p = (ctx.run(["git", "config", f"branch.{branch}.stack-project"]).stdout.strip()
         or ctx.run(["git", "config", f"stack-branch.{branch}.project"]).stdout.strip())
    if p:
        return p
    for line in ctx.run(["git", "config", "--get-regexp",
                         r"^stack-project\..*\.branch$"]).stdout.splitlines():
        k, _, v = line.partition(" ")
        if v.strip() == branch:
            m = re.match(r"^stack-project\.(.+)\.branch$", k)
            if m:
                return m.group(1)
    return None


def open_on_branch(branch, path, pos=None):   # open <path> on <branch> in the warm review-nvim
    # pos is an opaque locator forwarded verbatim — stack-open owns the grammar ("<line>" or "<line>:<col>").
    # Returns (code, out, err); code 504 marks a wedged-nvim timeout.
    args = [os.path.join(ctx.SCRIPTS, "stack-open"), branch, path]
    if pos:
        args.append(str(pos))
    # Bound it: stack-open probes the warm review-nvim, which hangs indefinitely if that
    # nvim is wedged (e.g. stuck on a prompt). Without a timeout the /open request — and
    # its server thread — pends forever, and each hung probe leaks an nvim. Run in its own
    # process group and SIGKILL the whole group on timeout so hover+o fails visibly fast
    # instead of spinning, and no zombie probe is left behind.
    proc = subprocess.Popen(args, cwd=ctx.repo_cwd(), stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                            text=True, start_new_session=True)
    try:
        out, err = proc.communicate(timeout=8)
    except subprocess.TimeoutExpired:
        try:
            os.killpg(os.getpgid(proc.pid), signal.SIGKILL)
        except ProcessLookupError:
            pass
        proc.communicate()
        return 504, "", "stack-open timed out — the review-nvim is unresponsive (wedged on a prompt?)"
    return proc.returncode, out, err


def open_here(path, pos=None):   # open <path> in the MAIN working checkout (stack-open --here)
    # For a GitHub blob view: no PR/branch to resolve — land in the editable checkout at the
    # line. Same wedged-nvim guard + 8s bound as open_on_branch.
    args = [os.path.join(ctx.SCRIPTS, "stack-open"), "--here", path]
    if pos:
        args.append(str(pos))
    proc = subprocess.Popen(args, cwd=ctx.repo_cwd(), stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                            text=True, start_new_session=True)
    try:
        out, err = proc.communicate(timeout=8)
    except subprocess.TimeoutExpired:
        try:
            os.killpg(os.getpgid(proc.pid), signal.SIGKILL)
        except ProcessLookupError:
            pass
        proc.communicate()
        return 504, "", "stack-open --here timed out — the review-nvim is unresponsive"
    return proc.returncode, out, err


def review_on_branch(branch):   # open <branch> as the whole-PR gm Diffview in the warm review-nvim
    # mirrors open_on_branch's wedged-nvim guard; the longer timeout covers <leader>gm's
    # origin/main fetch + Diffview build.
    args = [os.path.join(ctx.SCRIPTS, "stack-open"), "--review", branch]
    proc = subprocess.Popen(args, cwd=ctx.repo_cwd(), stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                            text=True, start_new_session=True)
    try:
        out, err = proc.communicate(timeout=20)
    except subprocess.TimeoutExpired:
        try:
            os.killpg(os.getpgid(proc.pid), signal.SIGKILL)
        except ProcessLookupError:
            pass
        proc.communicate()
        return 504, "", "stack-open --review timed out"
    return proc.returncode, out, err


def prepare_branch(branch):   # background worktree prefetch (stack-open --prepare) — fire-and-forget
    return ctx.fire([os.path.join(ctx.SCRIPTS, "stack-open"), "--prepare", branch],
             cwd=ctx.repo_cwd(), start_new_session=True)


def open_file(req, raw):   # POST /open — open a file on a branch in the warm review-nvim
    d = json.loads(raw or "{}")
    code, out, err = open_on_branch(d.get("branch", ""), d.get("path", ""), d.get("pos") or d.get("line"))
    if code == 504:
        req._send(504, json.dumps({"ok": False, "err": err}))
        return
    req._send(200 if code == 0 else 500,
              json.dumps({"ok": code == 0, "out": out, "err": err}))


def steer(req, raw):   # POST /steer — launch the Steer workspace (headless-claude design convo)
    d = json.loads(raw or "{}")
    args = [os.path.join(ctx.SCRIPTS, "steer-open"), d.get("branch", "")]
    p = d.get("path")   # the file the user is focused on; steer-open falls back to top-changed .ts
    if p:
        args.append(p)
    r = ctx.run(args)
    req._send(200 if r.returncode == 0 else 500,
              json.dumps({"ok": r.returncode == 0, "out": r.stdout, "err": r.stderr}))
