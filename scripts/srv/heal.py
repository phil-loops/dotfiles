"""Clean up what the tools left before P1 (tooling-doctor B6): claims that outlived a holder who
died before claims died with their holders.

  rebase   a rebase in progress whose owner record names a dead process → aborted (rebaseguard).
           One with NO record in a canopy scratch checkout (.loops-sync-wt, .loops-restack-wt, a
           stack-review-run worktree) older than STALE_S predates the record → aborted; no person
           works there. Anywhere else a record-less rebase is a person's: reported, never touched.
  lockdir  the mkdir locks fdlock replaced (<gitdir>/seed-gen.lock, <wt>/.gen/.rebuilding):
           nothing takes them any more, so any that remain are leftovers → removed.
  vehicle  a <b>-additive push vehicle (the route that drafted them is retired) whose content
           origin/<b> already carries → deleted with its config; one origin lacks is reported.
  review   a stack-review-run worktree older than STALE_S (the run removes its own; a killed one
           can't) → removed.

heal(repo, dry=False) → [{kind, path, action, why}]. `stack-doctor --heal [--dry-run]` prints them;
the server runs it once at start, when everything a previous server owned is dead by definition."""
import os
import subprocess
import sys
import time

if __package__ in (None, ""):
    sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
    from srv import rebaseguard  # noqa: E402
else:
    from . import rebaseguard

STALE_S = 3600
SCRATCH = (".loops-sync-wt", ".loops-restack-wt")
_SCRUB = ("GIT_DIR", "GIT_INDEX_FILE", "GIT_WORK_TREE", "GIT_PREFIX")


def _git(cwd, *a):
    env = {k: v for k, v in os.environ.items() if k not in _SCRUB}
    return subprocess.run(["git", "-C", cwd, *a], capture_output=True, text=True, env=env)


def _worktrees(repo):
    out = _git(repo, "worktree", "list", "--porcelain").stdout
    return [ln[len("worktree "):] for ln in out.splitlines() if ln.startswith("worktree ")]


def _scratch(path):
    base = os.path.basename(path.rstrip("/"))
    return base in SCRATCH or base.startswith("stack-review-run-")


def _age(path):
    try:
        return time.time() - os.stat(path).st_mtime
    except OSError:
        return 0


def _rebase_dir(gd):
    return next((d for d in (os.path.join(gd, "rebase-merge"), os.path.join(gd, "rebase-apply")) if os.path.isdir(d)), "")


def _rebases(repo, dry):
    found = []
    for wt in _worktrees(repo):
        gd = _git(wt, "rev-parse", "--absolute-git-dir").stdout.strip()
        rd = gd and _rebase_dir(gd)
        if not rd:
            continue
        has_record = os.path.exists(os.path.join(gd, rebaseguard.OWNER))
        if has_record:
            if dry:
                found.append({"kind": "rebase", "path": wt, "action": "would heal", "why": "owner record — aborted if its owner is dead"})
                continue
            state = rebaseguard.heal(wt)
            if state == "healed":
                found.append({"kind": "rebase", "path": wt, "action": "aborted", "why": "its owner died mid-rebase"})
            continue
        if _scratch(wt) and _age(rd) > STALE_S:
            if not dry:
                _git(wt, "rebase", "--abort")
            found.append({"kind": "rebase", "path": wt, "action": "would abort" if dry else "aborted",
                          "why": f"a canopy scratch checkout stuck mid-rebase for {int(_age(rd) // 60)} min"})
        elif _scratch(wt):
            found.append({"kind": "rebase", "path": wt, "action": "left",
                          "why": "a canopy scratch checkout mid-rebase — left while it may still be running"})
        else:
            found.append({"kind": "rebase", "path": wt, "action": "left",
                          "why": "a rebase with no owner record — someone's own; finish or abort it"})
    return found


def _lockdirs(repo, dry):
    found = []
    for wt in _worktrees(repo):
        gd = _git(wt, "rev-parse", "--absolute-git-dir").stdout.strip()
        for d in (gd and os.path.join(gd, "seed-gen.lock"), os.path.join(wt, ".gen", ".rebuilding")):
            if d and os.path.isdir(d):
                if not dry:
                    subprocess.run(["rm", "-rf", d])
                found.append({"kind": "lockdir", "path": d, "action": "would remove" if dry else "removed",
                              "why": "a mkdir lock fdlock replaced — nothing takes it any more"})
    return found


def _carried(repo, vehicle, branch):
    o = f"refs/remotes/origin/{branch}"
    otree = _git(repo, "rev-parse", "--verify", "-q", f"{o}^{{tree}}").stdout.strip()
    if not otree:
        return False
    if _git(repo, "merge-base", "--is-ancestor", f"refs/heads/{vehicle}", o).returncode == 0:
        return True
    r = _git(repo, "merge-tree", "--write-tree", o, f"refs/heads/{vehicle}")
    return r.returncode == 0 and r.stdout.split("\n", 1)[0].strip() == otree


def _vehicles(repo, dry):
    found = []
    refs = _git(repo, "for-each-ref", "--format=%(refname:short)", "refs/heads/*-additive").stdout.split()
    for v in refs:
        b = v[: -len("-additive")]
        if _carried(repo, v, b):
            if not dry:
                _git(repo, "branch", "-D", v)
                _git(repo, "config", "--remove-section", f"branch.{v}")
            found.append({"kind": "vehicle", "path": v, "action": "would delete" if dry else "deleted",
                          "why": f"origin/{b} already carries it"})
        else:
            found.append({"kind": "vehicle", "path": v, "action": "left",
                          "why": f"origin/{b} lacks some of it — push through canopy's p on {b}, then heal again"})
    return found


def _review_runs(repo, dry):
    found = []
    for wt in _worktrees(repo):
        if os.path.basename(wt.rstrip("/")).startswith("stack-review-run-") and _age(wt) > STALE_S:
            if not dry:
                _git(repo, "worktree", "remove", "--force", wt)
            found.append({"kind": "review", "path": wt, "action": "would remove" if dry else "removed",
                          "why": "a review run's checkout its killed run never removed"})
    if not dry:
        _git(repo, "worktree", "prune")
    return found


def heal(repo, dry=False):
    out = []
    for step in (_rebases, _lockdirs, _vehicles, _review_runs):
        try:
            out += step(repo, dry)
        except Exception as e:   # one step's failure never stops the rest
            out.append({"kind": step.__name__.strip("_"), "path": repo, "action": "failed", "why": str(e)[:200]})
    return out


def main(argv):
    dry = "--dry-run" in argv or "-n" in argv
    repo = _git(os.getcwd(), "rev-parse", "--show-toplevel").stdout.strip()
    if not repo:
        print("heal: not in a git repo", file=sys.stderr)
        return 1
    found = heal(repo, dry)
    if not found:
        print("✓ nothing to heal")
    for f in found:
        print(f"{'✗' if f['action'] in ('left', 'failed') else '✓'} {f['kind']:8} {f['action']:12} {f['path']} — {f['why']}")
    return 1 if any(f["action"] in ("left", "failed") for f in found) else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
