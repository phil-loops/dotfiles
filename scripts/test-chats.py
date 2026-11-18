#!/usr/bin/env python3
"""srv/chats.py (DESIGN.md round 27): each live chat with the work its binding names, matched by work
id; an unbound chat reads unbound, an ended one is absent, an unreadable journal never reads unbound.
A temp presence registry and journal; never ~/.claude/session-presence or the live journal."""
import json
import os
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
TMP = tempfile.mkdtemp(prefix="chats-test-")
os.environ["CLAUDE_SESSION_PRESENCE_DIR"] = os.path.join(TMP, "presence")
os.environ["CANOPY_WORK_JOURNAL"] = os.path.join(TMP, "journal.sqlite3")
os.makedirs(os.environ["CLAUDE_SESSION_PRESENCE_DIR"])
sys.path.insert(0, HERE)
from srv import chats, workjournal as wj  # noqa: E402

failures = 0


def check(name, ok, detail=""):
    global failures
    print(("✓ " if ok else "✗ ") + name + ("" if ok else f" — {detail}"))
    failures += 0 if ok else 1


ME = os.getpid()
START = " ".join(subprocess.run(["ps", "-o", "lstart=", "-p", str(ME)], capture_output=True, text=True).stdout.split())
BOUND, LOOSE, GONE = ("feedface-0000-4000-8000-00000000000" + c for c in "123")


def presence(sid, pid=ME, start=START, **extra):
    with open(os.path.join(os.environ["CLAUDE_SESSION_PRESENCE_DIR"], sid + ".json"), "w") as f:
        json.dump({"session_id": sid, "pid": pid, "start_time": start, "repo_name": "loops-wt-1", "branch": "wt-1",
                   "tmux_pane": "%9", "last_active": 100, **extra}, f)


presence(BOUND)
presence(LOOSE)
presence(GONE, pid=999999, start="never")
check("no journal: every live chat is unbound, the ended one absent",
      {k: v["works"] for k, v in chats.entities()["chat"].items()} == {BOUND: [], LOOSE: []}, chats.entities())

j = wj.Journal()
w = j.mint_branch_work("loops", "feat/x")
fp = chats.fingerprint()
gen = j.bind_session(BOUND, [w], by="test")
j.close()
got = chats.entities()["chat"]
check("a bound chat names its work by id, with the branch only as a label",
      got[BOUND]["works"] == [{"work": w, "todo": None, "repo": "loops", "branch": "feat/x"}] and got[BOUND]["generation"] == gen, got[BOUND])
check("an unbound chat says where it stands, never what it works on",
      got[LOOSE]["works"] == [] and got[LOOSE]["at"] == {"repo": "loops-wt-1", "branch": "wt-1"} and got[LOOSE]["pane"] == "%9", got[LOOSE])

presence(LOOSE, start="Thu Jan  1 00:00:00 1970")
check("a recycled pid is not the chat", LOOSE not in chats.entities()["chat"], chats.entities()["chat"].keys())
check("the fingerprint moves when a record is rewritten", chats.fingerprint() != fp)

j = wj.Journal()
j.retire_work(w)
j.close()
check("retired work is no longer what a chat is on", chats.entities()["chat"][BOUND]["works"] == [], chats.entities()["chat"][BOUND])

with open(os.environ["CANOPY_WORK_JOURNAL"], "r+b") as f:
    f.write(b"not a database" * 100)
got = chats.entities()["chat"][BOUND]
check("an unreadable journal says so instead of reading unbound", got["works"] is None and "unreadable" in got.get("bindingError", ""), got)

sys.exit(1 if failures else 0)
