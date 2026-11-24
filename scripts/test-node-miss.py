#!/usr/bin/env python3
"""Why a /node read rebuilt: the memo says expired, or which half of the key moved since the last read."""
import os
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from srv import memo, review  # noqa: E402

failures = 0


def check(name, ok, got=None):
    global failures
    print(("✓ " if ok else "✗ ") + name + ("" if ok else f" — got {got!r}"))
    failures += 0 if ok else 1


why = review._node_miss_why
check("a branch never read before", why("absent", None, "r1", "d1") == "first read")
check("a stored answer past its age", why("expired", ("r1", "d1"), "r1", "d1") == "expired")
check("refs moved", why("absent", ("r1", "d1"), "r2", "d1") == "refs moved")
check("both moved", why("absent", ("r1", "d1"), "r2", "d2") == "refs + dirt moved")
check("same key, nothing stored", why("absent", ("r1", "d1"), "r1", "d1") == "evicted or never stored")

check("memo: absent before a build", memo.state(("t", 1)) == "absent")
memo._FLIGHTS[("t", 2)] = object()
check("memo: a read that joins a running build isn't a miss", memo.state(("t", 2)) == "building")
memo._FLIGHTS.pop(("t", 2))
memo.get(("t", 1), lambda: "v")
check("memo: hit after", memo.state(("t", 1)) == "hit")
memo._ENTRIES[("t", 1)] = (time.monotonic() - memo._MAX_AGE - 1, "v", 1)
check("memo: expired past its age", memo.state(("t", 1)) == "expired")

print(f"\n{'OK' if not failures else 'FAILED'} — {failures} failure(s)")
sys.exit(1 if failures else 0)
