#!/usr/bin/env python3
"""srv/pushintent: a push Phil queued for when the gates go green settles exactly once — pushed
through the door on green, cancelled on red, on moved code, or by another ward; quiet when origin
already has it. Temp repo for the records; the gates run, the verdict and the push are stand-ins, so
nothing is spawned or pushed."""
import testenv  # noqa: F401,E402 — git here ignores the machine's config (testenv.py)
import contextlib
import os
import subprocess
import sys
import tempfile
import threading

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)


class _State:
    @staticmethod
    def poke():
        pass


sys.modules["srv.state"] = _State
from srv import ctx  # noqa: E402

env = {**os.environ, "GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@t", "GIT_COMMITTER_NAME": "t", "GIT_COMMITTER_EMAIL": "t@t"}
for k in ("GIT_DIR", "GIT_INDEX_FILE", "GIT_WORK_TREE"):
    env.pop(k, None)
repo = os.path.join(tempfile.mkdtemp(prefix="pwg-"), "r")
subprocess.run(["git", "init", "-q", "-b", "main", repo], check=True, env=env)
ctx.run = lambda argv, **kw: subprocess.run(argv, capture_output=True, text=True, env=env, cwd=kw.get("cwd", repo))
ctx.bump_pulse = lambda: None
ctx.log = lambda line: None
ctx.repo_cwd = lambda: repo


def git(*a):
    return ctx.run(["git", *a]).stdout.strip()


def commit(msg):
    with open(os.path.join(repo, "f"), "a") as f:
        f.write(msg + "\n")
    git("add", "f")
    git("commit", "-q", "-m", msg)


commit("base")
git("checkout", "-q", "-b", "b")
commit("work")


class Snap:
    def branch_key(self, b, k):
        return git("config", f"branch.{b}.stack-{k}")

    def local(self, b):
        return git("rev-parse", "--verify", "-q", f"refs/heads/{b}")

    def remote(self, b):
        return git("rev-parse", "--verify", "-q", f"refs/remotes/origin/{b}")

    def tree(self, sha):
        return git("rev-parse", f"{sha}^{{tree}}") if sha else ""


from srv import forestlock, push, repostate, pushintent  # noqa: E402

repostate.snapshot = Snap
repostate.invalidate = lambda: None
forestlock.hold = lambda *a, **k: contextlib.nullcontext()


class Run:
    def __init__(self, tree, alive=False):
        self.meta, self._alive = {"tree": tree}, alive

    def alive(self):
        return self._alive


world = {}


def reset(green=False, run=None, result=None, reasons=(), push_ok=True):
    world.update(green=green, run=run, result=result, reasons=list(reasons), push_ok=push_ok, pushes=0, spawned=0)
    git("config", "--unset-all", "branch.b.stack-push-when-green-said")


push._tree = lambda b: Snap().tree(Snap().local(b))
push.verdict_stands = lambda b, snap=None: "tree" if world["green"] else ""
push.gate_run = lambda b: world["run"]
push.gate_result = lambda run: world["result"]


def _harvest(b, tree, gates=()):
    world["green"] = True
    return True


push._harvest_green = _harvest
push._origin_verdict = lambda b: {"reasons": world["reasons"] + ([] if world["green"] else ["gates not green"]),
                                  "wards": [{"k": "gates", "why": "gates not green"}]}


def _push(b, stay=False):
    world["pushes"] += 1
    return {"ok": world["push_ok"], "err": "" if world["push_ok"] else "rejected"}


push.push_now = _push


def _spawn(b, **kw):
    world["spawned"] += 1
    return None


push._spawn_gates = _spawn


def queue():
    git("config", "branch.b.stack-push-when-green-tree", push._tree("b"))


def queued():
    return bool(git("config", "branch.b.stack-push-when-green-tree"))


def said():
    return pushintent.said("b") or ""


failures = 0


def check(name, ok, detail=""):
    global failures
    print(("✓ " if ok else "✗ ") + name + ("" if ok else f" — {detail}"))
    failures += 0 if ok else 1


tree = push._tree("b")

reset(run=Run(tree, alive=True))
queue()
check("a run still going: it waits", pushintent.resolve("b") is None and queued() and world["pushes"] == 0)

reset(run=Run(tree), result={"ok": True, "gates": []})
queue()
did = pushintent.resolve("b")
check("green: pushed once, through the door", did == "pushed" and world["pushes"] == 1, f"{did} {world}")
check("…the press is spent", not queued())
check("…and says so", said() == "pushed when the gates went green", said())

reset(run=Run(tree), result={"ok": False, "gates": [{"name": "typecheck", "ok": False}, {"name": "lint", "ok": True}]})
queue()
did = pushintent.resolve("b")
check("red: cancelled, nothing pushed", did == "cancelled" and world["pushes"] == 0 and not queued())
check("…naming what went red", "typecheck went red" in said(), said())

reset(green=True)
queue()
commit("more")   # the code moves after the press
did = pushintent.resolve("b")
check("moved code: cancelled, never ships what the press wasn't made on", did == "cancelled" and world["pushes"] == 0, did)
check("…and says why", "code changed" in said(), said())
tree = push._tree("b")

reset(green=True, reasons=["2 WIP commits"])
queue()
did = pushintent.resolve("b")
check("another ward refuses: nothing pushed, the ward's words", did == "refused" and world["pushes"] == 0 and "WIP" in said(), said())

reset(green=True)
queue()
git("update-ref", "refs/remotes/origin/b", Snap().local("b"))
did = pushintent.resolve("b")
check("origin already has it: settled quietly", did == "pushed already" and world["pushes"] == 0 and not queued() and said() == "", f"{did} {said()!r}")
git("update-ref", "-d", "refs/remotes/origin/b")

reset(run=None)
queue()
did = pushintent.resolve("b")
check("no run for this tree: starts one and waits", did is None and world["spawned"] == 1 and queued())

reset(green=True)
queue()
results = []
threads = [threading.Thread(target=lambda: results.append(pushintent.resolve("b"))) for _ in range(4)]
for t in threads:
    t.start()
for t in threads:
    t.join()
check("four resolvers at once: exactly one push", world["pushes"] == 1 and results.count("pushed") == 1, f"{world['pushes']} {results}")

reset(green=True)
check("nothing queued: nothing happens", pushintent.resolve("b") is None and world["pushes"] == 0)


class Req:
    def _send(self, code, body):
        self.code, self.body = code, __import__("json").loads(body)


reset(green=True, push_ok=False)
r = Req()
pushintent.post(r, '{"branch": "b"}')
check("a press whose push was tried at once and refused answers as a failure, never 'queued'",
      r.body.get("ok") is False and r.body.get("did") == "refused" and "didn't go" in r.body.get("err", ""), r.body)

reset(green=True)
r = Req()
pushintent.post(r, '{"branch": "b"}')
check("…and one that went says it pushed", r.body.get("ok") is True and r.body.get("did") == "pushed", r.body)

print(f"\n{'OK' if not failures else 'FAILED'} — {failures} failure(s)")
sys.exit(1 if failures else 0)
