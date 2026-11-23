#!/usr/bin/env python3
"""stack-reshape (srv/reshape.py, tooling-doctor B5): each verb keeps refs and forest config
consistent in one motion, never rewrites a published branch, and waits on the forest's lock.
Runs the real CLI in a temp repo; origin's refs are written with update-ref, nothing is pushed."""
import testenv  # noqa: F401,E402 — git here ignores the machine's config (testenv.py)
import json
import os
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
CLI = os.path.join(HERE, "stack-reshape")
env = {**os.environ, "GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@t", "GIT_COMMITTER_NAME": "t", "GIT_COMMITTER_EMAIL": "t@t"}
for k in ("GIT_DIR", "GIT_INDEX_FILE", "GIT_WORK_TREE", "STACK_FOREST_LOCKED", "CLAUDE_CODE_SESSION_ID"):
    env.pop(k, None)
failures = 0


def check(name, ok, detail=""):
    global failures
    print(("✓ " if ok else "✗ ") + name + ("" if ok else f" — {detail}"))
    failures += 0 if ok else 1


repo = os.path.join(tempfile.mkdtemp(prefix="reshape-"), "r")
env["CANOPY_WORK_JOURNAL"] = os.path.join(os.path.dirname(repo), "journal.sqlite3")
sys.path.insert(0, HERE)
from srv import workjournal  # noqa: E402


def work_of(work_id):
    j = workjournal.Journal(env["CANOPY_WORK_JOURNAL"])
    try:
        return j.work(work_id) or {}
    finally:
        j.close()
subprocess.run(["git", "init", "-q", "-b", "main", repo], check=True, env=env)


def git(*a, ok=True):
    return subprocess.run(["git", "-C", repo, *a], capture_output=True, text=True, env=env, check=ok).stdout.strip()


def cfg(key):
    return subprocess.run(["git", "-C", repo, "config", "--get-all", key], capture_output=True, text=True, env=env).stdout.split()


def commit(path, text, msg):
    with open(os.path.join(repo, path), "w") as f:
        f.write(text)
    git("add", path)
    git("commit", "-q", "-m", msg)


def reshape(*a):
    r = subprocess.run([CLI, *a], cwd=repo, capture_output=True, text=True, env=env)
    try:
        body = json.loads(r.stdout.strip().splitlines()[-1]) if r.stdout.strip() else {}
    except ValueError:
        body = {"raw": r.stdout}
    return r.returncode, body, r.stderr


def anc(a, b):
    return subprocess.run(["git", "-C", repo, "merge-base", "--is-ancestor", a, b], env=env).returncode == 0


commit("base.txt", "base\n", "root")
git("update-ref", "refs/remotes/origin/main", "main")

# new: the branch and all its config in one motion
rc, out, err = reshape("new", "a", "--parent", "main", "--project", "f", "--description", "add a")
check("new: created", rc == 0 and git("rev-parse", "a") == git("rev-parse", "origin/main"), (rc, out, err))
check("new: purpose, parent, project and registry set",
      cfg("branch.a.description") == ["add", "a"] and cfg("branch.a.stack-parent") == ["main"]
      and cfg("branch.a.stack-project") == ["f"] and cfg("stack-project.f.branch") == ["a"])
work_a = (cfg("branch.a.stack-work") or [""])[0]
check("new: the branch carries its own work identity", work_a.startswith("w_") and out.get("work") == work_a
      and work_of(work_a).get("branch") == "a" and work_of(work_a).get("todo_id") is None, (out, work_a))
check("new: a branch made outside a chat binds nothing", out.get("bound") is None, out)
SID = "feedface-0000-4000-8000-000000000002"
env["CLAUDE_CODE_SESSION_ID"] = SID
rc, out, err = reshape("new", "made-by-chat", "--parent", "main", "--project", "f", "--description", "add a chat's branch")
del env["CLAUDE_CODE_SESSION_ID"]
jj = workjournal.Journal(env["CANOPY_WORK_JOURNAL"])
check("new: the chat that made the branch is bound to its work", rc == 0 and out.get("bound") == SID
      and jj.bound_works("claude-code", SID) == cfg("branch.made-by-chat.stack-work"), (rc, out, err))
