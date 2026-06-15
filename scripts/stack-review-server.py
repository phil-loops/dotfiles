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


class H(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def _send(self, code, body, ctype="application/json"):
        b = body.encode() if isinstance(body, str) else body
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(b)))
        self.end_headers()
        self.wfile.write(b)

    def do_GET(self):
        last[0] = time.time()
        u = urlparse(self.path)
        if u.path in ("/", "/index.html"):
            self._send(200, open(os.path.join(ROOT, "index.html"), "rb").read(),
                       "text/html; charset=utf-8")
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
        elif u.path == "/purpose":
            branch = parse_qs(u.query).get("branch", [""])[0]
            r = run([os.path.join(SCRIPTS, "stack-purpose"), branch])
            self._send(200 if r.returncode == 0 else 500,
                       r.stdout if r.returncode == 0 else json.dumps({"thesis": "", "enables": ""}))
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
        self._send(404, "{}")


def reaper():
    while True:
        time.sleep(5)
        if time.time() - last[0] > IDLE:
            os._exit(0)


httpd = ThreadingHTTPServer(("127.0.0.1", 0), H)
print(httpd.server_address[1], flush=True)
threading.Thread(target=reaper, daemon=True).start()
httpd.serve_forever()
