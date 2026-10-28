# srv/push.py — the prepare-to-push gate + push endpoints (the node header's sync strip).
#
#   POST /gates          {branch}  → run stack-gates in the branch's worktree; JSON verdict.
#                                    {detach:true} spawns it with a progress journal instead.
#   GET  /gates-progress ?branch=  → live per-gate journal of a detached /gates run
#   POST /push-origin    {branch}  → THE shared-history door. Human finger only (viewer button);
#                                    Claude never calls this. Every guard re-verified server-side.
import json
import os
import re
import subprocess
import hashlib
import tempfile
import time
import threading
from urllib.parse import quote, parse_qs

from . import ctx, stage, sync, repostate, shellout, stackcfg, gate_queue, runs


def delta_tests(req, raw):
    # Run the tests RELATED to the branch's delta (stack-delta-tests: each changed X.ts's
    # co-located X.test.ts, plus changed *.test.ts). stack-delta-tests reads the delta from
    # HEAD, so it runs in the worktree HOLDING the branch — the sync strip no longer moves
    # the main checkout — or in its stack-open scratch tree (detached at the tip).
    d = json.loads(raw or "{}")
    branch = d.get("branch", "")
    wt = _branch_worktree(branch)
    if not wt:
        r0 = ctx.run([os.path.join(ctx.SCRIPTS, "stack-open"), "--path", branch])
        wt = (r0.stdout or "").strip() if r0.returncode == 0 else ""
    if not wt:
        return req._send(200, json.dumps({
            "ok": True, "ran": False, "noTests": False,
            "summary": f"no worktree holds {branch} and none could be materialized — advisory tests skipped"}))
    r = subprocess.run([os.path.join(ctx.SCRIPTS, "stack-delta-tests"), "--branch", branch],
                       cwd=wt, capture_output=True, text=True)
    out = (r.stdout or "") + (r.stderr or "")

    def _n(label):
        # node:test summary lines are "<symbol> <label> <n>" — `ℹ ` under tsx, `# ` under plain
        # node. (`ℹ` is isalnum/\w, so a \W-class won't consume it — match one leading token.)
        m = re.search(rf"^\S* {label} (\d+)\s*$", out, re.M)
        return int(m.group(1)) if m else None

    total = _n("tests")
    tail = "\n".join(l for l in out.splitlines() if l.strip())[-2000:]
    req._send(200, json.dumps({
        "ok": r.returncode == 0,
        "ran": total is not None,                    # tsx printed a summary ⇒ tests executed
        "noTests": ("no related tests" in out or "nothing to run" in out),
        "passed": _n("pass"),
        "failed": _n("fail"),
        "total": total,
        "summary": tail,
    }))


# A detached gates run is a run (srv/runs.py, kind "gates", one per repo + branch, the latest):
# stack-gates writes its progress journal into the run's directory, each gate's output beside it,
# so any server image — a restarted one included — reads the same run.
_GATE_LOCK = threading.RLock()
_REPO_IDS = {}
GATE_RUNS_KEPT = 14 * 86_400


def _repo_id():
    # stable per REPO (not per worktree): key off the git common dir, cached per request-cwd.
    cwd = ctx.repo_cwd()
    rid = _REPO_IDS.get(cwd)
    if rid is None:
        gd = ctx.run(["git", "rev-parse", "--path-format=absolute", "--git-common-dir"]).stdout.strip()
        rid = hashlib.sha1((gd or cwd).encode()).hexdigest()[:8]
        _REPO_IDS[cwd] = rid
    return rid


def _gate_key(branch):
    return f"{_repo_id()}/{branch}"


def gate_run(branch):
    """The branch's latest gates run, live or finished — None when it was never gated here."""
    return runs.find("gates", _gate_key(branch)) if branch else None


_LISTED = {"at": 0.0, "repo": "", "runs": []}


def gate_runs():
    """{branch: its latest gates run} for this repo — the directory listing is re-read every 2s."""
    rid = _repo_id()
    if time.monotonic() - _LISTED["at"] > 2 or _LISTED["repo"] != rid:
        _LISTED.update(at=time.monotonic(), repo=rid, runs=[r for r in runs.every("gates") if r.meta.get("repo") == rid])
    return {r.meta["branch"]: r for r in _LISTED["runs"]}


def journal(run):
    return run.path(run.meta["journal"])


def gate_events(run):
    return _journal_events(journal(run))


def gate_result(run):
    """The run's verdict event, once it has one."""
    return next((e for e in gate_events(run) if e.get("event") == "result"), None)


def _tail(path, n):
    try:
        with open(path, "rb") as f:
            f.seek(0, 2)
            f.seek(max(0, f.tell() - 16384))
            text = f.read().decode(errors="replace")
    except OSError:
        return []
    # a progress bar's carriage returns: keep each line's last frame
    return [ln.rsplit("\r", 1)[-1] for ln in text.splitlines() if ln.strip()][-n:]


def _journal_events(path):
    events = []
    try:
        with open(path) as f:
            for ln in f:
                try:
                    events.append(json.loads(ln))
                except ValueError:
                    pass
    except OSError:
        pass
    return events


