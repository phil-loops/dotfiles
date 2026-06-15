#!/usr/bin/env python3
"""stack-review-server — live, blessing-aware stack review over localhost.

  GET  /                 the review shell (the page fetches /model)
  GET  /model?branch=X   live model JSON  (runs `stack-model X`)
  POST /bless {branch,file}  runs `stack-bless` (file omitted/"." → whole branch)
  POST /heartbeat        keepalive; the server self-reaps after IDLE seconds idle

Args: <servedir> <scriptsdir> <repodir>. Prints the chosen 127.0.0.1 port, then serves.
The page is same-origin with the server, so /model and /bless are plain relative fetches.
"""
import sys, os, json, subprocess, threading, time, hashlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse, parse_qs

ROOT, SCRIPTS, CWD = sys.argv[1], sys.argv[2], sys.argv[3]
IDLE = 90
last = [time.time()]
_mcache = {}  # (branch, sig) -> model json — recompute only when something changed
_render_lock = threading.Lock()
_pulse = {"sig": "", "asset": ""}  # current model+asset fingerprints, refreshed ~1/s by pulse()


def run(args):
    return subprocess.run(args, cwd=CWD, capture_output=True, text=True)


def model_sig():
    # cheap fingerprint of everything the model depends on: ref tips + config +
    # blessing ledger. Changes on re-point, commit, re-parent, or bless.
    refs = run(["git", "for-each-ref", "--format=%(objectname)", "refs/heads"]).stdout
    gd = run(["git", "rev-parse", "--path-format=absolute", "--git-common-dir"]).stdout.strip()

    def mt(p):
        try:
            return os.path.getmtime(p)
        except OSError:
            return 0
    stamp = refs + str(mt(os.path.join(gd, "config"))) + str(mt(os.path.join(gd, "stack-blessed.json")))
    return hashlib.sha1(stamp.encode()).hexdigest()


def asset_sig():
    # fingerprint the viewer source the page is assembled from (tpl + shell + css/js).
    # a change here means a code edit, so open tabs should reload the reassembled page.
    parts = [os.path.join(SCRIPTS, "stack-review-html.tpl.py")]
    v = os.path.join(SCRIPTS, "viewer")
    for f in ("shell.html", "styles.css", "data.js", "graph.js", "detail.js", "palette.js"):
        parts.append(os.path.join(v, f))

    def mt(p):
        try:
            return os.path.getmtime(p)
        except OSError:
            return 0
    return hashlib.sha1(",".join(str(mt(p)) for p in parts).encode()).hexdigest()


def pulse():
    # one shared thread recomputes both fingerprints ~1/s; every open /events stream
    # reads these in-process, so N tabs cost one git check total, not N polling tabs.
    while True:
        try:
            _pulse["sig"] = model_sig()
            _pulse["asset"] = asset_sig()
        except Exception:
            pass
        time.sleep(1.0)


