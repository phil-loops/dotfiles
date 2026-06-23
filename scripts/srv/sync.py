# srv/sync.py — fork-staleness (the "N behind" badge) + the unpublished-root sync.
#   GET  /sync?branch=X    one branch's staleness vs origin/main
#   GET  /syncs?branch=…   batch staleness for many branches in one round-trip
#   POST /sync {branch}    rebase an unpublished root onto fresh origin/main
import json
import os
import re
import time
import threading
from urllib.parse import parse_qs
from concurrent.futures import ThreadPoolExecutor

from . import ctx


# ── deploy-critical detection (read-only) ────────────────────────────────────
# The exact pathspecs the loops pre-push hook rejects on, parsed FROM that hook so the
# viewer's "push blocked" badge can never drift from what actually blocks a push.
_GLOBS = None


def _deploy_critical_globs():
    global _GLOBS
    if _GLOBS is not None:
        return _GLOBS
    fallback = ["k8s/charts/loops/values.staging.yaml", "k8s/charts/loops/values.production.yaml",
                "packages/prisma/migrations/*", "clickhouse/migrations/*", "jobs.ts",
                "jobs/index.ts", ".env.template"]
    try:
        hook = os.path.expanduser("~/.dotfiles/hooks/loops-pre-push")
        globs, grab = [], False
        for ln in open(hook):
            if "deploy-critical" in ln.lower():
                grab = True
                continue
            if grab:
                globs += re.findall(r"'([^']+)'", ln)
                if "2>/dev/null" in ln:
                    break
        _GLOBS = globs or fallback
    except Exception:
        _GLOBS = fallback
    return _GLOBS


def _deploy_critical(branch):
    """Deploy-critical files origin/main changed that this branch is missing — mirrors the
    pre-push hook's `git diff <ref>..origin/main -- <globs>` exactly (read-only)."""
    globs = _deploy_critical_globs()
    out = ctx.run(["git", "diff", f"{branch}..origin/main", "--name-only", "--", *globs]).stdout
    return [f for f in out.splitlines() if f.strip()]


# ── published = has an OPEN PR (on the fork; origin=Loops-so has none) ────────
_PR_TTL = 30.0
_pr_cache = {"at": -1e9, "heads": set()}
_pr_lock = threading.Lock()


def _open_pr_heads():
    """Branch names with an OPEN PR. PRs live on the phil-loops fork (gh's default
    origin=Loops-so returns none), so query the repo derived from the phil-loops remote.
    Cached ~30s + locked so the 8-way /syncs batch fires at most one gh call."""
    if time.monotonic() - _pr_cache["at"] < _PR_TTL:
        return _pr_cache["heads"]
    with _pr_lock:
        if time.monotonic() - _pr_cache["at"] < _PR_TTL:
            return _pr_cache["heads"]
        try:
            url = ctx.run(["git", "remote", "get-url", "phil-loops"]).stdout.strip()
            m = re.search(r"[:/]([^/:]+/[^/]+?)(?:\.git)?$", url)
            repo = m.group(1) if m else "phil-loops/loops"
            out = ctx.run(["gh", "pr", "list", "-R", repo, "--state", "open",
                           "--json", "headRefName", "--limit", "300"]).stdout
            _pr_cache["heads"] = {pr["headRefName"] for pr in json.loads(out or "[]")}
        except Exception:
            pass  # keep last-good heads on a transient gh failure
        _pr_cache["at"] = time.monotonic()
    return _pr_cache["heads"]


def state(branch):
    """Fork-staleness of a branch vs origin/main — the signal behind the viewer's
    "N behind" badge.
      behind    — commits on origin/main not yet in this branch (two-dot count,
                  `git rev-list --count <branch>..origin/main`). >0 means the fork
                  point is stale, so GitHub-Desktop two-dot diffs inflate by ~this.
      syncable  — safe to auto-rebase onto origin/main with NO force-push. True
                  only for a root off main (parent==main) that is unpublished (no
                  remote-tracking ref). Rebasing a *published* branch rewrites
                  pushed commits (→ force-push); rebasing a *stacked* branch
                  detaches it from its parent (→ that's a restack, not a sync).
                  Neither is offered here — `why` explains the refusal.
    Pure inspection: no fetch, no mutation."""
    if not branch:
        return {"branch": "", "behind": 0, "syncable": False, "why": "no branch"}
    raw = ctx.run(["git", "rev-list", "--count", f"{branch}..origin/main"]).stdout.strip()
    try:
        behind = int(raw)
    except ValueError:
        behind = 0   # origin/main absent or bad ref → treat as up-to-date (no badge)
    parent = ctx.run(["git", "config", f"stack-branch.{branch}.parent"]).stdout.strip() or "main"
    # published = has an OPEN PR (Phil's rule: only an open PR counts, not a bare remote ref).
    published = branch in _open_pr_heads()
    why = ""
    if behind == 0:
        why = "up to date with origin/main"
    elif parent != "main":
        why = f"stacked on {parent} — needs a restack, not a sync"
    elif published:
        why = "has an open PR — rebase would rewrite pushed commits"
    return {"branch": branch, "behind": behind, "parent": parent, "published": published,
            "syncable": behind > 0 and parent == "main" and not published,
            "deployCritical": _deploy_critical(branch) if behind > 0 else [], "why": why}


def get_one(req, u):
    req._send(200, json.dumps(state(parse_qs(u.query).get("branch", [""])[0])))


