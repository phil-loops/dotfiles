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
IDLE = 900   # self-reap after 15min idle (was 90s — too eager; cold restarts pay a
             # fresh python boot + an uncached stack-forest git fan-out on the next /model)
last = [time.time()]
_mcache = {}  # (branch, sig) -> model json — recompute only when something changed
_pcache = {}  # (sig, origin-main-sha) -> picker json — the /projects fan-out is expensive
_render_lock = threading.Lock()
_pulse = {"sig": "", "asset": ""}  # current model+asset fingerprints, refreshed ~1/s by pulse()
_index_cache = {"asset": None, "html": None}  # assembled index.html, keyed by asset_sig


def run(args):
    return subprocess.run(args, cwd=CWD, capture_output=True, text=True)


def _main_worktree():
    # "check out here" / "jump to checkout" act on the user's PRIMARY working tree
    # — the repo's main worktree (git always lists it first) — never the dir this
    # server happened to be launched from (which may be an ephemeral feature
    # worktree). Resolve once so the target is stable regardless of launch cwd.
    for line in run(["git", "worktree", "list", "--porcelain"]).stdout.splitlines():
        if line.startswith("worktree "):
            return line[len("worktree "):]
    return CWD


MAIN_WT = _main_worktree()


def _worktree_of(branch):   # path of the worktree currently holding `branch`, or "" if none
    if not branch:
        return ""
    path = ""
    for line in run(["git", "worktree", "list", "--porcelain"]).stdout.splitlines():
        if line.startswith("worktree "):
            path = line[len("worktree "):]
        elif line == "branch refs/heads/" + branch:
            return path
    return ""


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
    for f in ("shell.html", "styles.css", "data.js", "graph.js", "detail.js", "palette.js", "freshness.js", "branchbar.js"):
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


def _sync_state(branch):
    """Fork-staleness of a branch vs origin/main — the signal behind the viewer's
    "N behind" badge.
      behind    — commits on origin/main not yet in this branch (two-dot count,
                  `git rev-list --count <branch>..origin/main`). >0 means the fork
                  point is stale, so GitHub-Desktop two-dot diffs inflate by ~this.
      syncable  — safe to auto-rebase onto origin/main with NO force-push. True
                  only for a root off main (parent==main) that is unpublished (no
                  remote-tracking ref). Rebasing a *published* branch rewrites
                  pushed commits (→ force-push); rebasing a *stacked* branch
                  detaches it from its parent (→ that's a restack, not a sync).
                  Neither is offered here — `why` explains the refusal.
    Pure inspection: no fetch, no mutation."""
    if not branch:
        return {"branch": "", "behind": 0, "syncable": False, "why": "no branch"}
    raw = run(["git", "rev-list", "--count", f"{branch}..origin/main"]).stdout.strip()
    try:
        behind = int(raw)
    except ValueError:
        behind = 0   # origin/main absent or bad ref → treat as up-to-date (no badge)
    parent = run(["git", "config", f"stack-branch.{branch}.parent"]).stdout.strip() or "main"
    # published = a remote-tracking ref for THIS branch exists on any remote. Suffix-
    # match (not a `refs/remotes/*/X` glob) so slashed names like goal/foo and
    # multiple remotes both resolve. More reliable than upstream config, which the
    # repo's branch.autoSetupMerge=simple can silently point at origin/main.
    remotes = run(["git", "for-each-ref", "--format=%(refname)", "refs/remotes/"]).stdout.splitlines()
    published = any(r.endswith("/" + branch) for r in remotes)
    why = ""
    if behind == 0:
        why = "up to date with origin/main"
    elif parent != "main":
        why = f"stacked on {parent} — needs a restack, not a sync"
    elif published:
        why = "published — rebasing would rewrite pushed commits"
    return {"branch": branch, "behind": behind, "parent": parent, "published": published,
            "syncable": behind > 0 and parent == "main" and not published, "why": why}


