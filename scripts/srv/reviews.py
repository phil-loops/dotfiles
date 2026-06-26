# srv/reviews.py — bridge GitHub "review requested of me" PRs into the local forest.
#
#   GET  /review-requests   open PRs awaiting your review (gh search), each flagged
#                           `imported` if its review/pr-<N> branch already exists
#   POST /review-import      fetch a PR head → local node off its base, pin it
#
# An imported PR is an ordinary standalone watch node — base...head diffs,
# open-in-nvim, chat, bless, even checkout — because it's a real local branch.
import json
import os
import re
import time
from urllib.parse import parse_qs

from srv import ctx
from srv import picker

_cache = {"at": 0.0, "json": "[]"}
_TTL = 30   # gh search is a ~1s network round-trip and the review queue barely moves


def _imported(num):
    return ctx.run(["git", "rev-parse", "--verify", "--quiet",
                    f"refs/heads/review/pr-{num}"]).returncode == 0


def requests(req):
    now = time.time()
    if now - _cache["at"] < _TTL:
        req._send(200, _cache["json"])
        return
    repo = ctx.run(["gh", "repo", "view", "--json", "nameWithOwner", "-q", ".nameWithOwner"]).stdout.strip()
    r = ctx.run(["gh", "search", "prs", "--review-requested=@me", "--state=open",
                 "--repo", repo, "--json", "number,title,author,url"])
    try:
        prs = json.loads(r.stdout or "[]")
    except json.JSONDecodeError:
        prs = []
    out = [{"number": p["number"], "title": p["title"],
            "author": (p.get("author") or {}).get("login", ""),
            "url": p["url"], "imported": _imported(p["number"])} for p in prs]
    _cache["at"], _cache["json"] = now, json.dumps(out)
    req._send(200, _cache["json"])


def import_pr(req, raw):
    d = json.loads(raw or "{}")
    num = str(d.get("number", "")).strip().lstrip("#")
    if not num.isdigit():
        req._send(400, json.dumps({"ok": False, "err": "no pr number"}))
        return
    r = ctx.run([os.path.join(ctx.SCRIPTS, "stack-review-import"), num])
    if r.returncode != 0:
        req._send(500, json.dumps({"ok": False, "err": (r.stderr or "import failed").strip()[:500]}))
        return
    _cache["at"] = 0.0   # force the next /review-requests to re-flag this PR as imported
    req._send(200, json.dumps({"ok": True, "branch": r.stdout.strip()}))


_branch_cache = {}   # pr-num -> (at, own_local_branch_or_None)
_BRANCH_TTL = 120


def _local_branch_for_pr(num):
    # Your own PR? Open the real local branch (already checked out, editable) instead of a
    # detached review/pr-N fetch — skips the gh + 2 fetches + scratch-worktree import.
    now = time.time()
    hit = _branch_cache.get(num)
    if hit and now - hit[0] < _BRANCH_TTL:
        return hit[1]
    r = ctx.run(["gh", "pr", "view", num, "--json", "headRefName,isCrossRepository",
                 "--jq", "[.headRefName, .isCrossRepository] | @tsv"])
    parts = r.stdout.strip().split("\t") if r.returncode == 0 else []
    branch = None
    if len(parts) == 2 and parts[1] != "true" and parts[0] and \
            ctx.run(["git", "show-ref", "--verify", "--quiet", f"refs/heads/{parts[0]}"]).returncode == 0:
        branch = parts[0]
    _branch_cache[num] = (now, branch)
    return branch


