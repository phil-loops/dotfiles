#!/usr/bin/env python3
"""stack-review-server — canopy, the live forest viewer, over localhost.

  GET  /v2[/…]           the app (dist/v2/index.html); / and v1's page URLs 302 here
  GET  /state, /v2/events  the app's store snapshot + its patch stream
  POST /heartbeat        keepalive; the server self-reaps after IDLE seconds idle

Args: <servedir> <scriptsdir> <repodir>. Prints the chosen 127.0.0.1 port, then serves.
Request logging (method path status ms) is default-on: stderr + a size-capped durable file at
<git-common-dir>/stack-review.log (survives bounces — attribution must outlive the process).
$STACK_REVIEW_LOG=0 silences both.
The page is same-origin with the server, so its API calls are plain relative fetches.
"""
import sys, os, json, re, socket, subprocess, threading, time, hashlib, shlex, html
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse, parse_qs

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))   # resolve the srv/ package regardless of cwd
from srv import ctx as srvctx, restack, sync, picker, review, chat, integrate, reviews, push, usage, preview

ROOT, SCRIPTS, CWD = sys.argv[1], sys.argv[2], sys.argv[3]
from srv import stage   # own line: the big srv import above is contested across sessions
from srv import prep    # own line: same reason
from srv import wiki    # own line: same reason
from srv import focus   # own line: same reason
from srv import footprint   # own line: same reason
from srv import repostate   # own line: same reason
from srv import procsig   # own line: same reason
from srv import actor, reqlog   # own line: same reason
os.environ["STACK_VIA"] = "viewer"   # git hooks under this server attribute to it, not to whoever launched it
from srv import pregate   # own line: same reason
from srv import v1redirect   # own line: same reason
from srv import tutor   # own line: same reason
from srv import outbox   # own line: same reason
from srv import outline   # own line: same reason
from srv import lsp   # own line: same reason
from srv import packet   # own line: same reason
from srv import state   # own line: same reason
from srv import telemetry   # own line: same reason
from srv import reviewdesk   # own line: same reason
from srv import keymap   # own line: same reason
from srv import todo   # own line: same reason
from srv import viewed   # own line: same reason
from srv import story   # own line: same reason
state.ASSET = lambda: asset_sig()   # tabs on an older build reload (srv/state.py)
srvctx.CWD = CWD   # set the default repo before any run() fires (run reads srvctx.repo_cwd())


def _ext_origins():
    # gh-to-nvim is the one non-localhost caller. Its id is derived (prod from the signing key,
    # dev from the source path) and ROTATES whenever the key does — a hardcoded id silently 403s
    # the popup's fetches after a rotation, so ask the same script the installer asks.
    ids = set()
    for mode in ("prod", "dev"):
        r = subprocess.run([os.path.join(SCRIPTS, "gh-to-nvim-ext-id"), mode],
                           capture_output=True, text=True)
        if r.returncode == 0 and r.stdout.strip():
            ids.add("chrome-extension://" + r.stdout.strip())
    return ids


EXT_ORIGINS = _ext_origins()
IDLE = 900   # self-reap after 15min idle (was 90s — too eager; cold restarts pay a
             # fresh python boot + an uncached stack-forest git fan-out on the next /model)
last = [time.time()]
_pulse = {"sig": "", "asset": "", "world": "", "procs": ""}  # model+asset+remote-world fingerprints, refreshed ~1/s by pulse()
_pulse_subs = srvctx.PULSE_SUBS    # open /events streams — pulse() only runs while this is > 0
_pulse_subs_lock = threading.Lock()
_pulse_wake = threading.Event()
LOG = os.environ.get("STACK_REVIEW_LOG", "1") not in ("", "0")   # default-on; STACK_REVIEW_LOG=0 silences
_log_lock = threading.Lock()
# Durable sink beside stderr: the servedir log dies with the server (mktemp, reaped on bounce),
# which is why the 2026-08-19 absorb incident is unattributable — attribution must outlive the
# process. Rotation, retention and poll coalescing live in srv/reqlog.py.


