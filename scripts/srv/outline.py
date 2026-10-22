# srv/outline.py — the words a branch carries, edited as one thing: its description, its
# outline (every own commit's subject + why), and the landing text (PR title + body) that the
# squash-merge turns into main's commit.
#
#   GET  /outline?branch=B        → {branch, parent, head, description, story, ticket, commits,
#                                    pr, draft, reseat, undo}
#   POST /outline                 {branch, head, edits:[{sha, subject, body}], description?,
#                                  prTitle?, prBody?} → {ok, newTip, changed, warnings, reseat}
#   POST /outline-undo            {branch} → restores the last outline save, same reseat path
#   GET  /outline-reseat?id=J     → the background reseat job's status
#
# A save rewrites every changed unpushed commit in ONE pass: a new chain built with commit-tree
# on the identical trees, landed with a single update-ref against the head the editor loaded —
# so a branch another writer moved meanwhile refuses instead of being clobbered, and tree-keyed
# verdicts (gates, review flags) ride along untouched. Descendants are reseated afterwards on a
# background thread the same way stack-reword carries them (commit-tree above the parent's new
# tip), skipping any whose commits a remote already holds. Every save is journaled to
# .git/stack-outline-log.jsonl beside the story log, which is what undo replays.
import json
import os
import re
import subprocess
import threading
import time
import uuid
from urllib.parse import parse_qs

from . import ctx, repostate, sync, watch

_WIP = re.compile(r"^(wip\b|fixup!|squash!|amend!)", re.IGNORECASE)
_PR_KEYS = {"prTitle": "stack-pr-title", "prBody": "stack-pr-body", "packet": "stack-packet", "prLabel": "stack-pr-label"}


def _git(*args):
    return ctx.run(["git", *args])


def _out(*args):
    return _git(*args).stdout.strip()


def _send(req, code, payload):
    req._send(code, json.dumps(payload))


def _refuse(req, code, err, **extra):
    _send(req, code, {"ok": False, "err": err, **extra})


def _fresh():
    """Every mutation starts here: another writer (a Claude session, focus sync) may have moved
    a ref since the cached graph last looked, and the head check is only as good as this read."""
    watch.poke()
    repostate.invalidate()


def _cfg(key):
    return _out("config", key)


def _set_cfg(key, value):
    if value:
        _git("config", key, value)
    else:
        _git("config", "--unset", key)


# ── reading the outline ────────────────────────────────────────────────────

def _base(branch):
    """The commit range's floor, the same one /commits and /node use: the parent, except a
    trunk parent resolves to origin's copy so a stale local main can't count merged work."""
    snap = repostate.snapshot()
    parent = snap.parent(branch)
    if parent == snap.main() and _git("rev-parse", "--verify", "-q", f"origin/{parent}").returncode == 0:
        return parent, f"origin/{parent}"
    return parent, parent


def _carried(branch, base):
    out = set()
    for dep in _git("config", "--get-all", f"branch.{branch}.stack-requires").stdout.split():
        out |= {ln[2:] for ln in _git("cherry", dep, branch, base).stdout.splitlines() if ln.startswith("- ")}
    return out


def own_commits(branch):
    """The branch's own commits oldest first, each with its message, churn, and whether any
    remote already holds it. Two git calls regardless of length."""
    parent, base = _base(branch)
    fmt = "%x1e%H%x1f%P%x1f%s%x1f%b%x1d"
    log = _git("log", "--reverse", "--numstat", f"--format={fmt}", f"{base}..{branch}").stdout
    unpushed = set(_git("rev-list", f"{base}..{branch}", "--not", "--remotes").stdout.split())
    carried = _carried(branch, base)
    rows = []
    for rec in log.split("\x1e"):
        if "\x1d" not in rec:
            continue
        head, _, stat = rec.partition("\x1d")
        sha, parents, subject, body = (head.split("\x1f") + ["", "", "", ""])[:4]
        add = dele = files = 0
        for ln in stat.strip().splitlines():
            cols = ln.split("\t")
            if len(cols) == 3:
                files += 1
                add += int(cols[0]) if cols[0].isdigit() else 0
                dele += int(cols[1]) if cols[1].isdigit() else 0
        merge = len(parents.split()) > 1
        lock = ("on a remote — rewording it would force-push" if sha not in unpushed
                else "a merge commit — reword it by hand" if merge
                else "carried from a fan-in dep — reword it there" if sha in carried else "")
        rows.append({"sha": sha, "short": sha[:10], "subject": subject, "body": body.strip(),
                     "pushed": sha not in unpushed, "merge": merge, "carried": sha in carried,
                     "locked": lock, "files": files, "add": add, "del": dele})
    return parent, base, rows


