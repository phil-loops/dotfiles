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
    out = ctx.run(["git", "config", "--get-regexp", r"^stack-branch\..*\.parent$"]).stdout
    for ln in out.splitlines():
        key, _, parent = ln.partition(" ")
        if parent.strip() in ("main", "origin/main"):
            yield key[len("stack-branch."):-len(".parent")]


def _archived(branch):
    proj = ctx.run(["git", "config", f"stack-branch.{branch}.project"]).stdout.strip()
    if not proj:
        return False
    return ctx.run(["git", "config", "--bool", f"stack-project.{proj}.archived"]).stdout.strip() == "true"


def _exists(branch):
    return ctx.run(["git", "rev-parse", "--verify", "-q", f"refs/heads/{branch}"]).returncode == 0


def _current(branch):
    return ctx.run(["git", "merge-base", "--is-ancestor", "origin/main", branch]).returncode == 0


def _candidate():
    for b in _roots():
        if not _exists(b) or _archived(b) or not _current(b):
            continue
        tree = push._tree(b)
        if not tree or push._green_tree(b) == tree:
            continue
        job = push._GATE_JOBS.get(b) or push._adopt_job(b)
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
            if restack._running() or restack._queue_read():
                continue   # trees about to move — gate after the restack, not before
            if any(push._job_running(j) for j in list(push._GATE_JOBS.values())):
                continue   # one gates run machine-wide: never stack a tsc under Phil's click
            b = _candidate()
            if b:
                push._spawn_gates(b, fix=False)
        except Exception:
            pass   # an ambient nicety must never take the server down
