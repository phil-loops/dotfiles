# srv/push.py — the prepare-to-push gate + push endpoints (the node header's sync strip).
#
#   POST /gates          {branch}  → run stack-gates in the branch's worktree; JSON verdict.
#                                    {detach:true} spawns it with a progress journal instead.
#   GET  /gates-progress ?branch=  → live per-gate journal of a detached /gates run
#   GET  /push-preview   ?branch=  → read-only: the outgoing-vs-origin commit + guard verdict
#   POST /push-origin    {branch}  → THE shared-history door. Human finger only (viewer button);
#                                    Claude never calls this. Every guard re-verified server-side.
import json
import os
import re
import subprocess
import tempfile
import time
from urllib.parse import parse_qs

from . import ctx, stage, sync


def delta_tests(req, raw):
    # Run the tests RELATED to the branch's delta (stack-delta-tests: each changed X.ts's
    # co-located X.test.ts, plus changed *.test.ts). The prep-to-merge pipeline calls this
    # AFTER checkout, so it runs in the main checkout (HEAD = branch, real node_modules).
    d = json.loads(raw or "{}")
    branch = d.get("branch", "")
    r = ctx.run([os.path.join(ctx.SCRIPTS, "stack-delta-tests"), "--branch", branch])
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


# branch → {"path": progress jsonl, "proc": Popen | "pid": int, "t0": epoch, "tree": tree sha
# at spawn}. The dict is just a warm cache: every spawn also writes a sidecar json next to the
# journal, so a bounced server re-adopts the still-running detached child instead of losing it.
_GATE_JOBS = {}


def _job_file(branch):
    return os.path.join(tempfile.gettempdir(), f"stack-gates-{branch.replace('/', '-')}.job.json")


def _adopt_job(branch):
    """Re-attach to a detached gates run this server process didn't spawn (the child is
    disowned and survives a server bounce; only the in-memory pointer died with us)."""
    try:
        with open(_job_file(branch)) as f:
            j = json.load(f)
        job = {"path": j["path"], "pid": int(j["pid"]), "t0": float(j["t0"]), "tree": j["tree"]}
    except Exception:
        return None
    _GATE_JOBS[branch] = job
    return job


