#!/usr/bin/env python3
"""srv/routes.py — every POST declares what it touches and who may send it, and the one dispatcher
enforces that before any handler runs: a click-only or outward route refuses everyone but Phil's
click, a machine route refuses in the sandbox, and nothing else is refused. Table-driven, so a new
route is covered the moment it's declared."""
import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)


class _State:
    @staticmethod
    def poke():
        pass

    @staticmethod
    def written():
        return 0


sys.modules["srv.state"] = _State
from srv import actor, routes  # noqa: E402

failures = 0


def check(name, ok, detail=""):
    global failures
    print(("✓ " if ok else "✗ ") + name + ("" if ok else f" — {detail}"))
    failures += 0 if ok else 1


class Req:
    def __init__(self):
        self.status, self.body = None, None

    def _send(self, status, body):
        self.status, self.body = status, json.loads(body)


bad = {p: r.effects - set(routes.EFFECTS) for p, r in routes.POST.items() if r.effects - set(routes.EFFECTS)}
check("every route's effects are named ones", not bad, bad)
check("every route has a handler", all(callable(r.handler) for r in routes.POST.values()))

# swap each handler for a recorder: a refusal must stop the handler from running at all
ran = []
real = dict(routes.POST)
for p, r in real.items():
    routes.POST[p] = r._replace(handler=lambda req, raw, p=p: (ran.append(p), req._send(200, '{"ok":true}')))


def send(path, phil, sandbox):
    actor.is_phil = lambda req: phil
    if sandbox:
        os.environ["STACK_REVIEW_SANDBOX"] = "1"
    else:
        os.environ.pop("STACK_REVIEW_SANDBOX", None)
    ran.clear()
    r = Req()
    saw = (routes.POST.get(path) or routes.Route(None, frozenset(), False)).saw
    routes.post(r, path, json.dumps({saw: "abc1234"} if saw else {}))
    return r, bool(ran)


wrong = []
for p, r in real.items():
    clicked_only = r.phil or "outward" in r.effects
    for phil in (False, True):
        for sandbox in (False, True):
            got, called = send(p, phil, sandbox)
            want = "sandbox" if "machine" in r.effects and sandbox else "phil" if clicked_only and not phil else "run"
            ok = called if want == "run" else (not called and got.status == 403 and want in got.body.get("err", "").lower())
            if not ok:
                wrong.append((p, "phil" if phil else "session", "sandbox" if sandbox else "machine", want, got.status, called))
check("each route runs or refuses exactly as declared, for Phil and a session, in and out of the sandbox", not wrong, wrong[:6])

outward = [p for p, r in real.items() if "outward" in r.effects]
check("pushing to origin is declared outward", {"/push-origin", "/force-origin"} <= set(outward), outward)
routes.POST["/__open_outward__"] = routes.Route(lambda req, raw: ran.append("x"), frozenset({"outward"}), False)
got, called = send("/__open_outward__", False, False)
check("an outward route declared open still needs Phil's click", got.status == 403 and not called, (got.status, called))
del routes.POST["/__open_outward__"]
# Principle 2: a route that moves history or reaches outward names what it acted on, or says why not
moving = {p for p, r in real.items() if r.effects & {"history", "outward"}}
check("every history or outward route declares what it saw, or why not",
      all(real[p].saw or p in routes.UNPINNED for p in moving), sorted(p for p in moving if not real[p].saw and p not in routes.UNPINNED))
check("UNPINNED names only real unpinned routes", all(p in real and not real[p].saw for p in routes.UNPINNED),
      [p for p in routes.UNPINNED if p not in real or real[p].saw])
check("the unpinned list only shrinks: adding to it is a decision written here", set(routes.UNPINNED) <= {
    "/outline", "/review-address", "/lsp/rename", "/push-when-green", "/sync", "/prep-push",
    "/prep", "/restack", "/reseat-children", "/dirty-resolve", "/reconcile", "/review-apply", "/review-helix"},
      sorted(routes.UNPINNED))
actor.is_phil = lambda req: True
os.environ.pop("STACK_REVIEW_SANDBOX", None)
for p in ("/push-origin", "/gates-waive", "/force-origin", "/revert-commit", "/outline-undo", "/catch-up", "/squash"):
    ran.clear()
    r = Req()
    routes.post(r, p, "{}")
    check(f"{p} without what it saw is refused before its handler", r.status == 400 and r.body.get("unseen") and not ran, (r.status, r.body, ran))
got, called = send("/__nope__", True, False)
check("an unknown route is a 404", got.status == 404 and not called)

print(f"\n{'OK' if not failures else 'FAIL'} — {failures} failure(s)")
sys.exit(1 if failures else 0)
