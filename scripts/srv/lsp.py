# srv/lsp.py — TypeScript hover + go-to-definition on both halves of a branch diff.
#
# One long-lived tsgo (`tsgo --lsp --stdio`, the binary Helix runs) reads viewer-owned detached
# worktrees that nobody works in: one serves the diff's "new" side (the branch tip), one its "old"
# side (the base). Asking about another commit MOVES a tree there instead of starting over:
# `git checkout` rewrites only the files that differ, seed-gen runs only when the generated
# types' inputs differ, and tsgo is told exactly which files changed (didChangeWatchedFiles) so it
# re-reads those and rebuilds the program incrementally on the next request. A small pool of trees
# keeps each dependency family's derived state (node_modules view, prisma client, packages dist):
# a commit goes to the tree already holding its lockfile + packages, so hopping between forests
# based on different mains doesn't re-derive them. Design + measurements: the
# canopy-v2-types wiki page.
#
# Exactness rules (test-lsp-differential checks answers byte-for-byte against a cold tsgo on a
# fresh worktree):
#   - the client declares dynamic watch registration, so tsgo never runs its own (asynchronous)
#     file watcher — every change reaches it as an explicit event before the next request
#   - generated files (.gen, packages/*/dist, the tree's prisma client) are diffed by stat
#     snapshot around seed-gen, and their changes are sent too
#   - a changed dependency view (node_modules links, the donor's install) or more changes than
#     tsgo's own excessive-change threshold restarts tsgo instead: past that threshold tsgo drops
#     its caches anyway, and a restart gives the old program's memory back
#
# Lifecycle: nothing starts until a request; ten idle minutes stop tsgo; the old side's project is
# unloaded after STACK_LSP_OLD_IDLE; tsgo never starts below the memory floor; the pidfile lets
# the next server image reap a tsgo that a hot reload or os._exit orphaned.
#
#   POST /lsp/hover      {branch, path, line, character, side?: "new"|"old", base?: sha}
#                          → {ok, contents, range}
#   POST /lsp/definition (same)  → {ok, sha, side, locations: [{path, line, character, endLine}]}
#        either one       → {ok: false, state: "loading" | "refused" | "error", message}
#   POST /lsp/prepare    {branch, base?} → move the trees there in the background (no tsgo)
#   GET  /lsp/status                    → {state, branch, trees, pid, rssMB, memLevel, …}
#   GET  /lsp/src        ?path=&sha=    → {path, text} — a definition target, at that commit
#
# `line` is 1-based (the diff's number on that side), `character` 0-based UTF-16 (LSP's default
# encoding, and what a JS string index already is). A "loading" answer means the request is still
# queued: asking again with the same position re-attaches to it rather than re-sending.
#
# Env: STACK_LSP_IDLE (600s), STACK_LSP_OLD_IDLE (180s), STACK_LSP_WAIT (per-request hold, 20s),
# HEAVY_TURN_MEM_FLOOR (30), STACK_LSP_MEM_LEVEL (forces the measured level; tests),
# STACK_LSP_STATE_DIR (pidfile, log, trees), STACK_LSP_TSGO (the binary),
# STACK_LSP_ANSWER_CACHE (0 disables the per-commit answer cache; the differential test),
# STACK_LSP_TREES (the tree pool, 4 ≈ 1 GB of disk; 1 flips one tree between tip and base),
# STACK_LSP_PREWARM ("trees": a branch page moves the trees; "server": and loads tsgo too),
# STACK_LSP_GOMEMLIMIT (tsgo's soft heap limit, 2000MiB), STACK_LSP_FRESH_CHECKER (0 trades the
# canonical hover text for warm-checker speed; see Server.ask).
import collections
import hashlib
import json
import os
import shutil
import signal
import subprocess
import threading
import time
from urllib.parse import parse_qs, unquote, urlparse

from . import ctx, actor

IDLE_S = int(os.environ.get("STACK_LSP_IDLE", "600"))
OLD_IDLE_S = int(os.environ.get("STACK_LSP_OLD_IDLE", "180"))
WAIT_S = float(os.environ.get("STACK_LSP_WAIT", "20"))
MEM_FLOOR = int(os.environ.get("HEAVY_TURN_MEM_FLOOR", "30"))
STATE_DIR = os.environ.get("STACK_LSP_STATE_DIR") or os.path.expanduser("~/Library/Caches/stack-review-lsp")
PIDFILE = os.path.join(STATE_DIR, "tsgo.json")
_VOLTA_TSGO = os.path.expanduser("~/.volta/bin/tsgo")
TSGO = os.environ.get("STACK_LSP_TSGO") or (_VOLTA_TSGO if os.path.exists(_VOLTA_TSGO) else "tsgo")
ANSWER_CACHE = os.environ.get("STACK_LSP_ANSWER_CACHE", "1") != "0"
POOL = max(1, int(os.environ.get("STACK_LSP_TREES", "4")))
PREWARM = os.environ.get("STACK_LSP_PREWARM", "trees")
FRESH_CHECKER = os.environ.get("STACK_LSP_FRESH_CHECKER", "1") != "0"   # Server.ask: canonical hover text   # "server": also load tsgo when a branch page opens
SRC_MAX = 400_000
LANGS = {".ts": "typescript", ".mts": "typescript", ".cts": "typescript", ".tsx": "typescriptreact",
         ".js": "javascript", ".mjs": "javascript", ".cjs": "javascript", ".jsx": "javascriptreact"}