def gates(req, raw):
    d = json.loads(raw or "{}")
    branch = d.get("branch", "")
    # A tree that already passed answers green instantly — the verdict is tree-keyed, so
    # re-running proves nothing new. force:true opts out (a suspected-flaky green).
    tree = _tree(branch) if branch else ""
    if not d.get("force") and tree and _green_tree(branch) == tree:
        return req._send(200, json.dumps({"ok": True, "cached": True, "gates": []}))
    # --fix is OPT-IN (fix:true): a red gate with a remediation (fresh → rebase, format →
    # oxfmt) gets one auto-fix attempt before the verdict. Default false since 2026-08-19 —
    # a bare gates check used to rebase stale branches as a side effect of observing, and
    # observation must never mutate. The sync strip passes fix:false explicitly anyway.
    # skip: Phil's call that a gate doesn't apply to this tree — it reports as a waiver, never silently
    skip = [g for g in d.get("skip") or [] if isinstance(g, str) and re.fullmatch(r"[a-z][a-z0-9-]*", g)]
    cmd = _gates_cmd(branch, fix=d.get("fix", False), tree=tree, skip=skip)
    # detach: spawn with a progress journal and return at once — the strip tails
    # GET /gates-progress for live per-gate position instead of freezing for a tsc.
    if d.get("detach"):
        old = gate_run(branch)
        if old and old.meta.get("tree") == tree and old.alive():
            gate_queue.promote(_queue_file(old))
            return req._send(200, json.dumps({"ok": True, "started": True, "already": True}))
        if old and old.meta.get("tree") == _tree(branch):
            # an orphaned run finished while no server was watching — harvest its verdict
            # instead of re-paying the typecheck for the same tree
            result = gate_result(old)
            if result and result.get("ok"):
                _record_green(branch, old.meta["tree"], result.get("gates", []))
                repostate.invalidate()   # the verdict landed outside a POST: unstale the snapshot now
                return req._send(200, json.dumps({"ok": True, "cached": True, "gates": result.get("gates", [])}))
        _spawn_gates(branch, fix=d.get("fix", False), skip=skip)
        return req._send(200, json.dumps({"ok": True, "started": True}))
    # The verdict the push door hangs on: validated, never passed through. It used to ship
    # whatever stack-gates printed to the browser as HTTP 200, and decide green inside a bare
    # `except: pass` — so a line of noise ahead of the JSON silently left push locked.
    verdict, err = shellout.json_out(cmd[0], cmd[1:], require=("ok",))
    if err:
        return req._send(200, json.dumps({**err, "gates": []}))
    if verdict.get("ok"):
        _record_green(branch, tree, verdict.get("gates", []))
        repostate.invalidate()   # the verdict landed outside a POST: unstale the snapshot now
    req._send(200, json.dumps(verdict))


# One gates run at a time, machine-wide: each run is 4-5 full tsc programs at 2-3 GB apiece,
# and four overlapping runs (2026-09-22, 09:26) swapped the machine for 37 minutes each where
# one alone takes ~40s. The priority queue shares tsc-turn's slot lock, so donor refreshes
# and surviving older gate runs stay serialized with interactive and background checks.
GATES_TURN_DIR = os.path.join(tempfile.gettempdir(), "stack-gates-turn")


def _queue_file(run):
    # stack-gates-turn names its queue request after the progress journal's basename
    return os.path.join(GATES_TURN_DIR, run.meta["journal"] + ".queue.json")


def _gates_cmd(branch, fix=False, background=False, tree=None, skip=()):
    cmd = [os.path.join(ctx.SCRIPTS, "stack-gates-turn"),
           "--queue", GATES_TURN_DIR, "--branch", branch,
           "--tree", _tree(branch) if tree is None else tree,
           "--priority", "background" if background else "interactive", "--",
           os.path.join(ctx.SCRIPTS, "stack-gates"), "--branch", branch]
    if fix:
        cmd.append("--fix")
    for g in skip:
        cmd += ["--skip", g]
    return cmd


def _spawn_gates(branch, fix=False, background=False, skip=()):
    with _GATE_LOCK:
        tree = _tree(branch)
        old = gate_run(branch)
        if old and old.meta.get("tree") == tree and old.alive():
            if not background:
                gate_queue.promote(_queue_file(old))
            return old
        cmd = _gates_cmd(branch, fix=fix, background=background, tree=tree, skip=skip)
        key = _gate_key(branch)
        # unique per run: the gate queue keys its slot request by this name, machine-wide
        name = f"gates-{_repo_id()}-{quote(branch, safe='')}-{time.time_ns()}.jsonl"
        path = os.path.join(runs.dir_of("gates", key), name)
        try:
            run = runs.start("gates", key, cmd + ["--progress", path], cwd=ctx.repo_cwd(),
                             meta={"repo": _repo_id(), "branch": branch, "tree": tree, "journal": name},
                             seed={name: json.dumps({"event": "queued", "ts": time.time()}) + "\n"})
        except runs.Busy:   # a live run for an older tree: it finishes as an obsolete verdict on its own
            return gate_run(branch)
        _LISTED["at"] = 0.0
        runs.prune("gates", GATE_RUNS_KEPT)
        return run


def gates_progress(req, u):
    qs = parse_qs(u.query)
    branch = (qs.get("branch") or [""])[0]
    run = gate_run(branch)
    if not run:
        return req._send(200, json.dumps({"running": False, "err": "no gates run for this branch"}))
    events = gate_events(run)
    result = next((e for e in events if e.get("event") == "result"), None)
    if result and result.get("ok"):
        # green is recorded against the TREE the run was spawned on — a message-only reword
        # while the gates ran keeps the same tree, so the verdict carries; any content change
        # (rebase, new commit) makes a new tree and the door stays locked
        _record_green(branch, run.meta["tree"], result.get("gates", []))
        repostate.invalidate()   # the verdict landed outside a POST: unstale the snapshot now
    running = run.alive()
    out = {"running": running, "elapsed": round(time.time() - run.started, 1), "events": events}
    # a gate's output so far: the one running, or ?gate= for any gate the run started
    want = (qs.get("gate") or [""])[0]
    done = {e.get("gate") for e in events if e.get("event") == "done"}
    starts = [e for e in events if e.get("event") == "start" and e.get("log")]
    pick = next((e for e in starts if e.get("gate") == want), None) if want else \
        next((e for e in reversed(starts) if e.get("gate") not in done), None)
    if pick and pick["log"].startswith(journal(run) + "."):
        out["tail"] = {"gate": pick["gate"], "lines": _tail(pick["log"], 40)}
    if result:
        out["result"] = {"ok": result.get("ok"), "gates": result.get("gates", []), "note": result.get("note")}
    elif not running:
        out["dead"] = True
    return req._send(200, json.dumps(out))


# ── origin push — the shared-history door ────────────────────────────────────
# Design + boundaries: ~/daily-log/2026-07-02-deprecate-gh-desktop/design.md.
# Phil's rules: FF-only, never force; a FIRST push is exactly ONE commit with a voiced
# subject + real body (it becomes the PR); follow-ups onto an open PR push as they are —
# each additive commit is a review round the reviewer reads as "changes since" — so long
# as every subject is voiced; gates green for the exact tree pushed; the app never
# authors PRs (at most a plain github.com link). Claude never calls /push-origin.

