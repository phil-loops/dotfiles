# srv/packet.py — the review packet: the PR body a branch publishes with, written as the contract a
# reviewer (and the john-hankles bot) checks the diff against. review_packet.py renders it; this
# module feeds it the facts the server already holds and keeps the two slow inputs off the request
# path: the model-drafted reading guide (cached on disk per branch + tree) and the open PRs' bodies
# and bot threads (one background GraphQL read per repo, like the outbox's open-PR detail cache).
#
#   GET  /packet?branch=B[&guide=auto]   {sections, body, title, label, guide, review}
#   POST /packet-guide {branch}          (re)draft "How to read it" with headless claude, in the background
#   GET  /packet-compare?branch=B[&base=X]   302 → the GitHub compare form, title + packet + label prefilled
#
# Never writes to GitHub: the compare link opens a form for Phil's hand, and the "copy updated
# body" the stale check offers is text for him to paste.
import json
import os
import re
import sys
import threading
import time
from urllib.parse import parse_qs

from . import ctx, ghreview, outbox, repostate, second_reader, sync

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
import review_packet as rp  # noqa: E402

BOT = "john-hankles"
GUIDE_MODEL = "sonnet"
GUIDE_TIMEOUT = 240


def _send(req, code, payload):
    req._send(code, json.dumps(payload))


_GIT_DIRS = {}


def git_dir():
    repo = ctx.repo_cwd()
    if repo not in _GIT_DIRS:
        _GIT_DIRS[repo] = ctx.run(["git", "rev-parse", "--path-format=absolute", "--git-common-dir"]).stdout.strip()
    return _GIT_DIRS[repo]


_LEDGER = {}   # path -> (mtime, parsed)


def _ledger(project):
    path = os.path.join(git_dir(), "stack-project-merges.json")
    try:
        mt = os.stat(path).st_mtime
    except OSError:
        return []
    hit = _LEDGER.get(path)
    if not hit or hit[0] != mt:
        try:
            with open(path) as fh:
                hit = (mt, json.load(fh).get("merges", {}))
        except (OSError, ValueError):
            hit = (mt, {})
        _LEDGER[path] = hit
    hist = hit[1].get(project, [])
    if isinstance(hist, dict):
        hist = [hist]
    return [{"pr": e.get("pr"), "title": e.get("title") or "", "branch": e.get("branch") or "", "state": "merged"}
            for e in reversed(hist)]


# ── the forest's facts, from an outbox forest (no spawns) ─────────────────────

def _ancestors(by_branch, node):
    seen, todo = set(), [node["parent"], *node.get("requires", [])]
    while todo:
        b = todo.pop()
        n = by_branch.get(b)
        if not n or b in seen:
            continue
        seen.add(b)
        todo += [n["parent"], *n.get("requires", [])]
    return seen


def forest_facts(project, nodes, node):
    """plan / stackedOn / after for one node, from the outbox forest it sits in plus the merge
    ledger (steps whose branches the forest already contracted away)."""
    if not node:
        return {"plan": [], "stackedOn": None, "after": []}
    by_branch = {n["branch"]: n for n in nodes}
    anc = _ancestors(by_branch, node)
    live_prs = {(n.get("pr") or {}).get("number") for n in nodes}
    plan = [s for s in _ledger(project) if s["branch"] not in by_branch and s.get("pr") not in live_prs]
    landed, rest = [], []
    for n in nodes:
        if n["status"] == "empty" and n is not node:
            continue
        pr = n.get("pr") or {}
        step = {"branch": n["branch"], "pr": pr.get("number"), "title": n.get("title") or "",
                "job": n.get("description") or n.get("title") or "", "me": n is node,
                "ancestor": n["branch"] in anc,
                "state": "merged" if n["status"] == "landed" else "open" if pr.get("number") else None}
        (landed if step["state"] == "merged" else rest).append(step)
    plan += landed + rest
    after = []
    for a in node.get("after") or []:
        an = by_branch.get(a)
        after.append({"branch": a, "pr": ((an or {}).get("pr") or {}).get("number"),
                      "job": (an or {}).get("description") or ""})
    so = node.get("stackedOn")
    return {"plan": plan if len(plan) > 1 else [], "stackedOn": so, "after": after}