def _durable_log_path():
    try:
        r = subprocess.run(["git", "-C", CWD, "rev-parse", "--path-format=absolute", "--git-common-dir"],
                           capture_output=True, text=True)
        d = r.stdout.strip()
        return os.path.join(d, "stack-review.log") if r.returncode == 0 and d else ""
    except Exception:
        return ""


_LOG_FILE = _durable_log_path()


def _log(line):
    with _log_lock:   # threaded server: one locked write, or concurrent requests interleave mid-line
        msg = f"{time.strftime('%Y-%m-%d %H:%M:%S')} {line}\n"
        sys.stderr.write(msg)
        sys.stderr.flush()
    reqlog.append(_LOG_FILE, msg)


_REVIEW_POSTS = {"/review-draft": reviewdesk.draft, "/review-apply": reviewdesk.apply, "/review-address": reviewdesk.address, "/review-note": reviewdesk.note}


def run(args, timeout=None):
    # cwd is the per-request active repo (srvctx.repo_cwd) — the ?repo= selection for this
    # thread, or CWD when none. So every handler that goes through run is repo-aware for free.
    #
    # timeout is opt-in per call and MUST NOT become a default — plenty of what comes through here
    # (a restack, a gates run, a vite build) is legitimately slow. But a network git/gh call on a
    # request thread that stalls pends that thread for the life of the server: nothing above reaps
    # it, so the thread and its child both leak, and the caller learns nothing. Expiry reads as an
    # ordinary failed CompletedProcess (124, the shell's timeout code), so callers keep their
    # `returncode != 0` shape without knowing this exists.
    try:
        return subprocess.run(args, cwd=srvctx.repo_cwd(), capture_output=True, text=True, timeout=timeout,
                              env=actor.child_env())
    except subprocess.TimeoutExpired:
        _log(f"run: timed out after {timeout}s — {' '.join(args)}")
        return subprocess.CompletedProcess(args, 124, "", f"timed out after {timeout}s")


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
srvctx.init(run=run, ROOT=ROOT, SCRIPTS=SCRIPTS, CWD=CWD, MAIN_WT=MAIN_WT, repos=REPOS, log=_log)


# restack helpers + endpoints now live in srv/restack.py (delegated below).


# srvctx.model_sig() now lives in srv/ctx.py (shared by /model, /projects, /sig).


def asset_sig():
    # the signature canopy-native watches (hello / asset): it moves when keys.toml is saved, so the
    # app reloads its keymap.
    try:
        mtime = os.path.getmtime(keymap.PATH)
    except OSError:
        mtime = 0
    return hashlib.sha1(str(mtime).encode()).hexdigest()


def _pulse_refresh():
    _pulse["sig"] = srvctx.model_sig() + str(srvctx.pulse_nonce[0])
    _pulse["asset"], _pulse["world"] = asset_sig(), sync.world_sig()
    try:
        _pulse["procs"] = procsig.sig()   # non-git state: agents, chat turns, restack, previews
    except Exception:
        pass


def pulse():
    # one shared thread recomputes both fingerprints ~1/s; every open /events stream
    # reads these in-process, so N tabs cost one git check total, not N polling tabs.
    #
    # N=0 was the case nobody wrote: with no stream open there is nothing to push to, yet this
    # kept spawning git around the clock — 0.44s of CPU per minute, measured, for no reader. That
    # cost is the whole reason the server reaps itself after 15min idle, which is in turn why
    # every consumer had to grow a way to resurrect it. Sleep until someone actually subscribes.
    while True:
        if _pulse_subs[0] == 0:
            _pulse_wake.wait()
            _pulse_wake.clear()
            continue
        try:
            sync.pulse_freshen()   # remote world converges while a tab is open, no client polling
            _pulse_refresh()
        except Exception:
            pass
        time.sleep(1.0)


# fork-staleness (_sync_state) + the /sync endpoints now live in srv/sync.py.


