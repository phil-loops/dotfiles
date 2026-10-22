# srv/outbox.py — the shipping desk: every forest with unlanded work, each node in merge order with
# what a push-or-open decision needs (own commits, pushed?, gates verdict for this tree, the title
# that will land, the PR and what an approved one is waiting on, a hold-for-morning stamp).
#
#   GET  /outbox[?project=<p>]           the desk; ?project narrows to one forest (the launch sheet polls it)
#   POST /<repo>/outbox-hold {branch|branches|project, until}   stamp branch.<b>.stack-hold-until (""/null clears)
#   POST /<repo>/outbox-title {branch, title}          stamp branch.<b>.stack-pr-title (""/null clears)
#
# Never pushes, never opens a PR, never calls gh on the request path: PR facts come from
# sync's SWR state map plus an open-PR detail cache refreshed in the background here, and
# both bow to $STACK_OUTBOX_PR_FIXTURE (a JSON file, re-read on every call) so a sandbox can
# render every lane — and tick a launch sheet forward by editing the file.
import importlib.machinery
import importlib.util
import json
import os
import re
import subprocess
import threading
import time
from datetime import datetime, timezone
from urllib.parse import parse_qs, quote

from . import ctx, push, repostate, stackcfg, sync

FIXTURE_ENV = "STACK_OUTBOX_PR_FIXTURE"
TRUNKS = ("main", "master", "origin/main")

# Measured 2026-10-21 over Phil's 2026 PRs (wiki/loops/viewer-redesign-evidence): opened at or after
# 15:00 PT → 18.8h median to merge, before → 3.2h; a 4-node forest drained serially ~164h.
WINDOW = {"cliffHourPT": 15, "slowH": 18.8, "fastH": 3.2, "serialForestH": 164, "morningHourPT": 9}


def _fixture():
    path = os.environ.get(FIXTURE_ENV)
    if not path:
        return None
    try:
        with open(path) as f:
            return json.load(f)
    except (OSError, ValueError):
        return {}


# ── open-PR detail: mergeability + approvals, which the shared state map doesn't carry ──
# Its own SWR cache over OPEN PRs only (~2s for a dozen, vs doubling the 500-PR state sweep
# every forest open already waits on). Never blocks: a cold read answers {} and fetches behind.
_DETAIL_TTL = 90.0
_DETAIL = {}
_DETAIL_LOCK = threading.Lock()
_DETAIL_REFRESHING = set()


def _fetch_detail():
    r = ctx.run(["gh", "pr", "list", "--state", "open", "--limit", "200", "--json",
                 "headRefName,number,mergeStateStatus,mergeable,baseRefName,createdAt,latestReviews"],
                timeout=30)
    if r.returncode != 0:
        return None
    try:
        rows = json.loads(r.stdout or "[]")
    except ValueError:
        return None
    out = {}
    for p in rows:
        approvals = [rv for rv in p.get("latestReviews") or [] if rv.get("state") == "APPROVED"]
        out[p.get("headRefName")] = {
            "mergeState": p.get("mergeStateStatus") or "",
            "mergeable": p.get("mergeable") or "",
            "baseRef": p.get("baseRefName") or "",
            "createdAt": p.get("createdAt") or "",
            "approvals": len(approvals),
            "approvedAt": max((rv.get("submittedAt") or "" for rv in approvals), default=""),
        }
    return out


def _refresh_detail(repo):
    try:
        ctx.set_repo(repo)
        fresh = _fetch_detail()
        if fresh is not None:
            with _DETAIL_LOCK:
                _DETAIL[repo] = {"at": time.time(), "data": fresh}
    finally:
        _DETAIL_REFRESHING.discard(repo)


def _detail_map():
    repo = ctx.repo_cwd()
    with _DETAIL_LOCK:
        ent = _DETAIL.get(repo)
        stale = not ent or time.time() - ent["at"] >= _DETAIL_TTL
        if stale and repo not in _DETAIL_REFRESHING:
            _DETAIL_REFRESHING.add(repo)
            threading.Thread(target=_refresh_detail, args=(repo,), daemon=True).start()
        return ent["data"] if ent else {}


