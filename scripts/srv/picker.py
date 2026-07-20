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
import hashlib
import threading
import subprocess
from concurrent.futures import ThreadPoolExecutor
from urllib.parse import parse_qs

from . import ctx

_pcache = {}  # repo-name -> ((content-sig, origin-main-sha), [projects]) — the per-repo fan-out is expensive
_PROJ_SNAP_V = 5  # projects card shape version — bump when a build adds a field, else the
                  # disk snapshot (keyed only on repo state) keeps serving the old shape
_PR_RE = re.compile(r"\(#(\d+)\)")


def _opened_file():
    # project -> epoch of the last hover+o file-open, kept in the git-common-dir so it
    # survives across worktrees. Drives the "recently touched first" ordering.
    gd = ctx.run(["git", "rev-parse", "--git-common-dir"]).stdout.strip()
    if gd and not os.path.isabs(gd):
        gd = os.path.join(ctx.repo_cwd(), gd)
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
    proj = (ctx.run(["git", "config", f"branch.{branch}.stack-project"]).stdout.strip()
            or ctx.run(["git", "config", f"stack-branch.{branch}.project"]).stdout.strip())
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


def _ready_to_merge(mergeable, prs, merged=()):
    """Split stack-forest's topologically-mergeable branches by PR state:
      ready      — an open PR already exists (the green into-main edge-bar set)
      candidates — no PR yet, but clear to merge straight into main.
    Pure split, input order preserved. A branch whose work already landed is in
    neither: its PR closed on merge, so "no open PR" would otherwise promote it to
    a candidate and the row would advertise pushing work that's already in main.
    It needs a contract, which the restack pre-pass does."""
    ready, candidates = [], []
    for b in mergeable:
        if b in merged:
            continue
        (ready if b in prs else candidates).append(b)
    return ready, candidates


def _merges_file():
    # project -> last merge-into-main {pr,title,at,branch}, kept in the git-common-dir
    # so it survives restarts and is shared across worktrees. Drives the "merged Xm
    # ago" recency badge on the picker cards.
    gd = ctx.run(["git", "rev-parse", "--git-common-dir"]).stdout.strip()
    if gd and not os.path.isabs(gd):
        gd = os.path.join(ctx.repo_cwd(), gd)
    return os.path.join(gd, "stack-project-merges.json") if gd else ""


def _gh_pr(num):
    # Resolve a (possibly already-merged) PR to its head branch + title. Bounded so a
    # slow/offline GitHub never stalls the picker; any failure → None (just no badge).
    try:
        r = subprocess.run(["gh", "pr", "view", str(num), "--json", "headRefName,title"],
                           cwd=ctx.repo_cwd(), capture_output=True, text=True, timeout=6)
        if r.returncode != 0:
            return None
        d = json.loads(r.stdout or "{}")
        return d.get("headRefName") or "", d.get("title") or ""
    except Exception:
        return None


def _is_trunk(branch):
    # A trunk anchor: an approved-but-unmerged node the forest treats as its base
    # (stack-branch.<b>.trunk=true). Set/cleared via POST /trunk; dies with the branch.
    return (ctx.run(["git", "config", "--bool", f"branch.{branch}.stack-trunk"]).stdout.strip()
            or ctx.run(["git", "config", "--bool", f"stack-branch.{branch}.trunk"]).stdout.strip()) == "true"


def _base_of(branch):
    # The ref a branch is measured for freshness against — and, later, rebased onto. A trunk anchor
    # is frozen (approved, merges as-is), so it's measured against ITSELF → never "behind main," and
    # later never rebased onto main (its descendants rebase onto it instead). Everything else sits on
    # origin/main. This is the ONE seam so trunk overrides main in a single place, not scattered.
    if _is_trunk(branch):
        return branch
    return "origin/main"


def _project_of(branch):
    p = (ctx.run(["git", "config", f"branch.{branch}.stack-project"]).stdout.strip()
         or ctx.run(["git", "config", f"stack-branch.{branch}.project"]).stdout.strip())
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


def _live_roster():
    """Every branch's project, read from the live config."""
    out = {}
    for line in ctx.run(["git", "config", "--get-regexp",
                         r"^stack-project\..*\.branch$"]).stdout.splitlines():
        k, _, v = line.partition(" ")
        m = re.match(r"^stack-project\.(.+)\.branch$", k)
        if m and v.strip():
            out[v.strip()] = m.group(1)
    for line in ctx.run(["git", "config", "--get-regexp",
                         r"^stack-branch\..*\.project$"]).stdout.splitlines():
        k, _, v = line.partition(" ")
        m = re.match(r"^stack-branch\.(.+)\.project$", k)
        if m and v.strip():
            out[m.group(1)] = v.strip()
    for line in ctx.run(["git", "config", "--get-regexp",
                         r"^branch\..*\.stack-project$"]).stdout.splitlines():
        k, _, v = line.partition(" ")
        m = re.match(r"^branch\.(.+)\.stack-project$", k)
        if m and v.strip():
            out[m.group(1)] = v.strip()
    return out