SIDES = ("new", "old")
# tsgo's excessiveChangeThreshold (internal/project/filechange.go): past it a snapshot drops its
# whole file cache, so a restart costs no more and returns the old program's memory at once
EXCESSIVE_CHANGES = 1000
SOURCE_SUFFIXES = (".ts", ".tsx", ".mts", ".cts", ".js", ".jsx", ".mjs", ".cjs", ".json")
CREATED, CHANGED, DELETED = 1, 2, 3


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


def _read_json(path):
    try:
        with open(path) as f:
            return json.load(f)
    except (OSError, ValueError):
        return None


def _reap_recorded(only_orphans):
    # The pidfile is how a tsgo survives nothing: os._exit (the idle reaper) and execv (hot reload)
    # both skip any cleanup, and the next image — same pid after a re-exec — reaps what it names.
    # only_orphans spares a tsgo another live viewer server still owns. Never a pattern kill:
    # Helix runs the identical command line.
    d = _read_json(PIDFILE)
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


def _git(repo, *args, check=False, timeout=300):
    r = subprocess.run(["git", "-C", repo, "-c", "core.hooksPath=/dev/null", *args],
                       capture_output=True, text=True, timeout=timeout)
    if check and r.returncode != 0:
        raise RuntimeError(f"git {' '.join(args[:2])} failed: {(r.stderr or '').strip()[-300:]}")
    return r


def _stat_sig(path):
    try:
        st = os.stat(path)
        return [st.st_size, st.st_mtime_ns, st.st_ino]
    except OSError:
        return None


# ── generated state ─────────────────────────────────────────────────
# What tsgo reads that git doesn't track: the generated tRPC types, the packages' dist, the
# tree-local prisma client — and, through node_modules links, the donor's (or a lockfile home's)
# install. snapshot() records the first three by stat and the link targets verbatim.

def snapshot(root):
    files, links = {}, {}

    def walk(d):
        for dp, _dns, fns in os.walk(d):
            for f in fns:
                p = os.path.join(dp, f)
                try:
                    st = os.lstat(p)
                except OSError:
                    continue
                files[p] = (st.st_size, st.st_mtime_ns, st.st_ino)

    walk(os.path.join(root, ".gen", "trpc-types"))
    pk = os.path.join(root, "packages")
    if os.path.isdir(pk):
        for p in sorted(os.listdir(pk)):
            walk(os.path.join(pk, p, "dist"))
    nm = os.path.join(root, "node_modules")
    if os.path.islink(nm):
        links[nm] = os.readlink(nm)
    elif os.path.isdir(nm):
        for e in os.listdir(nm):
            ep = os.path.join(nm, e)
            if os.path.islink(ep):
                links[ep] = os.readlink(ep)
            elif e.startswith(("@", ".prisma")) and os.path.isdir(ep):
                for s in os.listdir(ep):
                    sp = os.path.join(ep, s)
                    if os.path.islink(sp):
                        links[sp] = os.readlink(sp)
                    elif e in (".prisma", "@prisma"):
                        walk(sp) if os.path.isdir(sp) else files.__setitem__(sp, _stat_sig(sp))
    return files, links


def snapshot_events(before, after):
    """(events, links_changed) between two snapshots."""
    (f0, l0), (f1, l1) = before, after
    ev = []
    for p in f0.keys() | f1.keys():
        if p not in f0:
            ev.append((p, CREATED))
        elif p not in f1:
            ev.append((p, DELETED))
        elif f0[p] != f1[p]:
            ev.append((p, CHANGED))
    return sorted(ev), l0 != l1


def donor_key(donor):
    """Changes whenever the donor's install does — everything a tree borrows through its links."""
    if not donor:
        return None
    nm = os.path.join(donor, "node_modules")
    return [donor, _stat_sig(nm), _stat_sig(os.path.join(nm, ".package-lock.json")),
            _stat_sig(os.path.join(nm, ".prisma", "client", "index.d.ts"))]


def _stem(rel):
    for suf in (".d.ts", ".d.mts", ".d.cts") + SOURCE_SUFFIXES:
        if rel.endswith(suf):
            return rel[: -len(suf)]
    return rel


def gen_inputs(root):
    """Tree-relative inputs of the last tRPC types emit (its tsbuildinfo graph), case-folded — the
    tsbuildinfo records many names as the compiler's canonical lowercased path — or None."""
    info = _read_json(os.path.join(root, ".gen", "trpc-types.tsbuildinfo"))
    if not info:
        return None
    names = (info.get("program") or info).get("fileNames") or []
    if not names:
        return None
    base, low, out = os.path.join(root, ".gen"), root.lower() + os.sep, []
    for n in names:
        if n.startswith("lib.") and "/" not in n:   # the compiler's own lib files, versioned with it
            continue
        p = os.path.normpath(os.path.join(base, n)).lower()
        if p.startswith(low) and "/node_modules/" not in p[len(low) - 1:]:
            out.append(p[len(low):])
    return sorted(out)


