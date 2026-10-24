# srv/linemap.py — follow a review thread's anchor from the commit GitHub placed it on (the PR's
# pushed head) to the local tip, through the commits made since. A line a later commit changed
# reports that commit ("addressed by <sha>?"); a line it only shifted just moves.
#
# Pure parsing + translation, plus one spawn per (head, tip, paths): `git log -p -U0` over
# head..tip gives every commit's hunks, oldest first. When head isn't an ancestor of the tip (a
# local restack rewrote the commits), one `git diff -U0 head tip` stands in for the walk, and a
# changed line has no single commit to name. When the tip is BEHIND the head (commits made on
# GitHub, not pulled), the same diff only says where a line sits locally — nothing was addressed.
import re
import subprocess
import threading

from . import ctx

_HUNK = re.compile(r"^@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@")


def parse_hunks(text):
    """`git log -p -U0 --format=%x00%H` (or a bare `git diff -U0`) → [(sha, {path: [(a, b, c, d)]})],
    where each hunk is (old start, old count, new start, new count) as in its header."""
    out, cur, path, old = [], None, None, None
    for ln in text.splitlines():
        if ln.startswith("\x00"):
            cur = (ln[1:].strip(), {})
            out.append(cur)
            path = None
            continue
        if cur is None:
            cur = ("", {})
            out.append(cur)
        if ln.startswith("+++ "):
            p = ln[4:]
            path = None if p == "/dev/null" else p[2:] if p.startswith("b/") else p
            if path is not None:
                cur[1].setdefault(path, [])
            elif old:   # the file was deleted: every line of it changed
                cur[1][old] = [(1, 10 ** 9, 0, 0)]
        elif ln.startswith("--- "):
            p = ln[4:]
            old = None if p == "/dev/null" else p[2:] if p.startswith("a/") else p
        elif ln.startswith("diff --git"):
            path = old = None
        else:
            m = _HUNK.match(ln)
            if m and path is not None:
                a, b, c, d = m.group(1), m.group(2), m.group(3), m.group(4)
                cur[1][path].append((int(a), 1 if b is None else int(b), int(c), 1 if d is None else int(d)))
    return [(sha, files) for sha, files in out if files]


def shift(start, end, hunks):
    """One commit's hunks applied to the inclusive line range [start, end]: (start', end', changed).
    A changed range lands where the hunk that touched it begins, no longer than it was."""
    offset = 0
    for a, b, c, d in sorted(hunks):
        if b == 0:   # pure insertion after old line a
            if a < start:
                offset += d
                continue
            if a < end:   # inserted between two of the range's lines
                return start + offset, end + offset + d, True
            break
        if a + b - 1 < start:
            offset += d - b
            continue
        if a > end:
            break
        land = max(c, 1)
        return land, land + min(end - start, max(d - 1, 0)), True
    return start + offset, end + offset, False


def follow(start, end, commits):
    """[(sha, hunks)] oldest first → (start, end, addressedBy). addressedBy is the first commit that
    changed the range ("" when the walk has no single commit to name), None when nothing did."""
    by = None
    for sha, hunks in commits:
        start, end, changed = shift(start, end, hunks)
        if changed and by is None:
            by = sha
    return start, end, by


_CACHE = {}
_LOCK = threading.Lock()


def _git(args):
    return subprocess.run(["git", *args], cwd=ctx.repo_cwd(), capture_output=True, text=True)


def commits_between(head, tip, paths):
    """The hunk walk from head to tip over these paths, cached — refs are immutable by sha."""
    key = (ctx.repo_cwd(), head, tip, tuple(sorted(set(paths))))
    with _LOCK:
        hit = _CACHE.get(key)
    if hit is not None:
        return hit
    if not head or not tip or head == tip or not paths:
        res = {"walk": [], "mode": "same"}
    elif _git(["cat-file", "-e", f"{head}^{{commit}}"]).returncode != 0:
        res = {"walk": [], "mode": "unknown"}   # the PR head isn't here (never fetched): no mapping
    elif _git(["merge-base", "--is-ancestor", tip, head]).returncode == 0:
        # the local branch is BEHIND the PR (commits made on GitHub): nothing here addressed anything
        r = _git(["diff", "-U0", "--no-renames", head, tip, "--", *key[3]])
        res = {"walk": [("", files) for _sha, files in parse_hunks(r.stdout)], "mode": "behind",
               "behind": int(_git(["rev-list", "--count", f"{tip}..{head}"]).stdout.strip() or 0)}
    elif _git(["merge-base", "--is-ancestor", head, tip]).returncode == 0:
        r = _git(["log", "-p", "-U0", "--no-renames", "--reverse", "--first-parent", "--format=%x00%H",
                  f"{head}..{tip}", "--", *key[3]])
        res = {"walk": parse_hunks(r.stdout), "mode": "walk"}
    else:
        r = _git(["diff", "-U0", "--no-renames", head, tip, "--", *key[3]])
        res = {"walk": [("", files) for _sha, files in parse_hunks(r.stdout)], "mode": "rewritten"}
    with _LOCK:
        if len(_CACHE) > 512:
            _CACHE.clear()
        _CACHE[key] = res
    return res


def locate(walk, path, start, end):
    """A thread's (start, end) on the head, followed to the tip: {line, startLine, addressedBy}."""
    commits = [(sha, files.get(path, [])) for sha, files in walk]
    s, e, by = follow(start, end, commits)
    return {"line": e, "startLine": s if s != e else None, "addressedBy": by}
