#!/usr/bin/env python3
"""rebase-guarded / srv/rebaseguard.py: a canopy rebase killed with -9 mid-run is aborted by
the next guarded run; a person's rebase in progress is never touched. Temp repos, no remote."""
import os
import signal
import subprocess
import sys
import tempfile
import time

HERE = os.path.dirname(os.path.abspath(__file__))
CLI = os.path.join(HERE, "rebase-guarded")
env = {**os.environ, "GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@t", "GIT_COMMITTER_NAME": "t", "GIT_COMMITTER_EMAIL": "t@t"}
for k in ("GIT_DIR", "GIT_INDEX_FILE", "GIT_WORK_TREE"):
    env.pop(k, None)
failures = 0


def check(name, ok, detail=""):
    global failures
    print(("✓ " if ok else "✗ ") + name + ("" if ok else f" — {detail}"))
    failures += 0 if ok else 1


def repo():
    r = os.path.join(tempfile.mkdtemp(prefix="rebase-guard-"), "r")
    subprocess.run(["git", "init", "-q", "-b", "main", r], check=True, env=env)
    return r


def git(r, *a, check=True):
    return subprocess.run(["git", "-C", r, *a], capture_output=True, text=True, env=env, check=check)


def commit(r, path, text, msg):
    with open(os.path.join(r, path), "w") as f:
        f.write(text)
    git(r, "add", path)
    git(r, "commit", "-q", "-m", msg)


def in_progress(r):
    gd = git(r, "rev-parse", "--absolute-git-dir").stdout.strip()
    return os.path.isdir(os.path.join(gd, "rebase-merge")) or os.path.isdir(os.path.join(gd, "rebase-apply"))


def guarded(r, *a):
    return subprocess.run([CLI, "-C", r, *a], capture_output=True, text=True, env=env)


def setup(conflict=False):
    r = repo()
    commit(r, "f.txt", "base\n", "root")
    git(r, "checkout", "-q", "-b", "b")
    commit(r, "f.txt" if conflict else "b.txt", "branch\n", "b1")
    git(r, "checkout", "-q", "main")
    commit(r, "f.txt" if conflict else "m.txt", "main\n", "m1")
    git(r, "checkout", "-q", "b")
    return r


r = setup()
res = guarded(r, "main")
check("a clean guarded rebase succeeds and leaves no record", res.returncode == 0 and not in_progress(r)
      and not os.path.exists(os.path.join(git(r, "rev-parse", "--absolute-git-dir").stdout.strip(), "canopy-rebase-owner")), res.stderr)

r = setup(conflict=True)
tip = git(r, "rev-parse", "b").stdout.strip()
res = guarded(r, "main")
check("a conflicting guarded rebase aborts itself", res.returncode != 0 and not in_progress(r) and git(r, "rev-parse", "b").stdout.strip() == tip)

# kill -9 a guarded rebase mid-run (paused in an exec step), then heal
r = setup()
tip = git(r, "rev-parse", "b").stdout.strip()
p = subprocess.Popen([CLI, "-C", r, "-x", "sleep 30", "main"], env=env, start_new_session=True,
                     stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
for _ in range(100):
    if in_progress(r):
        break
    time.sleep(0.05)
time.sleep(0.3)
os.killpg(p.pid, signal.SIGKILL)
p.wait()
check("kill -9 mid-rebase leaves it stranded (the bug)", in_progress(r))
res = subprocess.run([CLI, "--heal", "-C", r], capture_output=True, text=True, env=env)
check("the next heal aborts the dead owner's rebase", res.returncode == 0 and not in_progress(r), res.stdout + res.stderr)
check("…and the branch is back where it was", git(r, "rev-parse", "b").stdout.strip() == tip and
      git(r, "symbolic-ref", "--short", "HEAD", check=False).stdout.strip() == "b")

# a person's rebase (no record) is never touched
r = setup(conflict=True)
git(r, "rebase", "main", check=False)
check("a person's conflicted rebase is in progress", in_progress(r))
res = subprocess.run([CLI, "--heal", "-C", r], capture_output=True, text=True, env=env)
check("heal refuses a person's rebase (exit 3) and leaves it", res.returncode == 3 and in_progress(r))
res = guarded(r, "main")
check("a guarded run refuses while a person's rebase is in progress", res.returncode == 3 and in_progress(r), res.stderr)

print("all passed" if not failures else f"{failures} failed")
sys.exit(1 if failures else 0)