def needs_regen(changes, inputs):
    """Whether a tree move can change what seed-gen --sync produces. `changes` are (status, rel)
    from git diff. Exact by construction: the emit's graph is `inputs` + configs + manifests +
    packages/** + resolution; an ADDED file only changes resolution when an import could now land
    on it — its stem (or its directory, for an index) is already an input's stem."""
    if inputs is None:
        return True
    ins = set(inputs)
    stems = {_stem(i) for i in inputs}
    for st, rel in changes:
        rel = rel.lower()   # inputs are case-folded (gen_inputs)
        base = os.path.basename(rel)
        if rel in ins or base in ("package.json", "package-lock.json", ".npmrc") \
                or base.startswith(("tsconfig", "tsbase")):
            return True
        if rel.startswith("packages/") and not rel.startswith("packages/prisma/migrations/"):
            return True
        if st == "A" and rel.endswith(SOURCE_SUFFIXES):
            s = _stem(rel)
            if s in stems or (os.path.basename(s) == "index" and os.path.dirname(s) in stems):
                return True
    return False


class Move:
    def __init__(self, events=(), restart=False, why=""):
        self.events, self.restart, self.why = list(events), restart, why
        self.timings = {}


def pool_dir(repo):
    slug = os.path.basename(repo.rstrip("/")) + "-" + hashlib.md5(repo.encode()).hexdigest()[:6]
    d = os.path.join(STATE_DIR, "trees", slug)
    os.makedirs(d, exist_ok=True)
    return os.path.realpath(d)


def family(repo, sha):
    """What a tree's derived state hangs on: the lockfile and packages/ (prisma schema included)."""
    return hashlib.md5(_git(repo, "ls-tree", sha, "package-lock.json", "packages").stdout.encode()).hexdigest()


class Tree:
    """A viewer-owned detached worktree in a repo's pool."""

    def __init__(self, repo, name):
        self.repo, self.slot = repo, name
        self.path = os.path.join(pool_dir(repo), name)
        self.meta_path = self.path + ".json"
        self.meta = _read_json(self.meta_path) or {}
        self.warning = ""

    @property
    def sha(self):
        return self.meta.get("sha")

    def _save(self):
        with open(self.meta_path + ".tmp", "w") as f:
            json.dump(self.meta, f)
        os.replace(self.meta_path + ".tmp", self.meta_path)

    def _valid(self):
        if not os.path.isfile(os.path.join(self.path, ".git")):
            return False
        r = _git(self.path, "rev-parse", "HEAD")
        return r.returncode == 0 and r.stdout.strip() == self.meta.get("sha")

    def _create(self, sha):
        if os.path.lexists(self.path):
            _git(self.repo, "worktree", "remove", "--force", self.path)
            if os.path.lexists(self.path):
                shutil.rmtree(self.path)   # our own dir under STATE_DIR; rmtree unlinks, never follows
        _git(self.repo, "worktree", "prune")
        _git(self.repo, "worktree", "add", "--detach", self.path, sha, check=True)
        os.makedirs(os.path.join(self.path, "node_modules"), exist_ok=True)   # seed-gen explodes it
        self.meta = {"sha": sha}

    def _sync(self):
        """seed-gen --sync: the one implementation of a tree's generated state."""
        r = subprocess.run([os.path.join(ctx.SCRIPTS, "seed-gen"), "--sync", self.path], capture_output=True,
                           text=True, timeout=900, env=actor.child_env() or dict(os.environ))
        out = (r.stdout or "").strip()
        self.warning = "" if r.returncode == 0 else ("tRPC types may be stale: " + (out.splitlines() or ["seed-gen failed"])[-1])
        self.meta["inputs"] = gen_inputs(self.path) if r.returncode == 0 else None
        if out:
            ctx.log(f"lsp: seed-gen {self.slot} @{self.meta['sha'][:9]}: {out.replace(chr(10), ' | ')}")

    def move(self, sha, donor):
        """Put the tree at `sha` with its generated state current; what tsgo must hear about it."""
        t0 = time.time()
        dkey = donor_key(donor)
        if not self._valid():
            existed = os.path.lexists(self.path)   # a tsgo may still hold files read from the old incarnation
            self._create(sha)
            self.meta["family"] = family(self.repo, sha)
            mv = Move(restart=existed, why="tree recreated")
            t1 = time.time()
            self._sync()
            self.meta["donor"] = dkey
            self._save()
            mv.timings = {"worktree": t1 - t0, "gen": time.time() - t1}
            return mv
        cur = self.meta["sha"]
        stale_gen = self.meta.get("donor") != dkey or self.meta.get("inputs") is None
        if cur == sha and not stale_gen:
            return Move()
        raw = _git(self.path, "diff", "--name-status", "--no-renames", "-z", cur, sha, check=True).stdout
        toks = raw.split("\0")
        changes = [(toks[i][:1], toks[i + 1]) for i in range(0, len(toks) - 1, 2) if toks[i]]
        _git(self.path, "checkout", "-q", "--detach", "--force", sha, check=True)
        self.meta["sha"] = sha
        self.meta["family"] = family(self.repo, sha)
        t1 = time.time()
        kind = {"A": CREATED, "D": DELETED}
        mv = Move([(os.path.join(self.path, rel), kind.get(st, CHANGED)) for st, rel in changes])
        if self.meta.get("donor") != dkey:
            mv.restart, mv.why = True, "the donor's install changed"
        if stale_gen or needs_regen(changes, self.meta.get("inputs")):
            before = snapshot(self.path)
            self._sync()
            ev, links_changed = snapshot_events(before, snapshot(self.path))
            mv.events += ev
            if links_changed:
                mv.restart, mv.why = True, "node_modules view changed"
            self.meta["donor"] = dkey
        if len(mv.events) > EXCESSIVE_CHANGES and not mv.restart:
            mv.restart, mv.why = True, f"{len(mv.events)} files changed"
        self._save()
        mv.timings = {"checkout": t1 - t0, "gen": time.time() - t1}
        return mv