def opening_subject(branch):
    """The first own commit's subject — what the PR title defaults to."""
    _, _, rows = own_commits(branch)
    mine = [r for r in rows if not r["carried"]]
    return mine[0]["subject"] if mine else ""


def _ticket(branch):
    snap = repostate.snapshot()
    t = snap.branch_key(branch, "ticket")
    if not t and snap.project(branch):
        t = snap.get(f"stack-project.{snap.project(branch)}.ticket")
    return t.lower()


def _story(branch):
    return _cfg(f"branch.{branch}.stack-story") or _cfg(f"stack-branch.{branch}.story")


# ── PR text + drafted body: stale-while-revalidate, never a gh call on the request thread ──

_SWR = {}            # key -> {"at", "sig", "value"}
_SWR_LOCK = threading.Lock()
_SWR_BUSY = set()


def _swr(key, sig, build, ttl=120.0):
    """(value, pending): the cached value when its sig matches and it is fresh; otherwise
    whatever is cached (possibly None) while one background build refreshes it."""
    now = time.monotonic()
    with _SWR_LOCK:
        ent = _SWR.get(key)
        fresh = ent and ent["sig"] == sig and now - ent["at"] < ttl
        if fresh:
            return ent["value"], False
        if key not in _SWR_BUSY:
            _SWR_BUSY.add(key)
            repo = ctx.repo_cwd()

            def run():
                try:
                    ctx.set_repo(repo)
                    value = build()
                    # a failed read (gh down) is retried in ~15s rather than held for the full ttl
                    at = time.monotonic() - (ttl - 15 if value is None else 0)
                    with _SWR_LOCK:
                        _SWR[key] = {"at": at, "sig": sig, "value": value}
                    ctx.bump_pulse()
                finally:
                    _SWR_BUSY.discard(key)
            threading.Thread(target=run, daemon=True).start()
        return (ent["value"] if ent else None), True


def _pr_text(url):
    r = ctx.run(["gh", "pr", "view", url, "--json", "title,body"], timeout=20)
    try:
        d = json.loads(r.stdout or "{}")
    except ValueError:
        return None
    return {"title": d.get("title", ""), "body": d.get("body", "")} if r.returncode == 0 else None


def _pr(branch):
    from . import outbox
    fx = outbox._fixture()   # the sandbox's PR facts, so every packet state renders without gh
    p = (fx if fx is not None else sync._pr_state_map()).get(branch) or {}
    if not p.get("number"):
        return {"exists": False}
    if fx is not None:
        text, pending = {"title": p.get("title", ""), "body": p.get("body", "")}, False
    else:
        text, pending = _swr(("pr", ctx.repo_cwd(), p["url"]), p.get("state"), lambda: _pr_text(p["url"]))
    return {"exists": True, "number": p["number"], "url": p.get("url", ""), "state": p.get("state", ""),
            "draft": bool(p.get("draft")), "title": (text or {}).get("title"),
            "body": (text or {}).get("body"), "pending": pending and text is None}


def _drafted_body(branch):
    from . import packet
    f = packet.facts(branch)
    return packet.rp.render(packet.rp.build(f), f["template"]).strip()


def _draft(branch, rows):
    title = _cfg(f"branch.{branch}.stack-pr-title")
    body = _cfg(f"branch.{branch}.stack-pr-body")
    mine = [r for r in rows if not r["carried"]]
    out = {"title": title or (mine[0]["subject"] if mine else ""), "titleSaved": bool(title),
           "body": body, "bodySaved": bool(body), "derivedBody": None, "bodyPending": False}
    derived, pending = _swr(("pr-body", ctx.repo_cwd(), branch), ctx.model_sig(), lambda: _drafted_body(branch))
    out["derivedBody"], out["bodyPending"] = derived, pending and derived is None
    if not body:
        out["body"] = derived or ""
    return out