class H(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def log_request(self, code="-", size="-"):
        self._status = code

    def handle_one_request(self):
        # the raw request line, not self.path: do_POST rewrites self.path to the repo-stripped one.
        if not LOG:
            return BaseHTTPRequestHandler.handle_one_request(self)
        self._status, self.raw_requestline = "-", b""   # cleared, or a dead keep-alive read re-logs the last request
        self._actor, self._sid, self._refused = None, None, None
        t0 = time.perf_counter()
        try:
            BaseHTTPRequestHandler.handle_one_request(self)
        finally:
            actor.clear_current()
            req = (getattr(self, "raw_requestline", b"") or b"").decode("latin-1").split()
            if req:
                ms = (time.perf_counter() - t0) * 1000
                hdrs = getattr(self, "headers", None)
                line = reqlog.request_line(req[0], req[1] if len(req) > 1 else "?", self._status, ms,
                                           self._actor, self._refused, self._sid,
                                           rid=hdrs.get("X-Request-Id") if hdrs else None)
                if line:
                    _log(line)

    def _identify(self, path):
        # who's calling, before the handler runs: the peer process is only walkable while connected
        self._actor, self._sid = actor.classify(self.headers, path, EXT_ORIGINS, self.client_address[1])
        self._refused = None
        actor.set_current(self._actor, self._sid)

    def _send(self, code, body, ctype="application/json"):
        b = body.encode() if isinstance(body, str) else body
        # the one choke point every handler answers through: an action answered {ok:false} is a
        # refusal even at 200 — name it for the request log and hand the client a short class.
        # POST only: a read whose payload says ok:false (a push verdict) refused nothing.
        if self.command == "POST" and ctype == "application/json" and b[:1] == b"{" and len(b) < 65536 and re.search(rb'"ok":\s*false', b):
            try:
                d = json.loads(b)
                if d.get("ok") is False:
                    self._refused = reqlog.error_class(d.get("err") or d.get("error"))
            except Exception:
                pass
        self.send_response(code)
        if getattr(self, "_refused", None):
            self.send_header("X-Stack-Refused", self._refused)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(b)))
        self.send_header("Cache-Control", "no-store")  # always serve the freshly-assembled page/diffs
        self.end_headers()
        self.wfile.write(b)

    def _enter_repo(self, u):
        # repo rides as the LEADING PATH SEGMENT when it names a registry repo: an API call
        # /<repo>/model pins this thread to <repo> and dispatches on the stripped path /model.
        # (The app's routes start with "v2" — not a repo — so they aren't stripped.)
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
        self._identify(u.path)
        try:
            self._dispatch_get(u)
        finally:
            srvctx.clear_repo()

    def _send_open_in_canopy(self, route):
        # The web viewer is retired; its /v2/… addresses now name a canopy-native page.
        cmd = html.escape(f"canopy {route}")
        link = html.escape(f"canopy://{route.lstrip('/')}", quote=True)
        body = (f"<!doctype html><meta charset=utf-8><title>canopy</title>"
                f"<p>This page is in the canopy app now: <a href=\"{link}\">open it in canopy</a>, or run</p>"
                f"<pre>{cmd}</pre>").encode()
        self._send(200, body, "text/html; charset=utf-8")

    def _redirect(self, to):
        self.send_response(302)
        self.send_header("Location", to)
        self.send_header("Content-Length", "0")
        self.send_header("Cache-Control", "no-store")
        self.end_headers()

    def _dispatch_get(self, u):
        if u.path == "/v2" or (u.path.startswith("/v2/") and u.path != "/v2/events"):
            return self._send_open_in_canopy(u.path + (f"?{u.query}" if u.query else ""))
        if (u.path in ("/", "/index.html", "/work", "/forests", "/watching", "/wiki", "/machine", "/tutor", "/outbox")
                or u.path.startswith(("/forests/", "/branch/", "/review/", "/push/", "/wiki/", "/tutor/", "/outbox/"))):
            return self._redirect(v1redirect.target(u))   # v1's page URLs (and /) → their v2 page
        elif u.path == "/model":          return review.model(self, u)
        elif u.path == "/sig":   # cheap change-detector for live polling (no stack-forest)
            # repo + pid let stack-review-serve detect a foreign-repo squatter on the
            # stable port and reclaim it (kill REPO_ID's holder, relaunch for its own repo).
            self._send(200, json.dumps({"sig": srvctx.model_sig(), "repo": REPO_ID, "pid": os.getpid()}))
        elif u.path == "/sync":   # fork-staleness vs origin/main (single branch)
            return sync.get_one(self, u)
        elif u.path == "/gates-progress":  # live per-gate journal of a detached /gates run
            return push.gates_progress(self, u)
        elif u.path == "/diverged-detail":  # what a ⇄ divergence IS: per-side commits (patch-id twins) + net tip diff
            return sync.diverged_detail(self, u)
        elif u.path == "/force-scope":  # read-only: may /force-origin replace origin's copy (the guards it re-checks)
            return sync.force_scope_get(self, u)
        elif u.path == "/prep-route":  # what "prep to push" would do next (read-only verdict + delegate)
            return prep.route(self, u)
        elif u.path == "/events":   # SSE: one push stream per tab, replaces the /heartbeat + /sig + /?_hot polls
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream")
            self.send_header("Cache-Control", "no-store")
            self.send_header("Connection", "keep-alive")
            self.end_headers()
            with _pulse_subs_lock:
                _pulse_subs[0] += 1
                first = _pulse_subs[0] == 1
            if first:
                try:
                    _pulse_refresh()   # seeding seen_* from fingerprints left over from the last
                except Exception:      # subscriber would read as a change and reload this tab on sight
                    pass
                _pulse_wake.set()
            seen_sig, seen_asset, seen_world, seen_procs = _pulse["sig"], _pulse["asset"], _pulse["world"], _pulse["procs"]
            seen_failing = False
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
                    if _pulse["world"] != seen_world:    # remote moved (merge, PR flip) → refetch in place
                        seen_world = _pulse["world"]
                        self.wfile.write(b"event: update\ndata: 1\n\n")
                        self.wfile.flush()
                    if _pulse["procs"] != seen_procs:    # a process/agent/preview moved → the process panels refetch
                        seen_procs = _pulse["procs"]
                        self.wfile.write(b"event: procs\ndata: 1\n\n")
                        self.wfile.flush()
                    failing, age = sync.fresh_state()
                    if failing != seen_failing:          # origin checks broke/recovered → honesty chip
                        seen_failing = failing
                        payload = json.dumps({"failing": failing, "age": int(age)})
                        self.wfile.write(f"event: stale\ndata: {payload}\n\n".encode())
                        self.wfile.flush()
                    beat = (beat + 1) % 5
                    if beat == 0:   # periodic comment: keep-alive + detect a closed tab (write then fails)
                        self.wfile.write(b": ping\n\n")
                        self.wfile.flush()
            except OSError:
                pass   # client closed the tab → the write fails, this thread ends
            finally:
                with _pulse_subs_lock:
                    _pulse_subs[0] -= 1
            return
        elif u.path == "/landed-why":     return story.why(self, u)   # a landed chapter's squash message on main
        elif u.path == "/state":          return state.get(self, u)   # the v2 store's snapshot: normalized entities + domain versions
        elif u.path == "/v2/events":      return state.events(self, u, keepalive=lambda: last.__setitem__(0, time.time()))   # SSE: entity patches per domain
        elif u.path == "/telemetry/summary": return telemetry.summary(self, u)   # command/surface latency vs budgets, from daily rollups
        elif u.path == "/ext-mtime":       return reviews.ext_mtime(self)
        # Hyphenated, not /wiki/… — /wiki/<slug> is a client route served index.html above.
        elif u.path == "/wiki-pages":     return wiki.pages(self, u)   # every page for this repo, nav-ordered
        elif u.path == "/wiki-src":       return wiki.src(self, u)     # resolve one citation to its source lines
        elif u.path == "/tutor-src":      return tutor.src(self, u)    # a pinned file for the code pane
        elif u.path == "/lsp/src":        return lsp.src(self, u)      # a definition target, at the commit its answer came from
        elif u.path == "/learning-state": return tutor.learning_state(self, u)   # the concept graph, depth + due derived
        elif u.path == "/tutor-terminal": return tutor.terminal(self, u)   # terminal /tutor sessions to pick up
        elif u.path == "/tutor-import":   return tutor.import_(self, u)    # one of them, as tab turns
        elif u.path == "/node":           return review.node(self, u)
        elif u.path == "/outline":        return outline.get(self, u)            # a branch's words: description, outline, landing text
        elif u.path == "/packet":         return packet.get(self, u)             # the review packet: the PR body as a checkable contract
        elif u.path == "/packet-compare": return packet.compare(self, u)         # 302 → GitHub's compare form, packet prefilled
        elif u.path == "/file":           return review.file(self, u)
        elif u.path == "/commits":        return review.commits(self, u)
        elif u.path == "/commit-diff":    return review.commit_diff(self, u)
        elif u.path == "/footprint":      return footprint.get(self, u)      # machine / repo sprawl / this server's own footprint
        elif u.path == "/previews":       return preview.previews(self)   # health-probed dev servers + shared stack
        elif u.path == "/preview-log":    return preview.log(self)   # tail one preview's next-dev log
        elif u.path == "/preview-wait":   return preview.wait(self)   # warming page: boots + hands off to the preview
        elif "text/html" in self.headers.get("Accept", ""):
            # A browser NAVIGATION that matched no route above is a human on a page URL that
            # moved, was mistyped, or predates a rename (/forest/x before /forests/x) — send
            # them home rather than a bare `{}` in the face. fetch/XHR doesn't ask for
            # text/html, so API 404s stay honest JSON.
            self._redirect(v1redirect.HOME)
        else:
            self._send(404, "{}")

    def do_POST(self):
        last[0] = time.time()
        # localhost is mixed-content-exempt, so any public webpage can lob simple-request POSTs here
        origin = self.headers.get("Origin")
        if origin and origin not in EXT_ORIGINS and not re.match(r"^https?://(localhost|127\.0\.0\.1)(:\d+)?$", origin):
            return self._send(403, '{"ok": false, "err": "cross-origin POST rejected"}')
        n = int(self.headers.get("Content-Length", 0) or 0)
        raw = self.rfile.read(n).decode() if n else "{}"
        u = self._enter_repo(urlparse(self.path))
        self.path = u.path   # repo prefix stripped, so the exact-match dispatch below is unchanged
        self._identify(u.path)
        try:
            self._dispatch_post(raw)
        finally:
            # any POST may have moved a ref or written config: drop the shared snapshot so the
            # very next reader rebuilds instead of riding out its freshness window
            repostate.invalidate()
            state.poke()   # the v2 stream's patch for this write goes out now, not on the next tick
            srvctx.clear_repo()

    def _dispatch_post(self, raw):
        if self.path == "/heartbeat":
            self._send(200, '{"ok":true}')
            return
        if self.path == "/open-url":   # Chrome ext (URL-only): parse a raw GitHub URL → nvim or viewer route
            return reviews.open_url(self, raw)
        if self.path == "/pr-forest":   # Chrome ext: forest membership + child seating for a PR
            return reviews.pr_forest(self, raw)
        if self.path == "/reseat-children":      # viewer: rebase drifted children back onto a rewritten branch
            return reviews.reseat(self, raw)
        if self.path == "/track":   # append one local usage event to .git/stack-usage.jsonl
            return usage.track(self, raw)
        if self.path == "/project-state":   # move a project between focus, the workbench and the archive
            return review.project_state(self, raw)
        if self.path == "/focus":      # pin/unpin or reorder the focus lane (stack-project.<p>.focus N)
            return review.focus_set(self, raw)
        if self.path == "/open":   # open the file on that branch in the warm review-nvim
            return picker.open_file(self, raw)
        if self.path == "/preview":   # spin a side-port `next dev` for this branch (no touch to :3000)
            return preview.start(self, raw)
        if self.path == "/preview-integration":   # …for the ✦<project> ghost, via its playground worktree
            return preview.start_integration(self, raw)
        if self.path == "/preview-main":   # run (or attach to) main on :3000
            return preview.start_main(self, raw)
        if self.path == "/preview-kill":   # stop one side-port preview (by its worktree dir)
            return preview.kill(self, raw)
        if self.path == "/preview-restart":   # kill + fresh next dev on the same port
            return preview.restart(self, raw)
        if self.path == "/preview-swap":   # flip the SAME port to another branch's build (before/after in one tab)
            return preview.swap(self, raw)
        if self.path == "/preview-reap":   # stop orphaned/crashed previews
            return preview.reap(self, raw)
        if self.path == "/stack-up":   # bring the shared Docker stack (Postgres/ClickHouse/…) up
            return preview.stack_up(self, raw)
        if self.path == "/sync":   # rebase an unpublished root branch onto fresh origin/main
            return sync.post_sync(self, raw)
        if self.path == "/fix-upstream":   # neutralize a footgun tracking ref (unset upstream)
            return sync.fix_upstream(self, raw)
        if self.path == "/diverged-additive":   # draft the additive PR update (push-vehicle branch, never pushes)
            return sync.diverged_additive(self, raw)
        if self.path == "/prep-push":   # ONE state-routed prep: additive / restack / squash → one outgoing commit
            return push.prep_push(self, raw)
        if self.path == "/outline":   # rewrite the outline's changed unpushed messages in one pass (+ description, landing text)
            return outline.save(self, raw)
        if self.path == "/outline-undo":   # restore the last outline save, if still unpushed and unmoved
            return outline.undo(self, raw)
        if self.path == "/packet-guide":   # (re)draft the packet's reading guide with headless claude
            return packet.guide(self, raw)
        if self.path == "/dirty-resolve":   # sync's routed decision on a dirty tree: include / stash / pop
            return push.dirty_resolve(self, raw)
        if self.path == "/reconcile":   # diverged-from-PR-head branch → eject Claude to reconcile (no force-push)
            return sync.post_reconcile(self, raw)
        if self.path == "/revert-commit":  # history row ↶: undo one own commit with a new revert commit
            return review.revert_commit(self, raw)
        if self.path == "/squash":   # collapse parent..branch into one voiced commit
            return review.squash(self, raw)
        if self.path == "/prep":     # prep-for-push: squash UNPUSHED commits → one, then oxfmt
            return review.prep(self, raw)
        if self.path == "/gates":    # sync strip: run repo gates → per-gate verdict (detach:true → journal)
            return push.gates(self, raw)
        if self.path == "/delta-tests":  # prep-to-merge: run the tests related to the branch's delta
            return push.delta_tests(self, raw)
        if self.path == "/push-origin":  # shared-history door: FF-only single-clean-commit push; human finger only
            return push.push_origin(self, raw)
        if self.path == "/force-origin":  # the ONE force exception: no PR, or a draft with zero reviews/comments; lease-guarded
            return push.force_origin(self, raw)
        if self.path == "/viewed":   # the review page's v: view or un-view change blocks (srv/viewed.py)
            return viewed.post(self, raw)
        if self.path == "/todo-item":   # the tracker page moves an item (state, rank)
            return todo.post(self, raw)
        if self.path in _REVIEW_POSTS:   # the branch page's review: the ledger (and Phil's pending review), local suggestion commits
            return _REVIEW_POSTS[self.path](self, raw)
        if self.path == "/outbox-hold":   # hold for morning: stamp/clear branch.<b>.stack-hold-until (branch or forest)
            return outbox.hold(self, raw)
        if self.path == "/restack":          # restack one project (background, scratch worktree)
            return restack.restack(self, raw)
        if self.path == "/chat":             # a read-only chat turn (the mail-map's Q&A proxies here) → SSE replay+live
            return chat.start(self, raw)
        if self.path == "/tutor":            # a Socratic turn → headless read-only claude, streamed (SSE)
            return tutor.start(self, raw)
        if self.path == "/lsp/hover":        # on-demand types for a diff token (read-only, starts tsgo on first ask)
            return lsp.hover(self, raw)
        if self.path == "/lsp/definition":
            return lsp.definition(self, raw)
        if self.path == "/lsp/type-definition":
            return lsp.type_definition(self, raw)
        if self.path == "/lsp/implementation":
            return lsp.implementation(self, raw)
        if self.path == "/lsp/references":
            return lsp.references(self, raw)
        if self.path == "/lsp/symbols":
            return lsp.symbols(self, raw)
        if self.path == "/lsp/rename":       # rename a name across the program at the branch tip: preview, then one commit
            return lsp.rename(self, raw)
        if self.path == "/lsp/prepare":      # move the type trees to a branch page's tip + base (no tsgo)
            return lsp.prepare(self, raw)
        if self.path == "/tutor-stop":
            return tutor.stop(self, raw)
        if self.path == "/learning-evidence":   # the learner audits a credit: edit or delete one evidence row
            return tutor.learning_evidence(self, raw)
        if self.path == "/learning-question":   # the learner's own questions, attached to concepts
            return tutor.learning_question(self, raw)
        if self.path == "/integrate":        # ghost "feature" node → does the whole project land on main cleanly?
            return integrate.check(self, raw)
        self._send(404, "{}")


