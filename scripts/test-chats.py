#!/usr/bin/env python3
"""srv/chats.py (DESIGN.md round 27): each live chat with the work its binding names, matched by work
id; an unbound chat reads unbound, an ended one is absent, an unreadable journal never reads unbound.
A temp presence registry and journal; never ~/.claude/session-presence or the live journal."""
import testenv  # noqa: F401,E402 — git here ignores the machine's config (testenv.py)
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

PANE_LABELS = {}
chats._read_labels = lambda: dict(PANE_LABELS)   # never the machine's tmux
chats.LABELS_TTL = 0

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

check("a chat without a pane label has none", got[LOOSE]["label"] is None, got[LOOSE])
fp = chats.fingerprint()
PANE_LABELS["%9"] = "canopy · chat labels"
check("a pane label moves the fingerprint, though no file changed", chats.fingerprint() != fp)
check("a chat carries its pane's label", chats.entities()["chat"][LOOSE]["label"] == "canopy · chat labels")
chats.LABELS_TTL, chats._LABELS["at"] = 60, float("-inf")
chats._labels()
PANE_LABELS["%9"] = "renamed"
check("within the TTL the labels are read once, not per tick", chats.entities()["chat"][LOOSE]["label"] == "canopy · chat labels")
chats.LABELS_TTL = 0
PANE_LABELS.clear()
fp = chats.fingerprint()

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

# round 28: the branches a chat acted on — its own edits and commits, recent, never a replay
import time as _time  # noqa: E402
now = _time.time()
presence(BOUND, acted={"loops:feat/edited": {"edit": now - 60}, "loops:feat/stale": {"edit": now - 3 * 3600}})
usage_repo = os.path.join(TMP, "usage-repo")
subprocess.run(["git", "init", "-q", "-b", "main", usage_repo], check=True)
from srv import ctx as _ctx  # noqa: E402
_ctx.REPOS = {"loops": usage_repo}
with open(os.path.join(usage_repo, ".git", "stack-usage.jsonl"), "w") as f:
    for e in [{"type": "commit", "branch": "feat/committed", "actor": "claude", "session": BOUND[:8], "ts": now - 30},
              {"type": "commit", "branch": "feat/replayed", "actor": "claude", "session": BOUND[:8], "replay": "rebase", "ts": now - 20},
              {"type": "commit", "branch": "feat/by-server", "actor": "server", "session": None, "ts": now - 10},
              {"type": "commit", "branch": "feat/old", "actor": "claude", "session": BOUND[:8], "ts": now - 3 * 3600},
              {"type": "commit", "branch": "feat/other-chat", "actor": "claude", "session": "deadbeef", "ts": now - 5},
              {"type": "commit", "branch": "feat/same-prefix", "actor": "claude", "session": BOUND[:8], "sessionId": BOUND[:-1] + "9", "ts": now - 4}]:
        f.write(json.dumps(e) + "\n")
acted = chats.entities()["chat"][BOUND]["acted"]
check("a chat is on the branches it edited or committed to lately, newest first, each with its evidence",
      [(a["branch"], a["how"]) for a in acted] == [("loops:feat/committed", "commit"), ("loops:feat/edited", "edit")], acted)
check("a replay, a server's commit, another chat's, or anything past two hours is no evidence",
      not {"loops:feat/replayed", "loops:feat/by-server", "loops:feat/old", "loops:feat/stale", "loops:feat/other-chat", "loops:feat/same-prefix"} & {a["branch"] for a in acted},
      "and a full id names exactly one chat, even one sharing its prefix")
os.environ["CANOPY_CHAT_DISMISSALS"] = os.path.join(TMP, "dismissals.json")


class _Req:
    def _send(self, code, body):
        self.code = code


r = _Req()
chats.dismiss(r, json.dumps({"session": BOUND, "branch": "loops:feat/committed"}))
acted = chats.entities()["chat"][BOUND]["acted"]
check("a dismissed link is hidden, the chat's other branches kept",
      r.code == 200 and [a["branch"] for a in acted] == ["loops:feat/edited"], acted)
with open(os.path.join(usage_repo, ".git", "stack-usage.jsonl"), "a") as f:
    f.write(json.dumps({"type": "commit", "branch": "feat/committed", "actor": "claude", "session": BOUND[:8], "sessionId": BOUND, "ts": _time.time() + 1}) + "\n")
check("acting there again brings it back", "loops:feat/committed" in [a["branch"] for a in chats.entities()["chat"][BOUND]["acted"]])
r = _Req()
chats.dismiss(r, json.dumps({"session": "short", "branch": "loops:x"}))
check("a malformed dismiss is refused", r.code == 400)
_ctx.REPOS = {}

# POST /chat-bind: Phil's click, decided from the generation his view showed (round 27, P7)
import json as _json  # noqa: E402
from srv import ctx  # noqa: E402

os.remove(os.environ["CANOPY_WORK_JOURNAL"])
repo = os.path.join(TMP, "repo")
genv = {**os.environ, "GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@t", "GIT_COMMITTER_NAME": "t", "GIT_COMMITTER_EMAIL": "t@t"}
for k in ("GIT_DIR", "GIT_INDEX_FILE", "GIT_WORK_TREE"):
    genv.pop(k, None)
subprocess.run(["git", "init", "-q", "-b", "main", repo], check=True, env=genv)
subprocess.run(["git", "-C", repo, "commit", "-q", "--allow-empty", "-m", "root"], check=True, env=genv)
subprocess.run(["git", "-C", repo, "branch", "old-branch"], check=True, env=genv)
ctx.CWD = ctx.MAIN_WT = repo
ctx.run = lambda argv, timeout=None, **kw: subprocess.run(argv, cwd=repo, capture_output=True, text=True, env=genv)


class Req:
    def _send(self, code, body):
        self.code, self.body = code, _json.loads(body)


def post(body):
    r = Req()
    chats.bind(r, _json.dumps(body))
    return r.code, r.body


code, body = post({"session": BOUND, "branch": "old-branch", "generation": 0})
work = subprocess.run(["git", "-C", repo, "config", "branch.old-branch.stack-work"], capture_output=True, text=True).stdout.strip()
check("a click binds a branch born before identities, giving it one", code == 200 and body["work"] == work and work.startswith("w_"), (code, body))
code, body = post({"session": BOUND, "branch": "old-branch", "generation": 0})
check("a click from a view of an older generation is refused with the binding now",
      code == 409 and body["current"] == {"generation": 1, "works": [work]}, (code, body))
check("a malformed click is refused in words", post({"session": "short", "branch": "old-branch", "generation": 1})[0] == 400)
check("a branch that isn't there is refused", post({"session": BOUND, "branch": "no-such", "generation": 1})[0] == 400)

sys.exit(1 if failures else 0)