def _scan_merges():
    # Walk new origin/main commits since the last scan; attribute each squash-merge
    # (subject "… (#N)") to a project via its head branch's project tag, and keep a
    # newest-first history per project. The store persists, so the badges survive
    # restarts and linger after the now-empty nodes are contracted.
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
    for k, v in list(merges.items()):   # migrate pre-history stores (one dict per project)
        if isinstance(v, dict):
            merges[k] = [v]
    # A merge DESTROYS the very config that says which project the branch belonged to: GitHub
    # deletes the head branch, and contraction drops its tags. Merging on GitHub (rather than
    # through this viewer) meant the scan below always arrived too late and dropped the merge
    # silently — the project forgot a step it had shipped. So carry a roster forward: it is
    # refreshed from live config on every scan, while the branches are still alive.
    roster = store.get("roster", {})
    roster.update(_live_roster())
    for line in reversed(log):   # oldest-first so newer merges land at the head
        at, _, subj = line.partition("\t")
        nums = _PR_RE.findall(subj)
        if not nums:
            continue
        res = _gh_pr(int(nums[-1]))
        if not res:
            continue
        branch, title = res
        proj = (_project_of(branch) or roster.get(branch)) if branch else None
        if proj:
            hist = merges.setdefault(proj, [])
            hist[:] = [e for e in hist if e.get("pr") != int(nums[-1])]
            hist.insert(0, {"pr": int(nums[-1]), "title": title or subj, "at": at, "branch": branch})
            # The plan numbers every step a project ever shipped, so this history is the only
            # record of the early ones — the branches are long gone. Keep enough that a long
            # forest never renumbers itself by forgetting where it started.
            del hist[64:]
    try:
        if path:
            with open(path, "w") as f:
                json.dump({"tip": tip, "merges": merges, "roster": roster}, f)
    except Exception:
        pass
    return merges


_shipped_cache = {}  # repo name → ((origin-main-sha, since-date), {project: shipped}) — one gh call per main move


def _shipped_by_project(name, tip, merges, members):
    # Merged-PR history per project over the past month, asked of GitHub itself — the local
    # merge journal only knows merges the daemon witnessed (it missed e.g. deps-helper #9491),
    # and this is what classes a forest as "shipping" on the home. Head branches map to
    # projects via branch config (stack-project lists keep entries for deleted branches,
    # which is exactly what resolves already-contracted heads), journal attributions as
    # fallback. gh failure → last known map, never a stall and never a lost class.
    since = time.strftime("%Y-%m-%d", time.localtime(time.time() - 30 * 86400))
    key = (tip, since)
    cached = _shipped_cache.get(name)
    if cached and cached[0] == key:
        return cached[1]
    try:
        r = subprocess.run(["gh", "pr", "list", "--state", "merged", "--author", "@me",
                            "--search", f"merged:>={since}", "--limit", "100",
                            "--json", "number,headRefName,mergedAt,title"],
                           cwd=ctx.repo_cwd(), capture_output=True, text=True, timeout=20)
        prs = json.loads(r.stdout or "[]") if r.returncode == 0 else None
    except Exception:
        prs = None
    if prs is None:
        return cached[1] if cached else {}
    to_proj = {}
    for line in ctx.run(["git", "config", "--get-regexp",
                         r"^stack-project\..*\.branch$"]).stdout.splitlines():
        k, _, b = line.partition(" ")
        if b and k.endswith(".branch"):
            to_proj.setdefault(b.strip(), k[len("stack-project."):-len(".branch")])
    for line in ctx.run(["git", "config", "--get-regexp",
                         r"^stack-branch\..*\.project$"]).stdout.splitlines():
        k, _, proj = line.partition(" ")
        if proj and k.endswith(".project"):
            to_proj[k[len("stack-branch."):-len(".project")]] = proj.strip()
    for line in ctx.run(["git", "config", "--get-regexp",
                         r"^branch\..*\.stack-project$"]).stdout.splitlines():
        k, _, proj = line.partition(" ")
        if proj and k.endswith(".stack-project"):
            to_proj[k[len("branch."):-len(".stack-project")]] = proj.strip()
    # journal fallback, LIVE projects only — journal keys outlive their forests by design,
    # and a dead name (a renamed effort like goal-metrics-page-job) would both steal the
    # head from its live successor and poison the prefix family into ambiguity.
    live = set(members) | set(to_proj.values())
    for proj, hist in merges.items():
        if proj not in live:
            continue
        for e in hist:
            if e.get("branch"):
                to_proj.setdefault(e["branch"], proj)
    # contracted heads lose their config — recover them through name families, but only
    # when unambiguous: a head named exactly like a project, or a slash-prefix owned by
    # exactly one project (goal-metrics/* → goal-metrics-dedup). Ambiguous (goals/*
    # spans several forests) stays unmapped rather than guessed.
    names = live
    fam = {}
    for b, proj in list(to_proj.items()) + [(b, p) for p, bs in members.items() for b in bs]:
        if "/" in b:
            fam.setdefault(b.split("/", 1)[0], set()).add(proj)

    def resolve(head):
        if not head:
            return None
        if head in to_proj:
            return to_proj[head]
        if head in names:
            return head
        owners = fam.get(head.split("/", 1)[0]) if "/" in head else None
        return next(iter(owners)) if owners and len(owners) == 1 else None

    out = {}
    for pr in sorted(prs, key=lambda x: x.get("mergedAt") or "", reverse=True):
        proj = resolve(pr.get("headRefName"))
        if not proj:
            continue
        s = out.setdefault(proj, {"count": 0, "latest": pr.get("mergedAt"), "prs": []})
        s["count"] += 1
        if len(s["prs"]) < 8:
            s["prs"].append({"pr": pr["number"], "title": pr.get("title"), "at": pr.get("mergedAt")})
    _shipped_cache[name] = (key, out)
    return out


