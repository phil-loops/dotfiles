#!/usr/bin/env python3
"""chat-bind: a name that is one forest, branch or tracker item binds the chat to its work and labels
it; free text stays a plain label; a name that is more than one refuses rather than guess.
A temp repo, journal, tracker and presence registry; never the live ones."""
import testenv  # noqa: F401,E402 — git here ignores the machine's config (testenv.py)
import importlib.machinery
import importlib.util
import os
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
TMP = tempfile.mkdtemp(prefix="chat-bind-test-")
os.environ["CANOPY_WORK_JOURNAL"] = os.path.join(TMP, "journal.sqlite3")
os.environ["CANOPY_TODO_DIR"] = os.path.join(TMP, "todo")
os.environ["CLAUDE_SESSION_PRESENCE_DIR"] = os.path.join(TMP, "presence")
os.makedirs(os.environ["CANOPY_TODO_DIR"])
os.makedirs(os.environ["CLAUDE_SESSION_PRESENCE_DIR"])
SESSION = "feedface-0000-4000-8000-000000000001"
os.environ["CLAUDE_CODE_SESSION_ID"] = SESSION
os.environ["TMUX_PANE"] = "%1"
sys.path.insert(0, HERE)
loader = importlib.machinery.SourceFileLoader("chat_bind", os.path.join(HERE, "chat-bind"))
spec = importlib.util.spec_from_loader("chat_bind", loader)
cb = importlib.util.module_from_spec(spec)
loader.exec_module(cb)
from srv import ctx, todo, workjournal as wj  # noqa: E402

failures = 0


def check(name, ok, detail=""):
    global failures
    print(("✓ " if ok else "✗ ") + name + ("" if ok else f" — {detail}"))
    failures += 0 if ok else 1


repo = os.path.join(TMP, "loops")
env = {**os.environ, "GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@t", "GIT_COMMITTER_NAME": "t", "GIT_COMMITTER_EMAIL": "t@t"}
for k in ("GIT_DIR", "GIT_INDEX_FILE", "GIT_WORK_TREE"):
    env.pop(k, None)


def git(*a):
    subprocess.run(["git", "-C", repo, *a], check=True, env=env, capture_output=True)


subprocess.run(["git", "init", "-q", "-b", "main", repo], check=True, env=env)
git("commit", "-q", "--allow-empty", "-m", "root")
for b in ("add-the-queue", "show-evidence", "twin"):
    git("branch", b)
git("config", "branch.add-the-queue.stack-project", "review-queue")
git("config", "branch.show-evidence.stack-project", "review-queue")
git("config", "branch.twin.stack-project", "twin")
todo.write("fix-the-thing", {"title": "Fix the thing", "kind": "build", "state": "open", "area": "home", "size": "S",
                             "why": "a test item", "incarnation": "i_" + "1" * 32}, "")
ctx.CWD = ctx.MAIN_WT = repo
ctx.run = lambda argv, timeout=None, **kw: subprocess.run(argv, cwd=repo, capture_output=True, text=True, env=env)


def bound():
    j = wj.Journal()
    try:
        b = j.binding(wj.CLAUDE_CODE_SOURCE, SESSION)
        return sorted(j.work(w)["branch"] or j.work(w)["todo_id"] for w in b["works"]) if b else []
    finally:
        j.close()


check("free text is a plain label and binds nothing", cb.resolve("%1", "poking at the ses findings") is None and bound() == [])
check("a forest binds the chat to every branch it holds", cb.resolve("%1", "review-queue") == "review-queue"
      and bound() == ["add-the-queue", "show-evidence"], bound())
check("a branch binds the chat to it", cb.resolve("%1", "add-the-queue") == "add-the-queue", bound())
check("a tracker item binds the chat to its work and shows its title",
      cb.resolve("%1", "fix-the-thing") == "Fix the thing" and "fix-the-thing" in bound(), bound())
try:
    cb.resolve("%1", "twin")
    check("a name that is a forest and a branch refuses", False, "it bound")
except cb.Refused as e:
    check("a name that is a forest and a branch refuses, naming how to pick",
          "forest:twin" in str(e) and "branch:twin" in str(e), str(e))
check("a kind prefix picks one", cb.resolve("%1", "branch:twin") == "twin" and "twin" in bound(), bound())
try:
    cb.resolve("%1", "todo:no-such-item")
    check("a prefixed name that isn't there refuses", False)
except cb.Refused:
    check("a prefixed name that isn't there refuses", True)
try:
    cb.resolve("%2", "review-queue")
    check("another pane with no chat of its own refuses rather than binding this chat", False)
except cb.Refused as e:
    check("another pane with no chat of its own refuses rather than binding this chat", "pane %2" in str(e), str(e))

sys.exit(1 if failures else 0)