def _forest_of(branch):
    """(snap, forest dict or None, node or None) via the outbox's own builder."""
    snap = repostate.snapshot()
    project = snap.project(branch)
    if not project:
        return snap, None, None
    prs, _ = outbox._pr_map()
    trunk = "origin/main" if snap.remote(snap.main()) else snap.main()
    graph = outbox._graph(snap, trunk)
    f = outbox._forest(snap, project, prs, outbox._slug(snap), graph)
    node = next((n for n in (f or {}).get("nodes", []) if n["branch"] == branch), None)
    return snap, f, node


# ── the branch's own facts (spawns: request-time only, never the outbox) ──────

def _floor(snap, branch):
    parent = snap.parent(branch)
    if parent in ("main", "master") or not snap.exists(parent):
        origin = f"origin/{snap.main()}"
        mb = ctx.run(["git", "merge-base", origin if snap.remote(snap.main()) else snap.main(), branch]).stdout.strip()
        return mb or parent
    return parent


def _gates(snap, branch, tree):
    """green for THIS tree + the gate names (and squawk's verdict) from the run that proved it."""
    green = snap.branch_key(branch, "gates-green-tree")
    out = {"green": bool(green) and green == tree, "tree": tree, "names": []}
    if not out["green"]:
        return out
    try:
        from . import push
        job = push._GATE_JOBS.get(push._jkey(branch)) or push._adopt_job(branch)
        if job and job.get("tree") == tree:
            res = next((e for e in push._journal_events(job["path"]) if e.get("event") == "result"), None)
            gates = (res or {}).get("gates") or []
            out["names"] = [g.get("name", "") for g in gates if g.get("name") and g.get("name") != "env"]
            sq = [g for g in gates if re.search(r"squawk|migration", g.get("name", ""), re.I)]
            if sq:
                out["squawk"] = all(g.get("ok") for g in sq)
    except Exception as e:   # the journal is a nicety; the verdict itself came from config
        ctx.log(f"packet: gate names for {branch}: {e!r}")
    return out


def facts(branch):
    snap, forest, node = _forest_of(branch)
    tip = snap.local(branch)
    tree = ctx.run(["git", "rev-parse", f"{branch}^{{tree}}"]).stdout.strip()
    floor = _floor(snap, branch)
    files = rp.diff_files(floor, branch, run=lambda *a: ctx.run(["git", *a]).stdout)
    subjects = [s for s in ctx.run(["git", "log", "--reverse", "--first-parent", "--format=%s", f"{floor}..{branch}"]).stdout.splitlines() if s]
    ff = forest_facts(snap.project(branch), (forest or {}).get("nodes", []), node)
    guide = rp.read_guide(git_dir(), branch, tree)
    return {
        "branch": branch, "tip": tip, "tree": tree, "floor": floor,
        "description": snap.description(branch), "subjects": subjects,
        "hand": rp.load_hand(snap.branch_key(branch, "packet")),
        **ff, "files": files, "guide": guide, "gates": _gates(snap, branch, tree),
        "template": outbox._template(snap),
        "title": landing_title(snap, branch, subjects),
        "label": snap.branch_key(branch, "pr-label") != "off",
        "node": node, "forest": forest,
    }


def landing_title(snap, branch, subjects):
    return snap.branch_key(branch, "pr-title") or (subjects[0] if subjects else snap.description(branch) or branch)


def body(branch):
    """The landing body: a hand-written legacy stack-pr-body wins verbatim; else the packet."""
    snap = repostate.snapshot()
    saved = snap.branch_key(branch, "pr-body")
    if saved:
        return saved
    f = facts(branch)
    return rp.render(rp.build(f), f["template"])


def label_on(branch):
    return repostate.snapshot().branch_key(branch, "pr-label") != "off"


# ── open PRs: body + bot threads, one background GraphQL read per repo ───────

_REMOTE_TTL = 120.0
_REMOTE = {}
_REMOTE_LOCK = threading.Lock()
_REMOTE_BUSY = set()

_CHUNK = 10   # full review threads per PR make each query heavier than the old first-comment read