def _project_members():
    # {project: [branch, ...]} from the hand-maintained stack-project.<name>.branch config.
    # Keys are stack-project.<NAME>.branch where NAME may itself contain dots, so peel the
    # fixed prefix/suffix rather than split on ".".
    r = ctx.run(["git", "config", "--get-regexp", r"^stack-project\..*\.branch$"])
    out = {}
    for line in r.stdout.splitlines():
        key, _, branch = line.partition(" ")
        if branch and key.startswith("stack-project.") and key.endswith(".branch"):
            out.setdefault(key[len("stack-project."):-len(".branch")], []).append(branch)
    return out


def _branch_commit_unix():
    # {branch: committer-date-unix} for every local branch — one fan-out, lexically/numeric
    # sortable for the Forests "recently worked on" order.
    r = ctx.run(["git", "for-each-ref", "--format=%(refname:short)%09%(committerdate:unix)", "refs/heads"])
    out = {}
    for line in r.stdout.splitlines():
        branch, _, ts = line.partition("\t")
        if ts.isdigit():
            out[branch] = int(ts)
    return out


def _branch_author_unix():
    # {branch: author-date-unix} — how long since the work was WRITTEN. Committer-date can't answer
    # that here: a rebase rewrites it, so our own restacking backdates every branch to today (one
    # mass restack made a 21-day-old forest read as touched 1d ago). Author-date survives a rebase,
    # so this is the only clock that can see work going stale.
    r = ctx.run(["git", "for-each-ref", "--format=%(refname:short)%09%(authordate:unix)", "refs/heads"])
    out = {}
    for line in r.stdout.splitlines():
        branch, _, ts = line.partition("\t")
        if ts.isdigit():
            out[branch] = int(ts)
    return out


# POST /next — read-only: the branch(es) in THIS branch's forest that can merge into main
# now, in canonical order. Reuses the exact machinery the Forest cards build from
# (stack-forest --projects + stack-prs → _ready_to_merge), so ordering never diverges.
def whats_next(req, raw):
    d = json.loads(raw or "{}")
    branch = d.get("branch", "")
    proj = _project_of(branch) if branch else None
    if not proj:
        return req._send(200, json.dumps({"ok": True, "project": None, "ready": [], "candidates": [],
                                          "summary": "This branch isn't in a forest project — nothing to order."}))
    fr = ctx.run([os.path.join(ctx.SCRIPTS, "stack-forest"), "--projects"])
    pr = ctx.run([os.path.join(ctx.SCRIPTS, "stack-prs")])
    try:
        projs = json.loads(fr.stdout or "[]")
    except Exception:
        projs = []
    try:
        prmap = json.loads(pr.stdout or "{}")
    except Exception:
        prmap = {}
    p = next((x for x in projs if x.get("name") == proj), None)
    ready, candidates = _ready_to_merge(p.get("mergeable", []) if p else [], prmap)
    if ready:
        summary = f"Ready to merge into main now: {', '.join(ready)}"
        if candidates:
            summary += f" · then clear next: {', '.join(candidates)}"
    elif candidates:
        summary = f"No open PRs yet, but clear to merge into main: {', '.join(candidates)}"
    else:
        summary = f"Nothing in “{proj}” is mergeable into main right now."
    return req._send(200, json.dumps({"ok": True, "project": proj, "ready": ready,
                                      "candidates": candidates, "summary": summary}))


