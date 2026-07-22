# srv/preview.py — spin a side-port `next dev` for a branch, and manage the running ones. Wraps
# the loops-preview script (auto-picks a free 3010-3060 port, borrows MAIN's node_modules/.env and
# the running Docker) so a branch renders in the browser WITHOUT moving the main checkout off :3000.
#   GET  /preview-wait     ?branch=  → HTML                   warming page: starts + watches the boot,
#                        | ?project=                           hands the tab off once the server answers
#   POST /preview          {branch}  → {ok, url, port, dir, reused?}  start, or attach to a running one
#   POST /preview-integration {project} → {ok, url, port, dir, reused?, dirty, fresh}  same, for a
#                                                             project's ✦integration playground worktree
#   POST /preview-main     {port?}    → {ok, url, port, dir, reused?}  run (or attach to) the literal
#                                                             main branch; prefer :3000 (or port), else free
#   POST /preview-kill     {dir}     → {ok}                   stop one (dir-string only; orphan-safe)
#   POST /preview-restart  {dir}     → {ok, url, port}        kill + fresh next dev on the SAME port
#   POST /preview-reap                → {ok, out}             stop orphaned/crashed previews
#   GET  /previews                    → {previews[], substrate}  health-probed list + shared dev stack
#   GET  /preview-log      ?dir=      → {ok, log}             tail the preview's next-dev log
#
# Health is more than "is the port open": a probe of the running preview classifies it as
# healthy / compiling / error / wedged, and dead/orphaned come from the port/worktree state.
# The substrate is the ONE shared Docker stack (Postgres/ClickHouse/Valkey/…) every preview and
# :3000 talk to — surfaced so the "what is this connected to, and is it isolated?" question is
# answerable (it is not isolated — writes are shared).
import json
import os
import re
import subprocess
import threading
import time
import urllib.error
import urllib.request
from concurrent.futures import ThreadPoolExecutor
from urllib.parse import parse_qs, urlparse

from . import ctx, checkout

_ANSI = re.compile(r"\x1b\[[0-9;?]*[a-zA-Z]")
# next-dev log markers, most-significant first — scanned bottom-up so the LATEST state wins.
_ERR = re.compile(r"(⨯|Failed to compile|Error:|SyntaxError|TypeError:)")
_READY = re.compile(r"(✓ Compiled|✓ Ready|Ready in)")
_COMPILING = re.compile(r"○ Compiling")


def _script():
    return os.path.join(ctx.SCRIPTS, "loops-preview")


# One shared snapshot of `loops-preview --json` (a multi-second shell of tmux/lsof/meta scans):
# /previews and /processes land within the same drawer-open beat and each paid the full run.
# Short TTL keeps ambient reads cheap; mutation paths pass fresh=True (an attach decision on a
# stale list would double-launch) and mutations invalidate so the next read sees the change.
_list_cache = {"at": 0.0, "data": None}
_LIST_TTL = 4.0
_list_lock = threading.Lock()


def _list_json(fresh=False):
    if not fresh and _list_cache["data"] is not None and time.monotonic() - _list_cache["at"] < _LIST_TTL:
        return _list_cache["data"]
    with _list_lock:
        if not fresh and _list_cache["data"] is not None and time.monotonic() - _list_cache["at"] < _LIST_TTL:
            return _list_cache["data"]
        try:
            p = subprocess.run([_script(), "--json"], capture_output=True, text=True, timeout=6)
            data = json.loads(p.stdout or "[]")
        except Exception:
            data = []
        _list_cache["data"], _list_cache["at"] = data, time.monotonic()
        return data


def _list_invalidate():
    _list_cache["at"] = 0.0


def _meta_get(name, key):
    try:
        with open("/tmp/loops-preview-%s.meta" % name) as f:
            for line in f:
                if line.startswith(key + "="):
                    return line.split("=", 1)[1].strip()
    except OSError:
        pass
    return ""


def _log_path(name):
    return "/tmp/loops-preview-%s.log" % name


def _log_state(name):
    # scan the log tail bottom-up: the most recent of error / compiling / ready. Returns
    # (state, summary) — summary is the error line when the last significant marker is an error.
    try:
        with open(_log_path(name)) as f:
            lines = f.readlines()[-400:]
    except OSError:
        return "", ""
    for raw in reversed(lines):
        line = _ANSI.sub("", raw).rstrip()
        if _ERR.search(line):
            return "error", line.strip()[:200]
        if _READY.search(line):
            return "ready", ""
        if _COMPILING.search(line):
            return "compiling", ""
    return "", ""


