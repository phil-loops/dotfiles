#!/usr/bin/env python3
"""srv/openprs.py — the one owner of the repo's open PRs: one listing across origin and the fork
defines membership, guards get a fresh sweep, an outage keeps last-good and says so, and the
costly detail decorates listed PRs but never adds one."""
import json
import os
import sys
import time
import types

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from srv import ctx, openprs  # noqa: E402

failures = 0


def check(name, ok, detail=""):
    global failures
    print(("✓ " if ok else "✗ ") + name + ("" if ok else f" — {detail}"))
    failures += 0 if ok else 1


GH = {"Loops-so/loops": [{"number": 1, "headRefName": "feat", "isCrossRepository": False},
                         {"number": 2, "headRefName": "dan/x", "isCrossRepository": False}],
      "phil-loops/loops": [{"number": 7, "headRefName": "bench/y", "isCrossRepository": False}]}
DETAIL = [{"number": 1, "headRefName": "feat", "headRefOid": "b" * 40, "mergeStateStatus": "CLEAN", "mergeable": "MERGEABLE",
           "latestReviews": [{"state": "APPROVED", "submittedAt": "2026-11-18T10:00:00Z"}],
           "reviews": [{"state": "APPROVED", "submittedAt": "2026-11-17T10:00:00Z", "commit": {"oid": "0" * 40}},
                       {"state": "COMMENTED", "submittedAt": "2026-11-18T11:00:00Z", "commit": {"oid": "b" * 40}},
                       {"state": "APPROVED", "submittedAt": "2026-11-18T10:00:00Z", "commit": {"oid": "a" * 40}}]},
          {"number": 99, "headRefName": "closed-since", "mergeStateStatus": "CLEAN", "mergeable": "MERGEABLE", "latestReviews": []}]
calls, down = [], set()


def run(argv, **kw):
    if argv[:3] == ["git", "remote", "get-url"]:
        return types.SimpleNamespace(returncode=0, stdout={"origin": "git@github.com:Loops-so/loops.git",
                                                            "phil-loops": "https://github.com/phil-loops/loops.git"}[argv[3]] + "\n")
    if argv[:3] == ["gh", "pr", "list"]:
        slug = argv[argv.index("-R") + 1]
        detail = "mergeStateStatus" in argv[argv.index("--json") + 1]
        calls.append(("detail" if detail else "list", slug))
        if slug in down:
            return types.SimpleNamespace(returncode=1, stdout="")
        return types.SimpleNamespace(returncode=0, stdout=json.dumps(DETAIL if detail else GH[slug]))
    raise AssertionError(argv)


ctx.run = run
ctx.repo_cwd = lambda: "/repo"

check("heads span origin and the fork", openprs.heads() == {"feat", "dan/x", "bench/y"}, openprs.heads())
check("one sweep per remote", sorted(calls) == [("list", "Loops-so/loops"), ("list", "phil-loops/loops")], calls)
calls.clear()
openprs.heads(); openprs.of_slug("Loops-so/loops")
check("a fresh listing serves every reader without a sweep", calls == [], calls)
check("a slug's PRs are its own", [p["number"] for p in openprs.of_slug("Loops-so/loops")] == [1, 2])

openprs._listing["/repo"]["at"] -= openprs.FRESH_TTL + 1
openprs.heads(fresh=True)
check("a guard asking fresh gets a live sweep past 5 s", len(calls) == 2, calls)

calls.clear()
check("the extension can read a known PR without another GitHub call",
      openprs.cached_pr("loops-so/loops", 1)["headRefName"] == "feat" and not calls)
check("the same number on another remote is a miss", openprs.cached_pr("phil-loops/loops", 1) is None)

GH["Loops-so/loops"].append({"number": 3, "headRefName": "new", "isCrossRepository": False})
openprs._listing["/repo"]["at"] -= openprs.TTL + 1
calls.clear()
check("a stale PR lookup leaves refresh to the listing owner", openprs.cached_pr("Loops-so/loops", 1) is None and not calls)
stale = openprs.heads()
for _ in range(50):
    if openprs.heads() != stale:
        break
    time.sleep(0.02)
check("a stale listing answers at once and refreshes behind", "new" not in stale and "new" in openprs.heads(), (stale, openprs.heads()))

down |= {"Loops-so/loops", "phil-loops/loops"}
openprs._listing["/repo"]["at"] -= openprs.FRESH_TTL + 1
check("an outage keeps the last-good heads", "feat" in openprs.heads(fresh=True) and openprs.failed())
down.clear()
openprs._listing["/repo"]["at"] -= openprs.FRESH_TTL + 1
check("…and a working sweep clears it", "feat" in openprs.heads(fresh=True) and not openprs.failed())

openprs.detail()
for _ in range(50):
    if openprs.detail():
        break
    time.sleep(0.02)
d = openprs.detail()
check("detail decorates a listed PR", d.get("feat", {}).get("mergeState") == "CLEAN", d)
check("…and never adds one the listing doesn't have", "closed-since" not in d, d)
check("detail carries the PR's head and the commit its newest approval saw",
      d["feat"].get("headSha") == "b" * 40 and d["feat"].get("approvedSha") == "a" * 40, d["feat"])

openprs.seed("/repo", ["only"])
check("a test seeds the listing", openprs.heads() == {"only"} and not openprs.failed())

print(f"\n{'OK' if not failures else 'FAIL'} — {failures} failure(s)")
sys.exit(1 if failures else 0)
