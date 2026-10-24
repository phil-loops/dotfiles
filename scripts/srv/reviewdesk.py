# srv/reviewdesk.py — the branch page's review, local side: what GitHub's review data looks like
# against the local tip, and the writes the page makes.
#
# The `review` domain of /state (srv/state.py builds it every tick from memory + a few stats):
#   conv    <repo>:<branch>          the PR: title, body, reviews, top-level comments, head, the
#                                    viewer, the local tip and its unpushed commits, the second
#                                    reader's "nobody flagged" list
#   thread  <repo>:<branch>#<node>   a review thread: full comment chain, GitHub's anchor (line on
#                                    the PR head) and `local` — that anchor followed to the local tip
#                                    (srv/linemap.py), with the commit that changed it, if one did;
#                                    `note` is the second reader's, when it left one
#   draft   <repo>:<branch>          the review being written: pending comments + summary, kept in
#                                    <common>/stack-review-drafts.json so a reload loses nothing
#   queued  <repo>:q:<id>            a reply naming an unpushed commit, waiting for that commit to
#                                    reach origin (<common>/stack-review-queue.json)
#
#   POST /review-draft   {branch, op: add|edit|remove|discard, comment?}   the pending review, locally
#   POST /review-submit  {branch, event: COMMENT|APPROVE|REQUEST_CHANGES, body}   finish the review
#   POST /review-comment {branch, path, side, line, startLine?, body}   add a single comment
#   POST /review-reply   {branch, thread, body}       reply (queued when it names an unpushed commit)
#   POST /review-resolve {branch, thread, resolved}   resolve / unresolve the conversation
#   POST /review-say     {branch, body}               a top-level conversation comment
#   POST /review-queue   {id, op: cancel}             let go of a queued reply
#   POST /review-apply   {branch, thread}             apply a suggestion as a LOCAL commit
#
# Every GitHub write goes through ghreview.mutate (its guards, its fake). Applying a suggestion is
# git only: a commit built in memory on the branch tip, landed the way /revert-commit lands one —
# `reset --keep` in the worktree holding the branch (refused when its file has edits there, or a
# gates run owns that worktree), else a compare-and-swap update-ref. Never a push.
#
# Second-reader notes (another agent writes them): <common>/stack-review-notes/<pr>/<thread-node>.json
# {verdict, evidence, elsewhere, cause, draftReply, model, at} and <pr>/_unflagged.json {items}.
import json
import os
import re
import subprocess
import tempfile
import threading
import time
import uuid

from . import ctx, ghreview, linemap, outbox, packet, repostate, watch

_DRAFTS = "stack-review-drafts.json"
_QUEUE = "stack-review-queue.json"
_NOTES = "stack-review-notes"
_FLOCK = threading.Lock()


def _send(req, code, payload):
    req._send(code, json.dumps(payload))


# ── small json files under the common dir, re-read only when they change ───

_FILES = {}


def _read(name, empty):
    path = os.path.join(watch.common_dir(), name)
    try:
        st = os.stat(path)
    except OSError:
        return empty() if callable(empty) else empty
    key = (st.st_mtime_ns, st.st_size)
    hit = _FILES.get(path)
    if not hit or hit[0] != key:
        try:
            with open(path) as f:
                hit = (key, json.load(f))
        except (OSError, ValueError):
            hit = (key, empty() if callable(empty) else empty)
        _FILES[path] = hit
    return hit[1]


def _write(name, data):
    path = os.path.join(watch.common_dir(), name)
    fd, tmp = tempfile.mkstemp(dir=os.path.dirname(path), prefix=".rv-")
    with os.fdopen(fd, "w") as f:
        json.dump(data, f, indent=1)
    os.replace(tmp, path)


def _drafts():
    return _read(_DRAFTS, dict)


def _queue():
    return _read(_QUEUE, lambda: {"items": []})


# ── second-reader notes ──────────────────────────────────────────────────

_NOTE_CACHE = {}