class H(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def _send(self, code, body, ctype="application/json"):
        b = body.encode() if isinstance(body, str) else body
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(b)))
        self.send_header("Cache-Control", "no-store")  # always serve the freshly-assembled page/diffs
        self.end_headers()
        self.wfile.write(b)

    def do_GET(self):
        last[0] = time.time()
        u = urlparse(self.path)
        if u.path in ("/", "/index.html"):
            # page-hot: rebuild index.html from the template so tpl.py edits
            # show on a plain browser refresh (only on page loads, not API calls)
            with _render_lock:
                try:
                    subprocess.run([sys.executable, os.path.join(SCRIPTS, "stack-review-html.tpl.py"),
                                    os.path.join(ROOT, "model.json"), os.path.join(ROOT, "index.html")],
                                   cwd=CWD, capture_output=True, timeout=20)
                except Exception:
                    pass
                body = open(os.path.join(ROOT, "index.html"), "rb").read()
            self._send(200, body, "text/html; charset=utf-8")
        elif u.path == "/model":
            branch = parse_qs(u.query).get("branch", [""])[0]
            ck = (branch, model_sig())
            if ck in _mcache:
                self._send(200, _mcache[ck])
                return
            r = run([os.path.join(SCRIPTS, "stack-forest"), branch])
            if r.returncode != 0:
                self._send(500, json.dumps({"error": r.stderr}))
            else:
                _mcache.clear()
                _mcache[ck] = r.stdout
                self._send(200, r.stdout)
        elif u.path == "/sig":   # cheap change-detector for live polling (no stack-forest)
            self._send(200, json.dumps({"sig": model_sig()}))
        elif u.path == "/events":   # SSE: one push stream per tab, replaces the /heartbeat + /sig + /?_hot polls
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream")
            self.send_header("Cache-Control", "no-store")
            self.send_header("Connection", "keep-alive")
            self.end_headers()
            seen_sig, seen_asset = _pulse["sig"], _pulse["asset"]
            beat = 0
            try:
                self.wfile.write(b": connected\n\n")
                self.wfile.flush()
                while True:
                    time.sleep(1.0)
                    last[0] = time.time()   # an open tab keeps the server alive (replaces /heartbeat)
                    if _pulse["asset"] != seen_asset:   # code changed → reload for the new page
                        seen_asset = _pulse["asset"]
                        self.wfile.write(b"event: reload\ndata: 1\n\n")
                        self.wfile.flush()
                    if _pulse["sig"] != seen_sig:        # forest changed → refetch in place
                        seen_sig = _pulse["sig"]
                        self.wfile.write(b"event: update\ndata: 1\n\n")
                        self.wfile.flush()
                    beat = (beat + 1) % 5
                    if beat == 0:   # periodic comment: keep-alive + detect a closed tab (write then fails)
                        self.wfile.write(b": ping\n\n")
                        self.wfile.flush()
            except OSError:
                pass   # client closed the tab → the write fails, this thread ends
            return
        elif u.path == "/prs":   # branch → open-PR map; stack-prs disk-caches, so GH isn't hammered
            r = run([os.path.join(SCRIPTS, "stack-prs")])
            self._send(200, r.stdout or "{}")
        elif u.path == "/projects":   # the picker: [{name, branches}] — choose a project to view
            r = run([os.path.join(SCRIPTS, "stack-forest"), "--projects"])
            self._send(200, r.stdout or "[]")
        elif u.path == "/node":
            q = parse_qs(u.query)
            branch = q.get("branch", [""])[0]
            base = q.get("base", [""])[0]
            args = [os.path.join(SCRIPTS, "stack-forest"), "--node", branch]
            if base:
                args += ["--base", base]
            r = run(args)
            self._send(200 if r.returncode == 0 else 500,
                       r.stdout if r.returncode == 0 else json.dumps({"branch": branch, "files": []}))
        elif u.path == "/purpose":
            q = parse_qs(u.query)
            args = [os.path.join(SCRIPTS, "stack-purpose")]
            if q.get("generate", ["0"])[0] == "1":   # opt-in token spend, only on ask
                args.append("--generate")
            args.append(q.get("branch", [""])[0])
            r = run(args)
            self._send(200 if r.returncode == 0 else 500,
                       r.stdout if r.returncode == 0 else json.dumps({"thesis": "", "enables": "", "source": "none"}))
        elif u.path == "/file":
            q = parse_qs(u.query)
            branch, path = q.get("branch", [""])[0], q.get("path", [""])[0]
            r = run(["git", "show", f"{branch}:{path}"])
            self._send(200 if r.returncode == 0 else 404,
                       r.stdout if r.returncode == 0 else "(file not found on this ref)",
                       "text/plain; charset=utf-8")
        else:
            self._send(404, "{}")

    def do_POST(self):
        last[0] = time.time()
        n = int(self.headers.get("Content-Length", 0) or 0)
        raw = self.rfile.read(n).decode() if n else "{}"
        if self.path == "/heartbeat":
            self._send(200, '{"ok":true}')
            return
        if self.path == "/bless":
            d = json.loads(raw or "{}")
            args = [os.path.join(SCRIPTS, "stack-bless"), d.get("branch", "")]
            f = d.get("file")
            if f and f != ".":
                args += ["--file", f]
            r = run(args)
            self._send(200 if r.returncode == 0 else 500,
                       json.dumps({"ok": r.returncode == 0, "out": r.stdout, "err": r.stderr}))
            return
        if self.path == "/purpose":   # save a thesis as the git branch description
            d = json.loads(raw or "{}")
            r = run([os.path.join(SCRIPTS, "stack-purpose"), "--set", d.get("text", ""), d.get("branch", "")])
            self._send(200 if r.returncode == 0 else 500, r.stdout if r.returncode == 0 else "{}")
            return
        if self.path == "/open":   # open the file ON that branch in the warm review-nvim (full LSP)
            d = json.loads(raw or "{}")
            args = [os.path.join(SCRIPTS, "stack-open"), d.get("branch", ""), d.get("path", "")]
            pos = d.get("pos") or d.get("line")   # opaque locator ("<line>" / "<line>:<col>" / …) — forwarded
            if pos:                               # verbatim; this wiring layer never parses it. stack-open owns
                args.append(str(pos))             # the grammar, so new locator kinds cost zero change HERE.
            r = run(args)
            self._send(200 if r.returncode == 0 else 500,
                       json.dumps({"ok": r.returncode == 0, "out": r.stdout, "err": r.stderr}))
            return
        if self.path == "/prepare":   # prefetch: build the branch's worktree in the background
            d = json.loads(raw or "{}")
            subprocess.Popen([os.path.join(SCRIPTS, "stack-open"), "--prepare", d.get("branch", "")],
                             cwd=CWD, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            self._send(200, '{"ok":true}')
            return
        self._send(404, "{}")


def reaper():
    while True:
        time.sleep(5)
        if time.time() - last[0] > IDLE:
            os._exit(0)


# Port: a STABLE default (so reloads + already-open tabs survive a restart) —
# overridable via $STACK_REVIEW_PORT. The 4th arg is the watcher's rebind port on
# self-reload. If the stable port is taken (a stale/foreign holder), fall back to
# an ephemeral one rather than failing to start.
PORT = int(sys.argv[4]) if len(sys.argv) > 4 else int(os.environ.get("STACK_REVIEW_PORT", "62333"))
ThreadingHTTPServer.allow_reuse_address = True
try:
    httpd = ThreadingHTTPServer(("127.0.0.1", PORT), H)
except OSError:
    httpd = ThreadingHTTPServer(("127.0.0.1", 0), H)
PORT = httpd.server_address[1]
if len(sys.argv) <= 4:
    print(PORT, flush=True)  # announce the port only on the first launch


def watcher():
    # server-hot: re-exec (same port) when this file changes. The shell scripts
    # it shells out to are already hot (run per request); only server.py needs this.
    src = os.path.abspath(__file__)
    m0 = os.path.getmtime(src)
    while True:
        time.sleep(1.0)
        try:
            if os.path.getmtime(src) != m0:
                httpd.socket.close()
                os.execv(sys.executable, [sys.executable, src, ROOT, SCRIPTS, CWD, str(PORT)])
        except OSError:
            pass


_pulse["sig"], _pulse["asset"] = model_sig(), asset_sig()   # seed so the first /events stream sees real values
threading.Thread(target=reaper, daemon=True).start()
threading.Thread(target=watcher, daemon=True).start()
threading.Thread(target=pulse, daemon=True).start()
httpd.serve_forever()
