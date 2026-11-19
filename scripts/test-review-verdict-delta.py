#!/usr/bin/env python3
"""The review verdict through a restack (srv/verdicts.py review_stands): a review harvested on the
tip stands as "tree"; after main advances and the branch is rebased forward it stands as "delta"
(the diff the reviewer read is byte-identical) and its flags still show; a finished run harvests
across a forward rebase; a new commit lapses it; a run that recorded no delta never carries."""
import testenv  # noqa: F401,E402 — git here ignores the machine's config (testenv.py)
import json
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
root = tempfile.mkdtemp(prefix="review-delta-")
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
from srv import push, repostate, verdicts  # noqa: E402


class FakeRun:
    """A finished review run, as srv/runs.py leaves one: its meta and its verdict.json."""
    def __init__(self, tree, delta, findings):
        self.id = f"run-{tree[:7]}-{delta[:7]}"
        self.meta = {"tree": tree, "delta": delta}
        self.dir = tempfile.mkdtemp(dir=root)
        with open(self.path("verdict.json"), "w") as f:
            json.dump({"ok": True, "tree": tree, "depth": "standard", "findings": findings}, f)

    def path(self, name):
        return os.path.join(self.dir, name)

    def alive(self):
        return False


def finished_review(findings=()):
    repostate.invalidate()
    run = FakeRun(push._tree("feat"), verdicts._delta("feat"), list(findings))
    verdicts.review_run = lambda branch: run
    return run


def stands():
    repostate.invalidate()
    return verdicts.review_stands("feat")


def flags():
    repostate.invalidate()
    got = push._review_flags("feat")
    return None if got is None else got["flags"]


git("remote", "add", "origin", origin)
write("a.txt", "one\ntwo\nthree\nfour\nfive\nsix\nseven\neight\nnine\nten\n")
write("b.txt", "alpha\nbeta\n")
git("add", "."); git("commit", "-q", "-m", "root"); git("push", "-q", "origin", "main")

git("checkout", "-q", "-b", "feat")
write("a.txt", "one\ntwo\nTHREE\nfour\nfive\nsix\nseven\neight\nnine\nten\n")
git("commit", "-q", "-am", "feat: three")
git("config", "branch.feat.stack-parent", "main")
git("checkout", "-q", "main")

finished_review([{"file": "a.txt", "line": 3, "verdict": "PLAUSIBLE", "summary": "shouting"}])
check("a harvested review stands as tree", (flags(), stands()) == (["a.txt:3 — (plausible) shouting"], "tree"), (flags(), stands()))
check("…and records the delta it read", git("config", "branch.feat.stack-review-flags-delta") != "")

# main moves in another file; the branch is rebased forward — the reviewed diff is unchanged
write("b.txt", "alpha\nbeta\ngamma\n"); git("commit", "-q", "-am", "main: gamma"); git("push", "-q", "origin", "main")
git("rebase", "-q", "main", "feat"); git("checkout", "-q", "main")
check("a forward rebase keeps the review as delta", stands() == "delta", stands())
check("…and its flags still show", flags() == ["a.txt:3 — (plausible) shouting"], flags())

# a run that finished before a forward rebase is still harvested after it
finished_review([])
write("b.txt", "alpha\nbeta\ngamma\nepsilon\n"); git("commit", "-q", "-am", "main: epsilon"); git("push", "-q", "origin", "main")
git("rebase", "-q", "main", "feat"); git("checkout", "-q", "main")
check("a run finished before a forward rebase is harvested after it", flags() == [] and stands() == "delta", (flags(), stands()))

# a new commit on the branch changes the diff the reviewer read: lapsed
git("checkout", "-q", "feat"); write("a.txt", "one\ntwo\nTHREE\nFOUR\nfive\nsix\nseven\neight\nnine\nten\n")
git("commit", "-q", "-am", "feat: four"); git("checkout", "-q", "main")
check("a new commit on the branch lapses it", (stands(), flags()) == ("", None), (stands(), flags()))

# a run recorded before deltas existed carries nothing through a rebase
run = finished_review([])
run.meta["delta"] = ""
check("a review without a delta stands only on its tree", flags() == [] and stands() == "tree", (flags(), stands()))
write("b.txt", "alpha\nbeta\ngamma\nepsilon\nzeta\n"); git("commit", "-q", "-am", "main: zeta"); git("push", "-q", "origin", "main")
git("rebase", "-q", "main", "feat"); git("checkout", "-q", "main")
check("…and lapses on a forward rebase", stands() == "", stands())

print(f"\n{'OK' if not failures else 'FAIL'} — {failures} failure(s)")
sys.exit(1 if failures else 0)