# Gates-green lives in git config (stack-branch.<b>.gates-green-tree), server-recorded and
# never client-claimed. Keyed by TREE sha, not commit: the gates read file contents only, so
# a message reword must not relock push — the tip-sha key stranded green on rewords
# (2026-07-12). Config, not process memory, so a server bounce doesn't relock push either.
def _green_tree(branch):
    return repostate.snapshot().branch_key(branch, "gates-green-tree")


def _record_green(branch, tree, gates=()):
    stackcfg.set_key(branch, "gates-green-tree", tree)
    # A green earned with a WAIVED gate (stack-gates marks it advisory — unsatisfiable, not
    # unmet) must say so at the door, or the waiver is a silent bypass. Tree-keyed like the
    # verdict it qualifies, so the next edit retires it with the green.
    warns = [g.get("warn", "") for g in (gates or ()) if g.get("advisory")]
    stackcfg.unset_all(branch, "gates-waived")
    for w in warns:
        if w:
            stackcfg.add_key(branch, "gates-waived", w)


_WIP_SUBJECT = re.compile(r"^(wip\b|fixup!|squash!|amend!)", re.IGNORECASE)


def _tip(branch):
    return ctx.run(["git", "rev-parse", branch]).stdout.strip()


def _tree(rev):
    return ctx.run(["git", "rev-parse", f"{rev}^{{tree}}"]).stdout.strip()


def _review_flags(branch):
    """push-ready's unapplied review findings (stack-branch.<b>.review-flag, multivar), valid
    only for the tree they were written against (review-flags-tree — same staleness contract
    as gates-green-tree). Stale/absent → None (the UI hides); an EMPTY fresh list is a state:
    reviewed-clean."""
    snap = repostate.snapshot()
    tree = snap.branch_key(branch, "review-flags-tree")
    if not tree or tree != snap.tree(branch):
        return None
    return {"flags": [l.strip() for l in snap.branch_key_all(branch, "review-flag") if l.strip()]}


def _todo_debt(branch, tip, scan=True):
    """What the pre-push TODO guard would say about this branch — asked of the guard
    itself rather than reimplemented, so the door and the hook can never disagree about
    what blocks. Without this the guard only speaks after a failed push, as a truncated
    one-line stderr (2026-09-21, #10564: a reviewer-requested `TODO: Fix in LOO-5922`).

    {"blocked": [<file:line:text>], "acks": [<ticket — why>]}; empty `blocked` means the
    push would clear, including on a repo the guard doesn't guard at all. The acks are read
    either way — with nothing outgoing there is nothing to block, but the branch's standing
    declaration is still what the door should show."""
    snap = repostate.snapshot()
    acks = [a.strip() for a in snap.branch_key_all(branch, "todo-ack") if a.strip()]
    guard = os.path.join(ctx.SCRIPTS, "prepush-todo-guard")
    url = ctx.run(["git", "remote", "get-url", "origin"]).stdout.strip() if scan else ""
    if not scan or not url or not os.access(guard, os.X_OK):
        return {"blocked": [], "acks": acks}
    r = subprocess.run(
        [guard, "origin", url], cwd=ctx.repo_cwd(), capture_output=True, text=True,
        env={**os.environ, "PUSH_SHA": tip, "PUSH_REF": f"refs/heads/{branch}", "TODO_GUARD": "1"},
    )
    if r.returncode == 0:
        return {"blocked": [], "acks": acks}
    return {"blocked": [l.strip() for l in (r.stdout or "").splitlines()
                        if re.match(r"^\s+\S+:\d+:", l)],
            "acks": acks}


def _pr_base(branch):
    """The compare form's base: the nearest stack ancestor with an OPEN PR on origin, else
    main. A stacked child targets its parent's PR so the review diff stays that branch's own
    work; GitHub retargets the child to main itself when the parent PR merges."""
    snap = repostate.snapshot()
    seen = {branch}
    b = branch
    while True:
        parent = snap.branch_key(b, "parent")
        if not parent or parent in ("main", "master") or parent in seen:
            return "main"
        if snap.published(parent) and snap.remote(parent):
            return parent
        seen.add(parent)
        b = parent


def landing_title(branch):
    """The PR title the squash-merge lands on main: the drafted branch.<b>.stack-pr-title,
    else the branch's opening commit subject."""
    saved = ctx.run(["git", "config", f"branch.{branch}.stack-pr-title"]).stdout.strip()
    if saved:
        return saved
    from . import outline
    return outline.opening_subject(branch)


def landing_body(branch):
    """A hand-written branch.<b>.stack-pr-body verbatim, else the drafted body (srv/packet.py
    drafted): a short why in Phil's voice above the repo's PR template, or the full packet for a
    forest that opts in."""
    from . import packet
    return packet.body(branch)


def compare_url(branch, base=None):
    """github.com compare link for the branch, opened straight to the 'Open a pull
    request' form (?expand=1) with the landing title, body and review label prefilled, against base
    (default _pr_base: the nearest stacked ancestor with an open PR, else main). Authoring
    still happens on the website — this only opens the form; it never calls gh pr create."""
    url = repostate.snapshot().get("remote.origin.url")
    m = re.search(r"[:/]([^/:]+/[^/]+?)(?:\.git)?$", url)
    if not m:
        return ""
    from . import packet
    title, body = landing_title(branch), landing_body(branch)
    return (f"https://github.com/{m.group(1)}/compare/{base or _pr_base(branch)}...{branch}?expand=1"
            + (f"&title={quote(title, safe='')}" if title else "")
            + (f"&body={quote(body, safe='')}" if body else "")
            + (f"&labels={packet.rp.LABEL}" if packet.label_on(branch) else ""))


def _origin_web(branch):
    return compare_url(branch)


def _open_pr_url(branch):
    """URL of an OPEN PR whose head is this branch — checked origin then the fork
    (Phil's PRs live on origin; the fork is the automation surface). Empty if none.
    Called ONLY at push time (never in the preview poll), so its gh calls stay rare:
    once a PR exists, a re-push jumps to it instead of the compare-and-create form."""
    for remote in ("origin", "phil-loops"):
        try:
            url = ctx.run(["git", "remote", "get-url", remote]).stdout.strip()
            m = re.search(r"[:/]([^/:]+/[^/]+?)(?:\.git)?$", url)
            if not m:
                continue
            out = ctx.run(["gh", "pr", "list", "-R", m.group(1), "--head", branch,
                           "--state", "open", "--json", "url", "--limit", "1"]).stdout
            arr = json.loads(out or "[]")
            if arr:
                return arr[0].get("url", "")
        except Exception:
            pass
    return ""


