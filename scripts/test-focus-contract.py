#!/usr/bin/env python3
"""srv/focus.py sheds landed members from every shown forest: a merged leaf goes, a merged parent
under a live child stays, a busy one is held, an archived forest isn't touched, and a pass that
dropped nothing isn't repeated until the forest changes. Runs the real stack-restack."""
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

failures = 0


def check(name, ok, detail=""):
    global failures
    print(("✓ " if ok else "✗ ") + name + ("" if ok else f" — {detail}"))
    failures += 0 if ok else 1


env = {**os.environ, "GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@t", "GIT_COMMITTER_NAME": "t", "GIT_COMMITTER_EMAIL": "t@t"}
for k in ("GIT_DIR", "GIT_INDEX_FILE", "GIT_WORK_TREE"):
    env.pop(k, None)
root = tempfile.mkdtemp(prefix="focus-contract-")
origin, repo = os.path.join(root, "o.git"), os.path.join(root, "r")
subprocess.run(["git", "init", "-q", "--bare", origin], check=True)
subprocess.run(["git", "init", "-q", "-b", "main", repo], check=True)


def git(*a):
    return subprocess.run(["git", "-C", repo, *a], capture_output=True, text=True, env=env, check=True).stdout.strip()


def exists(b):
    return subprocess.run(["git", "-C", repo, "rev-parse", "-q", "--verify", f"refs/heads/{b}"],
                          capture_output=True, env=env).returncode == 0


def mk(b, parent, project="proj"):
    git("checkout", "-q", "-b", b, parent)
    with open(os.path.join(repo, f"{b}.txt"), "w") as f:
        f.write(b)
    git("add", f"{b}.txt"); git("commit", "-q", "-m", b)
    git("config", f"branch.{b}.stack-parent", parent); git("config", f"branch.{b}.stack-project", project)
    git("config", "--add", f"stack-project.{project}.branch", b)


def land(*bs):
    git("checkout", "-q", "main")
    for b in bs:
        with open(os.path.join(repo, f"{b}.txt"), "w") as f:
            f.write(b)
        git("add", f"{b}.txt"); git("commit", "-q", "-m", f"squash {b}")
    git("push", "-q", "origin", "main")


git("remote", "add", "origin", origin)
git("commit", "-q", "--allow-empty", "-m", "base"); git("push", "-q", "origin", "main")
# proj: leaf (landed) · par (landed) → kid (live) · busy (landed, worktree busy) · old: arch (landed, archived)
mk("leaf", "main"); mk("par", "main"); mk("kid", "par"); mk("busy", "main"); mk("arch", "main", "old")
git("config", "stack-project.old.archived", "true")
land("leaf", "par", "busy", "arch")

ctx.CWD = ctx.MAIN_WT = repo
ctx.SCRIPTS = HERE
ctx.ROOT = root
ctx.run = lambda argv, **kw: subprocess.run(argv, cwd=repo, capture_output=True, text=True, env=env)
ctx.log = lambda *a, **k: None
from srv import focus, openprs, sync  # noqa: E402

openprs.heads = lambda *a, **k: {"kid"}
focus._busy = lambda branches, cwds: "busy" if branches == ["busy"] else ""
merged = {b: git("rev-parse", b) for b in ("leaf", "par", "busy", "arch")}

check("the archived forest isn't shown", focus._projects() == ["proj"], focus._projects())
st = {"contracted": {}}
dropped = focus._contract_project("proj", merged, st, set())
check("the pass reports a change", dropped is True)
check("the landed leaf is gone", not exists("leaf"))
check("the landed parent stays under its live child", exists("par") and focus._parent("kid") == "par")
check("the busy landed branch is held", exists("busy"))
check("the archived forest's landed branch is untouched", exists("arch"))
check("the registry keeps the survivors", sorted(git("config", "--get-all", "stack-project.proj.branch").split()) == ["busy", "kid", "par"])

# with only the busy branch landed, nothing runs at all
runs = []
real = focus._restack
focus._restack = lambda *a, **k: runs.append(a) or (0, "")
focus._contract_project("proj", {"busy": merged["busy"]}, {"contracted": {}}, set())
check("a forest whose landed branches are all held runs nothing", runs == [], runs)
focus._restack = real

# the worktree frees: busy goes; par still waits on kid
focus._busy = lambda branches, cwds: ""
focus._contract_project("proj", merged, st, set())
check("the freed branch goes", not exists("busy"))
check("what the pass left is remembered", "proj" in st["contracted"], st)

runs = []
real = focus._restack
focus._restack = lambda *a, **k: runs.append(a) or (0, "")
focus._contract_project("proj", merged, st, set())
check("…and not repeated while the forest is unchanged", runs == [], runs)

# kid lands: the pass runs again and the forest ships
focus._restack = real
land("kid")
focus._contract_project("proj", {**merged, "kid": git("rev-parse", "kid")}, st, set())
check("kid and par go once kid lands", not exists("kid") and not exists("par"))
check("the shipped forest leaves no keys", subprocess.run(["git", "-C", repo, "config", "--get-regexp", r"^stack-project\.proj\."],
                                                          capture_output=True, text=True, env=env).stdout == "")

# a landed root with a PUBLISHED child: the child can't be rebased and contract-only won't drop a
# parent under it, so the forest used to sit (disable-evidence, #11659). Now the child catches up
# on main by a merge against the tip it was built on, its quick gates queue, and the root goes
from srv import push  # noqa: E402
mk("pr2", "main", "pub"); mk("pk", "pr2", "pub")
git("push", "-q", "origin", "pk")
land("pr2")
pk_old, pr2_tip = git("rev-parse", "pk"), git("rev-parse", "pr2")
sync._pr_state_map = lambda: {"pr2": {"state": "MERGED", "head": pr2_tip}}
spawned = []
push._spawn_gates = lambda b, **k: spawned.append((b, k.get("quick")))
st2 = {"contracted": {}}
focus._contract_project("pub", {"pr2": pr2_tip}, st2, set())
check("the published child caught up on main by a merge (child, origin/main)",
      git("rev-list", "--parents", "-n1", "pk").split()[1:] == [pk_old, git("rev-parse", "origin/main")])
check("…points at main, and the landed root is gone", focus._parent("pk") == "main" and not exists("pr2"))
check("…and its quick gates are queued", spawned == [("pk", True)], spawned)

print(f"\n{'OK' if not failures else 'FAIL'} — {failures} failure(s)")
sys.exit(1 if failures else 0)
