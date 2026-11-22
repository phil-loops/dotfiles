#!/usr/bin/env python3
"""srv/prsignals.py: GitHub's search answer becomes each open PR's row icons — check runs and status contexts
bucketed as GitHub's checks summary draws them, unresolved threads only, approvals from latest reviews."""
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from srv import prsignals  # noqa: E402

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
sys.exit(1 if failures else 0)