class Server(ThreadingHTTPServer):
    allow_reuse_address = True

    def handle_error(self, request, client_address):
        # a tab navigating away or an SSE stream closing is normal here, and socketserver's default
        # dumps a ~20-line traceback per abort — that noise WAS the whole log (119KB, 2026-07-21).
        exc = sys.exc_info()[1]
        if isinstance(exc, (ConnectionResetError, BrokenPipeError)):
            if LOG:
                _log(f"client gone ({type(exc).__name__})")
            return
        super().handle_error(request, client_address)


def reaper():
    while True:
        time.sleep(5)
        if time.time() - last[0] > IDLE:
            lsp.stop_all("server idle")   # os._exit skips every cleanup — tsgo's process group goes first
            os._exit(0)


# Port: a STABLE default (so reloads + already-open tabs survive a restart) —
# overridable via $STACK_REVIEW_PORT. The 4th arg is the watcher's rebind port on
# self-reload. If the stable port is taken (a stale/foreign holder), fall back to
# an ephemeral one rather than failing to start.
PORT = int(sys.argv[4]) if len(sys.argv) > 4 else int(os.environ.get("STACK_REVIEW_PORT", "62333"))
# A re-exec (source-watcher hot reload) INHERITS the listening socket rather than rebinding
# it: closing and re-binding raced the old socket's teardown, and after 5s of trying the
# fallback bound a random port — a server alive but invisible to every consumer that computes
# the stable one (2026-09-09, caught by the log line below). Handing the fd over removes the
# race entirely: the port is never released, so it cannot be lost or stolen mid-reload.
_INHERITED_FD = os.environ.pop("STACK_REVIEW_FD", "")
if _INHERITED_FD:
    httpd = Server(("127.0.0.1", PORT), H, bind_and_activate=False)
    httpd.socket = socket.socket(fileno=int(_INHERITED_FD))
    httpd.server_address = httpd.socket.getsockname()
