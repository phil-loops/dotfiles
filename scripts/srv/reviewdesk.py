# srv/reviewdesk.py — the branch page's review, local side: what GitHub's review data looks like
# against the local tip, the ledger of what Phil writes, and the local suggestion commit.
#
# The `review` domain of /state (srv/state.py builds it every tick from memory + a few stats):
#   conv    <repo>:<branch>          the PR: title, body, reviews, top-level comments, head, the
#                                    viewer and his pending review, the local tip and its unpushed
#                                    commits, the second reader's "nobody flagged" list
#   thread  <repo>:<branch>#<node>   a review thread: full comment chain, GitHub's anchor (line on
#                                    the PR head) and `local` — that anchor followed to the local tip
#                                    (srv/linemap.py), with the commit that changed it, if one did;
#                                    `note` is the second reader's, when it left one; `fixedBy` the
#                                    commits that declare they address it (an `Addresses: <url of its
#                                    first comment>` trailer — wiki canopy-v2-address)
#   draft   <repo>:<branch>          the ledger's items for this branch (below), each with its state
#
# The ledger (<common>/stack-review-ledger.json) holds every comment and reply Phil writes here,
# durable across reloads. Each item has an idempotency key and moves
#     draft ──(Phil's keypress)──▶ sending ──▶ pending   (in his pending review on GitHub)
#                                                └──▶ submitted   (he pressed Submit on GitHub)
# `pending` and `submitted` are never assumed: they're read off GitHub, by finding the key each
# sent body carries. A failed send stays a draft with its error, retried with a keypress. A draft
# naming a commit that isn't on origin yet waits (`waiting`) and goes into the pending review once
# a push puts it there. The viewer never submits, resolves, or posts outside that pending review
# (srv/ghreview.py holds the only three mutations).
#
#   POST /review-draft  {branch, op: add, item, send?}   a comment {kind: comment, path, side, line,
#                                                         startLine?} or reply {kind: reply, thread};
#                                                         send: true goes on to the pending review
#                       {branch, op: send, keys?}        send these drafts (all, without keys)
#                       {branch, op: edit|remove, key, body?}   a draft not yet sent
#   POST /review-address {branch, thread, sha, head}     declare `sha` the thread's fix: its message
#                                                         gains `Addresses: <thread url>` (outline's
#                                                         guarded rewrite) and a reply "done in {fix}"
#                                                         is drafted to ride the push
#                        {branch, thread, claude: true}   hand it to a fresh Claude in the branch's
#                                                         worktree, the prompt drafted unsent, and
#                                                         draft the reply to wait for its fix
#                        {branch, undo: key}              take both back (outline undo + the draft)
#   POST /review-apply  {branch, thread}                 apply a suggestion as a LOCAL commit — git
#                                                         only, landed the way /revert-commit lands
#                                                         one (reset --keep in the branch's worktree,
#                                                         refused over edits there or a gates run;
#                                                         else a compare-and-swap update-ref). Never a push.
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

_LEDGER = "stack-review-ledger.json"
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


def _items():
    return _read(_LEDGER, lambda: {"items": []}).get("items") or []


def _save_items(items):
    _write(_LEDGER, {"items": items})


def _update(key, **fields):
    with _FLOCK:
        _save_items([dict(i, **fields) if i["key"] == key else i for i in _items()])


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


def on_github(pr):
    """{ledger key: (comment id, comment state, thread node)} for the bodies GitHub holds."""
    out = {}
    for t in pr["threads"]:
        for c in t["comments"]:
            k = ghreview.key_of(c["body"])
            if k:
                out[k] = (c["id"], c.get("state") or "SUBMITTED", t["node"])
    return out


def shown(item, pr, seen, waiting):
    """An item's state as GitHub and the refs say it is now."""
    hit = seen.get(item["key"])
    if hit:
        return "pending" if hit[1] == "PENDING" else "submitted"
    st = item.get("state") or "draft"
    if st == "sent":
        return "gone" if (pr.get("at") or 0) > (item.get("sentAt") or 0) + 2 else "sending"
    if st == "sending":
        return "sending"
    return "waiting" if waiting else "draft"


