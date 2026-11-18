"""One writer per forest (tooling-doctor P2): every tool that moves a forest's branch refs holds the
forest's lock while it does — the server's ref-moving endpoints, stack-restack, focus-sync (which
skips a held forest rather than wait), and agents' raw git through `forest-lock`.

A kernel lock (flock) on `<git-common-dir>/stack-forest-<project>.lock`, so it dies with its holder
however the holder dies; the file's content names the holder so a refusal can say who. A branch
outside any forest locks alone (`stack-branch-<name>.lock`). Re-entry: an operation already inside
the lock exports STACK_FOREST_LOCKED=<key>, and a nested tool for the same key doesn't take it again
(a fresh flock from a child would wait on its own parent)."""
import contextlib
import fcntl
import json
import os
import re
import subprocess
import time

ENV = "STACK_FOREST_LOCKED"
_SCRUB = ("GIT_DIR", "GIT_INDEX_FILE", "GIT_WORK_TREE", "GIT_PREFIX")


class Held(Exception):
    """The forest is held by someone else; str() says who."""


def _git(cwd, *args):
    env = {k: v for k, v in os.environ.items() if k not in _SCRUB}
    return subprocess.run(["git", *args], cwd=cwd, capture_output=True, text=True, env=env)


def key_for(cwd, project="", branch=""):
    """The lock key: the forest of `branch` (or `project` itself); a branch outside any forest locks alone."""
    if not project and branch:
        project = _git(cwd, "config", f"branch.{branch}.stack-project").stdout.strip()
    if project:
        return "forest-" + re.sub(r"[^A-Za-z0-9._-]", "_", project)
    return "branch-" + re.sub(r"[^A-Za-z0-9._-]", "_", branch or "unknown")


def path_for(cwd, key):
    common = _git(cwd, "rev-parse", "--path-format=absolute", "--git-common-dir").stdout.strip()
    return os.path.join(common, f"stack-{key}.lock")


def holder(path):
    try:
        with open(path) as f:
            return json.load(f)
    except (OSError, ValueError):
        return {}


def describe(rec):
    who = rec.get("who") or "another process"
    since = rec.get("since")
    age = f" for {int(time.time() - since)}s" if isinstance(since, (int, float)) else ""
    return f"{who} (pid {rec.get('pid', '?')}){age}"


def held(cwd, key):
    """The holder record while a live process holds `key`, else None."""
    p = path_for(cwd, key)
    try:
        fd = os.open(p, os.O_RDONLY)
    except OSError:
        return None
    try:
        fcntl.flock(fd, fcntl.LOCK_SH | fcntl.LOCK_NB)
    except BlockingIOError:
        return holder(p) or {"who": "another process"}
    finally:
        os.close(fd)
    return None


@contextlib.contextmanager
def hold(cwd, key, who, wait=30.0, export=True):
    """Hold `key` for the block. wait=0 tries once; raises Held when someone else keeps it.
    export=True sets ENV for the block so nested tools for the same key don't re-take it; the
    threaded server passes False (a process-wide env var would let another thread skip the lock)."""
    if export and os.environ.get(ENV) == key:
        yield
        return
    p = path_for(cwd, key)
    fd = os.open(p, os.O_RDWR | os.O_CREAT, 0o644)
    deadline = time.monotonic() + wait
    try:
        while True:
            try:
                fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
                break
            except BlockingIOError:
                if time.monotonic() >= deadline:
                    raise Held(f"{key.split('-', 1)[1]} is being changed by {describe(holder(p))} — try again when it's done")
                time.sleep(0.1)
        os.ftruncate(fd, 0)
        os.write(fd, json.dumps({"who": who, "pid": os.getpid(), "since": time.time()}).encode())
        if not export:
            yield
            return
        before = os.environ.get(ENV)
        os.environ[ENV] = key
        try:
            yield
        finally:
            if before is None:
                os.environ.pop(ENV, None)
            else:
                os.environ[ENV] = before
    finally:
        os.close(fd)   # releases the flock; a death releases it the same way
