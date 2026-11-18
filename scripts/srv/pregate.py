# srv/pregate.py — ambient root pre-gating: push is clicks, not waits.
#
# Any root (stack-branch parent == main) that is CURRENT with origin/main but holds no
# green verdict for its tree gets the same detached stack-gates run the ready strip
# spawns — ahead of the click, one at a time, never with --fix (an ambient run must not
# move a branch or author a commit). Green lands in stack-branch.<b>.gates-green-tree
# exactly as an interactive run would, so the strip answers from cache and the push door
# is already unlocked. A red run leaves its journal + job sidecar, which doubles as the
# "already tried this tree" memo: a failing root costs ONE typecheck per tree, not one
# per tick, and its verdict is waiting the moment the branch is opened.
#
# An open PR's follow-up (local ahead of origin's head) gets the QUICK set the same way: its
# push door only advises (tooling-doctor P5), so the advice is ready before p, not after it.
#
# The currency filter is what keeps this cheap: stale roots (the archived/parked
# hundreds) are behind origin/main and never qualify; a root becomes a candidate exactly
# when a restack brings it current — which is exactly when its old verdict died.

import time

from . import ctx, push, pushintent, restack

POLL_S = 45


def _roots():
    from . import repostate
    for branch, parent in repostate.snapshot().branch_keys("parent").items():
        if parent in ("main", "origin/main"):
            yield branch


def _archived(snap, branch):
    proj = snap.project(branch)
    return bool(proj) and snap.get(f"stack-project.{proj}.archived") == "true"


def _current_set():
    """Every branch containing origin/main, in ONE spawn. This is the currency filter the
    header comment calls cheap, and per-branch `merge-base --is-ancestor` made it the most
    expensive thing the idle server did: 564 roots × a spawn each, every 45s (measured
    2026-09-09 at ~10% of a core with nobody watching). 17 of those 564 are actually current."""
    out = ctx.run(["git", "for-each-ref", "--contains", "origin/main",
                   "--format=%(refname:short)", "refs/heads"]).stdout
    return {ln.strip() for ln in out.splitlines() if ln.strip()}





def _followups(snap):
    """Open-PR branches with commits origin doesn't have yet: their push door only advises
    (tooling-doctor P5), so the quick set runs ahead of p and the door has its advice ready."""
    for b in sorted(snap.pr_heads()):
        local, origin = snap.local(b), snap.remote(b)
        if local and origin and local != origin and snap.is_ancestor(origin, b):
            yield b


def _unmet(snap, b):
    """Whether b's tree still wants a run: no verdict, and no run for this tree (a finished
    one's green is harvested here; a red stands as the "already tried this tree" memo)."""
    tree = snap.tree(b)
    if not tree or push.verdict_stands(b, snap):
        return False
    run = push.gate_run(b)
    if run and run.meta.get("tree") == tree:
        if not run.alive():
            result = push.gate_result(run)
            if result and result.get("ok"):
                push._record_green(b, tree, result.get("gates", []))
        return False
    return True


def _candidate():
    """(branch, quick) for the next ambient run, or None: current roots get the full set, as a
    first push needs it; open PRs' follow-ups get the quick set CI's re-run complements."""
    from . import repostate
    snap = repostate.snapshot()
    current = _current_set()
    for b in _roots():
        if b in current and snap.exists(b) and not _archived(snap, b) and _unmet(snap, b):
            return b, False
    for b in _followups(snap):
        if snap.exists(b) and not _archived(snap, b) and _unmet(snap, b):
            return b, True
    return None


def pregate_forever():
    while True:
        time.sleep(POLL_S)
        try:
            pushintent.sweep()   # a queued push whose watcher a restart lost settles here
        except Exception:
            pass
        try:
            if not ctx.watched():
                continue   # nobody is looking: a speculative typecheck is pure heat
            if restack._running() or restack._queue_read():
                continue   # trees about to move — gate after the restack, not before
            if any(r.alive() for r in push.gate_runs().values()):
                continue   # one gates run machine-wide: never stack a tsc under Phil's click
            got = _candidate()
            if got:
                push._spawn_gates(got[0], fix=False, background=True, quick=got[1])
        except Exception:
            pass   # an ambient nicety must never take the server down