def _open_web(url):
    """Hand the compare view to the local default browser (`open`). Only ever reached
    via Phil's push-origin click — the tab popping is the point, not automation — so
    this stays a browser hand-off, never a `gh pr create`. Best-effort: a missing
    `open` (non-mac) just leaves the frontend link as the fallback."""
    if not url:
        return False
    try:
        ctx.fire(["open", url])
        return True
    except Exception:
        return False


def _is_restack(branch):
    """True when local is origin/<branch> restacked onto a newer origin/main: the merge-base
    with main strictly advanced AND every pushed commit rides patch-equivalent in local
    (git cherry survives context drift a rebase introduces). This state is ADOPTED, never
    rebuilt — the additive vehicle re-roots the new-base tree onto the stale pushed head,
    manufacturing imports of files that only exist on new main (the phantom-TS2307 flatten,
    2026-08-12). Origin catches up via prep's catch-up merge carrier — additive, never force."""
    snap = repostate.snapshot()
    mb_local = snap.merge_base(branch, "origin/main")
    mb_remote = snap.merge_base(f"origin/{branch}", "origin/main")
    if not mb_local or not mb_remote or mb_local == mb_remote:
        return False
    if not snap.is_ancestor(mb_remote, mb_local):
        return False
    cherry = [l for l in ctx.run(["git", "cherry", branch, f"origin/{branch}"]).stdout.splitlines() if l.strip()]
    if bool(cherry) and all(l.startswith("-") for l in cherry):
        return True
    # a sealed adoption: prep collapsed the restack to one commit, so per-commit patch-ids
    # no longer match origin's — the stamp remembers which origin head the seal superseded,
    # and goes inert the moment origin moves (force-push lands, or someone else pushes)
    seen = snap.branch_key(branch, "restack-supersedes")
    return bool(seen) and seen == snap.remote(branch)


def _chain_break(branch):
    """First stack ancestor whose ORIGIN copy is missing from this branch's history —
    the signature of a rebase that crossed a publish boundary (2026-08-23:
    schema/drop-download-fk carried rewritten twins of its PR'd parent). Pushing then
    makes the child's PR diff vs that parent show the parent's replayed commits plus
    main drift; no FF-only push sequence can clean it up after the fact. Returns the
    offending ancestor name, or ""."""
    snap = repostate.snapshot()
    seen, cur = set(), branch
    while cur and cur not in seen and len(seen) < 30:
        seen.add(cur)
        p = snap.branch_key(cur, "parent")
        if not p or p in ("main", "master"):
            return ""
        if snap.remote(p) and not snap.is_ancestor(f"origin/{p}", branch):
            return p
        cur = p
    return ""


