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
import subprocess
import tempfile
import time
from urllib.parse import parse_qs

from srv import ctx
from srv import picker


def _resolve_repo(slug):
    # Map a GitHub "<owner>/<repo>" slug (what the Chrome ext sends in the body) to a registry
    # repo → (name, worktree). Prefers an exact remote-URL match across the viewer-repos; falls
    # back to the slug's basename matching a repo name (any owner / monotoad → the monotoad
    # checkout). Unknown → (None, CWD) so it behaves exactly like today (loops default).
    slug = (slug or "").strip().lower()
    if not slug:
        return None, ctx.CWD
    base = {}
    for name, path in (ctx.REPOS or {}).items():
        base[name.lower()] = (name, path)
        rv = subprocess.run(["git", "-C", path, "remote", "-v"], capture_output=True, text=True)
        for m in re.finditer(r"github\.com[:/]([^/\s]+/[^/\s]+?)(?:\.git)?(?:\s|$)", rv.stdout):
            if m.group(1).lower() == slug:
                return name, path
    hit = base.get(slug.split("/")[-1])
    return hit if hit else (None, ctx.CWD)

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


def _refresh_review_branch(num):
    # Re-sync review/pr-N to the live PR head before a precise line-open, so the line lands where
    # GitHub shows it — a stale fetch drifts line numbers (a pushed refactor moves the line). The
    # bless ledger is content-keyed (patch-id/blob), so re-fetch is safe; cheap when already
    # current; --force because a PR head can be force-pushed.
    ctx.run(["git", "fetch", "--force", "origin", f"pull/{num}/head:review/pr-{num}"])


def from_github(req, raw):   # POST /from-github — Chrome ext: open a PR's <path> at <line> in nvim
    d = json.loads(raw or "{}")
    # The ext sends repo="<owner>/<repo>" in the body (not ?repo=), so map it ourselves and pin
    # the thread to that checkout — every ctx.run / picker.open below then acts on it. do_POST's
    # finally clears the thread-local. Unknown slug → CWD (loops), today's behavior.
    repo_name, repo_path = _resolve_repo(d.get("repo"))
    ctx.set_repo(repo_path)
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
    # repo prefix on the forest route so `→ viewer` lands on the right repo's node; loops (the CWD
    # default) and unknown slugs stay implicit (/forests/<project>/<branch>).
    prefix = f"{repo_name}/" if (repo_path != ctx.CWD and repo_name) else ""
    project = ctx.run(["git", "config", f"stack-branch.{branch}.project"]).stdout.strip()
    if project:
        route = f"/forests/{prefix}{project}/{branch}"
    elif local:
        route = f"/branch/{branch}"
    else:
        route = f"/review/{num}"
    if d.get("view") == "gm":   # whole-PR Diffview (<leader>gm) — no specific file/line
        code, _out, err = picker.review_on_branch(branch)
        req._send(200 if code == 0 else (504 if code == 504 else 500),
                  json.dumps({"ok": code == 0, "branch": branch, "path": route, "opened": code == 0, "local": local, "err": err}))
        return
    path = (d.get("path") or "").strip()
    if not path:
        picker.prepare_branch(branch)   # warm the worktree in the background for a fast first open
        req._send(200, json.dumps({"ok": True, "branch": branch, "path": route, "opened": False, "local": local}))
        return
    if not local:
        _refresh_review_branch(num)   # land on the line GitHub shows, not a stale fetch's
    code, _out, err = picker.open_on_branch(branch, path, d.get("line"))
    req._send(200 if code == 0 else (504 if code == 504 else 500),
              json.dumps({"ok": code == 0, "branch": branch, "path": route, "opened": code == 0, "local": local, "err": err}))


