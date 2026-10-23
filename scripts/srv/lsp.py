# srv/lsp.py — on-demand TypeScript hover + go-to-definition for the branch page.
#
# One viewer tsgo per machine (`tsgo --lsp --stdio`, the binary Helix runs), rooted in the
# stack-open review worktree of the branch last asked about. Nothing starts until a request
# arrives; asking about another branch, or the branch's tip moving, replaces it; ten idle
# minutes stop it. A tsgo on loops is a ~5 GB process, so it never starts below the
# memory floor heavy-turn uses. Read-only: documents are opened with their committed text
# and never changed.
#
# Out of scope: old-side (removed-line) types, find-references, and sharing one language server
# with Helix (Helix owns its tsgo's stdio).
#
#   POST /lsp/hover      {branch, path, line, character} → {ok, contents, range}
#   POST /lsp/definition {branch, path, line, character} → {ok, locations: [{path, line, character, endLine}]}
#        either one       → {ok: false, state: "loading" | "refused" | "error", message}
#   GET  /lsp/status                                      → {state, branch, root, startedAt, idleS, memLevel, progress, …}
#   GET  /lsp/src        ?path=                           → {path, text} — a definition target, from the server's tree
#
# `line` is 1-based (the diff's new-side number), `character` 0-based UTF-16 (LSP's default
# encoding, and what a JS string index already is). A "loading" answer means the request is still
# queued in tsgo: asking again with the same position re-attaches to it rather than re-sending.
#
# Env: STACK_LSP_IDLE (600s), STACK_LSP_WAIT (per-request hold, 20s), HEAVY_TURN_MEM_FLOOR (30),
# STACK_LSP_MEM_LEVEL (forces the measured level; tests), STACK_LSP_STATE_DIR (pidfile + log dir),
# STACK_LSP_TSGO (the binary).
import json
import os
import signal
import subprocess
import threading
import time
from urllib.parse import parse_qs, unquote, urlparse

from . import ctx, actor

IDLE_S = int(os.environ.get("STACK_LSP_IDLE", "600"))
WAIT_S = float(os.environ.get("STACK_LSP_WAIT", "20"))
MEM_FLOOR = int(os.environ.get("HEAVY_TURN_MEM_FLOOR", "30"))
STATE_DIR = os.environ.get("STACK_LSP_STATE_DIR") or os.path.expanduser("~/Library/Caches/stack-review-lsp")
PIDFILE = os.path.join(STATE_DIR, "tsgo.json")
_VOLTA_TSGO = os.path.expanduser("~/.volta/bin/tsgo")
TSGO = os.environ.get("STACK_LSP_TSGO") or (_VOLTA_TSGO if os.path.exists(_VOLTA_TSGO) else "tsgo")
SRC_MAX = 400_000
LANGS = {".ts": "typescript", ".mts": "typescript", ".cts": "typescript", ".tsx": "typescriptreact",
         ".js": "javascript", ".mjs": "javascript", ".cjs": "javascript", ".jsx": "javascriptreact"}
RETRY_AFTER_ERROR_S = 10


def mem_level():
    forced = os.environ.get("STACK_LSP_MEM_LEVEL")
    if forced:
        return int(forced)
    try:
        r = subprocess.run(["sysctl", "-n", "kern.memorystatus_level"], capture_output=True, text=True, timeout=2)
        return int(r.stdout.strip())
    except (OSError, ValueError, subprocess.TimeoutExpired):
        return None


def _alive(pid):
    try:
        os.kill(pid, 0)
        return True
    except ProcessLookupError:
        return False
    except PermissionError:
        return True


def _is_tsgo(pid):
    r = subprocess.run(["ps", "-o", "command=", "-p", str(pid)], capture_output=True, text=True)
    return "tsgo" in r.stdout


def _killpg(pgid, pid):
    for sig in (signal.SIGTERM, signal.SIGKILL):
        try:
            os.killpg(pgid, sig)
        except (ProcessLookupError, PermissionError):
            return
        for _ in range(20):
            if not _alive(pid):
                return
            time.sleep(0.1)


