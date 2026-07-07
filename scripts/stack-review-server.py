#!/usr/bin/env python3
"""stack-review-server — live, blessing-aware stack review over localhost.

  GET  /                 the review shell (the page fetches /model)
  GET  /model?branch=X   live model JSON  (runs `stack-model X`)
  POST /bless {branch,file}  runs `stack-bless` (file omitted/"." → whole branch)
  POST /heartbeat        keepalive; the server self-reaps after IDLE seconds idle

Args: <servedir> <scriptsdir> <repodir>. Prints the chosen 127.0.0.1 port, then serves.
The page is same-origin with the server, so /model and /bless are plain relative fetches.
"""
import sys, os, json, re, subprocess, threading, time, hashlib, shlex
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse, parse_qs

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))   # resolve the srv/ package regardless of cwd
from srv import ctx as srvctx, restack, sync, checkout, picker, review, assist, chat, integrate, reviews, push, usage, rebase, processes

ROOT, SCRIPTS, CWD = sys.argv[1], sys.argv[2], sys.argv[3]
from srv import stage   # own line: the big srv import above is contested across sessions
from srv import ship    # own line: same reason
from srv import prep    # own line: same reason
srvctx.CWD = CWD   # set the default repo before any run() fires (run reads srvctx.repo_cwd())
DIST = os.path.join(SCRIPTS, "viewer-solid", "dist")   # the built Solid app served at /
EXT_ORIGIN = "chrome-extension://icojbpfabggonphegfghfnmjemejofoi"   # gh-to-nvim, the one non-localhost caller
IDLE = 900   # self-reap after 15min idle (was 90s — too eager; cold restarts pay a
             # fresh python boot + an uncached stack-forest git fan-out on the next /model)
last = [time.time()]
_render_lock = threading.Lock()
_pulse = {"sig": "", "asset": ""}  # current model+asset fingerprints, refreshed ~1/s by pulse()
_index_cache = {"asset": None, "html": None}  # assembled index.html, keyed by asset_sig


def run(args):
    # cwd is the per-request active repo (srvctx.repo_cwd) — the ?repo= selection for this
    # thread, or CWD when none. So every handler that goes through run is repo-aware for free.
    return subprocess.run(args, cwd=srvctx.repo_cwd(), capture_output=True, text=True)


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


def _repo_id():
    # Stable identity of the repo this server is bound to: the git COMMON dir
    # (shared by every worktree of the same repo, so launching from a feature
    # worktree still matches the main checkout). Used by stack-review-serve to
    # tell "this is my repo, reuse it" from "a foreign repo squats the port".
    gd = run(["git", "rev-parse", "--path-format=absolute", "--git-common-dir"]).stdout.strip()
    return gd or CWD


REPO_ID = _repo_id()


def _build_registry():
    # The repos the Forests home aggregates over: `git config --all stack.viewer-repos`
    # (whitespace/newline-separated roots), defaulting to loops + monotoad. Each resolves to
    # its MAIN worktree (git lists it first) so per-repo git-common-dir state lands in the right
    # checkout. A root that isn't a git repo is skipped — never silently bound to the wrong tree.
    cfg = run(["git", "config", "--get-all", "stack.viewer-repos"]).stdout.split()
    roots = cfg or ["~/coding/loops", "~/coding/monotoad"]
    reg = {}
    for root in roots:
        path = os.path.expanduser(root.strip())
        if not path:
            continue
        r = subprocess.run(["git", "-C", path, "worktree", "list", "--porcelain"],
                           capture_output=True, text=True)
        if r.returncode != 0:
            continue
        wt = next((ln[len("worktree "):] for ln in r.stdout.splitlines()
                   if ln.startswith("worktree ")), path)
        reg[os.path.basename(path)] = wt
    return reg


REPOS = _build_registry()

# wire the shared context for the extracted handler modules (srv/*)
srvctx.init(run=run, ROOT=ROOT, SCRIPTS=SCRIPTS, CWD=CWD, MAIN_WT=MAIN_WT, repos=REPOS)


# restack helpers + endpoints now live in srv/restack.py (delegated below).


# /head, /prepare, /checkout (+ _worktree_of) now live in srv/checkout.py.


# srvctx.model_sig() now lives in srv/ctx.py (shared by /model, /projects, /sig).


