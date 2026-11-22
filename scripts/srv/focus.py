# srv/focus.py — keep the focus forests on current main without a click.
#
# Every POLL_S the server fetches origin/main. On a trunk move it fast-forwards local main and
# refreshes the gate donor; on every tick it restacks each focus forest that has fallen behind,
# one project at a time, with stack-restack --no-claude in the shared scratch worktree. A forest
# is left alone (and retried next tick) while any of its worktrees is dirty or has a process in
# it, while another restack runs or parks, or while its root is on origin (pushed, PR or not —
# a rebase there would leave the push door refusing a diverged branch). A conflict is
# aborted, never left parked — the forest carries the reason on /projects (`sync`), and is not
# retried until its branches or origin/main move.
#
# Every forest the viewer shows, focus or not, also sheds what landed: a member with a merged PR
# goes with stack-restack --contract-only, which drops it once nothing live sits on it and moves
# no branch. A member whose worktree is busy is held until it frees.
import json
import os
import subprocess
import threading
import time

from . import ctx, forestlock, openprs, repostate, restack, sync, watch

POLL_S = 90
_lock = threading.Lock()


def _state_path():
    return os.path.join(restack._gitdir(), "focus-sync.json")


def _load():
    try:
        with open(_state_path()) as fh:
            return json.load(fh)
    except (OSError, ValueError):
        return {"tip": "", "projects": {}}


def _save(st):
    path = _state_path()
    tmp = f"{path}.{os.getpid()}.tmp"
    with open(tmp, "w") as fh:
        json.dump(st, fh)
    os.replace(tmp, path)


def _git(*args):
    return ctx.run(["git", *args])


def _tip(ref):
    return _git("rev-parse", "-q", "--verify", ref).stdout.strip()


def _projects():
    """Every registered forest outside the archive."""
    snap = repostate.snapshot()   # the config is already in hand: no spawn per forest
    names = sorted({k[len("stack-project."):-len(".branch")] for k in snap.cfg
                    if k.startswith("stack-project.") and k.endswith(".branch") and snap.cfg[k]})
    return [p for p in names if snap.get(f"stack-project.{p}.archived").strip().lower() not in ("true", "yes", "on", "1")]


def _focus_projects():
    out = _git("config", "--name-only", "--get-regexp", r"^stack-project\..*\.focus$").stdout
    return [line[len("stack-project."):-len(".focus")] for line in out.splitlines() if line]


def _members(project):
    """Read fresh, not from the snapshot: a restack this tick just moved the config under it."""
    from stack_members import members
    return members(project, cwd=ctx.repo_cwd())


def _parent(branch):
    return _git("config", f"branch.{branch}.stack-parent").stdout.strip() or "main"


def _behind(branches):
    """Members whose parent tip isn't in their history (a root compares against origin/main)."""
    out = []
    for b in branches:
        p = _parent(b)
        ref = "origin/main" if p == "main" else p
        if _git("merge-base", "--is-ancestor", ref, b).returncode != 0:
            out.append(b)
    return out


def _sig(branches):
    return " ".join([_tip("origin/main")] + [f"{b}={_tip('refs/heads/' + b)}" for b in branches])


def _live_cwds():
    r = subprocess.run(["lsof", "-a", "-d", "cwd", "-Fn"], capture_output=True, text=True)
    return {line[1:] for line in r.stdout.splitlines() if line.startswith("n")}


def _busy(branches, cwds):
    """Why a member's worktree is off-limits: local changes, or a process working in it."""
    for b in branches:
        wt = restack._worktree_of(b)
        if not wt:
            continue
        if _git("-C", wt, "status", "--porcelain", "--untracked-files=no").stdout.strip():
            return f"{b}'s worktree has uncommitted changes"
        if any(c == wt or c.startswith(wt + "/") for c in cwds):
            return f"something is working in {b}'s worktree"
    return ""


def _gh_merged(branch):
    r = subprocess.run(["gh", "pr", "list", "--repo", "Loops-so/loops", "--state", "merged",
                        "--head", branch, "--json", "number", "--jq", "length"],
                       capture_output=True, text=True, cwd=ctx.repo_cwd())
    return r.returncode == 0 and r.stdout.strip() not in ("", "0")