def notes(number):
    """({thread node: note}, unflagged or None) for one PR, re-read when its directory changes."""
    d = os.path.join(watch.common_dir(), _NOTES, str(number))
    try:
        ents = sorted((e.name, e.stat().st_mtime_ns, e.stat().st_size) for e in os.scandir(d) if e.name.endswith(".json"))
    except OSError:
        return {}, None
    hit = _NOTE_CACHE.get(d)
    if hit and hit[0] == ents:
        return hit[1]
    by, unflagged = {}, None
    for name, _m, _s in ents:
        try:
            with open(os.path.join(d, name)) as f:
                doc = json.load(f)
        except (OSError, ValueError):
            continue
        if not isinstance(doc, dict):
            continue
        if name == "_unflagged.json":
            unflagged = {"items": [i for i in doc.get("items") or [] if isinstance(i, dict)][:50],
                         "model": doc.get("model") or "", "at": doc.get("at") or ""}
        else:
            by[name[:-5]] = {
                "verdict": doc.get("verdict") if doc.get("verdict") in ("right", "wrong", "partly", "unclear") else "unclear",
                "evidence": [e for e in doc.get("evidence") or [] if isinstance(e, dict)][:20],
                "elsewhere": [e for e in doc.get("elsewhere") or [] if isinstance(e, dict)][:20],
                "cause": doc.get("cause") or None, "draftReply": doc.get("draftReply") or None,
                "model": doc.get("model") or "", "at": doc.get("at") or "",
            }
    _NOTE_CACHE[d] = (ents, (by, unflagged))
    return by, unflagged


# ── which PRs this repo reviews, and their data ──────────────────────────

def reviewed(snap=None):
    """{local branch: pr} for every open PR with review data: stack branches' PRs and imported
    review/pr-N branches."""
    snap = snap or repostate.snapshot()
    fake = ghreview.fake_prs()
    if fake is not None:
        out = {}
        for n, pr in fake.items():
            if pr.get("state") != "OPEN":
                continue
            b = pr["headRef"] if snap.exists(pr["headRef"]) else f"review/pr-{n}"
            if snap.exists(b):
                out[b] = pr
        return out
    prs, _src = outbox._pr_map()
    packet.remote_map(snap, prs)   # keeps the one poller warm while a v2 tab is open
    want = packet.wanted(snap, prs)
    have = ghreview.cached(set(want))
    return {b: have[n] for n, b in want.items() if n in have}


_UNPUSHED = {}


def unpushed(tip, head, origin):
    """The tip's commits GitHub doesn't have yet (not under the PR head or origin's ref), newest first."""
    key = (ctx.repo_cwd(), tip, head, origin)
    if key not in _UNPUSHED:
        nots = [f"^{x}" for x in {head, origin} if x and _has(x)]
        r = ctx.run(["git", "rev-list", "--max-count=50", tip, *nots]) if tip and nots else None
        if len(_UNPUSHED) > 256:
            _UNPUSHED.clear()
        _UNPUSHED[key] = r.stdout.split() if r and r.returncode == 0 else []
    return _UNPUSHED[key]


def _has(sha):
    return ctx.run(["git", "cat-file", "-e", f"{sha}^{{commit}}"]).returncode == 0


