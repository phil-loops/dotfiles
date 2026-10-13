# srv/gitgraph.py — the commit graph in memory, so ancestry questions stop costing a spawn.
#
# One `git rev-list` loads every commit reachable from the branches and remotes (~50k in loops,
# ~0.4s, once per server); later tips are folded in incrementally when the stat watcher's
# generation moves. Each commit gets a generation number (1 + max over its parents), and every
# walk below visits commits in descending generation: by the time a commit is popped, every
# descendant that can reach it already has, so its paint flags are final. That ordering is what
# makes these answers exact rather than heuristic — and it bounds each walk to the commits above
# the fork point instead of the whole history.
#
# Answers: is-ancestor, the merge base when it is unique (several bases → None, the caller asks
# git so the tie-break stays git's), rev-list --count of A..B, and a commit's parents. Refs
# resolve from packed-refs + loose ref files with git's DWIM order; anything this module can't
# name with certainty (HEAD, rev expressions, annotated tags) resolves to None and the caller
# falls back to git.
import heapq
import os
import subprocess
import threading

_LOCK = threading.Lock()
_GRAPHS = {}   # git common dir -> Graph
_HEX = set("0123456789abcdef")


def _is_sha(s):
    return len(s) == 40 and set(s) <= _HEX


def plain_refname(name):
    """A full refname with no revision syntax — its absence from the ref map means it doesn't exist."""
    return name.startswith("refs/") and not any(c in name for c in "^~:@{}*?[ \\") and ".." not in name


