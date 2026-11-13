# srv/repostate.py — ONE snapshot of everything the read-only verdicts derive from: every ref
# (local + remote, with upstream tracking), the repo's local git config parsed once, and the
# cached open-PR set. Two git spawns build it; a fingerprint of those two outputs keys it, so
# every reader in the same request burst (nine panels on a node open) shares one snapshot
# instead of each re-spawning `git config` and `git rev-parse` for the same facts.
#
# Readers ask the snapshot, never git, for: a branch's parent/project/description/any
# stack-branch key (both namespaces resolved here, in one place), local + origin tips,
# upstream tracking, published. Anything that needs a *walk* (rev-list counts, merge-base)
# still spawns — but memoised per snapshot, so the same walk isn't repeated within one epoch.
import hashlib
import re
import threading
import time

from . import ctx, watch

_LOCK = threading.Lock()
_SNAP = {}   # repo cwd -> RepoState
# A snapshot serves as long as the stat watcher's generation hasn't moved; the spawned
# fingerprint re-check is only the safety net for a change the stat walk can't see.
_SAFETY_AGE = 30.0
# A commit's tree never changes, so this outlives every snapshot: (repo, commit sha) -> tree sha.
_TREE_OF = {}
_HEX40 = re.compile(r"^[0-9a-f]{40}$")