def entities(name):
    snap = repostate.snapshot()
    out = {"conv": {}, "thread": {}, "draft": {}}
    items = _items()
    me = ghreview.viewer()
    for b, pr in reviewed(snap).items():
        cid = f"{name}:{b}"
        tip = snap.local(b)
        origin = snap.remote(pr["headRef"])
        live = [t for t in pr["threads"] if not t["outdated"] and t["line"] is not None and t["side"] == "RIGHT"]
        mapping = linemap.commits_between(pr["head"], tip, [t["path"] for t in live])
        by_node, unflagged = notes(pr["number"])
        fixed = fixes(snap, b, pr)
        for t in pr["threads"]:
            local = None
            if not t["outdated"] and t["line"] is not None:
                if t["side"] == "RIGHT":
                    local = linemap.locate(mapping["walk"], t["path"], t["startLine"] or t["line"], t["line"])
                    if mapping["mode"] == "behind" and local["addressedBy"] is not None:
                        local = None   # its lines aren't on the (older) local tip: shown beside the file
                    elif mapping["mode"] == "behind":
                        local["addressedBy"] = None
                else:
                    local = {"line": t["line"], "startLine": t["startLine"], "addressedBy": None}
            tid = f"{cid}#{t['node']}"
            out["thread"][tid] = {"id": tid, "repo": name, "branch": b, "pr": pr["number"], **t,
                                  "local": local, "note": by_node.get(t["node"]),
                                  "fixedBy": fixed.get(thread_url(t)) or []}
        seen = on_github(pr)
        mine = []
        for it in items:
            if it["branch"] != b:
                continue
            held = [w for w in waits(snap, pr, it) if not on_origin(snap, pr, w)]
            no_fix = bool(it.get("fixFor")) and not _fix_of(snap, it, pr)
            mine.append({**{k: it.get(k) for k in ("key", "kind", "path", "side", "line", "startLine", "thread", "body", "err", "at", "fixFor")},
                         "threadId": f"{cid}#{it['thread']}" if it.get("thread") else None,
                         "state": "waiting" if no_fix and it.get("state") in ("draft", None) else shown(it, pr, seen, held),
                         "waitsFor": held, "waitingFix": no_fix, "send": bool(it.get("send"))})
        out["conv"][cid] = {
            "id": cid, "repo": name, "branch": b, "number": pr["number"], "title": pr["title"], "body": pr["body"],
            "url": pr["url"], "author": pr["author"], "state": pr["state"], "headRef": pr["headRef"],
            "base": pr["base"], "head": pr["head"], "tip": tip, "mapping": mapping["mode"], "behind": mapping.get("behind", 0),
            "unpushed": unpushed(tip, pr["head"], origin), "viewer": me,
            "reviews": pr["reviews"], "comments": pr["comments"], "pending": pr.get("pending"),
            "unflagged": unflagged, "at": pr.get("at") or 0,
        }
        out["draft"][cid] = {"id": cid, "repo": name, "branch": b, "items": mine}
    return out


def on_origin(snap, pr, sha):
    return any(snap.is_ancestor(sha, ref) for ref in (snap.remote(pr["headRef"]), pr["head"]) if ref)


# ── sending into Phil's pending review ───────────────────────────────────

class Waiting(Exception):
    pass