def _job_running(job):
    proc = job.get("proc")
    if proc is not None:
        return proc.poll() is None
    try:
        os.kill(job["pid"], 0)
        return True
    except OSError:
        return False


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
    # useCache: the sync strip re-runs on every motion — when this tree already passed,
    # answer green instantly instead of re-paying the typecheck.
    if d.get("useCache") and branch and _green_tree(branch) == _tree(branch):
        return req._send(200, json.dumps({"ok": True, "cached": True, "gates": []}))
    # --fix: a red gate with a remediation (e.g. fresh → rebase onto origin/main, format
    # → oxfmt) gets one auto-fix attempt before the verdict, so the card clears what it can.
    # The sync strip passes fix:false — its route step already sealed the ONE outgoing
    # commit, and a fix that commits (format cascade) or rebases would move the tip under it.
    cmd = [os.path.join(ctx.SCRIPTS, "stack-gates"), "--branch", branch]
    if d.get("fix", True):
        cmd.append("--fix")
    # detach: spawn with a progress journal and return at once — the strip tails
    # GET /gates-progress for live per-gate position instead of freezing for a tsc.
    if d.get("detach"):
        old = _GATE_JOBS.get(branch) or _adopt_job(branch)
        if old and _job_running(old):
            return req._send(200, json.dumps({"ok": True, "started": True, "already": True}))
        if old and old["tree"] == _tree(branch):
            # an orphaned run finished while no server was watching — harvest its verdict
            # instead of re-paying the typecheck for the same tree
            result = next((e for e in _journal_events(old["path"]) if e.get("event") == "result"), None)
            if result and result.get("ok"):
                _record_green(branch, old["tree"])
                return req._send(200, json.dumps({"ok": True, "cached": True, "gates": result.get("gates", [])}))
        path = os.path.join(
            tempfile.gettempdir(),
            f"stack-gates-{branch.replace('/', '-')}-{int(time.time())}.jsonl")
        proc = subprocess.Popen(cmd + ["--progress", path], cwd=ctx.repo_cwd(),
                                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        job = {"path": path, "proc": proc, "t0": time.time(), "tree": _tree(branch)}
        _GATE_JOBS[branch] = job
        with open(_job_file(branch), "w") as f:
            json.dump({"path": path, "pid": proc.pid, "t0": job["t0"], "tree": job["tree"]}, f)
        return req._send(200, json.dumps({"ok": True, "started": True}))
    r = ctx.run(cmd)
    # stack-gates always prints a JSON verdict on stdout and exits 0
    try:
        if json.loads(r.stdout).get("ok"):
            _record_green(branch, _tree(branch))
    except Exception:
        pass
    req._send(200, r.stdout or json.dumps({"ok": False, "gates": [], "err": r.stderr or "gates crashed"}))


def gates_progress(req, u):
    qs = parse_qs(u.query)
    branch = (qs.get("branch") or [""])[0]
    job = _GATE_JOBS.get(branch) or _adopt_job(branch)
    if not job:
        return req._send(200, json.dumps({"running": False, "err": "no gates run for this branch"}))
    events = _journal_events(job["path"])
    result = next((e for e in events if e.get("event") == "result"), None)
    if result and result.get("ok"):
        # green is recorded against the TREE the run was spawned on — a message-only reword
        # while the gates ran keeps the same tree, so the verdict carries; any content change
        # (rebase, new commit) makes a new tree and the door stays locked
        _record_green(branch, job["tree"])
    running = _job_running(job)
    out = {"running": running, "elapsed": round(time.time() - job["t0"], 1), "events": events}
    if result:
        out["result"] = {"ok": result.get("ok"), "gates": result.get("gates", []), "note": result.get("note")}
    elif not running:
        out["dead"] = True
    return req._send(200, json.dumps(out))


# ── origin push — the shared-history door ────────────────────────────────────
# Design + boundaries: ~/daily-log/2026-07-02-deprecate-gh-desktop/design.md.
# Phil's rules: FF-only, never force; outgoing must be exactly ONE commit with a
# voiced subject + real body; gates green for the exact tree pushed; the app never
# authors PRs (at most a plain github.com link). Claude never calls /push-origin.

# Gates-green lives in git config (stack-branch.<b>.gates-green-tree), server-recorded and
# never client-claimed. Keyed by TREE sha, not commit: the gates read file contents only, so
# a message reword must not relock push — the tip-sha key stranded green on rewords
# (2026-07-12). Config, not process memory, so a server bounce doesn't relock push either.
def _green_tree(branch):
    return (ctx.run(["git", "config", "--get", f"branch.{branch}.stack-gates-green-tree"]).stdout.strip()
            or ctx.run(["git", "config", "--get", f"stack-branch.{branch}.gates-green-tree"]).stdout.strip())


def _record_green(branch, tree):
    ctx.run(["git", "config", f"stack-branch.{branch}.gates-green-tree", tree])


_WIP_SUBJECT = re.compile(r"^(wip\b|fixup!|squash!|amend!)", re.IGNORECASE)


def _tip(branch):
    return ctx.run(["git", "rev-parse", branch]).stdout.strip()


def _tree(rev):
    return ctx.run(["git", "rev-parse", f"{rev}^{{tree}}"]).stdout.strip()


def _pr_base(branch):
    """The compare form's base: the nearest stack ancestor with an OPEN PR on origin, else
    main. A stacked child targets its parent's PR so the review diff stays that branch's own
    work; GitHub retargets the child to main itself when the parent PR merges."""
    heads = sync._open_pr_heads()
    seen = {branch}
    b = branch
    while True:
        parent = (ctx.run(["git", "config", f"branch.{b}.stack-parent"]).stdout.strip()
                  or ctx.run(["git", "config", f"stack-branch.{b}.parent"]).stdout.strip())
        if not parent or parent in ("main", "master") or parent in seen:
            return "main"
        if (parent in heads
                and ctx.run(["git", "rev-parse", "--verify", "-q",
                             f"refs/remotes/origin/{parent}"]).returncode == 0):
            return parent
        seen.add(parent)
        b = parent


def _origin_web(branch):
    """github.com compare link for the branch, opened straight to the 'Open a pull
    request' form (?expand=1) with the base prefilled by _pr_base. Authoring still
    happens on the website — this only opens the form; it never prefills a
    title/body or calls gh pr create."""
    url = ctx.run(["git", "remote", "get-url", "origin"]).stdout.strip()
    m = re.search(r"[:/]([^/:]+/[^/]+?)(?:\.git)?$", url)
    return f"https://github.com/{m.group(1)}/compare/{_pr_base(branch)}...{branch}?expand=1" if m else ""


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
        subprocess.Popen(["open", url], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        return True
    except Exception:
        return False


def _origin_verdict(branch):
    """Every /push-origin guard, recomputed from git — shared by the read-only
    preview (drives the crossing view + wards + arming) and the push itself
    (never trusts the client's copy of this verdict). The preview renders the
    whole threshold: what came before (the outgoing commits), what main has
    done since the fork, and the wards holding the door."""
    if not branch or ctx.run(["git", "rev-parse", "--verify", "-q", f"refs/heads/{branch}"]).returncode != 0:
        return None
    hard = []   # refusals outside the normal ward path
    if branch in ("main", "master"):
        hard.append("refusing to push trunk from here")
    has_remote = ctx.run(["git", "rev-parse", "--verify", "-q", f"refs/remotes/origin/{branch}"]).returncode == 0
    ff = True
    if has_remote:
        ff = ctx.run(["git", "merge-base", "--is-ancestor", f"origin/{branch}", branch]).returncode == 0
    # outgoing = commits origin doesn't have. On a first push, --not --remotes=origin keeps a
    # stacked branch's parent commits (already on origin via the parent) out of the count.
    range_args = [f"origin/{branch}..{branch}"] if has_remote else [branch, "--not", "--remotes=origin"]
    log = ctx.run(["git", "log", "--format=%H\x1f%s\x1f%ad\x1f%at", "--date=format:%b %e", *range_args]).stdout
    outgoing = []
    for rec in log.splitlines():
        parts = rec.split("\x1f")
        if len(parts) == 4:
            outgoing.append({"sha": parts[0], "subject": parts[1], "date": parts[2], "at": int(parts[3])})
    age_days = max(0, int((time.time() - outgoing[-1]["at"]) / 86400)) if outgoing else 0

    # the other side of the crossing: how far shared history moved since this work forked
    fork = ctx.run(["git", "merge-base", branch, "origin/main"]).stdout.strip()
    fork_date = ctx.run(["git", "log", "-1", "--format=%ad", "--date=format:%b %e", fork]).stdout.strip() if fork else ""
    main_since = 0
    if fork:
        raw = ctx.run(["git", "rev-list", "--count", f"{fork}..origin/main"]).stdout.strip()
        main_since = int(raw) if raw.isdigit() else 0
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

    commit = None
    voiced = said_why = not_merge = False
    if len(outgoing) == 1:
        sha = outgoing[0]["sha"]
        subject = outgoing[0]["subject"]
        body = ctx.run(["git", "log", "-1", "--format=%b", sha]).stdout.strip()
        voiced = not _WIP_SUBJECT.match(subject)
        said_why = bool(re.sub(r"^X-WIP:.*$", "", body, flags=re.IGNORECASE | re.MULTILINE).strip())
        not_merge = not ctx.run(["git", "rev-list", "--no-walk", "--merges", sha]).stdout.strip()
        commit = {"sha": sha, "subject": subject, "body": body}
    tip = _tip(branch)
    gates_green = _green_tree(branch) == _tree(tip)

    def ward(k, label, ok, why, advisory=False):
        return {"k": k, "label": label, "ok": bool(ok), "why": "" if ok else why, "advisory": advisory}
    wards = [
        ward("one", "one commit", len(outgoing) == 1 and not_merge,
             "nothing to push — origin already has this" if not outgoing
             else f"{len(outgoing)} commits — prep seals them into one" if len(outgoing) > 1
             else "outgoing commit is a merge commit"),
        ward("voiced", "voiced subject", voiced and len(outgoing) == 1,
             "" if len(outgoing) != 1 else "subject is a WIP/fixup placeholder — prep writes a voiced one"),
        ward("why", "says why", said_why and len(outgoing) == 1,
             "" if len(outgoing) != 1 else "no commit body — optional; add a why if it helps a reviewer", advisory=True),
        ward("purpose", "purpose set",
             bool(ctx.run(["git", "config", f"branch.{branch}.description"]).stdout.strip()),
             "no branch description — a forest member without a purpose is an unfinished operation", advisory=True),
        ward("ff", "fast-forward", ff,
             "diverged from origin — reconcile first; shared history is never overwritten"),
        ward("watch", "deploy watch clear", not deploy_critical,
             f"main changed {len(deploy_critical)} deploy-watched file{'s' if len(deploy_critical) != 1 else ''} this branch lacks — rebase forward"),
        ward("gates", "gates green", gates_green,
             "not green for this exact commit — ⟲ sync runs the gates"),
    ]
    reasons = hard + [w["why"] for w in wards if not w["ok"] and w["why"] and not w.get("advisory")]
    return {
        "branch": branch, "originExists": has_remote, "ff": ff, "outgoing": len(outgoing),
        "commits": outgoing[:8], "ageDays": age_days,
        "fork": {"sha": fork, "date": fork_date}, "mainSince": main_since,
        "deployCritical": deploy_critical,
        "files": files[:20], "moreFiles": max(0, len(files) - 20),
        "commit": commit, "gatesGreen": gates_green, "web": _origin_web(branch),
        # published (cached open-PR set, no per-poll gh call): with outgoing==0 it splits the
        # dead push button into 'view PR ↗' (has one) vs 'open PR ↗' (pushed, none yet).
        "published": branch in sync._open_pr_heads(),
        "wards": wards, "ok": not reasons, "reasons": reasons,
    }


def preview(req, u):
    branch = parse_qs(u.query).get("branch", [""])[0]
    # keep origin/main loosely fresh (throttled bg fetch) so the deploy-watch / behind wards
    # stop trailing a stale origin — they were computed against whatever the last fetch left.
    main = ctx.run(["git", "config", "stack.main-branch"]).stdout.strip() or "main"
    sync._freshen_trunk(main)
    v = _origin_verdict(branch)
    if v is None:
        return req._send(400, json.dumps({"ok": False, "err": "no such branch"}))
    req._send(200, json.dumps(v))


def open_pr(req, raw):
    """POST /open-pr {branch} — open the branch's PR page WITHOUT pushing: the OPEN PR if one
    exists (view it), else the compare-and-create form (author it). The push-less exit for a
    branch already up-to-date on origin (outgoing==0) that would otherwise face a dead push
    button. Human-finger only, same as push-origin: opens a browser tab, never gh pr create."""
    d = json.loads(raw or "{}")
    branch = d.get("branch", "")
    if not branch:
        return req._send(400, json.dumps({"ok": False, "err": "no branch"}))
    # a real local branch only — else a garbage name would open a junk compare tab (the URL is
    # built from the string, not a resolved ref). The frontend only fires this for real branches.
    if ctx.run(["git", "rev-parse", "--verify", "--quiet", f"refs/heads/{branch}"]).returncode != 0:
        return req._send(404, json.dumps({"ok": False, "err": f"no local branch {branch}"}))
    pr_url = _open_pr_url(branch)
    url = pr_url or _origin_web(branch)
    opened = _open_web(url)
    req._send(200, json.dumps({"ok": bool(url), "web": url, "opened": opened, "hadPr": bool(pr_url)}))


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


def push_origin(req, raw):
    d = json.loads(raw or "{}")
    branch = d.get("branch", "")
    v = _origin_verdict(branch)
    if v is None:
        return req._send(400, json.dumps({"ok": False, "err": "no such branch"}))
    if not v["ok"]:
        return req._send(200, json.dumps({"ok": False, "err": "; ".join(v["reasons"]), "verdict": v}))
    # plain push — no --force under any circumstance; the pre-push hook still runs
    # underneath as the last net (WIP trailers, merge commits, deploy-critical gap). Run it in
    # the branch's own worktree so the hook checks the tree that went green; no /checkout-to-main
    # relocation. Falls back to the pinned cwd when the branch is checked out nowhere.
    wt = _branch_worktree(branch)
    r = ctx.run((["git", "-C", wt] if wt else ["git"]) + ["push", "origin", branch])
    ok = r.returncode == 0
    # An open PR already exists → jump to it; otherwise the compare-and-create form.
    target = (_open_pr_url(branch) or v["web"]) if ok else v["web"]
    opened = _open_web(target) if ok else False
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
    with the mechanical message — the claude voicing is opt-in via /draft-message, so prep
    never blocks on a model call."""
    cmd = [os.path.join(ctx.SCRIPTS, "stack-squash"), "--unpushed", "--format", "--no-voice"]
    if message:
        cmd.append(f"--message={message}")
    r = ctx.run([*cmd, branch])
    try:
        return json.loads(r.stdout)
    except Exception:
        return {"ok": False, "err": (r.stderr or r.stdout or "squash failed").strip()[:300]}


def prep_push(req, raw):
    """POST /prep-push {branch} — route by state and land on 'exactly one outgoing commit':
      diverged + open PR    → build the additive vehicle, absorb it as the branch tip
      diverged, no PR       → refuse (⋯ reconcile is the manual override)
      behind + unpublished  → forward-rebase onto origin/main first (skipped on conflict)
      unpushed tail > 1     → stack-squash --unpushed --format (voiced draft)
      already one / nothing → no-op, report
    Always returns the outgoing commit (sha/subject/body) so the editor can open on it."""
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
        res = sync.build_additive(branch)
        if not res.get("ok"):
            return req._send(res.pop("code", 200), json.dumps(res))
        sha = res["shaFull"]
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
        if v["outgoing"] > 1:
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
    if v.get("commit"):
        # fold the forest section into the body the editor opens with, so the
        # "where this sits in the merge order" line is visible and editable up front
        # instead of being appended unseen at save — what you see is what gets committed.
        v["commit"] = {**v["commit"], "body": _with_forest(v["commit"]["body"], branch)}
    return req._send(200, json.dumps({
        "ok": True, "routed": routed, "outgoing": v["outgoing"],
        "commit": v["commit"], "wardsOk": v["ok"], "reasons": v["reasons"],
    }))


def _forest_section(branch):
    """The one line the project writes about itself: where this change sits in the merge order and
    what it builds on. Free — every fact comes from git config. Silent outside a project.
    The Mermaid map and the integration link deliberately do NOT go here: this repo has a PR
    template, so GitHub prefills a PR body from the TEMPLATE and never from the commit message —
    a diagram in a commit would reach git history and nothing else. `stack-pr-body` carries them."""
    r = ctx.run([os.path.join(ctx.SCRIPTS, "stack-commit-body"), branch, "--section"])
    return r.stdout.strip() if r.returncode == 0 else ""


def _with_forest(body, branch):
    section = _forest_section(branch)
    if not section:
        return body
    # regenerate: drop any previously generated line (and the old "-- forest --" fence)
    prose = "\n".join(
        line for line in body.split("-- forest --")[0].splitlines()
        if not line.startswith("Part of ")
    ).strip()
    return f"{prose}\n\n{section}" if prose else section


def draft_message(req, raw):
    """POST /draft-message {branch} — the opt-in claude pass: draft the ONE outgoing
    commit's message in the author's voice (stack-squash --dry drafts, nothing moves).
    Nothing is applied until the editor saves it through /prep-message."""
    d = json.loads(raw or "{}")
    branch = d.get("branch", "")
    v = _origin_verdict(branch)
    if v is None:
        return req._send(404, json.dumps({"ok": False, "err": "no such branch"}))
    if v["outgoing"] != 1 or not v["commit"]:
        return req._send(200, json.dumps({"ok": False, "err": "drafting needs exactly one unpushed commit — run prep first"}))
    r = ctx.run([os.path.join(ctx.SCRIPTS, "stack-squash"), "--dry", "--unpushed", branch])
    try:
        sq = json.loads(r.stdout)
    except Exception:
        return req._send(200, json.dumps({"ok": False, "err": (r.stderr or r.stdout or "draft failed").strip()[:300]}))
    if not sq.get("ok") or not sq.get("voiced"):
        return req._send(200, json.dumps({"ok": False, "err": sq.get("err") or "claude unavailable — keep the mechanical message or write your own"}))
    lines = (sq.get("message") or "").splitlines()
    return req._send(200, json.dumps({
        "ok": True,
        "subject": lines[0].strip() if lines else "",
        "body": _with_forest("\n".join(lines[1:]).strip(), branch),
    }))


def prep_message(req, raw):
    """POST /prep-message {branch, subject, body} — rewrite the message of the ONE unpushed
    tip commit, tree untouched (commit-tree + atomic update-ref, author preserved). Refuses
    unless the outgoing set is exactly that commit, so pushed history can't be reworded."""
    d = json.loads(raw or "{}")
    branch = d.get("branch", "")
    subject = (d.get("subject") or "").strip()
    body = (d.get("body") or "").strip()
    if not subject or _WIP_SUBJECT.match(subject):
        return req._send(200, json.dumps({"ok": False, "err": "subject must be a real voiced line, not a placeholder"}))
    v = _origin_verdict(branch)
    if v is None:
        return req._send(404, json.dumps({"ok": False, "err": "no such branch"}))
    if v["outgoing"] != 1 or not v["commit"]:
        return req._send(200, json.dumps({"ok": False, "err": "message editing needs exactly one unpushed commit — run prep first"}))
    tip = v["commit"]["sha"]
    if ctx.run(["git", "rev-parse", branch]).stdout.strip() != tip:
        return req._send(200, json.dumps({"ok": False, "err": "the outgoing commit isn't the branch tip — run prep first"}))
    if len(ctx.run(["git", "rev-list", "--no-walk", "--merges", tip]).stdout.split()) > 0:
        # commit-tree below writes ONE parent — rewording a merge would silently linearize it
        return req._send(200, json.dumps({"ok": False, "err": "the tip is a merge commit — can't reword it safely"}))
    meta = ctx.run(["git", "log", "-1", "--format=%an%x1f%ae%x1f%aD", tip]).stdout.strip().split("\x1f")
    env = dict(os.environ)
    if len(meta) == 3:
        env.update({"GIT_AUTHOR_NAME": meta[0], "GIT_AUTHOR_EMAIL": meta[1], "GIT_AUTHOR_DATE": meta[2]})
    # save the body verbatim — the forest section was already folded in when the
    # editor opened (see the prep return), so the author's edits to it are authoritative
    # here rather than regenerated out from under them.
    msg = subject + (f"\n\n{body}" if body else "")
    # A reword the author didn't ask for still moves the tip, and a moved tip reseats every
    # child. Now that prepare-commit-msg seeds the plan at commit time, the message usually
    # already matches — so say so and leave the sha alone.
    if msg.strip() == ctx.run(["git", "log", "-1", "--format=%B", tip]).stdout.strip():
        return req._send(200, json.dumps({
            "ok": True, "unchanged": True,
            "commit": {"sha": tip, "subject": subject, "body": body},
            "reseated": [],
        }))
    parent = ctx.run(["git", "rev-parse", f"{tip}~1"]).stdout.strip()
    cmd = ["git", "commit-tree", f"{tip}^{{tree}}", "-p", parent, "-m", msg]
    if ctx.run(["git", "config", "--get", "commit.gpgsign"]).stdout.strip() == "true":
        cmd.insert(2, "-S")   # plumbing ignores commit.gpgsign — unsigned reword pushes as Unverified
    r = subprocess.run(cmd, cwd=ctx.repo_cwd(), env=env, capture_output=True, text=True)
    new = r.stdout.strip()
    if r.returncode != 0 or not new:
        return req._send(500, json.dumps({"ok": False, "err": (r.stderr or "commit-tree failed").strip()[:300]}))
    # atomic old-value check; the tree is unchanged, so this is safe under any checkout
    r = ctx.run(["git", "update-ref", f"refs/heads/{branch}", new, tip])
    if r.returncode != 0:
        return req._send(200, json.dumps({"ok": False, "err": "branch moved while editing — reload and retry"}))
    # (no gates bookkeeping: gates-green is tree-keyed and a reword keeps the tree)
    # the tip sha moved — reseat any stacked children so they don't hang off the old commit
    # (same tree, so these rebases are trivially clean)
    from srv import reviews
    reseated = []
    reviews._reseat_walk(branch, reseated)
    return req._send(200, json.dumps({
        "ok": True, "commit": {"sha": new, "subject": subject, "body": body},
        "reseated": [x for x in reseated if x.get("status") == "reseated"],
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
