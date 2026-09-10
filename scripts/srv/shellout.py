# srv/shellout.py — the ONE place the server takes a stack-* script's word for something.
#
# The scripts and the server talk in stdout, and both sides only assumed the shape. Where that
# assumption sat inside a bare `except: pass` the failure was silent and wrong rather than loud:
# a warning line printed before stack-gates' verdict made `_record_green` skip (push stays
# locked, nothing says why) and shipped the noise to the browser as HTTP 200 JSON. This module
# makes the edge explicit: parse, tolerate leading noise but SAY it happened, require the keys
# the caller actually reads, and on failure hand back a structured error naming the script and
# quoting what it really said.
import json
import os
import re

from . import ctx

_ANSI = re.compile(r"\x1b\[[0-9;]*[A-Za-z]")


def _first_json(text):
    """(value, skipped_prefix) — a script that prints a hint before its verdict is still
    usable, but the prefix is returned so the caller can surface it instead of eating it."""
    stripped = _ANSI.sub("", text or "")
    for i, ch in enumerate(stripped):
        if ch in "{[":
            try:
                value, end = json.JSONDecoder().raw_decode(stripped[i:])
            except ValueError:
                continue
            trailing = stripped[i + end:].strip()
            return value, stripped[:i].strip(), trailing
    return None, stripped.strip(), ""


def json_out(script, args=(), *, require=(), want=dict, timeout=None, cwd=None):
    """Run `script` and return (value, err). err is None on success, else a dict with
    `err` (one line, for a UI) and `detail` (script, exit code, what it printed).

    require — top-level keys the caller reads; a missing one is a contract break, not a
    default, because that is how a renamed field became a silently-wrong verdict.
    """
    name = os.path.basename(script)
    r = ctx.run([script, *args], timeout=timeout) if cwd is None else \
        __import__("subprocess").run([script, *args], cwd=cwd, capture_output=True, text=True, timeout=timeout)
    stderr = _ANSI.sub("", (r.stderr or "")).strip()
    value, prefix, trailing = _first_json(r.stdout)

    def fail(msg):
        return None, {"ok": False, "err": f"{name}: {msg}",
                      "detail": {"script": name, "exit": r.returncode,
                                 "stdout": (r.stdout or "")[:300], "stderr": stderr[-300:]}}
    if value is None:
        if r.returncode != 0:
            return fail(stderr.splitlines()[-1] if stderr else f"exited {r.returncode} with no verdict")
        return fail("printed no JSON verdict")
    if not isinstance(value, want):
        return fail(f"returned {type(value).__name__}, expected {want.__name__}")
    missing = [k for k in require if k not in value] if isinstance(value, dict) else []
    if missing:
        return fail(f"verdict is missing {', '.join(missing)} — the contract changed")
    if prefix or trailing:
        # not fatal (the verdict parsed) but never silent: a script that has started printing
        # around its JSON is one edit away from breaking the parse outright
        ctx.log(f"{name}: JSON verdict came with extra output — {(prefix or trailing)[:160]!r}")
    return value, None
