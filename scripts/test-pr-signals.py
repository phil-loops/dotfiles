#!/usr/bin/env python3
"""srv/prsignals.py: GitHub's search answer becomes each open PR's row icons — check runs and status contexts
bucketed as GitHub's checks summary draws them, unresolved threads only, approvals from latest reviews."""
import json
import os
import sys

import subprocess
import tempfile

import testenv  # noqa: F401,E402 — git here ignores the machine's config (testenv.py)

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))


class _State:
    @staticmethod
    def poke():
        pass


sys.modules["srv.state"] = _State
from srv import ctx, prsignals  # noqa: E402

failures = 0


def check(name, ok, detail=""):
    global failures
    print(("✓ " if ok else "✗ ") + name + ("" if ok else f" — {detail}"))
    failures += 0 if ok else 1


def counts(**kw):
    return [{"state": k, "count": v} for k, v in kw.items()]


ANSWER = {"data": {"search": {"nodes": [
    {"number": 11733, "mergeable": "CONFLICTING",
     "latestReviews": {"nodes": [{"state": "APPROVED"}, {"state": "COMMENTED"}, {"state": "APPROVED"}]},
     "reviewThreads": {"nodes": [{"isResolved": True}, {"isResolved": False}]},
     "comments": {"totalCount": 3},
     "commits": {"nodes": [{"commit": {"statusCheckRollup": {"contexts": {
         "checkRunCountsByState": counts(SUCCESS=2, FAILURE=1, IN_PROGRESS=1, QUEUED=1, SKIPPED=5, TIMED_OUT=1),
         "statusContextCountsByState": counts(SUCCESS=1, PENDING=2, ERROR=1)}}}}]}},
    {"number": 11712, "mergeable": "MERGEABLE",
     "latestReviews": {"nodes": [{"state": "CHANGES_REQUESTED"}]},
     "reviewThreads": {"nodes": []}, "comments": {"totalCount": 0},
     "commits": {"nodes": [{"commit": {"statusCheckRollup": None}}]}},
    {}]}}}

got = prsignals.parse(json.dumps(ANSWER))
a, b = got["11733"], got["11712"]
check("check runs and status contexts share buckets; skipped counts nowhere",
      a["checks"] == {"pass": 3, "fail": 3, "running": 1, "queued": 3}, a["checks"])
check("only unresolved threads count", a["threads"] == 1, a)
check("approvals from latest reviews", a["approvals"] == 2 and not a["changesRequested"], a)
check("a conflicting PR says so", a["conflicts"] and not b["conflicts"], (a, b))
check("no rollup yet is zero checks, not a crash", b["checks"] == {"pass": 0, "fail": 0, "running": 0, "queued": 0}, b)
check("changes requested", b["changesRequested"] and b["approvals"] == 0, b)
check("a non-PR search hit is skipped", sorted(got) == ["11712", "11733"], got)
check("an error answer is no answer", prsignals.parse('{"errors": [{"message": "x"}]}') is None)
check("garbage is no answer", prsignals.parse("not json") is None)

# a native GitHub stack: which open PRs sit above each one, and which of those hold unpushed commits here
def entry(pos, number, state, head):
    return {"position": pos, "pullRequest": {"number": number, "state": state, "headRefName": head}}


STACK = {"entries": {"nodes": [entry(3, 30, "OPEN", "top"), entry(1, 10, "MERGED", "bottom"), entry(2, 20, "OPEN", "middle"),
                               entry(4, 40, "CLOSED", "dropped")]}}
up = prsignals.above(json.dumps({"data": {"search": {"nodes": [
    {"number": 20, "stack": STACK}, {"number": 30, "stack": STACK}, {"number": 99, "stack": None}, {}]}}}))
check("the open PRs above one in its stack, bottom to top", up == {"20": ["top"]}, up)
check("an answer without stacks, or no answer, names nothing",
      prsignals.above('{"errors": [{"message": "no such field"}]}') == {} and prsignals.above("not json") == {})

env = {**os.environ, "GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@t", "GIT_COMMITTER_NAME": "t", "GIT_COMMITTER_EMAIL": "t@t"}
repo = os.path.join(tempfile.mkdtemp(prefix="pr-signals-"), "r")
subprocess.run(["git", "init", "-q", "-b", "main", repo], check=True, env=env)


def git(*a):
    return subprocess.run(["git", "-C", repo, *a], capture_output=True, text=True, env=env, check=True).stdout.strip()


git("commit", "-q", "--allow-empty", "-m", "base")
for b in ("top", "pushed"):
    git("branch", b, "main")
    git("update-ref", f"refs/remotes/origin/{b}", b)
git("checkout", "-q", "top")
git("commit", "-q", "--allow-empty", "-m", "review fix")
git("commit", "-q", "--allow-empty", "-m", "another")
git("checkout", "-q", "main")
ctx.CWD = ctx.MAIN_WT = repo
ctx.run = lambda argv, **kw: subprocess.run(argv, capture_output=True, text=True, env=env, cwd=repo)
check("a branch above with unpushed commits is named with its count",
      prsignals.strands(["top", "pushed", "not-here"]) == [{"branch": "top", "commits": 2}], prsignals.strands(["top", "pushed", "not-here"]))

answers = {"stack": json.dumps({"data": {"search": {"nodes": [{"number": 11712, "stack": {"entries": {"nodes": [
    entry(1, 11712, "OPEN", "below"), entry(2, 11733, "OPEN", "top")]}}}]}}})}


def gh(argv, **kw):
    if argv[:3] == ["gh", "api", "graphql"]:
        body = answers["stack"] if "stack{" in argv[4] else json.dumps(ANSWER)
        return subprocess.CompletedProcess(argv, 0 if body else 1, body or "", "")
    return subprocess.run(argv, capture_output=True, text=True, env=env, cwd=repo)


ctx.run = gh
prsignals._refresh(repo, "o/r")
now = prsignals.current()
check("the PR below says what merging it would strand", now["11712"]["strands"] == [{"branch": "top", "commits": 2}], now["11712"])
check("…a PR with nothing above says nothing, and the stack lookup stays inside", now["11733"]["strands"] == [] and "above" not in now["11712"], now)
git("update-ref", "refs/remotes/origin/top", "top")   # pushed
check("…and it clears on the next read once that branch is pushed", prsignals.current()["11712"]["strands"] == [])
answers["stack"] = ""
prsignals._refresh(repo, "o/r")
check("a failed stack lookup still returns the row icons", prsignals.current()["11733"]["threads"] == 1 and prsignals.current()["11712"]["strands"] == [])
sys.exit(1 if failures else 0)