def _fetch_remote(slug, numbers):
    """The open PRs' bodies + review threads, one GraphQL read per chunk. Every PR also lands whole
    (full comment chains, reviews) in ghreview's cache, which the branch page's threads read."""
    owner, _, name = slug.partition("/")
    out = {}
    for i in range(0, len(numbers), _CHUNK):
        chunk = numbers[i:i + _CHUNK]
        q = "query { viewer { login } repository(owner: %s, name: %s) { %s } }" % (
            json.dumps(owner), json.dumps(name),
            " ".join(f"p{n}: pullRequest(number: {n}) {{ {ghreview.PR_FIELDS} }}" for n in chunk))
        r = ctx.run(["gh", "api", "graphql", "-f", f"query={q}"], timeout=40)
        if r.returncode != 0:
            ctx.log(f"packet: graphql read failed: {(r.stderr or '')[:200]}")
            return None
        try:
            data = json.loads(r.stdout or "{}").get("data") or {}
        except ValueError:
            return None
        login = (data.get("viewer") or {}).get("login")
        for pr in (data.get("repository") or {}).values():
            if not pr:
                continue
            full = ghreview.parse_pr(pr)
            ghreview.absorb(ctx.repo_cwd(), full, login)
            second_reader.on_pr(ctx.repo_cwd(), full)
            out[full["headRef"]] = _legacy(full)
    return out


def _legacy(full):
    return {"number": full["number"], "title": full["title"], "body": full["body"], "url": full["url"],
            "threads": ghreview.legacy_threads(full), "botRan": full["botRan"]}


def absorb_one(full):
    """A single PR re-read after a write: fold it into this repo's packet cache too."""
    with _REMOTE_LOCK:
        ent = _REMOTE.get(ctx.repo_cwd())
        if ent:
            ent["data"][full["headRef"]] = _legacy(full)


def _refresh_remote(repo, slug, numbers):
    try:
        ctx.set_repo(repo)
        fresh = _fetch_remote(slug, numbers)
        if fresh is not None:
            with _REMOTE_LOCK:
                _REMOTE[repo] = {"at": time.time(), "data": fresh, "numbers": tuple(numbers)}
            ctx.bump_pulse()
    finally:
        _REMOTE_BUSY.discard(repo)


def remote_map(snap, prs):
    """{branch: {number, title, body, url, threads, botRan}} for the open PRs of stack branches and
    imported review/pr-N branches — the fake GitHub's or the fixture's own entries when one is set,
    else the background cache."""
    fake = ghreview.fake_prs()
    if fake is not None:
        return {p["headRef"]: _legacy(p) for p in fake.values() if p.get("state") == "OPEN"}
    fx = outbox._fixture()
    if fx is not None:
        return {b: {"number": p.get("number"), "title": p.get("title", ""), "body": p.get("body", ""),
                    "url": p.get("url", ""), "threads": p.get("threads") or [], "botRan": bool(p.get("botRan"))}
                for b, p in fx.items() if isinstance(p, dict) and p.get("state") == "OPEN"}
    repo = ctx.repo_cwd()
    numbers = sorted(wanted(snap, prs))
    with _REMOTE_LOCK:
        ent = _REMOTE.get(repo)
        stale = not ent or time.time() - ent["at"] >= _REMOTE_TTL or ent.get("numbers") != tuple(numbers)
        if stale and numbers and repo not in _REMOTE_BUSY:
            slug = outbox._slug(snap)
            if slug:
                _REMOTE_BUSY.add(repo)
                threading.Thread(target=_refresh_remote, args=(repo, slug, numbers), daemon=True).start()
        return ent["data"] if ent else {}


def wanted(snap, prs):
    """{number: local branch} whose review data the poller keeps: open PRs of stack branches, and
    open PRs imported as review/pr-N branches."""
    out = {}
    for b, p in (prs or {}).items():
        if p.get("state") == "OPEN" and p.get("number") and snap.project(b):
            out[p["number"]] = b
    open_numbers = {p.get("number") for p in (prs or {}).values() if p.get("state") == "OPEN"}
    for ref in snap.sha:
        if ref.startswith("refs/heads/review/pr-"):
            n = ref[len("refs/heads/review/pr-"):]
            if n.isdigit() and int(n) in open_numbers and int(n) not in out:
                out[int(n)] = ref[len("refs/heads/"):]
    return out


def review_state(project, nodes, node, remote):
    """For a node with an open PR: is its published Where-this-sits behind the forest, and what
    did the bot find? None until the PR's body has been read."""
    pub = remote.get(node["branch"])
    if not pub:
        return None
    ff = forest_facts(project, nodes, node)
    fresh = rp.where_lines(ff["plan"], ff["stackedOn"], ff["after"])
    st = rp.staleness(pub["body"], fresh) or {"stale": False, "mergedSince": [], "openedSince": [], "updatedBody": ""}
    claims = rp.claims_of(pub["body"])
    findings = rp.match_findings(claims, pub["threads"], BOT)
    return {**st, "url": pub["url"], "number": pub["number"], "claims": claims, "findings": findings,
            "botRan": pub["botRan"] or bool(findings), "packet": "Intent" in rp.sections_of(pub["body"])}


