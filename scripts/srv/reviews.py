# srv/reviews.py — bridge GitHub "review requested of me" PRs into the local forest.
#
#   GET  /review-requests   open PRs awaiting your review (gh search), each flagged
#                           `imported` if its review/pr-<N> branch already exists
#   POST /review-import      fetch a PR head → local node off its base, pin it
#
# An imported PR is an ordinary standalone watch node — base...head diffs,
# open-in-nvim, chat, bless, even checkout — because it's a real local branch.
import hashlib
import json
import os
import re
import subprocess
import tempfile
import threading
import time
from urllib.parse import parse_qs, unquote

from srv import ctx
from srv import picker
from srv import sync


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

_cache = {}   # repo -> {"at", "json"} — per-repo: a monotoad tab must not serve loops' queue
_TTL = 30   # gh search is a ~1s network round-trip and the review queue barely moves
_cache_lock = threading.Lock()
_refreshing = set()   # repos with a background re-search in flight


def _imported(num):
    return ctx.run(["git", "rev-parse", "--verify", "--quiet",
                    f"refs/heads/review/pr-{num}"]).returncode == 0


def _compute_requests():
    repo = ctx.run(["gh", "repo", "view", "--json", "nameWithOwner", "-q", ".nameWithOwner"]).stdout.strip()
    r = ctx.run(["gh", "search", "prs", "--review-requested=@me", "--state=open",
                 "--repo", repo, "--json", "number,title,author,url"])
    try:
        prs = json.loads(r.stdout or "[]")
    except json.JSONDecodeError:
        prs = []
    return json.dumps([{"number": p["number"], "title": p["title"],
                        "author": (p.get("author") or {}).get("login", ""),
                        "url": p["url"], "imported": _imported(p["number"])} for p in prs])


def _refresh_requests(repo_path):
    try:
        ctx.set_repo(repo_path)
        payload = _compute_requests()
        with _cache_lock:
            _cache[repo_path] = {"at": time.time(), "json": payload}
    finally:
        _refreshing.discard(repo_path)
        ctx.clear_repo()


def requests(req):
    # SWR: serve the cached queue instantly; a stale entry re-searches gh in the background
    # (the ~1s network call used to block every Home load past the TTL). Cold blocks once.
    repo_path = ctx.repo_cwd()
    with _cache_lock:
        ent = _cache.get(repo_path)
        if ent:
            if time.time() - ent["at"] >= _TTL and repo_path not in _refreshing:
                _refreshing.add(repo_path)
                threading.Thread(target=_refresh_requests, args=(repo_path,), daemon=True).start()
            req._send(200, ent["json"])
            return
    payload = _compute_requests()
    with _cache_lock:
        _cache[repo_path] = {"at": time.time(), "json": payload}
    req._send(200, payload)


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
    _cache.pop(ctx.repo_cwd(), None)   # force the next /review-requests to re-flag this PR as imported
    req._send(200, json.dumps({"ok": True, "branch": r.stdout.strip()}))


_WARM_EVERY = 300   # the review queue moves on human timescales; gh search is a ~1s network call
_WARM_MAX = 5       # bound the git work — the queue is normally 1-2 PRs


def _warm_review_requests():
    # Being asked to review a PR is the one signal that reliably predicts the next ⌘⇧O: those files
    # are the ones you're about to jump into. Import the head and build its worktree while the PR is
    # still just sitting in the queue, so the first jump is warm (~0.5s) instead of paying a fetch
    # plus a cold worktree build (~1.4s) at the moment you press the key.
    prs = json.loads(_compute_requests())
    for p in prs[:_WARM_MAX]:
        num = str(p["number"])
        if not p.get("imported") and \
                ctx.run([os.path.join(ctx.SCRIPTS, "stack-review-import"), num]).returncode != 0:
            continue
        picker.prepare_branch(f"review/pr-{num}")


def warm_requests_forever():
    while True:
        try:
            ctx.set_repo(ctx.CWD)
            _warm_review_requests()
        except Exception:
            pass   # a warm is a nicety — never let it kill the thread (or the next cycle)
        finally:
            ctx.clear_repo()
        time.sleep(_WARM_EVERY)


_branch_cache = {}   # (repo, pr-num) -> (at, own_local_branch_or_None)
_BRANCH_TTL = 120


def _pr_key(num):
    # Every registered repo numbers its PRs from 1, so a bare number is not a cache key: with
    # loops and monotoad both live, monotoad#42 would read loops#42's answer and jump into the
    # wrong checkout without a word. The request has already pinned its repo by here.
    return (ctx.repo_cwd(), num)