jj.close()
work_chat = cfg("branch.made-by-chat.stack-work")[0]
rc, out, err = reshape("contract", "made-by-chat")
jj = workjournal.Journal(env["CANOPY_WORK_JOURNAL"])
check("contract: the branch's work is retired with it", rc == 0 and out.get("work") == work_chat
      and bool(jj.work(work_chat)["retired_at"]), (rc, out, err))
check("contract: the chat that was bound to it no longer lists it", jj.bound_works("claude-code", SID) == [],
      jj.bound_works("claude-code", SID))
check("contract: …and can still take work and capture a message",
      jj.bind_session(SID, [work_a], by="t") > 0 and jj.bound_works("claude-code", SID) == [work_a]
      and jj.capture(source="claude-code", conversation=SID, source_message_id="after-contract", text="go on")["works"].keys() == {work_a})
jj.close()
rc, out, _ = reshape("new", "x", "--parent", "main", "--project", "f")
check("new: refused without a purpose", rc == 1 and "description" in out.get("err", ""), out)

git("checkout", "-q", "a"); commit("a.txt", "a\n", "a1")
reshape("new", "b", "--parent", "a", "--project", "f", "--description", "add b")
git("checkout", "-q", "b"); commit("b.txt", "b\n", "b1")
reshape("new", "c", "--parent", "b", "--project", "f", "--description", "add c")
git("checkout", "-q", "c"); commit("c.txt", "c\n", "c1")
git("checkout", "-q", "main")
git("config", "--add", "branch.c.stack-after", "b")

# reparent: b doesn't need a — onto main; c follows
rc, out, err = reshape("reparent", "b", "main", "--description", "add b on its own")
check("reparent: moved", rc == 0 and anc("origin/main", "b") and not anc("a", "b"), (rc, out, err))
check("reparent: b keeps only its own commit", git("rev-list", "--count", "origin/main..b") == "1")
check("reparent: parent + description updated", cfg("branch.b.stack-parent") == ["main"] and cfg("branch.b.description")[-1] == "own")
check("reparent: the child followed", anc("b", "c") and not anc("a", "c") and out.get("carried", [{}])[0].get("branch") == "c", out)

# reparent refuses a published branch
git("update-ref", "refs/remotes/origin/a", "a")
rc, out, _ = reshape("reparent", "a", "b")
check("reparent: a published branch is Phil's call", rc == 1 and "published" in out.get("err", ""), out)
rc, out, _ = reshape("reparent", "b", "c")
check("reparent: a cycle is refused", rc == 1 and "cycle" in out.get("err", ""), out)

# rename: registry, children and edges follow; published refused
rc, out, err = reshape("rename", "b", "b2")
check("rename: done", rc == 0 and git("rev-parse", "--verify", "-q", "b2", ok=False) != "", (rc, out, err))
check("rename: registry follows", sorted(cfg("stack-project.f.branch")) == ["a", "b2", "c"], cfg("stack-project.f.branch"))
check("rename: child's parent follows", cfg("branch.c.stack-parent") == ["b2"])
check("rename: an after edge follows", cfg("branch.c.stack-after") == ["b2"], cfg("branch.c.stack-after"))
check("rename: config carried", cfg("branch.b2.description")[-1] == "own")
work_b = (cfg("branch.b2.stack-work") or [""])[0]
check("rename: the work identity follows and its label moves", work_b.startswith("w_") and out.get("work") == work_b
      and work_of(work_b).get("branch") == "b2", (out, work_b))
rc, out, err = reshape("new", "b", "--parent", "main", "--project", "f", "--description", "a new b")
check("a recreated name gets a new identity", rc == 0 and cfg("branch.b.stack-work")[0] not in ("", work_b), (rc, out, err))
reshape("contract", "b")
rc, out, _ = reshape("rename", "a", "a2")
check("rename: a published branch is Phil's call", rc == 1 and "published" in out.get("err", ""), out)

# contract: a branch with work is refused; an empty one goes and its children re-point
rc, out, _ = reshape("contract", "b2")
check("contract: refuses a branch with changes", rc == 1 and "not empty" in out.get("err", ""), out)
reshape("new", "e", "--parent", "b2", "--project", "f", "--description", "empty step")
git("branch", "-f", "c2", "c")
git("config", "branch.c2.stack-parent", "e")
git("config", "--add", "branch.c2.stack-requires", "e")
rc, out, err = reshape("contract", "e")
check("contract: empty branch dropped", rc == 0 and git("rev-parse", "--verify", "-q", "e", ok=False) == "", (rc, out, err))
check("contract: its child re-points to its parent", cfg("branch.c2.stack-parent") == ["b2"])
check("contract: an edge naming it is dropped", cfg("branch.c2.stack-requires") == [])
check("contract: registry entry gone", "e" not in cfg("stack-project.f.branch"))

