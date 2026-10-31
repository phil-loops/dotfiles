# srv/state.py — the v2 client's world as normalized entities: one snapshot, then entity patches.
#
#   GET /state[?archived=1]
#     {epoch, versions: {git, remote, review}, entities: {repo, project, branch, pr, landed, conv,
#      thread, draft: {id: obj}}, ms}
#   GET /v2/events?epoch=E&git=N&remote=M&review=R[&archived=1]   (SSE)
#     event: hello   {epoch, versions}                         first, always
#     event: patch   {domain, version, upserts: {type: {id: obj}}, deletes: {type: [id]}}
#     event: resync  {epoch, versions}                         refetch /state, then reconnect
#
# A branch carries its merge-order position in its forest (`order`, stack-merge-rank's), its
# hold-for-morning stamp, and what sync would fix — v1's /sync and /forest-health facts, from the
# refs alone: `behind` origin/main, `drifted` off its parent's tip, a footgun `upstream` and a
# `diverged` pushed copy. Dirt and the prep route aren't here: one needs a `status` per worktree
# and moves without any ref moving, the other walks commit bodies — the branch page reads them
# per branch (GET /sync, /prep-route, both memoised there). A PR carries what an approved one
# waits on (mergeState, mergeable) — the outbox's facts, so the Forests page derives ship state
# and the ready filter from the store alone.
#
# Ids: repo "<repo>", project/branch/pr "<repo>:<name>" (a pr is keyed by its head branch),
# landed "<repo>:<project>#<pr>". Archived projects are always listed (state "archive"); their
# branches and PRs only with archived=1 — on a stream without it, archiving a project turns into
# deletes of its branches and PRs, restoring one into their upserts.
#
# Domains own entity types and move on their own clocks:
#   git     repo, project, branch  refs + config + gate jobs; rebuilt when the stat-gated repostate
#                                  fingerprint or a gate job moves, so a quiet repo costs no spawn
#   remote  pr, landed, warm       sync's PR state cache (+ open-PR detail / the sandbox fixture) and
#                                  the merge ledger; in-memory reads, rebuilt every tick
#   review  conv, thread, draft,   open PRs' review threads (packet's background GraphQL read, or
#                                  the fake GitHub) mapped onto the local tips, the second reader's
#                                  notes, and the ledger of what Phil writes (srv/reviewdesk.py);
#                                  rebuilt every tick from memory + stats; and `viewed`, the change
#           viewed                 blocks Phil has viewed per branch (srv/viewed.py)
#   todo    todo                   the viewer's own feature tracker (srv/todo.py, ~/.dotfiles/canopy/todo),
#                                  global rather than per repo; rebuilt when a file's stat moves
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
import threading
import time
from urllib.parse import parse_qs

from . import ctx, outbox, push, repostate, reviewdesk, sync, todo, viewed, watch

EPOCH = f"{os.getpid():x}{int(time.time()):x}"
DOMAINS = ("git", "remote", "review", "todo")
RING = 128
REVIEW_TYPES = ("conv", "thread", "draft", "viewed")
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
_BEHIND = {}   # repo path -> (refs key, {branch: commits on trunk it lacks})
_ANC = {}      # (ancestor sha, tip sha) -> bool, for parents already on trunk (outside the graph)


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


def _behind_trunk(snap, trunk, branches):
    """{branch: commits on trunk it lacks} — v1's /sync `behind`, for every member in ONE spawn
    (for-each-ref's ahead-behind), recomputed only when a ref moves."""
    repo = ctx.repo_cwd()
    key = (_refs_key(snap), trunk)
    hit = _BEHIND.get(repo)
    if hit and hit[0] == key:
        return hit[1]
    out = {}
    if branches:
        r = ctx.run(["git", "for-each-ref", f"--format=%(refname) %(ahead-behind:{trunk})",
                     *[f"refs/heads/{b}" for b in sorted(branches)]])
        for ln in r.stdout.splitlines():
            ref, _, ab = ln.rpartition(" ")
            ref = ref.rpartition(" ")[0]
            if ref.startswith("refs/heads/") and ab.isdigit():
                out[ref[11:]] = int(ab)
    _BEHIND[repo] = (key, out)
    return out


def _is_ancestor(graph, a, b):
    """Is commit a an ancestor of b? Answered from the graph when a is off trunk; otherwise one
    cached `merge-base --is-ancestor` per sha pair."""
    if not a or not b:
        return False
    if a in graph.commits:
        return a == b or a in graph.ancestors(b)
    key = (a, b)
    if key not in _ANC:
        if len(_ANC) > 4000:
            _ANC.clear()
        _ANC[key] = ctx.run(["git", "merge-base", "--is-ancestor", a, b]).returncode == 0
    return _ANC[key]