else:
    httpd = None
    for _attempt in range(20):   # a just-killed predecessor can hold the port for a moment
        try:
            httpd = Server(("127.0.0.1", PORT), H)
            break
        except OSError:
            time.sleep(0.25)
    if httpd is None and os.environ.get("STACK_REVIEW_SUPERVISED"):
        # the supervised server IS the owner of this port: binding a random one instead makes
        # it invisible to every consumer while looking healthy to launchd. Exit and let launchd
        # retry (ThrottleInterval) until whatever holds the port is gone.
        _log(f"supervised: stable port {PORT} held by another process — exiting for a retry")
        raise SystemExit(75)
    if httpd is None:
        httpd = Server(("127.0.0.1", 0), H)
        _log(f"stable port {PORT} still held after 5s — bound {httpd.server_address[1]} instead; "
             "consumers that compute the stable port will not find this server")
PORT = httpd.server_address[1]
if len(sys.argv) <= 4:
    print(PORT, flush=True)  # announce the port only on the first launch


def watcher():
    # server-hot: re-exec (same port) when this file OR any srv/*.py module changes. srv/ is
    # imported once at startup, so without watching it those edits stay stale until a real
    # restart. (The shell scripts it shells out to are already hot — run per request.)
    import glob
    src = os.path.abspath(__file__)
    srvdir = os.path.join(os.path.dirname(src), "srv", "*.py")

    def stamp():
        # re-globbed every pass: a module ADDED after boot was invisible to a one-shot glob,
        # so a new srv/*.py needed a hand-bounce to take effect (three of them today)
        # review_packet.py is imported by srv/packet.py, so it reloads with them
        return max(os.path.getmtime(f) for f in [src, os.path.join(os.path.dirname(src), "review_packet.py")] + glob.glob(srvdir))
    m0 = stamp()
    while True:
        time.sleep(1.0)
        try:
            if stamp() != m0:
                # keep the socket OPEN and inheritable; the new image adopts it by fd
                fd = httpd.socket.fileno()
                os.set_inheritable(fd, True)
                os.environ["STACK_REVIEW_FD"] = str(fd)
                lsp.stop_all("server reload")
                os.execv(sys.executable, [sys.executable, src, ROOT, SCRIPTS, CWD, str(PORT)])
        except OSError:
            pass


