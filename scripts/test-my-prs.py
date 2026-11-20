#!/usr/bin/env python3
"""srv/reviews.py mine(): Home's "my open PRs" is the open-PR listing filtered to my login — never anyone
else's, never everyone's when the login is unknown — decorated with review facts and whether the head is local."""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from srv import reviews  # noqa: E402

failures = 0


def check(name, ok, detail=""):
    global failures
    print(("✓ " if ok else "✗ ") + name + ("" if ok else f" — {detail}"))
    failures += 0 if ok else 1


PRS = [{"number": 11710, "title": "fix: link monitors", "url": "u1", "headRefName": "fix/monitors", "author": {"login": "phil"}, "isDraft": False},
       {"number": 11712, "title": "feat: tweak eval", "url": "u2", "headRefName": "tweak", "author": {"login": "phil"}, "isDraft": True},
       {"number": 11700, "title": "chore: flag", "url": "u3", "headRefName": "dan/flag", "author": {"login": "dan"}, "isDraft": False},
       {"number": 11650, "title": "cross pr", "url": "u4", "headRefName": "bench/x", "author": {"login": "phil"}, "isCrossRepository": True},
       {"number": 205, "title": "fork automation", "url": "u5", "headRefName": "bot/y", "author": {"login": "phil"}, "slug": "phil-loops/loops"}]
for p in PRS:
    p.setdefault("slug", "Loops-so/loops")
DETAIL = {"fix/monitors": {"approvals": 0, "changesRequested": True, "mergeState": "BLOCKED", "createdAt": "2026-11-19T14:00:00Z"}}
local = {"fix/monitors", "bench/x"}.__contains__

rows = reviews.mine(PRS, DETAIL, "phil", local, "Loops-so/loops")
check("only my PRs, newest first", [r["number"] for r in rows] == [11712, 11710, 11650], rows)
check("review facts ride along", rows[1]["changesRequested"] and rows[1]["mergeState"] == "BLOCKED", rows[1])
check("a draft says so", rows[0]["draft"] and not rows[0]["local"], rows[0])
check("a local head is local", rows[1]["local"], rows[1])
check("a cross-repo PR's head is never read as the local branch of that name", rows[2]["local"] is False, rows[2])
check("an unknown login lists nothing, not everyone's", reviews.mine(PRS, DETAIL, None, local, "Loops-so/loops") == [])
check("the fork's PRs are never listed", 205 not in [r["number"] for r in rows], rows)
check("no origin, no list", reviews.mine(PRS, DETAIL, "phil", local, None) == [])
sys.exit(1 if failures else 0)