# ── the reading guide: headless claude, once per (branch, tree) ──────────────

_GUIDE_JOBS = {}   # (repo, branch, tree) -> {"state", "err", "at"}
_GUIDE_LOCK = threading.Lock()

_GUIDE_PROMPT = """You are drafting the "How to read it" section of a pull request description for the branch `{branch}`.
A reviewer will read the diff in the order you give, in one sitting, so put the files in the order that makes the change easiest to follow: usually schema/queries → models → wiring → UI → tests, but follow the change's own logic when it differs.

What the branch does: {description}
Its commits, oldest first:
{outline}

Changed files (status, lines added/removed):
{files}

Return ONLY a JSON array, no prose and no code fence. One object per file worth reading, in reading order:
{{"path": "<exact path from the list>", "note": "<at most 12 words>"}}
In each note say what to look for in that file. Mark the file holding the core logic with a note that starts "the core of it:". Say "skim — moved verbatim" for code that was only moved, "mechanical — skim" for renames/import churn, and "generated — skip" for generated files. Read files if you need to; the diff below may be truncated.

{diff}"""


def _guide_prompt(f):
    diff = ctx.run(["git", "diff", f"{f['floor']}...{f['branch']}"]).stdout
    cap = 60_000
    if len(diff) > cap:
        diff = diff[:cap] + f"\n… (diff truncated at {cap} chars — Read the files for the rest)"
    files = "\n".join(f"- {x['status']} {x['path']}" + (f" (from {x['old']})" if x.get("old") else "")
                      + f" +{x['add']} -{x['del']}" for x in f["files"])
    outline = "\n".join(f"{i}. {s}" for i, s in enumerate(f["subjects"], 1)) or "(none)"
    return _GUIDE_PROMPT.format(branch=f["branch"], description=f["description"] or "(no description)",
                                outline=outline, files=files, diff=diff)


def parse_guide(text, files):
    """The model's JSON array, kept only for paths that are really in the diff; any file it left
    out is appended in the deterministic order so nothing silently drops."""
    s, e = (text or "").find("["), (text or "").rfind("]")
    try:
        arr = json.loads(text[s:e + 1]) if 0 <= s < e else []
    except ValueError:
        arr = []
    known = {x["path"] for x in files}
    out, seen = [], set()
    for it in arr if isinstance(arr, list) else []:
        if not isinstance(it, dict):
            continue
        p = str(it.get("path") or "").strip().strip("`")
        if p in known and p not in seen:
            seen.add(p)
            out.append({"path": p, "note": " ".join(str(it.get("note") or "").split())[:140]})
    if not out:
        return None
    out += [x for x in rp.reading_order(files) if x["path"] not in seen]
    return out


def _run_guide(repo, key, f):
    from . import chat
    ctx.set_repo(repo)
    job = _GUIDE_JOBS[key]
    try:
        wt = chat._worktree_for(f["branch"])
        cmd = ["claude", "-p", _guide_prompt(f), "--model", GUIDE_MODEL, "--no-session-persistence"]
        if wt:
            cmd += ["--tools", "Read", "Grep", "Glob", "--allowedTools", "Read", "Grep", "Glob"]
        else:   # no checkout of this branch: Read would see some other tree, so the diff is all it gets
            cmd += ["--tools", ""]
        r = _run_in(cmd, wt or repo)
        lines = parse_guide(r.stdout, f["files"])
        if not lines:
            raise RuntimeError((r.stderr or r.stdout or "no usable reading order")[:200])
        path = rp.guide_path(git_dir(), f["branch"], f["tree"])
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "w") as fh:
            json.dump({"branch": f["branch"], "tree": f["tree"], "model": GUIDE_MODEL, "at": int(time.time()),
                       "lines": lines}, fh, indent=1)
        job["state"] = "done"
    except Exception as e:
        job.update(state="failed", err=str(e)[:200])
        ctx.log(f"packet: guide for {f['branch']} failed: {e!r}")
    finally:
        job["at"] = time.time()
        ctx.bump_pulse()


def _run_in(cmd, cwd):
    import subprocess
    try:
        return subprocess.run(cmd, cwd=cwd, capture_output=True, text=True, timeout=GUIDE_TIMEOUT)
    except subprocess.TimeoutExpired:
        return subprocess.CompletedProcess(cmd, 124, "", f"timed out after {GUIDE_TIMEOUT}s")