def _probe(port):
    # (status_code|None, latency_ms|None). A 5xx is still an HTTP response (compile/runtime error);
    # None means no response at all (refused/timeout) — the caller falls back to the log state.
    if not port:
        return None, None
    t0 = time.monotonic()
    try:
        with urllib.request.urlopen("http://127.0.0.1:%d/" % port, timeout=3) as r:
            return r.status, int((time.monotonic() - t0) * 1000)
    except urllib.error.HTTPError as e:
        return e.code, int((time.monotonic() - t0) * 1000)
    except Exception:
        return None, None


def _listening(port):
    # is anything holding the LISTEN socket on this port? Used before launching main: a mid-compile
    # task dev listens but doesn't answer HTTP yet, so a TCP check (not _probe) is what guards it.
    try:
        p = subprocess.run(["lsof", "-nP", "-iTCP:%d" % port, "-sTCP:LISTEN"],
                           capture_output=True, text=True, timeout=4)
        return p.returncode == 0 and bool(p.stdout.strip())
    except Exception:
        return False


def _health(pv):
    state = pv.get("state")
    if state == "orphaned":
        pv["health"] = "orphaned"
        return pv
    if state == "dead":
        pv["health"] = "dead"
        return pv
    port = int(pv["port"]) if str(pv.get("port", "")).isdigit() else 0
    code, lat = _probe(port)
    # an unmanaged stray has no preview log — and its dir's basename can collide with a
    # registered preview's log (same worktree, two servers), so never read one for it
    if pv.get("managed", True):
        logstate, summary = _log_state(pv.get("name", ""))
    else:
        logstate, summary = "", ""
    # A live probe is the strongest signal: <500 ⇒ healthy (it's serving now), ≥500 ⇒ error (the
    # page itself throws — a compile/runtime failure). Only when the probe gets no answer do we fall
    # back to the log: `next dev` prints "✓ Ready" the instant it boots but compiles a route on first
    # hit, so an idle just-booted server times out the probe without being broken — "ready" ⇒ healthy.
    if code is not None and code >= 500:
        pv["health"] = "error"
        pv["error"] = summary or ("HTTP %d" % code)
    elif code is not None:  # answered < 500 — serving
        pv["health"] = "healthy"
        pv["latency"] = lat
    elif logstate == "error":
        pv["health"] = "error"
        pv["error"] = summary
    elif logstate == "compiling":
        pv["health"] = "compiling"
    elif logstate == "ready":
        pv["health"] = "healthy"  # booted, last compile clean, probe just slow (on-demand compile)
    else:
        pv["health"] = "starting"  # listening but not yet ready in the log
    return pv


def _substrate():
    # the ONE shared dev stack (docker compose project "loops") that every preview + :3000 use —
    # NOT per-preview and NOT isolated, so a preview's writes hit the same Postgres/ClickHouse.
    # `ps -a`, not `ps`: a crashed container must count against the total, not vanish from it
    # (running-only listing once reported "10/10 up" while a container sat exited). Exited(0) is
    # a finished one-shot init job — shown as "done", excluded from the denominator.
    services = []
    try:
        p = subprocess.run(
            ["docker", "ps", "-a", "--filter", "label=com.docker.compose.project=loops",
             "--format", "{{.Names}}\t{{.Status}}"],
            capture_output=True, text=True, timeout=6)
        for line in p.stdout.strip().splitlines():
            parts = line.split("\t")
            if len(parts) >= 2:
                status = parts[1]
                up = status.startswith("Up")
                state = "up" if up else "done" if status.startswith("Exited (0)") else "failed"
                services.append({"name": parts[0], "status": status, "up": up, "state": state})
    except Exception:
        pass
    return {
        "project": "loops", "shared": True,
        "up": sum(1 for s in services if s["up"]),
        "total": sum(1 for s in services if s["state"] != "done"),
        "services": services,
    }


def wait(req):
    # the warming interstitial: served by THIS (always-alive) server so the tab a preview click
    # opens is never a refused connection — the page starts the preview, narrates the boot, and
    # location.replace()s to it once healthy. Re-read per request: hot-editable, nothing cached.
    try:
        with open(os.path.join(os.path.dirname(__file__), "preview-wait.html"), "rb") as f:
            body = f.read()
    except OSError:
        req._send(404, "preview-wait.html missing", "text/plain")
        return
    req._send(200, body, "text/html; charset=utf-8")


