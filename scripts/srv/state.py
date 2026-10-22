# srv/state.py — the v2 client's world as normalized entities: one snapshot, then entity patches.
#
#   GET /state[?archived=1]
#     {epoch, versions: {git, remote}, entities: {repo, project, branch, pr, landed: {id: obj}}, ms}
#   GET /v2/events?epoch=E&git=N&remote=M[&archived=1]          (SSE)
#     event: hello   {epoch, versions}                         first, always
#     event: patch   {domain, version, upserts: {type: {id: obj}}, deletes: {type: [id]}}
#     event: resync  {epoch, versions}                         refetch /state, then reconnect
#
# A branch carries its merge-order position in its forest (`order`, stack-merge-rank's) and its
# hold-for-morning stamp; a PR carries what an approved one waits on (mergeState, mergeable) — the
# outbox's facts, so the Forests page derives ship state and the ready filter from the store alone.
#
# Ids: repo "<repo>", project/branch/pr "<repo>:<name>" (a pr is keyed by its head branch),
# landed "<repo>:<project>#<pr>". Archived projects are always listed (state "archive"); their
# branches and PRs only with archived=1 — on a stream without it, archiving a project turns into
# deletes of its branches and PRs, restoring one into their upserts.
#
# Domains own entity types and move on their own clocks:
#   git     repo, project, branch  refs + config + gate jobs; rebuilt when the stat-gated repostate
#                                  fingerprint or a gate job moves, so a quiet repo costs no spawn
#   remote  pr, landed             sync's PR state cache (+ open-PR detail / the sandbox fixture) and
#                                  the merge ledger; in-memory reads, rebuilt every tick
# A version is per domain, monotonic within an epoch (one server process), and a patch's version is
# the previous one + 1 — so a client that sees a gap, or connects with a version older than the
# ring holds or from another epoch, gets `resync`. A client connecting without versions is assumed
# to hold the current ones (fetch /state first, then connect with its versions).
#
# Never gh on the request path: PR facts are whatever the caches hold right now.
import collections
import hashlib
import json
import os
import tempfile
import threading
import time
from urllib.parse import parse_qs

from . import ctx, outbox, push, repostate, sync, watch

EPOCH = f"{os.getpid():x}{int(time.time()):x}"
DOMAINS = ("git", "remote")
RING = 128
TICK = 0.5
_TRUNKS = ("main", "master")


class _Domain:
    def __init__(self):
        self.version = 0
        self.fp = None
        self.ents = {}
        self.ring = collections.deque(maxlen=RING)


_D = {d: _Domain() for d in DOMAINS}
_REFRESH = threading.Lock()
_COND = threading.Condition()
_WAKE = threading.Event()
_SUBS = [0]
_GRAPHS = {}   # repo path -> (tips key, Graph)
_TREES = {}    # repo path -> (refs key, {branch: tree})
_SIDECARS = {"at": 0.0}


def _refs_key(snap):
    return snap.once("v2-refs", lambda: hashlib.sha1(repr(sorted(snap.sha.items())).encode()).hexdigest())


def _membership(snap):
    """{branch: project} over local branches: an explicit tag, else the registry, else inherited
    from a member parent (a child cut under a forest without its own tag)."""
    registry = {}
    for k, vs in snap.cfg.items():
        if k.startswith("stack-project.") and k.endswith(".branch"):
            for b in vs:
                registry.setdefault(b.strip(), k[len("stack-project."):-len(".branch")])
    tags = snap.branch_keys("project")
    local = [r[11:] for r in snap.sha if r.startswith("refs/heads/")]
    out = {b: tags.get(b) or registry.get(b) for b in local}

    def inherit(b, depth=0):
        if out.get(b) or depth > 64:
            return out.get(b)
        parent = snap.branch_key(b, "parent")
        return inherit(parent, depth + 1) if parent in out else None
    for b in local:
        out[b] = inherit(b)
    return {b: p for b, p in out.items() if p}, set(registry.values()) | set(tags.values())


def _graph(snap, trunk, tips):
    repo = ctx.repo_cwd()
    key = hashlib.sha1(repr((trunk, snap.sha.get(f"refs/remotes/{trunk}", snap.local(trunk)), sorted(tips))).encode()).hexdigest()
    hit = _GRAPHS.get(repo)
    if hit and hit[0] == key:
        return hit[1]
    import subprocess
    r = subprocess.run(["git", "log", "--format=%H%x1f%P%x1f%s", "--stdin", "--not", trunk],
                       cwd=repo, input="\n".join(tips) + "\n", capture_output=True, text=True)
    g = outbox.Graph(r.stdout if r.returncode == 0 else "")
    _GRAPHS[repo] = (key, g)
    return g


