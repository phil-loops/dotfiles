#!/usr/bin/env python3
"""srv/routes.py's dispatcher holds the forest for every history/outward route that names a branch:
a held forest answers 409 in words, /restack (which only queues) and non-history routes don't lock.
Temp repo, stub handlers — no server, no remote."""
import json
import os
import subprocess
import sys
import tempfile
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)


class _State:
    @staticmethod
    def poke():
        pass


sys.modules["srv.state"] = _State
from srv import ctx, routes  # noqa: E402

env = {**os.environ, "GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@t", "GIT_COMMITTER_NAME": "t", "GIT_COMMITTER_EMAIL": "t@t"}
for k in ("GIT_DIR", "GIT_INDEX_FILE", "GIT_WORK_TREE", "STACK_FOREST_LOCKED"):
    env.pop(k, None)
    os.environ.pop(k, None)
r = os.path.join(tempfile.mkdtemp(prefix="routes-lock-"), "r")
subprocess.run(["git", "init", "-q", "-b", "main", r], check=True, env=env)
subprocess.run(["git", "-C", r, "config", "branch.b.stack-project", "p"], check=True, env=env)
ctx.repo_cwd = lambda: r
routes.actor.is_phil = lambda req: True
failures = 0


def check(name, ok, detail=""):
    global failures
    print(("✓ " if ok else "✗ ") + name + ("" if ok else f" — {detail}"))
    failures += 0 if ok else 1


class Req:
    def __init__(self):
        self.code, self.body = None, None

    def _send(self, code, body):
        self.code, self.body = code, body


ran = []
routes.POST["/t-history"] = routes._r(lambda req, raw: ran.append("history") or req._send(200, "{}"), "history")
routes.POST["/t-read"] = routes._r(lambda req, raw: ran.append("read") or req._send(200, "{}"))
routes.POST["/restack"] = routes._r(lambda req, raw: ran.append("restack") or req._send(200, "{}"), "history")
orig_hold = routes.forestlock.hold
routes.forestlock.hold = lambda cwd, key, who, wait=30, export=False: orig_hold(cwd, key, who, wait=0.3, export=export)

body = json.dumps({"branch": "b"})
req = Req(); routes.post(req, "/t-history", body)
check("an unheld forest runs the handler", req.code == 200 and ran[-1:] == ["history"])

holder = subprocess.Popen([os.path.join(HERE, "forest-lock"), "p", "--who", "an agent's reshape", "--", "sleep", "20"], cwd=r, env=env)
for _ in range(100):
    if routes.forestlock.held(r, "forest-p"):
        break
    time.sleep(0.05)
ran.clear()
req = Req(); routes.post(req, "/t-history", body)
check("a held forest answers 409 and says who holds it", req.code == 409 and "an agent's reshape" in json.loads(req.body)["err"] and ran == [], req.body)
req = Req(); routes.post(req, "/t-read", body)
check("a route without history/outward effects doesn't lock", req.code == 200 and ran == ["read"])
req = Req(); routes.post(req, "/restack", json.dumps({"branch": "b", "project": "p"}))
check("/restack (it only queues) doesn't lock", req.code == 200 and ran[-1] == "restack")
req = Req(); routes.post(req, "/t-history", json.dumps({"branch": "elsewhere"}))
check("a branch in no forest locks alone, unaffected", req.code == 200)
holder.kill(); holder.wait()
req = Req(); routes.post(req, "/t-history", body)
check("the holder gone, the forest runs again", req.code == 200)
print("all passed" if not failures else f"{failures} failed")
sys.exit(1 if failures else 0)