def entities(name):
    snap = repostate.snapshot()
    out = {"conv": {}, "thread": {}, "draft": {}, "queued": {}}
    drafts = _drafts()
    me = ghreview.viewer()
    for b, pr in reviewed(snap).items():
        cid = f"{name}:{b}"
        tip = snap.local(b)
        origin = snap.remote(pr["headRef"])
        live = [t for t in pr["threads"] if not t["outdated"] and t["line"] is not None and t["side"] == "RIGHT"]
        mapping = linemap.commits_between(pr["head"], tip, [t["path"] for t in live])
        by_node, unflagged = notes(pr["number"])
        for t in pr["threads"]:
            local = None
            if not t["outdated"] and t["line"] is not None:
                if t["side"] == "RIGHT":
                    local = linemap.locate(mapping["walk"], t["path"], t["startLine"] or t["line"], t["line"])
                else:
                    local = {"line": t["line"], "startLine": t["startLine"], "addressedBy": None}
            tid = f"{cid}#{t['node']}"
            out["thread"][tid] = {"id": tid, "repo": name, "branch": b, "pr": pr["number"], **t,
                                  "local": local, "note": by_node.get(t["node"])}
        d = drafts.get(b) or {}
        out["conv"][cid] = {
            "id": cid, "repo": name, "branch": b, "number": pr["number"], "title": pr["title"], "body": pr["body"],
            "url": pr["url"], "author": pr["author"], "state": pr["state"], "headRef": pr["headRef"],
            "base": pr["base"], "head": pr["head"], "tip": tip, "mapping": mapping["mode"],
            "unpushed": unpushed(tip, pr["head"], origin), "viewer": me,
            "reviews": pr["reviews"], "comments": pr["comments"], "pending": pr.get("pending"),
            "unflagged": unflagged, "at": pr.get("at") or 0,
        }
        out["draft"][cid] = {"id": cid, "repo": name, "branch": b, "comments": d.get("comments") or [],
                             "body": d.get("body") or ""}
    for it in _queue().get("items") or []:
        qid = f"{name}:q:{it['id']}"
        out["queued"][qid] = {"id": qid, "repo": name, **{k: it.get(k) for k in
                              ("branch", "number", "thread", "body", "waitsFor", "state", "err", "at")}}
        out["queued"][qid]["threadId"] = f"{name}:{it['branch']}#{it['thread']}"
    return out


# ── the reply queue's release ────────────────────────────────────────────

_RELEASE = {"seen": None, "busy": False}


def pushed():
    """A push just went to origin (push.py): look at the queue on the next tick, not after it."""
    _RELEASE["seen"] = None


def release_due():
    """Post each queued reply whose commits are all on GitHub now. Cheap when nothing moved:
    only a change in origin's refs (or a push) re-checks, and posting runs off the tick."""
    items = [i for i in _queue().get("items") or [] if i.get("state") == "waiting"]
    if not items or _RELEASE["busy"]:
        return
    snap = repostate.snapshot()
    sig = (ctx.repo_cwd(), snap.remote_tips())
    if _RELEASE["seen"] == sig:
        return
    _RELEASE["seen"] = sig
    prs = reviewed(snap)
    due = []
    for it in items:
        pr = prs.get(it["branch"])
        if not pr:
            continue
        on = [x for x in (snap.remote(pr["headRef"]), pr["head"]) if x]
        if all(any(snap.is_ancestor(sha, ref) for ref in on) for sha in it["waitsFor"]):
            due.append(it["id"])
    if due:
        _RELEASE["busy"] = True
        threading.Thread(target=_post_queued, args=(ctx.repo_cwd(), due), daemon=True).start()


def _set_item(qid, **fields):
    with _FLOCK:
        q = _queue()
        items = [dict(i, **fields) if i["id"] == qid else i for i in q.get("items") or []]
        if fields.get("_drop"):
            items = [i for i in items if i["id"] != qid]
        _write(_QUEUE, {"items": [{k: v for k, v in i.items() if k != "_drop"} for i in items]})


def _post_queued(repo, ids):
    from . import state
    ctx.set_repo(repo)
    try:
        for qid in ids:
            it = next((i for i in _queue().get("items") or [] if i["id"] == qid), None)
            if not it:
                continue
            _set_item(qid, state="posting")
            state.poke()
            try:
                ghreview.mutate("reply", {"thread": it["thread"], "body": it["body"]}, queued=True)
                _set_item(qid, _drop=True)
                ghreview.refetch(it["number"])
            except Exception as e:   # noqa: BLE001 — any failure stays visible on the item
                _set_item(qid, state="failed", err=str(e)[:200])
            state.poke()
    finally:
        _RELEASE["busy"] = False
        ctx.clear_repo()


# ── endpoints ────────────────────────────────────────────────────────────

def _body(raw):
    try:
        d = json.loads(raw or "{}")
    except ValueError:
        d = {}
    return d if isinstance(d, dict) else {}