def _serve_dir(req, dirp, extra=None):
    # attach, don't restart: loops-preview cold-reboots an existing session (kills tmux, wipes
    # .next), so re-clicking preview on a warm checkout must NOT destroy the running server.
    for pv in _list_json(fresh=True):
        if pv.get("dir") == dirp and pv.get("state") == "up" and str(pv.get("port", "")).isdigit():
            port = int(pv["port"])
            req._send(200, json.dumps({"ok": True, "port": port, "url": "http://localhost:%d" % port,
                                       "dir": dirp, "reused": True, **(extra or {})}))
            return
    # loops-preview detaches the server into tmux and returns immediately with the URL on stdout.
    p = subprocess.run([_script(), dirp, "--main", checkout._active_main_wt()], capture_output=True, text=True)
    _list_invalidate()
    m = re.search(r"localhost:(\d+)", p.stdout)
    if not m:
        req._send(500, json.dumps({"ok": False, "err": (p.stderr or p.stdout or "preview failed").strip()[:400]}))
        return
    port = int(m.group(1))
    req._send(200, json.dumps({"ok": True, "port": port, "url": "http://localhost:%d" % port,
                               "dir": dirp, **(extra or {})}))


def start(req, raw):
    d = json.loads(raw or "{}")
    branch = d.get("branch", "")
    if not branch:
        req._send(400, json.dumps({"ok": False, "err": "no branch"}))
        return
    # resolve (materialise) the branch's worktree — same synchronous path checkout.worktree opens
    # in Finder, so a watched/PR branch checked out nowhere still gets a tree to run.
    r = ctx.run([os.path.join(ctx.SCRIPTS, "stack-open"), "--path", branch])
    dirp = (r.stdout or "").strip()
    if r.returncode != 0 or not dirp:
        req._send(500, json.dumps({"ok": False, "err": (r.stderr or "could not resolve a worktree").strip()}))
        return
    _serve_dir(req, dirp)


def _integrate_playground(project):
    # → (dir, {dirty, fresh}, err). stack-integrate --worktree rebuilds refs/stack/<project>-integration
    # and parks it in the project's persistent playground worktree — a directory loops-preview can serve.
    r = ctx.run([os.path.join(ctx.SCRIPTS, "stack-integrate"), project, "--worktree"])
    dirp, flags = "", {}
    for line in r.stdout.splitlines():
        key, _, val = line.strip().partition(": ")
        if key == "playground":
            dirp = val
        elif key in ("dirty", "fresh"):
            flags[key] = val == "1"
    if not dirp or not os.path.isdir(dirp):
        # exit 1 = the leaves conflict (stderr names them), 2 = no such project — and the caller
        # answers those differently: a name that doesn't exist is 404 like every other unknown
        # thing on this surface, a real refusal is 500.
        err = (r.stderr or r.stdout or "could not build the integration").strip()[:600]
        return "", {}, err, 404 if r.returncode == 2 else 500
    return dirp, flags, "", 200


def start_integration(req, raw):
    d = json.loads(raw or "{}")
    project = d.get("project", "")
    if not project:
        req._send(400, json.dumps({"ok": False, "err": "no project"}))
        return
    dirp, flags, err, code = _integrate_playground(project)
    if err:
        req._send(code, json.dumps({"ok": False, "err": err}))
        return
    _serve_dir(req, dirp, {"project": project, **flags})