class Graph:
    def __init__(self, gd):
        self.gd = gd
        self.parents = {}   # sha -> tuple of parent shas
        self.gen = {}       # sha -> generation number
        self.tips = set()   # shas whose whole ancestry is loaded
        self.refs_gen = None
        self.refs = {}      # full refname -> sha (symrefs resolved)
        self.lock = threading.RLock()

    # ── loading ───────────────────────────────────────────────────────────
    def _git(self, args, input=None):
        return subprocess.run(["git", "--git-dir", self.gd, *args], capture_output=True, text=True, input=input)

    def _ingest(self, out):
        fresh = []
        for ln in out.splitlines():
            p = ln.split()
            if p and p[0] not in self.parents:
                self.parents[p[0]] = tuple(p[1:])
                fresh.append(p[0])
        # generations for the new commits: parents first. rev-list emits children before parents,
        # so walking the batch backwards settles most in one pass; the stack handles the rest.
        for sha in reversed(fresh):
            self._settle(sha)

    def _settle(self, sha):
        if sha in self.gen:
            return
        stack = [sha]
        while stack:
            c = stack[-1]
            if c in self.gen:
                stack.pop()
                continue
            ps = self.parents.get(c, ())
            todo = [p for p in ps if p not in self.gen and p in self.parents]
            if todo:
                stack.extend(todo)
                continue
            self.gen[c] = 1 + max((self.gen.get(p, 0) for p in ps), default=0)
            stack.pop()

    def extend(self, tips):
        """Make every sha in tips (and its ancestry) known. False when git can't produce one."""
        with self.lock:
            return self._extend(tips)

    def _extend(self, tips):
        new = [t for t in tips if t not in self.tips and t not in self.parents]
        if not new:
            self.tips.update(t for t in tips)
            return True
        stdin = "\n".join(new + ["^" + t for t in self.tips]) + "\n"
        r = self._git(["rev-list", "--parents", "--stdin"], input=stdin)
        if r.returncode != 0:
            return False
        self._ingest(r.stdout)
        self.tips.update(new)
        return all(t in self.parents for t in new)

    def load_refs(self, generation):
        """Re-read refs (packed-refs + loose files) when the watcher's generation moved, and fold
        any new branch/remote tips into the graph."""
        if self.refs_gen == generation:
            return
        refs = {}
        try:
            with open(os.path.join(self.gd, "packed-refs")) as fh:
                for ln in fh:
                    if ln[:1] in ("#", "^") or not ln.strip():
                        continue
                    sha, _, name = ln.rstrip("\n").partition(" ")
                    refs[name] = sha
        except OSError:
            pass
        root = os.path.join(self.gd, "refs")
        sym = {}
        for d, _dirs, files in os.walk(root):
            for f in files:
                path = os.path.join(d, f)
                name = os.path.relpath(path, self.gd)
                try:
                    with open(path) as fh:
                        val = fh.read().strip()
                except OSError:
                    continue
                if val.startswith("ref: "):
                    sym[name] = val[5:]
                elif _is_sha(val):
                    refs[name] = val
        for name, target in sym.items():
            if target in refs:
                refs[name] = refs[target]
        self.refs = refs
        self.refs_gen = generation
        tips = [s for n, s in refs.items() if n.startswith(("refs/heads/", "refs/remotes/"))]
        self.extend(tips)

    # ── naming ────────────────────────────────────────────────────────────
    def resolve(self, name):
        """A commit sha for a full sha or a branch/remote name, or None when only git can say."""
        if _is_sha(name):
            return name if (name in self.parents or self.extend([name])) else None
        if not name or name == "HEAD" or any(c in name for c in "^~:@{}*?[ \\") or ".." in name:
            return None
        for cand in (name, f"refs/{name}", f"refs/tags/{name}", f"refs/heads/{name}",
                     f"refs/remotes/{name}", f"refs/remotes/{name}/HEAD"):
            if cand in self.refs:
                if cand.startswith("refs/tags/"):
                    return None   # may be an annotated tag; peeling is git's job
                sha = self.refs[cand]
                return sha if (sha in self.parents or self.extend([sha])) else None
        return None

    # ── walks ─────────────────────────────────────────────────────────────
    def is_ancestor(self, a, b):
        if a == b:
            return True
        ga = self.gen[a]
        seen, heap = {b}, [(-self.gen[b], b)]
        while heap:
            g, c = heapq.heappop(heap)
            if c == a:
                return True
            for p in self.parents.get(c, ()):
                if p not in seen and self.gen.get(p, 0) >= ga:
                    seen.add(p)
                    heapq.heappush(heap, (-self.gen[p], p))
        return False

    def merge_bases(self, a, b):
        """Every best common ancestor of a and b (git's merge-base --all set, unordered)."""
        if a == b:
            return [a]
        flags = {a: 1, b: 2}
        heap = [(-self.gen[a], a), (-self.gen[b], b)]
        queued = {a, b}
        result = []
        live = 2   # queued commits not yet known to be below a found base
        while heap and live:
            _, c = heapq.heappop(heap)
            queued.discard(c)
            f = flags[c]
            if not f & 4:
                live -= 1
            if f & 3 == 3 and not f & 4:
                result.append(c)
                f |= 4
            for p in self.parents.get(c, ()):
                pf = flags.get(p, 0)
                nf = pf | (f & 7)
                if nf != pf:
                    flags[p] = nf
                    if p not in queued:
                        queued.add(p)
                        heapq.heappush(heap, (-self.gen[p], p))
                        if not nf & 4:
                            live += 1
                    elif nf & 4 and not pf & 4:
                        live -= 1
        if len(result) > 1:
            result = [r for r in result if not any(o != r and self.is_ancestor(r, o) for o in result)]
        return result

    def count_range(self, a, b):
        """rev-list --count a..b — commits reachable from b and not from a."""
        flags = {b: 1}
        flags[a] = flags.get(a, 0) | 2
        heap, queued = [], set()
        for c in {a, b}:
            heapq.heappush(heap, (-self.gen[c], c))
            queued.add(c)
        n = 0
        live = 1 if flags[b] == 1 else 0
        while heap and live:
            _, c = heapq.heappop(heap)
            queued.discard(c)
            f = flags[c]
            if f == 1:
                n += 1
                live -= 1
            for p in self.parents.get(c, ()):
                pf = flags.get(p, 0)
                nf = pf | (2 if f & 2 else 1)
                if nf != pf:
                    flags[p] = nf
                    if p not in queued:
                        queued.add(p)
                        heapq.heappush(heap, (-self.gen[p], p))
                        if nf == 1:
                            live += 1
                    elif nf & 2 and pf == 1:
                        live -= 1
        return n


def graph(gd, generation):
    """The loaded Graph for a git common dir, refs current as of <generation>."""
    with _LOCK:
        g = _GRAPHS.get(gd)
        if g is None:
            g = _GRAPHS[gd] = Graph(gd)
    with g.lock:
        g.load_refs(generation)
    return g
