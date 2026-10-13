# srv/fastgit.py — the one place a read-only git question is answered without a spawn.
#
# ctx.run is wrapped here at init, so call sites keep issuing `git …` argv and never learn this
# exists. A recognised question is answered from, in order:
#   1. the in-memory commit graph and ref map (srv/gitgraph): merge-base, --is-ancestor,
#      rev-list --count A..B, rev-parse of a name, a commit's parents — exact, or it declines;
#   2. the worktree admin files, for `worktree list --porcelain`;
#   3. a memo of git's own output. Every revision name is first pinned to the sha it names now
#      and git runs on the shas, so the command reads only immutable objects and its output is
#      kept for good — a ref moving elsewhere in the repo (other sessions do, all day) costs it
#      nothing. A read-only command that can't be pinned is keyed on the stat watcher's
#      generation instead, so a hit is what git would print right now.
# Anything else — working-tree reads, writes, stdin, relative dates — goes to git untouched,
# and pokes the watcher so whatever it wrote is seen by the next read.
import os
import re
import subprocess
import threading
from collections import OrderedDict

from . import ctx, gitgraph, watch

STATS = {"graph": 0, "worktrees": 0, "memo_hit": 0, "memo_miss": 0, "spawn": 0}
_LOCK = threading.Lock()
_MEMO = OrderedDict()   # key -> (stdout, returncode)
_CAP = 20000
_SHA_EXPR = re.compile(r"^\^?[0-9a-f]{40}(\^\{(tree|commit)\}|\^[0-9]?|~[0-9]*)*"
                       r"(\.\.\.?\^?[0-9a-f]{40}(\^\{(tree|commit)\}|\^[0-9]?|~[0-9]*)*)?(:.*)?$")
_TIME_DEPENDENT = re.compile(r"%[ac]r|relative|ago|^--(since|until|after|before|max-age|min-age)")
_READ_ONLY = {"rev-parse", "merge-base", "rev-list", "log", "show", "cherry", "for-each-ref",
              "name-rev", "ls-tree", "cat-file", "diff-tree", "config", "diff", "remote",
              "symbolic-ref", "branch"}
_CONFIG_WRITES = {"--add", "--unset", "--unset-all", "--replace-all", "--rename-section",
                  "--remove-section", "--edit", "-e"}
_STABLE_SECTIONS = ("core", "diff", "log", "format", "pretty", "color", "i18n", "grep", "merge")


_NEST = threading.local()


def wrap(run):
    def fast_run(args, timeout=None):
        is_git = bool(args) and args[0] == "git"
        if is_git and not getattr(_NEST, "on", False):
            _NEST.on = True   # the watcher and graph spawn through ctx.run too — never recurse
            try:
                hit = answer(args[1:])
            finally:
                _NEST.on = False
            if hit is not None:
                return hit
        r = run(args, timeout=timeout)
        if not (is_git and _cacheable(args[1:])):
            watch.poke()   # it may have written: the next generation() re-walks instead of reusing
        return r
    return fast_run


def _done(args, out, rc=0, err=""):
    return subprocess.CompletedProcess(["git", *args], rc, out, err)


def answer(args):
    """A CompletedProcess for a git argv this module can answer exactly, else None."""
    if not args or args[0] == "-C" or args[0].startswith("-c"):
        return None   # another directory or an override — keep it git's
    try:
        r = _graph_answer(args)
        if r is not None:
            STATS["graph"] += 1
            return r
        if args[:3] == ["worktree", "list", "--porcelain"] and len(args) == 3:
            out = worktree_porcelain()
            if out is not None:
                STATS["worktrees"] += 1
                return _done(args, out)
        return _memo_answer(args)
    except Exception as e:   # never let a shortcut fail a request — git still knows the answer
        ctx.log(f"fastgit: fell back to git for {' '.join(args)}: {e!r}")
        return None


def _gd():
    # the request repo's common dir without a ctx.run, seeded into the watcher's own map so its
    # common_dir() never has to ask either
    cwd = ctx.repo_cwd()
    gd = watch._GD.get(cwd)
    if gd is None:
        gd = subprocess.run(["git", "rev-parse", "--path-format=absolute", "--git-common-dir"],
                            cwd=cwd, capture_output=True, text=True).stdout.strip()
        if gd:
            watch._GD[cwd] = gd
    return gd


# ── 1. the graph ──────────────────────────────────────────────────────────
def _graph():
    gd = _gd()
    return gitgraph.graph(gd, watch.generation()) if gd else None


