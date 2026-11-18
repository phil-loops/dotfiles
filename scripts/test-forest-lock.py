#!/usr/bin/env python3
"""forest-lock / srv/forestlock.py: one writer per forest. Temp repo, no remote."""
import os
import signal
import subprocess
import sys
import tempfile
import time

HERE = os.path.dirname(os.path.abspath(__file__))
FL = os.path.join(HERE, "forest-lock")
env = {**os.environ, "GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@t", "GIT_COMMITTER_NAME": "t", "GIT_COMMITTER_EMAIL": "t@t"}
for k in ("GIT_DIR", "GIT_INDEX_FILE", "GIT_WORK_TREE", "STACK_FOREST_LOCKED", "CLAUDE_CODE_SESSION_ID"):
    env.pop(k, None)
failures = 0


def check(name, ok, detail=""):
    global failures
    print(("✓ " if ok else "✗ ") + name + ("" if ok else f" — {detail}"))
    failures += 0 if ok else 1


r = os.path.join(tempfile.mkdtemp(prefix="forest-lock-"), "r")
subprocess.run(["git", "init", "-q", "-b", "main", r], check=True, env=env)
subprocess.run(["git", "-C", r, "config", "branch.b.stack-project", "p"], check=True, env=env)


def fl(*a, **kw):
    return subprocess.run([FL, *a], cwd=r, capture_output=True, text=True, env={**env, **kw.get("extra", {})})


def holder(*a):
    p = subprocess.Popen([FL, *a, "--who", "test holder", "--", "sleep", "30"], cwd=r, env=env, start_new_session=True)
    for _ in range(100):
        if fl("--held", "p").returncode == 0 or fl("--held", "q").returncode == 0:
            break
        time.sleep(0.05)
    return p


p = holder("p")
res = fl("--held", "p")
check("a live holder is seen and named", res.returncode == 0 and "test holder" in res.stdout, res.stdout)
res = fl("p", "--wait", "0.3", "--", "true")
check("a second writer for the same forest waits, then gives up with 75", res.returncode == 75 and "test holder" in res.stderr, res.stderr)
res = fl("--branch", "b", "--wait", "0.3", "--", "true")
check("--branch resolves to its forest's lock", res.returncode == 75)
res = fl("p", "--wait", "0.3", "--", "true", extra={"STACK_FOREST_LOCKED": "forest-p"})
check("a nested tool inside the holder doesn't wait on its own forest", res.returncode == 0, res.stderr)
res = fl("q", "--wait", "0.3", "--", "true")
check("another forest isn't blocked", res.returncode == 0)
os.killpg(p.pid, signal.SIGKILL); p.wait()
t0 = time.monotonic()
res = fl("p", "--wait", "5", "--", "true")
check("kill -9 on the holder frees the forest at once", res.returncode == 0 and time.monotonic() - t0 < 1.5, res.stderr)
check("…and --held is false after", fl("--held", "p").returncode == 1)
res = fl("p", "--", "sh", "-c", "exit 7")
check("the command's own exit code comes back", res.returncode == 7)
print("all passed" if not failures else f"{failures} failed")
sys.exit(1 if failures else 0)
