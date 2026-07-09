# srv/sync.py — fork-staleness (the "N behind" badge) + the unpublished-root sync.
#   GET  /sync?branch=X    one branch's staleness vs origin/main
#   GET  /syncs?branch=…   batch staleness for many branches in one round-trip
#   POST /sync {branch}    rebase an unpublished root onto fresh origin/main
import json
import os
import re
import time
import subprocess
import tempfile
import threading
from urllib.parse import parse_qs
from concurrent.futures import ThreadPoolExecutor

from . import ctx
from . import prompts
from . import rebase


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
    """Branch names with an OPEN PR, unioned across ORIGIN and the phil-loops fork —
    Phil's real PRs live on origin (Loops-so), the fork is the automation surface;
    missing either side lets prep/squash rewrite a published branch (bit us on #9405).
    Cached ~30s + locked so the 8-way /syncs batch fires at most one gh sweep."""
    if time.monotonic() - _pr_cache["at"] < _PR_TTL:
        return _pr_cache["heads"]
    with _pr_lock:
        if time.monotonic() - _pr_cache["at"] < _PR_TTL:
            return _pr_cache["heads"]
        heads = set()
        got_any = False
        for remote in ("origin", "phil-loops"):
            try:
                url = ctx.run(["git", "remote", "get-url", remote]).stdout.strip()
                m = re.search(r"[:/]([^/:]+/[^/]+?)(?:\.git)?$", url)
                if not m:
                    continue
                out = ctx.run(["gh", "pr", "list", "-R", m.group(1), "--state", "open",
                               "--json", "headRefName", "--limit", "300"]).stdout
                heads |= {pr["headRefName"] for pr in json.loads(out or "[]")}
                got_any = True
            except Exception:
                pass
        if got_any:
            _pr_cache["heads"] = heads   # keep last-good heads on a full gh outage
        _pr_cache["at"] = time.monotonic()
    return _pr_cache["heads"]


