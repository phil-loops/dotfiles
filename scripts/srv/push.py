# srv/push.py — the "prepare to push" mobile flow's gate + push endpoints.
#
#   POST /gates        {branch}  → run stack-gates in the branch's worktree; JSON verdict
#   POST /push         {branch}  → fast-forward push to a SAFE remote (never origin); the
#                                  repo's pre-push hook (stack-prepush-guard) still runs,
#                                  so WIP commits are blocked at the door regardless.
#   GET  /push-preview ?branch=  → read-only: the outgoing-vs-origin commit + guard verdict
#   POST /push-origin  {branch}  → THE shared-history door. Human finger only (viewer button);
#                                  Claude never calls this. Every guard re-verified server-side.
import json
import os
import re
import time
from urllib.parse import parse_qs

from . import ctx, sync


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


def gates(req, raw):
    d = json.loads(raw or "{}")
    branch = d.get("branch", "")
    # --fix: a red gate with a remediation (e.g. fresh → rebase onto origin/main, format
    # → oxfmt) gets one auto-fix attempt before the verdict, so the card clears what it can.
    r = ctx.run([os.path.join(ctx.SCRIPTS, "stack-gates"), "--branch", branch, "--fix"])
    # stack-gates always prints a JSON verdict on stdout and exits 0
    try:
        if json.loads(r.stdout).get("ok"):
            _GREEN_GATES[branch] = _tip(branch)
    except Exception:
        pass
    req._send(200, r.stdout or json.dumps({"ok": False, "gates": [], "err": r.stderr or "gates crashed"}))


def _safe_remote(branch):
    """A non-origin remote to push to, or (None, reason). origin is read-only here."""
    configured = ctx.run(["git", "config", "stack-push.remote"]).stdout.strip()
    if configured:
        if configured == "origin":
            return None, "stack-push.remote is set to origin — refusing (origin is read-only)"
        return configured, None
    up = ctx.run(["git", "config", f"branch.{branch}.remote"]).stdout.strip()
    if up and up != "origin":
        return up, None
    if up == "origin":
        return None, "branch tracks origin — refusing to push there; set stack-push.remote to a fork"
    return None, "no push remote configured — set `git config stack-push.remote <fork>`"


def push(req, raw):
    d = json.loads(raw or "{}")
    branch = d.get("branch", "")
    if not branch:
        return req._send(400, json.dumps({"ok": False, "err": "no branch"}))

    remote, reason = _safe_remote(branch)
    if not remote:
        return req._send(200, json.dumps({"ok": False, "err": reason}))

    # plain push: never --force (only unpushed commits exist after prep, so it's a
    # fast-forward), and the pre-push guard fires here to block any stray WIP commit.
    r = ctx.run(["git", "push", remote, branch])
    ok = r.returncode == 0
    req._send(200, json.dumps({
        "ok": ok,
        "remote": remote,
        "out": (r.stdout or "").strip(),
        "err": (r.stderr or "").strip(),
    }))


# ── origin push — the shared-history door ────────────────────────────────────
# Design + boundaries: ~/daily-log/2026-07-02-deprecate-gh-desktop/design.md.
# Phil's rules: FF-only, never force; outgoing must be exactly ONE commit with a
# voiced subject + real body; gates green for that exact tip; the app never
# authors PRs (at most a plain github.com link). Claude never calls /push-origin.

_GREEN_GATES = {}   # branch → tip sha stack-gates last passed at (server-recorded, not client-claimed)

_WIP_SUBJECT = re.compile(r"^(wip\b|fixup!|squash!|amend!)", re.IGNORECASE)


def _tip(branch):
    return ctx.run(["git", "rev-parse", branch]).stdout.strip()


def _origin_web(branch):
    """Plain github.com compare link for the branch — the GitHub website is where
    PR authoring happens (never this app). No prefilled params, ever."""
    url = ctx.run(["git", "remote", "get-url", "origin"]).stdout.strip()
    m = re.search(r"[:/]([^/:]+/[^/]+?)(?:\.git)?$", url)
    return f"https://github.com/{m.group(1)}/compare/main...{branch}" if m else ""


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
    gates_green = _GREEN_GATES.get(branch) == tip

    def ward(k, label, ok, why):
        return {"k": k, "label": label, "ok": bool(ok), "why": "" if ok else why}
    wards = [
        ward("one", "one commit", len(outgoing) == 1 and not_merge,
             "nothing to push — origin already has this" if not outgoing
             else f"{len(outgoing)} commits — prep seals them into one" if len(outgoing) > 1
             else "outgoing commit is a merge commit"),
        ward("voiced", "voiced subject", voiced and len(outgoing) == 1,
             "" if len(outgoing) != 1 else "subject is a WIP/fixup placeholder — prep writes a voiced one"),
        ward("why", "says why", said_why and len(outgoing) == 1,
             "" if len(outgoing) != 1 else "commit body is empty — say what ships and why"),
        ward("ff", "fast-forward", ff,
             "diverged from origin — reconcile first; shared history is never overwritten"),
        ward("watch", "deploy watch clear", not deploy_critical,
             f"main changed {len(deploy_critical)} deploy-watched file{'s' if len(deploy_critical) != 1 else ''} this branch lacks — rebase forward"),
        ward("gates", "gates green", gates_green,
             "not green for this exact commit — run the pipeline above"),
    ]
    reasons = hard + [w["why"] for w in wards if not w["ok"] and w["why"]]
    return {
        "branch": branch, "originExists": has_remote, "ff": ff, "outgoing": len(outgoing),
        "commits": outgoing[:8], "ageDays": age_days,
        "fork": {"sha": fork, "date": fork_date}, "mainSince": main_since,
        "deployCritical": deploy_critical,
        "files": files[:20], "moreFiles": max(0, len(files) - 20),
        "commit": commit, "gatesGreen": gates_green, "web": _origin_web(branch),
        "wards": wards, "ok": not reasons, "reasons": reasons,
    }


def preview(req, u):
    branch = parse_qs(u.query).get("branch", [""])[0]
    v = _origin_verdict(branch)
    if v is None:
        return req._send(400, json.dumps({"ok": False, "err": "no such branch"}))
    req._send(200, json.dumps(v))


def push_origin(req, raw):
    d = json.loads(raw or "{}")
    branch = d.get("branch", "")
    v = _origin_verdict(branch)
    if v is None:
        return req._send(400, json.dumps({"ok": False, "err": "no such branch"}))
    if not v["ok"]:
        return req._send(200, json.dumps({"ok": False, "err": "; ".join(v["reasons"]), "verdict": v}))
    # plain push — no --force under any circumstance; the pre-push hook still runs
    # underneath as the last net (WIP trailers, merge commits, deploy-critical gap).
    r = ctx.run(["git", "push", "origin", branch])
    ok = r.returncode == 0
    req._send(200, json.dumps({
        "ok": ok,
        "remote": "origin",
        "web": v["web"],
        "out": (r.stdout or "").strip(),
        "err": (r.stderr or "").strip(),
    }))
