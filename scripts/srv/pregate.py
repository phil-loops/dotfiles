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
# The currency filter is what keeps this cheap: stale roots (the archived/parked
# hundreds) are behind origin/main and never qualify; a root becomes a candidate exactly
# when a restack brings it current — which is exactly when its old verdict died.

import time

from . import ctx, push, restack

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





def _candidate():
    from . import repostate
    snap = repostate.snapshot()
    current = _current_set()
    for b in _roots():
        if b not in current or not snap.exists(b) or _archived(snap, b):
            continue
        tree = snap.tree(b)
        if not tree or push._green_tree(b) == tree:
            continue
        job = push._GATE_JOBS.get(push._jkey(b)) or push._adopt_job(b)
        if job and job["tree"] == tree:
            if push._job_running(job):
                continue
            # finished for this exact tree — harvest a green, let a red stand as the memo
            result = next((e for e in push._journal_events(job["path"])
                           if e.get("event") == "result"), None)
            if result and result.get("ok"):
                push._record_green(b, tree)
            continue
        return b
    return None


def pregate_forever():
    while True:
        time.sleep(POLL_S)
        try:
            if not ctx.watched():
                continue   # nobody is looking: a speculative typecheck is pure heat
            if restack._running() or restack._queue_read():
                continue   # trees about to move — gate after the restack, not before
            if any(push._job_running(j) for j in list(push._GATE_JOBS.values())):
                continue   # one gates run machine-wide: never stack a tsc under Phil's click
            b = _candidate()
            if b:
                push._spawn_gates(b, fix=False)
        except Exception:
            pass   # an ambient nicety must never take the server down