def get(req, u):
    branch = (parse_qs(u.query).get("branch", [""]) or [""])[0]
    if not branch:
        return _refuse(req, 400, "no branch")
    if _git("rev-parse", "--verify", "-q", f"refs/heads/{branch}").returncode != 0:
        return _refuse(req, 404, f"no local branch {branch}")
    parent, base, rows = own_commits(branch)
    _send(req, 200, {
        "ok": True, "branch": branch, "parent": parent, "base": base,
        "head": _out("rev-parse", branch),
        "description": _cfg(f"branch.{branch}.description"),
        "story": _story(branch), "ticket": _ticket(branch),
        "commits": rows, "pr": _pr(branch), "draft": _draft(branch, rows),
        "reseat": _latest_job(branch), "undo": _undo_offer(branch),
    })


# ── the journal ────────────────────────────────────────────────────────────

def _journal_path():
    gd = _out("rev-parse", "--path-format=absolute", "--git-common-dir")
    return os.path.join(gd, "stack-outline-log.jsonl") if gd else ""


def _journal(entry):
    path = _journal_path()
    if not path:
        return
    with open(path, "a") as fh:
        fh.write(json.dumps({"ts": int(time.time()), **entry}) + "\n")


def _entries(branch):
    path = _journal_path()
    try:
        with open(path) as fh:
            rows = [json.loads(ln) for ln in fh if ln.strip()]
    except (OSError, ValueError):
        return []
    return [r for r in rows if r.get("branch") == branch]


def _undoable(branch):
    """The newest save on this branch that no later undo has already reversed."""
    stack = []
    for e in _entries(branch):
        if e.get("kind") == "edit":
            stack.append(e)
        elif e.get("kind") == "undo" and stack and stack[-1]["id"] == e.get("undoes"):
            stack.pop()
    return stack[-1] if stack else None


def _undo_offer(branch):
    e = _undoable(branch)
    if not e:
        return None
    moved = e["oldTip"] != e["newTip"]
    if moved and _out("rev-parse", branch) != e["newTip"]:
        return None
    return {"id": e["id"], "ts": e["ts"], "commits": len(e.get("commits", [])),
            "fields": [k for k in ("description", *_PR_KEYS) if k in e]}


# ── rewriting ──────────────────────────────────────────────────────────────

def _signs():
    return _out("config", "--get", "commit.gpgsign") == "true"


def _rebuild(old, parents, message, sign):
    """commit-tree on old's tree + author, onto parents, with message (None = keep old's)."""
    tree = _out("rev-parse", f"{old}^{{tree}}")
    an, ae, ad = _git("log", "-1", "--format=%an%x00%ae%x00%aD", old).stdout.rstrip("\n").split("\x00")
    msg = message if message is not None else _git("log", "-1", "--format=%B", old).stdout
    cmd = ["git", "commit-tree", tree, *[a for p in parents for a in ("-p", p)], *(["-S"] if sign else [])]
    env = {**os.environ, "GIT_AUTHOR_NAME": an, "GIT_AUTHOR_EMAIL": ae, "GIT_AUTHOR_DATE": ad}
    r = subprocess.run(cmd, cwd=ctx.repo_cwd(), input=msg, capture_output=True, text=True, env=env)
    if r.returncode != 0 or not r.stdout.strip():
        raise RuntimeError((r.stderr or "commit-tree failed").strip()[:300])
    return r.stdout.strip()


def _message(subject, body):
    return subject.strip() + (f"\n\n{body.strip()}" if body and body.strip() else "") + "\n"


def _normalize(msg):
    return subprocess.run(["git", "stripspace"], input=msg, capture_output=True, text=True).stdout