def _graph_answer(args):
    sub = args[0]
    if sub == "merge-base":
        if len(args) == 4 and args[1] == "--is-ancestor":
            g = _graph()
            a, b = g.resolve(args[2]), g.resolve(args[3])
            if a and b:
                return _done(args, "", 0 if g.is_ancestor(a, b) else 1)
        elif len(args) == 3 and not args[1].startswith("-") and not args[2].startswith("-"):
            g = _graph()
            a, b = g.resolve(args[1]), g.resolve(args[2])
            if a and b:
                bases = g.merge_bases(a, b)
                if len(bases) == 1:
                    return _done(args, bases[0] + "\n")
                if not bases:
                    return _done(args, "", 1)
    elif sub == "rev-list" and len(args) == 3 and args[1] == "--count":
        rng = args[2]
        if ".." in rng and "..." not in rng:
            left, right = rng.split("..", 1)
            g = _graph()
            a, b = g.resolve(left or "HEAD"), g.resolve(right or "HEAD")
            if a and b:
                return _done(args, f"{g.count_range(a, b)}\n")
    elif sub == "rev-parse" and 2 <= len(args) <= 4:
        flags, names = args[1:-1], args[-1]
        if set(flags) <= {"--verify", "-q", "--quiet"} and not names.startswith("-"):
            name = names[:-len("^{commit}")] if names.endswith("^{commit}") else names
            g = _graph()
            sha = g.resolve(name)
            if sha:
                return _done(args, sha + "\n")
            quiet = "--verify" in flags and ({"-q", "--quiet"} & set(flags))
            if quiet and name.startswith("refs/") and gitgraph.plain_refname(name):
                return _done(args, "", 1)   # a full refname the ref map doesn't hold doesn't exist
    elif sub == "log" and len(args) == 4 and args[1] == "-1" and args[2] == "--format=%P":
        g = _graph()
        sha = g.resolve(args[3])
        if sha and sha in g.parents:
            return _done(args, " ".join(g.parents[sha]) + "\n")
    return None


# ── 2. worktrees from their admin files ───────────────────────────────────
def _read(path):
    try:
        with open(path) as fh:
            return fh.read().strip()
    except OSError:
        return None


_FOLD = {}


def _ignorecase(gd):
    if gd not in _FOLD:
        _FOLD[gd] = subprocess.run(["git", "--git-dir", gd, "config", "--bool", "core.ignorecase"],
                                   capture_output=True, text=True).stdout.strip() == "true"
    return _FOLD[gd]


def worktree_porcelain():
    """`git worktree list --porcelain`, byte for byte, from the files git itself reads — or None
    for any state (bare repo, unborn branch, symref HEAD into another ref) that is git's to say."""
    gd = _gd()
    if not gd or os.path.basename(gd) != ".git":
        return None
    g = _graph()
    recs = []

    def rec(path, admin, locked_file, prunable):
        head = _read(os.path.join(admin, "HEAD"))
        if head is None:
            return False
        lines = [f"worktree {path}"]
        if head.startswith("ref: "):
            ref = head[5:]
            sha = g.refs.get(ref)
            if not sha or not ref.startswith("refs/heads/"):
                return False
            lines += [f"HEAD {sha}", f"branch {ref}"]
        elif gitgraph._is_sha(head):
            lines += [f"HEAD {head}", "detached"]
        else:
            return False
        if locked_file is not None:
            reason = _read(locked_file)
            if reason is not None:
                lines.append(f"locked {reason}" if reason else "locked")
        if prunable:
            lines.append(f"prunable {prunable}")
        recs.append("\n".join(lines) + "\n")
        return True

    if not rec(os.path.dirname(gd), gd, None, None):
        return None
    wts = os.path.join(gd, "worktrees")
    try:
        names = os.listdir(wts)
    except OSError:
        names = []
    linked = []
    for n in names:
        admin = os.path.join(wts, n)
        pointer = _read(os.path.join(admin, "gitdir"))
        if pointer is None:
            return None
        linked.append((os.path.dirname(pointer), admin, pointer))
    # git lists linked worktrees in path order, compared the way the filesystem does
    fold = _ignorecase(gd)
    linked.sort(key=lambda t: t[0].lower() if fold else t[0])
    for path, admin, pointer in linked:
        prunable = None if os.path.exists(pointer) else "gitdir file points to non-existent location"
        if not rec(path, admin, os.path.join(admin, "locked"), prunable):
            return None
    return "\n".join(recs) + "\n"


# ── 3. memo of git's own output ───────────────────────────────────────────
def _positionals(args):
    out = []
    for a in args[1:]:
        if a == "--":
            break
        if not a.startswith("-"):
            out.append(a)
    return out


def _cacheable(args):
    sub = args[0]
    if sub not in _READ_ONLY or any(_TIME_DEPENDENT.search(a) for a in args):
        return False
    if sub == "config":
        return not any(a in _CONFIG_WRITES for a in args) and (
            any(a in ("--get", "--get-all", "--get-regexp", "--list", "-l") for a in args)
            or len(_positionals(args)) == 1)
    if sub == "diff":
        pos = _positionals(args)
        if any(a in ("--cached", "--staged", "--no-index") for a in args):
            return False
        if not (len(pos) >= 2 or any(".." in p for p in pos)):
            return False   # one revision diffs against the working tree
        return "--" in args or all(_revish(p) for p in pos)   # `diff <rev> <path>` is a worktree read
    if sub == "remote":
        return args[1:2] in (["get-url"], ["-v"], [])
    if sub == "symbolic-ref":
        return len(_positionals(args)) == 1
    if sub == "branch":
        return args[1:] == ["--show-current"]
    if sub == "cat-file":
        return not any(a.startswith("--batch") for a in args)
    return True