def send_one(item, req=None, released=False):
    """One draft into the pending review: idempotent by its key (a body GitHub already holds is
    recognised, not sent again). Raises ghreview.Refused / Waiting; records the outcome."""
    snap = repostate.snapshot()
    pr = ghreview.refetch(item["number"]) or _pr_for(item["branch"])
    if item.get("fixFor") and not _fix_of(snap, item, pr):
        raise Waiting(item["key"])   # no commit declares the thread yet (or any more)
    if any(not on_origin(snap, pr, w) for w in waits(snap, pr, item)):
        raise Waiting(item["key"])
    if item["key"] in on_github(pr):
        _update(item["key"], state="sent", err=None, send=False, sentAt=time.time())
        return
    thread = next((t for t in pr.get("threads") or [] if t["node"] == item.get("thread")), None)
    why = ghreview.scope_refusal(item["kind"], thread)
    if why:
        _update(item["key"], state="draft", err=why, send=False)
        raise ghreview.Refused(why)
    _update(item["key"], state="sending", err=None)
    try:
        review = (pr.get("pending") or {}).get("id")
        if not review:
            got = ghreview.mutate("addPullRequestReview", {"pullRequestId": pr["id"], "commitOID": pr["head"]}, req, released)
            review = got["pullRequestReview"]["id"]
        text = item["body"].replace("{fix}", _fix_of(snap, item, pr)["short"]) if item.get("fixFor") else item["body"]
        body = text + ghreview.marker(item["key"])
        if item["kind"] == "reply":
            ghreview.mutate("addPullRequestReviewThreadReply",
                            {"pullRequestReviewThreadId": item["thread"], "pullRequestReviewId": review, "body": body}, req, released)
        else:
            start, line = _to_head(item["branch"], pr, item["path"], item.get("startLine") or item["line"], item["line"])
            side = "LEFT" if item.get("side") == "LEFT" else "RIGHT"
            inp = {"pullRequestReviewId": review, "path": item["path"], "line": line, "side": side,
                   "subjectType": "LINE", "body": body}
            if item.get("startLine") and start != line:
                inp.update(startLine=start, startSide=side)
            ghreview.mutate("addPullRequestReviewThread", inp, req, released)
    except Exception as e:   # noqa: BLE001 — every failure stays on the draft, retryable
        _update(item["key"], state="draft", err=str(e)[:200], send=False)
        raise ghreview.Refused(str(e)[:200]) from e
    _update(item["key"], state="sent", err=None, send=False, sentAt=time.time() + 0.001, review=review)
    ghreview.refetch(item["number"])


_RELEASE = {"seen": None, "busy": False}


def pushed():
    """A push just went to origin (push.py): look at waiting drafts on the next tick."""
    _RELEASE["seen"] = None


def release_due():
    """Send each draft Phil already sent that was waiting on a push, once its commits are on origin.
    Cheap when nothing moved: only a change in origin's refs re-checks; sending runs off the tick."""
    items = [i for i in _items() if i.get("state") == "draft" and i.get("send") and (i.get("waitsFor") or i.get("fixFor"))]
    if not items or _RELEASE["busy"]:
        return
    snap = repostate.snapshot()
    sig = (ctx.repo_cwd(), snap.remote_tips())
    if _RELEASE["seen"] == sig:
        return
    _RELEASE["seen"] = sig
    prs = reviewed(snap)
    due = [i["key"] for i in items if prs.get(i["branch"]) and (not i.get("fixFor") or _fix_of(snap, i, prs[i["branch"]]))
           and all(on_origin(snap, prs[i["branch"]], w) for w in waits(snap, prs[i["branch"]], i))]
    if due:
        _RELEASE["busy"] = True
        threading.Thread(target=_release, args=(ctx.repo_cwd(), due), daemon=True).start()


def _release(repo, keys):
    from . import state
    ctx.set_repo(repo)
    try:
        for k in keys:
            it = next((i for i in _items() if i["key"] == k), None)
            if not it:
                continue
            try:
                send_one(it, released=True)
            except (ghreview.Refused, Waiting):
                pass
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


def _guarded(fn):
    def run(req, raw):
        try:
            return fn(req, _body(raw))
        except ghreview.Refused as e:
            return _send(req, 200, {"ok": False, "err": str(e)})
    return run


