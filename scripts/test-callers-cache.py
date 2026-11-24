#!/usr/bin/env python3
"""The server's kept answer for prod-callers (srv/callers.py): absent until asked for, running while the
script works, done and kept for exactly the tip and base it was computed from, and absent again once
either moves. A throwaway repo and cache dir; the script is a stand-in that echoes its arguments."""
import testenv  # noqa: F401,E402 — git here ignores the machine's config (testenv.py)
import json
import os
import subprocess
import sys
import tempfile

TMP = os.path.realpath(tempfile.mkdtemp(prefix="callers-cache-test-"))
REPO, FAKE = os.path.join(TMP, "repo"), os.path.join(TMP, "fake")
with open(FAKE, "w") as f:
    f.write("#!/bin/sh\n[ -f \"$FAIL\" ] && { echo 'the service is down' >&2; exit 1; }\nprintf '{\"args\": \"%s\"}' \"$*\"\n")
os.chmod(FAKE, 0o755)
os.environ.update(STACK_CALLERS_DIR=os.path.join(TMP, "cache"), STACK_CALLERS_CMD=FAKE, FAIL=os.path.join(TMP, "fail"))
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from srv import callers  # noqa: E402

failures = 0


def check(name, ok, detail=""):
    global failures
    print(("✓ " if ok else "✗ ") + name + ("" if ok else f" — {detail}"))
    failures += 0 if ok else 1


def git(*args):
    return subprocess.run(["git", "-C", REPO, *args], capture_output=True, text=True, check=True).stdout.strip()


os.makedirs(REPO)
git("init", "-q")
git("commit", "-q", "--allow-empty", "-m", "base")
git("branch", "-M", "main")
git("checkout", "-qb", "feature")
git("commit", "-q", "--allow-empty", "-m", "work")
tip, base = git("rev-parse", "feature"), git("rev-parse", "main")

check("a branch that isn't there has no answer", callers.look(REPO, 1, "nope") is None)
check("nothing is worked out until it's asked for", callers.look(REPO, 1, "feature") == {"ok": True, "tip": tip, "base": base, "state": "absent"})
held = []
check("asking starts it once", callers.look(REPO, 7, "feature", run=True, start=lambda: held.append(1))["state"] == "running"
      and callers.look(REPO, 7, "feature", run=True, start=lambda: held.append(2))["state"] == "running" and held == [1], held)
callers._running[(tip, base)].run()
got = callers.look(REPO, 7, "feature")
check("the answer is kept for the tip and base it came from, asked of this server's own port",
      got["state"] == "done" and got["result"] == {"args": f"{tip} --base {base} --repo {REPO} --port 7 --json"}, got)
git("commit", "-q", "--allow-empty", "-m", "more")
check("a moved tip is absent again", callers.look(REPO, 7, "feature")["state"] == "absent")
open(os.environ["FAIL"], "w").close()
callers.look(REPO, 7, "feature", run=True, start=lambda: None)
callers._running[(git("rev-parse", "feature"), base)].run()
got = callers.look(REPO, 7, "feature")
check("a failed run says why and keeps nothing", got["state"] == "failed" and got["message"] == "the service is down" and len(os.listdir(os.environ["STACK_CALLERS_DIR"])) == 1, got)
os.remove(os.environ["FAIL"])
callers.look(REPO, 7, "feature", run=True, start=lambda: None)
callers._running[(git("rev-parse", "feature"), base)].run()
check("the next run clears the failure", callers.look(REPO, 7, "feature")["state"] == "done")

print("--- all passed" if not failures else f"--- {failures} failed")
raise SystemExit(1 if failures else 0)