def get_many(req, u):
    # BATCH fork-staleness: all branches in ONE round-trip, so the graph/rail badges
    # don't fan out N per-node /sync requests into the browser's ~6-connection-per-
    # origin limit (which serializes them into a load waterfall).
    bs = [b for b in parse_qs(u.query).get("branch", []) if b]
    with ThreadPoolExecutor(max_workers=8) as ex:   # state() shells git (GIL released) → real parallelism
        states = dict(zip(bs, ex.map(state, bs)))
    req._send(200, json.dumps(states))


# ── direct forward-rebase (the clean fast path) ──────────────────────────────
# A syncable root that's behind a CLEAN main rebases in one shot — replaying it onto
# origin/main almost never conflicts, so spinning up a whole Claude session for it is
# overkill. We do the `git rebase origin/main` ourselves, but NEVER in the server's main
# checkout (that wedged main): only in the branch's own clean worktree, or a dedicated
# detached scratch worktree when the branch isn't checked out anywhere. Conflicts /
# unsafe layouts fall back to the Claude eject below.
def _worktree_of(branch):
    out = ctx.run(["git", "worktree", "list", "--porcelain"]).stdout
    cur = ""
    for line in out.splitlines():
        if line.startswith("worktree "):
            cur = line[len("worktree "):]
        elif line == f"branch refs/heads/{branch}":
            return cur
    return ""


def _clean(wt):
    return not ctx.run(["git", "-C", wt, "status", "--porcelain"]).stdout.strip()


def _scratch_wt():
    # dedicated detached scratch worktree for rebasing un-checked-out branches — separate
    # from restack's .loops-restack-wt so the two never fight over one worktree. Reused.
    path = os.path.join(os.path.dirname(ctx.MAIN_WT) or ".", ".loops-sync-wt")
    listing = ctx.run(["git", "worktree", "list", "--porcelain"]).stdout
    if not any(os.path.realpath(line[len("worktree "):]) == os.path.realpath(path)
               for line in listing.splitlines() if line.startswith("worktree ")):
        ctx.run(["git", "worktree", "add", "--detach", path, "HEAD"])
    return path


def _direct_rebase(branch):
    """Try `git rebase origin/main` for `branch` in an isolated worktree (assumes
    origin/main is already fetched). Returns (status, summary):
      'clean'    — landed; branch ref moved. summary = what replayed.
      'conflict' — hit a conflict; aborted + restored. → caller ejects to Claude.
      'skip'     — no safe in-place worktree (branch in the main checkout, or its
                   worktree is dirty). → caller ejects to Claude.
    """
    main = os.path.realpath(ctx.MAIN_WT)
    wt = _worktree_of(branch)
    own = False  # did we borrow the branch into the scratch worktree?
    if wt and os.path.realpath(wt) != main and _clean(wt):
        target = wt
    elif not wt:
        target = _scratch_wt()
        if ctx.run(["git", "-C", target, "checkout", branch]).returncode != 0:
            return "skip", ""
        own = True
    else:
        return "skip", ""
    reb = ctx.run(["git", "-C", target, "rebase", "origin/main"])
    if reb.returncode != 0:
        ctx.run(["git", "-C", target, "rebase", "--abort"])
        if own:
            ctx.run(["git", "-C", target, "checkout", "--detach"])
        return "conflict", ""
    n = ctx.run(["git", "-C", target, "rev-list", "--count", "origin/main..HEAD"]).stdout.strip()
    if own:
        ctx.run(["git", "-C", target, "checkout", "--detach"])  # release the branch
    return "clean", f"replayed {n} commit{'' if n == '1' else 's'} onto origin/main"


def _eject(branch):
    # Fallback: hand the rebase to a standalone Claude in the branch's OWN worktree — it
    # resolves conflicts in isolation and does NOT push or open a PR (Phil handles that).
    prompt = (
        f"Rebase the branch `{branch}` forward onto the latest origin/main, here in this "
        f"worktree. Run `git fetch origin main` then `git rebase origin/main`. Resolve any "
        f"conflicts — check with me on real logic overlaps rather than guessing. Do NOT push "
        f"and do NOT open a PR; leave pushing to me. When done, summarize what replayed and "
        f"any conflicts you resolved."
    )
    r = ctx.run([os.path.join(ctx.SCRIPTS, "stack-claude"), branch, prompt])
    ok = r.returncode == 0
    return ok, ("" if ok else (r.stderr or r.stdout or "could not launch rebase session"))


def post_sync(req, raw):
    branch = json.loads(raw or "{}").get("branch", "")
    if not branch:
        req._send(400, json.dumps({"ok": False, "err": "no branch"}))
        return
    ctx.run(["git", "fetch", "origin", "main"])   # fresh origin/main before gating + rebasing
    st = state(branch)   # re-check server-side: never rebase a published/stacked branch on a stale client view
    if not st.get("syncable"):
        req._send(409, json.dumps({"ok": False, "err": st.get("why", "not syncable")}))
        return
    status, summary = _direct_rebase(branch)
    if status == "clean":
        req._send(200, json.dumps({"ok": True, "rebased": True, "summary": summary}))
        return
    # conflict or unsafe-to-rebase-in-place → eject to a standalone Claude.
    ok, err = _eject(branch)
    req._send(200 if ok else 500, json.dumps(
        {"ok": ok, "ejected": ok, "conflict": status == "conflict",
         "err": "" if ok else (err or "could not launch rebase session")}))