def _read_pidfile():
    try:
        with open(PIDFILE) as f:
            return json.load(f)
    except (OSError, ValueError):
        return None


def _reap_recorded(only_orphans):
    # The pidfile is how a tsgo survives nothing: os._exit (the idle reaper) and execv (hot reload)
    # both skip any cleanup, and the next image — same pid after a re-exec — reaps what it names.
    # only_orphans spares a tsgo another live viewer server still owns.
    d = _read_pidfile()
    if not d:
        return
    owner, pid, pgid = d.get("owner"), d.get("pid"), d.get("pgid")
    if only_orphans and owner != os.getpid() and owner and _alive(owner):
        return
    if pid and _alive(pid) and _is_tsgo(pid):
        _killpg(pgid or pid, pid)
    try:
        os.unlink(PIDFILE)
    except OSError:
        pass


class _Pending:
    def __init__(self):
        self.event = threading.Event()
        self.result = None
        self.error = None
        self.done_at = 0.0

    def settle(self, result=None, error=None):
        self.result, self.error, self.done_at = result, error, time.time()
        self.event.set()


class Session:
    def __init__(self, repo, branch, tip):
        self.repo, self.branch, self.tip = repo, branch, tip
        self.root = ""
        self.proc = None
        self.state = "preparing"   # preparing → starting → loading → ready | error | stopped
        self.message = f"preparing the worktree for {branch}"
        self.started_at = time.time()
        self.ready_at = None
        self.last_req = time.time()
        self.progress = {}         # $/progress token → {title, message, percentage}
        self.served = set()        # absolute paths a definition pointed at outside the tree (/lsp/src may read them)
        self._ready = threading.Event()
        self._lock = threading.Lock()
        self._write = threading.Lock()
        self._next = 1
        self._pending = {}         # jsonrpc id → _Pending
        self._inflight = {}        # (method, path, line, character) → _Pending
        self._opened = set()
        self._stopping = False
        self.healing = False       # the .gen heal is running beside tsgo

    # ── lifecycle ────────────────────────────────────────────────────
    def alive(self):
        if self.state in ("error", "stopped"):
            return False
        return self.proc is None or self.proc.poll() is None

    def boot(self):
        try:
            self._boot()
        except Exception as e:   # a boot thread that dies silently leaves every request "loading" forever
            self._fail(str(e) if isinstance(e, RuntimeError) else f"language server failed to start: {e}")

    def tree(self):
        """stack-open's review checkout for the branch, resynced to its tip. The .gen heal is NOT done
        here: it ran ~14 s in series before tsgo on a fresh tree (2026-10-22), so _heal runs it beside
        tsgo instead."""
        env = dict(actor.child_env() or os.environ)
        env["STACK_OPEN_NO_GEN_SYNC"] = "1"
        r = subprocess.run([os.path.join(ctx.SCRIPTS, "stack-open"), "--path", self.branch],
                           cwd=self.repo, capture_output=True, text=True, timeout=900, env=env)
        lines = [ln for ln in (r.stdout or "").splitlines() if ln.strip()]
        if r.returncode != 0 or not lines:
            why = ((r.stderr or "").strip().splitlines() or ["stack-open failed"])[-1]
            raise RuntimeError(f"couldn't prepare a worktree for {self.branch}: {why}")
        return lines[-1].strip()

    def _boot(self):
        root = os.path.realpath(self.tree())
        head = subprocess.run(["git", "-C", root, "rev-parse", "HEAD"], capture_output=True, text=True).stdout.strip()
        if head != self.tip:
            return self._fail(f"{root} is at {head[:9]}, not {self.branch}'s tip {self.tip[:9]}")
        if self._stopping:
            return
        self.root = root
        self.state, self.message = "starting", f"starting the type server for {self.branch}"
        os.makedirs(STATE_DIR, exist_ok=True)
        _reap_recorded(only_orphans=False)   # one per machine: a rival server's tsgo goes too
        log = open(os.path.join(STATE_DIR, "tsgo.log"), "ab")
        self.proc = subprocess.Popen([TSGO, "--lsp", "--stdio"], cwd=root, stdin=subprocess.PIPE,
                                     stdout=subprocess.PIPE, stderr=log, start_new_session=True)
        log.close()
        with open(PIDFILE, "w") as f:
            json.dump({"pid": self.proc.pid, "pgid": self.proc.pid, "owner": os.getpid(),
                       "root": root, "branch": self.branch, "started": self.started_at}, f)
        if self._stopping:
            return self.stop("replaced")
        threading.Thread(target=self._reader, daemon=True).start()
        uri = "file://" + root
        init = self._send_request("initialize", {
            "processId": os.getpid(),
            "rootUri": uri,
            "workspaceFolders": [{"uri": uri, "name": os.path.basename(root)}],
            "capabilities": {
                "textDocument": {
                    "hover": {"contentFormat": ["markdown", "plaintext"]},
                    "definition": {"linkSupport": True},
                    "synchronization": {"didSave": False},
                },
                "window": {"workDoneProgress": True},
                "workspace": {"configuration": True, "workspaceFolders": True},
            },
        })
        if not init.event.wait(120) or init.error:
            return self._fail(f"tsgo didn't initialize: {init.error or 'no answer in 120s'}")
        self._notify("initialized", {})
        self.state, self.message = "loading", f"loading types for {self.branch}"
        self._ready.set()
        threading.Thread(target=self._heal, daemon=True).start()

    def _heal(self):
        """Rebuild the tree's generated tRPC types beside tsgo. If anything changed, hand over to a
        fresh session at once (its own heal is then a no-op), so types come from the healed tree."""
        marker = os.path.join(self.root, ".gen", ".seed-gen-sha")
        before = _read_text(marker)
        self.healing = True
        try:
            subprocess.run([os.path.join(ctx.SCRIPTS, "seed-gen"), "--sync", self.root], capture_output=True,
                           text=True, timeout=900, env=actor.child_env() or dict(os.environ))
        except (OSError, subprocess.TimeoutExpired) as e:
            ctx.log(f"lsp: .gen heal for {self.branch} failed: {e}")
        finally:
            self.healing = False
        if _read_text(marker) == before or self._stopping:
            return
        with _lock:
            if _cur[0] is not self:
                return
            fresh = Session(self.repo, self.branch, self.tip)
            fresh.message = f"refreshing types for {self.branch} — tRPC types were rebuilt"
            _cur[0] = fresh
        self.stop("tRPC types rebuilt")
        threading.Thread(target=fresh.boot, daemon=True).start()

    def _fail(self, message):
        self.state, self.message = "error", message
        ctx.log(f"lsp: {message}")
        self._ready.set()
        self._kill()

    def stop(self, reason):
        self._stopping = True
        if self.state not in ("error",):
            self.state, self.message = "stopped", f"stopped ({reason})"
        self._ready.set()
        self._kill()
        ctx.log(f"lsp: stopped tsgo for {self.branch} ({reason})")

    def _kill(self):
        p = self.proc
        if p and p.poll() is None:
            _killpg(p.pid, p.pid)
            try:
                p.wait(timeout=2)
            except subprocess.TimeoutExpired:
                pass
        d = _read_pidfile()
        if p and d and d.get("pid") == p.pid:
            try:
                os.unlink(PIDFILE)
            except OSError:
                pass
        for pend in list(self._pending.values()):
            pend.settle(error=self.message)
        self._pending.clear()

    # ── wire ─────────────────────────────────────────────────────────
    def _write_msg(self, msg):
        body = json.dumps(msg).encode()
        with self._write:
            self.proc.stdin.write(b"Content-Length: %d\r\n\r\n" % len(body) + body)
            self.proc.stdin.flush()

    def _send_request(self, method, params):
        pend = _Pending()
        with self._lock:
            rid = self._next
            self._next += 1
            self._pending[rid] = pend
        try:
            self._write_msg({"jsonrpc": "2.0", "id": rid, "method": method, "params": params})
        except (BrokenPipeError, OSError, AttributeError) as e:
            self._pending.pop(rid, None)
            pend.settle(error=f"language server gone: {e}")
        return pend

    def _notify(self, method, params):
        self._write_msg({"jsonrpc": "2.0", "method": method, "params": params})

    def _reader(self):
        out = self.proc.stdout
        while True:
            length = None
            while True:
                line = out.readline()
                if not line:
                    return self._on_exit()
                line = line.strip()
                if not line:
                    break
                if line.lower().startswith(b"content-length:"):
                    length = int(line.split(b":", 1)[1])
            if length is None:
                continue
            try:
                msg = json.loads(out.read(length))
            except ValueError:
                continue
            self._on_message(msg)

    def _on_exit(self):
        if not self._stopping and self.state != "error":
            self.state, self.message = "stopped", "tsgo exited"
            ctx.log(f"lsp: tsgo for {self.branch} exited on its own (rc {self.proc.poll()})")
        self._ready.set()
        for pend in list(self._pending.values()):
            pend.settle(error="tsgo exited")
        self._pending.clear()

    def _on_message(self, msg):
        method = msg.get("method")
        if method is None:
            pend = self._pending.pop(msg.get("id"), None)
            if pend:
                err = msg.get("error")
                pend.settle(result=msg.get("result"), error=err and (err.get("message") or str(err)))
            return
        if "id" in msg:   # a server→client request: answer every one, or tsgo waits on it
            result = None
            if method == "workspace/configuration":
                result = [None] * len((msg.get("params") or {}).get("items") or [])
            try:
                self._write_msg({"jsonrpc": "2.0", "id": msg["id"], "result": result})
            except (BrokenPipeError, OSError):
                pass
            return
        if method == "$/progress":
            p = msg.get("params") or {}
            tok, v = str(p.get("token")), p.get("value") or {}
            if v.get("kind") == "end":
                self.progress.pop(tok, None)
            else:
                cur = self.progress.setdefault(tok, {})
                for k in ("title", "message", "percentage"):
                    if k in v:
                        cur[k] = v[k]

    # ── requests ─────────────────────────────────────────────────────
    def _open(self, rel):
        if rel in self._opened:
            return
        full = os.path.join(self.root, rel)
        dirty = subprocess.run(["git", "-C", self.root, "status", "--porcelain", "--", rel],
                               capture_output=True, text=True).stdout.strip()
        if dirty:   # a real worktree with edits: types still come from disk, but the open doc is the commit
            text = subprocess.run(["git", "-C", self.root, "show", f"HEAD:{rel}"],
                                  capture_output=True, text=True).stdout
        else:
            with open(full, encoding="utf-8", errors="replace") as f:
                text = f.read()
        self._notify("textDocument/didOpen", {"textDocument": {
            "uri": "file://" + full, "languageId": LANGS[os.path.splitext(rel)[1]], "version": 1, "text": text}})
        self._opened.add(rel)

    def ask(self, method, rel, line, character, deadline):
        key = (method, rel, line, character)
        with self._lock:
            for k, p in list(self._inflight.items()):
                if p.done_at and time.time() - p.done_at > 60:
                    del self._inflight[k]
            pend = self._inflight.get(key)
        if pend is None:
            self._open(rel)
            pend = self._send_request(method, {
                "textDocument": {"uri": "file://" + os.path.join(self.root, rel)},
                "position": {"line": line - 1, "character": character},
            })
            with self._lock:
                self._inflight[key] = pend
        if not pend.event.wait(max(0.0, deadline - time.time())):
            return None
        with self._lock:
            self._inflight.pop(key, None)
        if self.state == "loading":
            self.state, self.ready_at = "ready", time.time()
            self.message = f"types loaded in {self.ready_at - self.started_at:.0f}s"
        return pend

    def rel_or_abs(self, path):
        for root in {self.root, os.path.realpath(self.root)}:
            if path.startswith(root + os.sep):
                return os.path.relpath(path, root)
        self.served.add(path)
        return path

    def rss_mb(self):
        if not self.proc or self.proc.poll() is not None:
            return None
        r = subprocess.run(["ps", "-axo", "pgid=,rss="], capture_output=True, text=True)
        kb = sum(int(rss) for pg, rss in (ln.split() for ln in r.stdout.splitlines() if ln.strip())
                 if int(pg) == self.proc.pid)
        return round(kb / 1024)


