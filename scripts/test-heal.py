#!/usr/bin/env python3
"""srv/heal.py (stack-doctor --heal): pre-P1 leftovers are cleaned up and a person's own work is
never touched. Temp repos; the "origin" is a hand-written remote-tracking ref, no remote, no push."""
import json
import os
import subprocess
import sys
import tempfile
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from srv import heal  # noqa: E402

env = {**os.environ, "GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@t", "GIT_COMMITTER_NAME": "t", "GIT_COMMITTER_EMAIL": "t@t"}
for k in ("GIT_DIR", "GIT_INDEX_FILE", "GIT_WORK_TREE"):
    env.pop(k, None)
os.environ.update({k: v for k, v in env.items() if k.startswith("GIT_")})
failures = 0


def check(name, ok, detail=""):
    global failures
    print(("✓ " if ok else "✗ ") + name + ("" if ok else f" — {detail}"))
    failures += 0 if ok else 1


def git(r, *a, check=True):
    return subprocess.run(["git", "-C", r, *a], capture_output=True, text=True, env=env, check=check)


def commit(r, path, text, msg):
    with open(os.path.join(r, path), "w") as f:
        f.write(text)
    git(r, "add", path)
    git(r, "commit", "-q", "-m", msg)


def gitdir(r):
    return git(r, "rev-parse", "--absolute-git-dir").stdout.strip()


def in_progress(r):
    gd = gitdir(r)
    return os.path.isdir(os.path.join(gd, "rebase-merge")) or os.path.isdir(os.path.join(gd, "rebase-apply"))


def setup():
    base = tempfile.mkdtemp(prefix="heal-")
    r = os.path.join(base, "r")
    subprocess.run(["git", "init", "-q", "-b", "main", r], check=True, env=env)
    commit(r, "f.txt", "base\n", "root")
    git(r, "checkout", "-q", "-b", "b")
    commit(r, "f.txt", "branch\n", "b1")
    git(r, "checkout", "-q", "main")
    commit(r, "f.txt", "main\n", "m1")
    return base, r


def stop_mid_rebase(wt, branch="b"):
    git(wt, "checkout", "-q", "--detach", branch)
    git(wt, "rebase", "main", check=False)   # conflicts on f.txt → stopped mid-rebase
    return in_progress(wt)


def age(path, seconds):
    t = time.time() - seconds
    for root, dirs, files in os.walk(path):
        for n in dirs + files:
            os.utime(os.path.join(root, n), (t, t))
    os.utime(path, (t, t))


# 1. a dead owner's rebase is aborted; a person's (no record) in their own checkout is left
base, r = setup()
person = os.path.join(base, "person-wt")
git(r, "worktree", "add", "-q", "--detach", person, "main")
check("setup: person's checkout stopped mid-rebase", stop_mid_rebase(person))
dead = os.path.join(base, "dead-wt")
git(r, "worktree", "add", "-q", "--detach", dead, "main")
check("setup: dead owner's checkout stopped mid-rebase", stop_mid_rebase(dead))
with open(os.path.join(gitdir(dead), heal.rebaseguard.OWNER), "w") as f:
    json.dump({"pid": 999999, "start": "never"}, f)
found = heal.heal(r)
check("dead owner's rebase aborted", not in_progress(dead), found)
check("person's rebase left alone", in_progress(person))
check("person's rebase reported as left", any(f["kind"] == "rebase" and f["action"] == "left" and f["path"].endswith("person-wt") for f in found), found)

# 2. a record-less rebase in a canopy scratch checkout: left while fresh, aborted once old
scratch = os.path.join(base, ".loops-sync-wt")
git(r, "worktree", "add", "-q", "--detach", scratch, "main")
check("setup: scratch stopped mid-rebase", stop_mid_rebase(scratch))
heal.heal(r)
check("a fresh scratch rebase is left (could be a live pre-P1 run)", in_progress(scratch))
age(os.path.join(gitdir(scratch), "rebase-merge"), heal.STALE_S + 60)
found = heal.heal(r, dry=True)
check("dry run says it would abort", any(f["action"] == "would abort" for f in found), found)
check("dry run moves nothing", in_progress(scratch))
heal.heal(r)
check("an old scratch rebase is aborted", not in_progress(scratch))

# 3. the old mkdir lock dirs are removed
os.makedirs(os.path.join(gitdir(r), "seed-gen.lock"))
os.makedirs(os.path.join(r, ".gen", ".rebuilding"))
found = heal.heal(r)
check("seed-gen.lock dir removed", not os.path.isdir(os.path.join(gitdir(r), "seed-gen.lock")))
check(".gen/.rebuilding removed", not os.path.isdir(os.path.join(r, ".gen", ".rebuilding")))

# 4. a push vehicle origin already carries is deleted; one origin lacks is left
git(r, "branch", "carried", "b")
git(r, "branch", "carried-additive", "b")
git(r, "config", "branch.carried-additive.description", "vehicle")
git(r, "update-ref", "refs/remotes/origin/carried", "b")
git(r, "branch", "ahead", "main")
git(r, "update-ref", "refs/remotes/origin/ahead", "main")
git(r, "checkout", "-q", "-b", "ahead-additive", "main")
commit(r, "g.txt", "new\n", "vehicle-only work")
git(r, "checkout", "-q", "main")
found = heal.heal(r)
check("carried vehicle deleted", git(r, "rev-parse", "--verify", "-q", "refs/heads/carried-additive", check=False).returncode != 0)
check("carried vehicle's config removed", git(r, "config", "branch.carried-additive.description", check=False).returncode != 0)
check("a vehicle with work origin lacks is kept", git(r, "rev-parse", "--verify", "-q", "refs/heads/ahead-additive", check=False).returncode == 0)
check("…and reported", any(f["kind"] == "vehicle" and f["action"] == "left" for f in found), found)

# 5. an old stack-review-run checkout is removed; a fresh one stays
old = os.path.join(base, "stack-review-run-old")
new = os.path.join(base, "stack-review-run-new")
git(r, "worktree", "add", "-q", "--detach", old, "main")
git(r, "worktree", "add", "-q", "--detach", new, "main")
age(old, heal.STALE_S + 60)
heal.heal(r)
check("old review-run checkout removed", not os.path.isdir(old))
check("fresh review-run checkout kept", os.path.isdir(new))

# 6. the CLI: exit 1 while something is left for a person, words name it
res = subprocess.run([sys.executable, os.path.join(HERE, "srv", "heal.py"), "--dry-run"], cwd=r, capture_output=True, text=True, env=env)
check("CLI exits 1 while a person's rebase is pending", res.returncode == 1, res.stdout + res.stderr)
check("CLI names it", "person-wt" in res.stdout, res.stdout)

print(f"\n{'all passed' if not failures else f'{failures} failed'}")
sys.exit(1 if failures else 0)