def _origin_verdict(branch):
    """Every /push-origin guard, recomputed from git — shared by the read-only
    preview (drives the crossing view + wards + arming) and the push itself
    (never trusts the client's copy of this verdict). The preview renders the
    whole threshold: what came before (the outgoing commits), what main has
    done since the fork, and the wards holding the door."""
    snap = repostate.snapshot()
    if not branch or not snap.exists(branch):
        return None
    hard = []   # refusals outside the normal ward path
    if branch in ("main", "master"):
        hard.append("refusing to push trunk from here")
    has_remote = bool(snap.remote(branch))
    ff = True
    if has_remote:
        ff = snap.is_ancestor(f"origin/{branch}", branch)
    # published (cached open-PR set, no per-poll gh call): with outgoing==0 it splits the
    # dead push button into 'view PR ↗' (has one) vs 'open PR ↗' (pushed, none yet); with
    # outgoing>1 it only changes the label — follow-ups onto an open PR are review rounds.
    published = snap.published(branch)
    followup = has_remote and published
    # outgoing = commits origin doesn't have. On a first push, --not --remotes=origin keeps a
    # stacked branch's parent commits (already on origin via the parent) out of the count.
    # --first-parent: a catch-up merge's mainline commits arrive via the merge edge — they are
    # not this branch's outgoing work and must not trip the seal (which would flatten the merge).
    range_args = [f"origin/{branch}..{branch}"] if has_remote else [branch, "--not", "--remotes=origin"]
    log = ctx.run(["git", "log", "--first-parent", "--format=%H\x1f%s\x1f%ad\x1f%at", "--date=format:%b %e", *range_args]).stdout
    outgoing = []
    for rec in log.splitlines():
        parts = rec.split("\x1f")
        if len(parts) == 4:
            outgoing.append({"sha": parts[0], "subject": parts[1], "date": parts[2], "at": int(parts[3])})
    age_days = max(0, int((time.time() - outgoing[-1]["at"]) / 86400)) if outgoing else 0

    # the other side of the crossing: how far shared history moved since this work forked
    fork = snap.merge_base(branch, "origin/main")
    fork_date = ctx.run(["git", "log", "-1", "--format=%ad", "--date=format:%b %e", fork]).stdout.strip() if fork else ""
    main_since = snap.count(f"{fork}..origin/main") if fork else 0
    deploy_critical = sync._deploy_critical(branch)

    # what origin receives: per-file churn over the whole outgoing range (numstat lines
    # are "add<TAB>del<TAB>path"; binary files report "-"). Base = parent of the oldest
    # outgoing commit, which is right for first pushes and re-pushes alike.
    files = []
    if outgoing:
        numstat = ctx.run(["git", "diff", "--numstat", f"{outgoing[-1]['sha']}~1..{branch}"])
        for ln in (numstat.stdout or "").splitlines():
            p = ln.split("\t")
            if len(p) == 3:
                files.append({
                    "path": p[2],
                    "add": int(p[0]) if p[0].isdigit() else 0,
                    "del": int(p[1]) if p[1].isdigit() else 0,
                })

    # per-commit facts for the manifest (what each outgoing commit carries) and the wards
    for c in outgoing:
        parents = ctx.run(["git", "log", "-1", "--format=%P", c["sha"]]).stdout.split()
        c["merge"] = len(parents) > 1
        c["voiced"] = not _WIP_SUBJECT.match(c["subject"])
        stat = ctx.run(["git", "diff", "--shortstat", f"{c['sha']}^1", c["sha"]]).stdout if parents else ""
        for key, pat in (("files", r"(\d+) files? changed"), ("add", r"(\d+) insertion"), ("del", r"(\d+) deletion")):
            m = re.search(pat, stat)
            c[key] = int(m.group(1)) if m else 0

    commit = None
    voiced = said_why = not_merge = catchup = False
    if outgoing:
        # the tip carries the body the reviewer reads first; the oldest outgoing commit is the
        # only place a catch-up merge can sit (its first parent must be origin's head)
        sha = outgoing[0]["sha"]
        subject = outgoing[0]["subject"]
        body = ctx.run(["git", "log", "-1", "--format=%b", sha]).stdout.strip()
        voiced = all(c["voiced"] for c in outgoing)
        said_why = bool(re.sub(r"^X-WIP:.*$", "", body, flags=re.IGNORECASE | re.MULTILINE).strip())
        parents = ctx.run(["git", "log", "-1", "--format=%P", outgoing[-1]["sha"]]).stdout.split()
        not_merge = not any(c["merge"] for c in outgoing)
        # catch-up merge — GitHub's own "Update branch" shape, the one additive way a stale-fork
        # PR gets its review diff back to the branch's own work: first parent is origin's PR
        # head, second parent sits on the PR's base — origin/main, or the stack parent for a
        # stacked child. Anything else stays refused.
        bases = ["origin/main"]
        sp = snap.branch_key(branch, "parent")
        if sp and sp not in ("main", "master") and snap.remote(sp):
            bases.append(f"origin/{sp}")
        catchup = (len(parents) == 2 and has_remote
                   and parents[0] == snap.remote(branch)
                   and any(snap.is_ancestor(parents[1], b) for b in bases)
                   and not any(c["merge"] for c in outgoing[:-1]))
        if len(outgoing) == 1:
            commit = {"sha": sha, "subject": subject, "body": body}
    n_out = len(outgoing)
    has_outgoing = n_out >= 1
    wip = [c for c in outgoing if not c["voiced"]]
    tip = snap.local(branch)
    gates_green = _green_tree(branch) == snap.tree(tip)
    # Waivers recorded alongside the green (a gate that was unsatisfiable, not unmet). Shown
    # at the door so the green says what it cost; retired with the green when the tree moves.
    gates_waived = snap.branch_key_all(branch, "gates-waived") if gates_green else []
    todo = _todo_debt(branch, tip, scan=bool(outgoing))
    chain_broken = _chain_break(branch)

    def ward(k, label, ok, why, advisory=False):
        return {"k": k, "label": label, "ok": bool(ok), "why": "" if ok else why, "advisory": advisory}
    wards = [
        # Any number of deliberate commits may go out (2026-09-24: a deps refactor + the fix
        # it enables, kept apart for the reviewer); the shape ward now only refuses stray
        # merges. Placeholders are the voiced ward's business, and prep still seals those.
        ward("one", "one commit" if n_out == 1
             else f"{n_out} follow-up commits" if followup else f"{n_out} commits",
             has_outgoing and (not_merge or catchup),
             "nothing to push — origin already has this" if not outgoing
             else "outgoing includes a merge that isn't a catch-up of this branch's base"),
        ward("voiced", "voiced subjects" if n_out > 1 else "voiced subject", voiced and has_outgoing,
             "" if not has_outgoing
             else f"{len(wip)} of {n_out} subjects are WIP/fixup placeholders — prep seals them into one voiced commit" if n_out > 1
             else "subject is a WIP/fixup placeholder — prep writes a voiced one"),
        ward("why", "says why", said_why and has_outgoing,
             "" if not has_outgoing else "no commit body on the tip — optional; add a why if it helps a reviewer", advisory=True),
        ward("purpose", "purpose set",
             bool(snap.description(branch)),
             "no branch description — a forest member without a purpose is an unfinished operation", advisory=True),
        ward("ff", "fast-forward", ff,
             "" if ff else
             "origin's copy has no PR — ⚑ replace it with your local history (force-with-lease)"
             if has_remote and not published else
             "restacked onto newer main — prep folds it into a catch-up merge of origin's head (plain push)"
             if has_remote and _is_restack(branch) else
             "diverged from origin — reconcile first; shared history is never overwritten"),
        ward("chain", "stacked on origin history", not chain_broken,
             f"history diverged from origin/{chain_broken} — its PR won't stack clean; "
             f"reset the chain onto origin's copy and replay (restack conforms it)"),
        # FF-additive to a published head is exempt (mirrors the gates' fresh gate,
        # d051e01): the branch must sit on the PR tip to fast-forward, so it can never
        # "rebase forward" without rewriting shared history.
        ward("watch", "deploy watch clear", not deploy_critical or (has_remote and ff and bool(outgoing)),
             f"main changed {len(deploy_critical)} deploy-watched file{'s' if len(deploy_critical) != 1 else ''} this branch lacks — rebase forward"),
        ward("gates", "gates green" if not gates_waived else "gates green (1 waived)", gates_green,
             "not green for this exact commit — ⟲ sync runs the gates"),
        # The pre-push TODO ratchet, moved to the door: a TODO clears by naming a ticket the
        # branch acked (`branch.<b>.stack-todo-ack`), so a reviewer-requested marker ships
        # while undeclared debt still stops here.
        ward("todo", f"TODO debt acked ({len(todo['acks'])})" if todo["acks"] else "no TODO debt",
             not todo["blocked"],
             f"{len(todo['blocked'])} TODO{'s' if len(todo['blocked']) != 1 else ''} added with no ticket acked on this branch — "
             f"resolve them, or ack the ticket: git config --add branch.{branch}.stack-todo-ack '<TICKET> — <why this ships>'"),
    ]
    reasons = hard + [w["why"] for w in wards if not w["ok"] and w["why"] and not w.get("advisory")]
    # an unpublished copy nobody can have read: the ff ward alone holding the door opens the
    # replace route (/force-origin re-verifies the no-PR scope with a fresh gh call)
    blocking = [w["k"] for w in wards if not w["ok"] and not w.get("advisory")]
    replaceable = not hard and has_remote and not published and blocking == ["ff"]
    return {
        "branch": branch, "originExists": has_remote, "ff": ff, "outgoing": len(outgoing), "wip": len(wip),
        "commits": outgoing[:8], "moreCommits": max(0, n_out - 8), "ageDays": age_days,
        "followup": followup,
        "fork": {"sha": fork, "date": fork_date}, "mainSince": main_since,
        "deployCritical": deploy_critical,
        "files": files[:20], "moreFiles": max(0, len(files) - 20),
        "commit": commit, "gatesGreen": gates_green, "gatesWaived": gates_waived,
        "todoDebt": todo,
        "web": _origin_web(branch),
        "published": published,
        "wards": wards, "ok": not reasons, "reasons": reasons,
        "replaceable": replaceable, "originHead": snap.remote(branch),
        "review": _review_flags(branch),
    }