def _shared(branch):
    """Local-vs-shared vs origin: "local" (never pushed — the team can't see it),
    "ahead" (origin's copy is N commits behind), "synced", or "gone" (deleted on
    origin after merge). Reads the last fetch's refs — no network."""
    if ctx.run(["git", "rev-parse", "--verify", "-q", f"refs/remotes/origin/{branch}"]).returncode == 0:
        raw = ctx.run(["git", "rev-list", "--count", f"origin/{branch}..{branch}"]).stdout.strip()
        try:
            ahead = int(raw)
        except ValueError:
            ahead = 0
        return ("ahead" if ahead else "synced"), ahead
    track = ctx.run(["git", "for-each-ref", f"refs/heads/{branch}", "--format=%(upstream:track)"]).stdout.strip()
    return ("gone" if track == "[gone]" else "local"), 0


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
      shared    — local-vs-origin visibility (see _shared), with aheadOfOrigin
                  the commit count origin's copy lacks.
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
    proj = ctx.run(["git", "config", f"stack-branch.{branch}.project"]).stdout.strip()
    # A stacked branch behind main can't forward-rebase alone, but its PROJECT can — sync
    # delegates those to the restack machine instead of shrugging (the button leads to the
    # rebase and executes it).
    restack = behind > 0 and parent != "main" and bool(proj) and not published
    why = ""
    if behind == 0:
        why = "up to date with origin/main"
    elif restack:
        why = f"stacked on {parent} — sync restacks {proj} onto origin/main"
    elif parent != "main":
        why = f"stacked on {parent} with no project tag — restack it by hand"
    elif published:
        why = "has an open PR — rebase would rewrite pushed commits"
    shared, ahead = _shared(branch)
    # working-tree dirt of the worktree HOLDING this branch (incl. untracked — clean-tree
    # guards trip on those too). Dirt is per-worktree state; it ambushes whatever branch
    # the checkout holds, which is why it rides the branch payload.
    dirty, dirty_wt = [], ""
    wt_path, cur = None, None
    for ln in ctx.run(["git", "worktree", "list", "--porcelain"]).stdout.splitlines():
        if ln.startswith("worktree "):
            cur = ln[len("worktree "):]
        elif ln.startswith("branch ") and ln[len("branch "):].replace("refs/heads/", "", 1) == branch:
            wt_path = cur
    if wt_path:
        st = ctx.run(["git", "-C", wt_path, "status", "--porcelain"]).stdout.splitlines()
        dirty = [l[3:].split(" -> ", 1)[-1].strip().strip('"') for l in st if len(l) > 3][:20]
        dirty_wt = wt_path if dirty else ""
    return {"branch": branch, "behind": behind, "parent": parent, "published": published,
            "syncable": behind > 0 and parent == "main" and not published,
            "restack": restack, "project": proj,
            "shared": shared, "aheadOfOrigin": ahead,
            "dirty": dirty, "dirtyWorktree": dirty_wt,
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


_TRUNK_FETCH_AT = 0.0
_TRUNK_FETCH_LOCK = threading.Lock()

# `stack-forest --pr-state` is a live `gh pr list --state all --limit 300` — ~5s over a few hundred
# PRs, and health_many runs it on EVERY forest open (its cost grows with total PR count, not the
# forest's node count). PR state drifts on the order of minutes, so cache it stale-while-revalidate
# like stack-prs does: a fresh entry serves with no gh call, a stale one serves immediately and
# refreshes in the background, only a cold cache blocks once. Matches the 45s trunk-fetch throttle.
_PR_STATE_TTL = 120
_PR_STATE = {"at": 0.0, "data": None}
_PR_STATE_LOCK = threading.Lock()
_PR_STATE_REFRESHING = False


def _fetch_pr_state():
    r = ctx.run([os.path.join(ctx.SCRIPTS, "stack-forest"), "--pr-state"])
    if r.returncode != 0:
        return None
    try:
        return json.loads(r.stdout or "{}")
    except ValueError:
        return None


def _refresh_pr_state():
    global _PR_STATE_REFRESHING
    try:
        fresh = _fetch_pr_state()
        if fresh is not None:
            with _PR_STATE_LOCK:
                _PR_STATE["data"], _PR_STATE["at"] = fresh, time.time()
    finally:
        _PR_STATE_REFRESHING = False


def _pr_state_map():
    global _PR_STATE_REFRESHING
    now = time.time()
    with _PR_STATE_LOCK:
        data = _PR_STATE["data"]
        if data is not None:
            if now - _PR_STATE["at"] >= _PR_STATE_TTL and not _PR_STATE_REFRESHING:
                _PR_STATE_REFRESHING = True
                threading.Thread(target=_refresh_pr_state, daemon=True).start()
            return data
    # cold cache: block once to populate (fetch outside the lock so other endpoints don't wait)
    fresh = _fetch_pr_state()
    with _PR_STATE_LOCK:
        if fresh is not None:
            _PR_STATE["data"], _PR_STATE["at"] = fresh, time.time()
        elif _PR_STATE["data"] is None:
            _PR_STATE["data"] = {}  # cache empty on gh failure so we don't re-block every call
        return _PR_STATE["data"]


def _trunk(main):
    # merged-detection must compare against the REMOTE trunk: a squash-merge lands on
    # origin/<main>, while local `main` stays stale until it's fast-forwarded — so
    # comparing against local main silently misses anything merged upstream (the "merged
    # on origin but local doesn't know" bug). Prefer origin/<main>; fall back to local.
    remote = f"origin/{main}"
    if ctx.run(["git", "rev-parse", "--verify", "-q", remote]).returncode == 0:
        return remote
    return main


def _freshen_trunk(main):
    # Keep origin/<main> loosely fresh so a PR that merged upstream surfaces as a ghost on
    # a plain page load, without a manual "↻ check origin". Throttled + backgrounded: at
    # most one fetch per 45s, never blocks the health response (this load sees whatever's
    # already fetched; the next one sees the merge).
    global _TRUNK_FETCH_AT
    now = time.time()
    with _TRUNK_FETCH_LOCK:
        if now - _TRUNK_FETCH_AT < 45:
            return
        _TRUNK_FETCH_AT = now
    threading.Thread(
        target=lambda: ctx.run(["git", "fetch", "origin", main]), daemon=True
    ).start()


def _upstream_state(branch, main):
    # Surface a tracking ref that will bite a plain Pull/Push. A stacked branch should
    # track origin/<itself> (or nothing) — never origin/<main> (the autoSetupMerge trap)
    # or a differently-named remote (rename drift); both make GitHub Desktop's Pull MERGE
    # the wrong ref into the branch. Also flag a genuine ahead+behind divergence. Unset
    # upstream is the safe state (nothing to pull-merge), so it's never flagged.
    r = ctx.run(["git", "rev-parse", "--abbrev-ref", f"{branch}@{{upstream}}"])
    up = r.stdout.strip() if r.returncode == 0 else ""
    if not up:
        return {"upstream": "", "upstreamBad": False, "upstreamReason": "",
                "diverged": False, "ahead": 0, "behind": 0}
    remote = ctx.run(["git", "config", f"branch.{branch}.remote"]).stdout.strip()
    up_branch = up[len(remote) + 1:] if remote and up.startswith(remote + "/") else up
    bad = up_branch == main
    ahead = int(ctx.run(["git", "rev-list", "--count", f"{up}..{branch}"]).stdout.strip() or 0)
    behind = int(ctx.run(["git", "rev-list", "--count", f"{branch}..{up}"]).stdout.strip() or 0)
    # Two distinct footguns the badge surfaces:
    #   bad      — tracks the TRUNK: a Pull merges main into the branch (autoSetupMerge trap).
    #   diverged — tracks its OWN (non-trunk) pushed PR head but history was rewritten on one
    #              side (ahead AND behind ⇒ no fast-forward): a Pull re-merges the stale pre-
    #              rebase commits, a Push needs --force. The post-rebase PR-head case. We used
    #              to stay silent here ("Phil's renamed-PR flow"), but a clean rebase forward
    #              looks identical to a stale fork — so offer a Claude reconcile instead of
    #              letting GitHub Desktop tempt a destructive Pull. A branch merely ahead
    #              (behind == 0, an unpushed push) fast-forwards cleanly and is NOT flagged.
    diverged = (not bad) and ahead > 0 and behind > 0
    reason = f"tracks {up} (the trunk) — a Pull would merge main into this branch" if bad else ""
    return {"upstream": up, "upstreamBad": bad, "upstreamReason": reason,
            "diverged": diverged, "ahead": ahead, "behind": behind}


# rebase-classify (the PR-less merged-detection fallback) is a ~0.3s trial rebase, and health_many
# runs it per PR-less node on every forest open AND every 15s the docked map re-polls. Its result is
# a pure function of the branch tip and the trunk tip, so memoize on (branch_sha, trunk_sha): a
# forest with no new commits re-reads instantly, and any moved branch / advanced main busts its own
# key — it can never go stale wrongly. Tiny (one bool per distinct sha pair); cleared if it ever grows.
_MERGED_CACHE = {}
_MERGED_LOCK = threading.Lock()


def _merged_prless(branch, trunk):
    """Cached rebase-classify exit-20 (already-merged) for a PR-less branch vs the remote trunk."""
    key = tuple(ctx.run(["git", "rev-parse", branch, trunk]).stdout.split())
    if len(key) == 2:
        with _MERGED_LOCK:
            if key in _MERGED_CACHE:
                return _MERGED_CACHE[key]
    merged = ctx.run(
        [os.path.join(ctx.SCRIPTS, "rebase-classify"), branch, trunk]).returncode == 20
    if len(key) == 2:
        with _MERGED_LOCK:
            if len(_MERGED_CACHE) > 2000:
                _MERGED_CACHE.clear()
            _MERGED_CACHE[key] = merged
    return merged


def _node_health(branch, pr=None):
    """Forest-STRUCTURAL health (vs. state()'s fork-staleness):
      drifted — the node's configured parent is NOT a git ancestor, so it sits off the parent's
                tip and its parent...node diff balloons to ≈ main...node (the misleading 'looks
                like the main diff' case).
      merged  — the node's work already landed. AUTHORITATIVE from GitHub when the branch has a
                PR (`pr.state == MERGED`); falls back to rebase-classify exit 20 (local patch-id
                trial vs the REMOTE trunk) only for PR-less branches. GitHub is the source of
                truth — a squash-merge is invisible to local git by sha, so the local check is
                just the fallback.
      pr      — the live GitHub PR {number,state,draft,url,review} or None.
    Read-only page-load signals; the fix for both is a restack (contracts ghosts, rebases drift)."""
    if not branch:
        return {"branch": "", "drifted": False, "merged": False, "parent": "", "pr": None}
    main = ctx.run(["git", "config", "stack.main-branch"]).stdout.strip() or "main"
    parent = ctx.run(["git", "config", f"stack-branch.{branch}.parent"]).stdout.strip() or main
    drifted = parent != main and ctx.run(
        ["git", "merge-base", "--is-ancestor", parent, branch]).returncode != 0
    trunk = _trunk(main)
    if pr is not None:
        merged = pr.get("state") == "MERGED"
    else:
        merged = _merged_prless(branch, trunk)
    # contractable = droppable RIGHT NOW (rebase-classify exit 20: every remaining commit is
    # patch-identical to trunk). A merged PR with a follow-on commit reads merged=True but is
    # NOT contractable — /contract refuses it. The badge keys its verb off this, not merged.
    contractable = bool(_merged_prless(branch, trunk)) if merged else False
    return {"branch": branch, "drifted": bool(drifted), "merged": bool(merged),
            "contractable": contractable, "parent": parent,
            "pr": pr, **_upstream_state(branch, main)}


def health_many(req, u):
    # BATCH forest-structural health for the model's nodes, parallel like get_many — the viewer
    # overlays drifted/ghost badges + a "fix all" (restack) when anything's off.
    bs = [b for b in parse_qs(u.query).get("branch", []) if b]
    _freshen_trunk(ctx.run(["git", "config", "stack.main-branch"]).stdout.strip() or "main")
    # Authoritative PR state from GitHub, served from a stale-while-revalidate cache (see
    # _pr_state_map) so a forest open doesn't block ~5s on gh every time; GitHub is the source of
    # truth for "merged?", rebase-classify is only the PR-less fallback.
    pr_map = _pr_state_map()
    with ThreadPoolExecutor(max_workers=8) as ex:
        out = dict(zip(bs, ex.map(lambda b: _node_health(b, pr_map.get(b)), bs)))
    req._send(200, json.dumps(out))


def fix_upstream(req, raw):
    # Neutralize a footgun tracking ref: unset the branch's upstream so a Pull/Push can no
    # longer merge the wrong remote in. Config-only, non-destructive — the branch keeps all
    # its commits and can be published cleanly later. GitHub Desktop then offers "Publish"
    # instead of a dangerous "Pull".
    d = json.loads(raw or "{}")
    branch = d.get("branch", "")
    if not branch:
        req._send(400, json.dumps({"ok": False, "err": "no branch"}))
        return
    r = ctx.run(["git", "branch", "--unset-upstream", branch])
    if r.returncode != 0:
        req._send(200, json.dumps({"ok": False, "err": (getattr(r, "stderr", "") or "no upstream to unset").strip()}))
        return
    req._send(200, json.dumps({"ok": True, "branch": branch}))


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


def _eject_worktree(branch):
    # Build the branch's worktree the same way stack-open/stack-claude do, then resolve its path
    # (a real worktree holding the branch wins, else the scratch dir stack-open lays down) so the
    # headless rebase runs exactly where the interactive one used to.
    ctx.run([os.path.join(ctx.SCRIPTS, "stack-open"), "--prepare", branch])
    wt = _worktree_of(branch)
    if wt:
        return wt
    scratch = os.environ.get("STACK_OPEN_DIR", "/tmp/stack-study")
    return os.path.join(scratch, branch.replace("/", "_"))


def _eject(branch):
    # A real conflict / unsafe layout → hand the rebase to a headless claude in the branch's OWN
    # worktree, STREAMED (srv/rebase). It resolves conflicts in isolation and does NOT push or
    # open a PR (Phil handles that). Returns (ok, stream_key) — the key the client tails over SSE.
    prompt = (
        f"Rebase the branch `{branch}` forward onto the latest origin/main, here in this "
        f"worktree. Run `git fetch origin main` then `git rebase origin/main`. Resolve any "
        f"conflicts — check with me on real logic overlaps rather than guessing. Do NOT push "
        f"and do NOT open a PR; leave pushing to me. When done, summarize what replayed and "
        f"any conflicts you resolved."
    )
    try:
        cwd = _eject_worktree(branch)
        key = rebase.start(branch, cwd, prompt)
        return True, key
    except Exception as e:
        return False, str(e)[:400]


def _children_of(branch):
    out = ctx.run(["git", "config", "--get-regexp", r"^stack-branch\..*\.parent$"]).stdout
    kids = []
    for line in out.splitlines():
        key, _, val = line.partition(" ")
        if val.strip() == branch:
            kids.append(key[len("stack-branch."):-len(".parent")])
    return kids


def _already_merged(branch):
    """rebase-classify exit 20 == already-merged (squash/ff): its work is in origin/main,
    a forward rebase replays nothing. Non-destructive probe; origin/main assumed fetched."""
    rc = ctx.run([os.path.join(ctx.SCRIPTS, "rebase-classify"), branch, "origin/main"]).returncode
    return rc == 20


def _requirers_of(branch):
    out = ctx.run(["git", "config", "--get-regexp", r"^stack-branch\..*\.requires$"]).stdout
    deps = []
    for line in out.splitlines():
        key, _, val = line.partition(" ")
        if val.strip() == branch:
            deps.append(key[len("stack-branch."):-len(".requires")])
    return deps


def _contract(branch):
    """Drop an already-merged branch and rewire its dependents onto its parent (== main for a
    syncable root). Deterministic mirror of the manual contraction. Returns (children, deps, parent):
    `children` are branches parented on it (line moves up); `deps` fan it in via `requires` and now
    inherit its work from main, so that edge is dropped. Caller MUST have confirmed _already_merged
    first — this never re-checks."""
    parent = ctx.run(["git", "config", f"stack-branch.{branch}.parent"]).stdout.strip() or "main"
    base = ctx.run(["git", "rev-parse", "origin/main"]).stdout.strip()
    esc = "^" + branch.replace(".", r"\.") + "$"
    kids = _children_of(branch)
    for k in kids:
        ctx.run(["git", "config", f"stack-branch.{k}.parent", parent])
        ctx.run(["git", "config", f"stack-branch.{k}.base", base])
    # Fan-in dependents: the required base landed in main, so the edge is now redundant — drop it,
    # else the integrator carries a `requires` pointing at a branch that no longer exists.
    deps = _requirers_of(branch)
    for d in deps:
        ctx.run(["git", "config", "--unset", f"stack-branch.{d}.requires", esc])
    wt = _worktree_of(branch)
    if wt:
        ctx.run(["git", "-C", wt, "checkout", "--detach"])   # release so branch -D can run
    ctx.run(["git", "branch", "-D", branch])
    proj = ctx.run(["git", "config", f"stack-branch.{branch}.project"]).stdout.strip()
    for key in ("parent", "project", "base"):
        ctx.run(["git", "config", "--unset", f"stack-branch.{branch}.{key}"])
    if proj:
        ctx.run(["git", "config", "--unset", f"stack-project.{proj}.branch", esc])
    return kids, deps, parent


def post_sync(req, raw):
    branch = json.loads(raw or "{}").get("branch", "")
    if not branch:
        req._send(400, json.dumps({"ok": False, "err": "no branch"}))
        return
    ctx.run(["git", "fetch", "origin", "main"])   # fresh origin/main before gating + rebasing
    st = state(branch)   # re-check server-side: never rebase a published/stacked branch on a stale client view
    if not st.get("syncable"):
        if st.get("restack"):   # stacked chain behind main → the restack machine owns this rebase
            req._send(200, json.dumps({"ok": True, "restack": True, "project": st.get("project", "")}))
            return
        req._send(409, json.dumps({"ok": False, "err": st.get("why", "not syncable")}))
        return
    status, summary = _direct_rebase(branch)
    if status == "clean":
        req._send(200, json.dumps({"ok": True, "rebased": True, "summary": summary}))
        return
    # A replay conflict can mean the branch already squash-merged to main — rewiring it is
    # wrong; it should be CONTRACTED. Surface a Phil-driven drop, not a Claude grinding it.
    if status == "conflict" and _already_merged(branch):
        req._send(200, json.dumps(
            {"ok": True, "contract": True, "branch": branch, "children": _children_of(branch)}))
        return
    # genuine conflict or unsafe-to-rebase-in-place → eject to a headless claude, streamed.
    ok, key = _eject(branch)
    req._send(200 if ok else 500, json.dumps(
        {"ok": ok, "ejected": ok, "conflict": status == "conflict",
         "stream": key if ok else "",
         "err": "" if ok else (key or "could not launch rebase session")}))


def post_contract(req, raw):
    branch = json.loads(raw or "{}").get("branch", "")
    if not branch:
        req._send(400, json.dumps({"ok": False, "err": "no branch"}))
        return
    ctx.run(["git", "fetch", "origin", "main"])
    if not _already_merged(branch):
        req._send(409, json.dumps(
            {"ok": False, "err": "not already-merged — refusing to drop a branch with unmerged work"}))
        return
    kids, deps, parent = _contract(branch)
    parts = []
    if kids:
        parts.append(f"rewired {len(kids)} child{'' if len(kids) == 1 else 'ren'} onto {parent}")
    if deps:
        parts.append(f"dropped the requires edge on {len(deps)} integrator{'' if len(deps) == 1 else 's'}")
    summary = f"dropped {branch}" + (f"; {', '.join(parts)}" if parts else " (no dependents)")
    req._send(200, json.dumps(
        {"ok": True, "contracted": True, "branch": branch, "children": kids,
         "deps": deps, "parent": parent, "summary": summary}))


def post_reconcile(req, raw):
    # A branch diverged from its pushed PR head (rebased on one side) → hand it to a standalone
    # Claude in the branch's OWN worktree to work out which side is the source of truth and
    # reconcile. Mirrors _eject's contract: never force-pushes, never blind-pulls the stale head
    # back in — publishing stays Phil's. Almost always local was rebased and already wins, so the
    # session resolves it without back-and-forth.
    branch = json.loads(raw or "{}").get("branch", "")
    if not branch:
        req._send(400, json.dumps({"ok": False, "err": "no branch"}))
        return
    up = ctx.run(["git", "rev-parse", "--abbrev-ref", f"{branch}@{{upstream}}"]).stdout.strip()
    if not up:
        req._send(409, json.dumps({"ok": False, "err": "no upstream to reconcile against"}))
        return
    ahead = int(ctx.run(["git", "rev-list", "--count", f"{up}..{branch}"]).stdout.strip() or 0)
    behind = int(ctx.run(["git", "rev-list", "--count", f"{branch}..{up}"]).stdout.strip() or 0)
    r = ctx.run([os.path.join(ctx.SCRIPTS, "stack-claude"), branch,
                 prompts.reconcile(branch, up, ahead, behind)])
    ok = r.returncode == 0
    req._send(200 if ok else 500, json.dumps(
        {"ok": ok, "ejected": ok,
         "err": "" if ok else (r.stderr or r.stdout or "could not launch reconcile session")}))


def _patch_ids(range_spec):
    # sha → patch-id for every commit in range_spec. Content-stable across rebases, so a
    # rewritten commit matches its pre-rewrite twin even though the shas differ.
    shas = ctx.run(["git", "rev-list", range_spec]).stdout
    if not shas.strip():
        return {}
    cwd = ctx.repo_cwd()
    diffs = subprocess.run(["git", "diff-tree", "--stdin", "-p"], input=shas,
                           cwd=cwd, capture_output=True, text=True).stdout
    pids = subprocess.run(["git", "patch-id", "--stable"], input=diffs,
                          cwd=cwd, capture_output=True, text=True).stdout
    out = {}
    for line in pids.splitlines():
        parts = line.split()
        if len(parts) == 2:
            out[parts[1]] = parts[0]
    return out


def diverged_detail(req, u):
    # GET /diverged-detail?branch=X — what a ⇄ divergence actually IS, framed the way GitHub
    # Desktop (and the PR page) frames it: each side's commits with patch-id twins flagged, a
    # containment verdict, and the PR-DIFF comparison — what origin's review diff (trunk...head)
    # shows today vs what it becomes after pushing local. Tip-to-tip diffs are deliberately NOT
    # shown: after a restack they're dominated by main's advance, which reads as phantom churn.
    branch = (parse_qs(u.query).get("branch", [""]) or [""])[0]
    if not branch:
        req._send(400, json.dumps({"ok": False, "err": "no branch"}))
        return
    r = ctx.run(["git", "rev-parse", "--abbrev-ref", f"{branch}@{{upstream}}"])
    up = r.stdout.strip() if r.returncode == 0 else ""
    if not up:
        req._send(404, json.dumps({"ok": False, "err": f"{branch} has no upstream"}))
        return
    trunk = _trunk(ctx.run(["git", "config", "stack.main-branch"]).stdout.strip() or "main")

    def commits(range_spec):
        out = []
        for line in ctx.run(["git", "log", "--format=%H\t%s", range_spec]).stdout.splitlines():
            sha, _, subj = line.partition("\t")
            if sha:
                out.append({"full": sha, "sha": sha[:9], "subject": subj})
        return out

    ahead, behind = commits(f"{up}..{branch}"), commits(f"{branch}..{up}")
    a_ids, b_ids = _patch_ids(f"{up}..{branch}"), _patch_ids(f"{branch}..{up}")
    a_set, b_set = set(a_ids.values()), set(b_ids.values())
    for c in ahead:
        # a restacked branch carries trunk commits the pushed head predates — label them as
        # main's advance, not this branch's new work (they'd read as phantom local commits).
        c["fromMain"] = ctx.run(["git", "merge-base", "--is-ancestor", c["full"], trunk]).returncode == 0
        c["matched"] = a_ids.get(c.pop("full"), "") in b_set
    for c in behind:
        c["matched"] = b_ids.get(c.pop("full"), "") in a_set
    # Containment, tiered. Per-commit patch-ids only match a pure rebase; Phil's prep-to-merge
    # SQUASHES (4 pushed commits -> 1 local), so also try an in-memory merge of the pushed head
    # into local: same tree -> everything's already here; clean but different -> real remote-only
    # additions; conflicts -> both sides changed the same regions (the file list names them).
    if behind and all(c["matched"] for c in behind):
        containment, overlap = "rebase", []
    else:
        mt = subprocess.run(["git", "merge-tree", "--write-tree", branch, up],
                            cwd=ctx.repo_cwd(), capture_output=True, text=True)
        if mt.returncode == 0:
            local_tree = ctx.run(["git", "rev-parse", f"{branch}^{{tree}}"]).stdout.strip()
            containment = "contained" if mt.stdout.split("\n", 1)[0].strip() == local_tree else "clean-extra"
            overlap = []
        else:
            seen = set()
            for line in mt.stdout.splitlines()[1:]:
                parts = line.split("\t")
                if len(parts) == 2 and parts[0].count(" ") == 2:   # "mode sha stage\tpath" rows
                    seen.add(parts[1])
            containment, overlap = "overlap", sorted(seen)[:30]

    # The PR view: origin's review diff is trunk...head (three-dot, GitHub's own framing).
    # "now" = against the pushed head; "after" = against local, i.e. what a push makes it.
    def numstat(range_spec):
        out = {}
        for line in ctx.run(["git", "diff", "--numstat", range_spec]).stdout.splitlines():
            parts = line.split("\t")
            if len(parts) == 3:
                out[parts[2]] = (parts[0], parts[1])
        return out

    def shortstat(range_spec):
        return ctx.run(["git", "diff", "--shortstat", range_spec]).stdout.strip()

    now_files, after_files = numstat(f"{trunk}...{up}"), numstat(f"{trunk}...{branch}")
    pr_files = []
    for path in sorted(set(now_files) | set(after_files)):
        n, a = now_files.get(path), after_files.get(path)
        if n and a:
            status = "same" if n == a else "changed"
        else:
            status = "enters" if a else "leaves"
        pr_files.append({"path": path, "status": status,
                         "now": n and f"+{n[0]} −{n[1]}", "after": a and f"+{a[0]} −{a[1]}"})
    req._send(200, json.dumps({
        "ok": True, "upstream": up, "trunk": trunk, "ahead": ahead, "behind": behind,
        "containment": containment, "overlap": overlap,
        "prNow": shortstat(f"{trunk}...{up}"), "prAfter": shortstat(f"{trunk}...{branch}"),
        "prFiles": pr_files[:60]}))


def _draft_additive_message(branch, diff_text):
    # One opt-in claude pass (mirrors merge_subjects): draft the additive commit's message from
    # the delta actually being carried. Deterministic fallback so the draft never blocks on it.
    purpose = ctx.run(["git", "config", f"branch.{branch}.description"]).stdout.strip()
    prompt = (
        "This diff is an ADDITIVE update commit to an open PR - it lands on top of the "
        "already-reviewed commits, so the message should describe THIS change, not the branch.\n"
        f"Branch purpose: {purpose or '(none)'}\n"
        "Write a git commit message. subject: 'type(scope): ...' - plain language, describe the "
        "behavior in words, NO raw identifiers (function/table names, camelCase tokens), lower-case "
        "first word after the colon, under 60 chars, no trailing period. body: 1-3 plain sentences; "
        "HERE you may name a key function/field if load-bearing. "
        'Return ONLY JSON {"subject": ..., "body": ...}. No prose, no fences.\n\n'
        "DIFF (truncated):\n" + diff_text[:6000]
    )
    r = ctx.run(["claude", "-p", prompt, "--model", "sonnet"])
    text = (r.stdout or "").strip()
    try:
        s, e = text.find("{"), text.rfind("}")
        obj = json.loads(text[s:e + 1]) if 0 <= s < e else {}
        subject = (obj.get("subject") or "").strip().rstrip(".")
        body = (obj.get("body") or "").strip()
        if subject:
            return subject, body
    except ValueError:
        pass
    return (f"refactor: carry local rework onto the pushed head of {branch.rsplit('/', 1)[-1]}",
            "Additive PR update - applies the local branch's content without rewriting history.")


def build_additive(branch):
    """The ADDITIVE resolution for a diverged PR branch: ONE commit on top of the pushed
    head carrying local's PR-frame content, on a <branch>-additive vehicle branch. Never
    pushes; never touches <branch> itself. Returns the report dict — {ok: False, err,
    code} on refusal (code = HTTP status for the endpoint), {ok: True, vehicle, sha,
    shaFull, subject, prAfter, push} on success. Callable from /prep-push routing too."""
    r = ctx.run(["git", "rev-parse", "--abbrev-ref", f"{branch}@{{upstream}}"])
    up = r.stdout.strip() if r.returncode == 0 else ""
    if not up:
        return {"ok": False, "err": f"{branch} has no upstream", "code": 404}
    trunk = _trunk(ctx.run(["git", "config", "stack.main-branch"]).stdout.strip() or "main")
    vehicle = f"{branch}-additive"
    if ctx.run(["git", "rev-parse", "--verify", "--quiet", f"refs/heads/{vehicle}"]).returncode == 0:
        return {"ok": False, "err": f"{vehicle} already exists - push it or delete it first", "code": 409}

    # Frame poisoning: a pushed head carrying trunk's history DUPLICATED under foreign SHAs
    # (a backwards rebase) drags merge-base(trunk, head) into the ancient past, so the PR
    # renders the whole world no matter what lands on top. Additive fixes content divergence
    # only — a poisoned frame needs the head itself rewritten (human force-with-lease).
    dup = sum(1 for l in ctx.run(["git", "cherry", trunk, up]).stdout.splitlines() if l.startswith("-"))
    if dup >= 10:
        mb = ctx.run(["git", "merge-base", trunk, up]).stdout.strip()
        behind = ctx.run(["git", "rev-list", "--count", f"{mb}..{trunk}"]).stdout.strip() if mb else "?"
        return {"ok": False, "code": 409, "poisoned": True,
                "err": f"the pushed head duplicates {dup} of {trunk}'s commits under foreign SHAs "
                       f"(the PR frame's base is {behind} behind {trunk}) — additive can't fix a "
                       f"poisoned frame; rebuild the branch locally, then force-with-lease it yourself"}

    # Only files in either side's PR-frame diff (trunk...head) may enter the commit - restoring
    # whole-tree would drag main's advance into the PR. Restrict to frame paths whose CONTENT
    # actually differs between the two heads (tree diff = blob OIDs; numstat add/del pairs
    # collide on equal counts with different content).
    def frame_paths(head):
        return set(ctx.run(["git", "diff", "--name-only", f"{trunk}...{head}"]).stdout.splitlines())

    differing = set(ctx.run(["git", "diff", "--name-only", up, branch]).stdout.splitlines())
    paths = sorted(p for p in (frame_paths(up) | frame_paths(branch)) if p and p in differing)
    if not paths:
        return {"ok": False, "err": "the PR's content already matches local - nothing to carry", "code": 200}

    tmp = tempfile.mkdtemp(prefix="additive-")
    try:
        r = ctx.run(["git", "worktree", "add", "--detach", tmp, up])
        if r.returncode != 0:
            return {"ok": False, "err": (r.stderr or "worktree add failed").strip()[:300], "code": 500}
        in_branch = [p for p in paths
                     if ctx.run(["git", "cat-file", "-e", f"{branch}:{p}"]).returncode == 0]
        removed = [p for p in paths if p not in in_branch]
        if in_branch:
            r = ctx.run(["git", "-C", tmp, "restore", "--source", branch, "--worktree", "--", *in_branch])
            if r.returncode != 0:
                return {"ok": False, "err": (r.stderr or "restore failed").strip()[:300], "code": 500}
        if removed:
            ctx.run(["git", "-C", tmp, "rm", "-q", "--ignore-unmatch", "--", *removed])
        ctx.run(["git", "-C", tmp, "add", "-A", "--", *paths])
        if ctx.run(["git", "-C", tmp, "diff", "--cached", "--quiet"]).returncode == 0:
            return {"ok": False, "err": "nothing to commit - the PR files already match", "code": 200}
        delta = ctx.run(["git", "-C", tmp, "diff", "--cached"]).stdout
        subject, body = _draft_additive_message(branch, delta)
        r = ctx.run(["git", "-C", tmp, "commit", "-q", "-m", subject + ("\n\n" + body if body else "")])
        if r.returncode != 0:
            return {"ok": False, "err": (r.stderr or "commit failed").strip()[:300], "code": 500}
        sha = ctx.run(["git", "-C", tmp, "rev-parse", "HEAD"]).stdout.strip()
        ctx.run(["git", "branch", vehicle, sha])
        ctx.run(["git", "config", f"branch.{vehicle}.description",
                 f"Additive PR update for {branch}: carries the local rework onto the pushed head as one "
                 f"commit, so origin fast-forwards - no history rewrite. Push vehicle only, not a forest "
                 f"member; delete after pushing."])
        return {
            "ok": True, "vehicle": vehicle, "sha": sha[:10], "shaFull": sha, "subject": subject,
            "prAfter": ctx.run(["git", "diff", "--shortstat", f"{trunk}...{sha}"]).stdout.strip(),
            "push": f"git push origin {vehicle}:{branch}"}
    finally:
        ctx.run(["git", "worktree", "remove", "--force", tmp])


def diverged_additive(req, raw):
    # POST /diverged-additive {branch} - see build_additive; this endpoint is the thin wrapper.
    d = json.loads(raw or "{}")
    branch = (d.get("branch") or "").strip()
    if not branch:
        req._send(400, json.dumps({"ok": False, "err": "no branch"}))
        return
    res = build_additive(branch)
    req._send(res.pop("code", 200), json.dumps(res))
