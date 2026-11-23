#!/usr/bin/env python3
"""The catch-up srv/catchup.py builds is one the push door (srv/push.py) takes. With unpushed work
on a published branch (an earlier catch-up, a follow-up commit) the merge still goes on origin's
copy as the oldest outgoing commit, the unpushed commits ride on top of it, and the tree is the one
a merge on the local tip would have had. A parent's push carries only a child's catch-up, never the
child's own unpushed commits. Temp repo; origin refs written with update-ref and the open PR set a
stand-in, so nothing is pushed, fetched or asked of GitHub."""
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
repo = os.path.join(tempfile.mkdtemp(prefix="catch-up-door-"), "r")
subprocess.run(["git", "init", "-q", "-b", "main", repo], check=True, env=env)
os.chdir(repo)
ctx.run = lambda argv, **kw: subprocess.run(argv, capture_output=True, text=True, env=env, cwd=kw.get("cwd", repo))
ctx.CWD = ctx.MAIN_WT = repo
ctx.log = lambda line: None
from srv import catchup, push, repostate, openprs, sync, verdicts  # noqa: E402

OPEN = {"a", "b"}
openprs.heads = lambda fresh=False: set(OPEN)
sync._deploy_critical = lambda b: []
push._origin_web = lambda b: ""
push._review_flags = lambda b: {}
verdicts.waived = lambda b, tree: None
push.gate_run = lambda b: None


def git(*a, who=None):
    e = {**env, "GIT_AUTHOR_NAME": who} if who else env
    return subprocess.run(["git", *a], capture_output=True, text=True, env=e, check=True).stdout.strip()


def commit_on(branch, path, text, msg, who=None, pushed=False):
    """One commit on `branch`, leaving main checked out so no worktree holds the branch."""
    git("checkout", "-q", branch)
    with open(path, "w") as f:
        f.write(text)
    git("add", path)
    git("commit", "-q", "-m", msg, who=who)
    git("checkout", "-q", "main")
    if pushed:
        git("update-ref", f"refs/remotes/origin/{branch}", branch)
    return git("rev-parse", branch)


def door(b):
    repostate.invalidate()
    return push._origin_verdict(b)


def outgoing(b):
    """[(sha, parents, subject)] on b's first-parent line past origin's copy, newest first."""
    out = git("log", "--first-parent", "--format=%H\x1f%P\x1f%s", f"origin/{b}..{b}")
    return [(h, p.split(), s) for h, p, s in (ln.split("\x1f") for ln in out.splitlines())]


def tree(rev):
    return git("rev-parse", f"{rev}^{{tree}}")


def merged_tree(ours, theirs, base=""):
    """What a plain merge of `theirs` into `ours` holds: the tree to compare a catch-up against."""
    return git("merge-tree", "--write-tree", *([f"--merge-base={base}"] if base else []), ours, theirs).splitlines()[0]


def anc(a, b):
    return subprocess.run(["git", "merge-base", "--is-ancestor", a, b], env=env).returncode == 0


with open("base.txt", "w") as f:
    f.write("base\n")
git("add", "base.txt")
git("commit", "-q", "-m", "root")
git("update-ref", "refs/remotes/origin/main", "main")
for b, parent in (("a", "main"), ("b", "a")):
    git("branch", b, parent)
    git("config", f"branch.{b}.stack-parent", parent)
    git("config", f"branch.{b}.description", f"add {b}")
    commit_on(b, f"{b}.txt", f"{b}\n", f"feat: add {b}", pushed=True)

# 1 · two catch-ups between pushes fold into one merge on origin's copy
commit_on("a", "a2.txt", "a2\n", "a2", pushed=True)
check("first catch-up moves b", catchup.catch_up("b")["ok"] and anc("a", "b"))
check("…and the door takes it", door("b")["ok"], door("b")["reasons"])
commit_on("a", "a3.txt", "a3\n", "a3", pushed=True)
want = merged_tree("b", "a")
res = catchup.catch_up("b")
out = outgoing("b")
check("second catch-up before a push moves b", res["ok"] and anc("a", "b"), res)
check("…leaving one outgoing commit, a merge of a's tip into origin's copy",
      len(out) == 1 and out[0][1] == [git("rev-parse", "origin/b"), git("rev-parse", "a")], out)
check("…with the tree a merge on the local tip would have", tree("b") == want)
check("…and the door takes it", door("b")["ok"], door("b")["reasons"])
git("update-ref", "refs/remotes/origin/b", "b")   # pushed

# 2 · a catch-up after an unpushed follow-up goes under it
commit_on("b", "b.txt", "b fixed\n", "apply review fix", who="phil")
commit_on("a", "a4.txt", "a4\n", "a4", pushed=True)
want = merged_tree("b", "a")
res = catchup.catch_up("b")
out = outgoing("b")
check("catch-up after an unpushed follow-up moves b", res["ok"] and anc("a", "b"), res)
check("…the merge is the oldest outgoing commit, on origin's copy",
      len(out) == 2 and out[-1][1] == [git("rev-parse", "origin/b"), git("rev-parse", "a")], out)
check("…the follow-up rides on top with its subject and author",
      len(out) == 2 and out[0][2] == "apply review fix" and len(out[0][1]) == 1
      and git("log", "-1", "--format=%an", out[0][0]) == "phil", out)