# contract: a squash-merged branch (main carries its content as one commit) goes too
reshape("new", "sq", "--parent", "main", "--project", "f", "--description", "squash me")
git("checkout", "-q", "sq"); commit("sq.txt", "sq\n", "sq1"); commit("sq.txt", "sq2\n", "sq2")
git("checkout", "-q", "main"); git("merge", "-q", "--squash", "sq"); git("commit", "-q", "-m", "squash sq (#1)")
git("update-ref", "refs/remotes/origin/main", "main")
rc, out, err = reshape("contract", "sq")
check("contract: a squash-merged branch is contracted as merged", rc == 0 and out.get("why") == "merged", (rc, out, err))

# contract: GitHub's MERGED verdict at the local tip is the ground truth once main has moved past
# a squash (its lines rewritten since), where no content check can see the branch as merged
reshape("new", "gm", "--parent", "main", "--project", "f", "--description", "merged on github")
git("checkout", "-q", "gm"); commit("gm.txt", "one\n", "gm1")
git("checkout", "-q", "main"); git("merge", "-q", "--squash", "gm"); git("commit", "-q", "-m", "squash gm (#2)")
commit("gm.txt", "one, then more\n", "main moves past gm")
git("update-ref", "refs/remotes/origin/main", "main")
shim = os.path.join(os.path.dirname(repo), "shim")
os.makedirs(shim, exist_ok=True)
pr_json = os.path.join(os.path.dirname(repo), "prs.json")
with open(os.path.join(shim, "gh"), "w") as f:
    f.write(f"#!/bin/sh\ncat {pr_json}\n")
os.chmod(os.path.join(shim, "gh"), 0o755)


def github_says(branch, head, state="MERGED"):
    with open(pr_json, "w") as f:
        json.dump([{"headRefName": branch, "headRefOid": head, "number": 2, "state": state, "isDraft": False,
                    "url": "", "reviewDecision": ""}], f)


real_path = env["PATH"]
env["PATH"] = shim + os.pathsep + real_path
git("checkout", "-q", "gm"); commit("gm.txt", "one, locally\n", "after the merge")
github_says("gm", git("rev-parse", "gm~1"))
rc, out, _ = reshape("contract", "gm")
check("contract: a branch with a commit GitHub never merged is refused", rc == 1, out)
git("checkout", "-q", "main"); git("branch", "-f", "gm", "gm~1")
github_says("gm", git("rev-parse", "gm"))
rc, out, err = reshape("contract", "gm")
check("contract: GitHub's MERGED at the local tip contracts it, though main moved past its lines",
      rc == 0 and out.get("why") == "merged", (rc, out, err))
env["PATH"] = real_path

# land: a root squash-merges; its published child edits the very lines the root wrote (#11674).
# git's own merge base is pre-squash, so the root's change reads as made twice and conflicts; the
# tip the child was built on is the base that tells the truth
env["PATH"] = shim + os.pathsep + real_path
reshape("new", "lp", "--parent", "main", "--project", "f", "--description", "root that lands")
git("checkout", "-q", "lp"); commit("shared.txt", "one\npar\nthree\n", "lp1")
reshape("new", "lk", "--parent", "lp", "--project", "f", "--description", "published child")
git("checkout", "-q", "lk"); commit("shared.txt", "one\nkid\nthree\n", "lk1")
reshape("new", "lg", "--parent", "lk", "--project", "f", "--description", "its unpublished child")
git("checkout", "-q", "lg"); commit("lg.txt", "lg\n", "lg1")
reshape("new", "lu", "--parent", "lp", "--project", "f", "--description", "unpublished sibling")
git("checkout", "-q", "lu"); commit("lu.txt", "lu\n", "lu1")
git("update-ref", "refs/remotes/origin/lk", "lk")
git("checkout", "-q", "main"); git("merge", "-q", "--squash", "lp"); git("commit", "-q", "-m", "squash lp (#3)")
commit("other.txt", "main moves on\n", "main moves on")
git("update-ref", "refs/remotes/origin/main", "main")
github_says("lp", git("rev-parse", "lp"))
lk_old, lu_old = git("rev-parse", "lk"), git("rev-parse", "lu")
trap = subprocess.run(["git", "-C", repo, "merge-tree", "--write-tree", "lk", "origin/main"], capture_output=True, env=env)
check("land: git's default merge base conflicts (the trap)", trap.returncode == 1, trap.returncode)
rc, out, err = reshape("contract", "lp")
check("land: contracting the landed root lands its children", rc == 0 and out.get("why") == "merged"
      and sorted((r["branch"], r["how"]) for r in out.get("landed", [])) == [("lk", "merged"), ("lu", "rebased")], (rc, out, err))
