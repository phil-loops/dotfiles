"""What Phil has read on the review page, per change block (wiki canopy-v2-viewed).

  store   $GIT_COMMON_DIR/stack-viewed.json
            {"version": 2, "subjects": {<id>: {"viewed": {key: at}, "flagged": {key: at}}}}
  domain  review / viewed: {"<repo>:<branch>": {id, repo, branch, keys, flagged, flags}}
  POST /viewed {branch, marks: {key: "viewed"|"flagged"|"none"}, where?: {key: {path, line, text}}}
               (or {branch, keys, state}, or the older {keys, on})

A flag is a bookmark Phil comes back to, so it keeps where it was made (`where`: the file, the line
and the changed line's text) for canopy's list of flags; `flags` carries that per flagged key.

A block key is computed by the page (Diff.swift blocksOf) from a run of changed lines' own text, so
the store only holds keys. A subject is a branch's review id, `branch.<b>.stack-review-id` in git
config: git carries branch config through `git branch -m` and deletes it with the branch, so marks
follow a rename and a deleted branch's marks are pruned on the next write. The id is minted on a
branch's first mark.

Unmarking takes a key off every subject: the page reads marks across the repo's branches (a change
carried to a child, or the cumulative view, shows what was read), so a mark left on another branch
would keep it marked.

Version 1 ({branch name: {key: at}}) is read as viewed marks by branch name and rewritten as version
2 on the next write; names with no branch any more are dropped then.
"""
import json
import os
import re
import secrets
import threading
import time

from . import ctx

_LOCK = threading.Lock()
_GITDIR = {}   # repo path -> its common git dir (it never moves)
_CACHE = {}    # store path -> (mtime_ns, parsed)
_IDS = {}      # repo path -> (config mtime_ns, {id: branch})
_KEY = re.compile(r"[a-z0-9]+(\.[a-z0-9]+)*")
_ID_KEY = re.compile(r"^branch\.(.+)\.stack-review-id (\S+)$")
STATES = ("viewed", "flagged", "none")


def _gitdir():
    repo = ctx.repo_cwd()
    gd = _GITDIR.get(repo)
    if gd is None:
        r = ctx.run(["git", "-C", repo, "rev-parse", "--path-format=absolute", "--git-common-dir"])
        gd = _GITDIR[repo] = r.stdout.strip() if r.returncode == 0 else ""
    return gd


def _store():
    gd = _gitdir()
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


def _ids():
    """{review id: branch} from git config, re-read only when the config file changes."""
    repo = ctx.repo_cwd()
    gd = _gitdir()
    try:
        mtime = os.stat(os.path.join(gd, "config")).st_mtime_ns if gd else 0
    except OSError:
        mtime = 0
    hit = _IDS.get(repo)
    if hit and hit[0] == mtime:
        return hit[1]
    r = ctx.run(["git", "-C", repo, "config", "--get-regexp", r"^branch\..*\.stack-review-id$"])
    ids = {}
    for line in (r.stdout.splitlines() if r.returncode == 0 else []):
        m = _ID_KEY.match(line.strip())
        if m:
            ids[m.group(2)] = m.group(1)
    _IDS[repo] = (mtime, ids)
    return ids


def _branch_exists(branch):
    r = ctx.run(["git", "-C", ctx.repo_cwd(), "rev-parse", "--verify", "--quiet", f"refs/heads/{branch}"])
    return r.returncode == 0


def _id_for(branch):
    """The branch's review id, minted into its git config on first use."""
    for i, b in _ids().items():
        if b == branch:
            return i
    i = secrets.token_hex(6)
    r = ctx.run(["git", "-C", ctx.repo_cwd(), "config", f"branch.{branch}.stack-review-id", i])
    if r.returncode != 0:
        raise ValueError(f"couldn't give {branch} a review id")
    _IDS.pop(ctx.repo_cwd(), None)
    return i


def _subjects(data):
    """The store as {branch: {"viewed": {...}, "flagged": {...}}}, from either version."""
    if data.get("version") == 2:
        ids = _ids()
        return {ids[i]: s for i, s in data.get("subjects", {}).items() if i in ids}
    return {b: {"viewed": keys, "flagged": {}} for b, keys in data.items() if isinstance(keys, dict)}


def _flag(key, v):
    place = v if isinstance(v, dict) else {"at": v}
    return {"key": key, "at": place.get("at", 0), "path": place.get("path", ""),
            "line": place.get("line", 0), "text": place.get("text", "")}