_lock = threading.Lock()
_cur = [None]
_idle_started = [False]


def _idle_loop():
    while True:
        time.sleep(min(15, max(1, IDLE_S / 4)))
        s = _cur[0]
        if s and s.alive() and time.time() - s.last_req > IDLE_S:
            s.stop(f"idle {IDLE_S // 60}m" if IDLE_S >= 60 else f"idle {IDLE_S}s")


def _tip(repo, branch):
    r = subprocess.run(["git", "-C", repo, "rev-parse", "--verify", "-q", f"refs/heads/{branch}^{{commit}}"],
                       capture_output=True, text=True)
    return r.stdout.strip() if r.returncode == 0 else ""


def _read_text(path):
    try:
        with open(path) as f:
            return f.read().strip()
    except OSError:
        return ""


def _refused(message):
    return {"ok": False, "state": "refused", "message": message}


def _session(repo, branch):
    """The running session for (repo, branch, tip), or a fresh one replacing whatever ran; a dict = refusal."""
    tip = _tip(repo, branch)
    if not tip:
        return {"ok": False, "state": "error", "message": f"no branch {branch}"}
    with _lock:
        if not _idle_started[0]:
            _idle_started[0] = True
            threading.Thread(target=_idle_loop, daemon=True).start()
        s = _cur[0]
        if s and s.repo == repo and s.branch == branch and s.tip == tip:
            if s.alive():
                return s
            if s.state == "error" and time.time() - s.started_at < RETRY_AFTER_ERROR_S:
                return {"ok": False, "state": "error", "message": s.message}
        lvl = mem_level()
        if lvl is not None and lvl < MEM_FLOOR:
            return _refused(f"memory is tight ({lvl}% free, floor {MEM_FLOOR}%) — not starting a language server; "
                            "press o to read it in Helix")
        if s:
            s.stop("tip moved" if s.branch == branch and s.repo == repo else f"switched to {branch}")
        s = Session(repo, branch, tip)
        _cur[0] = s
        threading.Thread(target=s.boot, daemon=True).start()
        return s


