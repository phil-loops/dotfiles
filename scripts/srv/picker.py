# srv/picker.py — the landing/picker: project cards, PR maps, the standalone watch
# list, branch typeahead, recency ordering, and the open-in-nvim action.
#   GET  /projects        project cards w/ ready/candidate PRs + behind/overlap freshness
#   GET  /prs             branch → open-PR map (stack-prs, disk-cached)
#   GET  /myprs           my open PRs annotated with .project (homepage list)
#   GET  /project-opened  project → last file-open epoch (orders the no-PR cards)
#   GET  /standalone      the pinned watch list
#   GET  /branches        typeahead candidates for pinning
#   POST /standalone      pin/unpin a branch
#   POST /open            open a file on a branch in the warm review-nvim (+ recency stamp)
import os
import re
import json
import time
import signal
import subprocess
from concurrent.futures import ThreadPoolExecutor
from urllib.parse import parse_qs

from . import ctx

_pcache = {}  # (model_sig, origin-main-sha) -> picker json — the /projects fan-out is expensive
_PR_RE = re.compile(r"\(#(\d+)\)")


def _opened_file():
    # project -> epoch of the last hover+o file-open, kept in the git-common-dir so it
    # survives across worktrees. Drives the "recently touched first" ordering.
    gd = ctx.run(["git", "rev-parse", "--git-common-dir"]).stdout.strip()
    if gd and not os.path.isabs(gd):
        gd = os.path.join(ctx.CWD, gd)
    return os.path.join(gd, "stack-project-opened.json") if gd else ""


def _opened_load():
    try:
        with open(_opened_file()) as f:
            return json.load(f)
    except Exception:
        return {}


def _record_open(branch):
    # Stamp now against the branch's project tag, so a no-PR project floats to the top
    # after you open one of its files. No tag → nothing to order by, skip.
    if not branch:
        return
    proj = ctx.run(["git", "config", f"stack-branch.{branch}.project"]).stdout.strip()
    path = _opened_file()
    if not proj or not path:
        return
    try:
        d = _opened_load()
        d[proj] = int(time.time())
        with open(path, "w") as f:
            json.dump(d, f)
    except Exception:
        pass


def _ready_to_merge(mergeable, prs):
    """Split stack-forest's topologically-mergeable branches by PR state:
      ready      — an open PR already exists (the green into-main edge-bar set)
      candidates — no PR yet, but clear to merge straight into main.
    Pure split, input order preserved."""
    ready, candidates = [], []
    for b in mergeable:
        (ready if b in prs else candidates).append(b)
    return ready, candidates


def _merges_file():
    # project -> last merge-into-main {pr,title,at,branch}, kept in the git-common-dir
    # so it survives restarts and is shared across worktrees. Drives the "merged Xm
    # ago" recency badge on the picker cards.
    gd = ctx.run(["git", "rev-parse", "--git-common-dir"]).stdout.strip()
    if gd and not os.path.isabs(gd):
        gd = os.path.join(ctx.CWD, gd)
    return os.path.join(gd, "stack-project-merges.json") if gd else ""


def _gh_pr(num):
    # Resolve a (possibly already-merged) PR to its head branch + title. Bounded so a
    # slow/offline GitHub never stalls the picker; any failure → None (just no badge).
    try:
        r = subprocess.run(["gh", "pr", "view", str(num), "--json", "headRefName,title"],
                           cwd=ctx.CWD, capture_output=True, text=True, timeout=6)
        if r.returncode != 0:
            return None
        d = json.loads(r.stdout or "{}")
        return d.get("headRefName") or "", d.get("title") or ""
    except Exception:
        return None


def _project_of(branch):
    p = ctx.run(["git", "config", f"stack-branch.{branch}.project"]).stdout.strip()
    if p:
        return p
    for line in ctx.run(["git", "config", "--get-regexp",
                         r"^stack-project\..*\.branch$"]).stdout.splitlines():
        k, _, v = line.partition(" ")
        if v.strip() == branch:
            m = re.match(r"^stack-project\.(.+)\.branch$", k)
            if m:
                return m.group(1)
    return None


def _scan_merges():
    # Walk new origin/main commits since the last scan; attribute each squash-merge
    # (subject "… (#N)") to a project via its head branch's project tag, and keep the
    # newest merge per project. The store persists, so the badge survives restarts and
    # lingers after the now-empty node is contracted — until that project merges again.
    path = _merges_file()
    try:
        with open(path) as f:
            store = json.load(f)
    except Exception:
        store = {}
    tip = ctx.run(["git", "rev-parse", "origin/main"]).stdout.strip()
    old = store.get("tip", "")
    # Incremental when old..tip is a fast-forward; otherwise (first run / rewritten
    # main) backfill a bounded window so a brand-new viewer shows recent merges once.
    if old and ctx.run(["git", "merge-base", "--is-ancestor", old, tip]).returncode == 0:
        rng, cap = [f"{old}..origin/main"], []
    else:
        rng, cap = ["origin/main"], ["-n", "12"]
    log = ctx.run(["git", "log", *cap, "--format=%cI%x09%s", *rng]).stdout.splitlines()
    merges = store.get("merges", {})
    for line in reversed(log):   # oldest-first so a newer merge overwrites its project
        at, _, subj = line.partition("\t")
        nums = _PR_RE.findall(subj)
        if not nums:
            continue
        res = _gh_pr(int(nums[-1]))
        if not res:
            continue
        branch, title = res
        proj = _project_of(branch) if branch else None
        if proj:
            merges[proj] = {"pr": int(nums[-1]), "title": title or subj, "at": at, "branch": branch}
    try:
        if path:
            with open(path, "w") as f:
                json.dump({"tip": tip, "merges": merges}, f)
    except Exception:
        pass
    return merges