def _local_branch_for_pr(num):
    # Your own PR? Open the real local branch (already checked out, editable) instead of a
    # detached review/pr-N fetch — skips the gh + 2 fetches + scratch-worktree import.
    now = time.time()
    hit = _branch_cache.get(_pr_key(num))
    if hit and now - hit[0] < _BRANCH_TTL:
        return hit[1]
    r = ctx.run(["gh", "pr", "view", num, "--json", "headRefName,isCrossRepository",
                 "--jq", "[.headRefName, .isCrossRepository] | @tsv"], timeout=15)
    parts = r.stdout.strip().split("\t") if r.returncode == 0 else []
    branch = None
    if len(parts) == 2 and parts[1] != "true" and parts[0] and \
            ctx.run(["git", "show-ref", "--verify", "--quiet", f"refs/heads/{parts[0]}"]).returncode == 0:
        branch = parts[0]
    _branch_cache[_pr_key(num)] = (now, branch)
    return branch


_refreshed = {}   # pr-num -> unix time of the last head fetch
_refresh_locks = {}
_REFRESH_TTL = 120


def _refresh_review_branch(num):
    # Re-sync review/pr-N to the live PR head before a precise line-open, so the line lands where
    # GitHub shows it — a stale fetch drifts line numbers (a pushed refactor moves the line). The
    # bless ledger is content-keyed (patch-id/blob), so re-fetch is safe; --force because a PR
    # head can be force-pushed.
    #
    # It is NOT cheap when already current — a no-op fetch measures ~1.2s of network, and it ran
    # on every precise ⌘⇧O. The page-load prewarm pays it instead; the TTL is what lets the
    # keypress skip it. Prewarm time is also the more faithful moment to fetch: the line number
    # the chord sends was read off the page as it rendered, not off whatever the head is now.
    #
    # Lock per PR, don't just test the TTL: pressing the chord a second after the page renders
    # lands here while the prewarm's own fetch is still in flight and hasn't stamped the TTL yet,
    # so both would fetch the same ref at once — the keypress paying the very cost it's meant to
    # skip. Waiting for the in-flight fetch is strictly cheaper, and leaves the TTL warm.
    key = _pr_key(num)
    with _refresh_locks.setdefault(key, threading.Lock()):
        if time.time() - _refreshed.get(key, 0) < _REFRESH_TTL:
            return
        ctx.run(["git", "fetch", "--force", "origin", f"pull/{num}/head:review/pr-{num}"], timeout=20)
        _refreshed[key] = time.time()


def _match_diffhash(paths, want):
    return next((p for p in paths if p and hashlib.sha256(p.encode()).hexdigest() == want), None)


def _path_for_diffhash(branch, want):
    # GitHub's selected-line anchor is #diff-<sha256(path)> — one-way, but the branch is local by
    # now, so hash its changed files (vs merge-base with main; for a stacked PR that's a superset
    # of the PR's own files, which is harmless) and match. None → caller falls back to gm.
    r = ctx.run(["git", "diff", "--name-only", f"origin/main...{branch}"])
    if r.returncode != 0:
        r = ctx.run(["git", "diff", "--name-only", f"main...{branch}"])
    hit = _match_diffhash(r.stdout.splitlines(), want)
    if hit:
        return hit
    # Once the PR squash-merges, the branch stops differing from main and that list goes EMPTY —
    # every selected line then silently degraded to the whole-PR gm view (slower, and the wrong
    # thing). The anchor came from GitHub's diff, so the file is real: hash the tracked tree
    # instead (~0.02s, no network). A sha256 match on the full path is exact, never a near-miss.
    return _match_diffhash(ctx.run(["git", "ls-files"]).stdout.splitlines(), want)