def entities(name):
    """The review domain's `viewed` entities for one repo — a stat or two per tick when nothing changed."""
    out = {}
    for b, s in _subjects(_read(_store())).items():
        viewed, flagged = s.get("viewed") or {}, s.get("flagged") or {}
        if viewed or flagged:
            out[f"{name}:{b}"] = {"id": f"{name}:{b}", "repo": name, "branch": b,
                                  "keys": sorted(viewed), "flagged": sorted(flagged),
                                  "flags": sorted((_flag(k, v) for k, v in flagged.items()), key=lambda f: (f["path"], f["line"]))}
    return {"viewed": out}


def _where(raw):
    """{key: {path, line, text}} from a POST, dropping anything malformed; text is cut to one short line."""
    out = {}
    for k, w in (raw.items() if isinstance(raw, dict) else []):
        if isinstance(w, dict) and isinstance(w.get("path"), str) and isinstance(w.get("line"), int) and 0 < len(w["path"]) <= 500:
            text = w.get("text") if isinstance(w.get("text"), str) else ""
            out[k] = {"path": w["path"], "line": w["line"], "text": " ".join(text.split())[:160]}
    return out


def _migrated(data):
    """Version 2 of the store, minting ids for version 1's branches that still exist."""
    if data.get("version") == 2:
        return data
    subjects = {}
    for b, keys in data.items():
        if isinstance(keys, dict) and keys and _branch_exists(b):
            subjects[_id_for(b)] = {"viewed": dict(keys), "flagged": {}}
    return {"version": 2, "subjects": subjects}


def apply(data, branch_id, keys, state, now, where=None):
    """Pure: the store after marking `keys` with `state` on one subject. "none" clears them everywhere,
    since the page reads marks across subjects. A flag with a `where` keeps it (a re-flag moves it)."""
    where = where or {}
    data = json.loads(json.dumps(data))
    subjects = data.setdefault("subjects", {})
    mine = subjects.setdefault(branch_id, {"viewed": {}, "flagged": {}})
    for k in keys:
        if state == "none":
            for s in subjects.values():
                s.get("viewed", {}).pop(k, None)
                s.get("flagged", {}).pop(k, None)
        else:
            other = "flagged" if state == "viewed" else "viewed"
            mine.setdefault(other, {}).pop(k, None)
            marks = mine.setdefault(state, {})
            if state == "flagged" and k in where:
                at = marks[k].get("at", now) if isinstance(marks.get(k), dict) else marks.get(k, now)
                marks[k] = {"at": at, **where[k]}
            else:
                marks.setdefault(k, now)
    for i in [i for i, s in subjects.items() if not s.get("viewed") and not s.get("flagged")]:
        subjects.pop(i)
    return data


def post(req, raw):
    from . import state
    try:
        d = json.loads(raw or "{}")
        branch = d.get("branch", "")
        marks = d.get("marks")
        if not isinstance(marks, dict):
            keys = d.get("keys") or []
            mark = d.get("state") or ("viewed" if d.get("on") else "none")
            marks = {k: mark for k in keys} if isinstance(keys, list) and all(isinstance(k, str) for k in keys) else None
        if not branch or not marks or not all(isinstance(k, str) and _KEY.fullmatch(k) and v in STATES for k, v in marks.items()):
            raise ValueError("need {branch, marks: {block key: viewed|flagged|none}}")
        where = _where(d.get("where"))
        path = _store()
        if not path:
            raise ValueError("not in a git repo")
        if not _branch_exists(branch):
            raise ValueError(f"no branch {branch}")
        with _LOCK:
            data = _migrated(_read(path))
            ids = _ids()
            data["subjects"] = {i: s for i, s in data.get("subjects", {}).items() if i in ids}
            mine, now = _id_for(branch), int(time.time())
            for mark in STATES:
                group = [k for k, v in marks.items() if v == mark]
                if group:
                    data = apply(data, mine, group, mark, now, where)
            tmp = f"{path}.tmp"
            with open(tmp, "w") as f:
                json.dump(data, f, separators=(",", ":"), sort_keys=True)
            os.replace(tmp, path)
    except (OSError, ValueError) as e:
        return req._send(400, json.dumps({"ok": False, "error": str(e)}))
    state.poke()
    req._send(200, json.dumps({"ok": True, "branch": branch, "count": len(marks)}))