# ── the language server ─────────────────────────────────────────────

class _Pending:
    def __init__(self):
        self.event = threading.Event()
        self.result = None
        self.error = None

    def settle(self, result=None, error=None):
        self.result, self.error = result, error
        self.event.set()


class Server:
    """One tsgo over stdio: the wire, the open documents, change notifications."""

    def __init__(self, root, pidfile=True):
        self.root = root
        self.started_at = time.time()
        self.progress = {}
        self.opened = {}   # abs path → version
        self.kind = {}     # abs path → "configured" | "inferred" (custom/projectInfo)
        self._lock = threading.Lock()
        self._write = threading.Lock()
        self._next = 1
        self._pending = {}
        self.exited = False
        log = open(os.path.join(STATE_DIR, "tsgo.log"), "ab")
        # a soft heap limit: Go otherwise keeps every superseded program's memory — a footprint of
        # 2.2 → 3.9 GB over four incremental moves, flat at 2.2 GB with the limit (2026-10-22)
        env = dict(os.environ, GOMEMLIMIT=os.environ.get("STACK_LSP_GOMEMLIMIT", "2000MiB"))
        self.proc = subprocess.Popen([TSGO, "--lsp", "--stdio"], cwd=root, stdin=subprocess.PIPE,
                                     stdout=subprocess.PIPE, stderr=log, start_new_session=True, env=env)
        log.close()
        self.pidfile = pidfile
        if pidfile:
            with open(PIDFILE, "w") as f:
                json.dump({"pid": self.proc.pid, "pgid": self.proc.pid, "owner": os.getpid(),
                           "root": root, "started": self.started_at}, f)
        threading.Thread(target=self._reader, daemon=True).start()
        uri = "file://" + root
        init = self.request("initialize", {
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
                # dynamic watch registration: tsgo then leaves file watching to us and runs no
                # FSEvents watcher of its own — every change arrives as an explicit, ordered event
                "workspace": {"configuration": True, "workspaceFolders": True,
                              "didChangeWatchedFiles": {"dynamicRegistration": True}},
            },
        })
        if not init.event.wait(120) or init.error:
            self.kill()
            raise RuntimeError(f"tsgo didn't initialize: {init.error or 'no answer in 120s'}")
        self.notify("initialized", {})

    def alive(self):
        return not self.exited and self.proc.poll() is None

    def kill(self):
        p = self.proc
        if p.poll() is None:
            _killpg(p.pid, p.pid)
            try:
                p.wait(timeout=2)
            except subprocess.TimeoutExpired:
                pass
        d = _read_json(PIDFILE)
        if self.pidfile and d and d.get("pid") == p.pid:
            try:
                os.unlink(PIDFILE)
            except OSError:
                pass
        for pend in list(self._pending.values()):
            pend.settle(error="tsgo stopped")
        self._pending.clear()

    def _send(self, msg):
        body = json.dumps(msg).encode()
        with self._write:
            self.proc.stdin.write(b"Content-Length: %d\r\n\r\n" % len(body) + body)
            self.proc.stdin.flush()

    def request(self, method, params):
        pend = _Pending()
        with self._lock:
            rid = self._next
            self._next += 1
            self._pending[rid] = pend
        try:
            self._send({"jsonrpc": "2.0", "id": rid, "method": method, "params": params})
        except (BrokenPipeError, OSError, ValueError) as e:
            self._pending.pop(rid, None)
            pend.settle(error=f"language server gone: {e}")
        return pend

    def notify(self, method, params):
        try:
            self._send({"jsonrpc": "2.0", "method": method, "params": params})
        except (BrokenPipeError, OSError, ValueError):
            pass

    def _reader(self):
        out = self.proc.stdout
        while True:
            length = None
            while True:
                line = out.readline()
                if not line:
                    self.exited = True
                    for pend in list(self._pending.values()):
                        pend.settle(error="tsgo exited")
                    self._pending.clear()
                    return
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

    def _on_message(self, msg):
        method = msg.get("method")
        if method is None:
            pend = self._pending.pop(msg.get("id"), None)
            if pend:
                err = msg.get("error")
                pend.settle(result=msg.get("result"), error=err and (err.get("message") or str(err)))
            return
        if "id" in msg:   # a server→client request (configuration, watcher registration, progress): answer every one
            result = None
            if method == "workspace/configuration":
                result = [None] * len((msg.get("params") or {}).get("items") or [])
            try:
                self._send({"jsonrpc": "2.0", "id": msg["id"], "result": result})
            except (BrokenPipeError, OSError, ValueError):
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

    # documents — always the file's text on disk, which the tree holds at the asked commit
    def open(self, full):
        if full in self.opened:
            return
        with open(full, encoding="utf-8", errors="replace") as f:
            text = f.read()
        self.notify("textDocument/didOpen", {"textDocument": {
            "uri": "file://" + full, "languageId": LANGS.get(os.path.splitext(full)[1], "typescript"),
            "version": 1, "text": text}})
        self.opened[full] = 1

    def close_under(self, root):
        for full in [p for p in self.opened if p.startswith(root + os.sep)]:
            self.notify("textDocument/didClose", {"textDocument": {"uri": "file://" + full}})
            del self.opened[full]

    def reopen_one(self, root):
        """Close + reopen one document under root — tsgo unloads projects no open file needs only
        when a file opens (projectcollectionbuilder: cleanupConfiguredProjects)."""
        full = next((p for p in self.opened if p.startswith(root + os.sep)), None)
        if full:
            self.notify("textDocument/didClose", {"textDocument": {"uri": "file://" + full}})
            del self.opened[full]
            self.open(full)

    def changed(self, events):
        """Tell tsgo what moved on disk; documents it holds open follow their file."""
        if not events:
            return
        self.notify("workspace/didChangeWatchedFiles",
                    {"changes": [{"uri": "file://" + p, "type": t} for p, t in events]})
        for p, t in events:
            if p not in self.opened:
                continue
            self.kind.pop(p, None)   # a moved tree may hand the file to another project
            if t == DELETED or not os.path.isfile(p):
                self.notify("textDocument/didClose", {"textDocument": {"uri": "file://" + p}})
                del self.opened[p]
            else:
                with open(p, encoding="utf-8", errors="replace") as f:
                    text = f.read()
                self.opened[p] += 1
                self.notify("textDocument/didChange", {"textDocument": {"uri": "file://" + p, "version": self.opened[p]},
                                                       "contentChanges": [{"text": text}]})

    def ask(self, method, full, line0, character):
        """One answer, canonical: what a fresh tsgo gives for this file at this commit, whatever
        was asked before. Two things in tsgo would otherwise leak earlier asks into it:
          - a file no tsconfig includes joins the session's ONE inferred program, whose roots are
            every such file open — another commit's test file pulled @types/node globals into
            a phishtank test's hover (2026-10-22). So a loose file is asked alone.
          - hover text depends on the checker's history: a union's synthesized `?: undefined`
            members print in the order types were created (cold: domain-last; after six other
            hovers in the file: domain-first). An identical-content didChange makes tsgo clone the
            program with a fresh checker pool — 0.2-0.5 s, against 0.03 s from a warm checker."""
        self.open(full)
        if full not in self.kind:
            info = self.request("custom/projectInfo", {"textDocument": {"uri": "file://" + full}})
            info.event.wait(600)
            self.kind[full] = "configured" if (info.result or {}).get("configFilePath") else "inferred"
        if self.kind[full] == "inferred":
            for other in [p for p, k in self.kind.items() if k == "inferred" and p != full and p in self.opened]:
                self.notify("textDocument/didClose", {"textDocument": {"uri": "file://" + other}})
                del self.opened[other]
        if method == "textDocument/hover" and FRESH_CHECKER:
            self._touch(full)
        return self.request(method, {"textDocument": {"uri": "file://" + full},
                                     "position": {"line": line0, "character": character}})

    def _touch(self, full):
        with open(full, encoding="utf-8", errors="replace") as f:
            text = f.read()
        self.opened[full] += 1
        self.notify("textDocument/didChange", {"textDocument": {"uri": "file://" + full, "version": self.opened[full]},
                                               "contentChanges": [{"text": text}]})

    def pids(self):
        r = subprocess.run(["ps", "-axo", "pid=,pgid=,rss="], capture_output=True, text=True)
        return [(int(a), int(c)) for a, b, c in (ln.split() for ln in r.stdout.splitlines() if ln.strip())
                if int(b) == self.proc.pid]

    def rss_mb(self):
        if not self.alive():
            return None
        return round(sum(kb for _, kb in self.pids()) / 1024)