def _pr_for(branch):
    pr = reviewed().get(branch)
    if not pr:
        raise ghreview.Refused(f"no open PR with review data for {branch}")
    return pr


def _to_head(branch, pr, path, start, end):
    """A local-tip line range back onto the PR head GitHub knows; refused when local commits
    changed those lines (there is nothing on GitHub to anchor to until they're pushed)."""
    snap = repostate.snapshot()
    tip = snap.local(branch)
    if not tip or tip == pr["head"]:
        return start, end
    back = linemap.commits_between(tip, pr["head"], [path])
    if back["mode"] == "unknown":
        return start, end
    at = linemap.locate(back["walk"], path, start, end)
    if at["addressedBy"] is not None:
        raise ghreview.Refused(f"{path}:{end} isn't on GitHub yet — push first")
    return at["startLine"] or at["line"], at["line"]


def _thread_input(branch, pr, c):
    line = int(c["line"])
    start = int(c["startLine"]) if c.get("startLine") else None
    side = "LEFT" if c.get("side") == "LEFT" else "RIGHT"
    if side == "RIGHT":
        s, line = _to_head(branch, pr, c["path"], start or line, line)
        start = s if start else None
    body = (c.get("body") or "").strip()
    if not body:
        raise ghreview.Refused("an empty comment")
    return {"path": c["path"], "line": line, "side": side, "body": body,
            **({"startLine": start} if start and start != line else {})}


def _settle(req, number, extra=None):
    ghreview.refetch(number)
    _send(req, 200, {"ok": True, **(extra or {})})


def _guarded(fn):
    def run(req, raw):
        try:
            return fn(req, _body(raw))
        except ghreview.Refused as e:
            return _send(req, 200, {"ok": False, "err": str(e)})
    return run