def _loading(s, extra=""):
    if s.healing and s.state in ("starting", "loading"):
        extra += " · rebuilding tRPC types beside it"
    return {"ok": False, "state": "loading", "message": (s.message + extra),
            "elapsedS": round(time.time() - s.started_at, 1), "progress": _progress(s)}


def _progress(s):
    if not s.progress:
        return None
    return list(s.progress.values())[-1]


def _ask(req, raw, method):
    try:
        d = json.loads(raw or "{}")
        branch, rel = str(d["branch"]), str(d["path"])
        line, character = int(d["line"]), int(d["character"])
    except (ValueError, KeyError, TypeError):
        return req._send(400, json.dumps({"ok": False, "state": "error", "message": "want {branch, path, line, character}"}))
    if os.path.isabs(rel) or ".." in rel.split("/") or line < 1 or character < 0:
        return req._send(400, json.dumps({"ok": False, "state": "error", "message": f"bad position {rel}:{line}:{character}"}))
    ext = os.path.splitext(rel)[1]
    if ext not in LANGS:
        return req._send(200, json.dumps({"ok": False, "state": "error", "message": f"no language server for {ext or 'this file'}"}))
    s = _session(ctx.repo_cwd(), branch)
    if isinstance(s, dict):
        return req._send(200, json.dumps(s))
    s.last_req = time.time()
    deadline = time.time() + WAIT_S
    if not s._ready.wait(max(0.0, deadline - time.time())):
        return req._send(200, json.dumps(_loading(s)))
    if s.state in ("error", "stopped"):
        return req._send(200, json.dumps({"ok": False, "state": "error", "message": s.message}))
    if not os.path.isfile(os.path.join(s.root, rel)):
        return req._send(200, json.dumps({"ok": False, "state": "error", "message": f"{rel} isn't in {s.branch} at its tip"}))
    pend = s.ask(method, rel, line, character, deadline)
    if pend is None:
        return req._send(200, json.dumps(_loading(s)))
    if pend.error:
        return req._send(200, json.dumps({"ok": False, "state": "error", "message": str(pend.error)}))
    s.last_req = time.time()
    return req._send(200, json.dumps(_shape(s, method, pend.result)))