# ── the engine: trees + server + answers, driven by one worker ──────

class Job:
    def __init__(self, kind, key, fn):
        self.kind, self.key, self.fn = kind, key, fn
        self.event = threading.Event()
        self.result = None
        self.error = None
        self.done_at = 0.0


class Engine:
    def __init__(self):
        self.pools = {}           # repo → [Tree]
        self.assign = {}          # (repo, side) → the Tree serving that side
        self.server = None
        self.server_repo = None
        self.state, self.message = "idle", ""
        self.branch = {}          # slot → the branch / label last asked on that side
        self.last_req = time.time()
        self.last_old = 0.0
        self.answers = collections.OrderedDict()
        self.served = set()       # absolute definition targets outside the trees (/lsp/src may read them)
        self.last_move = {}
        self._jobs = collections.deque()
        self._inflight = {}
        self._cv = threading.Condition()
        self._worker = None
        self._donors = {}

    # worker
    def submit(self, kind, key, fn):
        with self._cv:
            for k in [k for k, j in self._inflight.items() if j.done_at and time.time() - j.done_at > 60]:
                del self._inflight[k]
            job = self._inflight.get(key)
            if job and not job.done_at:
                return job
            if kind == "prepare":   # a newer prefetch for the same slot supersedes a queued one
                for j in [j for j in self._jobs if j.kind == "prepare" and j.key[:3] == key[:3]]:
                    self._jobs.remove(j)
                    j.error = "superseded"
                    j.done_at = time.time()
                    j.event.set()
            job = Job(kind, key, fn)
            self._inflight[key] = job
            self._jobs.append(job)
            if not self._worker or not self._worker.is_alive():
                self._worker = threading.Thread(target=self._work, daemon=True)
                self._worker.start()
            self._cv.notify()
            return job

    def _work(self):
        while True:
            with self._cv:
                while not self._jobs:
                    self._cv.wait()
                job = self._jobs.popleft()
            try:
                job.result = job.fn()
            except Exception as e:   # a dead worker would leave every request "loading" forever
                job.error = str(e) if isinstance(e, RuntimeError) else f"{type(e).__name__}: {e}"
                ctx.log(f"lsp: {job.kind} failed: {job.error}")
            job.done_at = time.time()
            job.event.set()

    # trees
    def pool(self, repo):
        if repo not in self.pools:
            d = pool_dir(repo)
            names = sorted(n[:-5] for n in os.listdir(d) if n.endswith(".json") and n.startswith("t"))
            self.pools[repo] = [Tree(repo, n) for n in names][:POOL]
        return self.pools[repo]

    def tree(self, repo, side):
        return self.assign.get((repo, side))

    def _pick(self, repo, side, sha):
        """The tree for `sha` on this side: one already there, else one of its dependency family
        (the cheap move), else a new tree while the pool has room, else the least recently used.
        Never the other side's tree — unless the pool is one tree, time-shared."""
        cur = self.assign.get((repo, side))
        if cur and cur.sha == sha:
            return cur
        other = self.assign.get((repo, "old" if side == "new" else "new"))
        pool = self.pool(repo)
        usable = [t for t in pool if POOL == 1 or t is not other]
        fam = family(repo, sha)
        by_use = sorted(usable, key=lambda t: -t.meta.get("used", 0))
        pick = next((t for t in by_use if t.sha == sha), None) \
            or next((t for t in by_use if t.meta.get("family") == fam), None)
        if not pick and len(pool) < POOL:
            taken = {t.slot for t in pool}
            pick = Tree(repo, next(f"t{i}" for i in range(POOL) if f"t{i}" not in taken))
            pool.append(pick)
        pick = pick or by_use[-1]
        if cur is not None and cur is not pick and cur is not other and self.server and self.server.alive():
            self.server.close_under(cur.path)   # its project unloads at the next open
        self.assign[(repo, side)] = pick
        pick.meta["used"] = time.time()
        return pick

    def donor(self, repo):
        if repo not in self._donors:
            r = subprocess.run([os.path.join(ctx.SCRIPTS, "stack-donor"), repo], capture_output=True, text=True)
            self._donors[repo] = r.stdout.strip() if r.returncode == 0 and r.stdout.strip() else None
        return self._donors[repo]

    def _move(self, repo, slot, sha):
        t = self._pick(repo, slot, sha)
        if t.sha == sha and t._valid() and t.meta.get("donor") == donor_key(self.donor(repo)) \
                and t.meta.get("inputs") is not None:
            return Move()
        self.state, self.message = "preparing", f"moving the {slot}-side tree to {sha[:9]}"
        mv = t.move(sha, self.donor(repo))
        self.last_move[slot] = {"sha": sha, "tree": t.slot, "events": len(mv.events), "restart": mv.restart, "why": mv.why,
                                **{k: round(v, 2) for k, v in mv.timings.items()}}
        s = self.server
        if s and s.alive() and self.server_repo == repo:
            if mv.restart:
                self.stop(f"{slot} side: {mv.why}")
            else:
                s.changed(mv.events)
        if not (self.server and self.server.alive()):
            self.state, self.message = "idle", ""
        else:
            self.state, self.message = "ready", ""
        return mv

    def prepare(self, repo, slot, sha):
        self._move(repo, slot, sha)
        if PREWARM != "server" or slot != "new":
            return
        try:   # load the tip's project now, so the first K is a warm answer (costs tsgo's memory)
            s = self._ensure_server(repo)
        except _Refused:
            return
        t = self.tree(repo, slot)
        anchor = next((os.path.join(t.path, r) for r in ("trpc/root.ts", "lib/index.ts")
                       if os.path.isfile(os.path.join(t.path, r))), None)
        if anchor is None:
            names = _git(t.path, "ls-files", "--", "*.ts").stdout.split()
            anchor = names and os.path.join(t.path, names[0])
        if anchor:
            s.ask("textDocument/hover", anchor, 0, 0).event.wait(120)
            self.state, self.message = "ready", ""

    def _ensure_server(self, repo):
        s = self.server
        if s and s.alive() and self.server_repo == repo:
            return s
        if s:
            self.stop("switched repo" if self.server_repo != repo else "tsgo exited")
        lvl = mem_level()
        if lvl is not None and lvl < MEM_FLOOR:
            raise _Refused(f"memory is tight ({lvl}% free, floor {MEM_FLOOR}%) — not starting a language server; "
                           "press o to read it in Helix")
        os.makedirs(STATE_DIR, exist_ok=True)
        _reap_recorded(only_orphans=False)   # one per machine: a rival server's tsgo goes too
        self.state, self.message = "starting", "starting the type server"
        # rooted above the trees: projects come from each opened file's tsconfig, not the root
        self.server = Server(pool_dir(repo))
        self.server_repo = repo
        self.state, self.message = "loading", "loading types"
        return self.server

    def answer(self, repo, slot, sha, method, rel, line, character):
        """(raw LSP result, the root it was read under) for a position at `sha`."""
        dkey = donor_key(self.donor(repo))
        akey = (repo, sha, json.dumps(dkey), method, rel, line, character)
        if ANSWER_CACHE and akey in self.answers:
            self.answers.move_to_end(akey)
            return self.answers[akey]
        self._move(repo, slot, sha)
        t = self.tree(repo, slot)
        full = os.path.join(t.path, rel)
        if not os.path.isfile(full):
            raise RuntimeError(f"{rel} isn't in {sha[:9]}")
        s = self._ensure_server(repo)
        pend = s.ask(method, full, line - 1, character)
        while not pend.event.wait(1):
            if not s.alive():
                raise RuntimeError("tsgo exited")
        if pend.error:
            raise RuntimeError(str(pend.error))
        self.state, self.message = "ready", ""
        out = (pend.result, t.path)
        if ANSWER_CACHE:
            self.answers[akey] = out
            while len(self.answers) > 4000:
                self.answers.popitem(last=False)
        return out

    def unload_old(self, repo):
        s, old, new = self.server, self.tree(repo, "old"), self.tree(repo, "new")
        if s and s.alive() and old and old is not new:
            s.close_under(old.path)
            if new:
                s.reopen_one(new.path)

    def stop(self, reason):
        s, self.server = self.server, None
        if s:
            s.kill()
            ctx.log(f"lsp: stopped tsgo ({reason})")
        self.state, self.message = "idle", f"stopped ({reason})"