def _children():
    """{parent: [children]} from both stack-parent spellings, the target winning."""
    parents = {}
    for pat, pre, suf in ((r"^stack-branch\..*\.parent$", "stack-branch.", ".parent"),
                          (r"^branch\..*\.stack-parent$", "branch.", ".stack-parent")):
        for ln in _git("config", "--get-regexp", pat).stdout.splitlines():
            key, _, val = ln.partition(" ")
            parents[key[len(pre):-len(suf)]] = val.strip()
    out = {}
    for child, parent in parents.items():
        out.setdefault(parent, []).append(child)
    return {p: sorted(cs) for p, cs in out.items()}


def _repoint_base(branch, rewritten):
    for key in (f"branch.{branch}.stack-base", f"stack-branch.{branch}.base"):
        recorded = _cfg(key)
        if recorded in rewritten:
            _git("config", key, rewritten[recorded])


# ── the reseat job ─────────────────────────────────────────────────────────

_JOBS = {}
_LATEST = {}
_JOBS_LOCK = threading.Lock()


def _latest_job(branch):
    with _JOBS_LOCK:
        jid = _LATEST.get((ctx.repo_cwd(), branch))
        job = _JOBS.get(jid)
        if not job or time.time() - job["startedAt"] > 900:
            return None
        return dict(job, results=list(job["results"]))


def _reseat(job, root, old_tip, new_tip, rewritten):
    """Carry every descendant of root from old_tip to new_tip, breadth-first, the way
    stack-reword does: same trees, new parents. A child that left its parent's tip, already
    lives on a remote, or holds a merge is left alone and said so."""
    sign = _signs()
    kids = _children()
    moved = {root: (old_tip, new_tip)}
    queue = list(kids.get(root, []))
    seen = {root}
    while queue:
        child = queue.pop(0)
        if child in seen:
            continue
        seen.add(child)
        parent = (_cfg(f"branch.{child}.stack-parent") or _cfg(f"stack-branch.{child}.parent"))
        if parent not in moved:
            continue
        o, n = moved[parent]
        res = {"branch": child, "parent": parent}
        tip = _out("rev-parse", "--verify", "-q", f"refs/heads/{child}")
        if not tip:
            continue
        if _git("merge-base", "--is-ancestor", o, tip).returncode != 0:
            job["results"].append({**res, "status": "skipped",
                                   "why": f"doesn't sit on {parent}'s tip — restack it"})
            continue
        own = _git("rev-list", "--reverse", f"{o}..{tip}").stdout.split()
        unpushed = set(_git("rev-list", f"{o}..{tip}", "--not", "--remotes").stdout.split())
        if any(c not in unpushed for c in own):
            job["results"].append({**res, "status": "held",
                                   "why": "already on a remote — moving it would need a force-push; restack it by hand"})
            continue
        try:
            nt = n
            for c in own:
                if len(_out("rev-list", "--parents", "-1", c).split()) > 2:
                    raise RuntimeError(f"{c[:10]} is a merge commit")
                nt = rewritten[c] = _rebuild(c, [nt], None, sign)
        except RuntimeError as e:
            job["results"].append({**res, "status": "skipped", "why": str(e)})
            continue
        rewritten[o] = n
        r = _git("update-ref", "-m", "stack-outline: reseat", f"refs/heads/{child}", nt, tip)
        if r.returncode != 0:
            job["results"].append({**res, "status": "skipped", "why": "moved while reseating — left alone"})
            continue
        _repoint_base(child, rewritten)
        moved[child] = (tip, nt)
        job["results"].append({**res, "status": "reseated", "from": tip, "to": nt, "commits": len(own)})
        queue.extend(kids.get(child, []))


def _start_reseat(branch, old_tip, new_tip, rewritten):
    if not _children().get(branch):
        return None
    jid = uuid.uuid4().hex[:12]
    job = {"id": jid, "branch": branch, "state": "running", "results": [],
           "startedAt": time.time(), "finishedAt": None, "err": ""}
    repo = ctx.repo_cwd()
    with _JOBS_LOCK:
        _JOBS[jid] = job
        _LATEST[(repo, branch)] = jid

    def run():
        ctx.set_repo(repo)
        try:
            _fresh()
            _reseat(job, branch, old_tip, new_tip, dict(rewritten))
        except Exception as e:   # the job reports, never dies silently
            job["err"] = str(e)[:300]
        finally:
            job["state"] = "done"
            job["finishedAt"] = time.time()
            repostate.invalidate()
            ctx.bump_pulse()
            ctx.log(f"outline: reseat {jid} under {branch} — "
                    + ", ".join(f"{r['branch']} {r['status']}" for r in job["results"]))
    threading.Thread(target=run, daemon=True).start()
    return jid