def from_github(req, raw):   # POST /from-github — Chrome ext: open a PR's <path> at <line> in nvim
    d = json.loads(raw or "{}")
    num = str(d.get("number", "")).strip().lstrip("#")
    if not num.isdigit():
        req._send(400, json.dumps({"ok": False, "err": "no pr number"}))
        return
    branch = _local_branch_for_pr(num)
    local = branch is not None
    if not local:
        review = f"review/pr-{num}"
        if ctx.run(["git", "show-ref", "--verify", "--quiet", f"refs/heads/{review}"]).returncode == 0:
            branch = review   # already imported — reuse, don't re-fetch on every click
        else:
            r = ctx.run([os.path.join(ctx.SCRIPTS, "stack-review-import"), num])
            if r.returncode != 0:
                req._send(500, json.dumps({"ok": False, "err": (r.stderr or "import failed").strip()[:500]}))
                return
            _cache["at"] = 0.0   # force the next /review-requests to re-flag this PR as imported
            branch = r.stdout.strip()
    # Canonical viewer route — mirrors how the viewer opens a node: a forest member
    # (tagged stack-branch.<b>.project) lives at /forests/<project>/<branch>, an untagged
    # own branch is a standalone /branch/<b>, an imported PR is /review/N. The project tag
    # is the same git config the viewer reads, so membership stays single-source.
    project = ctx.run(["git", "config", f"stack-branch.{branch}.project"]).stdout.strip()
    if project:
        route = f"/forests/{project}/{branch}"
    elif local:
        route = f"/branch/{branch}"
    else:
        route = f"/review/{num}"
    path = (d.get("path") or "").strip()
    if not path:
        req._send(200, json.dumps({"ok": True, "branch": branch, "path": route, "opened": False, "local": local}))
        return
    code, _out, err = picker.open_on_branch(branch, path, d.get("line"))
    req._send(200 if code == 0 else (504 if code == 504 else 500),
              json.dumps({"ok": code == 0, "branch": branch, "path": route, "opened": code == 0, "local": local, "err": err}))


def ext_mtime(req):   # GET /ext-mtime — newest source mtime (ms) so the ext can flag a stale loaded copy
    d = os.path.join(ctx.SCRIPTS, "gh-to-nvim")
    latest = 0.0
    try:   # every loadable file (manifest/scripts/markup); skips README.md and icons/*.png
        for name in os.listdir(d):
            if name.endswith((".json", ".js", ".css", ".html")):
                latest = max(latest, os.path.getmtime(os.path.join(d, name)))
    except OSError:
        pass
    req._send(200, json.dumps({"mtime": int(latest * 1000)}))


# Cheap "did they push?" check for the node-load hint: ls-remote the PR head and compare to
# the local branch tip. Network, so cache per branch briefly — a node can re-render often.
_remote_cache = {}   # branch -> (at, payload)
_REMOTE_TTL = 20


def remote(req, u):
    branch = (parse_qs(u.query).get("branch", [""])[0]).strip()
    m = re.match(r"^review/pr-(\d+)$", branch)
    if not m:
        req._send(400, json.dumps({"ok": False, "err": "not a review branch"}))
        return
    now = time.time()
    hit = _remote_cache.get(branch)
    if hit and now - hit[0] < _REMOTE_TTL:
        req._send(200, hit[1])
        return
    local = ctx.run(["git", "rev-parse", branch]).stdout.strip()
    r = ctx.run(["git", "ls-remote", "origin", f"pull/{m.group(1)}/head"])
    remote_sha = r.stdout.split()[0] if r.returncode == 0 and r.stdout.split() else ""
    payload = json.dumps({
        "available": bool(remote_sha) and remote_sha != local,
        "remote": remote_sha[:9], "local": local[:9],
    })
    _remote_cache[branch] = (now, payload)
    req._send(200, payload)


# Re-fetch a force-pushed PR head into the local review branch. The bless ledger is keyed
# by branch+file → blob/patch-id (NOT the tip SHA), so we leave it untouched: files whose
# content is unchanged stay blessed, and genuinely-changed files fall to "stale" on their own.
def pull(req, raw):
    d = json.loads(raw or "{}")
    branch = (d.get("branch") or "").strip()
    m = re.match(r"^review/pr-(\d+)$", branch)
    if not m:
        req._send(400, json.dumps({"ok": False, "err": "not a review branch"}))
        return
    before = ctx.run(["git", "rev-parse", branch]).stdout.strip()
    r = ctx.run(["git", "fetch", "--force", "origin", f"pull/{m.group(1)}/head:{branch}"])
    if r.returncode != 0:
        req._send(500, json.dumps({"ok": False, "err": (r.stderr or "fetch failed").strip()[:500]}))
        return
    after = ctx.run(["git", "rev-parse", branch]).stdout.strip()
    _remote_cache.pop(branch, None)   # local now matches remote → next hint check recomputes
    req._send(200, json.dumps({"ok": True, "before": before[:9], "after": after[:9], "changed": before != after}))