# The read-only verdict is ~18 git spawns and every panel polls it. Everything it reads is a
# ref (branch, origin copy, origin/main, stack parent) or this branch's git config (gates-green,
# review flags, description, parent…) plus the cached open-PR set — so two spawns fingerprint
# it and a hit answers from memory. Belt and braces: a hit also expires after a minute.
# /push-origin never reads this cache; it recomputes the verdict at push time.
_PREVIEW_CACHE = {}   # (repo, branch) -> (fingerprint, monotonic, json)


def _branch_worktree(branch):
    """Path of the worktree that currently holds <branch> (HEAD = branch), or '' if none.
    Lets a push run in the branch's OWN tree so the pre-push hook checks what went green,
    instead of relocating the branch into the main checkout first (the GH-Desktop leftover)."""
    if not branch:
        return ""
    path = ""
    for line in ctx.run(["git", "worktree", "list", "--porcelain"]).stdout.splitlines():
        if line.startswith("worktree "):
            path = line[len("worktree "):]
        elif line == "branch refs/heads/" + branch:
            return path
    return ""


def force_origin(req, raw):
    """POST /force-origin {branch, lease} — the ONE sanctioned exception to FF-only: replace a
    stacked draft's pushed history so its PR re-acquires base ancestry (squash-merge repos
    force this on every mid-stack edit). Scope is the whole safety story, re-verified here
    with a fresh gh call — never the panel's copy: no PR at all, or the PR must still be a DRAFT with ZERO
    reviews and ZERO comments (nobody's read-state gets invalidated), gates green for this
    exact tree, and the client's lease must still be origin's head — then the push itself is
    --force-with-lease, so git refuses if origin moves in the gap. Human finger only, same
    as push-origin; anything outside this scope stays the additive vehicle's job."""
    d = json.loads(raw or "{}")
    branch = d.get("branch", "")
    lease = d.get("lease", "")
    if not branch or branch in ("main", "master"):
        return req._send(400, json.dumps({"ok": False, "err": "refusing: no branch / trunk"}))
    if ctx.run(["git", "rev-parse", "--verify", "-q", f"refs/heads/{branch}"]).returncode != 0:
        return req._send(404, json.dumps({"ok": False, "err": f"no local branch {branch}"}))
    if ctx.run(["git", "rev-parse", "--verify", "-q", f"refs/remotes/origin/{branch}"]).returncode != 0:
        return req._send(400, json.dumps({"ok": False, "err": "never pushed — plain push, no force needed"}))
    if ctx.run(["git", "merge-base", "--is-ancestor", f"origin/{branch}", branch]).returncode == 0:
        return req._send(400, json.dumps({"ok": False, "err": "fast-forwardable — plain push, no force needed"}))
    scope = sync.force_scope(branch, f"origin/{branch}")
    if not scope["eligible"]:
        bad = "; ".join(g["label"] for g in scope["guards"] if not g["ok"])
        return req._send(200, json.dumps({"ok": False, "err": f"out of scope: {bad}", "forceScope": scope}))
    if not lease or lease != scope["lease"]:
        return req._send(200, json.dumps({"ok": False, "forceScope": scope,
                                          "err": "origin moved since you read the sheet — re-open the panel"}))
    wt = _branch_worktree(branch)
    r = ctx.run((["git", "-C", wt] if wt else ["git"])
                + ["push", f"--force-with-lease={branch}:{lease}", "origin", branch])
    ok = r.returncode == 0
    target = scope.get("prUrl") or ""
    opened = _open_web(target) if ok and target else False
    req._send(200, json.dumps({
        "ok": ok, "remote": "origin", "web": target, "opened": opened,
        "out": (r.stdout or "").strip(), "err": (r.stderr or "").strip(),
    }))


def push_origin(req, raw):
    d = json.loads(raw or "{}")
    branch = d.get("branch", "")
    v = _origin_verdict(branch)
    if v is None:
        return req._send(400, json.dumps({"ok": False, "err": "no such branch"}))
    if not v["ok"]:
        return req._send(200, json.dumps({"ok": False, "err": "; ".join(v["reasons"]), "verdict": v}))
    # The verdict's ff ward read the last fetch's origin/<branch>; only trunk is fetched on a
    # throttle. A commit landed from github.com (an accepted suggestion) leaves that ref stale,
    # the ward green, and the push rejected with a stderr the header can't show. Fetch the one
    # ref now and refuse in words before git does.
    # A first push has no origin/<branch> to fetch or compare — the ward is only for re-pushes.
    ctx.run(["git", "fetch", "--quiet", "origin", branch])
    has_remote = ctx.run(["git", "rev-parse", "--verify", "-q", f"refs/remotes/origin/{branch}"]).returncode == 0
    if has_remote and ctx.run(["git", "merge-base", "--is-ancestor", f"origin/{branch}", branch]).returncode != 0:
        n = ctx.run(["git", "rev-list", "--count", f"{branch}..origin/{branch}"]).stdout.strip() or "?"
        return req._send(200, json.dumps({
            "ok": False, "verdict": v,
            "err": f"origin/{branch} has {n} commit{'' if n == '1' else 's'} you don't — sync first",
        }))
    # plain push — no --force under any circumstance; the pre-push hook still runs
    # underneath as the last net (WIP trailers, merge commits, deploy-critical gap). Run it in
    # the branch's own worktree so the hook checks the tree that went green; no /checkout-to-main
    # relocation. Falls back to the pinned cwd when the branch is checked out nowhere.
    wt = _branch_worktree(branch)
    r = ctx.run((["git", "-C", wt] if wt else ["git"]) + ["push", "origin", branch])
    ok = r.returncode == 0
    if ok:
        from . import reviewdesk
        reviewdesk.pushed()   # replies waiting on these commits go out on the next tick
    # An open PR already exists → jump to it; otherwise the compare-and-create form.
    target = (_open_pr_url(branch) or v["web"]) if ok else v["web"]
    # stay: the outbox's push, whose next step is its own open-PR link — no tab pops mid-sheet
    opened = _open_web(target) if ok and not d.get("stay") else False
    req._send(200, json.dumps({
        "ok": ok,
        "remote": "origin",
        "web": target,
        "opened": opened,
        "out": (r.stdout or "").strip(),
        "err": (r.stderr or "").strip(),
    }))