def _pr_map():
    """{branch: pr} — the fixture verbatim, else sync's state map overlaid with open-PR detail."""
    fx = _fixture()
    if fx is not None:
        return fx, "fixture"
    states = sync._pr_state_map() or {}
    detail = _detail_map()
    return {b: {**p, **detail.get(b, {})} for b, p in states.items()}, "gh"


# ── merge order: stack-merge-rank's compute(), fed the snapshot's config (no spawn) ──
_RANK_MOD = []


def _rank_mod():
    if not _RANK_MOD:
        path = os.path.join(ctx.SCRIPTS, "stack-merge-rank")
        loader = importlib.machinery.SourceFileLoader("stack_merge_rank", path)
        spec = importlib.util.spec_from_loader("stack_merge_rank", loader)
        mod = importlib.util.module_from_spec(spec)
        loader.exec_module(mod)
        _RANK_MOD.append(mod)
    return _RANK_MOD[0]


def _rank(project, snap):
    conf = snap.once("outbox-conf", lambda: {k: [v.strip() for v in vs] for k, vs in snap.cfg.items()})
    return snap.once(("outbox-rank", project), lambda: _rank_mod().compute(project, conf))


# ── walks: ONE `git log` over every unlanded commit per snapshot, walked in Python ──
_GRAPHS = {}   # repo -> (snapshot fingerprint, Graph)
_TREES = {}   # repo -> (refs fingerprint, {branch: tree})
_TEMPLATE = {}   # (repo, trunk sha) -> the PR template GitHub would otherwise supply


class Graph:
    """Every commit reachable from a stack branch (or its origin copy) but not from trunk, as
    {sha: (parents, subject)}. A per-branch `git log` was ~285 spawns on a cold desk; this is one.
    Anything missing from the map is on trunk."""

    def __init__(self, raw):
        self.commits = {}
        for ln in raw.splitlines():
            sha, _, rest = ln.partition("\x1f")
            parents, _, subject = rest.partition("\x1f")
            self.commits[sha] = (parents.split(), subject)
        self._anc = {}

    def ancestors(self, sha):
        if sha not in self._anc:
            seen, stack = set(), [sha]
            while stack:
                c = stack.pop()
                if c in seen or c not in self.commits:
                    continue
                seen.add(c)
                stack.extend(self.commits[c][0])
            self._anc[sha] = seen
        return self._anc[sha]

    def own(self, tip, base_tip):
        """Subjects newest first along tip's first-parent chain, stopping at anything the base
        (a parent branch's tip, or "" for trunk) already has — `git log --first-parent base..tip`,
        minus trunk commits a stale parent would otherwise drag in."""
        stop = self.ancestors(base_tip) if base_tip else set()
        out, c = [], tip
        while c in self.commits and c not in stop:
            parents, subject = self.commits[c]
            out.append(subject)
            c = parents[0] if parents else ""
        return out


def _graph(snap, trunk):
    repo = ctx.repo_cwd()
    hit = _GRAPHS.get(repo)
    if hit and hit[0] == snap.fingerprint:
        return hit[1]
    tips = sorted({sha for ref, sha in snap.sha.items()
                   if ref.startswith("refs/heads/") or ref.startswith("refs/remotes/origin/")} - {snap.remote(snap.main()), snap.local(snap.main())})
    r = subprocess.run(["git", "log", "--format=%H%x1f%P%x1f%s", "--stdin", "--not", trunk],
                       cwd=repo, input="\n".join(tips) + "\n", capture_output=True, text=True)
    g = Graph(r.stdout if r.returncode == 0 else "")
    _GRAPHS[repo] = (snap.fingerprint, g)
    return g


def _trees(snap):
    """{branch: tree sha} for every local head in ONE spawn — gates verdicts are tree-keyed."""
    repo = ctx.repo_cwd()
    hit = _TREES.get(repo)
    fp = snap.fingerprint
    if hit and hit[0] == fp:
        return hit[1]
    out = ctx.run(["git", "for-each-ref", "--format=%(refname:short) %(tree)", "refs/heads"]).stdout
    trees = dict(ln.rsplit(" ", 1) for ln in out.splitlines() if " " in ln)
    _TREES[repo] = (fp, trees)
    return trees