def _pos(p):
    return {"line": p["line"] + 1, "character": p["character"]}


def _markdown(contents):
    if contents is None:
        return ""
    if isinstance(contents, str):
        return contents
    if isinstance(contents, list):
        return "\n\n".join(filter(None, (_markdown(c) for c in contents)))
    if "language" in contents:
        return f"```{contents['language']}\n{contents.get('value', '')}\n```"
    if contents.get("kind") == "plaintext":
        return "```\n" + contents.get("value", "") + "\n```"
    return contents.get("value", "")


def _shape(s, method, result):
    if method == "textDocument/hover":
        md = _markdown((result or {}).get("contents")).strip()
        rng = (result or {}).get("range")
        return {"ok": True, "contents": md,
                "range": rng and {"start": _pos(rng["start"]), "end": _pos(rng["end"])}}
    raw = result if isinstance(result, list) else [result] if result else []
    locs = []
    for loc in raw:
        uri = loc.get("targetUri") or loc.get("uri")
        rng = loc.get("targetSelectionRange") or loc.get("range")
        if not uri or not rng:
            continue
        locs.append({"path": s.rel_or_abs(unquote(urlparse(uri).path)), "line": rng["start"]["line"] + 1,
                     "character": rng["start"]["character"], "endLine": rng["end"]["line"] + 1})
    return {"ok": True, "locations": locs}