def _trees(snap):
    repo = ctx.repo_cwd()
    key = _refs_key(snap)
    hit = _TREES.get(repo)
    if hit and hit[0] == key:
        return hit[1]
    out = ctx.run(["git", "for-each-ref", "--format=%(refname:short) %(tree)", "refs/heads"]).stdout
    trees = dict(ln.rsplit(" ", 1) for ln in out.splitlines() if " " in ln)
    _TREES[repo] = (key, trees)
    return trees


def _adopt_sidecars():
    # detached gate runs a previous server process spawned are only known by their sidecar files;
    # one scan of the temp dir every 10s, not a stat per branch per tick
    now = time.monotonic()
    if now - _SIDECARS["at"] < 10:
        return
    _SIDECARS["at"] = now
    pre = f"stack-gates-{push._repo_id()}-"
    try:
        names = [e.name for e in os.scandir(tempfile.gettempdir()) if e.name.startswith(pre) and e.name.endswith(".job.json")]
    except OSError:
        return
    from urllib.parse import unquote
    for n in names:
        b = unquote(n[len(pre):-len(".job.json")])
        if push._jkey(b) not in push._GATE_JOBS:
            push._adopt_job(b)


def _jobs():
    rid = push._repo_id()
    return {k[1]: j for k, j in list(push._GATE_JOBS.items()) if k[0] == rid}


def _jobs_sig(jobs):
    def mt(p):
        try:
            return os.path.getmtime(p)
        except OSError:
            return 0
    return repr(sorted((b, j.get("tree"), push._job_running(j), mt(j.get("path", ""))) for b, j in jobs.items()))


def _gates(snap, b, tree, jobs):
    green = snap.branch_key(b, "gates-green-tree")
    if green and green == tree:
        return "green", []
    job = jobs.get(b)
    if job and job.get("tree") == tree:
        if push._job_running(job):
            return "running", []
        res = next((e for e in push._journal_events(job["path"]) if e.get("event") == "result"), None)
        if res:
            if res.get("ok"):
                return "green", []
            return "red", [g.get("name", "") for g in res.get("gates") or [] if not g.get("ok")]
    return ("stale" if green else "none"), []


def _git_fp(name):
    snap = repostate.snapshot()
    _adopt_sidecars()
    jobs = _jobs()
    return snap, jobs, (snap.fingerprint, _jobs_sig(jobs))


def _git_entities(name, snap, jobs):
    main = snap.main()
    trunk = f"origin/{main}" if snap.remote(main) else main
    member, names = _membership(snap)
    tips = set()
    for b in member:
        p = snap.parent(b)
        tips.update(t for t in (snap.local(b), snap.remote(b), snap.local(p)) if t)
    graph = _graph(snap, trunk, tips)
    trees = _trees(snap)
    ents = {"repo": {name: {"id": name, "name": name, "main": main, "trunk": snap.sha.get(f"refs/remotes/{trunk}", snap.local(main))}},
            "project": {}, "branch": {}}
    sizes = collections.Counter(member.values())
    order = {}
    for p in set(member.values()):
        for i, b in enumerate(outbox._rank(p, snap).get("order", []), 1):
            order[b] = i
    for b, p in member.items():
        parent = snap.parent(b)
        tip = snap.local(b)
        base_tip = "" if parent in _TRUNKS or parent not in member and not snap.exists(parent) else snap.local(parent)
        own = graph.own(tip, base_tip) if tip else []
        remote = snap.remote(b)
        ahead = len(graph.own(tip, remote)) if remote and tip else 0
        tree = trees.get(b, "")
        gates, red = _gates(snap, b, tree, jobs)
        ents["branch"][f"{name}:{b}"] = {
            "id": f"{name}:{b}", "repo": name, "name": b, "project": f"{name}:{p}",
            "parent": parent, "parentId": f"{name}:{parent}" if parent in member else None,
            "description": snap.description(b), "subject": own[0] if own else "",
            "commits": len(own), "tip": tip, "tree": tree,
            "pushed": "synced" if remote and not ahead else "ahead" if remote else "local", "ahead": ahead,
            "gates": gates, "redGates": red,
            "order": order.get(b, 999), "holdUntil": snap.branch_key(b, "hold-until") or None,
        }
    for p in names:
        members = [b for b, q in member.items() if q == p]
        roots = [b for b in members if snap.parent(b) not in member]
        focus = snap.get(f"stack-project.{p}.focus")
        archived = snap.get(f"stack-project.{p}.archived") == "true"
        rank = int(focus) if focus.isdigit() and int(focus) > 0 else None
        listed = snap.get_all(f"stack-project.{p}.branch")
        roots.sort(key=lambda b: (listed.index(b) if b in listed else len(listed), b))
        summary = next((snap.description(b) for b in roots if snap.description(b)), "")
        ents["project"][f"{name}:{p}"] = {
            "id": f"{name}:{p}", "repo": name, "name": p,
            "state": "archive" if archived else "focus" if rank else "workbench", "rank": rank,
            "ticket": snap.get(f"stack-project.{p}.ticket") or None, "summary": summary[:160],
            "size": sizes.get(p, 0),
        }
    return ents


