#!/usr/bin/env python3
"""The gates verdict through a rebase (srv/push.py verdict_stands): a green recorded on the tip
stands as "tree"; after main advances and the branch is rebased forward it stands as "delta"
(the branch's own hunks are byte-identical); a new commit, or main landing inside a hunk's
context, lapses it; a harvested green for an older tree carries no delta."""
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
root = tempfile.mkdtemp(prefix="gates-delta-")
origin, repo = os.path.join(root, "o.git"), os.path.join(root, "r")
subprocess.run(["git", "init", "-q", "--bare", origin], check=True)
subprocess.run(["git", "init", "-q", "-b", "main", repo], check=True)


def git(*a):
    return subprocess.run(["git", "-C", repo, *a], capture_output=True, text=True, env=env, check=True).stdout.strip()


def write(path, text):
    with open(os.path.join(repo, path), "w") as f:
        f.write(text)


ctx.CWD = ctx.MAIN_WT = repo
ctx.SCRIPTS = HERE
ctx.run = lambda argv, **kw: subprocess.run(argv, cwd=repo, capture_output=True, text=True, env=env)
from srv import push, repostate  # noqa: E402


def stands(b):
    repostate.invalidate()
    return push.verdict_stands(b)


git("remote", "add", "origin", origin)
write("a.txt", "one\ntwo\nthree\nfour\nfive\nsix\nseven\neight\nnine\nten\n")
write("b.txt", "alpha\nbeta\n")
git("add", "."); git("commit", "-q", "-m", "root"); git("push", "-q", "origin", "main")

# the branch changes one line of a.txt; its gates go green on the tip
git("checkout", "-q", "-b", "feat")
write("a.txt", "one\ntwo\nTHREE\nfour\nfive\nsix\nseven\neight\nnine\nten\n")
git("commit", "-q", "-am", "feat: three")
git("config", "branch.feat.stack-parent", "main")
repostate.invalidate()
push._record_green("feat", push._tree("feat"), [{"name": "tests", "ok": True}])
check("a green on the tip stands as tree", stands("feat") == "tree", stands("feat"))
check("…and records the delta beside it", git("config", "branch.feat.stack-gates-green-delta") != "")

# main moves in another file; the branch is rebased forward — its own hunk is unchanged
git("checkout", "-q", "main")
write("b.txt", "alpha\nbeta\ngamma\n"); git("commit", "-q", "-am", "main: gamma"); git("push", "-q", "origin", "main")
git("rebase", "-q", "main", "feat")
check("a forward rebase keeps the verdict as delta", stands("feat") == "delta", stands("feat"))

# polling the old run's progress re-offers its green for the pre-rebase tree: it must not lapse the carried one
pre_rebase_tree = git("rev-parse", "ORIG_HEAD^{tree}")
check("harvesting the old run's green leaves the carried verdict alone", not push._harvest_green("feat", pre_rebase_tree) and stands("feat") == "delta", stands("feat"))

# a carried verdict is asked on every snapshot (any config write starts one): it reads no new diff
spawned, _run = [], ctx.run
ctx.run = lambda argv, **kw: (spawned.append(argv) if argv[:2] == ["git", "diff"] else None, _run(argv, **kw))[1]
for _ in range(3):
    git("config", "branch.feat.stack-touched", "x")
    stands("feat")
ctx.run = _run
check("a carried verdict reads its diff once, not once per snapshot", spawned == [], spawned)

# the door and the state read the one answer
git("checkout", "-q", "main")
v = push._origin_verdict("feat")
gates_ward = next(w for w in v["wards"] if w["k"] == "gates")
check("the door's gates ward is green and says it was carried", gates_ward["ok"] and "carried" in gates_ward["label"], gates_ward)

# main lands inside the hunk's context: the id changes, the verdict lapses
# (line six is three lines past the change: inside the hunk's context, outside the conflict zone)
write("a.txt", "one\ntwo\nthree\nfour\nfive\nSIX\nseven\neight\nnine\nten\n"); git("commit", "-q", "-am", "main: six"); git("push", "-q", "origin", "main")
git("rebase", "-q", "main", "feat")
check("main landing in the hunk's context lapses it", stands("feat") == "", stands("feat"))

# a fresh green, then a new commit on the branch: lapsed
push._record_green("feat", push._tree("feat"))
check("a fresh green stands as tree again", stands("feat") == "tree")
git("checkout", "-q", "feat"); write("b.txt", "alpha\nbeta\ngamma\ndelta\n"); git("commit", "-q", "-am", "feat: delta"); git("checkout", "-q", "main")
check("a new commit on the branch lapses it", stands("feat") == "", stands("feat"))

# a harvested green for an older tree carries no delta
old_tree = git("rev-parse", "feat~1^{tree}")
push._record_green("feat", old_tree)
check("a green for an older tree records no delta", subprocess.run(["git", "-C", repo, "config", "branch.feat.stack-gates-green-delta"], capture_output=True, text=True).stdout.strip() == "")
check("…and does not stand", stands("feat") == "", stands("feat"))

print(f"\n{'OK' if not failures else 'FAIL'} — {failures} failure(s)")
sys.exit(1 if failures else 0)