class RepoState:
    as_of = 0   # ctx.WRITES when its inputs were last read: every write up to this number is in it

    def __init__(self, refs_raw, cfg_raw):
        self.fingerprint = hashlib.sha1((refs_raw + "\x1e" + cfg_raw).encode()).hexdigest()
        self.at = time.monotonic()
        self.checked = self.at
        self.gen = None   # watch.generation() this snapshot was last verified against
        self.sha = {}        # refname -> objectname (refs/heads/x, refs/remotes/origin/x)
        self.upstream = {}   # short branch -> (upstream short, track e.g. "[gone]" / "[ahead 1]" / "")
        for ln in refs_raw.splitlines():
            p = ln.split(" ", 3)
            if len(p) >= 2:
                self.sha[p[0]] = p[1]
                if p[0].startswith("refs/heads/"):
                    self.upstream[p[0][11:]] = (p[2] if len(p) > 2 else "", p[3] if len(p) > 3 else "")
        self.cfg = {}        # key -> [values] (multivar keys keep every value, in order)
        for ln in cfg_raw.split("\0"):
            if not ln:
                continue
            k, _, v = ln.partition("\n")
            self.cfg.setdefault(k, []).append(v)
        # The open-PR set is LAZY and deliberately not part of the fingerprint: it comes from
        # gh, a cold read of it blocks, and /sig — the cheap change-detector the extension polls
        # every 2s — goes through this object's fingerprint. Eager loading made /sig take 6s on a
        # cold server. Refs and config identify a snapshot; PR membership is its own TTL'd cache
        # in sync, consulted on first use, and the pulse's world_sig already carries PR flips.
        self._pr_heads = None
        self._memo = {}

    # ── config ────────────────────────────────────────────────────────────
    def get(self, key, default=""):
        vals = self.cfg.get(key)
        return vals[-1] if vals else default

    def get_all(self, key):
        return list(self.cfg.get(key, []))

    def branch_key(self, branch, key, default=""):
        """branch.<b>.stack-<key> — git GCs it when the branch is deleted and carries it on
        rename. The pre-migration stack-branch.<b>.<key> spelling is no longer read: every repo
        was swept (stack-config-move --check clean, 2026-11-12) and every writer emits this one."""
        return self.get(f"branch.{branch}.stack-{key}") or default

    def branch_key_all(self, branch, key):
        """The multivar form of branch_key."""
        return self.get_all(f"branch.{branch}.stack-{key}")

    def branch_keys(self, key):
        """{branch: value} for one suffix across every branch. Branch names contain dots
        (viewer/map-shows-gates, wt-1.2), so affixes are stripped — never split on "." — which
        is also why this lives here instead of in each enumerator."""
        out = {}
        pre, suf = "branch.", f".stack-{key}"
        for k in self.cfg:
            if k.startswith(pre) and k.endswith(suf):
                out[k[len(pre):-len(suf)]] = self.get(k)
        return {b: v for b, v in out.items() if v}

    def parent(self, branch):
        return self.branch_key(branch, "parent") or self.main()

    def project(self, branch):
        return self.branch_key(branch, "project")

    def description(self, branch):
        return self.get(f"branch.{branch}.description")

    def main(self):
        return self.get("stack.main-branch") or "main"

    def trunk(self):
        """The trunk every range starts from: origin's copy when there is one, since a stale
        local main would count merged work as a branch's own."""
        main = self.main()
        return f"origin/{main}" if self.remote(main) else main

    def diff_base(self, branch):
        """Where a branch's own diff starts: its parent, with a trunk parent read as trunk()."""
        parent = self.parent(branch)
        return self.trunk() if parent == self.main() else parent

    # ── refs ──────────────────────────────────────────────────────────────
    def local(self, branch):
        return self.sha.get(f"refs/heads/{branch}", "")

    def remote(self, branch, remote="origin"):
        return self.sha.get(f"refs/remotes/{remote}/{branch}", "")

    def exists(self, branch):
        return f"refs/heads/{branch}" in self.sha

    def track(self, branch):
        return self.upstream.get(branch, ("", ""))

    def pr_heads(self, fresh=False):
        if self._pr_heads is None or fresh:
            from . import openprs
            self._pr_heads = openprs.heads(fresh=fresh)
        return self._pr_heads

    def published(self, branch):
        return branch in self.pr_heads()

    def branch_fingerprint(self, branch):
        """Everything a single-branch verdict reads: its refs (every remote's copy), its parent's,
        origin/main, its config block, and open-PR membership. Cheap — no spawn."""
        sp = self.parent(branch)
        parts = [self.local(branch), self.remote(branch), self.local(sp), self.remote(sp), self.remote(self.main()),
                 self.track(branch)[1], str(self.published(branch))]
        parts += [f"{k}={v}" for k, vs in sorted(self.cfg.items()) if k.startswith(f"branch.{branch}.") for v in vs]
        parts += [self.sha.get(r, "") for r in sorted(self.sha) if r.startswith("refs/remotes/") and r.endswith(f"/{branch}")]
        return hashlib.sha1("\x1f".join(parts).encode()).hexdigest()

    def ref_any(self, name):
        """Every tip <name> could resolve to — a local branch, a remote-tracking ref (bare or
        origin/-prefixed), or a full refname — for keys that must move when any of them does."""
        if not name:
            return ()
        return tuple(self.sha.get(r, "") for r in (f"refs/heads/{name}", f"refs/remotes/{name}",
                                                    f"refs/remotes/origin/{name}", name))

    def inputs_fingerprint(self, branches, *extra):
        """Key material for a payload derived from these branches' refs + config blocks, the
        and the trunk. No spawn."""
        main = self.main()
        parts = [main, self.ref_any(main), *extra]
        for b in branches:
            parts += [b, self.ref_any(b)]
            parts += [f"{k}={v}" for k, vs in sorted(self.cfg.items()) if k.startswith(f"branch.{b}.") for v in vs]
        return hashlib.sha1(repr(parts).encode()).hexdigest()

    def remote_tips(self, remote="origin"):
        """One hash over every refs/remotes/<remote>/* tip — for `--not --remotes=<remote>` walks."""
        pre = f"refs/remotes/{remote}/"
        return hashlib.sha1(repr(sorted((r, v) for r, v in self.sha.items() if r.startswith(pre))).encode()).hexdigest()

    # ── walks, memoised for the snapshot's life ──────────────────────────
    def count(self, rng, first_parent=False):
        key = ("count", rng, first_parent)
        if key not in self._memo:
            args = ["git", "rev-list", "--count"] + (["--first-parent"] if first_parent else []) + [rng]
            raw = ctx.run(args).stdout.strip()
            self._memo[key] = int(raw) if raw.isdigit() else 0
        return self._memo[key]

    def merge_base(self, a, b):
        key = ("mb", a, b)
        if key not in self._memo:
            self._memo[key] = ctx.run(["git", "merge-base", a, b]).stdout.strip()
        return self._memo[key]

    def tree(self, rev):
        """The tree of a local branch's tip or a commit sha. Branch tips are filled for every
        head in one spawn on the first miss and kept by commit, so a new snapshot (any config
        write) re-reads nothing."""
        sha = self.local(rev) or rev
        repo = ctx.repo_cwd()
        if (repo, sha) not in _TREE_OF and sha in self._head_shas():
            self._fill_head_trees(repo)
        if (repo, sha) in _TREE_OF:
            return _TREE_OF[(repo, sha)]
        key = ("tree", rev)
        if key not in self._memo:
            t = ctx.run(["git", "rev-parse", f"{rev}^{{tree}}"]).stdout.strip()
            if t and _HEX40.match(sha):
                _TREE_OF[(repo, sha)] = t
            self._memo[key] = t
        return self._memo[key]

    def head_trees(self):
        """{branch: tree sha} for every local head — one spawn at most, none once the tips are known."""
        repo = ctx.repo_cwd()
        heads = {r[11:]: s for r, s in self.sha.items() if r.startswith("refs/heads/")}
        if any((repo, s) not in _TREE_OF for s in heads.values()):
            self._fill_head_trees(repo)
        return {b: _TREE_OF[(repo, s)] for b, s in heads.items() if (repo, s) in _TREE_OF}

    def _head_shas(self):
        if "head-shas" not in self._memo:
            self._memo["head-shas"] = {s for r, s in self.sha.items() if r.startswith("refs/heads/")}
        return self._memo["head-shas"]

    def _fill_head_trees(self, repo):
        if self._memo.get("heads-filled"):
            return
        self._memo["heads-filled"] = True
        if len(_TREE_OF) > 50_000:
            _TREE_OF.clear()
        out = ctx.run(["git", "for-each-ref", "--format=%(objectname) %(tree)", "refs/heads"]).stdout
        for ln in out.splitlines():
            c, _, t = ln.partition(" ")
            if t:
                _TREE_OF[(repo, c)] = t

    def once(self, key, fn):
        """Memoise any per-snapshot computation (a diff, a script's JSON) under `key`."""
        if key not in self._memo:
            self._memo[key] = fn()
        return self._memo[key]

    def is_ancestor(self, a, b):
        key = ("anc", a, b)
        if key not in self._memo:
            self._memo[key] = ctx.run(["git", "merge-base", "--is-ancestor", a, b]).returncode == 0
        return self._memo[key]


