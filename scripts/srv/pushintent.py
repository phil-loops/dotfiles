"""A push Phil queued for when the gates go green (Phil 2026-11-18: push before the gates answer, and
make it principled and scalable — the usual case is one press, and only shipping WITHOUT them costs a
second).

  POST /push-when-green {branch}          Phil's press: queue the push, start the gates if nothing is
                                          running on this tree, settle at once if a verdict already stands
  POST /push-when-green {branch, cancel}  take the press back (u)

One record, tied to the code: branch.<b>.stack-push-when-green-tree (+ -by), the waiver's shape — a
new commit retires it, so a press never ships code it wasn't made on. Only Phil's click writes it
(routes: phil=True). resolve(b) settles it once the run for that tree has answered: green → the same
door as p (push.push_now: every ward recomputed, children carried); red, moved code, or a branch
origin already has → cancelled. The intent is cleared BEFORE the push, under one lock, so two
resolvers never push twice. Every run a queue starts gets a watcher that resolves on exit; sweep()
on the pregate tick catches what a restart missed. What happened is recorded (-said, with its time)
and shown on the branch for an hour."""
import json
import threading
import time

from . import ctx, forestlock, push, repostate, stackcfg

TREE, BY, SAID = "push-when-green-tree", "push-when-green-by", "push-when-green-said"
SAID_FOR_S = 3600
_LOCK = threading.Lock()


def queued(branch, snap=None, tree=None):
    """Whether a queued push stands for the branch's current tree (`tree` when the caller has it)."""
    snap = snap or repostate.snapshot()
    at = snap.branch_key(branch, TREE)
    return bool(at) and at == (tree or snap.tree(snap.local(branch)))


def said_at(branch, snap=None):
    """(what the last queued push came to, when) — or (None, None). The reader decides how long it
    shows: a time-bounded field computed here would go stale on a fingerprint that has no clock."""
    snap = snap or repostate.snapshot()
    text, _, at = (snap.branch_key(branch, SAID) or "").rpartition("|")
    try:
        return (text, float(at)) if text else (None, None)
    except ValueError:
        return None, None


def said(branch, snap=None, now=None):
    """What the last queued push came to, for an hour after it did; else None."""
    text, at = said_at(branch, snap)
    return text if text and (now or time.time()) - at < SAID_FOR_S else None


def _settle(branch, text):
    stackcfg.unset_all(branch, TREE)
    stackcfg.unset_all(branch, BY)
    if text:
        stackcfg.set_key(branch, SAID, f"{text}|{int(time.time())}")
    repostate.invalidate()
    ctx.bump_pulse()


def _blocking(branch):
    """The door's wards that would refuse this push for a reason other than its gates."""
    v = push._origin_verdict(branch)
    if v is None:
        return ["no such branch"]
    gates_why = {w.get("why") for w in v.get("wards", []) if w.get("k") == "gates"}
    return [r for r in v.get("reasons", []) if r not in gates_why]


def _pushed_already(branch):
    snap = repostate.snapshot()
    local, remote = snap.local(branch), snap.remote(branch)
    return bool(local) and local == remote


def resolve(branch, locked=False):
    """Settle the branch's queued push if its gates have answered. Returns what it did, or None
    while it waits. `locked`: the caller already holds the branch's forest lock (a POST)."""
    with _LOCK:
        repostate.invalidate()
        snap = repostate.snapshot()
        at = snap.branch_key(branch, TREE)
        if not at:
            return None
        tree = push._tree(branch)
        if at != tree:
            _settle(branch, "queued push cancelled — the code changed after you queued it")
            return "cancelled"
        if _pushed_already(branch):
            _settle(branch, "")
            return "pushed already"
        if not push.verdict_stands(branch):
            run = push.gate_run(branch)
            if run and run.meta.get("tree") == tree and run.alive():
                return None
            result = push.gate_result(run) if run and run.meta.get("tree") == tree else None
            if result and result.get("ok"):
                push._harvest_green(branch, tree, result.get("gates", []))
                repostate.invalidate()
            elif result:
                reds = [g.get("name", "?") for g in result.get("gates", []) if not g.get("ok") and not g.get("advisory")]
                _settle(branch, f"queued push cancelled — {', '.join(reds) or 'the gates'} went red")
                return "cancelled"
            else:
                watch(branch, push._spawn_gates(branch, background=False))
                return None
            if not push.verdict_stands(branch):
                return None
        why = _blocking(branch)
        if why:
            _settle(branch, "queued push didn't go — " + "; ".join(why))
            return "refused"
        stackcfg.unset_all(branch, TREE)   # cleared before the push: a second resolver finds nothing
        try:
            if locked:
                res = push.push_now(branch, stay=True)
            else:
                with forestlock.hold(ctx.repo_cwd(), forestlock.key_for(ctx.repo_cwd(), branch=branch),
                                     "push when green", wait=60, export=False):
                    res = push.push_now(branch, stay=True)
        except forestlock.Held as e:
            stackcfg.set_key(branch, TREE, tree)   # someone is changing the forest: try again next tick
            ctx.log(f"push-when-green: {branch} waits — {e}")
            return None
        _settle(branch, "pushed when the gates went green" if res.get("ok")
                else f"queued push didn't go — {res.get('err') or 'the push was refused'}")
        return "pushed" if res.get("ok") else "refused"


def watch(branch, run):
    """Resolve the branch's queued push the moment `run` exits."""
    if not run:
        return

    def _wait():
        while run.alive():
            time.sleep(2)
        try:
            resolve(branch)
        except Exception as e:   # a watcher must never take the server down; the sweep retries
            ctx.log(f"push-when-green: resolving {branch} failed: {e!r}")
    threading.Thread(target=_wait, daemon=True).start()


def sweep():
    """Resolve every queued push — what a restart's lost watchers left (the pregate tick)."""
    out = ctx.run(["git", "config", "--get-regexp", r"^branch\..*\.stack-" + TREE.replace("-", r"\-") + "$"]).stdout
    for line in out.splitlines():
        key = line.split(" ", 1)[0]
        resolve(key[len("branch."):-len(".stack-" + TREE)])


def post(req, raw):
    d = json.loads(raw or "{}")
    branch = d.get("branch", "")
    tree = push._tree(branch) if branch else ""
    if not tree:
        return req._send(404, json.dumps({"ok": False, "err": f"no branch {branch or '(none)'}"}))
    if d.get("cancel"):
        stackcfg.unset_all(branch, TREE)
        stackcfg.unset_all(branch, BY)
        repostate.invalidate()
        ctx.bump_pulse()
        return req._send(200, json.dumps({"ok": True, "queued": False}))
    why = _blocking(branch)
    if why:
        return req._send(200, json.dumps({"ok": False, "err": "; ".join(why)}))
    stackcfg.set_key(branch, BY, "Phil · " + time.strftime("%Y-%m-%d %H:%M"))
    stackcfg.set_key(branch, TREE, tree)
    run = push.gate_run(branch)
    if not push.verdict_stands(branch) and not (run and run.meta.get("tree") == tree and run.alive()):
        run = push._spawn_gates(branch, background=False)
    watch(branch, run)
    did = resolve(branch, locked=True)
    repostate.invalidate()
    ctx.bump_pulse()
    if did in ("refused", "cancelled"):   # the gates had answered already and the push couldn't go: say why
        return req._send(200, json.dumps({"ok": False, "err": said(branch) or "the push didn't go", "did": did}))
    req._send(200, json.dumps({"ok": True, "queued": did is None, "did": did}))