def hover(req, raw):
    return _ask(req, raw, "textDocument/hover")


def definition(req, raw):
    return _ask(req, raw, "textDocument/definition")


def status(req, u=None):
    s, lvl = _cur[0], mem_level()
    if not s:
        return req._send(200, json.dumps({"state": "idle", "memLevel": lvl, "memFloor": MEM_FLOOR, "idleKillS": IDLE_S}))
    req._send(200, json.dumps({
        "state": s.state if s.alive() or s.state in ("error", "stopped") else "stopped",
        "message": s.message, "branch": s.branch, "tip": s.tip, "root": s.root,
        "startedAt": s.started_at, "readyAt": s.ready_at, "elapsedS": round(time.time() - s.started_at, 1),
        "idleS": round(time.time() - s.last_req), "idleKillS": IDLE_S,
        "memLevel": lvl, "memFloor": MEM_FLOOR, "progress": _progress(s),
        "pid": s.proc.pid if s.proc else None, "rssMB": s.rss_mb(),
    }))


def src(req, u):
    path = parse_qs(u.query).get("path", [""])[0]
    s = _cur[0]
    if not s or not s.root:
        return req._send(200, json.dumps({"err": "no language server tree"}))
    if os.path.isabs(path):
        full = path if path in s.served else ""
    else:
        full = os.path.normpath(os.path.join(s.root, path))
        if not full.startswith(s.root + os.sep):
            full = ""
    if not full:
        return req._send(200, json.dumps({"err": f"not readable here: {path}"}))
    try:
        with open(full, encoding="utf-8", errors="replace") as f:
            text = f.read(SRC_MAX)
    except OSError as e:
        return req._send(200, json.dumps({"err": str(e)}))
    req._send(200, json.dumps({"path": path, "branch": s.branch, "text": text}))


def stop_all(reason="server exit"):
    s = _cur[0]
    if s:
        s.stop(reason)


_reap_recorded(only_orphans=True)