def open_blob(req, raw):   # POST /open-blob — Chrome ext: open a GitHub blob's <path> at <line>
    # A blob view (github.com/.../blob/<ref>/<path>#L<n>) has no PR — just a file + line. Open it
    # in the MAIN working checkout (where you read/edit), not a scratch worktree of the ref; the
    # ref is informational. path is the repo-relative path straight from the URL.
    d = json.loads(raw or "{}")
    # map the body's "<owner>/<repo>" → checkout and pin it, so open_here lands in THAT repo's
    # working tree (not :62497's loops CWD). Unknown slug → CWD. do_POST's finally clears it.
    _name, repo_path = _resolve_repo(d.get("repo"))
    ctx.set_repo(repo_path)
    path = (d.get("path") or "").strip()
    if not path:
        req._send(400, json.dumps({"ok": False, "err": "no path"}))
        return
    code, _out, err = picker.open_here(path, d.get("line"))
    req._send(200 if code == 0 else (504 if code == 504 else 500),
              json.dumps({"ok": code == 0, "path": path, "opened": code == 0, "err": err}))


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


# ── PR → forest: which forest is this PR part of, and are its children still seated on it? ──
#
#   POST /pr-forest           {number, repo} → {branch, project, decision, route, children:[{branch, seated}]}
#   POST /pr-reseat-children  {number, repo} → rebase every orphaned child back onto the PR branch
#
# "Seated" = the child still contains the PR branch's tip. A squash/amend/rebase of the PR
# branch (e.g. squashing commits before review) orphans every child — they keep the OLD tip in
# their history and the viewer shows phantom parent commits in their diffs. Re-seating replays
# each child's own commits onto the new tip: rebase --onto <parent> <recorded cut> <child>,
# where the cut is the parent tip the child was last seated on (stack-branch.<child>.base,
# maintained by the forest tooling; fork-point then merge-base as fallbacks).


def _children_of(branch):
    r = ctx.run(["git", "config", "--get-regexp", r"^stack-branch\..*\.parent$"])
    out = []
    for line in r.stdout.splitlines():
        key, _, val = line.partition(" ")
        if val.strip() == branch:
            out.append(key[len("stack-branch."):-len(".parent")])
    return out


def _seated(parent, child):
    return ctx.run(["git", "merge-base", "--is-ancestor", parent, child]).returncode == 0


def _cut_point(parent, child):
    # the recorded parent tip the child was last rebased onto — NOT merge-base(parent, child):
    # after the parent is rewritten that merge-base collapses to main and the rebase would
    # replay the parent's old commits into the child.
    base = ctx.run(["git", "config", f"stack-branch.{child}.base"]).stdout.strip()
    if base and ctx.run(["git", "cat-file", "-e", f"{base}^{{commit}}"]).returncode == 0:
        return base
    r = ctx.run(["git", "merge-base", "--fork-point", parent, child])
    if r.returncode == 0 and r.stdout.strip():
        return r.stdout.strip()
    return ctx.run(["git", "merge-base", parent, child]).stdout.strip()


def _worktree_of(branch):
    wt = None
    for line in ctx.run(["git", "worktree", "list", "--porcelain"]).stdout.splitlines():
        if line.startswith("worktree "):
            wt = line[len("worktree "):]
        elif line == f"branch refs/heads/{branch}":
            return wt
    return None


def _rebase_onto(child, parent, cut):
    # a branch can only be rebased from the worktree it's checked out in; an un-checked-out
    # branch gets a temp worktree for the duration.
    wt, tmp = _worktree_of(child), None
    if wt is not None and ctx.run(["git", "-C", wt, "status", "--porcelain"]).stdout.strip():
        return False, "worktree dirty"
    try:
        if wt is None:
            tmp = wt = tempfile.mkdtemp(prefix="gh-nvim-reseat-")
            r = ctx.run(["git", "worktree", "add", "--quiet", "--force", tmp, child])
            if r.returncode != 0:
                return False, (r.stderr or "worktree add failed").strip()[:300]
        r = ctx.run(["git", "-C", wt, "rebase", "--onto", parent, cut, child])
        if r.returncode != 0:
            ctx.run(["git", "-C", wt, "rebase", "--abort"])
            return False, (r.stderr or "rebase failed").strip()[-300:]
        return True, ""
    finally:
        if tmp is not None:
            ctx.run(["git", "worktree", "remove", "--force", tmp])