class _Refused(Exception):
    pass


_engine = Engine()
_idle_started = [False]


def _idle_loop():
    while True:
        time.sleep(min(15, max(1, min(IDLE_S, OLD_IDLE_S) / 4)))
        e = _engine
        s = e.server
        if not (s and s.alive()):
            continue
        now = time.time()
        if now - e.last_req > IDLE_S:
            e.submit("stop", ("stop", now), lambda: e.stop(f"idle {IDLE_S // 60}m" if IDLE_S >= 60 else f"idle {IDLE_S}s"))
        elif e.last_old and now - e.last_old > OLD_IDLE_S and e.server_repo:
            e.last_old = 0.0
            repo = e.server_repo
            e.submit("unload", ("unload", now), lambda: e.unload_old(repo))


def _start_idle():
    if not _idle_started[0]:
        _idle_started[0] = True
        threading.Thread(target=_idle_loop, daemon=True).start()


def _commit(repo, ref):
    r = subprocess.run(["git", "-C", repo, "rev-parse", "--verify", "-q", f"{ref}^{{commit}}"],
                       capture_output=True, text=True)
    return r.stdout.strip() if r.returncode == 0 else ""


def _tip(repo, branch):
    return _commit(repo, f"refs/heads/{branch}") or (_commit(repo, branch) if branch.startswith("refs/") else "")