def _template(snap):
    trunk = snap.remote(snap.main()) or snap.local(snap.main())
    key = (ctx.repo_cwd(), trunk)
    if key not in _TEMPLATE:
        t = ctx.run(["git", "show", f"{trunk}:.github/pull_request_template.md"])
        _TEMPLATE[key] = t.stdout.strip() if t.returncode == 0 else ""
    return _TEMPLATE[key]


def _gates(snap, branch, tree):
    """green | red | stale | running | none, plus the red gates' names. Tree-keyed like the
    push door: green only for THIS tree; a finished detached run for this tree is the red memo;
    a green for an older tree is stale (the edit since then hasn't been gated)."""
    green = snap.branch_key(branch, "gates-green-tree")
    if green and green == tree:
        return "green", []
    job = push._GATE_JOBS.get(push._jkey(branch)) or push._adopt_job(branch)
    if job and job.get("tree") == tree:
        if push._job_running(job):
            return "running", []
        res = next((e for e in push._journal_events(job["path"]) if e.get("event") == "result"), None)
        if res:
            if res.get("ok"):
                return "green", []
            return "red", [g.get("name", "") for g in res.get("gates") or [] if not g.get("ok")]
    return ("stale" if green else "none"), []


def _hours_since(iso):
    try:
        t = datetime.fromisoformat(iso.replace("Z", "+00:00"))
    except (ValueError, AttributeError):
        return None
    return round((datetime.now(timezone.utc) - t).total_seconds() / 3600, 1)


def _waiting_on(node, by_branch):
    """What an approved PR still waits on, each with the next human action as a link."""
    pr = node["pr"]
    out = []
    parent = by_branch.get(node["parent"])
    if parent and parent["status"] != "landed":
        ppr = parent.get("pr")
        out.append({"kind": "parent", "label": f"parent #{ppr['number']} unmerged" if ppr else f"parent {parent['leaf']} has no PR",
                    "url": ppr["url"] if ppr else ""})
    if pr.get("draft"):
        out.append({"kind": "draft", "label": "still a draft", "url": pr.get("url", "")})
    ms = (pr.get("mergeState") or "").upper()
    if pr.get("mergeable") == "CONFLICTING" or ms == "DIRTY":
        out.append({"kind": "conflicts", "label": "conflicts with its base", "url": pr.get("url", "")})
    elif ms == "UNSTABLE":
        out.append({"kind": "ci", "label": "CI failing", "url": (pr.get("url") or "") + "/checks"})
    elif ms == "BEHIND":
        out.append({"kind": "behind", "label": "behind its base", "url": pr.get("url", "")})
    elif ms == "BLOCKED" and not out:
        out.append({"kind": "checks", "label": "required checks pending", "url": (pr.get("url") or "") + "/checks"})
    if not out:
        out.append({"kind": "merge", "label": "nothing — merge it", "url": pr.get("url", "")})
    return out


def _slug(snap):
    m = re.search(r"[:/]([^/:]+/[^/]+?)(?:\.git)?$", snap.get("remote.origin.url"))
    return m.group(1) if m else ""


def _compare_url(slug, branch, base, title, body):
    """github.com compare-and-create form, stacked base + landing title + body prefilled. Opens a
    form for Phil's hand; nothing here creates the PR. Defers to push.compare_url when the
    OUTLINE branch's shared helper is present."""
    shared = getattr(push, "compare_url", None)
    if shared:
        try:
            return shared(branch, base=base)
        except Exception:
            pass
    if not slug:
        return ""
    return (f"https://github.com/{slug}/compare/{quote(base, safe='')}...{quote(branch, safe='')}?expand=1"
            + (f"&title={quote(title, safe='')}" if title else "")
            + (f"&body={quote(body, safe='')}" if body else ""))