# ── prep to push — ONE state-routed motion (design.md "the header is two buttons") ──

def _squash_unpushed(branch, message=""):
    """stack-squash --unpushed --format --no-voice: collapse the unpushed tail to one commit
    with the mechanical message, so prep never blocks on a model call."""
    cmd = [os.path.join(ctx.SCRIPTS, "stack-squash"), "--unpushed", "--format", "--no-voice"]
    if message:
        cmd.append(f"--message={message}")
    verdict, err = shellout.json_out(cmd[0], [*cmd[1:], branch], require=("ok",))
    return err if err else verdict


def prep_push(req, raw):
    """POST /prep-push {branch} — route by state and land on 'voiced outgoing commits' (a WIP
    tail is sealed into one; deliberate voiced commits go out as they are):
      restacked + open PR   → carry as a catch-up merge on origin's head (additive, plain push)
      diverged + open PR    → build the additive vehicle, absorb it as the branch tip
      diverged, no PR       → refuse (⋯ reconcile is the manual override)
      behind + unpublished  → forward-rebase onto origin/main first (skipped on conflict)
      unpushed tail > 1     → stack-squash --unpushed --format (voiced draft)
      already one / nothing → no-op, report
    The words are edited afterwards in the outline column (srv/outline.py)."""
    d = json.loads(raw or "{}")
    branch = d.get("branch", "")
    v = _origin_verdict(branch)
    if v is None:
        return req._send(404, json.dumps({"ok": False, "err": "no such branch"}))
    if branch in ("main", "master"):
        return req._send(200, json.dumps({"ok": False, "err": "trunk doesn't go through this door"}))
    published = branch in sync._open_pr_heads(fresh=True)
    tip_before = _tip(branch)
    routed = []

    if not v["ff"]:
        if not published:
            # not mechanically routable — the omni sync reads this flag and puts Claude in
            # the middle (the /reconcile eject) instead of stopping at a refusal
            return req._send(200, json.dumps({
                "ok": False, "reconcile": True,
                "err": "diverged from origin without an open PR — handing to Claude to work out the source of truth"}))
        if _is_restack(branch):
            holder = next((p for p, b in stage._worktrees() if b == branch), None)
            if holder and stage._dirty(holder):
                return req._send(200, json.dumps({
                    "ok": False, "err": f"{holder} holds {branch} with uncommitted changes — commit or stash first"}))
            # carry the restack as a catch-up merge: one commit whose tree is the restacked
            # tree and whose parents are origin's PR head + the new base — additive over
            # pushed history, so the door's plain FF push moves origin (no force, ever).
            # The tree is unchanged, so a green gates verdict rides along.
            tip = _tip(branch)
            origin_tip = ctx.run(["git", "rev-parse", f"origin/{branch}"]).stdout.strip()
            sp = (ctx.run(["git", "config", f"branch.{branch}.stack-parent"]).stdout.strip()
                  or ctx.run(["git", "config", f"stack-branch.{branch}.parent"]).stdout.strip())
            base_ref = (f"origin/{sp}" if sp and sp not in ("main", "master") and ctx.run(
                ["git", "rev-parse", "--verify", "-q", f"refs/remotes/origin/{sp}"]).returncode == 0
                else "origin/main")
            base = ctx.run(["git", "merge-base", branch, base_ref]).stdout.strip()
            if not origin_tip or not base:
                return req._send(500, json.dumps({"ok": False, "err": "couldn't resolve origin head / new base for the catch-up merge"}))
            folded = ctx.run(["git", "rev-list", "--count", f"{base}..{tip}"]).stdout.strip()
            meta = ctx.run(["git", "log", "-1", "--format=%an%x1f%ae%x1f%aD", tip]).stdout.strip().split("\x1f")
            env = dict(os.environ)
            if len(meta) == 3:
                env.update({"GIT_AUTHOR_NAME": meta[0], "GIT_AUTHOR_EMAIL": meta[1], "GIT_AUTHOR_DATE": meta[2]})
            msg = ctx.run(["git", "log", "-1", "--format=%B", tip]).stdout.strip()
            # identity trailer: machine-authored commits were anonymous — the 2026-08-19 absorb
            # incident was unattributable for it. Squash-merge strips it from origin.
            msg += "\n\nVia: /prep-push catch-up (stack-review-server)"
            cmd = ["git", "commit-tree", f"{tip}^{{tree}}", "-p", origin_tip, "-p", base, "-m", msg]
            if ctx.run(["git", "config", "--get", "commit.gpgsign"]).stdout.strip() == "true":
                cmd.insert(2, "-S")
            r = subprocess.run(cmd, cwd=ctx.repo_cwd(), env=env, capture_output=True, text=True)
            carrier = r.stdout.strip()
            if r.returncode != 0 or not carrier:
                return req._send(500, json.dumps({"ok": False, "err": (r.stderr or "commit-tree failed").strip()[:300]}))
            if holder:
                r = ctx.run(["git", "-C", holder, "reset", "--hard", carrier])
            else:
                r = ctx.run(["git", "update-ref", f"refs/heads/{branch}", carrier, tip])
            if r.returncode != 0:
                return req._send(200, json.dumps({"ok": False, "err": "branch moved while building the catch-up merge — reload and retry"}))
            # the seal-era stamp is now moot — the carrier state is self-describing (ff again)
            stackcfg.unset_key(branch, "restack-supersedes")
            routed.append(f"carried your restack ({folded} commit{'s' if folded != '1' else ''} on the new base) "
                          "as a catch-up merge on origin's head — additive history, plain push")
        else:
            res = sync.build_additive(branch)
            if not res.get("ok"):
                return req._send(res.pop("code", 200), json.dumps(res))
            sha = res["shaFull"]
            # verdict-preserving ward: the normal absorb is tree-preserving (the vehicle carries
            # local's content), so this fires only when the move would REPLACE a currently
            # gates-green tree with a different one — the 2026-08-19 delete-user shape. That is
            # never routine; it needs an explicit confirm:true, not a silent hard reset.
            green = _green_tree(branch)
            if (green and green == _tree(branch) and _tree(sha) != green and not d.get("confirm")):
                ctx.run(["git", "branch", "-D", res["vehicle"]])
                return req._send(200, json.dumps({
                    "ok": False, "confirmable": True,
                    "err": f"{branch} sits on a gates-green tree and the absorb would replace it with "
                           "different content — re-check the vehicle is what you mean, then retry with confirm"}))
            holder = next((p for p, b in stage._worktrees() if b == branch), None)
            if holder and stage._dirty(holder):
                ctx.run(["git", "branch", "-D", res["vehicle"]])
                return req._send(200, json.dumps({
                    "ok": False, "err": f"{holder} holds {branch} with uncommitted changes — commit or stash first"}))
            if holder:
                ctx.run(["git", "-C", holder, "reset", "--hard", sha])
            else:
                ctx.run(["git", "branch", "-f", branch, sha])
            ctx.run(["git", "branch", "-D", res["vehicle"]])
            ctx.run(["git", "config", "--remove-section", f"branch.{res['vehicle']}"])
            routed.append("carried your rework onto the PR head as one additive commit")
    else:
        state = sync.state(branch, fresh_prs=True)
        if state["behind"] > 0 and not published and state.get("parent") == "main" and v["outgoing"] > 0:
            scratch = "/tmp/viewer-prep-scratch"
            ctx.run(["git", "worktree", "remove", "--force", scratch])
            if ctx.run(["git", "worktree", "add", "--detach", scratch, "origin/main"]).returncode == 0:
                held = next((p for p, b in stage._worktrees() if b == branch and p != scratch), None)
                cut = ctx.run(["git", "merge-base", branch, "origin/main"]).stdout.strip()
                if held is None:
                    r = ctx.run(["git", "-C", scratch, "rebase", "--onto", "origin/main", cut, branch])
                    if r.returncode == 0:
                        routed.append(f"restacked onto origin/main ({state['behind']} behind)")
                    else:
                        ctx.run(["git", "-C", scratch, "rebase", "--abort"])
                        routed.append("restack skipped (would conflict) — pushing from the current base")
                else:
                    routed.append("restack skipped (branch is checked out) — pushing from the current base")
                ctx.run(["git", "worktree", "remove", "--force", scratch])
        v = _origin_verdict(branch)
        if v["outgoing"] > 1 and published:
            routed.append(f"{v['outgoing']} follow-up commits on the open PR — pushed as they are, no seal")
        elif v["outgoing"] > 1 and not v["wip"]:
            routed.append(f"{v['outgoing']} voiced commits — pushed as they are, no seal")
        elif v["outgoing"] > 1:
            # sealing resets onto origin's tip and re-commits the tree — across a merge that
            # linearizes it, turning "caught up with main" into main's diff re-declared as
            # branch content (the 22-files-changed failure, 2026-08-12)
            if ctx.run(["git", "rev-list", "--first-parent", "--merges",
                        f"origin/{branch}..{branch}"]).stdout.strip():
                return req._send(200, json.dumps({
                    "ok": False, "routed": routed,
                    "err": "unpushed commits include a merge — sealing would flatten it; push the merge first, then prep the rest"}))
            sq = _squash_unpushed(branch)
            if not sq.get("ok"):
                return req._send(200, json.dumps({"ok": False, "err": sq.get("err") or "squash failed", "routed": routed}))
            routed.append(f"sealed {v['outgoing']} unpushed commits into one" + (" (voiced)" if sq.get("voiced") else " — ✦ voice drafts a message"))
        elif v["outgoing"] == 1:
            routed.append("already one clean commit — nothing to do")
        else:
            return req._send(200, json.dumps({"ok": False, "err": "nothing to push — origin already has this", "routed": routed}))

    # every mutating route moves the tip — reseat stacked children so they don't hang
    # off the pre-prep commits (the external-amend-orphans failure mode)
    if _tip(branch) != tip_before:
        from srv import reviews
        reseated = []
        reviews._reseat_walk(branch, reseated)
        moved = [x["branch"] for x in reseated if x.get("status") == "reseated"]
        if moved:
            routed.append(f"reseated {', '.join(moved)}")
        held = [x["branch"] for x in reseated if x.get("status") == "held-pr"]
        if held:
            routed.append(f"left {', '.join(held)} untouched — open PR, reseat would need a force-push")

    v = _origin_verdict(branch)
    return req._send(200, json.dumps({
        "ok": True, "routed": routed, "outgoing": v["outgoing"],
        "commit": v["commit"], "wardsOk": v["ok"], "reasons": v["reasons"],
    }))


