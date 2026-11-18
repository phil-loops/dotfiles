#!/usr/bin/env python3
"""test-stack-review-run-own-base.py — a review sees only what a branch adds, not what it carries.

Throwaway repo: `dep` adds x; `b` (parent main) carries dep's commit via `requires` and adds y.
own_base must fold the carried commit into the base so the reviewed diff is y alone; a branch with
no requires keeps its plain base.
"""
import importlib.machinery
import importlib.util
import os
import subprocess
import sys
import tempfile

here = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_loader(
    "srr", importlib.machinery.SourceFileLoader("srr", os.path.join(here, "stack-review-run")))
srr = importlib.util.module_from_spec(spec)
spec.loader.exec_module(srr)

env = dict(os.environ, GIT_AUTHOR_NAME="t", GIT_AUTHOR_EMAIL="t@t", GIT_COMMITTER_NAME="t", GIT_COMMITTER_EMAIL="t@t")
root = tempfile.mkdtemp(prefix="srr-own-base-")
repo = os.path.join(root, "repo")


def sh(*cmd):
    subprocess.run(cmd, cwd=repo if os.path.isdir(repo) else root, env=env, check=True, capture_output=True)


def write(name, text):
    with open(os.path.join(repo, name), "w") as f:
        f.write(text)


sh("git", "init", "-q", "-b", "main", repo)
write("base", "base\n"); sh("git", "add", "-A"); sh("git", "commit", "-qm", "base")
sh("git", "checkout", "-qb", "dep"); write("x", "x\n"); sh("git", "add", "x"); sh("git", "commit", "-qm", "dep: add x")
dep_commit = subprocess.run(["git", "rev-parse", "HEAD"], cwd=repo, capture_output=True, text=True).stdout.strip()
sh("git", "checkout", "-q", "main"); sh("git", "checkout", "-qb", "b")
sh("git", "cherry-pick", dep_commit)
write("y", "y\n"); sh("git", "add", "y"); sh("git", "commit", "-qm", "b: add y")
sh("git", "config", "branch.b.stack-parent", "main")
sh("git", "config", "--add", "branch.b.stack-requires", "dep")

failures = 0


def check(name, got, want):
    global failures
    if got == want:
        print(f"PASS  {name}")
    else:
        failures += 1
        print(f"FAIL  {name}: want {want!r} got {got!r}")


def files(branch, use_own_base):
    tip = srr.git(repo, "rev-parse", branch).stdout.strip()
    base = srr.git(repo, "merge-base", "main", tip).stdout.strip()
    if use_own_base:
        base, _ = srr.own_base(repo, branch, base, tip)
    return sorted(f for f in srr.git(repo, "diff", "--name-only", base, tip).stdout.split() if f)


check("parent...branch includes the carried file", files("b", False), ["x", "y"])
check("the review base folds in the carried commit", files("b", True), ["y"])
check("a branch with no requires keeps its plain base", files("dep", True), ["x"])
print(f"{3 - failures} passed, {failures} failed")
sys.exit(1 if failures else 0)