def set_trunk(req, raw):   # POST /trunk {branch, on} — mark/unmark a branch as its forest's trunk anchor
    d = json.loads(raw or "{}")
    branch = d.get("branch", "")
    on = d.get("on", True)
    key = f"stack-branch.{branch}.trunk"
    if on:
        ctx.run(["git", "config", key, "true"])
    else:
        ctx.run(["git", "config", "--unset", key])
    req._send(200, json.dumps({"ok": True, "branch": branch, "trunk": bool(on),
                               "summary": f"“{branch}” is {'now the forest trunk — measured against itself, not main' if on else 'no longer the forest trunk'}."}))


# --- GET handlers ---

def prs(req):
    r = ctx.run([os.path.join(ctx.SCRIPTS, "stack-prs")])
    req._send(200, r.stdout or "{}")


def myprs(req):
    r = ctx.run([os.path.join(ctx.SCRIPTS, "my-prs")])
    req._send(200, r.stdout or "[]")


def _unpushed_map():
    # {branch: True} for a local branch whose tip matches no remote-tracking ref of the same name.
    # Remote-tracking refs are local, so this is one for-each-ref rather than a fetch per branch —
    # it reads a never-pushed branch as unpushed even behind a stale fetch, which is the safe way
    # to be wrong: the band's job is to notice work that never left this machine.
    heads, remotes = {}, {}
    for line in ctx.run(["git", "for-each-ref", "--format=%(refname) %(objectname)",
                         "refs/heads", "refs/remotes"]).stdout.splitlines():
        ref, _, sha = line.partition(" ")
        if ref.startswith("refs/heads/"):
            heads[ref[len("refs/heads/"):]] = sha
        elif ref.startswith("refs/remotes/"):
            _, _, branch = ref[len("refs/remotes/"):].partition("/")
            remotes.setdefault(branch, set()).add(sha)
    return {b: sha not in remotes.get(b, ()) for b, sha in heads.items()}


def _green_set():
    # {branch} whose gates verdict still stands. stack-branch.<b>.gates-green-tree records the TREE
    # the gates passed on, so a reworded commit keeps its verdict and a real edit drops it.
    recorded = {}
    for line in ctx.run(["git", "config", "--get-regexp",
                         r"^stack-branch\..*\.gates-green-tree$"]).stdout.splitlines():
        key, _, val = line.partition(" ")
        m = re.match(r"^stack-branch\.(.+)\.gates-green-tree$", key)
        if m and val.strip():
            recorded[m.group(1)] = val.strip()
    for line in ctx.run(["git", "config", "--get-regexp",
                         r"^branch\..*\.stack-gates-green-tree$"]).stdout.splitlines():
        key, _, val = line.partition(" ")
        m = re.match(r"^branch\.(.+)\.stack-gates-green-tree$", key)
        if m and val.strip():
            recorded[m.group(1)] = val.strip()
    if not recorded:
        return set()
    trees = dict(l.partition(" ")[::2] for l in ctx.run(
        ["git", "for-each-ref", "--format=%(refname:short) %(tree)", "refs/heads"]).stdout.splitlines())
    return {b for b, tree in recorded.items() if trees.get(b) == tree}


_gd_cache = {}   # repo path -> git-common-dir; never changes for a live repo, so spawn once


def _git_common_dir():
    repo = ctx.repo_cwd()
    gd = _gd_cache.get(repo)
    if gd is None:
        gd = ctx.run(["git", "rev-parse", "--path-format=absolute", "--git-common-dir"]).stdout.strip()
        _gd_cache[repo] = gd
    return gd


def _projects_snapshot_file():
    gd = _git_common_dir()
    return os.path.join(gd, "stack-projects-cache.json") if gd else ""


_OVERLAY_SUFFIXES = (".interest", ".shelved", ".focus", ".tier", ".epic")


def _is_overlay_line(line):
    # config lines the OVERLAY serves (triage axes + gates verdicts) — they change the
    # response without invalidating the heavy build, so the cache key must not see them.
    key = line.partition(" ")[0]
    if key.startswith("stack-project.") and key.endswith(_OVERLAY_SUFFIXES):
        return True
    return key.endswith(".gates-green-tree")