def _open_pr(req, d):   # via open_url (POST /open-url) — Chrome ext: open a PR's <path> at <line> in nvim
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
            r = ctx.run([os.path.join(ctx.SCRIPTS, "stack-review-import"), num], timeout=30)
            if r.returncode != 0:
                req._send(500, json.dumps({"ok": False, "err": (r.stderr or "import failed").strip()[:500]}))
                return
            _cache.pop(ctx.repo_cwd(), None)   # force the next /review-requests to re-flag this PR as imported
            branch = r.stdout.strip()
            _refreshed[_pr_key(num)] = time.time()   # the import just fetched this head — don't re-fetch it below
    prefix = f"{repo_name}/" if (repo_path != ctx.CWD and repo_name) else ""
    route = _viewer_route(branch, prefix, num, local)
    refreshed = False
    dh = (d.get("diffhash") or "").strip()
    if dh and not d.get("path"):   # URL-only line selection: resolve GitHub's hash to a path here
        if not local:
            _refresh_review_branch(num)   # hash was computed against the live head, not a stale fetch
            refreshed = True
        hit = _path_for_diffhash(branch, dh)
        if hit:
            d["path"], d["line"] = hit, d.get("hashline")
        else:
            d["view"] = "gm"   # unresolvable hash — the whole-PR view beats a wrong jump
    if d.get("view") == "gm":   # whole-PR Diffview (<leader>gm) — no specific file/line
        code, _out, err = picker.review_on_branch(branch)
        req._send(200 if code == 0 else (504 if code == 504 else 500),
                  json.dumps({"ok": code == 0, "branch": branch, "path": route, "opened": code == 0, "local": local, "err": err}))
        return
    path = (d.get("path") or "").strip()
    if not path:
        if not local:
            _refresh_review_branch(num)   # warm the REF too — before the worktree, so it builds at the live head
        picker.prepare_branch(branch)   # warm the worktree in the background for a fast first open
        req._send(200, json.dumps({"ok": True, "branch": branch, "path": route, "opened": False, "local": local}))
        return
    if not local and not refreshed:
        _refresh_review_branch(num)   # land on the line GitHub shows, not a stale fetch's
    code, _out, err = picker.open_on_branch(branch, path, d.get("line"))
    req._send(200 if code == 0 else (504 if code == 504 else 500),
              json.dumps({"ok": code == 0, "branch": branch, "path": route, "opened": code == 0, "local": local, "err": err}))


def _open_here(req, d):   # via open_url (POST /open-url) — Chrome ext: open a GitHub blob's <path> at <line>
    # A blob view (github.com/.../blob/<ref>/<path>#L<n>) has no PR — just a file + line. Open it
    # in the MAIN working checkout (where you read/edit), not a scratch worktree of the ref; the
    # ref is informational. path is the repo-relative path straight from the URL.
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


_GH_PR = re.compile(r"^https://github\.com/([^/]+/[^/]+)/pull/(\d+)")
_GH_FILE = re.compile(r"^https://github\.com/([^/]+/[^/]+)/(?:blob|blame|raw)/([^/]+)/([^#?]+)")
_GH_RAWHOST = re.compile(r"^https://raw\.githubusercontent\.com/([^/]+/[^/]+)/(?:refs/heads/)?([^/]+)/([^#?]+)")
_GH_COMMIT = re.compile(r"^https://github\.com/([^/]+/[^/]+)/commit/([0-9a-f]+)")
_GH_COMPARE = re.compile(r"^https://github\.com/([^/]+/[^/]+)/compare/([^?#]+)")
_GH_REPO = re.compile(r"^https://github\.com/([^/]+/[^/]+)")
_DIFF_HASH = re.compile(r"#diff-([0-9a-f]+)[RL](\d+)")
_LINE_HASH = re.compile(r"#L(\d+)")


def _compare_head(spec):
    # "<base>...<head>", "<base>..<head>", or a bare "<head>"; either side may carry a cross-fork
    # "<owner>:" prefix. Split on the range operator, never on "/" — branch names contain slashes.
    head = re.split(r"\.\.\.?", unquote(spec))[-1]
    return head.split(":", 1)[-1].strip("/")


def _viewer_route(branch, prefix="", num=None, local=True):
    # Canonical viewer route — mirrors how the viewer opens a node: a forest member (tagged
    # stack-branch.<b>.project) lives at /forests/<project>/<branch>, an untagged own branch is a
    # standalone /branch/<b>, an imported PR is /review/N. The project tag is the same git config
    # the viewer reads, so membership stays single-source. The repo prefix lands `→ viewer` on the
    # right repo's node; loops (the CWD default) and unknown slugs stay implicit.
    project = (ctx.run(["git", "config", f"branch.{branch}.stack-project"]).stdout.strip()
               or ctx.run(["git", "config", f"stack-branch.{branch}.project"]).stdout.strip())
    if project:
        return f"/forests/{prefix}{project}/{branch}"
    return f"/branch/{branch}" if local else f"/review/{num}"