def reseat_status(req, u):
    jid = (parse_qs(u.query).get("id", [""]) or [""])[0]
    with _JOBS_LOCK:
        job = _JOBS.get(jid)
        snap = dict(job, results=list(job["results"])) if job else None
    if not snap:
        return _refuse(req, 404, "no such reseat job")
    _send(req, 200, {"ok": True, **snap})


# ── POST /outline ──────────────────────────────────────────────────────────

def _apply_fields(branch, d, entry):
    """Description + landing text: git config, journaled with their before-values."""
    if d.get("description") is not None:
        new = " ".join(str(d["description"]).split())
        before = _cfg(f"branch.{branch}.description")
        if new != before:
            _set_cfg(f"branch.{branch}.description", new)
            entry["description"] = {"before": before, "after": new}
    for field, key in _PR_KEYS.items():
        if d.get(field) is None:
            continue
        new = _packet_value(d[field]) if field == "packet" else str(d[field]).strip()
        before = _cfg(f"branch.{branch}.{key}")
        if new != before:
            _set_cfg(f"branch.{branch}.{key}", new)
            entry[field] = {"before": before, "after": new}


def _packet_value(v):
    """The packet's hand parts as compact JSON — only what was written by hand; "" clears it."""
    try:
        d = json.loads(v) if isinstance(v, str) else v
    except ValueError:
        return ""
    if not isinstance(d, dict):
        return ""
    keep = {}
    if str(d.get("lead") or "").strip():
        keep["lead"] = str(d["lead"]).strip()
    for k in ("intent", "not", "read"):
        if isinstance(d.get(k), list):
            keep[k] = [" ".join(str(x).split()) for x in d[k] if str(x).strip()]
    return json.dumps(keep, ensure_ascii=False, separators=(",", ":")) if keep else ""


def save(req, raw):
    _fresh()
    d = json.loads(raw or "{}")
    branch = (d.get("branch") or "").strip()
    edits = d.get("edits") or []
    if not branch:
        return _refuse(req, 400, "no branch")
    if branch in ("main", "master"):
        return _refuse(req, 400, "trunk has no outline to edit")
    tip = _out("rev-parse", "--verify", "-q", f"refs/heads/{branch}")
    if not tip:
        return _refuse(req, 404, f"no local branch {branch}")

    _, _, rows = own_commits(branch)
    by_sha = {r["sha"]: r for r in rows}
    changes = {}
    for e in edits:
        sha = (e.get("sha") or "").strip()
        row = by_sha.get(sha) or next((r for r in rows if sha and r["sha"].startswith(sha)), None)
        if not row:
            return _refuse(req, 409, f"{sha[:10]} is no longer one of {branch}'s commits — the branch moved; reload",
                           moved=True)
        subject = (e.get("subject") or "").strip()
        if not subject or "\n" in subject:
            return _refuse(req, 400, f"{row['short']}: the subject must be one non-empty line")
        if _WIP.match(subject):
            return _refuse(req, 400, f"{row['short']}: “{subject}” is a placeholder — write the real subject")
        msg = _message(subject, e.get("body") or "")
        old = _normalize(_message(row["subject"], row["body"]))
        if _normalize(msg) == old:
            continue
        if row["locked"]:
            return _refuse(req, 409, f"{row['short']} is {row['locked']}")
        changes[row["sha"]] = msg

    if changes and d.get("head") and d["head"] != tip:
        return _refuse(req, 409, f"{branch} moved since the editor loaded it — reload to see the new commits",
                       moved=True, head=tip)
    for sha, exp in (d.get("expect") or {}).items():
        if sha in by_sha and by_sha[sha]["subject"] != exp:
            return _refuse(req, 409, f"{sha[:10]} changed under you — reload", moved=True, head=tip)

    entry = {"id": uuid.uuid4().hex[:12], "kind": "edit", "branch": branch, "oldTip": tip, "newTip": tip}
    warnings, new_tip, rewritten = [], tip, {}
    if changes:
        order = [r["sha"] for r in rows]
        first = min(order.index(s) for s in changes)
        sign = _signs()
        try:
            parents = _out("log", "-1", "--format=%P", order[first]).split()
            for sha in order[first:]:
                if sha != order[first] and len(_out("rev-list", "--parents", "-1", sha).split()) > 2:
                    raise RuntimeError(f"{sha[:10]} above the edit is a merge commit — reword by hand")
                new = _rebuild(sha, parents if sha == order[first] else [new_tip], changes.get(sha), sign)
                rewritten[sha] = new
                new_tip = new
        except RuntimeError as e:
            return _refuse(req, 500, str(e))
        r = _git("update-ref", "-m", f"stack-outline: reword {len(changes)}", f"refs/heads/{branch}", new_tip, tip)
        if r.returncode != 0:
            return _refuse(req, 409, f"{branch} moved while saving — nothing was written; reload", moved=True)
        entry["newTip"] = new_tip
        entry["commits"] = [{"old": s, "new": rewritten[s], "before": _git("log", "-1", "--format=%B", s).stdout,
                             "after": changes[s]} for s in changes]
    _apply_fields(branch, d, entry)
    if entry.get("commits") or any(k in entry for k in ("description", *_PR_KEYS)):
        _journal(entry)
    repostate.invalidate()
    job = _start_reseat(branch, tip, new_tip, rewritten) if changes else None
    _send(req, 200, {"ok": True, "newTip": new_tip, "oldTip": tip, "changed": len(changes),
                     "fields": [k for k in ("description", *_PR_KEYS) if k in entry],
                     "warnings": warnings, "reseat": job, "journal": entry["id"]})


