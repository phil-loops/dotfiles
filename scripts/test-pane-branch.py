#!/usr/bin/env python3
"""Which branch a tmux pane is working on (pane-branch, the reference-transaction hook's record): the
hook writes one line per branch move in the pane that made it, and a pane is on the branch it last
added commits to or last started in a forest. A throwaway repo and journal dir, no tmux server."""
import testenv  # noqa: F401,E402 — git here ignores the machine's config (testenv.py)
import importlib.machinery
import importlib.util
import os
import subprocess
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
loader = importlib.machinery.SourceFileLoader("pane_branch", os.path.join(HERE, "pane-branch"))
pb = importlib.util.module_from_spec(importlib.util.spec_from_loader("pane_branch", loader))
loader.exec_module(pb)

TMP = os.path.realpath(tempfile.mkdtemp(prefix="pane-branch-test-"))
REPO, JOURNAL = os.path.join(TMP, "repo"), os.path.join(TMP, "journal")
SERVER = "4242"
failures = 0


def check(name, ok, detail=""):
    global failures
    print(("✓ " if ok else "✗ ") + name + ("" if ok else f" — {detail}"))
    failures += 0 if ok else 1


def git(*args, pane=None, cwd=REPO):
    env = dict(os.environ, PANE_BRANCH_DIR=JOURNAL)
    env.pop("TMUX", None), env.pop("TMUX_PANE", None)
    if pane:
        env.update(TMUX=f"/tmp/sock,{SERVER},0", TMUX_PANE=pane)
    r = subprocess.run(["git", *args], cwd=cwd, env=env, capture_output=True, text=True)
    assert r.returncode == 0, f"git {' '.join(args)}: {r.stderr}"
    return r.stdout.strip()


def commit(name, pane=None, cwd=REPO):
    with open(os.path.join(cwd, name), "w") as f:
        f.write(name)
    git("add", name, cwd=cwd)
    git("commit", "-qm", name, pane=pane, cwd=cwd)


def on():
    return {pane: (m["branch"], m["how"]) for pane, m in pb.working_on(pb.read_moves(SERVER, JOURNAL), pb.Git()).items()}


def forest(branch):
    git("config", f"branch.{branch}.stack-project", "proj")


git("init", "-q", "-b", "main", REPO, cwd=TMP)
os.symlink(os.path.join(HERE, "..", "hooks", "loops-reference-transaction"), os.path.join(REPO, ".git", "hooks", "reference-transaction"))
commit("base", pane="%1")
check("a commit on the default branch isn't work on a branch", on() == {}, on())

git("checkout", "-q", "-b", "outside")
commit("no-pane")
check("a move made outside tmux writes nothing", [m["branch"] for m in pb.read_moves(SERVER, JOURNAL)] == ["main"], pb.read_moves(SERVER, JOURNAL))

git("checkout", "-q", "-b", "wt-1", "main", pane="%1")
check("starting a branch outside a forest isn't work yet", on() == {}, on())
commit("one", pane="%1")
check("a commit puts its pane on the branch", on() == {"%1": ("wt-1", "committed")}, on())
check("the record names the repo's main checkout", pb.read_moves(SERVER, JOURNAL)[-1]["repo"] == REPO, pb.read_moves(SERVER, JOURNAL)[-1])

git("branch", "feat", "main", pane="%2")
forest("feat")
check("starting a forest branch puts its pane on it", on().get("%2") == ("feat", "started"), on())

SCRATCH = os.path.join(TMP, "scratch")
git("worktree", "add", "-q", "--detach", SCRATCH, "feat")
commit("two", cwd=SCRATCH)
git("update-ref", "refs/heads/feat", git("rev-parse", "HEAD", cwd=SCRATCH), pane="%3", cwd=SCRATCH)
check("a tip moved forward from a scratch worktree, with no expected old value, counts", on().get("%3") == ("feat", "committed"), on())
check("…and is recorded against the main checkout", pb.read_moves(SERVER, JOURNAL)[-1]["repo"] == REPO, pb.read_moves(SERVER, JOURNAL)[-1])

git("branch", "other", "main", pane="%3")
forest("other")
git("branch", "-f", "feat", "main", pane="%1")
check("a rewrite doesn't move the pane that made it", on().get("%1") == ("wt-1", "committed"), on())
check("the latest work wins", on().get("%3") == ("other", "started"), on())

git("branch", "-D", "other", pane="%4")
check("a delete isn't work, and a deleted branch is nobody's", "%4" not in on() and on().get("%3") == ("feat", "committed"), on())

check("another tmux server's panes are another file", pb.read_moves("9999", JOURNAL) == [])

state = ("4242", "loops", "@3", [
    {"pane": "%1", "session": "loops", "window": "3", "index": "1", "window_id": "@3"},
    {"pane": "%3", "session": "loops", "window": "2", "index": "1", "window_id": "@2"},
    {"pane": "%9", "session": "agents", "window": "3", "index": "1", "window_id": "@7"},
])
rows = pb.rows(state, pb.read_moves(SERVER, JOURNAL), pb.Git())
check("a pane's address is window:pane, with the session when it isn't the client's",
      [r["address"] for r in rows] == ["3:1", "2:1", "agents 3:1"], [r["address"] for r in rows])
check("a row carries the repo's name and the branch", (rows[0]["repo"], rows[0]["branch"], rows[2]["branch"]) == ("repo", "wt-1", None), rows)
check("a digit is that pane of the window the client shows", pb.pick("1", state, rows)[0]["pane"] == "%1")
check("window:pane is in the client's session", pb.pick("2:1", state, rows)[0]["pane"] == "%3" and pb.pick("3:1", state, rows)[0]["pane"] == "%1")
check("a pane id names any pane", pb.pick("%9", state, rows)[0]["address"] == "agents 3:1")
check("a pane that isn't there says so", pb.pick("7", state, rows) == (None, "no pane 7"))

print("---", "all passed" if not failures else f"{failures} failed")
raise SystemExit(1 if failures else 0)
