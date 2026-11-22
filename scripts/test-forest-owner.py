#!/usr/bin/env python3
"""One owning chat per forest (srv/forestowner.py, forest-own, the reference-transaction hook): who
may write, warn vs enforce, the generation guard, assignment at start, and the hook's backstop.
Runs against a throwaway repo and presence dir, never the real ones."""
import testenv  # noqa: F401,E402 — git here ignores the machine's config (testenv.py)
import json
import os
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
TMP = tempfile.mkdtemp(prefix="forest-owner-test-")
PRESENCE = os.path.join(TMP, "presence")
os.makedirs(PRESENCE)
os.environ["CLAUDE_SESSION_PRESENCE_DIR"] = PRESENCE
os.environ.pop("STACK_INITIATOR", None)
os.environ.pop("STACK_OWNER_CHECKED", None)
sys.path.insert(0, HERE)
from srv import forestowner as fo  # noqa: E402

REPO = os.path.join(TMP, "repo")
A = "aaaaaaaa-0000-4000-8000-000000000001"
B = "bbbbbbbb-0000-4000-8000-000000000002"
failures = 0


def check(name, ok, detail=""):
    global failures
    print(("✓ " if ok else "✗ ") + name + ("" if ok else f" — {detail}"))
    failures += 0 if ok else 1


def git(*args, env=None):
    return subprocess.run(["git", *args], cwd=REPO, capture_output=True, text=True, env=env)


def presence(session, pid=None, start=None, started_at=1):
    pid = pid or os.getpid()
    rec = {"session_id": session, "pid": pid, "start_time": start or fo._lstart(pid), "started_at": started_at}
    with open(os.path.join(PRESENCE, f"{session}.json"), "w") as f:
        json.dump(rec, f)


def forget(session):
    try:
        os.remove(os.path.join(PRESENCE, f"{session}.json"))
    except FileNotFoundError:
        pass


def observations():
    path = fo._observations(REPO)
    if not os.path.exists(path):
        return []
    with open(path) as f:
        return [json.loads(line) for line in f]


subprocess.run(["git", "init", "-q", REPO], check=True)
git("commit", "-q", "--allow-empty", "-m", "root")
git("branch", "b1")
git("config", "branch.b1.stack-project", "forest")
git("branch", "loose")

# liveness
presence(A)
check("a running conversation with its recorded start time is live", fo.live(A))
presence(B, start="Mon Jan  1 00:00:00 2001")
check("a recycled pid (start time differs) isn't live", not fo.live(B))
presence(B, started_at=5)
check("a newer conversation in the same process (/clear) ends the older one", not fo.live(A) and fo.live(B))
forget(B)
check("…and the older one is live again once that record is gone", fo.live(A))
check("no record at all isn't live", not fo.live("cccccccc-0000-4000-8000-000000000003"))

# verdicts
check("a write outside any forest is fine", fo.verdict(REPO, "", ("claude", A))[0] == "ok")
check("Phil is never refused by ownership", fo.verdict(REPO, "forest", ("phil", None))[0] == "ok")
check("maintenance isn't refused by ownership", fo.verdict(REPO, "forest", ("maintenance", "focus-sync"))[0] == "ok")
check("an unidentified caller isn't refused by ownership", fo.verdict(REPO, "forest", ("unknown", None))[0] == "ok")
check("a chat writing to a forest with no owner reads unowned", fo.verdict(REPO, "forest", ("claude", A))[0] == "unowned")

gen = fo.set_owner(REPO, "forest", A, 0, "test")
check("setting the owner bumps the generation", gen == 1 and fo.owner(REPO, "forest")["session"] == A)
check("the owner may write", fo.verdict(REPO, "forest", ("claude", A))[0] == "ok")
presence(B, pid=os.getppid(), started_at=1)
v, why = fo.verdict(REPO, "forest", ("claude", B))
check("another chat writing to a live owner's forest reads foreign, naming the owner", v == "foreign" and A[:8] in why, why)
forget(A)
check("once the owner's conversation ends, the forest reads unowned", fo.verdict(REPO, "forest", ("claude", B))[0] == "unowned")
check("…including for the ended owner itself", fo.verdict(REPO, "forest", ("claude", A))[0] == "unowned")
presence(A)