check("…carrying only its own change", git("diff", "--name-only", f"{out[-1][0]}", "b") == "b.txt")
check("…with the tree a merge on the local tip would have", tree("b") == want)
check("…and the door takes it", door("b")["ok"], door("b")["reasons"])

# 3 · another follow-up and another catch-up, still unpushed: one merge, both follow-ups on top
commit_on("b", "b2.txt", "more\n", "add the second case", who="phil")
commit_on("a", "a5.txt", "a5\n", "a5", pushed=True)
want = merged_tree("b", "a")
res = catchup.catch_up("b")
out = outgoing("b")
check("a later catch-up folds the earlier one", res["ok"] and [len(p) for _, p, _ in out] == [1, 1, 2], out)
check("…follow-ups in the order they were made", [s for _, _, s in out[:2]] == ["add the second case", "apply review fix"], out)
check("…with the tree a merge on the local tip would have", tree("b") == want)
check("…and the door takes it", door("b")["ok"], door("b")["reasons"])
git("update-ref", "refs/remotes/origin/b", "b")   # pushed

# 4 · a catch-up to a parent origin doesn't have yet: the door asks for the parent first
commit_on("a", "a6.txt", "a6\n", "a6")            # not pushed
catchup.catch_up("b")
v = door("b")
check("a catch-up to an unpushed parent is refused", not v["ok"], v["reasons"])
check("…saying to push the parent first", any("push a first" in r for r in v["reasons"]), v["reasons"])
git("update-ref", "refs/remotes/origin/a", "a")   # the parent goes out
check("…and taken as it stands once the parent is pushed", door("b")["ok"], door("b")["reasons"])
git("update-ref", "refs/remotes/origin/b", "b")   # pushed

# 5 · unpushed work that isn't b's own line (a hand merge of something else) is never folded away
git("branch", "side", "main")
commit_on("side", "side.txt", "side\n", "side work")
git("checkout", "-q", "b")
git("merge", "-q", "--no-ff", "-m", "merge side by hand", "side")
git("checkout", "-q", "main")
commit_on("a", "a7.txt", "a7\n", "a7", pushed=True)
before = git("rev-parse", "b")
res = catchup.catch_up("b")
check("a hand merge in the unpushed tail keeps the catch-up on the local tip",
      res["ok"] and git("rev-parse", "b^1") == before and git("show", "b:side.txt") == "side", res)
git("update-ref", "refs/remotes/origin/b", "b")   # (Phil's call; out of this test's scope)

# 6 · a parent's push carries a child's catch-up, never the child's own unpushed commits
git("branch", "c", "b")
git("config", "branch.c.stack-parent", "b")
git("config", "branch.c.description", "add c")
commit_on("c", "c.txt", "c\n", "feat: add c", pushed=True)
git("branch", "d", "b")
git("config", "branch.d.stack-parent", "b")
commit_on("d", "d.txt", "d\n", "feat: add d", pushed=True)
commit_on("c", "c.txt", "c in review\n", "apply review fix")      # c has unpushed work, d doesn't
commit_on("b", "b3.txt", "b3\n", "b3", pushed=True)
pushed = []
carried = {r["branch"]: r for r in catchup.carry("b", lambda br: (pushed.append(br) or True, ""))}
check("both children catch up", anc("b", "c") and anc("b", "d"), carried)
check("the child with only a catch-up is pushed", "d" in pushed and carried["d"].get("pushed") is True, carried)
check("the child with unpushed commits of its own is not", "c" not in pushed and not carried["c"].get("pushed"), carried)
check("…and isn't reported as a failure", not carried["c"].get("err") and carried["c"].get("unpushed") == 1, carried)
check("…though the door would take it when Phil pushes", door("c") is not None and
      [len(p) for _, p, _ in outgoing("c")] == [1, 2], outgoing("c"))

# 7 · a landed parent: the catch-up to main also goes under unpushed work
git("checkout", "-q", "main")
git("merge", "-q", "--squash", "a")
git("commit", "-q", "-m", "add a (#1)")
git("update-ref", "refs/remotes/origin/main", "main")
commit_on("b", "b4.txt", "b4\n", "apply the last review fix", who="phil")
want = merged_tree("b", "origin/main", base=git("merge-base", "b", "a"))
how, new_tip, err = catchup.land_plan("b", git("rev-parse", "a"))
check("a landed parent's child plans a merge", how == "merged" and not err, (how, err))
check("…that moves b", not catchup._move("b", git("rev-parse", "b"), new_tip))
git("config", "branch.b.stack-parent", "main")
out = outgoing("b")
check("…the merge of main is the oldest outgoing commit, on origin's copy",
      len(out) == 2 and out[-1][1] == [git("rev-parse", "origin/b"), git("rev-parse", "origin/main")], out)
check("…the follow-up rides on top", len(out) == 2 and out[0][2] == "apply the last review fix"
      and git("log", "-1", "--format=%an", out[0][0]) == "phil", out)
check("…with the tree a merge on the local tip would have", tree("b") == want)
check("…and the door takes it", door("b")["ok"], door("b")["reasons"])

print(f"\n{'all passed' if not failures else f'{failures} failed'}")
sys.exit(1 if failures else 0)