def _ff_main(tip):
    cur = _tip("refs/heads/main")
    if not cur or cur == tip:
        return
    if _git("branch", "-f", "main", tip).returncode == 0:
        ctx.log(f"focus-sync: local main {cur[:9]} → {tip[:9]}")
        return
    wt = restack._worktree_of("main")
    if wt and not _git("-C", wt, "status", "--porcelain", "--untracked-files=no").stdout.strip() \
            and _git("-C", wt, "merge", "--ff-only", "-q", tip).returncode == 0:
        ctx.log(f"focus-sync: local main fast-forwarded in {wt} {cur[:9]} → {tip[:9]}")


def _held(project):
    """Why focus-sync leaves a forest alone this tick: another writer holds its lock (an agent's
    reshape, a click in canopy). Skipped, never waited on (tooling-doctor P2)."""
    rec = forestlock.held(ctx.repo_cwd(), forestlock.key_for(ctx.repo_cwd(), project=project))
    return f"being changed by {forestlock.describe(rec)}" if rec else ""


def _restack(project, hold=(), merged=None):
    """merged ({branch: the head GitHub merged}) runs --contract-only instead of the walk."""
    wt = restack.worktree()
    _git("-C", wt, "checkout", "--detach")
    # a writer that took the forest after _held() looked: stack-restack skips, never waits
    env = {**os.environ, "STACK_RESTACK_FOREST_WAIT": "0", "STACK_INITIATOR": "maintenance:focus-sync"}
    with open(os.path.join(ctx.ROOT, "restack.log"), "ab") as lf:
        cmd = [os.path.join(ctx.SCRIPTS, "stack-restack"), project, "--no-claude"]
        if hold:
            cmd.append("--hold=" + ",".join(hold))
        if merged is not None:
            cmd.append("--contract-only")
            env = {**env, "STACK_RESTACK_MERGED_HEADS": "\n".join(f"{b} {h or '-'}" for b, h in sorted(merged.items())),
                   "STACK_RESTACK_OPEN_PR_HEADS": f" {' '.join(sorted(openprs.heads()))} "}
        rc = subprocess.run(cmd, cwd=wt, stdout=lf, stderr=lf, env=env).returncode
    parked, current = restack._parked()
    if parked:
        restack._clear_park()
    _git("-C", wt, "checkout", "--detach")
    watch.poke()
    return rc, current


def _sync_project(project, st, cwds):
    branches = _members(project)
    prev = st["projects"].get(project, {})
    now = int(time.time())
    behind = _behind(branches)
    if not behind:
        st["projects"][project] = prev if prev.get("state") == "synced" else {"state": "synced", "at": now}
        return False
    sig = _sig(branches)
    if prev.get("state") in ("conflict", "stuck", "refused") and prev.get("sig") == sig:
        return False
    roots = [b for b in branches if _parent(b) == "main"]
    open_prs = openprs.heads()
    # A published root (an open PR, or pushed to origin and not merged) must not move — but only
    # its own subtree is held; the other roots still contract and restack (2026-10-27: #11228
    # merged and its forest sat skipped wholesale because a sibling root had an open PR).
    held = [r for r in roots if r in open_prs or (_tip(f"refs/remotes/origin/{r}") and not sync._already_merged(r))]

    def under_hold(b):
        while b and b != "main":
            if b in held:
                return True
            b = _parent(b)
        return False

    if held and all(under_hold(b) for b in behind):
        why = "its base has an open PR" if any(r in open_prs for r in held) else "its base is pushed to origin"
        st["projects"][project] = {"state": "skipped", "why": why}
        return False
    for r in roots:
        if r in behind and sync._already_merged(r) and not _gh_merged(r):
            st["projects"][project] = {"state": "refused", "sig": sig, "at": now, "branch": r,
                                       "why": f"{r} looks merged locally but GitHub has no merged PR for it"}
            return True
    why = _busy(branches, cwds) or _held(project)
    if why:
        st["projects"][project] = {"state": "waiting", "why": why}
        return False
    ctx.log(f"focus-sync: restacking {project} ({len(behind)} behind{', holding ' + ', '.join(held) if held else ''})")
    rc, current = _restack(project, hold=held)
    branches = _members(project)
    still = [b for b in _behind(branches) if not under_hold(b)]   # a held subtree is behind on purpose
    now = int(time.time())
    if current:
        st["projects"][project] = {"state": "conflict", "sig": _sig(branches), "at": now, "branch": current,
                                   "why": f"{current} conflicts with its new base — restack it to resolve"}
    elif still:
        st["projects"][project] = {"state": "stuck", "sig": _sig(branches), "at": now, "branch": still[0],
                                   "why": f"{still[0]} didn't move (stack-restack exit {rc})"}
    else:
        st["projects"][project] = {"state": "synced", "at": now}
    ctx.log(f"focus-sync: {project} → {st['projects'][project]['state']}")
    return True


