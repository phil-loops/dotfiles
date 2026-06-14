#!/usr/bin/env python3
"""stack-review-server — live, blessing-aware stack review over localhost.

  GET  /                 the review shell (the page fetches /model)
  GET  /model?branch=X   live model JSON  (runs `stack-model X`)
  POST /bless {branch,file}  runs `stack-bless` (file omitted/"." → whole branch)
  POST /heartbeat        keepalive; the server self-reaps after IDLE seconds idle

Args: <servedir> <scriptsdir> <repodir>. Prints the chosen 127.0.0.1 port, then serves.
The page is same-origin with the server, so /model and /bless are plain relative fetches.
"""
import sys, os, json, subprocess, threading, time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse, parse_qs

ROOT, SCRIPTS, CWD = sys.argv[1], sys.argv[2], sys.argv[3]
IDLE = 90
last = [time.time()]


def run(args):
    return subprocess.run(args, cwd=CWD, capture_output=True, text=True)


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
            r = run([os.path.join(SCRIPTS, "stack-forest"), branch])
            if r.returncode != 0:
                self._send(500, json.dumps({"error": r.stderr}))
            else:
                self._send(200, r.stdout)
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