def start_guide(f, force=False):
    key = (ctx.repo_cwd(), f["branch"], f["tree"])
    with _GUIDE_LOCK:
        job = _GUIDE_JOBS.get(key)
        if job and job["state"] == "running":
            return job
        if job and job["state"] == "failed" and not force:
            return job
        if f["guide"] and not force:
            return {"state": "done"}
        if not f["files"]:
            return {"state": "empty"}
        job = _GUIDE_JOBS[key] = {"state": "running", "err": "", "at": time.time()}
    threading.Thread(target=_run_guide, args=(ctx.repo_cwd(), key, f), daemon=True).start()
    return job


def _guide_state(f):
    job = _GUIDE_JOBS.get((ctx.repo_cwd(), f["branch"], f["tree"]))
    if job and job["state"] == "running":
        return {"state": "running"}
    if f["guide"]:
        return {"state": "done", "tree": f["tree"]}
    if job and job["state"] == "failed":
        return {"state": "failed", "err": job["err"]}
    return {"state": "none"}


# ── endpoints ─────────────────────────────────────────────────────────────

def get(req, u):
    q = parse_qs(u.query)
    branch = (q.get("branch", [""]) or [""])[0]
    if not branch:
        return _send(req, 400, {"ok": False, "err": "no branch"})
    if ctx.run(["git", "rev-parse", "--verify", "-q", f"refs/heads/{branch}"]).returncode != 0:
        return _send(req, 404, {"ok": False, "err": f"no local branch {branch}"})
    f = facts(branch)
    preview = (q.get("hand", [""]) or [""])[0]
    if preview:   # the editor's unsaved hand parts, rendered for its preview — never stored here
        f["hand"] = rp.load_hand(preview)
    p = rp.build(f)
    if (q.get("guide", [""]) or [""])[0] == "auto" and p["readSource"] != "hand":
        start_guide(f)
    snap = repostate.snapshot()
    review = None
    node = f["node"]
    if node and node.get("pr") and node["pr"].get("state") == "OPEN":
        prs, _ = outbox._pr_map()
        review = review_state(snap.project(branch), f["forest"]["nodes"], node, remote_map(snap, prs))
    saved_body = snap.branch_key(branch, "pr-body")
    _send(req, 200, {
        "ok": True, "branch": branch, "tree": f["tree"], "title": f["title"], "label": f["label"],
        "labelName": rp.LABEL, "sections": p, "hand": f["hand"],
        "body": saved_body or rp.render(p, f["template"]), "packetBody": rp.render(p, f["template"]),
        "legacyBody": bool(saved_body), "template": f["template"],
        "guide": _guide_state(f), "review": review,
        "pr": (node or {}).get("pr"),
    })


def guide(req, raw):
    d = json.loads(raw or "{}")
    branch = (d.get("branch") or "").strip()
    if not branch or ctx.run(["git", "rev-parse", "--verify", "-q", f"refs/heads/{branch}"]).returncode != 0:
        return _send(req, 400, {"ok": False, "err": "no such branch"})
    f = facts(branch)
    job = start_guide(f, force=True)
    _send(req, 200, {"ok": True, "state": job["state"], "tree": f["tree"]})


def compare(req, u):
    """302 to the compare-and-create form, built at click time so the outbox spends nothing per
    node and the packet carries whatever the forest looks like now."""
    from . import push
    q = parse_qs(u.query)
    branch = (q.get("branch", [""]) or [""])[0]
    base = (q.get("base", [""]) or [""])[0] or None
    if not branch or ctx.run(["git", "rev-parse", "--verify", "-q", f"refs/heads/{branch}"]).returncode != 0:
        return _send(req, 404, {"ok": False, "err": "no such branch"})
    url = push.compare_url(branch, base)
    if not url:
        return _send(req, 404, {"ok": False, "err": "no GitHub remote"})
    req.send_response(302)
    req.send_header("Location", url)
    req.send_header("Content-Length", "0")
    req.end_headers()


def _repo_prefix():
    repo = ctx.repo_cwd()
    name = next((n for n, p in (ctx.REPOS or {}).items() if p == repo), "")
    return "/" + name if name else ""


def compare_path(branch, base):
    from urllib.parse import quote
    return f"{_repo_prefix()}/packet-compare?branch={quote(branch, safe='')}&base={quote(base, safe='')}"