def _remote_entities(name, git_ents):
    branches = {b["name"]: b for b in git_ents["branch"].values() if b["repo"] == name}
    prs, _src = outbox._pr_map()
    ents = {"pr": {}, "landed": {}}
    for head, pr in prs.items():
        b = branches.get(head)
        if not b or not pr or pr.get("state") == "CLOSED":
            continue
        ents["pr"][b["id"]] = {
            "id": b["id"], "repo": name, "branch": head, "project": b["project"],
            "number": pr.get("number"), "url": pr.get("url") or "", "state": pr.get("state") or "",
            "review": pr.get("review") or None, "draft": bool(pr.get("draft")),
            "base": pr.get("baseRef") or None, "approvals": pr.get("approvals"),
            "mergeState": pr.get("mergeState") or None, "mergeable": pr.get("mergeable") or None,
            "approvedAt": pr.get("approvedAt") or None, "title": pr.get("title") or None,
        }
    try:
        with open(os.path.join(watch.common_dir(), "stack-project-merges.json")) as f:
            ledger = json.load(f).get("merges") or {}
    except (OSError, ValueError):
        ledger = {}
    for proj, steps in ledger.items():
        for s in steps if isinstance(steps, list) else [steps]:
            if not isinstance(s, dict) or not s.get("pr"):
                continue
            lid = f"{name}:{proj}#{s['pr']}"
            ents["landed"][lid] = {"id": lid, "repo": name, "project": f"{name}:{proj}", "pr": s["pr"],
                                   "title": s.get("title") or "", "branch": s.get("branch") or "", "at": s.get("at") or ""}
    return ents


def _diff(old, new):
    ups, dels = {}, {}
    for t in set(old) | set(new):
        o, n = old.get(t, {}), new.get(t, {})
        u = {i: v for i, v in n.items() if o.get(i) != v}
        d = [i for i in o if i not in n]
        if u:
            ups[t] = u
        if d:
            dels[t] = d
    return ups, dels


def _commit(domain, new, fp):
    """Swap in a domain's new entities; a non-empty diff becomes the next version's patch."""
    D = _D[domain]
    ups, dels = _diff(D.ents, new)
    D.fp = fp
    if not ups and not dels:
        D.ents = new
        return
    moved = {"show": [], "hide": []}
    for pid, p in ups.get("project", {}).items():
        was = D.ents.get("project", {}).get(pid)
        if p["state"] == "archive" and (not was or was["state"] != "archive"):
            moved["hide"].append(pid)
        elif was and was["state"] == "archive" and p["state"] != "archive":
            moved["show"].append(pid)
    for pid in dels.get("project", []):
        moved["hide"].append(pid)
    D.ents = new
    with _COND:
        D.version += 1
        D.ring.append({"domain": domain, "version": D.version, "upserts": ups, "deletes": dels, "moved": moved})
        _COND.notify_all()


def _each_repo(fn):
    prev = getattr(ctx._local, "repo", None)
    out = {}
    try:
        for name, path in (ctx.REPOS or {os.path.basename(ctx.CWD): ctx.CWD}).items():
            ctx.set_repo(path)
            try:
                out[name] = fn(name)
            except Exception as e:
                ctx.log(f"state: {name} failed: {e!r}")
    finally:
        ctx.set_repo(prev) if prev else ctx.clear_repo()
    return out


def _merge(parts, types):
    out = {t: {} for t in types}
    for ents in parts:
        for t in types:
            out[t].update(ents.get(t, {}))
    return out


def refresh():
    """Bring every domain up to date (single-flight); each change appends one patch."""
    with _REFRESH:
        probes = _each_repo(_git_fp)
        fp = tuple((n, probes[n][2]) for n in sorted(probes))
        if fp != _D["git"].fp:
            built = _each_repo(lambda n: _git_entities(n, probes[n][0], probes[n][1]) if n in probes else {})
            _commit("git", _merge(built.values(), ("repo", "project", "branch")), fp)
        git = _D["git"].ents
        remote = _each_repo(lambda n: _remote_entities(n, git))
        _commit("remote", _merge(remote.values(), ("pr", "landed")), None)


def _hidden():
    return {pid for pid, p in _D["git"].ents.get("project", {}).items() if p["state"] == "archive"}


def _visible(t, obj, hidden):
    return t not in ("branch", "pr") or obj.get("project") not in hidden