def _reseat_walk(parent, results):
    # top-down: seat each child on its (possibly just-moved) parent, then descend. A subtree
    # whose root conflicts is left alone — its own recorded cuts stay valid for a manual pass.
    parent_tip = ctx.run(["git", "rev-parse", parent]).stdout.strip()
    for child in _children_of(parent):
        if _seated(parent, child):
            results.append({"branch": child, "status": "seated"})
        else:
            ok, err = _rebase_onto(child, parent, _cut_point(parent, child))
            if not ok:
                results.append({"branch": child, "status": "conflict", "err": err})
                continue
            ctx.run(["git", "config", f"stack-branch.{child}.base", parent_tip])
            results.append({"branch": child, "status": "reseated"})
        _reseat_walk(child, results)


def _decision(num):
    r = ctx.run(["gh", "pr", "view", num, "--json", "reviewDecision", "--jq", ".reviewDecision"])
    return r.stdout.strip() if r.returncode == 0 else ""


def pr_forest(req, raw):   # POST /pr-forest — Chrome ext: forest membership + child seating for a PR
    d = json.loads(raw or "{}")
    repo_name, repo_path = _resolve_repo(d.get("repo"))
    ctx.set_repo(repo_path)
    num = str(d.get("number", "")).strip().lstrip("#")
    if not num.isdigit():
        req._send(400, json.dumps({"ok": False, "err": "no pr number"}))
        return
    branch = _local_branch_for_pr(num)
    if not branch:
        req._send(200, json.dumps({"ok": True, "branch": None}))   # not my local branch → no forest to show
        return
    project = ctx.run(["git", "config", f"stack-branch.{branch}.project"]).stdout.strip()
    children = [{"branch": c, "seated": _seated(branch, c)} for c in _children_of(branch)]
    prefix = f"{repo_name}/" if (repo_path != ctx.CWD and repo_name) else ""
    route = f"/forests/{prefix}{project}/{branch}" if project else f"/branch/{branch}"
    req._send(200, json.dumps({"ok": True, "branch": branch, "project": project or None,
                               "decision": _decision(num), "route": route, "children": children}))


def pr_reseat(req, raw):   # POST /pr-reseat-children — rebase orphaned children back onto an approved PR branch
    d = json.loads(raw or "{}")
    _name, repo_path = _resolve_repo(d.get("repo"))
    ctx.set_repo(repo_path)
    num = str(d.get("number", "")).strip().lstrip("#")
    if not num.isdigit():
        req._send(400, json.dumps({"ok": False, "err": "no pr number"}))
        return
    branch = _local_branch_for_pr(num)
    if not branch:
        req._send(404, json.dumps({"ok": False, "err": "no local branch for this PR"}))
        return
    # approval is the button's contract (and re-checked here); force is the escape hatch for
    # a deliberate early reseat. Purely local either way — nothing is pushed.
    if not d.get("force") and _decision(num) != "APPROVED":
        req._send(409, json.dumps({"ok": False, "err": "PR not approved"}))
        return
    results = []
    _reseat_walk(branch, results)
    moved = [r["branch"] for r in results if r["status"] == "reseated"]
    conflicts = [r for r in results if r["status"] == "conflict"]
    req._send(200 if not conflicts else 207,
              json.dumps({"ok": not conflicts, "branch": branch, "results": results,
                          "moved": moved, "conflicts": conflicts}))


def reseat(req, raw):   # POST /reseat-children {branch} — viewer: rebase drifted children back onto this branch
    # The viewer-scoped sibling of pr_reseat: keyed by branch (the drifted node's parent), no
    # PR-approval gate — the viewer IS the surgery surface. Same walk: every child off the tip
    # is rebased back on from its recorded cut, recursively; seated children are untouched.
    # Purely local — nothing is pushed.
    d = json.loads(raw or "{}")
    branch = (d.get("branch") or "").strip()
    if not branch:
        req._send(400, json.dumps({"ok": False, "err": "no branch"}))
        return
    if ctx.run(["git", "rev-parse", "--verify", "--quiet", f"refs/heads/{branch}"]).returncode != 0:
        req._send(404, json.dumps({"ok": False, "err": f"no local branch {branch}"}))
        return
    results = []
    _reseat_walk(branch, results)
    moved = [r["branch"] for r in results if r["status"] == "reseated"]
    conflicts = [r for r in results if r["status"] == "conflict"]
    req._send(200 if not conflicts else 207,
              json.dumps({"ok": not conflicts, "branch": branch, "results": results,
                          "moved": moved, "conflicts": conflicts}))