def _revish(p):
    if ".." in p or _SHA_EXPR.match(p):
        return True
    g = _graph()
    return g is not None and g.resolve(re.split(r"[~^]", p, 1)[0]) is not None


_STABLE = {}   # gd -> (config mtime, global mtime, digest)


def _stable_config(gd):
    # the config that shapes output (diff/log/core/…), so a forever-key still busts on a change
    # to it — but not on the branch/stack keys every session writes all day
    paths = (os.path.join(gd, "config"), os.path.expanduser("~/.gitconfig"),
             os.path.expanduser("~/.config/git/config"))
    stamp = tuple(os.stat(p).st_mtime_ns if os.path.exists(p) else 0 for p in paths)
    hit = _STABLE.get(gd)
    if hit and hit[0] == stamp:
        return hit[1]
    keep, take = [], False
    for p in paths:
        try:
            with open(p) as fh:
                for ln in fh:
                    s = ln.strip()
                    if s.startswith("["):
                        section = re.split(r"[\s\]\".]", s[1:], 1)[0].lower()
                        take = section in _STABLE_SECTIONS or section.startswith("include")
                    if take:
                        keep.append(s)
        except OSError:
            pass
    digest = hash(tuple(keep))
    _STABLE[gd] = (stamp, digest)
    return digest


_PINNABLE = {"diff", "log", "show", "rev-list", "merge-base", "cat-file", "ls-tree", "diff-tree",
             "rev-parse"}
_NAMES_IN_OUTPUT = re.compile(r"%[dDS]|--decorate|--source|--abbrev-ref|--symbolic|^--(all|branches|"
                              r"remotes|tags|glob|exclude|reflog|walk-reflogs|stdin|bisect|fork-point)")
_REV_TOKEN = re.compile(r"^(\^?)([^\^~:]+)((?:\^\{(?:tree|commit)\}|\^[0-9]?|~[0-9]*)*)(:.*)?$")


def _pin(args):
    """args with every revision name replaced by the sha it names right now — the command then
    reads only immutable objects, and neither its output nor its key depends on a ref moving.
    None when a name isn't certain (HEAD, a tag, an expression) or names reach the output."""
    if args[0] not in _PINNABLE or any(_NAMES_IN_OUTPUT.search(a) for a in args):
        return None
    if args[0] == "rev-parse" and any(a.startswith("-") and a not in ("--verify", "-q", "--quiet")
                                      for a in args[1:]):
        return None
    g = _graph()
    out, seen_dashdash, pinned = [args[0]], False, False
    for a in args[1:]:
        if seen_dashdash or a.startswith("-"):
            seen_dashdash = seen_dashdash or a == "--"
            out.append(a)
            continue
        sides = re.split(r"(\.\.\.?)", a)
        rebuilt = []
        for part in sides:
            if part in ("..", "..."):
                rebuilt.append(part)
                continue
            m = _REV_TOKEN.match(part)
            if not m:
                return None
            sha = m.group(2) if gitgraph._is_sha(m.group(2)) else g.resolve(m.group(2))
            if not sha:
                return None
            rebuilt.append(m.group(1) + sha + m.group(3) + (m.group(4) or ""))
            pinned = True
        out.append("".join(rebuilt))
    return out if pinned else None


def _memo_answer(args):
    if not _cacheable(args):
        return None
    gd = _gd()
    if not gd:
        return None
    cwd = ctx.repo_cwd()
    pinned = _pin(args)
    if pinned is not None:
        key = ("sha", gd, tuple(pinned), _stable_config(gd))
        hit = _lookup(key)
        if hit is not None:
            return _done(args, *hit)
        r = subprocess.run(["git", *pinned], cwd=cwd, capture_output=True, text=True)
        STATS["memo_miss"] += 1
        if r.returncode > 1 or r.stderr:
            return None   # a failure's message may quote the name we replaced — let git say it in full
        _store(key, r)
        return _done(args, r.stdout, r.returncode, r.stderr)
    key = ("gen", cwd, tuple(args), watch.generation(), _global_stamp())
    hit = _lookup(key)
    if hit is not None:
        return _done(args, *hit)
    gen_before = key[3]
    r = subprocess.run(["git", *args], cwd=cwd, capture_output=True, text=True)
    STATS["memo_miss"] += 1
    if watch.generation() == gen_before:   # else the repo moved under the spawn: answer, don't file it
        _store(key, r)
    return r


def _lookup(key):
    with _LOCK:
        hit = _MEMO.get(key)
        if hit is not None:
            _MEMO.move_to_end(key)
            STATS["memo_hit"] += 1
        return hit


def _store(key, r):
    with _LOCK:
        _MEMO[key] = (r.stdout, r.returncode, r.stderr)
        while len(_MEMO) > _CAP:
            _MEMO.popitem(last=False)


def _global_stamp():
    return tuple(os.stat(p).st_mtime_ns if os.path.exists(p) else 0
                 for p in (os.path.expanduser("~/.gitconfig"), os.path.expanduser("~/.config/git/config")))