def open_url(req, raw):   # POST /open-url {url, open?} — Chrome ext (URL-only): parse + route a GitHub URL
    # The extension no longer reads the page (activeTab grants the URL string, nothing else) —
    # everything must come from the URL. PR pages: number in the path, a selected line in
    # GitHub's #diff-<sha256(path)>R<n> hash (resolved by _path_for_diffhash once the branch is
    # local; no hash → whole-PR gm Diffview). Blob pages carry path + #L<n> outright. Commit
    # pages resolve the hash via the commit's own file list. open:"viewer" skips nvim and just
    # imports + returns the node's route for the ext to open in a tab.
    d = json.loads(raw or "{}")
    url = (d.get("url") or "").strip()
    m = _GH_PR.match(url)
    if m:
        p = {"repo": m.group(1), "number": m.group(2)}
        if d.get("open") in ("viewer", "prewarm"):
            # Both are path-less: import the head + build the worktree, open nothing, return the
            # route. "viewer" means the ext will open that route in a tab; "prewarm" means it won't
            # — it's just landing on the PR page, paying the cold cost now so the jump is warm.
            return _open_pr(req, p)
        h = _DIFF_HASH.search(url)
        if h:
            p["diffhash"], p["hashline"] = h.group(1), int(h.group(2))
        else:
            p["view"] = "gm"
        return _open_pr(req, p)
    m = _GH_FILE.match(url) or _GH_RAWHOST.match(url)
    if m:
        # NB: a ref containing slashes (feature/x) over-claims path segments — fine for the
        # common main/single-segment-ref case; ref is informational (opens the working checkout).
        # blame/raw share blob's shape exactly; raw carries no #L anchor, so it lands at line 1.
        lm = _LINE_HASH.search(url)
        return _open_here(req, {"repo": m.group(1), "ref": unquote(m.group(2)),
                                "path": unquote(m.group(3)),
                                "line": int(lm.group(1)) if lm else 1})
    m = _GH_COMMIT.match(url)
    if m:
        h = _DIFF_HASH.search(url)
        if not h:
            req._send(400, json.dumps({"ok": False, "err": "select a line on the commit first (click a line number)"}))
            return
        _name, repo_path = _resolve_repo(m.group(1))
        ctx.set_repo(repo_path)
        sha = m.group(2)
        if ctx.run(["git", "cat-file", "-e", f"{sha}^{{commit}}"]).returncode != 0:
            req._send(404, json.dumps({"ok": False, "err": f"commit {sha[:9]} not found locally — fetch first"}))
            return
        names = ctx.run(["git", "show", "--name-only", "--format=", sha]).stdout.splitlines()
        hit = next((n for n in names if n and hashlib.sha256(n.encode()).hexdigest() == h.group(1)), None)
        if not hit:
            req._send(404, json.dumps({"ok": False, "err": "selected line's file not in this commit"}))
            return
        return _open_here(req, {"repo": m.group(1), "path": hit, "line": int(h.group(2))})
    m = _GH_COMPARE.match(url)
    if m:
        # A compare has no PR number, so there is nothing to import — the head must already be a
        # local branch. Otherwise it's the same whole-branch Diffview the PR path falls back to.
        _name, repo_path = _resolve_repo(m.group(1))
        ctx.set_repo(repo_path)
        head = _compare_head(m.group(2))
        if not head or ctx.run(["git", "show-ref", "--verify", "--quiet", f"refs/heads/{head}"]).returncode != 0:
            req._send(404, json.dumps({"ok": False, "err": f"no local branch '{head}' — fetch it first"}))
            return
        if d.get("open") == "viewer":
            req._send(200, json.dumps({"ok": True, "branch": head, "path": _viewer_route(head), "opened": False}))
            return
        code, _out, err = picker.review_on_branch(head)
        req._send(200 if code == 0 else (504 if code == 504 else 500),
                  json.dumps({"ok": code == 0, "branch": head, "opened": code == 0, "err": err}))
        return
    if _GH_REPO.match(url) and d.get("open") == "viewer":
        # Soft landing: an issue/Actions/tree page names no file, so there is nothing to jump to —
        # but ⌘⇧U asked for the viewer, and viewer home is a better answer than a dead chord.
        req._send(200, json.dumps({"ok": True, "path": "/", "opened": False}))
        return
    req._send(400, json.dumps({"ok": False, "err": "no file in this URL (PR, blob, blame, commit, compare pages work)"}))


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
    parents = {}
    r = ctx.run(["git", "config", "--get-regexp", r"^stack-branch\..*\.parent$"])
    for line in r.stdout.splitlines():
        key, _, val = line.partition(" ")
        parents[key[len("stack-branch."):-len(".parent")]] = val.strip()
    r = ctx.run(["git", "config", "--get-regexp", r"^branch\..*\.stack-parent$"])
    for line in r.stdout.splitlines():
        key, _, val = line.partition(" ")
        parents[key[len("branch."):-len(".stack-parent")]] = val.strip()
    return [b for b, p in parents.items() if p == branch]


