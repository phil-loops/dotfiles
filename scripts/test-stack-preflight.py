#!/usr/bin/env python3
"""stack-preflight on a real repo with a bare origin: the words and the commits a push adds, newest
first, for a never-pushed root, a re-push, a stacked child, and a branch origin is ahead of."""
import testenv  # noqa: F401 — git here ignores the machine's config (testenv.py)
import os
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
TOOL = os.path.join(HERE, "stack-preflight")
failures = 0


def check(name, ok, detail=""):
    global failures
    print(("✓ " if ok else "✗ ") + name + ("" if ok else f" — {detail}"))
    failures += 0 if ok else 1


def git(*a, cwd):
    return subprocess.run(["git", *a], cwd=cwd, check=True, capture_output=True, text=True).stdout.strip()


def commit(cwd, name, msg):
    with open(os.path.join(cwd, name), "a") as f:
        f.write(name + "\n")
    git("add", name, cwd=cwd)
    git("commit", "-q", "-m", msg, cwd=cwd)


def run(cwd, *args):
    p = subprocess.run([TOOL, "--no-gh", *args], cwd=cwd, capture_output=True, text=True)
    return p.returncode, p.stdout


with tempfile.TemporaryDirectory() as tmp:
    origin, work, other = (os.path.join(tmp, d) for d in ("origin.git", "work", "other"))
    git("init", "-q", "--bare", origin, cwd=tmp)
    git("clone", "-q", origin, work, cwd=tmp)
    commit(work, "base", "init")
    git("push", "-q", "origin", "main", cwd=work)

    git("checkout", "-q", "-b", "feat", cwd=work)
    git("config", "branch.feat.stack-parent", "main", cwd=work)
    git("config", "branch.feat.description", "adds the feature", cwd=work)
    commit(work, "a", "feat: add a\n\nbecause a was missing")
    commit(work, "b", "apply b")

    code, out = run(work)
    check("a never-pushed branch exits 0", code == 0, out)
    check("it says it was never pushed", "never pushed" in out, out)
    check("the description shows", "adds the feature" in out, out)
    check("what lands is the opening commit's words", "title  feat: add a" in out and "because a was missing" in out, out)
    adds = out.split("This push adds")[1]
    check("the push adds both commits, newest first", adds.index("apply b") < adds.index("feat: add a"), out)
    check("the code stat names both files", " a " in out.split("Code this push adds")[1] and " b " in out.split("Code this push adds")[1], out)

    git("push", "-q", "origin", "feat", cwd=work)
    commit(work, "c", "apply c\n\nthe why of c")
    code, out = run(work)
    adds = out.split("This push adds")[1].split("already on origin")[0]
    check("a re-push adds only the new commit", "apply c" in adds and "apply b" not in adds, out)
    check("the new commit's body shows under it", "the why of c" in adds, out)
    check("the pushed commits are listed as already on origin", "apply b" in out.split("already on origin")[1], out)
    check("the whole branch's size shows once published", "Code the whole branch lands" in out, out)

    git("checkout", "-q", "-b", "child", cwd=work)
    git("config", "branch.child.stack-parent", "feat", cwd=work)
    commit(work, "d", "feat: add d")
    code, out = run(work, "child")
    adds = out.split("This push adds")[1]
    check("a stacked child's push stops at its parent", "feat: add d" in adds and "apply c" not in adds, out)
    check("a child's landing words are its own opening commit", "title  feat: add d" in out, out)

    git("clone", "-q", "-b", "feat", origin, other, cwd=tmp)
    commit(other, "e", "someone else's e")
    git("push", "-q", "origin", "feat", cwd=other)
    code, out = run(work, "feat")
    check("origin being ahead is called out by commit", "origin has commits" in out and "someone else's e" in out, out)

    code, out = run(work, "nope")
    check("an unknown branch is refused", code != 0, out)

sys.exit(1 if failures else 0)