def _loading(e):
    s = e.server
    prog = list(s.progress.values())[-1] if s and s.progress else None
    msg = e.message or "loading types"
    return {"ok": False, "state": "loading", "message": msg, "progress": prog}


def _ask(req, raw, method):
    try:
        d = json.loads(raw or "{}")
        branch, rel = str(d["branch"]), str(d["path"])
        line, character = int(d["line"]), int(d["character"])
        side = str(d.get("side") or "new")
        base = str(d.get("base") or "")
    except (ValueError, KeyError, TypeError):
        return req._send(400, json.dumps({"ok": False, "state": "error", "message": "want {branch, path, line, character}"}))
    if os.path.isabs(rel) or ".." in rel.split("/") or line < 1 or character < 0 or side not in SIDES:
        return req._send(400, json.dumps({"ok": False, "state": "error", "message": f"bad position {side} {rel}:{line}:{character}"}))
    ext = os.path.splitext(rel)[1]
    if ext not in LANGS:
        return req._send(200, json.dumps({"ok": False, "state": "error", "message": f"no language server for {ext or 'this file'}"}))
    repo = ctx.repo_cwd()
    sha = _tip(repo, branch) if side == "new" else (_commit(repo, base) if base else "")
    if not sha:
        why = f"no branch {branch}" if side == "new" else "this view has no single base commit to type"
        return req._send(200, json.dumps({"ok": False, "state": "error", "message": why}))
    e = _engine
    _start_idle()
    e.last_req = time.time()
    if side == "old":
        e.last_old = time.time()
    e.branch[side] = branch if side == "new" else f"{branch}'s base"
    job = e.submit("ask", ("ask", repo, side, sha, method, rel, line, character),
                   lambda: e.answer(repo, side, sha, method, rel, line, character))
    if not job.event.wait(WAIT_S):
        return req._send(200, json.dumps(_loading(e)))
    if job.error:
        st = "refused" if "memory is tight" in job.error else "error"
        return req._send(200, json.dumps({"ok": False, "state": st, "message": job.error}))
    e.last_req = time.time()
    result, root = job.result
    req._send(200, json.dumps(_shape(root, sha, side, method, result)))


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


