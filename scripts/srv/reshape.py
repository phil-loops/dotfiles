"""The verbs an agent reshapes a forest with (tooling-doctor B5), in place of raw git: each is one
motion that keeps refs and config consistent, and the `stack-reshape` CLI runs it under the
forest's lock (P2), so canopy's background restack and a click in canopy never interleave with it.

  new        create a branch with its purpose, parent, project and registry entry in one motion
  reparent   move an UNPUBLISHED branch onto another parent; its descendants follow (catchup.carry)
  contract   drop a branch whose diff is empty or merged; children re-point to its parent
  rename     rename an UNPUBLISHED branch; the registry and every edge naming it follow
  catch-up   catch the chain down to a branch up to its moved ancestors (catchup.catch_up)

History follows CLAUDE.md *History*: a published branch is never rewritten here — reparent and
rename refuse it (both would orphan or force its PR; that's Phil's call), and catch-up moves it by
a catch-up merge. Nothing here pushes. Every ref moves by compare-and-swap from the tip it read,
and every rebase is guarded (rebaseguard) in a throwaway detached checkout of its own, so a
conflict leaves nothing half-done and a death leaves nothing stranded."""
import contextlib
import os
import re
import tempfile

from . import catchup, ctx, rebaseguard, sync, workjournal

TRUNKS = catchup.TRUNKS


class Refused(Exception):
    """The verb won't do it; str() says why and what to do instead."""


def _git(*a):
    return ctx.run(["git", *a])


def _ok(*a):
    r = _git(*a)
    if r.returncode != 0:
        raise Refused((r.stderr or r.stdout or f"git {a[0]} failed").strip()[:300])
    return r.stdout.strip()


def _sha(ref):
    return catchup._sha(ref)


def _cfg(key):
    return _git("config", key).stdout.strip()


def _base(parent):
    """The ref a parent stands for: trunk is origin/main, a branch is itself."""
    return "origin/main" if parent in TRUNKS else parent


def published(b):
    return bool(_sha(f"refs/remotes/origin/{b}"))


def _exists(b):
    return bool(_sha(f"refs/heads/{b}"))


def _need(b):
    if not _exists(b):
        raise Refused(f"no branch {b}")


def project_of(b):
    return _cfg(f"branch.{b}.stack-project")


def _edges_naming(b):
    """[(key, value)] of every requires/after edge whose value is `b`."""
    out = _git("config", "--get-regexp", r"^branch\..*\.stack-(requires|after)$").stdout
    return [(k, v) for k, _, v in (ln.partition(" ") for ln in out.splitlines()) if v.strip() == b]


def _unset_value(key, value):
    _git("config", "--unset", key, f"^{re.escape(value)}$")


@contextlib.contextmanager
def scratch():
    """A throwaway detached checkout of our own — never the server's (.loops-sync-wt), which
    another forest's operation may be using under ITS lock."""
    path = tempfile.mkdtemp(prefix="stack-reshape-")
    _ok("worktree", "add", "--detach", path, "HEAD")
    try:
        yield path
    finally:
        _git("worktree", "remove", "--force", path)


def new(branch, parent, project, description):
    if _exists(branch):
        raise Refused(f"{branch} already exists")
    if not description.strip():
        raise Refused("a branch is born with its one-line purpose — pass --description")
    if not project:
        raise Refused("a forest member names its project — pass --project")
    base = _base(parent)
    if not _sha(base):
        raise Refused(f"no {base} to start {branch} from")
    work = _mint_work(branch, project, description.strip())
    _ok("branch", "--no-track", branch, base)
    _ok("config", f"branch.{branch}.stack-work", work)
    _ok("config", f"branch.{branch}.description", description.strip())
    _ok("config", f"branch.{branch}.stack-parent", "main" if parent in TRUNKS else parent)
    _ok("config", f"branch.{branch}.stack-project", project)
    _ok("config", "--add", f"stack-project.{project}.branch", branch)
    return {"ok": True, "branch": branch, "parent": parent or "main", "sha": _sha(f"refs/heads/{branch}")[:10], "work": work,
            "bound": _bind_creator(work)}


def _mint_work(branch, project, title):
    """The branch's work identity, made before the branch so a journal that can't write leaves no
    branch behind; a work whose branch never lands is inert."""
    j = workjournal.Journal()
    try:
        return j.mint_branch_work(ctx.repo_name(), branch, project=project, title=title)
    finally:
        j.close()


def work_of(branch):
    """The branch's work identity, made now for a branch born before it had one."""
    _need(branch)
    work = _git("config", f"branch.{branch}.stack-work").stdout.strip()
    if not work:
        work = _mint_work(branch, project_of(branch), _git("config", f"branch.{branch}.description").stdout.strip() or None)
        _ok("config", f"branch.{branch}.stack-work", work)
    return work


def _bind_creator(work):
    """Adds the new branch's work to the binding of the chat that made it (round 27, P4); a branch
    made from canopy or a script has no chat, and says so."""
    session = os.environ.get("CLAUDE_CODE_SESSION_ID", "")
    if not session:
        return None
    j = workjournal.Journal()
    try:
        j.bind_session(session, [work], by="stack-reshape new")
        return session
    except workjournal.JournalError as e:
        return f"not bound: {e}"
    finally:
        j.close()


