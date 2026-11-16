#!/usr/bin/env python3
"""evidence_core's judgment rules, on a throwaway cache + ledger (no rendering, no repo)."""
import copy
import json
import os
import sys
import tempfile

tmp = tempfile.mkdtemp()
os.environ["EVIDENCE_CACHE"] = os.path.join(tmp, "cache")
os.environ["EVIDENCE_LEDGER"] = os.path.join(tmp, "ledger.jsonl")
sys.path.insert(0, os.path.dirname(os.path.realpath(__file__)))
import evidence_core as E  # noqa: E402

failures = []


def check(cond, what):
    print(("ok   " if cond else "FAIL ") + what)
    if not cond:
        failures.append(what)


def blob(n):
    sha = f"{n:064x}"
    os.makedirs(os.path.dirname(E._blob(sha)), exist_ok=True)
    open(E._blob(sha), "wb").close()
    return sha


def publish(m):
    text = E._canon(m)
    mid = E._sha(text)
    E._write_atomic(E._manifest_path(mid), text)
    return mid


base = {
    "schema": E.SCHEMA, "repo": "r",
    "basis": {"beforeCommit": "b1", "afterCommit": "a1", "beforeTree": "bt", "afterTree": "at"},
    "recipe": {"name": "x", "digest": "d", "title": "X"},
    "expectation": "dark changes", "predict": {"dark": "changes"},
    "obligations": [{"id": "dark", "theme": "dark"}],
    "before": {"renderId": "rb", "scenes": {"dark": blob(1)}},
    "after": {"renderId": "ra", "scenes": {"dark": blob(2)}},
    "findings": [],
}
m1 = publish(base)

try:
    E.judge(m1, "maybe", "", "browser")
    check(False, "an unknown verdict is refused")
except E.Refused:
    check(True, "an unknown verdict is refused")
try:
    E.judge("0" * 64, "accept", "", "browser")
    check(False, "a manifest that doesn't exist can't be judged")
except E.Refused:
    check(True, "a manifest that doesn't exist can't be judged")

E.judge(m1, "accept", "looks right", "browser")
check(E.status(base, m1) == {"judged": True, "verdict": "accept", "at": E.status(base, m1)["at"],
                             "note": "looks right", "carriedFrom": None}, "Phil's own verdict reads back as his, not carried")
entry = json.loads(open(os.environ["EVIDENCE_LEDGER"]).read().splitlines()[-1])
check(entry["contents"] == base, "the ledger keeps what was judged, not just its id")

restacked = copy.deepcopy(base)
restacked["basis"] = {"beforeCommit": "b2", "afterCommit": "a2", "beforeTree": "bt2", "afterTree": "at2"}
restacked["before"]["renderId"] = "rb2"
m2 = publish(restacked)
s = E.status(restacked, m2)
check(s["judged"] and s["carriedFrom"] == m1, "identical pixels on a new tree carry the verdict, marked as carried")

for what, mutate in [
    ("a changed after-image", lambda m: m["after"]["scenes"].update(dark=blob(3))),
    ("a changed expectation", lambda m: m.update(expectation="dark changes subtly")),
    ("a changed scene obligation (same pixels)", lambda m: m["obligations"][0].update(focus="input")),
    ("a changed prediction", lambda m: m.update(predict={"dark": "same"})),
]:
    other = copy.deepcopy(restacked)
    mutate(other)
    mo = publish(other)
    check(not E.status(other, mo)["judged"], f"{what} carries nothing")

os.remove(E._blob(base["after"]["scenes"]["dark"]))
try:
    E.judge(m2, "accept", "", "browser")
    check(False, "a manifest whose images are gone can't be judged")
except E.Refused:
    check(True, "a manifest whose images are gone can't be judged")
check(E.blob_path("../../etc/passwd") is None, "blob lookup takes only a bare digest")

print(f"\n{len(failures)} failed" if failures else "\nall passed")
sys.exit(1 if failures else 0)