def _ready_to_merge(mergeable, prs):
    """Split stack-forest's topologically-mergeable branches by PR state:
      ready      — an open PR already exists (the green into-main edge-bar set)
      candidates — no PR yet, but clear to merge: local branches you could open a
                   PR for / merge straight into main.
    The topology walk now lives in stack-forest (`mergeable`), so this is a pure
    split — no git calls. Returns (ready, candidates), input order preserved."""
    ready, candidates = [], []
    for b in mergeable:
        (ready if b in prs else candidates).append(b)
    return ready, candidates


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
            # page-hot, but cached: rebuild index.html only when a viewer source file
            # actually changed (asset_sig), else serve the cached bytes — skips a python
            # subprocess + 8 file reads on every page load. The live shell is model-
            # independent (model.json is always "null" here), so asset_sig alone keys it.
            sig = asset_sig()
            with _render_lock:
                if _index_cache["html"] is None or _index_cache["asset"] != sig:
                    try:
                        subprocess.run([sys.executable, os.path.join(SCRIPTS, "stack-review-html.tpl.py"),
                                        os.path.join(ROOT, "model.json"), os.path.join(ROOT, "index.html")],
                                       cwd=CWD, capture_output=True, timeout=20)
                    except Exception:
                        pass
                    _index_cache["html"] = open(os.path.join(ROOT, "index.html"), "rb").read()
                    _index_cache["asset"] = sig
                body = _index_cache["html"]
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
        elif u.path == "/head":  # the branch the main checkout currently points at (for "jump to checkout")
            self._send(200, json.dumps({"branch": run(["git", "-C", MAIN_WT, "rev-parse", "--abbrev-ref", "HEAD"]).stdout.strip()}))
        elif u.path == "/restack-status":  # is a handed-off restack paused for a human? drives the picker badge
            # stack-restack writes <git-common-dir>/stack-restack-state/state on a conflict
            # it can't auto-resolve (and removes it on success/abort). Its presence == paused.
            gitdir = run(["git", "rev-parse", "--git-common-dir"]).stdout.strip()
            if gitdir and not os.path.isabs(gitdir):
                gitdir = os.path.join(CWD, gitdir)
            sd = os.path.join(gitdir, "stack-restack-state", "state") if gitdir else ""
            want = parse_qs(u.query).get("project", [""])[0]
            paused, proj, cur = False, "", ""
            if sd and os.path.exists(sd):
                with open(sd) as fh:
                    kv = dict(l.rstrip("\n").split("=", 1) for l in fh
                              if "=" in l and not l.startswith("SNAP"))
                proj, cur = kv.get("PROJECT", ""), kv.get("CURRENT", "")
                paused = (not want) or proj == want
            # still churning? (parent stack-restack stays alive across the whole topo walk;
            # it exits when it escalates, so running==False + paused==True means "needs you")
            running = subprocess.run(["pgrep", "-f", "stack-restack"],
                                     capture_output=True, text=True).returncode == 0
            # surface WHY it parked: the last escalation reason from restack.log, so the
            # picker badge can read "limitedCount or countSentPreviews?" instead of just
            # "resolve". stack-restack logs `⚑ claude escalated: <reason>` per pause.
            reason = ""
            if paused:
                try:
                    with open(os.path.join(ROOT, "restack.log")) as fh:
                        for line in fh:
                            if "claude escalated:" in line:
                                reason = line.split("claude escalated:", 1)[1].strip()
                except Exception:
                    pass
            self._send(200, json.dumps({"paused": paused, "project": proj, "current": cur,
                                        "running": running, "reason": reason}))
        elif u.path == "/sync":  # fork-staleness vs origin/main: how far behind, and is it safe to auto-rebase?
            self._send(200, json.dumps(_sync_state(parse_qs(u.query).get("branch", [""])[0])))
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
        elif u.path == "/projects":   # the picker: [{name, branches, ready:[…]}] — choose a project to view
            # The fan-out below (stack-forest --projects + a rev-list per branch)
            # costs ~0.5s; cache on model_sig + origin/main tip so repeat loads are
            # instant and it recomputes only when a ref/config/ledger changes or a
            # fetch moves origin/main (which the "behind" counts depend on).
            pck = (model_sig(), run(["git", "rev-parse", "origin/main"]).stdout.strip())
            if pck in _pcache:
                self._send(200, _pcache[pck])
                return
            r = run([os.path.join(SCRIPTS, "stack-forest"), "--projects"])
            try:
                projs = json.loads(r.stdout or "[]")
            except Exception:
                projs = []
            prs = run([os.path.join(SCRIPTS, "stack-prs")])
            try:
                prmap = json.loads(prs.stdout or "{}")
            except Exception:
                prmap = {}
            for p in projs:
                p["ready"], p["candidates"] = _ready_to_merge(p.get("mergeable", []), prmap)
                # freshness vs origin/main: how far the project's roots trail. >0 means
                # origin/main has moved ahead → the forest needs a restack (which also
                # condenses any now-redundant/squash-merged branches). Measured on the
                # mergeable roots (they fork off main); pure inspection, no fetch.
                behind = 0
                for b in p.get("mergeable", []):
                    n = run(["git", "rev-list", "--count", f"{b}..origin/main"]).stdout.strip()
                    if n.isdigit():
                        behind = max(behind, int(n))
                p["behind"] = behind
            payload = json.dumps(projs)
            _pcache.clear()
            _pcache[pck] = payload
            self._send(200, payload)
        elif u.path == "/standalone":   # the pinned watch list — [{branch, commits, add, del}]
            r = run([os.path.join(SCRIPTS, "stack-forest"), "--standalone"])
            self._send(200, r.stdout or "[]")
        elif u.path == "/branches":   # typeahead candidates for pinning: all local heads,
            # most-recent-first, minus main + the already-pinned. Names only.
            main = run(["git", "config", "stack.main-branch"]).stdout.strip() or "main"
            pinned = set(run(["git", "config", "--get-all", "stack.standalone"]).stdout.splitlines())
            heads = run(["git", "for-each-ref", "--sort=-committerdate", "refs/heads",
                         "--format=%(refname:short)"]).stdout.splitlines()
            self._send(200, json.dumps([b for b in heads if b and b != main and b not in pinned]))
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
        elif u.path == "/commits":   # this branch's own commits: parent..branch, newest first
            branch = parse_qs(u.query).get("branch", [""])[0]
            parent = run(["git", "config", f"stack-branch.{branch}.parent"]).stdout.strip() or "main"
            fmt = "%h\x1f%s\x1f%an\x1f%ad"   # \x1f = unit-sep: safe field split (subjects can hold anything)
            out = run(["git", "log", f"{parent}..{branch}", f"--format={fmt}", "--date=short"]).stdout
            commits = []
            for ln in out.splitlines():
                p = ln.split("\x1f")
                if len(p) >= 2:
                    commits.append({"sha": p[0], "subject": p[1],
                                    "author": p[2] if len(p) > 2 else "", "date": p[3] if len(p) > 3 else ""})
            self._send(200, json.dumps(commits))
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
        if self.path == "/standalone":   # pin/unpin a branch in the opt-in watch list (stack.standalone multivar)
            d = json.loads(raw or "{}")
            branch = d.get("branch", "").strip()
            if not branch:
                self._send(400, json.dumps({"ok": False, "err": "no branch"}))
                return
            if d.get("op") == "remove":
                # --fixed-value (git ≥2.30) treats the value as literal, not a regex —
                # MUST precede --unset-all. Handles branch names with regex-special chars.
                run(["git", "config", "--fixed-value", "--unset-all", "stack.standalone", branch])
                self._send(200, json.dumps({"ok": True}))
                return
            # add: must be a real local head; de-dupe so a branch is pinned at most once
            if run(["git", "rev-parse", "--verify", "--quiet", "refs/heads/" + branch]).returncode != 0:
                self._send(404, json.dumps({"ok": False, "err": "no such local branch"}))
                return
            if branch not in run(["git", "config", "--get-all", "stack.standalone"]).stdout.splitlines():
                run(["git", "config", "--add", "stack.standalone", branch])
            self._send(200, json.dumps({"ok": True}))
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
        if self.path == "/checkout":   # move the working tree onto this branch (git refuses if dirty)
            d = json.loads(raw or "{}")
            branch = d.get("branch", "")
            wt = _worktree_of(branch)
            if wt and os.path.realpath(wt) != os.path.realpath(MAIN_WT):
                # git can't move the main tree onto a branch another worktree already holds.
                if not d.get("force"):
                    # tell the client where it lives so it can offer to free it
                    self._send(409, json.dumps({"ok": False, "err": "already open in worktree at " + wt, "worktree": wt}))
                    return
                # force: detach that worktree's HEAD (keeps its commits, releases the branch name), then checkout here
                rd = run(["git", "-C", wt, "checkout", "--detach"])
                if rd.returncode != 0:
                    self._send(500, json.dumps({"ok": False, "err": "could not free worktree: " + (rd.stderr or rd.stdout)}))
                    return
            r = run(["git", "-C", MAIN_WT, "checkout", branch])
            self._send(200 if r.returncode == 0 else 500,
                       json.dumps({"ok": r.returncode == 0, "out": r.stdout, "err": r.stderr}))
            return
        if self.path == "/sync":   # rebase an unpublished root branch onto fresh origin/main (no force-push possible)
            d = json.loads(raw or "{}")
            branch = d.get("branch", "")
            st = _sync_state(branch)   # re-check server-side: never rebase a published/stacked branch on a stale client view
            if not st.get("syncable"):
                self._send(409, json.dumps({"ok": False, "err": st.get("why", "not syncable")}))
                return
            r = run(["git", "rebase", "origin/main", branch])   # checks out branch; git refuses if the tree is dirty
            self._send(200 if r.returncode == 0 else 500,
                       json.dumps({"ok": r.returncode == 0, "out": r.stdout, "err": r.stderr}))
            return
        if self.path == "/squash":   # collapse parent..branch into one voiced commit (headless claude)
            d = json.loads(raw or "{}")
            r = run([os.path.join(SCRIPTS, "stack-squash"), d.get("branch", "")])
            # stack-squash always prints a JSON report (on success AND handled failure)
            self._send(200 if r.returncode == 0 else 500,
                       r.stdout or json.dumps({"ok": False, "err": r.stderr or "squash crashed"}))
            return
        if self.path == "/prep":   # prep-for-push: squash UNPUSHED commits → one, then oxfmt
            d = json.loads(raw or "{}")
            r = run([os.path.join(SCRIPTS, "stack-squash"), "--unpushed", "--format", d.get("branch", "")])
            self._send(200 if r.returncode == 0 else 500,
                       r.stdout or json.dumps({"ok": False, "err": r.stderr or "prep crashed"}))
            return
        if self.path == "/restack":   # hand off: re-rebase descendants onto the squashed SHA (background)
            d = json.loads(raw or "{}")
            project = d.get("project", "")
            if not project or project in ("whole forest", "--all"):
                self._send(400, json.dumps({"ok": False, "err": "no registered project to restack"}))
                return
            logpath = os.path.join(ROOT, "restack.log")
            with open(logpath, "ab") as lf:
                subprocess.Popen([os.path.join(SCRIPTS, "stack-restack"), project],
                                 cwd=CWD, stdout=lf, stderr=lf)
            self._send(200, json.dumps({"ok": True, "project": project, "log": logpath}))
            return
        if self.path == "/restack-resolve":   # parked on a conflict → hand it to Claude (full-judgment), then resume
            d = json.loads(raw or "{}")
            project = d.get("project", "")
            if not project:
                self._send(400, json.dumps({"ok": False, "err": "no project"}))
                return
            logpath = os.path.join(ROOT, "restack.log")
            with open(logpath, "ab") as lf:
                subprocess.Popen([os.path.join(SCRIPTS, "stack-restack"), project, "--handoff"],
                                 cwd=CWD, stdout=lf, stderr=lf)
            self._send(200, json.dumps({"ok": True, "project": project, "log": logpath}))
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