def snapshot(archived):
    hidden = set() if archived else _hidden()
    ents = {}
    for D in _D.values():
        for t, objs in D.ents.items():
            ents[t] = {i: o for i, o in objs.items() if _visible(t, o, hidden)}
    return {"epoch": EPOCH, "versions": {d: _D[d].version for d in DOMAINS}, "entities": ents}


def _project_patch(patch, archived):
    """A ring patch as one client sees it: without archived=1, hidden projects' branches/PRs
    become deletes, and a project leaving the archive brings its branches/PRs back."""
    out = {"domain": patch["domain"], "version": patch["version"],
           "upserts": {t: dict(o) for t, o in patch["upserts"].items()},
           "deletes": {t: list(i) for t, i in patch["deletes"].items()}}
    if archived:
        return out
    hidden = _hidden()
    for t in ("branch", "pr"):
        for i, o in list(out["upserts"].get(t, {}).items()):
            if o.get("project") in hidden:
                del out["upserts"][t][i]
                out["deletes"].setdefault(t, []).append(i)
    moved = patch.get("moved") or {}
    if moved.get("show") or moved.get("hide"):
        show, hide = set(moved.get("show", [])) - hidden, set(moved.get("hide", []))
        for D in _D.values():
            for t in ("branch", "pr"):
                for i, o in D.ents.get(t, {}).items():
                    if o.get("project") in show:
                        out["upserts"].setdefault(t, {})[i] = o
                    elif o.get("project") in hide:
                        out["deletes"].setdefault(t, []).append(i)
    out["upserts"] = {t: o for t, o in out["upserts"].items() if o}
    out["deletes"] = {t: sorted(set(i)) for t, i in out["deletes"].items() if i}
    return out


def _behind(domain, since):
    """Ring patches after `since`, or None when the ring no longer reaches back that far."""
    D = _D[domain]
    if since >= D.version:
        return []
    got = [p for p in D.ring if p["version"] > since]
    return got if got and got[0]["version"] == since + 1 else None


def poke():
    """A POST just wrote to a repo: refresh now rather than on the next tick."""
    _WAKE.set()


def _refresher():
    while True:
        _WAKE.wait(TICK)
        _WAKE.clear()
        if _SUBS[0] <= 0:
            continue
        try:
            sync.pulse_freshen()   # the remote world converges while a v2 tab is open, as v1's pulse does
            refresh()
        except Exception as e:
            ctx.log(f"state: refresh failed: {e!r}")


threading.Thread(target=_refresher, daemon=True).start()


# ── handlers ─────────────────────────────────────────────────────────────

def get(req, u):
    t0 = time.perf_counter()
    archived = parse_qs(u.query).get("archived", [""])[0] == "1"
    refresh()
    body = snapshot(archived)
    body["ms"] = round((time.perf_counter() - t0) * 1000, 1)
    req._send(200, json.dumps(body, separators=(",", ":")))


def _sse(req, event, data):
    req.wfile.write(f"event: {event}\ndata: {json.dumps(data, separators=(',', ':'))}\n\n".encode())
    req.wfile.flush()


def events(req, u, keepalive=lambda: None):
    q = parse_qs(u.query)
    archived = q.get("archived", [""])[0] == "1"
    req.send_response(200)
    req.send_header("Content-Type", "text/event-stream")
    req.send_header("Cache-Control", "no-store")
    req.send_header("Connection", "keep-alive")
    req.end_headers()
    with _COND:
        _SUBS[0] += 1
    _WAKE.set()
    try:
        cursor = {}
        for d in DOMAINS:
            raw = q.get(d, [""])[0]
            cursor[d] = int(raw) if raw.isdigit() else _D[d].version
        current = {d: _D[d].version for d in DOMAINS}
        _sse(req, "hello", {"epoch": EPOCH, "versions": current})
        stale = q.get("epoch", [EPOCH])[0] != EPOCH
        last_ping = time.monotonic()
        while True:
            for d in DOMAINS:
                behind = None if stale else _behind(d, cursor[d])
                if behind is None:
                    _sse(req, "resync", {"epoch": EPOCH, "versions": {k: _D[k].version for k in DOMAINS}})
                    return
                for p in behind:
                    _sse(req, "patch", _project_patch(p, archived))
                    cursor[d] = p["version"]
            with _COND:
                if all(cursor[d] == _D[d].version for d in DOMAINS):
                    _COND.wait(15)
            keepalive()
            if time.monotonic() - last_ping > 15:
                req.wfile.write(b": ping\n\n")
                req.wfile.flush()
                last_ping = time.monotonic()
    except OSError:
        pass
    finally:
        with _COND:
            _SUBS[0] -= 1