def _read():
    refs = ctx.run(["git", "for-each-ref", "--format=%(refname) %(objectname) %(upstream:short) %(upstream:track)",
                    "refs/heads", "refs/remotes"]).stdout
    cfg = ctx.run(["git", "config", "--local", "--list", "-z"]).stdout
    return refs, cfg


def snapshot(fresh_prs=False):
    """The current RepoState for the request's repo. Served without a spawn while the stat
    watcher's generation is unchanged (and the snapshot is under _SAFETY_AGE); otherwise the
    two inputs are re-read — a changed fingerprint rebuilds, an unchanged one keeps the
    memoised walks. Mutating callers pass fresh_prs=True so the open-PR set is live."""
    repo = ctx.repo_cwd()
    gen = watch.generation(repo)
    now = time.monotonic()
    with _LOCK:
        cur = _SNAP.get(repo)
    if cur and cur.gen == gen and now - cur.checked < _SAFETY_AGE:
        if fresh_prs:
            cur.pr_heads(fresh=True)
        return cur
    as_of = ctx.WRITES[0]
    refs, cfg = _read()
    fp = hashlib.sha1((refs + "\x1e" + cfg).encode()).hexdigest()
    with _LOCK:
        cur = _SNAP.get(repo)
        if cur and cur.fingerprint == fp:
            cur.checked = now
            cur.as_of = max(cur.as_of, as_of)
            snap = cur
        else:
            snap = RepoState(refs, cfg)
            snap.as_of = as_of
            _SNAP[repo] = snap
        snap.gen = gen
    if fresh_prs:
        snap.pr_heads(fresh=True)
    return snap


def invalidate():
    """A mutation this server made (reword, squash, restack, config write) — drop the snapshot
    so the next reader rebuilds instead of waiting on the watcher's throttle."""
    watch.poke()
    with _LOCK:
        _SNAP.pop(ctx.repo_cwd(), None)