def asset_sig():
    # fingerprint the built Solid app (dist/) so a fresh `npm run build` reloads open tabs.
    # dist/index.html names hashed asset files, so its mtime alone moves on a rebuild; we
    # hash the assets dir too to be safe.
    parts = [os.path.join(DIST, "index.html")]
    adir = os.path.join(DIST, "assets")
    try:
        parts += [os.path.join(adir, f) for f in sorted(os.listdir(adir))]
    except OSError:
        pass

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
            _pulse["sig"] = srvctx.model_sig()
            _pulse["asset"] = asset_sig()
        except Exception:
            pass
        time.sleep(1.0)


# fork-staleness (_sync_state) + the /sync endpoints now live in srv/sync.py.


# picker endpoints + helpers (_ready_to_merge, recency) now live in srv/picker.py.


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

    def _enter_repo(self, u):
        # repo rides as the LEADING PATH SEGMENT when it names a registry repo: an API call
        # /<repo>/model pins this thread to <repo> and dispatches on the stripped path /model.
        # (The SPA route /forests/<repo>/<project>/<branch> starts with "forests" — not a repo —
        # so it isn't stripped; it serves index.html and the CLIENT parses the repo from the path.)
        # No repo prefix → CWD default. Returns the urlparse with the repo prefix removed.
        parts = u.path.split("/")
        if len(parts) >= 2 and parts[1] in srvctx.REPOS:
            srvctx.set_repo(srvctx.REPOS[parts[1]])
            return u._replace(path="/" + "/".join(parts[2:]))
        srvctx.clear_repo()
        return u

    def do_GET(self):
        last[0] = time.time()
        u = self._enter_repo(urlparse(self.path))
        try:
            self._dispatch_get(u)
        finally:
            srvctx.clear_repo()

    def _dispatch_get(self, u):
        if (u.path in ("/", "/index.html", "/work", "/forests", "/watching")
                or u.path.startswith(("/forests/", "/branch/", "/review/", "/push/"))):
            # Serve the built Solid app (scripts/viewer-solid/dist/index.html) for the shell AND
            # every client route: path-based routing (History API) means a deep-link/refresh to
            # /forest/x hits the server, which must return index.html (SPA fallback) so the client
            # can route it. API routes (/branch-url, /review-requests, /node, …) don't match these
            # prefixes, so they still fall through to their own handlers below.
            # Cached in-process, re-read only when asset_sig moves (a fresh `npm run build`).
            # Same-origin with this server, so the app's /model, /node, /bless… are plain
            # relative fetches — no dev proxy.
            sig = asset_sig()
            with _render_lock:
                if _index_cache["html"] is None or _index_cache["asset"] != sig:
                    try:
                        html = open(os.path.join(DIST, "index.html"), "rb").read()
                    except OSError:
                        self._send(503, "viewer not built — run `npm run build` in scripts/viewer-solid", "text/plain")
                        return
                    # Inject the registry repo names so the client router can tell a <repo> path
                    # segment from a <project> one (/forests/<repo>/<project> vs /forests/<project>).
                    inject = f"<script>window.__VIEWER_REPOS__={json.dumps(list(REPOS))}</script>".encode()
                    _index_cache["html"] = html.replace(b"<head>", b"<head>" + inject, 1)
                    _index_cache["asset"] = sig
                body = _index_cache["html"]
            self._send(200, body, "text/html; charset=utf-8")
        elif u.path.startswith("/assets/"):
            # hashed, immutable build assets (JS/CSS). basename-only + a fixed dir, so the
            # path can't escape dist/assets. Cache hard — the filename changes on rebuild.
            name = os.path.basename(u.path)
            fp = os.path.join(DIST, "assets", name)
            if not os.path.isfile(fp):
                return self._send(404, "{}")
            ctype = ("text/css" if name.endswith(".css")
                     else "application/javascript" if name.endswith(".js")
                     else "application/octet-stream")
            with open(fp, "rb") as fh:
                data = fh.read()
            self.send_response(200)
            self.send_header("Content-Type", ctype + "; charset=utf-8")
            self.send_header("Content-Length", str(len(data)))
            self.send_header("Cache-Control", "public, max-age=31536000, immutable")
            self.end_headers()
            self.wfile.write(data)
        elif u.path == "/model":          return review.model(self, u)
        elif u.path == "/pr-body":        return review.pr_body(self, u)
        elif u.path == "/sig":   # cheap change-detector for live polling (no stack-forest)
            # repo + pid let stack-review-serve detect a foreign-repo squatter on the
            # stable port and reclaim it (kill REPO_ID's holder, relaunch for its own repo).
            self._send(200, json.dumps({"sig": srvctx.model_sig(), "repo": REPO_ID, "pid": os.getpid()}))
        elif u.path == "/head":  # the branch the main checkout currently points at (for "jump to checkout")
            return checkout.head(self)
        elif u.path == "/restack-status":  # is a handed-off restack paused for a human? drives the picker badge
            return restack.status(self, u)
        elif u.path == "/restack-ambient":  # ambient daemon's latest dry-run report → the status chip
            return restack.ambient(self)
        elif u.path == "/restack-merges":  # daemon's what-just-merged attribution → "just landed" chip
            return restack.merges(self)
        elif u.path == "/sync":   # fork-staleness vs origin/main (single branch)
            return sync.get_one(self, u)
        elif u.path == "/push-preview":  # read-only: outgoing-vs-origin commit + push-origin guard verdict
            return push.preview(self, u)
        elif u.path == "/syncs":  # batch fork-staleness in one round-trip
            return sync.get_many(self, u)
        elif u.path == "/forest-health":  # batch drifted/merged-ghost per node (badges + fix-all)
            return sync.health_many(self, u)
        elif u.path == "/diverged-detail":  # what a ⇄ divergence IS: per-side commits (patch-id twins) + net tip diff
            return sync.diverged_detail(self, u)
        elif u.path == "/prep-route":  # what "prep to push" would do next (read-only verdict + delegate)
            return prep.route(self, u)
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
        elif u.path == "/prs":            return picker.prs(self)
        elif u.path == "/myprs":          return picker.myprs(self)
        elif u.path == "/projects":       return picker.projects(self)
        elif u.path == "/project-opened": return picker.project_opened(self)
        elif u.path == "/standalone":     return picker.standalone_list(self)
        elif u.path == "/branch-url":     return picker.branch_url(self, u)
        elif u.path == "/review-requests": return reviews.requests(self)
        elif u.path == "/review-remote":   return reviews.remote(self, u)
        elif u.path == "/ext-mtime":       return reviews.ext_mtime(self)
        elif u.path == "/branches":       return picker.branches(self)
        elif u.path == "/forest-branches": return picker.forest_branches(self)
        elif u.path == "/node":           return review.node(self, u)
        elif u.path == "/purpose":        return review.purpose_get(self, u)
        elif u.path == "/forest-purposes": return review.forest_purposes(self, u)
        elif u.path == "/file":           return review.file(self, u)
        elif u.path == "/commits":        return review.commits(self, u)
        elif u.path == "/tmux-targets":   return chat.tmux_targets(self)
        elif u.path == "/chat-jobs":      return chat.jobs(self)   # live-chat presence for Home
        elif u.path == "/processes":      return processes.list_all(self)   # unified background-process monitor
        else:
            self._send(404, "{}")

    def do_POST(self):
        last[0] = time.time()
        # localhost is mixed-content-exempt, so any public webpage can lob simple-request POSTs here
        origin = self.headers.get("Origin")
        if origin and origin != EXT_ORIGIN and not re.match(r"^https?://(localhost|127\.0\.0\.1)(:\d+)?$", origin):
            return self._send(403, '{"ok": false, "err": "cross-origin POST rejected"}')
        n = int(self.headers.get("Content-Length", 0) or 0)
        raw = self.rfile.read(n).decode() if n else "{}"
        u = self._enter_repo(urlparse(self.path))
        self.path = u.path   # repo prefix stripped, so the exact-match dispatch below is unchanged
        try:
            self._dispatch_post(raw)
        finally:
            srvctx.clear_repo()

    def _dispatch_post(self, raw):
        if self.path == "/heartbeat":
            self._send(200, '{"ok":true}')
            return
        if self.path == "/bless":
            return review.bless(self, raw)
        if self.path == "/standalone":   # pin/unpin a branch in the opt-in watch list
            return picker.pin(self, raw)
        if self.path == "/next":   # read-only: next mergeable branch(es) in this branch's forest
            return picker.whats_next(self, raw)
        if self.path == "/trunk":   # mark/unmark a branch as its forest's trunk anchor (frozen base)
            return picker.set_trunk(self, raw)
        if self.path == "/promote":   # graduate a watched branch into its own forest project
            return picker.promote(self, raw)
        if self.path == "/review-import":   # fetch a GitHub review-request PR → local node
            return reviews.import_pr(self, raw)
        if self.path == "/open-url":   # Chrome ext (URL-only): parse a raw GitHub URL → nvim or viewer route
            return reviews.open_url(self, raw)
        if self.path == "/review-pull":   # re-fetch a force-pushed PR head; blessings survive
            return reviews.pull(self, raw)
        if self.path == "/pr-forest":   # Chrome ext: forest membership + child seating for a PR
            return reviews.pr_forest(self, raw)
        if self.path == "/pr-reseat-children":   # Chrome ext: rebase orphaned children onto an approved PR branch
            return reviews.pr_reseat(self, raw)
        if self.path == "/reseat-children":      # viewer: rebase drifted children back onto a rewritten branch
            return reviews.reseat(self, raw)
        if self.path == "/track":   # append one local usage event to .git/stack-usage.jsonl
            return usage.track(self, raw)
        if self.path == "/drop-project":   # forget a forest grouping (config only; branches kept)
            return picker.drop_project(self, raw)
        if self.path == "/purpose":   # save a thesis as the git branch description
            return review.purpose_set(self, raw)
        if self.path == "/interest":   # promote/demote a branch's manual interest (stack-branch.<b>.interest)
            return review.interest_bump(self, raw)
        if self.path == "/open":   # open the file on that branch in the warm review-nvim
            return picker.open_file(self, raw)
        if self.path == "/prepare":   # prefetch: build the branch's worktree in the background
            return checkout.prepare(self, raw)
        if self.path == "/checkout":  # move the working tree onto this branch (git refuses if dirty)
            return checkout.move(self, raw)
        if self.path == "/worktree":  # reveal the branch's worktree in Finder (scratch one if none)
            return checkout.worktree(self, raw)
        if self.path == "/sync":   # rebase an unpublished root branch onto fresh origin/main
            return sync.post_sync(self, raw)
        if self.path == "/contract":   # drop an already-merged branch + rewire its children onto main
            return sync.post_contract(self, raw)
        if self.path == "/fix-upstream":   # neutralize a footgun tracking ref (unset upstream)
            return sync.fix_upstream(self, raw)
        if self.path == "/diverged-additive":   # draft the additive PR update (push-vehicle branch, never pushes)
            return sync.diverged_additive(self, raw)
        if self.path == "/prep-push":   # ONE state-routed prep: additive / restack / squash → one outgoing commit
            return push.prep_push(self, raw)
        if self.path == "/prep-message":   # edit the ONE unpushed commit's subject+body (tree untouched)
            return push.prep_message(self, raw)
        if self.path == "/dirty-resolve":   # sync's routed decision on a dirty tree: include / stash / pop
            return push.dirty_resolve(self, raw)
        if self.path == "/reconcile":   # diverged-from-PR-head branch → eject Claude to reconcile (no force-push)
            return sync.post_reconcile(self, raw)
        if self.path == "/discard-dirty":  # per-file reject: restore a tracked file to HEAD / delete an untracked one
            return review.discard_dirty(self, raw)
        if self.path == "/commit-dirty":  # commit all uncommitted worktree changes to the branch
            return review.commit_dirty(self, raw)
        if self.path == "/squash":   # collapse parent..branch into one voiced commit
            return review.squash(self, raw)
        if self.path == "/prep":     # prep-for-push: squash UNPUSHED commits → one, then oxfmt
            return review.prep(self, raw)
        if self.path == "/gates":    # mobile prepare-to-push: run repo gates → per-gate verdict
            return push.gates(self, raw)
        if self.path == "/delta-tests":  # prep-to-merge: run the tests related to the branch's delta
            return push.delta_tests(self, raw)
        if self.path == "/push":     # mobile prepare-to-push: FF push to a safe (non-origin) remote
            return push.push(self, raw)
        if self.path == "/push-origin":  # shared-history door: FF-only single-clean-commit push; human finger only
            return push.push_origin(self, raw)
        if self.path == "/restack":          # restack one project (background, scratch worktree)
            return restack.restack(self, raw)
        if self.path == "/stage":            # restack chain forward + move MAIN checkout onto the tip (dryRun supported)
            return stage.stage(self, raw)
        if self.path == "/ship":             # ready-to-ship: contract ghosts + restack forest + push order (dryRun supported)
            return ship.ship(self, raw)
        if self.path == "/restack-resolve":  # parked conflict → hand to Claude, then resume
            return restack.resolve(self, raw)
        if self.path == "/restack-abort":    # parked conflict → give up: abort rebase + clear state
            return restack.abort(self, raw)
        if self.path == "/restack-stop":     # running walk → stop it: kill drivers + abort + clear
            return restack.stop(self, raw)
        if self.path == "/check-origin":   # fetch origin + refresh PR/behind caches; report how far main moved
            before = run(["git", "rev-parse", "origin/main"]).stdout.strip()
            run(["git", "fetch", "origin", "main"])
            after = run(["git", "rev-parse", "origin/main"]).stdout.strip()
            moved = 0
            if before and after and before != after:
                try:
                    moved = int(run(["git", "rev-list", "--count", f"{before}..{after}"]).stdout.strip() or "0")
                except ValueError:
                    moved = 0
            # force the SWR caches fresh so the homepage reflects merges/new-PRs immediately
            run([os.path.join(SCRIPTS, "my-prs"), "--refresh"])
            run([os.path.join(SCRIPTS, "stack-prs"), "--refresh"])
            self._send(200, json.dumps({"ok": True, "moved": moved, "after": after[:9]}))
            return
        if self.path == "/restack-all":      # restack several projects back-to-back
            return restack.restack_all(self, raw)
        if self.path == "/claude":           # select diff lines → start a fresh claude on them
            return assist.start(self, raw)
        if self.path == "/claude-stream":    # chat-drawer edit action → headless claude, streamed (SSE)
            return assist.stream(self, raw)
        if self.path == "/chat":             # start OR reconnect a chat turn (server-side job) → SSE replay+live
            return chat.start(self, raw)
        if self.path == "/chat-stop":        # ■ stop: kill this turn's headless claude for real
            return chat.stop(self, raw)
        if self.path == "/chat-popout":      # pop a chat out → resume its session in an interactive tmux claude
            return chat.popout(self, raw)
        if self.path == "/chat-tmux":        # ✦ buttons: seeded chat straight into tmux (join + even-horizontal)
            return assist.chat_tmux(self, raw)
        if self.path == "/chat-attach":      # save a dropped/pasted image → temp file claude can Read
            return chat.attach(self, raw)
        if self.path == "/rebase-stream":    # tail the ejected forward-rebase (headless claude) → SSE replay+live
            return rebase.stream(self, raw)
        if self.path == "/rebase-stop":      # ■ stop: kill the branch's ejected rebase job for real
            return rebase.stop(self, raw)
        if self.path == "/merge-subjects":   # crisp the merge-story commit subjects (one haiku pass)
            return chat.merge_subjects(self, raw)
        if self.path == "/integrate":        # ghost "feature" node → does the whole project land on main cleanly?
            return integrate.check(self, raw)
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
    # server-hot: re-exec (same port) when this file OR any srv/*.py module changes. srv/ is
    # imported once at startup, so without watching it those edits stay stale until a real
    # restart. (The shell scripts it shells out to are already hot — run per request.)
    import glob
    src = os.path.abspath(__file__)
    srcs = [src] + glob.glob(os.path.join(os.path.dirname(src), "srv", "*.py"))
    m0 = max(os.path.getmtime(f) for f in srcs)
    while True:
        time.sleep(1.0)
        try:
            if max(os.path.getmtime(f) for f in srcs) != m0:
                httpd.socket.close()
                os.execv(sys.executable, [sys.executable, src, ROOT, SCRIPTS, CWD, str(PORT)])
        except OSError:
            pass


_pulse["sig"], _pulse["asset"] = srvctx.model_sig(), asset_sig()   # seed so the first /events stream sees real values
threading.Thread(target=reaper, daemon=True).start()
threading.Thread(target=watcher, daemon=True).start()
threading.Thread(target=pulse, daemon=True).start()
httpd.serve_forever()