def _projects_state(path):
    # One parallel sweep gathers what both the cache KEY and the live overlay need. The key
    # is CONTENT the cards are built from — ref tips (remotes too: unpushed/behind/PR pushes
    # must bust) + the stack config lines + bless ledger — never the config file's mtime:
    # concurrent sessions constantly touch unrelated keys, and every touch was a ~8s re-fan.
    with ThreadPoolExecutor(max_workers=4, initializer=ctx.set_repo, initargs=(path,)) as ex:
        f_refs = ex.submit(ctx.run, ["git", "for-each-ref", "--format=%(refname) %(objectname)",
                                     "refs/heads", "refs/remotes"])
        f_cfg = ex.submit(ctx.run, ["git", "config", "--get-regexp",
                                    r"^(stack-branch|stack-project|branch)\."])
        f_main = ex.submit(ctx.run, ["git", "rev-parse", "origin/main"])
        f_green = ex.submit(_green_set)
    refs, cfg = f_refs.result().stdout, f_cfg.result().stdout
    gd = _git_common_dir()

    def mt(p):
        try:
            return os.path.getmtime(p)
        except OSError:
            return 0
    heavy = "".join(l + "\n" for l in cfg.splitlines() if not _is_overlay_line(l))
    stamp = (refs + heavy
             + str(mt(os.path.join(gd, "stack-blessed.json")))
             + str(mt(os.path.join(gd, "stack-blessed-contrib.json"))))
    pck = (hashlib.sha1(stamp.encode()).hexdigest(), f_main.result().stdout.strip())
    return pck, cfg, f_green.result()


def _overlay_live(projs, cfg, green):
    # The axes Phil clicks all day (interest/shelve/focus/tier/epic) plus gates verdicts get
    # painted fresh onto the cached build every serve — flipping one repaints, never rebuilds.
    meta, members = {}, {}
    for line in cfg.splitlines():
        key, _, val = line.partition(" ")
        if not key.startswith("stack-project."):
            continue
        body = key[len("stack-project."):]
        if key.endswith(".branch") and val:
            members.setdefault(body[:-len(".branch")], []).append(val)
            continue
        for suf in _OVERLAY_SUFFIXES:
            if key.endswith(suf):
                meta.setdefault(body[:-len(suf)], {})[suf[1:]] = val.strip()
                break

    def pos_int(v):
        return int(v) if v and v.lstrip("-").isdigit() and int(v) > 0 else None
    out = []
    for p in projs:
        p = dict(p)   # never mutate the cached build — concurrent serves share it
        m = meta.get(p["name"], {})
        p["interest"] = pos_int(m.get("interest")) or 0
        p["shelved"] = m.get("shelved") == "true"
        p["focus"] = pos_int(m.get("focus"))
        tier = m.get("tier")
        p["tier"] = tier if tier in ("committed", "trying", "spike") else None
        p["epic"] = m.get("epic") or None
        branches = members.get(p["name"]) or p.get("mergeable", [])
        p["green"] = sum(1 for b in branches if b in green)
        out.append(p)
    return out


# single-flight: N concurrent cold /projects each ran their OWN multi-second git fan-out
# (dozens of subprocesses), starving the accept queue into connection-refused. Misses now
# queue on one build and re-check the cache inside the lock.
_pbuild_lock = threading.Lock()


def _projects_for(name, path):
    # Build one repo's project cards. The active repo is already pinned on this (request)
    # thread, but the fan-out pools below run on WORKER threads that don't inherit the
    # thread-local — so each pool seeds it via initializer=ctx.set_repo, else the workers
    # would query CWD (loops) for a monotoad build. Returns the tagged list (repo=name).
    pck, cfg, green = _projects_state(path)
    cached = _pcache.get(name)
    if cached and cached[0] == pck:
        return _overlay_live(cached[1], cfg, green)
    with _pbuild_lock:
        cached = _pcache.get(name)   # a queued waiter finds the winner's build here
        if cached and cached[0] == pck:
            return _overlay_live(cached[1], cfg, green)
        return _overlay_live(_projects_build(name, path, pck), cfg, green)