# --- GET handlers ---

def prs(req):
    r = ctx.run([os.path.join(ctx.SCRIPTS, "stack-prs")])
    req._send(200, r.stdout or "{}")


def myprs(req):
    r = ctx.run([os.path.join(ctx.SCRIPTS, "my-prs")])
    req._send(200, r.stdout or "[]")


def projects(req):
    # Cache on model_sig + origin/main tip so repeat loads are instant and recompute
    # only when a ref/config/ledger changes or a fetch moves origin/main.
    pck = (ctx.model_sig(), ctx.run(["git", "rev-parse", "origin/main"]).stdout.strip())
    if pck in _pcache:
        req._send(200, _pcache[pck])
        return
    # stack-forest --projects and stack-prs are independent → run concurrently.
    with ThreadPoolExecutor(max_workers=2) as ex:
        fr = ex.submit(ctx.run, [os.path.join(ctx.SCRIPTS, "stack-forest"), "--projects"])
        pf = ex.submit(ctx.run, [os.path.join(ctx.SCRIPTS, "stack-prs")])
        r, prsr = fr.result(), pf.result()
    try:
        projs = json.loads(r.stdout or "[]")
    except Exception:
        projs = []
    try:
        prmap = json.loads(prsr.stdout or "{}")
    except Exception:
        prmap = {}
    # Per mergeable root: how far it trails origin/main (behind), and whether main's new
    # commits touch files the branch also touches (overlap → a consequential restack vs
    # pure SHA churn). Fanned out through a thread pool (git releases the GIL).
    def _root_fresh(b):
        n = ctx.run(["git", "rev-list", "--count", f"{b}..origin/main"]).stdout.strip()
        behind = int(n) if n.isdigit() else 0
        overlap = False
        if behind:
            mb = ctx.run(["git", "merge-base", b, "origin/main"]).stdout.strip()
            if mb:
                main_files = set(ctx.run(["git", "diff", "--name-only", f"{mb}..origin/main"]).stdout.splitlines())
                if main_files:
                    branch_files = set(ctx.run(["git", "diff", "--name-only", f"{mb}..{b}"]).stdout.splitlines())
                    overlap = bool(main_files & branch_files)
        return behind, overlap
    roots = sorted({b for p in projs for b in p.get("mergeable", [])})
    with ThreadPoolExecutor(max_workers=8) as ex:
        fresh = dict(zip(roots, ex.map(_root_fresh, roots)))
    merges = _scan_merges()
    for p in projs:
        p["ready"], p["candidates"] = _ready_to_merge(p.get("mergeable", []), prmap)
        bs = p.get("mergeable", [])
        p["behind"] = max((fresh[b][0] for b in bs), default=0)
        p["overlap"] = any(fresh[b][1] for b in bs)
        p["merged"] = merges.get(p["name"])
    payload = json.dumps(projs)
    _pcache.clear()
    _pcache[pck] = payload
    req._send(200, payload)


def project_opened(req):
    req._send(200, json.dumps(_opened_load()))


def standalone_list(req):
    r = ctx.run([os.path.join(ctx.SCRIPTS, "stack-forest"), "--standalone"])
    req._send(200, r.stdout or "[]")


def _repo_web_url(remote):   # git@github.com:o/r.git | https://github.com/o/r.git → https web url
    raw = ctx.run(["git", "remote", "get-url", remote]).stdout.strip()
    m = re.search(r"github\.com[:/](.+?)(?:\.git)?$", raw) if raw else None
    return f"https://github.com/{m.group(1)}" if m else ""


def branch_url(req, u):   # GET /branch-url?branch= — the branch's open-PR url, else a compare view
    branch = (parse_qs(u.query).get("branch") or [""])[0]
    if not branch:
        req._send(400, json.dumps({"url": ""}))
        return
    url = ctx.run(["gh", "pr", "view", branch, "--json", "url", "-q", ".url"]).stdout.strip()
    if not url:
        # no PR → compare against main on the repo this branch pushes to (its fork), else origin.
        remote = ctx.run(["git", "config", "--get", f"branch.{branch}.remote"]).stdout.strip() or "origin"
        base = _repo_web_url(remote)
        if base:
            main = ctx.run(["git", "config", "stack.main-branch"]).stdout.strip() or "main"
            url = f"{base}/compare/{main}...{branch}"
    req._send(200, json.dumps({"url": url}))