def _pr_body(snap, node, nodes, ticket):
    """Furniture in stack-pr-body's shape (purpose, Stacked on, merge order with #N for opened
    steps), built from facts in hand — no gh, no spawn. A saved stack-pr-body wins verbatim."""
    saved = snap.branch_key(node["branch"], "pr-body")
    if saved:
        return saved
    lines = [node["description"] or node["title"]]
    if len(node["subjects"]) > 1:
        lines += [""] + [f"- {s}" for s in reversed(node["subjects"][:4])]
    so = node["stackedOn"]
    if so:
        lines += ["", f"Stacked on: #{so['pr']}" if so.get("pr") else f"Stacked on: `{so['branch']}` (its PR opens first)"]
    if len(nodes) > 1:
        lines += ["", "Part of a stack, in merge order:"]
        for i, n in enumerate(nodes, 1):
            ref = "[this branch]" if n is node else f"#{n['pr']['number']}" if n.get("pr") else (n["description"] or n["leaf"])
            lines.append(f"  {i}. {ref}")
    template = _template(snap) if len(nodes) > 1 else ""
    return "\n".join(lines) + (f"\n\n{template}\n" if template else "\n")


def _forest(snap, project, prs, slug, graph):
    rank = _rank(project, snap)
    order = [b for b in rank.get("order", []) if snap.exists(b)]
    if not order:
        return None
    trees = _trees(snap)
    ticket = snap.get(f"stack-project.{project}.ticket")
    nodes = []
    for pos, b in enumerate(order, 1):
        parent = snap.branch_key(b, "parent") or snap.main()
        pr = prs.get(b)
        if pr and pr.get("state") == "CLOSED":
            pr = None
        tip = snap.local(b)
        node = {"branch": b, "leaf": b.split("/")[-1], "position": pos, "rank": rank["rank"].get(b, 0),
                "parent": parent, "tip": tip, "description": snap.description(b),
                "requires": snap.branch_key_all(b, "requires"), "after": snap.branch_key_all(b, "after"),
                "pr": pr, "holdUntil": snap.branch_key(b, "hold-until")}
        if pr and pr.get("state") == "MERGED":
            node.update(status="landed", subjects=[], commits=0, pushed="synced", ahead=0, gates="green", redGates=[],
                        title=pr.get("title") or node["description"] or b, titleSource="pr")
            nodes.append(node)
            continue
        base_tip = "" if parent in TRUNKS or not snap.exists(parent) else snap.local(parent)
        subjects = graph.own(tip, base_tip) if tip else []
        remote = snap.remote(b)
        ahead = len(graph.own(tip, remote)) if remote and tip else 0
        gates, red = _gates(snap, b, trees.get(b, ""))
        saved_title = snap.branch_key(b, "pr-title")
        node.update(subjects=subjects[:6], commits=len(subjects), ahead=ahead,
                    pushed="synced" if remote and not ahead else "ahead" if remote else "local",
                    gates=gates, redGates=red,
                    title=saved_title or (subjects[-1] if subjects else node["description"] or b),
                    titleSource="saved" if saved_title else "commit")
        if pr and pr.get("state") == "OPEN":
            node["status"] = "approved" if pr.get("review") == "APPROVED" else "review"
        elif not subjects:
            node["status"] = "empty"
        else:
            node["status"] = "ready" if gates == "green" else "work"
        nodes.append(node)

    by_branch = {n["branch"]: n for n in nodes}
    live = [n for n in nodes if n["status"] not in ("landed", "empty")]
    if not live:
        return None
    for n in nodes:
        p = by_branch.get(n["parent"])
        n["stackedOn"] = None
        n["base"] = "main"
        if p and p["status"] != "landed":
            n["base"] = p["branch"]
            n["stackedOn"] = {"branch": p["branch"], "pr": (p.get("pr") or {}).get("number")}
        if n["status"] == "approved":
            n["waitingOn"] = _waiting_on(n, by_branch)
            n["waitingH"] = _hours_since(n["pr"].get("approvedAt") or n["pr"].get("createdAt") or "")
        if n["status"] in ("ready", "work"):
            n["compareUrl"] = _compare_url(slug, n["branch"], n["base"], n["title"], _pr_body(snap, n, nodes, ticket))
        del n["tip"]
    unopened = [n for n in live if n["status"] in ("ready", "work")]
    if len(unopened) >= 2:
        summary = "ready-to-launch" if all(n["gates"] == "green" for n in unopened) else "launch-blocked"
    elif any(n["status"] == "work" for n in live):
        summary = "blocked"
    elif any(n["status"] == "ready" for n in live):
        summary = "ready"
    elif any(n["status"] == "approved" for n in live):
        summary = "approved-chain"
    else:
        summary = "in-review"
    focus = snap.get(f"stack-project.{project}.focus")
    return {"project": project, "ticket": ticket, "summary": summary, "size": len(nodes),
            "unopened": len(unopened), "focus": int(focus) if focus.isdigit() else None, "nodes": nodes}