def _projects_build(name, path, pck):
    # The in-memory cache dies with the process, and the server re-execs on every srv/*.py
    # edit — so a restarted server's first /projects paid the full ~3s fan-out even when
    # nothing in the repo moved. A disk snapshot keyed on the same validation pair survives
    # restarts: sig matches → serve it instantly, sig differs → fall through and rebuild.
    snap_file = _projects_snapshot_file()
    if snap_file and os.path.exists(snap_file):
        try:
            snap = json.load(open(snap_file))
            if tuple(snap.get("pck") or ()) == pck and snap.get("v") == _PROJ_SNAP_V:
                _pcache[name] = (pck, snap["projs"])
                return snap["projs"]
        except Exception:
            pass
    # stack-forest --projects and stack-prs are independent → run concurrently.
    with ThreadPoolExecutor(max_workers=2, initializer=ctx.set_repo, initargs=(path,)) as ex:
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
        base = _base_of(b)
        n = ctx.run(["git", "rev-list", "--count", f"{b}..{base}"]).stdout.strip()
        behind = int(n) if n.isdigit() else 0
        overlap, merged = False, False
        if behind:
            mb = ctx.run(["git", "merge-base", b, base]).stdout.strip()
            if mb:
                base_files = set(ctx.run(["git", "diff", "--name-only", f"{mb}..{base}"]).stdout.splitlines())
                branch_files = set(ctx.run(["git", "diff", "--name-only", f"{mb}..{b}"]).stdout.splitlines())
                if base_files:
                    overlap = bool(base_files & branch_files)
                # Squash-merged: the branch's OWN files already match base, though its
                # history diverges and the rest of the tree has moved on. Same predicate
                # rebase-classify contracts on (VERDICT=already-merged). Scoped to the
                # branch's files — a whole-tree compare answers a different question.
                if branch_files:
                    merged = ctx.run(["git", "diff", "--quiet", base, b, "--", *branch_files]).returncode == 0
        return behind, overlap, merged
    roots = sorted({b for p in projs for b in p.get("mergeable", [])})
    with ThreadPoolExecutor(max_workers=8, initializer=ctx.set_repo, initargs=(path,)) as ex:
        fresh = dict(zip(roots, ex.map(_root_fresh, roots)))
    merges = _scan_merges()
    # Recency signals for the Forests sort: newest local commit (unix secs) across every member
    # branch, and newest PR open-date — so a forest's whole tree counts, not just its roots.
    members = _project_members()
    shipped = _shipped_by_project(name, pck[1], merges, members)
    commits = _branch_commit_unix()
    authored = _branch_author_unix()
    unpushed = _unpushed_map()
    for p in projs:
        p["repo"] = name
        bs = p.get("mergeable", [])
        # Roots whose work is in main but whose node is still in the forest — the restack
        # pre-pass drops+rewires them. This is live state, unlike the `landed` badge below,
        # which is history and lingers after the node is contracted.
        p["mergedNodes"] = [b for b in bs if fresh[b][2]]
        p["ready"], p["candidates"] = _ready_to_merge(bs, prmap, set(p["mergedNodes"]))
        p["behind"] = max((fresh[b][0] for b in bs), default=0)
        p["overlap"] = any(fresh[b][1] for b in bs)
        landed = merges.get(p["name"]) or []
        p["merged"] = landed[0] if landed else None
        p["landed"] = landed
        p["shipped"] = shipped.get(p["name"])
        branches = members.get(p["name"]) or bs
        p["trunk"] = next((b for b in branches if _is_trunk(b)), None)   # the forest's frozen base, if any
        p["unpushed"] = sum(1 for b in branches if unpushed.get(b, False))
        p["lastCommit"] = max((commits[b] for b in branches if b in commits), default=None)
        p["lastAuthored"] = max((authored[b] for b in branches if b in authored), default=None)
        p["prOpened"] = max((prmap[b]["createdAt"] for b in branches
                             if b in prmap and prmap[b].get("createdAt")), default=None)
    _pcache[name] = (pck, projs)   # one cached build per repo (keyed by its own model_sig)
    if snap_file:
        try:
            with open(snap_file, "w") as f:
                json.dump({"pck": list(pck), "v": _PROJ_SNAP_V, "projs": projs}, f)
        except OSError:
            pass
    return projs


def warm_projects():
    """Boot-time warm: build (or disk-load) every repo's project cards before the first
    page load asks — the Forests home's body is /projects, and cold it's a ~3s fan-out."""
    repos = ctx.REPOS or {os.path.basename(ctx.CWD): ctx.CWD}
    for name, path in repos.items():
        ctx.set_repo(path)
        try:
            _projects_for(name, path)
        except Exception:
            pass
        finally:
            ctx.clear_repo()