check("land: the published child is a catch-up merge (child, origin/main) — append-only",
      git("rev-list", "--parents", "-n1", "lk").split()[1:] == [lk_old, git("rev-parse", "origin/main")])
check("land: its tree is the child's own change on main",
      git("show", "lk:shared.txt") == "one\nkid\nthree" and git("show", "lk:other.txt") == "main moves on"
      and git("diff", "origin/main", "lk", "--name-only") == "shared.txt", git("diff", "origin/main", "lk"))
check("land: the unpublished sibling is rebased onto main with only its own commit",
      anc("origin/main", "lu") and git("rev-list", "--count", "origin/main..lu") == "1" and not anc(lu_old, "lu"))
check("land: children point at main, the root is gone",
      cfg("branch.lk.stack-parent") == ["main"] and cfg("branch.lu.stack-parent") == ["main"]
      and git("rev-parse", "--verify", "-q", "lp", ok=False) == "")
check("land: the grandchild follows its parent", anc("lk", "lg") and git("show", "lg:lg.txt") == "lg", out.get("carried"))

# a child that overlaps main beyond the root's change: a real conflict, refused with nothing moved
reshape("new", "lp2", "--parent", "main", "--project", "f", "--description", "another root")
git("checkout", "-q", "lp2"); commit("s2.txt", "a\nroot\nc\n", "lp2")
reshape("new", "lk2", "--parent", "lp2", "--project", "f", "--description", "overlapping child")
git("checkout", "-q", "lk2"); commit("s2.txt", "a\nchild\nc\n", "lk2")
git("update-ref", "refs/remotes/origin/lk2", "lk2")
git("checkout", "-q", "main"); git("merge", "-q", "--squash", "lp2"); git("commit", "-q", "-m", "squash lp2 (#4)")
commit("s2.txt", "a\nmain rewrote it\nc\n", "main rewrites the root's line")
git("update-ref", "refs/remotes/origin/main", "main")
github_says("lp2", git("rev-parse", "lp2"))
lk2_old = git("rev-parse", "lk2")
rc, out, err = reshape("contract", "lp2")
check("land: a real overlap refuses the contract and moves nothing",
      rc == 1 and "conflict" in out.get("err", "") and git("rev-parse", "lk2") == lk2_old
      and git("rev-parse", "--verify", "-q", "lp2", ok=False) != "" and cfg("branch.lk2.stack-parent") == ["lp2"], (rc, out))
env["PATH"] = real_path

# catch-up: a moves (as if a follow-up landed), its child chain catches up
git("checkout", "-q", "a"); commit("a2.txt", "a2\n", "a2"); git("checkout", "-q", "main")
reshape("new", "d", "--parent", "a", "--project", "f", "--description", "add d")
git("checkout", "-q", "a"); commit("a3.txt", "a3\n", "a3"); git("checkout", "-q", "main")
rc, out, err = reshape("catch-up", "d")
check("catch-up: the chain caught up", rc == 0 and anc("a", "d"), (rc, out, err))

# the lock: a held forest waits, then says who
holder = subprocess.Popen([os.path.join(HERE, "forest-lock"), "f", "--who", "a test", "--", "sleep", "3"], cwd=repo, env=env)
import time  # noqa: E402
time.sleep(0.5)
rc, out, err = reshape("contract", "d", "--wait", "0.3")
holder.wait()
check("a held forest: exit 75 naming the holder", rc == 75 and "a test" in err, (rc, err))

# no scratch checkout left behind
check("no throwaway checkouts left", "stack-reshape-" not in git("worktree", "list"))

print(f"\n{'all passed' if not failures else f'{failures} failed'}")
sys.exit(1 if failures else 0)