def _seated(parent, child):
    return ctx.run(["git", "merge-base", "--is-ancestor", parent, child]).returncode == 0


def _cut_point(parent, child):
    # the recorded parent tip the child was last rebased onto — NOT merge-base(parent, child):
    # after the parent is rewritten that merge-base collapses to main and the rebase would
    # replay the parent's old commits into the child.
    base = (ctx.run(["git", "config", f"branch.{child}.stack-base"]).stdout.strip()
            or ctx.run(["git", "config", f"stack-branch.{child}.base"]).stdout.strip())
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


def _resign_range(onto, tip):
    """git-replay has no -S and ignores commit.gpgsign, so its commits push as Unverified.
    Re-author each replayed commit bottom-up with commit-tree -S (tree/parents/author/message
    preserved, still worktree-free). Returns the signed tip, or None to fall back."""
    shas = ctx.run(["git", "rev-list", "--reverse", f"{onto}..{tip}"]).stdout.split()
    mapped = {}
    for sha in shas:
        meta = ctx.run(["git", "log", "-1", "--format=%T%x1f%P%x1f%an%x1f%ae%x1f%aD%x1f%B", sha]).stdout
        parts = meta.split("\x1f", 5)
        if len(parts) != 6:
            return None
        tree, parents, an, ae, ad, msg = parts
        env = dict(os.environ, GIT_AUTHOR_NAME=an, GIT_AUTHOR_EMAIL=ae, GIT_AUTHOR_DATE=ad)
        cmd = ["git", "commit-tree", tree, "-S", "-m", msg.rstrip("\n")]
        for p in parents.split():
            cmd += ["-p", mapped.get(p, p)]
        r = subprocess.run(cmd, cwd=ctx.repo_cwd(), env=env, capture_output=True, text=True)
        if r.returncode != 0 or not r.stdout.strip():
            return None
        mapped[sha] = r.stdout.strip()
    return mapped.get(shas[-1]) if shas else None


def _rebase_onto(child, parent, cut):
    # a branch can only be rebased from the worktree it's checked out in; an un-checked-out
    # branch gets a temp worktree for the duration.
    wt, tmp = _worktree_of(child), None
    if wt is not None and ctx.run(["git", "-C", wt, "status", "--porcelain"]).stdout.strip():
        return False, "worktree dirty"
    if wt is None:
        # replay writes the ref with no checkout — a full temp-worktree materialisation per
        # child made message-only reseats crawl; any refusal falls through to the real rebase
        r = ctx.run(["git", "replay", "--onto", parent, f"{cut}..{child}"])
        if r.returncode == 0 and r.stdout.strip():
            update = r.stdout
            fields = update.split()
            if len(fields) >= 4 and ctx.run(["git", "config", "--get", "commit.gpgsign"]).stdout.strip() == "true":
                signed = _resign_range(parent, fields[2])
                update = f"{fields[0]} {fields[1]} {signed} {fields[3]}\n" if signed else ""
            if update:
                u = subprocess.run(["git", "update-ref", "--stdin"], input=update,
                                   cwd=ctx.repo_cwd(), capture_output=True, text=True)
                if u.returncode == 0:
                    return True, ""
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
    published = sync._open_pr_heads(fresh=True)
    for child in _children_of(parent):
        if _seated(parent, child):
            results.append({"branch": child, "status": "seated"})
        elif child in published:
            # replaying a child with an open PR diverges its pushed copy — only a force-push lands that, so skip
            results.append({"branch": child, "status": "held-pr",
                            "err": "open PR — reseat would diverge the pushed branch (force-push); reconcile by hand"})
            continue
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
    project = (ctx.run(["git", "config", f"branch.{branch}.stack-project"]).stdout.strip()
               or ctx.run(["git", "config", f"stack-branch.{branch}.project"]).stdout.strip())
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
    held = [r for r in results if r["status"] == "held-pr"]
    req._send(200 if not conflicts else 207,
              json.dumps({"ok": not conflicts, "branch": branch, "results": results,
                          "moved": moved, "conflicts": conflicts, "held": held}))


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
    held = [r for r in results if r["status"] == "held-pr"]
    req._send(200 if not conflicts else 207,
              json.dumps({"ok": not conflicts, "branch": branch, "results": results,
                          "moved": moved, "conflicts": conflicts, "held": held}))