def projects(req):
    # Aggregate every registry repo's forests into one list, tagged by repo. Pin each repo on
    # this thread in turn (its build + pool workers read it); fall back to the launched repo
    # when the registry is empty. Each repo caches independently on its own model_sig.
    repos = ctx.REPOS or {os.path.basename(ctx.CWD): ctx.CWD}
    out = []
    for name, path in repos.items():
        ctx.set_repo(path)
        try:
            out.extend(_projects_for(name, path))
        except Exception:
            pass   # one unreachable/half-set-up repo must not blank the whole home list
        finally:
            ctx.clear_repo()
    req._send(200, json.dumps(out))


def project_opened(req):
    req._send(200, json.dumps(_opened_load()))


_standalone_cache = {}   # repo -> (model_sig, json) — stack-forest --standalone is ~1s of git fan-out


def standalone_list(req):
    repo = ctx.repo_cwd()
    sig = ctx.model_sig()
    hit = _standalone_cache.get(repo)
    if hit and hit[0] == sig:
        req._send(200, hit[1])
        return
    raw = ctx.run([os.path.join(ctx.SCRIPTS, "stack-forest"), "--standalone"]).stdout
    try:
        items = json.loads(raw or "[]")
    except json.JSONDecodeError:
        req._send(200, raw or "[]")
        return
    kept = []
    for it in items:
        b = it.get("branch", "")
        empty = it.get("commits", 0) == 0 and it.get("add", 0) == 0 and it.get("del", 0) == 0
        # a watched review PR with nothing left to review (empty diff vs main) has merged — auto-
        # drop it so the watch list self-cleans. Scoped to review/pr-* so a freshly-pinned branch
        # (also momentarily 0/0/0) isn't yanked out from under you.
        if b.startswith("review/pr-") and empty:
            ctx.run(["git", "config", "--fixed-value", "--unset-all", "stack.standalone", b])
            continue
        kept.append(it)
    payload = json.dumps(kept)
    # an unpin above touched config → sig already moved; storing the pre-unpin sig just
    # means one extra rebuild next call, then it settles.
    _standalone_cache[repo] = (sig, payload)
    req._send(200, payload)


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
            if remote == "origin":
                from srv import push
                cmp_base = push._pr_base(branch)
            else:
                cmp_base = ctx.run(["git", "config", "stack.main-branch"]).stdout.strip() or "main"
            url = f"{base}/compare/{cmp_base}...{branch}"
    req._send(200, json.dumps({"url": url}))


def branches(req):
    # typeahead for pinning: all local heads, most-recent-first, minus main + the pinned.
    main = ctx.run(["git", "config", "stack.main-branch"]).stdout.strip() or "main"
    pinned = set(ctx.run(["git", "config", "--get-all", "stack.standalone"]).stdout.splitlines())
    heads = ctx.run(["git", "for-each-ref", "--sort=-committerdate", "refs/heads",
                     "--format=%(refname:short)"]).stdout.splitlines()
    req._send(200, json.dumps([b for b in heads if b and b != main and b not in pinned]))


def forest_branches(req):
    # Every (branch, project, repo) the forest config names across ALL registry repos — the
    # Cmd+K global jump index. Pure config read per repo (no model rebuild, no fan-out), so it's
    # cheap to call on every palette open. The .branch list rots independently of the computed
    # model, so the palette still lists a forest's true nodes from /model when one is open.
    repos = ctx.REPOS or {os.path.basename(ctx.CWD): ctx.CWD}
    pairs = []
    for name, path in repos.items():
        ctx.set_repo(path)
        try:
            for line in ctx.run(["git", "config", "--get-regexp",
                                 r"^stack-project\..*\.branch$"]).stdout.splitlines():
                k, _, v = line.partition(" ")
                b = v.strip()
                m = re.match(r"^stack-project\.(.+)\.branch$", k)
                if b and m:
                    pairs.append({"branch": b, "project": m.group(1), "repo": name})
        finally:
            ctx.clear_repo()
    req._send(200, json.dumps(pairs))


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


def promote(req, raw):   # POST /promote — graduate a watched branch into its own forest project
    d = json.loads(raw or "{}")
    branch = d.get("branch", "").strip()
    if not branch:
        req._send(400, json.dumps({"ok": False, "err": "no branch"}))
        return
    if ctx.run(["git", "rev-parse", "--verify", "--quiet", "refs/heads/" + branch]).returncode != 0:
        req._send(404, json.dumps({"ok": False, "err": "no such local branch"}))
        return
    project = branch.rsplit("/", 1)[-1]   # the branch leaf becomes the forest tag
    main = ctx.run(["git", "config", "stack.main-branch"]).stdout.strip() or "main"
    ctx.run(["git", "config", f"stack-branch.{branch}.parent", main])   # forks off main → a root
    ctx.run(["git", "config", f"stack-branch.{branch}.project", project])
    members = ctx.run(["git", "config", "--get-all", f"stack-project.{project}.branch"]).stdout.splitlines()
    if branch not in members:
        ctx.run(["git", "config", "--add", f"stack-project.{project}.branch", branch])
    # it's a forest now, not a loose watched branch — drop it from the watch list.
    ctx.run(["git", "config", "--fixed-value", "--unset-all", "stack.standalone", branch])
    req._send(200, json.dumps({"ok": True, "project": project}))


