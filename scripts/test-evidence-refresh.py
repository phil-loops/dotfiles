#!/usr/bin/env python3
"""srv/evidence._refresh's re-capture rules, with the run machinery stubbed (no server, no repo)."""
import os
import sys
import tempfile

tmp = tempfile.mkdtemp()
os.environ["EVIDENCE_CACHE"] = os.path.join(tmp, "cache")
os.environ["EVIDENCE_LEDGER"] = os.path.join(tmp, "ledger.jsonl")
sys.path.insert(0, os.path.dirname(os.path.realpath(__file__)))
import srv.evidence as S  # noqa: E402

failures = []


def check(cond, what):
    print(("ok   " if cond else "FAIL ") + what)
    if not cond:
        failures.append(what)


class Busy(Exception):
    pass


class Runs:
    Busy = Busy

    def __init__(self):
        self.started, self.alive, self.refuse = [], False, False

    def every(self, kind):
        return [type("R", (), {"alive": lambda _s: self.alive})()] if self.alive else []

    def start(self, kind, key, cmd, cwd, meta):
        if self.refuse:
            raise Busy()
        self.started.append(key)

    def prune(self, kind, kept):
        pass


fake = Runs()
S.runs = fake
S.E.busy = lambda repo: False
S._key = lambda branch: f"r/{branch}"
S._subject = lambda card: "subject-1"
S.ctx.repo_cwd = lambda: tmp


def stale(why=()):
    return {"request": {"recipe": "x"}, "id": "m1", "current": False, "eligible": not why, "why": list(why)}


fake.refuse = True
check(S._refresh("b", stale()) is None and not fake.started, "a start refused as busy starts nothing")
fake.refuse = False
check(S._refresh("b", stale()) == "subject-1" and fake.started == ["r/b"],
      "a refused start doesn't use up the subject's attempt")
check(S._refresh("b", stale()) is None and len(fake.started) == 1, "the same stale card doesn't start a second attempt")
gone = stale(why=["some of its images are gone from the cache — render it again"])
gone["current"] = True
check(S._refresh("b", gone) == "subject-1" and len(fake.started) == 2,
      "evidence that became unusable after its capture is re-captured, though the subject is unchanged")
check(S._refresh("b", gone) is None and len(fake.started) == 2, "and only once while it stays that way")
fake.alive = True
other = stale()
S._subject = lambda card: "subject-2"
check(S._refresh("c", other) is None and other.get("waiting") is True,
      "a stale card behind another evidence run says it's waiting, so the page keeps asking")
fake.alive = False
check(S._refresh("c", stale()) == "subject-2", "and starts once the machine is free")

print(f"\n{len(failures)} failed" if failures else "\nall passed")
sys.exit(1 if failures else 0)
