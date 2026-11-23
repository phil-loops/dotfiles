#!/usr/bin/env python3
"""srv/focus.py catches a merged root's published children up on main, and when it can't, says why and
tries again next tick. It used to skip without a word whenever the local root differed from the head
GitHub merged, or a child's worktree was busy, and then remembered the forest as handled, so the
child sat behind its merged parent until someone merged main in by hand. Temp repo with no remote:
origin refs are written with update-ref, nothing is pushed, and GitHub's answer is a stand-in."""
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

failures = 0


def check(name, ok, detail=""):
    global failures
    print(("✓ " if ok else "✗ ") + name + ("" if ok else f" — {detail}"))
    failures += 0 if ok else 1


env = {**os.environ, "GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@t", "GIT_COMMITTER_NAME": "t", "GIT_COMMITTER_EMAIL": "t@t"}
for k in ("GIT_DIR", "GIT_INDEX_FILE", "GIT_WORK_TREE"):
    env.pop(k, None)
root = tempfile.mkdtemp(prefix="focus-land-skip-")
repo = os.path.join(root, "r")
subprocess.run(["git", "init", "-q", "-b", "main", repo], check=True, env=env)


def git(*a):
    return subprocess.run(["git", "-C", repo, *a], capture_output=True, text=True, env=env, check=True).stdout.strip()


def commit_file(name, text, msg):
    with open(os.path.join(repo, name), "w") as f:
        f.write(text)
    git("add", name); git("commit", "-q", "-m", msg)


def mk(b, parent, project):
    git("checkout", "-q", "-b", b, parent)
    commit_file(f"{b}.txt", b, b)
    git("config", f"branch.{b}.stack-parent", parent); git("config", f"branch.{b}.stack-project", project)
    git("config", "--add", f"stack-project.{project}.branch", b)


def publish(b):
    git("update-ref", f"refs/remotes/origin/{b}", b)


def squash_into_main(*files):
    git("checkout", "-q", "main")
    for name, text in files:
        commit_file(name, text, f"squash {name}")
    git("update-ref", "refs/remotes/origin/main", "main")


git("commit", "-q", "--allow-empty", "-m", "base")
git("update-ref", "refs/remotes/origin/main", "main")

ctx.CWD = ctx.MAIN_WT = repo
ctx.SCRIPTS = HERE
ctx.ROOT = root
ctx.run = lambda argv, **kw: subprocess.run(argv, cwd=repo, capture_output=True, text=True, env=env)
logged = []
ctx.log = lambda line, *a, **k: logged.append(line)
from srv import focus, push  # noqa: E402

focus._restack = lambda *a, **k: (0, "")   # contract-only's own drop isn't under test here
spawned = []
push._spawn_gates = lambda b, **k: spawned.append(b)


def skip_lines():
    return [ln for ln in logged if "weren't caught up on main" in ln]


# a: merged root, published child ak whose worktree is busy
mk("a", "main", "pa"); mk("ak", "a", "pa"); publish("ak")
squash_into_main(("a.txt", "a"))
merged = {"a": git("rev-parse", "a")}
busy = {"on": True}
focus._busy = lambda branches, cwds: "something is working in ak's worktree" if busy["on"] and "ak" in branches else ""
st = {"contracted": {}}
focus._contract_project("pa", merged, st, set())
check("a busy child isn't caught up", focus._parent("ak") == "a")
check("…and the skip is said, with its reason", len(skip_lines()) == 1 and "working in ak's worktree" in skip_lines()[0], skip_lines())
check("…and kept open in the state", st.get("landing", {}).get("pa") == {"a": "something is working in ak's worktree"}, st)
focus._contract_project("pa", merged, st, set())
check("the same skip next tick isn't said again", len(skip_lines()) == 1, skip_lines())
busy["on"] = False
focus._contract_project("pa", merged, st, set())
check("once the worktree frees, the next tick catches the child up on main", focus._parent("ak") == "main", focus._parent("ak"))
check("…by a merge with origin/main", git("rev-parse", "ak^2") == git("rev-parse", "origin/main"))
check("…its quick gates are queued", spawned == ["ak"], spawned)
check("…and the skip is closed", "pa" not in st.get("landing", {}), st)

# b: GitHub merged a head ahead of local b (a suggestion applied on GitHub); the child still lands
mk("b", "main", "pb"); mk("bk", "b", "pb"); publish("bk")
b_local = git("rev-parse", "b")
git("checkout", "-q", "-b", "b-github", "b"); commit_file("b-suggestion.txt", "s", "suggestion")
b_head = git("rev-parse", "b-github")
squash_into_main(("b.txt", "b"), ("b-suggestion.txt", "s"))
st = {"contracted": {}}
before = len(skip_lines())
focus._contract_project("pb", {"b": b_head}, st, set())
check("a merged head ahead of local still lands the child", focus._parent("bk") == "main", focus._parent("bk"))
check("…without a skip", len(skip_lines()) == before, skip_lines()[before:])

# c: local c carries a commit GitHub didn't merge; landing would carry it into the child, so it waits and says so
mk("c", "main", "pc"); c_head = git("rev-parse", "c")
commit_file("c-unpushed.txt", "u", "unpushed on c")
git("checkout", "-q", "-b", "ck", "c")
git("config", "branch.ck.stack-parent", "c"); git("config", "branch.ck.stack-project", "pc")
git("config", "--add", "stack-project.pc.branch", "ck"); commit_file("ck.txt", "ck", "ck"); publish("ck")
squash_into_main(("c.txt", "c"))
ck_tip = git("rev-parse", "ck")
st = {"contracted": {}}
focus._contract_project("pc", {"c": c_head}, st, set())
check("local commits GitHub didn't merge hold the child", focus._parent("ck") == "c" and git("rev-parse", "ck") == ck_tip)
check("…and the skip names them", any("has commits GitHub didn't merge" in ln and "ck" in ln for ln in skip_lines()), skip_lines()[-1:])

print(f"\n{'all passed' if not failures else f'{failures} failed'}")
sys.exit(1 if failures else 0)
