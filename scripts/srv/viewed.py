"""What Phil has viewed on the review page, per change block (wiki canopy-v2-viewed).

  store   $GIT_COMMON_DIR/stack-viewed.json   {subject: {block key: viewed-at}}
  domain  review / viewed: {"<repo>:<subject>": {id, repo, branch, keys}}
  POST /viewed {branch, keys, on}              view or un-view blocks; the page's v and u

A block key is computed by the page (review/diff.ts blocksOf) from a run of changed lines' own
text, so the store only holds keys. A subject is a branch name today; it's a subject rather than a
branch so a forest's integration ref can be reviewed as a whole beside its branches (undecided).
Started fresh 2026-10-25; the old per-file stack-blessed.json ledger went with v1.
"""
import json
import os
import re
import threading
import time

from . import ctx

_LOCK = threading.Lock()
_GITDIR = {}   # repo path -> its common git dir (it never moves)
_CACHE = {}    # store path -> (mtime_ns, parsed)
_KEY = re.compile(r"[a-z0-9]+(\.[0-9]+)?")


def _store():
    repo = ctx.repo_cwd()
    gd = _GITDIR.get(repo)
    if gd is None:
        r = ctx.run(["git", "-C", repo, "rev-parse", "--path-format=absolute", "--git-common-dir"])
        gd = _GITDIR[repo] = r.stdout.strip() if r.returncode == 0 else ""
    return os.path.join(gd, "stack-viewed.json") if gd else ""


def _read(path):
    try:
        st = os.stat(path)
    except OSError:
        return {}
    hit = _CACHE.get(path)
    if hit and hit[0] == st.st_mtime_ns:
        return hit[1]
    try:
        with open(path) as f:
            data = json.load(f)
    except (OSError, ValueError):
        data = {}
    _CACHE[path] = (st.st_mtime_ns, data)
    return data


def entities(name):
    """The review domain's `viewed` entities for one repo — a stat per tick when nothing changed."""
    data = _read(_store())
    return {"viewed": {f"{name}:{s}": {"id": f"{name}:{s}", "repo": name, "branch": s, "keys": sorted(keys)}
                       for s, keys in data.items() if keys}}


def post(req, raw):
    from . import state
    try:
        d = json.loads(raw or "{}")
        subject, keys, on = d.get("branch", ""), d.get("keys") or [], bool(d.get("on"))
        if not subject or not isinstance(keys, list) or not all(isinstance(k, str) and _KEY.fullmatch(k) for k in keys):
            raise ValueError("need {branch, keys: [block keys], on}")
        path = _store()
        if not path:
            raise ValueError("not in a git repo")
        with _LOCK:
            data = json.loads(json.dumps(_read(path)))
            mine = data.setdefault(subject, {})
            now = int(time.time())
            for k in keys:
                if on:
                    mine.setdefault(k, now)
                else:
                    mine.pop(k, None)
            if not mine:
                data.pop(subject, None)
            tmp = f"{path}.tmp"
            with open(tmp, "w") as f:
                json.dump(data, f, separators=(",", ":"), sort_keys=True)
            os.replace(tmp, path)
    except (OSError, ValueError) as e:
        return req._send(400, json.dumps({"ok": False, "error": str(e)}))
    state.poke()
    req._send(200, json.dumps({"ok": True, "branch": subject, "count": len(keys), "on": on}))
