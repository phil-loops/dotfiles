# srv/callers.py — which production entry points reach what a branch changes (scripts/prod-callers),
# worked out once per (tip, base) off the request thread and kept: the walk asks this server's own
# TypeScript service a few dozen questions and takes a minute or two, so a page never waits on it.
#
#   POST /callers {branch, run?} → {ok, state: "done", tip, base, result}     the kept answer for this tip
#                                | {ok, state: "running", tip, base}          being worked out now
#                                | {ok, state: "absent", tip, base}           never asked for (run: true starts it)
#                                | {ok, state: "failed", tip, base, message}  the last try, until the next run
#
# The answer is keyed by the two commits it was computed from, so a moved branch or parent is simply
# absent again. It lives in this module's own cache dir — a derived read, never a verdict or a git
# config key. Env: STACK_CALLERS_DIR (the cache), STACK_CALLERS_CMD (the script; tests).
import json
import os
import subprocess
import threading

from . import ctx

DIR = os.environ.get("STACK_CALLERS_DIR") or os.path.expanduser("~/Library/Caches/stack-review-callers")
CMD = os.environ.get("STACK_CALLERS_CMD") or os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "prod-callers")
TIMEOUT = 900
_lock = threading.Lock()
_running, _failed = {}, {}


def _out(repo, *args):
    r = subprocess.run(["git", "-C", repo, *args], capture_output=True, text=True)
    return r.stdout.strip() if r.returncode == 0 else ""


def commits(repo, branch):
    """(tip, base) the answer is about: the branch's tip and where it left its parent (main without one)."""
    tip = _out(repo, "rev-parse", "--verify", "--quiet", f"refs/heads/{branch}")
    parent = _out(repo, "config", f"branch.{branch}.stack-parent") or "main"
    return tip, (_out(repo, "merge-base", parent, tip) if tip else "")


def _path(tip, base):
    return os.path.join(DIR, f"{tip}-{base}.json")


def _work(repo, port, tip, base, key):
    try:
        r = subprocess.run([CMD, tip, "--base", base, "--repo", repo, "--port", str(port), "--json"],
                           capture_output=True, text=True, timeout=TIMEOUT)
        result = json.loads(r.stdout) if r.returncode == 0 else None
        if not isinstance(result, dict):
            raise ValueError((r.stderr or "prod-callers gave no answer").strip().splitlines()[-1][:300])
        os.makedirs(DIR, exist_ok=True)
        tmp = _path(tip, base) + f".{os.getpid()}.tmp"
        with open(tmp, "w") as f:
            json.dump(result, f)
        os.replace(tmp, _path(tip, base))
        failed = None
    except (OSError, ValueError, subprocess.TimeoutExpired) as e:
        failed = str(e) or type(e).__name__
    with _lock:
        _running.pop(key, None)
        if failed:
            _failed[key] = failed


def look(repo, port, branch, run=False, start=None):
    tip, base = commits(repo, branch)
    if not tip or not base:
        return None
    key, here = (tip, base), {"ok": True, "tip": tip, "base": base}
    try:
        with open(_path(tip, base)) as f:
            return {**here, "state": "done", "result": json.load(f)}
    except (OSError, ValueError):
        pass
    with _lock:
        if key in _running:
            return {**here, "state": "running"}
        if not run:
            return {**here, "state": "failed", "message": _failed[key]} if key in _failed else {**here, "state": "absent"}
        _failed.pop(key, None)
        thread = threading.Thread(target=_work, args=(repo, port, tip, base, key), daemon=True)
        _running[key] = thread
    (start or thread.start)()
    return {**here, "state": "running"}


def answer(req, raw):
    try:
        d = json.loads(raw or "{}")
        branch = str(d["branch"])
        if not branch or branch.startswith("-"):
            raise KeyError("branch")
    except (ValueError, KeyError, TypeError):
        return req._send(400, json.dumps({"ok": False, "err": "want {branch, run?}"}))
    got = look(ctx.repo_cwd(), req.server.server_address[1], branch, run=bool(d.get("run")))
    if got is None:
        return req._send(404, json.dumps({"ok": False, "err": f"no branch {branch}"}))
    req._send(200, json.dumps(got))