try:
    fo.set_owner(REPO, "forest", B, 0, "stale")
    check("a change read at an old generation is refused", False, "it went through")
except fo.Refused:
    check("a change read at an old generation is refused", True)

# initiator
check("STACK_INITIATOR wins over the chat's own id",
      fo.initiator({"STACK_INITIATOR": "phil", "CLAUDE_CODE_SESSION_ID": A}) == ("phil", None))
check("a chat's own id, when nothing else says", fo.initiator({"CLAUDE_CODE_SESSION_ID": A}) == ("claude", A))
check("nothing identified is unknown, never Phil", fo.initiator({}) == ("unknown", None))
check("an unrecognized initiator is unknown", fo.initiator({"STACK_INITIATOR": "bogus"}) == ("unknown", None))

# guard by mode
lines = []
v = fo.guard(REPO, "forest", "test write", "tool", branches=["b1"], who=("claude", B), out=lines.append)
obs = observations()
check("warn mode lets a foreign write through, says so, and records it",
      v == "foreign" and lines and obs and obs[-1]["verdict"] == "foreign" and obs[-1]["initiator"] == f"claude:{B}",
      f"{v} {lines} {obs[-1:]}")
git("config", "stack.forest-owner-mode", "enforce")
try:
    fo.guard(REPO, "forest", "test write", "tool", who=("claude", B), out=lines.append)
    check("enforce mode refuses a foreign write", False, "it went through")
except fo.Refused as e:
    check("enforce mode refuses a foreign write", A[:8] in str(e), str(e))
check("enforce mode lets the owner write", fo.guard(REPO, "forest", "x", "tool", who=("claude", A)) == "ok")
git("config", "stack.forest-owner-mode", "off")
n = len(observations())
fo.guard(REPO, "forest", "x", "tool", who=("claude", B), out=lines.append)
check("off mode records nothing", len(observations()) == n)
git("config", "--unset", "stack.forest-owner-mode")

# assignment at start
fo.set_owner(REPO, "forest", None, fo.generation(REPO, "forest"), "clear")
check("a chat starting a forest with no owner becomes its owner", fo.assign_if_unowned(REPO, "forest", ("claude", B)) == B)
check("…and a second chat doesn't take it from the live owner", fo.assign_if_unowned(REPO, "forest", ("claude", A)) == B)
check("Phil starting a forest assigns no chat", fo.assign_if_unowned(REPO, "other", ("phil", None)) is None)

# the CLI
cli = os.path.join(HERE, "forest-own")
envA = {**os.environ, "CLAUDE_CODE_SESSION_ID": A}
r = subprocess.run([cli, "adopt", "forest"], cwd=REPO, capture_output=True, text=True, env=envA)
check("adopting a forest with a live owner is refused", r.returncode == 1 and B[:8] in r.stderr, r.stderr)
r = subprocess.run([cli, "give", "forest", A], cwd=REPO, capture_output=True, text=True,
                   env={**os.environ, "CLAUDE_CODE_SESSION_ID": B})
check("the owner gives it to another live chat", r.returncode == 0 and fo.owner(REPO, "forest")["session"] == A, r.stderr)
r = subprocess.run([cli, "release", "forest"], cwd=REPO, capture_output=True, text=True, env=envA)
check("the owner releases it", r.returncode == 0 and not fo.owner(REPO, "forest"), r.stderr)
r = subprocess.run([cli, "adopt", "forest"], cwd=REPO, capture_output=True, text=True, env=envA)
check("a chat adopts a forest with no owner", r.returncode == 0 and fo.owner(REPO, "forest")["session"] == A, r.stderr)
r = subprocess.run([cli, "adopt", "forest"], cwd=REPO, capture_output=True, text=True,
                   env={k: v for k, v in os.environ.items() if k != "CLAUDE_CODE_SESSION_ID"})
check("only a chat adopts", r.returncode == 1)

# the hook backstop
hook = os.path.expanduser("~/.dotfiles/hooks/loops-reference-transaction")
git("config", "core.hooksPath", os.path.join(TMP, "hooks"))
os.makedirs(os.path.join(TMP, "hooks"))
os.symlink(hook, os.path.join(TMP, "hooks", "reference-transaction"))
envB = {**os.environ, "CLAUDE_CODE_SESSION_ID": B}
n = len(observations())
r = git("branch", "-f", "b1", "HEAD", env=envB)
obs = observations()
check("warn: a foreign chat's ref move goes through, with a warning and a record",
      r.returncode == 0 and "forest-own (warn)" in r.stderr and len(obs) == n + 1 and obs[-1]["layer"] == "hook",
      r.stderr + str(obs[-1:]))