_SHA_WORD = re.compile(r"\b[0-9a-f]{7,40}\b")

# ── addressing a thread: a declared link, carried in the commit ──────────

TRAILER = "Addresses"
_TRAILER_LINE = re.compile(r"^[A-Za-z][A-Za-z-]*: \S")
_FIXES = {}   # (repo, base, tip) -> {thread url: [{sha, short, subject}]}


def add_trailer(body, url):
    """The message body naming `url` as a thread it addresses, in its trailer block (made if it
    has none); a body that already names it is returned as it is."""
    line = f"{TRAILER}: {url}"
    body = (body or "").rstrip()
    if line in body.splitlines():
        return body
    if not body:
        return line
    last = body.split("\n\n")[-1]
    trailers = all(_TRAILER_LINE.match(ln) for ln in last.splitlines())
    return f"{body}\n{line}" if trailers and "\n\n" in body else f"{body}\n\n{line}"


def fixes_between(base, branch):
    """{thread url: [commits]} for the commits in base..branch whose trailers name a thread, newest
    first. git parses the trailers, so a reworded or rebased commit keeps its link."""
    fmt = f"%H%x1f%s%x1f%(trailers:key={TRAILER},valueonly,separator=%x1d)%x1e"
    out = {}
    for rec in ctx.run(["git", "log", f"--format={fmt}", f"{base}..{branch}"]).stdout.split("\x1e"):
        parts = rec.strip("\n").split("\x1f")
        if len(parts) < 3:
            continue
        for url in filter(None, (u.strip() for u in parts[2].split("\x1d"))):
            out.setdefault(url, []).append({"sha": parts[0], "short": parts[0][:7], "subject": parts[1]})
    return out


def fixes(snap, branch, pr):
    """fixes_between the PR's base and the local tip, memoised on both — a spawn only when they move."""
    base = f"origin/{pr['base']}" if snap.remote(pr["base"]) else pr["base"]
    key = (ctx.repo_cwd(), base, snap.local(branch))
    hit = _FIXES.get(key)
    if hit is None:
        hit = _FIXES[key] = fixes_between(base, branch)
        if len(_FIXES) > 400:
            for k in list(_FIXES)[:200]:
                del _FIXES[k]
    return hit


def thread_url(t):
    return ((t.get("comments") or [{}])[0] or {}).get("url") or ""


def _fix_of(snap, item, pr):
    """The commit a "done in {fix}" reply names now: the newest one declaring its thread."""
    got = fixes(snap, item["branch"], pr).get(item.get("fixFor") or "") or []
    return got[0] if got else None


def waits(snap, pr, item):
    """What a draft waits on before it can go: the commits its body names, and its fix's."""
    out = list(item.get("waitsFor") or [])
    if item.get("fixFor"):
        fx = _fix_of(snap, item, pr)
        if fx and fx["sha"] not in out:
            out.append(fx["sha"])
    return out


def waits_for(branch, pr, body):
    """The unpushed commits a body names (full shas): its draft waits for them to reach origin."""
    snap = repostate.snapshot()
    pending = unpushed(snap.local(branch), pr["head"], snap.remote(pr["headRef"]))
    return sorted({full for w in _SHA_WORD.findall(body) for full in pending if full.startswith(w)})


