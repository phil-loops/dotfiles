#!/usr/bin/env python3
"""srv/catchup.carry: a parent's push carries its children (tooling-doctor P7, A4) — a published
child catches up by a merge and is pushed through the door, an unpublished one is rebased, the
walk goes on down, and a child whose push is refused stops only its own subtree. Temp repo; the
push is a stand-in, so nothing is pushed or fetched."""
import testenv  # noqa: F401,E402 — git here ignores the machine's config (testenv.py)
import os
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)


class _State:
    @staticmethod
    def poke():
        pass


sys.modules["srv.state"] = _State
from srv import ctx  # noqa: E402

env = {**os.environ, "GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@t", "GIT_COMMITTER_NAME": "t", "GIT_COMMITTER_EMAIL": "t@t"}
for k in ("GIT_DIR", "GIT_INDEX_FILE", "GIT_WORK_TREE"):
    env.pop(k, None)
root = tempfile.mkdtemp(prefix="carry-")
repo = os.path.join(root, "r")
subprocess.run(["git", "init", "-q", "-b", "main", repo], check=True, env=env)
os.chdir(repo)
ctx.run = lambda argv, **kw: subprocess.run(argv, capture_output=True, text=True, env=env, cwd=kw.get("cwd", repo))
ctx.MAIN_WT = repo
from srv import catchup  # noqa: E402

failures = 0


def check(name, ok, detail=""):
    global failures
    print(("✓ " if ok else "✗ ") + name + ("" if ok else f" — {detail}"))
    failures += 0 if ok else 1


def git(*a, ok=True):
    return subprocess.run(["git", *a], capture_output=True, text=True, env=env, check=ok).stdout.strip()


def commit(path, text, msg):
    with open(path, "w") as f:
        f.write(text)
    git("add", path)
    git("commit", "-q", "-m", msg)


def anc(a, b):
    return subprocess.run(["git", "merge-base", "--is-ancestor", a, b], env=env).returncode == 0


commit("base.txt", "base\n", "root")
for b, parent in (("p", "main"), ("c", "p"), ("g", "c"), ("s", "p"), ("t", "s")):
    git("checkout", "-q", parent if parent != "main" else "main")
    git("checkout", "-q", "-b", b)
    commit(f"{b}.txt", f"{b}\n", f"{b}1")
    git("config", f"branch.{b}.stack-parent", parent)
for b in ("p", "c", "s", "t"):
    git("update-ref", f"refs/remotes/origin/{b}", b)       # g is local only
git("checkout", "-q", "p")
commit("p2.txt", "p moved\n", "p2")                          # p's follow-up, just pushed
git("update-ref", "refs/remotes/origin/p", "p")
git("checkout", "-q", "main")
c0, s0, t0, g0 = (git("rev-parse", b) for b in ("c", "s", "t", "g"))

pushed = []
def push_one(b):
    pushed.append(b)
    return (False, "door refused: test") if b == "s" else (True, "")

out = catchup.carry("p", push_one)
by = {r["branch"]: r for r in out}
check("children found", catchup.children("p") == ["c", "s"], catchup.children("p"))
check("published child caught up by a merge", by.get("c", {}).get("how") == "merged" and anc("p", "c"), out)
check("…append-only: its old tip is its first parent", git("rev-parse", "c^1") == c0)
check("…and pushed through the door", "c" in pushed and by["c"].get("pushed") is True, out)
check("unpublished grandchild rebased onto the carried child", by.get("g", {}).get("how") == "rebased" and anc("c", "g"), out)
check("…and not pushed", "g" not in pushed)
check("a refused push is reported for that child", by.get("s", {}).get("err", "").startswith("door refused"), out)
check("…its own child is left as it was", "t" not in by and git("rev-parse", "t") == t0, out)
again = catchup.carry("p", lambda b: (True, ""))
check("a second press moves only what the refusal held back", [r["branch"] for r in again] == ["t"] and anc("s", "t"), again)

print(f"\n{'all passed' if not failures else f'{failures} failed'}")
sys.exit(1 if failures else 0)