git("config", "stack.forest-owner-mode", "enforce")
r = git("update-ref", "-d", "refs/heads/b1", env=envB)
check("enforce: a foreign chat can't even delete the forest's branch", r.returncode != 0 and git("rev-parse", "-q", "--verify", "b1").returncode == 0, r.stderr)
r = git("branch", "-f", "b1", "HEAD", env=envA)
check("enforce: the owner moves it", r.returncode == 0, r.stderr)
r = git("branch", "-f", "loose", "HEAD", env=envB)
check("enforce: a branch outside any forest is anyone's", r.returncode == 0, r.stderr)
r = git("branch", "-f", "b1", "HEAD", env={k: v for k, v in os.environ.items() if k != "CLAUDE_CODE_SESSION_ID"})
check("enforce: Phil's terminal (no chat id) is never refused", r.returncode == 0, r.stderr)
r = git("branch", "-f", "b1", "HEAD", env={**envB, "STACK_OWNER_CHECKED": "forest"})
check("a tool that already checked the forest isn't checked twice by the hook", r.returncode == 0, r.stderr)
r = git("branch", "-f", "b1", "HEAD", env={**os.environ, "STACK_INITIATOR": f"claude:{B}"})
check("enforce: a write made for a foreign chat (STACK_INITIATOR) is refused too", r.returncode != 0, r.stderr)
fake_home = os.path.join(TMP, "home")
os.makedirs(os.path.join(fake_home, ".dotfiles", "scripts"))
stub = os.path.join(fake_home, ".dotfiles", "scripts", "forest-own")
with open(stub, "w") as f:
    f.write("#!/bin/sh\necho boom >&2\nexit 1\n")
os.chmod(stub, 0o755)
r = git("branch", "-f", "b1", "HEAD", env={**envB, "HOME": fake_home})
check("a forest-own that crashes never blocks a move", r.returncode == 0, r.stderr)

# the restack queue carries who asked
from srv import restack  # noqa: E402
qdir = os.path.join(TMP, "queue")
os.makedirs(qdir)
restack._gitdir = lambda: qdir
with open(os.path.join(qdir, "restack-queue"), "w") as f:
    f.write("now legacy\nbatch two claude:abc\n")
check("a queue line written before initiators were recorded reads unknown, never Phil",
      restack._queue_read() == [("now", "legacy", "unknown"), ("batch", "two", "claude:abc")], str(restack._queue_read()))
restack._enqueue("fresh", "now", "phil")
check("a queued restack keeps who asked for it", ("now", "fresh", "phil") in restack._queue_read(), str(restack._queue_read()))

# the server checks a history route's caller before it runs
from srv import actor, ctx, routes  # noqa: E402
ctx.set_repo(REPO)
actor.is_phil = lambda req: getattr(req, "phil", False)


class Req:
    def __init__(self, sid=None, phil=False):
        self._actor, self._sid, self.phil = ("browser" if phil else "claude"), sid, phil


squash = routes.POST["/squash"]
body = json.dumps({"branch": "b1"})
why = routes._owner_refusal(squash, Req(B), "/squash", body)
check("enforce: a foreign chat's history route is refused, naming the owner", A[:8] in why, why)
check("…and the route hands its initiator to what it spawns", actor.current_initiator() == f"claude:{B}")
check("enforce: the owner's history route runs", routes._owner_refusal(squash, Req(A), "/squash", body) == "")
check("enforce: Phil's click runs", routes._owner_refusal(squash, Req(phil=True), "/squash", body) == "")
check("a gates run with fix counts as a history write",
      A[:8] in routes._owner_refusal(routes.POST["/gates"], Req(B), "/gates", json.dumps({"branch": "b1", "fix": True})))
check("…a plain gates run doesn't", routes._owner_refusal(routes.POST["/gates"], Req(B), "/gates", body) == "")

print(f"\n{'all passed' if not failures else f'{failures} failed'}")
sys.exit(1 if failures else 0)