def _shape(root, sha, side, method, result):
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
        path = unquote(urlparse(uri).path)
        if path.startswith(root + os.sep):
            path = os.path.relpath(path, root)
        else:
            _engine.served.add(path)
        locs.append({"path": path, "line": rng["start"]["line"] + 1,
                     "character": rng["start"]["character"], "endLine": rng["end"]["line"] + 1})
    return {"ok": True, "sha": sha, "side": side, "locations": locs}


def hover(req, raw):
    return _ask(req, raw, "textDocument/hover")


def definition(req, raw):
    return _ask(req, raw, "textDocument/definition")


def prepare(req, raw):
    """Move the trees to a branch page's tip (and base) while it is read — git + seed-gen only;
    tsgo's ~1.5 GB waits for the first K unless STACK_LSP_PREWARM=server."""
    try:
        d = json.loads(raw or "{}")
    except ValueError:
        d = {}
    repo = ctx.repo_cwd()
    for slot, sha in (("new", _tip(repo, str(d.get("branch") or ""))), ("old", _commit(repo, str(d.get("base") or "")) if d.get("base") else "")):
        if sha:
            _engine.submit("prepare", ("prepare", repo, slot, sha), lambda slot=slot, sha=sha: _engine.prepare(repo, slot, sha))
    req._send(200, '{"ok":true}')


def status(req, u=None):
    e, lvl = _engine, mem_level()
    s = e.server
    alive = bool(s and s.alive())
    trees = {side: {"sha": t.sha, "tree": t.slot, "path": t.path, "warning": t.warning or None}
             for (repo, side), t in e.assign.items() if repo == ctx.repo_cwd()}
    state = e.state if alive or e.state in ("preparing", "error") else "idle"
    prog = list(s.progress.values())[-1] if alive and s.progress else None
    req._send(200, json.dumps({
        "state": state, "message": e.message, "branch": e.branch.get("new"), "branches": e.branch,
        "trees": trees, "lastMove": e.last_move,
        "startedAt": s.started_at if alive else None, "idleS": round(time.time() - e.last_req),
        "idleKillS": IDLE_S, "oldIdleS": OLD_IDLE_S, "memLevel": lvl, "memFloor": MEM_FLOOR, "progress": prog,
        "pid": s.proc.pid if alive else None, "rssMB": s.rss_mb() if alive else None,
        "answers": len(e.answers),
    }))


def src(req, u):
    """A definition target's text at the commit the answer came from — git for tracked files,
    the tree for generated ones while it still sits at that commit, absolute paths only if served."""
    q = parse_qs(u.query)
    path, sha = q.get("path", [""])[0], q.get("sha", [""])[0]
    repo, e = ctx.repo_cwd(), _engine
    text, err = None, ""
    if os.path.isabs(path):
        if path in e.served:
            try:
                with open(path, encoding="utf-8", errors="replace") as f:
                    text = f.read(SRC_MAX)
            except OSError as ex:
                err = str(ex)
        else:
            err = f"not readable here: {path}"
    elif ".." in path.split("/"):
        err = f"not readable here: {path}"
    else:
        trees = e.pools.get(repo, [])
        if not sha:   # an old client: the new side's commit
            sha = getattr(e.tree(repo, "new"), "sha", "") or ""
        if sha:
            r = _git(repo, "show", f"{sha}:{path}")
            if r.returncode == 0:
                text = r.stdout[:SRC_MAX]
            else:
                t = next((t for t in trees if t.sha == sha), None)
                full = t and os.path.normpath(os.path.join(t.path, path))
                if full and full.startswith(t.path + os.sep) and os.path.isfile(full):
                    with open(full, encoding="utf-8", errors="replace") as f:
                        text = f.read(SRC_MAX)
                else:
                    err = f"{path} isn't at {sha[:9]}"
        else:
            err = "no language server tree"
    if text is None:
        return req._send(200, json.dumps({"err": err}))
    req._send(200, json.dumps({"path": path, "sha": sha, "text": text}))


def stop_all(reason="server exit"):
    _engine.stop(reason)


_reap_recorded(only_orphans=True)