def _new_item(branch, pr, it):
    body = (it.get("body") or "").strip()
    if not body:
        raise ghreview.Refused("an empty comment")
    kind = "reply" if it.get("kind") == "reply" else "comment"
    out = {"key": str(it.get("key") or uuid.uuid4().hex[:12]), "branch": branch, "number": pr["number"], "kind": kind,
           "body": body, "state": "draft", "send": False, "err": None, "waitsFor": waits_for(branch, pr, body),
           "at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())}
    if kind == "reply":
        if not any(t["node"] == it.get("thread") for t in pr["threads"]):
            raise ghreview.Refused("that thread isn't on this PR")
        out["thread"] = it["thread"]
        if it.get("fixFor"):
            out["fixFor"] = str(it["fixFor"])
    else:
        if not it.get("path") or not it.get("line"):
            raise ghreview.Refused("a comment needs a path and a line")
        out.update(path=it["path"], side="LEFT" if it.get("side") == "LEFT" else "RIGHT", line=int(it["line"]),
                   startLine=int(it["startLine"]) if it.get("startLine") else None)
    return out


def _send_keys(req, branch, keys):
    """Send these drafts; the first refusal answers (the drafts stay, with their error)."""
    errs, waiting = [], []
    for k in keys:
        it = next((i for i in _items() if i["key"] == k and i["branch"] == branch), None)
        if not it or it.get("state") not in ("draft", None):
            continue
        _update(k, send=True)
        try:
            send_one({**it, "send": True}, req)
        except Waiting:
            waiting.append(k)
        except ghreview.Refused as e:
            errs.append(str(e))
    if errs:
        return _send(req, 200, {"ok": False, "err": f"kept as a draft — {errs[0]}"})
    _send(req, 200, {"ok": True, "waiting": waiting})


@_guarded
def draft(req, d):
    branch, op = d.get("branch") or "", d.get("op") or ""
    if op == "add":
        pr = _pr_for(branch)
        item = _new_item(branch, pr, d.get("item") or {})
        with _FLOCK:
            items = [i for i in _items() if i["key"] != item["key"]]
            # submitted items are GitHub's now; the ledger keeps a week of them
            cutoff = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(time.time() - 7 * 86400))
            items = [i for i in items if not (i.get("state") == "sent" and (i.get("at") or "") < cutoff)]
            _save_items([*items, item])
        if d.get("send"):
            return _send_keys(req, branch, [item["key"]])
        return _send(req, 200, {"ok": True})
    if op == "send":
        keys = d.get("keys") or [i["key"] for i in _items() if i["branch"] == branch and i.get("state") in ("draft", None)]
        return _send_keys(req, branch, keys)
    key = d.get("key") or ""
    it = next((i for i in _items() if i["key"] == key and i["branch"] == branch), None)
    if not it:
        raise ghreview.Refused("no such draft")
    if it.get("state") not in ("draft", None):
        raise ghreview.Refused("it's on GitHub already — change it there")
    with _FLOCK:
        if op == "remove":
            _save_items([i for i in _items() if i["key"] != key])
        elif op == "edit":
            body = (d.get("body") or "").strip()
            if not body:
                raise ghreview.Refused("an empty comment")
            pr = _pr_for(branch)
            _save_items([dict(i, body=body, waitsFor=waits_for(branch, pr, body)) if i["key"] == key else i for i in _items()])
        else:
            raise ghreview.Refused(f"unknown draft op {op!r}")
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


# ── address: declare a commit the thread's fix ───────────────────────────

class _Answer:
    """Stands in for a request so one handler can call another and read what it answered."""

    def __init__(self):
        self.code, self.data = 0, {}

    def _send(self, code, body, ctype=None):
        self.code = code
        try:
            self.data = json.loads(body) if body else {}
        except ValueError:
            self.data = {"err": str(body)[:200]}

    def ok(self):
        return self.code == 200 and self.data.get("ok") is not False