def start_main(req, raw):
    # "run main": a web-only next dev for the LITERAL main branch, preferring :3000. main's worktree
    # is resolved the same way branch previews resolve theirs — its own checkout if the primary tree
    # is on main, else a materialised scratch worktree — so this serves main's code even when the
    # primary checkout is parked on a feature branch. main is a single server, so if one already
    # serves that worktree (any port) we ATTACH rather than launch a twin. The preferred port
    # (caller's, default 3000) is taken when free; when something else squats it we fall back to a
    # free side port — loops-preview wipes .next before it binds, so never point it at a busy port.
    d = json.loads(raw or "{}")
    r = ctx.run([os.path.join(ctx.SCRIPTS, "stack-open"), "--path", "main"])
    dirp = (r.stdout or "").strip()
    if r.returncode != 0 or not dirp:
        req._send(500, json.dumps({"ok": False, "err": (r.stderr or "could not resolve a main worktree").strip()}))
        return
    for pv in _list_json(fresh=True):
        if pv.get("dir") == dirp and pv.get("state") != "orphaned" and str(pv.get("port", "")).isdigit():
            port = int(pv["port"])
            req._send(200, json.dumps({"ok": True, "port": port, "url": "http://localhost:%d" % port,
                                       "dir": dirp, "reused": True}))
            return
    pref = int(d["port"]) if str(d.get("port", "")).isdigit() else 3000
    argv = [_script(), dirp, "--main", checkout._active_main_wt()]
    if not _listening(pref):
        argv += ["--port", str(pref)]  # preferred is free — take it; else loops-preview auto-picks a free side port
    p = subprocess.run(argv, capture_output=True, text=True)
    _list_invalidate()
    m = re.search(r"localhost:(\d+)", p.stdout)
    if not m:
        req._send(500, json.dumps({"ok": False, "err": (p.stderr or p.stdout or "launch failed").strip()[:400]}))
        return
    port = int(m.group(1))
    req._send(200, json.dumps({"ok": True, "port": port, "url": "http://localhost:%d" % port, "dir": dirp}))


def restart(req, raw):
    d = json.loads(raw or "{}")
    dirp = d.get("dir", "")
    if not dirp:
        req._send(400, json.dumps({"ok": False, "err": "no dir"}))
        return
    name = os.path.basename(dirp.rstrip("/"))
    argv = [_script(), dirp]
    port = _meta_get(name, "PORT")  # reclaim the same port so the open tab keeps working
    if port:
        argv += ["--port", port]
    argv += ["--main", checkout._active_main_wt()]
    p = subprocess.run(argv, capture_output=True, text=True)
    _list_invalidate()
    m = re.search(r"localhost:(\d+)", p.stdout)
    if not m:
        req._send(500, json.dumps({"ok": False, "err": (p.stderr or p.stdout or "restart failed").strip()[:400]}))
        return
    newport = int(m.group(1))
    req._send(200, json.dumps({"ok": True, "port": newport, "url": "http://localhost:%d" % newport, "dir": dirp}))


def kill(req, raw):
    d = json.loads(raw or "{}")
    dirp = d.get("dir", "")
    port = str(d.get("port", "") or "")
    if not dirp and not port:
        req._send(400, json.dumps({"ok": False, "err": "no dir"}))
        return
    # port pins the exact server — one dir can host a registered preview AND an unmanaged stray
    argv = [_script(), dirp or "/", "--kill"]
    if port:
        argv += ["--port", port]
    subprocess.run(argv, capture_output=True, text=True)
    _list_invalidate()
    req._send(200, json.dumps({"ok": True}))


def reap(req, raw):
    p = subprocess.run([_script(), "--reap"], capture_output=True, text=True)
    _list_invalidate()
    req._send(200, json.dumps({"ok": True, "out": (p.stdout or "").strip()}))


def previews(req):
    # the docker-ps substrate scan is independent of the preview list + probes — overlap them
    # so the drawer's cold open pays max(list+probes, docker), not the sum.
    with ThreadPoolExecutor(max_workers=1) as sub_ex:
        f_sub = sub_ex.submit(_substrate)
        pvs = [dict(pv) for pv in _list_json()]   # rows get annotated — never mutate the shared snapshot
        # _active_main_wt reads the request's pinned repo via a thread-local the probe pool WON'T
        # inherit (ctx.py gotcha), so resolve it once here and stamp every row with it.
        main_wt = checkout._active_main_wt()
        for pv in pvs:
            pv["borrows"] = main_wt
            if pv.get("managed", True):
                pv["log"] = _log_path(pv.get("name", ""))
        if pvs:
            with ThreadPoolExecutor(max_workers=min(8, len(pvs))) as ex:
                pvs = list(ex.map(_health, pvs))
        substrate = f_sub.result()
    req._send(200, json.dumps({"ok": True, "previews": pvs, "substrate": substrate}))


def log(req):
    q = parse_qs(urlparse(req.path).query)
    dirp = q.get("dir", [""])[0]
    name = os.path.basename(dirp.rstrip("/")) if dirp else q.get("name", [""])[0]
    if not name:
        req._send(400, json.dumps({"ok": False, "err": "no dir"}))
        return
    path = _log_path(name)
    try:
        with open(path) as f:
            text = _ANSI.sub("", "".join(f.readlines()[-200:]))
    except OSError:
        text = ""
    req._send(200, json.dumps({"ok": True, "log": text, "path": path}))
