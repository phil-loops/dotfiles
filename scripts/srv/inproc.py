# srv/inproc.py — run a stack-* Python script inside the server instead of spawning it.
#
# A /node or /model fetch used to start a fresh interpreter for stack-forest (~0.1s before its
# first git call, far more on a loaded machine) whose own git calls the server could neither see
# nor answer. Here the script's compiled code runs per call in a fresh namespace: its `sys`,
# `subprocess` and `print` are proxies, so argv/exit/stdout stay local to the call, and every
# `git` it asks goes through fastgit like the server's own. The script file is unchanged and
# still runs standalone; a modified file is recompiled on the next call.
import builtins
import io
import os
import subprocess
import sys
import threading

from . import ctx

_CODE = {}   # path -> (mtime_ns, code object)
_LOCK = threading.Lock()


def _code(path):
    mt = os.stat(path).st_mtime_ns
    with _LOCK:
        hit = _CODE.get(path)
        if hit and hit[0] == mt:
            return hit[1]
    with open(path) as fh:
        code = compile(fh.read(), path, "exec")
    with _LOCK:
        _CODE[path] = (mt, code)
    return code


class _Sys:
    def __init__(self, argv, out, err):
        self.argv, self.stdout, self.stderr = argv, out, err

    def exit(self, code=0):
        raise SystemExit(code)

    def __getattr__(self, name):
        return getattr(sys, name)


class _Subprocess:
    """subprocess for the script: git questions go to fastgit, everything runs in the repo the
    request is bound to — the script's thread pools don't inherit the request's thread-local."""

    def __init__(self, repo):
        self.repo = repo

    def run(self, args, input=None, cwd=None, **kw):
        from . import fastgit
        if args and args[0] == "git" and input is None and cwd is None:
            ctx.set_repo(self.repo)
            hit = fastgit.answer(args[1:])
            if hit is not None:
                return hit
        return subprocess.run(args, input=input, cwd=cwd or self.repo, **kw)

    def __getattr__(self, name):
        return getattr(subprocess, name)


def run(path, argv):
    """The script's CompletedProcess, as if spawned with cwd = the request's repo."""
    repo = ctx.repo_cwd()
    out, err = io.StringIO(), io.StringIO()
    fake_sys, fake_sp = _Sys([path, *argv], out, err), _Subprocess(repo)

    def _import(name, globals=None, locals=None, fromlist=(), level=0):
        if name == "sys":
            return fake_sys
        if name == "subprocess":
            return fake_sp
        return builtins.__import__(name, globals, locals, fromlist, level)

    def _print(*a, file=None, **kw):
        builtins.print(*a, file=file if file is not None else out, **kw)

    bi = dict(vars(builtins), __import__=_import, print=_print)
    rc = 0
    try:
        exec(_code(path), {"__name__": "__main__", "__file__": path, "__builtins__": bi})
    except SystemExit as e:
        rc = e.code if isinstance(e.code, int) else (0 if e.code is None else 1)
    except Exception as e:
        err.write(f"{type(e).__name__}: {e}\n")
        rc = 1
    return subprocess.CompletedProcess([path, *argv], rc, out.getvalue(), err.getvalue())