def _projects(snap):
    names, seen = [], set()
    for k in snap.cfg:
        if k.startswith("stack-project.") and k.endswith(".branch"):
            p = k[len("stack-project."):-len(".branch")]
            if p not in seen:
                seen.add(p)
                names.append(p)
    return [p for p in names
            if snap.get(f"stack-project.{p}.archived") != "true" and snap.get(f"stack-project.{p}.shelved") != "true"]


def _repo_forests(name, only):
    snap = repostate.snapshot()
    prs, source = _pr_map()
    slug = _slug(snap)
    _rank_mod()
    _trees(snap)
    trunk = "origin/main" if snap.remote(snap.main()) else snap.main()
    graph = _graph(snap, trunk)
    forests = []
    for p in [only] if only else _projects(snap):
        f = _forest(snap, p, prs, slug, graph)
        if f:
            f["repo"] = name
            forests.append(f)
    return forests, source


def get(req, u):
    t0 = time.perf_counter()
    q = parse_qs(u.query)
    only = q.get("project", [""])[0]
    want_repo = q.get("repo", [""])[0]
    repos = ctx.REPOS or {os.path.basename(ctx.CWD): ctx.CWD}
    forests, source = [], "gh"
    for name, path in repos.items():
        if want_repo and name != want_repo:
            continue
        ctx.set_repo(path)
        try:
            fs, source = _repo_forests(name, only)
            forests += fs
        except Exception as e:
            ctx.log(f"outbox: {name} failed: {e!r}")
        finally:
            ctx.clear_repo()
    req._send(200, json.dumps({
        "forests": forests, "window": WINDOW, "prSource": source,
        "generatedAt": datetime.now(timezone.utc).isoformat(),
        "ms": round((time.perf_counter() - t0) * 1000),
    }))


def _members(snap, d):
    if d.get("branches"):
        return [b for b in d["branches"] if snap.exists(b)]
    if d.get("branch"):
        return [d["branch"]] if snap.exists(d["branch"]) else []
    project = d.get("project", "")
    return [b for b in snap.get_all(f"stack-project.{project}.branch") if snap.exists(b)] if project else []


def hold(req, raw):
    """POST {branch|branches|project, until} — hold for morning: stamp (or clear) the hold on one
    branch, a list, or every branch of a forest. A stamp only moves the row; nothing is pushed when it comes due."""
    d = json.loads(raw or "{}")
    snap = repostate.snapshot()
    targets = _members(snap, d)
    if not targets:
        return req._send(400, json.dumps({"ok": False, "err": "no such branch or project"}))
    until = (d.get("until") or "").strip()
    if until:
        try:
            datetime.fromisoformat(until.replace("Z", "+00:00"))
        except ValueError:
            return req._send(400, json.dumps({"ok": False, "err": "until must be an ISO timestamp"}))
    for b in targets:
        if until:
            stackcfg.set_key(b, "hold-until", until)
        else:
            stackcfg.unset_key(b, "hold-until")
    req._send(200, json.dumps({"ok": True, "branches": targets, "until": until}))


def title(req, raw):
    """POST {branch, title} — the PR title that will land (branch.<b>.stack-pr-title)."""
    d = json.loads(raw or "{}")
    branch = d.get("branch", "")
    if not branch or not repostate.snapshot().exists(branch):
        return req._send(400, json.dumps({"ok": False, "err": "no such branch"}))
    text = " ".join((d.get("title") or "").split())
    if text:
        stackcfg.set_key(branch, "pr-title", text)
    else:
        stackcfg.unset_key(branch, "pr-title")
    req._send(200, json.dumps({"ok": True, "branch": branch, "title": text}))
