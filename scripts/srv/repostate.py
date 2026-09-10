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
import os
import threading
import time

from . import ctx

_LOCK = threading.Lock()
_SNAP = {}   # repo cwd -> RepoState
_MAX_AGE = 2.0   # seconds a snapshot may serve without re-checking its fingerprint (the pulse reads it ~1/s)


class RepoState:
    def __init__(self, refs_raw, cfg_raw, pr_heads):
        self.fingerprint = hashlib.sha1((refs_raw + "\x1e" + cfg_raw).encode()).hexdigest()
        self.at = time.monotonic()
        self.checked = self.at
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
        self.pr_heads = pr_heads
        self._memo = {}

    # ── config ────────────────────────────────────────────────────────────
    def get(self, key, default=""):
        vals = self.cfg.get(key)
        return vals[-1] if vals else default

    def get_all(self, key):
        return list(self.cfg.get(key, []))

    def branch_key(self, branch, key, default=""):
        """branch.<b>.stack-<key> — the TARGET namespace, so git GCs it when the branch is
        deleted and carries it on rename — falling back to the pre-migration stack-branch.<b>.<key>
        spelling. The target wins, matching every other reader in the tree: during the keystone
        sweep a key exists in both, and a reader that preferred the old copy would answer with
        the value the sweep just superseded. This is the ONE place both are read; the migration
        ends by deleting the fallback arm here."""
        return self.get(f"branch.{branch}.stack-{key}") or self.get(f"stack-branch.{branch}.{key}") or default

    def branch_key_all(self, branch, key):
        """The multivar form of branch_key: the target namespace's values if it has any, else
        the pre-migration spelling's. Never concatenated — a half-swept key would double
        every requires edge."""
        return (self.get_all(f"branch.{branch}.stack-{key}")
                or self.get_all(f"stack-branch.{branch}.{key}"))

    def branch_keys(self, key):
        """{branch: value} for one suffix across every branch, both namespaces, target winning.
        Branch names contain dots (viewer/map-shows-gates, wt-1.2), so affixes are stripped —
        never split on "." — which is also why this lives here instead of in each enumerator."""
        out = {}
        old_pre, old_suf = "stack-branch.", f".{key}"
        new_pre, new_suf = "branch.", f".stack-{key}"
        for k in self.cfg:
            if k.startswith(old_pre) and k.endswith(old_suf):
                out.setdefault(k[len(old_pre):-len(old_suf)], self.get(k))
        for k in self.cfg:   # second pass: the target namespace overwrites
            if k.startswith(new_pre) and k.endswith(new_suf):
                out[k[len(new_pre):-len(new_suf)]] = self.get(k)
        return {b: v for b, v in out.items() if v}

    def parent(self, branch):
        return self.branch_key(branch, "parent") or self.main()

    def project(self, branch):
        return self.branch_key(branch, "project")

    def description(self, branch):
        return self.get(f"branch.{branch}.description")

    def main(self):
        return self.get("stack.main-branch") or "main"

    # ── refs ──────────────────────────────────────────────────────────────
    def local(self, branch):
        return self.sha.get(f"refs/heads/{branch}", "")

    def remote(self, branch, remote="origin"):
        return self.sha.get(f"refs/remotes/{remote}/{branch}", "")

    def exists(self, branch):
        return f"refs/heads/{branch}" in self.sha

    def track(self, branch):
        return self.upstream.get(branch, ("", ""))

    def published(self, branch):
        return branch in self.pr_heads

    def branch_fingerprint(self, branch):
        """Everything a single-branch verdict reads: its refs (every remote's copy), its parent's,
        origin/main, its config block, and open-PR membership. Cheap — no spawn."""
        sp = self.parent(branch)
        parts = [self.local(branch), self.remote(branch), self.local(sp), self.remote(sp), self.remote(self.main()),
                 self.track(branch)[1], str(self.published(branch))]
        parts += [f"{k}={v}" for k, vs in sorted(self.cfg.items()) if k.startswith((f"stack-branch.{branch}.", f"branch.{branch}."))
                  for v in vs]
        parts += [self.sha.get(r, "") for r in sorted(self.sha) if r.startswith("refs/remotes/") and r.endswith(f"/{branch}")]
        return hashlib.sha1("\x1f".join(parts).encode()).hexdigest()

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
        key = ("tree", rev)
        if key not in self._memo:
            self._memo[key] = ctx.run(["git", "rev-parse", f"{rev}^{{tree}}"]).stdout.strip()
        return self._memo[key]

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
    # the blessing ledgers live beside the config and change on every bless — they're part of
    # what the model view depends on, so their mtimes ride in the fingerprint
    gd = ctx.run(["git", "rev-parse", "--path-format=absolute", "--git-common-dir"]).stdout.strip()
    for name in ("stack-blessed.json", "stack-blessed-contrib.json"):
        try:
            cfg += f"\0#mtime:{name}={os.path.getmtime(os.path.join(gd, name))}"
        except OSError:
            pass
    return refs, cfg


def snapshot(fresh_prs=False):
    """The current RepoState for the request's repo. Re-reads the two inputs at most every
    _MAX_AGE seconds; a changed fingerprint rebuilds, an unchanged one keeps the memoised
    walks. Mutating callers pass fresh_prs=True so the open-PR set is live, never stale."""
    from . import sync
    repo = ctx.repo_cwd()
    now = time.monotonic()
    with _LOCK:
        cur = _SNAP.get(repo)
    if cur and not fresh_prs and now - cur.checked < _MAX_AGE:
        return cur
    refs, cfg = _read()
    heads = sync._open_pr_heads(fresh=fresh_prs)
    fp = hashlib.sha1((refs + "\x1e" + cfg).encode()).hexdigest()
    with _LOCK:
        cur = _SNAP.get(repo)
        if cur and cur.fingerprint == fp and cur.pr_heads == heads:
            cur.checked = now
            return cur
        snap = RepoState(refs, cfg, heads)
        _SNAP[repo] = snap
        return snap


def invalidate():
    """A mutation this server made (reword, squash, restack, config write) — drop the snapshot
    so the next reader rebuilds instead of riding out _MAX_AGE."""
    with _LOCK:
        _SNAP.pop(ctx.repo_cwd(), None)
