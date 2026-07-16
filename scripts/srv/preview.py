# srv/preview.py — spin a side-port `next dev` for a branch, and manage the running ones. Wraps
# the loops-preview script (auto-picks a free 3010-3060 port, borrows MAIN's node_modules/.env and
# the running Docker) so a branch renders in the browser WITHOUT moving the main checkout off :3000.
#   POST /preview          {branch}  → {ok, url, port, dir}   start (materialises a worktree if none)
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


def _list_json():
    try:
        p = subprocess.run([_script(), "--json"], capture_output=True, text=True, timeout=6)
        return json.loads(p.stdout or "[]")
    except Exception:
        return []


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
    logstate, summary = _log_state(pv.get("name", ""))
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
    services = []
    try:
        p = subprocess.run(
            ["docker", "ps", "--filter", "label=com.docker.compose.project=loops",
             "--format", "{{.Names}}\t{{.Status}}"],
            capture_output=True, text=True, timeout=6)
        for line in p.stdout.strip().splitlines():
            parts = line.split("\t")
            if len(parts) >= 2:
                services.append({"name": parts[0], "status": parts[1], "up": parts[1].startswith("Up")})
    except Exception:
        pass
    return {
        "project": "loops", "shared": True,
        "up": sum(1 for s in services if s["up"]), "total": len(services),
        "services": services,
    }


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
    # loops-preview detaches the server into tmux and returns immediately with the URL on stdout.
    p = subprocess.run([_script(), dirp, "--main", checkout._active_main_wt()], capture_output=True, text=True)
    m = re.search(r"localhost:(\d+)", p.stdout)
    if not m:
        req._send(500, json.dumps({"ok": False, "err": (p.stderr or p.stdout or "preview failed").strip()[:400]}))
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
    m = re.search(r"localhost:(\d+)", p.stdout)
    if not m:
        req._send(500, json.dumps({"ok": False, "err": (p.stderr or p.stdout or "restart failed").strip()[:400]}))
        return
    newport = int(m.group(1))
    req._send(200, json.dumps({"ok": True, "port": newport, "url": "http://localhost:%d" % newport, "dir": dirp}))


def kill(req, raw):
    d = json.loads(raw or "{}")
    dirp = d.get("dir", "")
    if not dirp:
        req._send(400, json.dumps({"ok": False, "err": "no dir"}))
        return
    subprocess.run([_script(), dirp, "--kill"], capture_output=True, text=True)
    req._send(200, json.dumps({"ok": True}))


def reap(req, raw):
    p = subprocess.run([_script(), "--reap"], capture_output=True, text=True)
    req._send(200, json.dumps({"ok": True, "out": (p.stdout or "").strip()}))


def previews(req):
    pvs = _list_json()
    # _active_main_wt reads the request's pinned repo via a thread-local the probe pool WON'T
    # inherit (ctx.py gotcha), so resolve it once here and stamp every row with it.
    main_wt = checkout._active_main_wt()
    for pv in pvs:
        pv["borrows"] = main_wt
        pv["log"] = _log_path(pv.get("name", ""))
    if pvs:
        with ThreadPoolExecutor(max_workers=min(8, len(pvs))) as ex:
            pvs = list(ex.map(_health, pvs))
    req._send(200, json.dumps({"ok": True, "previews": pvs, "substrate": _substrate()}))


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