PACK_QUIET = 1.5   # let a burst of saves settle before packing


def pack_watcher():
    # Pack the extension when its source goes quiet. Without this the whole self-update path is
    # theatre: an edit sits on disk, updates.xml keeps advertising the old version, and the SW can
    # ask as eagerly as it likes — there is nothing newer to fetch. (dist/ lives in a subdir, so a
    # pack's own output can't retrigger us; manifest.json can — the version bump — hence the
    # re-baseline below, or we'd pack in a loop forever.)
    d = os.path.join(SCRIPTS, "gh-to-nvim")
    exts = (".js", ".json", ".css", ".html")

    def newest():
        try:
            return max((os.path.getmtime(os.path.join(d, f))
                        for f in os.listdir(d) if f.endswith(exts)), default=0.0)
        except OSError:
            return 0.0

    seen = newest()
    while True:
        time.sleep(1.0)
        m = newest()
        if m == seen:
            continue
        time.sleep(PACK_QUIET)
        if newest() != m:
            continue   # still being edited — catch it on the next quiet
        subprocess.run([os.path.join(SCRIPTS, "gh-to-nvim-pack")], capture_output=True)
        seen = newest()


def warm():
    # prune dead worktree registrations (each rotted entry costs stack-forest a subprocess on
    # every /node sweep), then pre-sweep the gh PR caches so a session's first read never
    # blocks on a cold multi-second gh call.
    srvctx.run(["git", "worktree", "prune"])
    try:
        sync._pr_state_map()
        sync._open_pr_heads()
    except Exception:
        pass


