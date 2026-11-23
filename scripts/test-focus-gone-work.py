#!/usr/bin/env python3
"""srv/focus.py retires the work of a branch deleted outside the tools: work no `branch.<b>.stack-work`
names ends, with the chat bindings that named it; a work minted moments ago (its branch not made
yet) is left; and a config read that names nothing retires nothing. Temp repo and temp journal."""
import testenv  # noqa: F401,E402 — git here ignores the machine's config (testenv.py)
import os
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)


class _State:
    @staticmethod
    def poke():
        pass


sys.modules["srv.state"] = _State
from srv import ctx  # noqa: E402

failures = 0


def check(name, ok, detail=""):
    global failures
    print(("✓ " if ok else "✗ ") + name + ("" if ok else f" — {detail}"))
    failures += 0 if ok else 1


env = {**os.environ, "GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@t", "GIT_COMMITTER_NAME": "t", "GIT_COMMITTER_EMAIL": "t@t"}
for k in ("GIT_DIR", "GIT_INDEX_FILE", "GIT_WORK_TREE"):
    env.pop(k, None)
root = tempfile.mkdtemp(prefix="focus-gone-work-")
repo = os.path.join(root, "r")
os.environ["CANOPY_WORK_JOURNAL"] = os.path.join(root, "journal.sqlite3")
subprocess.run(["git", "init", "-q", "-b", "main", repo], check=True, env=env)


def git(*a):
    return subprocess.run(["git", "-C", repo, *a], capture_output=True, text=True, env=env, check=True).stdout.strip()


git("commit", "-q", "--allow-empty", "-m", "base")
ctx.CWD = ctx.MAIN_WT = repo
ctx.run = lambda argv, **kw: subprocess.run(argv, cwd=repo, capture_output=True, text=True, env=env)
logged = []
ctx.log = lambda line: logged.append(line)
from srv import focus, workjournal  # noqa: E402

clock = [1_000_000.0]
focus._retire_gone_work()
check("no journal: nothing to do, nothing created", not os.path.exists(os.environ["CANOPY_WORK_JOURNAL"]))

j = workjournal.Journal(clock=lambda: clock[0])
j.register_source("claude-code", adapter="claude-code", ordering="none")
REPO = ctx.repo_name()
kept, gone = j.mint_branch_work(REPO, "kept"), j.mint_branch_work(REPO, "gone")
elsewhere = j.mint_branch_work("another-repo", "gone")
j.bind("claude-code", "chat", [kept, gone], by="t")
j.close()
real_journal = workjournal.Journal
workjournal.Journal = lambda *a, **k: real_journal(*a, **{**k, "clock": lambda: clock[0]})
workjournal.open_existing = lambda path=None: workjournal.Journal()


def retired(w):
    jj = real_journal()
    try:
        return bool(jj.work(w)["retired_at"])
    finally:
        jj.close()


clock[0] += 3600
focus._retire_gone_work()
check("a config that names no work retires nothing", not retired(kept) and not retired(gone))

for b, w in (("kept", kept),):
    git("branch", b, "main")
    git("config", f"branch.{b}.stack-work", w)
jj = real_journal(clock=lambda: clock[0])
being_made = jj.mint_branch_work(REPO, "being-made")
jj.close()
focus._retire_gone_work()
check("the work of a branch that is gone is retired", retired(gone) and any(gone in ln for ln in logged), logged)
check("…a named branch's work stays", not retired(kept))
check("…another repo's work stays", not retired(elsewhere))
check("…a work minted moments ago stays", not retired(being_made))
jj = real_journal()
check("…and the chat that was bound to it no longer lists it", jj.bound_works("claude-code", "chat") == [kept],
      jj.bound_works("claude-code", "chat"))
jj.close()

print(f"\n{'all passed' if not failures else f'{failures} failed'}")
sys.exit(1 if failures else 0)