def _upstream(snap, graph, b, main, tip, remote):
    """v1's _upstream_state from the snapshot: (upstream, tracks the trunk, diverged from the
    pushed copy). An upstream's own ahead/behind rides in for-each-ref's track; a --no-track
    branch is measured against origin/<branch> through the graph."""
    up, track = snap.track(b)
    if up:
        rem = snap.get(f"branch.{b}.remote")
        bad = (up[len(rem) + 1:] if rem and up.startswith(rem + "/") else up) == main
        return up, bad, not bad and "ahead" in track and "behind" in track
    if not remote or not tip or remote == tip or remote not in graph.commits or tip not in graph.commits:
        return "", False, False
    return "", False, remote not in graph.ancestors(tip) and tip not in graph.ancestors(remote)


def _jobs_sig(jobs):
    def mt(p):
        try:
            return os.path.getmtime(p)
        except OSError:
            return 0
    return repr(sorted((b, r.meta.get("tree"), r.alive(), mt(push.journal(r))) for b, r in jobs.items()))


def _gates(snap, b, tree, jobs):
    green = snap.branch_key(b, "gates-green-tree")
    if green and green == tree:
        return "green", []
    run = jobs.get(b)
    if run and run.meta.get("tree") == tree:
        if run.alive():
            return "running", []
        res = push.gate_result(run)
        if res:
            if res.get("ok"):
                return "green", []
            return "red", [g.get("name", "") for g in res.get("gates") or [] if not g.get("ok")]
    return ("stale" if green else "none"), []


def _git_fp(name):
    snap = repostate.snapshot()
    jobs = push.gate_runs()
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
    behind = _behind_trunk(snap, trunk, member)
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
        up, up_bad, diverged = _upstream(snap, graph, b, main, tip, remote)
        rooted = parent in _TRUNKS or parent == trunk or not snap.exists(parent)
        ents["branch"][f"{name}:{b}"] = {
            "id": f"{name}:{b}", "repo": name, "name": b, "project": f"{name}:{p}",
            "parent": parent, "parentId": f"{name}:{parent}" if parent in member else None,
            "description": snap.description(b), "subject": own[0] if own else "",
            "commits": len(own), "outline": own[::-1], "tip": tip, "tree": tree,
            "pushed": "synced" if remote and not ahead else "ahead" if remote else "local", "ahead": ahead,
            "gates": gates, "redGates": red,
            "order": order.get(b, 999), "holdUntil": snap.branch_key(b, "hold-until") or None,
            "behind": behind.get(b, 0),
            "drifted": bool(tip) and not rooted and not _is_ancestor(graph, snap.local(parent), tip),
            "upstream": up, "upstreamBad": up_bad, "diverged": diverged,
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
    prs, src = outbox._pr_map()
    # until sync's first PR read lands, an absent PR means "not known yet", not "none"
    ents = {"pr": {}, "landed": {}, "warm": {name: {"id": name, "prs": src != "warming"}}}
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
        _commit("remote", _merge(remote.values(), ("pr", "landed", "warm")), None)
        review = _each_repo(lambda n: {**reviewdesk.entities(n), **viewed.entities(n)})
        _commit("review", _merge(review.values(), REVIEW_TYPES), None)
        tfp = todo.fingerprint()
        if tfp != _D["todo"].fp:
            _commit("todo", todo.entities(), tfp)
        _each_repo(lambda n: reviewdesk.release_due())


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
            try:   # a reply waiting on a push goes out after it even with no v2 tab open (a stat when the queue is empty)
                _each_repo(lambda n: reviewdesk.release_due())
            except Exception as e:
                ctx.log(f"state: reply release failed: {e!r}")
            continue
        try:
            sync.pulse_freshen()   # the remote world converges while a v2 tab is open, as v1's pulse does
            refresh()
        except Exception as e:
            ctx.log(f"state: refresh failed: {e!r}")


threading.Thread(target=_refresher, daemon=True).start()


# The server's asset_sig (it moves when keys.toml is saved): sent in hello and again when it
# moves, so canopy reloads its keymap.
ASSET = lambda: ""   # noqa: E731


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
        asset = ASSET()
        _sse(req, "hello", {"epoch": EPOCH, "versions": current, "asset": asset})
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
            if time.monotonic() - last_ping > 15 and ASSET() != asset:
                asset = ASSET()
                _sse(req, "asset", {"asset": asset})
            if time.monotonic() - last_ping > 15:
                req.wfile.write(b": ping\n\n")
                req.wfile.flush()
                last_ping = time.monotonic()
    except OSError:
        pass
    finally:
        with _COND:
            _SUBS[0] -= 1