# STACK_REVIEW_SANDBOX=1 (scripts/viewer-sandbox): a test server over a throwaway repo runs none of
# the jobs that reach beyond it — gh prewarm, the extension packer, focus restacks, pregates.
SANDBOX = os.environ.get("STACK_REVIEW_SANDBOX") == "1"
if not SANDBOX:
    threading.Thread(target=warm, daemon=True).start()
    threading.Thread(target=reviews.warm_requests_forever, daemon=True).start()   # review-requested PRs → worktree ready before the first jump
    threading.Thread(target=pack_watcher, daemon=True).start()   # ext source → packed, so the installed copy has something newer to fetch
# The reaper exists because an unsupervised server nobody owns must not linger. Under
# launchd (KeepAlive) it would instead be a restart loop on a 15-minute clock — and now
# that idle costs 0.3% of a core there is nothing to shed. The supervised runner sets this.
if not os.environ.get("STACK_REVIEW_SUPERVISED"):
    threading.Thread(target=reaper, daemon=True).start()
threading.Thread(target=watcher, daemon=True).start()
threading.Thread(target=pulse, daemon=True).start()
threading.Thread(target=restack.drain_forever, daemon=True).start()   # queued restacks run the moment the driver seat frees
if not SANDBOX:
    threading.Thread(target=focus.sync_forever, daemon=True).start()   # focus forests follow origin/main on their own
    threading.Thread(target=pregate.pregate_forever, daemon=True).start()   # current roots pre-gated → the push door is already unlocked (or the red is already parked) on arrival
httpd.serve_forever()