def open_on_branch(branch, path, pos=None):   # open <path> on <branch> in the warm review-nvim
    # pos is an opaque locator forwarded verbatim — stack-open owns the grammar ("<line>" or "<line>:<col>").
    # Returns (code, out, err); code 504 marks a wedged-nvim timeout. Stamps recency on success.
    args = [os.path.join(ctx.SCRIPTS, "stack-open"), branch, path]
    if pos:
        args.append(str(pos))
    # Bound it: stack-open probes the warm review-nvim, which hangs indefinitely if that
    # nvim is wedged (e.g. stuck on a prompt). Without a timeout the /open request — and
    # its server thread — pends forever, and each hung probe leaks an nvim. Run in its own
    # process group and SIGKILL the whole group on timeout so hover+o fails visibly fast
    # instead of spinning, and no zombie probe is left behind.
    proc = subprocess.Popen(args, cwd=ctx.repo_cwd(), stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                            text=True, start_new_session=True)
    try:
        out, err = proc.communicate(timeout=8)
    except subprocess.TimeoutExpired:
        try:
            os.killpg(os.getpgid(proc.pid), signal.SIGKILL)
        except ProcessLookupError:
            pass
        proc.communicate()
        return 504, "", "stack-open timed out — the review-nvim is unresponsive (wedged on a prompt?)"
    if proc.returncode == 0:
        _record_open(branch)   # stamp recency for the no-PR picker ordering
    return proc.returncode, out, err


def open_here(path, pos=None):   # open <path> in the MAIN working checkout (stack-open --here)
    # For a GitHub blob view: no PR/branch to resolve — land in the editable checkout at the
    # line. Same wedged-nvim guard + 8s bound as open_on_branch.
    args = [os.path.join(ctx.SCRIPTS, "stack-open"), "--here", path]
    if pos:
        args.append(str(pos))
    proc = subprocess.Popen(args, cwd=ctx.repo_cwd(), stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                            text=True, start_new_session=True)
    try:
        out, err = proc.communicate(timeout=8)
    except subprocess.TimeoutExpired:
        try:
            os.killpg(os.getpgid(proc.pid), signal.SIGKILL)
        except ProcessLookupError:
            pass
        proc.communicate()
        return 504, "", "stack-open --here timed out — the review-nvim is unresponsive"
    return proc.returncode, out, err


def review_on_branch(branch):   # open <branch> as the whole-PR gm Diffview in the warm review-nvim
    # mirrors open_on_branch's wedged-nvim guard; the longer timeout covers <leader>gm's
    # origin/main fetch + Diffview build.
    args = [os.path.join(ctx.SCRIPTS, "stack-open"), "--review", branch]
    proc = subprocess.Popen(args, cwd=ctx.repo_cwd(), stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                            text=True, start_new_session=True)
    try:
        out, err = proc.communicate(timeout=20)
    except subprocess.TimeoutExpired:
        try:
            os.killpg(os.getpgid(proc.pid), signal.SIGKILL)
        except ProcessLookupError:
            pass
        proc.communicate()
        return 504, "", "stack-open --review timed out"
    if proc.returncode == 0:
        _record_open(branch)
    return proc.returncode, out, err


def prepare_branch(branch):   # background worktree prefetch (stack-open --prepare) — fire-and-forget
    subprocess.Popen([os.path.join(ctx.SCRIPTS, "stack-open"), "--prepare", branch],
                     cwd=ctx.repo_cwd(), stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)


def open_file(req, raw):   # POST /open — open a file on a branch in the warm review-nvim
    d = json.loads(raw or "{}")
    code, out, err = open_on_branch(d.get("branch", ""), d.get("path", ""), d.get("pos") or d.get("line"))
    if code == 504:
        req._send(504, json.dumps({"ok": False, "err": err}))
        return
    req._send(200 if code == 0 else 500,
              json.dumps({"ok": code == 0, "out": out, "err": err}))


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
        if (ctx.run(["git", "config", f"branch.{b}.stack-project"]).stdout.strip()
                or ctx.run(["git", "config", f"stack-branch.{b}.project"]).stdout.strip()) == project:
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