def _relabel_work(branch):
    work = _git("config", f"branch.{branch}.stack-work").stdout.strip()
    if not work:
        return None
    j = workjournal.Journal()
    try:
        j.relink(work, branch=branch)
        return work
    except workjournal.JournalError as e:
        return f"label not moved: {e}"
    finally:
        j.close()


def reparent(branch, new_parent, description=""):
    _need(branch)
    if new_parent == branch:
        raise Refused("a branch can't be its own parent")
    if published(branch):
        raise Refused(f"{branch} is published — moving it onto {new_parent} rewrites its PR's history "
                      f"(a force push); that's Phil's call")
    old_parent = catchup.parent(branch) or "main"
    nb = _sha(_base(new_parent))
    if not nb:
        raise Refused(f"no {_base(new_parent)}")
    if new_parent not in TRUNKS and branch in catchup.chain(new_parent):
        raise Refused(f"{new_parent} sits under {branch} — that would make a cycle")
    tip = _sha(f"refs/heads/{branch}")
    ob = _sha(_base(old_parent))
    cut = _git("merge-base", tip, ob).stdout.strip() if ob else ""
    if not cut:
        raise Refused(f"couldn't find where {branch} leaves {old_parent}")
    with scratch() as wt:
        _ok("-C", wt, "checkout", "-q", "--detach", tip)
        r = rebaseguard.run(wt, ["--onto", nb, cut])
        if r.returncode != 0:
            raise Refused(f"{branch} conflicts with {new_parent} — resolve it by hand (nothing was moved)")
        moved = _git("-C", wt, "rev-parse", "HEAD").stdout.strip()
        _git("-C", wt, "checkout", "-q", "--detach")
        err = catchup._move(branch, tip, moved)
        if err:
            raise Refused(err)
        _ok("config", f"branch.{branch}.stack-parent", "main" if new_parent in TRUNKS else new_parent)
        if description.strip():
            _ok("config", f"branch.{branch}.description", description.strip())
        carried = catchup.carry(branch, None, wt)
    out = {"ok": True, "branch": branch, "from": old_parent, "to": new_parent, "carried": carried}
    if not description.strip():
        out["note"] = f"refresh {branch}'s description if it named {old_parent}"
    return out


def _in_main(branch):
    """origin/main already carries the branch's content: merging it in changes nothing — what a
    squash-merge leaves, where no single commit of the branch is an ancestor of main."""
    mtree = _sha("origin/main^{tree}")
    r = _git("merge-tree", "--write-tree", "origin/main", branch)
    return r.returncode == 0 and r.stdout.split("\n", 1)[0].strip() == mtree


def _merged_on_github(branch):
    """GitHub merged this branch's PR at exactly its local tip: the ground truth for a squash
    merge, which a content check misses once main moves past it (cite-what-ses-saw, 2026-11-18)."""
    pr = sync._pr_state_map().get(branch) or {}
    return pr.get("state") == "MERGED" and pr.get("head") == _sha(branch)


def contract(branch):
    _need(branch)
    parent = catchup.parent(branch) or "main"
    base = _base(parent)
    empty = _git("diff", "--quiet", f"{base}...{branch}").returncode == 0
    merged = bool(_sha("origin/main")) and (
        _git("merge-base", "--is-ancestor", branch, "origin/main").returncode == 0
        or _in_main(branch)) or _merged_on_github(branch)
    if not (empty or merged):
        raise Refused(f"{branch} still carries changes {parent} lacks — not empty, not merged; nothing to contract")
    holder = sync._worktree_of(branch)
    if holder:
        raise Refused(f"{branch} is checked out in {holder} — move that checkout off it first")
    kids = catchup.children(branch)
    for c in kids:
        _ok("config", f"branch.{c}.stack-parent", "main" if parent in TRUNKS else parent)
    for key, _ in _edges_naming(branch):
        _unset_value(key, branch)
    proj = project_of(branch)
    if proj:
        _unset_value(f"stack-project.{proj}.branch", branch)
    _ok("branch", "-D", branch)   # git drops branch.<b>.* with it
    return {"ok": True, "contracted": branch, "why": "empty" if empty else "merged",
            "children": kids, "parent": parent}


def rename(old, new_name):
    _need(old)
    if _exists(new_name):
        raise Refused(f"{new_name} already exists")
    if published(old):
        raise Refused(f"{old} is published — its PR's head is that name on origin, and renaming "
                      f"would orphan the PR; that's Phil's call")
    kids = catchup.children(old)
    edges = _edges_naming(old)
    _ok("branch", "-m", old, new_name)   # git carries branch.<old>.* to branch.<new>.*
    proj = project_of(new_name)
    if proj:
        _unset_value(f"stack-project.{proj}.branch", old)
        _ok("config", "--add", f"stack-project.{proj}.branch", new_name)
    for c in kids:
        _ok("config", f"branch.{c}.stack-parent", new_name)
    for key, _ in edges:
        key = key.replace(f"branch.{old}.", f"branch.{new_name}.", 1) if key.startswith(f"branch.{old}.") else key
        _unset_value(key, old)
        _ok("config", "--add", key, new_name)
    return {"ok": True, "from": old, "to": new_name, "children": kids, "work": _relabel_work(new_name)}


def catch_up(branch):
    _need(branch)
    with scratch() as wt:
        res = catchup.catch_up(branch, wt)
    if not res.get("ok"):
        raise Refused(res.get("err") or "the catch-up stopped")
    return res
