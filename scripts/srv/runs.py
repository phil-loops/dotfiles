# srv/runs.py — a run: a process that outlives the request that started it AND the server image
# that watched it (the server re-execs itself on every srv/*.py change). Everything about a run is
# a file in its directory, so any server image can find it, tail it and judge it:
#
#   ~/.cache/canopy/runs/<kind>/<key>/
#       run.json   {kind, key, id, argv, cwd, pid, started, meta} — written once at start
#       <out>      the process's own stdout (and stderr unless split) — it writes the file itself,
#                  no pipe to the server, so a server restart never cuts it off
#       exit       its exit status, written by the launcher when it ends on its own
#       stopped    a reader asked for the kill — an ending, not a failure
#       <marker>   once-only side effects a follower already performed (e.g. `applied`)
#
# A run is over when `exit` exists, or its process is gone (died without one: killed, crashed).
# One run per (kind, key): starting again replaces a finished run's directory; a live one refuses.
import json
import os
import shutil
import signal
import subprocess
import time
from urllib.parse import quote

ROOT = os.environ.get("CANOPY_RUNS") or os.path.expanduser("~/.cache/canopy/runs")

# "$@" runs the command; the status lands atomically once it returns. A signal that kills the
# launcher (a stop, a crash of the group) leaves no `exit` — dead pid + no exit = it died.
LAUNCHER = '"$@"; s=$?; echo $s > "$RUN_DIR/exit.tmp" && mv "$RUN_DIR/exit.tmp" "$RUN_DIR/exit"; exit $s'


class Busy(Exception):
    """A live run already holds this (kind, key)."""


def _dir(kind, key):
    k = quote(key, safe="")
    if not k or k.startswith("."):
        k = "%2E" + k[1:] if k else "%00"
    return os.path.join(ROOT, quote(kind, safe=""), k)


class Run:
    def __init__(self, path):
        self.dir = path
        with open(os.path.join(path, "run.json")) as f:
            self.info = json.load(f)

    kind = property(lambda self: self.info["kind"])
    key = property(lambda self: self.info["key"])
    id = property(lambda self: self.info["id"])
    pid = property(lambda self: self.info["pid"])
    started = property(lambda self: self.info["started"])
    meta = property(lambda self: self.info.get("meta") or {})

    def path(self, name):
        return os.path.join(self.dir, name)

    def exit_code(self):
        try:
            with open(self.path("exit")) as f:
                return int(f.read().strip())
        except (OSError, ValueError):
            return None

    def alive(self):
        if os.path.exists(self.path("exit")):
            return False
        try:
            # a re-exec'd server is still the launcher's parent: reap it, or its zombie looks alive
            wpid, _ = os.waitpid(self.pid, os.WNOHANG)
            if wpid == self.pid:
                return False
        except ChildProcessError:
            pass
        try:
            os.kill(self.pid, 0)
            return True
        except OSError:
            return False

    def stop(self, sig=signal.SIGTERM):
        """Kill the whole process group; the `stopped` marker tells every follower it was asked for."""
        self.mark("stopped")
        try:
            os.killpg(self.pid, sig)
        except (ProcessLookupError, PermissionError):
            pass

    def mark(self, name, data=""):
        tmp = self.path(name + ".tmp")
        with open(tmp, "w") as f:
            f.write(data)
        os.replace(tmp, self.path(name))

    def marked(self, name):
        return os.path.exists(self.path(name))

    def marker(self, name):
        try:
            with open(self.path(name)) as f:
                return f.read()
        except OSError:
            return None

    def read(self, name, offset=0):
        """Bytes of `name` from `offset` on, and the offset to read from next."""
        try:
            with open(self.path(name), "rb") as f:
                f.seek(offset)
                data = f.read()
        except OSError:
            return b"", offset
        return data, offset + len(data)


def dir_of(kind, key):
    """Where the run (kind, key) lives — for arguments that must name a file in it before it starts."""
    return _dir(kind, key)


def start(kind, key, argv, cwd, meta=None, out="out.log", err=None, env=None, seed=None):
    """Launch `argv` as the run (kind, key). stdout goes to `out` in the run's directory, stderr to
    `err` (or alongside stdout); `seed` {name: text} files exist before it starts. Raises Busy when
    a live run holds the key."""
    d = _dir(kind, key)
    old = find(kind, key)
    if old and old.alive():
        raise Busy(f"{kind} {key} is running (pid {old.pid})")
    shutil.rmtree(d, ignore_errors=True)
    os.makedirs(d)
    for name, text in (seed or {}).items():
        with open(os.path.join(d, name), "w") as f:
            f.write(text)
    started = time.time()
    run_id = f"{started:.6f}".replace(".", "")
    with open(os.path.join(d, out), "wb") as o, open(os.path.join(d, err or out), "ab") as e:
        proc = subprocess.Popen(["/bin/sh", "-c", LAUNCHER, "run", *argv], cwd=cwd, stdin=subprocess.DEVNULL,
                                stdout=o, stderr=e, start_new_session=True,
                                env={**(env or os.environ), "RUN_DIR": d})
    info = {"kind": kind, "key": key, "id": run_id, "argv": argv, "cwd": cwd, "pid": proc.pid,
            "started": started, "meta": meta or {}}
    tmp = os.path.join(d, "run.json.tmp")
    with open(tmp, "w") as f:
        json.dump(info, f)
    os.replace(tmp, os.path.join(d, "run.json"))
    # Popen would otherwise queue the child for its own reaping and race alive(); the run's files
    # are the truth, and alive() reaps it
    proc.returncode = 0
    return Run(d)


def find(kind, key):
    try:
        return Run(_dir(kind, key))
    except (OSError, ValueError, KeyError):
        return None


def every(kind):
    base = os.path.join(ROOT, quote(kind, safe=""))
    out = []
    for name in os.listdir(base) if os.path.isdir(base) else []:
        try:
            out.append(Run(os.path.join(base, name)))
        except (OSError, ValueError, KeyError):
            continue
    return out


def prune(kind, older_than):
    """Delete finished runs started more than `older_than` seconds ago."""
    cut = time.time() - older_than
    for r in every(kind):
        if r.started < cut and not r.alive():
            shutil.rmtree(r.dir, ignore_errors=True)