def undo(req, raw):
    _fresh()
    d = json.loads(raw or "{}")
    branch = (d.get("branch") or "").strip()
    if not branch:
        return _refuse(req, 400, "no branch")
    tip = _out("rev-parse", "--verify", "-q", f"refs/heads/{branch}")
    if not tip:
        return _refuse(req, 404, f"no local branch {branch}")
    e = _undoable(branch)
    if not e:
        return _refuse(req, 409, "nothing to undo on this branch")
    moved = e["oldTip"] != e["newTip"]
    if moved:
        if tip != e["newTip"]:
            return _refuse(req, 409, f"{branch} has moved since that save — undo would discard newer work", moved=True)
        mine = [c["new"] for c in e.get("commits", [])]
        unpushed = set(_git("rev-list", tip, "--not", "--remotes").stdout.split())
        if any(c not in unpushed for c in mine):
            return _refuse(req, 409, "those commits have been pushed since — undo would force-push")
        if _git("cat-file", "-e", f"{e['oldTip']}^{{commit}}").returncode != 0:
            return _refuse(req, 410, "the previous commits are gone from the object store")
        r = _git("update-ref", "-m", "stack-outline: undo", f"refs/heads/{branch}", e["oldTip"], tip)
        if r.returncode != 0:
            return _refuse(req, 409, f"{branch} moved while undoing — reload", moved=True)
    restored = []
    for field, key in (("description", "description"), *_PR_KEYS.items()):
        if field in e:
            full = f"branch.{branch}.{key}"
            if _cfg(full) == e[field]["after"]:
                _set_cfg(full, e[field]["before"])
                restored.append(field)
    _journal({"id": uuid.uuid4().hex[:12], "kind": "undo", "undoes": e["id"], "branch": branch,
              "oldTip": tip, "newTip": e["oldTip"] if moved else tip, "fields": restored})
    repostate.invalidate()
    rewritten = {c["new"]: c["old"] for c in e.get("commits", [])}
    job = _start_reseat(branch, tip, e["oldTip"], rewritten) if moved else None
    _send(req, 200, {"ok": True, "newTip": e["oldTip"] if moved else tip, "restored": restored,
                     "commits": len(e.get("commits", [])), "reseat": job})