def dirty_resolve(req, raw):
    """POST /dirty-resolve {branch, action} — the sync flow's routed decision on a dirty
    working tree, NOTHING automatic (the incident file was foreign WIP on the wrong
    branch — auto-include is the ledger-scripts-in-.zshrc failure at commit level).
      include → stage + commit everything in the holding worktree (the squash folds it)
      stash   → stash incl. untracked;  pop → bring a sync-stash back after the motion
    """
    d = json.loads(raw or "{}")
    branch = d.get("branch", "")
    action = d.get("action", "")
    wt = next((p for p, b in stage._worktrees() if b == branch), None)
    if not wt:
        return req._send(404, json.dumps({"ok": False, "err": f"no worktree holds {branch}"}))
    if action == "include":
        ctx.run(["git", "-C", wt, "add", "-A"])
        r = ctx.run(["git", "-C", wt, "commit", "-m", "wip: uncommitted working-tree changes, folded in via sync"])
    elif action == "stash":
        r = ctx.run(["git", "-C", wt, "stash", "push", "-u", "-m", f"sync-stash {branch}"])
    elif action == "pop":
        r = ctx.run(["git", "-C", wt, "stash", "pop"])
    else:
        return req._send(400, json.dumps({"ok": False, "err": f"unknown action {action!r}"}))
    ok = r.returncode == 0
    req._send(200, json.dumps({
        "ok": ok,
        "out": (r.stdout or "").strip(),
        "err": "" if ok else (r.stderr or r.stdout or f"{action} failed").strip(),
    }))