def address_prompt(branch, pr, t, note=None):
    """What a Claude session is handed to address one thread: the conversation, the second
    reader's read of it, where it is, and how to land the fix so the viewer can link it."""
    url = thread_url(t)
    out = [f"Address this review comment on PR #{pr['number']} (branch `{branch}`), at `{t['path']}:{t.get('line') or t.get('originalLine') or '?'}`.", ""]
    for c in t.get("comments") or []:
        out.append(f"{c.get('author') or 'someone'} wrote:")
        out += [f"> {ln}" if ln else ">" for ln in (c.get("body") or "").splitlines()]
        out.append("")
    if note:
        out.append(f"The second reader's read: {note.get('verdict') or 'unclear'}.")
        for k, label in (("evidence", "Evidence"), ("elsewhere", "Elsewhere"), ("cause", "Cause")):
            v = note.get(k)
            if v:
                out.append(f"{label}: {v if isinstance(v, str) else json.dumps(v)}")
        out.append("")
    out += [
        "Make the change in this worktree, then commit it as one commit: a subject in Phil's voice (at most 40 characters after `type(scope):`; a follow-up commit reads bare, no prefix), and this trailer as the message's last line:",
        "",
        f"{TRAILER}: {url}",
        "",
        "Don't push and don't reply on GitHub. The viewer links the commit to the thread from that trailer and has already drafted the reply (\"done in <sha>\"), which goes out with Phil's push. If the comment is wrong or needs no change, say so here instead of committing.",
    ]
    return "\n".join(out)


def _launch_claude(branch, prompt):
    """A fresh Claude in the branch's worktree with `prompt` typed into its composer, never sent
    (stack-claude's draft mode) — Phil reads and sends it."""
    env = dict(os.environ, STACK_CLAUDE_DRAFT="1")
    p = subprocess.Popen([os.path.join(ctx.SCRIPTS, "stack-claude"), branch], stdin=subprocess.PIPE, env=env,
                         stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, cwd=ctx.repo_cwd(), start_new_session=True)
    p.stdin.write(prompt.encode())
    p.stdin.close()


@_guarded
def address(req, d):
    """Declare `sha` the thread's fix, in one step: the commit's message gains the thread's
    Addresses trailer through outline's guarded rewrite (same tree, refused if the branch moved),
    and a reply "done in {fix}" is drafted to go into the pending review with the push. `undo`
    takes both back."""
    from . import outline
    branch = d.get("branch") or ""
    if d.get("undo"):
        ans = _Answer()
        outline.undo(ans, json.dumps({"branch": branch}))
        if not ans.ok():
            raise ghreview.Refused(ans.data.get("err") or "couldn't undo the trailer")
        with _FLOCK:
            _save_items([i for i in _items() if not (i["key"] == d["undo"] and i.get("state") in ("draft", None))])
        return _send(req, 200, {"ok": True})
    pr = _pr_for(branch)
    t = next((x for x in pr["threads"] if x["node"] == d.get("thread")), None)
    if not t or not thread_url(t):
        raise ghreview.Refused("that thread isn't on this PR")
    if d.get("claude"):
        note = notes(pr["number"])[0].get(t["node"])
        _launch_claude(branch, address_prompt(branch, pr, t, note))
        item = dict(_new_item(branch, pr, {"kind": "reply", "thread": t["node"], "body": "done in {fix}", "fixFor": thread_url(t)}), send=True)
        with _FLOCK:
            _save_items([*_items(), item])
        return _send(req, 200, {"ok": True, "key": item["key"]})
    sha = d.get("sha") or ""
    msg = ctx.run(["git", "log", "-1", "--format=%s%x1f%b", sha])
    if msg.returncode != 0 or "\x1f" not in msg.stdout:
        raise ghreview.Refused(f"no commit {sha[:7]}")
    subject, body = msg.stdout.split("\x1f", 1)
    ans = _Answer()
    outline.save(ans, json.dumps({"branch": branch, "head": d.get("head") or "",
                                  "edits": [{"sha": sha, "subject": subject.strip(), "body": add_trailer(body.strip(), thread_url(t))}]}))
    if not ans.ok():
        raise ghreview.Refused(ans.data.get("err") or "couldn't add the trailer")
    item = dict(_new_item(branch, pr, {"kind": "reply", "thread": t["node"], "body": "done in {fix}", "fixFor": thread_url(t)}), send=True)
    with _FLOCK:
        _save_items([*_items(), item])
    _send(req, 200, {"ok": True, "key": item["key"], "newTip": ans.data.get("newTip")})