def branches(req):
    # typeahead for pinning: all local heads, most-recent-first, minus main + the pinned.
    main = ctx.run(["git", "config", "stack.main-branch"]).stdout.strip() or "main"
    pinned = set(ctx.run(["git", "config", "--get-all", "stack.standalone"]).stdout.splitlines())
    heads = ctx.run(["git", "for-each-ref", "--sort=-committerdate", "refs/heads",
                     "--format=%(refname:short)"]).stdout.splitlines()
    req._send(200, json.dumps([b for b in heads if b and b != main and b not in pinned]))


# --- POST handlers ---

def pin(req, raw):   # POST /standalone — pin/unpin a branch in the watch list
    d = json.loads(raw or "{}")
    branch = d.get("branch", "").strip()
    if not branch:
        req._send(400, json.dumps({"ok": False, "err": "no branch"}))
        return
    if d.get("op") == "remove":
        # --fixed-value (git ≥2.30) treats the value as literal, not a regex — MUST
        # precede --unset-all. Handles branch names with regex-special chars.
        ctx.run(["git", "config", "--fixed-value", "--unset-all", "stack.standalone", branch])
        req._send(200, json.dumps({"ok": True}))
        return
    if ctx.run(["git", "rev-parse", "--verify", "--quiet", "refs/heads/" + branch]).returncode != 0:
        req._send(404, json.dumps({"ok": False, "err": "no such local branch"}))
        return
    if branch not in ctx.run(["git", "config", "--get-all", "stack.standalone"]).stdout.splitlines():
        ctx.run(["git", "config", "--add", "stack.standalone", branch])
    req._send(200, json.dumps({"ok": True}))


def open_file(req, raw):   # POST /open — open a file on a branch in the warm review-nvim
    d = json.loads(raw or "{}")
    args = [os.path.join(ctx.SCRIPTS, "stack-open"), d.get("branch", ""), d.get("path", "")]
    pos = d.get("pos") or d.get("line")   # opaque locator; forwarded verbatim — stack-open owns the grammar
    if pos:
        args.append(str(pos))
    # Bound it: stack-open probes the warm review-nvim, which hangs indefinitely if that
    # nvim is wedged (e.g. stuck on a prompt). Without a timeout the /open request — and
    # its server thread — pends forever, and each hung probe leaks an nvim. Run in its own
    # process group and SIGKILL the whole group on timeout so hover+o fails visibly fast
    # instead of spinning, and no zombie probe is left behind.
    proc = subprocess.Popen(args, cwd=ctx.CWD, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                            text=True, start_new_session=True)
    try:
        out, err = proc.communicate(timeout=8)
    except subprocess.TimeoutExpired:
        try:
            os.killpg(os.getpgid(proc.pid), signal.SIGKILL)
        except ProcessLookupError:
            pass
        proc.communicate()
        req._send(504, json.dumps({"ok": False, "err": "stack-open timed out — the review-nvim is unresponsive (wedged on a prompt?)"}))
        return
    if proc.returncode == 0:
        _record_open(d.get("branch", ""))   # stamp recency for the no-PR picker ordering
    req._send(200 if proc.returncode == 0 else 500,
              json.dumps({"ok": proc.returncode == 0, "out": out, "err": err}))


def drop_project(req, raw):   # POST /drop-project — forget a forest grouping (config only; branches kept)
    d = json.loads(raw or "{}")
    project = d.get("project", "").strip()
    if not project:
        req._send(400, json.dumps({"ok": False, "err": "no project"}))
        return
    members = ctx.run(["git", "config", "--get-all", f"stack-project.{project}.branch"]).stdout.splitlines()
    # Untag each member, but only if it still points at THIS project — a branch since
    # retagged into another forest must keep its newer tag.
    untagged = 0
    for b in (m.strip() for m in members):
        if not b:
            continue
        if ctx.run(["git", "config", f"stack-branch.{b}.project"]).stdout.strip() == project:
            ctx.run(["git", "config", "--unset", f"stack-branch.{b}.project"])
            untagged += 1
    # Drop the whole [stack-project "<name>"] section (the branch list + any sibling keys).
    ctx.run(["git", "config", "--remove-section", f"stack-project.{project}"])
    req._send(200, json.dumps({"ok": True, "dropped": project, "untagged": untagged}))


def steer(req, raw):   # POST /steer — launch the Steer workspace (headless-claude design convo)
    d = json.loads(raw or "{}")
    args = [os.path.join(ctx.SCRIPTS, "steer-open"), d.get("branch", "")]
    p = d.get("path")   # the file the user is focused on; steer-open falls back to top-changed .ts
    if p:
        args.append(p)
    r = ctx.run(args)
    req._send(200 if r.returncode == 0 else 500,
              json.dumps({"ok": r.returncode == 0, "out": r.stdout, "err": r.stderr}))