def _land_published_children(project, landed, cwds):
    """A landed root's published children can't be rebased, and contract-only won't drop a parent
    under a live child, so the forest sat until someone merged main into the child by hand
    (disable-evidence, 47 min after #11659). Catch each up on main against the tip it was built
    on (reshape.land), under the forest's lock, then queue its quick gates: the merge is a new
    tree its PR hasn't been checked on. A conflict there is a real overlap, logged and left."""
    from . import catchup, push, reshape
    for b in landed:
        if _parent(b) != "main":
            continue
        kids = [c for c in catchup.children(b) if _tip(f"refs/remotes/origin/{c}")]
        if not kids or _busy(kids, cwds):
            continue
        try:
            with forestlock.hold(ctx.repo_cwd(), forestlock.key_for(ctx.repo_cwd(), project=project),
                                 "focus-sync · land", wait=0, export=False):
                res = reshape.land(b, only_published=True)
        except (forestlock.Held, reshape.Refused) as e:
            ctx.log(f"focus-sync: {b}'s published children not caught up on main: {e}")
            continue
        for r in res["landed"]:
            if r["how"] == "merged":
                push._spawn_gates(r["branch"], background=True, quick=True)
        ctx.log(f"focus-sync: {b} landed — {', '.join(r['branch'] + ' ' + r['how'] for r in res['landed'])} on main")


def _contract_project(project, merged, st, cwds):
    """Drop the members that landed. What a pass leaves (live children sit on it) isn't retried until
    the forest's shape changes or another member lands; a held member is retried every tick."""
    def sig(members):
        return " ".join(f"{b}={_tip('refs/heads/' + b)}<{_parent(b)}" for b in members if b in merged) \
            + " | " + " ".join(f"{b}<{_parent(b)}" for b in members)

    members = _members(project)
    landed = [b for b in members if b in merged]
    if not landed or st["contracted"].get(project) == sig(members):
        return False
    if _held(project):
        return False   # someone is changing this forest: contract it next tick
    held = [b for b in landed if _busy([b], cwds)]
    if len(held) == len(landed):
        return False   # nothing to drop until a worktree frees
    tips = {b: _tip(f"refs/heads/{b}") for b in landed}
    _land_published_children(project, [b for b in landed if b not in held and merged.get(b) == tips[b]], cwds)
    ctx.log(f"focus-sync: contracting {project} ({', '.join(landed)}{'; holding ' + ', '.join(held) if held else ''})")
    _restack(project, hold=held, merged=merged)
    members = _members(project)
    gone = [b for b in landed if b not in members]
    if held:
        st["contracted"].pop(project, None)
    else:
        st["contracted"][project] = sig(members)   # what's left waits on live children
    if gone:
        ctx.log(f"focus-sync: {project} shed {', '.join(f'{b} ({tips[b][:12]})' for b in gone)}")
    return bool(gone)


def tick():
    ctx.set_repo(ctx.CWD)
    _git("fetch", "-q", "origin", "main")
    tip = _tip("origin/main")
    if not tip:
        return
    with _lock:
        st = _load()
        changed = False
        if tip != st.get("tip"):
            _ff_main(tip)
            ctx.fire(["nice", "-n", "10", os.path.join(ctx.SCRIPTS, "stack-donor"), "--refresh", ctx.MAIN_WT],
                     cwd=ctx.MAIN_WT)
            st["tip"] = tip
            changed = True
        shown = _projects()
        st["contracted"] = {p: v for p, v in st.get("contracted", {}).items() if p in shown}
        merged = {b: pr.get("head") for b, pr in sync._pr_state_map().items() if pr.get("state") == "MERGED"}
        cwds = None
        for p in shown:
            if restack.blocked():
                break
            if any(b in merged for b in _members(p)):
                cwds = _live_cwds() if cwds is None else cwds
                changed |= _contract_project(p, merged, st, cwds)
        focus = _focus_projects()
        st["projects"] = {p: v for p, v in st.get("projects", {}).items() if p in focus}
        for p in focus:
            if restack.blocked():
                break
            if cwds is None and _behind(_members(p)):
                cwds = _live_cwds()
            changed |= _sync_project(p, st, cwds or set())
        _save(st)
    if changed:
        ctx.bump_pulse()


def sync_forever():
    while True:
        try:
            tick()
        except Exception as e:
            ctx.log(f"focus-sync: tick failed: {e!r}")
        time.sleep(POLL_S)