@_guarded
def draft(req, d):
    branch, op = d.get("branch") or "", d.get("op") or ""
    c = d.get("comment") or {}
    with _FLOCK:
        all_ = dict(_drafts())
        cur = dict(all_.get(branch) or {"comments": [], "body": ""})
        comments = list(cur.get("comments") or [])
        if op == "add":
            if not c.get("path") or not c.get("line") or not (c.get("body") or "").strip():
                raise ghreview.Refused("a draft comment needs a path, a line and words")
            comments.append({"id": c.get("id") or uuid.uuid4().hex[:10], "path": c["path"],
                             "side": "LEFT" if c.get("side") == "LEFT" else "RIGHT", "line": int(c["line"]),
                             "startLine": int(c["startLine"]) if c.get("startLine") else None,
                             "body": c["body"].strip(), "at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())})
        elif op == "edit":
            comments = [dict(x, body=c.get("body", x["body"])) if x["id"] == c.get("id") else x for x in comments]
        elif op == "remove":
            comments = [x for x in comments if x["id"] != c.get("id")]
        elif op == "body":
            cur["body"] = d.get("body") or ""
        elif op == "discard":
            comments, cur["body"] = [], ""
        else:
            raise ghreview.Refused(f"unknown draft op {op!r}")
        cur["comments"] = comments
        if comments or cur.get("body"):
            all_[branch] = cur
        else:
            all_.pop(branch, None)
        _write(_DRAFTS, all_)
    _send(req, 200, {"ok": True})


_EVENTS = ("COMMENT", "APPROVE", "REQUEST_CHANGES")


@_guarded
def submit(req, d):
    branch, event = d.get("branch") or "", d.get("event") or ""
    if event not in _EVENTS:
        raise ghreview.Refused(f"finish a review as one of {', '.join(_EVENTS)}")
    pr = _pr_for(branch)
    cur = _drafts().get(branch) or {}
    body = (d.get("body") if d.get("body") is not None else cur.get("body") or "").strip()
    threads = [_thread_input(branch, pr, c) for c in cur.get("comments") or []]
    if event != "APPROVE" and not threads and not body:
        raise ghreview.Refused("say something, or add a comment, before finishing")
    ghreview.mutate("review", {"pr": pr["number"], "event": event, "body": body, "threads": threads}, req)
    with _FLOCK:
        all_ = dict(_drafts())
        all_.pop(branch, None)
        _write(_DRAFTS, all_)
    _settle(req, pr["number"])


@_guarded
def comment(req, d):
    branch = d.get("branch") or ""
    pr = _pr_for(branch)
    th = _thread_input(branch, pr, d)
    ghreview.mutate("review", {"pr": pr["number"], "event": "COMMENT", "body": "", "threads": [th]}, req)
    _settle(req, pr["number"])


_SHA_WORD = re.compile(r"\b[0-9a-f]{7,40}\b")


def waits_for(branch, pr, body):
    """The unpushed commits a reply names (full shas), so it can wait for them."""
    snap = repostate.snapshot()
    pending = unpushed(snap.local(branch), pr["head"], snap.remote(pr["headRef"]))
    return sorted({full for w in _SHA_WORD.findall(body) for full in pending if full.startswith(w)})


@_guarded
def reply(req, d):
    branch, node, body = d.get("branch") or "", d.get("thread") or "", (d.get("body") or "").strip()
    if not body:
        raise ghreview.Refused("an empty reply")
    pr = _pr_for(branch)
    if not any(t["node"] == node for t in pr["threads"]):
        raise ghreview.Refused("that thread isn't on this PR")
    waits = waits_for(branch, pr, body)
    if waits:
        if ghreview.fake_prs() is None:   # the gesture is checked now: the post happens later, off a tick
            why = ghreview.refusal(req)
            if why:
                raise ghreview.Refused(why)
        qid = uuid.uuid4().hex[:10]
        with _FLOCK:
            q = _queue()
            _write(_QUEUE, {"items": [*(q.get("items") or []), {
                "id": qid, "branch": branch, "number": pr["number"], "thread": node, "body": body,
                "waitsFor": waits, "state": "waiting", "err": None, "at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
            }]})
        pushed()
        return _send(req, 200, {"ok": True, "queued": qid, "waitsFor": waits})
    ghreview.mutate("reply", {"thread": node, "body": body}, req)
    _settle(req, pr["number"])


@_guarded
def resolve(req, d):
    branch, node = d.get("branch") or "", d.get("thread") or ""
    pr = _pr_for(branch)
    ghreview.mutate("resolve" if d.get("resolved", True) else "unresolve", {"thread": node}, req)
    _settle(req, pr["number"])


@_guarded
def say(req, d):
    pr = _pr_for(d.get("branch") or "")
    body = (d.get("body") or "").strip()
    if not body:
        raise ghreview.Refused("an empty comment")
    ghreview.mutate("comment", {"pr": pr["number"], "body": body}, req)
    _settle(req, pr["number"])


@_guarded
def queue(req, d):
    qid = d.get("id") or ""
    if d.get("op") != "cancel":
        raise ghreview.Refused("the queue only lets go")
    _set_item(qid.rsplit(":", 1)[-1], _drop=True)
    _send(req, 200, {"ok": True})


# ── apply suggestion: a local commit, never a push ───────────────────────

_FENCE = re.compile(r"^```suggestion[^\n]*\n(.*?)^```", re.S | re.M)


def suggestion_of(body):
    """The replacement lines of a comment's first ```suggestion block, or None."""
    m = _FENCE.search((body or "").replace("\r\n", "\n"))
    if not m:
        return None
    return m.group(1).splitlines()


def replace_lines(text, start, end, lines):
    """text with its 1-based inclusive lines [start, end] replaced, keeping its line ending."""
    nl = "\r\n" if "\r\n" in text else "\n"
    rows = text.split(nl)
    trailing = rows and rows[-1] == ""
    if trailing:
        rows = rows[:-1]
    if start < 1 or end > len(rows) or start > end:
        raise ghreview.Refused(f"lines {start}–{end} aren't in the file any more")
    rows[start - 1:end] = lines
    return nl.join(rows) + (nl if trailing else "")


def _git(args, **kw):
    return subprocess.run(["git", *args], cwd=ctx.repo_cwd(), capture_output=True, text=True, **kw)


def _commit_file(tip, path, content, message):
    ls = _git(["ls-tree", tip, "--", path]).stdout.split()
    mode = ls[0] if ls else "100644"
    blob = _git(["hash-object", "-w", "--stdin", "--path", path], input=content).stdout.strip()
    fd, index = tempfile.mkstemp(prefix="rv-index-")
    os.close(fd)
    try:
        env = {**os.environ, "GIT_INDEX_FILE": index}
        if _git(["read-tree", tip], env=env).returncode != 0:
            raise ghreview.Refused("couldn't read the tip's tree")
        if _git(["update-index", "--cacheinfo", f"{mode},{blob},{path}"], env=env).returncode != 0:
            raise ghreview.Refused("couldn't stage the suggestion")
        tree = _git(["write-tree"], env=env).stdout.strip()
    finally:
        os.unlink(index)
    r = _git(["commit-tree", tree, "-p", tip, "-F", "-"], input=message)
    if r.returncode != 0:
        raise ghreview.Refused((r.stderr or "commit failed").strip()[:200])
    return r.stdout.strip()


def _land(branch, tip, new, path):
    """Move the branch from tip to new, in its worktree when one holds it."""
    from . import push, review
    job = push._GATE_JOBS.get(push._jkey(branch))
    if job and push._job_running(job):
        raise ghreview.Refused("a gates run owns this branch's worktree — apply it after the run")
    wt = review._worktree_for_branch(branch)
    if wt:
        if _git(["-C", wt, "rev-parse", "HEAD"]).stdout.strip() != tip:
            raise ghreview.Refused("the branch's worktree isn't at the branch tip")
        if _git(["-C", wt, "status", "--porcelain", "--", path]).stdout.strip():
            raise ghreview.Refused(f"{path} has unsaved edits in {wt} — apply it there by hand")
        r = _git(["-C", wt, "reset", "--keep", new])
        if r.returncode != 0:
            raise ghreview.Refused((r.stderr or "reset failed").strip()[:200])
        if _git(["rev-parse", f"refs/heads/{branch}"]).stdout.strip() == new:
            return
    r = _git(["update-ref", "-m", "apply review suggestion", f"refs/heads/{branch}", new, tip])
    if r.returncode != 0:
        raise ghreview.Refused("the branch moved underneath — try again")


@_guarded
def apply(req, d):
    branch, node = d.get("branch") or "", d.get("thread") or ""
    pr = _pr_for(branch)
    t = next((t for t in pr["threads"] if t["node"] == node), None)
    if not t:
        raise ghreview.Refused("that thread isn't on this PR")
    if t["outdated"] or t["line"] is None or t["side"] != "RIGHT":
        raise ghreview.Refused("an outdated suggestion — apply it by hand")
    src = next((c for c in t["comments"] if suggestion_of(c["body"]) is not None), None)
    if not src:
        raise ghreview.Refused("no suggestion in this thread")
    snap = repostate.snapshot()
    tip = snap.local(branch)
    walk = linemap.commits_between(pr["head"], tip, [t["path"]])["walk"]
    at = linemap.locate(walk, t["path"], t["startLine"] or t["line"], t["line"])
    if at["addressedBy"] is not None:
        raise ghreview.Refused("those lines changed since the suggestion — apply it by hand")
    shown = _git(["show", f"{tip}:{t['path']}"])
    if shown.returncode != 0:
        raise ghreview.Refused(f"{t['path']} isn't on the tip")
    text = replace_lines(shown.stdout, at["startLine"] or at["line"], at["line"], suggestion_of(src["body"]))
    ticket = snap.get(f"stack-project.{snap.project(branch)}.ticket").lower() if snap.project(branch) else ""
    scope = f"({ticket})" if ticket else ""
    leaf = t["path"].rsplit("/", 1)[-1]
    new = _commit_file(tip, t["path"], text, f"fix{scope}: apply {src['author']}'s suggestion in {leaf}\n\n{src['url']}\n")
    _land(branch, tip, new, t["path"])
    _send(req, 200, {"ok": True, "sha": new})
